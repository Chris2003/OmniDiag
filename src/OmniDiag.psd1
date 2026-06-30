@{
    # ---------------------------------------------------------------------
    # OmniDiag module manifest
    # ---------------------------------------------------------------------
    RootModule        = 'OmniDiag.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b6e9d0c2-7a4d-4f3e-9c1a-0d2f5a8e10b4'
    Author            = 'OmniDiag Contributors'
    CompanyName       = 'OmniDiag'
    Copyright         = '(c) OmniDiag Contributors. MIT License.'
    Description       = 'OmniDiag - One Tool. Complete Diagnostics. A local-only, open-source Windows diagnostic utility.'

    PowerShellVersion = '5.1'

    # Core engine + CLI presentation are loaded as nested modules; their
    # exported functions are re-exported per FunctionsToExport below.
    NestedModules = @(
        'Core/Models.psm1',
        'Core/Logging.psm1',
        'Core/Registry.psm1',
        'Core/HealthScore.psm1',
        'Core/Engine.psm1',
        'Cli/OmniConsole.psm1'
    )

    FunctionsToExport = @(
        # Root
        'Invoke-OmniDiag', 'Get-OmniVersion',
        # Models
        'New-OmniFinding', 'New-OmniResult', 'Add-OmniFinding', 'Set-OmniResultMetric',
        'Complete-OmniResult', 'Get-OmniTimeRange', 'Get-OmniSeverityRank', 'Get-OmniSeverityNames',
        # Logging
        'New-OmniLogger',
        # Registry / engine / scoring
        'Test-OmniIsAdministrator', 'New-OmniContext', 'Get-OmniModule',
        'Invoke-OmniSession', 'Get-OmniHealthScore',
        # Console
        'Get-OmniStatusColor', 'New-OmniConsoleProgressCallback', 'Write-OmniConsoleDashboard'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Windows', 'Diagnostics', 'IT', 'Sysadmin', 'Troubleshooting', 'EventLog')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/OWNER/OmniDiag'
            ReleaseNotes = 'Milestone 1: core engine, plugin architecture, System Information module, console runner.'
        }
    }
}
