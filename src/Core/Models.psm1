<#
.SYNOPSIS
    OmniDiag core data models, severity/status vocabularies, and factory functions.

.DESCRIPTION
    Defines the shared, serialization-friendly object shapes used across every
    OmniDiag layer (engine, diagnostic modules, reporting). Models are emitted as
    typed PSCustomObjects via factory functions rather than PowerShell classes so
    they cross module boundaries cleanly (no `using module` requirement) and
    serialize losslessly to JSON.

    Severity and status are represented as validated strings with an associated
    numeric rank map, giving us ordering without the cross-scope friction of enums.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Vocabularies
# ---------------------------------------------------------------------------

# Ordered worst-last so a higher rank == more severe.
$script:OmniSeverityRank = [ordered]@{
    Pass        = 0
    Information = 1
    Warning     = 2
    Error       = 3
    Critical    = 4
}

# Roll-up status used at the module / session level.
$script:OmniStatusValues = @('Healthy', 'Warning', 'Critical', 'Unknown', 'Skipped', 'Failed')

function Get-OmniSeverityRank {
    <#
    .SYNOPSIS
        Returns the numeric rank for a severity string (higher == more severe).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Severity
    )
    if (-not $script:OmniSeverityRank.Contains($Severity)) {
        throw "Unknown severity '$Severity'. Valid values: $($script:OmniSeverityRank.Keys -join ', ')."
    }
    return [int]$script:OmniSeverityRank[$Severity]
}

function Get-OmniSeverityNames {
    <# .SYNOPSIS Returns the ordered list of valid severity names. #>
    [OutputType([string[]])]
    param()
    return [string[]]$script:OmniSeverityRank.Keys
}

# ---------------------------------------------------------------------------
# Secret scrubbing (docs/SECURITY-REVIEW.md, item 5)
# ---------------------------------------------------------------------------
# Collectors never deliberately read secrets, but command lines, proxy URLs, event text,
# and registry values can carry them. Every finding and metric passes through these
# patterns (New-OmniFinding, Complete-OmniResult) and so does every log record, so a
# secret-looking value never reaches a report, a saved session, or the run log.

