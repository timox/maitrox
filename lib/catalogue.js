'use strict';

// Portage de la section CATALOGUE de SockseekLib.ps1 : recense les
// playlists deja amorcees, pour pouvoir reprendre plus tard ce qui n'est
// pas passe.

const fs = require('fs');
const path = require('path');
const { getCataloguePath, getDefaultOutputDir, safeFolderName } = require('./paths');
const { getRunResults } = require('./runResults');

function readCatalogue() {
    const p = getCataloguePath();
    if (!fs.existsSync(p)) return [];
    try {
        const raw = fs.readFileSync(p, 'utf8');
        if (raw.trim() === '') return [];
        const parsed = JSON.parse(raw);
        return Array.isArray(parsed) ? parsed : [parsed];
    }
    catch (e) {
        console.warn(`Catalogue illisible (${p}) : ${e.message}`);
        return [];
    }
}

function saveCatalogue(entries) {
    const p = getCataloguePath();
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify(entries, null, 2), 'utf8');
}

function nowStamp() {
    const d = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function tryResolve(p) {
    try { return fs.realpathSync(p); } catch (e) { return p; }
}

function registerPlaylist({ url, outputDir, sourceCsv, indexPath, name, total = 0, ok, hasOk = false }) {
    const entries = readCatalogue();
    const now = nowStamp();
    const existing = entries.find((e) => e.Url === url);

    if (existing) {
        existing.OutputDir = outputDir;
        existing.SourceCsv = tryResolve(sourceCsv);
        existing.IndexPath = indexPath;
        existing.LastRun = now;
        existing.RunCount = Number(existing.RunCount || 0) + 1;
        if (total) existing.Total = total;
        if (hasOk) existing.Ok = ok;
        if (name) existing.Name = name;
    }
    else {
        entries.push({
            Url: url,
            Name: name || (url.split('/').filter(Boolean).pop() || url),
            OutputDir: outputDir,
            SourceCsv: tryResolve(sourceCsv),
            IndexPath: indexPath,
            FirstRun: now,
            LastRun: now,
            RunCount: 1,
            Total: total,
            Ok: hasOk ? ok : 0,
        });
    }

    saveCatalogue(entries);
}

function isDirEmpty(dir) {
    try { return fs.readdirSync(dir).length === 0; } catch (e) { return false; }
}

function moveEntry(src, dest) {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    try {
        fs.renameSync(src, dest);
    }
    catch (e) {
        if (e.code !== 'EXDEV') throw e;
        // Deplacement inter-disques : rename echoue, on copie puis supprime.
        fs.copyFileSync(src, dest);
        fs.unlinkSync(src);
    }
}

function movePlaylistToDefaultLocation(sourceDir, name) {
    // Deplace un dossier de playlist vers le dossier de destination par
    // defaut, pour recentraliser des telechargements eparpilles a
    // differents emplacements au fil du temps.
    //
    // Si un dossier du meme nom existe deja a destination (playlist deja
    // partiellement centralisee la-bas), fusionne fichier par fichier sans
    // jamais ecraser un fichier existant : en cas de conflit, le fichier
    // source est laisse en place plutot que perdu.
    const destRoot = getDefaultOutputDir();
    fs.mkdirSync(destRoot, { recursive: true });

    const sourceFull = fs.realpathSync(sourceDir);
    const targetDir = path.join(destRoot, safeFolderName(name));

    if (fs.existsSync(targetDir) && fs.realpathSync(targetDir) === sourceFull) {
        // Deja au bon endroit (reimport d'une playlist deja centralisee).
        return sourceFull;
    }

    if (!fs.existsSync(targetDir)) {
        moveEntry(sourceFull, targetDir);
        return fs.realpathSync(targetDir);
    }

    const skipped = [];
    const walk = (dir) => {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, entry.name);
            if (entry.isDirectory()) { walk(full); continue; }
            const rel = path.relative(sourceFull, full);
            const destPath = path.join(targetDir, rel);
            if (fs.existsSync(destPath)) { skipped.push(rel); continue; }
            fs.mkdirSync(path.dirname(destPath), { recursive: true });
            moveEntry(full, destPath);
        }
    };
    walk(sourceFull);

    // Retire les dossiers source devenus vides ; laisse en place ceux qui
    // contiennent encore des fichiers en conflit, non deplaces.
    const removeEmptyDirs = (dir) => {
        let entries;
        try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
        for (const entry of entries) {
            if (entry.isDirectory()) removeEmptyDirs(path.join(dir, entry.name));
        }
        if (isDirEmpty(dir) && dir !== sourceFull) fs.rmdirSync(dir);
    };
    removeEmptyDirs(sourceFull);
    if (fs.existsSync(sourceFull) && isDirEmpty(sourceFull)) fs.rmdirSync(sourceFull);

    if (skipped.length > 0) {
        console.warn(`Fusion partielle vers '${targetDir}' : ${skipped.length} fichier(s) ` +
            `deja present(s) a destination, laisse(s) dans '${sourceFull}' : ${skipped.join(', ')}`);
    }

    return fs.realpathSync(targetDir);
}

