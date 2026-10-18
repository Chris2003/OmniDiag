<#
.SYNOPSIS
    Plugin discovery and the OmniDiag diagnostic-module contract.

.DESCRIPTION
    Implements the plugin architecture requirement: new diagnostic modules can be
    dropped into src/Modules without touching the core. Each module is a .psm1 that
    exports exactly two convention-based functions:

        Get-OmniModuleManifest   -> [hashtable] metadata describing the module
        Invoke-OmniModuleScan    -> [OmniDiag.Result] produced from a context

    Functions are invoked inside each module's own session state via the call
    operator on its PSModuleInfo (`& $moduleInfo { ... }`), so identically-named
    convention functions across modules never collide.

    Manifest schema (returned by Get-OmniModuleManifest):
        Name          [string]  required, unique display name
        Category      [string]  required, dashboard grouping (e.g. 'Network')
        Description   [string]  optional, one line
        RequiresAdmin [bool]    optional, default $false
        Order         [int]     optional, sort weight (lower runs first)
        Enabled       [bool]    optional, default $true

    Module contract v1 (0.5.0) adds, all optional with derived defaults:
        Id                     [string]   stable unique id '<group>.<kebab-name>'
                                          (default: Group + '.' + kebab-case Name)
        Group                  [string]   one of Get-OmniGroupNames (default 'extras')
        RequiresElevation      [bool]     alias of RequiresAdmin
        NetworkAccess          [string]   None | LocalNetwork | Internet (default 'None')
        TimeoutSec             [int]      per-module budget in seconds (default 60)
        SupportedArchitectures [string[]] x64 | arm64 (default both)

    Added in 0.6.0, both optional:
        SupportedPlatforms     [string[]] Windows | Linux | macOS (default all three; the
                                          engine skips the module with SkippedReason
                                          'NotSupported' on any other host)
        Parallel               [bool]     default $true; $false runs the module on the
                                          caller's thread after the parallel pool (for
                                          modules that are not thread-safe or that
                                          measure the machine, like Benchmark)

    Invalid values and duplicate Ids are contract violations: the plugin is logged
    and skipped, exactly like a missing convention function.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Contract v1 vocabularies
# ---------------------------------------------------------------------------

# The ten v1.0 groups plus 'extras' (ordered as they appear in listings).
$script:OmniGroups = [ordered]@{
    system      = 'System'
    performance = 'Performance'
    services    = 'Services and drivers'
    startup     = 'Startup and persistence'
    events      = 'Event logs'
    reliability = 'Reliability'
    storage     = 'Storage'
    network     = 'Network'
    updates     = 'Windows Update and health'
    security    = 'Security'
    extras      = 'Extras'
}

$script:OmniNetworkAccessValues = @('None', 'LocalNetwork', 'Internet')
$script:OmniArchitectureValues = @('x64', 'arm64')
$script:OmniPlatformValues = @('Windows', 'Linux', 'macOS')
$script:OmniDefaultTimeoutSec = 60

# Group of each built-in scanner, used only to place results from sessions saved
# before contract v1 (which carry no Group/ModuleId). Live registrations read the
# manifest; this table is never consulted for them.
$script:OmniLegacyGroupMap = @{
    'System Information' = 'system'; 'System' = 'system'
    'Performance' = 'performance'; 'CPU' = 'performance'; 'Memory' = 'performance'
    'Processes' = 'performance'; 'Startup Performance' = 'performance'
    'Services' = 'services'; 'Drivers' = 'services'
    'Startup' = 'startup'; 'Scheduled Tasks' = 'startup'; 'Registry Health' = 'startup'
    'Event Logs' = 'events'; 'Error Summary' = 'events'
    'Reliability' = 'reliability'
    'Storage' = 'storage'; 'Disk' = 'storage'; 'Disk Usage' = 'storage'
    'Network' = 'network'; 'IP Configuration' = 'network'; 'DNS Resolver' = 'network'
    'Hosts File' = 'network'; 'Network Shares' = 'network'; 'WiFi Networks' = 'network'
    'Proxy Configuration' = 'network'; 'VPN' = 'network'
    'Windows Health' = 'updates'; 'Windows Update' = 'updates'; 'System Health' = 'updates'
    'Update Rings' = 'updates'
    'Security' = 'security'; 'Firewall Rules' = 'security'; 'Certificates' = 'security'
    'BitLocker' = 'security'; 'Defender Onboarding' = 'security'
}

