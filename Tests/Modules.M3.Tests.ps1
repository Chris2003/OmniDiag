#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Integration tests for the Milestone 3 diagnostic modules (Network, Storage,
    Windows Health, Security, Performance). These exercise the real modules through
    the engine. On a Windows runner they collect live data; the assertions only
    require a well-formed result so environment variance (e.g. Secure Boot off on a
    VM) does not cause false failures.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:ModulesPath = Join-Path $root 'src/Modules'
    $script:Registrations = Get-OmniModule -Path $script:ModulesPath
}

Describe 'Milestone 3 module discovery' {
    It 'discovers all expected diagnostic modules' {
        $names = $script:Registrations.Name
        foreach ($n in @('System Information','Event Logs','Network','Storage','Windows Health','Security','Performance')) {
            $names | Should -Contain $n
        }
    }

    It 'assigns each module a unique run order' {
        $orders = $script:Registrations.Order
        ($orders | Select-Object -Unique).Count | Should -Be $orders.Count
    }
}

Describe 'Milestone 3 modules execute cleanly' {
    BeforeAll {
        $logger = New-OmniLogger -MinimumLevel Error
        $ctx = New-OmniContext -Logger $logger
    }

    It '<Module> returns a well-formed, non-failed result' -ForEach @(
        @{ Module = 'Network' }
        @{ Module = 'Storage' }
        @{ Module = 'Windows Health' }
        @{ Module = 'Security' }
        @{ Module = 'Performance' }
    ) {
        $reg = $script:Registrations | Where-Object Name -eq $Module
        $reg | Should -Not -BeNullOrEmpty
        $session = Invoke-OmniSession -Registration @($reg) -Context $ctx
        $r = $session.Results[0]
        $r.PSTypeNames | Should -Contain 'OmniDiag.Result'
        $r.Status | Should -BeIn @('Healthy', 'Warning', 'Critical')
        $r.Findings.Count | Should -BeGreaterThan 0
    }
}
