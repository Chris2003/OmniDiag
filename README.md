<div align="center">

# OmniDiag

### One Tool. Complete Diagnostics.

A modern, **local-only**, open-source Windows diagnostic utility for IT professionals,
help desk technicians, sysadmins, consultants, and power users — Sysinternals-style,
but fully open and scriptable.

[![CI](https://github.com/OWNER/OmniDiag/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/OmniDiag/actions/workflows/ci.yml)
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

OmniDiag is being built in milestones. **Current: Milestone 5 — WPF GUI.**

| Capability | State |
|---|---|
| Core engine, plugin architecture, health scoring | ✅ Milestone 1 |
| Structured logging, console runner | ✅ Milestone 1 |
| System Information module | ✅ Milestone 1 |
| Event Log collection & analysis (grouping, Event-ID translation, patterns) | ✅ Milestone 2 |
| Network / Storage / Security / Health / Performance modules | ✅ Milestone 3 |
| HTML / JSON / CSV / ZIP reports | ✅ Milestone 4 |
| WPF GUI (dashboard, dark/light, cancel) | ✅ Milestone 5 |
| Repair Center, PDF reports | 🔜 Milestone 6 |

See [ROADMAP.md](ROADMAP.md) for the full version plan.

## Requirements

* Windows 10 / 11 / Server 2019+ (x64)
* Windows PowerShell **5.1** or PowerShell **7+**
* Some checks require **Administrator** rights (OmniDiag tells you which and skips them gracefully otherwise)

## Quick start

```powershell
# From the repository root
.\OmniDiag.ps1

# Scan only the last 24 hours, System category only
.\OmniDiag.ps1 -Range Last24Hours -IncludeCategory System

# Run elevated for a complete scan (recommended)
Start-Process pwsh -Verb RunAs -ArgumentList '-File', "$PWD\OmniDiag.ps1"

# Scan and generate reports (prompts with a privacy notice first)
.\OmniDiag.ps1 -Report -ReportFormat Html,Json,Csv,Zip -ReportPath .\reports

# Launch the graphical interface (dashboard, dark/light, cancel, export)
.\OmniDiag.ps1 -Gui
```

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

## How it works

```
OmniDiag.ps1  ──>  Invoke-OmniDiag  ──>  Engine (Invoke-OmniSession)
                                            │
            Get-OmniModule (plugin discovery)
                                            │
                 ┌──────────────────────────┴──────────────────────────┐
                 ▼                          ▼                           ▼
          7 built-in diagnostic modules                          (your module)
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
│   ├── Reporting/          # HTML/JSON/CSV/ZIP exporters
│   ├── UI/                 # WPF GUI (runtime XAML + runspace threading)
│   └── Cli/                # console presentation
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

The GUI provides a left-nav dashboard with a 0–100 health score, live scan progress
with a working Cancel button, dark/light themes, and one-click report export. Launch
it with `.\OmniDiag.ps1 -Gui`.

> _Captured screenshots will be added here; run `-Gui` on a Windows host to preview._

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Found a security
issue? Please read [SECURITY.md](SECURITY.md) first.

## License

[MIT](LICENSE) © OmniDiag Contributors
