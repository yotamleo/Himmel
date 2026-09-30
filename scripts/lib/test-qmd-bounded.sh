#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2123,SC2317,SC2329  # literal $ payloads; PATH scoped to subshells on purpose; cleanup runs via trap
# Tests for scripts/lib/qmd-bounded.sh (HIMMEL-3956).
# Usage: bash scripts/lib/test-qmd-bounded.sh
# Hermetic: a sh trampoline stands in for the qmd launcher (node, which forwards
# no signals) and a TERM-ignoring sleep stands in for bun blocked in native
# llama.cpp. No GPU, no qmd install.
# Platform guard (gitbash-only): POSIX bash 3.2+; a test fixture needs no .ps1
# twin (WS5 T15 convention).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=qmd-bounded.sh
# shellcheck disable=SC1091
. "$LIB_DIR/qmd-bounded.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qmd-bounded.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
# Every grandchild this suite starts writes its pid here; reap them on exit so
# a failing case never leaves the orphan it was testing for.
cleanup() {
    local f
    for f in "$TMP"/*.pid; do
        [ -f "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

# The trampoline: dies on TERM (as node does) and leaves its child running.
TRAMP="$TMP/tramp.sh"
cat >"$TRAMP" <<'EOF'
#!/bin/sh
pidfile="$1"
( trap '' TERM; exec sleep 30 ) &
echo $! >"$pidfile"
trap 'exit 143' TERM
wait
EOF
chmod +x "$TRAMP"

alive() { kill -0 "$1" 2>/dev/null && echo alive || echo dead; }
# Wait (at most 3 s) for a trampoline to record its grandchild's pid.
pid_of() {
    local n=0
    while [ ! -s "$1" ] && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
    cat "$1"
}

export QMD_KILL_GRACE_SECS=1

# Precondition (the bug): plain timeout returns and the grandchild lives on.
timeout 1 "$TRAMP" "$TMP/plain.pid"
gc=$(pid_of "$TMP/plain.pid")
sleep 2
assert_eq "precondition: plain timeout orphans the grandchild" "alive" "$(alive "$gc")"

# T1: the deadline kills the whole group, grandchild included, and rc is 124.
start=$(date +%s)
qmd_bounded 1 "$TRAMP" "$TMP/t1.pid"; rc=$?
took=$(( $(date +%s) - start ))
gc=$(pid_of "$TMP/t1.pid")
assert_eq "T1 deadline -> rc 124" "124" "$rc"
assert_eq "T1 grandchild is dead when qmd_bounded returns" "dead" "$(alive "$gc")"
assert_eq "T1 returns within deadline + grace + slack" "yes" "$([ "$took" -le 4 ] && echo yes || echo "no (${took}s)")"

# T2: a fast command passes rc and stdout through, and a capture does not wait
# on the watchdog.
start=$(date +%s)
out=$(qmd_bounded 20 sh -c 'echo hi; exit 3'); rc=$?
took=$(( $(date +%s) - start ))
assert_eq "T2 stdout + rc pass through" "hi|3" "$out|$rc"
assert_eq "T2 capture returns without waiting for the deadline" "yes" "$([ "$took" -le 2 ] && echo yes || echo "no (${took}s)")"

# T2b: stdin reaches the command (bash gives a background job /dev/null), and
# a CLOSED stdin reads as empty instead of hanging a `$(cat)`.
assert_eq "T2b piped stdin reaches the command" "piped" "$(echo piped | qmd_bounded 5 cat)"
out=$(qmd_bounded 3 sh -c 'x=$(cat); echo "[$x]"' <&-); rc=$?
assert_eq "T2b closed stdin reads as empty" "[]|0" "$out|$rc"

# T2c: a PATH without rm (a hermetic probe env) must not read as a fired
# deadline — the fast command still returns at once with its own rc.
mkdir -p "$TMP/norm"
for t in mktemp sleep; do ln -s "$(command -v "$t")" "$TMP/norm/$t"; done
start=$(date +%s)
out=$(PATH="$TMP/norm"; qmd_bounded 20 echo fast); rc=$?
took=$(( $(date +%s) - start ))
assert_eq "T2c no rm on PATH: rc + stdout pass through" "fast|0" "$out|$rc"
assert_eq "T2c no rm on PATH: returns without waiting for the deadline" "yes" "$([ "$took" -le 2 ] && echo yes || echo "no (${took}s)")"

# T2d: without sleep/mktemp on PATH no watchdog can run; the command must run
# unbounded rather than be killed at once or refused.
mkdir -p "$TMP/nosleep"
out=$(PATH="$TMP/nosleep"; qmd_bounded 20 echo fast 2>/dev/null); rc=$?
assert_eq "T2d no sleep/mktemp on PATH: runs unbounded" "fast|0" "$out|$rc"

# T3: deadline 0 runs unbounded; a malformed deadline is refused.
out=$(qmd_bounded 0 sh -c 'echo ok'); rc=$?
assert_eq "T3a deadline 0 runs the command" "ok|0" "$out|$rc"
qmd_bounded 5s true 2>/dev/null; rc=$?
assert_eq "T3b malformed deadline -> rc 2" "2" "$rc"

# T4: the default deadline honours QMD_TIMEOUT_SECS.
assert_eq "T4a default deadline" "3600" "$(unset QMD_TIMEOUT_SECS; qmd_timeout_secs)"
assert_eq "T4b QMD_TIMEOUT_SECS overrides" "7" "$(QMD_TIMEOUT_SECS=7 qmd_timeout_secs)"

# T5: qmd_cmd (the resolver every himmel script calls) routes through the bound.
mkdir -p "$TMP/bin" "$TMP/bun"
printf '#!/bin/sh\nexec "%s" "%s"\n' "$TRAMP" "$TMP/t5.pid" >"$TMP/bin/qmd"
chmod +x "$TMP/bin/qmd"
start=$(date +%s)
( PATH="$TMP/bin:$PATH" BUN_INSTALL="$TMP/bun" QMD_TIMEOUT_SECS=1
  export PATH BUN_INSTALL QMD_TIMEOUT_SECS
  # shellcheck source=qmd-bin.sh
  # shellcheck disable=SC1091
  . "$LIB_DIR/qmd-bin.sh"
  qmd_cmd query x ); rc=$?
took=$(( $(date +%s) - start ))
gc=$(pid_of "$TMP/t5.pid")
assert_eq "T5 qmd_cmd hits the QMD_TIMEOUT_SECS deadline -> rc 124" "124" "$rc"
assert_eq "T5 qmd_cmd leaves no grandchild" "dead" "$(alive "$gc")"
assert_eq "T5 returns within deadline + grace + slack" "yes" "$([ "$took" -le 4 ] && echo yes || echo "no (${took}s)")"

# T6: every himmel script that runs qmd directly (not through qmd_cmd) is
# bounded too. Each gets a hanging qmd and must return by the deadline, having
# really called it, with no grandchild left behind.
SCRIPTS="$(cd "$LIB_DIR/.." && pwd)"
mkdir -p "$TMP/t6bin"
printf '#!/bin/sh\nexec "%s" "%s"\n' "$TRAMP" "$TMP/t6.pid" >"$TMP/t6bin/qmd"
chmod +x "$TMP/t6bin/qmd"
t6_case() {
    local label="$1" gc took start
    shift
    rm -f "$TMP/t6.pid"
    start=$(date +%s)
    QMD_TIMEOUT_SECS=1 "$@" </dev/null >/dev/null 2>&1
    took=$(( $(date +%s) - start ))
    gc=$(pid_of "$TMP/t6.pid")
    assert_eq "T6 $label called the hanging qmd" "yes" "$([ -n "$gc" ] && echo yes || echo no)"
    assert_eq "T6 $label returns within deadline + grace + slack" "yes" "$([ "$took" -le 5 ] && echo yes || echo "no (${took}s)")"
    [ -n "$gc" ] && assert_eq "T6 $label leaves no grandchild" "dead" "$(alive "$gc")"
    [ -n "$gc" ] && echo "$gc" >"$TMP/t6-$label.pid"
}
t6_case qmd-staleness bash "$SCRIPTS/luna/qmd-staleness.sh" --qmd-bin "$TMP/t6bin/qmd"
t6_case qmd-reindex bash "$SCRIPTS/luna/qmd-reindex.sh" --qmd-bin "$TMP/t6bin/qmd"
t6_case audit-memory-capture env PATH="$TMP/t6bin:$PATH" MEMDIR="$TMP" \
    LUNA_VAULT_PATH="$TMP" MEMORY_CAPTURE_LOG="$TMP/capture.jsonl" \
    bash "$SCRIPTS/memory/audit-memory-capture.sh"

# T7: executed as a script (the path block-bare-qmd-query.sh names), it runs qmd
# bounded: args and rc pass through, the ad-hoc default deadline is 300 s, and a
# hanging qmd is reaped by QMD_TIMEOUT_SECS.
mkdir -p "$TMP/t7bin"
printf '#!/bin/sh\necho "args=$*" "deadline=$QMD_TIMEOUT_SECS"\nexit 5\n' >"$TMP/t7bin/qmd"
chmod +x "$TMP/t7bin/qmd"
out=$(env -u QMD_TIMEOUT_SECS PATH="$TMP/t7bin:$PATH" BUN_INSTALL="$TMP/bun" \
    bash "$LIB_DIR/qmd-bounded.sh" query -c luna x </dev/null); rc=$?
assert_eq "T7a CLI passes args + rc, default deadline 300" "args=query -c luna x deadline=300|5" "$out|$rc"
bash "$LIB_DIR/qmd-bounded.sh" </dev/null >/dev/null 2>&1; rc=$?
assert_eq "T7b CLI without a verb -> rc 2" "2" "$rc"
cp "$TMP/t5.pid" "$TMP/t5-done.pid"
rm -f "$TMP/t5.pid"
start=$(date +%s)
PATH="$TMP/bin:$PATH" BUN_INSTALL="$TMP/bun" QMD_TIMEOUT_SECS=1 \
    bash "$LIB_DIR/qmd-bounded.sh" query x </dev/null >/dev/null 2>&1; rc=$?
took=$(( $(date +%s) - start ))
gc=$(pid_of "$TMP/t5.pid")
assert_eq "T7c CLI hits the deadline -> rc 124" "124" "$rc"
assert_eq "T7c CLI leaves no grandchild" "dead" "$(alive "$gc")"
assert_eq "T7c returns within deadline + grace + slack" "yes" "$([ "$took" -le 4 ] && echo yes || echo "no (${took}s)")"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
