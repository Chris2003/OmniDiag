<#
.SYNOPSIS
    Assembles a self-contained, versioned OmniDiag portable package (folder + zip).

.DESCRIPTION
    OmniDiag already loads every module by path relative to itself (no install to
    PSModulePath), so "portable" is a packaging step: copy the runnable surface into
    a clean staging folder, stamp the version, and zip it. The result extracts and
    runs in place on any supported Windows host - local-only, no remoting, admin
    optional.

    The package is a WHITELIST of what an end user needs to run OmniDiag; developer
    and repo-only content (Tests, .github, .claude, reports, dist, this build folder)
    is deliberately excluded.

.PARAMETER OutputDirectory
    Where to write the staging folder and zip. Defaults to <repo>/dist.

.PARAMETER KeepStaging
    Keep the expanded staging folder next to the zip (handy for inspection / for
    running the packaged copy directly). By default only the zip is kept.

.PARAMETER Unblock
    Run Unblock-File over the staged files before zipping (clears Mark-of-the-Web on
    the build host's own copies; the .cmd launchers already handle this at run time).

.EXAMPLE
    ./build/Build-Portable.ps1

.EXAMPLE
    ./build/Build-Portable.ps1 -KeepStaging
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [switch] $KeepStaging,
    [switch] $Unblock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $repoRoot 'src/OmniDiag.psd1'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Cannot find the module manifest at: $manifestPath"
}
$version = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
Write-Host "Building OmniDiag portable package v$version" -ForegroundColor Cyan

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$pkgName = "OmniDiag-$version-portable"
$staging = Join-Path $OutputDirectory $pkgName
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# --- Whitelist: exactly what a user needs to run OmniDiag locally --------------
$include = @(
    'OmniDiag.ps1',
    'OmniDiag.cmd',
    'OmniDiag-GUI.cmd',
    'src',
    'docs',
    'README.md',
    'PORTABLE.md',
    'ROADMAP.md',
    'CHANGELOG.md',
    'LICENSE',
    'SECURITY.md'
)

foreach ($item in $include) {
    $srcPath = Join-Path $repoRoot $item
    if (-not (Test-Path -LiteralPath $srcPath)) {
        Write-Warning "Skipping missing item: $item"
        continue
    }
    Copy-Item -LiteralPath $srcPath -Destination $staging -Recurse -Force
    Write-Host "  + $item"
}

# --- Version stamp -------------------------------------------------------------
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
@"
OmniDiag $version
Portable build: $stamp

Local-only. No installation. No remoting.

Quick start:
  * Double-click OmniDiag.cmd       - console scan
  * Double-click OmniDiag-GUI.cmd   - graphical interface
  * From PowerShell:  .\OmniDiag.ps1

See PORTABLE.md for full usage and fleet-deployment guidance.
"@ | Set-Content -LiteralPath (Join-Path $staging 'VERSION.txt') -Encoding UTF8

if ($Unblock) {
    Get-ChildItem -LiteralPath $staging -Recurse -File | Unblock-File
    Write-Host "  Unblocked staged files (cleared Mark-of-the-Web)."
}

# --- Zip (archive root contains the versioned folder) --------------------------
$zipPath = Join-Path $OutputDirectory "$pkgName.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path $staging -DestinationPath $zipPath -CompressionLevel Optimal

# --- SHA256 sidecar for integrity ---------------------------------------------
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
"$hash  $pkgName.zip" | Set-Content -LiteralPath "$zipPath.sha256" -Encoding ascii

if (-not $KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force }

$result = [pscustomobject]@{
    Version = $version
    Package = $zipPath
    SizeKB  = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
    Sha256  = $hash
}
Write-Host ""
Write-Host "Portable package built:" -ForegroundColor Green
$result | Format-List | Out-String | Write-Host
return $result
