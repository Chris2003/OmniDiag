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

## Quick install — launches the GUI

Open **PowerShell** or **Windows Terminal**, paste this command, and press Enter:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Chris2003/OmniDiag/main/install.ps1')))
```

This installs OmniDiag for the current user, clears Windows' downloaded-file block
from the validated application files, and opens the GUI immediately. No administrator
rights or machine-wide execution-policy change is required. Run the same command later
to update; the previous installation is retained as a dated backup.

> **Security:** this convenience command executes code retrieved from GitHub. Review
> [`install.ps1`](install.ps1) first, or use the inspect-then-run method below. For
> managed deployment, pin `-Ref` to a release tag or commit and provide
> `-ExpectedSha256`.

<details>
<summary>Safer inspect-then-run method</summary>

```powershell
$url = 'https://raw.githubusercontent.com/Chris2003/OmniDiag/main/install.ps1'
$installer = Join-Path $env:TEMP 'Install-OmniDiag.ps1'
Invoke-WebRequest $url -OutFile $installer
notepad $installer
```

After reviewing the file, run:

```powershell
Unblock-File $installer
& $installer
```

</details>

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

OmniDiag is being built in milestones. **Current: 0.3.1 — one-command GUI install, Version 3 enterprise posture, and optional local Ollama guidance.**

| Capability | State |
|---|---|
| Core engine, plugin architecture, health scoring | ✅ Milestone 1 |
| Structured logging, console runner | ✅ Milestone 1 |
| System Information module | ✅ Milestone 1 |
| Event Log collection & analysis (grouping, Event-ID translation, patterns) | ✅ Milestone 2 |
| **49 diagnostic scanners** across endpoint, network, security, identity, and cloud categories | ✅ |
| Role profiles and daily task workflows from Help Desk through Cloud Admin | ✅ 0.2.0 |
| Local Active Directory, Entra ID, and Intune/MDM posture checks | ✅ 0.2.0 |
| Certificates, proxy, VPN, time, BitLocker escrow posture, Defender onboarding, and update rings | ✅ 0.3.0 |
| Optional evidence-grounded local Ollama analysis | ✅ 0.3.0 |
| HTML / JSON / CSV / ZIP reports | ✅ Milestone 4 |
| PDF reports + branding (logo / accent color) | ✅ Milestone 6 |
| WPF GUI (dashboard, light/dark toggle, cancel) | ✅ Milestone 5 |
| Repair Center — console + GUI tab (11 repairs incl. CCleaner-style registry cleanup, dry-run, confirmation, restore points) | ✅ |
| Portable / standalone distribution (fully local, no remoting) | ✅ Version 2 |

See [ROADMAP.md](ROADMAP.md) for the full version plan.

### Diagnostic scanners (49)

| Category | Scanners |
|---|---|
| **System** | System · Startup · Scheduled Tasks · Services · Drivers · Windows Features · Environment Variables · Registry Health · Installed Software · Windows Update · System Health |
| **Performance** | CPU · Memory · Processes · Performance · Benchmark · Startup Performance |
| **Hardware** | GPU · Battery · USB Devices |
| **Storage** | Disk · Storage · Disk Usage · Temp Files |
| **Network** | Network · IP Configuration · DNS Resolver · Hosts File · Network Shares · WiFi Networks · Proxy Configuration · VPN |
| **Security** | Security · Firewall Rules · Certificates · BitLocker · Defender Onboarding |
| **Peripherals** | Printers |
| **Reliability** | Reliability |
| **Event Logs** | Event Logs · Error Summary |
| **Applications** | Browser Diagnostics |
| **Identity** | Active Directory · Time Synchronization |
| **Cloud** | Entra ID · Intune and MDM · Update Rings |
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

# Correlate the resulting evidence with a local Gemma 4 model through Ollama
ollama pull gemma4:e2b
.\OmniDiag.ps1 -Workflow QuickTriage -AiAnalysis

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

For private, on-device correlation, see the [Local Ollama Assistant](docs/OLLAMA.md).
The default `gemma4:e2b` model is the lightest Gemma 4 Ollama tag but is still about
7.2 GB; use `gemma3:1b` (about 815 MB) on low-memory technician devices.

## How it works

```
OmniDiag.ps1  ──>  Invoke-OmniDiag  ──>  Engine (Invoke-OmniSession)
                                            │
            Get-OmniModule (plugin discovery)
                                            │
                 ┌──────────────────────────┴──────────────────────────┐
                 ▼                          ▼                           ▼
          49 built-in diagnostic scanners                        (your module)
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
