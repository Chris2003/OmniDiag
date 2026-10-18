#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    The omnidiag CLI router (Invoke-OmniDiagCli) and the exit-code helpers.

    Commands run for real against a temporary plugin folder of fake scanners (Pass,
    Warning, Error, a throwing one, an admin-only one, and one that declares Internet
    access), so every assertion is OS-independent. stdout and stderr are captured with
    StringWriters; a few cases start a child PowerShell process to prove the exit code
    reaches the shell. All data (sessions, logs, reports) goes to a TestDrive folder.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    $script:OldData = $env:OMNIDIAG_DATA
    $env:OMNIDIAG_DATA = Join-Path $TestDrive 'OmniDiagData'
    Get-OmniDataRoot -Refresh | Out-Null

    $script:ReportSchema = Join-Path $script:Root 'schemas/omnidiag-report.v1.json'
    $script:ListSchema = Join-Path $script:Root 'schemas/omnidiag-list.v1.json'
    $script:CanValidate = $PSVersionTable.PSVersion.Major -ge 7
    $script:IsAdmin = Test-OmniIsAdministrator

    # --- Fake scanner plugins -------------------------------------------------
    $script:Plugins = Join-Path $TestDrive 'plugins'
    New-Item -ItemType Directory -Path $script:Plugins -Force | Out-Null
    $fakes = @(
        @{ File = 'FakePass.psm1';  Manifest = "Name = 'Fake Pass'; Category = 'Test'; Group = 'system'; Order = 1";  Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'all good' -Severity 'Pass')" }
        @{ File = 'FakeWarn.psm1';  Manifest = "Name = 'Fake Warn'; Category = 'Test'; Group = 'storage'; Order = 2"; Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'disk filling up' -Severity 'Warning' -Recommendation 'Clean up.')" }
        @{ File = 'FakeCrit.psm1';  Manifest = "Name = 'Fake Crit'; Category = 'Test'; Group = 'security'; Order = 3"; Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'firewall off' -Severity 'Error')" }
        @{ File = 'FakeThrow.psm1'; Manifest = "Name = 'Fake Throw'; Category = 'Test'; Group = 'extras'; Order = 4";  Body = "throw 'intentional failure'" }
        @{ File = 'FakeAdmin.psm1'; Manifest = "Name = 'Fake Admin'; Category = 'Test'; Group = 'extras'; RequiresAdmin = `$true; Order = 5"; Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'admin ok' -Severity 'Pass')" }
        @{ File = 'FakeNet.psm1';   Manifest = "Name = 'Fake Net'; Category = 'Test'; Group = 'network'; NetworkAccess = 'Internet'; Order = 6"; Body = "if (Test-OmniNetworkProbeEnabled -Context `$Context) { Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'reachable' -Severity 'Pass') } else { Add-OmniFinding -Result `$r -Finding (New-OmniProbeSkippedFinding -Component 'Network/Test' -Probe 'ping the test target') }" }
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

    function Invoke-Cli {
        param([string[]] $Arguments, [string[]] $ModulesPath = @($script:Plugins))
        $out = [System.IO.StringWriter]::new()
        $err = [System.IO.StringWriter]::new()
        $code = Invoke-OmniDiagCli -Arguments $Arguments -ModulesPath $ModulesPath -Out $out -Err $err
        return [pscustomobject]@{ Code = $code; Out = $out.ToString(); Err = $err.ToString() }
    }

    function New-SyntheticSession {
        param([string[]] $Severity = @(), [string] $Status, [switch] $Cancelled, [switch] $AdminSkip)
        $r = New-OmniResult -ModuleName 'Synthetic' -Category 'Test' -RequiresAdmin ([bool]$AdminSkip)
        foreach ($s in $Severity) { Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title "f-$s" -Severity $s) }
        if ($Status) { Complete-OmniResult -Result $r -Status $Status | Out-Null } else { Complete-OmniResult -Result $r | Out-Null }
        if ($AdminSkip) { Add-Member -InputObject $r -MemberType NoteProperty -Name SkippedReason -Value 'RequiresElevation' }
        [pscustomobject]@{ Results = @($r); Cancelled = [bool]$Cancelled; Summary = $null }
    }

    $script:PwshExe = (Get-Process -Id $PID).Path
    $script:CliScript = Join-Path $script:Root 'src/Cli/omnidiag.ps1'
}

