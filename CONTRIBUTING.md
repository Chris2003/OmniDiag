# Contributing to OmniDiag

Thanks for your interest in improving OmniDiag! This guide covers how to set up,
test, and contribute, and how to add a diagnostic scanner or a repair.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating you agree to uphold it.

## Getting started

```powershell
git clone https://github.com/Chris2003/OmniDiag.git
cd OmniDiag
Import-Module .\src\OmniDiag.psd1 -Force
.\OmniDiag.ps1                 # classic console scan
.\OmniDiag.cmd list            # the omnidiag CLI (docs/CLI.md)
.\OmniDiag.ps1 -Gui            # the WPF window (docs/GUI.md)
```

Requirements: Windows 10 / 11 or Windows Server 2019+ (x64 or ARM64), Windows PowerShell 5.1
or PowerShell 7+, Pester 5.5+ for tests, and PSScriptAnalyzer for lint. Code that does not
touch Windows data sources (models, redaction, reporting, the CLI router, the docs tests) also
runs under PowerShell 7 on Linux, which is how the Ubuntu CI leg runs it.

## Development workflow

1. Create a branch: `git checkout -b feature/my-change`.
2. Make your change with tests.
3. Run `build/Invoke-Lint.ps1` and `build/Invoke-Tests.ps1` locally (see below). Both must pass.
4. Update the docs that describe what you changed (a scanner's group page under
   `docs/modules/`, `docs/CLI.md`, `docs/POWERSHELL.md`, `docs/GUI.md`).
   `Tests/Docs.Modules.Tests.ps1` fails when a scanner is missing from its group page or a
   relative link in the Markdown files points nowhere.
5. Update `CHANGELOG.md` under the topmost (unreleased) version.
6. Open a pull request describing the change and how you verified it. CI is the reference
   run: Windows PowerShell 5.1, PowerShell 7, Windows 11 ARM64, a standard user, and Ubuntu.

## Linting & tests

```powershell
# One-time setup
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser

# Lint: 0 errors required
.\build\Invoke-Lint.ps1
.\build\Invoke-Lint.ps1 -FailOnWarning        # stricter, optional

# Tests
.\build\Invoke-Tests.ps1
.\build\Invoke-Tests.ps1 -Path .\Tests\NoNetwork.Tests.ps1 -Verbosity Detailed
.\build\Invoke-Tests.ps1 -Coverage -CoverageTarget 80   # coverage report
```

Both scripts run on Windows PowerShell 5.1 and PowerShell 7+, and exit non-zero on failure.

**`build/Invoke-Tests.ps1`** runs Pester (5.5+) over `Tests/` through `New-PesterConfiguration`.
It points `OMNIDIAG_DATA` at a fresh temporary folder for the run, so tests never write
`OmniDiagData` into your checkout; the folder is deleted afterwards (`-KeepData` keeps it).
Use it instead of a bare `Invoke-Pester`. `-TestResultPath` writes NUnit XML.

**Coverage.** `-Coverage` measures `src/Core`, `src/Repair`, and `src/Reporting`, writes a
JaCoCo report (`-CoverageOutputPath`, default `coverage.xml`, git-ignored), and prints the
percentage per folder. `-CoverageTarget` (overall) and `-CoverageTargets` (per folder, e.g.
`@{ 'src/Core' = 80; 'src/Repair' = 80 }`, or `'src/Core=80,src/Repair=80'` from `pwsh -File`)
are report-only unless `-EnforceCoverage` is given; then any missed target fails the run. CI
enforces Core, Repair, and overall at 80% on the Windows pwsh 7 leg (Phase 4) and writes the
table to the job summary and `coverage-summary.json`. Windows-only code paths count as missed on
Linux, so compare Windows numbers.

