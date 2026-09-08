#!/usr/bin/env node
// scripts/lib/gen-commands-catalog.mjs — HIMMEL-2064.
//
// docs/commands-catalog.md rows for a command backed by `.claude/commands/<name>.md`
// carry a machine-generated Description column (byte-equal to that command's
// frontmatter `description:`) plus a hand-written Notes column for why/when
// context. Rows for a command with NO `.claude/commands/<name>.md` (plugin-
// sourced entries, e.g. the Clipper pipeline / Plugin skills sections) are
// exempt — left exactly as written.
//
// Usage:
//   node scripts/lib/gen-commands-catalog.mjs check   # CI: exit 1 on drift
//   node scripts/lib/gen-commands-catalog.mjs write   # regenerate in place
//   node scripts/lib/gen-commands-catalog.mjs check --staged  # pre-commit: read the STAGED blobs
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function frontmatterDescription(text) {
  const m = text.match(/^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/);
  if (!m) return '';
  const dm = m[1].match(/^description:\s*(.*)$/m);
  return dm ? dm[1].trim() : '';
}

export function loadGenerated(cmdDir) {
  const map = new Map();
  for (const entry of readdirSync(cmdDir)) {
    if (!entry.endsWith('.md')) continue;
    map.set(entry.slice(0, -'.md'.length), frontmatterDescription(readFileSync(join(cmdDir, entry), 'utf8')));
  }
  return map;
}

// Sections whose rows are ALWAYS plugin-sourced (no `.claude/commands/<name>.md`
// ever backs them, by design — see the section intros in docs/commands-catalog.md).
// An untagged, unmatched row OUTSIDE these sections is not "exempt", it is an
// ORPHAN: a command-backed row whose `.claude/commands/<name>.md` was removed
// or renamed (CR round 2, HIMMEL-2064 / HIMMEL-2080) — `write` drops it,
// `check` flags it. A TAGGED row (`/name (plugin)`) is exempt everywhere,
// regardless of section, since the tag itself declares it plugin-sourced.
const EXEMPT_SECTIONS = new Set([
  'Clipper pipeline (obsidian-triage plugin)',
  'Plugin skills & ops (himmel-ops, obsidian-triage)',
]);

// `.claude/commands/*.md` staged in the git index (pre-commit's own view of
// "what is being committed"), as a name -> description Map. Mirrors
// loadGenerated's contract, but sourced from `git show :<path>` blobs instead
// of the working tree, so an unrelated UNSTAGED edit sitting in a command
// file cannot influence the check (`--staged`, CR round 2 minor: align with
// check-doc-guard.sh's staged-vs-working convention).
export function loadGeneratedStaged(root, cmdDirRelative) {
  const map = new Map();
  const listing = execFileSync('git', ['ls-files', '--cached', '-z', `${cmdDirRelative}/*.md`], { cwd: root, encoding: 'utf8' });
  for (const path of listing.split('\0')) {
    if (!path) continue;
    const name = path.slice(cmdDirRelative.length + 1, -'.md'.length);
    // codex-1, CR round on HIMMEL-2064: git's `*` pathspec crosses directory
    // boundaries (verified: `.claude/commands/*.md` matches a nested
    // `sub/x.md`), but loadGenerated's readdirSync only reads DIRECT
    // entries — a staged nested file would appear only in staged mode and
    // false-flag as `<no catalog row>`. Skip anything not directly in
    // cmdDirRelative, matching loadGenerated's own direct-entries contract.
    if (name.includes('/')) continue;
    const blob = execFileSync('git', ['show', `:${path}`], { cwd: root, encoding: 'utf8' });
    map.set(name, frontmatterDescription(blob));
  }
  return map;
}

// A data row is `| /name [(tag)] | col2 | [col3] |`. Cell text is escaped at
// render time (escapeCell) so a literal `|` in a description/note can never
// be mis-read as a column boundary; parseRow reverses that (unescapeCell)
// before handing cells back to callers, so every caller works with plain
// logical text. Header/separator lines don't start with `| /`, so they never
// match ROW_START_RE.
const ROW_START_RE = /^\| \//;
// Escape backslashes BEFORE pipes (and unescape in the reverse order) so a
// cell containing a literal `\|` round-trips through CommonMark rendering:
// a single `\|` is itself a CommonMark escape sequence (renders as a bare
// `|`, silently dropping the backslash) — doubling the backslash first
// forces the renderer to consume it as its own escape pair, reproducing the
// original two characters (codex-1, CR round on HIMMEL-2064).
const escapeCell = (s) => s.replace(/\\/g, '\\\\').replace(/\|/g, '\\|');
const unescapeCell = (s) => s.replace(/\\\|/g, '|').replace(/\\\\/g, '\\');

