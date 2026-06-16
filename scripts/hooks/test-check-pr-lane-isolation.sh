#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-pr-lane-isolation.sh (HIMMEL-214).
#
# Usage: bash scripts/hooks/test-check-pr-lane-isolation.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-pr-lane-isolation.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

FAILED=0

# Simulate a CONSUMING repo (pre-commit runs hooks with CWD = consuming repo
# root and passes the `files:`-matched staged filenames as args; the hook
# reads CWD's git state, not the hook repo's).
REPO="$TMP/consumer"
git init -q -b main "$REPO" 2>/dev/null || { git init -q "$REPO" && git -C "$REPO" symbolic-ref HEAD refs/heads/main; }
git -C "$REPO" -c user.email=t@t.invalid -c user.name=t commit -q --allow-empty -m init

run_hook() {
    (cd "$REPO" && bash "$HOOK" "$@" >/dev/null 2>&1)
    echo "$?"
}

# T1: on main + one PR-lane filename → BLOCK (rc=1)
rc=$(run_hook "CLAUDE.md")
assert_rc "T1 main + PR-lane file" 1 "$rc"

# T2: on main + multiple filenames → BLOCK, message lists each path + SKIP hint
out=$( (cd "$REPO" && bash "$HOOK" "docs/a.md" "_Templates/t.md" 2>&1) ); rc=$?
assert_rc "T2 main + multiple files" 1 "$rc"
case "$out" in
    *"docs/a.md"*"_Templates/t.md"*) echo "PASS T2 message lists paths" ;;
    *) echo "FAIL T2 message lists paths — got: $out"; FAILED=$((FAILED + 1)) ;;
esac
case "$out" in
    *"SKIP=pr-lane-isolation"*) echo "PASS T2 SKIP hint present" ;;
    *) echo "FAIL T2 SKIP hint missing — got: $out"; FAILED=$((FAILED + 1)) ;;
esac

# T2b: filename with an internal space → still BLOCK and listed verbatim
# (pre-commit passes filenames as separate argv entries; pins the quoted
# "$@" handling against future refactors)
out=$( (cd "$REPO" && bash "$HOOK" "docs/a b.md" 2>&1) ); rc=$?
assert_rc "T2b filename with space" 1 "$rc"
case "$out" in
    *"docs/a b.md"*) echo "PASS T2b path listed verbatim" ;;
    *) echo "FAIL T2b path listed verbatim — got: $out"; FAILED=$((FAILED + 1)) ;;
esac

# T3: on main + zero filenames (nothing matched `files:`) → ALLOW (rc=0)
rc=$(run_hook)
assert_rc "T3 main + no filenames" 0 "$rc"

# T4: on a feature branch + PR-lane filename → ALLOW (rc=0)
git -C "$REPO" switch -q -c chore/some-change
rc=$(run_hook "CLAUDE.md")
assert_rc "T4 feature branch" 0 "$rc"

# T5: detached HEAD + filename → ALLOW (rc=0; is_on_main returns 1 — same
# posture as check-worktree-isolation.sh: detached HEAD is not main)
git -C "$REPO" switch -q --detach main
rc=$(run_hook "CLAUDE.md")
assert_rc "T5 detached HEAD" 0 "$rc"
git -C "$REPO" switch -q main

# T6: not a git repo → FAIL CLOSED (rc=1; is_on_main rc=2 must not be
# demoted to "not on main")
NOREPO="$TMP/norepo"
mkdir -p "$NOREPO"
rc=$( (cd "$NOREPO" && GIT_CEILING_DIRECTORIES="$TMP" bash "$HOOK" "CLAUDE.md" >/dev/null 2>&1); echo "$?" )
assert_rc "T6 broken repo fails closed" 1 "$rc"

# T7: export manifest sanity — .pre-commit-hooks.yaml must exist at the repo
# root and reference both exported entries, and the entry scripts must exist
# (a renamed script with a stale manifest would break every consumer at their
# next `pre-commit run`).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/.pre-commit-hooks.yaml"
if [ -f "$MANIFEST" ]; then
    echo "PASS T7 manifest exists"
else
    echo "FAIL T7 manifest missing at $MANIFEST"
    FAILED=$((FAILED + 1))
fi
for id in pr-lane-isolation worktree-isolation; do
    if grep -q "^- id: $id\$" "$MANIFEST" 2>/dev/null; then
        echo "PASS T7 manifest exports $id"
    else
        echo "FAIL T7 manifest missing id: $id"
        FAILED=$((FAILED + 1))
    fi
done
# bash 3.2-safe (no process substitution; macOS ships 3.2 per
# scripts/hooks/CLAUDE.md): capture first, loop over a here-doc.
entries=$(sed -n 's/^  entry: //p' "$MANIFEST" 2>/dev/null)
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if [ -f "$ROOT/$entry" ]; then
        echo "PASS T7 entry exists: $entry"
    else
        echo "FAIL T7 entry missing: $entry"
        FAILED=$((FAILED + 1))
    fi
done <<EOF
$entries
EOF

# T8: missing guardrails/lib.sh must FAIL CLOSED (rc=1 + refusal message),
# not fall through to an undefined is_on_main. Copy the hook into a tree
# with NO guardrails/ (mirrors T16 in test-block-edit-on-main.sh).
LIBLESS="$TMP/libless"
mkdir -p "$LIBLESS/hooks"
cp "$HOOK" "$LIBLESS/hooks/"
err=$( (cd "$REPO" && bash "$LIBLESS/hooks/check-pr-lane-isolation.sh" "CLAUDE.md" 2>&1 >/dev/null) ); rc=$?
assert_rc "T8 missing lib.sh fails closed" 1 "$rc"
case "$err" in
    *"cannot source guardrails/lib.sh"*) echo "PASS T8 refusal message" ;;
    *) echo "FAIL T8 refusal message — got: $err"; FAILED=$((FAILED + 1)) ;;
esac

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
