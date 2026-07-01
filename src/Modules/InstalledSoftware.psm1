<#
.SYNOPSIS
    OmniDiag diagnostic module: Installed Software.

.DESCRIPTION
    Enumerates the standard Windows uninstall registry hives (machine, WOW6432,
    and current-user) to produce an inventory of installed applications. Emits a
    count metric and a capped list of {Name, Version, Publisher}. Fails soft.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Installed Software'
        Category      = 'System'
        Description   = 'Inventory of installed applications from the uninstall hives.'
        RequiresAdmin = $false
        Order         = 180
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Installed Software' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $count = 0
    $softwareList = @()

    try {
        $uninstallPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )

        $apps = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
            Sort-Object -Property DisplayName -Unique

        $count = @($apps).Count
        Set-OmniResultMetric -Result $result -Name 'InstalledSoftwareCount' -Value $count

        $softwareList = @($apps | Select-Object -First 200 | ForEach-Object {
            [pscustomobject]@{
                Name      = [string]$_.DisplayName
                Version   = if ($_.PSObject.Properties['DisplayVersion']) { [string]$_.DisplayVersion } else { '' }
                Publisher = if ($_.PSObject.Properties['Publisher']) { [string]$_.Publisher } else { '' }
            }
        })
        Set-OmniResultMetric -Result $result -Name 'InstalledSoftware' -Value $softwareList
    } catch {
        $log.Warn("Installed-software enumeration failed: $($_.Exception.Message)", 'Installed Software')
    }

    Add-OmniFinding -Result $result -Finding (New-OmniFinding `
        -Title "$count applications installed" -Severity 'Information' -Component 'System/Software' `
        -Detail "Enumerated $count unique applications from the uninstall registry hives.")

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Software inventory collected' -Severity 'Pass' -Component 'System/Software' `
            -Detail 'Installed application inventory was collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
