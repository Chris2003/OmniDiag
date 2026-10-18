<#
.SYNOPSIS
    Public PowerShell surface for module groups: Get-OmniDiagGroup, Get-OmniDiagModule,
    Invoke-OmniDiagScan, and one Get-OmniDiag<Group> cmdlet per v1.0 group.

.DESCRIPTION
    Thin, pipeline-friendly wrappers over discovery (Get-OmniModule), the engine
    (Invoke-OmniSession), and the report schema v1 projection (ConvertTo-OmniReportV1).
    By default the scan cmdlets write v1-shaped finding objects (type name
    OmniDiag.V1.Finding) to the pipeline; -AsSession returns the native OmniDiag.Session
    instead (for Export-OmniReport, Save-OmniSession, Get-OmniExitCode, ...).

    Every scan runs locally. Connectivity probes run only with -NetworkProbes
    (decision 1).
#>

Set-StrictMode -Version Latest

$script:OmniGroupModulesPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules'

# One-line description per group (ids and display names live in Core/Registry).
$script:OmniGroupDescriptions = @{
    system      = 'Operating system, hardware, firmware, and device inventory.'
    performance = 'CPU, memory, processes, and boot and startup performance.'
    services    = 'Windows services and device drivers: state, start type, and failures.'
    startup     = 'Autostart and persistence: Run keys, startup folders, scheduled tasks.'
    events      = 'Windows event logs: errors and warnings grouped and translated.'
    reliability = 'Crashes, hangs, unexpected shutdowns, and stability history.'
    storage     = 'Disks, volumes, free space, disk health, and space usage.'
    network     = 'Adapters, IP and DNS configuration, Wi-Fi, proxy, VPN, shares; opt-in connectivity probes.'
    updates     = 'Windows Update state and policy, component store and system health.'
    security    = 'Defender, firewall, BitLocker, certificates, and security posture.'
    extras      = 'Everything else: identity and cloud management, peripherals, software, tools.'
}

function Get-OmniGroupScanRegistration {
    <# .SYNOPSIS Internal: discover enabled scanners (quiet logger). #>
    param([string[]] $ModulesPath, $Logger)
    if (-not $Logger) { $Logger = New-OmniLogger -MinimumLevel Error }
    return @(Get-OmniModule -Path $ModulesPath -Logger $Logger | Where-Object { $_.Enabled })
}

function Get-OmniDiagGroup {
    <#
    .SYNOPSIS
        Lists the OmniDiag module groups with their scanners.

    .DESCRIPTION
        Returns one object per v1.0 group (plus 'extras') in display order: Id, Name,
        Description, ScannerIds, and ScannerCount. The ids are the values accepted by
        Invoke-OmniDiagScan -Group, Get-OmniDiagModule -Group, and 'omnidiag <group>'.

    .PARAMETER Id
        Only these group ids.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagGroup | Format-Table Id, ScannerCount, Name

    .EXAMPLE
        (Get-OmniDiagGroup -Id network).ScannerIds
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Id,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    $regs = Get-OmniGroupScanRegistration -ModulesPath $ModulesPath
    foreach ($g in @(Get-OmniGroup)) {
        if ($Id -and $g.Id -notin $Id) { continue }
        $ids = [string[]]@($regs | Where-Object { $_.Group -eq $g.Id } | ForEach-Object { $_.Id })
        [pscustomobject]@{
            PSTypeName   = 'OmniDiag.GroupInfo'
            Id           = $g.Id
            Name         = $g.DisplayName
            Description  = [string]$script:OmniGroupDescriptions[$g.Id]
            ScannerIds   = $ids
            ScannerCount = $ids.Count
        }
    }
}

