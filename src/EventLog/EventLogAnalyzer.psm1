<#
.SYNOPSIS
    OmniDiag Event Log analyzer: collection, grouping, pattern detection, findings.

.DESCRIPTION
    The analysis pipeline behind the Event Logs module:

        Get-OmniEventRecord     -> bounded Get-WinEvent collection per channel
        Group-OmniEventRecord   -> collapse repeats; first/last seen, counts, enrich
        Get-OmniEventTimeline   -> ordered list of major lifecycle events
        New-OmniEventFinding     -> turn groups + cross-event patterns into findings

    Everything degrades gracefully: a missing channel or an access-denied log is
    logged and skipped, never fatal. Collection is bounded (MaxEventsPerChannel)
    to keep a full scan within the ~2-minute target.
#>

Set-StrictMode -Version Latest

# Self-bootstrap dependencies so the analyzer is usable standalone (Pester) and
# under the root module.
if (-not (Get-Command -Name 'Resolve-OmniEventMeaning' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'EventLogCatalog.psm1') -Global -Force -DisableNameChecking
}
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function ConvertFrom-OmniEventLevel {
    <#
    .SYNOPSIS
        Maps a Windows event Level number to an OmniDiag severity string.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [int] $Level)
    switch ($Level) {
        1       { 'Critical' }
        2       { 'Error' }
        3       { 'Warning' }
        4       { 'Information' }
        0       { 'Information' }   # LogAlways
        default { 'Information' }   # Verbose / unknown
    }
}

function Get-OmniEventRecord {
    <#
    .SYNOPSIS
        Collects events from a single channel within a time range, bounded.

    .PARAMETER Channel
        A channel definition from Get-OmniEventChannelDefinition.

    .PARAMETER Start / End
        Time window.

    .PARAMETER Level
        Optional array of Windows level numbers to include (1=Crit,2=Err,3=Warn,
        4=Info). Defaults to Critical+Error+Warning.

    .PARAMETER Id
        Optional Event ID filter.

    .PARAMETER MaxEvents
        Cap per channel (newest first). Default 5000.

    .PARAMETER Logger
        Optional OmniDiag logger.

    .OUTPUTS
        Normalized OmniDiag.EventRecord objects.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Channel,
        [Parameter(Mandatory)] [datetime] $Start,
        [Parameter(Mandatory)] [datetime] $End,
        [int[]] $Level = @(1, 2, 3),
        [int[]] $Id,
        [int] $MaxEvents = 5000,
        [pscustomobject] $Logger
    )

    $filter = @{ LogName = $Channel.LogName; StartTime = $Start; EndTime = $End }
    if ($Channel.ProviderName) { $filter['ProviderName'] = $Channel.ProviderName }
    if ($Level) { $filter['Level'] = $Level }
    if ($Id)    { $filter['Id'] = $Id }

    try {
        $raw = Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'No events were found') {
            if ($Logger) { $Logger.Debug("No matching events in '$($Channel.Name)'.", 'EventLogs') }
        } else {
            # Missing channel, access denied, etc. - informational, not fatal.
            if ($Logger) { $Logger.Debug("Channel '$($Channel.Name)' unavailable: $msg", 'EventLogs') }
        }
        return @()
    }

    foreach ($e in $raw) {
        [pscustomobject]@{
            PSTypeName   = 'OmniDiag.EventRecord'
            TimeCreated  = $e.TimeCreated
            Id           = [int]$e.Id
            ProviderName = $e.ProviderName
            Level        = [int]$e.Level
            Severity     = (ConvertFrom-OmniEventLevel -Level ([int]$e.Level))
            LogName      = $e.LogName
            Machine      = $e.MachineName
            Channel      = $Channel.Name
            Message      = if ($e.Message) { ($e.Message -split "`r?`n")[0].Trim() } else { "(no message; Event ID $($e.Id))" }
        }
    }
}

