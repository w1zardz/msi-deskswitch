@echo off
setlocal
rem Process-only policy; saved execution policy is not changed.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-AudioSetup.ps1"
set "taskAudioExit=%ERRORLEVEL%"
pause
exit /b %taskAudioExit%
