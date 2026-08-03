#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const WRAPPER = 'guardrail-skip-in-himmel.js';
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));

export const GUARDRAILS = [
  { basename: 'auto-approve-safe-bash.sh', matcher: 'Bash' },
  { basename: 'block-edit-on-main.sh', matcher: 'Edit|Write|MultiEdit|NotebookEdit' },
  { basename: 'block-read-secrets.sh', matcher: 'Bash|PowerShell|Read|Grep' },
];

// HIMMEL-1422: single source of truth for the guardrail-block "trust
// anchor" — the himmel checkout whose scripts/hooks/ copies of the wrapper
// + guardrail scripts are treated as authoritative. HIMMEL_REPO (env), when
// set, names it explicitly (multi-checkout installs, e.g. a global install
// pointing at a non-default clone); otherwise it falls back to the checkout
// this guardrail-block.mjs is itself running from (self-checkout —
// import.meta.url, not cwd, so it's correct regardless of invocation dir).
// install()/global bake the anchor's own scripts/hooks/ paths into the
// generated command (repoRoot() below); statusDetail()'s status --json
// reuses the SAME anchor to realpath-compare whatever is ACTUALLY wired
// against it, so drift (settings.json baked from a different/stale
// checkout, or a same-basename file dropped in an unrelated directory) is
// detectable even though ownsGuardrail() stays basename-only by design
// (codex-adv-5) — the anchor check is a SEPARATE, additive signal, not a
// change to ownership semantics.
function resolveAnchor() {
  const envRepo = process.env.HIMMEL_REPO;
  if (envRepo) return { repo: path.resolve(envRepo), source: 'HIMMEL_REPO' };
  return { repo: path.resolve(path.join(MODULE_DIR, '..', '..')), source: 'self-checkout' };
}

function resolveAuditAnchor(ctx = {}) {
  if (ctx.repoRoot) return { repo: path.resolve(ctx.repoRoot), source: 'ctx.repoRoot' };
  return { repo: path.resolve(path.join(MODULE_DIR, '..', '..')), source: 'self-checkout' };
}

function repoRoot() {
  return resolveAnchor().repo;
}

function settingsPath() {
  return process.env.CLAUDE_USER_SETTINGS || path.join(os.homedir(), '.claude', 'settings.json');
}

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--node' || arg === '--bash' || arg === '--stamp') {
      if (i + 1 >= argv.length) throw new Error(`${arg} requires a value`);
      args[arg.slice(2)] = argv[i + 1];
      i += 1;
    } else if (arg === '--json') {
      args.json = true;
    } else {
      args._.push(arg);
    }
  }
  return args;
}

function readSettings(file) {
  const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '{}';
  return { text, data: JSON.parse(text || '{}') };
}

function ensureHookRoot(data) {
  if (!data.hooks || typeof data.hooks !== 'object' || Array.isArray(data.hooks)) data.hooks = {};
  if (!Array.isArray(data.hooks.PreToolUse)) data.hooks.PreToolUse = [];
  return data.hooks.PreToolUse;
}

function hookGroups(data) {
  const groups = data?.hooks?.PreToolUse;
  return Array.isArray(groups) ? groups : [];
}

function isOwnedHook(hook, basename) {
  const command = hook?.command;
  if (typeof command !== 'string') return false;
  if (!command.includes(WRAPPER)) return false;
  return basename ? command.includes(basename) : true;
}

function commandFor({ nodePath, bashPath, himmelRepo, basename }) {
  const wrapper = path.join(himmelRepo, 'scripts', 'hooks', WRAPPER);
  const script = path.join(himmelRepo, 'scripts', 'hooks', basename);
  return `GUARDRAIL_BASH=${JSON.stringify(bashPath)} ${JSON.stringify(nodePath)} ${JSON.stringify(wrapper)} ${JSON.stringify(script)}`;
}

function desiredHook(opts, guardrail) {
  return {
    type: 'command',
    command: commandFor({ ...opts, basename: guardrail.basename }),
  };
}

function installData(data, opts) {
  const groups = ensureHookRoot(data);

  for (const guardrail of GUARDRAILS) {
    // Remove EVERY existing owned hook for this guardrail (dedups stale copies),
    // remembering the first group that held one so the fresh entry stays in its
    // established place. Rebuilding each group's hooks array avoids the
    // splice-invalidates-a-saved-index bug that let a duplicate survive.
    let homeGroup = null;
    for (const group of groups) {
      if (!Array.isArray(group.hooks)) continue;
      const kept = [];
      for (const hook of group.hooks) {
        if (isOwnedHook(hook, guardrail.basename)) {
          if (!homeGroup) homeGroup = group;
        } else {
          kept.push(hook);
        }
      }
      group.hooks = kept;
    }

    // Place exactly ONE fresh entry: back in its home group if it had one, else
    // an existing matcher group, else a new one.
    let targetGroup = homeGroup
      || groups.find((group) => group.matcher === guardrail.matcher && Array.isArray(group.hooks));
    if (!targetGroup) {
      targetGroup = { matcher: guardrail.matcher, hooks: [] };
      groups.push(targetGroup);
    }
    targetGroup.hooks.push(desiredHook(opts, guardrail));
  }

  data.hooks.PreToolUse = groups.filter((group) => !Array.isArray(group.hooks) || group.hooks.length > 0);
  return data;
}

function removeData(data) {
  const groups = hookGroups(data);
  for (const group of groups) {
    if (!Array.isArray(group.hooks)) continue;
    group.hooks = group.hooks.filter((hook) => !isOwnedHook(hook));
  }
  if (data?.hooks && Array.isArray(data.hooks.PreToolUse)) {
    data.hooks.PreToolUse = data.hooks.PreToolUse.filter((group) => !Array.isArray(group.hooks) || group.hooks.length > 0);
  }
  return data;
}

function stringify(data) {
  return `${JSON.stringify(data, null, 2)}\n`;
}

function backupPath(file, stamp) {
  const base = `${file}.${stamp}.bak`;
  if (!fs.existsSync(base)) return base;
  for (let i = 1; ; i += 1) {
    const candidate = `${base}.${i}`;
    if (!fs.existsSync(candidate)) return candidate;
  }
}

function atomicWrite(file, originalText, nextText, stamp) {
  if (nextText === originalText) return { wrote: false, backup: null };

  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true });
  const backup = backupPath(file, stamp || String(Date.now()));
  const temp = path.join(dir, `${path.basename(file)}.${process.pid}.tmp`);

  if (fs.existsSync(file)) fs.copyFileSync(file, backup);
  fs.writeFileSync(temp, nextText);
  JSON.parse(fs.readFileSync(temp, 'utf8'));
  fs.renameSync(temp, file);
  return { wrote: true, backup };
}

export function detectMode(data) {
  for (const group of hookGroups(data)) {
    if (!Array.isArray(group.hooks)) continue;
    if (group.hooks.some((hook) => isOwnedHook(hook))) return 'global';
  }
  return 'project';
}

export function install(data, opts) {
  return installData(data, opts);
}

export function remove(data) {
  return removeData(data);
}

function requireAbsolute(name, value) {
  if (!value) throw new Error(`--${name} is required`);
  if (!path.isAbsolute(value)) throw new Error(`--${name} must be absolute`);
}

function nodeResolves(data) {
  for (const group of hookGroups(data)) {
    if (!Array.isArray(group.hooks)) continue;
    for (const hook of group.hooks) {
      if (!isOwnedHook(hook)) continue;
      const command = hook.command.replace(/^GUARDRAIL_BASH="[^"]*"\s+/, '');
      const match = command.match(/^"([^"]+)"/);
      if (match) return fs.existsSync(match[1]);
    }
  }
  return false;
}

