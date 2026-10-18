#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    The Phase 3 omnidiag commands: repair list | repair run (--what-if | --apply [--yes]),
    compare, gui, --elevated-only, --redact, report --bundle and --from-session.

    Fake scanners and fake repairs only; a marker file proves whether a repair action
    ran (acceptance: repair without --apply performs no action). Answers to the --apply
    prompts are fed through a StringReader, so no test ever waits on the console. The
    router's elevation check is switched through its test seam
    ($script:OmniCliElevatedOverride in the Router module). Data goes to TestDrive.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    $script:OldData = $env:OMNIDIAG_DATA
    $env:OMNIDIAG_DATA = Join-Path $TestDrive 'OmniDiagData'
    Get-OmniDataRoot -Refresh | Out-Null

    $script:Router = (Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'Router' } | Select-Object -First 1
    $script:ListSchema = Join-Path $script:Root 'schemas/omnidiag-list.v1.json'
    $script:CanValidate = $PSVersionTable.PSVersion.Major -ge 7
    $script:HasRedaction = [bool](Get-Command New-OmniRedactionContext -ErrorAction SilentlyContinue)
    $script:IsWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

    # --- Fake scanners --------------------------------------------------------
    $script:Plugins = Join-Path $TestDrive 'plugins'
    New-Item -ItemType Directory -Path $script:Plugins -Force | Out-Null
    $fakes = @(
        @{ File = 'CmdWarn.psm1';  Manifest = "Name = 'Cmd Warn'; Category = 'Test'; Group = 'storage'; Order = 1"; Body = "if (`$env:OMNIDIAG_CMD_TOGGLE -eq 'on') { Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'disk filling up' -Severity 'Warning' -Component 'Cmd/Disk') } else { Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'disk fine' -Severity 'Pass' -Component 'Cmd/Disk') }" }
        @{ File = 'CmdAdmin.psm1'; Manifest = "Name = 'Cmd Admin'; Category = 'Test'; Group = 'security'; RequiresAdmin = `$true; Order = 2"; Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'admin ok' -Severity 'Pass')" }
    )
    foreach ($f in $fakes) {
        $text = @"
function Get-OmniModuleManifest { @{ $($f.Manifest) } }
function Invoke-OmniModuleScan {
    param(`$Context)
    `$m = Get-OmniModuleManifest
    `$r = New-OmniResult -ModuleName `$m.Name -Category `$m.Category
    $($f.Body)
    return (Complete-OmniResult -Result `$r)
}
Export-ModuleMember -Function 'Get-OmniModuleManifest', 'Invoke-OmniModuleScan'
"@
        Set-Content -LiteralPath (Join-Path $script:Plugins $f.File) -Value $text -Encoding ascii
    }

    # --- Fake repairs ---------------------------------------------------------
    $script:Repairs = Join-Path $TestDrive 'repairs'
    New-Item -ItemType Directory -Path $script:Repairs -Force | Out-Null
    $script:Marker = Join-Path $TestDrive 'cmd-marker.txt'
    $script:AdminMarker = Join-Path $TestDrive 'cmd-admin-marker.txt'
    $repairs = @(
        @{ File = 'CmdMarker.psm1'; Manifest = "Name = 'Cmd Marker'; Category = 'Test'; Risk = 'Safe'; Order = 1; AppliesTo = @('Cmd/Disk')"
           Body = "Invoke-OmniRepairStep -Result `$r -Context `$Context -Description 'write marker' -Action { Set-Content -LiteralPath '$($script:Marker)' -Value 'ran' -Force } | Out-Null" }
        @{ File = 'CmdReboot.psm1'; Manifest = "Name = 'Cmd Reboot'; Category = 'Test'; Risk = 'Moderate'; RebootHint = `$true; Order = 2"
           Body = "Invoke-OmniRepairStep -Result `$r -Context `$Context -Description 'noop' -Action { 'ok' } | Out-Null; if (-not `$Context.DryRun) { `$r.RebootRequired = `$true }" }
        @{ File = 'CmdFail.psm1'; Manifest = "Name = 'Cmd Fail'; Category = 'Test'; Risk = 'Safe'; Order = 3"
           Body = "Invoke-OmniRepairStep -Result `$r -Context `$Context -Description 'fails' -Action { throw 'boom' } | Out-Null" }
        @{ File = 'CmdAdmin.psm1'; Manifest = "Name = 'Cmd Admin'; Category = 'Test'; Risk = 'Moderate'; RequiresAdmin = `$true; Order = 4"
           Body = "Invoke-OmniRepairStep -Result `$r -Context `$Context -Description 'admin marker' -Action { Set-Content -LiteralPath '$($script:AdminMarker)' -Value 'ran' -Force } | Out-Null" }
    )
    foreach ($f in $repairs) {
        $text = @"
function Get-OmniRepairManifest { @{ $($f.Manifest) } }
function Invoke-OmniRepairAction {
    param(`$Context)
    `$m = Get-OmniRepairManifest
    `$r = New-OmniRepairResult -Name `$m.Name -Category `$m.Category
    $($f.Body)
    return (Complete-OmniRepairResult -Result `$r)
}
Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
"@
        Set-Content -LiteralPath (Join-Path $script:Repairs $f.File) -Value $text -Encoding ascii
    }

    function Invoke-Cli {
        param([string[]] $Arguments, [string] $InputText = '', [switch] $NonInteractive)
        $out = [System.IO.StringWriter]::new()
        $err = [System.IO.StringWriter]::new()
        $p = @{
            Arguments = $Arguments; ModulesPath = @($script:Plugins); RepairsPath = $script:Repairs
            Out = $out; Err = $err; In = [System.IO.StringReader]::new($InputText)
        }
        if ($NonInteractive) { $p.NonInteractive = $true }
        $code = Invoke-OmniDiagCli @p
        return [pscustomobject]@{ Code = $code; Out = $out.ToString(); Err = $err.ToString() }
    }

    function Set-CliElevated {
        param($Value)
        & $script:Router { param($v) $script:OmniCliElevatedOverride = $v } $Value
    }

    function Get-AuditCount {
        $path = Get-OmniRepairAuditPath
        if (-not (Test-Path -LiteralPath $path)) { return 0 }
        return @(Get-Content -LiteralPath $path | Where-Object { $_ }).Count
    }

    # Two saved sessions for compare: 'previous' warns, 'last' does not.
    $env:OMNIDIAG_CMD_TOGGLE = 'on'
    $before = Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group storage -AsSession
    $env:OMNIDIAG_CMD_TOGGLE = $null
    $after = Invoke-OmniDiagScan -ModulesPath $script:Plugins -Group storage -AsSession
    $sessions = Get-OmniDataPath -Kind Sessions
    $script:PreviousPath = Save-OmniSession -Session $before -Path (Join-Path $sessions 'session-20260101-000000.json')
    $script:LastPath = Save-OmniSession -Session $after -Path (Join-Path $sessions 'session-20260102-000000.json')
    (Get-Item -LiteralPath $script:PreviousPath).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-2)
    (Get-Item -LiteralPath $script:LastPath).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-1)
    # A report package of the 'previous' session, for comparing a .zip.
    $script:PreviousZip = @((Export-OmniDiagReport -Session $before -OutputDirectory (Join-Path $TestDrive 'zips') -Format Zip).Files)[0]
}

