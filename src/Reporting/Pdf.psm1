<#
.SYNOPSIS
    OmniDiag reporting: native PDF export (no browser, no bundled binaries).

.DESCRIPTION
    Emits a valid PDF document directly from an OmniDiag.Session using only the
    standard PDF base-14 fonts (Helvetica-Bold for headings, Courier for body text),
    so NOTHING external is required - no Chromium/Edge, no .NET PDF library, no
    network. This is what makes PDF work on locked-down / managed machines where a
    headless browser is blocked or forced into an interactive sign-in.

    The output is a clean, paginated, print-friendly technical report (device info,
    health score, top recommendations, per-module results, and findings) - it is not
    a pixel copy of the styled HTML report; use Export-OmniHtmlReport for that.

    Encoding: the whole file is written as Windows-1252 (a single-byte code page), so
    every character is exactly one byte and cross-reference offsets are computed from
    the real byte stream (a MemoryStream), never guessed.
#>

Set-StrictMode -Version Latest

# Approximate em-width per font (fraction of the font size). Courier is monospaced
# so 0.6 is exact; Helvetica-Bold is proportional, used only for short headings.
$script:OmniPdfFontEm = @{ F1 = 0.56; F2 = 0.6 }

function Format-OmniPdfNum {
    <# .SYNOPSIS Internal: format a number for PDF content with an invariant '.'. #>
    param([double] $N)
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.###}', $N)
}

function ConvertTo-OmniPdfText {
    <# .SYNOPSIS Internal: escape a string for a PDF literal ( ) and drop control chars. #>
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '\' { [void]$sb.Append('\\') }
            '(' { [void]$sb.Append('\(') }
            ')' { [void]$sb.Append('\)') }
            default {
                if ([int]$ch -lt 32) { [void]$sb.Append(' ') } else { [void]$sb.Append($ch) }
            }
        }
    }
    return $sb.ToString()
}

function ConvertFrom-OmniHexColor {
    <# .SYNOPSIS Internal: '#RRGGBB' -> 'r g b' PDF color (0-1), or $null if invalid. #>
    param([string] $Hex)
    if ($Hex -and $Hex -match '^#([0-9A-Fa-f]{6})$') {
        $r = [Convert]::ToInt32($Hex.Substring(1, 2), 16) / 255.0
        $g = [Convert]::ToInt32($Hex.Substring(3, 2), 16) / 255.0
        $b = [Convert]::ToInt32($Hex.Substring(5, 2), 16) / 255.0
        return ('{0} {1} {2}' -f (Format-OmniPdfNum $r), (Format-OmniPdfNum $g), (Format-OmniPdfNum $b))
    }
    return $null
}

function Get-OmniPdfSeverityRgb {
    param([string] $Severity)
    switch ($Severity) {
        'Critical'    { '0.80 0.09 0.11' }
        'Error'       { '0.79 0.33 0.00' }
        'Warning'     { '0.68 0.45 0.00' }
        'Information' { '0.10 0.40 0.70' }
        'Pass'        { '0.10 0.55 0.20' }
        default       { '0.10 0.12 0.14' }
    }
}

function Get-OmniPdfStatusRgb {
    param([string] $Status)
    switch ($Status) {
        'Critical' { '0.80 0.09 0.11' }
        'Failed'   { '0.80 0.09 0.11' }
        'Warning'  { '0.68 0.45 0.00' }
        'Healthy'  { '0.10 0.55 0.20' }
        default    { '0.42 0.46 0.50' }
    }
}

function Get-OmniPdfGradeRgb {
    param([string] $Grade)
    switch ($Grade) {
        'Healthy'  { '0.10 0.55 0.20' }
        'Warning'  { '0.68 0.45 0.00' }
        'Critical' { '0.80 0.09 0.11' }
        default    { '0.42 0.46 0.50' }
    }
}

# --- Document / layout model -------------------------------------------------
# $doc is a hashtable (reference type) mutated in place by the helpers below.

