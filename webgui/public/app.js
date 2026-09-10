'use strict';

// ============================================================== utilitaires
async function api(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Erreur HTTP ${res.status}`);
  return data;
}

function el(id) { return document.getElementById(id); }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }

// =================================================================== tabs =
document.querySelectorAll('nav button').forEach((btn) => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('nav button').forEach((b) => b.classList.remove('active'));
    document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
    btn.classList.add('active');
    el(`tab-${btn.dataset.tab}`).classList.add('active');
  });
});

function switchTab(name) {
  document.querySelectorAll('nav button').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
  document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.id === `tab-${name}`));
}

// ============================================================ suivi/jobs ==
let jobBusy = false;

function setBusy(busy) {
  jobBusy = busy;
  el('btn-stop-job').disabled = !busy;
  ['new-launch', 'btn-install', 'btn-check-updates', 'btn-import',
   'btn-refresh-playlists', 'btn-resume-all', 'btn-test-selected',
   'btn-resume-selected', 'btn-delete-selected'].forEach((id) => { el(id).disabled = busy; });
}

// Pastille d'etat visible depuis n'importe quel onglet (pas seulement
// "Suivi d'execution") : un job lance depuis "Nouvelle playlist" ne doit
// pas donner l'impression que plus rien ne se passe des qu'on change
// d'onglet.
function setGlobalStatus(state, text) {
  const pill = el('global-status');
  pill.dataset.state = state;
  el('global-status-text').textContent = text;
}

// Les scripts de bin/ prefixent leurs erreurs de "[ERREUR] " (voir
// bin/extract.js, bin/resume.js, etc.) : detecte ce marqueur pour mettre
// la ligne en evidence dans le journal, et pour remonter le vrai message
// -- pas seulement un code de sortie -- dans le statut et la pastille.
const ERROR_PREFIX = /^\[erreur\]\s?/i;
let lastErrorText = '';

function appendLog(line) {
  const box = el('log');
  const isError = ERROR_PREFIX.test(line);
  if (isError) lastErrorText = line.replace(ERROR_PREFIX, '');
  const row = document.createElement('div');
  row.className = isError ? 'log-line log-error' : 'log-line';
  row.textContent = line;
  box.appendChild(row);
  box.scrollTop = box.scrollHeight;
}

function clearLog() {
  el('log').textContent = '';
  lastErrorText = '';
}

async function startJob(kind, extra, description) {
  if (jobBusy) { alert("Une operation est deja en cours. Attends qu'elle se termine."); return; }
  switchTab('suivi');
  clearLog();
  el('suivi-status').textContent = `En cours : ${description}`;
  setGlobalStatus('busy', description);
  setBusy(true);
  try {
    await api('POST', '/api/jobs/start', { kind, ...extra });
  }
  catch (e) {
    setBusy(false);
    el('suivi-status').textContent = `Echec du demarrage : ${e.message}`;
    setGlobalStatus('error', 'Echec du demarrage');
  }
}

function connectStream() {
  const src = new EventSource('/api/jobs/stream');
  src.addEventListener('start', (ev) => {
    // Une operation demarree depuis un autre onglet/navigateur : refleter
    // l'etat ici aussi plutot que de laisser croire que rien ne tourne.
    const d = JSON.parse(ev.data);
    clearLog();
    el('suivi-status').textContent = `En cours : ${d.description}`;
    setGlobalStatus('busy', d.description);
    setBusy(true);
  });
  src.addEventListener('log', (ev) => appendLog(JSON.parse(ev.data).line));
  src.addEventListener('done', (ev) => {
    const d = JSON.parse(ev.data);
    if (d.code === 0) {
      el('suivi-status').textContent = `Termine sans echec : ${d.description}`;
      setGlobalStatus('ok', 'Termine');
    }
    else {
      const reason = lastErrorText || d.error || `code ${d.code}`;
      el('suivi-status').textContent = `Echec (${d.description}) : ${reason}`;
      setGlobalStatus('error', reason);
    }
    setBusy(false);
    refreshPlaylists();
  });
}

el('btn-stop-job').addEventListener('click', async () => {
  if (!confirm("Arreter l'operation en cours ? Les telechargements deja entames seront interrompus.")) return;
  el('suivi-status').textContent = 'Arret en cours...';
  await api('POST', '/api/jobs/stop');
});

// ===================================================== Nouvelle playlist ==
el('new-launch').addEventListener('click', () => {
  const url = el('new-url').value.trim();
  if (!url) { alert('URL de playlist requise.'); return; }
  const mode = document.querySelector('input[name=mode]:checked').value;
  const cookies = el('new-cookies').value || undefined;
  startJob('extract', { url, mode, cookiesFromBrowser: cookies }, 'extraction de la playlist');
});

// ========================================================= Configuration ==
async function refreshBinStatus(checkUpdates) {
  const s = await api('GET', '/api/status');
  const line = (label, info) => info.found
    ? `${label} : trouve, version ${info.version || '?'} (${info.path})`
    : `${label} : introuvable`;
  let text = `${line('sockseek', s.sockseek)}\n${line('yt-dlp', s.ytdlp)}`;
  el('bin-status').textContent = text;
  el('conf-dest').value = s.defaultOutputDir || '';

  if (checkUpdates) {
    el('bin-status').textContent += '\nVerification des mises a jour...';
    const u = await api('GET', '/api/updates');
    const fmt = (key, label) => {
      const r = u[key];
      if (!r || !r.available) return '';
      if (r.error) return ` -- ${label} : ${r.error}`;
      return r.upToDate ? ` -- ${label} : a jour` : ` -- ${label} : mise a jour disponible (${r.latest})`;
    };
    el('bin-status').textContent = `${line('sockseek', s.sockseek)}${fmt('sockseek', 'sockseek')}\n${line('yt-dlp', s.ytdlp)}${fmt('ytdlp', 'yt-dlp')}`;
  }
}

el('btn-install').addEventListener('click', () => startJob('install', {}, 'installation / mise a jour de sockseek et yt-dlp'));
el('btn-check-updates').addEventListener('click', () => refreshBinStatus(true));

async function refreshConfigStatus() {
  const c = await api('GET', '/api/config');
  const box = el('conf-status');
  if (!c.hasConf) {
    box.textContent = 'Configuration actuelle : aucune (sockseek.conf absent)';
  }
  else if (c.username) {
    box.textContent = `Configuration actuelle : identifiants enregistres pour '${c.username}'`;
    if (!el('conf-user').value) el('conf-user').value = c.username;
  }
  else {
    box.textContent = 'Configuration actuelle : sockseek.conf existe, mais aucun pseudo lisible';
  }
}

el('btn-save-creds').addEventListener('click', async () => {
  const username = el('conf-user').value.trim();
  const password = el('conf-pass').value;
  if (!username || !password) { alert('Pseudo et mot de passe requis.'); return; }
  try {
    await api('POST', '/api/config/credentials', { username, password });
    el('conf-pass').value = '';
    await refreshConfigStatus();
    alert('Identifiants enregistres dans sockseek.conf.');
  }
  catch (e) { alert(`Echec : ${e.message}`); }
});

el('btn-save-dest').addEventListener('click', async () => {
  const p = el('conf-dest').value.trim();
  if (!p) return;
  try { await api('POST', '/api/config/default-dir', { path: p }); alert('Dossier par defaut enregistre.'); }
  catch (e) { alert(`Echec : ${e.message}`); }
});

el('btn-open-dest').addEventListener('click', async () => {
  const p = el('conf-dest').value.trim();
  if (!p) return;
  await api('POST', '/api/open-folder', { path: p });
});

el('btn-import').addEventListener('click', async () => {
  const p = el('import-path').value.trim();
  if (!p) { alert('Dossier requis.'); return; }
  const name = el('import-name').value.trim() || undefined;
  try {
    const r = await api('POST', '/api/config/import', { path: p, name });
    await refreshPlaylists();
    alert(`Playlist '${r.Name}' importee : ${r.Ok} recuperes, ${r.Manquants} manquants sur ${r.Total} au total.\n\nDeplacee vers : ${r.OutputDir}`);
  }
  catch (e) { alert(`Echec de l'import : ${e.message}`); }
});

