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
    // timeoutMs (optionnel) : garde-fou de dernier recours si le
    // sous-processus reste bloque indefiniment (connexion reseau qui ne
    // repond ni n'echoue franchement, par exemple) -- sans lui, rien ne
    // signale jamais un blocage, contrairement a une vraie erreur que
    // --ignore-errors laisse passer. A completer, cote appelant, par les
    // options de timeout propres a l'outil lance quand elles existent
    // (--socket-timeout pour yt-dlp) : plus precises, elles evitent de
    // devoir attendre ce garde-fou en cas de blocage sur un seul element.
    const { timeoutMs, ...spawnOpts } = opts;
    return new Promise((resolve, reject) => {
        const proc = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'], ...spawnOpts });
        let stdout = '';
        let stderr = '';
        let settled = false;
        let timer = null;

        proc.stdout.on('data', (d) => { stdout += d; });
        proc.stderr.on('data', (d) => { stderr += d; });
        proc.on('error', (e) => { if (!settled) { settled = true; clearTimeout(timer); reject(e); } });
        proc.on('close', (code) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            resolve({ status: code == null ? 1 : code, stdout, stderr });
        });

        if (timeoutMs) {
            timer = setTimeout(() => {
                if (settled) return;
                settled = true;
                try { proc.kill('SIGKILL'); } catch (e) { /* deja mort */ }
                const err = new Error(`Delai depasse (${Math.round(timeoutMs / 1000)}s) sans reponse : processus arrete.`);
                err.timedOut = true;
                reject(err);
            }, timeoutMs);
        }
    });
}

module.exports = { runInherit, runCapture };
