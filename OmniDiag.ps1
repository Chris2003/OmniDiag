<#
.SYNOPSIS
    OmniDiag launcher - One Tool. Complete Diagnostics.

.DESCRIPTION
    Entry point for OmniDiag. Validates the host, imports the OmniDiag module, runs
    a diagnostic session, and renders the dashboard to the console.

    Milestone 1 ships the console experience; the WPF GUI (-Gui) arrives in a later
    milestone and currently falls back to the console with a notice.

    PRIVACY: All collection and analysis happen locally. OmniDiag never uploads
    anything. Collected data and logs may contain usernames, device names, file
    paths, and domain information - review reports before sharing.

.PARAMETER Range
    Time-range preset for time-aware modules. Last24Hours | Last7Days | Last30Days.

.PARAMETER IncludeCategory
    Only run modules in these categories (e.g. System, Network).

.PARAMETER ExcludeCategory
    Skip modules in these categories.

.PARAMETER Gui
    Reserved for the WPF interface (later milestone). Falls back to console for now.

.PARAMETER Quiet
    Suppress streaming log output; show only the final dashboard.

.EXAMPLE
    .\OmniDiag.ps1

.EXAMPLE
    .\OmniDiag.ps1 -Range Last24Hours -IncludeCategory System
#>
[CmdletBinding()]
param(
    [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days')]
    [string] $Range = 'Last7Days',
    [string[]] $IncludeCategory,
    [string[]] $ExcludeCategory,
    [switch] $Gui,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Host validation -------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error 'OmniDiag requires Windows PowerShell 5.1 or PowerShell 7+.'
    exit 1
}

$isWindowsHost = $true
try { if ($IsWindows -eq $false) { $isWindowsHost = $false } } catch { }
if (-not $isWindowsHost) {
    Write-Warning 'OmniDiag targets Windows. On this OS most diagnostic modules will report no data.'
}

# --- Import module ---------------------------------------------------------
$manifest = Join-Path $PSScriptRoot 'src/OmniDiag.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Error "OmniDiag module not found at: $manifest"
    exit 1
}
Import-Module $manifest -Force -DisableNameChecking

# --- Elevation notice ------------------------------------------------------
if (-not (Test-OmniIsAdministrator)) {
    Write-Host 'Note: running without administrator rights. Some checks (and admin-only modules) will be skipped.' -ForegroundColor Yellow
    Write-Host '      Re-run from an elevated prompt for a complete scan.' -ForegroundColor Yellow
}

if ($Gui) {
    Write-Host 'The WPF GUI is not available in this milestone yet; running the console experience.' -ForegroundColor Yellow
}

# --- Run -------------------------------------------------------------------
$progress = New-OmniConsoleProgressCallback
$session = Invoke-OmniDiag -Range $Range -IncludeCategory $IncludeCategory -ExcludeCategory $ExcludeCategory `
    -ProgressCallback $progress -Quiet:$Quiet

Write-OmniConsoleDashboard -Session $session
Write-Host ("Structured log written to: {0}" -f $session.LogPath) -ForegroundColor DarkGray

# Make the session available to the caller for scripting/automation.
$session
