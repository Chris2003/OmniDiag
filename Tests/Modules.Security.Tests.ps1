#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Security group scanners: Local Admins (membership of S-1-5-32-544, the built-in
    Administrator account, and the opt-in rule for joined devices) and the UAC checks of
    the Security scanner (EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop).

    Every data source sits behind a private helper in the plugin; the tests mock those
    helpers inside the plugin's module scope, so every finding path runs on any host.
    Each plugin is copied to TestDrive under a unique file name so its module name is
    unique for Mock -ModuleName.
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
        param([switch] $Probes)
        New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -NetworkProbes:$Probes
    }

    function Invoke-PluginScan {
        param($Module, $Context)
        & $Module { param($c) Invoke-OmniModuleScan -Context $c } $Context
    }

    function Get-FindingById {
        # The unary comma keeps the array: a one-element @() returned from a function is
        # unrolled to the PSCustomObject, which has no .Count on Windows PowerShell 5.1.
        param($Result, [string] $Id)
        return , @($Result.Findings | Where-Object Id -eq $Id)
    }

    $script:AdminsMod = Import-PluginCopy -File 'LocalAdmins.psm1' -AsName 'OmniSecTestAdmins'
    $script:SecurityMod = Import-PluginCopy -File 'Security.psm1' -AsName 'OmniSecTestSecurity'
}

AfterAll {
    foreach ($n in @('OmniSecTestAdmins', 'OmniSecTestSecurity')) { Remove-Module -Name $n -Force -ErrorAction SilentlyContinue }
}

