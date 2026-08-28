#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Contract + integration coverage for the full granular scanner set. Discovers every
    module under src/Modules, validates the plugin contract, then runs them all through
    the real engine on the host and asserts none threw and each returned a well-formed
    OmniDiag.Result. This replaces the old per-module suites (SystemInformation, M3).

    The live scan is genuinely exercised, so this suite takes a while on a real Windows
    host; it self-skips the execution assertions on non-Windows (no data sources).
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:ModulesPath = Join-Path $root 'src/Modules'
    $script:Logger = New-OmniLogger -MinimumLevel Error
    $script:Regs = @(Get-OmniModule -Path $script:ModulesPath -Logger $script:Logger)

    $script:IsWindowsHost = $true
    try { if ($IsWindows -eq $false) { $script:IsWindowsHost = $false } } catch { }
}

Describe 'Scanner discovery + contract' {
    It 'discovers the full granular scanner set (38+)' {
        $script:Regs.Count | Should -BeGreaterOrEqual 38
    }

    It 'gives every scanner a unique name' {
        $names = $script:Regs.Name
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
    }

    It 'gives every scanner a Name and Category' {
        foreach ($r in $script:Regs) {
            $r.Name     | Should -Not -BeNullOrEmpty
            $r.Category | Should -Not -BeNullOrEmpty
        }
    }

    It 'exposes the expected category groups' {
        $cats = $script:Regs.Category | Select-Object -Unique
        foreach ($c in @('System', 'Performance', 'Hardware', 'Storage', 'Network', 'Security', 'Event Logs', 'Identity', 'Cloud')) {
            $cats | Should -Contain $c
        }
    }
}

Describe 'All scanners execute cleanly through the engine' {
    BeforeAll {
        if ($script:IsWindowsHost) {
            $ctx = New-OmniContext -Logger $script:Logger -TimeRange (Get-OmniTimeRange -Preset Last24Hours)
            $script:Session = Invoke-OmniSession -Registration $script:Regs -Context $ctx
        }
    }

    It 'runs every discovered scanner' {
        if (-not $script:IsWindowsHost) { Set-ItResult -Skipped -Because 'non-Windows host'; return }
        $script:Session.Results.Count | Should -Be $script:Regs.Count
    }

    It 'no scanner throws (every result has a null Error)' {
        if (-not $script:IsWindowsHost) { Set-ItResult -Skipped -Because 'non-Windows host'; return }
        $threw = @($script:Session.Results | Where-Object { $_.Error })
        $threw.Count | Should -Be 0 -Because ("these scanners errored: " + (($threw | ForEach-Object { "$($_.ModuleName): $($_.Error)" }) -join ' | '))
    }

    It 'every result is a well-formed OmniDiag.Result with a valid status' {
        if (-not $script:IsWindowsHost) { Set-ItResult -Skipped -Because 'non-Windows host'; return }
        $valid = @('Healthy', 'Warning', 'Critical', 'Unknown', 'Skipped', 'Failed')
        foreach ($r in $script:Session.Results) {
            $r.PSTypeNames | Should -Contain 'OmniDiag.Result'
            $r.Status | Should -BeIn $valid
        }
    }

    It 'produces a scored summary' {
        if (-not $script:IsWindowsHost) { Set-ItResult -Skipped -Because 'non-Windows host'; return }
        $summary = @($script:Session.Results) | Get-OmniHealthScore
        $summary.Score | Should -BeGreaterOrEqual 0
        $summary.Score | Should -BeLessOrEqual 100
    }
}
