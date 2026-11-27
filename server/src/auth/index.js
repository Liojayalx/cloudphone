// Autenticación: código de emparejamiento aleatorio -> token por dispositivo (solo se guarda su hash)
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // sin 0/O/1/I
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const safeEq = (a, b) => { const x = Buffer.from(a), y = Buffer.from(b); return x.length === y.length && crypto.timingSafeEqual(x, y); };

export class Auth {
  constructor(dir, cfg, log) {
    this.cfg = cfg; this.log = log;
    fs.mkdirSync(dir, { recursive: true });
    this.file = path.join(dir, 'auth.json');
    this.adminTokenFile = path.join(dir, 'admin.token');
    this.fails = new Map(); // ip -> {n, until}
    this.state = fs.existsSync(this.file) ? JSON.parse(fs.readFileSync(this.file, 'utf8')) : { pairingCode: null, devices: [] };
    if (!this.state.pairingCode) this.regeneratePairingCode();
    if (!fs.existsSync(this.adminTokenFile)) fs.writeFileSync(this.adminTokenFile, crypto.randomBytes(32).toString('hex'));
    // CLOUDPHONE_ADMIN_TOKEN (>=32 caracteres hex) permite fijar el token solo para esa ejecución (pruebas/automatización)
    const envTok = process.env.CLOUDPHONE_ADMIN_TOKEN;
    this.adminToken = envTok && /^[0-9a-f]{32,}$/.test(envTok) ? envTok : fs.readFileSync(this.adminTokenFile, 'utf8').trim();
  }
  _save() { fs.writeFileSync(this.file + '.tmp', JSON.stringify(this.state, null, 2)); fs.renameSync(this.file + '.tmp', this.file); }

  regeneratePairingCode() {
    const n = this.cfg.pairingCodeLength;
    const bytes = crypto.randomBytes(n);
    this.state.pairingCode = Array.from(bytes, (b) => ALPHABET[b % ALPHABET.length]).join('');
    this._save();
    this.log.info('Código de emparejamiento regenerado');
    return this.state.pairingCode;
  }
  get pairingCode() { return this.state.pairingCode; }

  /** Canjea el código por un token. Limita intentos fallidos por IP. */
  pair(code, deviceName, ip) {
    const f = this.fails.get(ip);
    if (f && f.until > Date.now()) return { error: 'Demasiados intentos. Espera un minuto.', status: 429 };
    if (typeof code !== 'string' || !safeEq(code.trim().toUpperCase(), this.state.pairingCode)) {
      const n = (f?.n || 0) + 1;
      this.fails.set(ip, { n, until: n >= 5 ? Date.now() + 60_000 : 0 });
      this.log.warn(`Emparejamiento fallido desde ${ip}`);
      return { error: 'Código incorrecto', status: 401 };
    }
    if (this.state.devices.length >= this.cfg.maxAuthorizedDevices) return { error: 'Máximo de dispositivos alcanzado. Revoca alguno desde el panel.', status: 403 };
    this.fails.delete(ip);
    const token = crypto.randomBytes(this.cfg.tokenBytes).toString('hex');
    const dev = { id: crypto.randomUUID(), name: String(deviceName || 'iPhone').slice(0, 40), tokenHash: sha(token), createdAt: new Date().toISOString(), lastSeen: null, lastIp: ip };
    this.state.devices.push(dev);
    this.regeneratePairingCode(); // el código es de un solo uso
    this.log.info(`Dispositivo autorizado: ${dev.name} (${ip})`);
    return { token, deviceId: dev.id };
  }

  /** Devuelve el dispositivo asociado al token o null. */
  verify(token, ip) {
    if (!token) return null;
    const h = sha(token);
    const dev = this.state.devices.find((d) => safeEq(d.tokenHash, h));
    if (dev) { dev.lastSeen = new Date().toISOString(); dev.lastIp = ip; }
    return dev || null;
  }
  verifyAdmin(token) { return typeof token === 'string' && safeEq(token, this.adminToken); }
  devices() { return this.state.devices.map(({ tokenHash, ...d }) => d); }
  revoke(id) {
    const n = this.state.devices.length;
    this.state.devices = this.state.devices.filter((d) => d.id !== id);
    if (this.state.devices.length !== n) { this._save(); this.log.info(`Dispositivo revocado: ${id}`); return true; }
    return false;
  }
  flush() { this._save(); }
}
