'use strict';

// Portage de la section ANALYSE de SockseekLib.ps1 : confronte l'index
// sockseek au contenu reel du disque. La verite vient du disque : un
// fichier absent est un echec meme si l'index le declare telecharge.

const fs = require('fs');
const path = require('path');
const { parseCsv } = require('./csv');
const { safeFolderName } = require('./paths');

// Sockseek 3.x ecrit "state" et "failurereason" comme des codes numeriques
// d'enum interne (Sockseek.Core.Common.Enums.JobStateOld / JobFailureReason),
// pas du texte : verifie empiriquement sur sockseek 3.0.5 (--print index-failed
// donne "NoSearchResults" pendant que _index.csv, lui, ecrit "9"). Les valeurs
// viennent du code source du projet, pas d'une doc publique susceptible de
// changer sans prevenir : a revisiter si une future release change les codes.
const FAILURE_REASON_NAMES = {
    0: 'None', 1: 'InvalidSearchString', 2: 'OutOfDownloadRetries',
    4: 'AllDownloadsFailed', 5: 'Other', 6: 'ExtractionFailed',
    7: 'Cancelled', 8: 'ChildJobsFailed', 9: 'NoSearchResults',
    10: 'NoMatchingResults',
};
const FAILURE_REASON_CATEGORIES = {
    2: 'Probleme reseau ou pair injoignable',
    4: 'Probleme reseau ou pair injoignable',
    5: 'Echec (cause non precisee)',
    6: 'Echec (cause non precisee)',
    7: 'Annule',
    8: 'Echec (cause non precisee)',
    9: 'Introuvable sur Soulseek',
    10: 'Filtre par les conditions',
};
const STATE_NAMES = {
    0: 'Pending', 1: 'Done', 2: 'Failed', 3: 'AlreadyExists', 4: 'NotFoundLastTime',
};
const STATE_CATEGORIES = {
    4: 'Introuvable sur Soulseek', // NotFoundLastTime : ignore par --skip-not-found
};

const AUDIO_EXTENSIONS = new Set(['.mp3', '.flac', '.ogg', '.m4a', '.opus', '.wav', '.aac', '.alac']);

function findIndexColumn(row, candidates) {
    if (!row) return null;
    const names = Object.keys(row);
    for (const c of candidates) {
        const hit = names.find((n) => n.replace(/[\s_-]/g, '').toLowerCase() === c);
        if (hit) return hit;
    }
    return null;
}

function walkFiles(dir) {
    const out = [];
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
    catch (e) { return out; }
    for (const e of entries) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...walkFiles(full));
        else if (e.isFile()) out.push(full);
    }
    return out;
}

function findFileByPrefix(dir, prefix) {
    let entries;
    try { entries = fs.readdirSync(dir); }
    catch (e) { return null; }
    const lower = prefix.toLowerCase() + '.';
    const hit = entries.find((n) => n.toLowerCase().startsWith(lower));
    return hit ? path.join(dir, hit) : null;
}

