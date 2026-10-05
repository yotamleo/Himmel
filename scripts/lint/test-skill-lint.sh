#!/usr/bin/env bash
# test-skill-lint.sh — Tests for scripts/lint/skill-lint.sh (HIMMEL-3609).
#
# Usage: bash scripts/lint/test-skill-lint.sh
#
# Cases (RED-first: each fixture is built to violate exactly one rule and
# asserted to fail with that rule's tag before any fix would be applied):
#   1. no-frontmatter  : a SKILL.md with no --- block → [no-frontmatter], exit 1
#   2. no-name         : frontmatter with description but no name: → [no-name]
#   3. no-description  : frontmatter with name but no description: → [no-description]
#   4. name-mismatch   : name: differs from the parent directory name
#   5. dup-name        : two files under different dirs share the same name:
#   6. clean fixture   : a well-formed SKILL.md → exit 0
#   7. --staged mode   : lints only staged in-scope SKILL.md paths
#   8. --help          : exits 0 and prints usage
#   9. real tree       : the repo's actual in-scope SKILL.md corpus is clean
#  10. --staged/index  : --staged lints the INDEX content, not the working tree
#      (a) bad staged frontmatter + a clean unstaged edit on disk -> flagged
#      (b) clean staged frontmatter + a bad unstaged edit on disk -> not flagged
#  11. no-description  : a comment-only description (`# TODO`) counts as empty
#  12. description ok  : real text followed by a trailing `# comment` stays clean
#  13. name-mismatch   : a quoted name: with trailing whitespace still matches
#  14. description ok  : a quoted value holding ` # ` (`" # TODO"`) is not a comment
#      (b) an empty quoted value plus a trailing comment is still empty
#  15. tab in path     : a path containing a TAB is linted by its real path
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/skill-lint.sh"

[ -f "$LINT" ] || { printf 'FAIL: skill-lint.sh not found at %s\n' "$LINT"; exit 1; }

