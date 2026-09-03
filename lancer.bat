@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

echo ================================================================
echo  Recuperation d'une playlist vers Soulseek
echo ================================================================
echo.

call :FindPwsh
if errorlevel 1 goto NoPwsh

REM L'URL peut arriver en argument, sinon on la demande.
set "URL=%~1"
if not "%URL%"=="" goto HaveUrl

echo Colle l'URL de la playlist SoundCloud ou YouTube.
echo (clic droit dans cette fenetre pour coller)
echo.
set /p "URL=URL : "

:HaveUrl
if "%URL%"=="" goto NoUrl

echo.
echo URL : "%URL%"
echo.

REM Une recherche a blanc evite d'engager dix minutes pour rien.
set "MODE="
echo Que veux-tu faire ?
echo.
echo   [1] Tester d'abord : cherche sur Soulseek, ne telecharge rien
echo   [2] Telecharger pour de vrai
echo   [3] Extraire et nettoyer la liste seulement, sans toucher a Soulseek
echo.
set /p "CHOIX=Choix [1] : "
if "%CHOIX%"=="" set "CHOIX=1"

set "VALID="
if "%CHOIX%"=="1" (set "MODE=-Download -PrintOnly" & set "VALID=1")
if "%CHOIX%"=="2" (set "MODE=-Download" & set "VALID=1")
if "%CHOIX%"=="3" (set "MODE=" & set "VALID=1")
if not defined VALID goto BadChoice

REM Dossier de destination facultatif : vide = valeur du fichier de config.
set "DEST="
if not "%CHOIX%"=="3" (
    echo.
    echo Dossier de destination ^(laisse vide pour la valeur par defaut^) :
    set /p "DEST=Dossier : "
)

set "DESTARG="
if not "%DEST%"=="" set DESTARG=-OutputDir "%DEST%"

echo.
echo ----------------------------------------------------------------
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-SoulseekList.ps1" -Url "%URL%" %MODE% %DESTARG%
set CODE=%ERRORLEVEL%

echo.
echo ----------------------------------------------------------------
if %CODE%==0 (
    echo Termine sans echec.
) else if %CODE%==10 (
    echo Termine, mais certains titres n'ont pas ete recuperes.
    echo Le detail est dans rapport.csv, dans le dossier de destination.
) else (
    echo Termine avec le code %CODE%. Relis les messages ci-dessus.
)

echo.
pause
exit /b %CODE%


:NoUrl
echo.
echo   Aucune URL saisie, rien a faire.
echo.
pause
exit /b 1


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
