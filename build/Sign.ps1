<#
.SYNOPSIS
    Authenticode-signs every OmniDiag script in a folder and adds a signed file catalog,
    when a code-signing certificate is provided. Without one it does nothing (exit 0).

.DESCRIPTION
    Code-signing hook for releases (docs/RELEASING.md). The certificate and its password
    stay with the owner: this script never prints, logs, or writes a secret.

    With a certificate:
      1. Signs every *.ps1, *.psm1, and *.psd1 under -Path (SHA-256, ordinal order) with
         Set-AuthenticodeSignature, optionally timestamped (-TimestampServer).
      2. Creates a file catalog over the whole folder (New-FileCatalog, CatalogVersion 2,
         SHA-256) at <Path>/OmniDiag.cat, signs it, and checks it with Test-FileCatalog.
         The catalog covers what Authenticode cannot sign: the .cmd launchers (batch
         files have no Authenticode SIP), XAML, JSON schemas, Markdown, and VERSION.txt.
    Without a certificate: prints one line and returns (exit code 0).

    Run it on a STAGING copy before zipping (build/Build-Portable.ps1 -Sign does this):
    signing appends a signature block to each script, so signing after zipping, or
    editing a file afterwards, would leave the archive or the signature stale.

    Signing requires Windows (Set-AuthenticodeSignature / New-FileCatalog). The no-op
    path works everywhere.

.PARAMETER Path
    Folder to sign (for example dist/OmniDiag-<version>-portable).

.PARAMETER CertificateThumbprint
    Thumbprint of a code-signing certificate with a private key in Cert:\CurrentUser\My.

.PARAMETER PfxPath
    A .pfx file with the code-signing certificate and private key. The password is read
    from the environment variable OMNIDIAG_SIGN_PFX_PASSWORD (empty when unset). The key
    is loaded for this process only and never persisted.

.PARAMETER TimestampServer
    Optional timestamp server URL (for example your CA's RFC 3161 endpoint). Default: none.
    Without a timestamp, signatures stop validating when the certificate expires.

.PARAMETER CatalogName
    File name of the catalog written at the root of -Path. Default OmniDiag.cat.

.EXAMPLE
    ./build/Sign.ps1 -Path dist/OmniDiag-1.0.0-portable -CertificateThumbprint 0123...ABCD

.EXAMPLE
    $env:OMNIDIAG_SIGN_PFX_PASSWORD = '...'; ./build/Sign.ps1 -Path staging -PfxPath C:\secure\sign.pfx -TimestampServer http://timestamp.example
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $CertificateThumbprint,
    [string] $PfxPath,
    [string] $TimestampServer,
    [ValidatePattern('^[A-Za-z0-9._-]+\.cat$')]
    [string] $CatalogName = 'OmniDiag.cat'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Sign.ps1: folder not found: $Path" }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath

if (-not $CertificateThumbprint -and -not $PfxPath) {
    Write-Host 'Sign.ps1: no signing certificate provided (-CertificateThumbprint or -PfxPath); nothing was signed.'
    return [pscustomobject]@{ PSTypeName = 'OmniDiag.SignResult'; Signed = $false; Path = $root; Files = 0; Catalog = $null; Thumbprint = $null; Timestamped = $false }
}
if ($CertificateThumbprint -and $PfxPath) { throw 'Sign.ps1: pass either -CertificateThumbprint or -PfxPath, not both.' }

$isWindowsHost = $true
try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { $isWindowsHost = $true }
if (-not $isWindowsHost) { throw 'Sign.ps1: Authenticode signing and file catalogs require Windows.' }

$codeSigningOid = '1.3.6.1.5.5.7.3.3'
function Test-CodeSigningCertificate {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate)
    if (-not $Certificate.HasPrivateKey) { return $false }
    foreach ($ext in $Certificate.Extensions) {
        if ($ext -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
            foreach ($oid in $ext.EnhancedKeyUsages) { if ($oid.Value -eq $codeSigningOid) { return $true } }
            return $false
        }
    }
    return $false
}

