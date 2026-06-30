<#
.SYNOPSIS
    Repair: run System File Checker (sfc /scannow).
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Run System File Checker (SFC)'
        Category      = 'System'
        Description   = 'Scans protected OS files and repairs corrupted ones. Can take several minutes.'
        RequiresAdmin = $true
        Risk          = 'Destructive'
        RestorePoint  = $true
        RebootHint    = $false
        AppliesTo     = @()
        Order         = 80
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Run System File Checker (SFC)' -Category 'System'
    # SFC uses several non-zero exit codes for non-error states; rely on its output.
    Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Run System File Checker (sfc /scannow)' -IgnoreExitCode -Action {
        sfc.exe /scannow
    } | Out-Null
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
