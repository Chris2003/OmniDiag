# Changelog

## 0.2.0

- Added role profiles for Help Desk, Desktop Support, Systems, Network, Security, and Cloud administrators.
- Added ten task-oriented workflows for common daily IT support scenarios.
- Added read-only Active Directory, Entra ID, and Intune/MDM posture scanners.
- Added `-ListPlans`, `-Profile`, and `-Workflow` launcher options and public plan-discovery functions.
- Added a technician guide, phased improvement plan, plan contract tests, and Windows/Linux CI.
- Corrected GitHub project and CI badge URLs.

All notable changes to OmniDiag are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — CCleaner-style registry scan + backup-first cleaner
- **Registry detection** (`src/Core/RegistryScan.psm1`, `Get-OmniInvalidRegistryEntry`): a
  read-only scan for invalid/obsolete entries across seven checks — broken Run/RunOnce startup
  commands, dead App Paths, orphaned file associations (extension → missing ProgID), obsolete
  uninstall leftovers (missing InstallLocation), and missing shared-DLL / sound-event / font
  references. Returns a flat list of removable entries and changes nothing.
- **Registry Health scanner** now reports these as per-category Warning findings (metric
  `InvalidEntryCount`) alongside its existing Winlogon Shell/Userinit integrity checks.
- **Repair: "Clean Invalid Registry Entries"** (`src/Repairs/CleanRegistry.psm1`) — the 11th
  built-in repair. It re-scans, exports a **.reg backup** of every affected key first
  (`Export-OmniRegistryBackup`), then removes the entries (`Remove-OmniRegistryEntry`).
  Classified **Destructive**, requires admin, creates a System Restore point, and is fully
  dry-run aware (a dry-run reports the count + backup path and touches nothing). Restore by
  importing the .reg backup. Auto-recommended after a scan when invalid entries were found
  (`Test-OmniRepairApplicable`).
- Tests: `Core.RegistryScan.Tests.ps1` exercises detection read-only and does a real
  backup-then-remove round-trip against a throwaway HKCU value (no admin); repair-count
  assertions bumped to 11.

### Added — Portable / standalone distribution (Version 2, final increment)
- **Portable package build** (`build/Build-Portable.ps1`): assembles a self-contained,
  versioned package (staging folder + `dist/OmniDiag-<version>-portable.zip` with a
  `.sha256` sidecar) from a whitelist of the runnable surface (launchers, `src`, docs),
  deliberately excluding developer-only content (`Tests`, `.github`, `.claude`, `dist`,
  `build`). OmniDiag already loads every module by a path relative to itself (no install
  to `PSModulePath`), so the package extracts and runs in place on any supported Windows
  host — local-only, no remoting, admin optional.
- **Double-click launchers** `OmniDiag.cmd` (console) and `OmniDiag-GUI.cmd` (GUI): prefer
  PowerShell 7 (`pwsh`) when present, fall back to Windows PowerShell 5.1, and run with
  `-ExecutionPolicy Bypass` **for that process only** (no machine-wide change). This is
  what lets an extracted-from-zip copy run on a locked-down host where script execution is
  otherwise blocked (Mark-of-the-Web / RemoteSigned). The console launcher passes arguments
  through and pauses only when double-clicked (no args) so automation never hangs.
- **`PORTABLE.md`**: quick-start and fleet-deployment guidance (run locally, collect reports
  via Intune / ConfigMgr / GPO / RMM — no remoting), plus a `VERSION.txt` stamp in each
  package. New OS-independent Pester suite (`Tests/Build.Portable.Tests.ps1`) verifies the
  package contents, the dev-content exclusions, and the SHA256 integrity hash.

### Added — 35 granular diagnostic scanners
- Refactored the diagnostic surface from 7 consolidated modules into **35 focused,
  drop-in scanners** under `src/Modules`, across 10 categories:
  - **System (11):** System, Startup, Scheduled Tasks, Services, Drivers, Windows Features,
    Environment Variables, Registry Health, Installed Software, Windows Update, System Health
  - **Performance (5):** CPU, Memory, Processes, Benchmark, Startup Performance
  - **Hardware (3):** GPU, Battery, USB Devices
  - **Storage (3):** Disk, Disk Usage, Temp Files
  - **Network (6):** Network, IP Configuration, DNS Resolver, Hosts File, Network Shares, WiFi Networks
  - **Security (2):** Security, Firewall Rules
  - **Peripherals (1):** Printers &nbsp;•&nbsp; **Reliability (1):** Reliability
  - **Event Logs (2):** Event Logs, Error Summary &nbsp;•&nbsp; **Applications (1):** Browser Diagnostics
- The previous consolidated modules (System Information, Performance, Storage, Network,
  Security, Windows Health) were split into these granular scanners; each follows the same
  plugin contract (`Get-OmniModuleManifest` + `Invoke-OmniModuleScan`), fails soft per check,
  and is filterable via `-IncludeCategory` / `-ExcludeCategory`.
- Replaced the per-module test suites with `Tests/Modules.All.Tests.ps1`, which discovers
  every scanner, validates the contract, and runs the whole set through the engine asserting
  none throw and each returns a well-formed result.
- Performance: a full 35-scanner run completes in ~1 minute; the Benchmark and Disk Usage
  scanners were tuned (bounded CPU/disk micro-benchmark; dropped the whole-drive folder walk)
  and USB Devices now uses `-PresentOnly` so disconnected/phantom devices aren't false-flagged.

