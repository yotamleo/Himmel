#!/usr/bin/env bash
# Hermetic test for `clean-garden.sh --only <worktree-path|branch>` (HIMMEL-3297):
# prune exactly ONE worktree, so a console wrapping one leg cannot reach across
# a fleet-wide sweep and remove another live leg's cwd. Temp git repo + real
# worktrees + a stub gh that reports every feat/* branch as merged at its tip.
# Pattern follows scripts/test-clean-prune-strays.sh.
set -uo pipefail

# grepq <text> [grep-args...] — `grep -q` against <text> with NO pipeline
# (pipefail + early-exit grep = false negatives; HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"
CLEAN_SH="$SCRIPT_DIR/clean.sh"

PASS=0
FAIL=0
TMP_ROOT=""
HOLDER_PID=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null || true; fi
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
# expect <label> <output> <command...> — pass when the command succeeds.
expect() {
    local label="$1" out="$2"; shift 2
    if "$@"; then pass "$label"; else fail "$label" "$out"; fi
}
# expect_not <label> <output> <command...> — pass when the command reports
# absence (status 1); any other non-zero status is an execution error, a fail.
expect_not() {
    local label="$1" out="$2" rc=0; shift 2
    "$@" || rc=$?
    if [ "$rc" -eq 1 ]; then pass "$label"; else fail "$label" "status=$rc: $out"; fi
}
is_dir() { [ -d "$1" ]; }
is_gone() { [ ! -d "$1" ]; }
rc_is() { [ "$(rc_of "$1")" = "$2" ]; }
rc_nonzero() { [ "$(rc_of "$1")" != "0" ]; }
has_branch() { git -C "$REPO" rev-parse --verify -q "refs/heads/$1" >/dev/null; }

# ── shared setup ─────────────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-clean-only.XXXXXX")
# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/canon-path.sh"
CANON_ROOT=$(canon_path "$TMP_ROOT") || { echo "setup: canon_path failed" >&2; exit 1; }
TMP_ROOT="$CANON_ROOT"
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

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
# A real local bare repo as origin (not a fake https URL) so the
# HIMMEL-3747 --only-allow-unmerged "head is on the remote" check can do a
# genuine `git ls-remote origin` — gh (stubbed below) still answers the PR
# cache/NWO lookups, independent of this URL.
ORIGIN_BARE="$TMP_ROOT_UNIX/origin.git"
git init -q --bare "$ORIGIN_BARE"
git -C "$REPO" remote add origin "$ORIGIN_BARE"

# Stub gh: every feat/* branch is a merged PR at its current tip; open/* and
# closed/* branches get a PR row in that state (HIMMEL-3747 fixtures); any
# other branch has no PR row at all ("none").
STUB_DIR="$TMP_ROOT_UNIX/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if echo "$args" | grep -q "auth status"; then exit 0; fi
if echo "$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi
if echo "$args" | grep -q "api --paginate repos/owner/repo/pulls"; then
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\tmerged\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/feat)
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\topen\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/open)
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\tclosed\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/closed)
    exit 0
fi
if echo "$args" | grep -q -- "--state merged"; then echo "1"; exit 0; fi
if echo "$args" | grep -q -- "--state open"; then exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# A second stub whose PR-cache fetch fails outright (HIMMEL-3747: models an
# unresolvable PR_STATE — gh/cache failure — which must stay fail-closed
# even under --only-allow-unmerged).
STUB_DIR_FAIL="$TMP_ROOT_UNIX/bin-fail"
mkdir -p "$STUB_DIR_FAIL"
cat > "$STUB_DIR_FAIL/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if echo "$args" | grep -q "auth status"; then exit 0; fi  # pipefail-ok: $args is a small captured argv
if echo "$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi  # pipefail-ok: same $args
if echo "$args" | grep -q "api --paginate repos/owner/repo/pulls"; then  # pipefail-ok: same $args
    exit 1
fi
exit 0
STUB
chmod +x "$STUB_DIR_FAIL/gh"

mk_wt() {
    local name="$1" branch="$2"
    git -C "$REPO" worktree add -q "$TMP_ROOT/$name" -b "$branch" >/dev/null 2>&1
    echo "$TMP_ROOT/$name"
}