function New-OmniPdfPage {
    param([hashtable] $Doc)
    $sb = [System.Text.StringBuilder]::new()
    [void]$Doc.Pages.Add($sb)
    $Doc.Cur = $sb
    $Doc.Y = $Doc.PageH - $Doc.Margin
}

function New-OmniPdfDocument {
    $doc = @{
        PageW  = 612.0    # US Letter
        PageH  = 792.0
        Margin = 54.0     # 0.75"
        Pages  = [System.Collections.Generic.List[object]]::new()
        Images = [System.Collections.Generic.List[object]]::new()   # embedded JPEG XObjects
        Cur    = $null
        Y      = 0.0
    }
    New-OmniPdfPage -Doc $doc
    return $doc
}

function Add-OmniPdfSpacer {
    param([hashtable] $Doc, [double] $Height = 6)
    if (($Doc.Y - $Height) -lt $Doc.Margin) { New-OmniPdfPage -Doc $Doc } else { $Doc.Y -= $Height }
}

function Add-OmniPdfLine {
    <# .SYNOPSIS Internal: draw ONE line (truncated to fit), advancing the cursor. #>
    param(
        [hashtable] $Doc,
        [string] $Text,
        [string] $Font = 'F2',
        [double] $Size = 9,
        [string] $Rgb = '0.10 0.12 0.14',
        [double] $Indent = 0
    )
    $lineHeight = $Size * 1.35
    if (($Doc.Y - $lineHeight) -lt $Doc.Margin) { New-OmniPdfPage -Doc $Doc }
    $Doc.Y -= $lineHeight

    $em = $script:OmniPdfFontEm[$Font]; if (-not $em) { $em = 0.6 }
    $maxChars = [int][math]::Floor(($Doc.PageW - 2 * $Doc.Margin - $Indent) / ($Size * $em))
    if ($maxChars -lt 1) { $maxChars = 1 }
    $t = if ($null -eq $Text) { '' } else { $Text }
    if ($t.Length -gt $maxChars) { $t = $t.Substring(0, [math]::Max(1, $maxChars - 3)) + '...' }

    $esc = ConvertTo-OmniPdfText $t
    $x = Format-OmniPdfNum ($Doc.Margin + $Indent)
    $y = Format-OmniPdfNum $Doc.Y
    [void]$Doc.Cur.Append("BT`n/$Font $(Format-OmniPdfNum $Size) Tf`n$Rgb rg`n$x $y Td`n($esc) Tj`nET`n")
}

function Add-OmniPdfParagraph {
    <# .SYNOPSIS Internal: word-wrap body text (Courier) across as many lines/pages as needed. #>
    param(
        [hashtable] $Doc,
        [string] $Text,
        [double] $Size = 9,
        [string] $Rgb = '0.10 0.12 0.14',
        [double] $Indent = 0
    )
    if ([string]::IsNullOrEmpty($Text)) { return }
    $maxChars = [int][math]::Floor(($Doc.PageW - 2 * $Doc.Margin - $Indent) / ($Size * 0.6))
    if ($maxChars -lt 10) { $maxChars = 10 }

    foreach ($seg in ($Text -split "`r?`n")) {
        if ($seg -eq '') { Add-OmniPdfSpacer -Doc $Doc -Height ($Size * 0.6); continue }
        $line = ''
        foreach ($w in ($seg -split '\s+')) {
            if ($w -eq '') { continue }
            while ($w.Length -gt $maxChars) {
                if ($line -ne '') { Add-OmniPdfLine -Doc $Doc -Text $line -Font 'F2' -Size $Size -Rgb $Rgb -Indent $Indent; $line = '' }
                Add-OmniPdfLine -Doc $Doc -Text $w.Substring(0, $maxChars) -Font 'F2' -Size $Size -Rgb $Rgb -Indent $Indent
                $w = $w.Substring($maxChars)
            }
            $cand = if ($line -ne '') { "$line $w" } else { $w }
            if ($cand.Length -le $maxChars) { $line = $cand }
            else { Add-OmniPdfLine -Doc $Doc -Text $line -Font 'F2' -Size $Size -Rgb $Rgb -Indent $Indent; $line = $w }
        }
        if ($line -ne '') { Add-OmniPdfLine -Doc $Doc -Text $line -Font 'F2' -Size $Size -Rgb $Rgb -Indent $Indent }
    }
}

