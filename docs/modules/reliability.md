# Reliability (`reliability`)

Crashes, hangs, and unexpected shutdowns over the selected range: how stable this machine
has been.

## Run it

```bat
omnidiag reliability
omnidiag reliability --range 30d --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagReliability
Get-OmniDiagReliability -Range Last30Days -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| Crash Dumps | `reliability.crash-dumps` | Minidump and MEMORY.DMP inventory plus the configured crash dump settings. | Not required (listing the Minidump folder may need it; reported, not failed) | None |
| Reliability | `reliability.reliability` | Application crashes/hangs and unexpected shutdowns over time. | Not required | None |
| Reliability Monitor | `reliability.reliability-monitor` | Reliability Monitor stability index and failure records (application, Windows, hardware, installs). | Not required (access denied is reported as "requires elevation") | None |

## What it checks

- **Reliability** - counts application crashes (Application Error 1000), hangs (Application
  Hang 1002), and unexpected shutdowns (Kernel-Power 41) in the selected range. Warning for
  more than 5 crashes or any unexpected shutdown. Each Id is filtered by its provider
  (`Application Error`, `Application Hang`, `Microsoft-Windows-Kernel-Power`), since other
  providers reuse the same Ids. Every query is bounded by the range and by
  `ReliabilityMaxEvents` (default 1000); a count that reaches the cap is a lower bound
  (metric `EventCountsCapped`). Only "no matching events" counts as zero; any other read
  error (for example access denied) gives an Information "could not read" finding
  (`reliability.reliability.unreadable`) instead of the healthy Pass.
- **Reliability Monitor** - the data behind Reliability Monitor (`perfmon /rel`):
  - the System Stability Index (1 = least stable, 10 = most stable): latest value, minimum,
    average, and trend over the range (`Improving` / `Declining` when the latest sample
    differs from the first by 0.5 or more, else `Stable`; `Unknown` with one sample).
    Error below `StabilityErrorIndex` (default 1), Warning below `StabilityWarnIndex`
    (default 3), Pass otherwise. The defaults are deliberately low: every application
    crash costs index points that recover only slowly, so a few crashes push a typical,
    otherwise healthy desktop below 5;
  - reliability records summarized by category, with the 5 most frequent ProductName /
    SourceName per category. Categories are assigned by source and event id (not message
    text): application failures (Application Error 1000, Application Hang 1002), Windows
    failures (WER-SystemErrorReporting/BugCheck 1001, EventLog 6008, Windows Error Reporting
    1001 `BlueScreen`), hardware failures (WHEA-Logger, Windows Error Reporting 1001
    `LiveKernelEvent`), failed installs (WindowsUpdateClient 20, MsiInstaller 11708), and
    successful installs (WindowsUpdateClient 19, MsiInstaller 11707; metric only). The
    hardware mapping is best-effort. Application failures: Warning at `AppFailureWarnCount`
    (default 5), else Information; any Windows or hardware failure: Warning; failed installs:
    Warning at 3 or more, else Information.
- **Crash Dumps** - the kernel crash dumps written after a bug check: the count, newest date,
  and total size of `*.dmp` in the minidump folder with the 5 most recent files, and whether
  the full/kernel dump file exists (size, date). Also reports the CrashControl settings (dump
  type, dump file, minidump folder, automatic restart). A dump written inside the range is a
  Warning (the machine blue-screened); only older dumps is Information; no dumps is Pass.
  Dump contents are never opened, only file metadata.

## Data sources

| Scanner | Source |
|---|---|
| Reliability | `Get-WinEvent -FilterHashtable` (Application 1000/1002, System 41) with `StartTime`/`EndTime` and `MaxEvents` |
| Reliability Monitor | `Win32_ReliabilityStabilityMetrics` (`SystemStabilityIndex`, `TimeGenerated`) and `Win32_ReliabilityRecords` (`SourceName`, `ProductName`, `EventIdentifier`, `TimeGenerated`, `InsertionStrings`) in root\cimv2, each queried with a WQL `WHERE TimeGenerated >= '<start>' AND TimeGenerated <= '<end>'` (UTC DMTF datetimes) and capped at `ReliabilityMaxRecords` / `MaxStabilitySamples` (default 2000 each). 120-second time budget. |
| Crash Dumps | `HKLM\SYSTEM\CurrentControlSet\Control\CrashControl` (`CrashDumpEnabled`, `FilterPages`, `DumpFile`, `MinidumpDir`, `AutoReboot`); file metadata of `MinidumpDir\*.dmp` (default `%SystemRoot%\Minidump`) and `DumpFile` (default `%SystemRoot%\MEMORY.DMP`) |

The Reliability WMI classes are filled by the Reliability Analysis Component (the RacTask
scheduled task, `\Microsoft\Windows\RAC`) and need the "Configure Reliability WMI Providers"
policy, which is enabled by default on Windows client and disabled by default on Windows
Server. When both classes return nothing, the scanner says data collection is probably
disabled instead of reporting a healthy machine.

`CrashDumpEnabled`: 0 none, 1 complete (with `FilterPages` = 1: active), 2 kernel, 3 small,
7 automatic memory dump.

## Elevation

No scanner in this group requires administrator rights at the module level. Without them:

- Reliability Monitor: if the WMI provider denies access, an Information finding says the data
  "requires elevation"; whatever could be read is still reported.
- Crash Dumps: if listing the minidump folder is denied, an Information finding says it
  "requires elevation" and `MinidumpCount` is left empty; the settings and the memory dump
  are still reported.

## Network access

None. Every scanner in this group is local-only.

## Findings it can emit

| Scanner | Finding (Id) | Severity | When |
|---|---|---|---|
| Reliability | N application crashes (`reliability.reliability.app-crashes`) | Warning | More than 5 events 1000 |
| Reliability | Could not read some crash and shutdown events (`reliability.reliability.unreadable`) | Information | A query failed with an error other than "no matching events" (no healthy Pass then) |
| Reliability | N unexpected shutdown(s) (`reliability.reliability.unexpected-shutdowns`) | Warning | Any Kernel-Power 41 |
| Reliability | System stability looks healthy (`reliability.reliability.healthy`) | Pass | Otherwise |
| Reliability Monitor | System stability index is very low / low / healthy (`reliability.reliability-monitor.stability-index`) | Error / Warning / Pass | Latest index < 1 / < 3 / otherwise |
| Reliability Monitor | N application failure(s) recorded (`...application-failures`) | Warning / Information | 5+ / 1-4 |
| Reliability Monitor | N Windows failure(s) recorded (`...windows-failures`) | Warning | Any bug check or unexpected shutdown record |
| Reliability Monitor | N hardware failure(s) recorded (`...hardware-failures`) | Warning | Any WHEA or LiveKernelEvent record |
| Reliability Monitor | N failed install(s) recorded (`...failed-installs`) | Warning / Information | 3+ / 1-2 |
| Reliability Monitor | No failures recorded by Reliability Monitor (`...no-failures`) | Pass | Records readable, none in a failure category |
| Reliability Monitor | No Reliability Monitor data was recorded (`...no-data`) | Information | Both classes empty (collection disabled) |
| Reliability Monitor | No stability index was calculated in the range (`...no-stability-data`) | Information | Records but no index samples |
| Reliability Monitor | Reliability Monitor data requires elevation (`...requires-elevation`) | Information | Access denied |
| Reliability Monitor | Reliability Monitor data is not available (`...unavailable`) | Information | Classes missing (Server Core, provider off) |
| Crash Dumps | Crash dumps were written in the selected range (`reliability.crash-dumps.recent-dumps`) | Warning | A minidump or the memory dump is newer than the range start |
| Crash Dumps | Older crash dumps are present (`reliability.crash-dumps.inventory`) | Information | Only dumps older than the range |
| Crash Dumps | No crash dumps found (`reliability.crash-dumps.none`) | Pass | No dumps and nothing denied |
| Crash Dumps | Crash dump settings / Crash dumps are disabled / settings could not be read (`reliability.crash-dumps.settings`) | Information | Always |
| Crash Dumps | Minidump folder requires elevation (`reliability.crash-dumps.requires-elevation`) | Information | Listing denied |
| All | ... unavailable on this platform (`<scanner id>.platform`) | Information | Not Windows |

Finding Ids carry no counts or other live values.

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. The Reliability WMI classes are not available
on Server Core; that is reported as an Information finding, never as a failure. On other
operating systems each scanner returns an Information finding.
