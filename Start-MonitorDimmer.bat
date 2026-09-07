@echo off
REM Double-click this to start the Monitor Dimmer as a background process.
REM conhost --headless = no console window at all (plain -WindowStyle Hidden
REM still creates one, and closing it kills the dimmer). Look for the tray icon.
start "" C:\Windows\System32\conhost.exe --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "%~dp0MonitorDimmer.ps1"
