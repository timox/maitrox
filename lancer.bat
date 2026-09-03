@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

call :FindPwsh
if errorlevel 1 goto NoPwsh

REM Une URL passee en argument saute directement au traitement.
set "URL=%~1"
if not "%URL%"=="" goto AskMode

:Menu
cls
echo ================================================================
echo  Kit sockseek
echo ================================================================
echo.
echo   [1] Traiter une nouvelle playlist
echo   [2] Reprendre les titres manquants (toutes playlists)
echo   [3] Voir l'etat des playlists deja traitees
echo   [4] Quitter
echo.

set /p "MENU=Choix [1] : "
if "%MENU%"=="" set "MENU=1"

if "%MENU%"=="1" goto AskUrl
if "%MENU%"=="2" goto Resume
if "%MENU%"=="3" goto Etat
if "%MENU%"=="4" exit /b 0

echo.
echo   Choix invalide.
timeout /t 2 >nul
goto Menu


REM =============================================== nouvelle playlist ========
:AskUrl
echo.
echo Colle l'URL de la playlist SoundCloud ou YouTube.
echo (clic droit dans cette fenetre pour coller)
echo.
set /p "URL=URL : "
if "%URL%"=="" goto NoUrl

:AskMode
echo.
echo URL : "%URL%"
echo.
echo Que veux-tu faire ?
echo.
echo   [1] Tester d'abord : cherche sur Soulseek, ne telecharge rien
echo   [2] Telecharger pour de vrai
echo   [3] Extraire et nettoyer la liste seulement, sans toucher a Soulseek
echo.
set /p "CHOIX=Choix [1] : "
if "%CHOIX%"=="" set "CHOIX=1"

set "MODE="
set "VALID="
if "%CHOIX%"=="1" (set "MODE=-Download -PrintOnly" & set "VALID=1")
if "%CHOIX%"=="2" (set "MODE=-Download" & set "VALID=1")
if "%CHOIX%"=="3" (set "MODE=" & set "VALID=1")
if not defined VALID goto BadChoice

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
if "%CODE%"=="0" (
    echo Termine sans echec.
) else if "%CODE%"=="10" (
    echo Termine, mais certains titres n'ont pas ete recuperes.
    echo Le detail est dans rapport.csv, dans le dossier de destination.
    echo.
    echo Sur un reseau P2P, reessayer plus tard suffit souvent : le pair
    echo qui partage le morceau doit simplement etre connecte. Relance ce
    echo fichier et choisis "Reprendre les titres manquants".
) else (
    echo Termine avec le code %CODE%. Relis les messages ci-dessus.
)
goto End


REM ========================================================= reprise ========
:Resume
echo.
echo ----------------------------------------------------------------
echo  Reprise des titres manquants
echo ----------------------------------------------------------------
echo.
echo Un morceau introuvable un jour peut apparaitre le lendemain : il
echo suffit que le pair qui le partage se reconnecte. La reprise repasse
echo sur tout ce qui manque, toutes playlists confondues, en une fois.
echo.
echo   [1] Voir d'abord la liste des titres qui seraient repris
echo   [2] Reprendre maintenant
echo.
set /p "RMODE=Choix [1] : "
if "%RMODE%"=="" set "RMODE=1"

set "RARG="
set "VALID="
if "%RMODE%"=="1" (set "RARG=-DryRun" & set "VALID=1")
if "%RMODE%"=="2" (set "RARG=" & set "VALID=1")
if not defined VALID goto BadChoice

echo.
echo ----------------------------------------------------------------
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1" %RARG%
set CODE=%ERRORLEVEL%
goto End


REM ============================================================ etat ========
:Etat
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1" -List
set CODE=%ERRORLEVEL%
goto End


REM =========================================================== sortie =======
:End
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
echo   Choix invalide.
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
echo   Ce kit ne fonctionne ni avec le PowerShell 5.1 de Windows, ni
echo   avec ISE : il utilise des fonctions qui n'existent pas en 5.1.
echo.
pause
exit /b 1
