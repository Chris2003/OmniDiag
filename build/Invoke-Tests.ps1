<#
.SYNOPSIS
    Runs the OmniDiag Pester suite in isolation, with optional code coverage.

.DESCRIPTION
    The single entry point for tests, used by CI and recommended locally.

    * Isolation: OMNIDIAG_DATA is pointed at a fresh temporary folder for the run, so
      logs, sessions, and reports written by the code under test never land in the
      repository's OmniDiagData folder. The folder is removed afterwards (use
      -KeepData to inspect it) and the previous OMNIDIAG_DATA value is restored.
      Test files that manipulate OMNIDIAG_DATA themselves (Core.Portable tests the
      default, next-to-the-tool location and clears the variable) run last, so they
      can't switch isolation off for other files; an OmniDiagData folder that such a
      test creates in the repository during the run is removed afterwards (an
      OmniDiagData folder that existed before the run is left alone).
    * Tests run with strict mode off, as under a plain Invoke-Pester (this script's
      own Set-StrictMode would otherwise leak into every test scope).
    * Pester 5.5+ is driven through New-PesterConfiguration; the CI output format is
      chosen automatically (GitHub Actions / Azure Pipelines annotations when detected).
    * -Coverage measures src/Core, src/Repair, and src/Reporting, writes a JaCoCo XML
      report, and prints the overall and per-folder percentage. When running under
      GitHub Actions the table is also appended to the job summary.
    * -CoverageTarget (overall) and -CoverageTargets (per folder, e.g.
      @{ 'src/Core' = 80; 'src/Repair' = 80 }) are report-only unless -EnforceCoverage is
      given; then any missed target fails the run. CI enforces Core, Repair, and overall
      at 80% on the Windows pwsh 7 leg (Phase 4 gate).
    * With -Coverage a coverage-summary.json (overall, per folder, targets, verdicts) is
      written next to the JaCoCo report.

    Exit code: 0 when every test passed (skips are fine); 1 on any failed test, failed
    container (a test file that could not run), or an enforced coverage miss.

    Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Path
    Test files or folders to run. Defaults to <repo>/Tests.

.PARAMETER Coverage
    Enable code coverage for src/Core, src/Repair, src/Reporting.

.PARAMETER CoverageOutputPath
    Where to write the JaCoCo coverage XML. Defaults to <repo>/coverage.xml
    (git-ignored).

.PARAMETER CoverageTarget
    Target overall coverage percentage. Reported against; enforced only with
    -EnforceCoverage.

.PARAMETER CoverageTargets
    Per-folder targets: a hashtable { folder = percent } or, for 'pwsh -File', a string
    'src/Core=80,src/Repair=80'. Folders are the measured ones (src/Core, src/Repair,
    src/Reporting); the key 'Overall' sets the overall target (overrides -CoverageTarget).
    Reported against; enforced only with -EnforceCoverage.

.PARAMETER EnforceCoverage
    Fail (exit 1) when overall coverage is below -CoverageTarget or any folder is below
    its -CoverageTargets entry.

.PARAMETER TestResultPath
    Optional NUnit XML test-result file (for CI test reporters).

.PARAMETER Verbosity
    Pester output verbosity: None, Normal, Detailed, Diagnostic. Default Normal.

.PARAMETER KeepData
    Keep the temporary OMNIDIAG_DATA folder instead of deleting it.

.EXAMPLE
    ./build/Invoke-Tests.ps1

.EXAMPLE
    ./build/Invoke-Tests.ps1 -Coverage -CoverageOutputPath ./out/coverage.xml -CoverageTarget 80

.EXAMPLE
    ./build/Invoke-Tests.ps1 -Coverage -CoverageTarget 80 -CoverageTargets @{ 'src/Core' = 80; 'src/Repair' = 80 } -EnforceCoverage

.EXAMPLE
    ./build/Invoke-Tests.ps1 -Path ./Tests/NoNetwork.Tests.ps1 -Verbosity Detailed
