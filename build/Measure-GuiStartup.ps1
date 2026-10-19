<#
.SYNOPSIS
    Measures OmniDiag GUI startup: first paint and "shell ready" for several window-building
    strategies, plus the real launcher's wall time, in fresh PowerShell processes.

.DESCRIPTION
    Every measurement runs in a FRESH child process (no warm XAML engine or JIT), -Runs
    times per host, and the median is reported. Hosts: PowerShell 7 (pwsh) and Windows
    PowerShell 5.1 (powershell.exe), whichever exist (or -PowerShellPath).

    Variants (each child runs one on an STA thread, -STA; the OmniDiag module is imported
    BEFORE the clock starts, so these isolate WPF/XAML cost; the clock starts just before
    Add-Type of the WPF assemblies):

      Current            The real Initialize-OmniMainWindow path: code-built frame window,
                         shell XAML parsed at Background priority after the frame's first
                         paint. FirstPaint = the frame's ContentRendered; Ready = ShellReady.
      XamlShellSync      The shell XAML parsed synchronously into a window before Show (the
                         pre-frame approach): FirstPaint = Ready = ContentRendered.
      CodeFrame          Only a code-built Window (Grid + TextBlock "OmniDiag - loading", the
                         theme brushes set in code), no XAML: FirstPaint = Ready.
      CodeFrameThenShell CodeFrame, then the shell XAML parsed at Background priority and
                         swapped in as the Content: Ready = the next Background callback
                         after the swap ("ShellReady").
      Launcher           The real end-user path, OmniDiag.ps1 -Gui (module import, the MTA
                         -> STA hop on PowerShell 7, everything), measured from the child's
                         Process.StartTime. Uses the GUI's test hooks
                         OMNIDIAG_GUI_EXIT_AFTER_RENDER=1 (close once the shell is ready) and
                         OMNIDIAG_GUI_STARTUP_FILE (write the timings as JSON).

    Output: gui-startup.json (every run plus medians) and gui-startup.md in
    -OutputDirectory; the markdown is appended to $GITHUB_STEP_SUMMARY when set. Exit
    code 0 when at least one run produced a measurement, 2 otherwise. Windows only (WPF);
    needs a desktop session that can render windows.

.PARAMETER Runs
    Fresh processes per host and variant. Default 3.

.PARAMETER Variant
    Which variants to run. Default: all five.

.PARAMETER PowerShellPath
    PowerShell executables to measure. Default: pwsh (this one if running under 7, else
    the installed one) and %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe.

.PARAMETER OutputDirectory
    Where the summary files go. Default: <repo>/test-results/gui-startup.

.PARAMETER TimeoutSeconds
    Per-run timeout. Default 120.

.PARAMETER Child
    Internal: run one variant in this process and write its result to -ResultPath.

.PARAMETER ResultPath
    Internal: where a child writes its JSON result.

.EXAMPLE
    ./build/Measure-GuiStartup.ps1

.EXAMPLE
    ./build/Measure-GuiStartup.ps1 -Runs 5 -Variant Current, Launcher
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 25)] [int] $Runs = 3,
    [ValidateSet('Current', 'XamlShellSync', 'CodeFrame', 'CodeFrameThenShell', 'Launcher')]
    [string[]] $Variant = @('Current', 'XamlShellSync', 'CodeFrame', 'CodeFrameThenShell', 'Launcher'),
    [string[]] $PowerShellPath,
    [string] $OutputDirectory,
    [ValidateRange(10, 900)] [int] $TimeoutSeconds = 120,
    [string] $Child,
    [string] $ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $repoRoot (Join-Path 'src' 'OmniDiag.psd1')
$shellXamlPath = Join-Path $repoRoot (Join-Path 'src' (Join-Path 'UI' 'MainWindow.xaml'))

# ---------------------------------------------------------------------------
# Child: one variant, one fresh process
# ---------------------------------------------------------------------------

