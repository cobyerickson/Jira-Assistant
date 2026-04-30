@echo off
cd /d "%~dp0"
set "HELPER_URL=http://localhost:8765/health"
set "APP_URL=http://localhost:8765/app"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { $r = Invoke-WebRequest -Uri '%HELPER_URL%' -UseBasicParsing -TimeoutSec 2; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }"

if not errorlevel 1 (
  echo Jira helper is already running.
  echo.
  echo You can use the app right now.
  echo App URL:
  echo   %APP_URL%
  echo.
  echo Helper test URL:
  echo   %HELPER_URL%
  echo.
  echo Press any key to close this window.
  pause >nul
  exit /b 0
)

echo Starting Jira helper...
echo.
echo To stop it later:
echo   Double-click "Stop Jira Helper.bat"
echo.
powershell -ExecutionPolicy Bypass -File ".\jira-proxy.ps1"
if errorlevel 1 (
  echo.
  echo Jira helper stopped with an error.
  echo Press any key to close this window.
  pause >nul
)
