#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-no-ticket-id-in-user-strings.sh (HIMMEL-2371).
#
# Adopters see hook display names, hook deny messages, and slash-command
# descriptions — a raw HIMMEL-\d+ in one of those leaks project-tracker
# internals into the UI. The ticket ID stays valid in a code comment / YAML
# comment beside the string; this gate only rejects it INSIDE the string.
#
# Exercises the guard's direct-file mode (no git, no himmel-dev gating) against
# hermetic fixtures for the three scanned surfaces: `.pre-commit-config.yaml`
# `name:` fields, `.claude/commands/*.md` frontmatter `description:`, and
# `scripts/hooks/*.sh` adopter-facing `echo`/`printf … >&2` deny messages.
#
# Usage: bash scripts/hooks/test-check-no-ticket-id-in-user-strings.sh
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-no-ticket-id-in-user-strings.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h2371.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

run() { (cd "$1" && bash "$GUARD" "$2") 2>&1; }

# Case 1 (POSITIVE CONTROL): .pre-commit-config.yaml name: carries a ticket ID -> BLOCKED
echo "== Case 1: .pre-commit-config.yaml name: with a raw ticket ID -> refused =="
mkdir -p "$tmp/c1"
cat > "$tmp/c1/.pre-commit-config.yaml" <<'EOF'
      - id: no-push-to-main
        name: Block direct push to main (HIMMEL-9999)
        entry: bash scripts/hooks/check-push-target.sh
EOF
out=$(run "$tmp/c1" .pre-commit-config.yaml); rc=$?
if [ "$rc" -eq 1 ]; then pass "case 1 -> exit 1"; else fail "case 1 -> expected 1 got $rc" "$out"; fi
case "$out" in
    *"carries a raw ticket ID"*"HIMMEL-9999"*) pass "case 1 -> message names the file and the string" ;;
    *) fail "case 1 -> unexpected message" "$out" ;;
esac

# Case 2 (NEGATIVE CONTROL): same hook, ticket ID moved to a YAML comment -> PASS
echo "== Case 2: same name:, ticket ID moved to a YAML comment -> passes =="
mkdir -p "$tmp/c2"
cat > "$tmp/c2/.pre-commit-config.yaml" <<'EOF'
      - id: no-push-to-main
        name: Block direct push to main
        # HIMMEL-9999
        entry: bash scripts/hooks/check-push-target.sh
EOF
out=$(run "$tmp/c2" .pre-commit-config.yaml); rc=$?
if [ "$rc" -eq 0 ]; then pass "case 2 -> exit 0"; else fail "case 2 -> expected 0 got $rc" "$out"; fi

# Case 2b (codex-1 CR round 2 regression guard): a `name:`-suffixed key
# (`othername:`, not a hook's own `name:` field) carrying a ticket ID must
# NOT be flagged — a plain `case "$line" in [[:space:]]*name:*)` glob is not
# a real anchor (`*` is not a quantifier on the class before it) and matched
# `othername:` too; the fix trims leading whitespace first, then anchors.
echo "== Case 2b: a name:-SUFFIXED key (othername:) is not mistaken for name: =="
mkdir -p "$tmp/c2b"
cat > "$tmp/c2b/.pre-commit-config.yaml" <<'EOF'
      - id: some-hook
        othername: something with HIMMEL-9999 in it
        entry: bash scripts/hooks/check-something.sh
EOF
out=$(run "$tmp/c2b" .pre-commit-config.yaml); rc=$?
if [ "$rc" -eq 0 ]; then
    pass "case 2b -> exit 0 (othername: is not name:)"
else
    fail "case 2b -> expected 0 got $rc" "$out"
fi

# Case 2c (codex-1 CR round 3 regression guard): a ticket ID placed in a
# TRAILING inline YAML comment on the name: line is already compliant (the
# displayed name pre-commit renders strips everything from the unquoted #) —
# must NOT be flagged.
echo "== Case 2c: ticket ID in a trailing inline YAML comment on name: -> passes =="
mkdir -p "$tmp/c2c"
ticket2c="HIMMEL""-123"
cat > "$tmp/c2c/.pre-commit-config.yaml" <<EOF
      - id: no-push-to-main
        name: Block direct push to main # $ticket2c
        entry: bash scripts/hooks/check-push-target.sh