$script:OmniSecretRegexOptions = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
# Cheap pre-filter: a string without any of these cannot match a pattern below.
$script:OmniSecretHintRegex = [regex]::new('pass|pwd|secret|token|key|sig|bearer|basic|://[^\s/]*@|\d{6}-\d{6}|eyJ|gh[pousr]_|github_pat_|xox|AKIA|ASIA', $script:OmniSecretRegexOptions)
$script:OmniSecretPatterns = @(
    # BitLocker recovery password: 48 digits in 8 groups of 6.
    [pscustomobject]@{ Regex = [regex]::new('(?<!\d)\d{6}(?:-\d{6}){7}(?!\d)', $script:OmniSecretRegexOptions); Replacement = '[REDACTED-RECOVERY-KEY]' }
    # Credentials embedded in a URL: everything between scheme:// and the LAST '@' of the
    # authority (user:password@, a token used as the user name, or a password with '@').
    [pscustomobject]@{ Regex = [regex]::new('\b([a-z][a-z0-9+.\-]*://)(?!\[REDACTED\]@)[^\s/?#]+@', $script:OmniSecretRegexOptions); Replacement = '$1[REDACTED]@' }
    # JSON Web Tokens (header.payload.signature), with or without a Bearer prefix.
    [pscustomobject]@{ Regex = [regex]::new('(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*', $script:OmniSecretRegexOptions); Replacement = '[REDACTED-JWT]' }
    # Well-known token formats: GitHub (ghp_/gho_/ghu_/ghs_/ghr_, github_pat_), Slack (xoxb-, xoxp-, ...),
    # AWS access key ids (AKIA/ASIA, case-sensitive).
    [pscustomobject]@{ Regex = [regex]::new('(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}|(?-i:(?:AKIA|ASIA)[A-Z0-9]{16}))(?![A-Za-z0-9_])', $script:OmniSecretRegexOptions); Replacement = '[REDACTED-TOKEN]' }
    # name=value secrets: environment blocks, connection strings, query strings, INI files.
    [pscustomobject]@{ Regex = [regex]::new('(?<![A-Za-z0-9])((?:default)?password|passwd|pwd|passphrase|secret|client[_-]?secret|api[_-]?key|access[_-]?key|account[_-]?key|shared[_-]?access[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|token|sig)(\s*=\s*)(?!\[REDACTED)("[^"]*"|''[^'']*''|[^\s;&,"'']+)', $script:OmniSecretRegexOptions); Replacement = '$1$2[REDACTED]' }
    # name: value secrets (narrower list: 'Token: Yes' style event text stays readable).
    [pscustomobject]@{ Regex = [regex]::new('(?<![A-Za-z0-9])((?:default)?password|passwd|pwd|passphrase|client[_-]?secret|api[_-]?key)(\s*:\s*)(?!\[REDACTED)("[^"]*"|''[^'']*''|[^\s;&,"'']+)', $script:OmniSecretRegexOptions); Replacement = '$1$2[REDACTED]' }
    # Command-line switches: -Password x, --token x, /secret:x.
    [pscustomobject]@{ Regex = [regex]::new('((?:^|(?<=\s))(?:--?|/)(?:password|passwd|pwd|pass|passphrase|secret|token|api-?key)\b)(\s+|[:=])(?!\[REDACTED)("[^"]*"|''[^'']*''|[^\s"'']+)', $script:OmniSecretRegexOptions); Replacement = '$1$2[REDACTED]' }
    # HTTP authorization values (Basic needs a digit, '+', or '/' so prose like 'Basic Internationalization' stays).
    [pscustomobject]@{ Regex = [regex]::new('\b(bearer)\s+(?!\[REDACTED)[A-Za-z0-9\-._~+/]{16,}=*', $script:OmniSecretRegexOptions); Replacement = '$1 [REDACTED]' }
    [pscustomobject]@{ Regex = [regex]::new('\b(basic)\s+(?=[A-Za-z0-9+/]*[0-9+/])[A-Za-z0-9+/]{16,}={0,2}', $script:OmniSecretRegexOptions); Replacement = '$1 [REDACTED]' }
    # 'netsh wlan show profile key=clear' output (Key Content : <passphrase>).
    [pscustomobject]@{ Regex = [regex]::new('(Key Content\s*:\s*)(?!\[REDACTED)\S[^\r\n]*', $script:OmniSecretRegexOptions); Replacement = '$1[REDACTED]' }
)
# Property / dictionary-key names whose string value is a secret by itself (no 'key=' in the
# value): the whole value is replaced. Matched against the full name, so PasswordLastSet or
# PasswordNeverExpires stay readable.
$script:OmniSecretNameRegex = [regex]::new(
    '^(?:default[_ ]?)?password$|^(?:passwd|pwd|passphrase)$|^(?:client[_ -]?)?secret$|^(?:access|auth|refresh|bearer|api|id)?[_ -]?token$|^api[_ -]?key$|^key[_ ]?(?:content|material)$|^(?:bitlocker[_ ]?)?recovery[_ ]?(?:key|password)$|^(?:pre[_ -]?)?shared[_ ]?key$',
    $script:OmniSecretRegexOptions)
$script:OmniSecretMaxDepth = 16

# The helpers below are deliberately simple (non-advanced) functions: they run for every
# result, finding, and log record, and [CmdletBinding()] binding overhead adds up.

