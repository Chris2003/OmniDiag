#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests for the 'services' group scanners (Services, Drivers). Every data source
    is a private helper inside the plugin (Get-OmniServiceInstance, Get-OmniServiceScmEvent,
    Get-OmniDriverCim, Get-OmniDriverSystemRoot); the tests mock those helpers inside the
    plugin's module scope, so they run on Linux and Windows alike and cover each finding path.

    The mocks return script-scoped test data set in BeforeEach and changed per test; a
    string value makes the mocked helper throw it (data source unavailable).

    Each plugin is copied to TestDrive under a unique file name so its module name is unique
    for Mock -ModuleName (discovery elsewhere may have loaded 'Services' already).
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
        param([hashtable] $Config = @{})
        New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -Config $Config
    }

    function Invoke-PluginScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    function Get-FindingById {
        param($Result, [string] $Id)
        return , @($Result.Findings | Where-Object { $_.Id -eq $Id })
    }

    $script:SvcMod = Import-PluginCopy -File 'Services.psm1' -AsName 'OmniSvcTestServices'
    $script:DrvMod = Import-PluginCopy -File 'Drivers.psm1' -AsName 'OmniSvcTestDrivers'
}

AfterAll {
    foreach ($n in @('OmniSvcTestServices', 'OmniSvcTestDrivers')) { Remove-Module -Name $n -Force -ErrorAction SilentlyContinue }
}

