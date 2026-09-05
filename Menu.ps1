#Requires -Version 7.0
<#
.SYNOPSIS
    Menu interactif du kit sockseek : nouvelle playlist, reprise, etat.

.DESCRIPTION
    Equivalent PowerShell de lancer.bat -- memes actions, meme navigation
    (retour au menu principal ou menu de reprise, sortie explicite), mais
    sans les pieges de scripting batch (un `set /p` sur reponse vide garde
    l'ancienne valeur au lieu de la vider, echappement des guillemets, etc.)

    Get-SoulseekList.ps1 et Resume-Downloads.ps1 appellent `exit` a plusieurs
    endroits : ils sont donc toujours lances dans un processus pwsh separe
    (comme le ferait lancer.bat), jamais dot-sources ou appeles directement
    dans ce process -- un `exit` a l'interieur terminerait sinon ce menu.

.PARAMETER Url
    URL passee directement : saute le menu principal et va droit au choix
    du mode de traitement, comme `lancer.bat <url>`.

.EXAMPLE
    .\Menu.ps1

.EXAMPLE
    .\Menu.ps1 -Url "https://soundcloud.com/loleanto/sets/sans-retour-short"
#>

[CmdletBinding()]
param(
    [string] $Url
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'SockseekLib.ps1')

$pwshExe       = (Get-Process -Id $PID).Path
$getListScript = Join-Path $PSScriptRoot 'Get-SoulseekList.ps1'
$resumeScript  = Join-Path $PSScriptRoot 'Resume-Downloads.ps1'

function Read-Line {
    <# Read-Host renvoie $null en cas de fin de flux reelle sur l'entree
       standard (entree redirigee depuis un fichier vide, pipe ferme,
       lancement non interactif) -- distinct d'une simple touche Entree, qui
       renvoie une chaine vide. Sans ce garde-fou, une invite qui reboucle
       sur elle-meme (comme celles de ce menu) tournerait indefiniment. #>
    param([Parameter(Mandatory)] [string] $Prompt)
    $answer = Read-Host -Prompt $Prompt
    if ($null -eq $answer) {
        Write-Host ''
        Write-Host "Entree indisponible (flux ferme) : sortie." -ForegroundColor Yellow
        exit 1
    }
    return $answer
}

function Read-MenuChoice {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [string] $Default
    )
    $answer = Read-Line "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Invoke-KitScript {
    <# Lance un script du kit dans un nouveau processus pwsh et renvoie son
       code de sortie. Voir la remarque sur `exit` dans la description. #>
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [string[]] $ScriptArgs = @()
    )
    & $pwshExe -NoProfile -File $ScriptPath @ScriptArgs | Out-Host
    return $LASTEXITCODE
}

$code  = 0
$state = if ($Url) { 'AskMode' } else { 'Menu' }

