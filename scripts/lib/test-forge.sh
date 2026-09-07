#!/usr/bin/env bash
# Tests for the forge-dispatch seam (HIMMEL-326): forge_detect across every
# remote-URL shape + verb routing to each backend via the GH_CMD / BITBUCKET_CMD
# stub seams. No network. Mirrors the repo's bash test convention.
#
# The forge_* verbs are intentionally called bare (no positional args) here.
# shellcheck disable=SC2119
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/forge.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$SCRIPT_DIR/forge.sh"

PASS=0
FAIL=0
TMP_ROOT=""
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# HIMMEL-1924: a successful github create/edit now posts an `@coderabbitai
# review` trigger. Disarm it for the routing cases below so they stay hermetic
# and machine-independent — this checkout IS armed (`git config --local
# himmel.coderabbit true`), so without this the trigger would fire during the
# legacy assertions. The trigger cases at the end arm it explicitly (CR_APP=1).
export CR_APP=0
# HIMMEL-2034: the trigger seam now posts only on a repo whose CR gate is ours.
# The trigger stub's PR URLs are on acme/widget (not this checkout's origin),
# so allowlist it — the foreign-repo refusal itself is covered by the two hook
# suites.
export CR_TRIGGER_REPOS="acme/widget"
# Redirect the shared ledger to a throwaway file: no test may read or write the
# real repo's .git/cr-triggered-heads.
export CR_TRIGGER_LEDGER_PATH="$TMP_ROOT/cr-triggered-heads"

# ── forge_detect: FORGE override ─────────────────────────────────────────────
echo "TEST: forge_detect honors FORGE override"
assert_eq "FORGE=github"    "github"    "$(FORGE=github forge_detect)"
assert_eq "FORGE=bitbucket" "bitbucket" "$(FORGE=bitbucket forge_detect)"
rc=0; FORGE=gitlab forge_detect >/dev/null 2>&1 || rc=$?
assert_eq "FORGE=bogus → rc 2" "2" "$rc"

# ── forge_detect: origin URL shapes ──────────────────────────────────────────
echo "TEST: forge_detect parses origin URL shapes"
REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin "https://github.com/owner/repo.git"

detect_for() {  # $1 = origin url; echoes detect result (or empty on failure)
    git -C "$REPO" remote set-url origin "$1"
    ( cd "$REPO" && forge_detect 2>/dev/null )
}
assert_eq "github https .git"  "github"    "$(detect_for 'https://github.com/owner/repo.git')"
assert_eq "github https"       "github"    "$(detect_for 'https://github.com/owner/repo')"
assert_eq "github ssh"         "github"    "$(detect_for 'git@github.com:owner/repo.git')"
assert_eq "bitbucket https"    "bitbucket" "$(detect_for 'https://bitbucket.org/ws/repo.git')"
assert_eq "bitbucket https usr" "bitbucket" "$(detect_for 'https://user@bitbucket.org/ws/repo.git')"
assert_eq "bitbucket ssh"      "bitbucket" "$(detect_for 'git@bitbucket.org:ws/repo.git')"
assert_eq "uppercase host"     "github"    "$(detect_for 'https://GitHub.com/owner/repo')"

echo "TEST: forge_detect fails loud on unknown / missing origin"
git -C "$REPO" remote set-url origin "https://gitlab.com/owner/repo.git"
rc=0; ( cd "$REPO" && forge_detect ) >/dev/null 2>&1 || rc=$?
assert_eq "unknown host → rc 3" "3" "$rc"
NOREMOTE="$TMP_ROOT/noremote"; git init -q "$NOREMOTE"
rc=0; ( cd "$NOREMOTE" && forge_detect ) >/dev/null 2>&1 || rc=$?
assert_eq "no origin → rc 3" "3" "$rc"

# ── verb routing: github backend (GH_CMD stub) ───────────────────────────────
echo "TEST: github verbs route through GH_CMD"
GH_STUB="$TMP_ROOT/gh-stub.sh"
cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    "auth status"*)        exit 0 ;;
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"api user"*)          echo "ghlogin" ;;
    *"pr list"*merged*)    echo "2" ;;
    *"pr list"*)           echo "7" ;;
    *"pr create"*)         echo "https://github.com/owner/repo/pull/9" ;;
    *"pr merge"*)          exit 0 ;;
    *"issue create"*)      echo "https://github.com/owner/repo/issues/5" ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB"

