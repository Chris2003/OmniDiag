<#
.SYNOPSIS
    Runs PSScriptAnalyzer over OmniDiag with the repository settings.

.DESCRIPTION
    Analyzes src, OmniDiag.ps1, install.ps1, and build with PSScriptAnalyzerSettings.psd1
    (repo root), prints counts by severity and by rule plus every Error and Warning,
    and fails when any Error is found (or any Warning, with -FailOnWarning).

    PSAvoidUsingWriteHost results are dropped for the console presentation layers
    (src/Cli, src/UI, OmniDiag.ps1, install.ps1, build/), whose job is writing to the
    host; see the comment in PSScriptAnalyzerSettings.psd1.

    Files are analyzed one at a time and an analyzer crash is retried: PSScriptAnalyzer
    1.2x intermittently throws a NullReferenceException inside its parallel rule runner
    (Helper.GetExportedFunction, used by PSProvideCommentHelp). A file that still cannot
    be analyzed after the retries counts as an Error.

    Exit code: 0 when clean by the chosen policy, 1 otherwise.
    Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Path
    Files or folders to analyze (relative to the repo root). Defaults to
    src, OmniDiag.ps1, install.ps1, build.

.PARAMETER FailOnWarning
    Also fail when any Warning is reported.

.PARAMETER Retry
    Attempts per file when the analyzer itself throws. Default 3.

.EXAMPLE
    ./build/Invoke-Lint.ps1

.EXAMPLE
    ./build/Invoke-Lint.ps1 -FailOnWarning
#>
[CmdletBinding()]
param(
    [string[]] $Path = @('src', 'OmniDiag.ps1', 'install.ps1', 'build'),
    [switch] $FailOnWarning,
    [ValidateRange(1, 10)] [int] $Retry = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
$Path = @($Path | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() })

# Files where Write-Host is the intended output channel (repo-relative, '/' separators).
$writeHostAllowed = @('src/Cli/*', 'src/UI/*', 'OmniDiag.ps1', 'install.ps1', 'build/*')

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Error 'PSScriptAnalyzer is required: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 1
}
Import-Module PSScriptAnalyzer
Write-Host ("PSScriptAnalyzer {0} on PowerShell {1} ({2})" -f (Get-Module PSScriptAnalyzer).Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

function Get-RepoRelativePath {
    param([string] $FullPath)
    $root = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($FullPath)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { $full = $full.Substring($root.Length + 1) }
    return $full.Replace('\', '/')
}

# --- Collect files -------------------------------------------------------------------
$files = foreach ($p in $Path) {
    $full = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $repoRoot $p }
    if (-not (Test-Path -LiteralPath $full)) { Write-Warning "Skipping missing path: $p"; continue }
    if (Test-Path -LiteralPath $full -PathType Container) {
        Get-ChildItem -LiteralPath $full -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }
    } else {
        Get-Item -LiteralPath $full
    }
}
$files = @($files | Sort-Object FullName -Unique)
Write-Host ("Analyzing {0} file(s) with {1}" -f $files.Count, (Get-RepoRelativePath $settings))

# --- Analyze -------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
$crashed = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $rel = Get-RepoRelativePath $file.FullName
    $done = $false
    for ($attempt = 1; $attempt -le $Retry -and -not $done; $attempt++) {
        try {
            $diag = @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings -ErrorAction Stop)
            foreach ($d in $diag) {
                if ($d.RuleName -eq 'PSAvoidUsingWriteHost' -and @($writeHostAllowed | Where-Object { $rel -like $_ }).Count -gt 0) { continue }
                $results.Add([pscustomobject]@{
                        Severity = [string]$d.Severity
                        RuleName = $d.RuleName
                        File     = $rel
                        Line     = $d.Line
                        Message  = $d.Message
                    })
            }
            $done = $true
        } catch {
            if ($attempt -ge $Retry) {
                $crashed.Add($rel)
                Write-Warning "Analyzer failed on $rel after $Retry attempt(s): $($_.Exception.Message)"
            }
        }
    }
}
foreach ($c in $crashed) {
    $results.Add([pscustomobject]@{ Severity = 'Error'; RuleName = 'AnalyzerFailure'; File = $c; Line = 0; Message = 'PSScriptAnalyzer could not analyze this file.' })
}

# --- Report --------------------------------------------------------------------------
$count = @{}
foreach ($sev in 'Error', 'Warning', 'Information', 'ParseError') { $count[$sev] = @($results | Where-Object { $_.Severity -eq $sev }).Count }
$errorCount = $count['Error'] + $count['ParseError']

Write-Host ''
Write-Host 'By severity:'
Write-Host ('  Error       {0}' -f $errorCount)
Write-Host ('  Warning     {0}' -f $count['Warning'])
Write-Host ('  Information {0}' -f $count['Information'])

if ($results.Count -gt 0) {
    Write-Host ''
    Write-Host 'By rule:'
    $results | Group-Object Severity, RuleName | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ('  {0,5}  {1}' -f $_.Count, $_.Name)
    }
}

$shown = @($results | Where-Object { $_.Severity -in 'Error', 'ParseError', 'Warning' } | Sort-Object Severity, File, Line)
if ($shown.Count -gt 0) {
    Write-Host ''
    Write-Host 'Errors and warnings:'
    foreach ($r in $shown) { Write-Host ('  [{0}] {1}:{2}  {3}  {4}' -f $r.Severity, $r.File, $r.Line, $r.RuleName, $r.Message) }
}

if ($env:GITHUB_STEP_SUMMARY) {
    $md = @(
        '### PSScriptAnalyzer',
        '',
        '| Severity | Count |',
        '|---|---:|',
        "| Error | $errorCount |",
        "| Warning | $($count['Warning']) |",
        "| Information | $($count['Information']) |"
    )
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n") -Encoding UTF8
}

Write-Host ''
if ($errorCount -gt 0) {
    Write-Host "Lint FAILED: $errorCount error(s)."
    exit 1
}
if ($FailOnWarning -and $count['Warning'] -gt 0) {
    Write-Host "Lint FAILED: $($count['Warning']) warning(s) with -FailOnWarning."
    exit 1
}
Write-Host 'Lint passed (0 errors).'
exit 0
