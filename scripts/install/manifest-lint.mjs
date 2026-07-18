#!/usr/bin/env node
// scripts/install/manifest-lint.mjs — validates scripts/install/manifest.json
// against the Phase-1 probe-only schema (HIMMEL-756 T1.2). Zero-dep ESM.
//
// Checks per item:
//   (a) exactly the six required keys (id, kind, scopes, profiles, deps,
//       probe) plus any of the OPTIONAL_ITEM_KEYS (install, unwire,
//       removable, offboard) — still closed: any other key is a lint error.
//   (b) kind is never 'hardening' and is one of the fixed KIND vocabulary
//   (c) probe.type is one of the fixed PROBE_TYPES vocabulary
//   (d) ids are unique across the manifest
//   (e) every deps[] entry references an existing item id
//   (f) probe descriptor shape matches its type's contract (below) — closed
//       shapes: unknown/extra fields are a lint error, same as missing ones.
//   (g) install/unwire descriptor shape matches its type's contract (schema
//       v2, HIMMEL-755 A1) — same closed-shape treatment as probe. When
//       BOTH install and unwire are present and both are type 'wire', their
//       `target` values must also MATCH (a wire/unwire pair naming
//       different targets would wire one thing and unwire another).
//   (h) removable === 'per-item' IFF 'unwire' is present (biconditional);
//       removable, when present, is one of REMOVABLE_VALUES.
//   (i) scopes ⊆ [project, user], profiles ⊆ [core, luna, all] (schema v2
//       value-enums).
//   (j) deps[] form a DAG — no cycles (schema v2 DFS cycle detector).
//   (k) offboard, when present, is one of OFFBOARD_VALUES (unwire|advise|
//       keep) — HIMMEL-755 sub-ticket E. Optional; absent defaults to
//       'unwire' at the himmelctl consumer, so no biconditional here (unlike
//       removable<=>unwire) — offboard has no paired descriptor to agree with.
//
// Per-type probe descriptor shape contract (single normative source — the
// probe interpreter (HIMMEL-756 T1.3) MUST consume descriptors that satisfy
// this table; the two shapes below vary legitimately across items and are
// each machine-checked, not flattened):
//
//   type              | fields (all required unless noted)
//   ------------------|--------------------------------------------------
//   file-exists       | path: string
//   settings-key      | file: string; EXACTLY ONE of key: string XOR
//                     | keys: non-empty string[]
//   settings-hooks    | file: string; key: string
//   cmd:has_qmd       | resolver: string
//   qmd-index         | collections: non-empty string[]
//   mcp-registered    | server: string
//   handover-dir      | resolver: string
//   dep               | EXACTLY ONE of cmd: string XOR (win32: string AND
//                     | posix: string) — the win32/posix pair is the
//                     | platform-branched variant used by scheduler-backend
//
// Usage:
//   node scripts/install/manifest-lint.mjs [path-to-manifest.json]
// The manifest path defaults to manifest.json next to this script; override
// via a CLI arg (argv[2]) OR the MANIFEST_PATH env var (CLI arg wins if both
// are given) — this is the seam the brief's self-test uses to lint a
// corrupted temp copy without touching the real manifest.
//
// Exits 0 on a clean manifest; exits 1 and prints one message per violation
// otherwise.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
// CR fix (CodeRabbit round 19): the `target` vocabulary a wire/build (and
// wire unwire) descriptor accepts is derived from install-engine.js's ACTUAL
// dispatch sites (INSTALL_TARGETS), not a parallel hardcoded list here — the
// two could otherwise drift, and a lint-clean typo would silently dispatch
// the wrong primitive (non-statusline wire → pretooluse-hooks; non-jira-cli
// build → bitbucket). Default-importing the CommonJS engine pulls in only
// constants/functions at module-eval time (no spawn side effects).
import installEngine from '../himmelctl/lib/install-engine.js';