AfterAll {
    Set-CliElevated $null
    $env:OMNIDIAG_CMD_TOGGLE = $null
    $env:OMNIDIAG_DATA = $script:OldData
    Get-OmniDataRoot -Refresh | Out-Null
}

Describe 'omnidiag repair list' {
    It 'prints a table of repairs' {
        $r = Invoke-Cli -Arguments @('repair', 'list')
        $r.Code | Should -Be 0
        $r.Out | Should -Match '^ID\s+RISK'
        $r.Out | Should -Match 'repair\.cmd-marker\s+Safe'
    }

    It 'emits the list document as JSON (schema omnidiag-list v1)' {
        $r = Invoke-Cli -Arguments @('repair', 'list', '--format', 'json')
        $r.Code | Should -Be 0
        $doc = $r.Out | ConvertFrom-Json
        $doc.kind | Should -Be 'repairs'
        @($doc.items.id) | Should -Be @('repair.cmd-marker', 'repair.cmd-reboot', 'repair.cmd-fail', 'repair.cmd-admin')
        $doc.items[0].PSObject.Properties.Name | Should -Not -Contain 'recommended'
        if ($script:CanValidate) { Test-Json -Json $r.Out -SchemaFile $script:ListSchema | Should -BeTrue }
    }

    It 'marks recommended repairs with --from-session' {
        $r = Invoke-Cli -Arguments @('repair', 'list', '--from-session', 'previous', '--format', 'json', '-q')
        $r.Code | Should -Be 0
        $doc = $r.Out | ConvertFrom-Json
        ($doc.items | Where-Object id -eq 'repair.cmd-marker').recommended | Should -BeTrue
        ($doc.items | Where-Object id -eq 'repair.cmd-reboot').recommended | Should -BeFalse
        if ($script:CanValidate) { Test-Json -Json $r.Out -SchemaFile $script:ListSchema | Should -BeTrue }
        (Invoke-Cli -Arguments @('repair', 'list', '--from-session', 'last')).Out | Should -Match 'RECOMMENDED'
    }

    It 'rejects run-only options and unknown sessions' {
        (Invoke-Cli -Arguments @('repair', 'list', '--apply')).Code | Should -Be 10
        (Invoke-Cli -Arguments @('repair', 'list', '--from-session', (Join-Path $TestDrive 'missing.json'))).Code | Should -Be 10
    }
}

