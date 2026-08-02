#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted `$…` is deliberate throughout: these
# printf lines EMIT shell source into the GH_CMD stub files, so the expansions
# must survive verbatim and be evaluated when the stub runs, not when it is written.
# test-orphan-branches.sh — self-contained tests for orphan_branch_scan.
#
# Usage: bash scripts/lib/test-orphan-branches.sh
# Exit:  0 = all pass, 1 = one or more failures.
#
# Strategy (mirrors test-branch-shipped.sh): build real temp git repos with
# refs/remotes/origin/<branch>, write GH_CMD stub scripts, export FORGE=github
# + GH_CMD=<stub>, source orphan-branches.sh, call orphan_branch_scan, assert
# on stdout.  The per-branch gh call shape the lib issues is:
#   gh pr list --head <branch> --state all --limit 100 \
#       --json number,state,mergeCommit --jq '.[]|[.number,.state,(.mergeCommit.oid//"-")]|@tsv'
# so a stub matches on $4 (the --head value).  The CI call (open PRs only) is:
#   gh pr checks <number>      (rc 0 => green, rc 1 => failed, rc 8 => pending)
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── temp dir setup ────────────────────────────────────────────────────────────
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# A fake "primary" git dir: forge_detect (FORGE=github) needs a real-ish repo.
PRIMARY_DIR="$TMPDIR_ROOT/primary"
mkdir -p "$PRIMARY_DIR/.git"

# now in epoch seconds (portable: no external `date -d`).
now=$(date +%s)

# ── test harness ──────────────────────────────────────────────────────────────
_pass=0
_fail=0
pass() { printf '  PASS  %s\n' "$1"; _pass=$(( _pass + 1 )); }
fail() { printf '  FAIL  %s\n' "$1"; _fail=$(( _fail + 1 )); }

# mk_repo <dir> — init a minimal git repo + one commit (on main) so refs work.
# Disables the operator's global core.hooksPath pre-commit + commit.gpgsign so
# each `git commit` is fast + hermetic (the global hook adds ~5-10s/commit on
# the dev box and has nothing to do with the unit under test).
mk_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    git -C "$d" config core.autocrlf false
    mkdir -p "$d/.nohooks"
    git -C "$d" config core.hooksPath "$d/.nohooks"
    git -C "$d" config commit.gpgsign false
    printf 'init\n' > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -q -m "init"
    git -C "$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
}

# mk_remote_branch <repo> <name> <days_ago> — empty commit dated N days ago,
# then point refs/remotes/origin/<name> at it.  git accepts a raw epoch + tz.
mk_remote_branch() {
    local repo="$1" name="$2" days="$3"
    local epoch=$(( now - days * 86400 ))
    GIT_AUTHOR_DATE="$epoch +0000" GIT_COMMITTER_DATE="$epoch +0000" \
        git -C "$repo" commit -q --allow-empty -m "c $name"
    git -C "$repo" update-ref "refs/remotes/origin/$name" HEAD
}

# point origin/main at HEAD (the first commit) so the default branch is present.
mk_origin_main() {
    git -C "$1" update-ref refs/remotes/origin/main HEAD
}

# write a GH_CMD stub.  args: stub_path <lines...>  (each line is `echo`-able sh).
write_stub() {
    local stub_path="$1"; shift
    { printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' "$@"; } > "$stub_path"
    chmod +x "$stub_path"
}

# A stub that returns PR rows only for --head <named> branches.  It also writes
# a sentinel if it is EVER called WITHOUT --head (a global/headless list call) —
# that sentinel is the 81-false-positive-regression proof.  $1=pr $2=list
# $3=--head $4=<branch> ...  so $4 is the head branch.
# $1 = sentinel-file path, $2 = an associative word<branch>->rows encoding:
#   "BRANCH1:NUM:STATE:OID BRANCH2:..." (space separated; rows tab-joined).
make_head_stub() {
    local stub_path="$1" sentinel="$2"; shift 2
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf 'sent=%q\n' "$sentinel"
        printf '%s\n' 'if [ "$3" != "--head" ]; then touch "$sent"; exit 0; fi'
        printf '%s\n' 'b="$4"'
        printf '%s\n' 'case "$b" in'
        local spec
        for spec in "$@"; do
            # spec = BRANCH:NUM:STATE:OID   (OID optional, default "-")
            local br num state oid rest   # `rest` was leaking to global scope (glm-5)
            br="${spec%%:*}"; rest="${spec#*:}"
            num="${rest%%:*}"; rest="${rest#*:}"
            state="${rest%%:*}"; oid="${rest#*:}"
            [ "$oid" = "$state" ] && oid="-"
            printf '  %q) printf "%%s\\t%%s\\t%%s\\n" %s %s %s ;;\n' "$br" "$num" "$state" "$oid"
        done
        printf '%s\n' 'esac'
    } > "$stub_path"
    chmod +x "$stub_path"
}

