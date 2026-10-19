#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Accessibility, keyboard, high-contrast, and drill-down tests for the WPF GUI.

    * Cross-platform: the shell (MainWindow.xaml) and every section fragment
      (Sections/*.xaml, loaded on first navigation) are parsed as XML (every interactive
      control is named, the keyboard shortcuts exist, access keys are unique, focus visuals
      are set, severity colors are theme brushes), the code-behind's control list matches
      the XAML, and the pure helpers behind the findings filter, finding details, and group
      summaries are exercised on a synthetic session.
    * Windows desktop only: the real window is shown modelessly on its own STA thread and
      inspected with UI Automation (System.Windows.Automation). The test visits every
      section through the navigation (which loads each lazy section), and in each one
      checks that every keyboard-focusable element has a Name and that Tab traversal
      reaches every tab stop; first render is measured (soft gate: a warning above 2 s,
      never a failure). It skips with a reason on non-Windows hosts, non-interactive
      sessions, or when no window can be rendered (e.g. a CI runner without a usable
      desktop).
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:XamlPath = Join-Path $script:Root 'src/UI/MainWindow.xaml'
    $script:SectionDir = Join-Path $script:Root 'src/UI/Sections'
    $script:GuiPath = Join-Path $script:Root 'src/UI/OmniDiagGui.psm1'
    $script:Manifest = Join-Path $script:Root 'src/OmniDiag.psd1'
    Import-Module $script:Manifest -Force -DisableNameChecking -Global
    $script:Gui = (Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'OmniDiagGui' } | Select-Object -First 1

    # The shell (window, top bar, navigation, Dashboard, status bar) ...
    $script:XamlRaw = Get-Content -LiteralPath $script:XamlPath -Raw
    [xml]$script:Xaml = $script:XamlRaw
    # ... and the lazily loaded section fragments (plus their shared styles).
    $script:FragmentPaths = @(Get-ChildItem -LiteralPath $script:SectionDir -Filter '*.xaml' -File | Sort-Object Name | ForEach-Object { $_.FullName })
    $script:XamlDocs = @($script:Xaml) + @($script:FragmentPaths | ForEach-Object { [xml](Get-Content -LiteralPath $_ -Raw) })
    $script:AllXamlRaw = (@($script:XamlRaw) + @($script:FragmentPaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw })) -join "`n"
    $script:GuiSource = Get-Content -LiteralPath $script:GuiPath -Raw
    $script:XNs = 'http://schemas.microsoft.com/winfx/2006/xaml'

    function Get-XamlElement {
        # Elements of the given types across the shell and every fragment.
        param([string[]] $LocalName)
        @(foreach ($doc in $script:XamlDocs) { $doc.SelectNodes('//*') | Where-Object { $LocalName -contains $_.LocalName } })
    }
    function Get-XamlLabel {
        # A control's accessible label: AutomationProperties.Name, else its Content text.
        param($Node)
        $name = $Node.GetAttribute('AutomationProperties.Name')
        if ($name) { return $name }
        return ($Node.GetAttribute('Content') -replace '_', '')
    }
    function Get-XamlId {
        param($Node)
        $id = $Node.GetAttribute('Name', $script:XNs)
        if (-not $id) { $id = "<$($Node.LocalName) Content='$($Node.GetAttribute('Content'))'>" }
        $id
    }
}

Describe 'GUI accessibility: XAML (cross-platform)' {
    It 'names every interactive control (AutomationProperties.Name or Content text)' {
        $types = 'Button', 'ToggleButton', 'CheckBox', 'ComboBox', 'TextBox', 'ListBox', 'DataGrid', 'RadioButton', 'ListBoxItem', 'PasswordBox', 'Slider'
        $unnamed = @(Get-XamlElement $types | Where-Object { -not (Get-XamlLabel $_).Trim() } | ForEach-Object { Get-XamlId $_ })
        $unnamed | Should -BeNullOrEmpty -Because 'screen readers announce controls by name'
    }

    It 'gives icon-only buttons an explicit AutomationProperties.Name' {
        $iconOnly = @(Get-XamlElement 'Button' | Where-Object {
            $content = ($_.GetAttribute('Content') -replace '_', '')
            $content -and $content -notmatch '[A-Za-z]{2,}'
        })
        $iconOnly.Count | Should -BeGreaterThan 0 -Because 'the Help button is "?"'
        foreach ($b in $iconOnly) { $b.GetAttribute('AutomationProperties.Name') | Should -Not -BeNullOrEmpty }
    }

    It 'gives every DataGrid column a header' {
        $cols = Get-XamlElement 'DataGridTextColumn', 'DataGridCheckBoxColumn', 'DataGridTemplateColumn'
        $cols.Count | Should -BeGreaterThan 10
        @($cols | Where-Object { -not $_.GetAttribute('Header').Trim() } | ForEach-Object { $_.GetAttribute('Binding') }) |
            Should -BeNullOrEmpty
    }

    It 'names data grid rows for screen readers (row style binds AutomationProperties.Name)' {
        foreach ($grid in (Get-XamlElement 'DataGrid')) {
            $id = Get-XamlId $grid
            $rowStyle = $grid.GetAttribute('RowStyle')
            if ($rowStyle) {
                $rowStyle | Should -Match 'FindingRowStyle|NamedRowStyle' -Because "$id rows need a name"
            } else {
                $inline = @($grid.SelectNodes('.//*') | Where-Object { $_.LocalName -eq 'Setter' -and $_.GetAttribute('Property') -eq 'AutomationProperties.Name' })
                $inline.Count | Should -BeGreaterThan 0 -Because "$id rows need a name"
            }
        }
        foreach ($key in 'FindingRowStyle', 'NamedRowStyle') {
            $style = @(Get-XamlElement 'Style' | Where-Object { $_.GetAttribute('Key', $script:XNs) -eq $key })
            $style.Count | Should -Be 1
            @($style[0].SelectNodes('.//*') | Where-Object { $_.LocalName -eq 'Setter' -and $_.GetAttribute('Property') -eq 'AutomationProperties.Name' }).Count |
                Should -Be 1
        }
    }

    It 'binds the keyboard shortcuts as window KeyBindings' {
        $bindings = @(Get-XamlElement 'KeyBinding' | ForEach-Object {
            [pscustomobject]@{
                Key = $_.GetAttribute('Key'); Modifiers = $_.GetAttribute('Modifiers')
                Command = $_.GetAttribute('Command'); Parameter = $_.GetAttribute('CommandParameter')
            }
        })
        $expected = @(
            @('F5', '', 'Scan'), @('Escape', '', 'Cancel'), @('E', 'Control', 'Export'),
            @('F', 'Control', 'Find'), @('T', 'Alt', 'Theme'), @('F1', '', 'Help')
        ) + @(1..9 | ForEach-Object { , @("D$_", 'Control', "Nav$_") })
        foreach ($e in $expected) {
            $hit = @($bindings | Where-Object { $_.Key -eq $e[0] -and $_.Modifiers -eq $e[1] -and $_.Parameter -eq $e[2] })
            $hit.Count | Should -Be 1 -Because "$($e[1])+$($e[0]) should raise '$($e[2])'"
        }
        $bindings | ForEach-Object { $_.Command | Should -Be 'NavigationCommands.GoToPage' }
        # The bindings sit on the shell root and are moved onto the window when the shell
        # loads (Complete-OmniShellLoad), so they work wherever focus is.
        @($script:Xaml.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'Grid.InputBindings' }).Count | Should -Be 1
        $load = [regex]::Match($script:GuiSource, '(?s)function Complete-OmniShellLoad \{.*?\n\}\r?\n').Value
        $load | Should -Match '\$window\.InputBindings\.Add'
        $load | Should -Match '\$root\.InputBindings\.Clear\(\)'
    }

    It 'dispatches every KeyBinding parameter in code' {
        $script:GuiSource | Should -Match 'NavigationCommands\]::GoToPage'
        foreach ($p in 'Scan', 'Cancel', 'Export', 'Find', 'Theme', 'Help') {
            $script:GuiSource | Should -Match ([regex]::Escape("'^$p`$'"))
        }
        $script:GuiSource | Should -Match ([regex]::Escape("'^Nav(\d)`$'"))
    }

    It 'documents every shortcut in the in-app help and docs/GUI.md' {
        $help = & $script:Gui { $script:OmniShortcutHelp }
        $params = @($help | ForEach-Object { $_.Parameter } | Where-Object { $_ })
        foreach ($p in 'Scan', 'Cancel', 'Export', 'Find', 'Theme', 'Help', 'Nav1') { $params | Should -Contain $p }
        $doc = Get-Content -LiteralPath (Join-Path $script:Root 'docs/GUI.md') -Raw
        foreach ($k in 'F5', 'Esc', 'Ctrl+E', 'Ctrl+F', 'Alt+T', 'F1', 'Ctrl+1', 'Enter', 'High Contrast', 'Narrator') {
            $doc | Should -Match ([regex]::Escape($k))
        }
    }

    It 'uses unique access keys, and none on T (Alt+T toggles the theme)' {
        $keys = @(Get-XamlElement 'Button', 'CheckBox', 'Label', 'RadioButton' | ForEach-Object {
            $c = $_.GetAttribute('Content')
            if ($c -match '_(\w)') { $Matches[1].ToUpperInvariant() }
        })
        $keys.Count | Should -BeGreaterThan 10
        @($keys | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
        $keys | Should -Not -Contain 'T'
        foreach ($k in 'S', 'C', 'E') { $keys | Should -Contain $k }   # _Scan, _Cancel, _Export
    }

    It 'renders access-key underscores in the custom Button template' {
        $presenter = @(Get-XamlElement 'ContentPresenter' | Where-Object { $_.GetAttribute('RecognizesAccessKey') -eq 'True' })
        $presenter.Count | Should -BeGreaterThan 0
    }

    It 'sets a visible keyboard focus style on buttons, checkboxes, combo boxes, list items, and grids' {
        foreach ($t in 'Button', 'CheckBox', 'ComboBox', 'ListBoxItem', 'DataGrid') {
            $style = @(Get-XamlElement 'Style' | Where-Object { $_.GetAttribute('TargetType') -eq $t -and -not $_.GetAttribute('Key', $script:XNs) })
            $style.Count | Should -Be 1 -Because "implicit $t style"
            @($style[0].SelectNodes('*') | Where-Object { $_.GetAttribute('Property') -eq 'FocusVisualStyle' }).Count | Should -Be 1
        }
        # The focus rectangle uses a theme brush (mapped to a SystemColors brush in high contrast).
        $script:XamlRaw | Should -Match 'Stroke="\{DynamicResource BrushFocus\}"'
    }

    It 'orders the top bar before navigation and content (TabIndex)' {
        $order = 'ChkNetworkProbes', 'CmbRange', 'BtnScan', 'BtnCancel', 'BtnExport', 'BtnTheme', 'BtnHelp', 'NavList'
        $idx = foreach ($n in $order) {
            $node = @($script:Xaml.SelectNodes('//*') | Where-Object { $_.GetAttribute('Name', $script:XNs) -eq $n })[0]
            [int]$node.GetAttribute('TabIndex')
        }
        for ($i = 1; $i -lt $idx.Count; $i++) { $idx[$i] | Should -BeGreaterThan $idx[$i - 1] }
    }

    It 'conveys severity with theme brushes only (no hard-coded colors in triggers)' {
        $setters = @(Get-XamlElement 'DataTrigger' | ForEach-Object { $_.SelectNodes('*') } | Where-Object { $_.GetAttribute('Property') -eq 'Foreground' })
        $setters.Count | Should -BeGreaterThan 0
        foreach ($s in $setters) { $s.GetAttribute('Value') | Should -Match '^\{DynamicResource Brush' }
        # ...and severity is always also a text column.
        @(Get-XamlElement 'DataGridTextColumn' | Where-Object { $_.GetAttribute('Header') -eq 'Severity' }).Count | Should -BeGreaterOrEqual 2
    }

    It 'makes status and progress polite live regions' {
        $live = & $script:Gui { $script:OmniLiveRegionControls }
        $live | Should -Contain 'TxtStatus'
        $live | Should -Contain 'ProgressBarMain'
        $script:GuiSource | Should -Match 'Enable-OmniLiveRegion -Element'
        $script:GuiSource | Should -Match "'LiveSettingProperty'"
        $script:GuiSource | Should -Match "'Polite'"
        $script:GuiSource | Should -Match "'LiveRegionChanged'"
    }

    It 'is ASCII-only (XAML shell, section fragments, and code-behind)' {
        $script:FragmentPaths.Count | Should -BeGreaterOrEqual 7
        foreach ($path in @($script:XamlPath, $script:GuiPath) + $script:FragmentPaths) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because $path
        }
    }
}

Describe 'GUI code-behind matches the XAML (cross-platform)' {
    It 'defines every x:Name the code looks up (in the shell or a section fragment)' {
        $names = & $script:Gui { $script:OmniUiControlNames }
        $names.Count | Should -BeGreaterThan 40
        foreach ($n in $names) { $script:AllXamlRaw | Should -Match ('x:Name="' + $n + '"') }
    }

    It 'loads sections lazily: the window factory parses only the shell, navigation loads the rest' {
        $factory = [regex]::Match($script:GuiSource, '(?s)function Initialize-OmniMainWindow \{.*?\n\}\r?\n').Value
        $factory | Should -Not -BeNullOrEmpty
        # Code only: the factory's help and comments mention Import-OmniSection by name.
        $factoryCode = (($factory -replace '(?s)<#.*?#>', '') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $factoryCode | Should -Not -Match 'Import-OmniSection|Get-OmniSectionXaml'
        $nav = [regex]::Match($script:GuiSource, '(?s)function Show-OmniNavPanel \{.*?\n\}\r?\n').Value
        $nav | Should -Match 'Import-OmniSection'
        # Every navigation panel except the Dashboard is a lazily loaded section.
        $panels = & $script:Gui { $script:OmniNavPanels }
        foreach ($p in @($panels | Select-Object -Skip 1)) {
            (& $script:Gui { param($h) Get-OmniSectionForHost -HostName $h } $p) | Should -Not -BeNullOrEmpty -Because $p
        }
        (& $script:Gui { param($h) Get-OmniSectionForHost -HostName $h } 'PanelDashboard') | Should -BeNullOrEmpty
    }

    It 'only reaches for controls it looked up' {
        $names = & $script:Gui { $script:OmniUiControlNames }
        $used = [regex]::Matches($script:GuiSource, '(?:\$(?:ui|Ui|script:OmniUi)\.Controls|\$controls|\$c)\.([A-Za-z]+)', 'IgnoreCase') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        @($used).Count | Should -BeGreaterThan 30
        @($used | Where-Object { $names -notcontains $_ }) | Should -BeNullOrEmpty
    }

    It 'maps each navigation item to an existing panel, in order' {
        $panels = & $script:Gui { $script:OmniNavPanels }
        $items = @(Get-XamlElement 'ListBoxItem' | Where-Object { $_.ParentNode.GetAttribute('Name', $script:XNs) -eq 'NavList' })
        $items.Count | Should -Be $panels.Count
        for ($i = 0; $i -lt $items.Count; $i++) { $items[$i].GetAttribute('Tag') | Should -Be $panels[$i] }
        foreach ($p in $panels) { $script:XamlRaw | Should -Match ('x:Name="' + $p + '"') }
        $items[1].GetAttribute('Content') | Should -Be 'Groups'
    }

    It 'covers every palette key in the high-contrast SystemColors map' {
        $map = & $script:Gui { Get-OmniHighContrastBrushMap }
        $light = Get-OmniThemePalette -Name Light
        ($map.Keys | Sort-Object) | Should -Be ($light.Keys | Sort-Object)
        $systemBrushes = 'WindowBrush', 'WindowTextBrush', 'ControlBrush', 'ControlTextBrush', 'HighlightBrush',
            'HighlightTextBrush', 'HotTrackBrush', 'GrayTextBrush'
        foreach ($v in $map.Values) { $systemBrushes | Should -Contain $v }
        # Severity carries no color in high contrast.
        foreach ($k in @($map.Keys | Where-Object { $_ -like 'BrushSev*' })) { $map[$k] | Should -Be 'WindowTextBrush' }
        # Every palette key is declared in the XAML so DynamicResource lookups resolve.
        foreach ($k in $light.Keys) { $script:XamlRaw | Should -Match ('x:Key="' + $k + '"') }
    }

    It 'follows the Windows high-contrast setting live' {
        $script:GuiSource | Should -Match 'SystemParameters\]::HighContrast'
        $script:GuiSource | Should -Match 'add_StaticPropertyChanged'
        $script:GuiSource | Should -Match 'remove_StaticPropertyChanged'
    }

    It 'measures startup to first render and defers slow work until after it' {
        $script:GuiSource | Should -Match 'Add_ContentRendered'
        $script:GuiSource | Should -Match 'DispatcherPriority\]::ApplicationIdle'
        $script:GuiSource | Should -Match 'DispatcherPriority\]::Background'
        $script:GuiSource | Should -Match 'SetItemStatus\(\$ui\.Window, "StartupMs='
        # The window factory itself does no CIM / plugin discovery, elevation check, group
        # catalog, or log-file creation (all after first paint).
        $factory = [regex]::Match($script:GuiSource, '(?s)function Initialize-OmniMainWindow \{.*?\n\}\r?\n').Value
        $factory | Should -Not -BeNullOrEmpty
        $factory | Should -Not -Match 'Get-OmniSystemInfo|Get-OmniModule|Get-OmniDiagRepair|Get-CimInstance|Test-OmniIsAdministrator|Initialize-OmniGroupCatalog|New-OmniLogger'
        # First paint is a code-built frame: the factory parses no XAML at all.
        $factoryCode = (($factory -replace '(?s)<#.*?#>', '') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $factoryCode | Should -Not -Match 'XamlReader|Get-OmniMainWindowXaml'
        $factoryCode | Should -Match 'New-OmniFrameWindow'
        # The shell parses at Background priority after the frame's first paint, and
        # ShellReady (fully interactive) is a separate number from StartupMs (first paint).
        $factoryCode | Should -Match 'Complete-OmniShellLoad'
        $script:GuiSource | Should -Match 'ShellReadyMs=\$ms'
    }

    It 'routes the startup-file hook through Resolve-OmniOutputPath (devices, pipes, and streams refused)' {
        $ok = Join-Path $TestDrive 'gui-startup.json'
        $r = & $script:Gui {
            param($okPath)
            $saved = $script:OmniUi
            try {
                $script:OmniUi = @{
                    StartupTimings = $null; StartupMs = 11; ShellReadyMs = 22; FramePaintedUtc = $null
                    ShellReadyUtc = [DateTime]::UtcNow; Logger = $null; PendingWarnings = [System.Collections.ArrayList]::new()
                }
                $refused = @(foreach ($bad in @('\\.\pipe\omnidiag-gui-test', '\\localhost\pipe\omnidiag-gui-test', '\\.\NUL', ($okPath + ':stream'))) {
                    $threw = $false
                    try { $null = Write-OmniStartupFile -Path $bad } catch { $threw = $true }
                    [pscustomobject]@{ Path = $bad; Refused = $threw }
                })
                $written = Write-OmniStartupFile -Path $okPath
                # A honored hook is never silent: queued for the GUI log until it opens.
                Write-OmniHookWarning -Message 'test hook warning'
                [pscustomobject]@{ Refused = $refused; Written = $written; Pending = @($script:OmniUi.PendingWarnings) }
            } finally { $script:OmniUi = $saved }
        } $ok 2>$null
        foreach ($x in $r.Refused) { $x.Refused | Should -BeTrue -Because "$($x.Path) must be refused" }
        $r.Written | Should -Be ([System.IO.Path]::GetFullPath($ok))
        $doc = Get-Content -LiteralPath $ok -Raw | ConvertFrom-Json
        $doc.StartupMs | Should -Be 11
        $doc.ShellReadyMs | Should -Be 22
        $r.Pending | Should -Be @('test hook warning')
    }

    It 'never honors a test hook silently (Warn in the GUI log and stderr)' {
        $ready = [regex]::Match($script:GuiSource, '(?s)function Complete-OmniShellReady \{.*?\n\}\r?\n').Value
        $ready | Should -Match 'Write-OmniHookWarning -Message "OMNIDIAG_GUI_STARTUP_FILE is set'
        $ready | Should -Match "Write-OmniHookWarning -Message 'OMNIDIAG_GUI_EXIT_AFTER_RENDER is set"
        # The file write goes through the output-path check, never straight to the raw value.
        $file = [regex]::Match($script:GuiSource, '(?s)function Write-OmniStartupFile \{.*?\n\}\r?\n').Value
        $file | Should -Match 'Resolve-OmniOutputPath -Path \$Path'
        $file | Should -Match 'WriteAllText\(\$target,'
        $file | Should -Not -Match 'WriteAllText\(\$Path'
        $warn = [regex]::Match($script:GuiSource, '(?s)function Write-OmniHookWarning \{.*?\n\}\r?\n').Value
        $warn | Should -Match "Log\('Warn'"
        $warn | Should -Match '\[Console\]::Error\.WriteLine'
        $post = [regex]::Match($script:GuiSource, '(?s)function Invoke-OmniPostRenderSetup \{.*?\n\}\r?\n').Value
        $post | Should -Match 'PendingWarnings'
    }

    It 'applies the brushes once: the shell swap updates only the theme controls' {
        $load = [regex]::Match($script:GuiSource, '(?s)function Complete-OmniShellLoad \{.*?\n\}\r?\n').Value
        $loadCode = (($load -replace '(?s)<#.*?#>', '') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $loadCode | Should -Match 'Sync-OmniThemeControl'
        $loadCode | Should -Not -Match 'Sync-OmniEffectiveTheme|Set-OmniEffectiveBrush|Set-OmniTheme'
        # The combined step (brushes + controls) stays for startup and runtime changes.
        $sync = [regex]::Match($script:GuiSource, '(?s)function Sync-OmniEffectiveTheme \{.*?\n\}\r?\n').Value
        $sync | Should -Match 'Set-OmniEffectiveBrush'
        $sync | Should -Match 'Sync-OmniThemeControl'
        $brush = [regex]::Match($script:GuiSource, '(?s)function Set-OmniEffectiveBrush \{.*?\n\}\r?\n').Value
        $brush | Should -Match 'Set-OmniTheme -Window \$ui\.Window -Name HighContrast'
        $brush | Should -Match '\$ui\.HighContrast = Test-OmniHighContrast'
        # High contrast keeps following Windows at runtime (both brushes and controls).
        $factory = [regex]::Match($script:GuiSource, '(?s)function Initialize-OmniMainWindow \{.*?\n\}\r?\n').Value
        $factory | Should -Match "PropertyName -ne 'HighContrast'"
        $factory | Should -Match '(?s)add_StaticPropertyChanged.*Add_Activated'
        ([regex]::Matches($factory, 'Sync-OmniEffectiveTheme')).Count | Should -BeGreaterOrEqual 3
    }

    It 'gives the frame window an accessible, themed loading state' {
        $frame = [regex]::Match($script:GuiSource, '(?s)function New-OmniFrameWindow \{.*?\n\}\r?\n').Value
        $frame | Should -Not -BeNullOrEmpty
        $frame | Should -Not -Match 'XamlReader'
        $frame | Should -Match "SetName\(\`$status, 'Loading OmniDiag\.\.\.'\)"
        $frame | Should -Match "SetName\(\`$w, 'OmniDiag'\)"
        $frame | Should -Match "SetAutomationId\(\`$w, 'OmniDiagMainWindow'\)"
        $frame | Should -Match 'Enable-OmniLiveRegion -Element \$status'
        $frame | Should -Match "SetResourceReference\(\[System\.Windows\.Controls\.Control\]::BackgroundProperty, 'BrushWindowBg'\)"
        # The theme (or high contrast) is applied to the frame before it is shown.
        $factory = [regex]::Match($script:GuiSource, '(?s)function Initialize-OmniMainWindow \{.*?\n\}\r?\n').Value
        $factory | Should -Match 'Sync-OmniEffectiveTheme'
        # Interactions before the shell is ready are ignored safely.
        foreach ($fn in 'Invoke-OmniShortcut', 'Invoke-OmniThemeToggle', 'Sync-OmniBusyState', 'Invoke-OmniPostRenderSetup', 'Invoke-OmniDeferredStartup') {
            $body = [regex]::Match($script:GuiSource, '(?s)function ' + $fn + ' \{.*?\n\}\r?\n').Value
            $body | Should -Match 'ShellReady' -Because "$fn must not touch shell controls before the shell is in place"
        }
        # Queued shell work does nothing once the window has closed.
        $script:GuiSource | Should -Match '\$ui\.Closed = \$true'
    }

    It 'declares Light-palette fallbacks in the shell XAML; the window''s theme brushes win when it loads' {
        $light = Get-OmniThemePalette -Name Light
        foreach ($k in $light.Keys) {
            $m = [regex]::Match($script:XamlRaw, 'x:Key="' + $k + '"\s+Color="(#[0-9A-Fa-f]{6})"')
            $m.Success | Should -BeTrue -Because "$k must be a SolidColorBrush with a #RRGGBB color"
            $m.Groups[1].Value.ToUpperInvariant() | Should -Be $light[$k].ToUpperInvariant() -Because $k
        }
        $load = [regex]::Match($script:GuiSource, '(?s)function Complete-OmniShellLoad \{.*?\n\}\r?\n').Value
        $load | Should -Match 'if \(-not \$window\.Resources\.Contains\(\$key\)\)'
        $load | Should -Match '\$shellResources\.Clear\(\)'
        # The shell is not a Window (the frame is), and names resolve on its own name scope.
        $script:Xaml.DocumentElement.LocalName | Should -Be 'Grid'
        $load | Should -Match '\$root\.FindName\(\$n\)'
    }

    It 'records startup phase checkpoints and turns off the legacy accessibility switches before WPF loads' {
        foreach ($phase in 'Entry', 'StaRunspaceReady', 'WpfPreloaded', 'ModuleImported', 'InitializeStart', 'WpfAssembliesLoaded',
            'XamlEngineReady', 'ShellParsed', 'XamlParsed', 'WindowConstructed', 'ShowCalled', 'ContentRendered',
            'FramePainted', 'ShellReady') {
            $script:GuiSource | Should -Match ("Add-OmniStartupMark -Name '" + $phase + "'")
        }
        # Each lazily loaded section is marked when it loads.
        $script:GuiSource | Should -Match ([regex]::Escape('Add-OmniStartupMark -Name "Section${Name}Loaded"'))
        foreach ($sw in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3') {
            $script:GuiSource | Should -Match ([regex]::Escape("'$sw'"))
        }
        $factory = [regex]::Match($script:GuiSource, '(?s)function Initialize-OmniMainWindow \{.*?\n\}\r?\n').Value
        $factory.IndexOf('Disable-OmniLegacyAccessibility') | Should -BeLessThan $factory.IndexOf('Add-Type -AssemblyName PresentationFramework')
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $line = & $script:Gui {
            param($c)
            $saved = $script:OmniStartupMarks
            try {
                $script:OmniStartupMarks = $null
                Add-OmniStartupMark -Name 'Entry' -Clock $c
                Add-OmniStartupMark -Name 'XamlParsed' -Clock $c
                Add-OmniStartupMark -Name 'Entry' -Clock $c
                Format-OmniStartupTiming
            } finally { $script:OmniStartupMarks = $saved }
        } $clock
        $line | Should -Match '^Entry=\d+ ms, XamlParsed=\d+ ms$'
    }

    It 'exports reports in a background runspace, with the redaction option gated on -Redact' {
        $export = [regex]::Match($script:GuiSource, '(?s)function Invoke-OmniExportRequest \{.*?\n\}\r?\n').Value
        $export | Should -Match 'Invoke-OmniUiTask'
        $export | Should -Not -Match 'Export-OmniReport'
        $script:GuiSource | Should -Match "Parameters\.ContainsKey\('Redact'\)"
        $script:GuiSource | Should -Match 'Redact identifiers for sharing'
        $script:GuiSource | Should -Match 'Bundle \(\.zip\)'
    }

    It 'detects whether Export-OmniDiagReport -Redact can run' {
        $expected = (Get-Command Export-OmniDiagReport).Parameters.ContainsKey('Redact') -and
            [bool](Get-Command New-OmniRedactionContext -ErrorAction SilentlyContinue) -and
            [bool](Get-Command ConvertTo-OmniRedacted -ErrorAction SilentlyContinue)
        (& $script:Gui { Test-OmniRedactSupported }) | Should -Be $expected
    }
}

Describe 'GUI findings and group helpers (cross-platform)' {
    BeforeAll {
        $mk = {
            param($Module, $Group, $Status, [object[]] $Findings)
            [pscustomobject]@{
                ModuleName = $Module; Category = $Group; Group = $Group; Status = $Status; DurationMs = 12
                Findings = $Findings
            }
        }
        $f1 = New-OmniFinding -Title 'Disk almost full' -Severity Critical -Component 'C:' -Detail '2 GB free' `
            -LikelyCause 'Large temp files' -Recommendation 'Free up space' -Data @{ FreeGB = 2; Drive = 'C:' }
        $f2 = New-OmniFinding -Title 'TRIM enabled' -Severity Pass -Component 'Storage'
        $f3 = New-OmniFinding -Title 'DNS suffix missing' -Severity Warning -Component 'Ethernet' -Recommendation 'Set the suffix'
        $script:Session = [pscustomobject]@{
            Results = @(
                (& $mk 'Disk Space' 'storage' 'Critical' @($f1, $f2)),
                (& $mk 'DNS Resolver' 'network' 'Warning' @($f3))
            )
        }
        $script:Groups = @(
            @{ Id = 'storage'; Name = 'Storage'; Description = 'Disks'; ScannerCount = 5 },
            @{ Id = 'network'; Name = 'Network'; Description = 'Adapters'; ScannerCount = 7 },
            @{ Id = 'security'; Name = 'Security'; Description = 'Defender'; ScannerCount = 4 }
        )
        $script:Names = @{ storage = 'Storage'; network = 'Network'; security = 'Security' }
    }

    It 'flattens findings into rows, most severe first, with group names and screen-reader names' {
        $rows = @(& $script:Gui { param($s, $n) ConvertTo-OmniGuiFindingRow -Session $s -GroupNames $n } $script:Session $script:Names)
        $rows.Count | Should -Be 3
        $rows[0].Severity | Should -Be 'Critical'
        $rows[-1].Severity | Should -Be 'Pass'
        $rows[0].GroupName | Should -Be 'Storage'
        $rows[0].A11yName | Should -Be 'Critical: Disk almost full (Disk Space)'
    }

    It 'filters findings by words and by severity' {
        $rows = @(& $script:Gui { param($s, $n) ConvertTo-OmniGuiFindingRow -Session $s -GroupNames $n } $script:Session $script:Names)
        $f = { param($t, $sev) @(& $script:Gui { param($r, $t, $sev) Select-OmniFindingRow -Row $r -Text $t -Severity $sev } $rows $t $sev) }
        @(& $f '' 'All severities').Count | Should -Be 3
        @(& $f 'almost' '').Count | Should -Be 1
        @(& $f 'disk' '').Count | Should -Be 2               # title or module name
        @(& $f 'network suffix' '').Count | Should -Be 1     # every word must match (group name + title)
        @(& $f '' 'Warning').Count | Should -Be 1
        @(& $f 'disk' 'Warning').Count | Should -Be 0
    }

    It 'formats the finding detail panel with cause, recommendation, and evidence' {
        $rows = @(& $script:Gui { param($s, $n) ConvertTo-OmniGuiFindingRow -Session $s -GroupNames $n } $script:Session $script:Names)
        $text = & $script:Gui { param($r) Format-OmniFindingDetail -Row $r } $rows[0]
        foreach ($s in 'Disk almost full', 'Severity: Critical', 'Component: C:', 'Group: Storage', 'Likely cause:',
                       'Large temp files', 'Recommendation:', 'Free up space', 'Evidence:', 'FreeGB: 2') {
            $text | Should -Match ([regex]::Escape($s))
        }
        (& $script:Gui { Format-OmniFindingDetail -Row $null }) | Should -Match 'Select a finding'
    }

    It 'summarizes evidence briefly' {
        $long = 'x' * 500
        $out = & $script:Gui { param($d) Format-OmniEvidenceSummary -Data $d -MaxItems 2 } ([ordered]@{ A = 1; B = $long; C = 3 })
        $lines = $out -split "`r?`n"
        $lines.Count | Should -Be 3
        $lines[1].Length | Should -BeLessThan 200
        $lines[2] | Should -Match '1 more'
        (& $script:Gui { Format-OmniEvidenceSummary -Data $null }) | Should -Be ''
        (& $script:Gui { Format-OmniEvidenceSummary -Data ([pscustomobject]@{ Port = 443 }) }) | Should -Be 'Port: 443'
    }

    It 'summarizes each group: worst severity, counts, scanners, and a screen-reader name' {
        $rows = @(& $script:Gui { param($g, $s) Get-OmniGroupSummaryRow -Group $g -Session $s } $script:Groups $script:Session)
        $rows.Count | Should -Be 3
        $storage = $rows | Where-Object Id -eq 'storage'
        $storage.Worst | Should -Be 'Critical'
        $storage.Critical | Should -Be 1
        $storage.Scanners | Should -Be '1 of 5'
        $storage.Score | Should -Not -Be '-'
        $storage.A11yName | Should -Match '^Storage: .+ worst severity Critical'
        ($rows | Where-Object Id -eq 'network').Worst | Should -Be 'Warning'
        $security = $rows | Where-Object Id -eq 'security'
        $security.Status | Should -Be 'Not scanned'
        $security.Worst | Should -Be '-'
    }

    It 'lists groups before the first scan' {
        $rows = @(& $script:Gui { param($g) Get-OmniGroupSummaryRow -Group $g -Session $null } $script:Groups)
        $rows.Count | Should -Be 3
        $rows | ForEach-Object { $_.Status | Should -Be 'No scan yet' }
    }

    It 'lists module rows for one group' {
        $rows = @(& $script:Gui { param($s, $n) Get-OmniModuleRow -Session $s -GroupNames $n -GroupId 'network' } $script:Session $script:Names)
        $rows.Count | Should -Be 1
        $rows[0].Module | Should -Be 'DNS Resolver'
        $rows[0].A11yName | Should -Be 'DNS Resolver: Warning, 1 finding(s)'
    }

    It 'covers every v1.0 group from Get-OmniDiagGroup' {
        $groups = @(Get-OmniDiagGroup | ForEach-Object { @{ Id = $_.Id; Name = $_.Name; Description = $_.Description; ScannerCount = $_.ScannerCount } })
        $groups.Count | Should -BeGreaterOrEqual 10
        $rows = @(& $script:Gui { param($g) Get-OmniGroupSummaryRow -Group $g -Session $null } $groups)
        $rows.Count | Should -Be $groups.Count
    }

    It 'puts the keyboard reference into plain text' {
        $text = & $script:Gui { Get-OmniShortcutHelpText }
        foreach ($k in 'F5', 'Esc', 'Ctrl+E', 'Ctrl+F', 'Alt+T', 'F1') { $text | Should -Match ([regex]::Escape($k)) }
    }
}

Describe 'GUI under UI Automation (Windows desktop only)' {
    BeforeAll {
        $script:UiaSkip = $null
        $script:UiaResult = $null
        $onWindows = $true
        try { if ($IsWindows -eq $false) { $onWindows = $false } } catch { $onWindows = $true }
        if (-not $onWindows) {
            $script:UiaSkip = 'requires Windows (WPF + UI Automation)'
        } elseif (-not [Environment]::UserInteractive) {
            $script:UiaSkip = 'requires an interactive desktop session ([Environment]::UserInteractive is false)'
        } elseif ($env:OMNIDIAG_SKIP_UIA) {
            $script:UiaSkip = 'disabled by OMNIDIAG_SKIP_UIA'
        } else {
            try {
                Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationClient, UIAutomationTypes -ErrorAction Stop
            } catch {
                $script:UiaSkip = "WPF / UI Automation assemblies unavailable: $($_.Exception.Message)"
            }
        }
        if ($script:UiaSkip) { return }

        # Host the window on its own STA thread with a running dispatcher. UI Automation
        # client calls must not come from the window's own thread, so they run here.
        # Protocol per section: this thread sets NavRequest = <index>; the window thread
        # navigates there (loading a lazy section on first visit), walks Tab traversal,
        # stores the result in Sections[<index>], and sets NavDone = <index>; this thread
        # then runs the UI Automation name check on what is now shown.
        $sync = [hashtable]::Synchronized(@{
            Stage = 'starting'; Ready = $false; Error = $null; Hwnd = [IntPtr]::Zero
            StartupMs = $null; ShellReadyMs = $null; StartupTimings = ''; Stop = $false; Closed = $false
            Sections = [hashtable]::Synchronized(@{}); NavRequest = -1; NavDone = -1; NavBusy = $false
        })
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($Sync, $Manifest, $SrcRoot)
            $window = $null
            try {
                $Sync.Stage = 'import'
                Import-Module $Manifest -Force -DisableNameChecking
                $gui = (Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'OmniDiagGui' } | Select-Object -First 1
                $Sync.Stage = 'construct'
                $clock = [System.Diagnostics.Stopwatch]::StartNew()
                $window = & $gui {
                    param($m, $src, $c)
                    Initialize-OmniMainWindow -RootManifest $m -ModulesPath (Join-Path $src 'Modules') -RepairsPath (Join-Path $src 'Repairs') -StartupClock $c
                } $Manifest $SrcRoot $clock

                $Sync.Stage = 'show'
                $pump = { $window.Dispatcher.Invoke([Action] { }, [System.Windows.Threading.DispatcherPriority]::ContextIdle) }
                $window.ShowActivated = $true
                & $gui { param($c) Add-OmniStartupMark -Name 'ShowCalled' -Clock $c } $clock
                $window.Show()
                $deadline = [DateTime]::UtcNow.AddSeconds(20)
                while ($null -eq (& $gui { $script:OmniUi.StartupMs }) -and [DateTime]::UtcNow -lt $deadline) {
                    & $pump
                    Start-Sleep -Milliseconds 10
                }
                $Sync.StartupMs = & $gui { $script:OmniUi.StartupMs }
                if ($null -eq $Sync.StartupMs) { throw 'the window never rendered (no ContentRendered within 20 s)' }
                # First paint is the code-built frame; the shell (and every control) follows.
                $Sync.Stage = 'shell'
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                while ($null -eq (& $gui { $script:OmniUi.ShellReadyMs }) -and -not (& $gui { $script:OmniUi.ShellError }) -and [DateTime]::UtcNow -lt $deadline) {
                    & $pump
                    Start-Sleep -Milliseconds 10
                }
                $shellError = & $gui { $script:OmniUi.ShellError }
                if ($shellError) { throw "the shell XAML did not load: $shellError" }
                $Sync.ShellReadyMs = & $gui { $script:OmniUi.ShellReadyMs }
                if ($null -eq $Sync.ShellReadyMs) { throw 'the shell never became ready (no ShellReady within 30 s)' }
                $Sync.StartupTimings = [string](& $gui { Format-OmniStartupTiming -Marks $script:OmniUi.StartupTimings })
                $Sync.Hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle

                $Sync.Stage = 'tab'
                [void]$window.Activate()
                & $pump
                # Same hashtable the GUI fills as sections load.
                $ctl = & $gui { $script:OmniUi.Controls }
                $panels = @(& $gui { $script:OmniNavPanels })
                $describe = {
                    param($el)
                    $n = [System.Windows.Automation.AutomationProperties]::GetName($el)
                    $id = if ($el -is [System.Windows.FrameworkElement] -and $el.Name) { $el.Name } else { $el.GetType().Name }
                    if ($n) { "$id ($n)" } else { $id }
                }

                # Show section $Index (loading it on first visit), then press "Tab" (MoveFocus
                # Next) from the first top-bar control until focus returns to an element
                # already visited, and compare with every visible, enabled tab stop.
                $walkSection = {
                    param([int] $Index)
                    & $gui { param($i) Select-OmniNavSection -Index $i -NoFocus } $Index
                    & $pump
                    $window.UpdateLayout()
                    & $pump
                    $panel = $panels[$Index]
                    $section = & $gui { param($p) Get-OmniSectionForHost -HostName $p } $panel
                    $loaded = $true
                    if ($section) { $loaded = [bool](& $gui { param($n) Test-OmniSectionLoaded -Name $n } $section) }

                    [void]$ctl.ChkNetworkProbes.Focus()
                    & $pump
                    $visited = [System.Collections.Generic.List[object]]::new()
                    $mode = 'Static'   # window could not take keyboard focus (inactive desktop)
                    if ([System.Windows.Input.Keyboard]::FocusedElement -eq $ctl.ChkNetworkProbes) {
                        $mode = 'MoveFocus'
                        for ($i = 0; $i -lt 400; $i++) {
                            $cur = [System.Windows.Input.Keyboard]::FocusedElement
                            if (-not $cur -or $visited.Contains($cur)) { break }
                            $visited.Add($cur)
                            [void]$cur.MoveFocus([System.Windows.Input.TraversalRequest]::new([System.Windows.Input.FocusNavigationDirection]::Next))
                            & $pump
                        }
                    }

                    # Tab stops - except items inside list/grid/combo/text containers (one
                    # stop per container; arrows move within).
                    $stops = [System.Collections.Generic.List[object]]::new()
                    $walk = {
                        param($node, [bool] $insideItems)
                        $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                        for ($k = 0; $k -lt $count; $k++) {
                            $child = [System.Windows.Media.VisualTreeHelper]::GetChild($node, $k)
                            if ($child -is [System.Windows.UIElement] -and -not $child.IsVisible) { continue }
                            $isTabStop = $child -is [System.Windows.Controls.Control] -and $child.Focusable -and $child.IsEnabled -and $child.IsTabStop
                            if ($isTabStop -and -not $insideItems) { $stops.Add($child) }
                            $nextInside = $insideItems -or $child -is [System.Windows.Controls.ItemsControl] -or $child -is [System.Windows.Controls.Primitives.TextBoxBase]
                            & $walk $child $nextInside
                        }
                    }
                    & $walk $window $false
                    # A stop counts as reached when focus landed on it or inside it (an
                    # editable combo box focuses its text part; a grid may focus a cell).
                    $isReached = {
                        param($stop)
                        if ($visited.Contains($stop)) { return $true }
                        foreach ($v in $visited) {
                            if ($v -is [System.Windows.Media.Visual] -and $v.IsDescendantOf($stop)) { return $true }
                        }
                        return $false
                    }
                    $unreached = @()
                    if ($mode -eq 'MoveFocus') { $unreached = @($stops | Where-Object { -not (& $isReached $_) } | ForEach-Object { & $describe $_ }) }
                    return @{
                        Panel = $panel; Section = $section; Loaded = $loaded; Mode = $mode
                        Visited = @($visited | ForEach-Object { & $describe $_ })
                        Unreached = $unreached
                        TabStops = @($stops | ForEach-Object { & $describe $_ })
                    }
                }

                # Section 0 (the Dashboard, already shown) before handing over.
                $Sync.Sections[0] = & $walkSection 0
                $Sync.NavDone = 0
                $Sync.Stage = 'ready'
                $Sync.Ready = $true

                # Keep the dispatcher pumping (UI Automation requests are served on this thread)
                # and serve navigation requests until the test asks us to stop, or a safety timeout.
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $limit = [DateTime]::UtcNow.AddSeconds(240)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(100)
                $timer.Add_Tick({
                    $want = [int]$Sync.NavRequest
                    if (-not $Sync.NavBusy -and $want -ge 0 -and $want -ne [int]$Sync.NavDone) {
                        # NavBusy: walkSection pumps the dispatcher, so this tick can re-enter.
                        $Sync.NavBusy = $true
                        try {
                            $Sync.Sections[$want] = & $walkSection $want
                        } catch {
                            $Sync.Sections[$want] = @{ Panel = "#$want"; Error = $_.Exception.Message }
                        } finally {
                            $Sync.NavDone = $want
                            $Sync.NavBusy = $false
                        }
                    }
                    if ($Sync.Stop -or [DateTime]::UtcNow -gt $limit) {
                        $timer.Stop()
                        try { $window.Close() } catch { $null = $_ }
                        $frame.Continue = $false
                    }
                })
                $timer.Start()
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
            } catch {
                $Sync.Error = "$($Sync.Stage): $($_.Exception.Message)"
                try { if ($window) { $window.Close() } } catch { $null = $_ }
            } finally {
                $Sync.Closed = $true
            }
        }).AddParameters(@{ Sync = $sync; Manifest = $script:Manifest; SrcRoot = (Join-Path $script:Root 'src') })
        $handle = $ps.BeginInvoke()
        $script:UiaHost = @{ Sync = $sync; PowerShell = $ps; Runspace = $rs; Handle = $handle }

        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while (-not $sync.Ready -and -not $sync.Closed -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if (-not $sync.Ready) {
            $why = if ($sync.Error) { $sync.Error } else { "timed out at stage '$($sync.Stage)'" }
            # Building the window must work on any Windows host; only showing it needs a desktop.
            if ($sync.Stage -in 'import', 'construct', 'shell') {
                $script:UiaResult = "FAIL: $why"
            } else {
                $script:UiaSkip = "no usable desktop to render the window ($why)"
            }
            return
        }

        # Visit every section (forcing each lazy section to load), then run the UI
        # Automation walk (from this thread) on what that section shows.
        $panels = @(& $script:Gui { $script:OmniNavPanels })
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($sync.Hwnd)
        $cond = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::IsKeyboardFocusableProperty, $true)
        $unnamed = [System.Collections.Generic.List[string]]::new()
        $problems = [System.Collections.Generic.List[string]]::new()
        $byId = @{}
        $focusableCount = 0
        for ($i = 0; $i -lt $panels.Count; $i++) {
            if ($i -gt 0) {
                $sync.NavRequest = $i
                $navDeadline = [DateTime]::UtcNow.AddSeconds(30)
                while ([int]$sync.NavDone -ne $i -and -not $sync.Closed -and [DateTime]::UtcNow -lt $navDeadline) { Start-Sleep -Milliseconds 50 }
                if ([int]$sync.NavDone -ne $i) { $problems.Add("$($panels[$i]): the window did not navigate there within 30 s"); continue }
            }
            $info = $sync.Sections[$i]
            if ($info.ContainsKey('Error')) { $problems.Add("$($panels[$i]): $($info.Error)"); continue }
            if (-not $info.Loaded) { $problems.Add("$($panels[$i]): section $($info.Section) did not load") }
            $focusable = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
            $focusableCount = [Math]::Max($focusableCount, $focusable.Count)
            foreach ($el in $focusable) {
                $c = $el.Current
                if ($c.AutomationId) { $byId[$c.AutomationId] = $c }
                if ($c.ClassName -eq 'DataGridCell') { continue }   # cells are read through their named row
                if (-not ([string]$c.Name).Trim()) {
                    $unnamed.Add(('[{0}] {1} id={2} class={3}' -f $panels[$i], $c.ControlType.ProgrammaticName, $c.AutomationId, $c.ClassName))
                }
            }
        }
        $sections = @(for ($i = 0; $i -lt $panels.Count; $i++) { if ($sync.Sections.ContainsKey($i)) { $sync.Sections[$i] } })
        $script:UiaResult = [pscustomobject]@{
            FocusableCount = $focusableCount
            Unnamed        = @($unnamed | Select-Object -Unique)
            Problems       = @($problems)
            ById           = $byId
            WindowStatus   = $root.Current.ItemStatus
            StartupMs      = $sync.StartupMs
            ShellReadyMs   = $sync.ShellReadyMs
            StartupTimings = $sync.StartupTimings
            Sections       = $sections
        }
    }

    AfterAll {
        if ($script:UiaHost) {
            $script:UiaHost.Sync.Stop = $true
            [void]$script:UiaHost.Handle.AsyncWaitHandle.WaitOne(30000)
            try {
                if ($script:UiaHost.Handle.IsCompleted) {
                    [void]$script:UiaHost.PowerShell.EndInvoke($script:UiaHost.Handle)
                    $script:UiaHost.PowerShell.Dispose()
                    $script:UiaHost.Runspace.Dispose()
                } else {
                    [void]$script:UiaHost.PowerShell.BeginStop($null, $null)
                }
            } catch { $null = $_ }
        }
    }

    It 'builds and renders the main window, and loads every section on navigation' {
        if ($script:UiaSkip) { Set-ItResult -Skipped -Because $script:UiaSkip; return }
        $script:UiaResult | Should -Not -BeOfType [string] -Because "$script:UiaResult"
        $script:UiaResult.FocusableCount | Should -BeGreaterThan 5
        $script:UiaResult.Problems | Should -BeNullOrEmpty
        @($script:UiaResult.Sections).Count | Should -Be @(& $script:Gui { $script:OmniNavPanels }).Count
    }

    It 'gives every keyboard-focusable element a UI Automation Name, in every section' {
        if ($script:UiaSkip) { Set-ItResult -Skipped -Because $script:UiaSkip; return }
        if ($script:UiaResult -is [string]) { throw $script:UiaResult }
        $script:UiaResult.Unnamed | Should -BeNullOrEmpty
        $script:UiaResult.ById['BtnScan'].Name | Should -Be 'Run scan'
        $script:UiaResult.ById['BtnHelp'].Name | Should -Be 'Keyboard shortcuts and help'
        # Controls of lazily loaded sections were reached (and named) too.
        $script:UiaResult.ById['TxtFindingFilter'].Name | Should -Be 'Filter findings'
        $script:UiaResult.ById['BtnRunRepairs'].Name | Should -Be 'Run selected repairs'
        $script:UiaResult.ById['BtnAiCheck'].Name | Should -Be 'Check Ollama'
    }

    It 'reaches every tab stop with Tab in every section, in top bar -> navigation -> content order' {
        if ($script:UiaSkip) { Set-ItResult -Skipped -Because $script:UiaSkip; return }
        if ($script:UiaResult -is [string]) { throw $script:UiaResult }
        $sections = @($script:UiaResult.Sections)
        if ($sections.Count -eq 0 -or $sections[0].Mode -ne 'MoveFocus') {
            Set-ItResult -Inconclusive -Because 'the window could not take keyboard focus on this desktop'
            return
        }
        foreach ($s in $sections) {
            if ($s.Mode -ne 'MoveFocus') { continue }
            @($s.Unreached) | Should -BeNullOrEmpty -Because "every tab stop in $($s.Panel) must be reachable with Tab"
            $v = @($s.Visited)
            $scan = [array]::FindIndex([string[]]$v, [Predicate[string]] { param($x) $x -like 'BtnScan*' })
            $nav = [array]::FindIndex([string[]]$v, [Predicate[string]] { param($x) $x -like 'NavList*' -or $x -like 'ListBoxItem*' })
            $scan | Should -BeGreaterOrEqual 0 -Because $s.Panel
            $nav | Should -BeGreaterThan $scan -Because $s.Panel
        }
    }

    It 'renders first paint and the ready shell within 2 s (soft gate) and exposes both measurements' {
        if ($script:UiaSkip) { Set-ItResult -Skipped -Because $script:UiaSkip; return }
        if ($script:UiaResult -is [string]) { throw $script:UiaResult }
        # Two numbers: first paint (the code-built frame) and fully interactive (the shell).
        $ms = [int]$script:UiaResult.StartupMs
        $ready = [int]$script:UiaResult.ShellReadyMs
        $ms | Should -BeGreaterThan 0
        $ready | Should -BeGreaterOrEqual $ms
        $script:UiaResult.WindowStatus | Should -Be "StartupMs=$ms;ShellReadyMs=$ready"
        # Phase breakdown (ms since the clock started, just before Initialize-OmniMainWindow).
        $phases = [string]$script:UiaResult.StartupTimings
        Write-Host "    GUI first paint: $ms ms; shell ready (interactive): $ready ms ($phases)"
        if ($ms -gt 2000) {
            Write-Warning "GUI first paint took $ms ms (target: under 2000 ms). Soft gate - not failing. Phases: $phases"
        }
        if ($ready -gt 2000) {
            Write-Warning "GUI shell took $ready ms to become ready (target: under 2000 ms). Soft gate - not failing. Phases: $phases"
        }
        $phases | Should -Match 'FramePainted=\d+ ms'
        $phases | Should -Match 'ShellReady=\d+ ms'
        $phases | Should -Match 'ShellParsed=\d+ ms'
        $phases | Should -Match 'XamlParsed=\d+ ms'
        $phases | Should -Match 'ContentRendered=\d+ ms'
    }
}
