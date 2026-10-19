# Installer (per-user MSI) and winget

OmniDiag ships three ways. Pick one per machine:

| Way | Where it goes | Admin | Updates |
|---|---|---|---|
| **MSI** (this page) | `%LOCALAPPDATA%\Programs\OmniDiag`, Start menu, `omnidiag` on PATH | No | Install the newer MSI, or `winget upgrade` |
| Portable zip ([PORTABLE.md](../PORTABLE.md)) | Any folder or USB stick; nothing else on the host | No | Replace the folder |
| `install.ps1` quick installer | `%LOCALAPPDATA%\Programs\OmniDiag` | No | Run it again |

The MSI and `install.ps1` use the same folder. Do not mix them: uninstall the MSI before
using `install.ps1`, and remove an `install.ps1` copy (it keeps a dated backup) before
installing the MSI.

## Install

Download `OmniDiag-<version>-x64.msi` (or `-arm64.msi` on Windows 11 ARM64) from the
[Releases](https://github.com/Chris2003/OmniDiag/releases) page and double-click it. There
are no dialogs to answer and no UAC prompt; Windows shows a short progress bar. Silent:

```cmd
msiexec /i OmniDiag-1.0.0-x64.msi /qn
```

With winget (once the package is published, see below):

```cmd
winget install Chris2003.OmniDiag
```

Then open a **new** terminal (the PATH change reaches new processes only) and run:

```cmd
omnidiag version
```

The MSI is not code-signed yet (decision 8: signing hooks only for v1.0), so SmartScreen
may ask for confirmation on first run of the downloaded file.

## What the MSI installs

Everything is per user. The package is `Scope="perUser"`: it sets no `ALLUSERS`, marks
itself as not needing elevation, and refuses `ALLUSERS` given on the command line.

| Item | Location |
|---|---|
| Application files (the portable payload, minus `install.ps1`) | `%LOCALAPPDATA%\Programs\OmniDiag` |
| `omnidiag` command | `%LOCALAPPDATA%\Programs\OmniDiag\bin\omnidiag.cmd` |
| User PATH entry (appended last) | `%LOCALAPPDATA%\Programs\OmniDiag\bin` in `HKCU\Environment\Path` |
| Start menu: **OmniDiag** (GUI) and **OmniDiag (console)** | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\OmniDiag` |
| Installed-mode marker | `%LOCALAPPDATA%\Programs\OmniDiag\.omnidiag-installed` |
| Component key paths | `HKCU\Software\OmniDiag\Installer` |
| Apps & features entry | `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<ProductCode>` |

Nothing goes to Program Files, the all-users Start menu, or `HKLM`. (Windows Installer
itself keeps its usual per-user product registration and a cached copy of the MSI; it
removes both on uninstall.) The MSI has no custom actions, runs no scripts, installs no
service or scheduled task, makes no network connection, and uses no WiX extension. Files
installed by Windows Installer carry no Mark-of-the-Web, so nothing needs unblocking.

### Why `bin\omnidiag.cmd` and not the install folder on PATH

`cmd.exe` and PowerShell find `omnidiag` by trying each `PATHEXT` extension (`.COM;.EXE;
.BAT;.CMD;...`) in every PATH folder, so `omnidiag` resolves to `omnidiag.cmd`; file names
are case-insensitive. If the install folder itself were on PATH, PowerShell would find
`OmniDiag.ps1` there first (it runs scripts found on PATH ahead of `PATHEXT` matches in the
same folder), which would start the classic console instead of the CLI and depend on the
execution policy. So only `bin` is on PATH, and `bin\omnidiag.cmd` hands over to
`..\OmniDiag.cmd` without `call` (arguments are not re-parsed and the exit code is passed
through). No `omnidiag.exe` stub is needed: the winget `Commands` entry is metadata, and an
MSI is responsible for its own PATH, which this one sets. A double-click on the Start menu
entries runs the launchers exactly as in the portable folder.

## Where data goes (installed mode)

The portable rule "everything next to the tool" is kept for the zip, but an installed copy
stores its data in **`%LOCALAPPDATA%\OmniDiag\Data`** (logs, sessions, reports, registry
backups, scratch, module cache) instead of `<install folder>\OmniDiagData`:

- upgrades and uninstall replace or remove exactly the files the MSI installed and never
  touch reports or logs;
- uninstall leaves no stray `OmniDiagData` folder inside `Programs\OmniDiag`, so the
  install folder disappears completely;
- it is the usual Windows place for per-user application data.

How it works: the MSI installs a `.omnidiag-installed` marker next to the launchers. When
it is present, `OmniDiag.cmd` / `OmniDiag-GUI.cmd` set `OMNIDIAG_DATA` to
`%LOCALAPPDATA%\OmniDiag\Data`, and `src/Core/Paths.psm1` resolves the same folder
(reported as `Source = Installed`) when OmniDiag is started some other way. The portable
zip never contains the marker, so portable mode is unchanged. An explicit `OMNIDIAG_DATA`
still wins when OmniDiag is started without the launchers.

**Uninstall keeps `%LOCALAPPDATA%\OmniDiag\Data`** (your reports). Delete it yourself if
you no longer need it:

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\OmniDiag" -Recurse
```

## Upgrade

Installing a newer MSI upgrades in place (`MajorUpgrade`: the old version is removed
first, then the new one installed; the data folder is untouched). Installing an older MSI
over a newer one is refused. Installing the other architecture's MSI of the same version
replaces the installed one. With winget: `winget upgrade Chris2003.OmniDiag`.

## Uninstall

Any of:

- **Settings > Apps > Installed apps > OmniDiag > Uninstall**
- `msiexec /x OmniDiag-1.0.0-x64.msi /qn` (or `msiexec /x {ProductCode} /qn`)
- `winget uninstall Chris2003.OmniDiag`

Uninstall removes the application files and folders, the Start menu folder, the PATH entry
(only that entry; the rest of your PATH is untouched), the Apps & features entry, and
`HKCU\Software\OmniDiag\Installer`. It keeps `%LOCALAPPDATA%\OmniDiag\Data` (see above).
`%LOCALAPPDATA%\Programs` is removed only if it ends up empty.

## Architectures

Two MSIs are built from the same architecture-neutral payload (PowerShell scripts):
`-x64.msi` and `-arm64.msi`. They differ only in the MSI platform and ProductCode. Windows
11 ARM64 can install either; the arm64 one lets winget offer a native installer
(decision 6). Windows 10 22H2 x64 and Windows 11 x64 use the x64 MSI.

## Building the MSI

Requirements: Windows, the .NET SDK (8 or later), and WiX Toolset **5.0.2**:

```powershell
dotnet tool install --global wix --version 5.0.2
./build/Build-Msi.ps1 -Version 1.0.0 -OutputDirectory dist
```

`-Version` must equal `ModuleVersion` in `src/OmniDiag.psd1` (x.y.z). The script builds the
portable zip with `build/Build-Portable.ps1` (or takes `-PayloadZip`), stages it, generates
the file list (`OmniDiag.Payload.wxs`: one component per folder, HKCU key path, name-based
component GUIDs), runs `wix build` for each `-Platform` (default `x64, arm64`), and reads
each MSI back to check ProductVersion, UpgradeCode, ProductCode, no `ALLUSERS`, and the
"elevation not required" flag. It writes `dist/OmniDiag-<version>-<platform>.msi`, returns
one object per MSI (Path, ProductCode, Sha256, ...), and exits 1 on any failure.
`-GenerateOnly` stops before WiX (any OS) and keeps the staged files for inspection.

Stable identifiers:

- **UpgradeCode** `{7A225708-9A90-4726-8BE4-3480CB561715}` - never changes
  (`installer/OmniDiag.wxs`, `build/OmniDiag.Installer.psm1`; a test pins it).
- **ProductCode** - a name-based (UUID v5) GUID of `product:<version>:<platform>`: new for
  every version, identical for every rebuild of the same version.
- **Component GUIDs** - UUID v5 of each folder's relative path.

The MSI file itself is not byte-reproducible (Windows Installer stamps creation times), so
release checksums are taken from the built files.

Local install test (installs, checks, uninstalls; uses your profile):

```powershell
./build/Test-MsiInstall.ps1 -MsiPath dist/OmniDiag-1.0.0-x64.msi -OutputDirectory test-results/msi
```

### Licensing of the build tool

The MSI is built with **WiX Toolset v5.0.2**, licensed under the Microsoft Reciprocal
License (**MS-RL**). WiX is a build-time tool only: it is not part of this repository, not
redistributed, and not shipped in the MSI (the package has no custom actions or WiX
extensions, so no WiX binaries are embedded). OmniDiag stays MIT. The version is pinned to
5.0.2 on purpose: WiX v6 and later add the Open Source Maintenance Fee for some users,
which is a financial decision this project has not made. Do not upgrade WiX past v5 without
the owner's approval. See also [CREDITS.md](../CREDITS.md).

## winget manifest

```powershell
./build/New-WingetManifest.ps1 -Version 1.0.0 -InstallerPath dist/OmniDiag-1.0.0-x64.msi, dist/OmniDiag-1.0.0-arm64.msi -OutputDirectory dist/winget
```

writes the three-file manifest (schema v1.6.0) for `Chris2003.OmniDiag`:

| File | Content |
|---|---|
| `Chris2003.OmniDiag.yaml` | version manifest |
| `Chris2003.OmniDiag.installer.yaml` | `InstallerType: msi`, `Scope: user`, `Commands: [omnidiag]`, one entry per MSI with the GitHub release URL (`.../releases/download/v<version>/<msi>`), SHA256, ProductCode, UpgradeCode |
| `Chris2003.OmniDiag.locale.en-US.yaml` | publisher, MIT license, descriptions, URLs |

The ProductCode is read from each MSI (Windows Installer COM); `-ProductCode` supplies it
instead (tests, non-Windows). The output is deterministic (no dates; ASCII; LF).
`build/Test-WingetManifest.ps1` re-parses the YAML, validates it against the official JSON
schemas (`manifest.<type>.1.6.0.json` from microsoft/winget-cli; CI downloads them), checks
that the files agree, and recomputes the SHA256s.

### Submitting to winget (owner, manual)

Publishing to the community repository is a pull request the owner opens; nothing is
submitted automatically.

1. Tag and publish the release so the MSIs exist at their release URLs (the manifest's
   SHA256s must match those exact files).
2. Take `dist/winget` from the release workflow's artifacts (or regenerate it from the
   downloaded release MSIs with the command above).
