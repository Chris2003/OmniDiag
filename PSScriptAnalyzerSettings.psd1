# PSScriptAnalyzer settings for OmniDiag. Used by build/Invoke-Lint.ps1 (and CI), and
# picked up automatically by the VS Code PowerShell extension when configured
# ("powershell.scriptAnalysis.settingsPath": "PSScriptAnalyzerSettings.psd1").
#
# Policy (Phase 1): every default rule is on. Errors fail the build; warnings are
# reported against an agreed baseline (build/Invoke-Lint.ps1 -FailOnWarning makes them
# fatal); Information is advisory.
#
# PSAvoidUsingWriteHost stays ENABLED here. PSScriptAnalyzer settings cannot scope a rule
# to a path, so build/Invoke-Lint.ps1 drops that one rule's results for the presentation
# layers whose job is to write to the console: src/Cli, src/UI, OmniDiag.ps1, install.ps1,
# and build/. Everywhere else (Core, Repair, Reporting, Modules, EventLog) Write-Host is
# still flagged, because those layers must log through the logger or return objects.
@{
    Severity            = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    ExcludeRules        = @()

    Rules               = @{
        # Comment-based help on exported functions. Default severity (Information) is kept
        # on purpose: missing help is advisory and never fails the build.
        PSProvideCommentHelp = @{
            Enable                  = $true
            ExportedOnly            = $true
            BlockComment            = $true
            VSCodeSnippetCorrection = $false
            Placement               = 'begin'
        }
    }
}
