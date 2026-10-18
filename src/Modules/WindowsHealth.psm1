<#
.SYNOPSIS
    OmniDiag diagnostic module: Windows Health.

.DESCRIPTION
    Checks overall OS servicing health: pending reboot state (the authoritative
    pending-reboot check of the updates group), the Windows Update service, and counts
    (metrics only) of Device Manager problem devices, automatic services that are not
    running, and startup programs. Per-device and per-service findings are owned by
    the Drivers and Services scanners, so they are not duplicated here.

    This scanner is read-only. It never runs SFC or DISM: component-store and system
    file repair live in the Repair Center (repair.run-system-file-checker-sfc and
    repair.repair-component-store-dism), which run only when a technician starts them.

    Pending reboot markers read:
        HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending
        HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired
        HKLM\SYSTEM\CurrentControlSet\Control\Session Manager : PendingFileRenameOperations
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Windows Health'
        Id            = 'updates.windows-health'
        Group         = 'updates'
        NetworkAccess = 'None'
        Category      = 'Health'
        Description   = 'Pending reboot, update service state, and device/service problem counts.'
        RequiresAdmin = $false
        Order         = 50
        Enabled       = $true
    }
}

function Test-OmniPendingReboot {
    [OutputType([string[]])]
    param()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $checks = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; Reason = 'Component-Based Servicing' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; Reason = 'Windows Update' }
    )
    foreach ($c in $checks) {
        if (Test-Path -LiteralPath $c.Path) { $reasons.Add($c.Reason) }
    }
    try {
        $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        if ($sm.PendingFileRenameOperations) { $reasons.Add('Pending file rename') }
    } catch { }
    return [string[]]$reasons
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Windows Health' -Category 'Health' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Pending reboot ---------------------------------------------------
    $reasons = @(Test-OmniPendingReboot)
    Set-OmniResultMetric -Result $result -Name 'PendingReboot' -Value ($reasons.Count -gt 0)
    Set-OmniResultMetric -Result $result -Name 'PendingRebootReasons' -Value ($reasons -join '; ')
    if ($reasons.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'A system restart is pending' -Severity 'Warning' `
            -Component 'Health/Servicing' -Detail ("Pending reboot flagged by: {0}." -f ($reasons -join ', ')) `
            -LikelyCause 'Updates or installs have staged changes that apply on restart.' -Confidence 85 `
            -Recommendation 'Restart the device to finish applying pending changes.' -Id 'windows-health-pending-reboot')
    }

    # --- Device Manager problem devices (count only) ----------------------
    # Per-device findings, with severities mapped from the error code, are owned by
    # Drivers (services.drivers); this scanner only records the count.
    try {
        $bad = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
        Set-OmniResultMetric -Result $result -Name 'ProblemDevices' -Value $bad.Count
    } catch { $log.Warn("Win32_PnPEntity query failed: $($_.Exception.Message)", 'Windows Health') }

    # --- Automatic services not running (count only) ---------------------
    # The per-service check (exit codes, trigger-start services) is owned by Services
    # (services.services); this scanner only records the count.
    try {
        $stopped = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and -not $_.DelayedAutoStart })
        Set-OmniResultMetric -Result $result -Name 'AutoServicesStopped' -Value $stopped.Count
    } catch { $log.Warn("Win32_Service query failed: $($_.Exception.Message)", 'Windows Health') }

    # --- Windows Update service state ------------------------------------
    try {
        $wu = Get-Service -Name 'wuauserv' -ErrorAction Stop
        Set-OmniResultMetric -Result $result -Name 'WindowsUpdateService' -Value ("{0} (StartType {1})" -f $wu.Status, $wu.StartType)
        if ($wu.StartType -eq 'Disabled') {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows Update service is disabled' -Severity 'Warning' `
                -Component 'Health/Update' -Detail 'The wuauserv service start type is Disabled.' `
                -LikelyCause 'Update service disabled by policy, tooling, or manual change.' -Confidence 70 `
                -Recommendation 'Re-enable Windows Update unless intentionally managed elsewhere.' -Id 'windows-health-wuauserv-disabled')
        }
    } catch { $log.Debug("Could not query wuauserv: $($_.Exception.Message)", 'Windows Health') }

    # --- Startup programs (informational) --------------------------------
    try {
        $startup = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop)
        Set-OmniResultMetric -Result $result -Name 'StartupPrograms' -Value $startup.Count
    } catch { }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows health checks passed' -Severity 'Pass' `
            -Component 'Health' -Detail 'No pending reboot and the Windows Update service is not disabled. Device problems and stopped services are reported by Drivers and Services.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
