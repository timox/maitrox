'use strict';

// Portage de Write-M3UPlaylist / Show-RunSummary (SockseekLib.ps1).

const fs = require('fs');
const path = require('path');

const COLORS = {
    reset: '\x1b[0m', white: '\x1b[37m', green: '\x1b[32m', yellow: '\x1b[33m',
    red: '\x1b[31m', cyan: '\x1b[36m', gray: '\x1b[90m',
};

function paint(color, text) {
    if (!process.stdout.isTTY) return text;
    return `${COLORS[color] || ''}${text}${COLORS.reset}`;
}

function writeM3UPlaylist({ results, outputDir, playlistPath, relative = true }) {
    const ok = results.filter((r) => r.Reussi);

    const lines = ['#EXTM3U'];
    const stamp = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    const stampStr = `${stamp.getFullYear()}-${pad(stamp.getMonth() + 1)}-${pad(stamp.getDate())} ${pad(stamp.getHours())}:${pad(stamp.getMinutes())}`;
    lines.push(`# Genere le ${stampStr} - ${ok.length} titres`);

    for (const t of ok) {
        const secs = Number(t.Length);
        const dur = t.Length && !Number.isNaN(secs) && secs > 0 ? Math.trunc(secs) : -1;

        const label = t.Artist && t.Title ? `${t.Artist} - ${t.Title}`
            : t.Title ? t.Title
                : path.basename(t.Chemin, path.extname(t.Chemin));

        const p = relative ? path.relative(outputDir, t.Chemin) : t.Chemin;

        lines.push(`#EXTINF:${dur},${label}`);
        lines.push(p);
    }

    // UTF-8 sans BOM : formellement du M3U8, lu sans souci par VLC,
    // foobar2000 et Rekordbox sous l'extension .m3u.
    fs.writeFileSync(playlistPath, lines.join('\n') + '\n', 'utf8');
    return ok.length;
}

function showRunSummary(results, { title = 'RESULTAT', noDetail = false } = {}) {
    const ok = results.filter((r) => r.Reussi);
    const failed = results.filter((r) => !r.Reussi);
    const total = results.length;
    const pct = total ? Math.round((100 * ok.length) / total) : 0;

    console.log('');
    console.log(paint('white', `================ ${title} ================`));
    const pctColor = pct >= 60 ? 'green' : pct >= 30 ? 'yellow' : 'red';
    console.log(paint(pctColor, `  Telecharges : ${ok.length} / ${total}  (${pct} %)`));
    console.log(paint('gray', `  Echecs      : ${failed.length}`));

    if (failed.length) {
        console.log('');
        console.log(paint('yellow', '  Repartition des echecs :'));
        const groups = new Map();
        for (const f of failed) groups.set(f.Statut, (groups.get(f.Statut) || 0) + 1);
        [...groups.entries()].sort((a, b) => b[1] - a[1]).forEach(([name, count]) => {
            console.log(`    ${String(name).padEnd(38)} ${String(count).padStart(3)}`);
        });

        if (!noDetail) {
            console.log('');
            console.log(paint('yellow', '  Titres manquants :'));
            const sorted = [...failed].sort((a, b) =>
                (a.Statut || '').localeCompare(b.Statut || '') || (a.Artist || '').localeCompare(b.Artist || ''));
            for (const f of sorted) {
                console.log(paint('gray', `    ${`${f.Artist} - ${f.Title}`.replace(/^[\s-]+|[\s-]+$/g, '')}`));
            }
        }
    }
}

module.exports = { writeM3UPlaylist, showRunSummary, paint };
