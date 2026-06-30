<#
.SYNOPSIS
    Interactive console for the OmniDiag Repair Center.

.DESCRIPTION
    Presents the discovered repair catalog (grouped by category, with repairs relevant
    to the current scan flagged Recommended), lets the technician pick repairs, confirms
    each one individually with its risk/restore-point/reboot implications, then runs the
    confirmed set through Invoke-OmniRepair and prints the outcome. Presentation-only:
    all execution and safety logic lives in the repair engine.

    Selection + per-action confirmation is deliberately the console's job, not the
    engine's - the engine stays surface-agnostic so the GUI can reuse it unchanged.
#>

Set-StrictMode -Version Latest

function Get-OmniRepairRiskColor {
    param([string] $Risk)
    switch ($Risk) {
        'Safe'        { 'Green' }
        'Moderate'    { 'Yellow' }
        'Destructive' { 'Red' }
        default       { 'Gray' }
    }
}

function Get-OmniRepairStatusColor {
    param([string] $Status)
    switch ($Status) {
        'Succeeded'      { 'Green' }
        'DryRun'         { 'Cyan' }
        'RebootRequired' { 'Yellow' }
        'Skipped'        { 'DarkGray' }
        'Failed'         { 'Red' }
        default          { 'Gray' }
    }
}