# Source the library under test.  RED before orphan-branches.sh exists.
OB_LIB="$SCRIPT_DIR/orphan-branches.sh"
# Distinguish MISSING from BROKEN (HIMMEL-1325): a single `. … 2>/dev/null` test
# returned non-zero for BOTH a missing file and one that exists but failed to
# source, so a genuine syntax error in the lib masqueraded as "not found" and hid
# the real cause. Check existence first; on a present-but-failing source, surface
# the actual error instead of swallowing it.
if [ ! -f "$OB_LIB" ]; then
    echo "SKIP: $OB_LIB not found — tests would all fail with a source error."
    echo "      Create scripts/lib/orphan-branches.sh, then re-run this test."
    exit 1
fi
# shellcheck source=scripts/lib/orphan-branches.sh
# shellcheck disable=SC1091
if ! . "$OB_LIB" 2>"$TMPDIR_ROOT/ob-src.err"; then
    echo "FAIL: $OB_LIB exists but failed to source (syntax error? bad dependency?)."
    sed 's/^/      /' "$TMPDIR_ROOT/ob-src.err" 2>/dev/null
    exit 1
fi

# count_orphans <scan_output>
count_orphans() { printf '%s\n' "$1" | grep -c '^ORPHAN ' || true; }
# has_orphan <scan_output> <branch>
has_orphan() { grepq "$1" -F "ORPHAN $2"; }
# (has_chain removed — it was never called and was broken anyway: it used $1 as
# BOTH the scan output and the state pattern, ignoring $2/$3, so it would have
# silently returned false for every caller. chain_state_of is the working
# equivalent and is what the assertions actually use. codex-3 / glm-4.)
# chain_state_of <scan_output> <branch> -> echoes the chain state for that branch
chain_state_of() { printf '%s\n' "$1" | awk -v b="$2" '$1=="chain:" && $3==b {print $2; exit}'; }

