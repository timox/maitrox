#Requires -Version 7.0
<#
    Fonctions partagees par Build-Playlist.ps1, Get-SoulseekList.ps1 et
    Resume-Downloads.ps1. Ce fichier ne fait rien seul : il se charge par
    point-sourcing.

        . (Join-Path $PSScriptRoot 'SockseekLib.ps1')
#>

# ===================================================== NETTOYAGE DES TITRES ==
# Utilise par Get-SoulseekList.ps1 pour transformer les exports bruts
# SoundCloud/YouTube en entrees Artist/Title exploitables par sockseek.
# Teste independamment dans tests/SockseekLib.Tests.ps1.

# ---------------------------------------------------------------- regexes ---
# Prefixes de premiere : "PREMIERE:", "BCCO Premiere:", "PW PREMIERE |",
# "Bunkers Premiere /", "SYN Premiere:", "PREMIERE - "
$rePremiere   = [regex]::new('^\s*(?:[\w.&+\-'']{1,20}\s+)?premiere\s*(?::|\||/|\s[-–—])\s*',
                             'IgnoreCase')
# Fragment de crochet/parenthese tronque : "[ORE...", "(Volster..."
$reTruncated  = [regex]::new('\s*[\[(][^\])]*\.\.\.\s*$')
# Bloc entre crochets en fin de titre : codes catalogue, mentions diverses
$reBrackets   = [regex]::new('\s*\[[^\]]*\]\s*$')
# Mentions de telechargement libre, ou qu'elles soient
$reFreeDl     = [regex]::new('\+?\s*[\[(]?\s*(?:free\s*d(?:own)?l(?:oad)?|bandcamp)[^\])]*[\])]?\s*\+?',
                             'IgnoreCase')
$rePipeTail   = [regex]::new('\s*\|\s*(?:free\s*dl|bandcamp)\s*$', 'IgnoreCase')
# (Original Mix) : n'aide jamais une recherche Soulseek
$reOrigMix    = [regex]::new('\s*\(\s*original\s*mix\s*\)', 'IgnoreCase')
# Catalogue entre parentheses : (TAR034)
$reParenCat   = [regex]::new('\s*\(\s*[A-Z]{2,}[\s.\-]?\d{2,}\s*\)')
# Position vinyle en tete : "A2 Deluka - ..."
$reVinylPos   = [regex]::new('^[A-D][1-9]\s+')
# ", by Artiste" en suffixe (style Bandcamp / HPX)
$reBySuffix   = [regex]::new(',\s*by\s+.+$', 'IgnoreCase')
# Separateur artiste / titre
$reSplit      = [regex]::new('\s+[-–—]\s+')
# Ce qui n'est pas un morceau
$reJunk       = [regex]::new('template|demo\s*song', 'IgnoreCase')

# -------------------------------------------------------------- fonctions ---
function Normalize-Text {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    # NFKC : ramene les polices fantaisie unicode a de l'ASCII lisible
    $t = $Text.Normalize([Text.NormalizationForm]::FormKC)
    $t = $t -replace "，", ',' -replace "　", ' '
    return ($t -replace '\s+', ' ').Trim()
}

function Clean-Title {
    param([string] $Text)

    $truncated = $Text.TrimEnd().EndsWith('...')

    $t = $reTruncated.Replace($Text, '')
    $t = $rePremiere.Replace($t, '')
    $t = $rePipeTail.Replace($t, '')
    $t = $reFreeDl.Replace($t, ' ')

    # plusieurs blocs [..] peuvent s'enchainer en fin de titre
    do   { $prev = $t; $t = $reBrackets.Replace($t, '') }
    while ($prev -ne $t)

    $t = $reParenCat.Replace($t, '')
    $t = $reOrigMix.Replace($t, '')
    $t = $reVinylPos.Replace($t, '')
    $t = $reBySuffix.Replace($t, '')
    $t = $t -replace '\s+\)', ')' -replace '\s+', ' '

    return [pscustomobject]@{
        Text      = $t.Trim(" -–—|+".ToCharArray())
        Truncated = $truncated
    }
}