#>
[CmdletBinding()]
param(
    [string[]] $Path,
    [switch] $Coverage,
    [string] $CoverageOutputPath,
    [ValidateRange(0, 100)] [double] $CoverageTarget = 0,
    [object] $CoverageTargets,
    [switch] $EnforceCoverage,
    [string] $TestResultPath,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')] [string] $Verbosity = 'Normal',
    [switch] $KeepData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $Path) { $Path = @(Join-Path $repoRoot 'Tests') }
# 'pwsh -File' passes "a,b" as one string; accept comma-separated lists too.
$Path = @($Path | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() })

# Expand to test files, moving those that touch OMNIDIAG_DATA to the end (see .DESCRIPTION).
$testFiles = foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Error "Test path not found: $p"; exit 1 }
    if (Test-Path -LiteralPath $p -PathType Container) {
        Get-ChildItem -LiteralPath $p -Recurse -File -Filter '*.Tests.ps1' | Sort-Object FullName
    } else {
        Get-Item -LiteralPath $p
    }
}
$touchesData = { (Get-Content -LiteralPath $_.FullName -Raw) -match 'OMNIDIAG_DATA' }
$testFiles = @($testFiles | Where-Object { -not (& $touchesData) }) + @($testFiles | Where-Object $touchesData)
$repoData = Join-Path $repoRoot 'OmniDiagData'
$repoDataExisted = Test-Path -LiteralPath $repoData
if ($EnforceCoverage -and -not $Coverage) { $Coverage = [switch]$true }