// commandFor() bakes EXACTLY `GUARDRAIL_BASH="<bash>" "<node>" "<wrapper>"
// "<script>"` — four double-quoted segments, nothing before or after. This
// is the inverse, but STRICT (CR fix, codex-adv-5): the `$` anchor requires
// the match to consume the WHOLE command string, so a trailing shell
// comment or any extra token after the 4th quoted segment fails the match
// entirely (returns null) rather than being silently ignored. Contrast with
// the pre-fix parseOwnedCommand(), which took the first three quoted
// segments off `rest` via matchAll and never checked what followed them —
// reproduced: a command whose real script arg is a decoy (e.g.
// "claude-stub.sh") with the guardrail's actual basename sitting in a
// trailing `# comment` still parsed "successfully" into 3 args, since the
// comment text was simply never looked at.
const GENERATED_COMMAND_RE = /^GUARDRAIL_BASH="([^"]*)"\s+"([^"]*)"\s+"([^"]*)"\s+"([^"]*)"\s*$/;

function parseGeneratedCommand(hook) {
  if (!hook || hook.type !== 'command' || typeof hook.command !== 'string') return null;
  const match = hook.command.match(GENERATED_COMMAND_RE);
  if (!match) return null;
  const [, bashPath, nodePath, wrapperPath, scriptPath] = match;
  return { bashPath, nodePath, wrapperPath, scriptPath };
}

// CR fix (codex-adv-5): ownership is IDENTITY, not mention. The pre-fix
// isOwnedHook() substring-searched the WHOLE command string for `basename`
// — matching a guardrail's name anywhere, including inside an inert
// trailing comment, while the actual (4th quoted) script argument pointed
// somewhere else entirely. This checks the PARSED wrapper/script paths'
// basenames against the expected constants exactly (path.basename(), never
// String#includes()) — a decoy command whose real script arg doesn't match
// `guardrail.basename` is not owned by this guardrail, full stop, no matter
// what a comment elsewhere in the string claims.
function ownsGuardrail(parsed, guardrail) {
  return Boolean(parsed)
    && path.basename(parsed.wrapperPath) === WRAPPER
    && path.basename(parsed.scriptPath) === guardrail.basename;
}

// Returns { hook, matcher, parsed } for EVERY owned entry matching
// `guardrail` (order = hookGroups() traversal order), keeping each entry's
// ENCLOSING group matcher alongside the hook itself — unlike isOwnedHook()
// above (used by installData()/removeData() for CLEANUP, where a loose
// substring match is the correct, DELIBERATE behavior: catching any
// hand-edited/stale hook that merely mentions the wrapper is a feature
// there, not a bug) — and unlike an earlier round's singular
// findOwnedHookInfo(), which returned only the FIRST match (CR fix,
// codex-adv-4: installData()'s own dedup step — "remove EVERY existing
// owned hook for this guardrail" — exists precisely because duplicate owned
// entries for the same basename are a real drift state; a second,
// dead-pathed duplicate is invisible to a probe that only ever looks at the
// first hit, even though it can still independently fire and fail closed at
// runtime). This is the STRICT counterpart used ONLY by the status --json
// attestation contract below — never by installData()/removeData(), whose
// loose cleanup semantics are unchanged and out of scope for this ticket.
function findGuardrailEntries(data, guardrail) {
  const found = [];
  for (const group of hookGroups(data)) {
    if (!Array.isArray(group.hooks)) continue;
    for (const hook of group.hooks) {
      const parsed = parseGeneratedCommand(hook);
      if (ownsGuardrail(parsed, guardrail)) found.push({ hook, matcher: group.matcher, parsed });
    }
  }
  return found;
}

// CR fix (codex-adv-7, round 5): round 4's ANCHORED GENERATED_COMMAND_RE
// correctly rejects a TRUE decoy (wrong script identity, real basename only
// in an inert trailing comment) — but it also makes an entry with the SAME
// wrapper/script identity plus a trailing extra token/comment invisible
// entirely, not merely "not canonical". That's wrong: guardrail-skip-in-
// himmel.js reads only process.argv[2] (the script path) and ignores
// anything after it, so Claude Code still executes such an entry
// identically to a canonical one — it is RUNTIME-RELEVANT. A duplicate
// wired in this shape with a dead node/bash path would fail closed on
// matching tool calls while sitting completely outside this contract's
// enumeration (entryCount would stay 1, complete:true), reopening exactly
// the blind spot round 3's duplicate detection was built to close, just
// through a different command shape.
//
// This is the BOUNDED structural test for "references our identity without
// being canonical": extract every double-quoted segment in the command
// (regardless of position — no `^`/`$` anchor, no fixed arg count) and
// check whether ANY of them, taken as a whole quoted VALUE and reduced with
// path.basename(), equals WRAPPER, and ANY (possibly a different one)
// equals guardrail.basename. This is deliberately NOT the old whole-string
// substring search (String#includes over the entire command) that codex-
// adv-5 fixed: a basename sitting in an unquoted trailing `# comment` is
// never captured by the quote-extraction regex at all, so it still reads as
// a decoy/not-owned, exactly preserving round 4's fix. Only an ACTUAL
// quoted path argument whose basename matches counts.
function referencesGuardrailIdentity(hook, guardrail) {
  if (!hook || hook.type !== 'command' || typeof hook.command !== 'string') return false;
  const quoted = [...hook.command.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
  const hasWrapper = quoted.some((q) => path.basename(q) === WRAPPER);
  const hasScript = quoted.some((q) => path.basename(q) === guardrail.basename);
  return hasWrapper && hasScript;
}

// Returns { hook, matcher } for every hook that references `guardrail`'s
// identity (wrapper + script basenames, as quoted arguments) but did NOT
// match the canonical generated shape in findGuardrailEntries() — i.e. the
// tier-2 "runtime-relevant but non-attestable" anomaly this fix exists to
// surface. A hook already counted as canonical is excluded here (it would
// otherwise be double-counted as its own anomaly, since a canonical command
// trivially also "references" its own identity).
function findNonCanonicalEntries(data, guardrail) {
  const found = [];
  for (const group of hookGroups(data)) {
    if (!Array.isArray(group.hooks)) continue;
    for (const hook of group.hooks) {
      if (ownsGuardrail(parseGeneratedCommand(hook), guardrail)) continue;
      if (referencesGuardrailIdentity(hook, guardrail)) found.push({ hook, matcher: group.matcher });
    }
  }
  return found;
}

// CR fix (codex-adv-3): fs.existsSync() alone accepts a DIRECTORY, an
// unreadable file, or (for node/bash) a non-executable file as "resolves" —
// reproduced complete:true with a baked path pointing at a plain directory.
// isFile() is the load-bearing, fully portable check (a directory always
// fails it, on every platform); the accessSync() mode check layers on top
// but is a WEAK signal on Windows specifically — fs.accessSync(path, X_OK)
// on Windows has no real executable-bit concept and behaves like F_OK (just
// existence), confirmed empirically here, so it does not actually catch a
// non-executable regular file on Windows the way it does on POSIX. isFile()
// is what does the real work cross-platform; the mode check is included
// because it's free, harmless, and is the meaningful check on POSIX.
function isReadableFile(p) {
  let stat;
  try {
    stat = fs.statSync(p);
  } catch (_e) {
    return false;
  }
  if (!stat.isFile()) return false;
  try {
    fs.accessSync(p, fs.constants.R_OK);
  } catch (_e) {
    return false;
  }
  return true;
}

function isRunnableExecutable(p) {
  if (!isReadableFile(p)) return false;
  try {
    fs.accessSync(p, fs.constants.X_OK);
  } catch (_e) {
    return false;
  }
  return true;
}

// HIMMEL-1422: cheap content-sanity floor for the wrapper/script files —
// isReadableFile() alone accepts a truncated-to-zero-bytes (or
// whitespace-only) file sitting at an otherwise-correct path, which is
// exactly the "no-op guardrail" shape from the ticket's motivating scenario
// (an empty guardrail-skip-in-himmel.js). Deliberately cheap (a content
// check, not a real JS/bash parse or a hash) per the approved design —
// "full hashing only if it falls out naturally", and it didn't here.
function isSaneContentFile(p) {
  if (!isReadableFile(p)) return false;
  try {
    return fs.readFileSync(p, 'utf8').trim().length > 0;
  } catch (_e) {
    return false;
  }
}

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function readGitDir(repo) {
  const dotGit = path.join(repo, '.git');
  let stat;
  try {
    stat = fs.statSync(dotGit);
  } catch (_e) {
    return null;
  }
  if (stat.isDirectory()) return dotGit;
  if (!stat.isFile()) return null;
  try {
    const text = fs.readFileSync(dotGit, 'utf8').trim();
    const match = text.match(/^gitdir:\s*(.+)$/i);
    if (!match) return null;
    return path.resolve(repo, match[1]);
  } catch (_e) {
    return null;
  }
}

// HIMMEL-1427 (r4, codex-adv-3): for a linked worktree, the gitdir that
// readGitDir() resolves (.git/worktrees/<name>) carries refs/HEAD but NOT the
// objects/, packed-refs, or branch refs — those live in the shared COMMON dir.
// A worktree's per-worktree gitdir points at it via a `commondir` file (a path
// relative to that gitdir). A primary checkout has no such file and IS its own
// common dir, so this is a no-op there.
function resolveCommonDir(gitDir) {
  try {
    const text = fs.readFileSync(path.join(gitDir, 'commondir'), 'utf8').trim();
    return path.resolve(gitDir, text);
  } catch (_e) {
    return gitDir;
  }
}

// HIMMEL-1472 (R4): the authoritative object-format width is the repository's
// CONFIGURED format, NOT the HEAD/ref oid's own length. A crafted/corrupt DB in
// a DEFAULT (sha1) repo whose HEAD ref carries a 64-hex oid with a fully
// self-consistent sha256 commit→tree→blob chain passes every r3 width+rehash
// check (the HEAD oid pinned width 32 and the foreign chain agreed) while git
// itself rejects the repo (extensions.objectFormat says sha1); the mirror holds
// for a configured sha256 repo with a 40-hex chain. Read the common dir's
// config for [extensions] objectFormat and return the byte width it implies:
// sha256 → 32, absent/sha1 → 20 (git's default). Fail CLOSED on a present-but-
// unreadable config or an unrecognized value — degrade, never guess the width.
// A MISSING config file is the healthy default (no objectFormat override → sha1),
// matching git; any OTHER read error (permissions/I/O on a present file) degrades.
//
// HIMMEL-1472 (R5): apply git's FULL repository-format validation, not just the
// objectFormat value. R4 read objectFormat and derived a width but skipped the
// rules git uses to ACCEPT that config, so configs git REFUSES still yielded a
// width and a healthy attestation: objectFormat=sha256 with
// core.repositoryformatversion 0 (git: "repo version is 0, but v1-only extension
// found"), repositoryformatversion > 1 (git: "Expected git repo version <= 1"),
// an unknown extensions.* key (git: "unknown repository extension found"), or a
// valueless objectFormat (git: "invalid value for 'extensions.objectformat'").
// Mirror git's documented rule set and degrade on every config git itself rejects.
// git's documented extension keys (Documentation/technical/repository-version.txt
// + setup.c): the extensions.* keys git HONORS at repositoryformatversion >= 1. A
// key outside this set is one git refuses outright ("unknown repository extension
// found"), so attesting integrity against it would diverge from git. Keep this in
// sync with git's current known set.
const KNOWN_GIT_EXTENSIONS = new Set([
  'objectformat',
  'refstorage',
  'worktreeconfig',
  'preciousobjects',
  'partialclone',
  'compatobjectformat',
]);

// HIMMEL-1472 (R6): a known KEY is necessary but not sufficient — git also
// validates each extension's VALUE and refuses the repo on a bad one ("invalid
// value for 'extensions.<name>'"). R5 only checked the key set, so e.g.
// refStorage=bogus attested healthy against a config git rejects. Mirror git's
// accepted value sets: refStorage / compatObjectFormat take git's lowercase
// canonical tokens (case-SENSITIVE, like git); worktreeConfig / preciousObjects
// are git booleans (the literals below, case-INsensitive; a BARE key parses as
// true); partialClone is any non-empty remote name. objectFormat is validated
// by the width derivation below, not this table. A value outside its key's set
// degrades — never attest against a config git refuses.
const GIT_EXTENSION_VALUES = {
  refstorage: ['files', 'reftable'],
  compatobjectformat: ['sha1', 'sha256'],
  worktreeconfig: 'bool',
  preciousobjects: 'bool',
  partialclone: 'nonempty',
};
// git config_bool accepts exactly these literals (case-insensitive). A bare
// valueless variable (no `=`) is boolean true to git — the parse loop maps that
// to 'true' before this table sees it.
const GIT_BOOL_LITERALS = new Set(['true', 'false', 'yes', 'no', 'on', 'off', '1', '0']);
// true iff `raw` is a value git accepts for extension `key`. objectFormat (and
// any unconstrained key) is unconstrained here — objectFormat is normalized to
// {sha1,sha256} by the width derivation.
function validExtensionValue(key, raw) {
  const spec = GIT_EXTENSION_VALUES[key];
  if (!spec) return true;
  const v = raw.trim().replace(/^"|"$/g, '');
  if (spec === 'bool') return GIT_BOOL_LITERALS.has(v.toLowerCase());
  if (spec === 'nonempty') return v.length > 0;
  return spec.includes(v); // case-sensitive canonical token
}
// HIMMEL-1472 (R9): a STRICT value whitelist for the kv grammar. git's config
// value grammar is broad (escapes, line continuations, mid-value comment
// starts, ...) and chasing it exactly is a bottomless source of "looser than
// git" findings. The invariant needs only one direction — never attest against
// a config git REFUSES — so accept only the conservative shape every real
// default config satisfies and degrade on EVERYTHING else. Two shapes pass:
//   - bare value: no `"`, no `\`, no `;`/`#` (git reads ; and # as comment
//     starts only outside quotes; rather than model that, refuse them), OR
//   - fully quoted: optional surrounding whitespace then `"..."` with no `\`
//     and no `"` inside.
// Anything else — unbalanced/embedded quotes, any backslash (escapes and line
// continuations), trailing garbage after a closing quote — fails. This is
// fail-closed: a value git would ACCEPT but this refuses is safe (the
// guardrail reports width-unavailable and degrades gracefully). `v` is the raw
// text captured after `key =` (leading whitespace already consumed by the kv
// regex).
function valueIsWellFormed(v) {
  if (!v.includes('"') && !v.includes('\\') && !v.includes(';') && !v.includes('#')) return true;
  return /^\s*"[^"\\]*"\s*$/.test(v);
}
function configuredObjectByteWidth(commonDir) {
  let text;
  try {
    text = fs.readFileSync(path.join(commonDir, 'config'), 'utf8');
  } catch (e) {
    return e.code === 'ENOENT' ? 20 : null;
  }
  let section = null; // bare section in scope, or null (outside / subsectioned)
  let version = 0; // core.repositoryformatversion — git's default is 0
  let versionMalformed = false;
  let malformed = false; // a [core]/[extensions] line git's parser would reject
  const extensions = new Map(); // [extensions] keys (lowercased) → raw value
  // HIMMEL-1472 (R9) — CLOSURE RULE for the config-grammar class. This parser
  // accepts ONLY the strict subset below (headers, key grammar, and the value
  // whitelist in valueIsWellFormed); every shape outside it degrades. The
  // invariant is one-directional: NEVER attest a width against a config git
  // REFUSES. Degrading on a config git would ACCEPT is safe and by-design (the
  // fallback reports width-unavailable; the guardrail degrades gracefully).
  // So a future "parser is looser than git" finding must demonstrate a config
  // this WHITELIST ACCEPTS while git REJECTS it (a fail-open); "git accepts but
  // we degrade" is fail-closed and OUT OF SCOPE — that sentence is the decline
  // template for future re-raises.
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || line.startsWith(';')) continue;
    const sec = line.match(/^\[([^\]]*)\]$/);
    if (sec) {
      // HIMMEL-1472 (R8): mirror git's config header grammar (Documentation/config.txt).
      // Git accepts exactly two header forms — a bare `[name]` (name = alnum, `-`,
      // `.`) or a subsection `[name "sub"]` (whitespace then a DOUBLE-QUOTED
      // subsection, escapes \\ and \"). A header that looks like one but matches
      // neither (e.g. an unquoted second word like `[bad section]`) makes git reject
      // the whole file ("bad config line"), so degrade rather than silently scope it
      // out and attest a width against a config git refuses.
      const bareHeader = sec[1].match(/^([A-Za-z0-9.-]+)$/);
      const subHeader = sec[1].match(/^([A-Za-z0-9.-]+)[ \t]+"((?:[^"\\\n]|\\.)*)"$/);
      if (bareHeader) {
        // HIMMEL-1472 (R11): the bare-header grammar admits dots, so git's legacy
        // dotted subsection syntax `[name.sub]` lands here too. Git reads those keys
        // as `<name>.<sub>.*`; for `[extensions.x]` that is `extensions.x.*`, which
        // git refuses as an unknown extension at repositoryformatversion >= 1 — a
        // config this whitelist ACCEPTS while git REJECTS it (the R9 closure rule's
        // own fail-open), so degrade rather than silently scope it out and attest.
        // Dotted `[core.x]` (and any other dotted section) is consistently IGNORED
        // by both git's repo-format validation and this parser — extensions.* is the
        // only divergence, so this guard is extensions-only. Case-insensitive (match
        // lowercased); covers `[extensions.x]`, `[EXTENSIONS.X]`, `[extensions.]`.
        const name = bareHeader[1].toLowerCase();
        if (name.startsWith('extensions.')) malformed = true;
        else section = name;
      } else if (subHeader) {
        // HIMMEL-1472 (R10): git reads `[extensions "x"]` keys as `extensions.x.*` and
        // refuses them as unknown extensions at repositoryformatversion >= 1; at v0 any
        // extension present is already a degrade. No real repo carries subsectioned
        // extensions — degrade, never attest. `[core "x"]` and other subsections stay
        // scoped out (they play no part in repo-format validation). Section names are
        // case-insensitive in git config, so compare lowercased.
        if (subHeader[1].toLowerCase() === 'extensions') malformed = true;
        else section = null; // a subsectioned header (e.g. [remote "origin"]) is not the bare scope
      } else {
        malformed = true;
      }
      continue;
    }
    // git rejects the ENTIRE config file on a line its parser can't read, in
    // ANY section ("bad config line N in file .git/config") — so shape-validate
    // every line; only the SEMANTIC capture below is scoped to the bare
    // [core]/[extensions] sections.
    // HIMMEL-1472 (R8): a git variable name starts with a letter and allows only
    // alnum + `-` (no leading digit/dot, no embedded dot). The key patterns below
    // use that grammar so a key git rejects (9key, .key, key.sub) degrades instead
    // of attesting against a config git refuses.
    if (!section) {
      // Subsectioned (e.g. [remote "origin"]) or pre-section scope: a kv or
      // bare line is fine here in SHAPE; the VALUE is still whitelist-checked
      // (R9) so a value git refuses degrades even out of scope, and anything
      // else still chokes git's parser.
      const oosKv = line.match(/^([A-Za-z][A-Za-z0-9-]*)\s*=\s*(.*)$/);
      if (oosKv) {
        if (!valueIsWellFormed(oosKv[2])) malformed = true;
      } else if (!/^[A-Za-z][A-Za-z0-9-]*$/.test(line)) {
        malformed = true;
      }
      continue;
    }
    const kv = line.match(/^([A-Za-z][A-Za-z0-9-]*)\s*=\s*(.*)$/);
    if (kv) {
      const key = kv[1].toLowerCase();
      // R9: whitelist the value shape before any semantic capture, so a value
      // git refuses (unclosed quote, escape, trailing garbage) degrades even
      // under [core]/[extensions], where R6 only validated known extension keys.
      if (!valueIsWellFormed(kv[2])) {
        malformed = true;
        continue;
      }
      if (section === 'core' && key === 'repositoryformatversion') {
        const v = kv[2].trim();
        if (/^\d+$/.test(v)) version = Number(v);
        else versionMalformed = true;
      } else if (section === 'extensions') {
        // Capture every extensions.* key so an unknown one degrades below — git
        // refuses an unknown extension outright at repositoryformatversion >= 1.
        extensions.set(key, kv[2]);
      }
      continue;
    }
    // BARE key (no `=`): git parses a valueless variable as boolean true. For an
    // extensions.* key this is its =true form — a known boolean extension stays
    // valid (validated below); an unknown one still degrades on the key check.
    // R9: under [core], a valueless `repositoryformatversion` is a key git reads
    // as an integer — a valueless int key is one git rejects, so degrade.
    const bare = line.match(/^([A-Za-z][A-Za-z0-9-]*)$/);
    if (bare) {
      const bkey = bare[1].toLowerCase();
      if (section === 'extensions') extensions.set(bkey, 'true');
      else if (section === 'core' && bkey === 'repositoryformatversion') versionMalformed = true;
      continue;
    }
    // Neither `key = value` nor a bare `key`: a config line git would choke on.
    malformed = true;
  }
  if (malformed) return null; // a line git's parser rejects, anywhere in the file
  if (versionMalformed) return null; // non-numeric repositoryformatversion → degrade
  if (version > 1) return null; // git: "Expected git repo version <= 1"
  // Extensions are honored ONLY at repositoryformatversion >= 1. Any extension
  // present at version 0 is malformed (a real repo is v0 with NO extensions, or
  // v1+ WITH them); git refuses known v1-only extensions here ("repo version is
  // 0, but v1-only extension found"). Degrade fail-closed rather than guess.
  if (version === 0) return extensions.size > 0 ? null : 20;
  // version === 1: extensions honored, but every key must be one git recognizes —
  // an unknown one makes git refuse the repo outright.
  for (const key of extensions.keys()) {
    if (!KNOWN_GIT_EXTENSIONS.has(key)) return null;
  }
  // git also constrains each extension's VALUE — a value it refuses ("invalid
  // value for 'extensions.<name>'") makes it refuse the repo, so degrade.
  for (const [key, raw] of extensions) {
    if (!validExtensionValue(key, raw)) return null;
  }
  if (!extensions.has('objectformat')) return 20; // no override → git default sha1
  // git config values may be quoted; strip one layer. Lowercased because the
  // only canonical forms are sha1/sha256 — anything else (incl. a valueless
  // entry) degrades.
  const objectFormat = extensions.get('objectformat').trim().replace(/^"|"$/g, '').toLowerCase();
  if (objectFormat === 'sha256') return 32;
  if (objectFormat === 'sha1') return 20;
  return null; // unrecognized / valueless objectFormat → degrade, never guess
}

