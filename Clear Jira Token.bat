@echo off
cd /d "%~dp0"
echo This will remove the saved Jira token from your user environment variables.
echo.
powershell -ExecutionPolicy Bypass -NoProfile -Command ^
  "[Environment]::SetEnvironmentVariable('JIRA_PAT', $null, 'User');" ^
  "Remove-Item Env:JIRA_PAT -ErrorAction SilentlyContinue;" ^
  "Write-Host 'Removed JIRA_PAT from your user account.' -ForegroundColor Green"
echo.
echo Press any key to close this window.
pause >nul
