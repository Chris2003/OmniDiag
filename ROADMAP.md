# OmniDiag Roadmap

OmniDiag is delivered in milestones. Each milestone is independently usable and
gated on review before the next begins.

## Version 1 — Local diagnostics (in progress)
- [x] **M1** Core engine, plugin architecture, health scoring, logging, System Information
- [ ] **M2** Event Log collection & analysis (grouping, Event-ID translation, findings)
- [ ] **M3** Network, Storage, Windows Health, Security, Performance modules
- [ ] **M4** Reporting engine: HTML, JSON, CSV, ZIP package
- [ ] **M5** WPF GUI: dashboard, left navigation, dark/light, progress, cancel

## Version 2 — Repair & richer output
- [ ] Repair Center (flush DNS, reset Winsock, IP release/renew, restart services,
      Print Spooler, clear temp, SFC, DISM, Windows Update reset, restart Explorer)
- [ ] PDF reports
- [ ] Optional branding on reports
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
