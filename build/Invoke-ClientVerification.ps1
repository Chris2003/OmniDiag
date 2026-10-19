<#
.SYNOPSIS
    Verifies OmniDiag on a real Windows 10 / Windows 11 client and writes a result JSON to
    attach to the release notes or the verification issue.

.DESCRIPTION
    Hosted CI runners are Windows Server (plus one Windows 11 ARM64 image), so client
    behavior is verified by the owner on real machines (docs/VERIFICATION.md). Run this
    from the extracted portable folder or a checkout, once from a normal (standard user)
    prompt and once from an elevated prompt. It runs only OmniDiag's own read-only
    commands and never applies a repair:

      os            Caption, version, build, UBR, DisplayVersion, EditionID, ProductType
                    (1 = client), architecture.
      privilege     elevated or standard user (IsInRole + the token's integrity level).
      hosts         Windows PowerShell 5.1 and PowerShell 7 (when installed) each run
                    'omnidiag version' and 'scan --group system --format json'.
      launcher      'OmniDiag.cmd version' exits 0; 'OmniDiag.cmd scan --range bogus'
                    returns 10 through %ERRORLEVEL% (exit-code pass-through).
      elevation     standard user only: 'OmniDiag.cmd scan --elevated-only' returns 4.
      report        'OmniDiag.cmd report --bundle --output <dir>': exit code 0-3; HTML,
                    JSON, and ZIP exist; JSON validates against schema v1 (PowerShell 7);
                    host.isAdmin matches the prompt; elevation notices present only when
                    not elevated.
      gui           (unless -SkipGui) 'OmniDiag.cmd gui' shows its window; the time to the
                    first window is recorded (target < 2 s), then the window is closed.
      manual        with -Interactive, asks the checklist questions from
                    docs/VERIFICATION.md (y/n/s) and records the answers.

    The result file (client-verification-<timestamp>.json in -OutputDirectory) holds no
    computer, user, or domain name. The report files written next to it DO contain
    identifiers; attach only the result JSON, or re-run with -Redact.

    Exit code: 0 = no automated check failed; 1 = at least one failed; 2 = could not run.
    Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER OutputDirectory
    Where the result JSON and the report bundle go. Default:
    <tool>\verification-results\<timestamp>.

.PARAMETER SkipGui
    Do not open the GUI (for example over a remote shell without a desktop).

.PARAMETER Redact
    Pass --redact to the report command.

.PARAMETER Interactive
    Ask the manual checklist questions and record the answers.

.PARAMETER Notes
    Free text stored in the result (e.g. 'Dell Latitude 5420, BitLocker on').

.EXAMPLE
    .\build\Invoke-ClientVerification.ps1 -Interactive

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Invoke-ClientVerification.ps1 -SkipGui -Notes 'Win10 22H2 VM'
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [switch] $SkipGui,
    [switch] $Redact,
    [switch] $Interactive,
    [string] $Notes = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $root 'OmniDiag.cmd'
$cli = Join-Path $root (Join-Path 'src' (Join-Path 'Cli' 'omnidiag.ps1'))
$schemaPath = Join-Path $root (Join-Path 'schemas' 'omnidiag-report.v1.json')
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root (Join-Path 'verification-results' $stamp) }
$utf8 = [System.Text.UTF8Encoding]::new($false)

$onWindows = $true
try { if ($IsWindows -eq $false) { $onWindows = $false } } catch { $onWindows = $true }
if (-not $onWindows) { Write-Host 'Invoke-ClientVerification: Windows only.'; exit 2 }
if (-not (Test-Path -LiteralPath $launcher)) { Write-Host "OmniDiag.cmd not found next to build\ ($launcher)."; exit 2 }
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

$checks = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string] $Id, [string] $Title, [ValidateSet('Pass', 'Fail', 'Skipped', 'Info')] [string] $Status, [string] $Detail = '')
    $checks.Add([ordered]@{ id = $Id; title = $Title; status = $Status; detail = $Detail })
    Write-Host ('[{0,-7}] {1}: {2}' -f $Status, $Title, $Detail)
}

