<#
.SYNOPSIS
    OmniDiag diagnostic module: Registry Health.

.DESCRIPTION
    Two things: (1) integrity of security-relevant keys (Winlogon Shell/Userinit, Run keys)
    that are common persistence targets; and (2) a CCleaner-style READ-ONLY scan for invalid /
    obsolete registry entries (broken startup commands, dead App Paths, orphaned file
    associations, obsolete uninstall leftovers, missing shared-DLL / sound-event / font
    references) via Get-OmniInvalidRegistryEntry. Detection changes nothing; the
    "Clean Invalid Registry Entries" repair removes them (after a .reg backup).
    All reads fail soft; the module never throws.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories + registry scanner so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}
if (-not (Get-Command -Name 'Get-OmniInvalidRegistryEntry' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\RegistryScan.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Registry Health'
        Category      = 'System'
        Description   = 'Integrity of security-relevant registry keys and values.'
        RequiresAdmin = $false
        Order         = 170
        Enabled       = $true
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Registry Health' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $readableKeys = 0

    # --- Winlogon Shell / Userinit ----------------------------------------
    try {
        $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $winlogon = Get-ItemProperty -Path $winlogonPath -ErrorAction Stop
        $readableKeys++

        $shell = if ($winlogon.PSObject.Properties['Shell']) { [string]$winlogon.Shell } else { '' }
        Set-OmniResultMetric -Result $result -Name 'WinlogonShell' -Value $shell
        if ($shell.Trim().ToLowerInvariant() -ne 'explorer.exe') {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'Unexpected Winlogon Shell value' -Severity 'Warning' -Component 'System/Registry' `
                -Detail "Winlogon Shell is '$shell' (expected 'explorer.exe')." `
                -LikelyCause 'A modified Shell value can indicate malware persistence.' `
                -Confidence 60 `
                -Recommendation 'Verify the Shell value and scan the device for persistence/malware.')
        }

        $userinit = if ($winlogon.PSObject.Properties['Userinit']) { [string]$winlogon.Userinit } else { '' }
        Set-OmniResultMetric -Result $result -Name 'WinlogonUserinit' -Value $userinit
        if ($userinit.ToLowerInvariant() -notlike '*userinit.exe*') {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'Unexpected Winlogon Userinit value' -Severity 'Warning' -Component 'System/Registry' `
                -Detail "Winlogon Userinit is '$userinit' (expected to contain 'userinit.exe')." `
                -LikelyCause 'A modified Userinit value can indicate malware persistence.' `
                -Confidence 60 `
                -Recommendation 'Verify the Userinit value and scan the device for persistence/malware.')
        }
    } catch {
        $log.Warn("Winlogon key read failed: $($_.Exception.Message)", 'Registry Health')
    }

    # --- Run keys (confirm readable) --------------------------------------
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($rk in $runKeys) {
        try {
            $null = Get-ItemProperty -Path $rk -ErrorAction Stop
            $readableKeys++
        } catch {
            $log.Debug("Run key not readable ($rk): $($_.Exception.Message)", 'Registry Health')
        }
    }

    Set-OmniResultMetric -Result $result -Name 'ReadableKeys' -Value $readableKeys

    # --- CCleaner-style invalid/obsolete entries (read-only) --------------
    try {
        $invalid = @(Get-OmniInvalidRegistryEntry -Logger $log)
        Set-OmniResultMetric -Result $result -Name 'InvalidEntryCount' -Value $invalid.Count
        if ($invalid.Count -gt 0) {
            foreach ($grp in ($invalid | Group-Object Category | Sort-Object Count -Descending)) {
                Set-OmniResultMetric -Result $result -Name ("Invalid.{0}" -f ($grp.Name -replace '\s', '')) -Value $grp.Count
                $examples = (@($grp.Group | Select-Object -First 3 | ForEach-Object { $_.Detail }) -join '; ')
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("{0} invalid '{1}' registry entr{2}" -f $grp.Count, $grp.Name, $(if ($grp.Count -eq 1) { 'y' } else { 'ies' })) `
                    -Severity 'Warning' -Component 'System/Registry' `
                    -Detail "e.g. $examples" `
                    -LikelyCause 'Leftover entries from uninstalled software, moved files, or broken associations.' `
                    -Confidence 70 `
                    -Recommendation 'Repair Center > "Clean Invalid Registry Entries" removes these (a .reg backup is written first).')
            }
        }
    } catch {
        $log.Warn("Invalid-entry scan failed: $($_.Exception.Message)", 'Registry Health')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Registry health checks passed' -Severity 'Pass' -Component 'System/Registry' `
            -Detail "Checked $readableKeys security-relevant registry keys; no anomalies found.")
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
