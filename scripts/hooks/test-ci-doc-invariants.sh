#!/usr/bin/env bash
# Regression test for the CI `doc-invariants` job (HIMMEL-1305).
#
# The job mirrors three himmel-dev pre-commit gates into CI so the committed
# tree is validated by committed tooling. Those gates are pre-commit hooks:
# each triggers off `git diff --cached` and exits 0 when its inputs are not
# staged. A CI checkout's index is identical to HEAD, so WITHOUT the job's
# staging step every gate no-ops and the job is green-by-vacuum.
#
# THE CASES COMMIT THEIR BREAKAGE. That is the whole design: a case that only
# dirties the working tree proves nothing, because the dirt is itself what
# makes `git diff --cached` non-empty — the gate would fire for a reason CI
# never has. Committing leaves the tree pristine-vs-HEAD and broken, which is
# exactly the state `actions/checkout` produces for a bad commit.
#
# Simulates CI with a fresh clone (no `.himmel-dev` marker of its own), not a
# linked worktree — a worktree resolves the marker from the primary checkout
# and would not reproduce CI's conditions.
#
# rc: 0 all cases pass | 1 a case failed | 2 cannot evaluate (setup failed).
#
# shellcheck disable=SC2317  # break_* mutators are called indirectly via "$mutate"
# shellcheck disable=SC2329  # same as SC2317 in newer shellcheck
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

pass=0
fail=0

die() { echo "→ test-ci-doc-invariants: $*" >&2; exit 2; }

src="$REPO_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    src=$(cygpath -m "$REPO_ROOT") || die "cygpath failed"
fi

tmpd=$(mktemp -d -t ci-doc-inv-XXXXXX) || die "mktemp failed"
# Retry once: on Windows a `.tokensave/*.db` inside a fresh clone can still be
# open (the code-graph server indexes repos it notices), and rm then fails on
# that file and leaves the whole tree behind. One short retry clears it in
# practice; if it still fails, stay quiet rather than emit rm noise over the
# results — these live under mktemp and CI (ubuntu) has no such locking.
cleanup() {
    rm -rf "$tmpd" 2>/dev/null && return 0
    sleep 1
    rm -rf "$tmpd" 2>/dev/null || true
}
trap cleanup EXIT

# check <description> <expected-rc> <actual-rc>
check() {
    if [ "$2" = "$3" ]; then
        echo "  ok   — $1 (rc=$3)"
        pass=$((pass + 1))
    else
        echo "  FAIL — $1 (expected rc=$2, got rc=$3)"
        fail=$((fail + 1))
    fi
}

# fresh_clone <dir> — a clean clone with the himmel-dev marker CI creates.
fresh_clone() {
    git clone -q --no-hardlinks --depth 1 "file://$src" "$1" 2>/dev/null \
        || die "clone of $src failed"
    touch "$1/.himmel-dev" || die "cannot create .himmel-dev in $1"
}

# The EXACT staging recipe the CI job runs. `checkout --orphan` leaves HEAD
# unborn, so `add -A` stages the entire tree; re-adding against the real HEAD
# would rebuild an index identical to it and stage nothing.
stage_tree() {
    git -C "$1" checkout -q --orphan ci-doc-invariants && git -C "$1" add -A
}

commit_all() {
    git -C "$1" add -A \
        && git -C "$1" -c user.email=t@t -c user.name=t commit -qm "$2"
}

run_gate() {
    ( cd "$1" && bash "scripts/hooks/$2" >/dev/null 2>&1 )
    echo $?
}

# case_gate <name> <gate-script> <mutator-fn>
# Commits the breakage (pristine tree, bad content — the CI condition), then
# asserts the gate is a false green on the RAW checkout and blocks once the
# job's staging step has run.
case_gate() {
    local name="$1" gate="$2" mutate="$3" repo rc
    repo="$tmpd/$(echo "$name" | tr -cd '[:alnum:]')"

    fresh_clone "$repo"
    "$mutate" "$repo" || die "mutator $mutate failed"
    commit_all "$repo" "break: $name" || die "commit failed for $name"

    rc=$(run_gate "$repo" "$gate")
    check "$name: raw CI checkout is a false green" 0 "$rc"

    stage_tree "$repo" >/dev/null 2>&1 || die "stage_tree failed during $name"
    rc=$(run_gate "$repo" "$gate")
    check "$name: blocks once the job's staging step ran" 1 "$rc"
}

# --- mutators (each takes the repo dir) -------------------------------------

break_agents_md() {
    printf '\n\nSTALE-MARKER-FOR-TEST\n' >> "$1/AGENTS.md"
}

# Orphan a live debrand rule by deleting the prose its `from` matches.
# Paths come in as ENV, not argv: `node -e` argv slots have differed across
# Node versions (some builds put an eval marker in argv[1]), and getting that
# wrong here would abort the whole run rather than fail one case. env is
# unambiguous everywhere.
break_debrand() {
    CLAUDE_MD="$1/CLAUDE.md" DEBRAND_JSON="$1/scripts/agents-md/debrand.json" node -e '
        const fs = require("fs");
        const claude = process.env.CLAUDE_MD, table = process.env.DEBRAND_JSON;
        const d = JSON.parse(fs.readFileSync(table, "utf8"));
        const rules = d.rules || d;
        let src = fs.readFileSync(claude, "utf8");
        const live = rules
            .map((r) => (r && (r.from !== undefined ? r.from : r[0])))
            .filter((f) => typeof f === "string" && f && src.includes(f));
        if (!live.length) { console.error("no live debrand rule to orphan"); process.exit(3); }
        const out = src.split(live[0]).join("ORPHANED-FOR-TEST");
        if (out === src) { console.error("debrand mutator was a no-op"); process.exit(4); }
        fs.writeFileSync(claude, out);
    '
}

# Re-introduce a hardcoded lane-inventory token into CLAUDE.md prose. The
# needle must not sit on the sanctioned pointer line (which is exempt).
break_lanes() {
    printf '\nRoute bulk work through spawn-glm directly.\n' >> "$1/CLAUDE.md"
}

echo "test-ci-doc-invariants (HIMMEL-1305)"
echo

# --- baseline: a pristine committed tree passes every gate, having RUN ------
# Guards the opposite direction from the cases below: the staging step must not
# make a GOOD tree fail. On its own this proves little (a no-op also returns 0)
# — the cases are what prove the gates actually execute.
echo "baseline — pristine committed tree, staged as the job stages it:"
base="$tmpd/baseline"
fresh_clone "$base"
stage_tree "$base" >/dev/null 2>&1 || die "baseline stage_tree failed"
check "pristine: agents-md-fresh passes"  0 "$(run_gate "$base" check-agents-md-fresh.sh)"
check "pristine: debrand-coverage passes" 0 "$(run_gate "$base" check-debrand-coverage.sh)"
check "pristine: lanes-inventory passes"  0 "$(run_gate "$base" check-lanes-inventory.sh)"

echo
echo "stale AGENTS.md (committed):"
case_gate "stale AGENTS.md" check-agents-md-fresh.sh break_agents_md

echo
echo "orphaned debrand rule (committed):"
case_gate "orphaned debrand rule" check-debrand-coverage.sh break_debrand

echo
echo "lane inventory in CLAUDE.md prose (committed):"
case_gate "lane inventory in prose" check-lanes-inventory.sh break_lanes

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
