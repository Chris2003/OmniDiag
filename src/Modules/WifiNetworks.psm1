<#
.SYNOPSIS
    OmniDiag diagnostic module: WiFi Networks.

.DESCRIPTION
    Reports the current wireless connection (SSID, signal, connected or not) and counts
    nearby visible networks using 'netsh wlan show interfaces' and 'netsh wlan show
    networks'. Flags a weak connected signal. Degrades gracefully when no wireless
    adapter is present or the WLAN AutoConfig service is not running.

    Why netsh: Windows has no built-in PowerShell cmdlet or CIM class for the WLAN state
    (the Native Wifi API, WlanQueryInterface, needs compiled interop, which OmniDiag does
    not use). netsh labels are translated on localized Windows, so the parsing keys only
    on stable parts of the output:
        * an interface exists when a value is a GUID (each interface lists its GUID);
        * 'SSID' and 'SSID <n>' labels are not translated;
        * the signal is the first value of the form '<number>%';
        * the interface is connected when it reports an SSID (a disconnected interface
          does not).
    Nothing English-only (such as the 'State' text) drives a finding.

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
        Id            = 'network.wifi-networks'
        Group         = 'network'
        NetworkAccess = 'None'
        Category      = 'Network'
        Description   = 'Reports current wireless connection quality and nearby networks.'
        RequiresAdmin = $false
        Order         = 450
        Enabled       = $true
    }
}

function Invoke-OmniWlanNetsh {
    <#
    .SYNOPSIS
        Internal: runs 'netsh wlan <Arguments>' and returns its text ('' when netsh is
        unavailable or fails).
    #>
    [OutputType([string])]
    param([string[]] $Arguments)
    if (-not (Get-Command -Name 'netsh.exe' -ErrorAction SilentlyContinue)) { return '' }
    return ((@(& netsh.exe wlan @Arguments 2>&1) | ForEach-Object { [string]$_ }) -join "`n")
}

function ConvertFrom-OmniWlanInterfaceText {
    <#
    .SYNOPSIS
        Internal: parses 'netsh wlan show interfaces' language-independently.

    .DESCRIPTION
        Returns HasInterface (a GUID value is present), Connected (an SSID is reported),
        Ssid, and SignalPercent (first '<n>%' value, or $null).

    .PARAMETER Text
        The command output.
    #>
    [OutputType([pscustomobject])]
    param([AllowNull()] [AllowEmptyString()] [string] $Text)
    $info = [pscustomobject]@{ HasInterface = $false; Connected = $false; Ssid = $null; SignalPercent = $null }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $info }
    foreach ($line in ($Text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*([^:]+?)\s*:\s*(.*?)\s*$')
        if (-not $m.Success) { continue }
        $label = $m.Groups[1].Value
        $value = $m.Groups[2].Value
        if ($value -match '^\{?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}?$') { $info.HasInterface = $true }
        if ($null -eq $info.Ssid -and $label -ceq 'SSID' -and $value) { $info.Ssid = $value }
        if ($null -eq $info.SignalPercent) {
            $sm = [regex]::Match($value, '^(\d{1,3})\s*%$')
            if ($sm.Success) { $info.SignalPercent = [int]$sm.Groups[1].Value }
        }
    }
    $info.Connected = [bool]$info.Ssid
    return $info
}

function Invoke-OmniModuleScan {
    <#
    .SYNOPSIS
        Runs the WiFi check and returns an OmniDiag.Result.

    .PARAMETER Context
        The scan context (Logger, IsAdmin, ...).
    #>
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
    $iface = $null
    try {
        $iface = ConvertFrom-OmniWlanInterfaceText -Text (Invoke-OmniWlanNetsh -Arguments @('show', 'interfaces'))
    } catch {
        $log.Debug("netsh wlan show interfaces failed: $($_.Exception.Message)", 'WiFi Networks')
    }

    if ($null -eq $iface -or -not $iface.HasInterface) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No wireless adapter present' -Severity 'Information' -Component 'Network/WiFi' `
            -Detail 'netsh wlan reported no usable wireless interface: there is no adapter, the WLAN AutoConfig service is not running, or (on recent Windows 11 builds) location access for desktop apps is off, which netsh wlan may need.')
        return (Complete-OmniResult -Result $result)
    }

    $ssid = $iface.Ssid
    $signalPercent = $iface.SignalPercent
    Set-OmniResultMetric -Result $result -Name 'CurrentSSID' -Value ($ssid)
    Set-OmniResultMetric -Result $result -Name 'SignalPercent' -Value ($signalPercent)
    Set-OmniResultMetric -Result $result -Name 'ConnectionState' -Value $(if ($iface.Connected) { 'Connected' } else { 'Disconnected' })

    # --- Nearby networks --------------------------------------------------
    $nearbyCount = $null
    try {
        $netText = Invoke-OmniWlanNetsh -Arguments @('show', 'networks', 'mode=bssid')
        if (-not [string]::IsNullOrWhiteSpace($netText)) {
            $nearbyCount = [regex]::Matches($netText, '(?im)^\s*SSID\s+\d+\s*:').Count
        }
    } catch {
        $log.Debug("netsh wlan show networks failed: $($_.Exception.Message)", 'WiFi Networks')
    }
    Set-OmniResultMetric -Result $result -Name 'NearbyNetworkCount' -Value ($nearbyCount)

    if ($iface.Connected) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-wifi-connected' `
            -Title ("Connected to '{0}'" -f $ssid) -Severity 'Information' -Component 'Network/WiFi' `
            -Detail ("Signal strength: {0}%. Nearby networks: {1}." -f `
                $(if ($null -ne $signalPercent) { $signalPercent } else { 'unknown' }), `
                $(if ($null -ne $nearbyCount) { $nearbyCount } else { 'unknown' })))

        if ($null -ne $signalPercent -and $signalPercent -lt 40) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-wifi-weak-signal' `
                -Title ("Weak WiFi signal ({0}%)" -f $signalPercent) -Severity 'Warning' -Component 'Network/WiFi' `
                -Detail ("The connection to '{0}' has a signal strength of only {1}%." -f $ssid, $signalPercent) `
                -LikelyCause 'The device is far from the access point or there is significant interference.' `
                -Confidence 70 `
                -Recommendation 'Move closer to the access point, reduce obstructions/interference, or add a repeater.')
        }
    } else {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-wifi-not-connected' `
            -Title 'Wireless adapter is not connected' -Severity 'Information' -Component 'Network/WiFi' `
            -Detail ("A wireless interface is present but not connected to a network. Nearby networks: {0}." -f `
                $(if ($null -ne $nearbyCount) { $nearbyCount } else { 'unknown' })))
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Wireless connection is healthy' -Severity 'Pass' -Component 'Network/WiFi' `
            -Detail 'Wireless status was collected without issues.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
