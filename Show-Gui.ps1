#Requires -Version 7.0
<#
.SYNOPSIS
    Interface graphique (Windows Forms) du kit sockseek.

.DESCRIPTION
    Quatre onglets :
      - Nouvelle playlist : extraction/nettoyage/telechargement, comme
        Get-SoulseekList.ps1.
      - Configuration : installation/mise a jour automatique des binaires
        (PATH inclus), identifiants Soulseek, dossier de destination par
        defaut.
      - Playlists : liste des playlists deja traitees (catalogue), detail de
        l'execution passee (rapport par titre) pour la playlist selectionnee,
        reprise des titres manquants.
      - Suivi d'execution : journal en direct de l'operation en cours (ou de
        la derniere terminee) ; la fenetre y bascule automatiquement des
        qu'une action longue demarre, depuis n'importe quel onglet.

    System.Windows.Forms exige un thread STA : ce script se relance lui-meme
    avec -sta s'il ne l'est pas deja (utile si quelqu'un l'execute sans passer
    par gui.bat, qui passe deja -sta).

    Get-SoulseekList.ps1, Resume-Downloads.ps1 et Install-Sockseek.ps1
    appellent `exit` : ils sont donc toujours lances comme un processus pwsh
    separe (Start-Job), jamais dot-sources ou appeles directement dans ce
    process -- un `exit` a l'interieur tuerait sinon toute la fenetre. Un seul
    job a la fois (verrou global) : ca evite aussi de lancer plusieurs
    recherches Soulseek en parallele (bannissement de 30 minutes si les
    recherches s'enchainent trop vite -- voir README).

    IMPORTANT : ecrit et relu par un modele de langage, jamais lance sur une
    vraie machine Windows -- System.Windows.Forms n'existe pas sous
    PowerShell 7 sur Linux, impossible donc de le tester en conditions
    reelles ici (la logique non graphique -- lecture du catalogue, ecriture
    de la configuration, jobs/codes de sortie -- a ete verifiee separement).
    Signale tout comportement anormal.

.EXAMPLE
    .\Show-Gui.ps1
#>

[CmdletBinding()]
param()

# --------------------------------------------------------- relance en STA --
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-STA', '-File', $PSCommandPath)) {
        $psi.ArgumentList.Add($a)
    }
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    exit $proc.ExitCode
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'SockseekLib.ps1')

$pwshExe          = (Get-Process -Id $PID).Path
$getListScript    = Join-Path $PSScriptRoot 'Get-SoulseekList.ps1'
$resumeScript     = Join-Path $PSScriptRoot 'Resume-Downloads.ps1'
$installScript    = Join-Path $PSScriptRoot 'Install-Sockseek.ps1'
$defaultInstallDir = Join-Path $env:LOCALAPPDATA 'sockseek'

# ===================================================== job en arriere-plan =
$script:activeJob        = $null
$script:activeOnComplete = $null
$script:lastExitCode     = -1
$script:busyControls     = [System.Collections.Generic.List[object]]::new()

function Set-BusyState {
    param([bool] $Busy)
    foreach ($c in $script:busyControls) { $c.Enabled = -not $Busy }
}

function Start-KitJob {
    <# Lance un script du kit dans un nouveau processus pwsh, en arriere-plan,
       et bascule sur l'onglet "Suivi d'execution" pour l'afficher au fil de
       l'eau. $OnComplete (scriptblock, avec .GetNewClosure() deja applique
       par l'appelant si necessaire) est invoque avec le code de sortie une
       fois termine. #>
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [string[]] $ScriptArgs = @(),
        [Parameter(Mandatory)] [string] $Description,
        [scriptblock] $OnComplete = {}
    )
    if ($script:activeJob) {
        [System.Windows.Forms.MessageBox]::Show(
            "Une operation est deja en cours. Attends qu'elle se termine.",
            'Kit sockseek', 'OK', 'Warning') | Out-Null
        return
    }

    $tabs.SelectedTab = $tabSuivi
    $txtLogSuivi.Clear()
    $lblSuiviStatus.Text = "En cours : $Description"
    Set-BusyState $true

    $script:lastExitCode = -1
    $script:activeOnComplete = {
        param($code)
        $lblSuiviStatus.Text = if ($code -eq 0) { "Termine sans echec : $Description" }
                               else { "Termine (code $code) : $Description" }
        & $OnComplete $code
    }.GetNewClosure()

    $script:activeJob = Start-Job -ScriptBlock {
        param($Exe, $Path, $Args)
        & $Exe -NoProfile -File $Path @Args 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ __ExitCode = $LASTEXITCODE }
    } -ArgumentList $pwshExe, $ScriptPath, $ScriptArgs
}

