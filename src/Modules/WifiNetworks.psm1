<#
.SYNOPSIS
    OmniDiag diagnostic module: WiFi Networks.

.DESCRIPTION
    Reports the current wireless connection (SSID, signal, state) and counts nearby
    visible networks using netsh wlan. Flags a weak connected signal. Degrades
    gracefully when no wireless adapter is present.

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
        Name          = 'WiFi Networks'
        Category      = 'Network'
        Description   = 'Reports current wireless connection quality and nearby networks.'
        RequiresAdmin = $false
        Order         = 450
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

    $result = New-OmniResult -ModuleName 'WiFi Networks' -Category 'Network' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    # --- Current interface ------------------------------------------------
    $ifaceText = $null
    $hasInterface = $true
    try {
        $ifaceText = & netsh wlan show interfaces 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ifaceText) -or
            $ifaceText -match '(?im)There is no wireless interface|not running|is not started') {
            $hasInterface = $false
        }
    } catch {
        $log.Debug("netsh wlan show interfaces failed: $($_.Exception.Message)", 'WiFi Networks')
        $hasInterface = $false
    }

    if (-not $hasInterface) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No wireless adapter present' -Severity 'Information' -Component 'Network/WiFi' `
            -Detail 'No usable wireless interface was reported by netsh wlan.')
        return (Complete-OmniResult -Result $result)
    }

    $ssid = $null
    $signalPercent = $null
    $state = $null

    try {
        # Match "SSID" but not "BSSID".
        $mSsid = [regex]::Match($ifaceText, '(?im)^\s*SSID\s*:\s*(.+?)\s*$')
        if ($mSsid.Success) { $ssid = $mSsid.Groups[1].Value.Trim() }

        $mSignal = [regex]::Match($ifaceText, '(?im)^\s*Signal\s*:\s*(\d+)\s*%')
        if ($mSignal.Success) { $signalPercent = [int]$mSignal.Groups[1].Value }

        $mState = [regex]::Match($ifaceText, '(?im)^\s*State\s*:\s*(.+?)\s*$')
        if ($mState.Success) { $state = $mState.Groups[1].Value.Trim() }
    } catch {
        $log.Debug("Parsing interface output failed: $($_.Exception.Message)", 'WiFi Networks')
    }

    Set-OmniResultMetric -Result $result -Name 'CurrentSSID' -Value ($ssid)
    Set-OmniResultMetric -Result $result -Name 'SignalPercent' -Value ($signalPercent)
    Set-OmniResultMetric -Result $result -Name 'ConnectionState' -Value ($state)

    # --- Nearby networks --------------------------------------------------
    $nearbyCount = $null
    try {
        $netText = & netsh wlan show networks mode=bssid 2>&1 | Out-String
        if (-not [string]::IsNullOrWhiteSpace($netText)) {
            $matches = [regex]::Matches($netText, '(?im)^\s*SSID\s+\d+\s*:')
            $nearbyCount = $matches.Count
        }
    } catch {
        $log.Debug("netsh wlan show networks failed: $($_.Exception.Message)", 'WiFi Networks')
    }
    Set-OmniResultMetric -Result $result -Name 'NearbyNetworkCount' -Value ($nearbyCount)

    try {
        if ($ssid -and $state -match '(?i)connected') {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title ("Connected to '{0}'" -f $ssid) -Severity 'Information' -Component 'Network/WiFi' `
                -Detail ("Signal strength: {0}%. Nearby networks: {1}." -f `
                    $(if ($null -ne $signalPercent) { $signalPercent } else { 'unknown' }), `
                    $(if ($null -ne $nearbyCount) { $nearbyCount } else { 'unknown' })))

            if ($null -ne $signalPercent -and $signalPercent -lt 40) {
                Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                    -Title ("Weak WiFi signal ({0}%)" -f $signalPercent) -Severity 'Warning' -Component 'Network/WiFi' `
                    -Detail ("The connection to '{0}' has a signal strength of only {1}%." -f $ssid, $signalPercent) `
                    -LikelyCause 'The device is far from the access point or there is significant interference.' `
                    -Confidence 70 `
                    -Recommendation 'Move closer to the access point, reduce obstructions/interference, or add a repeater.')
            }
        }
    } catch {
        $log.Debug("Finding generation failed: $($_.Exception.Message)", 'WiFi Networks')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Wireless connection is healthy' -Severity 'Pass' -Component 'Network/WiFi' `
            -Detail 'Wireless status was collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