**`build/Invoke-Lint.ps1`** runs PSScriptAnalyzer with
[`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1) over `src`, `OmniDiag.ps1`,
`install.ps1`, and `build`. It prints counts by severity and by rule and lists every error and
warning. All default rules are on. `PSProvideCommentHelp` stays at Information (advisory).
`PSAvoidUsingWriteHost` is ignored only for the console presentation layers (`src/Cli`,
`src/UI`, `OmniDiag.ps1`, `install.ps1`, `build/`), because the settings file can't scope a
rule by path. Errors fail the build. Warnings are tracked against a baseline; don't add new
ones. Point the VS Code PowerShell extension at the same settings file
(`powershell.scriptAnalysis.settingsPath`).

**CI** (`.github/workflows/ci.yml`) runs on every push to `main` and every pull request:

- lint
- tests on Windows pwsh 7, Windows PowerShell 5.1, Ubuntu pwsh, and Windows 11 ARM64
  (all four block merges)
- the coverage gate on the Windows pwsh leg (Core, Repair, overall >= 80%; job summary and
  `test-results` artifact), plus a check that an elevated `report` has the elevation-only data
- a standard-user leg (`standard-user` job): the suite, `report`, and `scan` run as a throwaway
  local non-admin account (`build/Invoke-AsStandardUser.ps1`) and are validated with
  `build/Test-PrivilegeReport.ps1` against an elevated report from the same machine
- an OS-info line on every Windows leg (edition and build, for `docs/VERIFICATION.md`)
- the runtime no-network test and the performance measurement (see below)
- the portable package build (zip and `.sha256` uploaded as an artifact)
- non-blocking report jobs: GUI startup timing (`gui-startup`, `build/Measure-GuiStartup.ps1`)
  and GUI screenshots (`screenshots`, `build/New-Screenshots.ps1`; see below)
- dependency review on pull requests

Actions are pinned to commit SHAs, and Dependabot proposes updates weekly. Releases are built
by a separate workflow; see [docs/RELEASING.md](docs/RELEASING.md) and, for the MSI and winget
package, [docs/INSTALLER.md](docs/INSTALLER.md).

### Standard-user runs

The blocking `standard-user` job proves OmniDiag works without administrator rights:
`build/Invoke-AsStandardUser.ps1` (elevated; Windows) creates a throwaway Users-only local
account with a random in-memory password, copies the repository to a work folder it can
write, runs each `-Step` (the test suite, `omnidiag report`, `omnidiag scan`; see the job in
`.github/workflows/ci.yml` for the step format) as that account, refuses to run a step
elevated, and deletes the account afterwards. `build/Test-PrivilegeReport.ps1` then checks
exit codes, the report schema, and the structured elevation skips against an elevated
report from the same machine.

Code that needs elevation must declare it (`RequiresAdmin = $true` in the manifest, or a
structured `SkippedReason = RequiresElevation` / partial result for the elevated part) and
never fail for a standard user.

### Screenshots

`build/New-Screenshots.ps1` renders the real window with a synthetic demo session (host
`DEMO-PC`; nothing from the machine it runs on) and writes `dashboard-light.png`,
`dashboard-dark.png`, `groups.png`, `group-network.png`, `findings.png`, and `repair.png` at
1280x800. CI runs it in the `screenshots` job and uploads the files as the `screenshots`
artifact; a maintainer commits them to `docs/images/` when the GUI changes visibly.

```powershell
.\build\New-Screenshots.ps1          # writes docs\images\*.png (needs a Windows desktop session)
```

### Runtime no-network test and performance measurement

Two scripts in `build/` back the Phase 2 gates. Both write a JSON and a Markdown summary
(and append the Markdown to the GitHub job summary when run in CI).

**`build/Test-NoNetworkRuntime.ps1`** (Windows, elevated; CI job `no-network`) proves a
default scan makes no outbound network attempt. It enables Windows Filtering Platform
connection auditing and process-creation auditing, turns on the DNS-Client operational
log, and adds outbound firewall block rules for `pwsh.exe` / `powershell.exe`. It then runs
a positive control (a TCP connect to `1.1.1.1:443` plus a name lookup, which must be
detected), `omnidiag scan --format json`, and `omnidiag report`, and fails on any outbound
connection (allowed or blocked, loopback excluded) or DNS query from their process trees.
When the CLI supports `--network-probes`, an extra opt-in run is reported for information.
Everything is restored afterwards. Exit codes: 0 pass, 1 violation or undetected control,
2 could not run (not Windows, not elevated, setup error).

```powershell
pwsh -NoProfile -File .\build\Test-NoNetworkRuntime.ps1     # elevated
```

**`build/Measure-ScanPerformance.ps1`** (any OS; CI job `performance`, soft gate) runs the
full default scan `-Runs` times (default 3) in fresh child processes, plus `omnidiag version`
for startup cost, and reports per-run and median wall time and the slowest modules (from
the JSON report's `durationMs`). `-Enforce` makes a median over `-BudgetSeconds` (default
60) exit 1.

```powershell
.\build\Measure-ScanPerformance.ps1
.\build\Measure-ScanPerformance.ps1 -Runs 5 -Enforce
```

### No-network rule and allowlist

OmniDiag is local-only. `Tests/NoNetwork.Tests.ps1` parses every script under `src` (and
`OmniDiag.ps1`) and fails on any network-capable API outside its allowlist. That covers
`Invoke-WebRequest`, `Invoke-RestMethod`, `Test-Connection`, `Test-NetConnection`,
`Resolve-DnsName`, `Test-ComputerSecureChannel`, `Start-BitsTransfer`, remoting/CIM sessions,
`Invoke-Command -ComputerName`, `System.Net.WebClient`, `HttpClient`, sockets, `Ping`, `Dns`,
and `WebRequest`. Outside `src`, only `install.ps1` may download.

To add a network-capable API, you need all of these:

1. An allowlist entry at the top of `Tests/NoNetwork.Tests.ps1`: the file's repo-relative path,
   the API as the detector reports it, and a reason.
2. The plugin's manifest declares the matching `NetworkAccess` (`LocalNetwork` or `Internet`).
3. The network call runs only when `Test-OmniNetworkProbeEnabled -Context $Context` is true
   (connectivity probes are opt-in: `--network-probes`); otherwise the scanner does its local
   work and adds `New-OmniProbeSkippedFinding`. Put the call in a small private function so
   tests can mock it (see `Tests/Modules.NetworkProbes.Tests.ps1`), and take targets from
   `Get-OmniProbeTarget`.
4. The pull request has the **NetworkAccess** label.
5. A project owner approves it.

The test also fails on stale allowlist entries, so remove the entry when the usage goes away.

## Adding a diagnostic module

1. Create `src/Modules/MyScanner.psm1`.
2. Implement the two contract functions (`Get-OmniModuleManifest`,
   `Invoke-OmniModuleScan`) — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the
   full template and any existing scanner (e.g. `System.psm1`, `Cpu.psm1`) as a reference.
3. `Tests/Modules.All.Tests.ps1` discovers every scanner and runs it through the engine
   automatically, so a new scanner is covered on discovery/contract/clean-execution with no
   extra work. Add a dedicated `Tests/Modules.<Name>.Tests.ps1` only for scanner-specific
   behavior worth asserting.
4. List it in its group's `Tests/data/scanner-groups/<group>.psd1` (the contract test fails
   until every scanner is listed in exactly one file) and in its group's page under
   [docs/modules](docs/modules/README.md).
5. Declare `Id` (`<group>.<kebab-name>`), `Group`, `NetworkAccess`, `RequiresAdmin`, and a
   one-line `Description` in the manifest. Give findings stable `-Id`s that never contain
   live values (counts, sizes, percentages), so before/after comparisons can match them.
6. That's it: the engine discovers it automatically. **Do not modify the core** to
   add a scanner.

## Adding a repair

Repairs live in `src/Repairs/<Name>.psm1` and implement `Get-OmniRepairManifest` and
`Invoke-OmniRepairAction` (template and fields in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); `FlushDns.psm1` is the smallest example).

1. Manifest: `Name`, `Id` (`repair.<kebab-name>`), `Category`, `Description`, `Risk`
   (`Safe`, `Moderate`, `Destructive`), `RequiresAdmin`, `RestorePoint` (system-altering
   repairs ask for one), `RebootHint`, `NetworkAccess`, and `AppliesTo` (finding Id or
   Component substrings that make the repair "recommended" for a scan), or implement
   `Test-OmniRepairApplicable -Session` for finer logic.
2. Make every change inside `Invoke-OmniRepairStep -Result $r -Context $Context -Description
   '...' -Action { ... }`. The step runner honors the dry run (`--what-if`, `-WhatIf`, the
   GUI's Dry run), records output for the audit log, and catches failures. Never change the
   system outside a step.
3. Repairs are always opt-in and confirmed; don't add a path that runs one without `--apply`
   or a confirmation. Start external programs by full path (`$env:SystemRoot\...`), never
   through `PATH` (docs/SECURITY-REVIEW.md, item 3).
4. Tests: `Tests/Repairs.Catalog.Tests.ps1` validates every repair's manifest and dry-runs it
   automatically; add behavior tests with harmless fakes (see
   `Tests/Repair.EngineBranches.Tests.ps1`). List the repair in docs/CLI.md examples or
   docs/POWERSHELL.md only when its usage differs from the others.

### Module guidelines

- **Diagnose, don't dump.** Every finding should carry a severity and, where
  possible, a `LikelyCause`, `Confidence`, and `Recommendation`.
- **Fail soft.** Wrap data collection in `try/catch`; log failures via
  `$Context.Logger` and continue. Never let one query abort the module.
- **Respect privacy.** Don't transmit anything. Be mindful that findings may contain
  sensitive values.
- **Honor cancellation.** For long loops, check `$Context.CancellationToken.IsCancellationRequested`.
- **Declare admin needs.** Set `RequiresAdmin = $true` if you read an elevated-only
  source; the engine will skip gracefully when not elevated.
- **Be runspace-safe.** Scanners run in parallel worker runspaces: keep state inside
  `Invoke-OmniModuleScan`, treat `$Context` as read-only data, and log through
  `$Context.Logger`. Stay within `TimeoutSec` (default 60 s; raise it in the manifest if the
  scanner is legitimately slower). Set `Parallel = $false` only if the scanner must not run
  next to others (Benchmark measures the machine), and `SupportedPlatforms` /
  `SupportedArchitectures` if it can't run on some hosts (skipped as `NotSupported`).

## Style

- `Set-StrictMode -Version Latest` at the top of every file.
- Comment-based help on public functions; XML/comment docs on non-trivial logic.
- Approved PowerShell verbs (`Get-`, `New-`, `Invoke-`, ...) and `Verb-OmniNoun` naming
  for shared functions. Public cmdlets are `Verb-OmniDiag<Noun>`, listed in
  `FunctionsToExport` (`src/OmniDiag.psd1`) and documented in `docs/POWERSHELL.md`.
- Code runs on both Windows PowerShell 5.1 and PowerShell 7: no `??`, `?.`, ternaries, or
  `ForEach-Object -Parallel`, and wrap results in `@()` where 5.1 unrolls one-item arrays.
- No `Write-Host` outside the `Cli`/`UI` presentation layers.
- Source files are ASCII-only, saved as UTF-8 without a BOM. Windows PowerShell 5.1 reads a
  BOM-less file as ANSI, so write a non-ASCII character as `[char]0x....` or a regex `\uXXXX`
  escape, never as a literal.
