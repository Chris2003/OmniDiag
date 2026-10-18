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

    It 'groups by KB number, else by UpdateID, else by title without a version suffix' {
        & $script:HistMod { Get-OmniUpdateGroupKey -Title '2026-09 Cumulative Update (KB5012345)' -UpdateId 'x' } | Should -Be 'KB5012345'
        & $script:HistMod { Get-OmniUpdateGroupKey -Title 'Contoso Driver Update (Version 1.2.3)' -UpdateId '6A1B0C2D-0000-4E5F-9A8B-112233445566' } | Should -Be '6a1b0c2d-0000-4e5f-9a8b-112233445566'
        & $script:HistMod { Get-OmniUpdateGroupKey -Title 'Contoso Driver Update (Version 1.2.3)' -UpdateId '' } | Should -Be 'Contoso Driver Update'
        & $script:HistMod { Get-OmniUpdateGroupKey -Title '' -UpdateId 'abc' } | Should -Be 'abc'
        & $script:HistMod { ConvertTo-OmniUpdateFindingId -Key 'KB5012345' } | Should -Be 'update-history-failed-kb5012345'
    }

    It 'recognizes Defender definition updates by title or category' {
        & $script:HistMod { Test-OmniUpdateDefinitionEntry -Entry ([pscustomobject]@{ Title = 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.401.1.0)' }) } | Should -BeTrue
        & $script:HistMod { Test-OmniUpdateDefinitionEntry -Entry ([pscustomobject]@{ Title = 'Update for Microsoft Defender Antivirus antimalware platform - KB4052623 (Version 4.18.1)' }) } | Should -BeTrue
        & $script:HistMod { Test-OmniUpdateDefinitionEntry -Entry ([pscustomobject]@{ Title = 'Windows Defender - KB915597 (Definition 1.401.1.0)' }) } | Should -BeTrue
        & $script:HistMod { Test-OmniUpdateDefinitionEntry -Entry ([pscustomobject]@{ Title = 'Some vendor feed'; CategoryIds = @('e0789628-ce08-4437-be74-2495b842f43b') }) } | Should -BeTrue
        & $script:HistMod { Test-OmniUpdateDefinitionEntry -Entry ([pscustomobject]@{ Title = '2026-10 Cumulative Update (KB5000001)'; CategoryIds = @('0FA1201D-4330-4FA8-8AE9-B877473B6441') }) } | Should -BeFalse
        & $script:HistMod { Test-OmniUpdateDefinitionEntry -Entry ([pscustomobject]@{ Title = '2026-10 Cumulative Update (KB5000001)' }) } | Should -BeFalse
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

    It 'grades the last Windows update, not the last Defender definition update' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry {
            New-History -Entries @(
                (New-HistoryEntry 0 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.401.1.0)')
                (New-HistoryEntry 2 'Definition Update for Microsoft Defender Antivirus (Version 1.400.9.0)')
                (New-HistoryEntry 70 '2026-07 Cumulative Update (KB5000001)')
            )
        }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -eq 'update-history-last-install-stale')
        $f[0].Severity | Should -Be 'Warning'
        $r.Metrics['LastSuccessfulInstallAgeDays'] | Should -Be 70
        $r.Metrics['LastDefinitionUpdateAgeDays'] | Should -Be 0
    }

    It 'excludes definition updates identified by category ID' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry {
            $feed = New-HistoryEntry 1 'Feed'
            $feed | Add-Member -NotePropertyName CategoryIds -NotePropertyValue @('E0789628-CE08-4437-BE74-2495B842F43B')
            New-History -Entries @($feed, (New-HistoryEntry 70 '2026-07 Cumulative Update (KB5000001)'))
        }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        @($r.Findings | Where-Object Id -eq 'update-history-last-install-stale')[0].Severity | Should -Be 'Warning'
        $r.Metrics['LastSuccessfulInstallAgeDays'] | Should -Be 70
        $r.Metrics['LastDefinitionUpdateAgeDays'] | Should -Be 1
        ($r.Findings | Where-Object Id -eq 'update-history-summary').Detail | Should -Match 'Last definition update: \d{4}-'
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

    It 'builds the Id from UpdateID, not the versioned title, when there is no KB number' {
        Mock -ModuleName OmniUpdatesTestHistory Get-OmniUpdateHistoryEntry {
            New-History -Entries @(
                (New-HistoryEntry 2 'Contoso Driver - 10.1.2.3' -ResultCode 4 -HResult 1 -UpdateId '6A1B0C2D-0000-4E5F-9A8B-112233445566')
                (New-HistoryEntry 4 'Contoso Driver - 10.1.2.2' -ResultCode 4 -HResult 1 -UpdateId '6A1B0C2D-0000-4E5F-9A8B-112233445566')
            )
        }
        $r = Invoke-PluginScan -Module $script:HistMod -Context (New-TestContext)
        $f = @($r.Findings | Where-Object Id -like 'update-history-failed-*')
        $f.Count | Should -Be 1
        $f[0].Id | Should -Be 'update-history-failed-6a1b0c2d-0000-4e5f-9a8b-112233445566'
        $f[0].Id | Should -Not -Match '10-1-2'
        $f[0].Title | Should -Match 'Contoso Driver - 10\.1\.2\.3'
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

# New-Object has a -ComObject parameter only where COM exists (Windows); elsewhere a mock
# can't take -ComObject, so these run on the Windows CI legs only.
Describe 'Update History COM reader (New-Object mocked, reader real)' -Skip:(-not (Get-Command New-Object).Parameters.ContainsKey('ComObject')) {
    # Get-OmniUpdateHistoryEntry is NOT mocked here; only New-Object -ComObject is. The
    # fakes are shaped like the WUA objects: IUpdateHistoryEntryCollection (Count/Item),
    # IUpdateHistoryEntry(2) (Date, Operation, ResultCode, HResult, Title,
    # UpdateIdentity.UpdateID, Categories), ICategory (CategoryID).
    BeforeAll {
        function New-FakeComCollection {
            param([object[]] $Items)
            $c = [pscustomobject]@{ Count = @($Items).Count; Items = @($Items) }
            $c | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) $this.Items[$i] }
            $c
        }
        function New-FakeHistoryEntry {
            param([datetime] $Date, [string] $Title, [int] $ResultCode, [int] $HResult, [string] $UpdateId, [string[]] $Categories)
            $e = [pscustomobject]@{
                Date = $Date; Operation = 1; ResultCode = $ResultCode; HResult = $HResult; Title = $Title
                UpdateIdentity = [pscustomobject]@{ UpdateID = $UpdateId; RevisionNumber = 200 }
            }
            if ($PSBoundParameters.ContainsKey('Categories')) {
                $cats = @($Categories | ForEach-Object { [pscustomobject]@{ CategoryID = $_; Name = 'cat' } })
                $e | Add-Member -NotePropertyName Categories -NotePropertyValue (New-FakeComCollection -Items $cats)
            }
            $e
        }
        function New-FakeSession {
            param([int] $Total, [object[]] $Entries)
            $searcher = [pscustomobject]@{ Total = $Total; History = (New-FakeComCollection -Items $Entries); Asked = [System.Collections.Generic.List[object]]::new() }
            $searcher | Add-Member -MemberType ScriptMethod -Name GetTotalHistoryCount -Value { $this.Total }
            $searcher | Add-Member -MemberType ScriptMethod -Name QueryHistory -Value { param($start, $count) $this.Asked.Add(@($start, $count)); $this.History }
            $session = [pscustomobject]@{ Searcher = $searcher }
            $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { $this.Searcher }
            $session
        }
    }

    BeforeEach {
        $d1 = [datetime]'2026-10-01T08:00:00'
        $d2 = [datetime]'2026-09-15T08:00:00'
        $script:FakeSession = New-FakeSession -Total 2 -Entries @(
            (New-FakeHistoryEntry -Date $d1 -Title 'Security Intelligence Update (Version 1.401.1.0)' -ResultCode 2 -HResult 0 -UpdateId 'AAA' -Categories @('E0789628-CE08-4437-BE74-2495B842F43B'))
            (New-FakeHistoryEntry -Date $d2 -Title '2026-09 Cumulative Update (KB5000001)' -ResultCode 4 -HResult (-2145124329) -UpdateId 'BBB')
        )
        Mock -ModuleName OmniUpdatesTestHistory New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' } { $script:FakeSession }
    }

    It 'maps each COM history entry to a record' {
        $h = & $script:HistMod { Get-OmniUpdateHistoryEntry -MaxEntries 200 }
        $h.TotalCount | Should -Be 2
        @($h.Entries).Count | Should -Be 2
        $h.Entries[0].Date | Should -Be ([datetime]'2026-10-01T08:00:00')
        $h.Entries[0].Operation | Should -Be 1
        $h.Entries[0].ResultCode | Should -Be 2
        $h.Entries[0].UpdateId | Should -Be 'AAA'
        @($h.Entries[0].CategoryIds) | Should -Be @('E0789628-CE08-4437-BE74-2495B842F43B')
        $h.Entries[1].Title | Should -Be '2026-09 Cumulative Update (KB5000001)'
        $h.Entries[1].ResultCode | Should -Be 4
        $h.Entries[1].HResult | Should -Be (-2145124329)
        $h.Entries[1].UpdateId | Should -Be 'BBB'
        @($h.Entries[1].CategoryIds).Count | Should -Be 0 -Because 'an IUpdateHistoryEntry without Categories yields no IDs'
    }

    It 'asks QueryHistory for at most MaxEntries entries' {
        $null = & $script:HistMod { Get-OmniUpdateHistoryEntry -MaxEntries 1 }
        $script:FakeSession.Searcher.Asked[0][0] | Should -Be 0
        $script:FakeSession.Searcher.Asked[0][1] | Should -Be 1
    }

    It 'does not query when the history is empty' {
        $script:FakeSession = New-FakeSession -Total 0 -Entries @()
        $h = & $script:HistMod { Get-OmniUpdateHistoryEntry -MaxEntries 200 }
        $h.TotalCount | Should -Be 0
        @($h.Entries).Count | Should -Be 0
        $script:FakeSession.Searcher.Asked.Count | Should -Be 0
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
        # Windows Health also queries CIM and services. Always define simple stubs inside
        # the plugin copy's module scope (on Windows too): a function shadows the real
        # cmdlet, so Pester mocks the stub, not the CDXML/real cmdlet, and nothing leaks
        # into other test files.
        & $script:WinHealthMod {
            function script:Get-CimInstance { [CmdletBinding()] param([string] $ClassName, [Parameter(ValueFromRemainingArguments)] $Rest) }
            function script:Get-Service { [CmdletBinding()] param([string[]] $Name, [Parameter(ValueFromRemainingArguments)] $Rest) }
        }
    }

    BeforeEach {
        Mock -ModuleName OmniUpdatesTestWinHealth Get-CimInstance { @() }
        Mock -ModuleName OmniUpdatesTestWinHealth Get-Service { throw 'no service manager' }
    }

    It 'Windows Health records device and stopped-service counts only (Drivers and Services own the findings)' {
        Mock -ModuleName OmniUpdatesTestWinHealth Test-OmniPendingReboot { [string[]]@() }
        Mock -ModuleName OmniUpdatesTestWinHealth Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_PnPEntity' } {
            [pscustomobject]@{ Name = 'Spare NIC'; ConfigManagerErrorCode = [uint32]22 }
            [pscustomobject]@{ Name = 'Camera'; ConfigManagerErrorCode = [uint32]43 }
            [pscustomobject]@{ Name = 'Fine'; ConfigManagerErrorCode = [uint32]0 }
        }
        Mock -ModuleName OmniUpdatesTestWinHealth Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Service' } {
            [pscustomobject]@{ Name = 'Broken'; DisplayName = 'Broken'; StartMode = 'Auto'; State = 'Stopped'; DelayedAutoStart = $false }
        }
        $r = Invoke-PluginScan -Module $script:WinHealthMod -Context (New-TestContext)
        $r.Metrics['ProblemDevices'] | Should -Be 2
        $r.Metrics['AutoServicesStopped'] | Should -Be 1
        @($r.Findings | Where-Object { $_.Title -like 'Device problem*' }).Count | Should -Be 0
        @($r.Findings | Where-Object Id -eq 'windows-health-auto-services-stopped').Count | Should -Be 0
        @($r.Findings | Where-Object Severity -eq 'Pass').Count | Should -Be 1 -Because (($r.Findings | ForEach-Object { "$($_.Severity): $($_.Id)" }) -join '; ')
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
