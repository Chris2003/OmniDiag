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
| **Modules** | `src/Modules/` | Diagnostic plugins. One `.psm1` per module. Discovered at runtime. |
| **Event Log subsystem** | `src/EventLog/` | Knowledge base (channels + Event-ID translation catalog) and the analysis pipeline (collection, grouping, timeline, finding/pattern generation) used by the Event Logs module. Not plugins; imported by the module. |
| **Reporting** | `src/Reporting/` | HTML / JSON / CSV / ZIP exporters + `Export-OmniReport` coordinator. Consume a session; emit no side effects beyond writing files. |
| **UI** | `src/UI/` | WPF front-end: runtime-loaded XAML (`MainWindow.xaml`) + `Show-OmniDiagWindow`. Scans run in a background runspace; a DispatcherTimer polls a synchronized hashtable for progress; Cancel drives the engine's CancellationToken. STA-hosted when launched from MTA (PowerShell 7). |
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
  cooperative cancellation, reports progress, captures per-module errors, and
  finalizes timing/status.
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

Milestone 1 runs modules **sequentially**, checking the cancellation token before
each module. The engine signature is intentionally shaped so a runspace-pool
parallel executor can be substituted in Milestone 5 (where GUI responsiveness
matters) without changing any module or caller.