function Group-OmniEventRecord {
    <#
    .SYNOPSIS
        Collapses repeated events into enriched groups.

    .DESCRIPTION
        Groups by Provider + Id + (level-derived) severity, then enriches each group
        from the translation catalog. A catalog Severity override (e.g. 4625 -> Warning)
        takes precedence over the raw level. Output is sorted most-severe, then by count.

    .OUTPUTS
        OmniDiag.EventGroup objects.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Record
    )

    if ($Record.Count -eq 0) { return @() }

    $groups = $Record | Group-Object -Property ProviderName, Id, Severity

    $result = foreach ($g in $groups) {
        $first = $g.Group[0]
        $meaning = Resolve-OmniEventMeaning -Id $first.Id -ProviderName $first.ProviderName

        $severity = if ($meaning -and $meaning.Severity) { $meaning.Severity } else { $first.Severity }
        $sortedTimes = $g.Group | Sort-Object TimeCreated

        [pscustomobject]@{
            PSTypeName     = 'OmniDiag.EventGroup'
            ProviderName   = $first.ProviderName
            Id             = $first.Id
            Severity       = $severity
            SeverityRank   = (Get-OmniSeverityRank $severity)
            Category       = if ($meaning) { $meaning.Category } else { 'General' }
            Title          = if ($meaning) { $meaning.Title } else { "Event ID $($first.Id) from $($first.ProviderName)" }
            Count          = $g.Count
            FirstSeen      = ($sortedTimes | Select-Object -First 1).TimeCreated
            LastSeen       = ($sortedTimes | Select-Object -Last 1).TimeCreated
            Channel        = $first.Channel
            LogName        = $first.LogName
            SampleMessage  = $first.Message
            LikelyCause    = if ($meaning) { $meaning.Cause } else { '' }
            Recommendation = if ($meaning) { $meaning.Recommendation } else { '' }
            Known          = [bool]$meaning
        }
    }

    return @($result | Sort-Object -Property SeverityRank, Count -Descending)
}

function Get-OmniEventTimeline {
    <#
    .SYNOPSIS
        Builds an ordered timeline of major lifecycle events (boot, shutdown,
        crash, malware) for the report.

    .OUTPUTS
        Time-ordered OmniDiag.TimelineEntry objects (newest first), capped.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Record,
        [int] $Max = 100
    )

    $majorIds = 41, 6005, 6006, 6008, 6009, 1074, 1076, 1001, 1116, 1102
    $entries = foreach ($r in ($Record | Where-Object { $_.Id -in $majorIds })) {
        $meaning = Resolve-OmniEventMeaning -Id $r.Id -ProviderName $r.ProviderName
        [pscustomobject]@{
            PSTypeName = 'OmniDiag.TimelineEntry'
            Time       = $r.TimeCreated
            Id         = $r.Id
            Category   = if ($meaning) { $meaning.Category } else { 'General' }
            Title      = if ($meaning) { $meaning.Title } else { "Event ID $($r.Id)" }
            Provider   = $r.ProviderName
        }
    }
    return @($entries | Sort-Object Time -Descending | Select-Object -First $Max)
}

