<#
.SYNOPSIS
    Repair: flush the DNS resolver cache.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Flush DNS Cache'
        Category      = 'Network'
        Description   = 'Clears the DNS resolver cache to resolve stale or poisoned name lookups.'
        RequiresAdmin = $false
        Risk          = 'Safe'
        RestorePoint  = $false
        RebootHint    = $false
        AppliesTo     = @('network/dns')
        Order         = 10
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Flush DNS Cache' -Category 'Network'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Flush the DNS resolver cache' -Action {
        ipconfig /flushdns
    } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
