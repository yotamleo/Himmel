#!/usr/bin/env bash
# test-launcher-twin-parity.sh — the embedded node-JS of every launcher twin pair
# must be byte-identical (HIMMEL-1792).
#
# himmel ships cross-platform launchers as TWINS: a bash script plus a
# byte-parallel .ps1. The security-relevant predicates (the egress-matrix gate,
# the settings sanitizer) are embedded node JS — the .ps1 twins delegate to the
# IDENTICAL JS via here-strings rather than re-implementing it in PowerShell
# ("delegates to the IDENTICAL node -e one-liner (no PS re-impl)" — their own
# header comment). A predicate written twice and drifting is a recurring defect
# class here (the moonshot fence bypass in PR #1680; the openrouter
# first-match-wins bug in #1691; and HIMMEL-1774 CR round 3 shipped a
# PowerShell-ONLY regression green because nothing compared the twins).
#
# What this asserts, driven ENTIRELY from the files on disk (no hand-maintained
# fixture that can silently diverge from what shipped):
#   1. Every `$Var = @'...'@` here-string a .ps1 twin passes to `node -e` is
#      byte-identical (after CR + edge-whitespace normalization — checkout
#      artifacts, never content) to some `node -e '...'` block in its bash twin.
#   2. No twin carries an embedded-JS shape this check cannot see: a bash
#      `node -e "..."` (double-quoted) or a .ps1 `node -e '<literal>'` would be
#      an uncovered predicate, so it FAILS rather than passing vacuously.
#   3. Bash-only JS blocks (steps the .ps1 twin implements natively in
#      PowerShell) are pinned PER PAIR below — a new unilateral predicate must
#      be consciously added to that pin with a reason, never slip through.
#   4. The claude-glm sanitizer key set is pinned on BOTH twins, so even a
#      byte-identical edit cannot silently weaken what seeded settings strip.
#   5. Canary floors: the counts of JS-bearing pairs and matched PS blocks can
#      never silently drop to zero (the HIMMEL-1128 false-green class).
#   6. The block extractors are quote/escape-aware (HIMMEL-1792 CR round 1): an
#      embedded ' in bash JS (the `'\''` idiom) and a mid-line '@ inside a PS
#      here-string no longer truncate the captured block, and any boundary the
#      extractor cannot determine unambiguously FAILS loudly rather than
#      comparing a partial extent.
#   7. The shared seed-lock protocol is pinned across claude-glm, its .ps1 twin,
#      and graphify's seeder: owner-token acquire/check/release, recursive stale
#      cleanup, and validated base-10 timeout/stale settings must all be present.
#
# Scope: every scripts/claude-* <-> scripts/claude-*.ps1 sibling pair on disk —
# a NEW launcher twin is covered the moment it lands, with no list to update.
# OUT of scope (honestly): PowerShell-only logic such as Copy-SeedConfig has no
# bash-JS counterpart to compare — that side is covered by the pwsh smoke suite
# (scripts/test-claude-openrouter.ps1), not by byte parity.
#
# node is required (same dependency every launcher twin already carries).
# bash 3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"          # scripts/parity
SCRIPTS="$(cd "$HERE/.." && pwd)"              # scripts/

# Per-pair pin of bash-only JS blocks — steps the .ps1 twin implements natively
# in PowerShell, so no byte twin exists BY DESIGN. Each count is a reviewed
# exception, not an open category: a new bash-only `node -e` block fails this
# suite until it is either ported to the .ps1 twin or added here with a reason.
#   claude-codex: 2        — proxy config validation JS; .ps1 validates natively
#   claude-glm: 1          — GLM-specific settings surgery; .ps1 equivalent is native
#   claude-openrouter: 1   — stdin credit-parser; .ps1 parses ConvertFrom-Json natively
#   claude-routed: 0
#   claude-glm-seed-check.sh: 0  (no embedded JS on either side)
EXPECT_BASH_ONLY="claude-codex:2 claude-glm:1 claude-openrouter:1 claude-routed:0 claude-glm-seed-check.sh:0"

# Canary floors — today's counts. A pair deleted or a PS delegation dropped
# trips these; update them CONSCIOUSLY when the twin set genuinely changes.
EXPECT_MIN_PAIRS_WITH_JS=4
EXPECT_MIN_MATCHED_PS_BLOCKS=5

TMPDIR_W="$(mktemp -d -t launcher-twin-parity.XXXXXX)"
trap 'rm -rf "$TMPDIR_W"' EXIT

