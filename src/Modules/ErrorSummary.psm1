<#
.SYNOPSIS
    OmniDiag diagnostic module: Error Summary.

.DESCRIPTION
    Summarizes recent Critical/Error events from the System and Application logs
    within the session time range, groups them by source, and highlights bugchecks
    (BSOD, System Event ID 41) and application crashes (Event ID 1000).

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
        Name          = 'Error Summary'
        Category      = 'Event Logs'
        Description   = 'Summarizes recent critical/error events from System and Application logs.'
        RequiresAdmin = $false
        Order         = 710
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Error Summary' -Category 'Event Logs' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # Honor cancellation up front.
    try {
        if ($Context.CancellationToken -and $Context.CancellationToken.IsCancellationRequested) {
            return (Complete-OmniResult -Result $result -Status 'Skipped')
        }
    } catch { }

    $events = @()
    try {
        $filter = @{
            LogName   = 'System', 'Application'
            Level     = 1, 2
            StartTime = $Context.TimeRange.Start
            EndTime   = $Context.TimeRange.End
        }
        $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 500 -ErrorAction Stop)
    } catch {
        # No matching events is a common, benign case (throws "No events were found").
        if ($_.Exception.Message -match '(?i)No events were found') {
            $log.Debug('No matching error events in the selected range.', 'Error Summary')
        } else {
            $log.Warn("Get-WinEvent failed: $($_.Exception.Message)", 'Error Summary')
        }
    }

    $total = @($events).Count
    Set-OmniResultMetric -Result $result -Name 'TotalErrors' -Value $total

    # Re-check cancellation after the (potentially slow) query.
    try {
        if ($Context.CancellationToken -and $Context.CancellationToken.IsCancellationRequested) {
            return (Complete-OmniResult -Result $result -Status 'Skipped')
        }
    } catch { }

    $bugchecks = 0
    $appCrashes = 0

    try {
        if ($total -gt 0) {
            $topProviders = @($events | Group-Object -Property ProviderName |
                Sort-Object Count -Descending | Select-Object -First 5 |
                ForEach-Object { "{0} ({1})" -f $_.Name, $_.Count })
            Set-OmniResultMetric -Result $result -Name 'TopProviders' -Value $topProviders

            $bugchecks  = @($events | Where-Object { $_.LogName -eq 'System' -and $_.Id -eq 41 }).Count
            $appCrashes = @($events | Where-Object { $_.Id -eq 1000 }).Count
            Set-OmniResultMetric -Result $result -Name 'BugcheckCount' -Value $bugchecks
            Set-OmniResultMetric -Result $result -Name 'AppCrashCount' -Value $appCrashes

            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("{0} error/critical event(s) in range" -f $total) `
                -Severity 'Information' -Component 'EventLogs/Errors' `
                -Detail ('Top sources: ' + ($topProviders -join '; ')) `
                -Data $topProviders)
        }
    } catch {
        $log.Debug("Grouping events failed: $($_.Exception.Message)", 'Error Summary')
    }

    try {
        if ($bugchecks -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("{0} unexpected shutdown/bugcheck event(s)" -f $bugchecks) `
                -Severity 'Warning' -Component 'EventLogs/Bugcheck' `
                -Detail "System Event ID 41 (Kernel-Power) occurred $bugchecks time(s), indicating an unexpected restart or BSOD." `
                -LikelyCause 'Power loss, a driver/hardware fault, or a bug check (blue screen).' `
                -Confidence 65 `
                -Recommendation 'Review minidumps and reliability history; check drivers, power, and thermals.')
        }

        if ($total -gt 25) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Elevated error volume ({0} events)" -f $total) `
                -Severity 'Warning' -Component 'EventLogs/Errors' `
                -Detail "There were $total error/critical events in the selected range ($appCrashes app crash(es))." `
                -LikelyCause 'A recurring fault, failing hardware, or a misbehaving application/driver.' `
                -Confidence 55 `
                -Recommendation 'Investigate the top event sources to identify the recurring fault.')
        }
    } catch {
        $log.Debug("Finding generation failed: $($_.Exception.Message)", 'Error Summary')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No significant error activity' -Severity 'Pass' -Component 'EventLogs/Errors' `
            -Detail 'Recent System/Application error and critical events are within normal levels.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