$jobTimer = [System.Windows.Forms.Timer]::new()
$jobTimer.Interval = 300
$jobTimer.Add_Tick({
    if (-not $script:activeJob) { return }

    foreach ($item in (Receive-Job -Job $script:activeJob)) {
        if ($item -is [pscustomobject] -and $item.PSObject.Properties.Match('__ExitCode').Count -gt 0) {
            $script:lastExitCode = $item.__ExitCode
        }
        else {
            $txtLogSuivi.AppendText(([string]$item) + [Environment]::NewLine)
        }
    }

    if ($script:activeJob.State -in @('Completed', 'Failed', 'Stopped')) {
        Remove-Job -Job $script:activeJob -Force
        $onComplete = $script:activeOnComplete
        $exitCode   = $script:lastExitCode

        $script:activeJob        = $null
        $script:activeOnComplete = $null

        Set-BusyState $false
        & $onComplete $exitCode
    }
})

# ============================================================== catalogue =
function Get-StateRows {
    $rows = foreach ($e in @(Read-Catalogue)) {
        $pending = @(Get-PlaylistPending -Entry $e)
        $done = [int]$e.Total - $pending.Count
        if ($done -lt 0) { $done = [int]$e.Ok }
        [pscustomobject]@{
            Playlist        = $e.Name
            Manquants       = $pending.Count
            'Recuperes'     = $done
            Runs            = $e.RunCount
            'Dernier essai' = if ($e.LastRun) { ([datetime]$e.LastRun).ToString('yyyy-MM-dd HH:mm') } else { '' }
            Dossier         = $e.OutputDir
        }
    }
    return , @($rows)
}

function Update-StateGrid {
    param([Parameter(Mandatory)] [System.Windows.Forms.DataGridView] $Grid)
    $Grid.DataSource = $null
    $Grid.DataSource = Get-StateRows
}

# =================================================================== UI ===
$form = [System.Windows.Forms.Form]::new()
$form.Text         = 'Kit sockseek'
$form.Width        = 950
$form.Height       = 700
$form.StartPosition = 'CenterScreen'
$form.MinimumSize  = [System.Drawing.Size]::new(750, 550)

$tabs = [System.Windows.Forms.TabControl]::new()
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)

$monoFont = [System.Drawing.Font]::new('Consolas', 9)

function New-LogBox {
    $box = [System.Windows.Forms.TextBox]::new()
    $box.Multiline  = $true
    $box.ReadOnly   = $true
    $box.ScrollBars = 'Vertical'
    $box.WordWrap   = $false
    $box.Font       = $monoFont
    $box.Dock       = 'Fill'
    $box.BackColor  = [System.Drawing.Color]::White
    return $box
}

function New-FieldRow {
    <# Une ligne Label + control dans un TableLayoutPanel a 2 colonnes. #>
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TableLayoutPanel] $Panel,
        [Parameter(Mandatory)] [int] $Row,
        [Parameter(Mandatory)] [string] $LabelText,
        [Parameter(Mandatory)] [System.Windows.Forms.Control] $Control
    )
    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text = $LabelText
    $lbl.AutoSize = $true
    $lbl.Anchor = 'Left'
    $lbl.Margin = [System.Windows.Forms.Padding]::new(3, 8, 3, 3)
    [void]$Panel.Controls.Add($lbl, 0, $Row)
    [void]$Panel.Controls.Add($Control, 1, $Row)
}

# =============================================== onglet nouvelle playlist =
$tabNew = [System.Windows.Forms.TabPage]::new('Nouvelle playlist')
$tabs.TabPages.Add($tabNew)

