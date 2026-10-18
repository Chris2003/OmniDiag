<#
.SYNOPSIS
    Measures OmniDiag scan performance: full default scan wall time and CLI startup cost.

.DESCRIPTION
    Runs 'omnidiag scan --format json --output <tmp>' (the default selection: every scanner
    that needs no network access) -Runs times, each in a fresh PowerShell child process, and
    measures wall time. Also times 'omnidiag version' -StartupRuns times: the cost of
    starting PowerShell and importing the OmniDiag module, independent of the GUI.

    Prints per-run and median seconds, the median startup time, and the slowest modules
    (average durationMs from the JSON v1 reports), and writes performance.json and
    performance.md to -OutputDirectory (the markdown is also appended to
    $GITHUB_STEP_SUMMARY when set).

    Children get the environment OmniDiag.cmd sets up (PowerShell telemetry and update
    check off) and a throwaway OMNIDIAG_DATA folder.

    Roadmap gate (Phase 2): a full scan finishes in under 60 s on windows-latest, median of
    three runs, soft gate. Exit codes: 0 = measured (and within budget when -Enforce);
    1 = -Enforce and the median exceeds -BudgetSeconds; 2 = a run failed to produce a
    report or ended with a usage/internal error (exit code 10 or higher).

    Works on Windows PowerShell 5.1 and PowerShell 7+, on any OS (on Linux the scan is
    fast and has little to report, but the measurement path is the same).

.PARAMETER Runs
    Number of full scans. Default 3.

.PARAMETER StartupRuns
    Number of 'omnidiag version' runs for the startup measurement. Default 3.

.PARAMETER BudgetSeconds
    The median scan time budget. Default 60.

.PARAMETER Enforce
    Exit 1 when the median exceeds the budget. Without it the budget is reported only.

.PARAMETER Top
    How many of the slowest modules to list. Default 10.

.PARAMETER OutputDirectory
    Where the summary files go. Default: <repo>/test-results/performance.

.PARAMETER PowerShellPath
    The PowerShell executable that runs the CLI. Default: the one running this script.

.PARAMETER ScanArguments
    Extra arguments for 'omnidiag scan' (for example '--group','storage').

.EXAMPLE
    ./build/Measure-ScanPerformance.ps1

.EXAMPLE
    ./build/Measure-ScanPerformance.ps1 -Runs 5 -Enforce
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 50)] [int] $Runs = 3,
    [ValidateRange(1, 50)] [int] $StartupRuns = 3,
    [ValidateRange(1, 3600)] [double] $BudgetSeconds = 60,
    [switch] $Enforce,
    [ValidateRange(1, 100)] [int] $Top = 10,
    [string] $OutputDirectory,
    [string] $PowerShellPath,
    [string[]] $ScanArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$cli = Join-Path (Join-Path $repoRoot 'src') (Join-Path 'Cli' 'omnidiag.ps1')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot (Join-Path 'test-results' 'performance') }
if (-not $PowerShellPath) { $PowerShellPath = (Get-Process -Id $PID).Path }
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$work = Join-Path ([IO.Path]::GetTempPath()) ('omnidiag-perf-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force

function ConvertTo-ArgumentString {
    param([string[]] $Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ }
    }) -join ' '
}

function Invoke-TimedChild {
    # Runs PowerShell with the arguments; returns exit code, wall seconds, and stderr.
    param([string[]] $Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellPath
    $psi.Arguments = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $repoRoot
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $sw.Stop()
    [pscustomobject]@{
        ExitCode = $p.ExitCode
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        Stdout   = $outTask.Result
        Stderr   = $errTask.Result
    }
}

function Get-Median {
    param([double[]] $Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return 0 }
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$mid] }
    ($sorted[$mid - 1] + $sorted[$mid]) / 2
}

$envNames = 'OMNIDIAG_DATA', 'POWERSHELL_TELEMETRY_OPTOUT', 'POWERSHELL_UPDATECHECK', 'POWERSHELL_CLI_TELEMETRY_OPTOUT'
$envBackup = @{}
foreach ($n in $envNames) { $envBackup[$n] = [Environment]::GetEnvironmentVariable($n) }
$common = @('-NoProfile', '-NonInteractive')
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $common += @('-ExecutionPolicy', 'Bypass') }

$scanRuns = [System.Collections.Generic.List[object]]::new()
$startup = [System.Collections.Generic.List[double]]::new()
$moduleTimes = @{}
$errors = [System.Collections.Generic.List[string]]::new()

