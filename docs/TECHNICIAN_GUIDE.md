# OmniDiag Technician Guide

OmniDiag supports two ways to start: choose **who you are** with a role profile, or
choose **what you are fixing** with a task workflow. Both approaches run focused,
read-only diagnostics. Repairs remain separate, opt-in, and confirmation-gated.

## Start here

Open PowerShell in the OmniDiag folder and list the available plans:

```powershell
.\OmniDiag.ps1 -ListPlans
```

For an unknown issue, run the quick triage workflow:

```powershell
.\OmniDiag.ps1 -Workflow QuickTriage
```

Use `-Report` when the result needs to be attached to a ticket or escalated. Review
the report before sharing because it can contain internal device and user details.

## Role profiles

| Profile | Best for | Focus |
|---|---|---|
| `HelpDesk` | Tier 1/service desk | Fast endpoint, resource, disk, network, update, printing, and error triage |
| `DesktopSupport` | Tier 2/field support | Applications, devices, drivers, startup, reliability, and deeper endpoint checks |
| `SystemsAdmin` | Windows/server admins | OS health, services, storage, security, event logs, and identity posture |
| `NetworkAdmin` | Network/infrastructure admins | Addressing, DNS, Wi-Fi, shares, firewall, and domain dependencies |
| `SecurityAdmin` | Security/endpoint admins | Protection, patching, persistence, software, identity, and security events |
| `CloudAdmin` | Entra/Intune/Microsoft 365 admins | Join, registration, MDM enrollment, policy errors, DNS, and access prerequisites |
| `Full` | Tier 3/engineering | Every enabled scanner |

Example:

```powershell
.\OmniDiag.ps1 -Profile CloudAdmin -Range Last24Hours -Report -AcceptPrivacyNotice
```

## Daily task workflows

| Workflow | Use it when |
|---|---|
| `QuickTriage` | The symptom is unclear and you need a fast first pass |
| `SlowComputer` | A device is slow, freezing, or slow to sign in |
| `NetworkConnectivity` | Internet, LAN, VPN-adjacent, DNS, Wi-Fi, or share access fails |
| `Printing` | Printers are missing, offline, queued, or failing |
| `WindowsUpdate` | Updates fail, loop, remain pending, or require servicing checks |
| `LoginAndIdentity` | Domain sign-in, Microsoft 365 SSO, device trust, or enrollment fails |
| `StorageCleanup` | A disk is full, unhealthy, or needs a cleanup assessment |
| `SecurityPosture` | You need an endpoint protection and persistence review |
| `CloudReadiness` | You are onboarding or validating an Entra/Intune-managed device |
| `FullScan` | You need the complete evidence set |

## A simple support workflow

1. Run the closest task workflow without elevation.
2. Read **Top recommendations** from highest severity to lowest.
3. Re-run elevated only when the output says an admin-only check was skipped.
4. Export a report before changing the system when evidence must be preserved.
5. Use `-Repair -RepairDryRun` to preview applicable repairs.
6. Apply only repairs approved by your organization, then rescan the same workflow.
7. Escalate with the before/after reports, exact timestamps, and attempted actions.

## Identity and cloud checks

The enterprise scanners are intentionally local and read-only:

- **Active Directory** checks domain membership, the computer secure channel, the
  recorded logon server, and local Group Policy state.
- **Entra ID** parses the Windows-built-in `dsregcmd /status` output for join,
  registration, tenant, device-authentication, and primary-refresh-token posture.
- **Intune and MDM** checks local enrollment records, the Intune Management
  Extension, its service, and recent MDM policy-processing errors.
- **Enterprise prerequisites** add certificate expiration, proxy, VPN, time
  synchronization, BitLocker and escrow-policy evidence, Defender onboarding, and
  managed update-ring posture.

They do not use PowerShell remoting, authenticate to Microsoft Graph, modify the
directory, or upload device data. A missing enrollment is informational because not
every Windows device is intended to be cloud managed.

## Automation examples

```powershell
Import-Module .\src\OmniDiag.psd1

$session = Invoke-OmniDiag -Profile HelpDesk -Quiet
Export-OmniReport -Session $session -Format Json -OutputDirectory .\reports

$session = Invoke-OmniDiag -Workflow LoginAndIdentity -Range Last24Hours -Quiet
$session.Results | Where-Object Category -in 'Identity','Cloud'

(Get-OmniTaskWorkflow NetworkConnectivity).Modules
```

Optional private correlation is available after a scan with `-AiAnalysis`. See the
[Local Ollama Assistant](OLLAMA.md) for model sizing, setup, and privacy boundaries.

`-Profile` and `-Workflow` cannot be combined with each other or with
`-IncludeModule`; this prevents an ambiguous scan. Category exclusions can still
narrow a plan when required by policy.
