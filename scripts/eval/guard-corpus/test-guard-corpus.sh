#!/usr/bin/env bash
# scripts/eval/guard-corpus/test-guard-corpus.sh - suite for gen + diff
# (HIMMEL-4168). Proves:
#   1. gen is deterministic (same seed + seeds file => same bytes)
#   2. diff flags a planted base-deny/head-allow row, using two tiny STUB hooks
#      (never a real hook)
#   3. diff flags a planted slow stub as a TIMEOUT RISK
#   4. neither tool ever execs a generated command (a sentinel-file assertion)
#   5. gen --seeds-file applies transforms to a supplied (benign) seed
#
# The stub hooks here deny on a harmless sentinel token so no attack string is
# authored. Run via:
#   bash scripts/quiet-run.sh suite -- bash scripts/eval/guard-corpus/test-guard-corpus.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="$HERE/gen"
DIFF="$HERE/diff"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/guard-corpus-test.XXXXXX")" || {
  echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in output";; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: unexpected '$3' in output";; *) pass "$1";; esac; }

# --- 1. determinism -----------------------------------------------------------
python3 "$GEN" --seed 4168 -o "$TMP/a.jsonl"
python3 "$GEN" --seed 4168 -o "$TMP/b.jsonl"
if cmp -s "$TMP/a.jsonl" "$TMP/b.jsonl"; then pass "determinism: same seed, same bytes"
else fail "determinism: same seed produced different bytes"; fi
python3 "$GEN" --seed 9999 -o "$TMP/c.jsonl"
if cmp -s "$TMP/a.jsonl" "$TMP/c.jsonl"; then
  fail "determinism-control: different seed MUST differ (pad filler)"
else pass "determinism-control: different seed differs"; fi

# --- stub hooks: deny (exit 2) iff the payload command contains SENTINEL ------
# These stand in for a real guard. SENTINEL is a harmless token, not an attack.
mkdir -p "$TMP/scripts/hooks"
cat > "$TMP/base-hook.sh" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
case "$input" in *SENTINEL_DENY*) exit 2 ;; esac
exit 0
STUB
# head hook: the REGRESSION - it no longer denies SENTINEL_DENY (allows it).
cat > "$TMP/head-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
# slow hook: sleeps past the warn threshold.
cat > "$TMP/slow-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
sleep 2
exit 0
STUB
chmod +x "$TMP/base-hook.sh" "$TMP/head-hook.sh" "$TMP/slow-hook.sh"

# A tiny corpus carrying one deny-expected sentinel row + benign rows.
cat > "$TMP/seeds.txt" <<'SEEDS'
planted	deny	echo SENTINEL_DENY
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/seeds.txt" -o "$TMP/corpus.jsonl"

# --- 2. planted base-deny/head-allow is flagged -------------------------------
OUT=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/head-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC=$?
has "regression: flagged" "$OUT" "base-deny/head-allow (REGRESSION): "
hasnt "regression: not zero" "$OUT" "(REGRESSION): 0"
if [ "$RC" = "1" ]; then pass "regression: exit code 1"
else fail "regression: expected exit 1, got $RC"; fi

# control: base vs base (identical) => zero regressions, exit 0
OUT2=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC2=$?
has "regression-control: zero" "$OUT2" "(REGRESSION): 0"
if [ "$RC2" = "0" ]; then pass "regression-control: exit 0"
else fail "regression-control: expected exit 0, got $RC2"; fi

# --- 3. planted slow stub flagged TIMEOUT RISK --------------------------------
OUT3=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/slow-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 --timeout-warn 1 2>&1)
hasnt "timeout: flagged" "$OUT3" "TIMEOUT RISK (>= 1.0s): 0"
has "timeout: line present" "$OUT3" "TIMEOUT-RISK idx="

# --- 3b. two broken hooks (rc=1 everywhere) => inconclusive, exit 3 ----------
# codex-1: a run where no base exit code is 2 and hooks error must NOT read as
# a clean verdict (exit 0); it is inconclusive (exit 3).
cat > "$TMP/broken-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 1
STUB
chmod +x "$TMP/broken-hook.sh"
python3 "$DIFF" --base "$TMP/broken-hook.sh" --head "$TMP/broken-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC_BRK=$?
if [ "$RC_BRK" = "3" ]; then pass "inconclusive: two broken hooks exit 3 (not clean)"
else fail "inconclusive: expected exit 3, got $RC_BRK"; fi

# --- 3c. base-deny + head-ERROR is inconclusive, never a regression ----------
# codex-1: a regression is base-deny paired with a CLEAN head-allow (rc 0). A
# head that errored (rc 1) did not allow the command, so base-deny/head-error
# must read as inconclusive (exit 3), not a confirmed regression (exit 1).
OUT3C=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/broken-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC3C=$?
has "base-deny/head-error: no regression" "$OUT3C" "(REGRESSION): 0"
if [ "$RC3C" = "3" ]; then pass "base-deny/head-error: inconclusive exit 3"
else fail "base-deny/head-error: expected exit 3, got $RC3C"; fi

