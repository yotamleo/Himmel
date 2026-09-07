#!/usr/bin/env bash
# Integration test for the commit-msg gate THROUGH the real pre-commit
# commit-msg shim (HIMMEL-2461, HIMMEL-2462).
#
# The cases in test-check-commit-msg.sh invoke check-commit-msg.sh directly with
# a message file, which BYPASSES the pre-commit framework entirely. They were
# GREEN for the whole life of the gate while the gate enforced nothing on a real
# `git commit`: .pre-commit-config.yaml wired the hook with `pass_filenames:
# false`, so pre-commit never handed it the message path, `$1` was empty, `cat
# ""` failed, and the script exited 0 under a "Passed" line. Three must-fail
# arms — including `zzzz totally invalid message`, which is not even a
# conventional commit — all committed rc=0 on the HIMMEL-2457 Linux matrix.
#
# This test therefore drives `git commit` through a REAL
# `pre-commit install --hook-type commit-msg`, using the conventional-commit-msg
# entry EXTRACTED FROM THE REPO'S OWN .pre-commit-config.yaml — so re-adding
# `pass_filenames: false` to that file turns this suite red rather than
# silently restoring the vacuous gate.
#
# It also pins the coupling with HIMMEL-2462. Two separate `.env` sources cover
# two separate claims: `example` copies the repo's CURRENTLY SHIPPED
# .env.example verbatim, proving that file works end to end through the real
# hook today; `legacy-example` writes the PRE-FIX .env.example line as a
# literal in this test file (comment on the same line, wide gutter and all),
# so the coupling case cannot be disarmed by a later edit to .env.example
# itself (codex-1: the comment moved off that file's JIRA_PROJECT_KEY line,
# which had silently made the `example` arm stop exercising comment-stripping
# at all). Before load-dotenv.sh stripped a trailing comment, fixing the
# wiring alone made every machine installed from that shape un-committable.
#
# Skips cleanly (exit 0) where pre-commit is not installed, matching
# test-check-cr-before-push-precommit.sh. That exit 0 looks exactly like a
# pass to any caller reading only rc — read the `== Summary ==` block instead.
# `pre-commit` can also be present but off the NON-LOGIN PATH (measured on
# ubuntu_new: lives at /home/osboxes/.local/bin/pre-commit, rc=127 under a
# bare ssh exec, fine under `bash -lc`) — the same shape as HIMMEL-2458. Drive
# this suite through a LOGIN shell on a remote guest or you bank a non-result.
#
# Platform guard (gitbash-only): test fixture for the commit-msg gate; runs
# wherever the gate runs (Git Bash / POSIX bash), no .ps1 twin (project
# convention).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
HOOK="$SCRIPT_DIR/check-commit-msg.sh"
LOADER="$REPO_ROOT/scripts/lib/load-dotenv.sh"
CONFIG="$REPO_ROOT/.pre-commit-config.yaml"
ENV_EXAMPLE="$REPO_ROOT/.env.example"

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
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

