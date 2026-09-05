#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-cr-marker-on-pr-create.sh (HIMMEL-213).
#
# HIMMEL-213: the hook used to resolve the branch from CLAUDE_PROJECT_DIR
# (the main checkout, on `main`), but `gh pr create` actually runs in a
# worktree on a feature branch. It looked up cr-pending/main (empty) and
# never fired. The fix parses `--head <branch>` from the extracted
# `gh pr create` command and checks cr-pending/<that-branch> instead — and,
# because project_dir HEAD is main's HEAD (wrong for the head branch),
# BLOCKS on mere marker presence when resolved from --head.
#
# Covers (acceptance):
#   1. gh pr create --head feat/X (marker present for feat/X) -> BLOCK (exit 2),
#      with CLAUDE_PROJECT_DIR on main.
#   2. --head=feat/X form, marker present -> BLOCK (exit 2).
#   2b. -H feat/X short form, marker present -> BLOCK (exit 2).
#   2c. --head owner:feat/X fork form (owner stripped), marker present -> BLOCK.
#   3. --head feat/X, NO marker -> allow (exit 0).
#   4. No --head, marker present on current (project_dir) branch + SHA match
#      -> BLOCK (exit 2) — fall-back path not regressed.
#   5. Non-`gh pr create` command -> allow (exit 0).
#
# HIMMEL-1372 (matcher portability) additionally covers:
#   6. `gh  pr   create` (extra whitespace) still matches -> BLOCK.
#   7. the matcher regex uses POSIX EREs only — no `\s`/`\b` (GNU-only, inert
#      on BSD grep, which would silently un-gate the whole hook on macOS).
#   8. the negative cases stay negative: a string literal, a comment, `ghx`,
#      and `gh pr created` must NOT match.
#   9. an argument-less invocation whose token-end char is a metacharacter
#      (`gh pr create;`, `$(gh pr create)`, `>`, `&&`) still matches -> BLOCK.
#
# HIMMEL-1975 (ordinary command positions) additionally covers:
#  10. `{ … ; }`, `if`, `!`, a leading reserved word, and the wrapper commands
#      (`sudo`/`env`/`timeout`/`xargs`) all still reach the gate -> BLOCK.
#  11. the widening did NOT become "match anywhere": a grep search and a commit
#      message that merely QUOTE `gh pr create` stay negative -> allow.
#  12. the PreToolUse and PostToolUse matcher lines are byte-identical
#      (HIMMEL-1362 lockstep — they have already diverged once).
#
# HIMMEL-2035 (the gate follows the TOOL CALL's repo, not CLAUDE_PROJECT_DIR)
# additionally covers:
#  13. payload cwd = a foreign repo with a marker -> BLOCK (that repo's marker,
#      which CLAUDE_PROJECT_DIR could never see);
#      payload cwd = a foreign repo WITHOUT a marker while the himmel checkout
#      holds one for the SAME branch name -> allow (no cross-repo false block);
#      no cwd / a non-work-tree cwd -> unchanged CLAUDE_PROJECT_DIR fall-back;
#      `.tool_input.cwd` wins over `.cwd`;
#      a non-work-tree `.tool_input.cwd` does not shadow a valid `.cwd`, on the
#      jq path AND on the jq-less fallback;
#      cwd = a himmel WORKTREE with a marker, CLAUDE_PROJECT_DIR = the primary
#      on `main`, no --head -> BLOCK. That last one is a deliberate TIGHTENING
#      of a previously-missed block (spec §2.4) — pinned here so it is visible
#      in the suite rather than discovered in a live session.
#  14. `--repo <nwo>` divergence emits an ADVISORY but does NOT skip the gate:
#      `--repo` names the PR's TARGET repo, which for the fork/upstream flow is
#      deliberately not the local one, while the marker always belongs to the
#      repo the branch lives in. Exiting 0 there would un-gate every upstream
#      contribution — the very scenario this ticket exists for (CR codex-1).
#      The marker, not `--repo`, decides the exit code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-cr-marker-on-pr-create.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317  # invoked via trap; body reachable through it
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

# Setup: tmp git repo on main, plus a linked worktree on feat/X.
TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
git -C "$REPO" branch -m main 2>/dev/null || true