assert_eq "gh auth_status rc0"  "0" "$(FORGE=github GH_CMD="$GH_STUB" forge_auth_status; echo $?)"
assert_eq "gh repo_nwo"         "owner/repo" "$(FORGE=github GH_CMD="$GH_STUB" forge_repo_nwo)"
assert_eq "gh default_branch"   "main" "$(FORGE=github GH_CMD="$GH_STUB" forge_default_branch)"
assert_eq "gh user_slug"        "ghlogin" "$(FORGE=github GH_CMD="$GH_STUB" forge_user_slug)"
assert_eq "gh pr_find_open"     "7" "$(FORGE=github GH_CMD="$GH_STUB" forge_pr_find_open feat/x)"
assert_eq "gh pr_create url"    "https://github.com/owner/repo/pull/9" "$(FORGE=github GH_CMD="$GH_STUB" forge_pr_create T B main feat/x)"
assert_eq "gh pr_has_merged"    "2" "$(FORGE=github GH_CMD="$GH_STUB" forge_pr_has_merged feat/x)"
assert_eq "gh issue_create url" "https://github.com/owner/repo/issues/5" "$(FORGE=github GH_CMD="$GH_STUB" forge_issue_create owner/repo "A nit" "Fix it." cr-deferred)"

# ── github pr_mergeable: LOCAL git merge-tree, not GitHub's async field ───────
# HIMMEL-1232: gh_forge_pr_mergeable reads only base+head refs from gh (a
# synchronous field read, stubbed here) and computes the conflict locally with
# `git merge-tree`. So this exercises a REAL merge against real commits, not a
# mocked mergeable string.
echo "TEST: github pr_mergeable computes conflicts locally (git merge-tree, HIMMEL-1232)"
MREPO="$TMP_ROOT/mergerepo"
git init -q -b main "$MREPO" 2>/dev/null || { git init -q "$MREPO"; git -C "$MREPO" checkout -q -b main; }
git -C "$MREPO" config user.email t@t.t
git -C "$MREPO" config user.name test
printf 'a\nb\nc\n' > "$MREPO/f"; git -C "$MREPO" add f; git -C "$MREPO" commit -qm base
# Clean branch: adds an unrelated file — no overlap with main.
git -C "$MREPO" checkout -q -b feat/clean
echo x > "$MREPO/g"; git -C "$MREPO" add g; git -C "$MREPO" commit -qm clean
# Conflict branch off base changes line 2; main then changes the same line.
git -C "$MREPO" checkout -q -b feat/conflict main
printf 'a\nTHEIRS\nc\n' > "$MREPO/f"; git -C "$MREPO" add f; git -C "$MREPO" commit -qm theirs
git -C "$MREPO" checkout -q main
printf 'a\nOURS\nc\n' > "$MREPO/f"; git -C "$MREPO" add f; git -C "$MREPO" commit -qm ours
CLEAN_OID=$(git -C "$MREPO" rev-parse feat/clean)
CONFLICT_OID=$(git -C "$MREPO" rev-parse feat/conflict)

# Stub gh: answer only the base+head metadata read. MT_HEAD selects which commit
# is the PR head; MT_NOPR=1 simulates "no PR" (gh exits non-zero, empty stdout).
MT_STUB="$TMP_ROOT/gh-mergetree.sh"
cat >"$MT_STUB" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"pr view"*baseRefName*)
        [ "${MT_NOPR:-0}" = "1" ] && exit 1
        printf '%s %s\n' "${MT_BASE:-main}" "${MT_HEAD:?MT_HEAD unset}"
        ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$MT_STUB"

# merge-tree runs in cwd, so each call is made from inside MREPO.
assert_eq "gh pr_mergeable MERGEABLE (clean branch)" "MERGEABLE" \
    "$(cd "$MREPO" && FORGE=github GH_CMD="$MT_STUB" MT_HEAD="$CLEAN_OID" forge_pr_mergeable feat/clean)"
assert_eq "gh pr_mergeable CONFLICTING (real overlap)" "CONFLICTING" \
    "$(cd "$MREPO" && FORGE=github GH_CMD="$MT_STUB" MT_HEAD="$CONFLICT_OID" forge_pr_mergeable feat/conflict)"
# No PR -> empty (callers treat empty as "nothing to gate on").
assert_eq "gh pr_mergeable no-PR → empty" "" \
    "$(cd "$MREPO" && FORGE=github GH_CMD="$MT_STUB" MT_NOPR=1 forge_pr_mergeable feat/x)"
