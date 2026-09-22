#!/usr/bin/env bash
# Smoke test for scripts/unlanded-work.sh (HIMMEL-2070) — hermetic: builds a
# throwaway git repo per case, stubs gh via GH_CMD so no test hits the network.
# Usage: bash scripts/test-unlanded-work.sh
set -uo pipefail

# grepq <text> [grep-args...] — see scripts/test-himmel-doctor.sh header for
# why this must be a here-string, not a pipeline, under `set -o pipefail`.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/unlanded-work.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# make_repo <dir> — a base "main" (also aliased as origin/main, so the
# script's default --base origin/main resolves without a real remote).
make_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'base\n' > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -q -m "init"
    git -C "$d" branch -M main
    git -C "$d" update-ref refs/remotes/origin/main refs/heads/main
}

# commit_dated <dir> <hours-ago> <file> <content> [message] — commit on the
# CURRENT branch with an explicit author/committer date <hours-ago> hours
# before now (0 = now). Uses git's "@<unix-ts> +0000" date form — the one
# format every git build parses unconditionally (unlike the approxidate
# keywords "now" / "N hours ago", which this git build's GIT_AUTHOR_DATE
# parser rejects outright: `fatal: invalid date format: now`) — so no
# `date -d` dependency and no cross-platform/cross-git-version guessing.
#
# [message] defaults to "work: $f" (every pre-existing call site is
# unaffected). Pass a distinct one whenever two commit_dated calls would
# otherwise be IDENTICAL commit objects: same file, same content, same
# hours_ago, same default message, AND the same parent (e.g. a branch-side
# commit and a main-side commit made right after `checkout main`, before
# main has diverged). If both calls also land in the same wall-clock second
# (ts collision — a real risk on a fast machine, not a hypothetical), every
# field git hashes — tree, parent, message, author date, committer date — is
# equal, so git produces the SAME SHA for both: main and the branch become
# literally the same commit. `rev-list --count BASE..branch` is then 0, the
# `[ "$ahead" -gt 0 ] || continue` guard in unlanded-work.sh skips the branch
# entirely, and the fixture's row goes MISSING (not misclassified) — the
# HIMMEL-2508 "reverse-applies"/"human report" flake. Give the second commit
# a distinct message to force a distinct object.
commit_dated() {
    local d="$1" hours_ago="$2" f="$3" content="$4" msg="${5:-work: $3}" ts
    ts=$(( $(date +%s) - hours_ago * 3600 ))
    printf '%s\n' "$content" > "$d/$f"
    git -C "$d" add "$f"
    GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" git -C "$d" commit -q -m "$msg"
}

# make_gh_stub <dir> <branch:state:number[:sha[:base]] ...> — a gh stub
# answering `gh pr list --state all --limit 1000 --json
# headRefName,number,state,headRefOid,baseRefName` with a fixed JSON array
# built from the given rows (state is OPEN|MERGED|CLOSED). sha is optional
# (defaults to empty, i.e. never matches a real tip) — a MERGED row only
# counts when its sha equals the branch's CURRENT tip (codex-1, HIMMEL-2070
# CR round 1). base is optional (defaults to "main", matching every existing
# test's --base main) — a MERGED row only counts when its base equals the
# script's configured base (codex-4, CR round 4).
make_gh_stub() {
    local d="$1"; shift
    mkdir -p "$d"
    local rows="" row branch state number sha base sep=""
    for row in "$@"; do
        IFS=: read -r branch state number sha base <<< "$row"
        rows="${rows}${sep}{\"headRefName\":\"$branch\",\"state\":\"$state\",\"number\":$number,\"headRefOid\":\"${sha:-}\",\"baseRefName\":\"${base:-main}\"}"
        sep=","
    done
    cat > "$d/gh" <<EOF
#!/bin/sh
echo '[$rows]'
EOF
    chmod +x "$d/gh"
}

# tsv_row <tsv> <branch> — the matching TSV row (empty if none).
tsv_row() { printf '%s\n' "$1" | awk -F'\t' -v b="$2" '$2==b'; }

