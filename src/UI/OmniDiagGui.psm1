<#
.SYNOPSIS
    OmniDiag WPF GUI (runtime-loaded XAML).

.DESCRIPTION
    Presents the dashboard and findings in a Fluent-style window with dark/light
    themes. The scan runs in a BACKGROUND RUNSPACE so the UI thread stays
    responsive and the Cancel button works; progress is surfaced through a
    thread-safe synchronized hashtable that a DispatcherTimer polls on the UI
    thread. Cancellation uses the same CancellationToken the engine has honored
    since Milestone 1.

    WPF requires an STA thread. Windows PowerShell 5.1 consoles are STA; PowerShell 7
    is MTA, so Show-OmniDiagWindow hosts the window in a dedicated STA runspace when
    needed. No display is created until the window is shown, so importing this module
    is safe on headless/Server Core hosts.

    Threading model:
        UI thread  ── BtnScan ──> spawn background runspace (Invoke-OmniDiag)
                   <── DispatcherTimer polls $sync (Progress/Phase/Done) ──
        Cancel     ── $cts.Cancel()  (engine checks the token between modules)
#>

Set-StrictMode -Version Latest

$script:OmniUiRoot = $PSScriptRoot

function Get-OmniThemePalette {
    [OutputType([hashtable])]
    param([ValidateSet('Dark', 'Light')] [string] $Name = 'Dark')
    if ($Name -eq 'Light') {
        return @{
            BrushWindowBg = '#F5F7FA'; BrushPanel = '#FFFFFF'; BrushPanel2 = '#EEF1F5'
            BrushText = '#1A1F24'; BrushMuted = '#5A6472'; BrushAccent = '#0969DA'; BrushLine = '#D5DBE2'
        }
    }
    return @{
        BrushWindowBg = '#0F1419'; BrushPanel = '#1A212B'; BrushPanel2 = '#212A36'
        BrushText = '#E6EDF3'; BrushMuted = '#8B98A5'; BrushAccent = '#4493F8'; BrushLine = '#2D3742'
    }
}

function Set-OmniTheme {
    param([Parameter(Mandatory)] $Window, [ValidateSet('Dark', 'Light')] [string] $Name = 'Dark')
    $palette = Get-OmniThemePalette -Name $Name
    foreach ($key in $palette.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
        $Window.Resources[$key] = [System.Windows.Media.SolidColorBrush]::new($color)
    }
}

function Get-OmniGradeColor {
    param([string] $Grade)
    switch ($Grade) {
        'Healthy'  { '#3FB950' }
        'Warning'  { '#F5C518' }
        'Critical' { '#FF6B6B' }
        default    { '#8B98A5' }
    }
}