# Unresolvable head SHA -> UNKNOWN (fail open, never a false CONFLICTING).
assert_eq "gh pr_mergeable unresolvable head → UNKNOWN" "UNKNOWN" \
    "$(cd "$MREPO" && FORGE=github GH_CMD="$MT_STUB" MT_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef forge_pr_mergeable feat/x)"
# gh error (CLI missing) -> empty (fail open).
assert_eq "gh pr_mergeable gh-error → empty" "" \
    "$(cd "$MREPO" && FORGE=github GH_CMD=/no/such/gh forge_pr_mergeable feat/x)"

# ── verb routing: bitbucket backend (BITBUCKET_CMD stub) ─────────────────────
echo "TEST: bitbucket verbs route through BITBUCKET_CMD"
BB_STUB="$TMP_ROOT/bb-stub.sh"
cat >"$BB_STUB" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    "auth status"*)   exit 0 ;;
    "repo view"*)     echo '{"workspace":"ws","repo_slug":"repo","full_name":"ws/repo","default_branch":"main"}' ;;
    "user --slug"*)   echo "nick" ;;
    "pr list"*MERGED*) echo '[{"id":1},{"id":2}]' ;;
    "pr list"*OPEN*)  echo '[{"id":7}]' ;;
    "pr create"*)     echo '{"id":9,"url":"https://bitbucket.org/ws/repo/pull-requests/9","state":"OPEN"}' ;;
    "pr edit"*)       echo '{"id":7,"url":"https://bitbucket.org/ws/repo/pull-requests/7","state":"OPEN"}' ;;
    "pr merge"*)      exit 0 ;;
    "issue create"*)  echo '{"id":5,"title":"A nit","url":"https://bitbucket.org/ws/repo/issues/5"}' ;;
    *) echo "stub: unhandled bb args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$BB_STUB"

assert_eq "bb auth_status rc0"  "0" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_auth_status; echo $?)"
assert_eq "bb repo_nwo"         "ws/repo" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_repo_nwo)"
assert_eq "bb default_branch"   "main" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_default_branch)"
assert_eq "bb user_slug"        "nick" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_user_slug)"
assert_eq "bb pr_find_open"     "7" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_pr_find_open feat/x)"
assert_eq "bb pr_create url"    "https://bitbucket.org/ws/repo/pull-requests/9" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_pr_create T B main feat/x)"
assert_eq "bb pr_has_merged"    "2" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_pr_has_merged feat/x)"
assert_eq "bb pr_mergeable UNKNOWN (non-blocking, §5.1)" "UNKNOWN" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_pr_mergeable 7)"
assert_eq "bb pr_merge rc0"     "0" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_pr_merge 7 >/dev/null; echo $?)"

# A failing CLI must propagate (not be swallowed into empty/0 output).
echo "TEST: bitbucket backend propagates CLI failure (no silent empty)"
BB_FAIL="$TMP_ROOT/bb-fail.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$BB_FAIL"; chmod +x "$BB_FAIL"
assert_eq "bb default_branch CLI-fail → rc1" "1" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_FAIL" forge_default_branch >/dev/null 2>&1; echo $?)"
assert_eq "bb pr_find_open CLI-fail → rc1"   "1" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_FAIL" forge_pr_find_open feat/x >/dev/null 2>&1; echo $?)"

# A merge conflict (CLI exit 2, spec §5.1) must NOT report success.
echo "TEST: bitbucket pr_merge conflict (CLI exit 2) → failure"
BB_CONFLICT="$TMP_ROOT/bb-conflict.sh"
printf '#!/usr/bin/env bash\ncase "$* " in "pr merge"*) exit 2;; *) exit 0;; esac\n' >"$BB_CONFLICT"; chmod +x "$BB_CONFLICT"
rc=0; FORGE=bitbucket BITBUCKET_CMD="$BB_CONFLICT" forge_pr_merge 7 >/dev/null 2>&1 || rc=$?
assert_eq "bb pr_merge conflict → rc4" "4" "$rc"

