#!/usr/bin/env bash
# Coverage for scripts/lanes/stop-worker.sh (HIMMEL-1693) -- the sanctioned STOP
# chokepoint for in-flight lane workers.
#
# The suite is hermetic: it builds its own BRIDGE_ROOT session registry and its
# own git worktrees under a temp dir, so it never touches the operator's real
# lane sessions. The one case that signals a real process spawns its OWN
# `sleep` and kills only that.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP="$SCRIPT_DIR/../stop-worker.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-stop-worker.XXXXXX")
cleanup() { [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT" 2>/dev/null; }
trap cleanup EXIT

# HIMMEL-1693 CR (codex-1): stop-worker.sh no longer honors a plain BRIDGE_ROOT
# env (a forged registry there would be an arbitrary-process-kill primitive
# through the sanctioned STOP chokepoint). The hermetic fixture registry must
# use the explicit test seam instead -- its name makes clear this is NOT the
# canonical registry. BRIDGE_ROOT stays exported too (RUN G's G1/G2 need it
# visible to a child stop-worker.sh invocation to prove it is ignored there).
export BRIDGE_ROOT="$TMP_ROOT/bridge"
export STOP_WORKER_BRIDGE_ROOT_OVERRIDE="$BRIDGE_ROOT"
mkdir -p "$BRIDGE_ROOT/glm-sessions" "$BRIDGE_ROOT/claudex-sessions"

# mk_repo <dir> -- a real git repo with one commit, usable as a worker worktree.
mk_repo() {
    local d="$1"
    mkdir -p "$d"
    git init -q "$d" 2>/dev/null || { git init -q "$d"; }
    git -C "$d" config user.email t@test.com
    git -C "$d" config user.name t
    printf 'base\n' > "$d/file.txt"
    git -C "$d" add file.txt
    git -C "$d" commit -q -m base
}

# mk_session <lane> <id> <status> <pid> <branch> [worker_worktree] [extra-json]
mk_session() {
    local lane="$1" id="$2" status="$3" pid="$4" branch="$5" wt="${6:-}" extra="${7:-}"
    local dir="$BRIDGE_ROOT/${lane}-sessions/$id"
    mkdir -p "$dir"
    # NOTE the single skip: with `node -e`, process.argv is
    # [execPath, ...userArgs] — there is NO script-path element, so argv[1] is
    # the FIRST user arg. Destructuring with two skips silently wrote the
    # fixture to a file named after the second argument instead, node exited 0,
    # and every registry lookup then reported "no lane worker matches".
    node -e '
const fs=require("fs");
const [,p,lane,status,pid,branch,wt,extra]=process.argv;
const o={status,pid:Number(pid),lane,task_name:"t",branch,worker_worktree:wt};
if(extra) Object.assign(o,JSON.parse(extra));
fs.writeFileSync(p,JSON.stringify(o,null,2));
' "$dir/meta.json" "$lane" "$status" "$pid" "$branch" "$wt" "$extra"
    printf '%s\n' "$dir"
}

run_stop() { bash "$STOP" "$@" 2>&1; }

# HIMMEL-1929 push-quarantine helpers. set_pushurl seeds the worktree-scoped
# remote.origin.pushurl the way the retired lane quarantine used to
# (repo-level extensions.worktreeConfig=true, then a --worktree scoped value)
# -- the producer is gone as of HIMMEL-1961, so this fixture now stands in for
# residue left by a pre-removal dispatch; pushurl_of prints the current value,
# or nothing when the key is absent.
POISON="DISABLED-glm-quarantine"
set_pushurl() {
    git -C "$1" config extensions.worktreeConfig true
    git -C "$1" config --worktree remote.origin.pushurl "$2"
}
pushurl_of() { git -C "$1" config --worktree --get remote.origin.pushurl 2>/dev/null; }

echo "RUN A: registry resolution + refusals"

mk_session glm glm-done-1 "done" 0 glm/done >/dev/null
out=$(run_stop nonexistent-session); rc=$?
if [ "$rc" -eq 2 ]; then pass "A1: unknown target -> exit 2 (refused, not found)"; else fail "A1: expected rc=2, got $rc" "$out"; fi

out=$(run_stop glm-done-1); rc=$?
if [ "$rc" -eq 3 ]; then pass "A2: non-running session -> exit 3"; else fail "A2: expected rc=3, got $rc" "$out"; fi

# A raw pid must NOT be an accepted target -- that is the whole point of
# resolving through the registry.
out=$(run_stop 4242); rc=$?
if [ "$rc" -eq 2 ]; then pass "A3: a raw pid is not a valid target (exit 2)"; else fail "A3: expected rc=2 for a raw pid, got $rc" "$out"; fi

mk_session glm glm-unprobeable-1 running 0 glm/unprobeable "" '{"pid_probe":"unprobeable"}' >/dev/null
out=$(run_stop glm-unprobeable-1); rc=$?
if [ "$rc" -eq 4 ]; then
    case "$out" in
        *"possibly alive"*) pass "A4: unprobeable liveness marker -> exit 4, treated as possibly alive, nothing signalled" ;;
        *) fail "A4: exit 4 but message did not say possibly-alive" "$out" ;;
    esac
