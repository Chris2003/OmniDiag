<#
.SYNOPSIS
    Assembles a self-contained, versioned, reproducible OmniDiag portable package
    (folder + zip).

.DESCRIPTION
    OmniDiag already loads every module by path relative to itself (no install to
    PSModulePath), so "portable" is a packaging step: copy the runnable surface into
    a clean staging folder, stamp the version, optionally sign it, and zip it. The
    result extracts and runs in place on any supported Windows host - local-only, no
    remoting, admin optional.

    The package is a WHITELIST of what an end user needs to run OmniDiag; developer
    and repo-only content (Tests, .github, .claude, reports, dist, this build folder)
    is deliberately excluded. Inside a git work tree only TRACKED files are packaged,
    so stray local files never reach a release.

    Reproducibility (docs/RELEASING.md):
      * The zip is written with System.IO.Compression directly (not Compress-Archive):
        file entries only (no directory entries), sorted ordinally by name, forward-slash
        names under one versioned root folder, one fixed compression level, and no
        OS-specific attributes (external attributes are 0).
      * Every entry's timestamp is SOURCE_DATE_EPOCH when set, else the HEAD commit time
        (git log -1 --format=%ct), else 1980-01-01T00:00:00Z. VERSION.txt uses the same
        time instead of the wall clock.
      * File bytes are copied exactly as checked out; .gitattributes ('* -text') makes the
        checkout byte-identical to git on every OS (LF line endings everywhere).
      * Deflate output depends on the runtime: .NET Framework (Windows PowerShell 5.1)
        and each .NET (PowerShell 7) zlib build may compress differently, and .NET writes
        the host OS into the zip's "version made by" field. Release builds are pinned to
        PowerShell 7 on windows-latest; reproducibility is checked by building twice on
        the same host. -CompressionLevel NoCompression removes the deflate dependency.

.PARAMETER OutputDirectory
    Where to write the staging folder and zip. Defaults to <repo>/dist.

.PARAMETER Version
    Package version. Defaults to ModuleVersion in src/OmniDiag.psd1.

.PARAMETER CompressionLevel
    Optimal (default), Fastest, or NoCompression. Fixed per build; never adaptive.

.PARAMETER KeepStaging
    Keep the expanded staging folder next to the zip (handy for inspection / for
    running the packaged copy directly). By default only the zip is kept.

