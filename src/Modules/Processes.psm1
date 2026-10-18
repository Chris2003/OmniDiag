<#
.SYNOPSIS
    OmniDiag diagnostic module: Processes.

.DESCRIPTION
    Enumerates running processes, reports the top CPU and memory consumers, the
    system-wide handle and thread totals with the top handle holders, and flags any
    processes that are not responding or hold an unusually large number of handles.

    Handle threshold: a single process holding more than HandleWarnCount handles
    (default 20,000) raises a Warning. Typical desktop processes hold hundreds to a
    few thousand handles, and busy ones (browsers, security agents, Explorer) routinely
    pass 10,000, so 10,000 was too noisy; a count in the tens of thousands that keeps growing is the
    classic sign of a handle leak, which eventually exhausts kernel memory (paged /
    nonpaged pool) or the per-process handle limit (16,777,216) and makes the process
    or the whole machine misbehave. The Idle (PID 0) and System (PID 4) pseudo-
    processes are listed but never warned on: their counts reflect the kernel, not a
    leaking application.

    Per-run options (via $Context.Config):
        HandleWarnCount  int  Per-process handle warning threshold. Default 20000.

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
        Name          = 'Processes'
        Id            = 'performance.processes'
        Group         = 'performance'
        NetworkAccess = 'None'
        Category      = 'Performance'
        Description   = 'Running process count and top CPU/memory consumers.'
        RequiresAdmin = $false
        Order         = 230
        Enabled       = $true
    }
}