function Protect-OmniSecretText {
    <#
    .SYNOPSIS
        Replaces secret-looking values in a string with [REDACTED] markers.

    .DESCRIPTION
        Covers BitLocker recovery passwords (48 digits in 8 groups), URL user info
        (user:password@, token@, passwords containing '@'), JSON Web Tokens, GitHub /
        Slack / AWS access-key token formats, password= / pwd= / secret= / token= /
        api_key= / sig= style pairs, password: style labels, -Password / --token /
        /secret: command-line switches, Bearer / Basic authorization values, and netsh
        'Key Content' lines. The key and layout are kept (password=[REDACTED]) so the
        evidence still reads correctly. Idempotent. $null is returned as $null.

    .PARAMETER Text
        The string to scrub.

    .EXAMPLE
        Protect-OmniSecretText 'app.exe --password hunter2'   # 'app.exe --password [REDACTED]'
    #>
    param($Text)
    if ($null -eq $Text) { return $null }
    $s = [string]$Text
    if ($s.Length -lt 6 -or -not $script:OmniSecretHintRegex.IsMatch($s)) { return $s }
    foreach ($p in $script:OmniSecretPatterns) { $s = $p.Regex.Replace($s, $p.Replacement) }
    return $s
}

function Test-OmniSecretContainer {
    <# .SYNOPSIS Internal: true for the graph nodes the scrubbers descend into. #>
    param($Value)
    return ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Collections.IList] -or
        $Value -is [System.Management.Automation.PSCustomObject])
}

function Protect-OmniSecretData {
    <#
    .SYNOPSIS
        Scrubs secret-looking strings inside a session, result, or finding graph, IN PLACE.

    .DESCRIPTION
        Walks PSCustomObjects (note properties), dictionaries, and lists/arrays (depth-limited)
        and rewrites every string value with Protect-OmniSecretText. A string stored under a
        secret name (DefaultPassword, Password, Secret, Token, ApiKey, KeyMaterial,
        RecoveryPassword, ...) is replaced as a whole with [REDACTED]. Other .NET objects
        (CIM instances, process objects, ...) and read-only collections are left alone. The
        shape and object identity of the graph are preserved; the graph itself is modified.
        Use it on objects OmniDiag owns (results in Complete-OmniResult, sessions on import
        and export). For a caller's object that must stay untouched, use
        ConvertTo-OmniSecretSafeData, which returns a scrubbed copy.

    .PARAMETER InputObject
        The object graph to scrub.

    .PARAMETER Depth
        Internal recursion depth.

    .EXAMPLE
        Protect-OmniSecretData -InputObject $session
    #>
    param($InputObject, [int] $Depth = 0)
    if ($null -eq $InputObject -or $Depth -gt $script:OmniSecretMaxDepth) { return }
    $v = $InputObject

    if ($v -is [System.Collections.IDictionary]) {
        if ($v.IsReadOnly) { return }
        foreach ($k in @($v.Keys)) {
            $item = $v[$k]
            if ($item -is [string]) {
                if ($item.Length -gt 0 -and $k -is [string] -and $script:OmniSecretNameRegex.IsMatch($k)) { $v[$k] = '[REDACTED]'; continue }
                if ($item.Length -lt 6 -or -not $script:OmniSecretHintRegex.IsMatch($item)) { continue }
                $clean = Protect-OmniSecretText $item
                if (-not [string]::Equals($clean, $item, [System.StringComparison]::Ordinal)) { $v[$k] = $clean }
            } elseif (Test-OmniSecretContainer $item) {
                Protect-OmniSecretData $item ($Depth + 1)
            }
        }
        return
    }
    if ($v -is [System.Collections.IList]) {
        if ($v.IsReadOnly) { return }
        # byte[] / int[] and other value-type arrays hold no strings (and can be large).
        if ($v -is [array] -and $v.GetType().GetElementType().IsValueType) { return }
        for ($i = 0; $i -lt $v.Count; $i++) {
            $item = $v[$i]
            if ($item -is [string]) {
                if ($item.Length -lt 6 -or -not $script:OmniSecretHintRegex.IsMatch($item)) { continue }
                $clean = Protect-OmniSecretText $item
                if (-not [string]::Equals($clean, $item, [System.StringComparison]::Ordinal)) { $v[$i] = $clean }
            } elseif (Test-OmniSecretContainer $item) {
                Protect-OmniSecretData $item ($Depth + 1)
            }
        }
        return
    }
    if ($v -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in @($v.PSObject.Properties)) {
            if ([string]$prop.MemberType -ne 'NoteProperty') { continue }
            $item = $prop.Value
            if ($item -is [string]) {
                if ($item.Length -gt 0 -and $script:OmniSecretNameRegex.IsMatch($prop.Name)) { $prop.Value = '[REDACTED]'; continue }
                if ($item.Length -lt 6 -or -not $script:OmniSecretHintRegex.IsMatch($item)) { continue }
                $clean = Protect-OmniSecretText $item
                if (-not [string]::Equals($clean, $item, [System.StringComparison]::Ordinal)) { $prop.Value = $clean }
            } elseif (Test-OmniSecretContainer $item) {
                Protect-OmniSecretData $item ($Depth + 1)
            }
        }
    }
}

