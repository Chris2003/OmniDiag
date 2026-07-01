<#
.SYNOPSIS
    The OmniDiag orchestration engine.

.DESCRIPTION
    Runs a set of registered diagnostic modules against a shared context,
    honoring cooperative cancellation, reporting progress via a callback, and
    capturing per-module errors instead of letting one module abort the session.
    Produces an OmniDiag.Session containing every result plus a scored summary.

    Execution model (Milestone 1): modules run sequentially, with the cancellation
    token checked before each module and surfaced to the module via the context so
    long-running modules can cooperate. The interface is intentionally shaped so a
    runspace-pool parallel executor can be substituted later (Milestone 5, GUI)
    without changing any module or caller.
#>

Set-StrictMode -Version Latest

function Invoke-OmniSession {
    <#
    .SYNOPSIS
        Executes diagnostic modules and returns a complete session result.

    .PARAMETER Registration
        Module registrations from Get-OmniModule.

    .PARAMETER Context
        Execution context from New-OmniContext (logger, time range, token, etc.).

    .PARAMETER ProgressCallback
        Optional scriptblock invoked as each module starts/finishes. Receives a
        single PSCustomObject: @{ Index; Total; Name; Phase('Start'|'Done'|'Skipped');
        PercentComplete; Result }. Used by the CLI and (later) the GUI.

    .PARAMETER IncludeCategory / ExcludeCategory
        Optional category filters.

    .PARAMETER IncludeModule
        Optional list of module display names to run. When supplied, only modules whose
        Name is in this list run (applied after the category filters). Lets a caller (the
        GUI scanner picker, or automation) run an arbitrary subset of individual scanners.

    .OUTPUTS
        OmniDiag.Session
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Registration,

        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [scriptblock] $ProgressCallback,

        [string[]] $IncludeCategory,

        [string[]] $ExcludeCategory,

        [string[]] $IncludeModule
    )

    $log = $Context.Logger
    $token = $Context.CancellationToken

    $modules = $Registration | Where-Object { $_.Enabled }
    if ($IncludeCategory) { $modules = $modules | Where-Object { $_.Category -in $IncludeCategory } }
    if ($ExcludeCategory) { $modules = $modules | Where-Object { $_.Category -notin $ExcludeCategory } }
    if ($IncludeModule)   { $modules = $modules | Where-Object { $_.Name -in $IncludeModule } }
    $modules = @($modules)

    $sessionStart = Get-Date
    $results = [System.Collections.Generic.List[object]]::new()
    $total = $modules.Count
    $cancelled = $false

    $log.Info("Starting diagnostic session: $total module(s), range '$($Context.TimeRange.Label)', admin=$($Context.IsAdmin)", 'Engine')

    $report = {
        param($idx, $name, $phase, $result)
        if ($ProgressCallback) {
            $percent = if ($total -gt 0) { [int]([math]::Round(($idx / $total) * 100)) } else { 100 }
            $payload = [pscustomobject]@{
                Index           = $idx
                Total           = $total
                Name            = $name
                Phase           = $phase
                PercentComplete = $percent
                Result          = $result
            }
            try { & $ProgressCallback $payload } catch { $log.Warn("Progress callback threw: $($_.Exception.Message)", 'Engine') }
        }
    }

    for ($i = 0; $i -lt $total; $i++) {
        $reg = $modules[$i]

        if ($token.IsCancellationRequested) {
            $log.Warn("Cancellation requested; stopping before module '$($reg.Name)'.", 'Engine')
            $cancelled = $true
            break
        }

        & $report ($i) $reg.Name 'Start' $null

        # Gracefully skip admin-only modules when not elevated.
        if ($reg.RequiresAdmin -and -not $Context.IsAdmin) {
            $skip = New-OmniResult -ModuleName $reg.Name -Category $reg.Category -RequiresAdmin $true -HadAdmin $false
            Add-OmniFinding -Result $skip -Finding (New-OmniFinding -Title "$($reg.Name) skipped (requires administrator)" `
                -Severity 'Information' -Component $reg.Category `
                -Detail "This check needs elevated rights to read its data source." `
                -Recommendation 'Re-run OmniDiag as Administrator to include this module.')
            Complete-OmniResult -Result $skip -Status 'Skipped' | Out-Null
            $results.Add($skip)
            $log.Warn("Skipped '$($reg.Name)': requires administrator.", 'Engine')
            & $report ($i + 1) $reg.Name 'Skipped' $skip
            continue
        }

        $log.Info("Running module '$($reg.Name)'...", 'Engine')
        try {
            $result = & $reg.ModuleInfo { param($ctx) Invoke-OmniModuleScan -Context $ctx } $Context

            if ($null -eq $result) {
                throw "Module '$($reg.Name)' returned no result."
            }
            # Defensive: ensure timing/status are finalized even if the module forgot.
            if (-not $result.EndTime) { Complete-OmniResult -Result $result | Out-Null }
            $results.Add($result)
            $log.Info("Module '$($reg.Name)' completed: status=$($result.Status), findings=$($result.Findings.Count), $($result.DurationMs)ms", 'Engine')
        } catch {
            $errResult = New-OmniResult -ModuleName $reg.Name -Category $reg.Category -RequiresAdmin $reg.RequiresAdmin -HadAdmin $Context.IsAdmin
            $errResult.Error = $_.Exception.Message
            Add-OmniFinding -Result $errResult -Finding (New-OmniFinding -Title "$($reg.Name) failed to run" `
                -Severity 'Error' -Component $reg.Category `
                -Detail $_.Exception.Message `
                -LikelyCause 'The module raised an unhandled exception.' `
                -Recommendation 'Check the OmniDiag log for the full error and stack trace.')
            Complete-OmniResult -Result $errResult -Status 'Failed' | Out-Null
            $results.Add($errResult)
            $log.Error("Module '$($reg.Name)' threw: $($_.Exception.Message)", 'Engine')
        }

        & $report ($i + 1) $reg.Name 'Done' $results[$results.Count - 1]
    }

    $sessionEnd = Get-Date
    $summary = if ($results.Count -gt 0) { $results | Get-OmniHealthScore } else { $null }

    $session = [pscustomobject]@{
        PSTypeName   = 'OmniDiag.Session'
        StartTime    = $sessionStart
        EndTime      = $sessionEnd
        DurationMs   = [int]([math]::Round(($sessionEnd - $sessionStart).TotalMilliseconds))
        Cancelled    = $cancelled
        TimeRange    = $Context.TimeRange
        Host         = $Context.Host
        IsAdmin      = $Context.IsAdmin
        Results      = @($results)
        Summary      = $summary
    }

    $log.Info("Session finished: score=$(if($summary){$summary.Score}else{'n/a'}), duration=$($session.DurationMs)ms, cancelled=$cancelled", 'Engine')
    return $session
}

Export-ModuleMember -Function 'Invoke-OmniSession'
