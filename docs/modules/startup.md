# Startup and persistence (`startup`)

Autostart and persistence: what starts with Windows or the user session, from Run keys,
startup commands, and scheduled tasks, and whether the related registry keys are intact.

## Run it

```bat
omnidiag startup
omnidiag startup --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagStartup
Get-OmniDiagStartup -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| Registry Health | `startup.registry-health` | Integrity of security-relevant registry keys and values. | Not required | None |
| Scheduled Tasks | `startup.scheduled-tasks` | Enabled and third-party scheduled task inventory. | Not required | None |
| Startup | `startup.startup` | Autostart entries from registry Run keys and startup commands. | Not required | None |

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