else
    fail "A4: expected rc=4 for an unprobeable marker, got $rc" "$out"
fi

mk_session claudex claudex-nopid-1 running 0 claudex/nopid >/dev/null
out=$(run_stop claudex-nopid-1); rc=$?
if [ "$rc" -eq 4 ]; then pass "A5: running session with pid 0 -> exit 4, nothing signalled"; else fail "A5: expected rc=4, got $rc" "$out"; fi

# Two RUNNING sessions on one branch must not be stopped by branch name.
mk_session glm glm-dup-a running 999001 glm/dup >/dev/null
mk_session glm glm-dup-b running 999002 glm/dup >/dev/null
out=$(run_stop glm/dup); rc=$?
if [ "$rc" -eq 1 ]; then pass "A6: ambiguous branch match -> exit 1 (refuses to guess)"; else fail "A6: expected rc=1, got $rc" "$out"; fi

out=$(run_stop --list)
if printf '%s' "$out" | grep -q "glm-done-1" && printf '%s' "$out" | grep -q "claudex-nopid-1"; then
    pass "A7: --list enumerates sessions from BOTH lanes"
else
    fail "A7: --list missed a lane" "$out"
fi

echo "RUN B: checkpoint-before-signal"

# B1: a dirty worker worktree is checkpointed, and --dry-run signals nothing.
WT_B="$TMP_ROOT/wt-dirty"
mk_repo "$WT_B"
printf 'uncommitted work\n' > "$WT_B/file.txt"
printf 'brand new\n' > "$WT_B/newfile.txt"
set_pushurl "$WT_B" "$POISON"
mk_session glm glm-dirty-1 running 999003 glm/dirty "$WT_B" >/dev/null
out=$(run_stop --dry-run glm-dirty-1); rc=$?
if [ "$rc" -eq 0 ]; then pass "B1: --dry-run on a dirty worker exits 0"; else fail "B1: expected rc=0, got $rc" "$out"; fi
ckpt=$(git -C "$WT_B" rev-parse --verify --quiet refs/checkpoints/glm-dirty-1-halt)
if [ -n "$ckpt" ]; then
    pass "B2: the worker's dirty worktree was checkpointed BEFORE any signal"
else
    fail "B2: no refs/checkpoints/glm-dirty-1-halt was created" "$out"
fi
if [ "$(git -C "$WT_B" show "refs/checkpoints/glm-dirty-1-halt:newfile.txt" 2>/dev/null)" = "brand new" ]; then
    pass "B3a: the checkpoint captured an UNTRACKED file (git stash create cannot)"
else
    fail "B3a: untracked file missing from the checkpoint" "$out"
fi
if [ "$(git -C "$WT_B" show "refs/checkpoints/glm-dirty-1-halt:file.txt" 2>/dev/null)" = "uncommitted work" ]; then
    pass "B3b: the checkpoint captured the modified tracked file"
else
    fail "B3b: modified tracked file missing from the checkpoint" "$out"
fi
case "$out" in
    *"nothing signalled"*) pass "B4: --dry-run says explicitly that nothing was signalled" ;;
    *) fail "B4: dry-run output did not state that nothing was signalled" "$out" ;;
