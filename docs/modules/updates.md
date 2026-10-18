# Windows Update and health (`updates`)

Windows Update state, history, and policy, pending reboots, and servicing health: is this
machine patched and able to keep patching?

## Run it

```bat
omnidiag updates
omnidiag updates --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagUpdates
Get-OmniDiagUpdates -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| System Health | `updates.system-health` | Servicing (CBS) log freshness; pending reboot is reported by Windows Health. | Not required | None |
| Update History | `updates.update-history` | Local Windows Update history: last successful install and failed installs. | Not required | None |
| Update Rings | `updates.update-rings` | Local Windows Update for Business and MDM update policy posture. | Not required | None |
| Windows Health | `updates.windows-health` | Pending reboot, update service state, and device/service problem counts. | Not required | None |
| Windows Update | `updates.windows-update` | Installed hotfix posture and Windows Update service state. | Not required | None |

## What it checks

**Update History.** Reads up to 200 entries (newest first) of the local Windows Update
history.

- Last successful installation (`Operation` = installation, `ResultCode` 2 succeeded or
  3 succeeded with errors): older than 45 days is a Warning, older than 90 days an Error;
  no successful installation in the history is a Warning. Microsoft Defender definition
  updates are excluded from this grade, because they install several times a day and
  would hide a stale patch level: titles containing KB2267602, KB915597, KB4052623,
  "Security Intelligence Update", or "Definition Update", and, when
  `IUpdateHistoryEntry2.Categories` is available, the Definition Updates category
  `E0789628-CE08-4437-BE74-2495B842F43B`. The newest definition update is reported
  separately (metrics `LastDefinitionUpdate`, `LastDefinitionUpdateAgeDays`).
- Failed (`ResultCode` 4) and aborted (5) installations inside the scan time range
  (`--range`, default `Last7Days`), grouped by update (the KB number; else the
  `UpdateIdentity.UpdateID` GUID, so version strings in titles never enter the finding
  Id; else the title without a trailing version), with the count, the most recent
  failure, and its HRESULT as `0xXXXXXXXX`. A failure is Information instead of Warning
  when the same update installed successfully afterwards. At most 15 updates are listed.
- A summary: entries read, total history size, last success, last definition update,
  failures in range.
- The history collection and every entry/category COM object are released after reading.
- Option: `Config.UpdateHistoryMaxEntries` (1-200, default 200).

**Windows Health.** The single, authoritative pending-reboot check of OmniDiag; the
`wuauserv` start type; and counts only (metrics `ProblemDevices`, `AutoServicesStopped`,
`StartupPrograms`) of Device Manager devices with a `ConfigManagerErrorCode`, stopped
automatic (non-delayed) services, and startup programs. Per-device findings are owned by
Drivers (`services.drivers`) and the per-service stopped check by Services
(`services.services`), so they are not duplicated. It is read-only: it never runs SFC or
DISM (see "Repairs" below).

**System Health.** Records the last write time of `%SystemRoot%\Logs\CBS\CBS.log`. It no
longer raises its own pending-reboot finding; its `PendingRebootCheckedBy` metric points
to `updates.windows-health`. The task workflows and role profiles that run System Health
also run Windows Health.

**Windows Update.** Hotfix count and newest `InstalledOn` (Warning after 60 days), and the
`wuauserv` status.

**Update Rings.** Windows Update for Business and MDM update policy values.

### Repairs

Scanners never repair. System file and component store repair are the opt-in repairs
`repair.run-system-file-checker-sfc` (`sfc /scannow`) and
`repair.repair-component-store-dism` (DISM RestoreHealth) in the Repair Center, which run only when a technician starts them. (Windows Health used to
have a `RunSfc` option that ran `sfc /verifyonly` from the scan; it was removed in Phase 2.
The documented `RunDism` option never existed and is gone from the help.)

## Data sources

| Scanner | Source |
|---|---|
| Update History | Windows Update Agent COM API, read-only: `Microsoft.Update.Session` -> `CreateUpdateSearcher()` -> `GetTotalHistoryCount()` and `QueryHistory(0, N)` (`IUpdateHistoryEntry`: `Date`, `Title`, `Operation`, `ResultCode`, `HResult`, `UpdateIdentity.UpdateID`). Fallback: `Get-HotFix` `InstalledOn` |
| Windows Health | Registry markers `...\Component Based Servicing\RebootPending`, `...\WindowsUpdate\Auto Update\RebootRequired`, `Session Manager\PendingFileRenameOperations`; `Win32_PnPEntity`; `Win32_Service`; `Get-Service wuauserv`; `Win32_StartupCommand` |
| System Health | File timestamp of `%SystemRoot%\Logs\CBS\CBS.log` |
| Windows Update | `Get-HotFix`; `Get-Service wuauserv` |
| Update Rings | Policy registry keys |

Result codes, operations, and HRESULTs are numeric, so nothing depends on the display
language. Update titles are shown as Windows stores them (localized).

## Elevation

Everything runs as a standard user. Reading the Windows Update history does not need
elevation.

## Network access

None. `IUpdateSearcher::QueryHistory` "synchronously queries the computer for the history
of the update events" and returns the event records stored on the computer (Microsoft
Learn); Update History never calls `IUpdateSearcher.Search`, `BeginSearch`, a downloader,
or an installer. The CI no-network job audits this on every build.

## Findings it can emit

| Scanner | Finding (Id) | Severity | When |
|---|---|---|---|
| Update History | Updates installed recently (`update-history-last-install-recent`) | Pass | Last success (definition updates excluded) within 45 days |
| Update History | No update installed in over 45 / 90 days (`update-history-last-install-stale`) | Warning / Error | Last success older than 45 / 90 days |
| Update History | No successful update installation recorded (`update-history-no-successful-install`) | Warning | No succeeded installation in the entries read |
| Update History | Update failed to install: KB... (`update-history-failed-<kb, UpdateID, or title>`) | Warning / Information | Failed or aborted inside the time range; Information when it installed later |
| Update History | Windows Update history summary (`update-history-summary`) | Information | Every run with history |
| Update History | Failed-update history not available (`update-history-com-unavailable`) | Information | COM API unavailable; last install graded from `Get-HotFix` |
| Update History | Update history not available (`update-history-not-available`) | Information | Neither source readable (non-Windows) |
| Windows Health | A system restart is pending (`windows-health-pending-reboot`) | Warning | Any reboot marker present |
| Windows Health | Windows Update service is disabled (`windows-health-wuauserv-disabled`) | Warning | `wuauserv` start type Disabled |
| Windows Health | Windows health checks passed | Pass | None of the above |
| System Health | Servicing log collected (`system-health-servicing-log`) | Pass | CBS log found |
| System Health | Servicing log not found (`system-health-servicing-log-not-found`) | Information | CBS log missing or unreadable |
| Windows Update | Most recent update is N days old | Warning | Newest hotfix older than 60 days |
| Windows Update | Windows Update posture healthy | Pass | Otherwise |

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64: all checks. On a non-Windows host the
scanners return Information or Pass findings without failing.
