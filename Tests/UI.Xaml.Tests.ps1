#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests for the GUI layer. The XAML is split into a small shell (src/UI/MainWindow.xaml)
    and per-section fragments (src/UI/Sections/*.xaml) that load on first navigation.
    XAML structure and the theme palettes are validated on any OS; the real WPF
    XamlReader parse of the shell and every fragment self-skips unless running on
    Windows on an STA thread with WPF available.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:XamlPath = Join-Path $script:Root 'src/UI/MainWindow.xaml'
    $script:SectionDir = Join-Path $script:Root 'src/UI/Sections'
    $script:GuiPath = Join-Path $script:Root 'src/UI/OmniDiagGui.psm1'
    Import-Module (Join-Path $script:Root 'src/OmniDiag.psd1') -Force -DisableNameChecking -Global
    $script:Gui = (Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'OmniDiagGui' } | Select-Object -First 1

    $script:ShellRaw = Get-Content -LiteralPath $script:XamlPath -Raw
    $script:FragmentFiles = @(Get-ChildItem -LiteralPath $script:SectionDir -Filter '*.xaml' -File | Sort-Object Name)
    $script:FragmentRaw = @{}
    foreach ($f in $script:FragmentFiles) { $script:FragmentRaw[$f.Name] = Get-Content -LiteralPath $f.FullName -Raw }
    # Shell + every fragment, for "is this x:Name defined anywhere" checks.
    $script:AllRaw = (@($script:ShellRaw) + @($script:FragmentFiles | ForEach-Object { $script:FragmentRaw[$_.Name] })) -join "`n"
    $script:GuiSource = Get-Content -LiteralPath $script:GuiPath -Raw
    $script:Sections = & $script:Gui { $script:OmniSections }
    $script:StyleFile = & $script:Gui { $script:OmniSectionStyleFile }

    function Get-XamlNames {
        param([string] $Raw)
        @([regex]::Matches($Raw, 'x:Name="([A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
    }
}

Describe 'GUI XAML structure' {
    It 'is well-formed XML (shell and every fragment)' {
        { [xml]$script:ShellRaw } | Should -Not -Throw
        $script:FragmentFiles.Count | Should -BeGreaterOrEqual 7
        foreach ($f in $script:FragmentFiles) {
            { [xml]$script:FragmentRaw[$f.Name] } | Should -Not -Throw -Because $f.Name
        }
    }

    It 'has a fragment file for every lazily loaded section, and no orphan fragments' {
        $expected = @($script:Sections.Values | ForEach-Object { $_.File }) + @($script:StyleFile)
        foreach ($file in $expected) { Join-Path $script:SectionDir $file | Should -Exist }
        @($script:FragmentFiles | Where-Object { $expected -notcontains $_.Name } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'keeps the shell small: no data grids, and every section host is an empty Border' {
        $script:ShellRaw | Should -Not -Match '<DataGrid'
        [xml]$doc = $script:ShellRaw
        foreach ($s in $script:Sections.Values) {
            $hostNode = @($doc.SelectNodes('//*') | Where-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') -eq $s.Host })
            $hostNode.Count | Should -Be 1 -Because "$($s.Host) hosts $($s.File)"
            $hostNode[0].LocalName | Should -Be 'Border'
            @($hostNode[0].ChildNodes | Where-Object { $_.NodeType -eq 'Element' }).Count | Should -Be 0
        }
    }

    It 'defines every x:Name referenced in OmniDiagGui.psm1 in the shell or a fragment' {
        $names = & $script:Gui { $script:OmniUiControlNames }
        $names.Count | Should -BeGreaterThan 50
        $defined = Get-XamlNames $script:AllRaw
        @($names | Where-Object { $defined -notcontains $_ }) | Should -BeNullOrEmpty
        # ...and every control name the source reaches for ($ui.Controls.X, $controls.X, $c.X) is in that list.
        $used = [regex]::Matches($script:GuiSource, '(?:\$(?:ui|Ui|script:OmniUi)\.Controls|\$controls|\$c)\.([A-Za-z]+)', 'IgnoreCase') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        @($used | Where-Object { $names -notcontains $_ }) | Should -BeNullOrEmpty
        @($used | Where-Object { $defined -notcontains $_ }) | Should -BeNullOrEmpty
    }

    It 'defines each name where the code looks it up (shell names in the shell, section names in their fragment)' {
        $shellNames = & $script:Gui { $script:OmniShellControlNames }
        $inShell = Get-XamlNames $script:ShellRaw
        @($shellNames | Where-Object { $inShell -notcontains $_ }) | Should -BeNullOrEmpty
        foreach ($s in $script:Sections.Values) {
            $inFragment = Get-XamlNames $script:FragmentRaw[$s.File]
            @($s.Controls | Where-Object { $inFragment -notcontains $_ }) | Should -BeNullOrEmpty -Because $s.File
        }
        # Names are unique across the shell and the fragments.
        $all = Get-XamlNames $script:AllRaw
        @($all | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'uses no StaticResource in fragments (they are parsed on their own, outside the window)' {
        foreach ($f in $script:FragmentFiles) {
            $markup = $script:FragmentRaw[$f.Name] -replace '(?s)<!--.*?-->', ''
            $markup | Should -Not -Match 'StaticResource' -Because "$($f.Name) cannot see MainWindow.xaml resources at parse time"
        }
    }

    It 'defines all controls the GUI code binds to' {
        foreach ($n in @('BtnScan','BtnCancel','BtnExport','BtnTheme','CmbRange','NavList',
                         'PanelDashboard','PanelSysInfo','GridFindings','GridModules','ItemsRecommendations',
                         'TxtScore','TxtGrade','TxtCounts','ProgressBarMain','TxtStatus')) {
            $script:AllRaw | Should -Match ('x:Name="' + $n + '"')
        }
    }
    It 'defines the Diagnostics tab controls' {
        foreach ($n in @('PanelDiagnostics','DiagGrid','BtnDiagEnableAll','BtnDiagDisableAll')) {
            $script:AllRaw | Should -Match ('x:Name="' + $n + '"')
        }
    }
    It 'offers an unchecked, named "Run connectivity probes" option (probes are opt-in)' {
        [xml]$doc = $script:ShellRaw
        $box = @($doc.SelectNodes('//*') | Where-Object { $_.LocalName -eq 'CheckBox' -and $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') -eq 'ChkNetworkProbes' })
        $box.Count | Should -Be 1
        $box[0].GetAttribute('IsChecked') | Should -Be 'False'
        $box[0].GetAttribute('AutomationProperties.Name') | Should -Be 'Run connectivity probes (contacts the network)'
        $box[0].GetAttribute('Content') | Should -Be 'Run connectivity probes (contacts the network)'
        $script:GuiSource | Should -Match 'NetworkProbes = \$probes'
    }

    It 'adds a Diagnostics entry to the navigation' {
        $script:ShellRaw | Should -Match 'Content="Diagnostics"'
    }
    It 'defines the Repair Center controls' {
        foreach ($n in @('PanelRepair','RepairGrid','RepairResultGrid','BtnRunRepairs','BtnRepairCancel',
                         'BtnRepairRecommended','BtnRepairClear','ChkRepairDryRun','TxtRepairBanner','TxtRepairAdminNote')) {
            $script:AllRaw | Should -Match ('x:Name="' + $n + '"')
        }
    }
    It 'adds a Repair Center entry to the navigation' {
        $script:ShellRaw | Should -Match 'Content="Repair Center"'
    }
    It 'defines the Local AI controls' {
        foreach ($n in @('PanelLocalAi','CmbAiModel','TxtAiEndpoint','BtnAiCheck','TxtAiQuestion',
                         'BtnAiAnalyze','TxtAiStatus','TxtAiOutput')) {
            $script:AllRaw | Should -Match ('x:Name="' + $n + '"')
        }
        $script:ShellRaw | Should -Match 'Content="Local AI"'
        $script:AllRaw | Should -Match 'Text="http://127\.0\.0\.1:11434"'
        $script:AllRaw | Should -Match 'Content="gemma4:e2b"'
    }
}

Describe 'GUI module surface' {
    It 'exports Show-OmniDiagWindow (deprecated) and its implementation Start-OmniGuiWindow' {
        Get-Command Show-OmniDiagWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Start-OmniGuiWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
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
    It 'wires asynchronous, advisory Ollama operations into the GUI' {
        $script:GuiSource | Should -Match 'Test-OmniOllama'
        $script:GuiSource | Should -Match 'Invoke-OmniOllamaAnalysis'
        $script:GuiSource | Should -Match 'CreateRunspace'
        $script:GuiSource | Should -Match 'Format-OmniAiAnalysis'
    }

    It 'references none of the deprecated pre-1.0 command names' {
        $deprecated = 'Invoke-OmniDiag', 'Export-OmniReport', 'Import-OmniSession', 'Compare-OmniSession',
            'Invoke-OmniRepairCenter', 'Invoke-OmniRepair', 'Show-OmniDiagWindow'
        foreach ($name in $deprecated) {
            # Whole command names only: Invoke-OmniDiagScan is not Invoke-OmniDiag.
            $hits = [regex]::Matches($script:GuiSource, '(?<![\w-])' + [regex]::Escape($name) + '(?![\w-])')
            $hits.Count | Should -Be 0 -Because "the GUI must use the curated cmdlets instead of $name"
        }
    }

    It 'runs scans, exports, and repair catalogs through the curated cmdlets' {
        $script:GuiSource | Should -Match 'Invoke-OmniDiagScan @params'
        $script:GuiSource | Should -Match 'AsSession = \$true'
        $script:GuiSource | Should -Match 'Export-OmniDiagReport @p'
        $script:GuiSource | Should -Match 'Get-OmniDiagRepair -RepairsPath'
        $script:GuiSource | Should -Match 'Invoke-OmniRepairRun -Registration'
        foreach ($cmd in 'Invoke-OmniDiagScan', 'Export-OmniDiagReport', 'Get-OmniDiagRepair', 'Invoke-OmniRepairRun') {
            Get-Command -Name $cmd -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "$cmd must be exported for the background runspaces"
        }
        # The parameters the GUI passes exist on the cmdlets it calls.
        $scan = (Get-Command Invoke-OmniDiagScan).Parameters.Keys
        foreach ($p in 'AsSession', 'Range', 'ProgressCallback', 'CancellationToken', 'NetworkProbes', 'ModulesPath', 'Module') { $scan | Should -Contain $p }
        $export = (Get-Command Export-OmniDiagReport).Parameters.Keys
        foreach ($p in 'Session', 'OutputDirectory', 'Format', 'Redact') { $export | Should -Contain $p }
        $repairs = (Get-Command Get-OmniDiagRepair).Parameters.Keys
        foreach ($p in 'Session', 'RepairsPath') { $repairs | Should -Contain $p }
        $run = (Get-Command Invoke-OmniRepairRun).Parameters.Keys
        foreach ($p in 'Registration', 'Context', 'ProgressCallback') { $run | Should -Contain $p }
    }
}

Describe 'GUI XAML loads under WPF' {
    BeforeAll {
        $isSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
        $onWindows = $true
        try { if ($IsWindows -eq $false) { $onWindows = $false } } catch { }
        $script:WpfSkip = if (-not ($onWindows -and $isSta)) { 'requires Windows on an STA thread with WPF' } else { $null }
        if (-not $script:WpfSkip) { Add-Type -AssemblyName PresentationFramework, System.Xaml }
    }

    It 'parses the shell into a Grid with its resources and KeyBindings (Windows + STA only)' {
        if ($script:WpfSkip) { Set-ItResult -Skipped -Because $script:WpfSkip; return }
        $root = [System.Windows.Markup.XamlReader]::Parse($script:ShellRaw)
        # Not a Window: it becomes the Content of the code-built frame window.
        $root | Should -BeOfType [System.Windows.Controls.Grid]
        foreach ($n in (& $script:Gui { $script:OmniShellControlNames })) { $root.FindName($n) | Should -Not -BeNullOrEmpty -Because $n }
        $root.InputBindings.Count | Should -BeGreaterOrEqual 15
        $root.Resources.Contains('OmniFocusVisual') | Should -BeTrue
        $root.Resources.Contains([System.Windows.Controls.Button]) | Should -BeTrue
    }

    It 'builds the frame window in code, then swaps the shell in with names, resources, and shortcuts (Windows + STA only)' {
        if ($script:WpfSkip) { Set-ItResult -Skipped -Because $script:WpfSkip; return }
        $r = & $script:Gui {
            $saved = $script:OmniUi
            try {
                $w = Initialize-OmniMainWindow -Theme Dark
                $frameName = [System.Windows.Automation.AutomationProperties]::GetName($w)
                $before = [bool]$script:OmniUi.ShellReady
                # Shortcuts before the shell is ready are ignored, not errors.
                Invoke-OmniShortcut -Action 'Nav2'
                Invoke-OmniShortcut -Action 'Scan'
                # The swap must not re-apply the brushes (same instances before and after).
                $bgBefore = $w.Resources['BrushWindowBg']
                $textBefore = $w.Resources['BrushText']
                Complete-OmniShellLoad
                [pscustomobject]@{
                    SameBrushes = [object]::ReferenceEquals($bgBefore, $w.Resources['BrushWindowBg']) -and
                                  [object]::ReferenceEquals($textBefore, $w.Resources['BrushText'])
                    ThemeLabel  = [string]$script:OmniUi.Controls.BtnTheme.Content
                    HighContrast = [bool]$script:OmniUi.HighContrast
                    FrameName   = $frameName
                    Before      = $before
                    After       = [bool]$script:OmniUi.ShellReady
                    ShellError  = $script:OmniUi.ShellError
                    IsShell     = [object]::ReferenceEquals($w.Content, $script:OmniUi.ShellRoot)
                    Bindings    = $w.InputBindings.Count
                    HasStyle    = $w.Resources.Contains([System.Windows.Controls.Button])
                    DarkBg      = [string]$w.Resources['BrushWindowBg'].Color
                    ShellBrush  = $script:OmniUi.ShellRoot.Resources.Contains('BrushWindowBg')
                    BtnScan     = [bool]$script:OmniUi.Controls.BtnScan
                }
                try { $w.Close() } catch { $null = $_ }
            } finally {
                if ($script:OmniUi -and $script:OmniUi.HighContrastHandler) {
                    try { [System.Windows.SystemParameters]::remove_StaticPropertyChanged($script:OmniUi.HighContrastHandler) } catch { $null = $_ }
                }
                $script:OmniUi = $saved
            }
        }
        $r.FrameName | Should -Be 'OmniDiag'
        $r.Before | Should -BeFalse
        $r.ShellError | Should -BeNullOrEmpty
        $r.After | Should -BeTrue
        $r.IsShell | Should -BeTrue
        $r.Bindings | Should -BeGreaterOrEqual 15
        $r.HasStyle | Should -BeTrue
        $r.ShellBrush | Should -BeFalse -Because 'the shell must not shadow the window theme brushes'
        $r.SameBrushes | Should -BeTrue -Because 'the shell swap updates the theme controls only, not the brushes'
        # The controls step still ran: the toggle names the theme it switches to.
        $expectedLabel = if ($r.HighContrast) { $r.ThemeLabel } else { 'Light Mode' }
        $r.ThemeLabel | Should -Be $expectedLabel
        $r.BtnScan | Should -BeTrue
        # In high contrast the brushes are SystemColors, not the Dark palette.
        if (-not $r.HighContrast) {
            $r.DarkBg | Should -Be ('#FF' + (Get-OmniThemePalette -Name Dark)['BrushWindowBg'].TrimStart('#')).ToUpperInvariant()
        }
    }

    It 'parses every section fragment on its own and finds its controls (Windows + STA only)' {
        if ($script:WpfSkip) { Set-ItResult -Skipped -Because $script:WpfSkip; return }
        $styles = [System.Windows.Markup.XamlReader]::Parse($script:FragmentRaw[$script:StyleFile])
        $styles | Should -BeOfType [System.Windows.ResourceDictionary]
        foreach ($key in 'FindingRowStyle', 'NamedRowStyle', 'DetailTextBox') { $styles.Contains($key) | Should -BeTrue -Because $key }
        foreach ($s in $script:Sections.Values) {
            $root = [System.Windows.Markup.XamlReader]::Parse($script:FragmentRaw[$s.File])
            $root | Should -BeOfType [System.Windows.FrameworkElement]
            foreach ($n in $s.Controls) { $root.FindName($n) | Should -Not -BeNullOrEmpty -Because "$n in $($s.File)" }
        }
    }
}
