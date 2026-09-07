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
# The fallback is SCRIPT-relative ("two levels up from this script"), so
# sourcing the real $LIB (as every other case does) makes this case resolve to
# the real repo root and read the operator's real .env — not the clean no-op
# it claims to test. Give this one case its own scratch tree with a COPY of
# load-dotenv.sh two levels down, so its script-relative fallback resolves to
# the scratch root instead of the real repo.
NONGIT="$TMP/nongit"
mkdir -p "$NONGIT/scripts/lib"
cp "$LIB" "$NONGIT/scripts/lib/load-dotenv.sh"
if [ -e "$NONGIT/.env" ]; then
    echo "FAIL T10 setup — scratch root unexpectedly has a .env"
    FAILED=$((FAILED + 1))
fi
# shellcheck disable=SC1091
out=$( cd "$NONGIT" && unset HANDOVER_DIR && . "$NONGIT/scripts/lib/load-dotenv.sh" && load_dotenv HANDOVER_DIR; rc=$?; printf '%s|%s' "${HANDOVER_DIR:-<unset>}" "$rc" )
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

# ── HIMMEL-1912: one-pass loader invariants ─────────────────────────────────

# T22 (HIMMEL-1922): an already-set EMPTY environment value counts as ABSENT,
# so the .env value loads over it. Every caller guards with `[ -z "${KEY-}" ]`,
# so a loader that treated set-empty as "already provided" loaded nothing and
# still returned 0 — the silent-failure class this family of tickets removes.
printf 'DOTENV_KEEP=from-file\n' > "$REPO/.env"
got=$( cd "$REPO" && export DOTENV_KEEP= && load_dotenv DOTENV_KEEP && printf '<%s>' "$DOTENV_KEEP" )
assert_eq "T22 set-empty env is filled from .env" "<from-file>" "$got"

# T22b (HIMMEL-1922): the other half of the same rule — a live NON-EMPTY value
# still wins over .env. Without this, T22 alone would also pass a loader that
# clobbered unconditionally.
printf 'DOTENV_KEEP=from-file\n' > "$REPO/.env"
got=$( cd "$REPO" && export DOTENV_KEEP=live && load_dotenv DOTENV_KEEP && printf '<%s>' "$DOTENV_KEEP" )
assert_eq "T22b live non-empty env is not clobbered" "<live>" "$got"

# T23: matching is anchored to the complete key; XKEY must not satisfy KEY.
printf 'XDOTENV_ANCHOR=decoy\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_ANCHOR && load_dotenv DOTENV_ANCHOR && printf '%s' "${DOTENV_ANCHOR:-<unset>}" )
assert_eq "T23 key match is anchored" "<unset>" "$got"

# T24: first match wins even when its value is empty.
printf 'DOTENV_DUP=\nDOTENV_DUP=second\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_DUP && load_dotenv DOTENV_DUP && printf '<%s>' "$DOTENV_DUP" )
assert_eq "T24 empty first duplicate wins" "<>" "$got"

# T25: reject constructs unavailable in macOS's Bash 3.2.
incompatible=$(grep -En '(^|[[:space:]])(declare|local)[[:space:]]+-A|(^|[[:space:]])(mapfile|readarray)([[:space:]]|$)|\$\{[^}]*(\^\^|,,)|\[\[[^]]*[[:space:]]-v[[:space:]]' "$LIB" || true)
assert_eq "T25 Bash 3.2-compatible constructs" "" "$incompatible"

# T26: an explicitly selected root with no .env fails open, silently, with rc 0.
MISSING_ROOT="$TMP/missing-explicit-root"
mkdir -p "$MISSING_ROOT"
out=$( cd "$NONGIT" && unset DOTENV_MISSING && load_dotenv --root "$MISSING_ROOT" DOTENV_MISSING; rc=$?; printf '%s|%s' "${DOTENV_MISSING:-<unset>}" "$rc" )
assert_eq "T26 missing .env fails open" "<unset>|0" "$out"

