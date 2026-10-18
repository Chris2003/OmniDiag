#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Storage group scanners, with mocked data sources (runs on any platform).

    TRIM (storage.trim): every finding path - setting unreadable, NTFS disabled with an
    SSD (Warning), without an SSD or with unknown media (Information), ReFS disabled with
    and without ReFS volumes, and everything enabled (Pass). The scanner's private data
    helpers are mocked inside a uniquely named copy of the plugin.

    Storage / Disk / Disk Usage: volume findings carry stable Ids with no percentages or
    sizes in them. Storage cmdlets that do not exist on the host (Linux, macOS) get
    temporary global stubs so they can be mocked; the stubs are removed afterwards.
#>

BeforeAll {
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

    # Global stubs for storage cmdlets missing on this host, so Mock can replace them.
    $script:Stubbed = [System.Collections.Generic.List[string]]::new()
    $stubBody = [scriptblock]::Create('[CmdletBinding()] param([Parameter(ValueFromPipeline)] $InputObject, [Parameter(ValueFromRemainingArguments)] $Rest) process { }')
    foreach ($n in @('Get-PhysicalDisk', 'Get-Disk', 'Get-Volume', 'Get-StorageReliabilityCounter', 'Get-Counter', 'Get-CimInstance')) {
        if (-not (Get-Command -Name $n -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$n" -Value $stubBody
            $script:Stubbed.Add($n)
        }
    }

    $script:TrimMod = Import-PluginCopy -File 'Trim.psm1' -AsName 'OmniStorageTestTrim'
    $script:StorageMod = Import-PluginCopy -File 'Storage.psm1' -AsName 'OmniStorageTestStorage'
    $script:DiskMod = Import-PluginCopy -File 'Disk.psm1' -AsName 'OmniStorageTestDisk'
    $script:UsageMod = Import-PluginCopy -File 'DiskUsage.psm1' -AsName 'OmniStorageTestUsage'

    function New-Disk { param([string] $Name, [string] $Media) [pscustomobject]@{ FriendlyName = $Name; MediaType = $Media } }
}

AfterAll {
    foreach ($n in @('OmniStorageTestTrim', 'OmniStorageTestStorage', 'OmniStorageTestDisk', 'OmniStorageTestUsage')) {
        Remove-Module -Name $n -Force -ErrorAction SilentlyContinue
    }
    foreach ($n in $script:Stubbed) { Remove-Item -Path "function:global:$n" -ErrorAction SilentlyContinue }
}

Describe 'TRIM scanner manifest' {
    It 'is a local-only storage scanner' {
        $m = & $script:TrimMod { Get-OmniModuleManifest }
        $m.Id | Should -Be 'storage.trim'
        $m.Group | Should -Be 'storage'
        $m.NetworkAccess | Should -Be 'None'
        $m.RequiresAdmin | Should -BeFalse
    }

    It 'never calls fsutil' {
        $src = Get-Content -LiteralPath (Join-Path $script:Root 'src/Modules/Trim.psm1') -Raw
        # fsutil appears only inside the recommendation text, never as a command.
        $src | Should -Not -Match '(?m)^\s*(&\s*)?[''"]?fsutil'
        $src | Should -Not -Match '(?i)(Start-Process|Invoke-Expression|&)\s*[''"]?[^''"\s]*fsutil'
    }

    It 'treats SSD by enum name or numeric value' {
        & $script:TrimMod { Test-OmniTrimIsSsd -MediaType 'SSD' } | Should -BeTrue
        & $script:TrimMod { Test-OmniTrimIsSsd -MediaType '4' } | Should -BeTrue
        & $script:TrimMod { Test-OmniTrimIsSsd -MediaType 'HDD' } | Should -BeFalse
        & $script:TrimMod { Test-OmniTrimIsSsd -MediaType '' } | Should -BeFalse
    }
}

Describe 'TRIM scanner findings' {
    BeforeEach {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimRefsVolumeCount { 0 }
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimPhysicalDisk { , @((New-Disk 'Fast SSD' 'SSD'), (New-Disk 'Big HDD' 'HDD')) }
    }

    It 'reports Information when the setting cannot be read' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { $null }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        @($r.Findings).Count | Should -Be 1
        $r.Findings[0].Id | Should -Be 'storage-trim-not-available'
        $r.Findings[0].Severity | Should -Be 'Information'
        $r.Status | Should -Be 'Healthy'
    }

    It 'treats a registry read error like an unreadable setting' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { throw 'Access denied' }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        $r.Findings[0].Id | Should -Be 'storage-trim-not-available'
    }

    It 'passes when NTFS TRIM is enabled and ReFS is not set' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { [pscustomobject]@{ Ntfs = 0; Refs = $null } }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        @($r.Findings).Count | Should -Be 1
        $r.Findings[0].Id | Should -Be 'storage-trim-enabled'
        $r.Findings[0].Severity | Should -Be 'Pass'
        $r.Findings[0].Detail | Should -Match 'not set'
        $r.Metrics['NtfsDeleteNotification'] | Should -Be 'Enabled'
        $r.Metrics['RefsDeleteNotification'] | Should -Be 'NotSet'
        $r.Metrics['SsdCount'] | Should -Be 1
    }

    It 'treats an absent NTFS value as enabled (the NTFS default)' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { [pscustomobject]@{ Ntfs = $null; Refs = 0 } }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        $r.Findings[0].Id | Should -Be 'storage-trim-enabled'
        $r.Metrics['RefsDeleteNotification'] | Should -Be 'Enabled'
    }

    It 'warns when NTFS TRIM is disabled and an SSD is present' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { [pscustomobject]@{ Ntfs = 1; Refs = $null } }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'storage-trim-ntfs-disabled')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Detail | Should -Match 'Fast SSD'
        $f[0].Recommendation | Should -Match 'DisableDeleteNotify NTFS 0'
        @($r.Findings | Where-Object Severity -eq 'Pass').Count | Should -Be 0
        $r.Status | Should -Be 'Warning'
    }

    It 'is Information when NTFS TRIM is disabled but there is no SSD' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimPhysicalDisk { , @((New-Disk 'Big HDD' 'HDD')) }
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { [pscustomobject]@{ Ntfs = 1; Refs = $null } }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'storage-trim-ntfs-disabled')
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match 'No SSD'
        $r.Status | Should -Be 'Healthy'
    }

    It 'is Information when NTFS TRIM is disabled and the media type is unknown' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimPhysicalDisk { throw 'Storage module missing' }
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { [pscustomobject]@{ Ntfs = 1; Refs = $null } }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'storage-trim-ntfs-disabled')
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match 'could not be read'
        $r.Metrics.Contains('SsdCount') | Should -BeFalse
    }

    It 'warns when ReFS TRIM is disabled, an SSD is present, and ReFS volumes exist' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimRefsVolumeCount { 2 }
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { [pscustomobject]@{ Ntfs = 0; Refs = 1 } }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'storage-trim-refs-disabled')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Recommendation | Should -Match 'DisableDeleteNotify ReFS 0'
        $r.Metrics['RefsVolumeCount'] | Should -Be 2
        @($r.Findings | Where-Object Severity -eq 'Pass').Count | Should -Be 0
    }

    It 'is Information when ReFS TRIM is disabled but no ReFS volume exists' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { [pscustomobject]@{ Ntfs = 0; Refs = 1 } }
        $r = Invoke-PluginScan -Module $script:TrimMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'storage-trim-refs-disabled')
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match 'No ReFS volume'
        @($r.Findings | Where-Object Id -eq 'storage-trim-enabled').Count | Should -Be 1
    }

    It 'stops after reading the setting when the scan is cancelled' {
        Mock -ModuleName OmniStorageTestTrim Get-OmniTrimSetting { [pscustomobject]@{ Ntfs = 1; Refs = $null } }
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -CancellationToken $cts.Token
        $r = Invoke-PluginScan -Module $script:TrimMod -Context $ctx
        @($r.Findings).Count | Should -Be 0
        Should -Invoke -ModuleName OmniStorageTestTrim Get-OmniTrimPhysicalDisk -Times 0 -Exactly
    }
}

