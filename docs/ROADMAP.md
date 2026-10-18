# OmniDiag v1.0 roadmap

From 0.4.1 to a release-ready 1.0. The starting point is in [STATUS.md](STATUS.md); the target
design is the "v1.0 target" section of [ARCHITECTURE.md](ARCHITECTURE.md). The version history
of earlier milestones stays in the root [ROADMAP.md](../ROADMAP.md).

**Stack:** keep PowerShell (Windows PowerShell 5.1 + PowerShell 7) and WPF. Nothing in the v1.0
specification needs a rewrite, and the existing 49 scanners, 11 repairs, reporting, GUI, and
tests carry over. See ARCHITECTURE.md for how each requirement is met in this stack.

Each phase ends with green CI, an updated STATUS.md, and a summary of what was done, test
results, and open risks. Nothing is marked complete without passing tests. Anything that can't
be checked on a hosted runner is listed as unverified.

## Phase 1 — Foundation

**Deliverables**
- **Module contract v1.** Every scanner and repair manifest gets a stable `Id`, a `Group`,
  `RequiresElevation` (alias of `RequiresAdmin`), `NetworkAccess` (`None` / `LocalNetwork` /
  `Internet`), `TimeoutSec`, and `SupportedArchitectures`. Old manifests still load with derived
  defaults.
- **Finding/report schema v1.** `schemas/omnidiag-report.v1.json` (JSON Schema 2020-12) with
  `schemaVersion`; a v1 projection of the session (`ConvertTo-OmniReportV1`) that maps the native
  severities to the spec's Info / Warning / Critical. The internal five-level scale stays.
- **Exit codes.** The table in [CLI.md](CLI.md) (data in `src/Core/ExitCodes.psm1`), used by every command and propagated by the
  `.cmd` launchers.
- **CLI router.** `omnidiag.cmd` + `src/Cli/Router.psm1` with `list`, `scan`, `report`,
  `version`, global `--format`, `--output`, `--verbose`, `--quiet`. `OmniDiag.ps1` keeps its
  switches as a compatibility front end.
- **Logging.** Local JSONL only (already in place); `--verbose` raises the level to Debug.
- **CI.** PSScriptAnalyzer with a settings file (0 errors, agreed warning baseline), coverage
  report, the static no-network test, package job uploading the portable zip as an artifact,
  Actions pinned to SHAs, Dependabot for Actions.
- **Hygiene.** Remove the committed `dist/` artifact, fix the defects listed in STATUS.md
  (BOM/regex on 5.1, unused PDF parameters, `$matches`, dead code, stale comments), and stop
  tests writing into the repo.

**Acceptance criteria**
- A contract test proves every plugin has a unique `Id`, a `Group`, and a `NetworkAccess` value.
- `omnidiag list --format json` and `omnidiag scan --format json` validate against the v1 schema
  in CI; golden-file tests cover the v1 projection.
- Each documented exit code is produced by at least one test.
- PSScriptAnalyzer reports 0 errors in CI; coverage is reported for Core, Repair, Reporting.
- The static no-network test fails on any network API outside the allowlist.
- CI green on Windows pwsh 7, Windows PowerShell 5.1, and Ubuntu.

## Phase 2 — Diagnostic modules

**Deliverables**
- Map the 49 scanners into the ten v1.0 groups; `omnidiag <group>` runs a group, `--module <id>`
  runs one scanner.
- Make connectivity probes opt-in (`--network-probes`, configurable targets) pending decision 1;
  a skipped probe produces an Info finding saying how to run it.
- Fill the missing items: handle counts; unsigned and third-party drivers (signature status via
  `Win32_PnPSignedDriver` / `Get-AuthenticodeSignature` on the driver file); services as
  persistence; Reliability Monitor records (`Win32_ReliabilityRecords`); minidump inventory
  (`%SystemRoot%\Minidump`, `MEMORY.DMP`); TRIM status; routes (`Get-NetRoute`); listening ports
  with owning process (`Get-NetTCPConnection` / `Get-NetUDPEndpoint` + process lookup); failed
  Windows updates (Windows Update Agent COM history); local administrators
  (`Get-LocalGroupMember` with a fallback for domain-member resolution failures).
- Complete the partial items (service start types, driver/service failures, startup folders,
  scheduled-task persistence, last update install).
- Replace tool-output parsing where a documented API exists; keep the rest behind
  language-independent parsing and document why.
- Move SFC out of the Windows Health scanner (scanners never change the system).
- Runspace-pool engine with per-module timeouts; structured `Skipped (requires elevation)`
  results; ARM64 audit (missing data reported as "not available", never as a failure).
- Each group gets a CLI command, a `Get-OmniDiag<Group>` cmdlet, tests, and a docs page.

**Acceptance criteria**
- Every sub-item in the STATUS.md coverage table is ✅ or has a documented reason.
- A default scan makes no outbound connection (runtime test on the Windows runner: outbound
  firewall block on the PowerShell executables plus a DNS-client/TCP check), with only the
  allowlisted opt-in features excluded.
- A full scan finishes in under 60 s on `windows-latest` (median of three runs; soft gate).
- As a standard user, every elevation-dependent module returns a structured skip reason.
- Pester passes on the `windows-11-arm` runner.

## Phase 3 — Interfaces & UX