// -------------------------------------------------------- directory picker
let modalTarget = null;
async function openBrowser(startPath, targetInputId) {
  modalTarget = targetInputId;
  el('modal-backdrop').hidden = false;
  await loadBrowserPath(startPath || el(targetInputId).value || undefined);
}
async function loadBrowserPath(p) {
  const q = p ? `?path=${encodeURIComponent(p)}` : '';
  const r = await api('GET', `/api/browse${q}`);
  el('modal-path').textContent = r.path;
  el('modal-path').dataset.path = r.path;
  el('modal-path').dataset.parent = r.parent;
  const list = el('modal-list');
  list.innerHTML = '';
  r.dirs.forEach((name) => {
    const div = document.createElement('div');
    div.textContent = name;
    div.addEventListener('click', () => loadBrowserPath(r.path.replace(/[/\\]$/, '') + (r.path.includes('\\') ? '\\' : '/') + name));
    list.appendChild(div);
  });
}
el('modal-up').addEventListener('click', () => loadBrowserPath(el('modal-path').dataset.parent));
el('modal-cancel').addEventListener('click', () => { el('modal-backdrop').hidden = true; });
el('modal-choose').addEventListener('click', () => {
  if (modalTarget) el(modalTarget).value = el('modal-path').dataset.path;
  el('modal-backdrop').hidden = true;
});
el('btn-browse-dest').addEventListener('click', () => openBrowser(undefined, 'conf-dest'));
el('btn-browse-import').addEventListener('click', () => openBrowser(undefined, 'import-path'));

// ============================================================= Playlists ==
let playlistRows = [];
let selectedUrl = null;

async function refreshPlaylists() {
  const rows = await api('GET', '/api/playlists');
  playlistRows = Array.isArray(rows) ? rows : [];
  renderPlaylists();
}

