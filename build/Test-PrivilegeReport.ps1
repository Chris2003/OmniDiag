<#
.SYNOPSIS
    Validates OmniDiag reports for a privilege level: standard user (non-admin) or elevated.

.DESCRIPTION
    Phase 4 check behind the CI 'standard-user' job and the elevated windows-latest pwsh
    leg. It reads report files, never runs OmniDiag itself.

    -Expect Standard reads results.json from build/Invoke-AsStandardUser.ps1 and checks:
      * every step ran non-elevated: the account's SID, Medium/Low integrity, no
        BUILTIN\Administrators in the token (from the wrapper's whoami /groups record);
      * the Pester step (-TestStep) exited 0;
      * 'report' and 'scan' exit codes are in the documented set and are scan outcomes
        (0 none, 1 warnings, 2 critical, 3 partial); 4/5/10/20 fail;
      * the report JSON and the 'scan --format json' stdout validate against
        schemas/omnidiag-report.v1.json (Test-Json, PowerShell 7; reported as skipped on
        Windows PowerShell 5.1), and the HTML report exists and is not empty;
      * host.isAdmin is false;
      * elevation-dependent data is a structured skip, not an error: every module with
        requiresElevation true is Skipped with skippedReason RequiresElevation and no
        error; the per-finding elevation notices ('*-requires-elevation' ids, e.g.
        system.system.tpm-requires-elevation) are Information findings, and at least one
        is present; no module Failed with an access-denied style error.
    -Expect Elevated checks one report directory (-ReportDirectory, -ExitCode): exit code,
      schema, HTML, host.isAdmin true, no module skipped for RequiresElevation, and no
      '*-requires-elevation' finding: the elevated report has the extra sections.
    -CompareWithReportDirectory (with -Expect Standard) adds the elevated report's checks
      and a comparison: the same scanners in both, more elevation notices in the standard
      report, and at least as many modules run when elevated.

    Writes privilege-check.json and privilege-check.md to -OutputDirectory (the markdown is
    appended to $GITHUB_STEP_SUMMARY when set). Exit code 0 = every check passed, 1 = a
    check failed, 2 = inputs missing or unreadable.

    Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Expect
    Standard or Elevated.

.PARAMETER RunResultPath
    -Expect Standard: results.json written by build/Invoke-AsStandardUser.ps1.

.PARAMETER TestStep
    Name of the Pester step in results.json. Default 'pester'; '' to skip.

.PARAMETER ReportStep
    Name of the 'report' step. Default 'report'.

.PARAMETER ScanStep
    Name of the 'scan --format json' step. Default 'scan'; '' to skip.

.PARAMETER ReportDirectory
    -Expect Elevated: the folder 'omnidiag report --output' wrote to.

.PARAMETER ExitCode
    -Expect Elevated: the report command's exit code.

.PARAMETER CompareWithReportDirectory
    -Expect Standard: an elevated report folder from the same machine to compare with.

.PARAMETER CompareExitCode
    The exit code of the comparison report command.

.PARAMETER SchemaPath
    Default: <repo>/schemas/omnidiag-report.v1.json.

.PARAMETER OutputDirectory
    Default: <repo>/test-results/privilege-check.

.EXAMPLE
    ./build/Test-PrivilegeReport.ps1 -Expect Elevated -ReportDirectory test-results/elevated-report -ExitCode 1

.EXAMPLE
    ./build/Test-PrivilegeReport.ps1 -Expect Standard -RunResultPath test-results/standard-user/results.json -CompareWithReportDirectory test-results/elevated-report -CompareExitCode 1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Standard', 'Elevated')] [string] $Expect,
    [string] $RunResultPath,
    [string] $TestStep = 'pester',
    [string] $ReportStep = 'report',
    [string] $ScanStep = 'scan',
    [string] $ReportDirectory,
    [int] $ExitCode = -1,
    [string] $CompareWithReportDirectory,
    [int] $CompareExitCode = -1,
    [string] $SchemaPath,
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $SchemaPath) { $SchemaPath = Join-Path $repoRoot (Join-Path 'schemas' 'omnidiag-report.v1.json') }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot (Join-Path 'test-results' 'privilege-check') }
$utf8 = [System.Text.UTF8Encoding]::new($false)

