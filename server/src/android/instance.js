// Una instancia Android = un AVD del emulador oficial. Estado real, sin simulaciones.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { run } from './proc.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const PKG_RE = /^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$/;

export class Instance {
  constructor(def, index, ctx) {
    this.def = def; this.id = def.id; this.index = index;
    this.ctx = ctx; // { paths, adb, log }
    this.port = 5554 + index * 2;
    this.serial = `emulator-${this.port}`;
    this.state = 'stopped'; // stopped | starting | running | stopping | error
    this.lastError = null; this.startedAt = null; this.proc = null; this.root = null;
    this.busy = null;
  }
  get avdName() { return this.id; }
  get avdDir() { return path.join(this.ctx.paths.avdHome, `${this.avdName}.avd`); }
  get env() {
    const p = this.ctx.paths;
    return { ...p.toolEnv, ANDROID_HOME: p.androidSdk, JAVA_HOME: p.jdk };
  }
  setDef(def) { this.def = def; this.id = def.id; }

  /** Crea el AVD si no existe. */
  async ensureAvd() {
    if (fs.existsSync(path.join(this.avdDir, 'config.ini'))) return;
    const a = this.def.android;
    const sysImg = `system-images;android-${a.apiLevel};${a.image}`;
    if (!fs.existsSync(path.join(this.ctx.paths.androidSdk, 'system-images', `android-${a.apiLevel}`, ...a.image.split(';'))))
      throw new Error(`Falta la imagen ${sysImg}. Instálala con el instalador/SDK manager.`);
    fs.mkdirSync(this.ctx.paths.avdHome, { recursive: true });
    this.ctx.log.info(`Creando AVD ${this.avdName} (${sysImg})`);
    const bat = path.join(this.ctx.paths.androidSdk, 'cmdline-tools', 'latest', 'bin', 'avdmanager.bat');
    const r = await run(bat, ['create', 'avd', '-n', this.avdName, '-k', sysImg, '-d', a.deviceProfile, '--force'], { env: this.env, input: 'no\n', timeout: 120_000 });
    if (!fs.existsSync(path.join(this.avdDir, 'config.ini'))) throw new Error(`avdmanager falló: ${r.stderr || r.stdout}`);
  }

