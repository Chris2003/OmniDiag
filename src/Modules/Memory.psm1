<#
.SYNOPSIS
    OmniDiag diagnostic module: Memory.

.DESCRIPTION
    Reports physical memory usage from Win32_OperatingSystem and pagefile usage
    from Win32_PageFileUsage, and flags high memory pressure.

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
        Name          = 'Memory'
        Category      = 'Performance'
        Description   = 'Physical memory usage and pagefile utilization.'
        RequiresAdmin = $false
        Order         = 220
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

    $result = New-OmniResult -ModuleName 'Memory' -Category 'Performance' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Physical memory -------------------------------------------------
    $usedPct = $null
    try {
        $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
        if ($os) {
            $totalKb = [double]$os.TotalVisibleMemorySize
            $freeKb  = [double]$os.FreePhysicalMemory
            $totalGb = [math]::Round($totalKb / 1MB, 2)
            $freeGb  = [math]::Round($freeKb / 1MB, 2)
            Set-OmniResultMetric -Result $result -Name 'TotalRAMGB' -Value $totalGb
            Set-OmniResultMetric -Result $result -Name 'FreeRAMGB'  -Value $freeGb
            if ($totalKb -gt 0) {
                $usedPct = [math]::Round((($totalKb - $freeKb) / $totalKb) * 100, 1)
                Set-OmniResultMetric -Result $result -Name 'UsedPct' -Value $usedPct
            }
        }
    } catch {
        $log.Warn("Win32_OperatingSystem query failed: $($_.Exception.Message)", 'Memory')
    }

    # --- Pagefile --------------------------------------------------------
    try {
        $pf = Get-CimInstance -ClassName 'Win32_PageFileUsage' -ErrorAction Stop
        if ($pf) {
            $allocated = ($pf | Measure-Object -Property AllocatedBaseSize -Sum).Sum
            $currentUse = ($pf | Measure-Object -Property CurrentUsage -Sum).Sum
            Set-OmniResultMetric -Result $result -Name 'PageFileAllocatedMB' -Value ([int]$allocated)
            Set-OmniResultMetric -Result $result -Name 'PageFileUsedMB'      -Value ([int]$currentUse)
        } else {
            Set-OmniResultMetric -Result $result -Name 'PageFileUsedMB' -Value 0
        }
    } catch {
        $log.Debug("Win32_PageFileUsage query failed: $($_.Exception.Message)", 'Memory')
    }

    # --- Memory pressure -------------------------------------------------
    try {
        if ($null -ne $usedPct -and $usedPct -gt 90) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("High memory usage ({0}%)" -f $usedPct) -Severity 'Warning' `
                -Component 'Performance/Memory' `
                -Detail "Physical memory is $usedPct percent used." `
                -LikelyCause 'Too many applications open or a memory-heavy process.' `
                -Confidence 70 `
                -Recommendation 'Close unused applications or consider a memory upgrade.')
        }
    } catch {
        $log.Debug("Memory pressure evaluation failed: $($_.Exception.Message)", 'Memory')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Memory metrics collected' -Severity 'Pass' -Component 'Performance/Memory' `
            -Detail 'Physical memory and pagefile usage were collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
