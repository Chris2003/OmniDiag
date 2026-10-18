# Expected scanners of the 'system' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'system.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'System'             = @{ NetworkAccess = 'None' }
        'System Information' = @{ NetworkAccess = 'None' }
    }
}
