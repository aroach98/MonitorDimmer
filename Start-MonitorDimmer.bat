@echo off
REM Double-click this to start the Monitor Dimmer with no visible window.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "%~dp0MonitorDimmer.ps1"
