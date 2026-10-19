#Requires -Version 5.1
<#
.SYNOPSIS
    Renders the real OmniDiag GUI with a synthetic demo session and saves PNG screenshots.

.DESCRIPTION
    Builds the actual OmniDiag window (Initialize-OmniMainWindow from src/UI/OmniDiagGui.psm1:
    the code-built frame, then the shell XAML, then the lazily loaded sections) on an STA
    thread, loads a SYNTHETIC session (pseudonymous host 'DEMO-PC', user 'demo'; no data from
    the machine running the script), navigates to each section, and captures it with
    RenderTargetBitmap + PngBitmapEncoder at a fixed size (1280x800 by default).

    No real host data reaches the pictures:
      - the deferred startup task (System Information inventory over CIM, scanner and repair
        catalogs) is suppressed; the System Information panel gets synthetic values;
      - the session is built in memory from New-OmniResult / New-OmniFinding;
      - the repair list comes from the repair plugins' static metadata, with "Recommended"
        derived from the synthetic session (Get-OmniDiagRepair -Session).

    The window is shown (WPF only renders a shown window) but placed outside the visible
    desktop, without activation or a taskbar button. If it does not render there within
    the timeout, it is moved on-screen and the wait is repeated. Each section is captured
    from its visual tree, so the picture does not depend on the screen resolution or on
    other windows. Needs a Windows desktop session (GitHub-hosted Windows runners have one).

    Files written to -OutputDirectory:
        dashboard-light.png, dashboard-dark.png, groups.png, group-network.png,
        findings.png, repair.png

    Works on Windows PowerShell 5.1 and PowerShell 7 (the capture always runs in a
    dedicated STA runspace). CI runs it in the non-blocking 'screenshots' job and uploads
    the PNGs as an artifact; maintainers commit them to docs/images/.

.PARAMETER OutputDirectory
    Folder for the PNG files. Default: docs/images under the repository root.

.PARAMETER Width
    Image width in pixels (device-independent units at 96 DPI). Default 1280.

.PARAMETER Height
    Image height in pixels. Default 800.

.PARAMETER TimeoutSec
    How long to wait for the window to render and for the shell to become ready. Default 60.

.EXAMPLE
    ./build/New-Screenshots.ps1

.EXAMPLE
    ./build/New-Screenshots.ps1 -OutputDirectory out/shots -Width 1440 -Height 900
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [ValidateRange(640, 3840)] [int] $Width = 1280,
    [ValidateRange(480, 2160)] [int] $Height = 800,
    [ValidateRange(10, 600)] [int] $TimeoutSec = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Join-Path $repoRoot 'docs') 'images' }
if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path (Get-Location).Path $OutputDirectory }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

$onWindows = $true
if ($PSVersionTable.PSEdition -eq 'Core') { $onWindows = [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue) }
if (-not $onWindows) { throw 'New-Screenshots.ps1 needs Windows (WPF).' }

$manifest = Join-Path (Join-Path $repoRoot 'src') 'OmniDiag.psd1'
if (-not (Test-Path -LiteralPath $manifest)) { throw "Module manifest not found: $manifest" }
if (-not (Test-Path -LiteralPath $OutputDirectory)) { $null = New-Item -ItemType Directory -Path $OutputDirectory -Force }

