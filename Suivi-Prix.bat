@echo off
setlocal
rem Se placer dans le dossier du projet (la ou est ce fichier)
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
echo   Suivi des prix PS5 - PromoAggregator
echo ====================================
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Watch-Prices.ps1"
echo.
pause
