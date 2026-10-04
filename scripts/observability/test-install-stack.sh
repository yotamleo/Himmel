#!/usr/bin/env bash
# Suite for scripts/observability/install-stack.sh (HIMMEL-4288): the
# Linux/macOS flow-exporter user service. Every external tool the installer
# drives — uname, systemctl, launchctl, curl, bun, crontab, sleep — is a
# PATH stub (test-restart-stack.sh convention), and HOME points at a
# throwaway tree, so no case touches a real service manager or real unit dir.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/install-stack.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
assert_contains() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing '$2' in: $3" ;; esac
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/himmel-install-stack-test.XXXXXX")" || exit 1
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null; return 0; }
trap cleanup EXIT

# setup <uname-s> <healthz-code> <metrics-code> <cron-armed:0|1>
setup() {
    local case_dir="$TMP_ROOT/$RANDOM$RANDOM"
    BIN="$case_dir/bin"; HOME_DIR="$case_dir/home"; LOG="$case_dir/calls.log"
    mkdir -p "$BIN" "$HOME_DIR"; : > "$LOG"
    printf '#!/bin/sh\necho %s\n' "$1" > "$BIN/uname"
    printf '#!/bin/sh\necho "systemctl $*" >> "%s"\n' "$LOG" > "$BIN/systemctl"
    printf '#!/bin/sh\necho "launchctl $*" >> "%s"\n' "$LOG" > "$BIN/launchctl"
    printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
    printf '#!/bin/sh\nexit 0\n' > "$BIN/bun"
    cat > "$BIN/curl" <<EOF
#!/bin/sh
for a in "\$@"; do url="\$a"; done
case "\$url" in
    */healthz) printf '%s' "$2" ;;
    */metrics) printf '%s' "$3" ;;
    *) printf '000' ;;
