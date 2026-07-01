<#
.SYNOPSIS
    OmniDiag diagnostic module: Browser Diagnostics.

.DESCRIPTION
    Detects installed browsers (Edge, Chrome, Firefox) by their user-data folders,
    counts profiles, and estimates cache size best-effort. Warns when a browser
    cache is very large.

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
        Name          = 'Browser Diagnostics'
        Category      = 'Applications'
        Description   = 'Detects installed browsers, profiles, and cache usage.'
        RequiresAdmin = $false
        Order         = 800
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

    $result = New-OmniResult -ModuleName 'Browser Diagnostics' -Category 'Applications' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $localAppData = $env:LOCALAPPDATA
    $appData = $env:APPDATA

    # Helper: sum sizes of files under a path, bounded and soft-failing.
    $sizeGb = {
        param([string[]] $Paths)
        try {
            $existing = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
            if ($existing.Count -eq 0) { return $null }
            $bytes = (Get-ChildItem -LiteralPath $existing -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if ($null -eq $bytes) { return 0.0 }
            return [math]::Round(($bytes / 1GB), 2)
        } catch {
            return $null
        }
    }

    $foundAny = $false

    # --- Microsoft Edge ---------------------------------------------------
    try {
        $edgeRoot = Join-Path $localAppData 'Microsoft\Edge\User Data'
        if ($edgeRoot -and (Test-Path -LiteralPath $edgeRoot)) {
            $foundAny = $true
            Set-OmniResultMetric -Result $result -Name 'EdgeInstalled' -Value $true

            $profiles = @(Get-ChildItem -LiteralPath $edgeRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
            Set-OmniResultMetric -Result $result -Name 'EdgeProfileCount' -Value ($profiles.Count)

            $cachePaths = @($profiles | ForEach-Object { Join-Path $_.FullName 'Cache' })
            $cacheGb = & $sizeGb $cachePaths
            Set-OmniResultMetric -Result $result -Name 'EdgeCacheSizeGB' -Value $cacheGb

            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Microsoft Edge detected ({0} profile(s))" -f $profiles.Count) `
                -Severity 'Information' -Component 'Applications/Browser' `
                -Detail ("Edge cache is approximately {0} GB." -f $(if ($null -ne $cacheGb) { $cacheGb } else { 'unknown' })))

            if ($null -ne $cacheGb -and $cacheGb -gt 2) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("Edge cache is large ({0} GB)" -f $cacheGb) -Severity 'Warning' -Component 'Applications/Browser' `
                    -Detail "The Microsoft Edge cache is using approximately $cacheGb GB of disk space." `
                    -LikelyCause 'Accumulated browser cache over time.' -Confidence 60 `
                    -Recommendation 'Clear the browser cache to reclaim disk space.')
            }
        }
    } catch {
        $log.Debug("Edge detection failed: $($_.Exception.Message)", 'Browser Diagnostics')
    }

    # --- Google Chrome ----------------------------------------------------
    try {
        $chromeRoot = Join-Path $localAppData 'Google\Chrome\User Data'
        if ($chromeRoot -and (Test-Path -LiteralPath $chromeRoot)) {
            $foundAny = $true
            Set-OmniResultMetric -Result $result -Name 'ChromeInstalled' -Value $true

            $profiles = @(Get-ChildItem -LiteralPath $chromeRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
            Set-OmniResultMetric -Result $result -Name 'ChromeProfileCount' -Value ($profiles.Count)

            $cachePaths = @($profiles | ForEach-Object { Join-Path $_.FullName 'Cache' })
            $cacheGb = & $sizeGb $cachePaths
            Set-OmniResultMetric -Result $result -Name 'ChromeCacheSizeGB' -Value $cacheGb

            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Google Chrome detected ({0} profile(s))" -f $profiles.Count) `
                -Severity 'Information' -Component 'Applications/Browser' `
                -Detail ("Chrome cache is approximately {0} GB." -f $(if ($null -ne $cacheGb) { $cacheGb } else { 'unknown' })))

            if ($null -ne $cacheGb -and $cacheGb -gt 2) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("Chrome cache is large ({0} GB)" -f $cacheGb) -Severity 'Warning' -Component 'Applications/Browser' `
                    -Detail "The Google Chrome cache is using approximately $cacheGb GB of disk space." `
                    -LikelyCause 'Accumulated browser cache over time.' -Confidence 60 `
                    -Recommendation 'Clear the browser cache to reclaim disk space.')
            }
        }
    } catch {
        $log.Debug("Chrome detection failed: $($_.Exception.Message)", 'Browser Diagnostics')
    }

    # --- Mozilla Firefox --------------------------------------------------
    try {
        $ffRoot = Join-Path $appData 'Mozilla\Firefox\Profiles'
        if ($ffRoot -and (Test-Path -LiteralPath $ffRoot)) {
            $foundAny = $true
            Set-OmniResultMetric -Result $result -Name 'FirefoxInstalled' -Value $true

            $profiles = @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)
            Set-OmniResultMetric -Result $result -Name 'FirefoxProfileCount' -Value ($profiles.Count)

            # Firefox caches live under %LOCALAPPDATA%\Mozilla\Firefox\Profiles\<p>\cache2.
            $ffCacheRoot = Join-Path $localAppData 'Mozilla\Firefox\Profiles'
            $cachePaths = @()
            if ($ffCacheRoot -and (Test-Path -LiteralPath $ffCacheRoot)) {
                $cachePaths = @(Get-ChildItem -LiteralPath $ffCacheRoot -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName 'cache2' })
            }
            $cacheGb = & $sizeGb $cachePaths
            Set-OmniResultMetric -Result $result -Name 'FirefoxCacheSizeGB' -Value $cacheGb

            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Mozilla Firefox detected ({0} profile(s))" -f $profiles.Count) `
                -Severity 'Information' -Component 'Applications/Browser' `
                -Detail ("Firefox cache is approximately {0} GB." -f $(if ($null -ne $cacheGb) { $cacheGb } else { 'unknown' })))

            if ($null -ne $cacheGb -and $cacheGb -gt 2) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("Firefox cache is large ({0} GB)" -f $cacheGb) -Severity 'Warning' -Component 'Applications/Browser' `
                    -Detail "The Mozilla Firefox cache is using approximately $cacheGb GB of disk space." `
                    -LikelyCause 'Accumulated browser cache over time.' -Confidence 60 `
                    -Recommendation 'Clear the browser cache to reclaim disk space.')
            }
        }
    } catch {
        $log.Debug("Firefox detection failed: $($_.Exception.Message)", 'Browser Diagnostics')
    }

    if (-not $foundAny) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No supported browser profiles found' -Severity 'Information' -Component 'Applications/Browser' `
            -Detail 'No Edge, Chrome, or Firefox user-data folders were detected for the current user.')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Browser diagnostics collected' -Severity 'Pass' -Component 'Applications/Browser' `
            -Detail 'Browser detection and cache review completed without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
