#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Behavior tests for the extras scanners changed in Phase 2 wave B: Entra ID (registry
    join state; dsregcmd only with connectivity probes), Time Synchronization (registry
    configuration + bounded Time-Service events; no w32tm, no time server), and Intune and
    MDM (bounded DeviceManagement event query).

    Every data source goes through a private helper that is mocked inside the plugin's
    module scope, so the suite runs on any OS. Each plugin is copied to TestDrive under a
    unique file name so its module name is unique for Mock -ModuleName.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    function Import-ExtCopy {
        param([string] $File, [string] $AsName)
        $dir = Join-Path $TestDrive 'extplugins'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $copy = Join-Path $dir "$AsName.psm1"
        Copy-Item -LiteralPath (Join-Path $script:Root "src/Modules/$File") -Destination $copy -Force
        return (Import-Module -Name $copy -Force -PassThru -DisableNameChecking)
    }

    function New-ExtContext {
        param([switch] $Probes, [hashtable] $Config = @{})
        New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -NetworkProbes:$Probes -Config $Config
    }

    function Invoke-ExtScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    function Get-Finding {
        # The unary comma keeps the array: a one-element @() returned from a function is
        # unrolled to the PSCustomObject, which has no .Count on Windows PowerShell 5.1.
        param($Result, [string] $Id)
        return , @($Result.Findings | Where-Object Id -eq $Id)
    }

    # Layout as documented in "Troubleshoot devices by using the dsregcmd command".
    function New-DsregLines {
        param([string] $Joined = 'YES', [string] $Workplace = 'NO', [string] $Auth = 'SUCCESS', [string] $Prt = 'YES')
        @(
            '+----------------------------------------------------------------------+'
            '| Device State                                                         |'
            '+----------------------------------------------------------------------+'
            "             AzureAdJoined : $Joined"
            '          EnterpriseJoined : NO'
            '              DomainJoined : NO'
            '                  DeviceId : 00aa00aa-bb11-cc22-dd33-44ee44ee44ee'
            "          DeviceAuthStatus : $Auth"
            '                TenantName : Contoso'
            '                  TenantId : aaaabbbb-0000-cccc-1111-dddd2222eeee'
            "           WorkplaceJoined : $Workplace"
            "                AzureAdPrt : $Prt"
            '       AzureAdPrtAuthority : https://login.microsoftonline.com/aaaabbbb-0000-cccc-1111-dddd2222eeee'
        )
    }

    $script:EntraMod  = Import-ExtCopy -File 'EntraId.psm1' -AsName 'OmniExtTestEntra'
    $script:TimeMod   = Import-ExtCopy -File 'TimeSynchronization.psm1' -AsName 'OmniExtTestTime'
    $script:IntuneMod = Import-ExtCopy -File 'IntuneMdm.psm1' -AsName 'OmniExtTestIntune'

    # ALWAYS (on Windows too) give the plugin copies a simple Get-WinEvent stub in their
    # module scope: the function shadows the real cmdlet, so Pester mocks the stub, and
    # nothing leaks globally. The parameters the tests filter on are declared.
    foreach ($mod in @($script:TimeMod, $script:IntuneMod)) {
        & $mod { function script:Get-WinEvent { [CmdletBinding()] param($ListLog, [hashtable[]] $FilterHashtable, [int] $MaxEvents) } }
    }
}

AfterAll {
    foreach ($n in @('OmniExtTestEntra', 'OmniExtTestTime', 'OmniExtTestIntune')) { Remove-Module -Name $n -Force -ErrorAction SilentlyContinue }
}