# run_clean <script> <args...> — runs from inside the fixture repo; prints
# combined output then a final "rc=<n>" line. Honors RUN_CLEAN_STUB_DIR to
# swap in the failing-gh stub for one call (HIMMEL-3747 unknown-state case).
run_clean() {
    local script="$1"; shift
    (
        export PATH="${RUN_CLEAN_STUB_DIR:-$STUB_DIR}:${PATH}"
        # origin is a real local bare repo (for ls-remote), not a github.com
        # URL, so force forge detection past its origin-hostname sniff.
        export FORGE=github
        cd "$REPO" || exit 1
        set +e
        out=$(bash "$script" "$@" 2>&1)
        rc=$?
        printf '%s\nrc=%s\n' "$out" "$rc"
    )
}
rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p' | tail -1; }

WT_A=$(mk_wt wt-a feat/a)          # the --only target (path form)
WT_B=$(mk_wt wt-b feat/b)          # merged sibling — must SURVIVE an --only run
WT_C=$(mk_wt wt-c feat/c)          # --only target (branch form)
WT_D=$(mk_wt wt-d feat/d)          # merged sibling — must survive
WT_OPEN=$(mk_wt wt-open wip/open)  # no merged PR — --only must refuse
WT_DIRTY=$(mk_wt wt-dirty feat/dirty)
printf 'changed\n' >> "$WT_DIRTY/README"   # tracked change — --only must refuse
WT_HELD=$(mk_wt wt-held feat/held) # a live process's cwd — --only must refuse
WT_DRY=$(mk_wt wt-dry feat/dry)

# ── case 1: --only <path> prunes that worktree ONLY ──────────────────────────
echo "CASE 1: --only <path>"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_A")
expect "1: rc=0" "$out" rc_is "$out" 0
expect "1: target worktree pruned" "$out" is_gone "$WT_A"
# RED core: a fleet-wide sweep would have taken every merged sibling.
expect "1: merged sibling wt-b survived" "$out" is_dir "$WT_B"
expect "1: merged sibling wt-d survived" "$out" is_dir "$WT_D"
expect "1: merged sibling wt-held survived" "$out" is_dir "$WT_HELD"
expect "1: sibling branch feat/b kept" "$out" has_branch feat/b
expect_not "1: target branch feat/a deleted with its worktree" "$out" has_branch feat/a

# ── case 2: --only <branch> ──────────────────────────────────────────────────
echo "CASE 2: --only <branch>"
out=$(run_clean "$CLEAN_GARDEN" --only feat/c)
expect "2: rc=0" "$out" rc_is "$out" 0
expect "2: target worktree pruned by branch name" "$out" is_gone "$WT_C"
expect "2: siblings survived" "$out" is_dir "$WT_B"

# ── case 3: refuses a non-candidate, non-zero, worktree kept ─────────────────
echo "CASE 3: refusals"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_OPEN")
expect "3a: un-merged target refused non-zero" "$out" rc_nonzero "$out"
expect "3a: un-merged target kept" "$out" is_dir "$WT_OPEN"
expect "3a: message names the refusal" "$out" grepq "$out" "not a prune candidate"

out=$(run_clean "$CLEAN_GARDEN" --only feat/dirty)
expect "3b: dirty target refused non-zero" "$out" rc_nonzero "$out"
expect "3b: dirty target kept" "$out" is_dir "$WT_DIRTY"
expect "3b: dirty check still fires under --only" "$out" grepq "$out" "uncommitted changes"

out=$(run_clean "$CLEAN_GARDEN" --only "$REPO")
expect "3c: primary refused non-zero" "$out" rc_nonzero "$out"
expect "3c: primary untouched" "$out" is_dir "$REPO/.git"

out=$(run_clean "$CLEAN_GARDEN" --only feat/no-such-branch)
expect "3d: unknown target refused non-zero" "$out" rc_nonzero "$out"
expect "3d: message names the refusal" "$out" grepq "$out" "not a registered worktree"

# ── case 4: a live process's cwd still blocks --only (worktree_in_use) ───────
echo "CASE 4: live cwd holder"
# PLATFORM GUARD: worktree-inuse detects a live cwd holder by scanning /proc; hosts
# without it (macOS) fall back to a rename probe that cannot see a holder
# (HIMMEL-2602), so the refusal cannot be provoked there and is skipped.
# ponytail: holder refusal unexercised off Linux, add an lsof-based scan to worktree-inuse if macOS in-use detection is wanted (HIMMEL-2602).
if [ -d /proc/self ]; then
( cd "$WT_HELD" && exec sleep 60 ) &
HOLDER_PID=$!
sleep 0.3
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_HELD")
expect "4: live-cwd target refused non-zero" "$out" rc_nonzero "$out"
expect "4: live-cwd target kept" "$out" is_dir "$WT_HELD"
expect "4: message says in use" "$out" grepq "$out" "in use"
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
else
echo "  SKIP: 4: no /proc on this platform, live-cwd holder cannot be detected"
fi
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_HELD")
expect "4 control: same target with no holder is pruned" "$out" is_gone "$WT_HELD"

