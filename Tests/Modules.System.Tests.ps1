#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Behavior tests for the system group: the System scanner (OS support status,
    architecture, uptime, TPM, Secure Boot), the System Information scanner (inventory),
    the shared Get-OmniSystemInventory core helper, and the GUI's System Information panel
    data (which now reads the same inventory).

    Every data source goes through a private helper that is mocked inside the plugin's
    module scope, so the suite runs on any OS. Each plugin is copied to TestDrive under a
    unique file name so its module name is unique for Mock -ModuleName.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    function Import-SysCopy {
        param([string] $RelativePath, [string] $AsName)
        $dir = Join-Path $TestDrive 'sysplugins'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $copy = Join-Path $dir "$AsName.psm1"
        Copy-Item -LiteralPath (Join-Path $script:Root $RelativePath) -Destination $copy -Force
        return (Import-Module -Name $copy -Force -PassThru -DisableNameChecking)
    }

    function New-SysContext {
        param([bool] $Admin = $false, [System.Threading.CancellationToken] $Token = ([System.Threading.CancellationToken]::None))
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -CancellationToken $Token
        $ctx.IsAdmin = $Admin
        $ctx.Architecture = 'x64'
        return $ctx
    }

    function Invoke-SysScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    function Get-Finding {
        param($Result, [string] $Id)
        @($Result.Findings | Where-Object Id -eq $Id)
    }

    function New-FakeInventory {
        param([object] $Architecture = 9, [object] $LastBoot = (Get-Date).AddDays(-2), [double] $RamBytes = 16GB, [switch] $Empty)
        if ($Empty) {
            return [pscustomobject]@{ OperatingSystem = $null; ComputerSystem = $null; Bios = $null; BaseBoard = $null; Processor = $null; VideoController = @(); SoundDevice = @(); PageFile = $null; Errors = @('Win32_OperatingSystem: not available') }
        }
        [pscustomobject]@{
            OperatingSystem = [pscustomobject]@{ Caption = 'Microsoft Windows 11 Enterprise'; Version = '10.0.26200'; BuildNumber = '26200'; OSArchitecture = '64-bit'; InstallDate = [datetime]'2025-01-02'; LastBootUpTime = $LastBoot }
            ComputerSystem  = [pscustomobject]@{ Name = 'PC01'; Manufacturer = 'Contoso'; Model = 'Laptop 7'; SystemType = 'x64-based PC'; Domain = 'contoso.com'; Workgroup = $null; PartOfDomain = $true; TotalPhysicalMemory = $RamBytes; UserName = 'CONTOSO\user' }
            Bios            = [pscustomobject]@{ Manufacturer = 'Contoso'; SMBIOSBIOSVersion = '1.2.3'; ReleaseDate = [datetime]'2024-05-06'; SerialNumber = 'SN123' }
            BaseBoard       = [pscustomobject]@{ Manufacturer = 'Contoso'; Product = 'Board 9' }
            Processor       = [pscustomobject]@{ Name = ' Contoso CPU 9000 '; NumberOfCores = 8; NumberOfLogicalProcessors = 16; MaxClockSpeed = 3000; Architecture = $Architecture; VirtualizationFirmwareEnabled = $true }
            VideoController = @([pscustomobject]@{ Name = 'Contoso Graphics'; VideoProcessor = 'CG1'; AdapterCompatibility = 'Contoso'; AdapterRAM = 2GB; CurrentHorizontalResolution = 1920; CurrentVerticalResolution = 1080; CurrentRefreshRate = 60; DriverVersion = '31.0.1'; DriverDate = [datetime]'2025-03-04' })
            SoundDevice     = @([pscustomobject]@{ Name = 'Contoso Audio' })
            PageFile        = [pscustomobject]@{ CurrentUsage = 100; AllocatedBaseSize = 4096 }
            Errors          = @()
        }
    }

    function New-OsInfo {
        param([string] $Build, [int] $Ubr = 4317, [string] $Edition = 'Enterprise', [string] $DisplayVersion = '', [string] $ReleaseId = '', [string] $ProductName = 'Windows 10 Enterprise', [string] $InstallationType = 'Client')
        @{ CurrentBuild = $Build; CurrentBuildNumber = $Build; UBR = $Ubr; DisplayVersion = $DisplayVersion; ReleaseId = $ReleaseId; EditionID = $Edition
           ProductName = $ProductName; InstallationType = $InstallationType; CurrentMajorVersionNumber = 10; CurrentMinorVersionNumber = 0 }
    }

    $script:SysMod  = Import-SysCopy -RelativePath 'src/Modules/System.psm1' -AsName 'OmniSysTestSystem'
    $script:InfoMod = Import-SysCopy -RelativePath 'src/Modules/SystemInformation.psm1' -AsName 'OmniSysTestInfo'
    $script:InvMod  = Import-SysCopy -RelativePath 'src/Core/SystemInventory.psm1' -AsName 'OmniSysTestInventory'
    $script:GuiMod  = Import-SysCopy -RelativePath 'src/UI/OmniDiagGui.psm1' -AsName 'OmniSysTestGui'
}

