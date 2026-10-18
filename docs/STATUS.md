# OmniDiag status

Baseline for the v1.0 program. Recorded at commit `ad0a369` (version 0.4.1), 2026-10-18,
from the Phase 0 reconnaissance (repo inventory, build/test/lint run, gap analysis against
the v1.0 specification). The plan to close the gaps is in [ROADMAP.md](ROADMAP.md);
the target design is the "v1.0 target" section of [ARCHITECTURE.md](ARCHITECTURE.md).

**Legend:** ✅ works · 🟡 partial · ❌ missing · 🔴 broken / violates a v1.0 principle

## Summary

| Area | State | Notes |
|---|---|---|
| Build (module import, manifest, parse) | ✅ | 114 script files, 0 parse errors; `Test-ModuleManifest` passes; 68 exported functions |
| Portable package | 🟡 | `build/Build-Portable.ps1` produces a working zip + SHA256, but it isn't reproducible (`Compress-Archive` timestamps/order) |
| Tests | ✅ | 183 tests; CI green on Windows pwsh 7 (181 pass / 2 skip), Windows PowerShell 5.1 (181 / 2), Ubuntu (175 / 8) |
| Coverage (Linux run) | 🟡 | Core 80.7%, Repair 74.9%, Reporting 91.6%. Windows-only branches count as missed on Linux; no coverage gate in CI |
| Lint | 🟡 | PSScriptAnalyzer: 0 errors, 212 warnings, 149 info. Not run in CI, though CONTRIBUTING.md says it must pass |
| Diagnostic coverage vs v1.0 groups | 🟡 | 49 scanners; 10 required sub-items missing, 6 partial (table below) |
| Local-only (principle 1) | 🔴 | Default scans ping `1.1.1.1` and resolve `www.microsoft.com` automatically; no no-network CI test |
| Read-only by default (principle 2) | 🟡 | Repairs are separate, dry-run capable, and confirmed, but interactive only: no `--apply` / `--what-if` CLI. One scanner can run SFC |
| Scriptable (principle 3) | 🔴 | No `omnidiag <verb>` CLI, no exit-code scheme (scans always exit 0), unversioned JSON, no Markdown, no `Get-OmniDiag*` cmdlets |
| Least privilege (principle 4) | 🟡 | Runs as a standard user, skips admin-only work with a notice; no `--elevated-only`; CI runs only elevated |
| Portable (principle 5) | 🟡 | xcopy + zero-footprint mode work; no MSI/winget, no signing, no ARM64 testing |
| GUI | 🟡 | Dashboard, findings, diagnostics, Repair Center, Local AI, dark/light, export. No accessibility work, no keyboard bindings, no high contrast |
| Docs | 🟡 | README, ARCHITECTURE, PORTABLE, SECURITY, CONTRIBUTING, CODE_OF_CONDUCT, CHANGELOG, MIT LICENSE present; no per-module docs, no CLI/exit-code/schema reference |
| Release pipeline | ❌ | No release-on-tag job, no artifact publishing, no installer, no signing hooks |

## Stack and layout

- **Language/runtime:** PowerShell (Windows PowerShell 5.1 and PowerShell 7), WPF GUI with runtime-loaded XAML. About 13.5k lines.
- **Layout:** `OmniDiag.ps1` launcher (376 lines) → `src/OmniDiag.psd1`/`.psm1` (public API) → `src/Core` (2,279) · `src/Modules` (49 scanners, 5,578) · `src/Repair` + `src/Repairs` (engine + 11 repairs, 1,218) · `src/EventLog` (565) · `src/Reporting` (1,090) · `src/UI` (1,450) · `src/Cli` (338). Tests: 24 Pester files, 1,914 lines.
- **Packaging:** `OmniDiag.cmd` / `OmniDiag-GUI.cmd` launchers, `build/Build-Portable.ps1`, `install.ps1` (per-user install that downloads from GitHub).
- **CI:** `.github/workflows/ci.yml` runs Pester on three legs. No lint, coverage, package, or release jobs.
- **License:** MIT (`LICENSE`).

