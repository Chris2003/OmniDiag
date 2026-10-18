<#
.SYNOPSIS
    OmniDiag diagnostic module: Network.

.DESCRIPTION
    Reports active network adapters, packet-error counters, and the default gateway
    (all local). Connectivity probes are opt-in (decision 1): only when
    $Context.NetworkProbes is set does it ping the default gateway and a public IP
    (1.1.1.1) via System.Net.NetworkInformation.Ping and resolve www.microsoft.com via
    System.Net.Dns, then correlate the results into interpreted findings (e.g. gateway
    reachable but DNS/internet failing). Without probes it adds an Information finding
    saying how to run them. Targets come from Get-OmniProbeTarget
    ($Context.Config.ProbeTargets: PingGateway, PublicAddress, DnsName, TimeoutMs).

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
        Name          = 'Network'
        Id            = 'network.network'
        Group         = 'network'
        NetworkAccess = 'Internet'
        Category      = 'Network'
        Description   = 'Active adapters, packet errors, default gateway, and opt-in connectivity probes.'
        RequiresAdmin = $false
        Order         = 400
        Enabled       = $true
    }
}

function Invoke-OmniNetworkPing {
    <#
    .SYNOPSIS
        Internal (connectivity probe): pings a target once; returns the round trip in ms,
        or $null when it does not answer. Only called when probes are enabled.
    #>
    param([string] $Target, [int] $TimeoutMs = 2000)
    $p = $null
    try {
        $p = [System.Net.NetworkInformation.Ping]::new()
        $reply = $p.Send($Target, $TimeoutMs)
        if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            return [int]$reply.RoundtripTime
        }
        return $null
    } catch {
        return $null
    } finally {
        if ($p) { try { $p.Dispose() } catch { Write-Verbose $_.Exception.Message } }
    }
}

function Test-OmniNetworkDnsProbe {
    <#
    .SYNOPSIS
        Internal (connectivity probe): resolves a host name; $true when it returns at
        least one address. Only called when probes are enabled.
    #>
    param([string] $Name, $Logger)
    try {
        $entry = [System.Net.Dns]::GetHostEntry($Name)
        return ($null -ne $entry -and @($entry.AddressList).Count -gt 0)
    } catch {
        if ($Logger) { $Logger.Debug("DNS resolution failed: $($_.Exception.Message)", 'Network') }
        return $false
    }
}

