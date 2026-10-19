#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Phase 4 security review - content and import (docs/SECURITY-REVIEW.md, section
    "Content and import"). One Describe per review item:

      1. HTML / Markdown / PDF / JSON encoding: XSS-style payloads planted in every
         session field never survive raw in a report.
      2. CSV: formula injection is neutralized in every column; quoting round-trips.
      3. Redaction: a seeded, property-based test embeds random identifiers in varied
         surrounding text (punctuation, paths, JSON escapes, URL encoding, mixed case)
         across all fields, exports every format with -Redact, and requires zero
         originals and consistent pseudonyms. Plus regressions for the leaks it found.
      4. Session import: a seeded fuzzer (200 cases) and targeted cases - every import
         either returns a well-formed session or throws System.IO.InvalidDataException
         (error id OmniDiag.SessionImportInvalid); nothing is ever evaluated.
      5. Ollama: the prompt is redacted; model output is stripped of terminal control
         sequences before it is shown.

    Everything is deterministic (fixed seeds) and OS-independent (Windows PowerShell
    5.1, PowerShell 7 on Windows and Ubuntu). No network: Ollama uses a transport seam.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    . (Join-Path $script:Root 'Tests/golden/ReportFixture.ps1')
    $script:GoldenPath = Join-Path $script:Root 'Tests/golden/report-v1.fixture.json'
    $script:GoldenJson = [System.IO.File]::ReadAllText($script:GoldenPath)
    $script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $script:BS = [string][char]92   # backslash, for building JSON-escape text

    function Read-ReportText([string] $Path) {
        if ($Path -like '*.pdf') {
            # Latin-1 maps bytes one-to-one; undo the PDF literal-string escapes.
            $raw = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($Path))
            return $raw.Replace('\\', [string][char]1).Replace('\(', '(').Replace('\)', ')').Replace([string][char]1, '\')
        }
        return [System.IO.File]::ReadAllText($Path)
    }

    function Write-TestJson([string] $Path, [string] $Json) {
        [System.IO.File]::WriteAllText($Path, $Json, $script:Utf8NoBom)
        return $Path
    }

    # The import error contract (docs/SECURITY-REVIEW.md): exactly one exception type.
    function Get-ImportOutcome([string] $Path) {
        $out = [pscustomobject]@{ Session = $null; Error = $null; Ms = 0 }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try { $out.Session = Import-OmniDiagSession -Path $Path } catch { $out.Error = $_ }
        $sw.Stop()
        $out.Ms = $sw.ElapsedMilliseconds
        return $out
    }

    function Test-ImportRejected($Outcome) {
        if ($null -eq $Outcome.Error) { return $false }
        return ($Outcome.Error.Exception -is [System.IO.InvalidDataException] -and
            [string]$Outcome.Error.FullyQualifiedErrorId -like '*OmniDiag.SessionImportInvalid*' -and
            -not [string]::IsNullOrWhiteSpace($Outcome.Error.Exception.Message))
    }

    # $null when the imported session is well-formed, else the reason.
    function Get-SessionProblem($Session) {
        if ($null -eq $Session) { return 'no session returned' }
        if (@($Session).Count -ne 1) { return 'more than one object returned' }
        if ($Session -isnot [System.Management.Automation.PSCustomObject]) { return 'not an object' }
        if (-not $Session.PSObject.Properties['Results']) { return 'no Results' }
        if (-not $Session.PSObject.Properties['SourcePath']) { return 'no SourcePath' }
        foreach ($r in @($Session.Results)) {
            if ($r -isnot [System.Management.Automation.PSCustomObject]) { return 'a result is not an object' }
            if ($r.Metrics -isnot [System.Collections.IDictionary]) { return 'Metrics is not a dictionary' }
            foreach ($f in @($r.Findings)) {
                if ($f -isnot [System.Management.Automation.PSCustomObject]) { return 'a finding is not an object' }
                foreach ($n in @('Id', 'Title', 'Severity', 'Component', 'Detail', 'Recommendation')) {
                    $p = $f.PSObject.Properties[$n]
                    if ($p -and $p.Value -is [array]) { return "finding $n is an array" }
                }
            }
        }
        try { $null = ConvertTo-OmniReportV1 -Session $Session | ConvertTo-OmniJsonText } catch { return "v1 projection failed: $($_.Exception.Message)" }
        return $null
    }
}

# ---------------------------------------------------------------------------
# 1. HTML / Markdown / PDF / JSON encoding
# ---------------------------------------------------------------------------

