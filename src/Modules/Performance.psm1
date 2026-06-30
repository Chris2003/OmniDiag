<#
.SYNOPSIS
    OmniDiag diagnostic module: Performance.

.DESCRIPTION
    Samples current CPU, memory, and disk pressure and identifies the top resource-
    consuming processes. GPU utilization is read best-effort from performance
    counters where available (Windows 10/11). A short counter sample is taken, so
    this module adds roughly one second to a scan.

    Per-run options (via $Context.Config):
        CpuWarnPct   int  CPU warning threshold (percent). Default 90.
        RamWarnPct   int  Memory warning threshold (percent). Default 90.
        TopN         int  Number of top processes to report. Default 5.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Performance'
        Category      = 'Performance'
        Description   = 'Current CPU, memory, and disk pressure with top resource consumers.'
        RequiresAdmin = $false
        Order         = 70
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Performance' -Category 'Performance' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $cfg = $Context.Config

    $cpuWarn = if ($cfg.ContainsKey('CpuWarnPct')) { [int]$cfg['CpuWarnPct'] } else { 90 }
    $ramWarn = if ($cfg.ContainsKey('RamWarnPct')) { [int]$cfg['RamWarnPct'] } else { 90 }
    $topN    = if ($cfg.ContainsKey('TopN'))       { [int]$cfg['TopN'] }       else { 5 }

    # --- CPU --------------------------------------------------------------
    $cpuPct = $null
    try {
        $sample = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
        $cpuPct = [int][math]::Round($sample.CounterSamples[0].CookedValue)
    } catch {
        try { $cpuPct = [int](Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average } catch { }
    }
    if ($null -ne $cpuPct) {
        Set-OmniResultMetric -Result $result -Name 'CpuUsagePct' -Value $cpuPct
        if ($cpuPct -ge $cpuWarn) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "High CPU usage ($cpuPct%)" -Severity 'Warning' `
                -Component 'Performance/CPU' -Detail "Processor time sampled at $cpuPct%." `
                -LikelyCause 'A process is consuming the CPU, or the system is under heavy load.' -Confidence 60 `
                -Recommendation 'Check the top CPU processes below; end or update the offending application.')
        }
    }

    # --- Memory -----------------------------------------------------------
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalKb = [double]$os.TotalVisibleMemorySize
        $freeKb  = [double]$os.FreePhysicalMemory
        $usedPct = [int][math]::Round((($totalKb - $freeKb) / $totalKb) * 100)
        Set-OmniResultMetric -Result $result -Name 'MemoryUsagePct' -Value $usedPct
        Set-OmniResultMetric -Result $result -Name 'MemoryFreeGB' -Value ([math]::Round($freeKb / 1MB, 1))
        if ($usedPct -ge $ramWarn) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "High memory usage ($usedPct%)" -Severity 'Warning' `
                -Component 'Performance/Memory' -Detail "$usedPct% of physical memory is in use." `
                -LikelyCause 'Memory pressure - too many apps or a leak; the system may be paging heavily.' -Confidence 60 `
                -Recommendation 'Close unneeded apps; check the top memory processes below; consider more RAM.')
        }
    } catch { $log.Warn("Memory query failed: $($_.Exception.Message)", 'Performance') }

    # --- Disk activity (best-effort) -------------------------------------
    try {
        $disk = Get-Counter '\PhysicalDisk(_Total)\% Disk Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
        $diskPct = [int][math]::Round($disk.CounterSamples[0].CookedValue)
        Set-OmniResultMetric -Result $result -Name 'DiskActivityPct' -Value $diskPct
    } catch { $log.Debug("Disk activity counter unavailable: $($_.Exception.Message)", 'Performance') }

    # --- GPU (best-effort; Win10/11) -------------------------------------
    try {
        $gpu = Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop
        $gpuPct = [int][math]::Round((($gpu.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum))
        Set-OmniResultMetric -Result $result -Name 'GpuUsagePct' -Value $gpuPct
    } catch { $log.Debug("GPU counter unavailable: $($_.Exception.Message)", 'Performance') }

    # --- Top processes ----------------------------------------------------
    try {
        $procs = Get-Process -ErrorAction Stop
        $topMem = $procs | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First $topN
        $memList = $topMem | ForEach-Object { "{0} ({1} MB)" -f $_.ProcessName, [math]::Round($_.WorkingSet64 / 1MB, 0) }
        Set-OmniResultMetric -Result $result -Name 'TopMemoryProcesses' -Value ($memList -join '; ')

        $topCpu = $procs | Where-Object { $_.CPU } | Sort-Object -Property CPU -Descending | Select-Object -First $topN
        $cpuList = $topCpu | ForEach-Object { "{0} ({1}s CPU)" -f $_.ProcessName, [math]::Round($_.CPU, 0) }
        Set-OmniResultMetric -Result $result -Name 'TopCpuProcesses' -Value ($cpuList -join '; ')

        # Surface a single high-memory consumer as an informational finding.
        $hog = $topMem | Select-Object -First 1
        if ($hog -and $hog.WorkingSet64 -gt 2GB) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "$($hog.ProcessName) is using $([math]::Round($hog.WorkingSet64/1GB,1)) GB of RAM" -Severity 'Information' `
                -Component 'Performance/Memory' -Detail 'A single process is holding a large amount of memory.' `
                -Recommendation 'If unexpected, restart the application; investigate for a memory leak.')
        }
    } catch { $log.Warn("Get-Process failed: $($_.Exception.Message)", 'Performance') }

    if (($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Performance is within normal limits' -Severity 'Pass' `
            -Component 'Performance' -Detail 'CPU and memory pressure are within expected thresholds.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
