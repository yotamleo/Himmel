#!/usr/bin/env bash
# Tests for scripts/cr/anchor-handoff.sh (HIMMEL-3395): a gate writer entered
# by a RELATIVE path from a non-anchor tree runs the anchor's copy; an
# absolute entry runs the local copy; the relative door fails closed.
# T1-T10, T9b, T9c exercise scripts/cr/*.sh (depth 2 under the repo root).
# T11-T13 (HIMMEL-3437) exercise a depth-3 entry (scripts/handover/console-kit/*.sh)
# to prove the git-rev-parse-based root resolution is depth-agnostic.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WRITERS="write-verdicts clear-cr-marker panel-first-pass docs-audit-panel codex-adv-kickoff codex-adv-harvest doc-freshness-advisory known-findings ledger-append review-round orphan-check impacted-suites cr-scores"
# shellcheck disable=SC2016  # the literal line each writer carries, not an expansion
SOURCE_LINE='. "$(dirname "${BASH_SOURCE[0]}")/anchor-handoff.sh" || exit 2'

fail=0
pass=0
check() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else echo "FAIL: $3 — got '$1' want '$2'"; fail=1; fi; }

tmp="$(mktemp -d -t anchor-handoff.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# A tree holding the helper and a writer that is the real one up to (and
# including) its hand-off line, then a line naming which copy ran. Before the
# writer sources the helper, the whole head is just `set -uo pipefail`, so the
# local copy runs — the RED state.
#
# HIMMEL-3437: the generalized helper resolves its own root via
# `git rev-parse --show-toplevel`, so every fixture tree must be a real git
# repo (a bare `git init -q` — no commit needed, rev-parse works on an empty repo).
make_tree() {  # <root> <label>
    mkdir -p "$1/scripts/cr"
    git init -q "$1"
    cp "$DIR/anchor-handoff.sh" "$1/scripts/cr/anchor-handoff.sh"
    awk -v src="$SOURCE_LINE" '{ print } $0 == src { exit }' "$DIR/clear-cr-marker.sh" > "$1/scripts/cr/clear-cr-marker.sh.head"
    if grep -qxF "$SOURCE_LINE" "$1/scripts/cr/clear-cr-marker.sh.head"; then
        head=$(cat "$1/scripts/cr/clear-cr-marker.sh.head")
    else
        head='#!/usr/bin/env bash
set -uo pipefail'
    fi
    rm -f "$1/scripts/cr/clear-cr-marker.sh.head"
    printf '%s\necho "RAN:%s"\n' "$head" "$2" > "$1/scripts/cr/clear-cr-marker.sh"
}
anchor="$tmp/anchor"; wt="$tmp/wt"; bare="$tmp/bare"
make_tree "$anchor" anchor
make_tree "$wt" branch
mkdir -p "$bare"

