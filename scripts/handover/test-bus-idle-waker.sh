#!/usr/bin/env bash
# test-bus-idle-waker.sh — scripts/handover/bus-idle-waker.sh: a bus message or
# an inbox line for an idle session injects ONE fixed prompt, never content.
# shellcheck disable=SC2015,SC2016  # pass/fail chains and a literal injection fixture
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WAKER="$HERE/bus-idle-waker.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bus-waker.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
export HANDOVER_DIR="$tmp/handovers"
mkdir -p "$HANDOVER_DIR/inbox/.cursor"

# Fake qdbus6 records its argv, one call per line; fake bus prints $BUS_N.
cat > "$tmp/qdbus" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QLOG"
EOF
cat > "$tmp/bus" <<'EOF'
#!/usr/bin/env bash
[ "$1" = unread ] && printf '%s\n' "${BUS_N:-0}"
EOF
chmod +x "$tmp/qdbus" "$tmp/bus"
export QLOG="$tmp/qlog"
FIXED='You have 2 unread himmel messages: read them now.'

run() { # run <polls> <grace> [extra args]; env BUS_N / inbox decide the count
  local polls="$1" grace="$2"; shift 2
  : > "$QLOG"
  BUS_WAKER_QDBUS="$tmp/qdbus" BUS_WAKER_BUS="$tmp/bus" \
    bash "$WAKER" --name legX --service org.kde.konsole-1 --session /Sessions/3 \
    --poll 0.2 --grace "$grace" --rewake 100 --max-polls "$polls" "$@" >/dev/null 2>&1
  RUN_RC=$?
}

echo "== waker =="
BUS_N=0 run 4 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "nothing unread: nothing sent" || fail "nothing unread but sent: $(cat "$QLOG")"

BUS_N=2 run 3 60
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "unread inside the grace window (hook may still deliver): nothing sent" || fail "sent inside grace"

BUS_N=2 run 8 0.5
n=$(grep -c sendText "$QLOG")
[ "$RUN_RC" -eq 0 ] && [ "$n" -eq 1 ] && pass "unread past grace: exactly one prompt (rewake holds the next)" || fail "wanted 1 sendText, got $n"
grep -qF "org.kde.konsole-1 /Sessions/3 org.kde.konsole.Session.sendText ${FIXED}"$'\r' "$QLOG" \
  && pass "the injected text is the fixed sentence plus Enter" || fail "text differs: $(cat -A "$QLOG")"

BUS_N=abc run 6 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a non-numeric count sends nothing" || fail "non-numeric count sent"

# Content never travels: an inbox line carrying a command is counted, not typed.
printf 'from=con $(touch %s/pwned); rm -rf ~\n' "$tmp" > "$HANDOVER_DIR/inbox/legX.md"
printf '0' > "$HANDOVER_DIR/inbox/.cursor/legX"
BUS_N=0 run 8 0.5
if grep -qF 'You have 1 unread himmel messages: read them now.' "$QLOG" && ! grep -q -e 'pwned' -e 'rm -rf' "$QLOG" && [ ! -e "$tmp/pwned" ]; then
  pass "inbox line wakes with the fixed text only, never its content"
else fail "inbox wake: $(cat "$QLOG")"; fi

# A consumed inbox line (cursor at EOF) wakes nothing.
wc -c < "$HANDOVER_DIR/inbox/legX.md" | tr -d ' \n' > "$HANDOVER_DIR/inbox/.cursor/legX"
BUS_N=0 run 4 0
[ "$RUN_RC" -eq 0 ] && [ ! -s "$QLOG" ] && pass "a consumed inbox line sends nothing" || fail "consumed inbox woke"

# Exit when the konsole session is gone (fail-safe: no endless loop).
cat > "$tmp/qdbus-dead" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/qdbus-dead"
BUS_N=2 BUS_WAKER_QDBUS="$tmp/qdbus-dead" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name legX --service s --session /S --poll 0.2 --grace 0 --rewake 0 --max-polls 50 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && pass "a dead session ends the waker with rc=1" || fail "dead session: expected rc=1, got rc=$rc"

