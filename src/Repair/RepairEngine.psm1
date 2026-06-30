<#
.SYNOPSIS
    The OmniDiag repair execution engine.

.DESCRIPTION
    Runs a caller-selected set of repair registrations against a repair context and
    returns an OmniDiag.RepairSession. Mirrors the diagnostic engine
    (Core/Engine.psm1): per-repair error capture, admin-gated graceful skipping, and
    cooperative cancellation - so one repair can't abort the batch.

    Safety: when any selected repair declares RestorePoint and this is not a dry-run,
    the engine creates ONE System Restore checkpoint up front (not one per repair,
    which would hit the 24h throttle). The engine never prompts; selection and
    confirmation are the caller's job (the console today, the GUI next), which keeps
    the engine surface-agnostic and testable. It is SupportsShouldProcess, so -WhatIf
    and -Confirm work for programmatic callers.
#>

Set-StrictMode -Version Latest

function Invoke-OmniRepair {
    <#
    .SYNOPSIS
        Executes selected repairs and returns a complete repair session.

    .PARAMETER Registration
        Repair registrations (from Get-OmniRepair) the caller has chosen to run.

    .PARAMETER Context
        Repair context from New-OmniRepairContext (logger, IsAdmin, DryRun, token).

    .PARAMETER SkipRestorePoint
        Do not create a restore point even if a selected repair requests one.

    .PARAMETER ProgressCallback
        Optional scriptblock invoked as each repair starts/finishes. Receives
        @{ Index; Total; Name; Phase('Start'|'Done'|'Skipped'); PercentComplete; Result }.

    .OUTPUTS
        OmniDiag.RepairSession
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object[]] $Registration,
        [Parameter(Mandatory)] [pscustomobject] $Context,
        [switch] $SkipRestorePoint,
        [scriptblock] $ProgressCallback
    )

    $log = $Context.Logger
    $token = $Context.CancellationToken
    $selected = @($Registration | Where-Object { $_ })
    $total = $selected.Count
    $sessionStart = Get-Date

    $log.Info("Starting repair session: $total repair(s), dryRun=$($Context.DryRun), admin=$($Context.IsAdmin)", 'RepairEngine')

    $report = {
        param($idx, $name, $phase, $result)
        if ($ProgressCallback) {
            $percent = if ($total -gt 0) { [int]([math]::Round(($idx / $total) * 100)) } else { 100 }
            try {
                & $ProgressCallback ([pscustomobject]@{
                    Index = $idx; Total = $total; Name = $name; Phase = $phase
                    PercentComplete = $percent; Result = $result
                })
            } catch { $log.Warn("Repair progress callback threw: $($_.Exception.Message)", 'RepairEngine') }
        }
    }

    # --- One restore point up front, if any selected repair wants one ----------
    $restorePoint = $null
    $needsRestore = @($selected | Where-Object { $_.RestorePoint }).Count -gt 0
    if ($needsRestore -and -not $Context.DryRun -and -not $SkipRestorePoint) {
        $restorePoint = New-OmniRestorePoint -Description 'OmniDiag repair checkpoint' -Logger $log
    } elseif ($needsRestore -and $Context.DryRun) {
        $log.Info('[dry-run] Would create a System Restore checkpoint before the selected repairs.', 'RepairEngine')
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $cancelled = $false

    for ($i = 0; $i -lt $total; $i++) {
        $reg = $selected[$i]

        if ($token.IsCancellationRequested) {
            $log.Warn("Cancellation requested; stopping before repair '$($reg.Name)'.", 'RepairEngine')
            $cancelled = $true
            break
        }

        & $report ($i) $reg.Name 'Start' $null

        # Gracefully skip admin-only repairs when not elevated.
        if ($reg.RequiresAdmin -and -not $Context.IsAdmin) {
            $skip = New-OmniRepairResult -Name $reg.Name -Category $reg.Category
            Add-OmniRepairStep -Result $skip -Description 'Requires administrator rights' -Succeeded $false `
                -Output 'Re-run OmniDiag elevated to apply this repair.'
            Complete-OmniRepairResult -Result $skip -Status 'Skipped' | Out-Null
            $results.Add($skip)
            $log.Warn("Skipped repair '$($reg.Name)': requires administrator.", 'RepairEngine')
            & $report ($i + 1) $reg.Name 'Skipped' $skip
            continue
        }

        # -WhatIf path (programmatic). The context DryRun flag is the user-facing
        # dry-run and still invokes the action's describe path.
        if (-not $Context.DryRun -and -not $PSCmdlet.ShouldProcess($reg.Name, 'Run repair')) {
            $skip = New-OmniRepairResult -Name $reg.Name -Category $reg.Category
            Complete-OmniRepairResult -Result $skip -Status 'Skipped' | Out-Null
            $results.Add($skip)
            & $report ($i + 1) $reg.Name 'Skipped' $skip
            continue
        }

        $log.Info("Running repair '$($reg.Name)'...", 'RepairEngine')
        try {
            $result = & $reg.ModuleInfo { param($ctx) Invoke-OmniRepairAction -Context $ctx } $Context
            if ($null -eq $result) { throw "Repair '$($reg.Name)' returned no result." }
            if (-not $result.EndTime) { Complete-OmniRepairResult -Result $result | Out-Null }
            $results.Add($result)
            $log.Info("Repair '$($reg.Name)' finished: status=$($result.Status), $($result.DurationMs)ms", 'RepairEngine')
        } catch {
            $err = New-OmniRepairResult -Name $reg.Name -Category $reg.Category
            $err.Error = $_.Exception.Message
            Add-OmniRepairStep -Result $err -Description 'Unhandled error' -Succeeded $false -Output $_.Exception.Message
            Complete-OmniRepairResult -Result $err -Status 'Failed' | Out-Null
            $results.Add($err)
            $log.Error("Repair '$($reg.Name)' threw: $($_.Exception.Message)", 'RepairEngine')
        }

        & $report ($i + 1) $reg.Name 'Done' $results[$results.Count - 1]
    }

    $sessionEnd = Get-Date
    $rebootRequired = @($results | Where-Object { $_.RebootRequired -or $_.Status -eq 'RebootRequired' }).Count -gt 0

    $session = [pscustomobject]@{
        PSTypeName     = 'OmniDiag.RepairSession'
        StartTime      = $sessionStart
        EndTime        = $sessionEnd
        DurationMs     = [int]([math]::Round(($sessionEnd - $sessionStart).TotalMilliseconds))
        DryRun         = $Context.DryRun
        Cancelled      = $cancelled
        RestorePoint   = $restorePoint
        RebootRequired = $rebootRequired
        Host           = $Context.Host
        Results        = @($results)
    }

    $log.Info("Repair session finished: $($results.Count) run, reboot=$rebootRequired, cancelled=$cancelled, $($session.DurationMs)ms", 'RepairEngine')
    return $session
}

Export-ModuleMember -Function 'Invoke-OmniRepair'
