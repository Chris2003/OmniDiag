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
| Reliability | `reliability.reliability` | Application crashes/hangs and unexpected shutdowns over time. | Not required | None |

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