AfterAll {
    foreach ($n in @('OmniSysTestSystem', 'OmniSysTestInfo', 'OmniSysTestInventory', 'OmniSysTestGui')) { Remove-Module -Name $n -Force -ErrorAction SilentlyContinue }
}

Describe 'System scanner: operating system support status' {
    BeforeEach {
        Mock -ModuleName OmniSysTestSystem Test-OmniSysWindowsHost { $true }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysToday { [datetime]'2026-10-18' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { $null }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysSecureBootState { 'Enabled' }
    }

    It 'emits the full version string and flags a release within 90 days of end of servicing (Windows 11 23H2 Enterprise)' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '22631' -Ubr 4317 -DisplayVersion '23H2' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $r.Metrics['OSVersion'] | Should -Be '10.0.22631.4317'
        $r.Metrics['OSFamily'] | Should -Be 'Windows 11'
        $r.Metrics['OSRelease'] | Should -Be '23H2'
        $r.Metrics['OSProductName'] | Should -Be 'Windows 11 Enterprise'
        $r.Metrics['OSEndOfServicing'] | Should -Be '2026-11-10'
        $f = Get-Finding $r 'system.system.os-end-of-servicing-soon'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
    }

    It 'warns that a Home/Pro release past end of servicing is unsupported (Windows 11 24H2 Pro)' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '26100' -Edition 'Professional' -DisplayVersion '24H2' -ProductName 'Windows 10 Pro' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $f = Get-Finding $r 'system.system.os-unsupported-release'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Title | Should -Match 'upgrade'
        $f[0].Detail | Should -Match '2026-10-13'
        $r.Metrics['OSSupportStatus'] | Should -Be 'Unsupported'
    }

    It 'passes a serviced release and derives Windows 11 from the build (25H2 Enterprise)' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '26200' -DisplayVersion '25H2' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        (Get-Finding $r 'system.system.os-supported-release')[0].Severity | Should -Be 'Pass'
        $r.Metrics['OSProductName'] | Should -Be 'Windows 11 Enterprise'
    }

    It 'reports Windows 10 22H2 as Information: end of support on 2025-10-14, ESU not determinable offline' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '19045' -Edition 'Professional' -DisplayVersion '22H2' -ProductName 'Windows 10 Pro' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $f = Get-Finding $r 'system.system.os-windows10-end-of-support'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match '2025-10-14'
        $f[0].Detail | Should -Match 'ESU'
        $r.Metrics['OSFamily'] | Should -Be 'Windows 10'
    }

    It 'warns on Windows 10 below 22H2, using ReleaseId when DisplayVersion is missing' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '18363' -Edition 'Professional' -ReleaseId '1909' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        (Get-Finding $r 'system.system.os-unsupported-release')[0].Severity | Should -Be 'Warning'
        $r.Metrics['OSRelease'] | Should -Be '1909'
    }

    It 'uses the LTSC table for EnterpriseS (Windows 10 LTSC 2019 is serviced; LTSC 2021 IoT uses the IoT date)' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '17763' -Edition 'EnterpriseS' -ReleaseId '1809' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        (Get-Finding $r 'system.system.os-supported-release').Count | Should -Be 1
        $r.Metrics['OSRelease'] | Should -Be 'LTSC 2019'
        $r.Metrics['OSEndOfServicing'] | Should -Be '2029-01-09'
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '19044' -Edition 'IoTEnterpriseS' -DisplayVersion '21H2' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $r.Metrics['OSEndOfServicing'] | Should -Be '2032-01-13'
        (Get-Finding $r 'system.system.os-supported-release').Count | Should -Be 1
    }

    It 'gives no verdict for a build that is not in the table, an unknown edition, or Windows Server' {
        foreach ($info in @(
                (New-OsInfo -Build '27500'),
                (New-OsInfo -Build '26200' -Edition 'SomethingNew'),
                (New-OsInfo -Build '26100' -Edition 'ServerStandard' -InstallationType 'Server'))) {
            $script:CurInfo = $info
            Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { $script:CurInfo }
            $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
            $f = Get-Finding $r 'system.system.os-support-unknown'
            $f.Count | Should -Be 1
            $f[0].Severity | Should -Be 'Information'
            (Get-Finding $r 'system.system.os-unsupported-release').Count | Should -Be 0
        }
    }

    It 'says so when the version registry cannot be read' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { throw 'denied' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        (Get-Finding $r 'system.system.os-version-unavailable')[0].Severity | Should -Be 'Information'
    }
}