cat > "$TMPDIR_W/parity.js" <<'NODEJS'
// Extraction + comparison. Prints ok:/FAIL: lines and exits nonzero on any
// violation. All paths come from argv[2]; expectations from env.
const fs = require('fs');
const path = require('path');
const scriptsDir = process.argv[2];
const expectBashOnly = {};   // bash filename -> pinned count
for (const tok of (process.env.EXPECT_BASH_ONLY || '').split(/\s+/)) {
  if (!tok) continue;
  const i = tok.lastIndexOf(':');
  if (i > 0) expectBashOnly[tok.slice(0, i)] = parseInt(tok.slice(i + 1), 10);
}
const minPairs = parseInt(process.env.EXPECT_MIN_PAIRS || '0', 10);
const minMatched = parseInt(process.env.EXPECT_MIN_MATCHED || '0', 10);

let fails = 0;
const fail = (m) => { console.log('FAIL: ' + m); fails++; };

// Canonical form compared across twins: CR stripped (checkout artifact — the
// pair is eol=lf in git, but an editor or attribute drift must never read as
// content drift) and edge whitespace trimmed (the bash literal opens with a
// newline after `node -e '`; the PS here-string content starts on the next
// line — framing, not content). INTERNAL bytes are compared exactly.
const canon = (s) => s.replace(/\r/g, '').replace(/^\s+/, '').replace(/\s+$/, '');

// Extract the env-key predicates from the GLM settings sanitizer. Prefix
// predicates are rendered with `*`; exact predicates keep their literal name.
function sanitizerKeys(s) {
  const keys = [];
  let m;
  const prefixes = /u\.indexOf\("([^"]+)"\)===0/g;
  const exact = /u==="([^"]+)"/g;
  while ((m = prefixes.exec(s)) !== null) keys.push(m[1] + '*');
  while ((m = exact.exec(s)) !== null) keys.push(m[1]);
  return keys.sort();
}

// A block boundary the extractor could not determine. Thrown — never returned
// as a silent partial: a truncated extent can match the WRONG twin and report
// parity that was never established (HIMMEL-1792 CR round 1).
class ExtractError extends Error {}

// Extract every `node -e '...'` block from a bash twin. Bash cannot escape a
// quote inside single quotes, so an embedded ' is spelled `'\''` (close, \',
// reopen); stopping at the FIRST quote — the original extractor — silently
// truncated every block containing one. Boundary rules, loud on anything else:
//   quote + `\''` -> one literal ' flows into the JS; the block continues
//                    after the reopening quote
//   quote + word delimiter (whitespace ; | & < > ) or end-of-input
//                 -> the argument genuinely ends; the block is complete
//   anything else -> an implicit concatenation (`'a'b'`, `'a'"$v"`) this
//                    extractor cannot model -> ExtractError, never a partial
function bashBlocks(s) {
  const out = [];
  let i = 0;
  while (true) {
    const k = s.indexOf("node -e '", i);
    if (k < 0) break;
    const start = k + 9;
    let j = start, js = '', end = -1;
    while (end < 0) {
      const q = s.indexOf("'", j);
      if (q < 0) throw new ExtractError('bash twin: unterminated node -e block at offset ' + k);
      if (s.slice(q + 1, q + 4) === "\\''") {
        js += s.slice(j, q) + "'";
        j = q + 4;
      } else if (q + 1 >= s.length || /[\s;|&<>)]/.test(s[q + 1])) {
        js += s.slice(j, q);
        end = q;
      } else {
        throw new ExtractError('bash twin: cannot unambiguously terminate the node -e block at offset ' + k +
          ' (quote followed by ' + JSON.stringify(s.slice(q + 1, q + 3)) + ' — implicit concatenation is not modeled); refusing to compare a partial block');
      }
    }
    out.push({ js, raw: s.slice(k, k + 12) });
    i = end + 1;
  }
  return out;
}

