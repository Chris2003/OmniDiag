# Services and drivers (`services`)

Windows services and device drivers: what is installed and how it starts, what should be
running but isn't, which services crashed or failed to start recently, which drivers are
unsigned or third-party, and which devices report problems.

## Run it

```bat
omnidiag services
omnidiag services --format json --output C:\Cases\1234\
omnidiag services --range Last30Days
```

```powershell
Get-OmniDiagServices
Get-OmniDiagServices -IncludePassed | Format-Table severity, moduleId, title
Invoke-OmniDiagScan -Group services
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| Drivers | `services.drivers` | Driver inventory, unsigned and third-party drivers, and problem devices with the Device Manager error meaning. | Not required | None |
| Services | `services.services` | Service inventory by start type, stopped auto-start services, and recent SCM crash/start-failure events. | Not required | None |

## What it checks

### Services (`services.services`)

- **Start types.** Counts services by start type: Automatic, Automatic (Delayed Start),
  Manual, Disabled (plus Boot / System / Unknown if present), and by state (running,
  stopped). Always reported as an Information finding and in the `ServicesByStartType` metric.
- **Stopped automatic services.** Services with start type Automatic (not delayed) that
  are stopped. The detail shows the first 10, with the exit code when it is not 0.
- **Crashes and start failures.** Service Control Manager events in the System log over
  the session time range (`--range`): 7031 and 7034 (the service terminated unexpectedly)
  and 7000, 7009, 7011 (the service failed to start, or start/response timed out). Events
  are grouped per service; each service gets one finding per kind with the event count,
  the event IDs seen, and the last occurrence. At most 15 services per kind are listed;
  the rest are counted in one Information finding. The query is bounded to 500 events
  (newest first; config key `ServiceEventMaxEvents`), and `ScmEventsTruncated` says
  whether the cap was hit.

### Drivers (`services.drivers`)

- **Unsigned drivers.** PnP drivers whose package is not signed (`IsSigned` = False; a
  missing value is not counted as unsigned). The finding lists device, provider, version,
  and INF (first 20). File signatures are not re-verified.
- **Third-party drivers.** PnP drivers whose provider is not Microsoft: count and the top
  5 providers (Information).
- **Drivers loaded from unusual folders.** Running kernel / file-system drivers (non-PnP
  included) whose image is outside `%SystemRoot%\System32\drivers` and the driver store
  (`%SystemRoot%\System32\DriverStore`). Information: usually security, backup,
  virtualization, or anti-cheat software.
- **Problem devices.** One finding per device whose `ConfigManagerErrorCode` is not 0
  (up to 25, then a summary), with the meaning of the code and a recommendation:

  | Code | Meaning | Severity |
  |---|---|---|
  | 1 | Not configured correctly | Warning |
  | 3 | Driver corrupted, or low memory/resources | Warning |
  | 10 | Device cannot start | Warning |
  | 12 | Not enough free resources (conflict) | Warning |
  | 18 | Drivers must be reinstalled | Warning |
  | 22 | Device is disabled | Information |
  | 24 | Not present, not working, or missing drivers | Warning |
  | 28 | Drivers not installed | Warning |
  | 31 | Windows cannot load the drivers | Warning |
  | 39 | Driver cannot be loaded (corrupt or missing) | Error |
  | 43 | Windows stopped the device (it reported problems) | Error |
  | 45 | Device not connected | Information |
  | 52 | Driver signature cannot be verified | Error |
  | other | Device Manager reports a problem | Warning |

## Data sources

| Scanner | Source |
|---|---|
| Services | `Win32_Service` (`Name`, `DisplayName`, `StartMode`, `DelayedAutoStart`, `State`, `ExitCode`); `Get-WinEvent` on the local `System` log, provider `Service Control Manager`, IDs 7000/7009/7011/7031/7034 |
| Drivers | `Win32_PnPSignedDriver` (`IsSigned`, `Signer`, `DriverProviderName`, `DeviceName`, `DriverVersion`, `InfName`); `Win32_SystemDriver` (`Name`, `State`, `StartMode`, `PathName`); `Win32_PnPEntity` (`Name`, `DeviceID`, `ConfigManagerErrorCode`) |

Language independence: the service named in an SCM event is read from the event's
insertion strings by position (param1 for 7000/7031/7034, param2 for 7009/7011), never
from the rendered message, and mapped back to the service name through `Win32_Service`.
Start types, states, and error codes are the CIM values, not display text.

## Elevation

Nothing in this group needs administrator rights: standard users can read `Win32_Service`,
the driver classes, `Win32_PnPEntity`, and the System log.

## Network access

None. Every scanner in this group is local-only. Driver signatures are taken from the
driver store metadata; no file signature or certificate chain is verified (that could
fetch revocation data).

## Findings it can emit

| Finding (Id) | Severity | When |
|---|---|---|
| Service start types (`services-start-type-summary`) | Information | Always (counts by start type and state) |
| N automatic service(s) are stopped (`services-auto-start-stopped`) | Warning | An Automatic (not delayed) service is stopped |
| Service terminated unexpectedly: *name* (`services-scm-crash-<service>`) | Warning | Event 7031 or 7034 for the service in the range |
| Service failed to start: *name* (`services-scm-start-failure-<service>`) | Warning | Event 7000, 7009, or 7011 for the service in the range |
| More services with SCM failures (`services-scm-more`) | Information | More than 15 services of one kind |
| Service crash history not available (`services-scm-events-unavailable`) | Information | The System log cannot be read |
| Service inventory not available (`services-inventory-unavailable`) | Information | `Win32_Service` cannot be queried (result Skipped) |
| Services healthy (`services-healthy`) | Pass | No Warning or worse |
| N unsigned driver(s) installed (`drivers-unsigned`) | Warning | A PnP driver has `IsSigned` = False |
| N third-party driver(s) (`drivers-third-party-summary`) | Information | Any non-Microsoft PnP driver |
| N running driver(s) load from outside the driver folders (`drivers-system-driver-outside-driver-folder`) | Information | A running system driver image is outside System32\drivers and the driver store |
| Device problem: *device* (code N) (`drivers-problem-device-<device id>`) | Per code table | `ConfigManagerErrorCode` is not 0 |
| More devices reporting problems (`drivers-problem-device-more`) | Warning | More than 25 problem devices |
| Driver inventory not available (`drivers-inventory-unavailable`) | Information | No driver class can be queried (result Skipped) |
| No device problems detected (`drivers-healthy`) | Pass | No Warning or worse |

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. On other platforms (or when CIM / the event
log is unavailable) each scanner returns an Information "not available" finding and a
Skipped result instead of failing.
