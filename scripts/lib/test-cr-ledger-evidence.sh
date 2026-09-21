#!/usr/bin/env bash
# Tests for cr_ledger_outside_dispositioned in scripts/lib/cr-ledger-evidence.sh
# (HIMMEL-3124). Hermetic: a throwaway git repo + ledger, no network, no gh.
#
# The positive fixture is written by the REAL scripts/cr/ledger-append.sh — the
# exact recipe check-ci.sh prints — so the writer->reader contract is exercised
# end to end. Every negative is a ONE-FIELD variant of that passing row (a
# blanket failure — missing ledger, no node — would make every negative pass
# vacuously; the positive control proves the fixture is otherwise accepted).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPEND="$SCRIPT_DIR/../cr/ledger-append.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cr-ledger-evidence.XXXXXX")" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
unset CR_LEDGER

REPO="$TMP/repo"
git init --quiet "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -m one --quiet --no-verify
H=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -m two --quiet --no-verify
H2=$(git -C "$REPO" rev-parse HEAD)
# H3: a commit that EXISTS but is not an ancestor of H2 (a side commit off H).
H3=$(git -C "$REPO" -c user.email=t@t -c user.name=t commit-tree "$H^{tree}" -p "$H" -m side)
LEDGER="$REPO/.git/cr-critic-scores.jsonl"

ID=cr-od-39c3193c8945
FILE=.pre-commit-config.yaml
LINE=459
# shellcheck disable=SC2016  # literal backticks (a real finding title), no expansion wanted
TITLE='Keep `context7-mcp` in the description-cap gate.'

pass=0; fail=0
# chk <name> <want-rc> <head> <id> <file> <line>
# chk <name> <want-rc> <head> <id> <file> <line> [current-head]
chk() {
    local name="$1" want="$2" head="$3" id="$4" file="$5" line="$6" cur="${7:-}" rc=0 out
    out=$(cd "$REPO" && . "$SCRIPT_DIR/cr-ledger-evidence.sh" \
        && cr_ledger_outside_dispositioned "$head" "$id" "$file" "$line" "$cur" 2>&1) || rc=$?
    if [ "$rc" = "$want" ]; then pass=$((pass+1)); echo "ok   $name"
    else fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want) out='$out'"; fi
}
# The recipe check-ci prints for a deferral (writer's own interface, no changes).
write_row() { # write_row <verdict> <deferred-to|""> <reason|""> [head]
    local args=(finding --branch feat/x --head "${4:-$H}" --model coderabbit-outside
        --id "$ID" --severity sug --file "$FILE" --line "$LINE" --text "$TITLE"
        --verdict "$1")
    [ -n "$2" ] && args+=(--deferred-to "$2")
    [ -n "$3" ] && args+=(--reason "$3")
    CR_LEDGER="$LEDGER" bash "$APPEND" "${args[@]}" >/dev/null 2>"$TMP/append.err" \
        || { echo "FATAL: ledger-append refused the fixture row: $(cat "$TMP/append.err")"; exit 1; }
}
# variant <jq-filter>: rewrite the single fixture row with ONE field changed.
variant() {
    local row; row=$(cat "$LEDGER")
    printf '%s\n' "$row" | jq -c "$1" > "$LEDGER.new" && mv "$LEDGER.new" "$LEDGER"
}
fresh() { : > "$LEDGER"; }
# add_line <raw>: add one hand-made line (the writer dedups and validates, so it
# cannot produce a corrupt or duplicate row). Rewrites via `>`; the ledger has a
# single append-site owner (ledger-append.sh) and /pr-check invariant 7 flags any
# other `>>` to it.
add_line() { { cat "$LEDGER"; printf '%s\n' "$1"; } > "$LEDGER.new" && mv "$LEDGER.new" "$LEDGER"; }

