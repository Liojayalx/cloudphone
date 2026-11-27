// Carga, valida y completa con valores por defecto cloudphone-config.json
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

export const DEFAULTS = {
  schemaVersion: 1,
  server: {
    listenAddress: 'auto', // 'auto' = primera IPv4 privada; '127.0.0.1' = solo local
    port: 8443,
    adminPort: 8444,
    adminLoopbackOnly: true,
    autoStartAndroid: false,
    stopAndroidOnExit: true,
    logLevel: 'info',
    tls: { enabled: false, certPath: '', keyPath: '' },
  },
  auth: { pairingCodeLength: 8, tokenBytes: 32, maxAuthorizedDevices: 3 },
  instances: [
    {
      id: 'phone1',
      name: 'Mi Cloud Phone',
      android: {
        apiLevel: 33,
        image: 'google_apis;x86_64',
        resolution: { width: 720, height: 1280 },
        dpi: 320,
        orientation: 'portrait',
        ramMB: 3072,
        cpuCores: 3,
        storageGB: 8,
        gpu: 'host',
        deviceProfile: 'pixel_5',
        root: true,
      },
    },
  ],
  streaming: {
    codec: 'h264', maxWidth: 720, fps: 30, bitrateKbps: 4000, quality: 'balanced',
    reconnect: { enabled: true, maxAttempts: 0, backoffMs: 1000 },
  },
  paths: { androidSdk: '', jdk: '', avdHome: '', androidUserHome: '', tmp: '', data: '', logs: '', apkLibrary: '', scrcpyServer: '' },
};

const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);

export function deepMerge(base, over) {
  if (!isObj(base) || !isObj(over)) return over === undefined ? base : over;
  const out = { ...base };
  for (const k of Object.keys(over)) out[k] = isObj(base[k]) && isObj(over[k]) ? deepMerge(base[k], over[k]) : over[k];
  return out;
}

function lanAddress() {
  // Se ignoran adaptadores virtuales (Hyper-V/WSL, VirtualBox, VMware, Docker...): no son la red a la que se conecta el iPhone
  const virtual = /vEthernet|WSL|Hyper-V|VirtualBox|VMware|vmnet|Docker|Loopback|Bluetooth/i;
  const found = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const i of list || []) {
      if (i.family === 'IPv4' && !i.internal && /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(i.address)) found.push({ name, address: i.address });
    }
  }
  return (found.find((f) => !virtual.test(f.name)) || found[0])?.address || '127.0.0.1';
}

