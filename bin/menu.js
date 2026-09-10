#!/usr/bin/env node
'use strict';

// Portage de Menu.ps1 : menu interactif du kit sockseek -- nouvelle
// playlist, reprise, etat. Meme navigation que l'original (retour au menu
// principal ou menu de reprise, sortie explicite).
//
// bin/extract.js et bin/resume.js appellent process.exit() a plusieurs
// endroits : ils sont donc toujours lances dans un processus node separe
// (spawnSync), jamais requis directement dans ce process -- un exit() a
// l'interieur terminerait sinon ce menu.
//
//   node bin/menu.js
//   node bin/menu.js --url "https://soundcloud.com/loleanto/sets/..."

const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');
const { getDefaultOutputDir } = require('../lib/paths');
const { paint } = require('../lib/playlist');

const extractScript = path.join(__dirname, 'extract.js');
const resumeScript = path.join(__dirname, 'resume.js');

function readLine(prompt) {
    return new Promise((resolve) => {
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        rl.question(prompt, (answer) => {
            rl.close();
            // Read-Host renvoie $null en cas de fin de flux reelle : sans ce
            // garde-fou, une invite qui reboucle sur elle-meme tournerait
            // indefiniment. readline.question ne distingue pas nativement
            // ce cas -- 'close' sans reponse le fait, voir ci-dessous.
            resolve(answer);
        });
        rl.on('close', () => { /* geree par la resolution ci-dessus */ });
    });
}