function Write-ChildResult {
    param([System.Collections.IDictionary] $Result, [string] $Path)
    [System.IO.File]::WriteAllText($Path, ($Result | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
}

function Move-ShellIntoWindow {
    # The same swap Complete-OmniShellLoad does: resources (window keys win) and KeyBindings
    # onto the window, then the shell root becomes the Content.
    param($Window, $Root)
    $res = $Root.Resources
    foreach ($key in @($res.Keys)) { if (-not $Window.Resources.Contains($key)) { $Window.Resources[$key] = $res[$key] } }
    $res.Clear()
    $bindings = @($Root.InputBindings)
    $Root.InputBindings.Clear()
    foreach ($b in $bindings) { [void]$Window.InputBindings.Add($b) }
    $Window.Content = $Root
}

function New-CodeFrame {
    # A code-built window: no XAML. Brushes come from the GUI module's palette.
    param($Gui)
    $w = [System.Windows.Window]::new()
    $w.Title = 'OmniDiag - One Tool. Complete Diagnostics.'
    $w.Width = 1180; $w.Height = 760
    $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $w.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
    $w.FontSize = 13
    & $Gui { param($win) Set-OmniTheme -Window $win -Name Light } $w
    $w.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'BrushWindowBg')
    $grid = [System.Windows.Controls.Grid]::new()
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = 'OmniDiag - loading'
    $t.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $t.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'BrushText')
    [void]$grid.Children.Add($t)
    $w.Content = $grid
    return $w
}

function Invoke-ChildVariant {
    param([string] $Name, [string] $OutPath)
    $r = [ordered]@{
        Variant = $Name; PSEdition = [string]$PSVersionTable.PSEdition; PSVersion = [string]$PSVersionTable.PSVersion
        FirstPaintMs = $null; ReadyMs = $null; Marks = [ordered]@{}; Error = $null
    }
    try {
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'the child must run on an STA thread (-STA)' }
        $env:OMNIDIAG_NO_DEPRECATION_WARNING = '1'
        # Import first: the clock below measures WPF / XAML work only.
        Import-Module $manifest -Force -DisableNameChecking
        $gui = @((Get-Module OmniDiag).NestedModules | Where-Object { $_.Name -eq 'OmniDiagGui' })[0]
        $shellText = [System.IO.File]::ReadAllText($shellXamlPath, [System.Text.Encoding]::UTF8)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $mark = { param($n) if (-not $r.Marks.Contains($n)) { $r.Marks[$n] = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) } }
        $state = @{ Done = $false }
        $window = $null

        if ($Name -eq 'Current') {
            # The GUI's own exit hook closes the window once the shell is ready, before the
            # background startup runspace would start.
            $env:OMNIDIAG_GUI_EXIT_AFTER_RENDER = '1'
            $window = & $gui { param($c) Initialize-OmniMainWindow -StartupClock $c } $sw
        } else {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
            & $mark 'WpfAssembliesLoaded'
            if ($Name -eq 'XamlShellSync') {
                $window = New-CodeFrame -Gui $gui
                $root = [System.Windows.Markup.XamlReader]::Parse($shellText)
                & $mark 'ShellParsed'
                Move-ShellIntoWindow -Window $window -Root $root
            } else {
                $window = New-CodeFrame -Gui $gui
            }
            & $mark 'WindowConstructed'
            $window.Add_ContentRendered({
                & $mark 'ContentRendered'
                if ($Name -ne 'CodeFrameThenShell') { $state.Done = $true; return }
                [void]$window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action] {
                    $root = [System.Windows.Markup.XamlReader]::Parse($shellText)
                    & $mark 'ShellParsed'
                    Move-ShellIntoWindow -Window $window -Root $root
                    & $mark 'ShellSwapped'
                    [void]$window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action] {
                        & $mark 'ShellReady'
                        $state.Done = $true
                    })
                })
            })
        }

        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(20)
        $timer.Add_Tick({
            if ($Name -eq 'Current' -and $null -ne (& $gui { $script:OmniUi.ShellReadyMs })) { $state.Done = $true }
            if ($state.Done -or [DateTime]::UtcNow -gt $deadline) { $timer.Stop(); $frame.Continue = $false }
        })
        & $mark 'ShowCalled'
        $window.Show()
        $timer.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)

        if ($Name -eq 'Current') {
            $marks = & $gui { $script:OmniStartupMarks }
            if ($marks) { foreach ($k in @($marks.Keys)) { $r.Marks[[string]$k] = $marks[$k] } }
            $r.FirstPaintMs = & $gui { $script:OmniUi.StartupMs }
            $r.ReadyMs = & $gui { $script:OmniUi.ShellReadyMs }
        } else {
            if ($r.Marks.Contains('ContentRendered')) { $r.FirstPaintMs = $r.Marks['ContentRendered'] }
            $readyKey = if ($Name -eq 'CodeFrameThenShell') { 'ShellReady' } else { 'ContentRendered' }
            if ($r.Marks.Contains($readyKey)) { $r.ReadyMs = $r.Marks[$readyKey] }
        }
        if (-not $state.Done) { $r.Error = "timed out after $TimeoutSeconds s" }
        try { $window.Close() } catch { $null = $_ }
    } catch {
        $r.Error = $_.Exception.Message
    }
    Write-ChildResult -Result $r -Path $OutPath
}

