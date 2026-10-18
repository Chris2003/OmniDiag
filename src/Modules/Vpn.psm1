<# .SYNOPSIS OmniDiag diagnostic module: VPN client and failure posture. #>

Set-StrictMode -Version Latest
if (-not (Get-Command New-OmniFinding -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    @{ Name='VPN'; Id='network.vpn'; Group='network'; NetworkAccess='None'; Category='Network'; Description='Windows VPN profiles, connection state, adapters, and recent RasClient failures.'; RequiresAdmin=$false; Order=470; Enabled=$true }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Context)
    $result = New-OmniResult -ModuleName 'VPN' -Category 'Network' -HadAdmin $Context.IsAdmin
    $profiles = @(); $vpnAdapters = @(); $failureCount = 0
    try {
        if (Get-Command Get-VpnConnection -ErrorAction SilentlyContinue) { $profiles = @(Get-VpnConnection -ErrorAction SilentlyContinue) }
    } catch { $Context.Logger.Debug("VPN profile query failed: $($_.Exception.Message)", 'VPN') }
    try {
        if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
            $vpnAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'VPN|TAP|TUN|WireGuard|AnyConnect|GlobalProtect|Fortinet|Pulse|Juniper' })
        }
    } catch { $Context.Logger.Debug("VPN adapter query failed: $($_.Exception.Message)", 'VPN') }
    # Bounded event query: the scan's time range (default: last 7 days, never more than
    # 30 days) and at most $maxEvents events, newest first.
    $maxEvents = 200
    $end = Get-Date; $start = $end.AddDays(-7)
    $rangeProp = $Context.PSObject.Properties['TimeRange']
    if ($rangeProp -and $rangeProp.Value) {
        if ($rangeProp.Value.PSObject.Properties['End'] -and $rangeProp.Value.End) { $end = [datetime]$rangeProp.Value.End }
        if ($rangeProp.Value.PSObject.Properties['Start'] -and $rangeProp.Value.Start) { $start = [datetime]$rangeProp.Value.Start }
    }
    if ($start -lt $end.AddDays(-30)) { $start = $end.AddDays(-30) }
    try {
        if ((Get-Command Get-WinEvent -ErrorAction SilentlyContinue) -and (Get-WinEvent -ListLog 'Microsoft-Windows-RasClient/Operational' -ErrorAction SilentlyContinue)) {
            $failureCount = @(Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-RasClient/Operational'; Level=2; StartTime=$start; EndTime=$end } -MaxEvents $maxEvents -ErrorAction SilentlyContinue).Count
        }
    } catch { $Context.Logger.Debug("RasClient event query failed: $($_.Exception.Message)", 'VPN') }

    Set-OmniResultMetric -Result $result -Name 'ProfileCount' -Value $profiles.Count
    $connectedNames = @($profiles | Where-Object ConnectionStatus -eq Connected | ForEach-Object { [string]$_.Name })
    Set-OmniResultMetric -Result $result -Name 'ConnectedProfiles' -Value ($connectedNames -join ', ')
    Set-OmniResultMetric -Result $result -Name 'DetectedAdapterCount' -Value $vpnAdapters.Count
    Set-OmniResultMetric -Result $result -Name 'RecentRasClientErrorCount' -Value $failureCount
    Set-OmniResultMetric -Result $result -Name 'RasClientErrorCountCapped' -Value ($failureCount -ge $maxEvents)
    if ($failureCount -gt 0) {
        $countText = if ($failureCount -ge $maxEvents) { "$maxEvents or more" } else { "$failureCount" }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Id 'network-vpn-rasclient-errors' -Title "$countText recent VPN client errors" -Severity Warning -Component 'Network/VPN' -Detail 'RasClient logged connection errors in the selected time range.' -LikelyCause 'Authentication, gateway reachability, protocol, certificate, or policy negotiation failed.' -Confidence 70 -Recommendation 'Review the newest RasClient Operational events, then correlate their error codes with DNS, proxy, certificate, and identity findings.')
    } elseif ($profiles.Count -eq 0 -and $vpnAdapters.Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No Windows VPN configuration detected' -Severity Information -Component 'Network/VPN' -Detail 'No built-in VPN profile or recognizable VPN adapter was found.')
    } else {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'VPN posture collected' -Severity Pass -Component 'Network/VPN' -Detail 'VPN configuration was detected with no recent RasClient error event.')
    }
    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest','Invoke-OmniModuleScan')
