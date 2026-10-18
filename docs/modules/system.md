# System (`system`)

Operating system, hardware, firmware, and device inventory: what this machine is, before
anything else is diagnosed.

## Run it

```bat
omnidiag system
omnidiag system --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagSystem
Get-OmniDiagSystem -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| System | `system.system` | Operating system, firmware, and hardware identity inventory. | Not required | None |
| System Information | `system.system-information` | Hardware, firmware, and operating system inventory. | Not required | None |

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