# --- positive controls: the fixture IS accepted --------------------------------
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
chk d1-deferred-tracked-with-reason-clears       0 "$H" "$ID" "$FILE" "$LINE"
fresh; write_row disproved "" "the exclusion is intentional"
chk d2-disproved-with-reason-clears              0 "$H" "$ID" "$FILE" "$LINE"

# --- one-field negatives of the passing deferred row ---------------------------
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
chk d3-different-line-not-cleared                1 "$H" "$ID" "$FILE" 460
chk d4-different-file-not-cleared                1 "$H" "$ID" other/file.yaml "$LINE"
chk d5-different-id-not-cleared                  1 "$H" cr-od-000000000000 "$FILE" "$LINE"
chk d6-row-at-other-head-not-cleared             1 "$H2" "$ID" "$FILE" "$LINE"
chk d6b-unrelated-head-string-not-cleared        1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$ID" "$FILE" "$LINE"
variant '.reason=""';                          chk d7-empty-reason-refused            1 "$H" "$ID" "$FILE" "$LINE"
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
variant '.reason="   "';                       chk d7b-whitespace-reason-refused      1 "$H" "$ID" "$FILE" "$LINE"
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
variant 'del(.deferred_to)';                   chk d8-deferred-without-ticket-refused 1 "$H" "$ID" "$FILE" "$LINE"
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
variant '.deferred_to="not-a-ticket"';         chk d8b-deferred-bad-ticket-refused    1 "$H" "$ID" "$FILE" "$LINE"
for v in fixed agreed unaddressed conflict; do
    fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
    variant ".verdict=\"$v\""
    chk "d9-verdict-$v-refused"                  1 "$H" "$ID" "$FILE" "$LINE"
done
fresh; write_row disproved "" "the exclusion is intentional"
variant '.reason=""';                          chk d10-disproved-empty-reason-refused 1 "$H" "$ID" "$FILE" "$LINE"

# --- HIMMEL-3360: `fixed` disposes a PRIOR-head finding, on evidence only -----
# The prior-head path (5th arg = the CURRENT head, which differs from the row's
# head) accepts verdict fixed when the reason names a sha that resolves, is an
# ancestor of (or is) the current head, and is not the prior head itself. The
# at-head path (no 5th arg, or current == head) never accepts fixed: a fix at
# the same head is impossible.
fresh; write_row fixed "" "fixed in $H2"
chk f1-fixed-ancestor-sha-clears-prior-head      0 "$H" "$ID" "$FILE" "$LINE" "$H2"
chk f2-fixed-at-head-path-still-refused          1 "$H" "$ID" "$FILE" "$LINE"
chk f2b-fixed-current-equals-head-refused        1 "$H" "$ID" "$FILE" "$LINE" "$H"
fresh; write_row fixed "" "fixed in $H3"
chk f3-fixed-non-ancestor-sha-refused            1 "$H" "$ID" "$FILE" "$LINE" "$H2"
fresh; write_row fixed "" "fixed"
chk f4-fixed-without-sha-refused                 1 "$H" "$ID" "$FILE" "$LINE" "$H2"
fresh; write_row fixed "" "fixed in deadbeefdeadbeef"
chk f5-fixed-unresolvable-sha-refused            1 "$H" "$ID" "$FILE" "$LINE" "$H2"
fresh; write_row fixed "" "fixed in $H"
chk f6-fixed-naming-the-prior-head-refused       1 "$H" "$ID" "$FILE" "$LINE" "$H2"
fresh; write_row fixed "" "fixed in ${H2:0:10}"
chk f7-fixed-abbreviated-ancestor-sha-clears     0 "$H" "$ID" "$FILE" "$LINE" "$H2"
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
chk f8-deferred-still-clears-on-prior-head-path  0 "$H" "$ID" "$FILE" "$LINE" "$H2"

