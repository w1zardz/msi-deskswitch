@echo off
setlocal
rem This does not change the saved PowerShell execution policy.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Import-GoXlrProfiles.ps1" -ManifestPath "%~dp0GoXLR-Import.json"
set "taskImportExit=%ERRORLEVEL%"
pause
exit /b %taskImportExit%
