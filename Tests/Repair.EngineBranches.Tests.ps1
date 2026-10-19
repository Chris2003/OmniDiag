#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Branch tests for the repair engine (src/Repair/RepairEngine.psm1): cancellation between
    repairs, the restore-point gate and its approval logic, malformed plugin results, the
    dry-run guarantees, audit-log write failures and fallbacks, and the progress callback.

    Harmless fake repairs only: their single action appends to a marker file in TestDrive,
    so "did the action run?" is a file check. System Restore is replaced through the
    context's RestorePointProvider seam (no Mock -ModuleName: mocks don't reliably reach
    the nested engine module). Every run writes its audit log to TestDrive via
    Config['AuditLogPath'], never to the real OmniDiagData folder.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    $script:Dir = Join-Path $TestDrive 'engine-branch-repairs'
    New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null

    function New-BranchRepair {
        param([string] $File, [string] $Manifest, [string] $Body)
        $text = "function Get-OmniRepairManifest { $Manifest }`n" +
            "function Invoke-OmniRepairAction {`n    param(`$Context)`n$Body`n}`n" +
            "Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')`n"
        Set-Content -LiteralPath (Join-Path $script:Dir "$File.psm1") -Value $text -Encoding ascii
    }

    # Appends one line to Config['Marker'] - the only side effect any fake has.
    $markerBody = @'
    $r = New-OmniRepairResult -Name $Name -Category 'Test'
    $marker = $Context.Config['Marker']
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'append marker line' -Action {
        Add-Content -LiteralPath $marker -Value 'ran'
    } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
'@
    New-BranchRepair -File 'BrMarker' -Manifest "@{ Name = 'Br Marker'; Category = 'Test'; Order = 1 }" -Body ("    `$Name = 'Br Marker'`n" + $markerBody)
    New-BranchRepair -File 'BrRestore' -Manifest "@{ Name = 'Br Restore'; Category = 'Test'; Risk = 'Moderate'; RestorePoint = `$true; Order = 2 }" -Body ("    `$Name = 'Br Restore'`n" + $markerBody)
    New-BranchRepair -File 'BrAdminRestore' -Manifest "@{ Name = 'Br Admin Restore'; Category = 'Test'; Risk = 'Moderate'; RequiresAdmin = `$true; RestorePoint = `$true; Order = 3 }" -Body ("    `$Name = 'Br Admin Restore'`n" + $markerBody)

    # Cancels the run's token (Config['Cts']) after its own step completed.
    New-BranchRepair -File 'BrCanceller' -Manifest "@{ Name = 'Br Canceller'; Category = 'Test'; Order = 4 }" -Body @'
    $r = New-OmniRepairResult -Name 'Br Canceller' -Category 'Test'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'first step' -Action { 'first' } | Out-Null
    $Context.Config['Cts'].Cancel()
    return (Complete-OmniRepairResult -Result $r)
'@
    New-BranchRepair -File 'BrNull' -Manifest "@{ Name = 'Br Null'; Category = 'Test'; Order = 5 }" -Body '    return $null'
    # Returns a result without completing it (no EndTime): the engine must finish it.
    New-BranchRepair -File 'BrIncomplete' -Manifest "@{ Name = 'Br Incomplete'; Category = 'Test'; Order = 6 }" -Body @'
    $r = New-OmniRepairResult -Name 'Br Incomplete' -Category 'Test'
    Add-OmniRepairStep -Result $r -Description 'recorded by hand' -Succeeded $true -Output 'ok'
    return $r
'@
    # A plugin whose read-only discovery returns early but claims a reboot: a dry run must
    # still report DryRun and no reboot.
    New-BranchRepair -File 'BrDryReboot' -Manifest "@{ Name = 'Br Dry Reboot'; Category = 'Test'; RebootHint = `$true; Order = 7 }" -Body @'
    $r = New-OmniRepairResult -Name 'Br Dry Reboot' -Category 'Test'
    $r.RebootRequired = $true
    return $r