Describe 'omnidiag repair run' {
    BeforeEach {
        Remove-Item -LiteralPath $script:Marker, $script:AdminMarker -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-OmniRepairAuditPath) -Force -ErrorAction SilentlyContinue
        Set-CliElevated $null
    }
    AfterEach { Set-CliElevated $null }

    It 'refuses to run without --what-if or --apply (exit 10) and performs no action' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-marker')
        $r.Code | Should -Be 10
        $r.Err | Should -Match '--what-if'
        $r.Err | Should -Match '--apply'
        Test-Path -LiteralPath $script:Marker | Should -BeFalse
        Get-AuditCount | Should -Be 0
    }

    It '--what-if is a dry run: no action runs and nothing is audited' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-marker', 'repair.cmd-admin', '--what-if')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'DRY RUN'
        $r.Out | Should -Match '\[would\] write marker'
        Test-Path -LiteralPath $script:Marker | Should -BeFalse
        Test-Path -LiteralPath $script:AdminMarker | Should -BeFalse
        Get-AuditCount | Should -Be 0
    }

    It '--apply --yes runs the repair and appends to the audit log' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-marker', '--apply', '--yes')
        $r.Code | Should -Be 0
        Test-Path -LiteralPath $script:Marker | Should -BeTrue
        Get-AuditCount | Should -Be 1
        $entry = Get-Content -LiteralPath (Get-OmniRepairAuditPath) | Select-Object -First 1 | ConvertFrom-Json
        $entry.repairId | Should -Be 'repair.cmd-marker'
        $entry.dryRun | Should -BeFalse
        $r.Err | Should -Match 'Audit log:'
    }

    It '--apply asks per repair and runs only what was confirmed' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-marker', 'cmd-reboot', '--apply') -InputText "y`nn`n"
        $r.Err | Should -Match "Apply repair 'Cmd Marker' \[repair\.cmd-marker\]"
        $r.Err | Should -Match "Apply repair 'Cmd Reboot'"
        Test-Path -LiteralPath $script:Marker | Should -BeTrue
        $r.Code | Should -Be 0 -Because 'the reboot repair was declined'
        $r.Err | Should -Match 'Not applied: repair\.cmd-reboot'
    }

    It '--apply treats no answer as no' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-marker', '--apply') -InputText ''
        $r.Code | Should -Be 0
        Test-Path -LiteralPath $script:Marker | Should -BeFalse
        Get-AuditCount | Should -Be 0
    }

    It 'refuses --apply without --yes when standard input is not interactive' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-marker', '--apply') -InputText "y`n" -NonInteractive
        $r.Code | Should -Be 10
        $r.Err | Should -Match 'not interactive'
        Test-Path -LiteralPath $script:Marker | Should -BeFalse
    }

    It 'exits 12 when a repair needs a reboot' {
        (Invoke-Cli -Arguments @('repair', 'run', 'cmd-reboot', '--apply', '-y')).Code | Should -Be 12
    }

    It 'exits 11 when a repair fails' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'Cmd Fail', '--apply', '--yes')
        $r.Code | Should -Be 11
        $r.Out | Should -Match '\[FAILED\] fails'
    }

    It 'exits 4 when every requested repair needs elevation and the process is not elevated' {
        Set-CliElevated $false
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-admin', '--apply', '--yes')
        $r.Code | Should -Be 4
        $r.Err | Should -Match 'needs elevation'
        Test-Path -LiteralPath $script:AdminMarker | Should -BeFalse
        Get-AuditCount | Should -Be 0
    }

    It 'still describes elevation-only repairs with --what-if when not elevated' {
        Set-CliElevated $false
        (Invoke-Cli -Arguments @('repair', 'run', 'cmd-admin', '--what-if')).Code | Should -Be 0
    }

    It 'passes --allow-without-restore-point through' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-marker', '--apply', '--yes', '--allow-without-restore-point')
        $r.Code | Should -Be 0
        Test-Path -LiteralPath $script:Marker | Should -BeTrue
    }

    It 'writes a repair-run JSON document with --format json' {
        $r = Invoke-Cli -Arguments @('repair', 'run', 'cmd-marker', 'cmd-reboot', '--what-if', '--format', 'json')
        $r.Code | Should -Be 0
        $doc = $r.Out | ConvertFrom-Json
        $doc.kind | Should -Be 'repair-run'
        $doc.dryRun | Should -BeTrue
        @($doc.results.id) | Should -Be @('repair.cmd-marker', 'repair.cmd-reboot')
        @($doc.results.status | Select-Object -Unique) | Should -Be @('DryRun')
        $doc.exitCode | Should -Be 0
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a missing subcommand'; Arguments = @('repair'); Message = 'needs a subcommand' }
        @{ Case = 'an unknown subcommand'; Arguments = @('repair', 'fix'); Message = "unknown repair subcommand 'fix'" }
        @{ Case = 'no repair id'; Arguments = @('repair', 'run', '--what-if'); Message = 'at least one repair id' }
        @{ Case = 'an unknown repair'; Arguments = @('repair', 'run', 'nope', '--what-if'); Message = "unknown repair 'nope'" }
        @{ Case = 'both modes'; Arguments = @('repair', 'run', 'cmd-marker', '--what-if', '--apply'); Message = 'either --what-if or --apply' }
        @{ Case = '--yes without --apply'; Arguments = @('repair', 'run', 'cmd-marker', '--what-if', '--yes'); Message = '--yes only applies with --apply' }
        @{ Case = 'a non-JSON format'; Arguments = @('repair', 'run', 'cmd-marker', '--what-if', '--format', 'csv'); Message = 'json only' }
        @{ Case = 'a repair option on scan'; Arguments = @('scan', '--apply'); Message = "does not apply to 'scan'" }
    ) {
        $r = Invoke-Cli -Arguments $Arguments
        $r.Code | Should -Be 10
        $r.Err | Should -BeLike "*$Message*"
        Test-Path -LiteralPath $script:Marker | Should -BeFalse
    }
}