EOF
out=$(run "$tmp/c2c" .pre-commit-config.yaml); rc=$?
if [ "$rc" -eq 0 ]; then
    pass "case 2c -> exit 0 (inline comment, not part of the displayed name)"
else
    fail "case 2c -> expected 0 got $rc" "$out"
fi

# Case 3: slash-command frontmatter description carries a ticket ID -> BLOCKED
echo "== Case 3: command frontmatter description: with a ticket ID -> refused =="
mkdir -p "$tmp/c3/.claude/commands"
cat > "$tmp/c3/.claude/commands/fake.md" <<'EOF'
---
description: Print something useful (HIMMEL-4242).
argument-hint: [--flag]
---

Body text here.
EOF
out=$(run "$tmp/c3" .claude/commands/fake.md); rc=$?
if [ "$rc" -eq 1 ]; then pass "case 3 -> exit 1"; else fail "case 3 -> expected 1 got $rc" "$out"; fi

# Case 4: same command, description clean, ticket ID only in the body -> PASS
# (the ticket only asks for the frontmatter description; body prose is fine).
echo "== Case 4: description clean, body still cites the ticket -> passes =="
mkdir -p "$tmp/c4/.claude/commands"
cat > "$tmp/c4/.claude/commands/fake.md" <<'EOF'
---
description: Print something useful.
argument-hint: [--flag]
---

Implements HIMMEL-4242's original request.
EOF
out=$(run "$tmp/c4" .claude/commands/fake.md); rc=$?
if [ "$rc" -eq 0 ]; then pass "case 4 -> exit 0"; else fail "case 4 -> expected 0 got $rc" "$out"; fi

# Case 5: a scripts/hooks/*.sh deny message (echo ... >&2) carries a ticket ID -> BLOCKED
#
# The ticket token below is assembled from two literals (never appearing as
# one contiguous "HIMMEL-NNNN" substring on an echo/printf/>&2 line in THIS
# test script's own source) so writing the fixture doesn't itself trip this
# gate on scripts/hooks/test-check-no-ticket-id-in-user-strings.sh — the
# fixture FILE on disk still gets the real, contiguous string.
echo "== Case 5: hook deny message (echo ... >&2) with a ticket ID -> refused =="
mkdir -p "$tmp/c5/scripts/hooks"
ticket="HIMMEL""-1000"
cat > "$tmp/c5/scripts/hooks/check-fake.sh" <<EOF
#!/usr/bin/env bash
# $ticket: this hook exists because of an incident.
echo "check-fake: refused, see $ticket for context" >&2
exit 1
EOF
out=$(run "$tmp/c5" scripts/hooks/check-fake.sh); rc=$?
if [ "$rc" -eq 1 ]; then pass "case 5 -> exit 1"; else fail "case 5 -> expected 1 got $rc" "$out"; fi
case "$out" in
    *"check-fake.sh:3"*) pass "case 5 -> flags the echoed line, not the header comment" ;;
    *) fail "case 5 -> wrong line flagged" "$out" ;;
esac

# Case 6: same hook, deny message clean, ticket ID stays in the header comment -> PASS
echo "== Case 6: deny message clean, ticket ID stays in a code comment -> passes =="
mkdir -p "$tmp/c6/scripts/hooks"
cat > "$tmp/c6/scripts/hooks/check-fake.sh" <<'EOF'
#!/usr/bin/env bash
# HIMMEL-1000: this hook exists because of an incident.
echo "check-fake: refused" >&2
exit 1
EOF
out=$(run "$tmp/c6" scripts/hooks/check-fake.sh); rc=$?
if [ "$rc" -eq 0 ]; then pass "case 6 -> exit 0"; else fail "case 6 -> expected 0 got $rc" "$out"; fi

