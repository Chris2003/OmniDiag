<#
.SYNOPSIS
    OmniDiag report schema v1: the versioned JSON projection of a session.

.DESCRIPTION
    ConvertTo-OmniReportV1 projects an in-memory OmniDiag.Session into the public,
    versioned report document described by schemas/omnidiag-report.v1.json
    (JSON Schema 2020-12). The session itself is never changed; the projection
    happens at the export boundary.

    Guarantees:
      * deterministic property order (ordered dictionaries all the way down; plain
        hashtables in finding data are emitted with sorted keys),
      * ISO-8601 UTC timestamps ('yyyy-MM-ddTHH:mm:ss.fffZ'),
      * the v1 severity scale (Info / Warning / Critical) with the native five-level
        value kept in severityNative,
      * identical text on Windows PowerShell 5.1 and PowerShell 7: the document is
        written by ConvertTo-OmniJsonText (not ConvertTo-Json), which is ASCII-only
        (non-ASCII characters are \u-escaped) and culture-invariant.

    ConvertFrom-OmniReportV1 rebuilds a session-shaped object from a v1 document,
    good enough for Compare-OmniSession, the exit-code helper, and every report
    exporter. Import-OmniSession uses it when a file carries schemaVersion.

    Severity mapping (decision 4): Pass -> Info (passed = true); Information -> Info;
    Warning -> Warning; Error -> Critical; Critical -> Critical.
#>

Set-StrictMode -Version Latest

$script:OmniReportSchemaVersion = '1.1.0'
$script:OmniToolVersionCache = $null
$script:OmniPlainDataMaxDepth = 12

$script:OmniNativeSeverityRank = @{ Pass = 0; Information = 1; Warning = 2; Error = 3; Critical = 4 }
$script:OmniV1SeverityMap = @{ Pass = 'Info'; Information = 'Info'; Warning = 'Warning'; Error = 'Critical'; Critical = 'Critical' }

$script:OmniNumericTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    'System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16', 'System.Int32', 'System.UInt32',
    'System.Int64', 'System.UInt64', 'System.Single', 'System.Double', 'System.Decimal'
))

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Get-OmniReportSchemaVersion {
    <# .SYNOPSIS Returns the report schema version this OmniDiag writes ('1.1.0'). #>
    [OutputType([string])]
    param()
    return $script:OmniReportSchemaVersion
}

function Get-OmniV1ToolVersion {
    <# .SYNOPSIS Internal: OmniDiag version from the module manifest (cached). #>
    if (-not $script:OmniToolVersionCache) {
        try {
            $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'OmniDiag.psd1'
            $script:OmniToolVersionCache = [string](Import-PowerShellDataFile -Path $manifest).ModuleVersion
        } catch { $script:OmniToolVersionCache = '0.0.0' }
    }
    return $script:OmniToolVersionCache
}

function Get-OmniV1Value {
    <# .SYNOPSIS Internal: StrictMode-safe read of a property / dictionary key. #>
    param($InputObject, [string] $Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name) -and $null -ne $InputObject[$Name]) { return $InputObject[$Name] }
        return $Default
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function ConvertTo-OmniIsoTimestamp {
    <#
    .SYNOPSIS
        Formats a date as ISO-8601 UTC with milliseconds ('2026-06-01T08:00:00.000Z').

    .DESCRIPTION
        Accepts DateTime, DateTimeOffset, ISO strings, and the '/Date(ms)/' form that
        Windows PowerShell 5.1 writes. Returns $null for anything unparseable.
    #>
    [OutputType([string])]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    $fmt = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) { $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Local) }
        return $dt.ToUniversalTime().ToString($fmt, $inv)
    }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).UtcDateTime.ToString($fmt, $inv) }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $m = [regex]::Match($s, '^/Date\((-?\d+)([+-]\d{4})?\)/$')
    if ($m.Success) {
        return [System.DateTimeOffset]::FromUnixTimeMilliseconds([int64]$m.Groups[1].Value).UtcDateTime.ToString($fmt, $inv)
    }
    $parsed = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse($s, $inv, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString($fmt, $inv)
    }
    return $null
}

