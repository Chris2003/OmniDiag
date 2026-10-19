<#
.SYNOPSIS
    OmniDiag WPF GUI (runtime-loaded XAML).

.DESCRIPTION
    Presents the dashboard, per-group drill-down, and findings in a Fluent-style window
    with dark, light, and high-contrast themes. Scans, repairs, exports, Local AI calls,
    and the deferred startup work (System Information inventory, repair and scanner
    catalogs) all run in BACKGROUND RUNSPACES so the UI thread stays responsive.
    Progress is surfaced through thread-safe synchronized hashtables that
    DispatcherTimers poll on the UI thread. Cancellation uses the same
    CancellationToken the engine has honored since Milestone 1.

    Runspace-affine objects (registrations with PSModuleInfo, scriptblocks) never cross
    runspaces: background work returns plain values (strings, numbers, hashtables, and
    the scan session), and scriptblocks are passed as text and re-created on the far
    side.

    WPF requires an STA thread. Windows PowerShell 5.1 consoles are STA; PowerShell 7
    is MTA, so Start-OmniGuiWindow hosts the window in a dedicated STA runspace when
    needed. No display is created until the window is shown, so importing this module
    is safe on headless/Server Core hosts.

    XAML is split for startup time: MainWindow.xaml is a small shell (window chrome,
    top bar, navigation, the Dashboard, status bar). Every other section is a fragment
    in Sections\*.xaml, parsed on first navigation into its host (Import-OmniSection),
    cached, and wired by its own init (Initialize-OmniSection). Controls of a section
    that has not loaded yet are $null in $ui.Controls; code that touches them checks
    Test-OmniSectionLoaded first.

    Background runspaces call the curated cmdlets (Invoke-OmniDiagScan -AsSession,
    Export-OmniDiagReport, Get-OmniDiagRepair) or, where a curated cmdlet lacks what the
    GUI needs (repair progress callback, dry run without -WhatIf), the internal engine
    entry Invoke-OmniRepairRun - never the deprecated pre-1.0 names.

    Threading model:
        UI thread  -- BtnScan --> spawn background runspace (Invoke-OmniDiagScan)
                   <-- DispatcherTimer polls $sync (Progress/Phase/Done) --
        Cancel     -- $cts.Cancel()  (engine checks the token between modules)
        Startup    -- ContentRendered --> Dispatcher.BeginInvoke(Background)
                      --> logger, help tooltip, group names, Module Results grid
                   -- then Dispatcher.BeginInvoke(ApplicationIdle)
                      --> one background task (system info, repair + scanner catalogs)

    Accessibility: every interactive control has an AutomationProperties.Name; status
    text and the progress bar are polite live regions; keyboard shortcuts are window
    KeyBindings (see $script:OmniShortcutHelp and docs/GUI.md); high contrast swaps the
    palette for SystemColors brushes and follows SystemParameters.HighContrast.
#>

Set-StrictMode -Version Latest

$script:OmniUiRoot = $PSScriptRoot
$script:OmniUi = $null
$script:OmniStartupClock = $null
# Startup phase checkpoints (phase -> ms on the startup clock), see Add-OmniStartupMark.
$script:OmniStartupMarks = $null
# MainWindow.xaml (shell) text, read once per module instance (or handed in by the MTA host).
$script:OmniXamlText = $null
# Section fragment texts (Sections\<file> -> text), read on first use.
$script:OmniSectionXamlText = $null

# Every x:Name in the shell (MainWindow.xaml) that the code looks up with FindName.
$script:OmniShellControlNames = @(
    'BtnScan', 'BtnCancel', 'BtnExport', 'BtnTheme', 'BtnHelp', 'CmbRange', 'ChkNetworkProbes', 'NavList',
    'PanelDashboard', 'PanelSysInfo', 'TxtScore', 'TxtGrade', 'TxtComputer', 'TxtUser', 'TxtRange',
    'TxtDuration', 'TxtCounts', 'ItemsRecommendations', 'PanelDashboardModules',
    'PanelGroups', 'PanelFindings', 'PanelDiagnostics', 'PanelRepair', 'PanelLocalAi',
    'ProgressBarMain', 'TxtStatus'
)

# Lazily loaded sections: fragment file (under Sections\), the shell element that hosts it
# (a Border; the fragment becomes its Child), and the x:Names looked up in the fragment.
$script:OmniSections = [ordered]@{
    DashboardModules = @{ File = 'DashboardModules.xaml'; Host = 'PanelDashboardModules'; Controls = @('GridModules') }
    Groups           = @{ File = 'Groups.xaml'; Host = 'PanelGroups'; Controls = @(
            'GroupListView', 'GroupDetailView', 'GridGroups', 'BtnGroupOpen', 'TxtGroupsHint',
            'BtnGroupBack', 'TxtGroupTitle', 'TxtGroupSummary', 'GridGroupModules', 'GridGroupFindings', 'TxtGroupFindingDetail') }
    Findings         = @{ File = 'Findings.xaml'; Host = 'PanelFindings'; Controls = @(
            'GridFindings', 'TxtFindingFilter', 'CmbSeverityFilter', 'TxtFindingCount', 'TxtFindingDetail') }
    Diagnostics      = @{ File = 'Diagnostics.xaml'; Host = 'PanelDiagnostics'; Controls = @(
            'DiagGrid', 'BtnDiagEnableAll', 'BtnDiagDisableAll', 'BtnDiagRunSelected') }
    Repair           = @{ File = 'Repair.xaml'; Host = 'PanelRepair'; Controls = @(
            'RepairGrid', 'RepairResultGrid', 'BtnRunRepairs', 'BtnRepairCancel',
            'BtnRepairRecommended', 'BtnRepairClear', 'ChkRepairDryRun', 'TxtRepairBanner', 'TxtRepairAdminNote') }
    LocalAi          = @{ File = 'LocalAi.xaml'; Host = 'PanelLocalAi'; Controls = @(
            'CmbAiModel', 'TxtAiEndpoint', 'BtnAiCheck', 'TxtAiQuestion', 'BtnAiAnalyze', 'TxtAiStatus', 'TxtAiOutput') }
}

# Shared section-only styles (data grids, row styles, detail boxes), merged into the
# window's resources before the first section loads.
$script:OmniSectionStyleFile = 'SectionStyles.xaml'

# Every x:Name the code looks up (shell + all sections). Tests check each exists in the
# shell or a fragment, and that the code never reaches for a control outside this list.
$script:OmniUiControlNames = @($script:OmniShellControlNames + @($script:OmniSections.Values | ForEach-Object { $_.Controls }))

# Content panels in navigation order (NavList item i shows panel i; Ctrl+<i+1> jumps there).
$script:OmniNavPanels = @('PanelDashboard', 'PanelGroups', 'PanelFindings', 'PanelDiagnostics', 'PanelRepair', 'PanelLocalAi')

# Controls made polite UIA live regions (screen readers announce changes): at startup for
# the shell, when their section loads for the others (TxtFindingCount: All Findings).
$script:OmniLiveRegionControls = @('TxtStatus', 'ProgressBarMain', 'TxtFindingCount')

# Keyboard reference shown by F1 / the Help button and documented in docs/GUI.md.
# Parameter is the KeyBinding CommandParameter in MainWindow.xaml ('' = built-in behavior).
$script:OmniShortcutHelp = @(
    [pscustomobject]@{ Keys = 'F5';                   Parameter = 'Scan';   Action = 'Run a scan' }
    [pscustomobject]@{ Keys = 'Esc';                  Parameter = 'Cancel'; Action = 'Cancel the running scan or repair (or leave a group)' }
    [pscustomobject]@{ Keys = 'Ctrl+E';               Parameter = 'Export'; Action = 'Export reports for the latest scan' }
    [pscustomobject]@{ Keys = 'Ctrl+F';               Parameter = 'Find';   Action = 'Filter findings (opens All Findings)' }
    [pscustomobject]@{ Keys = 'Alt+T';                Parameter = 'Theme';  Action = 'Toggle dark / light theme' }
    [pscustomobject]@{ Keys = 'F1';                   Parameter = 'Help';   Action = 'Show this keyboard help' }
    [pscustomobject]@{ Keys = 'Ctrl+1 ... Ctrl+6';    Parameter = 'Nav1';   Action = 'Dashboard, Groups, All Findings, Diagnostics, Repair Center, Local AI' }
    [pscustomobject]@{ Keys = 'Up / Down';            Parameter = '';       Action = 'Move between sections in the navigation list' }
    [pscustomobject]@{ Keys = 'Enter';                Parameter = '';       Action = 'On a finding: read its details. On a group: open it' }
    [pscustomobject]@{ Keys = 'Alt+Left / Backspace'; Parameter = '';       Action = 'Back from a group to the group list' }
    [pscustomobject]@{ Keys = 'Alt+underlined letter'; Parameter = '';      Action = 'Press that button or focus that field (e.g. Alt+S scan)' }
    [pscustomobject]@{ Keys = 'Tab / Shift+Tab';      Parameter = '';       Action = 'Move between controls; arrow keys move inside lists and grids' }
    [pscustomobject]@{ Keys = 'Space';                Parameter = '';       Action = 'Toggle the checkbox in the focused grid cell' }
)

$script:OmniSeverityOrder = @('Critical', 'Error', 'Warning', 'Information', 'Pass')

# ---------------------------------------------------------------------------
# Startup: phase timings, accessibility switches, XAML text
# ---------------------------------------------------------------------------

function Add-OmniStartupMark {
    <#
    .SYNOPSIS
        Internal: record a startup checkpoint - milliseconds on the startup clock (from
        Start-OmniGuiWindow entry) at which a phase finished. The first mark per phase wins.

    .DESCRIPTION
        Phases, in order: Entry, StaRunspaceReady, WpfPreloaded (MTA host only: loaded on
        the calling thread while the STA runspace imports OmniDiag), ModuleImported,
        InitializeStart, WpfAssembliesLoaded, XamlEngineReady, ShellParsed, XamlParsed, WindowConstructed,
        ShowCalled, ContentRendered; then one Section<Name>Loaded per lazily loaded
        section (the clock keeps running after first render). Thread-safe: the MTA host
        marks from two threads.
    #>
    param([Parameter(Mandatory)] [string] $Name, [System.Diagnostics.Stopwatch] $Clock = $script:OmniStartupClock)
    if (-not $Clock) { return }
    if ($null -eq $script:OmniStartupMarks) { $script:OmniStartupMarks = [System.Collections.Specialized.OrderedDictionary]::new() }
    $marks = $script:OmniStartupMarks
    [System.Threading.Monitor]::Enter($marks)
    try {
        if (-not $marks.Contains($Name)) { $marks.Add($Name, [int]$Clock.Elapsed.TotalMilliseconds) }
    } finally {
        [System.Threading.Monitor]::Exit($marks)
    }
}

function Format-OmniStartupTiming {
    <# .SYNOPSIS Internal: the startup checkpoints as one line ("Entry=0 ms, ..., ContentRendered=1234 ms"), or ''. #>
    [OutputType([string])]
    param($Marks = $script:OmniStartupMarks)
    if ($null -eq $Marks -or $Marks.Count -eq 0) { return '' }
    $parts = foreach ($k in @($Marks.Keys)) { '{0}={1} ms' -f $k, $Marks[$k] }
    return ($parts -join ', ')
}

function Disable-OmniLegacyAccessibility {
    <#
    .SYNOPSIS
        Internal: turn off WPF's legacy accessibility behavior on .NET Framework.

    .DESCRIPTION
        powershell.exe (Windows PowerShell 5.1) does not target .NET Framework 4.7.1+, so
        WPF keeps the legacy accessibility switches on and UIA live regions (LiveSetting,
        LiveRegionChanged) do nothing. Clearing the three switches before WPF reads them
        (on first use) enables them. No effect on .NET (PowerShell 7), where they are off.
    #>
    if ($PSVersionTable.PSEdition -ne 'Desktop') { return }
    foreach ($name in @('Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2', 'Switch.UseLegacyAccessibilityFeatures.3')) {
        try { [System.AppContext]::SetSwitch($name, $false) } catch { $null = $_ }
    }
}

function Get-OmniMainWindowXaml {
    <# .SYNOPSIS Internal: the MainWindow.xaml text (read once, then cached). #>
    [OutputType([string])]
    param()
    if (-not $script:OmniXamlText) {
        $script:OmniXamlText = [System.IO.File]::ReadAllText((Join-Path $script:OmniUiRoot 'MainWindow.xaml'), [System.Text.Encoding]::UTF8)
    }
    return $script:OmniXamlText
}

function Get-OmniSectionXaml {
    <# .SYNOPSIS Internal: a section fragment's text (Sections folder; read once, then cached). #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $File)
    if ($null -eq $script:OmniSectionXamlText) { $script:OmniSectionXamlText = @{} }
    if (-not $script:OmniSectionXamlText.ContainsKey($File)) {
        $path = Join-Path (Join-Path $script:OmniUiRoot 'Sections') $File
        $script:OmniSectionXamlText[$File] = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    }
    return $script:OmniSectionXamlText[$File]
}

function Test-OmniSectionLoaded {
    <# .SYNOPSIS Internal: has this lazily loaded section been parsed and wired? #>
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Name)
    $ui = $script:OmniUi
    if ($null -eq $ui -or $null -eq $ui.Sections) { return $false }
    return [bool]$ui.Sections.ContainsKey($Name)
}

function Get-OmniSectionForHost {
    <# .SYNOPSIS Internal: the section name hosted by a shell element (e.g. PanelGroups -> Groups), or $null. #>
    [OutputType([string])]
    param([string] $HostName)
    foreach ($key in $script:OmniSections.Keys) {
        if ($script:OmniSections[$key].Host -eq $HostName) { return [string]$key }
    }
    return $null
}

function Use-OmniSectionStyle {
    <# .SYNOPSIS Internal: merge Sections\SectionStyles.xaml into the window resources (once). #>
    $ui = $script:OmniUi
    if ($ui.SectionStylesLoaded) { return }
    $dict = [System.Windows.Markup.XamlReader]::Parse((Get-OmniSectionXaml -File $script:OmniSectionStyleFile))
    [void]$ui.Window.Resources.MergedDictionaries.Add($dict)
    $ui.SectionStylesLoaded = $true
}

function Import-OmniSection {
    <#
    .SYNOPSIS
        Internal: load a lazily loaded section (parse its fragment, look up its controls,
        insert it into its host, wire it) once; later calls return the cached root.

    .DESCRIPTION
        UI thread only. Element lookups happen on the fragment's own name scope (each
        XamlReader.Parse root has one), so $ui.Controls gets the section's controls only
        after this runs. Records a Section<Name>Loaded startup mark and logs the load time.
    #>
    param([Parameter(Mandatory)] [string] $Name)
    $ui = $script:OmniUi
    if (-not $ui) { return $null }
    if ($ui.Sections.ContainsKey($Name)) { return $ui.Sections[$Name] }
    $def = $script:OmniSections[$Name]
    if (-not $def) { throw [System.ArgumentException]::new("Unknown GUI section '$Name'.") }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Use-OmniSectionStyle
    $root = [System.Windows.Markup.XamlReader]::Parse((Get-OmniSectionXaml -File $def.File))
    foreach ($n in $def.Controls) { $ui.Controls[$n] = $root.FindName($n) }
    # Cache before wiring: the init may raise events that ask whether the section is loaded.
    $ui.Sections[$Name] = $root
    $ui.Controls[$def.Host].Child = $root
    foreach ($n in $script:OmniLiveRegionControls) {
        if ($def.Controls -contains $n -and $ui.Controls[$n]) { [void](Enable-OmniLiveRegion -Element $ui.Controls[$n]) }
    }
    Initialize-OmniSection -Name $Name
    Sync-OmniBusyState
    $sw.Stop()
    $ms = [int]$sw.Elapsed.TotalMilliseconds
    $ui.SectionLoadMs[$Name] = $ms
    Add-OmniStartupMark -Name "Section${Name}Loaded" -Clock $ui.StartupClock
    if ($ui.Logger) {
        try { $ui.Logger.Log('Info', "GUI section $Name loaded in $ms ms.", 'Gui', @{ Section = $Name; LoadMs = $ms }) } catch { $null = $_ }
    }
    return $root
}

# ---------------------------------------------------------------------------
# Themes
# ---------------------------------------------------------------------------

