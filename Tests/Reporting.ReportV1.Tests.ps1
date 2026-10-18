#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Report schema v1: the projection (ConvertTo-OmniReportV1), the deterministic JSON
    writer, the reverse mapping (ConvertFrom-OmniReportV1 / Import-OmniSession), a
    golden-file comparison, and JSON Schema validation (PowerShell 7 only - Test-Json
    -Schema needs it; skipped on Windows PowerShell 5.1). OS-independent: the fixture
    session is synthetic and uses fixed UTC timestamps.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    . (Join-Path $PSScriptRoot 'golden/ReportFixture.ps1')

    $script:SchemaPath = Join-Path $script:Root 'schemas/omnidiag-report.v1.json'
    $script:GoldenPath = Join-Path $PSScriptRoot 'golden/report-v1.fixture.json'
    $script:CanValidate = $PSVersionTable.PSVersion.Major -ge 7

    $script:Session = New-OmniReportFixtureSession
    $script:V1 = ConvertTo-OmniReportV1 -Session $script:Session -Option (Get-OmniReportFixtureOption) -GeneratedAt (Get-OmniReportFixtureTime)
    $script:Json = $script:V1 | ConvertTo-OmniJsonText

    function Get-V1Module([string] $Id) { @($script:V1.modules | Where-Object { $_.id -eq $Id })[0] }

    # Volatile fields (generation time, tool version) are normalized before comparing.
    function ConvertTo-NormalizedReport([string] $Text) {
        $t = $Text -replace "`r`n", "`n"
        $t = $t -replace '"generatedAt": "[^"]*"', '"generatedAt": "<generatedAt>"'
        $t = $t -replace '("tool": \{\s*"name": "OmniDiag",\s*"version": )"[^"]*"', '$1"<version>"'
        return $t.TrimEnd()
    }
}

Describe 'ConvertTo-OmniReportV1 envelope' {
    It 'emits the v1 top-level properties in a fixed order' {
        @($script:V1.Keys) | Should -Be @('schemaVersion', 'tool', 'generatedAt', 'host', 'options', 'scan', 'summary', 'modules')
        $script:V1.schemaVersion | Should -Be '1.0.0'
        (Get-OmniReportSchemaVersion) | Should -Be '1.0.0'
        $script:V1.tool.name | Should -Be 'OmniDiag'
        $script:V1.tool.version | Should -Be ([string](Get-OmniVersion))
    }

    It 'projects the host and sorts the options' {
        $script:V1.host.computerName | Should -Be 'FIXTURE-PC'
        $script:V1.host.isAdmin | Should -BeFalse
        @($script:V1.options.Keys) | Should -Be @('command', 'groups', 'range')
    }

    It 'writes ISO-8601 UTC timestamps with milliseconds' {
        $script:V1.generatedAt | Should -Be '2026-06-01T08:00:00.000Z'
        $script:V1.scan.startedAt | Should -Be '2026-06-01T08:00:00.000Z'
        (Get-V1Module 'network.dns-resolver').startedAt | Should -Be '2026-06-01T08:00:02.000Z'
        ConvertTo-OmniIsoTimestamp -Value '/Date(1780300800000)/' | Should -Be '2026-06-01T08:00:00.000Z'
        ConvertTo-OmniIsoTimestamp -Value 'not a date' | Should -BeNullOrEmpty
    }

    It 'carries the health score, grade, and disjoint counts' {
        $script:V1.summary.healthScore | Should -Be $script:Session.Summary.Score
        $script:V1.summary.grade | Should -Be $script:Session.Summary.Grade
        $c = $script:V1.summary.counts
        $c.passed | Should -Be 1
        $c.info | Should -Be 2
        $c.warning | Should -Be 1
        $c.critical | Should -Be 3
    }

    It 'reports a null score for a session with no completed modules' {
        $empty = [pscustomobject]@{ Results = @(); Summary = $null; Cancelled = $true }
        $doc = ConvertTo-OmniReportV1 -Session $empty
        $doc.summary.healthScore | Should -BeNullOrEmpty
        $doc.summary.grade | Should -BeNullOrEmpty
        $doc.scan.cancelled | Should -BeTrue
        @($doc.modules).Count | Should -Be 0
    }
}

