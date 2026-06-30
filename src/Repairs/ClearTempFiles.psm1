<#
.SYNOPSIS
    Repair: clear temporary files.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Clear Temporary Files'
        Category      = 'Storage'
        Description   = 'Deletes the contents of the user TEMP folder (and the Windows TEMP folder when elevated) to reclaim space.'
        RequiresAdmin = $false
        Risk          = 'Safe'
        RestorePoint  = $false
        RebootHint    = $false
        AppliesTo     = @('storage')
        Order         = 60
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Clear Temporary Files' -Category 'Storage'

    $targets = [System.Collections.Generic.List[string]]::new()
    $targets.Add([string]$env:TEMP)
    if ($Context.IsAdmin) { $targets.Add((Join-Path $env:WINDIR 'Temp')) }

    foreach ($path in $targets) {
        $p = $path   # local copy captured by the action closure
        Invoke-OmniRepairStep -Result $r -Context $Context -Description "Delete temp files in $p" -Action {
            if (Test-Path -LiteralPath $p) {
                Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        } | Out-Null
    }
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