const KINDS = ['hook', 'plugin', 'dep', 'wiring', 'vault', 'scheduler', 'lane', 'mcp'];
const PROBE_TYPES = ['file-exists', 'settings-key', 'settings-hooks', 'cmd:has_qmd', 'qmd-index', 'mcp-registered', 'handover-dir', 'dep'];
const ITEM_KEYS = ['id', 'kind', 'scopes', 'profiles', 'deps', 'probe'];
// Optional schema-v2 consumer keys (HIMMEL-755 A1). Permitted by the
// exact-key check but not required — items authored under schemaVersion:1
// stay valid; items that DO carry them are shape-checked below.
const OPTIONAL_ITEM_KEYS = ['install', 'unwire', 'removable', 'offboard'];
const INSTALL_TYPES = ['adopt', 'setup', 'wire', 'plugins', 'qmd', 'dep', 'build', 'config'];
const UNWIRE_TYPES = ['wire'];
const SCOPES_ENUM = ['project', 'user'];
const PROFILES_ENUM = ['core', 'luna', 'all'];
const REMOVABLE_VALUES = ['per-item', 'full-offboard-only'];
// HIMMEL-755 sub-ticket E: the uninstall-completeness owned/shared cut.
// 'unwire' (himmel-owned, uninstall.sh tears it down) is the DEFAULT when
// the field is absent — see scripts/himmelctl/bin.js's partitionOffboard().
const OFFBOARD_VALUES = ['unwire', 'advise', 'keep'];

function resolveManifestPath() {
  const argPath = process.argv[2];
  if (argPath) return path.resolve(argPath);
  if (process.env.MANIFEST_PATH) return path.resolve(process.env.MANIFEST_PATH);
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.join(here, 'manifest.json');
}

function isNonEmptyStringArray(v) {
  return Array.isArray(v) && v.length > 0 && v.every((x) => typeof x === 'string');
}

// (f) validates probe descriptor shape against the per-type contract
// documented in the header comment. Pushes one message per violation
// (missing/wrong-typed required field, extra/unknown field) into errors.
function checkProbeShape(probe, label, errors) {
  if (!probe || typeof probe !== 'object') return;
  const type = probe.type;
  const otherKeys = Object.keys(probe).filter((k) => k !== 'type');
  const extraOf = (allowed) => otherKeys.filter((k) => !allowed.includes(k));
  const reportExtra = (allowed) => {
    const ex = extraOf(allowed);
    if (ex.length > 0) errors.push(`${label}: probe type '${type}' has unexpected field(s) [${ex.join(', ')}]`);
  };

  switch (type) {
    case 'file-exists': {
      if (typeof probe.path !== 'string') errors.push(`${label}: probe type 'file-exists' requires 'path' (string)`);
      reportExtra(['path']);
      break;
    }
    case 'settings-key': {
      if (typeof probe.file !== 'string') errors.push(`${label}: probe type 'settings-key' requires 'file' (string)`);
      const hasKey = Object.prototype.hasOwnProperty.call(probe, 'key');
      const hasKeys = Object.prototype.hasOwnProperty.call(probe, 'keys');
      if (hasKey === hasKeys) {
        errors.push(`${label}: probe type 'settings-key' requires exactly one of 'key' (string) or 'keys' (non-empty string array), got ${hasKey ? 'both' : 'neither'}`);
      } else if (hasKey && typeof probe.key !== 'string') {
        errors.push(`${label}: probe type 'settings-key' field 'key' must be a string`);
      } else if (hasKeys && !isNonEmptyStringArray(probe.keys)) {
        errors.push(`${label}: probe type 'settings-key' field 'keys' must be a non-empty array of strings`);
      }
      reportExtra(['file', 'key', 'keys']);
      break;
    }
    case 'settings-hooks': {
      if (typeof probe.file !== 'string') errors.push(`${label}: probe type 'settings-hooks' requires 'file' (string)`);
      if (typeof probe.key !== 'string') errors.push(`${label}: probe type 'settings-hooks' requires 'key' (string)`);
      reportExtra(['file', 'key']);
      break;
    }
    case 'cmd:has_qmd': {
      if (typeof probe.resolver !== 'string') errors.push(`${label}: probe type 'cmd:has_qmd' requires 'resolver' (string)`);
      reportExtra(['resolver']);
      break;
    }
    case 'qmd-index': {
      if (!isNonEmptyStringArray(probe.collections)) errors.push(`${label}: probe type 'qmd-index' requires 'collections' (non-empty array of strings)`);
      reportExtra(['collections']);
      break;
    }
    case 'mcp-registered': {
      if (typeof probe.server !== 'string') errors.push(`${label}: probe type 'mcp-registered' requires 'server' (string)`);
      reportExtra(['server']);
      break;
    }
    case 'handover-dir': {
      if (typeof probe.resolver !== 'string') errors.push(`${label}: probe type 'handover-dir' requires 'resolver' (string)`);
      reportExtra(['resolver']);
      break;
    }
    case 'dep': {
      const hasCmd = Object.prototype.hasOwnProperty.call(probe, 'cmd');
      const hasWin32 = Object.prototype.hasOwnProperty.call(probe, 'win32');
      const hasPosix = Object.prototype.hasOwnProperty.call(probe, 'posix');
      const hasPlatformPair = hasWin32 && hasPosix;
      if (hasCmd && (hasWin32 || hasPosix)) {
        errors.push(`${label}: probe type 'dep' requires exactly one of 'cmd' (string) or 'win32'+'posix' (both strings), got both`);
      } else if (hasCmd) {
        if (typeof probe.cmd !== 'string') errors.push(`${label}: probe type 'dep' field 'cmd' must be a string`);
      } else if (hasWin32 || hasPosix) {
        if (!hasPlatformPair || typeof probe.win32 !== 'string' || typeof probe.posix !== 'string') {
          errors.push(`${label}: probe type 'dep' requires both 'win32' and 'posix' (strings) when not using 'cmd'`);
        }
      } else {
        errors.push(`${label}: probe type 'dep' requires exactly one of 'cmd' (string) or 'win32'+'posix' (both strings), got neither`);
      }
      reportExtra(['cmd', 'win32', 'posix']);
      break;
    }
    default:
      // unknown probe.type is already reported by check (c); nothing to
      // validate further for a type outside the fixed vocabulary.
      break;
  }
}

