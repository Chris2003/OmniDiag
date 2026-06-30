<#
.SYNOPSIS
    Repair: restart the Print Spooler service.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Restart Print Spooler'
        Category      = 'Services'
        Description   = 'Restarts the Print Spooler service to clear stuck print jobs and spooler faults.'
        RequiresAdmin = $true
        Risk          = 'Safe'
        RestorePoint  = $false
        RebootHint    = $false
        AppliesTo     = @('health/services', 'printing', 'spooler')
        Order         = 40
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Restart Print Spooler' -Category 'Services'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Restart the Print Spooler service' -Action {
        Restart-Service -Name 'Spooler' -Force -ErrorAction Stop
    } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