// The ref/HEAD OID predicates accept 40-hex (sha1) OR 64-hex (sha256), matching
// readObject via hashAlgoForOid (HIMMEL-1468): the fallback ref/HEAD parser
// hardcoded-tested only {40}, so a sha256 repo (objectFormat=sha256) degraded to
// reference-unavailable whenever the git subprocess was unavailable — an
// internal inconsistency with r10's sha256 object support. This repo is sha1,
// so this is consistency, not a live bug. Exported for direct unit tests; a full
// sha256 round-trip is not exercisable end-to-end (the loose/tree readers stay
// sha1), so the predicate is the testable seam.
function readPackedRef(commonDir, ref) {
  try {
    const lines = fs.readFileSync(path.join(commonDir, 'packed-refs'), 'utf8').split(/\r?\n/);
    for (const line of lines) {
      if (!line || line.startsWith('#') || line.startsWith('^')) continue;
      const [oid, name] = line.split(' ');
      if (name === ref && hashAlgoForOid(oid)) return oid;
    }
  } catch (_e) {
    // packed-refs is optional.
  }
  return null;
}

export function readHeadOid(gitDir, commonDir) {
  let head;
  try {
    head = fs.readFileSync(path.join(gitDir, 'HEAD'), 'utf8').trim();
  } catch (_e) {
    return null;
  }
  if (hashAlgoForOid(head)) return head;
  const match = head.match(/^ref:\s*(.+)$/);
  if (!match) return null;
  const ref = match[1];
  try {
    const oid = fs.readFileSync(path.join(commonDir, ref), 'utf8').trim();
    if (hashAlgoForOid(oid)) return oid;
  } catch (_e) {
    return readPackedRef(commonDir, ref);
  }
  return null;
}

