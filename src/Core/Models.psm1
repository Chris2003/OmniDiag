<#
.SYNOPSIS
    OmniDiag core data models, severity/status vocabularies, and factory functions.

.DESCRIPTION
    Defines the shared, serialization-friendly object shapes used across every
    OmniDiag layer (engine, diagnostic modules, reporting). Models are emitted as
    typed PSCustomObjects via factory functions rather than PowerShell classes so
    they cross module boundaries cleanly (no `using module` requirement) and
    serialize losslessly to JSON.

    Severity and status are represented as validated strings with an associated
    numeric rank map, giving us ordering without the cross-scope friction of enums.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Vocabularies
# ---------------------------------------------------------------------------

# Ordered worst-last so a higher rank == more severe.
$script:OmniSeverityRank = [ordered]@{
    Pass        = 0
    Information = 1
    Warning     = 2
    Error       = 3
    Critical    = 4
}

# Roll-up status used at the module / session level.
$script:OmniStatusValues = @('Healthy', 'Warning', 'Critical', 'Unknown', 'Skipped', 'Failed')

function Get-OmniSeverityRank {
    <#
    .SYNOPSIS
        Returns the numeric rank for a severity string (higher == more severe).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Severity
    )
    if (-not $script:OmniSeverityRank.Contains($Severity)) {
        throw "Unknown severity '$Severity'. Valid values: $($script:OmniSeverityRank.Keys -join ', ')."
    }
    return [int]$script:OmniSeverityRank[$Severity]
}

function Get-OmniSeverityNames {
    <# .SYNOPSIS Returns the ordered list of valid severity names. #>
    [OutputType([string[]])]
    param()
    return [string[]]$script:OmniSeverityRank.Keys
}

# ---------------------------------------------------------------------------
# Finding
# ---------------------------------------------------------------------------

function New-OmniFinding {
    <#
    .SYNOPSIS
        Creates a single diagnostic finding.

    .DESCRIPTION
        A finding is the atomic unit of OmniDiag output: an interpreted, severity-
        tagged observation that goes beyond raw data to (optionally) include a
        likely cause, a confidence score, and a recommended next step. This is what
        powers the "diagnose, don't just dump" requirement.

    .PARAMETER Title
        Short, human-readable summary (e.g. "DNS resolution failing").

    .PARAMETER Severity
        One of Pass, Information, Warning, Error, Critical.

    .PARAMETER Component
        The affected component/subsystem (e.g. "Network/DNS", "Storage/Disk0").

    .PARAMETER Detail
        Longer explanation of what was observed.

    .PARAMETER LikelyCause
        Interpreted probable root cause, in plain English.

    .PARAMETER Confidence
        0-100 confidence in the likely cause / interpretation.

    .PARAMETER Recommendation
        Suggested next step for the technician.

    .PARAMETER Data
        Optional structured payload (hashtable / object) backing the finding.

    .PARAMETER Id
        Stable identifier for de-duplication and report cross-referencing.
        Auto-generated from Component+Title when omitted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [Parameter(Mandatory)]
        [ValidateScript({ $_ -in (Get-OmniSeverityNames) })]
        [string] $Severity,

        [string] $Component = 'General',

        [string] $Detail = '',

        [string] $LikelyCause = '',

        [ValidateRange(0, 100)]
        [int] $Confidence = 0,

        [string] $Recommendation = '',

        [object] $Data = $null,

        [string] $Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        $seed = "{0}|{1}" -f $Component, $Title
        $Id = ($seed.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    }

    $finding = [pscustomobject]@{
        PSTypeName     = 'OmniDiag.Finding'
        Id             = $Id
        Title          = $Title
        Severity       = $Severity
        SeverityRank   = Get-OmniSeverityRank -Severity $Severity
        Component      = $Component
        Detail         = $Detail
        LikelyCause    = $LikelyCause
        Confidence     = $Confidence
        Recommendation = $Recommendation
        Data           = $Data
        Timestamp      = (Get-Date)
    }
    return $finding
}

# ---------------------------------------------------------------------------
# Module result
# ---------------------------------------------------------------------------

