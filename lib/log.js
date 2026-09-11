'use strict';

// Niveaux de journalisation uniformes pour tous les scripts de bin/ :
// prefixe reconnu et mis en forme cote navigateur (webgui/public/app.js)
// -- contrairement aux couleurs ANSI de lib/playlist.js:paint(), qui ne
// donnent rien une fois le flux capture par la webgui (pipe, pas un TTY).
// Complementaire, pas un remplacement : utiliser les deux au besoin.
//
//   [DEBUG]  detail technique, visible seulement avec SOCKSEEK_DEBUG=1
//   [INFO]   deroulement normal (par defaut, pas de prefixe : c'est le
//            gros du journal, un prefixe sur chaque ligne serait du bruit)
//   [AVERT]  a signaler, mais n'empeche pas la suite
//   [ERREUR] fait echouer l'operation en cours

function debug(msg) {
    if (process.env.SOCKSEEK_DEBUG) console.log(`[DEBUG] ${msg}`);
}

function warn(msg) {
    console.warn(`[AVERT] ${msg}`);
}

function warnBlock(lines) {
    // Bloc d'avertissement multi-lignes : seule la premiere ligne porte le
    // prefixe [AVERT] (celle qui resume), le detail suit en clair --
    // prefixer chaque ligne les ferait toutes ressortir identiquement en
    // rouge, noyant le resume dans le detail au lieu de le distinguer.
    console.warn(`[AVERT] ${lines[0]}`);
    if (lines.length > 1) console.log(lines.slice(1).join('\n'));
}

function error(msg) {
    console.error(`[ERREUR] ${msg}`);
}

module.exports = { debug, warn, warnBlock, error };
