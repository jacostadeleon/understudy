@echo off
setlocal
set "UNDERSTUDY_DIR=%~dp0"
start "understudy" /min node "%UNDERSTUDY_DIR%proxy.mjs"
timeout /t 1 /nobreak >nul
curl -s http://127.0.0.1:8793/healthz
echo.
echo proxy is running. launch Claude Code with: %UNDERSTUDY_DIR%launch-claude.cmd
endlocal
