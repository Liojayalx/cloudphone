// Panel de administración de Cloud Phone (cliente web local). Habla con la API de administración (127.0.0.1).
const $ = (s) => document.querySelector(s);
const INSTANCE = 'phone1';

// ---- token: llega en el fragmento de la URL (no se envía al servidor) y se guarda en localStorage ----
const m = location.hash.match(/t=([0-9a-f]+)/);
if (m) { localStorage.setItem('cp_admin', m[1]); history.replaceState(null, '', location.pathname); }
let TOKEN = localStorage.getItem('cp_admin') || '';
if (!TOKEN) { TOKEN = (prompt('Token de administración (archivo data\\admin.token):') || '').trim(); localStorage.setItem('cp_admin', TOKEN); }

async function api(path, opts = {}) {
  const r = await fetch(path, { ...opts, headers: { 'X-Admin-Token': TOKEN, ...(opts.json ? { 'Content-Type': 'application/json' } : {}), ...opts.headers }, body: opts.json ? JSON.stringify(opts.json) : opts.body });
  const text = await r.text(); let data; try { data = JSON.parse(text); } catch { data = text; }
  if (!r.ok) { const e = new Error((data && (data.errors ? data.errors.join('\n') : data.error)) || r.statusText); e.status = r.status; throw e; }
  return data;
}
const post = (p, json) => api(p, { method: 'POST', json: json || {} });
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ---------------- estado de la instancia ----------------
let inst = null;
const STATE_TXT = { stopped: 'Apagado', starting: 'Iniciando…', running: 'En marcha', stopping: 'Apagando…', error: 'Error' };
async function refresh() {
  try {
    const st = await api('/admin/status');
    $('#serverInfo').textContent = `Servidor v${st.version} · escuchando en ${st.listen}`;
    inst = st.instances.find((i) => i.id === INSTANCE) || st.instances[0];
    $('#instName').textContent = inst.name;
    const b = $('#bState'); b.textContent = STATE_TXT[inst.state] || inst.state;
    b.className = 'badge ' + ({ running: 'ok', error: 'bad', starting: 'warn', stopping: 'warn' }[inst.state] || '');
    const r = $('#bRoot');
    if (inst.state !== 'running') { r.textContent = 'root: —'; r.className = 'badge'; }
    else { r.textContent = inst.root.active ? 'root: activo' : 'root: no'; r.className = 'badge ' + (inst.root.active ? 'ok' : 'bad'); }
    $('#bUp').textContent = inst.uptimeSeconds != null ? `activo ${fmtUp(inst.uptimeSeconds)}` : '—';
    $('#busyMsg').textContent = inst.busy ? `Operación en curso: ${inst.busy}…` : (inst.error ? `Error: ${inst.error}` : '');
    const run = inst.state === 'running', idle = !inst.busy;
    $('#btnStart').disabled = run || !idle; $('#btnStop').disabled = inst.state === 'stopped' || !idle; $('#btnRestart').disabled = !run || !idle;
    $('#btnLive').disabled = !run && !live.ws;
  } catch (e) { $('#serverInfo').innerHTML = `<span class="err">Sin conexión con el servidor: ${esc(e.message)}</span>`; }
}
const fmtUp = (s) => (s >= 3600 ? `${Math.floor(s / 3600)} h ` : '') + `${Math.floor(s / 60) % 60} min`;

async function loadInfo() {
  if (!inst || inst.state !== 'running') { $('#infoTable').innerHTML = '<tr><td colspan=2 class="muted">El Android no está en marcha</td></tr>'; return; }
  try {
    const i = await api(`/api/instances/${INSTANCE}/info`);
    const rows = [['Android', `${i.androidVersion} (API ${i.sdk})`], ['Modelo', i.model], ['Compilación', `${i.buildType} · ${i.abi}`], ['Root', i.root.active ? `sí — ${i.root.id}` : 'no'],
      ['Pantalla', `${i.display.size} @ ${i.display.density} dpi`], ['Memoria', `${i.memoryTotalMB} MB`], ['Almacenamiento', i.storage ? `${i.storage.usedMB} / ${i.storage.totalMB} MB` : '—']];
    $('#infoTable').innerHTML = rows.map(([k, v]) => `<tr><td>${k}</td><td>${esc(v)}</td></tr>`).join('');
  } catch (e) { $('#infoTable').innerHTML = `<tr><td colspan=2 class="err">${esc(e.message)}</td></tr>`; }
}