// The set of keys a probe descriptor checks, for cross-checking against a
// config-type install descriptor — non-null only for probe type
// 'settings-key' (the ONE probe type with a key/keys concept at all; every
// other probe type — handover-dir, dep, mcp-registered, ... — has no
// per-key notion, so the cross-check below is a no-op for those, same as
// today). Mirrors checkProbeShape's own key XOR keys handling.
function probeKeySet(probe) {
  if (!probe || probe.type !== 'settings-key') return null;
  if (Array.isArray(probe.keys)) return probe.keys;
  if (typeof probe.key === 'string') return [probe.key];
  return null;
}

// (g) validates the optional 'install' descriptor shape against its type's
// contract — same closed-shape treatment as checkProbeShape. Called only
// when 'install' is present on the item (it's optional per OPTIONAL_ITEM_KEYS).
// CR fix: a config-type install descriptor is now cross-checked against the
// SAME item's `probe` — the descriptor must name every key the probe
// actually verifies, or converging it wouldn't converge what status reports
// on. `probe` may be undefined/malformed (checkProbeShape reports that
// separately); probeKeySet() above returns null in that case and the
// cross-check is skipped (shape-only validation still applies).
function checkInstallShape(install, probe, label, errors) {
  if (!install || typeof install !== 'object') {
    errors.push(`${label}: 'install' must be an object`);
    return;
  }
  const type = install.type;
  if (!INSTALL_TYPES.includes(type)) {
    errors.push(`${label}: install.type '${type}' not in [${INSTALL_TYPES.join(', ')}]`);
    return;
  }
  const otherKeys = Object.keys(install).filter((k) => k !== 'type');
  const reportExtra = (allowed) => {
    const ex = otherKeys.filter((k) => !allowed.includes(k));
    if (ex.length > 0) errors.push(`${label}: install type '${type}' has unexpected field(s) [${ex.join(', ')}]`);
  };
  switch (type) {
    case 'wire':
    case 'build':
      if (typeof install.target !== 'string') {
        errors.push(`${label}: install type '${type}' requires 'target' (string)`);
      } else if (!installEngine.INSTALL_TARGETS[type].includes(install.target)) {
        // CR fix (CodeRabbit round 19): reject a target outside the engine's
        // closed vocabulary — without this a lint-clean typo silently
        // dispatches the wrong primitive (see INSTALL_TARGETS' header).
        errors.push(`${label}: install type '${type}' target '${install.target}' not in [${installEngine.INSTALL_TARGETS[type].join(', ')}]`);
      }
      reportExtra(['target']);
      break;
    case 'config': {
      // A config-type item's install descriptor must be able to name EVERY
      // key its OWN probe checks (a probe checking 4 keys with an install
      // descriptor naming only 1 is internally incoherent — the descriptor
      // wouldn't converge what the probe actually verifies). Mirrors probe
      // type 'settings-key's own key XOR keys shape exactly, for the shape
      // itself; the cross-check against the probe's key set is the CR fix.
      const hasKey = Object.prototype.hasOwnProperty.call(install, 'key');
      const hasKeys = Object.prototype.hasOwnProperty.call(install, 'keys');
      let shapeOk = true;
      if (hasKey === hasKeys) {
        errors.push(`${label}: install type 'config' requires exactly one of 'key' (string) or 'keys' (non-empty string array), got ${hasKey ? 'both' : 'neither'}`);
        shapeOk = false;
      } else if (hasKey && typeof install.key !== 'string') {
        errors.push(`${label}: install type 'config' field 'key' must be a string`);
        shapeOk = false;
      } else if (hasKeys && !isNonEmptyStringArray(install.keys)) {
        errors.push(`${label}: install type 'config' field 'keys' must be a non-empty array of strings`);
        shapeOk = false;
      }
      // CR fix: cross-check against the item's own probe key set (only
      // meaningful once the shape itself is valid, and only for a probe
      // that actually has a key/keys concept — see probeKeySet()).
      if (shapeOk) {
        const probeKeys = probeKeySet(probe);
        if (probeKeys) {
          if (hasKey && probeKeys.length > 1) {
            errors.push(`${label}: install type 'config' has a singular 'key' but the probe checks ${probeKeys.length} keys [${probeKeys.join(', ')}] — use 'keys' naming every probed key`);
          } else if (hasKey && install.key !== probeKeys[0]) {
            errors.push(`${label}: install.key '${install.key}' does not match the probe's key '${probeKeys[0]}'`);
          } else if (hasKeys) {
            const probeSet = new Set(probeKeys);
            const installSet = new Set(install.keys);
            const missing = probeKeys.filter((k) => !installSet.has(k));
            const extraKeys = install.keys.filter((k) => !probeSet.has(k));
            if (missing.length > 0 || extraKeys.length > 0) {
              errors.push(`${label}: install.keys must cover exactly the probe's key set [${probeKeys.join(', ')}] (missing=[${missing.join(', ')}] extra=[${extraKeys.join(', ')}])`);
            }
          }
        }
      }
      reportExtra(['key', 'keys']);
      break;
    }
    case 'adopt':
    case 'setup':
    case 'plugins':
    case 'qmd':
    case 'dep':
      reportExtra([]);
      break;
  }
}