function getRunResults({ indexPath, outputDir, sourceCsv } = {}) {
    const results = [];

    let index = [];
    if (indexPath && fs.existsSync(indexPath)) {
        index = parseCsv(fs.readFileSync(indexPath, 'utf8'));
    }

    const first = index[0] || null;
    const colPath = findIndexColumn(first, ['filepath', 'path', 'localpath']);
    const colArtist = findIndexColumn(first, ['artist', 'sartist', 'albumartist']);
    const colTitle = findIndexColumn(first, ['title', 'stitle']);
    const colAlbum = findIndexColumn(first, ['album', 'salbum']);
    const colLength = findIndexColumn(first, ['length', 'slength', 'duration']);
    const colState = findIndexColumn(first, ['state', 'status']);
    const colReason = findIndexColumn(first, ['failurereason', 'reason', 'error']);

    const val = (row, col) => (col ? row[col] : null);

    for (const row of index) {
        const rawPath = val(row, colPath);
        let full = null;
        if (rawPath && String(rawPath).trim() !== '') {
            full = path.isAbsolute(rawPath) ? rawPath : path.join(outputDir, rawPath);
        }
        const exists = !!(full && fs.existsSync(full) && fs.statSync(full).isFile());

        const state = val(row, colState);
        const reason = val(row, colReason);

        // sockseek 3.x : $state/$reason sont des codes numeriques d'enum (cf. plus haut).
        // reasonCode 0 (None) n'est pas exploitable : on retombe sur l'etat.
        const reasonCode = reason != null && /^-?\d+$/.test(String(reason)) ? parseInt(reason, 10) : null;
        const stateCode = state != null && /^-?\d+$/.test(String(state)) ? parseInt(state, 10) : null;

        const reasonCategory = reasonCode && FAILURE_REASON_CATEGORIES[reasonCode] ? FAILURE_REASON_CATEGORIES[reasonCode] : null;
        const stateCategory = stateCode != null && STATE_CATEGORIES[stateCode] ? STATE_CATEGORIES[stateCode] : null;

        let category;
        if (exists) category = 'Telecharge';
        else if (reasonCategory) category = reasonCategory;
        else if (stateCategory) category = stateCategory;
        // Repli pour un index au format texte (versions anterieures a sockseek 3.x).
        else if (reason && /not.?found|no.?result|introuv/i.test(reason)) category = 'Introuvable sur Soulseek';
        else if (reason && /nosuitable|no.?suitable|condition|filter|quality|bitrate|format/i.test(reason)) category = 'Filtre par les conditions';
        else if (reason && /timeout|stale|connect|refus|offline/i.test(reason)) category = 'Probleme reseau ou pair injoignable';
        else if (reason && /cancel|abort/i.test(reason)) category = 'Annule';
        else if (state && /not.?found/i.test(state)) category = 'Introuvable sur Soulseek';
        else if (state && /fail|error/i.test(state)) category = 'Echec (cause non precisee)';
        else if (rawPath) category = 'Fichier absent du disque';
        else category = 'Non telecharge';

        // Detail lisible : nom de l'enum plutot que le code numerique brut.
        const reasonDetail = reasonCode != null && FAILURE_REASON_NAMES[reasonCode] ? FAILURE_REASON_NAMES[reasonCode] : reason;
        const stateDetail = stateCode != null && STATE_NAMES[stateCode] ? STATE_NAMES[stateCode] : state;

        results.push({
            Artist: val(row, colArtist),
            Title: val(row, colTitle),
            Album: val(row, colAlbum),
            Length: val(row, colLength),
            Statut: category,
            Detail: reasonDetail && reasonDetail !== 'None' ? reasonDetail : stateDetail,
            Chemin: exists ? full : '',
            Reussi: !!exists,
        });
    }

    // Titres presents dans la source mais absents de l'index : jamais confies
    // a sockseek. Peut malgre tout etre deja sur le disque -- notamment un
    // titre recupere directement via yt-dlp (telechargement libre SoundCloud)
    // plutot que cherche sur Soulseek : la verite vient du disque, pas
    // seulement de l'index, meme ici.
    if (sourceCsv && fs.existsSync(sourceCsv)) {
        const seen = new Set();
        for (const r of results) seen.add(`${r.Artist}|${r.Title}`.toLowerCase().trim());
        const srcRows = parseCsv(fs.readFileSync(sourceCsv, 'utf8'));
        for (const src of srcRows) {
            const k = `${src.Artist}|${src.Title}`.toLowerCase().trim();
            if (seen.has(k)) continue;
            const safe = safeFolderName(`${src.Artist} - ${src.Title}`);
            const directFile = findFileByPrefix(outputDir, safe);
            if (directFile) {
                results.push({
                    Artist: src.Artist, Title: src.Title, Album: '',
                    Length: src.Length,
                    Statut: 'Telecharge directement (SoundCloud)',
                    Detail: "Telechargement libre propose par l'artiste",
                    Chemin: directFile, Reussi: true,
                });
            }
            else {
                results.push({
                    Artist: src.Artist, Title: src.Title, Album: '',
                    Length: src.Length,
                    Statut: 'Jamais traite',
                    Detail: "Absent de l'index : run interrompu ou entree ignoree",
                    Chemin: '', Reussi: false,
                });
            }
        }
    }

    // Repli : sans index, on balaye les fichiers audio presents.
    if (results.length === 0 && fs.existsSync(outputDir)) {
        for (const full of walkFiles(outputDir)) {
            if (AUDIO_EXTENSIONS.has(path.extname(full).toLowerCase())) {
                results.push({
                    Artist: '', Title: path.basename(full, path.extname(full)), Album: '', Length: '',
                    Statut: 'Telecharge', Detail: 'Detecte par balayage du dossier',
                    Chemin: full, Reussi: true,
                });
            }
        }
    }

    return results;
}

module.exports = { getRunResults, FAILURE_REASON_NAMES, STATE_NAMES };