function Convert-Entry {
    param($Entry)

    $metaArtist = Normalize-Text $Entry.artist
    $uploader   = Normalize-Text $Entry.uploader
    $metaTrack  = Normalize-Text $Entry.track
    $rawTitle   = Normalize-Text $Entry.title

    $isJunk = $reJunk.IsMatch($rawTitle)

    $cleaned   = Clean-Title $rawTitle
    $title     = $cleaned.Text
    $truncated = $cleaned.Truncated

    $notes = [System.Collections.Generic.List[string]]::new()

    if ($metaArtist -and $metaTrack) {
        # Metadonnees reelles renseignees : elles font autorite.
        $artist = $metaArtist
        $track  = (Clean-Title $metaTrack).Text
        $notes.Add('metadonnees')
    }
    else {
        # "ANNE- Gentle Loop" : tiret colle apres le nom d'artiste
        $ref = if ($metaArtist) { $metaArtist } else { $uploader }
        if ($ref -and $title.ToLower().StartsWith($ref.ToLower() + '-')) {
            $title = $title.Substring(0, $ref.Length) + ' - ' + $title.Substring($ref.Length + 1)
        }

        $parts = $reSplit.Split($title)
        if ($parts.Count -ge 2) {
            $artist = $parts[0].Trim()
            $track  = ($parts[1..($parts.Count - 1)] | ForEach-Object { $_.Trim() }) -join ' - '
        }
        elseif ($metaArtist) {
            $artist = $metaArtist
            $track  = $title
        }
        else {
            # Rien d'autre sous la main que le nom de chaine : peu fiable.
            $artist = $uploader
            $track  = $title
            $notes.Add('artiste=chaine')
        }
    }

    if ($truncated) { $notes.Add('TRONQUE') }
    if ($isJunk)    { $notes.Add('PAS_UN_MORCEAU') }
    if ($artist -and $uploader -and $artist -ne $uploader -and -not $metaArtist) {
        $notes.Add('artiste extrait du titre')
    }

    $length = if ($Entry.duration) { [int][math]::Floor([double]$Entry.duration) } else { '' }

    return [pscustomobject]@{
        Artist        = $artist
        Title         = $track
        Length        = $length
        SourceChannel = $uploader
        Url           = $Entry.webpage_url
        Review        = ($notes -join '; ')
    }
}

# ============================================================ ANALYSE ========

