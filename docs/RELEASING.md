# Releasing OmniDiag

How a release is cut, what it contains, how signing is set up, why the zip is
reproducible, and how users verify what they downloaded.

## What a release contains

Pushing a tag `v<version>` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml),
which publishes a GitHub release with these assets:

| Asset | Made by | Notes |
|---|---|---|
| `OmniDiag-<version>-portable.zip` | `build/Build-Portable.ps1` | Reproducible; scripts signed and `OmniDiag.cat` included when a certificate is configured |
| `OmniDiag-<version>*.msi` | `build/Build-Msi.ps1` | Per-user installer (only when that script exists) |
| winget manifest (`*.yaml`) | `build/New-WingetManifest.ps1` | Points at the MSI (only when that script exists) |
| `install.ps1` | the repository (signed copy when signing is on) | The quick installer; `releases/latest/download/install.ps1` always points at the newest one |
| `OmniDiag-<version>.cdx.json` | `build/New-Sbom.ps1` | CycloneDX 1.5 SBOM |
| `SHA256SUMS` | `build/New-ReleaseManifest.ps1` | SHA-256 of every asset above, written last |

The release notes are the version's section of [CHANGELOG.md](../CHANGELOG.md)
(`build/Get-ReleaseNotes.ps1`).

## Cutting a release

1. **Bump the version** in `src/OmniDiag.psd1` (`ModuleVersion`, `MAJOR.MINOR.PATCH`,
   optionally `-prerelease`, e.g. `1.0.0-rc.1`).
2. **Update CHANGELOG.md**: add (or rename) the section heading to the exact version and a
   date, e.g. `## 1.0.0 - 2026-11-02` (`## [1.0.0]` also works). A heading that still
   says `unreleased` is refused for tag pushes.
3. Commit, open a pull request, and wait for CI to be green (including the `reproducible`
   and `signing` jobs).
4. Optional dry run: **Actions > Release > Run workflow** on the branch, with tag
   `v<version>`. It builds and tests everything and uploads the assets as the
   `release-assets` workflow artifact; it publishes nothing.
5. **Tag and push** from the merged commit on `main`:

   ```powershell
   git tag -a v1.0.0 -m 'OmniDiag 1.0.0'
   git push origin v1.0.0
   ```

The workflow then:

1. checks that the tag equals `v` + `ModuleVersion` (fails otherwise);
2. extracts the release notes from CHANGELOG.md;
3. runs the full Pester suite (`build/Invoke-Tests.ps1`);
4. signs (only when the signing secrets exist) and builds the portable zip; signing
   always happens on the staging folder **before** zipping;
5. builds the MSI and the winget manifest, when those scripts exist;
6. writes the SBOM, then `SHA256SUMS` last, and verifies it;
7. in a separate `publish` job (the only one with write access to repository contents,
   and only for tag pushes) re-checks `SHA256SUMS` and runs `gh release create`. A tag with
   a `-` (e.g. `v1.0.0-rc.1`) is published as a pre-release.

If anything fails, delete the tag (`git push --delete origin v1.0.0; git tag -d v1.0.0`),
fix, and tag again. Never move a published tag: users and `SHA256SUMS` refer to it.

## Code signing (owner setup)

Signing is a hook: without a certificate the release is built unsigned and everything
else still works (`build/Sign.ps1` prints one line and exits 0).

`build/Sign.ps1`:

- signs every `*.ps1`, `*.psm1`, and `*.psd1` with Authenticode (SHA-256);
- creates a file catalog `OmniDiag.cat` (`New-FileCatalog -CatalogVersion 2`, SHA-256)
  over the whole package and signs it. The catalog is what protects the files Authenticode
  cannot sign: **`.cmd` batch files have no Authenticode format** (there is no SIP for
  them), and XAML, JSON schemas, Markdown, and `VERSION.txt` are covered the same way;
- never prints, logs, or stores the password or the key.

