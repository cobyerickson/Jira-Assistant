@echo off
cd /d "%~dp0"
echo This will save your Jira personal access token as a user environment variable.
echo You should only do this on your own computer.
echo.
powershell -ExecutionPolicy Bypass -NoProfile -Command ^
  "$token = Read-Host 'Paste your Jira personal access token';" ^
  "if ([string]::IsNullOrWhiteSpace($token)) { Write-Host 'No token was entered.' -ForegroundColor Yellow; exit 1 };" ^
  "[Environment]::SetEnvironmentVariable('JIRA_PAT', $token, 'User');" ^
  "$env:JIRA_PAT = $token;" ^
  "Write-Host 'Saved JIRA_PAT for your user account.' -ForegroundColor Green;" ^
  "Write-Host 'You can now start the helper without pasting the token each time.'"
echo.
echo Press any key to close this window.
pause >nul
