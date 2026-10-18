<#
.SYNOPSIS
    Repair plugin discovery, execution context, applicability matching, and the
    System Restore checkpoint helper.

.DESCRIPTION
    The repair counterpart to Core/Registry.psm1. A repair is a .psm1 in src/Repairs
    that exports two convention functions (and may export a third):

        Get-OmniRepairManifest    -> [hashtable] metadata
        Invoke-OmniRepairAction   -> [OmniDiag.RepairResult] from a repair context
        Test-OmniRepairApplicable -> [bool] (optional) given a diagnostic session

    Repairs run inside their own session state via the call operator on their
    PSModuleInfo (`& $moduleInfo { ... }`), so identically-named convention functions
    never collide - exactly like diagnostic modules.

    Manifest schema:
        Name          [string]  required, unique
        Category      [string]  required, menu grouping
        Description   [string]  optional, one line
        RequiresAdmin [bool]    optional, default $false
        Risk          [string]  optional, Safe|Moderate|Destructive (default Safe)
        RestorePoint  [bool]    optional, checkpoint before running (default $false)
        RebootHint    [bool]    optional, action typically needs a reboot (default $false)
        AppliesTo     [string[]] optional, finding Id/Component substrings addressed
        Order         [int]     optional, sort weight (lower first)
        Enabled       [bool]    optional, default $true

    Module contract v1 (0.5.0) adds Id ('repair.<kebab-name>' by default),
    RequiresElevation (alias of RequiresAdmin), NetworkAccess (None | LocalNetwork |
    Internet, default None), TimeoutSec (default 60), and SupportedArchitectures
    (default x64, arm64). Validation is shared with scanners
    (Resolve-OmniPluginContract); invalid values and duplicate Ids skip the plugin.
#>

Set-StrictMode -Version Latest

# Standalone (e.g. Pester) bootstrap: Test-OmniIsAdministrator and the shared contract
# validator (Resolve-OmniPluginContract) live in Core/Registry.
if (-not (Get-Command Resolve-OmniPluginContract -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Registry.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepair {
    <#
    .SYNOPSIS
        Discovers and loads repair plugins from one or more folders.

    .DESCRIPTION
        Imports each *.psm1 (excluding *.Tests.psm1), validates the contract, reads the
        manifest, and returns a registration per repair. Plugins that fail validation
        are logged and skipped rather than aborting discovery.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string[]] $Path,
        [pscustomobject] $Logger
    )

    $registrations = [System.Collections.Generic.List[object]]::new()
    $seenIds = @{}

    foreach ($folder in $Path) {
        if (-not (Test-Path -LiteralPath $folder)) {
            if ($Logger) { $Logger.Warn("Repair folder not found: $folder", 'RepairRegistry') }
            continue
        }

        $files = Get-ChildItem -LiteralPath $folder -Filter '*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.Tests.psm1' }

        foreach ($file in $files) {
            try {
                $modInfo = Import-Module -Name $file.FullName -PassThru -Force -DisableNameChecking -ErrorAction Stop

                $exported = $modInfo.ExportedFunctions.Keys
                foreach ($required in @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')) {
                    if ($exported -notcontains $required) {
                        throw "Repair '$($file.Name)' does not export required function '$required'."
                    }
                }

                $m = & $modInfo { Get-OmniRepairManifest }
                if (-not $m -or -not $m.Name -or -not $m.Category) {
                    throw "Repair '$($file.Name)' returned an invalid manifest (Name and Category are required)."
                }

                $risk = if ($m.Contains('Risk') -and $m.Risk) { [string]$m.Risk } else { 'Safe' }
                if ($risk -notin (Get-OmniRepairRiskNames)) {
                    throw "Repair '$($m.Name)' has invalid Risk '$risk'. Valid: $((Get-OmniRepairRiskNames) -join ', ')."
                }

                $contract = Resolve-OmniPluginContract -Manifest $m -Kind Repair
                if ($seenIds.ContainsKey($contract.Id)) {
                    throw "Repair '$($file.Name)' declares Id '$($contract.Id)', already used by '$($seenIds[$contract.Id])'. Ids must be unique; the duplicate was skipped."
                }

                $registration = [pscustomobject]@{
                    PSTypeName     = 'OmniDiag.RepairRegistration'
                    Id             = $contract.Id
                    Name           = [string]$m.Name
                    Category       = [string]$m.Category
                    Description    = if ($m.Contains('Description')) { [string]$m.Description } else { '' }
                    RequiresAdmin  = $contract.RequiresAdmin
                    RequiresElevation = $contract.RequiresAdmin
                    NetworkAccess  = $contract.NetworkAccess
                    TimeoutSec     = $contract.TimeoutSec
                    SupportedArchitectures = $contract.SupportedArchitectures
                    Risk           = $risk
                    RestorePoint   = if ($m.Contains('RestorePoint')) { [bool]$m.RestorePoint } else { $false }
                    RebootHint     = if ($m.Contains('RebootHint'))   { [bool]$m.RebootHint }   else { $false }
                    AppliesTo      = @(if ($m.Contains('AppliesTo')) { $m.AppliesTo } else { @() })
                    Order          = if ($m.Contains('Order')) { [int]$m.Order } else { 100 }
                    Enabled        = if ($m.Contains('Enabled') -and $null -ne $m.Enabled) { [bool]$m.Enabled } else { $true }
                    HasApplicableTest = ($exported -contains 'Test-OmniRepairApplicable')
                    Recommended    = $false
                    ModuleInfo     = $modInfo
                    SourceFile     = $file.FullName
                }
                $seenIds[$contract.Id] = $file.FullName
                $registrations.Add($registration)
                if ($Logger) { $Logger.Debug("Registered repair '$($registration.Name)' [$($registration.Id)]", 'RepairRegistry') }
            } catch {
                if ($Logger) { $Logger.Error("Failed to load repair '$($file.Name)': $($_.Exception.Message)", 'RepairRegistry') }
                else { Write-Warning "OmniDiag: failed to load repair '$($file.Name)': $($_.Exception.Message)" }
            }
        }
    }

    return $registrations | Sort-Object Category, Order, Name
}

