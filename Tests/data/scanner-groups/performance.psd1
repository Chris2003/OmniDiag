# Expected scanners of the 'performance' group, read by Tests/Core.Contract.Tests.ps1.
# Key: the scanner's manifest Name. Its Id must be 'performance.<kebab-case name>', and
# NetworkAccess must match the manifest. Add a new scanner here (and only here).
@{
    Scanners = @{
        'CPU'                 = @{ NetworkAccess = 'None' }
        'Memory'              = @{ NetworkAccess = 'None' }
        'Performance'         = @{ NetworkAccess = 'None' }
        'Processes'           = @{ NetworkAccess = 'None' }
        'Startup Performance' = @{ NetworkAccess = 'None' }
    }
}
