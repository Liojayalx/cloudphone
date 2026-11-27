// Sesión scrcpy-server v5.0.1 (Genymobile, Apache-2.0): H.264 real de la pantalla Android + canal de control.
// Protocolo según doc/develop.md y ControlMessage*.java de la etiqueta v5.0.1.
import { EventEmitter } from 'node:events';
import net from 'node:net';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

export const SCRCPY_VERSION = '5.0.1';
const REMOTE_JAR = '/data/local/tmp/scrcpy-server.jar';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Android KeyEvent
export const KEY = { HOME: 3, BACK: 4, POWER: 26, VOLUME_UP: 24, VOLUME_DOWN: 25, TAB: 61, ENTER: 66, DEL: 67, MENU: 82, APP_SWITCH: 187, DPAD_UP: 19, DPAD_DOWN: 20, DPAD_LEFT: 21, DPAD_RIGHT: 22, ESCAPE: 111, FORWARD_DEL: 112, MOVE_HOME: 122, MOVE_END: 123 };

/** Lector con búfer: readExact(n) espera a tener n bytes. */
class Reader {
  constructor(sock) {
    this.chunks = []; this.len = 0; this.waiter = null; this.closed = false;
    sock.on('data', (c) => { this.chunks.push(c); this.len += c.length; this._wake(); });
    sock.on('close', () => { this.closed = true; this._wake(); });
    sock.on('error', () => { this.closed = true; this._wake(); });
  }
  _wake() { if (this.waiter) { const w = this.waiter; this.waiter = null; w(); } }
  async readExact(n) {
    while (this.len < n) {
      if (this.closed) throw new Error('socket cerrado');
      await new Promise((r) => { this.waiter = r; });
    }
    const buf = Buffer.concat(this.chunks); const out = buf.subarray(0, n);
    const rest = buf.subarray(n); this.chunks = rest.length ? [rest] : []; this.len = rest.length;
    return out;
  }
}

export class ScrcpySession extends EventEmitter {
  /** opts: { adb, serial, jar, log, paths, video:{maxSize,bitrateKbps,fps,iFrameInterval} } */
  constructor(opts) {
    super();
    Object.assign(this, opts);
    this.state = 'idle'; // idle | starting | running | closed
    this.size = null; this.deviceName = ''; this.codec = null;
    this.config = null; // último paquete de configuración (SPS/PPS)
    this.proc = null; this.videoSock = null; this.ctrlSock = null; this.port = null;
    this.stats = { packets: 0, bytes: 0 };
  }

  async start() {
    if (this.state !== 'idle') throw new Error(`estado inválido: ${this.state}`);
    this.state = 'starting';
    const { adb, serial, log } = this;
    try {
      const push = await adb.raw(['-s', serial, 'push', this.jar, REMOTE_JAR], { timeout: 30_000 });
      if (push.code !== 0) throw new Error(`adb push falló: ${push.stderr || push.stdout}`);
      this.scid = crypto.randomInt(1, 0x7fffffff).toString(16).padStart(8, '0');
      const fw = await adb.raw(['-s', serial, 'forward', 'tcp:0', `localabstract:scrcpy_${this.scid}`], { timeout: 10_000 });
      this.port = parseInt(fw.stdout, 10);
      if (!this.port) throw new Error(`adb forward falló: ${fw.stderr || fw.stdout}`);

      const v = this.video;
      const args = ['-s', serial, 'shell', `CLASSPATH=${REMOTE_JAR}`, 'app_process', '/', 'com.genymobile.scrcpy.Server', SCRCPY_VERSION,
        `scid=${this.scid}`, 'log_level=info', 'tunnel_forward=true', 'audio=false', 'control=true', 'cleanup=false', 'clipboard_autosync=false',
        `max_size=${v.maxSize}`, `video_bit_rate=${v.bitrateKbps * 1000}`, `max_fps=${v.fps}`, `video_codec_options=i-frame-interval=${v.iFrameInterval}`];
      log.info(`scrcpy: lanzando servidor en ${serial} (scid ${this.scid}, puerto local ${this.port})`);
      this.proc = spawn(adb.exe, args, { env: { ...process.env, ...adb.env }, windowsHide: true });
      let serverOut = '';
      const onOut = (d) => { serverOut += d; if (serverOut.length > 4000) serverOut = serverOut.slice(-4000); };
      this.proc.stdout.on('data', onOut); this.proc.stderr.on('data', onOut);
      this.proc.on('exit', (c) => { log.info(`scrcpy: servidor terminó (código ${c})${c ? ' ' + serverOut.trim().split('\n').slice(-3).join(' | ') : ''}`); this._closed(); });

      this.videoSock = await this._connect(true);
      const vr = new Reader(this.videoSock);
      this.ctrlSock = await this._connect(false);
      this.ctrlSock.setNoDelay(true);
      this.ctrlSock.on('error', () => {});
      this._readDevice(new Reader(this.ctrlSock)).catch(() => {});

      this.deviceName = (await vr.readExact(64)).toString('utf8').replace(/\0+$/, '');
      const codecId = (await vr.readExact(4)).toString('latin1');
      if (codecId !== 'h264') throw new Error(`códec inesperado: ${JSON.stringify(codecId)}`);
      this.codec = 'h264';
      this.state = 'running';
      this._readVideo(vr).catch((e) => { if (this.state !== 'closed') log.warn(`scrcpy: lectura de vídeo terminó: ${e.message}`); this._closed(); });
    } catch (e) { this.state = 'idle'; await this.stop(); throw e; }
  }

