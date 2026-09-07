'use strict';
// scripts/himmelctl/lib/luna-config.js — engine module owning the adopter's
// shared config document at ~/.himmel/config.json (HIMMEL-2176 externalization
// Stage 1 PR-B, design §3.3 / assumption A13). This is NOT himmelctl's own
// private state cache (that's lib/state.js's <cacheDir()>/state.json, under
// ~/.claude/himmel/) — this document belongs to the adopter's luna+bridge
// subsystems, at ~/.himmel/, the SAME per-subsystem data-dir convention as
// ~/.himmel/quota-gauge.jsonl, ~/.himmel/flow-runs.jsonl and ~/.himmel/voice/
// (see e.g. scripts/lib/quota-gauge-ledger-path.sh). That's deliberate, not
// a mistake to "fix" toward ~/.claude/himmel/.
//
// Design constraints this module enforces, and why:
//   - ZERO new npm dependencies: only Node builtins + relative requires.
//   - No JSON-schema library. validateConfig() below is a hand-rolled,
//     table-driven, closed-shape walker in the style of
//     scripts/install/manifest-lint.mjs's checkProbeShape() — a declarative
//     SCHEMA tree, not a wall of hand-written `if`s.
//   - Trust-bearing artifacts (access.json, .salus, phi-roots, egress
//     denylists) are REFERENCED, never embedded/written here (design A8.1):
//     phi.declared records the adopter's yes/no ANSWER, nothing more.
//   - Secret material is never written into this document (design A8.2):
//     bridge.envPath is a PATH to the bridge's own .env; the bot token
//     itself never appears here.
//   - A schedule is canonically {time: "HH:MM" local, day?: MON..SUN} —
//     weekly when `day` is present, daily otherwise (design A9).
//
// API: load() (read + validate + migrate), save() (write-to-temp ->
// validate -> atomic rename -> keep ONE timestamped .bak), migrate() (pure
// vN->vN+1 functions; an unknown FUTURE version throws loudly and writes
// nothing).
//
// HIMMEL_LUNA_CONFIG_PATH overrides the resolved file path (explicit
// override, matches the shell-side single-file convention in e.g.
// scripts/lib/quota-gauge-ledger-path.sh's HIMMEL_QUOTA_GAUGE_LEDGER) — the
// seam hermetic tests use so they never touch the real
// ~/.himmel/config.json.

const fs = require('fs');
const os = require('os');
const path = require('path');

const CURRENT_VERSION = 1;

function configPath() {
  if (process.env.HIMMEL_LUNA_CONFIG_PATH) return process.env.HIMMEL_LUNA_CONFIG_PATH;
  return path.join(os.homedir(), '.himmel', 'config.json');
}

// The schema-shaped default when no config.json exists yet (first run) —
// mirrors lib/state.js's emptyState(). Values match design §3.3 exactly.
function defaultConfig() {
  return {
    version: CURRENT_VERSION,
    luna: {
      vaultPath: path.join(os.homedir(), 'Documents', 'luna'),
      cadence: {
        enabled: false,
        schedules: {
          fetchHealth: { time: '01:30' },
          harvest: { time: '02:00' },
          synthesize: { time: '03:00' },
          health: { time: '04:00', day: 'SUN' },
        },
        models: { harvest: 'sonnet', synthesize: 'sonnet', health: 'haiku' },
      },
      phi: { declared: false },
    },
    bridge: {
      enabled: false,
      envPath: '~/.claude/channels/telegram/.env',
      whisper: { cli: null, model: 'ggml-small.bin' },
    },
  };
}

// ── Schema (table-driven validator, no JSON-schema dependency) ─────────────
//
// checkNode() walks `value` against a declarative SCHEMA tree, pushing one
// message per violation into `errors`. Every 'object' node is CLOSED — an
// extra key not named in its `fields` is a validation error, the same
// closed-shape treatment manifest-lint.mjs applies to manifest items/probes.
// Every field is required unless `optional: true` (the only optional field
// in the whole v1 document is a schedule's `day` — daily-vs-weekly, A9).

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const DAY_ENUM = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

