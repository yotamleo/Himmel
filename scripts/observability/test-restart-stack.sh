#!/usr/bin/env bash
# Suite for scripts/observability/restart-stack.sh (HIMMEL-2133). Stubs
# schtasks, curl AND sleep via a PATH-stub bin dir (scripts/handover/test-
# merge-on-green.sh convention) and points LOCALAPPDATA at a throwaway tree
# so the grafana provisioning re-sync case never touches real machine state.
# The script itself has NO env-selected executables (HIMMEL-2133 CR round-2,
# codex-1) — the port-free probe is a plain `curl` connect-check, so the same
# PATH-stub `curl` that answers health checks also answers it (a URL ending
# in "/" is the port-probe shape; anything else is a health check), and the
# stub `sleep` makes the script's ~30s/~60s bounded polls cost nothing here.
#
# Each case runs a COPY of the script (+ its provisioning/ sibling) in a
# non-git tmp dir, never the real in-repo path — restart-stack.sh's own
# branch guard (HIMMEL-2133 CR round-1, codex-1) refuses to run from
# anything but a main/master checkout, and this worktree is on a feature
# branch. A tmp dir with no .git makes `git -C ... rev-parse` fail, which the
# guard treats as empty/inconclusive-but-allowed — the same convention
# test-merge-on-green.sh uses for its own fixed-sibling-path stubs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolved BEFORE any PATH override below — the real `mv` binary, for the
# rollback-failure case's call-counting stub to fall through to.
REAL_MV="$(command -v mv)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected '$want', got '$got'"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*|MSYS*) ;;
    *)
        echo "SKIP: restart-stack.sh is Windows/schtasks-only"
        exit 0
        ;;
esac

TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() { [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT" 2>/dev/null; return 0; }
trap cleanup EXIT

BIN=""; LOCALAPPDATA_DIR=""; SCHTASKS_LOG=""; CURL_LOG=""; PORT_PROBE_COUNTER=""; SCRIPT=""
PROMTOOL_LOG=""; PATH_PROMTOOL_MARKER=""; TASK_EXE_DIR=""

# run_captured <cmd...> — runs a command with stdout+stderr redirected to a
# real FILE, never captured straight off a `$(...)` pipe, then loads the
# result into $OUT; sets $RC. Windows Git Bash's MSYS layer can leak a
# `$(...)` pipe's write handle into a grandchild process (this suite's
# schtasks/curl/sleep stubs are each their own bash script, spawned via
# /usr/bin/env — extra process layers) that outlives the intended process
# tree, so the read side can hang waiting for an EOF that never comes even
# though the script itself already finished. A real file has no such
# handoff; `$(cat file)` on an already-closed file never hangs.
run_captured() {
    local out="$TMP_ROOT/run.out"
    : > "$out"
    "$@" > "$out" 2>&1
    RC=$?
    OUT="$(cat "$out")"
}

# patch_schtasks_stub <script-file> — strict pin, sed-in-copy (HIMMEL-2133 CR
# round-3, codex-1): restart-stack.sh pins SCHTASKS_BIN to schtasks.exe's
# absolute Windows path with NO PATH fallback in production. Assert the pin
# line exists FIRST so a future rename of the constant fails this suite
# loudly instead of silently testing against the real Windows schtasks.exe,
# then rewrite it in the given throwaway copy to point at THIS case's
# PATH-stub. Applied to EVERY script copy the suite runs (HIMMEL-2133 CR
# round-5, codex-1) — including the ad-hoc branch-guard copies below, which
# previously skipped this and could reach the real pinned binary if the
# branch guard ever unexpectedly let them through.
patch_schtasks_stub() {
    local f="$1"
    grep -q '^SCHTASKS_BIN="/c/Windows/System32/schtasks.exe"$' "$f" \
        || { echo "test-restart-stack: SCHTASKS_BIN pin line not found in restart-stack.sh — update this sed." >&2; exit 1; }
    # This suite is Windows/Git-Bash-only (the OSTYPE guard above), where MSYS
    # ships GNU coreutils — no BSD sed fallback needed here.
    sed -i "s#^SCHTASKS_BIN=.*#SCHTASKS_BIN=\"$BIN/schtasks\"#" "$f" # gnu-ok: MSYS-only suite
}

# setup_case — fresh tmp tree + stub bin dir + a non-git copy of the script
# (and its provisioning/ sibling) for one case. Removes the PREVIOUS case's
# tree first (only the last one needs the EXIT trap).
setup_case() {
    [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT" 2>/dev/null
    TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t rss)"
    BIN="$TMP_ROOT/bin"
    mkdir -p "$BIN"
    LOCALAPPDATA_DIR="$TMP_ROOT/localappdata"
    mkdir -p "$LOCALAPPDATA_DIR"
    SCHTASKS_LOG="$TMP_ROOT/schtasks.log"; : > "$SCHTASKS_LOG"
    CURL_LOG="$TMP_ROOT/curl.log"; : > "$CURL_LOG"
    PORT_PROBE_COUNTER="$TMP_ROOT/probe.count"
    PROMTOOL_LOG="$TMP_ROOT/promtool.log"; : > "$PROMTOOL_LOG"
    PATH_PROMTOOL_MARKER="$TMP_ROOT/path-promtool.marker"

    local script_copy_dir="$TMP_ROOT/scripts/observability"
    mkdir -p "$script_copy_dir"
    cp "$SCRIPT_DIR/restart-stack.sh" "$script_copy_dir/restart-stack.sh"
    cp -R "$SCRIPT_DIR/provisioning" "$script_copy_dir/provisioning"
    cp "$SCRIPT_DIR/alerts.rules.yml" "$script_copy_dir/alerts.rules.yml"
    cp "$SCRIPT_DIR/prometheus.yml" "$script_copy_dir/prometheus.yml"
    patch_schtasks_stub "$script_copy_dir/restart-stack.sh"
    chmod +x "$script_copy_dir/restart-stack.sh"
    SCRIPT="$script_copy_dir/restart-stack.sh"

    # Task-derived promtool resolution (HIMMEL-2239 CR round-1, codex-1):
    # resolve_promtool now reads the himmel-observability-prometheus task's
    # own "Task To Run:" line via //Query instead of globbing LOCALAPPDATA,
    # so the schtasks stub below must answer that query realistically. This
    # fake prometheus.exe's directory is also where the promtool stub(s)
    # below get planted — mirroring the real install layout (promtool.exe
    # ships beside prometheus.exe). Exported (not passed per run_captured
    # call) so every case inherits it without editing every invocation; a
    # case that needs a different/garbled answer overrides it by passing
    # SCHTASKS_QUERY_TASK_TO_RUN explicitly (see the schtasks stub below).
    TASK_EXE_DIR="$LOCALAPPDATA_DIR/himmel/observability/prometheus-3.13.1"
    mkdir -p "$TASK_EXE_DIR"
    : > "$TASK_EXE_DIR/prometheus.exe"
    TASK_EXE_WIN="$(cygpath -w "$TASK_EXE_DIR/prometheus.exe" 2>/dev/null || echo "$TASK_EXE_DIR/prometheus.exe")"
    # Trailing args after the .exe (matching the real line's shape) prove
    # resolve_promtool's "cut at the first .exe" parsing, not a whitespace
    # split — the config path below is quoted and contains no further ".exe".
    export STUB_TASK_TO_RUN_LINE="Task To Run:                          $TASK_EXE_WIN --config.file=\"${TASK_EXE_WIN%.exe}.yml\" -"

    # Records every invocation verbatim (proves the //End//TN//Run//Query
    # double-slash shape actually reaches schtasks). //Query prints the
    # Task To Run: line above (or SCHTASKS_QUERY_TASK_TO_RUN's override, for
    # the localized/unparseable-line case) AND a canned Last Result line, so
    # both resolve_promtool's pre-restart query and the post-restart
    # health-failure query have what they each grep for from the one stub.
    # //Run optionally appends SEED_GRAFANA_LOG_LINE to SEED_GRAFANA_LOG_FILE
    # (HIMMEL-2133 CR round-6, codex-2) — simulates Grafana itself writing a
    # provisioning-error line to its log at startup, AFTER
    # snapshot_grafana_log_watermark already ran (right before //End), so it
    # lands as a genuinely NEW line for verify_grafana_provisioning_loaded to
    # find, the same real-world timing a live Grafana would have.
    cat > "$BIN/schtasks" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SCHTASKS_LOG"
for a in "$@"; do
    if [ "$a" = "//Run" ] && [ -n "${SEED_GRAFANA_LOG_FILE:-}" ] && [ -n "${SEED_GRAFANA_LOG_LINE:-}" ]; then
        echo "$SEED_GRAFANA_LOG_LINE" >> "$SEED_GRAFANA_LOG_FILE"
    fi
    if [ "$a" = "//Query" ]; then
        echo "${SCHTASKS_QUERY_TASK_TO_RUN:-$STUB_TASK_TO_RUN_LINE}"
        echo "Last Result:                        ${SCHTASKS_QUERY_RESULT:-0}"
        exit 0
    fi
done
exit "${SCHTASKS_RC:-0}"
STUB
    chmod +x "$BIN/schtasks"

    # One stub serves BOTH calls restart-stack.sh makes through `curl`
    # (HIMMEL-2133 CR round-2, codex-1 — no env-selected probe program, so
    # the port-free check is itself a `curl` connect attempt against
    # "http://127.0.0.1:<port>/"): a URL ending in "/" is the port-probe
    # shape (PORT_PROBE_HOLD_CALLS "held" responses — exit 0, something
    # answered — before reporting free — exit 7, connection refused,
    # matching real curl's own code for that); anything else is a health
    # check (CURL_MODE=fail simulates a non-200/unreachable endpoint; default
    # prints a bare 200, matching real curl -o /dev/null -w '%{http_code}').
    cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CURL_LOG"
url="${!#}"
case "$url" in
    */)
        count=0
        [ -f "$PORT_PROBE_COUNTER" ] && count=$(cat "$PORT_PROBE_COUNTER")
        count=$((count + 1))
        echo "$count" > "$PORT_PROBE_COUNTER"
        if [ "$count" -le "${PORT_PROBE_HOLD_CALLS:-0}" ]; then
            exit 0
        fi
        exit 7
        ;;
    *)
        if [ "${CURL_MODE:-ok}" = "fail" ]; then
            exit 22
        fi
        printf '200'
        exit 0
        ;;
esac
STUB
    chmod +x "$BIN/curl"

    # No-op sleep — the script's ~30s/~60s bounded polls cost nothing here.
    cat > "$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$BIN/sleep"

    # promtool PATH stub (HIMMEL-2149) — kept so a case that removes the
    # task-derived stub below still exercises the PATH-fallback half of
    # resolve_promtool (HIMMEL-2239 CR round-1, codex-1: task-derived is now
    # the primary resolution, PATH is the degrade-path). Writes to
    # PATH_PROMTOOL_MARKER (default /dev/null) so a case can prove this one
    # was NOT the one invoked when the task-derived stub is present.
    cat > "$BIN/promtool" <<'STUB'
#!/usr/bin/env bash
: >> "${PATH_PROMTOOL_MARKER:-/dev/null}"
if [ -n "${PROMTOOL_FAIL_KIND:-}" ] && [ "$2" = "${PROMTOOL_FAIL_KIND}" ]; then
    exit 1
fi
exit "${PROMTOOL_RC:-0}"
STUB
    chmod +x "$BIN/promtool"

    # promtool task-derived stub (HIMMEL-2239 CR round-1, codex-1) — planted
    # beside the fake prometheus.exe in $TASK_EXE_DIR, the exact directory
    # resolve_promtool now derives from the schtasks "Task To Run:" line
    # (never from LOCALAPPDATA directly — that was the reviewed defect).
    # Logs every invocation's arguments to PROMTOOL_LOG (default /dev/null)
    # so a case can assert WHICH promtool subcommands ran. PROMTOOL_FAIL_KIND
    # fails only the check named in $2 ("rules"|"config"), letting a case
    # isolate a rules-only or config-only promtool failure; PROMTOOL_RC (as
    # before) fails everything when set.
    cat > "$TASK_EXE_DIR/promtool.exe" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${PROMTOOL_LOG:-/dev/null}"
if [ -n "${PROMTOOL_FAIL_KIND:-}" ] && [ "$2" = "${PROMTOOL_FAIL_KIND}" ]; then
    exit 1
fi
exit "${PROMTOOL_RC:-0}"
STUB
    chmod +x "$TASK_EXE_DIR/promtool.exe"
}

