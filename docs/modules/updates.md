# Windows Update and health (`updates`)

Windows Update state and policy, pending reboots, servicing health, and component store
health: is this machine patched and able to keep patching?

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
| System Health | `updates.system-health` | Pending-reboot detection and servicing log freshness. | Not required | None |
| Update Rings | `updates.update-rings` | Local Windows Update for Business and MDM update policy posture. | Not required | None |
| Windows Health | `updates.windows-health` | Pending reboot, device errors, service state, and update health. | Not required | None |
| Windows Update | `updates.windows-update` | Installed hotfix posture and Windows Update service state. | Not required | None |

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
