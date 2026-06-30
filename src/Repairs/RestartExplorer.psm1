<#
.SYNOPSIS
    Repair: restart Windows Explorer (the shell).
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Restart Windows Explorer'
        Category      = 'System'
        Description   = 'Restarts the Explorer shell to clear taskbar, tray, and desktop glitches.'
        RequiresAdmin = $false
        Risk          = 'Safe'
        RestorePoint  = $false
        RebootHint    = $false
        AppliesTo     = @()
        Order         = 50
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Restart Windows Explorer' -Category 'System'
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Stop and relaunch the Explorer shell' -Action {
        Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 600
        if (-not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) {
            Start-Process 'explorer.exe'
        }
    } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