# Documented exit codes (docs/CLI.md); a default scan/report may end with 0-3 only.
$documented = @(0, 1, 2, 3, 4, 5, 10, 11, 12, 20)
$scanOutcomes = @(0, 1, 2, 3)
$elevationIdPattern = '(?i)[.-]requires?-elevation$'
$deniedPattern = '(?i)access (is )?denied|unauthori[sz]ed|privilege|requires? (elevation|administrator)|0x80070005'

$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string] $Area, [string] $Name, [bool] $Passed, [string] $Detail = '', [switch] $Skipped)
    $state = if ($Skipped) { 'Skipped' } elseif ($Passed) { 'Pass' } else { 'FAIL' }
    $checks.Add([pscustomobject]@{ Area = $Area; Check = $Name; Result = $state; Detail = $Detail })
}

$schemaText = $null
if (Test-Path -LiteralPath $SchemaPath) { $schemaText = [System.IO.File]::ReadAllText($SchemaPath) }
$canValidate = [bool](Get-Command Test-Json -ErrorAction SilentlyContinue) -and $schemaText

function Test-ExitCodeValue {
    param([string] $Area, [string] $Label, [int] $Code)
    if ($Code -lt 0) { Add-Check $Area "$Label exit code" $true 'not recorded' -Skipped; return }
    $ok = $Code -in $scanOutcomes
    $detail = "exit code $Code"
    if (-not $ok -and $Code -in $documented) { $detail += ' (documented, but not a scan outcome)' }
    elseif (-not $ok) { $detail += ' (NOT a documented exit code)' }
    Add-Check $Area "$Label exit code in the documented scan outcomes (0-3)" $ok $detail
}

function Test-ReportText {
    # Parses and schema-validates one JSON report; returns the parsed object or $null.
    param([string] $Area, [string] $Label, [string] $Text)
    $doc = $null
    try { $doc = $Text | ConvertFrom-Json } catch { Add-Check $Area "$Label is JSON" $false $_.Exception.Message; return $null }
    Add-Check $Area "$Label is JSON" $true ("schemaVersion {0}, {1} modules" -f $doc.schemaVersion, @($doc.modules).Count)
    if ($canValidate) {
        $errs = $null
        $valid = $false
        try { $valid = Test-Json -Json $Text -Schema $schemaText -ErrorAction SilentlyContinue -ErrorVariable errs } catch { $errs = @($_) }
        $detail = 'valid'
        if (-not $valid) { $detail = (@($errs) | Select-Object -First 3 | ForEach-Object { "$_" }) -join ' | ' }
        Add-Check $Area "$Label validates against omnidiag-report.v1.json" ([bool]$valid) $detail
    } else {
        Add-Check $Area "$Label validates against omnidiag-report.v1.json" $true 'Test-Json needs PowerShell 7' -Skipped
    }
    return $doc
}

function Get-ReportFromDirectory {
    # Checks the HTML and JSON in a report folder; returns the parsed JSON or $null.
    param([string] $Area, [string] $Directory)
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) {
        Add-Check $Area 'report folder exists' $false "$Directory"
        return $null
    }
    $html = @(Get-ChildItem -LiteralPath $Directory -Filter '*.html' -File -Recurse | Sort-Object LastWriteTime -Descending)
    $htmlOk = $html.Count -gt 0 -and $html[0].Length -gt 0
    $htmlDetail = 'no .html file'
    if ($html.Count -gt 0) {
        $head = [System.IO.File]::ReadAllText($html[0].FullName)
        $htmlOk = $htmlOk -and ($head -match '(?i)<html')
        $htmlDetail = "$($html[0].Name), $($html[0].Length) bytes"
    }
    Add-Check $Area 'HTML report exists and is not empty' $htmlOk $htmlDetail
    $json = @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -Recurse | Sort-Object LastWriteTime -Descending)
    if ($json.Count -eq 0) { Add-Check $Area 'JSON report exists' $false 'no .json file'; return $null }
    Add-Check $Area 'JSON report exists' $true $json[0].Name
    return (Test-ReportText $Area 'JSON report' ([System.IO.File]::ReadAllText($json[0].FullName)))
}