echo "=== 1. unknown task refused ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" not-a-real-task
assert_eq "unknown target exits 2" "2" "$RC"
assert_eq "unknown target never invokes schtasks" "0" "$(grep -c . "$SCHTASKS_LOG")"
assert_eq "unknown target never invokes curl" "0" "$(grep -c . "$CURL_LOG")"
case "$OUT" in
    *"himmel-observability-"*) pass "refusal names the allowlisted family" ;;
    *) fail "refusal names the allowlisted family" "got: $OUT" ;;
esac

echo "=== 2. grafana path re-syncs provisioning first ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" grafana
assert_eq "grafana restart exits 0 against healthy stubs" "0" "$RC"
DEST="$LOCALAPPDATA_DIR/himmel/observability/grafana-provisioning/datasources/prometheus.yaml"
SRC="$SCRIPT_DIR/provisioning/datasources/prometheus.yaml"
assert_eq "provisioning file is copied verbatim into the local state root" \
    "$(cat "$SRC")" "$([ -f "$DEST" ] && cat "$DEST" || echo MISSING)"
ALERT_DEST="$LOCALAPPDATA_DIR/himmel/observability/grafana-provisioning/alerting/contact-points.yaml"
assert_eq "the whole provisioning tree is mirrored, not just one file" "0" \
    "$([ -f "$ALERT_DEST" ] && echo 0 || echo 1)"

echo "=== 2b. wholesale replace removes files no longer in the repo tree ==="
setup_case
STALE="$LOCALAPPDATA_DIR/himmel/observability/grafana-provisioning/datasources/stale-old-datasource.yaml"
mkdir -p "$(dirname "$STALE")"
echo "leftover from a repo file deleted upstream" > "$STALE"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" grafana
assert_eq "grafana restart still exits 0" "0" "$RC"
assert_eq "a stale file no longer in the repo tree does not survive the re-sync" "1" \
    "$([ -f "$STALE" ] && echo 0 || echo 1)"
DEST2="$LOCALAPPDATA_DIR/himmel/observability/grafana-provisioning/datasources/prometheus.yaml"
assert_eq "the current repo file is still present after the wholesale replace" "0" \
    "$([ -f "$DEST2" ] && echo 0 || echo 1)"

echo "=== 2c. a failed staged copy leaves the original untouched (stage-then-swap) ==="
setup_case
EXISTING="$LOCALAPPDATA_DIR/himmel/observability/grafana-provisioning/datasources/prometheus.yaml"
mkdir -p "$(dirname "$EXISTING")"
echo "existing config that must survive a failed re-sync" > "$EXISTING"
# Corrupt THIS CASE's own throwaway provisioning/ copy (never the real repo
# tree) so the staged copy fails its key-file verification.
rm -f "$(dirname "$SCRIPT")/provisioning/alerting/policies.yaml"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" grafana
assert_eq "a failed staged copy exits non-zero" "1" "$RC"
assert_eq "the pre-existing provisioning file is untouched" \
    "existing config that must survive a failed re-sync" "$(cat "$EXISTING" 2>/dev/null)"
STAGING_LEFTOVERS="$(find "$LOCALAPPDATA_DIR/himmel/observability" -maxdepth 1 -name 'grafana-provisioning.new-*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no leftover staging dir survives the failure" "0" "$STAGING_LEFTOVERS"
assert_eq "schtasks is never touched when the provisioning sync fails first" "0" "$(grep -c . "$SCHTASKS_LOG")"

echo "=== 3. LOCALAPPDATA unset -> loud refusal, no schtasks touch ==="
setup_case
# SC2016: $0 below is the INNER bash -c invocation's own positional param
# (the SCRIPT path passed as its argument), deliberately left unexpanded by
# the outer shell's single quotes.
# shellcheck disable=SC2016
run_captured env PATH="$BIN:$PATH" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    bash -c 'unset LOCALAPPDATA; exec bash "$0" grafana' "$SCRIPT"
assert_eq "missing LOCALAPPDATA exits non-zero" "1" "$RC"
case "$OUT" in
    *"LOCALAPPDATA is not set"*) pass "refusal names LOCALAPPDATA" ;;
    *) fail "refusal names LOCALAPPDATA" "got: $OUT" ;;
