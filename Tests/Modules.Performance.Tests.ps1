#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Performance group: handle and thread reporting in the Processes scanner.

    Get-Process is mocked inside a uniquely named copy of the plugin (see
    Tests/Modules.NetworkProbes.Tests.ps1 for the pattern), so these tests run on any
    host and cover every handle finding path: the Warning above the threshold, the
    Information summary below it, the Idle/System exemption, and the configurable
    threshold. The finding Ids are stable (no live values).
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

    function New-FakeProcess {
        param([string] $Name, [int] $Id, [int] $Handles, [int] $Threads = 4)
        [pscustomobject]@{
            ProcessName      = $Name
            Id               = $Id
            CPU              = [double]$Id
            WorkingSet64     = [long]$Id * 1MB
            HandleCount      = $Handles
            Threads          = @(1..$Threads)
            MainWindowHandle = 0
            Responding       = $true
        }
    }

    $script:ProcMod = Import-PluginCopy -File 'Processes.psm1' -AsName 'OmniPerfTestProcesses'
}

AfterAll {
    Remove-Module -Name 'OmniPerfTestProcesses' -Force -ErrorAction SilentlyContinue
}

Describe 'Processes scanner: handles and threads' {
    It 'reports totals and the top 5 handle holders, with an Information summary below the threshold' {
        Mock -ModuleName OmniPerfTestProcesses Get-Process {
            @(
                New-FakeProcess -Name 'a' -Id 10 -Handles 100 -Threads 2
                New-FakeProcess -Name 'b' -Id 11 -Handles 900 -Threads 3
                New-FakeProcess -Name 'c' -Id 12 -Handles 50 -Threads 1
                New-FakeProcess -Name 'd' -Id 13 -Handles 400 -Threads 4
                New-FakeProcess -Name 'e' -Id 14 -Handles 700 -Threads 5
                New-FakeProcess -Name 'f' -Id 15 -Handles 300 -Threads 6
            )
        }
        $r = Invoke-PluginScan -Module $script:ProcMod -Context (New-TestContext)
        $r.Metrics['TotalHandleCount'] | Should -Be 2450
        $r.Metrics['TotalThreadCount'] | Should -Be 21
        $top = @($r.Metrics['TopHandles'])
        $top.Count | Should -Be 5
        $top[0].Name | Should -Be 'b'
        $top[0].Value | Should -Be 900
        ($top.Name -contains 'c') | Should -BeFalse
        $r.Metrics['HighHandleProcessCount'] | Should -Be 0

        $info = @($r.Findings | Where-Object Id -eq 'performance.processes.handle-summary')
        $info.Count | Should -Be 1
        $info[0].Severity | Should -Be 'Information'
        $info[0].Detail | Should -Match '2450 handles and 21 threads'
        @($r.Findings | Where-Object Id -eq 'performance.processes.handle-count-high').Count | Should -Be 0
        @($r.Findings | Where-Object Severity -eq 'Pass').Count | Should -Be 1
    }

    It 'warns when a process exceeds 10,000 handles, with a stable Id' {
        Mock -ModuleName OmniPerfTestProcesses Get-Process {
            @(
                New-FakeProcess -Name 'leaky' -Id 4321 -Handles 25000
                New-FakeProcess -Name 'fine' -Id 22 -Handles 800
            )
        }
        $r = Invoke-PluginScan -Module $script:ProcMod -Context (New-TestContext)
        $w = @($r.Findings | Where-Object Id -eq 'performance.processes.handle-count-high')
        $w.Count | Should -Be 1
        $w[0].Severity | Should -Be 'Warning'
        $w[0].Detail | Should -Match 'leaky \(PID 4321\): 25000'
        $w[0].Detail | Should -Not -Match 'fine'
        $w[0].Recommendation | Should -Not -BeNullOrEmpty
        $r.Metrics['HighHandleProcessCount'] | Should -Be 1
        @($r.Findings | Where-Object Id -eq 'performance.processes.handle-summary').Count | Should -Be 0
        $r.Status | Should -Be 'Warning'
    }

    It 'never warns on the Idle (0) and System (4) pseudo-processes' {
        Mock -ModuleName OmniPerfTestProcesses Get-Process {
            @(
                New-FakeProcess -Name 'Idle' -Id 0 -Handles 0
                New-FakeProcess -Name 'System' -Id 4 -Handles 60000
                New-FakeProcess -Name 'app' -Id 30 -Handles 500
            )
        }
        $r = Invoke-PluginScan -Module $script:ProcMod -Context (New-TestContext)
        @($r.Findings | Where-Object Id -eq 'performance.processes.handle-count-high').Count | Should -Be 0
        @($r.Metrics['TopHandles'])[0].Name | Should -Be 'System'
        @($r.Findings | Where-Object Id -eq 'performance.processes.handle-summary').Count | Should -Be 1
    }

    It 'honors Config.HandleWarnCount' {
        Mock -ModuleName OmniPerfTestProcesses Get-Process { @(New-FakeProcess -Name 'app' -Id 30 -Handles 1500) }
        $r = Invoke-PluginScan -Module $script:ProcMod -Context (New-TestContext -Config @{ HandleWarnCount = 1000 })
        $w = @($r.Findings | Where-Object Id -eq 'performance.processes.handle-count-high')
        $w.Count | Should -Be 1
        $w[0].Title | Should -Match '1000'
    }

    It 'tolerates processes without handle or thread data' {
        Mock -ModuleName OmniPerfTestProcesses Get-Process {
            @([pscustomobject]@{ ProcessName = 'ghost'; Id = 99; CPU = $null; WorkingSet64 = 0; MainWindowHandle = 0; Responding = $true })
        }
        $r = Invoke-PluginScan -Module $script:ProcMod -Context (New-TestContext)
        $r.Metrics['TotalHandleCount'] | Should -Be 0
        $r.Metrics['TotalThreadCount'] | Should -Be 0
        $r.Error | Should -BeNullOrEmpty
    }

    It 'keeps the existing finding Ids' {
        Mock -ModuleName OmniPerfTestProcesses Get-Process { @(New-FakeProcess -Name 'app' -Id 30 -Handles 10) }
        $r = Invoke-PluginScan -Module $script:ProcMod -Context (New-TestContext)
        @($r.Findings | Where-Object Id -eq 'performance-processes-top-resource-consumers').Count | Should -Be 1
        @($r.Findings | Where-Object Id -eq 'performance-processes-process-inventory-collected').Count | Should -Be 1
    }
}
