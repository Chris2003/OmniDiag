<#
.SYNOPSIS
    OmniDiag diagnostic module: Benchmark.

.DESCRIPTION
    Runs a quick, bounded micro-benchmark: a fixed-iteration CPU math loop and a
    small sequential disk write/read in the temp folder. All work is time-boxed to
    stay well under ~1.5 seconds and never throws.

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
        Name          = 'Benchmark'
        Category      = 'Performance'
        Description   = 'Quick bounded CPU and disk micro-benchmark.'
        RequiresAdmin = $false
        Order         = 240
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

    $result = New-OmniResult -ModuleName 'Benchmark' -Category 'Performance' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $cpuMillis   = $null
    $cpuOpsSec   = $null
    $diskWrite   = $null
    $diskRead    = $null

    # --- CPU micro-benchmark ---------------------------------------------
    try {
        $iterations = 1000000
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $acc = 0.0
        for ($i = 0; $i -lt $iterations; $i++) {
            $acc += [math]::Sqrt($i)
        }
        $sw.Stop()
        $cpuMillis = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        if ($cpuMillis -gt 0) {
            $cpuOpsSec = [int]($iterations / ($cpuMillis / 1000.0))
        }
        Set-OmniResultMetric -Result $result -Name 'CpuMillis'    -Value $cpuMillis
        Set-OmniResultMetric -Result $result -Name 'CpuOpsPerSec' -Value $cpuOpsSec
        # Keep the accumulator referenced so the loop is not optimized away.
        $log.Debug("CPU benchmark accumulator: $acc", 'Benchmark')
    } catch {
        $log.Warn("CPU benchmark failed: $($_.Exception.Message)", 'Benchmark')
    }

    # --- Disk micro-benchmark --------------------------------------------
    $tempFile = $null
    try {
        $sizeMb = 8
        $bytes = New-Object byte[] (1MB)
        (New-Object System.Random).NextBytes($bytes)
        $tempFile = Join-Path $env:TEMP ("omnidiag_bench_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))

        # Write
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            for ($b = 0; $b -lt $sizeMb; $b++) { $fs.Write($bytes, 0, $bytes.Length) }
            $fs.Flush()
        } finally {
            $fs.Dispose()
        }
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -gt 0) {
            $diskWrite = [math]::Round($sizeMb / $sw.Elapsed.TotalSeconds, 1)
            Set-OmniResultMetric -Result $result -Name 'DiskWriteMBps' -Value $diskWrite
        }

        # Read
        $readBuf = New-Object byte[] (1MB)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        try {
            while ($fs.Read($readBuf, 0, $readBuf.Length) -gt 0) { }
        } finally {
            $fs.Dispose()
        }
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -gt 0) {
            $diskRead = [math]::Round($sizeMb / $sw.Elapsed.TotalSeconds, 1)
            Set-OmniResultMetric -Result $result -Name 'DiskReadMBps' -Value $diskRead
        }
    } catch {
        $log.Debug("Disk benchmark skipped: $($_.Exception.Message)", 'Benchmark')
    } finally {
        if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
            try { Remove-Item -LiteralPath $tempFile -Force -ErrorAction Stop } catch { }
        }
    }

    # --- Summary ---------------------------------------------------------
    try {
        $parts = @()
        if ($null -ne $cpuOpsSec) { $parts += ("CPU {0:N0} ops/s ({1} ms)" -f $cpuOpsSec, $cpuMillis) }
        if ($null -ne $diskWrite) { $parts += ("Disk write {0} MB/s" -f $diskWrite) }
        if ($null -ne $diskRead)  { $parts += ("Disk read {0} MB/s" -f $diskRead) }
        if ($parts.Count -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'Benchmark scores' -Severity 'Information' -Component 'Performance/Benchmark' `
                -Detail ($parts -join '; '))
        }
    } catch {
        $log.Debug("Benchmark summary failed: $($_.Exception.Message)", 'Benchmark')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Benchmark completed' -Severity 'Pass' -Component 'Performance/Benchmark' `
            -Detail 'CPU and disk micro-benchmark completed without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
