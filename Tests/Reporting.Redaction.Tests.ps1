#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Phase 3 acceptance test for report redaction (docs/ROADMAP.md): a fixture session
    with identifiers planted everywhere they can appear is exported with -Redact to
    JSON, HTML, CSV (findings + events), Markdown, PDF, and ZIP (every entry, including
    the README and the run log). No planted identifier may occur - case-insensitively -
    in any file's content or any file name, and the pseudonyms must agree across files.
    The PDF writer emits uncompressed content streams (verified below), so its text is
    scanned after undoing the PDF string escapes. OS-independent.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    if (-not (Get-Command New-OmniRedactionContext -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $script:Root 'src/Core/Redaction.psm1') -Force -DisableNameChecking -Global
    }

    function New-RedactionFixtureSession([string] $LogPath) {
        $t0 = [datetime]::new(2026, 6, 1, 8, 0, 0, [System.DateTimeKind]::Utc)

        $sys = New-OmniResult -ModuleName 'System Information' -Category 'System'
        Add-OmniFinding -Result $sys -Finding (New-OmniFinding -Id 'system-host' -Title 'Device ACME-WS-042 inventoried' -Severity 'Pass' -Component 'System/ACME-WS-042')
        Set-OmniResultMetric -Result $sys -Name 'ComputerName' -Value 'ACME-WS-042'
        Set-OmniResultMetric -Result $sys -Name 'Fqdn' -Value 'acme-ws-042.corp.contoso.com'
        Set-OmniResultMetric -Result $sys -Name 'Domain' -Value 'corp.contoso.com'
        Set-OmniResultMetric -Result $sys -Name 'LoggedOnUser' -Value 'CONTOSO\jdoe'
        Set-OmniResultMetric -Result $sys -Name 'ProfilePath' -Value 'C:\Users\jdoe'
        Set-OmniResultMetric -Result $sys -Name 'UserSid' -Value 'S-1-5-21-1004336348-1177238915-682003330-1001'
        Set-OmniResultMetric -Result $sys -Name 'Last user on ACME-WS-042' -Value 'jdoe'
        Set-OmniResultMetric -Result $sys -Name 'Adapters' -Value @(
            [pscustomobject]@{ Name = 'Ethernet'; Mac = '00-15-5D-AA-BB-CC'; IPv4 = '10.20.30.40'; IPv6 = 'fe80::1c2d:3e4f:5a6b:7c8d%12' },
            [pscustomobject]@{ Name = 'Wi-Fi'; Mac = '00:15:5d:aa:bb:dd'; IPv4 = '192.168.77.12'; IPv6 = '2001:0db8:0000:0000:0000:ff00:0042:8329' }
        )
        Set-OmniResultMetric -Result $sys -Name 'InstallDate' -Value $t0.AddDays(-30)
        $null = Complete-OmniResult -Result $sys

        $net = New-OmniResult -ModuleName 'Network' -Category 'Network'
        Add-OmniFinding -Result $net -Finding (New-OmniFinding -Id 'network-gateway' -Title 'Gateway 10.20.30.40 unreachable from ACME-WS-042' `
            -Severity 'Critical' -Component 'Network/00-15-5D-AA-BB-CC' -Detail 'Adapter 00:15:5D:AA:BB:CC (fe80::1c2d:3e4f:5a6b:7c8d) on acme-ws-042.corp.contoso.com lost 10.20.30.40.' `
            -LikelyCause 'CONTOSO\jdoe changed the static address to 192.168.77.12.' -Confidence 70 `
            -Recommendation 'Ask jdoe to restore DHCP; check 2001:db8::ff00:42:8329 too.' `
            -Data ([ordered]@{
                Peer     = '10.20.30.40'
                Owner    = 'CONTOSO\jdoe'
                Sids     = @('S-1-5-21-1004336348-1177238915-682003330-1001', 'S-1-5-18')
                Profiles = @{ 'C:\Users\msmith' = 12.5; 'C:\Users\jdoe' = 3 }
                Nested   = [pscustomobject]@{ Deeper = [pscustomobject]@{ Upn = 'jdoe@contoso.com'; Path = 'C:\Users\msmith\AppData\Local\Temp\x.log' } }
            }))
        Add-OmniFinding -Result $net -Finding (New-OmniFinding -Id 'network-profile' -Title 'Profile msmith is 20 GB' -Severity 'Warning' `
            -Component 'Storage/C:\Users\msmith' -Recommendation 'Clean C:\Users\msmith\Downloads on ACME-WS-042.')
        $null = Complete-OmniResult -Result $net

        $evt = New-OmniResult -ModuleName 'Event Logs' -Category 'Event Logs'
        Add-OmniFinding -Result $evt -Finding (New-OmniFinding -Id 'events-logon' -Title 'Logon failures for CONTOSO\jdoe' -Severity 'Error' `
            -Component 'Security/4625' -Detail '12 failures from 192.168.77.12 (S-1-5-21-1004336348-1177238915-682003330-1001).' -Recommendation 'Reset the password of jdoe.')
        Set-OmniResultMetric -Result $evt -Name 'TotalEvents' -Value 40
        Set-OmniResultMetric -Result $evt -Name 'ErrorEvents' -Value 12
        Set-OmniResultMetric -Result $evt -Name 'TopGroups' -Value @(
            [pscustomobject]@{
                Severity = 'Error'; Category = 'Security'; ProviderName = 'Microsoft-Windows-Security-Auditing'; Id = 4625
                Title = 'Logon failure for CONTOSO\jdoe on ACME-WS-042'; Count = 12; FirstSeen = $t0.AddHours(-5); LastSeen = $t0.AddHours(-1)
                Channel = 'Security'; SampleMessage = 'Account jdoe (S-1-5-21-1004336348-1177238915-682003330-1001) from 192.168.77.12 / fe80::1c2d:3e4f:5a6b:7c8d'
                Recommendation = 'Check C:\Users\jdoe\AppData for cached credentials.'
            }
        )
        Set-OmniResultMetric -Result $evt -Name 'Timeline' -Value @(
            [pscustomobject]@{ Time = $t0.AddHours(-2); Title = 'ACME-WS-042 rebooted by CONTOSO\jdoe'; Category = 'System' },
            [pscustomobject]@{ Time = $t0.AddHours(-1); Title = 'DHCP lease 10.20.30.40 lost (MAC 00-15-5D-AA-BB-CC)'; Category = 'Network' }
        )
        $null = Complete-OmniResult -Result $evt

        $results = @($sys, $net, $evt)
        return [pscustomobject]@{
            PSTypeName = 'OmniDiag.Session'
            StartTime  = $t0
            EndTime    = $t0.AddSeconds(5)
            DurationMs = 5000
            Cancelled  = $false
            TimeRange  = (Get-OmniTimeRange -Preset Last7Days)
            Host       = [pscustomobject]@{ ComputerName = 'ACME-WS-042'; UserName = 'CONTOSO\jdoe'; PSVersion = '5.1.19041.1' }
            IsAdmin    = $false
            Results    = $results
            Summary    = ($results | Get-OmniHealthScore)
            LogPath    = $LogPath
        }
    }

    # Every planted identifier (and fragments of the compressed/expanded IPv6 forms).
    $script:Planted = @(
        'ACME-WS-042', 'corp.contoso.com', 'contoso', 'jdoe', 'msmith',
        'S-1-5-21-1004336348', '1004336348-1177238915',
        '10.20.30.40', '192.168.77.12',
        'fe80::1c2d', '1c2d:3e4f:5a6b:7c8d', '2001:db8', '2001:0db8', 'ff00:42:8329', 'ff00:0042:8329',
        '00-15-5D-AA-BB-CC', '00:15:5D:AA:BB:CC', '00-15-5D-AA-BB-DD', '00:15:5d:aa:bb:dd'
    )

    function Read-ReportText([string] $Path) {
        if ($Path -like '*.pdf') {
            # Latin-1 maps bytes one-to-one; undo the PDF literal-string escapes.
            $raw = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($Path))
            return $raw.Replace('\\', [string][char]1).Replace('\(', '(').Replace('\)', ')').Replace([string][char]1, '\')
        }
        return [System.IO.File]::ReadAllText($Path)
    }

    $script:Out = Join-Path $TestDrive 'redacted'
    $script:LogPath = Join-Path $TestDrive 'omnidiag-run.jsonl'
    $logLines = @(
        '{"time":"2026-06-01T08:00:00.000Z","level":"Info","source":"Engine","message":"Scan started on ACME-WS-042 by CONTOSO\\jdoe"}',
        '{"time":"2026-06-01T08:00:01.000Z","level":"Info","source":"Paths","message":"Data folder C:\\Users\\jdoe\\Downloads\\OmniDiag\\OmniDiagData"}',
        '{"time":"2026-06-01T08:00:02.000Z","level":"Warn","source":"Network","message":"Gateway 10.20.30.40 / fe80::1c2d:3e4f:5a6b:7c8d on 00-15-5D-AA-BB-CC timed out (acme-ws-042.corp.contoso.com)"}'
    )
    [System.IO.File]::WriteAllText($script:LogPath, (($logLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))

    $script:Session = New-RedactionFixtureSession -LogPath $script:LogPath
    $script:SessionBefore = ConvertTo-OmniJsonText -InputObject $script:Session

    $script:MapPath = Join-Path (Join-Path $TestDrive 'private') 'redaction-map.json'
    $output = @(Export-OmniReport -Session $script:Session -OutputDirectory $script:Out -Format Html, Json, Csv, Md, Pdf, Zip `
        -Redact -RedactionMapPath $script:MapPath -Option @{ command = 'report'; output = 'C:\Users\jdoe\Reports' } 3>&1)
    $script:MapWarnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    $script:Set = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]

    $script:Extract = Join-Path $TestDrive 'zip'
    $zip = @($script:Set.Files | Where-Object { $_ -like '*.zip' })[0]
    Expand-Archive -LiteralPath $zip -DestinationPath $script:Extract

    # Every shareable file: the top-level outputs plus every ZIP entry.
    $script:AllFiles = @(@($script:Set.Files) + @(Get-ChildItem -LiteralPath $script:Extract -File -Recurse | ForEach-Object { $_.FullName }))
    $script:Text = @{}
    foreach ($f in $script:AllFiles) { $script:Text[$f] = Read-ReportText $f }
    $script:ZipText = @{}
    foreach ($f in Get-ChildItem -LiteralPath $script:Extract -File) { $script:ZipText[$f.Name] = Read-ReportText $f.FullName }

    $script:Map = (Get-Content -LiteralPath $script:MapPath -Raw | ConvertFrom-Json)
    function Get-Pseudonym([string] $Original) {
        @($script:Map.entries | Where-Object { $_.original -eq $Original })[0].pseudonym
    }
    function Get-OutputText([string] $Extension) {
        $script:Text[@($script:Set.Files | Where-Object { $_ -like "*$Extension" })[0]]
    }
}

Describe 'Redacted report bundle (Phase 3 acceptance)' {
    It 'wrote every format and the ZIP entries' {
        $script:Set.Redacted | Should -BeTrue
        $script:Set.Warnings | Should -BeNullOrEmpty
        foreach ($ext in @('.html', '.json', '.findings.csv', '.events.csv', '.md', '.pdf', '.zip')) {
            @($script:Set.Files | Where-Object { $_ -like "*$ext" }).Count | Should -Be 1 -Because "the $ext output must exist"
        }
        $entries = [string[]]@(Get-ChildItem -LiteralPath $script:Extract -File | ForEach-Object Name)
        [System.Array]::Sort($entries, [System.StringComparer]::Ordinal)
        $entries | Should -Be @('README.txt', 'data.json', 'events.csv', 'findings.csv', 'omnidiag-log.jsonl', 'report.html', 'report.pdf')
    }

    It 'leaves zero occurrences of <_> in every file and file name' -ForEach @(
        'ACME-WS-042', 'corp.contoso.com', 'contoso', 'jdoe', 'msmith',
        'S-1-5-21-1004336348', '1004336348-1177238915',
        '10.20.30.40', '192.168.77.12',
        'fe80::1c2d', '1c2d:3e4f:5a6b:7c8d', '2001:db8', '2001:0db8', 'ff00:42:8329', 'ff00:0042:8329',
        '00-15-5D-AA-BB-CC', '00:15:5D:AA:BB:CC', '00-15-5D-AA-BB-DD', '00:15:5d:aa:bb:dd'
    ) {
        $id = $_
        foreach ($f in $script:AllFiles) {
            $script:Text[$f].IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$id' must not appear in $(Split-Path $f -Leaf)"
            (Split-Path $f -Leaf).IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$id' must not appear in the file name"
        }
    }

    It 'names the files after the host pseudonym' {
        $hostPseudonym = Get-Pseudonym 'ACME-WS-042'
        $hostPseudonym | Should -Be 'HOST-1'
        $script:Set.BaseName | Should -BeLike 'OmniDiag-HOST-1-*'
        foreach ($f in $script:Set.Files) { Split-Path $f -Leaf | Should -BeLike 'OmniDiag-HOST-1-*' }
    }

    It 'uses the same pseudonyms in JSON, HTML, CSV, Markdown, PDF, and the ZIP' {
        $ip = Get-Pseudonym '10.20.30.40'
        $hostP = Get-Pseudonym 'ACME-WS-042'
        $ip | Should -Match '^IP-\d+$'
        $expectedTitle = "Gateway $ip unreachable from $hostP"

        $doc = Get-OutputText '.json' | ConvertFrom-Json
        $finding = @($doc.modules.findings | Where-Object { $_.id -eq 'network-gateway' })[0]
        $finding.title | Should -BeExactly $expectedTitle
        $finding.evidence.data.Peer | Should -BeExactly $ip

        (Get-OutputText '.html') | Should -Match ([regex]::Escape($expectedTitle))
        (Get-OutputText '.md') | Should -Match ([regex]::Escape($expectedTitle))
        (Get-OutputText '.pdf') | Should -Match ([regex]::Escape($expectedTitle))
        $csvRow = @(Import-Csv -LiteralPath @($script:Set.Files | Where-Object { $_ -like '*.findings.csv' })[0] | Where-Object { $_.Module -eq 'Network' -and $_.Severity -eq 'Critical' })[0]
        $csvRow.Title | Should -BeExactly $expectedTitle
        $script:ZipText['data.json'] | Should -Match ([regex]::Escape($expectedTitle))
        $script:ZipText['omnidiag-log.jsonl'] | Should -Match ("Gateway $ip / ")
    }

    It 'maps both MAC notations and both IPv6 notations to one pseudonym each' {
        Get-Pseudonym '00-15-5D-AA-BB-CC' | Should -Match '^MAC-\d+$'
        @($script:Map.entries | Where-Object { $_.category -eq 'Mac' }).Count | Should -Be 2
        @($script:Map.entries | Where-Object { $_.category -eq 'IPv6' }).Count | Should -Be 2
        $json = Get-OutputText '.json'
        $json | Should -Match ([regex]::Escape((Get-Pseudonym '2001:db8::ff00:42:8329')))
    }

    It 'keeps the structure of profile paths' {
        $other = Get-Pseudonym 'msmith'
        (Get-OutputText '.html') | Should -Match ([regex]::Escape("C:\Users\$other\Downloads"))
        $csv = @(Import-Csv -LiteralPath @($script:Set.Files | Where-Object { $_ -like '*.events.csv' })[0])
        $csv[0].Recommendation | Should -BeExactly ('Check C:\Users\{0}\AppData for cached credentials.' -f (Get-Pseudonym 'jdoe'))
    }

    It 'marks the JSON report options.redacted = true and redacts the options' {
        $doc = Get-OutputText '.json' | ConvertFrom-Json
        $doc.options.redacted | Should -BeTrue
        $doc.schemaVersion | Should -Be (Get-OmniReportSchemaVersion)
        $doc.host.computerName | Should -Be 'HOST-1'
        $doc.options.output | Should -BeExactly ('C:\Users\{0}\Reports' -f (Get-Pseudonym 'jdoe'))
        (Import-OmniSession -Path @($script:Set.Files | Where-Object { $_ -like '*.json' })[0]).Redacted | Should -BeTrue
    }

    It 'writes uncompressed PDF content streams (so the scan above sees the text)' {
        $pdf = Get-OutputText '.pdf'
        $pdf | Should -Not -Match 'FlateDecode'
        $pdf | Should -Match 'Computer  : HOST-1'
    }

    It 'redacts the README and the run log in the package' {
        $readme = $script:ZipText['README.txt']
        $readme | Should -Match 'Computer : HOST-1'
        $readme | Should -Match 'REDACTED'
        $log = $script:ZipText['omnidiag-log.jsonl']
        @($log -split "`n" | Where-Object { $_ }).Count | Should -Be 3
        $log | Should -Match ([regex]::Escape(('C:\\Users\\{0}\\Downloads' -f (Get-Pseudonym 'jdoe'))))
    }

    It 'writes the mapping file locally with a warning, outside the shareable files' {
        Test-Path -LiteralPath $script:MapPath | Should -BeTrue
        $script:Set.RedactionMapPath | Should -Be $script:MapPath
        $script:Set.Files | Should -Not -Contain $script:MapPath
        @($script:MapWarnings | Where-Object { "$_" -like '*UN-REDACTS*' }).Count | Should -Be 1
        $script:Map.kind | Should -Be 'omnidiag-redaction-map'
        (Get-Pseudonym 'ACME-WS-042') | Should -Be 'HOST-1'
        (Get-Pseudonym 'msmith') | Should -Match '^USER-\d+$'
    }

    It 'never modifies the session' {
        ConvertTo-OmniJsonText -InputObject $script:Session | Should -BeExactly $script:SessionBefore
        $script:Session.Host.ComputerName | Should -Be 'ACME-WS-042'
        $script:Session.PSObject.Properties['Redacted'] | Should -BeNullOrEmpty
    }
}