**Deliverables**
- **CLI:** the full command tree (`scan`, `<group>`, `report`, `list`, `repair`, `compare`,
  `gui`, `version`), `--format json|csv|md|html` (+ PDF), `--output`, `--elevated-only`,
  `--what-if`, `--apply` (`--yes` for non-interactive), `--redact`.
- **Repairs:** non-interactive `omnidiag repair <id…> --what-if | --apply`; nothing changes
  without `--apply` or a GUI confirmation; a local JSONL audit log of applied steps.
- **PowerShell:** curated cmdlets (`Get-OmniDiagModule`, `Invoke-OmniDiagScan`,
  `Get-OmniDiag<Group>`, `Invoke-OmniDiagReport`, `Get-OmniDiagRepair`,
  `Invoke-OmniDiagRepair` with `-WhatIf`/`-Confirm`, `Compare-OmniDiagSession`,
  `Show-OmniDiagGui`) with comment-based help and examples; old names as deprecated aliases.
- **Report bundle:** `omnidiag report` runs every safe module and writes one HTML + JSON bundle;
  `--redact` replaces host names, user names, domains, SIDs, profile paths, and IP/MAC addresses
  with stable pseudonyms in every output format.
- **GUI:** per-group drill-down, export (incl. redacted), keyboard navigation and shortcuts,
  `AutomationProperties` names on every interactive control, high-contrast support, startup
  under 2 s (lazy discovery, deferred work after first paint).

**Acceptance criteria**
- `Get-Help` shows at least one example for every public cmdlet (enforced by a test).
- A redaction fixture with planted identifiers leaves zero occurrences in JSON, HTML, CSV,
  Markdown, PDF, and file names.
- Repair without `--apply` performs no action (a test asserts no step action runs).
- A UI Automation test finds a name on every focusable control and full Tab traversal;
  GUI first render under 2 s on the Windows runner (soft gate).
- A manual Narrator and High Contrast checklist is completed and recorded (cannot be automated).

## Phase 4 — Hardening & verification

**Deliverables**
- Coverage at or above 80% on Core (measured on Windows), with unit tests for parsing and
  logic and integration tests that run real scanners on the Windows runner.
- A standard-user CI leg (local non-admin account) alongside the elevated leg.
- Security review with a test per item: export path handling (`--output` canonicalized, no
  traversal), zip-slip on report-package import, temp files only through `Get-OmniDataPath`,
  no secrets in reports, redaction correctness, executable resolution in the launchers (pin
  `pwsh.exe` / `powershell.exe` paths instead of `PATH` lookup), HTML/CSV encoding, fuzzed
  session import.
- Performance: full report under 60 s, GUI startup under 2 s, measured and recorded.

**Acceptance criteria**
- Coverage gate enforced in CI; both privilege legs green.
- Every security finding is fixed with a test, or documented with a reason.
- Win10 / Win11 client behavior verified on real machines or a self-hosted runner, or listed
  as unverified in the release notes.

## Phase 5 — Release readiness

**Deliverables**
- README with screenshots and quick start; docs per module group; CLI, exit-code, and schema
  reference; CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, CHANGELOG brought current; license
  confirmed (MIT).
- Reproducible portable zip (fixed timestamps, sorted entries), `SHA256SUMS`, SBOM.
- Installer per decision 7 (recommended: per-user WiX MSI + winget manifest pointing to it).
- Code-signing hook (`build/Sign.ps1`) that signs scripts and a file catalog when a
  certificate is provided and does nothing otherwise; signing secrets stay with the owner.
- Release-on-tag workflow attaching every artifact.

**Acceptance criteria**
- Two clean builds of the same tag produce byte-identical zips.
- With a test certificate, `Get-AuthenticodeSignature` reports Valid on every script file.
- The installer installs and uninstalls per user without admin; `omnidiag version` works in a
  new shell; `winget validate` passes on the manifest.
- Pushing a tag produces a GitHub release with zip, installer, checksums, and SBOM.

## Definition of done (v1.0)

- Clean build and green CI on Windows.
- All Phase 2 module groups work through the GUI, the CLI, and PowerShell, with tests.
- `omnidiag report` produces a correct HTML + JSON bundle as a standard user, with extra
  sections when elevated.
- The no-network test passes; security findings resolved or documented.
- Docs complete; a release can be produced from a tag.

## Decisions (approved 2026-10-18)

1. **Network probes** — opt-in via `--network-probes` (gateway, `1.1.1.1`, `www.microsoft.com`,
   AD secure-channel check).
2. **Local AI (Ollama)** — kept as an opt-in, loopback-only feature; allowlisted in the
   no-network test.
3. **DISM repair** — kept, labeled `Internet`, runs only with `--apply`.
4. **Severity mapping** — Pass and Information → Info (passing checks included with
   `passed: true`); Warning → Warning; Error and Critical → Critical. `severityNative` is kept.
5. **Groups** — the ten v1.0 groups, plus `extras` for the other scanners.
6. **Platforms** — Windows 10 22H2 x64 and Windows 11 x64; ARM64 on Windows 11 only.
7. **Installer** — per-user WiX MSI + winget manifest; a tiny signed `omnidiag.exe` stub is
   allowed if winget aliases need it.
8. **Code signing** — hooks only for v1.0; the certificate is chosen later.
9. **Repository** — public, so the free `windows-11-arm` runner is used.
10. **`install.ps1`** — kept, pinned to release tags instead of `main`.
11. **Public API** — curated `Get-OmniDiag*` / `Invoke-OmniDiag*` cmdlets; current names stay as
    deprecated aliases for one minor version.
