# Expected scanners of the 'events' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'events.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'Error Summary' = @{ NetworkAccess = 'None' }
        'Event Logs'    = @{ NetworkAccess = 'None' }
    }
}