function renderPlaylists() {
  const filter = el('pl-search').value.trim().toLowerCase();
  const shown = filter ? playlistRows.filter((r) => (r.Name || '').toLowerCase().includes(filter)) : playlistRows;
  el('pl-info').textContent = filter ? `${shown.length} / ${playlistRows.length} playlist(s) (filtre actif)` : `${playlistRows.length} playlist(s)`;

  const tbody = document.querySelector('#pl-table tbody');
  tbody.innerHTML = '';
  shown.forEach((r) => {
    const tr = document.createElement('tr');
    tr.className = r.Url === selectedUrl ? 'selected' : '';
    const missing = Number(r.Manquants) || 0;
    tr.innerHTML = `<td>${esc(r.Error ? r.Name + ' (erreur de lecture)' : r.Name)}</td>
      <td><span class="metric ${missing > 0 ? 'metric-warn' : 'metric-ok'}">${esc(r.Manquants)}</span></td>
      <td><span class="metric metric-neutral">${esc(r.Recuperes)}</span></td>
      <td class="num">${esc(r.Runs)}</td>
      <td>${esc(r.LastRun ? new Date(r.LastRun).toLocaleString() : '')}</td><td class="path">${esc(r.OutputDir)}</td>`;
    tr.addEventListener('click', () => { selectedUrl = r.Url; renderPlaylists(); loadDetail(r.Url); });
    tbody.appendChild(tr);
  });
}

function getSelectedRow() {
  const row = playlistRows.find((r) => r.Url === selectedUrl);
  if (!row) alert('Aucune playlist selectionnee dans la liste.');
  return row;
}

let detailFolder = null;
let detailLog = null;

async function loadDetail(url) {
  el('btn-open-log').disabled = true;
  el('btn-open-folder').disabled = true;
  detailFolder = null; detailLog = null;
  document.querySelector('#pl-detail-table thead tr').innerHTML = '';
  document.querySelector('#pl-detail-table tbody').innerHTML = '';

  const row = playlistRows.find((r) => r.Url === url);
  el('pl-detail-title').textContent = row ? `Playlist : ${row.Name} -- ${row.OutputDir}` : '';

  try {
    const d = await api('GET', `/api/playlists/detail?url=${encodeURIComponent(url)}`);
    detailFolder = d.outputDir;
    el('btn-open-folder').disabled = !detailFolder;
    if (d.logPath) { detailLog = d.logPath; el('btn-open-log').disabled = false; }
    if (d.rows && d.rows.length) {
      const cols = Object.keys(d.rows[0]);
      document.querySelector('#pl-detail-table thead tr').innerHTML = cols.map((c) => `<th>${esc(c)}</th>`).join('');
      document.querySelector('#pl-detail-table tbody').innerHTML = d.rows.map((r) =>
        `<tr>${cols.map((c) => `<td>${esc(r[c])}</td>`).join('')}</tr>`).join('');
    }
  }
  catch (e) { /* pas de detail disponible, ce n'est pas bloquant */ }
}

el('pl-search').addEventListener('input', renderPlaylists);
el('btn-refresh-playlists').addEventListener('click', refreshPlaylists);
el('btn-resume-all').addEventListener('click', () => startJob('resume-all', {}, 'reprise de toutes les playlists'));

el('btn-test-selected').addEventListener('click', () => {
  const row = getSelectedRow();
  if (!row) return;
  startJob('test-one', { name: row.Name }, `test de la playlist '${row.Name}'`);
});

el('btn-resume-selected').addEventListener('click', () => {
  const row = getSelectedRow();
  if (!row) return;
  startJob('resume-one', { name: row.Name }, `reprise de la playlist '${row.Name}'`);
});

el('btn-delete-selected').addEventListener('click', async () => {
  const row = getSelectedRow();
  if (!row) return;
  const del = confirm(
    `Supprimer aussi les fichiers telecharges sur le disque ?\n${row.OutputDir}\n\n` +
    "OK : supprime le dossier complet (irreversible).\nAnnuler : retire seulement l'entree du catalogue.");
  try {
    await api('POST', '/api/playlists/delete', { url: row.Url, deleteFiles: del });
    selectedUrl = null;
    await refreshPlaylists();
  }
  catch (e) { alert(`Echec de la suppression : ${e.message}`); }
});

el('btn-open-log').addEventListener('click', async () => {
  if (detailLog) await api('POST', '/api/open-folder', { path: detailLog });
});
el('btn-open-folder').addEventListener('click', async () => {
  if (detailFolder) await api('POST', '/api/open-folder', { path: detailFolder });
});

// =================================================================== init =
(async function init() {
  connectStream();
  try {
    const status = await api('GET', '/api/jobs/status');
    if (status.active) {
      setBusy(true);
      el('suivi-status').textContent = `En cours : ${status.description}`;
      setGlobalStatus('busy', status.description);
      switchTab('suivi');
    }
    if (status.lines) status.lines.forEach(appendLog);
  }
  catch (e) { /* pas grave au demarrage */ }

  refreshBinStatus(false);
  refreshConfigStatus();
  refreshPlaylists();
})();