'@
    New-BranchRepair -File 'BrThrows' -Manifest "@{ Name = 'Br Throws'; Category = 'Test'; Order = 8 }" -Body "    throw 'discovery unavailable on this host'"
    # A step whose Timestamp is not a [datetime] (hand-built result).
    New-BranchRepair -File 'BrOddStep' -Manifest "@{ Name = 'Br Odd Step'; Category = 'Test'; Order = 9 }" -Body @'
    $r = New-OmniRepairResult -Name 'Br Odd Step' -Category 'Test'
    Add-OmniRepairStep -Result $r -Description 'odd timestamp' -Succeeded $true -Output 'ok'
    $r.Steps[0].Timestamp = 'not-a-date'
    return (Complete-OmniRepairResult -Result $r)
'@
    # A failed result with no steps at all (the audit log still gets one line).
    New-BranchRepair -File 'BrEmptyFailed' -Manifest "@{ Name = 'Br Empty Failed'; Category = 'Test'; Order = 10 }" -Body @'
    $r = New-OmniRepairResult -Name 'Br Empty Failed' -Category 'Test'
    $r.Error = 'nothing could be done'
    return (Complete-OmniRepairResult -Result $r -Status 'Failed')
'@

    $script:Logger = New-OmniLogger -MinimumLevel Error
    $script:All = @(Get-OmniRepair -Path $script:Dir -Logger $script:Logger)
    function Get-Fake { param([string] $Name) @($script:All | Where-Object Name -eq $Name) }

    # A fresh marker/audit pair and a context for one test.
    function New-BranchContext {
        param([switch] $DryRun, [System.Threading.CancellationToken] $Token = ([System.Threading.CancellationToken]::None),
            [hashtable] $Extra = @{}, [pscustomobject] $Logger = $script:Logger)
        $id = [guid]::NewGuid().ToString('N')
        $config = @{ Marker = (Join-Path $TestDrive "marker-$id.txt"); AuditLogPath = (Join-Path $TestDrive "audit-$id.jsonl") }
        foreach ($k in $Extra.Keys) { $config[$k] = $Extra[$k] }
        New-OmniRepairContext -Logger $Logger -DryRun:$DryRun -CancellationToken $Token -Config $config
    }
    function Get-MarkerCount { param($Context) if (Test-Path -LiteralPath $Context.Config['Marker']) { @(Get-Content -LiteralPath $Context.Config['Marker']).Count } else { 0 } }
    function Get-AuditEntry {
        param($Context)
        $p = $Context.Config['AuditLogPath']
        if (-not (Test-Path -LiteralPath $p)) { return }
        Get-Content -LiteralPath $p | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
    }
    # Adds a recording RestorePointProvider; returns the list of recorded descriptions.
    function Add-RestoreProvider {
        param($Context, [string] $Status, [bool] $Protected, [string] $Message = 'test provider')
        $calls = [System.Collections.Generic.List[string]]::new()
        $answer = [pscustomobject]@{ Created = ($Status -eq 'Created'); Protected = $Protected; Status = $Status; Message = $Message }
        $provider = { param($d, $l) $calls.Add($d); $answer }.GetNewClosure()
        $Context | Add-Member -NotePropertyName RestorePointProvider -NotePropertyValue $provider -Force
        return , $calls
    }
}

Describe 'Repair engine: cancellation' {
    It 'runs nothing when the token is cancelled before the first repair' {
        $cts = [System.Threading.CancellationTokenSource]::new(); $cts.Cancel()
        $ctx = New-BranchContext -Token $cts.Token
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Marker') -Context $ctx
        $session.Cancelled | Should -BeTrue
        @($session.Results).Count | Should -Be 0
        Get-MarkerCount $ctx | Should -Be 0
        @(Get-AuditEntry $ctx).Count | Should -Be 0
    }

    It 'stops between repairs when cancellation arrives mid-session' {
        $cts = [System.Threading.CancellationTokenSource]::new()
        $ctx = New-BranchContext -Token $cts.Token -Extra @{ Cts = $cts }
        $session = Invoke-OmniRepair -Registration @((Get-Fake 'Br Canceller'), (Get-Fake 'Br Marker')) -Context $ctx
        $session.Cancelled | Should -BeTrue
        @($session.Results).Count | Should -Be 1
        $session.Results[0].Name | Should -Be 'Br Canceller'
        $session.Results[0].Status | Should -Be 'Succeeded'
        Get-MarkerCount $ctx | Should -Be 0 -Because 'the second repair must never start'
        $audit = @(Get-AuditEntry $ctx)
        $audit.Count | Should -Be 1 -Because 'only the repair that ran is audited'
        $audit[0].repairName | Should -Be 'Br Canceller'
    }
}

