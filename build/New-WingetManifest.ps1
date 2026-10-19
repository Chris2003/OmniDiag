<#
.SYNOPSIS
    Writes the winget manifest (v1.6.0, multi-file) for the OmniDiag MSI release.

.DESCRIPTION
    Generates the three files winget-pkgs expects for Chris2003.OmniDiag:
      Chris2003.OmniDiag.yaml               (version)
      Chris2003.OmniDiag.installer.yaml     (installer: msi, Scope user, Commands omnidiag)
      Chris2003.OmniDiag.locale.en-US.yaml  (defaultLocale: MIT, descriptions, URLs)
    InstallerUrl is https://github.com/Chris2003/OmniDiag/releases/download/v<ver>/<msi>;
    InstallerSha256 is computed from each -InstallerPath; ProductCode is read from each MSI
    (Windows Installer COM, Windows only) unless -ProductCode is given (tests, other OSes).
    The architecture comes from the file name (OmniDiag-<ver>-<arch>.msi) unless
    -Architecture is given.

    Output is deterministic: same inputs, byte-identical files (no dates; LF; ASCII;
    UTF-8 without BOM). build/Test-WingetManifest.ps1 validates it against the official
    JSON schemas. Submitting to microsoft/winget-pkgs is a manual pull request by the
    owner (docs/INSTALLER.md). No network access.

    Works on Windows PowerShell 5.1 and PowerShell 7+. Exit code 0 on success, 1 on failure.

.PARAMETER Version
    Package version, x.y.z (the release tag without 'v').

.PARAMETER InstallerPath
    One or more built MSIs (e.g. dist/OmniDiag-1.0.0-x64.msi, dist/OmniDiag-1.0.0-arm64.msi).

.PARAMETER OutputDirectory
    Folder for the three .yaml files (created; existing manifest files are replaced).

.PARAMETER ProductCode
    ProductCode per -InstallerPath (same order), instead of reading the MSI.

.PARAMETER Architecture
    Architecture per -InstallerPath (same order), instead of parsing the file name.

.PARAMETER UpgradeCode
    UpgradeCode for AppsAndFeaturesEntries. Default: read from the MSI, else the constant
    in build/OmniDiag.Installer.psm1.

.PARAMETER PassThru
    Also return the manifest dictionaries.

.EXAMPLE
    ./build/New-WingetManifest.ps1 -Version 1.0.0 -InstallerPath dist/OmniDiag-1.0.0-x64.msi -OutputDirectory dist/winget
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Version,
    [Parameter(Mandatory)][string[]] $InstallerPath,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [string[]] $ProductCode,
    [string[]] $Architecture,
    [string] $UpgradeCode,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'OmniDiag.Installer.psm1') -DisableNameChecking
$constants = Get-OmniInstallerConstant
$utf8 = [System.Text.UTF8Encoding]::new($false)
$exitCode = 0

try {
    if (-not (Test-OmniVersionString $Version)) { throw "-Version '$Version' must be x.y.z." }
    $paths = @($InstallerPath | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    if ($ProductCode -and @($ProductCode).Count -ne $paths.Count) { throw '-ProductCode needs one value per -InstallerPath.' }
    if ($Architecture -and @($Architecture).Count -ne $paths.Count) { throw '-Architecture needs one value per -InstallerPath.' }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $path = $paths[$i]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Installer not found: $path" }
        $full = (Resolve-Path -LiteralPath $path).ProviderPath
        $fileName = [System.IO.Path]::GetFileName($full)
        $arch = if ($Architecture) { [string]$Architecture[$i] } elseif ($fileName -match '-(x64|arm64|x86)\.msi$') { $Matches[1] } else { $null }
        if (-not $arch) { throw "Cannot tell the architecture of '$fileName' (expected OmniDiag-<ver>-<x64|arm64>.msi); pass -Architecture." }
        if ($fileName -notmatch [regex]::Escape("-$Version-")) { throw "Installer '$fileName' does not carry version $Version in its name." }
        $code = if ($ProductCode) { [string]$ProductCode[$i] } else { $null }
        if (-not $code) {
            # Read from the MSI (Windows only). With -ProductCode the MSI is not opened.
            $info = Get-OmniMsiInfo -Path $full
            $code = $info.ProductCode
            if (-not $UpgradeCode) { $UpgradeCode = $info.UpgradeCode }
            if ($info.ProductVersion -ne $Version) { throw "'$fileName' has ProductVersion $($info.ProductVersion), not $Version." }
        }
        $entries.Add(@{
                Architecture = $arch.ToLowerInvariant()
                FileName     = $fileName
                Sha256       = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
                ProductCode  = $code
            })
    }
    $archs = @($entries | ForEach-Object { $_.Architecture })
    if (@($archs | Select-Object -Unique).Count -ne $archs.Count) { throw "Two installers share an architecture: $($archs -join ', ')." }
    if (-not $UpgradeCode) { $UpgradeCode = $constants.UpgradeCode }

    $set = Get-OmniWingetManifestSet -Version $Version -Installer $entries.ToArray() -UpgradeCode $UpgradeCode
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $id = $constants.PackageIdentifier
    $files = [ordered]@{
        version       = Join-Path $OutputDirectory "$id.yaml"
        installer     = Join-Path $OutputDirectory "$id.installer.yaml"
        defaultLocale = Join-Path $OutputDirectory "$id.locale.en-US.yaml"
    }
    foreach ($kind in $files.Keys) {
        $yaml = ConvertTo-OmniWingetYaml -Manifest $set[$kind]
        [System.IO.File]::WriteAllText($files[$kind], $yaml, $utf8)
        Write-Host "[winget] Wrote $($files[$kind])"
    }
    $out = [ordered]@{
        PackageIdentifier = $id
        Version           = $Version
        OutputDirectory   = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
        Files             = @($files.Values)
        Installers        = @($entries | ForEach-Object { [pscustomobject]$_ })
    }
    if ($PassThru) { $out['Manifests'] = $set }
    [pscustomobject]$out
} catch {
    Write-Host "::error::New-WingetManifest: $($_.Exception.Message)"
    $exitCode = 1
}
if ($exitCode -ne 0) { exit $exitCode }
