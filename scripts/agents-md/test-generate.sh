#!/usr/bin/env bash
# Tests for generate.mjs — the CLAUDE.md -> AGENTS.md generator (HIMMEL-471).
# Bash 3.2-safe. Uses temp fixtures + env path overrides; never WRITES the
# repo's real CLAUDE.md / AGENTS.md. One deliberate exception to fixture
# hermeticity: section 9b READS the real CLAUDE.md as a rewrap-drift guard
# (HIMMEL-559), so an unrelated CLAUDE.md edit can legitimately fail it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate.mjs"
PREAMBLE="$SCRIPT_DIR/preamble.md"
DEBRAND="$SCRIPT_DIR/debrand.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
# Reliable CR detection (this platform's grep cannot match $'\r'): a file has CR
# iff stripping \r changes its byte count.
has_cr() { [ "$(wc -c < "$1")" -ne "$(tr -d '\r' < "$1" | wc -c)" ]; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run <expected-rc> <description> -- <gen args...>  (env: SRC/TGT honored)
run() {
  local want="$1"; shift
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  AGENTS_MD_SOURCE="$SRC" AGENTS_MD_TARGET="$TGT" \
  AGENTS_MD_PREAMBLE="$PREAMBLE" AGENTS_MD_DEBRAND="$DEBRAND" \
    node "$GEN" "$@" >"$TMP/out" 2>"$TMP/err"
  local rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc (rc=$rc)"; else bad "$desc (rc=$rc, want $want); stderr: $(cat "$TMP/err")"; fi
  return 0
}

# ---- fixtures -------------------------------------------------------------
SRC="$TMP/CLAUDE.md"; TGT="$TMP/AGENTS.md"
cat > "$SRC" <<'EOF'
# Fixture Rules

Always prefer the Skill tool when you can. Use judgement on trivial tasks.
EOF

# ---- 1. write: ladder before body, LF-only, debrand applied --------------
run 0 "write succeeds on small fixture" -- --write
out="$(cat "$TGT")"
case "$out" in
  "# AGENTS.md — himmel rules"*) ok "output starts with preamble title";;
  *) bad "output starts with preamble title";;
esac
prec_pos=$(grep -n "## Precedence — read this first" "$TGT" | head -1 | cut -d: -f1)
body_pos=$(grep -n "^# Fixture Rules" "$TGT" | head -1 | cut -d: -f1)
if [ -n "$prec_pos" ] && [ -n "$body_pos" ] && [ "$prec_pos" -lt "$body_pos" ]; then
  ok "precedence ladder appears before CLAUDE.md body"
else bad "precedence ladder appears before CLAUDE.md body (prec=$prec_pos body=$body_pos)"; fi
if has_cr "$TGT"; then bad "output is LF-only (found CR)"; else ok "output is LF-only"; fi
if grep -q "your skill-invocation mechanism" "$TGT" && ! grep -q "the Skill tool" "$TGT"; then
  ok "debrand substitution applied"
else bad "debrand substitution applied"; fi

# ---- 2. check: fresh = 0 --------------------------------------------------
run 0 "check exits 0 when AGENTS.md is fresh" -- --check

# ---- 3. check: stale = 1 (source edited, not regenerated) ----------------
printf '\nAn extra rule line.\n' >> "$SRC"
run 1 "check exits 1 when source edited without regenerating" -- --check
# regenerate to restore fresh state for later tests
run 0 "re-write after edit" -- --write
run 0 "check fresh again after re-write" -- --check

# ---- 4. CRLF-normalized compare (no false positive) ----------------------
# Rewrite the target with genuine CRLF endings; --check must still pass.
# awk reliably interprets the \r\n escapes (sed's \r handling is platform-variable).
awk 'BEGIN{ORS="\r\n"}{print}' "$TGT" > "$TGT.crlf" && mv "$TGT.crlf" "$TGT"
if has_cr "$TGT"; then ok "target now has CRLF endings (setup)"; else bad "CRLF setup failed"; fi
run 0 "check exits 0 despite CRLF target (normalized compare)" -- --check
run 0 "re-write restores LF target" -- --write