echo "== --help exits 0 =="
out="$(bash "$SCRIPT" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'Usage: unlanded-work.sh'; then pass "--help -> rc0"; else fail "--help -> rc=$rc"; fi

echo "== usage errors -> rc 2 =="
bash "$SCRIPT" --unknown-flag >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "unknown flag -> rc2"; else fail "unknown flag -> rc=$rc"; fi
bash "$SCRIPT" --class bogus >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "bad --class -> rc2"; else fail "bad --class -> rc=$rc"; fi
bash "$SCRIPT" --age-hours notanumber >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "bad --age-hours -> rc2"; else fail "bad --age-hours -> rc=$rc"; fi

echo "== unresolvable --base -> still exits 0, advisory =="
t="$(mktemp -d)"; make_repo "$t/repo"
out="$(cd "$t/repo" && bash "$SCRIPT" --base origin/does-not-exist --tsv 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "unresolvable base -> rc0, no rows"; else fail "unresolvable base -> rc=$rc out=$out"; fi
rm -rf "$t"

echo "== branch whose delta reverse-applies -> LANDED-ELSEWHERE =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/reverse-applies
commit_dated "$t/repo" 0 extra.md "reverse-apply me"
git -C "$t/repo" checkout -q main
# Land the SAME content on main (a different commit, same net diff) so the
# branch's delta reverse-applies against main's current tree. Distinct
# message (see commit_dated) so this doesn't collapse to the branch-side
# commit's exact SHA when both land in the same wall-clock second.
commit_dated "$t/repo" 0 extra.md "reverse-apply me" "landed on main: extra.md"
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1)"
row="$(tsv_row "$out" feat/reverse-applies)"
if grepq "$row" '^LANDED-ELSEWHERE' && grepq "$row" -F 'content already on main'; then
    pass "reverse-applies -> LANDED-ELSEWHERE"
else
    fail "reverse-applies -> $row"
fi
rm -rf "$t"

echo "== branch conflicts with main, ticket key ON main -> LANDED-ELSEWHERE =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b fix/himmel-9101-thing
commit_dated "$t/repo" 0 conflict.md "branch version"
git -C "$t/repo" checkout -q main
commit_dated "$t/repo" 0 conflict.md "main version, different content"
git -C "$t/repo" commit -q --amend -m "fix: [HIMMEL-9101] landed a different way"
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1)"
row="$(tsv_row "$out" fix/himmel-9101-thing)"
if grepq "$row" '^LANDED-ELSEWHERE' && grepq "$row" -F 'HIMMEL-9101 landed on main as'; then
    pass "conflict + key-on-main -> LANDED-ELSEWHERE"
else
    fail "conflict + key-on-main -> $row"
fi
rm -rf "$t"

echo "== branch conflicts with main, ticket key NOT on main -> STALE =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b fix/himmel-9102-thing
commit_dated "$t/repo" 0 conflict.md "branch version"
git -C "$t/repo" checkout -q main
commit_dated "$t/repo" 0 conflict.md "unrelated main version"
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1)"
row="$(tsv_row "$out" fix/himmel-9102-thing)"
if grepq "$row" '^STALE' && grepq "$row" -F 'no HIMMEL-9102 commit on main'; then
    pass "conflict + no key-on-main -> STALE"
else
    fail "conflict + no key-on-main -> $row"
fi
rm -rf "$t"

echo "== branch applies cleanly, no PR -> UNLANDED-LIVE =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9103-clean
commit_dated "$t/repo" 0 newfile.md "brand new content"
git -C "$t/repo" checkout -q main
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1)"
row="$(tsv_row "$out" feat/himmel-9103-clean)"
if grepq "$row" '^UNLANDED-LIVE'; then
    pass "clean apply, no PR -> UNLANDED-LIVE"
else
    fail "clean apply, no PR -> $row"
fi
rm -rf "$t"