Describe 'System scanner: architecture and uptime' {
    BeforeEach {
        Mock -ModuleName OmniSysTestSystem Test-OmniSysWindowsHost { $true }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysToday { [datetime]'2026-10-18' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '26200' -DisplayVersion '25H2' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { $null }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysSecureBootState { 'Enabled' }
    }

    It 'reports x64 and ARM64 on Windows 11 without a platform finding' {
        foreach ($pair in @(@{ Cim = 9; Name = 'x64' }, @{ Cim = 12; Name = 'ARM64' })) {
            $cim = $pair.Cim
            $script:CurArch = $cim
            Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory -Architecture $script:CurArch }
            $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
            $r.Metrics['Architecture'] | Should -Be $pair.Name
            (Get-Finding $r 'system.system.platform-outside-support-matrix').Count | Should -Be 0
        }
    }

    It 'flags x86, and ARM64 on Windows 10, as outside the support matrix' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory -Architecture 0 }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $r.Metrics['Architecture'] | Should -Be 'x86'
        (Get-Finding $r 'system.system.platform-outside-support-matrix')[0].Severity | Should -Be 'Information'

        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '19045' -DisplayVersion '22H2' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory -Architecture 12 }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        (Get-Finding $r 'system.system.platform-outside-support-matrix').Count | Should -Be 1
    }

    It 'falls back to the context architecture when Win32_Processor is unavailable' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory -Empty }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $r.Metrics['Architecture'] | Should -Be 'x64'
        $r.Metrics.Contains('UptimeDays') | Should -BeFalse
    }

    It 'warns on uptime over 14 days and records uptime otherwise' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory -LastBoot (Get-Date).AddDays(-20) }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $f = Get-Finding $r 'system.system.uptime-long'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $r.Metrics['UptimeDays'] | Should -BeGreaterThan 19

        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory -LastBoot (Get-Date).AddDays(-2) }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        (Get-Finding $r 'system.system.uptime-long').Count | Should -Be 0
        $r.Metrics['UptimeDays'] | Should -BeLessThan 3
    }
}

