<div align="center">

# OmniDiag

### One Tool. Complete Diagnostics.

A modern, **local-only**, open-source Windows diagnostic utility for IT professionals,
help desk technicians, sysadmins, consultants, and power users — Sysinternals-style,
but fully open and scriptable.

[![CI](https://github.com/Chris2003/OmniDiag/actions/workflows/ci.yml/badge.svg)](https://github.com/Chris2003/OmniDiag/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE.svg)](#requirements)

</div>

---

## Why OmniDiag

Diagnosing a sick Windows machine means jumping between Event Viewer, `ipconfig`,
`Get-PhysicalDisk`, Device Manager, `sfc`, `powercfg`, and a dozen other tools, then
mentally stitching the results together. OmniDiag runs all of those checks from **one
interface**, interprets the results, and tells you the **likely cause** and the
**recommended next step** — not just raw output.

* **Diagnose first, repair second.** Repairs are always optional and require confirmation.
* **Local-only by design.** Nothing is ever uploaded. No telemetry, no ads, no cloud.
* **Plugin architecture.** New diagnostic modules drop in without touching the core.
* **Scriptable.** Every layer is plain PowerShell you can read, audit, and automate.

> ⚠️ **Privacy:** Collected data and reports may contain usernames, device names, file
> paths, domains, and internal system information. OmniDiag keeps everything local —
> **review any report before you share it.**

## Status

OmniDiag is being built in milestones. **Current: 0.2.0 — guided technician workflows and enterprise identity posture.**

| Capability | State |
|---|---|
| Core engine, plugin architecture, health scoring | ✅ Milestone 1 |
| Structured logging, console runner | ✅ Milestone 1 |
| System Information module | ✅ Milestone 1 |
| Event Log collection & analysis (grouping, Event-ID translation, patterns) | ✅ Milestone 2 |
| **42 diagnostic scanners** across endpoint, network, security, identity, and cloud categories | ✅ |
| Role profiles and daily task workflows from Help Desk through Cloud Admin | ✅ 0.2.0 |
| Local Active Directory, Entra ID, and Intune/MDM posture checks | ✅ 0.2.0 |
| HTML / JSON / CSV / ZIP reports | ✅ Milestone 4 |
| PDF reports + branding (logo / accent color) | ✅ Milestone 6 |
| WPF GUI (dashboard, light/dark toggle, cancel) | ✅ Milestone 5 |
| Repair Center — console + GUI tab (11 repairs incl. CCleaner-style registry cleanup, dry-run, confirmation, restore points) | ✅ |
| Portable / standalone distribution (fully local, no remoting) | ✅ Version 2 |

See [ROADMAP.md](ROADMAP.md) for the full version plan.

### Diagnostic scanners (42)

| Category | Scanners |
|---|---|
| **System** | System · Startup · Scheduled Tasks · Services · Drivers · Windows Features · Environment Variables · Registry Health · Installed Software · Windows Update · System Health |
| **Performance** | CPU · Memory · Processes · Performance · Benchmark · Startup Performance |
| **Hardware** | GPU · Battery · USB Devices |
| **Storage** | Disk · Storage · Disk Usage · Temp Files |
| **Network** | Network · IP Configuration · DNS Resolver · Hosts File · Network Shares · WiFi Networks |
| **Security** | Security · Firewall Rules |
| **Peripherals** | Printers |
| **Reliability** | Reliability |
| **Event Logs** | Event Logs · Error Summary |
| **Applications** | Browser Diagnostics |
| **Identity** | Active Directory |
| **Cloud** | Entra ID · Intune and MDM |
| **Health** | Windows Health |

Each scanner is a self-contained plugin; filter a run with `-IncludeCategory` / `-ExcludeCategory`.

## Requirements

* Windows 10 / 11 / Server 2019+ (x64)
* Windows PowerShell **5.1** or PowerShell **7+**
* Some checks require **Administrator** rights (OmniDiag tells you which and skips them gracefully otherwise)

## Portable edition

OmniDiag runs fully locally with no installation. To produce a self-contained,
copy-anywhere package (folder + zip), run:

```powershell
.\build\Build-Portable.ps1        # writes dist\OmniDiag-<version>-portable.zip (+ .sha256)
```

Extract it anywhere and run it — no install, no remoting, admin optional:

* **Console scan** — double-click `OmniDiag.cmd`
* **Graphical interface** — double-click `OmniDiag-GUI.cmd`
* **From PowerShell** — `.\OmniDiag.ps1`

The `.cmd` launchers bypass the execution policy **for that process only** (no
machine-wide change), so an extracted-from-zip copy runs on locked-down hosts where
script execution is otherwise blocked. Deploy across a fleet with the tooling you
already have (Intune / ConfigMgr / GPO / RMM) and collect the reports — see
[PORTABLE.md](PORTABLE.md).

## Quick start

```powershell
# From the repository root
.\OmniDiag.ps1

# See guided plans for every technician level and common daily task
.\OmniDiag.ps1 -ListPlans

# Role-focused scans
.\OmniDiag.ps1 -Profile HelpDesk
.\OmniDiag.ps1 -Profile CloudAdmin

# Task-focused scans
.\OmniDiag.ps1 -Workflow QuickTriage
.\OmniDiag.ps1 -Workflow LoginAndIdentity

# Scan only the last 24 hours, System category only
.\OmniDiag.ps1 -Range Last24Hours -IncludeCategory System

# Run only specific scanners by name (the GUI Diagnostics tab does the same)
.\OmniDiag.ps1 -IncludeModule CPU,Memory,Disk,Network

# Run elevated for a complete scan (recommended)
Start-Process pwsh -Verb RunAs -ArgumentList '-File', "$PWD\OmniDiag.ps1"

# Scan and generate reports (prompts with a privacy notice first)
.\OmniDiag.ps1 -Report -ReportFormat Html,Json,Csv,Zip -ReportPath .\reports

# Branded PDF report (native PDF - no browser or external dependency required)
.\OmniDiag.ps1 -Report -ReportFormat Pdf,Html -BrandName "Acme IT" -BrandColor "#0969DA" -BrandLogo .\logo.png

# Launch the graphical interface (dashboard, dark/light, cancel, export)
.\OmniDiag.ps1 -Gui

# Scan, then open the Repair Center (confirmation-gated fixes for what was found)
.\OmniDiag.ps1 -Repair

# Preview repairs without changing anything (dry run)
.\OmniDiag.ps1 -Repair -RepairDryRun
```

> **Repair Center:** repairs are always opt-in and confirmed per action. Each shows its
> risk (Safe / Moderate / Destructive) and whether it needs elevation or a reboot, and a
> System Restore point is created before system-altering repairs. Run elevated for the
> full set (SFC, DISM, Winsock/Windows Update reset, service restarts).

> **GUI note:** WPF requires an STA thread. Windows PowerShell 5.1 is STA, so the GUI
> runs directly. PowerShell 7 is MTA — OmniDiag automatically hosts the window in a
> dedicated STA runspace, so `-Gui` works there too.

You can also use the module directly for automation:

```powershell
Import-Module .\src\OmniDiag.psd1
$session = Invoke-OmniDiag -Range Last7Days
$session.Summary.Score          # 0-100 overall health score
$session.Results                # per-module results & findings

# Generate reports from a session
Export-OmniReport -Session $session -OutputDirectory .\reports -Format Html,Json,Csv,Zip
```

See the [Technician Guide](docs/TECHNICIAN_GUIDE.md) for role and daily-task
workflows. The [Improvement Plan](docs/IMPROVEMENT_PLAN.md) explains the phased path
from guided endpoint triage to enterprise operations, cross-platform support, and
evidence-grounded assistance.

## How it works

```
OmniDiag.ps1  ──>  Invoke-OmniDiag  ──>  Engine (Invoke-OmniSession)
                                            │
            Get-OmniModule (plugin discovery)
                                            │
                 ┌──────────────────────────┴──────────────────────────┐
                 ▼                          ▼                           ▼
          42 built-in diagnostic scanners                        (your module)
  System · EventLogs · Network · Storage · Health · Security · Performance
                 │                          │                           │
                 └─── each returns an OmniDiag.Result of Findings ──────┘
                                            │
                              Get-OmniHealthScore  ──>  Dashboard / Reports
```

Each diagnostic module is a self-contained `.psm1` implementing two functions
(`Get-OmniModuleManifest`, `Invoke-OmniModuleScan`). The engine discovers them,
runs them against a shared context (logger, time range, cancellation token,
elevation state), and aggregates their findings into a scored session.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details and a guide to
writing your own module.

## Repository layout

```text
OmniDiag/
├── OmniDiag.ps1            # launcher
├── src/
│   ├── OmniDiag.psd1       # module manifest
│   ├── OmniDiag.psm1       # public entry points
│   ├── Core/               # models, logging, registry, engine, scoring
│   ├── EventLog/           # event-log knowledge base + analysis pipeline
│   ├── Modules/            # diagnostic plugins (one .psm1 each)
│   ├── Repair/             # repair core: models, registry, engine
│   ├── Repairs/            # repair plugins (one .psm1 each)
│   ├── Reporting/          # HTML/JSON/CSV/ZIP exporters
│   ├── UI/                 # WPF GUI (runtime XAML + runspace threading)
│   └── Cli/                # console presentation (scan + repair)
├── Tests/                  # Pester tests
├── docs/  assets/  reports/  tools/
└── .github/workflows/      # CI
```

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path .\Tests
```

## Screenshots

The GUI provides a left-nav dashboard with a 0–100 health score, a **DxDiag-style System
Information panel** (OS, manufacturer/model, BIOS, processor, memory, DirectX, per-GPU
display, and audio devices), live scan progress
with a working Cancel button, a light/dark theme toggle (light by default), a
**Diagnostics** tab to toggle individual scanners on/off (or run any single scanner on
its own), report export with a **format picker** (choose HTML / JSON / CSV / PDF / ZIP
before exporting), and a **Repair Center** tab — a checkbox grid of repairs (relevant ones
pre-checked after a scan) with a dry-run toggle, summary confirmation, and live progress.
Launch it with `.\OmniDiag.ps1 -Gui`.

> _Captured screenshots will be added here; run `-Gui` on a Windows host to preview._

## Troubleshooting

**`The term '...' is not recognized` when launching.** Make sure you're running an
up-to-date copy — an earlier build limited the module's exported functions and could
fail at startup. Re-import with `Import-Module .\src\OmniDiag.psd1 -Force` (or just
re-run `.\OmniDiag.ps1`).

**Scripts won't run / "running of scripts is disabled."** Set an execution policy for
your session: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

**Downloaded a ZIP and files are "blocked."** Files extracted from an internet ZIP
carry Windows' Mark of the Web and may be blocked on stricter execution policies.
Clear it once with:

```powershell
Get-ChildItem -Recurse .\ | Unblock-File
```

**"running without administrator rights."** This is informational, not an error — some
checks are skipped without elevation. Re-run from an elevated prompt for a full scan
(see Quick start).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Found a security
issue? Please read [SECURITY.md](SECURITY.md) first.

## License

[MIT](LICENSE) © OmniDiag Contributors