function ConvertFrom-OmniIsoTimestamp {
    <# .SYNOPSIS Internal: v1 timestamp (string or DateTime) -> local DateTime, or $null. #>
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) { return $dt.ToLocalTime() }
        return $dt
    }
    $iso = ConvertTo-OmniIsoTimestamp -Value $Value
    if (-not $iso) { return $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    return [datetime]::Parse($iso, $inv, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal).ToLocalTime()
}

function ConvertTo-OmniV1Severity {
    <#
    .SYNOPSIS
        Maps a native severity (Pass, Information, Warning, Error, Critical) to the v1
        scale (Info, Warning, Critical). Unknown values map to Info.
    #>
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string] $Severity)
    if ($Severity -and $script:OmniV1SeverityMap.ContainsKey($Severity)) { return $script:OmniV1SeverityMap[$Severity] }
    return 'Info'
}

function Get-OmniSortedKey {
    <# .SYNOPSIS Internal: dictionary keys in ordinal (culture-independent) order. #>
    param([object[]] $Key)
    $map = @{}
    foreach ($k in $Key) { $map[[string]$k] = $k }
    $names = [string[]]@($map.Keys)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    foreach ($n in $names) { $map[$n] }
}

function ConvertTo-OmniPlainData {
    <#
    .SYNOPSIS
        Converts an arbitrary object graph to JSON-ready plain data.

    .DESCRIPTION
        Produces only $null, strings, booleans, numbers, ordered dictionaries, and
        object arrays, so ConvertTo-OmniJsonText output is deterministic: dates become
        ISO-8601 UTC strings, enums and other scalars become strings, plain hashtables
        get sorted keys, and objects become ordered property maps. Depth is bounded
        (deeper values are rendered with ToString()).
    #>
    [CmdletBinding()]
    param([AllowNull()] $InputObject, [int] $Depth = 0)

    if ($null -eq $InputObject) { return $null }
    $value = $InputObject
    if ($value -is [System.Management.Automation.PSObject] -and $value.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
        $value = $value.PSObject.BaseObject
    }

    if ($value -is [string]) { return [string]$value }
    if ($value -is [char]) { return [string]$value }
    if ($value -is [bool]) { return [bool]$value }
    if ($value -is [datetime] -or $value -is [System.DateTimeOffset]) { return (ConvertTo-OmniIsoTimestamp -Value $value) }
    if ($value -is [enum]) { return $value.ToString() }
    if ($script:OmniNumericTypes.Contains($value.GetType().FullName)) {
        if (($value -is [double] -or $value -is [single]) -and ([double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value))) { return $null }
        return $value
    }
    if ($value -is [timespan]) { return ([timespan]$value).ToString('c', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($value -is [guid] -or $value -is [version] -or $value -is [uri] -or $value -is [System.Net.IPAddress] -or $value -is [scriptblock]) {
        return $value.ToString()
    }

    if ($Depth -ge $script:OmniPlainDataMaxDepth) { return [string]$value }

    if ($value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        $keys = @($value.Keys)
        if ($value -isnot [System.Collections.Specialized.OrderedDictionary]) { $keys = @(Get-OmniSortedKey -Key $keys) }
        foreach ($k in $keys) { $out[[string]$k] = ConvertTo-OmniPlainData -InputObject $value[$k] -Depth ($Depth + 1) }
        return $out
    }

    if ($value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $value) { $list.Add((ConvertTo-OmniPlainData -InputObject $item -Depth ($Depth + 1))) }
        return , $list.ToArray()
    }

    $out = [ordered]@{}
    if ($value -is [System.Management.Automation.PSCustomObject]) {
        $props = @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property', 'AliasProperty') })
    } else {
        $props = @($value.PSObject.Properties | Where-Object { $_.MemberType -eq 'Property' -and $_.IsGettable })
    }
    foreach ($p in $props) {
        $v = $null
        try { $v = $p.Value } catch { $v = $null }
        $out[[string]$p.Name] = ConvertTo-OmniPlainData -InputObject $v -Depth ($Depth + 1)
    }
    return $out
}

function ConvertTo-OmniJsonString {
    <# .SYNOPSIS Internal: JSON string literal, ASCII-only (\u-escapes outside 0x20-0x7E). #>
    param([AllowEmptyString()][string] $Value)
    if ($Value -cmatch '^[\x20-\x21\x23-\x5B\x5D-\x7E]*$') { return '"' + $Value + '"' }
    $escaped = [regex]::Replace($Value, '[^\x20-\x21\x23-\x5B\x5D-\x7E]', {
        param($m)
        $c = [int][char]$m.Value
        switch ($c) {
            0x22 { return '\"' }
            0x5C { return '\\' }
            0x08 { return '\b' }
            0x0C { return '\f' }
            0x0A { return '\n' }
            0x0D { return '\r' }
            0x09 { return '\t' }
            default { return ('\u{0:x4}' -f $c) }
        }
    })
    return '"' + $escaped + '"'
}

function Write-OmniJsonNode {
    <# .SYNOPSIS Internal: appends one plain-data value to a StringBuilder as JSON. #>
    param([System.Text.StringBuilder] $Builder, [AllowNull()] $Value, [int] $Level, [bool] $Compress)

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { [void]$Builder.Append('null'); return }
    if ($Value -is [System.Management.Automation.PSObject] -and $Value.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
        $Value = $Value.PSObject.BaseObject
    }
    if ($Value -is [string]) { [void]$Builder.Append((ConvertTo-OmniJsonString -Value $Value)); return }
    if ($Value -is [bool]) { [void]$Builder.Append($(if ($Value) { 'true' } else { 'false' })); return }
    if ($script:OmniNumericTypes.Contains($Value.GetType().FullName)) {
        if ($Value -is [double] -or $Value -is [single]) {
            $d = [double]$Value
            if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { [void]$Builder.Append('null') }
            else { [void]$Builder.Append($d.ToString('R', $inv)) }
        } else {
            [void]$Builder.Append(([System.IFormattable]$Value).ToString($null, $inv))
        }
        return
    }

    $newline = if ($Compress) { '' } else { "`n" }
    $pad = if ($Compress) { '' } else { '  ' * ($Level + 1) }
    $closePad = if ($Compress) { '' } else { '  ' * $Level }
    $colon = if ($Compress) { ':' } else { ': ' }

    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        # Built explicitly: a one-pair array returned from an 'if' would be unrolled.
        $pairs = [System.Collections.Generic.List[object[]]]::new()
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($k in @($Value.Keys)) { $pairs.Add([object[]]@([string]$k, $Value[$k])) }
        } else {
            foreach ($p in $Value.PSObject.Properties) { $pairs.Add([object[]]@([string]$p.Name, $p.Value)) }
        }
        if ($pairs.Count -eq 0) { [void]$Builder.Append('{}'); return }
        [void]$Builder.Append('{').Append($newline)
        for ($i = 0; $i -lt $pairs.Count; $i++) {
            [void]$Builder.Append($pad).Append((ConvertTo-OmniJsonString -Value $pairs[$i][0])).Append($colon)
            Write-OmniJsonNode -Builder $Builder -Value $pairs[$i][1] -Level ($Level + 1) -Compress $Compress
            if ($i -lt $pairs.Count - 1) { [void]$Builder.Append(',') }
            [void]$Builder.Append($newline)
        }
        [void]$Builder.Append($closePad).Append('}')
        return
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { [void]$Builder.Append('[]'); return }
        [void]$Builder.Append('[').Append($newline)
        for ($i = 0; $i -lt $items.Count; $i++) {
            [void]$Builder.Append($pad)
            Write-OmniJsonNode -Builder $Builder -Value $items[$i] -Level ($Level + 1) -Compress $Compress
            if ($i -lt $items.Count - 1) { [void]$Builder.Append(',') }
            [void]$Builder.Append($newline)
        }
        [void]$Builder.Append($closePad).Append(']')
        return
    }

    [void]$Builder.Append((ConvertTo-OmniJsonString -Value ([string]$Value)))
}