Describe 'Redaction entry points' {
    It 'the unredacted fixture really contains the identifiers in every format (control)' {
        $set = Export-OmniReport -Session $script:Session -OutputDirectory (Join-Path $TestDrive 'plain') -Format Html, Json, Csv, Md, Pdf
        $set.Redacted | Should -BeFalse
        foreach ($f in $set.Files) {
            (Read-ReportText $f).IndexOf('ACME-WS-042', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeGreaterOrEqual 0 -Because (Split-Path $f -Leaf)
        }
        (Get-Content -LiteralPath @($set.Files | Where-Object { $_ -like '*.json' })[0] -Raw | ConvertFrom-Json).options.PSObject.Properties['redacted'] | Should -BeNullOrEmpty
    }

    It 'redacts a caller-supplied base name' {
        $set = Export-OmniReport -Session $script:Session -OutputDirectory (Join-Path $TestDrive 'named') -Format Json -BaseName 'report-ACME-WS-042-jdoe' -Redact
        $set.BaseName | Should -Be 'report-HOST-1-USER-1'
        Split-Path @($set.Files)[0] -Leaf | Should -Be 'report-HOST-1-USER-1.json'
    }

    It 'requires -Redact for -RedactionMapPath' {
        { Export-OmniReport -Session $script:Session -OutputDirectory (Join-Path $TestDrive 'x') -Format Json -RedactionMapPath (Join-Path $TestDrive 'm.json') } | Should -Throw '*requires -Redact*'
    }

    It 'Export-OmniReportPackage -Redact redacts the package and its file name when called directly' {
        $zip = Export-OmniReportPackage -Session $script:Session -Path (Join-Path (Join-Path $TestDrive 'direct') 'ACME-WS-042.zip') -Redact
        Split-Path $zip -Leaf | Should -Be 'HOST-1.zip'
        $dest = Join-Path $TestDrive 'direct-x'
        Expand-Archive -LiteralPath $zip -DestinationPath $dest
        foreach ($f in Get-ChildItem -LiteralPath $dest -File) {
            $text = Read-ReportText $f.FullName
            foreach ($id in $script:Planted) {
                $text.IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$id' must not appear in $($f.Name)"
            }
        }
    }
}
