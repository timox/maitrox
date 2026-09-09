# Ancien kit PowerShell (archive)

Ce dossier contient la version d'origine du kit sockseek, ecrite en
PowerShell 7 (`pwsh`). Elle a ete remplacee par un portage Node.js pur --
`lib/`, `bin/` et `webgui/` a la racine du depot -- qui fait exactement la
meme chose sans dependre de PowerShell, y compris sous Linux ou `pwsh`
n'est qu'un runtime .NET rapporte, pas un citoyen natif de la plateforme.

Ces fichiers sont conserves ici pour reference (comportement d'origine,
historique) et ne sont plus maintenus ni invoques par `installer.bat`,
`lancer.bat`, `reprendre.bat` ou la webgui. Pour utiliser le kit, voir le
README a la racine du depot -- tout tourne desormais avec `node` seul.

Si tu veux malgre tout relancer cette version : `pwsh -File Install-Sockseek.ps1`
depuis ce dossier (les chemins relatifs entre scripts restent valides,
tout le groupe a ete deplace ensemble).