function Invoke-Captured {
    # Runs a program with arguments (one command-line string); returns exit code and output.
    param([string] $FilePath, [string] $Arguments, [int] $TimeoutSeconds = 600)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath, $Arguments)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $code = $null
    if ($p.WaitForExit($TimeoutSeconds * 1000)) { $p.WaitForExit(); $code = $p.ExitCode } else { try { $p.Kill() } catch { Write-Verbose 'already exited' } }
    [void]$out.Wait(10000); [void]$err.Wait(10000)
    [pscustomobject]@{ ExitCode = $code; Stdout = $out.Result; Stderr = $err.Result }
}

$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
function Invoke-Launcher {
    param([string] $Arguments, [int] $TimeoutSeconds = 600)
    Invoke-Captured -FilePath $cmdExe -Arguments ("/d /s /c `"`"$launcher`" $Arguments`"") -TimeoutSeconds $TimeoutSeconds
}

# --- os ------------------------------------------------------------------------------
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$cvValue = { param($name) if ($cv -and $cv.PSObject.Properties[$name]) { [string]$cv.$name } else { '' } }
$productType = [int]$os.ProductType
$osInfo = [ordered]@{
    caption        = [string]$os.Caption
    version        = [string]$os.Version
    build          = [string]$os.BuildNumber
    ubr            = (& $cvValue 'UBR')
    displayVersion = (& $cvValue 'DisplayVersion')
    editionId      = (& $cvValue 'EditionID')
    installationType = (& $cvValue 'InstallationType')
    productType    = $productType
    productTypeName = $(switch ($productType) { 1 { 'Workstation (client)' } 2 { 'Domain controller' } 3 { 'Server' } default { 'Unknown' } })
    architecture   = [string]$os.OSArchitecture
    processorArchitecture = [string]$env:PROCESSOR_ARCHITECTURE
}
$isClient = $productType -eq 1
Add-Result 'os.client' 'Windows client edition (ProductType 1)' $(if ($isClient) { 'Pass' } else { 'Info' }) ("{0} {1} build {2}.{3} ({4})" -f $osInfo.caption, $osInfo.displayVersion, $osInfo.build, $osInfo.ubr, $osInfo.architecture)

# --- privilege ---------------------------------------------------------------------------
$principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$ErrorActionPreference = 'Continue'
$groupsCsv = @(& (Join-Path $env:SystemRoot 'System32\whoami.exe') /groups /fo csv /nh 2>$null)
$ErrorActionPreference = 'Stop'
$groups = @($groupsCsv | Where-Object { $_ } | ConvertFrom-Csv -Header 'Name', 'Type', 'Sid', 'Attributes')
$labelRows = @($groups | Where-Object { $_.Sid -like 'S-1-16-*' })
$integrity = 'Unknown'
if ($labelRows.Count -gt 0) {
    $integrity = switch ([string]$labelRows[0].Sid) { 'S-1-16-4096' { 'Low' } 'S-1-16-8192' { 'Medium' } 'S-1-16-12288' { 'High' } 'S-1-16-16384' { 'System' } default { [string]$labelRows[0].Sid } }
}
$privilege = [ordered]@{
    elevated       = $isAdmin
    integrityLevel = $integrity
    administratorsGroupInToken = (@($groups | Where-Object { $_.Sid -eq 'S-1-5-32-544' }).Count -gt 0)
    kind           = $(if ($isAdmin) { 'elevated' } elseif (@($groups | Where-Object { $_.Sid -eq 'S-1-5-32-544' }).Count -gt 0) { 'admin account, not elevated (UAC filtered token)' } else { 'standard user' })
}
Add-Result 'privilege' 'Prompt privilege' 'Info' ("{0}, integrity {1}" -f $privilege.kind, $integrity)

# --- hosts ---------------------------------------------------------------------------------
$hostExes = [ordered]@{ 'powershell-5.1' = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
# The pinned locations OmniDiag.cmd uses (never a PATH lookup), in the launcher's precedence:
# %ProgramW6432%, then %ProgramFiles%, then %ProgramFiles(x86)%.
$pwshPath = $null
foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $base) { continue }
    $candidate = Join-Path $base 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $candidate) { $pwshPath = $candidate; break }
}
if ($pwshPath) { $hostExes['pwsh-7'] = $pwshPath }
$hostInfo = [ordered]@{}
foreach ($h in $hostExes.Keys) {
    $exe = $hostExes[$h]
    if (-not (Test-Path -LiteralPath $exe)) { Add-Result "host.$h" "$h present" 'Skipped' 'not installed'; continue }
    $v = Invoke-Captured -FilePath $exe -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$cli`" version --format json" -TimeoutSeconds 120
    $versionText = ''
    try { $versionText = [string](($v.Stdout | ConvertFrom-Json).powershell.version) } catch { $versionText = '' }
    Add-Result "host.$h.version" "$h runs 'omnidiag version'" $(if ($v.ExitCode -eq 0) { 'Pass' } else { 'Fail' }) "exit $($v.ExitCode) $versionText"
    $s = Invoke-Captured -FilePath $exe -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$cli`" scan --group system --format json --quiet" -TimeoutSeconds 600
    $parsed = $false
    try { $null = $s.Stdout | ConvertFrom-Json; $parsed = $true } catch { $parsed = $false }
    $ok = ($s.ExitCode -in @(0, 1, 2, 3)) -and $parsed
    Add-Result "host.$h.scan" "$h runs 'scan --group system --format json'" $(if ($ok) { 'Pass' } else { 'Fail' }) "exit $($s.ExitCode), JSON parsed: $parsed"
    $hostInfo[$h] = [ordered]@{ path = $exe; version = $versionText; versionExit = $v.ExitCode; scanExit = $s.ExitCode }
}

