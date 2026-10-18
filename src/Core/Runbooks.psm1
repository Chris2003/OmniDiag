<#
.SYNOPSIS
    Organization-owned runbook library for OmniDiag.

.DESCRIPTION
    Runbooks are plain Markdown files with a small front-matter header. They are
    owned by the organization (kept in the repository's runbooks/ folder, a file
    share, or any folder passed with -Path) and are read locally - nothing is
    fetched from a network service.

    Only runbooks whose front matter says `status: approved` are returned unless
    -IncludeUnapproved is passed, so drafts never reach a technician or the local
    AI assistant by accident.

    ---
    id: rb-dns-resolution
    title: DNS resolution failures
    status: approved
    owner: Network Team
    appliesTo: network/dns, dns
    tags: dns, name resolution
    ---
    # Markdown body with the steps...
#>

Set-StrictMode -Version Latest

# Repository-level runbooks/ folder (src/Core -> repo root).
$script:OmniDefaultRunbookPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'runbooks'

function Get-OmniDefaultRunbookPath {
    <# .SYNOPSIS Returns the runbook folder: $env:OMNIDIAG_RUNBOOK_PATH or the bundled runbooks/ folder. #>
    [OutputType([string])]
    param()
    if ($env:OMNIDIAG_RUNBOOK_PATH) { return $env:OMNIDIAG_RUNBOOK_PATH }
    return $script:OmniDefaultRunbookPath
}

function ConvertFrom-OmniRunbookText {
    <# .SYNOPSIS Internal: parse front matter + body of one runbook file. #>
    param([Parameter(Mandatory)][string] $Text, [string] $Path = '')

    $meta = @{}
    $body = $Text
    $match = [regex]::Match($Text, '\A\s*---\r?\n(?<front>.*?)\r?\n---\r?\n?(?<body>.*)\z', 'Singleline')
    if ($match.Success) {
        foreach ($line in ($match.Groups['front'].Value -split '\r?\n')) {
            if ($line -match '^\s*(?<key>[A-Za-z][A-Za-z0-9_-]*)\s*:\s*(?<value>.*?)\s*$') {
                $meta[$Matches['key'].ToLowerInvariant()] = $Matches['value'].Trim('"', "'")
            }
        }
        $body = $match.Groups['body'].Value
    }

    $split = { param($v) @(if ($v) { $v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }) }
    $fileName = if ($Path) { [System.IO.Path]::GetFileNameWithoutExtension($Path) } else { 'runbook' }
    $id = if ($meta['id']) { $meta['id'] } else { ($fileName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
    $title = if ($meta['title']) { $meta['title'] } else {
        $heading = [regex]::Match($body, '(?m)^#\s+(.+)$')
        if ($heading.Success) { $heading.Groups[1].Value.Trim() } else { $fileName }
    }
    $status = if ($meta['status']) { $meta['status'].ToLowerInvariant() } else { 'draft' }

    return [pscustomobject]@{
        PSTypeName = 'OmniDiag.Runbook'
        Id         = $id
        Title      = $title
        Status     = $status
        Approved   = ($status -eq 'approved')
        Owner      = [string]$meta['owner']
        AppliesTo  = & $split $meta['appliesto']
        Tags       = & $split $meta['tags']
        Body       = $body.Trim()
        Path       = $Path
    }
}

function Get-OmniRunbook {
    <#
    .SYNOPSIS
        Loads organization-owned runbooks from a folder of Markdown files.

    .PARAMETER Path
        One or more folders (searched recursively for *.md). Defaults to
        $env:OMNIDIAG_RUNBOOK_PATH, then the bundled runbooks/ folder.

    .PARAMETER Id
        Return only the runbook(s) with these ids.

    .PARAMETER IncludeUnapproved
        Also return draft / retired runbooks. Off by default.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Path = (Get-OmniDefaultRunbookPath),
        [string[]] $Id,
        [switch] $IncludeUnapproved
    )

    $runbooks = foreach ($folder in $Path) {
        if (-not (Test-Path -LiteralPath $folder)) {
            Write-Verbose "Runbook folder not found: $folder"
            continue
        }
        foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.md' -File -Recurse | Sort-Object FullName) {
            if ($file.Name -eq 'README.md') { continue }
            $text = [System.IO.File]::ReadAllText($file.FullName)
            ConvertFrom-OmniRunbookText -Text $text -Path $file.FullName
        }
    }

    $runbooks = @($runbooks | Where-Object { $IncludeUnapproved -or $_.Approved })
    if ($Id) { $runbooks = @($runbooks | Where-Object { $_.Id -in $Id }) }
    return $runbooks
}

function Find-OmniRunbook {
    <#
    .SYNOPSIS
        Retrieves the approved runbooks relevant to a session's findings.

    .DESCRIPTION
        A runbook matches a finding when one of its appliesTo patterns is a
        case-insensitive substring of the finding Id or Component - the same
        convention repairs use. Results are ordered by the most severe matching
        finding, then by the number of matches.

    .PARAMETER Session
        An OmniDiag.Session (live, or loaded with Import-OmniSession).

    .PARAMETER Runbook
        Runbooks to match. Defaults to Get-OmniRunbook -Path $Path.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Session,
        [object[]] $Runbook,
        [string[]] $Path = (Get-OmniDefaultRunbookPath)
    )

    if (-not $PSBoundParameters.ContainsKey('Runbook')) { $Runbook = @(Get-OmniRunbook -Path $Path) }

    $findings = @(foreach ($result in @($Session.Results)) {
        foreach ($finding in @($result.Findings)) { if ($finding -and $finding.Severity -ne 'Pass') { $finding } }
    })

    $matched = foreach ($rb in @($Runbook)) {
        $hits = @($findings | Where-Object {
            $target = ("{0} {1}" -f $_.Id, $_.Component).ToLowerInvariant()
            foreach ($pattern in @($rb.AppliesTo)) { if ($target.Contains($pattern.ToLowerInvariant())) { return $true } }
            $false
        })
        if ($hits.Count -eq 0) { continue }
        $worst = ($hits | ForEach-Object { Get-OmniSeverityRank -Severity $_.Severity } | Measure-Object -Maximum).Maximum
        [pscustomobject]@{
            PSTypeName      = 'OmniDiag.RunbookMatch'
            Runbook         = $rb
            Id              = $rb.Id
            Title           = $rb.Title
            FindingIds      = @($hits | ForEach-Object { [string]$_.Id } | Select-Object -Unique)
            HighestSeverity = $worst
        }
    }

    return @($matched | Sort-Object @{ Expression = 'HighestSeverity'; Descending = $true }, @{ Expression = { $_.FindingIds.Count }; Descending = $true }, Id)
}

Export-ModuleMember -Function @('Get-OmniRunbook', 'Find-OmniRunbook', 'Get-OmniDefaultRunbookPath')
