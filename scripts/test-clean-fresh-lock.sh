#!/usr/bin/env bash
# Hermetic test for HIMMEL-3297 option B: clean-garden.sh's fleet-wide prune
# skips a merged worktree whose leg still holds a FRESH
# scripts/handover/queue-lock.sh lock on its own handover doc (resume_cwd:
# frontmatter naming that worktree). Temp git repo + real worktrees + a fake
# handover root + real queue-lock.sh locks. Pattern follows
# scripts/test-clean-only.sh.
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"
QUEUE_LOCK="$SCRIPT_DIR/handover/queue-lock.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
expect() {
    local label="$1" out="$2"; shift 2
    if "$@"; then pass "$label"; else fail "$label" "$out"; fi
}
is_dir() { [ -d "$1" ]; }
is_gone() { [ ! -d "$1" ]; }
rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p' | tail -1; }
rc_is() { [ "$(rc_of "$1")" = "$2" ]; }
rc_nonzero() { [ "$(rc_of "$1")" != "0" ]; }

# ── shared setup ─────────────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-clean-fresh-lock.XXXXXX")
# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/canon-path.sh"
CANON_ROOT=$(canon_path "$TMP_ROOT") || { echo "setup: canon_path failed" >&2; exit 1; }
TMP_ROOT="$CANON_ROOT"

REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$REPO" config user.email t@test.com
git -C "$REPO" config user.name t
git -C "$REPO" config maintenance.auto false
printf 'base\n' > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -m main 2>/dev/null || true
git -C "$REPO" remote add origin https://github.com/owner/repo.git
# unlanded-work.sh (folded into --health) compares against origin/main; the
# fixture has no real remote.
git -C "$REPO" update-ref refs/remotes/origin/main main

# Stub gh: every feat/* branch is a merged PR at its current tip.
STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# pipefail-ok: this stub has its own shebang and never sets pipefail itself,
# so each `if echo … | grep -q …` below checks only grep's exit status (the
# pipeline's last command) — HIMMEL-1430 does not reach a shell that never
# opted into pipefail.
args="$*"
if echo "$args" | grep -q "auth status"; then exit 0; fi
if echo "$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi
if echo "$args" | grep -q "api --paginate repos/owner/repo/pulls"; then
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\tmerged\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/feat)
    exit 0
fi
if echo "$args" | grep -q "pr list"; then
    git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/feat \
        | jq -Rn '[inputs | split(" ") | {headRefName: .[0], number: 1, state: "MERGED", headRefOid: .[1], baseRefName: "main"}]'
    exit 0
fi
if echo "$args" | grep -q -- "--state merged"; then echo "1"; exit 0; fi
if echo "$args" | grep -q -- "--state open"; then exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

mk_wt() {
    local name="$1" branch="$2"
    git -C "$REPO" worktree add -q "$TMP_ROOT/$name" -b "$branch" >/dev/null 2>&1
    echo "$TMP_ROOT/$name"
}

HANDOVER_ROOT="$TMP_ROOT/handover-root"
mkdir -p "$HANDOVER_ROOT"

# mk_doc <name> <resume_cwd> — a handover doc with resume_cwd: frontmatter.
mk_doc() {
    local name="$1" cwd="$2" doc="$HANDOVER_ROOT/$1"
    cat > "$doc" <<EOF
---
resume_cwd: $cwd
template_version: 3
---

# fixture doc
EOF
    printf '%s' "$doc"
}

# lock_fresh <doc> — a real queue-lock.sh acquire; heartbeat is "now" (FRESH).
lock_fresh() {
    HANDOVER_DIR="$HANDOVER_ROOT" bash "$QUEUE_LOCK" acquire "$1" "fixture-fresh-$$" >/dev/null 2>&1
}

# lock_stale <doc> — acquire, then backdate the heartbeat past the TTL.
lock_stale() {
    local doc="$1"
    HANDOVER_DIR="$HANDOVER_ROOT" bash "$QUEUE_LOCK" acquire "$doc" "fixture-stale-$$" >/dev/null 2>&1
    local slug lockdir
    slug=$(printf '%s' "${doc#"$HANDOVER_ROOT"/}" | sed 's/\.md$//; s#/#__#g' | tr -c 'A-Za-z0-9_-' '-')
    lockdir="$HANDOVER_ROOT/.locks/queue/$slug.lock"
    printf '{"session":"fixture-stale-%s","host":"h","handover":"%s","started":"2020-01-01T00:00:00Z","heartbeat":"2020-01-01T00:00:00Z"}\n' "$$" "$doc" \
        > "$lockdir/owner.json"
}

