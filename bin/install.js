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
const { defaultInstallDir, defaultMusicDir, platformNames, installBinary } = require('../lib/install');

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
    const args = parseArgs(process.argv.slice(2), ['Force', 'SkipCredentials']);
    const installDir = args.InstallDir || defaultInstallDir();
    const musicDir = args.MusicDir || defaultMusicDir();
    const force = !!args.Force;
    const skipCredentials = !!args.SkipCredentials;
    const sockseekUrl = args.SockseekUrl;
    const ytDlpUrl = args.YtDlpUrl;

    console.log(paint('white', '================================================================\n Installation sockseek + yt-dlp\n================================================================'));

    step("Dossier d'installation");
    fs.mkdirSync(installDir, { recursive: true });
    ok(installDir);

    const { sockPattern, sockName, ytPattern, ytName } = platformNames();

    step('sockseek');
    const sockExe = await installBinary({
        repo: 'fiso64/sockseek', pattern: sockPattern, name: sockName,
        installDir, force, explicitUrl: sockseekUrl, log: info,
    });

    step('yt-dlp');
    const ytExe = await installBinary({
        repo: 'yt-dlp/yt-dlp', pattern: ytPattern, name: ytName,
        installDir, force, explicitUrl: ytDlpUrl, archive: false, log: info,
    });

    step('PATH');
    const sep = path.delimiter;
    process.env.PATH = `${(process.env.PATH || '').replace(new RegExp(`${sep}+$`), '')}${sep}${installDir}`;
    info('Ajoute pour cette session.');
    if (process.platform === 'win32') {
        info('Pour le rendre permanent : Parametres systeme > Variables d\'environnement,');
        info(`ajoute "${installDir}" a la variable PATH de l'utilisateur.`);
    }
    else {
        info('Pour le rendre permanent, ajoute a ton profil de shell :');
        info(`  export PATH="${installDir}:$PATH"`);
    }

    step('Configuration');
    const confDir = getSockseekConfigDir();
    const confFile = getSockseekConfPath();

    if (skipCredentials) {
        info('-SkipCredentials : ni prompt, ni ecriture de sockseek.conf.');
        info("Configure les identifiants separement (POST /api/config/credentials, ou --username/--password).");
    }
    else if (fs.existsSync(confFile) && !force) {
        info(`sockseek.conf existe deja : ${confFile}`);
        info('-Force pour le regenerer.');
    }
    else {
        console.log('');
        console.log(paint('white', '   Identifiants Soulseek.'));
        console.log(paint('gray', "   Le compte n'a pas besoin d'exister : le serveur enregistre"));
        console.log(paint('gray', '   le pseudo a la premiere connexion. Choisis-en un peu commun,'));
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
    const okSock = fs.existsSync(sockExe);
    const okYt = fs.existsSync(ytExe);
    const okConf = skipCredentials || fs.existsSync(confFile);

    console.log(`   sockseek      : ${paint(okSock ? 'green' : 'red', okSock ? 'OK' : 'MANQUANT')}`);
    console.log(`   yt-dlp        : ${paint(okYt ? 'green' : 'red', okYt ? 'OK' : 'MANQUANT')}`);
    if (skipCredentials) {
        console.log(paint('gray', '   configuration : ignoree (-SkipCredentials)'));
    }
    else {
        console.log(`   configuration : ${paint(okConf ? 'green' : 'red', okConf ? 'OK' : 'MANQUANT')}`);
    }

    if (okSock && okYt && okConf) {
        console.log(paint('white', [
            '',
            '================================================================',
            ' Termine.',
            '',
            ' Teste la connexion Soulseek (cela creera le compte si besoin) :',
            '',
            '   sockseek "Sciahri - Let Them Go" --song --print results',
            '',
            ' Puis extrais une playlist :',
            '',
            '   node bin/extract.js -Url "https://soundcloud.com/..." -Download',
            '',
            '================================================================',
        ].join('\n')));
        return 0;
    }

    console.warn('Installation incomplete, voir les lignes ci-dessus.');
    return 1;
}

if (require.main === module) {
    main().then((code) => process.exit(code || 0)).catch((e) => {
        console.error(paint('red', e.message));
        process.exit(1);
    });
}

module.exports = { main };
