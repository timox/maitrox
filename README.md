# Kit sockseek — playlists SoundCloud vers Soulseek

Récupère une playlist SoundCloud ou YouTube, nettoie les métadonnées, télécharge
ce qui existe sur Soulseek, et produit une playlist M3U des fichiers réellement
obtenus avec un rapport détaillé de ce qui a échoué et pourquoi.

## Contenu

Tout tourne sur [Node.js](https://nodejs.org/) seul, sans aucune dépendance
à installer (`npm install` n'est pas nécessaire) — même moteur que
l'interface web, sur Windows comme sur Linux/macOS.

## Un seul script : `installer.bat` / `installer.sh`

**C'est le seul script à lancer, à chaque fois** — premier lancement comme
tous les suivants. Double-clic sur `installer.bat` (Windows) ou
`./installer.sh` (Linux/macOS) et il enchaîne, sans rien d'autre à taper :

1. Met à jour le code du kit lui-même (`git pull`, si le dossier est un
   clone git — sans effet sinon, ni sans réseau : il continue avec le code
   déjà présent plutôt que de bloquer).
2. Installe ou met à jour `sockseek` et `yt-dlp`, et la configuration
   (`bin/install.js`) — en best-effort : une panne ici (quota GitHub, pas de
   réseau) n'empêche pas la suite.
3. Démarre l'interface web (`http://localhost:8342`, ouverte automatiquement
   dans le navigateur) — c'est là que tout le reste se pilote.

Un seul script, un seul réflexe en cas de doute : **relance
`installer.bat`/`installer.sh`**. S'il te dit que le port est déjà utilisé,
c'est qu'une instance tourne déjà quelque part (une fenêtre restée ouverte,
un ancien processus) — ferme-la avant de relancer ; le message te le dit
explicitement plutôt que de planter avec une pile d'erreurs illisible.

| Fichier | Rôle |
|---|---|
| `installer.bat` / `installer.sh` | **Le seul script à utiliser** : met à jour le code, installe/met à jour les binaires, démarre l'interface web |
| `webgui/server.js` | Le serveur de l'interface graphique |
| `webgui/public/` | Page web de l'interface (HTML/CSS/JS) |
| `webgui.bat` / `webgui.sh` | Redémarre juste le serveur web, sans repasser par la mise à jour/l'installation — pratique une fois que tout est déjà en place |
| `lancer.bat` / `lancer.sh` | Menu console (nouvelle playlist, reprise, état) — lance `bin/menu.js`, pour qui préfère le texte ou travaille par SSH |
| `reprendre.bat` / `reprendre.sh` | Va direct au menu de reprise console, sans passer par celui de `lancer.bat` |
| `bin/menu.js` | Le menu interactif console ; tout le cheminement (retours, sortie) y vit |
| `bin/install.js` | Télécharge les binaires, crée la configuration, règle le PATH |
| `bin/extract.js` | Extraction, nettoyage, téléchargement, rapport |
| `bin/build-playlist.js` | Rapport et playlist seuls, réutilisable après un run manuel |
| `bin/resume.js` | Reprise groupée des titres manquants, toutes playlists |
| `lib/` | Fonctions partagées (nettoyage des titres, catalogue, index sockseek, installation) |
| `powershell-legacy/` | Ancien kit PowerShell (archive, non maintenu) — voir son propre README |

### Interface graphique

L'interface s'ouvre automatiquement dans le navigateur après
`installer.bat`/`installer.sh`, sur `http://localhost:8342`. Toute la
logique (nettoyage des titres, catalogue, invocation de sockseek/yt-dlp)
vit dans `lib/` — le serveur Node ne fait que la piloter et afficher le
résultat dans une page web, ce qui la rend utilisable aussi bien sous
Windows que sous Linux.

Quatre onglets :

- **Nouvelle playlist** — colle une URL, choisis le mode (tester / télécharger
  / extraire seulement) et lance. Bascule automatiquement sur l'onglet Suivi
  d'exécution pour montrer la progression.
- **Configuration** — installe ou met à jour sockseek et yt-dlp (PATH inclus)
  en un clic, sans invite bloquante, avec vérification de version disponible
  sur demande (bouton séparé, appelle l'API GitHub) ; identifiants Soulseek
  (écrits directement dans `sockseek.conf`, en préservant tes réglages
  existants), avec rappel du pseudo déjà enregistré s'il y en a un ; dossier
  de destination par défaut, avec un bouton pour l'ouvrir directement dans
  l'explorateur de fichiers ; import d'un dossier de téléchargement existant
  (déplacé à la main, ou téléchargé avant l'existence du catalogue
  centralisé) — retrouve son `_index.csv` (ou balaie les fichiers audio s'il
  n'y en a pas), **déplace le dossier vers la destination par défaut**
  ci-dessus pour recentraliser les téléchargements éparpillés, puis
  l'enregistre dans le catalogue sans rien retélécharger. Si un dossier du
  même nom existe déjà à destination (playlist déjà en partie centralisée),
  fusionne fichier par fichier sans jamais écraser un fichier existant — un
  fichier en conflit (même nom aux deux emplacements) reste à son
  emplacement d'origine plutôt que d'être perdu. Réimporter une playlist déjà
  centralisée (ou sous le même nom) met simplement à jour l'entrée existante
  au lieu d'en créer une seconde.
- **Playlists** — liste des playlists déjà traitées (le catalogue), avec le
  détail du dernier run pour celle sélectionnée (le `rapport.csv` par titre,
  un bouton pour ouvrir le journal complet, et un bouton pour ouvrir son
  dossier de téléchargement dans l'explorateur de fichiers) ; boutons pour
  tester ou reprendre la playlist sélectionnée, tout reprendre d'un coup, ou
  supprimer la playlist sélectionnée (au choix : juste l'entrée du catalogue,
  ou l'entrée et ses fichiers téléchargés — demande confirmation dans les
  deux cas, la suppression des fichiers étant irréversible).
- **Suivi d'exécution** — le journal en direct de l'opération en cours (ou de
  la dernière terminée), avec un bouton **Arrêter l'opération en cours**
  (demande confirmation, puis tue tout de suite le processus et ses
  éventuels sous-processus). Une seule opération à la fois : lancer une
  nouvelle action pendant qu'une autre tourne est refusé, exactement pour la
  même raison que le kit ne lance jamais deux recherches Soulseek en
  parallèle (voir plus bas) — tant qu'aucune opération n'est en cours, ce
  bouton reste grisé. Un arrêt en cours de route interrompt les
  téléchargements entamés (les fichiers déjà complets restent utilisables,
  sockseek reprendra le reste au prochain lancement).

⚠️ **Testée côté serveur, pas encore dans un vrai navigateur.** Le serveur
Node (`webgui/server.js`) a été lancé pour de vrai pendant son développement,
avec de vraies requêtes HTTP contre chaque route (statut des binaires,
catalogue, import/déplacement/fusion de dossier, suppression, et le cycle
complet démarrage/journal en direct/arrêt d'un job — y compris la
terminaison forcée de l'arbre de processus, vérifiée en la reproduisant
directement). La page web elle-même (`webgui/public/`), en revanche, n'a
jamais été ouverte dans un vrai navigateur ni cliquée pour de vrai : mise en
page, comportement exact des boutons/formulaires, tout ce qui ne s'observe
que visuellement reste à confirmer en conditions réelles. Si quelque chose
se comporte mal, dis-le : ça se corrige vite une fois le symptôme connu. En
cas de souci bloquant, `lancer.bat` (menu console) offre exactement les
mêmes actions.

## Prérequis

[Node.js](https://nodejs.org/) (n'importe quelle version récente, 18+).
Rien d'autre à installer avec `npm` — tout le kit n'utilise que ce que Node
fournit déjà, `tar` (déjà présent sous Linux/macOS, et sous Windows 10
1803+) pour extraire les archives de sockseek/yt-dlp, et une connexion
sortante vers GitHub pour les récupérer.

## Installation

Double-clique sur **`installer.bat`** (Windows) ou lance `./installer.sh`
(Linux/macOS) — voir « Un seul script » plus haut. En ligne de commande,
les mêmes options passent directement à travers :

```sh
cd <dossier-du-kit>
./installer.sh
```

Il enchaîne :

1. Met à jour le code du kit (`git pull`, best-effort).
2. Résout la dernière release de `fiso64/sockseek` pour la plateforme
   courante (`win-x64`, `linux-x64` ou `osx-x64`), extrait le binaire vers
   `%LOCALAPPDATA%\sockseek` (Windows) ou `~/.local/share/sockseek`
   (Linux/macOS), et le rend exécutable (`chmod +x`) hors Windows.
3. Fait de même pour `yt-dlp` (`yt-dlp.exe`, `yt-dlp_linux` ou `yt-dlp_macos`
   selon la plateforme).
4. Ajoute le dossier d'installation au `PATH` de la session courante, et
   affiche la ligne à ajouter à ton profil de shell (Linux/macOS) ou à tes
   variables d'environnement (Windows) pour que ce soit permanent.
5. Demande tes identifiants Soulseek et écrit `sockseek.conf` (dans
   `%APPDATA%\sockseek` sous Windows, `~/.config/sockseek` ailleurs).
6. Démarre l'interface web.

Options utiles (transmises telles quelles à `bin/install.js`) :

```sh
./installer.sh -InstallDir "/opt/sockseek" -MusicDir "/data/techno"
./installer.sh -Force                  # reinstalle sockseek/yt-dlp (sans toucher a sockseek.conf)
./installer.sh -ForceCredentials       # regenere sockseek.conf (ecrase le mot de passe enregistre)
```

`-Force` et `-ForceCredentials` sont volontairement deux options distinctes :
la première ne touche jamais aux identifiants déjà enregistrés — sans elle,
`sockseek.conf` existant est **toujours laissé intact**. `-ForceCredentials`
prévient explicitement avant d'écraser, et sauvegarde l'ancien fichier
(`sockseek.conf.bak-<horodatage>`) avant de le remplacer.

### À propos du compte Soulseek

Il n'y a pas d'inscription préalable. Le serveur Soulseek enregistre un pseudo
à la première connexion : le compte est donc créé automatiquement quand
sockseek se connecte. Deux conséquences pratiques.

Si le pseudo que tu choisis est déjà pris par quelqu'un d'autre, la connexion
sera refusée — prends-en un peu commun. Et si tu fais tourner Nicotine+ ou
slskd en parallèle, utilise un **second compte** pour sockseek : deux sessions
simultanées sur le même pseudo provoquent des problèmes de connexion.

Vérifie que ça passe avant d'aller plus loin :

```sh
sockseek "Sciahri - Let Them Go" --song --print results
```

## Utilisation

Double-clique sur **`lancer.bat`** (ou lance `./lancer.sh`) et choisis
« Traiter une nouvelle playlist ». Il demande l'URL, puis propose trois modes : tester sans rien télécharger (le défaut), télécharger
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

```sh
node bin/extract.js -Url "https://soundcloud.com/loleanto/sets/sans-retour-short"
```

Voir ce que Soulseek renverrait, sans rien télécharger :

```sh
node bin/extract.js -Url "$url" -Download -PrintOnly
```

Pour de vrai :

```sh
node bin/extract.js -Url "$url" -Download -OutputDir "/data/techno"
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
| `-CookiesFromBrowser` | Pour les sets privés/réservés aux abonnés SoundCloud (voir plus bas) |

### Sets privés SoundCloud

Un lien « non listé » (avec `?secret_token=...`) n'a besoin de rien de
spécial : yt-dlp le gère déjà tout seul. Pour un set réellement privé
(réservé aux abonnés, ou visible seulement une fois connecté), SoundCloud
n'accepte pas de simple identifiant/mot de passe côté yt-dlp — un
`--username`/`--password` classique échoue avec une erreur explicite côté
yt-dlp. La seule option qui fonctionne est de réutiliser la session d'un
navigateur où tu es déjà connecté :

```sh
node bin/extract.js -Url "$url" -CookiesFromBrowser firefox
```

Valeurs acceptées : `brave`, `chrome`, `chromium`, `edge`, `firefox`,
`opera`, `safari`, `vivaldi`, `whale` — un **nom**, pas un chemin vers
l'exécutable : yt-dlp retrouve tout seul le dossier de profil du
navigateur. Sur certains navigateurs, le fichier de cookies est verrouillé
tant que le navigateur est ouvert ; ferme-le si l'extraction échoue.
L'interface graphique propose la même option dans l'onglet « Nouvelle
playlist ».

### Téléchargement direct des titres en libre téléchargement

Certains morceaux SoundCloud proposent un vrai bouton « Télécharger » —
l'artiste a explicitement autorisé le téléchargement du fichier original,
en plus de l'écoute en streaming. yt-dlp sait le détecter et le récupérer
directement, sans passer par Soulseek. `-Download` s'en sert
automatiquement : pour chaque titre proposant ce téléchargement libre, le
fichier original est téléchargé directement via yt-dlp (avec
`-CookiesFromBrowser` si fourni, utile pour les titres qui exigent d'être
connecté) ; seuls les titres restants (pas de téléchargement libre, ou
téléchargement direct en échec) partent en recherche sur Soulseek. Si tous
les titres d'une playlist sont récupérés directement, sockseek n'est même
pas lancé. `-PrintOnly` ignore ce mécanisme (il ne fait que prévisualiser
la recherche Soulseek, rien n'est téléchargé dans les deux cas).

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

À la fin d'un run, `bin/build-playlist.js` confronte l'index sockseek au disque.
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

```sh
node bin/build-playlist.js -OutputDir "/data/techno" -SourceCsv playlist-clean.csv
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

```sh
node bin/resume.js -List      # état des playlists, sans rien relancer
node bin/resume.js -DryRun    # ce qui serait repris
node bin/resume.js            # reprise réelle
```

Filtrer sur une seule playlist :

```sh
node bin/resume.js -Only "sans-retour"
```

Retirer une playlist du catalogue (les fichiers déjà téléchargés ne sont pas
touchés) :

```sh
node bin/resume.js -Only "sans-retour" -Forget
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

La logique de nettoyage des titres (`normalizeText`, `cleanTitle`,
`convertEntry`, dans `lib/text.js`) et l'analyse des résultats de run
(`lib/runResults.js`, `lib/catalogue.js`) sont couvertes par des tests dans
`tests/*.test.js` (runtime de test intégré à Node, aucune dépendance) —
pratique pour vérifier qu'une regex retouchée ne casse pas un cas déjà géré.

```sh
npm test
# equivalent : node --test tests/*.test.js
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

```sh
node bin/install.js \
   -SockseekUrl "https://github.com/.../sockseek_3.0.5_win-x64.zip" \
   -YtDlpUrl    "https://github.com/.../yt-dlp.exe"
```

**Beaucoup de « Filtre par les conditions »** — tes conditions sont trop
strictes pour ce répertoire. Retire `pref-format = flac` de la configuration,
ou augmente `length-tol`.
