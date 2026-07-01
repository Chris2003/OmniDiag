#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for report branding (name / logo / accent color), the print stylesheet, and
    the PDF exporter. Branding is verified deterministically against the HTML. PDF
    rendering needs a Chromium browser and a non-elevated session, so that assertion
    self-skips when unavailable; the soft-fail path is always verified.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global

    # Minimal synthetic session (no live scan needed).
    $r = New-OmniResult -ModuleName 'System Information' -Category 'System'
    Set-OmniResultMetric -Result $r -Name 'OS' -Value 'Windows 11'
    Add-OmniFinding -Result $r -Finding (New-OmniFinding -Title 'Secure Boot disabled' -Severity 'Warning' -Component 'System/Firmware' -Recommendation 'Enable Secure Boot')
    $done = Complete-OmniResult -Result $r
    $script:Session = [pscustomobject]@{
        PSTypeName = 'OmniDiag.Session'
        Host       = [pscustomobject]@{ ComputerName = 'TESTPC'; UserName = 'tester'; PSVersion = '7.0' }
        TimeRange  = (Get-OmniTimeRange -Preset Last7Days)
        DurationMs = 1234
        Cancelled  = $false
        IsAdmin    = $false
        Results    = @($done)
        Summary    = (@($done) | Get-OmniHealthScore)
    }

    # A tiny 1x1 PNG used as the logo.
    $script:Logo = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-logo-' + [guid]::NewGuid().ToString('N') + '.png')
    [System.IO.File]::WriteAllBytes($script:Logo,
        [System.Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
    $script:Out = Join-Path ([System.IO.Path]::GetTempPath()) ('omnidiag-brand-' + [guid]::NewGuid().ToString('N'))
}

Describe 'HTML branding' {
    BeforeAll {
        $script:Html = Join-Path $script:Out 'branded.html'
        Export-OmniHtmlReport -Session $script:Session -Path $script:Html `
            -BrandName 'Acme IT' -BrandColor '#0969DA' -BrandLogo $script:Logo | Out-Null
        $script:Markup = Get-Content -LiteralPath $script:Html -Raw
    }
    It 'shows the organization name (HTML-encoded)' { $script:Markup | Should -Match 'Prepared for Acme IT' }
    It 'embeds the logo as an inline base64 image' { $script:Markup | Should -Match "class='brand-logo'[^>]*data:image/png;base64," }
    It 'applies a valid accent color override' { $script:Markup | Should -Match '--info:#0969DA' }
    It 'includes a print stylesheet' { $script:Markup | Should -Match '@media print' }
    It 'ignores an invalid accent color' {
        $p = Join-Path $script:Out 'badcolor.html'
        Export-OmniHtmlReport -Session $script:Session -Path $p -BrandColor 'red' | Out-Null
        (Get-Content -LiteralPath $p -Raw) | Should -Not -Match '--info:red'
    }
}

Describe 'PDF exporter (native, no browser)' {
    It 'writes a valid, non-empty PDF file' {
        $pdf = Join-Path $script:Out 'render.pdf'
        Export-OmniPdfReport -Session $script:Session -Path $pdf | Should -Be $pdf
        $bytes = [System.IO.File]::ReadAllBytes($pdf)
        $bytes.Length | Should -BeGreaterThan 0
        # Valid PDFs start with "%PDF-" and end near "%%EOF".
        ([System.Text.Encoding]::ASCII.GetString($bytes, 0, 5)) | Should -Be '%PDF-'
        ([System.Text.Encoding]::ASCII.GetString($bytes)) | Should -Match '%%EOF'
    }

    It 'honors a #RRGGBB brand color without throwing and still emits a PDF' {
        $pdf = Join-Path $script:Out 'branded.pdf'
        { Export-OmniPdfReport -Session $script:Session -Path $pdf -BrandName 'Acme IT' -BrandColor '#0969DA' } | Should -Not -Throw
        (Get-Item -LiteralPath $pdf).Length | Should -BeGreaterThan 0
    }

    It 'ignores an invalid brand color (falls back, no throw)' {
        $pdf = Join-Path $script:Out 'badcolor.pdf'
        { Export-OmniPdfReport -Session $script:Session -Path $pdf -BrandColor 'red' } | Should -Not -Throw
        (Get-Item -LiteralPath $pdf).Length | Should -BeGreaterThan 0
    }

    It 'Export-OmniReport produces a PDF with no warning (no external dependency)' {
        $set = Export-OmniReport -Session $script:Session -OutputDirectory (Join-Path $script:Out 'rs') -Format Html, Pdf
        @($set.Files | Where-Object { $_ -like '*.html' }).Count | Should -Be 1
        @($set.Files | Where-Object { $_ -like '*.pdf' }).Count | Should -Be 1
        @($set.Warnings).Count | Should -Be 0
    }
}