async function act(path, label) {
  try { $('#busyMsg').textContent = label; await post(path); } catch (e) { $('#busyMsg').innerHTML = `<span class="err">${esc(e.message)}</span>`; }
  await refresh(); loadInfo();
}
$('#btnStart').onclick = () => { act(`/api/instances/${INSTANCE}/start`, 'Iniciando Android (≈1 min)…'); setTimeout(refresh, 800); };
$('#btnStop').onclick = () => { if (confirm('¿Apagar el Android?')) act(`/api/instances/${INSTANCE}/stop`, 'Apagando…'); };
$('#btnRestart').onclick = () => { act(`/api/instances/${INSTANCE}/restart`, 'Reiniciando (≈1-2 min)…'); setTimeout(refresh, 800); };
$('#btnPortrait').onclick = () => post(`/api/instances/${INSTANCE}/orientation`, { orientation: 'portrait' }).catch((e) => alert(e.message));
$('#btnLandscape').onclick = () => post(`/api/instances/${INSTANCE}/orientation`, { orientation: 'landscape' }).catch((e) => alert(e.message));
$('#btnRes').onclick = () => post(`/api/instances/${INSTANCE}/resolution`, { width: +$('#resW').value, height: +$('#resH').value, ...($('#resD').value ? { dpi: +$('#resD').value } : {}) }).then(loadInfo).catch((e) => alert(e.message));
$('#btnResReset').onclick = () => post(`/api/instances/${INSTANCE}/resolution`, { reset: true }).then(loadInfo).catch((e) => alert(e.message));

$('#btnSrvRestart').onclick = async () => {
  if (!confirm('¿Reiniciar el servidor? Se apagará el Android y se cortarán las conexiones.')) return;
  await post('/admin/shutdown', { restart: true }).catch(() => {});
  $('#serverInfo').textContent = 'Reiniciando servidor…'; setTimeout(() => location.reload(), 6000);
};
$('#btnSrvStop').onclick = async () => {
  if (!confirm('¿Apagar el servidor? Se apagará el Android. Para volver a usarlo, abre «Cloud Phone» desde el escritorio.')) return;
  await post('/admin/shutdown', { restart: false }).catch(() => {});
  $('#serverInfo').textContent = 'Servidor apagado';
};

// ---------------- pestañas ----------------
document.querySelectorAll('.tab').forEach((t) => t.onclick = () => {
  document.querySelectorAll('.tab').forEach((x) => x.classList.toggle('active', x === t));
  document.querySelectorAll('.pane').forEach((p) => p.classList.toggle('hidden', p.id !== 'tab-' + t.dataset.tab));
  ({ apps: loadApps, cfg: loadCfg, sec: loadSec, logs: loadLogs })[t.dataset.tab]();
});

// ---------------- APK y apps ----------------
async function loadApps() {
  const tb = $('#appsTable');
  if (!inst || inst.state !== 'running') { tb.innerHTML = '<tr><td class="muted">El Android no está en marcha</td></tr>'; return; }
  try {
    const { apps } = await api(`/api/instances/${INSTANCE}/apps`);
    tb.innerHTML = apps.map((a) => `<tr><td>${esc(a)}</td><td style="text-align:right"><button data-launch="${esc(a)}">Abrir</button> <button class="danger" data-un="${esc(a)}">Desinstalar</button></td></tr>`).join('') || '<tr><td class="muted">Ninguna</td></tr>';
    tb.querySelectorAll('[data-launch]').forEach((b) => b.onclick = () => post(`/api/instances/${INSTANCE}/launch`, { package: b.dataset.launch }).catch((e) => alert(e.message)));
    tb.querySelectorAll('[data-un]').forEach((b) => b.onclick = async () => { if (confirm(`¿Desinstalar ${b.dataset.un}?`)) { try { await api(`/api/instances/${INSTANCE}/apps/${encodeURIComponent(b.dataset.un)}`, { method: 'DELETE' }); } catch (e) { alert(e.message); } loadApps(); } });
  } catch (e) { tb.innerHTML = `<tr><td class="err">${esc(e.message)}</td></tr>`; }
}
$('#btnApps').onclick = loadApps;
$('#btnApk').onclick = async () => {
  const f = $('#apkFile').files[0]; if (!f) return ($('#apkMsg').textContent = 'Elige un archivo .apk');
  $('#apkMsg').textContent = `Subiendo ${f.name} (${(f.size / 1048576).toFixed(1)} MB)…`;
  try { await api(`/api/instances/${INSTANCE}/apk?name=${encodeURIComponent(f.name)}`, { method: 'POST', body: f, headers: { 'Content-Type': 'application/octet-stream' } }); $('#apkMsg').innerHTML = '<span class="okc">Instalado</span>'; loadApps(); }
  catch (e) { $('#apkMsg').innerHTML = `<span class="err">${esc(e.message)}</span>`; }
};

