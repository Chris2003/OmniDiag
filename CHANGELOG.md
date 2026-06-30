# Changelog

All notable changes to OmniDiag are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Milestone 3: Diagnostic modules
- **Network** module: adapter/IP/DNS/gateway inventory plus reachability probes
  (gateway, internet-by-IP, DNS resolution) with correlated diagnosis — including
  the "gateway reachable but DNS failing ⇒ DNS server issue" case — and firewall,
  proxy, VPN, and DNS-cache checks. Public-IP lookup is opt-in (`CheckPublicIP`).
- **Storage** module: physical-disk SMART/health, SSD wear and temperature, volume
  health and free-space thresholds, and best-effort disk-queue performance.
- **Windows Health** module: pending-reboot detection, Device Manager problem
  devices, stopped automatic services, Windows Update service state, startup count;
  optional opt-in SFC/DISM deep checks.
- **Security** module: Defender state/signature age, registered AV, firewall,
  BitLocker (admin), Secure Boot, TPM/Credential Guard, UAC, RDP exposure, and
  local administrators (admin).
- **Performance** module: sampled CPU/memory/disk pressure, best-effort GPU, and
  top CPU/memory processes.
- Probes use `System.Net.NetworkInformation.Ping` / `System.Net.Dns` for
  cross-version consistency; every module fails soft per-check and self-bootstraps.
- Integration tests covering discovery, manifests, and clean execution of all five
  modules through the engine.

### Added — Milestone 2: Event Log engine
- Event Log knowledge base (`src/EventLog/EventLogCatalog.psm1`): 14 collection
  channel definitions and a curated Event-ID translation catalog (~45 entries
  across boot/power, crash, disk, service, network, authentication, update,
  Defender, profile, and Group Policy categories) with severity overrides.
- Event Log analyzer (`src/EventLog/EventLogAnalyzer.psm1`): bounded per-channel
  collection (`Get-OmniEventRecord`), repeat collapsing with first/last-seen and
  counts (`Group-OmniEventRecord`), lifecycle timeline (`Get-OmniEventTimeline`),
  and finding generation with cross-event pattern detection (brute-force logons,
  service flapping, repeated unexpected shutdowns) via `New-OmniEventFinding`.
- **Event Logs** diagnostic module (`src/Modules/EventLogs.psm1`): collects across
  all channels within the session time range, honors cancellation between channels,
  skips admin-only channels gracefully, and emits an executive summary, interpreted
  findings, and structured timeline/group data for reporting.
- Pester tests for the catalog, analyzer (synthetic records), and the module.

## [0.1.0] - 2026-06-29 — Milestone 1: Core engine

### Added
- Core data models: severity vocabulary, `New-OmniFinding`, `New-OmniResult`,
  `Add-OmniFinding`, `Set-OmniResultMetric`, `Complete-OmniResult`, `Get-OmniTimeRange`.
- Structured, leveled logging (`New-OmniLogger`) writing to an in-memory buffer and
  a JSON-lines file, with no silent failures.
- Plugin architecture: runtime module discovery and contract validation
  (`Get-OmniModule`), execution context (`New-OmniContext`), elevation detection
  (`Test-OmniIsAdministrator`).
- Orchestration engine (`Invoke-OmniSession`) with cooperative cancellation,
  progress callbacks, per-module error capture, and admin-only graceful skipping.
- Health scoring and dashboard roll-ups (`Get-OmniHealthScore`).
- **System Information** reference diagnostic module (hardware, firmware, OS, TPM,
  Secure Boot, memory/uptime findings).
- Console runner with live progress and a dashboard view.
- Public entry point `Invoke-OmniDiag` and the `OmniDiag.ps1` launcher.
- Pester test suite for models, engine, and the System Information module.
- GitHub Actions CI: PSScriptAnalyzer lint + Pester tests on `windows-latest`.
- Project documentation and governance files.

[Unreleased]: https://github.com/OWNER/OmniDiag/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/OWNER/OmniDiag/releases/tag/v0.1.0
