<#
.SYNOPSIS
    OmniDiag diagnostic module: Temp Files.

.DESCRIPTION
    Estimates reclaimable space by summing file sizes across common temp/cache
    locations (user temp, Windows temp, prefetch, and reachable browser caches).
    All enumeration is bounded and fails soft; never throws. Does not delete.

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
        Name          = 'Temp Files'
        Category      = 'Storage'
        Description   = 'Estimated reclaimable space across temp and cache locations.'
        RequiresAdmin = $false
        Order         = 320
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

    $result = New-OmniResult -ModuleName 'Temp Files' -Category 'Storage' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # Helper: sum bytes under a path, fully fail-soft.
    $sumPath = {
        param([string] $Path)
        try {
            if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return [long]0 }
            $measured = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
            if ($measured -and $measured.Sum) { return [long]$measured.Sum }
            return [long]0
        } catch {
            return [long]0
        }
    }

    $paths = @(
        $env:TEMP,
        'C:\Windows\Temp',
        'C:\Windows\Prefetch'
    )

    # Per-user browser caches (best-effort, only if reachable).
    $localAppData = $env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $paths += @(
            (Join-Path $localAppData 'Google\Chrome\User Data\Default\Cache'),
            (Join-Path $localAppData 'Microsoft\Edge\User Data\Default\Cache'),
            (Join-Path $localAppData 'Mozilla\Firefox\Profiles')
        )
    }

    $totalBytes = [long]0
    foreach ($p in $paths) {
        try {
            $totalBytes += (& $sumPath $p)
        } catch {
            $log.Debug("Temp size scan failed for ${p}: $($_.Exception.Message)", 'Temp Files')
        }
    }

    $reclaimableMB = [math]::Round(($totalBytes / 1MB), 0)
    Set-OmniResultMetric -Result $result -Name 'ReclaimableMB' -Value $reclaimableMB

    if ($reclaimableMB -gt 2048) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title "$reclaimableMB MB of temporary files can be reclaimed" -Severity 'Warning' `
            -Component 'Storage/Temp' `
            -Detail "Temp and cache locations hold approximately $reclaimableMB MB." `
            -LikelyCause 'Accumulated temporary and cache files consuming disk space.' `
            -Confidence 75 `
            -Recommendation 'Run the Clear Temp Files repair to free the space.')
    } else {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title "$reclaimableMB MB of temporary files present" -Severity 'Information' `
            -Component 'Storage/Temp' `
            -Detail "Temp and cache locations hold approximately $reclaimableMB MB.")
    }

    # Always record at least one positive finding when nothing is wrong.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Temp file usage within normal range' -Severity 'Pass' -Component 'Storage/Temp' `
            -Detail 'Temporary and cache file usage does not warrant cleanup.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