Describe 'Storage scanners: stable volume finding Ids' {
    BeforeAll {
        $script:LowVolumes = {
            @(
                [pscustomobject]@{ DriveLetter = 'C'; Size = 100GB; SizeRemaining = 3GB; FileSystem = 'NTFS'; HealthStatus = 'Healthy'; DriveType = 'Fixed' }
                [pscustomobject]@{ DriveLetter = 'D'; Size = 100GB; SizeRemaining = 8GB; FileSystem = 'NTFS'; HealthStatus = 'Warning'; DriveType = 'Fixed' }
            )
        }
    }

    It 'Storage: low-space and volume-health Ids do not contain percentages' {
        Mock -ModuleName OmniStorageTestStorage Get-PhysicalDisk { @() }
        Mock -ModuleName OmniStorageTestStorage Get-Disk { @() }
        Mock -ModuleName OmniStorageTestStorage Get-Counter { throw 'no counters' }
        Mock -ModuleName OmniStorageTestStorage Get-Volume $script:LowVolumes
        $r = Invoke-PluginScan -Module $script:StorageMod -Context (New-TestContext)
        $ids = @($r.Findings.Id)
        $ids | Should -Contain 'storage-volume-low-space-c'
        $ids | Should -Contain 'storage-volume-low-space-d'
        $ids | Should -Contain 'storage-volume-health-d'
        ($r.Findings | Where-Object Id -eq 'storage-volume-low-space-c').Severity | Should -Be 'Critical'
        ($r.Findings | Where-Object Id -eq 'storage-volume-low-space-d').Severity | Should -Be 'Warning'
        foreach ($id in $ids) { $id | Should -Not -Match '\d+-free|pct|%' }
    }

    It 'Storage: the same volume keeps the same Id when its free space changes' {
        Mock -ModuleName OmniStorageTestStorage Get-PhysicalDisk { @() }
        Mock -ModuleName OmniStorageTestStorage Get-Disk { @() }
        Mock -ModuleName OmniStorageTestStorage Get-Counter { throw 'no counters' }
        Mock -ModuleName OmniStorageTestStorage Get-Volume { @([pscustomobject]@{ DriveLetter = 'C'; Size = 100GB; SizeRemaining = 7GB; FileSystem = 'NTFS'; HealthStatus = 'Healthy' }) }
        $a = Invoke-PluginScan -Module $script:StorageMod -Context (New-TestContext)
        Mock -ModuleName OmniStorageTestStorage Get-Volume { @([pscustomobject]@{ DriveLetter = 'C'; Size = 100GB; SizeRemaining = 9GB; FileSystem = 'NTFS'; HealthStatus = 'Healthy' }) }
        $b = Invoke-PluginScan -Module $script:StorageMod -Context (New-TestContext)
        $a.Findings[0].Id | Should -Be $b.Findings[0].Id
        $a.Findings[0].Title | Should -Not -Be $b.Findings[0].Title
    }

    It 'Storage: unhealthy disks get a per-disk Id' {
        Mock -ModuleName OmniStorageTestStorage Get-PhysicalDisk { @([pscustomobject]@{ DeviceId = '0'; FriendlyName = 'Disk A'; MediaType = 'SSD'; Size = 500GB; HealthStatus = 'Unhealthy'; OperationalStatus = @('Lost Communication') }) }
        Mock -ModuleName OmniStorageTestStorage Get-StorageReliabilityCounter { throw 'needs admin' }
        Mock -ModuleName OmniStorageTestStorage Get-Disk { @() }
        Mock -ModuleName OmniStorageTestStorage Get-Counter { throw 'no counters' }
        Mock -ModuleName OmniStorageTestStorage Get-Volume { @() }
        $r = Invoke-PluginScan -Module $script:StorageMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'storage-disk-health-0')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Critical'
    }

    It 'Disk: low-space Ids do not contain percentages' {
        Mock -ModuleName OmniStorageTestDisk Get-PhysicalDisk { @() }
        Mock -ModuleName OmniStorageTestDisk Get-CimInstance { @() }
        Mock -ModuleName OmniStorageTestDisk Get-Volume $script:LowVolumes
        $r = Invoke-PluginScan -Module $script:DiskMod -Context (New-TestContext)
        $ids = @($r.Findings.Id)
        $ids | Should -Contain 'disk-volume-low-space-c'
        $ids | Should -Contain 'disk-volume-low-space-d'
    }

    It 'Disk Usage: drive-full Ids do not contain percentages' {
        Mock -ModuleName OmniStorageTestUsage Get-Volume $script:LowVolumes
        Mock -ModuleName OmniStorageTestUsage Get-CimInstance { @() }
        $r = Invoke-PluginScan -Module $script:UsageMod -Context (New-TestContext)
        $ids = @($r.Findings.Id)
        $ids | Should -Contain 'disk-usage-drive-full-c'
        $ids | Should -Contain 'disk-usage-drive-full-d'
    }
}
