#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-glm-external-writes.sh (HIMMEL-654 GLM
# lane hardening — deterministic classifier substitute).
#
# Usage: bash scripts/hooks/test-block-glm-external-writes.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-glm-external-writes.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0
CASES=0
SKIPPED=0
GLM_URL="https://api.z.ai/api/anthropic"
BASH_ABS=$(command -v bash)
EMPTY_PATH=$(mktemp -d)
OUTBOX_FIXTURE=$(mktemp -d -t glm-outbox.XXXXXX)
OWN_SESSION="$OUTBOX_FIXTURE/glm-sessions/glm-own-1"
SIBLING_SESSION="$OUTBOX_FIXTURE/glm-sessions/glm-sibling-2"
mkdir -p "$OWN_SESSION" "$SIBLING_SESSION"
native_dir() {
    (cd "$1" && pwd -W 2>/dev/null) || (cd "$1" && pwd -P)
}
OWN_SESSION_NATIVE=$(native_dir "$OWN_SESSION")
SIBLING_SESSION_NATIVE=$(native_dir "$SIBLING_SESSION")
REPO_ROOT=$(cd "$(dirname "$HOOK")/../.." && pwd -P)
REPO_ROOT_NATIVE=$(native_dir "$REPO_ROOT")
HELPER="$REPO_ROOT/scripts/glm/append-outbox.sh"
HELPER_NATIVE="$REPO_ROOT_NATIVE/scripts/glm/append-outbox.sh"
cp "$HELPER" "$OWN_SESSION/append-outbox.sh"
cp "$HELPER" "$SIBLING_SESSION/append-outbox.sh"
OWN_HELPER="$OWN_SESSION/append-outbox.sh"
OWN_HELPER_NATIVE="$OWN_SESSION_NATIVE/append-outbox.sh"
SIBLING_HELPER_NATIVE="$SIBLING_SESSION_NATIVE/append-outbox.sh"

# run_case <json> [VAR=val ...] — extra args become env assignments.
# HIMMEL-2085: also unset the generalized worker-ness/pin-dir vars so a
# developer's own shell env (or a leftover from an earlier case) can never
# leak into a case that does not explicitly set them.
run_case() {
    local input="$1"; shift
    printf '%s' "$input" | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK -u GLM_SESSION_DIR \
        -u HIMMEL_WORKER -u HIMMEL_HOOK_INTEGRITY_DIR -u HIMMEL_HOOK_INTEGRITY_BYPASS_OK "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    CASES=$((CASES + 1))
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

# skip_case <label> <reason> — platform-gated case whose premise cannot exist
# on this host. Still increments CASES (so EXPECTED_CASES stays a true
# invariant across platforms) but never FAILED; the SKIP line names what did
# not run and why, per the no-silent-skip rule.
skip_case() {
    local label="$1" reason="$2"
    CASES=$((CASES + 1))
    SKIPPED=$((SKIPPED + 1))
    echo "SKIP $label — $reason"
}

# HIMMEL-1649 round 3: the hook is the EXECUTOR. A valid report is recorded by
# the hook and the Bash call is then DENIED (rc=2) with a success message. There
# is no explicit-allow path any more — an `allow` decision here would be a
# regression back to executing worker-reachable content, so assert it is absent.
assert_recorded() {
    local label="$1" input="$2" outbox="$3" before after out err rc decision; shift 3
    local outf errf
    outf=$(mktemp); errf=$(mktemp)
    before=$( [ -f "$outbox" ] && wc -l < "$outbox" || echo 0 )
    printf '%s' "$input" | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK -u GLM_SESSION_DIR "$@" bash "$HOOK" >"$outf" 2>"$errf"
    rc=$?
    out=$(cat "$outf"); err=$(cat "$errf"); rm -f "$outf" "$errf"
    # Round 4 [glm-3]: this guard used to read the decision off the capture of
    # `2>&1 >/dev/null` — i.e. STDERR — so it could never fire. A structured
    # permissionDecision arrives on STDOUT (where Claude Code reads it, and where
    # it would OVERRIDE the exit code), and the old capture threw stdout away.
    # Today the hook has no explicit-allow path at all: it allows by a bare
    # `exit 0` with no output, so an `allow` object appearing here at all would
    # be the regression back to executing worker-reachable content.
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    after=$( [ -f "$outbox" ] && wc -l < "$outbox" || echo 0 )
    CASES=$((CASES + 1))
    if [ "$rc" = 2 ] && [ "$decision" != "allow" ] \
       && printf '%s' "$err" | grep -q "guard recorded your report" \
       && [ "$after" -eq $((before + 1)) ]; then
        echo "PASS $label (recorded by hook, command denied)"
    else
        echo "FAIL $label — expected rc=2 + success message + 1 appended row, got rc=$rc rows=$before->$after"
        FAILED=$((FAILED + 1))
    fi
}

# A rejected payload must append NOTHING and deny with a non-success reason.
assert_rejected_no_append() {
    local label="$1" input="$2" outbox="$3" before after err rc; shift 3
    before=$( [ -f "$outbox" ] && wc -l < "$outbox" || echo 0 )
    err=$(printf '%s' "$input" | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK -u GLM_SESSION_DIR "$@" bash "$HOOK" 2>&1 >/dev/null)
    rc=$?
    after=$( [ -f "$outbox" ] && wc -l < "$outbox" || echo 0 )
    CASES=$((CASES + 1))
    if [ "$rc" = 2 ] && [ "$after" -eq "$before" ] \
       && ! printf '%s' "$err" | grep -q "guard recorded your report"; then
        echo "PASS $label (fail-closed, nothing appended)"
    else
        echo "FAIL $label — expected rc=2 + no append + no success message, got rc=$rc rows=$before->$after"
        FAILED=$((FAILED + 1))
    fi
}

b64url() { node -e 'process.stdout.write(Buffer.from(process.argv[1],"utf8").toString("base64url"))' "$1"; }

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# jq-missing runner: empty PATH hides jq from the hook, but bash is invoked by
# absolute path so the script still runs and must fail closed at the jq check.
run_case_no_jq() {
    printf '%s' "$1" | env -u ANTHROPIC_BASE_URL "ANTHROPIC_BASE_URL=$GLM_URL" PATH="$EMPTY_PATH" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    echo "$?"
}
# HIMMEL-2085 CR history: round 2 [codex-3] fail-OPENED a native-only
# worker_lane here (scope concern); round 3 [codex-1] correctly called that a
# reopening of the pin-forging attack this ticket exists to close (jq-missing
# means the pin-dir class cannot evaluate anything, so fail-open leaves it
# silently inert) -- reverted back to fail-closed for every worker_lane. The
# SAME jq-missing runner, but for a native-only worker_lane (HIMMEL_WORKER=1,
# no ANTHROPIC_BASE_URL) instead of glm_lane, pinning that both now agree.
run_case_no_jq_native() {
    printf '%s' "$1" | env -u ANTHROPIC_BASE_URL -u HIMMEL_WORKER "HIMMEL_WORKER=1" PATH="$EMPTY_PATH" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    echo "$?"
}

# --- OFF-LANE: everything allowed (expect rc=0) ---
assert_rc "off-lane git push"            0 "$(run_case "$(j_bash 'git push origin main')")"
assert_rc "off-lane gh pr create"        0 "$(run_case "$(j_bash 'gh pr create --title x')")"
assert_rc "off-lane mcp tool"            0 "$(run_case '{"tool_name":"mcp__plugin_github_github__merge_pull_request","tool_input":{}}')"
assert_rc "anthropic-url non-glm"        0 "$(run_case "$(j_bash 'git push')" "ANTHROPIC_BASE_URL=https://api.anthropic.com")"

# --- HIMMEL-1649: fixed own-session outbox helper carve-out ---
# GLM_SESSION_DIR is the dispatcher-owned inherited-env seam. The hook emits an
# EXPLICIT allow only for an exact helper invocation carrying one strict
# base64url token. Write/Edit stay native-denied and the old interpolated node -e
# append is now always denied.
OUTBOX_TOKEN="bGFuZSBlMmU"
# shellcheck disable=SC2016  # literal inherited variable spelling is command text under test
VAR_APPEND='bash "$GLM_SESSION_DIR/append-outbox.sh" bGFuZSBlMmU'
# DISTINCT payloads per shape variant (HIMMEL-1649 round 3): all three go to the
# SAME outbox back-to-back, and the F2 consecutive-duplicate suppression would
# (correctly) swallow the 2nd and 3rd if they repeated the first one's payload.
NATIVE_TOKEN=$(b64url 'lane e2e native')
POSIX_TOKEN=$(b64url 'lane e2e posix')
NATIVE_APPEND="bash $OWN_HELPER_NATIVE $NATIVE_TOKEN"
POSIX_APPEND="bash $OWN_HELPER $POSIX_TOKEN"
OWN_OUTBOX="$OWN_SESSION/outbox.jsonl"
assert_recorded "glm inherited session report recorded by hook" "$(j_bash "$VAR_APPEND")" "$OWN_OUTBOX" \
    "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
assert_recorded "glm native absolute session report recorded by hook" "$(j_bash "$NATIVE_APPEND")" "$OWN_OUTBOX" \
    "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
assert_recorded "glm POSIX absolute session report recorded by hook" "$(j_bash "$POSIX_APPEND")" "$OWN_OUTBOX" \
    "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
# Field-wise, not exact-line: records also carry the _sig dedup digest (F2).
assert_last_record() {
    local label="$1" filter="$2" file="$3"
    CASES=$((CASES + 1))
    if [ -f "$file" ] && tail -1 "$file" | jq -e "$filter" >/dev/null 2>&1; then
        echo "PASS $label"
    else
        echo "FAIL $label — last record in $file does not satisfy: $filter"
        FAILED=$((FAILED + 1))
    fi
}
assert_last_record "glm hook-written note is note-wrapped" '.type == "note" and .text == "lane e2e posix"' "$OWN_OUTBOX"

# (i) HIMMEL-1649 round 3 — THE regression test for codex-adv-1. A booby-trapped
# helper that would drop a canary must NEVER execute: the hook records the row
# itself and denies the command, so the canary cannot appear. This is the exact
# attack the round-2 pathname-trust ALLOW permitted (worker holds Edit on its
# session dir plus Bash(node *), so it could overwrite the helper).
CANARY="$OUTBOX_FIXTURE/canary-executed"
BOOBY_SESSION="$OUTBOX_FIXTURE/glm-sessions/glm-booby-3"
mkdir -p "$BOOBY_SESSION"
BOOBY_SESSION_NATIVE=$(native_dir "$BOOBY_SESSION")
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$CANARY" > "$BOOBY_SESSION/append-outbox.sh"
chmod +x "$BOOBY_SESSION/append-outbox.sh"
# shellcheck disable=SC2016  # literal inherited variable spelling is command text under test
assert_recorded "booby-trapped helper is never executed" "$(j_bash 'bash "$GLM_SESSION_DIR/append-outbox.sh" bGFuZSBlMmU')" \
    "$BOOBY_SESSION/outbox.jsonl" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$BOOBY_SESSION_NATIVE"
CASES=$((CASES + 1))
if [ ! -e "$CANARY" ]; then
    echo "PASS booby-trap canary absent (helper content never ran)"
else
    echo "FAIL booby-trap canary present — worker-writable helper EXECUTED (codex-adv-1 regression)"
    FAILED=$((FAILED + 1))
fi

# (ii) escalation JSON round-trips as type:"escalation" so adjudicate list sees it.
ESC_JSON='{"type":"escalation","capability":"git push origin x","arm":"git-push","reason":"no push arm","step":"7 push"}'
ESC_TOKEN=$(b64url "$ESC_JSON")
assert_recorded "structured escalation recorded" "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $ESC_TOKEN")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
CASES=$((CASES + 1))
if tail -1 "$OWN_OUTBOX" | jq -e '.type == "escalation" and .capability == "git push origin x" and (.ts | type) == "string"' >/dev/null 2>&1; then
    echo "PASS escalation keeps type/capability and gains a stamped ts"
