#!/usr/bin/env bash
# Tests for LUNA-130 grow-feed-log.mjs.
#
# Scope:
#   1. script parses (node --check)
#   2. usage / arg-error exit codes (msg-id, mode, mode-specific required flags, sender)
#   3. vault validation: missing .obsidian -> rc2; missing target file -> rc2
#   4. feed row appended in the right place (inside ## Log table), table well-formed,
#      ## Products untouched
#   5. idempotent re-run (same --msg-id) -> exit 0, file byte-identical
#   6. a note containing `|` and a newline is escaped/collapsed so the table survives
#   7. --dry-run writes nothing
#   8. product mode appends a `### <name>` section before ## Notes; re-run with the
#      same product name skips (product-exists), even under a fresh msg-id
#   9. no ## Log table -> rc2
#   9b. updated: frontmatter bump on a real write only
#   10. dedup is mode-scoped + boundary-safe (product-then-feed combo; short-id-is-
#       prefix-of-existing-id; true same-mode/same-id re-run still dedupes)
#   11. atomic write: a simulated write failure leaves the original file intact
#   12. dedup is anchored to the tool's own provenance comment, not a loose token —
#       a note/body merely containing a `tg:<id> <mode>`-looking string (bare or a
#       forged `<!-- ... -->`) must not suppress a later real write
#   13. --product name validation (reject pipe / newline / leading '#' / empty /
#       forged comment delimiters; heading text and wikilink anchor always agree)
#   14. a flag given with no following value (e.g. trailing --vault) exits 1
#   15. productHeadingExists is scoped to the ## Products block only
#   16. the resolved-target safety line lands on STDERR (never stdout), with
#       the exact absolute vault+target path, on all three branches: a real
#       write, --dry-run, and an already-logged skip
#   17. required string flags validate AFTER trimming, not on raw truthiness —
#       whitespace-only --msg-id / --sender are rejected outright (not silently
#       sanitized to an empty key); two DIFFERENT whitespace-only msg-ids must
#       not collide into one dedup key; a msg-id carrying a char sanitizeCell
#       would rewrite is REJECTED (round 5 superseded the round-2
#       sanitize-and-display posture — see Test 26)
#   18. vault-containment is checked on REAL paths too (realpathSync), not
#       just path strings — an NTFS junction pointing outside the vault is
#       refused (skips cleanly if junction creation needs privileges this
#       environment doesn't have)
#   19. a lost-write race (another writer's rename clobbers ours) is
#       recovered via one retry when possible, and fails loud (non-zero, no
#       false ✓) rather than silently when the retry also loses
#   20. stale-snapshot freshness: an external edit between read/build and
#       rename is preserved while the feed row is re-derived and added
#   21. feed product links require an exact matching heading in ## Products
#   22. containment is a positive parent-chain membership proof, unit-tested
#       directly (isContainedIn export): cross-drive (relative() going
#       ABSOLUTE on Windows — the round-4 bypass), sibling name-prefix,
#       parent, UNC, and case-variant shapes — no second drive required;
#       the win32-only cases announce their skip loudly on POSIX
#   23. the atomic-write temp suffix cannot smuggle a path separator or ':'
#       — the temp path must stay inside the target's proven directory
#   24. product name can't break the [[#<name>]] wikilink anchor (']]'/'[['
#       rejected; single brackets still accepted)
#   25. explicitly-passed blank flag values are rejected, never silently
#       defaulted (`--vault ""` must never fall through to the REAL vault;
#       `--product ""`/`--note-file ""` are usage errors; whitespace-only
#       --ec leaves no dangling "EC " prefix)
#   26. msg-id is charset-restricted ([A-Za-z0-9._:-]) so the whitespace-
#       delimited provenance id field is unambiguous BY CONSTRUCTION —
#       `--msg-id "1 feed"` can no longer write a marker that a later
#       legitimate `--msg-id 1 --mode feed` dedups against (round 5:
#       silent data loss reported as ⊘ already-logged)
#   27. a flag-shaped token where a value belongs is a usage error —
#       `--water --dry-run` must not swallow --dry-run and run a REAL write
#   28. --date must be YYYY-MM-DD as USAGE/SKILL.md advertise
#   29. flags inapplicable to the selected --mode are rejected, never
#       silently dropped (--body-file in feed mode is staged content)
#   30. test-only env hooks are refused without GROW_FEED_LOG_TEST_HOOKS=1
#       (a stray inherited hook must not instrument a real write)
#   31. a product LABEL containing '##' (mid-name) never terminates
#       ## Products — heading stays a ### subsection, feed-mode lookup by
#       that exact label resolves, the next product insert still lands at
#       the true block end; a label STARTING with '##' is rejected (the
#       Test-13 leading-'#' door, ## flavor)
#   32. a product BODY line starting with '##' can no longer truncate
#       ## Products (HIMMEL-1798): the line is entity-escaped on disk
#       (&#35;# … — legible, rest byte-preserved), no raw '^## ' line lands
#       inside the block, the next product's section is not spliced into
#       the first product's body, and a product heading BELOW the escaped
#       line (operator hand-added at the block tail) is still inside the
#       section for productHeadingExists
#   33. neutralizeHeadings predicate unit cases + idempotency
#       (f(f(x)) === f(x)), via the exported function — the same
#       Test-22 import pattern
#
# Cross-platform: bash on Linux/macOS/Git-Bash. Uses node (not bun) for CI.
# Never touches the real vault — builds a temp fixture vault per run.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/grow-feed-log.mjs"

tmpdir="$(mktemp -d -t grow-feed-log.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

# The tool honors its test-only env hooks (GROW_FEED_LOG_TODAY /
# _TMP_SUFFIX / _SIMULATE_LOST_WRITE / _BEFORE_RENAME_APPEND_FILE) only
# under this explicit gate — a stray hook inherited by a real
# Telegram-dispatched invocation is refused (Test 30 pins the refusal by
# clearing the gate for one invocation).
export GROW_FEED_LOG_TEST_HOOKS=1

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