3. On Windows: `winget validate --manifest dist/winget`. Optionally test the install in
   Windows Sandbox: `winget settings --enable LocalManifestFiles` (admin), then
   `winget install --manifest dist/winget`, run `omnidiag version` in a new terminal, and
   `winget uninstall Chris2003.OmniDiag`.
4. Fork [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs), copy the three
   files to `manifests/c/Chris2003/OmniDiag/<version>/`, commit, and open a pull request
   (one package version per PR). Sign the Microsoft CLA when the bot asks.
5. Wait for the validation pipeline and moderator review; answer any labels it adds.
   Later versions follow the same steps (or `wingetcreate update Chris2003.OmniDiag`).

## CI

The `installer` job in `.github/workflows/ci.yml` (windows-latest, blocking) installs WiX
5.0.2, builds both MSIs, runs ICE validation (report only), and runs
`build/Test-MsiInstall.ps1` twice: as the runner and, through
`build/Invoke-AsStandardUser.ps1`, as a throwaway standard user. Each run installs with
`msiexec /i /qn`, checks the files (and that the count matches the MSI's File table),
that nothing went to Program Files or `HKLM`, the `HKCU` Apps & features entry and
per-user assignment, the shortcuts and their targets, the user PATH, `omnidiag version` in
a new `cmd.exe` and a new Windows PowerShell whose PATH is re-read from the registry, and
the data location; then uninstalls and checks that everything except the data folder is
gone, including the PATH entry. It then generates the winget manifest, validates it against
the official schemas, and runs `winget validate` when the runner has winget (report only).
The `installer-arm64` job (windows-11-arm, soft) builds and tests the arm64 MSI.
