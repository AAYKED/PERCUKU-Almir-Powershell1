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

echo ====================================
echo   Recherche de codes promo
echo ====================================
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\promo.ps1"
echo.
pause
