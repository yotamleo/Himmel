#!/usr/bin/env bash
# HIMMEL-1596 Task 1.2 — liveness must not lie in either direction.
#
# The bug: last_output_at ALONE reads 0 for a worker that commits early and
# leaves a clean tree, so the better-behaved the worker, the more it reads
# STALLED — the same false-positive class the watchdog exists to remove.
#
# await-glm-worker.sh CANNOT be sourced (no source guard, and its arg loop
# calls bare `exit` on an unknown flag), so every case invokes it as a
# SUBPROCESS, matching its existing suite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../await-glm-worker.sh"
TMP="$(mktemp -d -t await-liveness.XXXXXX)"
# Windows holds git's pack handles briefly after exit; swallow the EBUSY.
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
export BRIDGE_ROOT="$TMP/bridge"

fails=0
# rc 4 = STALLED, rc 3 = still running (alive) after the window.
check() { # <name> <expected-rc> <actual-rc>
    if [ "$2" -eq "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1 (expected rc=$2 got rc=$3)"
        fails=$((fails + 1))
    fi
}

STALE_ISO="2020-01-01T00:00:00Z"   # far past: last_output_at is always stale

# mk <slug> — a worktree + a session whose recorded output is ancient.
# Everything else about the case is set by the caller afterwards.
mk() {
    local wt="$TMP/wt-$1" d="$BRIDGE_ROOT/glm-sessions/glm-$1-1000000000001"
    mkdir -p "$wt" "$d"
    ( cd "$wt" && git init -q -b work . \
      && git config user.name t && git config user.email t@example.invalid \
      && git config commit.gpgsign false \
      && echo seed > seed.txt && git add seed.txt \
      && GIT_COMMITTER_DATE="$STALE_ISO" GIT_AUTHOR_DATE="$STALE_ISO" \
         git commit -q -m seed ) >/dev/null 2>&1
    # Backdate every file so no fixture is accidentally "live" via mtime.
    find "$wt" -exec touch -d "$STALE_ISO" {} + 2>/dev/null || true
    # NO "pid" field, deliberately. On Git Bash pid_alive probes with
    # `tasklist /FI "PID eq N"`, i.e. WINDOWS pids — an MSYS shell's own $$
    # never matches one, so a fixture that records it reads PHANTOM (rc 5)
    # before the staleness logic under test is ever reached. An absent pid
    # probes "unprobeable", which is both honest for a synthetic fixture and
    # exactly the path that falls through to the staleness check.
    printf '{\n "status": "running",\n "started_at": "%s",\n "last_output_at": "%s",\n "worktree": "%s",\n "branch": "work"\n}\n' \
        "$STALE_ISO" "$STALE_ISO" "$wt" > "$d/meta.json"
    printf '%s' "$d"
}

run() { bash "$SUT" --session-dir "$1" --max-mins 0 --stall-mins 1 >/dev/null 2>&1; echo $?; }

# --- 1. DIRTY TREE -> live. Uncommitted work is progress, whatever the log says.
d=$(mk dirty); wt="$TMP/wt-dirty"
echo "work in progress" > "$wt/scratch.txt"
check "dirty tree reads LIVE" 3 "$(run "$d")"

# --- 2. CLEAN TREE + RECENT COMMIT -> live. THE REGRESSION CASE: the worker
#        committed early and went quiet, which the old single-signal check
#        scored as STALLED.
d=$(mk committed); wt="$TMP/wt-committed"
( cd "$wt" && echo "finished" > result.txt && git add result.txt \
  && git commit -q -m "worker committed its work" ) >/dev/null 2>&1
check "clean tree + recent commit reads LIVE" 3 "$(run "$d")"

# --- 3. RECENT FILE WRITE, nothing committed, nothing logged -> live.
d=$(mk writing); wt="$TMP/wt-writing"
echo "partial output" > "$wt/partial.txt"
( cd "$wt" && git add -A && git stash -q ) >/dev/null 2>&1   # keep tree clean
echo "still writing" > "$wt/partial.txt"                      # ... then touch it now
check "recent file write reads LIVE" 3 "$(run "$d")"

# --- 4. GENUINELY IDLE -> STALLED. Everything ancient: output, mtimes, commit.
#        This is the case the check must still catch; if a max-of-signals ever
#        widens ALIVE far enough to swallow this, the watchdog is useless.
d=$(mk idle)
check "genuinely idle reads STALLED" 4 "$(run "$d")"

# --- 5. No worktree recorded (an older meta.json) -> falls back to the
#        single signal and still STALLS. Proves the new fields are OPTIONAL
#        and an in-flight run written by an older spawner is not broken.
d="$BRIDGE_ROOT/glm-sessions/glm-legacy-1000000000001"
mkdir -p "$d"
printf '{\n "status": "running",\n "started_at": "%s",\n "last_output_at": "%s"\n}\n' \
    "$STALE_ISO" "$STALE_ISO" > "$d/meta.json"
check "legacy meta without worktree still STALLS" 4 "$(run "$d")"

# The suite's own live pid, in the namespace pid_alive probes: on Git Bash
# that is the WINDOWS pid (tasklist), read from /proc/$$/winpid; POSIX kill -0
# takes $$ directly. This is what lets the HIMMEL-1573 cases below record a
# pid that is GENUINELY alive for the duration of the run.
if [ -r "/proc/$$/winpid" ]; then LIVE_PID=$(cat "/proc/$$/winpid"); else LIVE_PID=$$; fi

# --- 6. LIVE PID -> live (HIMMEL-1573). Every write-side signal ancient, but
#        the recorded pid is CONFIRMED alive. A worker in its READ/PLAN phase
#        writes nothing, so process liveness is the only signal that can see
#        it — measured 2026-08-07: a verifiably-alive worker was declared
#        STALLED at the default window while reading. Alive pid = not stalled.
d=$(mk livepid); wt="$TMP/wt-livepid"
printf '{\n "status": "running",\n "pid": %s,\n "started_at": "%s",\n "last_output_at": "%s",\n "worktree": "%s",\n "branch": "work"\n}\n' \
    "$LIVE_PID" "$STALE_ISO" "$STALE_ISO" "$wt" > "$d/meta.json"
check "live pid reads LIVE despite stale write signals" 3 "$(run "$d")"

# --- 7. DEAD PID -> still PHANTOM (rc 5), unchanged: the fourth signal must
#        not swallow the confirmed-dead verdict that precedes it. Pid chosen
#        far above any real allocation so both probes CONFIRM absence.
d=$(mk deadpid); wt="$TMP/wt-deadpid"
printf '{\n "status": "running",\n "pid": 999999999,\n "started_at": "%s",\n "last_output_at": "%s",\n "worktree": "%s",\n "branch": "work"\n}\n' \
    "$STALE_ISO" "$STALE_ISO" "$wt" > "$d/meta.json"
check "dead pid still reads PHANTOM" 5 "$(run "$d")"

# --- 8. SIBLING CHURN IS NOT LIVENESS (HIMMEL-1616). worker_worktree (the
#        minted worktree) is ancient; the legacy `worktree` key (the dispatch
#        CWD) has a FRESH write, simulating a sibling worker's churn in the
#        shared checkout. The mtime leg must walk worker_worktree, so this
#        STALLS — before the fix the sibling write read as a false ALIVE.
d=$(mk siblingchurn); wt="$TMP/wt-siblingchurn"
mkdir -p "$TMP/dispatch-cwd"
echo "a sibling worker wrote this" > "$TMP/dispatch-cwd/churn.txt"
printf '{\n "status": "running",\n "started_at": "%s",\n "last_output_at": "%s",\n "worker_worktree": "%s",\n "worktree": "%s",\n "branch": "work"\n}\n' \
    "$STALE_ISO" "$STALE_ISO" "$wt" "$TMP/dispatch-cwd" > "$d/meta.json"
check "sibling churn in dispatch CWD no longer reads ALIVE" 4 "$(run "$d")"

# --- 9. worker_worktree is PREFERRED in the alive direction too: fresh write
#        in the minted worktree, legacy key pointing at an ancient dir.
d=$(mk workerwt); wt="$TMP/wt-workerwt"
mkdir -p "$TMP/stale-dispatch-cwd"
# POSIX touch -t, not GNU-only -d, and no failure suppression: a fixture that
# silently stays fresh would not establish the stated condition (CR round 1).
touch -t 200001010000 "$TMP/stale-dispatch-cwd"
echo "work in progress" > "$wt/scratch.txt"
printf '{\n "status": "running",\n "started_at": "%s",\n "last_output_at": "%s",\n "worker_worktree": "%s",\n "worktree": "%s",\n "branch": "work"\n}\n' \
    "$STALE_ISO" "$STALE_ISO" "$wt" "$TMP/stale-dispatch-cwd" > "$d/meta.json"
check "fresh write in worker_worktree reads LIVE" 3 "$(run "$d")"

# --- 10. EPERM pid (exists but unprobeable) -> NOT PHANTOM (CR round 1, PR
#         #1603). POSIX only: pid 1 exists but a non-root kill -0 gets EPERM,
#         which must read UNKNOWN (rc 2), fall through to the staleness check,
#         and STALL (rc 4) — never rc 5. Skipped on Git Bash (the tasklist
#         probe path — no pid 1 there) and under root (kill -0 1 succeeds,
#         which is a different, already-covered case).
if [ ! -r "/proc/$$/winpid" ] && ! kill -0 1 2>/dev/null; then
    d=$(mk epermpid); wt="$TMP/wt-epermpid"
    printf '{\n "status": "running",\n "pid": 1,\n "started_at": "%s",\n "last_output_at": "%s",\n "worktree": "%s",\n "branch": "work"\n}\n' \
        "$STALE_ISO" "$STALE_ISO" "$wt" > "$d/meta.json"
    check "EPERM pid reads unprobeable (STALLED, not PHANTOM)" 4 "$(run "$d")"
else
    echo "skip EPERM-pid case (Windows tasklist path, or running as root)"
fi

# --- Portability coverage (HIMMEL-1614).
# await-glm-worker.sh can only be driven as a subprocess, so the BSD/macOS
# `stat -f %m` path -- which does not exist in the GNU-only original -- is
# exercised by faking a non-GNU toolchain: a `find` that rejects -printf (so
# the SUT's detection cannot pick gnu) and a `stat` implementing BSD -f %m on
# top of the host's real GNU stat. This is the environment a macOS adopter
# has. Real find/stat are resolved once and exported for the shims to defer
# to; the quoted heredoc bodies are literal data (not linted by shellcheck).
AWAIT_LIVENESS_REAL_FIND="$(command -v find)"
AWAIT_LIVENESS_REAL_STAT="$(command -v stat)"
export AWAIT_LIVENESS_REAL_FIND AWAIT_LIVENESS_REAL_STAT

# run with a custom PATH prefix (fake toolchain); echo the exit code.
run_path() { PATH="$1:$PATH" bash "$SUT" --session-dir "$2" --max-mins 0 --stall-mins 1 >/dev/null 2>&1; echo $?; }
# run with a custom PATH prefix; echo exit code on stdout, stderr to file $3.
run_err() { PATH="$1:$PATH" bash "$SUT" --session-dir "$2" --max-mins 0 --stall-mins 1 >/dev/null 2>"$3"; echo $?; }

# make_fake_bin <dir> <bsd|none>: write a `find` that rejects -printf, plus a
# `stat` that either implements BSD -f %m (bsd) or always fails (none).
make_fake_bin() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/find" <<'EOF'
#!/usr/bin/env bash
# Fake BSD-like find: rejects -printf (the GNU extension). Anything else
# defers to the real find via AWAIT_LIVENESS_REAL_FIND.
for a in "$@"; do
    [ "$a" = "-printf" ] && { echo "find: unknown primary -printf" >&2; exit 1; }
done
exec "${AWAIT_LIVENESS_REAL_FIND:-find}" "$@"
EOF
    if [ "$2" = bsd ]; then
        cat > "$bin/stat" <<'EOF'
#!/usr/bin/env bash
# Fake BSD stat: `stat -f %m FILE...` prints each mtime as whole epoch secs,
# built on the host's real GNU stat -c %Y so the portability path can run on
# a GNU host. Other forms defer to the real stat.
if [ "$1" = "-f" ] && [ "$2" = "%m" ]; then
    shift 2
    for f in "$@"; do "${AWAIT_LIVENESS_REAL_STAT:-stat}" -c %Y "$f"; done
else
    exec "${AWAIT_LIVENESS_REAL_STAT:-stat}" "$@"
fi
EOF
    else
        cat > "$bin/stat" <<'EOF'
#!/usr/bin/env bash
# No usable stat: every call fails, so the SUT's detection falls through to
# MTIME_TOOL=none and the leg degrades with a notice instead of silently.
exit 1
EOF
    fi
    chmod +x "$bin/find" "$bin/stat"
}

