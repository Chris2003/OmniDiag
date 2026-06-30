#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the Repair Center result models and the Invoke-OmniRepairStep runner.
    Every "real" step uses a side-effect-free action so the suite never changes the host.
#>

BeforeAll {
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/OmniDiag.psd1'
    Import-Module $manifest -Force -DisableNameChecking -Global

    function New-TestRepairContext {
        param([switch] $DryRun)
        New-OmniRepairContext -Logger (New-OmniLogger -MinimumLevel Error) -DryRun:$DryRun
    }
}

Describe 'New-OmniRepairResult' {
    It 'creates a typed, empty result' {
        $r = New-OmniRepairResult -Name 'X' -Category 'Net'
        $r.PSTypeNames | Should -Contain 'OmniDiag.RepairResult'
        $r.Status | Should -Be 'Unknown'
        $r.Steps.Count | Should -Be 0
        $r.RebootRequired | Should -BeFalse
    }
}

Describe 'Invoke-OmniRepairStep' {
    It 'does not execute the action in dry-run, and flags the result' {
        $flag = @{ ran = $false }
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        $ctx = New-TestRepairContext -DryRun
        $ok = Invoke-OmniRepairStep -Result $r -Context $ctx -Description 'noop' -Action { $flag.ran = $true }
        $ok | Should -BeTrue
        $flag.ran | Should -BeFalse
        $r.DryRun | Should -BeTrue
        $r.Steps[0].DryRun | Should -BeTrue
        (Complete-OmniRepairResult -Result $r).Status | Should -Be 'DryRun'
    }

    It 'executes the action and captures output when not a dry-run' {
        $flag = @{ ran = $false }
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        $ctx = New-TestRepairContext
        $ok = Invoke-OmniRepairStep -Result $r -Context $ctx -Description 'emit' -Action { $flag.ran = $true; 'hello' }
        $ok | Should -BeTrue
        $flag.ran | Should -BeTrue
        $r.Steps[0].Succeeded | Should -BeTrue
        $r.Steps[0].Output | Should -Match 'hello'
    }

    It 'marks a step failed when the action throws' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        $ctx = New-TestRepairContext
        $ok = Invoke-OmniRepairStep -Result $r -Context $ctx -Description 'boom' -Action { throw 'kaboom' }
        $ok | Should -BeFalse
        $r.Steps[0].Succeeded | Should -BeFalse
        (Complete-OmniRepairResult -Result $r).Status | Should -Be 'Failed'
    }

    It 'treats a non-zero exit code as failure by default' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        $ctx = New-TestRepairContext
        $ok = Invoke-OmniRepairStep -Result $r -Context $ctx -Description 'exit3' -Action { $global:LASTEXITCODE = 3 }
        $ok | Should -BeFalse
    }

    It 'ignores a non-zero exit code when -IgnoreExitCode is set' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        $ctx = New-TestRepairContext
        $ok = Invoke-OmniRepairStep -Result $r -Context $ctx -Description 'exit3' -IgnoreExitCode -Action { $global:LASTEXITCODE = 3 }
        $ok | Should -BeTrue
    }
}

Describe 'Complete-OmniRepairResult' {
    It 'derives Succeeded when all steps pass' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        Add-OmniRepairStep -Result $r -Description 'a' -Succeeded $true
        (Complete-OmniRepairResult -Result $r).Status | Should -Be 'Succeeded'
    }
    It 'derives RebootRequired when flagged and all steps pass' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        Add-OmniRepairStep -Result $r -Description 'a' -Succeeded $true
        $r.RebootRequired = $true
        (Complete-OmniRepairResult -Result $r).Status | Should -Be 'RebootRequired'
    }
    It 'honors an explicit status override' {
        $r = New-OmniRepairResult -Name 'X' -Category 'T'
        (Complete-OmniRepairResult -Result $r -Status 'Skipped').Status | Should -Be 'Skipped'
    }
}