function ConvertTo-OmniSecretSafeData {
    <#
    .SYNOPSIS
        Returns a scrubbed COPY of a log or finding payload; the input is never modified.

    .DESCRIPTION
        Strings are scrubbed with Protect-OmniSecretText (or replaced whole under a secret
        name, as in Protect-OmniSecretData). Dictionaries, lists, and PSCustomObjects are
        copied. ErrorRecords and exceptions become their (scrubbed) message text, because
        their object graphs can carry command lines and arguments. Value types are returned
        as they are; other .NET objects are returned unchanged (not copied).

    .PARAMETER InputObject
        The payload to copy.

    .PARAMETER Depth
        Internal recursion depth.

    .EXAMPLE
        $safe = ConvertTo-OmniSecretSafeData -InputObject @{ password = 'x'; note = 'ok' }
    #>
    param($InputObject, [int] $Depth = 0)
    $v = $InputObject
    if ($null -eq $v) { return $null }
    if ($v -is [string]) { return (Protect-OmniSecretText $v) }
    if ($v -is [System.ValueType]) { return $v }
    if ($v -is [System.Management.Automation.ErrorRecord]) { return (Protect-OmniSecretText ([string]$v)) }
    if ($v -is [System.Exception]) { return (Protect-OmniSecretText ('{0}: {1}' -f $v.GetType().FullName, $v.Message)) }
    if ($Depth -gt $script:OmniSecretMaxDepth) { return (Protect-OmniSecretText ([string]$v)) }

    if ($v -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($k in @($v.Keys)) {
            $item = $v[$k]
            if ($item -is [string] -and $item.Length -gt 0 -and $k -is [string] -and $script:OmniSecretNameRegex.IsMatch($k)) { $copy[$k] = '[REDACTED]' }
            else { $copy[$k] = ConvertTo-OmniSecretSafeData $item ($Depth + 1) }
        }
        return $copy
    }
    if ($v -is [System.Collections.IList]) {
        if ($v -is [array] -and $v.GetType().GetElementType().IsValueType) { return , $v }
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $v) { $list.Add((ConvertTo-OmniSecretSafeData $item ($Depth + 1))) }
        return , $list.ToArray()
    }
    if ($v -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($prop in @($v.PSObject.Properties)) {
            if ([string]$prop.MemberType -ne 'NoteProperty') { continue }
            $item = $prop.Value
            if ($item -is [string] -and $item.Length -gt 0 -and $script:OmniSecretNameRegex.IsMatch($prop.Name)) { $copy[$prop.Name] = '[REDACTED]' }
            else { $copy[$prop.Name] = ConvertTo-OmniSecretSafeData $item ($Depth + 1) }
        }
        return [pscustomobject]$copy
    }
    return $v
}

# ---------------------------------------------------------------------------
# Finding
# ---------------------------------------------------------------------------

