<#
.SYNOPSIS
    OmniDiag diagnostic module: Startup Performance.

.DESCRIPTION
    Reports last boot time and uptime, counts autostart items, and makes a
    best-effort read of the last boot duration from the Diagnostics-Performance
    operational event log.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Startup Performance'
        Category      = 'Performance'
        Description   = 'Boot time, uptime, autostart item count, and boot duration.'
        RequiresAdmin = $false
        Order         = 250
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

    $result = New-OmniResult -ModuleName 'Startup Performance' -Category 'Performance' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Boot time / uptime ----------------------------------------------
    try {
        $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
        if ($os) {
            Set-OmniResultMetric -Result $result -Name 'LastBootTime' -Value ($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))
            $uptime = (Get-Date) - $os.LastBootUpTime
            Set-OmniResultMetric -Result $result -Name 'UptimeDays' -Value ([math]::Round($uptime.TotalDays, 1))
        }
    } catch {
        $log.Warn("Win32_OperatingSystem query failed: $($_.Exception.Message)", 'Startup Performance')
    }

    # --- Autostart items -------------------------------------------------
    $startupCount = $null
    try {
        $startup = @(Get-CimInstance -ClassName 'Win32_StartupCommand' -ErrorAction Stop)
        $startupCount = $startup.Count
        Set-OmniResultMetric -Result $result -Name 'StartupItemCount' -Value $startupCount
    } catch {
        $log.Debug("Win32_StartupCommand query failed: $($_.Exception.Message)", 'Startup Performance')
    }

    # --- Boot duration (best-effort, may require admin) ------------------
    $bootMs = $null
    try {
        $evt = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
            Id      = 100
        } -MaxEvents 1 -ErrorAction Stop | Select-Object -First 1
        if ($evt) {
            $xml = [xml]$evt.ToXml()
            $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'MainPathBootTime' }
            if ($node -and $node.'#text') {
                $bootMs = [int]$node.'#text'
                Set-OmniResultMetric -Result $result -Name 'BootDurationMs' -Value $bootMs
            }
        }
    } catch {
        $log.Debug("Boot duration unavailable: $($_.Exception.Message)", 'Startup Performance')
    }

    # --- Posture ---------------------------------------------------------
    try {
        if ($null -ne $bootMs -and $bootMs -gt 60000) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Slow boot ({0:N0} s)" -f ($bootMs / 1000.0)) -Severity 'Warning' `
                -Component 'Performance/Startup' `
                -Detail "Last recorded boot took $bootMs ms." `
                -LikelyCause 'Too many startup programs, failing hardware, or driver delays.' `
                -Confidence 60 `
                -Recommendation 'Reduce autostart items and check for pending driver/firmware updates.')
        }
        if ($null -ne $startupCount -and $startupCount -gt 30) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("High number of startup items ({0})" -f $startupCount) -Severity 'Warning' `
                -Component 'Performance/Startup' `
                -Detail "$startupCount autostart entries were found." `
                -LikelyCause 'Many applications configured to launch at logon.' `
                -Confidence 55 `
                -Recommendation 'Disable non-essential startup items to speed up logon.')
        }
    } catch {
        $log.Debug("Startup posture evaluation failed: $($_.Exception.Message)", 'Startup Performance')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Startup metrics collected' -Severity 'Pass' -Component 'Performance/Startup' `
            -Detail 'Boot time, uptime, and startup items were collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
