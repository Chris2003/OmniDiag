# omnidiag command line

`omnidiag` is OmniDiag's scriptable command line (0.6.0). It takes GNU-style arguments,
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
`report`, `version`, `help`, a group id such as `network`, or anything else that doesn't start
with `-`) or a `--long` option. A first argument starting with a single `-` goes to
`OmniDiag.ps1`.

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

### `version`

Prints `OmniDiag <version>`. With `--format json`:
`{ "schemaVersion": "1.0.0", "kind": "version", "tool": {...}, "reportSchemaVersion": "1.0.0", "powershell": {...} }`.

### `help [command|group]`

Prints the usage overview, one command's usage, or a group's usage. `--help` / `-h` work on
every command.

## Global options

| Option | Meaning |
|---|---|
| `-f`, `--format <fmt>` | `json` (report schema v1), `csv` (findings table), `md` (Markdown), `html`, `pdf`. Repeatable or a comma list. |
| `-o`, `--output <path>` | Write to a file or a directory instead of stdout. A path that exists as a folder, ends with `\` or `/`, or has no extension is a directory. Without `--format`, a file's extension picks the format (`.json`, `.csv`, `.md`, `.html`, `.pdf`); a directory gets `json` + `html` for `scan` and `report`, and `json` for `list` and `version`. |
| `--verbose` | Record Debug-level entries in the local log file (`OmniDiagData\logs\omnidiag-cli-*.jsonl`). Nothing extra goes to the console. |
| `-q`, `--quiet` | No progress or status lines on stderr. Errors and usage messages are still printed. |
| `--no-color` | Accepted for scripts; router output is already plain text. |
| `-h`, `--help`, `-?`, `/?` | Show help. |
| `--version` | Same as the `version` command. |

Options may appear before or after the command; `--name=value` works too, and `--` ends
option parsing.

## Output streams

* **Data** (JSON, CSV, Markdown) goes to **stdout only when `--format` is given without
  `--output`**. Only one format can go to stdout at a time; use `--output <directory>` for
  several. HTML and PDF are always files: without `--output` they go to
  `OmniDiagData\reports` and the path is printed on stderr (not with `--quiet`; use `--output`
  to choose the path when scripting).
* **Progress and status** go to **stderr** (suppressed by `--quiet`).
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
code on their own. `OmniDiag.ps1 -Repair` returns 11 or 12 when a repair failed or needs a
reboot. The table is also available as data: `Get-OmniExitCodeTable`.

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

:: A full report for the ticket (no connectivity probes)
omnidiag report --output C:\Cases\1234
```

```powershell
# From PowerShell: the CLI router
$code = Invoke-OmniDiagCli -Arguments @('scan', '--profile', 'HelpDesk', '--format', 'md', '--output', '.\triage.md')

# ... or the cmdlets, which write report-v1-shaped finding objects to the pipeline
Get-OmniDiagGroup | Format-Table Id, ScannerCount, Name
Get-OmniDiagModule -Group network | Format-Table Id, NetworkAccess, RequiresElevation
Get-OmniDiagStorage | Where-Object severity -ne 'Info'
Get-OmniDiagNetwork -NetworkProbes -IncludePassed | Format-Table severity, moduleId, title
$s = Invoke-OmniDiagScan -Group security, updates -AsSession; Export-OmniReport -Session $s -Format Html
```

`Invoke-OmniDiagScan [-Group <id[]>] [-Module <id[]>] [-NetworkProbes] [-MaxParallel <n>]
[-Range <preset>] [-IncludePassed] [-AsSession] [-Config <hashtable>]` and one cmdlet per group
(`Get-OmniDiagSystem`, `-Performance`, `-Services`, `-Startup`, `-Events`, `-Reliability`,
`-Storage`, `-Network`, `-Updates`, `-Security`, `-Extras`) write `OmniDiag.V1.Finding` objects:
the report schema v1 finding (`id`, `moduleId`, `title`, `severity`, `severityNative`, `passed`,
`component`, `evidence`, `likelyCause`, `recommendation`, `confidence`) plus `moduleName`,
`group`, `moduleStatus`, and `skippedReason`. Passing checks are left out unless
`-IncludePassed`; `-AsSession` returns the native session instead. `-NetworkProbes` exists on
`Invoke-OmniDiagScan`, `Get-OmniDiagNetwork`, and `Get-OmniDiagExtras`.

## Not yet available

`repair`, `compare`, `gui`, `--redact`, and `--elevated-only` are planned for later phases (see
[ROADMAP.md](ROADMAP.md)). Until then use `OmniDiag.ps1 -Repair`, `-CompareWith`, and `-Gui`.
