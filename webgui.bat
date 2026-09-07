@echo off
setlocal
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
    echo Node.js est introuvable dans le PATH.
    echo Installe-le depuis https://nodejs.org/ puis relance ce script.
    pause
    exit /b 1
)

start "" cmd /c "timeout /t 2 >nul & start http://localhost:8342"
node webgui\server.js
