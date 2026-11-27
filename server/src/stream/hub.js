// Hub de streaming: una sesión scrcpy por instancia, N clientes WebSocket.
//
// Servidor -> cliente
//   binario  [0x01][w u32][h u32]                      nueva sesión de vídeo (inicio o rotación)
//   binario  [0x02][flags][pts u64][payload H.264]     flags: bit0 = config (SPS/PPS), bit1 = fotograma clave
//   texto    JSON {type:'hello'|'pong'|'clipboard'|'error'|'closed'|'stats'}
// Cliente -> servidor (texto JSON)
//   {t:'touch',a:'down|move|up',id,x,y,p}  x,y normalizados 0..1 sobre la imagen
//   {t:'key',k:'back|home|recents|power|enter|del|menu|volup|voldown|tab|esc'}  |  {t:'keycode',code}
//   {t:'text',text} {t:'clipboard',text,paste} {t:'rotate'} {t:'ping',ts}
//   {t:'quality',fps,bitrateKbps,maxWidth}
import { WebSocketServer } from 'ws';
import path from 'node:path';
import { ScrcpySession, KEY } from './scrcpy.js';

const NAMED_KEYS = { back: KEY.BACK, home: KEY.HOME, recents: KEY.APP_SWITCH, power: KEY.POWER, enter: KEY.ENTER, del: KEY.DEL, menu: KEY.MENU, volup: KEY.VOLUME_UP, voldown: KEY.VOLUME_DOWN, tab: KEY.TAB, esc: KEY.ESCAPE };
const QUALITY = { low: { br: 0.5, gop: 3 }, balanced: { br: 1, gop: 2 }, high: { br: 1.75, gop: 1 } };
const MAX_BUFFER = 1.5 * 1024 * 1024;
const MAX_GOP_BYTES = 6 * 1024 * 1024;
const IDLE_MS = 15_000;

function packetMsg(p) {
  const b = Buffer.allocUnsafe(10 + p.data.length);
  b[0] = 2; b[1] = (p.config ? 1 : 0) | (p.key ? 2 : 0); b.writeBigUInt64BE(p.pts, 2); p.data.copy(b, 10);
  return b;
}
function sessionMsg(s) { const b = Buffer.alloc(9); b[0] = 1; b.writeUInt32BE(s.width, 1); b.writeUInt32BE(s.height, 5); return b; }

