#Requires -Version 7.0
<#
.SYNOPSIS
    Analyse le resultat d'un run sockseek : rapport d'echecs et playlist M3U.

.DESCRIPTION
    Sockseek tient un index CSV des elements traites. Ce script le relit,
    confronte chaque entree au disque, produit un rapport classant les echecs
    par cause, et genere une playlist M3U des seuls fichiers reellement
    presents.

    La verite vient du disque, pas de l'index : un fichier absent est un echec
    meme si l'index le dit telecharge. L'index ne sert qu'a retrouver la cause.

    Utilisable seul apres un run sockseek manuel.

.PARAMETER IndexPath
    Chemin de l'index sockseek (_index.csv dans le dossier de sortie).

.PARAMETER OutputDir
    Dossier de telechargement, pour resoudre les chemins relatifs.

.PARAMETER SourceCsv
    CSV source produit par Get-SoulseekList.ps1. Permet de reperer les titres
    jamais traites, absents de l'index.

.PARAMETER PlaylistPath
    Chemin de la playlist (defaut: <OutputDir>\playlist.m3u).

.PARAMETER ReportPath
    Chemin du rapport CSV (defaut: <OutputDir>\rapport.csv).

.PARAMETER Relative
    Ecrit des chemins relatifs dans la playlist. Actif par defaut : la
    playlist reste valide si le dossier est deplace ou copie ailleurs.

.EXAMPLE
    .\Build-Playlist.ps1 -OutputDir "D:\Music\techno"

.EXAMPLE
    .\Build-Playlist.ps1 -OutputDir "D:\Music\techno" -SourceCsv playlist-clean.csv
#>

[CmdletBinding()]
param(
    [string] $IndexPath,
    [Parameter(Mandatory)] [string] $OutputDir,
    [string] $SourceCsv,
    [string] $PlaylistPath,
    [string] $ReportPath,
    [bool]   $Relative = $true
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $OutputDir)) {
    throw "Dossier de sortie introuvable : $OutputDir"
}
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

if (-not $PlaylistPath) { $PlaylistPath = Join-Path $OutputDir 'playlist.m3u' }
if (-not $ReportPath)   { $ReportPath   = Join-Path $OutputDir 'rapport.csv' }

