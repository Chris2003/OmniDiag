@echo off
rem ============================================================================
rem  'omnidiag' command for the per-user MSI install (docs\INSTALLER.md).
rem
rem  The MSI installs this file as <install dir>\bin\omnidiag.cmd and appends only
rem  that bin folder to the user PATH. cmd.exe and PowerShell both resolve
rem  'omnidiag' to it through PATHEXT (.CMD), and nothing else from the install
rem  folder (OmniDiag.ps1, OmniDiag-GUI.cmd) is put on PATH - in PowerShell a
rem  folder holding OmniDiag.ps1 on PATH would run that script instead.
rem
rem  It hands over to the real launcher one folder up WITHOUT 'call': control
rem  transfers to OmniDiag.cmd, the arguments are not parsed a second time
rem  (no caret doubling), and its 'exit /b' code becomes this command's exit code.
rem ============================================================================
"%~dp0..\OmniDiag.cmd" %*