# --- launcher exit codes -------------------------------------------------------------------
$lv = Invoke-Launcher 'version' 120
Add-Result 'launcher.version' "OmniDiag.cmd version exits 0" $(if ($lv.ExitCode -eq 0) { 'Pass' } else { 'Fail' }) ("exit {0}: {1}" -f $lv.ExitCode, ([string]$lv.Stdout).Trim())
$lu = Invoke-Launcher 'scan --range bogus --quiet' 120
Add-Result 'launcher.exit-code' "OmniDiag.cmd passes a usage error (10) through %ERRORLEVEL%" $(if ($lu.ExitCode -eq 10) { 'Pass' } else { 'Fail' }) "exit $($lu.ExitCode)"
if (-not $isAdmin) {
    $le = Invoke-Launcher 'scan --elevated-only --quiet' 120
    Add-Result 'elevation.exit-4' "Standard prompt: 'scan --elevated-only' exits 4" $(if ($le.ExitCode -eq 4) { 'Pass' } else { 'Fail' }) "exit $($le.ExitCode)"
} else {
    Add-Result 'elevation.exit-4' "Standard prompt: 'scan --elevated-only' exits 4" 'Skipped' 'run again from a standard (non-elevated) prompt'
}

# --- report bundle -----------------------------------------------------------------------------
$reportDir = Join-Path $OutputDirectory 'report'
$reportArgs = "report --bundle --output `"$reportDir`""
if ($Redact) { $reportArgs += ' --redact' }
$started = Get-Date
$rep = Invoke-Launcher $reportArgs 900
$reportSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
Add-Result 'report.exit' "OmniDiag.cmd report --bundle exit code 0-3" $(if ($rep.ExitCode -in @(0, 1, 2, 3)) { 'Pass' } else { 'Fail' }) "exit $($rep.ExitCode) in $reportSeconds s (target < 60 s)"
$files = @()
if (Test-Path -LiteralPath $reportDir) { $files = @(Get-ChildItem -LiteralPath $reportDir -File -Recurse) }
foreach ($ext in @('.html', '.json', '.zip')) {
    $f = @($files | Where-Object { $_.Extension -eq $ext } | Sort-Object Length -Descending)
    $ok = $f.Count -gt 0 -and $f[0].Length -gt 0
    Add-Result "report$ext" "report wrote a non-empty $ext" $(if ($ok) { 'Pass' } else { 'Fail' }) $(if ($f.Count) { "$($f[0].Length) bytes" } else { 'missing' })
}
$jsonFile = @($files | Where-Object { $_.Extension -eq '.json' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
$reportSummary = $null
if ($jsonFile.Count -gt 0) {
    $text = [System.IO.File]::ReadAllText($jsonFile[0].FullName)
    $doc = $text | ConvertFrom-Json
    if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
        $valid = $false
        try { $valid = Test-Json -Json $text -Schema ([System.IO.File]::ReadAllText($schemaPath)) -ErrorAction SilentlyContinue } catch { $valid = $false }
        Add-Result 'report.schema' 'report JSON validates against schema v1' $(if ($valid) { 'Pass' } else { 'Fail' }) ''
    } else {
        Add-Result 'report.schema' 'report JSON validates against schema v1' 'Skipped' 'run this script under pwsh 7 to validate'
    }
    Add-Result 'report.isAdmin' 'report host.isAdmin matches the prompt' $(if ([bool]$doc.host.isAdmin -eq $isAdmin) { 'Pass' } else { 'Fail' }) "isAdmin=$($doc.host.isAdmin)"
    $modules = @($doc.modules)
    $notices = @($modules | ForEach-Object { @($_.findings) } | Where-Object { [string]$_.id -match '(?i)[.-]requires?-elevation$' })
    $noticeOk = if ($isAdmin) { $notices.Count -eq 0 } else { $notices.Count -gt 0 -and @($notices | Where-Object { $_.severity -ne 'Info' }).Count -eq 0 }
    $expectText = if ($isAdmin) { 'none expected when elevated' } else { 'Information notices expected as a standard user' }
    Add-Result 'report.elevation-notices' 'elevation notices match the privilege' $(if ($noticeOk) { 'Pass' } else { 'Fail' }) ("{0} notice(s); {1}" -f $notices.Count, $expectText)
    $failedModules = @($modules | Where-Object { $_.status -eq 'Failed' })
    Add-Result 'report.failed-modules' 'no module Failed' $(if ($failedModules.Count -eq 0) { 'Pass' } else { 'Fail' }) (($failedModules | ForEach-Object { "$($_.id): $($_.error)" }) -join '; ')
    $reportSummary = [ordered]@{
        seconds = $reportSeconds; exitCode = $rep.ExitCode; modules = $modules.Count
        ran = @($modules | Where-Object { $_.status -ne 'Skipped' }).Count
        skipped = @($modules | Where-Object { $_.status -eq 'Skipped' } | ForEach-Object { [ordered]@{ id = $_.id; reason = $_.skippedReason } })
        failed = @($failedModules | ForEach-Object { [ordered]@{ id = $_.id; error = $_.error } })
        statusCounts = [ordered]@{}
        healthScore = $doc.summary.healthScore; grade = $doc.summary.grade
        elevationNotices = @($notices | ForEach-Object { [string]$_.id })
    }
    foreach ($g in ($modules | Group-Object status)) { $reportSummary.statusCounts[[string]$g.Name] = $g.Count }
}

# --- gui ---------------------------------------------------------------------------------------
$gui = [ordered]@{ opened = $false; secondsToWindow = $null; title = '' }
if ($SkipGui) {
    Add-Result 'gui.open' 'GUI window opens' 'Skipped' '-SkipGui'
} elseif (-not [Environment]::UserInteractive) {
    Add-Result 'gui.open' 'GUI window opens' 'Skipped' 'no interactive desktop'
} else {
    $before = @(Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $t0 = Get-Date
    $launch = Start-Process -FilePath $cmdExe -ArgumentList ("/d /s /c `"`"$launcher`" gui`"") -WorkingDirectory $root -PassThru -WindowStyle Hidden
    $window = $null
    while (((Get-Date) - $t0).TotalSeconds -lt 60 -and -not $window) {
        Start-Sleep -Milliseconds 100
        $window = Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -notin $before -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -match 'OmniDiag' } |
            Select-Object -First 1
    }
    if ($window) {
        $gui.opened = $true
        $gui.secondsToWindow = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
        $gui.title = 'OmniDiag'
        Start-Sleep -Seconds 3
        [void]$window.CloseMainWindow()
        if (-not $window.WaitForExit(15000)) { Stop-Process -Id $window.Id -Force -ErrorAction SilentlyContinue }
        Add-Result 'gui.open' 'GUI window opens' 'Pass' ("first window after {0} s (target < 2 s, includes PowerShell start)" -f $gui.secondsToWindow)
    } else {
        Add-Result 'gui.open' 'GUI window opens' 'Fail' 'no OmniDiag window within 60 s'
    }
    try { if (-not $launch.HasExited) { Stop-Process -Id $launch.Id -Force -ErrorAction SilentlyContinue } } catch { Write-Verbose 'launcher gone' }
}