function Get-OmniGroupNames {
    <# .SYNOPSIS Returns the valid module group ids (contract v1), in display order. #>
    [OutputType([string[]])]
    param()
    return [string[]]@($script:OmniGroups.Keys)
}

function Get-OmniGroup {
    <#
    .SYNOPSIS
        Returns the module groups (contract v1) as Id / DisplayName records.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    foreach ($key in $script:OmniGroups.Keys) {
        [pscustomobject]@{ PSTypeName = 'OmniDiag.Group'; Id = [string]$key; DisplayName = [string]$script:OmniGroups[$key] }
    }
}

function Get-OmniNetworkAccessNames {
    <# .SYNOPSIS Returns the valid NetworkAccess values (contract v1). #>
    [OutputType([string[]])]
    param()
    return [string[]]$script:OmniNetworkAccessValues
}

function ConvertTo-OmniKebabCase {
    <#
    .SYNOPSIS
        Lower-cases a display name and joins its alphanumeric runs with '-'
        (e.g. 'Release / Renew IP Address' -> 'release-renew-ip-address').
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    return (($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
}

function Resolve-OmniModuleIdentity {
    <#
    .SYNOPSIS
        Returns the Id and Group of a module result, deriving them for results saved
        before contract v1.

    .DESCRIPTION
        Prefers the ModuleId/Group stamped on the result by the engine. For older
        results it uses the built-in scanner table, then 'extras', and builds the Id
        as '<group>.<kebab-name>' - the same rule the registry uses for manifests.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Name,
        [string] $ModuleId,
        [string] $Group
    )
    if ([string]::IsNullOrWhiteSpace($Group)) {
        $Group = if ($script:OmniLegacyGroupMap.ContainsKey($Name)) { $script:OmniLegacyGroupMap[$Name] } else { 'extras' }
    }
    if ([string]::IsNullOrWhiteSpace($ModuleId)) {
        $kebab = ConvertTo-OmniKebabCase -Value $Name
        if (-not $kebab) { $kebab = 'unnamed' }
        $ModuleId = "$Group.$kebab"
    }
    return [pscustomobject]@{ Id = $ModuleId; Group = $Group }
}

function Get-OmniManifestValue {
    <# .SYNOPSIS Internal: reads a manifest key (hashtable / ordered / object), or a default. #>
    param($Manifest, [string] $Key, $Default = $null)
    if ($null -eq $Manifest) { return $Default }
    if ($Manifest -is [System.Collections.IDictionary]) {
        if ($Manifest.Contains($Key) -and $null -ne $Manifest[$Key]) { return $Manifest[$Key] }
        return $Default
    }
    $p = $Manifest.PSObject.Properties[$Key]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Resolve-OmniPluginContract {
    <#
    .SYNOPSIS
        Validates a manifest against module contract v1 and returns the normalized
        contract fields (Id, Group, RequiresAdmin/RequiresElevation, NetworkAccess,
        TimeoutSec, SupportedArchitectures).

    .DESCRIPTION
        Shared by Get-OmniModule (scanners) and Get-OmniRepair (repairs). Missing
        fields get derived defaults; invalid values throw, so the caller logs and
        skips the plugin like any other contract violation.

    .PARAMETER Manifest
        The manifest hashtable returned by the plugin.

    .PARAMETER Kind
        'Module' (Id = '<group>.<kebab-name>') or 'Repair' (Id = 'repair.<kebab-name>';
        no Group).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [ValidateSet('Module', 'Repair')] [string] $Kind = 'Module'
    )

    $name = [string](Get-OmniManifestValue $Manifest 'Name' '')
    $kebab = ConvertTo-OmniKebabCase -Value $name
    if (-not $kebab) { throw "Plugin '$name' has a name with no letters or digits; cannot derive an Id." }

    $group = $null
    if ($Kind -eq 'Module') {
        $group = ([string](Get-OmniManifestValue $Manifest 'Group' 'extras')).ToLowerInvariant()
        if ($group -notin (Get-OmniGroupNames)) {
            throw "Plugin '$name' has invalid Group '$group'. Valid: $((Get-OmniGroupNames) -join ', ')."
        }
    }

    $defaultId = if ($Kind -eq 'Module') { "$group.$kebab" } else { "repair.$kebab" }
    $id = [string](Get-OmniManifestValue $Manifest 'Id' $defaultId)
    if ($id -cnotmatch '^[a-z0-9]+(?:[.-][a-z0-9]+)*$') {
        throw "Plugin '$name' has invalid Id '$id'. Use lower-case letters, digits, '.' and '-' (e.g. 'network.dns-resolver')."
    }

    $networkAccess = [string](Get-OmniManifestValue $Manifest 'NetworkAccess' 'None')
    $match = @($script:OmniNetworkAccessValues | Where-Object { $_ -ieq $networkAccess })
    if ($match.Count -eq 0) {
        throw "Plugin '$name' has invalid NetworkAccess '$networkAccess'. Valid: $($script:OmniNetworkAccessValues -join ', ')."
    }
    $networkAccess = [string]$match[0]

    # RequiresElevation is the v1 name; RequiresAdmin stays authoritative when both are given.
    $requiresAdmin = [bool](Get-OmniManifestValue $Manifest 'RequiresAdmin' (Get-OmniManifestValue $Manifest 'RequiresElevation' $false))

    $timeout = Get-OmniManifestValue $Manifest 'TimeoutSec' $script:OmniDefaultTimeoutSec
    $timeoutSec = 0
    if (-not [int]::TryParse([string]$timeout, [ref]$timeoutSec) -or $timeoutSec -lt 1) {
        throw "Plugin '$name' has invalid TimeoutSec '$timeout'. Use a positive whole number of seconds."
    }

    $arch = @(Get-OmniManifestValue $Manifest 'SupportedArchitectures' $script:OmniArchitectureValues)
    $archOut = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $arch) {
        $hit = @($script:OmniArchitectureValues | Where-Object { $_ -ieq [string]$a })
        if ($hit.Count -eq 0) {
            throw "Plugin '$name' has invalid SupportedArchitectures value '$a'. Valid: $($script:OmniArchitectureValues -join ', ')."
        }
        if (-not $archOut.Contains($hit[0])) { $archOut.Add($hit[0]) }
    }
    if ($archOut.Count -eq 0) { throw "Plugin '$name' declares no SupportedArchitectures." }

    $platforms = @(Get-OmniManifestValue $Manifest 'SupportedPlatforms' $script:OmniPlatformValues)
    $platOut = [System.Collections.Generic.List[string]]::new()
    foreach ($pl in $platforms) {
        $hit = @($script:OmniPlatformValues | Where-Object { $_ -ieq [string]$pl })
        if ($hit.Count -eq 0) {
            throw "Plugin '$name' has invalid SupportedPlatforms value '$pl'. Valid: $($script:OmniPlatformValues -join ', ')."
        }
        if (-not $platOut.Contains($hit[0])) { $platOut.Add($hit[0]) }
    }
    if ($platOut.Count -eq 0) { throw "Plugin '$name' declares no SupportedPlatforms." }

    return [pscustomobject]@{
        Id                     = $id
        Group                  = $group
        RequiresAdmin          = $requiresAdmin
        NetworkAccess          = $networkAccess
        TimeoutSec             = $timeoutSec
        SupportedArchitectures = [string[]]$archOut.ToArray()
        SupportedPlatforms     = [string[]]$platOut.ToArray()
        Parallel               = [bool](Get-OmniManifestValue $Manifest 'Parallel' $true)
    }
}