Describe 'omnidiag compare' {
    It 'compares previous with last as text' {
        $r = Invoke-Cli -Arguments @('compare', 'previous', 'last')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'OmniDiag comparison: Improved'
        $r.Out | Should -Match 'Resolved \(1\)'
        $r.Out | Should -Match 'disk filling up'
    }

    It 'emits a comparison document with --format json' {
        $r = Invoke-Cli -Arguments @('compare', $script:PreviousPath, $script:LastPath, '--format', 'json')
        $r.Code | Should -Be 0
        $doc = $r.Out | ConvertFrom-Json
        $doc.kind | Should -Be 'comparison'
        $doc.verdict | Should -Be 'Improved'
        $doc.counts.resolved | Should -Be 1
        $doc.before.path | Should -Be $script:PreviousPath
    }

    It 'exits 0 for a regression too (the verdict is in the output)' {
        $r = Invoke-Cli -Arguments @('compare', 'last', 'previous', '--format', 'json')
        $r.Code | Should -Be 0
        ($r.Out | ConvertFrom-Json).verdict | Should -Be 'Regressed'
    }

    It 'reads a report .zip and writes Markdown to --output' {
        $file = Join-Path $TestDrive 'cmp.md'
        $r = Invoke-Cli -Arguments @('compare', $script:PreviousZip, 'last', '--output', $file)
        $r.Code | Should -Be 0
        Get-Content -LiteralPath $file -Raw | Should -Match '# OmniDiag comparison: Improved'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'one session'; Arguments = @('compare', 'last'); Message = 'needs two sessions' }
        @{ Case = 'a missing file'; Arguments = @('compare', 'last', 'C:\nope\missing.json'); Message = 'cannot read session' }
        @{ Case = 'csv'; Arguments = @('compare', 'previous', 'last', '--format', 'csv'); Message = 'compare supports --format' }
    ) {
        $r = Invoke-Cli -Arguments $Arguments
        $r.Code | Should -Be 10
        $r.Err | Should -BeLike "*$Message*"
    }
}

Describe 'omnidiag gui' {
    It 'exits 10 on a non-Windows host' {
        if ($script:IsWindowsHost) { Set-ItResult -Skipped -Because 'this is Windows (the window would open)'; return }
        $r = Invoke-Cli -Arguments @('gui')
        $r.Code | Should -Be 10
        $r.Err | Should -Match 'needs Windows'
    }

    It 'takes no arguments' {
        (Invoke-Cli -Arguments @('gui', 'now')).Code | Should -Be 10
        (Invoke-Cli -Arguments @('gui', '--format', 'json')).Code | Should -Be 10
    }
}