// (g) validates the optional 'unwire' descriptor shape. Called only when
// 'unwire' is present on the item.
function checkUnwireShape(unwire, label, errors) {
  if (!unwire || typeof unwire !== 'object') {
    errors.push(`${label}: 'unwire' must be an object`);
    return;
  }
  const type = unwire.type;
  if (!UNWIRE_TYPES.includes(type)) {
    errors.push(`${label}: unwire.type '${type}' not in [${UNWIRE_TYPES.join(', ')}]`);
    return;
  }
  const otherKeys = Object.keys(unwire).filter((k) => k !== 'type');
  const reportExtra = (allowed) => {
    const ex = otherKeys.filter((k) => !allowed.includes(k));
    if (ex.length > 0) errors.push(`${label}: unwire type '${type}' has unexpected field(s) [${ex.join(', ')}]`);
  };
  switch (type) {
    case 'wire':
      if (typeof unwire.target !== 'string') {
        errors.push(`${label}: unwire type 'wire' requires 'target' (string)`);
      } else if (!installEngine.INSTALL_TARGETS.wire.includes(unwire.target)) {
        // CR fix (CodeRabbit round 19): same closed-vocabulary gate as the
        // install side — a non-statusline unwire target falls through to the
        // pretooluse-hooks primitive in unwireCommand().
        errors.push(`${label}: unwire type 'wire' target '${unwire.target}' not in [${installEngine.INSTALL_TARGETS.wire.join(', ')}]`);
      }
      reportExtra(['target']);
      break;
  }
}

