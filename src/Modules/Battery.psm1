<#
.SYNOPSIS
    OmniDiag diagnostic module: Battery.

.DESCRIPTION
    Reports battery presence, charge level, and AC status from Win32_Battery, and
    makes a best-effort wear estimate from the root/wmi design vs full-charge
    capacity classes.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Battery'
        Category      = 'Hardware'
        Description   = 'Battery presence, charge level, AC status, and wear.'
        RequiresAdmin = $false
        Order         = 270
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

    $result = New-OmniResult -ModuleName 'Battery' -Category 'Hardware' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $battery = $null
    try {
        $battery = Get-CimInstance -ClassName 'Win32_Battery' -ErrorAction Stop | Select-Object -First 1
    } catch {
        $log.Debug("Win32_Battery query failed: $($_.Exception.Message)", 'Battery')
    }

    if (-not $battery) {
        Set-OmniResultMetric -Result $result -Name 'BatteryPresent' -Value $false
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No battery detected (desktop or VM)' -Severity 'Information' `
            -Component 'Hardware/Battery' `
            -Detail 'No battery was reported by Win32_Battery.')
        return (Complete-OmniResult -Result $result)
    }

    Set-OmniResultMetric -Result $result -Name 'BatteryPresent' -Value $true

    # --- Charge / AC -----------------------------------------------------
    $charge = $null
    $onAc = $null
    try {
        $charge = [int]$battery.EstimatedChargeRemaining
        Set-OmniResultMetric -Result $result -Name 'ChargePercent' -Value $charge
        # BatteryStatus: 1 = Discharging (on battery), 2 = AC connected.
        $onAc = ($battery.BatteryStatus -eq 2)
        Set-OmniResultMetric -Result $result -Name 'OnAC' -Value $onAc
    } catch {
        $log.Debug("Battery status parse failed: $($_.Exception.Message)", 'Battery')
    }

    # --- Wear (best-effort) ----------------------------------------------
    $wearPct = $null
    try {
        $static = Get-CimInstance -Namespace 'root/wmi' -ClassName 'BatteryStaticData' -ErrorAction Stop | Select-Object -First 1
        $full   = Get-CimInstance -Namespace 'root/wmi' -ClassName 'BatteryFullChargedCapacity' -ErrorAction Stop | Select-Object -First 1
        if ($static -and $full -and $static.DesignedCapacity -gt 0) {
            $designed = [double]$static.DesignedCapacity
            $fullCap  = [double]$full.FullChargedCapacity
            $wearPct = [math]::Round((1 - ($fullCap / $designed)) * 100, 1)
            if ($wearPct -lt 0) { $wearPct = 0 }
            Set-OmniResultMetric -Result $result -Name 'WearPercent' -Value $wearPct
        }
    } catch {
        $log.Debug("Battery wear data unavailable: $($_.Exception.Message)", 'Battery')
    }

    # --- Posture ---------------------------------------------------------
    try {
        if ($null -ne $wearPct -and $wearPct -gt 25) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Battery wear at {0}%" -f $wearPct) -Severity 'Warning' `
                -Component 'Hardware/Battery' `
                -Detail "The battery has lost about $wearPct percent of its design capacity." `
                -LikelyCause 'Normal battery aging or heavy charge cycling.' `
                -Confidence 65 `
                -Recommendation 'Consider a battery replacement if runtime is inadequate.')
        }
        if ($null -ne $charge -and $charge -lt 20 -and $onAc -eq $false) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Low battery charge ({0}%)" -f $charge) -Severity 'Warning' `
                -Component 'Hardware/Battery' `
                -Detail "Charge is at $charge percent and the device is running on battery." `
                -LikelyCause 'The device is not connected to AC power.' `
                -Confidence 80 `
                -Recommendation 'Connect the charger to avoid an unexpected shutdown.')
        }
    } catch {
        $log.Debug("Battery posture evaluation failed: $($_.Exception.Message)", 'Battery')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Battery metrics collected' -Severity 'Pass' -Component 'Hardware/Battery' `
            -Detail 'Battery charge and health details were collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
