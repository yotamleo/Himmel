#!/usr/bin/env bash
# test-himmel-update-tools.sh — himmel-update.sh upgrades probe-mode station
# tools that the drift guard reads BEHIND (HIMMEL-4088).
#
# Before this ticket the updater never called apply-tool-upgrade.sh, so an
# operator running /himmel-update got "everything current" while the drift guard
# still showed rtk / twitter-cli BEHIND until the nightly cadence ran.
#
# Hermetic: the mock clone gets a STUB check-plugin-drift.sh (reads the stub
# tool's version, prints the guard's own BEHIND/CURRENT line shape), the REAL
# apply-tool-upgrade.sh (so the re-probe verdict is exercised end to end), and a
# private registry whose probe entries name fake tools on a private PATH. The
# real rtk / twitter-cli are never probed or upgraded.
#
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }
src_scripts="$(dirname "$SCRIPT")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-himmel-update-tools.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export USERPROFILE=''
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/no-claude-config"
export HERMES_HOME="$TMP/no-hermes"
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
mkdir -p "$HOME" "$HIMMELCTL_CACHE_DIR" || exit 1
unset HIMMEL_UPDATE_CHANNEL

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
has() { grep -q -- "$1" <<< "$2"; }
check_has() { if has "$2" "$3"; then assert_pass "$1"; else assert_fail "$1 — expected '$2', got: $3"; fi; }
check_lacks() { if has "$2" "$3"; then assert_fail "$1 — must not contain '$2', got: $3"; else assert_pass "$1"; fi; }
check_eq() { if [ "$2" = "$3" ]; then assert_pass "$1"; else assert_fail "$1 — expected '$2', got '$3'"; fi; }

CLONE="$TMP/clone"
mkdir -p "$CLONE/scripts/guardrails" "$CLONE/scripts/lib" "$CLONE/scripts/upstreams" || exit 1
if ! { cp "$SCRIPT" "$CLONE/scripts/himmel-update.sh" \
    && cp "$src_scripts/guardrails/lib.sh"        "$CLONE/scripts/guardrails/lib.sh" \
    && cp "$src_scripts/lib/cadence-format.sh"    "$CLONE/scripts/lib/cadence-format.sh" \
    && cp "$src_scripts/lib/resolve-hermes-py.sh" "$CLONE/scripts/lib/resolve-hermes-py.sh" \
    && cp "$src_scripts/lib/load-dotenv.sh"       "$CLONE/scripts/lib/load-dotenv.sh" \
    && cp "$src_scripts/upstreams/apply-tool-upgrade.sh" "$CLONE/scripts/upstreams/apply-tool-upgrade.sh" \
    && git init --quiet "$CLONE"; }; then
    echo "FAIL: mock clone setup" >&2
    exit 1
fi

# --check fetches the checkout's upstream first, so give it a local bare origin.
if git init --bare --quiet "$TMP/upstream.git" \
    && git -C "$CLONE" config user.email test@test.test \
    && git -C "$CLONE" config user.name Test \
    && git -C "$CLONE" remote add origin "$TMP/upstream.git" \
    && git -C "$CLONE" commit --quiet --allow-empty -m init \
    && git -C "$CLONE" push --quiet origin HEAD 2>/dev/null \
    && git -C "$CLONE" branch --quiet -u "origin/$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)"; then
    :
else
    echo "FAIL: mock origin setup" >&2; exit 1
fi

STATE="$TMP/state"     # one file per fake tool: its installed version
BIN="$TMP/bin"
LOG="$TMP/upgrade.log"
mkdir -p "$STATE" "$BIN" || exit 1

# Fake tools: `<tool> --version` prints the version in $STATE/<tool>.
# `<tool>-up` is the upgrade command: it appends to $LOG and, unless
# $STATE/<tool>.fail exists, moves the version to $STUB_LATEST (rc 0); with
# .fail it exits 1 and leaves the version where it was.
for t in alpha beta; do
    printf '#!/bin/sh\ncat "%s/%s"\n' "$STATE" "$t" > "$BIN/$t"
    # shellcheck disable=SC2016 # $STUB_LATEST must expand when the stub runs
    printf '#!/bin/sh\necho "%s-up ran" >> "%s"\n[ -f "%s/%s.fail" ] && exit 1\nprintf "%%s\\n" "$STUB_LATEST" > "%s/%s"\n' \
        "$t" "$LOG" "$STATE" "$t" "$STATE" "$t" > "$BIN/$t-up"
    chmod +x "$BIN/$t" "$BIN/$t-up"
done

# Stub drift guard: same output shape as the real one for tag_release/probe rows.
cat > "$CLONE/scripts/check-plugin-drift.sh" <<'EOF'
#!/usr/bin/env bash
for t in alpha beta; do
    inst=$(cat "$STATE_DIR/$t")
    if [ "$inst" = "$STUB_LATEST" ]; then
        echo "  $t: CURRENT  (installed $inst = acme/$t latest tag)  [A]"
    else
        echo "  $t: BEHIND   (acme/$t latest tag v$STUB_LATEST; installed $inst — upgrade)  [A]"
    fi
