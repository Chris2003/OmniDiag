# Changelog

All notable changes to OmniDiag are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Milestone 6: PDF reports + richer branding
- **PDF report** format (`src/Reporting/Pdf.psm1`, `Export-OmniPdfReport`): renders the
  existing HTML report to PDF via a headless Chromium browser (Microsoft Edge, which ships
  on Windows 10/11, or Google Chrome) using `--print-to-pdf`. No binaries are bundled.
  `Find-OmniChromium` locates the browser; the run is bounded (never hangs) and tries both
  modern and legacy headless modes. Added `Pdf` to `Export-OmniReport`, the launcher's
  `-ReportFormat`, and the GUI one-click export; ZIP packages include the PDF best-effort.
- **Richer branding**: `Export-OmniHtmlReport` / `Export-OmniReport` now accept `-BrandLogo`
  (a logo image embedded as base64 in the report header) and `-BrandColor` (a validated
  `#RRGGBB` accent that overrides the report highlight), alongside the existing `-BrandName`.
  Branding flows into HTML, PDF, and ZIP.
- **Print-friendly output**: the HTML report gained an `@media print` stylesheet, so the PDF
  (and any printed HTML) renders on a white, ink-friendly background while the on-screen
  report stays dark.
- **Graceful PDF degradation**: PDF is the only format with an external dependency, so
  `Export-OmniReport` soft-fails it - if no browser is found (or headless rendering is
  blocked, e.g. in an elevated session), the other formats still succeed and the reason is
  recorded in a new `Warnings` list on the returned `OmniDiag.ReportSet` and surfaced in the
  CLI/GUI.

### Added — Milestone 6: Repair Center GUI tab
- A **Repair Center** tab in the WPF GUI (third left-nav entry): a checkbox grid of the
  repair catalog with risk-colored rows, recommended repairs pre-checked after a scan,
  "Select Recommended" / "Clear" helpers, and a **Dry run** toggle. A single summary
  dialog confirms the selected repairs (with restore-point and reboot notes) before they
  run; results populate a grid with a reboot/restore-point banner.
- Repairs run in a **background STA runspace** (mirroring the scan), so the window stays
  responsive and the Cancel button drives the engine's `CancellationToken` even during
  long repairs (SFC/DISM). The runspace re-discovers repairs by name (registration objects
  are runspace-affine) and reuses the tested `Invoke-OmniRepair` engine unchanged.
- `Show-OmniDiagWindow` gains a `-RepairsPath` parameter (defaults to `src/Repairs`).

### Added — Milestone 6: Repair Center (Version 2, first increment)
- **Repair plugin architecture** mirroring the diagnostic side: repairs are drop-in
  `.psm1` plugins in `src/Repairs/`, each exporting `Get-OmniRepairManifest` and
  `Invoke-OmniRepairAction` (and an optional `Test-OmniRepairApplicable`), discovered
  and run in isolated session state by `Get-OmniRepair`. The core stays closed.
- **Repair core** (`src/Repair/`): result models + the `Invoke-OmniRepairStep` runner
  (dry-run aware, captures output/exit code, logs every step), `New-OmniRepairContext`,
  `Get-OmniApplicableRepair` (flags repairs relevant to a scan's findings), the
  `New-OmniRestorePoint` helper (fails soft when System Restore is unavailable), and
  the `Invoke-OmniRepair` engine (per-repair error capture, admin-gated skipping,
  cancellation, and ONE System Restore checkpoint up front for a batch that needs it).
- **Ten built-in repairs:** Flush DNS, Release/Renew IP, Reset Winsock, Restart Print
  Spooler, Restart Explorer, Clear Temporary Files, Restart Stopped Automatic Services,
  Reset Windows Update, Run SFC, and DISM /RestoreHealth — classified Safe / Moderate /
  Destructive, with admin and reboot requirements declared per repair.
- **Interactive console** (`Invoke-OmniRepairConsole`): catalog grouped by category with
  recommended repairs starred, numbered selection, and **per-action confirmation**
  showing each repair's risk, restore-point, and reboot implications.
- **Safety:** every repair supports a **dry-run** that describes without executing; the
  engine is `SupportsShouldProcess`; a restore point is created before system-altering
  repairs; admin-only repairs are skipped gracefully when not elevated.
- Launcher gains `-Repair` and `-RepairDryRun`; `Invoke-OmniRepairCenter` exposes the
  annotated catalog for automation. New OS-independent Pester suites (24 tests) cover
  the models, registry, engine, and every catalog plugin — all via dry-run/harmless
  fakes so the suite never changes the host.

### Changed
- Health score is now far more meaningful. The old model subtracted a flat penalty
  per finding (Critical 30 / Error 12 / Warning 4) with no ceiling, so ~9 Errors —
  routine for weeks of historical Event Log entries — zeroed the score on an
  otherwise-serviceable machine. The score now uses a **saturating penalty per
  severity** (`penalty = Cap * (1 - Decay^count)`): the first finding of a severity
  costs the most and each additional one adds less, so a flood of lower-severity
  findings can no longer bottom out the score while genuine Critical findings still
  dominate. Grade bands retuned to Healthy ≥ 80, Warning ≥ 50, Critical < 50. A
  clean machine still scores 100; a single Critical no longer reads as Healthy.
- GUI now defaults to the **Light** theme. The top-bar theme button is a labelled
  toggle (`Dark Mode` / `Light Mode`) that names the theme it will switch to, and
  the dashboard/findings status colors were retuned to stay legible on both themes.

### Fixed
- HTML report generation failing with **"The term 'Write-OmniTextFile' is not
  recognized."** `Write-OmniTextFile` (the shared UTF-8/no-BOM writer in
  `Reporting/Json.psm1`) is called cross-module by the HTML exporter, but it was
  missing from the manifest's `FunctionsToExport`, so it never reached the global
  scope where a function running in `Html.psm1`'s module scope could resolve it.
  Added it to `FunctionsToExport`.
