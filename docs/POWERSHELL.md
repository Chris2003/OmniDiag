# OmniDiag from PowerShell

OmniDiag is a PowerShell module. Everything the `omnidiag` command line and the GUI do is
available as cmdlets that return objects, so you can filter, sort, export, and script the
results. This page lists the public cmdlets (the supported, documented API from 0.8.0,
decision 11 in [ROADMAP.md](ROADMAP.md)), the objects they return, the plugin SDK, and the
names that are deprecated.

```powershell
Import-Module .\src\OmniDiag.psd1          # from the tool folder (portable zip or clone)
Get-Command -Module OmniDiag -Name *-OmniDiag*
Get-Help Invoke-OmniDiagRepair -Full       # every public cmdlet has full help with examples
```

Works in Windows PowerShell 5.1 and PowerShell 7. Nothing contacts the network unless you ask
for connectivity probes (`-NetworkProbes`), and nothing on the system changes unless you
confirm a repair.

## Public cmdlets

| Cmdlet | What it does | Returns |
|---|---|---|
| `Get-OmniDiagGroup` | The module groups (system, performance, services, startup, events, reliability, storage, network, updates, security, extras) with scanner counts. | `OmniDiag.GroupInfo` |
| `Get-OmniDiagModule` | The scanners: id, group, elevation, network access, timeout, architectures. | `OmniDiag.ModuleInfo` |
| `Invoke-OmniDiagScan` | Runs scanners (all, `-Group`, `-Module`, `-Profile`, `-Workflow`, `-ElevatedOnly`). | `OmniDiag.V1.Finding` objects, or the session with `-AsSession` |
| `Get-OmniDiag<Group>` | One per group: `Get-OmniDiagSystem`, `-Performance`, `-Services`, `-Startup`, `-Events`, `-Reliability`, `-Storage`, `-Network`, `-Updates`, `-Security`, `-Extras`. | `OmniDiag.V1.Finding` |
| `Invoke-OmniDiagReport` | Scan + report files in one step (`omnidiag report`). `-Bundle`, `-Redact`. | `OmniDiag.ReportSet` (+ `Session`, `SessionPath`, `ExitCode`) |
| `Export-OmniDiagReport` | Report files for an existing session: HTML, JSON (schema v1), CSV, Markdown, PDF, ZIP. `-Redact`. | `OmniDiag.ReportSet` |
| `Import-OmniDiagSession` | Loads a saved session, a JSON report, or a report `.zip`; `last` / `previous`. | `OmniDiag.Session` |
| `Compare-OmniDiagSession` | Before/after comparison of two sessions. | `OmniDiag.SessionComparison` |
| `Get-OmniDiagRepair` | The repairs, with `Recommended` for a session. | `OmniDiag.RepairRegistration` |
| `Invoke-OmniDiagRepair` | Runs repairs: `-WhatIf` is a dry run; asks before each repair (`-Confirm`). | `OmniDiag.RepairSession` (+ `ExitCode`) |
| `Show-OmniDiagGui` | Opens the window (Windows). | nothing |

### Scanning

```powershell
# Everything that is not a passing check, worst first
Invoke-OmniDiagScan | Sort-Object { @{ Critical = 0; Warning = 1; Info = 2 }[$_.severity] } |
    Format-Table severity, moduleId, title

# One group, including passing checks
Get-OmniDiagStorage -IncludePassed | Format-Table passed, severity, title

# A role profile or task workflow, as a session for reports
$s = Invoke-OmniDiagScan -Workflow SlowComputer -AsSession

# Only the checks that need administrator rights (throws when not elevated)
Invoke-OmniDiagScan -ElevatedOnly
```

