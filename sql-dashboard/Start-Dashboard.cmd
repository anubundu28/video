@echo off
rem SQL Server Health Dashboard launcher.
rem Starts the local web server with the PowerShell that ships with Windows.
rem -ExecutionPolicy Bypass applies to this process only; nothing is changed on the machine.
setlocal
cd /d "%~dp0"
title SQL Server Health Dashboard
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
if errorlevel 1 (
  echo.
  echo The dashboard stopped with an error. See the messages above.
  pause
)