esac
assert_eq "no schtasks call before the LOCALAPPDATA guard" "0" "$(grep -c . "$SCHTASKS_LOG")"

echo "=== 4. port held -> wait loop -> then proceeds to //Run ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=3 \
    bash "$SCRIPT" flow-exporter
assert_eq "restart succeeds once the port frees" "0" "$RC"
assert_eq "the port probe was polled past the held window (waited, not gave up)" "true" \
    "$([ -f "$PORT_PROBE_COUNTER" ] && [ "$(cat "$PORT_PROBE_COUNTER")" -ge 4 ] && echo true || echo false)"
assert_eq "//Run still ran after the wait" "1" "$(grep -c '//Run' "$SCHTASKS_LOG")"

echo "=== 5. port never frees -> refuses to //Run ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=999 \
    bash "$SCRIPT" prometheus
assert_eq "a port that never frees exits non-zero" "1" "$RC"
assert_eq "//Run is never issued into a still-held port" "0" "$(grep -c '//Run' "$SCHTASKS_LOG")"

echo "=== 6. health-verify failure -> nonzero, surfaces Last Result ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" CURL_MODE=fail SCHTASKS_QUERY_RESULT=0x1 \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "a failing health check exits non-zero" "1" "$RC"
case "$OUT" in
    *"Last Result"*) pass "failure output surfaces Last Result via //Query" ;;
    *) fail "failure output surfaces Last Result via //Query" "got: $OUT" ;;
esac
# 3, not 1 (HIMMEL-2239 CR round-1, codex-1): resolve_promtool now issues its
# own //Query //TN himmel-observability-prometheus //V //FO LIST BEFORE the
# restart even starts (task-derived promtool resolution) — once for
# sync_prometheus_alert_rules, once more for sync_prometheus_config (each
# calls resolve_promtool independently) — plus the post-restart
# health-failure query below; all three land in this log.
assert_eq "//Query was invoked for both promtool resolutions AND on health failure" "3" "$(grep -c '//Query' "$SCHTASKS_LOG")"

echo "=== 7. double-slash invocation shape reaches the stub ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" windows-exporter
LOGGED="$(cat "$SCHTASKS_LOG")"
case "$LOGGED" in
    *"//End //TN himmel-observability-windows-exporter"*) pass "//End uses the doubled-slash form" ;;
    *) fail "//End uses the doubled-slash form" "got: $LOGGED" ;;
esac
case "$LOGGED" in
    *"//Run //TN himmel-observability-windows-exporter"*) pass "//Run uses the doubled-slash form" ;;
    *) fail "//Run uses the doubled-slash form" "got: $LOGGED" ;;
esac
assert_eq "no single-slash /End form was ever issued" "0" "$(printf '%s' "$LOGGED" | grep -c '[^/]/End')"
assert_eq "no single-slash /Run form was ever issued" "0" "$(printf '%s' "$LOGGED" | grep -c '[^/]/Run')"

echo "=== 8. a feature-branch copy (with a real commit) refuses to run ==="
setup_case
BRANCH_DIR="$TMP_ROOT/branch-copy"
mkdir -p "$BRANCH_DIR/scripts/observability"
cp "$SCRIPT_DIR/restart-stack.sh" "$BRANCH_DIR/scripts/observability/restart-stack.sh"
cp -R "$SCRIPT_DIR/provisioning" "$BRANCH_DIR/scripts/observability/provisioning"
patch_schtasks_stub "$BRANCH_DIR/scripts/observability/restart-stack.sh"
chmod +x "$BRANCH_DIR/scripts/observability/restart-stack.sh"
git init -q "$BRANCH_DIR" >/dev/null 2>&1
git -C "$BRANCH_DIR" checkout -q -b feat/some-worktree-copy >/dev/null 2>&1
# A commit is REQUIRED (HIMMEL-2133 CR round-5, codex-1) to test the
# INTENDED refusal path robustly. Empirically verified by hand: on a truly
# unborn HEAD (no commit), `git rev-parse --abbrev-ref HEAD` fails but still
# prints the literal word "HEAD" to STDOUT (the diagnostic goes to stderr) —
# restart-stack.sh's `2>/dev/null || true` only swallows stderr, so
# current_branch becomes the STRING "HEAD", not empty, which the branch
# guard's `case` also refuses (it isn't 'main'/'master'/''). That means an
# unborn repo happens to get refused too, but only as an accidental side
# effect of a stdout quirk — not the documented empty-branch-allowed path
# (see case 8b below for that one). A real commit makes current_branch the
# actual branch name, exercising the branch guard's real, documented refusal
# instead of relying on that quirk. `-c user.name=/-c user.email=` avoids
# depending on any global git identity being configured on the runner.
git -C "$BRANCH_DIR" -c user.name=test -c user.email=test@example.invalid \
    commit -q --allow-empty -m "test commit" >/dev/null 2>&1
run_captured env PATH="$BIN:$PATH" bash "$BRANCH_DIR/scripts/observability/restart-stack.sh" flow-exporter
assert_eq "a copy checked out on a feature branch refuses to run" "2" "$RC"
case "$OUT" in
    *"not main/master"*) pass "refusal names the main/master requirement" ;;
    *) fail "refusal names the main/master requirement" "got: $OUT" ;;
esac
assert_eq "schtasks (stub or real) is never touched — refused before that" "0" "$(grep -c . "$SCHTASKS_LOG")"

