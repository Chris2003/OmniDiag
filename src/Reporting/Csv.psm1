<#
.SYNOPSIS
    OmniDiag reporting: CSV exports (findings table + event table).

.DESCRIPTION
    Flattens a session into spreadsheet-friendly tables:
      * findings.csv - every finding across all modules,
      * events.csv   - the grouped event-log table (when Event Logs ran).
#>

Set-StrictMode -Version Latest

function ConvertTo-OmniFindingTable {
    <#
    .SYNOPSIS
        Flattens all findings in a session into rows (most-severe first).
    #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [pscustomobject] $Session)

    $rows = foreach ($r in $Session.Results) {
        foreach ($f in $r.Findings) {
            [pscustomobject]@{
                Module         = $r.ModuleName
                Category       = $r.Category
                Severity       = $f.Severity
                SeverityRank   = $f.SeverityRank
                Component      = $f.Component
                Title          = $f.Title
                Detail         = $f.Detail
                LikelyCause    = $f.LikelyCause
                Confidence     = $f.Confidence
                Recommendation = $f.Recommendation
                Timestamp      = $f.Timestamp
            }
        }
    }
    return @($rows | Sort-Object -Property SeverityRank -Descending)
}

function ConvertTo-OmniEventTable {
    <#
    .SYNOPSIS
        Flattens the Event Logs module's grouped events into rows, if present.
    #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [pscustomobject] $Session)

    $evt = $Session.Results | Where-Object { $_.Category -eq 'Event Logs' } | Select-Object -First 1
    if (-not $evt -or -not $evt.Metrics.Contains('TopGroups')) { return @() }

    $rows = foreach ($g in $evt.Metrics['TopGroups']) {
        [pscustomobject]@{
            Severity       = $g.Severity
            Category       = $g.Category
            Source         = $g.ProviderName
            EventId        = $g.Id
            Title          = $g.Title
            Count          = $g.Count
            FirstSeen      = $g.FirstSeen
            LastSeen       = $g.LastSeen
            Channel        = $g.Channel
            Message        = $g.SampleMessage
            Recommendation = $g.Recommendation
        }
    }
    return @($rows)
}

function Export-OmniCsvReport {
    <#
    .SYNOPSIS
        Writes the findings table to a CSV file.

    .OUTPUTS
        The written file path (string).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $table = ConvertTo-OmniFindingTable -Session $Session
    $table | Select-Object Module, Category, Severity, Component, Title, Detail, LikelyCause, Confidence, Recommendation, Timestamp |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    return $Path
}

function Export-OmniEventCsvReport {
    <#
    .SYNOPSIS
        Writes the grouped event table to a CSV file. Returns $null if no event data.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path
    )
    $rows = ConvertTo-OmniEventTable -Session $Session
    if ($rows.Count -eq 0) { return $null }

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    return $Path
}

Export-ModuleMember -Function @(
    'Export-OmniCsvReport', 'Export-OmniEventCsvReport',
    'ConvertTo-OmniFindingTable', 'ConvertTo-OmniEventTable'
)
