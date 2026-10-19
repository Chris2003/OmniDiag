<div align="center">

# OmniDiag

### One Tool. Complete Diagnostics.

A local-only, open-source Windows diagnostics tool for IT technicians, help desks,
sysadmins, and power users: a GUI, a scriptable command line, and PowerShell cmdlets over
58 read-only scanners, with confirmation-gated repairs.

[![CI](https://github.com/Chris2003/OmniDiag/actions/workflows/ci.yml/badge.svg)](https://github.com/Chris2003/OmniDiag/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE.svg)](#requirements)

</div>

---

## What it is

Diagnosing a sick Windows machine usually means jumping between Event Viewer, `ipconfig`,
Device Manager, `Get-PhysicalDisk`, `sfc`, `powercfg`, and a dozen other tools, then
stitching the results together in your head. OmniDiag runs those checks from one place,
interprets the results, and tells you the **likely cause** and the **recommended next step**,
not just raw output. Every finding has a severity, a stable id, evidence, and a
recommendation, and the whole run gets a 0-100 health score.

You can use it three ways, all over the same engine:

* **GUI**: a WPF window with a dashboard, per-group drill-down, a findings browser,
  scanner toggles, a Repair Center, and optional local AI analysis.
* **Command line**: `omnidiag scan`, `omnidiag report`, `omnidiag repair`, ... with JSON,
  CSV, Markdown, HTML, and PDF output and documented exit codes.
* **PowerShell**: `Invoke-OmniDiagScan`, `Get-OmniDiagNetwork`, `Export-OmniDiagReport`, ...
  return objects you can filter, export, and automate.

## Principles

* **Local-only.** No telemetry, no accounts, no cloud. A default scan contacts no other
  machine (CI proves it); connectivity probes run only when you ask for them.
* **Read-only by default.** Scanning changes nothing. Repairs are separate, always opt-in,
  confirmed per repair, have a dry run, and are written to a local audit log.
* **Scriptable.** Stable JSON schema, documented exit codes, data on stdout and progress
  on stderr, and cmdlets that return objects.
* **Least privilege.** Runs as a standard user; checks that need administrator rights are
  skipped with a structured reason instead of failing, and CI runs the suite as a non-admin
  account.
* **Portable.** No installation required: run from a folder or a USB stick, and everything
  OmniDiag writes stays in an `OmniDiagData` folder next to the tool.

## Screenshots

| Dashboard (light) | Dashboard (dark) |
|---|---|
| ![OmniDiag dashboard, light theme: health score, system information, top recommendations, module results](docs/images/dashboard-light.png) | ![OmniDiag dashboard, dark theme](docs/images/dashboard-dark.png) |

| Groups | All Findings | Repair Center |
|---|---|---|
| ![Module groups with status, score, worst severity, and counts](docs/images/groups.png) | ![All findings with filter and detail panel](docs/images/findings.png) | ![Repair Center with recommended repairs and dry run](docs/images/repair.png) |

The screenshots show a synthetic demo session (host `DEMO-PC`), rendered from the real
window by `build/New-Screenshots.ps1`.

## Install

Pick one. All of them install the same files; none needs a machine-wide execution-policy
change.

* **Portable zip.** Download `OmniDiag-<version>-portable.zip` from
  [Releases](https://github.com/Chris2003/OmniDiag/releases/latest), check it against the
  published SHA-256, and extract it anywhere. See [PORTABLE.md](PORTABLE.md).
* **MSI.** Download the `.msi` from [Releases](https://github.com/Chris2003/OmniDiag/releases/latest)
  for a managed install. See [docs/INSTALLER.md](docs/INSTALLER.md).
* **winget.** `winget install Chris2003.OmniDiag` (available once the package has been
  accepted into the winget community repository).
* **Install script.** Installs for the current user and opens the GUI:

  ```powershell
  $installer = Join-Path $env:TEMP 'Install-OmniDiag.ps1'
  Invoke-WebRequest 'https://github.com/Chris2003/OmniDiag/releases/latest/download/install.ps1' -OutFile $installer
  notepad $installer          # review it first
  Unblock-File $installer
  & $installer
  ```

  By default it installs the latest release and verifies the zip against that release's
  `SHA256SUMS`, refusing to install on any mismatch. The script downloads and runs code
  with your rights: review it, and for managed deployment pin a release with `-Ref` and
  pass `-ExpectedSha256` (see [SECURITY.md](SECURITY.md)).

How releases are built, signed, and verified: [docs/RELEASING.md](docs/RELEASING.md).

## Requirements

* Windows 10 or 11, or Windows Server 2019 or later; x64 or ARM64.
* Windows PowerShell 5.1 (built in) or PowerShell 7+.
* Administrator rights are optional. Without them, the few elevation-only checks and
  repairs are skipped and reported as such; everything else runs.

Which editions and hosts are verified, and how: [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Quick start

From the extracted portable folder (or the install folder):

* **GUI**: double-click `OmniDiag-GUI.cmd` (or run `omnidiag gui`).
* **Console scan**: double-click `OmniDiag.cmd`.
* **A report for a ticket**: in a command prompt in that folder,

  ```bat
  OmniDiag.cmd report --output C:\Cases\1234 --bundle
  ```

  writes an HTML report, a JSON report (schema v1), and one `.zip` to attach.

`OmniDiag.cmd` is the `omnidiag` command: with the folder on `PATH` (or as the current
directory), type `omnidiag`. The launchers bypass the execution policy for their own process only, start
PowerShell from its fixed install path, and keep logs, reports, sessions, and caches in
`OmniDiagData` next to the tool.

## Command line

```bat
:: What can run, and what needs the network or elevation?
omnidiag list
omnidiag list groups --format json

:: Scan a group or a single scanner
omnidiag network
omnidiag scan --group storage,performance --format json --quiet > scan.json
omnidiag scan --module storage.disk --format md --output disk.md
omnidiag scan --profile HelpDesk --format md --output triage.md

:: Include the opt-in connectivity probes
omnidiag network --network-probes --output C:\Cases\1234\

:: A report that is safe to share outside the organization
omnidiag report --output C:\Cases\1234\shared --bundle --redact

:: Repairs: list what fits the last scan, preview, then apply with a y/N prompt each
omnidiag repair list --from-session last
omnidiag repair run flush-dns-cache --what-if
omnidiag repair run flush-dns-cache --apply

:: Did it help? Compare the scan before with the scan after
omnidiag compare previous last

omnidiag version
omnidiag help scan
```

Every command, option, and output rule: [docs/CLI.md](docs/CLI.md). The classic
`OmniDiag.ps1` switches (`-Profile`, `-Workflow`, `-Report`, `-Repair`, `-Gui`, `-FromSession`,
`-CompareWith`, `-AiAnalysis`, ...) keep working with the same exit codes; see the
[Technician Guide](docs/TECHNICIAN_GUIDE.md).

### Exit codes

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

`compare` exits 0 whenever it ran; the verdict (`Improved`, `Regressed`, ...) is data. The
table is also available as `Get-OmniExitCodeTable`.

## PowerShell

```powershell
Import-Module .\src\OmniDiag.psd1            # from the tool folder

Get-OmniDiagGroup | Format-Table Id, ScannerCount, Name
Get-OmniDiagModule -Group network | Format-Table Id, NetworkAccess, RequiresElevation

# Findings as objects (passing checks only with -IncludePassed)
Invoke-OmniDiagScan | Format-Table severity, moduleId, title
Get-OmniDiagStorage -IncludePassed | Format-Table passed, severity, title
Get-OmniDiagNetwork -NetworkProbes

# Reports
Invoke-OmniDiagReport -OutputDirectory C:\Cases\1234 -Bundle
Invoke-OmniDiagScan -Group security, updates -AsSession | Export-OmniDiagReport -Format Html, Json -Redact

# Saved sessions, comparison, repairs
Compare-OmniDiagSession -Before previous -After last
Get-OmniDiagRepair -Session last -RecommendedOnly | Invoke-OmniDiagRepair -WhatIf

Show-OmniDiagGui
```

Every public cmdlet, the objects on the pipeline, the plugin SDK, and the deprecated pre-1.0
names: [docs/POWERSHELL.md](docs/POWERSHELL.md).

## Module groups

58 scanners in 11 groups. Each page lists every scanner with its id, what it checks, its
elevation needs, its network access, and the findings it can emit.

| Group | Id | Scanners | Cmdlet | Page |
|---|---|---:|---|---|
| System | `system` | 2 | `Get-OmniDiagSystem` | [docs/modules/system.md](docs/modules/system.md) |
| Performance | `performance` | 5 | `Get-OmniDiagPerformance` | [docs/modules/performance.md](docs/modules/performance.md) |
| Services and drivers | `services` | 2 | `Get-OmniDiagServices` | [docs/modules/services.md](docs/modules/services.md) |
| Startup and persistence | `startup` | 5 | `Get-OmniDiagStartup` | [docs/modules/startup.md](docs/modules/startup.md) |
| Event logs | `events` | 2 | `Get-OmniDiagEvents` | [docs/modules/events.md](docs/modules/events.md) |
| Reliability | `reliability` | 3 | `Get-OmniDiagReliability` | [docs/modules/reliability.md](docs/modules/reliability.md) |
| Storage | `storage` | 4 | `Get-OmniDiagStorage` | [docs/modules/storage.md](docs/modules/storage.md) |
| Network | `network` | 10 | `Get-OmniDiagNetwork` | [docs/modules/network.md](docs/modules/network.md) |
| Windows Update and health | `updates` | 5 | `Get-OmniDiagUpdates` | [docs/modules/updates.md](docs/modules/updates.md) |
| Security | `security` | 6 | `Get-OmniDiagSecurity` | [docs/modules/security.md](docs/modules/security.md) |
| Extras (hardware, apps, identity, cloud) | `extras` | 14 | `Get-OmniDiagExtras` | [docs/modules/extras.md](docs/modules/extras.md) |

`omnidiag list modules` (or `Get-OmniDiagModule`) shows the live list on your machine.

## Security and privacy

* **Nothing leaves the machine by default.** Five scanners have a connectivity probe
  (gateway ping and name resolution, DNS resolvers, the domain secure channel, Entra ID
  device status, and local Administrators name lookups on joined devices). They run only with
  `--network-probes` / `-NetworkProbes` (a checkbox in the GUI); without it they do their
  local checks and say the probe was not run. CI runs a default scan under Windows
  Filtering Platform auditing and fails on any outbound connection or DNS query.
* **Reports describe the machine.** They can contain user, host, and domain names, paths,
  and addresses. Review them before sharing, or export with `--redact` / `-Redact`, which
  replaces identifiers with stable pseudonyms (`HOST-1`, `USER-1`, `IP-1`) in every format
  and file name ([docs/REDACTION.md](docs/REDACTION.md)).
* **Secrets are masked.** Password-, token-, and key-looking values are replaced with
  `[REDACTED]` in findings, metrics, and logs (heuristic; treat reports as sensitive).
* **Local AI is optional and local.** The assistant talks only to an Ollama endpoint you
  configure (loopback by default) and sends redacted evidence
  ([docs/OLLAMA.md](docs/OLLAMA.md)).
* **Hardened I/O.** Output paths are canonicalized, report-package import is guarded against
  zip-slip and zip bombs, session import is validated and fuzzed, and report content is
  encoded for HTML, Markdown, CSV, and PDF ([docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md)).

Report vulnerabilities privately: [SECURITY.md](SECURITY.md).

## Documentation

| Topic | Page |
|---|---|
| Documentation index | [docs/README.md](docs/README.md) |
| Role profiles and task workflows | [docs/TECHNICIAN_GUIDE.md](docs/TECHNICIAN_GUIDE.md) |
| Command line | [docs/CLI.md](docs/CLI.md) |
| PowerShell cmdlets | [docs/POWERSHELL.md](docs/POWERSHELL.md) |
| GUI | [docs/GUI.md](docs/GUI.md) |
| Module groups and scanners | [docs/modules/README.md](docs/modules/README.md) |
| Report schema | [docs/SCHEMA.md](docs/SCHEMA.md) |
| Redaction | [docs/REDACTION.md](docs/REDACTION.md) |
| Local AI (Ollama) | [docs/OLLAMA.md](docs/OLLAMA.md) |
| Portable use | [PORTABLE.md](PORTABLE.md) |
| Installer (MSI, winget) | [docs/INSTALLER.md](docs/INSTALLER.md) |
| Releasing and verifying releases | [docs/RELEASING.md](docs/RELEASING.md) |
| Architecture and plugin contract | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Security review | [docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md) |
| Changelog | [CHANGELOG.md](CHANGELOG.md) |

## Contributing

Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md) for development setup,
tests, lint, the coverage gate, and how to add a scanner or a repair. This project follows
the [Contributor Covenant](CODE_OF_CONDUCT.md).

## Authorship and AI disclosure

OmniDiag was built roughly **50% with AI assistance** and **50% by me (Chris B,
[@Chris2003](https://github.com/Chris2003)) and other collaborators who worked off
platform** (outside GitHub, so they don't show in the commit history). Design decisions,
testing on real Windows hosts, and review were done by people; AI tools helped write
code, tests, and documentation. See [CREDITS.md](CREDITS.md) for details.

## License

[MIT](LICENSE) (c) OmniDiag Contributors