# pr_create must map (TITLE BODY BASE HEAD) → CLI (--source HEAD --destination BASE).
echo "TEST: bitbucket pr_create arg mapping + pr_set_body best-effort"
BB_ARGS="$TMP_ROOT/bb-args.sh"
ARGS_LOG="$TMP_ROOT/bb-args.log"
cat >"$BB_ARGS" <<STUB
#!/usr/bin/env bash
echo "\$*" > "$ARGS_LOG"
echo '{"id":1,"url":"u"}'
STUB
chmod +x "$BB_ARGS"
FORGE=bitbucket BITBUCKET_CMD="$BB_ARGS" forge_pr_create "My Title" "Body" main feat/x >/dev/null
args=$(cat "$ARGS_LOG")
case "$args" in
    *"--source feat/x"*"--destination main"*) pass "pr_create maps --source HEAD --destination BASE" ;;
    *) fail "pr_create arg mapping" "got: $args" ;;
esac

# pr_set_body (NUMBER TITLE BODY) → CLI `pr edit NUMBER --title TITLE --body BODY`.
echo "TEST: bitbucket pr_set_body routes through the pr edit verb (title+body)"
assert_eq "bb pr_set_body rc0 on success" "0" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_pr_set_body 7 "My Title" "Body" >/dev/null 2>&1; echo $?)"
FORGE=bitbucket BITBUCKET_CMD="$BB_ARGS" forge_pr_set_body 7 "My Title" "Body" >/dev/null
args=$(cat "$ARGS_LOG")
case "$args" in
    "pr edit 7 --title My Title --body Body"*) pass "pr_set_body maps NUMBER --title --body" ;;
    *) fail "pr_set_body arg mapping" "got: $args" ;;
esac
# A failing CLI must propagate (best-effort handling lives in pr-open, not here).
assert_eq "bb pr_set_body CLI-fail → rc1" "1" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_FAIL" forge_pr_set_body 7 T B >/dev/null 2>&1; echo $?)"

# ── issue_create routing (HIMMEL-327, spec §5.2) ─────────────────────────────
echo "TEST: bitbucket issue_create — url on success, rc3 on issues-disabled"
assert_eq "bb issue_create url" "https://bitbucket.org/ws/repo/issues/5" "$(FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" forge_issue_create ws/repo "A nit" "Fix it." cr-deferred)"

# The CLI exits 3 when the issue tracker is disabled (verified §5.2 404). The
# seam must propagate rc 3 (NOT 1) so the deferred filer can degrade gracefully.
BB_NOISSUES="$TMP_ROOT/bb-noissues.sh"
printf '#!/usr/bin/env bash\ncase "$* " in "issue create"*) exit 3;; *) exit 0;; esac\n' >"$BB_NOISSUES"; chmod +x "$BB_NOISSUES"
rc=0; FORGE=bitbucket BITBUCKET_CMD="$BB_NOISSUES" forge_issue_create ws/repo T B cr-deferred >/dev/null 2>&1 || rc=$?
assert_eq "bb issue_create issues-disabled → rc3" "3" "$rc"
# A generic CLI failure (exit 1) must map to rc1, distinct from issues-disabled.
rc=0; FORGE=bitbucket BITBUCKET_CMD="$BB_FAIL" forge_issue_create ws/repo T B cr-deferred >/dev/null 2>&1 || rc=$?
assert_eq "bb issue_create generic-fail → rc1" "1" "$rc"

# issue_create must IGNORE REPO ($1) + LABEL ($4) and pass only --title --body
# (BB derives ws/repo from origin; BB issues have no free-form labels).
FORGE=bitbucket BITBUCKET_CMD="$BB_ARGS" forge_issue_create ws/repo "My Title" "Body" cr-deferred >/dev/null
args=$(cat "$ARGS_LOG")
case "$args" in
    "issue create --title My Title --body Body"*) pass "issue_create maps --title --body, drops REPO/LABEL" ;;
    *) fail "issue_create arg mapping" "got: $args" ;;
esac

# ── CodeRabbit trigger at the seam (HIMMEL-1924) ─────────────────────────────
# A PR opened/advanced from inside a script matches neither HIMMEL-1906 hook
# (they match the bash command string), so the seam itself must post the
# `@coderabbitai review` trigger — exactly once per head SHA, via the SAME
# ledger the hooks use, and never on an unarmed repo or on bitbucket.
echo "TEST: github seam triggers CodeRabbit once per head SHA (HIMMEL-1924)"
TRIG_LOG="$TMP_ROOT/trigger-comments.log"
: > "$TRIG_LOG"
export TRIG_LOG
TRIG_STUB="$TMP_ROOT/gh-trigger.sh"
cat >"$TRIG_STUB" <<'STUB'
#!/usr/bin/env bash
# `pr view` answers the seam's number/head/url lookup ($TRIG_HEAD selects the
# head); `pr comment` appends the posted body to $TRIG_LOG instead of posting.
case "${1:-} ${2:-}" in
    "pr create") echo "https://github.com/acme/widget/pull/42" ;;
    "pr view")   printf '%s %s %s\n' 42 "${TRIG_HEAD:?TRIG_HEAD unset}" "https://github.com/acme/widget/pull/42" ;;
    "pr comment")
        body=""
        while [ "$#" -gt 0 ]; do
            case "$1" in --body) body="${2:-}"; shift ;; esac
            shift
        done
        printf '%s\n' "$body" >> "${TRIG_LOG:?}"
        ;;
