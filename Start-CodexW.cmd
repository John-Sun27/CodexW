@echo off
setlocal
set "LAUNCHER=%~dp0CodexWLauncher.exe"
set "SCRIPT=%~dp0windows\CodexW.ps1"
if exist "%LAUNCHER%" (
  start "" "%LAUNCHER%"
  exit /b 0
)
if not exist "%SCRIPT%" (
  echo CodexW.ps1 was not found.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%SCRIPT%"
exit /b 0
