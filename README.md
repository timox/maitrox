# Kit sockseek — playlists SoundCloud vers Soulseek

Récupère une playlist SoundCloud ou YouTube, nettoie les métadonnées, télécharge
ce qui existe sur Soulseek, et produit une playlist M3U des fichiers réellement
obtenus avec un rapport détaillé de ce qui a échoué et pourquoi.

## Contenu

| Fichier | Rôle |
|---|---|
| `installer.bat` | **Double-clic : installe tout** |
| `gui.bat` | **Double-clic : interface graphique** — trouve `pwsh` et lance `Show-Gui.ps1` |
| `lancer.bat` | Double-clic : menu console (nouvelle playlist, reprise, état) — trouve `pwsh` et lance `Menu.ps1` |
| `reprendre.bat` | Double-clic : va direct au menu de reprise console, sans passer par celui de `lancer.bat` |
| `Show-Gui.ps1` | L'interface graphique elle-même (Windows Forms) |
| `Menu.ps1` | Le menu interactif console ; tout le cheminement (retours, sortie) y vit |
| `Install-Sockseek.ps1` | Télécharge les binaires, crée la configuration, règle le PATH |
| `Get-SoulseekList.ps1` | Extraction, nettoyage, téléchargement, rapport |
| `Build-Playlist.ps1` | Rapport et playlist seuls, réutilisable après un run manuel |
| `Resume-Downloads.ps1` | Reprise groupée des titres manquants, toutes playlists |
| `SockseekLib.ps1` | Fonctions partagées, pas destiné à être lancé seul |

Si tu n'as pas envie de toucher à une ligne de commande, double-clic sur
`installer.bat` une fois, puis sur `gui.bat` pour tout le reste : une
fenêtre avec quatre onglets (Nouvelle playlist, Configuration, Playlists,
Suivi d'exécution — détail plus bas). `lancer.bat` propose la même chose en
mode texte dans une console, pour qui préfère ça ou travaille par SSH. Le
reste de ce document décrit ce que ces outils font et comment piloter les
scripts directement.

### Interface graphique (`gui.bat`)

Quatre onglets :

- **Nouvelle playlist** — colle une URL, choisis le mode (tester / télécharger
  / extraire seulement) et lance. Bascule automatiquement sur l'onglet Suivi
  d'exécution pour montrer la progression.
- **Configuration** — installe ou met à jour sockseek et yt-dlp (PATH inclus)
  en un clic, sans invite bloquante ; identifiants Soulseek (écrits
  directement dans `sockseek.conf`, en préservant tes réglages existants) ;
  dossier de destination par défaut.
- **Playlists** — liste des playlists déjà traitées (le catalogue), avec le
  détail du dernier run pour celle sélectionnée (le `rapport.csv` par titre,
  et un bouton pour ouvrir le journal complet) ; boutons pour tester ou
  reprendre la playlist sélectionnée, ou tout reprendre d'un coup.
- **Suivi d'exécution** — le journal en direct de l'opération en cours (ou de
  la dernière terminée). Une seule opération à la fois : lancer une nouvelle
  action pendant qu'une autre tourne est refusé, exactement pour la même
  raison que le kit ne lance jamais deux recherches Soulseek en parallèle
  (voir plus bas).

⚠️ **Non testée en conditions réelles.** Cette interface a été écrite et
relue par un modèle de langage sans jamais tourner sur une vraie machine
Windows : `System.Windows.Forms` n'existe pas sous PowerShell 7 sur Linux,
il n'y avait donc aucun moyen de l'exécuter pendant son développement. La
logique non graphique qu'elle réutilise (lecture du catalogue, écriture de
la configuration, gestion des jobs et codes de sortie) a été vérifiée
séparément et fonctionne, mais la fenêtre elle-même — mise en page,
événements, tout ce qui dépend réellement de Windows Forms — n'a pas pu
l'être. Si quelque chose se comporte mal, dis-le : ça se corrige vite une
fois le symptôme connu. En cas de souci bloquant, `lancer.bat` (menu
console) offre exactement les mêmes actions.

## Prérequis

PowerShell 7 ou plus. Windows PowerShell 5.1 ne suffit pas : le kit utilise
l'encodage `utf8NoBOM` et `[IO.Path]::GetRelativePath`, absents de la 5.1.

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Ensuite, ouvre **pwsh** (pas `powershell.exe`, ni ISE — ISE est resté bloqué
sur 5.1 et ne sera jamais porté).

