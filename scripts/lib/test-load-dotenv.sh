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

# ── --root mode (HIMMEL-460): explicit root, CWD git resolution bypassed ─────
ROOTDIR="$TMP/explicit-root"
mkdir -p "$ROOTDIR"
printf 'HIMMEL_INITIATIVE=prcheck,pr\n' > "$ROOTDIR/.env"

# T11: --root loads <dir>/.env regardless of CWD.
got=$( cd "$NONGIT" && unset HIMMEL_INITIATIVE && load_dotenv --root "$ROOTDIR" HIMMEL_INITIATIVE && printf '%s' "${HIMMEL_INITIATIVE:-<unset>}" )
assert_eq "T11 --root loads its .env" "prcheck,pr" "$got"

# T12: --root NEVER reads the CWD repo's .env (the CWD-safety guarantee). Launch
# from inside a DECOY git repo whose .env sets a different value; --root must win.
DECOY="$TMP/decoy"; mkdir -p "$DECOY"; git -C "$DECOY" init --quiet
printf 'HIMMEL_INITIATIVE=DECOY_VALUE\n' > "$DECOY/.env"
got=$( cd "$DECOY" && unset HIMMEL_INITIATIVE && load_dotenv --root "$ROOTDIR" HIMMEL_INITIATIVE && printf '%s' "$HIMMEL_INITIATIVE" )
assert_eq "T12 --root ignores CWD repo .env" "prcheck,pr" "$got"

# T13: --root is still non-clobbering (process env wins).
got=$( cd "$NONGIT" && export HIMMEL_INITIATIVE=live && load_dotenv --root "$ROOTDIR" HIMMEL_INITIATIVE && printf '%s' "$HIMMEL_INITIATIVE" )
assert_eq "T13 --root non-clobbering" "live" "$got"

# T14: --root pointing at a dir with no .env → clean no-op, rc=0.
out=$( cd "$NONGIT" && unset HIMMEL_INITIATIVE && load_dotenv --root "$NONGIT" HIMMEL_INITIATIVE; rc=$?; printf '%s|%s' "${HIMMEL_INITIATIVE:-<unset>}" "$rc" )
assert_eq "T14 --root no .env no-op" "<unset>|0" "$out"

# ── _load_dotenv_primary_for (HIMMEL-1482): primary-checkout fallback for a ───
# pinned --root — the claude-codex path. A launcher invoked from a worktree copy
# of itself has <parent> = worktree root (no .env); the helper resolves the
# primary and reads .env there. canonicalize() compares paths by their resolved
# form (avoids macOS /tmp → /private/tmp and drive-form mismatches).
canon() { ( cd "$1" 2>/dev/null && pwd ); }
PFREPO="$TMP/pf-repo"; mkdir -p "$PFREPO"; git -C "$PFREPO" init --quiet
git -C "$PFREPO" config user.email t@example.com
git -C "$PFREPO" config user.name tester
git -C "$PFREPO" commit --allow-empty -q -m init
printf 'CLIPROXY_API_KEY=pk-from-primary\n' > "$PFREPO/.env"   # gitleaks:allow
PFWT="$TMP/pf-wt"
git -C "$PFREPO" worktree add -q "$PFWT" -b pf-branch

# T15: candidate is a linked worktree with NO .env → resolves the PRIMARY (which
# has .env), and emits exactly ONE advisory line to stderr.
root=$( _load_dotenv_primary_for "$PFWT" 2>/dev/null )
assert_eq "T15 worktree → primary root" "$(canon "$PFREPO")" "$(canon "$root")"
adv=$( _load_dotenv_primary_for "$PFWT" 2>&1 1>/dev/null )
case "$adv" in *"reading the primary checkout's .env"*) echo "PASS T15 advisory emitted" ;; *) echo "FAIL T15 advisory — got: $adv"; FAILED=$((FAILED + 1)) ;; esac