Describe 'Report encoding: XSS payloads in every field' {
    BeforeAll {
        $ls = [string][char]0x2028
        $ps = [string][char]0x2029
        # The PDF payload goes first so it survives the PDF's one-line truncation.
        $script:PdfMarker = 'PWNEDPDF'
        $script:Xss = @(
            "q) Tj $($script:PdfMarker) ET BT (",
            '<script>alert(1)</script>',
            '"><img src=x onerror=alert(2)>',
            "'><svg/onload=alert(3)>",
            'javascript:alert(4)',
            '</script><script>alert(5)</script>',
            '{{constructor.constructor(''alert(6)'')()}}',
            ('a' + $ls + 'b' + $ps + 'c'),
            '<a href="javascript:alert(7)">x</a>',
            '<!-- --><![CDATA[ ]]>',
            ("x`n`n<b>block</b>`n# Heading`n" + '```js' + "`n| a | b |`n[link](javascript:alert(8)) ![i](http://e/x.png) <http://e>"),
            ('back' + $script:BS + 'slash' + $script:BS + ')')
        )
        $script:P = $script:Xss -join ' '

        function New-XssSession {
            $p = $script:P
            $t0 = [datetime]::new(2026, 6, 1, 8, 0, 0, [System.DateTimeKind]::Utc)
            $sys = New-OmniResult -ModuleName "Sys $p" -Category 'System'
            Add-OmniFinding -Result $sys -Finding (New-OmniFinding -Id "id1-$p" -Title "T1 $p" -Severity 'Pass' -Component "C1 $p" -Detail "D1 $p")
            Set-OmniResultMetric -Result $sys -Name "Key $p" -Value "Val $p"
            Set-OmniResultMetric -Result $sys -Name 'OS' -Value "OS $p"
            $null = Complete-OmniResult -Result $sys

            $net = New-OmniResult -ModuleName "Net $p" -Category "Cat $p"
            Add-OmniFinding -Result $net -Finding (New-OmniFinding -Id "id2-$p" -Title "T2 $p" -Severity 'Critical' -Component "C2 $p" -Detail "D2 $p" `
                -LikelyCause "L2 $p" -Confidence 50 -Recommendation "R2 $p" -Data ([ordered]@{ "k $p" = "v $p"; Nested = @("n $p") }))
            Add-OmniFinding -Result $net -Finding (New-OmniFinding -Title "T3 $p" -Severity 'Warning' -Component "C3 $p" -Recommendation "R3 $p")
            $null = Complete-OmniResult -Result $net
            $net.Error = "E $p"
            Add-Member -InputObject $net -MemberType NoteProperty -Name ModuleId -Value "mid $p" -Force
            Add-Member -InputObject $net -MemberType NoteProperty -Name Group -Value "grp $p" -Force

            $evt = New-OmniResult -ModuleName "Evt $p" -Category 'Event Logs'
            Add-OmniFinding -Result $evt -Finding (New-OmniFinding -Title "T4 $p" -Severity 'Error' -Component "C4 $p" -Recommendation "R4 $p")
            Set-OmniResultMetric -Result $evt -Name 'TotalEvents' -Value "TE $p"
            Set-OmniResultMetric -Result $evt -Name 'TopGroups' -Value @([pscustomobject]@{
                    Severity = "S $p"; Category = "GC $p"; ProviderName = "P $p"; Id = "I $p"; Title = "GT $p"; Count = "N $p"
                    FirstSeen = $t0; LastSeen = "LS $p"; Channel = "CH $p"; SampleMessage = "M $p"; Recommendation = "GR $p"
                })
            Set-OmniResultMetric -Result $evt -Name 'Timeline' -Value @(
                [pscustomobject]@{ Time = $t0; Title = "TL $p"; Category = "TC $p" },
                [pscustomobject]@{ Time = "TT $p"; Title = "TL2 $p"; Category = "TC2 $p" }
            )
            $null = Complete-OmniResult -Result $evt

            $results = @($sys, $net, $evt)
            return [pscustomobject]@{
                PSTypeName = 'OmniDiag.Session'
                StartTime  = $t0
                EndTime    = $t0.AddSeconds(3)
                DurationMs = 3000
                Cancelled  = $false
                TimeRange  = [pscustomobject]@{ Start = $t0.AddDays(-1); End = $t0; Label = "Range $p"; Preset = "Pre $p" }
                Host       = [pscustomobject]@{ ComputerName = "PC $p"; UserName = "U $p"; PSVersion = "PSV $p" }
                IsAdmin    = $false
                Results    = $results
                Summary    = ($results | Get-OmniHealthScore)
                ScanPlan   = [pscustomobject]@{ Type = 'Workflow'; Name = "Plan $p"; Description = "PD $p" }
            }
        }

        # Every string in the golden v1 report (and every metric / data key) replaced
        # with the payload: the shape of a crafted report file a technician might open.
        function Set-PayloadEverywhere($Node, [int] $Depth = 0) {
            if ($Depth -gt 20 -or $null -eq $Node) { return }
            if ($Node -is [array]) {
                for ($i = 0; $i -lt $Node.Length; $i++) {
                    if ($Node[$i] -is [string]) { $Node[$i] = "$($script:P) #a$i" } else { Set-PayloadEverywhere $Node[$i] ($Depth + 1) }
                }
                return
            }
            if ($Node -isnot [System.Management.Automation.PSCustomObject]) { return }
            foreach ($prop in @($Node.PSObject.Properties)) {
                $v = $prop.Value
                if ($prop.Name -eq 'schemaVersion') { continue }
                if ($prop.Name -in @('metrics', 'data') -and $v -is [System.Management.Automation.PSCustomObject]) {
                    $renamed = [ordered]@{}
                    $k = 0
                    foreach ($inner in @($v.PSObject.Properties)) { $renamed["$($script:P) key$k"] = $inner.Value; $k++ }
                    $obj = [pscustomobject]$renamed
                    Set-PayloadEverywhere $obj ($Depth + 1)
                    $prop.Value = $obj
                    continue
                }
                if ($v -is [string] -or $v -is [datetime]) { $prop.Value = "$($script:P) #$($prop.Name)" }
                else { Set-PayloadEverywhere $v ($Depth + 1) }
            }
        }

        $script:XssDir = Join-Path $TestDrive 'xss'
        New-Item -ItemType Directory -Path $script:XssDir -Force | Out-Null

        # Session A: built with the factories (every free-text field carries the payload).
        $script:SessionA = New-XssSession
        # Session B: a crafted v1 report file, imported.
        $doc = $script:GoldenJson | ConvertFrom-Json
        Set-PayloadEverywhere $doc
        $craftedPath = Write-TestJson (Join-Path $script:XssDir 'crafted.json') ($doc | ConvertTo-Json -Depth 50)
        $script:SessionB = Import-OmniDiagSession -Path $craftedPath

        $script:Out = @{}
        foreach ($name in @('A', 'B')) {
            $s = if ($name -eq 'A') { $script:SessionA } else { $script:SessionB }
            $base = Join-Path $script:XssDir "report-$name"
            $brand = "Brand $($script:P)"
            $script:Out["$name.html"] = Read-ReportText (Export-OmniHtmlReport -Session $s -Path "$base.html" -BrandName $brand -BrandColor 'red;}</style><script>alert(9)</script>')
            $script:Out["$name.md"] = Read-ReportText (Export-OmniMarkdownReport -Session $s -Path "$base.md" -BrandName $brand)
            $script:Out["$name.pdf"] = Read-ReportText (Export-OmniPdfReport -Session $s -Path "$base.pdf" -BrandName $brand -BrandColor 'red) Tj')
            $script:Out["$name.json"] = Read-ReportText (Export-OmniJsonReport -Session $s -Path "$base.json")
            $script:Out["$name.pdfraw"] = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes("$base.pdf"))
        }

        # Tags and attributes outside the fixed report template.
        function Get-HtmlStructureProblem([string] $Html) {
            $allowedTags = @('html', 'head', 'meta', 'title', 'style', 'body', 'div', 'header', 'h1', 'h2', 'span', 'ul', 'li',
                'strong', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'p', 'footer')
            $allowedAttrs = @('lang', 'charset', 'class', 'style')
            $bad = [System.Collections.Generic.List[string]]::new()
            foreach ($m in [regex]::Matches($Html, '<\s*/?\s*([A-Za-z][A-Za-z0-9:-]*)([^>]*)>')) {
                $tag = $m.Groups[1].Value.ToLowerInvariant()
                $attrs = $m.Groups[2].Value
                if ($tag -notin $allowedTags) { $bad.Add("tag <$tag>") }
                if ($attrs -match '(?i)\bon[a-z]+\s*=') { $bad.Add("event handler in <$tag>") }
                if ($attrs -match '(?i)javascript:|vbscript:|data:text') { $bad.Add("script URL in <$tag>") }
                foreach ($a in [regex]::Matches($attrs, '([A-Za-z-]+)\s*=')) {
                    if ($a.Groups[1].Value.ToLowerInvariant() -notin $allowedAttrs) { $bad.Add("attribute $($a.Groups[1].Value) in <$tag>") }
                }
            }
            return @($bad)
        }

        # PDF text outside literal strings (the content-stream operators).
        function Get-PdfOperatorText([string] $Raw) {
            $sb = [System.Text.StringBuilder]::new()
            $depth = 0
            $i = 0
            while ($i -lt $Raw.Length) {
                $ch = $Raw[$i]
                if ($depth -eq 0) {
                    if ($ch -eq '(') { $depth = 1 } else { [void]$sb.Append($ch) }
                } elseif ($ch -eq '\') {
                    $i++
                } elseif ($ch -eq '(') {
                    $depth++
                } elseif ($ch -eq ')') {
                    $depth--
                }
                $i++
            }
            return $sb.ToString()
        }
    }

    It 'HTML (<_>): only the template''s own tags and attributes exist' -ForEach @('A', 'B') {
        $html = $script:Out["$_.html"]
        Get-HtmlStructureProblem $html | Should -BeNullOrEmpty
        ([regex]::Matches($html, '(?i)<\s*script')).Count | Should -Be 0
        ([regex]::Matches($html, '(?i)<\s*(img|svg|a|b|iframe)\b')).Count | Should -Be 0
    }

    It 'HTML (<_>): payloads are present, encoded, in text' -ForEach @('A', 'B') {
        $html = $script:Out["$_.html"]
        $html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;') | Should -BeTrue
        $html.Contains('&quot;&gt;&lt;img src=x onerror=alert(2)&gt;') | Should -BeTrue
        $html.Contains('"><img') | Should -BeFalse
        $html.Contains("'><svg") | Should -BeFalse
        $html.Contains('</script><script>') | Should -BeFalse
    }

    It 'HTML (A): every planted field is rendered encoded (host, metrics, events, modules, errors, brand)' {
        $html = $script:Out['A.html']
        foreach ($label in @('PC', 'U', 'Range', 'Key', 'Val', 'T2', 'D2', 'L2', 'R2', 'C2', 'T3', 'T4', 'TE', 'P', 'GT', 'N', 'LS', 'TL', 'TT', 'TC', 'E', 'Net', 'Cat', 'C1', 'T1', 'Brand')) {
            $expected = [System.Net.WebUtility]::HtmlEncode("$label $($script:Xss[0]) $($script:Xss[1]) $($script:Xss[2])")
            $html.Contains($expected) | Should -BeTrue -Because "the '$label' field must be shown encoded"
        }
    }

    It 'HTML: the brand color reaches CSS only as a validated #RRGGBB value' {
        $script:Out['A.html'] | Should -Not -Match 'alert\(9\)'
        $set = Join-Path $script:XssDir 'brand-ok.html'
        Export-OmniHtmlReport -Session $script:SessionA -Path $set -BrandColor '#12ab34' | Out-Null
        (Read-ReportText $set) | Should -Match ':root\{--info:#12ab34\}'
    }

    It 'Markdown (<_>): no raw HTML, no injected blocks, links, or table columns' -ForEach @('A', 'B') {
        $md = $script:Out["$_.md"]
        # Ids are shown in code spans, where text is literal (no HTML, no links); the rest is escaped.
        # An escaped backtick (\`) in text is not a code-span delimiter.
        $text = [regex]::Replace($md, '(?<!\\)`[^`\n]*(?<!\\)`', '')
        $text.IndexOf('<') | Should -Be -1 -Because 'every < from the session is encoded outside code spans'
        foreach ($line in ($md -split "`n")) {
            $line | Should -Not -Match '^\s*(# Heading|```|<|\| a \| b \|)' -Because 'a finding must not start a Markdown block of its own'
            if ($line -like '- **Finding id:***') { ([regex]::Matches($line, '`')).Count | Should -Be 2 }
        }
        $text | Should -Not -Match '(?<!\\)\]\(' -Because 'link and image syntax is escaped'
        $md.Contains([string][char]0x2028) | Should -BeFalse
        $md.Contains([string][char]0x2029) | Should -BeFalse
        $inModules = $false
        foreach ($line in ($md -split "`n")) {
            if ($line -eq '## Modules') { $inModules = $true; continue }
            if ($inModules -and $line.StartsWith('## ')) { break }
            if ($inModules -and $line.StartsWith('| ') -and $line -notlike '| Module |*') {
                ([regex]::Matches($line, '(?<!\\)\|')).Count | Should -Be 6 -Because "row '$line' must keep five columns"
            }
        }
    }

    It 'PDF (<_>): payload text stays inside string literals; no injected operators' -ForEach @('A', 'B') {
        $raw = $script:Out["$_.pdfraw"]
        $raw.Contains($script:PdfMarker) | Should -BeTrue
        $ops = Get-PdfOperatorText $raw
        $ops.Contains($script:PdfMarker) | Should -BeFalse
        ([regex]::Matches($ops, '\bBT\b')).Count | Should -Be ([regex]::Matches($ops, '\bTj\b')).Count
        ([regex]::Matches($ops, '\bBT\b')).Count | Should -Be ([regex]::Matches($ops, '\bET\b')).Count
        $raw | Should -Not -Match 'red\) Tj'
    }

    It 'JSON (<_>): ASCII-only, valid, and round-trips the payload exactly' -ForEach @('A', 'B') {
        $json = $script:Out["$_.json"]
        $json -cmatch '^[\x00-\x7F]*$' | Should -BeTrue
        $json.Contains($script:BS + 'u2028') | Should -BeTrue
        $doc = $json | ConvertFrom-Json
        if ($_ -eq 'A') {
            $finding = @($doc.modules.findings | Where-Object { $_.title -eq "T2 $($script:P)" })
            $finding.Count | Should -Be 1
            $finding[0].evidence.detail | Should -BeExactly "D2 $($script:P)"
        } else {
            $doc.host.computerName | Should -BeExactly "$($script:P) #computerName"
        }
    }
}

# ---------------------------------------------------------------------------
# 2. CSV encoding
# ---------------------------------------------------------------------------

Describe 'CSV encoding: formula injection and quoting in every column' {
    BeforeAll {
        $fw = [string][char]0xFF1D   # full-width '='
        $script:CsvPayloads = @(
            '=1+1', '+1+1', '-1+1', '@SUM(A1)', "`t=1", "`r=1", "`n=1", ' =1+1', '   +cmd|'' /C calc''!A0', '"=1+1', "'=1+1", ' "@x',
            '=HYPERLINK("http://x","y")', 'a,b,c', 'say "hi", ok', "multi`nline", 'plain text', '', ($fw + '1+1'), '-', 'a=1', '1-2'
        )
        function Get-CsvExpected([string] $Value) {
            if ($Value -match '^[\t\r\n]' -or $Value -match '^[\s"'']*[=+\-@]' -or $Value -match ('^\s*' + [char]0xFF1D)) { return "'" + $Value }
            return $Value
        }
        $n = $script:CsvPayloads.Count
        $script:FindingColumns = @('Module', 'Category', 'Severity', 'Component', 'Title', 'Detail', 'LikelyCause', 'Confidence', 'Recommendation', 'Timestamp')
        $script:EventColumns = @('Severity', 'Category', 'Source', 'EventId', 'Title', 'Count', 'FirstSeen', 'LastSeen', 'Channel', 'Message', 'Recommendation')
        function Get-Payload([int] $Row, [int] $Column) { return $script:CsvPayloads[($Row + $Column) % $script:CsvPayloads.Count] }

        # Raw objects (not the factories) so every column - even Severity, Confidence,
        # and Timestamp - can carry text, as in a hand-edited saved session.
        $results = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $n; $i++) {
            $f = [pscustomobject]@{
                Id = "f$i"; Severity = (Get-Payload $i 2); SeverityRank = $i; Component = (Get-Payload $i 3); Title = (Get-Payload $i 4)
                Detail = (Get-Payload $i 5); LikelyCause = (Get-Payload $i 6); Confidence = (Get-Payload $i 7); Recommendation = (Get-Payload $i 8)
                Timestamp = (Get-Payload $i 9); Data = $null
            }
            $results.Add([pscustomobject]@{ ModuleName = (Get-Payload $i 0); Category = (Get-Payload $i 1); Status = 'Warning'; Findings = @($f); Metrics = [ordered]@{} })
        }
        $groups = @(for ($i = 0; $i -lt $n; $i++) {
                [pscustomobject]@{
                    Severity = (Get-Payload $i 0); Category = (Get-Payload $i 1); ProviderName = (Get-Payload $i 2); Id = (Get-Payload $i 3)
                    Title = (Get-Payload $i 4); Count = (Get-Payload $i 5); FirstSeen = (Get-Payload $i 6); LastSeen = (Get-Payload $i 7)
                    Channel = (Get-Payload $i 8); SampleMessage = (Get-Payload $i 9); Recommendation = (Get-Payload $i 10)
                }
            })
        $results.Add([pscustomobject]@{ ModuleName = 'Event Logs'; Category = 'Event Logs'; Status = 'Warning'; Findings = @(); Metrics = [ordered]@{ TopGroups = $groups } })
        $script:CsvSession = [pscustomobject]@{ Results = $results.ToArray() }

        $script:FindingsCsv = Export-OmniCsvReport -Session $script:CsvSession -Path (Join-Path $TestDrive 'findings.csv')
        $script:EventsCsv = Export-OmniEventCsvReport -Session $script:CsvSession -Path (Join-Path $TestDrive 'events.csv')
        $script:FindingRows = @(Import-Csv -LiteralPath $script:FindingsCsv)
        $script:EventRows = @(Import-Csv -LiteralPath $script:EventsCsv)
        $script:CsvN = $n
    }

    It 'writes one row per finding and per event group' {
        $script:FindingRows.Count | Should -Be $script:CsvN
        $script:EventRows.Count | Should -Be $script:CsvN
    }

    It 'findings.csv column <_>: every payload is neutralized and round-trips' -ForEach @('Module', 'Category', 'Severity', 'Component', 'Title', 'Detail', 'LikelyCause', 'Confidence', 'Recommendation', 'Timestamp') {
        $col = $_
        $j = [array]::IndexOf($script:FindingColumns, $col)
        for ($k = 0; $k -lt $script:CsvN; $k++) {
            # Rows are sorted by SeverityRank descending, so row k holds finding n-1-k.
            $i = $script:CsvN - 1 - $k
            $expected = (Get-CsvExpected (Get-Payload $i $j)).Replace("`r`n", "`n")
            $actual = ([string]$script:FindingRows[$k].$col).Replace("`r`n", "`n")
            $actual | Should -BeExactly $expected -Because "row $k column $col"
            $actual | Should -Not -Match '^[=+\-@\t\r\n]'
        }
    }

    It 'events.csv column <_>: every payload is neutralized and round-trips' -ForEach @('Severity', 'Category', 'Source', 'EventId', 'Title', 'Count', 'FirstSeen', 'LastSeen', 'Channel', 'Message', 'Recommendation') {
        $col = $_
        $j = [array]::IndexOf($script:EventColumns, $col)
        for ($i = 0; $i -lt $script:CsvN; $i++) {
            $expected = (Get-CsvExpected (Get-Payload $i $j)).Replace("`r`n", "`n")
            $actual = ([string]$script:EventRows[$i].$col).Replace("`r`n", "`n")
            $actual | Should -BeExactly $expected -Because "row $i column $col"
            $actual | Should -Not -Match '^[=+\-@\t\r\n]'
        }
    }

    It 'quotes every field, so commas, quotes, and line breaks cannot shift columns' {
        $text = [System.IO.File]::ReadAllText($script:FindingsCsv)
        $header = ($text -split "`r?`n")[0]
        $header | Should -BeExactly ('"' + ($script:FindingColumns -join '","') + '"')
        $text.Contains('"say ""hi"", ok"') | Should -BeTrue
    }

    It 'keeps numbers and dates as values, and renders objects as neutralized text' {
        $r = [pscustomobject]@{
            ModuleName = 'M'; Category = 'C'; Status = 'Warning'; Metrics = [ordered]@{}
            Findings = @([pscustomobject]@{ Id = 'x'; Severity = 'Warning'; SeverityRank = 2; Component = @('=cmd', 'b'); Title = -5
                    Detail = [pscustomobject]@{ a = 1 }; LikelyCause = ''; Confidence = 80; Recommendation = $null; Timestamp = [datetime]::new(2026, 6, 1) })
        }
        $path = Export-OmniCsvReport -Session ([pscustomobject]@{ Results = @($r) }) -Path (Join-Path $TestDrive 'types.csv')
        $row = @(Import-Csv -LiteralPath $path)[0]
        $row.Component | Should -BeExactly "'=cmd; b"
        $row.Title | Should -BeExactly '-5'
        $row.Confidence | Should -BeExactly '80'
        $row.Detail | Should -Not -Match '^[=+\-@]'
    }
}

# ---------------------------------------------------------------------------
# 3. Redaction correctness
# ---------------------------------------------------------------------------

Describe 'Redaction: property-based leak test across every format' {
    BeforeAll {
        $script:Rng = [System.Random]::new(4711)
        function Get-RandomText([string] $Alphabet, [int] $Length) {
            $sb = [System.Text.StringBuilder]::new()
            for ($i = 0; $i -lt $Length; $i++) { [void]$sb.Append($Alphabet[$script:Rng.Next($Alphabet.Length)]) }
            return $sb.ToString()
        }
        function Get-RandomCase([string] $Text) {
            $sb = [System.Text.StringBuilder]::new()
            foreach ($ch in $Text.ToCharArray()) {
                if ($script:Rng.Next(2) -eq 0) { [void]$sb.Append([char]::ToUpperInvariant($ch)) } else { [void]$sb.Append([char]::ToLowerInvariant($ch)) }
            }
            return $sb.ToString()
        }
        function Get-Shuffled([object[]] $Items) {
            $a = [object[]]$Items.Clone()
            for ($i = $a.Length - 1; $i -gt 0; $i--) { $j = $script:Rng.Next($i + 1); $t = $a[$i]; $a[$i] = $a[$j]; $a[$j] = $t }
            return , $a
        }

        $bs = $script:BS
        # Surrounding text: punctuation, paths, URLs, JSON escapes (as literal text), URL encoding.
        $script:Templates = @(
            'value {0} end', '({0})', '[{0}]', '"{0}"', "'{0}'", '{0},', '{0};', '<{0}>', 'x={0}&y=1', '{"k":"{0}"}',
            ('{' + $bs + '"k' + $bs + '":' + $bs + '"{0}' + $bs + '"}'), ($bs + 'n{0}' + $bs + 'n'), ($bs + 't{0}'), ($bs + 'r' + $bs + 'n{0}'),
            ($bs + 'u0022{0}' + $bs + 'u0022'), ($bs + 'u003c{0}' + $bs + 'u003e'), '%22{0}%22', '%20{0}%20', 'q=%2F{0}%2F', '%3D{0}%26',
            'C:\Temp\{0}\x.log', '\\{0}\share', 'smb://{0}/c$', 'https://{0}/path?x=1', "line1`n{0}", "tab`t{0}",
            '{0}.', '{0}!', '{0}?', '{0}:', 'mixed {0} text'
        )

        function New-RandomIdentity {
            $lower = 'abcdefghijklmnopqrstuvwxyz'
            $alnum = 'abcdefghijklmnopqrstuvwxyz0123456789'
            $hex = '0123456789abcdef'
            $id = [ordered]@{}
            $id.Host = 'ws' + (Get-RandomText $alnum 4) + '-' + $script:Rng.Next(100, 1000)
            $id.User = 'u' + (Get-RandomText $lower 6) + $script:Rng.Next(0, 10)
            $id.NetBios = 'NB' + (Get-RandomText $lower 5).ToUpperInvariant()
            $id.DnsSuffix = 'ex' + (Get-RandomText $lower 4) + '.com'
            $id.Dns = 'corp' + (Get-RandomText $lower 4) + '.' + $id.DnsSuffix
            $firsts = @(10, 23, 45, 77, 100, 172, 192, 203)
            $id.IPv4 = @(1..4 | ForEach-Object { '{0}.{1}.{2}.{3}' -f $firsts[$script:Rng.Next($firsts.Count)], $script:Rng.Next(0, 256), $script:Rng.Next(0, 256), $script:Rng.Next(1, 255) } | Select-Object -Unique)
            # First groups always have four hex digits (see the %XX handling in Redaction.psm1).
            $g = { Get-RandomText '123456789abcdef' 1; Get-RandomText $hex 3 }
            $full = '2001:db8:' + ((1..6 | ForEach-Object { -join (& $g) }) -join ':')
            $comp = 'fd' + (Get-RandomText $hex 2) + ':' + (-join (& $g)) + '::' + (-join (& $g))
            $id.IPv6 = @($full, $comp)
            $id.Mac = @(1..2 | ForEach-Object { '02' + ((1..5 | ForEach-Object { '-' + (Get-RandomText $hex 2) }) -join '') })
            $id.Sid = @(1..2 | ForEach-Object { 'S-1-5-21-{0}-{1}-{2}-{3}' -f $script:Rng.Next(100000000, 2000000000), $script:Rng.Next(100000000, 2000000000), $script:Rng.Next(100000000, 2000000000), $script:Rng.Next(1000, 100000) })
            return [pscustomobject]$id
        }

        function Get-Fragments($Id) {
            $values = [System.Collections.Generic.List[string]]::new()
            foreach ($v in @($Id.Host, "$($Id.Host).$($Id.Dns)", $Id.User, "$($Id.NetBios)\$($Id.User)", $Id.NetBios, $Id.Dns,
                    "$($Id.User)@$($Id.Dns)", "$($Id.User)%40$($Id.Dns)", "mailto:$($Id.User)@$($Id.Dns)")) { $values.Add($v) }
            foreach ($v in @($Id.IPv4) + @($Id.IPv6) + @($Id.Sid)) { $values.Add($v) }
            foreach ($m in @($Id.Mac)) { $values.Add($m); $values.Add($m.Replace('-', ':')) }
            $out = [System.Collections.Generic.List[string]]::new()
            foreach ($v in $values) {
                foreach ($t in $script:Templates) { $out.Add($t.Replace('{0}', (Get-RandomCase $v))) }
            }
            # Profile paths, also JSON-escaped and Unix-style.
            $out.Add("C:\Users\$($Id.User)\AppData\Local\x.tmp")
            $out.Add("C:$bs$($bs)Users$bs$bs$($Id.User)$bs$($bs)Desktop")
            $out.Add("/home/$($Id.User)/.cache")
            return , (Get-Shuffled $out.ToArray())
        }

        function New-RandomSession($Id, [string[]] $Slot) {
            $t0 = [datetime]::new(2026, 6, 1, 8, 0, 0, [System.DateTimeKind]::Utc)
            $next = { $script:SlotIndex++; $Slot[$script:SlotIndex % $Slot.Count] }
            $script:SlotIndex = 0
            $sys = New-OmniResult -ModuleName 'System Information' -Category 'System'
            Add-OmniFinding -Result $sys -Finding (New-OmniFinding -Id (& $next) -Title (& $next) -Severity 'Warning' -Component (& $next) -Detail (& $next) -LikelyCause (& $next) -Recommendation (& $next) `
                    -Data ([ordered]@{ (& $next) = (& $next); Nested = [pscustomobject]@{ Deep = @((& $next), (& $next)); (& $next) = 1 } }))
            Set-OmniResultMetric -Result $sys -Name 'ComputerName' -Value $Id.Host
            Set-OmniResultMetric -Result $sys -Name (& $next) -Value (& $next)
            Set-OmniResultMetric -Result $sys -Name 'Adapters' -Value @([pscustomobject]@{ Name = (& $next); Address = (& $next) })
            $null = Complete-OmniResult -Result $sys
            $net = New-OmniResult -ModuleName 'Network' -Category 'Network'
            Add-OmniFinding -Result $net -Finding (New-OmniFinding -Title (& $next) -Severity 'Critical' -Component (& $next) -Detail (& $next) -Recommendation (& $next))
            Add-OmniFinding -Result $net -Finding (New-OmniFinding -Title (& $next) -Severity 'Pass' -Component (& $next))
            $null = Complete-OmniResult -Result $net
            $net.Error = (& $next)
            $evt = New-OmniResult -ModuleName 'Event Logs' -Category 'Event Logs'
            Add-OmniFinding -Result $evt -Finding (New-OmniFinding -Title (& $next) -Severity 'Error' -Component (& $next) -Detail (& $next) -Recommendation (& $next))
            Set-OmniResultMetric -Result $evt -Name 'TotalEvents' -Value 3
            Set-OmniResultMetric -Result $evt -Name 'TopGroups' -Value @([pscustomobject]@{
                    Severity = 'Error'; Category = 'Security'; ProviderName = (& $next); Id = 4625; Title = (& $next); Count = 3
                    FirstSeen = $t0; LastSeen = $t0; Channel = 'Security'; SampleMessage = (& $next); Recommendation = (& $next)
                })
            Set-OmniResultMetric -Result $evt -Name 'Timeline' -Value @([pscustomobject]@{ Time = $t0; Title = (& $next); Category = 'System' })
            $null = Complete-OmniResult -Result $evt
            $results = @($sys, $net, $evt)
            # Every remaining fragment goes into one more finding, so all of them are in the session.
            $rest = New-OmniResult -ModuleName 'Extras' -Category 'Custom'
            $remaining = @(for ($k = $script:SlotIndex + 1; $k -lt $Slot.Count; $k++) { $Slot[$k] })
            for ($k = 0; $k -lt $remaining.Count; $k += 8) {
                $chunk = @($remaining[$k..([math]::Min($k + 7, $remaining.Count - 1))])
                Add-OmniFinding -Result $rest -Finding (New-OmniFinding -Title ($chunk -join ' ') -Severity 'Information' -Component 'Extras' -Detail ($chunk -join ' | '))
            }
            $null = Complete-OmniResult -Result $rest
            $results += $rest
            return [pscustomobject]@{
                PSTypeName = 'OmniDiag.Session'
                StartTime  = $t0
                EndTime    = $t0.AddSeconds(5)
                DurationMs = 5000
                Cancelled  = $false
                TimeRange  = [pscustomobject]@{ Start = $t0.AddDays(-7); End = $t0; Label = (& $next); Preset = 'Last7Days' }
                Host       = [pscustomobject]@{ ComputerName = $Id.Host; UserName = "$($Id.NetBios)\$($Id.User)"; Domain = $Id.NetBios; DnsDomain = $Id.Dns; PSVersion = '5.1.19041.1' }
                IsAdmin    = $false
                Results    = $results
                Summary    = ($results | Get-OmniHealthScore)
                ScanPlan   = [pscustomobject]@{ Type = 'Workflow'; Name = (& $next); Description = (& $next) }
            }
        }

        $script:Cases = [System.Collections.Generic.List[object]]::new()
        $iterations = 4
        for ($it = 0; $it -lt $iterations; $it++) {
            $id = New-RandomIdentity
            $fragments = Get-Fragments $id
            $session = New-RandomSession $id $fragments
            $ctx = New-OmniRedactionContext -Session $session -ExcludeEnvironment
            $out = Join-Path $TestDrive "redact-$it"
            $set = Export-OmniReport -Session $session -OutputDirectory $out -Format Html, Json, Csv, Md, Pdf, Zip -Redact -RedactionContext $ctx `
                -BaseName "case-$it-$($id.Host)" -Option @{ note = $fragments[0]; path = "C:\Users\$($id.User)\Reports" } -WarningAction SilentlyContinue
            $extract = Join-Path $out 'zip'
            Expand-Archive -LiteralPath @($set.Files | Where-Object { $_ -like '*.zip' })[0] -DestinationPath $extract
            $files = @(@($set.Files) + @(Get-ChildItem -LiteralPath $extract -File -Recurse | ForEach-Object { $_.FullName }))
            $text = @{}
            foreach ($f in $files) { $text[$f] = Read-ReportText $f }

            $originals = [System.Collections.Generic.List[string]]::new()
            foreach ($v in @($id.Host, $id.User, $id.NetBios, $id.Dns, $id.DnsSuffix) + @($id.IPv4) + @($id.IPv6) + @($id.Sid)) { $originals.Add($v) }
            foreach ($v in @($id.IPv6)) { $originals.Add([System.Net.IPAddress]::Parse($v).ToString()) }
            foreach ($m in @($id.Mac)) { $originals.Add($m); $originals.Add($m.Replace('-', ':')) }
            foreach ($sid in @($id.Sid)) { foreach ($part in @($sid.Split('-') | Select-Object -Skip 4 -First 3)) { $originals.Add($part) } }
            $script:Cases.Add([pscustomobject]@{ Iteration = $it; Id = $id; Context = $ctx; Set = $set; Files = $files; Text = $text; Originals = @($originals | Select-Object -Unique); FragmentCount = $fragments.Count })
        }
        $script:PseudonymToken = '\b(?:HOST|USER|DOMAIN|PATH|SID|IPV6|IP|MAC|TERM)-(?:\d+|[0-9A-F]{8})\b'
    }

    It 'embedded many identifiers per iteration' {
        $script:Cases.Count | Should -Be 4
        foreach ($c in $script:Cases) { $c.FragmentCount | Should -BeGreaterThan 400 }
    }

    It 'leaves zero originals in any file or file name (iteration <_>)' -ForEach @(0, 1, 2, 3) {
        $c = $script:Cases[$_]
        $c.Set.Redacted | Should -BeTrue
        foreach ($f in $c.Files) {
            foreach ($o in $c.Originals) {
                $c.Text[$f].IndexOf($o, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$o' must not appear in $(Split-Path $f -Leaf) (iteration $($c.Iteration))"
                (Split-Path $f -Leaf).IndexOf($o, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$o' must not appear in the file name"
            }
        }
    }

    It 'maps every value to exactly one pseudonym, whatever its spelling (iteration <_>)' -ForEach @(0, 1, 2, 3) {
        $c = $script:Cases[$_]
        # Get-OmniRedactionMap returns its array as one object: assign it, do not wrap it in @().
        $map = Get-OmniRedactionMap -Context $c.Context
        $of = { param($cat) @($map | Where-Object { $_.Category -eq $cat }) }

        $ipv4 = & $of 'IPv4'
        [string[]]@($ipv4.Original | Sort-Object) | Should -Be ([string[]]@($c.Id.IPv4 | Sort-Object))
        $ipv6 = & $of 'IPv6'
        [string[]]@($ipv6.Original | Sort-Object) | Should -Be ([string[]]@($c.Id.IPv6 | ForEach-Object { [System.Net.IPAddress]::Parse($_).ToString().ToLowerInvariant() } | Sort-Object))
        $mac = & $of 'Mac'
        [string[]]@($mac.Original | Sort-Object) | Should -Be ([string[]]@($c.Id.Mac | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object))
        $sid = & $of 'Sid'
        [string[]]@($sid.Original | Sort-Object) | Should -Be ([string[]]@($c.Id.Sid | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object))
        @((& $of 'Host') | Where-Object { $_.Original -eq $c.Id.Host }).Count | Should -Be 1
        @((& $of 'User') | Where-Object { $_.Original -eq $c.Id.User }).Count | Should -Be 1
        @((& $of 'Domain') | Where-Object { $_.Original -eq $c.Id.Dns }).Count | Should -Be 1
        foreach ($cat in @('Host', 'User', 'Domain', 'Sid', 'IPv4', 'IPv6', 'Mac')) {
            $p = @((& $of $cat) | ForEach-Object { $_.Pseudonym })
            @($p | Select-Object -Unique).Count | Should -Be $p.Count -Because "$cat pseudonyms must be distinct"
        }
    }

    It 'uses only the context''s pseudonyms in every format, and each value''s pseudonym appears (iteration <_>)' -ForEach @(0, 1, 2, 3) {
        $c = $script:Cases[$_]
        # Get-OmniRedactionMap returns its array as one object: assign it, do not wrap it in @().
        $map = Get-OmniRedactionMap -Context $c.Context
        $known = @{}
        foreach ($e in $map) { foreach ($m in [regex]::Matches([string]$e.Pseudonym, $script:PseudonymToken)) { $known[$m.Value] = $true } }
        foreach ($f in $c.Files) {
            foreach ($m in [regex]::Matches($c.Text[$f], $script:PseudonymToken)) {
                $known.ContainsKey($m.Value) | Should -BeTrue -Because "$($m.Value) in $(Split-Path $f -Leaf) must come from the redaction map"
            }
        }
        $json = $c.Text[@($c.Set.Files | Where-Object { $_ -like '*.json' })[0]]
        foreach ($e in @($map | Where-Object { $_.Category -in @('IPv4', 'IPv6', 'Mac', 'Sid') })) {
            $json.Contains([string]$e.Pseudonym) | Should -BeTrue -Because "$($e.Category) $($e.Original) must be rendered as its pseudonym"
        }
        $c.Set.BaseName | Should -BeLike 'case-*-HOST-1'
    }
}

Describe 'Redaction regressions: identifiers glued to escape sequences' {
    BeforeAll {
        $script:Ctx = New-OmniRedactionContext -ExcludeEnvironment -Session ([pscustomobject]@{
                Host = [pscustomobject]@{ ComputerName = 'ACME-WS-042'; UserName = 'CONTOSO\jdoe'; DnsDomain = 'corp.contoso.com' }
            })
        function Invoke-Redact([string] $Text) { ConvertTo-OmniRedacted -InputObject $Text -Context $script:Ctx }
        $b = $script:BS
        $script:Glued = @(
            @{ Text = 'path%5Cjdoe%5Cfile'; Gone = 'jdoe' },
            @{ Text = 'mail jdoe%40corp.contoso.com'; Gone = 'contoso' },
            @{ Text = ('line' + $b + 'njdoe logged on'); Gone = 'jdoe' },
            @{ Text = ('quoted ' + $b + 'u0022ACME-WS-042' + $b + 'u0022'); Gone = 'ACME-WS-042' },
            @{ Text = ('tab' + $b + 'tCONTOSO'); Gone = 'CONTOSO' },
            @{ Text = 'peer%2010.20.30.40%20'; Gone = '10.20.30.40' },
            @{ Text = ('peer' + $b + 'n10.20.30.40'); Gone = '10.20.30.40' },
            @{ Text = ('peer' + $b + 'u002210.20.30.40'); Gone = '10.20.30.40' },
            @{ Text = 'link%20fe80::1c2d:3e4f:5a6b:7c8d%20'; Gone = '1c2d:3e4f' },
            @{ Text = 'link%3A2001:db8::ff00:42:8329'; Gone = 'ff00:42:8329' },
            @{ Text = ('link' + $b + 'n2001:db8::5'); Gone = '2001:db8' },
            @{ Text = 'sid%22S-1-5-21-1004336348-1177238915-682003330-1001%22'; Gone = '1004336348' },
            @{ Text = ('sid' + $b + 'tS-1-5-21-1004336348-1177238915-682003330-1001'); Gone = '1004336348' },
            @{ Text = 'mac%20aa:bb:cc:dd:ee:ff%20'; Gone = 'aa:bb:cc' },
            @{ Text = ('mac' + $b + 'r00-15-5D-AA-BB-CC'); Gone = '00-15-5D' }
        )
    }

    It 'redacts <Text>' -ForEach @(
        @{ Text = 'path%5Cjdoe%5Cfile' }, @{ Text = 'mail jdoe%40corp.contoso.com' }, @{ Text = 'peer%2010.20.30.40%20' },
        @{ Text = 'link%20fe80::1c2d:3e4f:5a6b:7c8d%20' }, @{ Text = 'link%3A2001:db8::ff00:42:8329' },
        @{ Text = 'sid%22S-1-5-21-1004336348-1177238915-682003330-1001%22' }, @{ Text = 'mac%20aa:bb:cc:dd:ee:ff%20' }
    ) {
        $case = @($script:Glued | Where-Object { $_.Text -eq $Text })[0]
        $out = Invoke-Redact $Text
        $out.IndexOf($case.Gone, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$($case.Gone)' must be redacted in '$Text' (got '$out')"
        $out | Should -Match '(HOST|USER|DOMAIN|IP|IPV6|SID|MAC)-\d+'
    }

    It 'redacts identifiers after literal JSON escapes (\n, \t, \r, \uXXXX)' {
        foreach ($case in @($script:Glued | Where-Object { $_.Text.Contains($script:BS) })) {
            $out = Invoke-Redact $case.Text
            $out.IndexOf($case.Gone, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$($case.Gone)' must be redacted in '$($case.Text)' (got '$out')"
        }
    }

    It 'keeps the URL escape and the zone structure around the pseudonym' {
        Invoke-Redact 'peer%2010.20.30.40%20' | Should -Match '^peer%20IP-\d+%20$'
        Invoke-Redact 'link%20fe80::1c2d:3e4f:5a6b:7c8d%20' | Should -Match '^link%20IPV6-\d+%20$'
        Invoke-Redact 'path%5Cjdoe%5Cfile' | Should -Match '^path%5CUSER-\d+%5Cfile$'
    }

    It 'rebuilds a generated finding id from the redacted text (no dashed address or glued name survives)' {
        $f = New-OmniFinding -Title 'Gateway 10.20.30.40 unreachable from %22ACME-WS-042%22' -Severity 'Warning' -Component 'Network/00-15-5D-AA-BB-CC'
        $f.Id | Should -BeLike '*10-20-30-40*'
        $copy = ConvertTo-OmniRedacted -InputObject $f -Context $script:Ctx
        $copy.Id | Should -BeExactly ((('{0}|{1}' -f $copy.Component, $copy.Title).ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
        foreach ($gone in @('10-20-30-40', 'acme-ws-042', '00-15-5d-aa-bb-cc', '15-5d-aa')) { $copy.Id | Should -Not -BeLike "*$gone*" }
        $explicit = New-OmniFinding -Id 'gw-ACME-WS-042' -Title 'Gateway 10.20.30.40' -Severity 'Warning'
        (ConvertTo-OmniRedacted -InputObject $explicit -Context $script:Ctx).Id | Should -Match '^gw-HOST-\d+$'
        # v1 report findings (lower-case members) get the same treatment.
        $v1 = [pscustomobject]@{ id = $f.Id; title = $f.Title; component = $f.Component }
        (ConvertTo-OmniRedacted -InputObject $v1 -Context $script:Ctx).id | Should -BeExactly $copy.Id
    }

    It 'still keeps versions, times, and words next to escapes' {
        $text = 'build%2010.0.19045.1 at%2012:30:45 %20jdoes %5Cxjdoe'
        Invoke-Redact $text | Should -BeExactly $text
    }
}

# ---------------------------------------------------------------------------
# 4. Session import: validation and fuzzing
# ---------------------------------------------------------------------------

Describe 'Session import: targeted malformed input' {
    BeforeAll {
        $script:ImpDir = Join-Path $TestDrive 'import'
        New-Item -ItemType Directory -Path $script:ImpDir -Force | Out-Null
        $script:NativePath = Join-Path $script:ImpDir 'native-golden.json'
        Save-OmniSession -Session (New-OmniReportFixtureSession) -Path $script:NativePath | Out-Null
        $script:NativeJson = [System.IO.File]::ReadAllText($script:NativePath)
        $script:GoldenModules = @(($script:GoldenJson | ConvertFrom-Json).modules).Count
        $script:CaseNo = 0
        function New-CasePath { $script:CaseNo++; Join-Path $script:ImpDir ("case-{0:000}.json" -f $script:CaseNo) }
        function Set-JsonMember($Doc, [string] $Path, $Value) {
            # 'modules[0].findings[0].title' style paths into a ConvertFrom-Json object.
            $parts = $Path -split '\.'
            $node = $Doc
            for ($i = 0; $i -lt $parts.Count; $i++) {
                $m = [regex]::Match($parts[$i], '^([^\[]+)(?:\[(\d+)\])?$')
                $name = $m.Groups[1].Value
                $last = ($i -eq $parts.Count - 1)
                if ($m.Groups[2].Success) {
                    $arr = $node.$name
                    if ($last) { $arr[[int]$m.Groups[2].Value] = $Value } else { $node = $arr[[int]$m.Groups[2].Value] }
                } elseif ($last) {
                    if ($node.PSObject.Properties[$name]) { $node.$name = $Value } else { Add-Member -InputObject $node -MemberType NoteProperty -Name $name -Value $Value }
                } else {
                    $node = $node.$name
                }
            }
        }
        function New-MutatedFile([string] $BaseJson, [string] $Path, $Value) {
            $doc = $BaseJson | ConvertFrom-Json
            Set-JsonMember $doc $Path $Value
            return (Write-TestJson (New-CasePath) ($doc | ConvertTo-Json -Depth 50))
        }
    }

    It 'loads the golden v1 report and a native session (control)' {
        $v1 = Get-ImportOutcome $script:GoldenPath
        Get-SessionProblem $v1.Session | Should -BeNullOrEmpty
        @($v1.Session.Results).Count | Should -Be $script:GoldenModules
        $native = Get-ImportOutcome $script:NativePath
        Get-SessionProblem $native.Session | Should -BeNullOrEmpty
    }

    It 'rejects truncated JSON at any point' {
        foreach ($cut in @(1, 2, 10, 100, [int]($script:GoldenJson.Length / 2), ($script:GoldenJson.Length - 3))) {
            $p = Write-TestJson (New-CasePath) $script:GoldenJson.Substring(0, $cut)
            Test-ImportRejected (Get-ImportOutcome $p) | Should -BeTrue -Because "a report cut at $cut characters is invalid"
        }
    }

    It 'rejects nesting deeper than the limit without recursing (depth <_>)' -ForEach @(150, 1000, 5000) {
        $deep = ('[' * $_) + (']' * $_)
        $p = Write-TestJson (New-CasePath) ($script:GoldenJson.Replace('"Servers": [', ('"Deep": ' + $deep + ', "Servers": [')))
        $o = Get-ImportOutcome $p
        Test-ImportRejected $o | Should -BeTrue
        $o.Error.Exception.Message | Should -BeLike '*nested deeper*'
        $o.Ms | Should -BeLessThan 20000
    }

    It 'does not count brackets inside strings as nesting' {
        $p = New-MutatedFile $script:GoldenJson 'modules[1].findings[0].title' ('[' * 5000 + '{' * 5000)
        $o = Get-ImportOutcome $p
        Get-SessionProblem $o.Session | Should -BeNullOrEmpty
        $o.Session.Results[1].Findings[0].Title.Length | Should -Be 10000
    }

    It 'loads a huge string completely (no silent truncation)' {
        $big = 'A' * (1536 * 1024)
        $p = New-MutatedFile $script:GoldenJson 'modules[1].findings[0].evidence.detail' $big
        $o = Get-ImportOutcome $p
        Get-SessionProblem $o.Session | Should -BeNullOrEmpty
        $o.Session.Results[1].Findings[0].Detail.Length | Should -Be $big.Length
    }

    It 'rejects a file over the 64 MB cap before reading it' {
        $p = New-CasePath
        $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Create)
        try { $fs.SetLength(64MB + 1) } finally { $fs.Dispose() }
        $o = Get-ImportOutcome $p
        Test-ImportRejected $o | Should -BeTrue
        $o.Error.Exception.Message | Should -BeLike '*too large*'
        $o.Ms | Should -BeLessThan 10000
    }

    It 'rejects a wrong JSON type for v1 member <Path>' -ForEach @(
        @{ Path = 'modules'; Kind = 'string' }, @{ Path = 'modules'; Kind = 'object' }, @{ Path = 'modules[0]'; Kind = 'string' },
        @{ Path = 'modules[0]'; Kind = 'number' }, @{ Path = 'modules[0].findings'; Kind = 'string' }, @{ Path = 'modules[0].findings'; Kind = 'object' },
        @{ Path = 'modules[1].findings[0]'; Kind = 'string' }, @{ Path = 'modules[1].findings[0].title'; Kind = 'array' },
        @{ Path = 'modules[1].findings[0].title'; Kind = 'object' }, @{ Path = 'modules[1].findings[0].id'; Kind = 'array' },
        @{ Path = 'modules[1].findings[0].evidence'; Kind = 'string' }, @{ Path = 'modules[1].findings[0].evidence.detail'; Kind = 'array' },
        @{ Path = 'modules[0].metrics'; Kind = 'array' }, @{ Path = 'modules[0].metrics'; Kind = 'string' }, @{ Path = 'modules[0].name'; Kind = 'object' },
        @{ Path = 'modules[0].status'; Kind = 'array' }, @{ Path = 'host'; Kind = 'string' }, @{ Path = 'host.computerName'; Kind = 'object' },
        @{ Path = 'host.userName'; Kind = 'array' }, @{ Path = 'scan'; Kind = 'array' }, @{ Path = 'scan.timeRange'; Kind = 'string' },
        @{ Path = 'scan.startedAt'; Kind = 'object' }, @{ Path = 'summary'; Kind = 'number' }, @{ Path = 'summary.grade'; Kind = 'array' },
        @{ Path = 'schemaVersion'; Kind = 'number' }, @{ Path = 'schemaVersion'; Kind = 'array' }, @{ Path = 'tool'; Kind = 'string' }
    ) {
        $value = switch ($Kind) {
            'string' { 'not the right type' }
            'number' { 5 }
            'array' { , @('a', 'b') }
            'object' { [pscustomobject]@{ x = 1 } }
        }
        $o = Get-ImportOutcome (New-MutatedFile $script:GoldenJson $Path $value)
        Test-ImportRejected $o | Should -BeTrue -Because "$Path as $Kind must be rejected"
    }

    It 'rejects a wrong JSON type for native member <Path>' -ForEach @(
        @{ Path = 'Results'; Kind = 'string' }, @{ Path = 'Results'; Kind = 'object' }, @{ Path = 'Results[0]'; Kind = 'string' },
        @{ Path = 'Results[0].Findings'; Kind = 'string' }, @{ Path = 'Results[1].Findings[0]'; Kind = 'number' },
        @{ Path = 'Results[1].Findings[0].Title'; Kind = 'array' }, @{ Path = 'Results[0].Metrics'; Kind = 'array' },
        @{ Path = 'Results[0].ModuleName'; Kind = 'array' }, @{ Path = 'Host'; Kind = 'string' }, @{ Path = 'Host.ComputerName'; Kind = 'array' },
        @{ Path = 'Summary'; Kind = 'array' }, @{ Path = 'TimeRange'; Kind = 'string' }
    ) {
        $value = switch ($Kind) {
            'string' { 'not the right type' }
            'number' { 5 }
            'array' { , @('a', 'b') }
            'object' { [pscustomobject]@{ x = 1 } }
        }
        $o = Get-ImportOutcome (New-MutatedFile $script:NativeJson $Path $value)
        Test-ImportRejected $o | Should -BeTrue -Because "$Path as $Kind must be rejected"
    }

    It 'rejects an unknown schemaVersion <_>' -ForEach @('2.0.0', '0.9.0', 'abc', '', '1', '1.1', '10.0.0', '1.1.0; drop') {
        $o = Get-ImportOutcome (New-MutatedFile $script:GoldenJson 'schemaVersion' $_)
        Test-ImportRejected $o | Should -BeTrue
        $o.Error.Exception.Message | Should -Match 'schemaVersion'
    }

    It 'rejects missing required members' {
        $o = Get-ImportOutcome (Write-TestJson (New-CasePath) '{"hello":1}')
        Test-ImportRejected $o | Should -BeTrue
        $o.Error.Exception.Message | Should -BeLike '*no Results*'
        $doc = $script:GoldenJson | ConvertFrom-Json
        $doc.PSObject.Properties.Remove('modules')
        $o = Get-ImportOutcome (Write-TestJson (New-CasePath) ($doc | ConvertTo-Json -Depth 50))
        Test-ImportRejected $o | Should -BeTrue
        $o.Error.Exception.Message | Should -BeLike '*modules is missing*'
        Test-ImportRejected (Get-ImportOutcome (New-MutatedFile $script:GoldenJson 'modules' $null)) | Should -BeTrue
        Test-ImportRejected (Get-ImportOutcome (New-MutatedFile $script:NativeJson 'Results' $null)) | Should -BeTrue
    }

    It 'rejects documents that are not one JSON object: <_>' -ForEach @('[]', '[{"Results":[]}]', '"text"', '42', 'null', 'true', '', '   ') {
        Test-ImportRejected (Get-ImportOutcome (Write-TestJson (New-CasePath) $_)) | Should -BeTrue
    }

    It 'accepts nulls for optional members and skips null entries (counted)' {
        foreach ($member in @('host', 'scan', 'summary', 'options', 'tool', 'generatedAt')) {
            $o = Get-ImportOutcome (New-MutatedFile $script:GoldenJson $member $null)
            Get-SessionProblem $o.Session | Should -BeNullOrEmpty -Because "$member = null is allowed"
        }
        $o = Get-ImportOutcome (New-MutatedFile $script:GoldenJson 'modules[0]' $null)
        Get-SessionProblem $o.Session | Should -BeNullOrEmpty
        @($o.Session.Results).Count | Should -Be ($script:GoldenModules - 1)
    }

    It 'handles byte order marks: <Name>' -ForEach @(
        @{ Name = 'UTF-8'; Encoding = 'utf8' }, @{ Name = 'UTF-16 LE'; Encoding = 'utf16le' }, @{ Name = 'UTF-16 BE'; Encoding = 'utf16be' }, @{ Name = 'double UTF-8'; Encoding = 'utf8x2' }
    ) {
        $enc = switch ($Encoding) {
            'utf16le' { [System.Text.UnicodeEncoding]::new($false, $true) }
            'utf16be' { [System.Text.UnicodeEncoding]::new($true, $true) }
            default { [System.Text.UTF8Encoding]::new($true) }
        }
        $bytes = [byte[]]($enc.GetPreamble() + $enc.GetBytes($script:GoldenJson))
        if ($Encoding -eq 'utf8x2') { $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $bytes) }
        $p = New-CasePath
        [System.IO.File]::WriteAllBytes($p, $bytes)
        $o = Get-ImportOutcome $p
        Get-SessionProblem $o.Session | Should -BeNullOrEmpty
        @($o.Session.Results).Count | Should -Be $script:GoldenModules
    }

    It 'handles bytes that are not UTF-8 (inside a string: loaded; in the structure: rejected)' {
        $bytes = [System.Collections.Generic.List[byte]]::new([byte[]]$script:Utf8NoBom.GetBytes($script:GoldenJson))
        $at = $script:GoldenJson.IndexOf('DNS resolution is failing')
        $bytes.InsertRange($at, [byte[]]@(0xFF, 0xFE, 0xC3))
        $p = New-CasePath
        [System.IO.File]::WriteAllBytes($p, $bytes.ToArray())
        $o = Get-ImportOutcome $p
        Get-SessionProblem $o.Session | Should -BeNullOrEmpty
        $o.Session.Results[1].Findings[0].Title.Contains([string][char]0xFFFD) | Should -BeTrue

        $bytes = [System.Collections.Generic.List[byte]]::new([byte[]]$script:Utf8NoBom.GetBytes($script:GoldenJson))
        $bytes.Insert($script:GoldenJson.IndexOf('"modules"') - 1, [byte]0xFF)
        $p = New-CasePath
        [System.IO.File]::WriteAllBytes($p, $bytes.ToArray())
        Test-ImportRejected (Get-ImportOutcome $p) | Should -BeTrue
    }

    It 'handles NUL characters in strings and rejects them in the structure' {
        $o = Get-ImportOutcome (New-MutatedFile $script:GoldenJson 'modules[1].findings[0].title' ('a' + [char]0 + 'b'))
        Get-SessionProblem $o.Session | Should -BeNullOrEmpty
        # A NUL between tokens: Windows PowerShell rejects it, PowerShell 7's reader may skip it.
        $raw = $script:GoldenJson.Insert($script:GoldenJson.IndexOf('"modules"'), [string][char]0)
        $o = Get-ImportOutcome (Write-TestJson (New-CasePath) $raw)
        if ($o.Error) { Test-ImportRejected $o | Should -BeTrue } else { Get-SessionProblem $o.Session | Should -BeNullOrEmpty }
    }

    It 'handles duplicate keys with a single documented outcome' {
        $cases = @(
            $script:GoldenJson.Replace('"schemaVersion": "1.1.0",', '"schemaVersion": "1.1.0", "schemaVersion": "9.0.0",'),
            $script:GoldenJson.Replace('"schemaVersion": "1.1.0",', '"schemaVersion": "1.1.0", "SCHEMAVERSION": "1.1.0",'),
            $script:GoldenJson.Replace('"schemaVersion": "1.1.0",', '"schemaVersion": "1.1.0", "modules": [],')
        )
        foreach ($json in $cases) {
            $o = Get-ImportOutcome (Write-TestJson (New-CasePath) $json)
            if ($o.Error) { Test-ImportRejected $o | Should -BeTrue } else { Get-SessionProblem $o.Session | Should -BeNullOrEmpty }
        }
        # A repeated key keeps its last value (or the reader rejects the file): an unsupported last value is rejected either way.
        Test-ImportRejected (Get-ImportOutcome (Write-TestJson (New-CasePath) $cases[0])) | Should -BeTrue
    }

    It 'never evaluates PowerShell syntax in strings' {
        Remove-Variable -Name OmniSecPwned -Scope Global -ErrorAction SilentlyContinue
        $payload = '$(Set-Variable -Name OmniSecPwned -Value 1 -Scope Global) @(Set-Variable -Name OmniSecPwned -Value 2 -Scope Global) ${env:USERNAME} `$x ' + "'+(Set-Variable -Name OmniSecPwned -Value 3 -Scope Global)+'"
        $doc = $script:GoldenJson | ConvertFrom-Json
        $doc.host.computerName = $payload
        $doc.modules[1].findings[0].title = $payload
        $doc.modules[1].findings[0].evidence.detail = $payload
        $doc.modules[1].name = $payload
        $doc.scan.timeRange.label = $payload
        Add-Member -InputObject $doc.modules[0].metrics -MemberType NoteProperty -Name $payload -Value $payload
        $p = Write-TestJson (New-CasePath) ($doc | ConvertTo-Json -Depth 50)
        $o = Get-ImportOutcome $p
        Get-SessionProblem $o.Session | Should -BeNullOrEmpty
        $o.Session.Host.ComputerName | Should -BeExactly $payload
        $o.Session.Results[1].Findings[0].Title | Should -BeExactly $payload
        $o.Session.Results[0].Metrics[$payload] | Should -BeExactly $payload
        $dir = Join-Path $TestDrive 'pwn'
        $null = Export-OmniReport -Session $o.Session -OutputDirectory $dir -Format Html, Json, Csv, Md, Pdf -BaseName 'pwn' -WarningAction SilentlyContinue
        $null = Export-OmniReport -Session $o.Session -OutputDirectory $dir -Format Html, Json, Md -BaseName 'pwn-r' -Redact -WarningAction SilentlyContinue
        Get-Variable -Name OmniSecPwned -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $native = $script:NativeJson | ConvertFrom-Json
        $native.Results[1].Findings[0].Title = $payload
        $o = Get-ImportOutcome (Write-TestJson (New-CasePath) ($native | ConvertTo-Json -Depth 50))
        $o.Session.Results[1].Findings[0].Title | Should -BeExactly $payload
        Get-Variable -Name OmniSecPwned -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Session import: deterministic fuzzer (200 cases)' {
    BeforeAll {
        $script:FuzzDir = Join-Path $TestDrive 'fuzz'
        New-Item -ItemType Directory -Path $script:FuzzDir -Force | Out-Null
        $nativePath = Join-Path $script:FuzzDir 'native-golden.json'
        Save-OmniSession -Session (New-OmniReportFixtureSession) -Path $nativePath | Out-Null
        $script:FuzzBases = @($script:GoldenJson, [System.IO.File]::ReadAllText($nativePath))
        $script:FuzzRng = [System.Random]::new(20261018)

        function Get-JsonSlot($Node, [System.Collections.Generic.List[object]] $Slots, [int] $Depth) {
            if ($Depth -gt 14 -or $null -eq $Node) { return }
            if ($Node -is [System.Management.Automation.PSCustomObject]) {
                foreach ($p in @($Node.PSObject.Properties)) {
                    $Slots.Add([pscustomobject]@{ Parent = $Node; Name = $p.Name; Index = -1 })
                    Get-JsonSlot $p.Value $Slots ($Depth + 1)
                }
            } elseif ($Node -is [array]) {
                for ($i = 0; $i -lt $Node.Length; $i++) {
                    $Slots.Add([pscustomobject]@{ Parent = $Node; Name = $null; Index = $i })
                    Get-JsonSlot $Node[$i] $Slots ($Depth + 1)
                }
            }
        }
        function Get-FuzzValue([int] $Kind) {
            switch ($Kind) {
                0 { return 'string' }
                1 { return 42 }
                2 { return -1 }
                3 { return 1.5e308 }
                4 { return $true }
                5 { return $null }
                6 { return , @() }
                7 { return , @('a', 1, $null) }
                8 { return [pscustomobject]@{ x = 1 } }
                9 { return ('x' * 50000) }
                10 { return '$(Set-Variable -Name OmniFuzzPwned -Value 1 -Scope Global)' }
                11 { return '@{a=1}' }
                12 { return ([string][char]0 + 'nul') }
                13 { return [pscustomobject]@{ value = 'wrapped' } }
                14 { return ('[' * 300) }
                default { return '' }
            }
        }
        function Set-FuzzSlot($Slot, $Value) {
            if ($Slot.Index -ge 0) { $Slot.Parent[$Slot.Index] = $Value } else { $Slot.Parent.($Slot.Name) = $Value }
        }
        function New-FuzzCase([int] $No) {
            $r = $script:FuzzRng
            $base = $script:FuzzBases[$(if ($r.Next(10) -lt 7) { 0 } else { 1 })]
            $op = $r.Next(12)
            $desc = "case $No op $op"
            $bytes = $null
            $text = $null
            switch ($op) {
                { $_ -in 0, 1, 2 } {
                    # Structural: wrong type / null / payload at a random member.
                    $doc = $base | ConvertFrom-Json
                    $slots = [System.Collections.Generic.List[object]]::new()
                    Get-JsonSlot $doc $slots 0
                    $slot = $slots[$r.Next($slots.Count)]
                    $kind = $r.Next(16)
                    Set-FuzzSlot $slot (Get-FuzzValue $kind)
                    $desc += " set $($slot.Name)[$($slot.Index)] kind $kind"
                    $text = $doc | ConvertTo-Json -Depth 60
                }
                3 {
                    # Structural: delete a random member.
                    $doc = $base | ConvertFrom-Json
                    $slots = [System.Collections.Generic.List[object]]::new()
                    Get-JsonSlot $doc $slots 0
                    $members = @($slots | Where-Object { $_.Index -lt 0 })
                    $slot = $members[$r.Next($members.Count)]
                    $slot.Parent.PSObject.Properties.Remove($slot.Name)
                    $desc += " delete $($slot.Name)"
                    $text = $doc | ConvertTo-Json -Depth 60
                }
                4 {
                    $versions = @('2.0.0', '0.9.0', '1', 'abc', '', '1.1', '1.1.0-beta', '10.0.0', '1.9.9', '1.0.0')
                    $v = $versions[$r.Next($versions.Count)]
                    $text = [regex]::Replace($base, '"schemaVersion":\s*"[^"]*"', ('"schemaVersion": "' + $v + '"'))
                    $desc += " schemaVersion $v"
                }
                5 { $cut = $r.Next(1, $base.Length); $text = $base.Substring(0, $cut); $desc += " truncate $cut" }
                6 {
                    $junk = @('{', '}', '[', ']', '"', ',', ':', '\', 'x', ' ', [string][char]0, 'null', '1e999', '"a":')
                    $j = $junk[$r.Next($junk.Count)]
                    $at = $r.Next($base.Length)
                    $text = $base.Insert($at, $j)
                    $desc += " insert '$j' at $at"
                }
                7 { $at = $r.Next($base.Length); $text = $base.Remove($at, 1); $desc += " remove at $at" }
                8 {
                    $b = [byte[]]$script:Utf8NoBom.GetBytes($base)
                    $at = $r.Next($b.Length)
                    $bad = @(0xFF, 0xFE, 0xC3, 0x80, 0xED)[$r.Next(5)]
                    $b[$at] = [byte]$bad
                    $bytes = $b
                    $desc += " byte 0x{0:X2} at $at" -f $bad
                }
                9 {
                    $boms = @(@(0xEF, 0xBB, 0xBF), @(0xFF, 0xFE), @(0xFE, 0xFF), @(0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF))
                    $k = $r.Next($boms.Count)
                    $enc = switch ($k) { 1 { [System.Text.UnicodeEncoding]::new($false, $false) } 2 { [System.Text.UnicodeEncoding]::new($true, $false) } default { $script:Utf8NoBom } }
                    $bytes = [byte[]]([byte[]]$boms[$k] + [byte[]]$enc.GetBytes($base))
                    $desc += " bom $k"
                }
                10 {
                    $d = @(5, 50, 90, 101, 500, 1500, 20000)[$r.Next(7)]
                    $text = ('{"x":' * $d) + $base + ('}' * $d)
                    if ($r.Next(2) -eq 0) { $text = $base.Replace('"Servers": [', ('"Deep": ' + ('[' * $d) + (']' * $d) + ', "Servers": [')) }
                    $desc += " nest $d"
                }
                default {
                    $text = $base.Replace('"schemaVersion": "1.1.0",', '"schemaVersion": "1.1.0", "schemaVersion": "1.1.0",')
                    $text = $text.Replace('"Results": [', '"Results": [], "Results": [')
                    $desc += ' duplicate keys'
                }
            }
            if ($null -eq $bytes) { $bytes = [byte[]]$script:Utf8NoBom.GetBytes($text) }
            $path = Join-Path $script:FuzzDir ("fuzz-{0:000}.json" -f $No)
            [System.IO.File]::WriteAllBytes($path, $bytes)
            return [pscustomobject]@{ No = $No; Path = $path; Description = $desc }
        }
    }

    It 'every case loads a well-formed session or throws the documented import error' {
        Remove-Variable -Name OmniFuzzPwned -Scope Global -ErrorAction SilentlyContinue
        $failures = [System.Collections.Generic.List[string]]::new()
        $loaded = 0
        $rejected = 0
        for ($n = 0; $n -lt 200; $n++) {
            $case = New-FuzzCase $n
            $o = Get-ImportOutcome $case.Path
            if ($o.Ms -gt 20000) { $failures.Add("$($case.Description): took $($o.Ms) ms") }
            if ($o.Error) {
                if (Test-ImportRejected $o) { $rejected++ }
                else { $failures.Add("$($case.Description): wrong error $($o.Error.Exception.GetType().FullName) [$($o.Error.FullyQualifiedErrorId)] $($o.Error.Exception.Message)") }
            } else {
                $problem = Get-SessionProblem $o.Session
                if ($problem) { $failures.Add("$($case.Description): loaded but $problem") } else { $loaded++ }
            }
        }
        ($failures -join [Environment]::NewLine) | Should -BeNullOrEmpty
        $loaded | Should -BeGreaterThan 20 -Because 'the fuzzer must also produce loadable variants'
        $rejected | Should -BeGreaterThan 20 -Because 'the fuzzer must also produce invalid input'
        Get-Variable -Name OmniFuzzPwned -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 5. Ollama assistant: redacted prompts, sanitized output
# ---------------------------------------------------------------------------

Describe 'Ollama assistant: prompt redaction and output sanitization' {
    BeforeAll {
        $sid = 'S-1-5-21-1004336348-1177238915-682003330-1001'
        $r = New-OmniResult -ModuleName 'Network' -Category 'Network'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Id 'network-gateway-acme-ws-042' -Title 'Gateway 10.20.30.40 unreachable from ACME-WS-042' `
                -Severity 'Critical' -Component 'Network/00-15-5D-AA-BB-CC' -LikelyCause "CONTOSO\jdoe changed the address of fe80::1c2d:3e4f:5a6b:7c8d" `
                -Recommendation "Ask jdoe ($sid) to check C:\Users\jdoe\AppData and acme-ws-042.corp.contoso.com")
        $null = Complete-OmniResult -Result $r
        $script:OSession = [pscustomobject]@{
            Results = @($r); Summary = [pscustomobject]@{ Score = 40; Grade = 'Critical' }
            Host = [pscustomobject]@{ ComputerName = 'ACME-WS-042'; UserName = 'CONTOSO\jdoe'; DnsDomain = 'corp.contoso.com' }
            ScanPlan = [pscustomobject]@{ Type = 'Workflow'; Name = 'Triage for ACME-WS-042' }
        }
        $script:OIdentifiers = @('ACME-WS-042', 'acme-ws-042', 'jdoe', 'CONTOSO', 'contoso.com', '10.20.30.40', '1c2d:3e4f', '00-15-5D-AA-BB-CC', '1004336348')
        $script:OBodies = [System.Collections.Generic.List[string]]::new()
        $script:OSentIds = [System.Collections.Generic.List[string]]::new()

        $script:AnalysisTransport = {
            param($method, $uri, $body)
            if ($uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ model = 'gemma4:e2b' }) } }
            $script:OBodies.Add(($body | ConvertTo-Json -Depth 30 -Compress))
            $marker = 'OmniDiag evidence JSON:'
            $evidence = $body.prompt.Substring($body.prompt.IndexOf($marker) + $marker.Length).Trim() | ConvertFrom-Json
            $sent = [string]@($evidence.findings)[0].id
            $script:OSentIds.Add($sent)
            $reply = [ordered]@{
                summary = 'ok'; priorities = @([ordered]@{ title = 't'; urgency = 'high'; evidenceIds = @($sent) })
                correlations = @(); nextSteps = @(); limitations = @()
            }
            return [pscustomobject]@{ response = ($reply | ConvertTo-Json -Depth 6 -Compress) }
        }
        $script:ChatTransport = {
            param($method, $uri, $body)
            if ($uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ model = 'gemma4:e2b' }) } }
            $script:OBodies.Add(($body | ConvertTo-Json -Depth 30 -Compress))
            $content = [string]@($body.messages)[@($body.messages).Count - 1].content
            $marker = 'Evidence for this turn (JSON):'
            $evidence = $content.Substring($content.IndexOf($marker) + $marker.Length).Trim() | ConvertFrom-Json
            $sent = [string]@($evidence.findings)[0].id
            $script:OSentIds.Add($sent)
            $reply = [ordered]@{ answer = 'ok'; findingIds = @($sent); runbookIds = @('rb-net'); requiresApproval = $false; suggestedQuestions = @(); limitations = @() }
            return [pscustomobject]@{ message = [pscustomobject]@{ role = 'assistant'; content = ($reply | ConvertTo-Json -Depth 6 -Compress) } }
        }

        $esc = [string][char]27
        $bel = [string][char]7
        $script:Evil = 'RED' + $esc + '[31mX' + $esc + '[0m ' + $esc + ']0;owned' + $bel + ' ' + $esc + ']8;;http://e' + $esc + '\link' + $esc + ']8;;' + $esc + '\ ' +
            [char]0x9B + '2J safe' + [char]13 + 'FAKE ' + [char]0x202E + 'gpj.exe ' + [char]0 + 'bell' + $bel + ' end' + [char]0x2028 + 'next'
        function Get-ControlProblem([string] $Text) {
            if ($Text -cmatch '[\x00-\x08\x0B-\x1F\x7F-\x9F]') { return 'control character' }
            foreach ($c in @(0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x2028, 0x2029)) {
                if ($Text.IndexOf([char]$c) -ge 0) { return ('U+{0:X4}' -f $c) }
            }
            return $null
        }
    }

    It 'sends no host, user, domain, path, SID, or address to the model (single analysis)' {
        $script:OBodies.Clear(); $script:OSentIds.Clear()
        $a = Invoke-OmniOllamaAnalysis -Session $script:OSession -Question 'Why can ACME-WS-042 not reach 10.20.30.40 as CONTOSO\jdoe?' -Model 'gemma4:e2b' -Transport $script:AnalysisTransport
        $script:OBodies.Count | Should -Be 1
        foreach ($id in $script:OIdentifiers) {
            $script:OBodies[0].IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$id' must not reach the model"
        }
        $script:OBodies[0] | Should -Match 'IP-\d+'
        # The model cited the id it was given; the analysis reports the session's own id.
        $script:OSentIds[0] | Should -Not -Be 'network-gateway-acme-ws-042'
        $a.Priorities[0].evidenceIds | Should -Be @('network-gateway-acme-ws-042')
        @($a.UnverifiedCitations).Count | Should -Be 0
    }

    It 'sends no identifiers in any turn of a conversation, history included' {
        $script:OBodies.Clear(); $script:OSentIds.Clear()
        $rb = [pscustomobject]@{ Id = 'rb-net'; Title = 'Gateway checks for ACME-WS-042'; Approved = $true; Owner = 'jdoe'; AppliesTo = @('network/'); Tags = @('gateway')
            Body = 'Ping 10.20.30.40 from ACME-WS-042 and check C:\Users\jdoe\net.log' }
        $conv = New-OmniAssistantConversation -Session $script:OSession -Runbook @($rb) -Model 'gemma4:e2b' -Transport $script:ChatTransport
        $t1 = Invoke-OmniAssistantTurn -Conversation $conv -Question 'Why is the gateway 10.20.30.40 unreachable from ACME-WS-042?'
        $t2 = Invoke-OmniAssistantTurn -Conversation $conv -Question 'What should jdoe check on acme-ws-042.corp.contoso.com first?'
        $script:OBodies.Count | Should -Be 2
        foreach ($body in $script:OBodies) {
            foreach ($id in $script:OIdentifiers) {
                $body.IndexOf($id, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$id' must not reach the model"
            }
        }
        $t1.FindingIds | Should -Be @('network-gateway-acme-ws-042')
        $t2.FindingIds | Should -Be @('network-gateway-acme-ws-042')
        $t1.Question | Should -BeLike '*ACME-WS-042*' -Because 'the local turn record keeps what the technician typed'
        @($t1.UnverifiedCitations).Count | Should -Be 0
    }

    It 'strips terminal control sequences from analysis output' {
        $evil = $script:Evil
        $transport = {
            param($method, $uri, $body)
            if ($uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ model = 'gemma4:e2b' }) } }
            $reply = [ordered]@{
                summary = $evil
                priorities = @([ordered]@{ title = $evil; urgency = $evil; evidenceIds = @(('inv' + [char]27 + '[2Jalid')) })
                correlations = @([ordered]@{ hypothesis = $evil; confidence = 5; evidenceIds = @() })
                nextSteps = @([ordered]@{ step = $evil; evidenceIds = @(); requiresApproval = $true })
                limitations = @($evil)
            }
            return [pscustomobject]@{ response = ($reply | ConvertTo-Json -Depth 6 -Compress) }
        }.GetNewClosure()
        $a = Invoke-OmniOllamaAnalysis -Session $script:OSession -Model 'gemma4:e2b' -Transport $transport
        foreach ($text in @($a.Summary, $a.Priorities[0].title, $a.Priorities[0].urgency, $a.Correlations[0].hypothesis, $a.NextSteps[0].step, $a.Limitations[0]) + @($a.UnverifiedCitations)) {
            Get-ControlProblem ([string]$text) | Should -BeNullOrEmpty -Because "model text '$text' must be display-safe"
        }
        $a.Summary | Should -BeLike 'REDX *'
        $a.Summary | Should -BeLike '*safe*FAKE*'
        $a.Summary | Should -BeLike "*end`nnext"
        @($a.UnverifiedCitations) | Should -Be @('invalid')
    }

    It 'strips terminal control sequences from conversation answers' {
        $evil = $script:Evil
        $transport = {
            param($method, $uri, $body)
            if ($uri -like '*/api/tags') { return [pscustomobject]@{ models = @([pscustomobject]@{ model = 'gemma4:e2b' }) } }
            $reply = [ordered]@{ answer = $evil; findingIds = @($evil); runbookIds = @(); requiresApproval = $false; suggestedQuestions = @($evil); limitations = @($evil) }
            return [pscustomobject]@{ message = [pscustomobject]@{ role = 'assistant'; content = ($reply | ConvertTo-Json -Depth 6 -Compress) } }
        }.GetNewClosure()
        $conv = New-OmniAssistantConversation -Session $script:OSession -Runbook @() -Model 'gemma4:e2b' -Transport $transport
        $t = Invoke-OmniAssistantTurn -Conversation $conv -Question 'What failed?'
        foreach ($text in @($t.Answer) + @($t.SuggestedQuestions) + @($t.Limitations) + @($t.UnverifiedCitations)) {
            Get-ControlProblem ([string]$text) | Should -BeNullOrEmpty -Because "model text '$text' must be display-safe"
        }
        $t.Answer | Should -BeLike 'REDX *'
    }

    It 'strips control sequences from what a local server returns in errors and model names' {
        $transport = {
            param($method, $uri, $body)
            throw ('down' + [char]27 + '[2J' + [char]13 + 'spoofed')
        }
        $status = Test-OmniOllama -Model 'gemma4:e2b' -Transport $transport
        $status.Available | Should -BeFalse
        Get-ControlProblem $status.Error | Should -BeNullOrEmpty
        $status.Error | Should -BeLike '*down*spoofed*'
        $names = {
            param($method, $uri, $body)
            return [pscustomobject]@{ models = @([pscustomobject]@{ model = ('gemma4:e2b' + [char]27 + '[8m') }) }
        }
        $s2 = Test-OmniOllama -Model 'gemma4:e2b' -Transport $names
        Get-ControlProblem (@($s2.Models)[0]) | Should -BeNullOrEmpty
    }
}
