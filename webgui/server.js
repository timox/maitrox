#!/usr/bin/env node
'use strict';

// Serveur web du kit sockseek : remplace l'ancienne interface WinForms
// (Show-Gui.ps1), qui ne pouvait tourner que sous Windows. Ce serveur est
// du Node.js pur (aucune dependance a installer) : il tourne pareil sous
// Windows et Linux, et sert une page web consultee dans n'importe quel
// navigateur.
//
// Toute la logique metier (nettoyage des titres, lecture/ecriture du
// catalogue, invocation de sockseek/yt-dlp) vit dans lib/ (portage Node de
// l'ancien SockseekLib.ps1) : ce serveur l'appelle directement pour les
// lectures/ecritures ponctuelles, et lance les scripts de bin/ dans un
// sous-processus node pour les actions longues (extraction, telechargement,
// installation) -- une seule source de verite, testee dans tests/.

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const PUBLIC_DIR = path.join(__dirname, 'public');
const PORT = process.env.SOCKSEEK_WEBGUI_PORT ? Number(process.env.SOCKSEEK_WEBGUI_PORT) : 8342;

const { getDefaultOutputDir, setDefaultOutputDir, setSockseekCredentials, getSockseekConfPath } = require('../lib/paths');
const { readCatalogue, getPlaylistPending, importPlaylistFolder, removeCatalogueEntry } = require('../lib/catalogue');
const { parseCsv } = require('../lib/csv');
const { findBinary } = require('../lib/findBinary');

const SCRIPTS = {
    extract: path.join(REPO_ROOT, 'bin', 'extract.js'),
    resume: path.join(REPO_ROOT, 'bin', 'resume.js'),
    install: path.join(REPO_ROOT, 'bin', 'install.js'),
};

// ================================================================= jobs ====
// Une seule operation a la fois, exactement comme l'ancienne GUI WinForms
// (Start-KitJob) : deux recherches Soulseek en parallele risqueraient un
// bannissement de 30 minutes cote serveur Soulseek.
let currentJob = null; // { proc, description, lines: [], done, exitCode }

// Les navigateurs se connectent typiquement AVANT qu'un job existe (page
// ouverte, rien encore lance) : un registre de listeners PAR job perd donc
// toute connexion deja ouverte des qu'un nouveau job est cree. Un registre
// global, independant du cycle de vie de chaque job, evite ca.
const sseClients = new Set();

function broadcast(event, data) {
    const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of sseClients) {
        try { res.write(payload); } catch (e) { /* client deconnecte : le prochain close() le retirera */ }
    }
}

function startJob(scriptPath, args, description) {
    if (currentJob && !currentJob.done) {
        throw new Error("Une operation est deja en cours. Attends qu'elle se termine.");
    }

    const spawnOpts = { cwd: REPO_ROOT, detached: process.platform !== 'win32' };
    const proc = spawn(process.execPath, [scriptPath, ...args], spawnOpts);

    const job = { proc, description, lines: [], done: false, exitCode: null };
    currentJob = job;
    broadcast('start', { description });

    const onData = (d) => {
        const text = d.toString('utf8');
        for (const line of text.split(/\r?\n/)) {
            if (line.length === 0) continue;
            // eslint-disable-next-line no-control-regex
            const clean = line.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, ''); // codes ANSI
            job.lines.push(clean);
            broadcast('log', { line: clean });
        }
    };
    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);

    proc.on('close', (code) => {
        job.done = true;
        job.exitCode = code;
        broadcast('done', { code, description });
    });
    proc.on('error', (e) => {
        job.done = true;
        job.exitCode = -1;
        const line = `[ERREUR] ${e.message}`;
        job.lines.push(line);
        broadcast('log', { line });
        broadcast('done', { code: -1, description, error: e.message });
    });

    return job;
}

function killCurrentJob() {
    if (!currentJob || currentJob.done) return false;
    const { proc } = currentJob;
    if (process.platform === 'win32') {
        execFile('taskkill', ['/PID', String(proc.pid), '/T', '/F'], () => {});
    }
    else {
        // proc a ete lance "detached" (chef de son propre groupe de
        // processus) : cibler -pid tue tout l'arbre (node + sockseek/yt-dlp
        // qu'il a lances), pas seulement le sous-processus node lui-meme.
        try { process.kill(-proc.pid, 'SIGKILL'); }
        catch (e) { try { proc.kill('SIGKILL'); } catch (e2) { /* deja mort */ } }
    }
    return true;
}

