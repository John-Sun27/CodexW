@echo off
setlocal
set "SCRIPT=%~dp0CodexW.ps1"
if not exist "%SCRIPT%" (
  echo CodexW.ps1 was not found.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%SCRIPT%"
exit /b 0