echo "=== 8b. a plain non-git copy (the genuine empty-branch case) is ALLOWED but only ever reaches the STUB ==="
setup_case
NOGIT_DIR="$TMP_ROOT/nogit-copy"
mkdir -p "$NOGIT_DIR/scripts/observability"
cp "$SCRIPT_DIR/restart-stack.sh" "$NOGIT_DIR/scripts/observability/restart-stack.sh"
cp -R "$SCRIPT_DIR/provisioning" "$NOGIT_DIR/scripts/observability/provisioning"
patch_schtasks_stub "$NOGIT_DIR/scripts/observability/restart-stack.sh"
chmod +x "$NOGIT_DIR/scripts/observability/restart-stack.sh"
# Deliberately NO `git init` at all — this is the ACTUAL empty-branch case
# (verified by hand: `git -C <no-.git-dir> rev-parse --abbrev-ref HEAD`
# captures as '', unlike an unborn-but-git-inited repo, which captures as the
# literal string "HEAD" — see the case 8 comment above). The point here is
# NOT the branch guard's verdict (it is ALLOWED, by the script's own design)
# — it is proving that even so, with patch_schtasks_stub applied, only the
# PATH-stub schtasks is ever reachable, never the real pinned binary
# (HIMMEL-2133 CR round-5, codex-1). This is also exactly what setup_case's
# OWN $SCRIPT copy already is, so every other case in this suite already
# relies on this same "no .git -> empty -> allowed" behavior implicitly.
run_captured env PATH="$BIN:$PATH" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$NOGIT_DIR/scripts/observability/restart-stack.sh" flow-exporter
assert_eq "the non-git copy is allowed through (not refused by the branch guard)" "0" "$RC"
assert_eq "the branch guard's refusal message never fired" "0" "$(printf '%s' "$OUT" | grep -c 'not main/master')"
assert_eq "schtasks WAS reached, and it was the STUB (//End logged, never real schtasks.exe)" "1" \
    "$(grep -c '//End' "$SCHTASKS_LOG")"

echo "=== 9. no env-selected executable seams remain (HIMMEL-2133 CR round-2, codex-1) ==="
# SC2016: both '${RESTART_STACK_' occurrences below are deliberately
# unexpanded literal text — the assertion name and the grep PATTERN, not a
# variable reference.
# shellcheck disable=SC2016
assert_eq 'no ${RESTART_STACK_ references in the script' "0" \
    "$(grep -c '${RESTART_STACK_' "$SCRIPT_DIR/restart-stack.sh")"

echo "=== 10. a held provisioning lock refuses concurrent grafana sync (rc=2) ==="
setup_case
LOCK_DEST="$LOCALAPPDATA_DIR/himmel/observability/grafana-provisioning"
mkdir -p "$LOCK_DEST.lock"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" grafana
assert_eq "a held lock refuses with rc=2" "2" "$RC"
case "$OUT" in
    *"already in progress"*) pass "refusal explains the concurrent-sync reason" ;;
    *) fail "refusal explains the concurrent-sync reason" "got: $OUT" ;;
esac
assert_eq "schtasks is never touched when the lock is held" "0" "$(grep -c . "$SCHTASKS_LOG")"
assert_eq "the pre-held lock dir is left in place (never removed by someone else's run)" "0" \
    "$([ -d "$LOCK_DEST.lock" ] && echo 0 || echo 1)"

echo "=== 11. a failed rollback exits distinct (rc=3) and names both paths, ABSENT ==="
setup_case
DEST11="$LOCALAPPDATA_DIR/himmel/observability/grafana-provisioning"
EXISTING2="$DEST11/datasources/prometheus.yaml"
mkdir -p "$(dirname "$EXISTING2")"
echo "pre-existing config" > "$EXISTING2"
MV_LOG="$TMP_ROOT/mv.log"; : > "$MV_LOG"
# Call-counting mv stub: call 1 (move the live tree aside to .old-$$)
# succeeds via the REAL mv; call 2 (move the staged .new-$$ into place)
# FAILS; call 3 (the rollback attempt) ALSO fails — the double-failure this
# case exists to prove restart-stack.sh surfaces loudly rather than silently.
cat > "$BIN/mv" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$MV_LOG"
n=$(grep -c . "$MV_LOG")
if [ "$n" -ge 2 ]; then
    exit 1
fi
exec "$REAL_MV" "$@"
STUB
chmod +x "$BIN/mv"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" MV_LOG="$MV_LOG" REAL_MV="$REAL_MV" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" grafana
assert_eq "a failed rollback exits with a code distinct from the plain-failure code (1)" "3" "$RC"
case "$OUT" in
    *CRITICAL*) pass "failure message is marked CRITICAL" ;;
    *) fail "failure message is marked CRITICAL" "got: $OUT" ;;
esac
case "$OUT" in
    *"$DEST11"*ABSENT*) pass "failure names the live path and says it is ABSENT" ;;
    *) fail "failure names the live path and says it is ABSENT" "got: $OUT" ;;
esac
case "$OUT" in
    *".old-"*) pass "failure names the stranded .old-\$\$ path" ;;
    *) fail "failure names the stranded .old-\$\$ path" "got: $OUT" ;;
esac
assert_eq "mv was tried a 3rd time (the rollback attempt itself)" "3" "$(grep -c . "$MV_LOG")"

echo "=== 12. grafana provisioning error since the restart -> distinct rc=4, line surfaced ==="
setup_case
LOGDIR12="$LOCALAPPDATA_DIR/himmel/observability/grafana-logs"
mkdir -p "$LOGDIR12"
LOGFILE12="$LOGDIR12/grafana.log"
echo 't=2026-08-26T19:00:00 level=info msg="pre-existing baseline line"' > "$LOGFILE12"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    SEED_GRAFANA_LOG_FILE="$LOGFILE12" \
    SEED_GRAFANA_LOG_LINE='t=2026-08-26T19:00:05 level=error logger=provisioning.datasources msg="data source not found"' \
    bash "$SCRIPT" grafana
