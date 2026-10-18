# Storage (`storage`)

Disks and volumes: physical disk health, SMART and SSD wear, free space, and where the
space went.

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
| Disk | `storage.disk` | Physical disk health, volume free space, and SMART status. | Not required | None |
| Disk Usage | `storage.disk-usage` | Per-volume space usage and largest top-level folders. | Not required | None |
| Storage | `storage.storage` | Disk SMART health, SSD wear/temperature, volume health, and free space. | Not required | None |

## What it checks

_To be completed by the group owner._

## Data sources

_To be completed by the group owner._

## Elevation

No scanner in this group requires administrator rights at the module level.

## Network access

None. Every scanner in this group is local-only.

## Findings it can emit

_To be completed by the group owner._

## Platforms

_To be completed by the group owner._
