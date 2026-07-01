<#
.SYNOPSIS
    OmniDiag diagnostic module: System.

.DESCRIPTION
    Collects core operating system, firmware, and hardware identity details via
    CIM and reports uptime posture.

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
        Name          = 'System'
        Category      = 'System'
        Description   = 'Operating system, firmware, and hardware identity inventory.'
        RequiresAdmin = $false
        Order         = 100
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

    $result = New-OmniResult -ModuleName 'System' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Operating system -------------------------------------------------
    try {
        $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
        if ($os) {
            Set-OmniResultMetric -Result $result -Name 'OSCaption'      -Value $os.Caption
            Set-OmniResultMetric -Result $result -Name 'OSVersion'      -Value $os.Version
            Set-OmniResultMetric -Result $result -Name 'OSBuildNumber'  -Value $os.BuildNumber
            Set-OmniResultMetric -Result $result -Name 'OSArchitecture' -Value $os.OSArchitecture

            try {
                Set-OmniResultMetric -Result $result -Name 'LastBootUpTime' -Value $os.LastBootUpTime
                $uptime = (Get-Date) - $os.LastBootUpTime
                $uptimeDays = [math]::Round($uptime.TotalDays, 1)
                Set-OmniResultMetric -Result $result -Name 'UptimeDays' -Value $uptimeDays
                if ($uptime.TotalDays -gt 14) {
                    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                        -Title ("System uptime is {0:N0} days" -f $uptime.TotalDays) -Severity 'Warning' `
                        -Component 'System/Uptime' `
                        -Detail 'The system has not been restarted in over two weeks.' `
                        -LikelyCause 'Long uptime can defer pending updates and accumulate memory pressure.' `
                        -Confidence 60 `
                        -Recommendation 'Restart the device to apply pending updates and clear transient issues.')
                }
            } catch {
                $log.Debug("Uptime calculation failed: $($_.Exception.Message)", 'System')
            }
        }
    } catch {
        $log.Warn("CIM query failed for Win32_OperatingSystem: $($_.Exception.Message)", 'System')
    }

    # --- Computer system / identity ---------------------------------------
    try {
        $cs = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction Stop
        if ($cs) {
            Set-OmniResultMetric -Result $result -Name 'Hostname'     -Value $cs.Name
            Set-OmniResultMetric -Result $result -Name 'Manufacturer' -Value $cs.Manufacturer
            Set-OmniResultMetric -Result $result -Name 'Model'        -Value $cs.Model
        }
    } catch {
        $log.Warn("CIM query failed for Win32_ComputerSystem: $($_.Exception.Message)", 'System')
    }

    # --- BIOS / serial ----------------------------------------------------
    try {
        $bios = Get-CimInstance -ClassName 'Win32_BIOS' -ErrorAction Stop
        if ($bios) {
            Set-OmniResultMetric -Result $result -Name 'SerialNumber'    -Value $bios.SerialNumber
            Set-OmniResultMetric -Result $result -Name 'BIOSVersion'     -Value $bios.SMBIOSBIOSVersion
            Set-OmniResultMetric -Result $result -Name 'BIOSReleaseDate' -Value $bios.ReleaseDate
        }
    } catch {
        $log.Warn("CIM query failed for Win32_BIOS: $($_.Exception.Message)", 'System')
    }

    # --- Motherboard ------------------------------------------------------
    try {
        $board = Get-CimInstance -ClassName 'Win32_BaseBoard' -ErrorAction Stop
        if ($board) {
            Set-OmniResultMetric -Result $result -Name 'Motherboard' -Value ("{0} {1}" -f $board.Manufacturer, $board.Product)
        }
    } catch {
        $log.Warn("CIM query failed for Win32_BaseBoard: $($_.Exception.Message)", 'System')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'System inventory collected' -Severity 'Pass' -Component 'System' `
            -Detail 'Operating system, firmware, and hardware identity details were collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