function Add-OmniPdfHeading {
    param([hashtable] $Doc, [string] $Text, [double] $Size = 13, [string] $Rgb = '0.10 0.12 0.14')
    Add-OmniPdfSpacer -Doc $Doc -Height 6
    Add-OmniPdfLine -Doc $Doc -Text $Text -Font 'F1' -Size $Size -Rgb $Rgb
    Add-OmniPdfSpacer -Doc $Doc -Height 2
}

function Add-OmniPdfRule {
    param([hashtable] $Doc)
    Add-OmniPdfSpacer -Doc $Doc -Height 4
    if (($Doc.Y - 1) -lt $Doc.Margin) { New-OmniPdfPage -Doc $Doc }
    $x1 = Format-OmniPdfNum $Doc.Margin
    $x2 = Format-OmniPdfNum ($Doc.PageW - $Doc.Margin)
    $y  = Format-OmniPdfNum $Doc.Y
    [void]$Doc.Cur.Append("0.80 0.80 0.80 RG 0.5 w $x1 $y m $x2 $y l S`n")
    Add-OmniPdfSpacer -Doc $Doc -Height 8
}

function Get-OmniJpegInfo {
    <#
    .SYNOPSIS
        Internal: read width, height, and component count from a JPEG's SOF marker.

    .DESCRIPTION
        Walks the JPEG marker segments (no decoding) until the first start-of-frame
        marker (SOF0-SOF15 except DHT C4, JPG C8, DAC CC). Returns $null when the bytes
        are not a JPEG or no usable frame header is found.
    #>
    [OutputType([hashtable])]
    param([byte[]] $Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 4) { return $null }
    if ($Bytes[0] -ne 0xFF -or $Bytes[1] -ne 0xD8) { return $null }

    $i = 2
    while ($i -lt $Bytes.Length - 1) {
        if ($Bytes[$i] -ne 0xFF) { return $null }
        $marker = $Bytes[$i + 1]
        if ($marker -eq 0xFF) { $i++; continue }                          # fill byte
        if ($marker -eq 0x01 -or ($marker -ge 0xD0 -and $marker -le 0xD8)) { $i += 2; continue }   # no length
        if ($marker -eq 0xD9 -or $marker -eq 0xDA) { return $null }       # EOI / SOS before any SOF
        if ($i + 3 -ge $Bytes.Length) { return $null }
        $segLen = ([int]$Bytes[$i + 2] -shl 8) -bor [int]$Bytes[$i + 3]
        if ($segLen -lt 2) { return $null }
        $isSof = ($marker -ge 0xC0 -and $marker -le 0xCF) -and ($marker -ne 0xC4) -and ($marker -ne 0xC8) -and ($marker -ne 0xCC)
        if ($isSof) {
            if ($i + 9 -ge $Bytes.Length) { return $null }
            $height = ([int]$Bytes[$i + 5] -shl 8) -bor [int]$Bytes[$i + 6]
            $width  = ([int]$Bytes[$i + 7] -shl 8) -bor [int]$Bytes[$i + 8]
            $comps  = [int]$Bytes[$i + 9]
            if ($width -le 0 -or $height -le 0 -or $comps -notin 1, 3, 4) { return $null }
            return @{ Width = $width; Height = $height; Components = $comps; Bits = [int]$Bytes[$i + 4] }
        }
        $i += 2 + $segLen
    }
    return $null
}