`Invoke-OmniDiagScan` parameters: `-Group`, `-Module`, `-Profile`, `-Workflow` (a profile or
workflow can't be combined with `-Group`/`-Module`), `-NetworkProbes`, `-ElevatedOnly`,
`-Range Last24Hours|Last7Days|Last30Days`, `-IncludePassed`, `-AsSession`, `-MaxParallel`,
`-Config`, `-ProgressCallback`, `-CancellationToken`, `-ModulesPath`. The group cmdlets take
`-IncludePassed`, `-Range`, `-MaxParallel`, `-AsSession`, `-ModulesPath` (and
`-NetworkProbes` on `Get-OmniDiagNetwork` / `Get-OmniDiagExtras`).

### Reports

```powershell
# Scan and write HTML + JSON (default) to a case folder, plus one zip to attach
Invoke-OmniDiagReport -OutputDirectory C:\Cases\1234 -Bundle

# Export an existing session; redacted for sharing outside the organization
Invoke-OmniDiagScan -Group network -AsSession | Export-OmniDiagReport -Format Html, Json, Pdf -Redact
Export-OmniDiagReport -Session last -Format Md -OutputDirectory .\out
```

`-Redact` replaces host names, user names, domains, SIDs, profile paths, and IP/MAC addresses
with stable pseudonyms (`HOST-1`, `USER-1`, `IP-1`, ...) in every file and file name;
`-RedactionMapPath <file>` also writes the local pseudonym map (keep it private). When the
redaction module is not part of the build, `-Redact` throws a `NotSupportedException`
saying so. The session object is never changed.

### Saved sessions and comparisons

Every scan from the CLI and `Invoke-OmniDiagReport` saves its session to
`OmniDiagData\sessions`. `last` and `previous` name the newest two.

```powershell
$before = Import-OmniDiagSession -Path previous
$c = Compare-OmniDiagSession -Before $before -After last
$c.Verdict                       # Improved | Regressed | Mixed | Unchanged
$c.Resolved | Format-Table Severity, Title
Get-ChildItem C:\Cases\*.zip | Import-OmniDiagSession | ForEach-Object { $_.Summary.Score }
```

### Repairs

```powershell
Get-OmniDiagRepair | Format-Table Id, Risk, RequiresElevation, RestorePoint, Name
Get-OmniDiagRepair -Session last -RecommendedOnly

# Dry run: describes every step, runs nothing, writes nothing to the audit log
Invoke-OmniDiagRepair -Id flush-dns-cache, restart-print-spooler -WhatIf

# Apply, asking before each repair (ConfirmImpact is High)
Invoke-OmniDiagRepair -Id flush-dns-cache

# Unattended (scheduled task, RMM): no prompts
$r = Invoke-OmniDiagRepair -Id flush-dns-cache -Confirm:$false
if ($r.ExitCode -eq 12) { 'Reboot required' }

# Pipeline from the catalog
Get-OmniDiagRepair -Session last -RecommendedOnly | Invoke-OmniDiagRepair -WhatIf
```

`-Id` takes the full id (`repair.flush-dns-cache`), the id without `repair.`, or the name.
`-Force` skips the prompts like `-Confirm:$false` (an explicit `-Confirm` still asks).
`-AllowWithoutRestorePoint` runs repairs that promise a System Restore point even when none
could be created. In a non-interactive host (`pwsh -NonInteractive`) use `-Confirm:$false`
or `-Force`, because PowerShell cannot ask.

The returned session's `ExitCode` matches `omnidiag repair run`: 11 a repair failed, 12 a
reboot is required, 4 every requested repair needs elevation and PowerShell is not elevated
(those repairs are reported as `Skipped`; nothing ran), otherwise 0. Every applied step is
appended to `OmniDiagData\logs\repair-audit.jsonl` (see [CLI.md](CLI.md#repair-run-id---what-if----apply---yes));
`Get-OmniRepairAuditPath` returns the path:

```powershell
Get-Content (Get-OmniRepairAuditPath) | ConvertFrom-Json | Format-Table time, repairId, step, succeeded
```

### Exit codes

`Get-OmniExitCodeTable` lists the codes; `Get-OmniExitCode -Session $s` gives a scan's code
and `Get-OmniRepairExitCode` / `Get-OmniRepairRunExitCode` a repair run's. They are the
codes `omnidiag` and `OmniDiag.ps1` exit with ([CLI.md](CLI.md#exit-codes)).

## Objects on the pipeline

| Type name | From | Key properties |
|---|---|---|
| `OmniDiag.V1.Finding` | `Invoke-OmniDiagScan`, `Get-OmniDiag<Group>` | The report schema v1 finding (`id`, `moduleId`, `title`, `severity` Info/Warning/Critical, `severityNative`, `passed`, `component`, `evidence`, `likelyCause`, `recommendation`, `confidence`) plus `moduleName`, `group`, `moduleStatus`, `skippedReason`. See [SCHEMA.md](SCHEMA.md). |
| `OmniDiag.Session` | `-AsSession`, `Import-OmniDiagSession`, `Invoke-OmniDiagReport` (`.Session`) | `StartTime`, `EndTime`, `Host`, `Results` (one `OmniDiag.Result` per scanner: `ModuleName`, `Category`, `Status`, `Findings`, `Metrics`), `Summary` (`Score`, counts), `Cancelled`, `LogPath`, `ScanPlan`, `SourcePath` (imported). |
| `OmniDiag.ReportSet` | `Export-OmniDiagReport`, `Invoke-OmniDiagReport` | `OutputDirectory`, `BaseName`, `Formats`, `Files`, `Warnings`, `GeneratedAt`. |
| `OmniDiag.SessionComparison` | `Compare-OmniDiagSession` | `Verdict`, `BeforeScore`, `AfterScore`, `ScoreDelta`, `Resolved`, `New`, `Persisting` (`OmniDiag.FindingChange`: `BeforeSeverity`, `AfterSeverity`, `Change`), `ModuleChanges`, `OutOfScope`. |
| `OmniDiag.RepairRegistration` | `Get-OmniDiagRepair` | `Id`, `Name`, `Category`, `Description`, `Risk` (Safe/Moderate/Destructive), `RequiresElevation`, `RestorePoint`, `RebootHint`, `NetworkAccess`, `Recommended`. |
| `OmniDiag.RepairSession` | `Invoke-OmniDiagRepair` | `DryRun`, `Cancelled`, `RestorePoint` (`Status`, `Message`), `RebootRequired`, `Results` (`OmniDiag.RepairResult`: `Name`, `Status` Succeeded/Failed/Skipped/DryRun/RebootRequired, `Steps`, `Error`), `ExitCode`, `LogPath`. |

## Deprecated names (0.8.0)

The pre-1.0 names keep working for one minor version. The first time one is used in a
PowerShell session it prints a warning such as
`Export-OmniReport is deprecated; use Export-OmniDiagReport.` Set
`$env:OMNIDIAG_NO_DEPRECATION_WARNING = 1` to hide these warnings. OmniDiag's own code
(the CLI, `OmniDiag.ps1`, the GUI) never triggers them: the warning is shown only when the
call comes from outside the tool's `src` folder and `OmniDiag.ps1`.

| Deprecated | Use instead | Notes |
|---|---|---|
| `Invoke-OmniDiag` | `Invoke-OmniDiagScan -AsSession` | `-Profile`, `-Workflow`, `-NetworkProbes`, `-Range`, `-Config`, `-ProgressCallback`, `-CancellationToken` are on `Invoke-OmniDiagScan`; `-IncludeModule` is `-Module`. |
| `Export-OmniReport` | `Export-OmniDiagReport` | Default formats are now HTML + JSON; add `-Format Csv` for the old set. |
| `Import-OmniSession` | `Import-OmniDiagSession` | Also takes `last` / `previous` and pipeline input. |
| `Compare-OmniSession` | `Compare-OmniDiagSession` | Also takes `last` / `previous`. |
| `Invoke-OmniRepairCenter` | `Get-OmniDiagRepair` | `-Session` accepts a path or `last`. |
| `Invoke-OmniRepair` | `Invoke-OmniDiagRepair` | Takes ids instead of registrations plus a context; adds `-WhatIf` / `-Confirm` and `ExitCode`. |
| `Show-OmniDiagWindow` | `Show-OmniDiagGui` | |

`Test-OmniOllama` and `Invoke-OmniOllamaAnalysis` (opt-in local AI, [OLLAMA.md](OLLAMA.md))
keep their names.

## Plugin SDK

Scanner and repair plugins (`src\Modules`, `src\Repairs`; see [ARCHITECTURE.md](ARCHITECTURE.md))
run in their own module scope and call these exported functions. They are a stable contract
for plugin authors, separate from the user-facing cmdlets above.

| Area | Functions |
|---|---|
| Results and findings | `New-OmniResult`, `New-OmniFinding`, `Add-OmniFinding`, `Set-OmniResultMetric`, `Complete-OmniResult`, `Get-OmniSeverityRank`, `Get-OmniSeverityNames`, `Get-OmniTimeRange` |
| Connectivity probes (decision 1) | `Test-OmniNetworkProbeEnabled`, `Get-OmniProbeTarget`, `New-OmniProbeSkippedFinding` |
| Data locations | `Get-OmniDataPath`, `Get-OmniDataRoot`, `Get-OmniToolRoot` |
| Shared system data | `Get-OmniSystemInventory`, `Test-OmniIsAdministrator`, `Get-OmniHostArchitecture`, `Get-OmniHostPlatform` |
| Registry helpers | `Get-OmniInvalidRegistryEntry`, `Export-OmniRegistryBackup`, `Remove-OmniRegistryEntry`, `ConvertTo-OmniRegProviderPath`, `ConvertTo-OmniRegExePath` |
| Repairs | `New-OmniRepairResult`, `Invoke-OmniRepairStep` (honors dry run; the only way a repair should change the system), `Add-OmniRepairStep`, `Complete-OmniRepairResult`, `Get-OmniRepairRiskNames` |
| Contract | `Get-OmniGroupNames`, `Get-OmniNetworkAccessNames`, `ConvertTo-OmniKebabCase` |

A scanner exports `Get-OmniModuleManifest` and `Invoke-OmniModuleScan`; a repair exports
`Get-OmniRepairManifest`, `Invoke-OmniRepairAction`, and optionally
`Test-OmniRepairApplicable`.

## Other exported functions

The manifest also exports the building blocks the CLI, GUI, and console use (engine, logger,
exporters such as `Export-OmniJsonReport`, `ConvertTo-OmniReportV1`, `Invoke-OmniDiagCli`,
`Get-OmniRepair`, `New-OmniRepairContext`, `Resolve-OmniSessionPath`,
`Write-OmniDeprecationWarning`, ...). They work, but they are internal: their parameters may
change between minor versions. Script against the public cmdlets above.
