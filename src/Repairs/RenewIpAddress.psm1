<#
.SYNOPSIS
    Repair: release and renew the DHCP-assigned IP address.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Release / Renew IP Address'
        Category      = 'Network'
        Description   = 'Releases and renews the DHCP lease to recover from a bad or stale address.'
        RequiresAdmin = $false
        Risk          = 'Safe'
        RestorePoint  = $false
        RebootHint    = $false
        AppliesTo     = @('network/adapter', 'network/dhcp', 'network/gateway')
        Order         = 20
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Release / Renew IP Address' -Category 'Network'
    # Non-DHCP adapters make ipconfig report a non-zero code; that is benign here.
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Release the current DHCP lease' -IgnoreExitCode -Action {
        ipconfig /release
    } | Out-Null
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Renew the DHCP lease' -IgnoreExitCode -Action {
        ipconfig /renew
    } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