PASS=0
FAIL=0
TMP_ROOT=""
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL: %s\n' "$1"
    [ $# -ge 2 ] && printf '        %s\n' "$2"
    FAIL=$((FAIL + 1))
}
assert_contains() {
    if grepq "$3" -F -- "$2"; then pass "$1"; else fail "$1" "missing: $2"; fi
}
assert_not_contains() {
    if grepq "$3" -F -- "$2"; then fail "$1" "unexpected: $2"; else pass "$1"; fi
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-lint.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$TMP_ROOT" ] || { echo "FATAL: mktemp -d returned empty" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Case 1: no frontmatter block
# ---------------------------------------------------------------------------
printf '\nCase 1: [no-frontmatter]\n'

mkdir -p "$TMP_ROOT/no-fm-skill"
NOFM="$TMP_ROOT/no-fm-skill/SKILL.md"
cat > "$NOFM" <<'EOF'
# no-fm-skill

Just prose, no frontmatter block at all.
EOF

OUT1="$(bash "$LINT" "$NOFM" 2>&1)"; EC1=$?
if [ "$EC1" -eq 1 ]; then pass "exit 1 on missing frontmatter"; else fail "expected exit 1, got $EC1" "$OUT1"; fi
assert_contains "[no-frontmatter] tag present" "no-frontmatter" "$OUT1"

# ---------------------------------------------------------------------------
# Case 2: frontmatter present but no name:
# ---------------------------------------------------------------------------
printf '\nCase 2: [no-name]\n'

mkdir -p "$TMP_ROOT/no-name-skill"
NONAME="$TMP_ROOT/no-name-skill/SKILL.md"
cat > "$NONAME" <<'EOF'
---
description: does something useful
---

# no-name-skill
EOF

OUT2="$(bash "$LINT" "$NONAME" 2>&1)"; EC2=$?
if [ "$EC2" -eq 1 ]; then pass "exit 1 on missing name:"; else fail "expected exit 1, got $EC2" "$OUT2"; fi
assert_contains "[no-name] tag present" "no-name" "$OUT2"

# ---------------------------------------------------------------------------
# Case 3: frontmatter present but no description:
# ---------------------------------------------------------------------------
printf '\nCase 3: [no-description]\n'

mkdir -p "$TMP_ROOT/no-desc-skill"
NODESC="$TMP_ROOT/no-desc-skill/SKILL.md"
cat > "$NODESC" <<'EOF'
---
name: no-desc-skill
---

# no-desc-skill
EOF

OUT3="$(bash "$LINT" "$NODESC" 2>&1)"; EC3=$?
if [ "$EC3" -eq 1 ]; then pass "exit 1 on missing description:"; else fail "expected exit 1, got $EC3" "$OUT3"; fi
assert_contains "[no-description] tag present" "no-description" "$OUT3"

# ---------------------------------------------------------------------------
# Case 4: name: != parent directory name
# ---------------------------------------------------------------------------
printf '\nCase 4: [name-mismatch]\n'

mkdir -p "$TMP_ROOT/actual-dir-name"
MISMATCH="$TMP_ROOT/actual-dir-name/SKILL.md"
cat > "$MISMATCH" <<'EOF'
---
name: some-other-name
description: does something useful
---

# actual-dir-name
EOF

OUT4="$(bash "$LINT" "$MISMATCH" 2>&1)"; EC4=$?
if [ "$EC4" -eq 1 ]; then pass "exit 1 on name/dirname mismatch"; else fail "expected exit 1, got $EC4" "$OUT4"; fi
assert_contains "[name-mismatch] tag present" "name-mismatch" "$OUT4"

# ---------------------------------------------------------------------------
# Case 5: duplicate name: across two files
# ---------------------------------------------------------------------------
printf '\nCase 5: [dup-name]\n'

mkdir -p "$TMP_ROOT/dup-a" "$TMP_ROOT/dup-b"
cat > "$TMP_ROOT/dup-a/SKILL.md" <<'EOF'
---
name: shared-name
description: first copy
---

# dup-a
EOF
cat > "$TMP_ROOT/dup-b/SKILL.md" <<'EOF'
---
name: shared-name
description: second copy
---

# dup-b
EOF

OUT5="$(bash "$LINT" "$TMP_ROOT/dup-a/SKILL.md" "$TMP_ROOT/dup-b/SKILL.md" 2>&1)"; EC5=$?
if [ "$EC5" -eq 1 ]; then pass "exit 1 on duplicate name:"; else fail "expected exit 1, got $EC5" "$OUT5"; fi
assert_contains "[dup-name] tag present" "dup-name" "$OUT5"
assert_contains "dup-name names the shared value" "shared-name" "$OUT5"

# ---------------------------------------------------------------------------
# Case 6: a well-formed SKILL.md is clean
# ---------------------------------------------------------------------------
printf '\nCase 6: clean fixture exits 0\n'

mkdir -p "$TMP_ROOT/clean-skill"
CLEAN="$TMP_ROOT/clean-skill/SKILL.md"
cat > "$CLEAN" <<'EOF'
---
name: clean-skill
description: a well-formed skill for the clean-fixture test case
---

# clean-skill
EOF

OUT6="$(bash "$LINT" "$CLEAN" 2>&1)"; EC6=$?
if [ "$EC6" -eq 0 ]; then pass "clean fixture exits 0"; else fail "expected exit 0, got $EC6" "$OUT6"; fi

# ---------------------------------------------------------------------------
# Case 7: --staged mode scopes to staged in-scope SKILL.md paths
# ---------------------------------------------------------------------------
printf '\nCase 7: --staged mode\n'

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.claude/skills/staged-bad" "$REPO/.claude/skills/unstaged-bad"
(
    cd "$REPO" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    cat > .claude/skills/staged-bad/SKILL.md <<'EOF'
---
description: missing a name field
---
EOF
    cat > .claude/skills/unstaged-bad/SKILL.md <<'EOF'
---
description: also missing a name field
---
EOF
    git add .claude/skills/staged-bad/SKILL.md
)
OUT7="$(cd "$REPO" && bash "$LINT" --staged 2>&1)"; EC7=$?
if [ "$EC7" -eq 1 ]; then pass "--staged exits 1 on a staged issue"; else fail "expected exit 1, got $EC7" "$OUT7"; fi
assert_contains "--staged reports the staged file" "staged-bad" "$OUT7"
assert_not_contains "--staged ignores the unstaged file" "unstaged-bad" "$OUT7"

# ---------------------------------------------------------------------------
# Case 8: --help
# ---------------------------------------------------------------------------
printf '\nCase 8: --help\n'

OUT8="$(bash "$LINT" --help 2>&1)"; EC8=$?
if [ "$EC8" -eq 0 ]; then pass "--help exits 0"; else fail "expected exit 0, got $EC8" "$OUT8"; fi
assert_contains "--help prints usage" "Usage:" "$OUT8"

# ---------------------------------------------------------------------------
# Case 9: the real repo's in-scope SKILL.md corpus is clean
# ---------------------------------------------------------------------------
printf '\nCase 9: real in-scope tree is clean\n'

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel)"
OUT9="$(cd "$REPO_ROOT" && bash "$LINT" 2>&1)"; EC9=$?
if [ "$EC9" -eq 0 ]; then pass "real tree exits 0 (regression guard, not a cleanup)"; else fail "expected exit 0, got $EC9" "$OUT9"; fi