# Case 7: docs/internals/** is allowlisted even under a scanned-looking name.
echo "== Case 7: docs/internals/** files are allowlisted =="
mkdir -p "$tmp/c7/docs/internals"
printf 'name: whatever (HIMMEL-1)\n' > "$tmp/c7/docs/internals/notes.md"
out=$(run "$tmp/c7" docs/internals/notes.md); rc=$?
if [ "$rc" -eq 0 ]; then pass "case 7 -> exit 0 (allowlisted path)"; else fail "case 7 -> expected 0 got $rc" "$out"; fi

# Case 8: an unscanned path (not one of the three surfaces) is never flagged,
# even with an obviously-offending line. Same token-assembly note as case 5.
echo "== Case 8: a path outside the scanned set is ignored =="
mkdir -p "$tmp/c8"
ticket8="HIMMEL""-1"
printf 'echo "whatever (%s)" >&2\n' "$ticket8" > "$tmp/c8/README.md"
out=$(run "$tmp/c8" README.md); rc=$?
if [ "$rc" -eq 0 ]; then pass "case 8 -> exit 0 (unscanned surface)"; else fail "case 8 -> expected 0 got $rc" "$out"; fi

# Case 9 (perf regression guard, HIMMEL-2371 CR round 1): a large hooks-shaped
# file must scan in well under a second — a per-line subshell fork made this
# effectively hang (17s for a 190-line file) under MSYS's slow fork().
echo "== Case 9: a large hook file scans fast (no per-line fork) =="
mkdir -p "$tmp/c9/scripts/hooks"
{
    echo '#!/usr/bin/env bash'
    i=0
    while [ "$i" -lt 800 ]; do
        echo "    echo \"line $i, nothing special here\" >&2"
        i=$((i + 1))
    done
} > "$tmp/c9/scripts/hooks/check-big.sh"
start=$(date +%s)
out=$(run "$tmp/c9" scripts/hooks/check-big.sh); rc=$?
elapsed=$(( $(date +%s) - start ))
if [ "$rc" -eq 0 ] && [ "$elapsed" -le 5 ]; then
    pass "case 9 -> 800-line file scans in ${elapsed}s (<=5s)"
else
    fail "case 9 -> rc=$rc elapsed=${elapsed}s (expected rc=0, <=5s)" "$out"
fi

