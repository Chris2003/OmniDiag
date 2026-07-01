<#
.SYNOPSIS
    OmniDiag diagnostic module: USB Devices.

.DESCRIPTION
    Enumerates USB devices via CIM/PnP and flags any that report a device-manager
    error. Emits a device count metric plus a list of device names.

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
        Name          = 'USB Devices'
        Category      = 'Hardware'
        Description   = 'Enumerates connected USB devices and flags device errors.'
        RequiresAdmin = $false
        Order         = 280
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

    $result = New-OmniResult -ModuleName 'USB Devices' -Category 'Hardware' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $devices = $null

    # Prefer Get-PnpDevice (richer status), fall back to CIM Win32_PnPEntity.
    try {
        if (Get-Command -Name 'Get-PnpDevice' -ErrorAction SilentlyContinue) {
            # -PresentOnly: exclude phantom/previously-connected devices, which report
            # a non-zero "not present" error code and would be flagged as false errors.
            $devices = @(Get-PnpDevice -Class 'USB' -PresentOnly -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name       = $_.FriendlyName
                    PnpId      = $_.InstanceId
                    Status     = $_.Status
                    ErrorCode  = $_.ConfigManagerErrorCode
                }
            })
        }
    } catch {
        $log.Warn("Get-PnpDevice failed: $($_.Exception.Message)", 'USB Devices')
        $devices = $null
    }

    if ($null -eq $devices) {
        try {
            $devices = @(Get-CimInstance -ClassName 'Win32_PnPEntity' -ErrorAction Stop |
                Where-Object { $_.PNPDeviceID -like 'USB*' } | ForEach-Object {
                    [pscustomobject]@{
                        Name      = $_.Name
                        PnpId     = $_.PNPDeviceID
                        Status    = $_.Status
                        ErrorCode = $_.ConfigManagerErrorCode
                    }
                })
        } catch {
            $log.Warn("CIM query failed for Win32_PnPEntity: $($_.Exception.Message)", 'USB Devices')
            $devices = @()
        }
    }

    Set-OmniResultMetric -Result $result -Name 'UsbDeviceCount' -Value (@($devices).Count)

    try {
        $names = @($devices | ForEach-Object { $_.Name } | Where-Object { $_ })
        Set-OmniResultMetric -Result $result -Name 'UsbDeviceNames' -Value $names
    } catch {
        $log.Debug("USB name list failed: $($_.Exception.Message)", 'USB Devices')
    }

    # Flag any device reporting an error.
    try {
        $errored = @($devices | Where-Object {
            ($null -ne $_.ErrorCode -and $_.ErrorCode -ne 0) -or ($_.Status -eq 'Error')
        })
        Set-OmniResultMetric -Result $result -Name 'UsbErrorCount' -Value $errored.Count
        foreach ($d in $errored) {
            $label = if ($d.Name) { $d.Name } else { $d.PnpId }
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title "USB device reporting an error: $label" -Severity 'Warning' `
                -Component 'Hardware/USB' `
                -Detail "Device '$label' reports error code $($d.ErrorCode) / status '$($d.Status)'." `
                -LikelyCause 'Driver problem, disconnected/failed device, or resource conflict.' `
                -Confidence 65 `
                -Recommendation 'Reconnect the device, update or reinstall its driver, or check Device Manager.')
        }
    } catch {
        $log.Debug("USB error scan failed: $($_.Exception.Message)", 'USB Devices')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'USB devices enumerated' -Severity 'Pass' -Component 'Hardware/USB' `
            -Detail 'All detected USB devices are operating without reported errors.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
