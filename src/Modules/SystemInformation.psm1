<#
.SYNOPSIS
    OmniDiag diagnostic module: System Information.

.DESCRIPTION
    Reference implementation of the OmniDiag plugin contract and the system group's
    inventory scanner: what this machine is (identity, hardware, firmware, board, CPU,
    graphics, installed memory, operating system name). It reads the shared inventory
    from Get-OmniSystemInventory (src/Core/SystemInventory.psm1), which the GUI's
    System Information panel also uses, and emits it as metrics.

    Health checks on the same data (operating system support status, uptime, TPM,
    Secure Boot) belong to the System scanner (System.psm1), so no fact is reported
    twice. The only finding here is the installed-memory check, which is part of the
    hardware inventory.

    Read-only; local CIM and registry only; no network.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone (e.g. in
# Pester) as well as when loaded by the OmniDiag root module.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}
if (-not (Get-Command -Name 'Get-OmniSystemInventory' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\SystemInventory.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'System Information'
        Id            = 'system.system-information'
        Group         = 'system'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Hardware, firmware, and operating system inventory.'
        RequiresAdmin = $false
        Order         = 10
        Enabled       = $true
    }
}

function Get-OmniSysInfoInstalledAppName {
    <#
    .SYNOPSIS
        Internal: unique DisplayName values from the machine-wide uninstall keys.
    #>
    [OutputType([string[]])]
    param()
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return [string[]]@(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
        Select-Object -ExpandProperty DisplayName -Unique)
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'System Information' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $inv = Get-OmniSystemInventory -Section ComputerSystem, Bios, BaseBoard, Processor, VideoController, OperatingSystem
    foreach ($e in @($inv.Errors)) { if ($log) { $log.Warn("CIM query failed: $e", 'System Information') } }

    # --- Computer system / identity ---------------------------------------
    $cs = $inv.ComputerSystem
    if ($cs) {
        Set-OmniResultMetric -Result $result -Name 'Manufacturer' -Value $cs.Manufacturer
        Set-OmniResultMetric -Result $result -Name 'Model'        -Value $cs.Model
        Set-OmniResultMetric -Result $result -Name 'Hostname'     -Value $cs.Name
        Set-OmniResultMetric -Result $result -Name 'CurrentUser'  -Value $cs.UserName
        Set-OmniResultMetric -Result $result -Name 'Domain'       -Value $cs.Domain

        if ($null -ne $cs.TotalPhysicalMemory) {
            $ramGb = [math]::Round(([double]$cs.TotalPhysicalMemory / 1GB), 1)
            Set-OmniResultMetric -Result $result -Name 'TotalRAMGB' -Value $ramGb
            if ($ramGb -gt 0 -and $ramGb -lt 8) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system-information.memory-low' `
                    -Title "Low installed memory ($ramGb GB)" -Severity 'Warning' -Component 'System/Memory' `
                    -Detail "The device has $ramGb GB of RAM." `
                    -LikelyCause 'Below the 8 GB practical minimum for a modern business workload.' `
                    -Confidence 70 `
                    -Recommendation 'Consider a memory upgrade if the user reports slowness with multiple apps open.')
            }
        }
    } else {
        Set-OmniResultMetric -Result $result -Name 'Hostname' -Value $Context.Host.ComputerName
    }

    # --- BIOS / serial ----------------------------------------------------
    if ($inv.Bios) {
        Set-OmniResultMetric -Result $result -Name 'SerialNumber'    -Value $inv.Bios.SerialNumber
        Set-OmniResultMetric -Result $result -Name 'BIOSVersion'     -Value $inv.Bios.SMBIOSBIOSVersion
        Set-OmniResultMetric -Result $result -Name 'BIOSReleaseDate' -Value $inv.Bios.ReleaseDate
    }

    # --- Motherboard ------------------------------------------------------
    if ($inv.BaseBoard) {
        Set-OmniResultMetric -Result $result -Name 'Motherboard' -Value ("{0} {1}" -f $inv.BaseBoard.Manufacturer, $inv.BaseBoard.Product).Trim()
    }

    # --- CPU --------------------------------------------------------------
    $cpu = $inv.Processor
    if ($cpu) {
        Set-OmniResultMetric -Result $result -Name 'CPU'            -Value ([string]$cpu.Name).Trim()
        Set-OmniResultMetric -Result $result -Name 'CPUCores'       -Value $cpu.NumberOfCores
        Set-OmniResultMetric -Result $result -Name 'CPUThreads'     -Value $cpu.NumberOfLogicalProcessors
        Set-OmniResultMetric -Result $result -Name 'CPUMaxClockMHz' -Value $cpu.MaxClockSpeed
        if ($null -ne $cpu.VirtualizationFirmwareEnabled) {
            Set-OmniResultMetric -Result $result -Name 'VirtualizationFirmwareEnabled' -Value ([bool]$cpu.VirtualizationFirmwareEnabled)
        }
    }

    # --- GPU --------------------------------------------------------------
    $gpus = @($inv.VideoController | Where-Object { $_ -and $_.Name })
    if ($gpus.Count -gt 0) {
        Set-OmniResultMetric -Result $result -Name 'GPU' -Value (($gpus | ForEach-Object { $_.Name }) -join '; ')
    }

    # --- OS identity (support status, UBR, and uptime: System scanner) ---------
    if ($inv.OperatingSystem) {
        Set-OmniResultMetric -Result $result -Name 'OS'           -Value $inv.OperatingSystem.Caption
        Set-OmniResultMetric -Result $result -Name 'OSVersion'    -Value $inv.OperatingSystem.Version
        Set-OmniResultMetric -Result $result -Name 'BuildNumber'  -Value $inv.OperatingSystem.BuildNumber
        Set-OmniResultMetric -Result $result -Name 'Architecture' -Value $inv.OperatingSystem.OSArchitecture
        if ($inv.OperatingSystem.InstallDate) {
            Set-OmniResultMetric -Result $result -Name 'OSInstallDate' -Value $inv.OperatingSystem.InstallDate
        }
    }

    # --- Installed software count -----------------------------------------
    if (-not ($Context.CancellationToken -and $Context.CancellationToken.IsCancellationRequested)) {
        try {
            Set-OmniResultMetric -Result $result -Name 'InstalledSoftwareCount' -Value (@(Get-OmniSysInfoInstalledAppName).Count)
        } catch {
            if ($log) { $log.Debug("Installed-software enumeration failed: $($_.Exception.Message)", 'System Information') }
        }
    }

    if (-not $cs -and -not $inv.Bios -and -not $cpu -and -not $inv.OperatingSystem) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system-information.inventory-unavailable' `
            -Title 'System inventory is not available' -Severity 'Information' -Component 'System' `
            -Detail 'The hardware and operating system inventory (CIM/WMI) could not be read on this host.' `
            -LikelyCause 'Not a Windows host, or the WMI service or repository is unavailable.' `
            -Recommendation 'On Windows, confirm the Windows Management Instrumentation service is running, then re-run the scan.')
    } elseif (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system.system-information.inventory-collected' `
            -Title 'System inventory collected' -Severity 'Pass' -Component 'System' `
            -Detail 'Hardware, firmware, and operating system inventory was collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
