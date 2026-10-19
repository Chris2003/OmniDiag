# Storage (`storage`)

Disks and volumes: physical disk health, SMART and SSD wear, free space, where the space
went, and whether TRIM reaches the SSDs.

## Run it

```bat
omnidiag storage
omnidiag storage --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagStorage
Get-OmniDiagStorage -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| Disk | `storage.disk` | Physical disk health, volume free space, and SMART status. | Not required (SMART predict-failure data may need elevation) | None |
| Disk Usage | `storage.disk-usage` | Per-volume space usage. | Not required | None |
| Storage | `storage.storage` | Disk SMART health, SSD wear/temperature, volume health, and free space. | Not required (wear and temperature need elevation) | None |
| TRIM | `storage.trim` | TRIM (delete notification) state for NTFS and ReFS, correlated with SSDs. | Not required | None |

## What it checks

**Disk.** Every physical disk's `HealthStatus` (anything but Healthy is Critical); SMART
predict-failure flags (Critical); fixed volumes with less than 10% free (Warning).

**Disk Usage.** Used space per fixed volume; more than 90% used is a Warning. It does not
walk folders (that cost ~18 s and duplicated Temp Files).

**Storage.** Physical disk health (Unhealthy = Critical, other non-Healthy = Warning);
drive temperature at or above 65 C (Warning); SSD wear at 80% (Warning) and 90% (Critical);
`Get-Disk` health; volume health (non-Healthy = Error); free space at or below
`LowSpaceWarnPct` (default 10%, Warning) and `LowSpaceCritPct` (default 5%, Critical); and
the current disk queue length (5 or more = Warning).

**TRIM.** Whether NTFS and ReFS send delete notifications (TRIM / unmap) to the drives,
and whether an SSD is present:

- NTFS: `DisableDeleteNotification` = 1 means TRIM is off. Absent or 0 means on (the NTFS
  default).
- ReFS: `RefsDisableDeleteNotification` = 1 means off, 0 means on, absent means "not set"
  (the ReFS default applies: on for ReFS v1, off for ReFS v2, per the `fsutil behavior`
  documentation). Only an explicit 1 is reported.
- TRIM off with an SSD present is a Warning (for ReFS, only when a ReFS volume exists or
  the volume list is unknown). TRIM off with no SSD, or when the media type cannot be read,
  is Information.

## Data sources

| Scanner | Source |
|---|---|
| Disk | `Get-PhysicalDisk` (falls back to `Win32_DiskDrive`), `root\wmi:MSStorageDriver_FailurePredictStatus`, `Get-Volume` (falls back to `Win32_LogicalDisk`, `DriveType=3`) |
| Disk Usage | `Get-Volume` (falls back to `Win32_LogicalDisk`) |
| Storage | `Get-PhysicalDisk`, `Get-StorageReliabilityCounter`, `Get-Disk`, `Get-Volume`, `Get-Counter '\PhysicalDisk(_Total)\Current Disk Queue Length'` |
| TRIM | Registry `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem` values `DisableDeleteNotification` and `RefsDisableDeleteNotification` (the values `fsutil behavior query DisableDeleteNotify` reports; fsutil is never run); `Get-PhysicalDisk` `MediaType` (`SSD`, numeric 4); `Get-Volume` `FileSystem` for ReFS volumes |

All sources are structured (CIM, registry, cmdlet objects); nothing parses tool output, so
results do not depend on the display language. The disk queue counter path is the one
exception that is localized on non-English Windows; when it cannot be read the check is
skipped (logged at Debug), never reported as a failure.

## Elevation

Everything runs as a standard user. `Get-StorageReliabilityCounter` (temperature, wear)
and the SMART predict-failure class usually need elevation: without it Storage skips
temperature and wear per disk and Disk skips the SMART check, logging the reason; the
rest of each scanner still runs.

## Network access

None. Every scanner in this group is local-only.

## Findings it can emit

Finding Ids are stable: they name the disk or drive letter, never a percentage or size,
so the same problem keeps the same Id from run to run.

| Scanner | Finding (Id) | Severity | When |
|---|---|---|---|
| Disk | Disk health not Healthy: <model> (`disk-health-disk<n>`) | Critical | Physical disk `HealthStatus` is not Healthy |
| Disk | Disk status not OK: <model> (`disk-health-disk<n>`) | Critical | `Get-PhysicalDisk` unavailable and `Win32_DiskDrive.Status` is not OK |
| Disk | SMART predicts drive failure (`disk-smart-predict-failure-<instance>`) | Critical | `PredictFailure` is set |
| Disk | Low free space on X: (N%) (`disk-volume-low-space-<letter>`) | Warning | Fixed volume under 10% free |
| Disk | Disks healthy | Pass | No Warning or worse |
| Disk Usage | Drive X: is N% full (`disk-usage-drive-full-<letter>`) | Warning | Fixed volume over 90% used |
| Disk Usage | Disk usage within limits | Pass | No drive over 90% |
| Storage | Disk health: <status> - <name> (`storage-disk-health-<deviceid>`) | Critical / Warning | `HealthStatus` Unhealthy / other non-Healthy |
| Storage | High drive temperature (N C) (`storage-disk-temperature-<deviceid>`) | Warning | 65 C or more |
| Storage | SSD wear at N% (`storage-ssd-wear-<deviceid>`) | Warning / Critical | Wear 80% / 90% or more |
| Storage | Disk N health: <status> (`storage-disk-operational-<n>`) | Warning | `Get-Disk` health not Healthy |
| Storage | Volume X: health is <status> (`storage-volume-health-<letter>`) | Error | Volume `HealthStatus` not Healthy |
| Storage | Low / Critically low disk space on X: (N% free) (`storage-volume-low-space-<letter>`) | Warning / Critical | Free space at or below `LowSpaceWarnPct` / `LowSpaceCritPct` |
| Storage | High disk queue length (N) (`storage-disk-queue-length`) | Warning | Queue length 5 or more |
| Storage | Storage is healthy | Pass | No Warning or worse |
| TRIM | TRIM is disabled for NTFS (`storage-trim-ntfs-disabled`) | Warning / Information | Warning with an SSD present; Information with no SSD or unknown media |
| TRIM | TRIM is disabled for ReFS (`storage-trim-refs-disabled`) | Warning / Information | Warning with an SSD and ReFS volumes (or unknown volumes); otherwise Information |
| TRIM | TRIM is enabled (`storage-trim-enabled`) | Pass | NTFS TRIM on and no Warning |
| TRIM | TRIM setting not available (`storage-trim-not-available`) | Information | The FileSystem key cannot be read (non-Windows) |

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64: all checks. The Storage cmdlets
(`Get-PhysicalDisk`, `Get-Volume`) ship with Windows; where they are missing, Disk and
Disk Usage fall back to CIM. On a non-Windows host the scanners return without failing
(TRIM reports "TRIM setting not available").
