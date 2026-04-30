@echo off
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$pidFile = Join-Path (Get-Location) 'jira-helper.pid';" ^
  "$helperPid = '';" ^
  "if (Test-Path -LiteralPath $pidFile) { $helperPid = (Get-Content -LiteralPath $pidFile -Raw).Trim() };" ^
  "if (-not $helperPid) {" ^
  "  try { $r = Invoke-WebRequest -Uri 'http://localhost:8765/health' -UseBasicParsing -TimeoutSec 2; if ($r.StatusCode -eq 200) {" ^
  "      $conn = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1;" ^
  "      if ($conn) { $helperPid = [string]$conn.OwningProcess }" ^
  "    } } catch {}" ^
  "};" ^
  "if (-not $helperPid) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue; Write-Host 'Jira helper is not currently running.' -ForegroundColor Yellow; exit 0 };" ^
  "try { Stop-Process -Id ([int]$helperPid) -Force -ErrorAction Stop; Write-Host ('Stopped Jira helper (PID ' + $helperPid + ').') -ForegroundColor Green }" ^
  "catch { Write-Host 'Could not stop the Jira helper. It may already be closed.' -ForegroundColor Yellow };" ^
  "Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue"

echo.
echo Press any key to close this window.
pause >nul
