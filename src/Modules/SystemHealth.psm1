<#
.SYNOPSIS
    OmniDiag diagnostic module: System Health.

.DESCRIPTION
    Records servicing log freshness: the last write time of the Component-Based
    Servicing log (%SystemRoot%\Logs\CBS\CBS.log). Read-only; does NOT run SFC or
    DISM. Fails soft; never throws.

    Pending reboot is reported by one authoritative check, the Windows Health scanner
    (updates.windows-health, finding 'windows-health-pending-reboot'); this scanner no
    longer raises its own copy of that finding.

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
        Id            = 'updates.system-health'
        Group         = 'updates'
        NetworkAccess = 'None'
        Category      = 'System'
        Description   = 'Servicing (CBS) log freshness; pending reboot is reported by Windows Health.'
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

    # Pending reboot: reported by Windows Health (updates.windows-health) only.
    Set-OmniResultMetric -Result $result -Name 'PendingRebootCheckedBy' -Value 'updates.windows-health'

    # --- CBS log freshness ------------------------------------------------
    $cbsFound = $false
    try {
        $winDir = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
        $cbsPath = Join-Path $winDir 'Logs\CBS\CBS.log'
        if (Test-Path -LiteralPath $cbsPath) {
            $cbs = Get-Item -LiteralPath $cbsPath -ErrorAction Stop
            Set-OmniResultMetric -Result $result -Name 'CBSLogLastWrite' -Value $cbs.LastWriteTime
            $cbsFound = $true
        }
    } catch {
        $log.Debug("CBS log read failed: $($_.Exception.Message)", 'System Health')
    }

    # Always record one finding.
    if ($cbsFound) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system-health-servicing-log' `
            -Title 'Servicing log collected' -Severity 'Pass' -Component 'System/Servicing' `
            -Detail 'The Component-Based Servicing log timestamp was recorded. Pending reboot is reported by the Windows Health scanner.')
    } else {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'system-health-servicing-log-not-found' `
            -Title 'Servicing log not found' -Severity 'Information' -Component 'System/Servicing' `
            -Detail 'The Component-Based Servicing log (Logs\CBS\CBS.log) was not found or could not be read. Pending reboot is reported by the Windows Health scanner.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
