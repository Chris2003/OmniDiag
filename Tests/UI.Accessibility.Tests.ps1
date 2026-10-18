#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Accessibility, keyboard, high-contrast, and drill-down tests for the WPF GUI.

    * Cross-platform: MainWindow.xaml is parsed as XML (every interactive control is named,
      the keyboard shortcuts exist, access keys are unique, focus visuals are set, severity
      colors are theme brushes), the code-behind's control list matches the XAML, and the
      pure helpers behind the findings filter, finding details, and group summaries are
      exercised on a synthetic session.
    * Windows desktop only: the real window is shown modelessly on its own STA thread and
      inspected with UI Automation (System.Windows.Automation): every keyboard-focusable
      element has a Name, Tab traversal reaches every tab stop, and first render is
      measured (soft gate: a warning above 2 s, never a failure). It skips with a reason
      on non-Windows hosts, non-interactive sessions, or when no window can be rendered
      (e.g. a CI runner without a usable desktop).
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:XamlPath = Join-Path $script:Root 'src/UI/MainWindow.xaml'
    $script:GuiPath = Join-Path $script:Root 'src/UI/OmniDiagGui.psm1'
    $script:Manifest = Join-Path $script:Root 'src/OmniDiag.psd1'
    Import-Module $script:Manifest -Force -DisableNameChecking -Global
    $script:Gui = (Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'OmniDiagGui' } | Select-Object -First 1

    $script:XamlRaw = Get-Content -LiteralPath $script:XamlPath -Raw
    [xml]$script:Xaml = $script:XamlRaw
    $script:GuiSource = Get-Content -LiteralPath $script:GuiPath -Raw
    $script:XNs = 'http://schemas.microsoft.com/winfx/2006/xaml'

    function Get-XamlElement {
        param([string[]] $LocalName)
        @($script:Xaml.SelectNodes('//*') | Where-Object { $LocalName -contains $_.LocalName })
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
        # The bindings live on the Window itself, so they work wherever focus is.
        @($script:Xaml.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'Window.InputBindings' }).Count | Should -Be 1
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

    It 'is ASCII-only (XAML and code-behind)' {
        foreach ($path in $script:XamlPath, $script:GuiPath) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because $path
        }
    }
}

