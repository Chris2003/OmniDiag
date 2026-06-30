# Changelog

All notable changes to OmniDiag are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-06-29 — Milestone 1: Core engine

### Added
- Core data models: severity vocabulary, `New-OmniFinding`, `New-OmniResult`,
  `Add-OmniFinding`, `Set-OmniResultMetric`, `Complete-OmniResult`, `Get-OmniTimeRange`.
- Structured, leveled logging (`New-OmniLogger`) writing to an in-memory buffer and
  a JSON-lines file, with no silent failures.
- Plugin architecture: runtime module discovery and contract validation
  (`Get-OmniModule`), execution context (`New-OmniContext`), elevation detection
  (`Test-OmniIsAdministrator`).
- Orchestration engine (`Invoke-OmniSession`) with cooperative cancellation,
  progress callbacks, per-module error capture, and admin-only graceful skipping.
- Health scoring and dashboard roll-ups (`Get-OmniHealthScore`).
- **System Information** reference diagnostic module (hardware, firmware, OS, TPM,
  Secure Boot, memory/uptime findings).
- Console runner with live progress and a dashboard view.
- Public entry point `Invoke-OmniDiag` and the `OmniDiag.ps1` launcher.
- Pester test suite for models, engine, and the System Information module.
- GitHub Actions CI: PSScriptAnalyzer lint + Pester tests on `windows-latest`.
- Project documentation and governance files.

[Unreleased]: https://github.com/OWNER/OmniDiag/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/OWNER/OmniDiag/releases/tag/v0.1.0
