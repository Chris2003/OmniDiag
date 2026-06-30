# OmniDiag Roadmap

OmniDiag is delivered in milestones. Each milestone is independently usable and
gated on review before the next begins.

## Version 1 — Local diagnostics (in progress)
- [x] **M1** Core engine, plugin architecture, health scoring, logging, System Information
- [x] **M2** Event Log collection & analysis (grouping, Event-ID translation, findings)
- [x] **M3** Network, Storage, Windows Health, Security, Performance modules
- [x] **M4** Reporting engine: HTML, JSON, CSV, ZIP package
- [x] **M5** WPF GUI: dashboard, left navigation, dark/light, progress, cancel

## Version 2 — Repair & richer output (in progress)
- [x] **M6** Repair Center (flush DNS, reset Winsock, IP release/renew, restart
      services, Print Spooler, clear temp, SFC, DISM, Windows Update reset, restart
      Explorer) — console + engine **and a GUI Repair Center tab**, with dry-run,
      confirmation, and a restore point before risky repairs.
- [x] **M6** PDF reports (headless Edge/Chrome rendering of the HTML report)
- [x] **M6** Optional branding on reports (organization name + logo + accent color)
- [ ] Remote diagnostics over PowerShell Remoting

## Version 3 — Enterprise integrations
- [ ] Active Directory checks
- [ ] Microsoft 365 checks
- [ ] Intune checks
- [ ] Entra ID checks

## Version 4 — Cross-platform
- [ ] Linux support
- [ ] macOS support

## Version 5 — AI-assisted troubleshooting
- [ ] Natural-language search over findings
- [ ] Deeper root-cause correlation across modules
- [ ] Automated repair suggestions

## Additional diagnostic modules (scheduled across M3+)
Microsoft 365 · Browser · Printing · USB · Battery
