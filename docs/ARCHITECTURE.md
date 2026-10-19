# OmniDiag Architecture

OmniDiag is a layered, plugin-based PowerShell application. The core is closed to
modification: new diagnostic capabilities are added as plugin modules, never by
editing the engine.

## Layers

| Layer | Folder | Responsibility |
|---|---|---|
| **Launcher** | `OmniDiag.ps1` | Host validation, module import, runs a session, renders the console dashboard. |
| **Public API** | `src/OmniDiag.psm1` | `Invoke-OmniDiag`, `Invoke-OmniRepairCenter`, and version helpers. The calls the CLI/GUI use. |
| **Core** | `src/Core/` | Data models, logging, plugin registry, orchestration engine, health scoring. |
| **Modules** | `src/Modules/` | Diagnostic plugins — 49 scanners across endpoint, network, security, identity, and cloud categories. One `.psm1` per scanner. Discovered at runtime. |
| **Plans** | `src/Core/Workflows.psm1` | Data-only role profiles and task workflows that resolve technician intent to scanner names without coupling the engine to UI concepts. |
| **Portable paths** | `src/Core/Paths.psm1` | `Get-OmniDataRoot` / `Get-OmniDataPath`: every file OmniDiag writes (logs, reports, sessions, backups, scratch) goes under `OmniDiagData` next to the tool, so it runs zero-footprint from a USB stick. No module may build write paths from `GetTempPath()`, `GetTempFileName()`, or `$env:TEMP`/`TMP`/`APPDATA`/`LOCALAPPDATA` (enforced by `Tests/Core.Portable.Tests.ps1`); scanners may *read* those folders. |
| **Runbooks** | `src/Core/Runbooks.psm1` | Organization-owned Markdown runbooks with front matter; approved-only by default; matched to findings by `appliesTo` (the same convention repairs use). |
| **Evidence** | `src/Core/Evidence.psm1` | `Import-OmniSession` (saved JSON / report zip), offline `Search-OmniEvidence` over findings + runbooks, and `Compare-OmniSession` before/after diffs keyed on stable finding IDs. |
| **Local AI** | `src/Core/Ollama.psm1` | Optional loopback-only Ollama client. Projects bounded non-pass evidence, requests structured finding-ID-linked guidance, and has no repair execution dependency. Multi-turn conversations (`New-OmniAssistantConversation` / `Invoke-OmniAssistantTurn`) retrieve evidence per turn and validate citations. |
| **Repair core** | `src/Repair/` | Repair models + step runner, plugin registry/discovery, restore-point helper, and the repair execution engine. The "fix" counterpart to Core. |
| **Repairs** | `src/Repairs/` | Repair plugins. One `.psm1` per repair. Discovered at runtime, exactly like diagnostic modules. |
| **Event Log subsystem** | `src/EventLog/` | Knowledge base (channels + Event-ID translation catalog) and the analysis pipeline (collection, grouping, timeline, finding/pattern generation) used by the Event Logs module. Not plugins; imported by the module. |
| **Reporting** | `src/Reporting/` | HTML / JSON / CSV / Markdown / **PDF** / ZIP exporters + `Export-OmniReport` coordinator. JSON is the versioned **report schema v1** (`ReportV1.psm1`: `ConvertTo-OmniReportV1` / `ConvertFrom-OmniReportV1` and the deterministic `ConvertTo-OmniJsonText` writer; see [SCHEMA.md](SCHEMA.md)). PDF is generated **natively** (`Pdf.psm1`, standard PDF fonts) — no browser or external dependency. Consume a session; emit no side effects beyond writing files. |
| **UI** | `src/UI/` | WPF front-end: runtime-loaded XAML: a small shell (`MainWindow.xaml`) plus per-section fragments (`Sections/*.xaml`, parsed on first navigation; see docs/GUI.md) + `Start-OmniGuiWindow` (behind `Show-OmniDiagGui`). Left-nav panels: **Dashboard** (health score, a DxDiag-style System Information panel via `Get-OmniSystemInfo`, recommendations, module results), **All Findings**, **Diagnostics** (toggle scanners on/off, or run one individually), **Repair Center**, **Local AI** (Ollama readiness + single-question analysis, run in a background runspace). Scans run in a background runspace; a DispatcherTimer polls a synchronized hashtable for progress; Cancel drives the engine's CancellationToken. Report export and per-scanner selection are wired here. STA-hosted when launched from MTA (PowerShell 7). |
| **CLI** | `src/Cli/` | Console presentation (dashboard + progress) and the `omnidiag` command-line router (`Router.psm1` / `omnidiag.ps1`, GNU-style arguments; see [CLI.md](CLI.md)). Exit codes come from `Core/ExitCodes.psm1`. |

