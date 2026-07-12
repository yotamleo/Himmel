#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-security-reviewed.sh.
#
# Builds a throwaway git repo with a main branch, a feature branch, and
# controlled commit messages, then runs the hook from inside it.
#
# Usage: bash scripts/hooks/test-check-security-reviewed.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-security-reviewed.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

# Build a temp repo with: main has README, feature branch adds files +
# commits with $msg. Run hook from feature branch HEAD.
make_repo() {
    local files="$1" msg="$2"
    local dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b main
        git config user.email t@t
        git config user.name t
        echo r > README.md
        git add README.md
        git -c commit.gpgsign=false commit -q -m "init"
        git checkout -q -b feat/x
        # shellcheck disable=SC2086 # files is space-separated, intentional split
        for f in $files; do
            mkdir -p "$(dirname "$f")"
            echo "x" > "$f"
        done
        git add -A
        # shellcheck disable=SC2086 # files is space-separated
        git -c commit.gpgsign=false commit -q -m "$msg"
    )
    echo "$dir"
}

run_in() {
    local dir="$1" env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        ( cd "$dir" && env "$env_assign" bash "$HOOK" >/dev/null 2>&1 )
    else
        ( cd "$dir" && bash "$HOOK" >/dev/null 2>&1 )
    fi
    echo "$?"
}

# Stub `gh` on PATH for PR-body fallback tests. The stub script prints
# `$body` verbatim regardless of args, simulating
# `gh pr view <branch> --json body --jq '.body'` returning that text.
make_gh_stub() {
    local body="$1"
    local d
    d=$(mktemp -d)
    cat > "$d/gh" <<STUB_EOF
#!/usr/bin/env bash
printf '%s\n' "$body"
STUB_EOF
    chmod +x "$d/gh"
    echo "$d"
}

run_in_with_path() {
    local dir="$1" stub_dir="$2"
    ( cd "$dir" && PATH="$stub_dir:$PATH" bash "$HOOK" >/dev/null 2>&1 )
    echo "$?"
}

# --- BLOCK cases (rc=1) ---
d=$(make_repo "src/foo.ts" "feat: add foo")
assert_rc "code change + no attestation"             1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "scripts/foo.sh" "feat: add shell")
assert_rc "scripts/ change + no attestation"         1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "src/api/handler.py" "feat: add handler")
assert_rc "python code + no attestation"             1 "$(run_in "$d")"
rm -rf "$d"

# --- ALLOW cases (rc=0) ---
d=$(make_repo "README.md" "docs: readme")
assert_rc "docs-only (.md)"                          0 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "docs/setup.md notes.txt" "docs: notes")
assert_rc "docs/ + .txt only"                        0 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "handovers/foo.md" "docs: handover")
assert_rc "handovers/ only"                          0 "$(run_in "$d")"
rm -rf "$d"

# Recognised tokens
for token in manual claude-code-security-review pr-review-toolkit ad-hoc; do
    d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed: %s\n' "$token")")
    assert_rc "code + attestation token='$token'"    0 "$(run_in "$d")"
    rm -rf "$d"
done

# Token followed by acceptable end-anchors (whitespace, EOL, . , ;)
d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed: manual.\n')")
assert_rc "code + 'manual.' (period end-anchor)"     0 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed: manual, fixed regex.\n')")
assert_rc "code + 'manual, ...' (comma end-anchor)"  0 "$(run_in "$d")"
rm -rf "$d"

# Anti-gaming: substring of a recognised token should NOT pass
d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed: manualish\n')")
assert_rc "code + 'manualish' substring = block"     1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed: please-manual-do-it\n')")
assert_rc "code + 'please-manual-do-it' = block"     1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed: cat /etc/n/a.txt\n')")
assert_rc "code + 'n/a' inside path = block (n/a token removed)" 1 "$(run_in "$d")"
rm -rf "$d"

# `n/a` itself is no longer a recognised token
d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed: n/a\n')")
assert_rc "code + 'n/a' alone = block (token removed)" 1 "$(run_in "$d")"
rm -rf "$d"

