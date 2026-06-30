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
#>

Set-StrictMode -Version Latest

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
        state, and a free-form Config bag for per-run options.

    .PARAMETER CancellationToken
        A [System.Threading.CancellationToken]. Defaults to CancellationToken.None.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Logger,
        [pscustomobject] $TimeRange,
        [System.Threading.CancellationToken] $CancellationToken = ([System.Threading.CancellationToken]::None),
        [hashtable] $Config = @{}
    )

    if (-not $TimeRange) { $TimeRange = Get-OmniTimeRange -Preset Last7Days }

    return [pscustomobject]@{
        PSTypeName        = 'OmniDiag.Context'
        Logger            = $Logger
        TimeRange         = $TimeRange
        CancellationToken = $CancellationToken
        IsAdmin           = (Test-OmniIsAdministrator)
        Config            = $Config
        Host              = [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            UserName     = $env:USERNAME
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

                $registration = [pscustomobject]@{
                    PSTypeName    = 'OmniDiag.Registration'
                    Name          = [string]$manifest.Name
                    Category      = [string]$manifest.Category
                    Description   = [string]($manifest.Description)
                    RequiresAdmin = [bool]($manifest.RequiresAdmin)
                    Order         = [int]($manifest.Order)
                    Enabled       = if ($null -ne $manifest.Enabled) { [bool]$manifest.Enabled } else { $true }
                    ModuleInfo    = $modInfo
                    SourceFile    = $file.FullName
                }
                $registrations.Add($registration)
                if ($Logger) { $Logger.Debug("Registered module '$($registration.Name)' [$($registration.Category)]", 'Registry') }
            } catch {
                if ($Logger) { $Logger.Error("Failed to load module '$($file.Name)': $($_.Exception.Message)", 'Registry') }
                else { Write-Warning "OmniDiag: failed to load module '$($file.Name)': $($_.Exception.Message)" }
            }
        }
    }

    return $registrations | Sort-Object Order, Name
}

Export-ModuleMember -Function @('Test-OmniIsAdministrator', 'New-OmniContext', 'Get-OmniModule')
