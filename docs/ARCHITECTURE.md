# OmniDiag Architecture

OmniDiag is a layered, plugin-based PowerShell application. The core is closed to
modification: new diagnostic capabilities are added as plugin modules, never by
editing the engine.

## Layers

| Layer | Folder | Responsibility |
|---|---|---|
| **Launcher** | `OmniDiag.ps1` | Host validation, module import, runs a session, renders the console dashboard. |
| **Public API** | `src/OmniDiag.psm1` | `Invoke-OmniDiag` and version helpers. The single call the CLI/GUI use. |
| **Core** | `src/Core/` | Data models, logging, plugin registry, orchestration engine, health scoring. |
| **Modules** | `src/Modules/` | Diagnostic plugins — the 35 granular scanners across 10 categories. One `.psm1` per scanner. Discovered at runtime. |
| **Repair core** | `src/Repair/` | Repair models + step runner, plugin registry/discovery, restore-point helper, and the repair execution engine. The "fix" counterpart to Core. |
| **Repairs** | `src/Repairs/` | Repair plugins. One `.psm1` per repair. Discovered at runtime, exactly like diagnostic modules. |
| **Event Log subsystem** | `src/EventLog/` | Knowledge base (channels + Event-ID translation catalog) and the analysis pipeline (collection, grouping, timeline, finding/pattern generation) used by the Event Logs module. Not plugins; imported by the module. |
| **Reporting** | `src/Reporting/` | HTML / JSON / CSV / **PDF** / ZIP exporters + `Export-OmniReport` coordinator. PDF is generated **natively** (`Pdf.psm1`, standard PDF fonts) — no browser or external dependency. Consume a session; emit no side effects beyond writing files. |
| **UI** | `src/UI/` | WPF front-end: runtime-loaded XAML (`MainWindow.xaml`) + `Show-OmniDiagWindow`. Left-nav panels: **Dashboard**, **All Findings**, **Diagnostics** (toggle scanners on/off, or run one individually), **Repair Center**. Scans run in a background runspace; a DispatcherTimer polls a synchronized hashtable for progress; Cancel drives the engine's CancellationToken. Report export and per-scanner selection are wired here. STA-hosted when launched from MTA (PowerShell 7). |
| **CLI** | `src/Cli/` | Console presentation (dashboard + progress). |

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

## The plugin contract

A diagnostic module is a `.psm1` in `src/Modules/` that exports exactly two
convention-based functions:

```powershell
function Get-OmniModuleManifest {
    @{
        Name          = 'My Module'   # required, unique
        Category      = 'Network'     # required, dashboard grouping
        Description   = 'What it checks.'
        RequiresAdmin = $false        # engine auto-skips if not elevated
        Order         = 50            # lower runs first
        Enabled       = $true
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
  24h throttle), failing soft when System Restore is unavailable.

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
| `Config` | Free-form hashtable for per-run options. |
| `Host` | ComputerName / UserName / PSVersion. |

## Result shapes

* **`OmniDiag.Finding`** — atomic observation: `Title`, `Severity`, `Component`,
  `Detail`, `LikelyCause`, `Confidence`, `Recommendation`, `Data`.
* **`OmniDiag.Result`** — one module run: `Status`, `Findings`, `Metrics`, timing.
* **`OmniDiag.Session`** — full scan: `Results`, `Summary`, timing, `Cancelled`.

## Execution & concurrency

Modules currently run **sequentially**, with the cancellation token checked before
each one; a full 35-scanner run takes roughly a minute. The engine and the module
contract are intentionally shaped so a runspace-pool parallel executor can be
substituted later — cutting scan time — without changing any module or caller. GUI
responsiveness is already handled separately: the whole session runs in a background
STA runspace while a DispatcherTimer polls progress on the UI thread.
