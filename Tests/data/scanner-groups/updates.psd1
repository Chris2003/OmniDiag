# Expected scanners of the 'updates' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'updates.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'System Health'  = @{ NetworkAccess = 'None' }
        'Update Rings'   = @{ NetworkAccess = 'None' }
        'Windows Health' = @{ NetworkAccess = 'None' }
        'Windows Update' = @{ NetworkAccess = 'None' }
    }
}
