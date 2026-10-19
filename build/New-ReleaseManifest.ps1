<#
.SYNOPSIS
    Writes (or verifies) SHA256SUMS for a folder of release artifacts.

.DESCRIPTION
    GNU coreutils format, one line per file: '<64 lowercase hex>  <file name>' (two
    spaces = text mode, as sha256sum prints), LF line endings, ASCII, sorted ordinally by
    name. Covers every regular file directly in -Path except SHA256SUMS itself and any
    -Exclude pattern. Run it LAST, after every other artifact exists.

    Verify on Linux/macOS:   sha256sum -c SHA256SUMS
    Verify on Windows:       ./build/New-ReleaseManifest.ps1 -Path <folder> -Verify
                             or compare (Get-FileHash <file>).Hash by hand.

    Exit code / result: returns the entries; with -Verify throws on any mismatch, missing
    file, or unlisted file.

.PARAMETER Path
    Folder holding the release artifacts (flat).

.PARAMETER OutputPath
    Where to write the manifest. Default <Path>/SHA256SUMS.

.PARAMETER Exclude
    Wildcard file-name patterns to leave out (for example '*.tmp').

.PARAMETER Verify
    Check an existing manifest against the files instead of writing one.

.EXAMPLE
    ./build/New-ReleaseManifest.ps1 -Path release
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $OutputPath,
    [string[]] $Exclude = @(),
    [switch] $Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "New-ReleaseManifest: folder not found: $Path" }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath
if (-not $OutputPath) { $OutputPath = Join-Path $root 'SHA256SUMS' }
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$manifestName = Split-Path -Path $OutputPath -Leaf
$manifestFull = [System.IO.Path]::GetFullPath($OutputPath)

$names = New-Object 'System.Collections.Generic.List[string]'
foreach ($f in (Get-ChildItem -LiteralPath $root -File -Force)) {
    if ([System.IO.Path]::GetFullPath($f.FullName) -eq $manifestFull) { continue }
    if ($f.Name -eq 'SHA256SUMS') { continue }
    $skip = $false
    foreach ($pattern in $Exclude) { if ($f.Name -like $pattern) { $skip = $true } }
    if ($skip) { continue }
    if ($f.Name -match '[\x00-\x1F\\]') { throw "New-ReleaseManifest: unsupported file name '$($f.Name)'." }
    $names.Add($f.Name)
}
$names.Sort([System.StringComparer]::Ordinal)

$entries = @(foreach ($n in $names) {
        [pscustomobject]@{ Name = $n; Sha256 = (Get-OmniSha256Hex -Path (Join-Path $root $n)) }
    })

if ($Verify) {
    if (-not (Test-Path -LiteralPath $OutputPath)) { throw "New-ReleaseManifest: $manifestName not found." }
    $listed = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($OutputPath)) {
        if (-not $line) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64}) [ *](.+)$') { throw "New-ReleaseManifest: malformed line in ${manifestName}: '$line'" }
        $listed[$Matches[2]] = $Matches[1].ToLowerInvariant()
    }
    $problems = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $entries) {
        if (-not $listed.ContainsKey($e.Name)) { $problems.Add("not listed: $($e.Name)") }
        elseif ($listed[$e.Name] -ne $e.Sha256) { $problems.Add("hash mismatch: $($e.Name)") }
    }
    foreach ($k in $listed.Keys) {
        if (-not ($entries | Where-Object { $_.Name -eq $k })) { $problems.Add("listed but missing: $k") }
    }
    if ($problems.Count -gt 0) { throw ("New-ReleaseManifest: verification failed: " + ($problems -join '; ')) }
    Write-Host "${manifestName}: $($entries.Count) file(s) verified."
    return $entries
}

if ($entries.Count -eq 0) { throw "New-ReleaseManifest: no artifacts in $root." }
$text = (@($entries | ForEach-Object { "$($_.Sha256)  $($_.Name)" }) -join "`n") + "`n"
Write-OmniTextFile -Path $OutputPath -Text $text
Write-Host "Wrote $manifestName ($($entries.Count) file(s))."
return $entries
