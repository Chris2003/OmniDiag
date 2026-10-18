# Expected scanners of the 'reliability' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'reliability.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'Crash Dumps'         = @{ NetworkAccess = 'None' }
        'Reliability'         = @{ NetworkAccess = 'None' }
        'Reliability Monitor' = @{ NetworkAccess = 'None' }
    }
}
