<#
.SYNOPSIS
    OmniDiag diagnostic module: Windows Health.

.DESCRIPTION
    Checks overall OS servicing health: pending reboot state, Device Manager problem
    devices, automatic services that are not running, the Windows Update service, and
    startup program count.

    Deep component checks (SFC /scannow, DISM /RestoreHealth) take minutes and would
    blow the ~2-minute scan target, so they are NOT run here - they live in the
    Version 2 Repair Center. They can be opted into via Config ('RunSfc' / 'RunDism')
    for a deep, elevated scan.

    Per-run options (via $Context.Config):
        RunSfc    bool  Run 'sfc /verifyonly' (slow, admin). Default $false.
        RunDism   bool  Run 'DISM /CheckHealth' (admin). Default $false.
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
        Category      = 'Health'
        Description   = 'Pending reboot, device errors, service state, and update health.'
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
    $cfg = $Context.Config

    # --- Pending reboot ---------------------------------------------------
    $reasons = @(Test-OmniPendingReboot)
    Set-OmniResultMetric -Result $result -Name 'PendingReboot' -Value ($reasons.Count -gt 0)
    if ($reasons.Count -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'A system restart is pending' -Severity 'Warning' `
            -Component 'Health/Servicing' -Detail ("Pending reboot flagged by: {0}." -f ($reasons -join ', ')) `
            -LikelyCause 'Updates or installs have staged changes that apply on restart.' -Confidence 85 `
            -Recommendation 'Restart the device to finish applying pending changes.')
    }

    # --- Device Manager problem devices ----------------------------------
    try {
        $bad = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
        Set-OmniResultMetric -Result $result -Name 'ProblemDevices' -Value $bad.Count
        foreach ($dev in ($bad | Select-Object -First 20)) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Device problem: $($dev.Name)" -Severity 'Warning' `
                -Component 'Health/Devices' -Detail "Device Manager error code $($dev.ConfigManagerErrorCode) on '$($dev.Name)'." `
                -LikelyCause 'Missing/failed driver or a disabled or malfunctioning device.' -Confidence 65 `
                -Recommendation 'Update or reinstall the driver in Device Manager; check vendor support.' `
                -Data @{ Name = $dev.Name; ErrorCode = $dev.ConfigManagerErrorCode })
        }
    } catch { $log.Warn("Win32_PnPEntity query failed: $($_.Exception.Message)", 'Windows Health') }

    # --- Automatic services not running ----------------------------------
    try {
        $stopped = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and -not $_.DelayedAutoStart })
        Set-OmniResultMetric -Result $result -Name 'AutoServicesStopped' -Value $stopped.Count
        if ($stopped.Count -gt 0) {
            $names = ($stopped | Select-Object -First 15 | ForEach-Object { $_.DisplayName }) -join '; '
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "$($stopped.Count) automatic service(s) not running" -Severity 'Warning' `
                -Component 'Health/Services' -Detail "Auto-start services currently stopped: $names" `
                -LikelyCause 'A service failed to start or was stopped.' -Confidence 55 `
                -Recommendation 'Review the listed services; start them or investigate start failures in the System log.' `
                -Data ($stopped | Select-Object Name, DisplayName))
        }
    } catch { $log.Warn("Win32_Service query failed: $($_.Exception.Message)", 'Windows Health') }

    # --- Windows Update service state ------------------------------------
    try {
        $wu = Get-Service -Name 'wuauserv' -ErrorAction Stop
        Set-OmniResultMetric -Result $result -Name 'WindowsUpdateService' -Value ("{0} (StartType {1})" -f $wu.Status, $wu.StartType)
        if ($wu.StartType -eq 'Disabled') {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows Update service is disabled' -Severity 'Warning' `
                -Component 'Health/Update' -Detail 'The wuauserv service start type is Disabled.' `
                -LikelyCause 'Update service disabled by policy, tooling, or manual change.' -Confidence 70 `
                -Recommendation 'Re-enable Windows Update unless intentionally managed elsewhere.')
        }
    } catch { $log.Debug("Could not query wuauserv: $($_.Exception.Message)", 'Windows Health') }

    # --- Startup programs (informational) --------------------------------
    try {
        $startup = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop)
        Set-OmniResultMetric -Result $result -Name 'StartupPrograms' -Value $startup.Count
    } catch { }

    # --- Optional deep checks (opt-in; slow; admin) ----------------------
    if (($cfg.ContainsKey('RunSfc') -and $cfg['RunSfc'])) {
        if ($Context.IsAdmin) {
            $log.Info('Running sfc /verifyonly (this can take several minutes)...', 'Windows Health')
            try {
                $sfc = & "$env:SystemRoot\System32\sfc.exe" /verifyonly 2>&1 | Out-String
                $clean = $sfc -match 'did not find any integrity violations'
                Set-OmniResultMetric -Result $result -Name 'SfcResult' -Value $(if ($clean) { 'No integrity violations' } else { 'Violations or unknown' })
                if (-not $clean) {
                    Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'SFC reported possible integrity violations' -Severity 'Warning' `
                        -Component 'Health/Components' -Detail 'sfc /verifyonly did not report a clean result.' `
                        -LikelyCause 'System file corruption may be present.' -Confidence 50 `
                        -Recommendation 'Run "sfc /scannow" and "DISM /Online /Cleanup-Image /RestoreHealth" from an elevated prompt.')
                }
            } catch { $log.Warn("SFC failed: $($_.Exception.Message)", 'Windows Health') }
        } else {
            $log.Warn('RunSfc requested but not elevated; skipping.', 'Windows Health')
        }
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Windows health checks passed' -Severity 'Pass' `
            -Component 'Health' -Detail 'No pending reboot, device errors, or stopped automatic services detected.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
