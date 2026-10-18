# Security (`security`)

Defender, firewall, BitLocker, certificates, and UAC: the machine's local security posture.

## Run it

```bat
omnidiag security
omnidiag security --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagSecurity
Get-OmniDiagSecurity -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| BitLocker | `security.bitlocker` | Volume protection and local recovery-key escrow policy evidence. | Not required | None |
| Certificates | `security.certificates` | Expired and expiring local machine and user certificates. | Not required | None |
| Defender Onboarding | `security.defender-onboarding` | Microsoft Defender Antivirus and Defender for Endpoint onboarding posture. | Not required | None |
| Firewall Rules | `security.firewall-rules` | Summarizes enabled firewall rules and inbound exposure. | Not required | None |
| Security | `security.security` | Checks Defender, firewall profiles, and UAC posture. | Not required | None |

## What it checks

_To be completed by the group owner._

## Data sources

_To be completed by the group owner._

## Elevation

No scanner in this group requires administrator rights at the module level.

## Network access

None. Every scanner in this group is local-only.

## Findings it can emit

_To be completed by the group owner._

## Platforms

_To be completed by the group owner._