echo "== same branch backdated past the threshold -> AGED flag set =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9104-old
commit_dated "$t/repo" 50 newfile.md "old content"
git -C "$t/repo" checkout -q main
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1)"
row="$(tsv_row "$out" feat/himmel-9104-old)"
aged="$(printf '%s' "$row" | awk -F'\t' '{print $5}')"
if grepq "$row" '^UNLANDED-LIVE' && [ "$aged" = "1" ]; then
    pass "backdated branch -> AGED=1"
else
    fail "backdated branch -> $row"
fi
rm -rf "$t"

echo "== --age-hours raises the threshold -> same branch no longer AGED =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9105-old2
commit_dated "$t/repo" 50 newfile.md "old content"
git -C "$t/repo" checkout -q main
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --age-hours 100 --tsv 2>&1)"
row="$(tsv_row "$out" feat/himmel-9105-old2)"
aged="$(printf '%s' "$row" | awk -F'\t' '{print $5}')"
if grepq "$row" '^UNLANDED-LIVE' && [ "$aged" = "0" ]; then
    pass "--age-hours 100 -> AGED=0 for a 50h-old branch"
else
    fail "--age-hours 100 -> $row"
fi
rm -rf "$t"

echo "== forge: open PR -> ACTIVE =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9106-active
commit_dated "$t/repo" 0 newfile.md "content"
git -C "$t/repo" checkout -q main
make_gh_stub "$t/stub" "feat/himmel-9106-active:OPEN:42"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --tsv 2>&1)"
row="$(tsv_row "$out" feat/himmel-9106-active)"
if grepq "$row" '^ACTIVE' && grepq "$row" -F 'open PR #42'; then
    pass "forge open PR -> ACTIVE"
else
    fail "forge open PR -> $row"
fi
rm -rf "$t"

echo "== forge: merged PR at the CURRENT tip -> LANDED-ELSEWHERE (even though the delta still conflicts) =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9107-merged
commit_dated "$t/repo" 0 conflict.md "branch version"
git -C "$t/repo" checkout -q main
commit_dated "$t/repo" 0 conflict.md "unrelated main version"
tip9107="$(git -C "$t/repo" rev-parse feat/himmel-9107-merged)"
make_gh_stub "$t/stub" "feat/himmel-9107-merged:MERGED:43:$tip9107"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --tsv 2>&1)"
row="$(tsv_row "$out" feat/himmel-9107-merged)"
if grepq "$row" '^LANDED-ELSEWHERE' && grepq "$row" -F 'merged PR #43'; then
    pass "forge merged PR (tip match) -> LANDED-ELSEWHERE"
else
    fail "forge merged PR (tip match) -> $row"
fi
rm -rf "$t"

# codex-1 (HIMMEL-2070 CR round 1): a MERGED PR recorded against a branch
# name whose CURRENT tip has since moved (reused/rewound branch name) must
# NOT be trusted as forge evidence — it falls through to the git-based rules
# instead of asserting LANDED-ELSEWHERE off a stale tip.
echo "== forge: merged PR at a STALE (non-current) tip -> NOT LANDED-ELSEWHERE via forge =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9115-stale-tip
commit_dated "$t/repo" 0 newfile.md "fresh content, never landed"
git -C "$t/repo" checkout -q main
make_gh_stub "$t/stub" "feat/himmel-9115-stale-tip:MERGED:99:0000000000000000000000000000000000000000"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --tsv 2>&1)"
row="$(tsv_row "$out" feat/himmel-9115-stale-tip)"
if grepq "$row" '^UNLANDED-LIVE'; then
    pass "forge merged PR (stale tip) -> falls through to UNLANDED-LIVE, not forge-asserted LANDED-ELSEWHERE"
else
    fail "forge merged PR (stale tip) -> $row"
fi
rm -rf "$t"