$topNew = [System.Windows.Forms.TableLayoutPanel]::new()
$topNew.Dock = 'Top'
$topNew.AutoSize = $true
$topNew.ColumnCount = 3
$topNew.Padding = [System.Windows.Forms.Padding]::new(8)
[void]$topNew.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize'))
[void]$topNew.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
[void]$topNew.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize'))

$txtUrl = [System.Windows.Forms.TextBox]::new()
$txtUrl.Dock = 'Fill'
New-FieldRow -Panel $topNew -Row 0 -LabelText 'URL de la playlist :' -Control $txtUrl
$topNew.SetColumnSpan($txtUrl, 2)

$grpMode = [System.Windows.Forms.GroupBox]::new()
$grpMode.Text = 'Mode'
$grpMode.AutoSize = $true
$grpMode.Width = 700
$grpMode.Height = 90
$rbTest = [System.Windows.Forms.RadioButton]::new()
$rbTest.Text = "Tester d'abord : cherche sur Soulseek, ne telecharge rien"
$rbTest.Location = [System.Drawing.Point]::new(10, 20)
$rbTest.AutoSize = $true
$rbTest.Checked = $true
$rbDownload = [System.Windows.Forms.RadioButton]::new()
$rbDownload.Text = 'Telecharger pour de vrai'
$rbDownload.Location = [System.Drawing.Point]::new(10, 45)
$rbDownload.AutoSize = $true
$rbExtract = [System.Windows.Forms.RadioButton]::new()
$rbExtract.Text = 'Extraire et nettoyer la liste seulement, sans toucher a Soulseek'
$rbExtract.Location = [System.Drawing.Point]::new(10, 70)
$rbExtract.AutoSize = $true
$grpMode.Controls.AddRange(@($rbTest, $rbDownload, $rbExtract))
[void]$topNew.Controls.Add($grpMode, 0, 1)
$topNew.SetColumnSpan($grpMode, 3)

$txtDestNew = [System.Windows.Forms.TextBox]::new()
$txtDestNew.Dock = 'Fill'
$txtDestNew.ReadOnly = $true
$txtDestNew.Text = Get-DefaultOutputDir
New-FieldRow -Panel $topNew -Row 2 -LabelText 'Dossier de destination :' -Control $txtDestNew
$lblDestHint = [System.Windows.Forms.Label]::new()
$lblDestHint.Text = '(modifiable dans Configuration)'
$lblDestHint.AutoSize = $true
$lblDestHint.ForeColor = [System.Drawing.Color]::Gray
[void]$topNew.Controls.Add($lblDestHint, 2, 2)

$btnStart = [System.Windows.Forms.Button]::new()
$btnStart.Text = 'Lancer'
$btnStart.AutoSize = $true
$btnStart.Font = [System.Drawing.Font]::new($form.Font, [System.Drawing.FontStyle]::Bold)
[void]$topNew.Controls.Add($btnStart, 1, 3)

$tabNew.AutoScroll = $true
$tabNew.Controls.Add($topNew)