esac
exit 0
STUB
chmod +x "$TRIG_STUB"
trig_count() { wc -l < "$TRIG_LOG" 2>/dev/null | tr -d ' '; }

# 1. an armed repo: a seam-opened PR posts the trigger and records the head.
FORGE=github GH_CMD="$TRIG_STUB" CR_APP=1 TRIG_HEAD=sha-aaa forge_pr_create T B main feat/x >/dev/null 2>&1
assert_eq "seam-opened PR posts one trigger" "1" "$(trig_count)"
if grep -qx '@coderabbitai review' "$TRIG_LOG"; then
    pass "the posted body is '@coderabbitai review'"
else
    fail "trigger body" "got: $(cat "$TRIG_LOG")"
fi
if grep -qxF "acme/widget 42 sha-aaa" "$CR_TRIGGER_LEDGER_PATH"; then
    pass "the head is recorded in the shared ledger (repo PR sha)"
else
    fail "ledger record" "got: $(cat "$CR_TRIGGER_LEDGER_PATH" 2>/dev/null)"
fi

# 2. same head again -> ledger no-op (this is what makes the seam and the two
#    HIMMEL-1906 hooks double-post-safe: they share this ledger).
FORGE=github GH_CMD="$TRIG_STUB" CR_APP=1 TRIG_HEAD=sha-aaa forge_pr_create T B main feat/x >/dev/null 2>&1
assert_eq "a second call at the SAME head posts nothing" "1" "$(trig_count)"

# 3. a new head -> posts again (the fix-round case HIMMEL-1906 exists for).
FORGE=github GH_CMD="$TRIG_STUB" CR_APP=1 TRIG_HEAD=sha-bbb forge_pr_create T B main feat/x >/dev/null 2>&1
assert_eq "a NEW head posts again" "2" "$(trig_count)"

# 4. the advance arm: a body refresh on an existing PR at a new head (what
#    graph-publish.sh / pr-open.sh do after pushing) triggers too.
FORGE=github GH_CMD="$TRIG_STUB" CR_APP=1 TRIG_HEAD=sha-ccc forge_pr_set_body 42 T B >/dev/null 2>&1
assert_eq "pr_set_body at a new head triggers (script-advanced PR)" "3" "$(trig_count)"

# 5/6. disarmed repos post NOTHING — CR_PROFILE=none (the documented opt-out)
#      and an adopter clone with no CodeRabbit App (cr-available.sh default).
FORGE=github GH_CMD="$TRIG_STUB" CR_APP=1 CR_PROFILE=none TRIG_HEAD=sha-ddd forge_pr_create T B main feat/x >/dev/null 2>&1
assert_eq "CR_PROFILE=none posts nothing" "3" "$(trig_count)"
FORGE=github GH_CMD="$TRIG_STUB" CR_APP=0 TRIG_HEAD=sha-eee forge_pr_create T B main feat/x >/dev/null 2>&1
assert_eq "an unarmed repo posts nothing" "3" "$(trig_count)"

# 7. bitbucket is a structural no-op — CodeRabbit is GitHub-only, so the
#    bitbucket backend carries no trigger at all.
FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" CR_APP=1 forge_pr_create T B main feat/x >/dev/null 2>&1
assert_eq "bitbucket create posts no trigger" "3" "$(trig_count)"

# 8. the create's stdout stays exactly the PR URL — the trigger's diagnostics
#    go to stderr, so a caller parsing the URL is unaffected.
assert_eq "pr_create stdout is still just the URL" "https://github.com/acme/widget/pull/42" \
    "$(FORGE=github GH_CMD="$TRIG_STUB" CR_APP=1 TRIG_HEAD=sha-fff forge_pr_create T B main feat/x 2>/dev/null)"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
