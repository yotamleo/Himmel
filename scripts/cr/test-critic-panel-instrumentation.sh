#!/usr/bin/env bash
# scripts/cr/test-critic-panel-instrumentation.sh -- HIMMEL-1500 instrumentation
# + auto-carry.
#
# Two things this ticket adds on top of the existing panel/ledger mechanism
# (extended, not duplicated — see ledger-append.sh's `attempt` kind and
# critic-panel.sh's _queue_attempt):
#
#   1. INSTRUMENT: every invocation ATTEMPT (the primary try + each fallback
#      candidate) gets its own `attempt` ledger row — model, status
#      (ok|timeout|error), attempt number, MEASURED duration_secs. Unlike
#      `avail` (one authoritative row per head+model), attempt rows are never
#      deduped, so a retried member's full timing history survives for
#      peak-window correlation (the HIMMEL-1500 ask), not just the final
#      verdict.
#   2. AUTO-CARRY: a critic that times out with no retry configured must not
#      silently vanish from the merged review. The panel already proceeds on
#      the surviving critics (>=1 responded -> exit 0, findings emitted) —
#      what was missing is that the merged STDOUT itself (a PR comment, a gate
#      log) carried no sign of the drop; only stderr's panel-availability
#      lines did. This suite proves the merged output now surfaces an
#      explicit "N of M critics did not respond" note + the unavailable
#      critic's reason/duration, and that a CLEAN run (all responded) shows
#      no such note.
#
# Stubs exit 124 directly to simulate a timeout outcome (rc=124/137 is all
# process_member inspects) rather than actually hanging + waiting on a REAL
# `timeout` kill — faster and avoids the documented Git-Bash
# timeout-does-not-reap-grandchildren trap other suites here work around with
# `exec sleep N`.
# Bash 3.2-safe.
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

unset CR_PROFILE CRITIC_PANEL_TIERS CRITIC_LEDGER_APPEND CR_LEDGER \
    CRITIC_FIRST_PASS CRITICS_JSON CRITIC_PARALLEL CRITIC_TIMEOUT_SECS \
    CRITIC_PANEL_TOTAL_TIMEOUT_SECS CRITIC_PANEL_STARTED_AT \
    CR_TRIVIALITY_OVERRIDE 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$HERE/critic-panel.sh"
tmp="$(mktemp -d -t critic-panel-instrumentation-test.XXXXXX)"
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
    if grepq "$2" -F -- "$3"; then
        echo "ok - $1"
    else
        echo "FAIL - $1: expected to contain [$3]"
        fails=$((fails + 1))
    fi
}

check_not_contains() {
    if grepq "$2" -F -- "$3"; then
        echo "FAIL - $1: expected NOT to contain [$3]"
        fails=$((fails + 1))
    else
        echo "ok - $1"
    fi
}

DIFF='diff --git a/foo.sh b/foo.sh
index 0000000..1111111 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,3 @@
 line
+null check missing
+x = 1'

# ===========================================================================
# Case 1: self-retry (glm's shipped shape) -- the ledger gets BOTH attempts,
# not just the final verdict. Uses the REAL ledger-append.sh (CR_LEDGER only,
# CRITIC_LEDGER_APPEND left at its default) so the `attempt` kind is exercised
# end to end, not just asserted against a stub.
# ===========================================================================
JSON1="$tmp/critics-self.json"
printf '{"panel":[{"slug":"glm","model":"glm-5.2","provider":"zai","route_provider":"glm","tier":"free","fallback_models":["glm-5.2"],"fallback_trigger":"any","fallback_provider":"glm"}]}' \
    > "$JSON1"
STUB1="$tmp/stub1.sh"
cat > "$STUB1" <<'EOS'
#!/usr/bin/env bash
slug=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slug) slug="$2"; shift 2 ;;
        --perspective-file) shift 2 ;;
        *) shift ;;
    esac