function Get-OmniHostArchitecture {
    <#
    .SYNOPSIS
        Returns the operating system's processor architecture as a contract v1 value
        ('x64' or 'arm64'), or the raw lower-case name for anything else (e.g. 'x86').

    .DESCRIPTION
        Uses RuntimeInformation.OSArchitecture when the runtime has it (PowerShell 7,
        .NET Framework 4.7.1+), else PROCESSOR_ARCHITEW6432 / PROCESSOR_ARCHITECTURE, so a
        32-bit PowerShell on 64-bit Windows still reports the OS architecture.

    .EXAMPLE
        Get-OmniHostArchitecture
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $raw = $null
    try { $raw = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { $raw = $null }
    if (-not $raw) {
        $raw = if ($env:PROCESSOR_ARCHITEW6432) { [string]$env:PROCESSOR_ARCHITEW6432 } else { [string]$env:PROCESSOR_ARCHITECTURE }
    }
    switch -Regex ($raw) {
        '^(?i)(x64|amd64)$' { return 'x64' }
        '^(?i)arm64$'       { return 'arm64' }
    }
    if ($raw) { return $raw.ToLowerInvariant() }
    return 'unknown'
}

function Get-OmniHostPlatform {
    <#
    .SYNOPSIS
        Returns the host platform as a contract value: 'Windows', 'Linux', or 'macOS'.

    .EXAMPLE
        Get-OmniHostPlatform
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($PSVersionTable.PSEdition -ne 'Core') { return 'Windows' }
    if (Get-Variable -Name 'IsLinux' -ValueOnly -ErrorAction SilentlyContinue) { return 'Linux' }
    if (Get-Variable -Name 'IsMacOS' -ValueOnly -ErrorAction SilentlyContinue) { return 'macOS' }
    return 'Windows'
}

function Test-OmniIsAdministrator {
    <#
    .SYNOPSIS
        Returns $true if the current process is running elevated (Windows).
        Returns $false on non-Windows hosts.
    #>
    [OutputType([bool])]
    param()
    try {
        if ($IsWindows -eq $false) { return $false }   # PS7 on non-Windows
    } catch { }
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function New-OmniContext {
    <#
    .SYNOPSIS
        Builds the execution context handed to every diagnostic module.

    .DESCRIPTION
        The context is the only argument a module receives. It carries the logger,
        the resolved time range, a cooperative cancellation token, the elevation
        state, whether connectivity probes may run, the host architecture and
        platform, and a free-form Config bag for per-run options.

    .PARAMETER Logger
        Logger from New-OmniLogger.

    .PARAMETER TimeRange
        Range from Get-OmniTimeRange. Default: the last 7 days.

    .PARAMETER CancellationToken
        A [System.Threading.CancellationToken]. Defaults to CancellationToken.None.

    .PARAMETER Config
        Per-run options read by modules (e.g. MaxEventsPerChannel, ProbeTargets).

    .PARAMETER NetworkProbes
        Allow connectivity probes (decision 1: off by default). Scanners that declare
        NetworkAccess other than 'None' still run without it, doing local work only.

    .EXAMPLE
        $ctx = New-OmniContext -Logger (New-OmniLogger) -NetworkProbes -Config @{ ProbeTargets = @{ PublicAddress = '9.9.9.9' } }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Logger,
        [pscustomobject] $TimeRange,
        [System.Threading.CancellationToken] $CancellationToken = ([System.Threading.CancellationToken]::None),
        [hashtable] $Config = @{},
        [switch] $NetworkProbes
    )

    if (-not $TimeRange) { $TimeRange = Get-OmniTimeRange -Preset Last7Days }

    return [pscustomobject]@{
        PSTypeName        = 'OmniDiag.Context'
        Logger            = $Logger
        TimeRange         = $TimeRange
        CancellationToken = $CancellationToken
        IsAdmin           = (Test-OmniIsAdministrator)
        NetworkProbes     = [bool]$NetworkProbes
        Architecture      = (Get-OmniHostArchitecture)
        Platform          = (Get-OmniHostPlatform)
        Config            = $Config
        Host              = [pscustomobject]@{
            ComputerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Environment]::MachineName }
            UserName     = if ($env:USERNAME) { $env:USERNAME } else { [System.Environment]::UserName }
            PSVersion    = $PSVersionTable.PSVersion.ToString()
        }
    }
}