assert_eq "a provisioning error since the restart exits the distinct code 4" "4" "$RC"
case "$OUT" in
    *"provisioning ERROR"*) pass "failure message names it a provisioning ERROR" ;;
    *) fail "failure message names it a provisioning ERROR" "got: $OUT" ;;
esac
case "$OUT" in
    *"logger=provisioning.datasources"*"data source not found"*) pass "the offending log line itself is surfaced" ;;
    *) fail "the offending log line itself is surfaced" "got: $OUT" ;;
esac
case "$OUT" in
    *"pre-existing baseline line"*) fail "the pre-existing (pre-restart) baseline line is NOT re-surfaced" "got: $OUT" ;;
    *) pass "the pre-existing (pre-restart) baseline line is NOT re-surfaced" ;;
esac

echo "=== 13. no grafana log dir -> WARNING, success path unchanged (rc=0) ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" grafana
assert_eq "grafana still succeeds when there is no log dir to verify against" "0" "$RC"
case "$OUT" in
    *"WARNING"*"cannot verify"*) pass "a missing log dir warns instead of failing" ;;
    *) fail "a missing log dir warns instead of failing" "got: $OUT" ;;
esac

echo "=== 14. prometheus path re-syncs alerts.rules.yml first ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart exits 0 against healthy stubs" "0" "$RC"
RULES_SRC="$SCRIPT_DIR/alerts.rules.yml"
RULES_DEST="$LOCALAPPDATA_DIR/himmel/observability/alerts.rules.yml"
assert_eq "alerts.rules.yml is copied verbatim into the local state root" \
    "$(cat "$RULES_SRC")" "$([ -f "$RULES_DEST" ] && cat "$RULES_DEST" || echo MISSING)"

echo "=== 14b. promtool unresolvable (task-dir AND PATH both empty) -> sync is REFUSED (HIMMEL-2239 fail-closed), not skipped ==="
setup_case
rm -f "$BIN/promtool" "$TASK_EXE_DIR/promtool.exe"
RULES_DEST14b="$LOCALAPPDATA_DIR/himmel/observability/alerts.rules.yml"
mkdir -p "$(dirname "$RULES_DEST14b")"
echo "pre-existing rules that must survive an unresolvable promtool" > "$RULES_DEST14b"
# PATH is $BIN + /usr/bin ONLY here (no ":$PATH" fallback, HIMMEL-2149 CR
# round-3, codex-2): the ordinary "$BIN:$PATH" shape lets a real promtool
# elsewhere on the OPERATOR's ambient PATH leak in and mask the absent-tool
# branch under test. /usr/bin is MSYS's own coreutils (cp/mv/rm/mkdir/date/
# cmp/cygpath — everything restart-stack.sh itself calls); schtasks/curl/
# sleep are stubs already resolved via $BIN, sed-pinned/relative, not a live
# PATH search.
run_captured env PATH="$BIN:/usr/bin" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart exits 1 when promtool is unresolvable" "1" "$RC"
assert_eq "the pre-existing alert-rules file is left untouched" \
    "pre-existing rules that must survive an unresolvable promtool" "$(cat "$RULES_DEST14b" 2>/dev/null)"
# schtasks IS invoked now (resolve_promtool's own //Query, task-derived
# resolution, HIMMEL-2239 CR round-1) even though it comes back empty-handed
# here — the MUTATING calls (//End, //Run) are what must never fire.
assert_eq "schtasks //End is never issued when promtool is unresolvable" "0" "$(grep -c '//End' "$SCHTASKS_LOG")"
assert_eq "schtasks //Run is never issued when promtool is unresolvable" "0" "$(grep -c '//Run' "$SCHTASKS_LOG")"
case "$OUT" in
    *"promtool could not be resolved"*"HIMMEL-2239"*) pass "the refusal names the resolution failure and HIMMEL-2239" ;;
    *) fail "the refusal names the resolution failure and HIMMEL-2239" "got: $OUT" ;;
esac

echo "=== 14c. task-derived promtool (via schtasks 'Task To Run:') is resolved AHEAD of PATH ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PROMTOOL_LOG="$PROMTOOL_LOG" PATH_PROMTOOL_MARKER="$PATH_PROMTOOL_MARKER" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart exits 0" "0" "$RC"
assert_eq "the task-derived promtool was invoked" "0" "$([ -s "$PROMTOOL_LOG" ] && echo 0 || echo 1)"
assert_eq "the PATH promtool was NEVER invoked (task-derived wins)" "0" \
    "$([ -f "$PATH_PROMTOOL_MARKER" ] && echo 1 || echo 0)"

echo "=== 14f. a LOCALIZED 'Task To Run:' label still resolves via the value shape, not the label (HIMMEL-2239 CR round-2, codex-1) ==="
setup_case
# codex-1's actual regression: on non-English Windows the field label is
# translated (German "Auszuführende Aufgabe:") but the PATH VALUE never is.
# resolve_promtool no longer greps for the label at all — it scans for a
# drive-letter path ending in prometheus.exe — so a localized label must
# still resolve the task-derived promtool, never fall back to PATH.
LOCALIZED_TASK_LINE="Auszuführende Aufgabe:                $TASK_EXE_WIN --config.file=\"${TASK_EXE_WIN%.exe}.yml\" -"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PROMTOOL_LOG="$PROMTOOL_LOG" PATH_PROMTOOL_MARKER="$PATH_PROMTOOL_MARKER" \
    SCHTASKS_QUERY_TASK_TO_RUN="$LOCALIZED_TASK_LINE" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart exits 0 on a localized-label station" "0" "$RC"
