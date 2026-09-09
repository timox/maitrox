'use strict';

// Portage d'Install-Sockseek.ps1 (telechargement des binaires) : resolution
// de la derniere release GitHub, telechargement, extraction, mise en place.
// Les identifiants (sockseek.conf) et le menu interactif restent dans
// bin/install.js -- ce module ne fait que la mecanique de telechargement,
// reutilisable telle quelle par la webgui (mode -SkipCredentials).

const fs = require('fs');
const https = require('https');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

function defaultInstallDir() {
    if (process.platform === 'win32' && process.env.LOCALAPPDATA) {
        return path.join(process.env.LOCALAPPDATA, 'sockseek');
    }
    return path.join(os.homedir(), '.local', 'share', 'sockseek');
}

function defaultMusicDir() {
    return path.join(os.homedir(), 'Music', 'sockseek');
}

// sockseek publie une release par plateforme :
// sockseek_<version>_win-x64.zip, _linux-x64.tar.gz, _osx-x64.tar.gz -- le
// zip Windows n'est pas executable tel quel sous Linux/macOS (format PE,
// pas ELF/Mach-O). yt-dlp publie de meme un binaire distinct par OS
// (yt-dlp.exe, yt-dlp_linux, yt-dlp_macos).
function platformNames() {
    const isWin = process.platform === 'win32';
    const isMac = process.platform === 'darwin';
    return {
        sockPattern: isWin ? /win-x64\.zip$/i : isMac ? /osx-x64\.tar\.gz$/i : /linux-x64\.tar\.gz$/i,
        sockName: isWin ? 'sockseek.exe' : 'sockseek',
        ytPattern: isWin ? /^yt-dlp\.exe$/i : isMac ? /^yt-dlp_macos$/i : /^yt-dlp_linux$/i,
        ytName: isWin ? 'yt-dlp.exe' : 'yt-dlp',
    };
}

function httpsJson(url, { headers = {}, timeout = 30000 } = {}) {
    return new Promise((resolve, reject) => {
        const req = https.get(url, { headers, timeout }, (res) => {
            if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
                res.resume();
                httpsJson(new URL(res.headers.location, url).toString(), { headers, timeout }).then(resolve, reject);
                return;
            }
            let data = '';
            res.on('data', (c) => { data += c; });
            res.on('end', () => {
                if (res.statusCode === 403 || res.statusCode === 429) {
                    reject(new Error([
                        `L'API GitHub refuse la requete (code ${res.statusCode}) : quota atteint.`,
                        '',
                        'Sans authentification, GitHub limite a 60 requetes par heure et par adresse IP.',
                        "Derriere un NAT d'entreprise, ce quota est partage avec tout le reseau.",
                        '',
                        'Deux contournements :',
                        '',
                        '  1. Attendre une heure, puis relancer.',
                        '',
                        '  2. Recuperer les URL a la main sur les pages de releases des deux projets',
                        '     (archive de la plateforme pour sockseek, binaire yt-dlp pour l\'autre)',
                        '     et les passer directement (--sockseek-url / --ytdlp-url).',
                    ].join('\n')));
                    return;
                }
                if (res.statusCode >= 400) {
                    reject(new Error(`GitHub a repondu ${res.statusCode} pour ${url}`));
                    return;
                }
                try { resolve(JSON.parse(data)); }
                catch (e) { reject(new Error(`Reponse GitHub illisible : ${e.message}`)); }
            });
        });
        req.on('timeout', () => req.destroy(new Error('Delai depasse')));
        req.on('error', reject);
    });
}

async function getLatestAsset(repo, pattern) {
    const headers = { 'User-Agent': 'sockseek-toolkit', Accept: 'application/vnd.github+json' };

    let releases = [];
    try {
        const rel = await httpsJson(`https://api.github.com/repos/${repo}/releases/latest`, { headers });
        releases = [rel];
    }
    catch (e) {
        if (/quota atteint/.test(e.message)) throw e;
        releases = [];
    }

    if (!releases.length || !releases[0].assets) {
        const all = await httpsJson(`https://api.github.com/repos/${repo}/releases?per_page=10`, { headers });
        releases = (Array.isArray(all) ? all : []).filter((r) => !r.prerelease);
    }

    for (const rel of releases) {
        const asset = (rel.assets || []).find((a) => pattern.test(a.name));
        if (asset) return { version: rel.tag_name, name: asset.name, url: asset.browser_download_url };
    }

    throw new Error(`Aucun asset correspondant a '${pattern}' dans les releases de ${repo}.`);
}