if ($Child) {
    if (-not $ResultPath) { throw '-Child needs -ResultPath.' }
    Invoke-ChildVariant -Name $Child -OutPath $ResultPath
    exit 0
}

# ---------------------------------------------------------------------------
# Parent: fresh processes, medians, summary
# ---------------------------------------------------------------------------

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Measure-GuiStartup.ps1 needs Windows (WPF).' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot (Join-Path 'test-results' 'gui-startup') }
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$work = Join-Path ([IO.Path]::GetTempPath()) ('omnidiag-gui-startup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force

if (-not $PowerShellPath) {
    $found = [System.Collections.Generic.List[string]]::new()
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $found.Add((Get-Process -Id $PID).Path)
    } else {
        $pw = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pw) { $found.Add($pw.Source) }
    }
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $winPs) { $found.Add($winPs) }
    $PowerShellPath = @($found)
}

function ConvertTo-ArgumentString {
    param([string[]] $Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ }
    }) -join ' '
}

function Invoke-Child {
    # Starts one fresh process and waits (with a timeout). Returns the exit code or $null on timeout.
    param([string] $Exe, [string[]] $Arguments, [hashtable] $Environment)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $repoRoot
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(($TimeoutSeconds + 30) * 1000)) {
        try { $p.Kill() } catch { $null = $_ }
        return [pscustomobject]@{ ExitCode = $null; Stderr = 'timed out' }
    }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Stderr = [string]$errTask.Result + [string]$outTask.Result }
}

function Get-Median {
    param([double[]] $Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return [math]::Round($sorted[$mid], 1) }
    [math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2, 1)
}

$baseEnv = @{
    OMNIDIAG_DATA = (Join-Path $work 'OmniDiagData')
    OMNIDIAG_NO_DEPRECATION_WARNING = '1'
    POWERSHELL_TELEMETRY_OPTOUT = '1'; POWERSHELL_UPDATECHECK = 'Off'; POWERSHELL_CLI_TELEMETRY_OPTOUT = '1'
}
$launcherScript = Join-Path $repoRoot 'OmniDiag.ps1'
$allRuns = [System.Collections.Generic.List[object]]::new()

