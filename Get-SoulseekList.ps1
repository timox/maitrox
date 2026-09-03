#Requires -Version 7.0
<#
.SYNOPSIS
    Extrait une playlist SoundCloud/YouTube via yt-dlp, nettoie les metadonnees
    et produit un CSV directement consommable par sockseek.

.DESCRIPTION
    Les exports SoundCloud sont sales : le champ "uploader" est le nom de la
    chaine ou du label, pas l'artiste, et les titres sont noyes sous les
    prefixes de premiere, les codes catalogue et les mentions free DL.
    Ce script remet tout d'aplomb et peut enchainer sur le telechargement.

.PARAMETER Url
    URL de la playlist / du set.

.PARAMETER Out
    Chemin du CSV nettoye (defaut: playlist-clean.csv).

.PARAMETER RawOut
    Si fourni, ecrit aussi le CSV brut avant nettoyage, pour comparaison.

.PARAMETER Download
    Enchaine sur sockseek une fois le CSV produit.

.PARAMETER Credential
    Identifiants Soulseek, si tu ne veux pas passer par sockseek.conf.
    A eviter : la ligne de commande d'un processus est lisible par les autres
    utilisateurs de la machine. Prefere le fichier de configuration.

.PARAMETER SockseekPath
    Chemin complet vers sockseek.exe (ou sldl.exe pour les anciennes releases).
    Inutile si le dossier du binaire est deja dans le PATH.

.PARAMETER OutputDir
    Dossier de telechargement passe a sockseek.

.PARAMETER PrintOnly
    Avec -Download : n'affiche que ce que sockseek trouverait, sans rien
    telecharger. A faire au moins une fois avant de lancer pour de vrai.

.EXAMPLE
    .\Get-SoulseekList.ps1 -Url "https://soundcloud.com/loleanto/sets/sans-retour-short"

.EXAMPLE
    .\Get-SoulseekList.ps1 -Url $url -Download -PrintOnly

.EXAMPLE
    .\Get-SoulseekList.ps1 -Url $url -Download -OutputDir "D:\Music\techno"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Url,

    [string] $Out = "playlist-clean.csv",
    [string] $RawOut,

    [switch] $Download,
    [string] $SockseekPath,
    [pscredential] $Credential,
    [string] $OutputDir = (Join-Path $HOME "Music" "sockseek"),
    [switch] $PrintOnly
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

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
    $t = $t -replace "\uFF0C", ',' -replace "\u3000", ' '
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

# ------------------------------------------------------------- extraction ---
if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) {
    throw "yt-dlp est introuvable dans le PATH."
}

Write-Host "Recuperation des metadonnees (une requete par piste, patience)..." -ForegroundColor Cyan

$raw = & yt-dlp --skip-download --ignore-errors -J $Url
if (-not $raw) {
    throw "yt-dlp n'a rien renvoye. Verifie l'URL et l'accessibilite de la playlist."
}

$data    = ($raw -join "`n") | ConvertFrom-Json
$entries = @($data.entries | Where-Object { $_ })

if ($entries.Count -eq 0) {
    throw "Aucune piste trouvee dans la playlist."
}

Write-Host "$($entries.Count) pistes recuperees." -ForegroundColor Cyan

# ---------------------------------------------------------------- export ----
if ($RawOut) {
    $entries | ForEach-Object {
        [pscustomobject]@{
            index    = $_.playlist_index
            artist   = $_.artist
            uploader = $_.uploader
            track    = $_.track
            titre    = $_.title
            duree    = $_.duration
            url      = $_.webpage_url
        }
    } | Export-Csv -Path $RawOut -NoTypeInformation -Encoding utf8BOM
    Write-Host "CSV brut ecrit dans $RawOut" -ForegroundColor DarkGray
}

$all  = $entries | ForEach-Object { Convert-Entry $_ }
$junk = @($all | Where-Object { $_.Review -match 'PAS_UN_MORCEAU' })
$rows = @($all | Where-Object { $_.Review -notmatch 'PAS_UN_MORCEAU' })

