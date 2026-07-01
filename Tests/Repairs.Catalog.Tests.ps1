#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Validates every built-in repair plugin: well-formed manifest and a clean dry-run.
    Dry-run guarantees no plugin touches the host while we exercise its action path.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:Logger = New-OmniLogger -MinimumLevel Error
    $script:Repairs = @(Get-OmniRepair -Path (Join-Path $root 'src/Repairs') -Logger $script:Logger)
}

Describe 'Built-in repair catalog' {
    It 'discovers all eleven repairs' {
        $script:Repairs.Count | Should -Be 11
    }

    It 'gives every repair a unique name' {
        $names = $script:Repairs.Name
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
    }

    It 'gives every repair a valid risk level' {
        $valid = Get-OmniRepairRiskNames
        foreach ($r in $script:Repairs) { $r.Risk | Should -BeIn $valid }
    }

    It 'has Name and Category on every manifest' {
        foreach ($r in $script:Repairs) {
            $r.Name | Should -Not -BeNullOrEmpty
            $r.Category | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Every repair dry-runs cleanly' {
    It 'produces a DryRun result with no exception for each repair' {
        $ctx = New-OmniRepairContext -Logger $script:Logger -DryRun
        foreach ($reg in $script:Repairs) {
            $session = Invoke-OmniRepair -Registration @($reg) -Context $ctx
            $session.Results[0].Status | Should -Be 'DryRun' -Because "$($reg.Name) should dry-run"
        }
    }
}
