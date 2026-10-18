#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Reliability group: Reliability (bounded event counts), Reliability Monitor
    (Win32_ReliabilityStabilityMetrics / Win32_ReliabilityRecords), and Crash Dumps
    (Minidump / MEMORY.DMP inventory + CrashControl settings).

    Each plugin is copied to TestDrive under a unique name and its private data-source
    helpers are mocked inside the plugin's module scope (the pattern of
    Tests/Modules.NetworkProbes.Tests.ps1), so every finding path runs on any host.
    Get-WinEvent and Get-CimInstance do not exist off Windows; when missing, a stub is
    defined inside the plugin copy (never globally) so the bounded-query tests can mock
    them.
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
        param([hashtable] $Config = @{}, [string] $Preset = 'Last7Days')
        New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -TimeRange (Get-OmniTimeRange -Preset $Preset) -Config $Config
    }

    function Invoke-PluginScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    function New-RelRecord {
        param([string] $Source, [int] $EventId, [string] $Product = $null, [string[]] $Strings = @(), [datetime] $Time = (Get-Date).AddDays(-1))
        [pscustomobject]@{ SourceName = $Source; EventIdentifier = $EventId; ProductName = $Product; InsertionStrings = $Strings; TimeGenerated = $Time; Logfile = 'Application'; RecordNumber = 1 }
    }

    function New-Sample {
        param([double] $Index, [datetime] $Time)
        [pscustomobject]@{ SystemStabilityIndex = $Index; TimeGenerated = $Time }
    }

    function New-DumpFile {
        param([string] $Name, [datetime] $Time, [long] $Length = 256KB)
        [pscustomobject]@{ Name = $Name; LastWriteTime = $Time; Length = $Length }
    }

    $script:RelMod = Import-PluginCopy -File 'Reliability.psm1' -AsName 'OmniRelTestReliability'
    $script:MonMod = Import-PluginCopy -File 'ReliabilityMonitor.psm1' -AsName 'OmniRelTestMonitor'
    $script:DumpMod = Import-PluginCopy -File 'CrashDumps.psm1' -AsName 'OmniRelTestDumps'

    # Off Windows, give the plugin copies a stub to mock (Pester mocks only existing commands).
    if (-not (Get-Command -Name 'Get-WinEvent' -ErrorAction SilentlyContinue)) {
        & $script:RelMod { function script:Get-WinEvent { [CmdletBinding()] param([hashtable[]] $FilterHashtable, [int] $MaxEvents) throw 'stub' } }
    }
    if (-not (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
        & $script:MonMod { function script:Get-CimInstance { [CmdletBinding()] param([string] $Namespace, [string] $ClassName, [string] $Filter, [string[]] $Property) throw 'stub' } }
    }
}

