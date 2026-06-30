#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests for OmniDiag core models.
#>

BeforeAll {
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/OmniDiag.psd1'
    Import-Module $manifest -Force -DisableNameChecking
}

Describe 'Severity vocabulary' {
    It 'orders severities from least to most severe' {
        (Get-OmniSeverityRank 'Pass')     | Should -BeLessThan (Get-OmniSeverityRank 'Warning')
        (Get-OmniSeverityRank 'Warning')  | Should -BeLessThan (Get-OmniSeverityRank 'Error')
        (Get-OmniSeverityRank 'Error')    | Should -BeLessThan (Get-OmniSeverityRank 'Critical')
    }
    It 'throws on an unknown severity' {
        { Get-OmniSeverityRank 'Nope' } | Should -Throw
    }
    It 'exposes all five names' {
        (Get-OmniSeverityNames) | Should -HaveCount 5
    }
}

Describe 'New-OmniFinding' {
    It 'creates a typed finding with an auto-generated id' {
        $f = New-OmniFinding -Title 'DNS failing' -Severity 'Error' -Component 'Network/DNS'
        $f.PSTypeNames | Should -Contain 'OmniDiag.Finding'
        $f.Severity | Should -Be 'Error'
        $f.SeverityRank | Should -Be (Get-OmniSeverityRank 'Error')
        $f.Id | Should -Be 'network-dns-dns-failing'
    }
    It 'rejects an invalid severity' {
        { New-OmniFinding -Title 'x' -Severity 'Bogus' } | Should -Throw
    }
    It 'clamps confidence to 0-100' {
        { New-OmniFinding -Title 'x' -Severity 'Pass' -Confidence 150 } | Should -Throw
    }
}

Describe 'Result lifecycle' {
    It 'derives Healthy when only Pass findings exist' {
        $r = New-OmniResult -ModuleName 'M' -Category 'C'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'ok' -Severity 'Pass')
        $done = Complete-OmniResult -Result $r
        $done.Status | Should -Be 'Healthy'
        $done.EndTime | Should -Not -BeNullOrEmpty
    }
    It 'derives Critical when an Error is present' {
        $r = New-OmniResult -ModuleName 'M' -Category 'C'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'boom' -Severity 'Error')
        (Complete-OmniResult -Result $r).Status | Should -Be 'Critical'
    }
    It 'derives Warning for warnings only' {
        $r = New-OmniResult -ModuleName 'M' -Category 'C'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'meh' -Severity 'Warning')
        (Complete-OmniResult -Result $r).Status | Should -Be 'Warning'
    }
    It 'honors an explicit status override' {
        $r = New-OmniResult -ModuleName 'M' -Category 'C'
        (Complete-OmniResult -Result $r -Status 'Skipped').Status | Should -Be 'Skipped'
    }
    It 'records metrics' {
        $r = New-OmniResult -ModuleName 'M' -Category 'C'
        Set-OmniResultMetric -Result $r -Name 'FreeGB' -Value 42
        $r.Metrics['FreeGB'] | Should -Be 42
    }
}

Describe 'Get-OmniTimeRange' {
    It 'resolves Last24Hours to a ~24h window' {
        $tr = Get-OmniTimeRange -Preset Last24Hours
        [math]::Round(($tr.End - $tr.Start).TotalHours) | Should -Be 24
        $tr.Preset | Should -Be 'Last24Hours'
    }
    It 'supports a custom range' {
        $start = (Get-Date).AddDays(-3)
        $tr = Get-OmniTimeRange -Start $start
        $tr.Preset | Should -Be 'Custom'
        $tr.Start  | Should -Be $start
    }
}

Describe 'Get-OmniHealthScore' {
    It 'scores 100 with no findings' {
        $r = Complete-OmniResult -Result (New-OmniResult -ModuleName 'M' -Category 'C')
        (Get-OmniHealthScore -Result @($r)).Score | Should -Be 100
    }
    It 'penalizes critical findings heavily' {
        $r = New-OmniResult -ModuleName 'M' -Category 'C'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'bad' -Severity 'Critical' -Recommendation 'fix it')
        $done = Complete-OmniResult -Result $r
        $sum = Get-OmniHealthScore -Result @($done)
        $sum.Score | Should -BeLessThan 100
        $sum.Counts.Critical | Should -Be 1
        $sum.TopRecommendations | Should -HaveCount 1
    }
}
