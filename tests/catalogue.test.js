'use strict';

// Portage des Describe 'Import-PlaylistFolder' / 'Remove-CatalogueEntry' de
// tests/SockseekLib.Tests.ps1.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { setDefaultOutputDir } = require('../lib/paths');
const { importPlaylistFolder, readCatalogue, removeCatalogueEntry } = require('../lib/catalogue');

describe('importPlaylistFolder', () => {
    // Rend gerable un dossier de telechargement jamais enregistre dans le
    // catalogue (deplace a la main, telecharge avant l'introduction du
    // catalogue centralise, etc.) sans jamais relancer d'extraction -- et
    // le deplace vers le dossier de destination par defaut pour
    // recentraliser des telechargements eparpilles.
    let catTestDir, sourcesDir, centralDir, savedAppData;

    before(() => {
        catTestDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sockseek-import-'));
        sourcesDir = path.join(catTestDir, 'sources');
        centralDir = path.join(catTestDir, 'centralized');
        fs.mkdirSync(sourcesDir, { recursive: true });
        savedAppData = process.env.APPDATA;
        process.env.APPDATA = catTestDir;
        setDefaultOutputDir(centralDir);
    });

    after(() => {
        if (savedAppData === undefined) delete process.env.APPDATA; else process.env.APPDATA = savedAppData;
        fs.rmSync(catTestDir, { recursive: true, force: true });
    });

    it("leve une erreur si le dossier n'existe pas", () => {
        assert.throws(() => importPlaylistFolder({ folderPath: path.join(sourcesDir, 'inexistant') }));
    });

    it("leve une erreur si le dossier ne contient ni index ni fichier audio, sans rien deplacer", () => {
        const empty = path.join(sourcesDir, 'vide');
        fs.mkdirSync(empty, { recursive: true });
        assert.throws(() => importPlaylistFolder({ folderPath: empty }));
        assert.equal(fs.existsSync(empty), true);
        assert.equal(fs.existsSync(path.join(centralDir, 'vide')), false);
    });

    it('enregistre un dossier avec _index.csv dans le catalogue, avec le bon compte, et le deplace vers la destination par defaut', () => {
        const folder = path.join(sourcesDir, 'Ma Playlist');
        fs.mkdirSync(folder, { recursive: true });
        fs.writeFileSync(path.join(folder, 'Artist - Ok.mp3'), '');
        fs.writeFileSync(path.join(folder, '_index.csv'),
            'filepath,artist,album,title,length,tracktype,state,failurereason\n' +
            'Artist - Ok.mp3,Artist,,Ok,300,0,1,0\n' +
            ',Artist,,Manquant,300,0,2,9\n');

        const imported = importPlaylistFolder({ folderPath: folder });
        assert.equal(imported.Total, 2);
        assert.equal(imported.Ok, 1);
        assert.equal(imported.Manquants, 1);
        assert.equal(imported.Name, 'Ma Playlist');
        assert.equal(imported.OutputDir, fs.realpathSync(path.join(centralDir, 'Ma Playlist')));

        assert.equal(fs.existsSync(folder), false);
        assert.equal(fs.existsSync(path.join(centralDir, 'Ma Playlist', 'Artist - Ok.mp3')), true);

        const entry = readCatalogue().find((e) => e.Name === 'Ma Playlist');
        assert.ok(entry);
        assert.equal(entry.Total, 2);
        assert.equal(entry.Ok, 1);
    });

    it("reimporter depuis le nouvel emplacement (deja centralise) met a jour l'entree sans la dupliquer", () => {
        const already = path.join(centralDir, 'Ma Playlist');
        const before2 = readCatalogue().length;
        importPlaylistFolder({ folderPath: already });
        assert.equal(readCatalogue().length, before2);
        assert.equal(fs.existsSync(already), true);
    });

    it('detecte aussi un dossier sans index mais avec des fichiers audio (balayage du disque)', () => {
        const folder = path.join(sourcesDir, 'Sans Index');
        fs.mkdirSync(folder, { recursive: true });
        fs.writeFileSync(path.join(folder, 'Un Titre.flac'), '');

        const imported = importPlaylistFolder({ folderPath: folder });
        assert.equal(imported.Total, 1);
        assert.equal(imported.Ok, 1);
        assert.equal(fs.existsSync(path.join(centralDir, 'Sans Index', 'Un Titre.flac')), true);
    });

    it('utilise le nom fourni plutot que le nom du dossier pour le nommer ET pour le dossier de destination', () => {
        const folder = path.join(sourcesDir, 'Nom Original');
        fs.mkdirSync(folder, { recursive: true });
        fs.writeFileSync(path.join(folder, 'Un Titre.flac'), '');

        const imported = importPlaylistFolder({ folderPath: folder, name: 'Nom choisi' });
        assert.equal(imported.Name, 'Nom choisi');
        assert.equal(fs.existsSync(path.join(centralDir, 'Nom choisi', 'Un Titre.flac')), true);
    });

    it('fusionne sans ecraser quand un dossier du meme nom existe deja a destination', () => {
        const preexisting = path.join(centralDir, 'Fusion Test');
        fs.mkdirSync(preexisting, { recursive: true });
        fs.writeFileSync(path.join(preexisting, 'A.mp3'), 'central-version');
        fs.writeFileSync(path.join(preexisting, 'B.flac'), 'central-version');

        const incoming = path.join(sourcesDir, 'Fusion Test');
        fs.mkdirSync(incoming, { recursive: true });
        fs.writeFileSync(path.join(incoming, 'A.mp3'), 'incoming-conflicting-version');
        fs.writeFileSync(path.join(incoming, 'C.flac'), 'incoming-new-file');

        importPlaylistFolder({ folderPath: incoming, name: 'Fusion Test' });

        // Le fichier deja present a destination n'est jamais ecrase.
        assert.match(fs.readFileSync(path.join(preexisting, 'A.mp3'), 'utf8'), /central-version/);
        // Le fichier nouveau est bien remonte a destination.
        assert.equal(fs.existsSync(path.join(preexisting, 'C.flac')), true);
        // Le fichier en conflit reste a l'emplacement source, non perdu.
        assert.equal(fs.existsSync(path.join(incoming, 'A.mp3')), true);
        assert.match(fs.readFileSync(path.join(incoming, 'A.mp3'), 'utf8'), /incoming-conflicting-version/);
        // Le fichier deplace, lui, ne reste pas en double a la source.
        assert.equal(fs.existsSync(path.join(incoming, 'C.flac')), false);
    });
});