Describe 'Repair engine: restore-point gate and approval' {
    It 'skips a RestorePoint repair when the checkpoint could not protect the run' {
        $ctx = New-BranchContext
        $calls = Add-RestoreProvider $ctx -Status 'Failed' -Protected $false -Message 'System Restore is disabled (test).'
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Restore') -Context $ctx
        $calls.Count | Should -Be 1
        $session.RestorePoint.Status | Should -Be 'Failed'
        $result = $session.Results[0]
        $result.Status | Should -Be 'Skipped'
        $result.Steps[0].Description | Should -Be 'Requires a System Restore point'
        $result.Steps[0].Output | Should -Match 'disabled \(test\)'
        $result.Steps[0].Output | Should -Match 'AllowRepairWithoutRestorePoint'
        Get-MarkerCount $ctx | Should -Be 0
        @(Get-AuditEntry $ctx).Count | Should -Be 0 -Because 'a gated repair changed nothing'
    }

    It 'runs when Windows throttled the request but a recent point exists, and audits that' {
        $ctx = New-BranchContext
        $calls = Add-RestoreProvider $ctx -Status 'RecentExisting' -Protected $true
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Restore') -Context $ctx
        $calls.Count | Should -Be 1
        $session.Results[0].Status | Should -Be 'Succeeded'
        Get-MarkerCount $ctx | Should -Be 1
        (@(Get-AuditEntry $ctx))[0].restorePoint | Should -Be 'RecentExisting'
    }

    It 'creates one checkpoint for the whole run, not one per repair' {
        $ctx = New-BranchContext
        $calls = Add-RestoreProvider $ctx -Status 'Created' -Protected $true
        $restore = Get-Fake 'Br Restore'
        $session = Invoke-OmniRepair -Registration @($restore, $restore) -Context $ctx
        $calls.Count | Should -Be 1
        @($session.Results | Where-Object Status -eq 'Succeeded').Count | Should -Be 2
        Get-MarkerCount $ctx | Should -Be 2
        @(Get-AuditEntry $ctx | Where-Object restorePoint -eq 'Created').Count | Should -Be 2
    }

    It '-AllowWithoutRestorePoint runs the repair after a failed checkpoint and audits Failed' {
        $ctx = New-BranchContext
        $calls = Add-RestoreProvider $ctx -Status 'Failed' -Protected $false
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Restore') -Context $ctx -AllowWithoutRestorePoint
        $calls.Count | Should -Be 1 -Because 'the checkpoint is still attempted'
        $session.Results[0].Status | Should -Be 'Succeeded'
        (@(Get-AuditEntry $ctx))[0].restorePoint | Should -Be 'Failed'
    }

    It '-SkipRestorePoint never asks for a checkpoint and audits SkippedByCaller' {
        $ctx = New-BranchContext
        $calls = Add-RestoreProvider $ctx -Status 'Created' -Protected $true
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Restore') -Context $ctx -SkipRestorePoint
        $calls.Count | Should -Be 0
        $session.RestorePoint | Should -BeNullOrEmpty
        $session.Results[0].Status | Should -Be 'Succeeded'
        (@(Get-AuditEntry $ctx))[0].restorePoint | Should -Be 'SkippedByCaller'
    }

    It 'asks for no checkpoint when no selected repair wants one (NotRequested)' {
        $ctx = New-BranchContext
        $calls = Add-RestoreProvider $ctx -Status 'Created' -Protected $true
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Marker') -Context $ctx
        $calls.Count | Should -Be 0
        $session.Results[0].Status | Should -Be 'Succeeded'
        (@(Get-AuditEntry $ctx))[0].restorePoint | Should -Be 'NotRequested'
    }

    It 'creates no checkpoint for an admin-only RestorePoint repair that is skipped for elevation' {
        $ctx = New-BranchContext
        $ctx.IsAdmin = $false
        $calls = Add-RestoreProvider $ctx -Status 'Created' -Protected $true
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Admin Restore') -Context $ctx
        $calls.Count | Should -Be 0 -Because 'a repair that cannot run must not trigger a System Restore point'
        $session.Results[0].Status | Should -Be 'Skipped'
        $session.Results[0].Steps[0].Description | Should -Be 'Requires administrator rights'
        Get-MarkerCount $ctx | Should -Be 0
        @(Get-AuditEntry $ctx).Count | Should -Be 0
    }

    It 'describes an admin-only repair in a dry run instead of skipping it, without a checkpoint' {
        $ctx = New-BranchContext -DryRun
        $ctx.IsAdmin = $false
        $calls = Add-RestoreProvider $ctx -Status 'Created' -Protected $true
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Admin Restore') -Context $ctx
        $calls.Count | Should -Be 0
        $session.Results[0].Status | Should -Be 'DryRun'
        Get-MarkerCount $ctx | Should -Be 0
        @(Get-AuditEntry $ctx).Count | Should -Be 0
    }
}

