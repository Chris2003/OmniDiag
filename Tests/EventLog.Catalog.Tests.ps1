#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the Event Log knowledge base (channels + translation catalog).
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/EventLog/EventLogCatalog.psm1') -Force -DisableNameChecking -Global
}

Describe 'Channel definitions' {
    It 'includes the four core logs' {
        $names = (Get-OmniEventChannelDefinition).Name
        $names | Should -Contain 'System'
        $names | Should -Contain 'Application'
        $names | Should -Contain 'Security'
        $names | Should -Contain 'Setup'
    }
    It 'marks Security as admin-only' {
        $sec = Get-OmniEventChannelDefinition | Where-Object Name -eq 'Security'
        $sec.RequiresAdmin | Should -BeTrue
    }
    It 'includes the operational channels from the spec' {
        $names = (Get-OmniEventChannelDefinition).Name
        foreach ($n in @('Windows Update','Windows Defender','DNS Client','Group Policy','WLAN AutoConfig','Network Profile')) {
            $names | Should -Contain $n
        }
    }
}

Describe 'Resolve-OmniEventMeaning' {
    It 'translates a known generic event' {
        $m = Resolve-OmniEventMeaning -Id 6008
        $m | Should -Not -BeNullOrEmpty
        $m.Category | Should -Be 'Power'
    }
    It 'prefers a provider-specific match over a generic one' {
        $m = Resolve-OmniEventMeaning -Id 1000 -ProviderName 'Application Error'
        $m.Title | Should -Be 'Application crash'
    }
    It 'overrides severity for security auditing events (4625 -> Warning)' {
        (Resolve-OmniEventMeaning -Id 4625).Severity | Should -Be 'Warning'
    }
    It 'returns null for an unknown event id' {
        Resolve-OmniEventMeaning -Id 999999 | Should -BeNullOrEmpty
    }
    It 'flags audit-log-cleared (1102) as Critical' {
        (Resolve-OmniEventMeaning -Id 1102).Severity | Should -Be 'Critical'
    }
}