# Build a fresh fixture vault with a minimal Grow-Feeding-Log.md (mirrors the
# real vault file's shape: frontmatter with `updated:`, one ## Log row,
# ## Products with one product subsection, ## Notes tail).
make_vault() {
    local v="$1"
    mkdir -p "$v/.obsidian" "$v/20-Areas/Grow"
    cat > "$v/20-Areas/Grow/Grow-Feeding-Log.md" <<'EOF'
---
type: area
updated: 2026-08-12
---

# Grow feeding log

## Log

| Date | Vessel | Water | Nutrients | EC/notes |
|---|---|---|---|---|
| 2026-08-12 | Small tent — mint (LECHUZA reservoir) | 5 L | 2 caps = 10 ml [[#GREEN24 Pfeffer- / Apfel-Minze (Mentha)]] | Diluted 10 ml in 5 L. |

## Products

### GREEN24 Pfeffer- / Apfel-Minze (Mentha)

Cap volume = 5 ml. Label dose: 1 cap/L.

## Notes

- What to capture going forward: mixed reservoir EC.
EOF
}

# -- Test 1: script parses --------------------------------------------------
echo "Test 1: script parses"
assert "grow-feed-log.mjs exists" yes "$([ -r "$SCRIPT" ] && echo yes || echo no)"
if node --check "$SCRIPT" 2>/dev/null; then s=ok; else s=fail; fi
assert "grow-feed-log.mjs parses" ok "$s"

# -- Test 2: usage / arg errors ----------------------------------------------
# Every invocation below dies before reaching vault resolution (msg-id/mode/
# required-flag/sender checks all run before resolveVault in main()) — but
# per the HIMMEL-130 review hardening, NO test may rely on that ordering
# staying that way. Every one still passes an explicit --vault at a scratch
# dir that doesn't even need to exist (never reached), so none of them could
# ever touch the operator's real default vault even under a future refactor.
echo "Test 2: usage / arg errors"
GUARDVAULT="$tmpdir/guardvault-unused"
node "$SCRIPT" --vault "$GUARDVAULT" -h >/dev/null 2>&1; assert "-h exits 0" 0 "$?"
node "$SCRIPT" --vault "$GUARDVAULT" --mode feed --sender a --date 2026-08-13 --vessel x >/dev/null 2>&1
assert "missing --msg-id exits 1" 1 "$?"
node "$SCRIPT" --vault "$GUARDVAULT" --mode bogus --msg-id 1 --sender a >/dev/null 2>&1
assert "bad --mode exits 1" 1 "$?"
node "$SCRIPT" --vault "$GUARDVAULT" --mode feed --msg-id 1 --sender a --vessel x >/dev/null 2>&1
assert "feed mode missing --date exits 1" 1 "$?"
node "$SCRIPT" --vault "$GUARDVAULT" --mode feed --msg-id 1 --sender a --date 2026-08-13 >/dev/null 2>&1
assert "feed mode missing --vessel exits 1" 1 "$?"
node "$SCRIPT" --vault "$GUARDVAULT" --mode product --msg-id 1 --sender a >/dev/null 2>&1
assert "product mode missing --product exits 1" 1 "$?"
node "$SCRIPT" --vault "$GUARDVAULT" --mode product --msg-id 1 --sender a --product p >/dev/null 2>&1
assert "product mode missing --body-file exits 1" 1 "$?"
node "$SCRIPT" --vault "$GUARDVAULT" --mode feed --msg-id 1 --date 2026-08-13 --vessel x >/dev/null 2>&1
assert "missing --sender exits 2" 2 "$?"
node "$SCRIPT" --vault "$GUARDVAULT" --weird >/dev/null 2>&1; assert "unknown arg exits 1" 1 "$?"

# -- Test 3: vault validation -------------------------------------------------
echo "Test 3: vault validation"
NOVAULT="$tmpdir/novault"; mkdir -p "$NOVAULT"
node "$SCRIPT" --vault "$NOVAULT" --mode feed --msg-id 1 --sender a --date 2026-08-13 --vessel x >/dev/null 2>&1
assert "vault without .obsidian exits 2" 2 "$?"

NOTARGET="$tmpdir/novtarget"; mkdir -p "$NOTARGET/.obsidian"
node "$SCRIPT" --vault "$NOTARGET" --mode feed --msg-id 1 --sender a --date 2026-08-13 --vessel x >/dev/null 2>&1
assert "vault without target file exits 2" 2 "$?"

NOTABLE="$tmpdir/notable"; mkdir -p "$NOTABLE/.obsidian" "$NOTABLE/20-Areas/Grow"
printf '# no log table here\n' > "$NOTABLE/20-Areas/Grow/Grow-Feeding-Log.md"
node "$SCRIPT" --vault "$NOTABLE" --mode feed --msg-id 1 --sender a --date 2026-08-13 --vessel x >/dev/null 2>&1
assert "target file without ## Log table exits 2" 2 "$?"

# -- Test 4: feed row appended in the right place ----------------------------
echo "Test 4: feed row placement"
VAULT="$tmpdir/vault"
make_vault "$VAULT"
TARGET="$VAULT/20-Areas/Grow/Grow-Feeding-Log.md"

out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 100 --sender alice --ts 2026-08-13T10:00:00Z \
  --date 2026-08-13 --vessel "Small tent — mint (LECHUZA reservoir)" --water "5 L" \
  --product "GREEN24 Pfeffer- / Apfel-Minze (Mentha)" --dose "2 caps = 10 ml" 2>&1)"
rc=$?
assert "feed write exits 0" 0 "$rc"
echo "$out" | grep -q '^✓ grow-feed-log: appended feed row' && a=ok || a=no
assert "feed write status line" ok "$a"

n=$(grep -c '^| 2026-08-13 |' "$TARGET")
assert "new row present exactly once" 1 "$n"
# it landed as the row directly after the existing one, inside the table:
# pipe-lines under ## Log in order are header, separator, data-row-1
# (original), data-row-2 (new) -> the 4th pipe-line must be our new row.
row2=$(awk '/^## Log/{f=1;next} f && /^## /{f=0} f' "$TARGET" | grep '^|' | sed -n '4p')
echo "$row2" | grep -q '^| 2026-08-13 |' && a=ok || a=no
assert "new row is the 2nd data row (right after the existing one)" ok "$a"
# ## Products untouched (still exactly one product subsection, unchanged)
n=$(grep -c '^### GREEN24' "$TARGET")
assert "## Products untouched (still 1 product heading)" 1 "$n"
grep -q '^### GREEN24 Pfeffer- / Apfel-Minze (Mentha)$' "$TARGET" && a=ok || a=no
assert "GREEN24 product heading exact text preserved" ok "$a"
# table still well-formed: every ## Log data row has 5 cells (6 pipes)
badrows=$(awk '/^## Log/{f=1} f && /^\|/{c++; if(c>2){n=gsub(/\|/,"|"); if(n!=6) bad++}} f && /^$/{exit} END{print bad+0}' "$TARGET")
assert "every data row has 5 cells" 0 "$badrows"

# -- Test 5: idempotent re-run -----------------------------------------------
echo "Test 5: idempotent re-run"
before_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 100 --sender alice --date 2026-08-13 --vessel x 2>&1)"
rc=$?
assert "re-run exits 0" 0 "$rc"
echo "$out" | grep -q 'already-logged' && a=ok || a=no
assert "re-run reports already-logged" ok "$a"
after_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
assert "re-run leaves file byte-identical" "$before_sha" "$after_sha"

# -- Test 6: pipe + newline sanitization -------------------------------------
echo "Test 6: cell sanitization"
printf 'checked with pen, a bit high | edge case\r\nsecond line\n' > "$tmpdir/note.txt"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 101 --sender alice --date 2026-08-14 \
  --vessel "Small tent — mint (LECHUZA reservoir)" --ec "1.8" --note-file "$tmpdir/note.txt" 2>&1)"
assert "sanitized-note write exits 0" 0 "$?"
row=$(grep '^| 2026-08-14 |' "$TARGET")
echo "$row" | grep -q 'edge case \\| edge case' && a=UNEXPECTED_DUP || a=ok
assert "no accidental duplication" ok "$a"
echo "$row" | grep -q 'a bit high \\| edge case second line' && a=ok || a=no
assert "pipe escaped + CRLF/newline collapsed to single space" ok "$a"
n=$(printf '%s' "$row" | wc -l | tr -d ' ')
assert "written row has no raw embedded newline" 0 "$n"

# -- Test 7: --dry-run writes nothing -----------------------------------------
echo "Test 7: --dry-run"
before_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 999 --sender alice --date 2026-08-15 --vessel x --dry-run 2>&1)"
rc=$?
assert "dry-run exits 0" 0 "$rc"
echo "$out" | grep -q 'dry-run' && a=ok || a=no
assert "dry-run announces" ok "$a"
after_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
assert "dry-run wrote nothing (byte-identical)" "$before_sha" "$after_sha"

# -- Test 8: product mode -----------------------------------------------------
echo "Test 8: product mode"
printf 'A new veg feed concentrate.\n\n- Cap volume = 5 ml.\n- Label dose: 1 cap/L.\n' > "$tmpdir/body.txt"
out="$(node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 200 --sender alice --product "BioBizz Grow" --body-file "$tmpdir/body.txt" 2>&1)"
rc=$?
assert "product write exits 0" 0 "$rc"
echo "$out" | grep -q '^✓ grow-feed-log: appended product section' && a=ok || a=no
assert "product write status line" ok "$a"
grep -q '^### BioBizz Grow$' "$TARGET" && a=ok || a=no
assert "product heading written" ok "$a"
# heading order: BioBizz Grow must come before ## Notes
biobizz_line=$(grep -n '^### BioBizz Grow$' "$TARGET" | cut -d: -f1)
notes_line=$(grep -n '^## Notes$' "$TARGET" | cut -d: -f1)
if [ "$biobizz_line" -lt "$notes_line" ]; then a=ok; else a=no; fi
assert "product section inserted before ## Notes" ok "$a"

