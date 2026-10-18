#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Phase 1 acceptance checks that the unit-level suites leave open (docs/ROADMAP.md):

    * Contract: discovering the built-in plugin folders logs no contract violation and
      drops no file. The registry keeps the first of two plugins with the same Id and
      only logs the second, so a count or uniqueness check over the registrations alone
      would miss a duplicate added later in file order.
    * Exit codes: 5, 11, 12, and 20 produced by the real engine / repair engine / router
      (the router tests derive them from synthetic objects or not at all), and the
      docs/CLI.md table kept in sync with Get-OmniExitCodeTable.
    * 'omnidiag scan --format json' over the real built-in scanners validates against the
      v1 schema (Test-Json: PowerShell 7 only), in process and through a child process
      whose stdout must be one clean JSON document; --verbose writes Debug records to the
      local log under OMNIDIAG_DATA and nothing extra to stdout.

    Cross-platform: on a non-Windows host most built-in scanners fail or skip, which
    still has to produce a valid v1 document. All data goes to a TestDrive folder.
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
    $script:PwshExe = (Get-Process -Id $PID).Path
    $script:CliScript = Join-Path $script:Root 'src/Cli/omnidiag.ps1'

    function Get-DiscoveryProblem {
        # Contract problems in one plugin folder: logged load/contract errors, plugin
        # files that produced no registration, and registrations missing Id / Group /
        # NetworkAccess.
        param([string] $Folder, [ValidateSet('Module', 'Repair')] [string] $Kind)
        $log = New-OmniLogger -MinimumLevel Error
        $regs = @(if ($Kind -eq 'Module') { Get-OmniModule -Path $Folder -Logger $log } else { Get-OmniRepair -Path $Folder -Logger $log })
        $files = @(Get-ChildItem -LiteralPath $Folder -Filter '*.psm1' -File | Where-Object { $_.Name -notlike '*.Tests.psm1' })
        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($e in @($log.Buffer | Where-Object { $_.Level -eq 'Error' })) { $problems.Add("logged: $($e.Message)") }
        if ($regs.Count -ne $files.Count) { $problems.Add("$($files.Count) plugin file(s) but $($regs.Count) registration(s)") }
        foreach ($r in $regs) {
            if (-not $r.Id) { $problems.Add("$($r.Name): no Id") }
            if (-not $r.NetworkAccess) { $problems.Add("$($r.Name): no NetworkAccess") }
            if ($Kind -eq 'Module' -and -not $r.Group) { $problems.Add("$($r.Name): no Group") }
        }
        return @($problems)
    }

    function New-TestScanner {
        param([string] $Folder, [string] $File, [string] $ManifestBody)
        $text = @"
function Get-OmniModuleManifest { @{ $ManifestBody } }
function Invoke-OmniModuleScan {
    param(`$Context)
    `$m = Get-OmniModuleManifest
    `$r = New-OmniResult -ModuleName `$m.Name -Category `$m.Category
    Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'ok' -Severity 'Pass')
    return (Complete-OmniResult -Result `$r)
}
Export-ModuleMember -Function 'Get-OmniModuleManifest', 'Invoke-OmniModuleScan'
"@
        Set-Content -LiteralPath (Join-Path $Folder $File) -Value $text -Encoding ascii
    }

    function New-TestRepair {
        param([string] $Folder, [string] $File, [string] $Name, [string] $Body)
        $text = @"
function Get-OmniRepairManifest { @{ Name = '$Name'; Category = 'Test'; Risk = 'Safe'; RequiresAdmin = `$false; Order = 1 } }
function Invoke-OmniRepairAction {
    param(`$Context)
    `$r = New-OmniRepairResult -Name '$Name' -Category 'Test'
    $Body
    return (Complete-OmniRepairResult -Result `$r)
}
Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
"@
        Set-Content -LiteralPath (Join-Path $Folder $File) -Value $text -Encoding ascii
    }

    function Get-ChildCliResult {
        # Runs src/Cli/omnidiag.ps1 in a child PowerShell and captures the raw stdout and
        # stderr text separately (no PowerShell stream wrapping, same on 5.1 and 7).
        # The child inherits this process's environment, including OMNIDIAG_DATA.
        param([string[]] $Arguments)
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshExe
        $psi.Arguments = ('-NoProfile -NonInteractive -File "{0}" {1}' -f $script:CliScript, ($Arguments -join ' '))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
    }
}

AfterAll {
    $env:OMNIDIAG_DATA = $script:OldData
    Get-OmniDataRoot -Refresh | Out-Null
}