# --- range line: the LINE is a literal token compared as a string --------------
fresh
CR_LEDGER="$LEDGER" bash "$APPEND" finding --branch feat/x --head "$H" --model coderabbit-outside \
    --id cr-od-2b1a31ba0692 --severity imp --file marketplace/plugins/himmel-ops/README.md --line 80-91 \
    --text x --verdict deferred --deferred-to HIMMEL-9001 --reason "tracked" >/dev/null 2>&1 \
    || { echo "FATAL: range-line fixture row refused"; exit 1; }
chk d11-range-line-string-match-clears           0 "$H" cr-od-2b1a31ba0692 marketplace/plugins/himmel-ops/README.md 80-91
chk d11b-range-start-only-not-cleared            1 "$H" cr-od-2b1a31ba0692 marketplace/plugins/himmel-ops/README.md 80

# --- gate integrity: the ledger path is FIXED, never env-overridable ----------
fresh                                          # the real ledger has NO row
FORGED="$TMP/forged.jsonl"
CR_LEDGER="$FORGED" bash "$APPEND" finding --branch feat/x --head "$H" --model coderabbit-outside \
    --id "$ID" --severity sug --file "$FILE" --line "$LINE" --text x --verdict deferred \
    --deferred-to HIMMEL-9001 --reason "forged" >/dev/null 2>&1
[ -s "$FORGED" ] || { echo "FATAL: forged ledger not written"; exit 1; }
CR_LEDGER="$FORGED" chk d12-env-pointed-forged-ledger-ignored 1 "$H" "$ID" "$FILE" "$LINE"
# ...and the same env var must not HIDE a real row either.
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
CR_LEDGER="$TMP/empty.jsonl" chk d12b-env-does-not-hide-real-row 0 "$H" "$ID" "$FILE" "$LINE"

# --- no silent inheritance: --set head= must not re-key a cr-od row -----------
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
CR_LEDGER="$LEDGER" bash "$APPEND" amend --head "$H" --id "$ID" --set "head=$H2" \
    --reason "re-key attempt" >/dev/null 2>"$TMP/amend.err" \
    || { echo "FATAL: amend --set head= refused: $(cat "$TMP/amend.err")"; exit 1; }
chk d13-amend-rekey-does-not-clear-new-head      1 "$H2" "$ID" "$FILE" "$LINE"
chk d13b-amend-rekey-keeps-original-head-bound   0 "$H"  "$ID" "$FILE" "$LINE"

# --- amends other than head still apply (the append-only correction path) -----
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
CR_LEDGER="$LEDGER" bash "$APPEND" amend --head "$H" --id "$ID" --set verdict=agreed \
    --reason "re-adjudicated: not deferrable" >/dev/null 2>"$TMP/amend.err" \
    || { echo "FATAL: amend --set verdict= refused: $(cat "$TMP/amend.err")"; exit 1; }
chk d14-amended-verdict-applies-and-refuses       1 "$H" "$ID" "$FILE" "$LINE"

# --- short (abbreviated) ledger head resolves through git, like the gate ------
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
variant ".head=\"${H:0:10}\""
chk d15-abbreviated-ledger-head-resolves         0 "$H" "$ID" "$FILE" "$LINE"

# --- fail closed on unreadable evidence ---------------------------------------
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
add_line 'not json at all'
chk d16-malformed-ledger-line-fails-closed       1 "$H" "$ID" "$FILE" "$LINE"
rm -f "$LEDGER"
chk d17-missing-ledger-fails-closed              1 "$H" "$ID" "$FILE" "$LINE"
fresh
chk d18-empty-ledger-no-disposition              1 "$H" "$ID" "$FILE" "$LINE"

# --- a second, non-disposing row for the same finding is not outvoted ---------
fresh; write_row deferred HIMMEL-9001 "pre-existing, tracked separately"
# (the writer dedups head+id, so a hand-made second row is the only way to get one)
add_line "$(jq -c '.verdict="unaddressed"' "$LEDGER")"
chk d19-later-undisposed-row-not-outvoted        1 "$H" "$ID" "$FILE" "$LINE"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
