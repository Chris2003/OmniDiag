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

    Audit log (0.8.0): every repair the engine actually executes (not a dry run, not
    skipped) appends one JSON line per recorded step to
    OmniDiagData\logs\repair-audit.jsonl, so the console, the CLI, the GUI, and the
    cmdlets all leave the same local trail. Dry runs are never written to the audit log:
    they change nothing, and their description is in the run's own log file. Each line:
        { time (ISO-8601 UTC), repairId, repairName, repairStatus, step, succeeded,
          output (at most 2000 characters), dryRun: false, user, computer, restorePoint }
    restorePoint is the checkpoint status for the run: Created, RecentExisting, Skipped,
    Failed, NotRequested (no selected repair asked for one), or SkippedByCaller.
#>

Set-StrictMode -Version Latest

$script:OmniRepairAuditMaxOutput = 2000

function Get-OmniRepairAuditPath {
    <#
    .SYNOPSIS
        Returns the path of the repair audit log (OmniDiagData\logs\repair-audit.jsonl).

    .EXAMPLE
        Get-Content (Get-OmniRepairAuditPath) | ConvertFrom-Json
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-OmniDataPath -Kind Logs -ChildPath 'repair-audit.jsonl')
}

function Write-OmniRepairAudit {
    <#
    .SYNOPSIS
        Internal: appends one JSON line per step of an executed (non-dry-run) repair.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Registration,
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] $Context,
        [string] $RestorePointStatus
    )
    $hostInfo = $null
    if ($Context.PSObject.Properties['Host']) { $hostInfo = $Context.Host }
    $user = if ($hostInfo -and $hostInfo.PSObject.Properties['UserName']) { [string]$hostInfo.UserName } else { [System.Environment]::UserName }
    $computer = if ($hostInfo -and $hostInfo.PSObject.Properties['ComputerName']) { [string]$hostInfo.ComputerName } else { [System.Environment]::MachineName }
    $steps = @($Result.Steps)
    if ($steps.Count -eq 0) {
        $steps = @([pscustomobject]@{ Description = '(no steps recorded)'; Succeeded = ($Result.Status -ne 'Failed'); Output = [string]$Result.Error; Timestamp = (Get-Date) })
    }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($step in $steps) {
        $output = [string]$step.Output
        if ($output.Length -gt $script:OmniRepairAuditMaxOutput) { $output = $output.Substring(0, $script:OmniRepairAuditMaxOutput) }
        $when = Get-Date
        if ($step.PSObject.Properties['Timestamp'] -and $step.Timestamp -is [datetime]) { $when = $step.Timestamp }
        $entry = [ordered]@{
            time         = $when.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
            repairId     = [string]$Registration.Id
            repairName   = [string]$Registration.Name
            repairStatus = [string]$Result.Status
            step         = [string]$step.Description
            succeeded    = [bool]$step.Succeeded
            output       = $output
            dryRun       = $false
            user         = $user
            computer     = $computer
            restorePoint = $RestorePointStatus
        }
        [void]$sb.Append(($entry | ConvertTo-Json -Compress -Depth 3)).Append("`n")
    }
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::AppendAllText($Path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}

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

    .PARAMETER AuditLogPath
        Where applied steps are logged. Default: OmniDiagData\logs\repair-audit.jsonl
        (or the repair context's Config['AuditLogPath']).

    .OUTPUTS
        OmniDiag.RepairSession

    .NOTES
        Deprecated as a user-facing command in 0.8.0: use Invoke-OmniDiagRepair, which
        adds -WhatIf / -Confirm handling and the exit code. OmniDiag's own surfaces
        (console, CLI, GUI) keep calling this engine without a warning.

    .EXAMPLE
        $ctx = New-OmniRepairContext -Logger (New-OmniLogger) -DryRun
        Invoke-OmniRepair -Registration (Get-OmniRepair -Path .\src\Repairs) -Context $ctx
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object[]] $Registration,
        [Parameter(Mandatory)] [pscustomobject] $Context,
        [switch] $SkipRestorePoint,
        # Run RestorePoint repairs even when no restore point could be created or found.
        [switch] $AllowWithoutRestorePoint,
        [scriptblock] $ProgressCallback,
        [string] $AuditLogPath
    )

    if (Get-Command Write-OmniDeprecationWarning -ErrorAction SilentlyContinue) {
        Write-OmniDeprecationWarning -Name 'Invoke-OmniRepair' -Replacement 'Invoke-OmniDiagRepair'
    }

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

    $restoreStatus = 'SkippedByCaller'
    if ($restorePoint) { $restoreStatus = [string]$restorePoint.Status }
    elseif (-not $needsRestore) { $restoreStatus = 'NotRequested' }
    if (-not $AuditLogPath -and $Context.PSObject.Properties['Config'] -and $Context.Config -is [System.Collections.IDictionary] -and
        $Context.Config.Contains('AuditLogPath') -and $Context.Config['AuditLogPath']) {
        $AuditLogPath = [string]$Context.Config['AuditLogPath']
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

        # Gracefully skip admin-only repairs when not elevated - but only for real
        # execution. A dry-run changes nothing and needs no elevation, so it still
        # describes admin-only repairs (status DryRun) rather than skipping them.
        if ($reg.RequiresAdmin -and -not $Context.IsAdmin -and -not $Context.DryRun) {
            $skip = New-OmniRepairResult -Name $reg.Name -Category $reg.Category
            Add-OmniRepairStep -Result $skip -Description 'Requires administrator rights' -Succeeded $false `
                -Output 'Re-run OmniDiag elevated to apply this repair.'
            Complete-OmniRepairResult -Result $skip -Status 'Skipped' | Out-Null
            $results.Add($skip)
            $log.Warn("Skipped repair '$($reg.Name)': requires administrator.", 'RepairEngine')
            & $report ($i + 1) $reg.Name 'Skipped' $skip
            continue
        }

        # Repairs that promise a restore point never run without one, unless the caller
        # explicitly opted out (-SkipRestorePoint / -AllowWithoutRestorePoint).
        if ($reg.RestorePoint -and -not $Context.DryRun -and -not $SkipRestorePoint -and -not $AllowWithoutRestorePoint -and
            -not ($restorePoint -and $restorePoint.PSObject.Properties['Protected'] -and $restorePoint.Protected)) {
            $skip = New-OmniRepairResult -Name $reg.Name -Category $reg.Category
            $why = if ($restorePoint) { $restorePoint.Message } else { 'No restore point was attempted.' }
            Add-OmniRepairStep -Result $skip -Description 'Requires a System Restore point' -Succeeded $false `
                -Output "$why Enable System Restore on the system drive, or re-run with -AllowRepairWithoutRestorePoint to proceed anyway."
            Complete-OmniRepairResult -Result $skip -Status 'Skipped' | Out-Null
            $results.Add($skip)
            $log.Warn("Skipped repair '$($reg.Name)': no restore point.", 'RepairEngine')
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
            # Dry-run is an engine-level guarantee, even when a plugin's read-only
            # discovery returns early without invoking an individual repair step.
            # Normalize both status and reboot state so callers can trust the session.
            if ($Context.DryRun) {
                $result.RebootRequired = $false
                Complete-OmniRepairResult -Result $result -Status 'DryRun' | Out-Null
            } elseif (-not $result.EndTime) {
                Complete-OmniRepairResult -Result $result | Out-Null
            }
            $results.Add($result)
            $log.Info("Repair '$($reg.Name)' finished: status=$($result.Status), $($result.DurationMs)ms", 'RepairEngine')
        } catch {
            $err = New-OmniRepairResult -Name $reg.Name -Category $reg.Category
            $err.Error = $_.Exception.Message
            Add-OmniRepairStep -Result $err -Description 'Unhandled error' -Succeeded $false -Output $_.Exception.Message
            # A discovery command can be unavailable on a non-Windows host during
            # dry-run. Preserve the error evidence, but keep the engine's strongest
            # contract: DryRun means no mutation was attempted and is reported as
            # such. Real executions continue to fail normally.
            $errorStatus = if ($Context.DryRun) { 'DryRun' } else { 'Failed' }
            Complete-OmniRepairResult -Result $err -Status $errorStatus | Out-Null
            $results.Add($err)
            $log.Error("Repair '$($reg.Name)' threw: $($_.Exception.Message)", 'RepairEngine')
        }

        # Audit trail of applied changes (never for dry runs). A failure to write the
        # audit line is logged but does not undo or fail the repair that already ran.
        if (-not $Context.DryRun) {
            try {
                $auditPath = $AuditLogPath
                if (-not $auditPath) { $auditPath = Get-OmniRepairAuditPath }
                Write-OmniRepairAudit -Path $auditPath -Registration $reg -Result $results[$results.Count - 1] `
                    -Context $Context -RestorePointStatus $restoreStatus
            } catch {
                $log.Warn("Could not write the repair audit log: $($_.Exception.Message)", 'RepairEngine')
            }
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

Export-ModuleMember -Function @('Invoke-OmniRepair', 'Get-OmniRepairAuditPath')
