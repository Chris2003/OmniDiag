<#
.SYNOPSIS
    OmniDiag reporting: the Export-OmniReport coordinator.

.DESCRIPTION
    One entry point that writes any combination of HTML / JSON / CSV / ZIP from a
    session, into a target directory with a consistent, sanitized base name. The
    individual exporters remain independently callable; this just orchestrates them.
    With -Redact, one redaction context is built and one redacted copy of the session
    is passed to every exporter (see docs/REDACTION.md).
#>

Set-StrictMode -Version Latest

function Get-OmniSafeName {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'host' }
    return ($Value -replace '[^A-Za-z0-9._-]', '_')
}

function Export-OmniReport {
    <#
    .SYNOPSIS
        Generates one or more report formats for a session.

    .PARAMETER Session
        The OmniDiag.Session to report on.

    .PARAMETER OutputDirectory
        Folder to write into. Created if missing. Default: OmniDiagData\reports next to the tool (see Get-OmniDataRoot).

    .PARAMETER Format
        Any of Html, Json (report schema v1), Csv, Md (Markdown), Pdf, Zip.
        Default: Html, Json, Csv.

    .PARAMETER BaseName
        Base file name (no extension). Default: OmniDiag-<computer>-<timestamp>.

    .PARAMETER BrandName
        Optional organization name for report branding.

    .PARAMETER BrandLogo
        Optional path to a logo image embedded in HTML/PDF report headers.

    .PARAMETER BrandColor
        Optional accent color (#RRGGBB) for HTML/PDF reports.

    .PARAMETER Option
        Optional run options recorded in the JSON report's 'options' object.

    .PARAMETER Redact
        Replace host names, user names, domains, SIDs, profile paths, and IP/MAC
        addresses with stable pseudonyms (HOST-1, USER-1, IP-1, ...) in every format and
        in the output file names. One context is built from the session, a redacted copy
        of the session is made once, and every exporter (HTML, JSON, CSV, Markdown, PDF,
        ZIP incl. its README and run log) renders that copy. The session passed in is
        not modified. The JSON report records options.redacted = true.

    .PARAMETER RedactionMapPath
        Optional path for a local JSON file mapping each original value to its
        pseudonym. It UN-REDACTS the report: keep it local, never share it. Requires
        -Redact; a warning is written.

    .PARAMETER AdditionalTerm
        Extra literal values to redact with -Redact (customer names, ticket ids, ...).
        Ignored when -RedactionContext is given (pass them to New-OmniRedactionContext).

    .PARAMETER RedactionContext
        An existing OmniDiag.RedactionContext to use with -Redact (so several bundles
        share pseudonyms). Default: a new context built from the session.

    .OUTPUTS
        OmniDiag.ReportSet describing the files written (and any Warnings). Redacted is
        $true for a redacted set; RedactionMapPath is the mapping file, if written (it
        is not listed in Files, which are the shareable outputs).

    .EXAMPLE
        Export-OmniReport -Session $session -Format Html, Json, Pdf

    .EXAMPLE
        Export-OmniReport -Session $session -Format Html, Json, Zip -Redact -RedactionMapPath .\private\map.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [string] $OutputDirectory = (Get-OmniDataPath -Kind Reports),
        [ValidateSet('Html', 'Json', 'Csv', 'Md', 'Pdf', 'Zip')]
        [string[]] $Format = @('Html', 'Json', 'Csv'),
        [string] $BaseName,
        [string] $BrandName,
        [string] $BrandLogo,
        [string] $BrandColor,
        [hashtable] $Option,
        [switch] $Redact,
        [string] $RedactionMapPath,
        [string[]] $AdditionalTerm = @(),
        [object] $RedactionContext
    )

    if ($RedactionMapPath -and -not $Redact) { throw '-RedactionMapPath requires -Redact.' }

    # Resolve relative paths against PowerShell's location (.NET file APIs use the process directory).
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if ($BrandLogo) { $BrandLogo = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BrandLogo) }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    # Redaction: one context, one redacted copy of the session, shared by every exporter.
    $sourceLogPath = $null
    $ctx = $null
    if ($Redact) {
        if ($Session.PSObject.Properties['LogPath'] -and $Session.LogPath) { $sourceLogPath = [string]$Session.LogPath }
        $ctx = $RedactionContext
        if ($null -eq $ctx) { $ctx = New-OmniRedactionContext -Session $Session -AdditionalTerm $AdditionalTerm }
        $Session = ConvertTo-OmniRedacted -InputObject $Session -Context $ctx
        Add-Member -InputObject $Session -MemberType NoteProperty -Name Redacted -Value $true -Force
        if ($Option) { $Option = ConvertTo-OmniRedacted -InputObject $Option -Context $ctx }
    }

    if (-not $BaseName) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $hostName = $null
        if ($Session.PSObject.Properties['Host'] -and $Session.Host -and $Session.Host.PSObject.Properties['ComputerName']) { $hostName = $Session.Host.ComputerName }
        $BaseName = "OmniDiag-$(Get-OmniSafeName $hostName)-$stamp"
    } elseif ($Redact) {
        # A caller-supplied name may embed the computer or user name too.
        $BaseName = ConvertTo-OmniRedacted -InputObject $BaseName -Context $ctx
    }

    $files = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $base = Join-Path $OutputDirectory $BaseName

    foreach ($fmt in ($Format | Select-Object -Unique)) {
        switch ($fmt) {
            'Html' { $files.Add((Export-OmniHtmlReport -Session $Session -Path "$base.html" -BrandName $BrandName -BrandLogo $BrandLogo -BrandColor $BrandColor)) }
            'Json' {
                $jsonParams = @{ Session = $Session; Path = "$base.json" }
                if ($Option) { $jsonParams.Option = $Option }
                $files.Add((Export-OmniJsonReport @jsonParams))
            }
            'Md'   { $files.Add((Export-OmniMarkdownReport -Session $Session -Path "$base.md" -BrandName $BrandName)) }
            'Csv'  {
                $files.Add((Export-OmniCsvReport -Session $Session -Path "$base.findings.csv"))
                $evt = Export-OmniEventCsvReport -Session $Session -Path "$base.events.csv"
                if ($evt) { $files.Add($evt) }
            }
            'Pdf'  {
                # PDF is generated natively (no browser / no external dependency).
                # Still guarded so an unexpected failure can't abort the other formats.
                try {
                    $files.Add((Export-OmniPdfReport -Session $Session -Path "$base.pdf" -BrandName $BrandName -BrandLogo $BrandLogo -BrandColor $BrandColor))
                } catch {
                    $warnings.Add("PDF export skipped: $($_.Exception.Message)")
                }
            }
            'Zip'  {
                $pkgParams = @{ Session = $Session; Path = "$base.zip"; BrandName = $BrandName; BrandLogo = $BrandLogo; BrandColor = $BrandColor }
                if ($Redact) { $pkgParams.Redact = $true; $pkgParams.RedactionContext = $ctx; $pkgParams.LogPath = $sourceLogPath }
                $files.Add((Export-OmniReportPackage @pkgParams))
            }
        }
    }

    $mapPath = $null
    if ($Redact -and $RedactionMapPath) {
        $mapPath = Export-OmniRedactionMapFile -Context $ctx -Path $RedactionMapPath
        Write-Warning "The redaction map '$mapPath' UN-REDACTS the report. Keep it on this machine and never share it with the report."
    }

    return [pscustomobject]@{
        PSTypeName      = 'OmniDiag.ReportSet'
        OutputDirectory = $OutputDirectory
        BaseName        = $BaseName
        Formats         = @($Format)
        Files           = @($files)
        Warnings        = @($warnings)
        Redacted        = [bool]$Redact
        RedactionMapPath = $mapPath
        GeneratedAt     = (Get-Date)
    }
}

