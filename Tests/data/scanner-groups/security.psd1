# Expected scanners of the 'security' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'security.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'BitLocker'           = @{ NetworkAccess = 'None' }
        'Certificates'        = @{ NetworkAccess = 'None' }
        'Defender Onboarding' = @{ NetworkAccess = 'None' }
        'Firewall Rules'      = @{ NetworkAccess = 'None' }
        'Local Admins'        = @{ NetworkAccess = 'LocalNetwork' }  # opt-in: member-name lookups may query a DC on joined devices
        'Security'            = @{ NetworkAccess = 'None' }
    }
}
