<#
.SYNOPSIS
    OmniDiag diagnostic module: Services.

.DESCRIPTION
    Inventories Windows services via Win32_Service, counting running and stopped
    services and flagging automatic-start services that are not running.

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
        Name          = 'Services'
        Category      = 'System'
        Description   = 'Windows service inventory and stopped auto-start detection.'
        RequiresAdmin = $false
        Order         = 130
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

    $result = New-OmniResult -ModuleName 'Services' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $services = $null
    try {
        $services = @(Get-CimInstance -ClassName 'Win32_Service' -ErrorAction Stop)
    } catch {
        $log.Warn("CIM query failed for Win32_Service: $($_.Exception.Message)", 'Services')
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    $total   = $services.Count
    $running = @($services | Where-Object { $_.State -eq 'Running' }).Count
    $stopped = @($services | Where-Object { $_.State -eq 'Stopped' }).Count

    Set-OmniResultMetric -Result $result -Name 'ServiceCount'        -Value $total
    Set-OmniResultMetric -Result $result -Name 'RunningServiceCount' -Value $running
    Set-OmniResultMetric -Result $result -Name 'StoppedServiceCount' -Value $stopped

    # --- Automatic-start services that are stopped ------------------------
    try {
        $autoStopped = @($services | Where-Object {
            $_.StartMode -eq 'Auto' -and $_.State -eq 'Stopped' -and
            -not ($_.PSObject.Properties.Name -contains 'DelayedAutoStart' -and $_.DelayedAutoStart)
        })
        Set-OmniResultMetric -Result $result -Name 'AutoStoppedServiceCount' -Value $autoStopped.Count

        if ($autoStopped.Count -gt 0) {
            $names = @($autoStopped | Select-Object -First 10 | ForEach-Object { $_.DisplayName })
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("$($autoStopped.Count) automatic service(s) are stopped") -Severity 'Warning' `
                -Component 'System/Services' `
                -Detail ("Automatic-start services currently stopped (first 10): " + ($names -join '; ')) `
                -LikelyCause 'A service set to start automatically failed to start or was stopped.' `
                -Confidence 55 `
                -Recommendation 'Investigate these services; some may indicate a failed dependency or misconfiguration.')
        }
    } catch {
        $log.Debug("Auto-stopped service detection failed: $($_.Exception.Message)", 'Services')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Services healthy' -Severity 'Pass' -Component 'System/Services' `
            -Detail "$running of $total services running; no stopped automatic services detected.")
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
