#!/usr/bin/env node
'use strict';

// Serveur web du kit sockseek : remplace l'ancienne interface WinForms
// (Show-Gui.ps1), qui ne pouvait tourner que sous Windows (System.Windows.Forms
// n'existe pas dans PowerShell 7 sur Linux). Ce serveur, lui, est du Node.js
// pur (aucune dependance a installer) : il tourne pareil sous Windows et
// Linux, et sert une page web consultee dans n'importe quel navigateur.
//
// Toute la logique metier (nettoyage des titres, lecture/ecriture du
// catalogue, invocation de sockseek/yt-dlp) reste dans les scripts
// PowerShell existants (SockseekLib.ps1 et les .ps1 a la racine) : ce
// serveur les invoque (spawn pour les actions longues, ou un court script
// PowerShell qui renvoie du JSON pour les lectures/ecritures ponctuelles)
// plutot que de reimplementer cette logique en JavaScript -- une seule
// source de verite, deja testee (tests/SockseekLib.Tests.ps1).

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');
const crypto = require('crypto');

const REPO_ROOT = path.resolve(__dirname, '..');
const PUBLIC_DIR = path.join(__dirname, 'public');
const PWSH = process.platform === 'win32' ? 'pwsh.exe' : 'pwsh';
const PORT = process.env.SOCKSEEK_WEBGUI_PORT ? Number(process.env.SOCKSEEK_WEBGUI_PORT) : 8342;

const LIB_PATH = path.join(REPO_ROOT, 'SockseekLib.ps1');
const SCRIPTS = {
    extract: path.join(REPO_ROOT, 'Get-SoulseekList.ps1'),
    resume: path.join(REPO_ROOT, 'Resume-Downloads.ps1'),
    install: path.join(REPO_ROOT, 'Install-Sockseek.ps1'),
};

// ============================================================ pwsh helpers =

function encodeCommand(script) {
    // -EncodedCommand evite tout probleme d'echappement (guillemets,
    // variables, retours a la ligne) en passant le script en Base64 --
    // bien plus robuste que de construire une chaine -Command depuis Node.
    return Buffer.from(script, 'utf16le').toString('base64');
}

/** Lance un court script PowerShell qui affiche un objet JSON sur sa sortie
 *  standard, et resout avec l'objet parse. Le script recoit deja SockseekLib.ps1
 *  dot-source (variable $Lib) et doit encapsuler ses erreurs dans un objet
 *  {"error": "..."} plutot que de planter, sans quoi le code de sortie/stderr
 *  sert de repli pour le message d'erreur. */
function runPwshJson(scriptBody) {
    return new Promise((resolve, reject) => {
        const full = `$ErrorActionPreference = 'Stop'\n[Console]::OutputEncoding = [Text.Encoding]::UTF8\n. '${LIB_PATH.replace(/'/g, "''")}'\n${scriptBody}`;
        const child = spawn(PWSH, ['-NoProfile', '-NonInteractive', '-EncodedCommand', encodeCommand(full)], {
            cwd: REPO_ROOT,
        });
        let out = '';
        let err = '';
        child.stdout.on('data', (d) => { out += d.toString('utf8'); });
        child.stderr.on('data', (d) => { err += d.toString('utf8'); });
        child.on('error', reject);
        child.on('close', (code) => {
            const trimmed = out.trim();
            if (!trimmed) {
                reject(new Error(err.trim() || `pwsh a quitte avec le code ${code} sans sortie.`));
                return;
            }
            try {
                const parsed = JSON.parse(trimmed);
                if (parsed && typeof parsed === 'object' && parsed.error) {
                    reject(new Error(parsed.error));
                    return;
                }
                resolve(parsed);
            }
            catch (e) {
                reject(new Error(`Reponse illisible de pwsh : ${trimmed.slice(0, 500)}`));
            }
        });
    });
}

function psQuote(str) {
    return `'${String(str).replace(/'/g, "''")}'`;
}

// ================================================================= jobs ====
// Une seule operation a la fois, exactement comme l'ancienne GUI WinForms
// (Start-KitJob) : deux recherches Soulseek en parallele risqueraient un
// bannissement de 30 minutes cote serveur Soulseek.
let currentJob = null; // { proc, description, lines: [], done, exitCode, listeners: Set<res> }

function broadcast(job, event, data) {
    const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of job.listeners) {
        res.write(payload);
    }
}