# Case 10/11 (codex-1 CR round 1, gate mode only): the gate scans the STAGED
# git blob, not the working-tree file — a file staged clean and then dirtied
# further must not falsely block, and a file staged WITH a violation and then
# fixed only in the working tree must NOT let the violation through.
if command -v git >/dev/null 2>&1; then
    repo="$tmp/gaterepo"
    mkdir -p "$repo/scripts/hooks"
    (
        cd "$repo" || exit 1
        git init -q -b main . 2>/dev/null || { git init -q .; git symbolic-ref HEAD refs/heads/main; }
        git config user.email t@test.com
        git config user.name test
        git commit -q --allow-empty -m init
    )
    touch "$repo/.himmel-dev"  # gate mode is himmel-dev-only; opt this fixture in

    echo "== Case 10: staged CLEAN, working tree dirtied with a violation -> gate still PASSES =="
    ticket10="HIMMEL""-5000"
    printf '#!/usr/bin/env bash\necho "check-fake: refused" >&2\nexit 1\n' > "$repo/scripts/hooks/check-fake.sh"
    (cd "$repo" && git add scripts/hooks/check-fake.sh)
    printf '#!/usr/bin/env bash\necho "check-fake: refused, see %s" >&2\nexit 1\n' "$ticket10" > "$repo/scripts/hooks/check-fake.sh"
    out=$(cd "$repo" && bash "$GUARD" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "case 10 -> exit 0 (staged blob is clean, working-tree dirt ignored)"
    else
        fail "case 10 -> expected 0 got $rc" "$out"
    fi
    (cd "$repo" && git reset -q --hard >/dev/null 2>&1) || true

    echo "== Case 11: staged WITH a violation, working tree fixed -> gate still BLOCKS =="
    ticket11="HIMMEL""-6000"
    mkdir -p "$repo/scripts/hooks"  # git reset --hard above pruned the now-empty dir
    printf '#!/usr/bin/env bash\necho "check-fake: refused, see %s" >&2\nexit 1\n' "$ticket11" > "$repo/scripts/hooks/check-fake.sh"
    (cd "$repo" && git add scripts/hooks/check-fake.sh)
    printf '#!/usr/bin/env bash\necho "check-fake: refused" >&2\nexit 1\n' > "$repo/scripts/hooks/check-fake.sh"
    out=$(cd "$repo" && bash "$GUARD" 2>&1); rc=$?
    if [ "$rc" -eq 1 ]; then
        pass "case 11 -> exit 1 (staged blob still carries the violation)"
    else
        fail "case 11 -> expected 1 got $rc" "$out"
    fi

    # Case 12 (codex-2 CR round 3 regression guard): a renamed hook file that
    # ALSO gains a ticket ID in its deny message in the same commit must still
    # be caught — --diff-filter=ACM alone excludes a rename-with-content-change
    # (git classifies it as R only, never also M), letting it bypass the gate.
    echo "== Case 12: a RENAMED hook file with a newly-added ticket ID -> gate still BLOCKS =="
    mkdir -p "$repo/scripts/hooks"
    # Substantial shared boilerplate (git's default rename-detection threshold
    # is 50% similarity — a tiny 3-line file with two words changed does NOT
    # clear it and is classified as a plain delete+add, not a rename).
    padding=""
    p=0
    while [ "$p" -lt 30 ]; do
        padding="${padding}# boilerplate line $p shared between both versions
"
        p=$((p + 1))
    done
    printf '#!/usr/bin/env bash\n%secho "refused" >&2\nexit 1\n' "$padding" > "$repo/scripts/hooks/check-old.sh"
    (cd "$repo" && git add scripts/hooks/check-old.sh && git commit -q -m "add check-old.sh")
    ticket12="HIMMEL""-7000"
    (cd "$repo" && git mv scripts/hooks/check-old.sh scripts/hooks/check-new.sh)
    printf '#!/usr/bin/env bash\n%secho "refused, see %s" >&2\nexit 1\n' "$padding" "$ticket12" > "$repo/scripts/hooks/check-new.sh"
    (cd "$repo" && git add scripts/hooks/check-new.sh)
    status=$(cd "$repo" && git diff --cached --name-status)
    # codex-4 CR round 6: assert git actually classified this as a rename (R)
    # — without this, the case could pass via the plain ADDED-file path and
    # never exercise --diff-filter=ACMR's R inclusion at all.
    case "$status" in
        R*) pass "case 12 setup -> git classified the fixture as a rename (R)" ;;
        *) fail "case 12 setup -> expected an R status, got: $status" ;;
    esac
    out=$(cd "$repo" && bash "$GUARD" 2>&1); rc=$?
    if [ "$rc" -eq 1 ]; then
        pass "case 12 -> exit 1 (renamed file with a new ticket ID is still caught)"
    else
        fail "case 12 -> expected 1 got $rc (git status: $status)" "$out"
    fi
    (cd "$repo" && git reset -q --hard >/dev/null 2>&1) || true

    # Case 13 (codex-1 CR round 5 regression guard): a staged filename with a
    # non-ASCII character. Plain `--name-only` C-quotes it
    # (`"scripts/hooks/check-caf\303\251.sh"`), which would fail to resolve if
    # passed literally to `git show`; `-z` resolves the real path instead.
    echo "== Case 13: a staged file with a NON-ASCII filename is still scanned =="
    mkdir -p "$repo/scripts/hooks"
    ticket13="HIMMEL""-8000"
    printf '#!/usr/bin/env bash\necho "refused, see %s" >&2\nexit 1\n' "$ticket13" > "$repo/scripts/hooks/check-café.sh"
    (cd "$repo" && git add "scripts/hooks/check-café.sh")
    out=$(cd "$repo" && bash "$GUARD" 2>&1); rc=$?
    if [ "$rc" -eq 1 ]; then
        pass "case 13 -> exit 1 (non-ASCII filename resolved and scanned)"
    else
        fail "case 13 -> expected 1 got $rc" "$out"
    fi
    (cd "$repo" && git reset -q --hard >/dev/null 2>&1) || true
else
    echo "== Case 10/11/12/13 SKIPPED: git not installed =="
fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