command -v pre-commit >/dev/null 2>&1 || { echo "SKIP: pre-commit not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
for required in "$HOOK" "$LOADER" "$CONFIG" "$ENV_EXAMPLE"; do
    [ -f "$required" ] || { echo "FAIL: missing fixture input $required" >&2; exit 1; }
done

tmp_raw=$(mktemp -d "${TMPDIR:-/tmp}/cr-commit-msg.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$tmp_raw"); else TMP_ROOT="$tmp_raw"; fi

# Neutralise the developer's global/system git config for every git process this
# suite spawns — pre-commit included. himmel's own machines set a global
# `core.hooksPath`, and `pre-commit install` refuses outright when one is in
# effect ("Cowardly refusing to install hooks with `core.hooksPath` set"), so
# without this the suite could never reach the behaviour it is testing. Empty
# files, not /dev/null: git must be able to stat them.
: > "$TMP_ROOT/gitconfig-empty"
export GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig-empty"
export GIT_CONFIG_SYSTEM="$TMP_ROOT/gitconfig-empty"

# The production entry, verbatim. Extract from `- id: conventional-commit-msg`
# up to (not including) the next sibling `- id:` at the same indentation, so the
# fixture's wiring IS the repo's wiring rather than a hand-copied restatement.
extract_entry() {
    awk '
        /^      - id: conventional-commit-msg$/ { grab = 1; print; next }
        grab && /^      - id: / { exit }
        grab { print }
    ' "$CONFIG"
}

ENTRY=$(extract_entry)
if [ -z "$ENTRY" ]; then
    echo "FAIL: could not extract the conventional-commit-msg entry from $CONFIG" >&2
    exit 1
fi

# build_repo <env-source> — fixture repo with the hook, the loader, the extracted
# entry, and an installed commit-msg shim. <env-source> is `example` (a copy of
# the repo's CURRENTLY SHIPPED .env.example, the adopter shape), `legacy-example`
# (a pinned literal of the PRE-FIX .env.example JIRA_PROJECT_KEY line — carries
# an inline comment no matter what .env.example ships today; this is what
# exercises HIMMEL-2462's comment-stripping), or `plain` (a minimal .env).
# Sets global REPO.
build_repo() {
    local env_source="$1"
    REPO="$TMP_ROOT/repo"
    rm -rf "$REPO"
    mkdir -p "$REPO/scripts/hooks" "$REPO/scripts/lib"
    git init -q -b main "$REPO"
    git -C "$REPO" config user.email t@t
    git -C "$REPO" config user.name t
    git -C "$REPO" config commit.gpgsign false
    cp "$HOOK" "$REPO/scripts/hooks/check-commit-msg.sh"
    cp "$LOADER" "$REPO/scripts/lib/load-dotenv.sh"
    {
        printf 'repos:\n'
        printf '  - repo: local\n'
        printf '    hooks:\n'
        printf '%s\n' "$ENTRY"
    } > "$REPO/.pre-commit-config.yaml"
    case "$env_source" in
        example)        cp "$ENV_EXAMPLE" "$REPO/.env" ;;
        # The exact historical .env.example:64 content (HIMMEL-2462) — pinned
        # here as a literal so this arm keeps exercising comment-stripping
        # regardless of what .env.example ships today. Wide gutter is deliberate.
        legacy-example) printf 'JIRA_PROJECT_KEY=HIMMEL                            # default project for jira ops\n' > "$REPO/.env" ;;
        plain)          printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$REPO/.env" ;;
        *) echo "FAIL: unknown env source $env_source" >&2; exit 1 ;;
    esac
    ( cd "$REPO" && pre-commit install --hook-type commit-msg ) >/dev/null 2>&1 \
        || { echo "FAIL: pre-commit install failed in the fixture" >&2; exit 1; }
    [ -f "$REPO/.git/hooks/commit-msg" ] \
        || { echo "FAIL: pre-commit did not write .git/hooks/commit-msg" >&2; exit 1; }
}

# try_commit <message> — stage a fresh change and commit it. Echoes the combined
# output; returns git's exit status. HEAD movement is asserted separately, so a
# hook that rejects but leaves the commit standing cannot read as a pass.
try_commit() {
    local message="$1"
    printf '%s\n' "$RANDOM-$(date +%s)" >> "$REPO/payload.txt"
    git -C "$REPO" add payload.txt
    ( cd "$REPO" && git commit -m "$message" 2>&1 )
}

head_sha() { git -C "$REPO" rev-parse --verify -q HEAD 2>/dev/null || echo "<none>"; }

# expect_rejected <label> <message> [needle]
expect_rejected() {
    local label="$1" message="$2" needle="${3:-}"
    local before after out rc=0
    before=$(head_sha)
    out=$(try_commit "$message") || rc=$?
    after=$(head_sha)
    git -C "$REPO" reset -q HEAD -- payload.txt 2>/dev/null || true
    git -C "$REPO" checkout -q -- payload.txt 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
        fail "$label — git commit returned 0 (the gate did not fire)"
        return
    fi
    if [ "$before" != "$after" ]; then
        fail "$label — HEAD moved despite a non-zero rc"
        return
    fi
    if [ -n "$needle" ]; then
        case "$out" in
            *"$needle"*) : ;;
            *) fail "$label — rejected, but the output never mentioned '$needle'"; return ;;
        esac
    fi
    pass "$label"
}

# expect_committed <label> <message>
expect_committed() {
    local label="$1" message="$2"
    local before after out rc=0
    before=$(head_sha)
    out=$(try_commit "$message") || rc=$?
    after=$(head_sha)
    if [ "$rc" -ne 0 ]; then
        fail "$label — git commit returned $rc: $(printf '%s' "$out" | tail -6 | tr '\n' ' ')"
        return
    fi
    if [ "$before" = "$after" ]; then
        fail "$label — rc=0 but HEAD did not move"
        return
    fi
    pass "$label"
}

