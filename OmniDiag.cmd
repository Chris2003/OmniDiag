@echo off
rem ============================================================================
rem  OmniDiag portable launcher (console)
rem
rem  Double-click this file, or run it from a command prompt. It runs the
rem  bundled OmniDiag.ps1 with the execution policy bypassed *for this process
rem  only* - no machine-wide policy change, no install, admin optional. This is
rem  what makes the extracted-from-zip copy "just run" on a locked-down box
rem  where script execution is otherwise blocked (Mark-of-the-Web / RemoteSigned).
rem
rem  Any arguments are passed straight through, e.g.:
rem      OmniDiag.cmd -Range Last24Hours
rem      OmniDiag.cmd -Report -ReportFormat Html -AcceptPrivacyNotice
rem      OmniDiag.cmd -Repair
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

rem Prefer PowerShell 7+ (pwsh) when present; fall back to Windows PowerShell 5.1,
rem which ships on every Windows 10/11 host.
set "PSEXE=powershell.exe"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

rem When double-clicked (no arguments), keep the window open so the dashboard
rem is readable. When invoked with arguments (console/automation), don't pause.
if "%~1"=="" (
    echo.
    pause
)
exit /b %RC%
