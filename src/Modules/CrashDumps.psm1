<#
.SYNOPSIS
    OmniDiag diagnostic module: Crash Dumps.

.DESCRIPTION
    Inventories the kernel crash dumps Windows wrote after a bug check (blue screen)
    and reports how crash dumps are configured. Only file metadata (name, size, last
    write time) is read; dump contents are never opened.

      * Minidumps: *.dmp in the configured MinidumpDir (default %SystemRoot%\Minidump):
        count, newest date, total size, and the 5 most recent files.
      * Full/kernel dump: the configured DumpFile (default %SystemRoot%\MEMORY.DMP):
        whether it exists, its size and date.
      * Settings: HKLM\SYSTEM\CurrentControlSet\Control\CrashControl values
        CrashDumpEnabled, DumpFile, MinidumpDir, AutoReboot (and FilterPages, which
        with CrashDumpEnabled = 1 means an Active memory dump).

    A dump written inside $Context.TimeRange raises a Warning. Listing the Minidump
    folder can require elevation; a denied listing yields an Information finding
    ("requires elevation") instead of a failure. Read-only; never throws.

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
        Name          = 'Crash Dumps'
        Id            = 'reliability.crash-dumps'
        Group         = 'reliability'
        NetworkAccess = 'None'
        Category      = 'Reliability'
        Description   = 'Minidump and MEMORY.DMP inventory plus the configured crash dump settings.'
        RequiresAdmin = $false   # the Minidump folder listing may need elevation; reported, not failed
        Order         = 620
        Enabled       = $true
    }
}

# ---------------------------------------------------------------------------
# Private helpers (one per data source, so tests can mock them)
# ---------------------------------------------------------------------------

function Test-OmniCrashDumpWindowsHost {
    <# .SYNOPSIS Returns $true on Windows (crash dumps are a Windows feature). #>
    [OutputType([bool])]
    param()
    try { if ($IsWindows -eq $false) { return $false } } catch { Write-Debug $_.Exception.Message }
    return $true
}

