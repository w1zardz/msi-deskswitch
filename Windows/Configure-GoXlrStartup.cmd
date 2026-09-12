@echo off
setlocal
rem This does not change the saved PowerShell execution policy.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Configure-GoXlrStartup.ps1"
set "taskStartupExit=%ERRORLEVEL%"
pause
exit /b %taskStartupExit%