To turn signing on for releases, add to the repository (**Settings > Secrets and
variables > Actions**):

| Name | Kind | Value |
|---|---|---|
| `OMNIDIAG_SIGN_PFX_BASE64` | secret | The code-signing `.pfx` (certificate + private key), base64-encoded |
| `OMNIDIAG_SIGN_PFX_PASSWORD` | secret | The `.pfx` password |
| `OMNIDIAG_SIGN_TIMESTAMP_URL` | variable (optional) | Your CA's timestamp server URL |

```powershell
# Encode the .pfx for the secret (keep the output private; delete it afterwards).
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\secure\omnidiag-sign.pfx')) | Set-Clipboard
```

**Certificate types.** Any certificate with the Code Signing extended key usage
(`1.3.6.1.5.5.7.3.3`) works with `Set-AuthenticodeSignature`:

- an **OV (organization-validated) code-signing certificate** from a public CA - the
  usual choice. Since 2023, CAs issue these keys on hardware (HSM / token / cloud key
  service), so the key may not be exportable to a `.pfx`. Then sign locally (below) or
  use your CA's cloud signing service and adapt the signing step;
- an **EV certificate** - the same, always hardware-bound;
- **Azure Trusted Signing** or another cloud signer - not wired in; it would replace the
  `.pfx` step;
- a **self-signed or internal-CA certificate** - fine for an organization that deploys
  OmniDiag internally and distributes its root/publisher certificate by Group Policy.
  Public users will see the signature as untrusted.

**Timestamping.** Without a timestamp, signatures stop validating when the certificate
expires. Set `OMNIDIAG_SIGN_TIMESTAMP_URL` to your CA's timestamp server (or pass
`-TimestampServer` locally); the default is none, so no network call is made unless you
ask for one.

**Signing locally** (for example with a hardware token in `Cert:\CurrentUser\My`):

```powershell
./build/Build-Portable.ps1 -Version 1.0.0 -KeepStaging -Sign -CertificateThumbprint <thumbprint> -TimestampServer <url>
./build/Test-ReleaseSignature.ps1 -Path dist/OmniDiag-1.0.0-portable
```

or with a `.pfx`: `$env:OMNIDIAG_SIGN_PFX_PASSWORD = '...'` and `-PfxPath <file>`
instead of `-CertificateThumbprint`.

The CI `signing` job proves the hook end to end on every push: it creates a throwaway
self-signed code-signing certificate, trusts it on the runner only, signs a portable
build, checks every signature and the catalog (in the staging folder and in the extracted
zip), and removes the certificate from every store.

## Reproducible builds

Two builds of the same commit produce byte-identical zips. `build/Build-Portable.ps1`:

- writes the zip with `System.IO.Compression` directly (not `Compress-Archive`): file
  entries only, sorted ordinally, forward-slash names under one root folder
  `OmniDiag-<version>-portable/`, one fixed compression level (`Optimal`; or
  `-CompressionLevel NoCompression`), and no OS-specific attributes;
- stamps every entry, and `VERSION.txt`, with **`SOURCE_DATE_EPOCH`** when set, else the
  HEAD commit time (`git log -1 --format=%ct`), else 1980-01-01T00:00:00Z. The release
  workflow sets it to the tagged commit's time;
- packages only git-tracked files (inside a git work tree), byte for byte as checked out.
  `.gitattributes` (`* -text`) makes every checkout identical to what git stores (LF line
  endings, no CRLF conversion on Windows). If an old Windows checkout still has CRLF
  files, the build warns; re-check out the files.

**Runtime caveat.** Deflate output depends on the compression library: Windows
PowerShell 5.1 (.NET Framework) and PowerShell 7 (.NET, whose zlib changes between .NET
versions) can compress the same bytes differently, and .NET records the host OS in each
entry's "version made by" field. So:

- release builds are pinned to **PowerShell 7 on `windows-latest`**;
- the CI `reproducible` job builds twice, in two separate clean checkouts on the same
  host, and fails unless the SHA-256 values match;
