#!/usr/bin/env bash
# Smoke test for scripts/setup/cli-proxy-lane.sh (HIMMEL-2778).
#
# Usage: bash scripts/setup/test-cli-proxy-lane.sh
#
# Scope (deliberately narrow — the .sh has no -AsLibrary seam like the .ps1
# twin, so every real system call is shadowed via a per-test PATH-prepended
# stub dir; HOME is redirected per test so nothing touches the real
# ~/.cli-proxy-api). Covers exactly what HIMMEL-2778 asked for, no more:
#   1. --install writes config with the loopback host + port
#   2. CLIPROXY_API_KEY is sourced from env only (unset + no .env -> refuses)
#   3. --register's unit-file shape (grepped; the unit is never really loaded)
#   4. --status parses a stubbed /v1/models (green path)
#   5. --verify on a stubbed-down proxy (RED control: proves the harness
#      catches a failing probe, not just the 200 happy path)
#   6/7. bounce-safety refuses --stop / --restart when ss reports an
#        ESTABLISHED connection on the proxy port
#   8. --stop is a no-op (rc=0) when nothing is running
#
# Exit codes: 0 all passed, 1 at least one failed.
#
# shellcheck disable=SC2016  # every make_stub body below is single-quoted on
# purpose: it must expand at STUB-RUNTIME (when the stubbed command actually
# runs inside cli-proxy-lane.sh), never at write-time here.
set -uo pipefail

# grepq <text> [grep-args...] — see test-check-jira-key.sh HIMMEL-1430 for why
# this avoids a `printf | grep -q` pipeline under `set -o pipefail`.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/cli-proxy-lane.sh"
STUB_SHA256="$(sed -n 's/^ASSET_SHA256="\(.*\)"$/\1/p' "$SCRIPT")"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_rc() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then pass "$name (rc=$actual)"; else fail "$name" "expected rc=$expected, got rc=$actual"; fi
}
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-cli-proxy-lane.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

STUBBIN="$TMPROOT/stubbin"
mkdir -p "$STUBBIN"

# make_stub <name> <body> — writes an executable shell stub into STUBBIN.
make_stub() {
    local name="$1" body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$STUBBIN/$name"
    chmod +x "$STUBBIN/$name"
}

# curl: -w '%{http_code}' present -> probe mode (echoes $STUB_HTTP_CODE);
# otherwise -> download mode (writes dummy bytes to the -o target).
make_stub curl '
for a in "$@"; do [ "$a" = "%{http_code}" ] && { printf "%s" "${STUB_HTTP_CODE:-000}"; exit 0; }; done
out="" prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && [ "$out" != "/dev/null" ] && printf "stub-asset" > "$out"
exit 0
'

# sha256sum: always reports the pinned constant, so a stubbed download
# "matches" without needing a real release asset.
make_stub sha256sum 'printf "%s  %s\n" "${STUB_SHA256:?}" "${1:-stub}"'

# tar: ignores the archive, just materializes cli-proxy-api under -C's dir.
make_stub tar '
dir="." prev=""
for a in "$@"; do [ "$prev" = "-C" ] && dir="$a"; prev="$a"; done
printf "#!/bin/sh\n" > "$dir/cli-proxy-api"
chmod +x "$dir/cli-proxy-api"
'

# systemctl: logs every invocation to $STUB_SYSTEMCTL_LOG; is-active prints
# $STUB_SYSTEMCTL_STATE (default: inactive) and exits $STUB_SYSTEMCTL_ACTIVE
# (default: 1, matching a real "inactive"/"activating" exit); is-enabled
# exits $STUB_SYSTEMCTL_ENABLED (default: not enabled); show --property=MainPID
# --value prints $STUB_SYSTEMCTL_MAINPID (default: empty, i.e. "no such
# process" -- unit_owns_port must see this as "can't confirm ownership").
# Everything else (daemon-reload, enable --now, start, stop) is a logged
# no-op success. Never touches real systemd.
make_stub systemctl '
[ -n "${STUB_SYSTEMCTL_LOG:-}" ] && printf "%s\n" "$*" >> "$STUB_SYSTEMCTL_LOG"
case " $* " in
  *" is-active "*) printf "%s\n" "${STUB_SYSTEMCTL_STATE:-inactive}"; exit "${STUB_SYSTEMCTL_ACTIVE:-1}" ;;
  *" is-enabled "*) exit "${STUB_SYSTEMCTL_ENABLED:-1}" ;;
  *" show "*"--property=MainPID"*) printf "%s\n" "${STUB_SYSTEMCTL_MAINPID:-}"; exit 0 ;;
  *) exit 0 ;;