Describe 'Entra ID scanner' {
    BeforeEach {
        Mock -ModuleName OmniExtTestEntra Test-OmniEntraWindowsHost { $true }
        Mock -ModuleName OmniExtTestEntra Invoke-OmniEntraDsregStatus { New-DsregLines }
    }

    It 'declares Internet access (dsregcmd contacts Entra ID, probes only)' {
        $m = & $script:EntraMod { Get-OmniModuleManifest }
        $m.Id | Should -Be 'extras.entra-id'
        $m.Name | Should -Be 'Entra ID'
        $m.NetworkAccess | Should -Be 'Internet'
    }

    It 'reads the join state from the registry and does not run dsregcmd without probes' {
        Mock -ModuleName OmniExtTestEntra Get-OmniEntraJoinInfo { @{ Joined = $true; TenantId = 'aaaabbbb-0000-cccc-1111-dddd2222eeee'; TenantName = 'Contoso' } }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext)
        Should -Invoke -ModuleName OmniExtTestEntra Invoke-OmniEntraDsregStatus -Times 0 -Exactly
        $r.Metrics['AzureAdJoined'] | Should -Be 'YES'
        $r.Metrics['TenantName'] | Should -Be 'Contoso'
        $r.Metrics['JoinStateSource'] | Should -Be 'Registry'
        $r.Metrics['ConnectivityProbesRun'] | Should -BeFalse
        $skip = @($r.Findings | Where-Object Title -eq 'Connectivity probe not run')
        $skip.Count | Should -Be 1
        $skip[0].Severity | Should -Be 'Information'
        $skip[0].Detail | Should -Match 'dsregcmd'
        (Get-Finding $r 'extras.entra-id.healthy')[0].Detail | Should -Match 'Contoso'
    }

    It 'reports a device that is not joined as Information, without a probe finding' {
        Mock -ModuleName OmniExtTestEntra Get-OmniEntraJoinInfo { @{ Joined = $false; TenantId = ''; TenantName = '' } }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext)
        (Get-Finding $r 'extras.entra-id.not-joined')[0].Severity | Should -Be 'Information'
        @($r.Findings | Where-Object Title -eq 'Connectivity probe not run').Count | Should -Be 0
        $r.Metrics['AzureAdJoined'] | Should -Be 'NO'
    }

    It 'says so when the join registry cannot be read' {
        Mock -ModuleName OmniExtTestEntra Get-OmniEntraJoinInfo { throw 'access denied' }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext)
        (Get-Finding $r 'extras.entra-id.join-state-unavailable')[0].Severity | Should -Be 'Information'
        $r.Metrics['JoinStateSource'] | Should -Be 'Unavailable'
    }

    It 'runs dsregcmd with probes and passes a healthy joined device' {
        Mock -ModuleName OmniExtTestEntra Get-OmniEntraJoinInfo { @{ Joined = $true; TenantId = 't'; TenantName = '' } }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext -Probes)
        Should -Invoke -ModuleName OmniExtTestEntra Invoke-OmniEntraDsregStatus -Times 1 -Exactly
        $r.Metrics['DeviceAuthStatus'] | Should -Be 'SUCCESS'
        $r.Metrics['ConnectivityProbesRun'] | Should -BeTrue
        @($r.Findings | Where-Object Title -eq 'Connectivity probe not run').Count | Should -Be 0
        (Get-Finding $r 'extras.entra-id.healthy')[0].Detail | Should -Match 'Contoso'
    }

    It 'warns on failed device authentication and a missing PRT' {
        Mock -ModuleName OmniExtTestEntra Get-OmniEntraJoinInfo { @{ Joined = $true; TenantId = 't'; TenantName = 'Contoso' } }
        Mock -ModuleName OmniExtTestEntra Invoke-OmniEntraDsregStatus { New-DsregLines -Auth 'FAILED. Device is either disabled or deleted' -Prt 'NO' }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext -Probes)
        (Get-Finding $r 'extras.entra-id.device-auth-failed')[0].Severity | Should -Be 'Warning'
        (Get-Finding $r 'extras.entra-id.prt-missing')[0].Severity | Should -Be 'Warning'
        (Get-Finding $r 'extras.entra-id.healthy').Count | Should -Be 0
    }

    It 'reports neither joined nor registered from dsregcmd, and passes a registered-only device' {
        Mock -ModuleName OmniExtTestEntra Get-OmniEntraJoinInfo { @{ Joined = $false; TenantId = ''; TenantName = '' } }
        Mock -ModuleName OmniExtTestEntra Invoke-OmniEntraDsregStatus { New-DsregLines -Joined 'NO' -Workplace 'NO' }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext -Probes)
        (Get-Finding $r 'extras.entra-id.not-joined-or-registered')[0].Severity | Should -Be 'Information'

        Mock -ModuleName OmniExtTestEntra Invoke-OmniEntraDsregStatus { New-DsregLines -Joined 'NO' -Workplace 'YES' -Prt 'NO' }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext -Probes)
        (Get-Finding $r 'extras.entra-id.healthy')[0].Detail | Should -Match 'registration'
        (Get-Finding $r 'extras.entra-id.prt-missing').Count | Should -Be 0
    }

    It 'warns when dsregcmd fails' {
        Mock -ModuleName OmniExtTestEntra Get-OmniEntraJoinInfo { @{ Joined = $true; TenantId = 't'; TenantName = '' } }
        Mock -ModuleName OmniExtTestEntra Invoke-OmniEntraDsregStatus { throw 'dsregcmd crashed' }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext -Probes)
        (Get-Finding $r 'extras.entra-id.dsregcmd-failed')[0].Severity | Should -Be 'Warning'
    }

    It 'parses dsregcmd output by documented field names only' {
        $v = & $script:EntraMod { param($l) ConvertFrom-OmniDsregStatus -Line $l } (New-DsregLines -Prt 'NO')
        $v['AzureAdJoined'] | Should -Be 'YES'
        $v['AzureAdPrt'] | Should -Be 'NO'
        $v['TenantName'] | Should -Be 'Contoso'
        $v.ContainsKey('AzureAdPrtAuthority') | Should -BeFalse
        $v.ContainsKey('EnterpriseJoined') | Should -BeTrue
        (& $script:EntraMod { ConvertFrom-OmniDsregStatus -Line $null }).Count | Should -Be 0
    }

    It 'is Windows-only' {
        Mock -ModuleName OmniExtTestEntra Test-OmniEntraWindowsHost { $false }
        $r = Invoke-ExtScan -Module $script:EntraMod -Context (New-ExtContext)
        $r.Findings[0].Id | Should -Be 'extras.entra-id.windows-only'
    }
}