done
exit 0
EOF
chmod +x "$CLONE/scripts/check-plugin-drift.sh"

# write_registry <alpha-unattended> <beta-unattended>
write_registry() {
    cat > "$TMP/registry.json" <<EOF
{"entries":[
 {"name":"alpha","kind":"tag_release","mode":"probe","tracked_repo":"acme/alpha",
  "version_command":"alpha --version","version_regex":"[0-9]+\\\\.[0-9]+\\\\.[0-9]+","tier":"A",
  "upgrade":{"command":["alpha-up"],"unattended":$1}},
 {"name":"beta","kind":"tag_release","mode":"probe","tracked_repo":"acme/beta",
  "version_command":"beta --version","version_regex":"[0-9]+\\\\.[0-9]+\\\\.[0-9]+","tier":"A",
  "upgrade":{"command":["beta-up"],"unattended":$2}},
 {"name":"gamma","kind":"tag_release","mode":"probe","tracked_repo":"acme/gamma",
  "version_command":"gamma --version","version_regex":"[0-9]+\\\\.[0-9]+\\\\.[0-9]+","tier":"A"},
 {"name":"delta","kind":"tag_release","mode":"base","tracked_repo":"acme/delta","synced_base":"1.0.0","tier":"A"}
]}
EOF
}

# reset <alpha-ver> <beta-ver>
reset() {
    rm -f "$STATE"/*.fail "$LOG"
    printf '%s\n' "$1" > "$STATE/alpha"
    printf '%s\n' "$2" > "$STATE/beta"
}

# run <flags...> — output in $OUT, rc in $RC.
run() {
    RC=0
    OUT="$(cd "$CLONE" && PATH="$BIN:/usr/bin:/bin" STATE_DIR="$STATE" STUB_LATEST="2.0.0" \
        DRIFT_REGISTRY="$TMP/registry.json" bash scripts/himmel-update.sh "$@" 2>&1)" || RC=$?
}
ran() { if [ -f "$LOG" ]; then cat "$LOG"; fi; }

echo "--only tools: a BEHIND unattended tool is upgraded and re-probed"
write_registry true true
reset 1.0.0 2.0.0
run --only tools
check_eq  "rc 0" 0 "$RC"
check_has "alpha updated row" 'alpha .*updated' "$OUT"
check_has "row shows the version move" '1\.0\.0 -> 2\.0\.0' "$OUT"
check_eq  "upgrade command ran once, for alpha only" "alpha-up ran" "$(ran)"
check_eq  "the installed version really moved" "2.0.0" "$(cat "$STATE/alpha")"
check_has "beta (already current) is up-to-date" 'beta .*up-to-date' "$OUT"
check_lacks "gamma (no upgrade block) is not a row" 'gamma' "$OUT"
check_lacks "delta (base mode) is not a row" 'delta' "$OUT"

echo "--only tools: everything current is a no-op"
reset 2.0.0 2.0.0
run --only tools
check_eq  "rc 0" 0 "$RC"
check_eq  "no upgrade command ran" "" "$(ran)"
check_has "alpha up-to-date" 'alpha .*up-to-date' "$OUT"

echo "--only tools: unattended:false prints the manual command and runs nothing"
write_registry false true
reset 1.0.0 2.0.0
run --only tools
check_eq  "rc 0" 0 "$RC"
check_eq  "gated tool was NOT upgraded" "" "$(ran)"
check_eq  "installed version untouched" "1.0.0" "$(cat "$STATE/alpha")"
check_has "alpha skipped" 'alpha .*skipped' "$OUT"
check_has "prints the one-command manual upgrade" 'bash scripts/upstreams/apply-tool-upgrade.sh alpha 2.0.0' "$OUT"

echo "an upgrade failure does not abort the rest"
write_registry true true
reset 1.0.0 1.0.0
: > "$STATE/alpha.fail"
run --only tools
check_has "alpha failed row" 'alpha .*failed' "$OUT"
check_has "beta still upgraded after alpha failed" 'beta .*updated' "$OUT"
check_eq  "both upgrade commands ran" "alpha-up ran
beta-up ran" "$(ran)"
check_eq  "--only reports the failure in its exit code" 1 "$RC"

echo "--check: reports behind, runs no upgrade"
write_registry true true
reset 1.0.0 2.0.0
run --check
check_has "alpha shown as available" 'alpha .*skipped.*update available' "$OUT"
check_eq  "no upgrade ran" "" "$(ran)"
check_eq  "installed version untouched" "1.0.0" "$(cat "$STATE/alpha")"

echo "--versions: a behind probe tool shows as behind and drives rc 1"
reset 1.0.0 2.0.0
run --versions
check_has "alpha behind row" 'alpha .*behind.*1\.0\.0.*2\.0\.0' "$OUT"
check_has "beta current row" 'beta .*current' "$OUT"
check_eq  "rc 1 (something behind)" 1 "$RC"
check_eq  "no upgrade ran" "" "$(ran)"

echo "--versions: all current"
reset 2.0.0 2.0.0
run --versions
check_lacks "no behind tool row" 'alpha .*behind' "$OUT"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
