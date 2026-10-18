#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the native PDF writer's brand logo: a JPEG logo is embedded as a DCTDecode
    image XObject (size read from the SOF marker), other formats are skipped with a
    warning, and the cross-reference table stays byte-exact. Cross-platform.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:PdfModule = (Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'Pdf' } | Select-Object -First 1

    $r = New-OmniResult -ModuleName 'System Information' -Category 'System'
    Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'Secure Boot disabled' -Severity 'Warning' -Component 'System/Firmware')
    $done = Complete-OmniResult -Result $r
    $script:Session = [pscustomobject]@{
        PSTypeName = 'OmniDiag.Session'
        Host       = [pscustomobject]@{ ComputerName = 'TESTPC'; UserName = 'tester'; PSVersion = '7.0' }
        TimeRange  = (Get-OmniTimeRange -Preset Last7Days)
        DurationMs = 10
        Cancelled  = $false
        IsAdmin    = $false
        Results    = @($done)
        Summary    = (@($done) | Get-OmniHealthScore)
    }

    # A real 2x1 baseline JPEG (287 bytes, 3 components) - width and height differ on purpose.
    $script:JpegBytes = [System.Convert]::FromBase64String(
        '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/' +
        '2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAABAAIDASIAAhEBAxEB/8QAFQAB' +
        'AQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAABAb/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIR' +
        'AxEAPwCOACqH/9k=')
    $script:Jpeg = Join-Path $TestDrive 'logo.jpg'
    [System.IO.File]::WriteAllBytes($script:Jpeg, $script:JpegBytes)

    $script:Png = Join-Path $TestDrive 'logo.png'
    [System.IO.File]::WriteAllBytes($script:Png,
        [System.Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))

    # Latin-1 maps bytes 0-255 one-to-one onto chars, so offsets in the string equal byte offsets.
    $script:ReadPdf = { param($p) [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($p)) }
}

Describe 'Get-OmniJpegInfo' {
    It 'reads width, height, and components from the SOF marker' {
        $info = & $script:PdfModule { param($b) Get-OmniJpegInfo -Bytes $b } $script:JpegBytes
        $info.Width | Should -Be 2
        $info.Height | Should -Be 1
        $info.Components | Should -Be 3
    }
    It 'parses a synthetic progressive (SOF2) header after an APP segment' {
        # SOI, APP0 (length 4, 2 payload bytes), SOF2 len 17: precision 8, height 0x0120, width 0x0340, 1 component.
        [byte[]] $b = 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC2, 0x00, 0x0B, 0x08, 0x01, 0x20, 0x03, 0x40, 0x01, 0x01, 0x11, 0x00
        $info = & $script:PdfModule { param($x) Get-OmniJpegInfo -Bytes $x } $b
        $info.Height | Should -Be 288
        $info.Width | Should -Be 832
        $info.Components | Should -Be 1
    }
    It 'returns nothing for non-JPEG or truncated bytes' {
        [byte[]] $png = 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A
        [byte[]] $cut = 0xFF, 0xD8, 0xFF, 0xE0, 0x00
        (& $script:PdfModule { param($x) Get-OmniJpegInfo -Bytes $x } $png) | Should -BeNullOrEmpty
        (& $script:PdfModule { param($x) Get-OmniJpegInfo -Bytes $x } $cut) | Should -BeNullOrEmpty
    }
}

Describe 'Export-OmniPdfReport -BrandLogo' {
    It 'embeds a JPEG logo as a DCTDecode image XObject and draws it' {
        $pdf = Join-Path $TestDrive 'jpeg-logo.pdf'
        $warn = $null
        Export-OmniPdfReport -Session $script:Session -Path $pdf -BrandLogo $script:Jpeg -WarningVariable warn | Should -Be $pdf
        @($warn).Count | Should -Be 0
        $text = & $script:ReadPdf $pdf
        $text | Should -Match '/Subtype /Image /Width 2 /Height 1 /ColorSpace /DeviceRGB'
        $text | Should -Match '/BitsPerComponent 8 /Filter /DCTDecode /Length 287'
        $text | Should -Match '/XObject << /Im1 \d+ 0 R >>'
        $text | Should -Match '/Im1 Do'
        # The JPEG stream is embedded verbatim.
        $text.Contains([System.Text.Encoding]::GetEncoding(28591).GetString($script:JpegBytes)) | Should -BeTrue
    }

    It 'keeps every cross-reference offset pointing at its object' {
        $pdf = Join-Path $TestDrive 'xref.pdf'
        Export-OmniPdfReport -Session $script:Session -Path $pdf -BrandLogo $script:Jpeg | Out-Null
        $text = & $script:ReadPdf $pdf
        $startxref = [int]([regex]::Match($text, 'startxref\n(\d+)').Groups[1].Value)
        $text.Substring($startxref, 4) | Should -Be 'xref'
        $count = [int]([regex]::Match($text.Substring($startxref), 'xref\n0 (\d+)').Groups[1].Value)
        $entries = [regex]::Matches($text.Substring($startxref), '(\d{10}) 00000 n')
        $entries.Count | Should -Be ($count - 1)
        for ($n = 1; $n -lt $count; $n++) {
            $offset = [int]$entries[$n - 1].Groups[1].Value
            $text.Substring($offset, ("$n 0 obj").Length) | Should -Be "$n 0 obj"
        }
    }

    It 'skips a non-JPEG logo with a warning and still writes the PDF' {
        $pdf = Join-Path $TestDrive 'png-logo.pdf'
        $warn = $null
        Export-OmniPdfReport -Session $script:Session -Path $pdf -BrandLogo $script:Png -WarningVariable warn -WarningAction SilentlyContinue | Should -Be $pdf
        @($warn).Count | Should -Be 1
        "$($warn[0])" | Should -Match 'not a JPEG'
        $text = & $script:ReadPdf $pdf
        $text | Should -Not -Match '/XObject'
        $text | Should -Match '%%EOF'
    }

    It 'skips a missing logo with a warning and still writes the PDF' {
        $pdf = Join-Path $TestDrive 'missing-logo.pdf'
        $warn = $null
        Export-OmniPdfReport -Session $script:Session -Path $pdf -BrandLogo (Join-Path $TestDrive 'nope.jpg') -WarningVariable warn -WarningAction SilentlyContinue | Should -Be $pdf
        "$($warn[0])" | Should -Match 'not found'
        (Get-Item -LiteralPath $pdf).Length | Should -BeGreaterThan 0
    }

    It 'no longer accepts the removed -TimeoutSeconds parameter' {
        (Get-Command Export-OmniPdfReport).Parameters.ContainsKey('TimeoutSeconds') | Should -BeFalse
    }
}
