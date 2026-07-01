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
echo   Initialisation des prix de reference ^(a lancer 1 fois^)
echo   Aucune alerte : on enregistre juste les prix actuels.
echo ==========================================================
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Watch-Prices.ps1" -NoAlert
echo.
echo Termine. Lance ensuite "Suivi-Prix.bat" pour etre alerte des variations.
echo.
pause