$btnStart.Add_Click({
    $url = $txtUrl.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        [System.Windows.Forms.MessageBox]::Show("Colle d'abord une URL de playlist.",
            'Kit sockseek', 'OK', 'Warning') | Out-Null
        return
    }

    $modeArgs = if ($rbTest.Checked) { @('-Download', '-PrintOnly') }
                elseif ($rbDownload.Checked) { @('-Download') }
                else { @() }

    Start-KitJob -ScriptPath $getListScript -ScriptArgs (@('-Url', $url) + $modeArgs) `
        -Description "extraction de la playlist" -OnComplete {
            param($code)
            Update-StateGrid $dgvPlaylists
        }.GetNewClosure()
})

# ================================================== onglet configuration ===
$tabConfig = [System.Windows.Forms.TabPage]::new('Configuration')
$tabs.TabPages.Add($tabConfig)

$topConfig = [System.Windows.Forms.TableLayoutPanel]::new()
$topConfig.Dock = 'Top'
$topConfig.AutoSize = $true
$topConfig.ColumnCount = 3
$topConfig.Padding = [System.Windows.Forms.Padding]::new(8)
[void]$topConfig.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize'))
[void]$topConfig.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
[void]$topConfig.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize'))
$tabConfig.AutoScroll = $true
$tabConfig.Controls.Add($topConfig)

# --- etat des binaires --------------------------------------------------
$grpBinaries = [System.Windows.Forms.GroupBox]::new()
$grpBinaries.Text = 'Binaires (sockseek, yt-dlp)'
$grpBinaries.AutoSize = $true
$grpBinaries.Width = 700
$grpBinaries.Height = 90

$lblBinStatus = [System.Windows.Forms.Label]::new()
$lblBinStatus.Location = [System.Drawing.Point]::new(10, 25)
$lblBinStatus.AutoSize = $true
$lblBinStatus.Text = 'Verification...'

$btnInstall = [System.Windows.Forms.Button]::new()
$btnInstall.Text = 'Installer / mettre a jour'
$btnInstall.AutoSize = $true
$btnInstall.Location = [System.Drawing.Point]::new(10, 55)

$grpBinaries.Controls.AddRange(@($lblBinStatus, $btnInstall))
[void]$topConfig.Controls.Add($grpBinaries, 0, 0)
$topConfig.SetColumnSpan($grpBinaries, 3)

function Test-KitBinary {
    <# Cherche un binaire dans le PATH puis dans le dossier d'installation
       par defaut (%LOCALAPPDATA%\sockseek), comme le font deja
       Get-SoulseekList.ps1 et Resume-Downloads.ps1. #>
    param([string[]] $Names)
    foreach ($name in $Names) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    foreach ($name in $Names) {
        $candidate = Join-Path $defaultInstallDir "$name.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Update-BinaryStatus {
    $sock = Test-KitBinary -Names @('sockseek', 'sldl')
    $yt   = Test-KitBinary -Names @('yt-dlp')
    $sockTxt = if ($sock) { "sockseek : trouve ($sock)" } else { 'sockseek : introuvable' }
    $ytTxt   = if ($yt)   { "yt-dlp : trouve ($yt)" }     else { 'yt-dlp : introuvable' }
    $lblBinStatus.Text = "$sockTxt`r`n$ytTxt"
}

$btnInstall.Add_Click({
    Start-KitJob -ScriptPath $installScript -ScriptArgs @('-SkipCredentials') `
        -Description 'installation des binaires' -OnComplete {
            param($code)
            Update-BinaryStatus
        }.GetNewClosure()
})

# --- identifiants soulseek -----------------------------------------------
$grpCreds = [System.Windows.Forms.GroupBox]::new()
$grpCreds.Text = 'Identifiants Soulseek'
$grpCreds.AutoSize = $true
$grpCreds.Width = 700
$grpCreds.Height = 150

$lblCredsHint = [System.Windows.Forms.Label]::new()
$lblCredsHint.Location = [System.Drawing.Point]::new(10, 20)
$lblCredsHint.AutoSize = $true
$lblCredsHint.MaximumSize = [System.Drawing.Size]::new(860, 0)
$lblCredsHint.ForeColor = [System.Drawing.Color]::DimGray
$lblCredsHint.Text = "Le compte n'a pas besoin d'exister au prealable : le serveur enregistre le pseudo a la premiere connexion. Choisis-en un peu commun, sinon il sera deja pris."

$lblUser = [System.Windows.Forms.Label]::new()
$lblUser.Text = 'Pseudo :'
$lblUser.Location = [System.Drawing.Point]::new(10, 55)
$lblUser.AutoSize = $true
$txtConfUser = [System.Windows.Forms.TextBox]::new()
$txtConfUser.Location = [System.Drawing.Point]::new(90, 52)
$txtConfUser.Width = 250

$lblPass = [System.Windows.Forms.Label]::new()
$lblPass.Text = 'Mot de passe :'
$lblPass.Location = [System.Drawing.Point]::new(10, 85)
$lblPass.AutoSize = $true
$txtConfPass = [System.Windows.Forms.TextBox]::new()
$txtConfPass.Location = [System.Drawing.Point]::new(90, 82)
$txtConfPass.Width = 250
$txtConfPass.UseSystemPasswordChar = $true

