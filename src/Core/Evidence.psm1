<#
.SYNOPSIS
    Saved-session evidence: load, search, and before/after comparison.

.DESCRIPTION
    Works on live sessions and on sessions saved as JSON reports, so a technician
    can reopen yesterday's scan, search it in plain language, or compare it with
    a fresh scan after a fix. Everything is local and deterministic - no model
    is required. The local AI assistant (Ollama.psm1) reuses Search-OmniEvidence
    to choose which evidence goes into each conversation turn.
#>

Set-StrictMode -Version Latest

$script:OmniStopWords = @(
    'a','an','the','and','or','but','is','are','was','were','be','been','am','do','does','did',
    'to','of','in','on','for','with','at','by','from','as','it','its','this','that','these','those',
    'what','which','who','why','how','when','where','can','could','should','would','will','i','me',
    'my','we','our','you','your','there','any','all','some','about','into','not','no','so','if','than',
    'then','them','they','he','she','his','her','tell','show','find','give','list','please','next','step','steps'
)

function ConvertTo-OmniSearchToken {
    <# .SYNOPSIS Internal: lower-case, split, drop stop words, light suffix stemming. #>
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $tokens = foreach ($word in ($Text.ToLowerInvariant() -split '[^a-z0-9]+')) {
        if ($word.Length -lt 2 -or $word -in $script:OmniStopWords) { continue }
        if ($word.Length -gt 5 -and $word.EndsWith('ing')) { $word = $word.Substring(0, $word.Length - 3) }
        elseif ($word.Length -gt 4 -and $word.EndsWith('ed')) { $word = $word.Substring(0, $word.Length - 2) }
        elseif ($word.Length -gt 3 -and $word.EndsWith('s') -and -not $word.EndsWith('ss')) { $word = $word.Substring(0, $word.Length - 1) }
        $word
    }
    return @($tokens)
}

function Get-OmniSessionFinding {
    <# .SYNOPSIS Returns every finding in a session, annotated with its module and category. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Session,
        [switch] $IncludePass
    )
    foreach ($result in @($Session.Results)) {
        if (-not $result -or -not $result.PSObject.Properties['Findings']) { continue }
        foreach ($finding in @($result.Findings)) {
            if (-not $finding) { continue }
            if (-not $IncludePass -and $finding.Severity -eq 'Pass') { continue }
            [pscustomobject]@{
                PSTypeName     = 'OmniDiag.SessionFinding'
                Id             = [string]$finding.Id
                Title          = [string]$finding.Title
                Severity       = [string]$finding.Severity
                Component      = [string]$finding.Component
                Detail         = [string]$finding.Detail
                LikelyCause    = [string]$finding.LikelyCause
                Recommendation = [string]$finding.Recommendation
                ModuleName     = [string]$result.ModuleName
                Category       = [string]$result.Category
            }
        }
    }
}

function Import-OmniSession {
    <#
    .SYNOPSIS
        Loads a session saved by Export-OmniJsonReport (or a report .zip package).

    .PARAMETER Path
        A JSON report, a report package .zip (its data.json is read), or a folder
        (the newest *.json report in it is used).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Saved session not found: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        $item = Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $item) { throw "No JSON report found in folder: $Path" }
    }

    if ($item.Extension -eq '.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($item.FullName)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -eq 'data.json' } | Select-Object -First 1
            if (-not $entry) { throw "Report package has no data.json: $($item.FullName)" }
            $reader = [System.IO.StreamReader]::new($entry.Open())
            try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
    } else {
        $json = [System.IO.File]::ReadAllText($item.FullName)
    }

    try { $session = $json | ConvertFrom-Json -ErrorAction Stop } catch { throw "Not a valid OmniDiag JSON report: $($item.FullName)" }
    if (-not $session.PSObject.Properties['Results']) { throw "JSON does not contain an OmniDiag session (no Results): $($item.FullName)" }

    # Restore live-session shapes the reporters rely on: Metrics is an ordered dictionary
    # (ConvertFrom-Json yields a PSCustomObject) and Results/Findings are arrays.
    $session.Results = @($session.Results | Where-Object { $_ })
    foreach ($result in $session.Results) {
        $metrics = [ordered]@{}
        if ($result.PSObject.Properties['Metrics'] -and $result.Metrics) {
            foreach ($p in $result.Metrics.PSObject.Properties) { $metrics[$p.Name] = $p.Value }
        }
        $result | Add-Member -MemberType NoteProperty -Name Metrics -Value $metrics -Force
        $findings = @(if ($result.PSObject.Properties['Findings']) { $result.Findings | Where-Object { $_ } })
        $result | Add-Member -MemberType NoteProperty -Name Findings -Value $findings -Force
    }
    Add-Member -InputObject $session -MemberType NoteProperty -Name SourcePath -Value $item.FullName -Force
    return $session
}