# codex-4 (HIMMEL-2070 CR round 4): a MERGED PR recorded against a DIFFERENT
# base branch (never necessarily landed on the configured --base at all)
# must not be trusted as forge evidence either -- same fall-through as a
# stale tip.
echo "== forge: merged PR against a DIFFERENT base branch -> NOT LANDED-ELSEWHERE via forge =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9117-wrong-base
commit_dated "$t/repo" 0 newfile2.md "fresh content, never landed on main"
git -C "$t/repo" checkout -q main
tip9117="$(git -C "$t/repo" rev-parse feat/himmel-9117-wrong-base)"
make_gh_stub "$t/stub" "feat/himmel-9117-wrong-base:MERGED:100:$tip9117:some-other-branch"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --tsv 2>&1)"
row="$(tsv_row "$out" feat/himmel-9117-wrong-base)"
if grepq "$row" '^UNLANDED-LIVE'; then
    pass "forge merged PR (wrong base) -> falls through to UNLANDED-LIVE, not forge-asserted LANDED-ELSEWHERE"
else
    fail "forge merged PR (wrong base) -> $row"
fi
rm -rf "$t"

echo "== forge unavailable (--no-forge) -> classification stays LOUD, no crash, exit 0 =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9108-noforge
commit_dated "$t/repo" 0 newfile.md "content"
git -C "$t/repo" checkout -q main
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1)"; rc=$?
row="$(tsv_row "$out" feat/himmel-9108-noforge)"
if [ "$rc" -eq 0 ] && grepq "$row" '^UNLANDED-LIVE'; then
    pass "--no-forge -> UNLANDED-LIVE (louder class), rc0"
else
    fail "--no-forge -> rc=$rc; $row"
fi
rm -rf "$t"

echo "== stub gh FAILS -> fail-OPEN: treated as forge-unknown, classes stay LOUD, no crash =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9109-ghfail
commit_dated "$t/repo" 0 newfile.md "content"
git -C "$t/repo" checkout -q main
mkdir -p "$t/stub"; printf '#!/bin/sh\nexit 1\n' > "$t/stub/gh"; chmod +x "$t/stub/gh"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --tsv 2>&1)"; rc=$?
row="$(tsv_row "$out" feat/himmel-9109-ghfail)"
if [ "$rc" -eq 0 ] && grepq "$row" '^UNLANDED-LIVE'; then
    pass "gh failure -> fail-open, UNLANDED-LIVE, rc0"
else
    fail "gh failure -> rc=$rc; $row"
fi
rm -rf "$t"

echo "== --tsv column count and ordering =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9110-cols
commit_dated "$t/repo" 0 newfile.md "content"
git -C "$t/repo" checkout -q main
git -C "$t/repo" worktree add -q "$t/wt-cols" feat/himmel-9110-cols
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1)"
row="$(tsv_row "$out" feat/himmel-9110-cols)"
ncols="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
cls="$(printf '%s' "$row" | awk -F'\t' '{print $1}')"
branch="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
wt="$(printf '%s' "$row" | awk -F'\t' '{print $7}')"
if [ "$ncols" -eq 7 ] && [ "$cls" = "UNLANDED-LIVE" ] && [ "$branch" = "feat/himmel-9110-cols" ] && [ -n "$wt" ]; then
    pass "--tsv: 7 columns, CLASS first, BRANCH second, worktree path populated"
else
    fail "--tsv columns -> ncols=$ncols cls=$cls branch=$branch wt=$wt"
fi
git -C "$t/repo" worktree remove --force "$t/wt-cols" >/dev/null 2>&1 || true
rm -rf "$t"

echo "== --class filters the TSV to one class =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9111-a
commit_dated "$t/repo" 0 a.md "a"
git -C "$t/repo" checkout -q main
git -C "$t/repo" checkout -q -b fix/himmel-9112-b
commit_dated "$t/repo" 0 b.md "b conflict"
git -C "$t/repo" checkout -q main
commit_dated "$t/repo" 0 b.md "unrelated"
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --class STALE --tsv 2>&1)"
if grepq "$out" -F 'fix/himmel-9112-b' && ! grepq "$out" -F 'feat/himmel-9111-a'; then
    pass "--class STALE -> only STALE rows"
else
    fail "--class STALE -> $out"
fi
rm -rf "$t"