function scheduleFieldSpec() {
  return {
    type: 'object',
    fields: {
      time: { type: 'time' },
      day: { type: 'enum', values: DAY_ENUM, optional: true },
    },
  };
}

const SCHEMA = {
  type: 'object',
  fields: {
    version: { type: 'exact', value: CURRENT_VERSION },
    luna: {
      type: 'object',
      fields: {
        vaultPath: { type: 'string' },
        cadence: {
          type: 'object',
          fields: {
            enabled: { type: 'boolean' },
            schedules: {
              type: 'object',
              fields: {
                fetchHealth: scheduleFieldSpec(),
                harvest: scheduleFieldSpec(),
                synthesize: scheduleFieldSpec(),
                health: scheduleFieldSpec(),
              },
            },
            models: {
              type: 'object',
              fields: {
                harvest: { type: 'string' },
                synthesize: { type: 'string' },
                health: { type: 'string' },
              },
            },
          },
        },
        phi: {
          type: 'object',
          // A8.1: `declared` records the adopter's yes/no ANSWER to the PHI
          // question — never a path to the checklist, never vault contents.
          fields: { declared: { type: 'boolean' } },
        },
      },
    },
    bridge: {
      type: 'object',
      fields: {
        enabled: { type: 'boolean' },
        // A8.2: a PATH to the bridge's own .env, never the token value.
        envPath: { type: 'string' },
        whisper: {
          type: 'object',
          fields: {
            cli: { type: 'stringOrNull' },
            model: { type: 'string' },
          },
        },
      },
    },
  },
};

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function checkNode(value, spec, label, errors) {
  switch (spec.type) {
    case 'object': {
      if (!isPlainObject(value)) {
        errors.push(`${label}: must be an object`);
        return;
      }
      const allowed = Object.keys(spec.fields);
      for (const key of allowed) {
        const fieldSpec = spec.fields[key];
        if (!Object.prototype.hasOwnProperty.call(value, key)) {
          if (!fieldSpec.optional) errors.push(`${label}.${key}: missing required field`);
          continue;
        }
        checkNode(value[key], fieldSpec, `${label}.${key}`, errors);
      }
      const extra = Object.keys(value).filter((k) => !allowed.includes(k));
      if (extra.length > 0) errors.push(`${label}: unexpected field(s) [${extra.join(', ')}]`);
      break;
    }
    case 'string':
      if (typeof value !== 'string') errors.push(`${label}: must be a string (got ${JSON.stringify(value)})`);
      break;
    case 'boolean':
      if (typeof value !== 'boolean') errors.push(`${label}: must be a boolean (got ${JSON.stringify(value)})`);
      break;
    case 'stringOrNull':
      if (value !== null && typeof value !== 'string') errors.push(`${label}: must be a string or null (got ${JSON.stringify(value)})`);
      break;
    case 'exact':
      if (value !== spec.value) errors.push(`${label}: must be exactly ${JSON.stringify(spec.value)} (got ${JSON.stringify(value)})`);
      break;
    case 'time':
      if (typeof value !== 'string' || !TIME_RE.test(value)) errors.push(`${label}: must be an "HH:MM" 24h local-time string (got ${JSON.stringify(value)})`);
      break;
    case 'enum':
      if (!spec.values.includes(value)) errors.push(`${label}: must be one of [${spec.values.join(', ')}] (got ${JSON.stringify(value)})`);
      break;
    /* istanbul ignore next -- every SCHEMA leaf above is a known type */
    default:
      errors.push(`${label}: <internal> unknown schema node type '${spec.type}'`);
  }
}

// Validate `doc` against the v1 schema; returns an array of error strings
// (empty = valid). Never throws — callers decide what a non-empty result
// means (load()/save() both turn it into a thrown Error naming the file).
function validateConfig(doc) {
  const errors = [];
  checkNode(doc, SCHEMA, '$', errors);
  return errors;
}