run() {  # <cwd> <HIMMEL_REPO or -> <entry path>
    if [ "$2" = "-" ]; then
        (cd "$1" && env -u HIMMEL_REPO -u CR_ANCHOR_HANDED_OFF bash "$3" 2>/dev/null; echo "rc=$?")
    else
        (cd "$1" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$2" bash "$3" 2>/dev/null; echo "rc=$?")
    fi
}

# 1. Relative entry from an edited worktree runs the anchor's copy.
check "$(run "$wt" "$anchor" scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "RAN:anchor rc=0 " "T1 relative entry hands off"
# 2. `./` is relative too — decided on the path as invoked.
check "$(run "$wt" "$anchor" ./scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "RAN:anchor rc=0 " "T2 ./ entry hands off"
# 3. Absolute entry runs the local copy (the deliberate open door).
check "$(run "$wt" "$anchor" "$wt/scripts/cr/clear-cr-marker.sh" | tr '\n' ' ')" "RAN:branch rc=0 " "T3 absolute entry runs local"
# 4. Relative entry with HIMMEL_REPO unset fails closed.
check "$(run "$wt" - scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "rc=2 " "T4 unset HIMMEL_REPO exits 2"
# 5. Empty HIMMEL_REPO fails closed too.
check "$(run "$wt" "" scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "rc=2 " "T5 empty HIMMEL_REPO exits 2"
# 6. An anchor with no copy of the writer fails closed.
check "$(run "$wt" "$bare" scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "rc=2 " "T6 anchor lacks writer exits 2"
# 7. One hop only: an already-handed-off process that is still not the anchor refuses.
out=$(cd "$wt" && CR_ANCHOR_HANDED_OFF=1 HIMMEL_REPO="$anchor" bash scripts/cr/clear-cr-marker.sh 2>/dev/null; echo "rc=$?")
check "$out" "rc=2" "T7 second hop refuses"
# 8. Relative entry inside the anchor itself runs without a hand-off.
err=$(cd "$anchor" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$anchor" bash scripts/cr/clear-cr-marker.sh 2>&1 >/dev/null)
check "$(run "$anchor" "$anchor" scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "RAN:anchor rc=0 " "T8 anchor runs itself"
check "$err" "" "T8 no hand-off message in the anchor"
# 9. Arguments survive the hand-off. The stub reports argc plus each arg
# pipe-delimited (not "$*", which would make one spaced argument ("a b")
# indistinguishable from two ("a" "b") — see the T9c RED control below).
printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\n' "$SOURCE_LINE" > "$anchor/scripts/cr/known-findings.sh"
printf '%s\n' 'printf '\''%s|'\'' "$#" "$@"' >> "$anchor/scripts/cr/known-findings.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\necho "LOCAL"\n' "$SOURCE_LINE" > "$wt/scripts/cr/known-findings.sh"
check "$(cd "$wt" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$anchor" bash scripts/cr/known-findings.sh --diff 'a b' 2>/dev/null)" "2|--diff|a b|" "T9 args forwarded (argc + pipe-delimited, distinguishes 1 spaced arg from 2)"

# 9c. RED control: a scratch copy of the hand-off whose exec line re-splits
# with an unquoted $* instead of "$@" must FAIL the strengthened T9 above -
# proves the check actually catches that regression class. Never touches the
# real scripts/cr/anchor-handoff.sh; the mutation lives only in $tmp.
red="$tmp/red"
mkdir -p "$red/scripts/cr"
git init -q "$red"
sed 's/"\$@"/$*/' "$DIR/anchor-handoff.sh" > "$red/scripts/cr/anchor-handoff.sh"
# shellcheck disable=SC2016  # the literal line to look for, not an expansion
if grep -qF 'exec bash "$_ah_anchor/$_ah_rel" "$@"' "$red/scripts/cr/anchor-handoff.sh"; then
    echo "FAIL: T9c setup — mutant exec line unchanged, control proves nothing" >&2
    fail=1
fi
printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\necho "LOCAL"\n' "$SOURCE_LINE" > "$red/scripts/cr/known-findings.sh"
red_out="$(cd "$red" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$anchor" bash scripts/cr/known-findings.sh --diff 'a b' 2>/dev/null)"
red_rc=$?
# Assert the SPECIFIC unquoted-$* re-split shape (exit 0, argc 3: --diff a b),
# not merely "not the correct value" — a setup/exec failure would also be
# not-the-correct-value (e.g. empty output) and must not pass as evidence.
check "$red_rc:$red_out" "0:3|--diff|a|b|" "T9c RED control catches the unquoted \$* re-split"

# 9b. A tree whose helper is missing fails closed rather than running the local copy.
rm -f "$wt/scripts/cr/anchor-handoff.sh"
check "$(run "$wt" "$anchor" scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "rc=2 " "T9b missing helper exits 2"
cp "$DIR/anchor-handoff.sh" "$wt/scripts/cr/anchor-handoff.sh"

# 10. Every auto-allowed writer sources the helper as its first statement
# after `set -uo pipefail` — before it reads cwd, a .env or any other file.
for w in $WRITERS; do
    first=$(grep -v -E '^[[:space:]]*(#|$)' "$DIR/$w.sh" | sed -n 2p)
    check "$first" "$SOURCE_LINE" "T10 $w sources the hand-off first"
done