// ---------------- configuración ----------------
async function loadCfg() { try { $('#cfgText').value = JSON.stringify(await api('/admin/config'), null, 2); $('#cfgMsg').textContent = ''; } catch (e) { $('#cfgMsg').innerHTML = `<span class="err">${esc(e.message)}</span>`; } }
$('#btnCfgLoad').onclick = loadCfg;
$('#btnCfgSave').onclick = async () => {
  let obj; try { obj = JSON.parse($('#cfgText').value); } catch (e) { return ($('#cfgMsg').innerHTML = `<span class="err">JSON inválido: ${esc(e.message)}</span>`); }
  try { const r = await api('/admin/config', { method: 'PUT', json: obj }); $('#cfgMsg').innerHTML = `<span class="okc">Guardado.</span> ${esc(r.note)}`; }
  catch (e) { $('#cfgMsg').innerHTML = `<span class="err">${esc(e.message).replace(/\n/g, '<br>')}</span>`; }
};

// ---------------- dispositivos / conexiones ----------------
async function loadSec() {
  try {
    $('#pairCode').textContent = (await api('/admin/pairing')).code;
    const devs = await api('/admin/devices');
    $('#devTable').innerHTML = '<tr><th>Nombre</th><th>IP</th><th>Último uso</th><th></th></tr>' + (devs.map((d) => `<tr><td>${esc(d.name)}</td><td>${esc(d.lastIp || '')}</td><td>${esc(d.lastSeen ? new Date(d.lastSeen).toLocaleString() : 'nunca')}</td><td><button class="danger" data-rev="${d.id}">Revocar</button></td></tr>`).join('') || '<tr><td colspan=4 class="muted">Ningún dispositivo emparejado</td></tr>');
    $('#devTable').querySelectorAll('[data-rev]').forEach((b) => b.onclick = async () => { if (confirm('¿Revocar este dispositivo?')) { await api('/admin/devices/' + b.dataset.rev, { method: 'DELETE' }); loadSec(); } });
    const cs = await api('/admin/connections');
    $('#connTable').innerHTML = '<tr><th>Dispositivo</th><th>IP</th><th>Desde</th><th>Enviado</th></tr>' + (cs.map((c) => `<tr><td>${esc(c.device)}</td><td>${esc(c.ip)}</td><td>${esc(new Date(c.since).toLocaleTimeString())}</td><td>${(c.sentBytes / 1048576).toFixed(1)} MB</td></tr>`).join('') || '<tr><td colspan=4 class="muted">Ninguna</td></tr>');
  } catch (e) { $('#devTable').innerHTML = `<tr><td class="err">${esc(e.message)}</td></tr>`; }
}
$('#btnPair').onclick = async () => { $('#pairCode').textContent = (await post('/admin/pairing')).code; };

// ---------------- logs ----------------
async function loadLogs() { try { const l = await api('/admin/logs?n=300'); const box = $('#logBox'); box.textContent = l.map((e) => `${e.t.slice(11, 19)} ${e.level.toUpperCase().padEnd(5)} [${e.module}] ${e.msg}`).join('\n'); box.scrollTop = box.scrollHeight; } catch (e) { $('#logBox').textContent = e.message; } }