AfterAll {
    $env:OMNIDIAG_DATA = $script:OldData
    Get-OmniDataRoot -Refresh | Out-Null
}

Describe 'Exit-code table and derivation' {
    It 'publishes every documented code' {
        @(Get-OmniExitCodeTable).Code | Should -Be @(0, 1, 2, 3, 4, 5, 10, 11, 12, 20)
        Get-OmniExitCodeValue -Name 'Usage' | Should -Be 10
    }

    It 'derives <Expected> for <Case>' -ForEach @(
        @{ Case = 'pass and information only'; Expected = 0; Severity = @('Pass', 'Information') }
        @{ Case = 'a warning'; Expected = 1; Severity = @('Pass', 'Warning') }
        @{ Case = 'an error'; Expected = 2; Severity = @('Warning', 'Error') }
        @{ Case = 'a critical finding'; Expected = 2; Severity = @('Critical') }
    ) {
        Get-OmniExitCode -Session (New-SyntheticSession -Severity $Severity) | Should -Be $Expected
    }

    It 'derives 3 when a module failed' {
        Get-OmniExitCode -Session (New-SyntheticSession -Severity @('Error') -Status 'Failed') | Should -Be 3
    }

    It 'derives 5 for a cancelled session, ahead of everything else' {
        Get-OmniExitCode -Session (New-SyntheticSession -Severity @('Critical') -Status 'Failed' -Cancelled) | Should -Be 5
    }

    It 'derives 4 only when explicitly requested modules were all skipped for elevation' {
        $s = New-SyntheticSession -Severity @('Information') -Status 'Skipped' -AdminSkip
        Get-OmniExitCode -Session $s -ExplicitSelection | Should -Be 4
        Get-OmniExitCode -Session $s -RequestedElevation | Should -Be 4
        Get-OmniExitCode -Session $s | Should -Be 0
    }

    It 'maps repair outcomes to 11 / 12 / 0' {
        $failed = [pscustomobject]@{ Results = @([pscustomobject]@{ Status = 'Failed' }, [pscustomobject]@{ Status = 'Succeeded' }); RebootRequired = $true }
        $reboot = [pscustomobject]@{ Results = @([pscustomobject]@{ Status = 'RebootRequired' }); RebootRequired = $true }
        $ok = [pscustomobject]@{ Results = @([pscustomobject]@{ Status = 'Succeeded' }); RebootRequired = $false }
        Get-OmniRepairExitCode -RepairSession $failed | Should -Be 11
        Get-OmniRepairExitCode -RepairSession $reboot | Should -Be 12
        Get-OmniRepairExitCode -RepairSession $ok | Should -Be 0
        Get-OmniRepairExitCode -RepairSession $null | Should -Be 0
    }
}

Describe 'omnidiag help / version' {
    It 'prints usage on stdout for help and --help' {
        foreach ($a in @(, @('help')) + @(, @('--help')) + @(, @('-h'))) {
            $r = Invoke-Cli -Arguments $a
            $r.Code | Should -Be 0
            $r.Out | Should -Match 'Usage: omnidiag <command>'
            $r.Err | Should -BeNullOrEmpty
        }
    }

    It 'prints command help' {
        $r = Invoke-Cli -Arguments @('help', 'scan')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'Usage: omnidiag scan'
        $r.Out | Should -Match '--network-probes'
        (Invoke-Cli -Arguments @('report', '--help')).Out | Should -Match 'Usage: omnidiag report'
    }

    It 'prints group help for help <group> and <group> --help' {
        (Invoke-Cli -Arguments @('help', 'network')).Out | Should -Match 'Usage: omnidiag network'
        $r = Invoke-Cli -Arguments @('storage', '--help')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'Usage: omnidiag storage'
        $r.Out | Should -Match 'scan --group storage'
    }

    It 'prints the version, as text or JSON' {
        $r = Invoke-Cli -Arguments @('version')
        $r.Code | Should -Be 0
        $r.Out.Trim() | Should -Be "OmniDiag $(Get-OmniVersion)"
        $j = (Invoke-Cli -Arguments @('--version', '--format', 'json')).Out | ConvertFrom-Json
        $j.kind | Should -Be 'version'
        $j.tool.version | Should -Be ([string](Get-OmniVersion))
        $j.reportSchemaVersion | Should -Be '1.0.0'
    }
}

