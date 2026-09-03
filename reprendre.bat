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

call :FindPwsh
if errorlevel 1 goto NoPwsh

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

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1" %MODE%
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
pause
exit /b 1
