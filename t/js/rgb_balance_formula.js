/*
 * rgb_balance_formula.test.js — characterization suite for the RGB balance
 * formulas in usr/share/PGenerator/webui-app.js.
 *
 * Purpose: pin the CURRENT behavior of rgbBalance*, meterPerceptualRgbBalanceGain,
 * meterBalanceTargetRow and ynToLstar so that later edits to the source are
 * deliberate. This is a characterization suite — pins behavior of rgbBalance*
 * in webui-app.js; if it fails after editing the source, the edit changed
 * balance math intentionally only.
 *
 * How it works: the harness reads webui-app.js as text, finds each target
 * function by a `^function <name>(` anchor (verified unique via grep at authoring
 * time; re-asserted at runtime), brace-matches its body with a state machine
 * that skips line/block comments, single/double/backtick strings and regex
 * literals, validates each snippet parses via new Function(), then evaluates
 * all snippets in a sandbox with stubs for every collaborator they call.
 * No line numbers are hard-coded. No repo source file is modified.
 *
 * Run:  node t/js/rgb_balance_formula.js   (raw JSON)
 *        prove t/rgb_balance_formula.t            (TAP via perl wrapper)
 * Requires: Node 22+, no npm dependencies.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const SRC_PATH = path.join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-app.js');

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------
const FN_NAMES = [
  'ynToLstar',
  'meterRgbBalanceFormula',
  'meterPerceptualRgbBalanceGain',
  'meterBalanceTargetRow',
  'rgbBalanceLstar',
  'rgbBalancePerceptual',
  'rgbBalanceAbsolute',
  'rgbBalanceHCFR',
  'rgbBalance',
  'meterRgbBalancePlotKey',
  'meterRgbBalancePlotIdentity',
  'meterRgbBalanceActiveNoiseFloor',
  'meterRgbBalanceNoiseFloor',
  'meterRgbBalanceNoiseFloorMode',
  'meterRgbBalanceNoiseFloorActive',
  'meterRgbBalanceNoiseFloorAnnotationLive',
  'meterFormatNoiseFloorValue',
  'meterNoiseHistoryStore',
  'meterStepNoiseKey',
  'meterRecordReadingNoise',
  'meterStepNoiseSigma',
  'meterEmpiricalNoiseFloorFor',
  'meterRgbBalanceEffectiveNoiseFloor',
  'meterRgbBalanceOffScaleDir',
  'meterRgbBalanceWithinNoise',
  'meterRgbBalanceNoiseFloorApplies',
  'meterUpdateNoiseFloorControlAvailability',
  'meterOnRgbBalanceNoiseFloorClear',
  'meterCommitRgbBalanceNoiseFloorInput',
  'meterOnRgbBalanceNoiseFloorChange',
  'meterSwitchToPerceptualRgbBalance',
  'meterApplyNoiseFloorPreset',
  'meterRgbDeltasForLive',
];

function extractFunction(src, name) {
  const re = new RegExp('^function\\s+' + name + '\\s*\\(', 'm');
  const m = re.exec(src);
  if (!m) throw new Error('anchor not found for function ' + name);
  // exactly one anchor expected — guard against ambiguous extraction
  const second = new RegExp('^function\\s+' + name + '\\s*\\(', 'gm');
  let count = 0;
  while (second.exec(src) !== null) count++;
  if (count !== 1) throw new Error('ambiguous anchors for function ' + name + ' (' + count + ')');

  let i = m.index;
  const n = src.length;
  let depth = 0, started = false, state = null, lastSig = '';
  for (; i < n; i++) {
    const c = src[i];
    switch (state) {
      case 'lc': if (c === '\n') state = null; continue;
      case 'bc': if (c === '*' && src[i + 1] === '/') { state = null; i++; } continue;
      case 'sq': if (c === '\\') { i++; continue; } if (c === "'") state = null; continue;
      case 'dq': if (c === '\\') { i++; continue; } if (c === '"') state = null; continue;
      case 'bt': if (c === '\\') { i++; continue; } if (c === '`') state = null; continue;
      case 're':
        if (c === '\\') { i++; continue; }
        if (c === '[') state = 'recls';
        else if (c === '/') state = null;
        continue;
      case 'recls':
        if (c === '\\') { i++; continue; }
        if (c === ']') state = 're';
        continue;
    }
    if (c === '/' && src[i + 1] === '/') { state = 'lc'; continue; }
    if (c === '/' && src[i + 1] === '*') { state = 'bc'; continue; }
    if (c === "'") { state = 'sq'; lastSig = c; continue; }
    if (c === '"') { state = 'dq'; lastSig = c; continue; }
    if (c === '`') { state = 'bt'; lastSig = c; continue; }
    if (c === '/') {
      // regex literal only where a value is expected; elsewhere it is division
      if (/[A-Za-z0-9_$)\]]/.test(lastSig)) { lastSig = c; continue; }
      state = 're'; lastSig = c; continue;
    }
    if (c === '{') { depth++; started = true; lastSig = c; continue; }
    if (c === '}') {
      depth--; lastSig = c;
      if (started && depth === 0) return src.slice(m.index, i + 1);
      continue;
    }
    if (!/\s/.test(c)) lastSig = c;
  }
  throw new Error('unbalanced braces extracting ' + name);
}

const srcText = fs.readFileSync(SRC_PATH, 'utf8');
const snippets = FN_NAMES.map((name) => {
  const snip = extractFunction(srcText, name);
  // every snippet must parse standalone; guards brace-matcher correctness
  try { new Function(snip); } catch (e) {
    throw new Error('extracted snippet for ' + name + ' does not parse: ' + e.message);
  }
  if (!snip.startsWith('function ' + name)) {
    throw new Error('extracted snippet for ' + name + ' has wrong anchor text');
  }
  return snip;
});

// ---------------------------------------------------------------------------
// Sandbox: stubs for every collaborator the extracted functions call.
// meterGreyTargetLuminanceForChartPoint is deliberately LEFT UNDEFINED so the
// extraction exercises the real fallback branch (`meterGreyTargetLuminance`),
// which is what a null-returning stub cannot do: rgbBalancePerceptual calls
// it unconditionally with no null check.
// ---------------------------------------------------------------------------
const STUBS = String.raw`
const BT709_XYZ2RGB = [
  [ 3.24096994, -1.53738318, -0.49861076],
  [-0.96924364,  1.87596750,  0.04155506],
  [ 0.05563008, -0.20397697,  1.05697156],
];
// getElementById routes by id: __sel drives meterRgbBalanceFormula,
// __noiseFloor drives the operator-selectable meterRgbBalanceNoiseFloor select.
// Restate the module-level noise-history consts the extracted history
// functions close over (source: webui-app.js — keep all copies in lockstep).
// The let-store too: only functions are brace-extracted, so the module
// state must exist in the sandbox or record's try/catch swallows a
// ReferenceError and every empirical floor silently reads null.
const METER_NOISE_HISTORY_K = 2;
const METER_NOISE_HISTORY_MAX = 12;
let meterNoiseHistory = null;
// Floor-input elements get a label stub so meterUpdateNoiseFloorControlAvailability
// can toggle opacity/title on their closest('label').
const document = { getElementById: (id) => {
  if (id === 'meterNoiseFloorMode') {
    return (typeof globalThis.__noiseMode !== 'undefined' && globalThis.__noiseMode) || null;
  }
  if (id === 'meterRgbBalanceNoiseFloor') {
    const el = (typeof globalThis.__noiseFloor !== 'undefined' && globalThis.__noiseFloor) || null;
    if (el && !el.closest) el.closest = () => globalThis.__noiseLabel;
    return el;
  }
  if (id === 'meterRgbBalanceNoiseFloorClear') {
    return (typeof globalThis.__noiseClear !== 'undefined' && globalThis.__noiseClear) || null;
  }
  if (id === 'meterRgbBalanceNoiseFloorHint') {
    return (typeof globalThis.__noiseHint !== 'undefined' && globalThis.__noiseHint) || null;
  }
  return (typeof globalThis.__sel !== 'undefined' && globalThis.__sel) || null;
} , querySelectorAll: (sel) => {
  if (sel === '.noise-floor-preset') return globalThis.__presetBtns || [];
  return [];
} };
globalThis.__noiseLabel = { style: {}, title: 'Perceptual noise floor tooltip: shadow gain applies.', dataset: {} };
// meterNoiseFloorMode routes to __noiseMode (flat <-> empirical select);
// it must NOT fall through to __sel, or a formula stub value would parse as
// a mode. The source-level noise-history constants are NOT brace-extracted
// with the functions (they are module-level consts), so they are restated in
// STUBS for the sandbox AND mirrored in test scope below; if the source
// values change, all three must change together.
// Collaborators of meterRecordReadingNoise: greyscale/real-measurement gates
// default ON (tests flip them), meterLiveRgbData returns __liveBal verbatim.
globalThis.__recIsGrey = true;
globalThis.__recIsReal = true;
function meterReadingIsGreyscale() { return globalThis.__recIsGrey; }
function meterReadingIsRealMeasurement() { return globalThis.__recIsReal; }
function meterLiveRgbData(rd) { return globalThis.__liveBal || null; }
function meterStepNameKey(step) { return (step && (step.name || (step.ire != null ? step.ire + '' : ''))) || ''; }
// The real meterOnRgbBalanceNoiseFloorChange (extracted below) delegates its
// redraw to the shared formula-change path; stub that and count invocations
// on globalThis so the test scope can read them.
globalThis.__noiseChangeCalls = 0;
function meterOnRgbBalanceFormulaChange() { globalThis.__noiseChangeCalls++; }
function meterGreyDeltaResult() { return { value: null }; }
function meterGreyRefMode() { return 'relative'; }
function meterDeltaEForm() { return 'deitp'; }
function meterGrayWorldWeight() { return null; }
function meterReadingXYZ(rd) { return rd ? { X: rd.X, Y: rd.Y, Z: rd.Z } : null; }
function meterResolveGreyRefMode(m) { return m || 'relative'; }
function meterTargetWhitePoint() { return { X: 0.9505, Y: 1.0, Z: 1.0890 }; } // D65-ish, matches app default
function meterGreyTargetPeak(whiteY) { return whiteY; }
function meterBlackReadingY() { return 0; }
function meterGreyTargetLuminance(ire, Lw, Lb, code) {
  return Lw * Math.pow(Math.max(0, Math.min(1, ire / 100)), 2.2); // fixed gamma 2.2; relative mode rescales target to measured Y, eotf tests assert against this same stub
}
function meterReadingIsPeakHeadroom(rd) { return false; }
function meterAnalysisGamut() { return { xyzToRgb: BT709_XYZ2RGB }; }
function xyzToLinRgb(X, Y, Z, M) { return M.map((r) => r[0] * X + r[1] * Y + r[2] * Z); }
function meterGreyscaleTargetSlotIre(rd) { return (rd && rd.target_ire != null) ? rd.target_ire : (rd && rd.ire); }
function meterChartIsDv() { return false; }
function meterChartIsHdr() { return false; }
let __gamutKey = 'bt709';
function meterActiveGamutKey() { return __gamutKey; }
// Plot-identity builder reads the generation through its cross-file accessor;
// stub it as a settable counter so tests can pin monotonicity semantics too.
globalThis.__generation = 0;
function meterReadingsGenerationValue() { return globalThis.__generation; }
function setGamutKey(g) { const prev = __gamutKey; __gamutKey = g; return prev; }
`;

const sandboxFactory = new Function(
  STUBS + '\n' + snippets.join('\n') + "\n return {" + FN_NAMES.join(', ') + ", setGamutKey};"
);
const S = sandboxFactory();

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------
let passed = 0, failed = 0;
// Test-scope mirror of the sandbox/source noise-history constants (see STUBS).
const METER_NOISE_HISTORY_K = 2;
const results = [];
function test(name, fn) {
  try {
    fn();
    passed++;
    results.push({ name: name, ok: true, msg: '' });
  } catch (e) {
    failed++;
    results.push({ name: name, ok: false, msg: (e && e.message) || String(e) });
  }
}
function assertClose(actual, expected, tol, what) {
  if (!(Math.abs(actual - expected) <= tol)) {
    throw new Error((what || 'value') + ': got ' + actual + ', expected ' + expected + ' ±' + tol);
  }
}
function assert(cond, what) {
  if (!cond) throw new Error(what || 'assertion failed');
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------
const WHITE_Y = 200;
// Neutral in the stub's meterTargetWhitePoint ratios (X/Y=0.9505, Z/Y=1.0890):
// perceptual/absolute targets are built from meterTargetWhitePoint(), so this
// is the exactly-balanced measured chromaticity for those modes.
function neutralWP(ire) {
  const Y = WHITE_Y * Math.pow(ire / 100, 2.2);
  return { ire: ire, X: 0.9505 * Y, Y: Y, Z: 1.0890 * Y };
}
const WHITE_REF = { ire: 100, X: 0.9505 * WHITE_Y, Y: WHITE_Y, Z: 1.0890 * WHITE_Y };
// Exact CIE D65 chromaticity (x=0.3127, y=0.3290): the exactly-balanced
// chromaticity for the HCFR unit-Y path under the BT.709 matrix.
function neutralD65(ire) {
  const Y = WHITE_Y * Math.pow(ire / 100, 2.2);
  const x = 0.3127, y = 0.3290;
  return { ire: ire, X: (x / y) * Y, Y: Y, Z: ((1 - x - y) / y) * Y };
}
function setFormula(v) { globalThis.__sel = v; } // v may be null/undefined or {value:...}

const IRE_POINTS = [100, 90, 70, 50, 30, 10, 5];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test('gain_at_100ire_is_1', () => {
  assert(S.meterPerceptualRgbBalanceGain({ ire: 100 }) === 1, 'gain(100) must be exactly 1');
  assert(S.meterPerceptualRgbBalanceGain({ ire: 120 }) === 1, 'gain(120) clamps to 1');
});

test('gain_capped_at_20', () => {
  assert(S.meterPerceptualRgbBalanceGain({ ire: 0 }) === 20, 'gain(0) must be exactly 20');
  assert(S.meterPerceptualRgbBalanceGain({ ire: -5 }) === 20, 'gain(-5) must be exactly 20');
});

test('gain_monotonic_decreasing', () => {
  const pts = [100, 90, 70, 50, 30, 10, 0];
  const gains = pts.map((ire) => S.meterPerceptualRgbBalanceGain({ ire: ire }));
  for (let i = 1; i < gains.length; i++) {
    assert(gains[i - 1] <= gains[i], 'gain must be non-increasing as IRE decreases: ' + gains.join(','));
  }
  assertClose(gains[4], 1 + 19 * Math.pow(0.7, 4), 1e-9, 'gain(30)');
});

test('balanced_neutral_stays_100_perceptual', () => {
  // Invariant: a perfectly balanced channel is exactly 100 at every IRE,
  // regardless of shadow gain (deviation 0 * gain stays 0).
  for (const ire of IRE_POINTS) {
    const rd = neutralWP(ire);
    setFormula({ value: 'perceptual' });
    const p = S.rgbBalance(rd, WHITE_REF, 'relative', null);
    setFormula({ value: 'absolute' });
    const a = S.rgbBalance(rd, WHITE_REF, 'relative', null);
    for (const [tag, res] of [['perceptual', p], ['absolute', a]]) {
      for (const ch of ['R', 'G', 'B']) {
        assertClose(res[ch], 100, 1e-6, 'ire=' + ire + ' ' + tag + '.' + ch);
      }
    }
  }
});

test('deviation_scales_with_gain_perceptual_vs_absolute', () => {
  // Red-heavy neutral: measured X lifted 2% -> nonzero deviation at low IRE.
  const ire = 10;
  const base = neutralWP(ire);
  const rd = { ire: ire, X: base.X * 1.02, Y: base.Y, Z: base.Z };
  setFormula({ value: 'absolute' });
  const abs = S.rgbBalance(rd, WHITE_REF, 'relative', null);
  setFormula({ value: 'perceptual' });
  const per = S.rgbBalance(rd, WHITE_REF, 'relative', null);
  const gain = S.meterPerceptualRgbBalanceGain(rd); // 1+19*0.9^4 = 13.4659
  assert(Math.abs(abs.R - 100) > 0.05, 'fixture must produce a measurable R deviation, got ' + abs.R);
  for (const ch of ['R', 'G', 'B']) {
    const ratio = (per[ch] - 100) / (abs[ch] - 100);
    assert(Math.abs(ratio / gain - 1) < 1e-9, ch + ': perceptual/absolute deviation ratio ' + ratio + ' != gain ' + gain);
  }
  // absolute dispatch IS rgbBalanceAbsolute: identical results
  const direct = S.rgbBalanceAbsolute(rd, WHITE_REF, 'relative', null);
  assert(JSON.stringify(abs) === JSON.stringify(direct), 'absolute dispatch must equal rgbBalanceAbsolute exactly');
});

test('hcfr_formula_dispatch_differs', () => {
  setFormula({ value: 'hcfr' });
  const rd = neutralD65(50);
  const res = S.rgbBalance(rd, WHITE_REF, 'relative', null);
  for (const ch of ['R', 'G', 'B']) {
    assert(Number.isFinite(res[ch]), 'hcfr ' + ch + ' must be finite, got ' + res[ch]);
    // unit-Y math on exact-D65 neutral is 100 up to BT.709 matrix normalization
    // (residual ~4e-6 on B because the stub white point differs from exact D65
    // by ~5e-5; tolerance widened from 1e-6 for that reason)
    assertClose(res[ch], 100, 1e-4, 'hcfr.' + ch);
  }
  // hcfr must be a genuinely different code path: on the WP-ratio neutral
  // (not exact D65) it does NOT land on exactly 100, unlike perceptual.
  const wpNeutral = S.rgbBalance(neutralWP(50), WHITE_REF, 'relative', null);
  const maxDev = Math.max(
    Math.abs(wpNeutral.R - 100), Math.abs(wpNeutral.G - 100), Math.abs(wpNeutral.B - 100));
  assert(maxDev > 1e-3, 'hcfr on WP-ratio neutral should deviate measurably from 100 (dev=' + maxDev + ')');
});

test('noChroma_at_zero_Y', () => {
  const rd = { ire: 50, X: 0, Y: 0, Z: 0 };
  for (const f of ['perceptual', 'absolute', 'hcfr']) {
    setFormula({ value: f });
    const res = S.rgbBalance(rd, WHITE_REF, 'relative', null);
    assert(res.noChroma === true, f + ' must set noChroma===true on zero-Y, got ' + JSON.stringify(res));
    assert(res.R === 100 && res.G === 100 && res.B === 100, f + ' must report 100/100/100 with noChroma');
  }
});

test('eotf_mode_includes_luminance', () => {
  // Neutral at ire 50 but 10% dimmer than the stub gamma target.
  const ire = 50;
  const Y = WHITE_Y * Math.pow(ire / 100, 2.2) * 0.9;
  const rd = { ire: ire, X: 0.9505 * Y, Y: Y, Z: 1.0890 * Y };
  setFormula({ value: 'absolute' });
  const abs = S.rgbBalance(rd, WHITE_REF, 'eotf', null);
  setFormula({ value: 'perceptual' });
  const per = S.rgbBalance(rd, WHITE_REF, 'eotf', null);
  const gain = 1 + 19 * Math.pow(0.5, 4); // = 2.1875
  assertClose(gain, S.meterPerceptualRgbBalanceGain(rd), 1e-12, 'gain(50)');
  // In chroma-only mode the same reading reads as perfect 100s; eotf must not.
  for (const ch of ['R', 'G', 'B']) {
    assert(abs[ch] < 100, 'absolute eotf ' + ch + ' must be <100 for dim patch, got ' + abs[ch]);
    assert(per[ch] < 100, 'perceptual eotf ' + ch + ' must be <100 for dim patch, got ' + per[ch]);
    const ratio = (100 - per[ch]) / (100 - abs[ch]);
    assert(Math.abs(ratio / gain - 1) < 1e-9, ch + ': eotf deviation ratio ' + ratio + ' != gain ' + gain);
  }
  // All three channels move near-equally on a chroma-neutral dim patch. NOT
  // bit-identical: L* is not linear in linear-RGB, and the B primary sits near
  // the cube-root origin (linear ~0.04 at 50 IRE) where ynToLstar's slope is
  // ~1000x the G channel's, so equal-Y errors land within ~5e-5, not 1e-9.
  assertClose(abs.R, abs.G, 1e-3, 'abs.R vs abs.G (L* slope differs per channel)');
  assertClose(abs.G, abs.B, 1e-4, 'abs.G vs abs.B (L* nonlinearity near B primary)');
});

test('dispatcher_defaults', () => {
  // no <select> in the DOM -> meterRgbBalanceFormula falls back to 'absolute'
  const rd = { ire: 20, X: 0.97 * 0.9505 * WHITE_Y * Math.pow(0.2, 2.2), Y: WHITE_Y * Math.pow(0.2, 2.2), Z: 1.0890 * WHITE_Y * Math.pow(0.2, 2.2) };
  globalThis.__sel = null;
  assert(S.meterRgbBalanceFormula() === 'absolute', 'fallback formula must be absolute');
  const viaDispatch = S.rgbBalance(rd, WHITE_REF, 'relative', null);
  const direct = S.rgbBalanceAbsolute(rd, WHITE_REF, 'relative', null);
  assert(JSON.stringify(viaDispatch) === JSON.stringify(direct), 'null-select dispatch must equal rgbBalanceAbsolute exactly');
  // select present but empty value also falls back to 'absolute'
  globalThis.__sel = { value: '' };
  assert(S.meterRgbBalanceFormula() === 'absolute', 'empty select value must fall back to absolute');
});

test('negative_channel_lstar', () => {
  // Extreme reading: huge X, Z=0 -> negative linear G (and odd B) after BT.709.
  const rd = { ire: 50, X: 10.0, Y: 0.5, Z: 0 };
  for (const f of ['perceptual', 'absolute', 'hcfr']) {
    setFormula({ value: f });
    const res = S.rgbBalance(rd, WHITE_REF, 'relative', null);
    for (const ch of ['R', 'G', 'B']) {
      assert(Number.isFinite(res[ch]), f + ' ' + ch + ' must stay finite on extreme reading, got ' + res[ch]);
    }
  }
  // ynToLstar is odd-symmetric on negatives (no NaN below the a<=0 edge)
  const l = S.ynToLstar(-0.5);
  assert(Number.isFinite(l) && l < 0, 'ynToLstar(-0.5) must be finite and negative, got ' + l);
  assertClose(-l, S.ynToLstar(0.5), 1e-12, 'ynToLstar odd symmetry');
});

test('lstar_core_delegation', () => {
  // Naming structure: rgbBalanceLstar is the single core; the two L* wrappers
  // differ ONLY in the shadowWeighted flag. If either wrapper stops delegating
  // (or the gain argument flips), this fails and the deviation-ratio tests
  // above will tell you which one diverged.
  const ire = 10;
  const base = neutralWP(ire);
  const rd = { ire: ire, X: base.X * 1.02, Y: base.Y, Z: base.Z };
  const coreOff = S.rgbBalanceLstar(rd, WHITE_REF, 'relative', null, false);
  const coreOn  = S.rgbBalanceLstar(rd, WHITE_REF, 'relative', null, true);
  const abs = S.rgbBalanceAbsolute(rd, WHITE_REF, 'relative', null);
  const per = S.rgbBalancePerceptual(rd, WHITE_REF, 'relative', null);
  assert(JSON.stringify(abs) === JSON.stringify(coreOff), 'rgbBalanceAbsolute must delegate to core with shadowWeighted=false');
  assert(JSON.stringify(per) === JSON.stringify(coreOn), 'rgbBalancePerceptual must delegate to core with shadowWeighted=true');
});

test('plot_key_identity', () => {
  // The hover/plot cache key must change whenever ANY balance input changes,
  // not just the formula (the bug it exists to prevent).
  globalThis.__sel = { value: 'perceptual' };
  const k = (m, b, g) => S.meterRgbBalancePlotKey(m, b, g);
  const base = k('relative', 0.01, 7);
  assert(k('relative', 0.01, 7) === base, 'same inputs must produce the same key');
  assert(k('eotf', 0.01, 7) !== base, 'grey-ref mode must enter the key');
  assert(k('relative', 0.02, 7) !== base, 'black level must enter the key');
  assert(k('relative', 0.01, 8) !== base, 'readings generation must enter the key');
  globalThis.__sel = { value: 'absolute' };
  assert(k('relative', 0.01, 7) !== base, 'formula must enter the key');
  globalThis.__sel = { value: 'perceptual' };
  const prevGamut = S.setGamutKey('p3d65');
  assert(k('relative', 0.01, 7) !== base, 'analysis gamut must enter the key');
  S.setGamutKey(prevGamut);
  // PR-16 review: drawRGBChart may plot a caller-filtered `gs` while hover
  // re-derives from global meterReadings — same tuple, different whiteRef or
  // entry count must still not match. The key takes the whiteRef OBJECT
  // (identity assembled in exactly one place) and the identity builder is
  // the ONE assembly both plot-cache sites call.
  const w1 = { X: 0.95, Y: 1, Z: 1.089 }, w2 = { X: 0.9645, Y: 1.015, Z: 1.1054 };
  const k5 = (m, b, g, w, c) => S.meterRgbBalancePlotKey(m, b, g, w, c);
  const base5 = k5('relative', 0.01, 7, w1, 11);
  assert(k5('relative', 0.01, 7, w1, 11) === base5, 'same full inputs same key');
  assert(k5('relative', 0.01, 7, w2, 11) !== base5, 'white ref must enter the key');
  assert(k5('relative', 0.01, 7, w1, 8) !== base5, 'plot entry count must enter the key');
  assert(k5('relative', 0.01, 7, null, 11) === k5('relative', 0.01, 7, undefined, 11), 'null/undefined whiteRef agree');
  assert(S.meterRgbBalancePlotKey('relative', 0.01, 7) === k5('relative', 0.01, 7, null, null), 'legacy 3-arg call still deterministic');
  // Identity builder: distinct-IRE count (not reading count), so a
  // duplicate-IRE gs yields the same identity for the draw and hover sides.
  const gsA = [{ ire: 0 }, { ire: 50 }, { ire: 100 }, { ire: 100 }];
  const idA = S.meterRgbBalancePlotIdentity(gsA, 'relative', 0.01, w1);
  const idA2 = S.meterRgbBalancePlotIdentity([...gsA].reverse(), 'relative', 0.01, { X: 0.95, Y: 1, Z: 1.089 });
  assert(idA === idA2, 'identity stable across order and equal-but-distinct white objects');
  // The duplicate-IRE gs and the distinct-only list of the SAME IREs share
  // identity — that is what makes the draw side (balMap keyed by IRE) and
  // the hover side (iterating gs) compute the SAME key with duplicates.
  const idSameDistinct = S.meterRgbBalancePlotIdentity([{ ire: 0 }, { ire: 50 }, { ire: 100 }], 'relative', 0.01, w1);
  assert(idA === idSameDistinct, 'identity counts DISTINCT IREs — duplicate readings do not skew it');
  const idFewer = S.meterRgbBalancePlotIdentity([{ ire: 0 }, { ire: 100 }], 'relative', 0.01, w1);
  assert(idA !== idFewer, 'a genuinely smaller distinct-IRE set differs');
  assert(S.meterRgbBalancePlotIdentity(gsA, 'relative', 0.01, null) !== idA, 'null whiteRef identity differs from a real one');
  assert(typeof S.meterRgbBalanceActiveNoiseFloor === 'function', 'active-floor helper exists');
});

test('noise_floor_annotation', () => {
  // Operator-selectable floor: the html select drives meterRgbBalanceNoiseFloor,
  // so the html option values must parse as the positive numbers the code
  // expects, and the webui-app.js side must NOT hard-code a constant anymore.
  const html = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-body.html'), 'utf8');
  // Free-typed floor: an <input type="number">, not a <select>.
  const block = /<input[^>]*id="meterRgbBalanceNoiseFloor"[^>]*>/.exec(html);
  if (!block) throw new Error('meterRgbBalanceNoiseFloor input missing from webui-body.html');
  if (/<select[^>]*id="meterRgbBalanceNoiseFloor"/.test(html)) throw new Error('floor control regressed to a select; it must be free-typable');
  assert(/type="number"/.test(block[0]), 'floor input must be type=number');
  assert(/min="0"/.test(block[0]), 'floor input min must be 0');
  // Preset affordance: real preset buttons (NOT a datalist — iOS/Android
  // number inputs ignore datalists, and the desktop arrow was deliberately
  // removed in 07df0e2c, so a datalist preset is unreachable on touch).
  if (/id="meterRgbBalanceNoiseFloor"[^>]*\blist=/.test(html.replace(/\s+/g,' '))) throw new Error('floor input re-wired to a datalist; presets must be buttons');
  const presetBtns = [...html.matchAll(/<button[^>]*class="noise-floor-preset"[^>]*>/g)].map((m) => m[0]);
  assert(presetBtns.length >= 2, 'need >=2 preset buttons, got ' + presetBtns.length);
  assert(presetBtns.every((b) => /onclick="meterApplyNoiseFloorPreset\('[0-9.]+'\)/.test(b)), 'each preset button must apply its value via meterApplyNoiseFloorPreset');
  assert(presetBtns.every((b) => /aria-label=/.test(b)), 'preset buttons need accessible names');
  // PR-16 review: oninput must NOT persist per keystroke — type=number
  // reports '' for partial input ('0.', ''), so a mid-typing save persists
  // junk/Off and a reload during typing loses the value. Persistence lives on
  // change/blur; oninput only refreshes the availability visuals.
  assert(!/oninput="[^"]*meterSaveColorPrefs\(\)/.test(block[0]), 'oninput must not write localStorage per keystroke');
  assert(/oninput="[^"]*meterUpdateNoiseFloorControlAvailability\(\)/.test(block[0]), 'oninput must keep the live availability update');
  assert(/aria-label=/.test(block[0]), 'floor input needs an aria-label');
  const F = 0.3; // typical colorimeter repeatability; value is operator-typed
  // The source must read the select, not a fixed constant.
  if (/const METER_RGB_BALANCE_NOISE_FLOOR\s*=/.test(srcText)) throw new Error('webui-app.js still hard-codes the noise floor constant');
  // Off: WithinNoise never fires regardless of deviation size.
  globalThis.__noiseFloor = null;
  assert(S.meterRgbBalanceWithinNoise(100.0, 13.47) === false, 'Off must disable the annotation even at zero deviation');
  globalThis.__noiseFloor = { value: '', style: {} };
  assert(S.meterRgbBalanceWithinNoise(100.0, 1) === false, 'empty select value = Off');
  // Floor at F: inside/at boundary true, above false, sign-symmetric.
  globalThis.__noiseFloor = { value: String(F) };
  assert(S.meterRgbBalanceWithinNoise(100 + F / 2, 1) === true, 'inside floor');
  assert(S.meterRgbBalanceWithinNoise(100 + F, 1) === true, 'exactly at floor is within noise');
  assert(S.meterRgbBalanceWithinNoise(100 + F + 1e-9, 1) === false, 'just above floor is not');
  assert(S.meterRgbBalanceWithinNoise(100 - 2 * F, 1) === false, '-2F ungained exceeds floor (sign-symmetric)');
  // gain must be divided out: gain 3.0, plotted 0.8 pts => pre-gain 0.267.
  const expectWithin = (0.8 / 3) <= F; // pre-gain deviation vs floor
  assert(S.meterRgbBalanceWithinNoise(100.8, 3.0) === expectWithin, 'gain must be divided out (pre-gain ' + (0.8 / 3).toFixed(3) + ' vs floor ' + F + ', expected ' + expectWithin + ')');
  assert(S.meterRgbBalanceWithinNoise(NaN, 3.0) === false, 'NaN never within noise');
  // A larger typed floor widens the band: midway deviation flips to within.
  const F2 = F * 2;
  globalThis.__noiseFloor = { value: String(F2) };
  assert(S.meterRgbBalanceWithinNoise(100 + (F + F2) / 2, 1) === true, 'midway deviation within the larger floor ' + F2);
  // Garbage/negative/zero typed values resolve to Off, never a negative floor.
  for (const junk of ['abc', '-0.5', '0']) {
    globalThis.__noiseFloor = { value: junk };
    assert(S.meterRgbBalanceWithinNoise(100.0, 1) === false, 'typed "' + junk + '" must behave as Off');
  }
  // Out-of-range values are capped at the control's declared max (10), not
  // honored literally — a restored pref cannot scale the annotation envelope
  // to absurd size. Capping applies through the floor getter itself.
  globalThis.__noiseFloor = { value: '25', style: {} };
  assert(S.meterRgbBalanceNoiseFloor() === 10, 'floor above control max must cap at 10');
  assert(S.meterRgbBalanceWithinNoise(100 + 10, 1) === true, 'capped floor still annotates');
  assert(S.meterRgbBalanceWithinNoise(100 + 11, 1) === false, 'above capped floor stays bright');
  globalThis.__noiseFloor = { value: '3', style: {} };
  assert(S.meterRgbBalanceNoiseFloor() === 3, 'in-range floor passes through unchanged');
  // Sub-0.01 floors are below meter repeatability and render an invisible
  // band (and String() would print '1e-7'): resolve to Off, both in the
  // getter and in the commit-time field rewrite.
  globalThis.__noiseFloor = { value: '0.005', style: {} };
  assert(S.meterRgbBalanceNoiseFloor() === 0, 'sub-0.01 floor resolves to Off');
  S.meterCommitRgbBalanceNoiseFloorInput();
  assert(globalThis.__noiseFloor.value === '', 'sub-0.01 commit blanks the field');
  globalThis.__noiseFloor = { value: '0.05', style: {} };
  assert(S.meterRgbBalanceNoiseFloor() === 0.05, '0.05 (the step size) stays on');
  S.meterCommitRgbBalanceNoiseFloorInput();
  assert(globalThis.__noiseFloor.value === '0.05', '0.05 commits unchanged');
  globalThis.__noiseFloor = { value: '3', style: {} };
  globalThis.__noiseFloor = null;
});

test('noise_floor_applies_only_to_perceptual', () => {
  // The floor divides out the shadow gain, which only the Perceptual formula
  // applies; the affordance must report itself inactive elsewhere.
  setFormula({ value: 'absolute' });
  assert(S.meterRgbBalanceNoiseFloorApplies() === false, 'absolute: floor must report not applicable');
  setFormula({ value: 'hcfr' });
  assert(S.meterRgbBalanceNoiseFloorApplies() === false, 'hcfr: floor must report not applicable');
  setFormula({ value: 'perceptual' });
  assert(S.meterRgbBalanceNoiseFloorApplies() === true, 'perceptual: floor must report applicable');
  setFormula(null); // missing select -> 'absolute' default
  assert(S.meterRgbBalanceNoiseFloorApplies() === false, 'default formula: not applicable');
});

// The active-state tooltip is authored in webui-body.html and cached by the
// availability function on first run (single-source copy). Harness label
// stubs carry an authored title, as every real page does.
const AUTHORED_TITLE = 'Perceptual noise floor tooltip: shadow gain applies.';
function noiseLabelStub() { return { style: {}, title: AUTHORED_TITLE, dataset: {} }; }
test('noise_floor_control_availability_dims_label', () => {
 // meterUpdateNoiseFloorControlAvailability toggles opacity/title and must
 // never throw when the input does not exist yet. Dimming targets the INPUT
 // and presets, never the label: the inactive hint lives inside the label and
 // opacity inherits multiplicatively, so a label-level 0.45 would dim the
 // affordance that explains the dim (PR-16 review finding).
 globalThis.__noiseFloor = null;
 S.meterUpdateNoiseFloorControlAvailability(); // element missing = no-op
 globalThis.__noiseFloor = { value: '0.3', style: {} };
 globalThis.__noiseLabel = { style: {}, title: 'Perceptual noise floor tooltip: shadow gain applies.', dataset: {} };
 setFormula({ value: 'perceptual' });
 S.meterUpdateNoiseFloorControlAvailability();
 assert(globalThis.__noiseLabel.style.opacity === '', 'perceptual: label must stay full opacity');
 assert(globalThis.__noiseFloor.style.opacity === '', 'perceptual: input must stay full opacity');
 assert(/shadow gain/.test(globalThis.__noiseLabel.title), 'perceptual: tooltip explains the annotation');
 setFormula({ value: 'absolute' });
 S.meterUpdateNoiseFloorControlAvailability();
 assert(globalThis.__noiseLabel.style.opacity === '', 'absolute: label must NEVER dim (hint lives inside it and cannot undo an inherited dim)');
 assert(globalThis.__noiseFloor.style.opacity === '0.45', 'absolute: input itself must dim');
 assert(/Perceptual/.test(globalThis.__noiseLabel.title), 'absolute: tooltip must say how to activate');
 globalThis.__noiseFloor = null;
});

test('noise_floor_clear_button', () => {
  // The × button appears only when a floor is on, and clearing goes back to
  // Off through the same redraw path an operator edit would take.
  const html = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-body.html'), 'utf8');
  const btn = /<button[^>]*id="meterRgbBalanceNoiseFloorClear"[^>]*>/.exec(html);
  if (!btn) throw new Error('clear button missing from webui-body.html');
  assert(/onclick="meterOnRgbBalanceNoiseFloorClear\(\)"/.test(btn[0]), 'clear button must invoke the clear handler');
  assert(/display:none/.test(btn[0]), 'clear button must start hidden (floor defaults to Off)');
  assert(/aria-label=/.test(btn[0]), 'clear button needs an accessible name');
  setFormula({ value: 'perceptual' });
  // Floor on: availability update must reveal the button.
  const clear = { style: {} };
  globalThis.__noiseClear = clear;
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  globalThis.__noiseLabel = { style: {}, title: 'Perceptual noise floor tooltip: shadow gain applies.', dataset: {} };
  S.meterUpdateNoiseFloorControlAvailability();
  assert(clear.style.display === '', 'floor on: clear button must be visible');
  // Floor off (empty): button hidden again.
  globalThis.__noiseFloor = { value: '', style: {} };
  S.meterUpdateNoiseFloorControlAvailability();
  assert(clear.style.display === 'none', 'floor off: clear button must hide');
  // The handler clears the input and triggers the shared redraw exactly once.
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  const before = __noiseChangeCalls;
  S.meterOnRgbBalanceNoiseFloorClear();
  assert(globalThis.__noiseFloor.value === '', 'clear must empty the input value');
  assert(__noiseChangeCalls === before + 1, 'clear must trigger the redraw path once');
  // Missing input: no-op, no redraw, no throw.
  globalThis.__noiseFloor = null;
  const before2 = __noiseChangeCalls;
  S.meterOnRgbBalanceNoiseFloorClear();
  assert(__noiseChangeCalls === before2, 'missing input: clear must be a no-op');
  globalThis.__noiseClear = null;
  globalThis.__noiseFloor = null;
});

test('live_deltas_carry_noise_flags', () => {
  // meterRgbDeltasForLive forwards the per-channel bal.noise flags (from
  // meterLiveRgbData) so the live bar renderer can dim noise-level bars.
  const spec = S.meterRgbDeltasForLive(null, { mode: 'balance', R: 100.1, G: 102, B: 99.9, noise: [true, false, true] });
  assert(spec.entries[0].noise === true, 'R flagged within noise must carry through');
  assert(spec.entries[1].noise === false, 'G above noise stays bright');
  assert(spec.entries[2].noise === true, 'B flagged within noise must carry through');
  // No noise array (floor off / non-perceptual): every entry bright, no crash.
  const plain = S.meterRgbDeltasForLive(null, { mode: 'balance', R: 100.1, G: 102, B: 99.9 });
  assert(plain.entries.every((e) => e.noise === false), 'missing bal.noise => all bright');
  // Delta-mode (color-series) balances never get flags attached upstream.
  const dm = S.meterRgbDeltasForLive(null, { mode: 'delta', R: 0.05, G: 0, B: -0.05 });
  assert(dm.entries.every((e) => e.noise === false), 'delta mode entries stay bright');
});

test('offscale_direction_under_view', () => {
  // The box-zoom bug this pins: comparing to plain 0/1 missed values inside
  // the axis range but outside the zoomed view window [vLo,vHi].
  const d = S.meterRgbBalanceOffScaleDir;
  assert(d(0.5, 0, 1) === 0, 'inside full axis is inside');
  assert(d(-0.1, 0, 1) === -1, 'below axis is -1');
  assert(d(1.2, 0, 1) === 1, 'above axis is +1');
  // Zoomed view covering only [0.4,0.6]: 0.2 is inside the AXIS but below the
  // VIEW — the case the pre-fix comparison scored as 0 (inside) and never
  // flagged, so no marker appeared under a vertical box-zoom.
  assert(d(0.2, 0.4, 0.6) === -1, 'inside axis but below zoomed view must flag -1');
  assert(d(0.9, 0.4, 0.6) === 1, 'inside axis but above zoomed view must flag +1');
  assert(d(0.5, 0.4, 0.6) === 0, 'inside the zoomed view is inside');
  assert(d(NaN, 0, 1) === 0, 'NaN never flagged');
  // Missing window bounds fall back to the full [0,1] axis.
  assert(d(1.5, undefined, undefined) === 1, 'missing bounds default to full axis');
});

test('noise_floor_input_commits_to_applied_value', () => {
  // The effective floor caps at 10 and resolves garbage to Off; the field must
  // never display a number that differs from the applied annotation.
  const commit = S.meterCommitRgbBalanceNoiseFloorInput;
  setFormula({ value: 'perceptual' });
  const cases = [
    ['20', '10', 'over-cap rewrites to the cap'],
    ['0.500', '0.5', 'trailing zeros normalize'],
    ['  0.3 ', '0.3', 'surrounding spaces trim'],
    ['-1', '', 'negative resolves to Off'],
    ['abc', '', 'non-numeric resolves to Off'],
    ['0', '', 'zero resolves to Off'],
    ['0.2', '0.2', 'valid value untouched'],
    ['10', '10', 'cap boundary untouched'],
    ['', '', 'empty stays empty'],
  ];
  for (const [input, expected, what] of cases) {
    globalThis.__noiseFloor = { value: input };
    commit();
    assert(globalThis.__noiseFloor.value === expected,
      what + ': got ' + JSON.stringify(globalThis.__noiseFloor.value) + ', expected ' + JSON.stringify(expected));
    // The committed field value must agree with what the annotation reads.
    const applied = S.meterRgbBalanceNoiseFloor();
    if (expected === '') assert(applied === 0, what + ': annotation must be Off when field is Off');
    else assertClose(applied, Number(expected), 1e-9, what + ': annotation matches field');
  }
  // Missing input: no-op, no throw.
  globalThis.__noiseFloor = null;
  commit();
});

test('noise_floor_change_handler_commits_before_redraw', () => {
  // The change handler normalizes the field before triggering the shared
  // redraw, so a preset pick or Enter can never redraw with a stale value.
  globalThis.__noiseFloor = { value: '25', style: {}, closest: () => globalThis.__noiseLabel };
  globalThis.__noiseLabel = { style: {}, title: 'Perceptual noise floor tooltip: shadow gain applies.', dataset: {} };
  const before = __noiseChangeCalls;
  S.meterOnRgbBalanceNoiseFloorChange();
  assert(globalThis.__noiseFloor.value === '10', 'change handler rewrites over-cap before redraw');
  assert(__noiseChangeCalls === before + 1, 'change handler still triggers the shared redraw once');
  globalThis.__noiseFloor = null;
});

test('noise_floor_blur_commit_is_wired_in_html', () => {
  const html = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-body.html'), 'utf8');
  const input = /<input[^>]*id="meterRgbBalanceNoiseFloor"[^>]*>/.exec(html);
  if (!input) throw new Error('noise floor input missing from webui-body.html');
  assert(/onblur="meterCommitRgbBalanceNoiseFloorInput\(\)/.test(input[0]), 'blur must commit the field');
  assert(/meterSaveColorPrefs\(\)/.test(/onblur="([^"]*)"/.exec(input[0])[1]), 'blur must re-persist after commit');
});

test('noise_floor_inactive_hint_offers_one_tap_perceptual_switch', () => {
  // Floor set while formula is Absolute: an inline hint must appear (touch
  // screens never hover the dimmed label). Perceptual or floor Off: hidden.
  const hint = { style: {} };
  globalThis.__noiseHint = hint;
  globalThis.__noiseLabel = { style: {}, title: 'Perceptual noise floor tooltip: shadow gain applies.', dataset: {} };
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  setFormula({ value: 'absolute' });
  S.meterUpdateNoiseFloorControlAvailability();
  assert(hint.style.display === '', 'floor on + absolute: hint visible');
  setFormula({ value: 'perceptual' });
  S.meterUpdateNoiseFloorControlAvailability();
  assert(hint.style.display === 'none', 'perceptual: hint hidden');
  setFormula({ value: 'absolute' });
  globalThis.__noiseFloor = { value: '', style: {} };
  S.meterUpdateNoiseFloorControlAvailability();
  assert(hint.style.display === 'none', 'floor off: hint hidden');
  // One-tap switch: selects Perceptual on the picker, keeps the floor value,
  // and runs the shared formula-change redraw path exactly once.
  const sel = { value: 'absolute' };
  globalThis.__sel = sel;
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  const before = __noiseChangeCalls;
  S.meterSwitchToPerceptualRgbBalance();
  assert(sel.value === 'perceptual', 'switch sets the formula picker');
  assert(globalThis.__noiseFloor.value === '0.5', 'switch keeps the floor value');
  assert(__noiseChangeCalls === before + 1, 'switch triggers the shared redraw once');
  assert(S.meterRgbBalanceNoiseFloorApplies() === true, 'after switch the floor applies');
  // Missing picker: still runs the redraw path, no throw.
  globalThis.__sel = null;
  S.meterSwitchToPerceptualRgbBalance();
  assert(__noiseChangeCalls === before + 2, 'missing picker: redraw still fires');
  globalThis.__noiseHint = null;
});

test('noise_floor_inactive_hint_is_wired_in_html', () => {
  const html = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-body.html'), 'utf8');
  const btn = /<button[^>]*id="meterRgbBalanceNoiseFloorHint"[^>]*>/.exec(html);
  if (!btn) throw new Error('inactive-hint button missing from webui-body.html');
  assert(/onclick="meterSwitchToPerceptualRgbBalance\(\)"/.test(btn[0]), 'hint must invoke the switch handler');
  assert(/display:none/.test(btn[0]), 'hint must start hidden');
  assert(/aria-label=/.test(btn[0]), 'hint needs an accessible name');
  // Theme token, not a hard-coded hex: the light theme's --orange (#a55300)
  // stays legible on white; a fixed amber would wash out.
  assert(/color:var\(--orange/.test(btn[0]), 'hint color must use the themed --orange token');
});

test('preset_button_applies_through_commit_path', () => {
  // A preset tap writes the field and runs the shared change path (which
  // commit-normalizes first), so the field can never disagree with the
  // annotation the tap draws.
  globalThis.__noiseFloor = { value: '', style: {} };
  const before = __noiseChangeCalls;
  S.meterApplyNoiseFloorPreset('0.5');
  assert(globalThis.__noiseFloor.value === '0.5', 'preset writes the field');
  assert(__noiseChangeCalls === before + 1, 'preset triggers the redraw path once');
  assertClose(S.meterRgbBalanceNoiseFloor(), 0.5, 1e-9, 'annotation reads the preset value');
  // Missing input: no-op, no throw, no redraw.
  globalThis.__noiseFloor = null;
  S.meterApplyNoiseFloorPreset('0.5');
  assert(__noiseChangeCalls === before + 1, 'missing input: preset tap is a no-op');
});

test('tapping_active_preset_turns_floor_off', () => {
  // aria-pressed advertises a toggle; the control must release too. Tapping
  // the active preset clears the field through the same commit path.
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  const before = __noiseChangeCalls;
  S.meterApplyNoiseFloorPreset('0.5');
  assert(globalThis.__noiseFloor.value === '', 'active preset tap turns Off');
  assert(__noiseChangeCalls === before + 1, 'Off tap redraws once');
  assert(S.meterRgbBalanceNoiseFloor() === 0, 'annotation Off after toggle');
  // A different preset still switches (not a toggle-off).
  S.meterApplyNoiseFloorPreset('1');
  assert(globalThis.__noiseFloor.value === '1', 'other preset applies from an active preset');
  // Numeric equality: typed '1.0' vs preset '1' toggles Off too.
  globalThis.__noiseFloor = { value: '1.0', style: {} };
  S.meterApplyNoiseFloorPreset('1');
  assert(globalThis.__noiseFloor.value === '', '1.0 == 1 toggles Off');
  // Tapping while Off re-applies (not stuck).
  S.meterApplyNoiseFloorPreset('1');
  assert(globalThis.__noiseFloor.value === '1', 'tap from Off re-applies');
});

function fakePresetBtn(value) {
  return { dataset: { value }, style: {}, _pressed: null, setAttribute(k, v) { if (k === 'aria-pressed') this._pressed = v; } };
}

test('active_preset_is_highlighted_and_aria_pressed', () => {
  globalThis.__noiseLabel = { style: {}, title: 'Perceptual noise floor tooltip: shadow gain applies.', dataset: {} };
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  const b2 = fakePresetBtn('0.2'), b5 = fakePresetBtn('0.5'), b1 = fakePresetBtn('1');
  globalThis.__presetBtns = [b2, b5, b1];
  setFormula({ value: 'perceptual' });
  // Floor equals a preset: exactly that button lights; the others reset.
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  S.meterUpdateNoiseFloorControlAvailability();
  assert(b5.style.borderColor === 'var(--accent,#5b7fff)', 'matching preset gets accent border');
  assert(b5._pressed === 'true', 'matching preset aria-pressed=true');
  assert(b2.style.borderColor === '' && b2._pressed === 'false', 'non-matching preset stays neutral');
  // Typed value matching no preset: nothing highlighted (also information).
  globalThis.__noiseFloor = { value: '0.35', style: {} };
  S.meterUpdateNoiseFloorControlAvailability();
  assert([b2, b5, b1].every((b) => b.style.borderColor === '' && b._pressed === 'false'), 'unmatched typed value highlights none');
  // Floor Off: everything resets, including a previously lit button.
  globalThis.__noiseFloor = { value: '', style: {} };
  S.meterUpdateNoiseFloorControlAvailability();
  assert(b5.style.borderColor === '' && b5._pressed === 'false', 'Off resets the lit preset');
  // No preset row in the DOM (early call): must not throw.
  globalThis.__presetBtns = [];
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  S.meterUpdateNoiseFloorControlAvailability();
  globalThis.__presetBtns = null;
  S.meterUpdateNoiseFloorControlAvailability();
  globalThis.__noiseFloor = null;
});

test('inactive_formula_dims_input_and_presets_not_the_hint', () => {
  // PR-16 review: the amber hint lives inside the control label; dimming the
  // label dimmed the hint below legibility exactly when it is the only
  // on-screen explanation. The dim must land on the input and the preset
  // buttons; the hint and its container stay full opacity.
  const hint = { style: {} };
  globalThis.__noiseHint = hint;
  const b2 = fakePresetBtn('0.2');
  globalThis.__presetBtns = [b2];
  globalThis.__noiseLabel = { style: {}, title: 'Perceptual noise floor tooltip: shadow gain applies.', dataset: {} };
  globalThis.__noiseFloor = { value: '0.5', style: {} };
  setFormula({ value: 'absolute' });
  S.meterUpdateNoiseFloorControlAvailability();
  assert(globalThis.__noiseFloor.style.opacity === '0.45', 'inactive: input dims');
  assert(b2.style.opacity === '0.45', 'inactive: presets dim');
  assert(globalThis.__noiseLabel.style.opacity === '', 'inactive: container label stays bright');
  assert(hint.style.opacity === undefined, 'inactive: hint carries no dim of its own');
  assert(hint.style.display === '', 'inactive: hint visible');
  // Back to Perceptual: everything restores.
  setFormula({ value: 'perceptual' });
  S.meterUpdateNoiseFloorControlAvailability();
  assert(globalThis.__noiseFloor.style.opacity === '' && b2.style.opacity === '', 'active: input and presets restored');
  globalThis.__noiseHint = null;
  globalThis.__presetBtns = null;
  globalThis.__noiseFloor = null;
});

test('noise_floor_row_has_coarse_pointer_touch_target_css', () => {
  // F-04: every target in the row is compact; a coarse-pointer media block
  // must raise the input, presets, clear ×, and hint to 44px. If this fails,
  // the row regressed to sub-44px touch targets on bench screens.
  const css = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-theme.css'), 'utf8');
  const m = /@media\(pointer:coarse\)\{([\s\S]*?)\}\s*\n#meterSettingsGrid/.exec(css);
  if (!m) throw new Error('coarse-pointer block for the noise-floor row missing from webui-theme.css');
  const block = m[1];
  assert(/min-height:44px/.test(block), '44px min-height rule present');
  for (const sel of ['.noise-floor-preset', '#meterRgbBalanceNoiseFloorClear', '#meterRgbBalanceNoiseFloorHint', '#meterRgbBalanceNoiseFloor\\b'.replace('\\b','')]) {
    assert(block.includes(sel.replace(/\\b/,'')), 'block covers ' + sel);
  }
  const html = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-body.html'), 'utf8');
  assert(/id="meterNoiseFloorControl"/.test(html), 'row label carries the scoping id');
});

test('preset_html_data_value_matches_onclick', () => {
  // The highlight compares data-value to the applied floor; if the two
  // attributes on a button ever disagree, the row lies about which is active.
  const html = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-body.html'), 'utf8');
  const btns = [...html.matchAll(/<button[^>]*class="noise-floor-preset"[^>]*>/g)].map((m) => m[0]);
  assert(btns.length >= 2, 'preset buttons present');
  for (const b of btns) {
    const dv = /data-value="([0-9.]+)"/.exec(b);
    const oc = /meterApplyNoiseFloorPreset\('([0-9.]+)'\)/.exec(b);
    if (!dv || !oc) throw new Error('preset button missing data-value or onclick value');
    assert(Number(dv[1]) === Number(oc[1]), 'data-value must equal the onclick value, got ' + dv[1] + ' vs ' + oc[1]);
  }
});

// ---------------------------------------------------------------------------
// Workspace companion: meterGreyTvColumnHtml lives in webui-workspace.js and
// renders the HTML live-RGB columns. Same brace-extraction trick, own sandbox.
// It consumes the meterRgbDeltasForLive entry shape, so the noise flag flowing
// from that spec into the dimmed fill + hover title is pinned end-to-end here.
// ---------------------------------------------------------------------------
const WS_PATH = path.join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-workspace.js');
const wsText = fs.readFileSync(WS_PATH, 'utf8');

function extractFrom(text, name) {
  const re = new RegExp('^function\\s+' + name + '\\s*\\(', 'm');
  const m = text.match(re);
  if (!m) throw new Error('anchor not found for function ' + name);
  const second = new RegExp('^function\\s+' + name + '\\s*\\(', 'gm');
  let count = 0;
  while (second.exec(text) !== null) count++;
  if (count !== 1) throw new Error('ambiguous anchors for function ' + name + ' (' + count + ')');
  // reuse the state machine in extractFunction by slicing from the anchor to a
  // sentinel: wrap so the brace matcher only sees this function's text.
  return extractFunction(text.slice(m.index), name);
}

const WS_STUBS = String.raw`
// Collaborators of meterGreyTvColumnHtml — the column formatter and step value
// are not under test; pin only the noise-flag handling in the fill markup.
function meterGreyTvFormatInputValue(v) { return String(v == null ? '' : v); }
function meterGreyTvFormatLiveValue(entry) { return entry && entry.labelV != null ? Number(entry.labelV).toFixed(2) + '%' : '--'; }
function meterGreyTvChannelStep() { return 1; }
function meterRgbBalanceNoiseFloor() { return globalThis.__wsNoiseFloor || 0; }
// mirror of the webui-app.js formatter (extracted separately; the column
// renderer only ever sees already-resolved per-entry floor numbers)
function meterFormatNoiseFloorValue(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return 'Off';
  return (Math.abs(n - Math.round(n)) < 1e-9) ? String(Math.round(n)) : String(Math.round(n * 100) / 100);
}
`;
const wsColumnHtml = new Function(
  WS_STUBS + '\n' + extractFrom(wsText, 'meterGreyTvColumnHtml') + '\n return meterGreyTvColumnHtml;'
)();

function wsColumn(entry, readOnly) {
  return wsColumnHtml('R', 'R', '#f44', 50, entry, 5, false, !!readOnly);
}

test('html_live_column_noise_fill_dims_and_explains', () => {
  // The title now names the entry's EFFECTIVE floor (liveEntry.floor), not a
  // re-read of the flat field — empirical floors vary per point.
  const noise = wsColumn({ v: 0.1, labelV: 100.1, showPlus: true, noise: true, floor: 0.5 });
  assert(noise.includes('opacity:.45'), 'within-noise fill dims');
  assert(noise.includes('title="Deviation is within the meter noise floor'), 'dimmed fill carries hover explanation');
  assert(noise.includes('±0.5 L* pre-gain'), 'explanation names the entry floor value');
  const empirical = wsColumn({ v: 0.31, labelV: 100.31, showPlus: true, noise: true, floor: 0.8451 });
  assert(empirical.includes('±0.85 L* pre-gain'), 'irrational empirical floor prints at 2dp');
  const bright = wsColumn({ v: 2, labelV: 102, showPlus: true, noise: false });
  assert(!bright.includes('opacity:.45'), 'bright fill untouched');
  assert(!bright.includes('noise floor'), 'bright fill has no noise title');
  const nullEntry = wsColumn(null);
  assert(nullEntry.includes('display:none'), 'null entry stays hidden');
});

test('html_live_column_readonly_variant_also_carries_noise_title', () => {
  const ro = wsColumn({ v: 0.05, labelV: 100.05, showPlus: true, noise: true, floor: 0.3 }, true);
  assert(ro.includes('is-readonly'), 'readonly variant rendered');
  assert(ro.includes('opacity:.45'), 'readonly within-noise fill dims');
  assert(ro.includes('noise floor'), 'readonly dimmed fill carries hover explanation');
});

test('canvas_delta_bar_titles_come_from_noise_flags', () => {
  // The canvas renderer cannot show per-bar tooltips, so it summarizes flagged
  // channels on the canvas element title. Extract the title block by anchor:
  // a regression that drops it silently returns the dimmed bars to cryptic.
  const appSrc = srcText;
  const idx = appSrc.indexOf('function drawDeltaBarsVertical(');
  assert(idx >= 0, 'drawDeltaBarsVertical anchor present');
  const body = appSrc.slice(idx, idx + 2000);
  assert(body.includes('c.title='), 'canvas title set from spec');
  assert(body.includes('e.noise'), 'title built from per-entry noise flags');
  assert(body.includes('noise floor'), 'title text explains the noise floor');
});

// ---------------------------------------------------------------------------
// Source-anchor regressions (PR-16 review round): the behaviors below live in
// functions too DOM-heavy for this extraction harness, so pin their key
// invariants textually. A refactor of the matched block trips these — update
// the anchor deliberately, the invariant is the point.
// ---------------------------------------------------------------------------
test('prefs_re_save_happens_after_full_restore', () => {
  // meterLoadColorPrefs must NOT call meterSaveColorPrefs mid-restore: the
  // save serializes the whole DOM, and un-restored controls would overwrite
  // the operator's stored prefs with HTML defaults (silent loss on 2nd
  // reload — PR-16 review CRITICAL). The re-save must sit after the LAST
  // setVal/setChk. Comment lines mentioning the call do not count.
  const fn = extractFunction(srcText, 'meterLoadColorPrefs');
  const lines = fn.split('\n').filter((l) => !/^\s*\/\//.test(l));
  const saveLines = lines
    .map((l, i) => [l.includes('meterSaveColorPrefs'), i])
    .filter(([has]) => has)
    .map(([, i]) => i);
  if (saveLines.length === 0) throw new Error('load path must re-save the committed noise floor (after the full restore)');
  let lastRestore = -1;
  lines.forEach((l, i) => { if (/\bset(Val|Chk)\(/.test(l)) lastRestore = i; });
  assert(saveLines.every((i) => i > lastRestore),
    'every meterSaveColorPrefs call must follow the last setVal/setChk (mid-load save clobbers un-restored prefs)');
});

test('hover_noise_annotation_skips_noChroma_points', () => {
  // A noChroma patch (zero light) carries the 100/100/100 sentinel; annotating
  // it 'within meter noise' asserts noise for a point that emitted none.
  const idx = wsText.indexOf('function chartHandleHover(');
  assert(idx >= 0, 'chartHandleHover anchor present');
  const body = wsText.slice(idx, idx + 4000);
  const gate = /if\(meterRgbBalanceNoiseFloorAnnotationLive\(\)&&!bal\.noChroma\)/.exec(body);
  if (!gate) throw new Error('hover noise annotation must be gated on !bal.noChroma');
  // The hit-zone fallback for a missing white ref must also mark noChroma,
  // otherwise a white-less chart still annotates.
  const reg = wsText.slice(wsText.indexOf('function chartRegisterInteraction('));
  assert(/:\{R:100,G:100,B:100,noChroma:true\}/.test(reg.slice(0, 4000)),
    'chartRegisterInteraction white-less fallback must carry noChroma:true');
});

test('noise_band_gain_comes_from_reading', () => {
  // The band half-width must use the same gain object the plotted values and
  // the tooltip divide by: the reading (analysis stamps live there), with the
  // step only as fallback.
  const idx = wsText.indexOf('function drawRGBChart(');
  assert(idx >= 0, 'drawRGBChart anchor present');
  const body = wsText.slice(idx, wsText.indexOf('function ', idx + 10));
  assert(/const rdZone=readingMap&&readingMap\[step\.ire\];/.test(body)&&/meterPerceptualRgbBalanceGain\(rdZone\)/.test(body),
    'noise band gain must resolve through readingMap[step.ire] into rdZone');
  assert(/if\(!rdZone\) return;/.test(body),
    'band must SKIP a step with no reading — the step fallback reintroduced the skew the comment forbids');
});

test('empirical_floor_from_repeat_scatter', () => {
  // Empirical mode: the per-point floor is k·σ of that step's own recorded
  // pre-gain balance scatter. A step with no/<2 samples has no empirical
  // floor and must fall back to the flat field (never silently blind).
  globalThis.__noiseMode = null;
  globalThis.__noiseFloor = { value: '0.3' };
  assert(S.meterRgbBalanceNoiseFloorMode() === 'flat', 'missing select defaults to flat');
  globalThis.__noiseMode = { value: 'empirical' };
  assert(S.meterRgbBalanceNoiseFloorMode() === 'empirical', 'select drives the mode');
  const step = { name: '45%' };
  // Flat mode ignores history entirely.
  assert(S.meterEmpiricalNoiseFloorFor(step) === null, 'flat mode: no empirical floor');
  // Empirical mode, no history: null -> effective floor falls back to flat.
  assert(S.meterEmpiricalNoiseFloorFor(step) === null, 'no history yet: null');
  assertClose(S.meterRgbBalanceEffectiveNoiseFloor(step), 0.3, 1e-9, 'fallback = flat field');
  // Feed three samples of a step whose displayed balance scatters around
  // 100 with gain 1 (pre-gain == displayed deviation). Sample stdev of
  // {0, +0.1, -0.1} is exactly 0.1 -> floor k·0.1.
  globalThis.__liveBal = { R: 100.0, G: 100.0, B: 100.0, gain: 1 };
  S.meterRecordReadingNoise({ X: 1, Y: 10, Z: 11 }, step);
  assert(S.meterEmpiricalNoiseFloorFor(step) === null, 'one sample: still no sigma');
  globalThis.__liveBal = { R: 100.1, G: 100.0, B: 100.0, gain: 1 };
  S.meterRecordReadingNoise({ X: 1, Y: 10, Z: 11.0001 }, step);
  assertClose(S.meterStepNoiseSigma(S.meterStepNoiseKey(step)), 0.1 / Math.SQRT2, 1e-9,
    'two-sample stdev of {0,0.1} is |d|/sqrt(2)');
  globalThis.__liveBal = { R: 99.9, G: 100.0, B: 100.0, gain: 1 };
  S.meterRecordReadingNoise({ X: 1, Y: 10, Z: 11.0002 }, step);
  const f = S.meterEmpiricalNoiseFloorFor(step);
  assertClose(f, METER_NOISE_HISTORY_K * 0.1, 1e-9, 'floor = k·sigma of the scatter');
  // The flag now judges against k·sigma, not the flat 0.3: deviation 0.25
  // (> flat 0.3? no: 0.25 < 0.3 flat-true; with k·sigma 0.2 it must be FALSE).
  assert(S.meterRgbBalanceWithinNoise(100.25, 1, step) === false, 'empirical floor replaces the flat verdict');
  assert(S.meterRgbBalanceWithinNoise(100.15, 1, step) === true, 'inside k·sigma flags');
  // An unknown step (no history) still uses the flat floor.
  assert(S.meterRgbBalanceWithinNoise(100.25, 1, { name: '5%' }) === true, 'unknown step: flat fallback');
  // Samples store PRE-gain: gain-4 balances of ±0.8 displayed are ±0.2
  // pre-gain, so the stdev lands at 0.2 in the same scale as above.
  const step2 = { name: '5%' };
  globalThis.__liveBal = { R: 100.0, G: 100.0, B: 100.0, gain: 4 };
  S.meterRecordReadingNoise({ X: 1, Y: 1, Z: 1 }, step2);
  globalThis.__liveBal = { R: 100.8, G: 100.0, B: 100.0, gain: 4 };
  S.meterRecordReadingNoise({ X: 1, Y: 1, Z: 1.1 }, step2);
  globalThis.__liveBal = { R: 99.2, G: 100.0, B: 100.0, gain: 4 };
  S.meterRecordReadingNoise({ X: 1, Y: 1, Z: 1.2 }, step2);
  assertClose(S.meterEmpiricalNoiseFloorFor(step2), METER_NOISE_HISTORY_K * 0.2, 1e-9,
    'sigma computed on pre-gain deviations');
  // Re-delivering the SAME (last) XYZ is ONE measurement, not scatter
  // evidence — the dedupe is consecutive-only by design: a stale series poll
  // re-delivers the newest reading, and a genuinely re-aimed meter never
  // reproduces an identical X/Y/Z triple.
  const sigmaBefore = S.meterStepNoiseSigma(S.meterStepNoiseKey(step2));
  globalThis.__liveBal = { R: 99.2, G: 100.0, B: 100.0, gain: 4 };
  S.meterRecordReadingNoise({ X: 1, Y: 1, Z: 1.2 }, step2);
  assertClose(S.meterStepNoiseSigma(S.meterStepNoiseKey(step2)), sigmaBefore, 1e-12,
    'duplicate XYZ poll must not add a sample');
  // Gates: non-greyscale and non-real readings record nothing.
  globalThis.__recIsGrey = false;
  globalThis.__liveBal = { R: 105, G: 95, B: 100, gain: 1 };
  S.meterRecordReadingNoise({ X: 2, Y: 2, Z: 2 }, { name: 'red-patch' });
  assert(S.meterEmpiricalNoiseFloorFor({ name: 'red-patch' }) === null, 'color patch records nothing');
  globalThis.__recIsGrey = true;
  globalThis.__recIsReal = false;
  S.meterRecordReadingNoise({ X: 3, Y: 3, Z: 3 }, { name: 'shell-step' });
  assert(S.meterEmpiricalNoiseFloorFor({ name: 'shell-step' }) === null, 'unread shell records nothing');
  globalThis.__recIsReal = true;
  globalThis.__noiseMode = null;
  globalThis.__noiseFloor = null;
  globalThis.__liveBal = null;
  // Store reset path: meterReplaceReadings clears it on series switch.
  const store = S.meterNoiseHistoryStore();
  store.set('45%', { vals: [[0, 0, 0], [0.1, -0.1, 0]] });
  assert(S.meterStepNoiseSigma('45%') > 0, 'store is shared module state');
});

test('empirical_mode_control_wiring', () => {
  // The mode select must exist, start at Flat, default to flat when missing,
  // and persist with the color prefs; Active() must light up for empirical
  // even with the flat field empty, and AnnotationLive() stays Perceptual-
  // gated in both modes.
  const html = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-body.html'), 'utf8');
  const sel = /<select[^>]*id="meterNoiseFloorMode"[^>]*>([\s\S]*?)<\/select>/.exec(html);
  if (!sel) throw new Error('meterNoiseFloorMode select missing from webui-body.html');
  assert(/value="flat" selected/.test(sel[0]), 'mode select must default to Flat (historic behavior)');
  assert(/value="empirical"/.test(sel[1]), 'empirical option present');
  assert(/onchange="meterOnNoiseFloorModeChange\(\)"/.test(sel[0]), 'mode change must trigger the redraw handler');
  assert(/aria-label=/.test(sel[0]), 'mode select needs an accessible name');
  assert(/rgb_noise_mode/.test(srcText), 'mode must persist in meterSaveColorPrefs');

  globalThis.__noiseMode = null;
  globalThis.__noiseFloor = { value: '' };
  assert(S.meterRgbBalanceNoiseFloorMode() === 'flat', 'missing select -> flat');
  assert(S.meterRgbBalanceNoiseFloorActive() === false, 'flat + empty field: not active');
  globalThis.__noiseMode = { value: 'empirical' };
  assert(S.meterRgbBalanceNoiseFloorActive() === true, 'empirical is active with an empty flat field');
  setFormula({ value: 'absolute' });
  assert(S.meterRgbBalanceNoiseFloorAnnotationLive() === false, 'absolute: annotation never live');
  setFormula({ value: 'perceptual' });
  assert(S.meterRgbBalanceNoiseFloorAnnotationLive() === true, 'perceptual + empirical: live');
  globalThis.__noiseMode = null;
  assert(S.meterRgbBalanceNoiseFloorAnnotationLive() === false, 'perceptual + flat + empty: off');
});

test('floor_formatter_prints_as_judged', () => {
  assert(S.meterFormatNoiseFloorValue(0.3) === '0.3', 'typed value prints as typed');
  assert(S.meterFormatNoiseFloorValue(3.0) === '3', 'integral prints without decimals');
  assert(S.meterFormatNoiseFloorValue(0.8451231) === '0.85', 'irrational empirical sigma rounds to 2dp');
  assert(S.meterFormatNoiseFloorValue(0) === 'Off', '0 reads Off');
  assert(S.meterFormatNoiseFloorValue(NaN) === 'Off', 'NaN reads Off');
});

// ---------------------------------------------------------------------------
// Report — machine-readable single JSON line; t/rgb_balance_formula.t
// (prove harness) decodes it into TAP assertions. Keep stdout JSON-only.
// ---------------------------------------------------------------------------
console.log(JSON.stringify({ passed: passed, failed: failed, results: results }));
process.exit(failed ? 1 : 0);