  // Conecta al puerto reenviado. El primer socket recibe un byte "dummy" cuando el servidor ya escucha.
  async _connect(first) {
    const deadline = Date.now() + 20_000;
    for (;;) {
      if (Date.now() > deadline) throw new Error('tiempo agotado conectando con scrcpy-server en el Android');
      if (this.proc && this.proc.exitCode !== null) throw new Error('scrcpy-server terminó antes de conectar');
      const sock = await new Promise((resolve) => {
        const s = net.connect(this.port, '127.0.0.1');
        s.setNoDelay(true);
        const fail = () => { s.destroy(); resolve(null); };
        s.once('error', fail);
        if (first) {
          const t = setTimeout(fail, 1500);
          s.once('data', (d) => { clearTimeout(t); s.pause(); s.unshift(d.subarray(1)); resolve(s); s.resume(); });
          s.once('close', fail);
        } else s.once('connect', () => resolve(s));
      });
      if (sock) return sock;
      await sleep(250);
    }
  }

  async _readVideo(r) {
    for (;;) {
      const h = await r.readExact(12);
      if (h[0] & 0x80) { // paquete de sesión: cambio de tamaño/rotación
        this.size = { width: h.readUInt32BE(4), height: h.readUInt32BE(8) };
        this.config = null;
        this.emit('session', this.size);
        continue;
      }
      const config = !!(h[0] & 0x40), key = !!(h[0] & 0x20);
      const pts = (BigInt(h.readUInt32BE(0) & 0x1fffffff) << 32n) | BigInt(h.readUInt32BE(4));
      const data = await r.readExact(h.readUInt32BE(8));
      this.stats.packets++; this.stats.bytes += data.length;
      if (config) this.config = data;
      this.emit('packet', { config, key, pts, data });
    }
  }

  // Mensajes dispositivo->cliente: 0 = portapapeles, 1 = ack portapapeles, 2 = salida UHID
  async _readDevice(r) {
    for (;;) {
      const t = (await r.readExact(1))[0];
      if (t === 0) { const n = (await r.readExact(4)).readUInt32BE(0); this.emit('clipboard', (await r.readExact(n)).toString('utf8')); }
      else if (t === 1) await r.readExact(8);
      else if (t === 2) { await r.readExact(2); const n = (await r.readExact(2)).readUInt16BE(0); await r.readExact(n); }
      else throw new Error(`mensaje de dispositivo desconocido ${t}`);
    }
  }

  _closed() {
    if (this.state === 'closed') return;
    this.state = 'closed';
    for (const s of [this.videoSock, this.ctrlSock]) try { s?.destroy(); } catch { /* */ }
    this.adb.raw(['-s', this.serial, 'forward', '--remove', `tcp:${this.port}`]).catch(() => {});
    this.emit('closed');
  }
  async stop() {
    try { this.proc?.kill(); } catch { /* */ }
    this._closed();
  }

  // ---------------- control (big-endian) ----------------
  _send(buf) { if (this.ctrlSock && !this.ctrlSock.destroyed) this.ctrlSock.write(buf); }

  /** nx,ny en [0,1] sobre la imagen de vídeo actual; action: 'down'|'move'|'up' */
  touch(action, id, nx, ny, pressure = 1) {
    if (!this.size) return;
    const { width: w, height: h } = this.size;
    const b = Buffer.alloc(32);
    const act = { down: 0, up: 1, move: 2 }[action]; if (act === undefined) return;
    b[0] = 2; b[1] = act;
    b.writeBigInt64BE(BigInt(id | 0), 2);
    b.writeInt32BE(Math.max(0, Math.min(w - 1, Math.round(nx * (w - 1)))), 10);
    b.writeInt32BE(Math.max(0, Math.min(h - 1, Math.round(ny * (h - 1)))), 14);
    b.writeUInt16BE(w, 18); b.writeUInt16BE(h, 20);
    b.writeUInt16BE(act === 1 ? 0 : Math.round(Math.max(0, Math.min(1, pressure)) * 0xffff), 22);
    b.writeInt32BE(act === 1 ? 0 : 1, 24); // actionButton: PRIMARY
    b.writeInt32BE(act === 1 ? 0 : 1, 28); // buttons
    this._send(b);
  }
  keycode(code, action /* 0 down, 1 up */, meta = 0) {
    const b = Buffer.alloc(14); b[0] = 0; b[1] = action; b.writeInt32BE(code, 2); b.writeInt32BE(0, 6); b.writeInt32BE(meta, 10); this._send(b);
  }
  key(code) { this.keycode(code, 0); this.keycode(code, 1); }
  text(str) {
    for (const chunk of splitText(str, 300)) { const t = Buffer.from(chunk, 'utf8'); const b = Buffer.alloc(5 + t.length); b[0] = 1; b.writeUInt32BE(t.length, 1); t.copy(b, 5); this._send(b); }
  }
  setClipboard(str, paste = false) {
    const t = Buffer.from(str, 'utf8').subarray(0, 200_000); const b = Buffer.alloc(14 + t.length);
    b[0] = 9; b.writeBigUInt64BE(0n, 1); b[9] = paste ? 1 : 0; b.writeUInt32BE(t.length, 10); t.copy(b, 14); this._send(b);
  }
  empty(type) { this._send(Buffer.from([type])); }
  resetVideo() { this.empty(17); }      // pide nueva sesión de captura => paquete de config + fotograma clave
  rotateDevice() { this.empty(11); }
  expandNotifications() { this.empty(5); }
  collapsePanels() { this.empty(7); }
}

function splitText(s, max) {
  const out = []; let cur = '';
  for (const ch of s) { if (Buffer.byteLength(cur + ch) > max) { out.push(cur); cur = ''; } cur += ch; }
  if (cur) out.push(cur);
  return out;
}
