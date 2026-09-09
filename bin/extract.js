#!/usr/bin/env node
'use strict';

// Portage de Get-SoulseekList.ps1 : extrait une playlist SoundCloud/YouTube
// via yt-dlp, nettoie les metadonnees et produit un CSV directement
// consommable par sockseek. Peut enchainer sur le telechargement.
//
//   node bin/extract.js -Url "https://soundcloud.com/loleanto/sets/..."
//   node bin/extract.js -Url $url -Download -PrintOnly
//   node bin/extract.js -Url $url -Download -OutputDir "D:\Music\techno"
//   node bin/extract.js -Url $url -CookiesFromBrowser firefox

const fs = require('fs');
const os = require('os');
const path = require('path');
const { runInherit, runCapture } = require('../lib/proc');
const { parseArgs } = require('../lib/argv');
const { convertEntry } = require('../lib/text');
const { writeCsv } = require('../lib/csv');
const { safeFolderName, getDefaultOutputDir, setDefaultOutputDir, getSockseekConfPath, getSockseekConfigDir } = require('../lib/paths');
const { findOnPath } = require('../lib/findBinary');
const { paint } = require('../lib/playlist');

const KNOWN_BROWSERS = ['brave', 'chrome', 'chromium', 'edge', 'firefox', 'opera', 'safari', 'vivaldi', 'whale'];

function findExtra(here) {
    // A cote du script, ou dans un sous-dossier -- profondeur 2, comme
    // Get-ChildItem -Depth 2 dans l'original.
    const names = ['sockseek.exe', 'sldl.exe', 'sockseek', 'sldl'];
    const search = (dir, depth) => {
        let entries;
        try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return null; }
        for (const e of entries) {
            if (e.isFile() && names.includes(e.name)) return path.join(dir, e.name);
        }
        if (depth <= 0) return null;
        for (const e of entries) {
            if (e.isDirectory()) {
                const hit = search(path.join(dir, e.name), depth - 1);
                if (hit) return hit;
            }
        }
        return null;
    };
    return search(here, 2);
}