function Get-OmniThemePalette {
    <#
    .SYNOPSIS
        Returns the brush palette (resource key -> #RRGGBB) for the Dark or Light theme.

    .DESCRIPTION
        Both palettes define the same keys. High contrast does not use a palette: it maps
        every key to a SystemColors brush (see Set-OmniTheme -Name HighContrast).

    .PARAMETER Name
        Dark or Light (default).
    #>
    [OutputType([hashtable])]
    param([ValidateSet('Dark', 'Light')] [string] $Name = 'Light')
    if ($Name -eq 'Light') {
        return @{
            BrushWindowBg = '#F5F7FA'; BrushPanel = '#FFFFFF'; BrushPanel2 = '#EEF1F5'
            BrushText = '#1A1F24'; BrushMuted = '#5A6472'; BrushAccent = '#0969DA'; BrushAccentText = '#FFFFFF'
            BrushLine = '#D5DBE2'; BrushFocus = '#1A1F24'; BrushHover = '#0969DA'; BrushDisabled = '#8C959F'
            BrushSevCritical = '#C4282D'; BrushSevError = '#B35A00'; BrushSevWarning = '#8A5A00'; BrushSevPass = '#1A7F37'
        }
    }
    return @{
        BrushWindowBg = '#0F1419'; BrushPanel = '#1A212B'; BrushPanel2 = '#212A36'
        BrushText = '#E6EDF3'; BrushMuted = '#8B98A5'; BrushAccent = '#4493F8'; BrushAccentText = '#0F1419'
        BrushLine = '#2D3742'; BrushFocus = '#E6EDF3'; BrushHover = '#4493F8'; BrushDisabled = '#6E7781'
        BrushSevCritical = '#FF7B72'; BrushSevError = '#FFA657'; BrushSevWarning = '#E3B341'; BrushSevPass = '#56D364'
    }
}

function Get-OmniHighContrastBrushMap {
    <#
    .SYNOPSIS
        Internal: palette key -> System.Windows.SystemColors brush property, for high contrast.

    .DESCRIPTION
        Severity and risk brushes all map to WindowText: in high contrast, color carries no
        meaning (severity is always also shown as text).
    #>
    [OutputType([hashtable])]
    param()
    return @{
        BrushWindowBg    = 'WindowBrush'
        BrushPanel       = 'WindowBrush'
        BrushPanel2      = 'ControlBrush'
        BrushText        = 'WindowTextBrush'
        BrushMuted       = 'WindowTextBrush'
        BrushAccent      = 'HighlightBrush'
        BrushAccentText  = 'HighlightTextBrush'
        BrushLine        = 'WindowTextBrush'
        BrushFocus       = 'HighlightBrush'
        BrushHover       = 'HotTrackBrush'
        BrushDisabled    = 'GrayTextBrush'
        BrushSevCritical = 'WindowTextBrush'
        BrushSevError    = 'WindowTextBrush'
        BrushSevWarning  = 'WindowTextBrush'
        BrushSevPass     = 'WindowTextBrush'
    }
}

function Set-OmniTheme {
    <#
    .SYNOPSIS
        Applies a theme to an OmniDiag window by replacing its brush resources.

    .PARAMETER Window
        The WPF window (its Resources receive the brushes).

    .PARAMETER Name
        Dark, Light (default), or HighContrast (SystemColors brushes; used automatically
        while Windows high contrast is on).
    #>
    param([Parameter(Mandatory)] $Window, [ValidateSet('Dark', 'Light', 'HighContrast')] [string] $Name = 'Light')
    if ($Name -eq 'HighContrast') {
        $map = Get-OmniHighContrastBrushMap
        foreach ($key in $map.Keys) {
            $Window.Resources[$key] = [System.Windows.SystemColors]::($map[$key])
        }
        return
    }
    $palette = Get-OmniThemePalette -Name $Name
    foreach ($key in $palette.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
        $Window.Resources[$key] = [System.Windows.Media.SolidColorBrush]::new($color)
    }
}

function Get-OmniGradeColor {
    # Mid-saturation values chosen to stay legible on both the light (default) and
    # dark panel backgrounds. Not used in high contrast.
    param([string] $Grade)
    switch ($Grade) {
        'Healthy'  { '#2DA44E' }
        'Warning'  { '#B7791F' }
        'Critical' { '#E5484D' }
        default    { '#8B98A5' }
    }
}

function Get-OmniThemeButtonLabel {
    <# .SYNOPSIS Internal: label for the theme toggle - names the theme it switches TO. #>
    param([ValidateSet('Dark', 'Light')] [string] $Current)
    if ($Current -eq 'Dark') { 'Light Mode' } else { 'Dark Mode' }
}

function Test-OmniHighContrast {
    <# .SYNOPSIS Internal: is Windows high contrast on? ($false when WPF is unavailable.) #>
    [OutputType([bool])]
    param()
    try { return [bool][System.Windows.SystemParameters]::HighContrast } catch { return $false }
}

function Write-OmniScoreColor {
    <# .SYNOPSIS Internal: color the score by grade (theme brush in high contrast or before a scan). #>
    $ui = $script:OmniUi
    $tb = $ui.Controls.TxtScore
    if ($ui.HighContrast -or -not $ui.ScoreGrade) {
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'BrushText')
    } else {
        $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString((Get-OmniGradeColor $ui.ScoreGrade)))
    }
}

function Sync-OmniEffectiveTheme {
    <#
    .SYNOPSIS
        Internal: apply the user's theme, or the high-contrast theme while Windows high
        contrast is on (the dark/light toggle is disabled then).

    .DESCRIPTION
        The brushes always go on the window, so the code-built frame (shown before the
        shell XAML loads) already has the right background, including high contrast.
        The theme button and the score color are updated once the shell is in place.
    #>
    $ui = $script:OmniUi
    if (-not $ui) { return }
    $ui.HighContrast = Test-OmniHighContrast
    if ($ui.HighContrast) { Set-OmniTheme -Window $ui.Window -Name HighContrast } else { Set-OmniTheme -Window $ui.Window -Name $ui.Theme }
    if (-not $ui.ShellReady) { return }
    $btn = $ui.Controls.BtnTheme
    $btn.Content = Get-OmniThemeButtonLabel -Current $ui.Theme
    $target = if ($ui.Theme -eq 'Dark') { 'light' } else { 'dark' }
    if ($ui.HighContrast) {
        $btn.IsEnabled = $false
        $btn.ToolTip = 'High contrast is on, so OmniDiag uses your Windows high-contrast colors. Turn high contrast off to choose dark or light.'
        [System.Windows.Automation.AutomationProperties]::SetName($btn, "Switch to $target theme (unavailable in high contrast)")
    } else {
        $btn.IsEnabled = $true
        $btn.ToolTip = 'Toggle dark or light theme (Alt+T)'
        [System.Windows.Automation.AutomationProperties]::SetName($btn, "Switch to $target theme")
    }
    Write-OmniScoreColor
}

function Invoke-OmniThemeToggle {
    <# .SYNOPSIS Internal: Alt+T / theme button - flip dark and light (no-op in high contrast). #>
    $ui = $script:OmniUi
    if (-not $ui.ShellReady) { return }
    if ($ui.HighContrast) {
        Write-OmniStatus -Text 'High contrast is on: OmniDiag follows your Windows high-contrast colors.' -Announce
        return
    }
    $ui.Theme = if ($ui.Theme -eq 'Dark') { 'Light' } else { 'Dark' }
    Sync-OmniEffectiveTheme
    Write-OmniStatus -Text "$($ui.Theme) theme on." -Announce
}

# ---------------------------------------------------------------------------
# Status, live regions, busy state
# ---------------------------------------------------------------------------

function Enable-OmniLiveRegion {
    <#
    .SYNOPSIS
        Internal: mark an element as a polite UIA live region.

    .DESCRIPTION
        AutomationProperties.LiveSetting exists from .NET Framework 4.7.1 (and .NET Core 3).
        It is set here by reflection rather than in XAML so the window still loads on older
        frameworks (where screen readers simply are not notified). Returns $true when set.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Element)
    try {
        $field = [System.Windows.Automation.AutomationProperties].GetField('LiveSettingProperty')
        if (-not $field) { return $false }
        $dp = $field.GetValue($null)
        $Element.SetValue($dp, [Enum]::Parse($dp.PropertyType, 'Polite'))
        return $true
    } catch {
        return $false
    }
}

function Invoke-OmniLiveRegion {
    <# .SYNOPSIS Internal: tell screen readers a live region changed (WPF does not do this itself). #>
    param([Parameter(Mandatory)] $Element)
    try {
        # Before the window is shown no screen reader can hear the event; creating an
        # automation peer then only costs startup time.
        if ($Element -is [System.Windows.FrameworkElement] -and -not $Element.IsLoaded) { return }
        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::FromElement($Element)
        if (-not $peer) { $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($Element) }
        if ($peer) {
            $evt = [Enum]::Parse([System.Windows.Automation.Peers.AutomationEvents], 'LiveRegionChanged')
            $peer.RaiseAutomationEvent($evt)
        }
    } catch {
        $null = $_   # pre-4.7.1 frameworks have no LiveRegionChanged event
    }
}

function Write-OmniStatus {
    <#
    .SYNOPSIS
        Internal: set the status bar text and (throttled) announce it to screen readers.

    .PARAMETER Announce
        Always announce (completion, errors). Otherwise announcements are limited to one
        every 3 s so a scan's per-module updates don't flood Narrator.
    #>
    param([AllowEmptyString()] [string] $Text, [switch] $Announce)
    $ui = $script:OmniUi
    if (-not $ui) { return }
    $tb = $ui.Controls.TxtStatus
    if (-not $tb -or $tb.Text -eq $Text) { return }
    $tb.Text = $Text
    $now = [DateTime]::UtcNow
    if ($Announce -or ($now - $ui.LastAnnounce).TotalMilliseconds -ge 3000) {
        $ui.LastAnnounce = $now
        Invoke-OmniLiveRegion -Element $tb
    }
}

function Test-OmniUiBusy {
    <# .SYNOPSIS Internal: is a scan, repair, Local AI call, or export running? #>
    [OutputType([bool])]
    param()
    $ui = $script:OmniUi
    return [bool]($ui.Scan -or $ui.Repair -or $ui.AiJob -or $ui.Export)
}

function Sync-OmniBusyState {
    <# .SYNOPSIS Internal: enable/disable actions from the current busy state (one place). #>
    $ui = $script:OmniUi
    if (-not $ui.ShellReady) { return }   # nothing to enable before the shell is in place
    $c = $ui.Controls
    $scan = [bool]$ui.Scan
    $repair = [bool]$ui.Repair
    $busy = Test-OmniUiBusy
    $hasSession = [bool]$ui.Session
    $c.BtnScan.IsEnabled = -not $busy
    $c.BtnCancel.IsEnabled = $scan -and -not $ui.Scan['Cancelling']
    $c.BtnExport.IsEnabled = $hasSession -and -not $busy
    # Section controls exist only once their section has loaded (Import-OmniSection
    # calls this again after loading one).
    if (Test-OmniSectionLoaded -Name 'Repair') {
        $c.BtnRunRepairs.IsEnabled = -not $busy
        $c.BtnRepairCancel.IsEnabled = $repair -and -not $ui.Repair['Cancelling']
    }
    if (Test-OmniSectionLoaded -Name 'LocalAi') {
        $c.BtnAiCheck.IsEnabled = -not $busy
        $c.BtnAiAnalyze.IsEnabled = $hasSession -and -not $busy
    }
    if (Test-OmniSectionLoaded -Name 'Diagnostics') {
        $c.BtnDiagRunSelected.IsEnabled = -not $busy
        $c.DiagGrid.IsEnabled = -not $scan
    }
}

# ---------------------------------------------------------------------------
# Background tasks (generic): run a script off the UI thread, poll for completion
# ---------------------------------------------------------------------------

function Invoke-OmniUiTask {
    <#
    .SYNOPSIS
        Internal: run a script in a background STA runspace with OmniDiag imported.

    .DESCRIPTION
        The script is passed as TEXT and re-created in the worker runspace (scriptblocks
        are runspace-affine). It is invoked as: & $script $SyncHash $Arguments, and its
        output becomes $SyncHash.Result. It may also write extra keys into $SyncHash for
        partial results. The shared task timer calls OnProgress (each tick) and OnComplete
        (once, after the runspace is disposed) on the UI thread as: & $block $Sync $Context.

    .OUTPUTS
        The task record (hashtable).
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Script,
        [hashtable] $Arguments = @{},
        [hashtable] $Context = @{},
        [scriptblock] $OnProgress,
        [scriptblock] $OnComplete
    )
    $ui = $script:OmniUi
    $sync = [hashtable]::Synchronized(@{ Done = $false; Result = $null; Error = $null })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $wrapper = {
        param($SyncHash, $Manifest, $TaskScript, $TaskArgs)
        try {
            Import-Module $Manifest -Force -DisableNameChecking
            $sb = [scriptblock]::Create($TaskScript)
            $SyncHash.Result = & $sb $SyncHash $TaskArgs
        } catch {
            $SyncHash.Error = $_.Exception.Message
        } finally {
            $SyncHash.Done = $true
        }
    }
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($wrapper).AddParameters(@{
        SyncHash = $sync; Manifest = $ui.Manifest; TaskScript = $Script.ToString(); TaskArgs = $Arguments
    })
    $handle = $ps.BeginInvoke()

    $task = @{
        Name = $Name; Sync = $sync; PowerShell = $ps; Runspace = $rs; Handle = $handle
        Context = $Context; OnProgress = $OnProgress; OnComplete = $OnComplete
    }
    [void]$ui.Tasks.Add($task)
    if (-not $ui.TaskTimer.IsEnabled) { $ui.TaskTimer.Start() }
    return $task
}

function Invoke-OmniUiTaskPoll {
    <# .SYNOPSIS Internal: task timer tick - report progress and finish completed tasks. #>
    $ui = $script:OmniUi
    if (-not $ui) { return }
    foreach ($task in @($ui.Tasks)) {
        if ($task.OnProgress) {
            try { & $task.OnProgress $task.Sync $task.Context } catch { Write-OmniStatus -Text "$($task.Name): $($_.Exception.Message)" }
        }
        if (-not $task.Sync.Done) { continue }
        # Remove first: OnComplete may show a modal dialog, during which this timer ticks again.
        [void]$ui.Tasks.Remove($task)
        try { [void]$task.PowerShell.EndInvoke($task.Handle) } catch { $null = $_ }
        try { $task.PowerShell.Dispose(); $task.Runspace.Dispose() } catch { $null = $_ }
        if ($task.OnComplete) {
            try { & $task.OnComplete $task.Sync $task.Context } catch { Write-OmniStatus -Text "$($task.Name) failed: $($_.Exception.Message)" -Announce }
        }
    }
    if ($ui.Tasks.Count -eq 0) { $ui.TaskTimer.Stop() }
}

# ---------------------------------------------------------------------------
# Pure helpers (no WPF): finding rows, filters, details, group summaries
# ---------------------------------------------------------------------------

