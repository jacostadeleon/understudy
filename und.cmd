@echo off
rem understudy control for Windows: start | stop | status | launch
setlocal
set "DIR=%~dp0"
if "%~1"=="" goto start
goto %~1 2>nul || goto usage

:start
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port 8793 -InformationLevel Quiet -WarningAction SilentlyContinue)) { Start-Process node -ArgumentList '\"%~dp0proxy.mjs\"' -WindowStyle Hidden; Start-Sleep 2 }; try { Invoke-RestMethod http://127.0.0.1:8793/healthz -TimeoutSec 3 | ConvertTo-Json -Compress } catch { Write-Host 'understudy: proxy failed to start' }"
goto :eof

:stop
powershell -NoProfile -Command "try { Invoke-RestMethod http://127.0.0.1:8793/shutdown -Method Post -TimeoutSec 3 | Out-Null; 'understudy: stopped' } catch { 'understudy: not running' }"
goto :eof

:status
powershell -NoProfile -Command "try { Invoke-RestMethod http://127.0.0.1:8793/healthz -TimeoutSec 3 | ConvertTo-Json -Compress } catch { Write-Host 'understudy: DOWN'; exit 1 }"
goto :eof

:launch
set "ANTHROPIC_BASE_URL=http://127.0.0.1:8793"
set "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
claude %2 %3 %4 %5 %6 %7 %8 %9
goto :eof

:usage
echo usage: und.cmd {start^|stop^|status^|launch [claude args]}
exit /b 1