Describe 'Usage errors exit 10 with usage on stderr' {
    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unknown option'; Arguments = @('scan', '--bogus'); Message = "unknown option '--bogus'" }
        @{ Case = 'an unknown short option'; Arguments = @('list', '-z'); Message = "unknown option '-z'" }
        @{ Case = 'an unknown command'; Arguments = @('frobnicate'); Message = "unknown command 'frobnicate'" }
        @{ Case = 'no command'; Arguments = @(); Message = 'no command given' }
        @{ Case = 'a missing option value'; Arguments = @('scan', '--format'); Message = 'requires a value' }
        @{ Case = 'a value on a flag'; Arguments = @('scan', '--quiet=yes'); Message = 'does not take a value' }
        @{ Case = 'an option for another command'; Arguments = @('list', '--group', 'system'); Message = "does not apply to 'list'" }
        @{ Case = 'an unknown format'; Arguments = @('scan', '--format', 'xml'); Message = "unknown format 'xml'" }
        @{ Case = 'an unknown list kind'; Arguments = @('list', 'widgets'); Message = "unknown list kind 'widgets'" }
        @{ Case = 'a list format that is not data'; Arguments = @('list', '--format', 'html'); Message = 'list supports' }
        @{ Case = 'an unknown group'; Arguments = @('scan', '--group', 'gaming'); Message = "unknown group 'gaming'" }
        @{ Case = 'an unknown module'; Arguments = @('scan', '--module', 'nope.nothing'); Message = "unknown module 'nope.nothing'" }
        @{ Case = 'profile with workflow'; Arguments = @('scan', '--profile', 'HelpDesk', '--workflow', 'QuickTriage'); Message = 'either --profile or --workflow' }
        @{ Case = 'an unknown profile'; Arguments = @('scan', '--profile', 'Wizard'); Message = "Unknown role profile 'Wizard'" }
        @{ Case = 'several stdout formats'; Arguments = @('scan', '--format', 'json,csv'); Message = 'only one --format' }
        @{ Case = 'an unknown range'; Arguments = @('scan', '--range', 'forever'); Message = "unknown range 'forever'" }
        @{ Case = 'an unexpected argument'; Arguments = @('version', 'extra'); Message = "unexpected argument 'extra'" }
    ) {
        $r = Invoke-Cli -Arguments $Arguments
        $r.Code | Should -Be 10
        $r.Err | Should -BeLike "*$Message*"
        $r.Err | Should -Match 'Usage: omnidiag'
        $r.Out | Should -BeNullOrEmpty
    }
}

