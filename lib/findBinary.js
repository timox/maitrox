'use strict';

// Recherche d'executable dans le PATH puis dans le dossier d'installation
// par defaut du kit -- partagee entre webgui/server.js et les scripts de
// bin/ (Get-SoulseekList.ps1 cherchait 'sockseek'/'sldl' de la meme facon).

const fs = require('fs');
const path = require('path');
const { defaultInstallDir } = require('./install');

function findOnPath(names) {
    const pathEnv = process.env.PATH || '';
    const exts = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
    const dirs = pathEnv.split(path.delimiter).filter(Boolean);
    for (const name of names) {
        for (const dir of dirs) {
            for (const ext of exts) {
                const candidate = path.join(dir, name + ext);
                try { if (fs.statSync(candidate).isFile()) return candidate; }
                catch (e) { /* absent ici, on continue */ }
            }
        }
    }
    return null;
}

function findBinary(names) {
    const onPath = findOnPath(names);
    if (onPath) return onPath;
    const dir = defaultInstallDir();
    for (const name of names) {
        const candidate = path.join(dir, process.platform === 'win32' ? `${name}.exe` : name);
        try { if (fs.statSync(candidate).isFile()) return candidate; } catch (e) { /* absent */ }
    }
    return null;
}

module.exports = { findOnPath, findBinary };