else
    echo "FAIL escalation record did not round-trip as a stamped escalation"
    FAILED=$((FAILED + 1))
fi

# (iii) non-JSON payload is note-wrapped verbatim.
PLAIN_TOKEN=$(b64url 'not json { at all')
assert_recorded "non-JSON payload note-wrapped" "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $PLAIN_TOKEN")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
assert_last_record "note-wrap preserves the text verbatim" '.type == "note" and .text == "not json { at all"' "$OWN_OUTBOX"

# --- HIMMEL-1649 round 3 (F2): consecutive-duplicate suppression -------------
# The hook appends then denies, which looks like a retryable failure. A retry
# storm must converge to ONE row, while the same note sent again LATER (after a
# different record) must still land.
DUP_TOKEN=$(b64url 'retry me')
DUP_CMD="bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $DUP_TOKEN"
assert_recorded "F2 first send of a report is recorded" "$(j_bash "$DUP_CMD")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
dup_before=$(wc -l < "$OWN_OUTBOX")
dup_err=$(printf '%s' "$(j_bash "$DUP_CMD")" | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK -u GLM_SESSION_DIR \
    "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE" bash "$HOOK" 2>&1 >/dev/null)
dup_rc=$?
dup_after=$(wc -l < "$OWN_OUTBOX")
CASES=$((CASES + 1))
if [ "$dup_rc" = 2 ] && [ "$dup_after" -eq "$dup_before" ] && printf '%s' "$dup_err" | grep -q "guard recorded your report"; then
    echo "PASS F2 immediate retry appends nothing and still reports success"
else
    echo "FAIL F2 retry — expected rc=2 + no new row + success message, got rc=$dup_rc rows=$dup_before->$dup_after"
    FAILED=$((FAILED + 1))
fi
# A DIFFERENT record breaks the streak, so the same payload lands again after it.
OTHER_TOKEN=$(b64url 'something else')
assert_recorded "F2 a different report still lands" "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $OTHER_TOKEN")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
assert_recorded "F2 the earlier payload lands again after a different one" "$(j_bash "$DUP_CMD")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"

# --- HIMMEL-1649 round 3 (F1): the interceptor is a SERVICE above the bypass --
# GLM_EXTERNAL_WRITES_OK disables ENFORCEMENT only. Under bypass the report must
# STILL be hook-recorded with identical semantics, and the booby-trapped helper
# must STILL never execute — otherwise a bypass session silently downgrades
# structured escalations to text notes the adjudicator cannot see.
BYPASS_SESSION="$OUTBOX_FIXTURE/glm-sessions/glm-bypass-4"
mkdir -p "$BYPASS_SESSION"
BYPASS_SESSION_NATIVE=$(native_dir "$BYPASS_SESSION")
BYPASS_CANARY="$OUTBOX_FIXTURE/canary-bypass"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$BYPASS_CANARY" > "$BYPASS_SESSION/append-outbox.sh"
chmod +x "$BYPASS_SESSION/append-outbox.sh"
BYPASS_ESC=$(b64url '{"type":"escalation","capability":"gh pr merge","arm":"gh","reason":"bypass","step":"9"}')
# shellcheck disable=SC2016  # literal inherited variable spelling is command text under test
assert_recorded "F1 bypass session still gets its report hook-recorded" \
    "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $BYPASS_ESC")" "$BYPASS_SESSION/outbox.jsonl" \
    "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$BYPASS_SESSION_NATIVE" "GLM_EXTERNAL_WRITES_OK=1"
assert_last_record "F1 bypass escalation keeps its structured type" '.type == "escalation" and .arm == "gh"' "$BYPASS_SESSION/outbox.jsonl"
CASES=$((CASES + 1))
if [ ! -e "$BYPASS_CANARY" ]; then
    echo "PASS F1 bypass canary absent (helper still never executed under bypass)"
else
    echo "FAIL F1 bypass canary present — bypass executed the on-disk helper"
    FAILED=$((FAILED + 1))
fi
# ENFORCEMENT really is off under bypass: a push still sails through.
assert_rc "F1 bypass still disables enforcement (git push allowed)" 0 \
    "$(run_case "$(j_bash 'git push origin main')" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_EXTERNAL_WRITES_OK=1")"

# --- HIMMEL-1649 round 4 [codex-1]: WHERE the no-execution property holds -----
# "No on-disk content executes" is an ENFORCEMENT-mode property. The F1 cases
# above pin the CONTRACT-SHAPED command under bypass (still hook-recorded, still
# no execution). These pin the other half honestly: a NEAR-MISS command shape is
# denied under enforcement, but under operator bypass it falls through and the
# on-disk helper IS the executor — by design, because that helper is the
# lockstep implementation of the same fail-closed schema. So the guarantee that
# survives the mode switch is the one that matters: a malformed payload appends
# nothing either way; only the executor differs.
R4_SESSION="$OUTBOX_FIXTURE/glm-sessions/glm-r4-6"
mkdir -p "$R4_SESSION"
R4_SESSION_NATIVE=$(native_dir "$R4_SESSION")
cp "$HELPER" "$R4_SESSION/append-outbox.sh"
R4_OUTBOX="$R4_SESSION/outbox.jsonl"
# Schema-invalid payload (escalation missing arm/reason/step) carried by a
# near-miss command shape (a trailing extra argument).
R4_BAD=$(b64url '{"type":"escalation","capability":"only-capability"}')
# shellcheck disable=SC2016  # literal inherited variable spelling is command text under test
R4_NEARMISS="bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $R4_BAD extra"
assert_rc "R4 enforcement denies the near-miss helper command" 2 \
    "$(run_case "$(j_bash "$R4_NEARMISS")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$R4_SESSION_NATIVE")"
assert_rc "R4 bypass lets the near-miss through to the on-disk helper" 0 \
    "$(run_case "$(j_bash "$R4_NEARMISS")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$R4_SESSION_NATIVE" "GLM_EXTERNAL_WRITES_OK=1")"
CASES=$((CASES + 1))
if [ ! -s "$R4_OUTBOX" ]; then
    echo "PASS R4 bypass hook appended nothing (the helper, not the hook, is the executor)"
else
    echo "FAIL R4 bypass hook appended a row for a command it did not service"
    FAILED=$((FAILED + 1))
fi
# The bypass-mode executor fail-closes exactly what the hook would have rejected.
env -u GLM_SESSION_DIR "GLM_SESSION_DIR=$R4_SESSION_NATIVE" bash "$R4_SESSION/append-outbox.sh" "$R4_BAD" >/dev/null 2>&1
r4_rc=$?
CASES=$((CASES + 1))
if [ "$r4_rc" = 2 ] && [ ! -s "$R4_OUTBOX" ]; then
    echo "PASS R4 the lockstep helper fail-closes the malformed payload, appending nothing"
else
    echo "FAIL R4 helper did not fail closed under bypass — rc=$r4_rc, outbox non-empty=$([ -s "$R4_OUTBOX" ] && echo yes || echo no)"
    FAILED=$((FAILED + 1))
fi
# Well-formed under bypass: the helper writes the SAME record the hook writes.
# An explicit ts makes the two byte-comparable (both stamp only when absent).
R4_GOOD_JSON='{"type":"escalation","capability":"git push origin x","arm":"git-push","reason":"lockstep check","step":"11","ts":"2026-08-09T00:00:00.000Z"}'
R4_GOOD=$(b64url "$R4_GOOD_JSON")
R4_HOOK_SESSION="$OUTBOX_FIXTURE/glm-sessions/glm-r4-hook-7"
mkdir -p "$R4_HOOK_SESSION"
R4_HOOK_SESSION_NATIVE=$(native_dir "$R4_HOOK_SESSION")
assert_recorded "R4 hook records the well-formed report" \
    "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $R4_GOOD")" "$R4_HOOK_SESSION/outbox.jsonl" \
    "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$R4_HOOK_SESSION_NATIVE"
env -u GLM_SESSION_DIR "GLM_SESSION_DIR=$R4_SESSION_NATIVE" bash "$R4_SESSION/append-outbox.sh" "$R4_GOOD" >/dev/null 2>&1
CASES=$((CASES + 1))
r4_hook_rec=$(tail -1 "$R4_HOOK_SESSION/outbox.jsonl" | jq -S -c . 2>/dev/null || true)
r4_helper_rec=$(tail -1 "$R4_OUTBOX" | jq -S -c . 2>/dev/null || true)
if [ -n "$r4_hook_rec" ] && [ "$r4_hook_rec" = "$r4_helper_rec" ]; then
    echo "PASS R4 bypass helper writes the identical record shape the hook writes"
else
    echo "FAIL R4 lockstep divergence — hook=$r4_hook_rec helper=$r4_helper_rec"
    FAILED=$((FAILED + 1))
fi

# --- HIMMEL-1649 round 9 (CodeRabbit, Major): PowerShell is a MEDIATED shell --
# hooks.json registers this hook for "Bash|PowerShell|mcp__.*", but the report
# interceptor and the near-miss deny were gated on tool=="Bash" alone. A
# PowerShell helper invocation was therefore neither hook-executed nor denied:
# it fell through to the generic classifiers, which do not match
# append-outbox.sh, and EXECUTED the on-disk helper in ENFORCEMENT mode —
# contradicting the branch invariant that under enforcement the report verb is
# run by the hook, never by on-disk content. Both directions are now pinned.
# The canary proves execution, not just exit codes: a booby-trapped helper that
# would touch a file must stay untouched, which is the property that actually
# distinguishes "hook serviced it" from "the shell ran the script".
PWSH_SESSION="$OUTBOX_FIXTURE/glm-sessions/glm-pwsh-9"
mkdir -p "$PWSH_SESSION"
PWSH_SESSION_NATIVE=$(native_dir "$PWSH_SESSION")
PWSH_CANARY="$OUTBOX_FIXTURE/pwsh-canary-9"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$PWSH_CANARY" > "$PWSH_SESSION/append-outbox.sh"
chmod +x "$PWSH_SESSION/append-outbox.sh"
PWSH_TOKEN=$(b64url '{"type":"note","text":"powershell lane parity"}')
assert_recorded "R9 PowerShell helper report is recorded by the hook" \
    "$(j_pwsh "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $PWSH_TOKEN")" "$PWSH_SESSION/outbox.jsonl" \
    "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$PWSH_SESSION_NATIVE"
CASES=$((CASES + 1))
if [ ! -e "$PWSH_CANARY" ]; then
    echo "PASS R9 PowerShell path never executed the on-disk helper (canary untouched)"
else
    echo "FAIL R9 PowerShell path EXECUTED the on-disk helper — canary fired"
    FAILED=$((FAILED + 1))
