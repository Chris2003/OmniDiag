<#
.SYNOPSIS
    OmniDiag reporting: self-contained HTML report.

.DESCRIPTION
    Renders an OmniDiag.Session into a single, self-contained HTML file (inline CSS,
    no external resources) suitable for sharing or archiving. Sections: executive
    summary with the 0-100 health score, device information, top recommendations,
    critical/error findings, warnings, event-log analysis (timeline + grouped
    events), per-module breakdown, passed checks, and a privacy notice.

    All user-derived text is HTML-encoded to prevent markup injection from event
    messages or device strings.
#>

Set-StrictMode -Version Latest

function Get-OmniHtmlEncode {
    param([AllowNull()] [object] $Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-OmniSeverityClass {
    param([string] $Severity)
    switch ($Severity) {
        'Critical'    { 'crit' }
        'Error'       { 'err' }
        'Warning'     { 'warn' }
        'Information' { 'info' }
        'Pass'        { 'pass' }
        default       { 'info' }
    }
}

function Get-OmniGradeClass {
    param([string] $Grade)
    switch ($Grade) {
        'Healthy'  { 'pass' }
        'Warning'  { 'warn' }
        'Critical' { 'crit' }
        default    { 'info' }
    }
}

function ConvertTo-OmniFindingHtmlRows {
    param([object[]] $Findings)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($f in $Findings) {
        $cls = Get-OmniSeverityClass $f.Severity
        [void]$sb.Append('<tr>')
        [void]$sb.Append("<td><span class='badge $cls'>$(Get-OmniHtmlEncode $f.Severity)</span></td>")
        [void]$sb.Append("<td>$(Get-OmniHtmlEncode $f.Component)</td>")
        [void]$sb.Append("<td><strong>$(Get-OmniHtmlEncode $f.Title)</strong><div class='muted'>$(Get-OmniHtmlEncode $f.Detail)</div></td>")
        [void]$sb.Append("<td>$(Get-OmniHtmlEncode $f.LikelyCause)</td>")
        [void]$sb.Append("<td>$(Get-OmniHtmlEncode $f.Recommendation)</td>")
        [void]$sb.Append('</tr>')
    }
    return $sb.ToString()
}

function Export-OmniHtmlReport {
    <#
    .SYNOPSIS
        Writes an HTML report for a session.

    .PARAMETER Session
        The OmniDiag.Session to render.

    .PARAMETER Path
        Output .html file path.

    .PARAMETER BrandName
        Optional organization name shown in the header (branding).

    .OUTPUTS
        The written file path (string).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $BrandName
    )

    $s = $Session.Summary
    $allFindings = @($Session.Results | ForEach-Object { $_.Findings })
    $crit = @($allFindings | Where-Object { $_.Severity -in @('Critical', 'Error') } | Sort-Object SeverityRank -Descending)
    $warn = @($allFindings | Where-Object { $_.Severity -eq 'Warning' })
    $pass = @($allFindings | Where-Object { $_.Severity -eq 'Pass' })

    $css = @'
<style>
:root{--bg:#0f1419;--panel:#1a212b;--panel2:#212a36;--txt:#e6edf3;--muted:#8b98a5;--line:#2d3742;
--crit:#e5484d;--err:#fb8c00;--warn:#f5c518;--info:#4493f8;--pass:#3fb950;}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);
font-family:Segoe UI,system-ui,-apple-system,Arial,sans-serif;font-size:14px;line-height:1.5}
.wrap{max-width:1100px;margin:0 auto;padding:24px}
header{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid var(--line);padding-bottom:16px;margin-bottom:24px}
h1{font-size:22px;margin:0}h2{font-size:17px;margin:28px 0 12px;border-left:3px solid var(--info);padding-left:10px}
.tag{color:var(--muted);font-size:13px}
.score{text-align:center;min-width:140px}
.score .num{font-size:46px;font-weight:700;line-height:1}
.score .lbl{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:1px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px}
.card .k{color:var(--muted);font-size:12px}.card .v{font-size:20px;font-weight:600;margin-top:4px}
table{width:100%;border-collapse:collapse;background:var(--panel);border-radius:8px;overflow:hidden}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}
th{background:var(--panel2);color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase}
tr:last-child td{border-bottom:none}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:700;color:#0b0e12}
.badge.crit{background:var(--crit);color:#fff}.badge.err{background:var(--err)}.badge.warn{background:var(--warn)}
.badge.info{background:var(--info);color:#fff}.badge.pass{background:var(--pass);color:#fff}
.txt-crit{color:var(--crit)}.txt-warn{color:var(--warn)}.txt-pass{color:var(--pass)}
.muted{color:var(--muted);font-size:12.5px;margin-top:3px}
.privacy{background:#2a1f12;border:1px solid #6b4a1f;border-radius:8px;padding:14px;margin-top:28px;color:#f0c987}
ul.recs{list-style:none;padding:0}ul.recs li{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:10px 12px;margin-bottom:8px}
.tl{border-left:2px solid var(--line);padding-left:14px;margin-left:6px}
.tl .ev{margin-bottom:8px}.tl .t{color:var(--muted);font-size:12px}
footer{margin-top:28px;border-top:1px solid var(--line);padding-top:14px;color:var(--muted);font-size:12px}
</style>
'@

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><title>OmniDiag Report</title>")
    [void]$sb.Append($css)
    [void]$sb.Append("</head><body><div class='wrap'>")

    # --- Header ---
    $brand = if ($BrandName) { "<div class='tag'>Prepared for " + (Get-OmniHtmlEncode $BrandName) + "</div>" } else { '' }
    $scoreNum = if ($s) { $s.Score } else { 'n/a' }
    $gradeCls = if ($s) { Get-OmniGradeClass $s.Grade } else { 'info' }
    $gradeTxt = if ($s) { Get-OmniHtmlEncode $s.Grade } else { 'Unknown' }
    [void]$sb.Append("<header><div><h1>OmniDiag Report</h1><div class='tag'>One Tool. Complete Diagnostics.</div>$brand</div>")
    [void]$sb.Append("<div class='score'><div class='num txt-$gradeCls'>$scoreNum</div><div class='lbl'>Health / 100 &middot; $gradeTxt</div></div></header>")

    # --- Executive summary ---
    [void]$sb.Append("<h2>Executive Summary</h2><div class='grid'>")
    [void]$sb.Append("<div class='card'><div class='k'>Computer</div><div class='v'>$(Get-OmniHtmlEncode $Session.Host.ComputerName)</div></div>")
    [void]$sb.Append("<div class='card'><div class='k'>User</div><div class='v'>$(Get-OmniHtmlEncode $Session.Host.UserName)</div></div>")
    [void]$sb.Append("<div class='card'><div class='k'>Scan Duration</div><div class='v'>$([math]::Round($Session.DurationMs/1000,1)) s</div></div>")
    [void]$sb.Append("<div class='card'><div class='k'>Time Range</div><div class='v'>$(Get-OmniHtmlEncode $Session.TimeRange.Label)</div></div>")
    if ($s) {
        [void]$sb.Append("<div class='card'><div class='k'>Critical / Error</div><div class='v txt-crit'>$($s.Counts.Critical) / $($s.Counts.Error)</div></div>")
        [void]$sb.Append("<div class='card'><div class='k'>Warnings</div><div class='v txt-warn'>$($s.Counts.Warning)</div></div>")
        [void]$sb.Append("<div class='card'><div class='k'>Passed</div><div class='v txt-pass'>$($s.Counts.Pass)</div></div>")
        [void]$sb.Append("<div class='card'><div class='k'>Modules Run</div><div class='v'>$($s.ModulesRun)</div></div>")
    }
    [void]$sb.Append('</div>')

    # --- Top recommendations ---
    if ($s -and $s.TopRecommendations.Count -gt 0) {
        [void]$sb.Append('<h2>Top Recommendations</h2><ul class="recs">')
        foreach ($r in $s.TopRecommendations) {
            $cls = Get-OmniSeverityClass $r.Severity
            [void]$sb.Append("<li><span class='badge $cls'>$(Get-OmniHtmlEncode $r.Severity)</span> <strong>$(Get-OmniHtmlEncode $r.Title)</strong><div class='muted'>$(Get-OmniHtmlEncode $r.Recommendation)</div></li>")
        }
        [void]$sb.Append('</ul>')
    }

    # --- Device information ---
    $sysResult = $Session.Results | Where-Object { $_.Category -eq 'System' } | Select-Object -First 1
    if ($sysResult -and $sysResult.Metrics.Count -gt 0) {
        [void]$sb.Append('<h2>Device Information</h2><table><tbody>')
        foreach ($key in $sysResult.Metrics.Keys) {
            [void]$sb.Append("<tr><th style='width:30%'>$(Get-OmniHtmlEncode $key)</th><td>$(Get-OmniHtmlEncode $sysResult.Metrics[$key])</td></tr>")
        }
        [void]$sb.Append('</tbody></table>')
    }

    # --- Failures (critical + error) ---
    [void]$sb.Append("<h2>Failures &amp; Errors ($($crit.Count))</h2>")
    if ($crit.Count -gt 0) {
        [void]$sb.Append('<table><thead><tr><th>Severity</th><th>Component</th><th>Finding</th><th>Likely Cause</th><th>Recommendation</th></tr></thead><tbody>')
        [void]$sb.Append((ConvertTo-OmniFindingHtmlRows -Findings $crit))
        [void]$sb.Append('</tbody></table>')
    } else {
        [void]$sb.Append("<p class='txt-pass'>No critical or error-level findings.</p>")
    }

    # --- Warnings ---
    [void]$sb.Append("<h2>Warnings ($($warn.Count))</h2>")
    if ($warn.Count -gt 0) {
        [void]$sb.Append('<table><thead><tr><th>Severity</th><th>Component</th><th>Finding</th><th>Likely Cause</th><th>Recommendation</th></tr></thead><tbody>')
        [void]$sb.Append((ConvertTo-OmniFindingHtmlRows -Findings $warn))
        [void]$sb.Append('</tbody></table>')
    } else {
        [void]$sb.Append("<p class='txt-pass'>No warnings.</p>")
    }

    # --- Event log analysis ---
    $evt = $Session.Results | Where-Object { $_.Category -eq 'Event Logs' } | Select-Object -First 1
    if ($evt) {
        [void]$sb.Append('<h2>Event Log Analysis</h2>')
        $m = $evt.Metrics
        [void]$sb.Append("<div class='grid'>")
        foreach ($k in @('TotalEvents', 'CriticalEvents', 'ErrorEvents', 'WarningEvents', 'UniqueEventTypes')) {
            if ($m.Contains($k)) { [void]$sb.Append("<div class='card'><div class='k'>$k</div><div class='v'>$(Get-OmniHtmlEncode $m[$k])</div></div>") }
        }
        [void]$sb.Append('</div>')

        if ($m.Contains('Timeline') -and @($m['Timeline']).Count -gt 0) {
            [void]$sb.Append("<h2 style='font-size:15px'>Timeline of Major Events</h2><div class='tl'>")
            foreach ($t in (@($m['Timeline']) | Select-Object -First 15)) {
                [void]$sb.Append("<div class='ev'><span class='t'>$(Get-OmniHtmlEncode ($t.Time.ToString('yyyy-MM-dd HH:mm')))</span> &mdash; $(Get-OmniHtmlEncode $t.Title) <span class='muted'>($(Get-OmniHtmlEncode $t.Category))</span></div>")
            }
            [void]$sb.Append('</div>')
        }

        if ($m.Contains('TopGroups') -and @($m['TopGroups']).Count -gt 0) {
            [void]$sb.Append("<h2 style='font-size:15px'>Top Event Groups</h2><table><thead><tr><th>Severity</th><th>Source</th><th>ID</th><th>Title</th><th>Count</th><th>First</th><th>Last</th></tr></thead><tbody>")
            foreach ($g in @($m['TopGroups'])) {
                $cls = Get-OmniSeverityClass $g.Severity
                [void]$sb.Append("<tr><td><span class='badge $cls'>$(Get-OmniHtmlEncode $g.Severity)</span></td><td>$(Get-OmniHtmlEncode $g.ProviderName)</td><td>$(Get-OmniHtmlEncode $g.Id)</td><td>$(Get-OmniHtmlEncode $g.Title)</td><td>$(Get-OmniHtmlEncode $g.Count)</td><td class='muted'>$(Get-OmniHtmlEncode ($g.FirstSeen.ToString('MM-dd HH:mm')))</td><td class='muted'>$(Get-OmniHtmlEncode ($g.LastSeen.ToString('MM-dd HH:mm')))</td></tr>")
            }
            [void]$sb.Append('</tbody></table>')
        }
    }

    # --- Per-module breakdown ---
    [void]$sb.Append('<h2>Module Results</h2><table><thead><tr><th>Module</th><th>Category</th><th>Status</th><th>Findings</th><th>Duration</th></tr></thead><tbody>')
    foreach ($r in $Session.Results) {
        $cls = Get-OmniSeverityClass $(if ($r.Status -eq 'Healthy') { 'Pass' } elseif ($r.Status -eq 'Warning') { 'Warning' } else { 'Critical' })
        [void]$sb.Append("<tr><td>$(Get-OmniHtmlEncode $r.ModuleName)</td><td>$(Get-OmniHtmlEncode $r.Category)</td><td><span class='badge $cls'>$(Get-OmniHtmlEncode $r.Status)</span></td><td>$($r.Findings.Count)</td><td class='muted'>$($r.DurationMs) ms</td></tr>")
    }
    [void]$sb.Append('</tbody></table>')

    # --- Passed checks ---
    [void]$sb.Append("<h2>Passed Checks ($($pass.Count))</h2><table><tbody>")
    foreach ($p in $pass) {
        [void]$sb.Append("<tr><td><span class='badge pass'>PASS</span></td><td>$(Get-OmniHtmlEncode $p.Component)</td><td>$(Get-OmniHtmlEncode $p.Title)</td></tr>")
    }
    [void]$sb.Append('</tbody></table>')

    # --- Privacy + footer ---
    [void]$sb.Append("<div class='privacy'><strong>Privacy notice.</strong> This report was generated locally and was not uploaded anywhere. It may contain usernames, device names, file paths, domains, and other internal information. Review it before sharing.</div>")
    [void]$sb.Append("<footer>Generated by OmniDiag on $(Get-OmniHtmlEncode ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))) &middot; All analysis performed locally.</footer>")
    [void]$sb.Append('</div></body></html>')

    Write-OmniTextFile -Path $Path -Content $sb.ToString()
    return $Path
}

Export-ModuleMember -Function @('Export-OmniHtmlReport', 'Get-OmniHtmlEncode', 'Get-OmniSeverityClass')
