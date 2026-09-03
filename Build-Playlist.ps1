#Requires -Version 7.0
<#
.SYNOPSIS
    Analyse le resultat d'un run sockseek : rapport d'echecs et playlist M3U.

.DESCRIPTION
    Relit l'index sockseek, le confronte au disque, classe les echecs par
    cause, ecrit un rapport CSV et une playlist M3U des fichiers reellement
    presents.

    La verite vient du disque, pas de l'index : un fichier absent est un echec
    meme si l'index le dit telecharge.

    Utilisable seul apres un run sockseek manuel.

.PARAMETER IndexPath
    Index sockseek. Trouve automatiquement dans OutputDir s'il est omis.

.PARAMETER OutputDir
    Dossier de telechargement.

.PARAMETER SourceCsv
    CSV produit par Get-SoulseekList.ps1, pour reperer les titres jamais traites.

.PARAMETER Register
    URL de la playlist : enregistre ou met a jour l'entree correspondante dans
    le catalogue de reprise.

.EXAMPLE
    .\Build-Playlist.ps1 -OutputDir "D:\Music\techno"
#>

[CmdletBinding()]
param(
    [string] $IndexPath,
    [Parameter(Mandatory)] [string] $OutputDir,
    [string] $SourceCsv,
    [string] $PlaylistPath,
    [string] $ReportPath,
    [string] $Register,
    [bool]   $Relative = $true
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'SockseekLib.ps1')

if (-not (Test-Path -LiteralPath $OutputDir)) {
    throw "Dossier de sortie introuvable : $OutputDir"
}
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

if (-not $PlaylistPath) { $PlaylistPath = Join-Path $OutputDir 'playlist.m3u' }
if (-not $ReportPath)   { $ReportPath   = Join-Path $OutputDir 'rapport.csv' }

if (-not $IndexPath) {
    $IndexPath = Get-ChildItem -Path $OutputDir -Recurse -File -Filter '_index.csv' `
                     -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
                 ForEach-Object { $_.FullName }
}

if ($IndexPath -and (Test-Path -LiteralPath $IndexPath)) {
    Write-Host "Index : $IndexPath" -ForegroundColor DarkGray
}
else {
    Write-Warning "Aucun index sockseek trouve. La playlist sera construite en"
    Write-Warning "balayant les fichiers audio du dossier, sans detail des echecs."
}

$results = Get-RunResults -IndexPath $IndexPath -OutputDir $OutputDir -SourceCsv $SourceCsv

Write-M3UPlaylist -Results $results -OutputDir $OutputDir `
                  -PlaylistPath $PlaylistPath -Relative $Relative | Out-Null

$results | Select-Object Artist, Title, Statut, Detail, Chemin |
    Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding utf8NoBOM

Show-RunSummary -Results $results

Write-Host ""
Write-Host "  Playlist : $PlaylistPath" -ForegroundColor Green
Write-Host "  Rapport  : $ReportPath"   -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor White

if ($Register -and $SourceCsv) {
    $ok = @($results | Where-Object { $_.Reussi }).Count
    Register-Playlist -Url $Register -OutputDir $OutputDir -SourceCsv $SourceCsv `
                      -IndexPath $IndexPath -Total @($results).Count -Ok $ok
    Write-Host "  Catalogue mis a jour : reprise possible via Resume-Downloads.ps1" -ForegroundColor DarkGray
}

$failed = @($results | Where-Object { -not $_.Reussi })
if ($failed.Count -gt 0) { exit 10 } else { exit 0 }