function readLooseObject(commonDir, oid) {
  // HIMMEL-1472: accept sha1 (40-hex) OR sha256 (64-hex) oids, keyed by
  // hashAlgoForOid (matching readObject's rehash chokepoint) — a sha256 repo's
  // loose objects live at objects/<2>/<62>, which the prior {40}-only guard
  // rejected, dead-ending the fallback one layer below readHeadOid's fix.
  if (!hashAlgoForOid(oid)) return null;
  const objectPath = path.join(commonDir, 'objects', oid.slice(0, 2), oid.slice(2));
  let inflated;
  try {
    inflated = zlib.inflateSync(fs.readFileSync(objectPath));
  } catch (_e) {
    return null;
  }
  const nul = inflated.indexOf(0);
  if (nul < 0) return null;
  const header = inflated.subarray(0, nul).toString('utf8');
  const [type] = header.split(' ');
  return { type, body: inflated.subarray(nul + 1) };
}

// ── packed-object support (HIMMEL-1427 r4, codex-adv-3) ────────────────────
// After a `git gc` / `git repack -d`, loose objects are deleted and live only
// in objects/pack/*.pack, indexed by the matching *.idx — so a loose-only
// reader returned reference-unavailable and a healthy install read degraded
// whenever the git subprocess was unavailable. The reader below parses the idx
// (v2) to locate the oid, then inflates from the .pack, resolving OFS_DELTA
// and REF_DELTA chains. Alternates (objects/info/alternates) are intentionally
// NOT followed — a missing base degrades honestly to reference-unavailable
// rather than silently crossing into another object store. Minimal and
// dependency-free, like the loose reader above.

function readUint32BE(buf, off) {
  return (buf[off] * 0x1000000) + ((buf[off + 1] << 16) + (buf[off + 2] << 8) + buf[off + 3]);
}

function readUint64BE(buf, off) {
  return readUint32BE(buf, off) * 0x100000000 + readUint32BE(buf, off + 4);
}

