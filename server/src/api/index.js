// API REST. Puerto de dispositivos (Bearer token) y puerto de administración (solo loopback, X-Admin-Token).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { deepMerge, DEFAULTS, saveConfig, validate, ROOT } from '../config/index.js';

export const VERSION = '0.1.0';
const MAX_JSON = 1024 * 1024;
const MAX_APK = 2 * 1024 * 1024 * 1024;

class HttpError extends Error { constructor(status, msg) { super(msg); this.status = status; } }

function send(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(data);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => { size += c.length; if (size > MAX_JSON) { reject(new HttpError(413, 'Cuerpo demasiado grande')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => { try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch { reject(new HttpError(400, 'JSON inválido')); } });
    req.on('error', reject);
  });
}

function saveApk(req, dir, name) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(dir, { recursive: true });
    const safe = path.basename(String(name || `upload-${Date.now()}.apk`)).replace(/[^\w.\- ]/g, '_');
    const file = path.join(dir, safe.toLowerCase().endsWith('.apk') ? safe : safe + '.apk');
    const out = fs.createWriteStream(file);
    let size = 0, magic = null;
    req.on('data', (c) => {
      if (!magic) magic = c.subarray(0, 2).toString('latin1');
      size += c.length;
      if (size > MAX_APK) { req.destroy(); out.destroy(); fs.rmSync(file, { force: true }); reject(new HttpError(413, 'APK demasiado grande')); }
    });
    req.pipe(out);
    out.on('finish', () => {
      if (magic !== 'PK' || size < 1000) { fs.rmSync(file, { force: true }); return reject(new HttpError(400, 'El archivo no es un APK válido')); }
      resolve({ file, size });
    });
    out.on('error', reject); req.on('error', reject);
  });
}

