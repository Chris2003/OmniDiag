# omnidiag command line

`omnidiag` is OmniDiag's scriptable command line (0.8.0). It takes GNU-style arguments,
writes data to stdout and progress to stderr, and reports its outcome as a documented exit
code. The classic `OmniDiag.ps1` switches keep working and use the same exit codes.

## Starting it

| How | Notes |
|---|---|
| `omnidiag <command> ...` | `OmniDiag.cmd` is the `omnidiag` command (Windows file names are case-insensitive). With the tool folder on `PATH` (or as the current directory) `omnidiag` runs it. It sets up the same portable, zero-footprint environment as before (data in `OmniDiagData`, TEMP redirected, PowerShell telemetry off), runs the router, and passes its exit code through as `%ERRORLEVEL%`. It never pauses when it gets arguments. |
| `OmniDiag.cmd` with no arguments or a `-Switch` | Classic console (`OmniDiag.ps1`), unchanged. Double-clicking still pauses at the end. |
| `pwsh -File src\Cli\omnidiag.ps1 <command> ...` | The script entry point the launcher calls. |
| `Invoke-OmniDiagCli -Arguments @('scan', '--group', 'network')` | From PowerShell after `Import-Module .\src\OmniDiag.psd1`. Returns the exit code; `-Out` / `-Err` take `TextWriter`s if you want to capture output. |