esac
'

make_stub loginctl 'exit 0'

# uname: reports $STUB_UNAME_M for -m (default: x86_64, the supported arch).
make_stub uname '[ "${1:-}" = "-m" ] && { printf "%s\n" "${STUB_UNAME_M:-x86_64}"; exit 0; }; exit 1'

# ss: two shapes, distinguished by "state" being one of the args --
# the ESTABLISHED-client bounce-safety query (-Htn state established ...,
# reports one ESTAB line iff $STUB_SS_ESTABLISHED=1) and the
# listening-socket-owner query used by unit_owns_port (-Htlnp ..., reports a
# LISTEN line naming pid=$STUB_SS_LISTEN_PID, or nothing if unset -- "can't
# find who's listening").
make_stub ss '
case " $* " in
  *" state "*)
    [ "${STUB_SS_ESTABLISHED:-0}" = "1" ] && echo "ESTAB 0 0 127.0.0.1:8317 127.0.0.1:9"
    exit 0
    ;;
  *)
    if [ -n "${STUB_SS_LISTEN_PID:-}" ]; then
      printf "LISTEN 0 128 127.0.0.1:8317 0.0.0.0:%s users:((\"cli-proxy-api\",pid=%s,fd=3))\n" "*" "$STUB_SS_LISTEN_PID"
    fi
    exit 0
    ;;
esac
'

# pgrep: reports $STUB_PGREP_PID (a real PID, so kill/kill -0 in the code
# under test act on something real) when set; otherwise never finds a bare
# (unregistered) proxy process.
make_stub pgrep '[ -n "${STUB_PGREP_LOG:-}" ] && printf "%s\n" "$*" >> "$STUB_PGREP_LOG"; [ -n "${STUB_PGREP_PID:-}" ] && { echo "$STUB_PGREP_PID"; exit 0; }; exit 1'

EMPTY_ENV_ROOT="$TMPROOT/no-dotenv-here"
mkdir -p "$EMPTY_ENV_ROOT"

OUT=""
RC=0
run() { RC=0; OUT=$(CLI_PROXY_LANE_DOTENV_ROOT="$EMPTY_ENV_ROOT" PATH="$STUBBIN:$PATH" bash "$SCRIPT" "$@" 2>&1) || RC=$?; }

fixture() {
    # fixture <name> [--with-exe-config] [--with-oauth]
    local dir="$TMPROOT/$1"
    mkdir -p "$dir/.cli-proxy-api"
    shift
    for opt in "$@"; do
        case "$opt" in
            --with-exe-config)
                printf '#!/bin/sh\n' > "$dir/.cli-proxy-api/cli-proxy-api"
                chmod +x "$dir/.cli-proxy-api/cli-proxy-api"
                printf 'host: "127.0.0.1"\nport: 8317\n' > "$dir/.cli-proxy-api/config.yaml"
                ;;
            --with-oauth)
                printf '{}' > "$dir/.cli-proxy-api/codex-stub@example.com.json"
                ;;
        esac
    done
    printf '%s' "$dir"
}