function New-OmniFinding {
    <#
    .SYNOPSIS
        Creates a single diagnostic finding.

    .DESCRIPTION
        A finding is the atomic unit of OmniDiag output: an interpreted, severity-
        tagged observation that goes beyond raw data to (optionally) include a
        likely cause, a confidence score, and a recommended next step. This is what
        powers the "diagnose, don't just dump" requirement.

    .PARAMETER Title
        Short, human-readable summary (e.g. "DNS resolution failing").

    .PARAMETER Severity
        One of Pass, Information, Warning, Error, Critical.

    .PARAMETER Component
        The affected component/subsystem (e.g. "Network/DNS", "Storage/Disk0").

    .PARAMETER Detail
        Longer explanation of what was observed.

    .PARAMETER LikelyCause
        Interpreted probable root cause, in plain English.

    .PARAMETER Confidence
        0-100 confidence in the likely cause / interpretation.

    .PARAMETER Recommendation
        Suggested next step for the technician.

    .PARAMETER Data
        Optional structured payload (hashtable / object) backing the finding.

    .PARAMETER Id
        Stable identifier for de-duplication and report cross-referencing.
        Auto-generated from Component+Title when omitted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [Parameter(Mandatory)]
        [ValidateScript({ $_ -in (Get-OmniSeverityNames) })]
        [string] $Severity,

        [string] $Component = 'General',

        [string] $Detail = '',

        [string] $LikelyCause = '',

        [ValidateRange(0, 100)]
        [int] $Confidence = 0,

        [string] $Recommendation = '',

        [object] $Data = $null,

        [string] $Id
    )

    # Scrub first, so an Id derived from the title never carries a secret either.
    $Title = Protect-OmniSecretText $Title
    if ([string]::IsNullOrWhiteSpace($Id)) {
        $seed = "{0}|{1}" -f $Component, $Title
        $Id = ($seed.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    }

    $finding = [pscustomobject]@{
        PSTypeName     = 'OmniDiag.Finding'
        Id             = $Id
        Title          = $Title
        Severity       = $Severity
        SeverityRank   = Get-OmniSeverityRank -Severity $Severity
        Component      = $Component
        Detail         = (Protect-OmniSecretText $Detail)
        LikelyCause    = (Protect-OmniSecretText $LikelyCause)
        Confidence     = $Confidence
        Recommendation = (Protect-OmniSecretText $Recommendation)
        Data           = $Data
        Timestamp      = (Get-Date)
    }
    # -Data is not modified here (it may still be the caller's object): the result,
    # including each finding's Data, is scrubbed once, in place, by Complete-OmniResult.
    return $finding
}

# ---------------------------------------------------------------------------
# Module result
# ---------------------------------------------------------------------------

function New-OmniResult {
    <#
    .SYNOPSIS
        Creates an empty result container for one diagnostic module run.

    .DESCRIPTION
        Aggregates the findings, metrics, timing, and status produced by a single
        module. Use Add-OmniFinding / Set-OmniResultMetric to populate it and
        Complete-OmniResult to finalize timing and derive the roll-up status.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleName,

        [string] $Category = 'General',

        [bool] $RequiresAdmin = $false,

        [bool] $HadAdmin = $false
    )

    return [pscustomobject]@{
        PSTypeName    = 'OmniDiag.Result'
        ModuleName    = $ModuleName
        Category      = $Category
        Status        = 'Unknown'
        RequiresAdmin = $RequiresAdmin
        HadAdmin      = $HadAdmin
        StartTime     = (Get-Date)
        EndTime       = $null
        DurationMs    = 0
        Findings      = [System.Collections.Generic.List[object]]::new()
        Metrics       = [ordered]@{}
        Error         = $null
    }
}

function Add-OmniFinding {
    <#
    .SYNOPSIS
        Appends one or more findings to a result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject] $Result,

        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
        [object[]] $Finding
    )
    process {
        foreach ($f in $Finding) {
            if ($null -ne $f) { [void]$Result.Findings.Add($f) }
        }
    }
}

function Set-OmniResultMetric {
    <#
    .SYNOPSIS
        Records a named metric/value on a result (e.g. "FreeSpaceGB" = 42).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Result,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowNull()] [object] $Value
    )
    $Result.Metrics[$Name] = $Value
}

