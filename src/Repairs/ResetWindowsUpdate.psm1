<#
.SYNOPSIS
    Repair: reset the Windows Update components.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Reset Windows Update'
        Category      = 'Update'
        Description   = 'Stops the update services, clears the SoftwareDistribution and catroot2 caches, and restarts the services.'
        RequiresAdmin = $true
        Risk          = 'Moderate'
        RestorePoint  = $true
        RebootHint    = $false
        AppliesTo     = @('health/update', 'update')
        Order         = 70
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Reset Windows Update' -Category 'Update'
    $services = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
    $softwareDistribution = Join-Path $env:WINDIR 'SoftwareDistribution'
    $catroot2 = Join-Path $env:WINDIR 'System32\catroot2'

    Invoke-OmniRepairStep -Result $r -Context $Context -Description "Stop update services ($($services -join ', '))" -Action {
        foreach ($s in $services) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    } | Out-Null

    foreach ($folder in @($softwareDistribution, $catroot2)) {
        $f = $folder
        Invoke-OmniRepairStep -Result $r -Context $Context -Description "Clear cache folder $f" -Action {
            if (Test-Path -LiteralPath $f) {
                $backup = "$f.old"
                if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
                Rename-Item -LiteralPath $f -NewName ("{0}.old" -f (Split-Path $f -Leaf)) -ErrorAction Stop
            }
        } | Out-Null
    }

    Invoke-OmniRepairStep -Result $r -Context $Context -Description "Start update services ($($services -join ', '))" -Action {
        foreach ($s in $services) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    } | Out-Null

    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
