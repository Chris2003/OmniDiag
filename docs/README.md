# OmniDiag documentation

Start with the [project README](../README.md) for what OmniDiag is and how to install it.

## Using OmniDiag

| Page | What it covers |
|---|---|
| [Technician Guide](TECHNICIAN_GUIDE.md) | Role profiles (Help Desk ... Cloud Admin) and task workflows (Quick Triage, Slow Computer, ...) and when to use which |
| [Command line](CLI.md) | `omnidiag` commands, options, output streams, exit codes, and examples |
| [PowerShell](POWERSHELL.md) | The public cmdlets, the objects they return, the plugin SDK, and deprecated names |
| [GUI](GUI.md) | The window's sections, keyboard shortcuts, export dialog, accessibility, and startup |
| [Module groups](modules/README.md) | The 11 groups and every scanner: what it checks, elevation, network access, and the findings it can emit |
| [Report redaction](REDACTION.md) | What `--redact` replaces, pseudonyms, the redaction map, and its limits |
| [Report schema v1](SCHEMA.md) | The JSON report format ([schemas/omnidiag-report.v1.json](../schemas/omnidiag-report.v1.json)) and session import rules |
| [Local Ollama assistant](OLLAMA.md) | Optional on-device AI analysis: models, what is sent, and how output is checked |
| [Portable edition](../PORTABLE.md) | Running from a folder or USB stick, zero-footprint data, fleet deployment |
| [Organization runbooks](../runbooks/README.md) | Writing approved runbooks that search and the assistant can cite |

## Installing and releasing

| Page | What it covers |
|---|---|
| [Installer](INSTALLER.md) | The MSI and the winget package |
| [Releasing](RELEASING.md) | How a release is built, signed, and published, and how to verify its artifacts |

## Security and quality

| Page | What it covers |
|---|---|
| [Security policy](../SECURITY.md) | Supported versions, how to report a vulnerability, scope, privacy model |
| [Security review](SECURITY-REVIEW.md) | Phase 4 review: each item's finding, fix, test, and the residual risks |
| [Platform verification](VERIFICATION.md) | Which Windows editions and PowerShell hosts are verified, and how |

## Project

| Page | What it covers |
|---|---|
| [Architecture](ARCHITECTURE.md) | Layers, the scanner and repair contracts, the engine, execution and concurrency |
| [Contributing](../CONTRIBUTING.md) | Development setup, tests, lint, coverage, CI, adding a scanner or a repair |
| [v1.0 roadmap](ROADMAP.md) and [status](STATUS.md) | The phased plan to 1.0 and where each item stands |
| [Improvement plan](IMPROVEMENT_PLAN.md) | The longer-term direction |
| [Milestone roadmap](../ROADMAP.md) | The original milestone plan |
| [Changelog](../CHANGELOG.md) | What changed in each version |
| [Credits and AI disclosure](../CREDITS.md) | Who built OmniDiag and how |