function Complete-OmniResult {
    <#
    .SYNOPSIS
        Finalizes a result: stamps end time/duration and derives roll-up Status
        from the highest-severity finding (unless an explicit status is given).

    .PARAMETER Status
        Optional explicit status override (e.g. 'Skipped', 'Failed').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Result,

        [ValidateScript({ $_ -in @('Healthy','Warning','Critical','Unknown','Skipped','Failed') })]
        [string] $Status
    )

    $Result.EndTime = Get-Date
    $Result.DurationMs = [int]([math]::Round(($Result.EndTime - $Result.StartTime).TotalMilliseconds))
    # Findings, metrics, and the error text never carry secret-looking values (in place).
    Protect-OmniSecretData -InputObject $Result

    if ($PSBoundParameters.ContainsKey('Status')) {
        $Result.Status = $Status
        return $Result
    }

    if ($Result.Findings.Count -eq 0) {
        $Result.Status = 'Healthy'
        return $Result
    }

    $max = ($Result.Findings | Measure-Object -Property SeverityRank -Maximum).Maximum
    $Result.Status = switch ($max) {
        { $_ -ge (Get-OmniSeverityRank 'Critical') } { 'Critical'; break }
        { $_ -ge (Get-OmniSeverityRank 'Error') }    { 'Critical'; break }
        { $_ -ge (Get-OmniSeverityRank 'Warning') }  { 'Warning';  break }
        default                                       { 'Healthy' }
    }
    return $Result
}

# ---------------------------------------------------------------------------
# Time range helper
# ---------------------------------------------------------------------------

function Get-OmniTimeRange {
    <#
    .SYNOPSIS
        Resolves a named preset or explicit Start/End into a normalized range.

    .PARAMETER Preset
        Last24Hours, Last7Days, or Last30Days.

    .PARAMETER Start
        Explicit start (overrides preset start).

    .PARAMETER End
        Explicit end. Defaults to now.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Preset')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'Preset')]
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')]
        [string] $Preset = 'Last7Days',

        [Parameter(ParameterSetName = 'Custom', Mandatory)]
        [datetime] $Start,

        [Parameter(ParameterSetName = 'Custom')]
        [datetime] $End
    )

    $now = Get-Date
    if ($PSCmdlet.ParameterSetName -eq 'Custom') {
        $endTime = if ($PSBoundParameters.ContainsKey('End')) { $End } else { $now }
        $label = "{0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm}" -f $Start, $endTime
        return [pscustomobject]@{
            PSTypeName = 'OmniDiag.TimeRange'
            Start      = $Start
            End        = $endTime
            Label      = $label
            Preset     = 'Custom'
        }
    }

    $start = switch ($Preset) {
        'Last24Hours' { $now.AddHours(-24) }
        'Last7Days'   { $now.AddDays(-7) }
        'Last30Days'  { $now.AddDays(-30) }
    }
    return [pscustomobject]@{
        PSTypeName = 'OmniDiag.TimeRange'
        Start      = $start
        End        = $now
        Label      = $Preset
        Preset     = $Preset
    }
}

# ---------------------------------------------------------------------------
# Connectivity probes (opt-in, decision 1)
# ---------------------------------------------------------------------------

# Default probe targets; override per run with $Context.Config.ProbeTargets (hashtable).
$script:OmniDefaultProbeTargets = [ordered]@{
    PingGateway   = $true                 # ping the default gateway found in the local IP config
    PublicAddress = '1.1.1.1'             # public IP pinged for internet reachability
    DnsName       = 'www.microsoft.com'   # host name resolved by the DNS probes
    TimeoutMs     = 2000                  # per-probe timeout
}

function Test-OmniNetworkProbeEnabled {
    <#
    .SYNOPSIS
        Returns $true when the scan context opted in to connectivity probes.

    .DESCRIPTION
        Connectivity probes (pinging the gateway or a public address, resolving a public
        name, the domain secure-channel check) contact the network, so they run only when
        the user asks for them: --network-probes (CLI), -NetworkProbes (OmniDiag.ps1,
        Invoke-OmniDiag, Invoke-OmniDiagScan), or the GUI option. Contexts created before
        the NetworkProbes property existed count as "off".

    .PARAMETER Context
        The scan context handed to Invoke-OmniModuleScan.

    .EXAMPLE
        if (Test-OmniNetworkProbeEnabled -Context $Context) { $latency = Send-Probe }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [AllowNull()] [object] $Context)
    if ($null -eq $Context) { return $false }
    $p = $Context.PSObject.Properties['NetworkProbes']
    return [bool]($p -and $p.Value)
}