## Diagnostic coverage against the v1.0 module groups

| # | Group / sub-item | State | Where | Data source |
|---|---|---|---|---|
| 1 | OS build, uptime | ✅ | `src/Modules/SystemInformation.psm1:111-130`, `System.psm1:46-59` | `Win32_OperatingSystem` |
| 1 | Hardware summary | ✅ | `SystemInformation.psm1:59-108` | `Win32_ComputerSystem`, `Win32_BIOS`, `Win32_BaseBoard`, `Win32_Processor`, `Win32_VideoController` |
| 1 | Firmware / TPM / Secure Boot | ✅ | `SystemInformation.psm1:82,133-170` | `Win32_BIOS`, `Win32_Tpm`, `Confirm-SecureBootUEFI` |
| 2 | CPU / RAM | ✅ | `Cpu.psm1:49-74`, `Memory.psm1:45-80`, `Performance.psm1:49-94` | `Win32_Processor`, `Get-Counter`, `Win32_OperatingSystem` |
| 2 | Handles | ❌ | — | — |
| 2 | Top consumers | ✅ | `Processes.psm1:~49-67`, `Performance.psm1:97-106` | `Get-Process` |
| 3 | Service state / start type | 🟡 | `Services.psm1:58-68` (counts + auto-start-but-stopped only) | `Win32_Service` |
| 3 | Unsigned / third-party drivers | ❌ | `Drivers.psm1:48` only counts signed drivers | — |
| 3 | Driver / service failures | 🟡 | `Drivers.psm1:56` (`ConfigManagerErrorCode`); SCM 7000/7031/7034 via the event catalog | `Win32_PnPEntity` |
| 4 | Run / RunOnce keys | ✅ | `Startup.psm1:48`, `RegistryHealth.psm1:89` | Registry |
| 4 | Scheduled tasks | 🟡 | `ScheduledTasks.psm1:60-69` (third-party = outside `\Microsoft\`) | `Get-ScheduledTask` |
| 4 | Services as persistence | ❌ | — | — |
| 4 | Startup folders | 🟡 | `Startup.psm1:68` (indirect) | `Win32_StartupCommand` |
| 5 | Critical/Error events grouped, de-duplicated | ✅ | `EventLogs.psm1:98-161`, `src/EventLog/EventLogAnalyzer.psm1:91,140` | `Get-WinEvent` (15 channels) |
| 5 | Known-bad event-ID hints | ✅ | `src/EventLog/EventLogCatalog.psm1` (46 entries incl. 41, 6008, 1001), `ErrorSummary.psm1:62-95` | `Get-WinEvent` |
| 6 | Reliability Monitor data | ❌ | `Reliability.psm1:63-73` counts event IDs instead | — (`Win32_ReliabilityRecords` not used) |
| 6 | Minidump inventory | ❌ | — | — |
| 7 | Volumes / free space | ✅ | `Storage.psm1:110`, `Disk.psm1:123`, `DiskUsage.psm1:63` | `Get-Volume`, `Win32_LogicalDisk` |
| 7 | SMART / health | ✅ | `Storage.psm1:49-97`, `Disk.psm1:105` | `Get-PhysicalDisk`, `Get-StorageReliabilityCounter`, `MSStorageDriver_FailurePredictStatus` |
| 7 | TRIM status | ❌ | — | — |
| 8 | Adapters / IP config | ✅ | `Network.psm1:~60-110`, `IpConfiguration.psm1:49-118` | `Get-NetAdapter`, `Get-NetIPConfiguration`, `Get-NetIPInterface` |
| 8 | DNS | ✅ | `DnsResolver.psm1:40-100` | `Get-DnsClientServerAddress`, `Resolve-DnsName` |
| 8 | Routes | ❌ | — | — |
| 8 | Listening ports + owning process | ❌ | — | — |
| 8 | Proxy | ✅ | `ProxyConfiguration.psm1:39` | Registry + **parses `netsh winhttp show proxy`** |
| 8 | Connectivity tests (user-invoked only) | 🔴 | `Network.psm1:147-160`, `DnsResolver.psm1:93-102` run automatically | .NET `Ping`, `Dns.GetHostEntry` |
| 9 | Last install | 🟡 | `WindowsUpdate.psm1:~50-65` | `Get-HotFix` (QFE only) |
| 9 | Pending reboot | ✅ | `SystemHealth.psm1:51`, `WindowsHealth.psm1` | CBS / WU / PendingFileRenameOperations registry |
| 9 | Failed updates | ❌ | — | — |
| 10 | Defender | ✅ | `Security.psm1:47-87`, `DefenderOnboarding.psm1` | `Get-MpComputerStatus`, registry |
| 10 | Firewall profiles | ✅ | `Security.psm1:90-107`, `FirewallRules.psm1` | `Get-NetFirewallProfile`, `Get-NetFirewallRule` |
| 10 | BitLocker | ✅ | `BitLocker.psm1` | `Get-BitLockerVolume`, FVE policy registry |
| 10 | UAC | ✅ | `Security.psm1:110-126` | `EnableLUA` registry |
| 10 | Local admins | ❌ | — | — |
| 11 | One command → HTML + JSON | ✅ | `OmniDiag.ps1 -Workflow FullScan -Report`, `src/Reporting/Report.psm1` | — |
| 11 | "Safe modules only" set | ❌ | No safe/network flag in manifests; FullScan runs everything | — |
| 11 | Redaction (hosts / users / IPs) | ❌ | Only AI-prompt redaction exists (`src/Core/Ollama.psm1` `Protect-OmniPromptText`) | — |

**Extra scanners** (no v1.0 group): Windows Features, Environment Variables, Installed Software, Benchmark,
GPU, Battery, USB Devices, Printers, Temp Files, Time Synchronization, Active Directory, Entra ID,
Intune/MDM, Browser Diagnostics. All 49 scanners currently declare `RequiresAdmin = $false`.

**Tool-output parsing** (v1.0 prefers documented APIs): `EntraId.psm1:31` (`dsregcmd /status`),
`ProxyConfiguration.psm1:39` (`netsh winhttp`), `WifiNetworks.psm1:51,93` (`netsh wlan`),
`TimeSynchronization.psm1:27` (`w32tm /query /status`), `WindowsHealth.psm1:128` (`sfc /verifyonly`,
matches an English string, so it only works on English Windows).

## Network activity today

| Where | Trigger | Traffic |
|---|---|---|
| `src/Modules/Network.psm1:55,147,152,160` | Automatic whenever the scanner runs (QuickTriage, NetworkConnectivity, Printing, LoginAndIdentity, CloudReadiness, FullScan) | ICMP to gateway and `1.1.1.1`; DNS for `www.microsoft.com` |
| `src/Modules/DnsResolver.psm1:93-102` | Automatic | DNS for `www.microsoft.com` |
| `src/Modules/ActiveDirectory.psm1:53` | Automatic on domain-joined hosts | `Test-ComputerSecureChannel` to a domain controller |
| `src/Core/Ollama.psm1:31,34` | Opt-in (`-AiAnalysis`, `-AiChat`, GUI Local AI) | HTTP to loopback Ollama only; redirects refused |
| `src/Repairs/RunDismRestoreHealth.psm1` | Opt-in repair | DISM may download from Windows Update |
| `install.ps1:26,81` | User runs the installer | Download from GitHub |
| CI (`Tests/Modules.All.Tests.ps1`) | Every Windows CI run | Runs the scanners above live |

## Interfaces

| Requirement | State | Evidence |
|---|---|---|
| `omnidiag <module>`, `report`, `list` | ❌ | Only `OmniDiag.ps1` with PowerShell switches (`-IncludeModule`, `-Workflow`, `-Report`, …) |
| `--format json\|csv\|md\|html` | 🟡 | HTML, JSON, CSV, PDF, ZIP exist (`src/Reporting`); Markdown missing; output only to files |
| Stable, versioned JSON schema | ❌ | `src/Reporting/Json.psm1` dumps the session with `ConvertTo-Json -Depth 12`; no `schemaVersion` anywhere |
| Documented exit codes | ❌ | Only `exit 1` for host/manifest/GUI errors (`OmniDiag.ps1:166,179,219`); a scan always exits 0 |
| PowerShell cmdlets returning objects | 🟡 | `Invoke-OmniDiag` returns a session object; 68 exports are mostly internals; no `Get-OmniDiag*` set |
| `--what-if` / `--apply` | 🟡 | Repair dry-run and confirmations exist (`src/Repair/RepairEngine.psm1`, `src/Cli/OmniRepairConsole.psm1`) but only as an interactive menu |
| `--elevated-only` | ❌ | — |
| `--verbose` + local log file | 🟡 | JSONL logs in `OmniDiagData\logs` (`src/Core/Logging.psm1`); no `--verbose` switch |
| Report redaction | ❌ | — |
| GUI accessibility, keyboard nav, high contrast | ❌ | `src/UI/MainWindow.xaml` has no `AutomationProperties`, no `KeyBinding`s; no high-contrast handling |

## Defects and hygiene found

| Item | State | Where |
|---|---|---|
| Literal U+FEFF in a regex in a file without a BOM; likely breaks `.reg` header stripping on Windows PowerShell 5.1 (unverified on Windows) | 🔴 | `src/Core/RegistryScan.psm1:285` |
| `-BrandLogo` / `-TimeoutSeconds` accepted but unused, so PDF reports never show the logo | 🔴 | `src/Reporting/Pdf.psm1:292-294` |
| Scanner can run SFC (scanners must be read-only) | 🔴 | `src/Modules/WindowsHealth.psm1:124-139` |
| Assigns to automatic `$matches` | 🟡 | `src/Modules/WifiNetworks.psm1:95` |
| Unused `$log` | 🟡 | `src/Modules/Reliability.psm1:46` |
| Documented `RunDism` option never implemented | 🟡 | `src/Modules/WindowsHealth.psm1:12,17` |
| `Get-OmniEventCatalog` never called | 🟡 | `src/EventLog/EventLogCatalog.psm1:221` |
| GUI re-implements the System Information scanner's CIM queries | 🟡 | `src/UI/OmniDiagGui.psm1:258` vs `src/Modules/SystemInformation.psm1:52-135` |
| Very large functions | 🟡 | `Invoke-OmniWindow` 430 lines (`src/UI/OmniDiagGui.psm1:601`), `Export-OmniHtmlReport` 210, `Network` scan 167, `Invoke-OmniRepair` 166 |
| Overlapping scanners | 🟡 | System/SystemInformation, Disk/Storage, SystemHealth/WindowsHealth (pending reboot), Performance/Processes/Cpu/Memory, `Win32_StartupCommand` ×3, `Get-MpComputerStatus` ×2 |
| Stale committed artifact | 🟡 | `dist/OmniDiag-0.1.0-portable.zip` (+ `.sha256`); `dist/` not git-ignored |
| Stale comments / headers / links | 🟡 | `src/Cli/OmniConsole.psm1:3-8`, `src/OmniDiag.psm1:36`, `Tests/Modules.All.Tests.ps1:5`, `CHANGELOG.md` link refs stop at 0.3.2 |
| Tests write `OmniDiagData/` into the repo root | 🟡 | Test isolation (git-ignored, but not cleaned) |
| Lint gate claimed but not enforced | 🟡 | `CONTRIBUTING.md:26,33-35` vs `.github/workflows/ci.yml` |

## What can't be verified on GitHub-hosted runners

- **Windows client SKUs.** Hosted x64 images are Windows Server 2022/2025. Windows 10 22H2 and Windows 11 x64 behavior (battery, Wi-Fi, Entra/Intune, Defender client, the WPF GUI on a real display) needs a self-hosted runner or manual testing.
- **ARM64.** The free `windows-11-arm` runner is available only for public repositories.
- **Standard user.** Hosted runners are elevated; a standard-user leg needs a local non-admin account created during the job.
- **Performance.** 2-vCPU hosted VMs are noisy; timing gates can only be soft.