# run_clean <args...> — runs clean-garden.sh from inside the fixture repo with
# the fixture handover root exported; prints combined output then "rc=<n>".
run_clean() {
    (
        export PATH="${STUB_DIR}:${PATH}"
        export HANDOVER_DIR="$HANDOVER_ROOT"
        cd "$REPO" || exit 1
        set +e
        out=$(bash "$CLEAN_GARDEN" "$@" 2>&1)
        rc=$?
        printf '%s\nrc=%s\n' "$out" "$rc"
    )
}

WT_FRESH=$(mk_wt wt-fresh feat/fresh)
WT_STALE=$(mk_wt wt-stale feat/stale)
WT_FREE=$(mk_wt wt-free feat/free)
WT_ONLY=$(mk_wt wt-only feat/only)

DOC_FRESH=$(mk_doc doc-fresh.md "$WT_FRESH")
DOC_STALE=$(mk_doc doc-stale.md "$WT_STALE")
DOC_ONLY=$(mk_doc doc-only.md "$WT_ONLY")
mk_doc doc-free.md "$WT_FREE" >/dev/null   # no lock ever taken for this one

lock_fresh "$DOC_FRESH"
lock_stale "$DOC_STALE"
lock_fresh "$DOC_ONLY"

# ── case 1: a merged worktree whose leg holds a FRESH lock is skipped ────────
echo "CASE 1: FRESH lock blocks the fleet-wide sweep"
out=$(run_clean --prune-only)
expect "1: FRESH-locked worktree survives" "$out" is_dir "$WT_FRESH"
expect "1: reason names the leg doc" "$out" grepq "$out" "FRESH queue lock"
expect "1: reason line cites the doc path" "$out" grepq "$out" -F "$DOC_FRESH"

# ── control: a STALE lock does not block the prune ───────────────────────────
echo "CONTROL: STALE lock is pruned as before"
expect "2: STALE-locked worktree pruned" "$out" is_gone "$WT_STALE"

# ── control: no lock at all (free) is pruned as before ───────────────────────
echo "CONTROL: free (unlocked) worktree is pruned as before"
expect "3: unlocked worktree pruned" "$out" is_gone "$WT_FREE"

# ── case 4: --only on a FRESH-locked worktree refuses with the same reason ───
echo "CASE 4: --only on a FRESH-locked worktree"
out=$(run_clean --only "$WT_ONLY")
expect "4: rc nonzero" "$out" rc_nonzero "$out"
expect "4: worktree kept" "$out" is_dir "$WT_ONLY"
expect "4: same FRESH-lock reason" "$out" grepq "$out" "FRESH queue lock"

# ── case 5: once the lock is released, the fleet-wide sweep prunes it ────────
echo "CASE 5: released lock, sweep prunes"
tok=$(HANDOVER_DIR="$HANDOVER_ROOT" bash "$QUEUE_LOCK" status "$DOC_FRESH" 2>/dev/null | sed -n 's/.*"session":"\([^"]*\)".*/\1/p')
HANDOVER_DIR="$HANDOVER_ROOT" bash "$QUEUE_LOCK" release "$DOC_FRESH" "$tok" >/dev/null 2>&1
out=$(run_clean --prune-only)
expect "5: previously FRESH-locked worktree pruned once released" "$out" is_gone "$WT_FRESH"

# ── case 6: --health is unaffected once the transient skip resolves ──────────
# (WT_ONLY's lock was never released, so its own FRESH-lock skip is genuinely
# still live and correctly feeds the SAME stuck-sweep bookkeeping every other
# skip reason already uses — releasing it here isolates that from the
# question this control actually asks: does a RESOLVED FRESH-lock skip leave
# any --health residue behind? It must not, same as any other resolved skip.)
echo "CASE 6: --health output unchanged"
tok_only=$(HANDOVER_DIR="$HANDOVER_ROOT" bash "$QUEUE_LOCK" status "$DOC_ONLY" 2>/dev/null | sed -n 's/.*"session":"\([^"]*\)".*/\1/p')
HANDOVER_DIR="$HANDOVER_ROOT" bash "$QUEUE_LOCK" release "$DOC_ONLY" "$tok_only" >/dev/null 2>&1
run_clean --prune-only >/dev/null
out=$(run_clean --health)
expect "6: --health rc=0 (no alarms) once every FRESH-lock skip resolves" "$out" rc_is "$out" 0

echo
echo "test-clean-fresh-lock: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
