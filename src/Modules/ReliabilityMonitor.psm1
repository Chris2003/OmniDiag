<#
.SYNOPSIS
    OmniDiag diagnostic module: Reliability Monitor.

.DESCRIPTION
    Reads the data behind Windows Reliability Monitor (perfmon /rel) through the
    documented Reliability WMI provider (RacWmiProv, namespace root\cimv2):

      * Win32_ReliabilityStabilityMetrics - the System Stability Index (1 = least
        stable, 10 = most stable), calculated roughly hourly. Reports the latest
        value, the minimum and average, and the trend over the selected range.
      * Win32_ReliabilityRecords - the reliability events (application failures,
        Windows failures, hardware failures, installs). Summarized by
        ProductName / SourceName per category.

    Both queries are bounded: a WQL WHERE clause keeps only instances whose
    TimeGenerated falls inside $Context.TimeRange, and at most
    ReliabilityMaxRecords (default 2000) records / MaxStabilitySamples (default
    2000) samples are read.

    The classes are populated by the Reliability Analysis Component (the RacTask
    scheduled task) and require the "Configure Reliability WMI Providers" policy
    (enabled by default on Windows client, disabled by default on Windows Server).
    When both classes return nothing, an Information finding explains that data
    collection is likely disabled. Read-only; never throws.

    Per-run options (via $Context.Config):
        ReliabilityMaxRecords   int  Cap on Win32_ReliabilityRecords read. Default 2000.
        MaxStabilitySamples     int  Cap on stability samples read. Default 2000.
        StabilityWarnIndex      num  Index below which a Warning is raised. Default 5.
        StabilityErrorIndex     num  Index below which an Error is raised. Default 3.
        AppFailureWarnCount     int  Application failures that raise a Warning. Default 5.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Reliability Monitor'
        Id            = 'reliability.reliability-monitor'
        Group         = 'reliability'
        NetworkAccess = 'None'
        Category      = 'Reliability'
        Description   = 'Reliability Monitor stability index and failure records (application, Windows, hardware, installs).'
        RequiresAdmin = $false
        Order         = 610
        Enabled       = $true
        # Win32_ReliabilityRecords enumeration is slow on machines with a long history.
        TimeoutSec    = 120
    }
}

# ---------------------------------------------------------------------------
# Private helpers (one per data source, so tests can mock them)
# ---------------------------------------------------------------------------

function Test-OmniRelMonWindowsHost {
    <# .SYNOPSIS Returns $true on Windows (the Reliability WMI provider is Windows-only). #>
    [OutputType([bool])]
    param()
    try { if ($IsWindows -eq $false) { return $false } } catch { Write-Debug $_.Exception.Message }
    return $true
}

function ConvertTo-OmniWmiDateTime {
    <#
    .SYNOPSIS
        Formats a date as a WQL/DMTF datetime literal in UTC (yyyyMMddHHmmss.ffffff+000).
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [datetime] $Value)
    return ($Value.ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff', [System.Globalization.CultureInfo]::InvariantCulture) + '+000')
}

function Get-OmniRelMonTimeFilter {
    <# .SYNOPSIS Builds the WQL WHERE clause bounding TimeGenerated to the range. #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [datetime] $Start, [Parameter(Mandatory)] [datetime] $End)
    return ("TimeGenerated >= '{0}' AND TimeGenerated <= '{1}'" -f (ConvertTo-OmniWmiDateTime $Start), (ConvertTo-OmniWmiDateTime $End))
}