# Unrecognised value does NOT count
d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed: yes\n')")
assert_rc "code + unrecognised value = block"        1 "$(run_in "$d")"
rm -rf "$d"

# Empty value does NOT count
d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\nSecurity reviewed:\n')")
assert_rc "code + empty value = block"               1 "$(run_in "$d")"
rm -rf "$d"

# Skip marker
d=$(make_repo "src/foo.ts" "$(printf 'feat: foo\n\n[skip security-review]\n')")
assert_rc "code + skip marker"                       0 "$(run_in "$d")"
rm -rf "$d"

# Env bypass
d=$(make_repo "src/foo.ts" "feat: foo")
assert_rc "code + env bypass"                        0 "$(run_in "$d" "SKIP_SECURITY_REVIEW=1")"
rm -rf "$d"

# --- PR-body fallback (gh stub) ---
# Stub gh returns a body that includes a recognised token on its own line
# (the ATTEST_RE anchors to start-of-line, so prose preceding the
# attestation line is fine but the token must NOT share its line with
# unrelated prose). -> pass.
d=$(make_repo "src/foo.ts" "feat: foo no attestation")
stub=$(make_gh_stub "$(printf '## Summary\nSome PR description prose.\n\n## Security review\n\nSecurity reviewed: manual\n')")
assert_rc "code + PR-body has 'manual' via gh stub"  0 "$(run_in_with_path "$d" "$stub")"
rm -rf "$d" "$stub"

# Stub gh returns a body WITHOUT the token -> block.
d=$(make_repo "src/foo.ts" "feat: foo no attestation")
stub=$(make_gh_stub "$(printf '## Summary\nSome PR description with no security attestation anywhere.\n')")
assert_rc "code + PR-body has no token via gh stub = block" 1 "$(run_in_with_path "$d" "$stub")"
rm -rf "$d" "$stub"

# Stub gh returns a body with a substring-gaming attempt -> block.
d=$(make_repo "src/foo.ts" "feat: foo no attestation")
stub=$(make_gh_stub "$(printf 'PR body line.\nSecurity reviewed: manualish\n')")
assert_rc "code + PR-body substring-gaming via gh stub = block" 1 "$(run_in_with_path "$d" "$stub")"
rm -rf "$d" "$stub"

# Inline-prose case: even if "Security reviewed:" appears mid-line, the
# ^ anchor in ATTEST_RE requires it at line start (modulo leading space).
# This is correct behaviour but worth pinning so a future ATTEST_RE relax
# doesn't accidentally weaken it.
d=$(make_repo "src/foo.ts" "feat: foo no attestation")
stub=$(make_gh_stub "Inline prose: Security reviewed: manual. Inline continues.")
assert_rc "code + PR-body inline-prose 'Security reviewed:' mid-line = block (anchor protected)" 1 "$(run_in_with_path "$d" "$stub")"
rm -rf "$d" "$stub"

# Mixed docs + code requires attestation (code presence is the trigger)
d=$(make_repo "src/foo.ts README.md" "feat: mixed")
assert_rc "mixed code+docs + no attestation = block" 1 "$(run_in "$d")"
rm -rf "$d"

d=$(make_repo "src/foo.ts README.md" "$(printf 'feat: mixed\n\nSecurity reviewed: manual\n')")
assert_rc "mixed code+docs + attestation"            0 "$(run_in "$d")"
rm -rf "$d"

# Main-branch push: skip.
d=$(mktemp -d)
(
    cd "$d" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    mkdir -p src
    echo r > src/foo.ts
    git add -A
    git -c commit.gpgsign=false commit -q -m "feat: foo"
) >/dev/null 2>&1
assert_rc "on main branch — skip"                    0 "$(run_in "$d")"
rm -rf "$d"

