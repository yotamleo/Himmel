#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# test-console-cmd-resolution.sh -- plugin /console from any repo. The
# himmel-ops plugin's console.md carries an embedded REPO-resolution snippet
# (modeled on himmel-update.md's, HIMMEL-459) so it runs from ANY directory
# ($HIMMEL_REPO -> git toplevel -> canonical install path -> error), then
# passes the session's own cwd to console.sh as --project. This test
# EXTRACTS that snippet from the command file (single source of truth, so
# the test can't drift from the prose) and exercises every branch, plus
# asserts the run line's flag order. bash-only (the snippet is bash inside
# the command; no .ps1 twin). Needs git.
# HIMMEL_REPO is never exported globally here (only via per-call env prefix)
# so the unset-cases see it genuinely absent.
set -u
unset HIMMEL_REPO 2>/dev/null || true
here="$(cd "$(dirname "$0")" && pwd)"
cmd="$here/../commands/console.md"
[ -f "$cmd" ] || { echo "FATAL: $cmd not found"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required for the git-toplevel case"; exit 2; }
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# Extract the resolver: from the `REPO="...` line through the ERR-guard line.
snippet="$(awk '/^REPO="/{f=1} f{print} /cannot locate himmel checkout/{exit}' "$cmd")"
[ -n "$snippet" ] || { echo "FATAL: could not extract resolver snippet from $cmd"; exit 2; }

# Run the snippet in a subshell under the caller's env/CWD; echo the resolved
# REPO (empty when the snippet errored + exited non-zero). HIMMEL_REPO / HOME
# are supplied by the caller via an env prefix on the run_resolver call.
run_resolver(){ ( eval "$snippet" && printf '%s' "$REPO" ) 2>/dev/null; }

td="$(mktemp -d "${TMPDIR:-/tmp}/console-cmd-res.XXXXXX")" ||{ echo "FATAL: mktemp -d failed"; exit 2; }
trap 'rm -rf "$td"' EXIT
empty_home="$td/empty-home"; mkdir -p "$empty_home"   # no canonical himmel here

# A fake clone that contains the sentinel script (for the HIMMEL_REPO case).
clone="$td/clone-himmel"; mkdir -p "$clone/scripts/handover/console"; : > "$clone/scripts/handover/console/console.sh"

# (i) HIMMEL_REPO set, CWD outside any repo -> resolves to the clone.
got="$( cd "$td" && HIMMEL_REPO="$clone" HOME="$empty_home" run_resolver )"
check "(i) HIMMEL_REPO from arbitrary dir" "$clone" "$got"

# (ii) HIMMEL_REPO unset, CWD inside a FOREIGN repo shipping its own
#      scripts/handover/console/console.sh, no canonical himmel present ->
#      the resolver must refuse, never run the foreign script just because
#      the cwd's git toplevel has one (HIMMEL-3623 verdict J1268O change 5,
#      F6 -- this is the vulnerability the fix closes).
gitclone="$td/gitclone"; mkdir -p "$gitclone/scripts/handover/console"
git init -q "$gitclone"; : > "$gitclone/scripts/handover/console/console.sh"
got="$( cd "$gitclone" && HOME="$empty_home" run_resolver )"; rc=$?
check "(ii) foreign repo's own console.sh never wins (errored)" "" "$got"
check "(ii) foreign repo's own console.sh never wins (non-zero exit)" "nonzero" "$( [ "$rc" -ne 0 ] && echo nonzero || echo zero )"

# (iii) neither HIMMEL_REPO nor a git repo nor a canonical himmel -> clear error.
# Empty stdout alone doesn't prove the snippet errored (a genuinely empty REPO
# would print empty too) -- assert the subshell's exit status is non-zero as
# well (HIMMEL-3623 verdict J1268O change 8, F9).
got="$( cd "$td" && HOME="$empty_home" run_resolver )"; rc=$?
check "(iii) none -> empty (errored)" "" "$got"
check "(iii) none -> non-zero exit" "nonzero" "$( [ "$rc" -ne 0 ] && echo nonzero || echo zero )"

# (iv) canonical default: HIMMEL_REPO unset, non-git CWD, himmel at the canonical
#      $HOME/Himmel path (console.md's own extra candidate over himmel-update.md's
#      list) -> resolves there.
canon_home="$td/canon-home"
canon="$canon_home/Himmel"; mkdir -p "$canon/scripts/handover/console"; : > "$canon/scripts/handover/console/console.sh"
got="$( cd "$td" && HOME="$canon_home" run_resolver )"
check "(iv) canonical default install path (\$HOME/Himmel)" "$canon" "$got"

# (iv-b) canonical himmel present AND cwd is a foreign repo with its own
#        console.sh -> the canonical install wins, the foreign toplevel is
#        never even considered (change 5, F6, stronger form of (ii)).
got="$( cd "$gitclone" && HOME="$canon_home" run_resolver )"
check "(iv-b) canonical install wins over a foreign repo's own console.sh" "$canon" "$got"

# (v) HIMMEL_REPO SET but STALE (points at a dir lacking the script): the `-f`
#     re-check on the resolver's 2nd line must fall through to the canonical
#     install candidates, NEVER to the cwd's git toplevel even when that
#     toplevel ships its own console.sh (change 5, F6).
bogus="$td/bogus"; mkdir -p "$bogus"   # no scripts/handover/console/console.sh inside
got="$( cd "$gitclone" && HIMMEL_REPO="$bogus" HOME="$canon_home" run_resolver )"
check "(v) stale HIMMEL_REPO -> canonical install, not the foreign git toplevel" "$canon" "$got"

# The run line that appends the derived --project must pass it AFTER
# $ARGUMENTS -- console.sh's first positional is the subcommand (new|next),
# which is INSIDE $ARGUMENTS, so --project has to come after it, not before.
run_line="$(grep -n 'console.sh" \$ARGUMENTS' "$cmd")"
[ -n "$run_line" ] || { echo "FAIL - run line: console.sh\" \$ARGUMENTS not found in $cmd"; fails=$((fails+1)); }
check "run line: --project comes after \$ARGUMENTS" \
    "$(printf '%s\n' "$run_line" | grep -c -- '\$ARGUMENTS --project "\$PROJECT"')" "1"

# codex-1 (pr-check round 2, HIMMEL-3623): a `new` whose own $ARGUMENTS
# already carries a --project must NOT also get the derived one appended --
# console.sh keeps the LAST --project, so appending unconditionally always
# clobbered an operator's own explicit --project on `new`. Assert the guard
# branch exists AND that it never itself appends the derived --project.
check "codex-1: a *--project* guard branch exists on new" \
    "$(grep -c -- '\*--project\*)' "$cmd")" "1"
check "codex-1: the *--project* new branch never appends the derived --project" \
    "$(printf '%s\n' "$run_line" | grep -c -- '\*--project\*.*--project "\$PROJECT"')" "0"

# codex-2 (pr-check round 2, HIMMEL-3623): no dispatch line may `cd "$REPO"`
# before expanding $ARGUMENTS -- that resolved any relative --doc/--project
# the operator passed against the himmel checkout instead of their own cwd.
check "codex-2: no cd \"\$REPO\" before dispatching console.sh" \
    "$(grep -v '^\s*#' "$cmd" | grep -c 'cd "\$REPO"')" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