function New-OmniRepairContext {
    <#
    .SYNOPSIS
        Builds the execution context handed to every repair action.

    .DESCRIPTION
        Mirrors New-OmniContext but adds the DryRun flag. When DryRun is set, repair
        steps describe their work instead of performing it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Logger,
        [switch] $DryRun,
        [System.Threading.CancellationToken] $CancellationToken = ([System.Threading.CancellationToken]::None),
        [hashtable] $Config = @{}
    )

    return [pscustomobject]@{
        PSTypeName        = 'OmniDiag.RepairContext'
        Logger            = $Logger
        DryRun            = [bool]$DryRun
        CancellationToken = $CancellationToken
        IsAdmin           = (Test-OmniIsAdministrator)
        Config            = $Config
        Host              = [pscustomobject]@{
            ComputerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Environment]::MachineName }
            UserName     = if ($env:USERNAME) { $env:USERNAME } else { [System.Environment]::UserName }
            PSVersion    = $PSVersionTable.PSVersion.ToString()
        }
    }
}

function Get-OmniApplicableRepair {
    <#
    .SYNOPSIS
        Annotates repair registrations with whether they're recommended for a session.

    .DESCRIPTION
        A repair is "recommended" if its optional Test-OmniRepairApplicable returns
        true for the session, or if any of its AppliesTo substrings appears in a
        finding's Id or Component (case-insensitive). Returns the same registrations
        with Recommended set (does not filter them out).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object[]] $Registration,
        [pscustomobject] $Session
    )

    # Build the haystack of finding Ids/Components from the session, lowercased.
    $haystack = [System.Collections.Generic.List[string]]::new()
    if ($Session -and $Session.PSObject.Properties['Results']) {
        foreach ($r in @($Session.Results)) {
            foreach ($f in @($r.Findings)) {
                # Only actionable findings recommend a repair; Pass/Information would match broad needles.
                if (-not $f -or ($f.PSObject.Properties['Severity'] -and [string]$f.Severity -in @('Pass', 'Information'))) { continue }
                if ($f.PSObject.Properties['Id'] -and $f.Id)              { $haystack.Add(([string]$f.Id).ToLowerInvariant()) }
                if ($f.PSObject.Properties['Component'] -and $f.Component) { $haystack.Add(([string]$f.Component).ToLowerInvariant()) }
            }
        }
    }

    foreach ($reg in $Registration) {
        $recommended = $false
        if ($reg.HasApplicableTest -and $Session) {
            try { $recommended = [bool](& $reg.ModuleInfo { param($s) Test-OmniRepairApplicable -Session $s } $Session) }
            catch { $recommended = $false }
        }
        if (-not $recommended) {
            foreach ($needle in @($reg.AppliesTo)) {
                $n = ([string]$needle).ToLowerInvariant()
                if ($n -and ($haystack | Where-Object { $_ -like "*$n*" })) { $recommended = $true; break }
            }
        }
        $reg.Recommended = $recommended
    }
    return $Registration
}