echo "TEST 1: --install writes config with the loopback host + port"
F1="$(fixture install)"
HOME="$F1" CLIPROXY_API_KEY="stub-key-1" STUB_SHA256="$STUB_SHA256" run --install
assert_rc "install exit code" 0 "$RC"
CFG1="$F1/.cli-proxy-api/config.yaml"
if [ -f "$CFG1" ]; then
    CFG1_BODY="$(cat "$CFG1")"
    assert_contains "config pins loopback host" 'host: "127.0.0.1"' "$CFG1_BODY"
    assert_contains "config pins the port" "port: 8317" "$CFG1_BODY"
    assert_contains "config carries the env key" '- "stub-key-1"' "$CFG1_BODY"
    # gnu-ok: this suite is Linux-only in scope (see header) -- stubs systemctl/ss/loginctl
    MODE1="$(stat -c '%a' "$CFG1" 2>/dev/null)"
    assert_rc "config mode is 0600" "600" "$MODE1"
else
    fail "config.yaml was written" "not found at $CFG1"
fi
if [ -x "$F1/.cli-proxy-api/cli-proxy-api" ]; then pass "binary installed executable"; else fail "binary installed executable"; fi

echo "TEST 2: CLIPROXY_API_KEY is sourced from env only -> unset + no .env refuses --install"
F2="$(fixture install2)"
RC=0
OUT=$(HOME="$F2" CLI_PROXY_LANE_DOTENV_ROOT="$EMPTY_ENV_ROOT" PATH="$STUBBIN:$PATH" \
    env -u CLIPROXY_API_KEY bash "$SCRIPT" --install 2>&1) || RC=$?
assert_rc "unset-key install exit code" 1 "$RC"
assert_contains "unset-key error names the var" "CLIPROXY_API_KEY is not set" "$OUT"
if [ ! -f "$F2/.cli-proxy-api/config.yaml" ]; then pass "no config written without a key"; else fail "no config written without a key"; fi

echo "TEST 3: --register's unit-file shape (grepped only; systemd is stubbed)"
F3="$(fixture register --with-exe-config)"
SVC_LOG="$TMPROOT/systemctl-3.log"
HOME="$F3" STUB_SYSTEMCTL_LOG="$SVC_LOG" STUB_HTTP_CODE="200" STUB_SYSTEMCTL_STATE="active" STUB_SYSTEMCTL_ACTIVE="0" STUB_SYSTEMCTL_MAINPID="1234" STUB_SS_LISTEN_PID="1234" run --register
assert_rc "register exit code" 0 "$RC"
UNIT3="$F3/.config/systemd/user/cli-proxy-api.service"
if [ -f "$UNIT3" ]; then
    UNIT3_BODY="$(cat "$UNIT3")"
    assert_contains "unit ExecStart names the exe + config" "ExecStart=\"$F3/.cli-proxy-api/cli-proxy-api\" -config \"$F3/.cli-proxy-api/config.yaml\"" "$UNIT3_BODY"
    assert_contains "unit restarts on failure" "Restart=on-failure" "$UNIT3_BODY"
    assert_contains "unit installs at default.target" "WantedBy=default.target" "$UNIT3_BODY"
else
    fail "unit file was written" "not found at $UNIT3"
fi
SVC3_BODY="$([ -f "$SVC_LOG" ] && cat "$SVC_LOG" || echo '')"
assert_contains "register reloads the daemon" "daemon-reload" "$SVC3_BODY"
assert_contains "register enables + starts the unit (never a raw systemd load)" "enable --now cli-proxy-api.service" "$SVC3_BODY"
assert_contains "register confirms readiness before reporting started" "registered + started" "$OUT"

echo "TEST 4: --status parses a stubbed healthy /v1/models"
F4="$(fixture status --with-exe-config --with-oauth)"
HOME="$F4" STUB_HTTP_CODE="200" STUB_SYSTEMCTL_ENABLED="0" run --status
assert_rc "status exit code (all green)" 0 "$RC"
assert_contains "status reports the proxy running" "running:     OK" "$OUT"
assert_contains "status reports codex auth present" "codex auth:  OK" "$OUT"

