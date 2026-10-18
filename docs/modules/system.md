# System (`system`)

Operating system, hardware, firmware, and device inventory, plus the platform health checks
a technician wants first: is this Windows release still serviced, is the device on a
supported architecture, when did it last restart, and are the TPM and Secure Boot in order.

## Run it

```bat
omnidiag system
omnidiag system --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagSystem
Get-OmniDiagSystem -IncludePassed | Format-Table severity, moduleId, title
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| System | `system.system` | Operating system support status, architecture, uptime, TPM, and Secure Boot health checks. | Not required; TPM and Secure Boot state need elevation (Information finding without it) | None |
| System Information | `system.system-information` | Hardware, firmware, and operating system inventory. | Not required | None |

The two scanners split the work so no fact is reported twice: **System Information** is the
inventory (what the machine is), **System** holds the health checks on that data. Pending
reboot is reported by the System Health scanner in the [updates](updates.md) group.

## What it checks

### System (`system.system`)

- **Operating system support status.** Builds the full version string
  `10.0.<CurrentBuild>.<UBR>`, the release (`DisplayVersion`, or `ReleaseId` on older
  builds), and the edition (`EditionID`). `ProductName` still says "Windows 10" on Windows 11,
  so the family is derived from the build (22000 or later = Windows 11). The release is
  looked up in an end-of-servicing table kept as data at the top of `src/Modules/System.psm1`
  (with the Microsoft Learn source URLs):
  - Windows 11 21H2 (22000) to 26H2 (26300) and 26H1 (28000), with separate dates for
    Home / Pro / Pro Education / Pro for Workstations and Enterprise / Education / IoT
    Enterprise / Enterprise multi-session.
  - LTSC/LTSB (EditionID `EnterpriseS`, `IoTEnterpriseS`): Windows 10 LTSB 2016 (14393),
    LTSC 2019 (17763), LTSC 2021 (19044; IoT until 2032-01-13), Windows 11 LTSC 2024 (26100;
    IoT until 2034-10-10).
  - Windows 10 below 22H2 (build < 19045) is unsupported. Windows 10 22H2 (19045) is the final
    release; Windows 10 reached end of support on **2025-10-14**, and whether the device is
    enrolled in Extended Security Updates (ESU) cannot be determined offline.
  - A release past its date is unsupported; within 90 days of it, "ending soon".
  - Builds that are not in the table (newer or pre-release), unknown editions, and Windows
    Server get no verdict (Information).
- **Architecture.** `Win32_Processor.Architecture` (9 = x64, 12 = ARM64, 0 = x86, 5 = ARM),
  falling back to the context architecture / `PROCESSOR_ARCHITECTURE`. The OmniDiag support
  matrix is Windows 10 22H2 x64 and Windows 11 x64 / ARM64; anything else gets an Information
  finding.
- **Uptime.** `Win32_OperatingSystem.LastBootUpTime`; Information below 30 days, Warning at
  30 days or more (the old 14-day threshold flagged machines that simply follow a monthly
  patch-and-restart cycle).
- **TPM.** `Win32_Tpm` (`root/cimv2/Security/MicrosoftTpm`), administrators only. As a
  standard user the scanner does not query it and reports "TPM details require elevation".
  Elevated: no TPM, a TPM that is not enabled/activated, or a TPM below 2.0 is a Warning.
- **Secure Boot.** `Confirm-SecureBootUEFI`: `$true` = enabled, `$false` = disabled on UEFI
  (Warning). It fails on legacy BIOS ("not supported on this platform", Warning: Windows 11
  needs UEFI) and without elevation ("access denied", Information: requires elevation). The
  failure is classified by exception type (`PlatformNotSupportedException`,
  `UnauthorizedAccessException`) or error id, never by message text.

### System Information (`system.system-information`)

Inventory metrics: host name, manufacturer, model, current user, domain, installed RAM, BIOS
version / date / serial number, motherboard, CPU (name, cores, threads, max clock,
virtualization firmware), GPU names, OS caption / version / build / architecture / install
date, and the number of installed applications. One check: less than 8 GB of RAM is a
Warning.

## Data sources

| Scanner | Source |
|---|---|
| System | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` (`CurrentBuild`, `UBR`, `DisplayVersion`, `ReleaseId`, `EditionID`, `ProductName`, `InstallationType`, `CurrentMajorVersionNumber`, `CurrentMinorVersionNumber`); `Win32_OperatingSystem.LastBootUpTime` and `Win32_Processor.Architecture` via `Get-OmniSystemInventory`; `Win32_Tpm`; `Confirm-SecureBootUEFI` |
| System Information | `Get-OmniSystemInventory` (`Win32_ComputerSystem`, `Win32_BIOS`, `Win32_BaseBoard`, `Win32_Processor`, `Win32_VideoController`, `Win32_OperatingSystem`); uninstall keys under `HKLM\SOFTWARE\(WOW6432Node\)Microsoft\Windows\CurrentVersion\Uninstall` |

