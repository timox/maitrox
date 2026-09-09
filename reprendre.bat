@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

echo ================================================================
echo  Reprise des titres manquants
echo ================================================================
echo.
echo Sur un reseau P2P, un morceau introuvable un jour peut apparaitre
echo le lendemain : il suffit que le pair qui le partage se reconnecte.
echo Cette reprise repasse sur tout ce qui manque, en une seule fois.
echo.

where node >nul 2>nul
if errorlevel 1 goto NoNode

echo Que veux-tu faire ?
echo.
echo   [1] Voir l'etat des playlists, sans rien relancer
echo   [2] Voir la liste des titres qui seraient repris
echo   [3] Reprendre pour de vrai
echo.
set /p "CHOIX=Choix [1] : "
if "%CHOIX%"=="" set "CHOIX=1"

set "MODE="
set "VALID="
if "%CHOIX%"=="1" (set "MODE=-List" & set "VALID=1")
if "%CHOIX%"=="2" (set "MODE=-DryRun" & set "VALID=1")
if "%CHOIX%"=="3" (set "MODE=" & set "VALID=1")
if not defined VALID goto BadChoice

echo.
echo ----------------------------------------------------------------
echo.

node "%~dp0bin\resume.js" %MODE%
set CODE=%ERRORLEVEL%

echo.
echo ----------------------------------------------------------------
if not %CODE%==0 echo Termine avec le code %CODE%.

echo.
pause
exit /b %CODE%


:BadChoice
echo.
echo   Choix invalide : tape 1, 2 ou 3.
echo.
pause
exit /b 1


:NoNode
echo.
echo   Node.js est introuvable dans le PATH.
echo.
echo   Installe-le depuis https://nodejs.org/ puis relance ce fichier.
echo.
pause
exit /b 1