# ── case 5: --dry-run under --only mutates nothing ───────────────────────────
echo "CASE 5: --only --dry-run"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_DRY" --dry-run)
expect "5: rc=0" "$out" rc_is "$out" 0
expect "5: dry-run names the target" "$out" grepq "$out" "would prune feat/dry"
expect_not "5: dry-run plans no sibling" "$out" grepq "$out" "would prune feat/b"
expect "5: dry-run removed nothing" "$out" is_dir "$WT_DRY"

# ── case 6: flag hygiene ─────────────────────────────────────────────────────
echo "CASE 6: flag hygiene"
out=$(run_clean "$CLEAN_GARDEN" --only)
expect "6a: --only with no value refused" "$out" rc_nonzero "$out"
expect "6a: usage error names the flag" "$out" grepq "$out" -e "--only needs"
out=$(run_clean "$CLEAN_GARDEN" feat/newone --only feat/b)
expect "6b: --only with a create branch refused" "$out" rc_nonzero "$out"
expect "6b: nothing pruned" "$out" is_dir "$WT_B"
out=$(run_clean "$CLEAN_GARDEN" --only feat/b --no-prune)
expect "6c: --only with --no-prune refused" "$out" rc_nonzero "$out"
expect "6c: nothing pruned" "$out" is_dir "$WT_B"

# ── case 7: clean.sh forwards --only ─────────────────────────────────────────
echo "CASE 7: clean.sh passthrough"
out=$(run_clean "$CLEAN_SH" --only feat/d)
expect "7: rc=0" "$out" rc_is "$out" 0
expect "7: clean.sh --only pruned the target" "$out" is_gone "$WT_D"
expect "7: sibling feat/b survived" "$out" is_dir "$WT_B"

# ── case 8: an ambiguous target (path of one worktree, branch of another) ────
echo "CASE 8: ambiguous target"
mkdir -p "$REPO/feat"
git -C "$REPO" worktree add -q "$REPO/feat/amb" -b feat/amb-holder >/dev/null 2>&1
WT_AMB_BR=$(mk_wt wt-amb-br feat/amb)   # branch feat/amb; the other one's PATH is repo/feat/amb
out=$(run_clean "$CLEAN_GARDEN" --only feat/amb)
expect "8: ambiguous target refused non-zero" "$out" rc_nonzero "$out"
expect "8: message names the ambiguity" "$out" grepq "$out" "matches 2 worktrees"
expect "8: path-matched worktree kept" "$out" is_dir "$REPO/feat/amb"
expect "8: branch-matched worktree kept" "$out" is_dir "$WT_AMB_BR"

# ── case 9: --only-allow-unmerged (HIMMEL-3747) ──────────────────────────────
echo "CASE 9: --only-allow-unmerged"

WT_UA_NONE=$(mk_wt wt-ua-none none/case)
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_NONE")
expect "9a control: no-PR branch refused WITHOUT the flag" "$out" rc_nonzero "$out"
expect "9a control: kept" "$out" is_dir "$WT_UA_NONE"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_NONE" --only-allow-unmerged)
expect "9a: no-PR branch, clean, zero-ahead pruned WITH the flag" "$out" is_gone "$WT_UA_NONE"

WT_UA_CLOSED=$(mk_wt wt-ua-closed closed/case)
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_CLOSED" --only-allow-unmerged)
expect "9b: closed-unmerged PR, clean, zero-ahead pruned WITH the flag" "$out" is_gone "$WT_UA_CLOSED"

WT_UA_OPEN=$(mk_wt wt-ua-open open/case)
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_OPEN" --only-allow-unmerged)
expect "9c: OPEN PR still refused even WITH the flag" "$out" rc_nonzero "$out"
expect "9c: open-PR worktree kept" "$out" is_dir "$WT_UA_OPEN"

WT_UA_DIRTY=$(mk_wt wt-ua-dirty none/dirty)
printf 'changed\n' >> "$WT_UA_DIRTY/README"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_DIRTY" --only-allow-unmerged)
expect "9d: dirty tree still refused WITH the flag" "$out" rc_nonzero "$out"
expect "9d: dirty worktree kept" "$out" is_dir "$WT_UA_DIRTY"