// ── Migration ────────────────────────────────────────────────────────────
//
// Pure vN -> vN+1 functions, keyed by the FROM version. Empty today — v1 is
// the only schema version design §3.3 defines. This is the seam future
// migrations hang off: one pure function per version bump, each returning a
// NEW object (never mutating its input) with `version` incremented by
// exactly one, so migrate()'s loop can walk multiple hops in sequence.
const MIGRATIONS = {
  // 1: (doc) => ({ ...doc, version: 2, ... }),
};

// Walk `doc.version` up to CURRENT_VERSION via MIGRATIONS. A version this
// build has no migration step for — including any version NEWER than
// CURRENT_VERSION, e.g. a config written by a future himmelctl — throws
// loudly naming the offending file, rather than silently truncating or
// guessing at a shape it doesn't understand. Callers (load()) must not
// persist anything when this throws.
function migrate(doc, filePath) {
  // CR round 7 fix (HIMMEL-2176, retask stage1-build-6d2e): a parsed document
  // that is valid JSON but not an object (null, an array, a bare number or
  // string all parse fine) used to reach `current.version` below and throw an
  // unhelpful TypeError instead of this module's named, file-identifying
  // error style. `typeof null === 'object'` also makes a naive typeof check
  // insufficient here — isPlainObject() already excludes both null and arrays.
  if (!isPlainObject(doc)) {
    throw new Error(`luna-config: ${filePath} does not contain a config object (got ${JSON.stringify(doc)}) (HIMMEL-2176)`);
  }
  let current = doc;
  let hops = 0;
  while (current.version < CURRENT_VERSION) {
    const step = MIGRATIONS[current.version];
    if (!step) {
      throw new Error(`luna-config: no migration path from version ${current.version} in ${filePath} (HIMMEL-2176)`);
    }
    current = step(current);
    hops += 1;
    if (hops > 100) {
      throw new Error(`luna-config: migration did not converge for ${filePath} after ${hops} hops (HIMMEL-2176)`);
    }
  }
  if (current.version > CURRENT_VERSION) {
    throw new Error(
      `luna-config: ${filePath} declares version ${current.version}, newer than the highest version `
      + `this himmelctl build understands (${CURRENT_VERSION}) — HIMMEL-2176; upgrade himmelctl before touching this file`
    );
  }
  return current;
}

// ── Load / Save ──────────────────────────────────────────────────────────

// Read, validate and migrate the on-disk config, or the schema-shaped
// default when no config.json exists yet (first run). A malformed file
// surfaces its parse/validation error naming the file path rather than
// silently resetting to default — this is the adopter's own artifact, and a
// corrupt copy should be investigated, not discarded (mirrors lib/state.js's
// load() policy for state.json). Never writes.
function load() {
  const p = configPath();
  if (!fs.existsSync(p)) return defaultConfig();

  const raw = fs.readFileSync(p, 'utf8');
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (err) {
    throw new Error(`luna-config: malformed JSON in ${p}: ${err.message} (HIMMEL-2176)`);
  }

  const migrated = migrate(doc, p);

  const errors = validateConfig(migrated);
  if (errors.length > 0) {
    throw new Error(`luna-config: ${p} fails schema validation (HIMMEL-2176):\n  - ${errors.join('\n  - ')}`);
  }
  return migrated;
}