// The exempt "(tag)" suffix is a closed set of the plugin markers this repo
// actually emits (see docs/commands-catalog.md rows), not any parenthetical
// (codex-2, CR round on HIMMEL-2064): an unanchored / \(/ let an unrelated
// aside like `/foo (beta)` evade the orphan check by looking tagged.
const TAG_RE = / \((himmel-ops|obsidian-triage|[\w-]+ plugin)\)$/;

// codex-1, CR round on HIMMEL-2064: `.split(' | ')` only splits on a pipe
// with a space on BOTH sides, so a hand-written cell with an unescaped pipe
// and no adjacent space (e.g. `note-a|note-b`) stayed inside one cell,
// passing check clean even though write would still re-escape it once
// parsed correctly. Split on every unescaped `|` regardless of surrounding
// whitespace — a `\` always escapes exactly the next character (matches
// escapeCell's contract), so an escaped pipe/backslash never becomes a
// delimiter.
function splitUnescaped(s) {
  const cells = [];
  let cur = '';
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === '\\' && i + 1 < s.length) {
      cur += ch + s[i + 1];
      i++;
    } else if (ch === '|') {
      cells.push(cur);
      cur = '';
    } else {
      cur += ch;
    }
  }
  cells.push(cur);
  return cells;
}

function parseRow(line) {
  // codex-1, CR round on HIMMEL-2064 (Critical): blindly slicing off the
  // last character assumed a trailing `|` always exists. GFM table rows
  // make the trailing pipe OPTIONAL (only the leading one is guaranteed
  // here, by ROW_START_RE's `^| /`) — a row that legitimately omits it had
  // its last real character silently truncated.
  //
  // codex-1, CR round on HIMMEL-2105 (Important): a plain `body.endsWith('|')`
  // check can't tell an optional trailing delimiter from a cell whose real
  // content legitimately ends in an escaped literal pipe (`\|`, as produced
  // by escapeCell) — stripping that char corrupts content. Let
  // splitUnescaped (which already knows escaped-vs-delimiter) decide: an
  // unescaped trailing `|` produces an empty trailing cell here, which we
  // drop; an escaped one doesn't split, so nothing is dropped.
  const rawCells = splitUnescaped(line.trim().slice(1));
  if (rawCells.length > 1 && rawCells[rawCells.length - 1] === '') rawCells.pop();
  const cells = rawCells.map((c) => unescapeCell(c.trim()));
  const nameMatch = cells[0].match(/^\/(\S+)/);
  return { name: nameMatch ? nameMatch[1] : '', tagged: TAG_RE.test(cells[0]), cells };
}

function buildLine(cells) {
  return `| ${cells.map(escapeCell).join(' | ')} |`;
}