- Diagnostic modules crashing with **"The property 'Count' cannot be found on
  this object."** under `Set-StrictMode -Version Latest`. Every module ended with
  `(($result.Findings | Where-Object {...}).Count -eq 0)`; when the filter matched
  nothing the pipeline yields `$null`, and `$null.Count` throws under strict mode —
  so any module with no warning-or-higher findings (commonly Network, Storage, and
  Windows Health on a healthy host) failed instead of reporting *Healthy*. Wrapped
  the filter in `@(...)` across all six modules. Also wrapped
  `Test-OmniPendingReboot`'s result (`@(Test-OmniPendingReboot)`) in Windows Health,
  which returned an empty `[string[]]` that unrolled to `$null` and hit the same
  strict-mode `.Count` failure when no reboot was pending.
- Module exports: the root module (`src/OmniDiag.psm1`) called
  `Export-ModuleMember -Function 'Get-OmniVersion', 'Invoke-OmniDiag'`, which
  overrides the manifest's `FunctionsToExport` and limited the public surface to
  just those two functions. As a result the nested-module functions
  (`Test-OmniIsAdministrator`, `Invoke-OmniSession`, the reporting and GUI
  functions, the console dashboard, etc.) were silently dropped, and running
  `OmniDiag.ps1` failed with **"The term 'Test-OmniIsAdministrator' is not
  recognized."** Removed the root-module `Export-ModuleMember` call so the
  manifest governs exports; all 30 public functions are now exported as intended.

### Added — Milestone 5: WPF GUI
- `src/UI/MainWindow.xaml`: Fluent-style window — top bar (range picker, Run Scan,
  Cancel, Export, Theme), left navigation (Dashboard / All Findings), dashboard with
  0–100 score, summary, top recommendations and module-results grid, a findings
  DataGrid with per-severity row coloring, and a status bar with a progress bar.
- `src/UI/OmniDiagGui.psm1` (`Show-OmniDiagWindow`): runtime XAML loading, dark/light
  theming via `Set-OmniTheme` / `Get-OmniThemePalette` (DynamicResource brushes),
  and a responsive scan that runs in a **background runspace** with progress polled
  by a `DispatcherTimer`; the Cancel button drives the engine's `CancellationToken`.
  One-click export reuses the Milestone 4 reporters behind a privacy confirmation.
- STA handling: runs directly under Windows PowerShell 5.1 (STA) and hosts the window
  in a dedicated STA runspace under PowerShell 7 (MTA). Importing the module is safe
  on headless/Server Core hosts (WPF assemblies load only when the window opens).
- Launcher `-Gui` now launches the interface; added a `-Gui` example.
- OS-independent GUI tests (XAML structure, theme palettes); the real WPF load
  self-skips off Windows/STA.

### Added — Milestone 4: Reporting engine
- `src/Reporting/` exporters consuming an `OmniDiag.Session`:
  - **JSON** (`Export-OmniJsonReport`) — full structured session, UTF-8 no BOM.
  - **CSV** (`Export-OmniCsvReport`, `Export-OmniEventCsvReport`) — flattened
    findings table and grouped event table.
  - **HTML** (`Export-OmniHtmlReport`) — self-contained report (inline CSS, no
    external resources): executive summary with 0–100 score, device information,
    top recommendations, failures/errors, warnings, event-log analysis (timeline +
    top groups), per-module breakdown, passed checks, and a privacy notice. All
    user-derived text is HTML-encoded to prevent injection.
  - **ZIP** (`Export-OmniReportPackage`) — bundles HTML + JSON + CSVs + raw log +
    README.
- `Export-OmniReport` coordinator: writes any combination of formats with a
  consistent, sanitized base name; optional `BrandName` branding.
- Launcher gains `-Report`, `-ReportFormat`, `-ReportPath`, `-BrandName`, and
  `-AcceptPrivacyNotice`, with an interactive privacy warning before export.
- OS-independent reporting tests (synthetic session), including an HTML-injection
  safety check.

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