echo "== human report: LANDED-ELSEWHERE drop commands present, STALE has none =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b glm/himmel-9113-landed
commit_dated "$t/repo" 0 same.md "content"
git -C "$t/repo" checkout -q main
# Distinct message (see commit_dated) — same file/content/hours_ago as the
# branch-side commit above would otherwise collapse to the same SHA.
commit_dated "$t/repo" 0 same.md "content" "landed on main: same.md"
git -C "$t/repo" checkout -q -b fix/himmel-9114-stale
commit_dated "$t/repo" 0 conflict2.md "branch"
git -C "$t/repo" checkout -q main
commit_dated "$t/repo" 0 conflict2.md "unrelated"
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main 2>&1)"
if grepq "$out" -F 'git branch -D glm/himmel-9113-landed' \
   && grepq "$out" -F 'No ready-to-run destructive command here on purpose'; then
    pass "human report: drop command for LANDED-ELSEWHERE, none for STALE"
else
    fail "human report -> $(printf '%s' "$out" | grep -A2 -E 'LANDED-ELSEWHERE|STALE')"
fi
rm -rf "$t"

# codex-5 (HIMMEL-2070 CR round 2): the printed drop command must be
# shell-safe-quoted (bash's own %q), not merely wrapped in "..." — a
# double-quoted ref name does NOT neutralize "$(...)"/backticks, and git ref
# names may legally contain either. Exercise a path with a literal space (the
# cheapest real case: a Windows username with a space) to prove %q actually
# escapes rather than passing through unquoted.
echo "== human report: worktree path is shell-safe-quoted (%q) in the drop command (codex-5) =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b glm/himmel-9116-quoted
commit_dated "$t/repo" 0 same2.md "content"
git -C "$t/repo" checkout -q main
# Distinct message (see commit_dated) — same file/content/hours_ago as the
# branch-side commit above would otherwise collapse to the same SHA.
commit_dated "$t/repo" 0 same2.md "content" "landed on main: same2.md"
mkdir -p "$t/with space"
git -C "$t/repo" worktree add -q "$t/with space/wt-quoted" glm/himmel-9116-quoted
# Derive the expected path from the script's OWN --tsv output, not from the
# raw $t shell variable: on Windows Git Bash, `git worktree list` normalizes
# a POSIX-form mktemp path (/tmp/tmp.XXXXX) to its Windows form
# (C:/Users/.../AppData/Local/Temp/tmp.XXXXX) -- comparing against $t
# directly would compare two different string representations of the same
# location and never match, regardless of whether %q is correct.
actual_wt="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1 | awk -F'\t' '$1=="LANDED-ELSEWHERE"{print $7; exit}')"
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main 2>&1)"
expected_q="$(printf '%q' "$actual_wt")"
if [ -n "$actual_wt" ] && grepq "$out" -F "git worktree remove $expected_q" && grepq "$out" -F '\ '; then
    pass "human report: worktree path with a space is shell-safe-quoted (%q) in the printed drop command"
else
    fail "human report worktree quoting -> actual_wt='$actual_wt'; $(printf '%s' "$out" | grep -A2 'LANDED-ELSEWHERE')"
fi
git -C "$t/repo" worktree remove --force "$t/with space/wt-quoted" >/dev/null 2>&1 || true
rm -rf "$t"

# ── HIMMEL-3405: pr<N> review refs classified by tip; readable SWEEP-ERROR;
# --health alarms (LOST-COMMITS / SWEEP-ERROR). ────────────────────────────

