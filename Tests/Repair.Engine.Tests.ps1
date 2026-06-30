#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the repair engine. Real-execution assertions use harmless fake repairs
    (a temp-file marker and a reboot flag); the only "real" repair touched is admin-
    gated off so its action never runs. Restore-point behavior is checked via the
    dry-run path, which never creates a checkpoint.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:RepairsPath = Join-Path $root 'src/Repairs'
    $script:Logger = New-OmniLogger -MinimumLevel Error

    # --- Build a temp folder of harmless fake repairs --------------------------
    $script:FakeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("omnidiag-fakerepairs-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:FakeDir -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $script:FakeDir 'FakeMarker.psm1') -Value @'
function Get-OmniRepairManifest { @{ Name = 'Fake Marker'; Category = 'Test'; Risk = 'Safe'; RequiresAdmin = $false; Order = 1 } }
function Invoke-OmniRepairAction {
    param($Context)
    $r = New-OmniRepairResult -Name 'Fake Marker' -Category 'Test'
    $marker = $Context.Config['Marker']
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'write marker file' -Action {
        Set-Content -LiteralPath $marker -Value 'ran' -Force
    } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}
Export-ModuleMember -Function @('Get-OmniRepairManifest','Invoke-OmniRepairAction')
'@

    Set-Content -LiteralPath (Join-Path $script:FakeDir 'FakeReboot.psm1') -Value @'
function Get-OmniRepairManifest { @{ Name = 'Fake Reboot'; Category = 'Test'; Risk = 'Moderate'; RequiresAdmin = $false; RebootHint = $true; Order = 2 } }
function Invoke-OmniRepairAction {
    param($Context)
    $r = New-OmniRepairResult -Name 'Fake Reboot' -Category 'Test'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'noop' -Action { 'ok' } | Out-Null
    $r.RebootRequired = $true
    return (Complete-OmniRepairResult -Result $r)
}
Export-ModuleMember -Function @('Get-OmniRepairManifest','Invoke-OmniRepairAction')
'@

    $script:Fakes = @(Get-OmniRepair -Path $script:FakeDir -Logger $script:Logger)
}

AfterAll {
    Remove-Item -LiteralPath $script:FakeDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-OmniRepair dry-run' {
    It 'runs the whole built-in catalog with no side effects' {
        $repairs = @(Get-OmniRepair -Path $script:RepairsPath -Logger $script:Logger)
        $ctx = New-OmniRepairContext -Logger $script:Logger -DryRun
        $session = Invoke-OmniRepair -Registration $repairs -Context $ctx
        $session.PSTypeNames | Should -Contain 'OmniDiag.RepairSession'
        @($session.Results | Where-Object Status -ne 'DryRun').Count | Should -Be 0
        $session.RebootRequired | Should -BeFalse
    }

    It 'does not create a restore point in dry-run, even for a RestorePoint repair' {
        $winsock = @(Get-OmniRepair -Path $script:RepairsPath -Logger $script:Logger | Where-Object Name -eq 'Reset Winsock Catalog')
        $ctx = New-OmniRepairContext -Logger $script:Logger -DryRun
        $session = Invoke-OmniRepair -Registration $winsock -Context $ctx
        $session.RestorePoint | Should -BeNullOrEmpty
    }

    It 'does not execute the marker action in dry-run' {
        $marker = Join-Path $script:FakeDir 'dryrun.marker'
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $ctx = New-OmniRepairContext -Logger $script:Logger -DryRun -Config @{ Marker = $marker }
        Invoke-OmniRepair -Registration @($script:Fakes | Where-Object Name -eq 'Fake Marker') -Context $ctx | Out-Null
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
}

Describe 'Invoke-OmniRepair real execution (harmless fakes)' {
    It 'executes the action when not a dry-run' {
        $marker = Join-Path $script:FakeDir 'real.marker'
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $ctx = New-OmniRepairContext -Logger $script:Logger -Config @{ Marker = $marker }
        $session = Invoke-OmniRepair -Registration @($script:Fakes | Where-Object Name -eq 'Fake Marker') -Context $ctx
        $session.Results[0].Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath $marker | Should -BeTrue
    }

    It 'rolls up RebootRequired across the session' {
        $ctx = New-OmniRepairContext -Logger $script:Logger
        $session = Invoke-OmniRepair -Registration @($script:Fakes | Where-Object Name -eq 'Fake Reboot') -Context $ctx
        $session.Results[0].Status | Should -Be 'RebootRequired'
        $session.RebootRequired | Should -BeTrue
    }
}

Describe 'Invoke-OmniRepair admin gating' {
    It 'skips an admin-only repair when the context is not elevated (action never runs)' {
        $winsock = @(Get-OmniRepair -Path $script:RepairsPath -Logger $script:Logger | Where-Object Name -eq 'Reset Winsock Catalog')
        $ctx = New-OmniRepairContext -Logger $script:Logger
        $ctx.IsAdmin = $false   # force the not-elevated path regardless of how tests run
        $session = Invoke-OmniRepair -Registration $winsock -Context $ctx
        $session.Results[0].Status | Should -Be 'Skipped'
    }
}
