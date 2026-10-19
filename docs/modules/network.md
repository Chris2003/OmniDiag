# Network (`network`)

Adapters, IP and DNS configuration, routes, listening ports, the hosts file, shares, Wi-Fi,
proxy, and VPN, plus opt-in connectivity probes: is this machine configured to reach what it
needs, what does it expose, and (with probes) does it reach the network?

## Run it

```bat
omnidiag network
omnidiag network --network-probes --format json --output C:\Cases\1234\
omnidiag scan --module network.listening-ports --format json
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
| Listening Ports | `network.listening-ports` | TCP listeners and UDP endpoints with their owning process and services; flags exposure on all interfaces. | Not required; other users' program paths need elevation | None |
| Network | `network.network` | Active adapters, packet errors, default gateway, and opt-in connectivity probes. | Not required | Internet (probe only) |
| Network Shares | `network.network-shares` | Enumerates SMB shares and flags overly permissive access. | Not required | None |
| Proxy Configuration | `network.proxy-configuration` | WinINET, WinHTTP, PAC, and process proxy configuration. | Not required | None |
| Routes | `network.routes` | IPv4 and IPv6 routing table: default routes per interface, ambiguous default routes, and persistent routes. | Not required | None |
| VPN | `network.vpn` | Windows VPN profiles, connection state, adapters, and recent RasClient failures. | Not required | None |
| WiFi Networks | `network.wifi-networks` | Reports current wireless connection quality and nearby networks. | Not required | None |

## What it checks

**DNS Resolver.** Lists the IPv4 DNS servers of each active adapter and warns for an active
adapter with none. With probes, resolves `DnsName` through the configured resolvers.

**Hosts File.** Counts custom entries in `%SystemRoot%\System32\drivers\etc\hosts`; 50 or
more entries pointing at loopback / null addresses are reported as a block list; a well-known
public domain (Microsoft, Google, PayPal, GitHub, ...) mapped to a non-loopback address is a
possible hijack.

**IP Configuration.** Per adapter: IPv4 addresses, default gateway, DHCP state. An APIPA
address (169.254.x.x) means DHCP failed.

**Listening Ports.** Every TCP socket in the Listen state and every UDP endpoint, with the
owning process id, process name, program path, publisher (the file's CompanyName), and the
Windows services hosted in that process (so a shared `svchost.exe` is named by its services,
for example `TermService`). The full table is in the `Listeners` metric. Checks:

- A listener bound to every interface (`0.0.0.0` or `::`) by a program that is not part of
  Windows is listed. "Part of Windows" means PID 0 / 4, a path under `%SystemRoot%`, a
  CompanyName starting with "Microsoft", or (when the path cannot be read) a well-known
  Windows process name. This is a heuristic on file metadata, not a signature check: an
  Authenticode check can fetch revocation data from the network, which a default scan never
  does.
- FTP (21), Telnet (23), Remote Desktop (3389), and WinRM (5985 / 5986) listening on every
  interface over TCP are each a Warning that asks you to confirm the firewall scope for that
  port. SMB (445) is bound on almost every Windows installation by default, so it is reported
  as Information with the same advice (it should normally not be open on the Public
  profile). WinRM is on by default on Windows Server, so on a Server SKU
  (`Win32_OperatingSystem.ProductType` 2 or 3, or the CurrentVersion `InstallationType`
  `Server`) 5985 / 5986 are Information; they stay a Warning on client SKUs (metric
  `ServerSku`). The scanner does not read firewall rules for the port and makes no connection
  attempt, so the finding says the port is bound, not that it is reachable.

**Network.** Active adapters (`Status = Up`), adapters with more than 1000 receive + send
errors, the IPv4 default gateway, and (with probes) gateway / public-address / DNS
reachability, correlated into "no connectivity" or "partial connectivity".

**Network Shares.** Counts shares that are not administrative (`$` suffix) and warns when a
share grants Everyone Full or Change access. Everyone is matched by name and by the local
name of the well-known SID S-1-1-0, so localized Windows ("Jeder", "Tout le monde") is
covered.

**Proxy Configuration.** The user's WinINET proxy (`ProxyEnable`, `ProxyServer`,
`AutoConfigURL`), the machine-wide WinHTTP proxy (used by Windows Update and most system
services and agents), and the `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` variables. Warns
when the user proxy is enabled without a server, or when WinINET and the environment
variables disagree; reports a configured WinHTTP proxy as Information.

**Routes.** The active IPv4 and IPv6 routing table. Checks:

- No default route (`0.0.0.0/0` or `::/0`) in either family: Warning.
- For each family, two or more default routes on different interfaces that share the lowest
  effective metric (route metric + interface metric, the value Windows uses to pick a route):
  Information. This is common with VPN split tunnelling or Wi-Fi plus Ethernet.
- Routes in the persistent store (saved across restarts; a static default gateway is stored
  there too) are listed as Information.

**VPN.** Built-in VPN profiles (`Get-VpnConnection`), adapters whose description looks like a
VPN client (TAP, WireGuard, AnyConnect, GlobalProtect, Fortinet, ...), and error events in
`Microsoft-Windows-RasClient/Operational`. The event query is bounded: the scan's time range
(default 7 days, clamped to at most 30 days) and at most 200 events; at the cap the finding
says "200 or more".

**WiFi Networks.** Whether a wireless interface exists, whether it is connected, the SSID,
the signal percentage, and the number of visible networks. A connected signal below 40% is a
Warning.

## Data sources

| Scanner | Source |
|---|---|
| DNS Resolver | `Get-DnsClientServerAddress`, `Get-NetAdapter`; probe: `Resolve-DnsName` (fallback `System.Net.Dns`) |
| Hosts File | The hosts file (read only) |
| IP Configuration | `Get-NetIPConfiguration`, `Get-NetIPInterface` |
| Listening Ports | `Get-NetTCPConnection -State Listen`, `Get-NetUDPEndpoint`, `Get-Process`, `Win32_Process` (`ExecutablePath`, when `Get-Process` has no path), `Win32_Service` (`ProcessId`), file version information (`CompanyName`) |
| Network | `Get-NetAdapter`, `Get-NetAdapterStatistics`, `Win32_NetworkAdapter` (fallback), `Get-NetIPConfiguration`; probes: `System.Net.NetworkInformation.Ping`, `System.Net.Dns` |
| Network Shares | `Get-SmbShare` (fallback `Win32_Share`), `Get-SmbShareAccess` |
| Proxy Configuration | `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`; `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections\WinHttpSettings`; fallback `netsh winhttp show proxy`; environment variables |
| Routes | `Get-NetRoute -PolicyStore ActiveStore` and `-PolicyStore PersistentStore` (IPv4 and IPv6) |
| VPN | `Get-VpnConnection`, `Get-NetAdapter -IncludeHidden`, `Get-WinEvent` (RasClient Operational, Level 2) |
| WiFi Networks | `netsh wlan show interfaces`, `netsh wlan show networks mode=bssid` |

All sources are local; none depends on the display language except where noted below.

**WinHTTP proxy (registry, not netsh).** `WinHttpSettings` is the binary value that
`netsh winhttp set proxy` writes. Microsoft does not document its layout; the scanner uses the
de-facto layout that Wine's `WinHttpGetDefaultProxyConfiguration` implements and that
matches Microsoft's published direct-access sample
(`1800000000000000010000000000000000000000`): a DWORD header (0x18), a DWORD change counter, a
DWORD of flags (1 = direct, 2 = named proxy), a DWORD length plus that many single-byte
characters for the proxy server, then a DWORD length plus characters for the bypass list.
Every length is bounds-checked; a value that does not fit is reported as undecodable
(Information) instead of being guessed at. Only when the value is missing or undecodable does
the scanner run `netsh winhttp show proxy`, and it parses that output by structure, not by
its translated labels: lines of the form `label : value`, the first being the proxy server
and the second the bypass list (a value in parentheses such as "(none)" counts as empty); no
such line means direct access.

**Wi-Fi (netsh, by necessity).** Windows has no PowerShell cmdlet or CIM class for the WLAN
connection state; the Native Wifi API (`WlanQueryInterface`) needs compiled interop, which
OmniDiag does not use. `netsh wlan` labels are translated, so the parser keys only on stable
parts of the output: an interface exists when a value is a GUID; the `SSID` and `SSID <n>`
labels are not translated; the signal is the first value of the form `<number>%` (with or
without a space); the interface is connected when it reports an SSID. Limitations: the
English state text is not used, so "connected" means "reports an SSID"; SSIDs with characters
outside the console code page may show as `?`; on recent Windows 11 builds `netsh wlan` can
require location access for desktop apps, and without it the scanner reports no usable
wireless interface.

## Elevation

No scanner in this group requires administrator rights. As a standard user, Listening Ports
cannot read the program path of processes owned by other users (services); it still lists
the listener, its process id and name, and its services, identifies well-known Windows
processes by name, and adds an Information finding, **Some listener program paths require
elevation**. Run elevated for complete owner paths and publishers.

## Network access

A default run is local-only. Routes, Listening Ports, Proxy Configuration, WiFi Networks, and
VPN never contact another host (Listening Ports reads the local TCP/UDP tables and makes no
connection attempt). With `--network-probes` (`-NetworkProbes`, or the GUI option "Run
connectivity probes (contacts the network)"):

| Scanner | Traffic |
|---|---|
| Network | ICMP ping to the default gateway (`PingGateway`) and to `PublicAddress` (default `1.1.1.1`); DNS lookup of `DnsName` (default `www.microsoft.com`); `TimeoutMs` (default 2000) per probe |
| DNS Resolver | DNS lookup of `DnsName` (default `www.microsoft.com`) through the configured resolvers |

Targets come from `Config.ProbeTargets` (`Get-OmniProbeTarget`). Without probes, both
scanners do their local checks and add an Information finding, **Connectivity probe not
run**, whose recommendation says how to run the probe.

## Findings it can emit

| Scanner | Finding (Id when explicit) | Severity | When |
|---|---|---|---|
| DNS Resolver | No DNS servers configured on *adapter* | Warning | An active adapter has no IPv4 DNS server |
| DNS Resolver | DNS resolution failed | Warning | Probe on, `DnsName` did not resolve |
| DNS Resolver | Connectivity probe not run | Information | Probes off |
| DNS Resolver | DNS resolver healthy | Pass | No warning |
| Hosts File | Hosts file has *n* custom entries (`network-hosts-file-custom-entries`) | Information | Any custom entry |
| Hosts File | Large block list detected (*n* entries) (`network-hosts-file-block-list`) | Information | 50 or more loopback / null entries |
| Hosts File | Possible hosts hijack: *domain* | Warning | A well-known domain maps to a non-loopback address |
| Hosts File | Hosts file is clean | Pass | No warning |
| IP Configuration | APIPA address on *adapter* (DHCP failure) | Warning | 169.254.x.x address |
| IP Configuration | IP configuration valid | Pass | No warning |
| Listening Ports | *Service* (TCP *port*) listens on all interfaces (`network-listening-ports-exposed-<port>`) | Warning (Information for 445, and for 5985 / 5986 on a Windows Server SKU) | TCP 21, 23, 445, 3389, 5985, or 5986 bound to `0.0.0.0` or `::` |
| Listening Ports | *n* non-Microsoft listener(s) on all interfaces (`network-listening-ports-third-party-all-interfaces`) | Information | A non-Windows program listens on every interface (TCP or UDP) |
| Listening Ports | Some listener program paths require elevation (`network-listening-ports-paths-require-elevation`) | Information | Standard user and a non-Windows owner's path is unreadable |
| Listening Ports | Listening ports not available (`network-listening-ports-unavailable`) | Information | `Get-NetTCPConnection` missing or failing |
| Listening Ports | No risky listener exposed on all interfaces (`network-listening-ports-reviewed`) | Pass | No warning |
| Network | No active network adapters | Critical | No adapter is up |
| Network | High packet errors on *adapter* | Warning | More than 1000 receive + send errors |
| Network | No network connectivity | Critical | Probes on, gateway, internet, and DNS all fail |
| Network | Partial connectivity (LAN up, WAN/DNS impaired) | Warning | Probes on, gateway answers but internet or DNS fails |
| Network | Connectivity probe not run | Information | Probes off |
| Network | Network adapters healthy / Network healthy | Pass | No warning (probes off / probes on) |
| Network Shares | *n* user share(s) present (`network-shares-user-shares`) | Information | Non-administrative shares exist |
| Network Shares | Share '*name*' grants Everyone *rights* access | Warning | Everyone has Full or Change |
| Network Shares | No overly permissive shares detected | Pass | No warning |
| Proxy Configuration | User proxy is enabled without a proxy server | Warning | `ProxyEnable` = 1 and `ProxyServer` empty |
| Proxy Configuration | Multiple proxy sources may disagree | Warning | WinINET proxy and proxy environment variables differ |
| Proxy Configuration | Machine-wide WinHTTP proxy is configured (`network-proxy-winhttp-named-proxy`) | Information | WinHTTP uses a named proxy |
| Proxy Configuration | WinHTTP proxy setting could not be decoded (`network-proxy-winhttp-undecodable`) | Information | `WinHttpSettings` has an unexpected layout |
| Proxy Configuration | Windows proxy stores are unavailable | Information | Not Windows |
| Proxy Configuration | Proxy configuration collected | Pass | No warning |
| Routes | No default route (`network-routes-no-default`) | Warning | Neither an IPv4 nor an IPv6 default route |
| Routes | Multiple IPv4 / IPv6 default routes with equal metric (`network-routes-ambiguous-default-ipv4` / `-ipv6`) | Information | Tie for the lowest effective metric across interfaces |
| Routes | *n* persistent route(s) configured (`network-routes-persistent`) | Information | Routes in the persistent store |
| Routes | Routing table not available (`network-routes-unavailable`) | Information | `Get-NetRoute` missing or failing |
| Routes | Default route present (`network-routes-healthy`) | Pass | No warning |
| VPN | *n* recent VPN client errors (`network-vpn-rasclient-errors`) | Warning | RasClient error events in the time range (capped at 200) |
| VPN | No Windows VPN configuration detected | Information | No profile and no VPN-like adapter |
| VPN | VPN posture collected | Pass | VPN present, no recent error |
| WiFi Networks | Weak WiFi signal (*n*%) (`network-wifi-weak-signal`) | Warning | Connected, signal below 40% |
| WiFi Networks | Connected to '*SSID*' (`network-wifi-connected`) | Information | Connected |
| WiFi Networks | Wireless adapter is not connected (`network-wifi-not-connected`) | Information | Interface present, no SSID |
| WiFi Networks | No wireless adapter present | Information | No interface (or WLAN service / location access unavailable) |
| WiFi Networks | Wireless connection is healthy | Pass | No warning |

Explicit finding ids are stable and contain no live values (for example
`network-listening-ports-exposed-3389`, `network-routes-no-default`,
`network-wifi-weak-signal`), so `Compare-OmniSession` can match them across scans. A
finding without an explicit id gets one derived from its component and title (for example
`network-dns-dns-resolution-failed`); a dynamic title (adapter, share, or domain name) makes
that derived id specific to the item.

## Platforms

Windows 10 22H2 x64, Windows 11 x64 and ARM64. The NetTCPIP, NetAdapter, DnsClient,
SmbShare, and VpnClient modules ship with every supported edition and architecture. Data a
platform does not provide (no wireless adapter, no `Get-NetRoute` in a stripped image, no
RasClient log) is reported as "not available" Information, never as a failure. Off Windows
the scanners return an Information finding and no data.