Describe 'System scanner: TPM' {
    BeforeEach {
        Mock -ModuleName OmniSysTestSystem Test-OmniSysWindowsHost { $true }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysToday { [datetime]'2026-10-18' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '26200' -DisplayVersion '25H2' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysSecureBootState { 'Enabled' }
    }

    It 'does not query the TPM as a standard user and says it requires elevation' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { throw 'should not be called' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext -Admin $false)
        Should -Invoke -ModuleName OmniSysTestSystem Get-OmniSysTpm -Times 0 -Exactly
        $f = Get-Finding $r 'system.system.tpm-requires-elevation'
        $f[0].Severity | Should -Be 'Information'
        $f[0].Title | Should -Be 'TPM details require elevation'
        $f[0].Detail | Should -Match 'requires elevation'
        $r.Metrics['TPMStatus'] | Should -Be 'RequiresElevation'
    }

    It 'passes an enabled TPM 2.0' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { [pscustomobject]@{ SpecVersion = '2.0, 0, 1.59'; IsEnabled_InitialValue = $true; IsActivated_InitialValue = $true } }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext -Admin $true)
        (Get-Finding $r 'system.system.tpm-ready')[0].Severity | Should -Be 'Pass'
        $r.Metrics['TPMVersion'] | Should -Be '2.0'
        $r.Metrics['TPMPresent'] | Should -BeTrue
    }

    It 'warns on TPM 1.2, a disabled TPM, and no TPM' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { [pscustomobject]@{ SpecVersion = '1.2, 2, 3'; IsEnabled_InitialValue = $true; IsActivated_InitialValue = $true } }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext -Admin $true)
        (Get-Finding $r 'system.system.tpm-version-below-2')[0].Severity | Should -Be 'Warning'

        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { [pscustomobject]@{ SpecVersion = '2.0, 0, 1.59'; IsEnabled_InitialValue = $false; IsActivated_InitialValue = $true } }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext -Admin $true)
        (Get-Finding $r 'system.system.tpm-disabled')[0].Severity | Should -Be 'Warning'

        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { $null }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext -Admin $true)
        (Get-Finding $r 'system.system.tpm-not-found')[0].Severity | Should -Be 'Warning'
        $r.Metrics['TPMPresent'] | Should -BeFalse
    }

    It 'reports a failed TPM query as Information, not as a missing TPM' {
        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { throw 'Invalid namespace' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext -Admin $true)
        (Get-Finding $r 'system.system.tpm-unavailable')[0].Severity | Should -Be 'Information'
        (Get-Finding $r 'system.system.tpm-not-found').Count | Should -Be 0
    }
}

Describe 'System scanner: Secure Boot' {
    BeforeEach {
        Mock -ModuleName OmniSysTestSystem Test-OmniSysWindowsHost { $true }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysToday { [datetime]'2026-10-18' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '26200' -DisplayVersion '25H2' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { $null }
    }

    It 'maps <State> to <Id> (<Severity>)' -TestCases @(
        @{ State = 'Enabled';           Id = 'system.system.secure-boot-enabled';             Severity = 'Pass' }
        @{ State = 'Disabled';          Id = 'system.system.secure-boot-disabled';            Severity = 'Warning' }
        @{ State = 'LegacyBios';        Id = 'system.system.secure-boot-legacy-bios';         Severity = 'Warning' }
        @{ State = 'RequiresElevation'; Id = 'system.system.secure-boot-requires-elevation';  Severity = 'Information' }
        @{ State = 'Unavailable';       Id = 'system.system.secure-boot-unavailable';         Severity = 'Information' }
    ) {
        param($State, $Id, $Severity)
        $script:CurState = $State
        Mock -ModuleName OmniSysTestSystem Get-OmniSysSecureBootState { $script:CurState }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $f = Get-Finding $r $Id
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be $Severity
        $r.Metrics['SecureBoot'] | Should -Be $State
    }

    It 'classifies Confirm-SecureBootUEFI failures by exception type, not message text' {
        & $script:SysMod { ConvertTo-OmniSysSecureBootFailure -ErrorRecord ([System.PlatformNotSupportedException]::new('x')) } | Should -Be 'LegacyBios'
        & $script:SysMod { ConvertTo-OmniSysSecureBootFailure -ErrorRecord ([System.UnauthorizedAccessException]::new('x')) } | Should -Be 'RequiresElevation'
        & $script:SysMod { ConvertTo-OmniSysSecureBootFailure -ErrorRecord ([System.InvalidOperationException]::new('x')) } | Should -Be 'Unavailable'
        $rec = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('Zugriff verweigert'), 'System.UnauthorizedAccessException,Microsoft.SecureBoot.Commands.ConfirmSecureBootUefiCommand', 'PermissionDenied', $null)
        & $script:SysMod { param($e) ConvertTo-OmniSysSecureBootFailure -ErrorRecord $e } $rec | Should -Be 'RequiresElevation'
        $rec2 = [System.Management.Automation.ErrorRecord]::new([System.PlatformNotSupportedException]::new('nicht unterstuetzt'), 'x', 'NotImplemented', $null)
        & $script:SysMod { param($e) ConvertTo-OmniSysSecureBootFailure -ErrorRecord $e } $rec2 | Should -Be 'LegacyBios'
    }
}

