#!/bin/sh
set -e
cd "$(dirname "$0")"

if ! command -v node >/dev/null 2>&1; then
    echo "Node.js est introuvable dans le PATH."
    echo "Installe-le (ex : apt install nodejs, ou https://nodejs.org/) puis relance ce script."
    exit 1
fi

(
    sleep 1
    if command -v xdg-open >/dev/null 2>&1; then xdg-open http://localhost:8342 >/dev/null 2>&1
    elif command -v open >/dev/null 2>&1; then open http://localhost:8342 >/dev/null 2>&1
    fi
) &

node webgui/server.js
