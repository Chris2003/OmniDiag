<#
.SYNOPSIS
    OmniDiag diagnostic module: Network.

.DESCRIPTION
    Collects IP/adapter/DNS/gateway configuration and runs reachability probes
    (gateway, internet by IP, DNS resolution), then correlates the results into
    interpreted findings - including the classic "gateway reachable but DNS
    failing => DNS server issue" diagnosis.

    Probes use System.Net.NetworkInformation.Ping and System.Net.Dns so behavior
    is consistent across Windows PowerShell 5.1 and PowerShell 7. Public-IP lookup
    is the only step that contacts an external service and is OFF by default to
    honor the local-only privacy stance (enable via Config 'CheckPublicIP').

    Per-run options (via $Context.Config):
        InternetProbeIp   string  IP to ping for internet reachability. Default 1.1.1.1.
        DnsProbeHost      string  Hostname to resolve for DNS test. Default www.microsoft.com.
        CheckPublicIP     bool    Look up the public IP (external call). Default $false.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'New-OmniFinding' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Core\Models.psm1') -Global -Force -DisableNameChecking
}

function Get-OmniModuleManifest {
    [OutputType([hashtable])]
    param()
    return @{
        Name          = 'Network'
        Category      = 'Network'
        Description   = 'IP configuration, DNS, gateway, adapters, and connectivity diagnostics.'
        RequiresAdmin = $false
        Order         = 30
        Enabled       = $true
    }
}

# --- internal helpers ------------------------------------------------------

