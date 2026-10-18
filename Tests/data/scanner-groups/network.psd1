# Expected scanners of the 'network' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'network.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
# NetworkAccess other than 'None' needs an allowlist entry in Tests/NoNetwork.Tests.ps1
# and owner approval (connectivity probes run only with --network-probes).
@{
    Scanners = @{
        'DNS Resolver'        = @{ NetworkAccess = 'Internet' }
        'Hosts File'          = @{ NetworkAccess = 'None' }
        'IP Configuration'    = @{ NetworkAccess = 'None' }
        'Network'             = @{ NetworkAccess = 'Internet' }
        'Network Shares'      = @{ NetworkAccess = 'None' }
        'Proxy Configuration' = @{ NetworkAccess = 'None' }
        'VPN'                 = @{ NetworkAccess = 'None' }
        'WiFi Networks'       = @{ NetworkAccess = 'None' }
    }
}
