#!/usr/bin/env node
'use strict';

// Portage d'Install-Sockseek.ps1 : installe sockseek et yt-dlp, et cree le
// fichier de configuration.
//
//   node bin/install.js
//   node bin/install.js -InstallDir "/opt/sockseek" -MusicDir "/data/techno"
//   node bin/install.js -SkipCredentials   (utilise par la webgui)

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const crypto = require('crypto');
const { parseArgs } = require('../lib/argv');
const { paint } = require('../lib/playlist');
const { getSockseekConfigDir, getSockseekConfPath, setDefaultOutputDir } = require('../lib/paths');
const { defaultInstallDir, defaultMusicDir, platformNames, installBinary, testSoulseekConnection } = require('../lib/install');

function step(msg) { console.log(paint('cyan', `\n>> ${msg}`)); }
function ok(msg) { console.log(paint('green', `   ${msg}`)); }
function info(msg) { console.log(paint('gray', `   ${msg}`)); }

function ask(prompt) {
    return new Promise((resolve) => {
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        rl.question(prompt, (answer) => { rl.close(); resolve(answer); });
    });
}

function askHidden(prompt) {
    // Saisie masquee du mot de passe, sans dependance npm : bascule le
    // terminal en mode brut et n'affiche pas les caracteres tapes.
    return new Promise((resolve) => {
        if (!process.stdin.isTTY) { ask(prompt).then(resolve); return; }
        process.stdout.write(prompt);
        let value = '';
        process.stdin.setRawMode(true);
        process.stdin.resume();
        process.stdin.setEncoding('utf8');
        const onData = (char) => {
            char = char.toString();
            if (char === '\n' || char === '\r' || char === '\u0004') {
                process.stdin.setRawMode(false);
                process.stdin.pause();
                process.stdin.removeListener('data', onData);
                process.stdout.write('\n');
                resolve(value);
                return;
            }
            if (char === '\u0003') { process.exit(130); }
            if (char === '\u007f' || char === '\b') { value = value.slice(0, -1); return; }
            value += char;
        };
        process.stdin.on('data', onData);
    });
}