done
cat >/dev/null
n=$(cat "$SELF_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$SELF_COUNT"
[ "$n" -eq 1 ] && exit 124
printf '# %s First-Pass Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n' "$slug"
exit 0
EOS
chmod +x "$STUB1"

LEDGER1="$tmp/ledger1.jsonl"
: > "$tmp/selfcount1"
printf '%s' "$DIFF" | SELF_COUNT="$tmp/selfcount1" CRITICS_JSON="$JSON1" CRITIC_FIRST_PASS="$STUB1" \
    CR_LEDGER="$LEDGER1" bash "$PANEL" >"$tmp/out1" 2>"$tmp/err1"
rc1=$?
check "1: retried member (2 attempts)" "$(cat "$tmp/selfcount1")" "2"
check "1: panel exit 0 (fallback recovered)" "$rc1" "0"

n_attempts1="$(grep -c '"kind":"attempt"' "$LEDGER1" 2>/dev/null || echo 0)"
check "1: TWO attempt rows written (primary + retry, never deduped)" "$n_attempts1" "2"
attempt1_status="$(node -e 'const fs=require("fs");const rs=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.kind==="attempt"&&r.model==="glm");console.log(rs[0]&&rs[0].status)' "$LEDGER1" 2>/dev/null)"
check "1: first attempt row status=timeout" "$attempt1_status" "timeout"
attempt1_has_duration="$(node -e 'const fs=require("fs");const rs=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.kind==="attempt"&&r.model==="glm");console.log(rs[0]&&typeof rs[0].duration_secs==="number")' "$LEDGER1" 2>/dev/null)"
check "1: first attempt row carries a numeric duration_secs" "$attempt1_has_duration" "true"
attempt2_shape="$(node -e 'const fs=require("fs");const rs=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.kind==="attempt"&&r.model==="glm");console.log(rs[1]&&(rs[1].attempt+","+rs[1].status))' "$LEDGER1" 2>/dev/null)"
check "1: second attempt row is attempt=2, status=ok" "$attempt2_shape" "2,ok"
avail1_status="$(node -e 'const fs=require("fs");const o=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).find(r=>r.kind==="avail");console.log(o&&o.status)' "$LEDGER1" 2>/dev/null)"
check "1: the authoritative avail row still reads ok (unchanged contract)" "$avail1_status" "ok"

# ===========================================================================
# Case 2: plain timeout, no fallback -- ONE attempt row, and the avail row's
# detail carries the MEASURED duration (not just the configured budget).
# ===========================================================================
JSON2="$tmp/critics-plain.json"
printf '{"panel":[{"slug":"glm","model":"glm-5.2","provider":"zai","route_provider":"glm","tier":"free"}]}' > "$JSON2"
STUB2="$tmp/stub2.sh"
cat > "$STUB2" <<'EOS'
#!/usr/bin/env bash
cat >/dev/null
exit 124
EOS
chmod +x "$STUB2"
LEDGER2="$tmp/ledger2.jsonl"
printf '%s' "$DIFF" | CRITICS_JSON="$JSON2" CRITIC_FIRST_PASS="$STUB2" \
    CR_LEDGER="$LEDGER2" bash "$PANEL" >"$tmp/out2" 2>"$tmp/err2"
rc2=$?
check "2: no-fallback timeout -> panel exit 1 (zero responders)" "$rc2" "1"
n_attempts2="$(grep -c '"kind":"attempt"' "$LEDGER2" 2>/dev/null || echo 0)"
check "2: exactly ONE attempt row (no retry configured)" "$n_attempts2" "1"
avail2_detail="$(node -e 'const fs=require("fs");const o=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).find(r=>r.kind==="avail");console.log(o&&o.detail)' "$LEDGER2" 2>/dev/null)"
check_contains "2: avail detail names the MEASURED duration, not just the config" "$avail2_detail" "timed out after"

# ===========================================================================
# Case 3 (auto-carry): a 2-member panel where ONE member times out (no
# fallback) and the OTHER responds. The panel already does not BLOCK on this
# (exit 0, findings from the survivor emitted) -- what this case proves is
# that the merged STDOUT itself now says so, not just stderr.
# ===========================================================================
JSON3="$tmp/critics-partial.json"
printf '{"panel":[{"slug":"a","model":"model-a","provider":"p","tier":"free"},{"slug":"b","model":"model-b","provider":"p","tier":"free"}]}' > "$JSON3"
STUB3="$tmp/stub3.sh"
cat > "$STUB3" <<'EOS'
#!/usr/bin/env bash
slug=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slug) slug="$2"; shift 2 ;;
        --perspective-file) shift 2 ;;
        *) shift ;;
    esac
done
cat >/dev/null
if [ "$slug" = "a" ]; then
    exit 124
fi
printf '# %s First-Pass Review\n\n## Critical Issues (1 found)\n- [%s-1]: something [foo.sh:2]\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n' "$slug" "$slug"
exit 0
EOS
chmod +x "$STUB3"
LEDGER3="$tmp/ledger3.jsonl"
printf '%s' "$DIFF" | CRITICS_JSON="$JSON3" CRITIC_FIRST_PASS="$STUB3" \
    CR_LEDGER="$LEDGER3" bash "$PANEL" >"$tmp/out3" 2>"$tmp/err3"
rc3=$?
out3="$(cat "$tmp/out3")"
check "3: auto-carry -- panel exits 0 (NOT blocked by the one timeout)" "$rc3" "0"
check_contains "3: merged review responded count is 1/2" "$out3" "(1/2 critics responded)"
check_contains "3: merged review carries a visible degrade note" "$out3" "## Note: 1 of 2 critics did not respond"
check_contains "3: the note names the unavailable critic + timeout reason" "$out3" "- a: unavailable reason=timeout"
check_contains "3: the note carries the measured duration (not fabricated)" "$out3" "timed out after"
check_contains "3: findings from the surviving critic are NOT dropped" "$out3" "something"
check_contains "3: NO fabricated verdict -- Critical Issues section still present" "$out3" "## Critical Issues"

# Control: a CLEAN run (both respond) shows NO degrade note.
JSON3C="$tmp/critics-clean.json"
printf '{"panel":[{"slug":"a","model":"model-a","provider":"p","tier":"free"},{"slug":"b","model":"model-b","provider":"p","tier":"free"}]}' > "$JSON3C"
STUB3C="$tmp/stub3c.sh"
cat > "$STUB3C" <<'EOS'
#!/usr/bin/env bash
slug=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slug) slug="$2"; shift 2 ;;
        --perspective-file) shift 2 ;;
        *) shift ;;
    esac
done
cat >/dev/null
printf '# %s First-Pass Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n' "$slug"
exit 0
EOS
chmod +x "$STUB3C"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/noop.sh"; chmod +x "$tmp/noop.sh"
printf '%s' "$DIFF" | CRITICS_JSON="$JSON3C" CRITIC_FIRST_PASS="$STUB3C" \
    CRITIC_LEDGER_APPEND="$tmp/noop.sh" bash "$PANEL" >"$tmp/out3c" 2>"$tmp/err3c"
out3c="$(cat "$tmp/out3c")"
check_contains "3c control: clean run responded 2/2" "$out3c" "(2/2 critics responded)"
check_not_contains "3c control: NO degrade note on a clean run" "$out3c" "## Note:"

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