function Search-OmniEvidence {
    <#
    .SYNOPSIS
        Plain-language search over a session's findings and approved runbooks.

    .DESCRIPTION
        Ranks findings and runbooks by keyword overlap with the query (titles and
        components weigh more than body text), with a small boost for severity and
        for runbooks whose appliesTo patterns match a session finding. Deterministic
        and offline; no model is involved.

    .PARAMETER Query
        Free text, e.g. "why is the network slow after the VPN connects".

    .PARAMETER Session
        Live or imported session. Optional when only runbooks are searched.

    .PARAMETER Runbook
        Runbooks to search (approved only by default via Get-OmniRunbook).

    .PARAMETER Top
        Maximum results to return.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Query,
        [pscustomobject] $Session,
        [object[]] $Runbook = @(),
        [ValidateRange(1, 200)][int] $Top = 10
    )

    $queryTokens = @(ConvertTo-OmniSearchToken $Query | Select-Object -Unique)
    if ($queryTokens.Count -eq 0) { return @() }

    $score = {
        param([hashtable] $Fields)
        $total = 0.0; $matched = @{}
        foreach ($weight in $Fields.Keys) {
            $tokens = @(ConvertTo-OmniSearchToken $Fields[$weight])
            foreach ($q in $queryTokens) {
                $hits = @($tokens | Where-Object { $_ -eq $q -or ($q.Length -ge 4 -and $_.StartsWith($q)) }).Count
                if ($hits -gt 0) { $total += [double]$weight * [math]::Min($hits, 3); $matched[$q] = $true }
            }
        }
        # Reward covering more of the query, not just repeating one term.
        if ($matched.Count -gt 0) { $total *= (1 + ($matched.Count / $queryTokens.Count)) }
        return [pscustomobject]@{ Score = $total; Matched = @($matched.Keys) }
    }

    $sessionFindings = @()
    if ($Session) { $sessionFindings = @(Get-OmniSessionFinding -Session $Session) }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $sessionFindings) {
        $s = & $score @{ 3 = "$($f.Title) $($f.Component)"; 2 = "$($f.ModuleName) $($f.Category) $($f.Id)"; 1 = "$($f.Detail) $($f.LikelyCause) $($f.Recommendation)" }
        if ($s.Score -le 0) { continue }
        $results.Add([pscustomobject]@{
            PSTypeName = 'OmniDiag.SearchHit'; Type = 'Finding'; Id = $f.Id; Title = $f.Title
            Severity = $f.Severity; Score = [math]::Round($s.Score + (Get-OmniSeverityRank -Severity $f.Severity) * 0.5, 2)
            MatchedTerms = $s.Matched; Snippet = (@($f.LikelyCause, $f.Recommendation) | Where-Object { $_ }) -join ' '
            Item = $f
        })
    }

    foreach ($rb in @($Runbook)) {
        if (-not $rb) { continue }
        $s = & $score @{ 3 = "$($rb.Title) $(@($rb.Tags) -join ' ')"; 2 = (@($rb.AppliesTo) -join ' '); 1 = $rb.Body }
        if ($s.Score -le 0) { continue }
        $linked = @(foreach ($f in $sessionFindings) {
            $target = ("{0} {1}" -f $f.Id, $f.Component).ToLowerInvariant()
            foreach ($pattern in @($rb.AppliesTo)) { if ($target.Contains($pattern.ToLowerInvariant())) { $f.Id; break } }
        })
        $body = ($rb.Body -replace '(?m)^#+\s*', '' -replace '\s+', ' ').Trim()
        $results.Add([pscustomobject]@{
            PSTypeName = 'OmniDiag.SearchHit'; Type = 'Runbook'; Id = $rb.Id; Title = $rb.Title
            Severity = $null; Score = [math]::Round($s.Score + [math]::Min($linked.Count, 3), 2)
            MatchedTerms = $s.Matched; Snippet = $(if ($body.Length -gt 240) { $body.Substring(0, 240) + '...' } else { $body })
            Item = $rb; LinkedFindingIds = @($linked | Select-Object -Unique)
        })
    }

    return @($results | Sort-Object @{ Expression = 'Score'; Descending = $true }, Type, Id | Select-Object -First $Top)
}

