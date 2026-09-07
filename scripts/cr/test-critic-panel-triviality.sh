#!/usr/bin/env bash
# scripts/cr/test-critic-panel-triviality.sh -- HIMMEL-737 triviality-gate wiring.
# Proves the panel drops the PAID tier when the diff classifies 'trivial', keeps
# both tiers on a nontrivial diff, honors CR_TRIVIALITY_OVERRIDE=full, and does
# NOT apply the gate in --check mode. The member seam is CRITIC_FIRST_PASS
# (stubbed, records every invoked model). Bash 3.2 safe.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# Hermetic: the panel reads CR_PROFILE (HIMMEL-558). Clear ambient values; each
# case sets CR_PROFILE explicitly.
# HIMMEL-1950: CR_REQUIRE_CROSS_MODEL now steers the trivial-diff path, and the
# panel falls back to .env when it is UNSET — so "unset" is not a hermetic
# value here. Every case that depends on it states it explicitly; this scrub
# only stops an ambient export from deciding before they do.
unset CR_PROFILE CRITIC_PANEL_TIERS CR_TRIVIALITY_OVERRIDE CR_REQUIRE_CROSS_MODEL \
    CRITIC_LEDGER_APPEND CR_LEDGER CRITIC_FIRST_PASS CRITICS_JSON \
    CRITIC_PARALLEL CRITIC_TIMEOUT_SECS CRITIC_PANEL_TOTAL_TIMEOUT_SECS \
    CRITIC_PANEL_STARTED_AT 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$HERE/critic-panel.sh"
tmp="$(mktemp -d -t critic-panel-triviality-test.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
fails=0
_skips=0
LEDGER_NOOP="$tmp/ledger-noop.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$LEDGER_NOOP"
chmod +x "$LEDGER_NOOP"
export CRITIC_LEDGER_APPEND="$LEDGER_NOOP"

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

check_contains() {
    if grepq "$2" -F -- "$3"; then
        echo "ok - $1"
    else
        echo "FAIL - $1: expected to contain [$3]"
        fails=$((fails + 1))
    fi
}

# skip <label> -- a case that could not run in this environment. Must NEVER
# be reported with the "ok - " pass token: a skip credited as a pass hides
# the fact that nothing was asserted (HIMMEL-2258 audit; HIMMEL-2226 fix).
skip() {
    echo "SKIP - $1"
    _skips=$((_skips + 1))
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
    # HIMMEL-2226 (HIMMEL-2258 audit): was "ok - " (a silently-credited pass).
    skip "4: no timeout binary"
    skip "4: no timeout binary"
    skip "4: no timeout binary"
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
# CR_REQUIRE_CROSS_MODEL=0 is load-bearing here (HIMMEL-1950): this is the
# adopter WITHOUT the cross-model floor, where dropping the last tier is
# right because the claude-only floor clears the marker on its own.
printf '%s' "$TRIVIAL_DIFF" | CR_PROFILE=paid CR_REQUIRE_CROSS_MODEL=0 CRITICS_JSON="$PAID_ONLY_JSON" \
    CRITIC_FIRST_PASS="$STUB" TG_CAPTURE="$tmp/cap5" bash "$PANEL" >"$tmp/out5" 2>"$tmp/err5"
rc5=$?
err5="$(cat "$tmp/err5")"
check "5: paid-only + trivial -> exit 1" "$rc5" "1"
check "5: NO member invoked" "$(grep -c . "$tmp/cap5")" "0"
check_contains "5: loud only-tier-stripped stderr line" "$err5" "stripped the ONLY requested tier"
check "5: NO paid-tier-skipped line (the strip is total, not partial)" \
    "$(printf '%s\n' "$err5" | grep -cF 'paid tier skipped')" "0"

# ===========================================================================
# HIMMEL-1950: paid is the ONLY tier and the diff is trivial.
#
# Dropping the last tier here degrades to claude-only, which clear-cr-marker
# gate 3b then REFUSES when CR_REQUIRE_CROSS_MODEL=1 (exit 14) — two correct
# mechanisms, jointly unsatisfiable, so a one-liner could never clear. Observed
# live twice. The panel now keeps exactly ONE external critic on that path.
#
# Two paid rows, to prove "exactly one" is a real cap and not just the registry
# happening to hold a single paid critic.
PAID2_MODEL="vendor/paid-model-2"
JSON2="$tmp/critics-tg2.json"
printf '{"panel":[
  {"slug":"paidcrit","model":"%s","provider":"test","tier":"paid"},
  {"slug":"paidcrit2","model":"%s","provider":"test","tier":"paid"}
]}' "$PAID_MODEL" "$PAID2_MODEL" > "$JSON2"

run_case2() {  # like run_case but with the two-paid-row registry
    _d="$1"; _o="$2"; _e="$3"; _c="$4"
    : > "$_c"
    printf '%s' "$_d" | CRITICS_JSON="$JSON2" CRITIC_FIRST_PASS="$STUB" \
        TG_CAPTURE="$_c" bash "$PANEL" >"$_o" 2>"$_e"
}

# 6: CR_REQUIRE_CROSS_MODEL=1 -> keep exactly ONE critic, do not exit 1.
CR_PROFILE="paid" CR_REQUIRE_CROSS_MODEL=1 \
    run_case2 "$TRIVIAL_DIFF" "$tmp/out6" "$tmp/err6" "$tmp/cap6"
