#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests for the 'startup' group persistence scanners (Service Persistence,
    Startup Folders, Scheduled Tasks). Every data source is a private helper inside the
    plugin (Get-OmniPersistenceService, Get-OmniPersistenceRoot, Get-OmniStartupFolderList,
    Get-OmniStartupFolderItem, Resolve-OmniStartupShortcut, Get-OmniStartupUrlTarget,
    Get-OmniScheduledTaskList); the tests mock those helpers inside the plugin's module
    scope, so they run on Linux and Windows alike and cover each finding path.

    The mocks return script-scoped test data set in BeforeEach and changed per test; a
    string value makes the mocked helper throw it (data source unavailable).

    Each plugin is copied to TestDrive under a unique file name so its module name is unique
    for Mock -ModuleName.
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    function Import-PluginCopy {
        param([string] $File, [string] $AsName)
        $dir = Join-Path $TestDrive 'plugins'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $copy = Join-Path $dir "$AsName.psm1"
        Copy-Item -LiteralPath (Join-Path $script:Root "src/Modules/$File") -Destination $copy -Force
        return (Import-Module -Name $copy -Force -PassThru -DisableNameChecking)
    }

    function New-TestContext {
        New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error)
    }

    function Invoke-PluginScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    function Get-FindingById {
        param($Result, [string] $Id)
        return , @($Result.Findings | Where-Object { $_.Id -eq $Id })
    }

    function New-TestService {
        param([string] $Name, [string] $StartMode, [string] $PathName)
        [pscustomobject]@{ Name = $Name; DisplayName = "$Name display"; StartMode = $StartMode; State = 'Running'; PathName = $PathName }
    }

    function New-TestTask {
        param([string] $Path, [string] $Name, [string[]] $Trigger = @(), [string] $Execute = '', [string] $Arguments = '',
            [string] $UserId = 'bob', [string] $State = 'Ready')
        $triggers = @($Trigger | ForEach-Object { [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = $_ } } })
        $actions = if ($Execute) { @([pscustomobject]@{ Execute = $Execute; Arguments = $Arguments }) } else { @() }
        [pscustomobject]@{
            TaskPath = $Path; TaskName = $Name; State = $State
            Principal = [pscustomobject]@{ UserId = $UserId }
            Triggers = $triggers; Actions = $actions
        }
    }

    $script:SpMod = Import-PluginCopy -File 'ServicePersistence.psm1' -AsName 'OmniStartTestServicePersistence'
    $script:SfMod = Import-PluginCopy -File 'StartupFolders.psm1' -AsName 'OmniStartTestStartupFolders'
    $script:StMod = Import-PluginCopy -File 'ScheduledTasks.psm1' -AsName 'OmniStartTestScheduledTasks'
}

