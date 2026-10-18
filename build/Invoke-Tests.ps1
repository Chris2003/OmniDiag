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
    * -CoverageTarget is report-only unless -EnforceCoverage is given (Phase 1 policy:
      coverage is reported, not gated).

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

.PARAMETER EnforceCoverage
    Fail (exit 1) when overall coverage is below -CoverageTarget.

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
    ./build/Invoke-Tests.ps1 -Path ./Tests/NoNetwork.Tests.ps1 -Verbosity Detailed
#>
[CmdletBinding()]
param(
    [string[]] $Path,
    [switch] $Coverage,
    [string] $CoverageOutputPath,
    [ValidateRange(0, 100)] [double] $CoverageTarget = 0,
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

$coverageFolders = @('src/Core', 'src/Repair', 'src/Reporting')
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

    if ($Coverage -and $result.CodeCoverage) {
        $cc = $result.CodeCoverage
        $norm = { param([string] $p) $p.Replace('\', '/').TrimEnd('/') }
        $rows = foreach ($folder in $coverageFolders) {
            $prefix = (& $norm (Join-Path $repoRoot $folder)) + '/'
            $inFolder = { (& $norm "$($_.File)").StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) }
            $hit = @($cc.CommandsExecuted | Where-Object $inFolder).Count
            $miss = @($cc.CommandsMissed | Where-Object $inFolder).Count
            $total = $hit + $miss
            [pscustomobject]@{
                Folder   = $folder
                Covered  = $hit
                Total    = $total
                Percent  = if ($total -gt 0) { [math]::Round(100.0 * $hit / $total, 1) } else { 0 }
            }
        }
        $overallTotal = $cc.CommandsAnalyzedCount
        $overall = if ($overallTotal -gt 0) { [math]::Round(100.0 * $cc.CommandsExecutedCount / $overallTotal, 1) } else { 0 }

        Write-Host ''
        Write-Host 'Code coverage (commands executed / analyzed):'
        foreach ($row in $rows) { Write-Host ('  {0,-14} {1,6}%  ({2}/{3})' -f $row.Folder, $row.Percent, $row.Covered, $row.Total) }
        Write-Host ('  {0,-14} {1,6}%  ({2}/{3})' -f 'Overall', $overall, $cc.CommandsExecutedCount, $overallTotal)
        Write-Host "  JaCoCo report: $CoverageOutputPath"
        if ($CoverageTarget -gt 0) {
            $verdict = if ($overall -ge $CoverageTarget) { 'met' } else { 'NOT met' }
            $mode = if ($EnforceCoverage) { 'enforced' } else { 'report only' }
            Write-Host ("  Target {0}% {1} ({2})." -f $CoverageTarget, $verdict, $mode)
            if ($EnforceCoverage -and $overall -lt $CoverageTarget) { $failed = $true }
        }

        if ($env:GITHUB_STEP_SUMMARY) {
            $md = [System.Collections.Generic.List[string]]::new()
            $md.Add("### Code coverage ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))")
            $md.Add('')
            $md.Add('| Folder | Coverage | Commands |')
            $md.Add('|---|---:|---:|')
            foreach ($row in $rows) { $md.Add(('| {0} | {1}% | {2}/{3} |' -f $row.Folder, $row.Percent, $row.Covered, $row.Total)) }
            $md.Add(('| **Overall** | **{0}%** | {1}/{2} |' -f $overall, $cc.CommandsExecutedCount, $overallTotal))
            if ($CoverageTarget -gt 0) { $md.Add(''); $md.Add("Target: $CoverageTarget% ($(if ($EnforceCoverage) { 'enforced' } else { 'report only' }))") }
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n") -Encoding UTF8
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