# re-run same product name (different msg-id) -> skip (product-exists), no duplicate
out="$(node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 201 --sender alice --product "BioBizz Grow" --body-file "$tmpdir/body.txt" 2>&1)"
rc=$?
assert "product re-run exits 0" 0 "$rc"
echo "$out" | grep -q 'product-exists' && a=ok || a=no
assert "product re-run reports product-exists" ok "$a"
n=$(grep -c '^### BioBizz Grow$' "$TARGET")
assert "no duplicate product heading" 1 "$n"

# -- Test 9: updated: frontmatter bump on real write only ---------------------
echo "Test 9: updated: bump"
# TODAY defaults to system date unless GROW_FEED_LOG_TODAY is set; re-derive
# expected value the same way the tool does, via env override for determinism.
GROW_FEED_LOG_TODAY=2026-08-20
export GROW_FEED_LOG_TODAY
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 300 --sender alice --date 2026-08-16 --vessel x 2>&1)"
assert "bump-test write exits 0" 0 "$?"
grep -q '^updated: 2026-08-20$' "$TARGET" && a=ok || a=no
assert "updated: bumped to GROW_FEED_LOG_TODAY on real write" ok "$a"
unset GROW_FEED_LOG_TODAY

# -- Test 10: dedup is mode-scoped + boundary-safe (regression) --------------
# A product-mode call and a feed-mode call sharing ONE --msg-id (the exact
# flow SKILL.md Step 0 instructs: file a new product, then its feed row, same
# message) must BOTH write — the second must not see the first's provenance
# comment as "already logged" just because the id substring matches.
echo "Test 10: dedup is mode-scoped + boundary-safe"
printf 'Fresh concentrate.\n' > "$tmpdir/body2.txt"
out="$(node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 700 --sender alice --product "NewCo Bloom" --body-file "$tmpdir/body2.txt" 2>&1)"
assert "combo: product-mode call exits 0" 0 "$?"
echo "$out" | grep -q '^✓ grow-feed-log: appended product section' && a=ok || a=no
assert "combo: product section appended" ok "$a"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 700 --sender alice --date 2026-08-17 --vessel x --product "NewCo Bloom" 2>&1)"
assert "combo: feed-mode call (same msg-id) exits 0" 0 "$?"
echo "$out" | grep -q '^✓ grow-feed-log: appended feed row' && a=ok || a=no
assert "combo: feed row appended, NOT skipped as already-logged" ok "$a"
n=$(grep -c '^| 2026-08-17 |' "$TARGET")
assert "combo: feed row present exactly once" 1 "$n"

# Boundary-safety: the file now contains "tg:700 product" and "tg:700 feed".
# A SHORTER id that is a textual prefix of "700" (here "70") must NOT be
# treated as already-logged.
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 70 --sender alice --date 2026-08-18 --vessel x 2>&1)"
assert "short-id-prefix-of-existing-id call exits 0" 0 "$?"
echo "$out" | grep -q '^✓ grow-feed-log: appended feed row' && a=ok || a=no
assert "short id '70' not shadowed by existing 'tg:700'" ok "$a"

# A genuine same-mode same-id re-run is still correctly deduped (unchanged
# behaviour — this is the case Test 5 also covers for a different msg-id).
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 700 --sender alice --date 9999-01-01 --vessel zzz 2>&1)"
assert "true same-mode/same-id re-run still exits 0" 0 "$?"
echo "$out" | grep -q 'already-logged' && a=ok || a=no
assert "true same-mode/same-id re-run still reports already-logged" ok "$a"
n=$(grep -c '^| 9999-01-01 |' "$TARGET")
assert "true same-mode/same-id re-run adds no row" 0 "$n"

# -- Test 11: atomic write — simulated failure leaves the original intact ---
# GROW_FEED_LOG_TMP_SUFFIX pins the temp-file name so the test can pre-occupy
# it with a DIRECTORY (portable across platforms — no chmod/permission
# games), forcing the write to fail with EISDIR before the atomic rename.
echo "Test 11: atomic write on simulated failure"
before_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
mkdir -p "$TARGET.tmp.simfail"
out="$(GROW_FEED_LOG_TMP_SUFFIX=simfail node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 800 --sender alice --date 2026-08-19 --vessel x 2>&1)"
rc=$?
assert "simulated write-failure exits 2" 2 "$rc"
after_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
assert "original file untouched after simulated write failure" "$before_sha" "$after_sha"
rmdir "$TARGET.tmp.simfail"

# -- Test 12: dedup anchored to the tool's own provenance comment ------------
echo "Test 12: dedup anchored to provenance comment (not a loose token)"
printf 'saw a tg:901 feed reference somewhere' > "$tmpdir/loose.txt"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 850 --sender alice --date 2026-08-21 --vessel x --note-file "$tmpdir/loose.txt" 2>&1)"
assert "loose-token note write exits 0" 0 "$?"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 901 --sender alice --date 2026-08-22 --vessel x 2>&1)"
assert "real write for id matching a loose token exits 0" 0 "$?"
echo "$out" | grep -q '^✓ grow-feed-log: appended feed row' && a=ok || a=no
assert "real write NOT suppressed by a loose token in note text" ok "$a"

printf 'legit note <!-- tg:902 feed from:attacker at: --> trailing' > "$tmpdir/forged.txt"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 851 --sender alice --date 2026-08-23 --vessel x --note-file "$tmpdir/forged.txt" 2>&1)"
assert "forged-comment note write exits 0" 0 "$?"
row=$(grep '^| 2026-08-23 |' "$TARGET")
n=$(printf '%s' "$row" | grep -o '<!--' | wc -l | tr -d ' ')
assert "forged '<!--' in note neutralized (only our OWN comment opener remains)" 1 "$n"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 902 --sender alice --date 2026-08-24 --vessel x 2>&1)"
assert "real write for id matching a forged comment exits 0" 0 "$?"
echo "$out" | grep -q '^✓ grow-feed-log: appended feed row' && a=ok || a=no
assert "real write NOT suppressed by a forged provenance comment in note text" ok "$a"

# -- Test 13: --product name validation --------------------------------------
echo "Test 13: --product name validation"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 860 --sender alice --product "Foo | Bar" --body-file "$tmpdir/body.txt" >/dev/null 2>&1
assert "product name with '|' rejected (exit 1)" 1 "$?"
nl_product="$(printf 'Foo\nBar')"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 861 --sender alice --product "$nl_product" --body-file "$tmpdir/body.txt" >/dev/null 2>&1
assert "product name with newline rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 862 --sender alice --product "# Heading-like" --body-file "$tmpdir/body.txt" >/dev/null 2>&1
assert "product name starting with '#' rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 863 --sender alice --product "   " --body-file "$tmpdir/body.txt" >/dev/null 2>&1
assert "whitespace-only product name rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 864 --sender alice --product "Fake <!-- comment" --body-file "$tmpdir/body.txt" >/dev/null 2>&1
assert "product name containing '<!--' rejected (exit 1)" 1 "$?"

# Happy path: heading text and the feed row's wikilink anchor must be
# byte-identical for the SAME normalized name.
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 865 --sender alice --date 2026-08-25 --vessel x --product "BioBizz Grow" 2>&1)"
assert "feed row with existing product name exits 0" 0 "$?"
grep -q '^| 2026-08-25 .*\[\[#BioBizz Grow\]\]' "$TARGET" && a=ok || a=no
assert "wikilink anchor text matches the '### BioBizz Grow' heading exactly" ok "$a"

# -- Test 14: a flag with no following value is a usage error ----------------
# This is the ONE invocation in this suite without a single well-formed
# --vault: a first, VALID --vault (scratch dir, never reached — parseArgs
# dies before main() ever calls resolveVault) is included so the test still
# satisfies "always pass an explicit --vault", while the trailing bare
# --vault (last token, no value) is the exact incident-reproducing case
# finding 6 covers — this IS what it must test, so it can't also be "fixed"
# without defeating the test's purpose.
echo "Test 14: missing flag value"
node "$SCRIPT" --vault "$tmpdir/guardvault-unused" --mode feed --msg-id 1 --sender a --date 2026-08-13 --vessel x --vault >/dev/null 2>&1
assert "trailing --vault with no value exits 1" 1 "$?"