// =========================== pantalla en vivo (WebCodecs) ===========================
const live = { ws: null, decoder: null, cfg: null, needKey: true, frames: 0, t0: 0, w: 0, h: 0, rtt: null, pingTimer: null, statTimer: null };
const canvas = $('#screen'), ctx2d = canvas.getContext('2d');
const setOverlay = (t) => { const o = $('#overlay'); o.textContent = t || ''; o.classList.toggle('hidden', !t); };

function codecString(sps) { const h = (n) => n.toString(16).padStart(2, '0'); return `avc1.${h(sps[1])}${h(sps[2])}${h(sps[3])}`; }
function findSps(buf) { // busca NAL tipo 7 en Annex B
  for (let i = 0; i + 4 < buf.length; i++) if (buf[i] === 0 && buf[i + 1] === 0 && (buf[i + 2] === 1 || (buf[i + 2] === 0 && buf[i + 3] === 1))) { const s = buf[i + 2] === 1 ? i + 3 : i + 4; if ((buf[s] & 0x1f) === 7) return buf.subarray(s, s + 4); }
  return null;
}
function resetDecoder(codec) {
  try { live.decoder?.close(); } catch { /* */ }
  live.decoder = new VideoDecoder({
    output: (f) => { if (canvas.width !== f.displayWidth || canvas.height !== f.displayHeight) { canvas.width = f.displayWidth; canvas.height = f.displayHeight; } ctx2d.drawImage(f, 0, 0); f.close(); live.frames++; },
    error: (e) => { console.warn('decoder', e); live.needKey = true; setOverlay('Error de decodificación, esperando fotograma clave…'); if (live.ws?.readyState === 1) resetDecoder(live.codec); },
  });
  live.decoder.configure({ codec, optimizeForLatency: true });
  live.codec = codec; live.needKey = true;
}

function onBinary(buf) {
  const v = new DataView(buf), u8 = new Uint8Array(buf);
  if (u8[0] === 1) { live.w = v.getUint32(1); live.h = v.getUint32(5); canvas.width = live.w; canvas.height = live.h; live.needKey = true; return; }
  if (u8[0] !== 2) return;
  const flags = u8[1], payload = u8.subarray(10);
  if (flags & 1) { live.cfg = payload.slice(); const sps = findSps(live.cfg); if (sps) resetDecoder(codecString(sps)); return; }
  if (!live.decoder || live.decoder.state !== 'configured') return;
  const key = !!(flags & 2);
  if (live.needKey && !key) return;
  if (live.decoder.decodeQueueSize > 8 && !key) return; // decodificador atrasado: descarta hasta clave
  let data = payload;
  if (key && live.cfg) { data = new Uint8Array(live.cfg.length + payload.length); data.set(live.cfg); data.set(payload, live.cfg.length); }
  live.needKey = false; setOverlay('');
  live.decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: Number(v.getBigUint64(2)), data }));
}

function liveConnect() {
  if (!('VideoDecoder' in window)) return setOverlay('Este navegador no soporta WebCodecs');
  setOverlay('Conectando…');
  const ws = new WebSocket(`ws://${location.host}/stream/${INSTANCE}?t=${TOKEN}`); ws.binaryType = 'arraybuffer';
  live.ws = ws; live.frames = 0; live.t0 = performance.now();
  $('#btnLive').textContent = 'Desconectar'; $('#btnLive').disabled = false;
  ws.onmessage = (e) => {
    if (typeof e.data !== 'string') return onBinary(e.data);
    const m = JSON.parse(e.data);
    if (m.type === 'pong') { live.rtt = Math.round(performance.now() - m.ts); }
    else if (m.type === 'error') setOverlay('Error: ' + m.message);
    else if (m.type === 'closed') setOverlay(m.reason);
  };
  ws.onclose = (e) => { liveCleanup(); setOverlay(e.code === 4500 || e.code === 4410 ? `Streaming no disponible (${e.reason || e.code}). ¿Android en marcha?` : 'Desconectado'); };
  live.pingTimer = setInterval(() => ws.readyState === 1 && ws.send(JSON.stringify({ t: 'ping', ts: performance.now(), rtt: live.rtt })), 2000);
  live.statTimer = setInterval(() => { const s = (performance.now() - live.t0) / 1000; $('#liveStats').textContent = `${live.w}×${live.h} · ${(live.frames / s).toFixed(0)} fps · latencia ${live.rtt ?? '—'} ms`; live.frames = 0; live.t0 = performance.now(); }, 1000);
}
function liveCleanup() {
  clearInterval(live.pingTimer); clearInterval(live.statTimer);
  try { live.decoder?.close(); } catch { /* */ } live.decoder = null; live.ws = null; live.cfg = null;
  $('#btnLive').textContent = 'Conectar'; $('#liveStats').textContent = 'desconectado';
}
$('#btnLive').onclick = () => { if (live.ws) { live.ws.close(); } else liveConnect(); };
const wsend = (o) => live.ws?.readyState === 1 && live.ws.send(JSON.stringify(o));