const PACK_IDX_MAGIC = [0xff, 0x74, 0x4f, 0x63]; // "\377tOc"
const PACK_TYPE_NAMES = { 1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag' };

// Returns the oid's byte offset into its .pack, or null if the oid is absent.
// A v2 idx is header(8) + fanout(256*4) + oid(total*<width>) + crc(total*4) +
// offset(total*4) [+ large-offset] tables — <width> is 20 (sha1) or 32 (sha256),
// keyed by the requested oid's format (HIMMEL-1472). A truncated/crafted idx can
// advertise a fanout total or large-offset index that points past idx.length,
// and the Buffer.compare/readUint32BE calls below then THROW ERR_OUT_OF_RANGE —
// uncaught, that crashes status --json instead of returning
// reference-unavailable. Every derived range (table span, large-offset entry,
// fanout search window) is checked against idx.length/total so a malformed idx
// returns null (honest "absent") rather than throwing (CodeRabbit on #1527).
export function findPackOffset(idx, oidHex) {
  if (idx.length < 1032) return null; // header(8) + fanout(256*4) minimum
  if (idx[0] !== PACK_IDX_MAGIC[0] || idx[1] !== PACK_IDX_MAGIC[1] || idx[2] !== PACK_IDX_MAGIC[2] || idx[3] !== PACK_IDX_MAGIC[3]) return null;
  if (readUint32BE(idx, 4) !== 2) return null; // v2 idx only
  // HIMMEL-1472: per-entry oid width is keyed by the repo object format — a sha1
  // idx stores 20-byte oids, a sha256 (objectFormat=sha256) idx stores 32. The
  // requested oid's hex length names it (oidByteWidth, matching hashAlgoForOid),
  // so the request and the idx must agree; any other length is no match.
  const width = oidByteWidth(oidHex);
  if (!width) return null;
  const fanoutOff = 8;
  const total = readUint32BE(idx, fanoutOff + 255 * 4);
  if (total === 0) return null;
  const oidsOff = fanoutOff + 256 * 4;
  const crcsOff = oidsOff + total * width;
  const offsOff = crcsOff + total * 4;
  const largeOff = offsOff + total * 4;
  // Require the whole oid+crc+offset table span to fit before touching any of
  // it — an absurd fanout total (e.g. 0xffffffff in a 1032-byte idx) fails here.
  if (largeOff > idx.length) return null;
  const oid = Buffer.from(oidHex, 'hex');
  const firstByte = oid[0];
  const lo = firstByte === 0 ? 0 : readUint32BE(idx, fanoutOff + (firstByte - 1) * 4);
  const hi = readUint32BE(idx, fanoutOff + firstByte * 4);
  // Fanout must be monotonic non-decreasing and bounded by total — a crafted
  // idx with hi > total (or lo > hi) yields an out-of-range search window.
  if (hi > total || lo > hi) return null;
  let left = lo;
  let right = hi;
  while (left < right) {
    const mid = (left + right) >>> 1;
    const cmp = idx.compare(oid, 0, width, oidsOff + mid * width, oidsOff + mid * width + width);
    if (cmp === 0) {
      let off = readUint32BE(idx, offsOff + mid * 4);
      if (off & 0x80000000) {
        const largeIdx = off & 0x7fffffff;
        // Large-offset entries are 8-byte, after the 4-byte offset table — a
        // crafted largeIdx can point past idx.length.
        if (largeOff + largeIdx * 8 + 8 > idx.length) return null;
        off = readUint64BE(idx, largeOff + largeIdx * 8);
      }
      return off;
    }
    if (cmp < 0) left = mid + 1;
    else right = mid;
  }
  return null;
}

// Maximum object size the delta reader will reconstruct (HIMMEL-1427 r10). git's
// practical single-object cap is well under 4 GiB; a size varint encoding more is
// a crafted stream. Capping the non-wrapping decode below bounds the math AND
// rejects a delta whose declared sizes would otherwise overflow past 32 bits.
const MAX_OBJECT_SIZE = 0xffffffff; // 4 GiB - 1

// Decodes a LEB128 base-128 size varint from `buf` starting at index `p`, using
// NON-WRAPPING Number math (HIMMEL-1427 r10). The prior `val |= (b & 0x7f) << shift`
// accumulation used JS bitwise ops, which coerce to a SIGNED 32-bit Int32 — so a
// 5-byte size varint like [0x81,0x80,0x80,0x80,0x10] (== 4_294_967_297, i.e.
// 2^32 + 1) WRAPPED to 1, silently bypassing the declared-base-size check
// instead of degrading. Multiply by 0x80 per byte and add (plain Number math — no
// bitwise coercion), range-check against MAX_OBJECT_SIZE, and reject a runaway
// run of continuation bytes. Returns { value, next } or null on a
// malformed/oversized varint (the caller reads null as 'degraded').
function decodeSizeVarint(buf, p) {
  let value = 0;
  let mult = 1;
  for (let count = 1; ; count++) {
    if (p >= buf.length) return null;
    const b = buf[p++];
    value += (b & 0x7f) * mult;
    // A real git object size needs at most 5 base-128 bytes (5*7 = 35 bits ≥ 32);
    // count > 10 is unreachable for a legitimate size and bounds a runaway run of
    // 0x80 continuation bytes (whose contribution is 0, so `value` alone could
    // never trip the size cap). value > MAX_OBJECT_SIZE rejects the 2^32+1 case.
    if (count > 10 || value > MAX_OBJECT_SIZE) return null;
    if (!(b & 0x80)) break;
    mult *= 0x80;
  }
  return { value, next: p };
}

// Applies a git delta (copy/insert op stream) onto a base object body. Returns
// the reconstructed body, or null on any malformed/truncated delta — the caller
// reads null as 'degraded', never a silent short/empty result. Exported so the
// r8 regressions can exercise the offset/varint math directly on small buffers.
export function applyDelta(base, delta) {
  let p = 0;
  // Base-size varint (HIMMEL-1427 r9/r10): CAPTURED via NON-WRAPPING math and
  // validated against the actual base length — a mismatch means the delta belongs
  // to a different base object, so degrade instead of applying it against the
  // wrong base. (r8 added the in-bounds termination check; r10 replaced the
  // bitwise-shift accumulator — which wrapped a 5-byte size varint past 2^32 and
  // could land back on base.length, bypassing this very check — with
  // decodeSizeVarint, which rejects the oversized value instead.)
  const baseHdr = decodeSizeVarint(delta, p);
  if (!baseHdr) return null;
  const baseSize = baseHdr.value;
  p = baseHdr.next;
  if (baseSize !== base.length) return null; // declared base size must match the actual base
  // Target-size varint (HIMMEL-1427 r10): same non-wrapping decode. A wrapped
  // target size could falsely match the reconstructed length on a 32-bit boundary
  // and accept a malformed delta; decodeSizeVarint rejects the oversized value.
  const targetHdr = decodeSizeVarint(delta, p);
  if (!targetHdr) return null;
  const targetSize = targetHdr.value;
  p = targetHdr.next;
  const chunks = [];
  while (p < delta.length) {
    const op = delta[p++];
    if (op & 0x80) {
      // Copy offset uses UNSIGNED assembly (HIMMEL-1427 r8): `<< 24` yields a
      // signed Int32, so a 4th offset byte >= 0x80 made cpOff negative and
      // corrupted copies on >2GB base objects. Multiply by 0x1000000 (matching
      // readUint32BE) and accumulate with `+` so cpOff stays a plain Number
      // across the full 32-bit range instead of being coerced back to Int32.
      let cpOff = 0;
      if (op & 0x01) cpOff += delta[p++];
      if (op & 0x02) cpOff += delta[p++] * 0x100;
      if (op & 0x04) cpOff += delta[p++] * 0x10000;
      if (op & 0x08) cpOff += delta[p++] * 0x1000000;
      let cpSize = 0;
      if (op & 0x10) cpSize |= delta[p++];
      if (op & 0x20) cpSize |= delta[p++] << 8;
      if (op & 0x40) cpSize |= delta[p++] << 16;
      if (p > delta.length) return null; // truncated copy command
      if (cpSize === 0) cpSize = 0x10000;
      // Validate the copy range against the actual base buffer (HIMMEL-1427 r9):
      // Buffer.subarray CLAMPS an overrun instead of throwing, so a copy past the
      // base end was silently truncated and could still match targetSize → a
      // false healthy verdict on malformed pack data. Reject non-finite/negative
      // values and any range past the base end; degrade instead.
      if (!Number.isFinite(cpOff) || !Number.isFinite(cpSize) ||
          cpOff < 0 || cpSize < 0 || cpOff + cpSize > base.length) {
        return null;
      }
      chunks.push(base.subarray(cpOff, cpOff + cpSize));
    } else if (op > 0) {
      if (p + op > delta.length) return null; // truncated insert payload
      chunks.push(delta.subarray(p, p + op));
      p += op;
    } else {
      return null; // op 0 is reserved
    }
  }
  const out = Buffer.concat(chunks);
  return out.length === targetSize ? out : null;
}

// Reads one packed object at byte offset `off`, resolving OFS_DELTA against a
// base in the SAME pack and REF_DELTA against a base resolved by oid (loose or
// packed). Returns { type, body } or null.
// Delta chains are bounded (CodeRabbit on #1526): a malformed/crafted pack can
// otherwise recurse forever — an OFS_DELTA whose offset varint decodes to 0
// re-reads the SAME entry, and a REF_DELTA can name a base that resolves back
// to itself through readObject. Both would end in a RangeError stack overflow,
// making contentIntegrity THROW instead of returning its honest 'degraded'.
// git itself caps delta depth (pack.depth default 50); 64 matches that posture.
const MAX_DELTA_DEPTH = 64;

function readPackEntry(commonDir, pack, idx, off, depth = 0, lookup, oidWidth) {
  if (depth > MAX_DELTA_DEPTH) return null;
  let b = pack[off];
  const type = (b >> 4) & 7;
  let p = off + 1;
  while (b & 0x80) { b = pack[p++]; } // skip the size varint
  const dataStart = p;
  if (type === 6) { // OFS_DELTA: base is at (off - negOff) in the same pack
    b = pack[dataStart];
    p = dataStart + 1;
    // negOff varint (HIMMEL-1427 r10): git's OFS_DELTA offset encoding, decoded
    // with NON-WRAPPING math. The prior `(negOff + 1) << 7` accumulator coerced to
    // a signed Int32 and wrapped past 2^31, so a crafted varint could decode to a
    // small positive value that passed the `> off` range check while naming the
    // wrong base. Multiply by 0x80 per byte (no bitwise coercion), cap the byte
    // run, and let the existing `> off` check reject any value pointing before the
    // pack start.
    let negOff = b & 0x7f;
    let count = 1;
    while (b & 0x80) {
      if (p >= pack.length) return null;
      b = pack[p++];
      if (++count > 10) return null;
      negOff = (negOff + 1) * 0x80 + (b & 0x7f);
    }
    if (!(negOff > 0) || negOff > off) return null; // 0 = self-reference loop; > off = out of range
    let delta;
    try { delta = zlib.inflateSync(pack.subarray(p)); } catch (_e) { return null; }
    const base = readPackEntry(commonDir, pack, idx, off - negOff, depth + 1, lookup, oidWidth);
    if (!base) return null;
    const body = applyDelta(base.body, delta);
    return body ? { type: base.type, body } : null;
  }
  if (type === 7) { // REF_DELTA: base named by the following oid (20 bytes sha1, 32 sha256)
    // HIMMEL-1472: the base-oid slice must be sized by the repo hash width, not a
    // fixed 20. An objectFormat=sha256 pack carries a 32-byte base oid — a fixed
    // 20 truncated it AND started the inflate 12 bytes inside the oid, so a
    // sha256 REF_DELTA never resolved. `oidWidth` is derived from the requested
    // oid (oidByteWidth in readPackedObject) the same way findPackOffset keys
    // the idx; an unknown width can't size the oid, so degrade (fail-closed).
    if (!oidWidth) return null;
    const baseOid = pack.subarray(dataStart, dataStart + oidWidth).toString('hex');
    let delta;
    try { delta = zlib.inflateSync(pack.subarray(dataStart + oidWidth)); } catch (_e) { return null; }
    // HIMMEL-1472 (R3): thread the pinned width so a foreign-format REF_DELTA
    // base (a mixed-format pack) is rejected at the readObject chokepoint rather
    // than traversed into a false integrity attestation.
    const base = readObject(commonDir, baseOid, depth + 1, lookup, oidWidth); // cycle-checked via lookup.visited
    if (!base) return null;
    const body = applyDelta(base.body, delta);
    return body ? { type: base.type, body } : null;
  }
  const typeName = PACK_TYPE_NAMES[type];
  let body;
  try { body = zlib.inflateSync(pack.subarray(dataStart)); } catch (_e) { return null; }
  return typeName ? { type: typeName, body } : null;
}

function readPackedObject(commonDir, oid, depth = 0, lookup, oidWidth) {
  let entries;
  try {
    entries = fs.readdirSync(path.join(commonDir, 'objects', 'pack'));
  } catch (_e) {
    return null;
  }
  for (const entry of entries) {
    if (!entry.endsWith('.idx')) continue;
    const idxPath = path.join(commonDir, 'objects', 'pack', entry);
    const packPath = `${idxPath.slice(0, -4)}.pack`;
    // Read each pack's idx+pack buffers at most once per top-level lookup: a
    // REF_DELTA chain re-enters readPackedObject per delta level, and re-reading
    // the whole pack each level (while earlier frames still hold their buffers)
    // multiplies resident memory by chain depth. `lookup.packCache` is one
    // shared cache across the whole lookup.
    let idx;
    let pack;
    try {
      let cached = lookup.packCache.get(idxPath);
      if (!cached) {
        cached = { idx: fs.readFileSync(idxPath), pack: fs.readFileSync(packPath) };
        lookup.packCache.set(idxPath, cached);
      }
      idx = cached.idx;
      pack = cached.pack;
    } catch (_e) {
      continue;
    }
    // Wrap per-index parsing so a malformed idx/pack is SKIPPED to the next
    // pack (or reference-unavailable) — never a throw out of the integrity
    // path. findPackOffset validates the idx; the pack body / delta stream can
    // still surprise, so readPackEntry is covered here too.
    try {
      const off = findPackOffset(idx, oid);
      if (off === null) continue;
      // HIMMEL-1472: findPackOffset matched this oid against the idx, so its
      // oidByteWidth (20 sha1 / 32 sha256) is the repo's hash width — thread it
      // into readPackEntry so the REF_DELTA base oid is sized correctly (the same
      // width source findPackOffset uses for the idx entries). R3: prefer the
      // pinned width threaded from readObject (the repo's single object format);
      // absent a pin (direct callers) derive it from the oid — both equal the
      // oid's own width once readObject has rejected any mismatched request.
      const width = oidWidth || oidByteWidth(oid);
      return readPackEntry(commonDir, pack, idx, off, depth, lookup, width);
    } catch (_e) {
      continue;
    }
  }
  return null;
}

// Picks the git object-id hash algorithm by oid length (HIMMEL-1427 r10): sha1
// oids are 40 hex chars, sha256 (git's objectFormat=sha256) are 64. Any other
// length is not a git oid → degrade rather than guess.
function hashAlgoForOid(oid) {
  if (oid.length === 40 && /^[0-9a-f]{40}$/.test(oid)) return 'sha1';
  if (oid.length === 64 && /^[0-9a-f]{64}$/.test(oid)) return 'sha256';
  return null;
}

// Byte width of a git object id by its hex length (HIMMEL-1472): the companion
// to hashAlgoForOid for the raw-byte readers below (pack-idx entries, tree
// entries) that index oid BYTES rather than pick a hash algorithm — sha1 = 20,
// sha256 = 32, else not a git oid. Function-declaration hoisting lets the
// earlier findPackOffset and the findTreeEntry call site use it.
function oidByteWidth(oid) {
  if (oid.length === 40 && /^[0-9a-f]{40}$/.test(oid)) return 20;
  if (oid.length === 64 && /^[0-9a-f]{64}$/.test(oid)) return 32;
  return null;
}

// Recomputes a git object id from its { type, body } (HIMMEL-1427 r10): git's oid
// is the hash of "<type> <size>\0<body>". Hashed in two update() steps so the
// (possibly large, binary) body is fed as raw bytes — never round-tripped through
// a JS string. `algo` must already be validated by hashAlgoForOid.
function computeGitOid(type, body, algo) {
  return crypto.createHash(algo)
    .update(`${type} ${body.length}\0`, 'utf8')
    .update(body)
    .digest('hex');
}

// The integrity fallback's single object lookup: loose first, then packed.
// `depth` carries the REF_DELTA chain budget; `lookup` (created once per
// top-level lookup) carries a visited-OID cycle set and a pack/idx buffer
// cache. A REF_DELTA can name a base that resolves back to itself — depth
// caps it at MAX_DELTA_DEPTH but only after 64 wasted per-level pack
// re-reads, so a repeat oid in one lookup degrades immediately, and each
// pack file is read at most once per lookup (CodeRabbit on #1527).
export function readObject(commonDir, oid, depth = 0, lookup, oidWidth) {
  if (!lookup) lookup = { visited: new Set(), packCache: new Map() };
  // HIMMEL-1472 (R3): when the caller pins a repo object-format width (threaded
  // from readHeadBlob's HEAD/ref oid), reject any oid whose own width disagrees.
  // Git forbids intermixing hash formats in one repository (hash-transition
  // spec): a crafted/corrupt DB with a 40-hex sha1 commit naming a 64-hex sha256
  // tree (or the mirror) would otherwise traverse and rehash green where
  // `git show HEAD:<path>` rejects — a false integrity attestation on the
  // git-unavailable fallback path. Without a pin (direct unit-test callers) the
  // per-oid rehash below still self-validates each object.
  if (oidWidth && oidByteWidth(oid) !== oidWidth) return null;
  if (lookup.visited.has(oid)) return null; // REF_DELTA cycle → degrade, don't loop
  lookup.visited.add(oid);
  const loose = readLooseObject(commonDir, oid);
  const obj = loose || readPackedObject(commonDir, oid, depth, lookup, oidWidth);
  // Recompute the object id and compare to the request (HIMMEL-1427 r10): a
  // crafted/corrupt idx can map oid→offset at the WRONG object, and a tampered
  // loose file can sit at an oid-derived path whose content hashes elsewhere —
  // either serves a blob that does NOT correspond to the requested oid, and the
  // integrity comparison would then read false-healthy. Verify at this single
  // chokepoint (every loose + packed result, including delta-reconstructed
  // objects whose final { type, body } flows through here): rehash
  // "<type> <len>\0<body>" with the algo picked by oid length and degrade on any
  // mismatch → reference-unavailable (fail-closed), never a wrong blob.
  if (obj) {
    const algo = hashAlgoForOid(oid);
    if (!algo || computeGitOid(obj.type, obj.body, algo) !== oid) return null;
  }
  return obj;
}

function commitTreeOid(body, oidWidth) {
  const lineEnd = body.indexOf(10);
  const firstLine = body.subarray(0, lineEnd < 0 ? body.length : lineEnd).toString('utf8');
  // HIMMEL-1472: accept sha1 (40-hex) OR sha256 (64-hex) tree oids, keyed
  // consistently with hashAlgoForOid — a sha256 repo's commit carries a 64-hex
  // tree line that the prior {40}-only regex silently dropped.
  const match = firstLine.match(/^tree ([0-9a-f]{40}|[0-9a-f]{64})$/);
  if (!match) return null;
  // HIMMEL-1472 (R3): reject a tree oid whose width disagrees with the repo's
  // pinned object format (threaded from readHeadBlob's HEAD/ref oid). Git
  // forbids a sha1 commit naming a sha256 tree (and the mirror); without this a
  // crafted/corrupt DB traversed into a false integrity attestation on the
  // git-unavailable fallback path.
  if (oidWidth && oidByteWidth(match[1]) !== oidWidth) return null;
  return match[1];
}

// HIMMEL-1472: a tree entry is "<mode> <name>\0<oid>" where the oid is 20 bytes
// (sha1) or 32 (sha256). The nul+<width> advance and oid slice are keyed by
// `oidWidth` — the tree's own oid width, passed by readHeadBlob's caller (a
// tree object's entries carry oids of the repo's object format). The prior
// hardcoded nul+21 walk silently truncated sha256 entry oids to their first 20
// bytes and advanced past only 21, desynchronizing every subsequent entry.
function findTreeEntry(treeBody, name, oidWidth) {
  // HIMMEL-1472 (R3, panel glm-1): an undefined oidWidth made nul+1+oidWidth
  // NaN, the oid subarray coerce to empty, and the loop index go NaN — silently
  // wrong instead of null. The pinned width is threaded from readHeadBlob, but
  // keep an explicit fail-closed guard matching the REF_DELTA arm regardless.
  if (!oidWidth) return null;
  let i = 0;
  while (i < treeBody.length) {
    const space = treeBody.indexOf(32, i);
    if (space < 0) return null;
    const nul = treeBody.indexOf(0, space + 1);
    if (nul < 0 || nul + 1 + oidWidth > treeBody.length) return null;
    const mode = treeBody.subarray(i, space).toString('utf8');
    const entryName = treeBody.subarray(space + 1, nul).toString('utf8');
    const oid = treeBody.subarray(nul + 1, nul + 1 + oidWidth).toString('hex');
    if (entryName === name) return { mode, oid };
    i = nul + 1 + oidWidth;
  }
  return null;
}

// HIMMEL-1427 (CR round 2, codex-adv finding 2): the integrity reference
// lookup below spawns `git -C <resolved repo root> show HEAD:<path>`. Inherited
// GIT_* repository/object/index/config override variables (GIT_DIR,
// GIT_WORK_TREE, GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY, GIT_COMMON_DIR,
// GIT_CEILING_DIRECTORIES, …) redirect repository discovery EVEN WITH an
// explicit -C — reproduced: a poisoned GIT_DIR made `git -C <worktree>
// rev-parse HEAD` resolve a DIFFERENT repo (main, not the worktree). Git
// itself exports GIT_DIR in hook contexts, so this fires in normal operation
// (a pre-push-invoked status probe), not just adversarially. Every git spawn
// in the integrity path therefore runs with a SANITIZED env: a copy of
// process.env with every /^GIT_/ key removed EXCEPT GIT_TERMINAL_PROMPT (a
// benign UI hint an operator may set deliberately). The explicit -C repo
// root it already passes then wins. Safe simple rule, per the round-2 brief.
// Exported so the round-4 regression (HIMMEL-1427, codex-adv-2) can unit-test
// the case-insensitive rule directly, isolated from the git subprocess.
export function sanitizedGitEnv() {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    // Windows env-var names are case-insensitive for the spawned git child
    // while JS preserves spelling, so a case-sensitive startsWith('GIT_')
    // filter let mixed-case `git_dir` / `Git_Dir` through — and git still
    // honors them, redirecting the integrity reference. Compare
    // case-insensitively on BOTH the prefix filter and the GIT_TERMINAL_PROMPT
    // exception; delete off the ORIGINAL key name so the actual env entry is
    // removed whatever its spelling.
    if (key.toUpperCase().startsWith('GIT_') && key.toUpperCase() !== 'GIT_TERMINAL_PROMPT') {
      delete env[key];
    }
  }
  return env;
}