# Everything below runs on an STA thread inside the GUI module's scope (so it can reach the
# GUI's internal functions and its $script:OmniUi state).
$captureScript = {
    param($Opt)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $W = [int]$Opt.Width
    $H = [int]$Opt.Height
    $written = [System.Collections.Generic.List[object]]::new()

    # ---- Synthetic demo session (no data from this machine) -------------------------------
    $t0 = [datetime]::new(2026, 6, 1, 9, 0, 0, [System.DateTimeKind]::Utc)
    $newResult = {
        param([string] $Name, [string] $Category, [string] $ModuleId, [string] $Group, [object[]] $Finding, [int] $DurationMs, [string] $Status)
        $r = New-OmniResult -ModuleName $Name -Category $Category -RequiresAdmin $false -HadAdmin $true
        foreach ($item in @($Finding)) {
            if ($null -eq $item) { continue }
            $item.Timestamp = $t0
            Add-OmniFinding -Result $r -Finding $item
        }
        if ($Status) { $null = Complete-OmniResult -Result $r -Status $Status } else { $null = Complete-OmniResult -Result $r }
        $r.StartTime = $t0
        $r.EndTime = $t0.AddMilliseconds($DurationMs)
        $r.DurationMs = $DurationMs
        Add-Member -InputObject $r -MemberType NoteProperty -Name ModuleId -Value $ModuleId -Force
        Add-Member -InputObject $r -MemberType NoteProperty -Name Group -Value $Group -Force
        Add-Member -InputObject $r -MemberType NoteProperty -Name SkippedReason -Value $null -Force
        return $r
    }
    $newFinding = { param($Title, $Severity, $Component, $Id, $Detail = '', $Cause = '', $Rec = '', $Conf = 0)
        $p = @{ Title = $Title; Severity = $Severity; Component = $Component; Detail = $Detail; LikelyCause = $Cause; Recommendation = $Rec; Confidence = $Conf }
        if ($Id) { $p.Id = $Id }
        New-OmniFinding @p
    }

    $results = @(
        (& $newResult 'System Information' 'System' 'system.system-information' 'system' @(
            (& $newFinding 'System inventory collected' 'Pass' 'System' $null 'Windows 11 Pro 24H2, 16 GB RAM.')) 140)
        (& $newResult 'CPU' 'Performance' 'performance.cpu' 'performance' @(
            (& $newFinding 'CPU metrics collected' 'Pass' 'Performance/CPU' $null '8 logical processors, 12% average load.')) 1050)
        (& $newResult 'Memory' 'Performance' 'performance.memory' 'performance' @(
            (& $newFinding 'High memory usage (91%)' 'Warning' 'Performance/Memory' $null '14.6 GB of 16 GB in use.' 'Many browser tabs and a large virtual machine are open.' 'Close unused applications or add memory.' 70)) 220)
        (& $newResult 'Services' 'System' 'services.services' 'services' @(
            (& $newFinding 'Automatic services are running' 'Pass' 'Services' $null)) 610)
        (& $newResult 'Startup' 'System' 'startup.startup' 'startup' @(
            (& $newFinding '27 startup item(s) found' 'Information' 'Startup' 'startup-items-summary'),
            (& $newFinding 'High number of startup items' 'Warning' 'Startup' 'startup-items-high-count' '27 Run-key and startup-command entries.' 'Many applications register themselves to start at sign-in.' 'Disable startup items you do not need in Task Manager > Startup apps.' 60)) 310)
        (& $newResult 'Event Logs' 'Event Logs' 'events.event-logs' 'events' @(
            (& $newFinding 'Disk warnings in the System log (x4)' 'Warning' 'EventLog/System' $null 'Event 153 from disk: the IO operation was retried.' 'A storage driver or cable issue causes retries.' 'Check the drive cabling and update the storage driver.' 55)) 1890)
        (& $newResult 'Reliability' 'Reliability' 'reliability.reliability' 'reliability' @(
            (& $newFinding '1 unexpected shutdown(s) (Last 7 days)' 'Warning' 'Reliability' 'reliability.reliability.unexpected-shutdowns' 'Kernel-Power event 41 on 2026-05-29.' 'Power loss or a forced restart.' 'Check the power supply and review crash dumps.' 60)) 480)
        (& $newResult 'Disk' 'Storage' 'storage.disk' 'storage' @(
            (& $newFinding 'Low free space on C: (7%)' 'Warning' 'Storage' 'disk-volume-low-space-c' '17.4 GB free of 237 GB.' 'Temporary files and old downloads fill the system drive.' 'Run the Clear Temp Files repair or Disk Cleanup.' 85)) 260)
        (& $newResult 'TRIM' 'Storage' 'storage.trim' 'storage' @(
            (& $newFinding 'TRIM is enabled' 'Pass' 'Storage/TRIM' 'storage-trim-enabled')) 90)
        (& $newResult 'DNS Resolver' 'Network' 'network.dns-resolver' 'network' @(
            (& $newFinding 'Connectivity probe not run' 'Information' 'Network/DNS' $null 'Run with --network-probes to test name resolution.'),
            (& $newFinding 'DNS resolver healthy' 'Pass' 'Network/DNS' $null)) 120)
        (& $newResult 'IP Configuration' 'Network' 'network.ip-configuration' 'network' @(
            (& $newFinding 'APIPA address on Wi-Fi (DHCP failure)' 'Error' 'Network/IP' $null 'Wi-Fi has 169.254.12.7.' 'The DHCP server did not answer.' 'Renew the address (Renew IP Address repair) or check the access point.' 80)) 150)
        (& $newResult 'Windows Update' 'Updates' 'updates.windows-update' 'updates' @(
            (& $newFinding 'Most recent update is 74 days old' 'Warning' 'WindowsUpdate' $null 'Last hotfix installed on 2026-03-19.' 'Updates are paused or failing.' 'Open Windows Update and install pending updates.' 65)) 700)
        (& $newResult 'Windows Health' 'Health' 'updates.windows-health' 'updates' @(
            (& $newFinding 'Windows health checks passed' 'Pass' 'Health' $null)) 330)
        (& $newResult 'Security' 'Security' 'security.security' 'security' @(
            (& $newFinding 'Firewall enabled on all profiles' 'Pass' 'Security/Firewall' $null),
            (& $newFinding 'Antivirus signatures are 9 days old' 'Warning' 'Security/Defender' $null 'Signature version 1.413.0.0.' 'Definition updates are not reaching the device.' 'Update Microsoft Defender definitions.' 70)) 540)
        (& $newResult 'Certificates' 'Security' 'security.certificates' 'security' @(
            (& $newFinding 'No expired certificates' 'Pass' 'Security/Certificates' $null)) 210)
        (& $newResult 'Printers' 'Peripherals' 'extras.printers' 'extras' @(
            (& $newFinding 'Print spooler running' 'Pass' 'Printers' $null)) 180)
    )
    $session = [pscustomobject]@{
        PSTypeName = 'OmniDiag.Session'
        StartTime  = $t0
        EndTime    = $t0.AddSeconds(9)
        DurationMs = 9300
        Cancelled  = $false
        TimeRange  = [pscustomobject]@{ PSTypeName = 'OmniDiag.TimeRange'; Start = $t0.AddDays(-7); End = $t0; Label = 'Last 7 days'; Preset = 'Last7Days' }
        Host       = [pscustomobject]@{ ComputerName = 'DEMO-PC'; UserName = 'demo'; PSVersion = '5.1.26100.1' }
        IsAdmin    = $true
        Results    = $results
        Summary    = ($results | Get-OmniHealthScore)
    }

    $sysInfo = [ordered]@{
        'System' = [ordered]@{
            'Computer Name' = 'DEMO-PC'; 'Operating System' = 'Microsoft Windows 11 Pro 10.0.26100 (Build 26100)'
            'Architecture' = '64-bit'; 'Manufacturer' = 'Contoso'; 'Model' = 'Demo Laptop 14'
            'Installed Memory (RAM)' = '16 GB'; 'Workgroup' = 'WORKGROUP'; 'Logged-in User' = 'DEMO-PC\demo'
            'DirectX Version' = 'DirectX 12'; 'Uptime' = '2d 4h 13m'
        }
        'Processor' = [ordered]@{ 'Processor' = 'Demo CPU 8-Core @ 2.80GHz'; 'Cores / Threads' = '4 cores, 8 logical' }
        'Display' = [ordered]@{ 'Name' = 'Demo Graphics'; 'Current Mode' = '1920 x 1080 @ 60 Hz' }
    }

    # ---- Window -------------------------------------------------------------------------
    $win = Initialize-OmniMainWindow -RootManifest $Opt.Manifest -ModulesPath $Opt.ModulesPath -RepairsPath $Opt.RepairsPath -Theme Light `
        -StartupClock ([System.Diagnostics.Stopwatch]::StartNew())
    $ui = $script:OmniUi
    # Suppress the deferred startup task (real System Information / catalogs from this host).
    $ui.StartupTask = 'suppressed by New-Screenshots.ps1'

    $win.WindowStyle = [System.Windows.WindowStyle]::None
    $win.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $win.ShowInTaskbar = $false
    $win.ShowActivated = $false
    $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
    $win.MinWidth = 0; $win.MinHeight = 0
    $win.Width = $W; $win.Height = $H
    $win.Left = [System.Windows.SystemParameters]::VirtualScreenLeft - $W - 200
    $win.Top = [System.Windows.SystemParameters]::VirtualScreenTop

    $pump = { $win.Dispatcher.Invoke([Action] { }, [System.Windows.Threading.DispatcherPriority]::ContextIdle) }
    $waitFor = {
        param([scriptblock] $Condition, [int] $Seconds)
        $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
        while (-not (& $Condition) -and [DateTime]::UtcNow -lt $deadline) {
            & $pump
            Start-Sleep -Milliseconds 20
        }
        return [bool](& $Condition)
    }

    $win.Show()
    if (-not (& $waitFor { $null -ne $script:OmniUi.StartupMs } $Opt.TimeoutSec)) {
        # Some desktops do not render a window placed off-screen: bring it on-screen and retry.
        $win.Left = [System.Windows.SystemParameters]::WorkArea.Left
        $win.Top = [System.Windows.SystemParameters]::WorkArea.Top
        if (-not (& $waitFor { $null -ne $script:OmniUi.StartupMs } $Opt.TimeoutSec)) { throw 'The window never rendered (no ContentRendered).' }
    }
    if (-not (& $waitFor { $null -ne $script:OmniUi.ShellReadyMs -or $script:OmniUi.ShellError } $Opt.TimeoutSec)) { throw 'The shell never became ready.' }
    if ($ui.ShellError) { throw "The shell XAML did not load: $($ui.ShellError)" }
    $null = & $waitFor { $script:OmniUi.PostRenderDone -and (Test-OmniSectionLoaded -Name 'DashboardModules') } $Opt.TimeoutSec

    # ---- Demo data into the UI ----------------------------------------------------------------
    $groups = @(Get-OmniDiagGroup -ModulesPath $Opt.ModulesPath | ForEach-Object {
        @{ Id = [string]$_.Id; Name = [string]$_.Name; Description = [string]$_.Description; ScannerCount = [int]$_.ScannerCount }
    })
    Register-OmniGroupCatalog -Group $groups
    Update-OmniSysInfoPanel -Ui $ui -Info $sysInfo
    $ui.Session = $session
    Update-OmniDashboard -Ui $ui -Session $session
    $repairs = @(Get-OmniDiagRepair -Session $session -RepairsPath $Opt.RepairsPath | ForEach-Object {
        @{
            Name = [string]$_.Name; Category = [string]$_.Category; Risk = [string]$_.Risk
            RequiresAdmin = [bool]$_.RequiresAdmin; Recommended = [bool]$_.Recommended
            RestorePoint = [bool]$_.RestorePoint; RebootHint = [bool]$_.RebootHint
        }
    })
    Show-OmniRepairCatalog -Item $repairs
    $s = $session.Summary
    Write-OmniStatus -Text ("Scan complete. Score {0} of 100, {1}. {2} finding(s)." -f $s.Score, $s.Grade, @($ui.FindingRows).Count)
    $ui.Controls.ProgressBarMain.Value = 100

    # ---- Capture ------------------------------------------------------------------------
    $save = {
        param([string] $Name)
        $root = $script:OmniUi.ShellRoot
        $root.Width = $W; $root.Height = $H
        & $pump
        $win.UpdateLayout()
        & $pump
        # Lay the shell out at exactly W x H (also when the desktop is smaller than the image).
        $root.Measure([System.Windows.Size]::new($W, $H))
        $root.Arrange([System.Windows.Rect]::new(0, 0, $W, $H))
        $bmp = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bg = [System.Windows.Media.DrawingVisual]::new()
        $dc = $bg.RenderOpen()
        $dc.DrawRectangle($win.Background, $null, [System.Windows.Rect]::new(0, 0, $W, $H))
        $dc.Close()
        $bmp.Render($bg)
        $bmp.Render($root)
        $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $path = Join-Path $Opt.OutputDirectory $Name
        $stream = [System.IO.File]::Create($path)
        try { $enc.Save($stream) } finally { $stream.Dispose() }
        $written.Add([pscustomobject]@{ Name = $Name; Path = $path; Width = $W; Height = $H })
    }
    $go = {
        param([int] $Index)
        Select-OmniNavSection -Index $Index -NoFocus
        & $pump
    }

    & $go 0
    & $save 'dashboard-light.png'

    if (-not $ui.HighContrast) {
        $ui.Theme = 'Dark'
        Sync-OmniEffectiveTheme
        Write-OmniStatus -Text ("Scan complete. Score {0} of 100, {1}. {2} finding(s)." -f $s.Score, $s.Grade, @($ui.FindingRows).Count)
        & $save 'dashboard-dark.png'
        $ui.Theme = 'Light'
        Sync-OmniEffectiveTheme
    }

    & $go 1
    & $save 'groups.png'
    $net = @($ui.GroupRows | Where-Object { $_.Id -eq 'network' }) | Select-Object -First 1
    if ($net) {
        Show-OmniGroupDetail -GroupRow $net -KeepFocus
        $c = $ui.Controls
        if ($c.GridGroupFindings.Items.Count -gt 0) { $c.GridGroupFindings.SelectedIndex = 0 }
        & $save 'group-network.png'
        $c.GroupDetailView.Visibility = 'Collapsed'
        $c.GroupListView.Visibility = 'Visible'
        $ui.SelectedGroupId = $null
    }

    & $go 2
    if ($ui.Controls.GridFindings.Items.Count -gt 0) { $ui.Controls.GridFindings.SelectedIndex = 0 }
    & $save 'findings.png'

    & $go 4
    if ($ui.Controls.ChkRepairDryRun) { $ui.Controls.ChkRepairDryRun.IsChecked = $true }
    & $save 'repair.png'

    try { $win.Close() } catch { $null = $_ }
    & $pump
    return $written.ToArray()
}

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.ThreadOptions = 'ReuseThread'
$rs.Open()
$ps = [PowerShell]::Create()
$ps.Runspace = $rs
try {
    [void]$ps.AddScript({
        param($Opt, $CaptureText)
        Import-Module $Opt.Manifest -Force -DisableNameChecking
        $root = Get-Module -Name OmniDiag | Select-Object -First 1
        $gui = @($root.NestedModules | Where-Object { $_.Name -eq 'OmniDiagGui' }) | Select-Object -First 1
        if (-not $gui) { throw 'The OmniDiagGui module was not loaded.' }
        & $gui ([scriptblock]::Create($CaptureText)) $Opt
    }).AddParameters(@{
        Opt = @{
            Manifest = $manifest
            ModulesPath = Join-Path (Join-Path $repoRoot 'src') 'Modules'
            RepairsPath = Join-Path (Join-Path $repoRoot 'src') 'Repairs'
            OutputDirectory = $OutputDirectory
            Width = $Width; Height = $Height; TimeoutSec = $TimeoutSec
        }
        CaptureText = $captureScript.ToString()
    })
    $out = $ps.Invoke()
    foreach ($e in @($ps.Streams.Error)) { Write-Warning "Screenshot runspace: $e" }
    if ($ps.HadErrors -and @($out).Count -eq 0) { throw 'No screenshots were written (see the warnings above).' }
    foreach ($item in @($out)) {
        if ($item -and $item.PSObject.Properties['Path']) {
            Write-Host ("Wrote {0} ({1}x{2})" -f $item.Path, $item.Width, $item.Height)
            $item
        }
    }
} finally {
    $ps.Dispose()
    $rs.Dispose()
}