# --- manual checklist (docs/VERIFICATION.md) ------------------------------------------------------
$manualItems = @(
    @{ id = 'manual.gui-dashboard'; question = 'GUI: the dashboard shows a health score and the findings list fills after a scan' },
    @{ id = 'manual.gui-keyboard'; question = 'GUI: Tab reaches every control; Narrator reads the section names' },
    @{ id = 'manual.gui-contrast'; question = 'GUI: High Contrast (Win+Left Alt+Print Screen) keeps every text readable' },
    @{ id = 'manual.report-html'; question = 'The HTML report opens in the default browser and looks complete' },
    @{ id = 'manual.standard-skips'; question = 'As a standard user: the report says which checks need elevation instead of showing errors' },
    @{ id = 'manual.client-findings'; question = 'Client-only data looks right (battery, Wi-Fi, BitLocker, Defender, Reliability Monitor)' }
)
$manual = [System.Collections.Generic.List[object]]::new()
foreach ($item in $manualItems) {
    $answer = 'not recorded'
    if ($Interactive) {
        $reply = Read-Host ("{0}? [y]es / [n]o / [s]kip" -f $item.question)
        $answer = switch -Regex ($reply) { '^(?i)y' { 'yes' } '^(?i)n' { 'no' } default { 'skipped' } }
    }
    $manual.Add([ordered]@{ id = $item.id; question = $item.question; answer = $answer })
}

