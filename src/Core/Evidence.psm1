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

function Save-OmniSession {
    <#
    .SYNOPSIS
        Saves a session in OmniDiag's native (internal) JSON format.

    .DESCRIPTION
        Native session snapshots are what -FromSession / -CompareWith 'Last' and the
        GUI reload. They keep every internal property (metrics, timings, severities)
        and are NOT the public report format - Export-OmniJsonReport writes the
        versioned report schema v1. Import-OmniSession reads both.

    .PARAMETER Session
        The OmniDiag.Session to save.

    .PARAMETER Path
        Destination file. Default: OmniDiagData\sessions\session-<timestamp>.json.

    .OUTPUTS
        The written file path (string).

    .EXAMPLE
        $saved = Save-OmniSession -Session $session
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [string] $Path
    )
    if (-not $Path) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $Path = Get-OmniDataPath -Kind Sessions -ChildPath "session-$stamp.json"
    }
    # .NET resolves relative paths against the process directory, not PowerShell's location.
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Depth 12 captures findings -> Data -> nested event groups/timeline entries.
    $json = $Session | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    return $Path
}

function Import-OmniSession {
    <#
    .SYNOPSIS
        Loads a saved session (native format), a JSON report (schema v1), or a report
        .zip package.

    .DESCRIPTION
        Files that carry 'schemaVersion' are v1 reports and are rebuilt with
        ConvertFrom-OmniReportV1 (major version 1 only); anything else must be a
        native session written by Save-OmniSession (or by OmniDiag before 0.5.0).

    .PARAMETER Path
        A saved session, a JSON report, a report package .zip (its data.json is read),
        or a folder (the newest *.json file in it is used).

    .NOTES
        Deprecated as a user-facing name in 0.8.0: use Import-OmniDiagSession.

    .EXAMPLE
        $session = Import-OmniSession -Path .\OmniDiagData\sessions\session-20261018-101500.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path)

    if (Get-Command Write-OmniDeprecationWarning -ErrorAction SilentlyContinue) {
        Write-OmniDeprecationWarning -Name 'Import-OmniSession' -Replacement 'Import-OmniDiagSession'
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Saved session not found: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        $item = Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $item) { throw "No JSON report found in folder: $Path" }
    }

    # Size cap before anything is read (a .zip is checked by the length of its data.json text below).
    if ($item.Extension -ne '.zip' -and $item.Length -gt $script:OmniSessionImportMaxBytes) {
        throw (New-OmniSessionImportError -Path $item.FullName -Message ("Saved session is too large: {0} bytes (the limit is {1} MB): {2}" -f
            $item.Length, ($script:OmniSessionImportMaxBytes / 1MB), $item.FullName))
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

    # Everything below either returns a well-formed session or throws exactly one error
    # type: System.IO.InvalidDataException with error id OmniDiag.SessionImportInvalid.
    try {
        $session = ConvertFrom-OmniSessionJson -Json $json -SourcePath $item.FullName
    } catch {
        if ($_.Exception -is [System.IO.InvalidDataException]) { throw $_ }
        throw (New-OmniSessionImportError -Path $item.FullName -Inner $_.Exception -Message ("Not a valid OmniDiag session or report: {0} ({1})" -f $item.FullName, $_.Exception.Message))
    }
    Add-Member -InputObject $session -MemberType NoteProperty -Name SourcePath -Value $item.FullName -Force
    return $session
}

# ---------------------------------------------------------------------------
# Session import: parsing and validation
# ---------------------------------------------------------------------------

# Files larger than this are rejected before they are read; nesting deeper than this is
# rejected before the JSON is parsed (saved sessions are at most ~20 levels deep).
$script:OmniSessionImportMaxBytes = 64MB
$script:OmniSessionImportMaxDepth = 100