function startJob(scriptPath, args, description) {
    if (currentJob && !currentJob.done) {
        throw new Error("Une operation est deja en cours. Attends qu'elle se termine.");
    }

    const spawnOpts = { cwd: REPO_ROOT, detached: process.platform !== 'win32' };
    const proc = spawn(PWSH, ['-NoProfile', '-NonInteractive', '-File', scriptPath, ...args], spawnOpts);

    const job = { proc, description, lines: [], done: false, exitCode: null, listeners: new Set() };
    currentJob = job;

    const onData = (d) => {
        const text = d.toString('utf8');
        for (const line of text.split(/\r?\n/)) {
            if (line.length === 0) continue;
            // eslint-disable-next-line no-control-regex
            const clean = line.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, ''); // codes ANSI (Write-Host -ForegroundColor)
            job.lines.push(clean);
            broadcast(job, 'log', { line: clean });
        }
    };
    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);

    proc.on('close', (code) => {
        job.done = true;
        job.exitCode = code;
        broadcast(job, 'done', { code, description });
    });
    proc.on('error', (e) => {
        job.done = true;
        job.exitCode = -1;
        job.lines.push(`[erreur] ${e.message}`);
        broadcast(job, 'done', { code: -1, description, error: e.message });
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
        // processus) : cibler -pid tue tout l'arbre (pwsh + sockseek/yt-dlp
        // qu'il a lances), pas seulement pwsh lui-meme.
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

function findOnPath(names) {
    const pathEnv = process.env.PATH || '';
    const exts = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
    const dirs = pathEnv.split(path.delimiter).filter(Boolean);
    for (const name of names) {
        for (const dir of dirs) {
            for (const ext of exts) {
                const candidate = path.join(dir, name + ext);
                try {
                    if (fs.statSync(candidate).isFile()) return candidate;
                }
                catch (e) { /* absent ici, on continue */ }
            }
        }
    }
    return null;
}

function defaultInstallDir() {
    if (process.platform === 'win32' && process.env.LOCALAPPDATA) {
        return path.join(process.env.LOCALAPPDATA, 'sockseek');
    }
    return path.join(require('os').homedir(), '.local', 'share', 'sockseek');
}

async function findBinary(names) {
    let found = findOnPath(names);
    if (found) return found;
    const dir = defaultInstallDir();
    for (const name of names) {
        const candidate = path.join(dir, process.platform === 'win32' ? `${name}.exe` : name);
        try { if (fs.statSync(candidate).isFile()) return candidate; } catch (e) { /* absent */ }
    }
    return null;
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
    try {
        defaultOutputDir = await runPwshJson('Get-DefaultOutputDir | ConvertTo-Json');
    } catch (e) { /* affiche quand meme le reste du statut */ }

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
        const data = await runPwshJson(`
try {
    $confPath = Get-SockseekConfPath
    if (-not (Test-Path -LiteralPath $confPath)) {
        [pscustomobject]@{ hasConf = $false } | ConvertTo-Json
    }
    else {
        $userLine = Get-Content -LiteralPath $confPath -Encoding utf8 -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '^\\s*username\\s*=' } | Select-Object -First 1
        $user = $null
        if ($userLine -and $userLine -match '^\\s*username\\s*=\\s*(.+?)\\s*$') { $user = $matches[1] }
        [pscustomobject]@{ hasConf = $true; username = $user } | ConvertTo-Json
    }
}
catch { [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json }
`);
        sendJson(res, 200, data);
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/config/credentials', async (req, res) => {
    const body = await readBody(req);
    if (!body.username || !body.password) { sendJson(res, 400, { error: 'username et password requis.' }); return; }
    try {
        await runPwshJson(`
try {
    Set-SockseekCredentials -Username ${psQuote(body.username)} -Password ${psQuote(body.password)}
    [pscustomobject]@{ ok = $true } | ConvertTo-Json
}
catch { [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json }
`);
        sendJson(res, 200, { ok: true });
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/config/default-dir', async (req, res) => {
    const body = await readBody(req);
    if (!body.path) { sendJson(res, 400, { error: 'path requis.' }); return; }
    try {
        await runPwshJson(`
try {
    Set-DefaultOutputDir -OutputDir ${psQuote(body.path)}
    [pscustomobject]@{ ok = $true } | ConvertTo-Json
}
catch { [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json }
`);
        sendJson(res, 200, { ok: true });
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/config/import', async (req, res) => {
    const body = await readBody(req);
    if (!body.path) { sendJson(res, 400, { error: 'path requis.' }); return; }
    const nameArg = body.name ? ` -Name ${psQuote(body.name)}` : '';
    try {
        const data = await runPwshJson(`
try {
    $r = Import-PlaylistFolder -FolderPath ${psQuote(body.path)}${nameArg}
    $r | ConvertTo-Json
}
catch { [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json }
`);
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
        const data = await runPwshJson(`
try {
    $rows = foreach ($e in @(Read-Catalogue)) {
        try {
            $pending = @(Get-PlaylistPending -Entry $e)
            $done = [int]$e.Total - $pending.Count
            if ($done -lt 0) { $done = [int]$e.Ok }
            [pscustomobject]@{
                Name = $e.Name; Url = $e.Url; Manquants = $pending.Count; Recuperes = $done
                Runs = $e.RunCount; LastRun = $e.LastRun; OutputDir = $e.OutputDir; Error = $false
            }
        }
        catch {
            [pscustomobject]@{
                Name = $e.Name; Url = $e.Url; Manquants = '?'; Recuperes = '?'
                Runs = $e.RunCount; LastRun = $e.LastRun; OutputDir = $e.OutputDir; Error = $true
            }
        }
    }
    , @($rows) | ConvertTo-Json -Depth 4
}
catch { [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json }
`);
        sendJson(res, 200, Array.isArray(data) ? data : (data ? [data] : []));
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('GET', '/api/playlists/detail', async (req, res, query) => {
    const url = query.get('url');
    if (!url) { sendJson(res, 400, { error: 'url requis.' }); return; }
    try {
        const data = await runPwshJson(`
try {
    $e = @(Read-Catalogue) | Where-Object { $_.Url -eq ${psQuote(url)} } | Select-Object -First 1
    if (-not $e) { [pscustomobject]@{ error = 'Playlist introuvable.' } | ConvertTo-Json; return }
    $rapportPath = Join-Path $e.OutputDir 'rapport.csv'
    $rows = if (Test-Path -LiteralPath $rapportPath) { @(Import-Csv -LiteralPath $rapportPath) } else { @() }
    $log = Get-ChildItem -LiteralPath $e.OutputDir -Filter 'sockseek-*.log' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }
    [pscustomobject]@{ outputDir = $e.OutputDir; logPath = $log; rows = @($rows) } | ConvertTo-Json -Depth 4
}
catch { [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json }
`);
        sendJson(res, 200, data);
    }
    catch (e) { sendJson(res, 500, { error: e.message }); }
});

route('POST', '/api/playlists/delete', async (req, res) => {
    const body = await readBody(req);
    if (!body.url) { sendJson(res, 400, { error: 'url requis.' }); return; }
    try {
        await runPwshJson(`
try {
    Remove-CatalogueEntry -Url ${psQuote(body.url)}${body.deleteFiles ? ' -DeleteFiles' : ''}
    [pscustomobject]@{ ok = $true } | ConvertTo-Json
}
catch { [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json }
`);
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
        else {
            currentJob.listeners.add(res);
        }
    }

    const keepAlive = setInterval(() => { try { res.write(': ping\n\n'); } catch (e) { /* client parti */ } }, 20000);
    req.on('close', () => {
        clearInterval(keepAlive);
        if (currentJob) currentJob.listeners.delete(res);
    });
});

// ---------------------------------------------------------- fichiers statiques
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };

function serveStatic(req, res, pathname) {
    const rel = pathname === '/' ? 'index.html' : pathname.slice(1);
    const filePath = path.join(PUBLIC_DIR, rel);
    if (!filePath.startsWith(PUBLIC_DIR)) { res.writeHead(403); res.end(); return; }
    fs.readFile(filePath, (err, data) => {
        if (err) { res.writeHead(404); res.end('Introuvable'); return; }
        res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream' });
        res.end(data);
    });
}

const server = http.createServer(async (req, res) => {
    const parsed = new URL(req.url, 'http://localhost');
    const match = routes.find((r) => r.method === req.method && r.pattern === parsed.pathname);
    if (match) {
        try {
            await match.handler(req, res, parsed.searchParams);
        }
        catch (e) {
            if (!res.headersSent) sendJson(res, 500, { error: e.message });
        }
        return;
    }
    if (req.method === 'GET') { serveStatic(req, res, parsed.pathname); return; }
    res.writeHead(404); res.end();
});

server.listen(PORT, () => {
    console.log(`Kit sockseek -- interface web sur http://localhost:${PORT}`);
});
