#!/usr/bin/env bash
# test-promtool-validation.sh — REAL-BINARY positive control for HIMMEL-2239.
#
# WHY a second suite: test-restart-stack.sh proves the PLUMBING (resolution
# order, fail-closed refusal, sync mechanics) against a stub promtool that
# always exits 0 or 1 on command. None of that proves promtool actually
# REJECTS a broken rules/config file — a validation step that cannot be shown
# to reject anything is exactly the vacuous-verdict class HIMMEL-2239 exists
# to close. This suite runs the REAL promtool binary against a known-good
# copy of each repo file (negative control: must pass) and a deliberately
# broken one (positive control: must fail) for both `check rules` and
# `check config`, plus the `test rules` unit-test fixture HIMMEL-2239 asked
# whether ANY automated path runs at all — before this suite, none did, so
# alerts.rules.test.yml was decorative.
#
# CAPABILITY-CONDITIONAL, loud-skip: this needs the real promtool from the
# stack's own install dir (or PATH), which is not guaranteed to exist on
# every machine that checks out this repo (a station that never ran
# install-stack.ps1 has no Prometheus release unpacked at all).
# scripts/ci/run-shell-tests.sh's SUITE_REQUIRE_TOOL table can't express this
# gate — it keys capability checks on PATH presence, and promtool is
# deliberately NOT on PATH (see resolve_promtool in restart-stack.sh) — so
# this suite carries its own runtime guard instead of relying on that table.
# Never touches this machine's real %LOCALAPPDATA% state: it only READS repo
# files and WRITES broken copies into its own mktemp -d tmp dir.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Pulls the `for:` value out of one rule block: scan forward from the exact
# rule-start line (an anchored whole-line match, never a substring — both
# files also mention these rule names in prose comments elsewhere) to the
# first bare `for:` line, skipping `keepFiringFor:` which ends in the same
# four letters.
extract_for() {
    local file="$1" marker="$2"
    awk -v marker="$marker" '
        $0 ~ ("^[[:space:]]*" marker "$") { found=1; next }
        found && /^[[:space:]]*- (uid|alert):/ { exit }
        found && /^[[:space:]]*for:[[:space:]]*[0-9]/ {
            sub(/^[[:space:]]*for:[[:space:]]*/, "")
            print $1
            exit
        }
    ' "$file"
}

# Extracts a bare `field:` scalar out of one rule block, same scan shape as
# extract_for above (anchored whole-line uid marker, stop at the next rule).
extract_field() {
    local file="$1" marker="$2" field="$3"
    awk -v marker="$marker" -v field="$field" '
        $0 ~ ("^[[:space:]]*" marker "$") { found=1; next }
        found && /^[[:space:]]*- uid:/ { exit }
        found && $0 ~ ("^[[:space:]]*" field ":[[:space:]]*[A-Za-z]") {
            sub("^[[:space:]]*" field ":[[:space:]]*", "")
            print $1
            exit
        }
    ' "$file"
}

# Case 0 (HIMMEL-2365 rules parity) runs FIRST, ahead of the promtool
# resolution/skip gate below — it needs no binary, and a station with no
# promtool must not silently skip a genuine parity drift (codex-1, CR round 1:
# an earlier version placed this after the skip gate, so it never ran at all
# on a promtool-less machine despite a comment there claiming it already had).
echo "=== 0. RULES PARITY (HIMMEL-2365): for: values match between the Grafana and Prometheus twins ==="
for pair in \
    "himmel_session_dead|- uid: himmel_session_dead|HimmelSessionDead|- alert: HimmelSessionDead" \
    "himmel_watcher_down|- uid: himmel_watcher_down|HimmelWatcherDown|- alert: HimmelWatcherDown" \
    "himmel_hook_chain_budget_pressure|- uid: himmel_hook_chain_budget_pressure|HimmelHookChainBudgetPressure|- alert: HimmelHookChainBudgetPressure" \
    "himmel_hook_chain_budget_denials|- uid: himmel_hook_chain_budget_denials|HimmelHookChainBudgetDenials|- alert: HimmelHookChainBudgetDenials" \
    "himmel_hook_chain_log_unreadable|- uid: himmel_hook_chain_log_unreadable|HimmelHookChainLogUnreadable|- alert: HimmelHookChainLogUnreadable"