# ---------------------------------------------------------------------------
# Case 10: --staged lints the INDEX, not the working tree
# ---------------------------------------------------------------------------
printf '\nCase 10a: --staged flags bad STAGED content despite a clean unstaged edit\n'

REPO2="$TMP_ROOT/repo2"
mkdir -p "$REPO2/.claude/skills/divergent-skill"
(
    cd "$REPO2" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    cat > .claude/skills/divergent-skill/SKILL.md <<'EOF'
---
description: missing a name field, staged
---
EOF
    git add .claude/skills/divergent-skill/SKILL.md
    cat > .claude/skills/divergent-skill/SKILL.md <<'EOF2'
---
name: divergent-skill
description: fixed on disk but not staged
---
EOF2
)
OUT10A="$(cd "$REPO2" && bash "$LINT" --staged 2>&1)"; EC10A=$?
if [ "$EC10A" -eq 1 ]; then pass "--staged flags bad staged content even when the working tree is clean"; else fail "expected exit 1, got $EC10A" "$OUT10A"; fi
assert_contains "--staged [no-name] on the staged (not working-tree) content" "no-name" "$OUT10A"

printf '\nCase 10b: --staged stays clean when only the working tree is broken\n'

REPO3="$TMP_ROOT/repo3"
mkdir -p "$REPO3/.claude/skills/divergent-skill2"
(
    cd "$REPO3" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    cat > .claude/skills/divergent-skill2/SKILL.md <<'EOF'
---
name: divergent-skill2
description: clean and staged
---
EOF
    git add .claude/skills/divergent-skill2/SKILL.md
    if [ -z "$(git diff --cached --name-only)" ]; then
        echo "FATAL: git add did not stage divergent-skill2/SKILL.md" >&2
        exit 1
    fi
    cat > .claude/skills/divergent-skill2/SKILL.md <<'EOF2'
---
description: broken on disk, missing name, not staged
---
EOF2
) || fail "Case 10b setup failed to stage the fixture" ""
OUT10B="$(cd "$REPO3" && bash "$LINT" --staged 2>&1)"; EC10B=$?
if [ "$EC10B" -eq 0 ]; then pass "--staged stays clean when only the working tree (not the index) is broken"; else fail "expected exit 0, got $EC10B" "$OUT10B"; fi

# ---------------------------------------------------------------------------
# Case 11: a comment-only description counts as empty
# ---------------------------------------------------------------------------
printf '\nCase 11: [no-description] on a comment-only value\n'

mkdir -p "$TMP_ROOT/comment-desc-skill"
COMMENTDESC="$TMP_ROOT/comment-desc-skill/SKILL.md"
cat > "$COMMENTDESC" <<'EOF'
---
name: comment-desc-skill
description: # TODO
---

# comment-desc-skill
EOF

OUT11="$(bash "$LINT" "$COMMENTDESC" 2>&1)"; EC11=$?
if [ "$EC11" -eq 1 ]; then pass "exit 1 on comment-only description"; else fail "expected exit 1, got $EC11" "$OUT11"; fi
assert_contains "[no-description] tag present for comment-only value" "no-description" "$OUT11"

# ---------------------------------------------------------------------------
# Case 12: real description text plus a trailing comment stays clean
# ---------------------------------------------------------------------------
printf '\nCase 12: description with real text and a trailing comment stays clean\n'

mkdir -p "$TMP_ROOT/trailing-comment-skill"
TRAILDESC="$TMP_ROOT/trailing-comment-skill/SKILL.md"
cat > "$TRAILDESC" <<'EOF'
---
name: trailing-comment-skill
description: real text # note
---

# trailing-comment-skill
EOF

