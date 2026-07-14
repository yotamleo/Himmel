#!/usr/bin/env node
// scripts/install/manifest-lint.mjs — validates scripts/install/manifest.json
// against the Phase-1 probe-only schema (HIMMEL-756 T1.2). Zero-dep ESM.
//
// Checks per item:
//   (a) exactly the six keys: id, kind, scopes, profiles, deps, probe
//   (b) kind is never 'hardening' and is one of the fixed KIND vocabulary
//   (c) probe.type is one of the fixed PROBE_TYPES vocabulary
//   (d) ids are unique across the manifest
//   (e) every deps[] entry references an existing item id
//   (f) probe descriptor shape matches its type's contract (below) — closed
//       shapes: unknown/extra fields are a lint error, same as missing ones.
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

const KINDS = ['hook', 'plugin', 'dep', 'wiring', 'vault', 'scheduler', 'lane', 'mcp'];
const PROBE_TYPES = ['file-exists', 'settings-key', 'settings-hooks', 'cmd:has_qmd', 'qmd-index', 'mcp-registered', 'handover-dir', 'dep'];
const ITEM_KEYS = ['id', 'kind', 'scopes', 'profiles', 'deps', 'probe'];

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

    // (a) exactly the six keys.
    const keys = Object.keys(it);
    const missing = ITEM_KEYS.filter((k) => !keys.includes(k));
    const extra = keys.filter((k) => !ITEM_KEYS.includes(k));
    if (missing.length > 0 || extra.length > 0) {
      errors.push(`${label}: expected exactly keys [${ITEM_KEYS.join(', ')}], missing=[${missing.join(', ')}] extra=[${extra.join(', ')}]`);
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