function psJsBlocks(s) {
  // Only here-strings actually INVOKED via `node -e $Var` count as embedded
  // JS — .ps1 twins also use here-strings for usage text / batch fixtures /
  // JSON, which are not predicates. A `node -e` whose argument is anything but
  // a $var is reported by the shape check instead.
  const out = [];
  const invokeRe = /node -e (\$\w+)/g;
  const invoked = new Set();
  let m;
  while ((m = invokeRe.exec(s)) !== null) invoked.add(m[1]);
  for (const v of invoked) {
    const assign = s.match(new RegExp('\\' + v + "\\s*=\\s*@'"));
    if (!assign) continue;                    // not a here-string; shape check reports the shape
    const start = s.indexOf('\n', assign.index) + 1;
    // A here-string terminates at a `'@` at the START of a line — the real PS
    // rule. The first `'@` ANYWHERE would truncate on mid-line content (a JS
    // string or regex containing '@), the PS-side twin of the bash first-quote
    // truncation; and an UNTERMINATED here-string used to be dropped by a
    // silent `continue` — an under-comparison, the same never-established-
    // parity class this rework closes.
    let end = -1;
    for (let e = s.indexOf("'@", start); e >= 0; e = s.indexOf("'@", e + 1)) {
      if (e === 0 || s[e - 1] === '\n' || s[e - 1] === '\r') { end = e; break; }
    }
    if (end < 0) throw new ExtractError('.ps1 twin: unterminated here-string for ' + v + " (no line-start '@ terminator)");
    out.push({ var: v, js: s.slice(start, end) });
  }
  return out;
}

