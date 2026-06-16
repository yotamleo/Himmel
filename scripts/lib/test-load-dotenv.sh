#!/usr/bin/env bash
# Tests for scripts/lib/load-dotenv.sh (HIMMEL-335).
# Each case runs load_dotenv in its own $(...) subshell to isolate the
# exported env between cases — the subshell-scoped export is intentional.
# shellcheck disable=SC2030,SC2031
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/load-dotenv.sh"
# shellcheck source=load-dotenv.sh
# shellcheck disable=SC1091
. "$LIB"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init --quiet

# T1: sets a key that is currently unset.
printf 'HANDOVER_DIR=/c/some/path/handovers\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "T1 sets unset key" "/c/some/path/handovers" "$got"

# T2: a value already in the live env wins (??= semantics).
got=$( cd "$REPO" && export HANDOVER_DIR=/live/value && load_dotenv HANDOVER_DIR && printf '%s' "$HANDOVER_DIR" )
assert_eq "T2 live env wins" "/live/value" "$got"

# T3: missing .env → no-op, key stays unset, rc=0.
rm -f "$REPO/.env"
out=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR; rc=$?; printf '%s|%s' "${HANDOVER_DIR:-<unset>}" "$rc" )
assert_eq "T3 missing .env no-op" "<unset>|0" "$out"

# T4: CRLF-safe (trailing CR stripped from value).
printf 'HANDOVER_DIR=/c/crlf/path\r\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '[%s]' "$HANDOVER_DIR" )
assert_eq "T4 CRLF stripped" "[/c/crlf/path]" "$got"

# T5: comments / blanks / non-KV lines skipped; surrounding whitespace trimmed.
printf '# comment\n\nnot-a-kv-line\n  HANDOVER_DIR =  /c/spaced/path  \n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '[%s]' "$HANDOVER_DIR" )
assert_eq "T5 trims + skips noise" "[/c/spaced/path]" "$got"

# T6: first match wins on a duplicated key.
printf 'HANDOVER_DIR=/first\nHANDOVER_DIR=/second\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '%s' "$HANDOVER_DIR" )
assert_eq "T6 first match wins" "/first" "$got"

# T7: default keys (no args) load HANDOVER_DIR + USER_SLUG.
printf 'HANDOVER_DIR=/c/h\nUSER_SLUG=tester\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR USER_SLUG && load_dotenv && printf '%s|%s' "$HANDOVER_DIR" "$USER_SLUG" )
assert_eq "T7 default keys" "/c/h|tester" "$got"

# T8: only requested keys are loaded (others stay unset).
printf 'HANDOVER_DIR=/c/h\nOTHER_KEY=should-not-load\n' > "$REPO/.env"
got=$( cd "$REPO" && unset HANDOVER_DIR OTHER_KEY && load_dotenv HANDOVER_DIR && printf '%s|%s' "$HANDOVER_DIR" "${OTHER_KEY:-<unset>}" )
assert_eq "T8 only requested keys" "/c/h|<unset>" "$got"

# T9: from inside a git WORKTREE, the loader resolves the PRIMARY checkout's
# .env (the headline guarantee — a gitignored .env is never copied into a
# worktree, so git-common-dir resolution must reach back to the main repo).
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
git -C "$REPO" commit --allow-empty -q -m init
printf 'HANDOVER_DIR=/c/primary/handovers\n' > "$REPO/.env"
WT="$TMP/wt"
git -C "$REPO" worktree add -q "$WT" -b wt-branch
got=$( cd "$WT" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR && printf '%s' "${HANDOVER_DIR:-<unset>}" )
assert_eq "T9 worktree reads primary .env" "/c/primary/handovers" "$got"
git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true

# T10: outside any git repo, _load_dotenv_root falls back to the script-
# relative root and no-ops cleanly when no .env is found there (rc=0, no crash).
NONGIT="$TMP/nongit"
mkdir -p "$NONGIT"
out=$( cd "$NONGIT" && unset HANDOVER_DIR && load_dotenv HANDOVER_DIR; rc=$?; printf '%s|%s' "${HANDOVER_DIR:-<unset>}" "$rc" )
assert_eq "T10 git-absent fallback clean no-op" "<unset>|0" "$out"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All load-dotenv tests passed."
else
    echo "$FAILED load-dotenv test(s) failed."
    exit 1
fi