async function readMenuChoice(prompt, def) {
    const answer = await readLine(`${prompt} [${def}] `);
    if (answer == null || answer.trim() === '') return def;
    return answer.trim();
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

function invokeKitScript(scriptPath, scriptArgs = []) {
    const run = spawnSync(process.execPath, [scriptPath, ...scriptArgs], { stdio: 'inherit' });
    return run.status == null ? 1 : run.status;
}

async function main() {
    const argIdx = process.argv.indexOf('--url');
    let url = argIdx >= 0 ? process.argv[argIdx + 1] : undefined;

    let code = 0;
    let state = url ? 'AskMode' : 'Menu';

    while (state !== 'Quit') {
        switch (state) {
            case 'Menu': {
                console.log('================================================================');
                console.log(' Kit sockseek');
                console.log('================================================================');
                console.log('');
                console.log('  [1] Traiter une nouvelle playlist');
                console.log('  [2] Reprendre les titres manquants');
                console.log("  [3] Voir l'etat des playlists deja traitees");
                console.log('  [4] Quitter');
                console.log('');
                const choice = await readMenuChoice('Choix', '1');
                if (choice === '1') state = 'AskUrl';
                else if (choice === '2') state = 'ResumeMenu';
                else if (choice === '3') state = 'Etat';
                else if (choice === '4') state = 'Quit';
                else { console.log(paint('yellow', '\n  Choix invalide.')); await sleep(1000); }
                break;
            }

            // =========================================== nouvelle playlist ====
            case 'AskUrl': {
                console.log('\nURL de la playlist SoundCloud ou YouTube :\n');
                url = await readLine('URL : ');
                if (!url || !url.trim()) {
                    console.log(paint('yellow', '\n  Aucune URL saisie, rien a faire.'));
                    await sleep(1000);
                    state = 'Menu';
                }
                else {
                    state = 'AskMode';
                }
                break;
            }

            case 'AskMode': {
                console.log(`\nURL : "${url}"\n`);
                console.log('Que faire ?\n');
                console.log("  [1] Tester d'abord : cherche sur Soulseek, ne telecharge rien");
                console.log('  [2] Telecharger pour de vrai');
                console.log("  [3] Extraire et nettoyer la liste seulement, sans toucher a Soulseek");
                console.log('');
                const choix = await readMenuChoice('Choix', '1');

                let modeArgs;
                if (choix === '1') modeArgs = ['-Download', '-PrintOnly'];
                else if (choix === '2') modeArgs = ['-Download'];
                else if (choix === '3') modeArgs = [];
                else modeArgs = null;

                if (modeArgs === null) {
                    console.log(paint('yellow', '\n  Choix invalide.'));
                    await sleep(1000);
                    break; // redemande sur AskMode, l'URL est deja connue
                }

                let destArgs = [];
                if (choix !== '3') {
                    const currentDest = getDefaultOutputDir();
                    console.log(`\nDossier de destination actuel : "${currentDest}"`);
                    console.log('Laisser vide pour le conserver, ou taper un nouveau chemin pour le');
                    console.log('remplacer (il devient le defaut pour les prochaines fois) :');
                    const dest = await readLine('Dossier : ');
                    if (dest && dest.trim()) destArgs = ['-OutputDir', dest.trim()];
                }

                console.log('\n----------------------------------------------------------------\n');

                code = invokeKitScript(extractScript, ['-Url', url, ...modeArgs, ...destArgs]);

                console.log('\n----------------------------------------------------------------');
                if (code === 0) {
                    console.log(paint('green', 'Termine sans echec.'));
                }
                else if (code === 10) {
                    console.log(paint('yellow', "Termine, mais certains titres n'ont pas ete recuperes."));
                    console.log('Le detail est dans rapport.csv, dans le sous-dossier de la playlist');
                    console.log('(a l\'interieur du dossier de destination).');
                    console.log('');
                    console.log("Sur un reseau P2P, reessayer plus tard suffit souvent : le pair");
                    console.log("qui partage le morceau doit simplement etre connecte -- selectionner");
                    console.log('"Reprendre les titres manquants" dans le menu principal.');
                }
                else {
                    console.log(paint('red', `Termine avec le code ${code}. Voir les messages ci-dessus.`));
                }
                state = 'PostAction';
                break;
            }

            // ================================================== reprise =======
            // bin/resume.js ne filtre que par PLAYLIST (-Only), pas titre par
            // titre : "une playlist en particulier" est donc la plus fine
            // granularite disponible.
            case 'ResumeMenu': {
                console.log('\n----------------------------------------------------------------');
                console.log(' Reprise des titres manquants');
                console.log('----------------------------------------------------------------\n');
                console.log("Un morceau introuvable un jour peut apparaitre le lendemain : il");
                console.log("suffit que le pair qui le partage se reconnecte. L'etat actuel :\n");

                invokeKitScript(resumeScript, ['-List']);

                console.log('\nQue reprendre ?\n');
                console.log('  [1] Voir d\'abord la liste des titres qui seraient repris (test, rien de relance)');
                console.log('  [2] Tous les morceaux manquants, toutes playlists confondues');
                console.log('  [3] Une playlist en particulier');
                console.log('  [4] Retour au menu principal');
                console.log('  [5] Quitter');
                console.log('');
                const choice = await readMenuChoice('Choix', '1');
                if (choice === '1') state = 'ResumeDryRunAll';
                else if (choice === '2') state = 'ResumeRunAll';
                else if (choice === '3') state = 'ResumeAskPlaylist';
                else if (choice === '4') state = 'Menu';
                else if (choice === '5') state = 'Quit';
                else { console.log(paint('yellow', '\n  Choix invalide.')); await sleep(1000); }
                break;
            }

            case 'ResumeDryRunAll': {
                console.log('\n----------------------------------------------------------------\n');
                invokeKitScript(resumeScript, ['-DryRun']);

                console.log('\nEt maintenant ?\n');
                console.log('  [1] Reprendre tous ces titres pour de vrai');
                console.log('  [2] Reprendre une playlist en particulier plutot');
                console.log('  [3] Retour au menu de reprise');
                console.log('  [4] Retour au menu principal');
                console.log('  [5] Quitter');
                console.log('');
                const choice = await readMenuChoice('Choix', '3');
                if (choice === '1') state = 'ResumeRunAll';
                else if (choice === '2') state = 'ResumeAskPlaylist';
                else if (choice === '3') state = 'ResumeMenu';
                else if (choice === '4') state = 'Menu';
                else if (choice === '5') state = 'Quit';
                else { console.log(paint('yellow', '\n  Choix invalide.')); await sleep(1000); }
                break;
            }

            case 'ResumeRunAll': {
                console.log('\n----------------------------------------------------------------\n');
                code = invokeKitScript(resumeScript, []);
                state = 'PostAction';
                break;
            }

            case 'ResumeAskPlaylist': {
                console.log("\nNom (ou fragment du nom) de la playlist a reprendre, tel qu'affiche");
                console.log('dans la colonne "Playlist" ci-dessus :\n');
                const plname = await readLine('Playlist : ');
                if (!plname || !plname.trim()) { state = 'ResumeMenu'; break; }

                console.log("\n  [1] Tester d'abord : voir ce qui serait repris pour cette playlist");
                console.log('  [2] Reprendre cette playlist pour de vrai\n');
                const ochoice = await readMenuChoice('Choix', '1');

                if (ochoice === '2') {
                    console.log('\n----------------------------------------------------------------\n');
                    code = invokeKitScript(resumeScript, ['-Only', plname.trim()]);
                    state = 'PostAction';
                    break;
                }
                if (ochoice !== '1') {
                    console.log(paint('yellow', '\n  Choix invalide.'));
                    await sleep(1000);
                    break; // redemande le nom de playlist
                }

                console.log('\n----------------------------------------------------------------\n');
                invokeKitScript(resumeScript, ['-Only', plname.trim(), '-DryRun']);

                console.log('\nEt maintenant ?\n');
                console.log('  [1] Reprendre cette playlist pour de vrai');
                console.log('  [2] Retour au menu de reprise');
                console.log('  [3] Retour au menu principal');
                console.log('  [4] Quitter');
                console.log('');
                const next = await readMenuChoice('Choix', '2');
                if (next === '1') {
                    console.log('\n----------------------------------------------------------------\n');
                    code = invokeKitScript(resumeScript, ['-Only', plname.trim()]);
                    state = 'PostAction';
                }
                else if (next === '2') state = 'ResumeMenu';
                else if (next === '3') state = 'Menu';
                else if (next === '4') state = 'Quit';
                else { console.log(paint('yellow', '\n  Choix invalide.')); await sleep(1000); state = 'ResumeMenu'; }
                break;
            }

            // ===================================================== etat =======
            case 'Etat': {
                console.log('');
                code = invokeKitScript(resumeScript, ['-List']);
                state = 'PostAction';
                break;
            }

            // ======================================== retour ou sortie ========
            case 'PostAction': {
                console.log('\n----------------------------------------------------------------');
                console.log('  [1] Retour au menu principal');
                console.log('  [2] Quitter');
                console.log('');
                const choice = await readMenuChoice('Choix', '1');
                if (choice === '1') state = 'Menu';
                else if (choice === '2') state = 'Quit';
                else { console.log(paint('yellow', '\n  Choix invalide.')); await sleep(1000); }
                break;
            }

            default:
                state = 'Quit';
        }
    }

    return code;
}

if (require.main === module) {
    main().then((code) => process.exit(code || 0)).catch((e) => {
        console.error(paint('red', e.message));
        process.exit(1);
    });
}

module.exports = { main };
