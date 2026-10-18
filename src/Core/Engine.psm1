<#
.SYNOPSIS
    The OmniDiag orchestration engine.

.DESCRIPTION
    Runs a set of registered diagnostic modules against a shared context,
    honoring cooperative cancellation, reporting progress via a callback, and
    capturing per-module errors instead of letting one module abort the session.
    Produces an OmniDiag.Session containing every result plus a scored summary.

    Execution model (0.6.0):

      * Parallel (default): a runspace pool with up to -MaxParallel workers (default:
        logical processors, capped at 8). Plugin PSModuleInfo objects and the logger's
        script methods are bound to the runspace that created them, so each worker
        imports the root module manifest once (InitialSessionState) and the plugin
        file by path, rebuilds the context from its plain pieces (time range, token,
        config copy, elevation, probes flag, host facts), and logs to an in-memory
        logger whose records the caller merges into its own logger. Only the caller's
        thread writes the log file, so lines are never interleaved.
      * Per-module TimeoutSec is enforced for pooled modules: a module that runs past
        its budget is stopped and recorded as Failed with Error 'Timed out after N s'
        (exit code 3, partial); the session continues.
      * The caller's thread runs a poll loop: it dispatches work, collects finished
        workers, enforces timeouts, honors the CancellationToken (no new work, running
        workers are stopped and recorded as Skipped/'Cancelled'), and invokes the
        progress callback, so callbacks never run on a worker thread.
      * Modules whose manifest sets Parallel = $false, and registrations that have no
        plugin file on disk (in-memory test modules), run on the caller's thread after
        the pool, in registration order. -MaxParallel 1 runs everything that way: the
        sequential engine, kept as the fallback (and used if the pool cannot start).
        Timeouts are not enforced on the caller's thread.
      * Results always come back in registration order, whatever finished first.

    Structured skips (Status 'Skipped', SkippedReason set, one Information finding):
      RequiresElevation  the module needs administrator rights and the process has none
      NotSupported       the module's SupportedPlatforms / SupportedArchitectures exclude
                         this host
      Cancelled          the scan was cancelled while the module was running
    Modules that a caller filters out (categories, -IncludeModule, Enabled = $false)
    are not part of the session and produce no result. A timeout is a failure, not a
    skip: Status 'Failed', Error 'Timed out after N s', SkippedReason $null.
#>

Set-StrictMode -Version Latest

# Root module manifest the workers import (src/OmniDiag.psd1).
$script:OmniEngineManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'OmniDiag.psd1'
$script:OmniEngineMaxParallelCap = 8
$script:OmniEnginePollMs = 25
$script:OmniEngineStopGraceMs = 2000

