// Logs: consola + archivo rotativo + buffer en memoria para el panel
import fs from 'node:fs';
import path from 'node:path';
import { EventEmitter } from 'node:events';

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const MAX_BYTES = 5 * 1024 * 1024;

export class Logger extends EventEmitter {
  constructor(dir, level = 'info') {
    super();
    this.level = LEVELS[level] ?? 20;
    this.ring = [];
    fs.mkdirSync(dir, { recursive: true });
    this.file = path.join(dir, 'server.log');
  }
  setLevel(l) { this.level = LEVELS[l] ?? this.level; }
  _write(lvl, mod, msg) {
    if (LEVELS[lvl] < this.level) return;
    const entry = { t: new Date().toISOString(), level: lvl, module: mod, msg: String(msg) };
    const line = `${entry.t} ${lvl.toUpperCase().padEnd(5)} [${mod}] ${entry.msg}`;
    console[lvl === 'error' ? 'error' : 'log'](line);
    this.ring.push(entry); if (this.ring.length > 500) this.ring.shift();
    try {
      if (fs.existsSync(this.file) && fs.statSync(this.file).size > MAX_BYTES) fs.renameSync(this.file, this.file + '.1');
      fs.appendFileSync(this.file, line + '\n');
    } catch { /* un fallo de log nunca debe tumbar el servidor */ }
    this.emit('entry', entry);
  }
  tail(n = 200) { return this.ring.slice(-n); }
  child(mod) {
    return Object.fromEntries(Object.keys(LEVELS).map((l) => [l, (m) => this._write(l, mod, m)]));
  }
}
