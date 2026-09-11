#!/usr/bin/env node
'use strict';

// Portage de Build-Playlist.ps1 : analyse le resultat d'un run sockseek --
// rapport d'echecs et playlist M3U. Utilisable seul apres un run manuel.
//
//   node bin/build-playlist.js -OutputDir "D:\Music\techno"

const fs = require('fs');
const path = require('path');
const { parseArgs } = require('../lib/argv');
const { getRunResults } = require('../lib/runResults');
const { writeM3UPlaylist, showRunSummary, paint } = require('../lib/playlist');
const { registerPlaylist } = require('../lib/catalogue');
const { writeCsv } = require('../lib/csv');
const log = require('../lib/log');

function findIndexRecursive(dir) {
    let best = null;
    const walk = (d) => {
        let entries;
        try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { return; }
        for (const entry of entries) {
            const full = path.join(d, entry.name);
            if (entry.isDirectory()) walk(full);
            else if (entry.name === '_index.csv') {
                const mtime = fs.statSync(full).mtimeMs;
                if (!best || mtime > best.mtime) best = { full, mtime };
            }
        }
    };
    walk(dir);
    return best ? best.full : null;
}

function buildPlaylist(opts) {
    let { indexPath, outputDir, sourceCsv, playlistPath, reportPath, register, relative = true } = opts;

    if (!outputDir || !fs.existsSync(outputDir)) {
        throw new Error(`Dossier de sortie introuvable : ${outputDir}`);
    }
    outputDir = fs.realpathSync(outputDir);

    if (!playlistPath) playlistPath = path.join(outputDir, 'playlist.m3u');
    if (!reportPath) reportPath = path.join(outputDir, 'rapport.csv');

    if (!indexPath) indexPath = findIndexRecursive(outputDir);

    if (indexPath && fs.existsSync(indexPath)) {
        console.log(paint('gray', `Index : ${indexPath}`));
    }
    else {
        log.warn('Aucun index sockseek trouve : playlist construite en balayant les fichiers audio du dossier, sans detail des echecs.');
    }

    const results = getRunResults({ indexPath, outputDir, sourceCsv });

    writeM3UPlaylist({ results, outputDir, playlistPath, relative });

    fs.writeFileSync(reportPath, writeCsv(results.map((r) => ({
        Artist: r.Artist, Title: r.Title, Statut: r.Statut, Detail: r.Detail, Chemin: r.Chemin,
    })), ['Artist', 'Title', 'Statut', 'Detail', 'Chemin']), 'utf8');

    showRunSummary(results);

    console.log('');
    console.log(paint('green', `  Playlist : ${playlistPath}`));
    console.log(paint('green', `  Rapport  : ${reportPath}`));
    console.log(paint('white', '=========================================='));

    if (register && sourceCsv) {
        const ok = results.filter((r) => r.Reussi).length;
        registerPlaylist({ url: register, outputDir, sourceCsv, indexPath, total: results.length, ok, hasOk: true });
        console.log(paint('gray', '  Catalogue mis a jour : reprise possible via bin/resume.js'));
    }

    return results;
}

if (require.main === module) {
    const args = parseArgs(process.argv.slice(2));
    try {
        const results = buildPlaylist({
            indexPath: args.IndexPath,
            outputDir: args.OutputDir,
            sourceCsv: args.SourceCsv,
            playlistPath: args.PlaylistPath,
            reportPath: args.ReportPath,
            register: args.Register,
            relative: args.Relative === undefined ? true : args.Relative !== 'false',
        });
        const failed = results.filter((r) => !r.Reussi);
        process.exit(failed.length > 0 ? 10 : 0);
    }
    catch (e) {
        log.error(e.message);
        process.exit(1);
    }
}

module.exports = { buildPlaylist };