// Pure core: given the catalog's current text and a Map of command-name →
// generated (frontmatter) description, either report drift (`check`) or
// return the regenerated text (`write`). No filesystem I/O.
//
// Each `## section` holds its own markdown table; a table becomes 3-column
// (Command | Description | Notes) only once it carries at least one row
// backed by a `.claude/commands/<name>.md` file (a "| Command | What it
// does |" header) — the plugin-only "Skill / command" table stays 2-column,
// untouched. `inTable` tracks that per-table state across the single pass so
// an EXEMPT row sitting inside an upgraded table still gets padded to 3
// columns (otherwise the table itself would be malformed markdown).
export function regenerateCatalog(catalogText, generated, mode) {
  const lines = catalogText.split(/\r?\n/);
  const violations = [];
  const seen = new Set();
  let inTable = false;
  // Separate from `inTable` (codex-2, CR round on HIMMEL-2064): `inTable`
  // covers EITHER header form and drives write's own migration (write always
  // upgrades a recognized header, so an as-yet-unmigrated legacy 2-col table
  // is not drift). `inTableThreeCol` is true only for the ALREADY-3-column
  // header — that is the specific "already migrated but this row lagged"
  // shape check must flag; an untouched legacy table stays unflagged until
  // someone actually runs write on it.
  let inTableThreeCol = false;
  let section = '';

  const out = [];
  for (const line of lines) {
    const headingMatch = line.match(/^## (.+)$/);
    if (headingMatch) section = headingMatch[1];

    if (line.trim() === '') { inTable = false; inTableThreeCol = false; out.push(line); continue; }
    if (!ROW_START_RE.test(line)) {
      // codex-1, HIMMEL-2064 CR round 3: recognize the ALREADY-migrated
      // 3-col header too, not just the legacy 2-col one — otherwise a
      // second `write` pass over an already-3-col table never sets inTable,
      // so a newly hand-added 2-cell exempt row in that table is left
      // un-padded, producing a malformed mixed-column table.
      if (line === '| Command | What it does |' || line === '| Command | Description | Notes |') {
        inTable = true;
        inTableThreeCol = line === '| Command | Description | Notes |';
        out.push(mode === 'write' ? '| Command | Description | Notes |' : line);
      } else if (line.startsWith('|---')) {
        out.push(mode === 'write' && inTable ? '|---|---|---|' : line);
      } else {
        if (line.startsWith('|')) { inTable = false; inTableThreeCol = false; } // any other header (e.g. "Skill / command")
        out.push(line);
      }
      continue;
    }

    const { name, tagged, cells } = parseRow(line);
    if (!generated.has(name)) {
      const exempt = tagged || EXEMPT_SECTIONS.has(section);
      if (!exempt) {
        // Orphan: a command-backed row whose command file is gone (removed
        // or renamed) — not plugin-exempt, so it must not linger silently.
        if (mode === 'check') violations.push({ name, have: '<orphaned row>', want: '<removed — run write to drop this row>' });
        else continue; // write: drop the row
        out.push(line);
        continue;
      }
      // exempt (plugin-sourced) — pad to 3 columns only if this row's table
      // was upgraded; otherwise leave as-is.
      // codex-2, CR round on HIMMEL-2064: `write` already padded an
      // unpadded exempt row inside an upgraded table, but `check` never
      // looked at this branch at all — a 2-column exempt row sitting inside
      // an already-3-column table passed check with zero violations even
      // though write would still change it. Mirror write's own condition.
      if (mode === 'check' && inTableThreeCol && cells.length < 3) {
        violations.push({ name, have: '<unpadded exempt row>', want: '<run write to pad it with an empty Notes cell>' });
      }
      out.push(mode === 'write' && inTable && cells.length < 3 ? buildLine([...cells, '']) : line);
      continue;
    }
    // codex-2, CR round 3: `seen` used to only record presence, so a
    // duplicated row for the same command (copy-paste) silently passed
    // whenever both copies' descriptions matched — flag the second
    // occurrence instead.
    if (mode === 'check' && seen.has(name)) {
      violations.push({ name, have: '<duplicate row>', want: '<remove the extra row>' });
      out.push(line);
      continue;
    }
    seen.add(name);

    const want = generated.get(name);
    const have = cells[1] ?? '';
    if (mode === 'check') {
      // codex-3, CR round on HIMMEL-2064: a legacy 2-column row whose col2
      // already equals frontmatter passed `have !== want` even though
      // `write` still restructures it (pads a Notes column, upgrades the
      // table header) — check said clean while write still had a diff.
      // Column count is a separate check, not folded into `have`/`want` (they
      // stay strings for the drift message), and never fires for `write`'s
      // own idempotency check just below (that row is always well-formed).
      if (have !== want) violations.push({ name, have, want });
      else if (cells.length < 3) violations.push({ name, have: '<legacy 2-column row>', want: '<run write to migrate to 3 columns>' });
      // codex-1, CR round on HIMMEL-2064: an unescaped `|` inside a
      // hand-written Notes cell splits into extra columns (parseRow's
      // ' | ' split has no way to tell it from a real column boundary) —
      // flag it the same way, so the row is never silently trusted as-is.
      else if (cells.length > 3) violations.push({ name, have: '<unescaped pipe in row>', want: '<run write to re-escape it, or fix by hand: escape the literal "|" as "\\|">' });
      out.push(line);
      continue;
    }
    // write: migrate to 3 columns (Command | Description | Notes), preserving
    // any existing extra prose as Notes. A pre-existing 2-col row whose
    // description already equals the frontmatter gets an empty Notes cell.
    // codex-1, CR round on HIMMEL-2074: rejoin cells[2..] with ' | ' rather
    // than taking only cells[2] — an unescaped `|` in a hand-written Notes
    // cell parses into extra cells, and taking cells[2] alone silently
    // truncated everything after that pipe. Rejoining recovers the full
    // original text, and buildLine's escapeCell re-escapes the `|` on
    // output, so the row self-heals into canonical (escaped) form.
    const notes = cells.length >= 3 ? cells.slice(2).join(' | ') : (have === want ? '' : have);
    out.push(buildLine([cells[0], want, notes]));
  }

  // A command with NO catalog row at all (added, or renamed with the old row
  // left behind) is invisible to the row-by-row pass above — it has no line
  // to walk. check-doc-guard.sh only proves the catalog FILE was touched in
  // the same commit as a new `.claude/commands/<name>.md`, not that a row for
  // it actually landed (codex-1, HIMMEL-2064 CR round 1). Catch that here.
  if (mode === 'check') {
    for (const name of generated.keys()) {
      if (!seen.has(name)) violations.push({ name, have: '<no catalog row>', want: generated.get(name) });
    }
  }

  const text = out.join('\n');
  return { text, violations, changed: text !== catalogText };
}

function main(mode, staged) {
  const root = resolve(join(fileURLToPath(import.meta.url), '..', '..', '..'));
  const catalogPath = join(root, 'docs/commands-catalog.md');
  const cmdDir = join(root, '.claude/commands');
  const catalogText = staged
    ? execFileSync('git', ['show', `:${relative(root, catalogPath).replace(/\\/g, '/')}`], { cwd: root, encoding: 'utf8' })
    : readFileSync(catalogPath, 'utf8');
  const generated = staged ? loadGeneratedStaged(root, '.claude/commands') : loadGenerated(cmdDir);
  const { text, violations, changed } = regenerateCatalog(catalogText, generated, mode);

  if (mode === 'check') {
    if (violations.length === 0) return 0;
    for (const v of violations) {
      if (v.have === '<no catalog row>') {
        console.error(`gen-commands-catalog: /${v.name} has no row in docs/commands-catalog.md — add one by hand (Command | Description | Notes), Description = "${v.want}"\n`);
      } else if (v.have === '<orphaned row>') {
        console.error(`gen-commands-catalog: /${v.name}'s row has no matching .claude/commands/${v.name}.md — run write to drop it\n`);
      } else if (v.have === '<duplicate row>') {
        console.error(`gen-commands-catalog: /${v.name} has more than one row in docs/commands-catalog.md — remove the extra one by hand\n`);
      } else if (v.have === '<legacy 2-column row>') {
        console.error(`gen-commands-catalog: /${v.name}'s row is still 2-column even though its Description matches frontmatter — run write to migrate it to 3 columns\n`);
      } else if (v.have === '<unescaped pipe in row>') {
        console.error(`gen-commands-catalog: /${v.name}'s row has an unescaped "|" splitting it into extra columns — run write to re-escape it, or fix by hand: escape the literal "|" as "\\|"\n`);
      } else if (v.have === '<unpadded exempt row>') {
        console.error(`gen-commands-catalog: /${v.name}'s row is still 2-column inside an already-3-column table — run write to pad it with an empty Notes cell\n`);
      } else {
        console.error(`gen-commands-catalog: ${v.name}: catalog says\n  "${v.have}"\nfrontmatter says\n  "${v.want}"\n`);
      }
    }
    console.error(`gen-commands-catalog: ${violations.length} row(s) drifted, missing, or orphaned. For a drifted/orphaned row: node scripts/lib/gen-commands-catalog.mjs write. For a missing row: add it by hand.`);
    return 1;
  }
  if (changed) writeFileSync(catalogPath, text);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const staged = args.includes('--staged');
  const mode = args.find((a) => a === 'check' || a === 'write');
  if (!mode) {
    console.error('usage: node scripts/lib/gen-commands-catalog.mjs <check|write> [--staged]');
    process.exitCode = 2;
  } else if (staged && mode !== 'check') {
    console.error('gen-commands-catalog: --staged is only valid with check (write always regenerates the working tree)');
    process.exitCode = 2;
  } else {
    process.exitCode = main(mode, staged);
  }
}