# Linked-worktree behaviour: feature touches only docs but origin/main
# touches non-docs code (simulating another PR landed). Hook should NOT
# fire because the feature branch diff itself is docs-only.
d=$(mktemp -d)
origin=$(mktemp -d)
(
    cd "$origin" || exit 1
    git init -q --bare -b main
) >/dev/null 2>&1
(
    cd "$d" || exit 1
    git clone -q "$origin" . >/dev/null 2>&1
    git config user.email t@t
    git config user.name t
    echo r > README.md
    git add README.md
    git -c commit.gpgsign=false commit -q -m "init"
    git push -q origin main >/dev/null 2>&1
    git checkout -q -b feat/x
    echo "docs body" > docs.md
    git add docs.md
    git -c commit.gpgsign=false commit -q -m "docs: add docs"
    git checkout -q main
    mkdir -p src
    echo "other code" > src/other.ts
    git add src/other.ts
    git -c commit.gpgsign=false commit -q -m "feat: other code on main"
    git push -q origin main >/dev/null 2>&1
    git reset -q --hard HEAD~1
    git checkout -q feat/x
    git fetch -q origin main >/dev/null 2>&1
) >/dev/null 2>&1
assert_rc "linked-worktree: docs-only feat, ignore origin-only code" 0 "$(run_in "$d" "SECURITY_REVIEW_NO_FETCH=1")"
rm -rf "$d" "$origin"

# --- HIMMEL-297: master-default repo ---
# A repo whose default branch is master (no main ref). Pre-fix the hook found
# neither origin/main nor local main and SKIPPED (false pass). Post-fix
# default_branch resolves master, so a code file with no attestation BLOCKS,
# and a push while sitting on master is skipped.
make_master_repo() {
    local files="$1" msg="$2" dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b master
        git config user.email t@t
        git config user.name t
        echo r > README.md
        git add README.md
        git -c commit.gpgsign=false commit -q -m "init"
        git checkout -q -b feat/x
        # shellcheck disable=SC2086 # files is space-separated, intentional split
        for f in $files; do
            mkdir -p "$(dirname "$f")"
            echo "x" > "$f"
        done
        git add -A
        git -c commit.gpgsign=false commit -q -m "$msg"
    )
    echo "$dir"
}

d=$(make_master_repo "src/foo.ts" "feat: add foo")
assert_rc "master-default: code + no attestation = block (base resolved to master)" 1 "$(run_in "$d" "SECURITY_REVIEW_NO_FETCH=1")"
rm -rf "$d"

d=$(mktemp -d)
(
    cd "$d" || exit 1
    git init -q -b master
    git config user.email t@t
    git config user.name t
    mkdir -p src
    echo r > src/foo.ts
    git add -A
    git -c commit.gpgsign=false commit -q -m "feat: foo"
) >/dev/null 2>&1
assert_rc "on master branch — skip"                  0 "$(run_in "$d")"
rm -rf "$d"

# --- HIMMEL-323 item 1: fail-CLOSED on an unresolvable diff base ---
# A repo with NO main/master ref and NO remote: default_branch falls back to
# "main", which doesn't exist, so no diff base resolves. ONLINE (no *_NO_FETCH)
# this is a genuinely-broken state -> fail CLOSED (exit 2). With NO_FETCH the
# operator opted into offline mode -> skip (exit 0) with a loud warning, so
# offline/shallow workflows are preserved.
make_no_default_repo() {
    local files="$1" msg="$2" dir
    dir=$(mktemp -d)
    (
        cd "$dir" || exit 1
        git init -q -b feat/x   # HEAD on a feature branch; no main/master ref ever created
        git config user.email t@t
        git config user.name t
        # shellcheck disable=SC2086 # files is space-separated, intentional split
        for f in $files; do mkdir -p "$(dirname "$f")"; echo x > "$f"; done
        git add -A
        git -c commit.gpgsign=false commit -q -m "$msg"
    )
    echo "$dir"
}

d=$(make_no_default_repo "src/foo.ts" "feat: add foo")
assert_rc "unresolvable base, online -> fail CLOSED (exit 2)"         2 "$(run_in "$d")"
assert_rc "unresolvable base, NO_FETCH -> skip + warn (exit 0)"       0 "$(run_in "$d" "SECURITY_REVIEW_NO_FETCH=1")"
rm -rf "$d"

