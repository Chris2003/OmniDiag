<#
.SYNOPSIS
    OmniDiag launcher - One Tool. Complete Diagnostics.

.DESCRIPTION
    Entry point for OmniDiag. Validates the host, imports the OmniDiag module, runs
    a diagnostic session, and renders the dashboard to the console.

    PORTABLE: OmniDiag runs from the folder it was extracted to (Downloads, a share,
    or a USB stick). Logs, reports, saved sessions, and backups are written to an
    OmniDiagData folder next to this script, never to the user profile or %TEMP%,
    so deleting the folder (or removing the USB stick) leaves no OmniDiag files on
    the host. See PORTABLE.md.

    PRIVACY: All collection and analysis happen locally. OmniDiag never uploads
    anything. Collected data and logs may contain usernames, device names, file
    paths, and domain information - review reports before sharing.

.PARAMETER Range
    Time-range preset for time-aware modules. Last24Hours | Last7Days | Last30Days.

.PARAMETER IncludeCategory
    Only run modules in these categories (e.g. System, Network).

.PARAMETER ExcludeCategory
    Skip modules in these categories.

.PARAMETER IncludeModule
    Run only these individual scanners by name (e.g. CPU, Memory, Disk). Applied after
    the category filters. The GUI's "Scanners..." picker uses the same mechanism.

.PARAMETER Profile
    Run a role-focused scanner set: HelpDesk, DesktopSupport, SystemsAdmin,
    NetworkAdmin, SecurityAdmin, CloudAdmin, or Full.

.PARAMETER Workflow
    Run a daily-task workflow such as QuickTriage, SlowComputer,
    NetworkConnectivity, Printing, WindowsUpdate, LoginAndIdentity,
    StorageCleanup, SecurityPosture, CloudReadiness, or FullScan.

.PARAMETER NetworkProbes
    Also run the connectivity probes: ping the default gateway and 1.1.1.1, resolve
    www.microsoft.com, and check the domain secure channel. Off by default, so a scan
    contacts no other machine; without it those scanners do their local checks and add
    an Information finding saying how to run the probe.

.PARAMETER ListPlans
    List available role profiles and task workflows without running a scan.

.PARAMETER AiAnalysis
    After the scan, request optional evidence-grounded guidance from a locally
    running Ollama instance. This is advisory and cannot execute repairs.

.PARAMETER AiModel
    Locally installed Ollama model. Defaults to the smallest Gemma 4 tag,
    gemma4:e2b. Use gemma3:1b on low-memory devices.

.PARAMETER AiChat
    After the scan, open a multi-turn conversation with the local Ollama model about
    the findings and the organization's approved runbooks. Every answer cites the
    finding/runbook IDs it used; citations the model invents are flagged.

.PARAMETER Search
    Plain-language search over the session's findings and approved runbooks (no AI
    required), e.g. -Search 'vpn dns slow'.

.PARAMETER FromSession
    Skip scanning and load a saved session instead: a JSON report, a report .zip,
    or 'Last' for the newest session saved in OmniDiagData\sessions.

.PARAMETER CompareWith
    Before/after comparison against an earlier session: a JSON report, a report
    .zip, or 'Last' for the previous saved session (e.g. scan, repair, re-scan).

.PARAMETER RunbookPath
    Folder(s) of organization-owned Markdown runbooks. Defaults to
    $env:OMNIDIAG_RUNBOOK_PATH, then the bundled runbooks folder. Only runbooks
    marked 'status: approved' are used.

.PARAMETER Gui
    Launch the WPF graphical interface (dashboard, dark/light, live progress, cancel,
    one-click report export) instead of the console experience. Windows only.

.PARAMETER Quiet
    Suppress streaming log output; show only the final dashboard.

.PARAMETER Repair
    After the scan, open the interactive Repair Center: a confirmation-gated menu of
    system repairs (flush DNS, reset Winsock, restart services, clear temp, SFC, DISM,
    Windows Update reset, and more), with the repairs relevant to your findings flagged.

.PARAMETER AllowRepairWithoutRestorePoint
    Let repairs that require a System Restore point run even when Windows could not
    create one (for example, System Restore is disabled). Without this switch those
    repairs are skipped.