function New-OmniResult {
    <#
    .SYNOPSIS
        Creates an empty result container for one diagnostic module run.

    .DESCRIPTION
        Aggregates the findings, metrics, timing, and status produced by a single
        module. Use Add-OmniFinding / Set-OmniResultMetric to populate it and
        Complete-OmniResult to finalize timing and derive the roll-up status.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleName,

        [string] $Category = 'General',

        [bool] $RequiresAdmin = $false,

        [bool] $HadAdmin = $false
    )

    return [pscustomobject]@{
        PSTypeName    = 'OmniDiag.Result'
        ModuleName    = $ModuleName
        Category      = $Category
        Status        = 'Unknown'
        RequiresAdmin = $RequiresAdmin
        HadAdmin      = $HadAdmin
        StartTime     = (Get-Date)
        EndTime       = $null
        DurationMs    = 0
        Findings      = [System.Collections.Generic.List[object]]::new()
        Metrics       = [ordered]@{}
        Error         = $null
    }
}

function Add-OmniFinding {
    <#
    .SYNOPSIS
        Appends one or more findings to a result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject] $Result,

        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
        [object[]] $Finding
    )
    process {
        foreach ($f in $Finding) {
            if ($null -ne $f) { [void]$Result.Findings.Add($f) }
        }
    }
}

function Set-OmniResultMetric {
    <#
    .SYNOPSIS
        Records a named metric/value on a result (e.g. "FreeSpaceGB" = 42).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Result,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowNull()] [object] $Value
    )
    $Result.Metrics[$Name] = $Value
}

function Complete-OmniResult {
    <#
    .SYNOPSIS
        Finalizes a result: stamps end time/duration and derives roll-up Status
        from the highest-severity finding (unless an explicit status is given).

    .PARAMETER Status
        Optional explicit status override (e.g. 'Skipped', 'Failed').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Result,

        [ValidateScript({ $_ -in @('Healthy','Warning','Critical','Unknown','Skipped','Failed') })]
        [string] $Status
    )

    $Result.EndTime = Get-Date
    $Result.DurationMs = [int]([math]::Round(($Result.EndTime - $Result.StartTime).TotalMilliseconds))

    if ($PSBoundParameters.ContainsKey('Status')) {
        $Result.Status = $Status
        return $Result
    }

    if ($Result.Findings.Count -eq 0) {
        $Result.Status = 'Healthy'
        return $Result
    }

    $max = ($Result.Findings | Measure-Object -Property SeverityRank -Maximum).Maximum
    $Result.Status = switch ($max) {
        { $_ -ge (Get-OmniSeverityRank 'Critical') } { 'Critical'; break }
        { $_ -ge (Get-OmniSeverityRank 'Error') }    { 'Critical'; break }
        { $_ -ge (Get-OmniSeverityRank 'Warning') }  { 'Warning';  break }
        default                                       { 'Healthy' }
    }
    return $Result
}

# ---------------------------------------------------------------------------
# Time range helper
# ---------------------------------------------------------------------------

function Get-OmniTimeRange {
    <#
    .SYNOPSIS
        Resolves a named preset or explicit Start/End into a normalized range.

    .PARAMETER Preset
        Last24Hours, Last7Days, or Last30Days.

    .PARAMETER Start
        Explicit start (overrides preset start).

    .PARAMETER End
        Explicit end. Defaults to now.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Preset')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'Preset')]
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')]
        [string] $Preset = 'Last7Days',

        [Parameter(ParameterSetName = 'Custom', Mandatory)]
        [datetime] $Start,

        [Parameter(ParameterSetName = 'Custom')]
        [datetime] $End
    )

    $now = Get-Date
    if ($PSCmdlet.ParameterSetName -eq 'Custom') {
        $endTime = if ($PSBoundParameters.ContainsKey('End')) { $End } else { $now }
        $label = "{0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm}" -f $Start, $endTime
        return [pscustomobject]@{
            PSTypeName = 'OmniDiag.TimeRange'
            Start      = $Start
            End        = $endTime
            Label      = $label
            Preset     = 'Custom'
        }
    }

    $start = switch ($Preset) {
        'Last24Hours' { $now.AddHours(-24) }
        'Last7Days'   { $now.AddDays(-7) }
        'Last30Days'  { $now.AddDays(-30) }
    }
    return [pscustomobject]@{
        PSTypeName = 'OmniDiag.TimeRange'
        Start      = $start
        End        = $now
        Label      = $Preset
        Preset     = $Preset
    }
}

Export-ModuleMember -Function @(
    'Get-OmniSeverityRank', 'Get-OmniSeverityNames',
    'New-OmniFinding', 'New-OmniResult', 'Add-OmniFinding',
    'Set-OmniResultMetric', 'Complete-OmniResult', 'Get-OmniTimeRange'
)
