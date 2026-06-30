<#
.SYNOPSIS
    Data models and the step runner for the OmniDiag Repair Center.

.DESCRIPTION
    Repairs are the "fix" half of OmniDiag's diagnose-first/repair-second design.
    This module defines the serialization-friendly result shapes a repair produces
    and the workhorse Invoke-OmniRepairStep, which executes a single unit of work
    while honoring dry-run, capturing output, and logging - so every repair plugin
    stays small and consistent.

    Models mirror the diagnostic side (Core/Models.psm1): typed PSCustomObjects via
    factory functions, not classes, so they cross module boundaries and serialize to
    JSON losslessly.
#>

Set-StrictMode -Version Latest

# Risk vocabulary, least-to-most impactful.
$script:OmniRepairRisk = @('Safe', 'Moderate', 'Destructive')

function Get-OmniRepairRiskNames {
    <# .SYNOPSIS Returns the valid repair risk levels. #>
    [OutputType([string[]])]
    param()
    return [string[]]$script:OmniRepairRisk
}

function New-OmniRepairResult {
    <#
    .SYNOPSIS
        Creates an empty result container for one repair run.

    .DESCRIPTION
        Populated by Invoke-OmniRepairStep (or direct property sets) and finalized by
        Complete-OmniRepairResult, which stamps timing and derives the roll-up Status.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [string] $Category = 'General'
    )

    return [pscustomobject]@{
        PSTypeName     = 'OmniDiag.RepairResult'
        Name           = $Name
        Category       = $Category
        Status         = 'Unknown'   # Succeeded | Failed | Skipped | DryRun | RebootRequired | Unknown
        Steps          = [System.Collections.Generic.List[object]]::new()
        StartTime      = (Get-Date)
        EndTime        = $null
        DurationMs     = 0
        RebootRequired = $false
        DryRun         = $false
        Error          = $null
    }
}

function Add-OmniRepairStep {
    <#
    .SYNOPSIS
        Appends a single step record to a repair result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Result,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [bool] $Succeeded,
        [string] $Output = '',
        [switch] $DryRun
    )
    [void]$Result.Steps.Add([pscustomobject]@{
        PSTypeName  = 'OmniDiag.RepairStep'
        Description = $Description
        Succeeded   = $Succeeded
        Output      = $Output
        DryRun      = [bool]$DryRun
        Timestamp   = (Get-Date)
    })
}

function Invoke-OmniRepairStep {
    <#
    .SYNOPSIS
        Runs one unit of repair work, honoring dry-run, capturing output, and logging.

    .DESCRIPTION
        The single execution primitive every repair plugin uses. When the context's
        DryRun flag is set, the action is NOT executed - the step is recorded as a
        dry-run and the result is flagged accordingly. Otherwise the action scriptblock
        runs, its output (including native stderr) is captured, and success is derived
        from a thrown exception or - for native commands - a non-zero exit code.

    .PARAMETER Action
        Scriptblock to execute (e.g. { ipconfig /flushdns }).

    .PARAMETER IgnoreExitCode
        Treat any non-zero native exit code as success anyway (some tools report
        non-zero for benign conditions, e.g. "nothing to do").

    .OUTPUTS
        [bool] - whether the step succeeded (always $true for a dry-run).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Result,
        [Parameter(Mandatory)] [pscustomobject] $Context,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [scriptblock] $Action,
        [switch] $IgnoreExitCode
    )

    $log = $Context.Logger

    if ($Context.DryRun) {
        $Result.DryRun = $true
        if ($log) { $log.Info("[dry-run] Would: $Description", 'Repair') }
        Add-OmniRepairStep -Result $Result -Description $Description -Succeeded $true `
            -Output '(dry-run: not executed)' -DryRun
        return $true
    }

    if ($log) { $log.Info("Repair step: $Description", 'Repair') }

    # Seed LASTEXITCODE so reading it under StrictMode is always safe, even when the
    # action runs only cmdlets (which don't set it).
    $global:LASTEXITCODE = 0
    try {
        $output = (& $Action 2>&1 | Out-String).Trim()
        $exit = $global:LASTEXITCODE
        $succeeded = $true
        if (-not $IgnoreExitCode -and $null -ne $exit -and $exit -ne 0) { $succeeded = $false }

        Add-OmniRepairStep -Result $Result -Description $Description -Succeeded $succeeded -Output $output
        if (-not $succeeded -and $log) { $log.Warn("Step '$Description' returned exit code $exit.", 'Repair') }
        return $succeeded
    } catch {
        Add-OmniRepairStep -Result $Result -Description $Description -Succeeded $false -Output $_.Exception.Message
        if ($log) { $log.Error("Step '$Description' failed: $($_.Exception.Message)", 'Repair') }
        return $false
    }
}

function Complete-OmniRepairResult {
    <#
    .SYNOPSIS
        Finalizes a repair result: stamps timing and derives the roll-up Status.

    .PARAMETER Status
        Optional explicit override (e.g. 'Skipped').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Result,
        [ValidateSet('Succeeded', 'Failed', 'Skipped', 'DryRun', 'RebootRequired', 'Unknown')]
        [string] $Status
    )

    $Result.EndTime = Get-Date
    $Result.DurationMs = [int]([math]::Round(($Result.EndTime - $Result.StartTime).TotalMilliseconds))

    if ($PSBoundParameters.ContainsKey('Status')) {
        $Result.Status = $Status
        return $Result
    }

    if ($Result.DryRun) {
        $Result.Status = 'DryRun'
        return $Result
    }

    $failed = @($Result.Steps | Where-Object { -not $_.Succeeded })
    if ($failed.Count -gt 0) {
        $Result.Status = 'Failed'
    } elseif ($Result.RebootRequired) {
        $Result.Status = 'RebootRequired'
    } else {
        $Result.Status = 'Succeeded'
    }
    return $Result
}

Export-ModuleMember -Function @(
    'Get-OmniRepairRiskNames', 'New-OmniRepairResult', 'Add-OmniRepairStep',
    'Invoke-OmniRepairStep', 'Complete-OmniRepairResult'
)