# --- HIMMEL-323 item 2: branch resolved via lib.sh::_branch (worktree-correct) ---
# Non-git dir: _branch returns rc=2 -> hook fails CLOSED (exit 2) with a clear
# diagnostic, rather than letting `set -e` abort on git's opaque exit 128.
ngd=$(mktemp -d)
assert_rc "non-git dir -> rc=2 fail-closed (cannot read branch)"     2 "$(run_in "$ngd")"
rm -rf "$ngd"

# Pin that the gate FIRES from a LINKED worktree on a feature branch while the
# PRIMARY checkout sits on main: under the natural pre-push env (GIT_DIR points
# at the worktree's own gitdir) the gate must read the worktree branch (feat/x),
# see the non-docs code, and BLOCK — never read the primary's 'main' and skip.
# NOTE: this is a regression-PIN, not a fix-prover — `git branch --show-current`
# is already worktree-correct in the natural env, so this passes on old code too.
# The genuine new-behaviour prover for the _branch switch is the non-git-dir
# rc=2 case above (old code aborted via set -e with git's opaque exit 128).
origin=$(mktemp -d); base=$(mktemp -d)
( cd "$origin" || exit 1; git init -q --bare -b main ) >/dev/null 2>&1
(
    cd "$base" || exit 1
    git clone -q "$origin" . >/dev/null 2>&1
    git config user.email t@t
    git config user.name t
    echo r > README.md; git add -A; git -c commit.gpgsign=false commit -q -m init
    git push -q origin main >/dev/null 2>&1
    git worktree add -q -b feat/x "${base}-wt" >/dev/null 2>&1
    mkdir -p "${base}-wt/src"; echo 'export const x = 1' > "${base}-wt/src/new.ts"
    git -C "${base}-wt" add -A
    git -C "${base}-wt" -c commit.gpgsign=false commit -q -m "feat: code, no attestation"
) >/dev/null 2>&1
wtgd="${base}/.git/worktrees/$(basename "${base}-wt")"
rc_wt=$( cd "${base}-wt" && env GIT_DIR="$wtgd" SECURITY_REVIEW_NO_FETCH=1 bash "$HOOK" >/dev/null 2>&1; echo $? )
assert_rc "linked worktree (primary on main): reads worktree branch + blocks" 1 "$rc_wt"
git -C "$base" worktree remove --force "${base}-wt" >/dev/null 2>&1 || true
rm -rf "$origin" "$base" "${base}-wt"

# --- HIMMEL-323: NO_FETCH only suppresses the fetch, NOT the gate ---
# A repo with a resolvable LOCAL base + code + no attestation, run with
# SECURITY_REVIEW_NO_FETCH=1, must still BLOCK (rc=1) — NO_FETCH skips only the
# network refresh, it must never short-circuit the gate when a base resolves.
d=$(make_repo "src/foo.ts" "feat: code, no attestation")
assert_rc "NO_FETCH with a resolvable base still gates (block rc=1)"  1 "$(run_in "$d" "SECURITY_REVIEW_NO_FETCH=1")"
rm -rf "$d"

# --- HIMMEL-323 item 1 (CR follow-up): fail-CLOSED when the diff itself errors ---
# An orphan/unrelated-history branch has no merge base, so `git diff base...HEAD`
# exits non-zero. The old `|| true` swallowed that to an empty changed-set -> a
# silent PASS on code never inspected. Now it fails CLOSED (exit 2).
d=$(mktemp -d)
(
    cd "$d" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    echo r > README.md; git add -A; git -c commit.gpgsign=false commit -q -m init
    git checkout -q --orphan feat/x
    git rm -rfq . 2>/dev/null || true
    mkdir -p src; echo 'export const x = 1' > src/foo.ts
    git add -A; git -c commit.gpgsign=false commit -q -m "feat: orphan code"
) >/dev/null 2>&1
assert_rc "orphan branch (no merge base) -> fail CLOSED (exit 2)"    2 "$(run_in "$d" "SECURITY_REVIEW_NO_FETCH=1")"
rm -rf "$d"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
