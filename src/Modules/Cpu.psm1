<#
.SYNOPSIS
    OmniDiag diagnostic module: CPU.

.DESCRIPTION
    Collects processor inventory and current load via CIM/WMI, optionally samples
    the '\Processor(_Total)\% Processor Time' performance counter, and makes a
    best-effort thermal reading from MSAcpi_ThermalZoneTemperature.

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
        Name          = 'CPU'
        Category      = 'Performance'
        Description   = 'Processor inventory, current load, and best-effort temperature.'
        RequiresAdmin = $false
        Order         = 210
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

    $result = New-OmniResult -ModuleName 'CPU' -Category 'Performance' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Processor inventory ---------------------------------------------
    $loadPercent = $null
    try {
        $cpu = Get-CimInstance -ClassName 'Win32_Processor' -ErrorAction Stop | Select-Object -First 1
        if ($cpu) {
            Set-OmniResultMetric -Result $result -Name 'Name'         -Value ($cpu.Name.Trim())
            Set-OmniResultMetric -Result $result -Name 'Cores'        -Value $cpu.NumberOfCores
            Set-OmniResultMetric -Result $result -Name 'LogicalProcessors' -Value $cpu.NumberOfLogicalProcessors
            Set-OmniResultMetric -Result $result -Name 'MaxClockMHz'  -Value $cpu.MaxClockSpeed
            $loadPercent = [int]$cpu.LoadPercentage
            Set-OmniResultMetric -Result $result -Name 'LoadPercent' -Value $loadPercent
        }
    } catch {
        $log.Warn("Win32_Processor query failed: $($_.Exception.Message)", 'CPU')
    }

    # --- Sampled counter (best-effort) -----------------------------------
    $sampledLoad = $null
    try {
        $counter = Get-Counter -Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
        $sampledLoad = [math]::Round(($counter.CounterSamples | Select-Object -First 1).CookedValue, 1)
        Set-OmniResultMetric -Result $result -Name 'SampledLoadPercent' -Value $sampledLoad
    } catch {
        $log.Debug("Processor counter sample unavailable: $($_.Exception.Message)", 'CPU')
    }

    # --- Temperature (best-effort) ---------------------------------------
    try {
        $thermal = Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop |
            Select-Object -First 1
        if ($thermal -and $thermal.CurrentTemperature) {
            # Value is in tenths of a Kelvin.
            $tempC = [math]::Round((($thermal.CurrentTemperature / 10.0) - 273.15), 1)
            Set-OmniResultMetric -Result $result -Name 'TemperatureC' -Value $tempC
        }
    } catch {
        $log.Debug("Thermal zone temperature unavailable: $($_.Exception.Message)", 'CPU')
    }

    # --- Load posture ----------------------------------------------------
    try {
        $effectiveLoad = if ($null -ne $sampledLoad) { $sampledLoad } else { $loadPercent }
        if ($null -ne $effectiveLoad -and $effectiveLoad -gt 90) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Sustained high CPU load ({0}%)" -f $effectiveLoad) -Severity 'Warning' `
                -Component 'Performance/CPU' `
                -Detail "Processor utilization is at $effectiveLoad percent." `
                -LikelyCause 'A busy process or background task is saturating the CPU.' `
                -Confidence 65 `
                -Recommendation 'Review top CPU consumers in Task Manager or the Processes module.')
        }
    } catch {
        $log.Debug("CPU load evaluation failed: $($_.Exception.Message)", 'CPU')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'CPU metrics collected' -Severity 'Pass' -Component 'Performance/CPU' `
            -Detail 'Processor inventory and load were collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