$loaded = @()
$cert = $null
try {
    if ($CertificateThumbprint) {
        $thumb = ($CertificateThumbprint -replace '\s', '').ToUpperInvariant()
        if ($thumb -notmatch '^[0-9A-F]{40}$') { throw 'Sign.ps1: -CertificateThumbprint must be 40 hex characters (SHA-1 thumbprint).' }
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        try {
            $found = @($store.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $thumb, $false))
        } finally { $store.Close() }
        if ($found.Count -eq 0) { throw "Sign.ps1: no certificate with thumbprint $thumb in Cert:\CurrentUser\My." }
        $cert = $found[0]
        if (-not (Test-CodeSigningCertificate $cert)) { throw "Sign.ps1: certificate $thumb has no private key or no Code Signing usage (EKU $codeSigningOid)." }
    } else {
        if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw 'Sign.ps1: -PfxPath does not point to a file.' }
        $password = [string]$env:OMNIDIAG_SIGN_PFX_PASSWORD
        $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        try {
            # UserKeySet without PersistKeySet: the private key lives only as long as this process needs it.
            $collection.Import((Resolve-Path -LiteralPath $PfxPath).ProviderPath, $password, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)
        } catch {
            # The exception text never contains the password; keep the message generic anyway.
            throw 'Sign.ps1: could not open the PFX file (wrong OMNIDIAG_SIGN_PFX_PASSWORD, or not a PKCS#12 file).'
        } finally { $password = $null }
        $loaded = @($collection)
        $cert = @($loaded | Where-Object { Test-CodeSigningCertificate $_ }) | Select-Object -First 1
        if (-not $cert) { throw 'Sign.ps1: the PFX file has no certificate with a private key and Code Signing usage.' }
    }

    Write-Host "Sign.ps1: signing with '$($cert.Subject)' (thumbprint $($cert.Thumbprint), expires $($cert.NotAfter.ToString('yyyy-MM-dd')))."
    if ($TimestampServer) { Write-Host "Sign.ps1: timestamp server $TimestampServer" } else { Write-Host 'Sign.ps1: no timestamp server (signatures stop validating when the certificate expires).' }

    $sigParams = @{ Certificate = $cert; HashAlgorithm = 'SHA256' }
    if ($TimestampServer) { $sigParams.TimestampServer = $TimestampServer }

    function Invoke-SignFile {
        param([string] $FilePath)
        $sig = Set-AuthenticodeSignature -LiteralPath $FilePath @sigParams
        $bad = @('NotSigned', 'HashMismatch', 'NotSupportedFileFormat', 'Incompatible')
        if ($null -eq $sig -or $null -eq $sig.SignerCertificate -or [string]$sig.Status -in $bad) {
            $status = if ($sig) { [string]$sig.Status } else { 'no result' }
            throw "Sign.ps1: signing failed for '$FilePath' ($status)."
        }
        # 'UnknownError' only means the chain is not trusted on this machine (for example a test certificate).
        return $sig
    }

    $rootFull = $root.TrimEnd('\', '/')
    $scripts = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
            ForEach-Object { $_.FullName })
    $relNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $scripts) { $relNames.Add($s.Substring($rootFull.Length + 1)) }
    $relNames.Sort([System.StringComparer]::Ordinal)
    foreach ($rel in $relNames) { Invoke-SignFile -FilePath (Join-Path $root $rel) | Out-Null }
    Write-Host "Sign.ps1: signed $($relNames.Count) script file(s)."

    $skipped = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Extension -in '.cmd', '.bat' })
    if ($skipped.Count -gt 0) {
        Write-Host "Sign.ps1: $($skipped.Count) batch file(s) cannot carry an Authenticode signature; the catalog covers them."
    }

    # File catalog over everything (signed scripts included), then sign the catalog itself.
    $catalogPath = Join-Path $root $CatalogName
    if (Test-Path -LiteralPath $catalogPath) { Remove-Item -LiteralPath $catalogPath -Force }
    $tempCatalog = Join-Path ([System.IO.Path]::GetTempPath()) ("omnidiag-" + [guid]::NewGuid().ToString('N') + '.cat')
    try {
        New-FileCatalog -Path $root -CatalogFilePath $tempCatalog -CatalogVersion 2 | Out-Null
        Move-Item -LiteralPath $tempCatalog -Destination $catalogPath
    } finally {
        if (Test-Path -LiteralPath $tempCatalog) { Remove-Item -LiteralPath $tempCatalog -Force -ErrorAction SilentlyContinue }
    }
    Invoke-SignFile -FilePath $catalogPath | Out-Null
    $check = Test-FileCatalog -Path $root -CatalogFilePath $catalogPath -FilesToSkip $CatalogName
    if ([string]$check -ne 'Valid') { throw "Sign.ps1: Test-FileCatalog reported '$check' right after creating $CatalogName." }
    Write-Host "Sign.ps1: catalog $CatalogName created, signed, and verified."

    return [pscustomobject]@{
        PSTypeName  = 'OmniDiag.SignResult'
        Signed      = $true
        Path        = $root
        Files       = $relNames.Count
        Catalog     = $catalogPath
        Thumbprint  = $cert.Thumbprint
        Timestamped = [bool]$TimestampServer
    }
} finally {
    foreach ($c in $loaded) { try { $c.Reset() } catch { $null = $_ } }
}
