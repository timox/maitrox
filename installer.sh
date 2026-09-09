#!/bin/sh
set -e
cd "$(dirname "$0")"

if ! command -v node >/dev/null 2>&1; then
    echo "Node.js est introuvable dans le PATH."
    echo "Installe-le (ex : apt install nodejs, ou https://nodejs.org/) puis relance ce script."
    exit 1
fi

exec node bin/install.js "$@"