esac
# The worker's own index/worktree must be untouched by checkpointing.
if [ -n "$(git -C "$WT_B" status --porcelain)" ]; then
    pass "B5: checkpointing left the worker's worktree dirty (did not commit or stash it)"
else
    fail "B5: the worker's worktree was mutated by checkpointing" "$out"
fi
# B5b (HIMMEL-1929): --dry-run signals nothing, so the worker is still live and
# its push tripwire must stay in place. Clearing the quarantine is part of
# concluding a halt, never part of reporting what one WOULD do.
if [ "$(pushurl_of "$WT_B")" = "$POISON" ]; then
    pass "B5b: --dry-run left the push quarantine intact (nothing signalled, worker still live)"
else
    fail "B5b: --dry-run cleared remote.origin.pushurl on a worker it never signalled" "$out"
fi

# B6: a worktree that cannot be checkpointed ABORTS the stop -- fail-safe.
mk_session glm glm-badwt-1 running 999004 glm/badwt "$TMP_ROOT/not-a-repo" >/dev/null
out=$(run_stop glm-badwt-1); rc=$?
if [ "$rc" -eq 5 ]; then
    pass "B6: an uncheckpointable worktree refuses the stop (exit 5), rather than killing with unsaved work"
else
    fail "B6: expected rc=5, got $rc" "$out"
fi

echo "RUN C: end-to-end stop of a live process"

# A REAL child, spawned under `set -m` so it owns its process group -- the shape
# proc-tree.sh documents. This is the ticket's "demonstrated end-to-end", not an
# inspection.
WT_C="$TMP_ROOT/wt-live"
mk_repo "$WT_C"
printf 'live work in progress\n' > "$WT_C/file.txt"
# HIMMEL-1929: a real dispatch leaves this sentinel on the worker's worktree
# for the life of the run; the spawner's restore is a `finally`, which a hard
# kill never reaches. C5 below asserts this halt cleans it up.
set_pushurl "$WT_C" "$POISON"
set -m
sleep 300 &
LIVE_PID=$!
set +m
# started_at must correlate with the fixture's OWN start time -- stop-worker
# now cross-checks the two (HIMMEL-1693 CR: spawn-time identity correlation)
# and refuses to signal a pid whose start time doesn't line up.
LIVE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
mk_session glm glm-live-1 running "$LIVE_PID" glm/live "$WT_C" "$(printf '{"started_at":"%s"}' "$LIVE_STARTED_AT")" >/dev/null

if kill -0 "$LIVE_PID" 2>/dev/null; then
    pass "C0: fixture child $LIVE_PID is alive before the stop"
else
    fail "C0: fixture child never started"
fi

out=$(run_stop glm-live-1); rc=$?
if [ "$rc" -eq 0 ]; then pass "C1: stop-worker exits 0 on a live worker"; else fail "C1: expected rc=0, got $rc" "$out"; fi

gone=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$LIVE_PID" 2>/dev/null; then gone=1; break; fi
    sleep 1
done
if [ "$gone" -eq 1 ]; then
    pass "C2: the worker process is actually GONE (verified against the OS, not the return code)"
else
    fail "C2: pid $LIVE_PID survived the stop" "$out"
fi
# No-op when C2 passed; on the C2 FAILURE path this keeps the suite from
# blocking up to 5 minutes in `wait` on the surviving sleep fixture
# (panel finding codex-1 @ 16a1012b; same kill-then-wait shape as RUN D).
kill -9 "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null

if [ -n "$(git -C "$WT_C" rev-parse --verify --quiet refs/checkpoints/glm-live-1-halt)" ]; then
    pass "C3: the halted worker's uncommitted work was checkpointed"
else
    fail "C3: no checkpoint for the halted worker" "$out"
fi

st=$(node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).status))' "$BRIDGE_ROOT/glm-sessions/glm-live-1/meta.json" 2>/dev/null)
if [ "$st" = "stopped-by-parent" ]; then
    pass "C4: meta.json records status=stopped-by-parent (a later reader cannot read it as running)"
else
    fail "C4: meta status is '$st', expected stopped-by-parent" "$out"
