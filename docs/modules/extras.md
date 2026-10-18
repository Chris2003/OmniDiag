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
| Entra ID | `extras.entra-id` | Microsoft Entra join, registration, tenant, and device-auth posture from dsregcmd. | Not required | None |
| Environment Variables | `extras.environment-variables` | Environment variable and PATH integrity inspection. | Not required | None |
| GPU | `extras.gpu` | Graphics adapter inventory, driver age, and resolution. | Not required | None |
| Installed Software | `extras.installed-software` | Inventory of installed applications from the uninstall hives. | Not required | None |
| Intune and MDM | `extras.intune-and-mdm` | Local MDM enrollment, Intune agent, service, and policy-event posture. | Not required | None |
| Printers | `extras.printers` | Installed printers, default printer, and offline/error state. | Not required | None |
| Temp Files | `extras.temp-files` | Estimated reclaimable space across temp and cache locations. | Not required | None |
| Time Synchronization | `extras.time-synchronization` | Windows Time service, source, synchronization, and NTP policy posture. | Not required | None |
| USB Devices | `extras.usb-devices` | Enumerates connected USB devices and flags device errors. | Not required | None |
| Windows Features | `extras.windows-features` | Enabled Windows optional feature inventory. | Not required | None |

## What it checks

_To be completed by the group owner._

## Data sources

_To be completed by the group owner._

## Elevation

No scanner in this group requires administrator rights at the module level.

## Network access

A default run is local-only. With `--network-probes` (`-NetworkProbes`, or the GUI option),
the Active Directory scanner runs `Test-ComputerSecureChannel` on domain-joined devices, which
contacts a domain controller. Without probes it reports domain membership, the logon server,
and Group Policy state from local data and adds an Information finding, **Connectivity probe
not run**, whose recommendation says how to run the check.

## Findings it can emit

_To be completed by the group owner._

## Platforms

_To be completed by the group owner._
