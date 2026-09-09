#Requires -Version 7.0
<#
.SYNOPSIS
    Reprend en une seule passe tous les titres manquants des playlists deja
    traitees.

.DESCRIPTION
    Sockseek travaille sur un reseau P2P : un morceau introuvable un jour peut
    apparaitre le lendemain, simplement parce que le pair qui le partage s'est
    reconnecte. Relancer plus tard rattrape une partie des echecs sans rien
    changer aux reglages.

    Ce script relit le catalogue des playlists deja amorcees, recalcule pour
    chacune ce qui manque, fusionne le tout en une liste dedoublonnee, et
    lance sockseek une fois par dossier de destination. Il regenere ensuite
    les playlists M3U et les rapports concernes.

    Un seul passage groupe, plutot qu'une relance par playlist : le serveur
    Soulseek bannit 30 minutes si les recherches s'enchainent trop vite, donc
    mieux vaut un flux unique et regulier.

.PARAMETER List
    Affiche le catalogue et l'etat de chaque playlist, sans rien relancer.

.PARAMETER Only
    Ne reprend que les playlists dont l'URL ou le nom contient ce texte.

.PARAMETER DryRun
    Montre ce qui serait relance, sans lancer sockseek.

.PARAMETER Forget
    Retire du catalogue les playlists correspondant a -Only.

.PARAMETER SockseekPath
    Chemin de sockseek.exe s'il n'est pas dans le PATH.

.EXAMPLE
    .\Resume-Downloads.ps1 -List

.EXAMPLE
    .\Resume-Downloads.ps1

.EXAMPLE
    .\Resume-Downloads.ps1 -Only "sans-retour" -DryRun
#>

[CmdletBinding()]
param(
    [switch] $List,
    [string] $Only,
    [switch] $DryRun,
    [switch] $Forget,
    [string] $SockseekPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'SockseekLib.ps1')

$entries = @(Read-Catalogue)

if ($entries.Count -eq 0) {
    Write-Host ""
    Write-Host "Le catalogue est vide." -ForegroundColor Yellow
    Write-Host "Il se remplit tout seul a chaque run de Get-SoulseekList.ps1 -Download."
    Write-Host "Catalogue : $(Get-CataloguePath)" -ForegroundColor DarkGray
    exit 0
}

if ($Only) {
    $entries = @($entries | Where-Object { $_.Url -like "*$Only*" -or $_.Name -like "*$Only*" })
    if ($entries.Count -eq 0) {
        Write-Warning "Aucune playlist ne correspond a '$Only'."
        exit 1
    }
}

# ------------------------------------------------------------------ oubli ---
if ($Forget) {
    if (-not $Only) {
        Write-Warning "-Forget exige -Only, pour ne pas vider le catalogue par accident."
        exit 1
    }
    $all  = @(Read-Catalogue)
    $urls = $entries.Url
    Save-Catalogue @($all | Where-Object { $urls -notcontains $_.Url })
    Write-Host "$($entries.Count) entree(s) retiree(s) du catalogue." -ForegroundColor Green
    Write-Host "Les fichiers deja telecharges ne sont pas touches." -ForegroundColor DarkGray
    exit 0
}

# --------------------------------------------------------------- etat des lieux
Write-Host ""
Write-Host "Catalogue : $(Get-CataloguePath)" -ForegroundColor DarkGray
Write-Host ""

$state = [System.Collections.Generic.List[object]]::new()

foreach ($e in $entries) {
    $pending = @(Get-PlaylistPending -Entry $e)
    $state.Add([pscustomobject]@{
        Entry   = $e
        Pending = $pending
    })
}

$state | ForEach-Object {
    $e = $_.Entry
    $done = [int]$e.Total - $_.Pending.Count
    if ($done -lt 0) { $done = [int]$e.Ok }
    [pscustomobject]@{
        Playlist  = $e.Name
        Manquants = $_.Pending.Count
        Recuperes = $done
        Runs      = $e.RunCount
        'Dernier essai' = if ($e.LastRun) { ([datetime]$e.LastRun).ToString('yyyy-MM-dd HH:mm') } else { '' }
        Dossier   = $e.OutputDir
    }
} | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($List) {
    Write-Host "Pour relancer les titres manquants : .\Resume-Downloads.ps1" -ForegroundColor Cyan
    exit 0
}

# ------------------------------------------------- regroupement par dossier --
$todo = @($state | Where-Object { $_.Pending.Count -gt 0 })

if ($todo.Count -eq 0) {
    Write-Host "Rien a reprendre : toutes les playlists sont completes." -ForegroundColor Green
    exit 0
}

# Un meme morceau peut manquer dans plusieurs playlists partageant un dossier.
# On ne le cherche qu'une fois.
$byDir = @{}
foreach ($s in $todo) {
    $dir = $s.Entry.OutputDir
    if (-not $byDir.ContainsKey($dir)) { $byDir[$dir] = @{} }
    foreach ($p in $s.Pending) {
        $key = "$($p.Artist)|$($p.Title)".ToLower().Trim()
        if (-not $byDir[$dir].ContainsKey($key)) {
            $byDir[$dir][$key] = [pscustomobject]@{
                Artist = $p.Artist; Title = $p.Title; Length = $p.Length
            }
        }
    }
}

