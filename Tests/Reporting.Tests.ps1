#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the reporting engine. Uses a synthetic OmniDiag.Session built from the
    public factory functions, so these run on any OS with no Windows data sources.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    function New-SyntheticSession {
        # System module result
        $sys = New-OmniResult -ModuleName 'System Information' -Category 'System'
        Set-OmniResultMetric -Result $sys -Name 'Manufacturer' -Value 'Contoso'
        Set-OmniResultMetric -Result $sys -Name 'Model' -Value 'TestBook 9000'
        Set-OmniResultMetric -Result $sys -Name 'CPU' -Value 'Test CPU @ 3.0GHz'
        Add-OmniFinding -Result $sys -Finding (New-OmniFinding -Title 'System inventory collected' -Severity 'Pass' -Component 'System')
        Complete-OmniResult -Result $sys | Out-Null

        # Event Logs result with timeline + groups
        $base = Get-Date '2026-06-01T08:00:00'
        $group = [pscustomobject]@{
            Severity = 'Critical'; Category = 'Disk'; ProviderName = 'Ntfs'; Id = 55
            Title = 'File system corruption detected'; Count = 3
            FirstSeen = $base; LastSeen = $base.AddHours(2); Channel = 'System'
            SampleMessage = 'corruption'; Recommendation = 'Run chkdsk'
        }
        $timelineEntry = [pscustomobject]@{ Time = $base.AddHours(1); Id = 41; Category = 'Power'; Title = 'Unexpected shutdown'; Provider = 'Kernel-Power' }
        $evt = New-OmniResult -ModuleName 'Event Logs' -Category 'Event Logs'
        Set-OmniResultMetric -Result $evt -Name 'TotalEvents' -Value 42
        Set-OmniResultMetric -Result $evt -Name 'CriticalEvents' -Value 1
        Set-OmniResultMetric -Result $evt -Name 'TopGroups' -Value @($group)
        Set-OmniResultMetric -Result $evt -Name 'Timeline' -Value @($timelineEntry)
        Add-OmniFinding -Result $evt -Finding (New-OmniFinding -Title 'File system corruption detected (x3)' -Severity 'Error' -Component 'Event Logs/Disk' -Recommendation 'Run chkdsk')
        Complete-OmniResult -Result $evt | Out-Null

        # Network result with a critical finding + an injection attempt
        $net = New-OmniResult -ModuleName 'Network' -Category 'Network'
        Add-OmniFinding -Result $net -Finding (New-OmniFinding -Title 'DNS resolution is failing' -Severity 'Critical' -Component 'Network/DNS' `
            -LikelyCause 'DNS server problem' -Recommendation 'Check DNS servers')
        Add-OmniFinding -Result $net -Finding (New-OmniFinding -Title '<script>alert(1)</script>' -Severity 'Warning' -Component 'Network/Test')
        Complete-OmniResult -Result $net | Out-Null

        $results = @($sys, $evt, $net)
        $logPath = Join-Path $TestDrive 'run.jsonl'
        Set-Content -Path $logPath -Value '{"Level":"Info","Message":"test"}' -Encoding UTF8

        $session = [pscustomobject]@{
            PSTypeName = 'OmniDiag.Session'
            StartTime  = $base; EndTime = $base.AddSeconds(30); DurationMs = 30000
            Cancelled  = $false
            TimeRange  = (Get-OmniTimeRange -Preset Last7Days)
            Host       = [pscustomobject]@{ ComputerName = 'TESTPC'; UserName = 'tester'; PSVersion = '5.1' }
            IsAdmin    = $false
            Results    = $results
            Summary    = ($results | Get-OmniHealthScore)
        }
        Add-Member -InputObject $session -MemberType NoteProperty -Name LogPath -Value $logPath
        return $session
    }

    $script:Session = New-SyntheticSession
}

Describe 'JSON export' {
    It 'writes valid JSON round-tripping the score' {
        $path = Join-Path $TestDrive 'r.json'
        Export-OmniJsonReport -Session $script:Session -Path $path | Should -Be $path
        Test-Path $path | Should -BeTrue
        $obj = Get-Content $path -Raw | ConvertFrom-Json
        $obj.Summary.Score | Should -Be $script:Session.Summary.Score
    }
}

Describe 'CSV export' {
    It 'writes a findings table including the DNS finding' {
        $path = Join-Path $TestDrive 'f.csv'
        Export-OmniCsvReport -Session $script:Session -Path $path | Out-Null
        $rows = Import-Csv $path
        ($rows | Where-Object { $_.Title -eq 'DNS resolution is failing' }) | Should -Not -BeNullOrEmpty
    }
    It 'writes an event table when event data is present' {
        $path = Join-Path $TestDrive 'e.csv'
        $res = Export-OmniEventCsvReport -Session $script:Session -Path $path
        $res | Should -Be $path
        (Import-Csv $path | Where-Object { $_.EventId -eq '55' }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'HTML export' {
    BeforeAll {
        $script:htmlPath = Join-Path $TestDrive 'r.html'
        Export-OmniHtmlReport -Session $script:Session -Path $script:htmlPath -BrandName 'Acme IT' | Out-Null
        $script:html = Get-Content $script:htmlPath -Raw
    }
    It 'produces a self-contained document with the score and brand' {
        $script:html | Should -Match 'OmniDiag Report'
        $script:html | Should -Match 'Acme IT'
        $script:html | Should -Match ([string]$script:Session.Summary.Score)
    }
    It 'includes device info and the event timeline' {
        $script:html | Should -Match 'Contoso'
        $script:html | Should -Match 'Unexpected shutdown'
        $script:html | Should -Match 'File system corruption'
    }
    It 'HTML-encodes user content to prevent injection' {
        $script:html | Should -Not -Match '<script>alert\(1\)</script>'
        $script:html | Should -Match '&lt;script&gt;'
    }
    It 'embeds the privacy notice' {
        $script:html | Should -Match 'Privacy notice'
    }
}

Describe 'Export-OmniReport coordinator' {
    It 'generates the requested formats and returns a report set' {
        $set = Export-OmniReport -Session $script:Session -OutputDirectory (Join-Path $TestDrive 'out') -Format Html, Json, Csv -BaseName 'unit'
        $set.PSTypeNames | Should -Contain 'OmniDiag.ReportSet'
        $set.Files.Count | Should -BeGreaterOrEqual 3
        foreach ($f in $set.Files) { Test-Path $f | Should -BeTrue }
    }
    It 'produces a ZIP package' {
        $set = Export-OmniReport -Session $script:Session -OutputDirectory (Join-Path $TestDrive 'zip') -Format Zip -BaseName 'pkg'
        $zip = $set.Files | Where-Object { $_ -like '*.zip' }
        Test-Path $zip | Should -BeTrue
    }
}

Describe 'Report hardening' {
    It 'neutralizes spreadsheet formulas in CSV cells' {
        $r = New-OmniResult -ModuleName 'Event Logs' -Category 'Event Logs'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title "=HYPERLINK(""http://x"",""click"")" -Severity 'Warning' -Component '@SUM(A1)' -Recommendation '+1')
        Complete-OmniResult -Result $r | Out-Null
        $path = Join-Path $TestDrive 'inj.csv'
        Export-OmniCsvReport -Session ([pscustomobject]@{ Results = @($r) }) -Path $path | Out-Null
        $row = Import-Csv -LiteralPath $path | Select-Object -First 1
        $row.Title | Should -BeLike "'=HYPERLINK*"
        $row.Component | Should -Be "'@SUM(A1)"
        $row.Recommendation | Should -Be "'+1"
    }

    It 'encodes summary numbers taken from an edited saved session' {
        $tampered = New-SyntheticSession
        $tampered.Summary.Score = '<img src=x onerror=alert(1)>'
        $path = Join-Path $TestDrive 'tampered.html'
        Export-OmniHtmlReport -Session $tampered -Path $path | Out-Null
        $html = Get-Content -LiteralPath $path -Raw
        $html | Should -Not -Match '<img src=x'
        $html | Should -Match '&lt;img src=x'
    }

    It 'resolves relative output paths against the PowerShell location' {
        Push-Location $TestDrive
        try {
            $set = Export-OmniReport -Session $script:Session -OutputDirectory 'relout' -Format Html, Json, Pdf -BaseName 'rel'
            @($set.Warnings).Count | Should -Be 0
            Join-Path $TestDrive 'relout/rel.html' | Should -Exist
            Join-Path $TestDrive 'relout/rel.pdf' | Should -Exist
        } finally { Pop-Location }
    }

    It 'exports every format for a session cancelled before any module finished' {
        $empty = [pscustomobject]@{ StartTime = Get-Date; EndTime = Get-Date; DurationMs = 0; Cancelled = $true; IsAdmin = $false; Results = @(); Summary = $null
            TimeRange = (Get-OmniTimeRange -Preset Last7Days); Host = $script:Session.Host }
        $set = Export-OmniReport -Session $empty -OutputDirectory (Join-Path $TestDrive 'empty') -Format Html, Json, Csv, Pdf, Zip -BaseName 'e'
        @($set.Warnings).Count | Should -Be 0
        @($set.Files | Where-Object { $_ }).Count | Should -BeGreaterOrEqual 4
    }
}