function Add-OmniPdfLogo {
    <#
    .SYNOPSIS
        Internal: embed a JPEG logo as an image XObject and draw it at the top-right of
        the current page. Returns $true when embedded; writes a warning and returns $false
        for a missing, unreadable, or non-JPEG file (the report is still written).
    #>
    [OutputType([bool])]
    param([hashtable] $Doc, [string] $Path, [double] $MaxWidth = 160, [double] $MaxHeight = 40)

    if (-not $Path) { return $false }
    $bytes = $null
    try {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        if (Test-Path -LiteralPath $full -PathType Leaf) { $bytes = [System.IO.File]::ReadAllBytes($full) }
    } catch { $bytes = $null }
    if ($null -eq $bytes) {
        Write-Warning "PDF report: brand logo '$Path' was not found or could not be read; the logo was skipped."
        return $false
    }
    $info = Get-OmniJpegInfo -Bytes $bytes
    if ($null -eq $info) {
        Write-Warning ("PDF report: brand logo '$Path' is not a JPEG; the native PDF writer embeds JPEG logos only " +
            '(the HTML report shows any format). The logo was skipped.')
        return $false
    }

    $name = 'Im{0}' -f ($Doc.Images.Count + 1)
    $Doc.Images.Add(@{ Name = $name; Bytes = $bytes; Width = $info.Width; Height = $info.Height; Components = $info.Components; Bits = $info.Bits })

    $scale = [math]::Min($MaxWidth / $info.Width, $MaxHeight / $info.Height)
    $w = $info.Width * $scale
    $h = $info.Height * $scale
    $x = $Doc.PageW - $Doc.Margin - $w
    $y = $Doc.PageH - $Doc.Margin - $h
    [void]$Doc.Cur.Append(('q {0} 0 0 {1} {2} {3} cm /{4} Do Q' -f (Format-OmniPdfNum $w), (Format-OmniPdfNum $h),
            (Format-OmniPdfNum $x), (Format-OmniPdfNum $y), $name) + "`n")
    return $true
}

