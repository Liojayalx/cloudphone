import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { loadConfig, deepMerge, DEFAULTS, validate } from '../src/config/index.js';

const tmp = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'cp-')), 'cloudphone-config.json');

test('crea la configuración por defecto si no existe y es válida', () => {
  const f = tmp();
  const { config, errors, created } = loadConfig(f);
  assert.equal(created, true); assert.deepEqual(errors, []); assert.ok(fs.existsSync(f));
  assert.equal(config.instances[0].android.root, true);
});

test('completa valores que faltan con los predeterminados', () => {
  const f = tmp(); fs.writeFileSync(f, JSON.stringify({ server: { port: 9000 } }));
  const { config, errors } = loadConfig(f);
  assert.deepEqual(errors, []); assert.equal(config.server.port, 9000); assert.equal(config.streaming.fps, 30);
});

test('rechaza valores inválidos con mensajes claros', () => {
  const c = deepMerge(DEFAULTS, { server: { port: 80, listenAddress: '0.0.0.0' }, streaming: { fps: 500 } });
  const e = validate(c).join('|');
  assert.match(e, /server\.port/); assert.match(e, /0\.0\.0\.0/); assert.match(e, /streaming\.fps/);
});

test('acepta archivos con BOM UTF-8 (Bloc de notas / PowerShell 5.1)', () => {
  const f = tmp(); fs.writeFileSync(f, '﻿' + JSON.stringify({ server: { port: 9100 } }));
  const { config, errors } = loadConfig(f);
  assert.deepEqual(errors, []); assert.equal(config.server.port, 9100);
});

test('el ejemplo cloudphone-config.example.json es válido', () => {
  const f = tmp(); fs.copyFileSync(new URL('../cloudphone-config.example.json', import.meta.url), f);
  const { errors } = loadConfig(f);
  assert.deepEqual(errors, []);
});

test('JSON corrupto devuelve error, no excepción', () => {
  const f = tmp(); fs.writeFileSync(f, '{ no es json');
  const { config, errors } = loadConfig(f);
  assert.equal(config, null); assert.equal(errors.length, 1);
});

test('ids de instancia duplicados o inválidos se rechazan', () => {
  const i = DEFAULTS.instances[0];
  const c = { ...DEFAULTS, instances: [i, { ...i }, { ...i, id: 'Mal Id' }] };
  const e = validate(c).join('|');
  assert.match(e, /duplicado/); assert.match(e, /\.id debe cumplir/);
});