Describe 'omnidiag list' {
    It 'prints a human table of the plugins by default' {
        $r = Invoke-Cli -Arguments @('list')
        $r.Code | Should -Be 0
        $r.Out | Should -Match '^ID\s+GROUP'
        $r.Out | Should -Match 'system\.fake-pass'
        $r.Out | Should -Match 'network\.fake-net\s+network\s+Internet'
    }

    It 'emits a versioned JSON document that validates against the list schema (<Kind>)' -ForEach @(
        @{ Kind = 'modules' }, @{ Kind = 'groups' }, @{ Kind = 'repairs' }, @{ Kind = 'plans' }
    ) {
        $r = Invoke-Cli -Arguments @('list', $Kind, '--format', 'json') -ModulesPath @(Join-Path $script:Root 'src/Modules')
        $r.Code | Should -Be 0
        $doc = $r.Out | ConvertFrom-Json
        $doc.schemaVersion | Should -Be '1.0.0'
        $doc.kind | Should -Be $Kind
        @($doc.items).Count | Should -BeGreaterThan 0
        if ($script:CanValidate) { Test-Json -Json $r.Out -SchemaFile $script:ListSchema | Should -BeTrue }
    }

    It 'lists every built-in scanner with ids and network access' {
        $doc = (Invoke-Cli -Arguments @('list', 'modules', '-f', 'json') -ModulesPath @(Join-Path $script:Root 'src/Modules')).Out | ConvertFrom-Json
        # One scanner per plugin file, so new scanners don't need this test edited.
        @($doc.items).Count | Should -Be @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'src/Modules') -Filter '*.psm1').Count
        ($doc.items | Where-Object id -eq 'network.dns-resolver').networkAccess | Should -Be 'Internet'
    }

    It 'emits CSV and Markdown' {
        $csv = (Invoke-Cli -Arguments @('list', 'groups', '--format=csv')).Out | ConvertFrom-Csv
        ($csv | Where-Object id -eq 'storage').moduleCount | Should -Be '1'
        (Invoke-Cli -Arguments @('list', 'groups', '--format', 'md')).Out | Should -Match '\| id \| name \| moduleCount \|'
    }

    It 'writes to --output instead of stdout' {
        $path = Join-Path $TestDrive 'modules.json'
        $r = Invoke-Cli -Arguments @('list', '--output', $path)
        $r.Code | Should -Be 0
        $r.Out | Should -BeNullOrEmpty
        $r.Err | Should -Match 'Wrote'
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).kind | Should -Be 'modules'
    }
}