function Update-OmniDashboard {
    <# .SYNOPSIS Internal: render a completed session into the UI (UI thread only). #>
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [pscustomobject] $Session)
    $c = $Ui.Controls
    $s = $Session.Summary

    if ($s) {
        $c.TxtScore.Text = [string]$s.Score
        $c.TxtScore.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString((Get-OmniGradeColor $s.Grade)))
        $c.TxtGrade.Text = $s.Grade
        $c.TxtCounts.Text = "Critical {0}  |  Error {1}  |  Warning {2}  |  Info {3}  |  Pass {4}" -f `
            $s.Counts.Critical, $s.Counts.Error, $s.Counts.Warning, $s.Counts.Information, $s.Counts.Pass
        $c.ItemsRecommendations.ItemsSource = @($s.TopRecommendations)
    }
    $c.TxtComputer.Text = "Computer: $($Session.Host.ComputerName)"
    $c.TxtUser.Text     = "User: $($Session.Host.UserName)"
    $c.TxtRange.Text    = "Range: $($Session.TimeRange.Label)"
    $c.TxtDuration.Text = "Duration: {0:N1} s" -f ($Session.DurationMs / 1000)

    $c.GridModules.ItemsSource = @($Session.Results | ForEach-Object {
        [pscustomobject]@{
            Module = $_.ModuleName; Category = $_.Category; Status = $_.Status
            Findings = $_.Findings.Count; DurationMs = $_.DurationMs
        }
    })
    $c.GridFindings.ItemsSource = @(ConvertTo-OmniFindingTable -Session $Session)
}

function Invoke-OmniWindow {
    <# .SYNOPSIS Internal: build and show the window (must run on an STA thread). #>
    param([string] $RootManifest, [string] $ModulesPath, [string] $Theme = 'Dark')

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop

    $xamlPath = Join-Path $script:OmniUiRoot 'MainWindow.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $names = @('BtnScan','BtnCancel','BtnExport','BtnTheme','CmbRange','NavList',
               'PanelDashboard','GridFindings','TxtScore','TxtGrade','TxtComputer',
               'TxtUser','TxtRange','TxtDuration','TxtCounts','ItemsRecommendations',
               'GridModules','ProgressBarMain','TxtStatus')
    $controls = @{}
    foreach ($n in $names) { $controls[$n] = $window.FindName($n) }

    # Shared GUI state (module scope so event handlers can reach it).
    $script:OmniUi = @{
        Window      = $window
        Controls    = $controls
        Theme       = $Theme
        Manifest    = $RootManifest
        ModulesPath = $ModulesPath
        Scan        = $null
        Session     = $null
        Timer       = $null
    }

    Set-OmniTheme -Window $window -Name $Theme

    # --- Progress poll timer ---------------------------------------------
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $ui = $script:OmniUi
        $scan = $ui.Scan
        if (-not $scan) { return }
        $sync = $scan.Sync
        $ui.Controls.ProgressBarMain.Value = [double]$sync.Progress
        $phase = if ($sync.CurrentModule) { "$($sync.CurrentModule) [$($sync.Phase)]" } else { 'Starting...' }
        $ui.Controls.TxtStatus.Text = "Scanning: $phase"

        if ($sync.Done) {
            $ui.Timer.Stop()
            try { $scan.PowerShell.EndInvoke($scan.Handle) } catch { }
            $scan.PowerShell.Dispose(); $scan.Runspace.Dispose(); $scan.Cts.Dispose()
            $ui.Scan = $null

            if ($sync.Error) {
                $ui.Controls.TxtStatus.Text = "Scan failed: $($sync.Error)"
            } else {
                $ui.Session = $sync.Session
                Update-OmniDashboard -Ui $ui -Session $sync.Session
                $cancelledNote = if ($sync.Session.Cancelled) { ' (cancelled)' } else { '' }
                $ui.Controls.TxtStatus.Text = "Scan complete$cancelledNote. Score $($sync.Session.Summary.Score)/100."
                $ui.Controls.BtnExport.IsEnabled = $true
            }
            $ui.Controls.BtnScan.IsEnabled = $true
            $ui.Controls.BtnCancel.IsEnabled = $false
            $ui.Controls.ProgressBarMain.Value = 100
        }
    })
    $script:OmniUi.Timer = $timer

    # --- Scan ------------------------------------------------------------
    $controls.BtnScan.Add_Click({
        $ui = $script:OmniUi
        if ($ui.Scan) { return }   # already running

        $rangeMap = @('Last24Hours', 'Last7Days', 'Last30Days')
        $idx = [Math]::Max(0, $ui.Controls.CmbRange.SelectedIndex)
        $range = $rangeMap[$idx]

        $sync = [hashtable]::Synchronized(@{ Progress = 0; CurrentModule = ''; Phase = ''; Done = $false; Session = $null; Error = $null })
        $cts = [System.Threading.CancellationTokenSource]::new()

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()

        $bg = {
            param($SyncHash, $Token, $Range, $Manifest, $ModulesPath)
            try {
                Import-Module $Manifest -Force -DisableNameChecking
                $cb = {
                    param($p)
                    $SyncHash.Progress = $p.PercentComplete
                    $SyncHash.CurrentModule = $p.Name
                    $SyncHash.Phase = $p.Phase
                }.GetNewClosure()
                $SyncHash.Session = Invoke-OmniDiag -Range $Range -ProgressCallback $cb `
                    -CancellationToken $Token -Quiet -ModulesPath $ModulesPath
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
        })
        $handle = $ps.BeginInvoke()

        $ui.Scan = @{ Sync = $sync; Cts = $cts; PowerShell = $ps; Runspace = $rs; Handle = $handle }

        $ui.Controls.BtnScan.IsEnabled = $false
        $ui.Controls.BtnCancel.IsEnabled = $true
        $ui.Controls.BtnExport.IsEnabled = $false
        $ui.Controls.ProgressBarMain.Value = 0
        $ui.Controls.TxtStatus.Text = 'Starting scan...'
        $ui.Timer.Start()
    })

    # --- Cancel ----------------------------------------------------------
    $controls.BtnCancel.Add_Click({
        $ui = $script:OmniUi
        if ($ui.Scan) {
            $ui.Controls.TxtStatus.Text = 'Cancelling...'
            $ui.Scan.Cts.Cancel()
            $ui.Controls.BtnCancel.IsEnabled = $false
        }
    })

    # --- Theme toggle ----------------------------------------------------
    $controls.BtnTheme.Add_Click({
        $ui = $script:OmniUi
        $ui.Theme = if ($ui.Theme -eq 'Dark') { 'Light' } else { 'Dark' }
        Set-OmniTheme -Window $ui.Window -Name $ui.Theme
    })

    # --- Navigation ------------------------------------------------------
    $controls.NavList.Add_SelectionChanged({
        $ui = $script:OmniUi
        $sel = $ui.Controls.NavList.SelectedIndex
        if ($sel -eq 1) {
            $ui.Controls.PanelDashboard.Visibility = 'Collapsed'
            $ui.Controls.GridFindings.Visibility = 'Visible'
        } else {
            $ui.Controls.PanelDashboard.Visibility = 'Visible'
            $ui.Controls.GridFindings.Visibility = 'Collapsed'
        }
    })

    # --- Export ----------------------------------------------------------
    $controls.BtnExport.Add_Click({
        $ui = $script:OmniUi
        if (-not $ui.Session) { return }
        $msg = "Reports are generated and stored locally - nothing is uploaded.`n`n" +
               "They may contain usernames, device names, file paths, domains, and other " +
               "internal information. Review before sharing.`n`nGenerate HTML/JSON/CSV/ZIP reports now?"
        $answer = [System.Windows.MessageBox]::Show($msg, 'OmniDiag - Privacy Notice', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        try {
            $outDir = Join-Path (Get-Location) 'reports'
            $set = Export-OmniReport -Session $ui.Session -OutputDirectory $outDir -Format Html, Json, Csv, Zip
            $ui.Controls.TxtStatus.Text = "Reports written to $($set.OutputDirectory)"
            [System.Windows.MessageBox]::Show("Reports written to:`n$($set.OutputDirectory)", 'OmniDiag', 'OK', 'Information') | Out-Null
            try { Invoke-Item -LiteralPath $set.OutputDirectory } catch { }
        } catch {
            [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", 'OmniDiag', 'OK', 'Error') | Out-Null
        }
    })

    # --- Clean up on close ----------------------------------------------
    $window.Add_Closing({
        $ui = $script:OmniUi
        if ($ui.Scan) {
            try { $ui.Scan.Cts.Cancel() } catch { }
            try { $ui.Timer.Stop() } catch { }
            try { $ui.Scan.PowerShell.Dispose(); $ui.Scan.Runspace.Dispose() } catch { }
        }
    })

    [void]$window.ShowDialog()
}

function Show-OmniDiagWindow {
    <#
    .SYNOPSIS
        Launches the OmniDiag GUI. Ensures an STA thread (hosting one when needed).

    .PARAMETER RootManifest
        Path to OmniDiag.psd1. Defaults to the sibling module manifest.

    .PARAMETER ModulesPath
        Diagnostic module folder. Defaults to the sibling Modules folder.

    .PARAMETER Theme
        Initial theme: Dark (default) or Light.
    #>
    [CmdletBinding()]
    param(
        [string] $RootManifest = (Join-Path (Split-Path $script:OmniUiRoot -Parent) 'OmniDiag.psd1'),
        [string] $ModulesPath  = (Join-Path (Split-Path $script:OmniUiRoot -Parent) 'Modules'),
        [ValidateSet('Dark', 'Light')] [string] $Theme = 'Dark'
    )

    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apartment -eq 'STA') {
        Invoke-OmniWindow -RootManifest $RootManifest -ModulesPath $ModulesPath -Theme $Theme
        return
    }

    # MTA (e.g. PowerShell 7): host the window in a dedicated STA runspace.
    Write-Verbose 'Current thread is MTA; hosting the GUI in a dedicated STA runspace.'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Manifest, $ModulesPath, $Theme)
        Import-Module $Manifest -Force -DisableNameChecking
        Show-OmniDiagWindow -RootManifest $Manifest -ModulesPath $ModulesPath -Theme $Theme
    }).AddParameters(@{ Manifest = $RootManifest; ModulesPath = $ModulesPath; Theme = $Theme })
    try {
        $ps.Invoke()   # blocks until the window closes
    } finally {
        $ps.Dispose(); $rs.Dispose()
    }
}

Export-ModuleMember -Function @('Show-OmniDiagWindow', 'Set-OmniTheme', 'Get-OmniThemePalette')
