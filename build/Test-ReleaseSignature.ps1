<#
.SYNOPSIS
    Verifies a signed OmniDiag folder: every script's Authenticode signature and the
    signed file catalog.

.DESCRIPTION
    For every *.ps1, *.psm1, and *.psd1 under -Path, Get-AuthenticodeSignature must report
    Status 'Valid' (signed, unmodified, and chaining to a root this machine trusts). The
    catalog (<Path>/OmniDiag.cat by default) must carry a Valid signature, and
    Test-FileCatalog must report 'Valid' (no file added, removed, or changed; the catalog
    itself and an OmniDiagData folder created by running the tool are skipped).

    Used by the CI 'signing' job and the release workflow; owners and users can run it on
    an extracted release too (Windows only). Exit code 0 when everything is valid, 1
    otherwise; a table of failures is printed.

.PARAMETER Path
    The extracted package folder (the one containing OmniDiag.ps1).

.PARAMETER CatalogName
    Catalog file name at the root of -Path. Default OmniDiag.cat.

.PARAMETER ExpectedThumbprint
    Optional: also require every signature to come from this certificate.

.EXAMPLE
    ./build/Test-ReleaseSignature.ps1 -Path C:\Tools\OmniDiag-1.0.0-portable
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $CatalogName = 'OmniDiag.cat',
    [string] $ExpectedThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWindowsHost = $true
try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { $isWindowsHost = $true }
if (-not $isWindowsHost) { throw 'Test-ReleaseSignature.ps1 requires Windows (Get-AuthenticodeSignature, Test-FileCatalog).' }

$root = (Resolve-Path -LiteralPath $Path).ProviderPath
$expected = if ($ExpectedThumbprint) { ($ExpectedThumbprint -replace '\s', '').ToUpperInvariant() } else { $null }
$failures = New-Object 'System.Collections.Generic.List[object]'

$scripts = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.FullName -notmatch '[\\/]OmniDiagData[\\/]' })
if ($scripts.Count -eq 0) { $failures.Add([pscustomobject]@{ File = $root; Problem = 'no script files found' }) }
foreach ($s in $scripts) {
    $sig = Get-AuthenticodeSignature -LiteralPath $s.FullName
    if ([string]$sig.Status -ne 'Valid') {
        $failures.Add([pscustomobject]@{ File = $s.FullName; Problem = "signature status $($sig.Status)" })
    } elseif ($expected -and $sig.SignerCertificate.Thumbprint -ne $expected) {
        $failures.Add([pscustomobject]@{ File = $s.FullName; Problem = "signed by $($sig.SignerCertificate.Thumbprint)" })
    }
}

$catalogPath = Join-Path $root $CatalogName
if (-not (Test-Path -LiteralPath $catalogPath)) {
    $failures.Add([pscustomobject]@{ File = $catalogPath; Problem = 'catalog missing' })
} else {
    $catSig = Get-AuthenticodeSignature -LiteralPath $catalogPath
    if ([string]$catSig.Status -ne 'Valid') {
        $failures.Add([pscustomobject]@{ File = $catalogPath; Problem = "catalog signature status $($catSig.Status)" })
    }
    $catResult = Test-FileCatalog -Path $root -CatalogFilePath $catalogPath -FilesToSkip @($CatalogName, 'OmniDiagData')
    if ([string]$catResult -ne 'Valid') {
        $failures.Add([pscustomobject]@{ File = $catalogPath; Problem = "Test-FileCatalog: $catResult" })
    }
}

Write-Host "Checked $($scripts.Count) script signature(s) and the catalog under $root."
if ($failures.Count -gt 0) {
    $failures | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
    Write-Host "Signature verification FAILED ($($failures.Count) problem(s))." -ForegroundColor Red
    exit 1
}
Write-Host 'All signatures and the file catalog are Valid.' -ForegroundColor Green
exit 0
