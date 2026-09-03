#Requires -Version 7.0
<#
    Fonctions partagees par Build-Playlist.ps1, Get-SoulseekList.ps1 et
    Resume-Downloads.ps1. Ce fichier ne fait rien seul : il se charge par
    point-sourcing.

        . (Join-Path $PSScriptRoot 'SockseekLib.ps1')
#>

# ============================================================ ANALYSE ========

function Find-IndexColumn {
    <# Les noms de colonnes de l'index sockseek ont bouge entre versions.
       On les retrouve par correspondance approximative. #>
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

function Get-RunResults {
    <#
    .SYNOPSIS
        Confronte l'index sockseek au contenu reel du disque.

    .DESCRIPTION
        La verite vient du disque : un fichier absent est un echec meme si
        l'index le declare telecharge. L'index ne sert qu'a retrouver la cause.
        Retourne un objet par titre, avec un booleen Reussi et une categorie
        d'echec exploitable.
    #>
    param(
        [string] $IndexPath,
        [Parameter(Mandatory)] [string] $OutputDir,
        [string] $SourceCsv
    )

    $results = [System.Collections.Generic.List[object]]::new()

    $index = @()
    if ($IndexPath -and (Test-Path -LiteralPath $IndexPath)) {
        $index = @(Import-Csv -LiteralPath $IndexPath)
    }

    $first     = $index | Select-Object -First 1
    $colPath   = Find-IndexColumn $first @('filepath', 'path', 'localpath')
    $colArtist = Find-IndexColumn $first @('artist', 'sartist', 'albumartist')
    $colTitle  = Find-IndexColumn $first @('title', 'stitle')
    $colAlbum  = Find-IndexColumn $first @('album', 'salbum')
    $colLength = Find-IndexColumn $first @('length', 'slength', 'duration')
    $colState  = Find-IndexColumn $first @('state', 'status')
    $colReason = Find-IndexColumn $first @('failurereason', 'reason', 'error')

    function local:Val { param($Row, $Col) if ($Col) { $Row.$Col } else { $null } }

    foreach ($row in $index) {
        $rawPath = local:Val $row $colPath
        $full = $null
        if (-not [string]::IsNullOrWhiteSpace($rawPath)) {
            $full = if ([IO.Path]::IsPathRooted($rawPath)) { $rawPath }
                    else { Join-Path $OutputDir $rawPath }
        }
        $exists = $full -and (Test-Path -LiteralPath $full -PathType Leaf)

        $state  = local:Val $row $colState
        $reason = local:Val $row $colReason

        $category =
            if ($exists) { 'Telecharge' }
            elseif ($reason -match '(?i)not.?found|no.?result|introuv') { 'Introuvable sur Soulseek' }
            elseif ($reason -match '(?i)nosuitable|no.?suitable|condition|filter|quality|bitrate|format') { 'Filtre par les conditions' }
            elseif ($reason -match '(?i)timeout|stale|connect|refus|offline') { 'Probleme reseau ou pair injoignable' }
            elseif ($reason -match '(?i)cancel|abort') { 'Annule' }
            elseif ($state  -match '(?i)not.?found') { 'Introuvable sur Soulseek' }
            elseif ($state  -match '(?i)fail|error')  { 'Echec (cause non precisee)' }
            elseif ($rawPath) { 'Fichier absent du disque' }
            else { 'Non telecharge' }

        $results.Add([pscustomobject]@{
            Artist = local:Val $row $colArtist
            Title  = local:Val $row $colTitle
            Album  = local:Val $row $colAlbum
            Length = local:Val $row $colLength
            Statut = $category
            Detail = if ($reason) { $reason } else { $state }
            Chemin = if ($exists) { $full } else { '' }
            Reussi = [bool]$exists
        })
    }

    # Titres presents dans la source mais absents de l'index : jamais traites.
    if ($SourceCsv -and (Test-Path -LiteralPath $SourceCsv)) {
        $seen = @{}
        foreach ($r in $results) { $seen["$($r.Artist)|$($r.Title)".ToLower().Trim()] = $true }
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

    # Repli : sans index, on balaye les fichiers audio presents.
    if ($results.Count -eq 0 -and (Test-Path -LiteralPath $OutputDir)) {
        $audio = '.mp3', '.flac', '.ogg', '.m4a', '.opus', '.wav', '.aac', '.alac'
        Get-ChildItem -Path $OutputDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $audio -contains $_.Extension.ToLower() } |
            ForEach-Object {
                $results.Add([pscustomobject]@{
                    Artist = ''; Title = $_.BaseName; Album = ''; Length = ''
                    Statut = 'Telecharge'; Detail = 'Detecte par balayage du dossier'
                    Chemin = $_.FullName; Reussi = $true
                })
            }
    }

    return $results
}

function Write-M3UPlaylist {
    param(
        [Parameter(Mandatory)] $Results,
        [Parameter(Mandatory)] [string] $OutputDir,
        [Parameter(Mandatory)] [string] $PlaylistPath,
        [bool] $Relative = $true
    )

    $ok = @($Results | Where-Object { $_.Reussi })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('#EXTM3U')
    $lines.Add("# Genere le $(Get-Date -Format 'yyyy-MM-dd HH:mm') - $($ok.Count) titres")

    foreach ($t in $ok) {
        $secs = 0
        $dur = if ($t.Length -and [double]::TryParse([string]$t.Length, [ref]$secs) -and $secs -gt 0) {
            [int]$secs
        } else { -1 }

        $label = if ($t.Artist -and $t.Title) { "$($t.Artist) - $($t.Title)" }
                 elseif ($t.Title)            { $t.Title }
                 else { [IO.Path]::GetFileNameWithoutExtension($t.Chemin) }

        $p = if ($Relative) { [IO.Path]::GetRelativePath($OutputDir, $t.Chemin) } else { $t.Chemin }

        $lines.Add("#EXTINF:$dur,$label")
        $lines.Add($p)
    }

    # UTF-8 sans BOM : formellement du M3U8, lu sans souci par VLC,
    # foobar2000 et Rekordbox sous l'extension .m3u.
    $lines | Set-Content -LiteralPath $PlaylistPath -Encoding utf8NoBOM
    return $ok.Count
}

function Show-RunSummary {
    param(
        [Parameter(Mandatory)] $Results,
        [string] $Title = 'RESULTAT',
        [switch] $NoDetail
    )

    $ok     = @($Results | Where-Object { $_.Reussi })
    $failed = @($Results | Where-Object { -not $_.Reussi })
    $total  = @($Results).Count
    $pct    = if ($total) { [math]::Round(100 * $ok.Count / $total) } else { 0 }

    Write-Host ""
    Write-Host "================ $Title ================" -ForegroundColor White
    Write-Host "  Telecharges : $($ok.Count) / $total  ($pct %)" `
        -ForegroundColor $(if ($pct -ge 60) { 'Green' } elseif ($pct -ge 30) { 'Yellow' } else { 'Red' })
    Write-Host "  Echecs      : $($failed.Count)" -ForegroundColor DarkGray

    if ($failed.Count) {
        Write-Host ""
        Write-Host "  Repartition des echecs :" -ForegroundColor Yellow
        $failed | Group-Object Statut | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("    {0,-38} {1,3}" -f $_.Name, $_.Count)
        }

        if (-not $NoDetail) {
            Write-Host ""
            Write-Host "  Titres manquants :" -ForegroundColor Yellow
            foreach ($f in ($failed | Sort-Object Statut, Artist)) {
                Write-Host ("    {0}" -f "$($f.Artist) - $($f.Title)".Trim(' -')) -ForegroundColor DarkGray
            }
        }
    }
}

# ========================================================== CATALOGUE ========
# Recense les playlists deja amorcees, pour pouvoir reprendre plus tard ce qui
# n'est pas passe. Sur un reseau P2P, un pair hors ligne aujourd'hui peut etre
# la demain : la reprise coute peu et rattrape beaucoup.

function Get-CataloguePath {
    $dir = if ($env:APPDATA) { [IO.Path]::Combine($env:APPDATA, 'sockseek') }
           else { [IO.Path]::Combine($HOME, '.config', 'sockseek') }
    return [IO.Path]::Combine($dir, 'catalogue.json')
}

function Read-Catalogue {
    $path = Get-CataloguePath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json)
    }
    catch {
        Write-Warning "Catalogue illisible ($path) : $($_.Exception.Message)"
        return @()
    }
}

function Save-Catalogue {
    param([Parameter(Mandatory)] $Entries)
    $path = Get-CataloguePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    ,@($Entries) | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $path -Encoding utf8NoBOM
}

function Register-Playlist {
    <# Cree ou met a jour l'entree d'une playlist. La cle est l'URL. #>
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $OutputDir,
        [Parameter(Mandatory)] [string] $SourceCsv,
        [string] $IndexPath,
        [string] $Name,
        [int] $Total = 0,
        [int] $Ok = 0
    )

    $entries = @(Read-Catalogue)
    $now = (Get-Date).ToString('s')

    $existing = $entries | Where-Object { $_.Url -eq $Url } | Select-Object -First 1

    if ($existing) {
        $existing.OutputDir = $OutputDir
        $existing.SourceCsv = (Resolve-Path -LiteralPath $SourceCsv -ErrorAction SilentlyContinue).Path ?? $SourceCsv
        $existing.IndexPath = $IndexPath
        $existing.LastRun   = $now
        $existing.RunCount  = [int]$existing.RunCount + 1
        if ($Total) { $existing.Total = $Total }
        if ($PSBoundParameters.ContainsKey('Ok')) { $existing.Ok = $Ok }
        if ($Name) { $existing.Name = $Name }
    }
    else {
        $entries += [pscustomobject]@{
            Url       = $Url
            Name      = if ($Name) { $Name } else { ($Url -split '/' | Where-Object { $_ } | Select-Object -Last 1) }
            OutputDir = $OutputDir
            SourceCsv = (Resolve-Path -LiteralPath $SourceCsv -ErrorAction SilentlyContinue).Path ?? $SourceCsv
            IndexPath = $IndexPath
            FirstRun  = $now
            LastRun   = $now
            RunCount  = 1
            Total     = $Total
            Ok        = $Ok
        }
    }

    Save-Catalogue $entries
}

function Get-PlaylistPending {
    <# Retourne les titres non recuperes d'une entree de catalogue. #>
    param([Parameter(Mandatory)] $Entry)

    if (-not (Test-Path -LiteralPath $Entry.OutputDir)) { return @() }

    $idx = $Entry.IndexPath
    if (-not ($idx -and (Test-Path -LiteralPath $idx))) {
        $idx = Join-Path $Entry.OutputDir '_index.csv'
    }

    $src = $Entry.SourceCsv
    if (-not ($src -and (Test-Path -LiteralPath $src))) { $src = $null }

    $res = Get-RunResults -IndexPath $idx -OutputDir $Entry.OutputDir -SourceCsv $src
    return @($res | Where-Object { -not $_.Reussi })
}