Describe 'System scanner: platform, cancellation, and overlap' {
    It 'returns a single Information finding on non-Windows hosts' {
        Mock -ModuleName OmniSysTestSystem Test-OmniSysWindowsHost { $false }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        $r.Findings.Count | Should -Be 1
        $r.Findings[0].Id | Should -Be 'system.system.windows-only'
        $r.Findings[0].Severity | Should -Be 'Information'
    }

    It 'skips the TPM and Secure Boot checks once cancellation is requested' {
        Mock -ModuleName OmniSysTestSystem Test-OmniSysWindowsHost { $true }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '26200' -DisplayVersion '25H2' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysTpm { $null }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysSecureBootState { 'Enabled' }
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext -Admin $true -Token $cts.Token)
        Should -Invoke -ModuleName OmniSysTestSystem Get-OmniSysTpm -Times 0 -Exactly
        Should -Invoke -ModuleName OmniSysTestSystem Get-OmniSysSecureBootState -Times 0 -Exactly
        $r.PSTypeNames | Should -Contain 'OmniDiag.Result'
    }

    It 'leaves inventory to System Information (no identity, BIOS, or board metrics)' {
        Mock -ModuleName OmniSysTestSystem Test-OmniSysWindowsHost { $true }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysOsVersionInfo { New-OsInfo -Build '26200' -DisplayVersion '25H2' }
        Mock -ModuleName OmniSysTestSystem Get-OmniSystemInventory { New-FakeInventory }
        Mock -ModuleName OmniSysTestSystem Get-OmniSysSecureBootState { 'Enabled' }
        $r = Invoke-SysScan -Module $script:SysMod -Context (New-SysContext)
        foreach ($k in @('Hostname', 'Manufacturer', 'Model', 'SerialNumber', 'BIOSVersion', 'Motherboard')) { $r.Metrics.Contains($k) | Should -BeFalse -Because $k }
    }

    It 'keeps the manifest Id and Name' {
        $m = & $script:SysMod { Get-OmniModuleManifest }
        $m.Name | Should -Be 'System'
        $m.Id | Should -Be 'system.system'
        $m.NetworkAccess | Should -Be 'None'
    }
}

