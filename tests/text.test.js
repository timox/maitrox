'use strict';

// Portage des Describe 'Clean-Title' / 'Normalize-Text' / 'Convert-Entry'
// de l'ancien tests/SockseekLib.Tests.ps1 (Pester) vers node:test.
//
//   node --test tests/

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { normalizeText, cleanTitle, convertEntry } = require('../lib/text');

function newEntry({ artist = '', uploader = '', track = '', title, duration = 240, url = 'https://example.invalid/track' }) {
    return { artist, uploader, track, title, duration, webpage_url: url };
}

describe('cleanTitle', () => {
    it('retire un prefixe de premiere avec deux-points', () => {
        assert.equal(cleanTitle('BCCO Premiere: Mislaw - Fourth Siren [THEIA001]').text, 'Mislaw - Fourth Siren');
    });

    it('retire un prefixe de premiere avec barre verticale', () => {
        assert.equal(cleanTitle('PW PREMIERE | Artist - Track').text, 'Artist - Track');
    });

    it('retire un prefixe de premiere avec tiret', () => {
        assert.equal(cleanTitle('PREMIERE - Artist - Track').text, 'Artist - Track');
    });

    it('retire (Original Mix)', () => {
        assert.equal(cleanTitle('Artist - Track (Original Mix)').text, 'Artist - Track');
    });

    it('conserve les noms de remix', () => {
        assert.equal(cleanTitle('Artist - Track (Kr!z Remix)').text, 'Artist - Track (Kr!z Remix)');
    });

    it('retire les codes catalogue entre crochets en fin de titre', () => {
        assert.equal(cleanTitle('Artist - Track [TAR034]').text, 'Artist - Track');
    });

    it('retire plusieurs blocs entre crochets enchaines', () => {
        assert.equal(cleanTitle('Artist - Track [FREE DL] [TAR034]').text, 'Artist - Track');
    });

    it('retire un code catalogue entre parentheses', () => {
        assert.equal(cleanTitle('Artist - Track (TAR034)').text, 'Artist - Track');
    });

    it('retire une position vinyle en tete', () => {
        assert.equal(cleanTitle('A2 Deluka - Track').text, 'Deluka - Track');
    });

    it('retire un suffixe ", by Artiste"', () => {
        assert.equal(cleanTitle('Track Name, by Someone').text, 'Track Name');
    });

    it('retire une mention de telechargement libre', () => {
        assert.equal(cleanTitle('Artist - Track (Free Download)').text, 'Artist - Track');
    });

    it('detecte un titre tronque et retire le fragment', () => {
        const result = cleanTitle('Artist - Track [ORE...');
        assert.equal(result.truncated, true);
        assert.equal(result.text, 'Artist - Track');
    });

    it('ne marque pas tronque un titre complet', () => {
        assert.equal(cleanTitle('Artist - Track').truncated, false);
    });
});

describe('normalizeText', () => {
    it('reduit les espaces multiples et trim', () => {
        assert.equal(normalizeText('  Artist   -   Track  '), 'Artist - Track');
    });

    it('renvoie une chaine vide pour une entree vide ou nulle', () => {
        assert.equal(normalizeText(''), '');
        assert.equal(normalizeText(null), '');
    });
});

describe('convertEntry', () => {
    it('utilise les metadonnees quand artist et track sont renseignes', () => {
        const entry = newEntry({ artist: 'Mislaw', uploader: 'BCCO', track: 'Fourth Siren', title: 'BCCO Premiere: Mislaw - Fourth Siren [THEIA001]' });
        const result = convertEntry(entry);
        assert.equal(result.Artist, 'Mislaw');
        assert.equal(result.Title, 'Fourth Siren');
        assert.match(result.Review, /metadonnees/);
    });

    it('extrait artiste et titre depuis le titre nettoye sans metadonnees', () => {
        const entry = newEntry({ uploader: 'SomeLabel', title: 'Artist - Track (Original Mix)' });
        const result = convertEntry(entry);
        assert.equal(result.Artist, 'Artist');
        assert.equal(result.Title, 'Track');
    });

    it("gere le tiret colle apres le nom d'artiste", () => {
        const entry = newEntry({ artist: 'ANNE', uploader: 'ANNE', title: 'ANNE- Gentle Loop' });
        const result = convertEntry(entry);
        assert.equal(result.Artist, 'ANNE');
        assert.equal(result.Title, 'Gentle Loop');
    });

    it("retombe sur le nom de la chaine quand aucun artiste n'est identifiable", () => {
        const entry = newEntry({ uploader: 'RandomChannel', title: 'Untitled Track' });
        const result = convertEntry(entry);
        assert.equal(result.Artist, 'RandomChannel');
        assert.match(result.Review, /artiste=chaine/);
    });

    it('signale un titre tronque', () => {
        const entry = newEntry({ uploader: 'Label', title: 'Artist - Track [ORE...' });
        assert.match(convertEntry(entry).Review, /TRONQUE/);
    });

    it("signale ce qui n'est pas un morceau", () => {
        const entry = newEntry({ uploader: 'Label', title: 'Ableton Demo Song' });
        assert.match(convertEntry(entry).Review, /PAS_UN_MORCEAU/);
    });

    it('convertit la duree en secondes entieres', () => {
        const entry = newEntry({ artist: 'A', uploader: 'U', track: 'T', title: 'A - T', duration: 245.7 });
        assert.equal(convertEntry(entry).Length, 245);
    });
});