Describe 'omnidiag scan' {
    It 'emits a schema v1 report on stdout with --format json and status on stderr' {
        $r = Invoke-Cli -Arguments @('scan', '--module', 'system.fake-pass', '--format', 'json')
        $r.Code | Should -Be 0
        $doc = $r.Out | ConvertFrom-Json
        $doc.schemaVersion | Should -Be '1.0.0'
        @($doc.modules).Count | Should -Be 1
        $doc.modules[0].id | Should -Be 'system.fake-pass'
        $doc.options.modules | Should -Be @('system.fake-pass')
        $r.Err | Should -Match 'Running 1 scanner'
        if ($script:CanValidate) { Test-Json -Json $r.Out -SchemaFile $script:ReportSchema | Should -BeTrue }
    }

    It 'keeps stderr silent with --quiet' {
        $r = Invoke-Cli -Arguments @('scan', '--module', 'system.fake-pass', '--format', 'json', '--quiet')
        $r.Code | Should -Be 0
        $r.Err | Should -BeNullOrEmpty
        { $r.Out | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'exits <Expected> for --module <Module>' -ForEach @(
        @{ Module = 'system.fake-pass'; Expected = 0 }
        @{ Module = 'storage.fake-warn'; Expected = 1 }
        @{ Module = 'security.fake-crit'; Expected = 2 }
        @{ Module = 'extras.fake-throw'; Expected = 3 }
    ) {
        (Invoke-Cli -Arguments @('scan', '--module', $Module, '-q')).Code | Should -Be $Expected
    }

    It 'exits 4 when every requested module needs elevation' {
        if ($script:IsAdmin) { Set-ItResult -Skipped -Because 'the test host is elevated'; return }
        $r = Invoke-Cli -Arguments @('scan', '--module', 'extras.fake-admin', '--format', 'json')
        $r.Code | Should -Be 4
        ($r.Out | ConvertFrom-Json).modules[0].skippedReason | Should -Be 'RequiresElevation'
    }

    It 'combines groups and modules, and accepts module names' {
        $doc = (Invoke-Cli -Arguments @('scan', '--group', 'storage', '--module', 'Fake Pass', '-f', 'json', '-q')).Out | ConvertFrom-Json
        @($doc.modules.id) | Should -Be @('system.fake-pass', 'storage.fake-warn')
    }

    It 'runs network-capable scanners by default with connectivity probes off' {
        $r = Invoke-Cli -Arguments @('scan', '--format', 'json')
        $doc = $r.Out | ConvertFrom-Json
        @($doc.modules.id) | Should -Contain 'network.fake-net'
        @($doc.modules).Count | Should -Be 6
        $net = $doc.modules | Where-Object id -eq 'network.fake-net'
        @($net.findings.title) | Should -Be @('Connectivity probe not run')
        $net.findings[0].severity | Should -Be 'Info'
        $net.findings[0].recommendation | Should -Match '--network-probes'
        $r.Err | Should -Match 'Connectivity probes are off \(network\.fake-net\)'
        $doc.options.PSObject.Properties.Name | Should -Not -Contain 'networkProbes'
        $r.Code | Should -Be 3

        $grp = Invoke-Cli -Arguments @('scan', '--group', 'network', '-f', 'json', '-q')
        $grp.Code | Should -Be 0
        @(($grp.Out | ConvertFrom-Json).modules.id) | Should -Be @('network.fake-net')
    }

    It 'runs connectivity probes with --network-probes and records the option' {
        $r = Invoke-Cli -Arguments @('scan', '--group', 'network', '--network-probes', '-f', 'json')
        $r.Code | Should -Be 0
        $doc = $r.Out | ConvertFrom-Json
        @($doc.modules[0].findings.title) | Should -Be @('reachable')
        $doc.options.networkProbes | Should -BeTrue
        $r.Err | Should -Match 'with connectivity probes'
        $r.Err | Should -Not -Match 'Connectivity probes are off'
    }

    It 'treats omnidiag <group> as scan --group <group>' {
        $r = Invoke-Cli -Arguments @('storage', '--format', 'json', '-q')
        $r.Code | Should -Be 1
        $doc = $r.Out | ConvertFrom-Json
        @($doc.modules.id) | Should -Be @('storage.fake-warn')
        @($doc.options.groups) | Should -Be @('storage')
        $doc.options.command | Should -Be 'scan'

        $net = Invoke-Cli -Arguments @('network', '--network-probes', '--format', 'json', '-q')
        $net.Code | Should -Be 0
        $ndoc = $net.Out | ConvertFrom-Json
        @($ndoc.modules[0].findings.title) | Should -Be @('reachable')
        $ndoc.options.networkProbes | Should -BeTrue

        $both = (Invoke-Cli -Arguments @('system', '--module', 'storage.fake-warn', '-f', 'json', '-q')).Out | ConvertFrom-Json
        @($both.modules.id) | Should -Be @('system.fake-pass', 'storage.fake-warn')
    }

    It 'rejects --network-probes where it does not apply' {
        $r = Invoke-Cli -Arguments @('list', '--network-probes')
        $r.Code | Should -Be 10
        $r.Err | Should -Match "does not apply to 'list'"
    }

    It 'prints a human summary on stdout without --format' {
        $r = Invoke-Cli -Arguments @('scan', '--module', 'storage.fake-warn')
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'health score'
        $r.Out | Should -Match '\[Warning\] disk filling up \(storage\.fake-warn\)'
    }

    It 'emits CSV and Markdown on stdout' {
        $csv = (Invoke-Cli -Arguments @('scan', '--module', 'storage.fake-warn', '--format', 'csv', '-q')).Out | ConvertFrom-Csv
        $csv[0].Title | Should -Be 'disk filling up'
        (Invoke-Cli -Arguments @('scan', '--module', 'storage.fake-warn', '--format', 'md', '-q')).Out | Should -Match '^# OmniDiag Report'
    }

    It 'writes the file named by --output and keeps data off stdout' {
        $path = Join-Path $TestDrive 'scan.json'
        $r = Invoke-Cli -Arguments @('scan', '--module', 'storage.fake-warn', '--format', 'json', '--output', $path)
        $r.Code | Should -Be 1
        $r.Out.Trim() | Should -Be $path
        $r.Out | Should -Not -Match '\{'
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).modules[0].id | Should -Be 'storage.fake-warn'
    }

    It 'infers the format from the --output extension' {
        $path = Join-Path $TestDrive 'scan.md'
        (Invoke-Cli -Arguments @('scan', '--module', 'system.fake-pass', '-o', $path, '-q')).Code | Should -Be 0
        Get-Content -LiteralPath $path -Raw | Should -Match '# OmniDiag Report'
    }

    It 'writes several formats into an --output directory' {
        $dir = Join-Path $TestDrive 'multi'
        $r = Invoke-Cli -Arguments @('scan', '--module', 'system.fake-pass', '--format', 'json,md,csv', '--output', $dir, '-q')
        $r.Code | Should -Be 0
        @(Get-ChildItem -LiteralPath $dir -Filter '*.json').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $dir -Filter '*.md').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $dir -Filter '*.findings.csv').Count | Should -Be 1
    }

    It 'saves the native session and honors --verbose in the local log' {
        $r = Invoke-Cli -Arguments @('scan', '--module', 'system.fake-pass', '--verbose')
        $r.Err | Should -Match 'Session saved to'
        $logPath = ([regex]::Match($r.Err, 'Log: (.+)')).Groups[1].Value.Trim()
        $logPath | Should -Exist
        @(Get-Content -LiteralPath $logPath | ConvertFrom-Json | Where-Object Level -eq 'Debug').Count | Should -BeGreaterThan 0
        $quietLog = ([regex]::Match((Invoke-Cli -Arguments @('scan', '--module', 'system.fake-pass')).Err, 'Log: (.+)')).Groups[1].Value.Trim()
        @(Get-Content -LiteralPath $quietLog | ConvertFrom-Json | Where-Object Level -eq 'Debug').Count | Should -Be 0
    }
}