fi
# A malformed PowerShell helper mention must fail closed, exactly like Bash.
PWSH_NEARMISS="bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $PWSH_TOKEN extra"
assert_rejected_no_append "R9 PowerShell near-miss fails closed" \
    "$(j_pwsh "$PWSH_NEARMISS")" "$PWSH_SESSION/outbox.jsonl" \
    "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$PWSH_SESSION_NATIVE"
CASES=$((CASES + 1))
if [ ! -e "$PWSH_CANARY" ]; then
    echo "PASS R9 PowerShell near-miss did not execute the on-disk helper"
else
    echo "FAIL R9 PowerShell near-miss EXECUTED the on-disk helper — canary fired"
    FAILED=$((FAILED + 1))
fi

# --- HIMMEL-1649 round 4 [codex-adv-r4-1]: a torn JSONL tail ------------------
# An interrupted earlier append leaves the file ending mid-line. Appending onto
# it would concatenate the new JSON into that partial line — consumers
# (fleet-control/aggregator/escalations.ts jsonl()) skip the combined invalid
# line, while deny_recorded still tells the worker the report was saved. The new
# record must land as its own independently parseable line.
TORN_SESSION="$OUTBOX_FIXTURE/glm-sessions/glm-torn-8"
mkdir -p "$TORN_SESSION"
TORN_SESSION_NATIVE=$(native_dir "$TORN_SESSION")
TORN_OUTBOX="$TORN_SESSION/outbox.jsonl"
printf '{"type":"note","text":"interrupted mid-write"' > "$TORN_OUTBOX"
TORN_TOKEN=$(b64url 'after the torn tail')
torn_err=$(printf '%s' "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $TORN_TOKEN")" \
    | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK -u GLM_SESSION_DIR \
      "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$TORN_SESSION_NATIVE" bash "$HOOK" 2>&1 >/dev/null)
torn_rc=$?
CASES=$((CASES + 1))
if [ "$torn_rc" = 2 ] && printf '%s' "$torn_err" | grep -q "guard recorded your report" \
   && tail -1 "$TORN_OUTBOX" | jq -e '.type == "note" and .text == "after the torn tail"' >/dev/null 2>&1; then
    echo "PASS torn tail did not swallow the next acknowledged report"
else
    echo "FAIL torn tail — expected rc=2 + success message + an independently parseable last line, got rc=$torn_rc"
    FAILED=$((FAILED + 1))
fi

# (iv) schema violations fail CLOSED and append nothing.
BAD_TYPE=$(b64url '{"type":"grant","text":"x"}')
assert_rejected_no_append "unknown type rejected" "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $BAD_TYPE")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
BAD_KEY=$(b64url '{"type":"note","text":"x","evil":1}')
assert_rejected_no_append "unknown key rejected" "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $BAD_KEY")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
BAD_FIELD=$(b64url '{"type":"escalation","capability":1,"arm":"gh","reason":"r","step":"s"}')
assert_rejected_no_append "non-string escalation field rejected" "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $BAD_FIELD")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"
MISSING_FIELD=$(b64url '{"type":"escalation","capability":"c","arm":"gh","reason":"r"}')
assert_rejected_no_append "escalation missing step rejected" "$(j_bash "bash \"\$GLM_SESSION_DIR/append-outbox.sh\" $MISSING_FIELD")" \
    "$OWN_OUTBOX" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE"

