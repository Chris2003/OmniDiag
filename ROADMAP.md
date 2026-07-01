# OmniDiag Roadmap

OmniDiag is delivered in milestones. Each milestone is independently usable and
gated on review before the next begins.

## Version 1 — Local diagnostics (in progress)
- [x] **M1** Core engine, plugin architecture, health scoring, logging, System Information
- [x] **M2** Event Log collection & analysis (grouping, Event-ID translation, findings)
- [x] **M3** Network, Storage, Windows Health, Security, Performance modules
- [x] **M4** Reporting engine: HTML, JSON, CSV, ZIP package
- [x] **M5** WPF GUI: dashboard, left navigation, dark/light, progress, cancel

## Version 2 — Repair & richer output (complete)
- [x] **M6** Repair Center (flush DNS, reset Winsock, IP release/renew, restart
      services, Print Spooler, clear temp, SFC, DISM, Windows Update reset, restart
      Explorer) — console + engine **and a GUI Repair Center tab**, with dry-run,
      confirmation, and a restore point before risky repairs.
- [x] **M6** PDF reports (native, browser-free writer - no external dependency)
- [x] **M6** Optional branding on reports (organization name + logo + accent color)
- [x] **Portable / standalone distribution** — a fully self-contained package that runs
      on any target machine without installation or remoting. No WinRM / PowerShell
      Remoting: OmniDiag is always executed **locally** on the machine being diagnosed
      (run directly, or deployed via the tooling that already exists — Intune, ConfigMgr,
      GPO scheduled task, or an RMM). `build/Build-Portable.ps1` assembles a versioned
      folder + zip (+ SHA256); `OmniDiag.cmd` / `OmniDiag-GUI.cmd` launchers bypass the
      execution policy per-process (no machine change) so an extracted-from-zip copy runs
      on locked-down hosts — offline and admin-optional. See `PORTABLE.md`.

> **Design principle — local-only, no remoting.** OmniDiag deliberately does **not**
> reach out to remote machines (WinRM/PSRemoting is disabled or firewalled on most
> enterprise endpoints). Every scan runs on the local host; "fleet" scenarios are served
> by running the portable tool on each machine and collecting the resulting reports, not
> by remote execution.

## Version 3 — Enterprise integrations (run locally)
Checks executed **on the local machine** (domain-joined / signed-in), not via remoting.
- [ ] Active Directory checks (local domain membership, secure channel, GPO, DC reachability)
- [ ] Microsoft 365 / Entra ID checks (sign-in state, Entra join/registration, Graph where available)
- [ ] Intune / MDM enrollment & policy health checks

## Version 4 — Cross-platform
- [ ] Linux support
- [ ] macOS support

## Version 5 — AI-assisted troubleshooting
- [ ] Natural-language search over findings
- [ ] Deeper root-cause correlation across modules
- [ ] Automated repair suggestions

## Diagnostic scanners
Expanded from the original consolidated modules to **35 granular scanners** across 10
categories (System, Performance, Hardware, Storage, Network, Security, Peripherals,
Reliability, Event Logs, Applications). This delivered the previously-scheduled
Browser · Printing (Printers) · USB · Battery scanners plus many more (Scheduled Tasks,
Hosts File, Network Shares, WiFi, Registry Health, Windows Features, Environment
Variables, Benchmark, etc.). Microsoft 365 checks remain part of Version 3.