fi

# C5 (HIMMEL-1929): the halt must not strand the push quarantine. The spawner
# restores the pushurl in a `finally` that a hard kill never reaches, and with
# the GLM lane dropped nothing else self-heals it -- so the chokepoint that
# did the killing clears it.
if [ -z "$(pushurl_of "$WT_C")" ]; then
    pass "C5: the stranded push quarantine was cleared from the halted worker's worktree"
else
    fail "C5: remote.origin.pushurl is still '$(pushurl_of "$WT_C")' after the halt" "$out"
fi
case "$out" in
    *"cleared the stranded push quarantine"*) pass "C6: the halt says out loud that it cleared the quarantine" ;;
    *) fail "C6: the halt cleared the quarantine silently" "$out" ;;
esac

echo "RUN D: spawn-time identity correlation (recycled-pid refusal)"

# A REAL live process, but its registry started_at is nowhere near when it
# actually started -- simulates a registry that thinks a stale/recycled pid
# is still its worker. Before the CR fix, stop-worker.sh sampled this
# process's identity fresh and verified it against ITSELF (a tautology) --
# it would have happily signalled this process. The fix must refuse.
WT_D="$TMP_ROOT/wt-mismatch"
mk_repo "$WT_D"
set -m
sleep 300 &
MISMATCH_PID=$!
set +m
STALE_STARTED_AT="2020-01-01T00:00:00.000Z"
mk_session glm glm-mismatch-1 running "$MISMATCH_PID" glm/mismatch "$WT_D" "$(printf '{"started_at":"%s"}' "$STALE_STARTED_AT")" >/dev/null

out=$(run_stop glm-mismatch-1); rc=$?
if [ "$rc" -eq 4 ]; then
    pass "D1: a pid whose own start time does not correlate with the registered started_at is refused (exit 4)"
else
    fail "D1: expected rc=4, got $rc" "$out"
fi
case "$out" in
    *"RECYCLED"*) pass "D2: refusal message calls out the recycled-pid mismatch" ;;
    *) fail "D2: refusal message did not mention a recycled pid" "$out" ;;
esac
if kill -0 "$MISMATCH_PID" 2>/dev/null; then
    pass "D3: the mismatched process was NOT signalled -- still alive"
else
    fail "D3: the mismatched process was killed despite failing spawn-time correlation"
fi
kill -9 "$MISMATCH_PID" 2>/dev/null
wait "$MISMATCH_PID" 2>/dev/null

echo "RUN E: leader confirmed-gone-before-any-signal records a truthful status"

