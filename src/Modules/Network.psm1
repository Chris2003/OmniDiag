<#
.SYNOPSIS
    OmniDiag diagnostic module: Network.

.DESCRIPTION
    Reports active network adapters, packet-error counters, and runs bounded
    reachability probes: ping the default gateway and a public IP (1.1.1.1) via
    System.Net.NetworkInformation.Ping, plus a DNS resolution test via
    System.Net.Dns. Correlates results into interpreted findings (e.g. gateway
    reachable but DNS/internet failing).

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
        Category      = 'Network'
        Description   = 'Active adapters, packet errors, and connectivity probes.'
        RequiresAdmin = $false
        Order         = 400
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

    $result = New-OmniResult -ModuleName 'Network' -Category 'Network' `
        -RequiresAdmin $false -HadAdmin $Context.IsAdmin
    $log = $Context.Logger

    $timeoutMs = 2000

    # Helper: ping a target, return latency ms or $null.
    $ping = {
        param([string] $Target)
        try {
            $p = [System.Net.NetworkInformation.Ping]::new()
            $reply = $p.Send($Target, $timeoutMs)
            if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                return [int]$reply.RoundtripTime
            }
            return $null
        } catch {
            return $null
        } finally {
            if ($p) { try { $p.Dispose() } catch { } }
        }
    }

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

    $gatewayLatency = $null
    if ($gateway) {
        Set-OmniResultMetric -Result $result -Name 'DefaultGateway' -Value $gateway
        $gatewayLatency = & $ping $gateway
    }
    Set-OmniResultMetric -Result $result -Name 'GatewayLatencyMs' -Value ($(if ($null -ne $gatewayLatency) { $gatewayLatency } else { -1 }))

    # --- Internet reachability (public IP) ---------------------------------
    $internetLatency = & $ping '1.1.1.1'
    $internetOk = ($null -ne $internetLatency)
    Set-OmniResultMetric -Result $result -Name 'InternetReachable' -Value $internetOk
    Set-OmniResultMetric -Result $result -Name 'InternetLatencyMs' -Value ($(if ($null -ne $internetLatency) { $internetLatency } else { -1 }))

    # --- DNS resolution ----------------------------------------------------
    $dnsOk = $false
    try {
        $entry = [System.Net.Dns]::GetHostEntry('www.microsoft.com')
        $dnsOk = ($null -ne $entry -and @($entry.AddressList).Count -gt 0)
    } catch {
        $dnsOk = $false
        $log.Debug("DNS resolution failed: $($_.Exception.Message)", 'Network')
    }
    Set-OmniResultMetric -Result $result -Name 'DnsOk' -Value $dnsOk

    # --- Correlated connectivity findings ----------------------------------
    $gatewayOk = ($null -ne $gatewayLatency)

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
            'The gateway responds but both internet (1.1.1.1) and DNS resolution fail.'
        } elseif (-not $dnsOk) {
            'The gateway and internet (1.1.1.1) respond but DNS resolution fails.'
        } else {
            'The gateway responds but the public IP (1.1.1.1) is unreachable.'
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