esac
EOF
    if [ "$4" = 1 ]; then
        printf '#!/bin/sh\necho "17 9 * * * bash runner # HIMMEL-Doctor"\n' > "$BIN/crontab"
    else
        printf '#!/bin/sh\nexit 0\n' > "$BIN/crontab"
    fi
    chmod +x "$BIN"/*
}

run() {
    OUT="$(env -u XDG_CONFIG_HOME HOME="$HOME_DIR" PATH="$BIN:${RUN_PATH:-/usr/bin:/bin}" bash "$SCRIPT" "$@" 2>&1)"
    RC=$?
}

UNIT_REL=".config/systemd/user/himmel-flow-exporter.service"
PLIST_REL="Library/LaunchAgents/himmel-flow-exporter.plist"

echo "case 1: linux install writes + enables the systemd user unit"
setup Linux 200 200 1
run install
assert_eq "linux install rc" 0 "$RC"
unit="$(cat "$HOME_DIR/$UNIT_REL" 2>/dev/null)"
assert_contains "unit ExecStart runs flow-exporter.ts via bun" "ExecStart=\"$BIN/bun\" run " "$unit"
assert_contains "unit names flow-exporter.ts" "scripts/observability/flow-exporter.ts\"" "$unit"
assert_contains "unit wanted by default.target" "WantedBy=default.target" "$unit"
calls="$(cat "$LOG")"
assert_contains "daemon-reload" "systemctl --user daemon-reload" "$calls"
assert_contains "enable" "systemctl --user enable himmel-flow-exporter.service" "$calls"
assert_contains "restart" "systemctl --user restart himmel-flow-exporter.service" "$calls"
assert_contains "health reported" "/healthz" "$OUT"

echo "case 2: linux install with an exporter that never answers fails"
setup Linux 000 000 1
run install
assert_eq "unhealthy install rc" 1 "$RC"
assert_contains "names the journal" "journalctl --user -u himmel-flow-exporter" "$OUT"

echo "case 3: /healthz 404 falls back to /metrics"
setup Linux 404 200 1
run install
assert_eq "fallback install rc" 0 "$RC"
assert_contains "fallback named" "/metrics" "$OUT"

echo "case 4: macOS install writes + bootstraps the launchd agent"
setup Darwin 200 200 1
run install
assert_eq "darwin install rc" 0 "$RC"
plist="$(cat "$HOME_DIR/$PLIST_REL" 2>/dev/null)"
assert_contains "plist label" "<string>himmel-flow-exporter</string>" "$plist"
assert_contains "plist runs bun" "<string>$BIN/bun</string>" "$plist"
assert_contains "plist KeepAlive" "<key>KeepAlive</key>" "$plist"
calls="$(cat "$LOG")"
assert_contains "bootstrap" "launchctl bootstrap gui/$(id -u) $HOME_DIR/$PLIST_REL" "$calls"
assert_contains "enable" "launchctl enable gui/$(id -u)/himmel-flow-exporter" "$calls"

echo "case 5: status — enabled + healthy + cadence armed is green"
setup Linux 200 200 1
run status
assert_eq "status rc green" 0 "$RC"
assert_contains "service line" "OK   service" "$OUT"
assert_contains "health line" "OK   health" "$OUT"
assert_contains "cadence line" "OK   doctor-cadence" "$OUT"

echo "case 6: status — doctor cadence not armed is red"
setup Linux 200 200 0
run status
assert_eq "status rc red" 1 "$RC"
assert_contains "cadence fail" "FAIL doctor-cadence" "$OUT"

echo "case 7: uninstall removes the unit"
setup Linux 200 200 1
run install
run uninstall
assert_eq "uninstall rc" 0 "$RC"
if [ -e "$HOME_DIR/$UNIT_REL" ]; then fail "unit removed"; else pass "unit removed"; fi
assert_contains "disable" "systemctl --user disable --now himmel-flow-exporter.service" "$(cat "$LOG")"

echo "case 8: Windows shells are pointed at install-stack.ps1"
setup MINGW64_NT-10.0 200 200 1
run install
assert_eq "windows rc" 2 "$RC"
assert_contains "points at ps1" "install-stack.ps1" "$OUT"

echo "case 9: missing bun fails before writing anything"
setup Linux 200 200 1
rm -f "$BIN/bun"
# a system-installed bun must not rescue the negative control: expose every
# system tool except bun through a private dir
SYSBIN="$BIN/../sysbin"; mkdir -p "$SYSBIN"
for f in /usr/bin/* /bin/*; do
    [ "${f##*/}" = bun ] || ln -sf "$f" "$SYSBIN/${f##*/}" 2>/dev/null
done
RUN_PATH="$SYSBIN" run install
unset RUN_PATH
assert_eq "no-bun rc" 1 "$RC"
if [ -e "$HOME_DIR/$UNIT_REL" ]; then fail "no unit without bun"; else pass "no unit without bun"; fi

echo "case 10: uninstall fails loudly when the service manager cannot stop a registered unit"
setup Linux 200 200 1
run install
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$2" in disable) exit 1;; esac\n' > "$BIN/systemctl"
run uninstall
assert_eq "linux uninstall rc on disable failure" 1 "$RC"
if [ -e "$HOME_DIR/$UNIT_REL" ]; then pass "unit kept when disable failed"; else fail "unit kept when disable failed"; fi

echo "case 11: uninstall with nothing installed is a clean no-op"
setup Linux 200 200 1
printf '#!/bin/sh\nexit 1\n' > "$BIN/systemctl"
run uninstall
assert_eq "uninstall nothing rc" 0 "$RC"

echo "case 12: macOS uninstall fails loudly when bootout fails on a loaded agent"
setup Darwin 200 200 1
run install
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in bootout) exit 1;; esac\nexit 0\n' > "$BIN/launchctl"
run uninstall
assert_eq "mac uninstall rc on bootout failure" 1 "$RC"
if [ -e "$HOME_DIR/$PLIST_REL" ]; then pass "plist kept when bootout failed"; else fail "plist kept when bootout failed"; fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
