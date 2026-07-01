<#
.SYNOPSIS
    OmniDiag diagnostic module: Scheduled Tasks.

.DESCRIPTION
    Enumerates scheduled tasks via Get-ScheduledTask, counting enabled tasks and
    enabled non-Microsoft tasks, and best-effort flags third-party tasks running
    as SYSTEM at logon.

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
        Name          = 'Scheduled Tasks'
        Category      = 'System'
        Description   = 'Enabled and third-party scheduled task inventory.'
        RequiresAdmin = $false
        Order         = 120
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

    $result = New-OmniResult -ModuleName 'Scheduled Tasks' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $tasks = $null
    try {
        if (-not (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
            $log.Warn('Get-ScheduledTask is not available on this system; skipping.', 'Scheduled Tasks')
            return (Complete-OmniResult -Result $result -Status 'Skipped')
        }
        $tasks = @(Get-ScheduledTask -ErrorAction Stop)
    } catch {
        $log.Warn("Get-ScheduledTask failed: $($_.Exception.Message)", 'Scheduled Tasks')
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    $enabled = @($tasks | Where-Object { $_.State -ne 'Disabled' })
    $thirdParty = @($enabled | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })

    Set-OmniResultMetric -Result $result -Name 'EnabledTaskCount'    -Value $enabled.Count
    Set-OmniResultMetric -Result $result -Name 'ThirdPartyTaskCount' -Value $thirdParty.Count

    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
        -Title ("$($enabled.Count) enabled scheduled task(s)") -Severity 'Information' -Component 'System/ScheduledTasks' `
        -Detail ("$($enabled.Count) enabled tasks, of which $($thirdParty.Count) are non-Microsoft."))

    # --- Best-effort: third-party tasks running as SYSTEM at logon ---------
    try {
        $risky = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $thirdParty) {
            try {
                $principal = $t.Principal
                $userId = if ($principal) { [string]$principal.UserId } else { '' }
                $isSystem = $userId -match '(?i)SYSTEM'
                $atLogon = $false
                foreach ($trig in @($t.Triggers)) {
                    if ($null -ne $trig -and $trig.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') {
                        $atLogon = $true
                    }
                }
                if ($isSystem -and $atLogon) {
                    $risky.Add(("{0}{1}" -f $t.TaskPath, $t.TaskName))
                }
            } catch {
                $log.Debug("Failed to inspect task '$($t.TaskName)': $($_.Exception.Message)", 'Scheduled Tasks')
            }
        }
        if ($risky.Count -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("$($risky.Count) third-party task(s) run as SYSTEM at logon") -Severity 'Warning' `
                -Component 'System/ScheduledTasks' `
                -Detail ("The following non-Microsoft tasks run as SYSTEM at logon: " + (($risky | Select-Object -First 10) -join '; ')) `
                -LikelyCause 'Third-party software configured a high-privilege autostart task.' `
                -Confidence 45 `
                -Recommendation 'Verify these tasks are legitimate and required.')
        }
    } catch {
        $log.Debug("SYSTEM-at-logon inspection failed: $($_.Exception.Message)", 'Scheduled Tasks')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Scheduled tasks inventory collected' -Severity 'Pass' -Component 'System/ScheduledTasks' `
            -Detail 'Scheduled tasks were enumerated without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