Describe 'Repair engine: malformed plugin results and dry-run guarantees' {
    It 'fails a repair that returns no result and audits the error step' {
        $ctx = New-BranchContext
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Null') -Context $ctx
        $result = $session.Results[0]
        $result.Status | Should -Be 'Failed'
        $result.Error | Should -Match 'returned no result'
        $result.Steps[0].Description | Should -Be 'Unhandled error'
        Get-OmniRepairExitCode -RepairSession $session | Should -Be 11
        $audit = @(Get-AuditEntry $ctx)
        $audit.Count | Should -Be 1
        $audit[0].step | Should -Be 'Unhandled error'
        $audit[0].repairStatus | Should -Be 'Failed'
        $audit[0].succeeded | Should -BeFalse
    }

    It 'audits "(no steps recorded)" with the error when a failed result has no steps' {
        $ctx = New-BranchContext
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Empty Failed') -Context $ctx
        $session.Results[0].Status | Should -Be 'Failed'
        $audit = @(Get-AuditEntry $ctx)
        $audit.Count | Should -Be 1
        $audit[0].step | Should -Be '(no steps recorded)'
        $audit[0].succeeded | Should -BeFalse
        $audit[0].output | Should -Be 'nothing could be done'
    }

    It 'completes a result the plugin returned unfinished' {
        $ctx = New-BranchContext
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Incomplete') -Context $ctx
        $result = $session.Results[0]
        $result.Status | Should -Be 'Succeeded'
        $result.EndTime | Should -Not -BeNullOrEmpty
        $result.DurationMs | Should -BeGreaterOrEqual 0
    }

    It 'reports DryRun and no reboot for a plugin that returns early in a dry run' {
        $ctx = New-BranchContext -DryRun
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Dry Reboot') -Context $ctx
        $session.Results[0].Status | Should -Be 'DryRun'
        $session.Results[0].RebootRequired | Should -BeFalse
        $session.RebootRequired | Should -BeFalse
        Get-OmniRepairExitCode -RepairSession $session | Should -Be 0
    }

    It 'keeps a dry run DryRun when the plugin throws, preserving the error' {
        $ctx = New-BranchContext -DryRun
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Throws') -Context $ctx
        $session.Results[0].Status | Should -Be 'DryRun'
        $session.Results[0].Error | Should -Match 'discovery unavailable'
        @(Get-AuditEntry $ctx).Count | Should -Be 0 -Because 'dry runs are never audited'
    }

    It 'fails the same throwing plugin on a real run and continues with the next repair' {
        $ctx = New-BranchContext
        $session = Invoke-OmniRepair -Registration @((Get-Fake 'Br Throws'), (Get-Fake 'Br Marker')) -Context $ctx
        $session.Results[0].Status | Should -Be 'Failed'
        $session.Results[1].Status | Should -Be 'Succeeded'
        Get-MarkerCount $ctx | Should -Be 1
    }
}