function Invoke-OmniModuleScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $result = New-OmniResult -ModuleName 'Network' -Category 'Network' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger
    $probes = Test-OmniNetworkProbeEnabled -Context $Context
    $targets = Get-OmniProbeTarget -Context $Context
    Set-OmniResultMetric -Result $result -Name 'ConnectivityProbesRun' -Value $probes

    # --- Active adapters ---------------------------------------------------
    $activeCount = 0
    try {
        $adapters = $null
        if (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) {
            try {
                $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { "$($_.Status)" -eq 'Up' })
            } catch { $adapters = $null }
        }

        if ($null -ne $adapters) {
            $activeCount = $adapters.Count
            $list = @($adapters | ForEach-Object { "{0} ({1})" -f $_.Name, $_.LinkSpeed })
            Set-OmniResultMetric -Result $result -Name 'ActiveAdapterList' -Value $list

            # Packet errors (best-effort).
            try {
                foreach ($a in $adapters) {
                    $stats = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
                    if ($stats) {
                        $rxErr = try { [int64]$stats.ReceivedPacketErrors } catch { 0 }
                        $txErr = try { [int64]$stats.OutboundPacketErrors } catch { 0 }
                        Set-OmniResultMetric -Result $result -Name "Adapter.$($a.Name).RxErrors" -Value $rxErr
                        Set-OmniResultMetric -Result $result -Name "Adapter.$($a.Name).TxErrors" -Value $txErr
                        if (($rxErr + $txErr) -gt 1000) {
                            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                                -Title "High packet errors on $($a.Name)" -Severity 'Warning' `
                                -Component 'Network/Adapter' `
                                -Detail "Adapter '$($a.Name)' reports $rxErr receive and $txErr transmit packet errors." `
                                -LikelyCause 'Faulty cable/port, driver issue, or link-layer interference.' `
                                -Confidence 55 `
                                -Recommendation 'Check cabling/port, update the NIC driver, and monitor error counters.')
                        }
                    }
                }
            } catch {
                $log.Debug("Adapter statistics failed: $($_.Exception.Message)", 'Network')
            }
        } else {
            $wmiAdapters = @(Get-CimInstance -ClassName 'Win32_NetworkAdapter' -ErrorAction Stop |
                Where-Object { $_.NetEnabled -eq $true })
            $activeCount = $wmiAdapters.Count
            $list = @($wmiAdapters | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Speed })
            Set-OmniResultMetric -Result $result -Name 'ActiveAdapterList' -Value $list
        }
    } catch {
        $log.Warn("Adapter enumeration failed: $($_.Exception.Message)", 'Network')
    }
    Set-OmniResultMetric -Result $result -Name 'ActiveAdapterCount' -Value $activeCount

    if ($activeCount -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No active network adapters' -Severity 'Critical' `
            -Component 'Network/Adapter' `
            -Detail 'No network adapter is in the Up state.' `
            -LikelyCause 'All adapters disabled/disconnected, or driver failure.' `
            -Confidence 80 `
            -Recommendation 'Check cabling/Wi-Fi, enable the adapter, and verify NIC drivers.')
    }

    # --- Default gateway ---------------------------------------------------
    $gateway = $null
    try {
        if (Get-Command -Name 'Get-NetIPConfiguration' -ErrorAction SilentlyContinue) {
            $cfgs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
            foreach ($c in $cfgs) {
                if ($c.IPv4DefaultGateway) {
                    $gw = @($c.IPv4DefaultGateway | ForEach-Object { $_.NextHop } | Where-Object { $_ }) | Select-Object -First 1
                    if ($gw) { $gateway = $gw; break }
                }
            }
        }
    } catch {
        $log.Debug("Gateway discovery failed: $($_.Exception.Message)", 'Network')
    }

    if ($gateway) { Set-OmniResultMetric -Result $result -Name 'DefaultGateway' -Value $gateway }

    if (-not $probes) {
        # Probes are opt-in (decision 1): report the local state and say how to probe.
        $what = if ($targets.PingGateway) { 'ping the default gateway and ' } else { 'ping ' }
        Add-OmniFinding -Result $result -Finding (New-OmniProbeSkippedFinding -Component 'Network/Connectivity' `
            -Probe ("{0}{1}, or resolve {2}" -f $what, $targets.PublicAddress, $targets.DnsName))
        if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
            Add-OmniFinding -Result $result -Finding (New-OmniFinding `
                -Title 'Network adapters healthy' -Severity 'Pass' -Component 'Network' `
                -Detail 'An active adapter is present and its packet-error counters are normal (connectivity not probed).')
        }
        return (Complete-OmniResult -Result $result)
    }

    $gatewayLatency = $null
    if ($gateway -and $targets.PingGateway) {
        $gatewayLatency = Invoke-OmniNetworkPing -Target $gateway -TimeoutMs $targets.TimeoutMs
    }
    Set-OmniResultMetric -Result $result -Name 'GatewayLatencyMs' -Value ($(if ($null -ne $gatewayLatency) { $gatewayLatency } else { -1 }))

    # --- Internet reachability (public IP) ---------------------------------
    $internetLatency = Invoke-OmniNetworkPing -Target $targets.PublicAddress -TimeoutMs $targets.TimeoutMs
    $internetOk = ($null -ne $internetLatency)
    Set-OmniResultMetric -Result $result -Name 'InternetReachable' -Value $internetOk
    Set-OmniResultMetric -Result $result -Name 'InternetLatencyMs' -Value ($(if ($null -ne $internetLatency) { $internetLatency } else { -1 }))

    # --- DNS resolution ----------------------------------------------------
    $dnsOk = Test-OmniNetworkDnsProbe -Name $targets.DnsName -Logger $log
    Set-OmniResultMetric -Result $result -Name 'DnsOk' -Value $dnsOk

    # --- Correlated connectivity findings ----------------------------------
    # Without a gateway probe (none found, or PingGateway off) the gateway counts as
    # unknown, which only the 'nothing works' finding treats as down.
    $gatewayOk = ($null -ne $gatewayLatency)
    $publicIp = $targets.PublicAddress

    if (-not $gatewayOk -and -not $internetOk -and -not $dnsOk -and $activeCount -gt 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'No network connectivity' -Severity 'Critical' `
            -Component 'Network/Connectivity' `
            -Detail 'Gateway, public IP, and DNS are all unreachable despite an active adapter.' `
            -LikelyCause 'Local link/gateway down, or no IP lease.' `
            -Confidence 75 `
            -Recommendation 'Check the local network/router and IP configuration.')
    } elseif ($gatewayOk -and (-not $internetOk -or -not $dnsOk)) {
        $detail = if (-not $dnsOk -and -not $internetOk) {
            "The gateway responds but both internet ($publicIp) and DNS resolution fail."
        } elseif (-not $dnsOk) {
            "The gateway and internet ($publicIp) respond but DNS resolution fails."
        } else {
            "The gateway responds but the public IP ($publicIp) is unreachable."
        }
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Partial connectivity (LAN up, WAN/DNS impaired)' -Severity 'Warning' `
            -Component 'Network/Connectivity' `
            -Detail $detail `
            -LikelyCause 'DNS server misconfiguration or an upstream/ISP outage past the gateway.' `
            -Confidence 65 `
            -Recommendation 'Verify DNS server settings and test upstream connectivity from the router.')
    }

    if (@($result.Findings | Where-Object { $_.SeverityRank -ge (Get-OmniSeverityRank 'Warning') }).Count -eq 0) {
        Add-OmniFinding -Result $result -Finding (New-OmniFinding `
            -Title 'Network healthy' -Severity 'Pass' -Component 'Network' `
            -Detail 'Active adapter present with working gateway, internet, and DNS resolution.')
    }

    return (Complete-OmniResult -Result $result)
}

Export-ModuleMember -Function @('Get-OmniModuleManifest', 'Invoke-OmniModuleScan')
