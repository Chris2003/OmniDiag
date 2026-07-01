<#
.SYNOPSIS
    OmniDiag diagnostic module: Environment Variables.

.DESCRIPTION
    Inspects machine and user environment variables with a focus on PATH:
    counts entries, detects duplicates, and flags PATH directories that do not
    exist.

    Contract:
        Get-OmniModuleManifest -> module metadata
        Invoke-OmniModuleScan  -> OmniDiag.Result
#>

Set-StrictMode -Version Latest

# Self-bootstrap the Core factories so this module is usable standalone.
if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Environment Variables'
        Category      = 'System'
        Description   = 'Environment variable and PATH integrity inspection.'
        RequiresAdmin = $false
        Order         = 160
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

    $result = New-OmniResult -ModuleName 'Environment Variables' -Category 'System' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $machineVars = $null
    $userVars = $null
    try {
        $machineVars = [Environment]::GetEnvironmentVariables('Machine')
        $userVars    = [Environment]::GetEnvironmentVariables('User')
    } catch {
        $log.Warn("Failed to read environment variables: $($_.Exception.Message)", 'Environment Variables')
        return (Complete-OmniResult -Result $result -Status 'Skipped')
    }

    try {
        $machineCount = if ($machineVars) { @($machineVars.Keys).Count } else { 0 }
        $userCount    = if ($userVars) { @($userVars.Keys).Count } else { 0 }
        Set-OmniResultMetric -Result $result -Name 'EnvVarCount' -Value ($machineCount + $userCount)
    } catch {
        $log.Debug("Env var count failed: $($_.Exception.Message)", 'Environment Variables')
    }

    # --- PATH analysis ----------------------------------------------------
    try {
        $machinePath = if ($machineVars -and $machineVars['Path']) { [string]$machineVars['Path'] } else { '' }
        $userPath    = if ($userVars -and $userVars['Path']) { [string]$userVars['Path'] } else { '' }

        $entries = @(($machinePath + ';' + $userPath) -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' })

        Set-OmniResultMetric -Result $result -Name 'PathEntryCount' -Value $entries.Count

        # Duplicate detection (case-insensitive)
        $dupes = @($entries | Group-Object -Property { $_.ToLowerInvariant().TrimEnd('\') } |
            Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Group[0] })
        Set-OmniResultMetric -Result $result -Name 'PathDuplicateCount' -Value $dupes.Count
        if ($dupes.Count -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("$($dupes.Count) duplicate PATH entry/entries") -Severity 'Information' `
                -Component 'System/Environment' `
                -Detail ("Duplicate PATH directories: " + ($dupes -join '; ')) `
                -LikelyCause 'The same directory was added to PATH more than once.' `
                -Confidence 60 `
                -Recommendation 'Remove duplicate PATH entries to keep the environment tidy.')
        }

        # Broken (non-existent) entries
        $broken = [System.Collections.Generic.List[string]]::new()
        foreach ($e in ($entries | Sort-Object -Unique)) {
            try {
                $expanded = [Environment]::ExpandEnvironmentVariables($e)
                if (-not (Test-Path -LiteralPath $expanded)) { $broken.Add($e) }
            } catch {
                $broken.Add($e)
            }
        }
        Set-OmniResultMetric -Result $result -Name 'PathBrokenCount' -Value $broken.Count
        if ($broken.Count -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("$($broken.Count) PATH entry/entries point to missing directories") -Severity 'Warning' `
                -Component 'System/Environment' `
                -Detail ("Non-existent PATH directories: " + (($broken | Select-Object -First 15) -join '; ')) `
                -LikelyCause 'Software was uninstalled or moved without cleaning up PATH.' `
                -Confidence 65 `
                -Recommendation 'Remove broken PATH entries to avoid slow lookups and confusion.')
        }
    } catch {
        $log.Warn("PATH analysis failed: $($_.Exception.Message)", 'Environment Variables')
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Environment variables healthy' -Severity 'Pass' -Component 'System/Environment' `
            -Detail 'Environment variables inspected; no broken PATH entries detected.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