# Sockseek 3.x ecrit "state" et "failurereason" comme des codes numeriques
# d'enum interne (Sockseek.Core.Common.Enums.JobStateOld / JobFailureReason),
# pas du texte : verifie empiriquement sur sockseek 3.0.5 (--print index-failed
# donne "NoSearchResults" pendant que _index.csv, lui, ecrit "9"). Les valeurs
# viennent du code source du projet, pas d'une doc publique susceptible de
# changer sans prevenir : a revisiter si une future release change les codes.
$script:SockseekFailureReasonNames = @{
    0 = 'None'; 1 = 'InvalidSearchString'; 2 = 'OutOfDownloadRetries'
    4 = 'AllDownloadsFailed'; 5 = 'Other'; 6 = 'ExtractionFailed'
    7 = 'Cancelled'; 8 = 'ChildJobsFailed'; 9 = 'NoSearchResults'
    10 = 'NoMatchingResults'
}
$script:SockseekFailureReasonCategories = @{
    2 = 'Probleme reseau ou pair injoignable'   # OutOfDownloadRetries
    4 = 'Probleme reseau ou pair injoignable'   # AllDownloadsFailed
    5 = 'Echec (cause non precisee)'            # Other
    6 = 'Echec (cause non precisee)'            # ExtractionFailed
    7 = 'Annule'                                # Cancelled
    8 = 'Echec (cause non precisee)'            # ChildJobsFailed
    9 = 'Introuvable sur Soulseek'               # NoSearchResults
    10 = 'Filtre par les conditions'             # NoMatchingResults
}
$script:SockseekStateNames = @{
    0 = 'Pending'; 1 = 'Done'; 2 = 'Failed'; 3 = 'AlreadyExists'; 4 = 'NotFoundLastTime'
}
$script:SockseekStateCategories = @{
    4 = 'Introuvable sur Soulseek'   # NotFoundLastTime : ignore par --skip-not-found
}

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

        # sockseek 3.x : $state/$reason sont des codes numeriques d'enum (cf. plus haut).
        # $reasonCode 0 (None) n'est pas exploitable : on retombe sur l'etat.
        $reasonCode = $null
        if ($reason -match '^-?\d+$') { $reasonCode = [int]$reason }
        $stateCode = $null
        if ($state -match '^-?\d+$') { $stateCode = [int]$state }

        $reasonCategory = if ($reasonCode -and $script:SockseekFailureReasonCategories.ContainsKey($reasonCode)) {
            $script:SockseekFailureReasonCategories[$reasonCode]
        } else { $null }
        $stateCategory = if ($null -ne $stateCode -and $script:SockseekStateCategories.ContainsKey($stateCode)) {
            $script:SockseekStateCategories[$stateCode]
        } else { $null }

        $category =
            if ($exists) { 'Telecharge' }
            elseif ($reasonCategory) { $reasonCategory }
            elseif ($stateCategory) { $stateCategory }
            # Repli pour un index au format texte (versions anterieures a sockseek 3.x).
            elseif ($reason -match '(?i)not.?found|no.?result|introuv') { 'Introuvable sur Soulseek' }
            elseif ($reason -match '(?i)nosuitable|no.?suitable|condition|filter|quality|bitrate|format') { 'Filtre par les conditions' }
            elseif ($reason -match '(?i)timeout|stale|connect|refus|offline') { 'Probleme reseau ou pair injoignable' }
            elseif ($reason -match '(?i)cancel|abort') { 'Annule' }
            elseif ($state  -match '(?i)not.?found') { 'Introuvable sur Soulseek' }
            elseif ($state  -match '(?i)fail|error')  { 'Echec (cause non precisee)' }
            elseif ($rawPath) { 'Fichier absent du disque' }
            else { 'Non telecharge' }

        # Detail lisible : nom de l'enum plutot que le code numerique brut.
        $reasonDetail = if ($null -ne $reasonCode -and $script:SockseekFailureReasonNames.ContainsKey($reasonCode)) {
            $script:SockseekFailureReasonNames[$reasonCode]
        } else { $reason }
        $stateDetail = if ($null -ne $stateCode -and $script:SockseekStateNames.ContainsKey($stateCode)) {
            $script:SockseekStateNames[$stateCode]
        } else { $state }

        $results.Add([pscustomobject]@{
            Artist = local:Val $row $colArtist
            Title  = local:Val $row $colTitle
            Album  = local:Val $row $colAlbum
            Length = local:Val $row $colLength
            Statut = $category
            Detail = if ($reasonDetail -and $reasonDetail -ne 'None') { $reasonDetail } else { $stateDetail }
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

function Get-SockseekConfigDir {
    if ($env:APPDATA) { [IO.Path]::Combine($env:APPDATA, 'sockseek') }
    else { [IO.Path]::Combine($HOME, '.config', 'sockseek') }
}

function Get-CataloguePath {
    return [IO.Path]::Combine((Get-SockseekConfigDir), 'catalogue.json')
}

function Get-PrefsPath {
    return [IO.Path]::Combine((Get-SockseekConfigDir), 'prefs.json')
}

function Get-DefaultOutputDir {
    <# Dossier de destination retenu d'un lancement a l'autre. Modifie via
       Set-DefaultOutputDir (typiquement en tapant un nouveau chemin dans le
       menu de lancer.bat), sinon valeur d'origine du kit. #>
    $path = Get-PrefsPath
    if (Test-Path -LiteralPath $path) {
        try {
            $prefs = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
            if ($prefs.OutputDir) { return $prefs.OutputDir }
        }
        catch {
            Write-Warning "Preferences illisibles ($path) : $($_.Exception.Message)"
        }
    }
    return (Join-Path $HOME 'Music' 'sockseek')
}

function Set-DefaultOutputDir {
    param([Parameter(Mandatory)] [string] $OutputDir)
    $path = Get-PrefsPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [pscustomobject]@{ OutputDir = $OutputDir } | ConvertTo-Json |
        Set-Content -LiteralPath $path -Encoding utf8NoBOM
}

function Get-SockseekConfPath {
    $dir = if ($env:APPDATA) { [IO.Path]::Combine($env:APPDATA, 'sockseek') }
           else { [IO.Path]::Combine($HOME, '.config', 'sockseek') }
    return [IO.Path]::Combine($dir, 'sockseek.conf')
}

function Set-SockseekCredentials {
    <# Ecrit ou met a jour username/password (et, si fourni, output-dir) dans
       sockseek.conf, sans toucher au reste du fichier (profils, autres
       reglages) ni exiger de prompt interactif -- utilisable depuis un
       bouton d'interface graphique. Cree le fichier s'il n'existe pas. #>
    param(
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password,
        [string] $OutputDir,
        [string] $ConfPath = (Get-SockseekConfPath)
    )

    # Assignation dans chaque branche plutot que $lines = if (...) {...} else
    # {...} : une List vide capturee comme "valeur" d'un bloc if/else est
    # deroulee (enumeree) par PowerShell et disparait -- $lines vaudrait $null.
    if (Test-Path -LiteralPath $ConfPath) {
        $lines = [System.Collections.Generic.List[string]]::new([string[]](Get-Content -LiteralPath $ConfPath -Encoding utf8))
    }
    else {
        $lines = [System.Collections.Generic.List[string]]::new()
    }

    function local:Set-ConfLine {
        param($Lines, [string] $Key, [string] $Value)
        $pattern = "^\s*$([regex]::Escape($Key))\s*="
        $idx = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match $pattern) { $idx = $i; break }
        }
        $newLine = "$Key = $Value"
        if ($idx -ge 0) { $Lines[$idx] = $newLine } else { $Lines.Add($newLine) }
    }

    Set-ConfLine $lines 'username' $Username
    Set-ConfLine $lines 'password' $Password
    if ($OutputDir) { Set-ConfLine $lines 'output-dir' $OutputDir }

    New-Item -ItemType Directory -Path (Split-Path -Parent $ConfPath) -Force | Out-Null
    $lines | Set-Content -LiteralPath $ConfPath -Encoding utf8NoBOM
}