AfterAll {
    foreach ($n in @('OmniRelTestReliability', 'OmniRelTestMonitor', 'OmniRelTestDumps')) { Remove-Module -Name $n -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
Describe 'Reliability scanner (bounded event counts)' {
    BeforeEach {
        Mock -ModuleName OmniRelTestReliability Test-OmniReliabilityWindowsHost { $true }
    }

    It 'never calls Get-WinEvent without -MaxEvents (static check)' {
        $path = Join-Path $script:Root 'src/Modules/Reliability.psm1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-WinEvent' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'MaxEvents' }).Count | Should -Be 1
        }
    }

    It 'passes MaxEvents and the time range to Get-WinEvent' {
        Mock -ModuleName OmniRelTestReliability Get-WinEvent { @(1, 2, 3) }
        $n = & $script:RelMod { Get-OmniReliabilityEventCount -Filter @{ LogName = 'System'; Id = 41; StartTime = (Get-Date).AddDays(-1); EndTime = (Get-Date) } -MaxEvents 25 }
        $n | Should -Be 3
        Should -Invoke -ModuleName OmniRelTestReliability Get-WinEvent -Times 1 -Exactly -ParameterFilter {
            $MaxEvents -eq 25 -and $FilterHashtable.ContainsKey('StartTime') -and $FilterHashtable.ContainsKey('EndTime')
        }
    }

    It 'treats a failed query (no events) as zero' {
        Mock -ModuleName OmniRelTestReliability Get-WinEvent { throw 'No events were found' }
        & $script:RelMod { Get-OmniReliabilityEventCount -Filter @{ LogName = 'System' } -MaxEvents 5 } | Should -Be 0
    }

    It 'bounds every count by the range and the cap, and reports a healthy machine' {
        Mock -ModuleName OmniRelTestReliability Get-OmniReliabilityEventCount { 0 }
        $ctx = New-TestContext -Config @{ ReliabilityMaxEvents = 50 }
        $r = Invoke-PluginScan -Module $script:RelMod -Context $ctx
        Should -Invoke -ModuleName OmniRelTestReliability Get-OmniReliabilityEventCount -Times 3 -Exactly -ParameterFilter {
            $MaxEvents -eq 50 -and $Filter.StartTime -eq $ctx.TimeRange.Start -and $Filter.EndTime -eq $ctx.TimeRange.End
        }
        $r.Metrics['EventCountsCapped'] | Should -BeFalse
        @($r.Findings | Where-Object Id -eq 'reliability.reliability.healthy').Count | Should -Be 1
    }

    It 'keeps the crash and shutdown findings and flags capped counts' {
        Mock -ModuleName OmniRelTestReliability Get-OmniReliabilityEventCount { 10 }
        $r = Invoke-PluginScan -Module $script:RelMod -Context (New-TestContext -Config @{ ReliabilityMaxEvents = 10 })
        $r.Metrics['AppCrashes'] | Should -Be 10
        $r.Metrics['EventCountsCapped'] | Should -BeTrue
        $c = @($r.Findings | Where-Object Id -eq 'reliability.reliability.app-crashes')
        $c.Count | Should -Be 1
        $c[0].Title | Should -Match '10 application crashes'
        $c[0].Detail | Should -Match 'lower bounds'
        @($r.Findings | Where-Object Id -eq 'reliability.reliability.unexpected-shutdowns').Count | Should -Be 1
        $r.Status | Should -Be 'Warning'
    }

    It 'returns an Information finding off Windows' {
        Mock -ModuleName OmniRelTestReliability Test-OmniReliabilityWindowsHost { $false }
        $r = Invoke-PluginScan -Module $script:RelMod -Context (New-TestContext)
        $r.Findings[0].Id | Should -Be 'reliability.reliability.platform'
        $r.Findings[0].Severity | Should -Be 'Information'
    }
}

