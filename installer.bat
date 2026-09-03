@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

echo ================================================================
echo  Installation du kit sockseek
echo ================================================================
echo.

call :FindPwsh
if errorlevel 1 goto NoPwsh

echo Utilisation de : %PWSH%
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Sockseek.ps1" %*
set CODE=%ERRORLEVEL%

echo.
if %CODE% neq 0 (
    echo L'installation s'est terminee avec le code %CODE%.
    echo Relis les messages ci-dessus.
) else (
    echo Installation terminee.
    echo.
    echo IMPORTANT : ferme cette fenetre et rouvre-en une nouvelle avant
    echo d'utiliser lancer.bat. Le PATH n'est relu qu'au demarrage d'un
    echo nouveau processus.
)

echo.
pause
exit /b %CODE%


:FindPwsh
REM PowerShell 7 dans le PATH ?
for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do (
    set "PWSH=%%P"
    exit /b 0
)
REM Sinon, emplacements d'installation habituels.
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
echo   PowerShell 7 est introuvable.
echo.
echo   Ce kit ne fonctionne pas avec le PowerShell 5.1 livre avec Windows
echo   ni avec ISE : il utilise des fonctions qui n'existent pas en 5.1.
echo.
echo   Installe-le, puis relance ce fichier :
echo.
echo      winget install --id Microsoft.PowerShell --source winget
echo.
echo   Si winget n'existe pas sur ce poste, recupere le paquet MSI
echo   PowerShell-7.x-win-x64.msi depuis la page des releases GitHub
echo   du projet PowerShell.
echo.
pause
exit /b 1