## Installation

Double-clique sur **`installer.bat`**, ou en ligne de commande :

```powershell
cd <dossier-du-kit>
pwsh -File .\Install-Sockseek.ps1
```

L'installateur enchaîne :

1. Passe la politique d'exécution à `Unrestricted` pour l'utilisateur courant.
2. Résout la dernière release de `fiso64/sockseek`, télécharge l'archive
   `win-x64`, extrait le binaire vers `%LOCALAPPDATA%\sockseek`.
3. Fait de même pour `yt-dlp.exe`.
4. Ajoute le dossier au PATH utilisateur (pas machine : aucune élévation requise).
5. Demande tes identifiants Soulseek et écrit `%APPDATA%\sockseek\sockseek.conf`.

Options utiles :

```powershell
.\Install-Sockseek.ps1 -InstallDir "D:\Outils\sockseek" -MusicDir "D:\Music\techno"
.\Install-Sockseek.ps1 -Force                  # réinstalle et régénère la config
.\Install-Sockseek.ps1 -SkipExecutionPolicy    # ne touche pas à la politique
```

Rouvre un terminal après l'installation : le PATH n'est relu qu'au démarrage
d'un processus.

### À propos du compte Soulseek

Il n'y a pas d'inscription préalable. Le serveur Soulseek enregistre un pseudo
à la première connexion : le compte est donc créé automatiquement quand
sockseek se connecte. Deux conséquences pratiques.

Si le pseudo que tu choisis est déjà pris par quelqu'un d'autre, la connexion
sera refusée — prends-en un peu commun. Et si tu fais tourner Nicotine+ ou
slskd en parallèle, utilise un **second compte** pour sockseek : deux sessions
simultanées sur le même pseudo provoquent des problèmes de connexion.

Vérifie que ça passe avant d'aller plus loin :

```powershell
sockseek "Sciahri - Let Them Go" --song --print results
```

### À propos de la politique d'exécution

`Unrestricted` exécute n'importe quel script sans avertissement, y compris ceux
téléchargés depuis Internet. `RemoteSigned` suffirait pour ce kit et reste plus
prudent — il n'exige une signature que pour les fichiers marqués comme venant
du web :

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

L'installateur applique `Unrestricted` par défaut ; `-SkipExecutionPolicy` le
laisse tranquille.

## Utilisation

Double-clique sur **`lancer.bat`** et choisis « Traiter une nouvelle
playlist ». Il demande l'URL, puis propose trois modes : tester sans rien télécharger (le défaut), télécharger
pour de vrai, ou seulement extraire et nettoyer la liste. Il accepte aussi une
URL en argument, ce qui permet d'en faire un raccourci.

Pour les deux premiers modes, il rappelle le **dossier de destination actuel**
et permet de le remplacer : laisse le champ vide pour le conserver, ou tape un
nouveau chemin pour en faire le nouveau défaut — il est alors mémorisé et
réutilisé automatiquement à chaque lancement suivant, y compris sans repasser
par le menu (`%APPDATA%\sockseek\prefs.json`). À l'installation, le dossier
choisi via `-MusicDir` devient ce défaut initial.

En ligne de commande, extraction et nettoyage seuls, pour inspecter le CSV avant d'engager quoi que
ce soit :

```powershell
.\Get-SoulseekList.ps1 -Url "https://soundcloud.com/loleanto/sets/sans-retour-short"
```

Voir ce que Soulseek renverrait, sans rien télécharger :

```powershell
.\Get-SoulseekList.ps1 -Url $url -Download -PrintOnly
```

Pour de vrai :

```powershell
.\Get-SoulseekList.ps1 -Url $url -Download -OutputDir "D:\Music\techno"
```

Passer `-OutputDir` explicitement, comme ci-dessus, met aussi a jour le
defaut retenu pour les prochains lancements — c'est ce que fait `lancer.bat`
quand tu tapes un nouveau chemin dans son menu.

### Paramètres