function ConvertTo-OmniPdfBinary {
    <# .SYNOPSIS Internal: assemble the page content streams into a valid PDF byte array. #>
    [OutputType([byte[]])]
    param([hashtable] $Doc)

    $enc = [System.Text.Encoding]::GetEncoding(1252)
    $ms = [System.IO.MemoryStream]::new()
    $W = { param($s) $b = $enc.GetBytes($s); $ms.Write($b, 0, $b.Length) }

    $pageCount = $Doc.Pages.Count
    $images = @()
    if ($Doc.ContainsKey('Images') -and $Doc.Images) { $images = @($Doc.Images) }
    # 1 catalog, 2 pages, 3 F1, 4 F2, then 2/page, then one per embedded image.
    $firstImageObj = 5 + $pageCount * 2
    $objCount = 4 + $pageCount * 2 + $images.Count
    $offsets = New-Object 'long[]' ($objCount + 1)

    $xobjects = ''
    if ($images.Count -gt 0) {
        $refs = for ($j = 0; $j -lt $images.Count; $j++) { '/{0} {1} 0 R' -f $images[$j].Name, ($firstImageObj + $j) }
        $xobjects = " /XObject << $($refs -join ' ') >>"
    }

    # Header (binary comment marks the file as containing binary data).
    & $W "%PDF-1.4`n"
    & $W ("%{0}{1}{2}{3}`n" -f [char]0xE2, [char]0xE3, [char]0xCF, [char]0xD3)

    $offsets[1] = $ms.Position
    & $W "1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"

    $kids = for ($i = 0; $i -lt $pageCount; $i++) { "$((5 + $i * 2)) 0 R" }
    $offsets[2] = $ms.Position
    & $W "2 0 obj`n<< /Type /Pages /Kids [$($kids -join ' ')] /Count $pageCount >>`nendobj`n"

    $offsets[3] = $ms.Position
    & $W "3 0 obj`n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>`nendobj`n"

    $offsets[4] = $ms.Position
    & $W "4 0 obj`n<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>`nendobj`n"

    for ($i = 0; $i -lt $pageCount; $i++) {
        $pageObj = 5 + $i * 2
        $contentObj = 6 + $i * 2
        $contentBytes = $enc.GetBytes($Doc.Pages[$i].ToString())

        $offsets[$pageObj] = $ms.Position
        & $W ("$pageObj 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {0} {1}] " -f [int]$Doc.PageW, [int]$Doc.PageH)
        & $W "/Resources << /Font << /F1 3 0 R /F2 4 0 R >>$xobjects >> /Contents $contentObj 0 R >>`nendobj`n"

        $offsets[$contentObj] = $ms.Position
        & $W "$contentObj 0 obj`n<< /Length $($contentBytes.Length) >>`nstream`n"
        $ms.Write($contentBytes, 0, $contentBytes.Length)
        & $W "`nendstream`nendobj`n"
    }

    # Image XObjects: JPEG bytes are embedded verbatim and decoded by the viewer (DCTDecode).
    for ($j = 0; $j -lt $images.Count; $j++) {
        $img = $images[$j]
        $imgObj = $firstImageObj + $j
        $colorSpace = switch ($img.Components) { 1 { '/DeviceGray' } 4 { '/DeviceCMYK' } default { '/DeviceRGB' } }
        $bits = if ($img.Bits -gt 0) { $img.Bits } else { 8 }
        $offsets[$imgObj] = $ms.Position
        & $W ("$imgObj 0 obj`n<< /Type /XObject /Subtype /Image /Width {0} /Height {1} /ColorSpace {2} " -f $img.Width, $img.Height, $colorSpace)
        & $W "/BitsPerComponent $bits /Filter /DCTDecode /Length $($img.Bytes.Length) >>`nstream`n"
        $ms.Write($img.Bytes, 0, $img.Bytes.Length)
        & $W "`nendstream`nendobj`n"
    }

    # Cross-reference table (each entry is exactly 20 bytes).
    $xrefPos = $ms.Position
    & $W "xref`n0 $($objCount + 1)`n"
    & $W "0000000000 65535 f`r`n"
    for ($n = 1; $n -le $objCount; $n++) {
        & $W ('{0:D10} 00000 n' -f [long]$offsets[$n]); & $W "`r`n"
    }

    & $W "trailer`n<< /Size $($objCount + 1) /Root 1 0 R >>`nstartxref`n$xrefPos`n%%EOF`n"

    return $ms.ToArray()
}

