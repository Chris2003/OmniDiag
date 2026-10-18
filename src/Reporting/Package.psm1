<#
.SYNOPSIS
    OmniDiag reporting: ZIP package export.

.DESCRIPTION
    Bundles a full report set - HTML, JSON, findings CSV, event CSV (when present),
    the raw structured log, and a README with the privacy notice - into a single
    .zip for hand-off. With -Redact every entry is redacted, including the README
    and the run log (redacted line by line; see docs/REDACTION.md).
#>

Set-StrictMode -Version Latest

function ConvertFrom-OmniJsonUnicodeEscape {
    <#
    .SYNOPSIS
        Internal: decodes \uXXXX escapes of printable characters in JSON text.

    .DESCRIPTION
        ConvertTo-Json on Windows PowerShell 5.1 escapes ' & < > (and more) as \u0027,
        \u0026, ... The decoded text is equivalent JSON. Quotes, backslashes, control
        characters, and surrogate halves stay escaped; an escaped backslash followed by
        'u0027' (\\u0027) is left alone.
    #>
    [OutputType([string])]
    param([AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrEmpty($Text) -or $Text.IndexOf('\u', [System.StringComparison]::Ordinal) -lt 0) { return $Text }
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $last = 0
    foreach ($m in $script:OmniJsonUnicodeEscapeRegex.Matches($Text)) {
        $code = [System.Convert]::ToInt32($m.Groups['hex'].Value, 16)
        $keep = $code -lt 0x20 -or $code -eq 0x22 -or $code -eq 0x5C -or ($code -ge 0x7F -and $code -lt 0xA0) -or ($code -ge 0xD800 -and $code -le 0xDFFF)
        if ($keep) { continue }
        [void]$sb.Append($Text, $last, $m.Index - $last)
        [void]$sb.Append($m.Groups['bs'].Value)
        [void]$sb.Append([char]$code)
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Text, $last, $Text.Length - $last)
    return $sb.ToString()
}

# An even run of backslashes (escaped backslashes, kept) followed by \uXXXX.
$script:OmniJsonUnicodeEscapeRegex = [regex]::new('(?<!\\)(?<bs>(?:\\\\)*)\\u(?<hex>[0-9A-Fa-f]{4})', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

function Export-OmniReportPackage {
    <#
    .SYNOPSIS
        Writes a ZIP package containing all report artifacts for a session.

    .PARAMETER Session
        The OmniDiag.Session to package.

    .PARAMETER Path
        Destination .zip path.

    .PARAMETER BrandName
        Optional organization name shown on the HTML (and best-effort PDF) report.

    .PARAMETER BrandLogo
        Optional logo image path embedded in the HTML (and best-effort PDF) report.

    .PARAMETER BrandColor
        Optional accent color (#RRGGBB) for the HTML (and best-effort PDF) report.

    .PARAMETER Redact
        Redact every entry with stable pseudonyms (see Export-OmniReport -Redact). A
        session that is already a redacted copy (Redacted = $true) is used as-is.

    .PARAMETER RedactionContext
        The OmniDiag.RedactionContext to use with -Redact. Default: a new context built
        from the session.

    .PARAMETER LogPath
        The run log to include (default: the session's LogPath). Export-OmniReport
        passes the original path because the redacted copy's LogPath is redacted.

    .OUTPUTS
        The written .zip path (string).

    .EXAMPLE
        Export-OmniReportPackage -Session $session -Path .\report.zip

    .EXAMPLE
        Export-OmniReportPackage -Session $session -Path .\shareable.zip -Redact
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $BrandName,
        [string] $BrandLogo,
        [string] $BrandColor,
        [switch] $Redact,
        [object] $RedactionContext,
        [string] $LogPath
    )

    if (-not $PSBoundParameters.ContainsKey('LogPath') -and $Session.PSObject.Properties['LogPath'] -and $Session.LogPath) {
        $LogPath = [string]$Session.LogPath
    }
    $ctx = $null
    if ($Redact) {
        $ctx = $RedactionContext
        if ($null -eq $ctx) { $ctx = New-OmniRedactionContext -Session $Session }
        $already = $Session.PSObject.Properties['Redacted'] -and [bool]$Session.Redacted
        if (-not $already) {
            $Session = ConvertTo-OmniRedacted -InputObject $Session -Context $ctx
            Add-Member -InputObject $Session -MemberType NoteProperty -Name Redacted -Value $true -Force
        }
    }

    # Canonical destination; device paths, streams, and reserved names are refused.
    $Path = Resolve-OmniOutputPath -Path $Path -Purpose 'report package'
    if ($Redact) {
        # The file name may embed the computer or user name too. The redacted leaf stays
        # one file-name component in the same folder.
        $leaf = Split-Path -Path $Path -Leaf
        $redactedLeaf = ConvertTo-OmniSafeFileName -Name ([string](ConvertTo-OmniRedacted -InputObject $leaf -Context $ctx)) -Default 'OmniDiag-report.zip'
        if ($redactedLeaf -ne $leaf) {
            $parent = Split-Path -Path $Path -Parent
            $Path = Resolve-OmniOutputPath -Path (Join-Path $parent $redactedLeaf) -Root $parent -Purpose 'report package'
        }
    }

    $staging = Join-Path (Get-OmniDataPath -Kind Temp) ("pkg-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        Export-OmniHtmlReport -Session $Session -Path (Join-Path $staging 'report.html') -BrandName $BrandName -BrandLogo $BrandLogo -BrandColor $BrandColor | Out-Null
        Export-OmniJsonReport -Session $Session -Path (Join-Path $staging 'data.json') | Out-Null
        Export-OmniCsvReport  -Session $Session -Path (Join-Path $staging 'findings.csv') | Out-Null
        Export-OmniEventCsvReport -Session $Session -Path (Join-Path $staging 'events.csv') | Out-Null

        # PDF is now generated natively (no browser), so include it best-effort and
        # never let an unexpected failure abort the package.
        $pdfIncluded = $false
        try {
            Export-OmniPdfReport -Session $Session -Path (Join-Path $staging 'report.pdf') -BrandName $BrandName -BrandLogo $BrandLogo -BrandColor $BrandColor | Out-Null
            $pdfIncluded = $true
        } catch { }

        # Include the raw structured log when available. Redacted packages get a copy
        # redacted line by line with the same context (each JSONL line is redacted as text,
        # after its printable \uXXXX escapes are decoded; the line stays valid JSON and its
        # timestamps and layout are untouched).
        $logIncluded = $false
        if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
            $logDest = Join-Path $staging 'omnidiag-log.jsonl'
            if ($Redact) {
                $utf8 = [System.Text.UTF8Encoding]::new($false)
                $writer = [System.IO.StreamWriter]::new($logDest, $false, $utf8)
                try {
                    foreach ($line in [System.IO.File]::ReadLines((Resolve-Path -LiteralPath $LogPath).ProviderPath)) {
                        # Undo \uXXXX escapes first: Windows PowerShell 5.1 writes ' and & as
                        # \u0027 / \u0026, which would hide o'brien or R&D from the term match.
                        $plainLine = ConvertFrom-OmniJsonUnicodeEscape -Text $line
                        $writer.Write([string](ConvertTo-OmniRedacted -InputObject $plainLine -Context $ctx))
                        $writer.Write("`n")
                    }
                } finally { $writer.Dispose() }
            } else {
                Copy-Item -LiteralPath $LogPath -Destination $logDest -Force
            }
            $logIncluded = $true
        }

        $plainNote = "It may contain usernames, device names, file paths, domains, and other internal`ninformation. Review the contents before sharing."
        $redactedNote = "REDACTED: host, user, and domain names, SIDs, profile paths, and IP/MAC addresses`nwere replaced with stable pseudonyms (HOST-1, USER-1, IP-1, ...) in every file,`nincluding the run log. Free text that cannot be derived from the session (for`nexample a colleague's name in an event message) may remain - review before sharing."
        $readme = @"
OmniDiag Report Package
=======================
Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Computer : $($Session.Host.ComputerName)

Contents:
  report.html        Human-readable report (open in a browser)
  report.pdf         Print-ready PDF report$(if ($pdfIncluded) { '' } else { ' (omitted: generation failed)' })
  data.json          Structured report data (OmniDiag report schema v1)
  findings.csv       All findings across modules
  events.csv         Grouped event-log table (if event data was collected)
  omnidiag-log.jsonl Raw structured run log$(if ($logIncluded) { '' } else { ' (not available)' })

PRIVACY: This package was generated locally and was NOT uploaded anywhere.
$(if ($Redact) { $redactedNote } else { $plainNote })
"@
        [System.IO.File]::WriteAllText((Join-Path $staging 'README.txt'), $readme, [System.Text.UTF8Encoding]::new($false))

        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

        $items = Get-ChildItem -LiteralPath $staging -File
        Compress-Archive -LiteralPath $items.FullName -DestinationPath $Path -Force
        return $Path
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function @('Export-OmniReportPackage')
