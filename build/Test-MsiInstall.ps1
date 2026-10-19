<#
.SYNOPSIS
    Installs the OmniDiag MSI for the current user, checks every promise in
    docs/INSTALLER.md, uninstalls it, and checks that everything it installed is gone.

.DESCRIPTION
    Backs the CI 'installer' job. Runs as whoever starts it: the (elevated) runner account,
    and - through build/Invoke-AsStandardUser.ps1 - a throwaway standard user, which proves
    the per-user MSI needs no administrator rights.

    Install (msiexec /i /qn, verbose log) must exit 0, then:
      * files are in %LOCALAPPDATA%\Programs\OmniDiag (launchers, module, bin\omnidiag.cmd,
        the installed-mode marker; install.ps1 left out), and the file count matches the
        MSI File table;
      * nothing new under Program Files, no OmniDiag ARP entry under HKLM (64- and 32-bit
        views); the ARP entry is under HKCU\...\Uninstall\<ProductCode> with the version and
        publisher; Windows Installer reports AssignmentType 0 (per-user);
      * Start menu shortcuts in the per-user Programs folder (none in the all-users one),
        pointing at the launchers;
      * the user PATH (HKCU\Environment) ends with <install dir>\bin; the machine PATH does not
        contain it;
      * a NEW shell whose PATH is re-read from the registry (machine + user, as Explorer
        builds it) runs 'omnidiag version' with exit code 0 and prints the version, in
        cmd.exe and in Windows PowerShell (which must resolve the .cmd, not OmniDiag.ps1);
      * the run wrote its data to %LOCALAPPDATA%\OmniDiag\Data, not the install folder.
    Uninstall (msiexec /x /qn) must exit 0, then the install folder, shortcuts, PATH entry,
    HKCU ARP entry, and HKCU\Software\OmniDiag\Installer are gone, and the user data folder
    is still there (kept by design; this script removes it afterwards when it created it).

    Writes checks.json (every check, pass/fail, detail) and the msiexec logs to
    -OutputDirectory. Exit code 0 = all checks passed, 1 = a check failed, 2 = could not run.
    Windows only; Windows PowerShell 5.1 or PowerShell 7+.

.PARAMETER MsiPath
    The MSI to test (e.g. dist/OmniDiag-1.0.0-x64.msi).

.PARAMETER Version
    Expected version. Default: the MSI's ProductVersion.

.PARAMETER OutputDirectory
    Logs and checks.json. Default: test-results/msi-install.

.PARAMETER KeepInstalled
    Stop after the install checks (no uninstall).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $MsiPath,
    [string] $Version,
    [string] $OutputDirectory,
    [switch] $KeepInstalled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot (Join-Path 'test-results' 'msi-install') }
$utf8 = [System.Text.UTF8Encoding]::new($false)
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string] $Name, [bool] $Passed, [string] $Detail = '')
    $checks.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
    $mark = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[msi-test] {0} {1}{2}" -f $mark, $Name, $(if ($Detail) { " - $Detail" } else { '' }))
    if (-not $Passed) { Write-Host "::error::MSI check failed: $Name $Detail" }
}

