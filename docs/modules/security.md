# Security (`security`)

Defender, firewall, BitLocker, certificates, UAC, and local administrators: the machine's
local security posture.

## Run it

```bat
omnidiag security
omnidiag security --format json --output C:\Cases\1234\
omnidiag security --network-probes
```

```powershell
Get-OmniDiagSecurity
Get-OmniDiagSecurity -IncludePassed | Format-Table severity, moduleId, title
Get-OmniDiagSecurity -NetworkProbes   # also lists local admins on a domain- or Entra-joined device
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| BitLocker | `security.bitlocker` | Volume protection and local recovery-key escrow policy evidence. | Not required; `Get-BitLockerVolume` returns full data only elevated | None |
| Certificates | `security.certificates` | Expired and expiring local machine and user certificates. | Not required | None |
| Defender Onboarding | `security.defender-onboarding` | Microsoft Defender Antivirus and Defender for Endpoint onboarding posture. | Not required | None |
| Firewall Rules | `security.firewall-rules` | Summarizes enabled firewall rules and inbound exposure. | Not required | None |
| Local Admins | `security.local-admins` | Members of the built-in Administrators group (by SID) and the built-in Administrator account state. | Not required | LocalNetwork (opt-in, joined devices only) |
| Security | `security.security` | Checks Defender, firewall profiles, and UAC posture (EnableLUA, admin prompt behavior, secure desktop). | Not required | None |

## What it checks

**Security (Defender, firewall profiles, UAC).**

- Microsoft Defender: real-time protection on, the antimalware service enabled, and the
  antivirus signature age (warning above 7 days).
- Windows Firewall: each profile (Domain, Private, Public) enabled.
- UAC, from the policy registry values (a missing value means the Windows default):
  - `EnableLUA` = 0 (Admin Approval Mode off, UAC disabled): Warning.
  - `ConsentPromptBehaviorAdmin` = 0 (elevate administrators without prompting): Warning.
    1 to 5 (prompt for credentials or consent; 5, the default, prompts for non-Windows
    binaries) are accepted.
  - `PromptOnSecureDesktop` = 0 (prompts on the interactive desktop): Warning.
  - When `EnableLUA` is 0 the other two values have no effect and are not reported.

**Firewall Rules.** Counts enabled inbound and outbound rules and enabled inbound Allow
rules; more than 150 enabled inbound Allow rules is a Warning (large attack surface).

**BitLocker.** Protection status, volume status, and encryption percentage of the operating
system volume (protection not On is a Warning), and local evidence of a recovery-key escrow
policy (`HKLM\SOFTWARE\Policies\Microsoft\FVE`). A protected volume without local escrow
policy evidence is Information: local inspection cannot prove the key is escrowed.

**Defender Onboarding.** Defender for Endpoint `OnboardingState` (registry), the Sense
sensor service state, and Defender Antivirus enabled / real-time protection.

**Certificates.** Certificates in the LocalMachine and CurrentUser personal (`My`) stores:
expired (Error, first 10) and expiring within 30 days (Warning, first 10).

**Local Admins.** The members of the built-in Administrators group, found by its well-known
SID `S-1-5-32-544`, so it works whatever the group is called on localized Windows. Checks:

- The built-in Administrator account (RID 500, found by SID, so a renamed account is still
  found) is enabled: Warning.
- Member count and the full list (name, SID, source: Local, ActiveDirectory, AzureAD,
  MicrosoftAccount): Information (the list is in the `AdministratorsMembers` metric).
- Local accounts other than the built-in Administrator that are members: Information.
- Members whose SID does not resolve to a name (deleted accounts, unreachable domain):
  Information.
- No member other than the built-in Administrator: Information.

## Data sources

| Scanner | Source |
|---|---|
| Security | `Get-MpComputerStatus`; `Get-NetFirewallProfile`; `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` (`EnableLUA`, `ConsentPromptBehaviorAdmin`, `PromptOnSecureDesktop`) |
| Firewall Rules | `Get-NetFirewallRule -Enabled True -Direction Inbound / Outbound` |
| BitLocker | `Get-BitLockerVolume`; `HKLM\SOFTWARE\Policies\Microsoft\FVE` |
| Defender Onboarding | `HKLM\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status` (`OnboardingState`); `Get-Service Sense`; `Get-MpComputerStatus` |
| Certificates | `System.Security.Cryptography.X509Certificates.X509Store` (`My`, read-only, existing stores only). Not the `Cert:` provider: enumerating it makes Windows fetch revocation data from the network. Only expiry dates are read; no chain is built. |
| Local Admins | `Get-LocalGroupMember -SID S-1-5-32-544`; fallback `Win32_Group` + `Win32_GroupUser` (the cmdlet can throw on a group that holds an orphaned or unresolvable SID); `Get-LocalUser` for the RID-500 account; `Win32_ComputerSystem.PartOfDomain` and `HKLM\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo` for the join state |

Every source is a documented cmdlet, CIM class, or registry value; no tool output is parsed,
so the results do not depend on the display language. Well-known SIDs (`S-1-5-32-544`, RID
500) are used instead of the localized names "Administrators" and "Administrator".

## Elevation

No scanner in this group requires administrator rights at the module level. As a standard
user:

- **BitLocker:** `Get-BitLockerVolume` can return no data for the OS volume; the scanner then
  reports "BitLocker volume status could not be read" (Information) and recommends running
  elevated.
- **Defender Onboarding:** the onboarding registry key can be unreadable; reported as "not
  locally evident" (Information).
- **Local Admins, Security, Firewall Rules, Certificates:** full results.

## Network access

A default run is local-only.

**Local Admins** is the only scanner in this group with opt-in network behaviour.
`Get-LocalGroupMember` and `Win32_GroupUser` translate each member SID to a name through the
Local Security Authority. For a domain or Microsoft Entra ID member that is not in the local
lookup cache, that translation can query a domain controller (or Entra ID). So:

| Device | Without `--network-probes` | With `--network-probes` |
|---|---|---|
| Not joined (workgroup) | Full check (every member resolves locally) | Same |
| Domain- or Entra-joined | Built-in Administrator check only; the group is not enumerated and an Information finding, **Connectivity probe not run**, says how to run it | Full check; member-name lookups may query a domain controller or Entra ID |

PowerShell has no way to list the group as SIDs only without compiled interop
(`NetLocalGroupGetMembers` level 0), which OmniDiag does not use, so on a joined device the
membership is not listed in a default scan rather than listed partially.

## Findings it can emit

| Scanner | Finding (Id when explicit) | Severity | When |
|---|---|---|---|
| Security | Real-time protection is disabled | Warning | Defender real-time protection off |
| Security | Antimalware service is not running | Warning | `AMServiceEnabled` false |
| Security | Antivirus signatures are *n* days old (`security-defender-signatures-outdated`) | Warning | Signature age above 7 days |
| Security | Firewall disabled for *profile* profile | Warning | A firewall profile is off |
| Security | User Account Control (UAC) is disabled | Warning | `EnableLUA` = 0 |
| Security | UAC elevates administrators without prompting (`security-uac-elevate-without-prompting`) | Warning | `ConsentPromptBehaviorAdmin` = 0 |
| Security | UAC prompts do not use the secure desktop (`security-uac-secure-desktop-disabled`) | Warning | `PromptOnSecureDesktop` = 0 |
| Security | Baseline security posture is healthy | Pass | No warning |
| Firewall Rules | *n* enabled inbound allow rule(s) (`security-firewall-inbound-allow-rules`) | Information | Any enabled inbound Allow rule |
| Firewall Rules | Unusually high number of inbound allow rules (*n*) (`security-firewall-inbound-allow-rules-high`) | Warning | More than 150 |
| Firewall Rules | Firewall rule set reviewed | Pass | No warning |
| BitLocker | BitLocker protection is not active on the OS volume | Warning | Protection status not On |
| BitLocker | BitLocker volume status could not be read | Information | No OS volume data |
| BitLocker | Recovery-key escrow is not locally verifiable | Information | Protected, no escrow policy evidence |
| BitLocker | BitLocker protection posture healthy | Pass | OS volume read and no warning |
| Defender Onboarding | Defender for Endpoint is not onboarded | Warning | `OnboardingState` not 1 |
| Defender Onboarding | MDE sensor service is not running | Warning | Onboarded, Sense not running |
| Defender Onboarding | Microsoft Defender Antivirus protection is reduced | Warning | Antivirus or real-time protection off |
| Defender Onboarding | Defender for Endpoint onboarding is not locally evident | Information | No readable `OnboardingState` |
| Defender Onboarding | Defender onboarding posture healthy | Pass | No other finding |
| Certificates | Expired certificate: *subject* (`certificate-expired-<thumbprint>`) | Error | `NotAfter` in the past (first 10) |
| Certificates | Certificate expires soon: *subject* (`certificate-expiring-<thumbprint>`) | Warning | Expires within 30 days (first 10) |
| Certificates | Windows certificate stores are unavailable | Information | Not Windows |
| Certificates | Personal certificate expiration posture healthy | Pass | Neither |
| Local Admins | Built-in Administrator account is enabled (`security-local-admins-builtin-administrator-enabled`) | Warning | RID-500 account enabled |
| Local Admins | *n* member(s) in the local Administrators group (`security-local-admins-members`) | Information | Membership listed |
| Local Admins | *n* additional local account(s) with administrator rights (`security-local-admins-extra-local-accounts`) | Information | Local accounts other than RID 500 are members |
| Local Admins | *n* Administrators member(s) could not be resolved to a name (`security-local-admins-unresolved`) | Information | Orphaned or unresolvable SIDs |
| Local Admins | No administrator besides the built-in account (`security-local-admins-only-builtin`) | Information | Only RID 500 (or nobody) is a member |
| Local Admins | Administrators group membership not available (`security-local-admins-unavailable`) | Information | Neither enumeration path worked |
| Local Admins | Connectivity probe not run | Information | Joined device, probes off (the scan stops after the built-in Administrator check) |
| Local Admins | Local administrator posture reviewed (`security-local-admins-reviewed`) | Pass | No warning |

Explicit finding ids are stable and contain no live values (for example
`security-local-admins-builtin-administrator-enabled`, `security-uac-elevate-without-prompting`,
`security-defender-signatures-outdated`), except the per-certificate ids, which carry the
certificate thumbprint so each certificate is tracked on its own. A finding without an
explicit id gets one derived from its component and title (for example
`security-bitlocker-bitlocker-protection-is-not-active-on-the-os-volume`).

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. The Defender, NetSecurity, BitLocker, and
LocalAccounts modules ship with every supported edition; `Get-BitLockerVolume` is missing on
editions without BitLocker (Home), and the LocalAccounts module is not available in 32-bit
PowerShell on 64-bit Windows: both are reported as "not available" Information, never as a
failure.