function New-OmniRestorePoint {
    <#
    .SYNOPSIS
        Creates a System Restore checkpoint, failing soft when it can't.

    .DESCRIPTION
        Calls the SystemRestore WMI class directly (Checkpoint-Computer does not exist
        in PowerShell 7) and verifies that a new restore point actually appeared, because
        Windows silently skips creation when one was made in the last 24 hours. Returns
        a status object instead of throwing.

        Protected is $true when a new point was created, or when Windows throttled the
        request but a restore point from the last 24 hours already exists. The repair
        engine refuses RestorePoint repairs unless Protected is $true.

    .OUTPUTS
        PSCustomObject: Created [bool], Protected [bool], Status
        (Created|RecentExisting|Skipped|Failed), Message.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Description = 'OmniDiag repair checkpoint',
        [pscustomobject] $Logger
    )

    $status = [pscustomobject]@{ Created = $false; Protected = $false; Status = 'Skipped'; Message = '' }

    try { if ($IsWindows -eq $false) { $status.Message = 'System Restore is Windows-only.'; return $status } } catch { }

    if (-not (Test-OmniIsAdministrator)) {
        $status.Message = 'A restore point requires administrator rights; skipped.'
        if ($Logger) { $Logger.Warn($status.Message, 'Repair') }
        return $status
    }

    # Newest existing restore point (sequence number + creation time), or $null.
    $latest = {
        $points = @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue)
        $newest = $points | Sort-Object { [int64]$_.SequenceNumber } -Descending | Select-Object -First 1
        if (-not $newest) { return $null }
        $created = $null
        try { $created = [datetime]::ParseExact(([string]$newest.CreationTime).Substring(0, 14), 'yyyyMMddHHmmss', $null).ToLocalTime() } catch { }
        [pscustomobject]@{ Sequence = [int64]$newest.SequenceNumber; Created = $created }
    }

    try {
        $before = & $latest
        # RestorePointType 12 = MODIFY_SETTINGS, EventType 100 = BEGIN_SYSTEM_CHANGE.
        $call = Invoke-CimMethod -Namespace 'root/default' -ClassName 'SystemRestore' -MethodName 'CreateRestorePoint' `
            -Arguments @{ Description = $Description; RestorePointType = [uint32]12; EventType = [uint32]100 } -ErrorAction Stop
        if ($call.ReturnValue -ne 0) { throw "SystemRestore.CreateRestorePoint returned $($call.ReturnValue) (System Restore may be disabled on the system drive)" }
        $after = & $latest
        if ($after -and (-not $before -or $after.Sequence -gt $before.Sequence)) {
            $status.Created = $true
            $status.Protected = $true
            $status.Status = 'Created'
            $status.Message = "Restore point '$Description' created."
        } elseif ($after -and $after.Created -and $after.Created -gt (Get-Date).AddHours(-24)) {
            $status.Protected = $true
            $status.Status = 'RecentExisting'
            $status.Message = "Windows allows one restore point per 24 hours; using the existing one from $($after.Created.ToString('yyyy-MM-dd HH:mm'))."
        } else {
            throw 'Windows reported success but no restore point was created'
        }
        if ($Logger) { $Logger.Info($status.Message, 'Repair') }
    } catch {
        $status.Status = 'Failed'
        $status.Message = "Could not create a restore point: $($_.Exception.Message). System Restore may be disabled or throttled (one per 24h)."
        if ($Logger) { $Logger.Warn($status.Message, 'Repair') }
    }
    return $status
}

Export-ModuleMember -Function @(
    'Get-OmniRepair', 'New-OmniRepairContext', 'Get-OmniApplicableRepair', 'New-OmniRestorePoint'
)
