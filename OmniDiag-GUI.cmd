@echo off
rem ============================================================================
rem  OmniDiag portable launcher (graphical interface)
rem
rem  Double-click to open the OmniDiag WPF window. Like OmniDiag.cmd, the
rem  execution policy is bypassed for this process only. The GUI is launched
rem  detached so this console window closes immediately.
rem ============================================================================
setlocal EnableExtensions
set "HERE=%~dp0"
set "SCRIPT=%HERE%OmniDiag.ps1"

if not exist "%SCRIPT%" (
    echo [OmniDiag] Cannot find OmniDiag.ps1 next to this launcher.
    exit /b 1
)

rem --- Portable / zero-footprint environment (this process only) -------------
rem Everything OmniDiag writes stays in OmniDiagData next to this launcher, so a
rem copy on a USB stick leaves no OmniDiag files on the host. PowerShell's own
rem module-analysis cache, update check, and telemetry are redirected/disabled,
rem and TEMP points at the tool folder (the real one is kept for the temp-clean repair).
set "OMNIDIAG_DATA=%HERE%OmniDiagData"
rem Installed by the per-user MSI (marker file next to this launcher; never in the
rem portable zip): data lives in %LOCALAPPDATA%\OmniDiag\Data instead, so upgrades
rem and uninstall never touch it (docs\INSTALLER.md). Must match src\Core\Paths.psm1.
if exist "%HERE%.omnidiag-installed" if defined LOCALAPPDATA set "OMNIDIAG_DATA=%LOCALAPPDATA%\OmniDiag\Data"
if not exist "%OMNIDIAG_DATA%\temp" mkdir "%OMNIDIAG_DATA%\temp" >nul 2>nul
if exist "%OMNIDIAG_DATA%\temp" if not exist "%OMNIDIAG_DATA%\temp\.omnidiag-scratch" (echo OmniDiag scratch folder; safe to delete.)>"%OMNIDIAG_DATA%\temp\.omnidiag-scratch" 2>nul
if exist "%OMNIDIAG_DATA%\temp" (
    set "OMNIDIAG_HOST_TEMP=%TEMP%"
    set "TEMP=%OMNIDIAG_DATA%\temp"
    set "TMP=%OMNIDIAG_DATA%\temp"
    set "PSModuleAnalysisCachePath=%OMNIDIAG_DATA%\cache\ModuleAnalysisCache"
) else (
    rem Read-only media: let OmniDiag pick its fallback location.
    set "OMNIDIAG_DATA="
)
set "POWERSHELL_TELEMETRY_OPTOUT=1"
set "POWERSHELL_UPDATECHECK=Off"
set "POWERSHELL_CLI_TELEMETRY_OPTOUT=1"

rem --- PowerShell executable: pinned paths, never a PATH / current-directory lookup ---
rem Prefer PowerShell 7+ (pwsh) when installed; fall back to Windows PowerShell 5.1,
rem which ships on every Windows 10/11 host. Only the fixed install locations are
rem considered (lowest priority first; each existing one overrides the previous), so
rem a pwsh.exe or powershell.exe planted in PATH or next to this file is never run.
rem Every variable is checked with 'defined' first: an unset one would expand to ""
rem and point at the root of the current drive, which standard users can write to.
if not defined SystemRoot set "SystemRoot=%windir%"
if not defined SystemRoot (
    echo [OmniDiag] SystemRoot is not set; cannot locate Windows PowerShell.
    exit /b 1
)
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined ProgramFiles(x86) if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PSEXE=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PSEXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PSEXE=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not exist "%PSEXE%" (
    echo [OmniDiag] Cannot find Windows PowerShell under %%SystemRoot%%\System32\WindowsPowerShell\v1.0.
    exit /b 1
)

start "OmniDiag" "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Gui
exit /b 0