// ============================================================== requetes ===

function sendJson(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        let data = '';
        req.on('data', (c) => { data += c; if (data.length > 5_000_000) req.destroy(); });
        req.on('end', () => {
            if (!data) { resolve({}); return; }
            try { resolve(JSON.parse(data)); }
            catch (e) { reject(new Error('Corps de requete JSON invalide.')); }
        });
        req.on('error', reject);
    });
}

function fetchJson(url) {
    return new Promise((resolve, reject) => {
        const req = https.get(url, {
            headers: { 'User-Agent': 'sockseek-toolkit', Accept: 'application/vnd.github+json' },
            timeout: 8000,
        }, (res) => {
            let data = '';
            res.on('data', (c) => { data += c; });
            res.on('end', () => {
                try { resolve(JSON.parse(data)); }
                catch (e) { reject(e); }
            });
        });
        req.on('timeout', () => req.destroy(new Error('Delai depasse')));
        req.on('error', reject);
    });
}

function getInstalledVersion(exePath) {
    return new Promise((resolve) => {
        if (!exePath) { resolve(null); return; }
        execFile(exePath, ['--version'], { timeout: 8000 }, (err, stdout) => {
            if (err) { resolve(null); return; }
            resolve((stdout || '').split(/\r?\n/)[0].trim() || null);
        });
    });
}

// ---------------------------------------------------------------- routes ---

const routes = [];
function route(method, pattern, handler) { routes.push({ method, pattern, handler }); }

route('GET', '/api/status', async (req, res) => {
    const sockPath = await findBinary(['sockseek', 'sldl']);
    const ytPath = await findBinary(['yt-dlp']);
    const [sockVersion, ytVersion] = await Promise.all([
        getInstalledVersion(sockPath),
        getInstalledVersion(ytPath),
    ]);
    let defaultOutputDir = null;
    try { defaultOutputDir = getDefaultOutputDir(); } catch (e) { /* affiche quand meme le reste du statut */ }

    sendJson(res, 200, {
        sockseek: { found: !!sockPath, path: sockPath, version: sockVersion },
        ytdlp: { found: !!ytPath, path: ytPath, version: ytVersion },
        defaultOutputDir,
    });
});

route('GET', '/api/updates', async (req, res) => {
    const sockPath = await findBinary(['sockseek', 'sldl']);
    const ytPath = await findBinary(['yt-dlp']);
    const result = {};
    for (const [key, repo, exePath] of [
        ['sockseek', 'fiso64/sockseek', sockPath],
        ['ytdlp', 'yt-dlp/yt-dlp', ytPath],
    ]) {
        if (!exePath) { result[key] = { available: false }; continue; }
        try {
            const rel = await fetchJson(`https://api.github.com/repos/${repo}/releases/latest`);
            const installed = await getInstalledVersion(exePath);
            const latest = rel && rel.tag_name;
            result[key] = {
                available: true,
                installed,
                latest,
                upToDate: !!(latest && installed && latest.replace(/^v/, '') === installed),
            };
        }
        catch (e) {
            result[key] = { available: true, error: 'Verification impossible (reseau/quota GitHub).' };
        }
    }
    sendJson(res, 200, result);
});

