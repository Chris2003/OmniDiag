<#
.SYNOPSIS
    OmniDiag diagnostic module: Reliability.

.DESCRIPTION
    Best-effort stability assessment. Counts application crashes and hangs from
    the Application log and unexpected shutdowns / bugchecks from the System log
    within the context time range. Uses Get-WinEvent -FilterHashtable and fails
    soft; never throws.

    Every query is bounded: StartTime/EndTime come from $Context.TimeRange and at
    most MaxEvents events are read per query (Config.ReliabilityMaxEvents, default
    1000). A count that reaches the cap is reported as "at least" that many (metric
    EventCountsCapped).

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Reliability'
        Id            = 'reliability.reliability'
        Group         = 'reliability'
        NetworkAccess = 'None'
        Category      = 'Reliability'
        Description   = 'Application crashes/hangs and unexpected shutdowns over time.'
        RequiresAdmin = $false
        Order         = 600
        Enabled       = $true
    }
}

function Test-OmniReliabilityWindowsHost {
    <# .SYNOPSIS Returns $true on Windows (the event log API is Windows-only). #>
    [OutputType([bool])]
    param()
    try { if ($IsWindows -eq $false) { return $false } } catch { Write-Debug $_.Exception.Message }
    return $true
}

function Get-OmniReliabilityEventCount {
    <#
    .SYNOPSIS
        Counts events for a FilterHashtable, reading at most MaxEvents (fail-soft).

    .PARAMETER Filter
        Get-WinEvent FilterHashtable (must carry StartTime and EndTime).

    .PARAMETER MaxEvents
        Upper bound on the events read.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [hashtable] $Filter,
        [Parameter(Mandatory)] [int] $MaxEvents
    )
    try {
        return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $MaxEvents -ErrorAction Stop).Count
    } catch {
        # Only "no matching events" means zero; any other error (access denied, missing
        # log, RPC failure) is rethrown so the scan does not report a healthy Pass it
        # could not verify.
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return 0 }
        throw
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Reliability' -Category 'Reliability' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin

    if (-not (Test-OmniReliabilityWindowsHost)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability.platform' `
            -Title 'Crash and shutdown history is unavailable on this platform' -Severity 'Information' `
            -Component 'Reliability' -Detail 'This scanner reads the Windows event logs, which exist only on Windows.')
        return (Complete-OmniResult -Result $result)
    }

    $start = $Context.TimeRange.Start
    $end   = $Context.TimeRange.End
    $maxEvents = 1000
    if ($Context.Config -and $Context.Config.ContainsKey('ReliabilityMaxEvents')) { $maxEvents = [int]$Context.Config['ReliabilityMaxEvents'] }
    if ($maxEvents -lt 1) { $maxEvents = 1 }

    # ProviderName pins each Id to its source: other providers reuse 1000/1002/41.
    $queries = [ordered]@{
        AppCrashes          = @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $start; EndTime = $end }
        AppHangs            = @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002; StartTime = $start; EndTime = $end }
        UnexpectedShutdowns = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $start; EndTime = $end }
    }
    $counts = @{}
    $capped = $false
    $unreadable = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $queries.Keys) {
        if ($Context.CancellationToken.IsCancellationRequested) {
            return (Complete-OmniResult -Result $result -Status 'Skipped')
        }
        try {
            $n = [int](Get-OmniReliabilityEventCount -Filter $queries[$name] -MaxEvents $maxEvents)
        } catch {
            $Context.Logger.Debug("Reliability query '$name' failed: $($_.Exception.Message)", 'Reliability')
            $unreadable.Add(('{0} ({1} log)' -f $name, $queries[$name].LogName))
            $counts[$name] = 0
            continue
        }
        if ($n -ge $maxEvents) { $capped = $true }
        $counts[$name] = $n
        Set-OmniResultMetric -Result $result -Name $name -Value $n
    }
    Set-OmniResultMetric -Result $result -Name 'EventCountsCapped' -Value $capped
    $appCrashes = $counts['AppCrashes']
    $unexpectedShutdowns = $counts['UnexpectedShutdowns']

    if ($unreadable.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability.unreadable' `
            -Title 'Could not read some crash and shutdown events' -Severity 'Information' `
            -Component 'Reliability' `
            -Detail ('These event queries failed, so their counts are unknown: ' + ($unreadable -join ', ') + '. The event log may be inaccessible (access denied) or unavailable.') `
            -Recommendation 'Run the scan elevated, or check that the Windows Event Log service is running.')
    }

    $rangeLabel = $Context.TimeRange.Label
    $atLeast = if ($capped) { ' Counts that reached the ' + $maxEvents + '-event cap are lower bounds.' } else { '' }

    if ($appCrashes -gt 5) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability.app-crashes' `
            -Title "$appCrashes application crashes ($rangeLabel)" -Severity 'Warning' `
            -Component 'Reliability/Crashes' `
            -Detail "The Application log recorded $appCrashes crash events (ID 1000) in the selected range.$atLeast" `
            -LikelyCause 'A faulty application, driver, or corrupted install may be crashing repeatedly.' `
            -Confidence 65 `
            -Recommendation 'Review the crashing applications in Event Viewer and update or reinstall them.')
    }

    if ($unexpectedShutdowns -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability.unexpected-shutdowns' `
            -Title "$unexpectedShutdowns unexpected shutdown(s) ($rangeLabel)" -Severity 'Warning' `
            -Component 'Reliability/Shutdowns' `
            -Detail "The System log recorded $unexpectedShutdowns Kernel-Power (ID 41) events in the selected range.$atLeast" `
            -LikelyCause 'Power loss, overheating, failing hardware, or a bugcheck (BSOD).' `
            -Confidence 60 `
            -Recommendation 'Check for overheating, power issues, and driver stability; review minidumps if present.')
    }

    # Always record at least one positive finding when nothing is wrong and every count was read.
    if ($unreadable.Count -eq 0 -and @($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability.healthy' `
            -Title 'System stability looks healthy' -Severity 'Pass' -Component 'Reliability' `
            -Detail "No elevated crash, hang, or unexpected-shutdown activity was found for $rangeLabel.")
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