The launcher sends the first argument to the router when it is a subcommand (`list`, `scan`,
`report`, `repair`, `compare`, `gui`, `version`, `help`, a group id such as `network`, or
anything else that doesn't start with `-`) or a `--long` option. A first argument starting with a single `-` goes to
`OmniDiag.ps1`.

## Command tree

```text
omnidiag list [modules|groups|repairs|plans]
omnidiag scan [--group <g>]... [--module <id>]... [--profile <p> | --workflow <w>]
              [--network-probes] [--elevated-only] [--range <preset>] [--redact [--redaction-map <file>]]
omnidiag <group> [same options as scan]          # shorthand for scan --group <group>
omnidiag report [--bundle] [--redact [--redaction-map <file>]] [--network-probes] [--elevated-only] [--range <preset>]
omnidiag report --from-session <path|last|previous> [--bundle] [--redact]
omnidiag repair list [--from-session <path|last|previous>]
omnidiag repair run <id>... (--what-if | --apply [--yes] [--allow-without-restore-point])
omnidiag compare <before> <after>
omnidiag gui
omnidiag version
omnidiag help [command|group]
global: --format <fmt> --output <path> --verbose --quiet --no-color --help
```

## Commands

### `list [modules|groups|repairs|plans]`

Lists the scanners (default), the module groups, the repairs, or the role profiles and task
workflows. Without `--format` it prints a table. With `--format json` it prints a versioned
document that validates against [`schemas/omnidiag-list.v1.json`](../schemas/omnidiag-list.v1.json):

```json
{ "schemaVersion": "1.0.0", "kind": "modules", "tool": { "name": "OmniDiag", "version": "0.5.0" },
  "items": [ { "id": "network.dns-resolver", "name": "DNS Resolver", "group": "network",
               "category": "Network", "requiresElevation": false, "networkAccess": "Internet",
               "timeoutSec": 60, "supportedArchitectures": ["x64", "arm64"], "enabled": true,
               "description": "..." } ] }
```

`list` supports `json`, `csv`, and `md`.

### `scan [selection]`

Runs scanners and summarizes the findings.

| Option | Meaning |
|---|---|
| `-g`, `--group <id>` | Run every scanner in a group. Repeatable or a comma list. Groups: `system`, `performance`, `services`, `startup`, `events`, `reliability`, `storage`, `network`, `updates`, `security`, `extras`. |
| `-m`, `--module <id>` | Run one scanner by id (e.g. `storage.disk`) or display name. Repeatable or a comma list. Combined with `--group` as a union. |
| `--profile <name>` | Run a role profile (`HelpDesk`, `DesktopSupport`, `SystemsAdmin`, `NetworkAdmin`, `SecurityAdmin`, `CloudAdmin`, `Full`). |
| `--workflow <name>` | Run a task workflow (`QuickTriage`, `SlowComputer`, `NetworkConnectivity`, `Printing`, `WindowsUpdate`, `LoginAndIdentity`, `StorageCleanup`, `SecurityPosture`, `CloudReadiness`, `FullScan`). |
| `--range <preset>` | Event time range: `Last24Hours`, `Last7Days` (default), `Last30Days` (or `24h`, `7d`, `30d`). |
| `--network-probes` | Also run the connectivity probes (see below). Off by default. |
| `--elevated-only` | Run only the selected scanners that require elevation (`requiresElevation` in `list modules`). When the prompt is not elevated, nothing runs and the exit code is 4 with a message; when no selected scanner needs elevation it is a usage error (10). |
| `--redact` | Replace host names, user names, domains, SIDs, profile paths, and IPv4/IPv6/MAC addresses with stable pseudonyms (`HOST-1`, `USER-1`, `IP-1`, ...) in everything written: JSON/CSV/Markdown on stdout, the summary, every report file, report file names, and the status lines on stderr (`Loaded saved session ...`, `Session saved to ...`, `Wrote ...`, `Log: ...`). File paths listed on stdout (one per written file) are the real paths, so scripts can open them. The native session saved in `OmniDiagData\sessions` is not redacted (it never leaves the machine). The JSON report's `options` records `redacted: true`. If this build has no redaction module, the command fails with exit code 20 before scanning. |
| `--redaction-map <file>` | With `--redact`: the exporter also writes the pseudonym-to-value map to this local file. Keep it private; it reverses the redaction. Applies to report files, not to stdout. |

With no selection, every scanner runs. `--profile`/`--workflow` can't be combined with each
other or with `--group`/`--module`.

**Network access (connectivity probes are opt-in).** A default scan contacts no other
machine. Three scanners can probe connectivity: `network.network` (ping the default gateway
and `1.1.1.1`, resolve `www.microsoft.com`), `network.dns-resolver` (resolve
`www.microsoft.com` through the configured resolvers), and `extras.active-directory` (the
domain secure-channel check against a domain controller). They run in every scan, group, and
plan, but without `--network-probes` they do only their local checks (adapters, IP and DNS
configuration, domain membership) and add an Information finding, "Connectivity probe not
run", whose recommendation says how to run it. The router also prints which scanners have
probes turned off. With `--network-probes` the probes run and the report's `options` records
`networkProbes: true`. Probe targets can be changed from PowerShell with
`-Config @{ ProbeTargets = @{ PublicAddress = '9.9.9.9'; DnsName = 'intranet.example';
PingGateway = $false; TimeoutMs = 1000 } }` (`Invoke-OmniDiag`, `Invoke-OmniDiagScan`).

Every scan is also saved in OmniDiag's native format to `OmniDiagData\sessions`, so
`OmniDiag.ps1 -FromSession Last` / `-CompareWith Last` see it.

**Execution.** Scanners run in parallel (a runspace pool with up to one worker per logical
processor, at most 8); results always come back in the scanners' registration order. A
scanner that runs past its `TimeoutSec` budget (default 60 s; `list modules` shows it) is
stopped and reported as `Failed` with the error `Timed out after N s` (exit code 3). Skipped
scanners carry a `skippedReason` in the JSON report: `RequiresElevation`, `NotSupported` (the
scanner doesn't support this platform or processor architecture), or `Cancelled`.

### `<group>`

`omnidiag <group-id> [options]` is shorthand for `omnidiag scan --group <group-id> [options]`,
for example `omnidiag network --network-probes --format json` or `omnidiag storage -o out\`.
Group ids: `system`, `performance`, `services`, `startup`, `events`, `reliability`, `storage`,
`network`, `updates`, `security`, `extras` (`omnidiag list groups`). `--module` adds scanners
from other groups; `omnidiag help <group>` prints the group's usage.

### `report`

Runs every scanner (connectivity probes only with `--network-probes`) and writes an HTML
report and a JSON report (schema v1) to `--output <directory>`, or to `OmniDiagData\reports`
next to the tool. The written paths are printed on stdout, one per line. `--format` replaces
the default `html,json` set (`json`, `csv`, `md`, `html`, `pdf`); `--output` must be a
directory.

| Option | Meaning |
|---|---|
| `--bundle` | Also write one `.zip` report package (the HTML, JSON, and CSV reports) next to the other files. |
| `--redact`, `--redaction-map <file>` | As for `scan`: every file and file name is redacted. |
| `--from-session <path\|last\|previous>` | Export a saved session (a native session, a JSON report, or a report `.zip`) instead of scanning. `last` is the newest saved session in `OmniDiagData\sessions`, `previous` the one before it. Can't be combined with `--range`, `--network-probes`, or `--elevated-only`. The exit code is derived from the loaded session. |
| `--elevated-only`, `--network-probes`, `--range` | As for `scan`. |

### `repair list`

Lists the repairs, like `list repairs`, with the columns id, risk, requiresElevation,
restorePoint, and name. `--format json|csv|md` and `--output` work as for `list`; the JSON
document is the `omnidiag-list` v1 document with `kind: "repairs"`. With
`--from-session <path|last|previous>` each item also has `recommended` (true when the repair
addresses a Warning or worse finding in that session) and the table gets a RECOMMENDED column.
Listing never runs anything.

### `repair run <id>... (--what-if | --apply [--yes])`

Runs repairs by id. An id is the full id (`repair.flush-dns-cache`), the id without the `repair.`
prefix (`flush-dns-cache`), or the display name (`"Flush DNS Cache"`), case-insensitively. Nothing
changes without `--apply`:

| Option | Meaning |
|---|---|
| (neither) | Usage error (exit 10) that explains `--what-if` and `--apply`. Nothing runs. |
| `--what-if` | Dry run: each repair describes every step it would take; no action runs, no restore point is created, and nothing is written to the audit log. Works without elevation. |
| `--apply` | Run the repairs. For each repair OmniDiag asks `Apply repair '<name>' [<id>] (risk ...)? [y/N]` on stderr and reads the answer from stdin; anything but `y`/`yes` (including end of input) skips that repair. |
| `--yes`, `-y` | With `--apply`: don't ask. Required when stdin is not interactive (redirected, a pipe, a scheduled task); without it `--apply` refuses with exit 10 before anything runs. |
| `--allow-without-restore-point` | Run repairs that promise a System Restore point even when none could be created (same as `OmniDiag.ps1 -AllowRepairWithoutRestorePoint`). |
| `--format json`, `--output <file>` | Write a `repair-run` document instead of the text result: `{ schemaVersion, kind: "repair-run", tool, dryRun, cancelled, restorePoint, rebootRequired, exitCode, auditLog, results: [ { id, name, status, rebootRequired, error, steps: [ { description, succeeded, dryRun, output } ] } ] }`. |

Repairs that need elevation are skipped (status `Skipped`) on a non-elevated prompt; when
*every* requested repair needs elevation, `--apply` stops before asking with exit code 4.
Repairs that declare `RestorePoint` get one checkpoint for the whole run and are skipped
when none could be created, unless `--allow-without-restore-point`.

Exit codes: 11 if any repair failed; otherwise 12 if any repair needs a reboot; 4 as above;
0 otherwise (also for a dry run and when every repair was declined).

**Audit log.** Every applied repair step (not dry runs, not skipped or declined repairs)
appends one JSON line to `OmniDiagData\logs\repair-audit.jsonl`, whichever surface ran it
(this command, `OmniDiag.ps1 -Repair`, the GUI, or `Invoke-OmniDiagRepair`):

```json
{"time":"2026-10-18T14:03:12.481Z","repairId":"repair.flush-dns-cache","repairName":"Flush DNS Cache","repairStatus":"Succeeded",
 "step":"Flush the DNS resolver cache","succeeded":true,"output":"Successfully flushed the DNS Resolver Cache.",
 "dryRun":false,"user":"jdoe","computer":"PC-042","restorePoint":"NotRequested"}
```

`output` is truncated to 2000 characters. `restorePoint` is the run's checkpoint status:
`Created`, `RecentExisting`, `Skipped`, `Failed`, `NotRequested` (no selected repair asked for
one), or `SkippedByCaller`. A repair that records no steps gets one line with step
`(no steps recorded)`. Dry runs are deliberately not audited: they change nothing, and what
they would have done is in the run's own log (`omnidiag-repair-*.jsonl`). The file is only
appended to; it is local and never sent anywhere.

### `compare <before> <after>`

Compares two sessions. Each argument is a saved native session, a JSON report (schema v1), a
report `.zip`, a folder (its newest `.json`), `last` (the newest saved session), or
`previous` (the one before it); every scan saves its session to `OmniDiagData\sessions`.
Findings are matched by stable id and classified as resolved, new, or persisting
(improved / worsened / unchanged); only modules that completed in both sessions are compared.

`--format text` (default) prints a readable summary, `md` a Markdown document, and `json` a
document `{ schemaVersion, kind: "comparison", tool, before: {path, startTime, score},
after: {...}, verdict, scoreDelta, counts: {resolved, new, persisting, improved, worsened,
outOfScope}, resolved: [...], new: [...], persisting: [...], moduleChanges: [...] }`.
`--output <file>` writes the result (the extension `.json` / `.md` picks the format).

The verdict is `Improved`, `Regressed`, `Mixed`, or `Unchanged`. **`compare` exits 0
whenever the comparison ran, also when the verdict is `Regressed`**: the exit code says
whether the command worked, the verdict is data. Scripts read it from the JSON
(`... --format json | ConvertFrom-Json | Select-Object -Expand verdict`). An unreadable
session is a usage error (10).

### `gui`

Opens the OmniDiag window (`Show-OmniDiagGui`), the same as `OmniDiag.ps1 -Gui`, and returns
when it closes. Windows only: on other systems it is a usage error (exit 10).

### `version`

Prints `OmniDiag <version>`. With `--format json`:
`{ "schemaVersion": "1.0.0", "kind": "version", "tool": {...}, "reportSchemaVersion": "1.1.0", "powershell": {...} }`.

### `help [command|group]`

Prints the usage overview, one command's usage, or a group's usage. `--help` / `-h` work on
every command.

## Global options

| Option | Meaning |
|---|---|
| `-f`, `--format <fmt>` | `json` (report schema v1), `csv` (findings table), `md` (Markdown), `html`, `pdf`. Repeatable or a comma list. `list` / `repair list` take `json`, `csv`, `md`; `repair run` takes `json`; `compare` takes `text`, `json`, `md`. |
| `-o`, `--output <path>` | Write to a file or a directory instead of stdout. A path that exists as a folder, ends with `\` or `/`, or has no extension is a directory. Without `--format`, a file's extension picks the format (`.json`, `.csv`, `.md`, `.html`, `.pdf`); a directory gets `json` + `html` for `scan` and `report`, and `json` for `list` and `version`. |
| `--verbose` | Record Debug-level entries in the local log file (`OmniDiagData\logs\omnidiag-cli-*.jsonl`). Nothing extra goes to the console. |
| `-q`, `--quiet` | No progress or status lines on stderr. Errors and usage messages are still printed. |
| `--no-color` | Accepted for scripts; router output is already plain text. |
| `-h`, `--help`, `-?`, `/?` | Show help. |
| `--version` | Same as the `version` command. |

Options may appear before or after the command; `--name=value` works too, and `--` ends
option parsing. Scan options (`--group`, `--module`, `--profile`, `--workflow`, `--range`,
`--network-probes`, `--elevated-only`, `--redact`, `--redaction-map`) apply to `scan`,
`<group>`, and (where listed above) `report`; repair options (`--what-if`, `--apply`, `--yes`,
`--allow-without-restore-point`) apply to `repair`; using one with another command is a usage
error.

## Output streams

* **Data** (JSON, CSV, Markdown) goes to **stdout only when `--format` is given without
  `--output`**. Only one format can go to stdout at a time; use `--output <directory>` for
  several. HTML and PDF are always files: without `--output` they go to
  `OmniDiagData\reports` and the path is printed on stderr (not with `--quiet`; use `--output`
  to choose the path when scripting).
* **Progress and status** go to **stderr** (suppressed by `--quiet`). The `repair run --apply`
  confirmation questions also go to stderr (even with `--quiet`), and the answers are read
  from stdin.
* When no data is written to stdout, the human-readable result (tables, the scan summary,
  help, written file paths) goes to stdout.
* JSON on stdout is pure ASCII (non-ASCII characters are `\u`-escaped), so it survives any
  console code page and redirection.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, no warnings or critical findings |
| 1 | Warnings present |
| 2 | Critical findings present (native severity Error or Critical) |
| 3 | Partial: one or more modules failed or timed out |
| 4 | Requested module(s) need elevation and the process isn't elevated |
| 5 | Cancelled |
| 10 | Usage or argument error |
| 11 | Repair failed |
| 12 | Repair succeeded; reboot required |
| 20 | Internal error |

How a scan's code is chosen, first match wins: cancelled (5); every module named with
`--module` (or `-IncludeModule`) was skipped for elevation (4); a module failed (3); any
Error/Critical finding (2); any Warning (1); otherwise 0. Skipped modules don't raise the
code on their own. `--elevated-only` on a non-elevated prompt exits 4 before scanning.
`repair run` and `OmniDiag.ps1 -Repair` return 11 when a repair failed, 12 when one needs a
reboot, and `repair run --apply` returns 4 when every requested repair needs elevation and
the prompt is not elevated. `compare` returns 0 whenever it ran, whatever the verdict.
`--redact` without the redaction module returns 20. The table is also available as data:
`Get-OmniExitCodeTable`.

For `OmniDiag.ps1`, PowerShell itself rejects invalid parameter values (for example an
unknown `-Range`) before the script runs; those exit with 1. Conflicting switches that the
script detects (`-Profile` with `-Workflow`, a plan with `-IncludeModule`, `-FromSession` with
scan selections, `-Gui` on a non-Windows host) exit with 10.

## Examples

```bat
:: What can run, and what needs the network or elevation?
omnidiag list
omnidiag list modules --format csv > modules.csv

:: Triage a user's network problem (with connectivity probes) and keep the evidence
omnidiag network --network-probes --output C:\Cases\1234\

:: Feed another tool
omnidiag scan --group storage,performance --format json --quiet > scan.json
if errorlevel 2 echo Critical findings present

:: A full report for the ticket (no connectivity probes), plus one zip to attach
omnidiag report --output C:\Cases\1234 --bundle

:: The same, safe to send outside the organization
omnidiag report --output C:\Cases\1234\shared --bundle --redact

:: Only the checks that need administrator rights (run from an elevated prompt)
omnidiag scan --elevated-only --format json --output C:\Cases\1234\admin.json

:: Which repairs fit the last scan? What would they do?
omnidiag repair list --from-session last
omnidiag repair run flush-dns-cache restart-print-spooler --what-if

:: Apply them, asking for each one; or unattended (scheduled task, RMM script)
omnidiag repair run flush-dns-cache restart-print-spooler --apply
omnidiag repair run flush-dns-cache --apply --yes
if %ERRORLEVEL%==12 echo Reboot required

:: Did the repair help? Compare the scan before with the scan after
omnidiag compare previous last
omnidiag compare C:\Cases\1234\before.zip last --format md --output C:\Cases\1234\diff.md

:: Open the window
omnidiag gui
```

```powershell
# From PowerShell: the CLI router
$code = Invoke-OmniDiagCli -Arguments @('scan', '--profile', 'HelpDesk', '--format', 'md', '--output', '.\triage.md')

# ... or the cmdlets, which write report-v1-shaped finding objects to the pipeline
Get-OmniDiagGroup | Format-Table Id, ScannerCount, Name
Get-OmniDiagModule -Group network | Format-Table Id, NetworkAccess, RequiresElevation
Get-OmniDiagStorage | Where-Object severity -ne 'Info'
Get-OmniDiagNetwork -NetworkProbes -IncludePassed | Format-Table severity, moduleId, title
$s = Invoke-OmniDiagScan -Group security, updates -AsSession; Export-OmniDiagReport -Session $s -Format Html
Invoke-OmniDiagReport -OutputDirectory C:\Cases\1234 -Bundle
Get-OmniDiagRepair -Session last -RecommendedOnly | Invoke-OmniDiagRepair -WhatIf
Compare-OmniDiagSession -Before previous -After last
```

The full PowerShell reference (every public cmdlet, the pipeline object types, the plugin
SDK, and the deprecated names) is [POWERSHELL.md](POWERSHELL.md).

`Invoke-OmniDiagScan [-Group <id[]>] [-Module <id[]>] [-NetworkProbes] [-MaxParallel <n>]
[-Range <preset>] [-IncludePassed] [-AsSession] [-Config <hashtable>]` and one cmdlet per group
(`Get-OmniDiagSystem`, `-Performance`, `-Services`, `-Startup`, `-Events`, `-Reliability`,
`-Storage`, `-Network`, `-Updates`, `-Security`, `-Extras`) write `OmniDiag.V1.Finding` objects:
the report schema v1 finding (`id`, `moduleId`, `title`, `severity`, `severityNative`, `passed`,
`component`, `evidence`, `likelyCause`, `recommendation`, `confidence`) plus `moduleName`,
`group`, `moduleStatus`, and `skippedReason`. Passing checks are left out unless
`-IncludePassed`; `-AsSession` returns the native session instead. `-NetworkProbes` exists on
`Invoke-OmniDiagScan`, `Get-OmniDiagNetwork`, and `Get-OmniDiagExtras`.

## Classic switches

`OmniDiag.ps1 -Repair` (interactive Repair Center), `-CompareWith`, and `-Gui` keep working;
they use the same engine, audit log, and exit codes as `repair`, `compare`, and `gui`.
