'use strict';

// Lancement de sous-processus asynchrone (yt-dlp, sockseek, tar).
//
// spawnSync bloque completement la boucle d'evenements Node pendant toute
// la duree du process lance -- des lignes deja passees a console.log()
// juste avant restent en attente d'ecriture (process.stdout est un pipe
// asynchrone quand il est redirige, comme c'est le cas ici puisque
// webgui/server.js capture stdout d'un sous-processus) et ne partent
// jamais tant que l'appel synchrone n'est pas termine : constate
// concretement, le journal de la webgui restait vide pendant toute
// l'extraction yt-dlp, y compris le tout premier message affiche avant de
// la lancer. spawn (asynchrone) laisse la boucle d'evenements tourner et
// donc ces ecritures partir normalement.

const { spawn } = require('child_process');

function runInherit(cmd, args, opts = {}) {
    return new Promise((resolve, reject) => {
        const proc = spawn(cmd, args, { stdio: 'inherit', ...opts });
        proc.on('error', reject);
        proc.on('close', (code) => resolve({ status: code == null ? 1 : code }));
    });
}

function runCapture(cmd, args, opts = {}) {
    return new Promise((resolve, reject) => {
        const proc = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'], ...opts });
        let stdout = '';
        let stderr = '';
        proc.stdout.on('data', (d) => { stdout += d; });
        proc.stderr.on('data', (d) => { stderr += d; });
        proc.on('error', reject);
        proc.on('close', (code) => resolve({ status: code == null ? 1 : code, stdout, stderr }));
    });
}

module.exports = { runInherit, runCapture };
