'use strict';

// Nettoyage des titres : portage de la section NETTOYAGE DES TITRES de
// SockseekLib.ps1 (PowerShell). Transforme les exports bruts
// SoundCloud/YouTube en entrees Artist/Title exploitables par sockseek.
// Teste dans tests/text.test.js.

// ---------------------------------------------------------------- regexes ---
// Prefixes de premiere : "PREMIERE:", "BCCO Premiere:", "PW PREMIERE |",
// "Bunkers Premiere /", "SYN Premiere:", "PREMIERE - "
const rePremiere = /^\s*(?:[\w.&+\-']{1,20}\s+)?premiere\s*(?::|\||\/|\s[-–—])\s*/i;
// Fragment de crochet/parenthese tronque : "[ORE...", "(Volster..."
const reTruncated = /\s*[[(][^\])]*\.\.\.\s*$/;
// Bloc entre crochets en fin de titre : codes catalogue, mentions diverses
const reBrackets = /\s*\[[^\]]*\]\s*$/;
// Mentions de telechargement libre, ou qu'elles soient
const reFreeDl = /\+?\s*[[(]?\s*(?:free\s*d(?:own)?l(?:oad)?|bandcamp)[^\])]*[\])]?\s*\+?/gi;
const rePipeTail = /\s*\|\s*(?:free\s*dl|bandcamp)\s*$/i;
// (Original Mix) : n'aide jamais une recherche Soulseek
const reOrigMix = /\s*\(\s*original\s*mix\s*\)/gi;
// Catalogue entre parentheses : (TAR034)
const reParenCat = /\s*\(\s*[A-Z]{2,}[\s.-]?\d{2,}\s*\)/g;
// Position vinyle en tete : "A2 Deluka - ..."
const reVinylPos = /^[A-D][1-9]\s+/;
// ", by Artiste" en suffixe (style Bandcamp / HPX)
const reBySuffix = /,\s*by\s+.+$/i;
// Separateur artiste / titre
const reSplit = /\s+[-–—]\s+/;
// Ce qui n'est pas un morceau
const reJunk = /template|demo\s*song/i;

function normalizeText(text) {
    if (text == null || String(text).trim() === '') return '';
    // NFKC : ramene les polices fantaisie unicode a de l'ASCII lisible
    let t = String(text).normalize('NFKC');
    t = t.replace(/，/g, ',').replace(/　/g, ' ');
    return t.replace(/\s+/g, ' ').trim();
}

function cleanTitle(text) {
    const original = text == null ? '' : String(text);
    const truncated = original.trimEnd().endsWith('...');

    let t = original.replace(reTruncated, '');
    t = t.replace(rePremiere, '');
    t = t.replace(rePipeTail, '');
    t = t.replace(reFreeDl, ' ');

    // plusieurs blocs [..] peuvent s'enchainer en fin de titre
    let prev;
    do {
        prev = t;
        t = t.replace(reBrackets, '');
    } while (prev !== t);

    t = t.replace(reParenCat, '');
    t = t.replace(reOrigMix, '');
    t = t.replace(reVinylPos, '');
    t = t.replace(reBySuffix, '');
    t = t.replace(/\s+\)/g, ')').replace(/\s+/g, ' ');

    return { text: t.trim().replace(/^[\s\-–—|+]+|[\s\-–—|+]+$/g, ''), truncated };
}

function convertEntry(entry) {
    const metaArtist = normalizeText(entry.artist);
    const uploader = normalizeText(entry.uploader);
    const metaTrack = normalizeText(entry.track);
    const rawTitle = normalizeText(entry.title);

    const isJunk = reJunk.test(rawTitle);

    const cleaned = cleanTitle(rawTitle);
    let title = cleaned.text;
    const truncated = cleaned.truncated;

    const notes = [];
    let artist;
    let track;

    if (metaArtist && metaTrack) {
        // Metadonnees reelles renseignees : elles font autorite.
        artist = metaArtist;
        track = cleanTitle(metaTrack).text;
        notes.push('metadonnees');
    }
    else {
        // "ANNE- Gentle Loop" : tiret colle apres le nom d'artiste
        const ref = metaArtist || uploader;
        if (ref && title.toLowerCase().startsWith(ref.toLowerCase() + '-')) {
            title = title.substring(0, ref.length) + ' - ' + title.substring(ref.length + 1);
        }

        const parts = title.split(reSplit);
        if (parts.length >= 2) {
            artist = parts[0].trim();
            track = parts.slice(1).map((p) => p.trim()).join(' - ');
        }
        else if (metaArtist) {
            artist = metaArtist;
            track = title;
        }
        else {
            // Rien d'autre sous la main que le nom de chaine : peu fiable.
            artist = uploader;
            track = title;
            notes.push('artiste=chaine');
        }
    }

    if (truncated) notes.push('TRONQUE');
    if (isJunk) notes.push('PAS_UN_MORCEAU');
    if (artist && uploader && artist !== uploader && !metaArtist) {
        notes.push('artiste extrait du titre');
    }

    const length = entry.duration ? Math.floor(Number(entry.duration)) : '';

    return {
        Artist: artist,
        Title: track,
        Length: length,
        SourceChannel: uploader,
        Url: entry.webpage_url,
        Review: notes.join('; '),
    };
}

module.exports = { normalizeText, cleanTitle, convertEntry };