async function main() {
    const args = parseArgs(process.argv.slice(2), ['Download', 'PrintOnly']);
    const url = args.Url;
    if (!url) throw new Error('-Url requis.');

    let out = args.Out || 'playlist-clean.csv';
    const rawOut = args.RawOut;
    const download = !!args.Download;
    const printOnly = !!args.PrintOnly;
    const sockseekPathArg = args.SockseekPath;
    const cookiesFromBrowser = args.CookiesFromBrowser;
    if (cookiesFromBrowser && !KNOWN_BROWSERS.includes(cookiesFromBrowser)) {
        throw new Error(`-CookiesFromBrowser doit etre l'un de : ${KNOWN_BROWSERS.join(', ')}`);
    }

    let outputDir;
    if (args.OutputDir) {
        outputDir = args.OutputDir;
        // -OutputDir explicite : devient le nouveau dossier par defaut pour
        // les prochains lancements.
        setDefaultOutputDir(outputDir);
    }
    else {
        outputDir = getDefaultOutputDir();
    }

    // ------------------------------------------------------------- extraction ---
    if (!findOnPath(['yt-dlp'])) {
        throw new Error('yt-dlp est introuvable dans le PATH.');
    }

    console.log(paint('cyan', 'Recuperation des metadonnees (une requete par piste, patience)...'));

    // --sleep-requests : SoundCloud limite a ~600 requetes / 10 min (1/s).
    // Sans ce throttle proactif, une playlist un peu longue declenche des
    // 429 en rafale, chacun retente 3 fois par defaut.
    const ytArgs = ['--skip-download', '--ignore-errors', '--sleep-requests', '1', '-J'];
    if (cookiesFromBrowser) ytArgs.push('--cookies-from-browser', cookiesFromBrowser);
    ytArgs.push(url);

    let ytRes;
    try { ytRes = await runCapture('yt-dlp', ytArgs); }
    catch (e) { throw new Error(`yt-dlp introuvable ou en echec : ${e.message}`); }
    const raw = ytRes.stdout;
    if (!raw || !raw.trim()) {
        throw new Error("yt-dlp n'a rien renvoye. Verifie l'URL et l'accessibilite de la playlist.");
    }

    const data = JSON.parse(raw);
    const entries = (data.entries || [data]).filter(Boolean);
    if (entries.length === 0) throw new Error('Aucune piste trouvee dans la playlist.');

    // Chaque playlist telecharge dans son propre sous-dossier, nomme
    // d'apres son titre, a l'interieur du dossier de destination.
    const playlistName = data.title || url.replace(/\/+$/, '').split('/').pop();
    const playlistFolder = safeFolderName(playlistName);
    const destDir = path.join(outputDir, playlistFolder);

    console.log(paint('cyan', `${entries.length} pistes recuperees.`));

    // yt-dlp sait recuperer le fichier original directement quand
    // l'artiste a active le telechargement libre sur SoundCloud (format
    // nomme "download" dans les metadonnees).
    const directDownloadUrls = new Set();
    for (const e of entries) {
        if (e.webpage_url && (e.formats || []).some((f) => f.format_id === 'download')) {
            directDownloadUrls.add(String(e.webpage_url));
        }
    }
    if (directDownloadUrls.size > 0) {
        console.log(paint('cyan', `${directDownloadUrls.size} titre(s) en telechargement libre directement sur SoundCloud.`));
    }

    // ---------------------------------------------------------------- export ----
    if (rawOut) {
        const rawRows = entries.map((e) => ({
            index: e.playlist_index, artist: e.artist, uploader: e.uploader,
            track: e.track, titre: e.title, duree: e.duration, url: e.webpage_url,
        }));
        fs.writeFileSync(rawOut, writeCsv(rawRows), 'utf8');
        console.log(paint('gray', `CSV brut ecrit dans ${rawOut}`));
    }

    const all = entries.map(convertEntry);
    const junk = all.filter((r) => /PAS_UN_MORCEAU/.test(r.Review));
    const rows = all.filter((r) => !/PAS_UN_MORCEAU/.test(r.Review));

    // Le BOM gene certains parseurs CSV : ecrit en UTF-8 sans BOM (comportement par defaut ici).
    fs.writeFileSync(out, writeCsv(rows, ['Artist', 'Title', 'Length', 'SourceChannel', 'Url', 'Review']), 'utf8');

    for (const r of rows) {
        console.log(`${(r.Artist || '').padEnd(30)} ${(r.Title || '').padEnd(40)} ${String(r.Length).padEnd(6)} ${r.Review || ''}`);
    }

    console.log('');
    console.log(paint('green', `${rows.length} titres exportes vers ${out}`));

    for (const j of junk) console.log(paint('gray', `  ecarte (pas un morceau) : ${j.Title}`));

    const flagged = rows.filter((r) => /TRONQUE/.test(r.Review));
    if (flagged.length > 0) {
        console.log('');
        console.log(paint('yellow', `${flagged.length} titres tronques dans l'export, a completer a la main :`));
        for (const f of flagged) console.log(`  ${f.Artist} - ${f.Title}`);
    }

    const weak = rows.filter((r) => /artiste=chaine/.test(r.Review));
    if (weak.length > 0) {
        console.log('');
        console.log(paint('yellow', `${weak.length} titres sans artiste identifiable (nom de chaine utilise par defaut).`));
        console.log('  --artist-maybe-wrong relancera une recherche sans l\'artiste pour ceux-la.');
    }

    // ---------------------------------------------------------- telechargement --
    if (!download) {
        console.log('');
        console.log(paint('cyan', 'Pour verifier ce que sockseek trouverait :'));
        console.log(`  node bin/extract.js -Url "${url}" -Download -PrintOnly`);
        return 0;
    }

    fs.mkdirSync(destDir, { recursive: true });

    // --------------------------------------- telechargement direct (SoundCloud) --
    let directRows = rows.filter((r) => directDownloadUrls.has(r.Url));
    let searchRows = rows.filter((r) => !directDownloadUrls.has(r.Url));

    if (directRows.length > 0 && printOnly) {
        // -PrintOnly ne fait que previsualiser la recherche Soulseek : rien
        // a telecharger, direct ou non, dans ce mode.
        console.log('');
        console.log(paint('gray', `${directRows.length} titre(s) en telechargement libre ignore(s) en mode -PrintOnly.`));
        searchRows = rows;
    }
    else if (directRows.length > 0) {
        console.log('');
        console.log(paint('cyan', `Telechargement direct de ${directRows.length} titre(s) libres sur SoundCloud...`));
        for (const row of directRows) {
            const safeName = safeFolderName(`${row.Artist} - ${row.Title}`);
            const outTemplate = path.join(destDir, `${safeName}.%(ext)s`);
            const dlArgs = ['-f', 'download', '--no-playlist', '-o', outTemplate];
            if (cookiesFromBrowser) dlArgs.push('--cookies-from-browser', cookiesFromBrowser);
            dlArgs.push(row.Url);

            const dl = await runInherit('yt-dlp', dlArgs);
            if (dl.status === 0) {
                console.log(paint('green', `  OK : ${row.Artist} - ${row.Title}`));
            }
            else {
                console.warn(`  Echec du telechargement direct, recherche Soulseek en repli : ${row.Artist} - ${row.Title}`);
                searchRows.push(row);
            }
        }
    }

    // Le CSV donne a sockseek exclut les titres deja recuperes directement
    // -- bin/build-playlist.js, lui, continue a lire le CSV complet ($out)
    // pour que le rapport final les compte comme reussis (verite sur le
    // disque) plutot que de les afficher comme jamais traites.
    let sockseekCsv = out;
    if (searchRows.length !== rows.length) {
        sockseekCsv = path.join(destDir, 'a-rechercher.csv');
        fs.writeFileSync(sockseekCsv, writeCsv(searchRows, ['Artist', 'Title', 'Length', 'SourceChannel', 'Url', 'Review']), 'utf8');
    }

    if (searchRows.length === 0) {
        console.log('');
        console.log(paint('green', 'Tous les titres ont ete recuperes directement : aucune recherche Soulseek necessaire.'));
        const { buildPlaylist } = require('./build-playlist');
        buildPlaylist({ outputDir: destDir, sourceCsv: out, register: url });
        return 0;
    }

    // Sockseek se distribue en binaire autonome : rien ne l'ajoute au PATH.
    let exe = null;
    if (sockseekPathArg) {
        if (!fs.existsSync(sockseekPathArg)) throw new Error(`Aucun executable a l'emplacement indique : ${sockseekPathArg}`);
        exe = fs.realpathSync(sockseekPathArg);
    }
    else {
        exe = findOnPath(['sockseek', 'sldl']) || findExtra(path.resolve(__dirname, '..'));
    }

    if (!exe) {
        console.log('');
        console.warn([
            'Executable sockseek introuvable.',
            '',
            'Sockseek se telecharge en binaire autonome depuis la page des releases',
            "GitHub : rien ne l'ajoute au PATH tout seul. Deux solutions :",
            '',
            '  1. Indiquer le chemin au script :',
            '     -SockseekPath "/chemin/vers/sockseek"',
            '',
            '  2. Ou lancer node bin/install.js pour l\'installer et le mettre sur le PATH.',
        ].join('\n'));
        console.log(paint('green', `Le CSV ${out} est bien ecrit : relance juste avec -SockseekPath.`));
        return 2;
    }

    console.log(paint('gray', `Executable : ${exe}`));

    // --- identifiants ----------------------------------------------------------
    const confCandidates = [
        path.join(os.homedir(), '.config', 'sockseek', 'sockseek.conf'),
        process.env.APPDATA ? path.join(process.env.APPDATA, 'sockseek', 'sockseek.conf') : null,
        process.env.XDG_CONFIG_HOME ? path.join(process.env.XDG_CONFIG_HOME, 'sockseek', 'sockseek.conf') : null,
        path.join(path.dirname(exe), 'sockseek.conf'),
    ].filter(Boolean);
    const conf = confCandidates.find((c) => fs.existsSync(c));
    const confAdvised = getSockseekConfPath();

    if (!conf) {
        console.log('');
        console.warn([
            'Aucun fichier sockseek.conf trouve, et aucun identifiant fourni.',
            'Sockseek exige --user et --pass, ou de les lire dans sa configuration.',
            '',
            'Cree le fichier suivant :',
            '',
            `  ${confAdvised}`,
            '',
            'avec au minimum :',
            '',
            '  username = ton-compte-soulseek',
            '  password = ton-mot-de-passe',
            `  output-dir = ${outputDir}`,
            '',
            "Utilise un compte Soulseek DEDIE si tu fais tourner un autre client",
            '(Nicotine+, slskd) en parallele : deux sessions sur le meme compte',
            'provoquent des problemes de connexion.',
        ].join('\n'));
        console.log(paint('green', `Le CSV ${out} est bien ecrit : relance une fois la config en place.`));
        return 3;
    }
    console.log(paint('gray', `Configuration : ${conf}`));

    const idxPath = path.join(destDir, '_index.csv');
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
    const logPath = path.join(destDir, `sockseek-${stamp}.log`);

    const sockArgs = [
        sockseekCsv,
        '--index-path', idxPath,
        '--log-file', logPath,
        '--song',
        '--artist-maybe-wrong',
        '--length-tol', '10',
        '--pref-format', 'flac,wav',
        '--remove-ft',
        '--name-format', '{artist( - )title|filename}',
        '--output-dir', destDir,
    ];

    if (printOnly) {
        sockArgs.push('--print', 'results');
        console.log('');
        console.log(paint('cyan', 'Recherche seule, aucun telechargement.'));
    }
    else {
        console.log('');
        console.log(paint('cyan', `Telechargement vers ${destDir}`));
        const minutes = Math.ceil(searchRows.length / 34.0) * 220 / 60;
        console.log(`Compte environ ${minutes} minutes minimum : le serveur Soulseek`);
        console.log(paint('gray', 'bannit 30 minutes si les recherches s\'enchainent trop vite.'));
    }

    const run = await runInherit(exe, sockArgs);
    const code = run.status;

    if (printOnly) {
        console.log('');
        console.log(paint('gray', `Recherche terminee (code ${code}).`));
        return 0;
    }

    if (code !== 0) {
        // Cherche une cause connue dans le journal plutot que de laisser
        // l'utilisateur deviner depuis un simple code de sortie.
        const logContent = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8') : null;
        if (logContent && /INVALIDPASS/.test(logContent)) {
            console.warn([
                'Identifiants Soulseek refuses (INVALIDPASS).',
                'Cause la plus frequente : ce pseudo est deja pris par quelqu\'un d\'autre --',
                'Soulseek ne cree un compte que si le pseudo est libre, sinon ton mot de',
                'passe ne correspondra jamais au sien. Choisis un pseudo moins courant.',
                'Sinon, verifie le mot de passe dans sockseek.conf.',
            ].join('\n'));
        }
        else if (logContent && /login failed/i.test(logContent)) {
            console.warn(`Connexion a Soulseek echouee. Voir le journal pour le detail : ${logPath}`);
        }
        else {
            console.warn(`sockseek s'est termine avec le code ${code}. Journal : ${logPath}`);
        }
    }

    // ---------------------------------------------------- rapport et playlist ---
    const { buildPlaylist } = require('./build-playlist');
    buildPlaylist({ outputDir: destDir, indexPath: idxPath, sourceCsv: out, register: url });

    console.log(paint('gray', `Journal detaille : ${logPath}`));
    return 0;
}

if (require.main === module) {
    main().then((code) => process.exit(code || 0)).catch((e) => {
        console.error(paint('red', e.message));
        process.exit(1);
    });
}

module.exports = { main };
