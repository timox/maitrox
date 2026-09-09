'use strict';

// Portage du Describe 'Get-RunResults' de tests/SockseekLib.Tests.ps1.
//
// sockseek 3.x ecrit "state" et "failurereason" dans _index.csv comme des
// codes numeriques d'enum, pas du texte. Ces tests figent ce format pour
// eviter que la classification retombe silencieusement sur "Non
// telecharge" pour tout.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { getRunResults } = require('../lib/runResults');

describe('getRunResults', () => {
    let testDir;

    before(() => { testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sockseek-test-')); });
    after(() => { fs.rmSync(testDir, { recursive: true, force: true }); });

    function writeIndex(name, content) {
        const p = path.join(testDir, name);
        fs.writeFileSync(p, content, 'utf8');
        return p;
    }

    it('categorise NoSearchResults (9) comme Introuvable sur Soulseek', () => {
        const idx = writeIndex('idx1.csv', 'filepath,artist,album,title,length,tracktype,state,failurereason\n,K-H1,,Krasnota,340,0,2,9\n');
        const results = getRunResults({ indexPath: idx, outputDir: testDir });
        assert.equal(results[0].Statut, 'Introuvable sur Soulseek');
        assert.equal(results[0].Detail, 'NoSearchResults');
        assert.equal(results[0].Reussi, false);
    });

    it('categorise NoMatchingResults (10) comme Filtre par les conditions', () => {
        const idx = writeIndex('idx2.csv', 'filepath,artist,album,title,length,tracktype,state,failurereason\n,Artist,,Title,300,0,2,10\n');
        assert.equal(getRunResults({ indexPath: idx, outputDir: testDir })[0].Statut, 'Filtre par les conditions');
    });

    it('categorise Cancelled (7) comme Annule', () => {
        const idx = writeIndex('idx3.csv', 'filepath,artist,album,title,length,tracktype,state,failurereason\n,Artist,,Title,300,0,2,7\n');
        assert.equal(getRunResults({ indexPath: idx, outputDir: testDir })[0].Statut, 'Annule');
    });

    it('un fichier present sur le disque est reussi meme sans filepath renseigne au bon format', () => {
        const sub = path.join(testDir, 'sub');
        fs.mkdirSync(sub, { recursive: true });
        fs.writeFileSync(path.join(sub, 'Artist - Title.mp3'), '');

        const idx = writeIndex('idx4.csv', 'filepath,artist,album,title,length,tracktype,state,failurereason\nsub/Artist - Title.mp3,Artist,,Title,300,0,1,0\n');
        const result = getRunResults({ indexPath: idx, outputDir: testDir });
        assert.equal(result[0].Statut, 'Telecharge');
        assert.equal(result[0].Reussi, true);
    });

    it("la verite vient du disque : un index optimiste sans fichier reel est un echec", () => {
        const idx = writeIndex('idx5.csv', 'filepath,artist,album,title,length,tracktype,state,failurereason\nmanquant/Artist - Title.mp3,Artist,,Title,300,0,1,0\n');
        const result = getRunResults({ indexPath: idx, outputDir: testDir });
        assert.equal(result[0].Reussi, false);
        assert.equal(result[0].Statut, 'Fichier absent du disque');
    });

    it("un titre absent de l'index mais telecharge directement (SoundCloud libre) est detecte sur le disque", () => {
        const direct = path.join(testDir, 'direct');
        fs.mkdirSync(direct, { recursive: true });
        fs.writeFileSync(path.join(direct, 'DirectArtist - DirectTitle.mp3'), '');

        const src = path.join(direct, 'source.csv');
        fs.writeFileSync(src, 'Artist,Title,Length,Review\nDirectArtist,DirectTitle,200,\n');

        // Pas d'index du tout (ou vide) : sockseek n'a jamais vu ce titre.
        const result = getRunResults({ outputDir: direct, sourceCsv: src });
        assert.equal(result.length, 1);
        assert.equal(result[0].Statut, 'Telecharge directement (SoundCloud)');
        assert.equal(result[0].Reussi, true);
    });

    it("un titre absent de l'index et absent du disque reste 'jamais traite'", () => {
        const direct2 = path.join(testDir, 'direct2');
        fs.mkdirSync(direct2, { recursive: true });

        const src = path.join(direct2, 'source.csv');
        fs.writeFileSync(src, 'Artist,Title,Length,Review\nPersonne,Rien,200,\n');

        const result = getRunResults({ outputDir: direct2, sourceCsv: src });
        assert.equal(result[0].Statut, 'Jamais traite');
        assert.equal(result[0].Reussi, false);
    });
});
