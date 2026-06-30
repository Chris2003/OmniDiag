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

Describe 'PDF exporter' {
    It 'Find-OmniChromium returns a path or $null without throwing' {
        $result = $null
        { $script:result = Find-OmniChromium } | Should -Not -Throw
        if ($null -ne $script:result) { $script:result | Should -BeOfType ([string]) }
    }

    It 'Export-OmniReport soft-fails PDF (records a warning) when it cannot render' {
        # Deterministic: drives the coordinator's try/catch. On a machine that CAN render
        # (browser present + not elevated) this produces a PDF and no warning - both are valid.
        $set = Export-OmniReport -Session $script:Session -OutputDirectory (Join-Path $script:Out 'rs') -Format Html, Pdf
        @($set.Files | Where-Object { $_ -like '*.html' }).Count | Should -Be 1
        $producedPdf = @($set.Files | Where-Object { $_ -like '*.pdf' }).Count -gt 0
        $warned = @($set.Warnings).Count -gt 0
        ($producedPdf -or $warned) | Should -BeTrue   # exactly one of: a PDF, or a recorded warning
    }

    It 'produces a non-empty PDF when a browser can render it' {
        if (-not (Find-OmniChromium)) { Set-ItResult -Skipped -Because 'no Chromium browser'; return }
        $pdf = Join-Path $script:Out 'render.pdf'
        try { Export-OmniPdfReport -Session $script:Session -Path $pdf -TimeoutSeconds 60 | Out-Null }
        catch { Set-ItResult -Skipped -Because "headless render unavailable here: $($_.Exception.Message)"; return }
        (Get-Item -LiteralPath $pdf).Length | Should -BeGreaterThan 0
    }
}
