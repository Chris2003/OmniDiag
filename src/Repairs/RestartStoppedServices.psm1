<#
.SYNOPSIS
    Repair: start automatic services that are not running.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Restart Stopped Automatic Services'
        Category      = 'Services'
        Description   = 'Starts services set to Automatic that are currently stopped (excluding delayed-start services).'
        RequiresAdmin = $true
        Risk          = 'Moderate'
        RestorePoint  = $false
        RebootHint    = $false
        AppliesTo     = @('health/services')
        Order         = 45
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Restart Stopped Automatic Services' -Category 'Services'

    # Read-only discovery (safe to run even in dry-run).
    $stopped = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and -not $_.DelayedAutoStart })

    if ($stopped.Count -eq 0) {
        Add-OmniRepairStep -Result $r -Description 'No stopped automatic services found' -Succeeded $true -Output 'Nothing to start.'
        return (Complete-OmniRepairResult -Result $r)
    }

    foreach ($svc in $stopped) {
        $name = [string]$svc.Name
        $display = [string]$svc.DisplayName
        Invoke-OmniRepairStep -Result $r -Context $Context -Description "Start service '$display' ($name)" -Action {
            Start-Service -Name $name -ErrorAction Stop
        } | Out-Null
    }
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