function New-OmniEventFinding {
    <#
    .SYNOPSIS
        Turns event groups (and cross-event patterns) into OmniDiag findings.

    .DESCRIPTION
        Emits a finding for every Critical/Error group, for recurring Warning groups
        (Count >= RecurringThreshold), and for higher-order patterns the per-group
        view misses (e.g. many failed logons => possible brute force; many service
        crashes => flapping service; repeated unexpected shutdowns).

    .PARAMETER Group
        Output of Group-OmniEventRecord.

    .PARAMETER RecurringThreshold
        Minimum count for a Warning-level group to be surfaced. Default 5.

    .PARAMETER MaxGroupFindings
        Cap on per-group findings to keep reports readable. Default 50.

    .OUTPUTS
        OmniDiag.Finding objects.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Group,
        [int] $RecurringThreshold = 5,
        [int] $MaxGroupFindings = 50
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    # --- Cross-event patterns (computed before per-group capping) ---------
    $failedLogons = $Group | Where-Object { $_.Id -eq 4625 }
    if ($failedLogons) {
        $total = ($failedLogons | Measure-Object -Property Count -Sum).Sum
        if ($total -ge 10) {
            $findings.Add((New-OmniFinding -Title "$total failed logon attempts detected" -Severity 'Critical' `
                -Component 'Event Logs/Authentication' `
                -Detail "Security event 4625 occurred $total time(s) in the selected window." `
                -LikelyCause 'A high volume of failed logons can indicate a brute-force attempt or a broken stored credential.' `
                -Confidence 65 `
                -Recommendation 'Identify the source account/host; if external, block it and review exposed services (e.g. RDP).' `
                -Data ($failedLogons | Select-Object Id, Count, FirstSeen, LastSeen)))
        }
    }

    $serviceCrashes = $Group | Where-Object { $_.Id -in @(7031, 7034) }
    if ($serviceCrashes) {
        $total = ($serviceCrashes | Measure-Object -Property Count -Sum).Sum
        if ($total -ge $RecurringThreshold) {
            $findings.Add((New-OmniFinding -Title "Repeated service crashes ($total)" -Severity 'Error' `
                -Component 'Event Logs/Service' `
                -Detail "Service Control Manager reported $total unexpected service terminations." `
                -LikelyCause 'A service is flapping - crashing and (sometimes) restarting repeatedly.' `
                -Confidence 70 `
                -Recommendation 'Identify the service in the messages; update the owning software and review its logs.' `
                -Data ($serviceCrashes | Select-Object Id, Count, FirstSeen, LastSeen)))
        }
    }

    $unexpectedShutdowns = $Group | Where-Object { $_.Id -in @(41, 6008) }
    if ($unexpectedShutdowns) {
        $total = ($unexpectedShutdowns | Measure-Object -Property Count -Sum).Sum
        if ($total -ge 2) {
            $findings.Add((New-OmniFinding -Title "$total unexpected shutdowns" -Severity 'Critical' `
                -Component 'Event Logs/Power' `
                -Detail "The system recorded $total unexpected shutdown/power-loss events." `
                -LikelyCause 'Recurring power loss or hard crashes - power supply, overheating, or a faulting driver.' `
                -Confidence 60 `
                -Recommendation 'Check power and cooling; correlate with bug checks (BSOD) and update drivers.' `
                -Data ($unexpectedShutdowns | Select-Object Id, Count, FirstSeen, LastSeen)))
        }
    }

    # --- Per-group findings ----------------------------------------------
    $notable = $Group | Where-Object {
        $_.SeverityRank -ge (Get-OmniSeverityRank 'Error') -or
        ($_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') -and $_.Count -ge $RecurringThreshold)
    } | Select-Object -First $MaxGroupFindings

    foreach ($g in $notable) {
        $countSuffix = if ($g.Count -gt 1) { " (x$($g.Count))" } else { '' }
        $detail = "{0} - Event ID {1} from {2}. First seen {3:yyyy-MM-dd HH:mm}, last seen {4:yyyy-MM-dd HH:mm}. Sample: {5}" -f `
            $g.Channel, $g.Id, $g.ProviderName, $g.FirstSeen, $g.LastSeen, $g.SampleMessage
        $findings.Add((New-OmniFinding -Title ("$($g.Title)$countSuffix") -Severity $g.Severity `
            -Component "Event Logs/$($g.Category)" `
            -Detail $detail `
            -LikelyCause $g.LikelyCause `
            -Confidence $(if ($g.Known) { 60 } else { 30 }) `
            -Recommendation $g.Recommendation `
            -Data $g))
    }

    return @($findings)
}

Export-ModuleMember -Function @(
    'ConvertFrom-OmniEventLevel', 'Get-OmniEventRecord', 'Group-OmniEventRecord',
    'Get-OmniEventTimeline', 'New-OmniEventFinding'
)