// ---- entrada: puntero -> toque ----
function norm(e) { const r = canvas.getBoundingClientRect(); return { x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) }; }
let down = false, lastMove = 0;
canvas.addEventListener('pointerdown', (e) => { canvas.focus(); canvas.setPointerCapture(e.pointerId); down = true; wsend({ t: 'touch', a: 'down', id: 0, ...norm(e), p: 1 }); });
canvas.addEventListener('pointermove', (e) => { if (!down) return; const n = performance.now(); if (n - lastMove < 12) return; lastMove = n; wsend({ t: 'touch', a: 'move', id: 0, ...norm(e), p: 1 }); });
const up = (e) => { if (!down) return; down = false; wsend({ t: 'touch', a: 'up', id: 0, ...norm(e), p: 0 }); };
canvas.addEventListener('pointerup', up); canvas.addEventListener('pointercancel', up);
canvas.addEventListener('contextmenu', (e) => { e.preventDefault(); wsend({ t: 'key', k: 'back' }); });

// ---- teclado físico ----
const SPECIAL = { Enter: 'enter', Backspace: 'del', Tab: 'tab', Escape: 'esc' };
const CODES = { ArrowUp: 19, ArrowDown: 20, ArrowLeft: 21, ArrowRight: 22, Delete: 112, Home: 122, End: 123 };
canvas.addEventListener('keydown', (e) => {
  if (e.ctrlKey || e.metaKey) return;
  if (SPECIAL[e.key]) { wsend({ t: 'key', k: SPECIAL[e.key] }); e.preventDefault(); }
  else if (CODES[e.key]) { wsend({ t: 'keycode', code: CODES[e.key] }); e.preventDefault(); }
  else if (e.key.length === 1) { wsend({ t: 'text', text: e.key }); e.preventDefault(); }
});
canvas.addEventListener('paste', (e) => { const t = e.clipboardData.getData('text'); if (t) { wsend({ t: 'clipboard', text: t, paste: true }); e.preventDefault(); } });

document.querySelectorAll('[data-key]').forEach((b) => b.onclick = () => wsend({ t: 'key', k: b.dataset.key }));
$('#btnRotate').onclick = () => wsend({ t: 'rotate' });
$('#btnNotif').onclick = () => wsend({ t: 'notif' });
const sendText = () => { const v = $('#textIn').value; if (v) { wsend({ t: 'text', text: v }); $('#textIn').value = ''; } };
$('#btnText').onclick = sendText; $('#textIn').onkeydown = (e) => { if (e.key === 'Enter') sendText(); };
$('#btnQ').onclick = () => wsend({ t: 'quality', fps: +$('#qFps').value, bitrateKbps: +$('#qBr').value });

// ---------------- arranque ----------------
refresh().then(loadInfo).then(loadApps);
setInterval(refresh, 3000);
setInterval(() => { if (!$('#tab-logs').classList.contains('hidden')) loadLogs(); if (!$('#tab-sec').classList.contains('hidden')) loadSec(); }, 3000);
window.__cp = { live, api, get inst() { return inst; } }; // útil para depuración/pruebas