Describe 'Contract: built-in discovery is clean' {
    It 'loads every scanner file with a unique Id, a Group, and a NetworkAccess value' {
        $problems = @(Get-DiscoveryProblem -Folder (Join-Path $script:Root 'src/Modules') -Kind Module)
        $problems | Should -BeNullOrEmpty -Because ($problems -join '; ')
    }

    It 'loads every repair file with a unique Id and a NetworkAccess value' {
        $problems = @(Get-DiscoveryProblem -Folder (Join-Path $script:Root 'src/Repairs') -Kind Repair)
        $problems | Should -BeNullOrEmpty -Because ($problems -join '; ')
    }

    It 'catches a duplicate Id that the registry silently drops (mutation check)' {
        $dir = Join-Path $TestDrive 'dup-plugins'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        New-TestScanner -Folder $dir -File 'P1AccFirst.psm1' -ManifestBody "Name = 'Acc First'; Category = 'Custom'; Id = 'extras.acc-same'; Group = 'extras'; NetworkAccess = 'None'"
        New-TestScanner -Folder $dir -File 'P1AccSecond.psm1' -ManifestBody "Name = 'Acc Second'; Category = 'Custom'; Id = 'extras.acc-same'; Group = 'extras'; NetworkAccess = 'None'"
        # The registrations alone look fine: one plugin, a unique Id.
        $regs = @(Get-OmniModule -Path $dir -Logger (New-OmniLogger -MinimumLevel Error))
        $regs.Count | Should -Be 1
        @($regs.Id | Select-Object -Unique).Count | Should -Be $regs.Count
        # The discovery check still reports it.
        $problems = @(Get-DiscoveryProblem -Folder $dir -Kind Module)
        ($problems -join "`n") | Should -Match 'already used'
        ($problems -join "`n") | Should -Match '2 plugin file\(s\) but 1 registration'
    }
}

Describe 'Exit codes produced by the real engines and router' {
    It 'documents exactly the codes the table publishes (docs/CLI.md)' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Root 'docs/CLI.md'))
        $start = [array]::IndexOf($lines, '## Exit codes')
        $start | Should -BeGreaterThan -1
        $documented = [System.Collections.Generic.List[int]]::new()
        for ($i = $start + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^## '; $i++) {
            if ($lines[$i] -match '^\|\s*(\d+)\s*\|') { $documented.Add([int]$Matches[1]) }
        }
        @($documented) | Should -Be @((Get-OmniExitCodeTable).Code)
    }

    It 'returns 5 for a session the engine cancelled' {
        $dir = Join-Path $TestDrive 'cancel-plugins'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        New-TestScanner -Folder $dir -File 'P1AccCancel.psm1' -ManifestBody "Name = 'Acc Cancel'; Category = 'Custom'; Group = 'extras'"
        $regs = @(Get-OmniModule -Path $dir -Logger (New-OmniLogger -MinimumLevel Error))
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -CancellationToken $cts.Token
        $session = Invoke-OmniSession -Registration $regs -Context $ctx
        $session.Cancelled | Should -BeTrue
        Get-OmniExitCode -Session $session | Should -Be 5
        Get-OmniExitCode -Session $session -ExplicitSelection | Should -Be 5
    }

    It 'returns 11 when a repair fails and 12 when one needs a reboot (real repair engine)' {
        $dir = Join-Path $TestDrive 'repair-plugins'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        New-TestRepair -Folder $dir -File 'P1AccRepairFail.psm1' -Name 'Acc Repair Fail' -Body "throw 'intentional repair failure'"
        New-TestRepair -Folder $dir -File 'P1AccRepairReboot.psm1' -Name 'Acc Repair Reboot' -Body "Invoke-OmniRepairStep -Result `$r -Context `$Context -Description 'noop' -Action { 'ok' } | Out-Null; `$r.RebootRequired = `$true"
        $logger = New-OmniLogger -MinimumLevel Error
        $repairs = @(Get-OmniRepair -Path $dir -Logger $logger)
        $repairs.Count | Should -Be 2
        $fail = @($repairs | Where-Object Name -eq 'Acc Repair Fail')
        $reboot = @($repairs | Where-Object Name -eq 'Acc Repair Reboot')

        $failed = Invoke-OmniRepair -Registration $fail -Context (New-OmniRepairContext -Logger $logger)
        $failed.Results[0].Status | Should -Be 'Failed'
        Get-OmniRepairExitCode -RepairSession $failed | Should -Be 11

        $rebooted = Invoke-OmniRepair -Registration $reboot -Context (New-OmniRepairContext -Logger $logger)
        $rebooted.RebootRequired | Should -BeTrue
        Get-OmniRepairExitCode -RepairSession $rebooted | Should -Be 12

        # A failure outranks a pending reboot.
        $both = Invoke-OmniRepair -Registration @($reboot + $fail) -Context (New-OmniRepairContext -Logger $logger)
        Get-OmniRepairExitCode -RepairSession $both | Should -Be 11
    }

    It 'returns 20 for an internal error in the router, with the message on stderr' {
        $out = [System.IO.StringWriter]::new()
        $out.Dispose()      # writing the result now throws ObjectDisposedException
        $err = [System.IO.StringWriter]::new()
        $code = Invoke-OmniDiagCli -Arguments @('version') -Out $out -Err $err
        $code | Should -Be 20
        $err.ToString() | Should -Match 'omnidiag: internal error'
        $err.ToString() | Should -Not -Match 'Usage: omnidiag'
    }

    It 'returns 20 when there is no session to derive a code from' {
        Get-OmniExitCode -Session $null | Should -Be 20
    }
}

