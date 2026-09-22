#!/usr/bin/env bash
# Tests for scripts/cr/anchor-handoff.sh (HIMMEL-3395): a gate writer entered
# by a RELATIVE path from a non-anchor tree runs the anchor's copy; an
# absolute entry runs the local copy; the relative door fails closed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WRITERS="write-verdicts clear-cr-marker panel-first-pass docs-audit-panel codex-adv-kickoff codex-adv-harvest doc-freshness-advisory known-findings ledger-append"
# shellcheck disable=SC2016  # the literal line each writer carries, not an expansion
SOURCE_LINE='."$(dirname "${BASH_SOURCE[0]}")/anchor-handoff.sh"'

fail=0
pass=0
check() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else echo "FAIL: $3 — got '$1' want '$2'"; fail=1; fi; }

tmp="$(mktemp -d -t anchor-handoff.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# A tree holding the helper and a writer that is the real one up to (and
# including) its hand-off line, then a line naming which copy ran. Before the
# writer sources the helper, the whole head is just `set -uo pipefail`, so the
# local copy runs — the RED state.
make_tree() {  # <root> <label>
    mkdir -p "$1/scripts/cr"
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
# 9. Arguments survive the hand-off.
printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\necho "ARGS:$*"\n' "$SOURCE_LINE" > "$anchor/scripts/cr/known-findings.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\necho "LOCAL"\n' "$SOURCE_LINE" > "$wt/scripts/cr/known-findings.sh"
check "$(cd "$wt" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$anchor" bash scripts/cr/known-findings.sh --diff 'a b' 2>/dev/null)" "ARGS:--diff a b" "T9 args forwarded"

# 10. Every auto-allowed writer sources the helper as its first statement
# after `set -uo pipefail` — before it reads cwd, a .env or any other file.
for w in $WRITERS; do
    first=$(grep -v -E '^[[:space:]]*(#|$)' "$DIR/$w.sh" | sed -n 2p)
    check "$first" "$SOURCE_LINE" "T10 $w sources the hand-off first"
done

echo "anchor-handoff: $pass passed, $([ "$fail" = 0 ] && echo 0 || echo some) failed"
exit "$fail"
