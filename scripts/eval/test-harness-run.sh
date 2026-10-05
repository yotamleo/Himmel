#!/usr/bin/env bash
# test-harness-run.sh — HIMMEL-4183. harness-run.py must leave NO descendant
# alive: not the direct child, not a grandchild in the child's process group,
# and not a grandchild that escaped into its own session (setsid /
# Popen(start_new_session=True) — the shape that left eight hook copies
# spinning for hours). Every process here is started by this suite and lives
# under its own temp dir; nothing else is read or signalled.
#
# PLATFORM GUARD: no .ps1 twin, by design — the runner is Linux-only
# (PR_SET_CHILD_SUBREAPER, /proc), like the judge harnesses it wraps.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${HARNESS_RUN_SUT:-$HERE/harness-run.py}"
W="$(mktemp -d "${TMPDIR:-/tmp}/harness-run-test.XXXXXX")" || exit 1
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

# alive <pid>: rc 0 while the pid exists and is not a zombie.
alive() {
    local st
    st=$(sed -n 's/^[0-9]* (.*) \([A-Z]\) .*/\1/p' "/proc/$1/stat" 2>/dev/null) || return 1
    [ -n "$st" ] && [ "$st" != "Z" ]
}

# Belt and braces: whatever a failing case leaves behind is killed on exit.
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap
cleanup() {
    local f p
    for f in "$W"/*.pid; do
        [ -f "$f" ] || continue
        read -r p < "$f" && kill -KILL "$p" 2>/dev/null
    done
    rm -rf "$W"
}
trap cleanup EXIT

# The child under test: one grandchild in its own process group, one that
# escapes into a new session, then either hangs or exits with a code.
cat > "$W/child.sh" <<'CHILD'
#!/usr/bin/env bash
d=$1 mode=$2
sleep 301 & echo $! > "$d/$3-group.pid"
setsid sleep 302 & echo $! > "$d/$3-session.pid"
echo $$ > "$d/$3-child.pid"
case "$mode" in
    hang) while :; do :; done ;;
    trap) trap 'echo term > "$d/$3-term"; exit 0' TERM
          echo ready > "$d/$3-ready"
          while :; do sleep 0.1; done ;;
    *) exit "$mode" ;;
esac
CHILD

# check_gone <tag> <label>: every pid the child recorded is dead.
check_gone() {
    local kind p
    for kind in child group session; do
        if [ ! -s "$W/$1-$kind.pid" ]; then fail "$2: $kind pid recorded"; continue; fi
        read -r p < "$W/$1-$kind.pid"
        if alive "$p"; then fail "$2: $kind ($p) still alive"; else pass "$2: $kind gone"; fi
    done
}

# An unrelated process the runner must not touch.
sleep 300 & bystander=$!
echo "$bystander" > "$W/bystander.pid"

# 1. deadline: a hung child and both grandchildren are killed, rc 124.
python3 "$SUT" --deadline 1 --kill-after 1 -- bash "$W/child.sh" "$W" hang t1 >/dev/null 2>&1
eq "deadline: rc 124" 124 "$?"
check_gone t1 "deadline"

# 2. normal exit: the child exits 0 but leaves both grandchildren running.
python3 "$SUT" --deadline 30 -- bash "$W/child.sh" "$W" 0 t2 >/dev/null 2>&1
eq "clean exit: rc 0" 0 "$?"
check_gone t2 "clean exit"

# 3. the child's own exit code passes through.
python3 "$SUT" --deadline 30 -- bash "$W/child.sh" "$W" 3 t3 >/dev/null 2>&1
eq "exit code passes through" 3 "$?"
check_gone t3 "exit 3"

# 4. the runner itself is told to stop: it sweeps before it goes.
python3 "$SUT" --deadline 60 -- bash "$W/child.sh" "$W" hang t4 >/dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do [ -s "$W/t4-session.pid" ] && break; sleep 0.1; done
kill -TERM "$runner"
wait "$runner"
eq "SIGTERM to runner: rc 143" 143 "$?"
check_gone t4 "runner SIGTERM"

# 4b. the runner's own SIGTERM gives the child a graceful TERM first.
python3 "$SUT" --deadline 60 --kill-after 5 -- bash "$W/child.sh" "$W" trap t4b >/dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do [ -s "$W/t4b-ready" ] && break; sleep 0.1; done
kill -TERM "$runner"
wait "$runner"
eq "SIGTERM to runner (trap child): rc 143" 143 "$?"
if [ -s "$W/t4b-term" ]; then pass "runner SIGTERM: child got SIGTERM first"; else fail "runner SIGTERM: child never got SIGTERM"; fi
check_gone t4b "runner SIGTERM (trap child)"

# In-process cases: load the runner as a module and patch one seam.
cat > "$W/inproc.py" <<'INPROC'
import importlib.util, os, signal, subprocess, sys, time
spec = importlib.util.spec_from_file_location("hr", sys.argv[1])
hr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hr)
mode, w, child = sys.argv[2], sys.argv[3], sys.argv[4]
if mode == "popen-signal":
    # A signal lands after the child exists but before Popen returns.
    real = subprocess.Popen
    def popen(*a, **k):
        real(*a, **k)
        for _ in range(50):
            if os.path.exists(os.path.join(w, "t7-session.pid")):
                break
            time.sleep(0.1)
        raise hr.Stop(signal.SIGTERM)
    hr.subprocess.Popen = popen
    sys.exit(hr.main(["--deadline", "60", "--", "bash", child, w, "hang", "t7"]))
if mode == "survivor":
    # A descendant SIGKILL cannot remove: the sweep must not report success.
    hr.SWEEP_SECS = 0.3
    hr.descendants = lambda root: [4194305]
    sys.exit(hr.main(["--deadline", "5", "--", "true"]))
INPROC

# 7. a signal during Popen still sweeps the child and both grandchildren.
python3 "$W/inproc.py" "$SUT" popen-signal "$W" "$W/child.sh" >/dev/null 2>&1
eq "signal during Popen: rc 143" 143 "$?"
check_gone t7 "signal during Popen"

# 8. a descendant that outlives the sweep is reported, rc 125.
err=$(python3 "$W/inproc.py" "$SUT" survivor "$W" "$W/child.sh" 2>&1 >/dev/null); rc=$?
eq "sweep survivor: rc 125" 125 "$rc"
case "$err" in *4194305*) pass "sweep survivor: pid named" ;; *) fail "sweep survivor: pid not named ($err)" ;; esac

# 9. orphans that exit DURING the run are reaped as they go, not left as
#    zombies under the subreaper until the final sweep (a long differential
#    that double-forks every hook call otherwise piles up pids).
# shellcheck disable=SC2016  # $1 and $(seq) expand in the child shell
python3 "$SUT" --deadline 30 -- bash -c \
    'for i in $(seq 200); do ( true & ); done; echo ready > "$1/t9-ready"; sleep 3' _ "$W" >/dev/null 2>&1 &
runner=$!
for _ in $(seq 1 50); do [ -s "$W/t9-ready" ] && break; sleep 0.1; done
sleep 0.5
zombies=$(python3 - "$runner" <<'ZOMB'
import os, sys
n = 0
for d in os.listdir("/proc"):
    try:
        s = open("/proc/%s/stat" % d).read() if d.isdigit() else ""
    except OSError:
        continue
    f = s[s.rfind(")") + 2:].split()
    n += bool(f) and f[0] == "Z" and f[1] == sys.argv[1]
print(n)
ZOMB
)
wait "$runner"
eq "orphans reaped mid-run: rc 0" 0 "$?"
if [ "$zombies" -lt 5 ]; then pass "orphans reaped mid-run ($zombies zombies)"; else fail "orphans reaped mid-run: $zombies zombies under the runner"; fi

# 10. a child killed by a signal still maps to 128+sig.
python3 "$SUT" --deadline 30 -- bash -c 'kill -KILL $$' >/dev/null 2>&1
eq "child killed by SIGKILL: rc 137" 137 "$?"

# 5. the sweep reaches only the runner's own descendants.
if alive "$bystander"; then pass "bystander untouched"; else fail "bystander was killed"; fi

# 6. usage errors are rc 2, never a silent run.
python3 "$SUT" -- true >/dev/null 2>&1
eq "missing --deadline: rc 2" 2 "$?"
python3 "$SUT" --deadline 5 >/dev/null 2>&1
eq "missing command: rc 2" 2 "$?"
for bad in nan inf -inf; do
    python3 "$SUT" --deadline "$bad" -- true >/dev/null 2>&1
    eq "--deadline $bad: rc 2" 2 "$?"
    python3 "$SUT" --deadline 5 --kill-after "$bad" -- true >/dev/null 2>&1
    eq "--kill-after $bad: rc 2" 2 "$?"
done

kill "$bystander" 2>/dev/null
if [ "$fails" -eq 0 ]; then echo "PASS: harness-run"; exit 0; fi
echo "FAIL: harness-run ($fails)"; exit 1