# ---- 5. @include rejection = 2 -------------------------------------------
SAVED_SRC="$SRC"; SRC="$TMP/with-include.md"; TGT="$TMP/AGENTS-inc.md"
printf '# Has include\n@RTK.md\nmore\n' > "$SRC"
run 2 "write rejects @include line (cannot-evaluate)" -- --write
run 2 "check rejects @include line (cannot-evaluate)" -- --check
SRC="$SAVED_SRC"; TGT="$TMP/AGENTS.md"

# ---- 6. >32 KiB hard-fail = 2 --------------------------------------------
BIG="$TMP/big.md"; TGTBIG="$TMP/AGENTS-big.md"
{ printf '# Big Rules\n'; head -c 36000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$BIG"
SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$BIG"; TGT="$TGTBIG"
run 2 "write hard-fails when assembled output > 32 KiB" -- --write
SRC="$SAVED_SRC"; TGT="$SAVED_TGT"

# ---- 7. 24-32 KiB warn band (exit 0 + stderr warning) --------------------
WARN="$TMP/warn.md"; TGTWARN="$TMP/AGENTS-warn.md"
{ printf '# Warn Rules\n'; head -c 28000 /dev/zero | tr '\0' 'y'; printf '\n'; } > "$WARN"
SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$WARN"; TGT="$TGTWARN"
AGENTS_MD_SOURCE="$SRC" AGENTS_MD_TARGET="$TGT" AGENTS_MD_PREAMBLE="$PREAMBLE" \
  AGENTS_MD_DEBRAND="$DEBRAND" node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ]; then ok "warn-band write exits 0"; else bad "warn-band write exits 0 (rc=$rc)"; fi
if grep -qi "warn" "$TMP/err"; then ok "warn-band emits stderr warning"; else bad "warn-band emits stderr warning"; fi
SRC="$SAVED_SRC"; TGT="$SAVED_TGT"

# ---- 8. idempotency -------------------------------------------------------
run 0 "idempotency write #1" -- --write
cp "$TGT" "$TMP/first"
run 0 "idempotency write #2" -- --write
if cmp -s "$TMP/first" "$TGT"; then ok "two writes are byte-identical"; else bad "two writes are byte-identical"; fi

# ---- 9. Fable debrand (HIMMEL-559) ----------------------------------------
# a) fixture: identity / quota / effort-calibration claims are neutralized.
# The fixture reproduces the two wrap points that matter — the embedded
# newlines in the 'Fable main loop' and 'Fable-5' entries are part of the
# contract (the rest of the fixture is condensed, not a verbatim copy).
FAB="$TMP/fable.md"; TGTFAB="$TMP/AGENTS-fable.md"
cat > "$FAB" <<'EOF'
# Fixture Rules

analysis); the **Fable main thread** orchestrates and owns final
judgment + synthesis. **Every dispatch names an explicit model** — an
unnamed dispatch inherits the Fable
main loop and burns the time-limited Fable quota on work a cheaper
tier handles.
Raise *effort* before raising model tier — Fable-5 `low` ≈ prior-gen
`xhigh`, and the same shift applies down-tier.
| Fable 5 | judgment, taste — hardest calls; escalation target |
compare per task vs Fable-low
Fable stays CONSERVED (limited release)
EOF
SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$FAB"; TGT="$TGTFAB"
run 0 "fable fixture write succeeds" -- --write
if grep -q 'the \*\*main thread\*\* orchestrates' "$TGT" && ! grep -q 'Fable main thread' "$TGT"; then
  ok "identity claim neutralized (main thread)"
else bad "identity claim neutralized (main thread)"; fi
if grep -q 'time-limited top-tier quota' "$TGT" && ! grep -q 'Fable quota' "$TGT"; then
  ok "quota claim neutralized"
else bad "quota claim neutralized"; fi
if grep -q 'inherits the main$' "$TGT"; then
  ok "wrap-spanning 'Fable main loop' entry matched across the newline"
else bad "wrap-spanning 'Fable main loop' entry matched across the newline"; fi
if grep -q 'on Claude, Fable-5' "$TGT"; then
  ok "effort calibration attributed to Claude"
else bad "effort calibration attributed to Claude"; fi
if grep -qF '| top model | judgment, taste — hardest calls; escalation target |' "$TGT"; then
  ok "top-model lane row neutralized"