function downloadFile(url, destPath, { timeout = 300000, redirectsLeft = 5 } = {}) {
    return new Promise((resolve, reject) => {
        const file = fs.createWriteStream(destPath);
        const req = https.get(url, { headers: { 'User-Agent': 'sockseek-toolkit' }, timeout }, (res) => {
            if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
                res.resume();
                file.close();
                if (redirectsLeft <= 0) { reject(new Error('Trop de redirections.')); return; }
                downloadFile(new URL(res.headers.location, url).toString(), destPath, { timeout, redirectsLeft: redirectsLeft - 1 })
                    .then(resolve, reject);
                return;
            }
            if (res.statusCode >= 400) {
                file.close();
                reject(new Error(`Telechargement echoue (${res.statusCode}) : ${url}`));
                return;
            }
            res.pipe(file);
            file.on('finish', () => file.close(() => resolve()));
        });
        req.on('timeout', () => req.destroy(new Error('Delai depasse')));
        req.on('error', reject);
    });
}

function expandArchive(archivePath, destDir) {
    // `tar` (bsdtar sous Windows 10 1803+, GNU tar sous Linux/macOS) lit
    // aussi bien le .zip que le .tar.gz : une seule commande couvre les deux
    // formats publies par sockseek/yt-dlp, sans dependance a installer.
    fs.mkdirSync(destDir, { recursive: true });
    const result = spawnSync('tar', ['-xf', archivePath, '-C', destDir]);
    if (result.error) throw new Error(`'tar' introuvable ou en echec : ${result.error.message}`);
    if (result.status !== 0) {
        throw new Error(`echec de 'tar' sur ${archivePath} (code ${result.status}) : ${(result.stderr || '').toString().trim()}`);
    }
}

function findFileRecursive(dir, names) {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return null; }
    for (const entry of entries) {
        const full = path.join(dir, entry.name);
        if (entry.isFile() && names.includes(entry.name)) return full;
    }
    for (const entry of entries) {
        if (entry.isDirectory()) {
            const hit = findFileRecursive(path.join(dir, entry.name), names);
            if (hit) return hit;
        }
    }
    return null;
}

function copyDirContents(srcDir, destDir) {
    fs.mkdirSync(destDir, { recursive: true });
    for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
        const from = path.join(srcDir, entry.name);
        const to = path.join(destDir, entry.name);
        if (entry.isDirectory()) copyDirContents(from, to);
        else fs.copyFileSync(from, to);
    }
}

async function installBinary({ repo, pattern, name, installDir, force, explicitUrl, archive = true, log = () => {} }) {
    const exePath = path.join(installDir, name);
    if (fs.existsSync(exePath) && !force) {
        log(`Deja present. --force pour reinstaller.`);
        return exePath;
    }

    const asset = explicitUrl
        ? { version: 'fournie', name: path.basename(explicitUrl), url: explicitUrl }
        : await getLatestAsset(repo, pattern);
    log(`Version ${asset.version} : ${asset.name}`);

    fs.mkdirSync(installDir, { recursive: true });

    if (!archive) {
        // yt-dlp publie le binaire lui-meme comme asset de release (yt-dlp.exe,
        // yt-dlp_linux, yt-dlp_macos) -- pas une archive a extraire, contrairement
        // a sockseek.
        await downloadFile(asset.url, exePath);
        if (process.platform !== 'win32') fs.chmodSync(exePath, 0o755);
        log(`Installe : ${exePath}`);
        return exePath;
    }

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sockseek-install-'));
    try {
        const archivePath = path.join(tmp, asset.name);
        await downloadFile(asset.url, archivePath);

        // Extrait dans un sous-dossier dedie, pas directement dans tmp :
        // sinon l'archive elle-meme se ferait copier avec le binaire par
        // le Copy plus bas.
        const extractDir = path.join(tmp, 'extract');
        expandArchive(archivePath, extractDir);

        const found = findFileRecursive(extractDir, [name, 'sockseek.exe', 'sockseek', 'sldl.exe']);
        if (!found) throw new Error(`Binaire introuvable dans l'archive ${asset.name}.`);

        if (fs.statSync(found).isFile() && fs.readdirSync(path.dirname(found)).length === 1) {
            // Un seul fichier dans son dossier : copie directe.
            fs.copyFileSync(found, exePath);
        }
        else {
            copyDirContents(path.dirname(found), installDir);
        }

        if (!fs.existsSync(exePath)) {
            // release anterieure au renommage (sldl.exe, Windows uniquement)
            const old = path.join(installDir, 'sldl.exe');
            if (fs.existsSync(old)) fs.renameSync(old, exePath);
        }
        if (process.platform !== 'win32' && fs.existsSync(exePath)) {
            fs.chmodSync(exePath, 0o755);
        }
        log(`Installe : ${exePath}`);
    }
    finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }

    return exePath;
}

module.exports = {
    defaultInstallDir,
    defaultMusicDir,
    platformNames,
    getLatestAsset,
    downloadFile,
    expandArchive,
    installBinary,
};
