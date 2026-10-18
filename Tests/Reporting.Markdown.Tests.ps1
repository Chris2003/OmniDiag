#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Markdown exporter (ConvertTo-OmniMarkdownReport / Export-OmniMarkdownReport and the
    'Md' format of Export-OmniReport). OS-independent: uses the fixed fixture session.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    . (Join-Path $PSScriptRoot 'golden/ReportFixture.ps1')
    $script:Session = New-OmniReportFixtureSession
    $script:Md = ConvertTo-OmniMarkdownReport -Session $script:Session -BrandName 'Acme IT'
}

Describe 'ConvertTo-OmniMarkdownReport' {
    It 'starts with a title, the brand, and a summary table' {
        $script:Md | Should -Match '^# OmniDiag Report'
        $script:Md | Should -Match '_Prepared by Acme IT_'
        $script:Md | Should -Match '\| Computer \| FIXTURE-PC \|'
        $script:Md | Should -Match ('\| Health score \| {0}/100 \|' -f $script:Session.Summary.Score)
        $script:Md | Should -Match '\| Findings \| 3 critical, 1 warning, 2 info, 1 passed \|'
    }

    It 'lists every module with its contract id, group, and status' {
        $script:Md | Should -Match '\| DNS Resolver \| `network.dns-resolver` \| network \| Critical \| 3 \|'
        $script:Md | Should -Match '\| BitLocker \| `security.bitlocker` \| security \| Skipped \(RequiresElevation\) \| 1 \|'
        $script:Md | Should -Match '\| Disk \| `storage.disk` \| storage \|'
    }

    It 'groups non-pass findings by v1 severity with the native severity alongside' {
        $script:Md | Should -Match '## Critical \(3\)'
        $script:Md | Should -Match '## Warning \(1\)'
        $script:Md | Should -Match '## Info \(2\)'
        $script:Md | Should -Match '- \*\*Severity:\*\* Critical \(Error\)'
        $script:Md | Should -Match '- \*\*Likely cause:\*\* DNS server unreachable\. \(confidence 80%\)'
        $script:Md.IndexOf('## Critical') | Should -BeLessThan $script:Md.IndexOf('## Warning')
    }

    It 'escapes markup, pipes, and line breaks from session text' {
        $script:Md | Should -Not -Match '<script>'
        $script:Md | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $script:Md | Should -Match 'timed out\. Second line \\\| pipe'
    }

    It 'summarizes passing checks unless -IncludePass is given' {
        $script:Md | Should -Match '## Passed checks \(1\)'
        $script:Md | Should -Not -Match 'System inventory collected'
        ConvertTo-OmniMarkdownReport -Session $script:Session -IncludePass | Should -Match '- System inventory collected - System Information'
    }

    It 'ends with the privacy notice' {
        $script:Md | Should -Match 'Privacy notice'
    }

    It 'handles a session with no modules' {
        $md = ConvertTo-OmniMarkdownReport -Session ([pscustomobject]@{ Results = @(); Summary = $null; Cancelled = $true })
        $md | Should -Match 'No modules ran\.'
        $md | Should -Match '\| Health score \| n/a \|'
        $md | Should -Match 'Cancelled'
    }
}

Describe 'Export-OmniMarkdownReport' {
    It 'writes UTF-8 without a BOM and returns the path' {
        $path = Join-Path $TestDrive 'r.md'
        Export-OmniMarkdownReport -Session $script:Session -Path $path | Should -Be $path
        $bytes = [System.IO.File]::ReadAllBytes($path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        [System.IO.File]::ReadAllText($path) | Should -Match '# OmniDiag Report'
    }

    It 'is available as the Md format of Export-OmniReport' {
        $set = Export-OmniReport -Session $script:Session -OutputDirectory (Join-Path $TestDrive 'md') -Format Md -BaseName 'fixture'
        $set.Files | Should -Be @((Join-Path (Join-Path $TestDrive 'md') 'fixture.md'))
    }
}