function Get-OmniUiValue {
    <# .SYNOPSIS Internal: strict-mode-safe property/key read with a default. #>
    param($InputObject, [Parameter(Mandatory)] [string] $Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Get-OmniResultGroupId {
    <# .SYNOPSIS Internal: the v1.0 group id of a module result (stamped by the engine, else derived). #>
    [OutputType([string])]
    param($Result)
    $g = [string](Get-OmniUiValue $Result 'Group' '')
    if ($g) { return $g }
    try {
        return [string](Resolve-OmniModuleIdentity -Name ([string](Get-OmniUiValue $Result 'ModuleName' ''))).Group
    } catch {
        return 'extras'
    }
}

function ConvertTo-OmniGuiFindingRow {
    <#
    .SYNOPSIS
        Internal: flatten a session's findings into grid rows (most severe first).

    .DESCRIPTION
        Each row carries the finding text fields, its module and group, the raw evidence
        (Data), an A11yName for screen readers ("Critical: <title> (<module>)"), and a
        lower-case SearchText used by the findings filter.
    #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)] $Session, [hashtable] $GroupNames = @{})
    $rows = foreach ($r in @(Get-OmniUiValue $Session 'Results' @())) {
        if ($null -eq $r) { continue }
        $gid = Get-OmniResultGroupId $r
        $gname = if ($GroupNames.ContainsKey($gid)) { [string]$GroupNames[$gid] } else { $gid }
        $module = [string](Get-OmniUiValue $r 'ModuleName' '')
        foreach ($f in @(Get-OmniUiValue $r 'Findings' @())) {
            if ($null -eq $f) { continue }
            $sev = [string](Get-OmniUiValue $f 'Severity' 'Information')
            $title = [string](Get-OmniUiValue $f 'Title' '')
            $component = [string](Get-OmniUiValue $f 'Component' '')
            $detail = [string](Get-OmniUiValue $f 'Detail' '')
            $cause = [string](Get-OmniUiValue $f 'LikelyCause' '')
            $rec = [string](Get-OmniUiValue $f 'Recommendation' '')
            $rank = Get-OmniUiValue $f 'SeverityRank' $null
            if ($null -eq $rank) {
                $i = [Array]::IndexOf([string[]]$script:OmniSeverityOrder, $sev)
                $rank = if ($i -ge 0) { 4 - $i } else { 1 }
            }
            [pscustomobject]@{
                Severity       = $sev
                SeverityRank   = [int]$rank
                Component      = $component
                Title          = $title
                Detail         = $detail
                LikelyCause    = $cause
                Recommendation = $rec
                Confidence     = Get-OmniUiValue $f 'Confidence' 0
                Module         = $module
                GroupId        = $gid
                GroupName      = $gname
                Data           = Get-OmniUiValue $f 'Data' $null
                A11yName       = '{0}: {1} ({2})' -f $sev, $title, $module
                SearchText     = (@($title, $component, $module, $gname, $gid, $detail, $cause, $rec, $sev) -join ' ').ToLowerInvariant()
            }
        }
    }
    return @($rows | Sort-Object -Property SeverityRank -Descending)
}

function Select-OmniFindingRow {
    <#
    .SYNOPSIS
        Internal: filter finding rows by free text (all words must match) and exact severity.

    .PARAMETER Severity
        Critical, Error, Warning, Information, or Pass. Empty or 'All...' = no filter.
    #>
    [OutputType([object[]])]
    param([object[]] $Row = @(), [string] $Text, [string] $Severity)
    $words = @(([string]$Text).ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    $sev = [string]$Severity
    if ($sev -like 'All*') { $sev = '' }
    return @($Row | Where-Object {
        if ($null -eq $_) { return $false }
        if ($sev -and $_.Severity -ne $sev) { return $false }
        foreach ($w in $words) { if (-not $_.SearchText.Contains($w)) { return $false } }
        return $true
    })
}

function Format-OmniEvidenceValue {
    <# .SYNOPSIS Internal: one evidence value as a short single line. #>
    [OutputType([string])]
    param($Value, [int] $MaxLength = 160)
    $s = if ($null -eq $Value) { '' }
         elseif ($Value -is [string]) { $Value }
         elseif ($Value -is [System.Collections.IDictionary]) { "$($Value.Count) field(s)" }
         elseif ($Value -is [System.Collections.IEnumerable]) {
             $items = @($Value)
             $head = @($items | Select-Object -First 3 | ForEach-Object { "$_" }) -join '; '
             if ($items.Count -gt 3) { "$($items.Count) item(s): $head; ..." } elseif ($items.Count) { $head } else { '(none)' }
         } else { "$Value" }
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength - 3) + '...' }
    return $s
}

function Format-OmniEvidenceSummary {
    <#
    .SYNOPSIS
        Internal: a short, readable summary of a finding's evidence (its Data object).

    .OUTPUTS
        Lines of "key: value" (at most MaxItems), or an empty string when there is none.
    #>
    [OutputType([string])]
    param($Data, [int] $MaxItems = 8)
    if ($null -eq $Data) { return '' }
    $pairs = [System.Collections.Generic.List[object]]::new()
    if ($Data -is [string] -or $Data.GetType().IsValueType) {
        $pairs.Add(@('Value', $Data))
    } elseif ($Data -is [System.Collections.IDictionary]) {
        foreach ($k in $Data.Keys) { $pairs.Add(@([string]$k, $Data[$k])) }
    } elseif ($Data -is [System.Collections.IEnumerable]) {
        $i = 1
        foreach ($item in $Data) { $pairs.Add(@("Item $i", $item)); $i++ }
    } else {
        foreach ($p in $Data.PSObject.Properties) {
            if ([string]$p.MemberType -in 'NoteProperty', 'Property', 'AliasProperty') { $pairs.Add(@($p.Name, $p.Value)) }
        }
    }
    if ($pairs.Count -eq 0) { return '' }
    $lines = @($pairs | Select-Object -First $MaxItems | ForEach-Object { '{0}: {1}' -f $_[0], (Format-OmniEvidenceValue $_[1]) })
    if ($pairs.Count -gt $MaxItems) { $lines += "... and $($pairs.Count - $MaxItems) more (see the JSON report)" }
    return ($lines -join [Environment]::NewLine)
}

function Format-OmniFindingDetail {
    <# .SYNOPSIS Internal: the finding detail panel text for one row. #>
    [OutputType([string])]
    param($Row)
    if ($null -eq $Row) { return 'Select a finding to see its details.' }
    $nl = [Environment]::NewLine
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add([string]$Row.Title)
    [void]$lines.Add("Severity: $($Row.Severity)    Component: $($Row.Component)")
    [void]$lines.Add("Module: $($Row.Module)    Group: $($Row.GroupName)")
    $conf = 0
    try { $conf = [int]$Row.Confidence } catch { $conf = 0 }
    if ($conf -gt 0) { [void]$lines.Add("Confidence: $conf%") }
    foreach ($section in @(@('Detail', $Row.Detail), @('Likely cause', $Row.LikelyCause), @('Recommendation', $Row.Recommendation))) {
        if ([string]::IsNullOrWhiteSpace([string]$section[1])) { continue }
        [void]$lines.Add('')
        [void]$lines.Add("$($section[0]):")
        [void]$lines.Add([string]$section[1])
    }
    $evidence = Format-OmniEvidenceSummary -Data $Row.Data
    if ($evidence) {
        [void]$lines.Add('')
        [void]$lines.Add('Evidence:')
        [void]$lines.Add($evidence)
    }
    return ($lines -join $nl)
}

function Get-OmniGroupSummaryRow {
    <#
    .SYNOPSIS
        Internal: one summary row per group (status, score, worst severity, counts).

    .PARAMETER Group
        Group catalog entries: @{ Id; Name; Description; ScannerCount }.

    .PARAMETER Session
        The latest scan, or $null before the first scan.
    #>
    [OutputType([object[]])]
    param([object[]] $Group = @(), $Session)
    $byGroup = @{}
    foreach ($r in @(Get-OmniUiValue $Session 'Results' @())) {
        if ($null -eq $r) { continue }
        $gid = Get-OmniResultGroupId $r
        if (-not $byGroup.ContainsKey($gid)) { $byGroup[$gid] = [System.Collections.Generic.List[object]]::new() }
        $byGroup[$gid].Add($r)
    }
    $rows = foreach ($g in $Group) {
        $id = [string](Get-OmniUiValue $g 'Id' '')
        $name = [string](Get-OmniUiValue $g 'Name' $id)
        # @(...) around the whole if: an if expression unrolls an empty or one-item array.
        $results = @(if ($byGroup.ContainsKey($id)) { $byGroup[$id] })
        $counts = @{ Critical = 0; Error = 0; Warning = 0; Information = 0; Pass = 0 }
        foreach ($r in $results) {
            foreach ($f in @(Get-OmniUiValue $r 'Findings' @())) {
                $s = [string](Get-OmniUiValue $f 'Severity' '')
                if ($counts.ContainsKey($s)) { $counts[$s]++ }
            }
        }
        $worst = $null
        foreach ($s in $script:OmniSeverityOrder) { if ($counts[$s] -gt 0) { $worst = $s; break } }
        $status = if ($Session) { 'Not scanned' } else { 'No scan yet' }
        $score = '-'
        if ($results.Count -gt 0) {
            if (-not $worst) { $worst = 'None' }
            $status = 'Scanned'
            try {
                $hs = Get-OmniHealthScore -Result $results
                $score = [string]$hs.Score
                $status = [string]$hs.Grade
            } catch { $null = $_ }
        }
        if (-not $worst) { $worst = '-' }
        $total = Get-OmniUiValue $g 'ScannerCount' $null
        $scanners = if ($null -ne $total) { "$($results.Count) of $total" } else { [string]$results.Count }
        [pscustomobject]@{
            Id          = $id
            Name        = $name
            Description = [string](Get-OmniUiValue $g 'Description' '')
            Status      = $status
            Score       = $score
            Worst       = $worst
            Critical    = $counts.Critical
            Error       = $counts.Error
            Warning     = $counts.Warning
            Scanners    = $scanners
            ResultCount = $results.Count
            A11yName    = '{0}: {1}, score {2}, worst severity {3}, {4} critical, {5} error, {6} warning' -f
                          $name, $status, $score, $worst, $counts.Critical, $counts.Error, $counts.Warning
        }
    }
    return @($rows)
}

function Get-OmniModuleRow {
    <# .SYNOPSIS Internal: module-result grid rows (optionally one group only). #>
    [OutputType([object[]])]
    param($Session, [hashtable] $GroupNames = @{}, [string] $GroupId)
    $rows = foreach ($r in @(Get-OmniUiValue $Session 'Results' @())) {
        if ($null -eq $r) { continue }
        $gid = Get-OmniResultGroupId $r
        if ($GroupId -and $gid -ne $GroupId) { continue }
        $name = [string](Get-OmniUiValue $r 'ModuleName' '')
        $status = [string](Get-OmniUiValue $r 'Status' '')
        $count = @(Get-OmniUiValue $r 'Findings' @()).Count
        [pscustomobject]@{
            Module     = $name
            Category   = [string](Get-OmniUiValue $r 'Category' '')
            GroupName  = if ($GroupNames.ContainsKey($gid)) { [string]$GroupNames[$gid] } else { $gid }
            Status     = $status
            Findings   = $count
            DurationMs = Get-OmniUiValue $r 'DurationMs' 0
            A11yName   = '{0}: {1}, {2} finding(s)' -f $name, $status, $count
        }
    }
    return @($rows)
}

# ---------------------------------------------------------------------------
# Dashboard, findings, groups (UI thread)
# ---------------------------------------------------------------------------

function Update-OmniDashboard {
    <# .SYNOPSIS Internal: render a completed session into the UI (UI thread only). #>
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [pscustomobject] $Session)
    $s = $Session.Summary

    if ($s) {
        $Ui.Controls.TxtScore.Text = [string]$s.Score
        $Ui.ScoreGrade = [string]$s.Grade
        $Ui.Controls.TxtGrade.Text = $s.Grade
        $Ui.Controls.TxtCounts.Text = "Critical {0}  |  Error {1}  |  Warning {2}  |  Info {3}  |  Pass {4}" -f `
            $s.Counts.Critical, $s.Counts.Error, $s.Counts.Warning, $s.Counts.Information, $s.Counts.Pass
        $Ui.Controls.ItemsRecommendations.ItemsSource = @($s.TopRecommendations)
        [System.Windows.Automation.AutomationProperties]::SetName($Ui.Controls.TxtScore, "Health score $($s.Score) of 100, $($s.Grade)")
    }
    Write-OmniScoreColor
    $Ui.Controls.TxtComputer.Text = "Computer: $($Session.Host.ComputerName)"
    $Ui.Controls.TxtUser.Text     = "User: $($Session.Host.UserName)"
    $Ui.Controls.TxtRange.Text    = "Range: $($Session.TimeRange.Label)"
    $Ui.Controls.TxtDuration.Text = "Duration: {0:N1} s" -f ($Session.DurationMs / 1000)

    # The Module Results grid loads right after first paint; if it has not yet, its
    # init binds the session itself.
    if (Test-OmniSectionLoaded -Name 'DashboardModules') {
        $Ui.Controls.GridModules.ItemsSource = @(Get-OmniModuleRow -Session $Session -GroupNames $Ui.GroupNames)
    }
    $Ui.FindingRows = @(ConvertTo-OmniGuiFindingRow -Session $Session -GroupNames $Ui.GroupNames)
    Show-OmniFindingFilter
    Show-OmniGroupSummary
}

function Show-OmniFindingFilter {
    <# .SYNOPSIS Internal: apply the text + severity filter to the All Findings grid (once that section has loaded). #>
    $ui = $script:OmniUi
    if (-not (Test-OmniSectionLoaded -Name 'Findings')) { return }
    $c = $ui.Controls
    $sevItem = $c.CmbSeverityFilter.SelectedItem
    $sev = if ($sevItem) { [string]$sevItem.Content } else { '' }
    $all = @($ui.FindingRows)
    $rows = @(Select-OmniFindingRow -Row $all -Text ([string]$c.TxtFindingFilter.Text) -Severity $sev)
    $c.GridFindings.ItemsSource = $rows
    $c.TxtFindingCount.Text = if (-not $ui.Session) { 'No scan yet.' } else { "Showing $(@($rows).Count) of $($all.Count) findings." }
    if (@($rows).Count -eq 0) { $c.TxtFindingDetail.Text = if ($ui.Session) { 'No findings match the filter.' } else { 'Run a scan to see findings.' } }
    Invoke-OmniLiveRegion -Element $c.TxtFindingCount
}

function Invoke-OmniGridFocus {
    <# .SYNOPSIS Internal: put keyboard focus on a grid's selected (or first) row. #>
    param([Parameter(Mandatory)] $Grid)
    if ($Grid.Items.Count -eq 0) { [void]$Grid.Focus(); return }
    if ($Grid.SelectedIndex -lt 0) { $Grid.SelectedIndex = 0 }
    $Grid.ScrollIntoView($Grid.SelectedItem)
    $Grid.UpdateLayout()
    $row = $Grid.ItemContainerGenerator.ContainerFromIndex($Grid.SelectedIndex)
    if ($row) {
        [void]$row.MoveFocus([System.Windows.Input.TraversalRequest]::new([System.Windows.Input.FocusNavigationDirection]::Next))
    } else {
        [void]$Grid.Focus()
    }
}

function Show-OmniFindingDetail {
    <# .SYNOPSIS Internal: Enter on a finding - fill the detail box and move focus to it. #>
    param([Parameter(Mandatory)] $Grid, [Parameter(Mandatory)] $Target)
    if (-not $Grid.SelectedItem) { return }
    $Target.Text = Format-OmniFindingDetail -Row $Grid.SelectedItem
    [void]$Target.Focus()
    $Target.CaretIndex = 0
}

function Show-OmniGroupSummary {
    <# .SYNOPSIS Internal: (re)build the Groups grid from the catalog and the latest session (once that section has loaded). #>
    $ui = $script:OmniUi
    if (-not (Test-OmniSectionLoaded -Name 'Groups')) { return }
    $grid = $ui.Controls.GridGroups
    $selectedId = if ($grid.SelectedItem) { [string]$grid.SelectedItem.Id } else { '' }
    $rows = @(Get-OmniGroupSummaryRow -Group @($ui.GroupCatalog) -Session $ui.Session)
    $ui.GroupRows = $rows
    $grid.ItemsSource = $rows
    if ($selectedId) {
        for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Id -eq $selectedId) { $grid.SelectedIndex = $i; break } }
    }
    if ($ui.SelectedGroupId -and $ui.Controls.GroupDetailView.Visibility -eq 'Visible') {
        $current = @($rows | Where-Object { $_.Id -eq $ui.SelectedGroupId }) | Select-Object -First 1
        if ($current) { Show-OmniGroupDetail -GroupRow $current -KeepFocus }
    }
}

function Show-OmniGroupDetail {
    <# .SYNOPSIS Internal: drill into one group - its modules and findings. #>
    param([Parameter(Mandatory)] $GroupRow, [switch] $KeepFocus)
    $ui = $script:OmniUi
    $c = $ui.Controls
    $ui.SelectedGroupId = [string]$GroupRow.Id
    $c.TxtGroupTitle.Text = [string]$GroupRow.Name
    $summary = if ($ui.Session) {
        "Status: $($GroupRow.Status). Score: $($GroupRow.Score). Worst severity: $($GroupRow.Worst). " +
        "Critical $($GroupRow.Critical), Error $($GroupRow.Error), Warning $($GroupRow.Warning). Scanners run: $($GroupRow.Scanners)."
    } else { 'No scan yet - run a scan (F5) to fill this group.' }
    if ($GroupRow.Description) { $summary += " $($GroupRow.Description)" }
    $c.TxtGroupSummary.Text = $summary
    $c.GridGroupModules.ItemsSource = @(Get-OmniModuleRow -Session $ui.Session -GroupNames $ui.GroupNames -GroupId $ui.SelectedGroupId)
    $findings = @($ui.FindingRows | Where-Object { $_ -and $_.GroupId -eq $ui.SelectedGroupId })
    $c.GridGroupFindings.ItemsSource = $findings
    $c.TxtGroupFindingDetail.Text = if ($findings.Count) { 'Select a finding to see its details.' } elseif ($ui.Session) { 'No findings in this group.' } else { 'Run a scan to see findings.' }
    $c.GroupListView.Visibility = 'Collapsed'
    $c.GroupDetailView.Visibility = 'Visible'
    if ($KeepFocus) { return }
    $ui.Window.UpdateLayout()
    if ($findings.Count) { Invoke-OmniGridFocus -Grid $c.GridGroupFindings } else { [void]$c.BtnGroupBack.Focus() }
    Write-OmniStatus -Text "Group $($GroupRow.Name): $($GroupRow.Status), $($findings.Count) finding(s)." -Announce
}

function Hide-OmniGroupDetail {
    <# .SYNOPSIS Internal: back from a group to the group list (focus returns to that group). #>
    $ui = $script:OmniUi
    $c = $ui.Controls
    if ($c.GroupDetailView.Visibility -ne 'Visible') { return }
    $c.GroupDetailView.Visibility = 'Collapsed'
    $c.GroupListView.Visibility = 'Visible'
    $ui.Window.UpdateLayout()
    Invoke-OmniGridFocus -Grid $c.GridGroups
    $ui.SelectedGroupId = $null
}

function Open-OmniSelectedGroup {
    <# .SYNOPSIS Internal: open the group selected in the Groups grid. #>
    $row = $script:OmniUi.Controls.GridGroups.SelectedItem
    if ($row) { Show-OmniGroupDetail -GroupRow $row }
}

# ---------------------------------------------------------------------------
# Catalogs (repairs, scanners, groups) and System Information
# ---------------------------------------------------------------------------

function Show-OmniRepairCatalog {
    <# .SYNOPSIS Internal: bind plain repair entries (from a background task) to the Repair grid. #>
    param([object[]] $Item = @())
    $ui = $script:OmniUi
    $rows = @($Item | Where-Object { $_ } | ForEach-Object {
        $rec = [bool]$_.Recommended
        $admin = [bool]$_.RequiresAdmin
        $a11y = '{0}, risk {1}' -f $_.Name, $_.Risk
        if ($rec) { $a11y += ', recommended' }
        if ($admin) { $a11y += ', needs administrator' }
        [pscustomobject]@{
            Selected     = $rec
            Mark         = if ($rec) { 'Yes' } else { '' }
            Name         = [string]$_.Name
            Category     = [string]$_.Category
            Risk         = [string]$_.Risk
            Admin        = if ($admin) { 'Yes' } else { '' }
            Recommended  = $rec
            RestorePoint = [bool]$_.RestorePoint
            Reboot       = [bool]$_.RebootHint
            A11yName     = $a11y
        }
    })
    $ui.RepairCatalog = $rows
    # The Repair Center binds $ui.RepairCatalog itself when it loads later.
    if (Test-OmniSectionLoaded -Name 'Repair') { $ui.Controls.RepairGrid.ItemsSource = $rows }
}

# Background script: repair catalog as plain hashtables (registrations hold PSModuleInfo).
# Get-OmniDiagRepair -Session flags the repairs recommended for that scan.
$script:OmniRepairCatalogScript = {
    param($SyncHash, $A)
    $cat = @(if ($A.Session) {
        Get-OmniDiagRepair -Session $A.Session -RepairsPath $A.RepairsPath
    } else {
        Get-OmniDiagRepair -RepairsPath $A.RepairsPath
    })
    , @($cat | ForEach-Object {
        @{
            Name = [string]$_.Name; Category = [string]$_.Category; Risk = [string]$_.Risk
            RequiresAdmin = [bool]$_.RequiresAdmin; Recommended = [bool]$_.Recommended
            RestorePoint = [bool]$_.RestorePoint; RebootHint = [bool]$_.RebootHint
        }
    })
}

function Invoke-OmniRepairCatalogLoad {
    <# .SYNOPSIS Internal: (re)load the repair catalog off the UI thread (flags Recommended for a session). #>
    param($Session)
    $ui = $script:OmniUi
    [void](Invoke-OmniUiTask -Name 'Repair catalog' -Script $script:OmniRepairCatalogScript `
        -Arguments @{ Session = $Session; RepairsPath = $ui.RepairsPath } `
        -OnComplete {
            param($Sync, $Ctx)
            if ($Sync.Error) { Write-OmniStatus -Text "Could not load repairs: $($Sync.Error)"; return }
            Show-OmniRepairCatalog -Item @($Sync.Result)
        })
}

function Initialize-OmniGroupCatalog {
    <# .SYNOPSIS Internal: group names before discovery finishes (cheap; no plugin loading). #>
    $groups = @()
    try {
        $groups = @(Get-OmniGroup | ForEach-Object { @{ Id = [string]$_.Id; Name = [string]$_.DisplayName; Description = ''; ScannerCount = $null } })
    } catch { $groups = @() }
    Register-OmniGroupCatalog -Group $groups
}

function Register-OmniGroupCatalog {
    <# .SYNOPSIS Internal: store the group catalog and its id -> name map. #>
    param([object[]] $Group = @())
    $ui = $script:OmniUi
    $ui.GroupCatalog = @($Group | Where-Object { $_ })
    $names = @{}
    foreach ($g in $ui.GroupCatalog) { $names[[string]$g.Id] = [string]$g.Name }
    $ui.GroupNames = $names
}

function Get-OmniSystemInfo {
    <#
    .SYNOPSIS
        Internal: gather DxDiag-style system information (grouped label/value sections).

    .DESCRIPTION
        Returns an ordered dictionary of section name -> ordered dictionary of label/value,
        for the Dashboard's System Information panel. The data comes from the shared
        Get-OmniSystemInventory (src/Core/SystemInventory.psm1), the same inventory the
        System Information scanner reports. It fails soft (missing values are simply
        omitted), so this never throws. The GUI calls it in a background runspace (CIM).
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $add = { param($Bag, $Key, $Value) if ($null -ne $Value -and "$Value".Trim()) { $Bag[$Key] = "$Value".Trim() } }

    $inv = $null
    try { $inv = Get-OmniSystemInventory } catch { $inv = $null }
    $os   = $null; $cs = $null; $bios = $null; $cpu = $null; $page = $null
    if ($inv) {
        $os   = $inv.OperatingSystem
        $cs   = $inv.ComputerSystem
        $bios = $inv.Bios
        $cpu  = $inv.Processor
        $page = $inv.PageFile
    }

    $info = [ordered]@{}

    # --- System ----------------------------------------------------------
    $sys = [ordered]@{}
    & $add $sys 'Computer Name' $env:COMPUTERNAME
    if ($os) {
        & $add $sys 'Operating System' ("{0} {1} (Build {2})" -f $os.Caption, $os.Version, $os.BuildNumber)
        & $add $sys 'Architecture' $os.OSArchitecture
        try { & $add $sys 'Language' (Get-Culture).DisplayName } catch { }
        try { if ($os.InstallDate) { & $add $sys 'Install Date' ('{0:yyyy-MM-dd}' -f $os.InstallDate) } } catch { }
        try {
            if ($os.LastBootUpTime) {
                $up = (Get-Date) - $os.LastBootUpTime
                & $add $sys 'Uptime' ('{0}d {1}h {2}m' -f [int]$up.TotalDays, $up.Hours, $up.Minutes)
            }
        } catch { }
        # DirectX: Windows 10/11 ship DirectX 12.
        try { if ([version]$os.Version -ge [version]'10.0') { & $add $sys 'DirectX Version' 'DirectX 12' } } catch { }
    }
    if ($cs) {
        & $add $sys 'Manufacturer' $cs.Manufacturer
        & $add $sys 'Model' $cs.Model
        & $add $sys 'System Type' $cs.SystemType
        if ($cs.PartOfDomain) { & $add $sys 'Domain' $cs.Domain } else { & $add $sys 'Workgroup' $cs.Workgroup }
        if ($cs.TotalPhysicalMemory) { & $add $sys 'Installed Memory (RAM)' ('{0} GB' -f [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)) }
    }
    & $add $sys 'Logged-in User' ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    if ($bios) {
        $biosDate = try { if ($bios.ReleaseDate) { ' ({0:yyyy-MM-dd})' -f $bios.ReleaseDate } else { '' } } catch { '' }
        & $add $sys 'BIOS' ("{0} {1}{2}" -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion, $biosDate)
    }
    if ($page -and $page.AllocatedBaseSize) {
        & $add $sys 'Page File' ('{0} MB used / {1} MB allocated' -f $page.CurrentUsage, $page.AllocatedBaseSize)
    }
    $info['System'] = $sys

    # --- Processor -------------------------------------------------------
    if ($cpu) {
        $proc = [ordered]@{}
        & $add $proc 'Processor' $cpu.Name
        & $add $proc 'Cores / Threads' ("{0} cores, {1} logical" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
        if ($cpu.MaxClockSpeed) { & $add $proc 'Max Clock' ('{0} MHz' -f $cpu.MaxClockSpeed) }
        $info['Processor'] = $proc
    }

    # --- Display (one section per GPU) -----------------------------------
    $gpus = @(if ($inv) { $inv.VideoController | Where-Object { $_.Name } })
    for ($i = 0; $i -lt $gpus.Count; $i++) {
        $g = $gpus[$i]
        $disp = [ordered]@{}
        & $add $disp 'Name' $g.Name
        & $add $disp 'Chip / Vendor' ((@($g.VideoProcessor, $g.AdapterCompatibility) | Where-Object { $_ } | Select-Object -Unique) -join ' / ')
        if ($g.AdapterRAM -and $g.AdapterRAM -gt 0) { & $add $disp 'Dedicated Memory (approx)' ('{0} GB' -f [math]::Round([uint64]$g.AdapterRAM / 1GB, 1)) }
        if ($g.CurrentHorizontalResolution -and $g.CurrentVerticalResolution) {
            $mode = '{0} x {1}' -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution
            if ($g.CurrentRefreshRate) { $mode += ' @ {0} Hz' -f $g.CurrentRefreshRate }
            & $add $disp 'Current Mode' $mode
        }
        & $add $disp 'Driver Version' $g.DriverVersion
        try { if ($g.DriverDate) { & $add $disp 'Driver Date' ('{0:yyyy-MM-dd}' -f $g.DriverDate) } } catch { }
        $title = if ($gpus.Count -gt 1) { "Display $($i + 1)" } else { 'Display' }
        $info[$title] = $disp
    }

    # --- Sound -----------------------------------------------------------
    $snd = @(if ($inv) { $inv.SoundDevice | Where-Object { $_.Name } })
    if ($snd.Count -gt 0) {
        $sound = [ordered]@{}
        $n = 1
        foreach ($d in $snd) { & $add $sound ("Device $n") $d.Name; $n++ }
        $info['Sound'] = $sound
    }

    return $info
}

function Update-OmniSysInfoPanel {
    <# .SYNOPSIS Internal: render Get-OmniSystemInfo output into the Dashboard's PanelSysInfo. #>
    param([hashtable] $Ui, [System.Collections.IDictionary] $Info)
    $panel = $Ui.Controls.PanelSysInfo
    if (-not $panel) { return }
    $panel.Children.Clear()
    if (-not $Info -or $Info.Count -eq 0) {
        $t = [System.Windows.Controls.TextBlock]::new()
        $t.Text = 'System information is unavailable.'
        $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'BrushMuted')
        [void]$panel.Children.Add($t)
        return
    }

    $first = $true
    foreach ($sectionName in $Info.Keys) {
        $h = [System.Windows.Controls.TextBlock]::new()
        $h.Text = $sectionName
        $h.FontWeight = 'SemiBold'
        $h.Margin = if ($first) { '0,0,0,4' } else { '0,12,0,4' }
        $h.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'BrushText')
        [void]$panel.Children.Add($h)
        $first = $false

        foreach ($entry in $Info[$sectionName].GetEnumerator()) {
            $g = [System.Windows.Controls.Grid]::new()
            $c0 = [System.Windows.Controls.ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(190)
            $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)

            $lbl = [System.Windows.Controls.TextBlock]::new()
            $lbl.Text = $entry.Key; $lbl.Margin = '0,1,8,1'
            $lbl.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'BrushMuted')
            [System.Windows.Controls.Grid]::SetColumn($lbl, 0)

            $val = [System.Windows.Controls.TextBlock]::new()
            $val.Text = [string]$entry.Value; $val.TextWrapping = 'Wrap'; $val.Margin = '0,1,0,1'
            $val.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'BrushText')
            [System.Windows.Controls.Grid]::SetColumn($val, 1)
            # Read as "Label: value" by screen readers.
            [System.Windows.Automation.AutomationProperties]::SetName($val, "$($entry.Key): $($entry.Value)")

            [void]$g.Children.Add($lbl); [void]$g.Children.Add($val)
            [void]$panel.Children.Add($g)
        }
    }
}

# Background script for deferred startup: system info, repair catalog, scanner/group catalog.
# Each part publishes into $SyncHash as soon as it is ready (the UI shows it on the next tick).
$script:OmniStartupScript = {
    param($SyncHash, $A)
    # 1. System Information (CIM).
    try {
        $gui = $null
        $root = Get-Module -Name OmniDiag | Select-Object -First 1
        if ($root) { $gui = @($root.NestedModules | Where-Object { $_.Name -eq 'OmniDiagGui' }) | Select-Object -First 1 }
        if (-not $gui) { $gui = Import-Module $A.GuiModule -PassThru -Force -DisableNameChecking }
        $SyncHash.SysInfo = & $gui { Get-OmniSystemInfo }
    } catch {
        $SyncHash.SysInfoError = $_.Exception.Message
    }
    $SyncHash.SysInfoDone = $true

    $log = New-OmniLogger -MinimumLevel Error

    # 2. Repair catalog (plain values only).
    try {
        $SyncHash.Repairs = @(Get-OmniDiagRepair -RepairsPath $A.RepairsPath | ForEach-Object {
            @{
                Name = [string]$_.Name; Category = [string]$_.Category; Risk = [string]$_.Risk
                RequiresAdmin = [bool]$_.RequiresAdmin; Recommended = [bool]$_.Recommended
                RestorePoint = [bool]$_.RestorePoint; RebootHint = [bool]$_.RebootHint
            }
        })
    } catch {
        $SyncHash.RepairsError = $_.Exception.Message
    }
    $SyncHash.RepairsDone = $true

    # 3. Scanner and group catalog (Diagnostics tab + Groups view). Enabled scanners only:
    # the engine never runs a disabled one, and Invoke-OmniDiagScan -Module rejects it.
    try {
        $SyncHash.Scanners = @(Get-OmniModule -Path $A.ModulesPath -Logger $log | Where-Object { $_.Enabled } | ForEach-Object {
            @{ Name = [string]$_.Name; Category = [string]$_.Category; Order = [int]$_.Order; Group = [string]$_.Group; Id = [string]$_.Id }
        })
        $SyncHash.Groups = @(Get-OmniDiagGroup -ModulesPath $A.ModulesPath | ForEach-Object {
            @{ Id = [string]$_.Id; Name = [string]$_.Name; Description = [string]$_.Description; ScannerCount = [int]$_.ScannerCount }
        })
    } catch {
        $SyncHash.CatalogError = $_.Exception.Message
    }
    $SyncHash.CatalogDone = $true
}

function Invoke-OmniDeferredStartup {
    <#
    .SYNOPSIS
        Internal: start the non-essential startup work after first paint.

    .DESCRIPTION
        Queued at ApplicationIdle from ContentRendered. Everything slow (CIM inventory,
        loading repair and scanner plugins) runs in one background runspace; the results
        are rendered on the UI thread as each part arrives.
    #>
    $ui = $script:OmniUi
    if (-not $ui -or $ui.Closed -or -not $ui.ShellReady -or $ui.StartupTask) { return }
    $ui.StartupTask = Invoke-OmniUiTask -Name 'Startup' -Script $script:OmniStartupScript `
        -Arguments @{ ModulesPath = $ui.ModulesPath; RepairsPath = $ui.RepairsPath; GuiModule = (Join-Path $script:OmniUiRoot 'OmniDiagGui.psm1') } `
        -Context @{ SysInfo = $false; Repairs = $false; Catalog = $false } `
        -OnProgress { param($Sync, $Ctx) Receive-OmniStartupPart -Sync $Sync -Context $Ctx } `
        -OnComplete {
            param($Sync, $Ctx)
            Receive-OmniStartupPart -Sync $Sync -Context $Ctx
            if ($Sync.Error) { Write-OmniStatus -Text "Startup tasks failed: $($Sync.Error)" }
        }
}

function Receive-OmniStartupPart {
    <# .SYNOPSIS Internal: render whichever deferred-startup parts have arrived (once each). #>
    param([Parameter(Mandatory)] $Sync, [Parameter(Mandatory)] [hashtable] $Context)
    $ui = $script:OmniUi
    if ($Sync.SysInfoDone -and -not $Context.SysInfo) {
        $Context.SysInfo = $true
        try { Update-OmniSysInfoPanel -Ui $ui -Info $Sync.SysInfo } catch { Write-OmniStatus -Text "System info unavailable: $($_.Exception.Message)" }
    }
    if ($Sync.RepairsDone -and -not $Context.Repairs) {
        $Context.Repairs = $true
        # A scan that finished first already loaded a session-aware catalog; keep that one.
        if (-not $ui.Session) {
            if ($Sync.RepairsError) { Write-OmniStatus -Text "Could not load repairs: $($Sync.RepairsError)" }
            else { Show-OmniRepairCatalog -Item @($Sync.Repairs) }
        }
    }
    if ($Sync.CatalogDone -and -not $Context.Catalog) {
        $Context.Catalog = $true
        if ($Sync.CatalogError) {
            Write-OmniStatus -Text "Could not load scanners: $($Sync.CatalogError)"
        } else {
            $ui.ScannerCatalog = @($Sync.Scanners)
            if (@($Sync.Groups).Count -gt 0) { Register-OmniGroupCatalog -Group @($Sync.Groups) }
            Show-OmniGroupSummary
            if ($ui.Controls.PanelDiagnostics.Visibility -eq 'Visible') { Initialize-OmniDiagPanel }
        }
    }
}

function Initialize-OmniDiagPanel {
    <#
    .SYNOPSIS
        Internal: populate the Diagnostics tab's tool grid once, from the scanner catalog.

    .DESCRIPTION
        Builds one row per scanner (Enabled toggle + Name/Group/Category/Status), sorted by
        category then run order, and binds them to DiagGrid. Cached on $ui.DiagRows so the
        toggle state persists for the session. The catalog is discovered in the background
        after first paint; until it arrives the tab shows a loading status.
    #>
    $ui = $script:OmniUi
    if ($ui.DiagRows -or -not (Test-OmniSectionLoaded -Name 'Diagnostics')) { return }
    if (-not $ui.ScannerCatalog) { Write-OmniStatus -Text 'Loading the scanner list...'; return }
    $rows = @($ui.ScannerCatalog | Sort-Object { $_.Category }, { $_.Order }, { $_.Name } | ForEach-Object {
        $gname = if ($ui.GroupNames.ContainsKey([string]$_.Group)) { $ui.GroupNames[[string]$_.Group] } else { [string]$_.Group }
        [pscustomobject]@{
            Enabled = $true; Name = [string]$_.Name; Category = [string]$_.Category; Order = $_.Order
            GroupName = $gname; Status = ''; A11yName = "$($_.Name), $gname"
        }
    })
    $ui.DiagRows = $rows
    $ui.Controls.DiagGrid.ItemsSource = $rows
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

function Start-OmniScan {
    <#
    .SYNOPSIS
        Internal: launch a diagnostic scan in a background runspace and wire the UI.

    .PARAMETER IncludeModule
        Limit the run to these scanner names. $null runs every scanner. Used by both
        Run Scan (the enabled set from the Diagnostics tab) and a single-scanner run.
    #>
    param([string[]] $IncludeModule)

    $ui = $script:OmniUi
    if (Test-OmniUiBusy) { return }

    $rangeMap = @('Last24Hours', 'Last7Days', 'Last30Days')
    $idx = [Math]::Max(0, $ui.Controls.CmbRange.SelectedIndex)
    $range = $rangeMap[$idx]
    # Connectivity probes are opt-in (decision 1): only when the box is ticked.
    $probes = $false
    if ($ui.Controls.ChkNetworkProbes) { $probes = ($ui.Controls.ChkNetworkProbes.IsChecked -eq $true) }

    $sync = [hashtable]::Synchronized(@{ Progress = 0; CurrentModule = ''; Phase = ''; Done = $false; Session = $null; Error = $null })
    $cts = [System.Threading.CancellationTokenSource]::new()

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $bg = {
        param($SyncHash, $Token, $Range, $Manifest, $ModulesPath, $IncludeModule, $NetworkProbes)
        try {
            Import-Module $Manifest -Force -DisableNameChecking
            $cb = {
                param($p)
                $SyncHash.Progress = $p.PercentComplete
                $SyncHash.CurrentModule = $p.Name
                $SyncHash.Phase = $p.Phase
            }.GetNewClosure()
            # Curated scan cmdlet; -AsSession returns the native session the GUI renders.
            # Its logger never writes to the console, and -Module takes scanner names.
            $params = @{
                AsSession = $true; Range = $Range; ProgressCallback = $cb; CancellationToken = $Token
                NetworkProbes = [bool]$NetworkProbes
            }
            if ($ModulesPath) { $params.ModulesPath = $ModulesPath }
            if ($IncludeModule) { $params.Module = $IncludeModule }
            $SyncHash.Session = Invoke-OmniDiagScan @params
            # Save with the tool (like the console) so -FromSession/-CompareWith Last see GUI
            # scans. Done here, not on the UI thread: serializing a session can take a while.
            try { Save-OmniSession -Session $SyncHash.Session | Out-Null } catch { $SyncHash.SaveError = $_.Exception.Message }
        } catch {
            $SyncHash.Error = $_.Exception.Message
        } finally {
            $SyncHash.Done = $true
        }
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($bg).AddParameters(@{
        SyncHash = $sync; Token = $cts.Token; Range = $range
        Manifest = $ui.Manifest; ModulesPath = $ui.ModulesPath
        IncludeModule = $IncludeModule; NetworkProbes = $probes
    })
    $handle = $ps.BeginInvoke()

    $ui.Scan = @{ Sync = $sync; Cts = $cts; PowerShell = $ps; Runspace = $rs; Handle = $handle; Cancelling = $false; LastModule = '' }
    Sync-OmniBusyState
    $ui.Controls.ProgressBarMain.IsIndeterminate = $false
    $ui.Controls.ProgressBarMain.Value = 0
    $selNote = if ($IncludeModule) { " ($(@($IncludeModule).Count) selected)" } else { ' (all scanners)' }
    Write-OmniStatus -Text "Starting scan$selNote..." -Announce
    $ui.Timer.Start()
}

function Invoke-OmniScanRequest {
    <# .SYNOPSIS Internal: Run Scan button / F5 - honor the Diagnostics toggles, then scan. #>
    $ui = $script:OmniUi
    if (Test-OmniUiBusy) { return }
    # Honor the Diagnostics tab toggles (once it has been populated). If the tab was
    # never opened, DiagRows is empty and we simply run every scanner.
    $only = $null
    $rows = @($ui.DiagRows)
    if ($rows.Count -gt 0) {
        $enabled = @($rows | Where-Object { $_.Enabled } | ForEach-Object { $_.Name })
        if ($enabled.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Enable at least one scanner on the Diagnostics tab to run.', 'OmniDiag', 'OK', 'Warning') | Out-Null
            return
        }
        if ($enabled.Count -lt $rows.Count) { $only = $enabled }
    }
    Start-OmniScan -IncludeModule $only
}

function Invoke-OmniScanPoll {
    <# .SYNOPSIS Internal: scan timer tick - progress, then render the finished session. #>
    $ui = $script:OmniUi
    $scan = $ui.Scan
    if (-not $scan) { return }
    $sync = $scan.Sync
    $ui.Controls.ProgressBarMain.Value = [double]$sync.Progress
    if (-not $scan.Cancelling) {
        $phase = if ($sync.CurrentModule) { "$($sync.CurrentModule) [$($sync.Phase)]" } else { 'Starting...' }
        Write-OmniStatus -Text "Scanning: $phase"
    }
    if (-not $sync.Done) { return }

    $ui.Timer.Stop()
    try { $scan.PowerShell.EndInvoke($scan.Handle) } catch { $null = $_ }
    $scan.PowerShell.Dispose(); $scan.Runspace.Dispose(); $scan.Cts.Dispose()
    $ui.Scan = $null

    if ($sync.Error) {
        Write-OmniStatus -Text "Scan failed: $($sync.Error)" -Announce
    } else {
        try {
            $ui.Session = $sync.Session
            Update-OmniDashboard -Ui $ui -Session $sync.Session
            Invoke-OmniRepairCatalogLoad -Session $sync.Session   # light up recommended repairs

            # Reflect the latest per-scanner status on the Diagnostics tab.
            if ($ui.DiagRows) {
                $statusByName = @{}
                foreach ($r in $sync.Session.Results) { $statusByName[$r.ModuleName] = $r.Status }
                foreach ($row in $ui.DiagRows) {
                    if ($statusByName.ContainsKey($row.Name)) { $row.Status = $statusByName[$row.Name] }
                }
                $ui.Controls.DiagGrid.Items.Refresh()
            }

            $cancelledNote = if ($sync.Session.Cancelled) { ' (cancelled)' } else { '' }
            # Summary is $null when a scan is cancelled before any module finishes.
            $scoreText = if ($sync.Session.Summary) { "Score $($sync.Session.Summary.Score) of 100, $($sync.Session.Summary.Grade)." } else { 'No score (no modules completed).' }
            $count = @($ui.FindingRows).Count
            Write-OmniStatus -Text "Scan complete$cancelledNote. $scoreText $count finding(s)." -Announce
        } catch {
            Write-OmniStatus -Text "Scan finished, but the results could not be displayed: $($_.Exception.Message)" -Announce
        }
    }
    $ui.Controls.ProgressBarMain.Value = 100
    Sync-OmniBusyState
}

function Request-OmniScanCancel {
    <# .SYNOPSIS Internal: cooperative cancel of the running scan. #>
    $ui = $script:OmniUi
    if (-not $ui.Scan -or $ui.Scan.Cancelling) { return }
    $ui.Scan.Cancelling = $true
    $ui.Scan.Cts.Cancel()
    Write-OmniStatus -Text 'Cancelling the scan after the current module...' -Announce
    Sync-OmniBusyState
}

function Request-OmniRepairCancel {
    <# .SYNOPSIS Internal: cooperative cancel of running repairs (stops after the current step). #>
    $ui = $script:OmniUi
    if (-not $ui.Repair -or $ui.Repair.Cancelling) { return }
    $ui.Repair.Cancelling = $true
    $ui.Repair.Cts.Cancel()
    Write-OmniStatus -Text 'Cancelling repairs after the current step...' -Announce
    Sync-OmniBusyState
}

function Request-OmniCancel {
    <# .SYNOPSIS Internal: Esc - cancel a scan, else repairs, else leave an open group. #>
    $ui = $script:OmniUi
    if ($ui.Scan) { Request-OmniScanCancel; return }
    if ($ui.Repair) { Request-OmniRepairCancel; return }
    if ((Test-OmniSectionLoaded -Name 'Groups') -and $ui.Controls.PanelGroups.Visibility -eq 'Visible' -and
        $ui.Controls.GroupDetailView.Visibility -eq 'Visible') { Hide-OmniGroupDetail }
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

function Test-OmniRedactSupported {
    <#
    .SYNOPSIS
        Internal: can Export-OmniDiagReport -Redact run (shared-report pseudonymization)?

    .DESCRIPTION
        True when Export-OmniDiagReport has -Redact and the redaction module's commands
        (New-OmniRedactionContext, ConvertTo-OmniRedacted) are loaded.
    #>
    [OutputType([bool])]
    param()
    $cmd = Get-Command -Name Export-OmniDiagReport -ErrorAction SilentlyContinue
    if (-not ($cmd -and $cmd.Parameters.ContainsKey('Redact'))) { return $false }
    return [bool]((Get-Command -Name New-OmniRedactionContext -ErrorAction SilentlyContinue) -and
        (Get-Command -Name ConvertTo-OmniRedacted -ErrorAction SilentlyContinue))
}

function Show-OmniExportDialog {
    <#
    .SYNOPSIS
        Internal: modal dialog to choose report formats, the zip bundle, and redaction.

    .DESCRIPTION
        Built programmatically (no XAML file) so it stays self-contained; it copies the
        owner's brush resources so it matches the current theme (including high contrast).
        Every control is named for screen readers and has an access key. Returns
        [pscustomobject]@{ Formats = [string[]]; Redact = [bool] }, or $null when the user
        cancels or selects nothing.

    .PARAMETER Owner
        The main window, so the dialog centers on it and is modal to it.

    .PARAMETER RedactSupported
        Whether Export-OmniDiagReport -Redact can run. When not, the redaction option is shown
        disabled with an explanatory tooltip.
    #>
    param(
        [Parameter(Mandatory)] $Owner,
        [bool] $RedactSupported
    )

    $dlg = [System.Windows.Window]::new()
    $dlg.Title = 'Export Reports'
    $dlg.SizeToContent = 'WidthAndHeight'
    $dlg.ResizeMode = 'NoResize'
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Owner = $Owner
    $dlg.MinWidth = 440
    $dlg.ShowInTaskbar = $false
    foreach ($key in (Get-OmniThemePalette -Name Light).Keys) {
        if ($Owner.Resources.Contains($key)) { $dlg.Resources[$key] = $Owner.Resources[$key] }
    }
    $dlg.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'BrushPanel')
    [System.Windows.Automation.AutomationProperties]::SetName($dlg, 'Export reports')

    $root = [System.Windows.Controls.StackPanel]::new()
    $root.Margin = '20'

    $text = {
        param([string] $Value, [string] $Brush, [int] $Size = 13)
        $t = [System.Windows.Controls.TextBlock]::new()
        $t.Text = $Value
        $t.TextWrapping = 'Wrap'
        $t.MaxWidth = 400
        $t.FontSize = $Size
        $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Brush)
        $t
    }

    $header = & $text 'Select the report formats to export' 'BrushText' 15
    $header.FontWeight = 'Bold'
    $header.Margin = '0,0,0,10'
    [void]$root.Children.Add($header)

    $notice = & $text ('Reports are generated and stored locally - nothing is uploaded. They may ' +
                       'contain usernames, device names, file paths, and domains. Review before sharing.') 'BrushMuted'
    $notice.Margin = '0,0,0,14'
    [void]$root.Children.Add($notice)

    # Ordered so the checkboxes (and the returned list) keep a sensible order.
    # Defaults mirror the CLI's default report set (Html, Json, Csv).
    $formats = [ordered]@{
        Html = @{ On = $true;  Label = '_HTML - rich, self-contained report' }
        Json = @{ On = $true;  Label = '_JSON - full structured report (for automation)' }
        Csv  = @{ On = $true;  Label = '_CSV - findings and event tables' }
        Md   = @{ On = $false; Label = '_Markdown - summary for tickets and chat' }
        Pdf  = @{ On = $false; Label = '_PDF - print-ready (native, no browser needed)' }
        Zip  = @{ On = $false; Label = '_Bundle (.zip) - HTML, PDF, JSON, CSV, and log in one file' }
    }
    $checkboxes = [ordered]@{}
    foreach ($fmt in $formats.Keys) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        $cb.Content = $formats[$fmt].Label
        $cb.IsChecked = $formats[$fmt].On
        $cb.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'BrushText')
        $cb.FontSize = 13
        $cb.Margin = '2,5,2,5'
        [System.Windows.Automation.AutomationProperties]::SetName($cb, ($formats[$fmt].Label -replace '_', ''))
        [void]$root.Children.Add($cb)
        $checkboxes[$fmt] = $cb
    }

    $sep = [System.Windows.Controls.Separator]::new()
    $sep.Margin = '0,10,0,6'
    [void]$root.Children.Add($sep)

    $chkRedact = [System.Windows.Controls.CheckBox]::new()
    $chkRedact.Content = '_Redact identifiers for sharing'
    $chkRedact.IsChecked = $false
    $chkRedact.Margin = '2,5,2,2'
    $chkRedact.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'BrushText')
    [System.Windows.Automation.AutomationProperties]::SetName($chkRedact, 'Redact identifiers for sharing')
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($chkRedact, $true)
    if ($RedactSupported) {
        $redactHelp = 'Replaces host names, user names, domains, SIDs, profile paths, and IP/MAC addresses with stable pseudonyms in every format.'
        $chkRedact.ToolTip = $redactHelp
    } else {
        $redactHelp = 'Not available in this build: the report exporter does not support redaction (Export-OmniDiagReport -Redact).'
        $chkRedact.IsEnabled = $false
        $chkRedact.ToolTip = $redactHelp
    }
    [System.Windows.Automation.AutomationProperties]::SetHelpText($chkRedact, $redactHelp)
    [void]$root.Children.Add($chkRedact)
    $redactNote = & $text $redactHelp 'BrushMuted' 12
    $redactNote.Margin = '22,0,0,0'
    [void]$root.Children.Add($redactNote)

    $btnRow = [System.Windows.Controls.StackPanel]::new()
    $btnRow.Orientation = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Right'
    $btnRow.Margin = '0,18,0,0'

    $btnCancel = [System.Windows.Controls.Button]::new()
    $btnCancel.Content = 'Cancel'
    $btnCancel.MinWidth = 90
    $btnCancel.Padding = '10,5'
    $btnCancel.Margin = '0,0,8,0'
    $btnCancel.IsCancel = $true
    [System.Windows.Automation.AutomationProperties]::SetName($btnCancel, 'Cancel export')

    $btnExport = [System.Windows.Controls.Button]::new()
    $btnExport.Content = '_Export'
    $btnExport.MinWidth = 90
    $btnExport.Padding = '10,5'
    $btnExport.IsDefault = $true
    [System.Windows.Automation.AutomationProperties]::SetName($btnExport, 'Export')
    # Setting DialogResult on a Window closes it. Only proceed if at least one format
    # is checked; the handler reads $checkboxes/$dlg from this still-live function
    # scope (ShowDialog blocks here while the handler runs).
    $btnExport.Add_Click({
        $anyChecked = $false
        foreach ($name in $checkboxes.Keys) { if ($checkboxes[$name].IsChecked) { $anyChecked = $true; break } }
        if (-not $anyChecked) {
            [System.Windows.MessageBox]::Show('Select at least one format to export.', 'OmniDiag', 'OK', 'Warning') | Out-Null
            return
        }
        $dlg.DialogResult = $true
    })

    [void]$btnRow.Children.Add($btnCancel)
    [void]$btnRow.Children.Add($btnExport)
    [void]$root.Children.Add($btnRow)

    $dlg.Content = $root
    [System.Windows.Input.FocusManager]::SetFocusedElement($dlg, $checkboxes['Html'])

    if ($dlg.ShowDialog() -ne $true) { return $null }
    $selected = @(foreach ($fmt in $checkboxes.Keys) { if ($checkboxes[$fmt].IsChecked) { $fmt } })
    if ($selected.Count -eq 0) { return $null }
    return [pscustomobject]@{
        Formats = [string[]]$selected
        Redact  = [bool]($RedactSupported -and $chkRedact.IsChecked -eq $true)
    }
}

# Background script: write the reports (never on the UI thread).
$script:OmniExportScript = {
    param($SyncHash, $A)
    $p = @{ Session = $A.Session; OutputDirectory = (Get-OmniDataPath -Kind Reports); Format = [string[]]$A.Formats }
    if ($A.Redact) { $p.Redact = $true }
    $set = Export-OmniDiagReport @p
    [pscustomobject]@{
        OutputDirectory = [string]$set.OutputDirectory
        Files           = [string[]]@($set.Files)
        Warnings        = [string[]]@($set.Warnings)
    }
}

function Invoke-OmniExportRequest {
    <# .SYNOPSIS Internal: Export button / Ctrl+E - pick formats, then export in the background. #>
    $ui = $script:OmniUi
    if (-not $ui.Session -or (Test-OmniUiBusy)) { return }
    $choice = Show-OmniExportDialog -Owner $ui.Window -RedactSupported (Test-OmniRedactSupported)
    if (-not $choice) { return }
    if (Test-OmniUiBusy) { return }

    $formats = [string[]]$choice.Formats
    $ui.Export = Invoke-OmniUiTask -Name 'Export' -Script $script:OmniExportScript `
        -Arguments @{ Session = $ui.Session; Formats = $formats; Redact = [bool]$choice.Redact } `
        -Context @{ Formats = $formats; Redact = [bool]$choice.Redact } `
        -OnComplete { param($Sync, $Ctx) Complete-OmniExport -Sync $Sync -Context $Ctx }
    Sync-OmniBusyState
    $ui.Controls.ProgressBarMain.IsIndeterminate = $true
    $redactNote = if ($choice.Redact) { ' (redacted)' } else { '' }
    Write-OmniStatus -Text "Exporting $($formats -join ', ')$redactNote..." -Announce
}

function Complete-OmniExport {
    <# .SYNOPSIS Internal: export finished - report, then open the folder. #>
    param([Parameter(Mandatory)] $Sync, [Parameter(Mandatory)] [hashtable] $Context)
    $ui = $script:OmniUi
    $ui.Export = $null
    $ui.Controls.ProgressBarMain.IsIndeterminate = $false
    Sync-OmniBusyState
    if ($Sync.Error) {
        Write-OmniStatus -Text "Export failed: $($Sync.Error)" -Announce
        [System.Windows.MessageBox]::Show("Export failed: $($Sync.Error)", 'OmniDiag', 'OK', 'Error') | Out-Null
        return
    }
    $set = $Sync.Result
    $ui.Controls.ProgressBarMain.Value = 100
    Write-OmniStatus -Text "Reports written to $($set.OutputDirectory)" -Announce
    $dialog = "Exported: $($Context.Formats -join ', ')"
    if ($Context.Redact) { $dialog += ' (identifiers redacted)' }
    $dialog += "`n`nReports written to:`n$($set.OutputDirectory)"
    if (@($set.Warnings).Count -gt 0) { $dialog += "`n`n" + (@($set.Warnings) -join "`n") }
    [System.Windows.MessageBox]::Show($dialog, 'OmniDiag', 'OK', 'Information') | Out-Null
    try { Invoke-Item -LiteralPath $set.OutputDirectory } catch { $null = $_ }
}

# ---------------------------------------------------------------------------
# Local AI
# ---------------------------------------------------------------------------

function Format-OmniAiAnalysis {
    <# .SYNOPSIS Internal: format structured Ollama guidance for the read-only GUI panel. #>
    param([Parameter(Mandatory)] [pscustomobject] $Analysis)

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("LOCAL AI ANALYSIS  |  $($Analysis.Model)  |  $($Analysis.EvidenceCount) finding(s)")
    [void]$lines.Add('')
    [void]$lines.Add('SUMMARY')
    [void]$lines.Add([string]$Analysis.Summary)

    if (@($Analysis.Priorities).Count -gt 0) {
        [void]$lines.Add(''); [void]$lines.Add('PRIORITIES')
        foreach ($item in @($Analysis.Priorities)) {
            [void]$lines.Add("- [$($item.urgency)] $($item.title)")
            [void]$lines.Add("  Evidence: $(@($item.evidenceIds) -join ', ')")
        }
    }
    if (@($Analysis.Correlations).Count -gt 0) {
        [void]$lines.Add(''); [void]$lines.Add('CORRELATIONS')
        foreach ($item in @($Analysis.Correlations)) {
            [void]$lines.Add("- $($item.hypothesis) (confidence: $($item.confidence)%)")
            [void]$lines.Add("  Evidence: $(@($item.evidenceIds) -join ', ')")
        }
    }
    if (@($Analysis.NextSteps).Count -gt 0) {
        [void]$lines.Add(''); [void]$lines.Add('NEXT DIAGNOSTIC STEPS')
        foreach ($item in @($Analysis.NextSteps)) {
            $approval = if ($item.requiresApproval) { ' [APPROVAL REQUIRED]' } else { '' }
            [void]$lines.Add("- $($item.step)$approval")
            [void]$lines.Add("  Evidence: $(@($item.evidenceIds) -join ', ')")
        }
    }
    if (@($Analysis.Limitations).Count -gt 0) {
        [void]$lines.Add(''); [void]$lines.Add('LIMITATIONS')
        foreach ($item in @($Analysis.Limitations)) { [void]$lines.Add("- $item") }
    }
    if ($Analysis.PSObject.Properties['UnverifiedCitations'] -and @($Analysis.UnverifiedCitations).Count -gt 0) {
        [void]$lines.Add(''); [void]$lines.Add("UNVERIFIED CITATIONS IGNORED: $(@($Analysis.UnverifiedCitations) -join ', ')")
    }
    [void]$lines.Add('')
    # Always shown: the model's requiresApproval flag can add a label but can't remove this one.
    [void]$lines.Add("Advisory only: get approval before changing the device, and verify guidance against the cited findings and your organization's runbooks.")
    return ($lines -join [Environment]::NewLine)
}

function Start-OmniAiOperation {
    <# .SYNOPSIS Internal: check Ollama or analyze the latest session off the UI thread. #>
    param([Parameter(Mandatory)] [ValidateSet('Status', 'Analyze')] [string] $Mode)

    $ui = $script:OmniUi
    if (Test-OmniUiBusy) { return }

    $model = ([string]$ui.Controls.CmbAiModel.Text).Trim()
    $endpoint = ([string]$ui.Controls.TxtAiEndpoint.Text).Trim()
    $question = ([string]$ui.Controls.TxtAiQuestion.Text).Trim()
    if (-not $model -or -not $endpoint) {
        [System.Windows.MessageBox]::Show('Enter an Ollama model and local endpoint.', 'OmniDiag Local AI', 'OK', 'Warning') | Out-Null
        return
    }
    if ($Mode -eq 'Analyze' -and -not $ui.Session) {
        [System.Windows.MessageBox]::Show('Run a diagnostic scan before requesting AI analysis.', 'OmniDiag Local AI', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $question) { $question = 'What are the most likely root causes and safest next diagnostic steps?' }

    $sync = [hashtable]::Synchronized(@{ Done = $false; Result = $null; Error = $null })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $bg = {
        param($SyncHash, $Operation, $Manifest, $Session, $Model, $Endpoint, $Question)
        try {
            Import-Module $Manifest -Force -DisableNameChecking
            $SyncHash.Result = if ($Operation -eq 'Status') {
                Test-OmniOllama -Model $Model -Endpoint $Endpoint
            } else {
                Invoke-OmniOllamaAnalysis -Session $Session -Question $Question -Model $Model -Endpoint $Endpoint
            }
        } catch {
            $SyncHash.Error = $_.Exception.Message
        } finally {
            $SyncHash.Done = $true
        }
    }
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($bg).AddParameters(@{
        SyncHash = $sync; Operation = $Mode; Manifest = $ui.Manifest; Session = $ui.Session
        Model = $model; Endpoint = $endpoint; Question = $question
    })
    $handle = $ps.BeginInvoke()

    $ui.AiJob = @{ Sync = $sync; PowerShell = $ps; Runspace = $rs; Handle = $handle; Mode = $Mode; Model = $model }
    Sync-OmniBusyState
    $ui.Controls.ProgressBarMain.IsIndeterminate = $true
    $ui.Controls.TxtAiStatus.Text = if ($Mode -eq 'Status') { 'Checking local Ollama...' } else { "Analyzing with $model..." }
    Write-OmniStatus -Text $ui.Controls.TxtAiStatus.Text -Announce
    if ($Mode -eq 'Analyze') { $ui.Controls.TxtAiOutput.Text = 'Generating evidence-grounded guidance...' }
    $ui.AiTimer.Start()
}

function Invoke-OmniAiPoll {
    <# .SYNOPSIS Internal: Local AI timer tick. #>
    $ui = $script:OmniUi
    $job = $ui.AiJob
    if (-not $job -or -not $job.Sync.Done) { return }

    $ui.AiTimer.Stop()
    try { $job.PowerShell.EndInvoke($job.Handle) } catch { $null = $_ }
    $job.PowerShell.Dispose(); $job.Runspace.Dispose()
    $ui.AiJob = $null
    $ui.Controls.ProgressBarMain.IsIndeterminate = $false
    Sync-OmniBusyState

    if ($job.Sync.Error) {
        $ui.Controls.TxtAiStatus.Text = "Local AI error: $($job.Sync.Error)"
        $ui.Controls.TxtAiOutput.Text = "Unable to complete local AI operation.`r`n`r`n$($job.Sync.Error)"
        Write-OmniStatus -Text 'Local AI operation failed.' -Announce
        return
    }

    if ($job.Mode -eq 'Status') {
        $status = $job.Sync.Result
        if (-not $status.Available) {
            $message = "Ollama is not available at $($status.Endpoint). Start Ollama and try again. $($status.Error)"
        } elseif (-not $status.ModelPresent) {
            $message = "Ollama is connected, but '$($status.Model)' is not installed. Run: ollama pull $($status.Model)"
        } else {
            $message = "Ollama is connected and '$($status.Model)' is ready."
        }
        $ui.Controls.TxtAiStatus.Text = $message
        $models = @($status.Models)
        $ui.Controls.TxtAiOutput.Text = $message + $(if ($models.Count -gt 0) { "`r`n`r`nInstalled models:`r`n- " + ($models -join "`r`n- ") } else { '' })
        Write-OmniStatus -Text 'Ollama check complete.' -Announce
    } else {
        $ui.Controls.TxtAiOutput.Text = Format-OmniAiAnalysis -Analysis $job.Sync.Result
        $ui.Controls.TxtAiStatus.Text = "Analysis complete using $($job.Model)."
        Write-OmniStatus -Text 'Local AI analysis complete.' -Announce
    }
}

# ---------------------------------------------------------------------------
# Repairs
# ---------------------------------------------------------------------------

function Invoke-OmniRepairRequest {
    <# .SYNOPSIS Internal: Run Selected - confirm, then run repairs in a background runspace. #>
    $ui = $script:OmniUi
    if (Test-OmniUiBusy) { return }

    $rows = @($ui.Controls.RepairGrid.ItemsSource | Where-Object { $_ -and $_.Selected })
    if ($rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Select at least one repair to run.', 'OmniDiag Repair', 'OK', 'Information') | Out-Null
        return
    }
    $names = @($rows | ForEach-Object { $_.Name })
    $dryRun = [bool]$ui.Controls.ChkRepairDryRun.IsChecked

    # Single summary confirmation.
    $list = ($rows | ForEach-Object { "  - $($_.Name)  [$($_.Risk)]" }) -join "`n"
    $msg = "About to run $($rows.Count) repair(s):`n`n$list"
    if (-not $dryRun -and @($rows | Where-Object { $_.RestorePoint }).Count -gt 0) {
        $msg += "`n`nA System Restore point will be created first; repairs that need one are skipped if it can't be."
    }
    if (@($rows | Where-Object { $_.Reboot }).Count -gt 0) {
        $msg += "`n`nOne or more repairs will require a reboot to fully apply."
    }
    $msg += if ($dryRun) { "`n`nDRY RUN: nothing will be changed.`n`nProceed?" } else { "`n`nProceed?" }
    if ([System.Windows.MessageBox]::Show($msg, 'OmniDiag Repair - Confirm', 'YesNo', 'Warning') -ne 'Yes') { return }
    if (Test-OmniUiBusy) { return }

    $sync = [hashtable]::Synchronized(@{ Progress = 0; Current = ''; Done = $false; Session = $null; Error = $null })
    $cts = [System.Threading.CancellationTokenSource]::new()

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $bg = {
        param($SyncHash, $Token, $Names, $DryRun, $Manifest, $RepairsPath)
        try {
            Import-Module $Manifest -Force -DisableNameChecking
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $logPath = Get-OmniDataPath -Kind Logs -ChildPath "omnidiag-repair-$stamp.jsonl"
            $log = New-OmniLogger -Path $logPath -MinimumLevel Info -Console:$false
            # Re-discover in THIS runspace: registration PSModuleInfo objects are
            # runspace-affine, so we pass repair Names across the boundary, not objects.
            $all = @(Get-OmniRepair -Path $RepairsPath -Logger $log)
            $chosen = @($all | Where-Object { $Names -contains $_.Name })
            $cb = {
                param($p)
                $SyncHash.Current = $p.Name
                $SyncHash.Progress = $p.PercentComplete
            }.GetNewClosure()
            $ctx = New-OmniRepairContext -Logger $log -DryRun:$DryRun -CancellationToken $Token
            # The engine entry, not Invoke-OmniDiagRepair: the GUI needs the progress
            # callback and a dry run driven by the checkbox (not -WhatIf), and it has
            # already confirmed the whole selection in its own dialog.
            $SyncHash.Session = Invoke-OmniRepairRun -Registration $chosen -Context $ctx -ProgressCallback $cb
        } catch {
            $SyncHash.Error = $_.Exception.Message
        } finally {
            $SyncHash.Done = $true
        }
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($bg).AddParameters(@{
        SyncHash = $sync; Token = $cts.Token; Names = $names; DryRun = $dryRun
        Manifest = $ui.Manifest; RepairsPath = $ui.RepairsPath
    })
    $handle = $ps.BeginInvoke()

    $ui.Repair = @{ Sync = $sync; Cts = $cts; PowerShell = $ps; Runspace = $rs; Handle = $handle; Cancelling = $false }
    $ui.Controls.RepairResultGrid.ItemsSource = @()
    $ui.Controls.TxtRepairBanner.Text = ''
    Sync-OmniBusyState
    $ui.Controls.ProgressBarMain.IsIndeterminate = $false
    $ui.Controls.ProgressBarMain.Value = 0
    Write-OmniStatus -Text $(if ($dryRun) { 'Starting repairs (dry run)...' } else { 'Starting repairs...' }) -Announce
    $ui.RepairTimer.Start()
}

function Invoke-OmniRepairPoll {
    <# .SYNOPSIS Internal: repair timer tick. #>
    $ui = $script:OmniUi
    $job = $ui.Repair
    if (-not $job) { return }
    $sync = $job.Sync
    $ui.Controls.ProgressBarMain.Value = [double]$sync.Progress
    if (-not $job.Cancelling) {
        Write-OmniStatus -Text $(if ($sync.Current) { "Repairing: $($sync.Current)" } else { 'Working...' })
    }
    if (-not $sync.Done) { return }

    $ui.RepairTimer.Stop()
    try { $job.PowerShell.EndInvoke($job.Handle) } catch { $null = $_ }
    $job.PowerShell.Dispose(); $job.Runspace.Dispose(); $job.Cts.Dispose()
    $ui.Repair = $null

    if ($sync.Error) {
        Write-OmniStatus -Text "Repairs failed: $($sync.Error)" -Announce
        $ui.Controls.TxtRepairBanner.Text = "Error: $($sync.Error)"
    } else {
        $rs = $sync.Session
        $ui.Controls.RepairResultGrid.ItemsSource = @($rs.Results | ForEach-Object {
            $failed = @($_.Steps | Where-Object { -not $_.Succeeded })
            $detail = if ($_.Error) { $_.Error }
                      elseif ($failed.Count -gt 0) { $failed[0].Description }
                      else { "$($_.Steps.Count) step(s) ok" }
            [pscustomobject]@{ Name = $_.Name; Status = $_.Status; Detail = $detail; A11yName = "$($_.Name): $($_.Status). $detail" }
        })
        $banner = ''
        if ($rs.DryRun) { $banner += 'Dry run complete - no changes were made. ' }
        if ($rs.RestorePoint) { $banner += "Restore point: $($rs.RestorePoint.Status). " }
        if ($rs.RebootRequired) { $banner += 'A RESTART is required to finish applying one or more repairs.' }
        $ui.Controls.TxtRepairBanner.Text = $banner
        Write-OmniStatus -Text "Repairs complete. $banner" -Announce
    }
    $ui.Controls.ProgressBarMain.Value = 100
    Sync-OmniBusyState
}

# ---------------------------------------------------------------------------
# Navigation and keyboard
# ---------------------------------------------------------------------------

function Select-OmniNavSection {
    <# .SYNOPSIS Internal: switch to section Index (0-based) and focus its navigation item. #>
    param([Parameter(Mandatory)] [int] $Index, [switch] $NoFocus)
    $ui = $script:OmniUi
    $nav = $ui.Controls.NavList
    if ($Index -lt 0 -or $Index -ge $nav.Items.Count) { return }
    $nav.SelectedIndex = $Index
    if ($NoFocus) { return }
    $item = $nav.ItemContainerGenerator.ContainerFromIndex($Index)
    if ($item) { [void]$item.Focus() }
}

function Show-OmniNavPanel {
    <# .SYNOPSIS Internal: NavList selection changed - load the section on first visit, then show its panel. #>
    $ui = $script:OmniUi
    $sel = $ui.Controls.NavList.SelectedItem
    if (-not $sel) { return }
    $panelName = [string]$sel.Tag
    $section = Get-OmniSectionForHost -HostName $panelName
    if ($section -and -not (Test-OmniSectionLoaded -Name $section)) {
        # Parsed while its host is still collapsed, so it is laid out once, when shown.
        try {
            [void](Import-OmniSection -Name $section)
        } catch {
            Write-OmniStatus -Text "Could not load the $($sel.Content) section: $($_.Exception.Message)" -Announce
        }
    }
    foreach ($p in $script:OmniNavPanels) {
        $ui.Controls[$p].Visibility = if ($p -eq $panelName) { 'Visible' } else { 'Collapsed' }
    }
    if ($panelName -eq 'PanelDiagnostics') { Initialize-OmniDiagPanel }
}

function Get-OmniShortcutHelpText {
    <# .SYNOPSIS Internal: the keyboard reference as plain text. #>
    [OutputType([string])]
    param()
    $lines = @('Keyboard shortcuts', '')
    foreach ($s in $script:OmniShortcutHelp) { $lines += ('{0,-24} {1}' -f $s.Keys, $s.Action) }
    $lines += ''
    $lines += 'High contrast: OmniDiag follows the Windows high-contrast setting automatically.'
    return ($lines -join [Environment]::NewLine)
}

function Show-OmniShortcutHelp {
    <# .SYNOPSIS Internal: F1 / Help button. #>
    [System.Windows.MessageBox]::Show((Get-OmniShortcutHelpText), 'OmniDiag - Keyboard shortcuts', 'OK', 'Information') | Out-Null
}

function Invoke-OmniShortcut {
    <# .SYNOPSIS Internal: dispatch a window KeyBinding (CommandParameter) to its action. #>
    param([AllowEmptyString()] [string] $Action)
    $ui = $script:OmniUi
    # The KeyBindings arrive with the shell, but a shortcut can still race the swap.
    if (-not $ui -or -not $ui.ShellReady) { return }
    switch -Regex ($Action) {
        '^Scan$'   { if ($ui.Controls.BtnScan.IsEnabled) { Invoke-OmniScanRequest } }
        '^Cancel$' { Request-OmniCancel }
        '^Export$' { if ($ui.Controls.BtnExport.IsEnabled) { Invoke-OmniExportRequest } else { Write-OmniStatus -Text 'Nothing to export yet: run a scan first (F5).' -Announce } }
        '^Find$'   {
            # Navigating loads the All Findings section (first time) synchronously.
            Select-OmniNavSection -Index ([Array]::IndexOf([string[]]$script:OmniNavPanels, 'PanelFindings')) -NoFocus
            if (Test-OmniSectionLoaded -Name 'Findings') {
                $ui.Window.UpdateLayout()
                [void]$ui.Controls.TxtFindingFilter.Focus()
                $ui.Controls.TxtFindingFilter.SelectAll()
            }
        }
        '^Theme$'  { Invoke-OmniThemeToggle }
        '^Help$'   { Show-OmniShortcutHelp }
        '^Nav(\d)$' { Select-OmniNavSection -Index ([int]$Matches[1] - 1) }
    }
}

# ---------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------

function Initialize-OmniSection {
    <#
    .SYNOPSIS
        Internal: wire a section that Import-OmniSection just loaded (handlers, initial
        state). Its controls are in $ui.Controls by now.
    #>
    param([Parameter(Mandatory)] [string] $Name)
    $ui = $script:OmniUi
    $controls = $ui.Controls
    switch ($Name) {
        'DashboardModules' {
            if ($ui.Session) { $controls.GridModules.ItemsSource = @(Get-OmniModuleRow -Session $ui.Session -GroupNames $ui.GroupNames) }
        }

        'Groups' {
            $controls.BtnGroupOpen.Add_Click({ Open-OmniSelectedGroup })
            $controls.BtnGroupBack.Add_Click({ Hide-OmniGroupDetail })
            $controls.GridGroups.Add_PreviewKeyDown({
                param($eventSender, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $eventSender.SelectedItem) {
                    $e.Handled = $true
                    Open-OmniSelectedGroup
                }
            })
            $controls.GridGroups.Add_MouseDoubleClick({ Open-OmniSelectedGroup })
            $controls.GroupDetailView.Add_PreviewKeyDown({
                param($eventSender, $e)
                $isBack = ($e.Key -eq [System.Windows.Input.Key]::Back -and -not ($e.OriginalSource -is [System.Windows.Controls.Primitives.TextBoxBase])) -or
                          ($e.Key -eq [System.Windows.Input.Key]::System -and $e.SystemKey -eq [System.Windows.Input.Key]::Left)
                if ($isBack) { $e.Handled = $true; Hide-OmniGroupDetail }
            })
            $controls.GridGroupFindings.Add_SelectionChanged({
                $c = $script:OmniUi.Controls
                if ($c.GridGroupFindings.SelectedItem) { $c.TxtGroupFindingDetail.Text = Format-OmniFindingDetail -Row $c.GridGroupFindings.SelectedItem }
            })
            $controls.GridGroupFindings.Add_PreviewKeyDown({
                param($eventSender, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $eventSender.SelectedItem) {
                    $e.Handled = $true
                    Show-OmniFindingDetail -Grid $eventSender -Target $script:OmniUi.Controls.TxtGroupFindingDetail
                }
            })
            Show-OmniGroupSummary
        }

        'Findings' {
            $controls.TxtFindingFilter.Add_TextChanged({ Show-OmniFindingFilter })
            $controls.CmbSeverityFilter.Add_SelectionChanged({ Show-OmniFindingFilter })
            $controls.GridFindings.Add_SelectionChanged({
                $c = $script:OmniUi.Controls
                if ($c.GridFindings.SelectedItem) { $c.TxtFindingDetail.Text = Format-OmniFindingDetail -Row $c.GridFindings.SelectedItem }
            })
            $controls.GridFindings.Add_PreviewKeyDown({
                param($eventSender, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $eventSender.SelectedItem) {
                    $e.Handled = $true
                    Show-OmniFindingDetail -Grid $eventSender -Target $script:OmniUi.Controls.TxtFindingDetail
                }
            })
            $controls.GridFindings.Add_MouseDoubleClick({
                param($eventSender, $e)
                if ($eventSender.SelectedItem) { Show-OmniFindingDetail -Grid $eventSender -Target $script:OmniUi.Controls.TxtFindingDetail }
            })
            Show-OmniFindingFilter
        }

        'Diagnostics' {
            $controls.BtnDiagEnableAll.Add_Click({
                $ui = $script:OmniUi
                foreach ($r in @($ui.DiagRows)) { if ($r) { $r.Enabled = $true } }
                $ui.Controls.DiagGrid.Items.Refresh()
            })
            $controls.BtnDiagDisableAll.Add_Click({
                $ui = $script:OmniUi
                foreach ($r in @($ui.DiagRows)) { if ($r) { $r.Enabled = $false } }
                $ui.Controls.DiagGrid.Items.Refresh()
            })
            $controls.BtnDiagRunSelected.Add_Click({
                $ui = $script:OmniUi
                $row = $ui.Controls.DiagGrid.SelectedItem
                if (-not $row) {
                    [System.Windows.MessageBox]::Show('Select a scanner in the list first.', 'OmniDiag', 'OK', 'Information') | Out-Null
                    return
                }
                if (Test-OmniUiBusy) { return }
                Select-OmniNavSection -Index 0 -NoFocus    # show the Dashboard for results
                Start-OmniScan -IncludeModule @([string]$row.Name)
            })
            # A row's "Run" button runs just that one scanner; results land on the Dashboard.
            # The handler is attached at the grid level and filters to Button clicks (the
            # checkbox-toggle and column-header clicks are not [Button], so they're ignored).
            $controls.DiagGrid.AddHandler(
                [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
                [System.Windows.RoutedEventHandler] {
                    param($eventSender, $e)
                    $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
                    if (-not $btn -or -not $btn.Tag) { return }
                    if (Test-OmniUiBusy) { return }
                    Select-OmniNavSection -Index 0 -NoFocus    # show the Dashboard for results
                    Start-OmniScan -IncludeModule @([string]$btn.Tag)
                })
            # Rows come from the scanner catalog (Initialize-OmniDiagPanel, called by
            # Show-OmniNavPanel, or by the deferred startup when the catalog arrives).
        }

        'Repair' {
            $controls.BtnRepairRecommended.Add_Click({
                $ui = $script:OmniUi
                foreach ($r in @($ui.Controls.RepairGrid.ItemsSource)) { if ($r) { $r.Selected = [bool]$r.Recommended } }
                $ui.Controls.RepairGrid.Items.Refresh()
            })
            $controls.BtnRepairClear.Add_Click({
                $ui = $script:OmniUi
                foreach ($r in @($ui.Controls.RepairGrid.ItemsSource)) { if ($r) { $r.Selected = $false } }
                $ui.Controls.RepairGrid.Items.Refresh()
            })
            $controls.BtnRepairCancel.Add_Click({ Request-OmniRepairCancel })
            $controls.BtnRunRepairs.Add_Click({ Invoke-OmniRepairRequest })
            # The elevation check used to run at startup; it is only needed here.
            if (-not (Test-OmniIsAdministrator)) {
                $controls.TxtRepairAdminNote.Text =
                    'Not elevated: repairs marked "Yes" under Admin will be skipped - re-run OmniDiag elevated for the full set. ' +
                    $controls.TxtRepairAdminNote.Text
            }
            if (@($ui.RepairCatalog).Count -gt 0) { $controls.RepairGrid.ItemsSource = @($ui.RepairCatalog) }
        }

        'LocalAi' {
            $controls.BtnAiCheck.Add_Click({ Start-OmniAiOperation -Mode Status })
            $controls.BtnAiAnalyze.Add_Click({ Start-OmniAiOperation -Mode Analyze })
            # The editable model box's inner text field is what takes keyboard focus; give
            # it the combo box's name so screen readers (and UI Automation) announce it.
            try {
                $cmb = $controls.CmbAiModel
                [void]$cmb.ApplyTemplate()
                $edit = $cmb.Template.FindName('PART_EditableTextBox', $cmb)
                if ($edit) { [System.Windows.Automation.AutomationProperties]::SetName($edit, 'Ollama model') }
            } catch { $null = $_ }
        }
    }
}

function Write-OmniStartupLog {
    <# .SYNOPSIS Internal: log the first-render time and the startup phase breakdown. #>
    $ui = $script:OmniUi
    if (-not $ui.Logger -or $null -eq $ui.StartupMs) { return }
    $ms = $ui.StartupMs
    try {
        $ui.Logger.Log('Info', "GUI first render in $ms ms (target: under 2000 ms).", 'Gui', @{ StartupMs = $ms; TargetMs = 2000 })
        $phases = Format-OmniStartupTiming -Marks $ui.StartupTimings
        if ($phases) { $ui.Logger.Log('Info', "GUI startup phases (ms since entry): $phases", 'Gui', @{ StartupTimings = $ui.StartupTimings }) }
        if ($ms -gt 2000) { $ui.Logger.Log('Warn', "GUI first render took $ms ms, over the 2000 ms target.", 'Gui', @{ StartupMs = $ms }) }
        $ready = $ui.ShellReadyMs
        if ($null -ne $ready) {
            # First paint (the frame) and fully interactive (the shell) are different numbers.
            $ui.Logger.Log('Info', "GUI shell ready (interactive) in $ready ms (target: under 2000 ms).", 'Gui', @{ ShellReadyMs = $ready; TargetMs = 2000 })
            if ($ready -gt 2000) { $ui.Logger.Log('Warn', "GUI shell took $ready ms to become ready, over the 2000 ms target.", 'Gui', @{ ShellReadyMs = $ready }) }
        }
    } catch { $null = $_ }
}

function Invoke-OmniPostRenderSetup {
    <#
    .SYNOPSIS
        Internal: cheap UI-thread work that is not needed for first paint.

    .DESCRIPTION
        Queued at Background priority once the shell is ready (Complete-OmniShellReady,
        before the ApplicationIdle background task): open the GUI log and record the
        startup timing, set the help tooltip, register the group names, and load the
        Dashboard's Module Results grid.
    #>
    $ui = $script:OmniUi
    if (-not $ui -or $ui.Closed -or -not $ui.ShellReady -or $ui.PostRenderDone) { return }
    $ui.PostRenderDone = $true
    try {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $ui.Logger = New-OmniLogger -Path (Get-OmniDataPath -Kind Logs -ChildPath "omnidiag-gui-$stamp.jsonl") -MinimumLevel Info
    } catch { $ui.Logger = $null }
    Write-OmniStartupLog
    $ui.Controls.BtnHelp.ToolTip = Get-OmniShortcutHelpText
    Initialize-OmniGroupCatalog
    Show-OmniGroupSummary
    try {
        [void](Import-OmniSection -Name 'DashboardModules')
    } catch {
        Write-OmniStatus -Text "Could not load the module results: $($_.Exception.Message)"
    }
}

function Complete-OmniShellLoad {
    <#
    .SYNOPSIS
        Internal: parse the shell (MainWindow.xaml) and make it the frame window's Content.

    .DESCRIPTION
        Queued at Background priority from the frame's ContentRendered. The shell root is
        a Grid: its resources (shared styles; the frame already holds the theme brushes)
        and its KeyBindings move onto the window, its x:Names are looked up on the shell
        root (its own name scope), and the top bar and navigation handlers are wired.
        On a parse failure the frame stays up and says so; nothing else runs.
    #>
    $ui = $script:OmniUi
    if (-not $ui -or $ui.Closed -or $ui.ShellReady -or $ui.ShellRoot) { return }
    $window = $ui.Window
    $clock = $ui.StartupClock
    try {
        # Diagnostic split of the parse cost: a trivial fragment first measures the XAML
        # engine's cold start (type system, theme lookups), separate from the shell's own size.
        $null = [System.Windows.Markup.XamlReader]::Parse('<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"/>')
        Add-OmniStartupMark -Name 'XamlEngineReady' -Clock $clock

        # Parse the cached shell text directly (no XmlDocument round trip; the XAML has no
        # inline text runs, so whitespace handling is the same).
        $root = [System.Windows.Markup.XamlReader]::Parse((Get-OmniMainWindowXaml))
        Add-OmniStartupMark -Name 'ShellParsed' -Clock $clock
        # Everything the shell needs is parsed now (kept for continuity with older logs).
        Add-OmniStartupMark -Name 'XamlParsed' -Clock $clock

        # Shell resources -> window (keys the window already has, i.e. theme brushes, win),
        # so implicit styles and DynamicResource lookups resolve from the window.
        $shellResources = $root.Resources
        foreach ($key in @($shellResources.Keys)) {
            if (-not $window.Resources.Contains($key)) { $window.Resources[$key] = $shellResources[$key] }
        }
        $shellResources.Clear()
        # KeyBindings -> window, so shortcuts work wherever focus is.
        $bindings = @($root.InputBindings)
        $root.InputBindings.Clear()
        foreach ($b in $bindings) { [void]$window.InputBindings.Add($b) }

        $controls = $ui.Controls
        foreach ($n in $script:OmniShellControlNames) { $controls[$n] = $root.FindName($n) }
        foreach ($n in $script:OmniLiveRegionControls) { if ($controls[$n]) { [void](Enable-OmniLiveRegion -Element $controls[$n]) } }

        # --- Top bar ---------------------------------------------------------
        $controls.BtnScan.Add_Click({ Invoke-OmniScanRequest })
        $controls.BtnCancel.Add_Click({ Request-OmniScanCancel })
        $controls.BtnExport.Add_Click({ Invoke-OmniExportRequest })
        $controls.BtnTheme.Add_Click({ Invoke-OmniThemeToggle })
        $controls.BtnHelp.Add_Click({ Show-OmniShortcutHelp })

        # --- Navigation (loads a section on its first visit) -------------------
        # Section handlers are wired by Initialize-OmniSection when each section loads.
        $controls.NavList.Add_SelectionChanged({ Show-OmniNavPanel })

        $ui.ShellRoot = $root
        $window.Content = $root
        $ui.ShellReady = $true
        Sync-OmniEffectiveTheme
        Sync-OmniBusyState
        [System.Windows.Input.FocusManager]::SetFocusedElement($window, $controls.BtnScan)
        if ($window.IsActive) { [void]$controls.BtnScan.Focus() }
    } catch {
        if (-not $ui.ShellReady) {
            $ui.ShellError = $_.Exception.Message
            $ui.FrameStatus.Text = "OmniDiag could not load its window: $($ui.ShellError)"
            [System.Windows.Automation.AutomationProperties]::SetName($ui.FrameStatus, $ui.FrameStatus.Text)
            Invoke-OmniLiveRegion -Element $ui.FrameStatus
            return
        }
        # The shell is already in place; only a post-swap step failed. Carry on.
        Write-OmniStatus -Text "Startup warning: $($_.Exception.Message)"
    }
    # Rendering runs above Background priority, so this lands after the shell's first frame.
    [void]$window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action] { Complete-OmniShellReady })
}

function Complete-OmniShellReady {
    <#
    .SYNOPSIS
        Internal: the shell is in place and rendered - record ShellReady, then queue the
        post-render setup and the background startup work.

    .DESCRIPTION
        ShellReadyMs is the "fully interactive" number; StartupMs stays the first paint of
        the frame. Test hooks (no effect unless set): OMNIDIAG_GUI_STARTUP_FILE=<path>
        writes the startup timings there as JSON; OMNIDIAG_GUI_EXIT_AFTER_RENDER=1 closes
        the window once the shell is ready (used by build/Measure-GuiStartup.ps1).
    #>
    $ui = $script:OmniUi
    if (-not $ui -or $ui.Closed -or $null -ne $ui.ShellReadyMs) { return }
    $ms = -1
    if ($ui.StartupClock) {
        Add-OmniStartupMark -Name 'ShellReady' -Clock $ui.StartupClock
        $ms = [int]$ui.StartupClock.Elapsed.TotalMilliseconds
    }
    $ui.ShellReadyUtc = [DateTime]::UtcNow
    $ui.ShellReadyMs = $ms
    try { [System.Windows.Automation.AutomationProperties]::SetItemStatus($ui.Window, "StartupMs=$($ui.StartupMs);ShellReadyMs=$ms") } catch { $null = $_ }
    if ($env:OMNIDIAG_GUI_STARTUP_FILE) { Write-OmniStartupFile -Path $env:OMNIDIAG_GUI_STARTUP_FILE }

    [void]$ui.Window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action] { Invoke-OmniPostRenderSetup })
    if (Test-OmniEnvFlag -Name 'OMNIDIAG_GUI_EXIT_AFTER_RENDER') {
        [void]$ui.Window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
            [Action] { try { $script:OmniUi.Window.Close() } catch { $null = $_ } })
        return
    }
    [void]$ui.Window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
        [Action] { Invoke-OmniDeferredStartup })
}

