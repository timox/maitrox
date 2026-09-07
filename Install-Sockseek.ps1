#Requires -Version 7.0
<#
.SYNOPSIS
    Installe sockseek et yt-dlp, et cree le fichier de configuration.

.DESCRIPTION
    Telecharge les deux binaires depuis leurs pages de releases GitHub, les
    place dans un dossier unique, ajoute ce dossier au PATH utilisateur et
    genere sockseek.conf.

    Le compte Soulseek n'a pas besoin d'exister au prealable : le serveur
    enregistre un pseudo a la premiere connexion. Si le pseudo choisi est
    deja pris par quelqu'un d'autre, la connexion sera refusee et il faudra
    en choisir un autre.

.PARAMETER InstallDir
    Dossier d'installation (defaut: %LOCALAPPDATA%\sockseek).

.PARAMETER MusicDir
    Dossier de telechargement de la musique.

.PARAMETER Force
    Reinstalle les binaires meme s'ils sont deja presents, et ecrase une
    configuration existante.

.PARAMETER SkipExecutionPolicy
    Ne touche pas a la politique d'execution PowerShell.

.PARAMETER SkipCredentials
    Installe les binaires et regle le PATH sans toucher a sockseek.conf :
    ni prompt interactif, ni ecrasement d'une configuration existante. Utile
    pour un lancement non interactif (bouton d'une interface graphique par
    exemple) ; les identifiants se configurent alors separement, avec
    Set-SockseekCredentials (SockseekLib.ps1).

.PARAMETER SockseekUrl
.PARAMETER YtDlpUrl
    URL de telechargement directe, pour contourner l'API GitHub si elle est
    inaccessible (quota atteint, proxy filtrant). Recupere l'URL a la main
    depuis la page des releases du projet.

.EXAMPLE
    .\Install-Sockseek.ps1

.EXAMPLE
    .\Install-Sockseek.ps1 -InstallDir "D:\Outils\sockseek" -MusicDir "D:\Music\techno"
#>

[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'sockseek'),
    [string] $MusicDir   = (Join-Path $HOME 'Music' 'sockseek'),
    [switch] $Force,
    [switch] $SkipExecutionPolicy,
    [switch] $SkipCredentials,
    [string] $SockseekUrl,
    [string] $YtDlpUrl
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'SockseekLib.ps1')

function Write-Step { param([string]$m) Write-Host "`n>> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "   $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "   $m" -ForegroundColor DarkGray }

Write-Host @"
================================================================
 Installation sockseek + yt-dlp
================================================================
"@ -ForegroundColor White

# ---------------------------------------------------- politique d'execution --
if (-not $SkipExecutionPolicy) {
    Write-Step "Politique d'execution PowerShell"
    $current = Get-ExecutionPolicy -Scope CurrentUser
    if ($current -eq 'Unrestricted') {
        Write-Info "Deja sur Unrestricted."
    }
    else {
        Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force
        Write-Ok "Passee de '$current' a 'Unrestricted' pour l'utilisateur courant."
        Write-Info "Unrestricted execute tout script sans avertissement, y compris"
        Write-Info "ceux venant d'Internet. RemoteSigned suffirait ici et resterait"
        Write-Info "plus prudent : Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
    }
}

# ------------------------------------------------------------- preparation --
Write-Step "Dossier d'installation"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Write-Ok $InstallDir

