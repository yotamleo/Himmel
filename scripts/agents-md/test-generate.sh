#!/usr/bin/env bash
# Tests for generate.mjs — the CLAUDE.md -> AGENTS.md generator (HIMMEL-471).
# Bash 3.2-safe. Uses temp fixtures + env path overrides; never touches the
# repo's real CLAUDE.md / AGENTS.md.
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

# ---- summary --------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