function Write-OmniStartupFile {
    <# .SYNOPSIS Internal: OMNIDIAG_GUI_STARTUP_FILE hook - the startup timings as JSON (UTF-8, no BOM). #>
    param([Parameter(Mandatory)] [string] $Path)
    $ui = $script:OmniUi
    try {
        $processStart = $null
        try { $processStart = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o') } catch { $processStart = $null }
        $marks = [ordered]@{}
        if ($ui.StartupTimings) { foreach ($k in @($ui.StartupTimings.Keys)) { $marks[[string]$k] = $ui.StartupTimings[$k] } }
        $doc = [ordered]@{
            StartupMs        = $ui.StartupMs
            ShellReadyMs     = $ui.ShellReadyMs
            ProcessStartUtc  = $processStart
            FramePaintedUtc  = $(if ($ui.FramePaintedUtc) { $ui.FramePaintedUtc.ToString('o') } else { $null })
            ShellReadyUtc    = $(if ($ui.ShellReadyUtc) { $ui.ShellReadyUtc.ToString('o') } else { $null })
            PSEdition        = [string]$PSVersionTable.PSEdition
            PSVersion        = [string]$PSVersionTable.PSVersion
            Marks            = $marks
        }
        [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    } catch { $null = $_ }
}

function Test-OmniEnvFlag {
    <# .SYNOPSIS Internal: is this environment variable set to something other than '', 0, or false? #>
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Name)
    $v = [string][Environment]::GetEnvironmentVariable($Name)
    return [bool]($v -and $v -notin @('0', 'false'))
}

function New-OmniFrameWindow {
    <#
    .SYNOPSIS
        Internal: the code-built frame window shown before any XAML is parsed.

    .DESCRIPTION
        No XAML parsing: a Window with the app's title, size, font, and accessibility
        properties, and a centered "OmniDiag" title plus a "Loading OmniDiag..." status
        (a polite live region with an AutomationProperties.Name). Its background and text
        use the theme brush keys, which Sync-OmniEffectiveTheme puts on the window (also
        in high contrast). The shell (MainWindow.xaml) replaces the Content once parsed.

    .OUTPUTS
        [pscustomobject] @{ Window; Status }
    #>
    $w = [System.Windows.Window]::new()
    $w.Title = 'OmniDiag - One Tool. Complete Diagnostics.'
    $w.Width = 1180; $w.Height = 760; $w.MinWidth = 900; $w.MinHeight = 560
    $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $w.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
    $w.FontSize = 13
    $w.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'BrushWindowBg')
    $w.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'BrushText')
    [System.Windows.Automation.AutomationProperties]::SetName($w, 'OmniDiag')
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($w, 'OmniDiagMainWindow')
    [System.Windows.Automation.AutomationProperties]::SetHelpText($w, 'Windows diagnostics. Press F1 for keyboard shortcuts.')

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $panel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $title = [System.Windows.Controls.TextBlock]::new()
    $title.Text = 'OmniDiag'
    $title.FontSize = 28
    $title.FontWeight = [System.Windows.FontWeights]::Bold
    $title.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $title.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'BrushText')
    $status = [System.Windows.Controls.TextBlock]::new()
    $status.Text = 'Loading OmniDiag...'
    $status.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $status.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'BrushMuted')
    [System.Windows.Automation.AutomationProperties]::SetName($status, 'Loading OmniDiag...')
    [void]$panel.Children.Add($title)
    [void]$panel.Children.Add($status)
    $grid = [System.Windows.Controls.Grid]::new()
    [void]$grid.Children.Add($panel)
    $w.Content = $grid
    [void](Enable-OmniLiveRegion -Element $status)
    return [pscustomobject]@{ Window = $w; Status = $status }
}