do
    IFS='|' read -r label grafana_marker _name prom_marker <<<"$pair"
    grafana_for="$(extract_for "$SCRIPT_DIR/provisioning/alerting/rules.yaml" "$grafana_marker")"
    prom_for="$(extract_for "$SCRIPT_DIR/alerts.rules.yml" "$prom_marker")"
    # codex-2, CR round 1: two empty extractions compare equal, which would
    # silently pass a rule block missing or unparseable in BOTH files. Fail
    # loudly on a missing marker instead of trusting the equality alone.
    if [ -z "$grafana_for" ] || [ -z "$prom_for" ]; then
        fail "$label: for: matches between rules.yaml and alerts.rules.yml" \
            "could not extract a for: value (grafana='$grafana_for' prometheus='$prom_for') — marker missing or rule block unparseable"
    else
        assert_eq "$label: for: matches between rules.yaml and alerts.rules.yml" "$grafana_for" "$prom_for"
    fi
done

# Case 0.5 (HIMMEL-2478/2480 noDataState policy): every rule in rules.yaml
# must carry the noDataState this table expects, matching rules.yaml's own
# header comment (NoData only when refId A is a bare metric selector; OK
# when A embeds a comparison, since empty then means healthy; KeepLast on
# the one deliberate himmel_flow_stalled exception). A rule added later with
# no entry below fails loudly rather than silently inheriting whatever the
# author typed. Needs no binary — runs ahead of the promtool skip gate too.
echo "=== 0.5. noDataState POLICY (HIMMEL-2478/2480): every rule matches its expected noDataState ==="
RULES_FILE="$SCRIPT_DIR/provisioning/alerting/rules.yaml"

# Expected noDataState per uid, same pipe-delimited table idiom as Case 0
# above — bash-3.2/BSD-safe: no `declare -A`/`mapfile` (bash 4+ only) and no
# `\s` (GNU-grep-only) anywhere in this case.
nodatastate_table() {
    for pair in \
        "himmel_flow_truncated|NoData" \
        "himmel_flow_error|NoData" \
        "himmel_flow_stalled|KeepLast" \
        "himmel_flow_last_success_age|OK" \
        "himmel_scheduled_task_disabled|OK" \
        "himmel_agent_tree_ram_runaway|OK" \
        "himmel_orphan_processes|NoData" \
        "himmel_watcher_down|OK" \
        "example-ws_inbox_backlog_rising|OK" \
        "himmel_session_dead|NoData" \
        "himmel_kernel_pool_high|OK" \
        "himmel_kernel_pool_critical|OK" \
        "himmel_kernel_pool_leak_rate|OK" \
        "himmel_commit_pressure|OK" \
        "himmel_hook_chain_budget_pressure|NoData" \
        "himmel_hook_chain_budget_denials|NoData" \
        "himmel_hook_chain_log_unreadable|NoData"
    do
        echo "$pair"
    done
}

# Every uid actually in the file, in file order.
ACTUAL_UIDS="$(grep -oE '^[[:space:]]*- uid: [A-Za-z0-9_]+' "$RULES_FILE" | awk '{print $NF}')"

# A duplicate `- uid:` in rules.yaml is invalid for Grafana on its own, and
# left unchecked it also makes the per-uid loop below silently run the same
# uid's lookup twice — catch it here, by name, before that loop even starts
# (HIMMEL-2478/2480 CR finding 3).
DUP_UIDS="$(printf '%s\n' "$ACTUAL_UIDS" | sort | uniq -d)"
while IFS= read -r dup; do
    [ -z "$dup" ] && continue
    fail "$dup: uid appears exactly once in rules.yaml" \
        "duplicate '- uid: $dup' entries — Grafana rejects duplicate rule uids"