$tmp = Join-Path ([IO.Path]::GetTempPath()) "sockseek-install-$([guid]::NewGuid().Guid.Substring(0,8))"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Get-LatestAsset {
    <#  Retourne l'URL du premier asset d'une release GitHub dont le nom
        correspond au motif fourni. Retombe sur la liste complete des releases
        si le depot n'expose pas de 'latest' (cas des depots sans release
        stable marquee).  #>
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Pattern
    )

    $headers = @{ 'User-Agent' = 'sockseek-toolkit'; 'Accept' = 'application/vnd.github+json' }

    function Invoke-GitHubApi {
        param([string] $Uri)
        try {
            return Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec 30
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 403 -or $status -eq 429) {
                throw @"
L'API GitHub refuse la requete (code $status) : quota atteint.

Sans authentification, GitHub limite a 60 requetes par heure et par adresse IP.
Derriere un NAT d'entreprise, ce quota est partage avec tout le reseau.

Deux contournements :

  1. Attendre une heure, puis relancer.

  2. Recuperer les URL a la main sur les pages de releases des deux projets
     (archive win-x64 pour sockseek, yt-dlp.exe pour l'autre) et les passer
     directement :

     .\Install-Sockseek.ps1 ``
        -SockseekUrl "https://github.com/.../sockseek_x.y.z_win-x64.zip" ``
        -YtDlpUrl    "https://github.com/.../yt-dlp.exe"
"@
            }
            throw
        }
    }

    $releases = @()
    try {
        $releases += Invoke-GitHubApi "https://api.github.com/repos/$Repo/releases/latest"
    }
    catch {
        if ($_.Exception.Message -match 'quota atteint') { throw }
        Write-Info "Pas de release 'latest' pour $Repo, parcours de la liste."
    }

    if (-not $releases -or -not $releases[0].assets) {
        $releases = Invoke-GitHubApi "https://api.github.com/repos/$Repo/releases?per_page=10" |
                    Where-Object { -not $_.prerelease }
    }

    foreach ($rel in $releases) {
        $asset = $rel.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
        if ($asset) {
            return [pscustomobject]@{
                Version = $rel.tag_name
                Name    = $asset.name
                Url     = $asset.browser_download_url
            }
        }
    }

    throw "Aucun asset correspondant a '$Pattern' dans les releases de $Repo."
}

# sockseek publie une release par plateforme (verifie dans le vrai depot,
# build/PublishZip.targets) : sockseek_<version>_win-x64.zip,
# _linux-x64.tar.gz, _osx-x64.tar.gz -- le zip Windows n'est pas executable
# tel quel sous Linux/macOS (format PE, pas ELF/Mach-O). yt-dlp publie de
# meme un binaire distinct par OS (yt-dlp.exe, yt-dlp_linux, yt-dlp_macos --
# verifie dans le README du vrai depot). Sans distinguer la plateforme ici,
# le script installait toujours le binaire Windows, meme sous Linux : il se
# copiait bien (Get-ChildItem le trouvait dans l'archive), mais restait
# introuvable ensuite (nomme *.exe, jamais executable) sans qu'aucune
# erreur ne le signale.
$sockPattern = if ($IsWindows) { '*win-x64.zip' } elseif ($IsMacOS) { '*osx-x64.tar.gz' } else { '*linux-x64.tar.gz' }
$sockName    = if ($IsWindows) { 'sockseek.exe' } else { 'sockseek' }
$ytPattern   = if ($IsWindows) { 'yt-dlp.exe' } elseif ($IsMacOS) { 'yt-dlp_macos' } else { 'yt-dlp_linux' }
$ytName      = if ($IsWindows) { 'yt-dlp.exe' } else { 'yt-dlp' }

function Expand-InstallArchive {
    <# Expand-Archive ne sait pas lire un .tar.gz : `tar`, present sur
       a peu pres tout Linux/macOS moderne, s'en charge a sa place. #>
    param([string] $ArchivePath, [string] $DestinationPath)
    if ($ArchivePath -match '\.tar\.gz$|\.tgz$') {
        & tar -xzf $ArchivePath -C $DestinationPath
        if ($LASTEXITCODE -ne 0) { throw "echec de 'tar' sur $ArchivePath (code $LASTEXITCODE)." }
    }
    else {
        Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
    }
}

# ---------------------------------------------------------------- sockseek --
Write-Step "sockseek"
$sockExe = Join-Path $InstallDir $sockName

