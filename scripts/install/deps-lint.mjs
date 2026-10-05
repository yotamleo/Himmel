#!/usr/bin/env node
// scripts/install/deps-lint.mjs — validates scripts/install/deps.json
// (HIMMEL-759). Sibling to manifest-lint.mjs, same closed-shape discipline,
// deliberately much smaller: deps.json is a flat toolchain declaration with
// no dependency graph, no scopes/profiles, no probe-type vocabulary — see
// deps.json's own header comment and scripts/himmelctl/lib/deps-engine.js
// for why it's a separate, simpler artifact from manifest.json.
//
// Checks per dep:
//   (a) exactly the six required keys (id, cmd, versionProbe, minVersion,
//       bootstrap, install) plus the optional 'resolver' key.
//   (b) versionProbe is an object with 'args' (non-empty string array).
//   (c) minVersion is null or a dotted-version string (x.y or x.y.z).
//   (d) bootstrap is a boolean.
//   (e) install has EXACTLY the three keys linux/macos/win32, each a recipe
//       object whose shape matches its 'manager' (below).
//   (f) ids are unique.
//
// Per-manager recipe shape:
//   manager        | fields (all required unless noted)
//   ---------------|--------------------------------------------------
//   ensure-tools   | (none — dispatches via ensure_tools(dep.cmd))
//   brew           | pkg: non-empty string
//   winget         | id: string
//   pip            | pkg: non-empty string
//   script         | script: non-empty string; args: string[] (optional, default [])
//   hint           | detail: string
//
// Usage:
//   node scripts/install/deps-lint.mjs [path-to-deps.json]
// Defaults to deps.json next to this script; override via a CLI arg
// (argv[2]) or the DEPS_PATH env var (CLI arg wins), same seam convention
// as manifest-lint.mjs's MANIFEST_PATH.
//
// Exits 0 on a clean file; exits 1 and prints one message per violation
// otherwise.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const TOP_LEVEL_KEYS = ['schemaVersion', 'deps'];
const OPTIONAL_TOP_LEVEL_KEYS = ['_comment'];
const DEP_KEYS = ['id', 'cmd', 'versionProbe', 'minVersion', 'bootstrap', 'install'];
const OPTIONAL_DEP_KEYS = ['resolver'];
const OS_KEYS = ['linux', 'macos', 'win32'];
const MANAGERS = ['ensure-tools', 'brew', 'winget', 'pip', 'script', 'hint'];

function resolveDepsPath() {
  const argPath = process.argv[2];
  if (argPath) return path.resolve(argPath);
  if (process.env.DEPS_PATH) return path.resolve(process.env.DEPS_PATH);
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.join(here, 'deps.json');
}

function isNonEmptyStringArray(v) {
  return Array.isArray(v) && v.length > 0 && v.every((x) => typeof x === 'string');
}

// Like isNonEmptyStringArray, but an empty array is also valid — for
// 'script' recipe's optional 'args' (default []), an explicit `args: []` is
// the same as omitting it, so it must lint clean too.
function isStringArray(v) {
  return Array.isArray(v) && v.every((x) => typeof x === 'string');
}

// A recipe/resolver identifier (pkg, script, resolver) must be a non-empty,
// non-whitespace string — an empty or whitespace-only value names no
// package/script/path to install, a real declaration bug, not a valid
// default. Distinct from isStringArray above, which intentionally accepts an
// EMPTY args array.
function isNonBlankString(v) {
  return typeof v === 'string' && v.trim() !== '';
}

function checkRecipe(recipe, label, osKey, errors) {
  if (!recipe || typeof recipe !== 'object' || Array.isArray(recipe)) {
    errors.push(`${label}: install.${osKey} must be an object`);
    return;
  }
  const manager = recipe.manager;
  if (!MANAGERS.includes(manager)) {
    errors.push(`${label}: install.${osKey}.manager '${manager}' not in [${MANAGERS.join(', ')}]`);
    return;
  }
  const otherKeys = Object.keys(recipe).filter((k) => k !== 'manager');
  const reportExtra = (allowed) => {
    const ex = otherKeys.filter((k) => !allowed.includes(k));
    if (ex.length > 0) errors.push(`${label}: install.${osKey} manager '${manager}' has unexpected field(s) [${ex.join(', ')}]`);
  };
  switch (manager) {
    case 'ensure-tools':
      reportExtra([]);
      break;
    case 'brew':
      if (!isNonBlankString(recipe.pkg)) errors.push(`${label}: install.${osKey} manager 'brew' requires 'pkg' (non-empty string)`);
      reportExtra(['pkg']);
      break;
    case 'winget':
      if (!isNonBlankString(recipe.id)) errors.push(`${label}: install.${osKey} manager 'winget' requires 'id' (non-empty string)`);
      reportExtra(['id']);
      break;
    case 'pip':
      if (!isNonBlankString(recipe.pkg)) errors.push(`${label}: install.${osKey} manager 'pip' requires 'pkg' (non-empty string)`);
      reportExtra(['pkg']);
      break;
    case 'script':
      if (!isNonBlankString(recipe.script)) errors.push(`${label}: install.${osKey} manager 'script' requires 'script' (non-empty string)`);
      if (Object.prototype.hasOwnProperty.call(recipe, 'args') && !isStringArray(recipe.args)) {
        errors.push(`${label}: install.${osKey} manager 'script' field 'args', when present, must be an array of strings`);
      }
      reportExtra(['script', 'args']);
      break;
    case 'hint':
      if (typeof recipe.detail !== 'string') errors.push(`${label}: install.${osKey} manager 'hint' requires 'detail' (string)`);
      reportExtra(['detail']);
      break;
  }
}

