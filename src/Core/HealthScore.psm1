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

# Per-severity score penalty model. The penalty for a severity SATURATES as the
# count grows: penalty = Cap * (1 - Decay^count). The first finding of a severity
# costs the most; each additional one adds less, approaching (never exceeding) Cap.
# This keeps a large volume of lower-severity findings - e.g. weeks of historical
# Event Log errors - from instantly zeroing an otherwise-serviceable machine, while
# still letting genuine Critical findings drive the score down hard.
$script:OmniSeverityWeight = @{
    Critical    = @{ Cap = 60; Decay = 0.55 }
    Error       = @{ Cap = 35; Decay = 0.82 }
    Warning     = @{ Cap = 18; Decay = 0.88 }
    Information = @{ Cap = 0;  Decay = 1.0 }
    Pass        = @{ Cap = 0;  Decay = 1.0 }
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
        $findings = [System.Collections.Generic.List[object]]::new()

        foreach ($r in $all) {
            foreach ($f in $r.Findings) {
                $findings.Add($f)
                if ($counts.Contains($f.Severity)) { $counts[$f.Severity]++ }
            }
        }

        # Reduce the score by a saturating penalty per severity (see the weight
        # table above): penalty = Cap * (1 - Decay^count).
        $score = 100.0
        foreach ($sev in @('Critical', 'Error', 'Warning')) {
            $n = $counts[$sev]
            if ($n -gt 0) {
                $w = $script:OmniSeverityWeight[$sev]
                $score -= [double]$w.Cap * (1.0 - [math]::Pow([double]$w.Decay, $n))
            }
        }

        if ($score -lt 0)   { $score = 0 }
        if ($score -gt 100) { $score = 100 }
        $score = [int][math]::Round($score)

        $grade = switch ($score) {
            { $_ -ge 80 } { 'Healthy'; break }
            { $_ -ge 50 } { 'Warning'; break }
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
