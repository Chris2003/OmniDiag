<#
.SYNOPSIS
    Console presentation for OmniDiag (Milestone 1 runner).

.DESCRIPTION
    Renders the dashboard summary and a live progress callback to the host. This
    is the interim front-end until the WPF GUI lands (Milestone 5); the full
    HTML/JSON/CSV reporting engine arrives in Milestone 4. Kept deliberately
    presentation-only so it has no dependency on how a session was produced.
#>

Set-StrictMode -Version Latest

function Get-OmniStatusColor {
    param([string] $Status)
    switch ($Status) {
        'Healthy'  { 'Green' }
        'Pass'     { 'Green' }
        'Warning'  { 'Yellow' }
        'Critical' { 'Red' }
        'Failed'   { 'Red' }
        'Error'    { 'Red' }
        'Skipped'  { 'DarkGray' }
        default    { 'Gray' }
    }
}

function New-OmniConsoleProgressCallback {
    <#
    .SYNOPSIS
        Builds a progress scriptblock for Invoke-OmniSession that drives the
        built-in Write-Progress bar plus a one-line-per-module status feed.
    #>
    [OutputType([scriptblock])]
    param()
    return {
        param($p)
        Write-Progress -Activity 'OmniDiag scan' -Status "$($p.Name) [$($p.Phase)]" -PercentComplete $p.PercentComplete
        if ($p.Phase -eq 'Done' -and $p.Result) {
            $color = Get-OmniStatusColor $p.Result.Status
            $line = "  [{0,3}%] {1,-26} {2,-9} {3} finding(s), {4} ms" -f `
                $p.PercentComplete, $p.Name, $p.Result.Status, $p.Result.Findings.Count, $p.Result.DurationMs
            Write-Host $line -ForegroundColor $color
        } elseif ($p.Phase -eq 'Skipped') {
            Write-Host ("  [{0,3}%] {1,-26} {2}" -f $p.PercentComplete, $p.Name, 'Skipped (admin required)') -ForegroundColor DarkGray
        }
    }
}

function Write-OmniConsoleDashboard {
    <#
    .SYNOPSIS
        Prints the dashboard summary for a completed session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session
    )

    $s = $Session.Summary
    Write-Host ''
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host '  OmniDiag  -  One Tool. Complete Diagnostics.' -ForegroundColor Cyan
    Write-Host '======================================================================' -ForegroundColor Cyan

    Write-Host ("  Computer    : {0}" -f $Session.Host.ComputerName)
    Write-Host ("  User        : {0}" -f $Session.Host.UserName)
    Write-Host ("  Time range  : {0}" -f $Session.TimeRange.Label)
    if ($Session.PSObject.Properties['ScanPlan'] -and $Session.ScanPlan) {
        Write-Host ("  Scan plan   : {0} ({1})" -f $Session.ScanPlan.Name, $Session.ScanPlan.Type)
    }
    Write-Host ("  Elevated    : {0}" -f $Session.IsAdmin)
    Write-Host ("  Duration    : {0:N1} s" -f ($Session.DurationMs / 1000))
    if ($Session.Cancelled) { Write-Host '  ** SESSION CANCELLED **' -ForegroundColor Yellow }

    if ($s) {
        Write-Host ''
        Write-Host ("  HEALTH SCORE: {0}/100  ({1})" -f $s.Score, $s.Grade) -ForegroundColor (Get-OmniStatusColor $s.Grade)
        Write-Host ("  Critical {0}  |  Error {1}  |  Warning {2}  |  Info {3}  |  Pass {4}" -f `
            $s.Counts.Critical, $s.Counts.Error, $s.Counts.Warning, $s.Counts.Information, $s.Counts.Pass)

        Write-Host ''
        Write-Host '  Modules:' -ForegroundColor Cyan
        foreach ($r in $Session.Results) {
            Write-Host ("    {0,-28} {1}" -f $r.ModuleName, $r.Status) -ForegroundColor (Get-OmniStatusColor $r.Status)
        }

        if ($s.TopRecommendations.Count -gt 0) {
            Write-Host ''
            Write-Host '  Top recommendations:' -ForegroundColor Cyan
            $n = 1
            foreach ($f in $s.TopRecommendations) {
                Write-Host ("    {0}. [{1}] {2}" -f $n, $f.Severity, $f.Title) -ForegroundColor (Get-OmniStatusColor $f.Severity)
                Write-Host ("       -> {0}" -f $f.Recommendation) -ForegroundColor Gray
                $n++
            }
        }
    }
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host ''
}

Export-ModuleMember -Function @(
    'Get-OmniStatusColor', 'New-OmniConsoleProgressCallback', 'Write-OmniConsoleDashboard'
)