rc6=$?
out6="$(cat "$tmp/out6")"; err6="$(cat "$tmp/err6")"
check "6: panel does NOT degrade to claude-only" "$rc6" "0"
check "6: exactly ONE critic ran" "$(grep -c . "$tmp/cap6")" "1"
check_contains "6: says why it kept a critic" "$err6" "keeping exactly ONE external critic"
check_contains "6: names the cap it applied" "$err6" "panel capped to 1 critic"
check_contains "6: the surviving critic answered" "$out6" "(1/1 critics responded)"
# HIMMEL-2129 (HIMMEL-2128 follow-up): the SKIPPED critic (paidcrit2) is
# configured AND available -- just not consulted to save cost -- so it must
# get a non-exhaustion avail row too, not silent absence (which looked
# identical to "never configured" to clear-cr-marker's
# CR_FLOOR_FALLBACK=claude-only exhaustion check). The surviving critic's own
# counts (1/1, exit 0) stay exactly as asserted above.
check_contains "6: dropped critic reported keep-one-skipped (HIMMEL-2129)" "$err6" \
    "panel-availability: paidcrit2 unavailable (trivial-diff keep-one cap) reason=keep-one-skipped"
check "6: dropped critic never actually consulted (no ok line)" \
    "$(printf '%s\n' "$err6" | grep -cF 'panel-availability: paidcrit2 ok')" "0"

# 6c (codex-1 CR round, HIMMEL-2129): the stderr diagnostic above is not
# proof a REAL ledger row landed -- prove it against the real
# ledger-append.sh (this file otherwise stubs CRITIC_LEDGER_APPEND to a
# no-op), the same way clear-cr-marker.sh's CR_FLOOR_FALLBACK=claude-only
# check will read it: a non-exhaustion reason on a genuine avail row.
LEDGER6="$tmp/ledger6.jsonl"
: > "$LEDGER6"
: > "$tmp/cap6c"
printf '%s' "$TRIVIAL_DIFF" | CR_PROFILE="paid" CR_REQUIRE_CROSS_MODEL=1 \
    CR_LEDGER="$LEDGER6" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$JSON2" CRITIC_FIRST_PASS="$STUB" TG_CAPTURE="$tmp/cap6c" \
    bash "$PANEL" >"$tmp/out6c" 2>"$tmp/err6c"
rc6c=$?
ledger6_summary="$(python3 - "$LEDGER6" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
avail = [r for r in rows if r.get('kind') == 'avail']
p2 = [r for r in avail if r.get('model') == 'paidcrit2']
print('avail=' + str(len(avail)))
print('ok=' + str(sum(r.get('status') == 'ok' for r in avail)))
print('p2-count=' + str(len(p2)))
print('p2-status=' + (p2[0].get('status', '') if p2 else 'MISSING'))
print('p2-reason=' + (p2[0].get('reason', '') if p2 else 'MISSING'))
PYEOF
)"
check "6c: panel exit code unaffected" "$rc6c" "0"
check "6c: 2 avail rows (1 real responder + 1 keep-one-skipped)" \
    "$(printf '%s\n' "$ledger6_summary" | sed -n 's/^avail=//p')" "2"
check "6c: the 1 real responder is still ok" "$(printf '%s\n' "$ledger6_summary" | sed -n 's/^ok=//p')" "1"
check "6c: exactly one paidcrit2 avail row (not double-counted)" \
    "$(printf '%s\n' "$ledger6_summary" | sed -n 's/^p2-count=//p')" "1"
check "6c: paidcrit2 row is unavailable" "$(printf '%s\n' "$ledger6_summary" | sed -n 's/^p2-status=//p')" "unavailable"
check "6c: paidcrit2 reason is keep-one-skipped (NOT an exhaustion class)" \
    "$(printf '%s\n' "$ledger6_summary" | sed -n 's/^p2-reason=//p')" "keep-one-skipped"

# 7: same shape WITHOUT the cross-model floor -> the old cheap path is intact.
# The claude-only floor clears the marker on its own there, so spending a paid
# call would be the regression.
CR_PROFILE="paid" CR_REQUIRE_CROSS_MODEL=0 \
    run_case2 "$TRIVIAL_DIFF" "$tmp/out7" "$tmp/err7" "$tmp/cap7"
rc7=$?
err7="$(cat "$tmp/err7")"
check "7: still degrades to claude-only (rc 1)" "$rc7" "1"
check "7: no critic was spent" "$(grep -c . "$tmp/cap7")" "0"
check_contains "7: the refusal explains the interaction" "$err7" \
    "CR_REQUIRE_CROSS_MODEL is NOT set"

# 8: a NONTRIVIAL diff with the floor set is untouched — both paid rows run.
# The cap must apply to the trivial path only, never narrow a real review.
CR_PROFILE="paid" CR_REQUIRE_CROSS_MODEL=1 \
    run_case2 "$NONTRIVIAL_DIFF" "$tmp/out8" "$tmp/err8" "$tmp/cap8"
check "8: nontrivial diff still runs the whole paid panel" "$(grep -c . "$tmp/cap8")" "2"

if [ "$fails" -eq 0 ]; then
    if [ "$_skips" -gt 0 ]; then
        echo "ALL PASS ($_skips skipped)"
    else
        echo "ALL PASS"
    fi
else
    echo "$fails FAILED"
    exit 1
fi
