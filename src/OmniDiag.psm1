<#
.SYNOPSIS
    OmniDiag root module: public entry points and high-level orchestration.

.DESCRIPTION
    Loaded via OmniDiag.psd1. The Core and CLI submodules are imported as nested
    modules (see the manifest), so their functions are available here and are
    re-exported per the manifest's FunctionsToExport list.

    Diagnostic modules under src/Modules are NOT loaded here; they are runtime
    plugins discovered by Get-OmniModule, which keeps the core closed to change
    when new modules are added.
#>

Set-StrictMode -Version Latest

# Default plugin directory (sibling 'Modules' folder).
$script:OmniModulesPath = Join-Path $PSScriptRoot 'Modules'

function Get-OmniVersion {
    <# .SYNOPSIS Returns the OmniDiag version from the module manifest. #>
    [OutputType([version])]
    param()
    $manifest = Join-Path $PSScriptRoot 'OmniDiag.psd1'
    return [version]((Import-PowerShellDataFile -Path $manifest).ModuleVersion)
}

function Invoke-OmniDiag {
    <#
    .SYNOPSIS
        Runs an end-to-end OmniDiag diagnostic session.

    .DESCRIPTION
        Convenience wrapper that builds a logger and context, discovers plugin
        modules, runs the session, and returns the OmniDiag.Session object. This
        is the single call the CLI launcher and (later) the GUI use to kick off
        a scan.

    .PARAMETER ModulesPath
        Folder(s) to discover diagnostic modules in. Defaults to src/Modules.

    .PARAMETER Range
        Time-range preset for time-aware modules (e.g. Event Logs).

    .PARAMETER IncludeCategory / ExcludeCategory
        Optional category filters.

    .PARAMETER Profile
        Focus the scan for an IT role such as HelpDesk, SystemsAdmin, or CloudAdmin.

    .PARAMETER Workflow
        Focus the scan on a daily task such as QuickTriage, SlowComputer, or
        LoginAndIdentity.

    .PARAMETER LogPath
        Path for the structured .jsonl log. Defaults to a per-run file under
        the user's temp folder.

    .PARAMETER CancellationToken
        Cooperative cancellation token (used by the GUI's Cancel button).

    .PARAMETER ProgressCallback
        Scriptblock invoked on module start/finish (see Invoke-OmniSession).

    .PARAMETER Quiet
        Suppress console logging from the logger.

    .EXAMPLE
        $session = Invoke-OmniDiag -Range Last7Days
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $ModulesPath = $script:OmniModulesPath,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')]
        [string] $Range = 'Last7Days',
        [string[]] $IncludeCategory,
        [string[]] $ExcludeCategory,
        [string[]] $IncludeModule,
        [ValidateSet('HelpDesk','DesktopSupport','SystemsAdmin','NetworkAdmin','SecurityAdmin','CloudAdmin','Full')]
        [string] $Profile,
        [ValidateSet('QuickTriage','SlowComputer','NetworkConnectivity','Printing','WindowsUpdate','LoginAndIdentity','StorageCleanup','SecurityPosture','CloudReadiness','FullScan')]
        [string] $Workflow,
        [string] $LogPath,
        [System.Threading.CancellationToken] $CancellationToken = ([System.Threading.CancellationToken]::None),
        [scriptblock] $ProgressCallback,
        [switch] $Quiet
    )

    if ($Profile -and $Workflow) { throw 'Choose either -Profile or -Workflow, not both.' }
    if (($Profile -or $Workflow) -and $IncludeModule) { throw 'Do not combine -Profile or -Workflow with -IncludeModule. Use one selection method.' }

    $scanPlan = $null
    if ($Profile) { $scanPlan = Get-OmniRoleProfile -Name $Profile }
    if ($Workflow) { $scanPlan = Get-OmniTaskWorkflow -Name $Workflow }
    if ($scanPlan -and @($scanPlan.Modules).Count -gt 0) { $IncludeModule = @($scanPlan.Modules) }

    if (-not $LogPath) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $LogPath = Join-Path ([System.IO.Path]::GetTempPath()) "OmniDiag/omnidiag-$stamp.jsonl"
    }

    $logger = New-OmniLogger -Path $LogPath -MinimumLevel Info -Console:(-not $Quiet)
    $logger.Info("OmniDiag $(Get-OmniVersion) starting.", 'OmniDiag')

    $timeRange = Get-OmniTimeRange -Preset $Range
    $context = New-OmniContext -Logger $logger -TimeRange $timeRange -CancellationToken $CancellationToken

    $registrations = Get-OmniModule -Path $ModulesPath -Logger $logger
    if (@($registrations).Count -eq 0) {
        $logger.Warn("No diagnostic modules found under: $($ModulesPath -join ', ')", 'OmniDiag')
    }

    $params = @{
        Registration = $registrations
        Context      = $context
    }
    if ($ProgressCallback) { $params.ProgressCallback = $ProgressCallback }
    if ($IncludeCategory)  { $params.IncludeCategory = $IncludeCategory }
    if ($ExcludeCategory)  { $params.ExcludeCategory = $ExcludeCategory }
    if ($IncludeModule)    { $params.IncludeModule = $IncludeModule }

    $session = Invoke-OmniSession @params
    Add-Member -InputObject $session -MemberType NoteProperty -Name LogPath -Value $LogPath -Force
    if ($scanPlan) {
        $planType = if ($Profile) { 'RoleProfile' } else { 'TaskWorkflow' }
        Add-Member -InputObject $session -MemberType NoteProperty -Name ScanPlan -Value ([pscustomobject]@{
            Type = $planType; Name = $scanPlan.Name; Description = $scanPlan.Description
        }) -Force
    }
    return $session
}

function Invoke-OmniRepairCenter {
    <#
    .SYNOPSIS
        Discovers repair plugins and (optionally) flags those recommended for a session.

    .DESCRIPTION
        Automation-friendly companion to Invoke-OmniDiag: returns the repair catalog as
        registrations (annotated with Recommended when a Session is supplied) without
        running anything. Feed the result to Invoke-OmniRepair to execute, or to
        Invoke-OmniRepairConsole for the interactive experience.

    .PARAMETER Session
        An OmniDiag.Session from Invoke-OmniDiag; used to flag Recommended repairs.

    .PARAMETER RepairsPath
        Folder of repair plugins. Defaults to src/Repairs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [pscustomobject] $Session,
        [string] $RepairsPath = (Join-Path $PSScriptRoot 'Repairs'),
        [pscustomobject] $Logger
    )

    if (-not $Logger) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $logFile = Join-Path ([System.IO.Path]::GetTempPath()) "OmniDiag/omnidiag-repair-$stamp.jsonl"
        $Logger = New-OmniLogger -Path $logFile -MinimumLevel Info -Console:$false
    }

    $repairs = @(Get-OmniRepair -Path $RepairsPath -Logger $Logger)
    if ($Session) { $repairs = @(Get-OmniApplicableRepair -Registration $repairs -Session $Session) }
    return $repairs
}

# NOTE: Do NOT call Export-ModuleMember here. When the root module calls it, the
# explicit list overrides the manifest's FunctionsToExport and the nested-module
# functions (Test-OmniIsAdministrator, Invoke-OmniSession, reporting, GUI, etc.)
# never reach the caller. Letting the manifest's FunctionsToExport govern exports
# correctly publishes all public functions across the root and nested modules.