# _PROC_TREE_PROC_ROOT is proc-tree.sh's OWN documented test seam (see its
# comment: "Overridable so a test can point it at an unreadable/absent
# directory to exercise the 'probe unavailable' arm without needing a
# genuinely-unreadable real /proc"). Pointing it at an empty dir makes
# proc_tree_process_alive report "confirmed absent" for ANY pid regardless of
# real OS state -- which deterministically drives proc_tree_terminate's
# initial guard to rc=3 (leader already exited before any signal was sent)
# without needing to win a real microsecond timing race. It does NOT affect
# proc_tree_process_identity (reads the real /proc directly), so the earlier
# spawn-time correlation check still runs against the REAL live process and
# passes -- exercising exactly the TERM_RC=3 path the status-recording fix
# targets. The process is never actually signalled; it is killed by the test
# afterward as ordinary fixture cleanup.
#
# HIMMEL-1693 CR round 2: proc_tree_process_alive only consults
# _PROC_TREE_PROC_ROOT on the Windows/MSYS branch (proc_tree_is_windows); on
# POSIX it calls `kill -0` directly and ignores this seam entirely. Off
# Windows/MSYS the override above would do nothing -- the real live fixture
# gets genuinely TERM/KILL'd, and E2-E4 would assert on a code path that never
# runs. Gate the whole RUN on the same probe proc-tree.sh's own
# proc_tree_is_windows uses (kept inline rather than sourcing proc-tree.sh,
# since this suite only ever invokes stop-worker.sh as a subprocess).
if [ -r "/proc/$$/winpid" ]; then
    WT_E="$TMP_ROOT/wt-alreadygone"
    mk_repo "$WT_E"
    set -m
    sleep 300 &
    GONE_PID=$!
    set +m
    GONE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    mk_session glm glm-alreadygone-1 running "$GONE_PID" glm/alreadygone "$WT_E" "$(printf '{"started_at":"%s"}' "$GONE_STARTED_AT")" >/dev/null

    FAKE_PROC_ROOT="$TMP_ROOT/fake-proc-root"
    mkdir -p "$FAKE_PROC_ROOT"
    out=$(_PROC_TREE_PROC_ROOT="$FAKE_PROC_ROOT" bash "$STOP" glm-alreadygone-1 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then pass "E1: a leader confirmed-gone-before-signal still exits 0"; else fail "E1: expected rc=0, got $rc" "$out"; fi
    case "$out" in
        *"already exited"*) pass "E2: output reports the worker had already exited" ;;
        *) fail "E2: output did not report an already-exited worker" "$out" ;;
    esac
    if kill -0 "$GONE_PID" 2>/dev/null; then
        pass "E3: the process was NOT actually signalled by the simulated race"
    else
        fail "E3: the process was killed despite the confirmed-gone guard refusing to signal"
    fi
    st=$(node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).status))' "$BRIDGE_ROOT/glm-sessions/glm-alreadygone-1/meta.json" 2>/dev/null)
    if [ "$st" = "already-exited" ]; then
        pass "E4: meta.json records status=already-exited, NOT stopped-by-parent (a later reader must not think this chokepoint acted)"
    else
        fail "E4: meta status is '$st', expected already-exited" "$out"
    fi
    kill -9 "$GONE_PID" 2>/dev/null
    wait "$GONE_PID" 2>/dev/null
else
    echo "  SKIP: RUN E requires the Windows/MSYS _PROC_TREE_PROC_ROOT liveness seam (proc_tree_process_alive uses kill -0 on this platform and ignores it)"
fi

echo "RUN F: pid already gone BEFORE identity sampling records a truthful status"

# codex-1 (panel @ 10dc1730e9e627ea2ff957774db3163a2d1a6673): distinct from RUN
# E's TERM_RC=3 path (which fires only after proc_tree_terminate's OWN initial
# guard runs), this drives the EARLIER guard -- proc_tree_process_identity
# finding nothing AND proc_tree_process_alive confirming absence, before
# proc_tree_terminate is ever called. A registry record naming a pid that
# never existed drives both functions to "confirmed absent" deterministically
# on POSIX (`ps -p`/`kill -0`) and on Windows/Git Bash (no /proc/<pid>/winpid,
# no $_PROC_TREE_PROC_ROOT/<pid> entry) without racing a real process's exit.
WT_F="$TMP_ROOT/wt-gonebeforeidentity"
mk_repo "$WT_F"
set_pushurl "$WT_F" "$POISON"
NEVER_EXISTED_PID=987654321
FBI_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
mk_session glm glm-gonebeforeid-1 running "$NEVER_EXISTED_PID" glm/gonebeforeid "$WT_F" "$(printf '{"started_at":"%s"}' "$FBI_STARTED_AT")" >/dev/null

out=$(run_stop glm-gonebeforeid-1); rc=$?
if [ "$rc" -eq 0 ]; then pass "F1: pid already gone before identity sampling still exits 0"; else fail "F1: expected rc=0, got $rc" "$out"; fi
case "$out" in
    *"already gone"*) pass "F2: output reports the pid was already gone" ;;
    *) fail "F2: output did not report the pid as already gone" "$out" ;;
esac
st=$(node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).status))' "$BRIDGE_ROOT/glm-sessions/glm-gonebeforeid-1/meta.json" 2>/dev/null)
if [ "$st" = "already-exited" ]; then
    pass "F3: meta.json records status=already-exited (a later reader must not see this session as still running)"
else
    fail "F3: meta status is '$st', expected already-exited" "$out"
fi
# F4 (HIMMEL-1929): the earlier of the two concluded-gone paths must clean up
# too -- a worker that died on its own before the halt reached it strands the
# quarantine exactly the same way.
if [ -z "$(pushurl_of "$WT_F")" ]; then
    pass "F4: the already-gone path also cleared the stranded push quarantine"