function Invoke-OmniPing {
    param([string] $Target, [int] $Count = 4, [int] $TimeoutMs = 1000)
    $ping = [System.Net.NetworkInformation.Ping]::new()
    $ok = 0; $rtts = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, $TimeoutMs)
            if ($r.Status -eq 'Success') { $ok++; $rtts.Add([int]$r.RoundtripTime) }
        } catch { }
    }
    [pscustomobject]@{
        Target    = $Target
        Sent      = $Count
        Received  = $ok
        Success   = ($ok -gt 0)
        LossPct   = [int]((($Count - $ok) / $Count) * 100)
        AvgMs     = if ($rtts.Count -gt 0) { [int](($rtts | Measure-Object -Average).Average) } else { $null }
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [pscustomobject] $Context)

    $result = New-OmniResult -ModuleName 'Network' -Category 'Network' -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $cfg = $Context.Config

    $internetIp = if ($cfg.ContainsKey('InternetProbeIp')) { [string]$cfg['InternetProbeIp'] } else { '1.1.1.1' }
    $dnsHost    = if ($cfg.ContainsKey('DnsProbeHost'))    { [string]$cfg['DnsProbeHost'] }    else { 'www.microsoft.com' }
    $checkPub   = $cfg.ContainsKey('CheckPublicIP') -and $cfg['CheckPublicIP']

    # --- Adapters ---------------------------------------------------------
    $upAdapters = @()
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -ne 'Not Present' }
        $upAdapters = @($adapters | Where-Object Status -eq 'Up')
        Set-OmniResultMetric -Result $result -Name 'AdaptersUp' -Value $upAdapters.Count
        foreach ($a in $upAdapters) {
            Set-OmniResultMetric -Result $result -Name "NIC: $($a.Name)" -Value ("{0}, {1}, MAC {2}" -f $a.InterfaceDescription, $a.LinkSpeed, $a.MacAddress)
        }
        if ($upAdapters.Count -eq 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No active network adapters' -Severity 'Critical' `
                -Component 'Network/Adapter' -Detail 'No network adapter is in the Up state.' `
                -LikelyCause 'Cable unplugged, Wi-Fi off, or all adapters disabled.' -Confidence 80 `
                -Recommendation 'Check the physical connection / Wi-Fi switch and enable the adapter.')
        }
    } catch {
        $log.Warn("Get-NetAdapter failed: $($_.Exception.Message)", 'Network')
    }

    # --- IP configuration, gateway, DNS servers ---------------------------
    $gateway = $null
    try {
        $cfgs = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway }
        $primary = $cfgs | Select-Object -First 1
        if ($primary) {
            $ipv4 = ($primary.IPv4Address | Select-Object -First 1).IPAddress
            $gateway = ($primary.IPv4DefaultGateway | Select-Object -First 1).NextHop
            $dnsServers = @($primary.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses } )
            Set-OmniResultMetric -Result $result -Name 'IPv4Address' -Value $ipv4
            Set-OmniResultMetric -Result $result -Name 'DefaultGateway' -Value $gateway
            Set-OmniResultMetric -Result $result -Name 'DNSServers' -Value ($dnsServers -join ', ')
        } else {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No default gateway configured' -Severity 'Critical' `
                -Component 'Network/Gateway' -Detail 'No interface has an IPv4 default gateway.' `
                -LikelyCause 'DHCP failure, limited connectivity, or misconfiguration.' -Confidence 75 `
                -Recommendation 'Renew the DHCP lease (ipconfig /renew) and verify the network link.')
        }
    } catch {
        $log.Warn("Get-NetIPConfiguration failed: $($_.Exception.Message)", 'Network')
    }

    # --- Reachability probes (the correlation engine) ---------------------
    $gwProbe = if ($gateway) { Invoke-OmniPing -Target $gateway -Count 4 } else { $null }
    $netProbe = Invoke-OmniPing -Target $internetIp -Count 4

    $dnsOk = $false; $dnsError = $null
    try {
        [void][System.Net.Dns]::GetHostEntry($dnsHost)
        $dnsOk = $true
    } catch { $dnsError = $_.Exception.Message }

    if ($gwProbe) {
        Set-OmniResultMetric -Result $result -Name 'GatewayPing' -Value ("{0}, {1}% loss, {2} ms" -f $(if ($gwProbe.Success) { 'reachable' } else { 'unreachable' }), $gwProbe.LossPct, $gwProbe.AvgMs)
    }
    Set-OmniResultMetric -Result $result -Name 'InternetPing' -Value ("{0}, {1}% loss, {2} ms" -f $(if ($netProbe.Success) { 'reachable' } else { 'unreachable' }), $netProbe.LossPct, $netProbe.AvgMs)
    Set-OmniResultMetric -Result $result -Name 'DnsResolution' -Value $(if ($dnsOk) { "OK ($dnsHost)" } else { "FAILED ($dnsHost)" })

    # Correlated diagnosis:
    $gwReachable = (-not $gateway) -or ($gwProbe -and $gwProbe.Success)
    if ($gateway -and $gwProbe -and -not $gwProbe.Success) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Default gateway is unreachable' -Severity 'Critical' `
            -Component 'Network/Gateway' -Detail "Ping to the gateway $gateway failed (100% loss)." `
            -LikelyCause 'Local link problem: cable/Wi-Fi, switch port, or a down router.' -Confidence 80 `
            -Recommendation 'Check the physical connection and the local router/switch.')
    }
    elseif ($gwReachable -and -not $netProbe.Success -and -not $dnsOk) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'No internet connectivity' -Severity 'Error' `
            -Component 'Network/Internet' -Detail "Gateway is reachable but $internetIp is not, and DNS resolution failed." `
            -LikelyCause 'Upstream/ISP outage or a firewall blocking outbound traffic.' -Confidence 60 `
            -Recommendation 'Verify the modem/ISP link and any edge firewall rules.')
    }
    elseif ($gwReachable -and $netProbe.Success -and -not $dnsOk) {
        # The spec's flagship example.
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'DNS resolution is failing' -Severity 'Error' `
            -Component 'Network/DNS' `
            -Detail "Internet is reachable by IP ($internetIp responds) but name resolution for '$dnsHost' failed: $dnsError" `
            -LikelyCause 'DNS requests are failing while gateway/internet communication succeeds - likely a DNS server problem or bad DNS configuration.' `
            -Confidence 85 `
            -Recommendation 'Verify the configured DNS servers, flush the DNS cache (Clear-DnsClientCache), or switch to a known-good resolver.')
    }
    elseif ($netProbe.Success -and $netProbe.LossPct -ge 25) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Packet loss to the internet ($($netProbe.LossPct)%)" -Severity 'Warning' `
            -Component 'Network/Internet' -Detail "Ping to $internetIp showed $($netProbe.LossPct)% loss, avg $($netProbe.AvgMs) ms." `
            -LikelyCause 'Unstable link, congestion, or Wi-Fi interference.' -Confidence 55 `
            -Recommendation 'Test on a wired connection; check Wi-Fi signal and for interference.')
    }
    elseif ($netProbe.Success -and $netProbe.AvgMs -ne $null -and $netProbe.AvgMs -ge 150) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "High internet latency ($($netProbe.AvgMs) ms)" -Severity 'Warning' `
            -Component 'Network/Internet' -Detail "Average round-trip to $internetIp is $($netProbe.AvgMs) ms." `
            -LikelyCause 'Distant route, congestion, or a slow link.' -Confidence 50 `
            -Recommendation 'Compare against a wired connection; investigate if calls/RDP feel laggy.')
    }

    # --- Firewall profiles ------------------------------------------------
    try {
        $fw = Get-NetFirewallProfile -ErrorAction Stop
        $disabled = @($fw | Where-Object { -not $_.Enabled })
        Set-OmniResultMetric -Result $result -Name 'FirewallProfiles' -Value (($fw | ForEach-Object { "$($_.Name)=$([bool]$_.Enabled)" }) -join ', ')
        if ($disabled.Count -gt 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title "Firewall disabled on $($disabled.Count) profile(s)" -Severity 'Warning' `
                -Component 'Network/Firewall' -Detail ("Disabled: {0}" -f (($disabled.Name) -join ', ')) `
                -LikelyCause 'Firewall profile turned off.' -Confidence 70 `
                -Recommendation 'Re-enable the Windows Firewall unless a managed policy intentionally disables it.')
        }
    } catch { $log.Debug("Get-NetFirewallProfile failed: $($_.Exception.Message)", 'Network') }

    # --- Proxy / VPN detection -------------------------------------------
    try {
        $proxy = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($proxy.ProxyEnable -eq 1) {
            Set-OmniResultMetric -Result $result -Name 'Proxy' -Value $proxy.ProxyServer
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'A proxy server is configured' -Severity 'Information' `
                -Component 'Network/Proxy' -Detail "Proxy: $($proxy.ProxyServer)" `
                -LikelyCause 'A system proxy is enabled.' `
                -Recommendation 'If connectivity issues exist, verify the proxy is reachable and correct.')
        } else {
            Set-OmniResultMetric -Result $result -Name 'Proxy' -Value 'none'
        }
    } catch { }

    try {
        $vpns = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'VPN|TAP|WireGuard|WAN Miniport|AnyConnect|GlobalProtect') })
        if ($vpns.Count -gt 0) {
            Set-OmniResultMetric -Result $result -Name 'VPN' -Value (($vpns.Name) -join ', ')
            Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'VPN adapter is active' -Severity 'Information' `
                -Component 'Network/VPN' -Detail ("Active VPN-like adapter(s): {0}" -f (($vpns.Name) -join ', ')) `
                -Recommendation 'If DNS/routing issues exist, test with the VPN disconnected to rule out a conflict.')
        }
    } catch { }

    # --- DNS cache size (informational) ----------------------------------
    try {
        $cache = @(Get-DnsClientCache -ErrorAction Stop)
        Set-OmniResultMetric -Result $result -Name 'DnsCacheEntries' -Value $cache.Count
    } catch { }

    # --- Optional public IP (external call, opt-in) ----------------------
    if ($checkPub) {
        try {
            $pub = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5 -ErrorAction Stop).ip
            Set-OmniResultMetric -Result $result -Name 'PublicIP' -Value $pub
        } catch { $log.Debug("Public IP lookup failed: $($_.Exception.Message)", 'Network') }
    }

    # Positive finding when nothing notable surfaced.
    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding -Title 'Network connectivity looks healthy' -Severity 'Pass' `
            -Component 'Network' -Detail 'Gateway, internet, and DNS probes succeeded.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