function Get-OmniModule {
    <#
    .SYNOPSIS
        Discovers and loads diagnostic modules from one or more folders.

    .DESCRIPTION
        Imports each *.psm1 (excluding files ending in .Tests.psm1), validates that
        it implements the contract, reads its manifest, and returns a registration
        record. Modules that fail validation are reported (logged + warning) and
        skipped rather than aborting discovery.

    .PARAMETER Path
        One or more directories to scan for module files.

    .PARAMETER Logger
        Optional logger for diagnostics during discovery.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Path,

        [pscustomobject] $Logger
    )

    $registrations = [System.Collections.Generic.List[object]]::new()
    $seenIds = @{}

    foreach ($folder in $Path) {
        if (-not (Test-Path -LiteralPath $folder)) {
            if ($Logger) { $Logger.Warn("Module folder not found: $folder", 'Registry') }
            continue
        }

        $files = Get-ChildItem -LiteralPath $folder -Filter '*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.Tests.psm1' }

        foreach ($file in $files) {
            try {
                $modInfo = Import-Module -Name $file.FullName -PassThru -Force -DisableNameChecking -ErrorAction Stop

                $exported = $modInfo.ExportedFunctions.Keys
                foreach ($required in @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')) {
                    if ($exported -notcontains $required) {
                        throw "Module '$($file.Name)' does not export required function '$required'."
                    }
                }

                $manifest = & $modInfo { Get-OmniModuleManifest }
                if (-not $manifest -or -not $manifest.Name -or -not $manifest.Category) {
                    throw "Module '$($file.Name)' returned an invalid manifest (Name and Category are required)."
                }

                $contract = Resolve-OmniPluginContract -Manifest $manifest -Kind Module
                if ($seenIds.ContainsKey($contract.Id)) {
                    throw "Module '$($file.Name)' declares Id '$($contract.Id)', already used by '$($seenIds[$contract.Id])'. Ids must be unique; the duplicate was skipped."
                }

                $registration = [pscustomobject]@{
                    PSTypeName             = 'OmniDiag.Registration'
                    Id                     = $contract.Id
                    Name                   = [string]$manifest.Name
                    Group                  = $contract.Group
                    Category               = [string]$manifest.Category
                    Description            = [string](Get-OmniManifestValue $manifest 'Description' '')
                    RequiresAdmin          = $contract.RequiresAdmin
                    RequiresElevation      = $contract.RequiresAdmin
                    NetworkAccess          = $contract.NetworkAccess
                    TimeoutSec             = $contract.TimeoutSec
                    SupportedArchitectures = $contract.SupportedArchitectures
                    SupportedPlatforms     = $contract.SupportedPlatforms
                    Parallel               = $contract.Parallel
                    Order                 = [int](Get-OmniManifestValue $manifest 'Order' 0)
                    Enabled                = [bool](Get-OmniManifestValue $manifest 'Enabled' $true)
                    ModuleInfo             = $modInfo
                    SourceFile             = $file.FullName
                }
                $seenIds[$contract.Id] = $file.FullName
                $registrations.Add($registration)
                if ($Logger) { $Logger.Debug("Registered module '$($registration.Name)' [$($registration.Id)]", 'Registry') }
            } catch {
                if ($Logger) { $Logger.Error("Failed to load module '$($file.Name)': $($_.Exception.Message)", 'Registry') }
                else { Write-Warning "OmniDiag: failed to load module '$($file.Name)': $($_.Exception.Message)" }
            }
        }
    }

    return $registrations | Sort-Object Order, Name
}

Export-ModuleMember -Function @(
    'Test-OmniIsAdministrator', 'New-OmniContext', 'Get-OmniModule',
    'Get-OmniGroupNames', 'Get-OmniGroup', 'Get-OmniNetworkAccessNames', 'ConvertTo-OmniKebabCase',
    'Resolve-OmniModuleIdentity', 'Resolve-OmniPluginContract',
    'Get-OmniHostArchitecture', 'Get-OmniHostPlatform'
)