echo "TEST 5 (RED control): --verify on a stubbed-down proxy is caught, not masked"
F5="$(fixture verify)"
HOME="$F5" STUB_HTTP_CODE="000" run --verify
assert_rc "verify exit code on a down proxy" 1 "$RC"
assert_contains "verify prints the observed code" "-> HTTP 000" "$OUT"

echo "TEST 6: bounce-safety refuses --stop when ss reports an ESTABLISHED client"
F6="$(fixture stop --with-exe-config)"
HOME="$F6" STUB_SS_ESTABLISHED="1" run --stop
assert_rc "stop refusal exit code" 1 "$RC"
assert_contains "stop refusal names the reason" "refusing proxy bounce" "$OUT"
assert_contains "stop refusal names an active client" "actively connected" "$OUT"

echo "TEST 7: bounce-safety refuses --restart when ss reports an ESTABLISHED client"
F7="$(fixture restart --with-exe-config)"
HOME="$F7" STUB_SS_ESTABLISHED="1" run --restart
assert_rc "restart refusal exit code" 1 "$RC"
assert_contains "restart refusal names the reason" "refusing proxy bounce" "$OUT"

echo "TEST 8: --stop is a no-op when nothing is running"
F8="$(fixture stop-idle --with-exe-config)"
HOME="$F8" STUB_SS_ESTABLISHED="0" STUB_SYSTEMCTL_ACTIVE="1" run --stop
assert_rc "idle stop exit code" 0 "$RC"
assert_contains "idle stop says nothing to stop" "nothing to stop" "$OUT"

echo "TEST 9: --stop reaches a unit stuck in 'activating' (auto-restart armed, no process yet)"
F9="$(fixture stop-activating --with-exe-config)"
SVC_LOG9="$TMPROOT/systemctl-9.log"
HOME="$F9" STUB_SYSTEMCTL_LOG="$SVC_LOG9" STUB_SS_ESTABLISHED="0" STUB_SYSTEMCTL_STATE="activating" STUB_SYSTEMCTL_ACTIVE="3" run --stop
assert_rc "activating stop exit code" 0 "$RC"
assert_contains "activating stop actually stops (not 'nothing to stop')" "stopped." "$OUT"
SVC9_BODY="$([ -f "$SVC_LOG9" ] && cat "$SVC_LOG9" || echo '')"
assert_contains "activating stop issues systemctl stop" "stop cli-proxy-api.service" "$SVC9_BODY"

echo "TEST 10: --status flags a reachable-but-unauthenticated proxy (HTTP 401) as not fully OK"
F10="$(fixture status-401 --with-exe-config --with-oauth)"
HOME="$F10" STUB_HTTP_CODE="401" STUB_SYSTEMCTL_ENABLED="0" run --status
assert_rc "401 status exit code (not fully OK)" 1 "$RC"
assert_contains "401 status names the mismatch" "UNAUTHENTICATED" "$OUT"

echo "TEST 11: --install refuses an unsupported architecture (only linux_amd64 is pinned+verified)"
F11="$(fixture install-arm64)"
HOME="$F11" CLIPROXY_API_KEY="stub-key-11" STUB_SHA256="$STUB_SHA256" STUB_UNAME_M="aarch64" run --install
assert_rc "arm64 install exit code" 1 "$RC"
assert_contains "arm64 install names the unsupported arch" "unsupported architecture 'aarch64'" "$OUT"
if [ ! -f "$F11/.cli-proxy-api/config.yaml" ]; then pass "no config written on unsupported arch"; else fail "no config written on unsupported arch"; fi

echo "TEST 12 (RED control): --register refuses to claim success when something else answers the port"
F12="$(fixture register-mismatch --with-exe-config)"
HOME="$F12" STUB_HTTP_CODE="200" STUB_SYSTEMCTL_STATE="active" STUB_SYSTEMCTL_ACTIVE="0" STUB_SYSTEMCTL_MAINPID="1234" STUB_SS_LISTEN_PID="9999" run --register
assert_rc "port-mismatch register exit code" 1 "$RC"
assert_contains "port-mismatch register names the ownership mismatch" "isn't the one listening there" "$OUT"