# A window started before EnableSecuritySensitiveDBusAPI refuses sendText: named, rc=3.
cat > "$tmp/qdbus-denied" <<'EOF'
#!/usr/bin/env bash
printf 'Error: org.freedesktop.DBus.Error.AccessDenied\nSecurity sensitive DBus API is disabled in the settings.\n' >&2
exit 2
EOF
chmod +x "$tmp/qdbus-denied"
BUS_N=2 BUS_WAKER_QDBUS="$tmp/qdbus-denied" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name legX --service s --session /S --poll 0.2 --grace 0 --rewake 0 --max-polls 50 >/dev/null 2>"$tmp/denied-err"
rc=$?
if [ "$rc" -eq 3 ] && grep -qxF 'bus-idle-waker: sendText denied (window predates the konsole D-Bus setting; relaunch it): legX' "$tmp/denied-err" && ! grep -q 'session gone' "$tmp/denied-err"; then
  pass "an AccessDenied sendText ends with rc=3 and names the denial, not a gone session"
else fail "denied: expected rc=3, got rc=$rc: $(cat "$tmp/denied-err")"; fi

bash "$WAKER" --name legX --service s --session >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "an option with no value is refused (rc=64)" || fail "valueless option: expected rc=64, got rc=$rc"

bash "$WAKER" --name legX --service s --session /S --poll abc >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "a non-numeric --poll is refused (rc=64)" || fail "bad --poll: expected rc=64, got rc=$rc"

bash "$WAKER" --name legX --service s --session /S --poll 0 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "--poll 0 is refused (rc=64)" || fail "--poll 0: expected rc=64, got rc=$rc"

bash "$WAKER" --name legX --service s --session /S --max-polls 0.5 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "a fractional --max-polls is refused (rc=64)" || fail "--max-polls 0.5: expected rc=64, got rc=$rc"

printf '08' > "$HANDOVER_DIR/inbox/.cursor/legX"
printf 'aaaaaaa\nbbb\n' > "$HANDOVER_DIR/inbox/legX.md"
BUS_N=0 run 8 0.5
grep -qF 'You have 1 unread himmel messages' "$QLOG" && pass "a zero-padded cursor still counts bytes in decimal" || fail "08 cursor: $(cat "$QLOG")"

# --pid: the waker armed for a launched konsole stops once that konsole is gone.
sleep 0 & dead=$!; wait "$dead"
: > "$QLOG"
BUS_N=0 BUS_WAKER_QDBUS="$tmp/qdbus" BUS_WAKER_BUS="$tmp/bus" bash "$WAKER" --name legX --service s --session /S --pid "$dead" --poll 0.2 --max-polls 50 >/dev/null 2>"$tmp/pid-err"
rc=$?
if [ "$rc" -eq 0 ] && grep -qxF "bus-idle-waker: konsole pid $dead gone, stopping: legX" "$tmp/pid-err"; then
  pass "--pid: a gone konsole ends the waker with rc=0"
else fail "--pid gone: expected rc=0 and the stop line, got rc=$rc: $(cat "$tmp/pid-err")"; fi
bash "$WAKER" --name legX --service s --session /S --pid 0 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 64 ] && pass "--pid 0 is refused (rc=64): kill -0 0 would probe the process group" || fail "--pid 0: expected rc=64, got rc=$rc"
BUS_N=2 run 3 0 --pid "$$"
[ "$RUN_RC" -eq 0 ] && grep -qF 'unread himmel messages: read them now.' "$QLOG" && pass "--pid: a live konsole still gets the wake" || fail "--pid live: rc=$RUN_RC, qlog: $(cat "$QLOG")"

echo "== succession doc =="
if grep -q 'run `bus adopt <new console>` as the leg' "$REPO/docs/handover/leg-sections/succession.md" && grep -q 'no edge to' "$REPO/docs/handover/leg-sections/succession.md"; then pass "succession.md tells the leg to run bus adopt and why"; else fail "succession.md lacks the bus adopt instruction"; fi

echo "bus-idle-waker: $failures failure(s)"
exit "$failures"
