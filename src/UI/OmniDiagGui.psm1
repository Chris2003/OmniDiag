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
    param([ValidateSet('Dark', 'Light')] [string] $Name = 'Light')
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
    param([Parameter(Mandatory)] $Window, [ValidateSet('Dark', 'Light')] [string] $Name = 'Light')
    $palette = Get-OmniThemePalette -Name $Name
    foreach ($key in $palette.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
        $Window.Resources[$key] = [System.Windows.Media.SolidColorBrush]::new($color)
    }
}

function Get-OmniGradeColor {
    # Mid-saturation values chosen to stay legible on both the light (default) and
    # dark panel backgrounds.
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

function Update-OmniRepairCatalog {
    <#
    .SYNOPSIS
        Internal: (re)populate the Repair Center grid (UI thread only).

    .DESCRIPTION
        Discovers the repair catalog via Invoke-OmniRepairCenter. When a Session is
        supplied, repairs relevant to its findings are flagged Recommended and pre-checked.
        Row objects are PSCustomObjects so the checkbox column can two-way bind to Selected.
    #>
    param([Parameter(Mandatory)] [hashtable] $Ui, [pscustomobject] $Session)

    $logger = New-OmniLogger -MinimumLevel Error
    $catalog = if ($Session) {
        @(Invoke-OmniRepairCenter -Session $Session -RepairsPath $Ui.RepairsPath -Logger $logger)
    } else {
        @(Invoke-OmniRepairCenter -RepairsPath $Ui.RepairsPath -Logger $logger)
    }

    $rows = @($catalog | ForEach-Object {
        [pscustomobject]@{
            Selected     = [bool]$_.Recommended
            Mark         = if ($_.Recommended) { [char]0x2605 } else { '' }   # star
            Name         = $_.Name
            Category     = $_.Category
            Risk         = $_.Risk
            Admin        = if ($_.RequiresAdmin) { 'Yes' } else { '' }
            Recommended  = [bool]$_.Recommended
            RestorePoint = [bool]$_.RestorePoint
            Reboot       = [bool]$_.RebootHint
        }
    })

    $Ui.RepairCatalog = $rows
    $Ui.Controls.RepairGrid.ItemsSource = $rows
}

function Invoke-OmniWindow {
    <# .SYNOPSIS Internal: build and show the window (must run on an STA thread). #>
    param([string] $RootManifest, [string] $ModulesPath, [string] $RepairsPath, [string] $Theme = 'Light')

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop

    $xamlPath = Join-Path $script:OmniUiRoot 'MainWindow.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $names = @('BtnScan','BtnCancel','BtnExport','BtnTheme','CmbRange','NavList',
               'PanelDashboard','GridFindings','TxtScore','TxtGrade','TxtComputer',
               'TxtUser','TxtRange','TxtDuration','TxtCounts','ItemsRecommendations',
               'GridModules','ProgressBarMain','TxtStatus',
               'PanelRepair','RepairGrid','RepairResultGrid','BtnRunRepairs','BtnRepairCancel',
               'BtnRepairRecommended','BtnRepairClear','ChkRepairDryRun','TxtRepairBanner','TxtRepairAdminNote')
    $controls = @{}
    foreach ($n in $names) { $controls[$n] = $window.FindName($n) }

    # Shared GUI state (module scope so event handlers can reach it).
    $script:OmniUi = @{
        Window        = $window
        Controls      = $controls
        Theme         = $Theme
        Manifest      = $RootManifest
        ModulesPath   = $ModulesPath
        RepairsPath   = $RepairsPath
        Scan          = $null
        Session       = $null
        Timer         = $null
        Repair        = $null
        RepairTimer   = $null
        RepairCatalog = @()
    }

    Set-OmniTheme -Window $window -Name $Theme
    $controls.BtnTheme.Content = Get-OmniThemeButtonLabel -Current $Theme

    # Populate the repair catalog (no session yet) and note elevation state.
    if (-not (Test-OmniIsAdministrator)) {
        $controls.TxtRepairAdminNote.Text =
            'Not elevated: repairs marked "Yes" under Admin will be skipped - re-run OmniDiag elevated for the full set. ' +
            $controls.TxtRepairAdminNote.Text
    }
    Update-OmniRepairCatalog -Ui $script:OmniUi

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
                Update-OmniRepairCatalog -Ui $ui -Session $sync.Session   # light up recommended repairs
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

    # --- Repair progress poll timer --------------------------------------
    $repairTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $repairTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $repairTimer.Add_Tick({
        $ui = $script:OmniUi
        $job = $ui.Repair
        if (-not $job) { return }
        $sync = $job.Sync
        $ui.Controls.ProgressBarMain.Value = [double]$sync.Progress
        $ui.Controls.TxtStatus.Text = if ($sync.Current) { "Repairing: $($sync.Current)" } else { 'Working...' }

        if ($sync.Done) {
            $ui.RepairTimer.Stop()
            try { $job.PowerShell.EndInvoke($job.Handle) } catch { }
            $job.PowerShell.Dispose(); $job.Runspace.Dispose(); $job.Cts.Dispose()
            $ui.Repair = $null

            if ($sync.Error) {
                $ui.Controls.TxtStatus.Text = "Repairs failed: $($sync.Error)"
                $ui.Controls.TxtRepairBanner.Text = "Error: $($sync.Error)"
            } else {
                $rs = $sync.Session
                $ui.Controls.RepairResultGrid.ItemsSource = @($rs.Results | ForEach-Object {
                    $failed = @($_.Steps | Where-Object { -not $_.Succeeded })
                    $detail = if ($_.Error) { $_.Error }
                              elseif ($failed.Count -gt 0) { $failed[0].Description }
                              else { "$($_.Steps.Count) step(s) ok" }
                    [pscustomobject]@{ Name = $_.Name; Status = $_.Status; Detail = $detail }
                })
                $banner = ''
                if ($rs.DryRun) { $banner += 'Dry run complete - no changes were made. ' }
                if ($rs.RestorePoint) { $banner += "Restore point: $($rs.RestorePoint.Status). " }
                if ($rs.RebootRequired) { $banner += 'A RESTART is required to finish applying one or more repairs.' }
                $ui.Controls.TxtRepairBanner.Text = $banner
                $ui.Controls.TxtStatus.Text = 'Repairs complete.'
            }
            $ui.Controls.BtnRunRepairs.IsEnabled = $true
            $ui.Controls.BtnRepairCancel.IsEnabled = $false
            $ui.Controls.ProgressBarMain.Value = 100
        }
    })
    $script:OmniUi.RepairTimer = $repairTimer

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
        $ui.Controls.BtnTheme.Content = Get-OmniThemeButtonLabel -Current $ui.Theme
    })

    # --- Navigation ------------------------------------------------------
    $controls.NavList.Add_SelectionChanged({
        $ui = $script:OmniUi
        $sel = $ui.Controls.NavList.SelectedIndex   # 0 Dashboard, 1 Findings, 2 Repair
        $ui.Controls.PanelDashboard.Visibility = if ($sel -eq 0) { 'Visible' } else { 'Collapsed' }
        $ui.Controls.GridFindings.Visibility   = if ($sel -eq 1) { 'Visible' } else { 'Collapsed' }
        $ui.Controls.PanelRepair.Visibility    = if ($sel -eq 2) { 'Visible' } else { 'Collapsed' }
    })

    # --- Repair: selection helpers ---------------------------------------
    $controls.BtnRepairRecommended.Add_Click({
        $ui = $script:OmniUi
        foreach ($r in @($ui.Controls.RepairGrid.ItemsSource)) { $r.Selected = [bool]$r.Recommended }
        $ui.Controls.RepairGrid.Items.Refresh()
    })
    $controls.BtnRepairClear.Add_Click({
        $ui = $script:OmniUi
        foreach ($r in @($ui.Controls.RepairGrid.ItemsSource)) { $r.Selected = $false }
        $ui.Controls.RepairGrid.Items.Refresh()
    })

    # --- Repair: cancel --------------------------------------------------
    $controls.BtnRepairCancel.Add_Click({
        $ui = $script:OmniUi
        if ($ui.Repair) {
            $ui.Controls.TxtStatus.Text = 'Cancelling repairs...'
            $ui.Repair.Cts.Cancel()
            $ui.Controls.BtnRepairCancel.IsEnabled = $false
        }
    })

    # --- Repair: run selected --------------------------------------------
    $controls.BtnRunRepairs.Add_Click({
        $ui = $script:OmniUi
        if ($ui.Repair) { return }   # already running

        $rows = @($ui.Controls.RepairGrid.ItemsSource | Where-Object { $_.Selected })
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
            $msg += "`n`nA System Restore point will be created first."
        }
        if (@($rows | Where-Object { $_.Reboot }).Count -gt 0) {
            $msg += "`n`nOne or more repairs will require a reboot to fully apply."
        }
        $msg += if ($dryRun) { "`n`nDRY RUN: nothing will be changed.`n`nProceed?" } else { "`n`nProceed?" }
        if ([System.Windows.MessageBox]::Show($msg, 'OmniDiag Repair - Confirm', 'YesNo', 'Warning') -ne 'Yes') { return }

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
                $logPath = Join-Path ([System.IO.Path]::GetTempPath()) "OmniDiag/omnidiag-repair-$stamp.jsonl"
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
                $SyncHash.Session = Invoke-OmniRepair -Registration $chosen -Context $ctx -ProgressCallback $cb
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

        $ui.Repair = @{ Sync = $sync; Cts = $cts; PowerShell = $ps; Runspace = $rs; Handle = $handle }
        $ui.Controls.RepairResultGrid.ItemsSource = @()
        $ui.Controls.TxtRepairBanner.Text = ''
        $ui.Controls.BtnRunRepairs.IsEnabled = $false
        $ui.Controls.BtnRepairCancel.IsEnabled = $true
        $ui.Controls.ProgressBarMain.Value = 0
        $ui.Controls.TxtStatus.Text = if ($dryRun) { 'Starting repairs (dry run)...' } else { 'Starting repairs...' }
        $ui.RepairTimer.Start()
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
        if ($ui.Repair) {
            try { $ui.Repair.Cts.Cancel() } catch { }
            try { $ui.RepairTimer.Stop() } catch { }
            try { $ui.Repair.PowerShell.Dispose(); $ui.Repair.Runspace.Dispose() } catch { }
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

    .PARAMETER RepairsPath
        Repair plugin folder. Defaults to the sibling Repairs folder.

    .PARAMETER Theme
        Initial theme: Light (default) or Dark.
    #>
    [CmdletBinding()]
    param(
        [string] $RootManifest = (Join-Path (Split-Path $script:OmniUiRoot -Parent) 'OmniDiag.psd1'),
        [string] $ModulesPath  = (Join-Path (Split-Path $script:OmniUiRoot -Parent) 'Modules'),
        [string] $RepairsPath  = (Join-Path (Split-Path $script:OmniUiRoot -Parent) 'Repairs'),
        [ValidateSet('Dark', 'Light')] [string] $Theme = 'Light'
    )

    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apartment -eq 'STA') {
        Invoke-OmniWindow -RootManifest $RootManifest -ModulesPath $ModulesPath -RepairsPath $RepairsPath -Theme $Theme
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
        param($Manifest, $ModulesPath, $RepairsPath, $Theme)
        Import-Module $Manifest -Force -DisableNameChecking
        Show-OmniDiagWindow -RootManifest $Manifest -ModulesPath $ModulesPath -RepairsPath $RepairsPath -Theme $Theme
    }).AddParameters(@{ Manifest = $RootManifest; ModulesPath = $ModulesPath; RepairsPath = $RepairsPath; Theme = $Theme })
    try {
        $ps.Invoke()   # blocks until the window closes
    } finally {
        $ps.Dispose(); $rs.Dispose()
    }
}

Export-ModuleMember -Function @('Show-OmniDiagWindow', 'Set-OmniTheme', 'Get-OmniThemePalette')