echo "== real pre-commit commit-msg path, the CURRENTLY SHIPPED .env.example =="
build_repo example
# Seed a first commit so HEAD exists; the gate applies to it too, so it must be
# a message the post-fix gate accepts. This proves .env.example as it ships
# TODAY works end to end through the real hook — whatever it does or doesn't
# carry as an inline comment is not this arm's concern (see legacy-example below).
expect_committed "seed commit passes the installed gate" "chore: [HIMMEL-2461] seed"

# The decisive negative control from the HIMMEL-2457 matrix: not even a
# conventional commit. This committed rc=0 before the wiring fix.
expect_rejected "a non-conventional message is REJECTED through the real hook" \
    "zzzz totally invalid message" "COMMIT REJECTED"
expect_rejected "a conventional message with no ticket is REJECTED through the real hook" \
    "chore: no ticket id here" "COMMIT REJECTED"

echo "== real pre-commit commit-msg path, legacy comment-bearing .env (2461+2462 coupling) =="
# codex-1: this arm is PINNED to the pre-fix .env.example content (see
# legacy-example in build_repo) rather than to whatever .env.example ships
# today, precisely so a future edit to .env.example cannot silently disarm it
# the way moving the inline comment off JIRA_PROJECT_KEY did here.
build_repo legacy-example
expect_committed "seed commit passes with a comment-bearing .env" "chore: [HIMMEL-2461] seed"
# HIMMEL-2462 coupling: this .env carries JIRA_PROJECT_KEY with a trailing
# inline comment. With the loader fix reverted the pattern in force becomes
# `HIMMEL   # default project for jira ops-[0-9]+` and this REJECTS with that
# garbage pattern printed verbatim — which is why 2461 and 2462 ship together.
expect_committed "a correct message COMMITS with a comment-bearing .env (2461+2462 coupling)" \
    "chore: [HIMMEL-2461] coupled"

echo "== real pre-commit commit-msg path, minimal .env =="
build_repo plain
expect_committed "seed commit passes with a comment-free .env" "chore: [HIMMEL-2461] seed"
expect_rejected "a non-conventional message is REJECTED with a comment-free .env" \
    "zzzz totally invalid message" "COMMIT REJECTED"

echo "== fail-closed when the hook is handed no message =="
# The wiring defect's signature: an empty "$1". Silence + rc=0 here is exactly
# what let the gate certify every commit for months, so it must be loud and
# non-zero. Run outside any git worktree so the COMMIT_EDITMSG fallback is
# genuinely absent.
NOGIT="$TMP_ROOT/nogit"
mkdir -p "$NOGIT"
no_msg_rc=0
no_msg_out=$( cd "$NOGIT" && bash "$HOOK" "" 2>&1 ) || no_msg_rc=$?
no_msg_hit=0
case "$no_msg_out" in *"COMMIT REJECTED"*) no_msg_hit=1 ;; esac
if [ "$no_msg_rc" -ne 0 ] && [ "$no_msg_hit" -eq 1 ]; then
    pass "empty \$1 with no COMMIT_EDITMSG fallback fails closed and names the wiring"
else
    fail "empty \$1 fails open (rc=$no_msg_rc) — the HIMMEL-2461 signature"
fi

missing_rc=0
missing_out=$( cd "$NOGIT" && bash "$HOOK" "$TMP_ROOT/no-such-message-file" 2>&1 ) || missing_rc=$?
missing_hit=0
case "$missing_out" in *"COMMIT REJECTED"*) missing_hit=1 ;; esac
if [ "$missing_rc" -ne 0 ] && [ "$missing_hit" -eq 1 ]; then
    pass "a \$1 naming a missing file fails closed"
else
    fail "a \$1 naming a missing file fails open (rc=$missing_rc)"
fi