assert_eq "the task-derived promtool IS resolved and used despite the localized label" "0" \
    "$([ -s "$PROMTOOL_LOG" ] && echo 0 || echo 1)"
assert_eq "the PATH promtool is NOT used as a fallback (no fallback needed)" "0" \
    "$([ -f "$PATH_PROMTOOL_MARKER" ] && echo 1 || echo 0)"

echo "=== 14g. a parent directory literally named 'foo.exe.d' does not truncate the extracted path (codex-2) ==="
setup_case
# Cutting at the FIRST '.exe' (the pre-round-2 approach) would yield
# ".../foo.exe" here — a nonexistent file — and dirname of that has no
# promtool, so the old code would degrade to PATH. Anchoring on
# `prometheus\.exe` specifically walks past the exe-flavoured directory name
# to the real terminal executable, so the CORRECT directory's promtool must
# be the one invoked.
CONTRIVED_DIR="$LOCALAPPDATA_DIR/himmel/observability/foo.exe.d/prometheus-9.9.9"
mkdir -p "$CONTRIVED_DIR"
: > "$CONTRIVED_DIR/prometheus.exe"
cat > "$CONTRIVED_DIR/promtool.exe" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${PROMTOOL_LOG:-/dev/null}"
exit "${PROMTOOL_RC:-0}"
STUB
chmod +x "$CONTRIVED_DIR/promtool.exe"
CONTRIVED_EXE_WIN="$(cygpath -w "$CONTRIVED_DIR/prometheus.exe" 2>/dev/null || echo "$CONTRIVED_DIR/prometheus.exe")"
CONTRIVED_TASK_LINE="Task To Run:                          $CONTRIVED_EXE_WIN --config.file=\"${CONTRIVED_EXE_WIN%.exe}.yml\" -"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PROMTOOL_LOG="$PROMTOOL_LOG" PATH_PROMTOOL_MARKER="$PATH_PROMTOOL_MARKER" \
    SCHTASKS_QUERY_TASK_TO_RUN="$CONTRIVED_TASK_LINE" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart exits 0 despite the '.exe'-flavoured parent directory" "0" "$RC"
assert_eq "the promtool beside the FULL (untruncated) prometheus.exe path was invoked" "0" \
    "$([ -s "$PROMTOOL_LOG" ] && echo 0 || echo 1)"
assert_eq "the PATH promtool was NEVER invoked (the correct directory resolved, no fallback needed)" "0" \
    "$([ -f "$PATH_PROMTOOL_MARKER" ] && echo 1 || echo 0)"

echo "=== 14e. a query output with no recognizable prometheus.exe path degrades gracefully to PATH promtool ==="
setup_case
# Genuinely unparseable (not a localized label — see 14f, which proves that
# resolves fine now): the query answers something with no Windows
# drive-letter path ending in prometheus.exe at all, so resolve_promtool must
# fall through to PATH rather than mistake this for "promtool is absent".
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PROMTOOL_LOG="$PROMTOOL_LOG" PATH_PROMTOOL_MARKER="$PATH_PROMTOOL_MARKER" \
    SCHTASKS_QUERY_TASK_TO_RUN="Auszuführende Aufgabe:               N/A" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart still exits 0 with an unparseable task-query line" "0" "$RC"
assert_eq "the task-derived promtool was NOT invoked (no path found to derive it from)" "0" \
    "$([ -s "$PROMTOOL_LOG" ] && echo 1 || echo 0)"
assert_eq "the PATH promtool WAS invoked as the graceful-degrade fallback" "0" \
    "$([ -f "$PATH_PROMTOOL_MARKER" ] && echo 0 || echo 1)"
RULES_DEST14e="$LOCALAPPDATA_DIR/himmel/observability/alerts.rules.yml"
assert_eq "the sync still proceeded via the PATH fallback" \
    "$(cat "$SCRIPT_DIR/alerts.rules.yml")" "$([ -f "$RULES_DEST14e" ] && cat "$RULES_DEST14e" || echo MISSING)"

echo "=== 14d. prometheus.yml itself is synced (HIMMEL-2242) ==="
setup_case
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" PROMTOOL_LOG="$PROMTOOL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart exits 0" "0" "$RC"
CONFIG_DEST14d="$LOCALAPPDATA_DIR/himmel/observability/prometheus.yml"
assert_eq "prometheus.yml is copied verbatim into the local state root" \
    "$(cat "$SCRIPT_DIR/prometheus.yml")" "$([ -f "$CONFIG_DEST14d" ] && cat "$CONFIG_DEST14d" || echo MISSING)"
assert_eq "promtool ran a rules check" "true" \
    "$([ "$(grep -c 'check rules' "$PROMTOOL_LOG")" -ge 1 ] && echo true || echo false)"
assert_eq "promtool ran a config check" "true" \
    "$([ "$(grep -c 'check config' "$PROMTOOL_LOG")" -ge 1 ] && echo true || echo false)"

echo "=== 15. promtool check rules failure refuses the sync, leaves dest untouched ==="
setup_case
RULES_DEST15="$LOCALAPPDATA_DIR/himmel/observability/alerts.rules.yml"
mkdir -p "$(dirname "$RULES_DEST15")"
echo "existing rules that must survive a failed promtool check" > "$RULES_DEST15"
# PROMTOOL_FAIL_KIND=rules (not the blunter PROMTOOL_RC=1) isolates the
# rules-check failure specifically, now that the same promtool also runs a
# config check (HIMMEL-2242) — this proves the rules failure alone is what
# refuses the sync, not merely "promtool exits nonzero for anything".
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" PROMTOOL_FAIL_KIND=rules \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "a failed promtool check exits non-zero" "1" "$RC"
assert_eq "the pre-existing alert-rules file is untouched" \
    "existing rules that must survive a failed promtool check" "$(cat "$RULES_DEST15" 2>/dev/null)"