echo "TEST 13 (RED control): --restart refuses to claim success when something else answers the port"
F13="$(fixture restart-mismatch --with-exe-config)"
HOME="$F13" STUB_HTTP_CODE="200" STUB_SYSTEMCTL_ENABLED="0" STUB_SYSTEMCTL_STATE="active" STUB_SYSTEMCTL_ACTIVE="0" STUB_SYSTEMCTL_MAINPID="1234" STUB_SS_LISTEN_PID="9999" run --restart
assert_rc "port-mismatch restart exit code" 1 "$RC"
assert_contains "port-mismatch restart names the ownership mismatch" "isn't the one listening there" "$OUT"

echo "TEST 14 (RED control): detached --restart (no registered unit) refuses to claim success when something else answers the port"
F14="$(fixture restart-detached-mismatch --with-exe-config)"
HOME="$F14" STUB_HTTP_CODE="200" STUB_SS_LISTEN_PID="424242" run --restart
assert_rc "detached port-mismatch restart exit code" 1 "$RC"
assert_contains "detached port-mismatch restart names the launched pid" "process this --restart just launched" "$OUT"

echo "TEST 15: --stop also kills a leftover standalone process even when the unit itself was already stopped"
F15="$(fixture stop-standalone --with-exe-config)"
sleep 60 &
LEFTOVER_PID=$!
HOME="$F15" STUB_PGREP_PID="$LEFTOVER_PID" STUB_SYSTEMCTL_STATE="active" STUB_SYSTEMCTL_ACTIVE="0" run --stop
assert_rc "standalone-leftover stop exit code" 0 "$RC"
if kill -0 "$LEFTOVER_PID" 2>/dev/null; then
    fail "leftover standalone process was killed too"
    kill "$LEFTOVER_PID" 2>/dev/null
else
    pass "leftover standalone process was killed too"
fi

echo "TEST 16 (RED control): --install refuses a CLIPROXY_API_KEY containing a newline"
F16="$(fixture install-newline-key)"
HOME="$F16" CLIPROXY_API_KEY="$(printf 'bad\nkey')" STUB_SHA256="$STUB_SHA256" run --install
assert_rc "newline-key install exit code" 1 "$RC"
assert_contains "newline-key error names the reason" "newline or carriage-return" "$OUT"
if [ ! -f "$F16/.cli-proxy-api/config.yaml" ]; then pass "no config written with a newline key"; else fail "no config written with a newline key"; fi

echo "TEST 17: proxy_pid's pgrep pattern matches the server command line but not an in-progress --login"
F17="$(fixture stop-login-safe --with-exe-config)"
PGREP_LOG="$TMPROOT/pgrep-17.log"
HOME="$F17" STUB_PGREP_LOG="$PGREP_LOG" STUB_SYSTEMCTL_STATE="inactive" STUB_SYSTEMCTL_ACTIVE="1" run --stop
assert_rc "stop-login-safe exit code" 0 "$RC"
PGREP_PATTERN="$(tail -n1 "$PGREP_LOG" 2>/dev/null | sed -n 's/^-f //p')"
if [ -z "$PGREP_PATTERN" ]; then
    fail "captured a pgrep -f pattern" "pgrep was not invoked"
else
    SERVER_LINE="$F17/.cli-proxy-api/cli-proxy-api -config $F17/.cli-proxy-api/config.yaml"
    LOGIN_LINE="$SERVER_LINE -codex-device-login"
    if grepq "$SERVER_LINE" -E "$PGREP_PATTERN"; then
        pass "pattern matches the server's own command line"
    else
        fail "pattern matches the server's own command line" "no match against: $SERVER_LINE"
    fi
    if grepq "$LOGIN_LINE" -E "$PGREP_PATTERN"; then
        fail "pattern does not match an in-progress --login" "matched: $LOGIN_LINE"
    else
        pass "pattern does not match an in-progress --login"
    fi
fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