export class StreamHub {
  constructor({ getConfig, manager, auth, log }) {
    this.getConfig = getConfig; this.manager = manager; this.auth = auth; this.log = log.child('stream');
    this.entries = new Map(); // instanceId -> { session, clients:Set, gop:[], gopBytes, idle, starting, override }
    this.wss = new WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: 512 * 1024 });
  }

  /** Engancha el hub a un http.Server. authFn(req, url) devuelve {name} o null. */
  attach(server, authFn) {
    server.on('upgrade', (req, socket, head) => {
      const url = new URL(req.url, 'http://x');
      const m = url.pathname.match(/^\/stream\/([a-z0-9_-]{1,24})$/);
      const who = m && authFn(req, url);
      if (!m || !who) { socket.write(`HTTP/1.1 ${m ? 401 : 404} ${m ? 'Unauthorized' : 'Not Found'}\r\nConnection: close\r\n\r\n`); socket.destroy(); return; }
      this.wss.handleUpgrade(req, socket, head, (ws) => this._onClient(ws, m[1], who, (req.socket.remoteAddress || '').replace(/^::ffff:/, '')));
    });
  }

  connections() {
    const out = [];
    for (const [id, e] of this.entries) for (const c of e.clients) out.push({ instance: id, device: c.who.name, ip: c.ip, since: c.since, sentBytes: c.sent, rttMs: c.rtt ?? null });
    return out;
  }

  _videoOpts(id, entry) {
    const cfg = this.getConfig(); const st = { ...cfg.streaming, ...(entry?.override || {}) };
    const inst = cfg.instances.find((i) => i.id === id); const r = inst.android.resolution;
    const q = QUALITY[st.quality] || QUALITY.balanced;
    return { maxSize: Math.round(st.maxWidth * Math.max(r.width, r.height) / Math.min(r.width, r.height)), bitrateKbps: Math.round(st.bitrateKbps * q.br), fps: st.fps, iFrameInterval: q.gop };
  }

  async _ensureSession(id) {
    const inst = this.manager.get(id);
    let e = this.entries.get(id);
    if (!e) { e = { session: null, clients: new Set(), gop: [], gopBytes: 0, idle: null, starting: null, override: null }; this.entries.set(id, e); }
    clearTimeout(e.idle); e.idle = null;
    if (e.session?.state === 'running') return e;
    if (!e.starting) {
      e.starting = (async () => {
        if (inst.state !== 'running') throw new Error(`La instancia no está en marcha (${inst.state})`);
        const s = new ScrcpySession({ adb: this.manager.ctx.adb, serial: inst.serial, jar: this.getConfig().paths.scrcpyServer, log: this.log, video: this._videoOpts(id, e) });
        s.on('session', (z) => { e.gop = []; e.gopBytes = 0; this._broadcast(e, sessionMsg(z)); });
        s.on('packet', (p) => this._onPacket(e, p));
        s.on('clipboard', (t) => this._broadcastJson(e, { type: 'clipboard', text: t }));
        s.on('closed', () => this._onSessionClosed(id, e, s));
        e.session = s; e.gop = []; e.gopBytes = 0;
        await s.start();
      })().finally(() => { e.starting = null; });
    }
    await e.starting;
    return e;
  }

  _onPacket(e, p) {
    const msg = packetMsg(p);
    if (p.key && !p.config) { e.gop = []; e.gopBytes = 0; }
    if (!p.config) { e.gop.push(msg); e.gopBytes += msg.length; if (e.gopBytes > MAX_GOP_BYTES) { e.gop = []; e.gopBytes = 0; } }
    for (const c of e.clients) {
      if (c.ws.readyState !== 1) continue;
      if (c.ws.bufferedAmount > MAX_BUFFER) { // cliente lento: descarta hasta el próximo fotograma clave
        if (!c.dropping) { c.dropping = true; this.log.warn(`Cliente lento (${c.who.name}): descartando fotogramas`); }
        if (Date.now() - (e.lastReset || 0) > 3000) { e.lastReset = Date.now(); e.session?.resetVideo(); }
      }
      if (c.dropping) { if (p.key || p.config) { if (c.ws.bufferedAmount < MAX_BUFFER / 4) c.dropping = false; } if (c.dropping) continue; }
      c.sent += msg.length; c.ws.send(msg, { binary: true });
    }
  }

  _onSessionClosed(id, e, s) {
    if (e.session !== s) return;
    e.session = null; e.gop = []; e.gopBytes = 0;
    this._broadcastJson(e, { type: 'closed', reason: 'La sesión de vídeo terminó (¿Android detenido?)' });
    for (const c of e.clients) c.ws.close(4410, 'stream closed');
  }

  _broadcast(e, buf) { for (const c of e.clients) if (c.ws.readyState === 1) c.ws.send(buf, { binary: true }); }
  _broadcastJson(e, o) { const t = JSON.stringify(o); for (const c of e.clients) if (c.ws.readyState === 1) c.ws.send(t); }

  async _onClient(ws, id, who, ip) {
    const inst = (() => { try { return this.manager.get(id); } catch { return null; } })();
    const send = (o) => ws.readyState === 1 && ws.send(JSON.stringify(o));
    if (!inst) { send({ type: 'error', message: 'Instancia desconocida' }); return ws.close(4404, 'unknown instance'); }
    ws._socket.setNoDelay(true);
    const client = { ws, who, ip, since: new Date().toISOString(), sent: 0, dropping: false, rtt: null };
    let entry;
    try { entry = await this._ensureSession(id); }
    catch (err) { this.log.error(`No se pudo iniciar el streaming: ${err.message}`); send({ type: 'error', message: err.message }); return ws.close(4500, 'stream start failed'); }
    if (ws.readyState !== 1) return;
    entry.clients.add(client);
    this.log.info(`Cliente de streaming conectado: ${who.name} (${ip}) -> ${id} [${entry.clients.size} activos]`);
    const s = entry.session;
    send({ type: 'hello', instance: { id, name: inst.def.name }, root: inst.root, device: s.deviceName, codec: 'h264', size: s.size, fps: this._videoOpts(id, entry).fps });
    if (s.size) ws.send(sessionMsg(s.size), { binary: true });
    if (s.config) ws.send(packetMsg({ config: true, key: false, pts: 0n, data: s.config }), { binary: true });
    for (const m of entry.gop) ws.send(m, { binary: true }); // GOP en caché: la imagen aparece sin esperar al siguiente fotograma clave
    if (!entry.gop.length) s.resetVideo();

    ws.on('message', (raw, isBinary) => { if (!isBinary) this._onControl(entry, client, id, raw.toString('utf8'), send); });
    ws.on('error', () => {});
    ws.on('close', () => {
      entry.clients.delete(client);
      this.log.info(`Cliente de streaming desconectado: ${who.name} (${ip}) [${entry.clients.size} activos]`);
      if (!entry.clients.size) entry.idle = setTimeout(() => { this.log.info(`Sin clientes: deteniendo streaming de ${id}`); entry.session?.stop(); }, IDLE_MS);
    });
  }

  _onControl(entry, client, id, text, send) {
    let m; try { m = JSON.parse(text); } catch { return; }
    const s = entry.session; if (!s || s.state !== 'running') return;
    const num = (v, lo, hi) => Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : null;
    switch (m.t) {
      case 'touch': { const x = num(m.x, 0, 1), y = num(m.y, 0, 1); if (x !== null && y !== null) s.touch(m.a, Number.isInteger(m.id) ? m.id : 0, x, y, num(m.p, 0, 1) ?? 1); break; }
      case 'key': if (NAMED_KEYS[m.k]) s.key(NAMED_KEYS[m.k]); break;
      case 'keycode': if (Number.isInteger(m.code) && m.code > 0 && m.code < 400) s.key(m.code); break;
      case 'text': if (typeof m.text === 'string' && m.text.length <= 2000) s.text(m.text); break;
      case 'clipboard': if (typeof m.text === 'string') s.setClipboard(m.text, !!m.paste); break;
      case 'rotate': s.rotateDevice(); break;
      case 'keyframe': if (Date.now() - (entry.lastReset || 0) > 1000) { entry.lastReset = Date.now(); s.resetVideo(); } break;
      case 'notif': s.expandNotifications(); break;
      case 'collapse': s.collapsePanels(); break;
      case 'ping': client.rtt = Number.isFinite(m.rtt) ? m.rtt : client.rtt; send({ type: 'pong', ts: m.ts, server: Date.now() }); break;
      case 'quality': {
        const o = { fps: num(m.fps, 5, 60), bitrateKbps: num(m.bitrateKbps, 500, 30000), maxWidth: num(m.maxWidth, 240, 2160) };
        entry.override = Object.fromEntries(Object.entries({ ...entry.override, ...o }).filter(([, v]) => v !== null && v !== undefined));
        this.log.info(`Cambio de calidad por ${client.who.name}: ${JSON.stringify(entry.override)}`);
        this._restart(id, entry).catch((e) => send({ type: 'error', message: e.message }));
        break;
      }
      default: break;
    }
  }

  async _restart(id, entry) {
    const old = entry.session;
    entry.session = null; entry.gop = []; entry.gopBytes = 0;
    old?.removeAllListeners('closed'); await old?.stop();
    const clients = [...entry.clients];
    await this._ensureSession(id);
    const s = entry.session;
    for (const c of clients) {
      if (c.ws.readyState !== 1) continue;
      c.dropping = false;
      c.ws.send(JSON.stringify({ type: 'hello', instance: { id }, device: s.deviceName, codec: 'h264', size: s.size, fps: this._videoOpts(id, entry).fps }));
      if (s.size) c.ws.send(sessionMsg(s.size), { binary: true });
      if (s.config) c.ws.send(packetMsg({ config: true, key: false, pts: 0n, data: s.config }), { binary: true });
    }
  }

  async stopAll() { for (const e of this.entries.values()) { for (const c of e.clients) c.ws.close(1001, 'server shutdown'); await e.session?.stop(); } }
}

export const jarPath = (paths) => paths.scrcpyServer || path.join(path.dirname(paths.androidSdk), 'scrcpy', 'scrcpy-server.jar');