function readHeadBlobFromGit(repo, relativePath) {
  try {
    return {
      ok: true,
      body: execFileSync('git', ['-C', repo, 'show', `HEAD:${relativePath}`], {
        encoding: 'buffer',
        maxBuffer: 10 * 1024 * 1024,
        env: sanitizedGitEnv(),
        stdio: ['ignore', 'pipe', 'ignore'],
      }),
    };
  } catch (_e) {
    return null;
  }
}

export function readHeadBlob(repo, relativePath) {
  const fromGit = readHeadBlobFromGit(repo, relativePath);
  if (fromGit) return fromGit;
  const gitDir = readGitDir(repo);
  if (!gitDir) return { ok: false, reason: 'reference-unavailable' };
  // HIMMEL-1427 (r4, codex-adv-3): for a linked worktree, readGitDir() returns
  // the per-worktree gitdir (.git/worktrees/<name>), but refs, packed-refs, and
  // objects/ live in the COMMON dir. resolveCommonDir() follows the commondir
  // pointer back to it (a no-op for a primary checkout, which has no such file
  // and IS its own common dir). HEAD stays read from the per-worktree gitdir —
  // that is where a worktree's HEAD lives — while every ref/object lookup uses
  // the common dir.
  const commonDir = resolveCommonDir(gitDir);
  const headOid = readHeadOid(gitDir, commonDir);
  if (!headOid) return { ok: false, reason: 'reference-unavailable' };
  // HIMMEL-1472 (R4): pin the repo's object-format width from the CONFIGURED
  // format (extensions.objectFormat in the common dir's config), NOT the HEAD/ref
  // oid's own length — the HEAD oid is corrupt/attacker-controllable, the config
  // is git's declared repo format. A crafted/corrupt default (sha1) repo whose
  // HEAD ref carries a 64-hex oid with a fully self-consistent sha256 chain passes
  // every r3 width+rehash check (the HEAD oid pinned width 32 and the chain
  // agreed) while git itself rejects the repo (objectFormat says sha1); the mirror
  // holds for a configured sha256 repo with a 40-hex chain. Derive the configured
  // width (fail-closed), REJECT a HEAD oid whose width disagrees, and pin the
  // CONFIGURED width into the traversal thread (readObject, commitTreeOid, the
  // tree walk, readPackEntry's REF_DELTA arm) — every oid inside a repo shares its
  // one object format (hash-transition spec), so a HEAD/oid disagreeing with the
  // config is corrupt and degrades rather than attests.
  const oidWidth = configuredObjectByteWidth(commonDir);
  if (!oidWidth) return { ok: false, reason: 'reference-unavailable' };
  if (oidByteWidth(headOid) !== oidWidth) return { ok: false, reason: 'reference-unavailable' };
  const commit = readObject(commonDir, headOid, 0, undefined, oidWidth);
  if (!commit || commit.type !== 'commit') return { ok: false, reason: 'reference-unavailable' };
  let treeOid = commitTreeOid(commit.body, oidWidth);
  if (!treeOid) return { ok: false, reason: 'reference-unavailable' };
  const parts = relativePath.split('/');
  for (let i = 0; i < parts.length; i += 1) {
    const tree = readObject(commonDir, treeOid, 0, undefined, oidWidth);
    if (!tree || tree.type !== 'tree') return { ok: false, reason: 'reference-unavailable' };
    const entry = findTreeEntry(tree.body, parts[i], oidWidth);
    if (!entry) return { ok: false, reason: 'reference-unavailable' };
    if (i === parts.length - 1) {
      const blob = readObject(commonDir, entry.oid, 0, undefined, oidWidth);
      if (!blob || blob.type !== 'blob') return { ok: false, reason: 'reference-unavailable' };
      return { ok: true, body: blob.body };
    }
    treeOid = entry.oid;
  }
  return { ok: false, reason: 'reference-unavailable' };
}

function contentIntegrity(p, anchor, relativePath) {
  const reference = `git:HEAD:${relativePath}`;
  let actual;
  try {
    if (!isReadableFile(p)) throw new Error('unreadable');
    actual = fs.readFileSync(p);
  } catch (_e) {
    return { verdict: 'degraded', reason: 'unreadable', sha256: null, reference, referenceSha256: null };
  }
  const actualSha = sha256(actual);
  const blob = readHeadBlob(anchor.repo, relativePath);
  if (!blob.ok) {
    return { verdict: 'degraded', reason: blob.reason, sha256: actualSha, reference, referenceSha256: null };
  }
  const referenceSha = sha256(blob.body);
  return {
    verdict: actualSha === referenceSha ? 'healthy' : 'degraded',
    reason: actualSha === referenceSha ? 'matches-git-object' : 'content-mismatch',
    sha256: actualSha,
    reference,
    referenceSha256: referenceSha,
  };
}