done <<<"$DUP_UIDS"

while IFS= read -r uid; do
    [ -z "$uid" ] && continue
    want=""
    matches=0
    while IFS='|' read -r t_uid t_want; do
        if [ "$t_uid" = "$uid" ]; then
            matches=$((matches + 1))
            want="$t_want"
        fi
    done < <(nodatastate_table)
    if [ "$matches" -gt 1 ]; then
        fail "$uid: has exactly one expected-noDataState table entry" \
            "found $matches conflicting/duplicate table entries for this uid — fix the table in this suite"
        continue
    fi
    if [ -z "$want" ]; then
        fail "$uid: has an expected-noDataState table entry" \
            "unknown uid — add it to the noDataState table in this suite before shipping"
        continue
    fi
    got="$(extract_field "$RULES_FILE" "- uid: $uid" noDataState)"
    assert_eq "$uid: noDataState is $want" "$want" "$got"
done <<<"$ACTUAL_UIDS"
# Every table entry actually appears in the file (catches a renamed/removed
# uid the table still references, the mirror-image gap of the check above).
while IFS='|' read -r t_uid _t_want; do
    found=0
    while IFS= read -r actual; do
        [ "$actual" = "$t_uid" ] && { found=1; break; }
    done <<<"$ACTUAL_UIDS"
    [ "$found" -eq 1 ] || fail "$t_uid: expected-noDataState table entry has a matching rule in rules.yaml" \
        "table references a uid not present in the file"
done < <(nodatastate_table)

