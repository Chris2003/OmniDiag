<#
.SYNOPSIS
    Runs commands as a throwaway local standard (non-admin) user and proves the child
    processes were not elevated.

.DESCRIPTION
    Backs the CI 'standard-user' job (Phase 4: a standard-user leg alongside the elevated
    legs). Windows only; must itself run elevated (it creates and deletes a local account).

    1. Creates a local account 'odsu-<random>' with a random 32-character password that is
       generated in memory (SecureString), never written to disk, a log, or a command line,
       and never printed. The account is a member of Users only: the script refuses to
       continue if it is in Administrators. New-LocalUser is tried first; the ADSI WinNT
       provider is the fallback (Microsoft.PowerShell.LocalAccounts is not always usable
       from PowerShell 7).
    2. Copies -SourcePath (the repository, without .git) to <WorkRoot>\repo, copies the
       -ShareModule modules (e.g. Pester, installed for the runner account) to
       <WorkRoot>\modules. <WorkRoot> gets an explicit ACL with inheritance removed
       (SYSTEM and Administrators Full, the account Modify; icacls by SID), so the
       "Authenticated Users: Modify" that C:\ hands to new folders does not apply. Folders the
       account wrote are deleted with 'rmdir /s /q' and copied with 'robocopy /XJ', which do
       not follow junctions or symbolic links.
    3. Runs every -Step through a small wrapper script, as the account. The wrapper first
       records its identity (whoami /user /groups /priv, the token's integrity level, and
       Administrators membership) and REFUSES to run the payload when it finds itself
       elevated (exit 97). Then it runs the step's command with stdout and stderr captured
       to files, and writes the exit code last.
       Launch mechanisms, in order (-Mechanism Auto):
         a. StartProcess  - Start-Process -Credential -LoadUserProfile (CreateProcessWithLogonW).
                            A probe step (cmd /c ver) must complete within 90 s; on hosted
                            runners this can fail ("Access is denied", or the child dies at
                            start when the parent's window station is not usable).
         b. ScheduledTask - a one-shot scheduled task registered with the account's
                            credentials (logon type Password, RunLevel Limited). The account
                            gets SeBatchLogonRight ("Log on as a batch job") through
                            secedit for the duration of the run. Afterwards a template that
                            sets SeBatchLogonRight explicitly to its original holders (empty
                            when there were none) is applied and the result re-exported to
                            confirm the account is gone; a failed restore is exit code 2.
                            Note: with PowerShell module logging enabled, the -Password
                            argument of Register-ScheduledTask could be written to the
                            PowerShell event log (hosted runners do not enable it); don't use
                            this fallback on a machine that logs pipeline execution.
       -Mechanism StartProcess or ScheduledTask forces one (no fallback).
    4. Self-check after every step: the identity file must exist, show the new account's
       SID, a Medium (or Low) integrity level, no Administrators group in the token, and
       IsInRole(Administrator) false. Any violation stops the run with exit code 1 and a
       loud error: results from an elevated child prove nothing about standard users.
    5. Copies every step folder to -OutputDirectory, writes results.json there (and a table
       to $GITHUB_STEP_SUMMARY when set), then - in a finally block - stops the account's
       processes, unregisters the tasks, restores the user rights, deletes the account (by
       name, whenever creation was attempted, even if it failed half-way) and its profile,
       and removes <WorkRoot> (unless -KeepAccount / -KeepWorkRoot).

    Step exit codes are recorded, not judged: build/Test-PrivilegeReport.ps1 validates the
    outputs. Exit codes of this script: 0 = every step ran as a verified standard user;
    1 = SELF-CHECK FAILED (a child was elevated, or ran as another account); 2 = could not
    run (not Windows, not elevated, account or launch setup failed, a step timed out).

    Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Step
    Hashtables: Name (letters, digits, '-', '_'), FilePath, Arguments (one command-line
    string), optional TimeoutMinutes (default 30) and Environment (hashtable). FilePath and
    Arguments may use the tokens {repo} (the copy of -SourcePath), {out} (an empty folder
    for the step's files), {work} (<WorkRoot>), {pwsh} (-PowerShellPath), {powershell}
    (Windows PowerShell 5.1), and {cmd} (cmd.exe).

.PARAMETER SourcePath
    Folder copied to <WorkRoot>\repo. Default: the repository this script belongs to.

.PARAMETER WorkRoot
    Working folder the account can write to. Default: <SystemDrive>\omnidiag-su (short, no
    spaces). Deleted first if it exists.

.PARAMETER OutputDirectory
    Where step folders and results.json are copied. Default: <repo>/test-results/standard-user.

.PARAMETER Mechanism
    Auto (default), StartProcess, or ScheduledTask.

.PARAMETER PowerShellPath
    PowerShell executable for the wrapper and the {pwsh} token. Default: the one running
    this script.

.PARAMETER ShareModule
    Module names to copy (newest installed version) into <WorkRoot>\modules, which is
    prepended to the account's PSModulePath. Example: Pester.

.PARAMETER KeepAccount
    Do not delete the account and its profile (debugging only).

.PARAMETER KeepWorkRoot
    Do not delete <WorkRoot>.

.EXAMPLE
    $steps = @(
        @{ Name = 'version'; FilePath = '{cmd}'; Arguments = '/d /s /c ""{repo}\OmniDiag.cmd" version"' }
    )
    ./build/Invoke-AsStandardUser.ps1 -Step $steps -OutputDirectory test-results/standard-user
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [hashtable[]] $Step,
    [string] $SourcePath,
    [string] $WorkRoot,
    [string] $OutputDirectory,
    [ValidateSet('Auto', 'StartProcess', 'ScheduledTask')] [string] $Mechanism = 'Auto',
    [string] $PowerShellPath,
    [string[]] $ShareModule = @(),
    [switch] $KeepAccount,
    [switch] $KeepWorkRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $SourcePath) { $SourcePath = $repoRoot }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot (Join-Path 'test-results' 'standard-user') }