function Get-ReportStat {
    param($Doc)
    $modules = @($Doc.modules)
    $findings = @($modules | ForEach-Object { @($_.findings) })
    [pscustomobject]@{
        IsAdmin             = [bool]$Doc.host.isAdmin
        Modules             = $modules.Count
        Ran                 = @($modules | Where-Object { $_.status -ne 'Skipped' }).Count
        SkippedElevation    = @($modules | Where-Object { $_.skippedReason -eq 'RequiresElevation' }).Count
        DeclaredElevation   = @($modules | Where-Object { $_.requiresElevation }).Count
        Failed              = @($modules | Where-Object { $_.status -eq 'Failed' }).Count
        Findings            = $findings.Count
        ElevationFindings   = @($findings | Where-Object { [string]$_.id -match $elevationIdPattern }).Count
        ModuleIds           = @($modules | ForEach-Object { [string]$_.id } | Sort-Object)
    }
}

function Test-StandardReport {
    param([string] $Area, $Doc)
    $s = Get-ReportStat $Doc
    Add-Check $Area 'host.isAdmin is false' (-not $s.IsAdmin) "isAdmin=$($s.IsAdmin)"
    $declared = @(@($Doc.modules) | Where-Object { $_.requiresElevation })
    $bad = @($declared | Where-Object { $_.status -ne 'Skipped' -or $_.skippedReason -ne 'RequiresElevation' -or $_.error })
    $detail = "$($declared.Count) module(s) declare requiresElevation"
    if ($declared.Count -eq 0) { $detail += ' (none today; elevation-dependent data is reported per finding)' }
    if ($bad.Count -gt 0) { $detail += '; not skipped cleanly: ' + (($bad | ForEach-Object { "$($_.id)=$($_.status)/$($_.skippedReason)" }) -join ', ') }
    Add-Check $Area 'requiresElevation modules are Skipped with skippedReason RequiresElevation (no error)' ($bad.Count -eq 0) $detail
    $reasons = @(@($Doc.modules) | Where-Object { $_.skippedReason } | ForEach-Object { [string]$_.skippedReason } | Sort-Object -Unique)
    $unknown = @($reasons | Where-Object { $_ -notin @('RequiresElevation', 'NotSupported', 'Cancelled') })
    Add-Check $Area 'skippedReason values are documented' ($unknown.Count -eq 0) ("reasons: " + ($(if ($reasons.Count) { $reasons -join ', ' } else { 'none' })))
    $notices = @(@($Doc.modules) | ForEach-Object { @($_.findings) } | Where-Object { [string]$_.id -match $elevationIdPattern })
    $noticeBad = @($notices | Where-Object { $_.severity -ne 'Info' })
    Add-Check $Area 'elevation notices are present and are Information findings (structured skip, not an error)' `
        ($notices.Count -gt 0 -and $noticeBad.Count -eq 0) ("{0} notice(s): {1}" -f $notices.Count, ((@($notices | ForEach-Object { [string]$_.id }) | Sort-Object -Unique) -join ', '))
    $denied = @(@($Doc.modules) | Where-Object { $_.status -eq 'Failed' -and [string]$_.error -match $deniedPattern })
    $failedAll = @(@($Doc.modules) | Where-Object { $_.status -eq 'Failed' })
    $failDetail = "$($failedAll.Count) module(s) Failed"
    if ($failedAll.Count -gt 0) { $failDetail += ': ' + (($failedAll | ForEach-Object { "$($_.id) ($($_.error))" }) -join '; ') }
    Add-Check $Area 'no module failed for lack of rights (access denied)' ($denied.Count -eq 0) $failDetail
    return $s
}

function Test-ElevatedReport {
    param([string] $Area, $Doc)
    $s = Get-ReportStat $Doc
    Add-Check $Area 'host.isAdmin is true' $s.IsAdmin "isAdmin=$($s.IsAdmin)"
    Add-Check $Area 'no module skipped for RequiresElevation' ($s.SkippedElevation -eq 0) "$($s.SkippedElevation) skipped"
    $notices = @(@($Doc.modules) | ForEach-Object { @($_.findings) } | Where-Object { [string]$_.id -match $elevationIdPattern } | ForEach-Object { [string]$_.id })
    Add-Check $Area 'no elevation notice: the elevation-only sections ran' ($notices.Count -eq 0) $(if ($notices.Count) { $notices -join ', ' } else { "$($s.Ran) of $($s.Modules) modules ran" })
    return $s
}

# --- Main ------------------------------------------------------------------------------
$standardStat = $null
$elevatedStat = $null
$inputError = $null
try {
    if ($Expect -eq 'Standard') {
        if (-not $RunResultPath -or -not (Test-Path -LiteralPath $RunResultPath)) { throw "results.json not found: $RunResultPath" }
        $runDir = Split-Path -Path (Resolve-Path -LiteralPath $RunResultPath).ProviderPath -Parent
        $run = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $RunResultPath).ProviderPath) | ConvertFrom-Json
        Add-Check 'Identity' 'standard-user self-check passed' ($run.selfCheck -eq 'passed' -and $run.exitCode -eq 0) "selfCheck=$($run.selfCheck), runner exit $($run.exitCode), mechanism $($run.mechanism)"
        $stepsByName = @{}
        foreach ($st in @($run.steps)) {
            $stepsByName[[string]$st.name] = $st
            $id = $st.identity
            $ok = $null -ne $id -and -not $id.elevated -and -not $id.isAdministratorRole -and -not $id.administratorsGroupPresent -and
                [string]$id.integrityLevel -in @('Medium', 'Low', 'MediumPlus') -and [string]$id.userSid -eq [string]$run.accountSid
            $detail = 'no identity record'
            if ($id) { $detail = "$($id.user), integrity $($id.integrityLevel), Administrators in token: $($id.administratorsGroupPresent), IsInRole(Administrator): $($id.isAdministratorRole)" }
            Add-Check 'Identity' "step '$($st.name)' ran as the standard account, not elevated" $ok $detail
        }
        foreach ($required in @($TestStep, $ReportStep, $ScanStep)) {
            if ($required -and -not $stepsByName.ContainsKey($required)) { Add-Check 'Inputs' "step '$required' present" $false 'missing from results.json' }
        }

        if ($TestStep -and $stepsByName.ContainsKey($TestStep)) {
            $t = $stepsByName[$TestStep]
            Add-Check 'Pester' 'Pester suite passed as a standard user' ($t.exitCode -eq 0) "exit code $($t.exitCode)$(if ($t.launchError) { '; ' + $t.launchError })"
        }
        if ($ReportStep -and $stepsByName.ContainsKey($ReportStep)) {
            $r = $stepsByName[$ReportStep]
            $code = -1
            if ($null -ne $r.exitCode) { $code = [int]$r.exitCode }
            Test-ExitCodeValue 'Standard report' "'report'" $code
            $doc = Get-ReportFromDirectory 'Standard report' (Join-Path $runDir $r.out)
            if ($doc) { $standardStat = Test-StandardReport 'Standard report' $doc }
        }
        if ($ScanStep -and $stepsByName.ContainsKey($ScanStep)) {
            $sc = $stepsByName[$ScanStep]
            $code = -1
            if ($null -ne $sc.exitCode) { $code = [int]$sc.exitCode }
            Test-ExitCodeValue 'Standard scan' "'scan --format json'" $code
            $stdoutPath = Join-Path $runDir $sc.stdout
            if (Test-Path -LiteralPath $stdoutPath) {
                $scanDoc = Test-ReportText 'Standard scan' 'scan stdout' ([System.IO.File]::ReadAllText($stdoutPath))
                if ($scanDoc) {
                    Add-Check 'Standard scan' 'host.isAdmin is false' (-not [bool]$scanDoc.host.isAdmin) "isAdmin=$($scanDoc.host.isAdmin)"
                }
            } else {
                Add-Check 'Standard scan' 'scan stdout captured' $false $stdoutPath
            }
        }
        if ($CompareWithReportDirectory) {
            Test-ExitCodeValue 'Elevated report' "elevated 'report'" $CompareExitCode
            $eDoc = Get-ReportFromDirectory 'Elevated report' $CompareWithReportDirectory
            if ($eDoc) { $elevatedStat = Test-ElevatedReport 'Elevated report' $eDoc }
        }
    } else {
        Test-ExitCodeValue 'Elevated report' "'report'" $ExitCode
        $eDoc = Get-ReportFromDirectory 'Elevated report' $ReportDirectory
        if ($eDoc) { $elevatedStat = Test-ElevatedReport 'Elevated report' $eDoc }
    }

    if ($standardStat -and $elevatedStat) {
        $same = (($standardStat.ModuleIds -join ',') -eq ($elevatedStat.ModuleIds -join ','))
        Add-Check 'Comparison' 'both reports cover the same scanners' $same "$($standardStat.Modules) vs $($elevatedStat.Modules) modules"
        Add-Check 'Comparison' 'standard report has more elevation notices than the elevated one' `
            ($standardStat.ElevationFindings -gt $elevatedStat.ElevationFindings) "$($standardStat.ElevationFindings) vs $($elevatedStat.ElevationFindings)"
        Add-Check 'Comparison' 'at least as many modules run when elevated' ($elevatedStat.Ran -ge $standardStat.Ran) "$($elevatedStat.Ran) elevated vs $($standardStat.Ran) standard"
    }
} catch {
    $inputError = $_.Exception.Message
    Add-Check 'Inputs' 'inputs readable' $false $inputError
}