# --- Coverage targets: folder -> percent, validated before anything runs ------------
$coverageFolders = @('src/Core', 'src/Repair', 'src/Reporting')
$folderTargets = [ordered]@{}
if ($null -ne $CoverageTargets) {
    $pairs = [System.Collections.Generic.List[object]]::new()
    if ($CoverageTargets -is [System.Collections.IDictionary]) {
        foreach ($k in $CoverageTargets.Keys) { $pairs.Add(@([string]$k, [string]$CoverageTargets[$k])) }
    } else {
        foreach ($item in @($CoverageTargets)) {
            foreach ($part in ([string]$item -split ',')) {
                if (-not $part.Trim()) { continue }
                $kv = $part -split '=', 2
                if ($kv.Count -ne 2) { Write-Error "Invalid -CoverageTargets entry '$part' (expected folder=percent)."; exit 1 }
                $pairs.Add(@($kv[0].Trim(), $kv[1].Trim()))
            }
        }
    }
    foreach ($pair in $pairs) {
        $key = ([string]$pair[0]).Replace('\', '/').Trim().TrimEnd('/')
        $value = 0.0
        $ok = [double]::TryParse([string]$pair[1], [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)
        if (-not $ok -or $value -lt 0 -or $value -gt 100) {
            Write-Error "Invalid coverage target for '$key': '$($pair[1])' (expected 0-100)."; exit 1
        }
        if ($key -eq 'Overall') { $CoverageTarget = $value; continue }
        $match = @($coverageFolders | Where-Object { $_ -eq $key })
        if ($match.Count -eq 0) { Write-Error "Unknown coverage folder '$key'. Measured: $($coverageFolders -join ', '), or Overall."; exit 1 }
        $folderTargets[$match[0]] = $value
    }
    if ($folderTargets.Count -gt 0 -and -not $Coverage) { $Coverage = [switch]$true }
}
if (-not $CoverageOutputPath) { $CoverageOutputPath = Join-Path $repoRoot 'coverage.xml' }

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.5.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Error 'Pester 5.5.0 or later is required: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser'
    exit 1
}
Import-Module $pester.Path -Force
Write-Host ("Pester {0} on PowerShell {1} ({2})" -f $pester.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

# --- Isolation: a throwaway data root for this run -------------------------------
$previousData = $env:OMNIDIAG_DATA
$dataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
$env:OMNIDIAG_DATA = $dataRoot
Write-Host "OMNIDIAG_DATA = $dataRoot"

$failed = $false
try {
    $config = New-PesterConfiguration
    $config.Run.Path = @($testFiles | ForEach-Object { $_.FullName })
    $config.Run.PassThru = $true
    $config.Output.Verbosity = $Verbosity
    try { $config.Output.CIFormat = 'Auto' } catch { Write-Verbose 'Output.CIFormat not supported by this Pester version.' }
    $config.Should.ErrorAction = 'Stop'

    if ($TestResultPath) {
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputFormat = 'NUnitXml'
        $config.TestResult.OutputPath = $TestResultPath
    }

    if ($Coverage) {
        $outDir = Split-Path -Path $CoverageOutputPath -Parent
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $config.CodeCoverage.Enabled = $true
        $config.CodeCoverage.Path = @($coverageFolders | ForEach-Object { Join-Path $repoRoot $_ })
        $config.CodeCoverage.OutputFormat = 'JaCoCo'
        $config.CodeCoverage.OutputPath = $CoverageOutputPath
        # Profiler-based coverage is much faster than breakpoints (Pester 5.5+).
        try { $config.CodeCoverage.UseBreakpoints = $false } catch { Write-Verbose 'CodeCoverage.UseBreakpoints not supported.' }
    }

    $result = & { Set-StrictMode -Off; Invoke-Pester -Configuration $config }
    if ($null -eq $result) { throw 'Invoke-Pester returned no result (see the error above).' }

    Write-Host ''
    Write-Host ("Tests: {0} passed, {1} failed, {2} skipped, {3} not run (total {4}); failed containers: {5}" -f `
            $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount, $result.TotalCount,
            @($result.FailedContainers).Count)
    if ($result.FailedCount -gt 0 -or @($result.FailedContainers).Count -gt 0 -or $result.Result -eq 'Failed') { $failed = $true }

    if ($Coverage -and -not $result.CodeCoverage) {
        Write-Host 'Code coverage was requested but Pester returned no coverage data.'
        if ($EnforceCoverage) { $failed = $true }
    }
    if ($Coverage -and $result.CodeCoverage) {
        $cc = $result.CodeCoverage
        $norm = { param([string] $p) $p.Replace('\', '/').TrimEnd('/') }
        $rows = foreach ($folder in $coverageFolders) {
            $prefix = (& $norm (Join-Path $repoRoot $folder)) + '/'
            $inFolder = { (& $norm "$($_.File)").StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) }
            $hit = @($cc.CommandsExecuted | Where-Object $inFolder).Count
            $miss = @($cc.CommandsMissed | Where-Object $inFolder).Count
            $total = $hit + $miss
            $percent = 0
            if ($total -gt 0) { $percent = [math]::Round(100.0 * $hit / $total, 1) }
            $target = $null
            if ($folderTargets.Contains($folder)) { $target = [double]$folderTargets[$folder] }
            [pscustomobject]@{
                Folder   = $folder
                Covered  = $hit
                Total    = $total
                Percent  = $percent
                Target   = $target
                Met      = ($null -eq $target -or $percent -ge $target)
            }
        }
        $overallTotal = $cc.CommandsAnalyzedCount
        $overall = if ($overallTotal -gt 0) { [math]::Round(100.0 * $cc.CommandsExecutedCount / $overallTotal, 1) } else { 0 }

        $overallMet = ($CoverageTarget -le 0 -or $overall -ge $CoverageTarget)
        $mode = 'report only'
        if ($EnforceCoverage) { $mode = 'enforced' }
        $fmtTarget = { param($t) if ($null -eq $t -or $t -le 0) { '-' } else { '{0}%' -f $t } }
        $fmtVerdict = { param($t, $met) if ($null -eq $t -or $t -le 0) { '' } elseif ($met) { 'met' } else { 'NOT met' } }

        Write-Host ''
        Write-Host "Code coverage (commands executed / analyzed); targets $($mode):"
        foreach ($row in $rows) {
            Write-Host ('  {0,-14} {1,6}%  ({2}/{3})  target {4,-5} {5}' -f $row.Folder, $row.Percent, $row.Covered, $row.Total,
                (& $fmtTarget $row.Target), (& $fmtVerdict $row.Target $row.Met))
        }
        Write-Host ('  {0,-14} {1,6}%  ({2}/{3})  target {4,-5} {5}' -f 'Overall', $overall, $cc.CommandsExecutedCount, $overallTotal,
            (& $fmtTarget $CoverageTarget), (& $fmtVerdict $CoverageTarget $overallMet))
        Write-Host "  JaCoCo report: $CoverageOutputPath"

        $misses = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $rows) { if (-not $row.Met) { $misses.Add(('{0} {1}% < {2}%' -f $row.Folder, $row.Percent, $row.Target)) } }
        if (-not $overallMet) { $misses.Add(('Overall {0}% < {1}%' -f $overall, $CoverageTarget)) }
        if ($misses.Count -gt 0) {
            Write-Host ("  Coverage targets missed ({0}): {1}" -f $mode, ($misses -join '; '))
            if ($EnforceCoverage) { $failed = $true }
        } elseif ($CoverageTarget -gt 0 -or $folderTargets.Count -gt 0) {
            Write-Host "  All coverage targets met ($mode)."
        }

        # Machine-readable summary next to the JaCoCo report (uploaded with the CI artifact).
        $overallTargetValue = $null
        if ($CoverageTarget -gt 0) { $overallTargetValue = $CoverageTarget }
        $summary = [ordered]@{
            powershell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
            enforced   = [bool]$EnforceCoverage
            overall    = [ordered]@{ percent = $overall; covered = $cc.CommandsExecutedCount; total = $overallTotal; target = $overallTargetValue; met = $overallMet }
            folders    = @($rows | ForEach-Object { [ordered]@{ folder = $_.Folder; percent = $_.Percent; covered = $_.Covered; total = $_.Total; target = $_.Target; met = $_.Met } })
            missed     = @($misses)
        }
        $summaryDir = Split-Path -Path $CoverageOutputPath -Parent
        if (-not $summaryDir) { $summaryDir = '.' }
        $summaryPath = Join-Path $summaryDir 'coverage-summary.json'
        try {
            [System.IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($summaryPath),($summary | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        } catch {
            Write-Host "  Could not write $($summaryPath): $($_.Exception.Message)"
        }

        if ($env:GITHUB_STEP_SUMMARY) {
            $md = [System.Collections.Generic.List[string]]::new()
            $md.Add("### Code coverage ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))")
            $md.Add('')
            $md.Add('| Folder | Coverage | Commands | Target | Result |')
            $md.Add('|---|---:|---:|---:|---|')
            foreach ($row in $rows) {
                $md.Add(('| {0} | {1}% | {2}/{3} | {4} | {5} |' -f $row.Folder, $row.Percent, $row.Covered, $row.Total,
                        (& $fmtTarget $row.Target), (& $fmtVerdict $row.Target $row.Met)))
            }
            $md.Add(('| **Overall** | **{0}%** | {1}/{2} | {3} | {4} |' -f $overall, $cc.CommandsExecutedCount, $overallTotal,
                    (& $fmtTarget $CoverageTarget), (& $fmtVerdict $CoverageTarget $overallMet)))
            $md.Add('')
            $note = "Targets: $mode."
            if ($misses.Count -gt 0) { $note += ' Missed: ' + ($misses -join '; ') + '.' }
            $md.Add($note)
            $md.Add('')
            try {
                Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n") -Encoding UTF8
            } catch {
                Write-Host "  Could not write the job summary: $($_.Exception.Message)"
            }
        }
    }
} catch {
    Write-Host "Test run aborted: $($_.Exception.Message)"
    $failed = $true
} finally {
    $env:OMNIDIAG_DATA = $previousData
    if ($KeepData) {
        Write-Host "Kept test data folder: $dataRoot"
    } else {
        Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $repoDataExisted -and (Test-Path -LiteralPath $repoData)) {
        Remove-Item -LiteralPath $repoData -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'Removed the OmniDiagData folder a test created in the repository during the run.'
    }
}

if ($failed) { exit 1 }
exit 0