OLD_REPO_REL="bash scripts/glm/append-outbox.sh $OUTBOX_TOKEN"
OLD_REPO_NATIVE="bash $HELPER_NATIVE $OUTBOX_TOKEN"
OLD_REPO_POSIX="bash $HELPER $OUTBOX_TOKEN"
ENV_PREFIX_APPEND="GLM_SESSION_DIR=$SIBLING_SESSION_NATIVE bash $OWN_HELPER_NATIVE $OUTBOX_TOKEN"
SIBLING_HELPER_APPEND="bash $SIBLING_HELPER_NATIVE $OUTBOX_TOKEN"
WRITE_HELPER="printf hacked > $OWN_HELPER_NATIVE"
assert_rc "glm old relative repo helper denied" 2 "$(run_case "$(j_bash "$OLD_REPO_REL")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm old native repo helper denied" 2 "$(run_case "$(j_bash "$OLD_REPO_NATIVE")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm old POSIX repo helper denied" 2 "$(run_case "$(j_bash "$OLD_REPO_POSIX")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm env-prefixed helper near-miss denied" 2 "$(run_case "$(j_bash "$ENV_PREFIX_APPEND")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm sibling session helper denied" 2 "$(run_case "$(j_bash "$SIBLING_HELPER_APPEND")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm write to minted session helper denied" 2 "$(run_case "$(j_bash "$WRITE_HELPER")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"

OLD_APPEND="node -e \"require('fs').appendFileSync('$OWN_SESSION_NATIVE/outbox.jsonl', JSON.stringify({text:'lane e2e'})+'\\n')\""
# shellcheck disable=SC2016  # literal command substitution is hostile command text under test
OLD_INJECT="node -e \"require('fs').appendFileSync('$OWN_SESSION_NATIVE/outbox.jsonl', JSON.stringify({text:'\$(gh pr merge 1)'})+'\\n')\""
SIBLING_APPEND="node -e \"require('fs').appendFileSync('$SIBLING_SESSION_NATIVE/outbox.jsonl', JSON.stringify({text:'sibling'})+'\\n')\""
assert_rc "glm old node append denied" 2 "$(run_case "$(j_bash "$OLD_APPEND")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm old node command-substitution tunnel denied" 2 "$(run_case "$(j_bash "$OLD_INJECT")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm old node sibling session outbox denied" 2 "$(run_case "$(j_bash "$SIBLING_APPEND")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm helper metadata absent denied" 2 "$(run_case "$(j_bash "$VAR_APPEND")" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm helper metadata malformed denied" 2 "$(run_case "$(j_bash "$VAR_APPEND")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=relative/glm-sessions/glm-forged")"
# shellcheck disable=SC2016  # hostile substitutions/backticks are literal command text under test
assert_rc "glm helper command substitution denied" 2 "$(run_case "$(j_bash 'bash "$GLM_SESSION_DIR/append-outbox.sh" $(gh pr merge 1)')" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
# shellcheck disable=SC2016  # hostile backticks are literal command text under test
assert_rc "glm helper backticks denied" 2 "$(run_case "$(j_bash 'bash "$GLM_SESSION_DIR/append-outbox.sh" `gh pr merge 1`')" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
# shellcheck disable=SC2016  # literal inherited variable spelling is command text under test
assert_rc "glm helper quoted payload denied" 2 "$(run_case "$(j_bash 'bash "$GLM_SESSION_DIR/append-outbox.sh" "bGFuZSBlMmU"')" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm helper newline denied" 2 "$(run_case "$(j_bash "$(printf 'bash %s bGFuZSBlMmU\ngh pr merge 1' "$OWN_HELPER_NATIVE")")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm helper semicolon denied" 2 "$(run_case "$(j_bash "bash $OWN_HELPER_NATIVE bGFuZSBlMmU; gh pr merge 1")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm helper redirect denied" 2 "$(run_case "$(j_bash "bash $OWN_HELPER_NATIVE bGFuZSBlMmU > /tmp/x")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm helper extra argument denied" 2 "$(run_case "$(j_bash "bash $OWN_HELPER_NATIVE bGFuZSBlMmU extra")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm helper non-base64url token denied" 2 "$(run_case "$(j_bash "bash $OWN_HELPER_NATIVE abc=")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
OVERSIZE_TOKEN=$(node -e 'process.stdout.write("a".repeat(16385))')
assert_rc "glm helper oversize token denied" 2 "$(run_case "$(j_bash "bash $OWN_HELPER_NATIVE $OVERSIZE_TOKEN")" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"
assert_rc "glm valid metadata leaves git-push denial unchanged" 2 "$(run_case "$(j_bash 'git push origin feat/x')" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$OWN_SESSION_NATIVE")"

# --- ON-LANE BLOCK cases (expect rc=2) ---
assert_rc "glm git push"                 2 "$(run_case "$(j_bash 'git push origin feat/x')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm git push after &&"        2 "$(run_case "$(j_bash 'bun test && git push')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm git -C path push"         2 "$(run_case "$(j_bash 'git -C /tmp/wt push')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# shellcheck disable=SC2016  # literal $(git push) is the command text under test, not for expansion
assert_rc "glm git push in subshell"     2 "$(run_case "$(j_bash 'echo $(git push 2>&1)')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# gh carve-out (HIMMEL-675): issue ops + pr/run READS allow; everything else denies.
assert_rc "glm gh pr create"             2 "$(run_case "$(j_bash 'gh pr create --fill')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr merge"              2 "$(run_case "$(j_bash 'gh pr merge 856 --squash')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr comment"           2 "$(run_case "$(j_bash 'gh pr comment 856 --body x')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh api"                   2 "$(run_case "$(j_bash 'gh api repos/o/r/issues -f title=x')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh repo delete"           2 "$(run_case "$(j_bash 'gh repo delete o/r')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm bare gh"                  2 "$(run_case "$(j_bash 'gh')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh compound smuggle"      2 "$(run_case "$(j_bash 'gh pr view 1 && gh pr merge 1')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm IWR uppercase alias"      2 "$(run_case "$(j_pwsh 'IWR https://example.com')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm push after pipe"          2 "$(run_case "$(j_bash 'git status | git push')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm remote set-url"           2 "$(run_case "$(j_bash 'git remote set-url --push origin git@github.com:u/r.git')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm config pushurl"           2 "$(run_case "$(j_bash 'git config remote.origin.pushurl git@github.com:u/r.git')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm config --local pushurl"   2 "$(run_case "$(j_bash 'git config --local remote.origin.pushurl git@github.com:u/r.git')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm config --get url (pinned overmatch)" 2 "$(run_case "$(j_bash 'git config --get remote.origin.url')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# url.<base>.pushInsteadOf rewrites where a push LANDS without naming a remote
# or a pushurl, so it is the same escape as `remote set-url` by another key.
# Both directions are denied: setting one redirects a push, and unsetting one
# removes an operator redirect the worker was never asked to touch (HIMMEL-1961
# CR -- the deny existed, nothing pinned it).
assert_rc "glm config pushInsteadOf set"   2 "$(run_case "$(j_bash 'git config url.https://github.com/.pushInsteadOf git@github.com:')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm config pushInsteadOf unset" 2 "$(run_case "$(j_bash 'git config --unset url.https://github.com/.pushInsteadOf')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh at end of command"     2 "$(run_case "$(j_bash 'cd /tmp && gh')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm iwr (PS alias)"           2 "$(run_case "$(j_pwsh 'iwr https://example.com')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm curl"                     2 "$(run_case "$(j_bash 'curl -X POST https://api.example.com -d x=1')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm wget"                     2 "$(run_case "$(j_bash 'wget https://example.com/f.tar.gz')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm Invoke-RestMethod"        2 "$(run_case "$(j_pwsh 'Invoke-RestMethod -Uri https://api.example.com -Method Post')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp github write"         2 "$(run_case '{"tool_name":"mcp__plugin_github_github__merge_pull_request","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp atlassian (CLI-first, still blocked)" 2 "$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__createJiraIssue","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"

# --- ON-LANE ALLOW cases (expect rc=0) ---
assert_rc "glm git commit"               0 "$(run_case "$(j_bash 'git commit -m "docs: fix typos"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm commit msg says git push" 0 "$(run_case "$(j_bash 'git commit -m "explain when to git push"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm git add/status/diff"      0 "$(run_case "$(j_bash 'git add -u && git status && git diff --stat')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm bun test"                 0 "$(run_case "$(j_bash 'bun test scripts/telegram')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm bun install"              0 "$(run_case "$(j_bash 'bun install')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm prose mentions gh"        0 "$(run_case "$(j_bash 'git commit -m "docs: gh usage notes"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm jirafish not jira"        0 "$(run_case "$(j_bash 'echo jirafish')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm jira prose in commit msg" 0 "$(run_case "$(j_bash 'git commit -m "docs: fix scripts/jira/index"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# Jira CLI is operator-allowed on-lane (audited + recoverable, policy 2026-07-03).
assert_rc "glm jira CLI path (allowed)"  0 "$(run_case "$(j_bash 'node scripts/jira/dist/index.js transition HIMMEL-1 Done')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm bare jira (allowed)"      0 "$(run_case "$(j_bash 'jira list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm jira direct path (allowed)" 0 "$(run_case "$(j_bash './scripts/jira/dist/index.js list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# gh issue ops + pr/run reads are operator-allowed on-lane (HIMMEL-675 carve-out).
assert_rc "glm gh issue list (allowed)"    0 "$(run_case "$(j_bash 'gh issue list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh issue create (allowed)"  0 "$(run_case "$(j_bash 'gh issue create --title x --body y')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh issue comment (allowed)" 0 "$(run_case "$(j_bash 'gh issue comment 858 --body done')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh issue close (allowed)"   0 "$(run_case "$(j_bash 'gh issue close 858')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr view (allowed)"       0 "$(run_case "$(j_bash 'gh pr view 856')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr diff (allowed)"       0 "$(run_case "$(j_bash 'gh pr diff 856')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr checks (allowed)"     0 "$(run_case "$(j_bash 'gh pr checks 856')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh pr list (allowed)"       0 "$(run_case "$(j_bash 'gh pr list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh run list (allowed)"      0 "$(run_case "$(j_bash 'gh run list')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm gh run watch (allowed)"     0 "$(run_case "$(j_bash 'gh run watch 123')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# qmd KB reads are operator-allowed on-lane (carve-out before the blanket mcp
# deny), but COLLECTION-SCOPED to "himmel" only (HIMMEL-1239) — an unscoped
# query (no collections filter) could hit salus (PHI vault) and must deny.
assert_rc "glm mcp qmd query unscoped (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query scoped himmel (allowed)" 0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["himmel"]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query scoped salus (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["salus"]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query scoped luna (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["luna"]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query mixed himmel+salus (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["himmel","salus"]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd query empty collections array (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":[]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CR round 1 (codex-2): collections must be a JSON ARRAY — an object's VALUES
# must not satisfy the allow-list via `.[]` (e.g. {"x":"himmel"} must deny,
# matching the Python-side isinstance(collections, list) contract).
assert_rc "glm mcp qmd query collections object not array (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":{"x":"himmel"}}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CodeRabbit PR #1353: himmel + a BLANK entry must still deny — the earlier
# extract+grep-vxF shell round-trip let this through because the empty jq -r
# line collapsed out via command-substitution trailing-newline stripping.
assert_rc "glm mcp qmd query himmel+blank entry (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["himmel",""]}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# get/multi_get: only a fully-qualified qmd://himmel/... path is positively
# scoped; bare paths and #docids are cross-collection-ambiguous (deny).
assert_rc "glm mcp qmd get scoped himmel (allowed)" 0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"qmd://himmel/README.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd get scoped salus (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"qmd://salus/patient.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd get bare filename unscoped (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"README.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd get docid unscoped (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"#abc123"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CR round 5 (codex-1 r5): qmd_himmel_scoped was grep-based (per-LINE match),
# so a value with an embedded newline where any line starts with
# qmd://himmel/ passed even though the value itself starts with salus. It
# must be a whole-STRING prefix check (matches Python re.match, no MULTILINE).
QMD_NEWLINE_FILE="$(jq -n --arg file "$(printf 'qmd://salus/secret\nqmd://himmel/x')" '{tool_name:"mcp__plugin_qmd_qmd__get",tool_input:{file:$file}}')"
assert_rc "glm mcp qmd get salus-then-himmel via newline (denied)" 2 "$(run_case "$QMD_NEWLINE_FILE" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get scoped himmel (allowed)" 0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/*.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get mixed scoped+unscoped (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/a.md,notes.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get luna referenced (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://luna/*.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CR round 1 (glm-3): under nullglob, a glob-bearing non-himmel segment that
# matches no file must still DENY. The awk-based validation (CR round 4)
# never does pathname expansion at all, so this stays denied unconditionally
# regardless of nullglob — kept as a regression pin.
assert_rc "glm mcp qmd multi_get salus glob under nullglob (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://salus/*.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL" "BASHOPTS=nullglob")"
# CR round 2 (codex-1 r2): a pattern of only empty comma-separated segments
# (",") must deny. Originally guarded by an explicit zero-iteration counter;
# now covered directly by the awk validation's NF==0 / empty-field checks
# (CR round 4) — kept as a regression pin.
assert_rc "glm mcp qmd multi_get comma-only pattern (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":","}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# CR round 4 (codex-1 r4) — ROOT CAUSE: bash word-splitting DROPS empty
# comma-separated fields, so a trailing/leading/adjacent-comma pattern lost
# its empty segment and was wrongly allowed despite containing one. The awk
# -F',' replacement preserves empty fields (NF counts them), matching
# Python's `pattern.split(",")` exactly — these three must all deny.
assert_rc "glm mcp qmd multi_get trailing comma (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/a.md,"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get leading comma (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":",qmd://himmel/a.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm mcp qmd multi_get adjacent commas (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/a.md,,qmd://himmel/b.md"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# status has no scoping input at all -> denied fail-closed.
assert_rc "glm mcp qmd status (denied)" 2 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__status","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
# off-lane: qmd fence does not apply — the pre-existing off-lane mcp allow
# case above ("off-lane mcp tool") already covers an unscoped qmd call
# reaching this hook when ANTHROPIC_BASE_URL is not the GLM lane.
assert_rc "off-lane mcp qmd query unscoped (allowed, off-lane)" 0 "$(run_case '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{}}')"
assert_rc "glm Read tool ignored"        0 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm empty command"            0 "$(run_case '{"tool_name":"Bash","tool_input":{}}' "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm multi-line prose push"    0 "$(run_case "$(j_bash "$(printf 'git commit -m "notes\nabout git push etiquette"')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
# Newlines are command separators (flattened to ';'): a second-line mutation
# must NOT slip through as an "argument" of the first line.
assert_rc "glm newline gh smuggle"       2 "$(run_case "$(j_bash "$(printf 'gh pr view 1\ngh pr merge 1')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm newline git push"         2 "$(run_case "$(j_bash "$(printf 'echo hi\ngit push')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
# Pinned over-block: quoted prose whose LINE STARTS with a blocked verb.
assert_rc "glm prose line-start push (pinned overmatch)" 2 "$(run_case "$(j_bash "$(printf 'git commit -m "notes\ngit push later"')")" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm prose remote set-url"     0 "$(run_case "$(j_bash 'git commit -m "docs: note the remote set-url tripwire"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm prose config url"         0 "$(run_case "$(j_bash 'git commit -m "docs: update config url notes"')" "ANTHROPIC_BASE_URL=$GLM_URL")"
assert_rc "glm env-prefix push (pinned limitation)" 0 "$(run_case "$(j_bash 'FOO=1 git push')" "ANTHROPIC_BASE_URL=$GLM_URL")"

# --- Edge cases: jq availability + malformed input ---
assert_rc "glm jq missing fails closed"  2 "$(run_case_no_jq "$(j_bash 'git status')")"
assert_rc "native worker jq missing ALSO fails closed (round-3 [codex-1] reversal)" 2 "$(run_case_no_jq_native "$(j_bash 'git status')")"
assert_rc "glm malformed JSON allows (documented)" 0 "$(run_case '{not json' "ANTHROPIC_BASE_URL=$GLM_URL")"

# --- Escape hatch (expect rc=0 on an otherwise-blocked command) ---
assert_rc "bypass GLM_EXTERNAL_WRITES_OK" 0 "$(run_case "$(j_bash 'git push')" "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_EXTERNAL_WRITES_OK=1")"

# --- grant-consult cases (escalation channel, spec G1-G12 + plan G13 F9 fast-path) ---
GRANT_DIR=""
mk_grants() { GRANT_DIR=$(mktemp -d); printf '%s\n' "$@" > "$GRANT_DIR/grants.jsonl"; }
# run a cmd on-lane with GLM_SESSION_DIR pointed at the fixture grants dir
run_case_grant() {
    local input="$1"; shift
    printf '%s' "$input" | env -u ANTHROPIC_BASE_URL -u GLM_EXTERNAL_WRITES_OK \
        "ANTHROPIC_BASE_URL=$GLM_URL" "GLM_SESSION_DIR=$GRANT_DIR" "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}
# count consumption lines for a grant_id in the fixture. grep -c prints "0" AND
# exits 1 on zero matches, so a `|| echo 0` would double-emit "0\n0" and break
# the expect-0 asserts (G13); swallow grep's exit and default a missing file to 0.
consumptions() { local c; c=$(grep -c "\"type\":\"consumption\",\"grant_id\":\"$1\"" "$GRANT_DIR/grants.jsonl" 2>/dev/null || true); echo "${c:-0}"; }

NOW_FAR="2999-01-01T00:00:00Z"; NOW_PAST="2000-01-01T00:00:00Z"
GH_API_GET='gh[[:space:]]+api[[:space:]]+repos/o/r([[:space:]]|$)'
GP_PUSH='git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+push([[:space:]]|$)'

# G1 valid gh-api-GET grant honored + 1 consumption
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g1\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G1 gh api GET granted"        0 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
assert_rc "G1 consumption appended"      1 "$(consumptions g1)"
# G2 expired
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g2\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_PAST\",\"max_uses\":3}"
assert_rc "G2 expired refused"           2 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
# G3 exhausted (max_uses:1 + 1 prior consumption)
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g3\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":1}" '{"type":"consumption","grant_id":"g3","ts":"2026-01-01T00:00:00Z"}'
assert_rc "G3 exhausted refused"         2 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
# G4 only-malformed line
mk_grants '{ not json'
assert_rc "G4 malformed only fails closed" 2 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
# G5 no GLM_SESSION_DIR at all -> unchanged deny
assert_rc "G5 no session dir unchanged"  2 "$(run_case "$(j_bash 'git push origin x')" "ANTHROPIC_BASE_URL=$GLM_URL")"
# G6 compound smuggle: grant covers gh api GET only
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g6\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G6 compound smuggle blocked"  2 "$(run_case_grant "$(j_bash 'gh api repos/o/r && gh pr merge 1')")"
# G7 valid git-push grant honored
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g7\",\"arm\":\"git-push\",\"pattern\":\"$GP_PUSH\",\"shape\":\"write\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G7 git-push granted"          0 "$(run_case_grant "$(j_bash 'git push origin x')")"
assert_rc "G7 consumption appended"      1 "$(consumptions g7)"
# G8 two honored calls, max_uses:2 -> both allowed, original line intact, 2 consumptions
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g8\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":2}"
ORIG_G8=$(head -1 "$GRANT_DIR/grants.jsonl")
assert_rc "G8 call 1"                    0 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
assert_rc "G8 call 2"                    0 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
assert_rc "G8 original grant byte-unchanged" 0 "$([ "$(head -1 "$GRANT_DIR/grants.jsonl")" = "$ORIG_G8" ] && echo 0 || echo 1)"
assert_rc "G8 two consumptions"          2 "$(consumptions g8)"
# G9 off-lane: grant never read. Feed stdin via a herestring, NOT a pipe — off
# lane the hook exits at the ANTHROPIC_BASE_URL check before reading stdin, so a
# pipe writer would take SIGPIPE (rc 141 under pipefail); a herestring has no
# live writer to signal.
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g9\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
G9_IN="$(j_bash 'gh api repos/o/r')"
assert_rc "G9 off-lane grant ignored"    0 "$(env -u ANTHROPIC_BASE_URL "GLM_SESSION_DIR=$GRANT_DIR" bash "$HOOK" >/dev/null 2>&1 <<<"$G9_IN"; echo $?)"
# G10 overlap grant does NOT credit sibling merge (single-alternation, F1)
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g10\",\"arm\":\"gh\",\"pattern\":\"gh[[:space:]]+pr[[:space:]]+view([[:space:]]|$)\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G10 overlap no-credit"        2 "$(run_case_grant "$(j_bash 'gh pr view 1 && gh pr merge 1')")"
# G11 one malformed + one valid covering grant -> honored (F7)
mk_grants '{ bad line' "{\"type\":\"grant\",\"grant_id\":\"g11\",\"arm\":\"gh\",\"pattern\":\"$GH_API_GET\",\"shape\":\"read\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G11 bad line skipped, valid honored" 0 "$(run_case_grant "$(j_bash 'gh api repos/o/r')")"
assert_rc "G11 consumption appended"     1 "$(consumptions g11)"
# G12 git-push grant whose pattern matches only benign git status (no push) -> REJECTED by gate (F8)
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g12\",\"arm\":\"git-push\",\"pattern\":\"git[[:space:]]+status\",\"shape\":\"write\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G12 non-push-anchored rejected" 2 "$(run_case_grant "$(j_bash 'git status && git push origin x')")"
# G13 F9 fast path: builtin-allowed command + valid UNRELATED grant present -> rc=0 AND grant neither consulted nor consumed
mk_grants "{\"type\":\"grant\",\"grant_id\":\"g13\",\"arm\":\"git-push\",\"pattern\":\"$GP_PUSH\",\"shape\":\"write\",\"expires_at\":\"$NOW_FAR\",\"max_uses\":3}"
assert_rc "G13 builtin-allowed fast path"       0 "$(run_case_grant "$(j_bash 'gh pr view 1')")"
assert_rc "G13 fast path did not consume grant" 0 "$(consumptions g13)"

# --- HIMMEL-2085: hook-integrity pin-dir write-fence (worker-ness, not lane) --
# The pin-dir class is the ONLY class in this file gated on worker_lane
# (glm_lane OR HIMMEL_WORKER=1) instead of glm_lane alone — see the header's
# HIMMEL-2085 GENERALIZATION note. These cases pin: (a) a headed/off-lane
# session stays unaffected, (b) a native (non-GLM) dispatched worker is now
# denied — closing the exact gap the ticket was filed for, (c) GLM-lane
# behavior for this NEW class is the same deny, (d) the documented bypass
# works, and (e) a native worker gets ONLY this class, not the rest of the
# GLM-specific enforcement (scope boundary, not a regression).
PIN_FIXTURE=$(mktemp -d -t hook-integrity.XXXXXX)
PIN_FIXTURE_NATIVE=$(native_dir "$PIN_FIXTURE")
PIN_WRITE_CMD="echo pwned > $PIN_FIXTURE/forged-session.json"
PIN_WRITE_CMD_NATIVE="echo pwned > $PIN_FIXTURE_NATIVE/forged-session.json"

assert_rc "pin-dir write off-lane (headed session, unaffected)" 0 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD")" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

assert_rc "pin-dir write denied for a native dispatched worker (HIMMEL-2085)" 2 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via native Windows-style path spelling" 2 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD_NATIVE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE_NATIVE")"
assert_rc "pin-dir write denied via PowerShell (native worker)" 2 \
    "$(run_case "$(j_pwsh "Set-Content -Path $PIN_FIXTURE/x.json -Value pwned")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# codex-1 (pr-check critic-panel round 4): the outer-command checks above scan
# only tool_input.command text, so `bash script.sh` (script.sh containing the
# forge payload) passed every check while the SCRIPT still forged the pin.
# Absolute script paths keep this hermetic regardless of the test runner's cwd.
PIN_SCRIPT_DIR=$(mktemp -d -t pin-script.XXXXXX)
PIN_SCRIPT_FORGE="$PIN_SCRIPT_DIR/forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SCRIPT_FORGE"
PIN_SCRIPT_BENIGN="$PIN_SCRIPT_DIR/benign.sh"
printf 'echo hello world\n' > "$PIN_SCRIPT_BENIGN"
assert_rc "pin-dir write denied via invoked script content (codex-1 round 4)" 2 \
    "$(run_case "$(j_bash "bash $PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via dot-sourced script content (codex-1 round 4)" 2 \
    "$(run_case "$(j_bash ". $PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "benign invoked script allowed (round-4 fix, no false positive)" 0 \
    "$(run_case "$(j_bash "bash $PIN_SCRIPT_BENIGN")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir invoked-script check skips a nonexistent path (fail-open on non-evaluable)" 0 \
    "$(run_case "$(j_bash 'bash /nonexistent/path/for/this/test.sh')" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# codex-1/codex-2 (pr-check critic-panel round 5): the round-4 extraction above
# only matched an interpreter word immediately followed by whitespace then an
# UNQUOTED path -- direct execution (no interpreter word at all), a dash-option
# before the path, a quoted path, and the `node` interpreter (an explicitly
# documented dispatched-worker grant, Bash(node *), alongside Bash(bash *))
# all bypassed it.
PIN_SCRIPT_FORGE_JS="$PIN_SCRIPT_DIR/forge.js"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SCRIPT_FORGE_JS"
assert_rc "pin-dir write denied via direct script execution, no interpreter word (codex-1 round 5)" 2 \
    "$(run_case "$(j_bash "$PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via bash -x with a dash option before the path (codex-1 round 5)" 2 \
    "$(run_case "$(j_bash "bash -x $PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via a quoted script path (codex-1 round 5)" 2 \
    "$(run_case "$(j_bash "bash \"$PIN_SCRIPT_FORGE\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via the node interpreter (codex-2 round 5)" 2 \
    "$(run_case "$(j_bash "node $PIN_SCRIPT_FORGE_JS")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "benign direct-exec script still allowed (round-5 fix, no false positive)" 0 \
    "$(run_case "$(j_bash "$PIN_SCRIPT_BENIGN")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# codex-2/codex-3 (pr-check critic-panel round 5, fresh pass AFTER the fix
# above landed): the regex-patch extraction still truncated a quoted path
# containing a SPACE to its first whitespace-delimited token, and matched an
# absolute/path-qualified interpreter (`/bin/bash forge.sh`) as a direct-exec
# target on the INTERPRETER itself rather than extracting its script argument.
# Root-caused with a quote-aware tokenizer (this file's own commentary above
# the awk block) instead of a third regex patch.
PIN_SCRIPT_SPACE_DIR=$(mktemp -d -t "pin-space.XXXXXX")
PIN_SCRIPT_SPACE_FORGE="$PIN_SCRIPT_SPACE_DIR/my forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SCRIPT_SPACE_FORGE"
assert_rc "pin-dir write denied via a quoted script path containing a space (codex-2 round 5 re-review)" 2 \
    "$(run_case "$(j_bash "bash \"$PIN_SCRIPT_SPACE_FORGE\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
PIN_BASH_ABS=$(command -v bash)
if [ -n "$PIN_BASH_ABS" ]; then
    assert_rc "pin-dir write denied via an absolute interpreter path (codex-3 round 5 re-review)" 2 \
        "$(run_case "$(j_bash "$PIN_BASH_ABS $PIN_SCRIPT_FORGE")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
fi

# codex-2 (pr-check critic-panel round 5, re-review pass 2): a `cd <dir> &&`
# segment ahead of the script invocation must shift the resolution cwd for
# every later segment -- the awk tokenizer used a STATIC tool_cwd and missed
# a script the command actually ran from a subdirectory. $PIN_SCRIPT_DIR is
# absolute, so `cd`-ing there keeps this hermetic regardless of the test
# runner's own cwd; `forge.sh` is deliberately RELATIVE here to exercise the
# post-cd resolution.
assert_rc "pin-dir write denied via cd-then-invoke with a relative script path (codex-2 round 5 re-review pass 2)" 2 \
    "$(run_case "$(j_bash "cd $PIN_SCRIPT_DIR && bash forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2200: three round-5 re-review residuals in the awk tokenizer,
# root-caused with a single-pass quote/escape-aware scanner (see the file's
# own commentary above the awk block) instead of another regex/split patch.
# codex-1: a `;` inside a QUOTED script path used to split the command
# mid-token because segment splitting ran BEFORE quote-aware tokenization.
PIN_SCRIPT_SEMI_FORGE="$PIN_SCRIPT_DIR/forge;payload.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SCRIPT_SEMI_FORGE"
assert_rc "pin-dir write denied via a semicolon inside a quoted script path (HIMMEL-2200 codex-1)" 2 \
    "$(run_case "$(j_bash "bash \"$PIN_SCRIPT_SEMI_FORGE\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# codex-2: a backslash-escaped space in an UNQUOTED path is a legitimate shell
# escaping form; the old tokenizer had no backslash handling at all and would
# truncate at the first (apparently unescaped) space. Reuses the existing
# space-containing fixture file, referenced via its escaped-space spelling
# instead of quotes.
PIN_ESCAPED_SPACE_CMD="bash ${PIN_SCRIPT_SPACE_DIR}/my\\ forge.sh"
assert_rc "pin-dir write denied via a backslash-escaped space in an unquoted script path (HIMMEL-2200 codex-2)" 2 \
    "$(run_case "$(j_bash "$PIN_ESCAPED_SPACE_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# codex-3: the round-5 cd-tracking advanced the modeled cwd unconditionally,
# even when the cd target does not exist on disk. A real shell's failed `cd`
# leaves it in the ORIGINAL directory, so `cd <nonexistent>; bash forge.sh`
# still executes forge.sh from tool_cwd -- pre-fix, the unconditional advance
# resolved forge.sh against the (nonexistent) target instead, the file check
# skipped a path that doesn't exist, and the pin payload was missed entirely
# (a false ALLOW). tool_cwd is set to $PIN_SCRIPT_DIR (which holds the pin
# payload forge.sh from the codex-1 round-4 fixture above) via an explicit
# tool_input.cwd, so a correct fix must still catch it after the failed cd.
PIN_CD_FAIL_JSON=$(jq -n --arg cmd "cd /this/definitely/does/not/exist/himmel-2200; bash forge.sh" \
    --arg cwd "$PIN_SCRIPT_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied because a failed cd must not advance the modeled cwd (HIMMEL-2200 codex-3)" 2 \
    "$(run_case "$PIN_CD_FAIL_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2200 pr-check critic-panel re-review (codex-1): the backslash
# handling added above was itself too broad -- it fired unconditionally even
# when the mediated tool is PowerShell (backslash is an ordinary literal
# character there, never an escape), stripping the separators out of a native
# Windows path and missing the real script. It also over-escaped inside a
# BASH double-quoted string: real bash only treats `\$` `` \` `` `\"` `\\` as
# special there, so a backslash before an ordinary character (the `U` in
# `C:\Users`) must stay literal, both characters kept.
PIN_SCRIPT_DIR_NATIVE=$(native_dir "$PIN_SCRIPT_DIR")
# These two rows exercise a native Windows backslash path and only hold a
# premise under a real Windows/MSYS host. native_dir()'s `pwd -W` is
# MSYS-only; on POSIX (this box included) it always falls through to
# `pwd -P`, so PIN_SCRIPT_DIR_NATIVE is a plain POSIX path here, the
# backslash below is NOT a path separator, and the constructed command names
# a different, nonexistent file. The guard correctly does not deny that --
# rc=0 is right, there is no guard gap. Same platform predicate + SKIP voice
# as scripts/luna/test-qmd-cadence.sh and scripts/graphify/test-ggs-cadence.sh.
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*)
        # PowerShell, UNQUOTED native path: pwsh dialect must disable
        # backslash-escape handling entirely, so the path resolves exactly as
        # spelled.
        assert_rc "pin-dir write denied via a native Windows backslash path under PowerShell, unquoted (HIMMEL-2200 codex-1)" 2 \
            "$(run_case "$(j_pwsh "bash ${PIN_SCRIPT_DIR_NATIVE}\\forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
        # Bash, DOUBLE-QUOTED native path: a backslash before an ordinary
        # character inside double quotes is not one of bash's four real
        # escape targets and must stay literal (both characters kept), not be
        # silently dropped.
        assert_rc "pin-dir write denied via a native Windows backslash path in a bash double-quoted string (HIMMEL-2200 codex-1)" 2 \
            "$(run_case "$(j_bash "bash \"${PIN_SCRIPT_DIR_NATIVE}\\forge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
        ;;
    *)
        skip_case "pin-dir write denied via a native Windows backslash path under PowerShell, unquoted (HIMMEL-2200 codex-1)" \
            "no Windows/MSYS host here — native_dir()'s pwd -W is MSYS-only, so the backslash path is unreachable and rc=0 is already correct"
        skip_case "pin-dir write denied via a native Windows backslash path in a bash double-quoted string (HIMMEL-2200 codex-1)" \
            "no Windows/MSYS host here — native_dir()'s pwd -W is MSYS-only, so the backslash path is unreachable and rc=0 is already correct"
        ;;
esac

# --- HIMMEL-2200 pr-check critic-panel re-review ROUND 3 (codex-1): the
# cd-existence `test -d` probe (round 2's fix, since replaced) reflected
# filesystem state at HOOK-SCAN time, before any segment of the multi-segment
# command has executed -- a real, concrete TOCTOU. `rmdir real; cd real; bash
# forge.sh`: at scan time `real` genuinely exists, so a scan-time probe says
# "cd succeeds" and follows it -- but the real shell's `rmdir` removes `real`
# FIRST, so the real `cd` then FAILS and the shell stays in the ORIGINAL
# directory, exactly where the real forge.sh sits, unscanned by a
# probe-and-commit design. Root-caused by replacing the single tracked cwd
# with a small FORKED set of candidates: every cd keeps the pre-cd candidate
# (models "cd fails") AND adds the post-cd candidate (models "cd succeeds"),
# so whichever branch the real shell takes, one candidate matches it. This
# fixture creates `real` as a genuinely-existing subdirectory (so the retired
# test-d probe would have advanced into it) while the real payload sits at
# the ORIGINAL cwd -- the fork model's "stays put" candidate must still find
# it.
PIN_TOCTOU_DIR=$(mktemp -d -t pin-toctou.XXXXXX)
PIN_TOCTOU_FORGE="$PIN_TOCTOU_DIR/forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_TOCTOU_FORGE"
mkdir -p "$PIN_TOCTOU_DIR/real"
PIN_TOCTOU_JSON=$(jq -n --arg cmd "rmdir real; cd real; bash forge.sh" --arg cwd "$PIN_TOCTOU_DIR" \
    '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied via rmdir-then-cd TOCTOU on an existing target (HIMMEL-2200 pr-check panel round 3 codex-1)" 2 \
    "$(run_case "$PIN_TOCTOU_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2200 pr-check critic-panel re-review ROUND 5 (codex-1): the
# candidate-set fork model (round 4) capped growth at MAXCAND by keeping the
# FIRST MAXCAND entries of the de-duped set -- but that set is built
# unchanged-block-first, advanced-block-second, so a plain first-N truncation
# systematically dropped EVERY "cd succeeds" candidate once enough distinct
# cd targets accumulated (candidates roughly double per distinct cd; MAXCAND=32
# means the 6th distinct cd is the first to overflow and get truncated),
# silently reopening the exact fork-model gap round 4 exists to close. Fixed
# by truncating BALANCED -- up to half the cap from each block -- so a real
# execution path can never be dropped just because it was pushed second. This
# fixture chains 6 distinct cd targets, with the real payload only at the
# FINAL (6th) location -- exactly the shape that overflowed the naive
# first-N truncation.
PIN_CHAIN_DIR=$(mktemp -d -t pin-chain.XXXXXX)
for _n in 1 2 3 4 5; do mkdir -p "$PIN_CHAIN_DIR/d$_n"; done
mkdir -p "$PIN_CHAIN_DIR/d5/d6"
PIN_CHAIN_FORGE="$PIN_CHAIN_DIR/d5/d6/forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_CHAIN_FORGE"
PIN_CHAIN_JSON=$(jq -n --arg cmd "cd $PIN_CHAIN_DIR/d1; cd ../d2; cd ../d3; cd ../d4; cd ../d5; cd d6; bash forge.sh" \
    --arg cwd "$PIN_CHAIN_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied via 6 distinct cds overflowing MAXCAND (HIMMEL-2200 pr-check panel round 5 codex-1)" 2 \
    "$(run_case "$PIN_CHAIN_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2214: `&&`/`||` short-circuit truthiness. The tokenizer segments
# on a bare `;`/`&`/`|` and has no notion of AND/OR short-circuit, so it models
# `false && cd existing` as if the cd ran while a real shell skips it and stays
# put. Against the pre-HIMMEL-2200 tokenizer (single modeled cwd, advanced
# unconditionally) that was a real fail-OPEN: the model moved into `existing`
# and never scanned the forge.sh actually sitting at the ORIGINAL cwd. The
# HIMMEL-2200 fork model SUBSUMES it -- a cd forks rather than replaces, and a
# cd skipped by short-circuit is indistinguishable from a cd that ran and
# failed, which is exactly the preserved unchanged candidate. Verified
# both-direction against `git show 2bab2305:scripts/hooks/block-glm-external-writes.sh`
# (ALLOWS this shape) vs today (DENIES it); this case pins the behaviour so a
# future narrowing of the fork model cannot silently reopen it.
PIN_SHORTCIRCUIT_DIR=$(mktemp -d -t pin-shortcircuit.XXXXXX)
mkdir -p "$PIN_SHORTCIRCUIT_DIR/existing"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SHORTCIRCUIT_DIR/forge.sh"
PIN_SHORTCIRCUIT_JSON=$(jq -n --arg cmd 'false && cd existing; bash forge.sh' \
    --arg cwd "$PIN_SHORTCIRCUIT_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied when a short-circuited cd never runs (HIMMEL-2214, subsumed by the fork model)" 2 \
    "$(run_case "$PIN_SHORTCIRCUIT_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Negative control for the case above: identical command shape, benign script
# content. A rc=2 here would mean the case above proves nothing.
PIN_SHORTCIRCUIT_OK_DIR=$(mktemp -d -t pin-shortcircuit-ok.XXXXXX)
mkdir -p "$PIN_SHORTCIRCUIT_OK_DIR/existing"
printf 'echo hello world\n' > "$PIN_SHORTCIRCUIT_OK_DIR/forge.sh"
PIN_SHORTCIRCUIT_OK_JSON=$(jq -n --arg cmd 'false && cd existing; bash forge.sh' \
    --arg cwd "$PIN_SHORTCIRCUIT_OK_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "short-circuit shape with benign script content still allowed (HIMMEL-2214 negative control)" 0 \
    "$(run_case "$PIN_SHORTCIRCUIT_OK_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2218 [codex-2]: PowerShell's escape character is the BACKTICK, and
# the tokenizer modelled no PowerShell escape at all -- so a backtick-escaped
# separator inside an UNQUOTED PowerShell path was treated as a real segment
# boundary, truncating the token to a path that matches no file, and the real
# script went unscanned (fail-OPEN). Reuses the `forge;payload.sh` fixture: the
# quoted spelling of this same path is the HIMMEL-2200 codex-1 case above, so
# the pair isolates dialect escape handling from quote handling.
# A literal backtick, assembled once so the fixtures below stay readable.
PIN_BT='`'
PIN_PWSH_ESCSEP_CMD="bash ${PIN_SCRIPT_DIR_NATIVE}/forge${PIN_BT};payload.sh"
assert_rc "pin-dir write denied via a backtick-escaped separator in an unquoted PowerShell path (HIMMEL-2218 codex-2)" 2 \
    "$(run_case "$(j_pwsh "$PIN_PWSH_ESCSEP_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2218 [codex-3]: a bash backslash-newline (or PowerShell
# backtick-newline) line continuation joins two PHYSICAL lines into ONE logical
# command before the real shell parses it. Each awk input record is one
# physical line, so a script path split across a continuation used to extract
# as two unrelated fragments and the real file was never scanned (fail-OPEN).
# `for` + `ge.sh` rejoins to the existing $PIN_SCRIPT_DIR/forge.sh fixture.
PIN_CONT_CMD=$(printf 'bash %s/for\\\nge.sh' "$PIN_SCRIPT_DIR")
assert_rc "pin-dir write denied via a bash backslash-newline line continuation (HIMMEL-2218 codex-3)" 2 \
    "$(run_case "$(j_bash "$PIN_CONT_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
PIN_PWSH_CONT_CMD=$(printf 'bash %s/for%s\nge.sh' "$PIN_SCRIPT_DIR" "$PIN_BT")
assert_rc "pin-dir write denied via a PowerShell backtick-newline line continuation (HIMMEL-2218 codex-3)" 2 \
    "$(run_case "$(j_pwsh "$PIN_PWSH_CONT_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Positive control on the odd/even rule that decides a continuation: TWO
# trailing backslashes are an escaped literal backslash, so the line really
# ends and nothing joins -- the resulting `.../for\` path matches no file.
# Joining here would be over-eager, not fail-closed, so this must stay rc=0.
PIN_CONT_EVEN_CMD=$(printf 'bash %s/for\\\\\nge.sh' "$PIN_SCRIPT_DIR")
assert_rc "an even run of trailing backslashes is not a line continuation (HIMMEL-2218 codex-3 control)" 0 \
    "$(run_case "$(j_bash "$PIN_CONT_EVEN_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2218 [codex-3], CodeRabbit review on PR #2005: CRLF line endings.
# AWK splits records on \n, so a command submitted with CRLF keeps the \r at
# the END of every record -- which means the escape character continuing the
# line is no longer the LAST character and the continuation join never fires.
# Verified a live fail-OPEN on BOTH dialects before the fix (rc=0 on the branch
# head that added the join, rc=2 after stripping one terminal \r). The strip
# happens once at the scanner entry point, so it also keeps a stray \r out of
# every token, rather than being patched per branch.
PIN_CR=$(printf '\r')
PIN_CRLF_CONT_CMD=$(printf 'bash %s/for\\%s\nge.sh' "$PIN_SCRIPT_DIR" "$PIN_CR")
assert_rc "pin-dir write denied via a bash line continuation with CRLF endings (HIMMEL-2218 codex-3, PR #2005 CodeRabbit)" 2 \
    "$(run_case "$(j_bash "$PIN_CRLF_CONT_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
PIN_PWSH_CRLF_CONT_CMD=$(printf 'bash %s/for%s%s\nge.sh' "$PIN_SCRIPT_DIR_NATIVE" "$PIN_BT" "$PIN_CR")
assert_rc "pin-dir write denied via a PowerShell line continuation with CRLF endings (HIMMEL-2218 codex-3, PR #2005 CodeRabbit)" 2 \
    "$(run_case "$(j_pwsh "$PIN_PWSH_CRLF_CONT_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Negative control: the same CRLF continuation shape resolving to a BENIGN
# script must stay rc=0, so the two cases above are the payload being caught
# and not the \r strip turning into a blanket deny on any CRLF command.
PIN_CRLF_BENIGN_CMD=$(printf 'bash %s/beni\\%s\ngn.sh' "$PIN_SCRIPT_DIR" "$PIN_CR")
assert_rc "CRLF line continuation to a benign script still allowed (HIMMEL-2218 codex-3 control)" 0 \
    "$(run_case "$(j_bash "$PIN_CRLF_BENIGN_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2218 expansion (console ruling, same scanner region and the same
# fail-open direction as codex-2): PowerShell embeds a literal quote inside a
# single-quoted string by DOUBLING it, so the doubled pair is one literal
# character in the token -- not a close followed by a reopen. Reading it as
# close-then-reopen dropped the quote character and produced a path matching no
# file. Bash has no doubling rule (two adjacent single-quoted strings really do
# concatenate), so the fix is pwsh-gated and the bash control below pins that.
PIN_SQ_FORGE="$PIN_SCRIPT_DIR/it's forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_SQ_FORGE"
PIN_PWSH_SQ_CMD="bash '${PIN_SCRIPT_DIR_NATIVE}/it''s forge.sh'"
assert_rc "pin-dir write denied via a PowerShell doubled single-quote in a script path (HIMMEL-2218 expansion)" 2 \
    "$(run_case "$(j_pwsh "$PIN_PWSH_SQ_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Bash control: the SAME text under bash is two adjacent quoted strings that
# concatenate to `its forge.sh`, which is not a file -- so bash semantics must
# stay unchanged (rc=0). A rc=2 here would mean the pwsh rule leaked dialects.
PIN_BASH_SQ_CMD="bash '${PIN_SCRIPT_DIR}/it''s forge.sh'"
assert_rc "bash adjacent-quote concatenation semantics unchanged by the pwsh doubling rule (HIMMEL-2218 expansion control)" 0 \
    "$(run_case "$(j_bash "$PIN_BASH_SQ_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2218 [codex-2], pr-check panel ROUND 2: modelling only the
# self-escaping trio (backtick, dollar, double-quote) was not enough. In
# PowerShell the backtick ALWAYS escapes: `n `t `r `a `b `f `v stand for control
# characters, `0 for NUL, and for ANY other character the backtick is simply
# DROPPED. So `xforge.sh really is xforge.sh -- an ordinary command with no
# exotic filename at all -- and the old model produced a literal-backtick path
# that matched no file, leaving the script unscanned. A fail-OPEN, verified
# rc=0 before / rc=2 after.
PIN_PWSH_ESCX_FORGE="$PIN_SCRIPT_DIR/xforge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_PWSH_ESCX_FORGE"
assert_rc "pin-dir write denied when a PowerShell unrecognized escape drops the backtick (HIMMEL-2218 codex-2, panel round 2)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}xforge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Negative control: same escape shape, benign target — must stay allowed, or
# the case above would prove only that PowerShell commands are denied wholesale.
PIN_PWSH_ESCX_BENIGN="$PIN_SCRIPT_DIR/xok.sh"
printf 'echo hello world\n' > "$PIN_PWSH_ESCX_BENIGN"
assert_rc "PowerShell unrecognized-escape path to a benign script still allowed (HIMMEL-2218 codex-2 control)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}xok.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# And a RECOGNIZED sequence must resolve to its control character, not to the
# letter: `t is a TAB, so this fixture is only reachable if the resolver runs.
PIN_TAB=$(printf '\t')
PIN_PWSH_TAB_FORGE="$PIN_SCRIPT_DIR/for${PIN_TAB}ge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_PWSH_TAB_FORGE"
assert_rc "pin-dir write denied when a PowerShell \`t resolves to a real tab in the path (HIMMEL-2218 codex-2, panel round 2)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/for${PIN_BT}tge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2218 [codex-1], pr-check panel ROUND 3: PowerShell's
# VARIABLE-LENGTH escape, `u{...}. Expectations here are not inferred from
# docs -- they were taken from a real PowerShell 7.6.5, which resolves
# "`u{66}orge" AND bare `u{66}orge alike to forge. So `u{66}orge.sh genuinely
# executes forge.sh, and a model that stops at one-character escapes looks for
# a literal u{66}orge.sh and scans nothing. This is the encoding that matters
# most of the escape family: a worker can apply it to ANY path, needing no
# unusual filename at all.
assert_rc "pin-dir write denied via a PowerShell \`u{...} escape in a quoted path (HIMMEL-2218 codex-1, panel round 3)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}u{66}orge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via a PowerShell \`u{...} escape in a BARE path (HIMMEL-2218 codex-1, panel round 3)" 2 \
    "$(run_case "$(j_pwsh "bash ${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}u{66}orge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Control: the same encoding resolving to the BENIGN script must stay allowed
# (0x62 = b, so this is benign.sh), or the two cases above would only prove
# that any command containing a backtick is denied.
assert_rc "a \`u{...} escape resolving to a benign script is still allowed (HIMMEL-2218 codex-1 control)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}u{62}enign.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Control: a MALFORMED sequence is not a unicode escape at all and must not be
# resolved as one -- otherwise the parser would invent paths on any `u it sees.
assert_rc "a malformed \`u{zz} is not treated as a unicode escape (HIMMEL-2218 codex-1 control)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_SCRIPT_DIR_NATIVE}/${PIN_BT}u{zz}orge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- COMPLETENESS BY ENUMERATION (operator directive, PR #2005 round 3).
# The PowerShell backtick grammar is FINITE, so the resolver is closed by
# enumerating it rather than by waiting to see whether another review round
# finds a hole. Every expectation below was read off a real PowerShell 7.6.5:
#
#   `n=10  `t=9  `r=13  `a=7  `b=8  `f=12  `v=11  `0=0     (control sequences)
#   `$=$   `"="  ``=`                                       (self-escaping trio)
#   `u{66}=f                                                (variable length)
#   `x=x                                                    (default: drop the backtick)
#
# NOT complete after all, and worth saying so plainly rather than leaving the
# claim standing: the round-5 panel found `e (ESC, 0x1B) missing from the list
# above. The enumeration was written out by hand instead of derived from
# about_Special_Characters, so it reproduced the author-s blind spot -- the
# exact failure mode enumeration was supposed to prevent. `e is deferred to
# HIMMEL-2236 with the >255-codepoint issue; a fix there should extend these
# cases from the language reference, not from another hand-written list.
#
# One case per form. The control sequences are asserted in the NEGATIVE
# direction, which is the direction that actually matters and needs no exotic
# filename: `n must NOT degrade to the letter n. Each fixture below is a REAL
# pin-forging payload named for<letter>ge.sh, so a resolver that collapsed the
# sequence to its letter would resolve onto the payload and DENY -- these cases
# pass only because the sequence resolved to a control character instead.
PIN_ESC_DIR=$(mktemp -d -t pin-escgrammar.XXXXXX)
PIN_ESC_DIR_NATIVE=$(native_dir "$PIN_ESC_DIR")
for _esc_letter in n t r a b f v 0; do
    printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_ESC_DIR/for${_esc_letter}ge.sh"
done
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_ESC_DIR/forge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_ESC_DIR/for${PIN_BT}ge.sh"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_ESC_DIR/for\$ge.sh"

for _esc_letter in n t r a b f v 0; do
    assert_rc "PowerShell \`$_esc_letter resolves to its control character, not the letter (escape-grammar enumeration)" 0 \
        "$(run_case "$(j_pwsh "bash \"${PIN_ESC_DIR_NATIVE}/for${PIN_BT}${_esc_letter}ge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
done

# Self-escaping trio. `` and `$ resolve to characters that ARE legal in a
# filename, so these two assert the POSITIVE direction: the payload is found.
assert_rc "pin-dir write denied via a PowerShell \`\` escape (literal backtick in the path)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_ESC_DIR_NATIVE}/for${PIN_BT}${PIN_BT}ge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
assert_rc "pin-dir write denied via a PowerShell \`\$ escape (literal dollar in the path)" 2 \
    "$(run_case "$(j_pwsh "bash \"${PIN_ESC_DIR_NATIVE}/for${PIN_BT}\$ge.sh\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# `" cannot be asserted positively -- a double quote is not a legal NTFS
# filename character -- so assert what actually matters: it must NOT terminate
# the string. Real PowerShell reads this whole thing as ONE argument
# (.../forge.sh";echo hi), which is not a file, so the command is allowed. A
# tokenizer that let `" close the quote would see `bash <dir>/forge.sh` as its
# own segment and DENY. This case passes only when `" is escaped correctly.
assert_rc "a PowerShell \`\" escape does not terminate the quoted path (escape-grammar enumeration)" 0 \
    "$(run_case "$(j_pwsh "bash \"${PIN_ESC_DIR_NATIVE}/forge.sh${PIN_BT}\";echo hi\"")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- pr-check panel ROUND 4 [codex-2]: the NUL filter has to sit on the
# EMITTED path, not on the token. A NUL can also arrive through the modeled
# CWD -- `cd path`0suffix` puts one in a candidate directory -- and the
# token-only test let that through, whereupon the bash reader silently dropped
# the NUL and spliced the candidate into a REAL directory, denying a command
# PowerShell never pointed there. Same false-positive shape as the `0 bug the
# grammar enumeration caught, one layer further in.
PIN_CDNUL_DIR=$(mktemp -d -t pin-cdnul.XXXXXX)
PIN_CDNUL_DIR_NATIVE=$(native_dir "$PIN_CDNUL_DIR")
mkdir -p "$PIN_CDNUL_DIR/sub"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_CDNUL_DIR/sub/forge.sh"
assert_rc "a NUL reaching the modeled cwd is not repaired into a real directory (panel round 4 codex-2)" 0 \
    "$(run_case "$(j_pwsh "cd ${PIN_CDNUL_DIR_NATIVE}/su${PIN_BT}0b; bash forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
# Control: the identical chain through the REAL directory must still deny, or
# the case above would pass merely because cd-tracking stopped working.
assert_rc "the same cd chain through the real directory still denies (panel round 4 codex-2 control)" 2 \
    "$(run_case "$(j_pwsh "cd ${PIN_CDNUL_DIR_NATIVE}/sub; bash forge.sh")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- pr-check panel ROUND 2 [codex-1], adjudicated DISPROVED as a bypass but
# pinned here so it stays disproved. The claim was that the continuation join
# can replace a real script path and let a write through. For any command a
# shell will actually EXECUTE, the join preserves detection: the interpreter and
# script tokens sit on the first physical line and survive the join, and a quote
# that closes on a later line still ends its token before the next segment. The
# one shape whose modelling the join does change is a command with an
# UNTERMINATED quote — which bash refuses outright ("unexpected EOF while
# looking for matching") and therefore never runs, so there is no write to fence.
# These two cases are the executable shapes; a real regression would flip them.
PIN_JOIN_ARG_CMD=$(printf "bash %s/forge.sh 'arg\\\\\nmore'" "$PIN_SCRIPT_DIR")
assert_rc "a continuation inside a quoted ARGUMENT does not hide the script (panel round 2 codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_JOIN_ARG_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"
PIN_JOIN_SEG_CMD=$(printf "bash '%s/a\\\\\nb'; bash %s/forge.sh" "$PIN_SCRIPT_DIR" "$PIN_SCRIPT_DIR")
assert_rc "a closed quote across a continuation still ends its segment (panel round 2 codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_JOIN_SEG_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# --- HIMMEL-2225 (pr-check critic-panel round 6 [codex-1]): the candidate set
# used to be built as an unchanged BLOCK followed by an advanced BLOCK, so
# once MAXCAND was reached the first-N truncation dropped the advanced block
# wholesale -- i.e. every "the latest cd succeeded, but an earlier one did not"
# candidate vanished at once. The round-5 protected index-1 invariant covers
# only the all-success chain, so a payload reachable ONLY on a mixed
# success/failure path was a fail-OPEN. Fixed by interleaving the two branches
# per candidate, so truncation degrades both evenly.
# Fixture: six distinct RELATIVE cd targets (the set doubles per target, so the
# 6th overflows MAXCAND=32) where `d5` does NOT exist and the payload sits at
# d1/d2/d3/d4/d6 -- reachable only on the "every cd but d5 succeeded" branch,
# which is the candidate the old block layout truncated away.
PIN_INTERLEAVE_DIR=$(mktemp -d -t pin-interleave.XXXXXX)
mkdir -p "$PIN_INTERLEAVE_DIR/d1/d2/d3/d4/d6"
printf 'echo pwned > "%s/forged.json"\n' "$PIN_FIXTURE" > "$PIN_INTERLEAVE_DIR/d1/d2/d3/d4/d6/forge.sh"
PIN_INTERLEAVE_JSON=$(jq -n --arg cmd 'cd d1; cd d2; cd d3; cd d4; cd d5; cd d6; bash forge.sh' \
    --arg cwd "$PIN_INTERLEAVE_DIR" '{tool_name:"Bash", tool_input:{command:$cmd, cwd:$cwd}}')
assert_rc "pin-dir write denied on a partial-failure cd branch past MAXCAND (HIMMEL-2225 round 6 codex-1)" 2 \
    "$(run_case "$PIN_INTERLEAVE_JSON" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# codex-1 (pr-check critic-panel ROUND 2): a CUSTOM pin dir configured in one
# drive-letter spelling (POSIX) must still be caught when the worker's command
# references the SAME directory in the OTHER spelling (native/Windows) --
# cross-spelling, unlike the same-spelling-both-sides case above. Rooted under
# $HOME (a genuine "/c/..." <-> "C:/..." drive mapping), NOT mktemp's default
# TMPDIR (MSYS mounts /tmp as its own alias, not a plain drive-letter pair, so
# a TMPDIR-rooted fixture cannot exercise this conversion at all). The
# "pin-cross-" name deliberately does not match the fixed default-path suffix
# check, isolating this case to the drive-letter-canonicalization fix.
PIN_CROSS_DIR=$(mktemp -d "$HOME/pin-cross-XXXXXX")
PIN_CROSS_DIR_NATIVE=$(native_dir "$PIN_CROSS_DIR")
assert_rc "pin-dir write denied via cross-spelling custom dir (codex-1 round 2)" 2 \
    "$(run_case "$(j_bash "echo pwned > $PIN_CROSS_DIR_NATIVE/forged.json")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_CROSS_DIR")"

# codex-1 (pr-check critic-panel round 1): matching only the RESOLVED absolute
# path missed the shell expanding an UNEXPANDED variable reference at
# execution time — the command text never contains the resolved path as a
# literal substring, so the original check alone missed it. A custom pin-dir
# fixture (not containing "himmel/hook-integrity" in its own name) isolates
# the var-name branch from the fixed-suffix branch below.
PIN_VAR_CUSTOM_DIR=$(mktemp -d -t pin-custom.XXXXXX)

# codex-2 (pr-check critic-panel round 2): PowerShell's canonical $env:X /
# ${env:X} scope-qualified variable syntax must be denied too -- the round-1
# fix only matched bash-style $X / ${X}.
# shellcheck disable=SC2016  # literal unexpanded PowerShell $env: reference is the command text under test
PIN_ENV_CMD='Set-Content -Path "$env:HIMMEL_HOOK_INTEGRITY_DIR/forged.json" -Value pwned'
assert_rc "pin-dir write denied via PowerShell \$env: reference (codex-2)" 2 \
    "$(run_case "$(j_pwsh "$PIN_ENV_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_VAR_CUSTOM_DIR")"
# shellcheck disable=SC2016  # literal unexpanded PowerShell ${env:X} reference is the command text under test
PIN_ENV_BRACED_CMD='Set-Content -Path "${env:HIMMEL_HOOK_INTEGRITY_DIR}/forged.json" -Value pwned'
assert_rc "pin-dir write denied via PowerShell \${env:X} braced reference (codex-2)" 2 \
    "$(run_case "$(j_pwsh "$PIN_ENV_BRACED_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_VAR_CUSTOM_DIR")"

# shellcheck disable=SC2016  # literal unexpanded env-var reference is the command text under test
PIN_VAR_CMD='echo pwned > "$HIMMEL_HOOK_INTEGRITY_DIR/forged.json"'
assert_rc "pin-dir write denied via unexpanded \$HIMMEL_HOOK_INTEGRITY_DIR reference (codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_VAR_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_VAR_CUSTOM_DIR")"
# shellcheck disable=SC2016  # literal unexpanded env-var reference is the command text under test
PIN_VAR_BRACED_CMD='echo pwned > "${HIMMEL_HOOK_INTEGRITY_DIR}/forged.json"'
assert_rc "pin-dir write denied via unexpanded \${HIMMEL_HOOK_INTEGRITY_DIR} braced reference (codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_VAR_BRACED_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_VAR_CUSTOM_DIR")"
# shellcheck disable=SC2016  # literal unexpanded $HOME reference is the command text under test
PIN_HOME_CMD='echo pwned > "$HOME/.claude/himmel/hook-integrity/forged.json"'
assert_rc "pin-dir write denied via unexpanded \$HOME default-path reference (codex-1)" 2 \
    "$(run_case "$(j_bash "$PIN_HOME_CMD")" "HIMMEL_WORKER=1")"

assert_rc "pin-dir write denied on the GLM lane too (new class extends it)" 2 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD")" "ANTHROPIC_BASE_URL=$GLM_URL" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

assert_rc "pin-dir write allowed under the documented bypass" 0 \
    "$(run_case "$(j_bash "$PIN_WRITE_CMD")" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE" "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1")"

# Scope boundary: a native worker gets ONLY the pin-dir class. The rest of
# this file's GLM-specific enforcement (push/gh/network) does not extend to
# it — HIMMEL-2085 asked for the hook-integrity surface, not a full GLM-lane
# replica for native workers.
assert_rc "native worker git push NOT blocked by this hook (out of HIMMEL-2085 scope)" 0 \
    "$(run_case "$(j_bash 'git push origin main')" "HIMMEL_WORKER=1")"
assert_rc "native worker unrelated command allowed" 0 \
    "$(run_case "$(j_bash 'git status')" "HIMMEL_WORKER=1" "HIMMEL_HOOK_INTEGRITY_DIR=$PIN_FIXTURE")"

# GLM lane's pre-existing enforcement is unchanged by this generalization.
assert_rc "glm lane git push still blocked (regression pin)" 2 \
    "$(run_case "$(j_bash 'git push origin main')" "ANTHROPIC_BASE_URL=$GLM_URL")"

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED case(s) FAILED"
    exit 1
fi

# Total-count guard: every assert_rc/skip_case increments CASES; a drift here
# means a case was silently dropped (or an early exit skipped the tail) even
# though nothing FAILED. Update EXPECTED_CASES deliberately when adding/
# removing a case.
EXPECTED_CASES=229   # +69: HIMMEL-2085 pin-dir write-fence + scope-boundary cases (+3 codex-1 var-expansion fix, +4 round-2 codex-1/2/3 fixes, +4 round-4 codex-1 script-indirection fix, +5 round-5 codex-1/2 direct-exec/dash-option/quoted-path/node fixes, +2 round-5 re-review pass 1 codex-2/3 quoted-space-path/absolute-interpreter fixes, +1 round-5 re-review pass 2 codex-2 cd-then-invoke fix, +3 HIMMEL-2200 quote-aware-split/backslash-escape/cd-existence-check fixes, +2 HIMMEL-2200 pr-check panel re-review codex-1 pwsh-dialect/double-quote-escape fixes, +1 HIMMEL-2200 pr-check panel round-3 codex-1 rmdir-then-cd TOCTOU fix, +1 HIMMEL-2200 pr-check panel round-5 codex-1 candidate-cap-truncation fix, +2 HIMMEL-2214 short-circuit-cd subsumption pin and its benign control, +1 HIMMEL-2218 codex-2 pwsh backtick-escaped separator fix, +3 HIMMEL-2218 codex-3 bash/pwsh line-continuation fix and its even-run control, +2 HIMMEL-2218 expansion pwsh doubled-single-quote fix and its bash-dialect control, +1 HIMMEL-2225 round-6 codex-1 candidate-interleave fix, +3 PR #2005 CodeRabbit CRLF line-continuation fix and its benign control, +3 PR #2005 panel round-2 codex-2 pwsh escape-sequence resolver and its controls, +2 PR #2005 panel round-2 codex-1 continuation-join non-regression pins, +4 PR #2005 panel round-3 codex-1 pwsh `u{...} unicode-escape fix and its controls, +11 PR #2005 PowerShell escape-grammar completeness enumeration, one case per form, +2 PR #2005 panel round-4 codex-2 NUL-filter-on-emitted-path fix and its control)
if [ "$CASES" -ne "$EXPECTED_CASES" ]; then
    echo "CASE-COUNT MISMATCH — ran $CASES, expected $EXPECTED_CASES"
    exit 1
fi
if [ "$SKIPPED" -ne 0 ]; then
    echo "all cases passed ($CASES/$EXPECTED_CASES, $SKIPPED skipped)"
else
    echo "all cases passed ($CASES/$EXPECTED_CASES)"
fi
exit 0