if ((Test-Path $sockExe) -and -not $Force) {
    Write-Info "Deja present. -Force pour reinstaller."
}
else {
    $asset = if ($SockseekUrl) {
        [pscustomobject]@{ Version = 'fournie'; Name = Split-Path $SockseekUrl -Leaf; Url = $SockseekUrl }
    } else {
        Get-LatestAsset -Repo 'fiso64/sockseek' -Pattern $sockPattern
    }
    Write-Info "Version $($asset.Version) : $($asset.Name)"

    $archive = Join-Path $tmp $asset.Name
    Invoke-WebRequest -Uri $asset.Url -OutFile $archive -TimeoutSec 300

    # Extrait dans un sous-dossier dedie, pas directement dans $tmp : sinon
    # l'archive elle-meme (qui y reste) se ferait copier avec le binaire par
    # le Copy-Item plus bas -- constate en le reproduisant (l'archive de
    # ~50 Mo se retrouvait dans le dossier d'installation final).
    $extractDir = Join-Path $tmp 'sockseek-extract'
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Expand-InstallArchive -ArchivePath $archive -DestinationPath $extractDir

    # L'archive peut contenir le binaire a la racine ou dans un sous-dossier.
    $found = Get-ChildItem -Path $extractDir -Recurse -File -Include 'sockseek.exe', 'sockseek', 'sldl.exe' |
             Select-Object -First 1
    if (-not $found) { throw "Binaire introuvable dans l'archive $($asset.Name)." }

    Copy-Item -Path (Join-Path $found.Directory.FullName '*') -Destination $InstallDir `
              -Recurse -Force
    if (-not (Test-Path $sockExe)) {
        # release anterieure au renommage (sldl.exe, Windows uniquement)
        $old = Join-Path $InstallDir 'sldl.exe'
        if (Test-Path $old) { Rename-Item $old $sockExe -Force }
    }
    if (-not $IsWindows) {
        & chmod +x $sockExe
    }
    Write-Ok "Installe : $sockExe"
}

# ------------------------------------------------------------------ yt-dlp --
Write-Step "yt-dlp"
$ytExe = Join-Path $InstallDir $ytName

if ((Test-Path $ytExe) -and -not $Force) {
    Write-Info "Deja present. -Force pour reinstaller."
}
else {
    $asset = if ($YtDlpUrl) {
        [pscustomobject]@{ Version = 'fournie'; Name = $ytName; Url = $YtDlpUrl }
    } else {
        Get-LatestAsset -Repo 'yt-dlp/yt-dlp' -Pattern $ytPattern
    }
    Write-Info "Version $($asset.Version)"
    Invoke-WebRequest -Uri $asset.Url -OutFile $ytExe -TimeoutSec 300
    if (-not $IsWindows) {
        & chmod +x $ytExe
    }
    Write-Ok "Installe : $ytExe"
}

# -------------------------------------------------------------------- PATH --
Write-Step "PATH utilisateur"
if ($IsWindows) {
    # [Environment]::GetEnvironmentVariable(..., 'User') persiste dans le
    # registre Windows : concept propre a Windows, sans equivalent direct
    # sous Linux/macOS (voir plus bas).
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -split ';' -contains $InstallDir) {
        Write-Info "Deja present."
    }
    else {
        $newPath = ($userPath.TrimEnd(';') + ';' + $InstallDir).TrimStart(';')
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Ok "Ajoute. Les nouveaux terminaux le verront."
    }
}
else {
    # Pas de registre ici : le PATH persistant se regle dans le profil du
    # shell (~/.bashrc, ~/.zshrc, ...), specifique a chacun -- on se contente
    # donc de l'indiquer plutot que de modifier un fichier a l'aveugle.
    Write-Info "Ajoute uniquement a cette session (pas de registre sous Linux/macOS)."
    Write-Info "Pour le rendre permanent, ajoute a ton profil de shell :"
    Write-Info "  export PATH=`"$InstallDir`:`$PATH`""
}
# rend les binaires utilisables dans la session courante, sur toutes les
# plateformes -- $env:PATH (majuscules) : les variables d'environnement sont
# sensibles a la casse sous Linux/macOS, contrairement a Windows ; $env:Path
# y resterait $null (constate en le reproduisant).
$sep = [IO.Path]::PathSeparator
$env:PATH = "$($env:PATH.TrimEnd($sep))$sep$InstallDir"