# --- 2b. an empty corpus is refused, never certified clean -------------------
# codex-2: zero rows exercise no hook; a clean exit 0 would be a false
# "reviewed clean". diff must refuse it (exit 2).
: > "$TMP/empty-corpus.jsonl"
python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/empty-corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC_EMPTY=$?
if [ "$RC_EMPTY" = "2" ]; then pass "empty-corpus: refused (exit 2)"
else fail "empty-corpus: expected exit 2, got $RC_EMPTY"; fi

# --- 1b. inherited GIT_DIR must not redirect the scratch git setup -----------
# codex-1: GIT_DIR/GIT_WORK_TREE/... override `git -C`, so a stray one in the
# environment could send scratch init/add/commit into a real repo. diff strips
# them; prove a sentinel GIT_DIR is never created by the scratch setup.
SENTGD="$TMP/sentinel-gitdir"
GIT_DIR="$SENTGD" python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 1 >/dev/null 2>&1
if [ ! -e "$SENTGD" ]; then pass "git-env: inherited GIT_DIR did not redirect scratch git"
else fail "git-env: scratch git honored inherited GIT_DIR ($SENTGD created)"; fi

# --- 2c. each invocation gets a fresh HOME/primary (no cross-run contamination)
# codex-2: a hook that writes state must not leak into another row or the other
# side of the comparison. This stub denies (exit 2) iff a PRIOR run in the same
# HOME planted a marker; with per-invocation fresh HOME it never sees one, so
# every run allows and nothing is spuriously denied. Benign-only corpus (no
# expect=deny rows) so the deny positive-control check does not fire.
cat > "$TMP/contaminate-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
if [ -e "$HOME/.seen" ]; then exit 2; fi
: > "$HOME/.seen"
exit 0
STUB
chmod +x "$TMP/contaminate-hook.sh"
python3 "$GEN" --seed 1 -o "$TMP/benign.jsonl"
OUT2C=$(python3 "$DIFF" --base "$TMP/contaminate-hook.sh" --head "$TMP/contaminate-hook.sh" \
        --corpus "$TMP/benign.jsonl" --jobs 1 2>&1); RC2C=$?
has "isolation: no cross-run contamination" "$OUT2C" "newly-denied: 0"
has "isolation: no stray denials" "$OUT2C" "(REGRESSION): 0"
if [ "$RC2C" = "0" ]; then pass "isolation: fresh HOME per invocation (exit 0)"
else fail "isolation: shared HOME contaminated runs, exit $RC2C"; fi

# --- 4. no code path execs a generated command (sentinel-file assertion) ------
# A seed that WOULD create a sentinel file if ever executed. diff must NOT run
# it; the file must not exist afterward. The hook only reads stdin.
SENT="$TMP/must-not-exist"
# expect=allow so the deny positive-control check (section 6) is not triggered
# here; this section only proves the command is never EXECUTED.
cat > "$TMP/exec-seeds.txt" <<SEEDS
planted	allow	touch $SENT
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/exec-seeds.txt" -o "$TMP/exec-corpus.jsonl"
python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/exec-corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC_NX=$?
# the sentinel-absent check is vacuous if diff crashed in setup before
# processing the corpus, so also assert the run actually completed clean
# (base vs base identical => exit 0).
if [ "$RC_NX" = "0" ]; then pass "no-exec: diff ran to completion (exit 0)"
else fail "no-exec: diff did not complete clean, exit $RC_NX (sentinel check would be vacuous)"; fi
if [ -e "$SENT" ]; then fail "no-exec: diff EXECUTED a generated command (sentinel created)"
else pass "no-exec: no generated command was executed"; fi

# --- 5. gen --seeds-file applies transforms to a supplied seed ----------------
cat > "$TMP/one-seed.txt" <<'SEEDS'
supplied	allow	touch PLACEHOLDER
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/one-seed.txt" -o "$TMP/sf.jsonl"
N=$(grep -c '"family": "supplied"' "$TMP/sf.jsonl")
# one seed x (len(TRANSFORMS)+pad) rows; just assert more than one variant.
if [ "$N" -ge 2 ]; then pass "seeds-file: transforms applied to supplied seed ($N rows)"
else fail "seeds-file: expected >=2 supplied rows, got $N"; fi
has "seeds-file: placeholder preserved" "$(cat "$TMP/sf.jsonl")" "PLACEHOLDER"

# --- 6. deny-expected rows the base never denies => inconclusive (exit 3) ----
# codex-3: if a judge supplies deny seeds but the base denies NONE, the deny
# positive control never fired, so "no regression" proves nothing. A clean
# exit 0 would be a false "reviewed clean"; diff must report it (exit 3).
cat > "$TMP/miss-seeds.txt" <<'SEEDS'
planted-miss	deny	echo harmless
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/miss-seeds.txt" -o "$TMP/miss-corpus.jsonl"
OUT6=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/miss-corpus.jsonl" --jobs 4 2>&1); RC6=$?
has "deny-control: warning present" "$OUT6" "NO deny-side coverage"
if [ "$RC6" = "3" ]; then pass "deny-control: no base deny => inconclusive exit 3"
else fail "deny-control: expected exit 3, got $RC6"; fi

echo "----"
echo "guard-corpus: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