function Get-OmniCrashControlSetting {
    <#
    .SYNOPSIS
        Reads HKLM\SYSTEM\CurrentControlSet\Control\CrashControl; $null when unreadable.
    #>
    [OutputType([object])]
    param()
    try {
        return (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Get-OmniMinidumpFile {
    <#
    .SYNOPSIS
        Lists *.dmp files (metadata only) in a folder. Returns @() when the folder does
        not exist; throws when the listing fails (for example, access denied).
    #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Filter '*.dmp' -File -Force -ErrorAction Stop)
}

function Get-OmniMemoryDumpFile {
    <#
    .SYNOPSIS
        Returns the file item (metadata only) for the full/kernel dump, $null when it
        does not exist; throws when access is denied.
    #>
    [OutputType([object])]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
}

function Test-OmniCrashDumpAccessDenied {
    <#
    .SYNOPSIS
        True when an error record means access denied (by type/category, never by the
        localized message).
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($ex -is [System.UnauthorizedAccessException]) { return $true }
        $ex = $ex.InnerException
    }
    try { if ([string]$ErrorRecord.CategoryInfo.Category -eq 'PermissionDenied') { return $true } } catch { Write-Debug $_.Exception.Message }
    return $false
}

function Get-OmniCrashDumpTypeName {
    <# .SYNOPSIS Plain-English name for a CrashDumpEnabled (+ FilterPages) value. #>
    [OutputType([string])]
    param([AllowNull()] [object] $CrashDumpEnabled, [AllowNull()] [object] $FilterPages)
    if ($null -eq $CrashDumpEnabled) { return 'Unknown' }
    switch ([int]$CrashDumpEnabled) {
        0 { return 'None' }
        1 { if ($null -ne $FilterPages -and [int]$FilterPages -eq 1) { return 'Active memory dump' } else { return 'Complete memory dump' } }
        2 { return 'Kernel memory dump' }
        3 { return 'Small memory dump' }
        7 { return 'Automatic memory dump' }
    }
    return ('Unknown ({0})' -f $CrashDumpEnabled)
}

function Get-OmniCrashControlValue {
    <# .SYNOPSIS Reads one property from the CrashControl object; $null when absent. #>
    param([AllowNull()] [object] $Setting, [string] $Name)
    if ($null -eq $Setting) { return $null }
    $p = $Setting.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Resolve-OmniDumpPath {
    <# .SYNOPSIS Expands environment variables in a configured path, or returns the default. #>
    [OutputType([string])]
    param([AllowNull()] [object] $Configured, [Parameter(Mandatory)] [string] $Default)
    $value = [string]$Configured
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    return [System.Environment]::ExpandEnvironmentVariables($value)
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

    $result = New-OmniResult -ModuleName 'Crash Dumps' -Category 'Reliability' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $component = 'Reliability/Crash Dumps'

    if (-not (Test-OmniCrashDumpWindowsHost)) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.crash-dumps.platform' `
            -Title 'Crash dump inventory is unavailable on this platform' -Severity 'Information' `
            -Component $component -Detail 'Windows crash dumps (Minidump, MEMORY.DMP) exist only on Windows.')
        return (Complete-OmniResult -Result $result)
    }

    $start = $Context.TimeRange.Start
    $rangeLabel = $Context.TimeRange.Label

    # --- Settings ---------------------------------------------------------
    $cc = Get-OmniCrashControlSetting
    $enabled = Get-OmniCrashControlValue -Setting $cc -Name 'CrashDumpEnabled'
    $filterPages = Get-OmniCrashControlValue -Setting $cc -Name 'FilterPages'
    $autoReboot = Get-OmniCrashControlValue -Setting $cc -Name 'AutoReboot'
    $dumpTypeName = Get-OmniCrashDumpTypeName -CrashDumpEnabled $enabled -FilterPages $filterPages
    $minidumpDir = Resolve-OmniDumpPath -Configured (Get-OmniCrashControlValue -Setting $cc -Name 'MinidumpDir') -Default '%SystemRoot%\Minidump'
    $dumpFile = Resolve-OmniDumpPath -Configured (Get-OmniCrashControlValue -Setting $cc -Name 'DumpFile') -Default '%SystemRoot%\MEMORY.DMP'

    Set-OmniResultMetric -Result $result -Name 'CrashDumpType' -Value $dumpTypeName
    Set-OmniResultMetric -Result $result -Name 'CrashDumpEnabled' -Value $(if ($null -ne $enabled) { [int]$enabled } else { $null })
    Set-OmniResultMetric -Result $result -Name 'AutoReboot' -Value $(if ($null -ne $autoReboot) { [bool][int]$autoReboot } else { $null })
    Set-OmniResultMetric -Result $result -Name 'MinidumpDir' -Value $minidumpDir
    Set-OmniResultMetric -Result $result -Name 'DumpFile' -Value $dumpFile

    $autoRebootText = if ($null -eq $autoReboot) { 'unknown' } elseif ([int]$autoReboot -eq 1) { 'on' } else { 'off' }
    $settingsText = "Dump type: $dumpTypeName; dump file: $dumpFile; minidump folder: $minidumpDir; automatic restart: $autoRebootText."
    if ($null -eq $cc) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.crash-dumps.settings' `
            -Title 'Crash dump settings could not be read' -Severity 'Information' -Component $component `
            -Detail 'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl was not readable; the default dump locations were checked.')
    } elseif ($null -ne $enabled -and [int]$enabled -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.crash-dumps.settings' `
            -Title 'Crash dumps are disabled' -Severity 'Information' -Component $component `
            -Detail "Windows will not write a memory dump after a bug check (CrashDumpEnabled = 0). $settingsText" `
            -Recommendation 'Set "Write debugging information" to Automatic or Small memory dump (System Properties > Advanced > Startup and Recovery) so the next blue screen can be analyzed.')
    } else {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.crash-dumps.settings' `
            -Title 'Crash dump settings' -Severity 'Information' -Component $component -Detail $settingsText)
    }

    if ($Context.CancellationToken.IsCancellationRequested) {
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    # --- Minidumps --------------------------------------------------------
    $minidumps = @()
    $minidumpDenied = $false
    try {
        $minidumps = @(Get-OmniMinidumpFile -Path $minidumpDir)
    } catch {
        if (Test-OmniCrashDumpAccessDenied -ErrorRecord $_) {
            $minidumpDenied = $true
        } elseif ($log) {
            $log.Debug("Minidump listing failed: $($_.Exception.Message)", 'Crash Dumps')
        }
    }
    $minidumps = @($minidumps | Sort-Object -Property LastWriteTime -Descending)
    $totalBytes = [long]0
    foreach ($f in $minidumps) { $totalBytes += [long]$f.Length }
    $recentList = @($minidumps | Select-Object -First 5 | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; LastWriteTime = $_.LastWriteTime; SizeKB = [math]::Round($_.Length / 1KB, 1) }
    })

    Set-OmniResultMetric -Result $result -Name 'MinidumpCount' -Value $(if ($minidumpDenied) { $null } else { $minidumps.Count })
    Set-OmniResultMetric -Result $result -Name 'MinidumpTotalMB' -Value $(if ($minidumpDenied) { $null } else { [math]::Round($totalBytes / 1MB, 2) })
    Set-OmniResultMetric -Result $result -Name 'MinidumpNewest' -Value $(if ($minidumps.Count -gt 0) { $minidumps[0].LastWriteTime } else { $null })
    Set-OmniResultMetric -Result $result -Name 'RecentMinidumps' -Value $recentList

    if ($minidumpDenied) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.crash-dumps.requires-elevation' `
            -Title 'Minidump folder requires elevation' -Severity 'Information' -Component $component `
            -Detail "Listing $minidumpDir was denied, so minidumps were not counted (requires elevation)." `
            -Recommendation 'Re-run OmniDiag as Administrator to inventory the minidumps.')
    }

    if ($Context.CancellationToken.IsCancellationRequested) {
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    # --- MEMORY.DMP -------------------------------------------------------
    $memoryDump = $null
    $memoryDenied = $false
    try {
        $memoryDump = Get-OmniMemoryDumpFile -Path $dumpFile
    } catch {
        if (Test-OmniCrashDumpAccessDenied -ErrorRecord $_) {
            $memoryDenied = $true
        } elseif ($log) {
            $log.Debug("Memory dump lookup failed: $($_.Exception.Message)", 'Crash Dumps')
        }
    }
    Set-OmniResultMetric -Result $result -Name 'MemoryDumpExists' -Value $(if ($memoryDenied) { $null } else { $null -ne $memoryDump })
    Set-OmniResultMetric -Result $result -Name 'MemoryDumpSizeMB' -Value $(if ($memoryDump) { [math]::Round($memoryDump.Length / 1MB, 1) } else { $null })
    Set-OmniResultMetric -Result $result -Name 'MemoryDumpDate' -Value $(if ($memoryDump) { $memoryDump.LastWriteTime } else { $null })

    # --- Findings ---------------------------------------------------------
    $recentMini = @($minidumps | Where-Object { $_.LastWriteTime -ge $start })
    $recentMemory = ($null -ne $memoryDump -and $memoryDump.LastWriteTime -ge $start)
    Set-OmniResultMetric -Result $result -Name 'RecentDumpCount' -Value ($recentMini.Count + $(if ($recentMemory) { 1 } else { 0 }))

    $listText = ($recentList | ForEach-Object { '{0} ({1:yyyy-MM-dd HH:mm}, {2} KB)' -f $_.Name, $_.LastWriteTime, $_.SizeKB }) -join '; '
    $memoryText = if ($memoryDump) { 'MEMORY.DMP: {0:yyyy-MM-dd HH:mm}, {1} MB.' -f $memoryDump.LastWriteTime, [math]::Round($memoryDump.Length / 1MB, 1) } else { 'No full/kernel memory dump.' }
    $data = [pscustomobject]@{
        MinidumpCount = $minidumps.Count; MinidumpTotalMB = [math]::Round($totalBytes / 1MB, 2); RecentMinidumps = $recentList
        MemoryDump = $(if ($memoryDump) { [pscustomobject]@{ Path = $dumpFile; LastWriteTime = $memoryDump.LastWriteTime; SizeMB = [math]::Round($memoryDump.Length / 1MB, 1) } } else { $null })
    }

    if ($recentMini.Count -gt 0 -or $recentMemory) {
        $parts = @()
        if ($recentMini.Count -gt 0) { $parts += "$($recentMini.Count) minidump(s)" }
        if ($recentMemory) { $parts += 'a full/kernel memory dump' }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.crash-dumps.recent-dumps' `
            -Title 'Crash dumps were written in the selected range' -Severity 'Warning' -Component $component `
            -Detail ("Windows wrote {0} in {1}, so the system bug-checked (blue screen). Most recent minidumps: {2}. {3}" -f ($parts -join ' and '), $rangeLabel, $(if ($listText) { $listText } else { 'none' }), $memoryText) `
            -LikelyCause 'A kernel-mode crash, most often a faulty or outdated driver, failing memory or storage, or overheating.' `
            -Confidence 75 `
            -Recommendation 'Analyze the dumps with WinDbg (!analyze -v) to find the faulting driver, and correlate with BugCheck (event 1001) and Kernel-Power 41 events at the same times.' `
            -Data $data)
    } elseif ($minidumps.Count -gt 0 -or $memoryDump) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.crash-dumps.inventory' `
            -Title 'Older crash dumps are present' -Severity 'Information' -Component $component `
            -Detail ("{0} minidump(s) totalling {1} MB, none in {2}. Most recent: {3}. {4}" -f $minidumps.Count, [math]::Round($totalBytes / 1MB, 2), $rangeLabel, $(if ($listText) { $listText } else { 'none' }), $memoryText) `
            -Recommendation 'No recent crashes; the old dumps can be analyzed with WinDbg if earlier blue screens matter, or removed to free space.' `
            -Data $data)
    } elseif (-not $minidumpDenied -and -not $memoryDenied) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'reliability.crash-dumps.none' `
            -Title 'No crash dumps found' -Severity 'Pass' -Component $component `
            -Detail "No minidumps in $minidumpDir and no memory dump at $dumpFile.")
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