function findFilesRecursive(dir, filename) {
    const out = [];
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return out; }
    for (const entry of entries) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) out.push(...findFilesRecursive(full, filename));
        else if (entry.name === filename) out.push(full);
    }
    return out;
}

function newestByMtime(files) {
    if (!files.length) return null;
    return files
        .map((f) => ({ f, mtime: fs.statSync(f).mtimeMs }))
        .sort((a, b) => b.mtime - a.mtime)[0].f;
}

function importPlaylistFolder({ folderPath, name } = {}) {
    // Rend gerable, depuis l'onglet Playlists, un dossier de telechargement
    // existant jamais enregistre dans le catalogue centralise -- deplace a
    // la main, telecharge avant l'introduction de ce catalogue, ou produit
    // sur une autre machine. Aucune extraction n'est relancee : on relit
    // juste ce qui est deja sur le disque.
    if (!fs.existsSync(folderPath) || !fs.statSync(folderPath).isDirectory()) {
        throw new Error(`Dossier introuvable : ${folderPath}`);
    }
    const resolvedIn = fs.realpathSync(folderPath);
    const finalName = name || path.basename(resolvedIn);

    // Valide AVANT de deplacer quoi que ce soit : un dossier qui n'est pas
    // une vraie playlist sockseek (ni index ni audio) ne doit pas laisser un
    // dossier vide residuel a la destination si l'import echoue ensuite.
    const probeIndex = newestByMtime(findFilesRecursive(resolvedIn, '_index.csv'));
    if (getRunResults({ indexPath: probeIndex, outputDir: resolvedIn }).length === 0) {
        throw new Error(`Aucun index sockseek (_index.csv) ni fichier audio trouve dans ce dossier : ${resolvedIn}`);
    }

    const resolved = movePlaylistToDefaultLocation(resolvedIn, finalName);

    const indexPath = newestByMtime(findFilesRecursive(resolved, '_index.csv'));

    // playlist-clean.csv est le nom par defaut de bin/extract.js, mais
    // n'importe quel CSV avec des colonnes Artist/Title fait l'affaire pour
    // detecter les titres jamais tentes -- utile si le fichier a ete
    // renomme ou copie a la main dans le dossier importe.
    const csvCandidates = fs.readdirSync(resolved, { withFileTypes: true })
        .filter((e) => e.isFile() && e.name.toLowerCase().endsWith('.csv'))
        .filter((e) => !['_index.csv', 'rapport.csv'].includes(e.name))
        .map((e) => path.join(resolved, e.name));
    const sourceCsv = newestByMtime(csvCandidates) || path.join(resolved, 'playlist-clean.csv');

    const results = getRunResults({ indexPath, outputDir: resolved, sourceCsv });
    const total = results.length;
    const ok = results.filter((r) => r.Reussi).length;

    const url = `local-import://${safeFolderName(finalName)}`;
    registerPlaylist({ url, outputDir: resolved, sourceCsv, indexPath, name: finalName, total, ok, hasOk: true });

    return {
        Name: finalName,
        OutputDir: resolved,
        IndexPath: indexPath,
        SourceCsv: sourceCsv,
        Total: total,
        Ok: ok,
        Manquants: total - ok,
    };
}

function removeCatalogueEntry(url, { deleteFiles = false } = {}) {
    const entries = readCatalogue();
    const entry = entries.find((e) => e.Url === url);
    if (!entry) throw new Error(`Playlist introuvable dans le catalogue (URL : ${url})`);

    if (deleteFiles && entry.OutputDir && fs.existsSync(entry.OutputDir)) {
        fs.rmSync(entry.OutputDir, { recursive: true, force: true });
    }

    saveCatalogue(entries.filter((e) => e.Url !== url));
    return entry;
}

function getPlaylistPending(entry) {
    if (!fs.existsSync(entry.OutputDir)) return [];

    let idx = entry.IndexPath;
    if (!(idx && fs.existsSync(idx))) idx = path.join(entry.OutputDir, '_index.csv');

    let src = entry.SourceCsv;
    if (!(src && fs.existsSync(src))) src = null;

    const res = getRunResults({ indexPath: idx, outputDir: entry.OutputDir, sourceCsv: src });
    return res.filter((r) => !r.Reussi);
}

module.exports = {
    readCatalogue,
    saveCatalogue,
    registerPlaylist,
    movePlaylistToDefaultLocation,
    importPlaylistFolder,
    removeCatalogueEntry,
    getPlaylistPending,
};
