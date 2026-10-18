# Network (`network`)

Adapters, IP and DNS configuration, the hosts file, shares, Wi-Fi, proxy, and VPN, plus
opt-in connectivity probes: is this machine configured to reach what it needs, and (with
probes) does it?

## Run it

```bat
omnidiag network
omnidiag network --network-probes --format json --output C:\Cases\1234\
```

```powershell
Get-OmniDiagNetwork
Get-OmniDiagNetwork -NetworkProbes -IncludePassed | Format-Table severity, moduleId, title
Get-OmniDiagNetwork -NetworkProbes -Config @{ ProbeTargets = @{ PublicAddress = '9.9.9.9'; DnsName = 'intranet.example' } }
```

## Scanners

| Scanner | Id | What it checks | Elevation | Network access |
|---|---|---|---|---|
| DNS Resolver | `network.dns-resolver` | Configured DNS servers per adapter and an opt-in resolution test. | Not required | Internet (probe only) |
| Hosts File | `network.hosts-file` | Inspects the Windows hosts file for custom entries and possible hijacks. | Not required | None |
| IP Configuration | `network.ip-configuration` | Per-adapter IP addresses, gateway, and DHCP state. | Not required | None |
| Network | `network.network` | Active adapters, packet errors, default gateway, and opt-in connectivity probes. | Not required | Internet (probe only) |
| Network Shares | `network.network-shares` | Enumerates SMB shares and flags overly permissive access. | Not required | None |
| Proxy Configuration | `network.proxy-configuration` | WinINET, WinHTTP, PAC, and process proxy configuration. | Not required | None |
| VPN | `network.vpn` | Windows VPN profiles, connection state, adapters, and recent RasClient failures. | Not required | None |
| WiFi Networks | `network.wifi-networks` | Reports current wireless connection quality and nearby networks. | Not required | None |

## What it checks

_To be completed by the group owner._

## Data sources

_To be completed by the group owner._

## Elevation

No scanner in this group requires administrator rights at the module level.

## Network access

A default run is local-only. With `--network-probes` (`-NetworkProbes`, or the GUI option
"Run connectivity probes (contacts the network)"):

| Scanner | Traffic |
|---|---|
| Network | ICMP ping to the default gateway (`PingGateway`) and to `PublicAddress` (default `1.1.1.1`); DNS lookup of `DnsName` (default `www.microsoft.com`); `TimeoutMs` (default 2000) per probe |
| DNS Resolver | DNS lookup of `DnsName` (default `www.microsoft.com`) through the configured resolvers |

Targets come from `Config.ProbeTargets` (`Get-OmniProbeTarget`). Without probes, both
scanners do their local checks and add an Information finding, **Connectivity probe not
run**, whose recommendation says how to run the probe.

## Findings it can emit

_To be completed by the group owner._

## Platforms

_To be completed by the group owner._
