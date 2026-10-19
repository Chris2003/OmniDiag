# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | Yes: security fixes are released as 1.0.x patch releases |
| < 1.0 (0.x development milestones) | No: upgrade to the latest 1.0.x release |

Security fixes land on `main` first and ship in the next 1.0.x release. Pin a released tag
(or the release's checksums) for repeatable deployments.

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Report privately through
[GitHub Security Advisories](https://github.com/Chris2003/OmniDiag/security/advisories/new)
(Security > Report a vulnerability). Include:

- a description of the issue and its impact;
- steps to reproduce or a proof of concept (a crafted report file, session, or zip is
  welcome; please don't include real host data);
- the affected version (`omnidiag version`) or commit, the Windows version, and whether you
  used Windows PowerShell 5.1 or PowerShell 7.

We aim to acknowledge reports within 5 business days and to give a remediation timeline
after triage. Coordinated disclosure is appreciated; we credit reporters in the release
notes unless you prefer otherwise.

## Scope

In scope (examples):

- **Data leaving the machine.** Any network traffic in a default run (connectivity probes
  are opt-in with `--network-probes` / `-NetworkProbes`), or anything sent to the optional
  local Ollama endpoint that should have been redacted.
- **Report and redaction leaks.** Secrets (passwords, tokens, recovery keys) reaching a
  report, the run log, or a saved session; identifiers surviving `--redact` / `-Redact`.
- **Unsafe file handling.** Writing outside the chosen output folder, path or device-name
  tricks in `--output`, zip-slip or zip bombs in report-package import, crashes or code
  execution from a crafted session or report file.
- **Content injection.** Script or markup injection in the HTML, Markdown, or PDF reports;
  CSV formula injection; terminal escape sequences reaching the console.
- **Privilege and execution.** Executable planting or `PATH` / current-folder hijacking in
  the launchers, the installer, or a repair; a repair that runs without `--apply` or
  confirmation, ignores the dry run, or skips its restore-point or backup gate.
- **Installer and release integrity.** `install.ps1`, the MSI, or release artifacts and their
  checksums or signatures (see [docs/RELEASING.md](docs/RELEASING.md) and
  [docs/INSTALLER.md](docs/INSTALLER.md)).

Out of scope:

- What an administrator can already do: OmniDiag runs with the rights of whoever starts it;
  running it elevated gives it broad read access by design.
- A host that is already compromised, or a user-writable folder placed early in the machine
  `PATH` (a host misconfiguration; see the residual risks in the security review).
- Findings that are simply inaccurate (please open a normal issue), and third-party tools
  OmniDiag reads from (report those upstream).

## Security review

The Phase 4 security review records each item (export paths, package import, launcher
executable resolution, temporary files, secret scrubbing, report encoding, redaction,
session import fuzzing, Ollama prompts and output) with its finding, fix, test, and the
residual risks we accept: [docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md).

## Privacy model

OmniDiag is **local-only by design**:

- No telemetry, no ads, no analytics, no accounts.
- A default scan contacts no other machine. Five scanners have connectivity probes that run
  only when you ask (`--network-probes`; see [docs/CLI.md](docs/CLI.md)); CI proves a default scan makes no outbound
  connection or DNS query (`build/Test-NoNetworkRuntime.ps1`).
- Reports are written only where you choose. They can contain user names, device names,
  file paths, domains, and addresses: **review reports before sharing them**, or export with
  `--redact` (see [docs/REDACTION.md](docs/REDACTION.md)).
- Secret-looking values are masked in findings, metrics, and logs, but the patterns are
  heuristic; treat every report as sensitive.
- The optional Local AI feature talks only to an Ollama endpoint you configure (loopback by
  default) and sends redacted evidence ([docs/OLLAMA.md](docs/OLLAMA.md)).

OmniDiag never reaches out to manage other machines. Remote execution (WinRM / PowerShell
Remoting) is intentionally not a feature; fleet use is served by running the portable build
on each machine and collecting the reports.

## Install trust model

`install.ps1` downloads and runs code with the current user's rights. Review it first, and
for managed deployment pin it to a release (download it from the release, or pass `-Ref`
with a release tag) and supply `-ExpectedSha256`. The installer validates the archive's
entry names and sizes before extracting, installs only an allowlist of files, clears
Mark-of-the-Web only after validation, and keeps the previous installation as a backup.

## Repairs

Repairs change system state and are always opt-in: nothing runs without `--apply` (CLI),
confirmation (cmdlets, GUI, console), and every repair has a dry run. System-altering repairs
run only after a System Restore point is verified (a new one, or one from the last 24
hours), unless you pass `--allow-without-restore-point`. The registry cleanup removes
nothing unless its `.reg` backup succeeded. Every applied step is written to a local audit
log (`OmniDiagData\logs\repair-audit.jsonl`).
