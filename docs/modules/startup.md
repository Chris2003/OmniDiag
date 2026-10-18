# Startup and persistence (`startup`)

Autostart and persistence: what starts with Windows or the user session, from Run keys,
startup commands, the Startup folders, scheduled tasks, and auto-start services, which of
those entries start from locations a standard user can write or use script hosts the way
malware does, and whether the related registry keys are intact.

## Run it

```bat
omnidiag startup
omnidiag startup --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagStartup
Get-OmniDiagStartup -IncludePassed | Format-Table severity, moduleId, title
Invoke-OmniDiagScan -Group startup
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| Registry Health | `startup.registry-health` | Integrity of security-relevant registry keys and values. | Not required | None |
| Scheduled Tasks | `startup.scheduled-tasks` | Enabled and third-party scheduled tasks, with logon/boot persistence and suspicious actions. | Not required (hidden tasks need elevation) | None |
| Service Persistence | `startup.service-persistence` | Auto-start services running from non-standard or user-writable locations, and unquoted service paths. | Not required | None |
| Startup | `startup.startup` | Autostart entries from registry Run keys and startup commands. | Not required | None |
| Startup Folders | `startup.startup-folders` | Per-user and all-users Startup folder entries, with shortcut targets and risky locations. | Not required | None |

## What it checks

"User-writable location" below means any of: `\Users\<name>\AppData\`, `\Users\Public\`,
`\Users\<name>\Downloads|Desktop|Documents\`, any `\Temp\` or `\Tmp\` folder (including
`%SystemRoot%\Temp`), or a file directly in `C:\ProgramData\`. "Suspicious script host"
means: `powershell.exe` / `pwsh.exe` with an encoded command (`-EncodedCommand` or any
prefix, `-ec`) or a URL / download cradle; `wscript.exe` / `cscript.exe`; `mshta.exe`;
`rundll32.exe` or `regsvr32.exe` with a URL, UNC path, or `javascript:` / `vbscript:`.

### Startup (`startup.startup`) - Run keys

- Enumerates the value names under `HKLM` and `HKCU`
  `Software\Microsoft\Windows\CurrentVersion\Run` and `RunOnce`, plus `Win32_StartupCommand`
  (which also covers the Startup folders and the per-user Run keys of loaded profiles).
- Reports the total as an Information finding and flags more than 25 entries (Warning).

### Startup Folders (`startup.startup-folders`)

- Lists every file in the per-user (`[Environment]::GetFolderPath('Startup')`) and
  all-users (`'CommonStartup'`) Startup folders, except `desktop.ini`.
- `.lnk` shortcuts: reads the target and arguments with the `WScript.Shell` COM object
  (the shortcut is loaded, never saved). A shortcut that cannot be read is listed as
  "target not resolved".
- `.url` Internet shortcuts: reads the `URL=` line as text.
- Flags (Warning) a shortcut whose target is in a user-writable location or that uses a
  suspicious script host, an executable or script (`.exe`, `.bat`, `.cmd`, `.vbs`, `.js`,
  `.ps1`, `.hta`, `.scr`, ...) placed directly in a Startup folder, and an Internet
  shortcut that opens a `file:` URL.

### Scheduled Tasks (`startup.scheduled-tasks`)

- Counts enabled tasks and enabled non-Microsoft tasks (task path outside `\Microsoft\`).
- For non-Microsoft tasks with a logon (`MSFT_TaskLogonTrigger`) or boot
  (`MSFT_TaskBootTrigger`) trigger, lists the task, its triggers, and each exec action
  (`Execute` + `Arguments`) as Information.
- Flags (Warning) those logon/boot tasks whose action runs from a user-writable location
  or uses a suspicious script host.
- Flags (Warning) non-Microsoft tasks that run as SYSTEM at logon.

### Service Persistence (`startup.service-persistence`)

- Parses each service's `PathName` into its binary path: quoted or unquoted, with
  arguments, `\SystemRoot\` and `\??\` prefixes, a bare `system32\` path, and environment
  variables. Relative names (no folder) are not judged.
- For automatic-start services (including delayed):
  - binary in a user-writable location -> Warning;
  - otherwise, binary outside `%SystemRoot%`, `%ProgramFiles%`, and `%ProgramFiles(x86)%`
    -> Warning. Microsoft Defender's platform folders under `%ProgramData%\Microsoft\` are
    treated as standard.
- For every service that is not disabled: an unquoted path whose binary path contains a
  space (for example `C:\Program Files\Vendor App\svc.exe -k`) -> Warning, the classic
  unquoted-service-path hijack.
- An Information summary with the counts.

### Registry Health (`startup.registry-health`)

- Checks the Winlogon `Shell` and `Userinit` values (common persistence targets) and that
  the `HKLM` / `HKCU` Run keys are readable, and runs the read-only invalid-registry-entry
  scan (broken startup commands, dead App Paths, orphaned associations, and similar).

## Data sources

| Scanner | Source |
|---|---|
| Startup | Registry `HKLM`/`HKCU` `...\CurrentVersion\Run` and `RunOnce`; `Win32_StartupCommand` |
| Startup Folders | `[Environment]::GetFolderPath('Startup' / 'CommonStartup')`; `Get-ChildItem`; `WScript.Shell` `CreateShortcut(...).TargetPath` / `.Arguments` (read-only); `.url` file text |
| Scheduled Tasks | `Get-ScheduledTask` (`TaskPath`, `TaskName`, `State`, `Principal.UserId`, `Triggers` CIM class names, `Actions.Execute` / `Arguments`) |
| Service Persistence | `Win32_Service` (`Name`, `DisplayName`, `StartMode`, `State`, `PathName`); `%SystemRoot%`, `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramData%` |
| Registry Health | Registry (`Winlogon`, Run keys, and the invalid-entry locations) |

All checks use CIM values, registry data, and CIM class names, never localized display
text. No binary is opened or executed and no signature is verified.

## Elevation

Every scanner runs as a standard user. Scheduled Tasks: tasks whose security descriptor
hides them from standard users are not listed without elevation; the summary finding says
so when the scan is not elevated. Startup reads `HKCU` of the user running the scan.

## Network access

None. Every scanner in this group is local-only. Shortcut targets are read from the
`.lnk` file without resolving them (no network share is contacted), and no file signature
or certificate is checked.

## Findings it can emit

| Finding (Id) | Severity | When |
|---|---|---|
| N startup item(s) found (`startup-items-summary`) | Information | Always (Startup) |
| High number of startup items (`startup-items-high-count`) | Warning | More than 25 Run-key / startup-command entries |
| Startup entries within normal range (`startup-items-ok`) | Pass | No Warning or worse (Startup) |
| N Startup folder item(s) (`startup-folders-summary`) | Information | Always (lists the entries and their targets) |
| N Startup folder item(s) need review (`startup-folders-suspicious-entry`) | Warning | A target in a user-writable location, a suspicious script host, or an executable/script directly in the folder |
| Startup folders not available (`startup-folders-unavailable`) | Information | The folders are not defined on this platform (result Skipped) |
| Startup folder entries look normal (`startup-folders-ok`) | Pass | No Warning or worse (Startup Folders) |
| N enabled scheduled task(s) (`scheduled-tasks-summary`) | Information | Always |
| N non-Microsoft task(s) start at logon or boot (`scheduled-tasks-logon-boot`) | Information | A non-Microsoft task has a logon or boot trigger (lists actions) |
| N logon/boot task(s) with a suspicious action (`scheduled-tasks-suspicious-action`) | Warning | Such a task runs from a user-writable location or uses a suspicious script host |
| N third-party task(s) run as SYSTEM at logon (`scheduled-tasks-system-at-logon`) | Warning | A non-Microsoft task runs as SYSTEM with a logon trigger |
| Scheduled tasks not available (`scheduled-tasks-unavailable`) | Information | `Get-ScheduledTask` is unavailable (result Skipped) |
| Scheduled tasks inventory collected (`scheduled-tasks-ok`) | Pass | No Warning or worse (Scheduled Tasks) |
| Auto-start service locations reviewed (`service-persistence-summary`) | Information | Always (counts) |
| N auto-start service(s) run from a user-writable location (`service-persistence-user-writable`) | Warning | See above |
| N auto-start service(s) run from outside Windows and Program Files (`service-persistence-nonstandard-location`) | Warning | See above |
| N service(s) with an unquoted path containing spaces (`service-persistence-unquoted-path`) | Warning | See above |
| Service inventory not available (`service-persistence-unavailable`) | Information | `Win32_Service` cannot be queried (result Skipped) |
| Auto-start services run from standard locations (`service-persistence-ok`) | Pass | No Warning or worse (Service Persistence) |
| Unexpected Winlogon Shell / Userinit value | Warning | The value differs from the Windows default (Registry Health) |
| N invalid '*category*' registry entries | Warning | The read-only invalid-entry scan found entries (Registry Health) |
| Registry health checks passed | Pass | No Warning or worse (Registry Health) |

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. On other platforms (or when CIM, the task
scheduler cmdlets, or the Startup folders are unavailable) each scanner returns an
Information "not available" finding and a Skipped result instead of failing.
