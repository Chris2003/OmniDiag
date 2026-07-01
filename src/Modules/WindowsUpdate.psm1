<#
.SYNOPSIS
    OmniDiag diagnostic module: Windows Update.

.DESCRIPTION
    Reports installed hotfix posture (count and most-recent install date) via
    Get-HotFix and the state of the Windows Update service. Warns when the most
    recent update is older than 60 days. Fails soft; never throws.

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
        Name          = 'Windows Update'
        Category      = 'System'
        Description   = 'Installed hotfix posture and Windows Update service state.'
        RequiresAdmin = $false
        Order         = 190
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

    $result = New-OmniResult -ModuleName 'Windows Update' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Hotfixes ---------------------------------------------------------
    $lastUpdate = $null
    try {
        $hotfixes = Get-HotFix -ErrorAction Stop
        $count = @($hotfixes).Count
        Set-OmniResultMetric -Result $result -Name 'HotfixCount' -Value $count

        $dated = @($hotfixes | Where-Object { $_.PSObject.Properties['InstalledOn'] -and $_.InstalledOn })
        if ($dated.Count -gt 0) {
            $lastUpdate = ($dated | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1).InstalledOn
            Set-OmniResultMetric -Result $result -Name 'LastUpdateInstalled' -Value $lastUpdate

            $ageDays = ((Get-Date) - $lastUpdate).TotalDays
            if ($ageDays -gt 60) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("Most recent update is {0:N0} days old" -f $ageDays) -Severity 'Warning' `
                    -Component 'System/Updates' `
                    -Detail ("The last installed update was on {0:yyyy-MM-dd}." -f $lastUpdate) `
                    -LikelyCause 'The system may be missing recent security updates.' `
                    -Confidence 70 `
                    -Recommendation 'Run Windows Update to install the latest quality and security updates.')
            }
        }
    } catch {
        $log.Warn("Get-HotFix failed: $($_.Exception.Message)", 'Windows Update')
    }

    # --- Windows Update service state -------------------------------------
    try {
        $svc = Get-Service -Name 'wuauserv' -ErrorAction Stop
        Set-OmniResultMetric -Result $result -Name 'WuauservStatus' -Value ([string]$svc.Status)
    } catch {
        $log.Warn("wuauserv service query failed: $($_.Exception.Message)", 'Windows Update')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Windows Update posture healthy' -Severity 'Pass' -Component 'System/Updates' `
            -Detail 'Update history was collected and no stale-update issues were detected.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
