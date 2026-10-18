# Expected scanners of the 'services' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'services.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'Drivers'  = @{ NetworkAccess = 'None' }
        'Services' = @{ NetworkAccess = 'None' }
    }
}
