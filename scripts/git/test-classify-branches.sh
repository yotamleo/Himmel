#!/usr/bin/env bash
# Hermetic tests for classify-branches.sh (HIMMEL-1600).
#
# Every case runs in a throwaway repo built here, and the PR data comes from
# --pr-map, so the suite never touches the network, gh, or the real repo.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/classify-branches.sh"
TMP="$(mktemp -d -t classify-branches-test.XXXXXX)"
# Windows keeps git's pack handles open briefly after the process exits, so a
# straight rm can EBUSY and fail an otherwise-passing run. Swallow it.
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

FAILED=0
assert_line() { # <label> <verdict> <branch> <output>
    local label="$1" verdict="$2" branch="$3" out="$4" line
    line=$(printf '%s\n' "$out" | grep -E "^[A-Z]+ +${branch}\$" | head -1)
    if [ -z "$line" ]; then
        echo "FAIL $label — no verdict line for '$branch'"; FAILED=$((FAILED + 1)); return
    fi
    case "$line" in
        "$verdict"*) echo "PASS $label ($line)" ;;
        *) echo "FAIL $label — expected $verdict, got: $line"; FAILED=$((FAILED + 1)) ;;
    esac
}

R="$TMP/repo"
mkdir -p "$R"
cd "$R" || exit 2
git init -q -b main .
git config user.email t@t.t; git config user.name t; git config commit.gpgsign false

seed() { printf '%s\n' "$2" > "$1"; git add "$1"; }

seed base.txt "base"
git commit -qm "base"

# --- squash-merged branch: content is in main, but under a NEW commit whose
# patch-id differs from every commit on the branch. This is the case git log
# main..B and git cherry both get wrong.
git checkout -q -b feat/squashed
seed sq.txt "squashed content"
git commit -qm "sq c1"
printf 'more\n' >> sq.txt; git add sq.txt; git commit -qm "sq c2"
git checkout -q main
git merge -q --squash feat/squashed >/dev/null 2>&1
git commit -qm "squash: feat/squashed"

# --- genuinely unlanded branch
git checkout -q -b feat/ahead main
seed ahead.txt "never landed"
git commit -qm "ahead"

# --- closed-unmerged-but-landed-via-another-PR: the branch's content shipped
# in a DIFFERENT commit on main, and its own PR was CLOSED, not merged.
git checkout -q -b feat/closed-but-landed main
seed carried.txt "carried content"
git commit -qm "carried"
git checkout -q main
seed carried.txt "carried content"
git commit -qm "someone else shipped the same content"

# --- a branch that ADDS a file and one that DELETES a file, landed
git checkout -q -b feat/deletes main
git rm -q base.txt
git commit -qm "delete base.txt"
git checkout -q main
git merge -q --squash feat/deletes >/dev/null 2>&1
git commit -qm "squash: delete base.txt"

# --- a branch that deletes a file where the deletion did NOT land
git checkout -q -b feat/delete-unlanded main
seed keeper.txt "keep me"
git commit -qm "add keeper"
git checkout -q main
git merge -q --squash feat/delete-unlanded >/dev/null 2>&1
git commit -qm "squash: add keeper"
git checkout -q -b feat/delete-not-landed main
git rm -q keeper.txt
git commit -qm "delete keeper (never lands)"

# --- EMPTY file added on a branch, landed. The trap: an empty blob and an
# absent path both hash to e69de29…, so a hash-object probe cannot tell them
# apart and would call this ABSENT.
git checkout -q -b feat/empty main
: > empty.txt; git add empty.txt
git commit -qm "add an empty file"
git checkout -q main
git merge -q --squash feat/empty >/dev/null 2>&1
git commit -qm "squash: empty file"

# --- EMPTY file added on a branch that did NOT land: must be AHEAD, proving
# the empty-blob handling is not just "always says present".
git checkout -q -b feat/empty-unlanded main
: > lonely-empty.txt; git add lonely-empty.txt
git commit -qm "add an unlanded empty file"

