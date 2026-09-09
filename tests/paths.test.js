'use strict';

// Portage des Describe 'ConvertTo-SafeFolderName' / 'Get-DefaultOutputDir /
// Set-DefaultOutputDir' / 'Set-SockseekCredentials' de
// tests/SockseekLib.Tests.ps1.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { describe, it, before, after, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { safeFolderName, getDefaultOutputDir, setDefaultOutputDir, setSockseekCredentials } = require('../lib/paths');

describe('safeFolderName', () => {
    it('laisse un nom de playlist simple inchange', () => {
        assert.equal(safeFolderName('Sans retour - Phoen V'), 'Sans retour - Phoen V');
    });

    it('retire les caracteres invalides pour un nom de dossier', () => {
        assert.doesNotMatch(safeFolderName('Techno: Vol. 1 / 2 <mix>'), /[:/\\<>]/);
    });

    it("retombe sur 'playlist' pour un nom vide", () => {
        assert.equal(safeFolderName(''), 'playlist');
        assert.equal(safeFolderName(null), 'playlist');
    });
});

describe('getDefaultOutputDir / setDefaultOutputDir', () => {
    // Isole des vraies preferences de l'utilisateur : redirige APPDATA
    // (ou ~/.config sur Unix) vers un dossier jetable le temps du test.
    let prefsTestDir;
    let savedAppData;

    before(() => {
        prefsTestDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sockseek-prefs-'));
        savedAppData = process.env.APPDATA;
        process.env.APPDATA = prefsTestDir;
    });

    after(() => {
        if (savedAppData === undefined) delete process.env.APPDATA; else process.env.APPDATA = savedAppData;
        fs.rmSync(prefsTestDir, { recursive: true, force: true });
    });

    it("renvoie le dossier d'origine du kit quand rien n'est enregistre", () => {
        assert.equal(getDefaultOutputDir(), path.join(os.homedir(), 'Music', 'sockseek'));
    });

    it('persiste un nouveau dossier par defaut', () => {
        setDefaultOutputDir('D:\\Music\\techno');
        assert.equal(getDefaultOutputDir(), 'D:\\Music\\techno');
    });

    it('la valeur persistee survit a un nouvel appel (relit le fichier, pas un cache memoire)', () => {
        setDefaultOutputDir('D:\\Ailleurs');
        assert.equal(getDefaultOutputDir(), 'D:\\Ailleurs');
        assert.equal(getDefaultOutputDir(), 'D:\\Ailleurs');
    });
});

describe('setSockseekCredentials', () => {
    let confTestDir;
    let confTestPath;

    before(() => {
        confTestDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sockseek-conf-'));
        confTestPath = path.join(confTestDir, 'sockseek.conf');
    });

    after(() => { fs.rmSync(confTestDir, { recursive: true, force: true }); });

    afterEach(() => { try { fs.unlinkSync(confTestPath); } catch (e) { /* deja absent */ } });

    it("cree le fichier s'il n'existe pas, avec username/password/output-dir", () => {
        setSockseekCredentials({ username: 'alice', password: 'secret1', outputDir: 'D:\\Music', confPath: confTestPath });
        const content = fs.readFileSync(confTestPath, 'utf8');
        assert.match(content, /username = alice/);
        assert.match(content, /password = secret1/);
        assert.match(content, /output-dir = D:\\Music/);
    });

    it('ne renvoie pas une liste vide -> null (regression sur if/else comme expression)', () => {
        // Le premier appel part d'un fichier inexistant. Si
        // setSockseekCredentials ne cree rien, le fichier reste absent --
        // exactement le symptome du bug corrige dans la version PowerShell.
        setSockseekCredentials({ username: 'x', password: 'y', confPath: confTestPath });
        assert.equal(fs.existsSync(confTestPath), true);
    });

    it('met a jour username/password sans toucher aux autres reglages', () => {
        fs.writeFileSync(confTestPath, [
            '# commentaire utilisateur',
            'username = old',
            'password = oldpass',
            'pref-format = flac',
            'length-tol = 5',
            '',
        ].join('\r\n'), 'utf8');

        setSockseekCredentials({ username: 'bob', password: 'newpass', confPath: confTestPath });

        const lines = fs.readFileSync(confTestPath, 'utf8').split(/\r?\n/);
        assert.ok(lines.includes('# commentaire utilisateur'));
        assert.ok(lines.includes('username = bob'));
        assert.ok(lines.includes('password = newpass'));
        assert.ok(lines.includes('pref-format = flac'));
        assert.ok(lines.includes('length-tol = 5'));
        assert.equal(lines.filter((l) => /^username/.test(l)).length, 1);
    });
});