// (j) DFS cycle detector over the deps[] graph. Pushes ONE error naming the
// cycle path and stops at the first cycle found (deterministic id-sorted
// traversal order so re-runs report the same cycle first). Every item `id`
// and each `deps[]` entry is required to be a string BEFORE the graph is
// built: a non-string id gets its OWN error here (not silently dropped —
// check (a)'s exact-key check reports plenty of shapes but never
// specifically "id must be a string") and that node is excluded from the
// graph; a non-string deps[] entry is likewise flagged and excluded as an
// edge (check (e) separately reports a dangling/malformed *string* deps
// entry that doesn't resolve to a known id — this guards the type itself,
// so the DFS below never has to reason about a non-string graph key/value).
function detectDepCycle(items, errors) {
  const graph = new Map();
  for (const it of items) {
    if (!it || typeof it !== 'object') continue;
    if (typeof it.id !== 'string') {
      errors.push(`<unknown id>: item 'id' must be a string for dependency-cycle analysis (got ${JSON.stringify(it.id)})`);
      continue;
    }
    let deps = [];
    if (Array.isArray(it.deps)) {
      for (const d of it.deps) {
        if (typeof d === 'string') {
          deps.push(d);
        } else {
          errors.push(`${it.id}: deps entry must be a string for dependency-cycle analysis (got ${JSON.stringify(d)})`);
        }
      }
    }
    graph.set(it.id, deps);
  }
  const WHITE = 0;
  const GRAY = 1;
  const BLACK = 2;
  const color = new Map();
  for (const id of graph.keys()) color.set(id, WHITE);
  const stack = [];

  function dfs(id) {
    color.set(id, GRAY);
    stack.push(id);
    for (const dep of graph.get(id) || []) {
      if (!graph.has(dep)) continue; // dangling dep already reported by (e)
      if (color.get(dep) === GRAY) {
        const idx = stack.indexOf(dep);
        return stack.slice(idx).concat(dep);
      }
      if (color.get(dep) === WHITE) {
        const cycle = dfs(dep);
        if (cycle) return cycle;
      }
    }
    stack.pop();
    color.set(id, BLACK);
    return null;
  }

  for (const id of [...graph.keys()].sort()) {
    if (color.get(id) === WHITE) {
      const cycle = dfs(id);
      if (cycle) {
        errors.push(`dependency cycle detected: ${cycle.join(' -> ')}`);
        return;
      }
    }
  }
}