function missingIntegrity(relativePath) {
  return { verdict: 'degraded', reason: 'missing-path', sha256: null, reference: `git:HEAD:${relativePath}`, referenceSha256: null };
}

// HIMMEL-1422: realpath-compare a configured (parsed) path against the
// trust anchor's expected copy. realpathSync resolves symlinks AND
// normalizes OS-reported case, so two paths naming the SAME file compare
// equal even if written with different separators/casing; a path that
// doesn't exist can't be realpath'd (ENOENT), so this falls back to a plain
// path.resolve() normalization — cheap, and the *Resolves fields already
// flag a nonexistent path as broken on their own, so a fallback-only
// mismatch there is never the ONLY signal. Windows path comparison is
// case-insensitive; POSIX stays case-sensitive.
function resolvedPath(p) {
  try {
    return fs.realpathSync(p);
  } catch (_e) {
    return path.resolve(p);
  }
}

function pathsMatchAnchor(configuredPath, anchorPath) {
  const a = resolvedPath(configuredPath);
  const b = resolvedPath(anchorPath);
  return process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
}

// Resolves ONE owned entry ({ hook, matcher, parsed } from
// findGuardrailEntries — `parsed` is already strictly matched, so no null
// check is needed here) into its status --json shape (everything but
// basename/present/entryCount, which the caller already knows). Shared by
// the "primary" (first-found) entry and every entry in `duplicates`, so
// both are checked identically. `anchor` is statusDetail()'s single
// resolveAnchor() result (HIMMEL-1422), threaded through rather than
// re-resolved per entry.
function resolveOwnedEntry(info, guardrail, anchor, auditAnchor) {
  const wrapperRelativePath = `scripts/hooks/${WRAPPER}`;
  const scriptRelativePath = `scripts/hooks/${guardrail.basename}`;
  const anchorWrapperPath = path.join(anchor.repo, 'scripts', 'hooks', WRAPPER);
  const anchorScriptPath = path.join(anchor.repo, 'scripts', 'hooks', guardrail.basename);
  const auditWrapperPath = path.join(auditAnchor.repo, 'scripts', 'hooks', WRAPPER);
  const auditScriptPath = path.join(auditAnchor.repo, 'scripts', 'hooks', guardrail.basename);
  return {
    matcher: info.matcher ?? null,
    matcherMatches: (info.matcher ?? null) === guardrail.matcher,
    bashPath: info.parsed.bashPath,
    bashResolves: isRunnableExecutable(info.parsed.bashPath),
    nodePath: info.parsed.nodePath,
    nodeResolves: isRunnableExecutable(info.parsed.nodePath),
    wrapperPath: info.parsed.wrapperPath,
    wrapperResolves: isSaneContentFile(info.parsed.wrapperPath),
    anchorWrapperPath,
    wrapperMatchesAnchor: pathsMatchAnchor(info.parsed.wrapperPath, anchorWrapperPath),
    auditWrapperPath,
    wrapperMatchesAuditAnchor: pathsMatchAnchor(info.parsed.wrapperPath, auditWrapperPath),
    wrapperIntegrity: contentIntegrity(info.parsed.wrapperPath, anchor, wrapperRelativePath),
    scriptPath: info.parsed.scriptPath,
    scriptResolves: isSaneContentFile(info.parsed.scriptPath),
    anchorScriptPath,
    scriptMatchesAnchor: pathsMatchAnchor(info.parsed.scriptPath, anchorScriptPath),
    auditScriptPath,
    scriptMatchesAuditAnchor: pathsMatchAnchor(info.parsed.scriptPath, auditScriptPath),
    scriptIntegrity: contentIntegrity(info.parsed.scriptPath, anchor, scriptRelativePath),
  };
}