function Get-PathEntry {
    param([AllowNull()][string] $Value)
    if (-not $Value) { return @() }
    return @($Value -split ';' | Where-Object { $_ } | ForEach-Object { $_.Trim().TrimEnd('\') })
}

function Test-PathListContains {
    param([AllowNull()][string] $Value, [string] $Entry)
    $want = $Entry.TrimEnd('\')
    foreach ($e in (Get-PathEntry $Value)) {
        if ([string]::Equals([System.Environment]::ExpandEnvironmentVariables($e), $want, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-RegistryPath {
    <# Raw (unexpanded) PATH from the registry, as Explorer reads it for a new shell. #>
    param([ValidateSet('User', 'Machine')][string] $Scope)
    if ($Scope -eq 'User') {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    } else {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
    }
    if (-not $key) { return '' }
    try { return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Close() }
}

function Invoke-Msiexec {
    param([string[]] $Arguments, [string] $LogName)
    $log = Join-Path $OutputDirectory $LogName
    $argLine = ($Arguments + @('/qn', '/norestart', '/l*v', ('"{0}"' -f $log))) -join ' '
    Write-Host "[msi-test] msiexec $argLine"
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}

function Invoke-NewShell {
    <# Runs a command line in a fresh process whose PATH is machine + user PATH from the registry. #>
    param([string] $FilePath, [string] $Arguments, [string] $WorkingDirectory)
    $machine = [System.Environment]::ExpandEnvironmentVariables((Get-RegistryPath -Scope Machine))
    $user = [System.Environment]::ExpandEnvironmentVariables((Get-RegistryPath -Scope User))
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath, $Arguments)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.EnvironmentVariables['PATH'] = (@($machine, $user) | Where-Object { $_ }) -join ';'
    # Not inherited from this (test) process: the launchers decide the data location.
    $psi.EnvironmentVariables.Remove('OMNIDIAG_DATA')
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(300000)) { try { $proc.Kill() } catch { $null = $_ }; return [pscustomobject]@{ ExitCode = 124; Stdout = ''; Stderr = 'TIMEOUT' } }
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $outTask.Result; Stderr = $errTask.Result }
}

$exitCode = 0
$createdData = $false
$installed = $false
try {
    $onWindows = $true
    try { if ($IsWindows -eq $false) { $onWindows = $false } } catch { $onWindows = $true }
    if (-not $onWindows) { Write-Host 'Test-MsiInstall: Windows only.'; exit 2 }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
    Import-Module (Join-Path $PSScriptRoot 'OmniDiag.Installer.psm1') -DisableNameChecking
    $constants = Get-OmniInstallerConstant
    $MsiPath = (Resolve-Path -LiteralPath $MsiPath).ProviderPath
    $info = Get-OmniMsiInfo -Path $MsiPath
    if (-not $Version) { $Version = $info.ProductVersion }
    $productCode = $info.ProductCode
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([System.Security.Principal.WindowsPrincipal]::new($me)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host "[msi-test] $MsiPath (ProductCode $productCode, version $Version) as $($me.Name) (administrator: $isAdmin)"

    $localAppData = [System.Environment]::GetFolderPath('LocalApplicationData')
    $installDir = Join-Path $localAppData 'Programs\OmniDiag'
    $binDir = Join-Path $installDir 'bin'
    $dataDir = Join-Path $localAppData 'OmniDiag\Data'
    $startMenu = Join-Path ([System.Environment]::GetFolderPath('Programs')) 'OmniDiag'
    $commonStartMenu = Join-Path ([System.Environment]::GetFolderPath('CommonPrograms')) 'OmniDiag'
    $programFilesDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique |
        ForEach-Object { Join-Path $_ 'OmniDiag' }
    $arpUser = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
    $arpMachine = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$productCode",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$productCode")
    $installerKey = 'HKCU:\Software\OmniDiag\Installer'

    # --- Preconditions ---------------------------------------------------------------
    if (Test-Path -LiteralPath $installDir) { throw "$installDir already exists; run on a clean profile." }
    $preProgramFiles = @($programFilesDirs | Where-Object { Test-Path -LiteralPath $_ })
    $preData = Test-Path -LiteralPath $dataDir
    $userPathBefore = Get-RegistryPath -Scope User

    # --- Install ---------------------------------------------------------------------
    $code = Invoke-Msiexec -Arguments @('/i', ('"{0}"' -f $MsiPath)) -LogName 'install.log'
    Add-Check 'msiexec /i exits 0' ($code -eq 0) "exit $code"
    if ($code -ne 0) { throw "install failed (msiexec exit $code); see install.log" }
    $installed = $true

    foreach ($rel in @('OmniDiag.cmd', 'OmniDiag-GUI.cmd', 'OmniDiag.ps1', 'src\OmniDiag.psd1', 'src\Cli\omnidiag.ps1', 'bin\omnidiag.cmd', $constants.InstalledMarker)) {
        Add-Check "installed: $rel" (Test-Path -LiteralPath (Join-Path $installDir $rel) -PathType Leaf)
    }
    Add-Check 'install.ps1 is not installed (the quick installer would replace an MSI install)' (-not (Test-Path -LiteralPath (Join-Path $installDir 'install.ps1')))
    $binFiles = @(Get-ChildItem -LiteralPath $binDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    Add-Check 'bin holds only omnidiag.cmd' (($binFiles -join ',') -eq 'omnidiag.cmd') ($binFiles -join ', ')

    $installedCount = @(Get-ChildItem -LiteralPath $installDir -Recurse -File -Force).Count
    $msiFileCount = $null
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $bf = [System.Reflection.BindingFlags]
        $db = $wi.GetType().InvokeMember('OpenDatabase', $bf::InvokeMethod, $null, $wi, @($MsiPath, 0))
        $view = $db.GetType().InvokeMember('OpenView', $bf::InvokeMethod, $null, $db, @('SELECT `File` FROM `File`'))
        [void]$view.GetType().InvokeMember('Execute', $bf::InvokeMethod, $null, $view, @())
        $msiFileCount = 0
        while ($null -ne $view.GetType().InvokeMember('Fetch', $bf::InvokeMethod, $null, $view, @())) { $msiFileCount++ }
        [void]$view.GetType().InvokeMember('Close', $bf::InvokeMethod, $null, $view, @())
    } catch { Write-Host "[msi-test] Could not count the MSI File table: $($_.Exception.Message)" }
    Add-Check 'installed file count equals the MSI File table' ($installedCount -eq $msiFileCount) "installed $installedCount, MSI $msiFileCount"

    $newProgramFiles = @($programFilesDirs | Where-Object { (Test-Path -LiteralPath $_) -and $_ -notin $preProgramFiles })
    Add-Check 'nothing written under Program Files' ($newProgramFiles.Count -eq 0) ($newProgramFiles -join ', ')
    foreach ($k in $arpMachine) { Add-Check "no ARP entry under $k" (-not (Test-Path -LiteralPath $k)) }
    $arp = Get-ItemProperty -LiteralPath $arpUser -ErrorAction SilentlyContinue
    Add-Check "ARP entry under $arpUser" ($null -ne $arp)
    if ($arp) {
        $arpValue = { param([string] $Name) if ($arp.PSObject.Properties[$Name]) { [string]$arp.$Name } else { '' } }
        $value = & $arpValue 'DisplayName'; Add-Check 'ARP DisplayName' ($value -eq 'OmniDiag') $value
        $value = & $arpValue 'DisplayVersion'; Add-Check 'ARP DisplayVersion' ($value -eq $Version) $value
        $value = & $arpValue 'Publisher'; Add-Check 'ARP Publisher' ($value -eq $constants.Publisher) $value
        $value = & $arpValue 'URLInfoAbout'; Add-Check 'ARP URLInfoAbout' ($value -eq $constants.RepositoryUrl) $value
    } else {
        $found = @(Get-ChildItem -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -eq $productCode } | ForEach-Object { $_.Name })
        Write-Host "[msi-test] ProductCode found under: $($found -join '; ')"
    }
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $assignment = [string]$wi.GetType().InvokeMember('ProductInfo', [System.Reflection.BindingFlags]::GetProperty, $null, $wi, @($productCode, 'AssignmentType'))
        Add-Check 'Windows Installer AssignmentType is 0 (per-user)' ($assignment -eq '0') "AssignmentType $assignment"
    } catch { Add-Check 'Windows Installer AssignmentType is 0 (per-user)' $false $_.Exception.Message }
    Add-Check "HKCU installer key $installerKey" (Test-Path -LiteralPath $installerKey)

    $shell = New-Object -ComObject WScript.Shell
    foreach ($lnk in @(@{ Name = 'OmniDiag.lnk'; Target = 'OmniDiag-GUI.cmd' }, @{ Name = 'OmniDiag (console).lnk'; Target = 'OmniDiag.cmd' })) {
        $path = Join-Path $startMenu $lnk.Name
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        Add-Check "Start menu shortcut $($lnk.Name) (per-user)" $exists $path
        if ($exists) {
            $target = [string]$shell.CreateShortcut($path).TargetPath
            Add-Check "$($lnk.Name) targets $($lnk.Target)" ([string]::Equals($target, (Join-Path $installDir $lnk.Target), [System.StringComparison]::OrdinalIgnoreCase)) $target
        }
    }
    Add-Check 'no all-users Start menu folder' (-not (Test-Path -LiteralPath $commonStartMenu)) $commonStartMenu

    $userPath = Get-RegistryPath -Scope User
    $machinePath = Get-RegistryPath -Scope Machine
    Add-Check 'user PATH contains <install>\bin' (Test-PathListContains $userPath $binDir) $userPath
    $lastEntry = @(Get-PathEntry $userPath) | Select-Object -Last 1
    Add-Check 'user PATH entry is appended last' ([string]::Equals([string]$lastEntry, $binDir, [System.StringComparison]::OrdinalIgnoreCase)) ([string]$lastEntry)
    Add-Check 'user PATH does not contain the install folder itself' (-not (Test-PathListContains $userPath $installDir))
    Add-Check 'machine PATH does not contain <install>\bin' (-not (Test-PathListContains $machinePath $binDir))

    # --- A new shell ----------------------------------------------------------------
    $work = Join-Path $OutputDirectory 'shell-cwd'
    $null = New-Item -ItemType Directory -Path $work -Force
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $where = Invoke-NewShell -FilePath $cmdExe -Arguments '/d /c where omnidiag' -WorkingDirectory $work
    $firstHit = @(($where.Stdout -split "`r?`n") | Where-Object { $_ }) | Select-Object -First 1
    Add-Check "'where omnidiag' resolves to bin\omnidiag.cmd" ([string]::Equals([string]$firstHit, (Join-Path $binDir 'omnidiag.cmd'), [System.StringComparison]::OrdinalIgnoreCase)) ([string]$firstHit)
    $r = Invoke-NewShell -FilePath $cmdExe -Arguments '/d /c omnidiag version' -WorkingDirectory $work
    [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'cmd-version.txt'), "exit $($r.ExitCode)`n--- stdout`n$($r.Stdout)`n--- stderr`n$($r.Stderr)", $utf8)
    Add-Check "new cmd.exe: 'omnidiag version' exits 0" ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
    Add-Check "new cmd.exe: 'omnidiag version' prints OmniDiag $Version" ($r.Stdout -match ('OmniDiag ' + [regex]::Escape($Version))) ($r.Stdout.Trim())
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $r = Invoke-NewShell -FilePath $winPs -Arguments '-NoProfile -NonInteractive -Command "omnidiag version --format json; exit $LASTEXITCODE"' -WorkingDirectory $work
    [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'powershell-version.txt'), "exit $($r.ExitCode)`n--- stdout`n$($r.Stdout)`n--- stderr`n$($r.Stderr)", $utf8)
    Add-Check "new Windows PowerShell: 'omnidiag version --format json' exits 0" ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
    $reported = $null
    try { $reported = [string]((($r.Stdout | ConvertFrom-Json).tool).version) } catch { $reported = $null }
    Add-Check 'new Windows PowerShell: JSON reports the version' ($reported -eq $Version) ([string]$reported)

    $createdData = (-not $preData) -and (Test-Path -LiteralPath $dataDir)
    Add-Check 'data goes to %LOCALAPPDATA%\OmniDiag\Data' (Test-Path -LiteralPath $dataDir) $dataDir
    Add-Check 'no OmniDiagData in the install folder' (-not (Test-Path -LiteralPath (Join-Path $installDir 'OmniDiagData')))

    if ($KeepInstalled) { Write-Host '[msi-test] -KeepInstalled: not uninstalling.' }
    else {
        # --- Uninstall -------------------------------------------------------------------
        $code = Invoke-Msiexec -Arguments @('/x', ('"{0}"' -f $MsiPath)) -LogName 'uninstall.log'
        Add-Check 'msiexec /x exits 0' ($code -eq 0) "exit $code"
        if ($code -eq 0) { $installed = $false }
        $left = @()
        if (Test-Path -LiteralPath $installDir) { $left = @(Get-ChildItem -LiteralPath $installDir -Recurse -Force | ForEach-Object { $_.FullName }) }
        Add-Check 'install folder removed' (-not (Test-Path -LiteralPath $installDir)) ($left -join ', ')
        Add-Check 'Start menu folder removed' (-not (Test-Path -LiteralPath $startMenu))
        $userPathAfter = Get-RegistryPath -Scope User
        Add-Check 'user PATH entry removed' (-not (Test-PathListContains $userPathAfter $binDir)) $userPathAfter
        $beforeEntries = @(Get-PathEntry $userPathBefore) -join ';'
        $afterEntries = @(Get-PathEntry $userPathAfter) -join ';'
        Add-Check 'user PATH otherwise unchanged' ($beforeEntries -eq $afterEntries) "before '$beforeEntries' after '$afterEntries'"
        Add-Check 'HKCU ARP entry removed' (-not (Test-Path -LiteralPath $arpUser))
        Add-Check "HKCU installer key removed" (-not (Test-Path -LiteralPath $installerKey))
        if (Test-Path -LiteralPath 'HKCU:\Software\OmniDiag') {
            Write-Host '[msi-test] Note: HKCU\Software\OmniDiag remains (left by Windows Installer when empty).'
        }
        Add-Check 'user data folder is kept on uninstall' (Test-Path -LiteralPath $dataDir) $dataDir
    }
} catch {
    Write-Host "::error::Test-MsiInstall: $($_.Exception.Message)"
    if ($exitCode -eq 0) { $exitCode = 2 }
} finally {
    if ($installed -and -not $KeepInstalled) {
        # A check threw half-way: do not leave the product installed on the machine.
        try { $null = Invoke-Msiexec -Arguments @('/x', ('"{0}"' -f $MsiPath)) -LogName 'cleanup-uninstall.log' } catch { Write-Host "Cleanup uninstall failed: $($_.Exception.Message)" }
    }
    if ($createdData -and -not $KeepInstalled) {
        Remove-Item -LiteralPath (Split-Path $dataDir -Parent) -Recurse -Force -ErrorAction SilentlyContinue
    }
    try {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
        $failed = @($checks | Where-Object { -not $_.passed })
        if ($exitCode -eq 0 -and $failed.Count -gt 0) { $exitCode = 1 }
        $doc = [ordered]@{
            kind     = 'msi-install-test'
            msi      = $MsiPath
            version  = $Version
            user     = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            exitCode = $exitCode
            passed   = @($checks | Where-Object { $_.passed }).Count
            failed   = $failed.Count
            checks   = @($checks)
        }
        [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'checks.json'), ($doc | ConvertTo-Json -Depth 4), $utf8)
        if ($env:GITHUB_STEP_SUMMARY) {
            $md = "### MSI install test ($($doc.user))`n`n$($doc.passed) passed, $($doc.failed) failed (exit $exitCode).`n`n"
            if ($failed.Count -gt 0) { $md += (($failed | ForEach-Object { "- FAIL: $($_.name) $($_.detail)" }) -join "`n") + "`n`n" }
            [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $md, $utf8)
        }
    } catch { Write-Host "Could not write checks.json: $($_.Exception.Message)" }
}
exit $exitCode