// Keep exactly ONE timestamped .bak of the file currently at `p` (design:
// "keep ONE timestamped .bak", not an accumulating history) — pruning any
// earlier backups for this same config path before writing a fresh one.
// Called BEFORE the temp-write/rename below so a crash in that window still
// leaves a usable .bak next to an untouched original (V7 atomic-write-
// interruption case).
function backupExisting(p) {
  const dir = path.dirname(p);
  const base = path.basename(p);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const freshName = `${base}.bak-${stamp}`;
  const freshPath = path.join(dir, freshName);
  // CR round 7 fix (HIMMEL-2176, retask stage1-build-6d2e): the fresh backup
  // used to be created AFTER pruning every existing `.bak-*` — if
  // copyFileSync then failed (ENOSPC, permissions, a locked file) the
  // adopter was left with no backup at all, in exactly the failure scenarios
  // where the backup matters most. Creating the fresh copy first means a
  // copyFileSync failure here still leaves whatever backup already existed
  // untouched, and propagates uncaught so save() aborts as it does today.
  //
  // CR round 11 fix (HIMMEL-2176, retask stage1-build-6d2e): `freshPath` is
  // JUST as predictable ahead of time as save()'s pid-named tmp path is —
  // timestamp-based rather than pid-based, but a plain copyFileSync still
  // followed whatever already sat there, symlink or not. `COPYFILE_EXCL`
  // closes it the same way `{ flag: 'wx' }` already closes it on the temp
  // path a few lines below: it's backed by open()'s O_CREAT|O_EXCL (and, on
  // Windows, CopyFileW's fail-if-exists parameter), not a stat-then-write
  // race, so it refuses ANYTHING already at freshPath rather than writing
  // through a pre-planted symlink. A symlink at freshPath is refused outright
  // and left untouched (see the lstat check below); a plain regular file —
  // the same-timestamp collision this stamp's granularity can produce, e.g.
  // two saves under a mocked clock in tests — is a stale backup from an
  // earlier save at this exact timestamp string, not a copy of today's `p`,
  // and refreshing it to today's content is correct.
  //
  // CR round 12 fix (HIMMEL-2176, retask stage1-build-6d2e): round 11
  // resolved that plain-file collision with unlink-then-copy — remove the
  // stale file at freshPath, then retry the copy at that SAME name. If the
  // retry then failed (ENOSPC, permissions, a transient I/O error), the
  // adopter was left with ZERO backups: the stale one already destroyed, no
  // replacement ever written. That's the exact defect round 7 above closed
  // one layer up, reintroduced inside this EEXIST branch. The fix: never
  // destroy freshPath before its replacement exists. The replacement is
  // copied to a staging path that cannot collide with freshPath — pid-suffixed,
  // the same convention save()'s own `.tmp-${pid}` uses below — so the stale
  // file sits untouched on disk for the ENTIRE duration of that copy, and
  // only once it has landed successfully is freshPath replaced, via a single
  // atomic renameSync rather than a remove-then-create window. There is no
  // instant on any path through this branch with zero backups on disk, and a
  // successful refresh still leaves exactly one file at the predictable
  // `freshName` the prune loop below (and every caller) key on — renameSync
  // overwrites freshPath in place rather than adding a second file beside it.
  try {
    fs.copyFileSync(p, freshPath, fs.constants.COPYFILE_EXCL);
  } catch (err) {
    if (err.code !== 'EEXIST') throw err;
    if (fs.lstatSync(freshPath).isSymbolicLink()) {
      throw new Error(`luna-config: a symlink already exists at ${freshPath} — refusing to back up through it (HIMMEL-2176)`);
    }
    const stagePath = `${freshPath}.stage-${process.pid}`;
    // `stageRemovalRefused` mirrors save()'s own `tmpRemovalRefused` below —
    // a symlink at stagePath is refused and left untouched, so the cleanup
    // in the outer catch must not be the thing that unlinks it.
    let stageRemovalRefused = false;
    try {
      try {
        fs.copyFileSync(p, stagePath, fs.constants.COPYFILE_EXCL);
      } catch (stageErr) {
        if (stageErr.code !== 'EEXIST') throw stageErr;
        if (fs.lstatSync(stagePath).isSymbolicLink()) {
          stageRemovalRefused = true;
          throw new Error(`a symlink already exists at ${stagePath} — refusing to stage the replacement backup through it`);
        }
        fs.unlinkSync(stagePath);
        fs.copyFileSync(p, stagePath, fs.constants.COPYFILE_EXCL);
      }
    } catch (stageFailure) {
      if (!stageRemovalRefused) removeTempBestEffort(stagePath);
      throw new Error(`luna-config: refusing to refresh the backup at ${freshPath} — staging copy to ${stagePath} failed: ${stageFailure.message} (HIMMEL-2176)`);
    }
    // CR fix (HIMMEL-2176, retask stage1-build-6d2e): renameSync used to sit
    // OUTSIDE the cleanup handling — a failed rename (locked/permission-denied
    // destination) left the PID-named staging file behind, contradicting
    // backupExisting()'s own contract that staging failures clean up after
    // themselves. Mirrors save()'s own rename-with-cleanup fix a few lines
    // below, honoring stageRemovalRefused to avoid unintentionally touching
    // a symlink that was deliberately refused.
    try {
      fs.renameSync(stagePath, freshPath);
    } catch (err) {
      if (!stageRemovalRefused) removeTempBestEffort(stagePath);
      throw new Error(`luna-config: refusing to refresh the backup at ${freshPath} — rename from ${stagePath} failed: ${err.message} (HIMMEL-2176)`);
    }
  }
  // Prune everything ELSE named `${base}.bak-*`. Excluding `freshName` by
  // name (not just "the last one written") matters on the collision edge:
  // two saves within the same timestamp-string granularity would make
  // copyFileSync above silently overwrite an already-present same-named
  // backup, and pruning by name still leaves exactly that one file standing
  // rather than deleting the copy just written.
  for (const f of fs.readdirSync(dir)) {
    if (f.startsWith(`${base}.bak-`) && f !== freshName) fs.unlinkSync(path.join(dir, f));
  }
}