route('GET', '/api/config', async (req, res) => {
    try {
        const confPath = getSockseekConfPath();
        if (!fs.existsSync(confPath)) { sendJson(res, 200, { hasConf: false }); return; }
        const lines = fs.readFileSync(confPath, 'utf8').split(/\r?\n/);
        const userLine = lines.find((l) => /^\s*username\s*=/.test(l));
        const m = userLine && userLine.match(/^\s*username\s*=\s*(.+?)\s*$/);
        sendJson(res, 200, { hasConf: true, username: m ? m[1] : null });
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/config/credentials', async (req, res) => {
    const body = await readBody(req);
    if (!body.username || !body.password) { sendJson(res, 400, { error: 'username et password requis.' }); return; }
    try {
        setSockseekCredentials({ username: body.username, password: body.password });
        sendJson(res, 200, { ok: true });
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/config/default-dir', async (req, res) => {
    const body = await readBody(req);
    if (!body.path) { sendJson(res, 400, { error: 'path requis.' }); return; }
    try {
        setDefaultOutputDir(body.path);
        sendJson(res, 200, { ok: true });
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/config/import', async (req, res) => {
    const body = await readBody(req);
    if (!body.path) { sendJson(res, 400, { error: 'path requis.' }); return; }
    try {
        const data = importPlaylistFolder({ folderPath: body.path, name: body.name });
        sendJson(res, 200, data);
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('GET', '/api/browse', async (req, res, query) => {
    let dir = query.get('path') || require('os').homedir();
    try {
        const stat = fs.statSync(dir);
        if (!stat.isDirectory()) dir = path.dirname(dir);
    }
    catch (e) { dir = require('os').homedir(); }
    let entries = [];
    try {
        entries = fs.readdirSync(dir, { withFileTypes: true })
            .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
            .map((e) => e.name)
            .sort((a, b) => a.localeCompare(b));
    }
    catch (e) { /* dossier illisible : liste vide */ }
    sendJson(res, 200, { path: dir, parent: path.dirname(dir), dirs: entries });
});

route('POST', '/api/open-folder', async (req, res) => {
    const body = await readBody(req);
    if (!body.path) { sendJson(res, 400, { error: 'path requis.' }); return; }
    const opener = process.platform === 'win32' ? 'explorer.exe' : (process.platform === 'darwin' ? 'open' : 'xdg-open');
    execFile(opener, [body.path], () => {});
    sendJson(res, 200, { ok: true });
});

route('GET', '/api/playlists', async (req, res) => {
    try {
        const rows = readCatalogue().map((e) => {
            try {
                const pending = getPlaylistPending(e);
                let done = Number(e.Total || 0) - pending.length;
                if (done < 0) done = Number(e.Ok || 0);
                return {
                    Name: e.Name, Url: e.Url, Manquants: pending.length, Recuperes: done,
                    Runs: e.RunCount, LastRun: e.LastRun, OutputDir: e.OutputDir, Error: false,
                };
            }
            catch (e2) {
                return {
                    Name: e.Name, Url: e.Url, Manquants: '?', Recuperes: '?',
                    Runs: e.RunCount, LastRun: e.LastRun, OutputDir: e.OutputDir, Error: true,
                };
            }
        });
        sendJson(res, 200, rows);
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('GET', '/api/playlists/detail', async (req, res, query) => {
    const url = query.get('url');
    if (!url) { sendJson(res, 400, { error: 'url requis.' }); return; }
    try {
        const entry = readCatalogue().find((e) => e.Url === url);
        if (!entry) { sendJson(res, 200, { error: 'Playlist introuvable.' }); return; }

        const rapportPath = path.join(entry.OutputDir, 'rapport.csv');
        const rows = fs.existsSync(rapportPath) ? parseCsv(fs.readFileSync(rapportPath, 'utf8')) : [];

        let logPath = null;
        try {
            const logs = fs.readdirSync(entry.OutputDir)
                .filter((n) => /^sockseek-.*\.log$/.test(n))
                .map((n) => path.join(entry.OutputDir, n));
            if (logs.length) {
                logPath = logs.map((f) => ({ f, mtime: fs.statSync(f).mtimeMs })).sort((a, b) => b.mtime - a.mtime)[0].f;
            }
        }
        catch (e) { /* dossier illisible : pas de journal */ }

        sendJson(res, 200, { outputDir: entry.OutputDir, logPath, rows });
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/playlists/delete', async (req, res) => {
    const body = await readBody(req);
    if (!body.url) { sendJson(res, 400, { error: 'url requis.' }); return; }
    try {
        removeCatalogueEntry(body.url, { deleteFiles: !!body.deleteFiles });
        sendJson(res, 200, { ok: true });
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/jobs/start', async (req, res) => {
    const body = await readBody(req);
    try {
        let scriptPath;
        let args = [];
        let description;
        switch (body.kind) {
            case 'extract': {
                if (!body.url) throw new Error('url requis.');
                scriptPath = SCRIPTS.extract;
                args = ['-Url', body.url];
                if (body.mode === 'test') args.push('-Download', '-PrintOnly');
                else if (body.mode === 'download') args.push('-Download');
                if (body.cookiesFromBrowser) args.push('-CookiesFromBrowser', body.cookiesFromBrowser);
                description = 'extraction de la playlist';
                break;
            }
            case 'resume-all':
                scriptPath = SCRIPTS.resume;
                description = 'reprise de toutes les playlists';
                break;
            case 'resume-one':
                if (!body.name) throw new Error('name requis.');
                scriptPath = SCRIPTS.resume;
                args = ['-Only', body.name];
                description = `reprise de la playlist '${body.name}'`;
                break;
            case 'test-one':
                if (!body.name) throw new Error('name requis.');
                scriptPath = SCRIPTS.resume;
                args = ['-Only', body.name, '-DryRun'];
                description = `test de la playlist '${body.name}'`;
                break;
            case 'install':
                scriptPath = SCRIPTS.install;
                args = ['-SkipCredentials'];
                description = 'installation / mise a jour de sockseek et yt-dlp';
                break;
            default:
                throw new Error(`Type d'operation inconnu : ${body.kind}`);
        }
        const job = startJob(scriptPath, args, description);
        sendJson(res, 200, { started: true, description: job.description });
    }
    catch (e) { sendJson(res, 409, { error: e.message }); }
});

route('POST', '/api/jobs/stop', async (req, res) => {
    const stopped = killCurrentJob();
    sendJson(res, 200, { stopped });
});

route('GET', '/api/jobs/status', async (req, res) => {
    if (!currentJob) { sendJson(res, 200, { active: false }); return; }
    sendJson(res, 200, {
        active: !currentJob.done,
        description: currentJob.description,
        done: currentJob.done,
        exitCode: currentJob.exitCode,
        lines: currentJob.lines,
    });
});

route('GET', '/api/jobs/stream', async (req, res) => {
    res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
    });
    res.write(': connecte\n\n');

    if (currentJob) {
        for (const line of currentJob.lines) {
            res.write(`event: log\ndata: ${JSON.stringify({ line })}\n\n`);
        }
        if (currentJob.done) {
            res.write(`event: done\ndata: ${JSON.stringify({ code: currentJob.exitCode, description: currentJob.description })}\n\n`);
        }
    }
    // Ajoute a la liste globale dans tous les cas (job en cours, deja
    // termine, ou pas encore demarre) : ainsi la prochaine operation lancee
    // depuis cette meme page, meme si elle est arrivee bien avant, recevra
    // quand meme le flux en direct.
    sseClients.add(res);

    const keepAlive = setInterval(() => { try { res.write(': ping\n\n'); } catch (e) { /* client parti */ } }, 20000);
    req.on('close', () => {
        clearInterval(keepAlive);
        sseClients.delete(res);
    });
});

// ============================================================== static ====

const MIME = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.ico': 'image/x-icon',
};

function serveStatic(req, res, pathname) {
    let rel = pathname === '/' ? '/index.html' : pathname;
    const filePath = path.normalize(path.join(PUBLIC_DIR, rel));
    if (!filePath.startsWith(PUBLIC_DIR)) { res.writeHead(403); res.end(); return; }
    fs.readFile(filePath, (err, data) => {
        if (err) { res.writeHead(404); res.end('Not found'); return; }
        const ext = path.extname(filePath);
        res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
        res.end(data);
    });
}

// =================================================================== http ==

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const match = routes.find((r) => r.method === req.method && r.pattern === url.pathname);
    if (match) {
        try { await match.handler(req, res, url.searchParams); }
        catch (e) { sendJson(res, 500, { error: e.message }); }
        return;
    }
    if (req.method === 'GET') { serveStatic(req, res, url.pathname); return; }
    res.writeHead(404); res.end('Not found');
});

server.listen(PORT, () => {
    console.log(`Kit sockseek -- interface web sur http://localhost:${PORT}`);
});