- to reproduce a published zip yourself, use PowerShell 7 with the same .NET version (the
  release job summary records it) on Windows, check out the tag, set
  `SOURCE_DATE_EPOCH` to the tagged commit's time, and run
  `./build/Build-Portable.ps1 -Version <version>`. An unsigned build matches an unsigned
  release; signed releases contain signatures only the owner can produce. The files
  inside the zip (and their hashes in the SBOM) are the same on any host.

`New-Sbom.ps1` is deterministic too: its `serialNumber` is derived from the version and
the zip's hash, its timestamp is `SOURCE_DATE_EPOCH`, and it uses its own JSON writer.

## The SBOM

`OmniDiag-<version>.cdx.json` (CycloneDX 1.5) lists:

- OmniDiag itself: version, MIT license, `pkg:github/Chris2003/OmniDiag@<version>`, and
  the zip with its SHA-256;
- every file in the zip with its SHA-256. OmniDiag ships **no third-party runtime code**:
  no DLLs, executables, or fonts (PDF reports use the PDF standard fonts by name; a
  branding logo is supplied at run time; the GUI uses WPF from Windows). A test fails if a
  binary, library, or font is ever added to the package;
- the build and test tools that are **not** shipped (Pester, PSScriptAnalyzer, the pinned
  GitHub Actions), with scope `excluded`;
- the optional, user-installed local Ollama service (loopback only, off by default).

The host runtime (Windows PowerShell 5.1 or PowerShell 7+ on Windows 10/11) is a
prerequisite and recorded as a property.

## Verifying a release

Download the assets you need **and** `SHA256SUMS` from the release page.

**Checksums (Windows PowerShell or PowerShell 7):**

```powershell
$zip = 'OmniDiag-1.0.0-portable.zip'
$listed = ((Get-Content .\SHA256SUMS) -match "  $([regex]::Escape($zip))$" -split '\s+')[0]
$actual = (Get-FileHash .\$zip -Algorithm SHA256).Hash
if ($actual -eq $listed) { 'OK' } else { "MISMATCH: $actual vs $listed" }
```

**Linux / macOS / Git Bash:** `sha256sum -c SHA256SUMS --ignore-missing`

`SHA256SUMS` itself comes from the same release page, so it protects against corrupted or
swapped downloads from mirrors and caches; for protection against a compromised release
page, rely on signatures (below) once signing is configured.

The quick installer (`install.ps1`, default mode) does the checksum step automatically
and refuses to install on any mismatch or a missing entry.

**Signatures (signed releases, Windows):**

```powershell
Expand-Archive .\OmniDiag-1.0.0-portable.zip -DestinationPath C:\Tools
Get-ChildItem C:\Tools\OmniDiag-1.0.0-portable -Recurse -Include *.ps1,*.psm1,*.psd1 |
    Get-AuthenticodeSignature | Where-Object Status -ne 'Valid'    # expect no output
Get-AuthenticodeSignature C:\Tools\OmniDiag-1.0.0-portable\OmniDiag.cat   # Status: Valid
Test-FileCatalog -Path C:\Tools\OmniDiag-1.0.0-portable `
    -CatalogFilePath C:\Tools\OmniDiag-1.0.0-portable\OmniDiag.cat -FilesToSkip OmniDiag.cat, OmniDiagData   # Valid
```

Check that the signer (`(Get-AuthenticodeSignature <file>).SignerCertificate.Subject`) is
the publisher you expect. Run these checks before the first launch: OmniDiag writes an
`OmniDiagData` folder next to itself (hence `-FilesToSkip OmniDiagData`). From a
repository checkout, `./build/Test-ReleaseSignature.ps1 -Path <folder>` runs all of them.

**SBOM:** compare a file's hash in the SBOM with `Get-FileHash <file>` to confirm it is
the shipped version.
