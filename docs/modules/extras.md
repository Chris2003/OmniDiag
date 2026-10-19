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

One section per scanner. Entra ID, Time Synchronization, and Intune and MDM were reworked in
0.7.0; the other scanners are unchanged from earlier releases.

### Active Directory (`extras.active-directory`)

- Domain membership from `Win32_ComputerSystem` (`PartOfDomain`, `Domain`). A device that
  is not domain joined gets one Information finding and the scan stops there.
- Logon server: an empty `LOGONSERVER` on a domain-joined device is a Warning.
- With `--network-probes`: `Test-ComputerSecureChannel`; a result of false is an Error.
  When the cmdlet is missing or throws, the check is not reported (logged at Debug).
  Without probes the standard **Connectivity probe not run** finding is added.
- Group Policy: records whether the machine Group Policy state key exists
  (`MachineGroupPolicyStatePresent` metric only; no finding).

### Battery (`extras.battery`)

- Presence from `Win32_Battery` (first battery only); none is Information and the scan
  stops there.
- Charge (`EstimatedChargeRemaining`) and AC status (`BatteryStatus` 2 = on AC): a charge
  below 20% while not on AC is a Warning.
- Wear, best effort: 1 - full-charge capacity / design capacity; above 25% is a Warning.
  When the `root/wmi` capacity classes cannot be read, wear is omitted (logged at Debug).

### Benchmark (`extras.benchmark`)

- CPU: a fixed loop of 1,000,000 square roots, timed; reports milliseconds and operations
  per second.