Describe 'Local Admins scanner' {
    BeforeEach {
        Mock -ModuleName OmniSecTestAdmins Get-OmniDeviceJoinState { [pscustomobject]@{ DomainJoined = $false; EntraJoined = $false } }
        Mock -ModuleName OmniSecTestAdmins Get-OmniLocalUserAccount {
            [pscustomobject]@{ Available = $true; Users = @(
                    [pscustomobject]@{ Name = 'Administrator'; Sid = 'S-1-5-21-1000-2000-3000-500'; Enabled = $false }
                    [pscustomobject]@{ Name = 'jdoe'; Sid = 'S-1-5-21-1000-2000-3000-1001'; Enabled = $true }
                ) }
        }
        Mock -ModuleName OmniSecTestAdmins Get-OmniAdministratorsMember {
            [pscustomobject]@{ Available = $true; Source = 'Get-LocalGroupMember'; Error = ''; Members = @(
                    [pscustomobject]@{ Name = 'PC1\Administrator'; Sid = 'S-1-5-21-1000-2000-3000-500'; Source = 'Local' }
                    [pscustomobject]@{ Name = 'PC1\jdoe'; Sid = 'S-1-5-21-1000-2000-3000-1001'; Source = 'Local' }
                    [pscustomobject]@{ Name = 'CORP\Domain Admins'; Sid = 'S-1-5-21-7-8-9-512'; Source = 'ActiveDirectory' }
                    [pscustomobject]@{ Name = 'S-1-5-21-7-8-9-1105'; Sid = 'S-1-5-21-7-8-9-1105'; Source = 'Unknown' }
                ) }
        }
    }

    It 'declares the contract manifest (opt-in LocalNetwork access)' {
        $m = & $script:AdminsMod { Get-OmniModuleManifest }
        $m.Id | Should -Be 'security.local-admins'
        $m.Group | Should -Be 'security'
        $m.NetworkAccess | Should -Be 'LocalNetwork'
        $m.RequiresAdmin | Should -BeFalse
    }

    It 'lists members, extra local admins, and unresolved SIDs on a non-joined device' {
        $r = Invoke-PluginScan -Module $script:AdminsMod -Context (New-TestContext)
        Should -Invoke -ModuleName OmniSecTestAdmins Get-OmniAdministratorsMember -Times 1 -Exactly
        $members = Get-FindingById $r 'security-local-admins-members'
        $members.Count | Should -Be 1
        $members[0].Detail | Should -Match 'CORP\\Domain Admins'
        $extra = Get-FindingById $r 'security-local-admins-extra-local-accounts'
        $extra.Count | Should -Be 1
        $extra[0].Detail | Should -Match 'jdoe'
        $extra[0].Detail | Should -Not -Match 'PC1\\Administrator'
        @($extra[0].Data).Count | Should -Be 1
        $u = Get-FindingById $r 'security-local-admins-unresolved'
        $u.Count | Should -Be 1
        $u[0].Detail | Should -Match 'S-1-5-21-7-8-9-1105'
        (Get-FindingById $r 'security-local-admins-only-builtin').Count | Should -Be 0
        (Get-FindingById $r 'security-local-admins-builtin-administrator-enabled').Count | Should -Be 0
        (Get-FindingById $r 'security-local-admins-reviewed').Count | Should -Be 1
        $r.Metrics['AdministratorsMemberCount'] | Should -Be 4
        $r.Metrics['MembershipEnumerated'] | Should -BeTrue
        $r.Metrics['BuiltinAdministratorEnabled'] | Should -BeFalse
        $r.Status | Should -Be 'Healthy'
    }

    It 'warns when the built-in Administrator (RID 500) is enabled, whatever its name' {
        Mock -ModuleName OmniSecTestAdmins Get-OmniLocalUserAccount {
            [pscustomobject]@{ Available = $true; Users = @([pscustomobject]@{ Name = 'Administrateur'; Sid = 'S-1-5-21-1000-2000-3000-500'; Enabled = $true }) }
        }
        $r = Invoke-PluginScan -Module $script:AdminsMod -Context (New-TestContext)
        $w = Get-FindingById $r 'security-local-admins-builtin-administrator-enabled'
        $w.Count | Should -Be 1
        $w[0].Severity | Should -Be 'Warning'
        $w[0].Detail | Should -Match 'Administrateur'
        $r.Status | Should -Be 'Warning'
        (Get-FindingById $r 'security-local-admins-reviewed').Count | Should -Be 0
    }

    It 'skips membership on a domain-joined device without probes, and says why' {
        Mock -ModuleName OmniSecTestAdmins Get-OmniDeviceJoinState { [pscustomobject]@{ DomainJoined = $true; EntraJoined = $false } }
        $r = Invoke-PluginScan -Module $script:AdminsMod -Context (New-TestContext)
        Should -Invoke -ModuleName OmniSecTestAdmins Get-OmniAdministratorsMember -Times 0 -Exactly
        Should -Invoke -ModuleName OmniSecTestAdmins Get-OmniLocalUserAccount -Times 1 -Exactly
        $info = @($r.Findings | Where-Object Title -eq 'Connectivity probe not run')
        $info.Count | Should -Be 1
        $info[0].Detail | Should -Match 'domain controller'
        $r.Metrics['MembershipEnumerated'] | Should -BeFalse
        $r.Metrics['DeviceJoined'] | Should -BeTrue
    }

    It 'skips membership on an Entra-joined device without probes' {
        Mock -ModuleName OmniSecTestAdmins Get-OmniDeviceJoinState { [pscustomobject]@{ DomainJoined = $false; EntraJoined = $true } }
        $r = Invoke-PluginScan -Module $script:AdminsMod -Context (New-TestContext)
        Should -Invoke -ModuleName OmniSecTestAdmins Get-OmniAdministratorsMember -Times 0 -Exactly
        @($r.Findings | Where-Object Title -eq 'Connectivity probe not run').Count | Should -Be 1
    }

    It 'lists membership on a joined device with probes' {
        Mock -ModuleName OmniSecTestAdmins Get-OmniDeviceJoinState { [pscustomobject]@{ DomainJoined = $true; EntraJoined = $false } }
        $r = Invoke-PluginScan -Module $script:AdminsMod -Context (New-TestContext -Probes)
        Should -Invoke -ModuleName OmniSecTestAdmins Get-OmniAdministratorsMember -Times 1 -Exactly
        @($r.Findings | Where-Object Title -eq 'Connectivity probe not run').Count | Should -Be 0
        (Get-FindingById $r 'security-local-admins-members').Count | Should -Be 1
    }

    It 'reports when only the built-in account is a member' {
        Mock -ModuleName OmniSecTestAdmins Get-OmniAdministratorsMember {
            [pscustomobject]@{ Available = $true; Source = 'Win32_GroupUser'; Error = 'Failed to compare two elements in the array.'; Members = @(
                    [pscustomobject]@{ Name = 'PC1\Administrator'; Sid = 'S-1-5-21-1000-2000-3000-500'; Source = 'Local' }
                ) }
        }
        $r = Invoke-PluginScan -Module $script:AdminsMod -Context (New-TestContext)
        $o = Get-FindingById $r 'security-local-admins-only-builtin'
        $o.Count | Should -Be 1
        $o[0].Severity | Should -Be 'Information'
        (Get-FindingById $r 'security-local-admins-members')[0].Detail | Should -Match 'Win32_GroupUser'
        $r.Metrics['MembershipSource'] | Should -Be 'Win32_GroupUser'
        (Get-FindingById $r 'security-local-admins-extra-local-accounts').Count | Should -Be 0
    }

    It 'reports an unavailable membership with the error' {
        Mock -ModuleName OmniSecTestAdmins Get-OmniAdministratorsMember { [pscustomobject]@{ Available = $false; Source = ''; Error = 'The term Get-LocalGroupMember is not recognized'; Members = @() } }
        $r = Invoke-PluginScan -Module $script:AdminsMod -Context (New-TestContext)
        $u = Get-FindingById $r 'security-local-admins-unavailable'
        $u.Count | Should -Be 1
        $u[0].Detail | Should -Match 'not recognized'
        $r.Metrics['MembershipEnumerated'] | Should -BeFalse
    }

    It 'still runs when Get-LocalUser is unavailable' {
        Mock -ModuleName OmniSecTestAdmins Get-OmniLocalUserAccount { [pscustomobject]@{ Available = $false; Users = @() } }
        $r = Invoke-PluginScan -Module $script:AdminsMod -Context (New-TestContext)
        $r.Metrics['BuiltinAdministratorEnabled'] | Should -BeNullOrEmpty
        (Get-FindingById $r 'security-local-admins-members').Count | Should -Be 1
    }

    It 'extracts the RID only from machine or domain account SIDs' {
        $rids = & $script:AdminsMod { @((Get-OmniSidRid 'S-1-5-21-1-2-3-500'), (Get-OmniSidRid 'S-1-5-32-544'), (Get-OmniSidRid 'S-1-12-1-1-2-3-4')) }
        $rids | Should -Be @(500, -1, -1)
    }
}

