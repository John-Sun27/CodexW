@echo off
setlocal
cd /d "%~dp0"
set "SCRIPT=%~dp0CodexW.ps1"
if not exist "%SCRIPT%" (
  echo CodexW.ps1 was not found.
  pause
  exit /b 1
)
set "VBS=%TEMP%\codexw-start-%RANDOM%%RANDOM%.vbs"
> "%VBS%" echo Set sh = CreateObject("WScript.Shell")
>> "%VBS%" echo sh.CurrentDirectory = "%~dp0"
>> "%VBS%" echo sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ""%SCRIPT%""", 0, False
wscript.exe "%VBS%"
exit /b 0
