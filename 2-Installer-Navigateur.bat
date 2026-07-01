@echo off
setlocal
cd /d "%~dp0"

echo ==========================================================
echo   Installation du mode navigateur (pour Fnac et Carrefour)
echo   Necessaire une seule fois. Duree : 1 a 2 minutes.
echo ==========================================================
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js est requis pour le mode navigateur.
  echo Installe-le avec :   winget install OpenJS.NodeJS.LTS
  echo puis ferme/rouvre et relance ce fichier.
  echo.
  pause
  exit /b 1
)

echo Installation des dependances (Playwright)...
call npm install
if errorlevel 1 (
  echo.
  echo Echec de "npm install". Verifie ta connexion et reessaie.
  pause
  exit /b 1
)

echo.
echo Telechargement du navigateur Chromium...
call npx playwright install chromium

echo.
echo ==========================================================
echo   Termine ! Fnac et Carrefour seront releves via le
echo   navigateur. Lance maintenant "1-Initialiser-Prix.bat".
echo ==========================================================
echo.
pause
