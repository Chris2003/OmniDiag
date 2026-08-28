#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
}

Describe 'Role profiles and task workflows' {
    It 'provides profiles for every major IT support level' {
        $names = (Get-OmniRoleProfile).Name
        foreach ($name in @('HelpDesk','DesktopSupport','SystemsAdmin','NetworkAdmin','SecurityAdmin','CloudAdmin','Full')) {
            $names | Should -Contain $name
        }
    }

    It 'provides task-oriented daily workflows' {
        $names = (Get-OmniTaskWorkflow).Name
        foreach ($name in @('QuickTriage','SlowComputer','NetworkConnectivity','Printing','WindowsUpdate','LoginAndIdentity','StorageCleanup','SecurityPosture','CloudReadiness','FullScan')) {
            $names | Should -Contain $name
        }
    }

    It 'resolves names case-insensitively' {
        (Get-OmniRoleProfile -Name 'helpdesk').Name | Should -Be 'HelpDesk'
        (Get-OmniTaskWorkflow -Name 'quicktriage').Name | Should -Be 'QuickTriage'
    }

    It 'maps every named scanner to a discovered module' {
        $logger = New-OmniLogger -MinimumLevel Error
        $modulesPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Modules'
        $available = @(Get-OmniModule -Path $modulesPath -Logger $logger).Name
        $requested = @((Get-OmniRoleProfile).Modules) + @((Get-OmniTaskWorkflow).Modules)
        foreach ($name in @($requested | Where-Object { $_ } | Select-Object -Unique)) {
            $available | Should -Contain $name
        }
    }

    It 'throws a useful error for an unknown plan' {
        { Get-OmniRoleProfile -Name 'NoSuchRole' } | Should -Throw '*Valid profiles*'
        { Get-OmniTaskWorkflow -Name 'NoSuchTask' } | Should -Throw '*Valid workflows*'
    }
}