# ---------------------------------------------------------------------------
# The query helpers themselves (the scanner tests below mock them out in BeforeEach).
Describe 'Reliability Monitor queries' {
    It 'queries both classes with a TimeGenerated WHERE clause and caps the count' {
        Mock -ModuleName OmniRelTestMonitor Get-CimInstance { 1..10 | ForEach-Object { New-Sample -Index 9 -Time (Get-Date) } }
        $rows = & $script:MonMod { Get-OmniRelMonStabilityMetric -Start (Get-Date).AddDays(-7) -End (Get-Date) -MaxRecords 4 }
        @($rows).Count | Should -Be 4
        $null = & $script:MonMod { Get-OmniRelMonRecord -Start (Get-Date).AddDays(-7) -End (Get-Date) -MaxRecords 4 }
        Should -Invoke -ModuleName OmniRelTestMonitor Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_ReliabilityStabilityMetrics' -and $Filter -match "^TimeGenerated >= '\d{14}\.\d{6}\+000' AND TimeGenerated <= "
        }
        Should -Invoke -ModuleName OmniRelTestMonitor Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_ReliabilityRecords' -and $Filter -match '^TimeGenerated >= '
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Reliability Monitor scanner' {
    BeforeEach {
        Mock -ModuleName OmniRelTestMonitor Test-OmniRelMonWindowsHost { $true }
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric { @() }
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord { @() }
    }

    It 'formats the WQL time filter in UTC DMTF form' {
        $s = & $script:MonMod { ConvertTo-OmniWmiDateTime -Value ([datetime]::new(2026, 10, 1, 12, 30, 5, [System.DateTimeKind]::Utc)) }
        $s | Should -Be '20261001123005.000000+000'
        $f = & $script:MonMod { Get-OmniRelMonTimeFilter -Start ([datetime]::new(2026, 10, 1, 0, 0, 0, [System.DateTimeKind]::Utc)) -End ([datetime]::new(2026, 10, 8, 0, 0, 0, [System.DateTimeKind]::Utc)) }
        $f | Should -Be "TimeGenerated >= '20261001000000.000000+000' AND TimeGenerated <= '20261008000000.000000+000'"
    }

    It 'explains that data collection is disabled when both classes are empty' {
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.no-data')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match 'RacTask'
        $r.Findings.Count | Should -Be 1
    }

    It 'passes the context range and the configured caps to the queries' {
        $ctx = New-TestContext -Config @{ ReliabilityMaxRecords = 77; MaxStabilitySamples = 33 }
        $null = Invoke-PluginScan -Module $script:MonMod -Context $ctx
        Should -Invoke -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord -Times 1 -Exactly -ParameterFilter { $MaxRecords -eq 77 -and $Start -eq $ctx.TimeRange.Start -and $End -eq $ctx.TimeRange.End }
        Should -Invoke -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric -Times 1 -Exactly -ParameterFilter { $MaxRecords -eq 33 }
    }

    It 'reports a healthy index as Pass with the trend' {
        $now = Get-Date
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric { @((New-Sample -Index 9.5 -Time $now), (New-Sample -Index 7 -Time $now.AddDays(-3))) }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.stability-index')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Pass'
        $r.Metrics['StabilityIndexLatest'] | Should -Be 9.5
        $r.Metrics['StabilityIndexMin'] | Should -Be 7
        $r.Metrics['StabilityTrend'] | Should -Be 'Improving'
        @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.no-stability-data').Count | Should -Be 0
        @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.no-failures').Count | Should -Be 1
    }

    It 'warns below 5 and reports a declining trend' {
        $now = Get-Date
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric { @((New-Sample -Index 8 -Time $now.AddDays(-2)), (New-Sample -Index 4.2 -Time $now)) }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.stability-index')
        $f[0].Severity | Should -Be 'Warning'
        $r.Metrics['StabilityTrend'] | Should -Be 'Declining'
    }

    It 'raises an Error below 3' {
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric { @(New-Sample -Index 2.1 -Time (Get-Date)) }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.stability-index')
        $f[0].Severity | Should -Be 'Error'
        $r.Metrics['StabilityTrend'] | Should -Be 'Unknown'
        $r.Status | Should -Be 'Critical'
    }

    It 'summarizes failures by category and source' {
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric { @(New-Sample -Index 6 -Time (Get-Date)) }
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord {
            $list = @()
            1..5 | ForEach-Object { $list += New-RelRecord -Source 'Application Error' -EventId 1000 -Product 'contoso.exe' }
            $list += New-RelRecord -Source 'Application Hang' -EventId 1002 -Product 'fabrikam.exe'
            $list += New-RelRecord -Source 'Microsoft-Windows-WER-SystemErrorReporting' -EventId 1001
            $list += New-RelRecord -Source 'EventLog' -EventId 6008
            $list += New-RelRecord -Source 'Microsoft-Windows-WHEA-Logger' -EventId 17
            $list += New-RelRecord -Source 'Windows Error Reporting' -EventId 1001 -Strings @('bucket', '5', 'LiveKernelEvent')
            $list += New-RelRecord -Source 'Windows Error Reporting' -EventId 1001 -Strings @('bucket', '5', 'APPCRASH')
            $list += New-RelRecord -Source 'Microsoft-Windows-WindowsUpdateClient' -EventId 20 -Product 'KB5000001'
            $list += New-RelRecord -Source 'MsiInstaller' -EventId 11708 -Product 'Contoso Agent'
            $list += New-RelRecord -Source 'MsiInstaller' -EventId 11707 -Product 'Contoso Tools'
            $list
        }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        $r.Metrics['ApplicationFailures'] | Should -Be 6
        $r.Metrics['WindowsFailures'] | Should -Be 2
        $r.Metrics['HardwareFailures'] | Should -Be 2
        $r.Metrics['FailedInstalls'] | Should -Be 2
        $r.Metrics['SuccessfulInstalls'] | Should -Be 1

        $app = @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.application-failures')
        $app[0].Severity | Should -Be 'Warning'
        $app[0].Detail | Should -Match 'contoso\.exe \(Application Error\) x5'
        @($app[0].Data)[0].Count | Should -Be 5
        (@($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.windows-failures'))[0].Severity | Should -Be 'Warning'
        (@($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.hardware-failures'))[0].Severity | Should -Be 'Warning'
        (@($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.failed-installs'))[0].Severity | Should -Be 'Information'
        @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.no-failures').Count | Should -Be 0
    }

    It 'reports few application failures and many failed installs at the right severities' {
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric { @(New-Sample -Index 8 -Time (Get-Date)) }
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord {
            @(
                New-RelRecord -Source 'Application Error' -EventId 1000 -Product 'contoso.exe'
                New-RelRecord -Source 'Microsoft-Windows-WindowsUpdateClient' -EventId 20 -Product 'KB1'
                New-RelRecord -Source 'Microsoft-Windows-WindowsUpdateClient' -EventId 20 -Product 'KB2'
                New-RelRecord -Source 'Microsoft-Windows-WindowsUpdateClient' -EventId 20 -Product 'KB3'
            )
        }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        (@($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.application-failures'))[0].Severity | Should -Be 'Information'
        (@($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.failed-installs'))[0].Severity | Should -Be 'Warning'
    }

    It 'notes a missing stability index when only records exist' {
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord { @(New-RelRecord -Source 'MsiInstaller' -EventId 11707) }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.no-stability-data').Count | Should -Be 1
        @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.no-failures').Count | Should -Be 1
    }

    It 'says "requires elevation" when access is denied' {
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord { throw [System.UnauthorizedAccessException]::new('Access denied') }
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric { @(New-Sample -Index 9 -Time (Get-Date)) }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.requires-elevation')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match 'requires elevation'
        @($r.Findings | Where-Object Id -eq 'reliability.reliability-monitor.no-failures').Count | Should -Be 0
        $r.Error | Should -BeNullOrEmpty
    }

    It 'reports the classes as unavailable when the queries fail' {
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord { throw 'Invalid class' }
        Mock -ModuleName OmniRelTestMonitor Get-OmniRelMonStabilityMetric { throw 'Invalid class' }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        $r.Findings.Count | Should -Be 1
        $r.Findings[0].Id | Should -Be 'reliability.reliability-monitor.unavailable'
        $r.Findings[0].Severity | Should -Be 'Information'
    }

    It 'stops early when cancelled' {
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -CancellationToken $cts.Token
        $r = Invoke-PluginScan -Module $script:MonMod -Context $ctx
        $r.Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord -Times 0 -Exactly
    }

    It 'returns an Information finding off Windows' {
        Mock -ModuleName OmniRelTestMonitor Test-OmniRelMonWindowsHost { $false }
        $r = Invoke-PluginScan -Module $script:MonMod -Context (New-TestContext)
        $r.Findings[0].Id | Should -Be 'reliability.reliability-monitor.platform'
        Should -Invoke -ModuleName OmniRelTestMonitor Get-OmniRelMonRecord -Times 0 -Exactly
    }
}

# ---------------------------------------------------------------------------
Describe 'Crash Dumps scanner' {
    BeforeEach {
        Mock -ModuleName OmniRelTestDumps Test-OmniCrashDumpWindowsHost { $true }
        Mock -ModuleName OmniRelTestDumps Get-OmniCrashControlSetting {
            [pscustomobject]@{ CrashDumpEnabled = 7; DumpFile = 'C:\Windows\MEMORY.DMP'; MinidumpDir = 'C:\Windows\Minidump'; AutoReboot = 1 }
        }
        Mock -ModuleName OmniRelTestDumps Get-OmniMinidumpFile { @() }
        Mock -ModuleName OmniRelTestDumps Get-OmniMemoryDumpFile { $null }
    }

    It 'passes when there are no dumps and reports the settings' {
        $r = Invoke-PluginScan -Module $script:DumpMod -Context (New-TestContext)
        @($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.none').Count | Should -Be 1
        $s = @($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.settings')
        $s[0].Severity | Should -Be 'Information'
        $s[0].Detail | Should -Match 'Automatic memory dump'
        $r.Metrics['CrashDumpType'] | Should -Be 'Automatic memory dump'
        $r.Metrics['AutoReboot'] | Should -BeTrue
        $r.Metrics['MinidumpCount'] | Should -Be 0
        $r.Metrics['MemoryDumpExists'] | Should -BeFalse
        Should -Invoke -ModuleName OmniRelTestDumps Get-OmniMinidumpFile -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Windows\Minidump' }
        Should -Invoke -ModuleName OmniRelTestDumps Get-OmniMemoryDumpFile -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Windows\MEMORY.DMP' }
    }

    It 'warns on dumps written in the range and lists the 5 most recent' {
        $now = Get-Date
        Mock -ModuleName OmniRelTestDumps Get-OmniMinidumpFile {
            @(
                New-DumpFile -Name 'old1.dmp' -Time $now.AddDays(-60)
                New-DumpFile -Name 'new1.dmp' -Time $now.AddDays(-1)
                New-DumpFile -Name 'new2.dmp' -Time $now.AddDays(-2)
                New-DumpFile -Name 'old2.dmp' -Time $now.AddDays(-40)
                New-DumpFile -Name 'old3.dmp' -Time $now.AddDays(-50)
                New-DumpFile -Name 'old4.dmp' -Time $now.AddDays(-70)
                New-DumpFile -Name 'old5.dmp' -Time $now.AddDays(-80)
            )
        }
        Mock -ModuleName OmniRelTestDumps Get-OmniMemoryDumpFile { New-DumpFile -Name 'MEMORY.DMP' -Time $now.AddDays(-1) -Length 800MB }
        $r = Invoke-PluginScan -Module $script:DumpMod -Context (New-TestContext)
        $w = @($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.recent-dumps')
        $w.Count | Should -Be 1
        $w[0].Severity | Should -Be 'Warning'
        $w[0].Detail | Should -Match '2 minidump\(s\) and a full/kernel memory dump'
        $w[0].Recommendation | Should -Match 'WinDbg'
        $w[0].Recommendation | Should -Match 'BugCheck'
        $r.Metrics['MinidumpCount'] | Should -Be 7
        $r.Metrics['RecentDumpCount'] | Should -Be 3
        $r.Metrics['MemoryDumpSizeMB'] | Should -Be 800
        $recent = @($r.Metrics['RecentMinidumps'])
        $recent.Count | Should -Be 5
        $recent[0].Name | Should -Be 'new1.dmp'
        $r.Metrics['MinidumpNewest'] | Should -Be $now.AddDays(-1)
        $r.Status | Should -Be 'Warning'
    }

    It 'reports only older dumps as Information' {
        Mock -ModuleName OmniRelTestDumps Get-OmniMinidumpFile { @(New-DumpFile -Name 'old.dmp' -Time (Get-Date).AddDays(-90)) }
        $r = Invoke-PluginScan -Module $script:DumpMod -Context (New-TestContext)
        $i = @($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.inventory')
        $i.Count | Should -Be 1
        $i[0].Severity | Should -Be 'Information'
        @($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.recent-dumps').Count | Should -Be 0
    }

    It 'says "requires elevation" when the Minidump folder is denied' {
        Mock -ModuleName OmniRelTestDumps Get-OmniMinidumpFile { throw [System.UnauthorizedAccessException]::new('Access denied') }
        $r = Invoke-PluginScan -Module $script:DumpMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.requires-elevation')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match 'requires elevation'
        $r.Metrics['MinidumpCount'] | Should -BeNullOrEmpty
        @($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.none').Count | Should -Be 0
        $r.Error | Should -BeNullOrEmpty
    }

    It 'flags disabled crash dumps and names the dump types' {
        Mock -ModuleName OmniRelTestDumps Get-OmniCrashControlSetting { [pscustomobject]@{ CrashDumpEnabled = 0; AutoReboot = 0 } }
        $r = Invoke-PluginScan -Module $script:DumpMod -Context (New-TestContext)
        $s = @($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.settings')
        $s[0].Title | Should -Be 'Crash dumps are disabled'
        $s[0].Recommendation | Should -Not -BeNullOrEmpty
        $r.Metrics['AutoReboot'] | Should -BeFalse
        & $script:DumpMod { Get-OmniCrashDumpTypeName -CrashDumpEnabled 1 -FilterPages 1 } | Should -Be 'Active memory dump'
        & $script:DumpMod { Get-OmniCrashDumpTypeName -CrashDumpEnabled 1 -FilterPages $null } | Should -Be 'Complete memory dump'
        & $script:DumpMod { Get-OmniCrashDumpTypeName -CrashDumpEnabled 2 -FilterPages $null } | Should -Be 'Kernel memory dump'
        & $script:DumpMod { Get-OmniCrashDumpTypeName -CrashDumpEnabled 3 -FilterPages $null } | Should -Be 'Small memory dump'
    }

    It 'falls back to the default locations when CrashControl is unreadable' {
        Mock -ModuleName OmniRelTestDumps Get-OmniCrashControlSetting { $null }
        $r = Invoke-PluginScan -Module $script:DumpMod -Context (New-TestContext)
        (@($r.Findings | Where-Object Id -eq 'reliability.crash-dumps.settings'))[0].Title | Should -Be 'Crash dump settings could not be read'
        Should -Invoke -ModuleName OmniRelTestDumps Get-OmniMinidumpFile -Times 1 -Exactly -ParameterFilter { $Path -like '*Minidump' }
    }

    It 'returns an Information finding off Windows' {
        Mock -ModuleName OmniRelTestDumps Test-OmniCrashDumpWindowsHost { $false }
        $r = Invoke-PluginScan -Module $script:DumpMod -Context (New-TestContext)
        $r.Findings.Count | Should -Be 1
        $r.Findings[0].Id | Should -Be 'reliability.crash-dumps.platform'
        Should -Invoke -ModuleName OmniRelTestDumps Get-OmniMinidumpFile -Times 0 -Exactly
    }

    It 'stops early when cancelled' {
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -CancellationToken $cts.Token
        $r = Invoke-PluginScan -Module $script:DumpMod -Context $ctx
        $r.Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName OmniRelTestDumps Get-OmniMinidumpFile -Times 0 -Exactly
    }
}
