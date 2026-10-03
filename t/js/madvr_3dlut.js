/*
 * madvr_3dlut.test.js — characterization + format suite for the madVR
 * .3dlut (H3D) writer in usr/share/PGenerator/webui-workspace.js.
 *
 * Extracts the converter functions from the live source by anchor (no line
 * numbers), feeds them a tiny analytic .cube, and pins the exact byte layout
 * DisplayCAL's madvr.py writes: 96-byte LE header, text params at 512,
 * 256^3 BGR uint16 LE nodes (blue fastest) at 16384, linear cal1 trailer.
 *
 * Run:  node t/js/madvr_3dlut.js   (raw JSON)
 *       prove t/madvr_3dlut.t      (TAP via perl wrapper)
 * Requires: Node 22+, no npm dependencies.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('node:assert/strict');

const SRC = path.join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-workspace.js');
const source = fs.readFileSync(SRC, 'utf8');

// Anchor-extract top-level functions and consts (brace-match state machine
// skipping strings/comments, same contract as rgb_balance_formula.js).
function extractBlock(name, decl) {
  const re = new RegExp(`^${decl} ${name}\\b`, 'm');
  const m = source.match(re);
  assert.ok(m, `${decl} ${name} found in webui-workspace.js`);
  assert.equal(source.slice(0, m.index).match(re), null, `${name} anchor unique`);
  let i = source.indexOf('{', m.index);
  if (decl === 'const') {
    // const initializers in this file are single-line statements
    const end = source.indexOf('\n', m.index);
    return source.slice(m.index, end + 1);
  }
  let depth = 0, inStr = null, inLine = false, inBlock = false, inRe = false;
  for (; i < source.length; i++) {
    const c = source[i], p = source[i - 1];
    if (inLine) { if (c === '\n') inLine = false; continue; }
    if (inBlock) { if (c === '/' && p === '*') inBlock = false; continue; }
    if (inStr) { if (c === '\\') { i++; continue; } if (c === inStr) inStr = null; continue; }
    if (c === '/' && source[i + 1] === '/') { inLine = true; continue; }
    if (c === '/' && source[i + 1] === '*') { inBlock = true; continue; }
    if (c === '"' || c === "'" || c === '`') { inStr = c; continue; }
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return source.slice(m.index, i + 1); }
  }
  throw new Error(`${name} block not closed`);
}

const names = [
  ['METER_MADVR_LUT_RES', 'const'], ['METER_MADVR_PARAM_OFFSET', 'const'],
  ['METER_MADVR_LUT_OFFSET', 'const'], ['METER_MADVR_CAL1_SIZE', 'const'],
  ['METER_MADVR_D65_WP', 'const'], ['meterMadvrScratch', 'const'],
  ['meterMadvrPrimaries', 'function'], ['meterMadvrParamsFromName', 'function'],
  ['meterMadvrLatticePos', 'function'], ['meterMadvrTrilinear', 'function'],
  ['meterCubeToMadvr', 'function'],
];
const context = {};
vm.createContext(context);
for (const [n, d] of names) vm.runInContext(extractBlock(n, d), context);

const results = [];
const t = (label, fn) => { try { fn(); results.push([label, true, '']); } catch (e) { results.push([label, false, String(e && e.message || e)]); } };
// Cross-realm (vm) values have foreign prototypes; compare via JSON.
const eq = (a, b, msg) => assert.equal(JSON.stringify(a), JSON.stringify(b), msg);

// Build a test .cube lattice: output = 0.25 + 0.5*signal on each axis
// (a ramp that is neither identity nor flat, linear in the signal).
// Storage follows the .cube convention: red index varies fastest.
function rampParsed(S) {
  const values = [];
  for (let b = 0; b < S; b++) for (let g = 0; g < S; g++) for (let r = 0; r < S; r++) {
    values.push([0.25 + 0.5 * r / (S - 1), 0.25 + 0.5 * g / (S - 1), 0.25 + 0.5 * b / (S - 1)]);
  }
  return { ok: true, size: S, values, domainMin: [0, 0, 0], domainMax: [1, 1, 1], errors: [] };
}

const parsed = rampParsed(5);

t('unknown gamut refused', () => {
  assert.equal(context.meterMadvrPrimaries('rec-9999'), null);
  assert.equal(context.meterCubeToMadvr(parsed, { gamut: 'rec-9999' }), null);
});

t('bt709 primaries match madVR install-API values', () => {
  eq(context.meterMadvrPrimaries('bt709'),
    [0.64000, 0.33000, 0.30000, 0.60000, 0.15000, 0.06000, 0.31273, 0.32902]);
  eq(context.meterMadvrPrimaries('BT2020').slice(0, 2), [0.708, 0.292]);
});

t('name heuristics: solved names carry mode and gamut', () => {
  eq(context.meterMadvrParamsFromName('20261001_TV_sdr_ramp_active_bt709_2.2.cube'), { gamut: 'bt709', hdr: false });
  eq(context.meterMadvrParamsFromName('20261001_TV_hdr10_lattice_active_bt2020_2.4.cube'), { gamut: 'bt2020', hdr: true });
  eq(context.meterMadvrParamsFromName('x_p3d65_y'), { gamut: 'p3d65', hdr: false });
  eq(context.meterMadvrParamsFromName('plain'), { gamut: 'bt709', hdr: false });
  // hdr without gamut defaults to bt2020 (solve-side rule)
  eq(context.meterMadvrParamsFromName('lut_hdr10'), { gamut: 'bt2020', hdr: true });
});

t('file size and header layout', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'bt709', hdr: false });
  assert.equal(bytes.constructor.name, 'Uint8Array', 'returns Uint8Array');
  const total = 16384 + 256 * 256 * 256 * 6 + 1552;
  assert.equal(bytes.length, total, 'total = header/LUT pad + 256^3*6 + cal1');
  const dv = new DataView(bytes.buffer);
  assert.equal(String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]), '3DLT');
  assert.equal(dv.getInt32(4, true), 1, 'file version 1');
  assert.equal(dv.getInt32(48, true), 8, 'input bit depth 8');
  assert.equal(dv.getInt32(64, true), 16, 'output bit depth 16');
  assert.equal(dv.getInt32(72, true), 512, 'parameters offset');
  assert.equal(dv.getInt32(80, true), 16384, 'LUT offset');
  assert.equal(dv.getInt32(84, true), 0, 'compression method none');
  const lutBytes = 256 * 256 * 256 * 6;
  assert.equal(dv.getInt32(88, true), lutBytes, 'compressed size');
  assert.equal(dv.getInt32(92, true), lutBytes, 'uncompressed size');
});

t('SDR parameter block', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'bt709', hdr: false });
  const size = new DataView(bytes.buffer).getInt32(76, true);
  const text = Buffer.from(bytes.subarray(512, 512 + size)).toString('latin1');
  assert.ok(text.endsWith('\0'), 'params NUL-terminated');
  const lines = text.replace(/\0$/, '').split('\r\n');
  assert.deepEqual(lines, [
    'Input_Primaries 0.64000 0.33000 0.30000 0.60000 0.15000 0.06000 0.31273 0.32902',
    'Input_Range 16 235',
    'Output_Range 16 235',
  ]);
});

t('HDR parameter block adds PQ transfer lines', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'bt2020', hdr: true });
  const size = new DataView(bytes.buffer).getInt32(76, true);
  const text = Buffer.from(bytes.subarray(512, 512 + size)).toString('latin1');
  assert.match(text, /Input_Transfer_Function PQ/);
  assert.match(text, /Output_Transfer_Function PQ/);
  assert.match(text, /Input_Primaries 0\.70800/);
});

t('LUT node order and values (BGR uint16 LE, blue fastest)', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'p3d65', hdr: false });
  const lut16 = new Uint16Array(bytes.buffer, 16384, 256 * 256 * 256 * 3);
  const q = (v) => Math.round(v * 65535);
  // Node (r=0,g=0,b=0): ramp -> all channels 0.25
  assert.deepEqual([lut16[0], lut16[1], lut16[2]], [q(0.25), q(0.25), q(0.25)], 'first node B,G,R = 0.25');
  // Walk is blue-fastest: node index 1 = (r=0,g=0,b=1) -> only B channel moves.
  assert.deepEqual([lut16[3], lut16[4], lut16[5]],
    [Math.round((0.25 + 0.5 / 255) * 65535), q(0.25), q(0.25)], 'B is the fast axis');
  // Last node (r=g=b=255): ramp -> 0.75 on every channel.
  const last = (256 * 256 * 256 - 1) * 3;
  assert.deepEqual([lut16[last], lut16[last + 1], lut16[last + 2]], [q(0.75), q(0.75), q(0.75)], 'last node 0.75');
  // A mid red-only node: index r=128,g=0,b=0 -> offset ((128*256)*256)*3
  const mid = ((128 * 256 + 0) * 256 + 0) * 3;
  assert.deepEqual([lut16[mid], lut16[mid + 1], lut16[mid + 2]],
    [q(0.25), q(0.25), Math.round((0.25 + 0.5 * 128 / 255) * 65535)], 'red is the slow axis');
});

t('domain mapping honours DOMAIN_MIN/MAX', () => {
  const p = rampParsed(3);
  p.domainMin = [0.2, 0.2, 0.2]; p.domainMax = [0.8, 0.8, 0.8];
  // values ramp 0.25..0.75 across lattice 0..2
  const bytes = context.meterCubeToMadvr(p, { gamut: 'bt709', hdr: false });
  const lut16 = new Uint16Array(bytes.buffer, 16384, 256 * 256 * 256 * 3);
  // signal 0.5 sits mid-domain -> lattice coordinate 1.0 -> ramp value 0.5
  const node = ((0 * 256 + 0) * 256 + 128) * 3; // r=0,g=0,b=128 -> signal 0.50196 ~ domain mid
  const got = lut16[node];
  assert.ok(Math.abs(got - Math.round(0.5 * 65535)) <= 65535 * 0.004, `domain-mid B sample ${got} ~ 0.5`);
});

t('cal1 trailer is a linear full-range ramp', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'bt709', hdr: false });
  const c = bytes.length - 1552;
  assert.equal(String.fromCharCode(bytes[c], bytes[c + 1], bytes[c + 2], bytes[c + 3]), 'cal1');
  const dv = new DataView(bytes.buffer);
  assert.equal(dv.getInt32(c + 4, true), 1, 'cal1 version');
  assert.equal(dv.getInt32(c + 8, true), 256, 'entries');
  assert.equal(dv.getInt32(c + 12, true), 2, 'bytes per entry');
  const ramps = new Uint16Array(bytes.buffer, c + 16, 768);
  for (const ch of [0, 1, 2]) {
    assert.equal(ramps[ch * 256], 0, `ch${ch} black`);
    assert.equal(ramps[ch * 256 + 255], 65535, `ch${ch} white`);
    assert.equal(ramps[ch * 256 + 100], 25700, `ch${ch} linear mid`);
  }
});

t('bad input refused', () => {
  assert.equal(context.meterCubeToMadvr(null, {}), null);
  assert.equal(context.meterCubeToMadvr({ ok: false }, {}), null);
  assert.equal(context.meterCubeToMadvr({ ok: true, size: 2, values: 'nope' }, {}), null);
});

let failed = 0;
for (const [label, ok, err] of results) {
  if (!ok) failed++;
  console.log(`${ok ? 'ok' : 'FAIL'} ${label}${ok ? '' : ' — ' + err}`);
}
console.log(JSON.stringify({ pass: results.length - failed, fail: failed }));
process.exit(failed ? 1 : 0);