echo "== pr<N> review ref at or behind a MERGED PR's head -> LANDED-ELSEWHERE (matched by tip, not name) =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9200-prref
commit_dated "$t/repo" 0 conflict.md "branch v1" "feat: first"
mid9200="$(git -C "$t/repo" rev-parse HEAD)"
commit_dated "$t/repo" 0 conflict.md "branch v2" "feat: second"
head9200="$(git -C "$t/repo" rev-parse HEAD)"
git -C "$t/repo" branch pr77 "$head9200"          # review snapshot AT the merged head
git -C "$t/repo" branch pr78 "$mid9200"           # review snapshot BEHIND the merged head
git -C "$t/repo" checkout -q pr77
commit_dated "$t/repo" 0 conflict.md "branch v3" "feat: post-merge extra"
git -C "$t/repo" branch pr79 HEAD                 # review snapshot AHEAD of the merged head
git -C "$t/repo" checkout -q main
commit_dated "$t/repo" 0 conflict.md "unrelated main version" "main: unrelated"
git -C "$t/repo" branch -f pr77 "$head9200"
git -C "$t/repo" branch -D feat/himmel-9200-prref >/dev/null 2>&1
make_gh_stub "$t/stub" "feat/himmel-9200-prref:MERGED:77:$head9200"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --tsv 2>&1)"
r77="$(tsv_row "$out" pr77)"; r78="$(tsv_row "$out" pr78)"; r79="$(tsv_row "$out" pr79)"
if grepq "$r77" '^LANDED-ELSEWHERE' && grepq "$r77" -F 'merged PR #77'; then pass "pr ref AT the merged head -> LANDED-ELSEWHERE"; else fail "pr ref at merged head -> $r77"; fi
if grepq "$r78" '^LANDED-ELSEWHERE'; then pass "pr ref BEHIND the merged head -> LANDED-ELSEWHERE"; else fail "pr ref behind merged head -> $r78"; fi
if grepq "$r79" '^STALE'; then pass "control: pr ref AHEAD of the merged head stays STALE (unlanded commits are never called landed)"; else fail "pr ref ahead of merged head -> $r79"; fi
# A merged PR whose base is NOT the configured base proves nothing about landing on it.
make_gh_stub "$t/stub" "feat/himmel-9200-prref:MERGED:77:$head9200:develop"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --tsv 2>&1)"
r77="$(tsv_row "$out" pr77)"
if grepq "$r77" '^STALE'; then pass "control: merged PR into another base does not classify a pr ref LANDED"; else fail "pr ref, other-base PR -> $r77"; fi
rm -rf "$t"

echo "== no merge base with base -> readable cause, never a raw rc =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q --orphan fix/himmel-9210-unrelated
git -C "$t/repo" rm -rq -f . >/dev/null 2>&1
commit_dated "$t/repo" 0 other-root.md "unrelated history" "root: unrelated"
git -C "$t/repo" checkout -q main
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --tsv 2>&1)"
row="$(tsv_row "$out" fix/himmel-9210-unrelated)"
if grepq "$row" -F 'no merge base with main' && ! grepq "$row" -F 'rc='; then
    pass "no-merge-base branch -> evidence names the cause, no raw rc"
else
    fail "no-merge-base evidence -> $row"
fi
out="$(cd "$t/repo" && bash "$SCRIPT" --no-forge --base main --health 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -E '^SWEEP-ERROR fix/himmel-9210-unrelated no merge base with main' && ! grepq "$out" -F 'rc='; then
    pass "--health: no-merge-base -> SWEEP-ERROR line with the cause, rc1"
else
    fail "--health no-merge-base -> rc=$rc out=$out"
fi
rm -rf "$t"

echo "== --health: LOST-COMMITS when a MERGED PR's branch tip is AHEAD of the merged head =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9220-lost
commit_dated "$t/repo" 0 lost.md "shipped" "feat: shipped"
head9220="$(git -C "$t/repo" rev-parse HEAD)"
commit_dated "$t/repo" 0 lost2.md "post-merge commit that never landed" "feat: after merge"
git -C "$t/repo" checkout -q -b feat/himmel-9221-clean "$head9220"      # control: exactly at the merged head
git -C "$t/repo" checkout -q -b feat/himmel-9222-active "$head9220"     # control: ahead but an OPEN PR exists
commit_dated "$t/repo" 0 active.md "wip" "feat: wip"
git -C "$t/repo" checkout -q main
git -C "$t/repo" update-ref refs/remotes/origin/feat/himmel-9223-remote "$(git -C "$t/repo" rev-parse feat/himmel-9220-lost)"
make_gh_stub "$t/stub" \
    "feat/himmel-9220-lost:MERGED:220:$head9220" \
    "feat/himmel-9221-clean:MERGED:221:$head9220" \
    "feat/himmel-9222-active:MERGED:222:$head9220" "feat/himmel-9222-active:OPEN:223" \
    "feat/himmel-9223-remote:MERGED:224:$head9220"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --health 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -x 'LOST-COMMITS feat/himmel-9220-lost pr#220 ahead=1'; then pass "local merged branch ahead of its merged head -> LOST-COMMITS ... ahead=1, rc1"; else fail "LOST-COMMITS local -> rc=$rc out=$out"; fi