## Core building blocks

* **Models** (`Core/Models.psm1`) — serialization-friendly PSCustomObject factories:
  `New-OmniFinding`, `New-OmniResult`, `Add-OmniFinding`, `Set-OmniResultMetric`,
  `Complete-OmniResult`, plus the severity vocabulary and `Get-OmniTimeRange`.
  Models are objects (not classes) so they cross module boundaries without
  `using module` and serialize losslessly to JSON.
* **Logging** (`Core/Logging.psm1`) — `New-OmniLogger` returns a leveled logger that
  writes to an in-memory ring buffer, a JSON-lines file, and optionally the console.
  No silent failures: the logger itself never throws.
* **Registry** (`Core/Registry.psm1`) — `Get-OmniModule` discovers plugins,
  validates the contract, and reads each manifest. `New-OmniContext` builds the
  per-run context; `Test-OmniIsAdministrator` reports elevation.
* **Engine** (`Core/Engine.psm1`) — `Invoke-OmniSession` runs modules, honors
  cooperative cancellation, applies the `IncludeCategory` / `ExcludeCategory` /
  `IncludeModule` filters (the last selects individual scanners by name — what the GUI
  Diagnostics tab and the launcher's `-IncludeModule` use), reports progress, captures
  per-module errors, and finalizes timing/status.
* **Health scoring** (`Core/HealthScore.psm1`) — `Get-OmniHealthScore` turns results
  into the 0-100 score, severity counts, per-category status, and top recommendations.
* **Registry scan** (`Core/RegistryScan.psm1`) — `Get-OmniInvalidRegistryEntry` (read-only,
  CCleaner-style detection of invalid/obsolete entries), `Export-OmniRegistryBackup` (writes a
  `.reg` backup of affected keys), and `Remove-OmniRegistryEntry`. Shared by the **Registry
  Health** scanner (reporting) and the **Clean Invalid Registry Entries** repair (backup, then
  remove) so detection lives in exactly one place.

## The plugin contract

A diagnostic module is a `.psm1` in `src/Modules/` that exports exactly two
convention-based functions:

```powershell
function Get-OmniModuleManifest {
    @{
        Name          = 'My Module'   # required, unique
        Id            = 'network.my-module'  # contract v1: stable, unique '<group>.<kebab-name>'
        Group         = 'network'     # contract v1: one of the v1.0 groups or 'extras'
        NetworkAccess = 'None'        # contract v1: None | LocalNetwork | Internet
        Category      = 'Network'     # required, dashboard grouping
        Description   = 'What it checks.'
        RequiresAdmin = $false        # engine auto-skips if not elevated (alias: RequiresElevation)
        Order         = 50            # lower runs first
        Enabled       = $true
        # Optional (contract v1): TimeoutSec = 60; SupportedArchitectures = @('x64', 'arm64')
    }
}

function Invoke-OmniModuleScan {
    param([pscustomobject] $Context)   # logger, time range, token, IsAdmin, config

    $result = New-OmniResult -ModuleName 'My Module' -Category 'Network'
    # ... collect data, honoring $Context.CancellationToken ...
    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
        -Title 'Something is wrong' -Severity 'Warning' -Component 'Network/DNS' `
        -LikelyCause '...' -Confidence 70 -Recommendation '...')
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
```

Because each module is invoked inside its **own** session state via the call
operator on its `PSModuleInfo` (`& $moduleInfo { ... }`), identically-named
convention functions across modules never collide.

Add the self-bootstrap guard at the top so the module is usable standalone (e.g.
in Pester) as well as under the root module:

```powershell
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}
```

## The repair contract (Repair Center)

Repairs are the "fix" half of OmniDiag and reuse the plugin pattern verbatim. A repair
is a `.psm1` in `src/Repairs/` that exports two convention functions (and may export a
third), discovered and isolated by `Get-OmniRepair` the same way modules are:

```powershell
function Get-OmniRepairManifest {
    @{
        Name          = 'Flush DNS Cache'  # required, unique
        Category      = 'Network'          # menu grouping
        Description   = 'What it does.'
        RequiresAdmin = $false             # engine skips gracefully if not elevated
        Risk          = 'Safe'             # Safe | Moderate | Destructive
        RestorePoint  = $false             # checkpoint before running
        RebootHint    = $false             # action typically needs a reboot
        AppliesTo     = @('network/dns')   # finding Id/Component substrings addressed
        Order         = 10
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    param([pscustomobject] $Context)       # Logger, IsAdmin, DryRun, token, Config, Host
    $r = New-OmniRepairResult -Name 'Flush DNS Cache' -Category 'Network'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Flush resolver cache' `
        -Action { ipconfig /flushdns }
    return (Complete-OmniRepairResult -Result $r)
}

# Optional: finer "recommended for this scan" logic than AppliesTo substring matching.
function Test-OmniRepairApplicable { param([pscustomobject] $Session) <# [bool] #> }
```

Key rules:

* **All side effects go through `Invoke-OmniRepairStep`.** It honors the context's
  `DryRun` flag (describe, don't execute), captures output and exit code, and logs each
  step — so a dry-run is guaranteed side-effect-free and every plugin stays tiny.
* **Selection and confirmation are the caller's job**, not the engine's. `Invoke-OmniRepair`
  runs an already-chosen set; the console (`Invoke-OmniRepairConsole`) and, later, the GUI
  own the menu and the per-action Y/N. This keeps the engine surface-agnostic and testable.
* **Safety is built in:** the engine is `SupportsShouldProcess`; admin-only repairs skip
  gracefully when not elevated; and it creates ONE System Restore checkpoint up front for a
  batch that contains any `RestorePoint` repair (never one per repair — that would hit the
  24h throttle). The point is verified (a new sequence number, or an existing point from
  the last 24h); if none protects the run, `RestorePoint` repairs are **skipped** unless the
  caller passes `-AllowWithoutRestorePoint`.
* **Cancellation is cooperative:** `Invoke-OmniRepairStep` refuses to start a step once the
  context's token is cancelled, and the GUI never kills a running repair pipeline.
* **Repair `Category` is a menu grouping** (Network, Storage, System, Services, Update,
  Cleanup), separate from the 13 diagnostic categories.

Result shapes: **`OmniDiag.RepairResult`** (one repair: `Status`, `Steps`, `RebootRequired`,
timing), **`OmniDiag.RepairSession`** (a run: `Results`, `RestorePoint`, `RebootRequired`,
`Cancelled`, timing). Repairs link back to findings via the stable finding `Id`/`Component`
and the manifest's `AppliesTo`, surfaced by `Get-OmniApplicableRepair`.

## The context object

`Invoke-OmniModuleScan` receives one argument, the context:

| Property | Description |
|---|---|
| `Logger` | Leveled logger (`.Info()`, `.Warn()`, `.Error()`, `.Debug()`). |
| `TimeRange` | `Start`, `End`, `Label`, `Preset` for time-aware modules. |
| `CancellationToken` | `[System.Threading.CancellationToken]` — check `IsCancellationRequested`. |
| `IsAdmin` | Whether the process is elevated. |
| `NetworkProbes` | Whether connectivity probes may run (opt-in; read it with `Test-OmniNetworkProbeEnabled`). Probe targets: `Get-OmniProbeTarget` (defaults merged with `Config.ProbeTargets`). |
| `Architecture` / `Platform` | Host facts the engine uses for `NotSupported` skips (`x64`/`arm64`; `Windows`/`Linux`/`macOS`). |
| `Config` | Free-form hashtable for per-run options. |
| `Host` | ComputerName / UserName / PSVersion. |

A module that runs on the parallel engine gets a context rebuilt in its worker runspace from
these values (its logger is in-memory and merged into the caller's log afterwards), so modules
must treat the context as plain data and must not stash state in it.

## Result shapes

* **`OmniDiag.Finding`** — atomic observation: `Title`, `Severity`, `Component`,
  `Detail`, `LikelyCause`, `Confidence`, `Recommendation`, `Data`.
* **`OmniDiag.Result`** — one module run: `Status`, `Findings`, `Metrics`, timing.
* **`OmniDiag.Session`** — full scan: `Results`, `Summary`, timing, `Cancelled`.

## Execution & concurrency

Since 0.6.0 `Invoke-OmniSession` runs modules on a **runspace pool** (`-MaxParallel`, default
the logical processor count capped at 8; `-MaxParallel 1` is the sequential engine, kept as
the fallback):

* Each worker runspace imports the root module manifest once (InitialSessionState) and then
  imports the plugin file by path: a registration's `PSModuleInfo` belongs to the caller's
  runspace and is never used across threads.
* The context crosses as plain data (time range, token, a copy of `Config`, elevation, the
  probes flag, host facts) and is rebuilt in the worker. Each worker logs to an in-memory
  logger; the caller merges those records (`AddRecord`, original timestamps kept), so only the
  caller's thread appends to the log file.
* The caller's thread runs a poll loop: it dispatches work, collects finished workers, stops
  modules that exceed their `TimeoutSec` (reported as `Failed`, `Error` = `Timed out after N
  s`, exit code 3), honors the `CancellationToken` (no new work; running workers are stopped
  and reported as `Skipped` with `SkippedReason` = `Cancelled`), and invokes the progress
  callback, so callbacks never run on a worker thread.
* Results are returned in registration order, whatever finished first.
* Modules whose manifest sets `Parallel = $false` (e.g. Benchmark, which measures the
  machine) and registrations without a plugin file run on the caller's thread after the
  pool. Timeouts are not enforced on the caller's thread.
* Structured skips: `RequiresElevation`, `NotSupported` (`SupportedPlatforms` /
  `SupportedArchitectures` exclude the host), `Cancelled`. Modules removed by a caller's
  filters are simply not part of the session.

The GUI runs the whole session in a background STA runspace (the pool nests inside it) while
a DispatcherTimer polls progress on the UI thread; pool workers use the caller's COM
apartment (STA under Windows PowerShell and the GUI, MTA under pwsh).

## v1.0 target

The sections above describe OmniDiag as it is. This section is the agreed direction for
v1.0; the delivery plan is [ROADMAP.md](ROADMAP.md) and the starting point is
[STATUS.md](STATUS.md). Items marked *(decision)* follow the owner decisions approved on 2026-10-18 (listed in the roadmap).

**Implemented in 0.5.0 (Phase 1):** module contract v1, report schema v1, the exit codes, and
the CLI router with `list`, `scan`, `report`, `version`, and `help` — each subsection below says
what shipped and what is still to come.

### Stack decision

Keep PowerShell (Windows PowerShell 5.1 + PowerShell 7) and WPF. How the v1.0 requirements fit:

| Requirement | Approach in this stack |
|---|---|
| `omnidiag` command with subcommands | `omnidiag` → `OmniDiag.cmd` (one file: Windows names are case-insensitive, so a separate `omnidiag.cmd` would collide with it) → `src/Cli/omnidiag.ps1` → `src/Cli/Router.psm1` (GNU-style arguments) *(0.5.0)*. Optional tiny signed `omnidiag.exe` stub (.NET Framework 4.8) only if winget aliases or a signed executable entry point require it *(decision)* |
| ARM64 | Windows PowerShell 5.1 + WPF run natively on Windows 11 ARM64 (.NET Framework 4.8.1); PowerShell 7 ships win-arm64. Scanners report unavailable data as "not available" |
| Full report < 60 s | Runspace-pool executor in the engine (the plugin contract already allows it), per-module timeouts, bounded event queries |
| GUI startup < 2 s | Manifest-only plugin discovery, deferred tab construction, no CIM calls before first paint |
| Signed code | Authenticode signatures + file catalog via a build hook that does nothing without a certificate. Unsigned scripts run in Constrained Language mode under WDAC/AppLocker, which breaks WPF and .NET calls *(decision: certificate route)* |
| Installer | Per-user WiX MSI (adds `omnidiag` to PATH, no admin) + winget manifest pointing to it; portable zip stays the xcopy option *(decision)* |
| Versioned JSON | JSON Schema 2020-12 file per major version, `schemaVersion` in every document, golden-file tests |

### Layers

```text
OmniDiag.cmd / OmniDiag-GUI.cmd ─┐
OmniDiag.ps1 (compat front end) ─┼─► CLI router ─► public cmdlets (Get-OmniDiag*, Invoke-OmniDiag*)
WPF GUI ─────────────────────────┘                     │
                                                       ▼
        Core: engine (runspace pool, timeouts) · plugin registry · models v1 · redaction · logging · paths
                         │                                   │
                 Scanners (src/Modules)              Repairs (src/Repairs, --apply only)
                         │
        Reporting: JSON v1 · HTML · CSV · Markdown · PDF · bundle (optionally redacted)
```

### Module contract v1 *(implemented in 0.5.0)*

`Get-OmniModuleManifest` keeps its current fields and adds:

| Field | Meaning |
|---|---|
| `Id` | Stable, unique, kebab/dotted id (e.g. `network.listening-ports`) |
| `Group` | One of the ten v1.0 groups (or `extras`) *(decision)* |
| `RequiresElevation` | Alias of `RequiresAdmin` |
| `NetworkAccess` | `None` · `LocalNetwork` · `Internet`; anything other than `None` means the scanner has a connectivity probe, which runs only with `--network-probes` *(decision)* |
| `TimeoutSec` | Per-module budget for the engine |
| `SupportedArchitectures` | `x64`, `arm64` |
| `SupportedPlatforms` | `Windows`, `Linux`, `macOS` (0.6.0; default all) |
| `Parallel` | `$false` keeps the module off the runspace pool (0.6.0; default `$true`) |

Manifests without these fields still load with derived defaults. `Invoke-OmniModuleScan($Context)`
is unchanged; it is the spec's `Run(ctx)`.

As shipped: all 49 scanners declare `Id`, `Group`, and `NetworkAccess`; all 11 repairs declare
`Id` (`repair.<kebab-name>`) and `NetworkAccess`. `Resolve-OmniPluginContract` (Core/Registry)
validates and normalizes the fields for both registries and derives the defaults (`Id` =
`<group>.<kebab-name>`, `Group` = `extras`, `NetworkAccess` = `None`, `TimeoutSec` = 60,
`SupportedArchitectures` = `x64`, `arm64`). Invalid values and duplicate Ids are contract
violations: the plugin is logged and skipped. Registrations expose `Id`, `Group`,
`RequiresElevation`, `NetworkAccess`, `TimeoutSec`, and `SupportedArchitectures`; the engine stamps
`ModuleId`, `Group`, and `SkippedReason` on each result. Since 0.6.0 the engine enforces
`TimeoutSec` for pooled modules, and connectivity probes are opt-in everywhere: scanners with
`NetworkAccess` other than `None` run in every selection but probe only when the context's
`NetworkProbes` flag is set (`--network-probes`, `-NetworkProbes`, the GUI option); otherwise
they add a "Connectivity probe not run" Information finding. `Tests/Core.Contract.Tests.ps1`
enforces the conventions table, which lives in `Tests/data/scanner-groups/<group>.psd1` (one
file per group; every scanner listed in exactly one).

### Report schema v1 *(implemented in 0.5.0)*

A projection of the session at the export boundary; the in-memory session is not changed.
As shipped (full reference: [SCHEMA.md](SCHEMA.md), schema file
`schemas/omnidiag-report.v1.json`), the envelope also carries a `scan` object (timing, cancelled,
time range, plan), each module carries `category`, `requiresElevation`, `error`, and `metrics`,
and finding `evidence` is `{detail, data}`; `requiresElevation` lives on the module, not the
finding. `Export-OmniJsonReport`, `Export-OmniReport -Format Json`, and the package `data.json`
write v1; saved sessions (`Save-OmniSession`) stay native; `Import-OmniSession` reads both.

```text
{ schemaVersion: "1.1.0", tool: {name, version}, generatedAt, host (redactable), options,
  summary: {healthScore, grade, counts},
  modules: [ {id, name, group, status, skippedReason, startedAt, durationMs,
              findings: [ {id, moduleId, title, severity, severityNative, passed, component,
                           evidence, likelyCause, recommendation, confidence,
                           requiresElevation} ] } ] }
```

Severity mapping *(decision)*: Pass and Information → `Info` (Pass also sets `passed: true`);
Warning → `Warning`; Error and Critical → `Critical`. `severityNative` keeps the original
value, so the health score and GUI don't change. Versioning follows SemVer: additive changes
bump the minor version; breaking changes bump the major version and add a new schema file.

### CLI

```text
omnidiag list [modules|groups|repairs|plans]
omnidiag scan [--group <g>…] [--module <id>…] [--profile <p> | --workflow <w>] [--network-probes]
omnidiag <group>                       # shorthand for scan --group <group>
omnidiag report [--from-session <path>|last] [--redact]
omnidiag repair list | run <id>… (--what-if | --apply [--yes])
omnidiag compare <before> <after>
omnidiag gui | version
global: --format json|csv|md|html|pdf  --output <path>  --redact  --elevated-only
        --verbose  --quiet  --no-color
```

Data goes to stdout only when `--format` is given without `--output`; status and progress go to
stderr.

*Implemented in 0.5.0:* `list`, `scan` (`--group`, `--module`, `--profile`, `--workflow`,
`--range`), `report`, `version`, `help`, and the global `--format`, `--output`, `--verbose`,
`--quiet`, `--no-color`, `--help`. *0.6.0:* the `<group>` shorthand and `--network-probes`,
plus the PowerShell cmdlets `Get-OmniDiagGroup`, `Get-OmniDiagModule`, `Invoke-OmniDiagScan`,
and `Get-OmniDiag<Group>` (`src/Core/Groups.psm1`; findings in the report-v1 shape, type
`OmniDiag.V1.Finding`). The rest of the tree (`repair`, `compare`, `gui`, `--from-session`,
`--redact`, `--elevated-only`) follows in Phase 3. Reference: [CLI.md](CLI.md).

### Exit codes *(implemented in 0.5.0)*

`Core/ExitCodes.psm1` holds the table as data (`Get-OmniExitCodeTable`) and derives a scan's code
(`Get-OmniExitCode`) and a repair run's code (`Get-OmniRepairExitCode`). Both the router and
`OmniDiag.ps1` exit with them, and `OmniDiag.cmd` propagates `%ERRORLEVEL%`.

| Code | Meaning |
|---|---|
| 0 | Success, no warnings or critical findings |
| 1 | Warnings present |
| 2 | Critical findings present |
| 3 | Partial: one or more modules failed or timed out |
| 4 | Requested module(s) need elevation and the process isn't elevated |
| 5 | Cancelled |
| 10 | Usage or argument error |
| 11 | Repair failed |
| 12 | Repair succeeded; reboot required |
| 20 | Internal error |

### Redaction

`ConvertTo-OmniRedacted` runs at the export boundary and never changes the session. It collects
identifiers from the context (computer, user, domain, FQDN, profile path, user SIDs) and matches
IPv4, IPv6, and MAC addresses. It replaces each with a stable pseudonym per bundle (`HOST-1`,
`USER-1`, `IP-1`), so findings still correlate. It walks every string in the object graph and in
file names. An optional mapping file stays local. *(Implemented in Phase 3; see [REDACTION.md](REDACTION.md).)*

### No-network enforcement

1. **Static:** a Pester test walks the AST of every script for network APIs (`Invoke-WebRequest`,
   `Invoke-RestMethod`, `Net.WebClient`, `HttpClient`, sockets, `Ping`, `Dns`, `Resolve-DnsName`,
   `Test-Connection`, `Test-NetConnection`, `Test-ComputerSecureChannel`, `Start-BitsTransfer`)
   and fails on any use outside an allowlist tied to the plugin's `NetworkAccess`.
2. **Runtime (Windows runner):** `build/Test-NoNetworkRuntime.ps1`, CI job `no-network`. It
   enables auditing for *Filtering Platform Connection* (Security events 5156 allowed / 5157
   blocked, each carrying the calling `ProcessID` and `Application`) and *Process Creation*
   (4688, to follow child processes), enables the `Microsoft-Windows-DNS-Client/Operational`
   log (3006 = query issued, attributed to the calling process), and adds outbound firewall
   block rules for `pwsh.exe` and `powershell.exe` so an attempt never leaves the runner while
   other processes keep their connectivity. It then runs, with the environment `OmniDiag.cmd`
   sets up (PowerShell update check and telemetry off):
   * a **positive control** (TCP connect to `1.1.1.1:443` and a name lookup) that the detector
     must see, or the test fails as vacuous;
   * `omnidiag scan --format json` (default selection) and `omnidiag report`;
   * when the CLI supports it, `omnidiag scan --network-probes` - reported for information
     only, since that is the opt-in path.

   For each run it keeps the events from the run's time window and process tree, drops
   inbound and loopback (`127.0.0.0/8`, `::1`) records, and also flags connections to the
   known probe targets (`1.1.1.1`, the default gateways) and lookups of the probe name
   (`www.microsoft.com`) from any process, in case a probe is attributed to a system
   process. Any remaining event in the scan or report run is a violation (exit 1). Audit
   policy (`auditpol /backup` / `/restore`), firewall profiles and rules, and the DNS log
   state are restored in a `finally` block. The JSON and Markdown report is a CI artifact.
3. **Mocks:** per-module Pester mocks for network cmdlets.

### CI pipeline

lint (PSScriptAnalyzer + contract/help tests) → tests (Windows pwsh 7, Windows PowerShell 5.1,
Ubuntu for pure logic, `windows-11-arm`; coverage gate on Core) → standard-user leg →
no-network runtime test (`build/Test-NoNetworkRuntime.ps1`) → performance (soft gate,
`build/Measure-ScanPerformance.ps1`: median of three full scans against the 60 s budget,
startup time, slowest modules) → package (reproducible zip, signing hook,
`SHA256SUMS`, SBOM) → release on tag.