Describe 'System Information scanner (inventory)' {
    BeforeEach {
        Mock -ModuleName OmniSysTestInfo Get-OmniSysInfoInstalledAppName { @('App A', 'App B', 'App C') }
    }

    It 'reports the inventory as metrics and passes when nothing is wrong' {
        Mock -ModuleName OmniSysTestInfo Get-OmniSystemInventory { New-FakeInventory }
        $r = Invoke-SysScan -Module $script:InfoMod -Context (New-SysContext)
        $r.Metrics['Hostname'] | Should -Be 'PC01'
        $r.Metrics['Manufacturer'] | Should -Be 'Contoso'
        $r.Metrics['SerialNumber'] | Should -Be 'SN123'
        $r.Metrics['Motherboard'] | Should -Be 'Contoso Board 9'
        $r.Metrics['CPU'] | Should -Be 'Contoso CPU 9000'
        $r.Metrics['CPUThreads'] | Should -Be 16
        $r.Metrics['GPU'] | Should -Be 'Contoso Graphics'
        $r.Metrics['TotalRAMGB'] | Should -Be 16
        $r.Metrics['OS'] | Should -Be 'Microsoft Windows 11 Enterprise'
        $r.Metrics['InstalledSoftwareCount'] | Should -Be 3
        $r.Metrics['VirtualizationFirmwareEnabled'] | Should -BeTrue
        (Get-Finding $r 'system.system-information.inventory-collected')[0].Severity | Should -Be 'Pass'
    }

    It 'does not repeat the System scanner checks (uptime, TPM, Secure Boot, support status)' {
        Mock -ModuleName OmniSysTestInfo Get-OmniSystemInventory { New-FakeInventory -LastBoot (Get-Date).AddDays(-30) }
        $r = Invoke-SysScan -Module $script:InfoMod -Context (New-SysContext)
        foreach ($k in @('UptimeDays', 'LastBootUpTime', 'TPMPresent', 'SecureBoot', 'OSSupportStatus')) { $r.Metrics.Contains($k) | Should -BeFalse -Because $k }
        @($r.Findings | Where-Object { $_.Component -match 'Uptime|Security' }).Count | Should -Be 0
    }

    It 'warns on less than 8 GB of RAM' {
        Mock -ModuleName OmniSysTestInfo Get-OmniSystemInventory { New-FakeInventory -RamBytes 4GB }
        $r = Invoke-SysScan -Module $script:InfoMod -Context (New-SysContext)
        (Get-Finding $r 'system.system-information.memory-low')[0].Severity | Should -Be 'Warning'
        (Get-Finding $r 'system.system-information.inventory-collected').Count | Should -Be 0
    }

    It 'falls back to the context host name and says when no inventory is available' {
        Mock -ModuleName OmniSysTestInfo Get-OmniSystemInventory { New-FakeInventory -Empty }
        $ctx = New-SysContext
        $r = Invoke-SysScan -Module $script:InfoMod -Context $ctx
        $r.Metrics['Hostname'] | Should -Be $ctx.Host.ComputerName
        (Get-Finding $r 'system.system-information.inventory-unavailable')[0].Severity | Should -Be 'Information'
    }

    It 'keeps the manifest Id and Name' {
        $m = & $script:InfoMod { Get-OmniModuleManifest }
        $m.Name | Should -Be 'System Information'
        $m.Id | Should -Be 'system.system-information'
    }
}