else bad "top-model lane row neutralized"; fi
if grep -qF 'compare per task vs top-model-low' "$TGT"; then
  ok "top-model-low comparison neutralized"
else bad "top-model-low comparison neutralized"; fi
if grep -qF 'The top model stays CONSERVED (limited release)' "$TGT"; then
  ok "top-model conservation sentence neutralized"
else bad "top-model conservation sentence neutralized"; fi
SRC="$SAVED_SRC"; TGT="$SAVED_TGT"

# b) real-CLAUDE.md leak check: after generation, no identity-claiming Fable
# text may survive outside HTML comments (FABLE-WINDOW provenance comments are
# documentary and allowed). This is the guard that catches a CLAUDE.md rewrap
# silently breaking the newline-embedded debrand entries. Reads the repo's
# real CLAUDE.md; writes only to a temp target.
strip_html_comments() {   # <in> <out>
  # Two-pass on purpose: a bare sed RANGE ('/<!--/,/-->/d') treats a
  # SINGLE-LINE '<!-- ... -->' as an unterminated range START (addr2 is only
  # tested from the NEXT line) and deletes everything to the next '-->' or
  # EOF — the preamble's single-line comments would swallow the whole body
  # and make the leak check vacuously pass. So: drop inline comment spans
  # first, then range-drop the remaining true multi-line blocks.
  sed 's/<!--.*-->//g' "$1" | sed '/<!--/,/-->/d' > "$2"
}
REAL_SRC="$SCRIPT_DIR/../../CLAUDE.md"; TGTREAL="$TMP/AGENTS-real.md"
if [ -f "$REAL_SRC" ]; then
  SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$REAL_SRC"; TGT="$TGTREAL"
  run 0 "real-CLAUDE.md write succeeds" -- --write
  stripped="$TMP/real-stripped.md"
  strip_html_comments "$TGTREAL" "$stripped"
  # Guard the guard: the strip must not have eaten the body (a regression back
  # to the vacuous strip would silently green-light every leak).
  if grep -q 'Subagent policy' "$stripped"; then
    ok "comment-strip preserves the body (leak check is non-vacuous)"
  else bad "comment-strip preserves the body (leak check is non-vacuous)"; fi
  # A leak = ANY 'Fable' text outside comments except the explicitly attributed
  # calibration phrase. Strip the allowed phrase FIRST, then any residual
  # 'Fable' is a leak — line-position-independent, so it catches wrap-split
  # fragments (e.g. '**Fable' / 'main thread**' after a rewrap breaks an
  # entry) and future unattributed Fable-5 mentions alike.
  leaks="$(sed 's/on Claude, Fable-5//g' "$stripped" | grep -n 'Fable' || true)"
  if [ -z "$leaks" ]; then
    ok "no Fable text outside comments except attributed calibration (real CLAUDE.md)"
  else bad "no Fable text outside comments except attributed calibration (real CLAUDE.md): $leaks"; fi
  SRC="$SAVED_SRC"; TGT="$SAVED_TGT"
fi

# c) RED PATH: prove the leak check actually fires when a rewrap breaks an
# entry. Re-wrap 'the **Fable main thread**' across a line boundary — entry 4
# (no embedded newline) stops matching and the leaked fragments span two lines,
# which the old line-based patterns ('the Fable|Fable main|Fable quota') could
# NOT see. The strip-then-residual check must still flag it.
BROKEN="$TMP/fable-rewrap.md"; TGTBROKEN="$TMP/AGENTS-broken.md"
cat > "$BROKEN" <<'EOF'
# Fixture Rules

analysis); the **Fable
main thread** orchestrates and owns final judgment.
EOF
SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$BROKEN"; TGT="$TGTBROKEN"
run 0 "rewrap red-path fixture write succeeds" -- --write
broken_stripped="$TMP/broken-stripped.md"
strip_html_comments "$TGTBROKEN" "$broken_stripped"
if sed 's/on Claude, Fable-5//g' "$broken_stripped" | grep -q 'Fable'; then
  ok "leak check fires on a rewrap-broken entry (red path)"
else bad "leak check fires on a rewrap-broken entry (red path)"; fi
SRC="$SAVED_SRC"; TGT="$SAVED_TGT"

# ---- summary --------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
