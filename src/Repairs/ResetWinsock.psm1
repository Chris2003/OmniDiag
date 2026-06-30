<#
.SYNOPSIS
    Repair: reset the Winsock catalog.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Reset Winsock Catalog'
        Category      = 'Network'
        Description   = 'Resets the Windows Sockets catalog to a clean state. Requires a reboot to fully apply.'
        RequiresAdmin = $true
        Risk          = 'Moderate'
        RestorePoint  = $true
        RebootHint    = $true
        AppliesTo     = @('network')
        Order         = 30
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Reset Winsock Catalog' -Category 'Network'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Reset the Winsock catalog (netsh winsock reset)' -Action {
        netsh winsock reset
    } | Out-Null
    if (-not $Context.DryRun) { $r.RebootRequired = $true }
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
