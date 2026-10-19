<#
.SYNOPSIS
    Writes a CycloneDX 1.5 JSON SBOM for an OmniDiag portable zip, with no external tools.

.DESCRIPTION
    What the SBOM says (and why):
      * metadata.component: OmniDiag itself - version, MIT license, purl
        pkg:github/Chris2003/OmniDiag@<version>, the source repository, and the release zip
        (with its SHA-256) as the distribution.
      * components (type 'file'): every file shipped in the zip, by path inside the package,
        with its SHA-256. All of them are OmniDiag's own MIT-licensed files: OmniDiag
        bundles no third-party runtime code - no binaries, DLLs, or fonts. (PDF reports use
        the PDF standard base-14 fonts by name, never embedded; a branding logo is supplied
        by the user at run time; the GUI uses WPF from Windows.) Re-check this when adding
        any file not written for OmniDiag (Tests/Build.Release.Tests.ps1 fails on bundled
        binaries, libraries, and fonts).
      * components with scope 'excluded': the build/test tools that never ship (Pester,
        PSScriptAnalyzer, the pinned GitHub Actions).
      * services: the optional, user-installed local Ollama endpoint (loopback only, off by
        default) - documented, not shipped.
      * The host runtime (Windows PowerShell 5.1 or PowerShell 7+, .NET, Windows) is a
        prerequisite provided by the machine and is recorded as a property, not a component.

    Deterministic: same zip + version + SOURCE_DATE_EPOCH -> same bytes. serialNumber is a
    UUID (version-5 layout) derived from SHA-256("OmniDiag|<version>|<zip sha256>");
    metadata.timestamp is SOURCE_DATE_EPOCH (else the HEAD commit time, else 1980-01-01).
    The JSON writer is our own (build/ReleaseTools.psm1), so 5.1 and 7 produce the same text.

.PARAMETER ZipPath
    The portable zip (dist/OmniDiag-<version>-portable.zip).

.PARAMETER Version
    Defaults to ModuleVersion in src/OmniDiag.psd1.

.PARAMETER OutputPath
    Default: next to the zip, OmniDiag-<version>.cdx.json.

.EXAMPLE
    ./build/New-Sbom.ps1 -ZipPath dist/OmniDiag-1.0.0-portable.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ZipPath,
    [string] $Version,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

$repoRoot = Split-Path $PSScriptRoot -Parent
$version = Get-OmniReleaseVersion -RepoRoot $repoRoot -Version $Version
$epoch = Get-OmniSourceDateEpoch -RepoRoot $repoRoot
$timestamp = (ConvertFrom-OmniUnixTime -Epoch $epoch).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "New-Sbom: zip not found: $ZipPath" }
$zipFull = (Resolve-Path -LiteralPath $ZipPath).ProviderPath
$zipName = Split-Path -Path $zipFull -Leaf
$zipHash = Get-OmniSha256Hex -Path $zipFull
if (-not $OutputPath) { $OutputPath = Join-Path (Split-Path -Path $zipFull -Parent) "OmniDiag-$version.cdx.json" }
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

$purl = "pkg:github/Chris2003/OmniDiag@$version"
$repoUrl = 'https://github.com/Chris2003/OmniDiag'

# --- Shipped files: hashed from the zip itself (what users actually get) -------
Add-Type -AssemblyName System.IO.Compression
$files = New-Object 'System.Collections.Generic.List[object]'
$stream = [System.IO.File]::OpenRead($zipFull)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        $names = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object { $_.FullName })
        $prefix = ''
        $first = @($names | ForEach-Object { $_.Split('/')[0] } | Sort-Object -Unique)
        if ($first.Count -eq 1 -and @($names | Where-Object { $_.Contains('/') }).Count -eq $names.Count) { $prefix = $first[0] + '/' }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $ms = New-Object System.IO.MemoryStream
            $es = $entry.Open()
            try { $es.CopyTo($ms) } finally { $es.Dispose() }
            $rel = $entry.FullName.Substring($prefix.Length)
            $files.Add([pscustomobject]@{ Path = $rel; Sha256 = (Get-OmniSha256Hex -Bytes $ms.ToArray()) })
            $ms.Dispose()
        }
    } finally { $archive.Dispose() }
} finally { $stream.Dispose() }
if ($files.Count -eq 0) { throw "New-Sbom: $zipName has no files." }

$byPath = @{}
foreach ($f in $files) { $byPath[$f.Path] = $f }
$sortedPaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($k in $byPath.Keys) { $sortedPaths.Add($k) }
$sortedPaths.Sort([System.StringComparer]::Ordinal)

# --- Deterministic serial number (UUID, version-5 layout, from a SHA-256) -------
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $seed = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("OmniDiag|$version|$zipHash")) } finally { $sha.Dispose() }
$u = New-Object byte[] 16
[Array]::Copy($seed, $u, 16)
$u[6] = [byte](($u[6] -band 0x0F) -bor 0x50)
$u[8] = [byte](($u[8] -band 0x3F) -bor 0x80)
$hex = ([System.BitConverter]::ToString($u)).Replace('-', '').ToLowerInvariant()
$serial = 'urn:uuid:{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)

function New-Property { param([string] $Name, [string] $Value) [ordered]@{ name = $Name; value = $Value } }

