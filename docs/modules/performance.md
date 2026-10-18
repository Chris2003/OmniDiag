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

- **CPU** - processor model, cores, and clock (`Win32_Processor`); current load from one
  1-second counter sample; temperature best-effort. Warning when the load is above 90%.
- **Memory** - physical memory in use and pagefile utilization. Warning above 90% in use.
- **Performance** - a one-second snapshot of CPU, memory, disk activity, and GPU load plus the
  top consumers. Warning at `CpuWarnPct` / `RamWarnPct` (default 90%); Information when one
  process holds more than 2 GB of RAM.
- **Processes** - process count; the top 5 by CPU time and by working set; processes that are
  not responding (Warning); the system-wide **handle and thread totals** and the **top 5
  processes by handle count**. A process holding more than `HandleWarnCount` handles (default
  20,000) raises a Warning. Rationale: typical desktop processes hold hundreds to a few
  thousand handles, and busy ones (browsers, security agents, Explorer) routinely pass
  10,000, so the old 10,000 default was noisy; tens of thousands that keep growing are the classic sign of a handle leak,
  which eventually exhausts kernel pool memory or the per-process limit (16,777,216 handles)
  and makes the application or the whole machine misbehave. The Idle (PID 0) and System
  (PID 4) pseudo-processes are listed but never warned on, because their counts reflect the
  kernel rather than a leaking application. Otherwise an Information finding summarizes the
  totals and the top holders.
- **Startup Performance** - last boot time, uptime, number of autostart entries, and the last
  boot duration. Warning when boot took more than 60 s or there are more than 30 autostart
  entries.

## Data sources

| Scanner | Source |
|---|---|
| CPU | `Win32_Processor`; `\Processor(_Total)\% Processor Time`; `MSAcpi_ThermalZoneTemperature` (root/wmi, best-effort) |
| Memory | `Win32_OperatingSystem`, `Win32_PageFileUsage` |
| Performance | `Get-Counter` (processor, physical disk, GPU engine), `Win32_OperatingSystem`, `Get-Process` |
| Processes | `Get-Process` (`CPU`, `WorkingSet64`, `HandleCount`, `Threads`, `Responding`) |
| Startup Performance | `Win32_OperatingSystem`, `Win32_StartupCommand`, `Microsoft-Windows-Diagnostics-Performance/Operational` event 100 (newest only, `MaxEvents 1`) |

Counter paths are used only where no CIM equivalent gives a live sample; no tool output is
parsed.

## Elevation

No scanner in this group requires administrator rights at the module level.

## Network access

None. Every scanner in this group is local-only.

## Findings it can emit

| Scanner | Finding (Id when explicit) | Severity | When |
|---|---|---|---|
| CPU | Sustained high CPU load | Warning | Load above 90% |
| Memory | High memory usage | Warning | More than 90% of RAM in use |
| Performance | High CPU usage / High memory usage | Warning | At or above `CpuWarnPct` / `RamWarnPct` |
| Performance | `<process>` is using N GB of RAM | Information | One process holds more than 2 GB |
| Processes | N process(es) not responding (`performance.processes.not-responding`) | Warning | A windowed process is not responding |
| Processes | N process(es) hold more than 20000 handles (`performance.processes.handle-count-high`) | Warning | A process other than Idle/System is above `HandleWarnCount` |
| Processes | Handle and thread totals (`performance.processes.handle-summary`) | Information | No process is above the threshold |
| Processes | Top resource consumers | Information | Always (top 5 by CPU time) |
| Startup Performance | Slow boot / High number of startup items | Warning | Boot over 60 s / more than 30 autostart entries |
| All | `... metrics collected` / within normal limits | Pass | No Warning was raised |

Processes metrics: `ProcessCount`, `TopCpu`, `TopMemory`, `TotalHandleCount`,
`TotalThreadCount`, `TopHandles` (name, PID, handle count), `HighHandleProcessCount`,
`NotRespondingCount`.

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. Counters or the thermal zone class that a
platform does not expose are omitted from the metrics (logged at Debug), never reported as a
failure.
