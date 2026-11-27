// Envoltorio de adb
import path from 'node:path';
import { run } from './proc.js';

export class Adb {
  constructor(sdk, env = {}) { this.exe = path.join(sdk, 'platform-tools', 'adb.exe'); this.env = env; }
  raw(args, opts = {}) { return run(this.exe, args, { ...opts, env: { ...this.env, ...opts.env } }); }
  async devices() {
    const r = await this.raw(['devices']);
    return r.stdout.split(/\r?\n/).slice(1).map((l) => l.trim().split(/\s+/)).filter((x) => x[0]).map(([serial, state]) => ({ serial, state }));
  }
  async shell(serial, cmd, opts) { return this.raw(['-s', serial, 'shell', cmd], opts); }
  async prop(serial, name) { return (await this.shell(serial, `getprop ${name}`)).stdout; }
  async install(serial, apk) { return this.raw(['-s', serial, 'install', '-r', '-d', apk], { timeout: 300_000 }); }
  async uninstall(serial, pkg) { return this.raw(['-s', serial, 'uninstall', pkg], { timeout: 60_000 }); }
  async root(serial) {
    await this.raw(['-s', serial, 'root'], { timeout: 20_000 });
    await this.raw(['-s', serial, 'wait-for-device'], { timeout: 30_000 });
    const id = (await this.shell(serial, 'id')).stdout;
    return /uid=0\(root\)/.test(id);
  }
}