# --- result ---------------------------------------------------------------------------------------
$toolVersion = ''
try { $toolVersion = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $root 'src\OmniDiag.psd1')).ModuleVersion } catch { $toolVersion = '' }
$failedChecks = @($checks | Where-Object { $_.status -eq 'Fail' })
$result = [ordered]@{
    kind          = 'omnidiag-client-verification'
    schemaVersion = '1.0.0'
    generatedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    tool          = [ordered]@{ name = 'OmniDiag'; version = $toolVersion }
    runner        = [ordered]@{ powershell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)" }
    os            = $osInfo
    privilege     = $privilege
    hosts         = $hostInfo
    report        = $reportSummary
    gui           = $gui
    checks        = @($checks)
    manual        = @($manual)
    notes         = $Notes
    verdict       = $(if ($failedChecks.Count -gt 0) { 'FAIL' } else { 'PASS' })
}
$resultPath = Join-Path $OutputDirectory "client-verification-$stamp.json"
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 6), $utf8)
Write-Host ''
Write-Host ("Verdict: {0} ({1} failed of {2} automated checks)" -f $result.verdict, $failedChecks.Count, @($checks | Where-Object { $_.status -in @('Pass', 'Fail') }).Count)
Write-Host "Result (no computer or user names): $resultPath"
Write-Host "Report files (contain identifiers unless -Redact): $reportDir"
if ($failedChecks.Count -gt 0) { exit 1 }
exit 0