$btnSaveCreds = [System.Windows.Forms.Button]::new()
$btnSaveCreds.Text = 'Enregistrer les identifiants'
$btnSaveCreds.AutoSize = $true
$btnSaveCreds.Location = [System.Drawing.Point]::new(10, 115)

$grpCreds.Controls.AddRange(@($lblCredsHint, $lblUser, $txtConfUser, $lblPass, $txtConfPass, $btnSaveCreds))
[void]$topConfig.Controls.Add($grpCreds, 0, 1)
$topConfig.SetColumnSpan($grpCreds, 3)

$btnSaveCreds.Add_Click({
    $u = $txtConfUser.Text.Trim()
    $p = $txtConfPass.Text
    if ([string]::IsNullOrWhiteSpace($u) -or [string]::IsNullOrWhiteSpace($p)) {
        [System.Windows.Forms.MessageBox]::Show('Pseudo et mot de passe sont obligatoires.',
            'Kit sockseek', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        Set-SockseekCredentials -Username $u -Password $p
        $txtConfPass.Text = ''
        [System.Windows.Forms.MessageBox]::Show('Identifiants enregistres dans sockseek.conf.',
            'Kit sockseek', 'OK', 'Information') | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Echec de l'enregistrement : $($_.Exception.Message)",
            'Kit sockseek', 'OK', 'Error') | Out-Null
    }
})

# --- dossier de destination par defaut ------------------------------------
$grpDest = [System.Windows.Forms.GroupBox]::new()
$grpDest.Text = 'Dossier de destination par defaut'
$grpDest.AutoSize = $true
$grpDest.Width = 700
$grpDest.Height = 70

$txtConfDest = [System.Windows.Forms.TextBox]::new()
$txtConfDest.Location = [System.Drawing.Point]::new(10, 25)
$txtConfDest.Width = 470
$txtConfDest.Text = Get-DefaultOutputDir

$btnConfBrowse = [System.Windows.Forms.Button]::new()
$btnConfBrowse.Text = 'Parcourir...'
$btnConfBrowse.AutoSize = $true
$btnConfBrowse.Location = [System.Drawing.Point]::new(490, 23)

$btnConfSaveDest = [System.Windows.Forms.Button]::new()
$btnConfSaveDest.Text = 'Enregistrer'
$btnConfSaveDest.AutoSize = $true
$btnConfSaveDest.Location = [System.Drawing.Point]::new(590, 23)

$grpDest.Controls.AddRange(@($txtConfDest, $btnConfBrowse, $btnConfSaveDest))
[void]$topConfig.Controls.Add($grpDest, 0, 2)
$topConfig.SetColumnSpan($grpDest, 3)

$btnConfBrowse.Add_Click({
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = 'Dossier de destination par defaut'
    if (Test-Path -LiteralPath $txtConfDest.Text) { $dlg.SelectedPath = $txtConfDest.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtConfDest.Text = $dlg.SelectedPath
    }
})

$btnConfSaveDest.Add_Click({
    $d = $txtConfDest.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($d)) { return }
    Set-DefaultOutputDir -OutputDir $d
    $txtDestNew.Text = $d
    [System.Windows.Forms.MessageBox]::Show('Dossier par defaut enregistre.',
        'Kit sockseek', 'OK', 'Information') | Out-Null
})

# ------------------------------------------------------- onglet playlists =
$tabPlaylists = [System.Windows.Forms.TabPage]::new('Playlists')
$tabs.TabPages.Add($tabPlaylists)

$splitPl = [System.Windows.Forms.SplitContainer]::new()
$splitPl.Dock = 'Fill'
$splitPl.Orientation = 'Horizontal'
$tabPlaylists.Controls.Add($splitPl)

# --- panneau du haut : liste des playlists --------------------------------
$dgvPlaylists = [System.Windows.Forms.DataGridView]::new()
$dgvPlaylists.Dock = 'Fill'
$dgvPlaylists.ReadOnly = $true
$dgvPlaylists.AllowUserToAddRows = $false
$dgvPlaylists.AllowUserToDeleteRows = $false
$dgvPlaylists.AutoSizeColumnsMode = 'Fill'
$dgvPlaylists.SelectionMode = 'FullRowSelect'
$dgvPlaylists.MultiSelect = $false