function Compare-OmniSession {
    <#
    .SYNOPSIS
        Before/after comparison of two sessions (e.g. before and after a repair).

    .DESCRIPTION
        Findings are matched by their stable Id. Non-pass findings are classified as
        Resolved (only before), New (only after), or Persisting (both, with a
        severity change of Improved / Worsened / Unchanged). Health score and
        per-module status deltas are included, plus an overall Verdict.

    .PARAMETER Before
        Earlier session, or a path to a saved JSON report / package.

    .PARAMETER After
        Later session, or a path to a saved JSON report / package.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object] $Before,
        [Parameter(Mandatory)][object] $After
    )

    if ($Before -is [string]) { $Before = Import-OmniSession -Path $Before }
    if ($After -is [string]) { $After = Import-OmniSession -Path $After }

    $index = {
        param($Session)
        $map = [ordered]@{}
        foreach ($f in @(Get-OmniSessionFinding -Session $Session)) {
            # Keep the most severe occurrence when an Id repeats.
            if (-not $map.Contains($f.Id) -or (Get-OmniSeverityRank $f.Severity) -gt (Get-OmniSeverityRank $map[$f.Id].Severity)) { $map[$f.Id] = $f }
        }
        return $map
    }
    $b = & $index $Before
    $a = & $index $After

    $resolved = @(foreach ($id in $b.Keys) { if (-not $a.Contains($id)) { $b[$id] } })
    $new = @(foreach ($id in $a.Keys) { if (-not $b.Contains($id)) { $a[$id] } })
    $persisting = @(foreach ($id in $b.Keys) {
        if (-not $a.Contains($id)) { continue }
        $delta = (Get-OmniSeverityRank $a[$id].Severity) - (Get-OmniSeverityRank $b[$id].Severity)
        [pscustomobject]@{
            PSTypeName = 'OmniDiag.FindingChange'; Id = $id; Title = $a[$id].Title; Component = $a[$id].Component
            BeforeSeverity = $b[$id].Severity; AfterSeverity = $a[$id].Severity
            Change = $(if ($delta -lt 0) { 'Improved' } elseif ($delta -gt 0) { 'Worsened' } else { 'Unchanged' })
        }
    })

    $scoreOf = { param($s) if ($s.PSObject.Properties['Summary'] -and $s.Summary -and $s.Summary.PSObject.Properties['Score']) { [int]$s.Summary.Score } else { $null } }
    $beforeScore = & $scoreOf $Before
    $afterScore = & $scoreOf $After
    $scoreDelta = if ($null -ne $beforeScore -and $null -ne $afterScore) { $afterScore - $beforeScore } else { $null }

    $statusOf = { param($s) $m = @{}; foreach ($r in @($s.Results)) { if ($r) { $m[[string]$r.ModuleName] = [string]$r.Status } }; $m }
    $bs = & $statusOf $Before; $as = & $statusOf $After
    $moduleChanges = @(foreach ($name in @($bs.Keys + $as.Keys | Sort-Object -Unique)) {
        $was = $bs[$name]; $now = $as[$name]
        if ($was -ne $now) { [pscustomobject]@{ ModuleName = $name; BeforeStatus = $was; AfterStatus = $now } }
    })

    $better = $resolved.Count + @($persisting | Where-Object Change -eq 'Improved').Count
    $worse = $new.Count + @($persisting | Where-Object Change -eq 'Worsened').Count
    $verdict = if ($better -eq 0 -and $worse -eq 0) { 'Unchanged' }
        elseif ($worse -eq 0) { 'Improved' }
        elseif ($better -eq 0) { 'Regressed' }
        else { 'Mixed' }

    return [pscustomobject]@{
        PSTypeName    = 'OmniDiag.SessionComparison'
        BeforeTime    = $Before.StartTime
        AfterTime     = $After.StartTime
        BeforeScore   = $beforeScore
        AfterScore    = $afterScore
        ScoreDelta    = $scoreDelta
        Verdict       = $verdict
        Resolved      = @($resolved | Sort-Object @{ Expression = { Get-OmniSeverityRank $_.Severity }; Descending = $true }, Id)
        New           = @($new | Sort-Object @{ Expression = { Get-OmniSeverityRank $_.Severity }; Descending = $true }, Id)
        Persisting    = @($persisting)
        ModuleChanges = $moduleChanges
    }
}

Export-ModuleMember -Function @('Get-OmniSessionFinding', 'Import-OmniSession', 'Search-OmniEvidence', 'Compare-OmniSession')
