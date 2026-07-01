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

set "PSEXE=powershell.exe"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

start "OmniDiag" "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Gui
exit /b 0