# ── T1: branch with NO PR -> ORPHAN -------------------------------------------
t="$TMPDIR_ROOT/t1"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/orphan" 1
stub="$TMPDIR_ROOT/gh-t1"
write_stub "$stub" 'exit 0'   # empty stdout for every --head call => 0 PRs
export FORGE=github GH_CMD="$stub" ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if has_orphan "$out" "feat/orphan"; then pass "T1: no-PR branch -> ORPHAN"; else fail "T1: expected ORPHAN feat/orphan; got: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:|orphan-branches:)' | head)"; fi
unset GH_CMD FORGE ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T2: branch with an OPEN PR -> NOT orphan (chain: pr) ----------------------
t="$TMPDIR_ROOT/t2"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/open" 1
stub="$TMPDIR_ROOT/gh-t2"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t2" "feat/open:42:OPEN:-"
# CI call for the open PR: `gh pr checks 42` -> rc 1 WITH a failing check row
# (a genuine red check — distinct from the no-checks rc=1 exercised in T20/T21,
# which must read as ci=none). This shared stub is reused by T3/T4/T10/T11/T13/T18
# as a generic "not green" CI; a failing row keeps all of those correct.
{ printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' 'echo -e "CI\t\tfail"'; printf '%s\n' 'exit 1'; } > "$TMPDIR_ROOT/ci-no"
chmod +x "$TMPDIR_ROOT/ci-no"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$TMPDIR_ROOT/ci-no" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if ! has_orphan "$out" "feat/open" && grepq "$out" '^chain: pr .*ci=failed'; then
    pass "T2: open-PR branch + failed CI -> chain: pr, ci=failed (not orphan)"
else
    fail "T2: expected chain: pr feat/open with ci=failed, no ORPHAN; got: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:)' )"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T3: branch with a MERGED PR -> NOT orphan (chain: merged) -----------------
t="$TMPDIR_ROOT/t3"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/merged" 2
stub="$TMPDIR_ROOT/gh-t3"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t3" "feat/merged:7:MERGED:abc123"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$TMPDIR_ROOT/ci-no" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50 ORPHAN_PUBLIC_CLONE=""
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if ! has_orphan "$out" "feat/merged" && grepq "$out" '^chain: merged '; then
    pass "T3: merged-PR branch -> chain: merged (not orphan)"
else
    fail "T3: expected chain: merged feat/merged; got: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:)')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX ORPHAN_PUBLIC_CLONE

# ── T4: THE 81-FALSE-POSITIVE REGRESSION TEST --------------------------------
# A branch that HAS a PR must NOT be reported orphan even when a GLOBAL list is
# truncated.  The lib must query per-branch (--head), never a headless list.
# Proof shape: the stub touches a sentinel on any headless (no --head) call; a
# correct lib never makes one, so the sentinel stays absent AND the has-PR
# branch is classified from its per-head truth.
t="$TMPDIR_ROOT/t4"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/has-pr" 1
mk_remote_branch "$t/rep" "feat/really-orphan" 1
sent="$TMPDIR_ROOT/sent-t4"; rm -f "$sent"
stub="$TMPDIR_ROOT/gh-t4"
make_head_stub "$stub" "$sent" "feat/has-pr:99:OPEN:-"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$TMPDIR_ROOT/ci-no" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if has_orphan "$out" "feat/really-orphan" && ! has_orphan "$out" "feat/has-pr" && [ ! -f "$sent" ]; then
    pass "T4: has-PR branch NOT orphan + no headless gh call (per-branch only)"
else
    fail "T4: per-branch isolation failed — orphan=$(printf '%s' "$out" | grep -c '^ORPHAN '), sentinel=$([ -f "$sent" ] && echo present || echo absent)"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T5: protected branch (main) is excluded -----------------------------------
t="$TMPDIR_ROOT/t5"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "main" 1      # a stray origin/main-like ref is ignored
mk_remote_branch "$t/rep" "feat/x" 1
stub="$TMPDIR_ROOT/gh-t5"
write_stub "$stub" 'exit 0'
export FORGE=github GH_CMD="$stub" ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if has_orphan "$out" "feat/x" && ! grepq "$out" -E '^(ORPHAN|chain:) main( |$)'; then
    pass "T5: 'main' excluded from scan"
else
    fail "T5: main leaked into scan: $(printf '%s\n' "$out" | grep -E 'main')"
fi
unset GH_CMD FORGE ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T6: ORPHAN_BRANCH_IGNORE glob excludes a branch --------------------------
t="$TMPDIR_ROOT/t6"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "renovate/deps" 1
mk_remote_branch "$t/rep" "feat/y" 1
stub="$TMPDIR_ROOT/gh-t6"
write_stub "$stub" 'exit 0'
export FORGE=github GH_CMD="$stub" ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50 \
    ORPHAN_BRANCH_IGNORE='renovate/*'
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if has_orphan "$out" "feat/y" && ! grepq "$out" 'renovate/deps'; then
    pass "T6: ORPHAN_BRANCH_IGNORE glob excludes renovate/*"
else
    fail "T6: ignore glob failed: $(printf '%s\n' "$out" | grep -E 'renovate|feat/y')"
fi
unset GH_CMD FORGE ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX ORPHAN_BRANCH_IGNORE

# ── T7: date window bounds old branches out (and the bound is STATED) --------
t="$TMPDIR_ROOT/t7"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/recent" 5
mk_remote_branch "$t/rep" "feat/old" 200
stub="$TMPDIR_ROOT/gh-t7"
write_stub "$stub" 'exit 0'
export FORGE=github GH_CMD="$stub" ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if has_orphan "$out" "feat/recent" && ! grepq "$out" 'feat/old' \
   && grepq "$out" 'window=30'; then
    pass "T7: window=30 bounds old branch out + bound stated"
else
    fail "T7: window bounding failed: $(printf '%s\n' "$out" | grep -E 'feat/old|feat/recent|window=')"
fi
unset GH_CMD FORGE ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T8: forge unreachable (gh exits non-zero) -> uncertain, no false orphan --
t="$TMPDIR_ROOT/t8"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/q" 1
stub="$TMPDIR_ROOT/gh-t8"
write_stub "$stub" 'exit 1'   # every gh call fails (unauthed/offline shape)
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$stub" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if ! has_orphan "$out" "feat/q" && grepq "$out" '^uncertain:'; then
    pass "T8: forge-error -> uncertain (no false orphan)"
else
    fail "T8: expected uncertain feat/q, no ORPHAN; got: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|uncertain:)')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T9: per-branch gh timeout -> uncertain, wall-clock bounded ---------------
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    t="$TMPDIR_ROOT/t9"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
    mk_remote_branch "$t/rep" "feat/slow" 1
    stub="$TMPDIR_ROOT/gh-t9"
    write_stub "$stub" 'sleep 30' 'exit 0'
    export FORGE=github GH_CMD="$stub" OB_CI_CMD="$stub" \
        ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50 ORPHAN_BRANCH_TIMEOUT=1
    _ts=$(date +%s)
    out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
    _te=$(date +%s); _el=$(( _te - _ts ))
    if ! has_orphan "$out" "feat/slow" && grepq "$out" '^uncertain:' && [ "$_el" -lt 10 ]; then
        pass "T9: slow gh -> uncertain, bounded (${_el}s < 10s)"
    else
        fail "T9: timeout handling failed (el=${_el}s): $(printf '%s\n' "$out" | grep -E '^(ORPHAN|uncertain:)')"
    fi
    unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX ORPHAN_BRANCH_TIMEOUT
else
    pass "T9: timeout case skipped (no timeout/gtimeout binary)"
fi

# ── T10: mixed repo — only the orphan is flagged; others get chain labels ----
t="$TMPDIR_ROOT/t10"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/orphan2" 1
mk_remote_branch "$t/rep" "feat/open2" 1
mk_remote_branch "$t/rep" "feat/merged2" 2
stub="$TMPDIR_ROOT/gh-t10"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t10" \
    "feat/open2:55:OPEN:-" "feat/merged2:66:MERGED:oid66"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$TMPDIR_ROOT/ci-no" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50 ORPHAN_PUBLIC_CLONE=""
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
_n=$(count_orphans "$out")
if [ "$_n" = "1" ] && has_orphan "$out" "feat/orphan2" \
   && grepq "$out" '^chain: pr .*feat/open2' \
   && grepq "$out" '^chain: merged .*feat/merged2'; then
    pass "T10: mixed repo — 1 orphan + correct chain labels"
else
    fail "T10: mixed classification wrong (orphans=$_n): $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:)')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX ORPHAN_PUBLIC_CLONE

# ── T11: propagated — merged PR whose mergeCommit is in the public clone -----
t="$TMPDIR_ROOT/t11"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/prop" 2
# A public clone whose history contains the mergeCommit oid.
pub="$t/pub"; mk_repo "$pub"
GIT_AUTHOR_DATE="$((now - 86400)) +0000" GIT_COMMITTER_DATE="$((now - 86400)) +0000" \
    git -C "$pub" commit -q --allow-empty -m "squash for feat/prop"
oid="$(git -C "$pub" rev-parse HEAD)"
stub="$TMPDIR_ROOT/gh-t11"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t11" "feat/prop:77:MERGED:$oid"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$TMPDIR_ROOT/ci-no" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50 ORPHAN_PUBLIC_CLONE="$pub"
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if grepq "$out" '^chain: propagated .*feat/prop'; then
    pass "T11: merged + mergeCommit in public clone -> propagated"
else
    fail "T11: expected propagated; got: $(printf '%s\n' "$out" | grep -E '^chain:')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX ORPHAN_PUBLIC_CLONE

# ── T12: ci-green — open PR whose `gh pr checks` exits 0 (all green) ---------
t="$TMPDIR_ROOT/t12"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/green" 1
stub="$TMPDIR_ROOT/gh-t12"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t12" "feat/green:88:OPEN:-"
ci_yes="$TMPDIR_ROOT/ci-yes"
{ printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' 'echo -e "CI\t\tpass"'; printf '%s\n' 'exit 0'; } > "$ci_yes"; chmod +x "$ci_yes"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$ci_yes" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if grepq "$out" '^chain: ci-green .*feat/green'; then
    pass "T12: open PR + green CI -> ci-green"
else
    fail "T12: expected ci-green; got: $(printf '%s\n' "$out" | grep -E '^chain:')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T13: closed-only PR -> abandoned, NOT orphan, NOT merged -----------------
t="$TMPDIR_ROOT/t13"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/closed" 1
stub="$TMPDIR_ROOT/gh-t13"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t13" "feat/closed:33:CLOSED:-"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$TMPDIR_ROOT/ci-no" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if ! has_orphan "$out" "feat/closed" && grepq "$out" '^chain: closed .*feat/closed'; then
    pass "T13: closed-only PR -> chain: closed (abandoned, not orphan)"
else
    fail "T13: expected chain: closed; got: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:)')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T14: STSTATIC — lib never issues a headless `gh pr list` -----------------
# A headless (no --head) `gh pr list --state all` is the truncation trap root
# cause.  Grep the lib source for the pattern and reject it.
_lib_src="$OB_LIB"
# Strip comment lines BEFORE the check: the lib's header deliberately quotes the
# anti-pattern (`gh pr list --state all --limit 1000`) to document the trap, and
# matching that prose is a false positive on the test's own documentation.
# Guard the no-candidate case: an empty substitution would reach grepq as a
# here-string holding ONE blank line, which `-v -- '--head'` matches — falsely
# failing T14 when the lib has no `pr list` lines at all (CR r1 codex-1).
_pr_lines="$(grep -vE '^[[:space:]]*#' "$_lib_src" | grep -E 'pr list')" || _pr_lines=""
if [ -n "$_pr_lines" ] && grepq "$_pr_lines" -v -- '--head'; then
    fail "T14 STATIC: lib issues a headless 'gh pr list' (truncation-trap root cause)"
else
    pass "T14 STATIC: every 'gh pr list' in the lib carries --head (no global membership test)"
fi

# ── T16: transient empty response must NOT become a false ORPHAN -------------
# Observed 2026-07-28: `gh pr list --head fix/himmel-1315-revert-duplicate-switch`
# returned rc=0 and EMPTY for a branch whose PR #1442 was MERGED; a re-query
# returned it.  An empty rc=0 is indistinguishable from a genuine no-PR result,
# so the scan must confirm with a second query before claiming ORPHAN.  This
# stub is empty on its FIRST --head call and returns the merged PR thereafter.
t="$TMPDIR_ROOT/t16"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "fix/flaky" 1
stub="$TMPDIR_ROOT/gh-t16"; ctr="$TMPDIR_ROOT/t16-calls"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'ctr=%q\n' "$ctr"
    printf '%s\n' 'if [ "$3" != "--head" ]; then exit 0; fi'
    printf '%s\n' 'n=0; [ -f "$ctr" ] && n=$(cat "$ctr")'
    printf '%s\n' 'n=$((n + 1)); printf "%s" "$n" > "$ctr"'
    printf '%s\n' 'if [ "$n" -le 1 ]; then exit 0; fi'   # first call: transient empty
    printf '%s\n' 'printf "%s\t%s\t%s\n" 1442 MERGED -'
} > "$stub"
chmod +x "$stub"
export FORGE=github GH_CMD="$stub" ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if ! has_orphan "$out" "fix/flaky" && [ "$(chain_state_of "$out" "fix/flaky")" = "merged" ]; then
    pass "T16: transient empty rc=0 re-queried -> chain: merged (no false ORPHAN)"
else
    fail "T16: transient empty became a false verdict; got: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:|uncertain:)')"
fi
unset GH_CMD FORGE ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T15: dual-mode — running the lib as a script prints a report + exits 1 on orphan
t="$TMPDIR_ROOT/t15"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/orphan3" 1
stub="$TMPDIR_ROOT/gh-t15"; write_stub "$stub" 'exit 0'
out="$(FORGE=github GH_CMD="$stub" ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50 \
    OB_PRIMARY="$t/rep" bash "$OB_LIB" 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && grepq "$out" '^ORPHAN feat/orphan3'; then
    pass "T15: dual-mode run -> report + non-zero exit on orphan"
else
    fail "T15: dual-mode failed (rc=$rc): $(printf '%s\n' "$out" | grep -E '^(ORPHAN|orphan-branches:)' | head -3)"
fi
unset GH_CMD FORGE ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T17: forge calls use the target repo, not the ambient cwd -----------------
t="$TMPDIR_ROOT/t17"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "fix/scoped" 1
mkdir -p "$t/elsewhere"
sent="$TMPDIR_ROOT/sent-t17"; rm -f "$sent"
stub="$TMPDIR_ROOT/gh-t17"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'expected=%q\n' "$t/rep"
    printf 'sent=%q\n' "$sent"
    printf '%s\n' 'if [ "$PWD" != "$expected" ]; then touch "$sent"; exit 1; fi'
    printf '%s\n' 'if [ "$1" = pr ] && [ "$2" = list ] && [ "$3" = --head ] && [ "$4" = fix/scoped ]; then'
    printf '%s\n' '    printf "%s\t%s\t%s\n" 117 OPEN -; exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [ "$1" = pr ] && [ "$2" = checks ] && [ "$3" = 117 ]; then'
    printf '%s\n' '    printf "CI\t\tpass\n"; exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'touch "$sent"; exit 1'
} > "$stub"
chmod +x "$stub"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$stub" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(cd "$t/elsewhere" && orphan_branch_scan "$t/rep" 2>/dev/null)"
if [ ! -f "$sent" ] && [ "$(chain_state_of "$out" "fix/scoped")" = "ci-green" ]; then
    pass "T17: PR + CI lookups run from target repo when ambient cwd differs"