Describe 'Get-OmniSystemInventory (core)' {
    It 'is exported by the OmniDiag module' {
        @((Get-Module -Name OmniDiag).ExportedFunctions.Keys) | Should -Contain 'Get-OmniSystemInventory'
    }

    It 'copies the requested sections into plain objects and records failures' {
        Mock -ModuleName OmniSysTestInventory Get-OmniInventoryCimInstance {
            switch ($ClassName) {
                'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Windows'; Version = '10.0.26200'; BuildNumber = '26200'; OSArchitecture = '64-bit'; InstallDate = $null; LastBootUpTime = [datetime]'2026-10-17'; Extra = 'dropped' } }
                'Win32_VideoController' { [pscustomobject]@{ Name = 'GPU A' }; [pscustomobject]@{ Name = 'GPU B' } }
                'Win32_Processor'       { [pscustomobject]@{ Name = 'CPU 0'; Architecture = 12 }; [pscustomobject]@{ Name = 'CPU 1'; Architecture = 12 } }
                'Win32_BIOS'            { throw 'WMI repository is corrupt' }
                default                 { $null }
            }
        }
        $inv = & $script:InvMod { Get-OmniSystemInventory }
        $inv.OperatingSystem.LastBootUpTime | Should -Be ([datetime]'2026-10-17')
        $inv.OperatingSystem.PSObject.Properties.Name | Should -Not -Contain 'Extra'
        @($inv.VideoController).Count | Should -Be 2
        $inv.Processor.Name | Should -Be 'CPU 0'
        $inv.Processor.Architecture | Should -Be 12
        $inv.Bios | Should -BeNullOrEmpty
        $inv.ComputerSystem | Should -BeNullOrEmpty
        @($inv.SoundDevice).Count | Should -Be 0
        @($inv.Errors) | Should -HaveCount 1
        @($inv.Errors)[0] | Should -Match '^Win32_BIOS: '
    }

    It 'queries only the requested sections' {
        Mock -ModuleName OmniSysTestInventory Get-OmniInventoryCimInstance { $null }
        $inv = & $script:InvMod { Get-OmniSystemInventory -Section OperatingSystem, Processor }
        Should -Invoke -ModuleName OmniSysTestInventory Get-OmniInventoryCimInstance -Times 2 -Exactly
        Should -Invoke -ModuleName OmniSysTestInventory Get-OmniInventoryCimInstance -Times 0 -Exactly -ParameterFilter { $ClassName -eq 'Win32_BIOS' }
        $inv.PSObject.Properties.Name | Should -Contain 'Bios'
    }

    It 'never throws when CIM is unavailable' {
        Mock -ModuleName OmniSysTestInventory Get-OmniInventoryCimInstance { throw 'Get-CimInstance not found' }
        { & $script:InvMod { Get-OmniSystemInventory } } | Should -Not -Throw
        $inv = & $script:InvMod { Get-OmniSystemInventory }
        @($inv.Errors).Count | Should -Be 8
    }
}

Describe 'GUI System Information panel data' {
    It 'builds the same panel fields from the shared inventory' {
        Mock -ModuleName OmniSysTestGui Get-OmniSystemInventory { New-FakeInventory }
        $info = & $script:GuiMod { Get-OmniSystemInfo }
        Should -Invoke -ModuleName OmniSysTestGui Get-OmniSystemInventory -Times 1 -Exactly
        @($info.Keys) | Should -Be @('System', 'Processor', 'Display', 'Sound')
        $sys = $info['System']
        $sys['Operating System'] | Should -Be 'Microsoft Windows 11 Enterprise 10.0.26200 (Build 26200)'
        $sys['Architecture'] | Should -Be '64-bit'
        $sys['Manufacturer'] | Should -Be 'Contoso'
        $sys['Model'] | Should -Be 'Laptop 7'
        $sys['System Type'] | Should -Be 'x64-based PC'
        $sys['Domain'] | Should -Be 'contoso.com'
        $sys['Installed Memory (RAM)'] | Should -Be '16 GB'
        $sys['BIOS'] | Should -Be 'Contoso 1.2.3 (2024-05-06)'
        $sys['Page File'] | Should -Be '100 MB used / 4096 MB allocated'
        $sys.Contains('Uptime') | Should -BeTrue
        $info['Processor']['Cores / Threads'] | Should -Be '8 cores, 16 logical'
        $info['Processor']['Max Clock'] | Should -Be '3000 MHz'
        $info['Display']['Current Mode'] | Should -Be '1920 x 1080 @ 60 Hz'
        $info['Display']['Driver Date'] | Should -Be '2025-03-04'
        $info['Sound']['Device 1'] | Should -Be 'Contoso Audio'
    }

    It 'still returns the computer name when no inventory is available' {
        Mock -ModuleName OmniSysTestGui Get-OmniSystemInventory { New-FakeInventory -Empty }
        $info = & $script:GuiMod { Get-OmniSystemInfo }
        @($info.Keys) | Should -Be @('System')
    }
}