if grepq "$out" -x 'LOST-COMMITS origin/feat/himmel-9223-remote pr#224 ahead=1'; then pass "remote-tracking branch ahead of its merged head -> LOST-COMMITS origin/..."; else fail "LOST-COMMITS remote -> $out"; fi
if ! grepq "$out" -F 'himmel-9221-clean' && ! grepq "$out" -F 'himmel-9222-active'; then pass "controls: branch at the merged head and branch with an open PR raise no alarm"; else fail "controls raised an alarm -> $out"; fi
rm -rf "$t"

echo "== --health: healthy repo -> empty output, rc0 =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9230-fine
commit_dated "$t/repo" 0 fine.md "fine" "feat: fine"
head9230="$(git -C "$t/repo" rev-parse HEAD)"
git -C "$t/repo" checkout -q main
make_gh_stub "$t/stub" "feat/himmel-9230-fine:MERGED:230:$head9230"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --health 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "clean merged branch -> no alarm output, rc0"; else fail "healthy --health -> rc=$rc out=$out"; fi
rm -rf "$t"

echo "== --health: post-merge commits whose content is already on main are NOT lost =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9240-dup
commit_dated "$t/repo" 0 dup.md "shipped" "feat: shipped"
head9240="$(git -C "$t/repo" rev-parse HEAD)"
commit_dated "$t/repo" 0 dup2.md "landed via another PR" "feat: follow-up"
git -C "$t/repo" checkout -q main
commit_dated "$t/repo" 0 dup2.md "landed via another PR" "main: follow-up landed under another sha"
make_gh_stub "$t/stub" "feat/himmel-9240-dup:MERGED:240:$head9240"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --health 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "follow-up commit already on main under another sha -> no LOST-COMMITS"; else fail "dup follow-up -> rc=$rc out=$out"; fi
rm -rf "$t"

echo "== --health: merged head not fetched locally -> SWEEP-ERROR, never a silent pass =="
t="$(mktemp -d)"; make_repo "$t/repo"
git -C "$t/repo" checkout -q -b feat/himmel-9250-nohead
commit_dated "$t/repo" 0 nohead.md "unpushed tail" "feat: tail"
git -C "$t/repo" checkout -q main
make_gh_stub "$t/stub" "feat/himmel-9250-nohead:MERGED:250:1111111111111111111111111111111111111111"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --health 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -E '^SWEEP-ERROR feat/himmel-9250-nohead .*not present locally'; then pass "unfetched merged head -> SWEEP-ERROR with the cause"; else fail "unfetched head -> rc=$rc out=$out"; fi
rm -rf "$t"

echo "== --health: forge unavailable -> SWEEP-ERROR (forge), not a silent healthy =="
t="$(mktemp -d)"; make_repo "$t/repo"
mkdir -p "$t/stub"; printf '#!/bin/sh\nexit 1\n' > "$t/stub/gh"; chmod +x "$t/stub/gh"
out="$(cd "$t/repo" && GH_CMD="$t/stub/gh" bash "$SCRIPT" --base main --health 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -E '^SWEEP-ERROR \(forge\) '; then pass "forge outage -> SWEEP-ERROR (forge), rc1"; else fail "forge outage --health -> rc=$rc out=$out"; fi
rm -rf "$t"

echo "== --health cannot combine with --tsv/--class =="
bash "$SCRIPT" --health --tsv >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "--health --tsv -> rc2"; else fail "--health --tsv -> rc=$rc"; fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
