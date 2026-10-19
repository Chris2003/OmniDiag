<#
.SYNOPSIS
    Validates the generated winget manifest against the official v1.6.0 JSON schemas.

.DESCRIPTION
    For the three files New-WingetManifest.ps1 writes (version, installer, defaultLocale):
      1. parses the YAML (the subset our generator writes; build/OmniDiag.Installer.psm1)
         and re-serializes it, which must give the identical bytes (deterministic output,
         nothing the parser misread);
      2. validates each document with Test-Json against manifest.<type>.1.6.0.json from
         -SchemaDirectory (the official schemas from microsoft/winget-cli; CI downloads
         them - this script never touches the network);
      3. checks the files agree: PackageIdentifier, PackageVersion, ManifestVersion 1.6.0,
         DefaultLocale = PackageLocale, InstallerType msi, Scope user, Commands omnidiag,
         and every InstallerUrl is the GitHub release URL for v<version>;
      4. with -InstallerDirectory, recomputes every InstallerSha256 from the MSI next to it.

    Needs PowerShell 7 (Test-Json). Exit code 0 = valid, 1 = invalid, 2 = could not run.
    'winget validate' (when winget exists) is run separately by CI.

.PARAMETER ManifestDirectory
    Folder with the three .yaml files.

.PARAMETER SchemaDirectory
    Folder with manifest.version.1.6.0.json, manifest.installer.1.6.0.json, and
    manifest.defaultLocale.1.6.0.json.

.PARAMETER InstallerDirectory
    Optional folder holding the MSIs the manifest describes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ManifestDirectory,
    [Parameter(Mandatory)][string] $SchemaDirectory,
    [string] $InstallerDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) { Write-Host 'Test-WingetManifest needs PowerShell 7 (Test-Json).'; exit 2 }
Import-Module (Join-Path $PSScriptRoot 'OmniDiag.Installer.psm1') -DisableNameChecking
$constants = Get-OmniInstallerConstant
$id = $constants.PackageIdentifier
$problems = [System.Collections.Generic.List[string]]::new()

$files = [ordered]@{
    version       = Join-Path $ManifestDirectory "$id.yaml"
    installer     = Join-Path $ManifestDirectory "$id.installer.yaml"
    defaultLocale = Join-Path $ManifestDirectory "$id.locale.en-US.yaml"
}
$docs = @{}
foreach ($kind in $files.Keys) {
    $path = $files[$kind]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $problems.Add("missing $path"); continue }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $problems.Add("$kind has a BOM") }
    if (@($bytes | Where-Object { $_ -gt 0x7E -or ($_ -lt 0x20 -and $_ -ne 0x0A) }).Count -gt 0) { $problems.Add("$kind is not plain ASCII with LF line endings") }
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    try {
        $doc = ConvertFrom-OmniWingetYaml -Yaml $text
    } catch { $problems.Add("$kind does not parse: $($_.Exception.Message)"); continue }
    $docs[$kind] = $doc
    if ((ConvertTo-OmniWingetYaml -Manifest $doc) -ne $text) { $problems.Add("$kind does not round-trip byte for byte") }

    $schemaPath = Join-Path $SchemaDirectory "manifest.$kind.1.6.0.json"
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { Write-Host "Schema not found: $schemaPath"; exit 2 }
    $json = $doc | ConvertTo-Json -Depth 10
    $schemaErrors = $null
    $ok = Test-Json -Json $json -Schema ([System.IO.File]::ReadAllText($schemaPath)) -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if (-not $ok) {
        $problems.Add("$kind fails manifest.$kind.1.6.0.json: " + (@($schemaErrors | ForEach-Object { $_.Exception.Message }) -join ' | '))
    } else { Write-Host "[winget] $kind valid against manifest.$kind.1.6.0.json" }
}

if ($docs.Count -eq 3) {
    $v = $docs['version']; $inst = $docs['installer']; $loc = $docs['defaultLocale']
    foreach ($d in @($v, $inst, $loc)) {
        if ($d['PackageIdentifier'] -ne $id) { $problems.Add("PackageIdentifier '$($d['PackageIdentifier'])' is not $id") }
        if ($d['PackageVersion'] -ne $v['PackageVersion']) { $problems.Add('PackageVersion differs between files') }
        if ($d['ManifestVersion'] -ne '1.6.0') { $problems.Add("ManifestVersion '$($d['ManifestVersion'])' is not 1.6.0") }
    }
    $ver = [string]$v['PackageVersion']
    if ($v['DefaultLocale'] -ne $loc['PackageLocale']) { $problems.Add('DefaultLocale does not match PackageLocale') }
    if ($inst['InstallerType'] -ne 'msi') { $problems.Add('InstallerType is not msi') }
    if ($inst['Scope'] -ne 'user') { $problems.Add('Scope is not user') }
    if (@($inst['Commands']) -notcontains 'omnidiag') { $problems.Add('Commands does not list omnidiag') }
    if ($loc['License'] -ne 'MIT') { $problems.Add('License is not MIT') }
    foreach ($i in @($inst['Installers'])) {
        $prefix = "$($constants.RepositoryUrl)/releases/download/v$ver/"
        $url = [string]$i['InstallerUrl']
        if (-not $url.StartsWith($prefix, [System.StringComparison]::Ordinal)) { $problems.Add("InstallerUrl '$url' is not under $prefix") }
        $name = $url.Substring($url.LastIndexOf('/') + 1)
        if ($name -ne "OmniDiag-$ver-$($i['Architecture']).msi") { $problems.Add("InstallerUrl file '$name' does not match the architecture $($i['Architecture'])") }
        if ($InstallerDirectory) {
            $msi = Join-Path $InstallerDirectory $name
            if (-not (Test-Path -LiteralPath $msi -PathType Leaf)) { $problems.Add("installer $msi not found") }
            elseif ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -ne $i['InstallerSha256']) { $problems.Add("InstallerSha256 does not match $msi") }
        }
    }
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "::error::winget manifest: $p" }
    exit 1
}
Write-Host "[winget] Manifest in $ManifestDirectory is valid (schemas v1.6.0, consistency, determinism)."
exit 0