# Resolves the same way restart-stack.sh's own resolve_promtool does — the
# himmel-observability-prometheus scheduled task's registered Execute path,
# then PATH — so there is one resolution story in this directory, not two
# (HIMMEL-2239 CR round-3, codex-1: this suite previously resolved via a
# LOCALAPPDATA glob instead; not a privilege boundary here the way it was in
# restart-stack.sh's own sanctioned carve-out, but keeping two resolvers in
# sync is pure upkeep for no benefit, and this one is strictly less code).
# $SCHTASKS_BIN missing (non-Windows, or an unusual station) just falls
# through to PATH and then the loud-skip below — never a hard failure.
# Loud-skip (exit 0, never a silent pass) when nothing resolves.
PROMTOOL=""
SCHTASKS_BIN="/c/Windows/System32/schtasks.exe"
if [ -x "$SCHTASKS_BIN" ]; then
    # Language-independent value-shape scan (see resolve_promtool in
    # restart-stack.sh): a Windows drive-letter path ending in
    # prometheus.exe, never the (localizable) "Task To Run:" label.
    exe_path="$("$SCHTASKS_BIN" //Query //TN himmel-observability-prometheus //V //FO LIST 2>/dev/null \
        | grep -oE '[A-Za-z]:[\\].*prometheus\.exe' | head -n 1)"
    if [ -n "$exe_path" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            posix_path="$(cygpath -u "$exe_path")"
        else
            posix_path="${exe_path//\\//}"
        fi
        task_dir="$(dirname "$posix_path")"
        for cand in "$task_dir/promtool.exe" "$task_dir/promtool"; do
            [ -x "$cand" ] && { PROMTOOL="$cand"; break; }
        done
    fi
fi
if [ -z "$PROMTOOL" ] && command -v promtool >/dev/null 2>&1; then
    PROMTOOL="promtool"
fi
if [ -z "$PROMTOOL" ]; then
    echo "SKIP: promtool not resolvable — looked at the himmel-observability-prometheus scheduled task's registered Execute path (via schtasks //Query) and then on PATH. This suite needs the real binary, not a stub; nothing to validate against on a station with no Prometheus release installed." >&2
    # Case 0 (rules parity) needs no binary and already ran above — don't let
    # a missing promtool swallow a genuine parity failure into a SKIP.
    if [ "$FAIL" -gt 0 ]; then
        echo "(but $FAIL promtool-independent check(s) already failed — not skipping the whole suite)" >&2
        summary
    fi
    exit 0
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t promtool-validate)"
# shellcheck disable=SC2329,SC2317
cleanup() { [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null; return 0; }
trap cleanup EXIT

echo "=== 1. NEGATIVE CONTROL: promtool check rules against the repo's own alerts.rules.yml -> pass ==="
"$PROMTOOL" check rules "$SCRIPT_DIR/alerts.rules.yml" >"$TMP_DIR/out1.log" 2>&1
rc1=$?
[ "$rc1" -eq 0 ] || cat "$TMP_DIR/out1.log" >&2
assert_eq "the repo's real rules file passes" "0" "$rc1"

echo "=== 2. POSITIVE CONTROL: an unparseable PromQL expr -> promtool must reject it ==="
BAD_RULES="$TMP_DIR/bad-rules.yml"
cat > "$BAD_RULES" <<'YAML'
groups:
  - name: broken
    rules:
      - alert: UnparseableExpr
        expr: rate(
YAML
"$PROMTOOL" check rules "$BAD_RULES" >"$TMP_DIR/out2.log" 2>&1
rc2=$?
# POSITIVE control: failure direction is rc2 == 0 (promtool wrongly ACCEPTED
# the broken fixture) — that is the case worth dumping the log for.
[ "$rc2" -eq 0 ] && cat "$TMP_DIR/out2.log" >&2
assert_eq "an unparseable expr is rejected (non-zero, exact code not asserted)" "true" \
    "$([ "$rc2" -ne 0 ] && echo true || echo false)"

echo "=== 3. NEGATIVE CONTROL: promtool check config against the repo's own prometheus.yml -> pass ==="
# rule_files in prometheus.yml is relative ("alerts.rules.yml"), so the
# fixture needs alerts.rules.yml copied alongside the config copy.
cp "$SCRIPT_DIR/prometheus.yml" "$TMP_DIR/prometheus.yml"
cp "$SCRIPT_DIR/alerts.rules.yml" "$TMP_DIR/alerts.rules.yml"
"$PROMTOOL" check config "$TMP_DIR/prometheus.yml" >"$TMP_DIR/out3.log" 2>&1
rc3=$?
[ "$rc3" -eq 0 ] || cat "$TMP_DIR/out3.log" >&2
assert_eq "the repo's real config passes" "0" "$rc3"

echo "=== 4. POSITIVE CONTROL: an invalid scrape_timeout value -> promtool must reject it ==="
BAD_CONFIG="$TMP_DIR/bad-config.yml"
cat > "$BAD_CONFIG" <<'YAML'
global:
  scrape_interval: 60s
scrape_configs:
  - job_name: broken
    scrape_timeout: not-a-duration
    static_configs:
      - targets:
          - 127.0.0.1:9999
YAML
"$PROMTOOL" check config "$BAD_CONFIG" >"$TMP_DIR/out4.log" 2>&1
rc4=$?
# POSITIVE control: same direction as case 2 — dump on rc4 == 0 (wrongly
# accepted), not on the rejection that is actually expected.
[ "$rc4" -eq 0 ] && cat "$TMP_DIR/out4.log" >&2
assert_eq "an invalid scrape_timeout is rejected (non-zero, exact code not asserted)" "true" \
    "$([ "$rc4" -ne 0 ] && echo true || echo false)"

echo "=== 5. alerts.rules.test.yml unit-test fixture actually runs (HIMMEL-2239: before this suite, no automated path ran it) ==="
( cd "$SCRIPT_DIR" && "$PROMTOOL" test rules alerts.rules.test.yml >"$TMP_DIR/out5.log" 2>&1 )
rc5=$?
[ "$rc5" -eq 0 ] || cat "$TMP_DIR/out5.log" >&2
assert_eq "the recorded-series unit tests pass" "0" "$rc5"

summary