# --- 11. PORTABLE FALLBACK YIELDS A LIVE EPOCH.
#        Case 3 already proves mtime can be the SOLE live signal (no recent
#        commit, no recorded output, a freshly written file) via THIS host's
#        native GNU path. It cannot prove the PORTABLE path -- the BSD/macOS
#        `stat -f %m` fallback absent from the GNU-only original. The fake bin
#        forces detection off gnu onto bsd; a fresh file (mtime-only signal)
#        must still read LIVE. Against the original, the fake find breaks
#        -printf, the leg returns nothing, and this reads STALLED -- the silent
#        capability loss HIMMEL-1614 names.
FAKE_BSD="$TMP/fakebin-bsd"
make_fake_bin "$FAKE_BSD" bsd
d=$(mk portfb)
echo "fresh work via portable path" > "$TMP/wt-portfb/portable.txt"
check "portable stat fallback reads LIVE" 3 "$(run_path "$FAKE_BSD" "$d")"

# --- 12. UNAVAILABLE TOOLING EMITS A NOTICE, not a silent degrade.
#        Neither -printf nor a usable stat: the leg must say so ONCE on stderr
#        and contribute nothing, rather than the old silent drop to two
#        signals. An idle fixture still reads STALLED (the watchdog is not
#        weakened); the stderr notice is the regression signal, because the
#        original code emits nothing here.
FAKE_NONE="$TMP/fakebin-none"
make_fake_bin "$FAKE_NONE" none
d=$(mk idlefb)
err="$TMP/idlefb.err"
rc=$(run_err "$FAKE_NONE" "$d" "$err")
check "unavailable tooling still STALLS" 4 "$rc"
notice_count=$(grep -c "mtime liveness leg unavailable" "$err")
if [ "$notice_count" -eq 1 ]; then
    echo "ok   unavailable tooling emits the notice exactly once"
else
    echo "FAIL unavailable tooling emits the notice exactly once (got $notice_count)"
    fails=$((fails + 1))
fi

echo
if [ "$fails" -gt 0 ]; then
    echo "test-await-liveness: $fails FAILURE(S)"
    exit 1
fi
echo "test-await-liveness: all tests pass"
