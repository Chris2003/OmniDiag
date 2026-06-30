<#
.SYNOPSIS
    OmniDiag reporting: ZIP package export.

.DESCRIPTION
    Bundles a full report set - HTML, JSON, findings CSV, event CSV (when present),
    the raw structured log, and a README with the privacy notice - into a single
    .zip for hand-off.
#>

Set-StrictMode -Version Latest

function Export-OmniReportPackage {
    <#
    .SYNOPSIS
        Writes a ZIP package containing all report artifacts for a session.

    .PARAMETER Session
        The OmniDiag.Session to package.

    .PARAMETER Path
        Destination .zip path.

    .PARAMETER BrandName
        Optional branding passed to the HTML report.

    .OUTPUTS
        The written .zip path (string).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $BrandName
    )

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("OmniDiag-pkg-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        Export-OmniHtmlReport -Session $Session -Path (Join-Path $staging 'report.html') -BrandName $BrandName | Out-Null
        Export-OmniJsonReport -Session $Session -Path (Join-Path $staging 'data.json') | Out-Null
        Export-OmniCsvReport  -Session $Session -Path (Join-Path $staging 'findings.csv') | Out-Null
        Export-OmniEventCsvReport -Session $Session -Path (Join-Path $staging 'events.csv') | Out-Null

        # Include the raw structured log when available.
        if ($Session.PSObject.Properties.Name -contains 'LogPath' -and $Session.LogPath -and (Test-Path -LiteralPath $Session.LogPath)) {
            Copy-Item -LiteralPath $Session.LogPath -Destination (Join-Path $staging 'omnidiag-log.jsonl') -Force
        }

        $readme = @"
OmniDiag Report Package
=======================
Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Computer : $($Session.Host.ComputerName)

Contents:
  report.html        Human-readable report (open in a browser)
  data.json          Full structured session data
  findings.csv       All findings across modules
  events.csv         Grouped event-log table (if event data was collected)
  omnidiag-log.jsonl Raw structured run log (if available)

PRIVACY: This package was generated locally and was NOT uploaded anywhere.
It may contain usernames, device names, file paths, domains, and other internal
information. Review the contents before sharing.
"@
        [System.IO.File]::WriteAllText((Join-Path $staging 'README.txt'), $readme, [System.Text.UTF8Encoding]::new($false))

        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

        $items = Get-ChildItem -LiteralPath $staging -File
        Compress-Archive -Path $items.FullName -DestinationPath $Path -Force
        return $Path
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function @('Export-OmniReportPackage')
