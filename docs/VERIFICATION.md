# Platform verification

Where OmniDiag has been verified, and how. Phase 4 acceptance (ROADMAP.md): "Win10 / Win11
client behavior verified on real machines or a self-hosted runner, or listed as unverified in
the release notes." This page is that list. Keep it honest: a row is **verified** only when a
named CI job or an attached result file backs it.

GitHub's hosted Windows runners are Windows Server, except `windows-11-arm` (Windows 11 client,
ARM64). Every Windows CI leg prints an `OS:` line (caption, version, build, ProductType: 1 =
client, 3 = server, architecture, PowerShell) in its log and job summary, so the job itself
proves which edition it ran on.

## Matrix

| OS | Edition | Arch | Host | How verified | Privilege | Status |
|---|---|---|---|---|---|---|
| Windows Server (`windows-latest` image) | Datacenter (server, ProductType 3) | x64 | PowerShell 7 | CI `Pester (windows-latest, pwsh)`: suite + coverage gate + elevated `report` check | Elevated | Verified by CI (each run) |
| Windows Server (`windows-latest` image) | Datacenter (server) | x64 | Windows PowerShell 5.1 | CI `Pester (windows-latest, powershell)` | Elevated | Verified by CI (each run) |
| Windows Server (`windows-latest` image) | Datacenter (server) | x64 | PowerShell 7 | CI `Standard user (windows-latest, pwsh)`: suite, `report`, `scan` as a local Users-only account | Standard user | New in Phase 4: verified once the first run is green |
| Windows Server (`windows-latest` image) | Datacenter (server) | x64 | PowerShell 7 | CI `No-network runtime test`, `Performance (soft gate)`, `Portable package` | Elevated | Verified by CI (each run) |
| Windows 11 (`windows-11-arm` image) | Client (ProductType 1; edition in the `OS:` line) | ARM64 | PowerShell 7 | CI `Pester (windows-11-arm, pwsh)` | Elevated | Verified by CI (each run) |
| Windows 11 (`windows-11-arm` image) | Client | ARM64 | Windows PowerShell 5.1 | not run in CI | - | Unverified |
| Windows 11 23H2 / 24H2 | Pro / Enterprise | x64 | PowerShell 7 and 5.1 | owner: `build/Invoke-ClientVerification.ps1` | Standard user and elevated | **Unverified - needs owner run** |
| Windows 10 22H2 | Pro / Enterprise | x64 | Windows PowerShell 5.1 (and 7 if installed) | owner: `build/Invoke-ClientVerification.ps1` | Standard user and elevated | **Unverified - needs owner run** |
| Windows 10 / 11 on a self-hosted runner | any client | x64 | both | not set up (see below) | - | Not available |
| Ubuntu (`ubuntu-latest`) | - | x64 | PowerShell 7 | CI `Pester (ubuntu-latest, pwsh)`: pure logic only; Windows scanners skip | - | Verified by CI (each run); not a supported platform |

Until a Windows 10 / Windows 11 x64 client row has an attached result, the release notes must
say: "Windows 10 22H2 and Windows 11 x64 client editions are not yet verified on real hardware;
CI covers Windows Server x64 and Windows 11 ARM64."

What only a client can show (STATUS.md open risks): battery and Wi-Fi data, Entra ID / Intune
join state, Reliability Monitor history, real crash dumps, client-SKU severities (for example
listening services that are normal on a server), the `.cmd` exit-code pass-through on a desktop,
the real non-elevated exit 4, the GUI on a physical display, Narrator and High Contrast.

## Owner verification run

Takes about 5 minutes per machine. Use the portable zip from the CI `omnidiag-portable`
artifact (or a checkout of the release tag) and extract it to a folder you can write to.

1. **Standard user.** Open a normal Command Prompt (not "Run as administrator"; ideally as a
   real non-admin account) in the extracted folder and run:

   ```bat
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\Invoke-ClientVerification.ps1 -Interactive -Notes "Win10 22H2, Latitude 5420"
   ```

   With PowerShell 7 installed, run it once more with `pwsh.exe` instead of `powershell.exe`
   (the JSON schema check needs PowerShell 7; both hosts are exercised either way).
2. **Elevated.** Open an elevated prompt ("Run as administrator") and run the same command.
3. **Attach** each `verification-results\<timestamp>\client-verification-<timestamp>.json` to
   the verification issue or release PR. The result file holds no computer, user, or domain
   name. The `report` folder next to it does; keep it local, or re-run with `-Redact`.