# -- Test 15: productHeadingExists is scoped to ## Products only -------------
echo "Test 15: product-heading scope"
SCOPEVAULT="$tmpdir/scopevault"
mkdir -p "$SCOPEVAULT/.obsidian" "$SCOPEVAULT/20-Areas/Grow"
cat > "$SCOPEVAULT/20-Areas/Grow/Grow-Feeding-Log.md" <<'EOF'
---
type: area
updated: 2026-08-12
---

## Log

| Date | Vessel | Water | Nutrients | EC/notes |
|---|---|---|---|---|
| 2026-08-12 | v | 5 L | dose | notes |

## Products

### Existing Product

body

## Notes

- see ### Ghost Product mentioned in prose here (not a real heading)
EOF
printf 'real body\n' > "$tmpdir/ghost-body.txt"
out="$(node "$SCRIPT" --vault "$SCOPEVAULT" --mode product --msg-id 1 --sender alice --product "Ghost Product" --body-file "$tmpdir/ghost-body.txt" 2>&1)"
assert "product write exits 0 despite a same-name '###' string in ## Notes prose" 0 "$?"
echo "$out" | grep -q '^✓ grow-feed-log: appended product section' && a=ok || a=no
assert "product-exists check ignores '###' text outside ## Products" ok "$a"

# -- Test 16: resolved-target safety line, on stderr, all three branches ----
# The safety line (HIMMEL-130 review hardening, added after the vault
# incident) has no other coverage — a safety mechanism with no test regresses
# silently, and this is the one meant to catch an unannounced write before it
# happens. Compute the expected absolute vault/target strings the SAME way
# the tool does (node's own path.resolve), so this doesn't hardcode a
# separator style (backslash on this Windows box) or depend on how $VAULT
# happens to be spelled. stdout and stderr are captured SEPARATELY — the
# status lines are stdout, the safety line is stderr — via a stderr file
# rather than combining them.
echo "Test 16: resolved-target safety line (stderr, all branches)"
expected_vault_abs="$(node -e "console.log(require('path').resolve(process.argv[1]))" "$VAULT")"
expected_target_abs="$(node -e "console.log(require('path').resolve(process.argv[1], '20-Areas/Grow/Grow-Feeding-Log.md'))" "$VAULT")"
expected_safety_line="grow-feed-log: target vault=${expected_vault_abs} file=${expected_target_abs}"
stderr16="$tmpdir/stderr16"

# Branch 1: real write.
stdout16="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 950 --sender alice --date 2026-08-26 --vessel x 2>"$stderr16")"
assert "safety-line real-write: CLI exits 0" 0 "$?"
serr16="$(cat "$stderr16")"
[ "$serr16" = "$expected_safety_line" ] && a=ok || a=no
assert "safety-line emitted on real write, exact vault+target path" ok "$a"
echo "$stdout16" | grep -q '^✓ grow-feed-log: appended feed row' && a=ok || a=no
assert "safety-line real-write: stdout still carries the ✓ status line" ok "$a"

# Branch 2: --dry-run.
stdout16="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 951 --sender alice --date 2026-08-27 --vessel x --dry-run 2>"$stderr16")"
assert "safety-line dry-run: CLI exits 0" 0 "$?"
serr16="$(cat "$stderr16")"
[ "$serr16" = "$expected_safety_line" ] && a=ok || a=no
assert "safety-line emitted on --dry-run, exact vault+target path" ok "$a"

# Branch 3: already-logged skip (re-run msg-id 950 from Branch 1).
stdout16="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 950 --sender alice --date 2026-08-26 --vessel x 2>"$stderr16")"
assert "safety-line skip: CLI exits 0" 0 "$?"
serr16="$(cat "$stderr16")"
[ "$serr16" = "$expected_safety_line" ] && a=ok || a=no
assert "safety-line emitted on already-logged skip, exact vault+target path" ok "$a"
echo "$stdout16" | grep -q 'already-logged' && a=ok || a=no
assert "safety-line skip: stdout still carries the ⊘ status line" ok "$a"

# -- Test 17: required flags validate AFTER trimming, not raw truthiness ----
# `if (!args.msgId)` is truthy for a whitespace-only value, which then
# sanitizes to an empty idempotency key — so two DIFFERENT whitespace-only
# msg-ids used to collide into ONE dedup key, silently skipping the second as
# "already-logged". Pinned against the pre-fix code at commit 55dfc90e before
# writing these assertions (not just asserted blind): the old tool wrote the
# first with a garbled `(tg:  )` status line (exit 0) and then skipped the
# second, DIFFERENT whitespace-only id as already-logged (exit 0) — the exact
# silent-loss shape this test guards against.
echo "Test 17: whitespace-only required flags validate after trimming"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id "   " --sender alice --date 2026-08-28 --vessel x >/dev/null 2>&1
assert "whitespace-only --msg-id exits 1 (not silently accepted)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 970 --sender "   " --date 2026-08-28 --vessel x >/dev/null 2>&1
assert "whitespace-only --sender exits 2 (not silently accepted)" 2 "$?"

# The actual data-loss scenario: two DIFFERENT whitespace-only ids. Neither
# may succeed, and — the specific old failure mode — the second must NOT be
# reported as "already-logged" (that would mean it silently collided with the
# first instead of being independently rejected).
out1="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id "  " --sender alice --date 2026-08-29 --vessel x 2>&1)"
rc1=$?
out2="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id " " --sender alice --date 2026-08-30 --vessel x 2>&1)"
rc2=$?
assert "first whitespace-only msg-id ('  ') exits 1" 1 "$rc1"
assert "second, DIFFERENT whitespace-only msg-id (' ') also exits 1" 1 "$rc2"
echo "$out1" | grep -q 'already-logged' && a=COLLIDED || a=ok
assert "first whitespace-only msg-id NOT reported as already-logged" ok "$a"
echo "$out2" | grep -q 'already-logged' && a=COLLIDED || a=ok
assert "second whitespace-only msg-id NOT reported as already-logged (no collision)" ok "$a"
n=$(grep -c '^| 2026-08-29 |\|^| 2026-08-30 |' "$TARGET")
assert "neither whitespace-only attempt wrote a row" 0 "$n"

# Round 5 superseded the round-2 sanitize-and-display posture this block
# used to pin: a msg-id carrying ANY character sanitizeCell would rewrite
# (here '|') is now rejected outright, because the id is the dedup key
# embedded in a whitespace-delimited provenance field — a key that needs
# rewriting cannot be guaranteed to survive as one unambiguous field.
# Test 26 pins the collision mechanism itself.
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id "ab|cd" --sender alice --date 2026-09-01 --vessel x >/dev/null 2>&1
assert "pipe-containing msg-id rejected (exit 1) — key characters are never rewritten" 1 "$?"

# -- Test 18: real-path containment against a symlink/junction escape -------
# The lexical containment check compares path STRINGS, so a junction/symlink
# anywhere under the vault (here: `20-Areas` itself) that points OUTSIDE the
# vault would pass it while the actual write lands elsewhere. Uses an NTFS
# junction (mklink /J) — unlike a symlink, junctions don't need elevation on
# Windows. Skips cleanly (not a fail) if this environment can't create one.
echo "Test 18: real-path containment (symlink/junction escape)"
JUNCVAULT="$tmpdir/juncvault"
JUNCOUTSIDE="$tmpdir/juncoutside"
mkdir -p "$JUNCVAULT/.obsidian"
mkdir -p "$JUNCOUTSIDE/Grow"
cat > "$JUNCOUTSIDE/Grow/Grow-Feeding-Log.md" <<'EOF'
---
type: area
updated: 2026-08-12
---

## Log

| Date | Vessel | Water | Nutrients | EC/notes |
|---|---|---|---|---|
| 2026-08-12 | v | 5 L | dose | notes |

## Products

### Existing Product

body

