# Expected scanners of the 'storage' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'storage.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'Disk'       = @{ NetworkAccess = 'None' }
        'Disk Usage' = @{ NetworkAccess = 'None' }
        'Storage'    = @{ NetworkAccess = 'None' }
        'TRIM'       = @{ NetworkAccess = 'None' }
    }
}
