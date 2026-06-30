<#
.SYNOPSIS
    Computes the 0-100 overall health score and dashboard roll-ups.

.DESCRIPTION
    Turns a set of module results into the headline metrics the dashboard needs:
    a 0-100 score, severity counts, per-category status, and the top
    recommendations. The score starts at 100 and is reduced by weighted penalties
    per finding severity, then clamped to [0,100].
#>

Set-StrictMode -Version Latest

# Penalty applied to the running score per finding, by severity.
$script:OmniSeverityPenalty = @{
    Critical    = 30
    Error       = 12
    Warning     = 4
    Information = 0
    Pass        = 0
}

function Get-OmniHealthScore {
    <#
    .SYNOPSIS
        Aggregates module results into a scored dashboard summary.

    .PARAMETER Result
        One or more OmniDiag.Result objects (pipeline-friendly).

    .OUTPUTS
        OmniDiag.HealthSummary with Score, Grade, severity Counts, Categories,
        and TopRecommendations.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $Result
    )

    begin {
        $all = [System.Collections.Generic.List[object]]::new()
    }
    process {
        foreach ($r in $Result) { if ($null -ne $r) { $all.Add($r) } }
    }
    end {
        $counts = [ordered]@{ Critical = 0; Error = 0; Warning = 0; Information = 0; Pass = 0 }
        $score = 100.0
        $findings = [System.Collections.Generic.List[object]]::new()

        foreach ($r in $all) {
            foreach ($f in $r.Findings) {
                $findings.Add($f)
                if ($counts.Contains($f.Severity)) { $counts[$f.Severity]++ }
                $score -= ($script:OmniSeverityPenalty[$f.Severity])
            }
        }

        if ($score -lt 0)   { $score = 0 }
        if ($score -gt 100) { $score = 100 }
        $score = [int][math]::Round($score)

        $grade = switch ($score) {
            { $_ -ge 90 } { 'Healthy'; break }
            { $_ -ge 70 } { 'Warning'; break }
            default       { 'Critical' }
        }

        $categories = foreach ($grp in ($all | Group-Object Category)) {
            $worst = ($grp.Group | ForEach-Object {
                switch ($_.Status) {
                    'Critical' { 3 } 'Failed' { 3 }
                    'Warning'  { 2 }
                    'Healthy'  { 1 }
                    default    { 0 }
                }
            } | Measure-Object -Maximum).Maximum
            [pscustomobject]@{
                Category = $grp.Name
                Status   = switch ($worst) { 3 { 'Critical' } 2 { 'Warning' } 1 { 'Healthy' } default { 'Unknown' } }
                Modules  = $grp.Count
            }
        }

        # Top recommendations: most severe findings that carry a recommendation.
        $topRecommendations = $findings |
            Where-Object { $_.Recommendation } |
            Sort-Object -Property SeverityRank -Descending |
            Select-Object -First 10

        return [pscustomobject]@{
            PSTypeName         = 'OmniDiag.HealthSummary'
            Score              = $score
            Grade              = $grade
            Counts             = $counts
            TotalFindings      = $findings.Count
            ModulesRun         = $all.Count
            Categories         = @($categories)
            TopRecommendations = @($topRecommendations)
            GeneratedAt        = (Get-Date)
        }
    }
}

Export-ModuleMember -Function 'Get-OmniHealthScore'
