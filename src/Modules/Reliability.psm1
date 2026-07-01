<#
.SYNOPSIS
    OmniDiag diagnostic module: Reliability.

.DESCRIPTION
    Best-effort stability assessment. Counts application crashes and hangs from
    the Application log and unexpected shutdowns / bugchecks from the System log
    within the context time range. Uses Get-WinEvent -FilterHashtable and fails
    soft; never throws.

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
        Category      = 'Reliability'
        Description   = 'Application crashes/hangs and unexpected shutdowns over time.'
        RequiresAdmin = $false
        Order         = 600
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

    $result = New-OmniResult -ModuleName 'Reliability' -Category 'Reliability' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $start = $Context.TimeRange.Start
    $end   = $Context.TimeRange.End

    # Helper: count events for a filter hashtable, fully fail-soft.
    $countEvents = {
        param([hashtable] $Filter)
        try {
            $events = Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop
            return @($events).Count
        } catch {
            # No matching events raises a non-fatal error; treat as zero.
            return 0
        }
    }

    # --- Application crashes (Event ID 1000 / Application Error) -----------
    $appCrashes = & $countEvents @{ LogName = 'Application'; Id = 1000; StartTime = $start; EndTime = $end }
    Set-OmniResultMetric -Result $result -Name 'AppCrashes' -Value $appCrashes

    # --- Application hangs (Event ID 1002) --------------------------------
    $appHangs = & $countEvents @{ LogName = 'Application'; Id = 1002; StartTime = $start; EndTime = $end }
    Set-OmniResultMetric -Result $result -Name 'AppHangs' -Value $appHangs

    # --- Unexpected shutdowns / bugchecks (System Event ID 41) ------------
    $unexpectedShutdowns = & $countEvents @{ LogName = 'System'; Id = 41; StartTime = $start; EndTime = $end }
    Set-OmniResultMetric -Result $result -Name 'UnexpectedShutdowns' -Value $unexpectedShutdowns

    $rangeLabel = $Context.TimeRange.Label

    if ($appCrashes -gt 5) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title "$appCrashes application crashes ($rangeLabel)" -Severity 'Warning' `
            -Component 'Reliability/Crashes' `
            -Detail "The Application log recorded $appCrashes crash events (ID 1000) in the selected range." `
            -LikelyCause 'A faulty application, driver, or corrupted install may be crashing repeatedly.' `
            -Confidence 65 `
            -Recommendation 'Review the crashing applications in Event Viewer and update or reinstall them.')
    }

    if ($unexpectedShutdowns -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title "$unexpectedShutdowns unexpected shutdown(s) ($rangeLabel)" -Severity 'Warning' `
            -Component 'Reliability/Shutdowns' `
            -Detail "The System log recorded $unexpectedShutdowns Kernel-Power (ID 41) events in the selected range." `
            -LikelyCause 'Power loss, overheating, failing hardware, or a bugcheck (BSOD).' `
            -Confidence 60 `
            -Recommendation 'Check for overheating, power issues, and driver stability; review minidumps if present.')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'System stability looks healthy' -Severity 'Pass' -Component 'Reliability' `
            -Detail "No elevated crash, hang, or unexpected-shutdown activity was found for $rangeLabel.")
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