else
    fail "F4: remote.origin.pushurl is still '$(pushurl_of "$WT_F")' on the already-gone path" "$out"
fi

# F5-F6 (HIMMEL-1929): ONLY the quarantine sentinel is cleared. An operator's
# real per-worktree pushurl is not this chokepoint's to unset -- a halt that
# silently deleted push configuration would be a worse bug than the leak.
WT_F2="$TMP_ROOT/wt-realpushurl"
mk_repo "$WT_F2"
REAL_PUSHURL="git@example.invalid:operator/keepme.git"
set_pushurl "$WT_F2" "$REAL_PUSHURL"
F2_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
mk_session glm glm-realpushurl-1 running "$NEVER_EXISTED_PID" glm/realpushurl "$WT_F2" "$(printf '{"started_at":"%s"}' "$F2_STARTED_AT")" >/dev/null
out=$(run_stop glm-realpushurl-1); rc=$?
if [ "$rc" -eq 0 ]; then pass "F5: a halt on a worktree carrying a real pushurl still exits 0"; else fail "F5: expected rc=0, got $rc" "$out"; fi
if [ "$(pushurl_of "$WT_F2")" = "$REAL_PUSHURL" ]; then
    pass "F6: a non-sentinel remote.origin.pushurl is left exactly as it was"
else
    fail "F6: the halt clobbered a real pushurl (now '$(pushurl_of "$WT_F2")')" "$out"
fi

# F7-F9 (HIMMEL-1929 panel round 4): proc_tree_process_alive answers 0 alive /
# 1 CONFIRMED absent / 2 probe-could-not-answer, and its contract forbids
# reading 2 as absence. stop-worker tested it with a bare `if`, so an
# unanswerable probe took the already-gone branch -- annotating a possibly-live
# worker as exited and (with this ticket's cleanup) stripping its push
# tripwire. Drive rc 2 deterministically by pointing proc-tree.sh's OWN test
# seam at a path that does not exist: the pid entry is missing AND the root is
# unreadable, which is exactly "the probe proves nothing". Gated like RUN E --
# the seam is only consulted on the Windows/MSYS branch.
if [ -r "/proc/$$/winpid" ]; then
    WT_F3="$TMP_ROOT/wt-probefailed"
    mk_repo "$WT_F3"
    set_pushurl "$WT_F3" "$POISON"
    F3_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    mk_session glm glm-probefailed-1 running "$NEVER_EXISTED_PID" glm/probefailed "$WT_F3" "$(printf '{"started_at":"%s"}' "$F3_STARTED_AT")" >/dev/null
    out=$(_PROC_TREE_PROC_ROOT="$TMP_ROOT/no-such-proc-root" bash "$STOP" glm-probefailed-1 2>&1); rc=$?
    if [ "$rc" -eq 4 ]; then
        pass "F7: an unanswerable liveness probe is refused (exit 4), not read as confirmed absence"
    else
        fail "F7: expected rc=4 for an unanswerable liveness probe, got $rc" "$out"
    fi
    st=$(node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).status))' "$BRIDGE_ROOT/glm-sessions/glm-probefailed-1/meta.json" 2>/dev/null)
    if [ "$st" = "running" ]; then
        pass "F8: meta.json still reads running -- an unconfirmed absence must not be annotated as already-exited"
    else
        fail "F8: meta status is '$st', expected running" "$out"
    fi
    if [ "$(pushurl_of "$WT_F3")" = "$POISON" ]; then
        pass "F9: the push quarantine is left in place for a worker whose absence is unconfirmed"
    else
        fail "F9: the tripwire was stripped from a possibly-live worker" "$out"
    fi
else
    echo "  SKIP: F7-F9 require the Windows/MSYS _PROC_TREE_PROC_ROOT liveness seam (proc_tree_process_alive uses kill -0 on this platform and ignores it)"
fi

echo "RUN G: registry-root override gating (HIMMEL-1693 CR, codex-1)"

