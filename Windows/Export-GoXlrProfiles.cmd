@echo off
setlocal
rem Bypass applies only to this PowerShell process; no saved execution policy changes.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Export-GoXlrProfiles.ps1"
set "taskExportExit=%ERRORLEVEL%"
if not "%taskExportExit%"=="0" pause
exit /b %taskExportExit%
