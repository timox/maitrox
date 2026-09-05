@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

call :FindPwsh
if errorlevel 1 goto NoPwsh

REM -sta : System.Windows.Forms exige un thread STA. Show-Gui.ps1 se
REM relance lui-meme avec -sta s'il ne l'est pas deja, donc ce n'est pas
REM strictement indispensable ici, mais evite un aller-retour inutile.
"%PWSH%" -NoProfile -sta -ExecutionPolicy Bypass -File "%~dp0Show-Gui.ps1"
set CODE=%ERRORLEVEL%

if not %CODE%==0 (
    echo.
    echo L'interface graphique s'est terminee avec le code %CODE%.
    pause
)
exit /b %CODE%


:FindPwsh
for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do (
    set "PWSH=%%P"
    exit /b 0
)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
    exit /b 0
)
if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" (
    set "PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
    exit /b 0
)
if exist "%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe" (
    set "PWSH=%LOCALAPPDATA%\Microsoft\PowerShell\7\pwsh.exe"
    exit /b 0
)
exit /b 1


:NoPwsh
echo.
echo   PowerShell 7 est introuvable. Lance d'abord installer.bat.
echo.
echo   Ce kit ne fonctionne ni avec le PowerShell 5.1 de Windows, ni
echo   avec ISE : il utilise des fonctions qui n'existent pas en 5.1.
echo.
pause
exit /b 1