$barPlaylists = [System.Windows.Forms.FlowLayoutPanel]::new()
$barPlaylists.Dock = 'Bottom'
$barPlaylists.AutoSize = $true
$barPlaylists.Height = 50
$barPlaylists.WrapContents = $true

$btnRefreshPlaylists = [System.Windows.Forms.Button]::new()
$btnRefreshPlaylists.Text = "Actualiser la liste"
$btnRefreshPlaylists.AutoSize = $true
$btnRefreshPlaylists.Margin = [System.Windows.Forms.Padding]::new(3, 10, 3, 3)

$btnResumeAll = [System.Windows.Forms.Button]::new()
$btnResumeAll.Text = 'Reprendre tout, toutes playlists confondues'
$btnResumeAll.AutoSize = $true
$btnResumeAll.Margin = [System.Windows.Forms.Padding]::new(3, 10, 3, 3)

$btnTestSelected = [System.Windows.Forms.Button]::new()
$btnTestSelected.Text = 'Tester la playlist selectionnee'
$btnTestSelected.AutoSize = $true
$btnTestSelected.Margin = [System.Windows.Forms.Padding]::new(3, 10, 3, 3)

$btnResumeSelected = [System.Windows.Forms.Button]::new()
$btnResumeSelected.Text = 'Reprendre la playlist selectionnee'
$btnResumeSelected.AutoSize = $true
$btnResumeSelected.Margin = [System.Windows.Forms.Padding]::new(3, 10, 3, 3)

$barPlaylists.Controls.AddRange(@($btnRefreshPlaylists, $btnResumeAll, $btnTestSelected, $btnResumeSelected))

$panelPlaylistsTop = [System.Windows.Forms.Panel]::new()
$panelPlaylistsTop.Dock = 'Fill'
$panelPlaylistsTop.Controls.Add($dgvPlaylists)
$panelPlaylistsTop.Controls.Add($barPlaylists)
$splitPl.Panel1.Controls.Add($panelPlaylistsTop)

# --- panneau du bas : detail de la playlist selectionnee ------------------
$panelDetail = [System.Windows.Forms.Panel]::new()
$panelDetail.Dock = 'Fill'
$splitPl.Panel2.Controls.Add($panelDetail)

$dgvDetail = [System.Windows.Forms.DataGridView]::new()
$dgvDetail.Dock = 'Fill'
$dgvDetail.ReadOnly = $true
$dgvDetail.AllowUserToAddRows = $false
$dgvDetail.AllowUserToDeleteRows = $false
$dgvDetail.AutoSizeColumnsMode = 'Fill'

$barDetail = [System.Windows.Forms.FlowLayoutPanel]::new()
$barDetail.Dock = 'Top'
$barDetail.AutoSize = $true
$barDetail.Height = 30

$lblDetailTitle = [System.Windows.Forms.Label]::new()
$lblDetailTitle.Text = 'Selectionne une playlist ci-dessus pour voir le detail de son dernier run.'
$lblDetailTitle.AutoSize = $true
$lblDetailTitle.Margin = [System.Windows.Forms.Padding]::new(3, 8, 3, 3)

$btnOpenLog = [System.Windows.Forms.Button]::new()
$btnOpenLog.Text = 'Ouvrir le journal'
$btnOpenLog.AutoSize = $true
$btnOpenLog.Enabled = $false
$btnOpenLog.Margin = [System.Windows.Forms.Padding]::new(15, 3, 3, 3)

$barDetail.Controls.AddRange(@($lblDetailTitle, $btnOpenLog))

$panelDetail.Controls.Add($dgvDetail)
$panelDetail.Controls.Add($barDetail)

$script:selectedPlaylistLogPath = $null