function Invoke-OmniRepairConsole {
    <#
    .SYNOPSIS
        Runs the interactive Repair Center against an (optional) scan session.

    .PARAMETER Session
        The OmniDiag.Session from a scan; used to flag Recommended repairs. Optional.

    .PARAMETER DryRun
        Run every selected repair in dry-run mode (describe only; no system changes).

    .PARAMETER RepairsPath
        Folder of repair plugins. Defaults to the sibling src/Repairs folder.

    .PARAMETER LogPath
        Structured log path for the repair run. Defaults to a per-run temp file.
    #>
    [CmdletBinding()]
    param(
        [pscustomobject] $Session,
        [switch] $DryRun,
        [string] $RepairsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Repairs'),
        [string] $LogPath
    )

    if (-not $LogPath) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $LogPath = Join-Path ([System.IO.Path]::GetTempPath()) "OmniDiag/omnidiag-repair-$stamp.jsonl"
    }
    $logger = New-OmniLogger -Path $LogPath -MinimumLevel Info -Console:$false

    $repairs = @(Get-OmniRepair -Path $RepairsPath -Logger $logger)
    if ($Session) { $repairs = @(Get-OmniApplicableRepair -Registration $repairs -Session $Session) }
    if ($repairs.Count -eq 0) {
        Write-Host 'No repairs are available.' -ForegroundColor Yellow
        return
    }

    $isAdmin = Test-OmniIsAdministrator

    Write-Host ''
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host '  OmniDiag Repair Center' -ForegroundColor Cyan
    if ($DryRun) { Write-Host '  (DRY RUN - no changes will be made)' -ForegroundColor Cyan }
    Write-Host '======================================================================' -ForegroundColor Cyan
    if (-not $isAdmin) {
        Write-Host '  Not elevated: repairs marked (admin) will be unavailable until you re-run elevated.' -ForegroundColor DarkYellow
    }
    Write-Host '  Legend: * = recommended for this scan   [Risk]   (admin) = needs elevation' -ForegroundColor DarkGray
    Write-Host ''

    # --- Print catalog, numbered, grouped by category ----------------------
    $index = 0
    $numbered = [System.Collections.Generic.List[object]]::new()
    foreach ($group in ($repairs | Group-Object Category)) {
        Write-Host ("  {0}" -f $group.Name) -ForegroundColor Cyan
        foreach ($reg in $group.Group) {
            $index++
            $numbered.Add($reg)
            $star = if ($reg.Recommended) { '*' } else { ' ' }
            $adminTag = if ($reg.RequiresAdmin) { ' (admin)' } else { '' }
            $line = "   {0}{1,2}. {2,-36} [{3}]{4}" -f $star, $index, $reg.Name, $reg.Risk, $adminTag
            Write-Host $line -ForegroundColor (Get-OmniRepairRiskColor $reg.Risk)
            Write-Host ("        {0}" -f $reg.Description) -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    # --- Selection ---------------------------------------------------------
    Write-Host '  Select repairs to run: numbers (e.g. 1,3 5), "r" recommended, "a" all, Enter to cancel.' -ForegroundColor Gray
    $answer = Read-Host '  Selection'
    if ([string]::IsNullOrWhiteSpace($answer)) { Write-Host '  Cancelled.' -ForegroundColor DarkGray; return }

    $chosen = [System.Collections.Generic.List[object]]::new()
    switch -Regex ($answer.Trim().ToLowerInvariant()) {
        '^a(ll)?$' { foreach ($r in $numbered) { $chosen.Add($r) }; break }
        '^r(ec.*)?$' { foreach ($r in $numbered) { if ($r.Recommended) { $chosen.Add($r) } }; break }
        default {
            foreach ($tok in ($answer -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
                $n = [int]$tok
                if ($n -ge 1 -and $n -le $numbered.Count) { $chosen.Add($numbered[$n - 1]) }
            }
        }
    }
    $chosen = @($chosen | Select-Object -Unique)
    if ($chosen.Count -eq 0) { Write-Host '  Nothing selected.' -ForegroundColor DarkGray; return }

    # --- Per-action confirmation ------------------------------------------
    $confirmed = [System.Collections.Generic.List[object]]::new()
    Write-Host ''
    foreach ($reg in $chosen) {
        $prefix = if ($DryRun) { '[dry run] ' } else { '' }
        Write-Host ("  {0}{1}  [{2}]" -f $prefix, $reg.Name, $reg.Risk) -ForegroundColor (Get-OmniRepairRiskColor $reg.Risk)
        if ($reg.RequiresAdmin -and -not $isAdmin) {
            Write-Host '      Requires administrator - it will be skipped on this non-elevated run.' -ForegroundColor DarkYellow
        }
        if ($reg.RestorePoint -and -not $DryRun) { Write-Host '      A System Restore point will be created before running.' -ForegroundColor Gray }
        if ($reg.RebootHint) { Write-Host '      A reboot will be required to fully apply this repair.' -ForegroundColor Gray }
        $ans = Read-Host '      Run this repair? [y/N]'
        if ($ans -match '^(y|yes)$') { $confirmed.Add($reg) }
    }
    $confirmed = @($confirmed)
    if ($confirmed.Count -eq 0) { Write-Host ''; Write-Host '  No repairs confirmed.' -ForegroundColor DarkGray; return }

    # --- Run ---------------------------------------------------------------
    Write-Host ''
    Write-Host ("  Running {0} repair(s)..." -f $confirmed.Count) -ForegroundColor Cyan
    $ctx = New-OmniRepairContext -Logger $logger -DryRun:$DryRun
    $progress = {
        param($p)
        if ($p.Phase -eq 'Done' -and $p.Result) {
            Write-Host ("    {0,-40} {1}" -f $p.Name, $p.Result.Status) -ForegroundColor (Get-OmniRepairStatusColor $p.Result.Status)
        } elseif ($p.Phase -eq 'Skipped') {
            Write-Host ("    {0,-40} {1}" -f $p.Name, 'Skipped') -ForegroundColor DarkGray
        }
    }
    $repairSession = Invoke-OmniRepair -Registration $confirmed -Context $ctx -ProgressCallback $progress

    Write-OmniRepairSummary -RepairSession $repairSession -LogPath $LogPath
    return $repairSession
}

function Write-OmniRepairSummary {
    <# .SYNOPSIS Prints the outcome of a repair session. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $RepairSession,
        [string] $LogPath
    )

    Write-Host ''
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '  Repair results' -ForegroundColor Cyan
    if ($RepairSession.DryRun) { Write-Host '  (dry run - nothing was changed)' -ForegroundColor Cyan }
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Cyan

    if ($RepairSession.RestorePoint) {
        $rp = $RepairSession.RestorePoint
        $rpColor = if ($rp.Created) { 'Green' } else { 'Yellow' }
        Write-Host ("  Restore point: {0} - {1}" -f $rp.Status, $rp.Message) -ForegroundColor $rpColor
    }

    foreach ($r in $RepairSession.Results) {
        Write-Host ("  {0,-40} {1}" -f $r.Name, $r.Status) -ForegroundColor (Get-OmniRepairStatusColor $r.Status)
        foreach ($step in $r.Steps) {
            $mark = if ($step.Succeeded) { 'ok ' } else { 'FAIL' }
            $markColor = if ($step.Succeeded) { 'DarkGray' } else { 'Red' }
            Write-Host ("      [{0}] {1}" -f $mark, $step.Description) -ForegroundColor $markColor
        }
    }

    if ($RepairSession.RebootRequired) {
        Write-Host ''
        Write-Host '  ** A RESTART IS REQUIRED to finish applying one or more repairs. **' -ForegroundColor Yellow
    }
    if ($LogPath) { Write-Host ("  Repair log: {0}" -f $LogPath) -ForegroundColor DarkGray }
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
}

Export-ModuleMember -Function @('Invoke-OmniRepairConsole', 'Write-OmniRepairSummary')