async function main() {
    const args = parseArgs(process.argv.slice(2), ['Force', 'ForceCredentials', 'SkipCredentials']);
    const installDir = args.InstallDir || defaultInstallDir();
    const musicDir = args.MusicDir || defaultMusicDir();
    const force = !!args.Force;
    // Delibrement separe de -Force : regenerer sockseek.conf ecrase le mot
    // de passe Soulseek enregistre, une reinstallation des binaires non.
    const forceCredentials = !!args.ForceCredentials;
    const skipCredentials = !!args.SkipCredentials;
    const sockseekUrl = args.SockseekUrl;
    const ytDlpUrl = args.YtDlpUrl;

    console.log(paint('white', '================================================================\n Installation sockseek + yt-dlp\n================================================================'));

    step("Dossier d'installation");
    fs.mkdirSync(installDir, { recursive: true });
    ok(installDir);

    const { sockPattern, sockName, ytPattern, ytName } = platformNames();

    // Chaque binaire s'installe independamment : un echec sur l'un (quota
    // GitHub, pas de reseau) ne doit pas empecher de tenter l'autre, ni
    // d'atteindre l'etape Configuration plus bas -- sans ce garde-fou,
    // sockseek en echec sautait aussi l'installation de yt-dlp et la
    // configuration, sans lien logique entre les deux.
    step('sockseek');
    let sockExe = null;
    try {
        sockExe = await installBinary({
            repo: 'fiso64/sockseek', pattern: sockPattern, name: sockName,
            installDir, force, explicitUrl: sockseekUrl, log: info,
        });
    }
    catch (e) { console.error(`[ERREUR] ${e.message}`); }

    step('yt-dlp');
    let ytExe = null;
    try {
        ytExe = await installBinary({
            repo: 'yt-dlp/yt-dlp', pattern: ytPattern, name: ytName,
            installDir, force, explicitUrl: ytDlpUrl, archive: false, log: info,
        });
    }
    catch (e) { console.error(`[ERREUR] ${e.message}`); }

    step('PATH');
    const sep = path.delimiter;
    process.env.PATH = `${(process.env.PATH || '').replace(new RegExp(`${sep}+$`), '')}${sep}${installDir}`;
    info('Ajoute pour cette session.');
    if (process.platform === 'win32') {
        info('Pour le rendre permanent : Parametres systeme > Variables d\'environnement,');
        info(`ajouter "${installDir}" a la variable PATH de l'utilisateur.`);
    }
    else {
        info('Pour le rendre permanent, ajouter au profil de shell :');
        info(`  export PATH="${installDir}:$PATH"`);
    }

    step('Configuration');
    const confDir = getSockseekConfigDir();
    const confFile = getSockseekConfPath();

    const confAlreadyExists = fs.existsSync(confFile);

    if (skipCredentials) {
        info('-SkipCredentials : ni prompt, ni ecriture de sockseek.conf.');
        info("Identifiants a configurer separement (POST /api/config/credentials, ou --username/--password).");
    }
    // -Force ne concerne QUE les binaires (reinstallation sans risque) : il
    // ne doit jamais, par lui-meme, ecraser les identifiants Soulseek deja
    // enregistres -- perte du mot de passe sans avertissement sinon, pour
    // qui voulait juste forcer la reinstallation de sockseek/yt-dlp.
    // Regenerer sockseek.conf exige -ForceCredentials, separement.
    else if (confAlreadyExists && !forceCredentials) {
        info(`sockseek.conf existe deja : ${confFile}`);
        info('Inchange. -ForceCredentials pour le regenerer (ecrase le mot de passe enregistre).');
    }
    else {
        if (confAlreadyExists) {
            const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
            const backupPath = `${confFile}.bak-${stamp}`;
            fs.copyFileSync(confFile, backupPath);
            console.log('');
            console.warn(`ATTENTION : sockseek.conf existant remplace (-ForceCredentials). Ancienne version sauvegardee : ${backupPath}`);
        }

        console.log('');
        console.log(paint('white', '   Identifiants Soulseek.'));
        console.log(paint('gray', "   Le compte n'a pas besoin d'exister : le serveur enregistre"));
        console.log(paint('gray', '   le pseudo a la premiere connexion. Prevoir un pseudo assez commun,'));
        console.log(paint('gray', '   sinon il sera deja pris et la connexion echouera.'));
        console.log('');

        let user = (await ask('   Pseudo Soulseek : ')).trim();
        while (!user) user = (await ask('   Pseudo Soulseek (obligatoire) : ')).trim();

        let pass = await askHidden('   Mot de passe : ');
        if (!pass.trim()) {
            pass = crypto.randomBytes(8).toString('hex');
            info('Vide : un mot de passe aleatoire a ete genere et ecrit dans le fichier.');
        }

        fs.mkdirSync(confDir, { recursive: true });
        fs.mkdirSync(musicDir, { recursive: true });

        const stamp = new Date().toISOString().slice(0, 16).replace('T', ' ');
        const content = [
            `# Genere par bin/install.js le ${stamp}`,
            `username = ${user}`,
            `password = ${pass}`,
            '',
            `output-dir = ${musicDir}`,
            '',
            '# Prefere le flac, retombe sur le mp3 s\'il n\'y en a pas.',
            'pref-format = flac,mp3',
            '',
            '# Les premieres SoundCloud et les rips vinyle s\'ecartent souvent de',
            '# quelques secondes de la duree annoncee par la source.',
            'length-tol = 10',
            '',
        ].join('\n');
        fs.writeFileSync(confFile, content, 'utf8');

        setDefaultOutputDir(musicDir);

        ok(`Ecrit : ${confFile}`);
        info(`Musique : ${musicDir}`);
    }

    step('Verification');
    const okSock = !!sockExe && fs.existsSync(sockExe);
    const okYt = !!ytExe && fs.existsSync(ytExe);
    const okConf = skipCredentials || fs.existsSync(confFile);

    console.log(`   sockseek      : ${paint(okSock ? 'green' : 'red', okSock ? 'OK' : 'MANQUANT')}`);
    console.log(`   yt-dlp        : ${paint(okYt ? 'green' : 'red', okYt ? 'OK' : 'MANQUANT')}`);
    if (skipCredentials) {
        console.log(paint('gray', '   configuration : ignoree (-SkipCredentials)'));
    }
    else {
        console.log(`   configuration : ${paint(okConf ? 'green' : 'red', okConf ? 'OK' : 'MANQUANT')}`);
    }

    if (!(okSock && okYt && okConf)) {
        console.warn('Installation incomplete, voir les lignes ci-dessus.');
        return 1;
    }

    let testOk = true;
    if (!skipCredentials) {
        step('Test de connexion Soulseek');
        const test = await testSoulseekConnection(sockExe);
        testOk = test.ok;
        console.log(`   ${paint(test.ok ? 'green' : 'red', test.message)}`);
    }

    console.log(paint('white', [
        '',
        '================================================================',
        ' Termine.',
        '',
        ' Extraction d\'une playlist :',
        '',
        '   node bin/extract.js -Url "https://soundcloud.com/..." -Download',
        '',
        '================================================================',
    ].join('\n')));

    return testOk ? 0 : 1;
}

if (require.main === module) {
    main().then((code) => process.exit(code || 0)).catch((e) => {
        console.error(`[ERREUR] ${e.message}`);
        process.exit(1);
    });
}

module.exports = { main };
