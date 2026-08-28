# OmniDiag Improvement Plan

The goal is to make OmniDiag useful from a first-week help-desk technician through
an endpoint, systems, security, network, or cloud administrator without turning it
into an unsafe one-click mutation tool.

## Product assessment

The existing diagnostic engine, plugin contract, reporting, health score, portable
build, GUI, and confirmation-gated Repair Center are a solid foundation. The main
gaps are workflow guidance, enterprise identity visibility, explainability, fleet
integration contracts, and test/release automation.

## Phase 1 — Guided daily workflows (implemented in 0.2.0)

- Role profiles from Help Desk through Cloud Admin.
- Task workflows for the most common daily tickets.
- Read-only Active Directory, Entra ID, and Intune/MDM posture scanners.
- Beginner-to-admin technician guide and discoverable `-ListPlans` command.
- Plan metadata in session output and normal report serialization.
- Tests that prevent a plan from referring to a missing scanner.

Success measure: a technician selects the right evidence set without knowing every
scanner name, and an escalation records which plan produced the evidence.

## Phase 2 — Explainable triage and safe runbooks

- Add prerequisites, duration, required privilege, and data-sensitivity metadata to every scanner.
- Add verification steps, rollback guidance, escalation owner, and authoritative references to findings.
- Correlate related findings into evidence-backed incident hypotheses.
- Add organization-owned runbook packs; never silently execute a runbook.
- Add before/after comparison reports for repair verification.

Success measure: Tier 1 follows safe verification steps while Tier 3 can inspect the
raw evidence and confidence behind every hypothesis.

## Phase 3 — Enterprise operations without remoting

- Produce stable JSON schemas and exit codes for RMM, Intune, ConfigMgr, CI, and ticketing ingestion.
- Add redaction policies for usernames, hostnames, domains, IP addresses, and paths.
- Add signed configuration profiles with scanner and repair allowlists.
- Add local certificate, proxy, VPN, time-sync, BitLocker escrow, Defender onboarding, and update-ring checks.
- Add optional Graph checks only through explicit authentication and consent, separate from local-only mode.

Success measure: enterprises deploy the portable package at scale, collect predictable
evidence, and enforce policy without enabling inbound remoting.

## Phase 4 — Cross-platform technician core

- Split platform-neutral findings, workflows, reporting, and correlation from Windows collectors.
- Add Linux collectors for systemd, journal, packages, disks, networking, SSH, and cloud agents.
- Add macOS collectors for launch services, unified logs, FileVault, networking, profiles, and MDM.
- Keep platform-specific repair catalogs separate and default to dry-run.

Success measure: profiles and reports remain familiar across platforms while every
collector accurately declares its supported operating systems.

## Phase 5 — Evidence-grounded assistance

- Add natural-language search over the local session and approved runbooks.
- Generate incident summaries that cite finding IDs and never invent missing facts.
- Recommend the next diagnostic step based on unresolved uncertainty.
- Require explicit approval for every mutation with audit, rollback, and verification data.

Success measure: assistance reduces time to resolution without weakening technician
control, privacy, evidence quality, or change management.

## Engineering priorities across every phase

- Test on Windows PowerShell 5.1 and current PowerShell 7.
- Maintain Pester contract tests for every plugin and workflow.
- Sign releases, publish SHA-256 checksums, and generate an SBOM.
- Treat reports as sensitive and make redaction easy before sharing.
- Prefer read-only checks; keep repair selection, confirmation, and verification separate.
