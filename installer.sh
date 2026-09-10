#!/bin/sh
# Script unique : met a jour le code du kit, installe/met a jour les
# binaires (sockseek, yt-dlp) et la configuration, puis demarre
# l'interface web -- un seul script pour tout installer et deployer,
# du premier lancement aux suivants. Pas besoin d'autre script ni de
# commande git/node a taper a la main.
cd "$(dirname "$0")"

if ! command -v node >/dev/null 2>&1; then
    echo "Node.js est introuvable dans le PATH."
    echo "Installe-le (ex : apt install nodejs, ou https://nodejs.org/) puis relance ce script."
    exit 1
fi

# ------------------------------------------------- mise a jour du code -----
# Sans effet si le dossier n'est pas un clone git (kit recupere autrement
# qu'avec git) ou sans reseau : avertit et continue plutot que de bloquer
# la suite pour autant.
if [ -d .git ] && command -v git >/dev/null 2>&1; then
    echo "================================================================"
    echo " Mise a jour du kit"
    echo "================================================================"
    BEFORE=$(git rev-parse HEAD 2>/dev/null || echo '')
    if git pull --ff-only; then
        AFTER=$(git rev-parse HEAD 2>/dev/null || echo '')
        if [ "$BEFORE" != "$AFTER" ]; then
            echo ""
            echo "Kit mis a jour."
        else
            echo ""
            echo "Deja a jour."
        fi
    else
        echo ""
        echo "Mise a jour du kit impossible (pas de reseau, ou modifications"
        echo "locales en conflit) : on continue avec le code deja present."
    fi
    echo ""
fi

# --------------------------------------------- binaires + configuration ----
# Meilleur effort : une panne ici (quota GitHub, pas de reseau) ne doit pas
# empecher de demarrer l'interface web -- elle affiche le meme diagnostic
# et permet de reessayer l'installation depuis l'onglet Configuration.
node bin/install.js "$@"

# --------------------------------------------------- interface web ---------
echo ""
echo "================================================================"
echo " Demarrage de l'interface web"
echo "================================================================"
echo ""

(
    sleep 1
    if command -v xdg-open >/dev/null 2>&1; then xdg-open http://localhost:8342 >/dev/null 2>&1
    elif command -v open >/dev/null 2>&1; then open http://localhost:8342 >/dev/null 2>&1
    fi
) &

exec node webgui/server.js