export function validate(c) {
  const e = [];
  const int = (v, lo, hi, name) => { if (!Number.isInteger(v) || v < lo || v > hi) e.push(`${name} debe ser entero entre ${lo} y ${hi}`); };
  const oneOf = (v, list, name) => { if (!list.includes(v)) e.push(`${name} debe ser uno de: ${list.join(', ')}`); };
  const s = c.server;
  if (typeof s.listenAddress !== 'string' || !s.listenAddress) e.push('server.listenAddress inválido');
  int(s.port, 1024, 65535, 'server.port'); int(s.adminPort, 1024, 65535, 'server.adminPort');
  if (s.port === s.adminPort) e.push('server.port y server.adminPort no pueden ser iguales');
  oneOf(s.logLevel, ['debug', 'info', 'warn', 'error'], 'server.logLevel');
  if (s.listenAddress === '0.0.0.0') e.push('server.listenAddress 0.0.0.0 no permitido: usa la IP de tu LAN o "auto"');
  int(c.auth.pairingCodeLength, 6, 16, 'auth.pairingCodeLength'); int(c.auth.tokenBytes, 16, 64, 'auth.tokenBytes');
  int(c.auth.maxAuthorizedDevices, 1, 20, 'auth.maxAuthorizedDevices');
  if (!Array.isArray(c.instances) || c.instances.length < 1) e.push('instances debe tener al menos una instancia');
  const ids = new Set();
  (c.instances || []).forEach((it, n) => {
    const p = `instances[${n}]`;
    if (!/^[a-z0-9_-]{1,24}$/.test(it.id || '')) e.push(`${p}.id debe cumplir [a-z0-9_-]{1,24}`);
    if (ids.has(it.id)) e.push(`${p}.id duplicado`); ids.add(it.id);
    if (typeof it.name !== 'string' || !it.name.trim()) e.push(`${p}.name vacío`);
    const a = it.android || {};
    int(a.apiLevel, 28, 40, `${p}.android.apiLevel`);
    if (!/^[a-z_]+;[a-z0-9_]+$/.test(a.image || '')) e.push(`${p}.android.image inválido (ej. google_apis;x86_64)`);
    int(a.resolution?.width, 320, 2160, `${p}.android.resolution.width`); int(a.resolution?.height, 480, 3840, `${p}.android.resolution.height`);
    int(a.dpi, 120, 640, `${p}.android.dpi`); int(a.ramMB, 1024, 16384, `${p}.android.ramMB`);
    int(a.cpuCores, 1, 8, `${p}.android.cpuCores`); int(a.storageGB, 2, 128, `${p}.android.storageGB`);
    oneOf(a.orientation, ['portrait', 'landscape'], `${p}.android.orientation`);
    oneOf(a.gpu, ['host', 'swiftshader_indirect', 'angle_indirect', 'auto'], `${p}.android.gpu`);
    if (!/^[a-z0-9_]+$/.test(a.deviceProfile || '')) e.push(`${p}.android.deviceProfile inválido`);
    if (typeof a.root !== 'boolean') e.push(`${p}.android.root debe ser true/false`);
  });
  const st = c.streaming;
  int(st.fps, 5, 60, 'streaming.fps'); int(st.bitrateKbps, 500, 30000, 'streaming.bitrateKbps'); int(st.maxWidth, 240, 2160, 'streaming.maxWidth');
  oneOf(st.quality, ['low', 'balanced', 'high'], 'streaming.quality'); oneOf(st.codec, ['h264'], 'streaming.codec');
  return e;
}

/** Devuelve { config, file, errors }. Si el archivo no existe lo crea con valores por defecto. */
export function loadConfig(file = process.env.CLOUDPHONE_CONFIG || path.join(ROOT, 'cloudphone-config.json')) {
  let user = {};
  let created = false;
  if (!fs.existsSync(file)) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(DEFAULTS, null, 2) + '\n');
    created = true;
  } else {
    // El Bloc de notas / PowerShell 5.1 guardan con BOM UTF-8: JSON.parse no lo admite
    try { user = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, '')); }
    catch (err) { return { config: null, file, errors: [`No se puede leer ${file}: ${err.message}`] }; }
  }
  const config = deepMerge(DEFAULTS, user);
  if (Array.isArray(user.instances)) config.instances = user.instances.map((i) => deepMerge(DEFAULTS.instances[0], i));
  const errors = validate(config);
  const base = path.dirname(file);
  const p = config.paths;
  p.androidSdk ||= process.env.ANDROID_SDK_ROOT || path.join(base, 'runtime', 'sdk');
  p.jdk ||= process.env.JAVA_HOME || path.join(base, 'runtime', 'jdk');
  p.avdHome ||= path.join(base, 'runtime', 'avd');
  p.androidUserHome ||= path.join(base, 'runtime', 'android-user');
  p.tmp ||= path.join(base, 'runtime', 'tmp');
  p.scrcpyServer ||= path.join(base, 'runtime', 'scrcpy', 'scrcpy-server.jar');
  p.data ||= path.join(base, 'data');
  p.logs ||= path.join(base, 'logs');
  p.apkLibrary ||= path.join(base, 'apk');
  config._resolved = { listenAddress: config.server.listenAddress === 'auto' ? lanAddress() : config.server.listenAddress };
  return { config, file, errors, created };
}

/** Guarda solo lo que el usuario puede editar (sin campos internos). */
export function saveConfig(file, config) {
  const clean = JSON.parse(JSON.stringify(config));
  delete clean._resolved;
  const errors = validate(clean);
  if (errors.length) return errors;
  fs.writeFileSync(file + '.tmp', JSON.stringify(clean, null, 2) + '\n');
  fs.renameSync(file + '.tmp', file);
  return [];
}