function Get-OmniProbeTarget {
    <#
    .SYNOPSIS
        Returns the connectivity-probe targets for a scan: the defaults merged with
        $Context.Config.ProbeTargets.

    .DESCRIPTION
        Keys: PingGateway (bool), PublicAddress (string), DnsName (string), TimeoutMs (int).
        Unknown keys in Config.ProbeTargets are ignored; missing keys keep the defaults
        (gateway, 1.1.1.1, www.microsoft.com, 2000 ms).

    .PARAMETER Context
        The scan context (may be $null: defaults only).

    .EXAMPLE
        $targets = Get-OmniProbeTarget -Context $Context
        $targets.DnsName
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] [object] $Context)

    $t = [ordered]@{}
    foreach ($k in $script:OmniDefaultProbeTargets.Keys) { $t[$k] = $script:OmniDefaultProbeTargets[$k] }

    $cfg = $null
    if ($null -ne $Context) {
        $p = $Context.PSObject.Properties['Config']
        if ($p -and $p.Value -is [System.Collections.IDictionary] -and $p.Value.Contains('ProbeTargets')) { $cfg = $p.Value['ProbeTargets'] }
    }
    if ($cfg -is [System.Collections.IDictionary]) {
        foreach ($k in @($script:OmniDefaultProbeTargets.Keys)) {
            if ($cfg.Contains($k) -and $null -ne $cfg[$k] -and "$($cfg[$k])" -ne '') {
                $t[$k] = switch ($k) {
                    'PingGateway' { [bool]$cfg[$k] }
                    'TimeoutMs'   { [int]$cfg[$k] }
                    default       { [string]$cfg[$k] }
                }
            }
        }
    }
    if ($t.TimeoutMs -lt 100) { $t.TimeoutMs = 100 }
    return [pscustomobject]$t
}

function New-OmniProbeSkippedFinding {
    <#
    .SYNOPSIS
        Creates the standard Information finding a scanner adds when it did not run its
        connectivity probe because probes are opt-in.

    .PARAMETER Component
        Finding component (e.g. 'Network/Connectivity').

    .PARAMETER Probe
        Plain-language description of the probe that was not run (e.g. 'ping the default
        gateway and 1.1.1.1, resolve www.microsoft.com').

    .EXAMPLE
        Add-OmniFinding -Result $result -Finding (New-OmniProbeSkippedFinding -Component 'Network/DNS' -Probe 'resolve www.microsoft.com')
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Factory: returns a new in-memory object and changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Component,
        [Parameter(Mandatory)] [string] $Probe
    )
    return (New-OmniFinding -Title 'Connectivity probe not run' -Severity 'Information' -Component $Component `
        -Detail "Connectivity probes are off by default, so this scan did not $Probe. Everything else in this check ran locally." `
        -Recommendation 'To test connectivity, re-run with --network-probes (omnidiag CLI), -NetworkProbes (OmniDiag.ps1 or Invoke-OmniDiagScan), or tick "Run connectivity probes (contacts the network)" in the GUI.')
}

Export-ModuleMember -Function @(
    'Get-OmniSeverityRank', 'Get-OmniSeverityNames',
    'New-OmniFinding', 'New-OmniResult', 'Add-OmniFinding',
    'Set-OmniResultMetric', 'Complete-OmniResult', 'Get-OmniTimeRange',
    'Test-OmniNetworkProbeEnabled', 'Get-OmniProbeTarget', 'New-OmniProbeSkippedFinding',
    'Protect-OmniSecretText', 'Protect-OmniSecretData', 'ConvertTo-OmniSecretSafeData'
)
