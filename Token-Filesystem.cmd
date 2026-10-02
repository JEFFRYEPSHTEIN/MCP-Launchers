@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-MCP-Token.ps1" -Server Filesystem %*
set "MCP_TOKEN_EXIT=%errorlevel%"
pause
exit /b %MCP_TOKEN_EXIT%
