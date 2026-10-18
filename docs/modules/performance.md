# Performance (`performance`)

CPU, memory, processes, and boot and startup performance: why the machine feels slow right
now, and how long it takes to start.

## Run it

```bat
omnidiag performance
omnidiag performance --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagPerformance
Get-OmniDiagPerformance -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| CPU | `performance.cpu` | Processor inventory, current load, and best-effort temperature. | Not required | None |
| Memory | `performance.memory` | Physical memory usage and pagefile utilization. | Not required | None |
| Performance | `performance.performance` | Current CPU, memory, and disk pressure with top resource consumers. | Not required | None |
| Processes | `performance.processes` | Running process count and top CPU/memory consumers. | Not required | None |
| Startup Performance | `performance.startup-performance` | Boot time, uptime, autostart item count, and boot duration. | Not required | None |

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
