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

OmniDiag is being built in milestones. **Current: Milestone 1 — core engine.**

| Capability | State |
|---|---|
| Core engine, plugin architecture, health scoring | ✅ Milestone 1 |
| Structured logging, console runner | ✅ Milestone 1 |
| System Information module | ✅ Milestone 1 |
| Event Log collection & analysis | 🔜 Milestone 2 |
| Network / Storage / Security / Health / Performance modules | 🔜 Milestone 3 |
| HTML / JSON / CSV / ZIP reports | 🔜 Milestone 4 |
| WPF GUI (dashboard, dark/light, cancel) | 🔜 Milestone 5 |
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
```

You can also use the module directly for automation:

```powershell
Import-Module .\src\OmniDiag.psd1
$session = Invoke-OmniDiag -Range Last7Days
$session.Summary.Score          # 0-100 overall health score
$session.Results                # per-module results & findings
```

## How it works

```
OmniDiag.ps1  ──>  Invoke-OmniDiag  ──>  Engine (Invoke-OmniSession)
                                            │
            Get-OmniModule (plugin discovery)
                                            │
                 ┌──────────────────────────┴──────────────────────────┐
                 ▼                          ▼                           ▼
        SystemInformation          (Network, Storage, …)        (your module)
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
│   ├── Modules/            # diagnostic plugins (one .psm1 each)
│   ├── Reporting/          # HTML/JSON/CSV/ZIP (Milestone 4)
│   ├── UI/                 # WPF GUI (Milestone 5)
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

> _GUI screenshots will be added with Milestone 5._

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Found a security
issue? Please read [SECURITY.md](SECURITY.md) first.

## License

[MIT](LICENSE) © OmniDiag Contributors
