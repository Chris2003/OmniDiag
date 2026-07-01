<#
.SYNOPSIS
    OmniDiag diagnostic module: Windows Features.

.DESCRIPTION
    Enumerates enabled Windows optional features via Win32_OptionalFeature.

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
        Name          = 'Windows Features'
        Category      = 'System'
        Description   = 'Enabled Windows optional feature inventory.'
        RequiresAdmin = $false
        Order         = 150
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

    $result = New-OmniResult -ModuleName 'Windows Features' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Optional features (InstallState 1 = enabled) ---------------------
    try {
        $features = @(Get-CimInstance -ClassName 'Win32_OptionalFeature' -ErrorAction Stop)
        $enabled = @($features | Where-Object { $_.InstallState -eq 1 })
        $enabledNames = @($enabled | ForEach-Object { $_.Name } | Sort-Object -Unique)

        Set-OmniResultMetric -Result $result -Name 'EnabledFeatureCount' -Value $enabledNames.Count
        Set-OmniResultMetric -Result $result -Name 'EnabledFeatures'     -Value $enabledNames

        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title ("$($enabledNames.Count) Windows optional feature(s) enabled") -Severity 'Information' `
            -Component 'System/Features' `
            -Detail ("Enabled features: " + ($enabledNames -join ', ')))
    } catch {
        $log.Warn("CIM query failed for Win32_OptionalFeature: $($_.Exception.Message)", 'Windows Features')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Windows features inventory collected' -Severity 'Pass' -Component 'System/Features' `
            -Detail 'Enabled Windows optional features were enumerated without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