## Notes
EOF
if command -v cygpath >/dev/null 2>&1 && MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$JUNCVAULT/20-Areas")" "$(cygpath -w "$JUNCOUTSIDE")" >/dev/null 2>&1; then
  out="$(node "$SCRIPT" --vault "$JUNCVAULT" --mode feed --msg-id 1 --sender alice --date 2026-08-13 --vessel x 2>&1)"
  rc=$?
  assert "junction-escape write refused (exit 2)" 2 "$rc"
  echo "$out" | grep -q 'symlink/junction escape' && a=ok || a=no
  assert "junction-escape error names the real-path containment check" ok "$a"
  n=$(grep -c '^| 2026-08-13 |' "$JUNCOUTSIDE/Grow/Grow-Feeding-Log.md")
  assert "junction-escape refusal wrote nothing outside the vault" 0 "$n"
else
  echo "  SKIP  junction-escape containment test (mklink /J unavailable or denied in this environment)"
fi

# -- Test 19: lost-write race — one retry, then loud (not silent) failure ---
# codex-adv-r2-1, scoped down: no cross-process lock (dispatch is serialized
# from a single telegram session; a lock wouldn't cover Obsidian editing the
# file live anyway) — instead, verify after every write and retry once, so a
# genuinely lost race either self-heals or fails LOUD instead of reporting a
# false ✓. GROW_FEED_LOG_SIMULATE_LOST_WRITE clobbers the file back to its
# pre-write snapshot immediately after our own real write, faithfully
# reproducing what a losing race looks like on disk (not just a faked
# boolean), so the retry path is exercised for real.
echo "Test 19: lost-write race — retry once, then fail loud"
LWVAULT="$tmpdir/lwvault"
make_vault "$LWVAULT"
LWTARGET="$LWVAULT/20-Areas/Grow/Grow-Feeding-Log.md"

out="$(GROW_FEED_LOG_SIMULATE_LOST_WRITE=1 node "$SCRIPT" --vault "$LWVAULT" --mode feed --msg-id 1 --sender alice --date 2026-08-13 --vessel x 2>&1)"
rc=$?
assert "one simulated lost write: CLI exits 0 (recovered via the retry)" 0 "$rc"
echo "$out" | grep -q '^✓ grow-feed-log: appended feed row' && a=ok || a=no
assert "one simulated lost write: ✓ printed only after the retry genuinely lands the row" ok "$a"
n=$(grep -c '^| 2026-08-13 |' "$LWTARGET")
assert "one simulated lost write: the row really is present after recovery" 1 "$n"

out="$(GROW_FEED_LOG_SIMULATE_LOST_WRITE=2 node "$SCRIPT" --vault "$LWVAULT" --mode feed --msg-id 2 --sender alice --date 2026-08-14 --vessel x 2>&1)"
rc=$?
assert "two simulated lost writes (exhausts the retry): exits 2 (write failure per the header contract, not a usage error)" 2 "$rc"
echo "$out" | grep -q '✓' && a=FALSE_POSITIVE || a=ok
assert "two simulated lost writes: does NOT print a false ✓" ok "$a"
echo "$out" | grep -q 'lost a concurrent-write race' && a=ok || a=no
assert "two simulated lost writes: error names the race explicitly" ok "$a"
n=$(grep -c '^| 2026-08-14 |' "$LWTARGET")
assert "two simulated lost writes: no row silently left behind" 0 "$n"

# -- Test 20: stale snapshot is re-derived; concurrent edit is preserved -----
# This is the opposite race ordering from Test 19: another writer appends
# AFTER our snapshot/build but BEFORE our rename. Pre-fix writeAtomic blindly
# renamed the stale snapshot over this edit and still printed ✓. The test hook
# performs that external append immediately before the stale check; the first
# attempt must refuse, then the retry must derive its insert from the fresh file.
echo "Test 20: stale-snapshot freshness preserves concurrent edits"
FRESHVAULT="$tmpdir/freshvault"
make_vault "$FRESHVAULT"
FRESHTARGET="$FRESHVAULT/20-Areas/Grow/Grow-Feeding-Log.md"
printf '\n- concurrent Obsidian edit\n' > "$tmpdir/concurrent-append.txt"
out="$(GROW_FEED_LOG_BEFORE_RENAME_APPEND_FILE="$tmpdir/concurrent-append.txt" node "$SCRIPT" --vault "$FRESHVAULT" --mode feed --msg-id 3 --sender alice --date 2026-08-15 --vessel x 2>&1)"
rc=$?
assert "stale snapshot: CLI exits 0 after rebuilding from fresh state" 0 "$rc"
echo "$out" | grep -q '^✓ grow-feed-log: appended feed row' && a=ok || a=no
assert "stale snapshot: success is reported only after the rebuilt write lands" ok "$a"
n=$(grep -c '^- concurrent Obsidian edit$' "$FRESHTARGET")
assert "stale snapshot: concurrent Obsidian edit is preserved exactly once" 1 "$n"
n=$(grep -c '^| 2026-08-15 |' "$FRESHTARGET")
assert "stale snapshot: requested feed row is added exactly once" 1 "$n"

# -- Test 21: feed product must exist in ## Products --------------------------
# The runbook declares ## Products authoritative. Accepting an arbitrary
# --product would let an extraction mistake create a broken [[#...]] link.
echo "Test 21: feed product requires an existing Products heading"
PRODUCTVAULT="$tmpdir/productauthority"
make_vault "$PRODUCTVAULT"
PRODUCTTARGET="$PRODUCTVAULT/20-Areas/Grow/Grow-Feeding-Log.md"
before_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$PRODUCTTARGET")"
out="$(node "$SCRIPT" --vault "$PRODUCTVAULT" --mode feed --msg-id 4 --sender alice --date 2026-08-16 --vessel x --product "Missing Product" 2>&1)"
rc=$?
assert "missing product heading: feed write is refused (exit 2)" 2 "$rc"
echo "$out" | grep -q 'product not found in ## Products' && a=ok || a=no
assert "missing product heading: error names the Products authority" ok "$a"
after_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$PRODUCTTARGET")"
assert "missing product heading: refusal leaves file byte-identical" "$before_sha" "$after_sha"

# -- Test 22: containment predicate — positive-proof unit cases -------------
# CR round 4: on Windows, path.relative() returns an ABSOLUTE path when base
# and full sit on different drives (it cannot express a cross-drive
# traversal), so the old escape-shape predicate — "does rel start with '..',
# does it resolve() back" — passed BOTH its guards and the write proceeded
# outside the vault. Round 2 had already bypassed the same predicate through
# a junction. The fix replaces shape-inference with a positive parent-chain
# membership proof (isContainedIn, exported for exactly this test); these
# cases are pure path algebra on strings, so no D: drive has to exist —
# which is also WHY this is a unit test: a junction to a second volume can't
# be created portably, and a subst-mapped drive letter is resolved away by
# realpathSync before the check would ever see it. Cases that only exist
# under Windows path semantics announce their skip on POSIX instead of
# silently no-opping.
echo "Test 22: containment predicate unit cases (cross-drive = round-4 ratchet)"
cat > "$tmpdir/contain-cases.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
const { isContainedIn } = await import(pathToFileURL(process.argv[2]).href);
const cases = [];
const add = (desc, base, full, want) => cases.push({ desc, base, full, want });
if (process.platform === "win32") {
  add("deep child is contained", "C:\\v\\vault", "C:\\v\\vault\\20-Areas\\Grow\\log.md", true);
  add("base itself is contained (self)", "C:\\v\\vault", "C:\\v\\vault", true);
  add("case-variant child is contained (NTFS is case-insensitive)", "C:\\V\\Vault", "c:\\v\\vault\\x.md", true);
  add("sibling with base as name-prefix is NOT contained", "C:\\v\\vault", "C:\\v\\vault-evil\\x.md", false);
  add("parent is NOT contained", "C:\\v\\vault", "C:\\v", false);
  add("same-drive unrelated path is NOT contained", "C:\\v\\vault", "C:\\other\\x.md", false);
  // THE round-4 bypass: cross-drive. relative(base, full) here is the
  // ABSOLUTE "D:\\evil\\x.md" — no leading "..", unchanged by resolve().
  add("cross-drive full is NOT contained (round-4 bypass)", "C:\\v\\vault", "D:\\evil\\x.md", false);
  add("cross-drive full mirroring the vault layout is NOT contained", "C:\\v\\vault", "D:\\v\\vault\\x.md", false);
  add("UNC full vs drive-letter base is NOT contained", "C:\\v\\vault", "\\\\srv\\share\\x.md", false);
} else {
  add("deep child is contained", "/v/vault", "/v/vault/20-Areas/Grow/log.md", true);
  add("base itself is contained (self)", "/v/vault", "/v/vault", true);
  add("sibling with base as name-prefix is NOT contained", "/v/vault", "/v/vault-evil/x.md", false);
  add("parent is NOT contained", "/v/vault", "/v", false);
  add("root-level unrelated path is NOT contained", "/v/vault", "/etc/passwd", false);
  console.log("SKIP cross-drive + UNC + case-variant cases (Windows path semantics only: a single POSIX root cannot make relative() return an absolute path, so the round-4 bypass shape is structurally unreachable here)");
}
let bad = 0;
for (const c of cases) {
  const got = isContainedIn(c.base, c.full);
  if (got === c.want) console.log(`ok ${c.desc}`);
  else { console.log(`BAD ${c.desc}: isContainedIn(${c.base}, ${c.full}) = ${got}, want ${c.want}`); bad++; }
}
process.exit(bad === 0 ? 0 : 1);
EOF
out="$(node "$tmpdir/contain-cases.mjs" "$SCRIPT" 2>&1)"
rc=$?
assert "all containment predicate unit cases hold" 0 "$rc"
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" | sed 's/^/         /'; fi
if echo "$out" | grep -q '^ok cross-drive full is NOT contained'; then a=ok
elif echo "$out" | grep -q '^SKIP cross-drive'; then a=ok; echo "  SKIP  cross-drive predicate cases (POSIX — announced by the unit runner above)"
else a=no; fi
assert "cross-drive case ran (win32) or announced its skip (POSIX)" ok "$a"