# The configuration helper itself (the scanner tests below mock it in BeforeEach).
Describe 'Time Synchronization configuration' {
    It 'prefers the Group Policy configuration over the local one' {
        Mock -ModuleName OmniExtTestTime Get-ItemProperty { [pscustomobject]@{ Type = 'NTP' } } -ParameterFilter { $LiteralPath -like '*Policies*' }
        Mock -ModuleName OmniExtTestTime Get-ItemProperty { [pscustomobject]@{ Type = 'NT5DS'; NtpServer = 'time.contoso.com,0x9' } } -ParameterFilter { $LiteralPath -like '*CurrentControlSet*' }
        $cfg = & $script:TimeMod { Get-OmniTimeConfig }
        $cfg.Type | Should -Be 'NTP'
        $cfg.Source | Should -Be 'Policy'
        $cfg.NtpServer | Should -Be 'time.contoso.com,0x9'
    }
}

Describe 'Time Synchronization scanner' {
    BeforeEach {
        Mock -ModuleName OmniExtTestTime Test-OmniTimeWindowsHost { $true }
        Mock -ModuleName OmniExtTestTime Get-OmniTimeService { @{ Status = 'Running'; StartType = 'Automatic' } }
        Mock -ModuleName OmniExtTestTime Get-OmniTimeConfig { @{ Type = 'NT5DS'; NtpServer = ''; Source = 'Local' } }
        Mock -ModuleName OmniExtTestTime Get-OmniTimeEvent { @([pscustomobject]@{ Id = 37; TimeCreated = (Get-Date).AddHours(-1) }) } -ParameterFilter { $Id -contains 35 }
        Mock -ModuleName OmniExtTestTime Get-OmniTimeEvent { @() } -ParameterFilter { $Id -contains 36 }
    }

    It 'passes a healthy configuration and bounds both event queries' {
        $ctx = New-ExtContext
        $r = Invoke-ExtScan -Module $script:TimeMod -Context $ctx
        (Get-Finding $r 'extras.time-synchronization.healthy')[0].Severity | Should -Be 'Pass'
        $r.Metrics['Type'] | Should -Be 'NT5DS'
        $r.Metrics['SyncFailureEventCount'] | Should -Be 0
        $r.Metrics['LastSyncEvent'] | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName OmniExtTestTime Get-OmniTimeEvent -Times 1 -Exactly -ParameterFilter { $Id -contains 35 -and $MaxEvents -eq 1 }
        Should -Invoke -ModuleName OmniExtTestTime Get-OmniTimeEvent -Times 1 -Exactly -ParameterFilter { $Id -contains 36 -and $MaxEvents -le 50 -and $StartTime -eq $ctx.TimeRange.Start }
    }

    It 'warns when the service is disabled' {
        Mock -ModuleName OmniExtTestTime Get-OmniTimeService { @{ Status = 'Stopped'; StartType = 'Disabled' } }
        $r = Invoke-ExtScan -Module $script:TimeMod -Context (New-ExtContext)
        (Get-Finding $r 'extras.time-synchronization.service-disabled')[0].Severity | Should -Be 'Warning'
    }

    It 'treats a stopped trigger-start (Manual) service as Information' {
        Mock -ModuleName OmniExtTestTime Get-OmniTimeService { @{ Status = 'Stopped'; StartType = 'Manual' } }
        $r = Invoke-ExtScan -Module $script:TimeMod -Context (New-ExtContext)
        (Get-Finding $r 'extras.time-synchronization.service-on-demand')[0].Severity | Should -Be 'Information'
        (Get-Finding $r 'extras.time-synchronization.healthy').Count | Should -Be 1 -Because (($r.Findings | ForEach-Object { "$($_.Severity): $($_.Id)" }) -join '; ')
    }

    It 'warns when an automatic service is not running' {
        Mock -ModuleName OmniExtTestTime Get-OmniTimeService { @{ Status = 'Stopped'; StartType = 'Automatic' } }
        $r = Invoke-ExtScan -Module $script:TimeMod -Context (New-ExtContext)
        (Get-Finding $r 'extras.time-synchronization.service-not-running')[0].Severity | Should -Be 'Warning'
    }

    It 'warns when synchronization is turned off (Type NoSync)' {
        Mock -ModuleName OmniExtTestTime Get-OmniTimeConfig { @{ Type = 'NoSync'; NtpServer = ''; Source = 'Policy' } }
        $r = Invoke-ExtScan -Module $script:TimeMod -Context (New-ExtContext)
        $f = Get-Finding $r 'extras.time-synchronization.sync-disabled'
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Detail | Should -Match 'Policy'
    }

    It 'warns on synchronization failure events (36 / 47) newer than the newest success' {
        Mock -ModuleName OmniExtTestTime Get-OmniTimeEvent { @([pscustomobject]@{ Id = 37; TimeCreated = (Get-Date).AddDays(-3) }) } -ParameterFilter { $Id -contains 35 }
        Mock -ModuleName OmniExtTestTime Get-OmniTimeEvent { @([pscustomobject]@{ Id = 36; TimeCreated = (Get-Date).AddDays(-1) }, [pscustomobject]@{ Id = 47; TimeCreated = (Get-Date).AddDays(-2) }) } -ParameterFilter { $Id -contains 36 }
        $r = Invoke-ExtScan -Module $script:TimeMod -Context (New-ExtContext)
        $f = Get-Finding $r 'extras.time-synchronization.sync-failures'
        $f.Count | Should -Be 1 -Because (($r.Findings | ForEach-Object { "$($_.Severity): $($_.Id)" }) -join '; ')
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Detail | Should -Match '36, 47'
        $r.Metrics['SyncFailureEventCount'] | Should -Be 2
    }

    It 'warns on failures when no successful synchronization event exists' {
        Mock -ModuleName OmniExtTestTime Get-OmniTimeEvent { @() } -ParameterFilter { $Id -contains 35 }
        Mock -ModuleName OmniExtTestTime Get-OmniTimeEvent { @([pscustomobject]@{ Id = 47; TimeCreated = (Get-Date).AddDays(-2) }) } -ParameterFilter { $Id -contains 36 }
        $r = Invoke-ExtScan -Module $script:TimeMod -Context (New-ExtContext)
        (Get-Finding $r 'extras.time-synchronization.sync-failures')[0].Severity | Should -Be 'Warning'
    }

    It 'reports failures that a later synchronization resolved as Information' {
        # BeforeEach: newest success (37) one hour ago.
        Mock -ModuleName OmniExtTestTime Get-OmniTimeEvent { @([pscustomobject]@{ Id = 36; TimeCreated = (Get-Date).AddDays(-1) }, [pscustomobject]@{ Id = 47; TimeCreated = (Get-Date).AddDays(-2) }) } -ParameterFilter { $Id -contains 36 }
        $r = Invoke-ExtScan -Module $script:TimeMod -Context (New-ExtContext)
        $f = Get-Finding $r 'extras.time-synchronization.sync-failures'
        $f.Count | Should -Be 1 -Because (($r.Findings | ForEach-Object { "$($_.Severity): $($_.Id)" }) -join '; ')
        $f[0].Severity | Should -Be 'Information'
        $f[0].Detail | Should -Match 'later synchronization succeeded'
        (Get-Finding $r 'extras.time-synchronization.healthy').Count | Should -Be 1
    }

    It 'never runs w32tm (localized output, and /resync would contact a time server)' {
        $text = Get-Content -LiteralPath (Join-Path $script:Root 'src/Modules/TimeSynchronization.psm1') -Raw
        $text | Should -Not -Match 'w32tm(\.exe)?\s+/'
    }

    It 'is Windows-only' {
        Mock -ModuleName OmniExtTestTime Test-OmniTimeWindowsHost { $false }
        $r = Invoke-ExtScan -Module $script:TimeMod -Context (New-ExtContext)
        $r.Findings[0].Id | Should -Be 'extras.time-synchronization.windows-only'
    }
}

