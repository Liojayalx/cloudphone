// Ejecución de procesos externos (adb, emulator, avdmanager .bat) sin shell inyectable
import { spawn } from 'node:child_process';

const q = (a) => `"${String(a).replace(/"/g, '\\"')}"`;

/** Ejecuta un exe o un .bat y devuelve { code, stdout, stderr }. Nunca rechaza salvo error de lanzamiento. */
export function run(file, args = [], { env, timeout = 60_000, input, cwd } = {}) {
  return new Promise((resolve, reject) => {
    const isBat = /\.(bat|cmd)$/i.test(file);
    const child = isBat
      ? spawn('cmd.exe', ['/d', '/s', '/c', `"${[q(file), ...args.map(q)].join(' ')}"`], { env: { ...process.env, ...env }, windowsHide: true, windowsVerbatimArguments: true, cwd })
      : spawn(file, args, { env: { ...process.env, ...env }, windowsHide: true, cwd });
    let stdout = '', stderr = '', done = false;
    const timer = setTimeout(() => { if (!done) { child.kill(); stderr += `\n[timeout ${timeout}ms]`; } }, timeout);
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', (e) => { done = true; clearTimeout(timer); reject(e); });
    child.on('close', (code) => { done = true; clearTimeout(timer); resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() }); });
    if (input !== undefined) child.stdin.end(input); else child.stdin.end();
  });
}
