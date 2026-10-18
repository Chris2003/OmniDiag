# Extras (`extras`)

Everything outside the ten v1.0 groups: identity and cloud management (Active Directory,
Entra ID, Intune), peripherals, software and feature inventory, time sync, temp files, and a
quick benchmark.

## Run it

```bat
omnidiag extras
omnidiag extras --network-probes --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagExtras
Get-OmniDiagExtras -NetworkProbes -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| Active Directory | `extras.active-directory` | Local domain membership, DC discovery, Group Policy posture, and an opt-in secure-channel check. | Not required | LocalNetwork (probe only) |
| Battery | `extras.battery` | Battery presence, charge level, AC status, and wear. | Not required | None |
| Benchmark | `extras.benchmark` | Quick bounded CPU and disk micro-benchmark. Runs alone, after the parallel pool (`Parallel = $false`). | Not required | None |
| Browser Diagnostics | `extras.browser-diagnostics` | Detects installed browsers, profiles, and cache usage. | Not required | None |
| Entra ID | `extras.entra-id` | Microsoft Entra join and tenant from the registry; opt-in dsregcmd device-auth and PRT check. | Not required | Internet (probe only: `dsregcmd /status` contacts Microsoft Entra ID) |
| Environment Variables | `extras.environment-variables` | Environment variable and PATH integrity inspection. | Not required | None |
| GPU | `extras.gpu` | Graphics adapter inventory, driver age, and resolution. | Not required | None |
| Installed Software | `extras.installed-software` | Inventory of installed applications from the uninstall hives. | Not required | None |
| Intune and MDM | `extras.intune-and-mdm` | Local MDM enrollment, Intune agent, service, and policy-event posture. | Not required | None |
| Printers | `extras.printers` | Installed printers, default printer, and offline/error state. | Not required | None |
| Temp Files | `extras.temp-files` | Estimated reclaimable space across temp and cache locations. | Not required | None |
| Time Synchronization | `extras.time-synchronization` | Windows Time service, configured source, sync events, and NTP policy posture. | Not required | None |
| USB Devices | `extras.usb-devices` | Enumerates connected USB devices and flags device errors. | Not required | None |
| Windows Features | `extras.windows-features` | Enabled Windows optional feature inventory. | Not required | None |

## What it checks

Sections below cover the scanners reworked in 0.7.0 (Entra ID, Time Synchronization, Intune
and MDM); the other scanners are unchanged and their sections are still to be written.

### Entra ID (`extras.entra-id`)

- Default scan: whether the device is Microsoft Entra joined (including hybrid joined) and
  the tenant id / name, from the registry.
- With `--network-probes`: `dsregcmd /status` adds Entra registration (WorkplaceJoined),
  `DeviceAuthStatus` (Warning when not `SUCCESS`), and the user's primary refresh token
  (`AzureAdPrt`; Warning when a joined device has none).

### Time Synchronization (`extras.time-synchronization`)

- W32Time start type and state: Disabled is a Warning; stopped with start type Manual is
  Information (W32Time is trigger-started on workgroup devices); stopped otherwise is a
  Warning.
- Effective configuration: `Type` `NoSync` is a Warning (the clock is never synchronized).
- Synchronization failures in the scan time range (Time-Service events 36 and 47) are a
  Warning only when the newest failure is newer than the newest success event (35 or 37),
  or no success event exists; when a later synchronization succeeded they are
  Information. The newest success event is reported as `LastSyncEvent`.

### Intune and MDM (`extras.intune-and-mdm`)

- Populated enrollment records, the Intune Management Extension service, and error events
  (level 2) in the DeviceManagement Enterprise Diagnostics Admin log. The event query is
  bounded by the scan time range and `MaxEventsPerChannel` (run Config, default 500); when
  the cap is reached the finding says "at least N". The finding is a Warning only at 10 or
  more error events in the range (a few errors are routine sync and policy retries);
  fewer is Information.

## Data sources

| Scanner | Source |
|---|---|
| Entra ID | `HKLM\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo\<thumbprint>` (`TenantId`) and `...\CloudDomainJoin\TenantInfo\<tenant id>` (`DisplayName`). The documented API, `NetGetAadJoinInformation` (lmjoin.h), needs P/Invoke, which OmniDiag does not compile at run time; the registry key is the location Windows maintains for joined devices but is not itself documented on Microsoft Learn. The device certificate is not read. With probes: `dsregcmd /status`, parsed by the documented field names (`AzureAdJoined`, `EnterpriseJoined`, `DomainJoined`, `WorkplaceJoined`, `DeviceId`, `TenantId`, `TenantName`, `DeviceAuthStatus`, `AzureAdPrt`) and the documented values (`YES`, `NO`, `SUCCESS`). Microsoft does not document whether these labels are localized (unverified on non-English Windows); only these labels are matched, and when none is found the dsregcmd checks are not reported rather than misread. |
| Time Synchronization | `Get-Service W32Time` (Status, StartType); `HKLM\SOFTWARE\Policies\Microsoft\W32Time\Parameters` (Group Policy, wins) and `HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters` (`Type`, `NtpServer`); System log, provider `Microsoft-Windows-Time-Service`, events 35/37 (newest one) and 36/47 (scan time range, at most 50), matched by event ID. `w32tm /query /status` is no longer used: its output is localized. |
| Intune and MDM | `HKLM\SOFTWARE\Microsoft\Enrollments`, `HKLM\SOFTWARE\Microsoft\IntuneManagementExtension`, `Get-Service IntuneManagementExtension`, `Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin` (`Get-WinEvent -FilterHashtable` with Level, StartTime, EndTime, and `-MaxEvents`). |

## Elevation

No scanner in this group requires administrator rights at the module level.

## Network access

A default run is local-only. With `--network-probes` (`-NetworkProbes`, or the GUI option),
the Active Directory scanner runs `Test-ComputerSecureChannel` on domain-joined devices, which
contacts a domain controller. Without probes it reports domain membership, the logon server,
and Group Policy state from local data and adds an Information finding, **Connectivity probe
not run**, whose recommendation says how to run the check.

With probes, the Entra ID scanner also runs `dsregcmd /status`. That command contacts
Microsoft Entra ID (its `DeviceAuthStatus` check needs connectivity to Entra ID, and its
pre-join diagnostics test domain-controller and device-registration-service connectivity),
so a default scan reads the join state from the registry only and, on joined devices, adds
the same **Connectivity probe not run** finding.

Time Synchronization never contacts a time server: it reads configuration and the event log
only (no `w32tm /resync`, no `w32tm /stripchart`).

## Findings it can emit

### Entra ID

| Id | Title | Severity | When |
|---|---|---|---|
| `extras.entra-id.healthy` | Entra registration posture healthy | Pass | Joined or registered, no warnings |
| `extras.entra-id.not-joined` | Device is not Microsoft Entra joined | Information | Default scan, no join record |
| `extras.entra-id.not-joined-or-registered` | Device is not joined or registered with Entra ID | Information | With probes, dsregcmd reports both NO |
| `extras.entra-id.device-auth-failed` | Entra device authentication is not healthy | Warning | With probes, `DeviceAuthStatus` is not `SUCCESS` |
| `extras.entra-id.prt-missing` | No Entra primary refresh token for the current user | Warning | With probes, joined and `AzureAdPrt` is not `YES` |
| `extras.entra-id.dsregcmd-failed` | Could not read Entra join status | Warning | With probes, dsregcmd failed |
| `extras.entra-id.join-state-unavailable` | Entra join state could not be read | Information | Registry unreadable and dsregcmd not run |
| (standard) | Connectivity probe not run | Information | Default scan on a joined device |
| `extras.entra-id.windows-only` | Entra join status is unavailable | Information | Non-Windows host |

### Time Synchronization

| Id | Title | Severity | When |
|---|---|---|---|
| `extras.time-synchronization.healthy` | Time synchronization posture healthy | Pass | No warnings |
| `extras.time-synchronization.service-disabled` | Windows Time service is disabled | Warning | Start type Disabled |
| `extras.time-synchronization.service-not-running` | Windows Time service is not running | Warning | Stopped, start type not Manual |
| `extras.time-synchronization.service-on-demand` | Windows Time service is stopped (starts on demand) | Information | Stopped, start type Manual |
| `extras.time-synchronization.sync-disabled` | Time synchronization is turned off | Warning | `Type` = `NoSync` |
| `extras.time-synchronization.sync-failures` | Time synchronization failures were logged | Warning / Information | Events 36 / 47 in the time range; Warning when the newest failure is newer than the newest 35 / 37 success (or there is none), else Information |
| `extras.time-synchronization.windows-only` | Windows time synchronization is unavailable | Information | Non-Windows host |

### Intune and MDM

| Id | Title | Severity | When |
|---|---|---|---|
| `extras.intune-and-mdm.healthy` | Intune and MDM posture healthy | Pass | Enrolled, no warnings |
| `extras.intune-and-mdm.no-enrollment` | No local MDM enrollment detected | Information | No populated enrollment record |
| `extras.intune-and-mdm.ime-not-running` | Intune Management Extension is not running | Warning | IME installed, service not running |
| `extras.intune-and-mdm.recent-mdm-errors` | N (or "at least N") recent MDM enrollment or policy errors | Warning / Information | Error events in the time range; Warning at 10 or more, else Information |
| `extras.intune-and-mdm.windows-only` | Intune and MDM check is Windows-only | Information | Non-Windows host |

## Platforms

_To be completed by the group owner._
