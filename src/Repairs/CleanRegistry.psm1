<#
.SYNOPSIS
    Repair: clean invalid / obsolete registry entries (CCleaner-style), backup first.

.DESCRIPTION
    Re-scans for invalid registry entries via Get-OmniInvalidRegistryEntry, writes a .reg
    BACKUP of every affected key, then removes the entries. Every change flows through
    Invoke-OmniRepairStep, so a dry-run describes the work (count + backup path) without
    touching anything. The engine also creates a System Restore point up front (RestorePoint)
    and only runs when elevated (RequiresAdmin). Restore by importing the .reg backup.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command New-OmniRepairResult -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Repair\RepairModels.psm1') -Global -Force -DisableNameChecking
}
if (-not (Get-Command Get-OmniInvalidRegistryEntry -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\RegistryScan.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniRepairManifest {
    @{
        Name          = 'Clean Invalid Registry Entries'
        Category      = 'Cleanup'
        Description   = 'Finds and removes invalid/obsolete registry entries (broken startup, dead App Paths, orphaned file associations, uninstall leftovers, missing shared-DLL/sound/font references). Exports a .reg backup first.'
        RequiresAdmin = $true
        Risk          = 'Destructive'
        RestorePoint  = $true
        RebootHint    = $false
        AppliesTo     = @('registry', 'system/registry')
        Order         = 90
        Enabled       = $true
    }
}

function Invoke-OmniRepairAction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $r = New-OmniRepairResult -Name 'Clean Invalid Registry Entries' -Category 'Cleanup'
    $log = $Context.Logger

    $entries = @()
    try { $entries = @(Get-OmniInvalidRegistryEntry -Logger $log) }
    catch { if ($log) { $log.Warn("Registry scan failed: $($_.Exception.Message)", 'CleanRegistry') } }

    if ($entries.Count -eq 0) {
        Invoke-OmniRepairStep -Result $r -Context $Context -Description 'Scan registry for invalid entries (none found)' -Action { } | Out-Null
        return (Complete-OmniRepairResult -Result $r)
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backup = Join-Path ([System.IO.Path]::GetTempPath()) "OmniDiag\RegBackup-$stamp.reg"
    $byCat = (@($entries | Group-Object Category | Sort-Object Count -Descending | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')

    # 1) Backup first (skipped in dry-run; the action captures $entries/$backup from this scope).
    Invoke-OmniRepairStep -Result $r -Context $Context -Description "Back up $($entries.Count) affected registry key(s) to $backup" -Action {
        Export-OmniRegistryBackup -Entries $entries -Path $backup | Out-Null
    } | Out-Null

    # 2) Remove the invalid entries.
    Invoke-OmniRepairStep -Result $r -Context $Context -Description "Remove $($entries.Count) invalid registry entries ($byCat)" -Action {
        $removed = 0
        foreach ($e in $entries) {
            try { Remove-OmniRegistryEntry -Entry $e -ErrorAction Stop; $removed++ }
            catch { }
        }
        "Removed $removed of $($entries.Count) entries. Backup: $backup"
    } | Out-Null

    return (Complete-OmniRepairResult -Result $r)
}

function Test-OmniRepairApplicable {
    <# .SYNOPSIS Recommended when the scan reported invalid registry entries. #>
    param([pscustomobject] $Session)
    try {
        foreach ($res in $Session.Results) {
            if ($res.ModuleName -eq 'Registry Health' -and $res.Metrics -and $res.Metrics.Contains('InvalidEntryCount')) {
                return ([int]$res.Metrics['InvalidEntryCount'] -gt 0)
            }
        }
    } catch { }
    return $false
}

Export-ModuleMember -Function @('Get-OmniRepairManifest', 'Invoke-OmniRepairAction', 'Test-OmniRepairApplicable')