# -- Test 23: temp-file suffix cannot relocate the write --------------------
# The atomic-write temp path is `<target>.tmp.<suffix>`. Containment is
# proven for <target>, and the temp file inherits that proof ONLY while the
# suffix stays inside the target's basename — a suffix smuggling a path
# separator (or an NTFS alternate-data-stream ':') would move the write to
# a path nothing ever checked. Must refuse outright (exit 2), leaving the
# target untouched.
echo "Test 23: tmp-suffix path separators refused"
TSVAULT="$tmpdir/tsvault"
make_vault "$TSVAULT"
TSTARGET="$TSVAULT/20-Areas/Grow/Grow-Feeding-Log.md"
before_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TSTARGET")"
out="$(GROW_FEED_LOG_TMP_SUFFIX='../escape' node "$SCRIPT" --vault "$TSVAULT" --mode feed --msg-id 1 --sender alice --date 2026-08-13 --vessel x 2>&1)"
rc=$?
assert "slash-carrying tmp suffix refused (exit 2)" 2 "$rc"
echo "$out" | grep -q 'path-safety' && a=ok || a=no
assert "slash-suffix refusal names path-safety" ok "$a"
out="$(GROW_FEED_LOG_TMP_SUFFIX='..\escape' node "$SCRIPT" --vault "$TSVAULT" --mode feed --msg-id 2 --sender alice --date 2026-08-13 --vessel x 2>&1)"
assert "backslash-carrying tmp suffix refused (exit 2)" 2 "$?"
out="$(GROW_FEED_LOG_TMP_SUFFIX='x:ads' node "$SCRIPT" --vault "$TSVAULT" --mode feed --msg-id 3 --sender alice --date 2026-08-13 --vessel x 2>&1)"
assert "colon-carrying (ADS) tmp suffix refused (exit 2)" 2 "$?"
after_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TSTARGET")"
assert "target byte-identical after all refused tmp-suffix attempts" "$before_sha" "$after_sha"

# -- Test 24: product name cannot break its own wikilink anchor -------------
# normalizeProductName validated the name for the table-cell, heading, and
# comment contexts — but the SAME value reaches a fourth context, the
# `[[#<name>]]` anchor. A ']]' in the name closes the link early, silently
# detaching the feed row from the ## Products heading that round 3 made
# authoritative. Reject the link-breaking sequences; single brackets stay
# legal (real product names like "Cal-Mag [10L]" must not be over-blocked).
echo "Test 24: product name wikilink-anchor integrity"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 866 --sender alice --product "Foo ]] Bar" --body-file "$tmpdir/body.txt" >/dev/null 2>&1
assert "product name with ']]' rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 867 --sender alice --product "Foo [[Bar" --body-file "$tmpdir/body.txt" >/dev/null 2>&1
assert "product name with '[[' rejected (exit 1)" 1 "$?"
out="$(node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 868 --sender alice --product "Cal-Mag [10L]" --body-file "$tmpdir/body.txt" 2>&1)"
assert "product name with single brackets still accepted (exit 0)" 0 "$?"
grep -q '^### Cal-Mag \[10L\]$' "$TARGET" && a=ok || a=no
assert "single-bracket product heading written intact" ok "$a"

# -- Test 25: explicitly blank flag values are rejected, never defaulted ----
# Round 2's defect class one level up: deciding "was this flag given?" on
# RAW truthiness makes `--vault ""` indistinguishable from an ABSENT --vault
# — and an absent --vault targets the operator's REAL vault by design. The
# blank value must die as a usage error, exactly like the trailing bare
# `--vault` (Test 14), which is the same incident through the other door.
echo "Test 25: explicitly blank flag values are rejected, never defaulted"
node "$SCRIPT" --vault "" --mode feed --msg-id 1 --sender a --date 2026-08-13 --vessel x >/dev/null 2>&1
assert "--vault '' exits 1 (never falls through to the default vault)" 1 "$?"
node "$SCRIPT" --vault "   " --mode feed --msg-id 1 --sender a --date 2026-08-13 --vessel x >/dev/null 2>&1
assert "whitespace-only --vault exits 1 (never falls through)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 2002 --sender a --date 2026-08-13 --vessel x --product "" >/dev/null 2>&1
assert "feed --product '' exits 1 (not silently treated as no product)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 2002 --sender a --date 2026-08-13 --vessel x --note-file "" >/dev/null 2>&1
assert "--note-file '' exits 1 (not silently treated as no note)" 1 "$?"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 2003 --sender alice --date 2026-09-02 --vessel x --ec '   ' 2>&1)"
assert "whitespace-only --ec write exits 0" 0 "$?"
row=$(grep '^| 2026-09-02 |' "$TARGET")
echo "$row" | grep -q 'EC' && a=DANGLING || a=ok
assert "whitespace-only --ec leaves no dangling 'EC ' prefix in the notes cell" ok "$a"

# -- Test 26: msg-id charset — the dedup key field is unambiguous ------------
# CR round 5 (two independent critics): sanitizeCell collapses newlines to a
# SPACE and internal spaces survive, so `--msg-id "1 feed"` wrote the marker
# `<!-- tg:1 feed feed from:... -->` — which a later, LEGITIMATE
# `--msg-id 1 --mode feed` matched via its `\s+feed\b` regex and silently
# skipped as already-logged: a never-logged entry reported as ⊘ present,
# data loss disguised as success. `\b`/`\s+` were escape-shaped proxies for
# a field boundary the id itself could contain — the same invariant breach
# as the round-4 relative() bug. The fix restricts the id to
# [A-Za-z0-9._:-], so the whitespace-delimited id field on file can NEVER
# contain a delimiter, which turns the anchored dedup regex into an exact
# field-equality comparison (and sanitizeCell into the identity on every
# accepted id: key on file == key compared == key displayed).
echo "Test 26: msg-id charset restriction (round-5 dedup-collision ratchet)"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id "1 feed" --sender alice --date 2026-09-03 --vessel x >/dev/null 2>&1
assert "THE collision input: msg-id '1 feed' rejected (exit 1)" 1 "$?"
tab_id="$(printf '5\t1')"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id "$tab_id" --sender alice --date 2026-09-03 --vessel x >/dev/null 2>&1
assert "msg-id with an embedded tab rejected (exit 1)" 1 "$?"
nl_id="$(printf '5
1')"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id "$nl_id" --sender alice --date 2026-09-03 --vessel x >/dev/null 2>&1
assert "msg-id with an embedded newline rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id '<!--x' --sender alice --date 2026-09-03 --vessel x >/dev/null 2>&1
assert "msg-id with comment-forgery characters rejected (exit 1)" 1 "$?"
# The id shape the skill actually dispatches (numeric telegram message id)
# still round-trips: real write, then exact-field dedup on re-run.
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 5100 --sender alice --date 2026-09-03 --vessel x 2>&1)"
assert "plain numeric msg-id still writes (exit 0)" 0 "$?"
out="$(node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 5100 --sender alice --date 2026-09-03 --vessel x 2>&1)"
assert "numeric msg-id re-run still exits 0" 0 "$?"
echo "$out" | grep -q 'already-logged' && a=ok || a=no
assert "numeric msg-id re-run dedups via the exact-field comparison" ok "$a"