function Update-PlaylistDetail {
    param($SelectedRow)

    $dgvDetail.DataSource = $null
    $btnOpenLog.Enabled = $false
    $script:selectedPlaylistLogPath = $null

    if (-not $SelectedRow) {
        $lblDetailTitle.Text = 'Selectionne une playlist ci-dessus pour voir le detail de son dernier run.'
        return
    }

    $row = $SelectedRow.DataBoundItem
    $dossier = $row.Dossier
    $lblDetailTitle.Text = "Playlist : $($row.Playlist)  --  $dossier"

    $rapportPath = Join-Path $dossier 'rapport.csv'
    if (Test-Path -LiteralPath $rapportPath) {
        $dgvDetail.DataSource = , @(Import-Csv -LiteralPath $rapportPath)
    }

    $latestLog = Get-ChildItem -LiteralPath $dossier -Filter 'sockseek-*.log' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestLog) {
        $script:selectedPlaylistLogPath = $latestLog.FullName
        $btnOpenLog.Enabled = $true
    }
}

$dgvPlaylists.Add_SelectionChanged({
    if ($dgvPlaylists.SelectedRows.Count -gt 0) {
        Update-PlaylistDetail -SelectedRow $dgvPlaylists.SelectedRows[0]
    }
    else {
        Update-PlaylistDetail -SelectedRow $null
    }
})

$btnOpenLog.Add_Click({
    if ($script:selectedPlaylistLogPath) {
        try { Start-Process -FilePath $script:selectedPlaylistLogPath }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Impossible d'ouvrir le journal : $($_.Exception.Message)",
                'Kit sockseek', 'OK', 'Error') | Out-Null
        }
    }
})

$btnRefreshPlaylists.Add_Click({
    Update-StateGrid $dgvPlaylists
    Update-PlaylistDetail -SelectedRow $null
})

$btnResumeAll.Add_Click({
    Start-KitJob -ScriptPath $resumeScript -Description 'reprise de toutes les playlists' -OnComplete {
        param($code)
        Update-StateGrid $dgvPlaylists
    }.GetNewClosure()
})

function Get-SelectedPlaylistName {
    if ($dgvPlaylists.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Selectionne une playlist dans la liste.',
            'Kit sockseek', 'OK', 'Warning') | Out-Null
        return $null
    }
    return $dgvPlaylists.SelectedRows[0].DataBoundItem.Playlist
}

$btnTestSelected.Add_Click({
    $name = Get-SelectedPlaylistName
    if (-not $name) { return }
    Start-KitJob -ScriptPath $resumeScript -ScriptArgs @('-Only', $name, '-DryRun') `
        -Description "test de la playlist '$name'"
})

$btnResumeSelected.Add_Click({
    $name = Get-SelectedPlaylistName
    if (-not $name) { return }
    Start-KitJob -ScriptPath $resumeScript -ScriptArgs @('-Only', $name) `
        -Description "reprise de la playlist '$name'" -OnComplete {
            param($code)
            Update-StateGrid $dgvPlaylists
        }.GetNewClosure()
})

# --------------------------------------------------- onglet suivi execution
$tabSuivi = [System.Windows.Forms.TabPage]::new("Suivi d'execution")
$tabs.TabPages.Add($tabSuivi)

$lblSuiviStatus = [System.Windows.Forms.Label]::new()
$lblSuiviStatus.Dock = 'Top'
$lblSuiviStatus.AutoSize = $false
$lblSuiviStatus.Height = 24
$lblSuiviStatus.Padding = [System.Windows.Forms.Padding]::new(6)
$lblSuiviStatus.Text = "Pret. Rien n'a encore ete lance."

$txtLogSuivi = New-LogBox

$tabSuivi.Controls.Add($txtLogSuivi)
$tabSuivi.Controls.Add($lblSuiviStatus)

# ------------------------------------------------------- boutons a verrouiller
$script:busyControls.AddRange(@(
    $btnStart, $btnInstall,
    $btnRefreshPlaylists, $btnResumeAll, $btnTestSelected, $btnResumeSelected
))

# ---------------------------------------------------------------- demarrage
Update-BinaryStatus
Update-StateGrid $dgvPlaylists
Update-PlaylistDetail -SelectedRow $null
$splitPl.SplitterDistance = [int]($form.Height * 0.4)

$jobTimer.Start()
$form.Add_FormClosed({ $jobTimer.Stop() })

[void][System.Windows.Forms.Application]::Run($form)
