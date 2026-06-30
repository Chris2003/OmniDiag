<#
.SYNOPSIS
    Repair: repair the component store with DISM /RestoreHealth.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Repair Component Store (DISM)'
        Category      = 'System'
        Description   = 'Runs DISM /Online /Cleanup-Image /RestoreHealth to repair the Windows component store. Can take several minutes and needs internet for replacement files.'
        RequiresAdmin = $true
        Risk          = 'Destructive'
        RestorePoint  = $true
        RebootHint    = $false
        AppliesTo     = @()
        Order         = 85
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Repair Component Store (DISM)' -Category 'System'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Repair the component store (DISM /Online /Cleanup-Image /RestoreHealth)' -Action {
        dism.exe /Online /Cleanup-Image /RestoreHealth
    } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