# -- Test 27: a flag-shaped token where a value belongs is a usage error -----
# next() only rejected an ABSENT value; a following flag token was silently
# consumed as the value. The dangerous shape: `--water --dry-run` swallows
# --dry-run, so a requested dry-run becomes a REAL vault write.
echo "Test 27: flag-shaped token is not a value"
node "$SCRIPT" --vault --dry-run --mode feed --msg-id 1 --sender a --date 2026-08-13 --vessel x >/dev/null 2>&1
assert "--vault --dry-run exits 1 (flag token not consumed as a value)" 1 "$?"
before_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 5200 --sender a --date 2026-08-13 --vessel x --water --dry-run >/dev/null 2>&1
assert "--water --dry-run exits 1 (a requested dry-run never becomes a real write)" 1 "$?"
after_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
assert "swallowed-dry-run attempt wrote nothing" "$before_sha" "$after_sha"

# -- Test 28: --date must be YYYY-MM-DD --------------------------------------
# USAGE and SKILL.md advertise YYYY-MM-DD; the value lands in the log
# table's Date column, so a free-form date silently corrupts sort/scan
# semantics. (Valid dates are exercised by every write test above.)
echo "Test 28: --date format validation"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 5210 --sender a --date "13-08-2026" --vessel x >/dev/null 2>&1
assert "--date DD-MM-YYYY rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 5211 --sender a --date "2026-8-13" --vessel x >/dev/null 2>&1
assert "--date with unpadded month rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 5212 --sender a --date "today" --vessel x >/dev/null 2>&1
assert "--date free text rejected (exit 1)" 1 "$?"

# -- Test 29: mode-inapplicable flags are rejected, never silently dropped ---
# A --body-file passed in feed mode is STAGED CONTENT the caller expected to
# land; silently ignoring it loses data behind a ✓. Same reject-don't-guess
# posture as every other guard in the tool.
echo "Test 29: mode-inapplicable flags rejected"
node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 5300 --sender a --date 2026-08-13 --vessel x --body-file "$tmpdir/body.txt" >/dev/null 2>&1
assert "feed mode with --body-file rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 5301 --sender a --product "BioBizz Grow" --body-file "$tmpdir/body.txt" --note-file "$tmpdir/note.txt" >/dev/null 2>&1
assert "product mode with --note-file rejected (exit 1)" 1 "$?"
node "$SCRIPT" --vault "$VAULT" --mode product --msg-id 5302 --sender a --product "BioBizz Grow" --body-file "$tmpdir/body.txt" --ec 1.8 >/dev/null 2>&1
assert "product mode with --ec rejected (exit 1)" 1 "$?"

# -- Test 30: test-only env hooks are refused without the explicit gate ------
# The tool runs from a Telegram-dispatched session; a stray hook variable
# inherited from a test shell could append foreign content to, or clobber, a
# REAL vault write. Without GROW_FEED_LOG_TEST_HOOKS=1 (cleared here for one
# invocation — the suite exports it globally at the top) any set hook is a
# loud exit-2 refusal, never a silently-instrumented write.
echo "Test 30: env hooks refused without GROW_FEED_LOG_TEST_HOOKS=1"
before_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
out="$(GROW_FEED_LOG_TEST_HOOKS='' GROW_FEED_LOG_SIMULATE_LOST_WRITE=1 node "$SCRIPT" --vault "$VAULT" --mode feed --msg-id 5400 --sender a --date 2026-08-13 --vessel x 2>&1)"
rc=$?
assert "stray SIMULATE_LOST_WRITE without the gate exits 2" 2 "$rc"
echo "$out" | grep -q 'GROW_FEED_LOG_TEST_HOOKS' && a=ok || a=no
assert "refusal names the gate and the stray hook" ok "$a"
after_sha="$(node -e "console.log(require('crypto').createHash('sha256').update(require('fs').readFileSync(process.argv[1])).digest('hex'))" "$TARGET")"
assert "gated refusal wrote nothing" "$before_sha" "$after_sha"

# -- Test 31: a product LABEL containing '##' never terminates ## Products -
# The written heading is `### <name>`, and `^##\s+\S` can never match a line
# whose third character is '#' — so a mid-name '##' is inert for section
# parsing and the label door stays CLOSED by the existing reject-leading-'#'
# rule (Test 13). This test PINS both halves so a future "helpful" change
# (escaping the label, or relaxing the rejection) cannot silently reopen the
# door: escaping the label would break the byte-identity the [[#<name>]]
# anchor needs (the round-5 [[/]] lesson), so rejection is the contract.
echo "Test 31: product label containing '##' never terminates ## Products"
LABELVAULT="$tmpdir/labelvault"
make_vault "$LABELVAULT"
LABELTARGET="$LABELVAULT/20-Areas/Grow/Grow-Feeding-Log.md"
printf 'A mix-ratio product.\n' > "$tmpdir/label-body.txt"
out="$(node "$SCRIPT" --vault "$LABELVAULT" --mode product --msg-id 6000 --sender alice --product "Mix ## 1:500 ratio" --body-file "$tmpdir/label-body.txt" 2>&1)"
assert "label containing '##' accepted (exit 0)" 0 "$?"
grep -q '^### Mix ## 1:500 ratio$' "$LABELTARGET" && a=ok || a=no
assert "'##'-containing label heading written verbatim (stays a ### subsection)" ok "$a"
node "$SCRIPT" --vault "$LABELVAULT" --mode product --msg-id 6001 --sender alice --product "## Evil" --body-file "$tmpdir/label-body.txt" >/dev/null 2>&1
assert "label starting with '##' rejected (exit 1)" 1 "$?"
# Full-section LOOKUP by that exact label: productHeadingExists must find the
# heading (round-3 authority) and the wikilink anchor must carry it verbatim.
out="$(node "$SCRIPT" --vault "$LABELVAULT" --mode feed --msg-id 6002 --sender alice --date 2026-09-10 --vessel x --product "Mix ## 1:500 ratio" 2>&1)"
assert "feed lookup by the '##'-containing label exits 0" 0 "$?"
grep -q '^| 2026-09-10 .*\[\[#Mix ## 1:500 ratio\]\]' "$LABELTARGET" && a=ok || a=no
assert "wikilink anchor written verbatim for the '##'-containing label" ok "$a"
# Full-section INSERT after it: the next product must land at the TRUE block
# end (before ## Notes), not at any label-derived truncation point.
out="$(node "$SCRIPT" --vault "$LABELVAULT" --mode product --msg-id 6003 --sender alice --product "After Label Prod" --body-file "$tmpdir/label-body.txt" 2>&1)"
assert "product insert after the '##'-containing label exits 0" 0 "$?"
albl=$(grep -n '^### After Label Prod$' "$LABELTARGET" | cut -d: -f1)
nlbl=$(grep -n '^## Notes$' "$LABELTARGET" | cut -d: -f1)
if [ -n "$albl" ] && [ -n "$nlbl" ] && [ "$albl" -lt "$nlbl" ]; then a=ok; else a=no; fi
assert "next product still lands before ## Notes (section not truncated)" ok "$a"

