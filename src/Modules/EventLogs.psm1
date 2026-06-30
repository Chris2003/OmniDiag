<#
.SYNOPSIS
    OmniDiag diagnostic module: Event Logs.

.DESCRIPTION
    The headline OmniDiag feature. Collects events from the System, Application,
    Security, Setup, and a dozen operational channels within the session time
    range; collapses repeats; translates known Event IDs into plain English; and
    emits interpreted findings (with likely cause + recommendation) plus a timeline
    and an executive summary - rather than dumping raw logs.

    Collection is bounded per channel and honors the cancellation token between
    channels to stay within the ~2-minute scan target. The Security and Defender
    channels need elevation; when not elevated they are skipped with a note instead
    of failing the whole module.

    Per-run options (via $Context.Config):
        EventLevels          int[]  Windows level numbers to collect. Default 1,2,3.
        IncludeInformation   bool   Also collect Information (level 4). Default $false.
        EventId              int[]  Restrict to specific Event IDs.
        MaxEventsPerChannel  int    Per-channel cap. Default 5000.
        RecurringThreshold   int    Min count for a Warning group to surface. Default 5.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap dependencies (Models + event-log catalog/analyzer) so the module
# works both standalone (Pester) and when loaded by the OmniDiag root module.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}
if (-not (Get-Command -Name 'Get-OmniEventRecord' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\EventLog\EventLogCatalog.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\EventLog\EventLogAnalyzer.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Event Logs'
        Category      = 'Event Logs'
        Description   = 'Collects, groups, and interprets Windows event logs across key channels.'
        RequiresAdmin = $false   # per-channel; Security/Defender skipped when not elevated
        Order         = 20
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Event Logs' -Category 'Event Logs' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $cfg = $Context.Config

    # --- Resolve options --------------------------------------------------
    $levels = if ($cfg.ContainsKey('EventLevels')) { [int[]]$cfg['EventLevels'] } else { @(1, 2, 3) }
    if ($cfg.ContainsKey('IncludeInformation') -and $cfg['IncludeInformation'] -and ($levels -notcontains 4)) {
        $levels += 4
    }
    $eventId   = if ($cfg.ContainsKey('EventId')) { [int[]]$cfg['EventId'] } else { $null }
    $maxPer    = if ($cfg.ContainsKey('MaxEventsPerChannel')) { [int]$cfg['MaxEventsPerChannel'] } else { 5000 }
    $threshold = if ($cfg.ContainsKey('RecurringThreshold')) { [int]$cfg['RecurringThreshold'] } else { 5 }

    $start = $Context.TimeRange.Start
    $end   = $Context.TimeRange.End

    # --- Collect across channels -----------------------------------------
    $allRecords = [System.Collections.Generic.List[object]]::new()
    $channels = Get-OmniEventChannelDefinition
    $collected = 0; $skippedAdmin = 0; $cancelledEarly = $false
    $perChannel = [ordered]@{}

    foreach ($ch in $channels) {
        if ($Context.CancellationToken.IsCancellationRequested) {
            $log.Warn('Event log collection cancelled before completing all channels.', 'Event Logs')
            $cancelledEarly = $true
            break
        }

        if ($ch.RequiresAdmin -and -not $Context.IsAdmin) {
            $log.Debug("Skipping channel '$($ch.Name)' (requires administrator).", 'Event Logs')
            $skippedAdmin++
            continue
        }

        $records = @(Get-OmniEventRecord -Channel $ch -Start $start -End $end -Level $levels -Id $eventId -MaxEvents $maxPer -Logger $log)
        $perChannel[$ch.Name] = $records.Count
        if ($records.Count -gt 0) {
            $allRecords.AddRange([object[]]$records)
            $collected++
        }
    }

    $records = $allRecords.ToArray()
    $log.Info("Collected $($records.Count) event(s) across $collected channel(s).", 'Event Logs')

    # --- Analyze ----------------------------------------------------------
    $groups   = Group-OmniEventRecord -Record $records
    $timeline = Get-OmniEventTimeline -Record $records
    $findings = New-OmniEventFinding -Group $groups -RecurringThreshold $threshold

    foreach ($f in $findings) { Add-OmniFinding -Result $result -Finding $f }

    if ($skippedAdmin -gt 0 -and -not $Context.IsAdmin) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title "$skippedAdmin channel(s) skipped (require administrator)" -Severity 'Information' `
            -Component 'Event Logs/Security' `
            -Detail 'The Security and Defender channels were not read because OmniDiag is not elevated.' `
            -Recommendation 'Re-run OmniDiag as Administrator to include security and Defender events.')
    }

    if ($records.Count -eq 0 -and -not $cancelledEarly) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No notable events in the selected window' -Severity 'Pass' -Component 'Event Logs' `
            -Detail "No Critical/Error/Warning events were found for $($Context.TimeRange.Label).")
    }

    # --- Metrics (executive summary + structured data for reporting) ------
    Set-OmniResultMetric -Result $result -Name 'TimeRange'           -Value $Context.TimeRange.Label
    Set-OmniResultMetric -Result $result -Name 'TotalEvents'         -Value $records.Count
    Set-OmniResultMetric -Result $result -Name 'CriticalEvents'      -Value (@($records | Where-Object Severity -eq 'Critical').Count)
    Set-OmniResultMetric -Result $result -Name 'ErrorEvents'         -Value (@($records | Where-Object Severity -eq 'Error').Count)
    Set-OmniResultMetric -Result $result -Name 'WarningEvents'       -Value (@($records | Where-Object Severity -eq 'Warning').Count)
    Set-OmniResultMetric -Result $result -Name 'UniqueEventTypes'    -Value (@($groups).Count)
    Set-OmniResultMetric -Result $result -Name 'ChannelsCollected'   -Value $collected
    Set-OmniResultMetric -Result $result -Name 'ChannelsSkippedAdmin' -Value $skippedAdmin
    Set-OmniResultMetric -Result $result -Name 'EventsPerChannel'    -Value $perChannel
    # Structured payloads consumed by the reporting engine (Milestone 4).
    Set-OmniResultMetric -Result $result -Name 'TopGroups' -Value (@($groups | Select-Object -First 25))
    Set-OmniResultMetric -Result $result -Name 'Timeline'  -Value $timeline

    if ($cancelledEarly) {
        return (Complete-OmniResult -Result $result -Status 'Warning')
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
