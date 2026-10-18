#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Updates group scanners, with mocked data sources (runs on any platform).

    Update History (updates.update-history): last-install grading (Pass / Warning /
    Error / none recorded), failed and aborted installs grouped by update with the most
    recent failure and its HRESULT in hex, the time-range and entry bounds, later
    successful installs downgrading a failure to Information, the Get-HotFix fallback,
    and nothing available. The WUA COM reader is a private helper mocked inside a
    uniquely named copy of the plugin; the source is also checked to call history
    methods only (never IUpdateSearcher.Search).

    Windows Health is the single pending-reboot check; System Health no longer emits a
    pending-reboot finding. Neither scanner runs SFC or DISM.
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
        param([hashtable] $Config = @{}, [System.Threading.CancellationToken] $Token = [System.Threading.CancellationToken]::None)
        New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -Config $Config -CancellationToken $Token `
            -TimeRange (Get-OmniTimeRange -Preset Last30Days)
    }

    function Invoke-PluginScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    function New-HistoryEntry {
        param([int] $DaysAgo, [string] $Title, [int] $ResultCode = 2, [int] $Operation = 1, [object] $HResult = 0, [string] $UpdateId = '')
        [pscustomobject]@{
            Date = (Get-Date).AddDays(-$DaysAgo); Title = $Title; Operation = $Operation
            ResultCode = $ResultCode; HResult = $HResult; UpdateId = $UpdateId
        }
    }

    function New-History {
        param([object[]] $Entries, [int] $Total = -1)
        if ($Total -lt 0) { $Total = @($Entries).Count }
        [pscustomobject]@{ TotalCount = $Total; Entries = @($Entries) }
    }

    $script:HistMod = Import-PluginCopy -File 'UpdateHistory.psm1' -AsName 'OmniUpdatesTestHistory'
    $script:WinHealthMod = Import-PluginCopy -File 'WindowsHealth.psm1' -AsName 'OmniUpdatesTestWinHealth'
    $script:SysHealthMod = Import-PluginCopy -File 'SystemHealth.psm1' -AsName 'OmniUpdatesTestSysHealth'
}

AfterAll {
    foreach ($n in @('OmniUpdatesTestHistory', 'OmniUpdatesTestWinHealth', 'OmniUpdatesTestSysHealth')) {
        Remove-Module -Name $n -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Update History scanner: contract and safety' {
    It 'is a local-only updates scanner' {
        $m = & $script:HistMod { Get-OmniModuleManifest }
        $m.Id | Should -Be 'updates.update-history'
        $m.Group | Should -Be 'updates'
        $m.NetworkAccess | Should -Be 'None'
        $m.RequiresAdmin | Should -BeFalse
    }

    It 'reads history only and never searches online' {
        $src = Get-Content -LiteralPath (Join-Path $script:Root 'src/Modules/UpdateHistory.psm1') -Raw
        $src | Should -Match '\.QueryHistory\('
        $src | Should -Match '\.GetTotalHistoryCount\('
        $src | Should -Not -Match '\.Search\('
        $src | Should -Not -Match '(?i)BeginSearch|CreateUpdateDownloader|CreateUpdateInstaller|Get-WindowsUpdate'
    }

    It 'formats HRESULTs as 8-digit hex, signed or unsigned' {
        & $script:HistMod { ConvertTo-OmniHResultHex -HResult (-2145124329) } | Should -Be '0x80240017'
        & $script:HistMod { ConvertTo-OmniHResultHex -HResult ([uint32]2149842967) } | Should -Be '0x80240017'
        & $script:HistMod { ConvertTo-OmniHResultHex -HResult 0 } | Should -Be '0x00000000'
        & $script:HistMod { ConvertTo-OmniHResultHex -HResult $null } | Should -Be ''
    }

    It 'groups by KB number, else by title without a version suffix' {
        & $script:HistMod { Get-OmniUpdateGroupKey -Title '2026-09 Cumulative Update (KB5012345)' -UpdateId 'x' } | Should -Be 'KB5012345'
        & $script:HistMod { Get-OmniUpdateGroupKey -Title 'Contoso Driver Update (Version 1.2.3)' -UpdateId 'x' } | Should -Be 'Contoso Driver Update'
        & $script:HistMod { Get-OmniUpdateGroupKey -Title '' -UpdateId 'abc' } | Should -Be 'abc'
        & $script:HistMod { ConvertTo-OmniUpdateFindingId -Key 'KB5012345' } | Should -Be 'update-history-failed-kb5012345'
    }

    It 'caps the entries it asks for at 200' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry { New-History -Entries @(New-HistoryEntry 3 'Update (KB5000001)') }
        Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext -Config @{ UpdateHistoryMaxEntries = 5000 }) | Out-Null
        Should -Invoke -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry -Times 1 -Exactly -ParameterFilter { $MaxEntries -eq 200 }
        Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext) | Out-Null
        Should -Invoke -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry -Times 2 -Exactly -ParameterFilter { $MaxEntries -eq 200 }
        Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext -Config @{ UpdateHistoryMaxEntries = 10 }) | Out-Null
        Should -Invoke -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry -Times 1 -Exactly -ParameterFilter { $MaxEntries -eq 10 }
    }
}

Describe 'Update History scanner: last successful install' {
    It 'passes when an update installed recently, and adds a summary' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry {
            New-History -Total 350 -Entries @((New-HistoryEntry 5 'Cumulative Update (KB5000001)'), (New-HistoryEntry 40 'Older (KB5000000)'))
        }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        ($r.Findings | Where-Object Id -eq 'update-history-last-install-recent').Severity | Should -Be 'Pass'
        $sum = @($r.Findings | Where-Object Id -eq 'update-history-summary')
        $sum.Count | Should -Be 1
        $sum[0].Severity | Should -Be 'Information'
        $sum[0].Detail | Should -Match 'Read 2 of 350'
        $r.Metrics['HistorySource'] | Should -Be 'Windows Update Agent'
        $r.Metrics['LastSuccessfulInstallAgeDays'] | Should -Be 5
        $r.Status | Should -Be 'Healthy'
    }

    It 'counts "succeeded with errors" as an install and ignores uninstalls' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry {
            New-History -Entries @((New-HistoryEntry 2 'Removed (KB5000009)' -Operation 2), (New-HistoryEntry 10 'Partial (KB5000002)' -ResultCode 3))
        }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $r.Metrics['LastSuccessfulInstallAgeDays'] | Should -Be 10
    }

    It 'warns when the last install is older than 45 days' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry { New-History -Entries @(New-HistoryEntry 60 'Old (KB5000001)') }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'update-history-last-install-stale')
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Title | Should -Not -Match '60'
        $r.Status | Should -Be 'Warning'
    }

    It 'raises an Error when the last install is older than 90 days, with the same Id' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry { New-History -Entries @(New-HistoryEntry 120 'Ancient (KB5000001)') }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'update-history-last-install-stale')
        $f[0].Severity | Should -Be 'Error'
        $f[0].Detail | Should -Match '120 days ago'
    }

    It 'warns when the history has no successful install' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry { New-History -Entries @() }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        ($r.Findings | Where-Object Id -eq 'update-history-no-successful-install').Severity | Should -Be 'Warning'
        ($r.Findings | Where-Object Id -eq 'update-history-summary').Detail | Should -Match 'none recorded'
    }
}

Describe 'Update History scanner: failed installs' {
    It 'groups failures by update with the most recent failure and its error in hex' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry {
            New-History -Entries @(
                (New-HistoryEntry 1 'Good (KB5000100)')
                (New-HistoryEntry 2 '2026-10 Cumulative Update (KB5000200)' -ResultCode 4 -HResult (-2145124329))
                (New-HistoryEntry 6 '2026-10 Cumulative Update (KB5000200)' -ResultCode 4 -HResult (-2147024784))
                (New-HistoryEntry 8 'Contoso Driver (Version 2.0.1)' -ResultCode 5 -HResult (-2145116147))
                (New-HistoryEntry 9 'Contoso Driver (Version 2.0.0)' -ResultCode 4 -HResult (-2145116147))
            )
        }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $kb = @($r.Findings | Where-Object Id -eq 'update-history-failed-kb5000200')
        $kb.Count | Should -Be 1
        $kb[0].Severity | Should -Be 'Warning'
        $kb[0].Detail | Should -Match 'failed 2 time'
        $kb[0].Detail | Should -Match '0x80240017'
        $kb[0].Data.HResult | Should -Be '0x80240017'
        $drv = @($r.Findings | Where-Object Id -eq 'update-history-failed-contoso-driver')
        $drv.Count | Should -Be 1
        $drv[0].Detail | Should -Match 'aborted 2 time'
        $r.Metrics['FailedInstallsInRange'] | Should -Be 4
        $r.Metrics['FailedUpdates'] | Should -Be 2
        $r.Status | Should -Be 'Warning'
    }

    It 'downgrades a failure to Information when the update installed later' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry {
            New-History -Entries @(
                (New-HistoryEntry 1 'Cumulative Update (KB5000300)')
                (New-HistoryEntry 3 'Cumulative Update (KB5000300)' -ResultCode 4 -HResult 0x80070005)
            )
        }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'update-history-failed-kb5000300')
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match 'installed successfully afterwards'
        $r.Status | Should -Be 'Healthy'
    }

    It 'ignores failures outside the scan time range' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry {
            New-History -Entries @(
                (New-HistoryEntry 1 'Good (KB5000100)')
                (New-HistoryEntry 40 'Old failure (KB5000400)' -ResultCode 4 -HResult 1)
            )
        }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        @($r.Findings | Where-Object Id -like 'update-history-failed-*').Count | Should -Be 0
        $r.Metrics['FailedInstallsInRange'] | Should -Be 0
    }

    It 'stops before grading when the scan is cancelled' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry { New-History -Entries @(New-HistoryEntry 1 'Good (KB5000100)') }
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext -Token $cts.Token)
        @($r.Findings).Count | Should -Be 0
    }
}

Describe 'Update History scanner: fallbacks' {
    It 'falls back to Get-HotFix when the COM API is unavailable' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry { throw 'Class not registered' }
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryHotFixDate { (Get-Date).AddDays(-100) }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $r.Metrics['HistorySource'] | Should -Be 'Get-HotFix'
        ($r.Findings | Where-Object Id -eq 'update-history-last-install-stale').Severity | Should -Be 'Error'
        ($r.Findings | Where-Object Id -eq 'update-history-com-unavailable').Severity | Should -Be 'Information'
    }

    It 'reports Information when neither source is available' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry { throw 'Class not registered' }
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryHotFixDate { throw 'not supported' }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        @($r.Findings).Count | Should -Be 1
        $r.Findings[0].Id | Should -Be 'update-history-not-available'
        $r.Findings[0].Severity | Should -Be 'Information'
    }

    It 'reports Information when the hotfix list has no dates' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry { throw 'Class not registered' }
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryHotFixDate { $null }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $r.Findings[0].Id | Should -Be 'update-history-not-available'
    }
}

Describe 'Pending reboot: one authoritative check' {
    BeforeAll {
        # Windows Health also queries CIM and services; make those return nothing.
        $stubBody = [scriptblock]::Create('[CmdletBinding()] param([Parameter(ValueFromRemainingArguments)] $Rest) ')
        $script:Stubbed = [System.Collections.Generic.List[string]]::new()
        foreach ($n in @('Get-CimInstance', 'Get-Service')) {
            if (-not (Get-Command -Name $n -ErrorAction SilentlyContinue)) {
                Set-Item -Path "function:global:$n" -Value $stubBody
                $script:Stubbed.Add($n)
            }
        }
    }

    AfterAll {
        foreach ($n in $script:Stubbed) { Remove-Item -Path "function:global:$n" -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        Mock -ModuleName OmniUpdatesTestWinHealth Get-CimInstance { @() }
        Mock -ModuleName OmniUpdatesTestWinHealth Get-Service { throw 'no service manager' }
    }

    It 'Windows Health raises the pending-reboot Warning with a stable Id' {
        Mock -ModuleName OmniUpdatesTestWinHealth Test-OmniPendingReboot { [string[]]@('Windows Update', 'Pending file rename') }
        $r = Invoke-PluginScan -Module $script:WinHealthMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'windows-health-pending-reboot')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Detail | Should -Match 'Windows Update, Pending file rename'
        $r.Metrics['PendingReboot'] | Should -BeTrue
        $r.Metrics['PendingRebootReasons'] | Should -Be 'Windows Update; Pending file rename'
    }

    It 'Windows Health passes without a pending reboot' {
        Mock -ModuleName OmniUpdatesTestWinHealth Test-OmniPendingReboot { [string[]]@() }
        $r = Invoke-PluginScan -Module $script:WinHealthMod -Context (New-TestContext)
        @($r.Findings | Where-Object Id -eq 'windows-health-pending-reboot').Count | Should -Be 0
        $r.Metrics['PendingReboot'] | Should -BeFalse
        @($r.Findings | Where-Object Severity -eq 'Pass').Count | Should -Be 1
    }

    It 'System Health emits no pending-reboot finding and points to Windows Health' {
        $r = Invoke-PluginScan -Module $script:SysHealthMod -Context (New-TestContext)
        @($r.Findings | Where-Object { $_.Title -match '(?i)reboot|restart' }).Count | Should -Be 0
        $r.Metrics['PendingRebootCheckedBy'] | Should -Be 'updates.windows-health'
        $r.Metrics.Contains('PendingReboot') | Should -BeFalse
        @($r.Findings).Count | Should -Be 1
        $r.Findings[0].Id | Should -BeIn @('system-health-servicing-log', 'system-health-servicing-log-not-found')
    }

    It 'every workflow that runs System Health for reboot state also runs Windows Health' {
        $plans = @(Get-OmniRoleProfile) + @(Get-OmniTaskWorkflow)
        foreach ($p in $plans) {
            if ($p.Name -eq 'StorageCleanup') { continue }
            if (@($p.Modules) -contains 'System Health') { @($p.Modules) | Should -Contain 'Windows Health' -Because "$($p.Name) relied on System Health for pending reboot" }
        }
    }
}

Describe 'Scanners never run repair tools' {
    It '<File> does not run SFC or DISM and has no RunSfc / RunDism option' -ForEach @(
        @{ File = 'WindowsHealth.psm1' }
        @{ File = 'SystemHealth.psm1' }
        @{ File = 'UpdateHistory.psm1' }
        @{ File = 'WindowsUpdate.psm1' }
    ) {
        $src = Get-Content -LiteralPath (Join-Path $script:Root "src/Modules/$File") -Raw
        $src | Should -Not -Match '(?i)sfc\.exe|sfc\s+/(verifyonly|scannow)'
        $src | Should -Not -Match '(?i)dism(\.exe)?\s+/'
        $src | Should -Not -Match 'RunSfc|RunDism'
    }
}