Describe 'Services scanner' {
    BeforeEach {
        $script:SvcData = @(
            [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler'; StartMode = 'Auto'; State = 'Running'; DelayedAutoStart = $false; ExitCode = 0 }
            [pscustomobject]@{ Name = 'Delayed'; DisplayName = 'Delayed Svc'; StartMode = 'Auto'; State = 'Stopped'; DelayedAutoStart = $true; ExitCode = 0 }
            [pscustomobject]@{ Name = 'ManualSvc'; DisplayName = 'Manual Svc'; StartMode = 'Manual'; State = 'Stopped'; DelayedAutoStart = $false; ExitCode = 0 }
            [pscustomobject]@{ Name = 'Off'; DisplayName = 'Disabled Svc'; StartMode = 'Disabled'; State = 'Stopped'; DelayedAutoStart = $false; ExitCode = 0 }
        )
        $script:ScmData = @()
        Mock -ModuleName OmniSvcTestServices Get-OmniServiceInstance {
            if ($script:SvcData -is [string]) { throw $script:SvcData }
            $script:SvcData
        }
        Mock -ModuleName OmniSvcTestServices Get-OmniServiceScmEvent {
            if ($script:ScmData -is [string]) { throw $script:ScmData }
            $script:ScmData
        }
    }

    It 'reports counts by start type and passes when nothing is wrong' {
        $r = Invoke-PluginScan -Module $script:SvcMod -Context (New-TestContext)
        $t = $r.Metrics['ServicesByStartType']
        $t['Automatic'] | Should -Be 1
        $t['Automatic (Delayed Start)'] | Should -Be 1
        $t['Manual'] | Should -Be 1
        $t['Disabled'] | Should -Be 1
        $r.Metrics['ServiceCount'] | Should -Be 4
        (Get-FindingById $r 'services-start-type-summary')[0].Severity | Should -Be 'Information'
        (Get-FindingById $r 'services-healthy').Count | Should -Be 1
        (Get-FindingById $r 'services-auto-start-stopped').Count | Should -Be 0
        $r.Metrics['ScmEventCount'] | Should -Be 0
    }

    It 'flags stopped automatic services (not delayed) with their exit code' {
        $script:SvcData = @(
            [pscustomobject]@{ Name = 'Broken'; DisplayName = 'Broken Svc'; StartMode = 'Auto'; State = 'Stopped'; DelayedAutoStart = $false; ExitCode = 1067 }
            [pscustomobject]@{ Name = 'Delayed'; DisplayName = 'Delayed Svc'; StartMode = 'Auto'; State = 'Stopped'; DelayedAutoStart = $true; ExitCode = 0 }
        )
        $r = Invoke-PluginScan -Module $script:SvcMod -Context (New-TestContext)
        $f = Get-FindingById $r 'services-auto-start-stopped'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Detail | Should -Match 'Broken Svc \(exit code 1067\)'
        $f[0].Detail | Should -Not -Match 'Delayed Svc'
        $r.Metrics['AutoStoppedServiceCount'] | Should -Be 1
        (Get-FindingById $r 'services-healthy').Count | Should -Be 0
    }

    It 'groups SCM crash and start-failure events per service' {
        $now = Get-Date
        $script:ScmData = @(
            [pscustomobject]@{ Id = 7031; TimeCreated = $now.AddHours(-1); ServiceName = 'Print Spooler' }
            [pscustomobject]@{ Id = 7031; TimeCreated = $now.AddHours(-2); ServiceName = 'Print Spooler' }
            [pscustomobject]@{ Id = 7034; TimeCreated = $now.AddHours(-3); ServiceName = 'Print Spooler' }
            [pscustomobject]@{ Id = 7009; TimeCreated = $now.AddHours(-4); ServiceName = 'Print Spooler' }
            [pscustomobject]@{ Id = 7000; TimeCreated = $now.AddHours(-5); ServiceName = 'Foo Service' }
            [pscustomobject]@{ Id = 7011; TimeCreated = $now.AddHours(-6); ServiceName = 'Foo Service' }
        )
        $r = Invoke-PluginScan -Module $script:SvcMod -Context (New-TestContext)
        $crash = Get-FindingById $r 'services-scm-crash-spooler'
        $crash.Count | Should -Be 1
        $crash[0].Severity | Should -Be 'Warning'
        $crash[0].Detail | Should -Match '^3 unexpected termination'
        $crash[0].Detail | Should -Match '7031, 7034'
        $crash[0].Data.ServiceName | Should -Be 'Spooler'
        (Get-FindingById $r 'services-scm-start-failure-spooler').Count | Should -Be 1
        $foo = Get-FindingById $r 'services-scm-start-failure-foo-service'
        $foo.Count | Should -Be 1
        $foo[0].Detail | Should -Match '^2 start failure'
        $r.Metrics['CrashedServiceCount'] | Should -Be 1
        $r.Metrics['FailedStartServiceCount'] | Should -Be 2
        $r.Metrics['ScmEventCount'] | Should -Be 6
        (Get-FindingById $r 'services-healthy').Count | Should -Be 0
    }

    It 'queries the SCM event ids over the time range with a bounded MaxEvents' {
        $range = Get-OmniTimeRange -Preset Last24Hours
        $script:ExpectedStart = $range.Start
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -TimeRange $range -Config @{ ServiceEventMaxEvents = 50 }
        $null = Invoke-PluginScan -Module $script:SvcMod -Context $ctx
        Should -Invoke -ModuleName OmniSvcTestServices Get-OmniServiceScmEvent -Times 1 -Exactly -ParameterFilter {
            $MaxEvents -eq 50 -and $Start -eq $script:ExpectedStart -and
            @(@(7000, 7009, 7011, 7031, 7034) | Where-Object { $Id -notcontains $_ }).Count -eq 0
        }
    }

    It 'says so when the System log cannot be read' {
        $script:ScmData = 'log unavailable'
        $r = Invoke-PluginScan -Module $script:SvcMod -Context (New-TestContext)
        $f = Get-FindingById $r 'services-scm-events-unavailable'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
        $r.Metrics.Contains('ScmEventCount') | Should -BeFalse
    }

    It 'is skipped with an Information finding when Win32_Service is unavailable' {
        $script:SvcData = 'no CIM'
        $r = Invoke-PluginScan -Module $script:SvcMod -Context (New-TestContext)
        $r.Status | Should -Be 'Skipped'
        (Get-FindingById $r 'services-inventory-unavailable')[0].Severity | Should -Be 'Information'
    }

    It 'uses finding ids that do not embed counts' {
        $script:SvcData = @([pscustomobject]@{ Name = 'Broken'; DisplayName = 'Broken Svc'; StartMode = 'Auto'; State = 'Stopped'; DelayedAutoStart = $false; ExitCode = 1 })
        $r = Invoke-PluginScan -Module $script:SvcMod -Context (New-TestContext)
        foreach ($f in $r.Findings) { $f.Id | Should -Not -Match '\d' }
    }
}

Describe 'Drivers scanner' {
    BeforeEach {
        $script:CimData = @{}
        $script:CimData['Win32_PnPSignedDriver'] = @(
            [pscustomobject]@{ DeviceName = 'Generic Bus'; DriverProviderName = 'Microsoft'; DriverVersion = '10.0'; InfName = 'machine.inf'; IsSigned = $true; Signer = 'Microsoft Windows' }
            [pscustomobject]@{ DeviceName = 'NIC'; DriverProviderName = 'Intel'; DriverVersion = '1.2'; InfName = 'oem1.inf'; IsSigned = $true; Signer = 'Microsoft Windows Hardware Compatibility Publisher' }
            [pscustomobject]@{ DeviceName = 'Chipset'; DriverProviderName = 'Intel'; DriverVersion = '3.4'; InfName = 'oem2.inf'; IsSigned = $true; Signer = 'Microsoft Windows Hardware Compatibility Publisher' }
            [pscustomobject]@{ DeviceName = 'Legacy'; DriverProviderName = $null; DriverVersion = $null; InfName = $null; IsSigned = $null; Signer = $null }
        )
        $script:CimData['Win32_SystemDriver'] = @(
            [pscustomobject]@{ Name = 'inbox'; State = 'Running'; StartMode = 'Boot'; PathName = '\SystemRoot\System32\drivers\inbox.sys' }
            [pscustomobject]@{ Name = 'dch'; State = 'Running'; StartMode = 'Manual'; PathName = 'C:\Windows\System32\DriverStore\FileRepository\x.inf_amd64\dch.sys' }
        )
        $script:CimData['Win32_PnPEntity'] = @([pscustomobject]@{ Name = 'Disk'; DeviceID = 'SCSI\DISK\1'; ConfigManagerErrorCode = 0 })
        Mock -ModuleName OmniSvcTestDrivers Get-OmniDriverSystemRoot { 'C:\Windows' }
        Mock -ModuleName OmniSvcTestDrivers Get-OmniDriverCim {
            $v = $script:CimData[$ClassName]
            if ($v -is [string]) { throw $v }
            $v
        }
    }

    It 'passes and summarizes third-party providers when nothing is wrong' {
        $r = Invoke-PluginScan -Module $script:DrvMod -Context (New-TestContext)
        $r.Metrics['DriverCount'] | Should -Be 4
        $r.Metrics['UnsignedDriverCount'] | Should -Be 0
        $r.Metrics['ThirdPartyDriverCount'] | Should -Be 2
        $s = Get-FindingById $r 'drivers-third-party-summary'
        $s.Count | Should -Be 1
        $s[0].Severity | Should -Be 'Information'
        $s[0].Detail | Should -Match 'Intel \(2\)'
        $r.Metrics['RunningDriversOutsideDriverFolderCount'] | Should -Be 0
        $r.Metrics['ProblemDeviceCount'] | Should -Be 0
        (Get-FindingById $r 'drivers-healthy').Count | Should -Be 1
    }

    It 'flags unsigned drivers as a Warning (a null IsSigned is not unsigned)' {
        $script:CimData['Win32_PnPSignedDriver'] = @(
            [pscustomobject]@{ DeviceName = 'Odd Device'; DriverProviderName = 'Acme'; DriverVersion = '0.1'; InfName = 'oem9.inf'; IsSigned = $false; Signer = $null }
            [pscustomobject]@{ DeviceName = 'Legacy'; DriverProviderName = $null; DriverVersion = $null; InfName = $null; IsSigned = $null; Signer = $null }
        )
        $r = Invoke-PluginScan -Module $script:DrvMod -Context (New-TestContext)
        $f = Get-FindingById $r 'drivers-unsigned'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Detail | Should -Match 'Odd Device \(Acme 0\.1, oem9\.inf\)'
        $r.Metrics['UnsignedDriverCount'] | Should -Be 1
        (Get-FindingById $r 'drivers-healthy').Count | Should -Be 0
    }

    It 'lists running system drivers loaded from outside the driver folders' {
        $script:CimData['Win32_SystemDriver'] = @(
            [pscustomobject]@{ Name = 'inbox'; State = 'Running'; StartMode = 'Boot'; PathName = '\SystemRoot\System32\drivers\inbox.sys' }
            [pscustomobject]@{ Name = 'vendor'; State = 'Running'; StartMode = 'System'; PathName = '\??\C:\Program Files\Vendor\vendor.sys' }
            [pscustomobject]@{ Name = 'idle'; State = 'Stopped'; StartMode = 'Manual'; PathName = 'C:\Tools\idle.sys' }
        )
        $r = Invoke-PluginScan -Module $script:DrvMod -Context (New-TestContext)
        $r.Metrics['RunningDriversOutsideDriverFolderCount'] | Should -Be 1
        $f = Get-FindingById $r 'drivers-system-driver-outside-driver-folder'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match ([regex]::Escape('vendor [System] C:\Program Files\Vendor\vendor.sys'))
        $f[0].Detail | Should -Not -Match 'idle'
    }

    It 'emits one finding per problem device with the code meaning and a recommendation' {
        $script:CimData['Win32_PnPEntity'] = @(
            [pscustomobject]@{ Name = 'USB Camera'; DeviceID = 'USB\VID_1234&PID_5678\1'; ConfigManagerErrorCode = 43 }
            [pscustomobject]@{ Name = 'Spare NIC'; DeviceID = 'PCI\VEN_8086&DEV_1'; ConfigManagerErrorCode = 22 }
            [pscustomobject]@{ Name = $null; DeviceID = 'ROOT\ODD\0000'; ConfigManagerErrorCode = 99 }
            [pscustomobject]@{ Name = 'Fine'; DeviceID = 'ROOT\FINE'; ConfigManagerErrorCode = 0 }
        )
        $r = Invoke-PluginScan -Module $script:DrvMod -Context (New-TestContext)
        $r.Metrics['ProblemDeviceCount'] | Should -Be 3
        $cam = Get-FindingById $r 'drivers-problem-device-usb-vid-1234-pid-5678-1'
        $cam.Count | Should -Be 1
        $cam[0].Severity | Should -Be 'Error'
        $cam[0].Detail | Should -Match 'stopped this device'
        $cam[0].Recommendation | Should -Not -BeNullOrEmpty
        $cam[0].Data.ErrorCode | Should -Be 43
        (Get-FindingById $r 'drivers-problem-device-pci-ven-8086-dev-1')[0].Severity | Should -Be 'Information'
        $odd = Get-FindingById $r 'drivers-problem-device-root-odd-0000'
        $odd[0].Severity | Should -Be 'Warning'
        $odd[0].Title | Should -Match 'ROOT\\ODD\\0000 \(code 99\)'
        @($r.Findings | Where-Object { $_.Id -like 'drivers-problem-device-*' }).Count | Should -Be 3
    }

    It 'maps every documented Device Manager code' {
        $codes = @(& $script:DrvMod { $script:DeviceErrorCode.Keys })
        foreach ($c in @(1, 3, 10, 12, 18, 22, 24, 28, 31, 39, 43, 45, 52)) { $codes | Should -Contain $c }
    }

    It 'is skipped with an Information finding when no CIM class can be queried' {
        foreach ($k in @('Win32_PnPSignedDriver', 'Win32_SystemDriver', 'Win32_PnPEntity')) { $script:CimData[$k] = 'no CIM' }
        $r = Invoke-PluginScan -Module $script:DrvMod -Context (New-TestContext)
        $r.Status | Should -Be 'Skipped'
        (Get-FindingById $r 'drivers-inventory-unavailable')[0].Severity | Should -Be 'Information'
    }
}
