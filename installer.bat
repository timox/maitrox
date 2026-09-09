@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

echo ================================================================
echo  Installation du kit sockseek
echo ================================================================
echo.

where node >nul 2>nul
if errorlevel 1 goto NoNode

node "%~dp0bin\install.js" %*
set CODE=%ERRORLEVEL%

echo.
if %CODE% neq 0 (
    echo L'installation s'est terminee avec le code %CODE%.
    echo Relis les messages ci-dessus.
) else (
    echo Installation terminee.
)

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