Describe 'Module and finding projection' {
    It 'keeps stamped ids/groups and derives them for pre-v1 results' {
        @($script:V1.modules.id) | Should -Be @('system.system-information', 'network.dns-resolver', 'storage.disk', 'security.bitlocker', 'extras.custom-plugin')
        (Get-V1Module 'storage.disk').group | Should -Be 'storage'
    }

    It 'records skip reasons, errors, and elevation requirements' {
        $skip = Get-V1Module 'security.bitlocker'
        $skip.status | Should -Be 'Skipped'
        $skip.skippedReason | Should -Be 'RequiresElevation'
        $skip.requiresElevation | Should -BeTrue
        $fail = Get-V1Module 'extras.custom-plugin'
        $fail.status | Should -Be 'Failed'
        $fail.error | Should -Be 'intentional failure'
        (Get-V1Module 'network.dns-resolver').skippedReason | Should -BeNullOrEmpty
    }

    It 'maps <Native> to <V1> (passed = <Passed>)' -ForEach @(
        @{ Native = 'Pass'; V1 = 'Info'; Passed = $true }
        @{ Native = 'Information'; V1 = 'Info'; Passed = $false }
        @{ Native = 'Warning'; V1 = 'Warning'; Passed = $false }
        @{ Native = 'Error'; V1 = 'Critical'; Passed = $false }
        @{ Native = 'Critical'; V1 = 'Critical'; Passed = $false }
    ) {
        ConvertTo-OmniV1Severity -Severity $Native | Should -Be $V1
        $r = New-OmniResult -ModuleName 'Map' -Category 'Test'
        Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 't' -Severity $Native)
        $doc = ConvertTo-OmniReportV1 -Session ([pscustomobject]@{ Results = @((Complete-OmniResult -Result $r)) })
        $f = $doc.modules[0].findings[0]
        $f.severity | Should -Be $V1
        $f.severityNative | Should -Be $Native
        $f.passed | Should -Be $Passed
    }

    It 'nests detail and data under evidence and links findings to their module' {
        $f = (Get-V1Module 'network.dns-resolver').findings[0]
        @($f.Keys) | Should -Be @('id', 'moduleId', 'title', 'severity', 'severityNative', 'passed', 'component', 'evidence', 'likelyCause', 'recommendation', 'confidence')
        $f.id | Should -Be 'network-dns-failure'
        $f.moduleId | Should -Be 'network.dns-resolver'
        $f.evidence.detail | Should -Match 'timed out'
        $f.confidence | Should -Be 80
    }

    It 'sorts unordered hashtable keys (ordinal) and keeps ordered ones' {
        $data = (Get-V1Module 'network.dns-resolver').findings[0].evidence.data
        @($data.Keys) | Should -Be @('Servers', 'alpha', 'zeta')
        @((Get-V1Module 'network.dns-resolver').findings[2].evidence.data.Keys) | Should -Be @('Entries', 'Ratio')
    }

    It 'does not modify the session' {
        $before = $script:Session | ConvertTo-Json -Depth 8
        ConvertTo-OmniReportV1 -Session $script:Session | Out-Null
        ($script:Session | ConvertTo-Json -Depth 8) | Should -Be $before
    }
}