describe('removeCatalogueEntry', () => {
    let remTestDir, savedAppData;

    function newFakePlaylistFolder(name) {
        const folder = path.join(remTestDir, `src-${name}`);
        fs.mkdirSync(folder, { recursive: true });
        fs.writeFileSync(path.join(folder, 'Titre.flac'), '');
        return importPlaylistFolder({ folderPath: folder, name });
    }

    before(() => {
        remTestDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sockseek-remove-'));
        savedAppData = process.env.APPDATA;
        process.env.APPDATA = remTestDir;
        setDefaultOutputDir(path.join(remTestDir, 'central'));
    });

    after(() => {
        if (savedAppData === undefined) delete process.env.APPDATA; else process.env.APPDATA = savedAppData;
        fs.rmSync(remTestDir, { recursive: true, force: true });
    });

    it('leve une erreur pour une URL absente du catalogue', () => {
        assert.throws(() => removeCatalogueEntry('local-import://inconnue'));
    });

    it('retire uniquement l\'entree du catalogue sans toucher aux fichiers par defaut', () => {
        newFakePlaylistFolder('Garder les fichiers');
        const entry = readCatalogue().find((e) => e.Name === 'Garder les fichiers');
        const outputDir = entry.OutputDir;

        removeCatalogueEntry(entry.Url);

        assert.equal(readCatalogue().find((e) => e.Name === 'Garder les fichiers'), undefined);
        assert.equal(fs.existsSync(outputDir), true);
    });

    it('retire aussi les fichiers du disque avec deleteFiles', () => {
        newFakePlaylistFolder('Supprimer aussi');
        const entry = readCatalogue().find((e) => e.Name === 'Supprimer aussi');
        const outputDir = entry.OutputDir;

        removeCatalogueEntry(entry.Url, { deleteFiles: true });

        assert.equal(readCatalogue().find((e) => e.Name === 'Supprimer aussi'), undefined);
        assert.equal(fs.existsSync(outputDir), false);
    });
});