function ConvertTo-SafeFolderName {
    <# Nom de playlist -> nom de dossier valide sur Windows comme sur Unix.
       Liste figee plutot que [IO.Path]::GetInvalidFileNameChars() : cette
       API est dependante de la plateforme (sur Linux elle n'exclut que '/'),
       alors que le kit cible du disque Windows quelle que soit la machine
       qui execute le script. #>
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'playlist' }
    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1f]', ' '
    $safe = $safe -replace '\s+', ' '
    $safe = $safe.Trim(" .")
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'playlist' }
    return $safe
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

function Import-PlaylistFolder {
    <# Rend gerable, depuis l'onglet Playlists, un dossier de telechargement
       existant jamais enregistre dans le catalogue centralise -- deplace a
       la main, telecharge avant l'introduction de ce catalogue, ou produit
       sur une autre machine. Aucune extraction n'est relancee : on relit
       juste ce qui est deja sur le disque.

       La cle du catalogue est l'URL d'origine (voir Register-Playlist),
       perdue pour un dossier importe : on fabrique donc un identifiant
       stable a partir du chemin du dossier -- reimporter le meme dossier
       met a jour l'entree plutot que d'en creer une seconde. #>
    param(
        [Parameter(Mandatory)] [string] $FolderPath,
        [string] $Name
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        throw "Dossier introuvable : $FolderPath"
    }
    $resolved = (Resolve-Path -LiteralPath $FolderPath).Path

    $indexPath = Get-ChildItem -Path $resolved -Recurse -File -Filter '_index.csv' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
                 ForEach-Object { $_.FullName }

    # playlist-clean.csv est le nom par defaut de Get-SoulseekList.ps1, mais
    # n'importe quel CSV avec des colonnes Artist/Title fait l'affaire pour
    # detecter les titres jamais tentes (voir Get-RunResults) -- utile si le
    # fichier a ete renomme ou copie a la main dans le dossier importe.
    $sourceCsv = Get-ChildItem -Path $resolved -File -Filter '*.csv' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notin @('_index.csv', 'rapport.csv') } |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
                 ForEach-Object { $_.FullName }
    if (-not $sourceCsv) { $sourceCsv = Join-Path $resolved 'playlist-clean.csv' }

    if (-not $Name) { $Name = Split-Path -Leaf $resolved }

    $results = @(Get-RunResults -IndexPath $indexPath -OutputDir $resolved -SourceCsv $sourceCsv)
    if ($results.Count -eq 0) {
        throw "Aucun index sockseek (_index.csv) ni fichier audio trouve dans ce dossier : $resolved"
    }
    $total = $results.Count
    $ok    = @($results | Where-Object { $_.Reussi }).Count

    $url = "local-import://$resolved"
    Register-Playlist -Url $url -OutputDir $resolved -SourceCsv $sourceCsv `
                       -IndexPath $indexPath -Name $Name -Total $total -Ok $ok

    return [pscustomobject]@{
        Name      = $Name
        OutputDir = $resolved
        IndexPath = $indexPath
        SourceCsv = $sourceCsv
        Total     = $total
        Ok        = $ok
        Manquants = $total - $ok
    }
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