4. Update the matrix row above: status "Verified (owner, <date>, <build>)" and a link to the
   attached result.

What the script checks (automated, each recorded as Pass / Fail / Skipped):

| Check | Expectation |
|---|---|
| OS | ProductType 1 (client); caption, DisplayVersion, build.UBR, EditionID, architecture recorded |
| Hosts | Windows PowerShell 5.1 and PowerShell 7 (when installed) each run `omnidiag version` and `scan --group system --format json` |
| Launcher | `OmniDiag.cmd version` exits 0; `OmniDiag.cmd scan --range bogus` returns 10 in `%ERRORLEVEL%` |
| Elevation | standard prompt only: `OmniDiag.cmd scan --elevated-only` returns 4 |
| Report | `OmniDiag.cmd report --bundle --output <dir>` exits 0-3 within the 60 s target; HTML, JSON, ZIP exist and are not empty; JSON validates against schema v1 (PowerShell 7); `host.isAdmin` matches the prompt; elevation notices (`*-requires-elevation` Information findings) appear only as a standard user; no module `Failed` |
| GUI | `OmniDiag.cmd gui` shows the OmniDiag window (time to first window recorded; target < 2 s), then it is closed. Skip with `-SkipGui` |

Manual checklist (asked with `-Interactive`, answers stored in the result file):

- [ ] GUI: the dashboard shows a health score and the findings list fills after a scan.
- [ ] GUI: Tab reaches every control; Narrator reads the section names (docs/GUI.md).
- [ ] GUI: High Contrast keeps every text readable.
- [ ] The HTML report opens in the default browser and looks complete.
- [ ] As a standard user: the report says which checks need elevation instead of showing errors.
- [ ] Client-only data looks right: battery, Wi-Fi, BitLocker, Defender, Reliability Monitor.

## How CI covers the standard user

The `standard-user` job (blocking) runs on `windows-latest`:

1. `build/Invoke-AsStandardUser.ps1` creates a local account `odsu-<random>` that is a member
   of Users only, with a random 32-character password generated in memory and never printed.
   It copies the repository and Pester to `C:\omnidiag-su` and grants the account Modify there.
2. Each step runs through a wrapper as that account. Launch: `Start-Process -Credential
   -LoadUserProfile` first; if that is not usable on the runner (probe `cmd /c ver` fails), a
   scheduled task registered with the account's credentials (logon type Password, RunLevel
   Limited) after granting "Log on as a batch job" with `secedit` (restored afterwards).
3. Before running anything the wrapper records `whoami /user /groups /priv`, the token's
   integrity level, and Administrators membership, and refuses to run if it is elevated. After
   every step the parent checks the record (the account's SID, Medium integrity, no
   `S-1-5-32-544` in the token) and stops the job with "SELF-CHECK FAILED" if it does not hold.
4. Steps: the Pester suite (`build/Invoke-Tests.ps1`), `OmniDiag.cmd report --format json,html
   --output <dir>`, `OmniDiag.cmd scan --format json`.
5. `build/Test-PrivilegeReport.ps1` validates, as the runner: exit codes are scan outcomes
   (0-3), the JSON (report and scan stdout) validates against `schemas/omnidiag-report.v1.json`
   with `Test-Json`, the HTML exists and is not empty, `host.isAdmin` is false, every
   `requiresElevation` module is `Skipped` with `skippedReason: RequiresElevation` (no scanner
   declares it today; elevation-dependent data is reported as Information notices such as
   `system.system.tpm-requires-elevation`, and at least one must be present), and no module
   failed with an access-denied error. It then compares with an elevated `report` made on the
   same VM: the same scanners, more elevation notices for the standard user, and at least as
   many modules run when elevated. Everything is uploaded as `standard-user-results`.

The elevated `Pester (windows-latest, pwsh)` leg also runs `report` and checks the elevated
side on its own: `host.isAdmin` true, no RequiresElevation skip, no elevation notice.

## Self-hosted client runner (optional)

A Windows 10 / 11 machine registered as a self-hosted runner with the label `windows-client`
would turn the owner rows into CI rows: add a matrix entry `os: [self-hosted, windows-client]`
for both shells and run `build/Invoke-ClientVerification.ps1 -SkipGui` as a step. Self-hosted
runners on a public repository run code from pull requests; only do this on a disposable VM
and restrict the job to `push` on `main`.