# 11-13 (HIMMEL-3437). A depth-3 entry (scripts/handover/console-kit/*.sh) —
# the source line points at ITS OWN sibling anchor-handoff.sh copy (the one
# generalizing this file no longer requires the two hardcoded scripts/cr/
# writers to be depth-2; real scripts/handover/*.sh sources scripts/cr/anchor-handoff.sh
# cross-directory instead, exercised separately by test-merge-on-green.sh /
# test-go.sh — this fixture just proves the resolver itself is depth-agnostic).
# shellcheck disable=SC2016  # the literal line each writer carries, not an expansion
D3_SOURCE_LINE='. "$(dirname "${BASH_SOURCE[0]}")/anchor-handoff.sh" || exit 2'
make_d3_tree() {  # <root> <label>
    mkdir -p "$1/scripts/handover/console-kit"
    git init -q "$1"
    cp "$DIR/anchor-handoff.sh" "$1/scripts/handover/console-kit/anchor-handoff.sh"
    printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\necho "RAN:%s"\n' "$D3_SOURCE_LINE" "$2" > "$1/scripts/handover/console-kit/go-stub.sh"
}
d3_anchor="$tmp/d3_anchor"; d3_wt="$tmp/d3_wt"
make_d3_tree "$d3_anchor" anchor
make_d3_tree "$d3_wt" branch
# 11. Relative entry three levels deep hands off to the anchor's copy.
check "$(run "$d3_wt" "$d3_anchor" scripts/handover/console-kit/go-stub.sh | tr '\n' ' ')" "RAN:anchor rc=0 " "T11 depth-3 relative entry hands off"
# 12. Absolute entry three levels deep still runs the local copy.
check "$(run "$d3_wt" "$d3_anchor" "$d3_wt/scripts/handover/console-kit/go-stub.sh" | tr '\n' ' ')" "RAN:branch rc=0 " "T12 depth-3 absolute entry runs local"
# 13. Relative entry three levels deep with HIMMEL_REPO unset fails closed.
check "$(run "$d3_wt" - scripts/handover/console-kit/go-stub.sh | tr '\n' ' ')" "rc=2 " "T13 depth-3 unset HIMMEL_REPO exits 2"

# 14 (HIMMEL-3437 F1). A worktree reached through a SYMLINKED path must still
# hand off. `_ah_dir` is built from plain `pwd` (logical, symlink-preserving)
# while `_ah_root` comes from `git rev-parse --show-toplevel` (physical,
# symlink-resolved) — when the entry cwd is a symlink these diverge, and the
# old string-subtraction (`${_ah_dir#"$_ah_root"/}`) left `_ah_rel` absolute
# instead of relative, breaking the hand-off.
real_wt="$tmp/real_wt"; link_wt="$tmp/link_wt"
make_tree "$real_wt" branch
ln -s "$real_wt" "$link_wt"
check "$(run "$link_wt" "$anchor" scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "RAN:anchor rc=0 " "T14 symlinked worktree still hands off (F1)"

# 15 (HIMMEL-3437 F2). A worktree nested INSIDE the anchor's own directory
# tree, whose own .git is corrupted (git rev-parse fails for a bad reason,
# not because it's a genuine non-git fixture), must fail closed rather than
# have the no-git walk-up fallback find the anchor as an ancestor and treat
# itself as already-the-anchor — that would run this copy's own (possibly
# tampered) bytes unchecked.
nested="$anchor/.claude/worktrees/nested_corrupt"
mkdir -p "$nested/scripts/cr"
cp "$DIR/anchor-handoff.sh" "$nested/scripts/cr/anchor-handoff.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\necho "RAN:corrupted"\n' "$SOURCE_LINE" > "$nested/scripts/cr/clear-cr-marker.sh"
echo "gitdir: /nonexistent/path" > "$nested/.git"
check "$(run "$nested" "$anchor" scripts/cr/clear-cr-marker.sh | tr '\n' ' ')" "rc=2 " "T15 corrupted nested worktree fails closed instead of self-anchoring (F2)"

echo "anchor-handoff: $pass passed, $([ "$fail" = 0 ] && echo 0 || echo some) failed"
exit "$fail"