// Best-effort delete of our own temp file. Every cleanup call site below is
// about to throw its OWN, informative error naming what actually went wrong
// (a bad shape, a failed rename, a failed write) — an unguarded unlinkSync
// racing against the file already being gone (or a permission flip) would
// replace that informative error with a raw, unrelated one instead of just
// leaving the original error to surface. existsSync + a swallowed catch keep
// this step from ever becoming the reported failure itself.
function removeTempBestEffort(tmp) {
  try {
    if (fs.existsSync(tmp)) fs.unlinkSync(tmp);
  } catch (_e) {
    // best-effort — whatever error triggered this cleanup is what gets thrown.
  }
}

// Persist `doc`: write-to-temp -> validate -> atomic rename -> keep ONE
// timestamped .bak. Validates what was actually SERIALIZED to the temp file
// (re-read + re-parsed), not just the in-memory object, so a shape defect
// introduced by JSON.stringify itself (e.g. a dropped `undefined`) is caught
// before it ever reaches the real config path. On ANY failure (bad shape,
// interrupted write, OR a failed rename — e.g. a locked/permission-denied
// destination) the temp file is cleaned up and the ORIGINAL file is left
// completely untouched — fs.renameSync is the only step that can make the
// new content visible at `p`, and it only runs after validation passes.
function save(doc) {
  const p = configPath();
  const dir = path.dirname(p);
  fs.mkdirSync(dir, { recursive: true });

  if (fs.existsSync(p)) backupExisting(p);

  const tmp = `${p}.tmp-${process.pid}`;
  // CR round 3 fix (HIMMEL-2176, retask stage1-build-6d2e): the write itself
  // used to sit OUTSIDE the cleanup handling below — a failure mid-write
  // (ENOSPC, permission-denied) could still leave a partial tmp file behind,
  // the same "cleaned up on any failure" contract gap codex-5's rename fix
  // (below) already closed for the rename step. removeTempBestEffort()'s own
  // existsSync guard covers a write that fails before the file is ever
  // created at all, same as it covers every other cleanup call site below.
  //
  // CR round 5 fix (HIMMEL-2176, retask stage1-build-6d2e): `tmp` is a
  // PREDICTABLE path (pid-based), and a plain writeFileSync follows whatever
  // already sits there — including a symlink an attacker pre-planted, which
  // would redirect this write into an arbitrary target. `{ flag: 'wx' }`
  // (O_CREAT|O_EXCL) makes existence-check-and-create atomic at the OS level:
  // open() fails on ANYTHING already at `tmp`, symlink or not, and never
  // follows one. EEXIST is then resolved with an lstat (never followed, so
  // it reports the entry itself) to tell apart the two cases that can
  // produce it: a symlink is refused outright and left untouched — an
  // attacker can always recreate it, but this function will never silently
  // write through one — while a plain regular file (a stale leftover from a
  // previous crashed save() run, e.g. the same pid reused) is safe to remove
  // and the write retried exactly once, so a crash doesn't wedge every
  // future save() with a permanent EEXIST.
  //
  // CR round 9 fix (HIMMEL-2176, retask stage1-build-6d2e): a `tmpIsOurs`
  // flag used to gate cleanup and was only set true AFTER writeFileSync
  // RETURNED — a partial write (ENOSPC, an I/O error mid-flush) has O_EXCL
  // succeed in CREATING the file before the write/flush portion throws, so
  // `tmpIsOurs` stayed false and cleanup skipped the very file it had just
  // created, leaking it. Ownership doesn't actually need a flag for that
  // case: O_CREAT|O_EXCL guarantees that any non-EEXIST failure means
  // nothing else could have raced us onto `tmp`, so whatever now exists
  // there is unconditionally ours to remove. `tmpRemovalRefused` names the
  // ONE case cleanup must still skip — the pre-planted symlink, refused and
  // left alone on purpose because it was never ours to touch, not leaked by
  // omission.
  let tmpRemovalRefused = false;
  try {
    try {
      fs.writeFileSync(tmp, JSON.stringify(doc, null, 2) + '\n', { flag: 'wx' });
    } catch (err) {
      if (err.code !== 'EEXIST') throw err;
      if (fs.lstatSync(tmp).isSymbolicLink()) {
        tmpRemovalRefused = true;
        throw new Error(`a symlink already exists at ${tmp} — refusing to write through it`);
      }
      fs.unlinkSync(tmp);
      fs.writeFileSync(tmp, JSON.stringify(doc, null, 2) + '\n', { flag: 'wx' });
    }
  } catch (err) {
    if (!tmpRemovalRefused) removeTempBestEffort(tmp);
    throw new Error(`luna-config: refusing to save ${p} — write to ${tmp} failed: ${err.message} (HIMMEL-2176)`);
  }

  let written;
  try {
    written = JSON.parse(fs.readFileSync(tmp, 'utf8'));
  } catch (err) {
    removeTempBestEffort(tmp);
    throw new Error(`luna-config: internal error — just-written ${tmp} failed to parse: ${err.message} (HIMMEL-2176)`);
  }
  const errors = validateConfig(written);
  if (errors.length > 0) {
    removeTempBestEffort(tmp);
    throw new Error(`luna-config: refusing to save ${p} — schema violation(s) (HIMMEL-2176):\n  - ${errors.join('\n  - ')}`);
  }

  // CR fix (HIMMEL-2176, codex-5): renameSync used to sit OUTSIDE the
  // cleanup handling — a failed rename (locked/permission-denied
  // destination) left the PID-named temp file behind, contradicting this
  // function's own "temp file is cleaned up on any failure" contract above.
  try {
    fs.renameSync(tmp, p);
  } catch (err) {
    removeTempBestEffort(tmp);
    throw new Error(`luna-config: refusing to save ${p} — rename from ${tmp} failed: ${err.message} (HIMMEL-2176)`);
  }
}

module.exports = { load, save, migrate, validateConfig, defaultConfig, configPath, CURRENT_VERSION };