function New-OmniSessionImportError {
    <#
    .SYNOPSIS
        Internal: the one error Import-OmniSession throws for content it cannot load - an
        ErrorRecord with a System.IO.InvalidDataException, error id
        OmniDiag.SessionImportInvalid, category InvalidData.
    #>
    param([string] $Message, [string] $Path, [System.Exception] $Inner)
    if ($Inner) { $ex = [System.IO.InvalidDataException]::new($Message, $Inner) } else { $ex = [System.IO.InvalidDataException]::new($Message) }
    return [System.Management.Automation.ErrorRecord]::new($ex, 'OmniDiag.SessionImportInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $Path)
}

function Test-OmniJsonNestingDepth {
    <#
    .SYNOPSIS
        Internal: $true when the JSON text nests objects/arrays no deeper than MaxDepth.

    .DESCRIPTION
        Runs before ConvertFrom-Json, so a hostile file (thousands of nested brackets)
        is rejected the same way on Windows PowerShell 5.1 and PowerShell 7 and never
        reaches a recursive parser. String literals are removed first (brackets inside
        strings do not nest); the atomic group and the optional closing quote keep that
        pass linear even for an unterminated string. What remains is reduced to its
        brackets, and innermost pairs are removed once per level.
    #>
    param([string] $Json, [int] $MaxDepth)
    $timeout = [TimeSpan]::FromSeconds(30)
    $none = [System.Text.RegularExpressions.RegexOptions]::None
    $skeleton = [regex]::Replace($Json, '"(?>(?:[^"\\]+|\\[\s\S])*)"?', '', $none, $timeout)
    $skeleton = [regex]::Replace($skeleton, '[^\[\]{}]+', '', $none, $timeout)
    $run = '[\[{]{' + ($MaxDepth + 1) + '}'
    for ($level = 0; $level -le $MaxDepth; $level++) {
        if ($skeleton.Length -eq 0) { return $true }
        if ([regex]::IsMatch($skeleton, $run, $none, $timeout)) { return $false }
        $next = [regex]::Replace($skeleton, '\{\}|\[\]', '', $none, $timeout)
        # Unbalanced brackets: not valid JSON; ConvertFrom-Json reports it.
        if ($next.Length -eq $skeleton.Length) { return $true }
        $skeleton = $next
    }
    return ($skeleton.Length -eq 0)
}

function Test-OmniImportScalar {
    <# .SYNOPSIS Internal: $true for a JSON scalar as ConvertFrom-Json returns it (or $null). #>
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [datetime] -or $Value -is [System.DateTimeOffset]) { return $true }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) { return $true }
    if ($Value.GetType().FullName -eq 'System.Numerics.BigInteger') { return $true }
    # Windows PowerShell 5.1's ConvertTo-Json writes a date from Get-Date (or a string that
    # carries extended properties) as { "value": ..., "DisplayHint": ..., ... }: native
    # sessions saved there contain such wrappers, so they count as a scalar.
    if ($Value -is [System.Management.Automation.PSCustomObject] -and $Value.PSObject.Properties['value']) {
        $inner = $Value.PSObject.Properties['value'].Value
        return ($null -eq $inner -or $inner -is [string] -or $inner -is [bool] -or $inner -is [datetime] -or $inner -is [int] -or
            $inner -is [long] -or $inner -is [double] -or $inner -is [decimal])
    }
    return $false
}

function Get-OmniImportTypeName {
    <# .SYNOPSIS Internal: 'an array' / 'an object' / 'a string' ... for validation messages. #>
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return 'a string' }
    if ($Value -is [array]) { return 'an array' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'an object' }
    return ('a {0}' -f $Value.GetType().Name)
}