Describe 'Intune and MDM scanner: bounded event query' {
    BeforeEach {
        Mock -ModuleName OmniExtTestIntune Test-OmniIntuneWindowsHost { $true }
        Mock -ModuleName OmniExtTestIntune Test-Path { $false }
    }

    It 'queries at most 500 events in the scan time range by default' {
        Mock -ModuleName OmniExtTestIntune Get-OmniIntuneMdmErrorCount { 0 }
        $ctx = New-ExtContext
        $r = Invoke-ExtScan -Module $script:IntuneMod -Context $ctx
        Should -Invoke -ModuleName OmniExtTestIntune Get-OmniIntuneMdmErrorCount -Times 1 -Exactly -ParameterFilter { $MaxEvents -eq 500 -and $Start -eq $ctx.TimeRange.Start -and $End -eq $ctx.TimeRange.End }
        $r.Metrics['RecentMdmErrorCount'] | Should -Be 0
        (Get-Finding $r 'extras.intune-and-mdm.no-enrollment')[0].Severity | Should -Be 'Information'
    }

    It 'honors Config.MaxEventsPerChannel and says "at least" when the cap is reached' {
        Mock -ModuleName OmniExtTestIntune Get-OmniIntuneMdmErrorCount { 25 }
        $r = Invoke-ExtScan -Module $script:IntuneMod -Context (New-ExtContext -Config @{ MaxEventsPerChannel = 25 })
        Should -Invoke -ModuleName OmniExtTestIntune Get-OmniIntuneMdmErrorCount -Times 1 -Exactly -ParameterFilter { $MaxEvents -eq 25 }
        $f = Get-Finding $r 'extras.intune-and-mdm.recent-mdm-errors'
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Title | Should -Be 'at least 25 recent MDM enrollment or policy errors'
        $r.Metrics['RecentMdmErrorCountCapped'] | Should -BeTrue
    }

    It 'reports fewer than 10 errors as Information and 10 or more as a Warning' {
        Mock -ModuleName OmniExtTestIntune Get-OmniIntuneMdmErrorCount { 9 }
        $r = Invoke-ExtScan -Module $script:IntuneMod -Context (New-ExtContext)
        $f = Get-Finding $r 'extras.intune-and-mdm.recent-mdm-errors'
        $f[0].Severity | Should -Be 'Information'
        $f[0].Title | Should -Be '9 recent MDM enrollment or policy errors'
        Mock -ModuleName OmniExtTestIntune Get-OmniIntuneMdmErrorCount { 10 }
        $r = Invoke-ExtScan -Module $script:IntuneMod -Context (New-ExtContext)
        (Get-Finding $r 'extras.intune-and-mdm.recent-mdm-errors')[0].Severity | Should -Be 'Warning'
    }

    It 'passes MaxEvents, the time range, and the error level to Get-WinEvent' {
        Mock -ModuleName OmniExtTestIntune Get-WinEvent { [pscustomobject]@{ LogName = 'x' } } -ParameterFilter { $null -ne $ListLog }
        Mock -ModuleName OmniExtTestIntune Get-WinEvent { 1..3 | ForEach-Object { [pscustomobject]@{ Id = 404 } } } -ParameterFilter { $null -ne $FilterHashtable }
        $start = (Get-Date).AddDays(-7); $end = Get-Date
        $n = & $script:IntuneMod { param($s, $e) Get-OmniIntuneMdmErrorCount -Start $s -End $e -MaxEvents 10 } $start $end
        $n | Should -Be 3
        Should -Invoke -ModuleName OmniExtTestIntune Get-WinEvent -Times 1 -Exactly -ParameterFilter {
            $null -ne $FilterHashtable -and $MaxEvents -eq 10 -and $FilterHashtable.Level -eq 2 -and $FilterHashtable.StartTime -eq $start -and $FilterHashtable.EndTime -eq $end
        }
    }
}