function Export-OmniRedactionMapFile {
    <#
    .SYNOPSIS
        Writes a redaction context's original -> pseudonym map as local JSON.

    .DESCRIPTION
        The file un-redacts every report produced with the context; it is meant to
        stay on the technician's machine. Written as deterministic, ASCII-only JSON
        (UTF-8, no BOM).

    .PARAMETER Context
        The OmniDiag.RedactionContext used for the redacted reports.

    .PARAMETER Path
        Destination .json path.

    .OUTPUTS
        The written path (string).

    .EXAMPLE
        Export-OmniRedactionMapFile -Context $ctx -Path .\private\redaction-map.json
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $Path
    )
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($e in (Get-OmniRedactionMap -Context $Context)) {
        $entries.Add([ordered]@{ category = [string]$e.Category; pseudonym = [string]$e.Pseudonym; original = [string]$e.Original })
    }
    $doc = [ordered]@{
        kind        = 'omnidiag-redaction-map'
        warning     = 'This file UN-REDACTS OmniDiag reports. Keep it local; never share it with the report.'
        generatedAt = (ConvertTo-OmniIsoTimestamp -Value (Get-Date))
        salted      = [bool]$Context.Salted
        entries     = $entries.ToArray()
    }
    Write-OmniTextFile -Path $Path -Content ((ConvertTo-OmniJsonText -InputObject $doc) + "`n")
    return $Path
}

Export-ModuleMember -Function @('Export-OmniReport', 'Get-OmniSafeName', 'Export-OmniRedactionMapFile')