AfterAll {
    foreach ($n in @('OmniStartTestServicePersistence', 'OmniStartTestStartupFolders', 'OmniStartTestScheduledTasks')) {
        Remove-Module -Name $n -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Service Persistence scanner' {
    BeforeEach {
        $script:SvcData = @(
            New-TestService 'svchost' 'Auto' 'C:\Windows\system32\svchost.exe -k netsvcs -p'
            New-TestService 'quoted' 'Auto' '"C:\Program Files\Vendor\svc.exe" --run'
            New-TestService 'kernelish' 'Auto' '\SystemRoot\System32\foo.exe'
            New-TestService 'defender' 'Auto' '"C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.1-0\MsMpEng.exe"'
            New-TestService 'relative' 'Auto' 'svc.exe'
        )
        Mock -ModuleName OmniStartTestServicePersistence Get-OmniPersistenceRoot {
            @{ SystemRoot = 'C:\Windows'; ProgramFiles = 'C:\Program Files'; ProgramFilesX86 = 'C:\Program Files (x86)'; ProgramW6432 = 'C:\Program Files'; ProgramData = 'C:\ProgramData' }
        }
        Mock -ModuleName OmniStartTestServicePersistence Get-OmniPersistenceService {
            if ($script:SvcData -is [string]) { throw $script:SvcData }
            $script:SvcData
        }
    }

    It 'passes when every auto-start binary is in a standard location' {
        $r = Invoke-PluginScan -Module $script:SpMod -Context (New-TestContext)
        $r.Metrics['AutoStartServiceCount'] | Should -Be 5
        $r.Metrics['UserWritableServiceCount'] | Should -Be 0
        $r.Metrics['NonStandardLocationServiceCount'] | Should -Be 0
        $r.Metrics['UnquotedServicePathCount'] | Should -Be 0
        (Get-FindingById $r 'service-persistence-summary')[0].Severity | Should -Be 'Information'
        (Get-FindingById $r 'service-persistence-ok').Count | Should -Be 1
    }

    It 'flags user-writable, non-standard, and unquoted service paths' {
        $script:SvcData = @(
            New-TestService 'svchost' 'Auto' 'C:\Windows\system32\svchost.exe -k netsvcs -p'
            New-TestService 'appdata' 'Auto' '"C:\Users\bob\AppData\Roaming\x\evil.exe"'
            New-TestService 'pdroot' 'Auto' 'C:\ProgramData\evil.exe'
            New-TestService 'temp' 'Auto' 'C:\Windows\Temp\t.exe /svc'
            New-TestService 'custom' 'Auto' 'D:\Apps\agent.exe -service'
            New-TestService 'unq' 'Manual' 'C:\Program Files\Bad Vendor\svc.exe -x'
            New-TestService 'disabledunq' 'Disabled' 'C:\Program Files\X Y\a.exe'
        )
        $r = Invoke-PluginScan -Module $script:SpMod -Context (New-TestContext)
        $r.Metrics['AutoStartServiceCount'] | Should -Be 5
        $r.Metrics['UserWritableServiceCount'] | Should -Be 3
        $r.Metrics['NonStandardLocationServiceCount'] | Should -Be 1
        $r.Metrics['UnquotedServicePathCount'] | Should -Be 1

        $uw = Get-FindingById $r 'service-persistence-user-writable'
        $uw[0].Severity | Should -Be 'Warning'
        $uw[0].Detail | Should -Match ([regex]::Escape('C:\Users\bob\AppData\Roaming\x\evil.exe'))
        $uw[0].Detail | Should -Match ([regex]::Escape('C:\ProgramData\evil.exe'))
        $uw[0].Detail | Should -Match ([regex]::Escape('C:\Windows\Temp\t.exe'))

        $ns = Get-FindingById $r 'service-persistence-nonstandard-location'
        $ns[0].Severity | Should -Be 'Information'
        $ns[0].Detail | Should -Match ([regex]::Escape('D:\Apps\agent.exe'))

        $uq = Get-FindingById $r 'service-persistence-unquoted-path'
        $uq[0].Severity | Should -Be 'Warning'
        $uq[0].Detail | Should -Match 'unq display'
        $uq[0].Detail | Should -Not -Match 'disabledunq'
        (Get-FindingById $r 'service-persistence-ok').Count | Should -Be 0
    }

    It 'reports a custom install folder as Information and still passes' {
        $script:SvcData = @(
            New-TestService 'svchost' 'Auto' 'C:\Windows\system32\svchost.exe -k netsvcs -p'
            New-TestService 'custom' 'Auto' '"D:\Apps\agent.exe" -service'
        )
        $r = Invoke-PluginScan -Module $script:SpMod -Context (New-TestContext)
        (Get-FindingById $r 'service-persistence-nonstandard-location')[0].Severity | Should -Be 'Information'
        (Get-FindingById $r 'service-persistence-ok').Count | Should -Be 1
    }

    It 'parses quoted, unquoted, and prefixed PathName values' {
        $p = & $script:SpMod { ConvertFrom-OmniServicePathName -PathName '"C:\Program Files\A B\x.exe" -arg' -SystemRoot 'C:\Windows' }
        $p.Image | Should -Be 'C:\Program Files\A B\x.exe'
        $p.Quoted | Should -BeTrue
        $p.UnquotedWithSpace | Should -BeFalse
        $p = & $script:SpMod { ConvertFrom-OmniServicePathName -PathName 'C:\Program Files\A B\x.exe -arg "q"' -SystemRoot 'C:\Windows' }
        $p.Image | Should -Be 'C:\Program Files\A B\x.exe'
        $p.UnquotedWithSpace | Should -BeTrue
        $p = & $script:SpMod { ConvertFrom-OmniServicePathName -PathName '\SystemRoot\System32\drivers\x.sys' -SystemRoot 'C:\Windows' }
        $p.Image | Should -Be 'C:\Windows\System32\drivers\x.sys'
        $p = & $script:SpMod { ConvertFrom-OmniServicePathName -PathName '\??\C:\Tools\y.exe' -SystemRoot 'C:\Windows' }
        $p.Image | Should -Be 'C:\Tools\y.exe'
        $p = & $script:SpMod { ConvertFrom-OmniServicePathName -PathName 'C:\Windows\system32\svchost.exe -k LocalService' -SystemRoot 'C:\Windows' }
        $p.UnquotedWithSpace | Should -BeFalse
    }

    It 'is skipped with an Information finding when Win32_Service is unavailable' {
        $script:SvcData = 'no CIM'
        $r = Invoke-PluginScan -Module $script:SpMod -Context (New-TestContext)
        $r.Status | Should -Be 'Skipped'
        (Get-FindingById $r 'service-persistence-unavailable')[0].Severity | Should -Be 'Information'
    }
}

Describe 'Startup Folders scanner' {
    BeforeEach {
        $script:Folders = @(
            [pscustomobject]@{ Scope = 'CurrentUser'; Path = 'C:\Users\bob\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' }
            [pscustomobject]@{ Scope = 'AllUsers'; Path = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp' }
        )
        $script:Items = @{
            CurrentUser = @()
            AllUsers    = @([pscustomobject]@{ Name = 'Vendor.lnk'; FullName = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Vendor.lnk'; Extension = '.lnk' })
        }
        $script:Links = @{
            'Vendor.lnk' = [pscustomobject]@{ Target = 'C:\Program Files\Vendor\v.exe'; Arguments = '/tray' }
        }
        Mock -ModuleName OmniStartTestStartupFolders New-OmniStartupShell { [pscustomobject]@{ FakeShell = $true } }
        Mock -ModuleName OmniStartTestStartupFolders Get-OmniStartupFolderList { $script:Folders }
        Mock -ModuleName OmniStartTestStartupFolders Get-OmniStartupFolderItem {
            $scope = if ($Path -like 'C:\Users\*') { 'CurrentUser' } else { 'AllUsers' }
            $script:Items[$scope]
        }
        Mock -ModuleName OmniStartTestStartupFolders Resolve-OmniStartupShortcut {
            $leaf = ($Path -split '\\')[-1]
            if ($script:Links.ContainsKey($leaf)) { $script:Links[$leaf] } else { $null }
        }
        Mock -ModuleName OmniStartTestStartupFolders Get-OmniStartupUrlTarget { 'https://intranet.example/' }
    }

    It 'lists entries and passes when nothing is risky' {
        $r = Invoke-PluginScan -Module $script:SfMod -Context (New-TestContext)
        $r.Metrics['StartupFolderEntryCount'] | Should -Be 1
        $s = Get-FindingById $r 'startup-folders-summary'
        $s[0].Severity | Should -Be 'Information'
        $s[0].Detail | Should -Match ([regex]::Escape('[AllUsers] Vendor.lnk -> C:\Program Files\Vendor\v.exe /tray'))
        (Get-FindingById $r 'startup-folders-ok').Count | Should -Be 1
    }

    It 'flags user-writable targets, script hosts, and files placed directly in the folder' {
        $userDir = 'C:\Users\bob\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        $script:Items['CurrentUser'] = @(
            [pscustomobject]@{ Name = 'App.lnk'; FullName = "$userDir\App.lnk"; Extension = '.lnk' }
            [pscustomobject]@{ Name = 'run.bat'; FullName = "$userDir\run.bat"; Extension = '.bat' }
            [pscustomobject]@{ Name = 'site.url'; FullName = "$userDir\site.url"; Extension = '.url' }
            [pscustomobject]@{ Name = 'ps.lnk'; FullName = "$userDir\ps.lnk"; Extension = '.lnk' }
            [pscustomobject]@{ Name = 'ok.lnk'; FullName = "$userDir\ok.lnk"; Extension = '.lnk' }
        )
        $script:Links['App.lnk'] = [pscustomobject]@{ Target = 'C:\Users\bob\AppData\Local\App\app.exe'; Arguments = '' }
        $script:Links['ps.lnk'] = [pscustomobject]@{ Target = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; Arguments = '-NoP -w hidden -enc SQBFAFgA' }
        $script:Links['ok.lnk'] = [pscustomobject]@{ Target = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; Arguments = '-ExecutionPolicy Bypass -File C:\Scripts\x.ps1' }
        $r = Invoke-PluginScan -Module $script:SfMod -Context (New-TestContext)
        $r.Metrics['StartupFolderEntryCount'] | Should -Be 6
        $r.Metrics['SuspiciousStartupFolderEntryCount'] | Should -Be 2
        $r.Metrics['UserWritableStartupFolderEntryCount'] | Should -Be 1
        $i = Get-FindingById $r 'startup-folders-user-writable-target'
        $i[0].Severity | Should -Be 'Information'
        $i[0].Detail | Should -Match 'App\.lnk'
        $w = Get-FindingById $r 'startup-folders-suspicious-entry'
        $w[0].Severity | Should -Be 'Warning'
        $w[0].Detail | Should -Not -Match 'App\.lnk'
        $w[0].Detail | Should -Match 'run\.bat .*placed directly'
        $w[0].Detail | Should -Match 'ps\.lnk .*encoded command'
        $w[0].Detail | Should -Not -Match 'ok\.lnk'
        $w[0].Detail | Should -Not -Match 'site\.url'
        (Get-FindingById $r 'startup-folders-ok').Count | Should -Be 0
    }

    It 'treats a per-user install under LOCALAPPDATA\Programs as Information and still passes' {
        $userDir = 'C:\Users\bob\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        $script:Items['CurrentUser'] = @([pscustomobject]@{ Name = 'Chat.lnk'; FullName = "$userDir\Chat.lnk"; Extension = '.lnk' })
        $script:Links['Chat.lnk'] = [pscustomobject]@{ Target = 'C:\Users\bob\AppData\Local\Programs\Chat\chat.exe'; Arguments = '--minimized' }
        $r = Invoke-PluginScan -Module $script:SfMod -Context (New-TestContext)
        (Get-FindingById $r 'startup-folders-user-writable-target')[0].Severity | Should -Be 'Information'
        (Get-FindingById $r 'startup-folders-suspicious-entry').Count | Should -Be 0
        (Get-FindingById $r 'startup-folders-ok').Count | Should -Be 1
    }

    It 'warns when a user-writable target also uses a script host' {
        $userDir = 'C:\Users\bob\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        $script:Items['CurrentUser'] = @([pscustomobject]@{ Name = 'Ws.lnk'; FullName = "$userDir\Ws.lnk"; Extension = '.lnk' })
        $script:Links['Ws.lnk'] = [pscustomobject]@{ Target = 'C:\Users\bob\AppData\Local\Temp\wscript.exe'; Arguments = 'a.vbs' }
        $r = Invoke-PluginScan -Module $script:SfMod -Context (New-TestContext)
        $w = Get-FindingById $r 'startup-folders-suspicious-entry'
        $w[0].Severity | Should -Be 'Warning'
        $w[0].Detail | Should -Match 'Ws\.lnk .*user-writable.*Windows Script Host'
        (Get-FindingById $r 'startup-folders-user-writable-target').Count | Should -Be 0
    }

    It 'creates one WScript.Shell per scan' {
        $userDir = 'C:\Users\bob\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        $script:Items['CurrentUser'] = @(
            [pscustomobject]@{ Name = 'a.lnk'; FullName = "$userDir\a.lnk"; Extension = '.lnk' }
            [pscustomobject]@{ Name = 'b.lnk'; FullName = "$userDir\b.lnk"; Extension = '.lnk' }
        )
        $null = Invoke-PluginScan -Module $script:SfMod -Context (New-TestContext)
        Should -Invoke -ModuleName OmniStartTestStartupFolders New-OmniStartupShell -Times 1 -Exactly
        Should -Invoke -ModuleName OmniStartTestStartupFolders Resolve-OmniStartupShortcut -Times 3 -Exactly
    }

    It 'reports shortcuts it cannot resolve (no WScript.Shell)' {
        $script:Links = @{}
        $r = Invoke-PluginScan -Module $script:SfMod -Context (New-TestContext)
        $s = Get-FindingById $r 'startup-folders-summary'
        $s[0].Detail | Should -Match 'target not resolved'
        $s[0].Detail | Should -Match 'could not be resolved'
    }

    It 'says the folders are empty' {
        $script:Items['AllUsers'] = @()
        $r = Invoke-PluginScan -Module $script:SfMod -Context (New-TestContext)
        (Get-FindingById $r 'startup-folders-summary')[0].Detail | Should -Match 'empty'
        (Get-FindingById $r 'startup-folders-ok').Count | Should -Be 1
    }

    It 'is skipped with an Information finding when no Startup folder is defined' {
        $script:Folders = @()
        $r = Invoke-PluginScan -Module $script:SfMod -Context (New-TestContext)
        $r.Status | Should -Be 'Skipped'
        (Get-FindingById $r 'startup-folders-unavailable')[0].Severity | Should -Be 'Information'
    }
}

Describe 'Scheduled Tasks scanner' {
    BeforeEach {
        $script:Tasks = @(
            New-TestTask -Path '\Microsoft\Windows\Foo\' -Name 'MsLogon' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'mshta.exe' -Arguments 'x.hta'
            New-TestTask -Path '\' -Name 'Updater' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Program Files\Vendor\upd.exe' -Arguments '/silent'
            New-TestTask -Path '\' -Name 'Daily' -Trigger 'MSFT_TaskDailyTrigger' -Execute 'mshta.exe' -Arguments 'http://example.invalid/a.hta'
        )
        Mock -ModuleName OmniStartTestScheduledTasks Get-OmniScheduledTaskList {
            if ($script:Tasks -is [string]) { throw $script:Tasks }
            $script:Tasks
        }
    }

    It 'lists third-party logon/boot tasks with their actions and passes when none is risky' {
        $r = Invoke-PluginScan -Module $script:StMod -Context (New-TestContext)
        $r.Metrics['EnabledTaskCount'] | Should -Be 3
        $r.Metrics['ThirdPartyTaskCount'] | Should -Be 2
        $r.Metrics['LogonBootTaskCount'] | Should -Be 1
        $r.Metrics['SuspiciousTaskCount'] | Should -Be 0
        $f = Get-FindingById $r 'scheduled-tasks-logon-boot'
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match ([regex]::Escape('\Updater [Logon] -> C:\Program Files\Vendor\upd.exe /silent'))
        $f[0].Detail | Should -Not -Match 'MsLogon'
        $f[0].Detail | Should -Not -Match 'Daily'
        (Get-FindingById $r 'scheduled-tasks-ok').Count | Should -Be 1
    }

    It 'flags user-writable and script-host actions in logon/boot tasks' {
        $script:Tasks = @(
            New-TestTask -Path '\' -Name 'Updater' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Program Files\Vendor\upd.exe'
            New-TestTask -Path '\' -Name 'Enc' -Trigger 'MSFT_TaskBootTrigger' -Execute 'powershell.exe' -Arguments '-w hidden -EncodedCommand SQBFAFgA'
            New-TestTask -Path '\' -Name 'AppData' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Users\bob\AppData\Local\x\a.exe'
            New-TestTask -Path '\' -Name 'Js' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'rundll32.exe' -Arguments 'javascript:"\..\mshtml,RunHTMLApplication"'
            New-TestTask -Path '\' -Name 'Vbs' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Windows\System32\wscript.exe' -Arguments 'C:\Scripts\a.vbs'
            New-TestTask -Path '\' -Name 'PsFile' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'powershell.exe' -Arguments '-ExecutionPolicy Bypass -File C:\Scripts\x.ps1'
            New-TestTask -Path '\' -Name 'Off' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'mshta.exe' -State 'Disabled'
        )
        $r = Invoke-PluginScan -Module $script:StMod -Context (New-TestContext)
        $r.Metrics['EnabledTaskCount'] | Should -Be 6
        $r.Metrics['LogonBootTaskCount'] | Should -Be 6
        $r.Metrics['SuspiciousTaskCount'] | Should -Be 3
        $r.Metrics['UserWritableTaskCount'] | Should -Be 1
        $i = Get-FindingById $r 'scheduled-tasks-user-writable-action'
        $i[0].Severity | Should -Be 'Information'
        $i[0].Detail | Should -Match '\\AppData \[Logon\]'
        $w = Get-FindingById $r 'scheduled-tasks-suspicious-action'
        $w[0].Severity | Should -Be 'Warning'
        $w[0].Detail | Should -Match '\\Enc \[Boot\].*PowerShell encoded command'
        $w[0].Detail | Should -Not -Match '\\AppData'
        $w[0].Detail | Should -Match '\\Js \[Logon\].*rundll32'
        $w[0].Detail | Should -Match '\\Vbs \[Logon\].*Windows Script Host'
        $w[0].Detail | Should -Not -Match 'PsFile'
        $w[0].Detail | Should -Not -Match '\\Off'
        $w[0].Detail | Should -Not -Match 'Updater'
    }

    It 'lists third-party tasks that run as SYSTEM at logon as Information' {
        $script:Tasks = @(New-TestTask -Path '\Vendor\' -Name 'Agent' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Program Files\V\s.exe' -UserId 'SYSTEM')
        $r = Invoke-PluginScan -Module $script:StMod -Context (New-TestContext)
        $f = Get-FindingById $r 'scheduled-tasks-system-at-logon'
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match ([regex]::Escape('\Vendor\Agent'))
        (Get-FindingById $r 'scheduled-tasks-ok').Count | Should -Be 1
    }

    It 'warns on a SYSTEM logon task whose action is in a user-writable location' {
        $script:Tasks = @(
            New-TestTask -Path '\' -Name 'Sys1' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Users\Public\x.exe' -UserId 'NT AUTHORITY\SYSTEM'
            New-TestTask -Path '\' -Name 'Sys2' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Program Files\V\s.exe' -UserId 'S-1-5-18'
        )
        $r = Invoke-PluginScan -Module $script:StMod -Context (New-TestContext)
        $r.Metrics['SystemAtLogonTaskCount'] | Should -Be 2
        $f = Get-FindingById $r 'scheduled-tasks-system-at-logon'
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Detail | Should -Match '\\Sys1 \(action in a user-writable location'
        $f[0].Detail | Should -Match '\\Sys2'
    }

    It 'matches the SYSTEM principal exactly, not as a substring' {
        $script:Tasks = @(New-TestTask -Path '\' -Name 'Svc' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Program Files\V\s.exe' -UserId 'CONTOSO\systemadmin')
        $r = Invoke-PluginScan -Module $script:StMod -Context (New-TestContext)
        (Get-FindingById $r 'scheduled-tasks-system-at-logon').Count | Should -Be 0
    }

    It 'keeps known vendor updaters in the logon/boot listing only' {
        $script:Tasks = @(
            New-TestTask -Path '\' -Name 'MicrosoftEdgeUpdateTaskMachineCore{A1B2}' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe' -Arguments '/c' -UserId 'SYSTEM'
            New-TestTask -Path '\' -Name 'GoogleUpdateTaskMachineCore' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Program Files (x86)\Google\Update\GoogleUpdate.exe' -Arguments '/c' -UserId 'SYSTEM'
            New-TestTask -Path '\' -Name 'OneDrive Standalone Update Task-S-1-5-21-1' -Trigger 'MSFT_TaskLogonTrigger' -Execute 'C:\Users\bob\AppData\Local\Microsoft\OneDrive\OneDriveStandaloneUpdater.exe'
        )
        $r = Invoke-PluginScan -Module $script:StMod -Context (New-TestContext)
        $r.Metrics['LogonBootTaskCount'] | Should -Be 3
        (Get-FindingById $r 'scheduled-tasks-logon-boot')[0].Severity | Should -Be 'Information'
        (Get-FindingById $r 'scheduled-tasks-system-at-logon').Count | Should -Be 0
        (Get-FindingById $r 'scheduled-tasks-user-writable-action').Count | Should -Be 0
        (Get-FindingById $r 'scheduled-tasks-ok').Count | Should -Be 1
    }

    It 'is skipped with an Information finding when Get-ScheduledTask is unavailable' {
        $script:Tasks = 'not available'
        $r = Invoke-PluginScan -Module $script:StMod -Context (New-TestContext)
        $r.Status | Should -Be 'Skipped'
        (Get-FindingById $r 'scheduled-tasks-unavailable')[0].Severity | Should -Be 'Information'
    }
}

Describe 'Startup Folders shortcut seam (New-Object mocked, helpers real)' {
    # The helpers under test are NOT mocked here; only New-Object -ComObject is.
    BeforeEach {
        $script:Created = 0
        $script:ShortcutError = $false
        Mock -ModuleName OmniStartTestStartupFolders New-Object -ParameterFilter { $ComObject -eq 'WScript.Shell' } {
            $script:Created++
            $shell = [pscustomobject]@{ Kind = 'FakeWScriptShell' }
            $shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
                param($p)
                if ($script:ShortcutError) { throw 'The shortcut is damaged.' }
                [pscustomobject]@{ TargetPath = 'C:\Program Files\Vendor\v.exe'; Arguments = "/tray $p" }
            }
            $shell
        }
    }

    It 'creates the shell through New-Object and maps TargetPath/Arguments' {
        $r = & $script:SfMod {
            $s = New-OmniStartupShell
            Resolve-OmniStartupShortcut -Path 'C:\x\Vendor.lnk' -Shell $s
        }
        $script:Created | Should -Be 1
        $r.Target | Should -Be 'C:\Program Files\Vendor\v.exe'
        $r.Arguments | Should -Be '/tray C:\x\Vendor.lnk'
    }

    It 'returns $null when the shortcut cannot be read' {
        $script:ShortcutError = $true
        $r = & $script:SfMod { Resolve-OmniStartupShortcut -Path 'C:\x\bad.lnk' -Shell (New-OmniStartupShell) }
        $r | Should -BeNullOrEmpty
    }

    It 'returns $null when WScript.Shell cannot be created' {
        Mock -ModuleName OmniStartTestStartupFolders New-Object -ParameterFilter { $ComObject -eq 'WScript.Shell' } { throw 'Class not registered' }
        $r = & $script:SfMod { $s = New-OmniStartupShell; [pscustomobject]@{ Shell = $s; Lnk = (Resolve-OmniStartupShortcut -Path 'C:\x\a.lnk' -Shell $s) } }
        $r.Shell | Should -BeNullOrEmpty
        $r.Lnk | Should -BeNullOrEmpty
    }

    It 'release ignores objects that are not COM objects' {
        { & $script:SfMod { Remove-OmniStartupComObject -InputObject ([pscustomobject]@{ A = 1 }); Remove-OmniStartupComObject -InputObject $null } } | Should -Not -Throw
    }
}