# T27: requested keys that match load_dotenv's own local names still load.
printf 'root=ROOTVAL\nkeys=KEYSVAL\nenvfile=ENVFILEVAL\nkey=KEYVAL\nline=LINEVAL\nval=VALVAL\npending=PENDINGVAL\nDOTENV_LOCAL_CONTROL=CONTROLVAL\n' > "$REPO/.env"
got=$( cd "$REPO" && unset root keys envfile key line val pending DOTENV_LOCAL_CONTROL && load_dotenv root keys envfile key line val pending DOTENV_LOCAL_CONTROL && printf '%s|%s|%s|%s|%s|%s|%s|%s' "${root:-<unset>}" "${keys:-<unset>}" "${envfile:-<unset>}" "${key:-<unset>}" "${line:-<unset>}" "${val:-<unset>}" "${pending:-<unset>}" "${DOTENV_LOCAL_CONTROL:-<unset>}" )
assert_eq "T27 local-name keys load" "ROOTVAL|KEYSVAL|ENVFILEVAL|KEYVAL|LINEVAL|VALVAL|PENDINGVAL|CONTROLVAL" "$got"

# T28 (HIMMEL-2462): an unquoted trailing ` #…` comment is stripped. The fixture
# line is `.env.example`'s JIRA_PROJECT_KEY verbatim — the one the commit-msg
# gate builds its ticket pattern from. Before this, every machine installed from
# .env.example ran the gate with the pattern
# `HIMMEL   # default project for jira ops-[0-9]+`, which nothing can match.
printf 'JIRA_PROJECT_KEY=HIMMEL                            # default project for jira ops\n' > "$REPO/.env"
got=$( cd "$REPO" && unset JIRA_PROJECT_KEY && load_dotenv JIRA_PROJECT_KEY && printf '<%s>' "$JIRA_PROJECT_KEY" )
assert_eq "T28 inline comment is stripped (.env.example:64 verbatim)" "<HIMMEL>" "$got"

# T28b: a single space before the `#` is enough — the comment marker is
# whitespace-then-hash, not a wide gutter.
printf 'DOTENV_C1=value #comment\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_C1 && load_dotenv DOTENV_C1 && printf '<%s>' "$DOTENV_C1" )
assert_eq "T28b one space before # is a comment" "<value>" "$got"

# T29 NEGATIVE CONTROL: an UNSPACED `#` is part of the value, not a comment —
# the dotenv convention, and the reason a URL fragment survives. Without this
# case a loader that stripped from the first `#` anywhere would pass T28.
printf 'DOTENV_URL=http://x/#frag\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_URL && load_dotenv DOTENV_URL && printf '<%s>' "$DOTENV_URL" )
assert_eq "T29 unspaced # stays in the value" "<http://x/#frag>" "$got"

# T29b NEGATIVE CONTROL: a `#` inside quotes is data even with a space before it.
# The surrounding quotes are NOT stripped — that is pre-existing behaviour this
# change deliberately leaves alone (HIMMEL-1493 covers quote handling).
printf 'DOTENV_TOKEN="abc #def"\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_TOKEN && load_dotenv DOTENV_TOKEN && printf '<%s>' "$DOTENV_TOKEN" )
assert_eq "T29b quoted # is data" '<"abc #def">' "$got"

# T29c: a comment AFTER a quoted value is still a comment.
printf "DOTENV_QC='a b' # trailing note\n" > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_QC && load_dotenv DOTENV_QC && printf '<%s>' "$DOTENV_QC" )
assert_eq "T29c comment after a quoted value is stripped" "<'a b'>" "$got"

# T29d: an unterminated quote keeps the whole remainder — never guess where a
# broken value ends.
printf 'DOTENV_UQ="abc # def\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_UQ && load_dotenv DOTENV_UQ && printf '<%s>' "$DOTENV_UQ" )
assert_eq "T29d unterminated quote keeps the remainder" '<"abc # def>' "$got"