Describe 'Repair engine: audit log robustness' {
    It 'logs an audit write failure without failing or undoing the repair' {
        $logger = New-OmniLogger -MinimumLevel Debug
        $blocker = Join-Path $TestDrive ('blocker-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $blocker -Value 'a file where the audit folder should be'
        $ctx = New-BranchContext -Logger $logger -Extra @{ AuditLogPath = (Join-Path $blocker 'repair-audit.jsonl') }
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Marker') -Context $ctx
        $session.Results[0].Status | Should -Be 'Succeeded'
        Get-MarkerCount $ctx | Should -Be 1
        @($logger.Buffer | Where-Object { $_.Message -match 'Could not write the repair audit log' }).Count | Should -Be 1
    }

    It 'falls back to the process identity when the context carries no host details' {
        $id = [guid]::NewGuid().ToString('N')
        $ctx = [pscustomobject]@{
            Logger            = $script:Logger
            DryRun            = $false
            CancellationToken = [System.Threading.CancellationToken]::None
            IsAdmin           = $false
            Config            = @{ Marker = (Join-Path $TestDrive "marker-$id.txt"); AuditLogPath = (Join-Path $TestDrive "audit-$id.jsonl") }
            Host              = $null
        }
        Invoke-OmniRepair -Registration (Get-Fake 'Br Marker') -Context $ctx | Out-Null
        $audit = @(Get-AuditEntry $ctx)
        $audit.Count | Should -Be 1
        $audit[0].user | Should -Be ([System.Environment]::UserName)
        $audit[0].computer | Should -Be ([System.Environment]::MachineName)
    }

    It 'stamps the current UTC time when a step has no usable timestamp' {
        $ctx = New-BranchContext
        Invoke-OmniRepair -Registration (Get-Fake 'Br Odd Step') -Context $ctx | Out-Null
        $raw = @(Get-Content -LiteralPath $ctx.Config['AuditLogPath'] | Where-Object { $_ })
        $raw.Count | Should -Be 1
        $raw[0] | Should -Match '"time":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"'
        $raw[0] | Should -Match '"step":"odd timestamp"'
    }
}

Describe 'Repair engine: progress callback' {
    It 'reports Start, Done, and Skipped with indexes and percentages' {
        $events = [System.Collections.Generic.List[string]]::new()
        $callback = { param($p) $events.Add(('{0}:{1}/{2}:{3}' -f $p.Phase, $p.Index, $p.Total, $p.PercentComplete)) }.GetNewClosure()
        $ctx = New-BranchContext
        $ctx.IsAdmin = $false
        Invoke-OmniRepair -Registration @((Get-Fake 'Br Marker'), (Get-Fake 'Br Admin Restore')) -Context $ctx -ProgressCallback $callback | Out-Null
        ($events -join ',') | Should -Be 'Start:0/2:0,Done:1/2:50,Start:1/2:50,Skipped:2/2:100'
    }

    It 'logs a throwing callback and still completes the session' {
        $logger = New-OmniLogger -MinimumLevel Debug
        $ctx = New-BranchContext -Logger $logger
        $session = Invoke-OmniRepair -Registration (Get-Fake 'Br Marker') -Context $ctx -ProgressCallback { throw 'the window is gone' }
        $session.Results[0].Status | Should -Be 'Succeeded'
        @($logger.Buffer | Where-Object { $_.Message -match 'progress callback threw' }).Count | Should -BeGreaterThan 0
    }
}
