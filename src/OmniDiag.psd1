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
        'Core/RegistryScan.psm1',
        'Core/Engine.psm1',
        'Repair/RepairModels.psm1',
        'Repair/RepairRegistry.psm1',
        'Repair/RepairEngine.psm1',
        'Reporting/Json.psm1',
        'Reporting/Csv.psm1',
        'Reporting/Html.psm1',
        'Reporting/Pdf.psm1',
        'Reporting/Package.psm1',
        'Reporting/Report.psm1',
        'Cli/OmniConsole.psm1',
        'Cli/OmniRepairConsole.psm1',
        'UI/OmniDiagGui.psm1'
    )

    FunctionsToExport = @(
        # Root
        'Invoke-OmniDiag', 'Get-OmniVersion', 'Invoke-OmniRepairCenter',
        # Models
        'New-OmniFinding', 'New-OmniResult', 'Add-OmniFinding', 'Set-OmniResultMetric',
        'Complete-OmniResult', 'Get-OmniTimeRange', 'Get-OmniSeverityRank', 'Get-OmniSeverityNames',
        # Logging
        'New-OmniLogger',
        # Registry / engine / scoring
        'Test-OmniIsAdministrator', 'New-OmniContext', 'Get-OmniModule',
        'Invoke-OmniSession', 'Get-OmniHealthScore',
        # Registry scan/backup/remove (shared by the Registry Health scanner and the
        # Clean Invalid Registry Entries repair; exported so both resolve them globally).
        'Get-OmniInvalidRegistryEntry', 'Export-OmniRegistryBackup', 'Remove-OmniRegistryEntry',
        'ConvertTo-OmniRegProviderPath', 'ConvertTo-OmniRegExePath',
        # Repair Center (models, registry, engine, console). Cross-module helpers
        # (Invoke-OmniRepairStep, the result factories, Get-OmniRepairRiskNames,
        # New-OmniRestorePoint) MUST be exported so plugins/engine can resolve them
        # globally - same lesson as Write-OmniTextFile.
        'New-OmniRepairResult', 'Add-OmniRepairStep', 'Invoke-OmniRepairStep',
        'Complete-OmniRepairResult', 'Get-OmniRepairRiskNames',
        'Get-OmniRepair', 'New-OmniRepairContext', 'Get-OmniApplicableRepair',
        'New-OmniRestorePoint', 'Invoke-OmniRepair',
        'Invoke-OmniRepairConsole', 'Write-OmniRepairSummary',
        # Console
        'Get-OmniStatusColor', 'New-OmniConsoleProgressCallback', 'Write-OmniConsoleDashboard',
        # Reporting
        'Export-OmniReport', 'Export-OmniHtmlReport', 'Export-OmniJsonReport',
        'Export-OmniCsvReport', 'Export-OmniEventCsvReport', 'Export-OmniReportPackage',
        'Export-OmniPdfReport',
        'ConvertTo-OmniFindingTable', 'ConvertTo-OmniEventTable',
        # Shared reporting helper (used cross-module by the HTML exporter, so it
        # must be globally resolvable, not just private to Json.psm1).
        'Write-OmniTextFile',
        # GUI
        'Show-OmniDiagWindow', 'Set-OmniTheme', 'Get-OmniThemePalette'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Windows', 'Diagnostics', 'IT', 'Sysadmin', 'Troubleshooting', 'EventLog')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/OWNER/OmniDiag'
            ReleaseNotes = 'Milestone 5: WPF GUI (Show-OmniDiagWindow) with dashboard, left navigation, dark/light themes, background-runspace scanning with a working Cancel button, and one-click report export - completing Version 1. Builds on the M1 core engine, M2 Event Log engine, seven M1-M3 diagnostic modules, and the M4 reporting engine.'
        }
    }
}