export function createServers({ config, configFile, manager, auth, log, hub, control }) {
  const L = log.child('api');
  const state = { config };

  async function instanceRoutes(method, parts, url, req, res) {
    // parts: ['instances', id?, action?, ...]
    if (parts.length === 1 && method === 'GET') { await manager.refresh(); return send(res, 200, manager.list().map((i) => i.status())); }
    const inst = manager.get(parts[1]); const action = parts[2];
    if (!action && method === 'GET') { await inst.probe(); return send(res, 200, inst.status()); }
    if (method === 'GET' && action === 'info') return send(res, 200, await inst.info());
    if (method === 'GET' && action === 'apps') return send(res, 200, { apps: await inst.apps(url.searchParams.get('all') === '1') });
    if (method === 'DELETE' && action === 'apps' && parts[3]) { await inst.uninstall(decodeURIComponent(parts[3])); return send(res, 200, { ok: true }); }
    if (method !== 'POST') throw new HttpError(404, 'Ruta no encontrada');
    switch (action) {
      case 'start': return send(res, 200, await inst.start());
      case 'stop': return send(res, 200, await inst.stop());
      case 'restart': return send(res, 200, await inst.restart());
      case 'orientation': {
        inst.requireRunning(); const b = await readJson(req);
        if (!['portrait', 'landscape'].includes(b.orientation)) throw new HttpError(400, 'orientation: portrait|landscape');
        await inst.setOrientation(b.orientation); return send(res, 200, { ok: true });
      }
      case 'resolution': {
        const b = await readJson(req);
        if (b.reset) { await inst.resetDisplay(); return send(res, 200, { ok: true }); }
        const { width, height, dpi } = b;
        if (![width, height].every((n) => Number.isInteger(n) && n >= 240 && n <= 3840) || (dpi !== undefined && !(Number.isInteger(dpi) && dpi >= 120 && dpi <= 640))) throw new HttpError(400, 'width/height 240-3840, dpi 120-640');
        await inst.setResolution(width, height, dpi); return send(res, 200, { ok: true });
      }
      case 'launch': { const b = await readJson(req); await inst.launch(String(b.package || '')); return send(res, 200, { ok: true }); }
      case 'apk': {
        inst.requireRunning();
        const { file, size } = await saveApk(req, state.config.paths.apkLibrary, url.searchParams.get('name'));
        L.info(`APK recibido ${path.basename(file)} (${size} B) -> instalando en ${inst.id}`);
        await inst.installApk(file);
        return send(res, 200, { ok: true, file: path.basename(file), size });
      }
      default: throw new HttpError(404, 'Ruta no encontrada');
    }
  }

  const bearer = (req) => (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const ipOf = (req) => (req.socket.remoteAddress || '').replace(/^::ffff:/, '');

  const deviceServer = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://x'); const parts = url.pathname.split('/').filter(Boolean);
      if (parts[0] !== 'api') throw new HttpError(404, 'Ruta no encontrada');
      const p = parts.slice(1);
      if (req.method === 'GET' && p[0] === 'ping') return send(res, 200, { service: 'cloudphone', version: VERSION });
      if (req.method === 'POST' && p[0] === 'pair') {
        const b = await readJson(req); const r = auth.pair(b.code, b.deviceName, ipOf(req));
        return r.error ? send(res, r.status, { error: r.error }) : send(res, 200, r);
      }
      const dev = auth.verify(bearer(req), ipOf(req));
      if (!dev) throw new HttpError(401, 'No autorizado');
      if (req.method === 'GET' && p[0] === 'status') { await manager.refresh(); return send(res, 200, { version: VERSION, device: { id: dev.id, name: dev.name }, instances: manager.list().map((i) => i.status()), streaming: state.config.streaming }); }
      if (p[0] === 'instances') return await instanceRoutes(req.method, p, url, req, res);
      throw new HttpError(404, 'Ruta no encontrada');
    } catch (e) { handleErr(e, res, L); }
  });

  const adminServer = http.createServer(async (req, res) => {
    try {
      if (!['127.0.0.1', '::1'].includes(ipOf(req))) throw new HttpError(403, 'Solo acceso local');
      const url = new URL(req.url, 'http://x'); const parts = url.pathname.split('/').filter(Boolean);
      if (req.method === 'GET' && (url.pathname === '/' || parts[0] === 'panel')) return serveStatic(res, url.pathname === '/' ? 'index.html' : parts.slice(1).join('/'));
      if (!auth.verifyAdmin(req.headers['x-admin-token'])) throw new HttpError(401, 'Token de administración inválido');
      const m = req.method;
      if (parts[0] === 'api' && parts[1] === 'instances') return await instanceRoutes(m, parts.slice(1), url, req, res);
      if (parts[0] !== 'admin') throw new HttpError(404, 'Ruta no encontrada');
      const [, a, b] = parts;
      if (m === 'GET' && a === 'status') { await manager.refresh(); return send(res, 200, { version: VERSION, listen: `${state.config._resolved.listenAddress}:${state.config.server.port}`, instances: manager.list().map((i) => i.status()), devices: auth.devices() }); }
      if (m === 'GET' && a === 'pairing') return send(res, 200, { code: auth.pairingCode });
      if (m === 'POST' && a === 'pairing') return send(res, 200, { code: auth.regeneratePairingCode() });
      if (m === 'GET' && a === 'devices') return send(res, 200, auth.devices());
      if (m === 'GET' && a === 'connections') return send(res, 200, hub ? hub.connections() : []);
      if (m === 'POST' && a === 'shutdown' && control) {
        const b = await readJson(req);
        send(res, 200, { ok: true, restart: !!b.restart });
        setTimeout(() => control.shutdown({ restart: !!b.restart }), 200);
        return;
      }
      if (m === 'DELETE' && a === 'devices' && b) return auth.revoke(b) ? send(res, 200, { ok: true }) : send(res, 404, { error: 'No existe' });
      if (m === 'GET' && a === 'logs') return send(res, 200, log.tail(Number(url.searchParams.get('n')) || 200));
      if (m === 'GET' && a === 'config') { const c = JSON.parse(JSON.stringify(state.config)); delete c._resolved; return send(res, 200, c); }
      if (m === 'PUT' && a === 'config') {
        const merged = deepMerge(DEFAULTS, await readJson(req));
        const errors = validate(merged);
        if (errors.length) return send(res, 422, { error: 'Configuración inválida', errors });
        const errs = saveConfig(configFile, merged); if (errs.length) return send(res, 422, { errors: errs });
        merged._resolved = state.config._resolved; state.config = merged; manager.updateDefs(merged.instances); log.setLevel(merged.server.logLevel);
        L.info('Configuración actualizada desde el panel');
        return send(res, 200, { ok: true, note: 'Instancias: se aplica al próximo arranque. Puertos/dirección: reinicia el servidor.' });
      }
      throw new HttpError(404, 'Ruta no encontrada');
    } catch (e) { handleErr(e, res, L); }
  });

  for (const s of [deviceServer, adminServer]) { s.requestTimeout = 0; s.headersTimeout = 15_000; }

  if (hub) {
    // Streaming: el iPhone se autentica con su token (cabecera Authorization); el panel local con el token de admin (?t=) y solo desde loopback.
    hub.attach(deviceServer, (req) => { const d = auth.verify(bearer(req), ipOf(req)); return d ? { name: d.name } : null; });
    hub.attach(adminServer, (req, url) => (['127.0.0.1', '::1'].includes(ipOf(req)) && auth.verifyAdmin(url.searchParams.get('t') || req.headers['x-admin-token']) ? { name: 'Panel de administración' } : null));
  }
  return { deviceServer, adminServer };
}

const PANEL_DIR = path.join(ROOT, 'panel');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };
function serveStatic(res, rel) {
  const file = path.resolve(PANEL_DIR, rel);
  if (!file.startsWith(PANEL_DIR + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) throw new HttpError(404, 'No encontrado');
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'self'; connect-src 'self' ws://127.0.0.1:* ws://localhost:*; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'" });
  fs.createReadStream(file).pipe(res);
}

function handleErr(e, res, L) {
  const status = e.status || 500;
  if (status >= 500) L.error(`${e.stack || e.message}`);
  if (!res.headersSent) send(res, status, { error: e.message });
  else res.end();
}
