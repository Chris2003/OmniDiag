# Expected scanners of the 'extras' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'extras.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
# NetworkAccess other than 'None' needs an allowlist entry in Tests/NoNetwork.Tests.ps1
# and owner approval (connectivity probes run only with --network-probes).
@{
    Scanners = @{
        'Active Directory'      = @{ NetworkAccess = 'LocalNetwork' }
        'Battery'               = @{ NetworkAccess = 'None' }
        'Benchmark'             = @{ NetworkAccess = 'None' }
        'Browser Diagnostics'   = @{ NetworkAccess = 'None' }
        'Entra ID'              = @{ NetworkAccess = 'Internet' }
        'Environment Variables' = @{ NetworkAccess = 'None' }
        'GPU'                   = @{ NetworkAccess = 'None' }
        'Installed Software'    = @{ NetworkAccess = 'None' }
        'Intune and MDM'        = @{ NetworkAccess = 'None' }
        'Printers'              = @{ NetworkAccess = 'None' }
        'Temp Files'            = @{ NetworkAccess = 'None' }
        'Time Synchronization'  = @{ NetworkAccess = 'None' }
        'USB Devices'           = @{ NetworkAccess = 'None' }
        'Windows Features'      = @{ NetworkAccess = 'None' }
    }
}
