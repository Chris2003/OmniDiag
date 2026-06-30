#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Integration test: the Event Logs module discovered and run through the engine.
    Tolerant of zero events so it passes on any Windows runner; on non-Windows the
    module simply returns no events and still produces a well-formed result.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:ModulesPath = Join-Path $root 'src/Modules'
}

Describe 'Event Logs module' {
    It 'is discovered by the registry' {
        (Get-OmniModule -Path $script:ModulesPath | Where-Object Name -eq 'Event Logs') | Should -HaveCount 1
    }

    It 'declares the expected manifest' {
        $reg = Get-OmniModule -Path $script:ModulesPath | Where-Object Name -eq 'Event Logs'
        $m = & $reg.ModuleInfo { Get-OmniModuleManifest }
        $m.Category | Should -Be 'Event Logs'
        $m.Order | Should -Be 20
    }

    It 'returns a well-formed result with summary metrics' {
        $logger = New-OmniLogger -MinimumLevel Error
        $ctx = New-OmniContext -Logger $logger -TimeRange (Get-OmniTimeRange -Preset Last24Hours) `
            -Config @{ MaxEventsPerChannel = 50 }
        $reg = Get-OmniModule -Path $script:ModulesPath | Where-Object Name -eq 'Event Logs'
        $session = Invoke-OmniSession -Registration @($reg) -Context $ctx

        $r = $session.Results[0]
        $r.PSTypeNames | Should -Contain 'OmniDiag.Result'
        $r.Status | Should -BeIn @('Healthy', 'Warning', 'Critical')
        $r.Metrics.Keys | Should -Contain 'TotalEvents'
        $r.Metrics.Keys | Should -Contain 'Timeline'
        $r.Metrics.Keys | Should -Contain 'EventsPerChannel'
    }
}
