# Services and drivers (`services`)

Windows services and device drivers: what is installed, what should be running but isn't,
and which devices report problems.

## Run it

```bat
omnidiag services
omnidiag services --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagServices
Get-OmniDiagServices -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| Drivers | `services.drivers` | Driver inventory and problem-device detection. | Not required | None |
| Services | `services.services` | Windows service inventory and stopped auto-start detection. | Not required | None |

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