Describe '--elevated-only' {
    AfterEach { Set-CliElevated $null }

    It 'exits 4 with a message when the process is not elevated' {
        Set-CliElevated $false
        $r = Invoke-Cli -Arguments @('scan', '--elevated-only', '--format', 'json')
        $r.Code | Should -Be 4
        $r.Err | Should -Match 'not elevated'
        $r.Out | Should -BeNullOrEmpty
        (Invoke-Cli -Arguments @('storage', '--elevated-only')).Code | Should -Be 4
        (Invoke-Cli -Arguments @('report', '--elevated-only', '--output', (Join-Path $TestDrive 'eo'))).Code | Should -Be 4
    }

    It 'runs only the scanners that need elevation when elevated' {
        Set-CliElevated $true
        $r = Invoke-Cli -Arguments @('scan', '--elevated-only', '--format', 'json', '-q')
        $doc = $r.Out | ConvertFrom-Json
        @($doc.modules.id) | Should -Be @('security.cmd-admin')
        $doc.options.elevatedOnly | Should -BeTrue
    }

    It 'is a usage error when no selected scanner needs elevation' {
        Set-CliElevated $true
        $r = Invoke-Cli -Arguments @('storage', '--elevated-only')
        $r.Code | Should -Be 10
        $r.Err | Should -Match 'requires elevation'
    }

    It 'does not apply to list' {
        (Invoke-Cli -Arguments @('list', '--elevated-only')).Code | Should -Be 10
    }
}

Describe 'omnidiag report --bundle / --from-session' {
    It 'writes a .zip report package next to the HTML and JSON' {
        $dir = Join-Path $TestDrive 'bundle'
        $r = Invoke-Cli -Arguments @('report', '--output', $dir, '--bundle', '-q')
        @(Get-ChildItem -LiteralPath $dir -Filter '*.zip').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $dir -Filter '*.html').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $dir -Filter '*.json').Count | Should -Be 1
        $r.Out | Should -Match '\.zip'
    }

    It 'exports a saved session without scanning' {
        $dir = Join-Path $TestDrive 'from-session'
        $r = Invoke-Cli -Arguments @('report', '--from-session', $script:PreviousPath, '--output', $dir, '--format', 'json')
        $r.Code | Should -Be 1 -Because 'that saved session has a warning'
        $doc = Get-Content -LiteralPath @(Get-ChildItem -LiteralPath $dir -Filter '*.json')[0].FullName -Raw | ConvertFrom-Json
        $doc.options.fromSession | Should -BeTrue
        $r.Err | Should -Match 'Loaded saved session'
    }

    It 'rejects --from-session with scan-only options' {
        (Invoke-Cli -Arguments @('report', '--from-session', 'last', '--network-probes')).Code | Should -Be 10
        (Invoke-Cli -Arguments @('scan', '--from-session', 'last')).Code | Should -Be 10
    }
}

Describe '--redact' {
    It 'fails clearly (exit 20) when the redaction module is missing' {
        if ($script:HasRedaction) { Set-ItResult -Skipped -Because 'the redaction module is present'; return }
        $r = Invoke-Cli -Arguments @('scan', '--group', 'storage', '--redact', '--format', 'json')
        $r.Code | Should -Be 20
        $r.Err | Should -Match 'redact'
        $r.Out | Should -BeNullOrEmpty
    }

    It 'keeps the computer name out of JSON on stdout' {
        if (-not $script:HasRedaction) { Set-ItResult -Skipped -Because 'New-OmniRedactionContext is not available in this build'; return }
        $r = Invoke-Cli -Arguments @('scan', '--group', 'storage', '--redact', '--format', 'json', '-q')
        $r.Out | Should -Not -Match ([regex]::Escape([System.Environment]::MachineName))
        ($r.Out | ConvertFrom-Json).options.redacted | Should -BeTrue
    }

    It 'keeps the computer name out of the report files and file names' {
        if (-not $script:HasRedaction) { Set-ItResult -Skipped -Because 'New-OmniRedactionContext is not available in this build'; return }
        $dir = Join-Path $TestDrive 'redacted-report'
        Invoke-Cli -Arguments @('report', '--output', $dir, '--redact', '--bundle', '-q') | Out-Null
        $name = [regex]::Escape([System.Environment]::MachineName)
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File)) {
            $f.Name | Should -Not -Match $name
            if ($f.Extension -in @('.json', '.html')) { Get-Content -LiteralPath $f.FullName -Raw | Should -Not -Match $name }
        }
    }

    It 'needs --redact for --redaction-map' {
        (Invoke-Cli -Arguments @('scan', '--redaction-map', (Join-Path $TestDrive 'map.json'))).Code | Should -Be 10
    }
}
