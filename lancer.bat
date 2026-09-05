@echo off
chcp 65001 >nul
setlocal
set "CODE=0"

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
echo   [2] Reprendre les titres manquants
echo   [3] Voir l'etat des playlists deja traitees
echo   [4] Quitter
echo.

set "MENU="
set /p "MENU=Choix [1] : "
if "%MENU%"=="" set "MENU=1"

if "%MENU%"=="1" goto AskUrl
if "%MENU%"=="2" goto ResumeMenu
if "%MENU%"=="3" goto Etat
if "%MENU%"=="4" goto Quit

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
set "URL="
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
set "CHOIX="
set /p "CHOIX=Choix [1] : "
if "%CHOIX%"=="" set "CHOIX=1"

set "MODE="
set "VALID="
if "%CHOIX%"=="1" (set "MODE=-Download -PrintOnly" & set "VALID=1")
if "%CHOIX%"=="2" (set "MODE=-Download" & set "VALID=1")
if "%CHOIX%"=="3" (set "MODE=" & set "VALID=1")
if not defined VALID goto BadChoiceMenu

set "DEST="
if not "%CHOIX%"=="3" (
    set "CURRENTDEST="
    for /f "delims=" %%D in ('"%PWSH%" -NoProfile -Command ". \"%~dp0SockseekLib.ps1\"; Get-DefaultOutputDir"') do set "CURRENTDEST=%%D"

    echo.
    echo Dossier de destination actuel : "%CURRENTDEST%"
    echo Laisse vide pour le conserver, ou tape un nouveau chemin pour le
    echo remplacer ^(il devient le defaut pour les prochaines fois^) :
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
    echo Le detail est dans rapport.csv, dans le sous-dossier de la playlist
    echo ^(a l'interieur du dossier de destination^).
    echo.
    echo Sur un reseau P2P, reessayer plus tard suffit souvent : le pair
    echo qui partage le morceau doit simplement etre connecte. Choisis
    echo "Reprendre les titres manquants" dans le menu principal.
) else (
    echo Termine avec le code %CODE%. Relis les messages ci-dessus.
)
goto PostAction


REM ========================================================= reprise ========
REM Resume-Downloads.ps1 ne filtre que par PLAYLIST (-Only), pas titre par
REM titre : "une playlist en particulier" est donc la plus fine granularite
REM disponible.
:ResumeMenu
echo.
echo ----------------------------------------------------------------
echo  Reprise des titres manquants
echo ----------------------------------------------------------------
echo.
echo Un morceau introuvable un jour peut apparaitre le lendemain : il
echo suffit que le pair qui le partage se reconnecte. L'etat actuel :
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1" -List

echo.
echo Que veux-tu reprendre ?
echo.
echo   [1] Voir d'abord la liste des titres qui seraient repris (test, rien de relance)
echo   [2] Tous les morceaux manquants, toutes playlists confondues
echo   [3] Une playlist en particulier
echo   [4] Retour au menu principal
echo   [5] Quitter
echo.
set "RMODE="
set /p "RMODE=Choix [1] : "
if "%RMODE%"=="" set "RMODE=1"

if "%RMODE%"=="1" goto ResumeDryRunAll
if "%RMODE%"=="2" goto ResumeRunAll
if "%RMODE%"=="3" goto ResumeAskPlaylist
if "%RMODE%"=="4" goto Menu
if "%RMODE%"=="5" goto Quit
goto BadChoiceResume


:ResumeDryRunAll
echo.
echo ----------------------------------------------------------------
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1" -DryRun

echo.
echo Que veux-tu faire maintenant ?
echo.
echo   [1] Reprendre tous ces titres pour de vrai
echo   [2] Reprendre une playlist en particulier plutot
echo   [3] Retour au menu de reprise
echo   [4] Retour au menu principal
echo   [5] Quitter
echo.
set "DMODE="
set /p "DMODE=Choix [3] : "
if "%DMODE%"=="" set "DMODE=3"

if "%DMODE%"=="1" goto ResumeRunAll
if "%DMODE%"=="2" goto ResumeAskPlaylist
if "%DMODE%"=="3" goto ResumeMenu
if "%DMODE%"=="4" goto Menu
if "%DMODE%"=="5" goto Quit
goto BadChoiceResume


:ResumeRunAll
echo.
echo ----------------------------------------------------------------
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1"
set CODE=%ERRORLEVEL%
goto PostAction


:ResumeAskPlaylist
echo.
echo Nom ^(ou fragment du nom^) de la playlist a reprendre, tel qu'affiche
echo dans la colonne "Playlist" ci-dessus :
echo.
set "PLNAME="
set /p "PLNAME=Playlist : "
if "%PLNAME%"=="" goto ResumeMenu

echo.
echo   [1] Tester d'abord : voir ce qui serait repris pour cette playlist
echo   [2] Reprendre cette playlist pour de vrai
echo.
set "OMODE="
set /p "OMODE=Choix [1] : "
if "%OMODE%"=="" set "OMODE=1"

if "%OMODE%"=="2" goto ResumeRunOnly
if not "%OMODE%"=="1" goto BadChoiceResume

echo.
echo ----------------------------------------------------------------
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1" -Only "%PLNAME%" -DryRun

echo.
echo Que veux-tu faire maintenant ?
echo.
echo   [1] Reprendre cette playlist pour de vrai
echo   [2] Retour au menu de reprise
echo   [3] Retour au menu principal
echo   [4] Quitter
echo.
set "OMODE2="
set /p "OMODE2=Choix [2] : "
if "%OMODE2%"=="" set "OMODE2=2"

if "%OMODE2%"=="1" goto ResumeRunOnly
if "%OMODE2%"=="2" goto ResumeMenu
if "%OMODE2%"=="3" goto Menu
if "%OMODE2%"=="4" goto Quit
goto BadChoiceResume


:ResumeRunOnly
echo.
echo ----------------------------------------------------------------
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1" -Only "%PLNAME%"
set CODE=%ERRORLEVEL%
goto PostAction


REM ============================================================ etat ========
:Etat
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resume-Downloads.ps1" -List
set CODE=%ERRORLEVEL%
goto PostAction


REM =============================================== retour ou sortie =========
:PostAction
echo.
echo ----------------------------------------------------------------
echo   [1] Retour au menu principal
echo   [2] Quitter
echo.
set "POST="
set /p "POST=Choix [1] : "
if "%POST%"=="" set "POST=1"

if "%POST%"=="1" goto Menu
if "%POST%"=="2" goto Quit
goto PostAction


:Quit
echo.
exit /b %CODE%


:NoUrl
echo.
echo   Aucune URL saisie, rien a faire.
timeout /t 2 >nul
goto Menu


:BadChoiceMenu
echo.
echo   Choix invalide.
timeout /t 2 >nul
goto AskMode


:BadChoiceResume
echo.
echo   Choix invalide.
timeout /t 2 >nul
goto ResumeMenu


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