WT_UA_PUSHED=$(mk_wt wt-ua-pushed none/pushed)
printf 'extra\n' > "$WT_UA_PUSHED/extra.txt"
git -C "$WT_UA_PUSHED" add extra.txt
git -C "$WT_UA_PUSHED" commit -q -m "extra commit ahead of main"
git -C "$REPO" push -q origin "none/pushed:refs/heads/none/pushed"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_PUSHED" --only-allow-unmerged)
expect "9e: ahead-of-main but head pushed to origin pruned WITH the flag" "$out" is_gone "$WT_UA_PUSHED"

# 9g (HIMMEL-4334): a never-merged branch's leg scratch may be its only copy,
# so the root-scratch arms do NOT apply under --only-allow-unmerged; only tool
# churn (package-lock.json) stays discardable.
WT_UA_SCRATCH=$(mk_wt wt-ua-scratch none/scratch)
printf 'x\n' > "$WT_UA_SCRATCH/.pr-body.txt"
mkdir -p "$WT_UA_SCRATCH/.scratch"; printf 'x\n' > "$WT_UA_SCRATCH/.scratch/a.txt"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_SCRATCH" --only-allow-unmerged)
expect "9g: unmerged branch with root scratch refused WITH the flag" "$out" rc_nonzero "$out"
expect "9g: unmerged scratch worktree kept" "$out" is_dir "$WT_UA_SCRATCH"
WT_UA_CHURN=$(mk_wt wt-ua-churn none/churn)
printf 'lock\n' > "$WT_UA_CHURN/package-lock.json"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_CHURN" --only-allow-unmerged)
expect "9g control: tool churn alone still pruned WITH the flag" "$out" is_gone "$WT_UA_CHURN"

# 9g2 (HIMMEL-4334 judge J1806u): the REAL repo .gitignore must not hide
# .himmel-scratch/ from the stray scan, or `git worktree remove` would delete a
# never-merged branch's only scratch. Branch pushed so the ahead check passes.
WT_UA_REAL=$(mk_wt wt-ua-real none/realignore)
cp "$SCRIPT_DIR/../.gitignore" "$WT_UA_REAL/.gitignore"
git -C "$WT_UA_REAL" add .gitignore
git -C "$WT_UA_REAL" commit -q -m "carry the real repo .gitignore"
git -C "$REPO" push -q origin "none/realignore:refs/heads/none/realignore"
mkdir -p "$WT_UA_REAL/.himmel-scratch"; printf 'x\n' > "$WT_UA_REAL/.himmel-scratch/notes.md"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_REAL" --only-allow-unmerged)
expect "9g2: .himmel-scratch/notes.md under the REAL .gitignore refused WITH the flag" "$out" rc_is "$out" 1
expect "9g2: worktree with .himmel-scratch kept" "$out" is_dir "$WT_UA_REAL"

WT_UA_NOTPUSHED=$(mk_wt wt-ua-notpushed none/notpushed)
printf 'extra\n' > "$WT_UA_NOTPUSHED/extra.txt"
git -C "$WT_UA_NOTPUSHED" add extra.txt
git -C "$WT_UA_NOTPUSHED" commit -q -m "extra commit, never pushed"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_UA_NOTPUSHED" --only-allow-unmerged)
expect "9f: ahead-of-main and NOT on origin refused WITH the flag" "$out" rc_nonzero "$out"
expect "9f: unpushed-ahead worktree kept" "$out" is_dir "$WT_UA_NOTPUSHED"

WT_UA_UNKNOWN=$(mk_wt wt-ua-unknown none/unknown)
out=$(RUN_CLEAN_STUB_DIR="$STUB_DIR_FAIL" run_clean "$CLEAN_GARDEN" --only "$WT_UA_UNKNOWN" --only-allow-unmerged)
expect "9g: unresolvable PR state (gh/cache failure) refused WITH the flag" "$out" rc_nonzero "$out"
expect "9g: unknown-state worktree kept" "$out" is_dir "$WT_UA_UNKNOWN"

out=$(run_clean "$CLEAN_GARDEN" --only-allow-unmerged)
expect "9h: --only-allow-unmerged with no --only refused" "$out" rc_nonzero "$out"
expect "9h: usage error names the flag" "$out" grepq "$out" -e "--only-allow-unmerged requires --only"

# ── control: the plain (fleet-wide) run still prunes every merged sibling ────
echo "CONTROL: plain --prune-only"
out=$(run_clean "$CLEAN_GARDEN" --prune-only)
expect "control: plain prune still takes the merged sibling feat/b" "$out" is_gone "$WT_B"

echo
echo "test-clean-only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