function lint(manifest) {
  const errors = [];
  const items = Array.isArray(manifest.items) ? manifest.items : [];
  const ids = new Set(items.map((it) => it && it.id));

  for (const it of items) {
    if (it === null || typeof it !== 'object' || Array.isArray(it)) {
      errors.push('item must be an object');
      continue;
    }

    const label = it.id || '<unknown id>';

    // (a) exactly the six required keys, plus any OPTIONAL_ITEM_KEYS.
    const keys = Object.keys(it);
    const missing = ITEM_KEYS.filter((k) => !keys.includes(k));
    const extra = keys.filter((k) => !ITEM_KEYS.includes(k) && !OPTIONAL_ITEM_KEYS.includes(k));
    if (missing.length > 0 || extra.length > 0) {
      errors.push(`${label}: expected exactly keys [${ITEM_KEYS.join(', ')}] (+ optionally [${OPTIONAL_ITEM_KEYS.join(', ')}]), missing=[${missing.join(', ')}] extra=[${extra.join(', ')}]`);
    }

    // (b) kind never 'hardening', kind in KINDS.
    if (it.kind === 'hardening') {
      errors.push(`${label}: kind 'hardening' is not permitted`);
    } else if (!KINDS.includes(it.kind)) {
      errors.push(`${label}: kind '${it.kind}' not in [${KINDS.join(', ')}]`);
    }

    // (c) probe.type in PROBE_TYPES.
    const probeType = it.probe && it.probe.type;
    if (!PROBE_TYPES.includes(probeType)) {
      errors.push(`${label}: probe.type '${probeType}' not in [${PROBE_TYPES.join(', ')}]`);
    }

    // (f) probe descriptor shape matches its type's contract.
    checkProbeShape(it.probe, label, errors);

    // (g) optional install/unwire descriptor shapes.
    if (Object.prototype.hasOwnProperty.call(it, 'install')) {
      checkInstallShape(it.install, it.probe, label, errors);
    }
    if (Object.prototype.hasOwnProperty.call(it, 'unwire')) {
      checkUnwireShape(it.unwire, label, errors);
    }

    // CR fix: install/unwire target coherence. checkInstallShape and
    // checkUnwireShape each validate their OWN descriptor in isolation, so
    // an item could declare install:{type:"wire",target:"statusline"}
    // alongside unwire:{type:"wire",target:"pretooluse-hooks"} and lint
    // clean — an incoherent pairing that would wire one thing and unwire
    // another. Mirrors the config↔probe key cross-check above: only fires
    // once BOTH descriptors are themselves shape-valid ('wire' type with a
    // string target) — a malformed descriptor already gets its own error
    // from the shape checks above, so this doesn't pile on a confusing
    // second error about a mismatch that isn't the real problem yet.
    if (it.install && it.install.type === 'wire' && typeof it.install.target === 'string'
        && it.unwire && it.unwire.type === 'wire' && typeof it.unwire.target === 'string'
        && it.install.target !== it.unwire.target) {
      errors.push(`${label}: install.target '${it.install.target}' does not match unwire.target '${it.unwire.target}' — a 'wire' install/unwire pair must target the SAME thing`);
    }

    // (h) removable === 'per-item' IFF 'unwire' is present.
    const hasUnwire = Object.prototype.hasOwnProperty.call(it, 'unwire');
    const hasRemovable = Object.prototype.hasOwnProperty.call(it, 'removable');
    if (hasRemovable && !REMOVABLE_VALUES.includes(it.removable)) {
      errors.push(`${label}: removable '${it.removable}' not in [${REMOVABLE_VALUES.join(', ')}]`);
    }
    const removableIsPerItem = it.removable === 'per-item';
    if (removableIsPerItem !== hasUnwire) {
      errors.push(`${label}: removable === 'per-item' iff 'unwire' is present (removable=${JSON.stringify(it.removable)}, hasUnwire=${hasUnwire})`);
    }

    // (k) offboard, when present, is one of OFFBOARD_VALUES. Optional — no
    // biconditional against another field (see the header comment).
    if (Object.prototype.hasOwnProperty.call(it, 'offboard') && !OFFBOARD_VALUES.includes(it.offboard)) {
      errors.push(`${label}: offboard '${it.offboard}' not in [${OFFBOARD_VALUES.join(', ')}]`);
    }

    // (i) value-enums: scopes ⊆ [project, user], profiles ⊆ [core, luna, all].
    // A non-array scopes/profiles is a lint error in its own right (not
    // silently skipped — a malformed shape here would otherwise pass the
    // enum check by vacuous truth and only surface, confusingly, wherever
    // else the value gets consumed).
    if (Array.isArray(it.scopes)) {
      for (const s of it.scopes) {
        if (!SCOPES_ENUM.includes(s)) errors.push(`${label}: scopes entry '${s}' not in [${SCOPES_ENUM.join(', ')}]`);
      }
    } else {
      errors.push(`${label}: 'scopes' must be an array`);
    }
    if (Array.isArray(it.profiles)) {
      for (const p of it.profiles) {
        if (!PROFILES_ENUM.includes(p)) errors.push(`${label}: profiles entry '${p}' not in [${PROFILES_ENUM.join(', ')}]`);
      }
    } else {
      errors.push(`${label}: 'profiles' must be an array`);
    }

    // (e) every deps[] entry references an existing item id. 'deps' absent
    // is treated as empty; present-but-non-array is a lint error rather
    // than silently skipped.
    if (Array.isArray(it.deps)) {
      for (const d of it.deps) {
        if (!ids.has(d)) {
          errors.push(`${label}: deps entry '${d}' does not reference an existing item id`);
        }
      }
    } else if (Object.prototype.hasOwnProperty.call(it, 'deps')) {
      errors.push(`${label}: 'deps' must be an array`);
    }
  }

  // (d) ids unique.
  const seen = new Set();
  for (const it of items) {
    const id = it && it.id;
    if (seen.has(id)) errors.push(`duplicate item id: '${id}'`);
    seen.add(id);
  }

  // (j) deps[] must form a DAG.
  detectDepCycle(items, errors);

  return errors;
}

function main() {
  const manifestPath = resolveManifestPath();
  const raw = readFileSync(manifestPath, 'utf8');
  const manifest = JSON.parse(raw);
  const errors = lint(manifest);
  if (errors.length > 0) {
    console.error(`manifest-lint: ${errors.length} violation(s) in ${manifestPath}`);
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }
  const items = Array.isArray(manifest.items) ? manifest.items : [];
  console.log(`manifest-lint: OK (${items.length} items) — ${manifestPath}`);
  process.exit(0);
}

main();
