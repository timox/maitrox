#Requires -Version 7.0
<#
    Tests Pester pour les fonctions de SockseekLib.ps1 : nettoyage
    (Normalize-Text, Clean-Title, Convert-Entry) et analyse des resultats
    de run (Get-RunResults).

    Lancement :
        Invoke-Pester .\tests\SockseekLib.Tests.ps1

    Necessite le module Pester (v5+) :
        Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'SockseekLib.ps1')

    function New-Entry {
        param(
            [string] $Artist,
            [string] $Uploader,
            [string] $Track,
            [string] $Title,
            $Duration = 240,
            [string] $Url = 'https://example.invalid/track'
        )
        [pscustomobject]@{
            artist      = $Artist
            uploader    = $Uploader
            track       = $Track
            title       = $Title
            duration    = $Duration
            webpage_url = $Url
        }
    }
}

Describe 'Clean-Title' {

    It 'retire un prefixe de premiere avec deux-points' {
        (Clean-Title 'BCCO Premiere: Mislaw - Fourth Siren [THEIA001]').Text |
            Should -Be 'Mislaw - Fourth Siren'
    }

    It 'retire un prefixe de premiere avec barre verticale' {
        (Clean-Title 'PW PREMIERE | Artist - Track').Text | Should -Be 'Artist - Track'
    }

    It 'retire un prefixe de premiere avec tiret' {
        (Clean-Title 'PREMIERE - Artist - Track').Text | Should -Be 'Artist - Track'
    }

    It 'retire (Original Mix)' {
        (Clean-Title 'Artist - Track (Original Mix)').Text | Should -Be 'Artist - Track'
    }

    It 'conserve les noms de remix' {
        (Clean-Title 'Artist - Track (Kr!z Remix)').Text | Should -Be 'Artist - Track (Kr!z Remix)'
    }

    It 'retire les codes catalogue entre crochets en fin de titre' {
        (Clean-Title 'Artist - Track [TAR034]').Text | Should -Be 'Artist - Track'
    }

    It 'retire plusieurs blocs entre crochets enchaines' {
        (Clean-Title 'Artist - Track [FREE DL] [TAR034]').Text | Should -Be 'Artist - Track'
    }

    It 'retire un code catalogue entre parentheses' {
        (Clean-Title 'Artist - Track (TAR034)').Text | Should -Be 'Artist - Track'
    }

    It 'retire une position vinyle en tete' {
        (Clean-Title 'A2 Deluka - Track').Text | Should -Be 'Deluka - Track'
    }

    It 'retire un suffixe ", by Artiste"' {
        (Clean-Title 'Track Name, by Someone').Text | Should -Be 'Track Name'
    }

    It 'retire une mention de telechargement libre' {
        (Clean-Title 'Artist - Track (Free Download)').Text | Should -Be 'Artist - Track'
    }

    It 'detecte un titre tronque et retire le fragment' {
        $result = Clean-Title 'Artist - Track [ORE...'
        $result.Truncated | Should -BeTrue
        $result.Text | Should -Be 'Artist - Track'
    }

    It "ne marque pas tronque un titre complet" {
        (Clean-Title 'Artist - Track').Truncated | Should -BeFalse
    }
}

Describe 'Normalize-Text' {
    It 'reduit les espaces multiples et trim' {
        Normalize-Text '  Artist   -   Track  ' | Should -Be 'Artist - Track'
    }

    It 'renvoie une chaine vide pour une entree vide ou nulle' {
        Normalize-Text '' | Should -Be ''
        Normalize-Text $null | Should -Be ''
    }
}