# resolve_promtool's own //Query (task-derived resolution, HIMMEL-2239 CR
# round-1) DOES reach schtasks and succeeds — it is the subsequent `promtool
# check rules` that fails. Only the MUTATING calls must never fire.
assert_eq "schtasks //End is never issued when promtool check rules fails" "0" "$(grep -c '//End' "$SCHTASKS_LOG")"
assert_eq "schtasks //Run is never issued when promtool check rules fails" "0" "$(grep -c '//Run' "$SCHTASKS_LOG")"
case "$OUT" in
    *"promtool check rules failed"*) pass "refusal names the promtool failure" ;;
    *) fail "refusal names the promtool failure" "got: $OUT" ;;
esac

echo "=== 15b. promtool check config failure refuses the config sync, leaves dest untouched (HIMMEL-2242) ==="
setup_case
CONFIG_DEST15b="$LOCALAPPDATA_DIR/himmel/observability/prometheus.yml"
mkdir -p "$(dirname "$CONFIG_DEST15b")"
echo "existing config that must survive a failed promtool check" > "$CONFIG_DEST15b"
# Failing ONLY "config" (not "rules") proves the rules sync still succeeds
# (it runs first) while the config sync alone is refused.
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" PROMTOOL_FAIL_KIND=config \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "a failed promtool config check exits non-zero" "1" "$RC"
assert_eq "the pre-existing prometheus.yml is untouched" \
    "existing config that must survive a failed promtool check" "$(cat "$CONFIG_DEST15b" 2>/dev/null)"
# Same reasoning as case 15: resolve_promtool's own //Query succeeds; only
# the MUTATING calls must never fire.
assert_eq "schtasks //End is never issued when promtool check config fails" "0" "$(grep -c '//End' "$SCHTASKS_LOG")"
assert_eq "schtasks //Run is never issued when promtool check config fails" "0" "$(grep -c '//Run' "$SCHTASKS_LOG")"
case "$OUT" in
    *"promtool check config failed"*) pass "refusal names the promtool config failure" ;;
    *) fail "refusal names the promtool config failure" "got: $OUT" ;;
esac
RULES_DEST15b="$LOCALAPPDATA_DIR/himmel/observability/alerts.rules.yml"
assert_eq "the rules sync completed before the config sync was refused" \
    "$(cat "$SCRIPT_DIR/alerts.rules.yml")" "$([ -f "$RULES_DEST15b" ] && cat "$RULES_DEST15b" || echo MISSING)"

echo "=== 16. a pre-existing alert-rules file is backed up with a timestamped .bak ==="
setup_case
RULES_DEST16="$LOCALAPPDATA_DIR/himmel/observability/alerts.rules.yml"
mkdir -p "$(dirname "$RULES_DEST16")"
echo "the previous rules version" > "$RULES_DEST16"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart still exits 0" "0" "$RC"
BAK_COUNT="$(find "$(dirname "$RULES_DEST16")" -maxdepth 1 -name 'alerts.rules.yml.bak-*' | wc -l | tr -d ' ')" # gnu-ok: MSYS-only suite
assert_eq "exactly one timestamped .bak of the replaced file is left behind" "1" "$BAK_COUNT"
BAK_FILE="$(find "$(dirname "$RULES_DEST16")" -maxdepth 1 -name 'alerts.rules.yml.bak-*' | head -n 1)" # gnu-ok: MSYS-only suite
assert_eq "the .bak holds the REPLACED (previous) content" \
    "the previous rules version" "$(cat "$BAK_FILE" 2>/dev/null)"
assert_eq "the live file holds the NEW (repo) content" \
    "$(cat "$SCRIPT_DIR/alerts.rules.yml")" "$(cat "$RULES_DEST16")"

echo "=== 16b. a pre-existing prometheus.yml is backed up with a timestamped .bak (HIMMEL-2242) ==="
setup_case
CONFIG_DEST16b="$LOCALAPPDATA_DIR/himmel/observability/prometheus.yml"
mkdir -p "$(dirname "$CONFIG_DEST16b")"
echo "the previous config version" > "$CONFIG_DEST16b"
run_captured env PATH="$BIN:$PATH" LOCALAPPDATA="$LOCALAPPDATA_DIR" \
    SCHTASKS_LOG="$SCHTASKS_LOG" CURL_LOG="$CURL_LOG" \
    PORT_PROBE_COUNTER="$PORT_PROBE_COUNTER" PORT_PROBE_HOLD_CALLS=0 \
    bash "$SCRIPT" prometheus
assert_eq "prometheus restart still exits 0" "0" "$RC"
BAK_COUNT16b="$(find "$(dirname "$CONFIG_DEST16b")" -maxdepth 1 -name 'prometheus.yml.bak-*' | wc -l | tr -d ' ')" # gnu-ok: MSYS-only suite
assert_eq "exactly one timestamped .bak of the replaced config is left behind" "1" "$BAK_COUNT16b"
BAK_FILE16b="$(find "$(dirname "$CONFIG_DEST16b")" -maxdepth 1 -name 'prometheus.yml.bak-*' | head -n 1)" # gnu-ok: MSYS-only suite
assert_eq "the .bak holds the REPLACED (previous) config content" \
    "the previous config version" "$(cat "$BAK_FILE16b" 2>/dev/null)"
assert_eq "the live config holds the NEW (repo) content" \
    "$(cat "$SCRIPT_DIR/prometheus.yml")" "$(cat "$CONFIG_DEST16b")"

summary