# Le BOM gene certains parseurs CSV : on ecrit en UTF-8 sans BOM.
$rows | Export-Csv -Path $Out -NoTypeInformation -Encoding utf8NoBOM

$rows | Select-Object Artist, Title, Length, Review |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host ""
Write-Host "$($rows.Count) titres exportes vers $Out" -ForegroundColor Green

foreach ($j in $junk) {
    Write-Host "  ecarte (pas un morceau) : $($j.Title)" -ForegroundColor DarkGray
}

$flagged = @($rows | Where-Object { $_.Review -match 'TRONQUE' })
if ($flagged.Count -gt 0) {
    Write-Host ""
    Write-Host "$($flagged.Count) titres tronques dans l'export, a completer a la main :" -ForegroundColor Yellow
    foreach ($f in $flagged) {
        Write-Host "  $($f.Artist) - $($f.Title)"
    }
}

$weak = @($rows | Where-Object { $_.Review -match 'artiste=chaine' })
if ($weak.Count -gt 0) {
    Write-Host ""
    Write-Host "$($weak.Count) titres sans artiste identifiable (nom de chaine utilise par defaut)." -ForegroundColor Yellow
    Write-Host "  --artist-maybe-wrong relancera une recherche sans l'artiste pour ceux-la."
}

# ---------------------------------------------------------- telechargement --
if (-not $Download) {
    Write-Host ""
    Write-Host "Pour verifier ce que sockseek trouverait :" -ForegroundColor Cyan
    Write-Host "  .\Get-SoulseekList.ps1 -Url `"$Url`" -Download -PrintOnly"
    return
}

# Sockseek se distribue en binaire autonome : rien ne l'ajoute au PATH.
# On le cherche donc a plusieurs endroits plausibles avant d'abandonner.
$exe = $null

if ($SockseekPath) {
    if (-not (Test-Path -LiteralPath $SockseekPath)) {
        throw "Aucun executable a l'emplacement indique : $SockseekPath"
    }
    $exe = (Resolve-Path -LiteralPath $SockseekPath).Path
}
else {
    # 1. dans le PATH, sous l'un ou l'autre nom (sldl = ancien nom du projet)
    foreach ($name in 'sockseek', 'sldl') {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($cmd) { $exe = $cmd.Source; break }
    }

    # 2. a cote du script, ou dans un sous-dossier
    if (-not $exe) {
        $here = Split-Path -Parent $PSCommandPath
        $found = Get-ChildItem -Path $here -Recurse -Depth 2 -File `
                     -Include 'sockseek.exe', 'sldl.exe', 'sockseek', 'sldl' `
                     -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $exe = $found.FullName }
    }
}

if (-not $exe) {
    Write-Host ""
    Write-Warning @"
Executable sockseek introuvable.

Sockseek se telecharge en binaire autonome depuis la page des releases GitHub :
rien ne l'ajoute au PATH tout seul. Deux solutions :

  1. Indiquer le chemin au script :
     -SockseekPath "C:\Outils\sockseek\sockseek.exe"

  2. Ou ajouter son dossier au PATH utilisateur, une bonne fois :
     [Environment]::SetEnvironmentVariable('Path',
        [Environment]::GetEnvironmentVariable('Path','User') + ';C:\Outils\sockseek',
        'User')
     puis rouvrir le terminal.

Si tu as une release anterieure au renommage, le binaire s'appelle sldl.exe.
"@
    Write-Host "Le CSV $Out est bien ecrit : relance juste avec -SockseekPath." -ForegroundColor Green
    exit 2
}

Write-Host "Executable : $exe" -ForegroundColor DarkGray

# --- identifiants ----------------------------------------------------------
# Sockseek lit sockseek.conf dans, par ordre : le dossier de config utilisateur,
# %APPDATA%, XDG_CONFIG_HOME, puis le dossier du binaire.
$confCandidates = @(
    [IO.Path]::Combine($HOME, '.config', 'sockseek', 'sockseek.conf')
    $(if ($env:APPDATA)         { [IO.Path]::Combine($env:APPDATA, 'sockseek', 'sockseek.conf') })
    $(if ($env:XDG_CONFIG_HOME) { [IO.Path]::Combine($env:XDG_CONFIG_HOME, 'sockseek', 'sockseek.conf') })
    [IO.Path]::Combine((Split-Path -Parent $exe), 'sockseek.conf')
) | Where-Object { $_ }

$conf = $confCandidates | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | Select-Object -First 1

# Emplacement conseille selon la plateforme
$confAdvised = if ($env:APPDATA) {
    [IO.Path]::Combine($env:APPDATA, 'sockseek', 'sockseek.conf')
} else {
    [IO.Path]::Combine($HOME, '.config', 'sockseek', 'sockseek.conf')
}

if ($Credential) {
    $sockArgsCreds = @(
        '--user', $Credential.UserName
        '--pass', $Credential.GetNetworkCredential().Password
    )
    Write-Warning "Identifiants passes en ligne de commande : visibles par les autres processus."
}
elseif ($conf) {
    $sockArgsCreds = @()
    Write-Host "Configuration : $conf" -ForegroundColor DarkGray
}
else {
    Write-Host ""
    Write-Warning @"
Aucun fichier sockseek.conf trouve, et aucun identifiant fourni.
Sockseek exige --user et --pass, ou de les lire dans sa configuration.

Cree le fichier suivant :

  $confAdvised

avec au minimum :

  username = ton-compte-soulseek
  password = ton-mot-de-passe
  output-dir = $OutputDir

Utilise un compte Soulseek DEDIE si tu fais tourner un autre client
(Nicotine+, slskd) en parallele : deux sessions sur le meme compte
provoquent des problemes de connexion.

Sinon, en depannage : -Credential (Get-Credential)
"@
    Write-Host "Le CSV $Out est bien ecrit : relance une fois la config en place." -ForegroundColor Green
    exit 3
}

$idxPath = Join-Path $OutputDir '_index.csv'
$logPath = Join-Path $OutputDir ("sockseek-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$sockArgs = @(
    $Out
    '--index-path', $idxPath
    '--log-file', $logPath
    '--song'
    '--artist-maybe-wrong'
    '--length-tol', '10'
    '--pref-format', 'flac,wav'
    '--remove-ft'
    '--name-format', '{artist( - )title|filename}'
    '--output-dir', $OutputDir
)

if ($PrintOnly) {
    $sockArgs += @('--print', 'results')
    Write-Host ""
    Write-Host "Recherche seule, aucun telechargement." -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "Telechargement vers $OutputDir" -ForegroundColor Cyan
    Write-Host "Compte environ $([math]::Ceiling($rows.Count / 34.0) * 220 / 60) minutes minimum : le serveur Soulseek"
    Write-Host "bannit 30 minutes si les recherches s'enchainent trop vite." -ForegroundColor DarkGray
}

& $exe @sockArgs @sockArgsCreds
$code = $LASTEXITCODE

if ($PrintOnly) {
    Write-Host ""
    Write-Host "Recherche terminee (code $code)." -ForegroundColor DarkGray
    return
}

if ($code -ne 0) {
    Write-Warning "sockseek s'est termine avec le code $code. Journal : $logPath"
}

# ---------------------------------------------------- rapport et playlist ---
$builder = Join-Path (Split-Path -Parent $PSCommandPath) 'Build-Playlist.ps1'
if (Test-Path -LiteralPath $builder) {
    & $builder -OutputDir $OutputDir -IndexPath $idxPath -SourceCsv $Out -Register $Url
}
else {
    Write-Warning "Build-Playlist.ps1 absent : ni rapport ni playlist generes."
}

Write-Host "Journal detaille : $logPath" -ForegroundColor DarkGray