`Get-OmniSystemInventory` (`src/Core/SystemInventory.psm1`, exported by the OmniDiag module)
is the single place the inventory CIM queries live. The GUI's System Information panel uses
it too, so the panel and the scanner always show the same data. No tool output is parsed in
this group, and no result depends on the display language.

## Elevation

Both scanners run as a standard user. Without elevation the System scanner skips the TPM
query and gets "access denied" from `Confirm-SecureBootUEFI`; it reports each as an
Information finding that says "requires elevation" (metrics `TPMStatus` and `SecureBoot` =
`RequiresElevation`). Everything else is the same as elevated.

## Network access

None. Every scanner in this group is local-only.

## Findings it can emit

### System

| Id | Title | Severity | When |
|---|---|---|---|
| `system.system.os-unsupported-release` | Unsupported Windows release, upgrade required | Warning | Windows 10 below 22H2, or a Windows 11 / LTSC release past its end of servicing for this edition |
| `system.system.os-windows10-end-of-support` | Windows 10 has reached end of support | Information | Windows 10 22H2 (ESU status cannot be determined offline) |
| `system.system.os-end-of-servicing-soon` | Windows release reaches end of servicing soon | Information | Within 90 days of the release's end date |
| `system.system.os-supported-release` | Windows release is in support | Pass | Release serviced for more than 90 days |
| `system.system.os-support-unknown` | Windows support status could not be determined | Information | Build not in the table, unknown edition, or Windows Server |
| `system.system.os-version-unavailable` | Windows version could not be read | Information | CurrentVersion registry key unreadable |
| `system.system.platform-outside-support-matrix` | Platform is outside the OmniDiag support matrix | Information | Not x64, or ARM64 on Windows 10 |
| `system.system.uptime-long` | System uptime is N days | Warning | Last boot 30 days ago or more |
| `system.system.uptime` | System uptime is N days | Information | Last boot less than 30 days ago |
| `system.system.tpm-requires-elevation` | TPM details require elevation | Information | Standard user |
| `system.system.tpm-ready` | TPM is present and enabled | Pass | TPM 2.0, enabled and activated |
| `system.system.tpm-not-found` | No TPM detected | Warning | Elevated, `Win32_Tpm` returns nothing |
| `system.system.tpm-disabled` | TPM is present but not enabled | Warning | Not enabled or not activated |
| `system.system.tpm-version-below-2` | TPM version is below 2.0 | Warning | TPM 1.2 |
| `system.system.tpm-unavailable` | TPM state could not be read | Information | `Win32_Tpm` query failed |
| `system.system.secure-boot-enabled` | Secure Boot is enabled | Pass | UEFI, Secure Boot on |
| `system.system.secure-boot-disabled` | Secure Boot is disabled | Warning | UEFI, Secure Boot off |
| `system.system.secure-boot-legacy-bios` | Device boots in legacy BIOS mode | Warning | Secure Boot not supported on this platform |
| `system.system.secure-boot-requires-elevation` | Secure Boot state requires elevation | Information | Access denied (standard user) |
| `system.system.secure-boot-unavailable` | Secure Boot state is not available | Information | Cmdlet missing or other failure |
| `system.system.windows-only` | System health checks are Windows-only | Information | Non-Windows host |

### System Information

| Id | Title | Severity | When |
|---|---|---|---|
| `system.system-information.memory-low` | Low installed memory (N GB) | Warning | Less than 8 GB of RAM |
| `system.system-information.inventory-collected` | System inventory collected | Pass | Inventory read, no warnings |
| `system.system-information.inventory-unavailable` | System inventory is not available | Information | No CIM data (non-Windows, WMI unavailable) |

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. On ARM64, `Win32_Processor.Architecture`
reports 12; `VirtualizationFirmwareEnabled` and some SMBIOS fields may be empty and are then
omitted, not reported as failures. On a non-Windows host the System scanner returns a single
Information finding and System Information reports the inventory as not available.