$fileComponents = @(foreach ($p in $sortedPaths) {
        [ordered]@{
            type      = 'file'
            'bom-ref' = "file:$p"
            name      = $p
            version   = $version
            scope     = 'required'
            hashes    = @([ordered]@{ alg = 'SHA-256'; content = $byPath[$p].Sha256 })
            licenses  = @([ordered]@{ license = [ordered]@{ id = 'MIT' } })
        }
    })

# Build/test tooling: used to lint, test, and package; never shipped.
$excluded = @(
    [ordered]@{
        type = 'library'; 'bom-ref' = 'tool:pester'; name = 'Pester'; scope = 'excluded'
        description = 'PowerShell test framework (CI and development only; not shipped).'
        licenses = @([ordered]@{ license = [ordered]@{ id = 'Apache-2.0' } })
        purl = 'pkg:nuget/Pester'
        properties = @((New-Property 'omnidiag:versionConstraint' '>=5.5.0'), (New-Property 'omnidiag:source' 'PowerShell Gallery'))
    }
    [ordered]@{
        type = 'library'; 'bom-ref' = 'tool:psscriptanalyzer'; name = 'PSScriptAnalyzer'; scope = 'excluded'
        description = 'PowerShell linter (CI only; not shipped).'
        licenses = @([ordered]@{ license = [ordered]@{ id = 'MIT' } })
        purl = 'pkg:nuget/PSScriptAnalyzer'
        properties = @((New-Property 'omnidiag:versionConstraint' '>=1.21.0'), (New-Property 'omnidiag:source' 'PowerShell Gallery'))
    }
    [ordered]@{
        type = 'application'; 'bom-ref' = 'tool:actions-checkout'; name = 'actions/checkout'; version = 'v7.0.1'; scope = 'excluded'
        description = 'GitHub Action used by CI and the release workflow (not shipped).'
        purl = 'pkg:github/actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
    }
    [ordered]@{
        type = 'application'; 'bom-ref' = 'tool:actions-upload-artifact'; name = 'actions/upload-artifact'; version = 'v7.0.1'; scope = 'excluded'
        description = 'GitHub Action used by CI and the release workflow (not shipped).'
        purl = 'pkg:github/actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
    }
)

$bom = [ordered]@{
    '$schema'    = 'http://cyclonedx.org/schema/bom-1.5.schema.json'
    bomFormat    = 'CycloneDX'
    specVersion  = '1.5'
    serialNumber = $serial
    version      = 1
    metadata     = [ordered]@{
        timestamp  = $timestamp
        lifecycles = @([ordered]@{ phase = 'build' })
        tools      = [ordered]@{
            components = @([ordered]@{
                    type        = 'application'
                    author      = 'OmniDiag Contributors'
                    name        = 'New-Sbom.ps1'
                    version     = $version
                    description = 'OmniDiag''s own SBOM generator (build/New-Sbom.ps1); no external tools.'
                })
        }
        component  = [ordered]@{
            type               = 'application'
            'bom-ref'          = $purl
            author             = 'OmniDiag Contributors'
            name               = 'OmniDiag'
            version            = $version
            description        = 'OmniDiag - One Tool. Complete Diagnostics. A local-only, open-source Windows diagnostic utility (PowerShell).'
            licenses           = @([ordered]@{ license = [ordered]@{ id = 'MIT' } })
            copyright          = 'Copyright (c) 2026 OmniDiag Contributors'
            purl               = $purl
            externalReferences = @(
                [ordered]@{ type = 'vcs'; url = $repoUrl }
                [ordered]@{ type = 'website'; url = $repoUrl }
                [ordered]@{
                    type    = 'distribution'
                    url     = "$repoUrl/releases/download/v$version/$zipName"
                    hashes  = @([ordered]@{ alg = 'SHA-256'; content = $zipHash })
                    comment = 'Portable package; the components below are its files.'
                }
            )
        }
        properties = @(
            (New-Property 'omnidiag:package' $zipName)
            (New-Property 'omnidiag:package:sha256' $zipHash)
            (New-Property 'omnidiag:sourceDateEpoch' ([string]$epoch))
            (New-Property 'omnidiag:thirdPartyRuntimeCode' 'none: every shipped file is OmniDiag''s own (MIT); no third-party binaries, libraries, or fonts are bundled')
            (New-Property 'omnidiag:hostRuntime' 'Windows PowerShell 5.1 or PowerShell 7+ on Windows 10/11 (provided by the host, not shipped)')
        )
    }
    components   = @($fileComponents + $excluded)
    services     = @(
        [ordered]@{
            'bom-ref'          = 'service:ollama-local'
            name               = 'Ollama (optional, user-installed)'
            description        = 'Optional local AI analysis over loopback HTTP only; off by default; not shipped.'
            endpoints          = @('http://127.0.0.1:11434')
            authenticated      = $false
            'x-trust-boundary' = $false
        }
    )
    dependencies = @(
        [ordered]@{ ref = $purl; dependsOn = @() }
    )
    compositions = @(
        [ordered]@{ aggregate = 'complete'; assemblies = @($purl); dependencies = @($purl) }
    )
}

$json = (ConvertTo-OmniJson -InputObject $bom) + "`n"
Write-OmniTextFile -Path $OutputPath -Text $json
Write-Host "Wrote SBOM $OutputPath ($($sortedPaths.Count) files, serial $serial)."
return [pscustomobject]@{ Path = $OutputPath; SerialNumber = $serial; Files = $sortedPaths.Count; Timestamp = $timestamp; ZipSha256 = $zipHash }
