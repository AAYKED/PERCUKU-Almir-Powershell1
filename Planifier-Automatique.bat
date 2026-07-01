@echo off
setlocal
cd /d "%~dp0"

where pwsh >nul 2>nul
if errorlevel 1 (
  echo.
  echo PowerShell 7 ^(pwsh^) est introuvable.
  echo Installe-le avec :  winget install Microsoft.PowerShell
  echo puis relance ce fichier.
  echo.
  pause
  exit /b 1
)

echo ==========================================================
echo   Planification automatique du suivi des prix
echo   Le releve se fera tout seul toutes les 6 heures.
echo ==========================================================
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Register-PriceWatchTask.ps1" -IntervalHours 6 -RunNow
echo.
echo Pour arreter plus tard, lance :
echo   pwsh .\Register-PriceWatchTask.ps1 -Unregister
echo.
pause
