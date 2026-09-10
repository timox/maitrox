#!/usr/bin/env node
'use strict';

// Portage de Resume-Downloads.ps1 : reprend en une seule passe tous les
// titres manquants des playlists deja traitees.
//
//   node bin/resume.js -List
//   node bin/resume.js
//   node bin/resume.js -Only "sans-retour" -DryRun

const fs = require('fs');
const path = require('path');
const { runInherit } = require('../lib/proc');
const { parseArgs } = require('../lib/argv');
const { readCatalogue, saveCatalogue, getPlaylistPending } = require('../lib/catalogue');
const { getCataloguePath } = require('../lib/paths');
const { getRunResults } = require('../lib/runResults');
const { writeM3UPlaylist, paint } = require('../lib/playlist');
const { writeCsv } = require('../lib/csv');
const { findOnPath } = require('../lib/findBinary');

function findExtra(here) {
    const names = ['sockseek.exe', 'sldl.exe', 'sockseek', 'sldl'];
    const search = (dir, depth) => {
        let entries;
        try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return null; }
        for (const e of entries) {
            if (e.isFile() && names.includes(e.name)) return path.join(dir, e.name);
        }
        if (depth <= 0) return null;
        for (const e of entries) {
            if (e.isDirectory()) {
                const hit = search(path.join(dir, e.name), depth - 1);
                if (hit) return hit;
            }
        }
        return null;
    };
    return search(here, 2);
}

