#!/usr/bin/env bash
# scripts/cr/test-critic-panel-triviality.sh -- HIMMEL-737 triviality-gate wiring.
# Proves the panel drops the PAID tier when the diff classifies 'trivial', keeps
# both tiers on a nontrivial diff, honors CR_TRIVIALITY_OVERRIDE=full, and does
# NOT apply the gate in --check mode. The member seam is CRITIC_FIRST_PASS
# (stubbed, records every invoked model). Bash 3.2 safe.
set -uo pipefail

# Hermetic: the panel reads CR_PROFILE (HIMMEL-558). Clear ambient values; each
# case sets CR_PROFILE explicitly.
unset CR_PROFILE CRITIC_PANEL_TIERS CR_TRIVIALITY_OVERRIDE 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$HERE/critic-panel.sh"
tmp="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
fails=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

check_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "ok - $1"
    else
        echo "FAIL - $1: expected to contain [$3]"
        fails=$((fails + 1))
    fi
}

# --- Registry: one free row + one paid row, both answerable by the stub. ---
FREE_MODEL="vendor/free-model"
PAID_MODEL="vendor/paid-model"
JSON="$tmp/critics-tg.json"
printf '{"panel":[
  {"slug":"freecrit","model":"%s","provider":"test","tier":"free"},
  {"slug":"paidcrit","model":"%s","provider":"test","tier":"paid"}
]}' "$FREE_MODEL" "$PAID_MODEL" > "$JSON"

# --- CFP stub: record each invoked model to TG_CAPTURE, return a valid review. ---
STUB="$tmp/stub-cfp.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
model=""
slug=""
while [ $# -gt 0 ]; do
    case "$1" in
        --model) model="$2"; shift 2 ;;
        --slug)  slug="$2";  shift 2 ;;
        --perspective-file) shift 2 ;;
        *) shift ;;
    esac
done
cat >/dev/null
[ -n "${TG_CAPTURE:-}" ] && printf '%s\n' "$model" >> "$TG_CAPTURE"
printf '# %s First-Pass Review\n\n' "$slug"
printf '## Critical Issues (0 found)\n\n'
printf '## Important Issues (0 found)\n\n'
printf '## Suggestions (0 found)\n'
exit 0
EOS
chmod +x "$STUB"

# --- Fixtures: trivial (1-file, 1 non-safety code line) vs nontrivial (3 lines). ---
TRIVIAL_DIFF='diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -1,1 +1,2 @@
 existing
+one line'

NONTRIVIAL_DIFF='diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -1,1 +1,4 @@
 existing
+a
+b
+c'

run_case() {
    # $1=diff $2=out $3=err $4=cap ; caller sets CR_PROFILE / CR_TRIVIALITY_OVERRIDE
    _d="$1"; _o="$2"; _e="$3"; _c="$4"
    : > "$_c"
    printf '%s' "$_d" | CRITICS_JSON="$JSON" CRITIC_FIRST_PASS="$STUB" \
        TG_CAPTURE="$_c" bash "$PANEL" >"$_o" 2>"$_e"
}

# ===========================================================================
# Case 1: trivial diff + CR_PROFILE=free,paid -> paid dropped, free runs.
# ===========================================================================
CR_PROFILE="free,paid" run_case "$TRIVIAL_DIFF" "$tmp/out1" "$tmp/err1" "$tmp/cap1"
out1="$(cat "$tmp/out1")"; err1="$(cat "$tmp/err1")"
check "1: free member invoked" "$(grep -cF -- "$FREE_MODEL" "$tmp/cap1")" "1"
check "1: paid member NOT invoked" "$(grep -cF -- "$PAID_MODEL" "$tmp/cap1")" "0"
check_contains "1: skip line names verdict + override hint" "$err1" \
    "triviality-gate verdict=trivial (one-liner) - paid tier skipped (CR_TRIVIALITY_OVERRIDE=full to force)"
check_contains "1: only the free member responded (1/1)" "$out1" "(1/1 critics responded)"

