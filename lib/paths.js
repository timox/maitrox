'use strict';

// Chemins de configuration et petites conversions de noms : portage des
// fonctions Get-SockseekConfigDir / Get-CataloguePath / Get-PrefsPath /
// Get-DefaultOutputDir / Set-DefaultOutputDir / Get-SockseekConfPath /
// Set-SockseekCredentials / ConvertTo-SafeFolderName de SockseekLib.ps1.

const fs = require('fs');
const os = require('os');
const path = require('path');
const log = require('./log');

function getSockseekConfigDir() {
    if (process.env.APPDATA) return path.join(process.env.APPDATA, 'sockseek');
    return path.join(os.homedir(), '.config', 'sockseek');
}

function getCataloguePath() {
    return path.join(getSockseekConfigDir(), 'catalogue.json');
}

function getPrefsPath() {
    return path.join(getSockseekConfigDir(), 'prefs.json');
}

function getDefaultOutputDir() {
    // Dossier de destination retenu d'un lancement a l'autre. Modifie via
    // setDefaultOutputDir, sinon valeur d'origine du kit.
    const p = getPrefsPath();
    if (fs.existsSync(p)) {
        try {
            const prefs = JSON.parse(fs.readFileSync(p, 'utf8'));
            if (prefs.OutputDir) return prefs.OutputDir;
        }
        catch (e) {
            log.warn(`Preferences illisibles (${p}) : ${e.message}`);
        }
    }
    return path.join(os.homedir(), 'Music', 'sockseek');
}

function setDefaultOutputDir(outputDir) {
    const p = getPrefsPath();
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify({ OutputDir: outputDir }), 'utf8');
}

function getSockseekConfPath() {
    const dir = process.env.APPDATA ? path.join(process.env.APPDATA, 'sockseek')
        : path.join(os.homedir(), '.config', 'sockseek');
    return path.join(dir, 'sockseek.conf');
}

function setSockseekCredentials({ username, password, outputDir, confPath }) {
    // Ecrit ou met a jour username/password (et, si fourni, output-dir) dans
    // sockseek.conf, sans toucher au reste du fichier (profils, autres
    // reglages) ni exiger de prompt interactif. Cree le fichier s'il
    // n'existe pas.
    const target = confPath || getSockseekConfPath();
    let lines = [];
    if (fs.existsSync(target)) {
        lines = fs.readFileSync(target, 'utf8').replace(/\r\n/g, '\n').split('\n');
        if (lines.length && lines[lines.length - 1] === '') lines.pop();
    }

    function setConfLine(key, value) {
        const pattern = new RegExp(`^\\s*${key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*=`);
        const idx = lines.findIndex((l) => pattern.test(l));
        const newLine = `${key} = ${value}`;
        if (idx >= 0) lines[idx] = newLine; else lines.push(newLine);
    }

    setConfLine('username', username);
    setConfLine('password', password);
    if (outputDir) setConfLine('output-dir', outputDir);

    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, lines.join('\r\n') + '\r\n', 'utf8');
}

function safeFolderName(name) {
    // Nom de playlist -> nom de dossier valide sur Windows comme sur Unix.
    // Liste figee plutot qu'une API dependante de la plateforme : le kit
    // cible du disque Windows quelle que soit la machine qui l'execute.
    if (name == null || String(name).trim() === '') return 'playlist';
    let safe = String(name).replace(/[<>:"/\\|?*\x00-\x1f]/g, ' ');
    safe = safe.replace(/\s+/g, ' ').trim();
    safe = safe.replace(/^[\s.]+|[\s.]+$/g, '');
    if (safe === '') return 'playlist';
    return safe;
}

module.exports = {
    getSockseekConfigDir,
    getCataloguePath,
    getPrefsPath,
    getDefaultOutputDir,
    setDefaultOutputDir,
    getSockseekConfPath,
    setSockseekCredentials,
    safeFolderName,
};