Describe 'scan --format json over the built-in scanners' {
    It 'emits a v1 document for the default (probes off) scan that validates against the schema' {
        $out = [System.IO.StringWriter]::new()
        $err = [System.IO.StringWriter]::new()
        $code = Invoke-OmniDiagCli -Arguments @('scan', '--format', 'json', '--quiet') -Out $out -Err $err
        $code | Should -BeIn @(0, 1, 2, 3)
        $text = $out.ToString()
        $doc = $text | ConvertFrom-Json
        $doc.schemaVersion | Should -Be '1.0.0'
        $expected = @(Get-OmniModule -Path (Join-Path $script:Root 'src/Modules') -Logger (New-OmniLogger -MinimumLevel Error) |
            Where-Object { $_.Enabled })
        @($doc.modules).Count | Should -Be $expected.Count
        @($doc.modules.id | Sort-Object) | Should -Be @($expected.Id | Sort-Object)
        if (-not $script:CanValidate) { Set-ItResult -Skipped -Because 'Test-Json -Schema requires PowerShell 7'; return }
        Test-Json -Json $text -SchemaFile $script:ReportSchema | Should -BeTrue
    }
}

Describe 'omnidiag.ps1 in a child process: clean stdout and local logging' {
    It 'scan --module system.system-information --format json --verbose: stdout is one JSON document' {
        $r = Get-ChildCliResult -Arguments @('scan', '--module', 'system.system-information', '--format', 'json', '--verbose')
        $r.Code | Should -BeIn @(0, 1, 2, 3)
        $trimmed = $r.Out.Trim()
        $trimmed | Should -Match '^\{' -Because 'nothing may precede the JSON document on stdout'
        $trimmed | Should -Match '\}$' -Because 'nothing may follow the JSON document on stdout'
        $doc = $trimmed | ConvertFrom-Json
        @($doc.modules.id) | Should -Be @('system.system-information')
        $r.Err | Should -Match 'Running 1 scanner'
        if ($script:CanValidate) { Test-Json -Json $trimmed -SchemaFile $script:ReportSchema | Should -BeTrue }

        # --verbose: Debug records in a local JSONL log under OMNIDIAG_DATA.
        $m = [regex]::Match($r.Err, 'Log: (.+?\.jsonl)')
        $m.Success | Should -BeTrue
        $logPath = $m.Groups[1].Value.Trim()
        $logPath | Should -Exist
        $logPath.StartsWith((Get-OmniDataPath -Kind Logs), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue -Because "the log ($logPath) must be in the isolated OmniDiagData\logs"
        $records = @(Get-Content -LiteralPath $logPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object Level -eq 'Debug').Count | Should -BeGreaterThan 0
    }

    It 'scan without --verbose logs no Debug records' {
        $r = Get-ChildCliResult -Arguments @('scan', '--module', 'system.system-information', '--format', 'json')
        $m = [regex]::Match($r.Err, 'Log: (.+?\.jsonl)')
        $m.Success | Should -BeTrue
        $records = @(Get-Content -LiteralPath $m.Groups[1].Value.Trim() | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        @($records).Count | Should -BeGreaterThan 0
        @($records | Where-Object Level -eq 'Debug').Count | Should -Be 0
    }

    It 'list modules --format json: stdout is one JSON document that validates against the list schema' {
        $r = Get-ChildCliResult -Arguments @('list', 'modules', '--format', 'json')
        $r.Code | Should -Be 0
        $trimmed = $r.Out.Trim()
        $trimmed | Should -Match '^\{'
        $trimmed | Should -Match '\}$'
        @(($trimmed | ConvertFrom-Json).items).Count | Should -Be @(Get-ChildItem -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Modules') -Filter '*.psm1').Count
        if ($script:CanValidate) { Test-Json -Json $trimmed -SchemaFile $script:ListSchema | Should -BeTrue }
    }

    It 'version --format json and a bad option: <Case>' -ForEach @(
        @{ Case = 'version json'; Arguments = @('version', '--format', 'json'); Code = 0; Json = $true }
        @{ Case = 'unknown option'; Arguments = @('list', '--bogus'); Code = 10; Json = $false }
    ) {
        $r = Get-ChildCliResult -Arguments $Arguments
        $r.Code | Should -Be $Code
        if ($Json) {
            ($r.Out.Trim() | ConvertFrom-Json).kind | Should -Be 'version'
        } else {
            $r.Out.Trim() | Should -BeNullOrEmpty -Because 'usage errors go to stderr only'
            $r.Err | Should -Match "unknown option '--bogus'"
        }
    }
}