# Worker script. A string, not a scriptblock: scriptblocks are bound to the session
# state that created them and must not run on another runspace's thread.
$script:OmniEngineWorker = @'
param([string] $SourceFile, [hashtable] $ContextData)
$ErrorActionPreference = 'Stop'
$out = @{ Result = $null; Error = $null; Log = @() }
$logger = $null
try {
    $logger = New-OmniLogger -MinimumLevel $ContextData.LogLevel
    $config = @{}
    foreach ($key in @($ContextData.Config.Keys)) { $config[$key] = $ContextData.Config[$key] }
    $ctx = New-OmniContext -Logger $logger -TimeRange $ContextData.TimeRange -CancellationToken $ContextData.CancellationToken `
        -Config $config -NetworkProbes:([bool]$ContextData.NetworkProbes)
    foreach ($name in @($ContextData.Properties.Keys)) {
        Add-Member -InputObject $ctx -MemberType NoteProperty -Name $name -Value $ContextData.Properties[$name] -Force
    }
    $module = Import-Module -Name $SourceFile -PassThru -Force -DisableNameChecking
    $out.Result = & $module { param($c) Invoke-OmniModuleScan -Context $c } $ctx
} catch {
    $out.Error = $_.Exception.Message
}
if ($null -ne $logger) { $out.Log = $logger.Buffer.ToArray() }
$out
'@

# ---------------------------------------------------------------------------
# Helpers (internal)
# ---------------------------------------------------------------------------

function Get-OmniEngineValue {
    <# .SYNOPSIS Internal: StrictMode-safe property read (object or dictionary) with a default. #>
    param($InputObject, [string] $Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name) -and $null -ne $InputObject[$Name]) { return $InputObject[$Name] }
        return $Default
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-OmniDefaultParallelism {
    <#
    .SYNOPSIS
        Returns the engine's default worker count: the logical processor count, capped at 8.

    .EXAMPLE
        Invoke-OmniSession -Registration $regs -Context $ctx -MaxParallel (Get-OmniDefaultParallelism)
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int][Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, $script:OmniEngineMaxParallelCap))
}

function Set-OmniEngineStamp {
    <#
    .SYNOPSIS
        Internal: stamps contract identity (ModuleId, Group) and the skip reason on a result.
        Additive NoteProperties; existing consumers are unaffected.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mutates an in-memory result object only.')]
    param($Result, $Registration, [string] $SkippedReason)
    if ($null -eq $Result) { return }
    $identity = Resolve-OmniModuleIdentity -Name ([string]$Registration.Name) `
        -ModuleId ([string](Get-OmniEngineValue $Registration 'Id' '')) -Group ([string](Get-OmniEngineValue $Registration 'Group' ''))
    Add-Member -InputObject $Result -MemberType NoteProperty -Name ModuleId -Value $identity.Id -Force
    Add-Member -InputObject $Result -MemberType NoteProperty -Name Group -Value $identity.Group -Force
    $reason = if ($SkippedReason) { $SkippedReason } else { $null }
    Add-Member -InputObject $Result -MemberType NoteProperty -Name SkippedReason -Value $reason -Force
}

function Get-OmniEngineSkipReason {
    <#
    .SYNOPSIS
        Internal: why the engine must skip a module on this host ('NotSupported',
        'RequiresElevation'), or $null when it can run.
    #>
    param($Registration, $Context)

    $platform = [string](Get-OmniEngineValue $Context 'Platform' '')
    $platforms = @(Get-OmniEngineValue $Registration 'SupportedPlatforms' @())
    if ($platform -and $platforms.Count -gt 0 -and -not ($platforms -contains $platform)) { return 'NotSupported' }

    # Only the two contract architectures are judged; an unknown host value never skips.
    $arch = [string](Get-OmniEngineValue $Context 'Architecture' '')
    $archs = @(Get-OmniEngineValue $Registration 'SupportedArchitectures' @())
    if ($arch -in @('x64', 'arm64') -and $archs.Count -gt 0 -and -not ($archs -contains $arch)) { return 'NotSupported' }

    if ([bool](Get-OmniEngineValue $Registration 'RequiresAdmin' $false) -and -not [bool](Get-OmniEngineValue $Context 'IsAdmin' $false)) {
        return 'RequiresElevation'
    }
    return $null
}

