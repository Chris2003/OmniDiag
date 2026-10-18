#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests for the OmniDiag orchestration engine. Uses in-memory fake
    modules (New-Module) so the engine is exercised without touching the disk
    or any Windows data source.
#>

BeforeAll {
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/OmniDiag.psd1'
    Import-Module $manifest -Force -DisableNameChecking -Global

    function New-FakeRegistration {
        param(
            [string] $Name = 'Fake',
            [string] $Category = 'Test',
            [string] $Severity = 'Pass',
            [bool] $RequiresAdmin = $false,
            [switch] $Throw
        )
        # Arguments are bound into the new module's session state via -ArgumentList
        # so the convention functions close over them (New-Module has no $using:).
        $sb = {
            param($ModName, $ModCategory, $ModSeverity, $ShouldThrow)
            function Get-OmniModuleManifest { @{ Name = $ModName; Category = $ModCategory } }
            function Invoke-OmniModuleScan {
                param($Context)
                if ($ShouldThrow) { throw 'intentional failure' }
                $r = New-OmniResult -ModuleName $ModName -Category $ModCategory
                Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'fake' -Severity $ModSeverity)
                return (Complete-OmniResult -Result $r)
            }
            Export-ModuleMember -Function *
        }
        $mod = New-Module -Name "Fake_$Name" -ScriptBlock $sb -ArgumentList $Name, $Category, $Severity, ([bool]$Throw)
        return [pscustomobject]@{
            Name = $Name; Category = $Category; Description = ''
            RequiresAdmin = $RequiresAdmin; Order = 1; Enabled = $true
            ModuleInfo = $mod; SourceFile = ''
        }
    }

    function New-TestContext {
        param([System.Threading.CancellationToken] $Token = [System.Threading.CancellationToken]::None)
        $logger = New-OmniLogger -MinimumLevel Error   # no file, no console noise
        New-OmniContext -Logger $logger -CancellationToken $Token
    }

    # File-based fake scanners: only registrations with a plugin file go to the runspace pool.
    function New-PluginFolder {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    function New-FilePlugin {
        param(
            [string] $Folder, [string] $Name, [int] $Order = 1, [string] $Group = 'extras',
            [string] $Body = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'ok' -Severity 'Pass')",
            [string] $Extra = ''
        )
        $file = Join-Path $Folder (($Name -replace '[^A-Za-z0-9]', '') + '.psm1')
        $text = @"
function Get-OmniModuleManifest { @{ Name = '$Name'; Category = 'Test'; Group = '$Group'; Order = $Order; $Extra } }
function Invoke-OmniModuleScan {
    param(`$Context)
    `$r = New-OmniResult -ModuleName '$Name' -Category 'Test'
    $Body
    return (Complete-OmniResult -Result `$r)
}
Export-ModuleMember -Function 'Get-OmniModuleManifest', 'Invoke-OmniModuleScan'
"@
        Set-Content -LiteralPath $file -Value $text -Encoding ascii
    }

    function Get-TestRegistration {
        param([string] $Folder)
        @(Get-OmniModule -Path $Folder -Logger (New-OmniLogger -MinimumLevel Error))
    }

    # A comparable projection of a session (everything but timing).
    function Get-SessionShape {
        param($Session)
        foreach ($r in $Session.Results) {
            $f = @($r.Findings | ForEach-Object { '{0}|{1}' -f $_.Severity, $_.Title }) -join ';'
            '{0}|{1}|{2}|{3}|{4}|{5}' -f $r.ModuleName, $r.ModuleId, $r.Status, $r.SkippedReason, $r.Error, $f
        }
    }

    $script:ThreadFinding = "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'thread' -Severity 'Pass' -Data ([System.Threading.Thread]::CurrentThread.ManagedThreadId))"
}

Describe 'Invoke-OmniSession' {
    It 'runs a module and aggregates a summary' {
        $reg = New-FakeRegistration -Severity 'Pass'
        $session = Invoke-OmniSession -Registration @($reg) -Context (New-TestContext)
        $session.PSTypeNames | Should -Contain 'OmniDiag.Session'
        $session.Results | Should -HaveCount 1
        $session.Results[0].Status | Should -Be 'Healthy'
        $session.Summary.Score | Should -Be 100
        $session.Cancelled | Should -BeFalse
    }

    It 'captures a module exception as a Failed result instead of aborting' {
        $good = New-FakeRegistration -Name 'Good' -Severity 'Pass'
        $bad  = New-FakeRegistration -Name 'Bad' -Throw
        $session = Invoke-OmniSession -Registration @($bad, $good) -Context (New-TestContext)
        $session.Results | Should -HaveCount 2
        ($session.Results | Where-Object Status -eq 'Failed') | Should -HaveCount 1
        ($session.Results | Where-Object Status -eq 'Healthy') | Should -HaveCount 1
    }

    It 'skips admin-only modules when not elevated' {
        $reg = New-FakeRegistration -Name 'NeedsAdmin' -RequiresAdmin $true
        $ctx = New-TestContext
        $ctx.IsAdmin = $false
        $session = Invoke-OmniSession -Registration @($reg) -Context $ctx
        $session.Results[0].Status | Should -Be 'Skipped'
    }

    It 'honors a pre-cancelled token and runs nothing' {
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        $reg = New-FakeRegistration
        $session = Invoke-OmniSession -Registration @($reg) -Context (New-TestContext -Token $cts.Token)
        $session.Cancelled | Should -BeTrue
        $session.Results | Should -HaveCount 0
    }

    It 'applies category filters' {
        $a = New-FakeRegistration -Name 'A' -Category 'System'
        $b = New-FakeRegistration -Name 'B' -Category 'Network'
        $session = Invoke-OmniSession -Registration @($a, $b) -Context (New-TestContext) -IncludeCategory 'Network'
        $session.Results | Should -HaveCount 1
        $session.Results[0].Category | Should -Be 'Network'
    }

    It 'runs a role profile through the public API and records the plan' {
        $modulesPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Modules'
        $session = Invoke-OmniDiag -ModulesPath $modulesPath -Profile HelpDesk -Quiet
        $session.ScanPlan.Name | Should -Be 'HelpDesk'
        $session.ScanPlan.Type | Should -Be 'RoleProfile'
        @($session.Results).Count | Should -BeGreaterThan 0
        foreach ($result in @($session.Results)) {
            (Get-OmniRoleProfile HelpDesk).Modules | Should -Contain $result.ModuleName
        }
    }

    It 'rejects ambiguous scanner selection' {
        { Invoke-OmniDiag -Profile HelpDesk -Workflow QuickTriage -Quiet } | Should -Throw '*either*'
        { Invoke-OmniDiag -Profile HelpDesk -IncludeModule CPU -Quiet } | Should -Throw '*selection method*'
    }
}

Describe 'Parallel engine (runspace pool)' {
    It 'defaults to the processor count capped at 8' {
        $n = Get-OmniDefaultParallelism
        $n | Should -BeGreaterOrEqual 1
        $n | Should -BeLessOrEqual 8
        $n | Should -Be ([Math]::Min([Environment]::ProcessorCount, 8))
    }

    It 'returns results in registration order whatever finishes first, from worker threads' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Order A' -Order 1 -Body ("Start-Sleep -Milliseconds 1500; " + $script:ThreadFinding)
        New-FilePlugin -Folder $dir -Name 'Order B' -Order 2 -Body $script:ThreadFinding
        New-FilePlugin -Folder $dir -Name 'Order C' -Order 3 -Body ("Start-Sleep -Milliseconds 400; " + $script:ThreadFinding)
        $callerThread = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        $events = [System.Collections.Generic.List[object]]::new()
        $cb = { param($p) $events.Add([pscustomobject]@{ Name = $p.Name; Phase = $p.Phase; Index = $p.Index; Thread = [System.Threading.Thread]::CurrentThread.ManagedThreadId }) }.GetNewClosure()

        $session = Invoke-OmniSession -Registration (Get-TestRegistration $dir) -Context (New-TestContext) -MaxParallel 3 -ProgressCallback $cb

        @($session.Results.ModuleName) | Should -Be @('Order A', 'Order B', 'Order C')
        foreach ($r in $session.Results) {
            $r.Status | Should -Be 'Healthy'
            $r.Findings[0].Data | Should -Not -Be $callerThread -Because 'pooled modules run on worker threads'
        }
        # Progress: a Start and a Done per module, all on the caller's thread, Done indexes 1..3.
        @($events | Where-Object Phase -eq 'Start').Count | Should -Be 3
        @($events | Where-Object Phase -eq 'Done').Count | Should -Be 3
        @($events | Where-Object Phase -eq 'Done' | ForEach-Object Index) | Should -Be @(1, 2, 3)
        @($events | Where-Object { $_.Thread -ne $callerThread }).Count | Should -Be 0
    }

    It 'fails a module that runs past its TimeoutSec, stops it, and keeps going' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Too Slow' -Order 1 -Extra 'TimeoutSec = 1' -Body 'Start-Sleep -Seconds 60'
        New-FilePlugin -Folder $dir -Name 'Quick One' -Order 2
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $session = Invoke-OmniSession -Registration (Get-TestRegistration $dir) -Context (New-TestContext) -MaxParallel 2
        $sw.Stop()

        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        $session.Cancelled | Should -BeFalse
        $slow = $session.Results | Where-Object ModuleName -eq 'Too Slow'
        $slow.Status | Should -Be 'Failed'
        $slow.Error | Should -Be 'Timed out after 1 s'
        $slow.SkippedReason | Should -BeNullOrEmpty
        $slow.ModuleId | Should -Be 'extras.too-slow'
        ($session.Results | Where-Object ModuleName -eq 'Quick One').Status | Should -Be 'Healthy'
        Get-OmniExitCode -Session $session | Should -Be 3
        $v1 = ConvertTo-OmniReportV1 -Session $session
        ($v1.modules | Where-Object { $_.id -eq 'extras.too-slow' }).error | Should -Be 'Timed out after 1 s'
    }

    It 'honors cancellation: no new work, running workers stopped and recorded as Cancelled' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Slow A' -Order 1 -Body 'Start-Sleep -Seconds 60'
        New-FilePlugin -Folder $dir -Name 'Slow B' -Order 2 -Body 'Start-Sleep -Seconds 60'
        New-FilePlugin -Folder $dir -Name 'Slow C' -Order 3 -Body 'Start-Sleep -Seconds 60'
        $cts = [System.Threading.CancellationTokenSource]::new()
        # Cancel (on the caller's thread) as soon as the second module starts.
        $cb = { param($p) if ($p.Phase -eq 'Start' -and $p.Name -eq 'Slow B') { $cts.Cancel() } }.GetNewClosure()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $session = Invoke-OmniSession -Registration (Get-TestRegistration $dir) -Context (New-TestContext -Token $cts.Token) -MaxParallel 2 -ProgressCallback $cb
        $sw.Stop()

        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        $session.Cancelled | Should -BeTrue
        @($session.Results.ModuleName) | Should -Be @('Slow A', 'Slow B')
        foreach ($r in $session.Results) {
            $r.Status | Should -Be 'Skipped'
            $r.SkippedReason | Should -Be 'Cancelled'
        }
        Get-OmniExitCode -Session $session | Should -Be 5
    }

    It 'isolates a throwing module as a Failed result' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Thrower' -Order 1 -Body "throw 'intentional failure'"
        New-FilePlugin -Folder $dir -Name 'Survivor' -Order 2
        $session = Invoke-OmniSession -Registration (Get-TestRegistration $dir) -Context (New-TestContext) -MaxParallel 2
        $bad = $session.Results | Where-Object ModuleName -eq 'Thrower'
        $bad.Status | Should -Be 'Failed'
        $bad.Error | Should -Be 'intentional failure'
        $bad.Findings[0].Severity | Should -Be 'Error'
        ($session.Results | Where-Object ModuleName -eq 'Survivor').Status | Should -Be 'Healthy'
    }

    It 'produces the same findings with -MaxParallel 1 (sequential) and in parallel' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Eq Pass' -Order 1
        New-FilePlugin -Folder $dir -Name 'Eq Warn' -Order 2 -Body "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'filling up' -Severity 'Warning')"
        New-FilePlugin -Folder $dir -Name 'Eq Info' -Order 3 -Body "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'fyi' -Severity 'Information'); Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'bad' -Severity 'Error')"
        New-FilePlugin -Folder $dir -Name 'Eq Throw' -Order 4 -Body "throw 'boom'"
        New-FilePlugin -Folder $dir -Name 'Eq Admin' -Order 5 -Extra 'RequiresAdmin = $true'
        New-FilePlugin -Folder $dir -Name 'Eq Platform' -Order 6 -Extra "SupportedPlatforms = @('macOS')"
        New-FilePlugin -Folder $dir -Name 'Eq Inline' -Order 7 -Extra 'Parallel = $false'
        $regs = Get-TestRegistration $dir

        $ctx1 = New-TestContext; $ctx1.IsAdmin = $false; $ctx1.Platform = 'Windows'
        $ctx4 = New-TestContext; $ctx4.IsAdmin = $false; $ctx4.Platform = 'Windows'
        $seq = Invoke-OmniSession -Registration $regs -Context $ctx1 -MaxParallel 1
        $par = Invoke-OmniSession -Registration $regs -Context $ctx4 -MaxParallel 4

        @(Get-SessionShape $par) | Should -Be @(Get-SessionShape $seq)
        @($par.Results).Count | Should -Be 7
        ($par.Results | Where-Object ModuleName -eq 'Eq Admin').SkippedReason | Should -Be 'RequiresElevation'
        ($par.Results | Where-Object ModuleName -eq 'Eq Platform').SkippedReason | Should -Be 'NotSupported'
        $par.Summary.Score | Should -Be $seq.Summary.Score
    }

    It 'runs Parallel = $false modules on the caller thread' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Pinned' -Order 1 -Extra 'Parallel = $false' -Body $script:ThreadFinding
        New-FilePlugin -Folder $dir -Name 'Pooled' -Order 2 -Body $script:ThreadFinding
        $session = Invoke-OmniSession -Registration (Get-TestRegistration $dir) -Context (New-TestContext) -MaxParallel 2
        $caller = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        ($session.Results | Where-Object ModuleName -eq 'Pinned').Findings[0].Data | Should -Be $caller
        ($session.Results | Where-Object ModuleName -eq 'Pooled').Findings[0].Data | Should -Not -Be $caller
        @($session.Results.ModuleName) | Should -Be @('Pinned', 'Pooled')
    }

    It 'skips modules whose platform or architecture is not supported, with SkippedReason NotSupported in the v1 report' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Arm Only' -Order 1 -Extra "SupportedArchitectures = @('arm64')"
        New-FilePlugin -Folder $dir -Name 'Win Only' -Order 2 -Extra "SupportedPlatforms = @('Windows')"
        $ctx = New-TestContext
        $ctx.Architecture = 'x64'
        $ctx.Platform = 'Linux'
        $session = Invoke-OmniSession -Registration (Get-TestRegistration $dir) -Context $ctx
        foreach ($r in $session.Results) {
            $r.Status | Should -Be 'Skipped'
            $r.SkippedReason | Should -Be 'NotSupported'
        }
        $v1 = ConvertTo-OmniReportV1 -Session $session
        @($v1.modules | ForEach-Object { $_.skippedReason }) | Should -Be @('NotSupported', 'NotSupported')
        Get-OmniExitCode -Session $session | Should -Be 0
    }

    It 'merges worker log records into the caller log file as whole JSON lines' {
        $dir = New-PluginFolder
        foreach ($i in 1..6) {
            New-FilePlugin -Folder $dir -Name "Logger $i" -Order $i -Body ("foreach (`$k in 1..20) { `$Context.Logger.Info(""worker $i line `$k"", 'Fake') }; Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title 'ok' -Severity 'Pass')")
        }
        $logPath = Join-Path $TestDrive 'merge.jsonl'
        $logger = New-OmniLogger -Path $logPath -MinimumLevel Info
        $ctx = New-OmniContext -Logger $logger
        $null = Invoke-OmniSession -Registration (Get-TestRegistration $dir) -Context $ctx -MaxParallel 4
        $lines = @(Get-Content -LiteralPath $logPath | Where-Object { $_.Trim() })
        $records = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        $records.Count | Should -Be $lines.Count
        @($records | Where-Object { $_.Component -eq 'Fake' }).Count | Should -Be 120
        @($logger.Buffer | Where-Object { $_.Component -eq 'Fake' }).Count | Should -Be 120
    }

    It 'passes the probes flag, config, and elevation state to workers' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Ctx Probe' -Order 1 -Body "Add-OmniFinding -Result `$r -Finding (New-OmniFinding -Title ('probes=' + (Test-OmniNetworkProbeEnabled -Context `$Context) + ';x=' + `$Context.Config['X'] + ';admin=' + `$Context.IsAdmin) -Severity 'Pass')"
        $ctx = New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error) -Config @{ X = 'abc' }
        $ctx.IsAdmin = $false
        $session = Invoke-OmniSession -Registration (Get-TestRegistration $dir) -Context $ctx -MaxParallel 2 -NetworkProbes
        $session.Results[0].Findings[0].Title | Should -Be 'probes=True;x=abc;admin=False'
    }

    It 'works when the session itself runs in a background runspace (GUI scenario)' {
        $dir = New-PluginFolder
        New-FilePlugin -Folder $dir -Name 'Nested A' -Order 1
        New-FilePlugin -Folder $dir -Name 'Nested B' -Order 2
        $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/OmniDiag.psd1'
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [PowerShell]::Create()
        try {
            $ps.Runspace = $rs
            [void]$ps.AddScript({
                    param($Manifest, $Folder)
                    Import-Module $Manifest -Force -DisableNameChecking
                    $regs = @(Get-OmniModule -Path $Folder -Logger (New-OmniLogger -MinimumLevel Error))
                    $s = Invoke-OmniSession -Registration $regs -Context (New-OmniContext -Logger (New-OmniLogger -MinimumLevel Error)) -MaxParallel 2
                    @($s.Results | ForEach-Object { '{0}={1}' -f $_.ModuleName, $_.Status })
                }).AddArgument($manifest).AddArgument($dir)
            $out = @($ps.Invoke())
            $ps.HadErrors | Should -BeFalse
            @($out | ForEach-Object { [string]$_ }) | Should -Be @('Nested A=Healthy', 'Nested B=Healthy')
        } finally {
            $ps.Dispose()
            $rs.Dispose()
        }
    }
}
