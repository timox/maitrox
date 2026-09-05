@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

call :FindPwsh
if errorlevel 1 goto NoPwsh

REM Toute la logique de menu vit dans Menu.ps1 (PowerShell) : ce fichier ne
REM sert qu'a trouver pwsh et a le lancer. Une URL passee en argument saute
REM directement au traitement, comme avant.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Menu.ps1" -Url "%~1"
set CODE=%ERRORLEVEL%

echo.
pause
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