# -- Test 32: a product BODY '##' line can no longer truncate ## Products ---
# HIMMEL-1798 ratchet. findProductsBlock infers the end of ## Products from
# the next `^## ` heading-shaped line — an escape-shaped proxy over content
# the caller controls. Product body text used to be inserted raw (apart from
# comment neutralization), so an extracted body line like `## Usage notes`
# PREMATURELY TERMINATED the block it was inserted into: the next product's
# section was spliced in BEFORE that line (splitting the first product's
# body mid-section), and any product heading below it fell OUTSIDE the block
# for productHeadingExists — feed mode would refuse an entry the operator
# can plainly see in their vault. The fix entity-escapes the line's first
# `#` (neutralizeHeadings — same escape-not-strip posture as
# neutralizeComments), so tool-inserted content can never form a section
# terminator. Reverting the one-line wiring change makes every assertion
# below go red; that falsification was run for real against this suite.
echo "Test 32: product body '##' line cannot truncate ## Products (HIMMEL-1798 ratchet)"
BODYVAULT="$tmpdir/bodyvault"
make_vault "$BODYVAULT"
BODYTARGET="$BODYVAULT/20-Areas/Grow/Grow-Feeding-Log.md"
printf 'Bogus label transcription.\n\n## Usage notes\n\n- 1 cap/L.\n' > "$tmpdir/bogus-body.txt"
out="$(node "$SCRIPT" --vault "$BODYVAULT" --mode product --msg-id 6100 --sender alice --product "Bogus Body Prod" --body-file "$tmpdir/bogus-body.txt" 2>&1)"
assert "product write with a '##'-carrying body exits 0" 0 "$?"
grep -q '^&#35;# Usage notes$' "$BODYTARGET" && a=ok || a=no
assert "heading-shaped body line entity-escaped on disk (&#35;# Usage notes)" ok "$a"
grep -q '^## Usage notes$' "$BODYTARGET" && a=TRUNCATES || a=ok
assert "NO raw '^## Usage notes' line lands inside ## Products" ok "$a"
grep -q '^- 1 cap/L.$' "$BODYTARGET" && a=ok || a=no
assert "rest of the body byte-preserved around the escape (legible round-trip)" ok "$a"

# Full-section INSERT: the next product's section must land AFTER the first
# product's ENTIRE body (escaped line and tail included), before ## Notes.
# Under the bug it splices at the injected heading line instead — the tail
# line ordering below is the red signal.
printf 'A clean product body.\n' > "$tmpdir/clean-body.txt"
out="$(node "$SCRIPT" --vault "$BODYVAULT" --mode product --msg-id 6101 --sender alice --product "After Body Prod" --body-file "$tmpdir/clean-body.txt" 2>&1)"
assert "second product write after a '##'-carrying body exits 0" 0 "$?"
esc_line=$(grep -n '^&#35;# Usage notes$' "$BODYTARGET" | cut -d: -f1)
tail_line=$(grep -n '^- 1 cap/L.$' "$BODYTARGET" | cut -d: -f1)
after_line=$(grep -n '^### After Body Prod$' "$BODYTARGET" | cut -d: -f1)
notes_line=$(grep -n '^## Notes$' "$BODYTARGET" | cut -d: -f1)
if [ -n "$esc_line" ] && [ -n "$tail_line" ] && [ -n "$after_line" ] && [ -n "$notes_line" ] \
   && [ "$esc_line" -lt "$tail_line" ] && [ "$tail_line" -lt "$after_line" ] && [ "$after_line" -lt "$notes_line" ]; then a=ok; else a=no; fi
assert "section order intact: escaped line + body tail stay in the FIRST product; next product lands after them, before ## Notes" ok "$a"

# Full-section LOOKUP: an operator hand-adds a product at the tail of
# ## Products (a normal Obsidian edit this append-only tool must tolerate —
# same premise as Test 15's hand-built fixture). Under the bug the raw
# injected heading had already truncated the block, so this heading sat
# OUTSIDE ## Products and the feed-mode authority check refused it (exit 2,
# 'product not found'); post-fix the escaped line does not terminate the
# section and the link resolves.
awk '/^## Notes$/ && !ins { print ""; print "### Hand Added Prod"; print ""; print "hand notes"; print ""; ins=1 } { print }' "$BODYTARGET" > "$BODYTARGET.hand" && mv "$BODYTARGET.hand" "$BODYTARGET"
out="$(node "$SCRIPT" --vault "$BODYVAULT" --mode feed --msg-id 6102 --sender alice --date 2026-09-11 --vessel x --product "Hand Added Prod" 2>&1)"
rc=$?
assert "feed lookup for a product heading BELOW the escaped line exits 0" 0 "$rc"
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" | sed 's/^/         /'; fi
grep -q '^| 2026-09-11 .*\[\[#Hand Added Prod\]\]' "$BODYTARGET" && a=ok || a=no
assert "wikilink anchor resolves to the below-the-escape product" ok "$a"

# Determinism of the escape at CLI level: the same '##'-carrying body dry-run
# produces byte-identical output twice. (f(f(x)) idempotency is Test 33.)
out1="$(node "$SCRIPT" --vault "$BODYVAULT" --mode product --msg-id 6199 --sender alice --product "Dry Run Prod" --body-file "$tmpdir/bogus-body.txt" --dry-run 2>/dev/null)"
out2="$(node "$SCRIPT" --vault "$BODYVAULT" --mode product --msg-id 6199 --sender alice --product "Dry Run Prod" --body-file "$tmpdir/bogus-body.txt" --dry-run 2>/dev/null)"
assert "dry-run of the same '##'-carrying body is byte-stable across runs" "$out1" "$out2"

# -- Test 33: neutralizeHeadings predicate unit cases + idempotency ---------
# Same import-the-shipped-tool pattern as Test 22: these pin the PREDICATE
# (what counts as a heading-shaped line start, what is left untouched), while
# Test 32 pins the WIRING (the pipeline actually calls it). Both are needed —
# a green unit table with an unwired call site is the exact false-green
# shape the falsification step guards against.
echo "Test 33: neutralizeHeadings unit cases + idempotency"
cat > "$tmpdir/heading-cases.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
const { neutralizeHeadings } = await import(pathToFileURL(process.argv[2]).href);
const cases = [
  // the HIMMEL-1798 terminator shape (what findProductsBlock keys on)
  ["## Usage notes", "&#35;# Usage notes"],
  // phantom product-heading door (productHeadingExists keys on ^###)
  ["### Evil product", "&#35;## Evil product"],
  ["# H1", "&#35; H1"],                        // Obsidian outline, H1 flavor
  ["###### H6", "&#35;##### H6"],              // deepest real heading level
  ["##", "&#35;#"],                            // bare empty heading
  ["# ", "&#35; "],                            // hash + space, nothing else
  ["#hashtag", "#hashtag"],                    // no space after the run: not a heading anywhere
  ["#5 bolt", "#5 bolt"],                      // ditto — left legible
  ["####### seven", "####### seven"],          // 7+ hashes: not ATX (CommonMark caps at 6), not ^##\s either
  ["text ## mid-line", "text ## mid-line"],    // mid-line ## is inert
  ["  ## indented", "  ## indented"],          // leading spaces: the tool's ^-anchored parsers never see it as a terminator
  ["intro\n## Usage notes\noutro", "intro\n&#35;# Usage notes\noutro"], // per-line, rest byte-preserved
  ["a\r\n## CRLF\r\nb", "a\r\n&#35;# CRLF\r\nb"], // caller CRLF: only the line-start hash touched
];
let bad = 0;
for (const [input, want] of cases) {
  const got = neutralizeHeadings(input);
  if (got !== want) { console.log(`BAD ${JSON.stringify(input)} -> ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); bad++; }
  const twice = neutralizeHeadings(got);
  if (twice !== got) { console.log(`BAD not idempotent: ${JSON.stringify(input)} -> ${JSON.stringify(got)} -> ${JSON.stringify(twice)}`); bad++; }
}
process.exit(bad === 0 ? 0 : 1);
EOF
out="$(node "$tmpdir/heading-cases.mjs" "$SCRIPT" 2>&1)"
rc=$?
assert "all neutralizeHeadings unit cases hold + f(f(x)) === f(x)" 0 "$rc"
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" | sed 's/^/         /'; fi

# -- Summary --------------------------------------------------------------
echo ""
echo "grow-feed-log tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