function Add-OmniProcessHandleFinding {
    <#
    .SYNOPSIS
        Adds the handle/thread totals, the top 5 handle holders, and the handle findings.

    .DESCRIPTION
        Sums HandleCount and thread counts over the process snapshot (metrics
        TotalHandleCount, TotalThreadCount, TopHandles), then adds a Warning
        (performance.processes.handle-count-high) for every process above the
        HandleWarnCount threshold, Idle and System excepted, or an Information
        summary (performance.processes.handle-summary) otherwise.

    .PARAMETER Result
        The scanner result to add metrics and findings to.

    .PARAMETER Process
        Process objects from Get-Process.

    .PARAMETER Context
        The scan context (Config.HandleWarnCount).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Result,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Process,
        [Parameter(Mandatory)] [pscustomobject] $Context
    )

    $threshold = 20000
    if ($Context.Config -and $Context.Config.ContainsKey('HandleWarnCount')) { $threshold = [int]$Context.Config['HandleWarnCount'] }

    $totalHandles = [long]0
    $totalThreads = [long]0
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Process) {
        $handles = 0
        try { if ($null -ne $p.HandleCount) { $handles = [int]$p.HandleCount } } catch { $handles = 0 }
        $threads = 0
        try { if ($null -ne $p.Threads) { $threads = @($p.Threads).Count } } catch { $threads = 0 }
        $totalHandles += $handles
        $totalThreads += $threads
        $rows.Add([pscustomobject]@{ Name = [string]$p.ProcessName; Id = [int]$p.Id; Value = $handles })
    }

    Set-OmniResultMetric -Result $Result -Name 'TotalHandleCount' -Value $totalHandles
    Set-OmniResultMetric -Result $Result -Name 'TotalThreadCount' -Value $totalThreads
    $top = @($rows | Sort-Object -Property Value -Descending | Select-Object -First 5)
    Set-OmniResultMetric -Result $Result -Name 'TopHandles' -Value $top
    $topText = ($top | ForEach-Object { '{0} (PID {1}): {2}' -f $_.Name, $_.Id, $_.Value }) -join '; '

    # Idle (0) and System (4) are kernel pseudo-processes; never warn on them.
    $over = @($rows | Where-Object { $_.Id -ne 0 -and $_.Id -ne 4 -and $_.Value -gt $threshold } |
        Sort-Object -Property Value -Descending)
    Set-OmniResultMetric -Result $Result -Name 'HighHandleProcessCount' -Value $over.Count

    if ($over.Count -gt 0) {
        $list = ($over | ForEach-Object { '{0} (PID {1}): {2}' -f $_.Name, $_.Id, $_.Value }) -join '; '
        Add-OmniFinding -Result $Result -Finding (New-OmniFinding -Id 'performance.processes.handle-count-high' `
            -Title ('{0} process(es) hold more than {1} handles' -f $over.Count, $threshold) -Severity 'Warning' `
            -Component 'Performance/Handles' `
            -Detail ('Processes above the threshold: {0}. System-wide: {1} handles, {2} threads.' -f $list, $totalHandles, $totalThreads) `
            -LikelyCause 'A handle leak: the application opens handles (files, registry keys, events, threads) and never closes them. Left alone it exhausts kernel memory or the per-process handle limit.' `
            -Confidence 55 `
            -Recommendation 'Restart the application to release the handles; if the count climbs again, update it or report the leak to its vendor (Process Explorer shows which handle types grow).' `
            -Data @($over))
    } elseif ($rows.Count -gt 0) {
        Add-OmniFinding -Result $Result -Finding (New-OmniFinding -Id 'performance.processes.handle-summary' `
            -Title 'Handle and thread totals' -Severity 'Information' `
            -Component 'Performance/Handles' `
            -Detail ('{0} handles and {1} threads across {2} processes; no process holds more than {3} handles. Top handle holders: {4}.' -f $totalHandles, $totalThreads, $rows.Count, $threshold, $topText) `
            -Data $top)
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Processes' -Category 'Performance' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    try {
        $procs = @(Get-Process -ErrorAction Stop)
        Set-OmniResultMetric -Result $result -Name 'ProcessCount' -Value $procs.Count

        # --- Top 5 by CPU ------------------------------------------------
        try {
            $topCpu = $procs | Where-Object { $null -ne $_.CPU } |
                Sort-Object -Property CPU -Descending | Select-Object -First 5 |
                ForEach-Object {
                    [pscustomobject]@{ Name = $_.ProcessName; Value = [math]::Round([double]$_.CPU, 1) }
                }
            Set-OmniResultMetric -Result $result -Name 'TopCpu' -Value @($topCpu)
        } catch {
            $log.Debug("Top-CPU enumeration failed: $($_.Exception.Message)", 'Processes')
        }

        # --- Top 5 by working set ---------------------------------------
        try {
            $topMem = $procs | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 5 |
                ForEach-Object {
                    [pscustomobject]@{ Name = $_.ProcessName; Value = [math]::Round($_.WorkingSet64 / 1MB, 1) }
                }
            Set-OmniResultMetric -Result $result -Name 'TopMemory' -Value @($topMem)
        } catch {
            $log.Debug("Top-memory enumeration failed: $($_.Exception.Message)", 'Processes')
        }

        # --- Handles and threads ----------------------------------------
        try {
            Add-OmniProcessHandleFinding -Result $result -Process $procs -Context $Context
        } catch {
            $log.Debug("Handle/thread evaluation failed: $($_.Exception.Message)", 'Processes')
        }

        # --- Not-responding processes -----------------------------------
        try {
            $notResponding = @($procs | Where-Object {
                $_.MainWindowHandle -ne 0 -and $_.Responding -eq $false
            } | Select-Object -ExpandProperty ProcessName -Unique)
            Set-OmniResultMetric -Result $result -Name 'NotRespondingCount' -Value $notResponding.Count
            if ($notResponding.Count -gt 0) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'performance.processes.not-responding' `
                    -Title ("{0} process(es) not responding" -f $notResponding.Count) -Severity 'Warning' `
                    -Component 'Performance/Processes' `
                    -Detail ("Not responding: {0}" -f ($notResponding -join ', ')) `
                    -LikelyCause 'An application is hung or blocked waiting on a resource.' `
                    -Confidence 60 `
                    -Recommendation 'Investigate or restart the affected applications.')
            }
        } catch {
            $log.Debug("Not-responding evaluation failed: $($_.Exception.Message)", 'Processes')
        }

        # --- Informational summary of top consumers ---------------------
        try {
            $topCpuNames = @($procs | Where-Object { $null -ne $_.CPU } |
                Sort-Object -Property CPU -Descending | Select-Object -First 5 -ExpandProperty ProcessName)
            if ($topCpuNames.Count -gt 0) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title 'Top resource consumers' -Severity 'Information' `
                    -Component 'Performance/Processes' `
                    -Detail ("Top CPU processes: {0}" -f ($topCpuNames -join ', ')))
            }
        } catch {
            $log.Debug("Top-consumer summary failed: $($_.Exception.Message)", 'Processes')
        }
    } catch {
        $log.Warn("Get-Process failed: $($_.Exception.Message)", 'Processes')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Process inventory collected' -Severity 'Pass' -Component 'Performance/Processes' `
            -Detail 'Running processes were enumerated without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
