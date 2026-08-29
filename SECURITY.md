# Security Policy

## Privacy model

OmniDiag is **local-only by design**:

- No telemetry, no ads, no analytics.
- No data is ever uploaded or sent to any cloud service by default.
- All collection and analysis happen on the local machine.
- Reports are written only where you choose, and OmniDiag warns that they may
  contain usernames, device names, file paths, domains, and other internal
  information. **Review reports before sharing them.**

OmniDiag is deliberately **local-only**: it runs on the machine being diagnosed and
never reaches out to other machines. Remote execution (e.g. WinRM/PowerShell Remoting)
was intentionally left off the roadmap; "fleet" use is served by running the portable
build on each machine and collecting the reports. Should any remote/cloud capability
ever be added, it would be strictly opt-in and clearly disclosed.

## Supported versions

OmniDiag is pre-1.0 and under active development. Security fixes are applied to the
latest `main`. Pin a released tag for stability.

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, report privately via [GitHub Security Advisories](https://github.com/Chris2003/OmniDiag/security/advisories/new)
(Security → Report a vulnerability). Include:

- A description of the issue and its impact.
- Steps to reproduce or a proof of concept.
- Affected version / commit.

We aim to acknowledge reports within 5 business days and to provide a remediation
timeline after triage. Coordinated disclosure is appreciated.

## Quick installer trust model

The README offers a one-command installer for convenience. It retrieves
`install.ps1` from this repository and therefore executes remote code with the current
user's privileges. Review the script before running it, especially in managed
environments. The installer validates the extracted OmniDiag layout, supports an
optional archive SHA-256, installs only an explicit allowlist, clears Mark-of-the-Web
only after validation, and keeps the previous installation as a recoverable backup.

For repeatable deployment, pin `-Ref` to an approved release tag or commit and supply
`-ExpectedSha256`. Do not expose a branded short URL until HTTPS, ownership, redirects,
and change controls for that domain are established.

## Scope notes

- OmniDiag executes diagnostic queries with the privileges of the running user.
  Running elevated grants it broad read access to the system — only run it from
  trusted sources.
- Optional repair actions (the Repair Center) change system state and always require
  explicit confirmation; a System Restore point is created before system-altering repairs,
  and a dry-run mode describes every repair without executing it.