function Assert-OmniImportShape {
    <#
    .SYNOPSIS
        Internal: checks the members of one parsed JSON object against a shape spec and
        throws an import error naming the first member of the wrong type.

    .PARAMETER Spec
        Member name -> 'scalar' | 'object' | 'array' | 'any'. 'object' and 'array' allow
        null; a member listed in -Required must be present and not null.
    #>
    param($Value, [string] $Where, [hashtable] $Spec, [string[]] $Required = @(), [string] $SourcePath)
    if ($Value -isnot [System.Management.Automation.PSCustomObject]) {
        throw (New-OmniSessionImportError -Path $SourcePath -Message ("{0} must be an object, found {1}: {2}" -f $Where, (Get-OmniImportTypeName $Value), $SourcePath))
    }
    foreach ($name in $Required) {
        $p = $Value.PSObject.Properties[$name]
        if (-not $p -or $null -eq $p.Value) {
            throw (New-OmniSessionImportError -Path $SourcePath -Message ("{0}.{1} is missing: {2}" -f $Where, $name, $SourcePath))
        }
    }
    foreach ($name in @($Spec.Keys)) {
        $p = $Value.PSObject.Properties[$name]
        if (-not $p) { continue }
        $v = $p.Value
        $ok = switch ($Spec[$name]) {
            'scalar' { Test-OmniImportScalar $v }
            'object' { $null -eq $v -or $v -is [System.Management.Automation.PSCustomObject] }
            'array'  { $null -eq $v -or $v -is [array] }
            default  { $true }
        }
        if (-not $ok) {
            $want = switch ($Spec[$name]) { 'scalar' { 'a string, number, boolean, or null' } 'object' { 'an object or null' } default { 'an array or null' } }
            throw (New-OmniSessionImportError -Path $SourcePath -Message ("{0}.{1} must be {2}, found {3}: {4}" -f $Where, $name, $want, (Get-OmniImportTypeName $v), $SourcePath))
        }
    }
}

function Assert-OmniImportedReportV1 {
    <# .SYNOPSIS Internal: validates the shape of a parsed schema v1 report before it is rebuilt. #>
    param($Doc, [string] $SourcePath)
    if ($Doc.schemaVersion -isnot [string]) {
        throw (New-OmniSessionImportError -Path $SourcePath -Message ("schemaVersion must be a string such as '1.1.0', found {0}: {1}" -f (Get-OmniImportTypeName $Doc.schemaVersion), $SourcePath))
    }
    if ($Doc.schemaVersion -notmatch '^1\.\d+\.\d+$') {
        throw (New-OmniSessionImportError -Path $SourcePath -Message ("Unsupported OmniDiag report schemaVersion '{0}'. This version of OmniDiag reads 1.x reports: {1}" -f $Doc.schemaVersion, $SourcePath))
    }
    Assert-OmniImportShape -Value $Doc -Where 'report' -SourcePath $SourcePath -Required @('modules') -Spec @{
        tool = 'object'; generatedAt = 'scalar'; host = 'object'; options = 'object'; scan = 'object'; summary = 'object'; modules = 'array'
    }
    if ($null -ne $Doc.PSObject.Properties['host'] -and $null -ne $Doc.host) {
        Assert-OmniImportShape -Value $Doc.host -Where 'host' -SourcePath $SourcePath -Spec @{ computerName = 'scalar'; userName = 'scalar'; isAdmin = 'scalar'; psVersion = 'scalar' }
    }
    if ($null -ne $Doc.PSObject.Properties['scan'] -and $null -ne $Doc.scan) {
        Assert-OmniImportShape -Value $Doc.scan -Where 'scan' -SourcePath $SourcePath -Spec @{
            startedAt = 'scalar'; finishedAt = 'scalar'; durationMs = 'scalar'; cancelled = 'scalar'; timeRange = 'object'; plan = 'object'
        }
        if ($null -ne $Doc.scan.PSObject.Properties['timeRange'] -and $null -ne $Doc.scan.timeRange) {
            Assert-OmniImportShape -Value $Doc.scan.timeRange -Where 'scan.timeRange' -SourcePath $SourcePath -Spec @{ preset = 'scalar'; label = 'scalar'; start = 'scalar'; end = 'scalar' }
        }
        if ($null -ne $Doc.scan.PSObject.Properties['plan'] -and $null -ne $Doc.scan.plan) {
            Assert-OmniImportShape -Value $Doc.scan.plan -Where 'scan.plan' -SourcePath $SourcePath -Spec @{ type = 'scalar'; name = 'scalar' }
        }
    }
    if ($null -ne $Doc.PSObject.Properties['summary'] -and $null -ne $Doc.summary) {
        Assert-OmniImportShape -Value $Doc.summary -Where 'summary' -SourcePath $SourcePath -Spec @{ healthScore = 'scalar'; grade = 'scalar'; counts = 'object' }
    }
    $mi = 0
    foreach ($m in @($Doc.modules)) {
        $where = "modules[$mi]"; $mi++
        if ($null -eq $m) { continue }
        Assert-OmniImportShape -Value $m -Where $where -SourcePath $SourcePath -Spec @{
            id = 'scalar'; name = 'scalar'; group = 'scalar'; category = 'scalar'; status = 'scalar'; skippedReason = 'scalar'
            requiresElevation = 'scalar'; startedAt = 'scalar'; durationMs = 'scalar'; error = 'scalar'; metrics = 'object'; findings = 'array'
        }
        $fi = 0
        foreach ($f in @($(if ($m.PSObject.Properties['findings']) { $m.findings }))) {
            $fwhere = "$where.findings[$fi]"; $fi++
            if ($null -eq $f) { continue }
            Assert-OmniImportShape -Value $f -Where $fwhere -SourcePath $SourcePath -Spec @{
                id = 'scalar'; moduleId = 'scalar'; title = 'scalar'; severity = 'scalar'; severityNative = 'scalar'; passed = 'scalar'
                component = 'scalar'; evidence = 'object'; likelyCause = 'scalar'; recommendation = 'scalar'; confidence = 'scalar'
            }
            if ($f.PSObject.Properties['evidence'] -and $null -ne $f.evidence) {
                Assert-OmniImportShape -Value $f.evidence -Where "$fwhere.evidence" -SourcePath $SourcePath -Spec @{ detail = 'scalar'; data = 'any' }
            }
        }
    }
}