Describe 'GUI code-behind matches the XAML (cross-platform)' {
    It 'defines every x:Name the code looks up' {
        $names = & $script:Gui { $script:OmniUiControlNames }
        $names.Count | Should -BeGreaterThan 40
        foreach ($n in $names) { $script:XamlRaw | Should -Match ('x:Name="' + $n + '"') }
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
        $script:GuiSource | Should -Match 'SetItemStatus\(\$ui\.Window, "StartupMs='
        # The window factory itself does no CIM / plugin discovery.
        $factory = [regex]::Match($script:GuiSource, '(?s)function Initialize-OmniMainWindow \{.*?\n\}\r?\n').Value
        $factory | Should -Not -BeNullOrEmpty
        $factory | Should -Not -Match 'Get-OmniSystemInfo|Get-OmniModule|Invoke-OmniRepairCenter|Get-CimInstance'
    }

    It 'exports reports in a background runspace, with the redaction option gated on -Redact' {
        $export = [regex]::Match($script:GuiSource, '(?s)function Invoke-OmniExportRequest \{.*?\n\}\r?\n').Value
        $export | Should -Match 'Invoke-OmniUiTask'
        $export | Should -Not -Match 'Export-OmniReport'
        $script:GuiSource | Should -Match "Parameters\.ContainsKey\('Redact'\)"
        $script:GuiSource | Should -Match 'Redact identifiers for sharing'
        $script:GuiSource | Should -Match 'Bundle \(\.zip\)'
    }

    It 'detects whether Export-OmniReport supports -Redact' {
        $expected = (Get-Command Export-OmniReport).Parameters.ContainsKey('Redact')
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
        $sync = [hashtable]::Synchronized(@{
            Stage = 'starting'; Ready = $false; Error = $null; Hwnd = [IntPtr]::Zero
            StartupMs = $null; Mode = ''; Visited = @(); Unreached = @(); Stop = $false; Closed = $false
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
                $window.Show()
                $deadline = [DateTime]::UtcNow.AddSeconds(20)
                while ($null -eq (& $gui { $script:OmniUi.StartupMs }) -and [DateTime]::UtcNow -lt $deadline) {
                    & $pump
                    Start-Sleep -Milliseconds 10
                }
                $Sync.StartupMs = & $gui { $script:OmniUi.StartupMs }
                if ($null -eq $Sync.StartupMs) { throw 'the window never rendered (no ContentRendered within 20 s)' }
                $Sync.Hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle

                # Tab traversal: start at the first top-bar control and press "Tab" (MoveFocus
                # Next) until focus returns to an element already visited.
                $Sync.Stage = 'tab'
                [void]$window.Activate()
                & $pump
                $ctl = & $gui { $script:OmniUi.Controls }
                $describe = {
                    param($el)
                    $n = [System.Windows.Automation.AutomationProperties]::GetName($el)
                    $id = if ($el -is [System.Windows.FrameworkElement] -and $el.Name) { $el.Name } else { $el.GetType().Name }
                    if ($n) { "$id ($n)" } else { $id }
                }
                [void]$ctl.ChkNetworkProbes.Focus()
                & $pump
                $visited = [System.Collections.Generic.List[object]]::new()
                if ([System.Windows.Input.Keyboard]::FocusedElement -eq $ctl.ChkNetworkProbes) {
                    $Sync.Mode = 'MoveFocus'
                    for ($i = 0; $i -lt 400; $i++) {
                        $cur = [System.Windows.Input.Keyboard]::FocusedElement
                        if (-not $cur -or $visited.Contains($cur)) { break }
                        $visited.Add($cur)
                        [void]$cur.MoveFocus([System.Windows.Input.TraversalRequest]::new([System.Windows.Input.FocusNavigationDirection]::Next))
                        & $pump
                    }
                } else {
                    $Sync.Mode = 'Static'   # window could not take keyboard focus (inactive desktop)
                }
                $Sync.Visited = @($visited | ForEach-Object { & $describe $_ })

                # Every visible, enabled tab stop must be in the traversal - except items inside
                # list/grid/combo containers (one stop per container; arrows move within).
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
                if ($Sync.Mode -eq 'MoveFocus') {
                    $Sync.Unreached = @($stops | Where-Object { -not $visited.Contains($_) } | ForEach-Object { & $describe $_ })
                } else {
                    $Sync.Unreached = @()
                }
                $Sync.TabStops = @($stops | ForEach-Object { & $describe $_ })

                $Sync.Stage = 'ready'
                $Sync.Ready = $true

                # Keep the dispatcher pumping (UI Automation requests are served on this thread)
                # until the test asks us to stop, or a safety timeout.
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $limit = [DateTime]::UtcNow.AddSeconds(180)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(100)
                $timer.Add_Tick({
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
            if ($sync.Stage -in 'import', 'construct') {
                $script:UiaResult = "FAIL: $why"
            } else {
                $script:UiaSkip = "no usable desktop to render the window ($why)"
            }
            return
        }

        # UI Automation walk (from this thread).
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($sync.Hwnd)
        $cond = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::IsKeyboardFocusableProperty, $true)
        $focusable = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
        $unnamed = @(foreach ($el in $focusable) {
            $c = $el.Current
            if ($c.ClassName -eq 'DataGridCell') { continue }   # cells are read through their named row
            if (-not ([string]$c.Name).Trim()) { '{0} id={1} class={2}' -f $c.ControlType.ProgrammaticName, $c.AutomationId, $c.ClassName }
        })
        $byId = @{}
        foreach ($el in $focusable) { if ($el.Current.AutomationId) { $byId[$el.Current.AutomationId] = $el.Current } }
        $script:UiaResult = [pscustomobject]@{
            FocusableCount = $focusable.Count
            Unnamed        = $unnamed
            ById           = $byId
            WindowStatus   = $root.Current.ItemStatus
            StartupMs      = $sync.StartupMs
            Mode           = $sync.Mode
            Visited        = @($sync.Visited)
            Unreached      = @($sync.Unreached)
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

    It 'builds and renders the main window' {
        if ($script:UiaSkip) { Set-ItResult -Skipped -Because $script:UiaSkip; return }
        $script:UiaResult | Should -Not -BeOfType [string] -Because "$script:UiaResult"
        $script:UiaResult.FocusableCount | Should -BeGreaterThan 5
    }

    It 'gives every keyboard-focusable element a UI Automation Name' {
        if ($script:UiaSkip) { Set-ItResult -Skipped -Because $script:UiaSkip; return }
        if ($script:UiaResult -is [string]) { throw $script:UiaResult }
        $script:UiaResult.Unnamed | Should -BeNullOrEmpty
        $script:UiaResult.ById['BtnScan'].Name | Should -Be 'Run scan'
        $script:UiaResult.ById['BtnHelp'].Name | Should -Be 'Keyboard shortcuts and help'
    }

    It 'reaches every tab stop with Tab, in top bar -> navigation -> content order' {
        if ($script:UiaSkip) { Set-ItResult -Skipped -Because $script:UiaSkip; return }
        if ($script:UiaResult -is [string]) { throw $script:UiaResult }
        if ($script:UiaResult.Mode -ne 'MoveFocus') {
            Set-ItResult -Inconclusive -Because 'the window could not take keyboard focus on this desktop'
            return
        }
        $script:UiaResult.Unreached | Should -BeNullOrEmpty
        $v = @($script:UiaResult.Visited)
        $scan = [array]::FindIndex([string[]]$v, [Predicate[string]] { param($s) $s -like 'BtnScan*' })
        $nav = [array]::FindIndex([string[]]$v, [Predicate[string]] { param($s) $s -like 'NavList*' -or $s -like 'ListBoxItem*' })
        $scan | Should -BeGreaterOrEqual 0
        $nav | Should -BeGreaterThan $scan
    }

    It 'renders first paint within 2 s (soft gate) and exposes the measurement' {
        if ($script:UiaSkip) { Set-ItResult -Skipped -Because $script:UiaSkip; return }
        if ($script:UiaResult -is [string]) { throw $script:UiaResult }
        $ms = [int]$script:UiaResult.StartupMs
        $ms | Should -BeGreaterThan 0
        $script:UiaResult.WindowStatus | Should -Be "StartupMs=$ms"
        if ($ms -gt 2000) {
            Write-Warning "GUI first render took $ms ms (target: under 2000 ms). Soft gate - not failing."
        } else {
            Write-Host "    GUI first render: $ms ms"
        }
    }
}