### Added — DxDiag-style System Information on the Dashboard
- The GUI **Dashboard** now shows a **System Information** panel (DxDiag-style), grouped into
  System (OS/build/architecture/language, manufacturer/model, system type, domain, installed
  RAM, BIOS, page file, install date, uptime, DirectX version), Processor (name, cores/threads,
  max clock), one Display section per GPU (name, chip/vendor, approx dedicated memory, current
  mode + refresh rate, driver version/date), and Sound (audio devices). Gathered via CIM
  (`Get-OmniSystemInfo`), rendered theme-aware (`Update-OmniSysInfoPanel`), and fails soft so
  missing values are simply omitted.

### Added — GUI Diagnostics tab: per-scanner on/off + run individually
- New **Diagnostics** entry in the GUI left navigation (Dashboard / All Findings / Diagnostics
  / Repair Center). It lists all 35 scanners in a grid (sorted by category and run order) with:
  an **On/Off toggle** per scanner (only enabled scanners run when you click **Run Scan**), a
  per-row **Run** button that runs just that one scanner (results land on the Dashboard),
  **Enable All / Disable All** helpers, and a **Last Status** column updated after each scan.
  Toggle state persists for the session; the grid is disabled while a scan is in progress.
- The previous top-bar "Scanners..." modal picker was replaced by this tab.
- Engine support: `Invoke-OmniSession` and `Invoke-OmniDiag` gained an `-IncludeModule`
  parameter (filter by scanner name, applied after the category filters). The launcher
  `OmniDiag.ps1` exposes `-IncludeModule` too, so the same subset selection works from the CLI
  (e.g. `.\OmniDiag.ps1 -IncludeModule CPU,Memory,Disk`).

### Changed
- **PDF reports are now generated natively - no browser, no external dependency.** The old
  exporter shelled out to a headless Chromium browser (Edge/Chrome) to render the HTML,
  which hung indefinitely on managed/enterprise machines where Edge is forced into an
  interactive MSA sign-in / SmartScreen flow, and produced no PDF. `Export-OmniPdfReport`
  now emits a valid PDF directly from the session using only the standard PDF base-14 fonts
  (Helvetica-Bold + Courier), so it works offline on any locked-down host - fitting the
  local-only / portable design. Output is a clean, paginated, print-friendly report (device
  info, health score, top recommendations, per-module results, findings) rather than a pixel
  copy of the styled HTML. Generation is now ~0.5 s instead of a multi-second (or hung)
  browser launch. `Find-OmniChromium` was removed (no longer needed); `Export-OmniPdfReport`
  keeps its signature (the now-unused `-TimeoutSeconds` is accepted and ignored). ZIP packages
  always include the PDF; `Export-OmniReport` no longer soft-fails PDF for a missing browser.
- **GUI export is now a format picker.** Clicking **Export** opens a modal dialog with a
  checkbox per report format (HTML / JSON / CSV / PDF / ZIP) and the privacy notice, and
  exports exactly the checked formats - replacing the previous one-click "export everything"
  behavior. Defaults mirror the CLI's default set (HTML, JSON, CSV pre-checked; PDF and ZIP
  opt-in). The dialog (`Show-OmniExportDialog`) is built at runtime, matches the active
  light/dark theme, requires at least one format, and returns nothing on Cancel.

### Fixed
- Repair **dry-run** incorrectly **skipped admin-only repairs** when not elevated. The
  admin gate in `Invoke-OmniRepair` fired before the dry-run path, so on a non-elevated
  host the six admin-required repairs reported `Skipped` instead of `DryRun` — a dry-run
  changes nothing and needs no elevation, so it must still *describe* those repairs. The
  gate now applies only to real execution (`-not $Context.DryRun`), fixing two failing
  repair suites; real-execution admin gating is unchanged.

### Added — Milestone 6: PDF reports + richer branding
- **PDF report** format (`src/Reporting/Pdf.psm1`, `Export-OmniPdfReport`): adds `Pdf` to
  `Export-OmniReport`, the launcher's `-ReportFormat`, the GUI export, and ZIP packages.
  (Originally rendered via a headless Chromium browser; **superseded** by the native,
  browser-free writer described under *Changed* above.)
- **Richer branding**: `Export-OmniHtmlReport` / `Export-OmniReport` now accept `-BrandLogo`
  (a logo image embedded as base64 in the report header) and `-BrandColor` (a validated
  `#RRGGBB` accent that overrides the report highlight), alongside the existing `-BrandName`.
  Branding flows into HTML, PDF, and ZIP.
- **Print-friendly output**: the HTML report gained an `@media print` stylesheet, so the PDF
  (and any printed HTML) renders on a white, ink-friendly background while the on-screen
  report stays dark.
- **Report warnings channel**: `Export-OmniReport` returns a `Warnings` list on the
  `OmniDiag.ReportSet` (surfaced in the CLI/GUI) for any per-format issue. (Originally the
  PDF soft-fail path for a missing browser; the native writer no longer has that dependency,
  but the warnings channel remains for defensive reporting.)

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

[Unreleased]: https://github.com/Chris2003/OmniDiag/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Chris2003/OmniDiag/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Chris2003/OmniDiag/releases/tag/v0.1.0
