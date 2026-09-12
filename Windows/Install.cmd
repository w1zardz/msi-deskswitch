@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
set "taskInstallExit=%ERRORLEVEL%"
if not "%taskInstallExit%"=="0" echo Installation did not finish. Read the error above.
pause
exit /b %taskInstallExit%
