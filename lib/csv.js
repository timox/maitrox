'use strict';

// Lecture/ecriture CSV minimale (RFC 4180 : champs entre guillemets si
// necessaire, guillemet double pour echapper un guillemet). Remplace
// Import-Csv / Export-Csv de PowerShell -- pas de dependance npm, comme le
// reste du kit.

function parseCsv(text) {
    if (text == null) return [];
    // Retire un BOM eventuel et normalise les fins de ligne.
    const clean = text.replace(/^﻿/, '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    if (clean.trim() === '') return [];

    const rows = [];
    let row = [];
    let field = '';
    let inQuotes = false;
    let i = 0;
    const n = clean.length;

    function endField() { row.push(field); field = ''; }
    function endRow() { endField(); rows.push(row); row = []; }

    while (i < n) {
        const c = clean[i];
        if (inQuotes) {
            if (c === '"') {
                if (clean[i + 1] === '"') { field += '"'; i += 2; continue; }
                inQuotes = false; i++; continue;
            }
            field += c; i++; continue;
        }
        if (c === '"') { inQuotes = true; i++; continue; }
        if (c === ',') { endField(); i++; continue; }
        if (c === '\n') { endRow(); i++; continue; }
        field += c; i++;
    }
    // Derniere ligne sans retour final.
    if (field !== '' || row.length > 0) endRow();

    if (rows.length === 0) return [];
    const header = rows[0];
    return rows.slice(1)
        .filter((r) => !(r.length === 1 && r[0] === ''))
        .map((r) => {
            const obj = {};
            header.forEach((h, idx) => { obj[h] = r[idx] === undefined ? '' : r[idx]; });
            return obj;
        });
}

function csvValue(v) {
    const s = v == null ? '' : String(v);
    if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
}

function writeCsv(rows, columns) {
    const cols = columns || (rows.length ? Object.keys(rows[0]) : []);
    const lines = [cols.map(csvValue).join(',')];
    for (const row of rows) {
        lines.push(cols.map((c) => csvValue(row[c])).join(','));
    }
    return lines.join('\r\n') + '\r\n';
}

module.exports = { parseCsv, writeCsv };