# ----------------------------------------------------------- configuration --
Write-Step "Configuration"
$confDir  = Get-SockseekConfigDir
$confFile = Get-SockseekConfPath

if ($SkipCredentials) {
    Write-Info "-SkipCredentials : ni prompt, ni ecriture de sockseek.conf."
    Write-Info "Configure les identifiants separement (Set-SockseekCredentials)."
}
elseif ((Test-Path $confFile) -and -not $Force) {
    Write-Info "sockseek.conf existe deja : $confFile"
    Write-Info "-Force pour le regenerer."
}
else {
    Write-Host ""
    Write-Host "   Identifiants Soulseek." -ForegroundColor White
    Write-Host "   Le compte n'a pas besoin d'exister : le serveur enregistre" -ForegroundColor DarkGray
    Write-Host "   le pseudo a la premiere connexion. Choisis-en un peu commun," -ForegroundColor DarkGray
    Write-Host "   sinon il sera deja pris et la connexion echouera." -ForegroundColor DarkGray
    Write-Host ""

    $user = Read-Host "   Pseudo Soulseek"
    while ([string]::IsNullOrWhiteSpace($user)) {
        $user = Read-Host "   Pseudo Soulseek (obligatoire)"
    }

    $secure = Read-Host "   Mot de passe" -AsSecureString
    $pass = [Net.NetworkCredential]::new('', $secure).Password
    if ([string]::IsNullOrWhiteSpace($pass)) {
        $pass = [guid]::NewGuid().Guid.Substring(0, 16)
        Write-Info "Vide : un mot de passe aleatoire a ete genere et ecrit dans le fichier."
    }

    New-Item -ItemType Directory -Path $confDir  -Force | Out-Null
    New-Item -ItemType Directory -Path $MusicDir -Force | Out-Null

    @"
# Genere par Install-Sockseek.ps1 le $(Get-Date -Format 'yyyy-MM-dd HH:mm')
username = $user
password = $pass

output-dir = $MusicDir

# Prefere le flac, retombe sur le mp3 s'il n'y en a pas.
pref-format = flac,mp3

# Les premieres SoundCloud et les rips vinyle s'ecartent souvent de
# quelques secondes de la duree annoncee par la source.
length-tol = 10
"@ | Set-Content -Path $confFile -Encoding utf8NoBOM

    Set-DefaultOutputDir -OutputDir $MusicDir

    Write-Ok "Ecrit : $confFile"
    Write-Info "Musique : $MusicDir"
}

Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------- verifications ---
Write-Step "Verification"
$okSock = Test-Path $sockExe
$okYt   = Test-Path $ytExe
$okConf = $SkipCredentials -or (Test-Path $confFile)

Write-Host ("   sockseek      : " + $(if ($okSock) { 'OK' } else { 'MANQUANT' })) `
    -ForegroundColor $(if ($okSock) { 'Green' } else { 'Red' })
Write-Host ("   yt-dlp        : " + $(if ($okYt)   { 'OK' } else { 'MANQUANT' })) `
    -ForegroundColor $(if ($okYt)   { 'Green' } else { 'Red' })
if ($SkipCredentials) {
    Write-Host "   configuration : ignoree (-SkipCredentials)" -ForegroundColor DarkGray
}
else {
    Write-Host ("   configuration : " + $(if ($okConf) { 'OK' } else { 'MANQUANT' })) `
        -ForegroundColor $(if ($okConf) { 'Green' } else { 'Red' })
}

if ($okSock -and $okYt -and $okConf) {
    Write-Host @"

================================================================
 Termine.

 Teste la connexion Soulseek (cela creera le compte si besoin) :

   sockseek "Sciahri - Let Them Go" --song --print results

 Puis extrais une playlist :

   .\Get-SoulseekList.ps1 -Url "https://soundcloud.com/..." -Download

================================================================
"@ -ForegroundColor White
}
else {
    Write-Warning "Installation incomplete, voir les lignes ci-dessus."
    exit 1
}