function Get-OmniDiagModule {
    <#
    .SYNOPSIS
        Lists the OmniDiag scanners as plain objects.

    .DESCRIPTION
        Returns one object per discovered scanner: Id, Name, Group, Category,
        Description, RequiresElevation, NetworkAccess, TimeoutSec, and
        SupportedArchitectures. NetworkAccess other than 'None' means the scanner has a
        connectivity probe that runs only with -NetworkProbes / --network-probes.

    .PARAMETER Group
        Only scanners in these groups (e.g. network, storage).

    .PARAMETER Id
        Only these scanner ids (or display names). Wildcards are allowed.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagModule -Group network | Format-Table Id, NetworkAccess, RequiresElevation

    .EXAMPLE
        Get-OmniDiagModule -Id 'storage.*'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Group,
        [string[]] $Id,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    foreach ($g in @($Group)) {
        if ($g -and $g.ToLowerInvariant() -notin (Get-OmniGroupNames)) {
            throw [System.ArgumentException]::new("Unknown group '$g'. Valid: $((Get-OmniGroupNames) -join ', ').")
        }
    }
    foreach ($r in (Get-OmniGroupScanRegistration -ModulesPath $ModulesPath)) {
        if ($Group -and $r.Group -notin $Group) { continue }
        if ($Id) {
            $hit = $false
            foreach ($pattern in $Id) { if ($r.Id -like $pattern -or $r.Name -like $pattern) { $hit = $true; break } }
            if (-not $hit) { continue }
        }
        [pscustomobject]@{
            PSTypeName             = 'OmniDiag.ModuleInfo'
            Id                     = $r.Id
            Name                   = $r.Name
            Group                  = $r.Group
            Category               = $r.Category
            Description            = $r.Description
            RequiresElevation      = [bool]$r.RequiresElevation
            NetworkAccess          = $r.NetworkAccess
            TimeoutSec             = [int]$r.TimeoutSec
            SupportedArchitectures = [string[]]@($r.SupportedArchitectures)
        }
    }
}

function ConvertTo-OmniDiagFindingObject {
    <#
    .SYNOPSIS
        Internal: flattens a session into v1-shaped finding objects
        (type OmniDiag.V1.Finding), one per finding, in module order.
    #>
    param($Session, [bool] $IncludePassed)
    $v1 = ConvertTo-OmniReportV1 -Session $Session
    foreach ($m in @($v1.modules)) {
        foreach ($f in @($m.findings)) {
            if ($f.passed -and -not $IncludePassed) { continue }
            [pscustomobject]@{
                PSTypeName     = 'OmniDiag.V1.Finding'
                id             = $f.id
                moduleId       = $f.moduleId
                moduleName     = $m.name
                group          = $m.group
                moduleStatus   = $m.status
                skippedReason  = $m.skippedReason
                title          = $f.title
                severity       = $f.severity
                severityNative = $f.severityNative
                passed         = [bool]$f.passed
                component      = $f.component
                evidence       = $f.evidence
                likelyCause    = $f.likelyCause
                recommendation = $f.recommendation
                confidence     = $f.confidence
            }
        }
    }
}