// `status --json` contract (HIMMEL-1418, extended by CR fixes codex-adv-1/2,
// then codex-adv-3/4, then codex-adv-5): a STABLE, machine-readable
// enumeration of every EXPECTED guardrail hook (GUARDRAILS, in that fixed
// order), each with its own presence + matcher + usability detail — unlike
// the plain `status` verb below (kept byte-for-byte unchanged: himmel-
// update.sh's report_guardrail_block parses it), which only ever proves "at
// least one owned hook exists and ITS node path resolves" (detectMode()'s
// `.some()`, nodeResolves()'s first-match return). SCOPE (fixed as of
// codex-adv-3/4/5, round 4): this contract attests the FULL GENERATED
// COMMAND IDENTITY — presence, resolution, matcher, uniqueness, and shape —
// of the configured hook wiring. It does NOT execute the hook chain, check
// node/bash versions, reason about ACLs beyond isFile()+access(), or judge
// semantic equivalence of a differently-FORMED-but-still-correct command;
// that is explicitly out of scope for this ticket (a deeper runtime-proof
// contract, if ever wanted, is a follow-up ticket, not an extension here).
//
// Ownership semantics (CR fix, codex-adv-5, refined by codex-adv-7 — round
// 5): "owned by guardrail X" (canonical, drives entryCount/present/paths)
// means the ENTIRE command string parses as EXACTLY the generated shape
// (GENERATED_COMMAND_RE — 4 quoted segments, nothing trailing) AND the
// parsed script arg's basename === X's basename. A command that merely
// MENTIONS X's basename somewhere (e.g. in an unquoted trailing `# comment`)
// while its real (4th quoted) script arg points elsewhere is a TRUE DECOY —
// not owned by X, or by ANY guardrail — it reads present:false/entryCount:0
// for every GUARDRAILS entry, i.e. plain "missing", the same as if nothing
// were wired at all. This was the deliberately chosen semantic for decoys
// (over "owned but flagged"): the contract's job is to attest whether the
// REAL protection is wired, and a decoy is not real protection — "missing"
// is the most conservative, fail-closed characterization.
//
// BUT (codex-adv-7): a command whose wrapper/script ARE X's real identity —
// each appearing as an actual quoted argument, not a comment — that merely
// fails the canonical anchored shape (e.g. a trailing extra token/comment
// AFTER the 4th quoted segment) is NOT a decoy: guardrail-skip-in-himmel.js
// reads only process.argv[2] (the script path) and ignores anything after
// it, so Claude Code still executes this entry identically to a canonical
// one. Silently treating it as "missing" (round 4's blanket answer) would
// hide a genuinely runtime-relevant duplicate — reopening exactly the
// round-3 blind spot this ticket already closed once, just via a different
// command shape. `nonCanonicalCount`/`nonCanonical` (below) surface this as
// its own tracked anomaly, distinct from both a decoy (not referenced at
// all) and a canonical duplicate (entryCount, round 3): it FORCES
// complete:false for the affected guardrail even when the canonical entry
// alone would otherwise be perfectly valid, because an ignored-but-still-
// wired duplicate with a dead node/bash path can still fail closed on a
// matching real tool call.
//
// A decoy sitting in an otherwise mode=global settings.json (detectMode()
// still uses the intentionally loose isOwnedHook() below, so mode can read
// "global" off a decoy alone) simply yields entryCount:0/nonCanonicalCount:0
// for every real guardrail, so `complete` still correctly reads false and
// the probe's detail still correctly says "<basename>: missing" — never a
// false "present".
//
// HIMMEL-1422 (trust anchor + content-sanity floor, companion finding to
// codex-adv-5/7): basename-only ownership means a settings.json referencing
// a same-named file in a WRONG directory (a stale/moved checkout, or an
// unrelated no-op stub) passed every prior check — "present" attested
// wiring, not that the wired file IS the real himmel copy. Two additive
// fixes, neither changing ownership semantics (still basename-only, per
// codex-adv-5's deliberate choice):
//   1. `anchor` (top-level, resolveAnchor()): HIMMEL_REPO env when set,
//      else the checkout guardrail-block.mjs is itself running from
//      (self-checkout, import.meta.url-derived). The SAME anchor
//      install()/global already bake paths from (repoRoot() === anchor.repo).
//   2. Per-hook anchorWrapperPath/wrapperMatchesAnchor and
//      anchorScriptPath/scriptMatchesAnchor: realpath-compare the
//      CONFIGURED wrapper/script paths against the anchor's own
//      scripts/hooks/ copies (pathsMatchAnchor()). A mismatch never flips
//      present:false (ownership is unchanged) but DOES force
//      complete:false — the affected hook reads present:true,
//      *MatchesAnchor:false, so a consumer can name the anchor precisely
//      instead of a bare "missing".
// Separately, *Resolves (wrapperResolves/scriptResolves) now also requires
// non-trivial content (isSaneContentFile(), not just isReadableFile()) — a
// truncated-to-zero-bytes or whitespace-only file at an otherwise-correct
// (even anchor-matching) path is a no-op guardrail and must not read
// resolves:true either. Shape:
//   {
//     "mode": "global" | "project",
//     "anchor": { "repo": string, "source": "HIMMEL_REPO" | "self-checkout" },
//                            // the trust anchor statusDetail() itself
//                            // resolved for THIS run (see above).
//     "complete": boolean,  // true iff mode === "global" AND every hook
//                            // below has EXACTLY ONE owned entry
//                            // (entryCount === 1), that entry's ACTUAL
//                            // matcher exactly equals expectedMatcher, its
//                            // bash/node/wrapper/script paths are all
//                            // USABLE (see below), its wrapper/script
//                            // both match the anchor, AND it has ZERO
//                            // runtime-relevant NON-CANONICAL duplicate
//                            // entries (nonCanonicalCount === 0).
//                            // false otherwise.
//     "hooks": [
//       {
//         "basename": string,        // e.g. "auto-approve-safe-bash.sh"
//         "matcher": string|null,    // the FIRST-FOUND owned entry's ACTUAL
//                                    // PreToolUse matcher (null if absent)
//         "expectedMatcher": string, // the matcher this hook NEEDS for full
//                                    // tool coverage (GUARDRAILS' own value)
//         "matcherMatches": boolean, // matcher === expectedMatcher, EXACT
//                                    // string equality — a looser "does
//                                    // matcher cover expectedMatcher's tool
//                                    // set" check would need to parse both
//                                    // as alternation regexes and reason
//                                    // about set containment; exact-match is
//                                    // the simplest rule that can never
//                                    // silently under-verify coverage, at
//                                    // the cost of flagging a hand-authored
//                                    // matcher that's a harmless superset
//                                    // as non-compliant too (acceptable: an
//                                    // operator who wants to relax this
//                                    // should re-run setup-hooks, not craft
//                                    // one by hand).
//         "present": boolean,        // >= 1 owned hook entry exists for this basename
//         "entryCount": number,      // TOTAL owned entries found for this
//                                    // basename (CR fix, codex-adv-4:
//                                    // installData()'s own dedup step
//                                    // proves duplicate owned entries are a
//                                    // real drift state — a dead-pathed
//                                    // duplicate is still independently
//                                    // wired and can fail closed at
//                                    // runtime, so `complete` requires
//                                    // EXACTLY 1, not merely >= 1)
//         "bashPath": string|null,   // FIRST-FOUND entry's fields below —
//         "bashResolves": boolean,   // ADDITIONAL entries (if entryCount > 1)
//         "nodePath": string|null,   // are in `duplicates`, same shape as
//         "nodeResolves": boolean,   // this block minus basename/present/
//         "wrapperPath": string|null,// entryCount/duplicates itself.
//         "wrapperResolves": boolean,
//         "anchorWrapperPath": string, // HIMMEL-1422: the anchor's own
//                                    // scripts/hooks/<WRAPPER> path — shown
//                                    // even when the hook is absent, so a
//                                    // consumer always knows where the
//                                    // anchor's copy WOULD be.
//         "wrapperMatchesAnchor": boolean, // HIMMEL-1422: realpath-compare
//                                    // (pathsMatchAnchor()) wrapperPath
//                                    // against anchorWrapperPath. false for
//                                    // an absent hook (no wrapperPath to
//                                    // compare).
//         "scriptPath": string|null,
//         "scriptResolves": boolean, // *Resolves fields (CR fix, codex-adv-3,
//                                    // extended HIMMEL-1422): "usable", not
//                                    // merely fs.existsSync().
//                                    // wrapper/script (passed as ARGUMENTS to
//                                    // node/bash, never exec'd directly) need
//                                    // to be a regular, READABLE file WITH
//                                    // non-trivial content (isSaneContentFile()
//                                    // — HIMMEL-1422: a zero-byte or
//                                    // whitespace-only file at an otherwise-
//                                    // correct path is a no-op guardrail and
//                                    // must not read resolves:true).
//                                    // node/bash (spawned as the executable
//                                    // itself) additionally need X_OK. isFile()
//                                    // is the load-bearing, fully portable
//                                    // check — it is what actually rejects a
//                                    // DIRECTORY, which fs.existsSync() alone
//                                    // accepted (the reproduced false-green).
//                                    // The X_OK layer is a WEAK signal on
//                                    // Windows specifically: fs.accessSync
//                                    // (path, X_OK) has no real executable-bit
//                                    // concept there and behaves like F_OK
//                                    // (existence only, confirmed empirically)
//                                    // — so a non-executable-but-readable file
//                                    // baked as the node/bash path will NOT
//                                    // be caught on Windows, only on POSIX.
//         "anchorScriptPath": string, // HIMMEL-1422: the anchor's own
//                                    // scripts/hooks/<basename> path —
//                                    // same shown-even-when-absent rule as
//                                    // anchorWrapperPath.
//         "scriptMatchesAnchor": boolean, // HIMMEL-1422: same as
//                                    // wrapperMatchesAnchor, for scriptPath.
//         "duplicates": [ /* same per-entry shape as above, one per
//                            ADDITIONAL owned entry beyond the first-found;
//                            [] when entryCount <= 1 */ ],
//         "nonCanonicalCount": number, // CR fix, codex-adv-7 (round 5):
//                                    // commands that reference THIS
//                                    // guardrail's wrapper+script identity
//                                    // as actual quoted arguments (not a
//                                    // comment mention — see
//                                    // referencesGuardrailIdentity()) but
//                                    // fail the canonical anchored shape
//                                    // (e.g. a trailing extra token). These
//                                    // are RUNTIME-RELEVANT (the wrapper
//                                    // only reads argv[2] and ignores the
//                                    // rest) yet excluded from entryCount —
//                                    // `complete` requires this to be 0.
//         "nonCanonical": [ /* { matcher, command } per anomaly above;
//                              [] when nonCanonicalCount is 0 */ ]
//       },
//       ... one entry per GUARDRAILS item, in GUARDRAILS order (stable) ...
//     ]
//   }
// Field names/order and hook order are fixed once shipped — this is a probe
// contract (scripts/himmelctl/lib/probes.js's cmd:guardrail_block_status).
export function statusDetail(data, ctx = {}) {
  const mode = detectMode(data);
  const anchor = resolveAnchor();
  const auditAnchor = resolveAuditAnchor(ctx);
  const anchorMatchesAudit = pathsMatchAnchor(anchor.repo, auditAnchor.repo);
  const hooks = GUARDRAILS.map((guardrail) => {
    const found = findGuardrailEntries(data, guardrail);
    const nonCanonical = findNonCanonicalEntries(data, guardrail);
    const wrapperRelativePath = `scripts/hooks/${WRAPPER}`;
    const scriptRelativePath = `scripts/hooks/${guardrail.basename}`;
    const entry = {
      basename: guardrail.basename,
      matcher: null,
      expectedMatcher: guardrail.matcher,
      matcherMatches: false,
      present: found.length > 0,
      entryCount: found.length,
      bashPath: null,
      bashResolves: false,
      nodePath: null,
      nodeResolves: false,
      wrapperPath: null,
      wrapperResolves: false,
      anchorWrapperPath: path.join(anchor.repo, 'scripts', 'hooks', WRAPPER),
      wrapperMatchesAnchor: false,
      auditWrapperPath: path.join(auditAnchor.repo, 'scripts', 'hooks', WRAPPER),
      wrapperMatchesAuditAnchor: false,
      wrapperIntegrity: missingIntegrity(wrapperRelativePath),
      scriptPath: null,
      scriptResolves: false,
      anchorScriptPath: path.join(anchor.repo, 'scripts', 'hooks', guardrail.basename),
      scriptMatchesAnchor: false,
      auditScriptPath: path.join(auditAnchor.repo, 'scripts', 'hooks', guardrail.basename),
      scriptMatchesAuditAnchor: false,
      scriptIntegrity: missingIntegrity(scriptRelativePath),
      duplicates: [],
      nonCanonicalCount: nonCanonical.length,
      nonCanonical: nonCanonical.map((info) => ({ matcher: info.matcher ?? null, command: info.hook.command })),
    };
    if (found.length > 0) {
      const primary = resolveOwnedEntry(found[0], guardrail, anchor, auditAnchor);
      entry.matcher = primary.matcher;
      entry.matcherMatches = primary.matcherMatches;
      entry.bashPath = primary.bashPath;
      entry.bashResolves = primary.bashResolves;
      entry.nodePath = primary.nodePath;
      entry.nodeResolves = primary.nodeResolves;
      entry.wrapperPath = primary.wrapperPath;
      entry.wrapperResolves = primary.wrapperResolves;
      entry.wrapperMatchesAnchor = primary.wrapperMatchesAnchor;
      entry.wrapperMatchesAuditAnchor = primary.wrapperMatchesAuditAnchor;
      entry.wrapperIntegrity = primary.wrapperIntegrity;
      entry.scriptPath = primary.scriptPath;
      entry.scriptResolves = primary.scriptResolves;
      entry.scriptMatchesAnchor = primary.scriptMatchesAnchor;
      entry.scriptMatchesAuditAnchor = primary.scriptMatchesAuditAnchor;
      entry.scriptIntegrity = primary.scriptIntegrity;
      entry.duplicates = found.slice(1).map((info) => resolveOwnedEntry(info, guardrail, anchor, auditAnchor));
    }
    return entry;
  });
  const complete = mode === 'global' && hooks.every((h) => (
    h.entryCount === 1 && h.nonCanonicalCount === 0
      && h.matcherMatches && h.bashResolves && h.nodeResolves && h.wrapperResolves && h.scriptResolves
      && h.wrapperMatchesAnchor && h.scriptMatchesAnchor
  ));
  const contentIntegrityComplete = hooks.every((h) => h.wrapperIntegrity.verdict === 'healthy' && h.scriptIntegrity.verdict === 'healthy');
  const auditAnchorComplete = anchorMatchesAudit && hooks.every((h) => h.wrapperMatchesAuditAnchor && h.scriptMatchesAuditAnchor);
  const attestationComplete = complete && contentIntegrityComplete && auditAnchorComplete;
  return { mode, anchor, auditAnchor, anchorMatchesAudit, complete, contentIntegrityComplete, auditAnchorComplete, attestationComplete, hooks };
}

function run(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const command = args._[0];
  const file = settingsPath();

  if (!['detect', 'install', 'remove', 'status', 'global', 'project'].includes(command)) {
    throw new Error('usage: guardrail-block.mjs detect|install|remove|status|global|project [--node ABS --bash ABS] [--stamp VALUE] [--json]');
  }

  const { text, data } = readSettings(file);

  if (command === 'detect') {
    process.stdout.write(`${detectMode(data)}\n`);
    return;
  }

  if (command === 'status') {
    if (args.json) {
      process.stdout.write(`${JSON.stringify(statusDetail(data))}\n`);
    } else {
      process.stdout.write(`guardrail-mode=${detectMode(data)} node-resolves=${nodeResolves(data) ? 'yes' : 'no'}\n`);
    }
    return;
  }

  let next;
  if (command === 'install' || command === 'global') {
    requireAbsolute('node', args.node);
    requireAbsolute('bash', args.bash);
    next = installData(data, { nodePath: args.node, bashPath: args.bash, himmelRepo: repoRoot() });
  } else {
    next = removeData(data);
  }

  const result = atomicWrite(file, text, stringify(next), args.stamp);
  process.stdout.write(`${command === 'project' ? 'remove' : command}: ${result.wrote ? `updated ${file}` : 'no changes'}\n`);
}

const invoked = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invoked) {
  try {
    run();
  } catch (e) {
    process.stderr.write(`guardrail-block: ${e.message}\n`);
    process.exit(1);
  }
}