function ConvertTo-OmniJsonText {
    <#
    .SYNOPSIS
        Serializes an object graph to deterministic, ASCII-only JSON text.

    .DESCRIPTION
        The input is normalized with ConvertTo-OmniPlainData first, then written with
        two-space indentation and LF line endings (or compact with -Compress). Output
        is byte-identical on Windows PowerShell 5.1 and PowerShell 7, which is what
        the golden-file tests rely on.

    .PARAMETER InputObject
        Any object; typically the result of ConvertTo-OmniReportV1.

    .PARAMETER Compress
        Emit a single line with no insignificant whitespace.

    .EXAMPLE
        ConvertTo-OmniReportV1 -Session $session | ConvertTo-OmniJsonText
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [AllowNull()] $InputObject,
        [switch] $Compress
    )
    process {
        $plain = ConvertTo-OmniPlainData -InputObject $InputObject
        $sb = [System.Text.StringBuilder]::new()
        Write-OmniJsonNode -Builder $sb -Value $plain -Level 0 -Compress ([bool]$Compress)
        return $sb.ToString()
    }
}

# ---------------------------------------------------------------------------
# Session -> v1
# ---------------------------------------------------------------------------

function ConvertTo-OmniReportV1Finding {
    <# .SYNOPSIS Internal: one native finding -> v1 finding (ordered). #>
    param($Finding, [string] $ModuleId)
    $native = [string](Get-OmniV1Value $Finding 'Severity' 'Information')
    if (-not $script:OmniNativeSeverityRank.ContainsKey($native)) { $native = 'Information' }
    $title = [string](Get-OmniV1Value $Finding 'Title' '')
    $component = [string](Get-OmniV1Value $Finding 'Component' 'General')
    $id = [string](Get-OmniV1Value $Finding 'Id' '')
    if (-not $id) { $id = ((('{0}|{1}' -f $component, $title).ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')) }
    if (-not $id) { $id = 'finding' }
    $confidence = 0
    [void][int]::TryParse([string](Get-OmniV1Value $Finding 'Confidence' 0), [ref]$confidence)
    if ($confidence -lt 0) { $confidence = 0 } elseif ($confidence -gt 100) { $confidence = 100 }

    return [ordered]@{
        id             = $id
        moduleId       = $ModuleId
        title          = $title
        severity       = (ConvertTo-OmniV1Severity -Severity $native)
        severityNative = $native
        passed         = ($native -eq 'Pass')
        component      = $component
        evidence       = [ordered]@{
            detail = [string](Get-OmniV1Value $Finding 'Detail' '')
            data   = (ConvertTo-OmniPlainData -InputObject (Get-OmniV1Value $Finding 'Data' $null))
        }
        likelyCause    = [string](Get-OmniV1Value $Finding 'LikelyCause' '')
        recommendation = [string](Get-OmniV1Value $Finding 'Recommendation' '')
        confidence     = $confidence
    }
}

function ConvertTo-OmniReportV1 {
    <#
    .SYNOPSIS
        Projects an OmniDiag session into the versioned report document (schema v1).

    .DESCRIPTION
        Returns an ordered dictionary shaped as schemas/omnidiag-report.v1.json:
        schemaVersion, tool, generatedAt, host, options, scan, summary, modules[].
        Each module carries its stable contract-v1 id and group (derived for sessions
        saved before 0.5.0), status, skip reason, timing, metrics, and findings; each
        finding carries the v1 severity plus severityNative and passed. The session
        is not modified. Serialize with ConvertTo-OmniJsonText.

    .PARAMETER Session
        A live, imported, or rebuilt OmniDiag.Session.

    .PARAMETER Option
        Free-form run options recorded verbatim under 'options' (keys sorted), e.g.
        @{ command = 'scan'; groups = @('network') }. When the session is a redacted
        copy (it carries Redacted = $true, see Export-OmniReport -Redact), the options
        also get redacted = true (schema 1.1.0).

    .PARAMETER GeneratedAt
        Override the generation time (tests use a fixed value). Default: now.

    .EXAMPLE
        ConvertTo-OmniReportV1 -Session $session | ConvertTo-OmniJsonText | Set-Content report.json
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [object] $Session,
        [hashtable] $Option,
        [datetime] $GeneratedAt = (Get-Date)
    )

    $sessionHost = Get-OmniV1Value $Session 'Host' $null
    $isAdmin = [bool](Get-OmniV1Value $Session 'IsAdmin' $false)

    $optionSource = @{}
    if ($Option) { foreach ($k in @($Option.Keys)) { $optionSource[$k] = $Option[$k] } }
    if ([bool](Get-OmniV1Value $Session 'Redacted' $false)) { $optionSource['redacted'] = $true }
    $options = [ordered]@{}
    foreach ($k in @(Get-OmniSortedKey -Key @($optionSource.Keys))) {
        $options[[string]$k] = ConvertTo-OmniPlainData -InputObject $optionSource[$k]
    }

    $timeRange = Get-OmniV1Value $Session 'TimeRange' $null
    $plan = Get-OmniV1Value $Session 'ScanPlan' $null
    $durationMs = 0
    [void][int]::TryParse([string](Get-OmniV1Value $Session 'DurationMs' 0), [ref]$durationMs)
    $scan = [ordered]@{
        startedAt  = (ConvertTo-OmniIsoTimestamp -Value (Get-OmniV1Value $Session 'StartTime' $null))
        finishedAt = (ConvertTo-OmniIsoTimestamp -Value (Get-OmniV1Value $Session 'EndTime' $null))
        durationMs = $durationMs
        cancelled  = [bool](Get-OmniV1Value $Session 'Cancelled' $false)
        timeRange  = $(if ($timeRange) {
            [ordered]@{
                preset = [string](Get-OmniV1Value $timeRange 'Preset' '')
                label  = [string](Get-OmniV1Value $timeRange 'Label' '')
                start  = (ConvertTo-OmniIsoTimestamp -Value (Get-OmniV1Value $timeRange 'Start' $null))
                end    = (ConvertTo-OmniIsoTimestamp -Value (Get-OmniV1Value $timeRange 'End' $null))
            }
        } else { $null })
        plan       = $(if ($plan) {
            [ordered]@{ type = [string](Get-OmniV1Value $plan 'Type' ''); name = [string](Get-OmniV1Value $plan 'Name' '') }
        } else { $null })
    }

    $counts = [ordered]@{ info = 0; warning = 0; critical = 0; passed = 0 }
    $modules = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @(Get-OmniV1Value $Session 'Results' @())) {
        if ($null -eq $r) { continue }
        $name = [string](Get-OmniV1Value $r 'ModuleName' '')
        $identity = Resolve-OmniModuleIdentity -Name $name -ModuleId ([string](Get-OmniV1Value $r 'ModuleId' '')) -Group ([string](Get-OmniV1Value $r 'Group' ''))
        $status = [string](Get-OmniV1Value $r 'Status' 'Unknown')
        $requiresAdmin = [bool](Get-OmniV1Value $r 'RequiresAdmin' $false)
        $skippedReason = [string](Get-OmniV1Value $r 'SkippedReason' '')
        if (-not $skippedReason -and $status -eq 'Skipped' -and $requiresAdmin -and -not [bool](Get-OmniV1Value $r 'HadAdmin' $false)) {
            $skippedReason = 'RequiresElevation'
        }
        $moduleMs = 0
        [void][int]::TryParse([string](Get-OmniV1Value $r 'DurationMs' 0), [ref]$moduleMs)
        $errorText = [string](Get-OmniV1Value $r 'Error' '')

        $findings = [System.Collections.Generic.List[object]]::new()
        foreach ($f in @(Get-OmniV1Value $r 'Findings' @())) {
            if ($null -eq $f) { continue }
            $vf = ConvertTo-OmniReportV1Finding -Finding $f -ModuleId $identity.Id
            if ($vf.passed) { $counts.passed++ }
            elseif ($vf.severity -eq 'Critical') { $counts.critical++ }
            elseif ($vf.severity -eq 'Warning') { $counts.warning++ }
            else { $counts.info++ }
            $findings.Add($vf)
        }

        $modules.Add([ordered]@{
            id                = $identity.Id
            name              = $name
            group             = $identity.Group
            category          = [string](Get-OmniV1Value $r 'Category' '')
            status            = $status
            skippedReason     = $(if ($skippedReason) { $skippedReason } else { $null })
            requiresElevation = $requiresAdmin
            startedAt         = (ConvertTo-OmniIsoTimestamp -Value (Get-OmniV1Value $r 'StartTime' $null))
            durationMs        = $moduleMs
            error             = $(if ($errorText) { $errorText } else { $null })
            metrics           = (ConvertTo-OmniPlainData -InputObject (Get-OmniV1Value $r 'Metrics' ([ordered]@{})))
            findings          = $findings.ToArray()
        })
    }

    $summary = Get-OmniV1Value $Session 'Summary' $null
    $score = $null
    if ($summary) {
        $s = 0
        if ([int]::TryParse([string](Get-OmniV1Value $summary 'Score' ''), [ref]$s)) { $score = [math]::Max(0, [math]::Min(100, $s)) }
    }
    $grade = $null
    if ($summary) {
        $g = [string](Get-OmniV1Value $summary 'Grade' '')
        if ($g -in @('Healthy', 'Warning', 'Critical')) { $grade = $g }
    }
    if (-not $grade -and $null -ne $score) {
        $grade = if ($score -ge 80) { 'Healthy' } elseif ($score -ge 50) { 'Warning' } else { 'Critical' }
    }

    return [ordered]@{
        schemaVersion = $script:OmniReportSchemaVersion
        tool          = [ordered]@{ name = 'OmniDiag'; version = (Get-OmniV1ToolVersion) }
        generatedAt   = (ConvertTo-OmniIsoTimestamp -Value $GeneratedAt)
        host          = [ordered]@{
            computerName = [string](Get-OmniV1Value $sessionHost 'ComputerName' '')
            userName     = [string](Get-OmniV1Value $sessionHost 'UserName' '')
            isAdmin      = $isAdmin
            psVersion    = [string](Get-OmniV1Value $sessionHost 'PSVersion' '')
        }
        options       = $options
        scan          = $scan
        summary       = [ordered]@{
            healthScore = $score
            grade       = $grade
            counts      = $counts
        }
        modules       = $modules.ToArray()
    }
}

# ---------------------------------------------------------------------------
# v1 -> session
# ---------------------------------------------------------------------------

function ConvertTo-OmniOrderedMap {
    <# .SYNOPSIS Internal: dictionary / PSCustomObject -> ordered dictionary (top level only). #>
    param($Value)
    $out = [ordered]@{}
    if ($null -eq $Value) { return $out }
    if ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { $out[[string]$k] = $Value[$k] }; return $out }
    foreach ($p in $Value.PSObject.Properties) { $out[$p.Name] = $p.Value }
    return $out
}

