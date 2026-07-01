<#
.SYNOPSIS
    OmniDiag diagnostic module: Drivers.

.DESCRIPTION
    Counts signed drivers via Win32_PnPSignedDriver and detects problem devices
    via Win32_PnPEntity ConfigManagerErrorCode.

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
        Name          = 'Drivers'
        Category      = 'System'
        Description   = 'Driver inventory and problem-device detection.'
        RequiresAdmin = $false
        Order         = 140
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

    $result = New-OmniResult -ModuleName 'Drivers' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Signed driver count ----------------------------------------------
    try {
        $drivers = @(Get-CimInstance -ClassName 'Win32_PnPSignedDriver' -ErrorAction Stop)
        Set-OmniResultMetric -Result $result -Name 'DriverCount' -Value $drivers.Count
    } catch {
        $log.Warn("CIM query failed for Win32_PnPSignedDriver: $($_.Exception.Message)", 'Drivers')
    }

    # --- Problem devices --------------------------------------------------
    try {
        $problems = @(Get-CimInstance -ClassName 'Win32_PnPEntity' -ErrorAction Stop |
            Where-Object { $null -ne $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
        Set-OmniResultMetric -Result $result -Name 'ProblemDeviceCount' -Value $problems.Count

        if ($problems.Count -gt 0) {
            $details = @($problems | ForEach-Object {
                $name = if ($_.Name) { $_.Name } else { $_.DeviceID }
                "{0} (error {1})" -f $name, $_.ConfigManagerErrorCode
            })
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("$($problems.Count) device(s) reporting problems") -Severity 'Warning' `
                -Component 'System/Drivers' `
                -Detail ("Devices with a Device Manager error: " + ($details -join '; ')) `
                -LikelyCause 'Missing, corrupt, or incompatible drivers, or disabled/failed hardware.' `
                -Confidence 70 `
                -Recommendation 'Update or reinstall the affected device drivers via Device Manager or the vendor.')
        }
    } catch {
        $log.Warn("CIM query failed for Win32_PnPEntity: $($_.Exception.Message)", 'Drivers')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No device problems detected' -Severity 'Pass' -Component 'System/Drivers' `
            -Detail 'Driver inventory collected and no devices are reporting errors.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