Describe 'omnidiag report' {
    It 'writes HTML + JSON v1 for every scanner (probes off)' {
        $dir = Join-Path $TestDrive 'report'
        $r = Invoke-Cli -Arguments @('report', '--output', $dir)
        $r.Code | Should -Be 3
        $json = @(Get-ChildItem -LiteralPath $dir -Filter '*.json')
        $html = @(Get-ChildItem -LiteralPath $dir -Filter '*.html')
        $json.Count | Should -Be 1
        $html.Count | Should -Be 1
        $r.Out | Should -Match ([regex]::Escape($json[0].FullName))
        $doc = Get-Content -LiteralPath $json[0].FullName -Raw | ConvertFrom-Json
        $doc.options.command | Should -Be 'report'
        @($doc.modules.id) | Should -Contain 'network.fake-net'
        @(($doc.modules | Where-Object id -eq 'network.fake-net').findings.title) | Should -Be @('Connectivity probe not run')
        if ($script:CanValidate) { Test-Json -Json (Get-Content -LiteralPath $json[0].FullName -Raw) -SchemaFile $script:ReportSchema | Should -BeTrue }
    }

    It 'defaults to the reports data folder' {
        $r = Invoke-Cli -Arguments @('report', '-q')
        $r.Out | Should -Match ([regex]::Escape((Get-OmniDataPath -Kind Reports)))
    }

    It 'refuses a file as the output directory' {
        $file = Join-Path $TestDrive 'not-a-dir.txt'
        Set-Content -LiteralPath $file -Value 'x'
        (Invoke-Cli -Arguments @('report', '--output', $file)).Code | Should -Be 10
    }
}

Describe 'Exit codes reach the shell (child process)' {
    It 'omnidiag.ps1 returns 0 with clean JSON on stdout' {
        $out = & $script:PwshExe -NoProfile -File $script:CliScript list groups --format json 2>$null
        $LASTEXITCODE | Should -Be 0
        (($out -join "`n") | ConvertFrom-Json).kind | Should -Be 'groups'
    }

    It 'omnidiag.ps1 returns 10 for an unknown option' {
        # Windows PowerShell 5.1 turns a child's stderr into an error record even with 2>$null;
        # the usage message on stderr is expected here, so don't let it stop the test.
        $ErrorActionPreference = 'Continue'
        & $script:PwshExe -NoProfile -File $script:CliScript scan --bogus 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 10
    }

    It 'OmniDiag.ps1 returns 10 for conflicting selections' {
        # Windows PowerShell 5.1 turns a child's stderr into an error record even with 2>$null;
        # the usage message on stderr is expected here, so don't let it stop the test.
        $ErrorActionPreference = 'Continue'
        & $script:PwshExe -NoProfile -File (Join-Path $script:Root 'OmniDiag.ps1') -Profile HelpDesk -Workflow QuickTriage 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 10
    }
}