- Disk: writes then reads an 8 MB file (1 MB blocks) in the OmniDiag data `temp` folder
  (never the user's `%TEMP%`), reports MB/s for each, and deletes the file.
- Scores only, no thresholds: the result is an Information **Benchmark scores** finding.
  Cancellation is checked every 100,000 CPU iterations and before the disk test.

### Browser Diagnostics (`extras.browser-diagnostics`)

- Detects Edge, Chrome, and Firefox for the current user by their user-data folders
  (Information per browser found, with the profile count).
- Profiles: Edge and Chrome folders named `Default` or `Profile *`; every Firefox profile
  folder.
- Cache size per browser, summed across its profiles; above 2 GB is a Warning.

### Environment Variables (`extras.environment-variables`)

- Counts machine and user variables (`EnvVarCount` metric).
- PATH (machine + user): duplicate entries (case-insensitive, trailing `\` ignored) are
  Information; entries that do not exist after variable expansion are a Warning (at most
  15 listed in the detail).
- When the variables cannot be read the result is Skipped.

### GPU (`extras.gpu`)

- Inventory from `Win32_VideoController`: names, VRAM (`AdapterRAM`, best effort; it can
  under-report large VRAM), driver versions, and current resolution.
- A `DriverDate` older than 2 years is a Warning per adapter.
- Total GPU utilization from the `GPU Engine` counters, best effort; omitted when the
  counter cannot be read (logged at Debug).

### Installed Software (`extras.installed-software`)

- Applications with a `DisplayName` in the machine, WOW6432Node, and current-user uninstall
  keys, de-duplicated by name. Reports the count and the first 200 entries (name, version,
  publisher). Inventory only: no thresholds, no Warning.

### Printers (`extras.printers`)

- Printers from `Get-Printer`, falling back to `Win32_Printer`; records the count, the
  default printer, the name and status list, and the print-driver count (`Get-PrinterDriver`,
  best effort).
- A printer is not ready (Warning) when, with `Get-Printer`, its `PrinterStatus` contains
  `Offline` or `Error`; with the CIM fallback, when `WorkOffline` is set or `PrinterStatus`
  is 7 (Offline).

### Temp Files (`extras.temp-files`)

- Sums file sizes, without deleting anything, in the user's temp folder (the real one, not
  the portable OmniDiag temp folder), `%WINDIR%\Temp`, `%WINDIR%\Prefetch`, the Chrome and
  Edge `Default` profile caches, and `%LOCALAPPDATA%\Mozilla\Firefox\Profiles`.
- More than 2048 MB is a Warning (the recommendation points to the Clear Temp Files
  repair); 2048 MB or less is Information. Unreadable folders count as 0.

### USB Devices (`extras.usb-devices`)

- Present USB devices from `Get-PnpDevice -Class USB -PresentOnly` (previously connected,
  not-present devices are excluded so they are not flagged), falling back to
  `Win32_PnPEntity` entries whose `PNPDeviceID` starts with `USB`.
- A non-zero `ConfigManagerErrorCode` or status `Error` is a Warning per device.

### Windows Features (`extras.windows-features`)

- Enabled optional features (`Win32_OptionalFeature`, `InstallState` 1): count and sorted
  names. Inventory only: no thresholds, no Warning.

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
| Active Directory | `Win32_ComputerSystem` (`PartOfDomain`, `Domain`); the `LOGONSERVER` environment variable; `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List` (existence only). With probes: `Test-ComputerSecureChannel`. |
| Battery | `Win32_Battery` (`EstimatedChargeRemaining`, `BatteryStatus`); `root/wmi` `BatteryStaticData` (`DesignedCapacity`) and `BatteryFullChargedCapacity` (`FullChargedCapacity`). |
| Benchmark | In-process timing (`System.Diagnostics.Stopwatch`); an 8 MB scratch file in the OmniDiag data `temp` folder (`Get-OmniDataPath -Kind Temp`), deleted afterwards. |
| Browser Diagnostics | Folders `%LOCALAPPDATA%\Microsoft\Edge\User Data` and `%LOCALAPPDATA%\Google\Chrome\User Data` (profile `Cache` subfolders); `%APPDATA%\Mozilla\Firefox\Profiles` (profiles) and `%LOCALAPPDATA%\Mozilla\Firefox\Profiles\<profile>\cache2` (cache). File sizes via `Get-ChildItem -Recurse`. |
| Environment Variables | `[Environment]::GetEnvironmentVariables('Machine')` and `('User')`; `[Environment]::ExpandEnvironmentVariables` and `Test-Path` per PATH entry. |
| GPU | `Win32_VideoController` (`Name`, `AdapterRAM`, `DriverVersion`, `DriverDate`, `CurrentHorizontalResolution`, `CurrentVerticalResolution`); `Get-Counter '\GPU Engine(*)\Utilization Percentage'`. |
| Installed Software | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*`, `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*`, `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` (`DisplayName`, `DisplayVersion`, `Publisher`). |
| Printers | `Get-Printer` (falls back to `Win32_Printer`: `WorkOffline`, `PrinterStatus`, `Default`); `Win32_Printer` for the default printer; `Get-PrinterDriver`. |
| Temp Files | Folders `%TEMP%` (or `OMNIDIAG_HOST_TEMP` under the portable launcher), `%WINDIR%\Temp`, `%WINDIR%\Prefetch`, `%LOCALAPPDATA%\Google\Chrome\User Data\Default\Cache`, `%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache`, `%LOCALAPPDATA%\Mozilla\Firefox\Profiles`. File sizes via `Get-ChildItem -Recurse -Force`. |
| USB Devices | `Get-PnpDevice -Class USB -PresentOnly` (`FriendlyName`, `InstanceId`, `Status`, `ConfigManagerErrorCode`); falls back to `Win32_PnPEntity` filtered on `PNPDeviceID` `USB*`. |
| Windows Features | `Win32_OptionalFeature` (`Name`, `InstallState`). |
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

### Other scanners

These scanners set no explicit finding Id; each Id is derived from the finding's component
and title (for example `identity-activedirectory-no-domain-logon-server-is-recorded`), so a
title that carries a live value (a count, a percentage, a device name) gives an Id specific
to that value.

| Scanner | Finding | Severity | When |
|---|---|---|---|
| Active Directory | Active Directory check is Windows-only | Information | Non-Windows host |
| Active Directory | Device is not Active Directory domain joined | Information | `Win32_ComputerSystem.PartOfDomain` is false (the scan stops here) |
| Active Directory | Connectivity probe not run | Information | Domain-joined, probes off |
| Active Directory | No domain logon server is recorded | Warning | Domain-joined and `LOGONSERVER` is empty |
| Active Directory | Active Directory secure channel is unhealthy | Error | Probes on and `Test-ComputerSecureChannel` returns false |
| Active Directory | Active Directory posture healthy | Pass | Domain-joined, no warning |
| Battery | No battery detected (desktop or VM) | Information | `Win32_Battery` returns nothing |
| Battery | Battery wear at *n*% | Warning | Wear (1 - full-charge capacity / design capacity) above 25% |
| Battery | Low battery charge (*n*%) | Warning | Charge below 20% and not on AC power |
| Battery | Battery metrics collected | Pass | Battery present, no warning |
| Benchmark | Benchmark scores | Information | At least one CPU or disk score was measured |
| Benchmark | Benchmark completed | Pass | Run not cancelled |
| Browser Diagnostics | Microsoft Edge / Google Chrome / Mozilla Firefox detected (*n* profile(s)) | Information | The browser's user-data folder exists |
| Browser Diagnostics | Edge / Chrome / Firefox cache is large (*n* GB) | Warning | That browser's cache is above 2 GB |
| Browser Diagnostics | No supported browser profiles found | Information | None of the three browsers was found |
| Browser Diagnostics | Browser diagnostics collected | Pass | No warning |
| Environment Variables | *n* duplicate PATH entry/entries | Information | Machine + user PATH holds the same directory more than once (case-insensitive, trailing `\` ignored) |
| Environment Variables | *n* PATH entry/entries point to missing directories | Warning | A PATH entry (after variable expansion) does not exist |
| Environment Variables | Environment variables healthy | Pass | No warning (when the variables cannot be read the result is Skipped, with no finding) |
| GPU | Old GPU driver for *adapter* | Warning | `Win32_VideoController.DriverDate` older than 2 years |
| GPU | GPU inventory collected | Pass | No warning |
| Installed Software | *n* applications installed | Information | Always |
| Installed Software | Software inventory collected | Pass | Always |
| Printers | Printer not ready: *name* | Warning | Printer offline (`WorkOffline`, or status Offline) or in an Error status |
| Printers | Printers enumerated | Pass | No warning |
| Temp Files | *n* MB of temporary files can be reclaimed | Warning | More than 2048 MB across the temp, Prefetch, and browser-cache folders |
| Temp Files | *n* MB of temporary files present | Information | 2048 MB or less |
| Temp Files | Temp file usage within normal range | Pass | No warning |
| USB Devices | USB device reporting an error: *device* | Warning | Non-zero device error code or status Error |
| USB Devices | USB devices enumerated | Pass | No warning |
| Windows Features | *n* Windows optional feature(s) enabled | Information | `Win32_OptionalFeature` query succeeded |
| Windows Features | Windows features inventory collected | Pass | No warning |

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. Where a cmdlet is missing, Printers falls
back to `Win32_Printer` and USB Devices to `Win32_PnPEntity`. Data a device does not provide
(no battery, no `root/wmi` battery capacity classes, no readable `GPU Engine` counter, no
browser folders) is left out of the metrics or reported as Information, never as a failure.
The `GPU Engine` counter path is localized on non-English Windows; when it cannot be read the
utilization metric is omitted (logged at Debug).

On a non-Windows host, Active Directory, Entra ID, Time Synchronization, and Intune and MDM
return a single Information "Windows-only" finding. The other scanners have no explicit
platform check: their queries fail soft (logged, metric omitted), so their result is not
meaningful off Windows.