else
    fail "T17: forge lookup used ambient cwd or wrong args: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:|uncertain:)')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T18: generated stub matches pattern metacharacters literally --------------
t="$TMPDIR_ROOT/t18"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "fix/a)b" 1
stub="$TMPDIR_ROOT/gh-t18"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t18" "fix/a)b:118:OPEN:-"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$TMPDIR_ROOT/ci-no" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if ! has_orphan "$out" "fix/a)b" && [ "$(chain_state_of "$out" "fix/a)b")" = "pr" ]; then
    pass "T18: generated stub matches metacharacter branch fix/a)b literally"
else
    fail "T18: metacharacter branch was misclassified: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:|uncertain:)')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T19: pending checks remain distinct from failed checks --------------------
t="$TMPDIR_ROOT/t19"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/pending" 1
stub="$TMPDIR_ROOT/gh-t19"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t19" "feat/pending:119:OPEN:-"
ci_pending="$TMPDIR_ROOT/ci-pending"
{ printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' 'exit 8'; } > "$ci_pending"; chmod +x "$ci_pending"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$ci_pending" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if grepq "$out" '^chain: pr .*feat/pending.*ci=pending'; then
    pass "T19: open PR + pending CI -> chain: pr, ci=pending"
else
    fail "T19: expected ci=pending; got: $(printf '%s\n' "$out" | grep -E '^chain:')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T20: rc=1 with NO checks output -> ci=none (HIMMEL-1325) -------------------
# `gh pr checks` exits 1 for BOTH a red check AND "no checks reported"
# (cli/cli#9390, #9682, #7401 — upstream has declined to change it). Actions is
# OFF on this private repo, so "no checks" is the COMMON private-PR state. The
# no-checks message goes to stderr (the lib captures stderr to /dev/null), so the
# realistic stub leaves stdout EMPTY on a rc=1: that must read `none`, not `failed`.
t="$TMPDIR_ROOT/t20"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/nochecks" 1
stub="$TMPDIR_ROOT/gh-t20"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t20" "feat/nochecks:201:OPEN:-"
ci_none="$TMPDIR_ROOT/ci-none"
{ printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' 'exit 1'; } > "$ci_none"; chmod +x "$ci_none"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$ci_none" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if ! has_orphan "$out" "feat/nochecks" && grepq "$out" '^chain: pr .*feat/nochecks.*ci=none'; then
    pass "T20: rc=1 + empty output (no checks) -> ci=none (not failed)"
else
    fail "T20: expected ci=none for no-checks rc=1; got: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:|uncertain:)')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T21: rc=1 with gh's "no checks" message ON STDOUT -> ci=none (HIMMEL-1325) -
# Defensive: some gh builds print "no checks reported" to STDOUT (not stderr),
# so $out is non-empty on a no-checks rc=1. The discriminator must still read it
# as `none` by matching the message, never treat the non-empty rc=1 as `failed`.
t="$TMPDIR_ROOT/t21"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/nomsg" 1
stub="$TMPDIR_ROOT/gh-t21"
make_head_stub "$stub" "$TMPDIR_ROOT/sent-t21" "feat/nomsg:202:OPEN:-"
ci_nomsg="$TMPDIR_ROOT/ci-nomsg"
{ printf '%s\n' '#!/usr/bin/env bash'; printf '%s\n' 'echo "no checks reported"'; printf '%s\n' 'exit 1'; } > "$ci_nomsg"; chmod +x "$ci_nomsg"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$ci_nomsg" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
if ! has_orphan "$out" "feat/nomsg" && grepq "$out" '^chain: pr .*feat/nomsg.*ci=none'; then
    pass "T21: rc=1 + 'no checks reported' on stdout -> ci=none (matched by message)"
else
    fail "T21: expected ci=none for no-checks message; got: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:|uncertain:)')"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T22: leading-zero ORPHAN_BRANCH_DAYS must not parse as octal (HIMMEL-1325) -
# $(( )) parses a leading-zero value as OCTAL, so "08" is an error ("value too
# great for base") and the scan ABORTS (verified pre-fix: line 266 error, exit 1,
# empty stdout). Base-10 normalization (10#$days) must let a config like 08 scan.
t="$TMPDIR_ROOT/t22"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/oct" 1
stub="$TMPDIR_ROOT/gh-t22"
write_stub "$stub" 'exit 0'
export FORGE=github GH_CMD="$stub" ORPHAN_BRANCH_DAYS=08 ORPHAN_BRANCH_MAX=50
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
# window=8d (not 08d) + the orphan surfaced => days was read base-10, not octal.
if has_orphan "$out" "feat/oct" && grepq "$out" 'window=8d'; then
    pass "T22: ORPHAN_BRANCH_DAYS=08 parsed base-10 (window=8d, orphan found)"
else
    fail "T22: leading-zero days misparsed as octal: $(printf '%s\n' "$out" | grep -E '^(ORPHAN|chain:|orphan-branches:)' | head)"
fi
unset GH_CMD FORGE ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX

# ── T23: no `timeout` binary -> scan still bounds gh via _ob_bounded (HIMMEL-1325)
# Stock macOS / minimal containers have no GNU timeout, so _ob_timeout_cmd returns
# empty and the scan must fall back to the portable _ob_bounded runner rather than
# run gh UNBOUNDED. Override the detector to SIMULATE that host (no pgrep needed —
# the stub records its own PID via $$ and we kill -0 it), point gh at a stub that
# hangs (exec sleep 30 so $! IS the sleep, killable with no orphan), and assert:
# bounded (< the stub's 30s) + uncertain (timeout => rc!=0 => uncertain) + no
# false ORPHAN + the hung child is reaped (not lingering).
t="$TMPDIR_ROOT/t23"; mk_repo "$t/rep"; mk_origin_main "$t/rep"
mk_remote_branch "$t/rep" "feat/slow2" 1
stub="$TMPDIR_ROOT/gh-t23"
# exec sleep 30 => the stub process becomes sleep, so $! is sleep's PID and the
# SIGTERM hits it directly (mirrors real gh, a single binary with no child tree).
write_stub "$stub" "echo \$\$ > '$TMPDIR_ROOT/t23-pid'" 'exec sleep 30'
_orig_tcmd="$(declare -f _ob_timeout_cmd)"    # save real detector, restore after
_ob_timeout_cmd() { :; }                       # simulate "no timeout/gtimeout"
export FORGE=github GH_CMD="$stub" OB_CI_CMD="$stub" \
    ORPHAN_BRANCH_DAYS=30 ORPHAN_BRANCH_MAX=50 ORPHAN_BRANCH_TIMEOUT=1
_ts=$(date +%s)
out="$(orphan_branch_scan "$t/rep" 2>/dev/null)"
_te=$(date +%s); _el=$(( _te - _ts ))
_spid="$(cat "$TMPDIR_ROOT/t23-pid" 2>/dev/null)"
_left=0; kill -0 "$_spid" 2>/dev/null && _left=1
eval "$_orig_tcmd"                             # restore the real _ob_timeout_cmd
if ! has_orphan "$out" "feat/slow2" && grepq "$out" '^uncertain:' \
   && [ "$_el" -lt 10 ] && [ "$_left" = 0 ]; then
    pass "T23: no-timeout-binary fallback bounded (${_el}s<10s) -> uncertain, child reaped"
else
    fail "T23: portable fallback failed (el=${_el}s, leftover=$_left): $(printf '%s\n' "$out" | grep -E '^(ORPHAN|uncertain:)' | head)"
fi
unset GH_CMD FORGE OB_CI_CMD ORPHAN_BRANCH_DAYS ORPHAN_BRANCH_MAX ORPHAN_BRANCH_TIMEOUT

# ── T24: _ob_bounded normal path -> real rc + stdout captured + NO noise --------
# The fast (non-timeout) path must return the child's real exit status, capture
# its stdout, and emit no job-control `[n] PID`/Done chatter. We capture the
# FUNCTION's stderr (where any such noise would surface) and assert it is empty.
_btmp="$TMPDIR_ROOT/ob-bnd.out"; _berr="$TMPDIR_ROOT/ob-bnd.err"
_ob_bounded 3 "$_btmp" "$TMPDIR_ROOT" sh -c 'printf "ok\n"; exit 0' 2>"$_berr"
_rc=$?
if [ "$_rc" = 0 ] && [ "$(cat "$_btmp")" = ok ] && [ ! -s "$_berr" ]; then
    pass "T24: _ob_bounded fast path -> rc=0, stdout captured, no job-control noise"
else
    fail "T24: fast path wrong (rc=$_rc, out=$(cat "$_btmp" 2>/dev/null), err=$(cat "$_berr" 2>/dev/null))"
fi

# ── T25: shared ci-no stub is chmod +x'd (HIMMEL-1325) -------------------------
# The ci-no stub (shared as OB_CI_CMD by T2/T3/T4/T10/T11/T13/T18) was the SOLE
# stub written without `chmod +x` (every other stub at lines 78/107/328/459/481/501
# has it). On Linux/macOS a non-executable OB_CI_CMD returns 126 (not 1), so
# _ob_ci_state takes the rc!=0 -> pending branch instead of the rc==1 branch and
# those 7 tests silently stop testing what they claim. Git Bash/MSYS EXECUTES
# non-executable scripts AND reports `test -x` true AND `stat` mode 755 for them,
# so the behavioral tests + a [ -x ] guard all pass here regardless — exactly why
# this bug shipped unnoticed on Windows. This guard reads the test's OWN source
# for the chmod line: a text check no MSYS permissiveness can mask, so it fails
# the moment the chmod is dropped, on EVERY OS (it FAILED pre-fix).
if grep -qE 'chmod[[:space:]]+\+x.*ci-no' "$0"; then
    pass "T25: shared ci-no stub is chmod +x'd (no 126 on Linux/macOS)"
else
    fail "T25: ci-no stub missing chmod +x — returns 126 (not 1) on Linux/macOS"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