function Initialize-OmniMainWindow {
    <#
    .SYNOPSIS
        Internal: build the frame window, wire the window-level handlers, and return the
        (not yet shown) window. The shell XAML loads after the frame's first paint.

    .DESCRIPTION
        Separate from Invoke-OmniWindow so tests can show the window modelessly. Must run
        on an STA thread. No XAML is parsed here: the frame is built in code
        (New-OmniFrameWindow), so first paint does not wait for the XAML engine. After
        it: ContentRendered -> Background: Complete-OmniShellLoad (parse MainWindow.xaml,
        move its resources and KeyBindings onto the window, make it the Content) ->
        Background: Complete-OmniShellReady (ShellReady mark) -> Background:
        Invoke-OmniPostRenderSetup -> ApplicationIdle: Invoke-OmniDeferredStartup
        (background runspace). Every other section loads on first navigation.
    #>
    param(
        [string] $RootManifest, [string] $ModulesPath, [string] $RepairsPath,
        [ValidateSet('Dark', 'Light')] [string] $Theme = 'Light',
        [System.Diagnostics.Stopwatch] $StartupClock
    )

    Add-OmniStartupMark -Name 'InitializeStart' -Clock $StartupClock
    Disable-OmniLegacyAccessibility
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop
    Add-OmniStartupMark -Name 'WpfAssembliesLoaded' -Clock $StartupClock

    $frame = New-OmniFrameWindow
    $window = $frame.Window

    # Every control stays $null until the shell (or its section) loads.
    $controls = @{}
    foreach ($n in $script:OmniUiControlNames) { $controls[$n] = $null }

    # Shared GUI state (module scope so event handlers can reach it).
    $script:OmniUi = @{
        Window         = $window
        FrameStatus    = $frame.Status
        ShellRoot      = $null   # MainWindow.xaml root (a Grid), the window's Content once loaded
        ShellReady     = $false  # true once the shell is the Content and wired
        ShellError     = $null
        Closed         = $false
        Controls       = $controls
        Theme          = $Theme
        HighContrast   = $false
        Manifest       = $RootManifest
        ModulesPath    = $ModulesPath
        RepairsPath    = $RepairsPath
        Logger         = $null   # opened after the shell is ready (Invoke-OmniPostRenderSetup)
        StartupClock   = $StartupClock
        StartupMs      = $null   # first paint (the frame's ContentRendered)
        ShellReadyMs   = $null   # the shell is in place and rendered (fully interactive)
        FramePaintedUtc = $null
        ShellReadyUtc  = $null
        StartupTimings = $null   # phase -> ms (OrderedDictionary), set at first render
        StartupTask    = $null
        PostRenderDone = $false
        Sections       = @{}     # loaded section name -> fragment root
        SectionLoadMs  = @{}     # loaded section name -> load time (ms)
        SectionStylesLoaded = $false
        Scan           = $null
        Session        = $null
        Timer          = $null
        Repair         = $null
        RepairTimer    = $null
        AiJob          = $null
        AiTimer        = $null
        Export         = $null
        Tasks          = [System.Collections.ArrayList]::new()
        TaskTimer      = $null
        RepairCatalog  = @()
        DiagRows       = $null   # Diagnostics tab rows: { Enabled; Name; Category; Order; GroupName; Status }
        ScannerCatalog = $null
        GroupCatalog   = @()
        GroupNames     = @{}
        GroupRows      = @()
        SelectedGroupId = $null
        FindingRows    = @()
        ScoreGrade     = $null
        LastAnnounce   = [DateTime]::MinValue
        HighContrastHandler = $null
    }
    $ui = $script:OmniUi

    # The theme brushes (or the high-contrast SystemColors brushes) go on the frame now,
    # so the very first paint already has the right background.
    Sync-OmniEffectiveTheme

    # --- Timers (all on the UI thread) ---------------------------------
    $mkTimer = {
        param([int] $Ms, [scriptblock] $Tick)
        $t = [System.Windows.Threading.DispatcherTimer]::new()
        $t.Interval = [TimeSpan]::FromMilliseconds($Ms)
        $t.Add_Tick($Tick)
        $t
    }
    $ui.Timer       = & $mkTimer 200 { Invoke-OmniScanPoll }
    $ui.RepairTimer = & $mkTimer 200 { Invoke-OmniRepairPoll }
    $ui.AiTimer     = & $mkTimer 200 { Invoke-OmniAiPoll }
    $ui.TaskTimer   = & $mkTimer 150 { Invoke-OmniUiTaskPoll }

    # --- Keyboard shortcuts: one CommandBinding for the shell's KeyBindings --
    # The KeyBindings themselves arrive with the shell (Complete-OmniShellLoad moves them
    # onto this window); until then no shortcut exists, and Invoke-OmniShortcut ignores
    # anything that races the swap.
    $executed = [System.Windows.Input.ExecutedRoutedEventHandler] {
        param($eventSender, $e)
        $e.Handled = $true
        Invoke-OmniShortcut -Action ([string]$e.Parameter)
    }
    $canExecute = [System.Windows.Input.CanExecuteRoutedEventHandler] {
        param($eventSender, $e)
        $e.CanExecute = $true
        $e.Handled = $true
    }
    [void]$window.CommandBindings.Add([System.Windows.Input.CommandBinding]::new(
        [System.Windows.Input.NavigationCommands]::GoToPage, $executed, $canExecute))

    # --- High contrast: follow the Windows setting live --------------------
    # SystemParameters.StaticPropertyChanged fires (on this UI thread) when the setting
    # flips; Activated re-applies SystemColors in case the user switched between
    # high-contrast themes while away (that does not change the HighContrast flag).
    $hcHandler = [System.ComponentModel.PropertyChangedEventHandler] {
        param($eventSender, $e)
        if ($e.PropertyName -ne 'HighContrast') { return }
        Sync-OmniEffectiveTheme
        $state = if ($script:OmniUi.HighContrast) { 'on: using Windows high-contrast colors' } else { "off: $($script:OmniUi.Theme) theme" }
        Write-OmniStatus -Text "High contrast $state." -Announce
    }
    try {
        [System.Windows.SystemParameters]::add_StaticPropertyChanged($hcHandler)
        $ui.HighContrastHandler = $hcHandler
    } catch { $ui.HighContrastHandler = $null }
    $window.Add_Activated({
        $ui = $script:OmniUi
        if ($ui.HighContrast -or (Test-OmniHighContrast)) { Sync-OmniEffectiveTheme }
    })

    # --- First paint (the frame): measure it, then load the shell ------------
    $window.Add_ContentRendered({
        $ui = $script:OmniUi
        if ($null -ne $ui.StartupMs) { return }
        $ms = -1
        if ($ui.StartupClock) {
            Add-OmniStartupMark -Name 'ContentRendered' -Clock $ui.StartupClock
            Add-OmniStartupMark -Name 'FramePainted' -Clock $ui.StartupClock
            # The clock keeps running: the shell and section loads are marked on it afterwards.
            $ms = [int]$ui.StartupClock.Elapsed.TotalMilliseconds
        }
        $ui.FramePaintedUtc = [DateTime]::UtcNow
        $ui.StartupTimings = $script:OmniStartupMarks
        $ui.StartupMs = $ms
        # Hidden diagnostic: readable through UI Automation (ItemStatus) by tests and tools.
        try { [System.Windows.Automation.AutomationProperties]::SetItemStatus($ui.Window, "StartupMs=$ms") } catch { $null = $_ }
        # The shell parses at Background priority, after this frame is on screen.
        [void]$ui.Window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action] { Complete-OmniShellLoad })
    })

    # --- Clean up on close ----------------------------------------------
    $window.Add_Closing({
        param($eventSender, $e)
        $ui = $script:OmniUi
        if ($ui.Repair) {
            # Killing the repair pipeline mid-step could leave services stopped or a registry
            # cleanup half done. Request a cooperative cancel and keep the window open.
            try { $ui.Repair.Cts.Cancel(); $ui.Repair.Cancelling = $true } catch { $null = $_ }
            $e.Cancel = $true
            Write-OmniStatus -Text 'Stopping repairs after the current step... close the window again when they finish.' -Announce
            [System.Windows.MessageBox]::Show('A repair is running. OmniDiag will stop after the current step; close the window again when it finishes.', 'OmniDiag Repair', 'OK', 'Warning') | Out-Null
            return
        }
        if ($ui.Export) {
            $answer = [System.Windows.MessageBox]::Show('Reports are still being written. Close anyway? The export may be incomplete.', 'OmniDiag', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        }
        if ($ui.Scan) {
            try { $ui.Scan.Cts.Cancel() } catch { $null = $_ }
            try { $ui.Timer.Stop() } catch { $null = $_ }
            try { $ui.Scan.PowerShell.Dispose(); $ui.Scan.Runspace.Dispose() } catch { $null = $_ }
        }
        if ($ui.AiJob) {
            try { $ui.AiTimer.Stop() } catch { $null = $_ }
            try { $ui.AiJob.PowerShell.Stop() } catch { $null = $_ }
            try { $ui.AiJob.PowerShell.Dispose(); $ui.AiJob.Runspace.Dispose() } catch { $null = $_ }
        }
        try { $ui.TaskTimer.Stop() } catch { $null = $_ }
        foreach ($t in @($ui.Tasks)) {
            # Non-blocking: the worker finishes or stops on its own; nothing waits for it.
            try { [void]$t.PowerShell.BeginStop($null, $null) } catch { $null = $_ }
        }
    })
    $window.Add_Closed({
        $ui = $script:OmniUi
        # Queued shell / startup work checks this and does nothing after close.
        if ($ui) { $ui.Closed = $true }
        if ($ui -and $ui.HighContrastHandler) {
            try { [System.Windows.SystemParameters]::remove_StaticPropertyChanged($ui.HighContrastHandler) } catch { $null = $_ }
            $ui.HighContrastHandler = $null
        }
    })

    # The frame is ready to show; the shell and its controls come after first paint.
    Add-OmniStartupMark -Name 'WindowConstructed' -Clock $StartupClock
    return $window
}

