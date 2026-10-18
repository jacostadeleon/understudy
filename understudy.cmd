@echo off
rem one-click understudy: starts (or reuses) the proxy and parks the tray app
rem in the system tray: green dot = running, red = stopped, right-click for controls
start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tray.ps1"