# --- RENAME on a landed branch. The trap: diff.renames defaults to TRUE since
# Git 2.9, so without an explicit --no-renames the walk sees one
# `R100<TAB>old<TAB>new` line, binds the path to the tab-joined "old<TAB>new",
# finds no blob for it, and misreports this landed branch AHEAD.
#
# The file MUST already exist at the merge-base, or git has nothing to rename
# FROM and emits a plain `A` — which is why it is committed on main first. A
# fixture that creates and renames the file entirely on the branch passes with
# or without the fix and proves nothing.
git checkout -q main
printf 'a\nb\nc\nd\ne\n' > renamed-from.txt
git add renamed-from.txt
git commit -qm "add a file that a later branch renames"
git checkout -q -b feat/renames main
git mv renamed-from.txt renamed-to.txt
git commit -qm "rename it"
git checkout -q main
git merge -q --squash feat/renames >/dev/null 2>&1
git commit -qm "squash: the rename"

git checkout -q main

PRMAP="$TMP/prmap.tsv"
printf 'feat/closed-but-landed\tCLOSED\n' > "$PRMAP"

out=$(bash "$SUT" --base main --pr-map "$PRMAP" --verbose 2>&1)
echo "$out"
echo "---"

assert_line "squash-merged branch is LANDED"        LANDED feat/squashed            "$out"
assert_line "genuinely unlanded branch is AHEAD"    AHEAD  feat/ahead               "$out"
assert_line "closed-unmerged-but-landed is LANDED"  LANDED feat/closed-but-landed   "$out"
assert_line "landed DELETION is LANDED"             LANDED feat/deletes             "$out"
assert_line "unlanded DELETION is AHEAD"            AHEAD  feat/delete-not-landed   "$out"
assert_line "landed EMPTY file is LANDED"           LANDED feat/empty               "$out"
assert_line "unlanded EMPTY file is AHEAD"          AHEAD  feat/empty-unlanded      "$out"
assert_line "landed branch with a RENAME is LANDED" LANDED feat/renames             "$out"

# A merged PR short-circuits content comparison entirely.
printf 'feat/ahead\tMERGED\n' > "$TMP/prmap2.tsv"
out2=$(bash "$SUT" --base main --pr-map "$TMP/prmap2.tsv" 2>&1)
assert_line "merged PR wins over content (LANDED)"  LANDED feat/ahead               "$out2"

# MERGED must win even when the same branch also carries a CLOSED PR row.
printf 'feat/ahead\tCLOSED\nfeat/ahead\tMERGED\n' > "$TMP/prmap3.tsv"
out3=$(bash "$SUT" --base main --pr-map "$TMP/prmap3.tsv" 2>&1)
assert_line "MERGED beats a sibling CLOSED row"     LANDED feat/ahead               "$out3"

# --pattern narrows the report.
out4=$(bash "$SUT" --base main --pr-map "$PRMAP" --pattern 'feat/ahead' 2>&1)
if printf '%s\n' "$out4" | grep -qE '^[A-Z]+ +feat/squashed$'; then
    echo "FAIL --pattern still reported a non-matching branch"; FAILED=$((FAILED + 1))
else
    echo "PASS --pattern excludes non-matching branches"
fi

# Report-only contract: the branch list must be identical before and after.
before=$(git for-each-ref --format='%(refname:short)' refs/heads/ | sort)
bash "$SUT" --base main --pr-map "$PRMAP" >/dev/null 2>&1
after=$(git for-each-ref --format='%(refname:short)' refs/heads/ | sort)
if [ "$before" = "$after" ]; then
    echo "PASS report-only: no branch was created or deleted"
else
    echo "FAIL report-only: the branch list changed"; FAILED=$((FAILED + 1))
fi

# Usage errors.
assert_rc2() { # <label> <rc>
    if [ "$2" -eq 2 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1 — expected rc=2, got rc=$2"; FAILED=$((FAILED + 1))
    fi
}
bash "$SUT" --base does-not-exist >/dev/null 2>&1
assert_rc2 "missing base ref exits 2" $?
bash "$SUT" --bogus >/dev/null 2>&1
assert_rc2 "unknown flag exits 2" $?

echo "---"
if [ "$FAILED" -gt 0 ]; then
    echo "test-classify-branches: $FAILED FAILURE(S)"
    exit 1
fi
echo "test-classify-branches: all cases pass"
