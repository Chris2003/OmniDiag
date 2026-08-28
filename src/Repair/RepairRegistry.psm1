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
#>

Set-StrictMode -Version Latest

# Standalone (e.g. Pester) bootstrap: Test-OmniIsAdministrator lives in Core/Registry.
if (-not (Get-Command Test-OmniIsAdministrator -ErrorAction SilentlyContinue)) {
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

                $registration = [pscustomobject]@{
                    PSTypeName     = 'OmniDiag.RepairRegistration'
                    Name           = [string]$m.Name
                    Category       = [string]$m.Category
                    Description    = if ($m.Contains('Description')) { [string]$m.Description } else { '' }
                    RequiresAdmin  = if ($m.Contains('RequiresAdmin')) { [bool]$m.RequiresAdmin } else { $false }
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
                $registrations.Add($registration)
                if ($Logger) { $Logger.Debug("Registered repair '$($registration.Name)' [$($registration.Category)]", 'RepairRegistry') }
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
        Wraps Checkpoint-Computer. Returns a status object instead of throwing so the
        repair engine can proceed (with a clear record) when System Restore is
        unavailable - not elevated, disabled on the system drive, throttled to once per
        24h, or not Windows.

    .OUTPUTS
        PSCustomObject: Created [bool], Status (Created|Skipped|Failed), Message.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Description = 'OmniDiag repair checkpoint',
        [pscustomobject] $Logger
    )

    $status = [pscustomobject]@{ Created = $false; Status = 'Skipped'; Message = '' }

    try { if ($IsWindows -eq $false) { $status.Message = 'System Restore is Windows-only.'; return $status } } catch { }

    if (-not (Test-OmniIsAdministrator)) {
        $status.Message = 'A restore point requires administrator rights; skipped.'
        if ($Logger) { $Logger.Warn($status.Message, 'Repair') }
        return $status
    }

    try {
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $status.Created = $true
        $status.Status = 'Created'
        $status.Message = "Restore point '$Description' created."
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