.PARAMETER RepairDryRun
    Open the Repair Center in dry-run mode: every selected repair only describes what it
    would do - no changes are made. Implies -Repair.

.EXAMPLE
    .\OmniDiag.ps1

.EXAMPLE
    .\OmniDiag.ps1 -Repair

.EXAMPLE
    .\OmniDiag.ps1 -Repair -RepairDryRun

.EXAMPLE
    .\OmniDiag.ps1 -Range Last24Hours -IncludeCategory System

.EXAMPLE
    .\OmniDiag.ps1 -Workflow NetworkConnectivity -NetworkProbes -CompareWith Last

.EXAMPLE
    .\OmniDiag.ps1 -FromSession Last -AiChat

.EXAMPLE
    .\OmniDiag.ps1 -Gui

.NOTES
    Exit codes (see docs/CLI.md): 0 no warnings or critical findings, 1 warnings,
    2 critical findings, 3 a module failed, 4 the requested -IncludeModule scanners
    all need elevation, 5 cancelled, 10 conflicting arguments, 11 a repair failed,
    12 a repair needs a reboot, 20 internal error. The session object is still
    written to the pipeline first, so '$s = .\OmniDiag.ps1' keeps working.
    Parameter-binding failures (e.g. an invalid -Range value) are reported by
    PowerShell itself before this script runs and exit with 1.
#>
[CmdletBinding()]
param(
    [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')]
    [string] $Range = 'Last7Days',
    [string[]] $IncludeCategory,
    [string[]] $ExcludeCategory,
    [string[]] $IncludeModule,
    [ValidateSet('HelpDesk','DesktopSupport','SystemsAdmin','NetworkAdmin','SecurityAdmin','CloudAdmin','Full')]
    [string] $Profile,
    [ValidateSet('QuickTriage','SlowComputer','NetworkConnectivity','Printing','WindowsUpdate','LoginAndIdentity','StorageCleanup','SecurityPosture','CloudReadiness','FullScan')]
    [string] $Workflow,
    [switch] $NetworkProbes,
    [switch] $ListPlans,
    [switch] $Gui,
    [switch] $Quiet,

    # Optional local AI analysis
    [switch] $AiAnalysis,
    [string] $AiModel = 'gemma4:e2b',
    [string] $AiQuestion = 'What are the most likely root causes and safest next diagnostic steps?',
    [string] $OllamaEndpoint = 'http://127.0.0.1:11434',
    [switch] $AiChat,

    # Saved sessions, search, and runbooks
    [string] $Search,
    [string] $FromSession,
    [string] $CompareWith,
    [string[]] $RunbookPath,

    # Reporting
    [switch] $Report,
    [ValidateSet('Html', 'Json', 'Csv', 'Md', 'Pdf', 'Zip')]
    [string[]] $ReportFormat = @('Html', 'Json', 'Csv'),
    [string] $ReportPath,
    [string] $BrandName,
    [string] $BrandLogo,
    [string] $BrandColor,
    [switch] $AcceptPrivacyNotice,

    # Repair Center
    [switch] $Repair,
    [switch] $RepairDryRun,
    [switch] $AllowRepairWithoutRestorePoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Host validation -------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5) {
    [Console]::Error.WriteLine('OmniDiag requires Windows PowerShell 5.1 or PowerShell 7+.')
    exit 20
}

# --- Argument checks (exit 10) -------------------------------------------------
function Exit-OmniUsageError {
    param([string] $Message)
    [Console]::Error.WriteLine("OmniDiag: $Message")
    [Console]::Error.WriteLine("Run 'Get-Help $PSCommandPath -Detailed' for usage.")
    exit 10
}
if ($Profile -and $Workflow) { Exit-OmniUsageError 'Choose either -Profile or -Workflow, not both.' }
if (($Profile -or $Workflow) -and $IncludeModule) { Exit-OmniUsageError 'Do not combine -Profile or -Workflow with -IncludeModule. Use one selection method.' }
if ($FromSession -and ($Profile -or $Workflow -or $IncludeModule -or $IncludeCategory -or $ExcludeCategory)) {
    Exit-OmniUsageError '-FromSession loads a saved session; it cannot be combined with scan selections (-Profile, -Workflow, -IncludeModule, -IncludeCategory, -ExcludeCategory).'
}

$isWindowsHost = $true
try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { }
if (-not $isWindowsHost) {
    Write-Warning 'OmniDiag targets Windows. On this OS most diagnostic modules will report no data.'
}

# --- Import module ---------------------------------------------------------
$manifest = Join-Path $PSScriptRoot 'src/OmniDiag.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    [Console]::Error.WriteLine("OmniDiag module not found at: $manifest")
    exit 20
}
Import-Module $manifest -Force -DisableNameChecking