function Get-OmniRelMonStabilityMetric {
    <#
    .SYNOPSIS
        Reads Win32_ReliabilityStabilityMetrics within the range (bounded). Throws on error.
    #>
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [datetime] $Start,
        [Parameter(Mandatory)] [datetime] $End,
        [Parameter(Mandatory)] [int] $MaxRecords
    )
    $filter = Get-OmniRelMonTimeFilter -Start $Start -End $End
    return @(Get-CimInstance -Namespace 'root/cimv2' -ClassName 'Win32_ReliabilityStabilityMetrics' -Filter $filter `
        -Property 'SystemStabilityIndex', 'TimeGenerated' -ErrorAction Stop | Select-Object -First $MaxRecords)
}

function Get-OmniRelMonRecord {
    <#
    .SYNOPSIS
        Reads Win32_ReliabilityRecords within the range (bounded). Throws on error.
    #>
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [datetime] $Start,
        [Parameter(Mandatory)] [datetime] $End,
        [Parameter(Mandatory)] [int] $MaxRecords
    )
    $filter = Get-OmniRelMonTimeFilter -Start $Start -End $End
    return @(Get-CimInstance -Namespace 'root/cimv2' -ClassName 'Win32_ReliabilityRecords' -Filter $filter `
        -Property 'SourceName', 'ProductName', 'EventIdentifier', 'TimeGenerated', 'InsertionStrings', 'Logfile', 'RecordNumber' `
        -ErrorAction Stop | Select-Object -First $MaxRecords)
}

function Test-OmniRelMonAccessDenied {
    <#
    .SYNOPSIS
        True when an error record means access denied (checked by type and code,
        never by the localized message).
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($ex -is [System.UnauthorizedAccessException]) { return $true }
        try {
            $native = $ex.PSObject.Properties['NativeErrorCode']
            if ($native -and [string]$native.Value -eq 'AccessDenied') { return $true }
        } catch { Write-Debug $_.Exception.Message }
        # E_ACCESSDENIED (0x80070005) and WBEM_E_ACCESS_DENIED (0x80041003).
        try { if ($ex.HResult -eq -2147024891 -or $ex.HResult -eq -2147217405) { return $true } } catch { Write-Debug $_.Exception.Message }
        $ex = $ex.InnerException
    }
    try { if ([string]$ErrorRecord.CategoryInfo.Category -eq 'PermissionDenied') { return $true } } catch { Write-Debug $_.Exception.Message }
    return $false
}

function Get-OmniRelMonRecordCategory {
    <#
    .SYNOPSIS
        Maps a reliability record to a Reliability Monitor category by its source and
        event id (language independent).

    .OUTPUTS
        'Application', 'Windows', 'Hardware', 'FailedInstall', 'SuccessfulInstall', or
        $null for records outside these categories.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $Record)

    $src = ''
    $id = 0
    $eventName = ''
    try { $src = [string]$Record.SourceName } catch { Write-Debug $_.Exception.Message }
    try { $id = [int]$Record.EventIdentifier } catch { Write-Debug $_.Exception.Message }
    try {
        $ins = @($Record.InsertionStrings)
        # Windows Error Reporting 1001: index 2 is the (non-localized) event name.
        if ($ins.Count -gt 2) { $eventName = [string]$ins[2] }
    } catch { Write-Debug $_.Exception.Message }

    if ($src -eq 'Application Error' -and $id -eq 1000) { return 'Application' }
    if ($src -eq 'Application Hang' -and $id -eq 1002) { return 'Application' }
    if (($src -like '*WER-SystemErrorReporting' -or $src -eq 'BugCheck') -and $id -eq 1001) { return 'Windows' }
    if ($src -eq 'EventLog' -and $id -eq 6008) { return 'Windows' }
    if ($src -like '*WHEA-Logger*') { return 'Hardware' }
    if ($src -eq 'Windows Error Reporting' -and $id -eq 1001) {
        if ($eventName -eq 'LiveKernelEvent') { return 'Hardware' }
        if ($eventName -eq 'BlueScreen') { return 'Windows' }
        return $null   # APPCRASH etc. duplicate the Application Error records
    }
    if ($src -like '*WindowsUpdateClient*') {
        if ($id -eq 20) { return 'FailedInstall' }
        if ($id -eq 19) { return 'SuccessfulInstall' }
    }
    if ($src -eq 'MsiInstaller') {
        if ($id -eq 11708) { return 'FailedInstall' }
        if ($id -eq 11707) { return 'SuccessfulInstall' }
    }
    return $null
}

function Get-OmniRelMonTopSource {
    <# .SYNOPSIS Top 5 "ProductName (SourceName) xN" labels for a set of records. #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Record)
    $labels = foreach ($r in $Record) {
        $product = ''
        try { $product = [string]$r.ProductName } catch { Write-Debug $_.Exception.Message }
        $source = ''
        try { $source = [string]$r.SourceName } catch { Write-Debug $_.Exception.Message }
        if ($product) { '{0} ({1})' -f $product, $source } else { $source }
    }
    return @(@($labels) | Group-Object | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
        Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ Source = $_.Name; Count = $_.Count } })
}

function Get-OmniRelMonConfigValue {
    <# .SYNOPSIS Reads a numeric Config option with a default. #>
    param([pscustomobject] $Context, [string] $Name, [double] $Default)
    try {
        if ($Context.Config -and $Context.Config.ContainsKey($Name)) { return [double]$Context.Config[$Name] }
    } catch { Write-Debug $_.Exception.Message }
    return $Default
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Reliability Monitor' -Category 'Reliability' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $component = 'Reliability/Reliability Monitor'

    if (-not (Test-OmniRelMonWindowsHost)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.platform' `
            -Title 'Reliability Monitor data is unavailable on this platform' -Severity 'Information' `
            -Component $component -Detail 'Reliability Monitor (Win32_Reliability* WMI classes) exists only on Windows.')
        return (Complete-OmniResult -Result $result)
    }

    $maxRecords = [int](Get-OmniRelMonConfigValue -Context $Context -Name 'ReliabilityMaxRecords' -Default 2000)
    $maxSamples = [int](Get-OmniRelMonConfigValue -Context $Context -Name 'MaxStabilitySamples' -Default 2000)
    $warnIndex  = Get-OmniRelMonConfigValue -Context $Context -Name 'StabilityWarnIndex' -Default 5
    $errorIndex = Get-OmniRelMonConfigValue -Context $Context -Name 'StabilityErrorIndex' -Default 3
    $appWarn    = [int](Get-OmniRelMonConfigValue -Context $Context -Name 'AppFailureWarnCount' -Default 5)
    if ($maxRecords -lt 1) { $maxRecords = 1 }
    if ($maxSamples -lt 1) { $maxSamples = 1 }
    $start = $Context.TimeRange.Start
    $end = $Context.TimeRange.End
    $rangeLabel = $Context.TimeRange.Label

    $denied = $false
    $unavailable = $false

    # --- Stability index -------------------------------------------------
    $samples = @()
    try {
        $samples = @(Get-OmniRelMonStabilityMetric -Start $start -End $end -MaxRecords $maxSamples)
    } catch {
        if (Test-OmniRelMonAccessDenied -ErrorRecord $_) { $denied = $true } else { $unavailable = $true }
        if ($log) { $log.Debug("Win32_ReliabilityStabilityMetrics query failed: $($_.Exception.Message)", 'Reliability Monitor') }
    }

    if ($Context.CancellationToken.IsCancellationRequested) {
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    # --- Reliability records ---------------------------------------------
    $records = @()
    try {
        $records = @(Get-OmniRelMonRecord -Start $start -End $end -MaxRecords $maxRecords)
    } catch {
        if (Test-OmniRelMonAccessDenied -ErrorRecord $_) { $denied = $true } else { $unavailable = $true }
        if ($log) { $log.Debug("Win32_ReliabilityRecords query failed: $($_.Exception.Message)", 'Reliability Monitor') }
    }

    if ($Context.CancellationToken.IsCancellationRequested) {
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    Set-OmniResultMetric -Result $result -Name 'StabilitySamples' -Value $samples.Count
    Set-OmniResultMetric -Result $result -Name 'ReliabilityRecordsRead' -Value $records.Count
    Set-OmniResultMetric -Result $result -Name 'ReliabilityRecordsTruncated' -Value ($records.Count -ge $maxRecords)

    if ($denied) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.requires-elevation' `
            -Title 'Reliability Monitor data requires elevation' -Severity 'Information' -Component $component `
            -Detail 'Access to the Reliability WMI provider was denied, so part or all of the Reliability Monitor data could not be read (requires elevation).' `
            -Recommendation 'Re-run OmniDiag as Administrator to include Reliability Monitor data.')
    }
    if ($unavailable -and -not $denied -and $samples.Count -eq 0 -and $records.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.unavailable' `
            -Title 'Reliability Monitor data is not available' -Severity 'Information' -Component $component `
            -Detail 'The Win32_ReliabilityStabilityMetrics / Win32_ReliabilityRecords classes could not be queried. They are missing on Server Core and when the Reliability WMI provider is turned off.' `
            -Recommendation 'Enable the "Configure Reliability WMI Providers" policy and the RacTask scheduled task (Microsoft\Windows\RAC) if Reliability Monitor history is needed.')
        return (Complete-OmniResult -Result $result)
    }
    if (-not $denied -and -not $unavailable -and $samples.Count -eq 0 -and $records.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.no-data' `
            -Title 'No Reliability Monitor data was recorded' -Severity 'Information' -Component $component `
            -Detail "Win32_ReliabilityStabilityMetrics and Win32_ReliabilityRecords returned nothing for $rangeLabel. Reliability data collection is probably disabled: the Reliability Analysis Component (the RacTask scheduled task) must run and the ""Configure Reliability WMI Providers"" policy must be enabled (it is disabled by default on Windows Server)." `
            -LikelyCause 'Reliability data collection is disabled, or the machine was installed very recently.' `
            -Recommendation 'Enable the "Configure Reliability WMI Providers" policy and the RacTask scheduled task (Microsoft\Windows\RAC) to collect Reliability Monitor history.')
        return (Complete-OmniResult -Result $result)
    }

    # --- Stability index findings ----------------------------------------
    if ($samples.Count -gt 0) {
        $ordered = @($samples | Where-Object { $null -ne $_.SystemStabilityIndex } | Sort-Object -Property TimeGenerated)
        if ($ordered.Count -gt 0) {
            $latest = [math]::Round([double]$ordered[-1].SystemStabilityIndex, 2)
            $first = [math]::Round([double]$ordered[0].SystemStabilityIndex, 2)
            $stats = $ordered | Measure-Object -Property SystemStabilityIndex -Minimum -Average
            $min = [math]::Round([double]$stats.Minimum, 2)
            $avg = [math]::Round([double]$stats.Average, 2)
            $delta = $latest - $first
            $trend = if ($ordered.Count -lt 2) { 'Unknown' } elseif ($delta -ge 0.5) { 'Improving' } elseif ($delta -le -0.5) { 'Declining' } else { 'Stable' }

            Set-OmniResultMetric -Result $result -Name 'StabilityIndexLatest' -Value $latest
            Set-OmniResultMetric -Result $result -Name 'StabilityIndexMin' -Value $min
            Set-OmniResultMetric -Result $result -Name 'StabilityIndexAverage' -Value $avg
            Set-OmniResultMetric -Result $result -Name 'StabilityTrend' -Value $trend

            $detail = "Latest System Stability Index: $latest of 10 (minimum $min, average $avg over $($ordered.Count) sample(s) in $rangeLabel; trend: $trend, from $first)."
            $data = [pscustomobject]@{ Latest = $latest; Minimum = $min; Average = $avg; First = $first; Trend = $trend; Samples = $ordered.Count }
            if ($latest -lt $errorIndex) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.stability-index' `
                    -Title 'System stability index is very low' -Severity 'Error' -Component $component -Detail $detail `
                    -LikelyCause 'Frequent application, Windows, or hardware failures in the recent past.' -Confidence 70 `
                    -Recommendation 'Open Reliability Monitor (perfmon /rel) and fix the most frequent failures listed below; correlate with crash dumps and bug-check events.' `
                    -Data $data)
            } elseif ($latest -lt $warnIndex) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.stability-index' `
                    -Title 'System stability index is low' -Severity 'Warning' -Component $component -Detail $detail `
                    -LikelyCause 'Recurring failures recorded by Reliability Monitor.' -Confidence 60 `
                    -Recommendation 'Open Reliability Monitor (perfmon /rel) and review the failures listed below.' `
                    -Data $data)
            } else {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.stability-index' `
                    -Title 'System stability index is healthy' -Severity 'Pass' -Component $component -Detail $detail -Data $data)
            }
        }
    } elseif (-not $denied) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.no-stability-data' `
            -Title 'No stability index was calculated in the range' -Severity 'Information' -Component $component `
            -Detail "Reliability records exist but Win32_ReliabilityStabilityMetrics returned no samples for $rangeLabel. The index is calculated by the Reliability Analysis Component (RacTask), which may be disabled." `
            -Recommendation 'Check that the RacTask scheduled task (Microsoft\Windows\RAC) is enabled.')
    }

    # --- Failure records -------------------------------------------------
    $byCategory = @{ Application = @(); Windows = @(); Hardware = @(); FailedInstall = @(); SuccessfulInstall = @() }
    foreach ($r in $records) {
        $cat = Get-OmniRelMonRecordCategory -Record $r
        if ($cat) { $byCategory[$cat] += $r }
    }
    Set-OmniResultMetric -Result $result -Name 'ApplicationFailures' -Value $byCategory['Application'].Count
    Set-OmniResultMetric -Result $result -Name 'WindowsFailures' -Value $byCategory['Windows'].Count
    Set-OmniResultMetric -Result $result -Name 'HardwareFailures' -Value $byCategory['Hardware'].Count
    Set-OmniResultMetric -Result $result -Name 'FailedInstalls' -Value $byCategory['FailedInstall'].Count
    Set-OmniResultMetric -Result $result -Name 'SuccessfulInstalls' -Value $byCategory['SuccessfulInstall'].Count

    $describe = {
        param([object[]] $Set)
        $top = @(Get-OmniRelMonTopSource -Record $Set)
        $text = ($top | ForEach-Object { '{0} x{1}' -f $_.Source, $_.Count }) -join '; '
        return @{ Top = $top; Text = $text }
    }

    $app = $byCategory['Application']
    if ($app.Count -gt 0) {
        $d = & $describe $app
        $sev = if ($app.Count -ge $appWarn) { 'Warning' } else { 'Information' }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.application-failures' `
            -Title "$($app.Count) application failure(s) recorded" -Severity $sev -Component $component `
            -Detail "Reliability Monitor recorded $($app.Count) application crash/hang record(s) in $rangeLabel. Most frequent: $($d.Text)." `
            -LikelyCause 'An application (or an add-in or dependency it loads) is crashing or hanging.' -Confidence 60 `
            -Recommendation 'Update or repair the most frequent applications; check their faulting module in Reliability Monitor.' `
            -Data $d.Top)
    }

    $win = $byCategory['Windows']
    if ($win.Count -gt 0) {
        $d = & $describe $win
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.windows-failures' `
            -Title "$($win.Count) Windows failure(s) recorded" -Severity 'Warning' -Component $component `
            -Detail "Reliability Monitor recorded $($win.Count) Windows failure(s) (bug checks or unexpected shutdowns) in $rangeLabel. Sources: $($d.Text)." `
            -LikelyCause 'Blue screens or unexpected shutdowns: a faulty driver, failing hardware, overheating, or power loss.' -Confidence 65 `
            -Recommendation 'Analyze the crash dumps (WinDbg !analyze -v) and correlate with bug-check (1001) and Kernel-Power 41 events.' `
            -Data $d.Top)
    }

    $hw = $byCategory['Hardware']
    if ($hw.Count -gt 0) {
        $d = & $describe $hw
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.hardware-failures' `
            -Title "$($hw.Count) hardware failure(s) recorded" -Severity 'Warning' -Component $component `
            -Detail "Reliability Monitor recorded $($hw.Count) hardware error report(s) (WHEA or LiveKernelEvent) in $rangeLabel. Sources: $($d.Text)." `
            -LikelyCause 'A hardware component (CPU, memory, PCIe device, GPU) reported an error, or a device driver recovered from a hang.' -Confidence 55 `
            -Recommendation 'Update chipset, GPU, and storage drivers and firmware; run memory and hardware diagnostics if errors recur.' `
            -Data $d.Top)
    }

    $fi = $byCategory['FailedInstall']
    if ($fi.Count -gt 0) {
        $d = & $describe $fi
        $sev = if ($fi.Count -ge 3) { 'Warning' } else { 'Information' }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.failed-installs' `
            -Title "$($fi.Count) failed install(s) recorded" -Severity $sev -Component $component `
            -Detail "Reliability Monitor recorded $($fi.Count) failed update or MSI install(s) in $rangeLabel. Most frequent: $($d.Text)." `
            -LikelyCause 'An update or installer failed (disk space, a pending reboot, servicing-stack or component-store problems).' -Confidence 50 `
            -Recommendation 'Note the failing update or product and its error code in Reliability Monitor; retry after a restart.' `
            -Data $d.Top)
    }

    if (($app.Count + $win.Count + $hw.Count + $fi.Count) -eq 0 -and -not $denied) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.reliability-monitor.no-failures' `
            -Title 'No failures recorded by Reliability Monitor' -Severity 'Pass' -Component $component `
            -Detail "No application, Windows, hardware, or install failures were recorded in $rangeLabel.")
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