function Invoke-OmniWindow {
    <# .SYNOPSIS Internal: build and show the window modally (must run on an STA thread). #>
    param([string] $RootManifest, [string] $ModulesPath, [string] $RepairsPath, [string] $Theme = 'Light')
    $clock = $script:OmniStartupClock
    if (-not $clock) { $clock = [System.Diagnostics.Stopwatch]::StartNew() }
    $window = Initialize-OmniMainWindow -RootManifest $RootManifest -ModulesPath $ModulesPath -RepairsPath $RepairsPath -Theme $Theme -StartupClock $clock
    Add-OmniStartupMark -Name 'ShowCalled' -Clock $clock
    [void]$window.ShowDialog()
}

function Start-OmniGuiWindow {
    <#
    .SYNOPSIS
        Internal: launches the OmniDiag GUI. Ensures an STA thread (hosting one when needed).

    .DESCRIPTION
        The implementation behind Show-OmniDiagGui (and the deprecated pre-1.0 GUI
        command, which Core/PublicApi.psm1 keeps as a wrapper). Opens the WPF window:
        Dashboard, Groups (per-group drill-down), All Findings (filter + details),
        Diagnostics, Repair Center, and Local AI. Press F1 in the window for keyboard
        shortcuts. The time from this call to the window's first render is logged
        (OmniDiagData\logs\omnidiag-gui-*.jsonl) and exposed as the window's UI
        Automation ItemStatus ("StartupMs=<n>").

    .PARAMETER RootManifest
        Path to OmniDiag.psd1. Defaults to the sibling module manifest.

    .PARAMETER ModulesPath
        Diagnostic module folder. Defaults to the sibling Modules folder.

    .PARAMETER RepairsPath
        Repair plugin folder. Defaults to the sibling Repairs folder.

    .PARAMETER Theme
        Initial theme: Light (default) or Dark. Ignored while Windows high contrast is on.

    .EXAMPLE
        Start-OmniGuiWindow -Theme Dark
    #>
    [CmdletBinding()]
    param(
        [string] $RootManifest = (Join-Path (Split-Path $script:OmniUiRoot -Parent) 'OmniDiag.psd1'),
        [string] $ModulesPath  = (Join-Path (Split-Path $script:OmniUiRoot -Parent) 'Modules'),
        [string] $RepairsPath  = (Join-Path (Split-Path $script:OmniUiRoot -Parent) 'Repairs'),
        [ValidateSet('Dark', 'Light')] [string] $Theme = 'Light'
    )

    # Startup clock: from here to first render. Kept when an outer MTA call handed one in
    # (together with the phase marks recorded so far).
    if (-not $script:OmniStartupClock) {
        $script:OmniStartupClock = [System.Diagnostics.Stopwatch]::StartNew()
        $script:OmniStartupMarks = $null
    }
    Add-OmniStartupMark -Name 'Entry'

    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apartment -eq 'STA') {
        try {
            Invoke-OmniWindow -RootManifest $RootManifest -ModulesPath $ModulesPath -RepairsPath $RepairsPath -Theme $Theme
        } finally {
            $script:OmniStartupClock = $null
            $script:OmniStartupMarks = $null
        }
        return
    }

    # MTA (e.g. PowerShell 7): host the window in a dedicated STA runspace.
    Write-Verbose 'Current thread is MTA; hosting the GUI in a dedicated STA runspace.'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    Add-OmniStartupMark -Name 'StaRunspaceReady'
    # Read the shell XAML here and hand it over, so the STA runspace does not read it again.
    $xamlText = $null
    try { $xamlText = Get-OmniMainWindowXaml } catch { $xamlText = $null }
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Manifest, $ModulesPath, $RepairsPath, $Theme, $Clock, $Marks, $XamlText)
        Import-Module $Manifest -Force -DisableNameChecking
        # Hand the caller's startup clock, phase marks, and XAML text to the GUI module in
        # this runspace.
        $root = Get-Module -Name OmniDiag | Select-Object -First 1
        $gui = $null
        if ($root) { $gui = @($root.NestedModules | Where-Object { $_.Name -eq 'OmniDiagGui' }) | Select-Object -First 1 }
        if ($gui -and $Clock) {
            & $gui {
                param($c, $m, $x)
                $script:OmniStartupClock = $c
                $script:OmniStartupMarks = $m
                if ($x) { $script:OmniXamlText = $x }
                Add-OmniStartupMark -Name 'ModuleImported'
            } $Clock $Marks $XamlText
        }
        Start-OmniGuiWindow -RootManifest $Manifest -ModulesPath $ModulesPath -RepairsPath $RepairsPath -Theme $Theme
    }).AddParameters(@{
        Manifest = $RootManifest; ModulesPath = $ModulesPath; RepairsPath = $RepairsPath; Theme = $Theme
        Clock = $script:OmniStartupClock; Marks = $script:OmniStartupMarks; XamlText = $xamlText
    })
    try {
        # The STA runspace imports OmniDiag (the slow part) while this thread loads the WPF
        # assemblies (they are process-wide), so the two overlap instead of adding up.
        $handle = $ps.BeginInvoke()
        Disable-OmniLegacyAccessibility
        try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop } catch { $null = $_ }
        Add-OmniStartupMark -Name 'WpfPreloaded'
        [void]$ps.EndInvoke($handle)   # blocks until the window closes; rethrows its errors
    } finally {
        $ps.Dispose(); $rs.Dispose()
        $script:OmniStartupClock = $null
        $script:OmniStartupMarks = $null
    }
}

Export-ModuleMember -Function @('Start-OmniGuiWindow', 'Set-OmniTheme', 'Get-OmniThemePalette')
