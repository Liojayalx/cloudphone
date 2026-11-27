// Gestor de instancias (preparado para varias; hoy la config trae una)
import fs from 'node:fs';
import { Adb } from './adb.js';
import { Instance } from './instance.js';

export class InstanceManager {
  constructor(config, log) {
    this.log = log.child ? log.child('android') : log;
    const p = config.paths;
    for (const d of [p.androidUserHome, p.tmp, p.avdHome]) fs.mkdirSync(d, { recursive: true });
    // Todo lo que escriben adb/emulador (claves, cachés, temporales) va a las rutas configuradas, no a C:\Users\...
    p.toolEnv = { ANDROID_USER_HOME: p.androidUserHome, ANDROID_AVD_HOME: p.avdHome, ANDROID_SDK_ROOT: p.androidSdk, TEMP: p.tmp, TMP: p.tmp };
    this.ctx = { paths: p, adb: new Adb(p.androidSdk, p.toolEnv), log: this.log };
    this.instances = new Map();
    config.instances.forEach((d, i) => this.instances.set(d.id, new Instance(d, i, this.ctx)));
  }
  get(id) { const i = this.instances.get(id); if (!i) throw Object.assign(new Error(`Instancia desconocida: ${id}`), { status: 404 }); return i; }
  list() { return [...this.instances.values()]; }
  /** Aplica una nueva definición (surte efecto en el siguiente arranque). */
  updateDefs(defs) { defs.forEach((d) => { const i = this.instances.get(d.id); if (i) i.setDef(d); }); }
  async refresh() { await Promise.all(this.list().map((i) => i.probe().catch(() => {}))); }
  async startAutostart(config) {
    if (!config.server.autoStartAndroid) return;
    for (const i of this.list()) i.start().catch(() => {});
  }
  async stopAll() { await Promise.all(this.list().map((i) => i.stop().catch(() => {}))); }
}