function Export-OmniPdfReport {
    <#
    .SYNOPSIS
        Writes a native PDF report for a session (no browser, no external dependency).

    .PARAMETER Session
        The OmniDiag.Session to render.

    .PARAMETER Path
        Output .pdf file path.

    .PARAMETER BrandName
        Optional organization name, shown under the title.

    .PARAMETER BrandColor
        Optional accent color (#RRGGBB) for the title and recommendations.

    .PARAMETER BrandLogo
        Optional path to a logo image, drawn at the top-right of the first page. JPEG files
        are embedded directly (DCTDecode image XObject; size read from the SOF marker), so
        no image library is needed. Other formats are skipped with a warning (Write-Warning)
        and the report is still written; the HTML report shows any format.

    .OUTPUTS
        The written .pdf path (string).

    .NOTES
        The -TimeoutSeconds parameter (ignored since the native writer replaced the
        headless-browser renderer) was removed in 0.5.0; no caller in the repository used it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $BrandName,
        [string] $BrandLogo,
        [string] $BrandColor
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $summary = $Session.Summary
    if (-not $summary) { $summary = @($Session.Results) | Get-OmniHealthScore }

    $accent = ConvertFrom-OmniHexColor $BrandColor
    if (-not $accent) { $accent = '0.04 0.41 0.85' }
    $muted = '0.42 0.46 0.50'

    $doc = New-OmniPdfDocument
    if ($BrandLogo) { [void](Add-OmniPdfLogo -Doc $doc -Path $BrandLogo) }

    # --- Title ---------------------------------------------------------------
    Add-OmniPdfLine -Doc $doc -Text 'OmniDiag Diagnostic Report' -Font 'F1' -Size 20 -Rgb $accent
    Add-OmniPdfSpacer -Doc $doc -Height 2
    $gen = try { '{0:yyyy-MM-dd HH:mm:ss}' -f $summary.GeneratedAt } catch { '{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date) }
    Add-OmniPdfLine -Doc $doc -Text "Generated: $gen" -Font 'F2' -Size 9 -Rgb $muted
    if ($BrandName) { Add-OmniPdfLine -Doc $doc -Text "Prepared for $BrandName" -Font 'F2' -Size 9 -Rgb $muted }
    Add-OmniPdfRule -Doc $doc

    # --- Health score --------------------------------------------------------
    Add-OmniPdfLine -Doc $doc -Text ('Health score: {0}/100  ({1})' -f $summary.Score, $summary.Grade) `
        -Font 'F1' -Size 16 -Rgb (Get-OmniPdfGradeRgb $summary.Grade)
    Add-OmniPdfSpacer -Doc $doc -Height 2
    $c = $summary.Counts
    Add-OmniPdfLine -Doc $doc -Text ('Critical {0}   Error {1}   Warning {2}   Info {3}   Pass {4}' -f `
            $c.Critical, $c.Error, $c.Warning, $c.Information, $c.Pass) -Font 'F2' -Size 10
    Add-OmniPdfLine -Doc $doc -Text ('Modules run: {0}   Total findings: {1}' -f $summary.ModulesRun, $summary.TotalFindings) `
        -Font 'F2' -Size 10 -Rgb $muted

    # --- Device --------------------------------------------------------------
    Add-OmniPdfHeading -Doc $doc -Text 'Device'
    $os = $null
    foreach ($r in $Session.Results) {
        foreach ($k in @('OS', 'OperatingSystem', 'OSName')) {
            if ($r.Metrics -and $r.Metrics.Contains($k)) { $os = [string]$r.Metrics[$k]; break }
        }
        if ($os) { break }
    }
    Add-OmniPdfLine -Doc $doc -Text ('Computer  : {0}' -f $Session.Host.ComputerName) -Font 'F2' -Size 9
    Add-OmniPdfLine -Doc $doc -Text ('User      : {0}' -f $Session.Host.UserName) -Font 'F2' -Size 9
    if ($os) { Add-OmniPdfLine -Doc $doc -Text ('OS        : {0}' -f $os) -Font 'F2' -Size 9 }
    Add-OmniPdfLine -Doc $doc -Text ('PowerShell: {0}' -f $Session.Host.PSVersion) -Font 'F2' -Size 9
    Add-OmniPdfLine -Doc $doc -Text ('Elevated  : {0}' -f $(if ($Session.IsAdmin) { 'Yes' } else { 'No' })) -Font 'F2' -Size 9
    Add-OmniPdfLine -Doc $doc -Text ('Range     : {0}' -f $Session.TimeRange.Label) -Font 'F2' -Size 9
    Add-OmniPdfLine -Doc $doc -Text ('Duration  : {0:N1} s' -f ($Session.DurationMs / 1000)) -Font 'F2' -Size 9

    # --- Top recommendations -------------------------------------------------
    $recs = @($summary.TopRecommendations)
    if ($recs.Count -gt 0) {
        Add-OmniPdfHeading -Doc $doc -Text 'Top recommendations'
        $i = 1
        foreach ($f in $recs) {
            Add-OmniPdfLine -Doc $doc -Text ('{0}. [{1}] {2}' -f $i, $f.Severity, $f.Title) `
                -Font 'F1' -Size 10 -Rgb (Get-OmniPdfSeverityRgb $f.Severity)
            if ($f.Recommendation) { Add-OmniPdfParagraph -Doc $doc -Text ('-> {0}' -f $f.Recommendation) -Size 9 -Indent 14 }
            $i++
        }
    }

    # --- Module results ------------------------------------------------------
    Add-OmniPdfHeading -Doc $doc -Text 'Module results'
    foreach ($r in $Session.Results) {
        Add-OmniPdfLine -Doc $doc -Text ('{0}  ({1})  -  {2}  -  {3} finding(s), {4} ms' -f `
                $r.ModuleName, $r.Category, $r.Status, $r.Findings.Count, $r.DurationMs) `
            -Font 'F2' -Size 9 -Rgb (Get-OmniPdfStatusRgb $r.Status)
        if ($r.Error) { Add-OmniPdfParagraph -Doc $doc -Text ('Error: {0}' -f $r.Error) -Size 8 -Rgb '0.80 0.09 0.11' -Indent 14 }
    }

    # --- Findings detail (everything except Pass), worst first ---------------
    $detail = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Session.Results) {
        foreach ($f in $r.Findings) {
            if ($f.Severity -ne 'Pass') { $detail.Add([pscustomobject]@{ F = $f; Module = $r.ModuleName }) }
        }
    }
    if ($detail.Count -gt 0) {
        Add-OmniPdfHeading -Doc $doc -Text 'Findings'
        $ordered = $detail | Sort-Object -Property @{ Expression = { $_.F.SeverityRank }; Descending = $true }, @{ Expression = { $_.Module } }
        foreach ($item in $ordered) {
            $f = $item.F
            Add-OmniPdfLine -Doc $doc -Text ('[{0}] {1}' -f $f.Severity, $f.Title) `
                -Font 'F1' -Size 10 -Rgb (Get-OmniPdfSeverityRgb $f.Severity)
            $meta = 'Component: {0}  |  Module: {1}' -f $f.Component, $item.Module
            if ($f.Confidence -gt 0) { $meta += '  |  Confidence: {0}%' -f $f.Confidence }
            Add-OmniPdfLine -Doc $doc -Text $meta -Font 'F2' -Size 8 -Rgb $muted -Indent 14
            if ($f.Detail)         { Add-OmniPdfParagraph -Doc $doc -Text $f.Detail -Size 9 -Indent 14 }
            if ($f.LikelyCause)    { Add-OmniPdfParagraph -Doc $doc -Text ('Likely cause: {0}' -f $f.LikelyCause) -Size 9 -Indent 14 }
            if ($f.Recommendation) { Add-OmniPdfParagraph -Doc $doc -Text ('Recommendation: {0}' -f $f.Recommendation) -Size 9 -Rgb $accent -Indent 14 }
            Add-OmniPdfSpacer -Doc $doc -Height 6
        }
    }

    # --- Footer / privacy ----------------------------------------------------
    Add-OmniPdfRule -Doc $doc
    $privacy = if ($Session.PSObject.Properties['Redacted'] -and $Session.Redacted) {
        'Redacted report: OmniDiag runs entirely on the local machine and uploads nothing. Host, user, and ' +
        'domain names, SIDs, profile paths, and IP/MAC addresses were replaced with stable pseudonyms ' +
        '(HOST-1, USER-1, IP-1, ...). Free text that cannot be derived from the session may remain; review before sharing.'
    } else {
        'Privacy: OmniDiag runs entirely on the local machine and uploads nothing. This report may ' +
        'contain usernames, device names, file paths, and domain information. Review before sharing.'
    }
    Add-OmniPdfParagraph -Doc $doc -Size 8 -Rgb $muted -Text $privacy

    [System.IO.File]::WriteAllBytes(($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)), (ConvertTo-OmniPdfBinary -Doc $doc))
    return $Path
}

Export-ModuleMember -Function @('Export-OmniPdfReport')