if ($Gui -and -not $isWindowsHost) { Exit-OmniUsageError 'The GUI requires Windows (WPF). Use the console mode on this OS.' }

$exitCode = 0
$session = $null
try {
    # --- Portable data location --------------------------------------------------
    $dataRoot = Get-OmniDataRoot
    if ($dataRoot.Source -eq 'TempFallback') {
        Write-Warning "The OmniDiag folder is not writable; data is being written to $($dataRoot.Path). Copy OmniDiag to writable media (e.g. a USB stick) to keep everything with the tool."
    } elseif (-not $dataRoot.IsPortable -and $dataRoot.Source -ne 'Installed') {
        Write-Host "Note: OMNIDIAG_DATA sends OmniDiag's data to $($dataRoot.Path), outside the tool folder." -ForegroundColor Yellow
    }

    function Resolve-OmniSavedSessionPath {
        param([string] $Value, [string] $Exclude)
        if ($Value -ne 'Last') { return $Value }
        $saved = @(Get-ChildItem -LiteralPath (Get-OmniDataPath -Kind Sessions) -Filter '*.json' -File |
            Where-Object { $_.FullName -ne $Exclude } | Sort-Object LastWriteTime -Descending)
        if ($saved.Count -eq 0) { throw "No saved sessions in $(Get-OmniDataPath -Kind Sessions). Run a scan first." }
        return $saved[0].FullName
    }

    if ($ListPlans) {
        Write-Host ''
        Write-Host 'Role profiles' -ForegroundColor Cyan
        Get-OmniRoleProfile | Format-Table Name, Audience, Description -Wrap
        Write-Host 'Task workflows' -ForegroundColor Cyan
        Get-OmniTaskWorkflow | Format-Table Name, Description -Wrap
        return
    }

    # --- Elevation notice ------------------------------------------------------
    if (-not (Test-OmniIsAdministrator)) {
        Write-Host 'Note: running without administrator rights. Some checks (and admin-only modules) will be skipped.' -ForegroundColor Yellow
        Write-Host '      Re-run from an elevated prompt for a complete scan.' -ForegroundColor Yellow
    }

    if ($Gui) {
        Write-Host 'Launching OmniDiag GUI...' -ForegroundColor Cyan
        Show-OmniDiagGui
        return
    }

    # --- Run (console) or load a saved session ------------------------------------
    $savedPath = $null
    if ($FromSession) {
        $session = Import-OmniDiagSession -Path (Resolve-OmniSavedSessionPath -Value $FromSession)
        $savedPath = $session.SourcePath
        Write-OmniConsoleDashboard -Session $session
        Write-Host ("Loaded saved session: {0}" -f $savedPath) -ForegroundColor DarkGray
    } else {
        $progress = New-OmniConsoleProgressCallback
        # Pass only the selections that were given: an unset -Profile/-Workflow is '' and fails ValidateSet.
        $scan = @{ Range = $Range; ProgressCallback = $progress; Quiet = $Quiet }
        if ($IncludeCategory) { $scan.IncludeCategory = $IncludeCategory }
        if ($ExcludeCategory) { $scan.ExcludeCategory = $ExcludeCategory }
        if ($IncludeModule)   { $scan.IncludeModule = $IncludeModule }
        if ($Profile)         { $scan.Profile = $Profile }
        if ($Workflow)        { $scan.Workflow = $Workflow }
        if ($NetworkProbes)   { $scan.NetworkProbes = $true }
        $session = Invoke-OmniDiag @scan

        Write-OmniConsoleDashboard -Session $session
        Write-Host ("Structured log written to: {0}" -f $session.LogPath) -ForegroundColor DarkGray

        # Keep a snapshot with the tool so later runs can compare (-CompareWith Last) or chat (-FromSession Last).
        # Native session format; the public JSON report (schema v1) is written by -Report.
        $savedPath = Save-OmniSession -Session $session
        Write-Host ("Session saved to: {0} (local only; may contain user, device, and domain names - delete OmniDiagData to remove)" -f $savedPath) -ForegroundColor DarkGray
    }

    # @(...) around the whole if: an empty result returned from an if statement is $null.
    $runbooks = @(try { if ($RunbookPath) { Get-OmniRunbook -Path $RunbookPath } else { Get-OmniRunbook } }
        catch { Write-Warning "Runbooks could not be loaded: $($_.Exception.Message)" })

    # --- Before / after comparison ------------------------------------------------
    if ($CompareWith) {
        $beforePath = Resolve-OmniSavedSessionPath -Value $CompareWith -Exclude $savedPath
        $comparison = Compare-OmniDiagSession -Before $beforePath -After $session
        Write-Host ("Compared with: {0}" -f $beforePath) -ForegroundColor DarkGray
        Write-OmniSessionComparison -Comparison $comparison
    }

    # --- Relevant approved runbooks -----------------------------------------------
    $runbookMatches = @(Find-OmniRunbook -Session $session -Runbook $runbooks)
    if ($runbookMatches.Count -gt 0) {
        Write-Host '  Approved runbooks for these findings:' -ForegroundColor Cyan
        foreach ($m in $runbookMatches) { Write-Host ("    {0}  {1}  (findings: {2})" -f $m.Id, $m.Title, ($m.FindingIds -join ', ')) }
        Write-Host ''
    }

    # --- Evidence search ------------------------------------------------------------
    if ($Search) {
        $hits = @(Search-OmniEvidence -Query $Search -Session $session -Runbook $runbooks)
        Write-Host ("  Search: '{0}' - {1} result(s)" -f $Search, $hits.Count) -ForegroundColor Cyan
        foreach ($h in $hits) {
            $label = if ($h.Type -eq 'Finding') { "[$($h.Severity)]" } else { '[Runbook]' }
            Write-Host ("    {0,-13} {1}  ({2})" -f $label, $h.Title, $h.Id)
            if ($h.Snippet) { Write-Host ("                  {0}" -f $h.Snippet) -ForegroundColor Gray }
        }
        Write-Host ''
    }

    # --- Optional local Ollama analysis ---------------------------------------
    if ($AiAnalysis) {
        Write-Host ''
        Write-Host "Local AI analysis ($AiModel)" -ForegroundColor Cyan
        $ai = $null
        try { $ai = Invoke-OmniOllamaAnalysis -Session $session -Question $AiQuestion -Model $AiModel -Endpoint $OllamaEndpoint }
        catch { Write-Warning "Local AI analysis skipped: $($_.Exception.Message)" }
    }
    if ($AiAnalysis -and $ai) {
        Write-Host $ai.Summary
        if ($ai.Priorities.Count -gt 0) {
            Write-Host '  Priorities:' -ForegroundColor Cyan
            foreach ($item in $ai.Priorities) { Write-Host "  - [$($item.urgency)] $($item.title) (evidence: $(@($item.evidenceIds) -join ', '))" }
        }
        if ($ai.NextSteps.Count -gt 0) {
            Write-Host '  Next diagnostic steps:' -ForegroundColor Cyan
            foreach ($item in $ai.NextSteps) {
                # The model's own flag can only add the label; a prompt-injected finding can't remove the advisory below.
                $approval = if ($item.requiresApproval) { ' [approval required]' } else { '' }
                Write-Host "  - $($item.step)$approval (evidence: $(@($item.evidenceIds) -join ', '))"
            }
        }
        if (@($ai.UnverifiedCitations).Count -gt 0) { Write-Host ("  ! Unverified citations ignored: {0}" -f ($ai.UnverifiedCitations -join ', ')) -ForegroundColor Yellow }
        Write-Host '  Advisory only: get approval before changing the device, and validate guidance against the cited findings and organizational runbooks.' -ForegroundColor Yellow
    }

    # --- Multi-turn local AI conversation ------------------------------------------
    if ($AiChat) {
        $conversation = New-OmniAssistantConversation -Session $session -Runbook $runbooks -Model $AiModel -Endpoint $OllamaEndpoint
        Write-Host ''
        Write-Host "Local AI conversation ($AiModel) - ask about the findings; press Enter on an empty line to finish." -ForegroundColor Cyan
        while ($true) {
            $question = Read-Host 'You'
            if ([string]::IsNullOrWhiteSpace($question) -or $question -match '^(exit|quit|q)$') { break }
            try {
                $turn = Invoke-OmniAssistantTurn -Conversation $conversation -Question $question
            } catch {
                Write-Host "  ! $($_.Exception.Message)" -ForegroundColor Red
                continue
            }
            Write-Host "AI : $($turn.Answer)"
            $cites = @($turn.FindingIds) + @($turn.RunbookIds)
            if ($cites.Count -gt 0) { Write-Host ("     evidence: {0}" -f ($cites -join ', ')) -ForegroundColor DarkGray }
            if ($turn.RequiresApproval) { Write-Host '     [approval required before changing the device]' -ForegroundColor Yellow }
            if ($turn.UnverifiedCitations.Count -gt 0) { Write-Host ("     ! unverified citations ignored: {0}" -f ($turn.UnverifiedCitations -join ', ')) -ForegroundColor Yellow }
            foreach ($q in @($turn.SuggestedQuestions | Select-Object -First 3)) { Write-Host "     try: $q" -ForegroundColor DarkCyan }
        }
    }

    # --- Reporting (with privacy warning) --------------------------------------
    if ($Report) {
        Write-Host ''
        Write-Host 'PRIVACY NOTICE' -ForegroundColor Yellow
        Write-Host '  Reports are generated and stored locally - nothing is uploaded.' -ForegroundColor Yellow
        Write-Host '  They may contain usernames, device names, file paths, domains, and' -ForegroundColor Yellow
        Write-Host '  other internal information. Review before sharing.' -ForegroundColor Yellow

        $proceed = $AcceptPrivacyNotice
        if (-not $proceed) {
            $answer = Read-Host 'Generate report(s) now? [Y/N]'
            $proceed = ($answer -match '^(y|yes)$')
        }

        if ($proceed) {
            $params = @{ Session = $session; Format = $ReportFormat }
            if ($ReportPath)  { $params.OutputDirectory = $ReportPath }
            if ($BrandName)   { $params.BrandName = $BrandName }
            if ($BrandLogo)   { $params.BrandLogo = $BrandLogo }
            if ($BrandColor)  { $params.BrandColor = $BrandColor }
            $reportSet = Export-OmniDiagReport @params
            Write-Host ''
            Write-Host "Report(s) written to: $($reportSet.OutputDirectory)" -ForegroundColor Green
            foreach ($f in $reportSet.Files) { Write-Host "  $f" -ForegroundColor Gray }
            foreach ($w in $reportSet.Warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }
        } else {
            Write-Host 'Report generation skipped.' -ForegroundColor DarkGray
        }
    }

    # --- Exit code from the scan (0-5; see Get-OmniExitCodeTable) -------------------
    $exitCode = Get-OmniExitCode -Session $session -ExplicitSelection:([bool]$IncludeModule)

    # --- Repair Center ---------------------------------------------------------
    if ($Repair -or $RepairDryRun) {
        $repairSession = @(Invoke-OmniRepairConsole -Session $session -DryRun:$RepairDryRun -AllowWithoutRestorePoint:$AllowRepairWithoutRestorePoint) |
            Where-Object { $_ -and $_.PSObject.Properties['Results'] } | Select-Object -Last 1
        # A failed repair (11) or a pending reboot (12) outranks the scan's code.
        $repairCode = Get-OmniRepairExitCode -RepairSession $repairSession
        if ($repairCode -ne 0) { $exitCode = $repairCode }
    }

} catch {
    [Console]::Error.WriteLine("OmniDiag: internal error: $($_.Exception.Message)")
    Write-Verbose $_.ScriptStackTrace
    $exitCode = 20
} finally {
    # Remove OmniDiag's scratch files on every exit path (errors, GUI close, Ctrl+C);
    # logs, reports, and saved sessions stay in OmniDiagData.
    Clear-OmniTempData
}

# Make the session available to the caller for scripting/automation, then report
# the outcome as the process exit code.
if ($null -ne $session) { $session }
exit $exitCode