# codex-1 (CR round 2): `-r` is true for a readable DIRECTORY, so a `$1` that
# resolves to one used to sail past the old guard into `cat`, which fails to
# stderr and leaves COMMIT_MSG empty — the empty-message path then exits 0,
# recreating the vacuous gate. The guard must require a REGULAR FILE.
DIR_AS_MSG="$TMP_ROOT/a-directory-not-a-file"
mkdir -p "$DIR_AS_MSG"
dir_rc=0
dir_out=$( cd "$NOGIT" && bash "$HOOK" "$DIR_AS_MSG" 2>&1 ) || dir_rc=$?
dir_hit=0
case "$dir_out" in *"COMMIT REJECTED"*) dir_hit=1 ;; esac
if [ "$dir_rc" -ne 0 ] && [ "$dir_hit" -eq 1 ]; then
    pass "a \$1 naming a directory fails closed"
else
    fail "a \$1 naming a directory fails open (rc=$dir_rc)"
fi

echo "== the COMMIT_EDITMSG fallback RECOVERS an ordinary commit, not just fails closed =="
# The two sections above only prove the guard FIRES on malformed input — a
# guard with only must-fail arms is exactly the shape that bricks a machine.
# This proves the fallback path also RECOVERS a real `git commit`: install a
# raw commit-msg shim that calls the hook with NO argument at all (mimicking
# any wiring, not just pre-commit, that drops $1), so the hook can only reach
# a verdict via `git rev-parse --git-path COMMIT_EDITMSG`. The negative arm
# (an invalid message still rejects through the same shim) is what makes the
# positive arm mean something — a hook that always exits 0 would pass alone.
NOARG_REPO="$TMP_ROOT/noarg-repo"
rm -rf "$NOARG_REPO"
git init -q -b main "$NOARG_REPO"
git -C "$NOARG_REPO" config user.email t@t
git -C "$NOARG_REPO" config user.name t
git -C "$NOARG_REPO" config commit.gpgsign false
printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$NOARG_REPO/.env"
# A template-free `git init` (this suite pins init.templateDir to an empty
# directory via scripts/lib/git-test-env.sh, and run-shell-tests.sh pins the
# same for every suite it spawns) creates NO .git/hooks/ directory at all —
# only the template's own hooks/ subdir would seed one. Without this mkdir the
# printf below silently fails ("No such file or directory"), the shim is never
# installed, and the negative arm two lines down then passes VACUOUSLY (git
# commit succeeds because no hook exists to reject it) — exactly the failure
# this suite exists to catch, just relocated into its own fixture.
mkdir -p "$NOARG_REPO/.git/hooks"
{
    printf '#!/usr/bin/env bash\n'
    printf 'exec bash "%s"\n' "$HOOK"
} > "$NOARG_REPO/.git/hooks/commit-msg"
chmod +x "$NOARG_REPO/.git/hooks/commit-msg"
[ -x "$NOARG_REPO/.git/hooks/commit-msg" ] \
    || { echo "FAIL: no-argument shim not installed at $NOARG_REPO/.git/hooks/commit-msg" >&2; FAIL=$((FAIL+1)); }
REPO="$NOARG_REPO"
expect_committed "no-argument shim: COMMIT_EDITMSG fallback recovers a real commit" \
    "chore: [HIMMEL-2461] fallback"
expect_rejected "no-argument shim: an invalid message still REJECTS through the fallback" \
    "zzzz totally invalid message" "COMMIT REJECTED"

echo "== a real merge commit still commits through the installed pre-commit shim =="
# The merge exemption lives behind the message read (MERGE_HEAD check), so
# this proves the fail-closed guard does not fire ahead of it and brick an
# ordinary `git merge`.
build_repo plain
expect_committed "seed commit for merge fixture" "chore: [HIMMEL-2461] seed"
git -C "$REPO" checkout -q -b feature
printf 'feature\n' >> "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -q -m "chore: [HIMMEL-2461] feature change"
git -C "$REPO" checkout -q main
printf 'main\n' >> "$REPO/mainline.txt"
git -C "$REPO" add mainline.txt
git -C "$REPO" commit -q -m "chore: [HIMMEL-2461] main change"
before=$(head_sha)
merge_out=$( cd "$REPO" && git merge --no-edit feature 2>&1 )
merge_rc=$?
after=$(head_sha)
if [ "$merge_rc" -eq 0 ] && [ "$before" != "$after" ]; then
    pass "a real merge commit lands through the installed shim"
else
    fail "a real merge commit did not land (rc=$merge_rc): $(printf '%s' "$merge_out" | tail -6 | tr '\n' ' ')"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