Describe 'Convert-Entry' {

    It 'utilise les metadonnees quand artist et track sont renseignes' {
        $entry = New-Entry -Artist 'Mislaw' -Uploader 'BCCO' -Track 'Fourth Siren' `
                            -Title 'BCCO Premiere: Mislaw - Fourth Siren [THEIA001]'
        $result = Convert-Entry $entry
        $result.Artist | Should -Be 'Mislaw'
        $result.Title  | Should -Be 'Fourth Siren'
        $result.Review | Should -Match 'metadonnees'
    }

    It 'extrait artiste et titre depuis le titre nettoye sans metadonnees' {
        $entry = New-Entry -Artist '' -Uploader 'SomeLabel' -Track '' `
                            -Title 'Artist - Track (Original Mix)'
        $result = Convert-Entry $entry
        $result.Artist | Should -Be 'Artist'
        $result.Title  | Should -Be 'Track'
    }

    It 'gere le tiret colle apres le nom d''artiste' {
        $entry = New-Entry -Artist 'ANNE' -Uploader 'ANNE' -Track '' `
                            -Title 'ANNE- Gentle Loop'
        $result = Convert-Entry $entry
        $result.Artist | Should -Be 'ANNE'
        $result.Title  | Should -Be 'Gentle Loop'
    }

    It "retombe sur le nom de la chaine quand aucun artiste n'est identifiable" {
        $entry = New-Entry -Artist '' -Uploader 'RandomChannel' -Track '' -Title 'Untitled Track'
        $result = Convert-Entry $entry
        $result.Artist | Should -Be 'RandomChannel'
        $result.Review | Should -Match 'artiste=chaine'
    }

    It 'signale un titre tronque' {
        $entry = New-Entry -Artist '' -Uploader 'Label' -Track '' -Title 'Artist - Track [ORE...'
        $result = Convert-Entry $entry
        $result.Review | Should -Match 'TRONQUE'
    }

    It "signale ce qui n'est pas un morceau" {
        $entry = New-Entry -Artist '' -Uploader 'Label' -Track '' -Title 'Ableton Demo Song'
        $result = Convert-Entry $entry
        $result.Review | Should -Match 'PAS_UN_MORCEAU'
    }

    It 'convertit la duree en secondes entieres' {
        $entry = New-Entry -Artist 'A' -Uploader 'U' -Track 'T' -Title 'A - T' -Duration 245.7
        (Convert-Entry $entry).Length | Should -Be 245
    }
}

Describe 'Get-RunResults' {
    <#
    sockseek 3.x ecrit "state" et "failurereason" dans _index.csv comme des
    codes numeriques d'enum (JobStateOld / JobFailureReason cote sockseek),
    pas du texte. Verifie avec le vrai binaire sockseek 3.0.5 (--mock-files-dir) :
    un titre introuvable donne "state=2,failurereason=9", et --print index-failed
    confirme que 9 = NoSearchResults. Ces tests figent ce format pour eviter que
    la classification retombe silencieusement sur "Non telecharge" pour tout.
    #>

    BeforeAll {
        $script:testDir = Join-Path ([IO.Path]::GetTempPath()) "sockseek-test-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'categorise NoSearchResults (9) comme Introuvable sur Soulseek' {
        $idx = Join-Path $testDir 'idx1.csv'
        @'
filepath,artist,album,title,length,tracktype,state,failurereason
,K-H1,,Krasnota,340,0,2,9
'@ | Set-Content -LiteralPath $idx -Encoding utf8NoBOM

        $results = Get-RunResults -IndexPath $idx -OutputDir $testDir
        $results[0].Statut | Should -Be 'Introuvable sur Soulseek'
        $results[0].Detail | Should -Be 'NoSearchResults'
        $results[0].Reussi | Should -BeFalse
    }

    It 'categorise NoMatchingResults (10) comme Filtre par les conditions' {
        $idx = Join-Path $testDir 'idx2.csv'
        @'
filepath,artist,album,title,length,tracktype,state,failurereason
,Artist,,Title,300,0,2,10
'@ | Set-Content -LiteralPath $idx -Encoding utf8NoBOM

        (Get-RunResults -IndexPath $idx -OutputDir $testDir)[0].Statut | Should -Be 'Filtre par les conditions'
    }

    It 'categorise Cancelled (7) comme Annule' {
        $idx = Join-Path $testDir 'idx3.csv'
        @'
filepath,artist,album,title,length,tracktype,state,failurereason
,Artist,,Title,300,0,2,7
'@ | Set-Content -LiteralPath $idx -Encoding utf8NoBOM

        (Get-RunResults -IndexPath $idx -OutputDir $testDir)[0].Statut | Should -Be 'Annule'
    }

    It 'un fichier present sur le disque est reussi meme sans filepath renseigne au bon format' {
        $sub = Join-Path $testDir 'sub'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $sub 'Artist - Title.mp3') -Force | Out-Null

        $idx = Join-Path $testDir 'idx4.csv'
        @'
filepath,artist,album,title,length,tracktype,state,failurereason
sub/Artist - Title.mp3,Artist,,Title,300,0,1,0
'@ | Set-Content -LiteralPath $idx -Encoding utf8NoBOM

        $result = Get-RunResults -IndexPath $idx -OutputDir $testDir
        $result[0].Statut | Should -Be 'Telecharge'
        $result[0].Reussi | Should -BeTrue
    }

    It "la verite vient du disque : un index optimiste sans fichier reel est un echec" {
        $idx = Join-Path $testDir 'idx5.csv'
        @'
filepath,artist,album,title,length,tracktype,state,failurereason
manquant/Artist - Title.mp3,Artist,,Title,300,0,1,0
'@ | Set-Content -LiteralPath $idx -Encoding utf8NoBOM

        $result = Get-RunResults -IndexPath $idx -OutputDir $testDir
        $result[0].Reussi | Should -BeFalse
        $result[0].Statut | Should -Be 'Fichier absent du disque'
    }
}
