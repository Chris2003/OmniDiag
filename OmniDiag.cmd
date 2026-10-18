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
rem  It is also the 'omnidiag' command: Windows file names are case-insensitive,
rem  so this one file serves both spellings. The first argument picks the entry:
rem    * a subcommand or a --long option  -> the CLI router (src\Cli\omnidiag.ps1)
rem          omnidiag list modules --format json
rem          omnidiag scan --group network
rem          omnidiag report --output C:\Reports
rem          omnidiag --help
rem    * nothing, or a PowerShell-style -Switch -> the classic console (OmniDiag.ps1)
rem          OmniDiag.cmd -Range Last24Hours
rem          OmniDiag.cmd -Report -ReportFormat Html -AcceptPrivacyNotice
rem          OmniDiag.cmd -Repair
rem  Arguments are passed straight through, and the exit code (see docs\CLI.md)
rem  is propagated as %ERRORLEVEL%.
rem ============================================================================
setlocal EnableExtensions
set "HERE=%~dp0"
set "SCRIPT=%HERE%OmniDiag.ps1"
set "CLI=%HERE%src\Cli\omnidiag.ps1"

if not exist "%SCRIPT%" (
    echo [OmniDiag] Cannot find OmniDiag.ps1 next to this launcher.
    exit /b 20
)

rem --- Entry point: CLI router for subcommands / --options, classic console otherwise.
rem (No goto/labels: they are unreliable in batch files with LF line endings.)
set "MODE=legacy"
set "ARG1=%~1"
if defined ARG1 set "MODE=cli"
if defined ARG1 if "%ARG1:~0,1%"=="-" set "MODE=legacy"
if defined ARG1 if "%ARG1:~0,2%"=="--" set "MODE=cli"
set "ENTRY=%SCRIPT%"
if "%MODE%"=="cli" set "ENTRY=%CLI%"
if not exist "%ENTRY%" (
    echo [OmniDiag] Cannot find %ENTRY%.
    exit /b 20
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
    exit /b 20
)
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined ProgramFiles(x86) if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PSEXE=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PSEXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "PSEXE=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not exist "%PSEXE%" (
    echo [OmniDiag] Cannot find Windows PowerShell under %%SystemRoot%%\System32\WindowsPowerShell\v1.0.
    exit /b 20
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%ENTRY%" %*
set "RC=%ERRORLEVEL%"

rem When double-clicked (no arguments), keep the window open so the dashboard
rem is readable. With arguments (console/automation, and every CLI command) it
rem never pauses.
if "%~1"=="" (
    echo.
    pause
)
exit /b %RC%
