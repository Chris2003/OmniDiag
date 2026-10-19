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

function ConvertTo-OmniCsvSafeValue {
    <#
    .SYNOPSIS
        Internal: one CSV cell value with spreadsheet formulas neutralized.

    .DESCRIPTION
        A cell whose first character is = + - @ TAB CR or LF - also after leading
        whitespace or quote characters, which spreadsheets skip (' =cmd', '"=cmd') - or
        whose first non-blank character is a full-width = + - @ is prefixed with a single
        quote, so it is shown as text and never evaluated. Numbers, booleans, and dates
        pass through unchanged; anything else (an object or array from an imported
        session) is rendered as text first, so it cannot smuggle a formula past the
        check. Quoting of commas, quotes, and line breaks is left to Export-Csv, which
        quotes every field and doubles embedded quotes.
    #>
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSObject]) { $Value = $Value.PSObject.BaseObject }
    if ($Value -is [bool] -or $Value -is [datetime] -or $Value -is [System.DateTimeOffset] -or $Value -is [enum]) { return $Value }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int] -or
        $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64] -or $Value -is [double] -or $Value -is [single] -or
        $Value -is [decimal]) { return $Value }
    if ($Value -is [string]) { $text = $Value }
    elseif ($Value -is [System.Collections.IEnumerable]) { $text = (@($Value) | ForEach-Object { [string]$_ }) -join '; ' }
    else { $text = [string]$Value }
    if ($text -match '^[\t\r\n]' -or $text -match '^[\s"'']*[=+\-@\uFF1D\uFF0B\uFF0D\uFF20]') { return "'" + $text }
    return $text
}

function ConvertTo-OmniCsvSafeRow {
    <#
    .SYNOPSIS
        Internal: neutralize spreadsheet formulas in exported text.

    .DESCRIPTION
        Event messages, provider names, hosts entries, and printer names can be written
        by any program, so a cell starting with = + - @ (or TAB/CR/LF, also after leading
        whitespace or quotes) would run as a formula when the CSV is opened in Excel.
        Such cells are prefixed with a single quote (ConvertTo-OmniCsvSafeValue). Applied
        only at export, so the GUI grid keeps the raw values.
    #>
    param([Parameter(ValueFromPipeline)] [object] $Row)
    process {
        if ($null -eq $Row) { return }
        $copy = [ordered]@{}
        foreach ($p in $Row.PSObject.Properties) {
            $copy[$p.Name] = ConvertTo-OmniCsvSafeValue -Value $p.Value
        }
        [pscustomobject]$copy
    }
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
        ConvertTo-OmniCsvSafeRow | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
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
    $rows = @(ConvertTo-OmniEventTable -Session $Session)
    if ($rows.Count -eq 0) { return $null }

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $rows | ConvertTo-OmniCsvSafeRow | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    return $Path
}

Export-ModuleMember -Function @(
    'Export-OmniCsvReport', 'Export-OmniEventCsvReport',
    'ConvertTo-OmniFindingTable', 'ConvertTo-OmniEventTable'
)
