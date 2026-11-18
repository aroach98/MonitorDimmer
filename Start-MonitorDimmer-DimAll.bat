@echo off
REM Start the Monitor Dimmer with EVERY monitor dimmed (full-screen dimming) at 100%.
REM Ctrl+Alt+Up/Down = darker/lighter, Ctrl+Alt+A = back to focus-follow mode.
start "" C:\Windows\System32\conhost.exe --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "%~dp0MonitorDimmer.ps1" -DimAll -Level 1.0