function Invoke-OmniDiagScan {
    <#
    .SYNOPSIS
        Runs OmniDiag scanners and writes their findings to the pipeline.

    .DESCRIPTION
        Selects scanners by group and/or id (none = every scanner), runs them on the
        parallel engine, and writes one OmniDiag.V1.Finding object per finding (the
        report schema v1 shape plus moduleName, group, moduleStatus, and skippedReason).
        Passing checks (severityNative 'Pass') are left out unless -IncludePassed.
        Skipped and failed modules still appear through their Information / Critical
        finding, and a warning names them. With -AsSession the native OmniDiag.Session
        is returned instead (all findings, for Export-OmniReport, Save-OmniSession,
        Get-OmniExitCode, ...).

        Everything runs locally. Connectivity probes (gateway and 1.1.1.1 ping, DNS
        resolution of www.microsoft.com, domain secure channel) run only with
        -NetworkProbes.

    .PARAMETER Group
        Group ids to run (system, performance, services, startup, events, reliability,
        storage, network, updates, security, extras). Combined with -Module as a union.

    .PARAMETER Module
        Scanner ids (e.g. storage.disk) or display names to run.

    .PARAMETER NetworkProbes
        Also run connectivity probes (contacts the network).

    .PARAMETER MaxParallel
        Engine worker count. 0 (default) = logical processors capped at 8; 1 = sequential.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER IncludePassed
        Also write passing checks (passed = $true) to the pipeline.

    .PARAMETER AsSession
        Return the native OmniDiag.Session instead of finding objects.

    .PARAMETER Config
        Per-run module options, e.g. @{ ProbeTargets = @{ PublicAddress = '9.9.9.9' } }.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .PARAMETER CancellationToken
        Cooperative cancellation token.

    .PARAMETER Profile
        Run a role profile (HelpDesk, DesktopSupport, SystemsAdmin, NetworkAdmin,
        SecurityAdmin, CloudAdmin, Full). Cannot be combined with -Workflow, -Group,
        or -Module.

    .PARAMETER Workflow
        Run a task workflow (QuickTriage, SlowComputer, NetworkConnectivity, Printing,
        WindowsUpdate, LoginAndIdentity, StorageCleanup, SecurityPosture, CloudReadiness,
        FullScan). Cannot be combined with -Profile, -Group, or -Module.

    .PARAMETER ElevatedOnly
        Run only the selected scanners that require elevation. Throws an
        UnauthorizedAccessException when the process is not elevated.

    .PARAMETER ProgressCallback
        Optional scriptblock invoked as each scanner starts and finishes (see
        Invoke-OmniSession). Without it, Write-Progress shows the progress.

    .OUTPUTS
        OmniDiag.V1.Finding objects, or one OmniDiag.Session with -AsSession.

    .EXAMPLE
        Invoke-OmniDiagScan -Group storage, performance | Where-Object severity -ne 'Info'

    .EXAMPLE
        Invoke-OmniDiagScan -Module network.dns-resolver -NetworkProbes -IncludePassed

    .EXAMPLE
        $session = Invoke-OmniDiagScan -AsSession; Export-OmniDiagReport -Session $session -Format Html

    .EXAMPLE
        $session = Invoke-OmniDiagScan -Workflow SlowComputer -AsSession
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Group,
        [string[]] $Module,
        [switch] $NetworkProbes,
        [ValidateRange(0, 64)]
        [int] $MaxParallel = 0,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')]
        [string] $Range = 'Last7Days',
        [switch] $IncludePassed,
        [switch] $AsSession,
        [hashtable] $Config = @{},
        [string[]] $ModulesPath = $script:OmniGroupModulesPath,
        [System.Threading.CancellationToken] $CancellationToken = ([System.Threading.CancellationToken]::None),
        [ValidateSet('HelpDesk', 'DesktopSupport', 'SystemsAdmin', 'NetworkAdmin', 'SecurityAdmin', 'CloudAdmin', 'Full')]
        [string] $Profile,
        [ValidateSet('QuickTriage', 'SlowComputer', 'NetworkConnectivity', 'Printing', 'WindowsUpdate', 'LoginAndIdentity', 'StorageCleanup', 'SecurityPosture', 'CloudReadiness', 'FullScan')]
        [string] $Workflow,
        [switch] $ElevatedOnly,
        [scriptblock] $ProgressCallback
    )

    if ($Profile -and $Workflow) { throw [System.ArgumentException]::new('Choose either -Profile or -Workflow, not both.') }
    if (($Profile -or $Workflow) -and (@($Group | Where-Object { $_ }).Count -gt 0 -or @($Module | Where-Object { $_ }).Count -gt 0)) {
        throw [System.ArgumentException]::new('Do not combine -Profile or -Workflow with -Group or -Module.')
    }
    if ($ElevatedOnly -and -not (Test-OmniIsAdministrator)) {
        throw [System.UnauthorizedAccessException]::new('-ElevatedOnly runs only the scanners that need elevation; start PowerShell as administrator.')
    }
    $plan = $null; $planInfo = $null
    if ($Profile) { $plan = Get-OmniRoleProfile -Name $Profile; $planInfo = [pscustomobject]@{ Type = 'RoleProfile'; Name = $plan.Name; Description = $plan.Description } }
    if ($Workflow) { $plan = Get-OmniTaskWorkflow -Name $Workflow; $planInfo = [pscustomobject]@{ Type = 'TaskWorkflow'; Name = $plan.Name; Description = $plan.Description } }

    $groups = @($Group | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($g in $groups) {
        if ($g -notin (Get-OmniGroupNames)) {
            throw [System.ArgumentException]::new("Unknown group '$g'. Valid: $((Get-OmniGroupNames) -join ', ').")
        }
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $logger = New-OmniLogger -Path (Get-OmniDataPath -Kind Logs -ChildPath "omnidiag-scan-$stamp.jsonl") -MinimumLevel Info
    $regs = Get-OmniGroupScanRegistration -ModulesPath $ModulesPath -Logger $logger

    $explicit = @{}
    foreach ($m in @($Module | Where-Object { $_ })) {
        $hit = @($regs | Where-Object { $_.Id -ieq $m -or $_.Name -ieq $m })
        if ($hit.Count -eq 0) { throw [System.ArgumentException]::new("Unknown module '$m'. Run Get-OmniDiagModule for ids.") }
        foreach ($h in $hit) { $explicit[$h.Id] = $true }
    }
    $selected = if ($groups.Count -gt 0 -or $explicit.Count -gt 0) {
        @($regs | Where-Object { $_.Group -in $groups -or $explicit.ContainsKey($_.Id) })
    } elseif ($plan -and @($plan.Modules).Count -gt 0) {
        @($regs | Where-Object { $_.Name -in @($plan.Modules) })
    } else { $regs }
    if ($ElevatedOnly) { $selected = @($selected | Where-Object { $_.RequiresElevation }) }
    if (@($selected).Count -eq 0) { throw [System.ArgumentException]::new('No scanners match the selection.') }

    $context = New-OmniContext -Logger $logger -TimeRange (Get-OmniTimeRange -Preset $Range) `
        -CancellationToken $CancellationToken -Config $Config -NetworkProbes:$NetworkProbes
    $activity = 'OmniDiag scan'
    # No GetNewClosure(): on Windows PowerShell 5.1 it re-validates this function's
    # [ValidateSet] parameters (an unset -Profile is '') and throws.
    $progress = {
        param($p)
        $status = if ($p.Phase -eq 'Start') { "Running $($p.Name)" } else { "$($p.Name): $($p.Phase)" }
        Write-Progress -Activity 'OmniDiag scan' -Status $status -PercentComplete ([Math]::Min(100, [Math]::Max(0, [int]$p.PercentComplete)))
    }
    if ($ProgressCallback) { $progress = $ProgressCallback }
    try {
        $session = Invoke-OmniSession -Registration $selected -Context $context -ProgressCallback $progress -MaxParallel $MaxParallel
    } finally {
        if (-not $ProgressCallback) { Write-Progress -Activity $activity -Completed }
    }
    Add-Member -InputObject $session -MemberType NoteProperty -Name LogPath -Value $logger.Path -Force
    if ($planInfo) { Add-Member -InputObject $session -MemberType NoteProperty -Name ScanPlan -Value $planInfo -Force }

    if ($AsSession) { return $session }

    $notRun = @($session.Results | Where-Object { $_.Status -in @('Skipped', 'Failed') })
    if ($notRun.Count -gt 0) {
        $names = ($notRun | ForEach-Object {
                $why = if ($_.Status -eq 'Failed') { 'failed' } elseif ($_.SkippedReason) { [string]$_.SkippedReason } else { 'skipped' }
                '{0} ({1})' -f $_.ModuleId, $why
            }) -join ', '
        Write-Warning ("{0} scanner(s) did not complete: {1}." -f $notRun.Count, $names)
    }
    ConvertTo-OmniDiagFindingObject -Session $session -IncludePassed ([bool]$IncludePassed)
}

# ---------------------------------------------------------------------------
# One cmdlet per group (thin wrappers over Invoke-OmniDiagScan -Group)
# ---------------------------------------------------------------------------

function Invoke-OmniDiagGroupScan {
    <# .SYNOPSIS Internal: shared body of the Get-OmniDiag<Group> cmdlets. #>
    param([string] $GroupId, [System.Collections.IDictionary] $Bound)
    $p = @{}
    foreach ($k in @($Bound.Keys)) { $p[[string]$k] = $Bound[$k] }
    Invoke-OmniDiagScan -Group $GroupId @p
}

function Get-OmniDiagSystem {
    <#
    .SYNOPSIS
        Runs the System group: operating system, hardware, firmware, and device inventory.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group system. Writes v1 finding objects; passing
        checks are left out unless -IncludePassed.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagSystem -IncludePassed | Format-Table severity, title
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'system' -Bound $PSBoundParameters
}

function Get-OmniDiagPerformance {
    <#
    .SYNOPSIS
        Runs the Performance group: CPU, memory, processes, and startup performance.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group performance. Writes v1 finding objects;
        passing checks are left out unless -IncludePassed.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagPerformance | Where-Object severity -eq 'Warning'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'performance' -Bound $PSBoundParameters
}

function Get-OmniDiagServices {
    <#
    .SYNOPSIS
        Runs the Services and drivers group.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group services. Writes v1 finding objects; passing
        checks are left out unless -IncludePassed.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagServices | Select-Object severity, title, recommendation
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Named after the services group (public API, decision 11).')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'services' -Bound $PSBoundParameters
}

function Get-OmniDiagStartup {
    <#
    .SYNOPSIS
        Runs the Startup and persistence group.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group startup. Writes v1 finding objects; passing
        checks are left out unless -IncludePassed.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagStartup -IncludePassed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'startup' -Bound $PSBoundParameters
}

function Get-OmniDiagEvents {
    <#
    .SYNOPSIS
        Runs the Event logs group.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group events. Writes v1 finding objects; passing
        checks are left out unless -IncludePassed.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagEvents -Range Last24Hours | Where-Object severity -eq 'Critical'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Named after the events group (public API, decision 11).')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'events' -Bound $PSBoundParameters
}

function Get-OmniDiagReliability {
    <#
    .SYNOPSIS
        Runs the Reliability group: crashes, hangs, and unexpected shutdowns.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group reliability. Writes v1 finding objects;
        passing checks are left out unless -IncludePassed.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagReliability -Range Last30Days
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'reliability' -Bound $PSBoundParameters
}

function Get-OmniDiagStorage {
    <#
    .SYNOPSIS
        Runs the Storage group: disks, volumes, free space, and disk health.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group storage. Writes v1 finding objects; passing
        checks are left out unless -IncludePassed.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagStorage | Format-List title, evidence, recommendation
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'storage' -Bound $PSBoundParameters
}

function Get-OmniDiagNetwork {
    <#
    .SYNOPSIS
        Runs the Network group: adapters, IP and DNS configuration, Wi-Fi, proxy, VPN.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group network. Runs locally by default; with
        -NetworkProbes it also pings the default gateway and 1.1.1.1 and resolves
        www.microsoft.com (targets configurable via -Config @{ ProbeTargets = @{...} }).
        Writes v1 finding objects; passing checks are left out unless -IncludePassed.

    .PARAMETER NetworkProbes
        Also run the connectivity probes (contacts the network).

    .PARAMETER Config
        Per-run module options, e.g. @{ ProbeTargets = @{ PublicAddress = '9.9.9.9'; DnsName = 'intranet.example' } }.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagNetwork

    .EXAMPLE
        Get-OmniDiagNetwork -NetworkProbes -IncludePassed | Format-Table severity, moduleId, title
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $NetworkProbes,
        [hashtable] $Config,
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'network' -Bound $PSBoundParameters
}

function Get-OmniDiagUpdates {
    <#
    .SYNOPSIS
        Runs the Windows Update and health group.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group updates. Writes v1 finding objects; passing
        checks are left out unless -IncludePassed.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagUpdates -IncludePassed
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Named after the updates group (public API, decision 11).')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'updates' -Bound $PSBoundParameters
}

function Get-OmniDiagSecurity {
    <#
    .SYNOPSIS
        Runs the Security group: Defender, firewall, BitLocker, certificates, posture.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group security. Runs locally by default; with
        -NetworkProbes the Local Admins scanner also lists the Administrators group on a
        domain- or Entra-joined device (resolving member names can query a domain
        controller). Writes v1 finding objects; passing checks are left out unless
        -IncludePassed.

    .PARAMETER NetworkProbes
        Also run the opt-in checks that can contact the network.

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagSecurity | Where-Object severity -in 'Warning', 'Critical'

    .EXAMPLE
        Get-OmniDiagSecurity -NetworkProbes -IncludePassed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $NetworkProbes,
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'security' -Bound $PSBoundParameters
}

function Get-OmniDiagExtras {
    <#
    .SYNOPSIS
        Runs the Extras group: identity and cloud management, peripherals, software, tools.

    .DESCRIPTION
        Same as Invoke-OmniDiagScan -Group extras. Runs locally by default; with
        -NetworkProbes the Active Directory scanner also checks the domain secure
        channel (contacts a domain controller). Writes v1 finding objects; passing
        checks are left out unless -IncludePassed.

    .PARAMETER NetworkProbes
        Also run the connectivity probes (contacts the network).

    .PARAMETER IncludePassed
        Also write passing checks.

    .PARAMETER Range
        Event time range: Last24Hours, Last7Days (default), Last30Days.

    .PARAMETER MaxParallel
        Engine worker count (0 = default, 1 = sequential).

    .PARAMETER AsSession
        Return the native OmniDiag.Session.

    .PARAMETER ModulesPath
        Scanner plugin folder(s). Default: the bundled src/Modules.

    .EXAMPLE
        Get-OmniDiagExtras -NetworkProbes
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Named after the extras group (public API, decision 11).')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $NetworkProbes,
        [switch] $IncludePassed,
        [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')] [string] $Range = 'Last7Days',
        [ValidateRange(0, 64)] [int] $MaxParallel = 0,
        [switch] $AsSession,
        [string[]] $ModulesPath = $script:OmniGroupModulesPath
    )
    Invoke-OmniDiagGroupScan -GroupId 'extras' -Bound $PSBoundParameters
}

Export-ModuleMember -Function @(
    'Get-OmniDiagGroup', 'Get-OmniDiagModule', 'Invoke-OmniDiagScan',
    'Get-OmniDiagSystem', 'Get-OmniDiagPerformance', 'Get-OmniDiagServices', 'Get-OmniDiagStartup',
    'Get-OmniDiagEvents', 'Get-OmniDiagReliability', 'Get-OmniDiagStorage', 'Get-OmniDiagNetwork',
    'Get-OmniDiagUpdates', 'Get-OmniDiagSecurity', 'Get-OmniDiagExtras'
)