  /** Aplica la configuración editable al config.ini del AVD (surte efecto en el siguiente arranque). */
  applyAvdConfig() {
    const a = this.def.android;
    const file = path.join(this.avdDir, 'config.ini');
    const map = new Map(fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).map((l) => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1)]; }));
    const w = a.orientation === 'landscape' ? a.resolution.height : a.resolution.width;
    const h = a.orientation === 'landscape' ? a.resolution.width : a.resolution.height;
    Object.entries({
      'hw.ramSize': a.ramMB, 'hw.cpu.ncore': a.cpuCores, 'hw.lcd.width': w, 'hw.lcd.height': h,
      'hw.lcd.density': a.dpi, 'disk.dataPartition.size': `${a.storageGB}G`, 'hw.keyboard': 'yes',
    }).forEach(([k, v]) => map.set(k, String(v)));
    // avdmanager a veces escribe <temp>: los datos se perderían en cada arranque
    map.delete('disk.dataPartition.path');
    fs.writeFileSync(file, [...map].map(([k, v]) => `${k}=${v}`).join('\n') + '\n');
  }

  /** Detecta una instancia ya en marcha (p. ej. tras reiniciar el servidor). */
  async probe() {
    if (this.busy) return this.state;
    const devs = await this.ctx.adb.devices();
    const d = devs.find((x) => x.serial === this.serial);
    if (d && d.state === 'device') {
      const boot = await this.ctx.adb.prop(this.serial, 'sys.boot_completed');
      if (boot === '1') {
        if (this.state !== 'running') { this.state = 'running'; this.startedAt ||= Date.now(); }
        if (this.root === null) this.root = /uid=0\(root\)/.test((await this.ctx.adb.shell(this.serial, 'id')).stdout);
        return this.state;
      }
      return this.state === 'stopped' ? 'starting' : this.state;
    }
    if (this.state === 'running' || this.state === 'starting' && !this.proc) { this.state = 'stopped'; this.root = null; }
    return this.state;
  }

  _exclusive(name, fn) {
    if (this.busy) throw Object.assign(new Error(`Operación en curso: ${this.busy}`), { status: 409 });
    this.busy = name;
    return fn().finally(() => { this.busy = null; }).then(() => this.status());
  }

  async start() {
    if (await this.probe() === 'running') return this.status();
    return this._exclusive('start', async () => {
      this.state = 'starting'; this.lastError = null;
      const log = this.ctx.log;
      try {
        await this.ensureAvd(); this.applyAvdConfig();
        const out = fs.openSync(path.join(this.ctx.paths.logs, `emulator-${this.id}.log`), 'a');
        const a = this.def.android;
        const args = ['-avd', this.avdName, '-port', String(this.port), '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot', '-gpu', a.gpu];
        log.info(`Arrancando emulador ${this.id} (${args.join(' ')})`);
        this.proc = spawn(path.join(this.ctx.paths.androidSdk, 'emulator', 'emulator.exe'), args, { env: { ...process.env, ...this.env }, windowsHide: true, stdio: ['ignore', out, out] });
        this.proc.on('exit', (c) => { log.info(`Emulador ${this.id} terminó (código ${c})`); this.proc = null; if (this.state !== 'stopping') { this.state = 'stopped'; } });
        const t0 = Date.now();
        for (;;) {
          if (!this.proc) throw new Error('El emulador terminó inesperadamente (¿WHPX activo? ¿otro hipervisor en uso?). Revisa logs/emulator-' + this.id + '.log');
          if (Date.now() - t0 > 300_000) throw new Error('Tiempo de espera agotado esperando el arranque de Android');
          const devs = await this.ctx.adb.devices();
          if (devs.some((x) => x.serial === this.serial && x.state === 'device') && await this.ctx.adb.prop(this.serial, 'sys.boot_completed') === '1') break;
          await sleep(2000);
        }
        await this.postBoot();
        this.state = 'running'; this.startedAt = Date.now();
        log.info(`Android ${this.id} listo en ${Math.round((Date.now() - t0) / 1000)} s (root=${this.root})`);
      } catch (e) {
        this.state = 'error'; this.lastError = e.message; log.error(`Fallo al iniciar ${this.id}: ${e.message}`);
        if (this.proc) this.proc.kill();
        throw e;
      }
      return this.status();
    });
  }

  async postBoot() {
    const adb = this.ctx.adb;
    if (this.def.android.root) this.root = await adb.root(this.serial);
    else this.root = (await adb.shell(this.serial, 'id')).stdout.includes('uid=0(');
    if (this.def.android.root && !this.root) this.ctx.log.warn(`root solicitado pero no disponible en ${this.id}`);
    await this.setOrientation(this.def.android.orientation);
  }

  async stop() {
    if (await this.probe() === 'stopped' && !this.proc) return this.status();
    return this._exclusive('stop', async () => {
      this.state = 'stopping';
      this.ctx.log.info(`Deteniendo ${this.id}`);
      await this.ctx.adb.raw(['-s', this.serial, 'emu', 'kill'], { timeout: 15_000 }).catch(() => {});
      const t0 = Date.now();
      while (Date.now() - t0 < 40_000) {
        const devs = await this.ctx.adb.devices();
        if (!devs.some((x) => x.serial === this.serial) && !this.proc) break;
        await sleep(1000);
      }
      if (this.proc) this.proc.kill();
      this.state = 'stopped'; this.root = null; this.startedAt = null;
      return this.status();
    });
  }
  async restart() { await this.stop(); return this.start(); }

  requireRunning() { if (this.state !== 'running') throw Object.assign(new Error(`La instancia ${this.id} no está en marcha (estado: ${this.state})`), { status: 409 }); }

  async setOrientation(o) {
    const sh = (c) => this.ctx.adb.shell(this.serial, c);
    await sh('settings put system accelerometer_rotation 0');
    await sh(`settings put system user_rotation ${o === 'landscape' ? 1 : 0}`);
  }
  async setResolution(width, height, dpi) {
    this.requireRunning();
    const sh = (c) => this.ctx.adb.shell(this.serial, c);
    await sh(`wm size ${width}x${height}`);
    if (dpi) await sh(`wm density ${dpi}`);
  }
  async resetDisplay() { this.requireRunning(); await this.ctx.adb.shell(this.serial, 'wm size reset; wm density reset'); }

  async info() {
    this.requireRunning();
    const adb = this.ctx.adb, s = this.serial;
    const props = {};
    for (const [k, p] of Object.entries({ androidVersion: 'ro.build.version.release', sdk: 'ro.build.version.sdk', model: 'ro.product.model', buildType: 'ro.build.type', abi: 'ro.product.cpu.abi', fingerprint: 'ro.build.fingerprint' })) props[k] = await adb.prop(s, p);
    const idOut = (await adb.shell(s, 'id')).stdout;
    const size = (await adb.shell(s, 'wm size')).stdout, dens = (await adb.shell(s, 'wm density')).stdout;
    const mem = (await adb.shell(s, 'grep MemTotal /proc/meminfo')).stdout.match(/(\d+)/);
    const df = (await adb.shell(s, 'df -k /data | tail -1')).stdout.split(/\s+/);
    this.root = /uid=0\(root\)/.test(idOut);
    return {
      ...props,
      root: { active: this.root, id: idOut.split(' ').slice(0, 2).join(' '), suExists: (await adb.shell(s, 'ls /system/xbin/su 2>/dev/null')).stdout.length > 0 },
      display: { size: size.split('\n').pop().replace(/.*: /, ''), density: dens.split('\n').pop().replace(/.*: /, '') },
      memoryTotalMB: mem ? Math.round(Number(mem[1]) / 1024) : null,
      storage: df.length >= 4 ? { totalMB: Math.round(df[1] / 1024), usedMB: Math.round(df[2] / 1024), freeMB: Math.round(df[3] / 1024) } : null,
      uptimeSeconds: this.startedAt ? Math.round((Date.now() - this.startedAt) / 1000) : null,
    };
  }

  async apps(all = false) {
    this.requireRunning();
    // -f da "package:<ruta>=<paquete>"; las apps instaladas por el usuario (incluidas actualizaciones de apps de sistema) viven en /data/app
    const r = await this.ctx.adb.shell(this.serial, 'pm list packages -f');
    return r.stdout.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.startsWith('package:') && (all || l.startsWith('package:/data/app/')))
      .map((l) => l.slice(l.lastIndexOf('=') + 1)).sort();
  }
  async installApk(file) {
    this.requireRunning();
    const r = await this.ctx.adb.install(this.serial, file);
    if (!/Success/.test(r.stdout)) throw Object.assign(new Error(`Instalación fallida: ${(r.stdout + ' ' + r.stderr).trim()}`), { status: 422 });
    return true;
  }
  async uninstall(pkg) {
    this.requireRunning();
    if (!PKG_RE.test(pkg)) throw Object.assign(new Error('Nombre de paquete inválido'), { status: 400 });
    const r = await this.ctx.adb.uninstall(this.serial, pkg);
    if (!/Success/.test(r.stdout)) throw Object.assign(new Error(`No se pudo desinstalar: ${(r.stdout + ' ' + r.stderr).trim()}`), { status: 422 });
    return true;
  }
  async launch(pkg) {
    this.requireRunning();
    if (!PKG_RE.test(pkg)) throw Object.assign(new Error('Nombre de paquete inválido'), { status: 400 });
    const r = await this.ctx.adb.shell(this.serial, `monkey -p ${pkg} -c android.intent.category.LAUNCHER 1`);
    if (/No activities found|Error/.test(r.stdout + r.stderr)) throw Object.assign(new Error('La app no tiene actividad lanzable'), { status: 422 });
  }

  status() {
    const a = this.def.android;
    return {
      id: this.id, name: this.def.name, state: this.state, busy: this.busy, error: this.lastError,
      root: { requested: a.root, active: this.root }, serial: this.serial,
      configured: { resolution: a.resolution, dpi: a.dpi, orientation: a.orientation, ramMB: a.ramMB, cpuCores: a.cpuCores, storageGB: a.storageGB, apiLevel: a.apiLevel, image: a.image },
      uptimeSeconds: this.startedAt && this.state === 'running' ? Math.round((Date.now() - this.startedAt) / 1000) : null,
    };
  }
}