// Embedded-JS shapes this check CANNOT see. `node -e "..."` in bash and
// `node -e '<literal>'` / `node -e "<literal>"` in .ps1 would embed a predicate
// outside the compared sets, so they fail loudly instead of passing vacuously.
// Comment mentions ("the IDENTICAL node -e one-liner") never quote directly
// after -e and so do not trip this.
function bashShapeViolations(s) {
  const out = [];
  const re = /node -e[ \t]+"/g;
  let m;
  while ((m = re.exec(s)) !== null) out.push(m.index);
  return out;
}
function psShapeViolations(s) {
  const out = [];
  const re = /node -e[ \t]+['"]/g;
  let m;
  while ((m = re.exec(s)) !== null) out.push(m.index);
  return out;
}

// The lock path can be shared across these launchers via config-dir overrides,
// so pin the on-disk protocol itself, not just the embedded JS twin blocks. The
// markers deliberately cover every protocol phase; a refactor must update this
// reviewed pin rather than silently dropping one implementation again.
(function seedLockProtocolParity() {
  const before = fails;
  const bashMarkers = [
    'LOCK="$CONFIG_DIR.seed-lock"',
    'SEED_LOCK_TOKEN=',
    '> "$LOCK/owner"',
    'owner="$(cat "$LOCK/owner"',
    '[ "$owner" = "$SEED_LOCK_TOKEN" ] || return 0',
    'rm -f "$LOCK/owner"',
    'rm -rf "$LOCK.stale.$$"',
    'SEED_LOCK_TIMEOUT=$(( 10#$SEED_LOCK_TIMEOUT ))',
    'SEED_LOCK_STALE=$(( 10#$SEED_LOCK_STALE ))',
  ];
  const specs = [
    ['claude-glm', bashMarkers],
    [path.join('graphify', 'seed-claude-config.sh'), bashMarkers],
    ['claude-glm.ps1', [
      '"$ConfigDir.seed-lock"',
      '$SeedLockToken =',
      "Set-Content -LiteralPath (Join-Path $Lock 'owner') -Value $SeedLockToken",
      'Get-Content -LiteralPath $ownerPath',
      'if ($owner -ne $SeedLockToken) { return }',
      'Remove-Item -LiteralPath $ownerPath',
      '[System.IO.Directory]::Delete($Lock)',
      'Remove-Item -LiteralPath "$Lock.stale.$PID" -Recurse -Force',
      '[int]::TryParse($env:CLAUDE_LANE_SEED_LOCK_TIMEOUT',
      '[int]::TryParse($env:CLAUDE_LANE_SEED_LOCK_STALE',
    ]],
  ];
  for (const [file, markers] of specs) {
    const source = fs.readFileSync(path.join(scriptsDir, file), 'utf8');
    for (const marker of markers) {
      if (!source.includes(marker)) fail(file + ': seed-lock protocol marker missing ' + JSON.stringify(marker));
    }
  }
  if (fails === before) console.log('ok: seed-lock ownership protocol pinned across all three implementations');
})();

// ---------------------------------------------------------------------------
// Extractor self-tests (HIMMEL-1792 CR round 1). The old bash extractor stopped
// at the first single quote, so a JS block containing the bash `'\''` escape
// was compared as a TRUNCATED extent — a check that can report parity it never
// established. These pin the boundary contract — FULL block, or a loud
// ExtractError, never a silent partial — on synthetic inputs (the extractors
// are pure functions); the scan below still drives only the real twins on disk.
// ---------------------------------------------------------------------------
(function extractorSelftest() {
  const IDIOM = "'\\''";  // the four bytes bash spells an embedded quote with
  const eq = (name, got, want) => {
    if (got !== want) fail('selftest ' + name + ': got ' + JSON.stringify(got) + ' want ' + JSON.stringify(want));
  };
  const mustThrow = (name, input, fn) => {
    try { fn(input); } catch (e) {
      if (e instanceof ExtractError) return;
      throw e;
    }
    fail('selftest ' + name + ': expected a loud ExtractError, got a silent result');
  };
  // bash: the '\'' idiom flows one literal ' into the JS and the block extends
  // to its REAL closing quote — whichever word shape ends the argument.
  eq('escaped-quote block', bashBlocks("node -e 'const q=\"it" + IDIOM + "s\"; done=1' 2>/dev/null\n")[0].js,
     "const q=\"it's\"; done=1");
  eq('delimiter: newline',  bashBlocks("node -e 'a" + IDIOM + "b'\n")[0].js, "a'b");
  eq('delimiter: space',    bashBlocks("node -e 'a" + IDIOM + "b' extra\n")[0].js, "a'b");
  eq('delimiter: paren',    bashBlocks("x=$(node -e 'a" + IDIOM + "b')\n")[0].js, "a'b");
  eq('delimiter: eof',      bashBlocks("node -e 'a" + IDIOM + "b'")[0].js, "a'b");
  eq('consecutive idioms',  bashBlocks("node -e 'x" + IDIOM + "y" + IDIOM + "z'\n")[0].js, "x'y'z");
  eq('multiple blocks',     bashBlocks("node -e 'one'\nnode -e 'two" + IDIOM + "s'\n").map((b) => b.js).join('|'),
     "one|two's");
  mustThrow('unterminated', "node -e 'const x=1;\n", bashBlocks);
  mustThrow('implicit concat', "node -e 'a'b'c'", bashBlocks);
  mustThrow('quote then expansion', "node -e 'a'\"$v\"", bashBlocks);
  // ps: mid-line '@ is CONTENT (only a line-start '@ terminates) and an
  // unterminated here-string fails loudly instead of being silently dropped.
  eq('ps: mid-line \'@ is content',
     psJsBlocks("$J = @'\nconst s=\"'@ not a terminator\";\n'@\nnode -e $J\n")[0].js,
     "const s=\"'@ not a terminator\";\n");
  mustThrow('ps: unterminated here-string', "$J = @'\nconst x=1;\nnode -e $J\n", psJsBlocks);
})();

// Enumerate twin pairs from disk: every scripts/claude-*.ps1 whose stem has a
// regular-file bash sibling (claude-<stem> or claude-<stem>.sh).
const pairs = [];
for (const f of fs.readdirSync(scriptsDir).sort()) {
  if (!/^claude-.*\.ps1$/.test(f)) continue;
  const stem = f.slice(0, -4);
  const bare = path.join(scriptsDir, stem);
  const withSh = path.join(scriptsDir, stem + '.sh');
  if (fs.existsSync(bare) && fs.statSync(bare).isFile()) pairs.push([stem, f]);
  else if (fs.existsSync(withSh) && fs.statSync(withSh).isFile()) pairs.push([stem + '.sh', f]);
}
if (pairs.length === 0) fail('no launcher twin pairs discovered under ' + scriptsDir + ' — the check has gone vacuous');

let pairsWithJs = 0, matchedPs = 0, totalBashOnly = 0;
for (const [bashFile, psFile] of pairs) {
  const bs = fs.readFileSync(path.join(scriptsDir, bashFile), 'utf8');
  const ps = fs.readFileSync(path.join(scriptsDir, psFile), 'utf8');
  bashShapeViolations(bs).forEach(() => fail(bashFile + ': double-quoted `node -e "..."` — an embedded-JS shape this parity check cannot compare; use the single-quoted form'));
  psShapeViolations(ps).forEach(() => fail(psFile + ': literal `node -e \'...\'`/`"..."` — a PS embedded-JS shape this check cannot compare; assign a here-string and pass the $var'));
  let bb, pb;
  try {
    bb = bashBlocks(bs).map((b) => canon(b.js));
    pb = psJsBlocks(ps);
  } catch (e) {
    if (!(e instanceof ExtractError)) throw e;
    fail(e.message + ' [' + bashFile + ' <-> ' + psFile + ']');
    continue;
  }

  if (bashFile === 'claude-glm') {
    const expected = ['ANTHROPIC_*', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_*'];
    const bashSanitizer = bb.find((js) => js.includes('delete j.model;') && js.includes('delete j.env[k];'));
    const psSanitizer = pb.find((p) => p.var === '$SanitizerJs');
    if (!bashSanitizer) fail('claude-glm: settings sanitizer JS block not found');
    if (!psSanitizer) fail('claude-glm.ps1: $SanitizerJs block not found');
    if (bashSanitizer && psSanitizer) {
      const bashKeys = sanitizerKeys(bashSanitizer);
      const psKeys = sanitizerKeys(psSanitizer.js);
      if (JSON.stringify(bashKeys) !== JSON.stringify(expected)) {
        fail('claude-glm: sanitizer key set ' + JSON.stringify(bashKeys) + ' != pinned ' + JSON.stringify(expected));
      }
      if (JSON.stringify(psKeys) !== JSON.stringify(expected)) {
        fail('claude-glm.ps1: sanitizer key set ' + JSON.stringify(psKeys) + ' != pinned ' + JSON.stringify(expected));
      }
      if (JSON.stringify(bashKeys) === JSON.stringify(expected) && JSON.stringify(psKeys) === JSON.stringify(expected)) {
        console.log('ok: claude-glm sanitizer key set pinned on both twins (' + expected.join(', ') + ')');
      }
    }
  }

  let noJs = false;
  if (bb.length === 0 && pb.length === 0) {
    noJs = true;
  } else {
    pairsWithJs++;
  }

  let pairMatched = 0;
  for (const { var: v, js } of pb) {
    const t = canon(js);
    if (bb.includes(t)) { pairMatched++; matchedPs++; continue; }
    let best = -1, bestCommon = -1;
    bb.forEach((c, i) => {
      let d = 0;
      while (d < c.length && d < t.length && c[d] === t[d]) d++;
      if (d > bestCommon) { bestCommon = d; best = i; }
    });
    fail(psFile + ': ' + v + ' is NOT byte-identical to any node -e block in ' + bashFile +
      (best >= 0 ? ' (closest bash block #' + best + ' diverges at char ' + bestCommon + ': ps=' + JSON.stringify(t.slice(Math.max(0, bestCommon - 20), bestCommon + 60)) + ' bash=' + JSON.stringify(bb[best].slice(Math.max(0, bestCommon - 20), bestCommon + 60)) + ')' : ' (bash twin embeds no JS at all)'));
  }

  let bashOnly = 0;
  bb.forEach((c) => { if (!pb.some((p) => canon(p.js) === c)) bashOnly++; });
  totalBashOnly += bashOnly;
  const pinned = expectBashOnly[bashFile] !== undefined ? expectBashOnly[bashFile] : 0;
  if (bashOnly !== pinned) {
    fail(bashFile + ': ' + bashOnly + ' bash-only JS block(s) but ' + pinned + ' pinned — port the block to ' + psFile + ' or pin the reviewed exception with a reason in EXPECT_BASH_ONLY');
  }
  if (noJs) {
    console.log('ok: ' + bashFile + ' <-> ' + psFile + ' (no embedded JS on either side — nothing to compare)');
  } else {
    console.log('ok: ' + bashFile + ' <-> ' + psFile + ' (' + pairMatched + ' PS JS block(s) byte-identical, ' + bashOnly + ' bash-only vs pin ' + pinned + ')');
  }
}

if (pairsWithJs < minPairs) fail('JS-bearing twin pairs dropped to ' + pairsWithJs + ' (floor ' + minPairs + ') — a twin lost its embedded JS; update the floor consciously or restore the twin');
if (matchedPs < minMatched) fail('matched PS JS blocks dropped to ' + matchedPs + ' (floor ' + minMatched + ') — a .ps1 twin stopped delegating to the shared JS; update the floor consciously or restore the delegation');
console.log('summary: pairs=' + pairs.length + ' pairs_with_js=' + pairsWithJs + ' matched_ps_blocks=' + matchedPs + ' bash_only_blocks=' + totalBashOnly);
process.exit(fails === 0 ? 0 : 1);
NODEJS

EXPECT_BASH_ONLY="$EXPECT_BASH_ONLY" \
EXPECT_MIN_PAIRS="$EXPECT_MIN_PAIRS_WITH_JS" \
EXPECT_MIN_MATCHED="$EXPECT_MIN_MATCHED_PS_BLOCKS" \
  node "$TMPDIR_W/parity.js" "$SCRIPTS"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "parity check FAILED"
exit 1
