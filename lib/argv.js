'use strict';

// Analyse d'arguments minimale, dans le style des parametres PowerShell du
// kit d'origine (-Url x -Download -PrintOnly) : pas de dependance npm.
function parseArgs(argv, switchNames = []) {
    const out = {};
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith('-')) {
            const name = a.replace(/^-+/, '');
            if (switchNames.includes(name)) {
                out[name] = true;
            }
            else {
                out[name] = argv[i + 1];
                i++;
            }
        }
    }
    return out;
}

module.exports = { parseArgs };
