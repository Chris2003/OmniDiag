# Expected scanners of the 'startup' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'startup.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'Registry Health' = @{ NetworkAccess = 'None' }
        'Scheduled Tasks' = @{ NetworkAccess = 'None' }
        'Startup'         = @{ NetworkAccess = 'None' }
    }
}