# T16: candidate is the primary (has .env) → returned unchanged, NO advisory.
assert_eq "T16 primary unchanged" "$(canon "$PFREPO")" "$(canon "$(_load_dotenv_primary_for "$PFREPO" 2>/dev/null)")"
adv=$( _load_dotenv_primary_for "$PFREPO" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T16 no advisory on primary"; else echo "FAIL T16 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi

# T17: both missing (worktree AND primary have no .env) → returns the candidate
# unchanged, NO advisory (the caller's missing-.env path applies — load_dotenv
# no-ops, the key stays unset, the launcher's own error message surfaces).
rm -f "$PFREPO/.env"
root=$( _load_dotenv_primary_for "$PFWT" 2>/dev/null )
assert_eq "T17 both-missing returns candidate" "$(canon "$PFWT")" "$(canon "$root")"
adv=$( _load_dotenv_primary_for "$PFWT" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T17 no advisory on both-missing"; else echo "FAIL T17 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi
printf 'CLIPROXY_API_KEY=pk-from-primary\n' > "$PFREPO/.env"   # gitleaks:allow  (restore for T18)

# T18: integration — load_dotenv --root <helper-resolved worktree> finds the key
# in the PRIMARY .env (exactly what claude-codex does). Run from the worktree's
# own cwd to prove --root + helper reaches the primary regardless of CWD.
got=$( cd "$PFWT" && unset CLIPROXY_API_KEY && load_dotenv --root "$(_load_dotenv_primary_for "$PFWT")" CLIPROXY_API_KEY && printf '%s' "${CLIPROXY_API_KEY:-<unset>}" )
assert_eq "T18 load_dotenv via helper finds primary key" "pk-from-primary" "$got"

# T19: a non-git candidate dir → returned unchanged (git fails, no fallback, no
# advisory) — hermetic tests that pin the root to a temp dir are unaffected.
PFNONGIT="$TMP/pf-nongit"; mkdir -p "$PFNONGIT"
assert_eq "T19 non-git returns candidate" "$(canon "$PFNONGIT")" "$(canon "$(_load_dotenv_primary_for "$PFNONGIT" 2>/dev/null)")"
adv=$( _load_dotenv_primary_for "$PFNONGIT" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T19 no advisory on non-git"; else echo "FAIL T19 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi

# T20 (HIMMEL-1482 R2): a NESTED dir INSIDE a worktree (NOT the worktree root)
# must NOT read the primary .env. A hermetically pinned root like
# <worktree>/scripts resolves common-dir to the real .git and (under r1) differed
# from the candidate → silently loaded the operator's .env. The candidate is not
# the checkout root, so the fallback must NOT fire (primary .env still present).
PFWTNEST="$PFWT/nested"; mkdir -p "$PFWTNEST"
root=$( _load_dotenv_primary_for "$PFWTNEST" 2>/dev/null )
assert_eq "T20 nested-in-worktree returns candidate" "$(canon "$PFWTNEST")" "$(canon "$root")"
adv=$( _load_dotenv_primary_for "$PFWTNEST" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T20 no advisory on nested-in-worktree"; else echo "FAIL T20 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi

# T21 (HIMMEL-1482 R2): a NESTED dir INSIDE the primary checkout must NOT fall
# back either — git-dir == git-common-dir here (primary checkout), so there is no
# linked worktree to fall back from, and the candidate is not the toplevel.
PFPRIMNEST="$PFREPO/nested"; mkdir -p "$PFPRIMNEST"
root=$( _load_dotenv_primary_for "$PFPRIMNEST" 2>/dev/null )
assert_eq "T21 nested-in-primary returns candidate" "$(canon "$PFPRIMNEST")" "$(canon "$root")"
adv=$( _load_dotenv_primary_for "$PFPRIMNEST" 2>&1 1>/dev/null )
if [ -z "$adv" ]; then echo "PASS T21 no advisory on nested-in-primary"; else echo "FAIL T21 advisory leaked: $adv"; FAILED=$((FAILED + 1)); fi

git -C "$PFREPO" worktree remove --force "$PFWT" 2>/dev/null || true

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All load-dotenv tests passed."
else
    echo "$FAILED load-dotenv test(s) failed."
    exit 1
fi