if (-not $PowerShellPath) { $PowerShellPath = (Get-Process -Id $PID).Path }
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Step { param([string] $Message) Write-Host "[standard-user] $Message" }

# --- Preconditions -------------------------------------------------------------------
$onWindows = $true
try { if ($IsWindows -eq $false) { $onWindows = $false } } catch { $onWindows = $true }
if (-not $onWindows) { Write-Host 'Invoke-AsStandardUser: Windows only.'; exit 2 }
$me = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Invoke-AsStandardUser: must run elevated (it creates and deletes a local account).'; exit 2
}
if (-not $WorkRoot) { $WorkRoot = Join-Path ($env:SystemDrive + '\') 'omnidiag-su' }
$names = @{}
foreach ($s in $Step) {
    foreach ($key in @('Name', 'FilePath', 'Arguments')) {
        if (-not $s.Contains($key)) { Write-Host "Invoke-AsStandardUser: every -Step needs $key."; exit 2 }
    }
    if ([string]$s.Name -notmatch '^[A-Za-z0-9_-]+$' -or [string]$s.Name -like 'probe*') { Write-Host "Invoke-AsStandardUser: invalid step name '$($s.Name)'."; exit 2 }
    if ($names.ContainsKey([string]$s.Name)) { Write-Host "Invoke-AsStandardUser: duplicate step name '$($s.Name)'."; exit 2 }
    $names[[string]$s.Name] = $true
}

# --- Helpers -------------------------------------------------------------------------
function Get-RandomSecret {
    # 32 characters with every class present; built straight into a SecureString.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-=?@^_')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = [byte[]]::new(4)
    $pick = {
        param([int] $Max)
        $rng.GetBytes($buf)
        return [int]([System.BitConverter]::ToUInt32($buf, 0) % [uint32]$Max)
    }
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[(& $pick $set.Length)]) }
    while ($chars.Count -lt 32) { $chars.Add($all[(& $pick $all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = & $pick ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    $secure = [System.Security.SecureString]::new()
    foreach ($c in $chars) { $secure.AppendChar($c) }
    $chars.Clear()
    $rng.Dispose()
    $secure.MakeReadOnly()
    return $secure
}

function Get-GroupName {
    param([string] $Sid)
    $account = ([System.Security.Principal.SecurityIdentifier]::new($Sid)).Translate([System.Security.Principal.NTAccount]).Value
    return ($account -split '\\')[-1]
}

function Test-LocalGroupMember {
    param([string] $GroupSid, [string] $Name)
    $group = [ADSI]("WinNT://$env:COMPUTERNAME/$(Get-GroupName $GroupSid),group")
    return [bool]$group.psbase.Invoke('IsMember', "WinNT://$env:COMPUTERNAME/$Name")
}

function Add-StandardAccount {
    param([string] $Name, [System.Security.SecureString] $Secret)
    $description = 'OmniDiag CI standard-user leg (temporary)'
    $created = $false
    if (Get-Command New-LocalUser -ErrorAction SilentlyContinue) {
        try {
            New-LocalUser -Name $Name -Password $Secret -Description $description -PasswordNeverExpires `
                -UserMayNotChangePassword -AccountNeverExpires -ErrorAction Stop | Out-Null
            $created = $true
            Write-Step 'Account created with New-LocalUser.'
        } catch {
            Write-Step "New-LocalUser failed ($($_.Exception.Message)); falling back to ADSI."
        }
    }
    if (-not $created) {
        $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
        $user = $computer.Create('User', $Name)
        # [void]: adapted ADSI methods return $null, which would otherwise leak into this
        # function's output and turn the returned SID into an array.
        [void]$user.SetPassword([System.Net.NetworkCredential]::new('', $Secret).Password)
        [void]$user.Put('Description', $description)
        [void]$user.SetInfo()
        Write-Step 'Account created with ADSI (WinNT provider).'
    }
    if (-not (Test-LocalGroupMember -GroupSid 'S-1-5-32-545' -Name $Name)) {
        $users = [ADSI]("WinNT://$env:COMPUTERNAME/$(Get-GroupName 'S-1-5-32-545'),group")
        [void]$users.psbase.Invoke('Add', "WinNT://$env:COMPUTERNAME/$Name,user")
    }
    if (Test-LocalGroupMember -GroupSid 'S-1-5-32-544' -Name $Name) {
        throw "The account '$Name' is a member of Administrators; refusing to continue."
    }
    $sid = ([System.Security.Principal.NTAccount]::new($env:COMPUTERNAME, $Name)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    return $sid
}

function Unregister-StandardAccount {
    param([string] $Name, [string] $Sid)
    try {
        Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
            Where-Object { $_.UserName -and ($_.UserName -split '\\')[-1] -eq $Name } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { Write-Step "Could not stop the account's processes: $($_.Exception.Message)" }
    try {
        $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
        [void]$computer.Delete('User', $Name)
        Write-Step 'Account deleted.'
    } catch { Write-Step "Could not delete the account: $($_.Exception.Message)" }
    if ($Sid) {
        try {
            Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue |
                Remove-CimInstance -ErrorAction Stop
        } catch { Write-Step "Could not delete the account's profile: $($_.Exception.Message)" }
    }
}

function Invoke-Native {
    param([string] $FilePath, [string[]] $ArgumentList)
    # 'Continue': on Windows PowerShell 5.1, stderr redirected under 'Stop' throws.
    $ErrorActionPreference = 'Continue'
    $output = & $FilePath @ArgumentList 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
}

function Clear-Tree {
    # Deletes a folder the standard account could write to. 'rmdir /s /q' removes junctions and
    # symbolic links without following them (Remove-Item -Recurse can follow them on 5.1).
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    # cmd.exe would interpret & ^ % and quotes in the path: refuse anything outside a plain set.
    if ($Path -notmatch '^[A-Za-z]:\\[\w .\\-]*$') { throw "Refusing to delete '$Path' with cmd rmdir: unexpected characters in the path." }
    $r = Invoke-Native (Join-Path $env:SystemRoot 'System32\cmd.exe') @('/d', '/c', 'rmdir', '/s', '/q', $Path)
    if (Test-Path -LiteralPath $Path) { throw "Could not delete '$Path' (rmdir exit $($r.ExitCode)): $($r.Output)" }
}

function Copy-TreeNoReparse {
    # Copies a folder the standard account wrote, skipping junctions and symbolic links (/XJ).
    param([string] $Source, [string] $Destination)
    $r = Invoke-Native (Join-Path $env:SystemRoot 'System32\robocopy.exe') @($Source, $Destination, '/E', '/XJ', '/R:0', '/W:0', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XD', (Join-Path $Source 'temp'))
    # robocopy: 0-7 = success (files copied / extra / mismatched), 8+ = failure.
    if ($r.ExitCode -ge 8) { throw "robocopy '$Source' failed ($($r.ExitCode)): $($r.Output)" }
}

function Grant-BatchLogonRight {
    # Adds the SID to SeBatchLogonRight with secedit; returns the exported original policy.
    param([string] $Sid, [string] $Folder)
    $null = New-Item -ItemType Directory -Path $Folder -Force
    $before = Join-Path $Folder 'user-rights-before.inf'
    $after = Join-Path $Folder 'user-rights-after.inf'
    $r = Invoke-Native 'secedit.exe' @('/export', '/cfg', $before, '/areas', 'USER_RIGHTS', '/quiet')
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $before)) { throw "secedit /export failed ($($r.ExitCode)): $($r.Output)" }
    $original = ''
    foreach ($line in @(Get-Content -LiteralPath $before -Encoding Unicode)) {
        if ($line -match '^\s*SeBatchLogonRight\s*=(.*)$') { $original = $Matches[1].Trim() }
    }
    # The restore file names SeBatchLogonRight explicitly - with the original holders, or
    # empty when nobody held it - so re-applying it really removes the grant.
    $restore = Join-Path $Folder 'user-rights-restore.inf'
    Write-BatchRightInf -Path $restore -Value $original
    $granted = "*$Sid"
    if ($original) { $granted = "$original,*$Sid" }
    Write-BatchRightInf -Path $after -Value $granted
    $r = Invoke-Native 'secedit.exe' @('/configure', '/db', (Join-Path $Folder 'grant.sdb'), '/cfg', $after, '/areas', 'USER_RIGHTS', '/quiet')
    if ($r.ExitCode -ne 0) { throw "secedit /configure failed ($($r.ExitCode)): $($r.Output)" }
    Write-Step 'Granted SeBatchLogonRight to the account (secedit).'
    return [pscustomobject]@{ RestoreInf = $restore; Sid = $Sid }
}

function Write-BatchRightInf {
    # A minimal security template that sets only SeBatchLogonRight.
    param([string] $Path, [string] $Value)
    $text = @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1', '[Privilege Rights]', "SeBatchLogonRight = $Value")
    Set-Content -LiteralPath $Path -Value $text -Encoding Unicode
}

function Restore-UserRight {
    # Re-applies the original SeBatchLogonRight holders and verifies the account is gone from
    # it. Returns $true on success; the caller turns $false into exit code 2.
    param($Backup, [string] $Folder)
    if (-not $Backup) { return $true }
    $r = Invoke-Native 'secedit.exe' @('/configure', '/db', (Join-Path $Folder 'restore.sdb'), '/cfg', $Backup.RestoreInf, '/areas', 'USER_RIGHTS', '/quiet')
    if ($r.ExitCode -ne 0) { Write-Host "::error::secedit restore of SeBatchLogonRight returned $($r.ExitCode): $($r.Output)"; return $false }
    $check = Join-Path $Folder 'user-rights-check.inf'
    $null = Invoke-Native 'secedit.exe' @('/export', '/cfg', $check, '/areas', 'USER_RIGHTS', '/quiet')
    $still = (Test-Path -LiteralPath $check) -and
        (@(Get-Content -LiteralPath $check -Encoding Unicode | Where-Object { $_ -match '^\s*SeBatchLogonRight\s*=' -and $_ -match [regex]::Escape($Backup.Sid) }).Count -gt 0)
    if ($still) { Write-Host '::error::SeBatchLogonRight still lists the temporary account after the restore.'; return $false }
    Write-Step 'Restored the previous SeBatchLogonRight holders.'
    return $true
}

# The wrapper the account runs. It never receives the password; it only reads its spec.
$wrapperText = @'
param([Parameter(Mandatory)] [string] $SpecPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$spec = [System.IO.File]::ReadAllText($SpecPath) | ConvertFrom-Json
$code = 98
try {
    # --- Identity self-check, before anything else runs -----------------------------
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdminRole = ([System.Security.Principal.WindowsPrincipal]::new($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    $ErrorActionPreference = 'Continue'   # native stderr must not throw on Windows PowerShell 5.1
    $csv = @(& "$env:SystemRoot\System32\whoami.exe" /groups /fo csv /nh 2>$null)
    $groups = @($csv | Where-Object { $_ } | ConvertFrom-Csv -Header 'Name', 'Type', 'Sid', 'Attributes')
    $label = @($groups | Where-Object { $_.Sid -like 'S-1-16-*' } | Select-Object -First 1)
    $integritySid = if ($label.Count -gt 0) { [string]$label[0].Sid } else { '' }
    $integrity = switch ($integritySid) {
        'S-1-16-0' { 'Untrusted' } 'S-1-16-4096' { 'Low' } 'S-1-16-8192' { 'Medium' } 'S-1-16-8448' { 'MediumPlus' }
        'S-1-16-12288' { 'High' } 'S-1-16-16384' { 'System' } default { 'Unknown' }
    }
    $adminsPresent = @($groups | Where-Object { $_.Sid -eq 'S-1-5-32-544' }).Count -gt 0
    $elevated = $isAdminRole -or $adminsPresent -or ($integrity -in @('High', 'System', 'Unknown'))
    $identity = [ordered]@{
        user                      = $id.Name
        userSid                   = $id.User.Value
        isAdministratorRole       = $isAdminRole
        administratorsGroupPresent = $adminsPresent
        integritySid              = $integritySid
        integrityLevel            = $integrity
        elevated                  = $elevated
        powershell                = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    }
    [System.IO.File]::WriteAllText($spec.IdentityJsonPath, ($identity | ConvertTo-Json), $utf8)
    $whoami = (& "$env:SystemRoot\System32\whoami.exe" /user /groups /priv 2>&1 | Out-String)
    $ErrorActionPreference = 'Stop'
    [System.IO.File]::WriteAllText($spec.IdentityTextPath, $whoami, $utf8)
    if ($elevated) {
        [System.IO.File]::WriteAllText($spec.StderrPath, "REFUSED: this process is elevated (integrity $integrity, Administrators present: $adminsPresent, IsInRole(Administrator): $isAdminRole).", $utf8)
        $code = 97
        return
    }

    # --- Environment -------------------------------------------------------------------
    # Start-Process -Credential can hand down the runner account's environment; point the
    # per-user variables at this account (known folders come from its own token/profile).
    $parts = $id.Name -split '\\', 2
    $profileDir = [System.Environment]::GetFolderPath('UserProfile')
    $own = [ordered]@{
        USERNAME     = $parts[-1]
        USERDOMAIN   = $parts[0]
        USERPROFILE  = $profileDir
        APPDATA      = [System.Environment]::GetFolderPath('ApplicationData')
        LOCALAPPDATA = [System.Environment]::GetFolderPath('LocalApplicationData')
    }
    if ($profileDir -and $profileDir.Length -gt 2) { $own['HOMEDRIVE'] = $profileDir.Substring(0, 2); $own['HOMEPATH'] = $profileDir.Substring(2) }
    foreach ($k in $own.Keys) { if ($own[$k]) { [System.Environment]::SetEnvironmentVariable($k, [string]$own[$k], 'Process') } }
    # Writable temp/cache in the step folder, plus anything the step asked for.
    foreach ($p in @($spec.Environment.PSObject.Properties)) { [System.Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process') }
    # Keep only module folders this account can list (the runner's own are not readable),
    # with the shared modules first.
    $readable = @(($env:PSModulePath -split ';') | Where-Object { $_ } | Where-Object {
            $dir = $_
            try { [void][System.IO.Directory]::GetDirectories($dir); $true } catch { $false }
        })
    if ($spec.ModulePath) { $readable = @($spec.ModulePath) + $readable }
    $env:PSModulePath = ($readable | Select-Object -Unique) -join ';'

    # --- Payload ---------------------------------------------------------------------
    $psi = [System.Diagnostics.ProcessStartInfo]::new($spec.FilePath, $spec.Arguments)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $spec.WorkingDirectory
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($proc.WaitForExit([int]$spec.TimeoutSeconds * 1000)) {
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } else {
        $ErrorActionPreference = 'Continue'
        & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.Id /T /F 2>&1 | Out-Null
        $ErrorActionPreference = 'Stop'
        $code = 124
    }
    [void]$outTask.Wait(30000); [void]$errTask.Wait(30000)
    $stdout = if ($outTask.IsCompleted) { $outTask.Result } else { '' }
    $stderr = if ($errTask.IsCompleted) { $errTask.Result } else { '' }
    if ($code -eq 124) { $stderr += "`nTIMEOUT: killed after $($spec.TimeoutSeconds) s." }
    [System.IO.File]::WriteAllText($spec.StdoutPath, $stdout, $utf8)
    [System.IO.File]::WriteAllText($spec.StderrPath, $stderr, $utf8)
} catch {
    $code = 98
    try { [System.IO.File]::AppendAllText($spec.StderrPath, "WRAPPER ERROR: $($_.Exception.Message)`n", $utf8) } catch { $code = 98 }
} finally {
    # Exit code last, atomically: its presence tells the parent the step is over.
    $tmp = "$($spec.ExitCodePath).tmp"
    [System.IO.File]::WriteAllText($tmp, [string]$code, $utf8)
    Move-Item -LiteralPath $tmp -Destination $spec.ExitCodePath -Force
}
exit $code
'@

# --- State shared with the finally block ---------------------------------------------
$accountName = 'odsu-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
$accountSid = $null
$accountAttempted = $false
$secret = $null
$taskPath = '\OmniDiagCI\'
$registeredTasks = [System.Collections.Generic.List[string]]::new()
$rightsBackup = $null
$adminScratch = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-su-admin-' + [guid]::NewGuid().ToString('N'))
$results = [System.Collections.Generic.List[object]]::new()
$failedProbes = [System.Collections.Generic.List[object]]::new()
$exitCode = 0
$usedMechanism = $null

function Invoke-WrappedStep {
    # Runs one step through the wrapper with the given mechanism; returns a result object.
    param([hashtable] $Definition, [string] $Via)
    $name = [string]$Definition.Name
    $stepDir = Join-Path (Join-Path $WorkRoot 'steps') $name
    Clear-Tree $stepDir
    $outDir = Join-Path $stepDir 'out'
    $tempDir = Join-Path $stepDir 'temp'
    $null = New-Item -ItemType Directory -Path $outDir -Force
    $null = New-Item -ItemType Directory -Path $tempDir -Force
    $timeoutMinutes = 30
    if ($Definition.Contains('TimeoutMinutes')) { $timeoutMinutes = [double]$Definition.TimeoutMinutes }
    $tokens = [ordered]@{
        '{repo}' = (Join-Path $WorkRoot 'repo'); '{out}' = $outDir; '{work}' = $WorkRoot; '{pwsh}' = $PowerShellPath
        '{powershell}' = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        '{cmd}' = (Join-Path $env:SystemRoot 'System32\cmd.exe')
    }
    $filePath = [string]$Definition.FilePath
    $arguments = [string]$Definition.Arguments
    foreach ($k in $tokens.Keys) { $filePath = $filePath.Replace($k, $tokens[$k]); $arguments = $arguments.Replace($k, $tokens[$k]) }
    $environment = [ordered]@{ TEMP = $tempDir; TMP = $tempDir; PSModuleAnalysisCachePath = (Join-Path $tempDir 'ModuleAnalysisCache')
        POWERSHELL_TELEMETRY_OPTOUT = '1'; POWERSHELL_UPDATECHECK = 'Off' }
    if ($Definition.Contains('Environment') -and $Definition.Environment) {
        foreach ($k in $Definition.Environment.Keys) { $environment[[string]$k] = [string]$Definition.Environment[$k] }
    }
    $modulePath = Join-Path $WorkRoot 'modules'
    $spec = [ordered]@{
        Name             = $name
        FilePath         = $filePath
        Arguments        = $arguments
        WorkingDirectory = (Join-Path $WorkRoot 'repo')
        TimeoutSeconds   = [int]($timeoutMinutes * 60)
        StdoutPath       = (Join-Path $stepDir 'stdout.txt')
        StderrPath       = (Join-Path $stepDir 'stderr.txt')
        IdentityJsonPath = (Join-Path $stepDir 'identity.json')
        IdentityTextPath = (Join-Path $stepDir 'identity.txt')
        ExitCodePath     = (Join-Path $stepDir 'exitcode.txt')
        ModulePath       = $(if (Test-Path -LiteralPath $modulePath) { $modulePath } else { '' })
        Environment      = $environment
    }
    $specPath = Join-Path $stepDir 'spec.json'
    [System.IO.File]::WriteAllText($specPath, ($spec | ConvertTo-Json -Depth 4), $utf8)
    $wrapper = Join-Path $WorkRoot 'run-as-user.ps1'
    $argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapper`" -SpecPath `"$specPath`""
    $credential = [System.Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$accountName", $secret)

    Write-Step "Step '$name' via $Via (timeout $timeoutMinutes min): $filePath $arguments"
    $started = Get-Date
    $deadline = $started.AddSeconds($spec.TimeoutSeconds + 120)
    $launchError = $null
    $proc = $null
    $taskName = $null
    try {
        if ($Via -eq 'StartProcess') {
            $proc = Start-Process -FilePath $PowerShellPath -ArgumentList $argLine -Credential $credential -LoadUserProfile `
                -WorkingDirectory $WorkRoot -PassThru -RedirectStandardOutput (Join-Path $stepDir 'wrapper-stdout.txt') `
                -RedirectStandardError (Join-Path $stepDir 'wrapper-stderr.txt')
        } else {
            $taskName = "OmniDiag-SU-$name-" + ([guid]::NewGuid().ToString('N').Substring(0, 6))
            $action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $argLine -WorkingDirectory $WorkRoot
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($spec.TimeoutSeconds + 300)) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Settings $settings `
                -User "$env:COMPUTERNAME\$accountName" -Password $credential.GetNetworkCredential().Password -RunLevel Limited -Force | Out-Null
            $registeredTasks.Add($taskName)
            Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Out-Null
        }
    } catch {
        $launchError = $_.Exception.Message
    }

    # Wait for the exit-code file (written last by the wrapper).
    $exitFile = $spec.ExitCodePath
    $goneSince = $null
    while (-not $launchError -and -not (Test-Path -LiteralPath $exitFile)) {
        if ((Get-Date) -gt $deadline) { $launchError = 'timed out waiting for the step to finish'; break }
        $alive = $true
        if ($proc) {
            try { $alive = -not $proc.HasExited } catch { $alive = $null -ne (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) }
        } elseif ($taskName) {
            $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
            $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
            # 267009 = SCHED_S_TASK_RUNNING, 267011 = SCHED_S_TASK_HAS_NOT_RUN.
            if ($task -and [string]$task.State -ne 'Running' -and $info -and $info.LastTaskResult -notin @(267009, 267011) -and
                ((Get-Date) - $started).TotalSeconds -gt 15) {
                $alive = $false
                if (-not (Test-Path -LiteralPath $exitFile)) { $launchError = ('scheduled task ended with 0x{0:X8} before the wrapper finished' -f $info.LastTaskResult) }
            }
        }
        if (-not $alive) {
            if (-not $goneSince) { $goneSince = Get-Date }
            elseif (((Get-Date) - $goneSince).TotalSeconds -gt 15) { $launchError = 'the wrapper exited without writing an exit code'; break }
        }
        if ($launchError) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($launchError -and $proc) {
        # Don't leave a hung child holding files in the step folder.
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { Write-Verbose "Child already gone: $($_.Exception.Message)" }
    }
    if ($taskName) {
        if ($launchError) { Stop-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue | Out-Null }
        try { Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop; [void]$registeredTasks.Remove($taskName) } catch { Write-Step "Could not unregister task ${taskName}: $($_.Exception.Message)" }
    }

    $code = $null
    if (Test-Path -LiteralPath $exitFile) { $code = [int]([System.IO.File]::ReadAllText($exitFile).Trim()) }
    $identity = $null
    if (Test-Path -LiteralPath $spec.IdentityJsonPath) { $identity = [System.IO.File]::ReadAllText($spec.IdentityJsonPath) | ConvertFrom-Json }
    return [pscustomobject]@{
        Name        = $name
        Mechanism   = $Via
        ExitCode    = $code
        Seconds     = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        LaunchError = $launchError
        Identity    = $identity
        StepDir     = $stepDir
        OutDir      = $outDir
    }
}

function Assert-NotElevated {
    # The self-check: fails loudly unless the step ran as the new account, non-elevated.
    param($Result)
    $problems = [System.Collections.Generic.List[string]]::new()
    $id = $Result.Identity
    if ($null -eq $id) {
        $problems.Add('no identity record (the wrapper did not start as the account)')
    } else {
        if ([string]$id.userSid -ne $accountSid) { $problems.Add("ran as $($id.user) ($($id.userSid)), not the standard account") }
        if ($id.isAdministratorRole) { $problems.Add('IsInRole(Administrator) is true') }
        if ($id.administratorsGroupPresent) { $problems.Add('the token contains BUILTIN\Administrators (S-1-5-32-544)') }
        if ([string]$id.integrityLevel -notin @('Medium', 'Low', 'MediumPlus')) { $problems.Add("integrity level is $($id.integrityLevel)") }
        if ($id.elevated) { $problems.Add('the wrapper reported itself elevated') }
    }
    if ($Result.ExitCode -eq 97) { $problems.Add('the wrapper refused to run the payload because it was elevated') }
    return @($problems)
}

try {
    # --- 1. Account ------------------------------------------------------------------
    $secret = Get-RandomSecret
    Write-Step "Creating local standard account '$accountName' (Users only; password generated in memory, never shown)."
    # From here on the finally block deletes the account by name, even if creation throws
    # half-way (after the account exists but before its SID is known).
    $accountAttempted = $true
    $accountSid = [string](@(Add-StandardAccount -Name $accountName -Secret $secret) | Where-Object { $_ -is [string] } | Select-Object -Last 1)
    if ($accountSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw "Unexpected SID for the new account: '$accountSid'." }
    Write-Step "Account SID: $accountSid"

    # --- 2. Work root ----------------------------------------------------------------
    # Explicit ACL, no inheritance: C:\ grants Authenticated Users Modify on new folders.
    Clear-Tree $WorkRoot
    $null = New-Item -ItemType Directory -Path $WorkRoot -Force
    $acl = Invoke-Native 'icacls.exe' @($WorkRoot, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', "*$($accountSid):(OI)(CI)M", '/Q')
    if ($acl.ExitCode -ne 0) { throw "icacls failed ($($acl.ExitCode)): $($acl.Output)" }
    Write-Step "Work root $WorkRoot`: SYSTEM and Administrators Full, the account Modify, nothing inherited."
    $null = New-Item -ItemType Directory -Path (Join-Path $WorkRoot 'repo') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $WorkRoot 'steps') -Force
    $skip = @('.git', 'test-results', 'OmniDiagData', 'coverage.xml', 'dist')
    Get-ChildItem -LiteralPath $SourcePath -Force | Where-Object { $_.Name -notin $skip } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path (Join-Path $WorkRoot 'repo') $_.Name) -Recurse -Force
    }
    foreach ($moduleName in $ShareModule) {
        $m = Get-Module -ListAvailable -Name $moduleName | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $m) { throw "Module '$moduleName' is not installed for the runner account; cannot share it." }
        $target = Join-Path (Join-Path (Join-Path $WorkRoot 'modules') $m.Name) ([string]$m.Version)
        $null = New-Item -ItemType Directory -Path $target -Force
        Copy-Item -Path (Join-Path $m.ModuleBase '*') -Destination $target -Recurse -Force
        Write-Step "Shared module $($m.Name) $($m.Version)."
    }
    [System.IO.File]::WriteAllText((Join-Path $WorkRoot 'run-as-user.ps1'), $wrapperText, $utf8)

    # --- 3. Mechanism ----------------------------------------------------------------
    $candidates = @($Mechanism)
    if ($Mechanism -eq 'Auto') { $candidates = @('StartProcess', 'ScheduledTask') }
    foreach ($via in $candidates) {
        if ($via -eq 'ScheduledTask' -and -not $rightsBackup) {
            try { $rightsBackup = Grant-BatchLogonRight -Sid $accountSid -Folder $adminScratch }
            catch { Write-Step "Could not grant SeBatchLogonRight: $($_.Exception.Message)" }
        }
        $probe = @{ Name = "probe-$via"; FilePath = '{cmd}'; Arguments = '/d /c ver'; TimeoutMinutes = 1.5 }
        $p = Invoke-WrappedStep -Definition $probe -Via $via
        if ($p.Identity -or $p.ExitCode -eq 97) {
            # The wrapper started: from here on an elevated child is a hard failure, not a fallback.
            $problems = @(Assert-NotElevated $p)
            if ($problems.Count -gt 0) {
                $results.Add($p); $exitCode = 1
                Write-Host "::error::SELF-CHECK FAILED in the probe via ${via}: $($problems -join '; ')"
                throw 'self-check failed: the child process was elevated or not the standard account'
            }
        }
        if ($p.Identity -and $p.ExitCode -eq 0 -and -not $p.LaunchError) {
            $usedMechanism = $via
            $results.Add($p)
            Write-Step "Mechanism: $via (probe ran as $($p.Identity.user), integrity $($p.Identity.integrityLevel))."
            break
        }
        $failedProbes.Add($p)
        $why = $p.LaunchError
        if (-not $why) { $why = "exit code $($p.ExitCode)" }
        Write-Step "Mechanism $via is not usable here: $why"
        $wrapErr = Join-Path $p.StepDir 'wrapper-stderr.txt'
        if (Test-Path -LiteralPath $wrapErr) { Write-Step ("  wrapper stderr: " + ([System.IO.File]::ReadAllText($wrapErr).Trim())) }
    }
    if (-not $usedMechanism) { throw "no launch mechanism worked (tried: $($candidates -join ', '))." }

    # --- 4. Steps --------------------------------------------------------------------
    foreach ($s in $Step) {
        $r = Invoke-WrappedStep -Definition $s -Via $usedMechanism
        $results.Add($r)
        if ($null -eq $r.Identity -and $r.ExitCode -ne 97) {
            # The wrapper never got as far as its identity record: a launch failure, not a privilege leak.
            Write-Host "::error::Step '$($r.Name)' did not start as the account: $($r.LaunchError)"
            $exitCode = 2
            continue
        }
        $problems = @(Assert-NotElevated $r)
        if ($problems.Count -gt 0) {
            Write-Host "::error::SELF-CHECK FAILED in step '$($r.Name)': $($problems -join '; ')"
            Write-Host 'The child process was not a standard user; its results prove nothing. Stopping.'
            $exitCode = 1
            break
        }
        if ($r.LaunchError) {
            Write-Host "::error::Step '$($r.Name)' did not complete: $($r.LaunchError)"
            $exitCode = 2
            continue
        }
        Write-Step ("Step '{0}' exit code {1} in {2} s as {3} (integrity {4})." -f $r.Name, $r.ExitCode, $r.Seconds, $r.Identity.user, $r.Identity.integrityLevel)
    }
} catch {
    if ($exitCode -eq 0) { $exitCode = 2 }
    Write-Host "::error::Invoke-AsStandardUser: $($_.Exception.Message)"
} finally {
    # --- 5. Outputs, then cleanup ------------------------------------------------------
    try {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
        $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
        foreach ($r in @($results) + @($failedProbes)) {
            if (Test-Path -LiteralPath $r.StepDir) {
                $dest = Join-Path $OutputDirectory $r.Name
                Clear-Tree $dest
                # The account wrote this folder: copy without following junctions/symlinks.
                Copy-TreeNoReparse -Source $r.StepDir -Destination $dest
            }
        }
        $doc = [ordered]@{
            kind        = 'standard-user-run'
            account     = $accountName
            accountSid  = $accountSid
            mechanism   = $usedMechanism
            selfCheck   = $(if ($exitCode -eq 1) { 'FAILED' } elseif ($exitCode -ne 0) { 'incomplete' } elseif ($results.Count -gt 0) { 'passed' } else { 'not run' })
            exitCode    = $exitCode
            failedProbes = @($failedProbes | ForEach-Object { [ordered]@{ name = $_.Name; mechanism = $_.Mechanism; exitCode = $_.ExitCode; launchError = $_.LaunchError; directory = $_.Name } })
            steps       = @($results | ForEach-Object {
                    [ordered]@{
                        name        = $_.Name
                        mechanism   = $_.Mechanism
                        exitCode    = $_.ExitCode
                        seconds     = $_.Seconds
                        launchError = $_.LaunchError
                        identity    = $_.Identity
                        directory   = $_.Name
                        stdout      = (Join-Path $_.Name 'stdout.txt')
                        stderr      = (Join-Path $_.Name 'stderr.txt')
                        out         = (Join-Path $_.Name 'out')
                    }
                })
        }
        [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'results.json'), ($doc | ConvertTo-Json -Depth 6), $utf8)
        $md = [System.Collections.Generic.List[string]]::new()
        $md.Add('### Standard-user run')
        $md.Add('')
        # An empty value inside ** ** renders as '****' (it is not masking): name the missing value.
        $mechanismText = if ($usedMechanism) { $usedMechanism } else { 'none (no launch mechanism worked)' }
        $md.Add(('Account `{0}` (Users only), mechanism **{1}**, self-check **{2}**.' -f $accountName, $mechanismText, $doc.selfCheck))
        $md.Add('')
        $md.Add('| Step | Exit code | Seconds | User | Integrity | Administrators in token | Note |')
        $md.Add('|---|---:|---:|---|---|---|---|')
        foreach ($r in $results) {
            $user = ''; $integrity = ''; $admins = ''
            if ($r.Identity) { $user = $r.Identity.user; $integrity = $r.Identity.integrityLevel; $admins = [string]$r.Identity.administratorsGroupPresent }
            $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $r.Name, $r.ExitCode, $r.Seconds, $user, $integrity, $admins, $r.LaunchError))
        }
        $md.Add('')
        $mdText = $md -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'results.md'), $mdText, $utf8)
        if ($env:GITHUB_STEP_SUMMARY) { [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $mdText + "`n", $utf8) }
        Write-Host $mdText
    } catch {
        Write-Host "Could not write the results: $($_.Exception.Message)"
        if ($exitCode -eq 0) { $exitCode = 2 }
    }

    foreach ($t in @($registeredTasks)) {
        try { Unregister-ScheduledTask -TaskName $t -TaskPath $taskPath -Confirm:$false -ErrorAction Stop } catch { Write-Step "Could not unregister task ${t}: $($_.Exception.Message)" }
    }
    if ($rightsBackup) {
        $restored = $false
        try { $restored = Restore-UserRight -Backup $rightsBackup -Folder $adminScratch } catch { Write-Host "::error::Restoring SeBatchLogonRight failed: $($_.Exception.Message)" }
        if (-not $restored -and $exitCode -eq 0) { $exitCode = 2 }
    }
    if ($KeepAccount) {
        Write-Step "Kept account '$accountName' (-KeepAccount)."
    } elseif ($accountAttempted) {
        # By name: the account may exist even when Add-StandardAccount threw before returning its SID.
        $sidForProfile = $accountSid
        if (-not $sidForProfile) {
            try { $sidForProfile = ([System.Security.Principal.NTAccount]::new($env:COMPUTERNAME, $accountName)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sidForProfile = $null }
        }
        Unregister-StandardAccount -Name $accountName -Sid $sidForProfile
    }
    if (-not $KeepWorkRoot) {
        try { Clear-Tree $WorkRoot } catch { Write-Step "Could not remove ${WorkRoot}: $($_.Exception.Message)" }
    }
    try { Clear-Tree $adminScratch } catch { Write-Step "Could not remove the admin scratch folder: $($_.Exception.Message)" }
    $secret = $null
}

exit $exitCode