# --------------------------------------------------------- lecture index ----
if (-not $IndexPath) {
    $IndexPath = Get-ChildItem -Path $OutputDir -Recurse -File -Filter '_index.csv' `
                     -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
                 ForEach-Object { $_.FullName }
}

$index = @()
if ($IndexPath -and (Test-Path -LiteralPath $IndexPath)) {
    $index = @(Import-Csv -LiteralPath $IndexPath)
    Write-Host "Index : $IndexPath ($($index.Count) entrees)" -ForegroundColor DarkGray
}
else {
    Write-Warning "Aucun index sockseek trouve. La playlist sera construite en"
    Write-Warning "balayant les fichiers audio du dossier, sans detail des echecs."
}

# Les noms de colonnes de l'index ont bouge entre versions : on les retrouve
# par correspondance approximative plutot que de les coder en dur.
function Find-Column {
    param($Row, [string[]] $Candidates)
    if (-not $Row) { return $null }
    $names = $Row.PSObject.Properties.Name
    foreach ($c in $Candidates) {
        $hit = $names | Where-Object { ($_ -replace '[\s_-]', '').ToLower() -eq $c } |
               Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

$first = $index | Select-Object -First 1
$colPath   = Find-Column $first @('filepath', 'path', 'localpath')
$colArtist = Find-Column $first @('artist', 'sartist', 'albumartist')
$colTitle  = Find-Column $first @('title', 'stitle')
$colAlbum  = Find-Column $first @('album', 'salbum')
$colLength = Find-Column $first @('length', 'slength', 'duration')
$colState  = Find-Column $first @('state', 'status')
$colReason = Find-Column $first @('failurereason', 'reason', 'error')

function Get-Val { param($Row, $Col) if ($Col) { $Row.$Col } else { $null } }

# ------------------------------------------------------------ evaluation ----
$results = [System.Collections.Generic.List[object]]::new()

foreach ($row in $index) {
    $rawPath = Get-Val $row $colPath
    $full    = $null

    if (-not [string]::IsNullOrWhiteSpace($rawPath)) {
        $full = if ([IO.Path]::IsPathRooted($rawPath)) { $rawPath }
                else { Join-Path $OutputDir $rawPath }
    }

    $exists = $full -and (Test-Path -LiteralPath $full -PathType Leaf)

    $state  = Get-Val $row $colState
    $reason = Get-Val $row $colReason

    # Classement des echecs par cause, pour savoir quoi corriger.
    $category = if ($exists) { 'Telecharge' }
        elseif ($reason -match '(?i)not.?found|no.?result|introuv') { 'Introuvable sur Soulseek' }
        elseif ($reason -match '(?i)nosuitable|no.?suitable|condition|filter|quality|bitrate|format') { 'Filtre par les conditions' }
        elseif ($reason -match '(?i)timeout|stale|connect|refus|offline') { 'Probleme reseau ou pair injoignable' }
        elseif ($reason -match '(?i)cancel|abort') { 'Annule' }
        elseif ($state  -match '(?i)not.?found') { 'Introuvable sur Soulseek' }
        elseif ($state  -match '(?i)fail|error') { 'Echec (cause non precisee)' }
        elseif ($rawPath) { 'Fichier absent du disque' }
        else { 'Non telecharge' }

    $results.Add([pscustomobject]@{
        Artist   = Get-Val $row $colArtist
        Title    = Get-Val $row $colTitle
        Album    = Get-Val $row $colAlbum
        Length   = Get-Val $row $colLength
        Statut   = $category
        Detail   = if ($reason) { $reason } else { $state }
        Chemin   = if ($exists) { $full } else { '' }
        Reussi   = [bool]$exists
    })
}

# --------------------------------------- titres jamais traites (hors index) --
if ($SourceCsv -and (Test-Path -LiteralPath $SourceCsv)) {
    $seen = @{}
    foreach ($r in $results) {
        $k = "$($r.Artist)|$($r.Title)".ToLower().Trim()
        $seen[$k] = $true
    }
    foreach ($src in (Import-Csv -LiteralPath $SourceCsv)) {
        $k = "$($src.Artist)|$($src.Title)".ToLower().Trim()
        if (-not $seen.ContainsKey($k)) {
            $results.Add([pscustomobject]@{
                Artist = $src.Artist; Title = $src.Title; Album = ''
                Length = $src.Length
                Statut = 'Jamais traite'
                Detail = "Absent de l'index : run interrompu ou entree ignoree"
                Chemin = ''; Reussi = $false
            })
        }
    }
}

# ------------------------- repli : aucun index, on balaye le dossier audio ---
if ($results.Count -eq 0) {
    $audio = '.mp3', '.flac', '.ogg', '.m4a', '.opus', '.wav', '.aac', '.alac'
    Get-ChildItem -Path $OutputDir -Recurse -File |
        Where-Object { $audio -contains $_.Extension.ToLower() } |
        ForEach-Object {
            $results.Add([pscustomobject]@{
                Artist = ''; Title = $_.BaseName; Album = ''; Length = ''
                Statut = 'Telecharge'; Detail = 'Detecte par balayage du dossier'
                Chemin = $_.FullName; Reussi = $true
            })
        }
}

# ---------------------------------------------------------------- playlist --
$ok = @($results | Where-Object { $_.Reussi })

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('#EXTM3U')
$lines.Add("# Genere le $(Get-Date -Format 'yyyy-MM-dd HH:mm') - $($ok.Count) titres")

foreach ($t in $ok) {
    $secs = 0
    if ($t.Length -and [double]::TryParse([string]$t.Length, [ref]$secs) -and $secs -gt 0) {
        $dur = [int]$secs
    } else { $dur = -1 }

    $label = if ($t.Artist -and $t.Title) { "$($t.Artist) - $($t.Title)" }
             elseif ($t.Title)            { $t.Title }
             else                         { [IO.Path]::GetFileNameWithoutExtension($t.Chemin) }

    $p = $t.Chemin
    if ($Relative) {
        $p = [IO.Path]::GetRelativePath($OutputDir, $t.Chemin)
    }

    $lines.Add("#EXTINF:$dur,$label")
    $lines.Add($p)
}

# UTF-8 sans BOM : c'est formellement du M3U8, mais tous les lecteurs
# actuels (VLC, foobar2000, Rekordbox) le lisent sous l'extension .m3u.
$lines | Set-Content -LiteralPath $PlaylistPath -Encoding utf8NoBOM

# ----------------------------------------------------------------- rapport --
$results | Select-Object Artist, Title, Statut, Detail, Chemin |
    Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding utf8NoBOM

# ------------------------------------------------------------------ resume --
$failed = @($results | Where-Object { -not $_.Reussi })
$total  = $results.Count
$pct    = if ($total) { [math]::Round(100 * $ok.Count / $total) } else { 0 }

Write-Host ""
Write-Host "================ RESULTAT ================" -ForegroundColor White
Write-Host "  Telecharges : $($ok.Count) / $total  ($pct %)" `
    -ForegroundColor $(if ($pct -ge 60) { 'Green' } elseif ($pct -ge 30) { 'Yellow' } else { 'Red' })
Write-Host "  Echecs      : $($failed.Count)" -ForegroundColor DarkGray

if ($failed.Count) {
    Write-Host ""
    Write-Host "  Repartition des echecs :" -ForegroundColor Yellow
    $failed | Group-Object Statut | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ("    {0,-38} {1,3}" -f $_.Name, $_.Count)
    }

    Write-Host ""
    Write-Host "  Titres manquants :" -ForegroundColor Yellow
    foreach ($f in ($failed | Sort-Object Statut, Artist)) {
        $lbl = "$($f.Artist) - $($f.Title)".Trim(' -')
        Write-Host ("    {0}" -f $lbl) -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Playlist : $PlaylistPath" -ForegroundColor Green
Write-Host "  Rapport  : $ReportPath"   -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor White

# Code de sortie exploitable en tache planifiee : 0 si tout est passe.
if ($failed.Count -gt 0) { exit 10 } else { exit 0 }
