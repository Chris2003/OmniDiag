#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $logger = New-OmniLogger -MinimumLevel Error
    $script:Registrations = @(Get-OmniModule -Path (Join-Path $root 'src/Modules') -Logger $logger)
    $script:Version3Names = @('Active Directory','Entra ID','Intune and MDM','Certificates','Proxy Configuration','VPN','Time Synchronization','BitLocker','Defender Onboarding','Update Rings')
}

Describe 'Version 3 enterprise scanner catalog' {
    It 'contains every Version 3 scanner exactly once' {
        foreach ($name in $script:Version3Names) {
            @($script:Registrations | Where-Object Name -eq $name) | Should -HaveCount 1
        }
    }

    It 'keeps enterprise scans read-only at the manifest level' {
        foreach ($registration in @($script:Registrations | Where-Object Name -in $script:Version3Names)) {
            $registration.RequiresAdmin | Should -BeFalse
            $registration.Enabled | Should -BeTrue
        }
    }

    It 'includes the completed enterprise evidence in Cloud Admin' {
        $cloud = Get-OmniRoleProfile CloudAdmin
        foreach ($name in $script:Version3Names) { $cloud.Modules | Should -Contain $name }
    }
}
