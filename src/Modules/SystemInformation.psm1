<#
.SYNOPSIS
    OmniDiag diagnostic module: System Information.

.DESCRIPTION
    Reference implementation of the OmniDiag plugin contract. Collects core device
    inventory (hardware, firmware, OS) via CIM/WMI and emits both metrics (for the
    dashboard) and interpreted findings (TPM / Secure Boot / low-memory posture).

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

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'System Information'
        Category      = 'System'
        Description   = 'Hardware, firmware, and operating system inventory.'
        RequiresAdmin = $false
        Order         = 10
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

    $result = New-OmniResult -ModuleName 'System Information' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # Helper: run a CIM query, log + swallow failures, return $null on error.
    $cim = {
        param([string] $Class, [string] $Namespace = 'root/cimv2')
        try {
            return Get-CimInstance -ClassName $Class -Namespace $Namespace -ErrorAction Stop
        } catch {
            $log.Warn("CIM query failed for ${Class}: $($_.Exception.Message)", 'System Information')
            return $null
        }
    }

    # --- Computer system / identity ---------------------------------------
    $cs = & $cim 'Win32_ComputerSystem'
    if ($cs) {
        Set-OmniResultMetric -Result $result -Name 'Manufacturer' -Value $cs.Manufacturer
        Set-OmniResultMetric -Result $result -Name 'Model'        -Value $cs.Model
        Set-OmniResultMetric -Result $result -Name 'Hostname'     -Value $cs.Name
        Set-OmniResultMetric -Result $result -Name 'CurrentUser'  -Value $cs.UserName
        Set-OmniResultMetric -Result $result -Name 'Domain'       -Value $cs.Domain

        $ramGb = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 1)
        Set-OmniResultMetric -Result $result -Name 'TotalRAMGB' -Value $ramGb
        if ($ramGb -gt 0 -and $ramGb -lt 8) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title "Low installed memory ($ramGb GB)" -Severity 'Warning' -Component 'System/Memory' `
                -Detail "The device has $ramGb GB of RAM." `
                -LikelyCause 'Below the 8 GB practical minimum for a modern business workload.' `
                -Confidence 70 `
                -Recommendation 'Consider a memory upgrade if the user reports slowness with multiple apps open.')
        }
    } else {
        Set-OmniResultMetric -Result $result -Name 'Hostname' -Value $Context.Host.ComputerName
    }

    # --- BIOS / serial ----------------------------------------------------
    $bios = & $cim 'Win32_BIOS'
    if ($bios) {
        Set-OmniResultMetric -Result $result -Name 'SerialNumber'   -Value $bios.SerialNumber
        Set-OmniResultMetric -Result $result -Name 'BIOSVersion'    -Value ($bios.SMBIOSBIOSVersion)
        Set-OmniResultMetric -Result $result -Name 'BIOSReleaseDate' -Value $bios.ReleaseDate
    }

    # --- Motherboard ------------------------------------------------------
    $board = & $cim 'Win32_BaseBoard'
    if ($board) {
        Set-OmniResultMetric -Result $result -Name 'Motherboard' -Value ("{0} {1}" -f $board.Manufacturer, $board.Product)
    }

    # --- CPU --------------------------------------------------------------
    $cpu = & $cim 'Win32_Processor' | Select-Object -First 1
    if ($cpu) {
        Set-OmniResultMetric -Result $result -Name 'CPU'          -Value $cpu.Name.Trim()
        Set-OmniResultMetric -Result $result -Name 'CPUCores'     -Value $cpu.NumberOfCores
        Set-OmniResultMetric -Result $result -Name 'CPUThreads'   -Value $cpu.NumberOfLogicalProcessors
        Set-OmniResultMetric -Result $result -Name 'CPUMaxClockMHz' -Value $cpu.MaxClockSpeed
    }

    # --- GPU --------------------------------------------------------------
    $gpu = & $cim 'Win32_VideoController'
    if ($gpu) {
        Set-OmniResultMetric -Result $result -Name 'GPU' -Value (($gpu | ForEach-Object { $_.Name }) -join '; ')
    }

    # --- OS ---------------------------------------------------------------
    $os = & $cim 'Win32_OperatingSystem'
    if ($os) {
        Set-OmniResultMetric -Result $result -Name 'OS'            -Value $os.Caption
        Set-OmniResultMetric -Result $result -Name 'OSVersion'     -Value $os.Version
        Set-OmniResultMetric -Result $result -Name 'BuildNumber'   -Value $os.BuildNumber
        Set-OmniResultMetric -Result $result -Name 'Architecture'  -Value $os.OSArchitecture
        try {
            $uptime = (Get-Date) - $os.LastBootUpTime
            Set-OmniResultMetric -Result $result -Name 'UptimeDays' -Value ([math]::Round($uptime.TotalDays, 1))
            if ($uptime.TotalDays -gt 14) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("System uptime is {0:N0} days" -f $uptime.TotalDays) -Severity 'Warning' `
                    -Component 'System/Uptime' `
                    -Detail 'The system has not been restarted in over two weeks.' `
                    -LikelyCause 'Long uptime can defer pending updates and accumulate memory pressure.' `
                    -Confidence 60 `
                    -Recommendation 'Restart the device to apply pending updates and clear transient issues.')
            }
        } catch { }
    }

    # --- TPM --------------------------------------------------------------
    try {
        $tpm = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
        if ($tpm) {
            Set-OmniResultMetric -Result $result -Name 'TPMPresent'    -Value $true
            Set-OmniResultMetric -Result $result -Name 'TPMVersion'    -Value ($tpm.SpecVersion)
            Set-OmniResultMetric -Result $result -Name 'TPMEnabled'    -Value ([bool]$tpm.IsEnabled_InitialValue)
        }
    } catch {
        Set-OmniResultMetric -Result $result -Name 'TPMPresent' -Value $false
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No TPM detected' -Severity 'Warning' -Component 'System/Security' `
            -Detail 'A Trusted Platform Module was not found via WMI.' `
            -LikelyCause 'TPM disabled in firmware, not present, or query blocked.' `
            -Confidence 50 `
            -Recommendation 'A TPM 2.0 is required for Windows 11 and BitLocker. Check firmware (UEFI) settings.')
    }

    # --- Secure Boot (best-effort; needs UEFI, sometimes elevation) -------
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        Set-OmniResultMetric -Result $result -Name 'SecureBoot' -Value ([bool]$sb)
        if (-not $sb) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'Secure Boot is disabled' -Severity 'Warning' -Component 'System/Security' `
                -Detail 'Secure Boot is supported but currently disabled.' `
                -LikelyCause 'Disabled in UEFI firmware.' -Confidence 80 `
                -Recommendation 'Enable Secure Boot in UEFI for boot integrity (required for Windows 11).')
        }
    } catch {
        Set-OmniResultMetric -Result $result -Name 'SecureBoot' -Value 'Unknown'
        $log.Debug("Secure Boot state unavailable: $($_.Exception.Message)", 'System Information')
    }

    # --- Virtualization firmware ------------------------------------------
    if ($cpu) {
        try {
            Set-OmniResultMetric -Result $result -Name 'VirtualizationFirmwareEnabled' -Value ([bool]$cpu.VirtualizationFirmwareEnabled)
        } catch { }
    }

    # --- Installed software count -----------------------------------------
    try {
        $uninstallPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $apps = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } | Select-Object -ExpandProperty DisplayName -Unique
        Set-OmniResultMetric -Result $result -Name 'InstalledSoftwareCount' -Value (@($apps).Count)
    } catch {
        $log.Debug("Installed-software enumeration failed: $($_.Exception.Message)", 'System Information')
    }

    # Always record at least one positive finding so the module reads as 'Healthy'
    # when nothing is wrong (keeps the dashboard honest).
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'System inventory collected' -Severity 'Pass' -Component 'System' `
            -Detail 'Hardware, firmware, and OS details were collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