function Assert-OmniImportedNativeSession {
    <# .SYNOPSIS Internal: validates the shape of a parsed native session (Save-OmniSession). #>
    param($Session, [string] $SourcePath)
    if (-not $Session.PSObject.Properties['Results']) {
        throw (New-OmniSessionImportError -Path $SourcePath -Message "JSON does not contain an OmniDiag session (no Results): $SourcePath")
    }
    Assert-OmniImportShape -Value $Session -Where 'session' -SourcePath $SourcePath -Required @('Results') -Spec @{
        StartTime = 'scalar'; EndTime = 'scalar'; DurationMs = 'scalar'; Cancelled = 'scalar'; IsAdmin = 'scalar'
        Host = 'object'; TimeRange = 'object'; Summary = 'object'; ScanPlan = 'object'; Results = 'array'
    }
    if ($Session.PSObject.Properties['Host'] -and $null -ne $Session.Host) {
        Assert-OmniImportShape -Value $Session.Host -Where 'session.Host' -SourcePath $SourcePath -Spec @{
            ComputerName = 'scalar'; UserName = 'scalar'; Domain = 'scalar'; DnsDomain = 'scalar'; PSVersion = 'scalar'; OSVersion = 'scalar'
        }
    }
    if ($Session.PSObject.Properties['TimeRange'] -and $null -ne $Session.TimeRange) {
        Assert-OmniImportShape -Value $Session.TimeRange -Where 'session.TimeRange' -SourcePath $SourcePath -Spec @{ Start = 'scalar'; End = 'scalar'; Label = 'scalar'; Preset = 'scalar' }
    }
    if ($Session.PSObject.Properties['ScanPlan'] -and $null -ne $Session.ScanPlan) {
        Assert-OmniImportShape -Value $Session.ScanPlan -Where 'session.ScanPlan' -SourcePath $SourcePath -Spec @{ Type = 'scalar'; Name = 'scalar'; Description = 'scalar' }
    }
    if ($Session.PSObject.Properties['Summary'] -and $null -ne $Session.Summary) {
        Assert-OmniImportShape -Value $Session.Summary -Where 'session.Summary' -SourcePath $SourcePath -Spec @{
            Score = 'scalar'; Grade = 'scalar'; Counts = 'object'; ModulesRun = 'scalar'; TopRecommendations = 'array'
        }
        $ti = 0
        foreach ($t in @($(if ($Session.Summary.PSObject.Properties['TopRecommendations']) { $Session.Summary.TopRecommendations }))) {
            if ($null -ne $t) {
                Assert-OmniImportShape -Value $t -Where "session.Summary.TopRecommendations[$ti]" -SourcePath $SourcePath -Spec @{ Severity = 'scalar'; Title = 'scalar'; Recommendation = 'scalar' }
            }
            $ti++
        }
    }
    $ri = 0
    foreach ($r in @($Session.Results)) {
        $where = "Results[$ri]"; $ri++
        if ($null -eq $r) { continue }
        Assert-OmniImportShape -Value $r -Where $where -SourcePath $SourcePath -Spec @{
            ModuleName = 'scalar'; Category = 'scalar'; Status = 'scalar'; RequiresAdmin = 'scalar'; HadAdmin = 'scalar'
            StartTime = 'scalar'; EndTime = 'scalar'; DurationMs = 'scalar'; Error = 'scalar'; ModuleId = 'scalar'; Group = 'scalar'
            SkippedReason = 'scalar'; Metrics = 'object'; Findings = 'array'
        }
        $fi = 0
        foreach ($f in @($(if ($r.PSObject.Properties['Findings']) { $r.Findings }))) {
            $fwhere = "$where.Findings[$fi]"; $fi++
            if ($null -eq $f) { continue }
            Assert-OmniImportShape -Value $f -Where $fwhere -SourcePath $SourcePath -Spec @{
                Id = 'scalar'; Title = 'scalar'; Severity = 'scalar'; SeverityRank = 'scalar'; Component = 'scalar'; Detail = 'scalar'
                LikelyCause = 'scalar'; Confidence = 'scalar'; Recommendation = 'scalar'; Timestamp = 'scalar'; Data = 'any'
            }
        }
    }
}

