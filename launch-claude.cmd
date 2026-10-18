@echo off
setlocal
set "ANTHROPIC_BASE_URL=http://127.0.0.1:8793"
set "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
claude %*
endlocal
