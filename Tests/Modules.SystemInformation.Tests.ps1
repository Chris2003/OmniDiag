#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests for the System Information reference module and plugin discovery.
    These run on any OS: when CIM data is unavailable (non-Windows / sandboxed CI)
    the module still returns a well-formed result with the fallback Hostname metric.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:ModulesPath = Join-Path $root 'src/Modules'
}

Describe 'Plugin discovery' {
    It 'finds the System Information module' {
        $regs = Get-OmniModule -Path $script:ModulesPath
        ($regs | Where-Object Name -eq 'System Information') | Should -HaveCount 1
    }
    It 'registrations carry a category and module info' {
        $reg = Get-OmniModule -Path $script:ModulesPath | Where-Object Name -eq 'System Information'
        $reg.Category | Should -Be 'System'
        $reg.ModuleInfo | Should -Not -BeNullOrEmpty
    }
}

Describe 'System Information module contract' {
    It 'exposes a valid manifest' {
        $reg = Get-OmniModule -Path $script:ModulesPath | Where-Object Name -eq 'System Information'
        $m = & $reg.ModuleInfo { Get-OmniModuleManifest }
        $m.Name | Should -Be 'System Information'
        $m.Category | Should -Be 'System'
        $m.RequiresAdmin | Should -BeFalse
    }

    It 'returns a well-formed result when invoked through the engine' {
        $logger = New-OmniLogger -MinimumLevel Error
        $ctx = New-OmniContext -Logger $logger
        $regs = Get-OmniModule -Path $script:ModulesPath | Where-Object Name -eq 'System Information'
        $session = Invoke-OmniSession -Registration @($regs) -Context $ctx

        $session.Results | Should -HaveCount 1
        $r = $session.Results[0]
        $r.PSTypeNames | Should -Contain 'OmniDiag.Result'
        $r.Status | Should -BeIn @('Healthy', 'Warning', 'Critical')
        $r.Metrics.Keys | Should -Contain 'Hostname'
        $r.Findings.Count | Should -BeGreaterThan 0
    }
}
