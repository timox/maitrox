@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 goto NoNode

REM Toute la logique de menu vit dans bin/menu.js (Node) : ce fichier ne
REM sert qu'a trouver node et a le lancer. Une URL passee en argument saute
REM directement au traitement, comme avant.
if "%~1"=="" (
    node "%~dp0bin\menu.js"
) else (
    node "%~dp0bin\menu.js" --url "%~1"
)
set CODE=%ERRORLEVEL%

echo.
pause
exit /b %CODE%


:NoNode
echo.
echo   Node.js est introuvable dans le PATH.
echo.
echo   Installe-le depuis https://nodejs.org/ puis relance ce fichier.
echo.
pause
exit /b 1
