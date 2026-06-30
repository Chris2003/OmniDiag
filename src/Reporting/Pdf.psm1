<#
.SYNOPSIS
    OmniDiag reporting: PDF export via headless Chromium.

.DESCRIPTION
    Renders the OmniDiag HTML report to PDF using an installed Chromium browser
    (Microsoft Edge, which ships on Windows 10/11, or Google Chrome) in headless
    --print-to-pdf mode. This reuses the HTML exporter verbatim, so branding, layout,
    and the print stylesheet are written once and the PDF inherits them.

    No binaries are bundled. When no browser is found, Export-OmniPdfReport throws a
    clear error; the Export-OmniReport coordinator catches it and records a warning so
    the other formats still succeed.
#>

Set-StrictMode -Version Latest

function Find-OmniChromium {
    <#
    .SYNOPSIS
        Returns the path to an installed Chromium browser (Edge preferred, then Chrome),
        or $null. Windows-only.
    #>
    [OutputType([string])]
    param()

    try { if ($IsWindows -eq $false) { return $null } } catch { }

    foreach ($cmd in @('msedge.exe', 'chrome.exe')) {
        $c = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($c -and $c.Source) { return [string]$c.Source }
    }

    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ }
    # Edge first, then Chrome (the relative path is checked under every base).
    foreach ($rel in @('Microsoft\Edge\Application\msedge.exe', 'Google\Chrome\Application\chrome.exe')) {
        foreach ($b in $bases) {
            $p = Join-Path $b $rel
            if (Test-Path -LiteralPath $p) { return [string]$p }
        }
    }
    return $null
}

function Invoke-OmniChromiumPrint {
    <#
    .SYNOPSIS
        Internal: one headless print-to-pdf attempt. Returns $true if a non-empty PDF
        was produced. Never hangs - the wait is bounded and the process is killed on
        timeout. A unique --user-data-dir is REQUIRED so the launch does not forward to
        an already-running browser ("Opening in existing browser session") and exit
        without rendering.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Browser,
        [Parameter(Mandatory)] [string] $Mode,        # --headless=new | --headless=old
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $PdfPath,
        [int] $TimeoutSeconds = 120
    )
    $userData = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-cef-' + [System.IO.Path]::GetRandomFileName())
    try {
        if (Test-Path -LiteralPath $PdfPath) { Remove-Item -LiteralPath $PdfPath -Force -ErrorAction SilentlyContinue }
        $argLine =
            "$Mode --disable-gpu --no-first-run --no-default-browser-check " +
            "--user-data-dir=`"$userData`" --print-to-pdf-no-header " +
            "--print-to-pdf=`"$PdfPath`" `"$Uri`""
        $proc = Start-Process -FilePath $Browser -ArgumentList $argLine -NoNewWindow -PassThru -ErrorAction Stop
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            return $false
        }
        return (Test-Path -LiteralPath $PdfPath) -and ((Get-Item -LiteralPath $PdfPath).Length -gt 0)
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $userData) { Remove-Item -LiteralPath $userData -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Export-OmniPdfReport {
    <#
    .SYNOPSIS
        Writes a PDF report for a session by printing the HTML report via headless Chromium.

    .PARAMETER Session
        The OmniDiag.Session to render.

    .PARAMETER Path
        Output .pdf file path.

    .PARAMETER BrandName / BrandLogo / BrandColor
        Optional branding forwarded to the HTML report.

    .PARAMETER TimeoutSeconds
        Per-attempt cap on the headless browser run (default 120). Prevents hangs.

    .OUTPUTS
        The written .pdf path (string).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $BrandName,
        [string] $BrandLogo,
        [string] $BrandColor,
        [int] $TimeoutSeconds = 120
    )

    $browser = Find-OmniChromium
    if (-not $browser) {
        throw 'PDF export needs Microsoft Edge or Google Chrome to render the report, but neither was found. Export HTML instead, or install a Chromium browser.'
    }

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $tmpHtml = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-pdf-' + [System.IO.Path]::GetRandomFileName() + '.html')
    try {
        Export-OmniHtmlReport -Session $Session -Path $tmpHtml -BrandName $BrandName -BrandLogo $BrandLogo -BrandColor $BrandColor | Out-Null
        $uri = ([System.Uri]$tmpHtml).AbsoluteUri   # file:///C:/... (spaces percent-encoded)

        # Try modern headless first, then legacy: --print-to-pdf support differs by
        # Edge/Chrome version, so we attempt both before giving up.
        $ok = $false
        foreach ($mode in @('--headless=new', '--headless=old')) {
            if (Invoke-OmniChromiumPrint -Browser $browser -Mode $mode -Uri $uri -PdfPath $Path -TimeoutSeconds $TimeoutSeconds) {
                $ok = $true; break
            }
        }
        if (-not $ok) {
            throw "The browser ran but produced no PDF at '$Path'. Headless print-to-pdf can fail when the session is elevated - try generating the PDF from a non-elevated session, or export HTML."
        }
        return $Path
    }
    finally {
        if (Test-Path -LiteralPath $tmpHtml) { Remove-Item -LiteralPath $tmpHtml -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function @('Find-OmniChromium', 'Export-OmniPdfReport')
