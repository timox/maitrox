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

.PARAMETER CookiesFromBrowser
    Reutilise la session d'un navigateur ou tu es deja connecte a
    SoundCloud, pour les sets prives ou reserves aux abonnes. Un nom de
    navigateur (brave, chrome, chromium, edge, firefox, opera, safari,
    vivaldi, whale), pas un chemin d'executable : yt-dlp retrouve tout seul
    le dossier de profil correspondant. SoundCloud n'accepte pas de simple
    identifiant/mot de passe cote yt-dlp -- voir le fichier CHANGELOG ou
    l'aide de yt-dlp pour --cookies-from-browser en cas de souci (verrouillage
    du fichier de cookies si le navigateur est ouvert, par exemple).

    Les sets "non listes" (lien avec ?secret_token=...) n'en ont pas besoin :
    yt-dlp les gere deja tout seul.

.EXAMPLE
    .\Get-SoulseekList.ps1 -Url "https://soundcloud.com/loleanto/sets/sans-retour-short"

.EXAMPLE
    .\Get-SoulseekList.ps1 -Url $url -Download -PrintOnly

.EXAMPLE
    .\Get-SoulseekList.ps1 -Url $url -Download -OutputDir "D:\Music\techno"

.EXAMPLE
    .\Get-SoulseekList.ps1 -Url $url -CookiesFromBrowser firefox
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
    [string] $OutputDir,
    [switch] $PrintOnly,

    [ValidateSet('brave', 'chrome', 'chromium', 'edge', 'firefox', 'opera', 'safari', 'vivaldi', 'whale')]
    [string] $CookiesFromBrowser
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# Regex de nettoyage et fonctions Normalize-Text / Clean-Title / Convert-Entry :
# voir SockseekLib.ps1, testees independamment dans tests/SockseekLib.Tests.ps1.
. (Join-Path $PSScriptRoot 'SockseekLib.ps1')

if ($PSBoundParameters.ContainsKey('OutputDir') -and $OutputDir) {
    # -OutputDir explicite : devient le nouveau dossier par defaut pour les
    # prochains lancements (lancer.bat s'appuie la-dessus pour le rendre
    # modifiable depuis son menu).
    Set-DefaultOutputDir -OutputDir $OutputDir
}
else {
    $OutputDir = Get-DefaultOutputDir
}

# ------------------------------------------------------------- extraction ---
if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) {
    throw "yt-dlp est introuvable dans le PATH."
}

Write-Host "Recuperation des metadonnees (une requete par piste, patience)..." -ForegroundColor Cyan

$ytDlpArgs = @('--skip-download', '--ignore-errors', '-J')
if ($CookiesFromBrowser) {
    $ytDlpArgs += @('--cookies-from-browser', $CookiesFromBrowser)
}
$ytDlpArgs += $Url

$raw = & yt-dlp @ytDlpArgs
if (-not $raw) {
    throw "yt-dlp n'a rien renvoye. Verifie l'URL et l'accessibilite de la playlist."
}

$data    = ($raw -join "`n") | ConvertFrom-Json
$entries = @($data.entries | Where-Object { $_ })

if ($entries.Count -eq 0) {
    throw "Aucune piste trouvee dans la playlist."
}

# Chaque playlist telecharge dans son propre sous-dossier, nomme d'apres son
# titre, a l'interieur du dossier de destination : deux sets ne se melangent
# jamais sur le disque.
$playlistName   = if ($data.title) { $data.title } else { ($Url.TrimEnd('/') -split '/' | Select-Object -Last 1) }
$playlistFolder = ConvertTo-SafeFolderName $playlistName
$destDir        = Join-Path $OutputDir $playlistFolder

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

$idxPath = Join-Path $destDir '_index.csv'
$logPath = Join-Path $destDir ("sockseek-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

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
    '--output-dir', $destDir
)

if ($PrintOnly) {
    $sockArgs += @('--print', 'results')
    Write-Host ""
    Write-Host "Recherche seule, aucun telechargement." -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "Telechargement vers $destDir" -ForegroundColor Cyan
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
    & $builder -OutputDir $destDir -IndexPath $idxPath -SourceCsv $Out -Register $Url
}
else {
    Write-Warning "Build-Playlist.ps1 absent : ni rapport ni playlist generes."
}

Write-Host "Journal detaille : $logPath" -ForegroundColor DarkGray
