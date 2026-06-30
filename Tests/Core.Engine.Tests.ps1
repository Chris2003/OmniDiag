#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests for the OmniDiag orchestration engine. Uses in-memory fake
    modules (New-Module) so the engine is exercised without touching the disk
    or any Windows data source.
#>

BeforeAll {
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/OmniDiag.psd1'
    Import-Module $manifest -Force -DisableNameChecking -Global

    function New-FakeRegistration {
        param(
            [string] $Name = 'Fake',
            [string] $Category = 'Test',
            [string] $Severity = 'Pass',
            [bool] $RequiresAdmin = $false,
            [switch] $Throw
        )
        # Arguments are bound into the new module's session state via -ArgumentList
        # so the convention functions close over them (New-Module has no $using:).
        $sb = {
            param($ModName, $ModCategory, $ModSeverity, $ShouldThrow)
            function Get-OmniModuleManifest { @{ Name = $ModName; Category = $ModCategory } }
            function Invoke-OmniModuleScan {
                param($Context)
                if ($ShouldThrow) { throw 'intentional failure' }
                $r = New-OmniResult -ModuleName $ModName -Category $ModCategory
                Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'fake' -Severity $ModSeverity)
                return (Complete-OmniResult -Result $r)
            }
            Export-ModuleMember -Function *
        }
        $mod = New-Module -Name "Fake_$Name" -ScriptBlock $sb -ArgumentList $Name, $Category, $Severity, ([bool]$Throw)
        return [pscustomobject]@{
            Name = $Name; Category = $Category; Description = ''
            RequiresAdmin = $RequiresAdmin; Order = 1; Enabled = $true
            ModuleInfo = $mod; SourceFile = ''
        }
    }

    function New-TestContext {
        param([System.Threading.CancellationToken] $Token = [System.Threading.CancellationToken]::None)
        $logger = New-OmniLogger -MinimumLevel Error   # no file, no console noise
        New-OmniContext -Logger $logger -CancellationToken $Token
    }
}

Describe 'Invoke-OmniSession' {
    It 'runs a module and aggregates a summary' {
        $reg = New-FakeRegistration -Severity 'Pass'
        $session = Invoke-OmniSession -Registration @($reg) -Context (New-TestContext)
        $session.PSTypeNames | Should -Contain 'OmniDiag.Session'
        $session.Results | Should -HaveCount 1
        $session.Results[0].Status | Should -Be 'Healthy'
        $session.Summary.Score | Should -Be 100
        $session.Cancelled | Should -BeFalse
    }

    It 'captures a module exception as a Failed result instead of aborting' {
        $good = New-FakeRegistration -Name 'Good' -Severity 'Pass'
        $bad  = New-FakeRegistration -Name 'Bad' -Throw
        $session = Invoke-OmniSession -Registration @($bad, $good) -Context (New-TestContext)
        $session.Results | Should -HaveCount 2
        ($session.Results | Where-Object Status -eq 'Failed') | Should -HaveCount 1
        ($session.Results | Where-Object Status -eq 'Healthy') | Should -HaveCount 1
    }

    It 'skips admin-only modules when not elevated' {
        $reg = New-FakeRegistration -Name 'NeedsAdmin' -RequiresAdmin $true
        $ctx = New-TestContext
        $ctx.IsAdmin = $false
        $session = Invoke-OmniSession -Registration @($reg) -Context $ctx
        $session.Results[0].Status | Should -Be 'Skipped'
    }

    It 'honors a pre-cancelled token and runs nothing' {
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        $reg = New-FakeRegistration
        $session = Invoke-OmniSession -Registration @($reg) -Context (New-TestContext -Token $cts.Token)
        $session.Cancelled | Should -BeTrue
        $session.Results | Should -HaveCount 0
    }

    It 'applies category filters' {
        $a = New-FakeRegistration -Name 'A' -Category 'System'
        $b = New-FakeRegistration -Name 'B' -Category 'Network'
        $session = Invoke-OmniSession -Registration @($a, $b) -Context (New-TestContext) -IncludeCategory 'Network'
        $session.Results | Should -HaveCount 1
        $session.Results[0].Category | Should -Be 'Network'
    }
}