# Feature branch + worktree (the place gh pr create really runs).
git -C "$REPO" branch feat/X
WORKTREE="$TMP_ROOT/wt-featX"
git -C "$REPO" worktree add -q "$WORKTREE" feat/X

# project_dir = main checkout (stays on main). This is what the hook sees as
# CLAUDE_PROJECT_DIR in the real session-in-main / work-in-worktree pattern.
PROJECT_DIR="$REPO"

# Marker lives under the SHARED .git (git-common-dir), regardless of worktree.
git_common=$(git -C "$REPO" rev-parse --git-common-dir)
case "$git_common" in
    /*|?:/*|?:\\*) ;;
    *)             git_common="$REPO/$git_common" ;;
esac
marker_for() { echo "${git_common}/cr-pending/$1"; }

write_marker() {
    local branch="$1"
    local m
    m=$(marker_for "$branch")
    mkdir -p "$(dirname "$m")"
    # Format mirrors check-cr-before-push.sh: "<iso-date> | <sha>"
    printf '%s | %s\n' "2026-05-31T00:00:00+00:00" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$m"
}

# Run the hook with a given command string as the PreToolUse payload, with
# CLAUDE_PROJECT_DIR pointed at the main checkout. Returns exit code via rc.
#
# $2/$3/$4 are optional (HIMMEL-2035): the payload's top-level `cwd`, its
# `tool_input.cwd`, and a CLAUDE_PROJECT_DIR override. Omitted -> the payload
# carries no cwd key at all, which is exactly the shape every pre-2035 case
# above sends, so those keep exercising the CLAUDE_PROJECT_DIR path.
run_hook() {
    local command_json="$1" sess_cwd="${2:-}" tool_cwd="${3:-}" proj="${4:-$PROJECT_DIR}"
    local ti payload
    ti="\"command\":\"$command_json\""
    if [ -n "$tool_cwd" ]; then ti="$ti,\"cwd\":\"$tool_cwd\""; fi
    payload="{\"tool_name\":\"Bash\",\"tool_input\":{$ti}"
    if [ -n "$sess_cwd" ]; then payload="$payload,\"cwd\":\"$sess_cwd\""; fi
    payload="$payload}"
    rc=0
    out=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" 2>&1) || rc=$?
}

# Test 1: --head feat/X, marker present -> BLOCK (exit 2) -------------
echo "TEST: gh pr create --head feat/X, marker present, project_dir on main -> BLOCK"
write_marker "feat/X"
run_hook "gh pr create --head feat/X --base main --title t --body b"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on --head feat/X with marker"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi
case "$out" in
    *"CR review pending for feat/X"*) pass "stderr names the head branch feat/X" ;;
    *) fail "expected 'CR review pending for feat/X' in stderr" "out: $out" ;;
esac

# Test 2: --head=feat/X form, marker present -> BLOCK ----------------
echo "TEST: --head=feat/X (equals form), marker present -> BLOCK"
run_hook "gh pr create --head=feat/X --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on --head=feat/X with marker"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi

# Test 2b: -H feat/X (short form), marker present -> BLOCK ----------
echo "TEST: -H feat/X (short form), marker present -> BLOCK"
run_hook "gh pr create -H feat/X --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on -H feat/X with marker"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi

# Test 2c: --head owner:feat/X (fork form), marker present -> BLOCK --
# The owner: segment must be stripped so the marker for the bare branch
# name is found.
echo "TEST: --head owner:feat/X (fork form), marker present -> BLOCK"
run_hook "gh pr create --head somefork:feat/X --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on --head owner:feat/X (owner stripped)"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi
case "$out" in
    *"CR review pending for feat/X"*) pass "stderr names bare branch feat/X (owner stripped)" ;;
    *) fail "expected 'CR review pending for feat/X' in stderr" "out: $out" ;;
esac

# Test 3: --head feat/X, NO marker -> allow (exit 0) ----------------
echo "TEST: --head feat/X, no marker -> allow"
rm -f "$(marker_for feat/X)"
run_hook "gh pr create --head feat/X --base main"
if [ "$rc" -eq 0 ]; then
    pass "allowed (exit 0) when no marker for head branch"
else
    fail "expected exit 0, got rc=$rc" "out: $out"
fi

# Test 4: no --head, marker present on project_dir branch + SHA match -> BLOCK
# (fall-back path: branch resolved from project_dir, SHA-match refinement kept)
echo "TEST: no --head, marker on current branch (SHA match) -> BLOCK (fall-back not regressed)"
# Make project_dir live ON feat/X so branch --show-current = feat/X and HEAD
# matches the marker SHA we write.
git -C "$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true
git -C "$REPO" checkout -q feat/X
head_sha=$(git -C "$REPO" rev-parse HEAD)
m=$(marker_for "feat/X")
mkdir -p "$(dirname "$m")"
printf '%s | %s\n' "2026-05-31T00:00:00+00:00" "$head_sha" > "$m"
run_hook "gh pr create --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) via project_dir fall-back with SHA match"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi
rm -f "$m"

# Test 5: non-`gh pr create` command -> allow ------------------------
echo "TEST: unrelated command -> allow (exit 0)"
write_marker "feat/X"
run_hook "git status"
if [ "$rc" -eq 0 ]; then
    pass "allowed (exit 0) for non gh-pr-create command"
else
    fail "expected exit 0, got rc=$rc" "out: $out"
fi

# Test 6: extra whitespace between the words -> still BLOCK -----------
# The shell collapses nothing: `gh  pr   create` is a valid invocation and the
# gate must see it (the pure-bash fast path used to test for the literal
# `gh pr create` substring and exit before the anchored regex ever ran).
echo "TEST: gh  pr   create (extra whitespace), marker present -> BLOCK"
write_marker "feat/X"
run_hook "gh  pr   create --head feat/X --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on extra-whitespace 'gh  pr   create'"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi

# Test 7: matcher is POSIX ERE only — no \s / \b (BSD grep) ------------
# Asserted against the hook SOURCE, because a GNU-grep machine cannot observe
# the defect at runtime: on GNU grep `\s`/`\b` work fine, on BSD grep they
# match literal `s`/`b` and the whole gate silently never fires. "POSIX ERE
# only" IS the contract, so the source is the right place to pin it.
echo "TEST: matcher regex uses POSIX bracket classes only (no GNU-only escapes)"
matcher_line=$(grep -F "grep -qE" "$HOOK" | grep -F "create" || true)
if [ -z "$matcher_line" ]; then
    fail "could not locate the anchored 'grep -qE ... create' matcher in $HOOK"
elif [ "${matcher_line//\\/}" != "$matcher_line" ]; then
    # Bash pattern removal, not `grep '[\]'`: a bracket expression holding a
    # backslash is dialect-dependent, and a grep that errored on it would
    # return non-zero — indistinguishable, in an `elif`, from "no backslash
    # found", i.e. the test would pass while proving nothing (CR codex-2).
    fail "matcher contains a backslash escape (GNU-only, inert on BSD grep)" "line: $matcher_line"
else
    pass "matcher is backslash-free (POSIX bracket classes only)"
fi

# Test 8: negative cases stay negative -------------------------------
# Marker for feat/X is present and every command names --head feat/X, so a
# match would BLOCK (exit 2). Exit 0 therefore proves the matcher rejected it,
# not that the marker lookup happened to miss.
echo "TEST: non-command-position / near-miss spellings -> allow (exit 0)"
neg_labels="string-literal comment ghx-prefix pr-created"
set -- \
    'echo \"gh pr create --head feat/X\"' \
    '# TODO: gh pr create --head feat/X later' \
    'ghx pr create --head feat/X' \
    'gh pr created --head feat/X'
for label in $neg_labels; do
    run_hook "$1"
    if [ "$rc" -eq 0 ]; then
        pass "allowed (exit 0) for negative case: $label"
    else
        fail "negative case '$label' matched (rc=$rc)" "out: $out"
    fi
    shift
done

# Test 9: token-end characters other than whitespace -> BLOCK ---------
# An argument-less invocation ends `create` on a metacharacter, not a space.
# A whitespace-only end-of-token class let all of these through the gate
# (CR codex-1 on the first panel round of this branch).
echo "TEST: argument-less invocations ending on a metacharacter -> BLOCK"
# These have no --head, so the hook takes the project_dir fall-back, which
# needs the marker sha to equal HEAD (REPO is on feat/X since test 4).
fallback_sha=$(git -C "$REPO" rev-parse HEAD)
fallback_marker=$(marker_for "feat/X")
mkdir -p "$(dirname "$fallback_marker")"
printf '%s | %s\n' "2026-05-31T00:00:00+00:00" "$fallback_sha" > "$fallback_marker"
# shellcheck disable=SC2016  # literal $( in a command STRING, not an expansion
for meta_cmd in 'gh pr create;' 'gh pr create>out.txt' 'gh pr create&&echo done' '$(gh pr create)'; do
    run_hook "$meta_cmd"
    if [ "$rc" -eq 2 ]; then
        pass "blocked (exit 2) on '$meta_cmd'"
    else
        fail "'$meta_cmd' did not match the gate (rc=$rc)" "out: $out"
    fi
done

# Test 10: ordinary command positions the old class missed -> BLOCK ---
# HIMMEL-1975. The anchor used to cover only line-start and `; & | ` $( (`, so
# every shape below reached the gate and was waved through. Each names
# `--head feat/X`, whose marker is present, so BLOCK (exit 2) proves the
# MATCHER fired — allow (exit 0) means the shape slipped the gate entirely.
# `--base main` trails every one of them on purpose: the hook word-splits the
# command to find `--head`, so a shape ending `--head feat/X;` would hand it
# the branch `feat/X;`, and the case would pass for the wrong reason.
echo "TEST: brace/reserved-word/wrapper command positions -> BLOCK"
write_marker "feat/X"
# shellcheck disable=SC2016  # literal shell syntax in a command STRING
for pos_cmd in \
    '{ gh pr create --head feat/X --base main; }' \
    'if gh pr create --head feat/X --base main; then echo ok; fi' \
    '! gh pr create --head feat/X --base main' \
    'then gh pr create --head feat/X --base main' \
    'sudo gh pr create --head feat/X --base main' \
    'env FOO=1 gh pr create --head feat/X --base main' \
    'timeout 60 gh pr create --head feat/X --base main' \
    'xargs -I{} gh pr create --head feat/X --base main'
do
    run_hook "$pos_cmd"
    if [ "$rc" -eq 2 ]; then
        pass "blocked (exit 2) on '$pos_cmd'"
    else
        fail "'$pos_cmd' slipped the gate (rc=$rc)" "out: $out"
    fi
done

# Test 11: the widened anchor did NOT become "match anywhere" -> allow -
# The widening's whole risk is re-admitting false positives, and on a
# PreToolUse gate a false positive BLOCKS an unrelated Bash call — including
# the very commands used to maintain these hooks. No `--head` here, so a match
# would take the project_dir fall-back, whose marker (written by test 9) still
# has sha == HEAD: a match would exit 2. Exit 0 proves the matcher rejected it.
echo "TEST: quoted/searched occurrences stay negative after the widening"
neg2_labels="grep-search git-commit-message"
set -- \
    'grep -n \"gh pr create\" scripts/hooks/x.sh' \
    'git commit -m \"fix gh pr create matcher\"'
for label in $neg2_labels; do
    run_hook "$1"
    if [ "$rc" -eq 0 ]; then
        pass "allowed (exit 0) for negative case: $label"
    else
        fail "negative case '$label' matched (rc=$rc)" "out: $out"
    fi
    shift
done

# Test 12: the two twins carry the SAME matcher line (HIMMEL-1362 lockstep) --
# They have diverged once already (the end-of-token class landed in this hook
# on HIMMEL-1372 and not in the sibling), and a divergence means the PostToolUse
# trigger silently stops firing on shapes the PreToolUse gate blocks.
echo "TEST: PreToolUse and PostToolUse matchers are byte-identical"
twin="$SCRIPT_DIR/trigger-cr-on-pr-create.sh"
this_matcher=$(grep -F "grep -qE" "$HOOK" | grep -F "pr[[:space:]]+create" || true)
twin_matcher=$(grep -F "grep -qE" "$twin" | grep -F "pr[[:space:]]+create" || true)
if [ -z "$this_matcher" ] || [ -z "$twin_matcher" ]; then
    fail "could not locate the matcher line in one of the twins"
elif [ "$this_matcher" = "$twin_matcher" ]; then
    pass "both twins carry the identical matcher line"
else
    fail "the twins' matcher lines differ" "this: $this_matcher
    twin: $twin_matcher"
fi

# Test 13: the repo is the TOOL CALL's, not CLAUDE_PROJECT_DIR (HIMMEL-2035) --
echo "TEST: payload cwd selects the repo whose marker is checked"

# A repo that is emphatically NOT the himmel checkout.
mk_repo() { # <dir> <branch>
    local d="$1" b="$2"
    git init -q --initial-branch=main "$d" 2>/dev/null || {
        git init -q "$d"
        git -C "$d" symbolic-ref HEAD refs/heads/main || true
    }
    git -C "$d" config user.email t@test.com
    git -C "$d" config user.name test
    git -C "$d" commit -q --allow-empty -m init
    git -C "$d" checkout -q -b "$b"
}

# Marker in <repo>'s OWN .git (git-common-dir, so a worktree writes the
# primary's), keyed to that repo's HEAD so the SHA-match path blocks.
mark_head() { # <repo> <branch>
    local d="$1" b="$2" g m
    g=$(git -C "$d" rev-parse --git-common-dir)
    case "$g" in /*|?:/*|?:\\*) ;; *) g="$d/$g" ;; esac
    m="$g/cr-pending/$b"
    mkdir -p "$(dirname "$m")"
    printf '%s | %s\n' "2026-05-31T00:00:00+00:00" "$(git -C "$d" rev-parse HEAD)" > "$m"
}

FOREIGN="$TMP_ROOT/foreign"
mk_repo "$FOREIGN" "feat/foreign"
mark_head "$FOREIGN" "feat/foreign"
# himmel-side marker for feat/X (REPO is on feat/X since test 4) - the
# same-name branch that used to false-block a foreign create.
write_marker "feat/X"

# (a) cwd = foreign repo holding a marker -> BLOCK on ITS marker. Only the
# foreign .git has a marker for feat/foreign, so exit 2 proves the lookup
# happened there and not in CLAUDE_PROJECT_DIR.
run_hook "gh pr create --base main" "$FOREIGN"
if [ "$rc" -eq 2 ]; then
    pass "cwd=foreign repo with marker -> blocked (exit 2)"
else
    fail "expected exit 2 for foreign repo with marker, got rc=$rc" "out: $out"
fi
case "$out" in
    *"CR review pending for feat/foreign"*) pass "stderr names the FOREIGN repo branch" ;;
    *) fail "expected the foreign branch in stderr" "out: $out" ;;
esac

# (b) the other direction: cwd = foreign repo on a branch whose name collides
# with a himmel branch that DOES have a marker -> allow. This is the false
# block the pre-2035 hook produced.
git -C "$FOREIGN" checkout -q -b feat/X
run_hook "gh pr create --base main" "$FOREIGN"
if [ "$rc" -eq 0 ]; then
    pass "cwd=foreign repo, no marker there, same-name himmel marker -> allowed"
else
    fail "expected exit 0 (no cross-repo false block), got rc=$rc" "out: $out"
fi

# (c) no cwd key in the payload -> unchanged CLAUDE_PROJECT_DIR behaviour.
# REPO is on feat/X whose marker (write_marker) carries a placeholder sha, so
# the fall-back takes the stale-marker branch: exit 2.
run_hook "gh pr create --base main"
if [ "$rc" -eq 2 ]; then
    pass "no cwd in payload -> CLAUDE_PROJECT_DIR fall-back unchanged"
else
    fail "expected exit 2 via fall-back, got rc=$rc" "out: $out"
fi

# (d) cwd present but not a git work tree -> same fall-back.
mkdir -p "$TMP_ROOT/plain"
run_hook "gh pr create --base main" "$TMP_ROOT/plain"
if [ "$rc" -eq 2 ]; then
    pass "non-work-tree cwd -> CLAUDE_PROJECT_DIR fall-back"
else
    fail "expected exit 2 via fall-back for a non-work-tree cwd, got rc=$rc" "out: $out"
fi

# (e) precedence: .tool_input.cwd beats .cwd. Only FOREIGN2 has a marker for
# feat/tool, and FOREIGN (the .cwd value) has none for its current branch, so
# exit 2 naming feat/tool can only come from .tool_input.cwd winning.
FOREIGN2="$TMP_ROOT/foreign2"
mk_repo "$FOREIGN2" "feat/tool"
mark_head "$FOREIGN2" "feat/tool"
run_hook "gh pr create --base main" "$FOREIGN" "$FOREIGN2"
if [ "$rc" -eq 2 ]; then
    pass ".tool_input.cwd wins over .cwd (exit 2)"
else
    fail "expected exit 2 from .tool_input.cwd, got rc=$rc" "out: $out"
fi
case "$out" in
    *"CR review pending for feat/tool"*) pass "stderr names the .tool_input.cwd repo's branch" ;;
    *) fail "expected feat/tool in stderr" "out: $out" ;;
esac

# (f) spec 2.4 named exception - a DELIBERATE tightening for himmel's own
# branches. cwd = a worktree on feat/y with a marker, CLAUDE_PROJECT_DIR = the
# primary on main, no --head. Pre-2035 this looked up cr-pending/main, found
# nothing and waved the create through (the accepted missed block of
# HIMMEL-213). Now the marker is real, so the block is true.
PRIMARY2="$TMP_ROOT/primary2"
mk_repo "$PRIMARY2" "feat/y"
git -C "$PRIMARY2" checkout -q main
WT2="$TMP_ROOT/wt-featy"
git -C "$PRIMARY2" worktree add -q "$WT2" feat/y
mark_head "$WT2" "feat/y"
run_hook "gh pr create --base main" "$WT2" "" "$PRIMARY2"
if [ "$rc" -eq 2 ]; then
    pass "cwd=himmel worktree with marker, no --head -> blocked (2.4 tightening)"
else
    fail "expected exit 2 for the worktree cwd, got rc=$rc" "out: $out"
fi
# control: the same payload with cwd = the primary (on main, no marker) still
# allows - so the block above is cwd-driven, not fixture leakage.
run_hook "gh pr create --base main" "$PRIMARY2" "" "$PRIMARY2"
if [ "$rc" -eq 0 ]; then
    pass "cwd=primary on main (no marker) -> allowed"
else
    fail "expected exit 0 for the primary cwd, got rc=$rc" "out: $out"
fi

# (g) CR codex-3: a .tool_input.cwd that is NOT a work tree must not shadow a
# valid .cwd — the candidates are validated independently, in order. FOREIGN2
# (marker for feat/tool) is the .cwd; a plain dir is the .tool_input.cwd.
run_hook "gh pr create --base main" "$FOREIGN2" "$TMP_ROOT/plain"
if [ "$rc" -eq 2 ]; then
    pass "non-work-tree .tool_input.cwd falls through to a valid .cwd"
else
    fail "expected exit 2 via the .cwd candidate, got rc=$rc" "out: $out"
fi

# (h) CR round 2: on a jq-less box the fallback must offer EVERY payload `cwd`
# as a candidate. Built by dropping jq's OWN directory from PATH (skipped when
# it shares one with git — removing it would break the hook itself, and the case
# would then pass for the wrong reason). The invalid value is FIRST in the raw
# JSON, so a fallback that kept only the first match would fall through to
# CLAUDE_PROJECT_DIR and allow.
jq_bin=$(command -v jq 2>/dev/null || true)
git_bin=$(command -v git 2>/dev/null || true)
if [ -z "$jq_bin" ]; then
    echo "  SKIP: no jq on this box — the fallback IS the only path here"
elif [ "$(dirname "$jq_bin")" = "$(dirname "$git_bin")" ]; then
    echo "  SKIP: jq shares a directory with git — cannot build a jq-less PATH"
else
    nojq_path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -x -F "$(dirname "$jq_bin")" | tr '\n' ':' | sed 's/:$//')
    if PATH="$nojq_path" command -v jq >/dev/null 2>&1; then
        echo "  SKIP: jq still resolvable after pruning its directory from PATH"
    else
        jqless_payload="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr create --base main\",\"cwd\":\"$TMP_ROOT/plain\"},\"cwd\":\"$FOREIGN2\"}"
        rc=0
        out=$(printf '%s' "$jqless_payload" | PATH="$nojq_path" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HOOK" 2>&1) || rc=$?
        if [ "$rc" -eq 2 ]; then
            pass "jq-less fallback offers every payload cwd as a candidate"
        else
            fail "jq-less fallback lost the valid .cwd (rc=$rc)" "out: $out"
        fi
        # ...and it must honour the PRECEDENCE, not the raw JSON key order (CR
        # round 3). Here the top-level `cwd` is serialized FIRST and points at a
        # repo with no marker; `.tool_input.cwd` comes later and points at one
        # with a marker. Exit 2 can only mean .tool_input.cwd won on merit.
        jqless_order="{\"cwd\":\"$FOREIGN\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr create --base main\",\"cwd\":\"$FOREIGN2\"}}"
        rc=0
        out=$(printf '%s' "$jqless_order" | PATH="$nojq_path" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HOOK" 2>&1) || rc=$?
        if [ "$rc" -eq 2 ]; then
            pass "jq-less fallback keeps .tool_input.cwd ahead of a earlier-serialized .cwd"
        else
            fail "jq-less fallback took raw key order over precedence (rc=$rc)" "out: $out"
        fi
    fi
fi

# Test 14: FR1a - `--repo <nwo>` divergence advises but never skips the gate ---
# The exit code must track the MARKER, never the nwo comparison: FOREIGN2 (on
# feat/tool, marker present) must block whether or not `--repo` matches, and
# FOREIGN3 (on feat/none, no marker) must allow the same way. Only the advisory
# on stderr distinguishes the diverging pairs. A `--repo`-driven exit 0 would
# un-gate every fork/upstream `gh pr create`, which is this ticket's own
# motivating scenario (CR codex-1).
echo "TEST: --repo nwo divergence -> advisory only; the marker still decides"

FOREIGN3="$TMP_ROOT/foreign3"
mk_repo "$FOREIGN3" "feat/none"

fr1a() { # <label> <repo-dir> <origin-url|-> <command> <expected-rc> <advisory:yes|no>
    local label="$1" dir="$2" origin="$3" command="$4" want="$5" want_adv="$6"
    git -C "$dir" remote remove origin 2>/dev/null || true
    if [ "$origin" != "-" ]; then git -C "$dir" remote add origin "$origin"; fi
    run_hook "$command" "$dir"
    if [ "$rc" -ne "$want" ]; then
        fail "FR1a $label: expected exit $want, got rc=$rc" "out: $out"
        return
    fi
    case "$out" in
        *"advisory: --repo"*) local saw=yes ;;
        *)                    local saw=no ;;
    esac
    if [ "$saw" = "$want_adv" ]; then
        pass "FR1a $label: exit $want, advisory=$saw"
    else
        fail "FR1a $label: expected advisory=$want_adv, saw=$saw" "out: $out"
    fi
}

# marker present (FOREIGN2, feat/tool) -> ALWAYS exit 2, advisory only on divergence
fr1a "https + .git"     "$FOREIGN2" "https://github.com/owner/name.git" "gh pr create --repo owner/name --base main"  2 no
fr1a "ssh + case-fold"  "$FOREIGN2" "git@github.com:owner/name"         "gh pr create --repo Owner/Name --base main"  2 no
fr1a "equals form"      "$FOREIGN2" "https://github.com/owner/name"     "gh pr create --repo=owner/name --base main"  2 no
fr1a "fork/upstream"    "$FOREIGN2" "https://github.com/owner/name"     "gh pr create --repo other/thing --base main" 2 yes
fr1a "fork/upstream -R" "$FOREIGN2" "https://github.com/owner/name"     "gh pr create -R other/thing --base main"     2 yes
fr1a "no origin remote" "$FOREIGN2" "-"                                 "gh pr create --repo owner/name --base main"  2 yes
fr1a "no --repo at all" "$FOREIGN2" "https://github.com/owner/name"     "gh pr create --base main"                    2 no
# no marker (FOREIGN3, feat/none) -> exit 0 either way; the advisory never blocks
fr1a "diverge, no marker" "$FOREIGN3" "https://github.com/owner/name" "gh pr create --repo other/thing --base main" 0 yes
fr1a "match, no marker"   "$FOREIGN3" "https://github.com/owner/name" "gh pr create --repo owner/name --base main"  0 no

# Summary ------------------------------------------------------------
echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
