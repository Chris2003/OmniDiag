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

set "PSEXE=powershell.exe"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

start "OmniDiag" "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Gui
exit /b 0
