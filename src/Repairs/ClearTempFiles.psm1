<#
.SYNOPSIS
    Repair: clear temporary files.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}
if (-not (Get-Command Get-OmniDataRoot -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Paths.psm1') -Global -Force -DisableNameChecking
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
        AppliesTo     = @('storage/temp')
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
    # Portable launchers point TEMP at the tool folder; clean the user's real temp folder.
    $userTemp = if ($env:OMNIDIAG_HOST_TEMP) { $env:OMNIDIAG_HOST_TEMP } else { $env:TEMP }
    $targets.Add([string]$userTemp)
    if ($Context.IsAdmin) { $targets.Add((Join-Path $env:WINDIR 'Temp')) }

    # Never delete OmniDiag itself or its data (logs, sessions, registry backups), e.g. when
    # the tool was extracted under %TEMP% or the data root fell back to %TEMP%\OmniDiag.
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $protected = @((Get-OmniDataRoot).Path, (Get-OmniToolRoot)) | Where-Object { $_ } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd($sep) + $sep }

    foreach ($path in $targets) {
        $p = $path   # local copy captured by the action closure
        Invoke-OmniRepairStep -Result $r -Context $Context -Description "Delete temp files in $p" -Action {
            if (Test-Path -LiteralPath $p) {
                Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue |
                    Where-Object {
                        $child = $_.FullName.TrimEnd($sep) + $sep
                        -not ($protected | Where-Object { $_.StartsWith($child, [System.StringComparison]::OrdinalIgnoreCase) })
                    } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        } | Out-Null
    }
    return (Complete-OmniRepairResult -Result $r)
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction')
