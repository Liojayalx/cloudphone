// Punto de entrada del servidor Cloud Phone
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { loadConfig } from './config/index.js';
import { Logger } from './log/index.js';
import { Auth } from './auth/index.js';
import { InstanceManager } from './android/manager.js';
import { createServers, VERSION } from './api/index.js';
import { StreamHub } from './stream/hub.js';

const { config, file, errors, created } = loadConfig();
if (!config || errors.length) {
  console.error(`Configuración inválida en ${file}:\n - ${errors.join('\n - ')}`);
  process.exit(1);
}
const logger = new Logger(config.paths.logs, config.server.logLevel);
const log = logger.child('server');
if (created) log.warn(`No existía configuración: se creó ${file} con valores por defecto`);
log.info(`Cloud Phone Server ${VERSION} — config ${file}`);

const auth = new Auth(config.paths.data, config.auth, logger.child('auth'));
const manager = new InstanceManager(config, logger);
const hub = new StreamHub({ getConfig: () => config, manager, auth, log: logger });
const control = { shutdown: (opts) => shutdown('panel', opts) };
const { deviceServer, adminServer } = createServers({ config, configFile: file, manager, auth, log: logger, hub, control });

const host = config._resolved.listenAddress;
const listen = (srv, h, p, name) => new Promise((res, rej) => { srv.once('error', rej); srv.listen(p, h, () => { log.info(`${name} escuchando en http://${h}:${p}`); res(); }); });

try {
  await listen(deviceServer, host, config.server.port, 'API de dispositivos');
  await listen(adminServer, '127.0.0.1', config.server.adminPort, 'API de administración (solo local)');
} catch (e) {
  log.error(`No se pudo abrir el puerto: ${e.message}`);
  process.exit(1);
}
if (host === '127.0.0.1') log.warn('Escuchando solo en localhost: el iPhone no podrá conectar. Configura server.listenAddress con la IP de tu LAN o "auto".');
log.info(`Código de emparejamiento: ${auth.pairingCode}  (un solo uso)`);
log.info(`Token de administración en: ${path.join(config.paths.data, 'admin.token')}`);

await manager.refresh();
manager.startAutostart(config);

const pidFile = path.join(config.paths.data, 'server.pid');
fs.writeFileSync(pidFile, String(process.pid));

let closing = false;
async function shutdown(sig, { restart = false } = {}) {
  if (closing) return; closing = true;
  log.info(`Recibido ${sig}${restart ? ' (reinicio)' : ''}, cerrando...`);
  deviceServer.close(); adminServer.close();
  deviceServer.closeAllConnections?.(); adminServer.closeAllConnections?.();
  await hub.stopAll();
  if (config.server.stopAndroidOnExit) await manager.stopAll();
  auth.flush();
  try { fs.rmSync(pidFile, { force: true }); } catch { /* */ }
  if (restart) {
    // nuevo proceso con los mismos argumentos y entorno, ya con los puertos liberados
    spawn(process.execPath, process.argv.slice(1), { detached: true, stdio: 'ignore', env: process.env, windowsHide: true, cwd: process.cwd() }).unref();
  }
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('uncaughtException', (e) => log.error(`uncaughtException: ${e.stack}`));
process.on('unhandledRejection', (e) => log.error(`unhandledRejection: ${e?.stack || e}`));