function ConvertFrom-OmniReportV1 {
    <#
    .SYNOPSIS
        Rebuilds a session-shaped object from a report schema v1 document.

    .DESCRIPTION
        Accepts the dictionary returned by ConvertTo-OmniReportV1, an object from
        ConvertFrom-Json, or the JSON text itself. Native severities come back from
        severityNative (or are inferred from severity/passed), so health scoring,
        Compare-OmniSession, Get-OmniExitCode, and every exporter work on the result.
        The summary is recomputed from the findings and then pinned to the report's
        healthScore/grade. Throws when the document's major version is not 1.

    .PARAMETER Report
        The v1 document (dictionary / object) or its JSON text.

    .EXAMPLE
        $session = Get-Content report.json -Raw | ConvertFrom-OmniReportV1
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, ValueFromPipeline)] [object] $Report)

    process {
        $doc = $Report
        if ($doc -is [string]) {
            try { $doc = $doc | ConvertFrom-Json -ErrorAction Stop } catch { throw "Not valid JSON: $($_.Exception.Message)" }
        }
        $version = [string](Get-OmniV1Value $doc 'schemaVersion' '')
        if (-not $version) { throw 'Not an OmniDiag v1 report: schemaVersion is missing.' }
        if ($version -notmatch '^1\.\d+\.\d+') { throw "Unsupported OmniDiag report schemaVersion '$version'. This version of OmniDiag reads 1.x reports." }

        $docHost = Get-OmniV1Value $doc 'host' $null
        $scan = Get-OmniV1Value $doc 'scan' $null
        $isAdmin = [bool](Get-OmniV1Value $docHost 'isAdmin' $false)

        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($m in @(Get-OmniV1Value $doc 'modules' @())) {
            if ($null -eq $m) { continue }
            $start = ConvertFrom-OmniIsoTimestamp -Value (Get-OmniV1Value $m 'startedAt' $null)
            $ms = 0
            [void][int]::TryParse([string](Get-OmniV1Value $m 'durationMs' 0), [ref]$ms)
            $end = if ($start) { $start.AddMilliseconds($ms) } else { $null }

            $findings = [System.Collections.Generic.List[object]]::new()
            foreach ($f in @(Get-OmniV1Value $m 'findings' @())) {
                if ($null -eq $f) { continue }
                $native = [string](Get-OmniV1Value $f 'severityNative' '')
                if (-not $script:OmniNativeSeverityRank.ContainsKey($native)) {
                    $native = switch ([string](Get-OmniV1Value $f 'severity' 'Info')) {
                        'Critical' { 'Critical' }
                        'Warning'  { 'Warning' }
                        default    { if ([bool](Get-OmniV1Value $f 'passed' $false)) { 'Pass' } else { 'Information' } }
                    }
                }
                $evidence = Get-OmniV1Value $f 'evidence' $null
                $confidence = 0
                [void][int]::TryParse([string](Get-OmniV1Value $f 'confidence' 0), [ref]$confidence)
                $findings.Add([pscustomobject]@{
                    PSTypeName     = 'OmniDiag.Finding'
                    Id             = [string](Get-OmniV1Value $f 'id' '')
                    Title          = [string](Get-OmniV1Value $f 'title' '')
                    Severity       = $native
                    SeverityRank   = [int]$script:OmniNativeSeverityRank[$native]
                    Component      = [string](Get-OmniV1Value $f 'component' 'General')
                    Detail         = [string](Get-OmniV1Value $evidence 'detail' '')
                    LikelyCause    = [string](Get-OmniV1Value $f 'likelyCause' '')
                    Confidence     = $confidence
                    Recommendation = [string](Get-OmniV1Value $f 'recommendation' '')
                    Data           = (Get-OmniV1Value $evidence 'data' $null)
                    Timestamp      = $start
                })
            }

            $skipped = [string](Get-OmniV1Value $m 'skippedReason' '')
            $errorText = [string](Get-OmniV1Value $m 'error' '')
            $results.Add([pscustomobject]@{
                PSTypeName    = 'OmniDiag.Result'
                ModuleName    = [string](Get-OmniV1Value $m 'name' '')
                Category      = [string](Get-OmniV1Value $m 'category' '')
                Status        = [string](Get-OmniV1Value $m 'status' 'Unknown')
                RequiresAdmin = [bool](Get-OmniV1Value $m 'requiresElevation' $false)
                HadAdmin      = $isAdmin
                StartTime     = $start
                EndTime       = $end
                DurationMs    = $ms
                Findings      = $findings
                Metrics       = (ConvertTo-OmniOrderedMap -Value (Get-OmniV1Value $m 'metrics' $null))
                Error         = $(if ($errorText) { $errorText } else { $null })
                ModuleId      = [string](Get-OmniV1Value $m 'id' '')
                Group         = [string](Get-OmniV1Value $m 'group' '')
                SkippedReason = $(if ($skipped) { $skipped } else { $null })
            })
        }

        $summary = $null
        if ($results.Count -gt 0) {
            $summary = $results.ToArray() | Get-OmniHealthScore
            $docSummary = Get-OmniV1Value $doc 'summary' $null
            $score = Get-OmniV1Value $docSummary 'healthScore' $null
            if ($null -ne $score) { $summary.Score = [int]$score }
            $grade = [string](Get-OmniV1Value $docSummary 'grade' '')
            if ($grade) { $summary.Grade = $grade }
        }

        $tr = Get-OmniV1Value $scan 'timeRange' $null
        $timeRange = $null
        if ($tr) {
            $timeRange = [pscustomobject]@{
                PSTypeName = 'OmniDiag.TimeRange'
                Start      = (ConvertFrom-OmniIsoTimestamp -Value (Get-OmniV1Value $tr 'start' $null))
                End        = (ConvertFrom-OmniIsoTimestamp -Value (Get-OmniV1Value $tr 'end' $null))
                Label      = [string](Get-OmniV1Value $tr 'label' '')
                Preset     = [string](Get-OmniV1Value $tr 'preset' '')
            }
        }
        $sessionMs = 0
        [void][int]::TryParse([string](Get-OmniV1Value $scan 'durationMs' 0), [ref]$sessionMs)

        $session = [pscustomobject]@{
            PSTypeName    = 'OmniDiag.Session'
            StartTime     = (ConvertFrom-OmniIsoTimestamp -Value (Get-OmniV1Value $scan 'startedAt' $null))
            EndTime       = (ConvertFrom-OmniIsoTimestamp -Value (Get-OmniV1Value $scan 'finishedAt' $null))
            DurationMs    = $sessionMs
            Cancelled     = [bool](Get-OmniV1Value $scan 'cancelled' $false)
            TimeRange     = $timeRange
            Host          = [pscustomobject]@{
                ComputerName = [string](Get-OmniV1Value $docHost 'computerName' '')
                UserName     = [string](Get-OmniV1Value $docHost 'userName' '')
                PSVersion    = [string](Get-OmniV1Value $docHost 'psVersion' '')
            }
            IsAdmin       = $isAdmin
            Results       = $results.ToArray()
            Summary       = $summary
            SchemaVersion = $version
        }
        if ([bool](Get-OmniV1Value (Get-OmniV1Value $doc 'options' $null) 'redacted' $false)) {
            Add-Member -InputObject $session -MemberType NoteProperty -Name Redacted -Value $true
        }
        $plan = Get-OmniV1Value $scan 'plan' $null
        if ($plan) {
            Add-Member -InputObject $session -MemberType NoteProperty -Name ScanPlan -Value ([pscustomobject]@{
                Type = [string](Get-OmniV1Value $plan 'type' ''); Name = [string](Get-OmniV1Value $plan 'name' ''); Description = ''
            })
        }
        return $session
    }
}

Export-ModuleMember -Function @(
    'Get-OmniReportSchemaVersion', 'ConvertTo-OmniReportV1', 'ConvertFrom-OmniReportV1',
    'ConvertTo-OmniJsonText', 'ConvertTo-OmniPlainData', 'ConvertTo-OmniIsoTimestamp', 'ConvertTo-OmniV1Severity'
)