Describe 'ConvertTo-OmniJsonText' {
    It 'is deterministic' {
        $again = ConvertTo-OmniReportV1 -Session $script:Session -Option (Get-OmniReportFixtureOption) -GeneratedAt (Get-OmniReportFixtureTime) | ConvertTo-OmniJsonText
        $again | Should -BeExactly $script:Json
    }

    It 'writes ASCII only, escaping control and non-ASCII characters' {
        $script:Json | Should -Not -Match '[^\x09\x0A\x0D\x20-\x7E]'
        $script:Json.Contains('Caf' + '\' + 'u00e9') | Should -BeTrue
        $script:Json.Contains('timed out.' + '\' + 'nSecond line') | Should -BeTrue
        $script:Json.Contains('Ignore \"quoted\" \\ text.') | Should -BeTrue
    }

    It 'renders scalars culture-invariantly and maps NaN to null' {
        ConvertTo-OmniJsonText -InputObject ([ordered]@{ d = 0.25; n = [double]::NaN; b = $true; z = $null; e = @(); o = @{} }) -Compress |
            Should -Be '{"d":0.25,"n":null,"b":true,"z":null,"e":[],"o":{}}'
    }

    It 'parses back with ConvertFrom-Json' {
        { $script:Json | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe 'Golden file' {
    It 'matches Tests/golden/report-v1.fixture.json (generatedAt and tool.version normalized)' {
        $golden = [System.IO.File]::ReadAllText($script:GoldenPath)
        ConvertTo-NormalizedReport $script:Json | Should -BeExactly (ConvertTo-NormalizedReport $golden)
    }
}

Describe 'JSON Schema validation (PowerShell 7)' {
    It 'is a valid 2020-12 schema document' {
        $schema = Get-Content -LiteralPath $script:SchemaPath -Raw | ConvertFrom-Json
        $schema.'$schema' | Should -Be 'https://json-schema.org/draft/2020-12/schema'
    }

    It 'validates the fixture projection and the golden file' {
        if (-not $script:CanValidate) { Set-ItResult -Skipped -Because 'Test-Json -Schema requires PowerShell 7'; return }
        Test-Json -Json $script:Json -SchemaFile $script:SchemaPath | Should -BeTrue
        Test-Json -Json ([System.IO.File]::ReadAllText($script:GoldenPath)) -SchemaFile $script:SchemaPath | Should -BeTrue
    }

    It 'validates a report written by Export-OmniJsonReport for an empty, cancelled session' {
        if (-not $script:CanValidate) { Set-ItResult -Skipped -Because 'Test-Json -Schema requires PowerShell 7'; return }
        $path = Join-Path $TestDrive 'empty.json'
        Export-OmniJsonReport -Session ([pscustomobject]@{ Results = @(); Summary = $null; Cancelled = $true }) -Path $path | Out-Null
        Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $script:SchemaPath | Should -BeTrue
    }

    It 'rejects documents that break the contract' {
        if (-not $script:CanValidate) { Set-ItResult -Skipped -Because 'Test-Json -Schema requires PowerShell 7'; return }
        $bad = $script:Json -replace '"severity": "Critical"', '"severity": "Error"'
        Test-Json -Json $bad -SchemaFile $script:SchemaPath -ErrorAction SilentlyContinue | Should -BeFalse
        $badPass = $script:Json -replace '"passed": true', '"passed": false'
        Test-Json -Json $badPass -SchemaFile $script:SchemaPath -ErrorAction SilentlyContinue | Should -BeFalse
    }
}

Describe 'ConvertFrom-OmniReportV1 round trip' {
    BeforeAll {
        $script:Back = ConvertFrom-OmniReportV1 -Report $script:Json
    }

    It 'restores native severities, statuses, and module identity' {
        $script:Back.PSTypeNames | Should -Contain 'OmniDiag.Session'
        $nat = @($script:Back.Results | ForEach-Object { $_.Findings } | ForEach-Object { $_.Severity })
        $orig = @($script:Session.Results | ForEach-Object { $_.Findings } | ForEach-Object { $_.Severity })
        $nat | Should -Be $orig
        @($script:Back.Results.Status) | Should -Be @($script:Session.Results.Status)
        @($script:Back.Results.ModuleId) | Should -Be @($script:V1.modules.id)
        ($script:Back.Results | Where-Object ModuleName -eq 'BitLocker').SkippedReason | Should -Be 'RequiresElevation'
    }

    It 'keeps the score, host, time range, and timing' {
        $script:Back.Summary.Score | Should -Be $script:Session.Summary.Score
        $script:Back.Host.ComputerName | Should -Be 'FIXTURE-PC'
        $script:Back.TimeRange.Label | Should -Be 'Last7Days'
        $script:Back.StartTime.ToUniversalTime() | Should -Be (Get-OmniReportFixtureTime)
        $script:Back.Results[1].DurationMs | Should -Be 340
    }

    It 'compares as unchanged against the original session' {
        $cmp = Compare-OmniSession -Before $script:Session -After $script:Back
        $cmp.Verdict | Should -Be 'Unchanged'
        @($cmp.Resolved).Count | Should -Be 0
        @($cmp.New).Count | Should -Be 0
    }

    It 'yields the same exit code as the original session' {
        Get-OmniExitCode -Session $script:Back | Should -Be (Get-OmniExitCode -Session $script:Session)
    }

    It 're-projects to the same document' {
        $again = ConvertTo-OmniReportV1 -Session $script:Back -Option (Get-OmniReportFixtureOption) -GeneratedAt (Get-OmniReportFixtureTime) | ConvertTo-OmniJsonText
        $again | Should -BeExactly $script:Json
    }

    It 'rejects other major versions and documents without schemaVersion' {
        { ConvertFrom-OmniReportV1 -Report ($script:Json -replace '"schemaVersion": "1.0.0"', '"schemaVersion": "2.0.0"') } | Should -Throw '*Unsupported*'
        { ConvertFrom-OmniReportV1 -Report '{"hello":1}' } | Should -Throw '*schemaVersion*'
    }
}

Describe 'Saved sessions and report files' {
    It 'Import-OmniSession reads a v1 JSON report' {
        $path = Join-Path $TestDrive 'report.json'
        Export-OmniJsonReport -Session $script:Session -Path $path | Out-Null
        $loaded = Import-OmniSession -Path $path
        $loaded.SourcePath | Should -Be (Get-Item $path).FullName
        $loaded.SchemaVersion | Should -Be '1.0.0'
        $loaded.Summary.Score | Should -Be $script:Session.Summary.Score
    }

    It 'Save-OmniSession writes the native format and Import-OmniSession reads it' {
        $path = Join-Path $TestDrive 'native.json'
        Save-OmniSession -Session $script:Session -Path $path | Should -Be $path
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $raw.PSObject.Properties['schemaVersion'] | Should -BeNullOrEmpty
        $raw.PSObject.Properties['Results'] | Should -Not -BeNullOrEmpty
        (Import-OmniSession -Path $path).Summary.Score | Should -Be $script:Session.Summary.Score
    }

    It 'Save-OmniSession defaults to the sessions data folder' {
        $saved = Save-OmniSession -Session $script:Session
        try {
            $saved | Should -BeLike (Join-Path (Get-OmniDataPath -Kind Sessions) 'session-*.json')
        } finally { Remove-Item -LiteralPath $saved -Force -ErrorAction SilentlyContinue }
    }

    It 'a report package carries a v1 data.json that Import-OmniSession reads' {
        $zip = Join-Path $TestDrive 'pkg.zip'
        Export-OmniReportPackage -Session $script:Session -Path $zip | Out-Null
        $extract = Join-Path $TestDrive 'pkg'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract
        (Get-Content -LiteralPath (Join-Path $extract 'data.json') -Raw | ConvertFrom-Json).schemaVersion | Should -Be '1.0.0'
        $loaded = Import-OmniSession -Path $zip
        $loaded.Summary.Score | Should -Be $script:Session.Summary.Score
        @($loaded.Results).Count | Should -Be 5
    }

    It 'reloaded v1 reports export every format again' {
        $path = Join-Path $TestDrive 'again.json'
        Export-OmniJsonReport -Session $script:Session -Path $path | Out-Null
        $loaded = Import-OmniSession -Path $path
        $set = Export-OmniReport -Session $loaded -OutputDirectory (Join-Path $TestDrive 'again') -Format Html, Json, Csv, Md, Pdf -BaseName 'again'
        @($set.Warnings).Count | Should -Be 0
        foreach ($f in $set.Files) { $f | Should -Exist }
    }
}