# ===========================================================================
# Case 2: nontrivial diff + CR_PROFILE=free,paid -> BOTH invoked (no skip).
# ===========================================================================
CR_PROFILE="free,paid" run_case "$NONTRIVIAL_DIFF" "$tmp/out2" "$tmp/err2" "$tmp/cap2"
out2="$(cat "$tmp/out2")"; err2="$(cat "$tmp/err2")"
check "2: free member invoked" "$(grep -cF -- "$FREE_MODEL" "$tmp/cap2")" "1"
check "2: paid member invoked" "$(grep -cF -- "$PAID_MODEL" "$tmp/cap2")" "1"
check "2: NO triviality skip line" "$(printf '%s\n' "$err2" | grep -cF 'triviality-gate verdict=trivial')" "0"
check_contains "2: both members responded (2/2)" "$out2" "(2/2 critics responded)"

# ===========================================================================
# Case 3: CR_TRIVIALITY_OVERRIDE=full + trivial-looking diff -> BOTH invoked.
# The gate itself maps full -> nontrivial; the panel must not skip paid.
# ===========================================================================
CR_PROFILE="free,paid" CR_TRIVIALITY_OVERRIDE=full \
    run_case "$TRIVIAL_DIFF" "$tmp/out3" "$tmp/err3" "$tmp/cap3"
out3="$(cat "$tmp/out3")"; err3="$(cat "$tmp/err3")"
check "3: free member invoked" "$(grep -cF -- "$FREE_MODEL" "$tmp/cap3")" "1"
check "3: paid member invoked (override forces full panel)" "$(grep -cF -- "$PAID_MODEL" "$tmp/cap3")" "1"
check "3: NO triviality skip line under override=full" "$(printf '%s\n' "$err3" | grep -cF 'triviality-gate verdict=trivial')" "0"
check_contains "3: both members responded (2/2)" "$out3" "(2/2 critics responded)"

# ===========================================================================
# Case 4: --check mode ignores the gate. --check reads no diff and health-probes
# rows; --all-tiers must still probe the paid row (the gate never runs there).
# ===========================================================================
CHK_INVOKE="$tmp/chk-invoke.sh"
cat > "$CHK_INVOKE" <<'EOS'
#!/usr/bin/env bash
m=""
while [ $# -gt 0 ]; do case "$1" in --model) m="$2"; shift 2;; --prompt-file) shift 2;; *) shift;; esac; done
printf 'ok\n'; exit 0
EOS
chmod +x "$CHK_INVOKE"

if command -v timeout > /dev/null 2>&1; then
    chk_out="$(CR_PROFILE="free,paid" CRITICS_JSON="$JSON" CRITIC_INVOKE="$CHK_INVOKE" \
        timeout 15 bash "$PANEL" --check --all-tiers </dev/null 2>&1)"; chk_rc=$?
    check "4: --check terminates (not 124 timeout)" "$([ "$chk_rc" != "124" ] && echo ok)" "ok"
    check_contains "4: --check --all-tiers probes the paid row (gate not applied)" "$chk_out" "row paidcrit: ok"
    check "4: --check emits NO triviality skip line" "$(printf '%s\n' "$chk_out" | grep -cF 'triviality-gate')" "0"
else
    echo "ok - 4: SKIP (no timeout binary)"
    echo "ok - 4: SKIP (no timeout binary)"
    echo "ok - 4: SKIP (no timeout binary)"
fi

# ===========================================================================
# Case 5 (CR round): paid is the ONLY requested tier and the diff is trivial ->
# the panel must NOT silently substitute the registry-default free tier; it
# exits 1 (the caller's documented claude-only fail-open) with a loud stderr
# line, and NO member is invoked.
# ===========================================================================
PAID_ONLY_JSON="$tmp/critics-paidonly.json"
printf '{"panel":[{"slug":"paidcrit","model":"%s","provider":"test","tier":"paid"}]}' \
    "$PAID_MODEL" > "$PAID_ONLY_JSON"
: > "$tmp/cap5"
printf '%s' "$TRIVIAL_DIFF" | CR_PROFILE=paid CRITICS_JSON="$PAID_ONLY_JSON" \
    CRITIC_FIRST_PASS="$STUB" TG_CAPTURE="$tmp/cap5" bash "$PANEL" >"$tmp/out5" 2>"$tmp/err5"
rc5=$?
err5="$(cat "$tmp/err5")"
check "5: paid-only + trivial -> exit 1" "$rc5" "1"
check "5: NO member invoked" "$(grep -c . "$tmp/cap5")" "0"
check_contains "5: loud only-tier-stripped stderr line" "$err5" "stripped the ONLY requested tier"
check "5: NO paid-tier-skipped line (the strip is total, not partial)" \
    "$(printf '%s\n' "$err5" | grep -cF 'paid tier skipped')" "0"

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