| Paramètre | Effet |
|---|---|
| `-Url` | Playlist SoundCloud ou YouTube (obligatoire) |
| `-Out` | CSV nettoyé (défaut `playlist-clean.csv`) |
| `-RawOut` | Écrit aussi le CSV brut, pour comparer |
| `-Download` | Enchaîne sur sockseek |
| `-PrintOnly` | Avec `-Download` : recherche seule |
| `-OutputDir` | Dossier de destination ; omis, reprend le défaut retenu (voir plus haut). Passé explicitement, devient le nouveau défaut |
| `-SockseekPath` | Chemin du binaire si absent du PATH |
| `-Credential` | Identifiants explicites, en dépannage |

### Un sous-dossier par playlist

Chaque playlist télécharge dans son propre sous-dossier, nommé d'après son
titre (nettoyé des caractères invalides pour un chemin Windows), à
l'intérieur du dossier de destination ci-dessus. Deux sets ne se mélangent
jamais sur le disque : `D:\Music\techno\Sans retour - Phoen V\`,
`D:\Music\techno\Deep House Essentials\`, etc. — chacun avec son propre
`rapport.csv`, `playlist.m3u` et journal. `-OutputDir` (ou le défaut retenu)
désigne donc le dossier **parent** commun à toutes les playlists, pas le
dossier final.

## Ce qui est nettoyé

Les exports SoundCloud sont sales, et c'est là que se joue le taux de réussite.
Le champ `uploader` est le nom de la chaîne ou du label, pas l'artiste : sur un
set typique, une trentaine de titres ont leur véritable artiste caché dans le
titre. « BCCO Premiere: Mislaw - Fourth Siren [THEIA001] » doit devenir artiste
`Mislaw`, titre `Fourth Siren`, sans quoi la recherche part sur « BCCO ».

Sont retirés : préfixes de premiere sous toutes leurs formes, codes catalogue
entre crochets, mentions de téléchargement libre, `(Original Mix)`, positions
vinyle en tête (`A2 Deluka`), suffixes `, by Artiste`. Les polices fantaisie
Unicode sont normalisées.

Sont **conservés** : les noms de remix `(Kr!z Remix)`, discriminants pour la
recherche, et les durées, qui servent de filtre.

La colonne `Review` du CSV signale les cas douteux : `TRONQUE` pour les titres
coupés à l'export, `artiste=chaine` quand aucun artiste n'a pu être extrait.

## Suivi des échecs

À la fin d'un run, `Build-Playlist.ps1` confronte l'index sockseek au disque.
La vérité vient du disque : un fichier absent est un échec même si l'index le
dit téléchargé. L'index ne sert qu'à retrouver la cause.

Chaque échec est classé :

| Catégorie | Signification | Piste |
|---|---|---|
| Introuvable sur Soulseek | Aucun résultat | Le morceau n'y est pas ; `--yt-dlp` en repli |
| Filtre par les conditions | Des résultats, mais aucun conforme | Assouplir `--length-tol`, `--format` |
| Problème réseau ou pair injoignable | Le pair a lâché | Relancer, ça repart souvent |
| Fichier absent du disque | Index optimiste | Fichier déplacé ou supprimé après coup |
| Jamais traité | Absent de l'index | Run interrompu |
| Annulé | Recherche interrompue côté sockseek | Relancer |
| Échec (cause non précisée) | L'index marque l'échec sans motif exploitable | Voir le journal détaillé |

Deux fichiers sont produits dans le dossier de sortie : `rapport.csv` avec le
détail par titre, et `sockseek-<horodatage>.log` pour le journal brut.

Relancer l'analyse seule après un run manuel :

```powershell
.\Build-Playlist.ps1 -OutputDir "D:\Music\techno" -SourceCsv playlist-clean.csv
```

Code de sortie 0 si tout est passé, 10 s'il reste des échecs — exploitable en
tâche planifiée.

## Reprise des titres manquants

C'est là que se rattrape l'essentiel des échecs. Soulseek est un réseau P2P :
un morceau introuvable aujourd'hui parce que la seule personne qui le partage
est hors ligne sera peut-être là demain. Relancer ne coûte presque rien et
récupère régulièrement quelques titres de plus, sans changer un seul réglage.

Chaque run avec `-Download` inscrit la playlist dans un catalogue
(`%APPDATA%\sockseek\catalogue.json`). La reprise le relit, recalcule ce qui
manque pour chacune, regroupe par dossier de destination et relance sockseek
un flux a la fois (chaque playlist ayant son propre sous-dossier, ça revient
en general a une passe par playlist).

Ce regroupement n'est pas cosmétique. Le serveur bannit 30 minutes si les
recherches s'enchaînent trop vite : un flux unique et régulier par dossier
vaut mieux que plusieurs relances concurrentes.

Double-clique sur **`lancer.bat`** et choisis « Reprendre les titres
manquants » (ou directement sur **`reprendre.bat`**, qui saute droit à ce
menu). Le menu de reprise affiche d'abord l'état actuel, puis propose de
voir la liste avant de relancer, de tout reprendre, ou de ne reprendre
qu'une playlist en particulier (la seule granularité disponible : le script
filtre par playlist, pas titre par titre) — avec, à chaque étape, un retour
possible au menu de reprise ou au menu principal plutôt qu'une sortie
immédiate. En ligne de commande :

```powershell
.\Resume-Downloads.ps1 -List      # état des playlists, sans rien relancer
.\Resume-Downloads.ps1 -DryRun    # ce qui serait repris
.\Resume-Downloads.ps1            # reprise réelle
```

Filtrer sur une seule playlist :

```powershell
.\Resume-Downloads.ps1 -Only "sans-retour"
```

Retirer une playlist du catalogue (les fichiers déjà téléchargés ne sont pas
touchés) :

```powershell
.\Resume-Downloads.ps1 -Only "sans-retour" -Forget
```

Après chaque reprise, les playlists M3U et les rapports concernés sont
régénérés, et le catalogue met à jour son compte de titres récupérés.

Ne t'acharne pas le même jour : si une reprise ne ramène rien, laisse passer
quelques jours et réessaie à une heure où davantage de pairs sont connectés.

## Playlist M3U

`playlist.m3u` est écrite dans le dossier de sortie, au format M3U étendu
(`#EXTINF` avec durée et libellé), avec des **chemins relatifs** : le dossier
reste transportable vers une clé USB ou un autre disque sans casser la
playlist. Seuls les fichiers réellement présents y figurent.

