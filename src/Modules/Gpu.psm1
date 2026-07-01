<#
.SYNOPSIS
    OmniDiag diagnostic module: GPU.

.DESCRIPTION
    Collects video controller inventory (name, VRAM, driver version/date, current
    resolution) from Win32_VideoController, flags stale drivers, and makes a
    best-effort GPU utilization reading from performance counters.

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
        Name          = 'GPU'
        Category      = 'Hardware'
        Description   = 'Graphics adapter inventory, driver age, and resolution.'
        RequiresAdmin = $false
        Order         = 260
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

    $result = New-OmniResult -ModuleName 'GPU' -Category 'Hardware' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Video controllers -----------------------------------------------
    try {
        $gpus = @(Get-CimInstance -ClassName 'Win32_VideoController' -ErrorAction Stop)
        if ($gpus.Count -gt 0) {
            Set-OmniResultMetric -Result $result -Name 'GPUCount' -Value $gpus.Count
            Set-OmniResultMetric -Result $result -Name 'Names' -Value (($gpus | ForEach-Object { $_.Name }) -join '; ')

            $vramList = @()
            $driverList = @()
            $resList = @()
            $staleDate = (Get-Date).AddYears(-2)

            foreach ($g in $gpus) {
                try {
                    # AdapterRAM can under-report for large VRAM but is best-effort.
                    if ($g.AdapterRAM -and $g.AdapterRAM -gt 0) {
                        $vramList += [math]::Round($g.AdapterRAM / 1GB, 1)
                    }
                    if ($g.DriverVersion) { $driverList += $g.DriverVersion }

                    $driverDate = $null
                    if ($g.DriverDate) {
                        try { $driverDate = [datetime]$g.DriverDate } catch { $driverDate = $null }
                    }
                    if ($driverDate) {
                        if ($driverDate -lt $staleDate) {
                            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                                -Title ("Old GPU driver for {0}" -f $g.Name) -Severity 'Warning' `
                                -Component 'Hardware/GPU' `
                                -Detail ("Driver dated {0:yyyy-MM-dd}." -f $driverDate) `
                                -LikelyCause 'The graphics driver has not been updated in over two years.' `
                                -Confidence 60 `
                                -Recommendation 'Update the graphics driver from the vendor or Windows Update.')
                        }
                    }
                    if ($g.CurrentHorizontalResolution -and $g.CurrentVerticalResolution) {
                        $resList += ("{0}x{1}" -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution)
                    }
                } catch {
                    $log.Debug("GPU entry parse failed: $($_.Exception.Message)", 'GPU')
                }
            }

            if ($vramList.Count -gt 0)  { Set-OmniResultMetric -Result $result -Name 'VRAMGB'         -Value ($vramList -join '; ') }
            if ($driverList.Count -gt 0){ Set-OmniResultMetric -Result $result -Name 'DriverVersions' -Value ($driverList -join '; ') }
            if ($resList.Count -gt 0)   { Set-OmniResultMetric -Result $result -Name 'Resolutions'    -Value ($resList -join '; ') }
        }
    } catch {
        $log.Warn("Win32_VideoController query failed: $($_.Exception.Message)", 'GPU')
    }

    # --- GPU utilization (best-effort) -----------------------------------
    try {
        $counters = Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop
        $total = ($counters.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
        Set-OmniResultMetric -Result $result -Name 'GPULoadPercent' -Value ([math]::Round($total, 1))
    } catch {
        $log.Debug("GPU utilization counter unavailable: $($_.Exception.Message)", 'GPU')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'GPU inventory collected' -Severity 'Pass' -Component 'Hardware/GPU' `
            -Detail 'Graphics adapter details were collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
