#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    function New-TestSession {
        param([object[]] $Findings, [int] $Score)
        $r = New-OmniResult -ModuleName 'Test' -Category Network
        foreach ($f in $Findings) { Add-OmniFinding -Result $r -Finding $f }
        Complete-OmniResult -Result $r | Out-Null
        [pscustomobject]@{ StartTime = Get-Date; Results = @($r); Summary = [pscustomobject]@{ Score = $Score; Grade = 'Warning' } }
    }

    $script:Dns = New-OmniFinding -Id 'network-dns-failure' -Title 'DNS resolution failed' -Severity Error -Component 'Network/DNS' -LikelyCause 'Resolver unreachable.' -Recommendation 'Verify DNS servers.'
    $script:Cpu = New-OmniFinding -Id 'performance-cpu-high' -Title 'High CPU usage' -Severity Warning -Component 'Performance/CPU' -Recommendation 'Review top processes.'
    $script:Disk = New-OmniFinding -Id 'storage-low-space' -Title 'Low free space' -Severity Warning -Component 'Storage/Usage'
    $script:CpuWorse = New-OmniFinding -Id 'performance-cpu-high' -Title 'High CPU usage' -Severity Critical -Component 'Performance/CPU'
    $script:Ok = New-OmniFinding -Title 'Firewall enabled' -Severity Pass -Component 'Security/Firewall'
    $script:Before = New-TestSession -Findings @($script:Dns, $script:Cpu, $script:Ok) -Score 70
    $script:Runbook = [pscustomobject]@{ Id = 'rb-dns'; Title = 'DNS resolution failures'; Approved = $true; Owner = 'Net'; AppliesTo = @('network/dns'); Tags = @('dns', 'lookup'); Body = 'Check resolvers and flush the cache.' }
}

Describe 'Saved sessions' {
    It 'round-trips a session through a JSON report' {
        $path = Join-Path $TestDrive 'before.json'
        Export-OmniJsonReport -Session $script:Before -Path $path | Out-Null
        $loaded = Import-OmniSession -Path $path
        $loaded.SourcePath | Should -Be (Get-Item $path).FullName
        @(Get-OmniSessionFinding -Session $loaded).Id | Should -Contain 'network-dns-failure'
    }

    It 'restores report-ready shapes so a reloaded session exports every format' {
        $path = Join-Path $TestDrive 'metrics.json'
        $live = Invoke-OmniDiag -IncludeModule 'System Information' -Quiet -LogPath (Join-Path $TestDrive 'log.jsonl')
        Export-OmniJsonReport -Session $live -Path $path | Out-Null
        $loaded = Import-OmniSession -Path $path
        $loaded.Results[0].Metrics -is [System.Collections.IDictionary] | Should -BeTrue
        Export-OmniEventCsvReport -Session $loaded -Path (Join-Path $TestDrive 'e.csv') | Should -BeNullOrEmpty
        Export-OmniReportPackage -Session $loaded -Path (Join-Path $TestDrive 'pkg.zip') | Should -Exist
    }

    It 'rejects files that are not OmniDiag sessions' {
        $bad = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $bad -Value '{"hello":1}'
        { Import-OmniSession -Path $bad } | Should -Throw '*no Results*'
    }

    It 'excludes pass findings unless asked' {
        @(Get-OmniSessionFinding -Session $script:Before).Count | Should -Be 2
        @(Get-OmniSessionFinding -Session $script:Before -IncludePass).Count | Should -Be 3
    }
}

Describe 'Evidence search' {
    It 'ranks the finding that matches the question first' {
        $hits = @(Search-OmniEvidence -Query 'why are DNS lookups failing?' -Session $script:Before)
        $hits[0].Id | Should -Be 'network-dns-failure'
        $hits.Id | Should -Not -Contain 'performance-cpu-high'
    }

    It 'returns runbooks linked to the matching findings' {
        $hits = @(Search-OmniEvidence -Query 'dns resolution' -Session $script:Before -Runbook @($script:Runbook))
        $rb = $hits | Where-Object Type -eq 'Runbook'
        $rb.Id | Should -Be 'rb-dns'
        $rb.LinkedFindingIds | Should -Contain 'network-dns-failure'
    }

    It 'returns nothing for stop-word-only queries' {
        @(Search-OmniEvidence -Query 'what is the' -Session $script:Before).Count | Should -Be 0
    }
}

Describe 'Before/after comparison' {
    It 'classifies resolved, new, and worsened findings with a score delta' {
        $after = New-TestSession -Findings @($script:CpuWorse, $script:Disk) -Score 65
        $cmp = Compare-OmniSession -Before $script:Before -After $after
        $cmp.Resolved.Id | Should -Contain 'network-dns-failure'
        $cmp.New.Id | Should -Contain 'storage-low-space'
        ($cmp.Persisting | Where-Object Id -eq 'performance-cpu-high').Change | Should -Be 'Worsened'
        $cmp.ScoreDelta | Should -Be -5
        $cmp.Verdict | Should -Be 'Mixed'
    }

    It 'reports Improved when issues were only resolved, from saved files' {
        $beforePath = Join-Path $TestDrive 'b.json'; $afterPath = Join-Path $TestDrive 'a.json'
        Export-OmniJsonReport -Session $script:Before -Path $beforePath | Out-Null
        Export-OmniJsonReport -Session (New-TestSession -Findings @($script:Cpu) -Score 88) -Path $afterPath | Out-Null
        $cmp = Compare-OmniSession -Before $beforePath -After $afterPath
        $cmp.Verdict | Should -Be 'Improved'
        $cmp.ScoreDelta | Should -Be 18
        ($cmp.Persisting | Where-Object Id -eq 'performance-cpu-high').Change | Should -Be 'Unchanged'
    }

    It 'reports Unchanged for identical sessions' {
        (Compare-OmniSession -Before $script:Before -After $script:Before).Verdict | Should -Be 'Unchanged'
    }
}