Describe 'Security scanner: UAC' {
    It 'warns on elevation without prompting and a disabled secure desktop' {
        Mock -ModuleName OmniSecTestSecurity Get-OmniUacPolicy { [pscustomobject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 0; PromptOnSecureDesktop = 0 } }
        $r = Invoke-PluginScan -Module $script:SecurityMod -Context (New-TestContext)
        (Get-FindingById $r 'security-uac-elevate-without-prompting').Count | Should -Be 1
        (Get-FindingById $r 'security-uac-secure-desktop-disabled').Count | Should -Be 1
        $r.Metrics['UACEnabled'] | Should -BeTrue
        $r.Metrics['UACConsentPromptBehaviorAdmin'] | Should -Be 0
        $r.Metrics['UACPromptOnSecureDesktop'] | Should -BeFalse
        $r.Status | Should -Be 'Warning'
    }

    It 'treats missing values as the Windows defaults' {
        Mock -ModuleName OmniSecTestSecurity Get-OmniUacPolicy { [pscustomobject]@{ EnableLUA = $null; ConsentPromptBehaviorAdmin = $null; PromptOnSecureDesktop = $null } }
        $r = Invoke-PluginScan -Module $script:SecurityMod -Context (New-TestContext)
        @($r.Findings | Where-Object Component -eq 'Security/UAC').Count | Should -Be 0
        $r.Metrics['UACEnabled'] | Should -BeTrue
        $r.Metrics['UACConsentPromptBehaviorAdmin'] | Should -Be 5
        $r.Metrics['UACPromptOnSecureDesktop'] | Should -BeTrue
    }

    It 'accepts prompt-for-credentials settings (1..5) on the secure desktop' {
        Mock -ModuleName OmniSecTestSecurity Get-OmniUacPolicy { [pscustomobject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 2; PromptOnSecureDesktop = 1 } }
        $r = Invoke-PluginScan -Module $script:SecurityMod -Context (New-TestContext)
        @($r.Findings | Where-Object Component -eq 'Security/UAC').Count | Should -Be 0
    }

    It 'reports UAC disabled and nothing else about UAC' {
        Mock -ModuleName OmniSecTestSecurity Get-OmniUacPolicy { [pscustomobject]@{ EnableLUA = 0; ConsentPromptBehaviorAdmin = 0; PromptOnSecureDesktop = 0 } }
        $r = Invoke-PluginScan -Module $script:SecurityMod -Context (New-TestContext)
        $uac = @($r.Findings | Where-Object Component -eq 'Security/UAC')
        $uac.Count | Should -Be 1
        $uac[0].Title | Should -Be 'User Account Control (UAC) is disabled'
        $r.Metrics['UACEnabled'] | Should -BeFalse
    }

    It 'records Unknown when the policy key cannot be read' {
        Mock -ModuleName OmniSecTestSecurity Get-OmniUacPolicy { throw 'Cannot find path' }
        $r = Invoke-PluginScan -Module $script:SecurityMod -Context (New-TestContext)
        $r.Metrics['UACEnabled'] | Should -Be 'Unknown'
    }
}