function ConvertFrom-OmniSessionJson {
    <#
    .SYNOPSIS
        Internal: JSON text -> validated session (native format or report schema v1).

    .DESCRIPTION
        Rejects, with an import error: text nested deeper than the import limit,
        anything ConvertFrom-Json cannot parse, a document that is not a JSON object,
        an unsupported schemaVersion, a missing Results (native) or modules (v1), and a
        member of the wrong JSON type (a string where an array or object belongs, an
        object where text belongs). Null entries in Results / modules / findings carry no
        data and are skipped. Strings are data: nothing in them is ever evaluated.
    #>
    param([string] $Json, [string] $SourcePath)

    if ($Json.Length -gt $script:OmniSessionImportMaxBytes) {
        throw (New-OmniSessionImportError -Path $SourcePath -Message ("Saved session is too large: {0} characters (the limit is {1} MB): {2}" -f
            $Json.Length, ($script:OmniSessionImportMaxBytes / 1MB), $SourcePath))
    }
    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw (New-OmniSessionImportError -Path $SourcePath -Message "Not a valid OmniDiag JSON report (the file is empty): $SourcePath")
    }
    # A byte order mark the reader did not consume (e.g. a doubled BOM) is not content.
    $Json = $Json.TrimStart([char]0xFEFF)
    # A session is one JSON object. (PowerShell 7 would unroll a top-level array.)
    if (-not [regex]::IsMatch($Json, '\A\s*\{')) {
        throw (New-OmniSessionImportError -Path $SourcePath -Message "JSON does not contain an OmniDiag session (no Results; the document is not a JSON object): $SourcePath")
    }
    if (-not (Test-OmniJsonNestingDepth -Json $Json -MaxDepth $script:OmniSessionImportMaxDepth)) {
        throw (New-OmniSessionImportError -Path $SourcePath -Message ("Not a valid OmniDiag JSON report (nested deeper than {0} levels): {1}" -f $script:OmniSessionImportMaxDepth, $SourcePath))
    }

    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $parsed = ConvertFrom-Json -InputObject $Json -Depth ($script:OmniSessionImportMaxDepth + 2) -ErrorAction Stop
        } else {
            $parsed = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
        }
    } catch {
        throw (New-OmniSessionImportError -Path $SourcePath -Inner $_.Exception -Message ("Not a valid OmniDiag JSON report: {0} ({1})" -f $SourcePath, $_.Exception.Message))
    }
    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        throw (New-OmniSessionImportError -Path $SourcePath -Message "JSON does not contain an OmniDiag session (no Results): $SourcePath")
    }

    # Report schema v1 (Export-OmniJsonReport, report packages from 0.5.0 on).
    if ($parsed.PSObject.Properties['schemaVersion']) {
        Assert-OmniImportedReportV1 -Doc $parsed -SourcePath $SourcePath
        return (ConvertFrom-OmniReportV1 -Report $parsed)
    }

    Assert-OmniImportedNativeSession -Session $parsed -SourcePath $SourcePath

    # Restore live-session shapes the reporters rely on: Metrics is an ordered dictionary
    # (ConvertFrom-Json yields a PSCustomObject) and Results/Findings are arrays.
    $parsed.Results = @($parsed.Results | Where-Object { $null -ne $_ })
    foreach ($result in $parsed.Results) {
        $metrics = [ordered]@{}
        if ($result.PSObject.Properties['Metrics'] -and $result.Metrics) {
            foreach ($p in $result.Metrics.PSObject.Properties) { $metrics[$p.Name] = $p.Value }
        }
        $result | Add-Member -MemberType NoteProperty -Name Metrics -Value $metrics -Force
        $findings = @(if ($result.PSObject.Properties['Findings']) { $result.Findings | Where-Object { $null -ne $_ } })
        $result | Add-Member -MemberType NoteProperty -Name Findings -Value $findings -Force
    }
    return $parsed
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
        Findings are matched by their stable Id. Findings whose auto-generated Id embeds a
        live value (e.g. "High CPU usage (93%)") are then paired by Component plus the title
        with numbers masked, so a changed measurement reads as Persisting, not Resolved + New.
        Non-pass findings are classified as
        Resolved (only before), New (only after), or Persisting (both, with a
        severity change of Improved / Worsened / Unchanged). Health score and
        per-module status deltas are included, plus an overall Verdict.

    .PARAMETER Before
        Earlier session, or a path to a saved JSON report / package.

    .PARAMETER After
        Later session, or a path to a saved JSON report / package.

    .NOTES
        Deprecated as a user-facing name in 0.8.0: use Compare-OmniDiagSession.

    .EXAMPLE
        Compare-OmniSession -Before .\before.json -After .\after.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object] $Before,
        [Parameter(Mandatory)][object] $After
    )

    if (Get-Command Write-OmniDeprecationWarning -ErrorAction SilentlyContinue) {
        Write-OmniDeprecationWarning -Name 'Compare-OmniSession' -Replacement 'Compare-OmniDiagSession'
    }

    if ($Before -is [string]) { $Before = Import-OmniSession -Path $Before }
    if ($After -is [string]) { $After = Import-OmniSession -Path $After }

    # Only modules that actually ran in BOTH sessions are comparable: a finding from a
    # scanner the second scan didn't run (different workflow, admin-only skip) is not "resolved".
    $statusOf = { param($s) $m = @{}; foreach ($r in @($s.Results)) { if ($r) { $m[[string]$r.ModuleName] = [string]$r.Status } }; $m }
    $bs = & $statusOf $Before; $as = & $statusOf $After
    $ranIn = { param($m, $name) $m.ContainsKey($name) -and $m[$name] -notin @('Skipped', 'Failed') }
    $comparable = @{}
    foreach ($name in $bs.Keys) { if ((& $ranIn $bs $name) -and (& $ranIn $as $name)) { $comparable[$name] = $true } }
    $outOfScope = [System.Collections.Generic.List[object]]::new()

    $index = {
        param($Session)
        $map = [ordered]@{}
        foreach ($f in @(Get-OmniSessionFinding -Session $Session)) {
            if (-not $comparable.ContainsKey($f.ModuleName)) { $outOfScope.Add($f); continue }
            # Keep the most severe occurrence when an Id repeats.
            if (-not $map.Contains($f.Id) -or (Get-OmniSeverityRank $f.Severity) -gt (Get-OmniSeverityRank $map[$f.Id].Severity)) { $map[$f.Id] = $f }
        }
        return $map
    }
    $b = & $index $Before
    $a = & $index $After

    # Pair by Id first, then by Component + number-masked title for Ids that embed live values.
    $signature = { param($f) ('{0}|{1}' -f $f.Component, ($f.Title -replace '\d+([.,]\d+)?', '#')).ToLowerInvariant() }
    $pairs = [System.Collections.Generic.List[object]]::new()
    $unmatchedBefore = [System.Collections.Generic.List[object]]::new()
    $afterUsed = @{}
    foreach ($id in $b.Keys) {
        if ($a.Contains($id)) { $pairs.Add(@($b[$id], $a[$id])); $afterUsed[$id] = $true } else { $unmatchedBefore.Add($b[$id]) }
    }
    $afterBySignature = @{}
    foreach ($id in $a.Keys) {
        if ($afterUsed.ContainsKey($id)) { continue }
        $sig = & $signature $a[$id]
        if (-not $afterBySignature.ContainsKey($sig)) { $afterBySignature[$sig] = [System.Collections.Generic.Queue[object]]::new() }
        $afterBySignature[$sig].Enqueue($a[$id])
    }
    $resolved = @(foreach ($f in $unmatchedBefore) {
        $sig = & $signature $f
        if ($afterBySignature.ContainsKey($sig) -and $afterBySignature[$sig].Count -gt 0) {
            $match = $afterBySignature[$sig].Dequeue(); $afterUsed[$match.Id] = $true; $pairs.Add(@($f, $match))
        } else { $f }
    })
    $new = @(foreach ($id in $a.Keys) { if (-not $afterUsed.ContainsKey($id)) { $a[$id] } })
    $persisting = @(foreach ($pair in $pairs) {
        $was = $pair[0]; $now = $pair[1]
        $delta = (Get-OmniSeverityRank $now.Severity) - (Get-OmniSeverityRank $was.Severity)
        [pscustomobject]@{
            PSTypeName = 'OmniDiag.FindingChange'; Id = $now.Id; Title = $now.Title; Component = $now.Component
            BeforeSeverity = $was.Severity; AfterSeverity = $now.Severity; BeforeTitle = $was.Title
            Change = $(if ($delta -lt 0) { 'Improved' } elseif ($delta -gt 0) { 'Worsened' } else { 'Unchanged' })
        }
    })

    $scoreOf = { param($s) if ($s.PSObject.Properties['Summary'] -and $s.Summary -and $s.Summary.PSObject.Properties['Score']) { [int]$s.Summary.Score } else { $null } }
    $beforeScore = & $scoreOf $Before
    $afterScore = & $scoreOf $After
    $scoreDelta = if ($null -ne $beforeScore -and $null -ne $afterScore) { $afterScore - $beforeScore } else { $null }

    $moduleChanges = @(foreach ($name in (@($bs.Keys) + @($as.Keys) | Sort-Object -Unique)) {
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
        BeforeTime    = $(if ($Before.PSObject.Properties['StartTime']) { $Before.StartTime })
        AfterTime     = $(if ($After.PSObject.Properties['StartTime']) { $After.StartTime })
        BeforeScore   = $beforeScore
        AfterScore    = $afterScore
        ScoreDelta    = $scoreDelta
        Verdict       = $verdict
        # Findings from modules that did not run (successfully) in both sessions - not compared.
        OutOfScope    = @($outOfScope)
        Resolved      = @($resolved | Sort-Object @{ Expression = { Get-OmniSeverityRank $_.Severity }; Descending = $true }, Id)
        New           = @($new | Sort-Object @{ Expression = { Get-OmniSeverityRank $_.Severity }; Descending = $true }, Id)
        Persisting    = @($persisting)
        ModuleChanges = $moduleChanges
    }
}

Export-ModuleMember -Function @('Get-OmniSessionFinding', 'Save-OmniSession', 'Import-OmniSession', 'Search-OmniEvidence', 'Compare-OmniSession')