# --- Output ------------------------------------------------------------------------------
$failed = @($checks | Where-Object Result -eq 'FAIL')
$md = [System.Collections.Generic.List[string]]::new()
$md.Add("### Privilege check ($Expect)")
$md.Add('')
if ($standardStat -or $elevatedStat) {
    $md.Add('| | Standard user | Elevated |')
    $md.Add('|---|---:|---:|')
    $cell = { param($stat, $name) if ($stat) { [string]$stat.$name } else { '-' } }
    foreach ($row in @(@('host.isAdmin', 'IsAdmin'), @('Modules', 'Modules'), @('Modules run', 'Ran'),
            @('Skipped: RequiresElevation', 'SkippedElevation'), @('Modules failed', 'Failed'),
            @('Findings', 'Findings'), @('Elevation notices', 'ElevationFindings'))) {
        $md.Add(('| {0} | {1} | {2} |' -f $row[0], (& $cell $standardStat $row[1]), (& $cell $elevatedStat $row[1])))
    }
    $md.Add('')
}
$md.Add('| Area | Check | Result | Detail |')
$md.Add('|---|---|---|---|')
foreach ($c in $checks) { $md.Add(('| {0} | {1} | {2} | {3} |' -f $c.Area, $c.Check, $c.Result, ([string]$c.Detail).Replace('|', '/'))) }
$md.Add('')
$verdict = 'PASS'
if ($failed.Count -gt 0) { $verdict = "FAIL ($($failed.Count) check(s))" }
$md.Add("**$verdict**")
$md.Add('')
$mdText = $md -join "`n"

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$doc = [ordered]@{
    kind     = 'privilege-check'
    expect   = $Expect
    verdict  = $verdict
    standard = $standardStat
    elevated = $elevatedStat
    checks   = @($checks)
}
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'privilege-check.json'), ($doc | ConvertTo-Json -Depth 5), $utf8)
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'privilege-check.md'), $mdText, $utf8)
if ($env:GITHUB_STEP_SUMMARY) { [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $mdText + "`n", $utf8) }
Write-Host $mdText

if ($inputError -and $checks.Count -le 1) { exit 2 }
if ($failed.Count -gt 0) { exit 1 }
exit 0
