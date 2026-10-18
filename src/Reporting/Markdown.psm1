<#
.SYNOPSIS
    OmniDiag reporting: Markdown export.

.DESCRIPTION
    Renders a session as GitHub-flavored Markdown - a summary table, the module
    roll-up (with contract-v1 ids and groups), and every non-pass finding grouped by
    severity - for pasting into tickets, chats, and wikis. Uses the v1 severity
    scale (Critical / Warning / Info) with the native severity alongside.

    All session text is escaped: table cells have '|' and line breaks neutralized,
    and '&', '<', '>' are HTML-encoded so a crafted finding cannot inject markup
    into a rendered page.
#>

Set-StrictMode -Version Latest

function ConvertTo-OmniMarkdownText {
    <# .SYNOPSIS Internal: escape session text for Markdown (optionally for a table cell). #>
    param([AllowNull()] $Value, [switch] $Cell)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    # Characters that start Markdown constructs inside inline text.
    $s = [regex]::Replace($s, '([\\`*_\[\]])', '\$1')
    if ($Cell) {
        $s = $s.Replace('|', '\|')
        $s = [regex]::Replace($s, '\r?\n', ' ')
    }
    return $s.Trim()
}

function ConvertTo-OmniMarkdownReport {
    <#
    .SYNOPSIS
        Renders a session as a Markdown document (string).

    .PARAMETER Session
        A live, imported, or rebuilt OmniDiag.Session.

    .PARAMETER BrandName
        Optional organization name shown under the title.

    .PARAMETER IncludePass
        Also list passing checks (by default only their count is shown).

    .EXAMPLE
        ConvertTo-OmniMarkdownReport -Session $session | Set-Content report.md
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [string] $BrandName,
        [switch] $IncludePass
    )

    $v1 = ConvertTo-OmniReportV1 -Session $Session
    $nl = "`n"
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('# OmniDiag Report').Append($nl).Append($nl)
    if ($BrandName) { [void]$sb.Append('_Prepared by ').Append((ConvertTo-OmniMarkdownText $BrandName)).Append('_').Append($nl).Append($nl) }

    $scoreText = if ($null -ne $v1.summary.healthScore) { "$($v1.summary.healthScore)/100" } else { 'n/a' }
    $gradeText = if ($v1.summary.grade) { [string]$v1.summary.grade } else { 'n/a' }
    $counts = $v1.summary.counts
    [void]$sb.Append('| Item | Value |').Append($nl).Append('| --- | --- |').Append($nl)
    $rows = [ordered]@{
        'Computer'      = $v1.host.computerName
        'User'          = $v1.host.userName
        'Elevated'      = $(if ($v1.host.isAdmin) { 'Yes' } else { 'No' })
        'Scan started'  = $(if ($v1.scan.startedAt) { $v1.scan.startedAt } else { 'n/a' })
        'Time range'    = $(if ($v1.scan.timeRange) { $v1.scan.timeRange.label } else { 'n/a' })
        'Health score'  = $scoreText
        'Grade'         = $gradeText
        'Findings'      = ('{0} critical, {1} warning, {2} info, {3} passed' -f $counts.critical, $counts.warning, $counts.info, $counts.passed)
        'OmniDiag'      = $v1.tool.version
        'Report schema' = $v1.schemaVersion
    }
    if ($v1.scan.cancelled) { $rows['Status'] = 'Cancelled before every module finished' }
    foreach ($k in $rows.Keys) {
        [void]$sb.Append('| ').Append($k).Append(' | ').Append((ConvertTo-OmniMarkdownText $rows[$k] -Cell)).Append(' |').Append($nl)
    }
    [void]$sb.Append($nl)

    [void]$sb.Append('## Modules').Append($nl).Append($nl)
    if (@($v1.modules).Count -eq 0) {
        [void]$sb.Append('No modules ran.').Append($nl).Append($nl)
    } else {
        [void]$sb.Append('| Module | Id | Group | Status | Findings |').Append($nl).Append('| --- | --- | --- | --- | ---: |').Append($nl)
        foreach ($m in $v1.modules) {
            $status = [string]$m.status
            if ($m.skippedReason) { $status = "$status ($($m.skippedReason))" }
            $notPassed = @($m.findings | Where-Object { -not $_.passed }).Count
            [void]$sb.Append('| ').Append((ConvertTo-OmniMarkdownText $m.name -Cell)).Append(' | `').Append(([string]$m.id).Replace('`', '')).Append('` | ')
            [void]$sb.Append((ConvertTo-OmniMarkdownText $m.group -Cell)).Append(' | ').Append((ConvertTo-OmniMarkdownText $status -Cell)).Append(' | ').Append($notPassed).Append(' |').Append($nl)
        }
        [void]$sb.Append($nl)
    }

    $all = foreach ($m in $v1.modules) { foreach ($f in $m.findings) { [pscustomobject]@{ Module = $m.name; Finding = $f } } }
    $all = @($all)
    foreach ($sev in @('Critical', 'Warning', 'Info')) {
        $items = @($all | Where-Object { $_.Finding.severity -eq $sev -and -not $_.Finding.passed })
        if ($items.Count -eq 0) { continue }
        [void]$sb.Append('## ').Append($sev).Append(' (').Append($items.Count).Append(')').Append($nl).Append($nl)
        foreach ($it in $items) {
            $f = $it.Finding
            [void]$sb.Append('### ').Append((ConvertTo-OmniMarkdownText $f.title)).Append($nl).Append($nl)
            [void]$sb.Append('- **Module:** ').Append((ConvertTo-OmniMarkdownText $it.Module)).Append($nl)
            [void]$sb.Append('- **Component:** ').Append((ConvertTo-OmniMarkdownText $f.component)).Append($nl)
            [void]$sb.Append('- **Severity:** ').Append($f.severity).Append(' (').Append($f.severityNative).Append(')').Append($nl)
            [void]$sb.Append('- **Finding id:** `').Append(([string]$f.id).Replace('`', '')).Append('`').Append($nl)
            if ($f.evidence.detail) { [void]$sb.Append('- **Detail:** ').Append((ConvertTo-OmniMarkdownText $f.evidence.detail -Cell)).Append($nl) }
            if ($f.likelyCause) {
                $cause = ConvertTo-OmniMarkdownText $f.likelyCause -Cell
                if ($f.confidence -gt 0) { $cause = "$cause (confidence $($f.confidence)%)" }
                [void]$sb.Append('- **Likely cause:** ').Append($cause).Append($nl)
            }
            if ($f.recommendation) { [void]$sb.Append('- **Recommendation:** ').Append((ConvertTo-OmniMarkdownText $f.recommendation -Cell)).Append($nl) }
            [void]$sb.Append($nl)
        }
    }

    $passed = @($all | Where-Object { $_.Finding.passed })
    if ($passed.Count -gt 0) {
        [void]$sb.Append('## Passed checks (').Append($passed.Count).Append(')').Append($nl).Append($nl)
        if ($IncludePass) {
            foreach ($it in $passed) {
                [void]$sb.Append('- ').Append((ConvertTo-OmniMarkdownText $it.Finding.title -Cell)).Append(' - ').Append((ConvertTo-OmniMarkdownText $it.Module -Cell)).Append($nl)
            }
        } else {
            [void]$sb.Append('Passing checks are omitted; see the JSON or HTML report for the full list.').Append($nl)
        }
        [void]$sb.Append($nl)
    }

    [void]$sb.Append('---').Append($nl).Append($nl)
    if ($v1.options.Contains('redacted') -and $v1.options['redacted']) {
        [void]$sb.Append('_Redacted report: generated locally by OmniDiag; nothing was uploaded. Host, user, and domain names, SIDs, profile paths, and IP/MAC addresses were replaced with stable pseudonyms (HOST-1, USER-1, IP-1, ...). Free text that cannot be derived from the session may remain - review before sharing._').Append($nl)
    } else {
        [void]$sb.Append('_Privacy notice: generated locally by OmniDiag; nothing was uploaded. This report may contain user, device, domain, and path names - review before sharing._').Append($nl)
    }
    return $sb.ToString()
}

function Export-OmniMarkdownReport {
    <#
    .SYNOPSIS
        Writes a session to a Markdown (.md) report.

    .PARAMETER Session
        The OmniDiag.Session to report on.

    .PARAMETER Path
        Output file path.

    .PARAMETER BrandName
        Optional organization name shown under the title.

    .OUTPUTS
        The written file path (string).

    .EXAMPLE
        Export-OmniMarkdownReport -Session $session -Path .\report.md
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $BrandName
    )
    $md = ConvertTo-OmniMarkdownReport -Session $Session -BrandName $BrandName
    Write-OmniTextFile -Path $Path -Content $md
    return $Path
}

Export-ModuleMember -Function @('ConvertTo-OmniMarkdownReport', 'Export-OmniMarkdownReport')