function stampNow() {
    const d = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

async function main() {
    const args = parseArgs(process.argv.slice(2), ['List', 'DryRun', 'Forget']);
    const list = !!args.List;
    const only = args.Only;
    const dryRun = !!args.DryRun;
    const forget = !!args.Forget;
    const sockseekPathArg = args.SockseekPath;

    let entries = readCatalogue();

    if (entries.length === 0) {
        console.log('');
        console.log(paint('yellow', 'Le catalogue est vide.'));
        console.log('Il se remplit tout seul a chaque run de bin/extract.js -Download.');
        console.log(paint('gray', `Catalogue : ${getCataloguePath()}`));
        return 0;
    }

    if (only) {
        entries = entries.filter((e) => (e.Url || '').includes(only) || (e.Name || '').includes(only));
        if (entries.length === 0) {
            console.warn(`Aucune playlist ne correspond a '${only}'.`);
            return 1;
        }
    }

    // ------------------------------------------------------------------ oubli ---
    if (forget) {
        if (!only) {
            console.warn("-Forget exige -Only, pour ne pas vider le catalogue par accident.");
            return 1;
        }
        const all = readCatalogue();
        const urls = new Set(entries.map((e) => e.Url));
        saveCatalogue(all.filter((e) => !urls.has(e.Url)));
        console.log(paint('green', `${entries.length} entree(s) retiree(s) du catalogue.`));
        console.log(paint('gray', 'Les fichiers deja telecharges ne sont pas touches.'));
        return 0;
    }

    // --------------------------------------------------------------- etat des lieux
    console.log('');
    console.log(paint('gray', `Catalogue : ${getCataloguePath()}`));
    console.log('');

    const state = entries.map((e) => ({ entry: e, pending: getPlaylistPending(e) }));

    for (const s of state) {
        const e = s.entry;
        let done = Number(e.Total || 0) - s.pending.length;
        if (done < 0) done = Number(e.Ok || 0);
        const lastRun = e.LastRun ? new Date(e.LastRun).toISOString().replace('T', ' ').slice(0, 16) : '';
        console.log(`  ${(e.Name || '').padEnd(38)} manquants=${String(s.pending.length).padStart(3)} recuperes=${String(done).padStart(3)} runs=${e.RunCount || 0} dernier=${lastRun}`);
        console.log(paint('gray', `    ${e.OutputDir || ''}`));
    }

    if (list) {
        console.log('');
        console.log(paint('cyan', 'Pour relancer les titres manquants : node bin/resume.js'));
        return 0;
    }

    // ------------------------------------------------- regroupement par dossier --
    const todo = state.filter((s) => s.pending.length > 0);

    if (todo.length === 0) {
        console.log(paint('green', 'Rien a reprendre : toutes les playlists sont completes.'));
        return 0;
    }

    // Un meme morceau peut manquer dans plusieurs playlists partageant un
    // dossier. On ne le cherche qu'une fois.
    const byDir = new Map();
    for (const s of todo) {
        const dir = s.entry.OutputDir;
        if (!byDir.has(dir)) byDir.set(dir, new Map());
        const bucket = byDir.get(dir);
        for (const p of s.pending) {
            const key = `${p.Artist}|${p.Title}`.toLowerCase().trim();
            if (!bucket.has(key)) bucket.set(key, { Artist: p.Artist, Title: p.Title, Length: p.Length });
        }
    }

    const grandTotal = [...byDir.values()].reduce((sum, m) => sum + m.size, 0);
    const minutes = Math.ceil(grandTotal / 34.0) * 220 / 60;

    console.log(paint('cyan', `${grandTotal} titre(s) a reprendre, repartis sur ${byDir.size} dossier(s).`));
    console.log(paint('gray', `Duree minimale estimee : ${Math.round(minutes)} minutes (limite de recherches Soulseek).`));

    if (dryRun) {
        console.log('');
        for (const [dir, bucket] of byDir) {
            console.log(dir);
            for (const t of bucket.values()) console.log(paint('gray', `    ${t.Artist} - ${t.Title}`));
        }
        console.log('');
        console.log(paint('yellow', '-DryRun : rien n\'a ete lance.'));
        return 0;
    }

    // ---------------------------------------------------------------- sockseek ---
    let exe = null;
    if (sockseekPathArg) {
        if (!fs.existsSync(sockseekPathArg)) throw new Error(`Executable introuvable : ${sockseekPathArg}`);
        exe = fs.realpathSync(sockseekPathArg);
    }
    else {
        exe = findOnPath(['sockseek', 'sldl']) || findExtra(path.resolve(__dirname, '..'));
    }
    if (!exe) throw new Error('sockseek introuvable. Passe -SockseekPath, ou relance node bin/install.js.');

    const stamp = stampNow();

    for (const [dir, bucket] of byDir) {
        const tracks = [...bucket.values()];

        console.log('');
        console.log(paint('white', '================================================================'));
        console.log(paint('white', ` ${dir}  --  ${tracks.length} titre(s)`));
        console.log(paint('white', '================================================================'));

        const retryCsv = path.join(dir, `reprise-${stamp}.csv`);
        fs.writeFileSync(retryCsv, writeCsv(tracks, ['Artist', 'Title', 'Length']), 'utf8');

        const idxPath = path.join(dir, '_index.csv');
        const logPath = path.join(dir, `sockseek-reprise-${stamp}.log`);

        const sockArgs = [
            retryCsv,
            '--index-path', idxPath,
            '--log-file', logPath,
            '--song',
            '--artist-maybe-wrong',
            '--length-tol', '10',
            '--pref-format', 'flac,wav',
            '--remove-ft',
            '--name-format', '{artist( - )title|filename}',
            '--output-dir', dir,
        ];

        const run = await runInherit(exe, sockArgs);
        if (run.status !== 0) {
            console.warn(`sockseek a rendu le code ${run.status}. Journal : ${logPath}`);
        }

        try { fs.unlinkSync(retryCsv); } catch (e) { /* deja absent */ }
    }

    // ------------------------------------------ regeneration rapports/playlists --
    console.log('');
    console.log(paint('cyan', 'Mise a jour des playlists et des rapports...'));

    const catalogue = readCatalogue();
    let gagnes = 0;

    for (const s of todo) {
        const e = s.entry;
        const before = s.pending.length;

        const idx = e.IndexPath && fs.existsSync(e.IndexPath) ? e.IndexPath : path.join(e.OutputDir, '_index.csv');
        const src = e.SourceCsv && fs.existsSync(e.SourceCsv) ? e.SourceCsv : null;

        const res = getRunResults({ indexPath: idx, outputDir: e.OutputDir, sourceCsv: src });
        const ok = res.filter((r) => r.Reussi);
        const after = res.filter((r) => !r.Reussi).length;
        gagnes += before - after;

        writeM3UPlaylist({ results: res, outputDir: e.OutputDir, playlistPath: path.join(e.OutputDir, 'playlist.m3u') });

        fs.writeFileSync(path.join(e.OutputDir, 'rapport.csv'), writeCsv(res.map((r) => ({
            Artist: r.Artist, Title: r.Title, Statut: r.Statut, Detail: r.Detail, Chemin: r.Chemin,
        })), ['Artist', 'Title', 'Statut', 'Detail', 'Chemin']), 'utf8');

        const entry = catalogue.find((c) => c.Url === e.Url);
        if (entry) {
            const d = new Date();
            const pad = (n) => String(n).padStart(2, '0');
            entry.LastRun = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
            entry.RunCount = Number(entry.RunCount || 0) + 1;
            entry.Total = res.length;
            entry.Ok = ok.length;
        }

        const gain = before - after;
        const paintColor = gain > 0 ? 'green' : 'gray';
        console.log(paint(paintColor, `  ${(e.Name || '').padEnd(40)} ${String(gain).padStart(3)} recuperes, ${String(after).padStart(3)} restants`));
    }

    saveCatalogue(catalogue);

    console.log('');
    if (gagnes > 0) {
        console.log(paint('green', `${gagnes} titre(s) recupere(s) sur cette reprise.`));
    }
    else {
        console.log(paint('yellow', 'Aucun titre supplementaire cette fois.'));
        console.log(paint('gray', "Sur du P2P c'est normal : reessaie dans quelques jours, a une"));
        console.log(paint('gray', 'heure ou davantage de pairs sont connectes.'));
    }

    return 0;
}

if (require.main === module) {
    main().then((code) => process.exit(code || 0)).catch((e) => {
        console.error(`[ERREUR] ${e.message}`);
        process.exit(1);
    });
}

module.exports = { main };