try {
    $env:OMNIDIAG_DATA = Join-Path $work 'OmniDiagData'
    $env:POWERSHELL_TELEMETRY_OPTOUT = '1'
    $env:POWERSHELL_UPDATECHECK = 'Off'
    $env:POWERSHELL_CLI_TELEMETRY_OPTOUT = '1'

    # Startup: PowerShell start + module import + router, no scanning.
    for ($i = 1; $i -le $StartupRuns; $i++) {
        $r = Invoke-TimedChild -Arguments ($common + @('-File', $cli, 'version'))
        if ($r.ExitCode -ne 0) { $errors.Add("version run $i exited $($r.ExitCode): $($r.Stderr.Trim())") }
        $startup.Add($r.Seconds)
        Write-Host ("startup run {0}: {1:N2} s" -f $i, $r.Seconds)
    }

    for ($i = 1; $i -le $Runs; $i++) {
        $json = Join-Path $work "scan-$i.json"
        $r = Invoke-TimedChild -Arguments ($common + @('-File', $cli, 'scan') + $ScanArguments + @('--format', 'json', '--output', $json, '--quiet'))
        $engineMs = $null
        $moduleCount = 0
        if ($r.ExitCode -ge 10) { $errors.Add("scan run $i exited $($r.ExitCode): $($r.Stderr.Trim())") }
        if (Test-Path -LiteralPath $json) {
            $doc = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
            $engineMs = [int64]$doc.scan.durationMs
            foreach ($m in @($doc.modules)) {
                $moduleCount++
                if (-not $moduleTimes.ContainsKey($m.id)) { $moduleTimes[$m.id] = [System.Collections.Generic.List[double]]::new() }
                $moduleTimes[$m.id].Add([double]$m.durationMs)
            }
        } else {
            $errors.Add("scan run $i wrote no JSON report (exit $($r.ExitCode)).")
        }
        $scanRuns.Add([pscustomobject]@{ Run = $i; Seconds = $r.Seconds; ExitCode = $r.ExitCode; EngineMs = $engineMs; Modules = $moduleCount })
        Write-Host ("scan run {0}: {1:N2} s (exit {2}, {3} modules, engine {4} ms)" -f $i, $r.Seconds, $r.ExitCode, $moduleCount, $engineMs)
    }
} finally {
    foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $envBackup[$n]) }
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop } catch { Write-Verbose "cleanup: $($_.Exception.Message)" }
}

# --- Summary -------------------------------------------------------------------------
$median = [math]::Round((Get-Median ([double[]]@($scanRuns | ForEach-Object { $_.Seconds }))), 2)
$startupMedian = [math]::Round((Get-Median ([double[]]$startup.ToArray())), 2)
$withinBudget = $median -le $BudgetSeconds
$slowest = @($moduleTimes.GetEnumerator() | ForEach-Object {
        $avg = ($_.Value | Measure-Object -Average).Average
        [pscustomobject]@{ Id = $_.Key; AverageMs = [math]::Round($avg, 0); MaxMs = ($_.Value | Measure-Object -Maximum).Maximum }
    } | Sort-Object AverageMs -Descending | Select-Object -First $Top)

$summary = [ordered]@{
    measuredAt           = (Get-Date).ToUniversalTime().ToString('o')
    os                   = [Environment]::OSVersion.VersionString
    powershell           = $PSVersionTable.PSVersion.ToString()
    runs                 = @($scanRuns)
    medianSeconds        = $median
    budgetSeconds        = $BudgetSeconds
    withinBudget         = $withinBudget
    enforced             = [bool]$Enforce
    startupSeconds       = @($startup)
    startupMedianSeconds = $startupMedian
    slowestModules       = $slowest
    errors               = @($errors)
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'performance.json') -Encoding UTF8

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('### Scan performance')
$md.Add('')
$gate = if ($withinBudget) { 'within' } else { 'OVER' }
$mode = if ($Enforce) { 'enforced' } else { 'soft gate' }
$md.Add(('Median full scan: **{0:N2} s** ({1} the {2} s budget, {3}). Median startup (`omnidiag version`): **{4:N2} s**.' -f $median, $gate, $BudgetSeconds, $mode, $startupMedian))
$md.Add('')
$md.Add('| Run | Wall (s) | Engine (s) | Modules | Exit |')
$md.Add('|---:|---:|---:|---:|---:|')
foreach ($r in $scanRuns) {
    $engine = if ($null -ne $r.EngineMs) { '{0:N2}' -f ($r.EngineMs / 1000) } else { '-' }
    $md.Add(('| {0} | {1:N2} | {2} | {3} | {4} |' -f $r.Run, $r.Seconds, $engine, $r.Modules, $r.ExitCode))
}
if ($slowest.Count -gt 0) {
    $md.Add('')
    $md.Add("Slowest modules (average over $Runs run(s)):")
    $md.Add('')
    $md.Add('| Module | Avg (ms) | Max (ms) |')
    $md.Add('|---|---:|---:|')
    foreach ($s in $slowest) { $md.Add("| $($s.Id) | $($s.AverageMs) | $($s.MaxMs) |") }
}
if ($errors.Count -gt 0) { $md.Add(''); $md.Add('**Errors**'); $md.Add(''); foreach ($e in $errors) { $md.Add("- $e") } }
$mdText = $md -join "`n"
Set-Content -LiteralPath (Join-Path $OutputDirectory 'performance.md') -Value $mdText -Encoding UTF8
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $mdText -Encoding UTF8 }
Write-Host ''
Write-Host $mdText

if ($errors.Count -gt 0) { exit 2 }
if ($Enforce -and -not $withinBudget) { exit 1 }
exit 0
