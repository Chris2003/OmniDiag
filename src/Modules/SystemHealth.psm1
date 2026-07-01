<#
.SYNOPSIS
    OmniDiag diagnostic module: System Health.

.DESCRIPTION
    Detects a pending reboot by inspecting the well-known servicing / Windows
    Update / Session Manager markers, and records the timestamp of the newest CBS
    log if present. Does NOT run SFC or DISM. Fails soft; never throws.

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
        Name          = 'System Health'
        Category      = 'System'
        Description   = 'Pending-reboot detection and servicing log freshness.'
        RequiresAdmin = $false
        Order         = 200
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

    $result = New-OmniResult -ModuleName 'System Health' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Pending reboot detection -----------------------------------------
    $reasons = @()

    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            $reasons += 'Component Based Servicing'
        }
    } catch { $log.Debug("CBS reboot check failed: $($_.Exception.Message)", 'System Health') }

    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            $reasons += 'Windows Update'
        }
    } catch { $log.Debug("WU reboot check failed: $($_.Exception.Message)", 'System Health') }

    try {
        $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if ($sm.PSObject.Properties['PendingFileRenameOperations'] -and $sm.PendingFileRenameOperations) {
            $reasons += 'Pending file rename operations'
        }
    } catch { $log.Debug("Session Manager reboot check failed: $($_.Exception.Message)", 'System Health') }

    $pending = ($reasons.Count -gt 0)
    Set-OmniResultMetric -Result $result -Name 'PendingReboot' -Value $pending
    Set-OmniResultMetric -Result $result -Name 'PendingRebootReasons' -Value ($reasons -join '; ')

    if ($pending) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'A system reboot is pending' -Severity 'Warning' -Component 'System/Servicing' `
            -Detail ("Pending reboot markers found: {0}." -f ($reasons -join ', ')) `
            -LikelyCause 'Updates or servicing operations require a restart to complete.' `
            -Confidence 85 `
            -Recommendation 'Restart the device to finish applying pending changes.')
    }

    # --- CBS log freshness ------------------------------------------------
    try {
        $cbsPath = 'C:\Windows\Logs\CBS\CBS.log'
        if (Test-Path $cbsPath) {
            $cbs = Get-Item -Path $cbsPath -ErrorAction Stop
            Set-OmniResultMetric -Result $result -Name 'CBSLogLastWrite' -Value $cbs.LastWriteTime
        }
    } catch {
        $log.Debug("CBS log read failed: $($_.Exception.Message)", 'System Health')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No pending reboot detected' -Severity 'Pass' -Component 'System/Servicing' `
            -Detail 'No servicing, Windows Update, or file-rename reboot markers were present.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