# T30: a comment-free value is byte-identical to before — the change must be
# invisible to every key that carries no `#`.
printf 'DOTENV_PLAIN=a b  c\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_PLAIN && load_dotenv DOTENV_PLAIN && printf '<%s>' "$DOTENV_PLAIN" )
assert_eq "T30 comment-free value is unchanged" "<a b  c>" "$got"

# T30b: a value that is ENTIRELY a comment resolves to empty rather than to the
# comment text.
printf 'DOTENV_ONLYC=  # nothing here\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_ONLYC && load_dotenv DOTENV_ONLYC && printf '<%s>' "$DOTENV_ONLYC" )
assert_eq "T30b comment-only value is empty" "<>" "$got"

# T31 (codex-2): an apostrophe in an UNQUOTED value is DATA, not a quote open —
# a value is quoted only when it BEGINS with a quote. Without this rule the
# apostrophe opened quote-mode and never closed, so the trailing comment was
# never stripped.
printf "DOTENV_APOS=don't # note\n" > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_APOS && load_dotenv DOTENV_APOS && printf '<%s>' "$DOTENV_APOS" )
assert_eq "T31 apostrophe in unquoted value is data, comment still stripped" "<don't>" "$got"

# T32 (codex-2): a backslash-escaped quote inside a quoted value does NOT close
# it, so the `#` after it stays inside the (still-open) quote and the value is
# kept WHOLE. Before this fix the escaped quote was read as the close and the
# value was truncated — data loss on a secret-bearing path.
printf 'DOTENV_ESCQ="abc \\" # data"\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_ESCQ && load_dotenv DOTENV_ESCQ && printf '<%s>' "$DOTENV_ESCQ" )
assert_eq 'T32 escaped quote does not close, value kept whole' '<"abc \" # data">' "$got"

# T33: a comment after a properly CLOSED quoted value is still stripped — the
# positive control paired with T32 (an escape must not disable stripping
# generally, only for a genuinely escaped quote).
printf 'DOTENV_QCOM="abc" # note\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_QCOM && load_dotenv DOTENV_QCOM && printf '<%s>' "$DOTENV_QCOM" )
assert_eq 'T33 comment after a closed quoted value is stripped' '<"abc">' "$got"

# T34: leading whitespace before the opening quote is skipped before the
# quote-start check runs — an inner `#` stays data (still inside the quote)
# and the trailing comment after the quote closes is still stripped.
printf 'DOTENV_LWSQ=   "abc # def" # trail\n' > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_LWSQ && load_dotenv DOTENV_LWSQ && printf '<%s>' "$DOTENV_LWSQ" )
assert_eq "T34 leading whitespace before opening quote is skipped" '<"abc # def">' "$got"

# T35 (codex, round 3): inside a SINGLE-quoted value a backslash is a LITERAL
# character, not an escape — shell/dotenv convention. A trailing-backslash
# Windows path like 'C:\' must still close on the real closing quote; escaping
# applies only inside DOUBLE quotes (T32). Built via an intermediate variable
# so bash's own quote parsing (not printf's format-string escapes) produces
# the literal backslash.
bsq_line="DOTENV_BSQ='C:\\' # note"
printf '%s\n' "$bsq_line" > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_BSQ && load_dotenv DOTENV_BSQ && printf '<%s>' "$DOTENV_BSQ" )
assert_eq "T35 single-quoted trailing backslash is literal, comment stripped" "<'C:\\'>" "$got"

# T36: a backslash NOT at the end of a single-quoted value is data too.
bsq_line="DOTENV_BSQ2='a\\b' # note"
printf '%s\n' "$bsq_line" > "$REPO/.env"
got=$( cd "$REPO" && unset DOTENV_BSQ2 && load_dotenv DOTENV_BSQ2 && printf '<%s>' "$DOTENV_BSQ2" )
assert_eq "T36 single-quoted mid-value backslash is literal" "<'a\\b'>" "$got"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All load-dotenv tests passed."
else
    echo "$FAILED load-dotenv test(s) failed."
    exit 1
fi