$grandTotal = ($byDir.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
$minutes = [math]::Ceiling($grandTotal / 34.0) * 220 / 60

Write-Host "$grandTotal titre(s) a reprendre, repartis sur $($byDir.Count) dossier(s)." -ForegroundColor Cyan
Write-Host "Duree minimale estimee : $([math]::Round($minutes)) minutes (limite de recherches Soulseek)." -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host ""
    foreach ($dir in $byDir.Keys) {
        Write-Host "  $dir" -ForegroundColor White
        foreach ($t in $byDir[$dir].Values) {
            Write-Host "    $($t.Artist) - $($t.Title)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "-DryRun : rien n'a ete lance." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------- sockseek ---
$exe = $null
if ($SockseekPath) {
    if (-not (Test-Path -LiteralPath $SockseekPath)) {
        throw "Executable introuvable : $SockseekPath"
    }
    $exe = (Resolve-Path -LiteralPath $SockseekPath).Path
}
else {
    foreach ($n in 'sockseek', 'sldl') {
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($c) { $exe = $c.Source; break }
    }
    if (-not $exe) {
        $f = Get-ChildItem -Path $PSScriptRoot -Recurse -Depth 2 -File `
                 -Include 'sockseek.exe', 'sldl.exe', 'sockseek', 'sldl' `
                 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $exe = $f.FullName }
    }
}
if (-not $exe) {
    throw "sockseek introuvable. Passe -SockseekPath, ou relance installer.bat."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

foreach ($dir in $byDir.Keys) {
    $tracks = @($byDir[$dir].Values)

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor White
    Write-Host " $dir  --  $($tracks.Count) titre(s)" -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor White

    $retryCsv = Join-Path $dir "reprise-$stamp.csv"
    $tracks | Select-Object Artist, Title, Length |
        Export-Csv -LiteralPath $retryCsv -NoTypeInformation -Encoding utf8NoBOM

    $idxPath = Join-Path $dir '_index.csv'
    $logPath = Join-Path $dir "sockseek-reprise-$stamp.log"

    $sockArgs = @(
        $retryCsv
        '--index-path', $idxPath
        '--log-file', $logPath
        '--song'
        '--artist-maybe-wrong'
        '--length-tol', '10'
        '--pref-format', 'flac,wav'
        '--remove-ft'
        '--name-format', '{artist( - )title|filename}'
        '--output-dir', $dir
    )

    & $exe @sockArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "sockseek a rendu le code $LASTEXITCODE. Journal : $logPath"
    }

    Remove-Item -LiteralPath $retryCsv -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------ regeneration rapports/playlists --
Write-Host ""
Write-Host "Mise a jour des playlists et des rapports..." -ForegroundColor Cyan

$catalogue = @(Read-Catalogue)
$gagnes = 0

foreach ($s in $todo) {
    $e = $s.Entry
    $before = $s.Pending.Count

    $idx = if ($e.IndexPath -and (Test-Path -LiteralPath $e.IndexPath)) { $e.IndexPath }
           else { Join-Path $e.OutputDir '_index.csv' }
    $src = if ($e.SourceCsv -and (Test-Path -LiteralPath $e.SourceCsv)) { $e.SourceCsv } else { $null }

    $res = Get-RunResults -IndexPath $idx -OutputDir $e.OutputDir -SourceCsv $src
    $ok  = @($res | Where-Object { $_.Reussi })
    $after = @($res | Where-Object { -not $_.Reussi }).Count
    $gagnes += ($before - $after)

    Write-M3UPlaylist -Results $res -OutputDir $e.OutputDir `
        -PlaylistPath (Join-Path $e.OutputDir 'playlist.m3u') | Out-Null

    $res | Select-Object Artist, Title, Statut, Detail, Chemin |
        Export-Csv -LiteralPath (Join-Path $e.OutputDir 'rapport.csv') `
                   -NoTypeInformation -Encoding utf8NoBOM

    $entry = $catalogue | Where-Object { $_.Url -eq $e.Url } | Select-Object -First 1
    if ($entry) {
        $entry.LastRun  = (Get-Date).ToString('s')
        $entry.RunCount = [int]$entry.RunCount + 1
        $entry.Total    = @($res).Count
        $entry.Ok       = $ok.Count
    }

    $gain = $before - $after
    $couleur = if ($gain -gt 0) { 'Green' } else { 'DarkGray' }
    Write-Host ("  {0,-40} {1,3} recuperes, {2,3} restants" -f `
        $e.Name, $gain, $after) -ForegroundColor $couleur
}

Save-Catalogue $catalogue

Write-Host ""
if ($gagnes -gt 0) {
    Write-Host "$gagnes titre(s) recupere(s) sur cette reprise." -ForegroundColor Green
}
else {
    Write-Host "Aucun titre supplementaire cette fois." -ForegroundColor Yellow
    Write-Host "Sur du P2P c'est normal : reessaie dans quelques jours, a une" -ForegroundColor DarkGray
    Write-Host "heure ou davantage de pairs sont connectes." -ForegroundColor DarkGray
}

exit 0