function Get-OmniEngineSkipResult {
    <# .SYNOPSIS Internal: a finished Skipped result with one Information finding explaining why. #>
    param($Registration, $Context, [string] $Reason)

    $name = [string]$Registration.Name
    $category = [string]$Registration.Category
    $requiresAdmin = [bool](Get-OmniEngineValue $Registration 'RequiresAdmin' $false)
    $hadAdmin = [bool](Get-OmniEngineValue $Context 'IsAdmin' $false)
    $skip = New-OmniResult -ModuleName $name -Category $category -RequiresAdmin $requiresAdmin -HadAdmin $hadAdmin

    switch ($Reason) {
        'RequiresElevation' {
            $title = "$name skipped (requires administrator)"
            $detail = 'This check needs elevated rights to read its data source.'
            $recommendation = 'Re-run OmniDiag as Administrator to include this module.'
        }
        'NotSupported' {
            $platforms = (@(Get-OmniEngineValue $Registration 'SupportedPlatforms' @()) -join ', ')
            $archs = (@(Get-OmniEngineValue $Registration 'SupportedArchitectures' @()) -join ', ')
            $title = "$name skipped (not supported on this system)"
            $detail = "This check supports platforms [$platforms] and architectures [$archs]; this host is $([string](Get-OmniEngineValue $Context 'Platform' 'unknown')) $([string](Get-OmniEngineValue $Context 'Architecture' 'unknown'))."
            $recommendation = 'No action needed: the data this check reads does not exist on this kind of system.'
        }
        'Cancelled' {
            $title = "$name cancelled"
            $detail = 'The scan was cancelled while this check was running, so it has no results.'
            $recommendation = 'Run the scan again to include this module.'
        }
        default {
            $title = "$name skipped"
            $detail = "The engine skipped this check ($Reason)."
            $recommendation = ''
        }
    }
    Add-OmniFinding -Result $skip -Finding (New-OmniFinding -Title $title -Severity 'Information' -Component $category `
        -Detail $detail -Recommendation $recommendation)
    Complete-OmniResult -Result $skip -Status 'Skipped' | Out-Null
    return $skip
}

function Get-OmniEngineFailureResult {
    <# .SYNOPSIS Internal: a finished Failed result carrying the error text and one Error finding. #>
    param(
        $Registration, $Context, [string] $Message,
        [string] $Title,
        [string] $LikelyCause = 'The module raised an unhandled exception.',
        [string] $Recommendation = 'Check the OmniDiag log for the full error and stack trace.'
    )
    $name = [string]$Registration.Name
    if (-not $Title) { $Title = "$name failed to run" }
    $errResult = New-OmniResult -ModuleName $name -Category ([string]$Registration.Category) `
        -RequiresAdmin ([bool](Get-OmniEngineValue $Registration 'RequiresAdmin' $false)) -HadAdmin ([bool](Get-OmniEngineValue $Context 'IsAdmin' $false))
    $errResult.Error = $Message
    Add-OmniFinding -Result $errResult -Finding (New-OmniFinding -Title $Title -Severity 'Error' -Component ([string]$Registration.Category) `
        -Detail $Message -LikelyCause $LikelyCause -Recommendation $Recommendation)
    Complete-OmniResult -Result $errResult -Status 'Failed' | Out-Null
    return $errResult
}

function Complete-OmniEngineRun {
    <# .SYNOPSIS Internal: validates a module's return value and finalizes its timing if the module forgot. #>
    param($Result, $Registration)
    if ($null -eq $Result) { throw "Module '$($Registration.Name)' returned no result." }
    if (-not $Result.EndTime) { Complete-OmniResult -Result $Result | Out-Null }
    return $Result
}

function Invoke-OmniEngineInline {
    <# .SYNOPSIS Internal: runs one module on the caller's thread (sequential path). #>
    param($Registration, $Context)
    $log = $Context.Logger
    $log.Info("Running module '$($Registration.Name)'...", 'Engine')
    try {
        $result = & $Registration.ModuleInfo { param($ctx) Invoke-OmniModuleScan -Context $ctx } $Context
        $result = Complete-OmniEngineRun -Result $result -Registration $Registration
        $log.Info("Module '$($Registration.Name)' completed: status=$($result.Status), findings=$($result.Findings.Count), $($result.DurationMs)ms", 'Engine')
        return $result
    } catch {
        $log.Error("Module '$($Registration.Name)' threw: $($_.Exception.Message)", 'Engine')
        return (Get-OmniEngineFailureResult -Registration $Registration -Context $Context -Message $_.Exception.Message)
    }
}

function Get-OmniEngineContextData {
    <#
    .SYNOPSIS
        Internal: the plain, thread-safe pieces of a context that a worker rebuilds its
        own context from (no logger, no script methods, a shallow copy of Config).
    #>
    param($Context)
    $cfg = @{}
    $source = Get-OmniEngineValue $Context 'Config' $null
    if ($source -is [System.Collections.IDictionary]) { foreach ($k in @($source.Keys)) { $cfg[$k] = $source[$k] } }
    $props = @{}
    foreach ($p in $Context.PSObject.Properties) {
        if ($p.Name -in @('Logger', 'TimeRange', 'CancellationToken', 'Config', 'NetworkProbes')) { continue }
        $props[$p.Name] = $p.Value
    }
    $level = [string](Get-OmniEngineValue $Context.Logger 'MinimumLevel' 'Info')
    if ($level -notin @('Debug', 'Info', 'Warn', 'Error')) { $level = 'Info' }
    return @{
        TimeRange         = (Get-OmniEngineValue $Context 'TimeRange' $null)
        CancellationToken = $Context.CancellationToken
        Config            = $cfg
        NetworkProbes     = (Test-OmniNetworkProbeEnabled -Context $Context)
        Properties        = $props
        LogLevel          = $level
    }
}

function Open-OmniEnginePool {
    <#
    .SYNOPSIS
        Internal: opens a runspace pool whose runspaces import the root module manifest,
        and verifies that the import worked (throws otherwise, so the caller falls back
        to the sequential path).
    #>
    param([int] $Size)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule([string[]]@($script:OmniEngineManifest))
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($iss)
    [void]$pool.SetMaxRunspaces($Size)
    # Same COM apartment as the caller (STA under Windows PowerShell / the GUI, MTA under pwsh),
    # so modules keep the threading model they had on the sequential engine.
    try { $pool.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState() } catch { Write-Verbose "ApartmentState not set: $($_.Exception.Message)" }
    $pool.Open()

    $check = [System.Management.Automation.PowerShell]::Create()
    try {
        $check.RunspacePool = $pool
        [void]$check.AddScript("[bool](Get-Command -Name 'New-OmniContext' -ErrorAction SilentlyContinue)", $true)
        $ok = @($check.Invoke())
        if ($ok.Count -eq 0 -or -not [bool]$ok[0]) {
            try { $pool.Close(); $pool.Dispose() } catch { Write-Verbose $_.Exception.Message }
            throw "worker runspaces could not import '$script:OmniEngineManifest'"
        }
    } finally {
        $check.Dispose()
    }
    return $pool
}

function Invoke-OmniEngineTask {
    <# .SYNOPSIS Internal: starts one module on the pool; returns the task record. #>
    param($Pool, $Entry, [hashtable] $ContextData)
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($script:OmniEngineWorker, $true).AddArgument([string]$Entry.SourceFile).AddArgument($ContextData)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{
        Entry      = $Entry
        PowerShell = $ps
        Handle     = $handle
        Clock      = $clock
        TimeoutSec = [int]$Entry.TimeoutSec
    }
}

function Request-OmniEngineTaskStop {
    <# .SYNOPSIS Internal: asks a worker pipeline to stop without waiting for it. #>
    param($Task)
    try { [void]$Task.PowerShell.BeginStop($null, $null) } catch { Write-Verbose "Stop request failed: $($_.Exception.Message)" }
}

function Add-OmniEngineLogRecord {
    <# .SYNOPSIS Internal: merges one worker log record into the caller's logger. #>
    param($Logger, $Record)
    if ($null -eq $Record -or $null -eq $Logger) { return }
    if ($Logger.PSObject.Methods['AddRecord']) { $Logger.AddRecord($Record); return }
    $Logger.Log([string](Get-OmniEngineValue $Record 'Level' 'Info'), [string](Get-OmniEngineValue $Record 'Message' ''),
        [string](Get-OmniEngineValue $Record 'Component' ''), (Get-OmniEngineValue $Record 'Data' $null))
}

function Receive-OmniEngineTask {
    <# .SYNOPSIS Internal: collects a finished worker: merges its log and returns the module result. #>
    param($Task, $Context)
    $reg = $Task.Entry.Registration
    $log = $Context.Logger
    $out = $null
    $errText = $null
    try {
        $items = @($Task.PowerShell.EndInvoke($Task.Handle))
        if ($items.Count -gt 0) { $out = $items[$items.Count - 1] }
    } catch {
        $errText = $_.Exception.Message
    } finally {
        try { $Task.PowerShell.Dispose() } catch { Write-Verbose $_.Exception.Message }
    }

    if ($null -ne $out) {
        foreach ($rec in @($out.Log)) { Add-OmniEngineLogRecord -Logger $log -Record $rec }
        if ($out.Error) { $errText = [string]$out.Error }
    } elseif (-not $errText) {
        $errText = "Module '$($reg.Name)' returned no result."
    }

    if (-not $errText) {
        try {
            $result = Complete-OmniEngineRun -Result $out.Result -Registration $reg
            $log.Info("Module '$($reg.Name)' completed: status=$($result.Status), findings=$($result.Findings.Count), $($result.DurationMs)ms", 'Engine')
            return $result
        } catch {
            $errText = $_.Exception.Message
        }
    }
    $log.Error("Module '$($reg.Name)' threw: $errText", 'Engine')
    return (Get-OmniEngineFailureResult -Registration $reg -Context $Context -Message $errText)
}

function Close-OmniEnginePool {
    <#
    .SYNOPSIS
        Internal: disposes stopped workers and the pool. A worker that ignores Stop (stuck
        in a native call) must not hang the session, so the pool is then closed
        asynchronously instead.
    #>
    param($Pool, [object[]] $Abandoned)
    $stuck = $false
    $deadline = [DateTime]::UtcNow.AddMilliseconds($script:OmniEngineStopGraceMs)
    foreach ($t in @($Abandoned)) {
        if ($null -eq $t) { continue }
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($t.Handle.IsCompleted -or $t.Handle.AsyncWaitHandle.WaitOne($left)) {
            try { [void]$t.PowerShell.EndInvoke($t.Handle) } catch { Write-Verbose $_.Exception.Message }
            try { $t.PowerShell.Dispose() } catch { Write-Verbose $_.Exception.Message }
        } else {
            $stuck = $true
        }
    }
    if ($null -eq $Pool) { return }
    if ($stuck) {
        try { [void]$Pool.BeginClose($null, $null) } catch { Write-Verbose $_.Exception.Message }
    } else {
        try { $Pool.Close() } catch { Write-Verbose $_.Exception.Message }
        try { $Pool.Dispose() } catch { Write-Verbose $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

function Invoke-OmniSession {
    <#
    .SYNOPSIS
        Executes diagnostic modules and returns a complete session result.

    .DESCRIPTION
        Runs the enabled registrations (after the optional filters) on a runspace pool
        (see the module description for the execution model), enforcing per-module
        TimeoutSec, honoring the context's CancellationToken, and returning results in
        registration order. Modules that cannot run on this host are recorded as
        structured skips (SkippedReason RequiresElevation / NotSupported / Cancelled).

    .PARAMETER Registration
        Module registrations from Get-OmniModule.

    .PARAMETER Context
        Execution context from New-OmniContext (logger, time range, token, etc.).

    .PARAMETER ProgressCallback
        Optional scriptblock invoked on the caller's thread as each module starts and
        finishes. Receives a single PSCustomObject: @{ Index; Total; Name;
        Phase('Start'|'Done'|'Skipped'); PercentComplete; Result }. Index counts the
        modules finished so far. Used by the CLI and the GUI.

    .PARAMETER IncludeCategory
        Run only modules in these categories.

    .PARAMETER ExcludeCategory
        Skip modules in these categories.

    .PARAMETER IncludeModule
        Optional list of module display names to run. When supplied, only modules whose
        Name is in this list run (applied after the category filters). Lets a caller (the
        GUI scanner picker, or automation) run an arbitrary subset of individual scanners.

    .PARAMETER MaxParallel
        Worker count. 0 (default) = logical processors capped at 8
        (Get-OmniDefaultParallelism); 1 = the sequential engine on the caller's thread.

    .PARAMETER NetworkProbes
        Sets the context's NetworkProbes flag for this session (connectivity probes are
        opt-in). Without it the context's own value is used.

    .OUTPUTS
        OmniDiag.Session

    .EXAMPLE
        $ctx = New-OmniContext -Logger (New-OmniLogger)
        $session = Invoke-OmniSession -Registration (Get-OmniModule -Path .\src\Modules) -Context $ctx

    .EXAMPLE
        Invoke-OmniSession -Registration $regs -Context $ctx -MaxParallel 1   # sequential
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Registration,

        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [scriptblock] $ProgressCallback,

        [string[]] $IncludeCategory,

        [string[]] $ExcludeCategory,

        [string[]] $IncludeModule,

        [ValidateRange(0, 64)]
        [int] $MaxParallel = 0,

        [switch] $NetworkProbes
    )

    $log = $Context.Logger
    $token = $Context.CancellationToken
    if ($PSBoundParameters.ContainsKey('NetworkProbes')) {
        Add-Member -InputObject $Context -MemberType NoteProperty -Name NetworkProbes -Value ([bool]$NetworkProbes) -Force
    }
    if ($MaxParallel -lt 1) { $MaxParallel = Get-OmniDefaultParallelism }

    $modules = $Registration | Where-Object { $_.Enabled }
    if ($IncludeCategory) { $modules = $modules | Where-Object { $_.Category -in $IncludeCategory } }
    if ($ExcludeCategory) { $modules = $modules | Where-Object { $_.Category -notin $ExcludeCategory } }
    if ($IncludeModule)   { $modules = $modules | Where-Object { $_.Name -in $IncludeModule } }
    $modules = @($modules)

    $sessionStart = Get-Date
    $total = $modules.Count
    $slots = [object[]]::new($total)
    $cancelled = $false
    $completed = 0

    # Plan: skip reason, and whether the module can go to the pool.
    $entries = @(for ($i = 0; $i -lt $total; $i++) {
        $reg = $modules[$i]
        $source = [string](Get-OmniEngineValue $reg 'SourceFile' '')
        $pooled = ($MaxParallel -gt 1) -and [bool](Get-OmniEngineValue $reg 'Parallel' $true) -and
            $source -and (Test-Path -LiteralPath $source -PathType Leaf)
        [pscustomobject]@{
            Index        = $i
            Registration = $reg
            SkipReason   = (Get-OmniEngineSkipReason -Registration $reg -Context $Context)
            Pooled       = [bool]$pooled
            SourceFile   = $source
            TimeoutSec   = [int](Get-OmniEngineValue $reg 'TimeoutSec' 60)
        }
    })
    $poolEntries = @($entries | Where-Object { -not $_.SkipReason -and $_.Pooled })
    $workers = [int][Math]::Min($MaxParallel, [Math]::Max(1, $poolEntries.Count))

    $mode = if ($poolEntries.Count -gt 0) { "parallel, $workers worker(s)" } else { 'sequential' }
    $log.Info("Starting diagnostic session: $total module(s), range '$($Context.TimeRange.Label)', admin=$($Context.IsAdmin), probes=$(Test-OmniNetworkProbeEnabled -Context $Context), $mode", 'Engine')

    $report = {
        param($idx, $name, $phase, $result)
        if ($ProgressCallback) {
            $percent = if ($total -gt 0) { [int]([math]::Round(($idx / $total) * 100)) } else { 100 }
            $payload = [pscustomobject]@{
                Index           = $idx
                Total           = $total
                Name            = $name
                Phase           = $phase
                PercentComplete = $percent
                Result          = $result
            }
            try { & $ProgressCallback $payload } catch { $log.Warn("Progress callback threw: $($_.Exception.Message)", 'Engine') }
        }
    }

    $recordSkip = {
        param($entry)
        $reg = $entry.Registration
        & $report $completed $reg.Name 'Start' $null
        $skip = Get-OmniEngineSkipResult -Registration $reg -Context $Context -Reason $entry.SkipReason
        Set-OmniEngineStamp -Result $skip -Registration $reg -SkippedReason $entry.SkipReason
        $slots[$entry.Index] = $skip
        $log.Warn("Skipped '$($reg.Name)': $($entry.SkipReason).", 'Engine')
    }

    if ($poolEntries.Count -eq 0) {
        # Sequential engine: everything on the caller's thread, in order.
        foreach ($e in $entries) {
            if ($token.IsCancellationRequested) {
                $log.Warn("Cancellation requested; stopping before module '$($e.Registration.Name)'.", 'Engine')
                $cancelled = $true
                break
            }
            if ($e.SkipReason) {
                & $recordSkip $e
                $completed++
                & $report $completed $e.Registration.Name 'Skipped' $slots[$e.Index]
                continue
            }
            & $report $completed $e.Registration.Name 'Start' $null
            $res = Invoke-OmniEngineInline -Registration $e.Registration -Context $Context
            Set-OmniEngineStamp -Result $res -Registration $e.Registration
            $slots[$e.Index] = $res
            $completed++
            & $report $completed $e.Registration.Name 'Done' $res
        }
    } else {
        $inline = [System.Collections.Generic.List[object]]::new()

        # 1. Engine skips (no worker needed).
        foreach ($e in $entries) {
            if (-not $e.SkipReason) { continue }
            if ($token.IsCancellationRequested) { $cancelled = $true; break }
            & $recordSkip $e
            $completed++
            & $report $completed $e.Registration.Name 'Skipped' $slots[$e.Index]
        }

        # 2. The pool.
        $pool = $null
        if (-not $cancelled -and -not $token.IsCancellationRequested) {
            try {
                $pool = Open-OmniEnginePool -Size $workers
            } catch {
                $log.Warn("Parallel engine unavailable ($($_.Exception.Message)); running modules sequentially.", 'Engine')
                $pool = $null
            }
        }
        if ($null -eq $pool) {
            foreach ($e in $entries) { if (-not $e.SkipReason) { $inline.Add($e) } }
        } else {
            foreach ($e in $entries) { if (-not $e.SkipReason -and -not $e.Pooled) { $inline.Add($e) } }
            $contextData = Get-OmniEngineContextData -Context $Context
            $queue = [System.Collections.Generic.Queue[object]]::new()
            foreach ($e in $poolEntries) { $queue.Enqueue($e) }
            $running = [System.Collections.Generic.List[object]]::new()
            $abandoned = [System.Collections.Generic.List[object]]::new()
            try {
                while ($queue.Count -gt 0 -or $running.Count -gt 0) {
                    if ($token.IsCancellationRequested) {
                        $log.Warn("Cancellation requested; stopping $($running.Count) running module(s), $($queue.Count) not started.", 'Engine')
                        $cancelled = $true
                        $queue.Clear()
                        foreach ($t in $running) {
                            Request-OmniEngineTaskStop -Task $t
                            $abandoned.Add($t)
                            $reg = $t.Entry.Registration
                            $skip = Get-OmniEngineSkipResult -Registration $reg -Context $Context -Reason 'Cancelled'
                            Set-OmniEngineStamp -Result $skip -Registration $reg -SkippedReason 'Cancelled'
                            $slots[$t.Entry.Index] = $skip
                            $completed++
                            & $report $completed $reg.Name 'Skipped' $skip
                        }
                        $running.Clear()
                        break
                    }

                    while ($queue.Count -gt 0 -and $running.Count -lt $workers) {
                        $e = $queue.Dequeue()
                        & $report $completed $e.Registration.Name 'Start' $null
                        $log.Info("Running module '$($e.Registration.Name)' (worker)...", 'Engine')
                        $running.Add((Invoke-OmniEngineTask -Pool $pool -Entry $e -ContextData $contextData))
                    }

                    $still = [System.Collections.Generic.List[object]]::new()
                    $finished = [System.Collections.Generic.List[object]]::new()
                    foreach ($t in $running) {
                        if ($t.Handle.IsCompleted -or $t.Clock.Elapsed.TotalSeconds -ge $t.TimeoutSec) { $finished.Add($t) } else { $still.Add($t) }
                    }
                    $running = $still

                    foreach ($t in $finished) {
                        $reg = $t.Entry.Registration
                        if ($t.Handle.IsCompleted) {
                            $res = Receive-OmniEngineTask -Task $t -Context $Context
                        } else {
                            Request-OmniEngineTaskStop -Task $t
                            $abandoned.Add($t)
                            $msg = 'Timed out after {0} s' -f $t.TimeoutSec
                            $log.Error("Module '$($reg.Name)' timed out after $($t.TimeoutSec) s; its worker was stopped.", 'Engine')
                            $res = Get-OmniEngineFailureResult -Registration $reg -Context $Context -Message $msg `
                                -Title "$($reg.Name) timed out" `
                                -LikelyCause "The module ran longer than its $($t.TimeoutSec)-second budget (TimeoutSec), for example on a slow or very busy system." `
                                -Recommendation "Run this module on its own (omnidiag scan --module $([string](Get-OmniEngineValue $reg 'Id' $reg.Name))) and check the OmniDiag log."
                        }
                        Set-OmniEngineStamp -Result $res -Registration $reg
                        $slots[$t.Entry.Index] = $res
                        $completed++
                        & $report $completed $reg.Name 'Done' $res
                    }

                    if ($running.Count -gt 0) { [System.Threading.Thread]::Sleep($script:OmniEnginePollMs) }
                }
            } finally {
                foreach ($t in $running) { Request-OmniEngineTaskStop -Task $t; $abandoned.Add($t) }
                Close-OmniEnginePool -Pool $pool -Abandoned $abandoned.ToArray()
            }
        }

        # 3. Modules that must run on the caller's thread (Parallel = $false, or no plugin file).
        foreach ($e in $inline) {
            if ($cancelled) { break }
            if ($token.IsCancellationRequested) {
                $log.Warn("Cancellation requested; stopping before module '$($e.Registration.Name)'.", 'Engine')
                $cancelled = $true
                break
            }
            & $report $completed $e.Registration.Name 'Start' $null
            $res = Invoke-OmniEngineInline -Registration $e.Registration -Context $Context
            Set-OmniEngineStamp -Result $res -Registration $e.Registration
            $slots[$e.Index] = $res
            $completed++
            & $report $completed $e.Registration.Name 'Done' $res
        }
    }

    $results = @($slots | Where-Object { $null -ne $_ })

    $sessionEnd = Get-Date
    $summary = if ($results.Count -gt 0) { $results | Get-OmniHealthScore } else { $null }

    $session = [pscustomobject]@{
        PSTypeName   = 'OmniDiag.Session'
        StartTime    = $sessionStart
        EndTime      = $sessionEnd
        DurationMs   = [int]([math]::Round(($sessionEnd - $sessionStart).TotalMilliseconds))
        Cancelled    = $cancelled
        TimeRange    = $Context.TimeRange
        Host         = $Context.Host
        IsAdmin      = $Context.IsAdmin
        Results      = $results
        Summary      = $summary
    }

    $log.Info("Session finished: score=$(if($summary){$summary.Score}else{'n/a'}), duration=$($session.DurationMs)ms, cancelled=$cancelled", 'Engine')
    return $session
}

Export-ModuleMember -Function 'Invoke-OmniSession', 'Get-OmniDefaultParallelism'
