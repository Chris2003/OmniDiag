# Changelog

All notable changes to OmniDiag. Versions before 1.0.0 were development milestones and
were not published as releases.

## [1.0.0] - Unreleased

<!-- Release notes for v1.0.0 go here (filled in at release time; see docs/RELEASING.md). -->

## [0.9.0]

Phase 4 of the v1.0 roadmap: hardening. Every item of the security review has a finding,
a fix or a documented reason, and a dedicated test; see
[docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md).

### Security review: files and I/O
- **Export path canonicalization:** every output path (`--output`, `--redaction-map`,
  `-OutputDirectory`, `-Path`) goes through the new `Resolve-OmniOutputPath`: `..` is
  collapsed, and device paths (`\\.\`, `\\?\`, UNC `pipe` / `mailslot` shares), reserved
  device names (`NUL`, `CON`, `COM1.json`, ...), NTFS streams, and non-file-system providers
  are refused (CLI: usage error, exit 10). Host-derived, redacted, and `-BaseName` file
  names are reduced to one safe file-name component (`ConvertTo-OmniSafeFileName`).
  `Export-Csv` and `Compress-Archive` use `-LiteralPath`.
- **Zip-slip and zip-bomb guards:** report-package (`.zip`) import validates every entry
  name before reading (absolute names, drive letters, `:`, `..`, control characters, device
  names), refuses more than 256 entries and a `data.json` over 64 MB declared or actually
  inflated, and never extracts. `install.ps1` applies the same entry-name rules and streams
  each entry with a 64 MB / 512 MB cap before `Expand-Archive`.
- **Launcher executable pinning:** `OmniDiag.cmd` and `OmniDiag-GUI.cmd` no longer run
  `where pwsh` or a bare `pwsh` / `powershell.exe` (which cmd.exe resolves from the current
  folder first). They use `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` and
  switch to `pwsh.exe` only from the standard `PowerShell\7` install folders. The Restart
  Explorer repair starts `%SystemRoot%\explorer.exe`.
- **Secret scrubbing:** `Protect-OmniSecretText` / `Protect-OmniSecretData` mask BitLocker
  recovery passwords, URL credentials, `password=` / `token=` / `secret=` / `sig=` pairs,
  `-Password` / `--token` switches, Bearer and Basic values, netsh key content, JWTs, and
  GitHub / Slack / AWS token formats in findings, metrics, and every log record. Sessions
  are scrubbed once on completion, again on import and before export, so older or edited
  sessions cannot leak secrets. The proxy scanner scrubs proxy URLs at the source.
- A static check keeps temporary files on `Get-OmniDataPath` (no new `%TEMP%` use).

### Security review: content and import
- **Report encoding:** Markdown collapses line breaks and control characters and escapes
  pipes everywhere, and ids in code spans can no longer end the span and inject HTML. CSV
  formula neutralization also covers leading whitespace or quotes, a leading LF, full-width
  `= + - @`, and non-string values. HTML renders non-date times and non-numeric durations
  from imported sessions as encoded text instead of failing. PDF and JSON were verified.
- **Redaction:** identifiers glued to URL escapes (`%XX`) or JSON escapes kept as text
  (`\n`, `\t`, `\uXXXX`) are now redacted by every detector (found by a property-based
  test). Generated finding ids (kebab case of component and title) are rebuilt from the
  redacted text, so names and addresses no longer leak through them.
- **Session import validation and fuzzing:** `Import-OmniSession` caps files at 64 MB and
  nesting at 100 levels (checked before parsing), requires one JSON object, validates the
  shape of v1 reports and native sessions, and reports every failure as one
  `System.IO.InvalidDataException` (`OmniDiag.SessionImportInvalid`). A seeded 200-case
  fuzzer runs in CI.
- **Local AI (Ollama):** everything sent about a session (findings, ids, the question, the
  plan, runbook text, earlier turns) goes through the report redaction context, and cited
  ids are mapped back. Model output, model names, and server errors are stripped of
  terminal control sequences and bidi overrides before display.

### Quality gates and verification
- **Coverage gate:** `build/Invoke-Tests.ps1 -CoverageTargets ... -EnforceCoverage`; CI
  fails when `src/Core`, `src/Repair`, or overall line coverage drops below 80%. New branch
  tests for the repair engine and registry.
- **Standard-user CI leg:** `build/Invoke-AsStandardUser.ps1` runs the suite, `report`, and
  `scan` as a throwaway Users-only local account; `build/Test-PrivilegeReport.ps1` checks
  exit codes, the report schema, structured elevation skips, and compares with an elevated
  report. Blocking job `standard-user`.
- **Client verification:** `build/Invoke-ClientVerification.ps1` writes an identifier-free
  result file for Windows 10 / 11 client runs; `docs/VERIFICATION.md` lists what is
  verified and what is not.

### GUI
- **Frame-first startup:** the window is first built in code (title, theme, a "Loading
  OmniDiag..." live region) and painted before any XAML is parsed; the shell
  (`MainWindow.xaml`) loads right after at Background priority.
- **Lazy sections:** Groups, All Findings, Diagnostics, Repair Center, and Local AI are XAML
  fragments under `src/UI/Sections/`, parsed on first navigation and cached.
- **Measured startup:** first paint (`StartupMs`) and fully interactive (`ShellReadyMs`) are
  logged with a phase breakdown and exposed through UI Automation;
  `build/Measure-GuiStartup.ps1` compares strategies in fresh processes (non-blocking CI job
  `gui-startup`). See docs/GUI.md.
- Background work uses the curated cmdlets (`Invoke-OmniDiagScan`, `Export-OmniDiagReport`,
  `Get-OmniDiagRepair`) and the new non-deprecated engine entry `Invoke-OmniRepairRun`
  (`Invoke-OmniRepair` is now a deprecated wrapper over it). The GUI implementation is
  `Start-OmniGuiWindow`, behind `Show-OmniDiagGui`.

## 0.8.0 (unreleased)

Phase 3 of the v1.0 roadmap: interfaces and UX.

### Sharing reports safely
- **Report redaction:** `--redact` (CLI), `-Redact` (`Export-OmniDiagReport`,
  `Invoke-OmniDiagReport`), and a GUI export option replace host, user, and domain names,
  the FQDN, profile folders, account SIDs, and IPv4/IPv6/MAC addresses with stable pseudonyms
  (`HOST-1`, `USER-1`, `IP-1`, ...) in HTML, JSON, CSV, Markdown, PDF, the ZIP (incl. its
  README and run log), and file names. The session itself is never changed. `-Salt` keeps
  pseudonyms aligned across bundles; `--redaction-map` / `-RedactionMapPath` writes a
  local-only mapping file. See docs/REDACTION.md.
- Report schema 1.1.0 (additive): optional `options.redacted`.

### Command line
- `omnidiag repair list [--from-session]` and `repair run <id>... (--what-if | --apply [--yes])`:
  nothing changes without `--apply`; y/N per repair, `--yes` required when stdin isn't
  interactive; exit codes 4/11/12.
- `omnidiag compare <before> <after>` (paths, report zips, `last`, `previous`; text, JSON, or
  Markdown), `omnidiag gui`, `--elevated-only`, `report --bundle`, `report --from-session`.
- **Repair audit log:** every applied repair step is appended to
  `OmniDiagData\logs\repair-audit.jsonl` from the CLI, console, GUI, and cmdlets. Dry runs are
  never audited.

### PowerShell
- Curated cmdlets with full help: `Invoke-OmniDiagScan`, `Get-OmniDiag<Group>`,
  `Invoke-OmniDiagReport`, `Export-OmniDiagReport`, `Import-OmniDiagSession`,
  `Compare-OmniDiagSession`, `Get-OmniDiagRepair`, `Invoke-OmniDiagRepair` (`-WhatIf` = dry
  run, ConfirmImpact High), `Show-OmniDiagGui`, plus `Get-OmniDiagModule`/`Get-OmniDiagGroup`.
  New docs/POWERSHELL.md (cmdlets, object types, plugin SDK, deprecations).
- Deprecated (still working, one-time warning, `OMNIDIAG_NO_DEPRECATION_WARNING=1` hides it):
  `Invoke-OmniDiag`, `Export-OmniReport`, `Import-OmniSession`, `Compare-OmniSession`,
  `Invoke-OmniRepairCenter`, `Invoke-OmniRepair`, `Show-OmniDiagWindow`.

### Review fixes
- Redaction: the machine DNS domain and Domain/DnsDomain/DomainName metrics are redacted even
  without `USERDNSDOMAIN` (SYSTEM, local accounts, imported sessions); sessions record
  `Host.Domain` / `Host.DnsDomain`.
- Redaction: profile folders behind device paths, UNC shares, and WSL mounts; MAC/IPv6
  addresses glued to labels or followed by ':'; run-log names written as `\u0027`/`\u0026` by
  Windows PowerShell 5.1.
- `Invoke-OmniRepair -WhatIf` creates no restore point; `-Confirm` asks before the restore point
  is created. CLI `--redact` also redacts the stderr status lines.
- Windows PowerShell 5.1: `Invoke-OmniDiagScan` and the group cmdlets work (no `GetNewClosure`
  over validated parameters); GUI live regions work (legacy accessibility switches off).

### GUI
- Screen-reader names on every control and grid row; status and progress announced as live
  regions; access keys and a logical Tab order with visible focus in every theme.
- Keyboard shortcuts: F5 scan, Esc cancel, Ctrl+E export, Ctrl+F filter, Alt+T theme, F1 help,
  Ctrl+1..6 sections, Enter for details / open group (docs/GUI.md).
- Follows Windows High Contrast live using system colours; severity is always shown as text.
- Groups view with per-group status, score, worst severity, and counts, with drill-down; All
  Findings gets a text/severity filter and a detail panel.
- Export dialog adds Bundle (.zip) and "Redact identifiers for sharing"; export runs in the
  background. First render is measured; inventory and catalogs load after first paint.


## 0.7.0 (unreleased)

Phase 2, wave B of the v1.0 roadmap: every v1.0 module group is complete. Nine new scanners;
all new and changed findings have stable Ids without live values.

### Services & startup
- Services: counts by start type; per-service crash (7031/7034) and start-failure
  (7000/7009/7011) history from the System log over the scan range.
- Drivers: unsigned and third-party drivers, running system drivers outside the driver folders,
  and one finding per problem device with the Device Manager error meaning and a fix.
- New `startup.service-persistence`: auto-start services in user-writable or non-standard
  folders, and unquoted service paths.
- New `startup.startup-folders`: per-user and all-users Startup entries with shortcut targets;
  flags risky locations and script hosts.
- Scheduled Tasks: non-Microsoft logon/boot tasks with their actions; flags user-writable and
  script-host actions.

### Performance, events & reliability
- Handle and thread totals and the top processes by handle count (Warning above 10,000).
- Event hints for disk 153, Ntfs 137, and the BugCheck / WER 1001 sources; Ntfs 98 keeps its
  logged level; event and reliability findings have stable Ids.
- New `reliability.reliability-monitor`: System Stability Index (latest, trend) and failure
  records by product, bounded to the time range.
- New `reliability.crash-dumps`: minidump and MEMORY.DMP inventory plus crash-dump settings.
- Reliability, VPN, and Intune event queries are bounded.

### Storage & updates
- New `storage.trim`: TRIM state for NTFS and ReFS from the registry, correlated with SSDs.
- New `updates.update-history`: local Windows Update history (last successful install, failed
  installs with HRESULT), read-only and offline (never searches Windows Update).
- Pending reboot is reported once (Windows Health).
- Fixed: Windows Health no longer runs `sfc /verifyonly`; scanners are read-only.

### Network & security
- New `network.routes`: default routes, equal-metric ambiguity, persistent routes.
- New `network.listening-ports`: listeners with owning process and services; FTP, Telnet,
  RDP, and WinRM bound to all interfaces are Warnings, SMB is Information.
- New `security.local-admins`: Administrators by SID and the built-in Administrator check; on
  domain/Entra-joined devices members are listed only with `--network-probes` (name
  resolution can contact a domain controller).
- WinHTTP proxy read from the registry; `netsh` fallback and Wi-Fi parsing no longer depend on
  the display language. UAC also checks `ConsentPromptBehaviorAdmin` and `PromptOnSecureDesktop`.

### System & extras
- System: Windows support status (version, release, edition, end-of-servicing table; Windows
  10 22H2 end-of-support notice), architecture check, and TPM / Secure Boot states including
  "requires elevation" and legacy BIOS.
- System and System Information no longer report the same facts; the GUI panel and the
  scanner share `Get-OmniSystemInventory`.
- Entra ID reads join state from the registry; `dsregcmd /status` (needs Entra connectivity)
  runs only with `--network-probes`.
- Time Synchronization reads registry configuration and Time-Service events instead of
  localized `w32tm` output and never contacts a time server.

### Review fixes (fewer false positives)
- Scheduled tasks: SYSTEM-at-logon tasks are Information unless the action is user-writable or
  uses a script host; exact SYSTEM match; Edge, Google, and OneDrive updaters are listed only.
- A user-writable startup/task target alone is Information; service non-standard install
  location is Information.
- Update History excludes Defender definition updates from the last-install grade
  (`LastDefinitionUpdate` metric); KB-less finding Ids use the UpdateID.
- Services is the single owner of stopped auto-start services (exit code 0/1077 is Information,
  trigger-start services skipped); Drivers is the single owner of problem devices.
- Reliability event counts are filtered by provider, and an unreadable log no longer reports a
  Pass; stability index warns below 3 and errors below 1.
- Time-sync failures warn only when newer than the last success; Intune MDM warns at 10+ errors;
  WinRM is Information on Windows Server; handle threshold 20,000; uptime warns at 30 days.
- COM objects (WScript.Shell, WUA history) are released; one shell per scan.
- Tests: seam tests one level below the private helpers; module-scoped stubs for Windows
  cmdlets so mocks behave the same on Windows and Linux; Windows PowerShell 5.1 fixes.

### Workflows
- New scanners added to the relevant task workflows; QuickTriage, LoginAndIdentity,
  CloudReadiness, and SecurityPosture include the System health checks.


## 0.6.0 (unreleased)

Phase 2, wave A of the v1.0 roadmap: the shared foundation for the module groups.

### Network
- **Connectivity probes are opt-in** (owner decision 1): `--network-probes` (CLI),
  `-NetworkProbes` (`OmniDiag.ps1`), or the "Run connectivity probes" GUI checkbox. Without it,
  the Network, DNS Resolver, and Active Directory scanners do only local work and add a
  "Connectivity probe not run" Information finding. Probe targets are configurable
  (`Config.ProbeTargets`). Network-capable scanners now run in default, group, and plan scans.
- **Runtime no-network test** (`build/Test-NoNetworkRuntime.ps1`, blocking CI job): audits
  Windows Filtering Platform connections and DNS queries while PowerShell is blocked outbound,
  requires a positive control to be detected, and fails on any outbound attempt from a default
  scan or report.

### Engine
- Runspace-pool engine (`-MaxParallel`, default CPU count up to 8; `1` = sequential), per-module
  `TimeoutSec` enforcement (a timeout is a Failed result, exit code 3), cancellation of running
  modules, results in registration order, progress on the caller's thread, worker logs merged
  into the single run log.
- Structured skips: `skippedReason` RequiresElevation / NotSupported / Cancelled. New optional
  manifest fields `SupportedPlatforms` and `Parallel` (`$false` runs on the caller's thread).
- Event Logs collection bounded (2,000 events per channel, 20,000 total); Benchmark runs alone.

### Groups
- `omnidiag <group>` (e.g. `omnidiag network`), and cmdlets `Get-OmniDiagGroup`,
  `Get-OmniDiagModule`, `Invoke-OmniDiagScan`, and one per group (`Get-OmniDiagSystem` …
  `Get-OmniDiagSecurity`, `Get-OmniDiagExtras`) returning v1 finding objects.
- Group documentation pages under `docs/modules/`; contract expectations split per group
  (`Tests/data/scanner-groups/`).

### CI
- Scan performance job (`build/Measure-ScanPerformance.ps1`): median of three full scans
  against the 60-second budget, startup time, and the slowest modules (soft gate).
- The Windows ARM64 test leg now blocks merges.


## 0.5.0 (unreleased)

Phase 1 (Foundation) of the v1.0 roadmap.

### Contract & schema
- **Module contract v1.** Every scanner manifest now declares a stable `Id`
  (`<group>.<kebab-name>`, e.g. `network.dns-resolver`), a `Group` (one of `system`,
  `performance`, `services`, `startup`, `events`, `reliability`, `storage`, `network`, `updates`,
  `security`, `extras`), and `NetworkAccess` (`None` / `LocalNetwork` / `Internet`); every repair
  declares `Id` (`repair.<kebab-name>`) and `NetworkAccess`. Registrations also expose
  `RequiresElevation` (alias of `RequiresAdmin`), `TimeoutSec` (default 60), and
  `SupportedArchitectures` (default `x64`, `arm64`). Older manifests load with derived defaults;
  invalid values and duplicate Ids are logged and the plugin is skipped. The engine stamps
  `ModuleId`, `Group`, and `SkippedReason` on each result.
- **Report schema v1.** `schemas/omnidiag-report.v1.json` (JSON Schema 2020-12) and
  `ConvertTo-OmniReportV1` / `ConvertFrom-OmniReportV1`: a versioned projection of the session
  with `schemaVersion`, ISO-8601 UTC timestamps, and the v1 severity scale (Pass and Information
  → Info with `passed`, Warning → Warning, Error and Critical → Critical; `severityNative` kept).
  Output is deterministic and ASCII-only (`ConvertTo-OmniJsonText`), identical on PowerShell 5.1
  and 7, and covered by a golden-file test. See `docs/SCHEMA.md`.
- **Breaking for JSON consumers:** `Export-OmniJsonReport`, `Export-OmniReport -Format Json`, and
  the report package's `data.json` now write schema v1 instead of the raw session. Saved sessions
  in `OmniDiagData\sessions` keep the native format through the new `Save-OmniSession` (used by
  `OmniDiag.ps1` and the GUI). `Import-OmniSession` reads native sessions, v1 reports, and both
  kinds of package.
- **Markdown reports:** `ConvertTo-OmniMarkdownReport` / `Export-OmniMarkdownReport`, and `Md` in
  `Export-OmniReport` and `OmniDiag.ps1 -ReportFormat`.
- **Exit codes:** `Get-OmniExitCodeTable`, `Get-OmniExitCode`, `Get-OmniRepairExitCode`.
  `OmniDiag.ps1` now exits 0/1/2/3/4/5 from the scan, 10 for conflicting switches, 11/12 after a
  failed or reboot-pending repair, and 20 on an internal error (it still writes the session object
  first, and scratch cleanup still runs).

### CLI
- **`omnidiag` command.** `OmniDiag.cmd` doubles as `omnidiag`: a subcommand or `--option` goes to
  the new router (`src/Cli/omnidiag.ps1` → `Invoke-OmniDiagCli`), anything else to the classic
  console. Same portable environment; `%ERRORLEVEL%` is propagated; it never pauses with
  arguments.
- Commands: `list [modules|groups|repairs|plans]`, `scan [--group] [--module] [--profile |
  --workflow] [--range]`, `report [--output <dir>]`, `version`, `help`. Global options:
  `--format json|csv|md|html|pdf`, `--output`, `--verbose` (Debug entries in the local log),
  `--quiet`, `--no-color`, `--help`. Data goes to stdout only with `--format` and no `--output`;
  progress and status go to stderr. `list --format json` emits a versioned document
  (`schemas/omnidiag-list.v1.json`). Unknown commands or options print usage on stderr and exit 10.
- Scanners that need network access run from the CLI only when named with `--module`.
- `Invoke-OmniDiag -LogLevel`; module version 0.5.0. The portable package and `install.ps1` now
  ship the `schemas` folder. See `docs/CLI.md`.

### CI & hygiene
- **CI pipeline.** Lint job (PSScriptAnalyzer, 0 errors required). Tests on Windows pwsh 7,
  Windows PowerShell 5.1, Ubuntu pwsh, and Windows 11 ARM64 (ARM64 doesn't block merges yet).
  Coverage report from the Windows pwsh leg. Portable-package job uploads the zip and
  `.sha256` as an artifact. Dependency review runs on pull requests. Every action is pinned to
  a commit SHA, and Dependabot checks GitHub Actions weekly.
- **`build/Invoke-Tests.ps1`.** One test entry point for CI and local runs (Pester 5.5+,
  Windows PowerShell 5.1 and PowerShell 7). It points `OMNIDIAG_DATA` at a throwaway folder
  so tests stop writing `OmniDiagData` into the repository. `-Coverage` writes a JaCoCo report
  and prints coverage for Core, Repair, and Reporting. `-CoverageTarget` only reports unless
  `-EnforceCoverage` is given.
- **`build/Invoke-Lint.ps1` + `PSScriptAnalyzerSettings.psd1`.** Runs the default rules and
  prints counts by severity and rule. Fails on any error, or on any warning with
  `-FailOnWarning`. Retries files when PSScriptAnalyzer itself crashes intermittently.
  Write-Host is allowed only in the console presentation layers.
- **Static no-network test** (`Tests/NoNetwork.Tests.ps1`). Walks the AST of every product
  script for network-capable cmdlets and .NET types. It fails on usage outside an explicit
  allowlist and on stale allowlist entries, and a self-test proves the detector catches each
  pattern. Outside `src`, only `install.ps1` may download.
- **Fixed:** `.reg` backup header stripping on Windows PowerShell 5.1. A literal U+FEFF in a
  BOM-less file was read as three ANSI characters; the regex now uses `﻿` and the file
  is ASCII-only.
- **Fixed:** PDF reports now show `-BrandLogo` for JPEG files, embedded natively as a
  DCTDecode image. Other formats are skipped with a warning; the HTML report still shows any
  format. Removed the unused `-TimeoutSeconds` parameter from `Export-OmniPdfReport`.
- Lint fixes: no assignment to the automatic `$matches` (WiFi Networks), no unused `$log`
  (Reliability), and a singular noun for an internal PDF helper. `OmniDiagGui.psm1` is now
  ASCII-only.
- Removed the stale committed `dist/` package, and `dist/` is now git-ignored. Fixed stale
  header comments and added the missing 0.4.0/0.4.1 compare links.

## 0.4.1 — architecture review fixes

From a four-reviewer swarm review against `docs/ARCHITECTURE.md` (plugin contracts, core
layering, local-only/zero-footprint/privacy guarantees, reporting/UI/tests).

### Safety
- **Restore points are now verified.** `New-OmniRestorePoint` uses the SystemRestore WMI class
  (Checkpoint-Computer doesn't exist in PowerShell 7) and checks that a point really exists.
  Repairs marked `RestorePoint` are skipped when none protects the run, unless
  `-AllowRepairWithoutRestorePoint` is passed.
- Registry cleanup removes nothing unless its `.reg` backup completed (reg.exe failures now
  stop the cleanup), and it reports failed removals instead of claiming success.
- Clear Temporary Files never deletes OmniDiag's own folder or data.
- Repair steps don't start after cancellation; closing the GUI during a repair cancels
  cooperatively instead of killing it mid-step. Scans and repairs can't run at the same time.
- Repair recommendations ignore Pass/Information findings, and repair `AppliesTo` values now
  match what scanners emit (Print Spooler and IP renew were never recommended; Winsock, Temp,
  and Windows Update reset were recommended on healthy scans).

### Portable / zero footprint
- Benchmark and the registry backup no longer write to `%TEMP%` when `OmniDiag.ps1` is run
  directly; the portable test now also catches `GetTempFileName()` and `$env:TEMP` write paths.
- Scratch cleanup only deletes a folder carrying OmniDiag's marker, so `OMNIDIAG_DATA` pointed at
  an existing folder can't wipe a real `Temp`. Data-root paths are normalized (no prefix
  false-positives); an unwritable `OMNIDIAG_DATA` falls back with a warning.
- Scratch is cleaned on every exit path (errors included). The temp-files scanner measures the
  user's real temp folder under the portable launchers.
- `PORTABLE.md` now lists every network probe, and documents PowerShell's own startup cache.

### Fixes
- The launcher crashed after every scan when no approved runbooks loaded (including every
  copy installed by `install.ps1`, which didn't install `runbooks/`). One unreadable runbook
  no longer stops a run; a failed AI call no longer skips reports and repairs.
- Before/after comparison only compares scanners that ran in both scans (others are listed as
  out of scope) and pairs findings whose titles embed live values such as "High CPU usage (93%)".
- GUI: no crash when a scan is cancelled before any module finishes; GUI scans are saved for
  `-FromSession Last` / `-CompareWith Last`; GPU "Chip / Vendor" joins correctly.
- Reports: relative `-ReportPath` / `-BrandLogo` resolve against the current PowerShell folder;
  module badges no longer show Skipped/Unknown as Critical; failed scanners show their error.

### Security & privacy
- CSV exports neutralize spreadsheet formulas (`=`, `+`, `-`, `@`) from event text and other
  attacker-writable strings. HTML reports encode every value from (possibly edited) saved sessions.
- Local AI: requests refuse HTTP redirects and are sent as UTF-8 on Windows PowerShell 5.1;
  e-mail addresses, certificate DN parts, and local user/computer/domain names are redacted from
  prompts; analysis-mode citations are verified like chat mode; the approval advisory is always shown.
- `install.ps1` installs `runbooks/` and carries `OmniDiagData` across upgrades.

### CI
- Added a Windows PowerShell 5.1 job and retries for flaky PowerShell Gallery installs.

## 0.4.0

### Portable, zero-footprint operation
- OmniDiag now keeps everything it writes in an `OmniDiagData` folder next to the tool:
  logs, reports, saved sessions, registry backups, and scratch files. Nothing goes to
  `%TEMP%`, `%APPDATA%`, or `%LOCALAPPDATA%`, so it can run from the download folder or
  a USB stick and leave no OmniDiag files behind (`Get-OmniDataRoot`, `Get-OmniDataPath`).
- The `.cmd` launchers point `TEMP`/`TMP` and PowerShell's module-analysis cache at the
  tool folder and turn off PowerShell 7 telemetry and the update check, for that process only.
- Falls back to `%TEMP%\OmniDiag` with a warning when the tool folder is read-only;
  `OMNIDIAG_DATA` overrides the location.
- The Clear Temporary Files repair still cleans the user's real temp folder when launched
  from the portable launchers.

### Version 5 complete — runbooks, search, multi-turn AI, before/after
- Organization-owned Markdown runbooks with front matter (`runbooks/`, `-RunbookPath`,
  `OMNIDIAG_RUNBOOK_PATH`); only `status: approved` runbooks are used. Matching runbooks
  are listed after every console scan (`Get-OmniRunbook`, `Find-OmniRunbook`).
- Saved sessions: every console scan is saved to `OmniDiagData\sessions`; `-FromSession`
  and `Import-OmniSession` reload a JSON report, report .zip, or `Last`.
- Offline plain-language search over findings and approved runbooks (`-Search`,
  `Search-OmniEvidence`).
- Multi-turn local Ollama conversation (`-AiChat`, `New-OmniAssistantConversation`,
  `Invoke-OmniAssistantTurn`): retrieves evidence for each turn, keeps bounded history, and
  validates every cited finding/runbook ID. Citations the model invents are flagged and ignored.
- Before/after comparison (`-CompareWith`, `Compare-OmniSession`): resolved, new, and
  worsened/improved findings, score delta, module status changes, and an overall verdict.

### Fixed
- The console launcher failed to start any scan without `-Profile` or `-Workflow`
  (an empty value was passed to a validated parameter).

### Other
- Added `CREDITS.md` and an authorship and AI-disclosure section to the README.

## 0.3.2

- Added a dedicated Local AI page to the WPF GUI with editable model, loopback endpoint, and technician question controls.
- Added background Ollama readiness checks and evidence-grounded analysis of the latest scan without blocking the interface.
- Rendered priorities, correlations, next steps, limitations, approval flags, and cited finding IDs in a read-only result view.
- Added Local AI GUI contract tests and updated the Ollama/GUI documentation.

## 0.3.1

- Added a one-command current-user installer that opens the GUI immediately.
- Added archive layout validation, optional SHA-256 pinning, allowlist-only deployment, recursive downloaded-file unblocking, and recoverable update backups.
- Added installer parser/safety tests and included the installer in portable builds.
- Documented quick, inspect-then-run, manual portable, and managed deployment paths.
- Corrected the GitHub Security Advisory URL.

## 0.3.0

- Completed local Version 3 enterprise posture with certificate, proxy, VPN, time synchronization, BitLocker escrow-policy, Defender onboarding, and update-ring scanners.
- Expanded Cloud Admin, Security Admin, Systems Admin, Network Admin, and task workflows to use the new evidence.
- Added optional loopback-only Ollama analysis with structured finding-ID citations and no repair execution path.
- Defaulted local AI to `gemma4:e2b` with a documented `gemma3:1b` low-memory alternative.
- Added Ollama contract tests, setup documentation, and privacy boundaries.

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

[Unreleased]: https://github.com/Chris2003/OmniDiag/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/Chris2003/OmniDiag/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Chris2003/OmniDiag/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/Chris2003/OmniDiag/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/Chris2003/OmniDiag/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Chris2003/OmniDiag/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Chris2003/OmniDiag/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Chris2003/OmniDiag/releases/tag/v0.1.0