Le fichier est en UTF-8 sans BOM. C'est formellement du M3U8, mais VLC,
foobar2000 et Rekordbox le lisent sans difficulté sous l'extension `.m3u`.

## Attentes réalistes

Sur un set fait de premières de labels confidentiels et de free DL Bandcamp,
le taux de réussite sera bas — ce répertoire ne circule pas beaucoup sur
Soulseek. Fais toujours un `-PrintOnly` d'abord.

Côté durée : le serveur bannit 30 minutes si les recherches s'enchaînent trop
vite, et le limiteur intégré autorise 34 recherches par 220 secondes. Pour 80
titres, compte une dizaine de minutes au minimum. Ne touche pas à
`--searches-per-time`.

## Tests

La logique de nettoyage des titres (`Normalize-Text`, `Clean-Title`,
`Convert-Entry`, dans `SockseekLib.ps1`) est couverte par des tests Pester
dans `tests/SockseekLib.Tests.ps1` — pratique pour vérifier qu'une regex
retouchée ne casse pas un cas déjà géré.

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0   # une fois
Invoke-Pester .\tests\SockseekLib.Tests.ps1
```

## Dépannage

**`yt-dlp est introuvable dans le PATH`** — rouvre le terminal après
l'installation, ou passe par `-SockseekPath` pour sockseek.

**`Aucun fichier sockseek.conf trouve`** — relance l'installateur, ou crée le
fichier à la main dans `%APPDATA%\sockseek\`.

**La connexion Soulseek échoue** — pseudo déjà pris, ou déjà utilisé par un
autre client ouvert en parallèle.

**`L'API GitHub refuse la requete (code 403)`** — quota GitHub atteint : 60
requêtes par heure et par IP sans authentification, partagé avec tout le
réseau derrière un NAT d'entreprise. Attends une heure, ou récupère les URL à
la main sur les pages de releases et passe-les à l'installateur :

```powershell
.\Install-Sockseek.ps1 `
   -SockseekUrl "https://github.com/.../sockseek_3.0.5_win-x64.zip" `
   -YtDlpUrl    "https://github.com/.../yt-dlp.exe"
```

**Beaucoup de « Filtre par les conditions »** — tes conditions sont trop
strictes pour ce répertoire. Retire `pref-format = flac` de la configuration,
ou augmente `length-tol`.