function lint(doc) {
  const errors = [];
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) {
    errors.push('deps.json must be a JSON object');
    return errors;
  }

  const topKeys = Object.keys(doc);
  const topExtra = topKeys.filter((k) => !TOP_LEVEL_KEYS.includes(k) && !OPTIONAL_TOP_LEVEL_KEYS.includes(k));
  const topMissing = TOP_LEVEL_KEYS.filter((k) => !topKeys.includes(k));
  if (topExtra.length > 0 || topMissing.length > 0) {
    errors.push(`top level: expected exactly keys [${TOP_LEVEL_KEYS.join(', ')}] (+ optionally [${OPTIONAL_TOP_LEVEL_KEYS.join(', ')}]), missing=[${topMissing.join(', ')}] extra=[${topExtra.join(', ')}]`);
  }
  if (doc.schemaVersion !== 1) {
    errors.push(`top level: schemaVersion must be 1 (got ${JSON.stringify(doc.schemaVersion)})`);
  }

  const deps = Array.isArray(doc.deps) ? doc.deps : [];
  if (!Array.isArray(doc.deps)) errors.push("top level: 'deps' must be an array");

  for (const dep of deps) {
    if (dep === null || typeof dep !== 'object' || Array.isArray(dep)) {
      errors.push('dep entry must be an object');
      continue;
    }
    const label = dep.id || '<unknown id>';

    const keys = Object.keys(dep);
    const missing = DEP_KEYS.filter((k) => !keys.includes(k));
    const extra = keys.filter((k) => !DEP_KEYS.includes(k) && !OPTIONAL_DEP_KEYS.includes(k));
    if (missing.length > 0 || extra.length > 0) {
      errors.push(`${label}: expected exactly keys [${DEP_KEYS.join(', ')}] (+ optionally [${OPTIONAL_DEP_KEYS.join(', ')}]), missing=[${missing.join(', ')}] extra=[${extra.join(', ')}]`);
    }

    if (!isNonBlankString(dep.id)) errors.push(`${label}: 'id' must be a non-empty string`);
    if (!isNonBlankString(dep.cmd)) errors.push(`${label}: 'cmd' must be a non-empty string`);
    if (Object.prototype.hasOwnProperty.call(dep, 'resolver') && !isNonBlankString(dep.resolver)) {
      errors.push(`${label}: 'resolver', when present, must be a non-empty string`);
    }

    if (!dep.versionProbe || typeof dep.versionProbe !== 'object' || Array.isArray(dep.versionProbe)) {
      errors.push(`${label}: 'versionProbe' must be an object`);
    } else {
      const vpKeys = Object.keys(dep.versionProbe);
      if (vpKeys.some((k) => k !== 'args')) errors.push(`${label}: 'versionProbe' must contain only 'args'`);
      if (!isNonEmptyStringArray(dep.versionProbe.args)) errors.push(`${label}: versionProbe.args must be a non-empty array of strings`);
    }

    if (dep.minVersion !== null && !(typeof dep.minVersion === 'string' && /^\d+\.\d+(\.\d+)?$/.test(dep.minVersion))) {
      errors.push(`${label}: 'minVersion' must be null or a dotted version string (x.y or x.y.z), got ${JSON.stringify(dep.minVersion)}`);
    }

    if (typeof dep.bootstrap !== 'boolean') errors.push(`${label}: 'bootstrap' must be a boolean`);

    if (!dep.install || typeof dep.install !== 'object' || Array.isArray(dep.install)) {
      errors.push(`${label}: 'install' must be an object`);
    } else {
      const instKeys = Object.keys(dep.install);
      const instMissing = OS_KEYS.filter((k) => !instKeys.includes(k));
      const instExtra = instKeys.filter((k) => !OS_KEYS.includes(k));
      if (instMissing.length > 0 || instExtra.length > 0) {
        errors.push(`${label}: 'install' must have exactly keys [${OS_KEYS.join(', ')}], missing=[${instMissing.join(', ')}] extra=[${instExtra.join(', ')}]`);
      }
      for (const osKey of OS_KEYS) {
        if (Object.prototype.hasOwnProperty.call(dep.install, osKey)) {
          checkRecipe(dep.install[osKey], label, osKey, errors);
        }
      }
    }
  }

  const seen = new Set();
  for (const dep of deps) {
    const id = dep && dep.id;
    if (seen.has(id)) errors.push(`duplicate dep id: '${id}'`);
    seen.add(id);
  }

  return errors;
}

function main() {
  const depsPath = resolveDepsPath();
  const raw = readFileSync(depsPath, 'utf8');
  const doc = JSON.parse(raw);
  const errors = lint(doc);
  if (errors.length > 0) {
    console.error(`deps-lint: ${errors.length} violation(s) in ${depsPath}`);
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }
  const deps = Array.isArray(doc.deps) ? doc.deps : [];
  console.log(`deps-lint: OK (${deps.length} deps) — ${depsPath}`);
  process.exit(0);
}

main();