while ($state -ne 'Quit') {
    switch ($state) {

        'Menu' {
            Clear-Host
            Write-Host '================================================================'
            Write-Host ' Kit sockseek'
            Write-Host '================================================================'
            Write-Host ''
            Write-Host '  [1] Traiter une nouvelle playlist'
            Write-Host '  [2] Reprendre les titres manquants'
            Write-Host "  [3] Voir l'etat des playlists deja traitees"
            Write-Host '  [4] Quitter'
            Write-Host ''
            switch (Read-MenuChoice 'Choix' '1') {
                '1'     { $state = 'AskUrl' }
                '2'     { $state = 'ResumeMenu' }
                '3'     { $state = 'Etat' }
                '4'     { $state = 'Quit' }
                default {
                    Write-Host ''
                    Write-Host '  Choix invalide.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
        }

        # =========================================== nouvelle playlist ====
        'AskUrl' {
            Write-Host ''
            Write-Host "Colle l'URL de la playlist SoundCloud ou YouTube."
            Write-Host ''
            $Url = Read-Line 'URL'
            if ([string]::IsNullOrWhiteSpace($Url)) {
                Write-Host ''
                Write-Host '  Aucune URL saisie, rien a faire.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                $state = 'Menu'
            }
            else {
                $state = 'AskMode'
            }
        }

        'AskMode' {
            Write-Host ''
            Write-Host "URL : `"$Url`""
            Write-Host ''
            Write-Host 'Que veux-tu faire ?'
            Write-Host ''
            Write-Host "  [1] Tester d'abord : cherche sur Soulseek, ne telecharge rien"
            Write-Host '  [2] Telecharger pour de vrai'
            Write-Host "  [3] Extraire et nettoyer la liste seulement, sans toucher a Soulseek"
            Write-Host ''
            $choix = Read-MenuChoice 'Choix' '1'

            $modeArgs = switch ($choix) {
                '1'     { , @('-Download', '-PrintOnly') }
                '2'     { , @('-Download') }
                '3'     { , @() }
                default { $null }
            }
            if ($null -eq $modeArgs) {
                Write-Host ''
                Write-Host '  Choix invalide.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                continue   # redemande sur AskMode, l'URL est deja connue
            }

            $destArgs = @()
            if ($choix -ne '3') {
                $currentDest = Get-DefaultOutputDir
                Write-Host ''
                Write-Host "Dossier de destination actuel : `"$currentDest`""
                Write-Host 'Laisse vide pour le conserver, ou tape un nouveau chemin pour le'
                Write-Host 'remplacer (il devient le defaut pour les prochaines fois) :'
                $dest = Read-Line 'Dossier'
                if (-not [string]::IsNullOrWhiteSpace($dest)) {
                    $destArgs = @('-OutputDir', $dest)
                }
            }

            Write-Host ''
            Write-Host '----------------------------------------------------------------'
            Write-Host ''

            $code = Invoke-KitScript -ScriptPath $getListScript `
                        -ScriptArgs (@('-Url', $Url) + $modeArgs + $destArgs)

            Write-Host ''
            Write-Host '----------------------------------------------------------------'
            switch ($code) {
                0  { Write-Host 'Termine sans echec.' -ForegroundColor Green }
                10 {
                    Write-Host "Termine, mais certains titres n'ont pas ete recuperes." -ForegroundColor Yellow
                    Write-Host 'Le detail est dans rapport.csv, dans le sous-dossier de la playlist'
                    Write-Host '(a l''interieur du dossier de destination).'
                    Write-Host ''
                    Write-Host "Sur un reseau P2P, reessayer plus tard suffit souvent : le pair"
                    Write-Host 'qui partage le morceau doit simplement etre connecte. Choisis'
                    Write-Host '"Reprendre les titres manquants" dans le menu principal.'
                }
                default { Write-Host "Termine avec le code $code. Relis les messages ci-dessus." -ForegroundColor Red }
            }
            $state = 'PostAction'
        }

        # ================================================== reprise =======
        # Resume-Downloads.ps1 ne filtre que par PLAYLIST (-Only), pas titre
        # par titre : "une playlist en particulier" est donc la plus fine
        # granularite disponible.
        'ResumeMenu' {
            Write-Host ''
            Write-Host '----------------------------------------------------------------'
            Write-Host ' Reprise des titres manquants'
            Write-Host '----------------------------------------------------------------'
            Write-Host ''
            Write-Host "Un morceau introuvable un jour peut apparaitre le lendemain : il"
            Write-Host "suffit que le pair qui le partage se reconnecte. L'etat actuel :"
            Write-Host ''

            Invoke-KitScript -ScriptPath $resumeScript -ScriptArgs @('-List') | Out-Null

            Write-Host ''
            Write-Host 'Que veux-tu reprendre ?'
            Write-Host ''
            Write-Host '  [1] Voir d''abord la liste des titres qui seraient repris (test, rien de relance)'
            Write-Host '  [2] Tous les morceaux manquants, toutes playlists confondues'
            Write-Host '  [3] Une playlist en particulier'
            Write-Host '  [4] Retour au menu principal'
            Write-Host '  [5] Quitter'
            Write-Host ''
            switch (Read-MenuChoice 'Choix' '1') {
                '1'     { $state = 'ResumeDryRunAll' }
                '2'     { $state = 'ResumeRunAll' }
                '3'     { $state = 'ResumeAskPlaylist' }
                '4'     { $state = 'Menu' }
                '5'     { $state = 'Quit' }
                default {
                    Write-Host ''
                    Write-Host '  Choix invalide.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
        }

        'ResumeDryRunAll' {
            Write-Host ''
            Write-Host '----------------------------------------------------------------'
            Write-Host ''
            Invoke-KitScript -ScriptPath $resumeScript -ScriptArgs @('-DryRun') | Out-Null

            Write-Host ''
            Write-Host 'Que veux-tu faire maintenant ?'
            Write-Host ''
            Write-Host '  [1] Reprendre tous ces titres pour de vrai'
            Write-Host '  [2] Reprendre une playlist en particulier plutot'
            Write-Host '  [3] Retour au menu de reprise'
            Write-Host '  [4] Retour au menu principal'
            Write-Host '  [5] Quitter'
            Write-Host ''
            switch (Read-MenuChoice 'Choix' '3') {
                '1'     { $state = 'ResumeRunAll' }
                '2'     { $state = 'ResumeAskPlaylist' }
                '3'     { $state = 'ResumeMenu' }
                '4'     { $state = 'Menu' }
                '5'     { $state = 'Quit' }
                default {
                    Write-Host ''
                    Write-Host '  Choix invalide.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
        }

        'ResumeRunAll' {
            Write-Host ''
            Write-Host '----------------------------------------------------------------'
            Write-Host ''
            $code  = Invoke-KitScript -ScriptPath $resumeScript
            $state = 'PostAction'
        }

        'ResumeAskPlaylist' {
            Write-Host ''
            Write-Host 'Nom (ou fragment du nom) de la playlist a reprendre, tel qu''affiche'
            Write-Host 'dans la colonne "Playlist" ci-dessus :'
            Write-Host ''
            $plname = Read-Line 'Playlist'
            if ([string]::IsNullOrWhiteSpace($plname)) {
                $state = 'ResumeMenu'
                continue
            }

            Write-Host ''
            Write-Host "  [1] Tester d'abord : voir ce qui serait repris pour cette playlist"
            Write-Host '  [2] Reprendre cette playlist pour de vrai'
            Write-Host ''
            $ochoice = Read-MenuChoice 'Choix' '1'

            if ($ochoice -eq '2') {
                Write-Host ''
                Write-Host '----------------------------------------------------------------'
                Write-Host ''
                $code  = Invoke-KitScript -ScriptPath $resumeScript -ScriptArgs @('-Only', $plname)
                $state = 'PostAction'
                continue
            }
            if ($ochoice -ne '1') {
                Write-Host ''
                Write-Host '  Choix invalide.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                continue   # redemande le nom de playlist
            }

            Write-Host ''
            Write-Host '----------------------------------------------------------------'
            Write-Host ''
            Invoke-KitScript -ScriptPath $resumeScript -ScriptArgs @('-Only', $plname, '-DryRun') | Out-Null

            Write-Host ''
            Write-Host 'Que veux-tu faire maintenant ?'
            Write-Host ''
            Write-Host '  [1] Reprendre cette playlist pour de vrai'
            Write-Host '  [2] Retour au menu de reprise'
            Write-Host '  [3] Retour au menu principal'
            Write-Host '  [4] Quitter'
            Write-Host ''
            switch (Read-MenuChoice 'Choix' '2') {
                '1' {
                    Write-Host ''
                    Write-Host '----------------------------------------------------------------'
                    Write-Host ''
                    $code  = Invoke-KitScript -ScriptPath $resumeScript -ScriptArgs @('-Only', $plname)
                    $state = 'PostAction'
                }
                '2'     { $state = 'ResumeMenu' }
                '3'     { $state = 'Menu' }
                '4'     { $state = 'Quit' }
                default {
                    Write-Host ''
                    Write-Host '  Choix invalide.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    $state = 'ResumeMenu'
                }
            }
        }

        # ===================================================== etat =======
        'Etat' {
            Write-Host ''
            $code  = Invoke-KitScript -ScriptPath $resumeScript -ScriptArgs @('-List')
            $state = 'PostAction'
        }

        # ======================================== retour ou sortie ========
        'PostAction' {
            Write-Host ''
            Write-Host '----------------------------------------------------------------'
            Write-Host '  [1] Retour au menu principal'
            Write-Host '  [2] Quitter'
            Write-Host ''
            switch (Read-MenuChoice 'Choix' '1') {
                '1'     { $state = 'Menu' }
                '2'     { $state = 'Quit' }
                default {
                    Write-Host ''
                    Write-Host '  Choix invalide.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
        }
    }
}

exit $code