.PARAMETER Unblock
    Run Unblock-File over the staged files before zipping (clears Mark-of-the-Web on
    the build host's own copies; the .cmd launchers already handle this at run time).

.PARAMETER Sign
    Run build/Sign.ps1 on the staging folder BEFORE zipping (scripts + file catalog).
    Without -CertificateThumbprint or -PfxPath, Sign.ps1 does nothing.

.PARAMETER CertificateThumbprint
    Passed to build/Sign.ps1 (certificate in Cert:\CurrentUser\My).

.PARAMETER PfxPath
    Passed to build/Sign.ps1 (password from env OMNIDIAG_SIGN_PFX_PASSWORD).

.PARAMETER TimestampServer
    Passed to build/Sign.ps1 (RFC 3161 / Authenticode timestamp URL; none by default).

.EXAMPLE
    ./build/Build-Portable.ps1

.EXAMPLE
    $env:SOURCE_DATE_EPOCH = '1767225600'; ./build/Build-Portable.ps1 -Version 1.0.0 -KeepStaging
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $Version,
    [ValidateSet('Optimal', 'Fastest', 'NoCompression')]
    [string] $CompressionLevel = 'Optimal',
    [switch] $KeepStaging,
    [switch] $Unblock,
    [switch] $Sign,
    [string] $CertificateThumbprint,
    [string] $PfxPath,
    [string] $TimestampServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

$repoRoot = Split-Path $PSScriptRoot -Parent
$version = Get-OmniReleaseVersion -RepoRoot $repoRoot -Version $Version
$epoch = Get-OmniSourceDateEpoch -RepoRoot $repoRoot
$zipTime = Get-OmniZipTimestamp -Epoch $epoch
Write-Host "Building OmniDiag portable package v$version (source date $($zipTime.ToString('yyyy-MM-ddTHH:mm:ssZ')))" -ForegroundColor Cyan

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

$pkgName = "OmniDiag-$version-portable"
$staging = Join-Path $OutputDirectory $pkgName
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# --- Whitelist: exactly what a user needs to run OmniDiag locally --------------
$include = @(
    'OmniDiag.ps1',
    'OmniDiag.cmd',
    'OmniDiag-GUI.cmd',
    'install.ps1',
    'src',
    'schemas',
    'docs',
    'runbooks',
    'README.md',
    'PORTABLE.md',
    'ROADMAP.md',
    'CHANGELOG.md',
    'LICENSE',
    'SECURITY.md'
)

# Tracked files when this is a git work tree (deterministic, no stray local files);
# otherwise everything under the whitelisted paths.
$files = $null
$tracked = Invoke-OmniGit -RepoRoot $repoRoot -Arguments (@('ls-files', '-z', '--') + $include)
if ($null -ne $tracked) {
    $files = @($tracked.Split([char]0) | Where-Object { $_ } | ForEach-Object { $_.Trim("`n") } | Where-Object {
            $_ -and (Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf)
        })
    if ($files.Count -eq 0) { $files = $null }
}
$source = 'git'
if ($null -eq $files) {
    $source = 'filesystem'
    $rootFull = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/')
    $files = @(foreach ($item in $include) {
            $srcPath = Join-Path $repoRoot $item
            if (Test-Path -LiteralPath $srcPath -PathType Leaf) { $item }
            elseif (Test-Path -LiteralPath $srcPath -PathType Container) {
                Get-ChildItem -LiteralPath $srcPath -Recurse -File -Force | ForEach-Object {
                    $_.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
                }
            }
        })
}
foreach ($item in $include) {
    $present = @($files | Where-Object { $_ -eq $item -or $_.StartsWith("$item/", [System.StringComparison]::Ordinal) })
    if ($present.Count -eq 0) { Write-Warning "Skipping missing item: $item" } else { Write-Host "  + $item" }
}

foreach ($rel in $files) {
    $dest = Join-Path $staging $rel
    $destDir = Split-Path -Path $dest -Parent
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    [System.IO.File]::Copy((Join-Path $repoRoot $rel), $dest, $true)
}
Write-Host "  $($files.Count) files from $source"

# --- Version stamp (deterministic: source date, not the wall clock) ------------
$commit = Invoke-OmniGit -RepoRoot $repoRoot -Arguments @('rev-parse', 'HEAD')
if (-not $commit -or $commit.Trim() -notmatch '^[0-9a-f]{40}$') { $commit = 'unknown' } else { $commit = $commit.Trim() }
$stampText = @(
    "OmniDiag $version"
    "Source date: $($zipTime.ToString('yyyy-MM-ddTHH:mm:ssZ')) (SOURCE_DATE_EPOCH $epoch)"
    "Commit: $commit"
    ''
    'Local-only. No installation. No remoting.'
    ''
    'Quick start:'
    '  * Double-click OmniDiag.cmd       - console scan'
    '  * Double-click OmniDiag-GUI.cmd   - graphical interface'
    '  * From PowerShell:  .\OmniDiag.ps1'
    ''
    'See PORTABLE.md for full usage and fleet-deployment guidance.'
    'Verify this package: docs/RELEASING.md (SHA256SUMS, signatures).'
    ''
) -join "`n"
Write-OmniTextFile -Path (Join-Path $staging 'VERSION.txt') -Text $stampText

if ($Unblock) {
    Get-ChildItem -LiteralPath $staging -Recurse -File | Unblock-File
    Write-Host "  Unblocked staged files (cleared Mark-of-the-Web)."
}

# --- Optional signing: always BEFORE zipping -----------------------------------
$signResult = $null
if ($Sign) {
    $signParams = @{ Path = $staging }
    if ($CertificateThumbprint) { $signParams.CertificateThumbprint = $CertificateThumbprint }
    if ($PfxPath) { $signParams.PfxPath = $PfxPath }
    if ($TimestampServer) { $signParams.TimestampServer = $TimestampServer }
    $signResult = & (Join-Path $PSScriptRoot 'Sign.ps1') @signParams
}

# --- Reproducible zip (archive root contains the versioned folder) -------------
Add-Type -AssemblyName System.IO.Compression
$level = [System.IO.Compression.CompressionLevel]::$CompressionLevel
$zipPath = Join-Path $OutputDirectory "$pkgName.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$stagingFull = [System.IO.Path]::GetFullPath($staging).TrimEnd('\', '/')
$entries = New-Object 'System.Collections.Generic.List[string]'
foreach ($f in (Get-ChildItem -LiteralPath $staging -Recurse -File -Force)) {
    $entries.Add($f.FullName.Substring($stagingFull.Length + 1).Replace('\', '/'))
}
$entries.Sort([System.StringComparer]::Ordinal)

$crlfFiles = New-Object 'System.Collections.Generic.List[string]'
$textExtensions = @('.ps1', '.psm1', '.psd1', '.md', '.xaml', '.json', '.cmd', '.txt')
$fileStream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($rel in $entries) {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $staging $rel))
            if ([System.IO.Path]::GetExtension($rel).ToLowerInvariant() -in $textExtensions -and
                [System.Text.Encoding]::ASCII.GetString($bytes).Contains("`r`n") -and
                -not ($signResult -and $signResult.Signed)) {
                $crlfFiles.Add($rel)
            }
            $entry = $archive.CreateEntry("$pkgName/$rel", $level)
            $entry.LastWriteTime = $zipTime
            # No OS-specific attributes (ExternalAttributes: .NET Framework 4.7.2+ / .NET Core).
            if ($entry.PSObject.Properties['ExternalAttributes']) { $entry.ExternalAttributes = 0 }
            $entryStream = $entry.Open()
            try { $entryStream.Write($bytes, 0, $bytes.Length) } finally { $entryStream.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $fileStream.Dispose() }

if ($crlfFiles.Count -gt 0) {
    Write-Warning ("$($crlfFiles.Count) packaged text file(s) have CRLF line endings, so this zip will not match a clean " +
        "checkout (git stores LF; .gitattributes '* -text'). Re-check out the files (e.g. 'git rm -r --cached . ; git reset --hard') " +
        "before a release build. First: $($crlfFiles[0])")
}

# --- SHA256 sidecar for integrity (GNU format, lowercase hex) ------------------
$hashHex = Get-OmniSha256Hex -Path $zipPath
Write-OmniTextFile -Path "$zipPath.sha256" -Text "$hashHex  $pkgName.zip`n"

if (-not $KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force }

$result = [pscustomobject]@{
    Version         = $version
    Package         = $zipPath
    Staging         = $(if ($KeepStaging) { $staging } else { $null })
    SizeKB          = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
    Sha256          = $hashHex.ToUpperInvariant()
    Entries         = $entries.Count
    SourceDateEpoch = $epoch
    Commit          = $commit
    CompressionLevel = $CompressionLevel
    Signed          = [bool]($signResult -and $signResult.Signed)
}
Write-Host ""
Write-Host "Portable package built:" -ForegroundColor Green
$result | Format-List | Out-String | Write-Host
return $result
