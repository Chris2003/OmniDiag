#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the GUI layer. XAML structure and the theme palettes are validated on
    any OS; the real WPF XamlReader load self-skips unless running on Windows on an
    STA thread with WPF available.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:XamlPath = Join-Path $root 'src/UI/MainWindow.xaml'
    Import-Module (Join-Path $root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
}

Describe 'GUI XAML structure' {
    It 'is well-formed XML' {
        { [xml](Get-Content -LiteralPath $script:XamlPath -Raw) } | Should -Not -Throw
    }
    It 'defines all controls the GUI code binds to' {
        $raw = Get-Content -LiteralPath $script:XamlPath -Raw
        foreach ($n in @('BtnScan','BtnCancel','BtnExport','BtnTheme','CmbRange','NavList',
                         'PanelDashboard','PanelSysInfo','GridFindings','GridModules','ItemsRecommendations',
                         'TxtScore','TxtGrade','TxtCounts','ProgressBarMain','TxtStatus')) {
            $raw | Should -Match ('x:Name="' + $n + '"')
        }
    }
    It 'defines the Diagnostics tab controls' {
        $raw = Get-Content -LiteralPath $script:XamlPath -Raw
        foreach ($n in @('PanelDiagnostics','DiagGrid','BtnDiagEnableAll','BtnDiagDisableAll')) {
            $raw | Should -Match ('x:Name="' + $n + '"')
        }
    }
    It 'adds a Diagnostics entry to the navigation' {
        (Get-Content -LiteralPath $script:XamlPath -Raw) | Should -Match 'Content="Diagnostics"'
    }
    It 'defines the Repair Center controls' {
        $raw = Get-Content -LiteralPath $script:XamlPath -Raw
        foreach ($n in @('PanelRepair','RepairGrid','RepairResultGrid','BtnRunRepairs','BtnRepairCancel',
                         'BtnRepairRecommended','BtnRepairClear','ChkRepairDryRun','TxtRepairBanner','TxtRepairAdminNote')) {
            $raw | Should -Match ('x:Name="' + $n + '"')
        }
    }
    It 'adds a Repair Center entry to the navigation' {
        (Get-Content -LiteralPath $script:XamlPath -Raw) | Should -Match 'Content="Repair Center"'
    }
}

Describe 'GUI module surface' {
    It 'exports Show-OmniDiagWindow' {
        Get-Command Show-OmniDiagWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'provides Dark and Light palettes with identical keys' {
        $d = Get-OmniThemePalette -Name Dark
        $l = Get-OmniThemePalette -Name Light
        ($d.Keys | Sort-Object) | Should -Be ($l.Keys | Sort-Object)
    }
    It 'uses different background colors per theme' {
        (Get-OmniThemePalette -Name Dark)['BrushWindowBg'] |
            Should -Not -Be (Get-OmniThemePalette -Name Light)['BrushWindowBg']
    }
}

Describe 'GUI XAML loads under WPF' {
    It 'parses into a WPF Window (Windows + STA only)' {
        $isSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
        $onWindows = $true
        try { if ($IsWindows -eq $false) { $onWindows = $false } } catch { }
        if (-not ($onWindows -and $isSta)) {
            Set-ItResult -Skipped -Because 'requires Windows on an STA thread with WPF'
            return
        }
        Add-Type -AssemblyName PresentationFramework, System.Xaml
        [xml]$x = Get-Content -LiteralPath $script:XamlPath -Raw
        $reader = [System.Xml.XmlNodeReader]::new($x)
        { [System.Windows.Markup.XamlReader]::Load($reader) } | Should -Not -Throw
    }
}
