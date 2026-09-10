@echo off
REM Script unique : met a jour le code du kit, installe/met a jour les
REM binaires (sockseek, yt-dlp) et la configuration, puis demarre
REM l'interface web -- un seul script pour tout installer et deployer,
REM du premier lancement aux suivants. Pas besoin d'autre script ni de
REM commande git/node a taper a la main.
chcp 65001 >nul
setlocal EnableDelayedExpansion

cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 goto NoNode

REM ------------------------------------------------- mise a jour du code ---
REM Sans effet si le dossier n'est pas un clone git ou sans reseau : avertit
REM et continue plutot que de bloquer la suite pour autant.
if exist "%~dp0.git" (
    where git >nul 2>nul
    if not errorlevel 1 (
        echo ================================================================
        echo  Mise a jour du kit
        echo ================================================================
        echo.
        for /f "delims=" %%H in ('git rev-parse HEAD 2^>nul') do set "BEFORE=%%H"
        git pull --ff-only
        if errorlevel 1 (
            echo.
            echo Mise a jour du kit impossible ^(pas de reseau, ou modifications
            echo locales en conflit^) : on continue avec le code deja present.
        ) else (
            for /f "delims=" %%H in ('git rev-parse HEAD 2^>nul') do set "AFTER=%%H"
            if not "!BEFORE!"=="!AFTER!" (
                echo.
                echo Kit mis a jour.
            ) else (
                echo.
                echo Deja a jour.
            )
        )
        echo.
    )
)

REM --------------------------------------------- binaires + configuration --
REM Meilleur effort : une panne ici (quota GitHub, pas de reseau) ne doit
REM pas empecher de demarrer l'interface web -- elle affiche le meme
REM diagnostic et permet de reessayer l'installation depuis l'onglet
REM Configuration.
REM
REM -SkipCredentials par defaut : ce script ne doit jamais s'arreter pour
REM attendre une saisie dans CETTE fenetre -- les identifiants Soulseek se
REM configurent dans l'interface web demarree juste apres (onglet
REM Configuration), pas ici. Sans effet si -ForceCredentials ou
REM -SkipCredentials figure deja dans les arguments.
set "INSTALL_ARGS=%*"
echo !INSTALL_ARGS! | findstr /C:"-ForceCredentials" /C:"-SkipCredentials" >nul
if errorlevel 1 (
    node "%~dp0bin\install.js" -SkipCredentials %*
) else (
    node "%~dp0bin\install.js" %*
)

REM --------------------------------------------------- interface web -------
echo.
echo ================================================================
echo  Demarrage de l'interface web
echo ================================================================
echo.

start "" cmd /c "timeout /t 2 >nul & start http://localhost:8342"
node "%~dp0webgui\server.js"
exit /b %ERRORLEVEL%


:NoNode
echo.
echo   Node.js est introuvable dans le PATH.
echo.
echo   Installe-le depuis https://nodejs.org/ puis relance ce fichier.
echo.
pause
exit /b 1