OUT12="$(bash "$LINT" "$TRAILDESC" 2>&1)"; EC12=$?
if [ "$EC12" -eq 0 ]; then pass "description with real text plus a trailing comment stays clean"; else fail "expected exit 0, got $EC12" "$OUT12"; fi

# ---------------------------------------------------------------------------
# Case 13: a quoted name: with trailing whitespace still matches the parent dir
# ---------------------------------------------------------------------------
printf '\nCase 13: quoted name: with trailing whitespace avoids a false name-mismatch\n'

mkdir -p "$TMP_ROOT/quoted-name-skill"
QUOTEDNAME="$TMP_ROOT/quoted-name-skill/SKILL.md"
printf -- '---\nname: "quoted-name-skill"  \ndescription: quoted name with trailing spaces\n---\n\n# quoted-name-skill\n' > "$QUOTEDNAME"

OUT13="$(bash "$LINT" "$QUOTEDNAME" 2>&1)"; EC13=$?
if [ "$EC13" -eq 0 ]; then pass "quoted name: with trailing whitespace still matches the parent dir"; else fail "expected exit 0, got $EC13" "$OUT13"; fi

# ---------------------------------------------------------------------------
# Case 14: a ` #` inside a quoted description is content, not a comment
# ---------------------------------------------------------------------------
printf '\nCase 14: quoted description containing " # " is not reported empty\n'

mkdir -p "$TMP_ROOT/quoted-hash-skill"
QUOTEDHASH="$TMP_ROOT/quoted-hash-skill/SKILL.md"
cat > "$QUOTEDHASH" <<'EOF'
---
name: quoted-hash-skill
description: " # TODO"
---

# quoted-hash-skill
EOF

OUT14="$(bash "$LINT" "$QUOTEDHASH" 2>&1)"; EC14=$?
if [ "$EC14" -eq 0 ]; then pass "quoted description with an inner ' # ' exits 0"; else fail "expected exit 0, got $EC14" "$OUT14"; fi
assert_not_contains "no [no-description] for a quoted ' # ' value" "no-description" "$OUT14"

printf '\nCase 14b: an empty quoted description followed by a comment is still empty\n'

mkdir -p "$TMP_ROOT/empty-quoted-skill"
EMPTYQUOTED="$TMP_ROOT/empty-quoted-skill/SKILL.md"
cat > "$EMPTYQUOTED" <<'EOF'
---
name: empty-quoted-skill
description: "" # TODO
---
EOF

OUT14B="$(bash "$LINT" "$EMPTYQUOTED" 2>&1)"; EC14B=$?
if [ "$EC14B" -eq 1 ]; then pass "empty quoted description exits 1"; else fail "expected exit 1, got $EC14B" "$OUT14B"; fi
assert_contains "[no-description] for an empty quoted value" "no-description" "$OUT14B"

# ---------------------------------------------------------------------------
# Case 15: a path containing a TAB is linted by its real path
# ---------------------------------------------------------------------------
printf '\nCase 15: a path containing a TAB is linted by its real path\n'

TABDIR="$TMP_ROOT/tab$(printf '\t')parent"
mkdir -p "$TABDIR/tab-path-skill" "$TABDIR/tab-bad-skill"
cat > "$TABDIR/tab-path-skill/SKILL.md" <<'EOF'
---
name: tab-path-skill
description: lives under a directory whose name holds a tab
---
EOF
cat > "$TABDIR/tab-bad-skill/SKILL.md" <<'EOF'
---
description: missing a name field, under a tab path
---
EOF

OUT15A="$(bash "$LINT" "$TABDIR/tab-path-skill/SKILL.md" 2>&1)"; EC15A=$?
if [ "$EC15A" -eq 0 ]; then pass "clean file under a tab path exits 0"; else fail "expected exit 0, got $EC15A" "$OUT15A"; fi
assert_contains "clean tab-path file is actually checked" "clean (1 file(s) checked)" "$OUT15A"

OUT15B="$(bash "$LINT" "$TABDIR/tab-bad-skill/SKILL.md" 2>&1)"; EC15B=$?
if [ "$EC15B" -eq 1 ]; then pass "bad file under a tab path exits 1"; else fail "expected exit 1, got $EC15B" "$OUT15B"; fi
assert_contains "finding names the real tab-holding path" "$TABDIR/tab-bad-skill/SKILL.md:" "$OUT15B"
assert_contains "[no-name] reported for the tab-path file" "no-name" "$OUT15B"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