foreach ($exe in $PowerShellPath) {
    $hostLabel = if ([IO.Path]::GetFileNameWithoutExtension($exe) -ieq 'pwsh') { 'pwsh' } else { 'powershell' }
    foreach ($v in $Variant) {
        for ($i = 1; $i -le $Runs; $i++) {
            $out = Join-Path $work ("{0}-{1}-{2}.json" -f $hostLabel, $v, $i)
            $run = [ordered]@{ Host = $hostLabel; Exe = $exe; Variant = $v; Run = $i; FirstPaintMs = $null; ReadyMs = $null; Marks = $null; Error = $null }
            $envVars = @{} + $baseEnv
            if ($v -eq 'Launcher') {
                # The real path: no -STA (PowerShell 7 hops to an STA runspace itself).
                $envVars.OMNIDIAG_GUI_EXIT_AFTER_RENDER = '1'
                $envVars.OMNIDIAG_GUI_STARTUP_FILE = $out
                $res = Invoke-Child -Exe $exe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcherScript, '-Gui') -Environment $envVars
            } else {
                $res = Invoke-Child -Exe $exe -Arguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath,
                    '-Child', $v, '-ResultPath', $out, '-TimeoutSeconds', [string]$TimeoutSeconds) -Environment $envVars
            }
            if (-not (Test-Path -LiteralPath $out)) {
                $run.Error = "no result (exit $($res.ExitCode)): $(([string]$res.Stderr).Trim())"
            } else {
                $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
                $run.Marks = $doc.Marks
                if ($v -eq 'Launcher') {
                    # Wall time from the child's own process start.
                    try {
                        $start = [DateTime]::Parse([string]$doc.ProcessStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                        $paint = [DateTime]::Parse([string]$doc.FramePaintedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                        $ready = [DateTime]::Parse([string]$doc.ShellReadyUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                        $run.FirstPaintMs = [math]::Round(($paint - $start).TotalMilliseconds, 1)
                        $run.ReadyMs = [math]::Round(($ready - $start).TotalMilliseconds, 1)
                        $run.EntryFirstPaintMs = $doc.StartupMs
                        $run.EntryReadyMs = $doc.ShellReadyMs
                    } catch {
                        $run.Error = "launcher timings incomplete: $($_.Exception.Message)"
                    }
                } else {
                    $run.FirstPaintMs = $doc.FirstPaintMs
                    $run.ReadyMs = $doc.ReadyMs
                    if ($doc.Error) { $run.Error = [string]$doc.Error }
                }
            }
            $allRuns.Add([pscustomobject]$run)
            Write-Host ("{0,-10} {1,-19} run {2}: first paint {3} ms, ready {4} ms{5}" -f $hostLabel, $v, $i, $run.FirstPaintMs, $run.ReadyMs, $(if ($run.Error) { " ($($run.Error))" } else { '' }))
        }
    }
}

$summary = [System.Collections.Generic.List[object]]::new()
foreach ($g in @($allRuns | Group-Object -Property Host, Variant)) {
    $ok = @($g.Group | Where-Object { -not $_.Error -and $null -ne $_.FirstPaintMs })
    $first = $g.Group[0]
    $row = [ordered]@{
        Host = $first.Host; Variant = $first.Variant; Runs = @($g.Group).Count; Ok = $ok.Count
        FirstPaintMs = Get-Median -Values @($ok | ForEach-Object { [double]$_.FirstPaintMs })
        ReadyMs = Get-Median -Values @($ok | Where-Object { $null -ne $_.ReadyMs } | ForEach-Object { [double]$_.ReadyMs })
        XamlEngineReadyMs = $null; ShellParsedMs = $null
    }
    foreach ($m in 'XamlEngineReady', 'ShellParsed') {
        $vals = @($ok | ForEach-Object { if ($_.Marks -and $_.Marks.PSObject.Properties[$m]) { [double]$_.Marks.$m } })
        if ($vals.Count -gt 0) { $row["${m}Ms"] = Get-Median -Values $vals }
    }
    $summary.Add([pscustomobject]$row)
}

$doc = [ordered]@{
    GeneratedUtc = [DateTime]::UtcNow.ToString('o'); Runs = $Runs
    Note = 'ms. Launcher: from the child process start. Other variants: from just before Add-Type of WPF (module imported before the clock).'
    Summary = @($summary); AllRuns = @($allRuns)
}
$doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'gui-startup.json') -Encoding UTF8

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('### GUI startup (median of {0} fresh processes)' -f $Runs)
$md.Add('')
$md.Add('First paint = first ContentRendered. Ready = the shell is in place and rendered (fully interactive); for XamlShellSync and CodeFrame it equals first paint (CodeFrame has no shell). Launcher is measured from process start (module import included); the other variants from just before Add-Type, with OmniDiag already imported. Target: under 2000 ms.')
$md.Add('')
$md.Add('| Host | Variant | First paint (ms) | Ready (ms) | XamlEngineReady (ms) | ShellParsed (ms) | OK runs |')
$md.Add('|---|---|---:|---:|---:|---:|---:|')
foreach ($s in $summary) {
    $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6}/{7} |' -f $s.Host, $s.Variant, $s.FirstPaintMs, $s.ReadyMs, $s.XamlEngineReadyMs, $s.ShellParsedMs, $s.Ok, $s.Runs))
}
$failed = @($allRuns | Where-Object { $_.Error })
if ($failed.Count -gt 0) {
    $md.Add('')
    $md.Add('Failed runs:')
    foreach ($f in $failed) { $md.Add(('- {0} {1} run {2}: {3}' -f $f.Host, $f.Variant, $f.Run, ($f.Error -replace '\s+', ' '))) }
}
$mdText = ($md -join "`n") + "`n"
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'gui-startup.md'), $mdText, [System.Text.UTF8Encoding]::new($false))
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $mdText -Encoding UTF8 }
Write-Host ''
Write-Host $mdText

try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
if (@($summary | Where-Object { $_.Ok -gt 0 }).Count -eq 0) { exit 2 }
exit 0