# G1: a plain BRIDGE_ROOT env WITHOUT the explicit STOP_WORKER_BRIDGE_ROOT_OVERRIDE
# flag must be IGNORED -- the canonical root (~/.claude/handover/bridge) is used
# instead, so the lookup MISSES this fixture registry entirely. Before the fix,
# stop-worker.sh trusted a plain BRIDGE_ROOT the same way await-glm-worker.sh
# does, which let a caller aim it at a forged registry and get an arbitrary-
# process-kill primitive through the sanctioned STOP chokepoint. Run in a
# subshell so `unset` does not affect the rest of this suite (every other RUN
# needs the seam exported).
mk_session glm glm-envonly-1 running 999005 glm/envonly >/dev/null
out=$(unset STOP_WORKER_BRIDGE_ROOT_OVERRIDE; bash "$STOP" glm-envonly-1 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
    pass "G1: plain BRIDGE_ROOT without the test flag is ignored -- canonical root used, fixture session not found (refused)"
else
    fail "G1: expected rc=2 (fixture registry missed via the canonical root), got $rc" "$out"
fi
case "$out" in
    *"WARNING"*"BRIDGE_ROOT"*) pass "G2: a warning is printed when a plain BRIDGE_ROOT is ignored" ;;
    *) fail "G2: no warning printed for an ignored BRIDGE_ROOT" "$out" ;;
esac

# G3: with the explicit seam set (as every other RUN in this suite has it),
# the fixture registry still resolves normally.
mk_session glm glm-seamworks-1 "done" 0 glm/seamworks >/dev/null
out=$(run_stop glm-seamworks-1); rc=$?
if [ "$rc" -eq 3 ]; then
    pass "G3: with STOP_WORKER_BRIDGE_ROOT_OVERRIDE set, the fixture registry resolves normally (session found, not running)"
else
    fail "G3: expected rc=3 (session found via the seam), got $rc" "$out"
fi

# G4: whenever the override IS active, a loud banner names it as a test
# override -- never silently mistakable for the canonical registry.
case "$out" in
    *"TEST OVERRIDE"*"registry root"*) pass "G4: the loud TEST OVERRIDE banner is printed when the seam is active" ;;
    *) fail "G4: no TEST OVERRIDE banner printed" "$out" ;;
esac

echo "RUN H: STOP_WORKER_GRACE_SECS validation (HIMMEL-1693 CR round 2)"

# H1: a non-numeric GRACE must be rejected BEFORE it ever reaches
# proc_tree_terminate's `sleep "$grace"` -- a bad value there fails sleep at
# once and silently collapses the TERM grace window. Refused with usage rc=1,
# same as any other bad-input refusal.
mk_session glm glm-badgrace-1 "done" 0 glm/badgrace >/dev/null
out=$(STOP_WORKER_GRACE_SECS="notanumber" run_stop glm-badgrace-1); rc=$?
if [ "$rc" -eq 1 ]; then
    pass "H1: non-numeric STOP_WORKER_GRACE_SECS refused (exit 1)"
else
    fail "H1: expected rc=1 for a non-numeric GRACE, got $rc" "$out"
fi
case "$out" in
    *"must be a whole number of seconds"*) pass "H2: refusal message names the bad value" ;;
    *) fail "H2: refusal message did not explain the bad GRACE value" "$out" ;;
esac

# H3: a negative GRACE must also be refused -- the digit-class guard rejects
# the leading '-' the same way it rejects letters.
out=$(STOP_WORKER_GRACE_SECS="-5" run_stop glm-badgrace-1); rc=$?
if [ "$rc" -eq 1 ]; then
    pass "H3: negative STOP_WORKER_GRACE_SECS refused (exit 1)"
else
    fail "H3: expected rc=1 for a negative GRACE, got $rc" "$out"
fi

# H4: unset GRACE still falls back to the documented default of 5s and the
# rest of the run proceeds normally (not a refusal).
out=$(unset STOP_WORKER_GRACE_SECS; run_stop glm-badgrace-1); rc=$?
if [ "$rc" -eq 3 ]; then
    pass "H4: unset STOP_WORKER_GRACE_SECS falls back to the default, run proceeds (rc=3, session not running)"
else
    fail "H4: expected rc=3 (default grace, non-running session), got $rc" "$out"
fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
