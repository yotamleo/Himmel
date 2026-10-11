#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# Hermetic test for scripts/cr/impacted-suites.sh (HIMMEL-2821). Builds a
# throwaway repo shaped like PR #2261: a changed script (uninstall-plugins.sh)
# whose end-to-end suite (test-uninstall.sh) lives one directory UP and that
# neither a directory sweep nor "the owning suites" prose would have reached.
#
# Platform guard: POSIX bash 3.2+; runs under Git Bash on Windows too.
#
# Usage: bash scripts/cr/test-impacted-suites.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# grepq <text> [grep-args...] — `grep -q` with no pipeline (pipefail SIGPIPE
# trap, HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
IS="$REPO_ROOT/scripts/cr/impacted-suites.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

if [ ! -f "$IS" ]; then
    fail "impacted-suites.sh not found at $IS"
    echo "FAIL: $failures case(s) failed"
    exit 1
fi

# SHD is first assigned in row 36b but named in the EXIT traps of rows 36/36a; declared
# here so an early exit cannot abort that cleanup on an unbound variable (HIMMEL-5189).
SHD=""
FX="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX"' EXIT

# --- fixture repo ---------------------------------------------------------
mkf() { mkdir -p "$FX/$(dirname "$1")"; printf '%s\n' "${2:-# $1}" > "$FX/$1"; }
(
    fixture_enter_git_init_dir "$FX" || exit 1
    git init -q
    git config user.email t@e
    git config user.name t
)
mkf scripts/machine-setup/uninstall-plugins.sh
mkf scripts/machine-setup/install.sh
mkf scripts/uninstall.sh
mkf scripts/test-uninstall.sh 'bash "$d/machine-setup/uninstall-plugins.sh"; bash "$d/uninstall.sh"'
mkf scripts/test-other.sh 'bash "$d/uninstall.sh"'
mkf scripts/test-wrapper.sh 'bash "$d/test-other.sh"'
mkf scripts/test-installer.sh 'bash "$d/machine-setup/install.sh"'
mkf scripts/lanes/tests/plugins.test.mjs "// drives uninstall-plugins.sh"
mkf .claude/commands/pr-check.md
mkf scripts/test-cmd.sh 'grep -q "/pr-check" x'
mkf scripts/test-clean-cmd.sh 'grep -q "/pr-check_extra" x'
mkf docs/foo/README.md
mkf scripts/test-readme-foo.sh 'grep -q foo/README.md x'
mkf scripts/test-readme-bare.sh 'grep -q README.md x'
mkf package.json '{}'
mkf scripts/test-pkg.sh 'grep -q "$root/package.json" x'
mkf scripts/eval/guard-corpus/diff
mkf scripts/test-diff-word.sh 'diff -u a b'
mkf scripts/test-guard-corpus.sh 'bash "$d/eval/guard-corpus/diff"'
mkf scripts/test-diff-fullpath.sh 'bash scripts/eval/guard-corpus/diff'
mkf scripts/test-diff-var.sh 'DIFF="$HERE/diff"'
mkf scripts/claude-fake
mkf scripts/test-claude-fake.sh "launcher=path.join(scripts,'claude-fake')"
mkf scripts/test-diff-source.sh 'cd eval/guard-corpus && source diff'
mkf scripts/test-diff-dot.sh 'cd eval/guard-corpus && . "diff"'
mkf scripts/test-diff-directive.sh '# shellcheck source=diff'
mkf scripts/test-diff-dashdash.sh 'cd eval/guard-corpus && source -- diff'
mkf scripts/q/'we"ird.sh'
mkf scripts/test-q-dquote.sh 'bash "$d/q/we"ird.sh'
mkf scripts/q/'back\slash.sh'
mkf scripts/test-q-backslash.sh 'bash "$d/q/back\slash.sh"'
mkf scripts/q/$'ta\tb.sh'
mkf scripts/test-q-tab.sh $'bash "$d/q/ta\tb.sh"'
mkf scripts/test-diff-plain.sh 'cd eval/guard-corpus && diff a b'
mkf scripts/test-diff-prose.sh '# the source diff is shown below'
mkf scripts/diff-helper.sh 'cd eval/guard-corpus && source diff'
mkf scripts/test-diff-helper.sh 'bash "$d/diff-helper.sh"'
mkf scripts/hooks/block-foo-guard.sh
mkf scripts/test-stem-ext.sh 'guard_rc block-foo-guard "x"'
mkf scripts/test-stem-longer.sh 'guard_rc block-foo-guard-extra "x"'
mkf scripts/test-stem-dotted.sh 'x=block-foo-guard.bak'
mkf scripts/lib/my_helper.sh
mkf scripts/test-stem-underscore.sh 'use my_helper here'
mkf scripts/hooks/gate.sh
mkf scripts/test-stem-word.sh 'open the gate now'
mkf scripts/test-stem-gate-full.sh 'bash scripts/hooks/gate.sh'
mkf scripts/test-stem-lead.sh 'guard_rc x-block-foo-guard "x"'
mkf scripts/hooks/a+b-c.sh
mkf scripts/test-stem-plus.sh 'guard_rc a+b-c "x"'
mkf scripts/test-stem-plus-wild.sh 'guard_rc aab-c "x"'
mkf scripts/lib/clo-lib.sh
mkf scripts/hooks/block-clo-hook.sh 'source "$d/lib/clo-lib.sh"'
mkf scripts/test-clo-stem.sh 'guard_rc block-clo-hook "x"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: base"

# change <file> — append a line to <file>, commit, set $range to that commit.
change() {
    printf '# changed\n' >> "$FX/$1"
    git -C "$FX" add -A
    git -C "$FX" commit -q -m "fix: change $1"
    range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
}
run_is() { ( cd "$FX" && bash "$IS" "$@" 2>/dev/null ); }

# --- 1. the #2261 shape: the far-away end-to-end suite is listed -----------
change scripts/machine-setup/uninstall-plugins.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "uninstall-plugins.sh -> scripts/test-uninstall.sh (one dir up)"; else fail "test-uninstall.sh not listed: $out"; fi
if grepq "$out" '^scripts/lanes/tests/plugins\.test\.mjs$'; then pass ".test.mjs suite listed"; else fail "mjs suite not listed: $out"; fi
if ! grepq "$out" 'test-other\.sh'; then pass "suite naming only uninstall.sh is not listed"; else fail "test-other.sh listed for an uninstall-plugins.sh change: $out"; fi
out="$(run_is "$range" --shell)"
if ! grepq "$out" '\.mjs$' && grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "--shell keeps only test-*.sh"; else fail "--shell output wrong: $out"; fi

# --- 2. word boundary: install.sh must not match uninstall.sh ---------------
change scripts/machine-setup/install.sh
out="$(run_is "$range")"
if [ "$out" = "scripts/test-installer.sh" ]; then pass "install.sh change lists only its own suite (not uninstall.sh mentions)"; else fail "install.sh boundary: $out"; fi

# --- 3. command form: /pr-check, and /pr-check_extra is a different word -----
change .claude/commands/pr-check.md
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-cmd\.sh$'; then pass "commands/pr-check.md -> suite naming /pr-check"; else fail "/pr-check suite not listed: $out"; fi
if ! grepq "$out" 'test-clean-cmd\.sh'; then pass "/pr-check_extra is not /pr-check"; else fail "boundary broke on /pr-check_extra: $out"; fi

# --- 4. generic basename (README.md) needs its parent dir --------------------
change docs/foo/README.md
out="$(run_is "$range")"
if [ "$out" = "scripts/test-readme-foo.sh" ]; then pass "README.md matched via foo/README.md, bare README.md mention ignored"; else fail "generic basename: $out"; fi

# --- 5. a changed suite lists itself ----------------------------------------
change scripts/test-other.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-other\.sh$'; then pass "a changed suite is impacted by itself"; else fail "changed suite not listed: $out"; fi
if grepq "$out" '^scripts/test-wrapper\.sh$'; then pass "a suite that invokes the changed suite is impacted too"; else fail "caller of the changed suite not listed: $out"; fi

# --- 6. a deleted file still lists the suites that reference it --------------
git -C "$FX" rm -q scripts/machine-setup/install.sh
git -C "$FX" commit -q -m "chore: drop install.sh"
range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
out="$(run_is "$range")"
if [ "$out" = "scripts/test-installer.sh" ]; then pass "deleted install.sh still lists test-installer.sh"; else fail "deleted file: $out"; fi

# --- 7. fail-closed on a range that does not resolve ------------------------
out="$( cd "$FX" && bash "$IS" 'nope..alsonope' 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "unresolvable range -> rc2, empty stdout"; else fail "bad range rc=$rc out=$out"; fi
( cd "$FX" && bash "$IS" 'HEAD' >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "range without .. -> rc2"; else fail "no-dots range rc=$rc"; fi

# --- 8. --check: RED control for the ticket ----------------------------------
# The #2261 PR: uninstall-plugins.sh touched, test-uninstall.sh never run.
change scripts/machine-setup/uninstall-plugins.sh
( cd "$FX" && printf '' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "RED control: impacted suites with NO verdict -> row NOT clean (rc1)"; else fail "no-verdict fixture PR passed the row: rc=$rc"; fi
err="$( cd "$FX" && printf '' | bash "$IS" --check "$range" 2>&1 >/dev/null )"
if grepq "$err" 'scripts/test-uninstall\.sh'; then pass "the missing verdict names test-uninstall.sh"; else fail "missing suite not named: $err"; fi

V1='SUITE scripts/test-uninstall.sh = PASS'
V2='SUITE scripts/lanes/tests/plugins.test.mjs = SKIP no node on this host'
( cd "$FX" && printf '%s\n%s\n' "$V1" "$V2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass "PASS + SKIP-with-reason for every impacted suite -> clean (rc0)"; else fail "full verdict set refused: rc=$rc"; fi

( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = SKIP' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "SKIP without a reason is not a verdict (rc1)"; else fail "reasonless SKIP accepted: rc=$rc"; fi

err="$( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = BLOCKED denied: bun not permitted' | bash "$IS" --check "$range" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 3 ] && grepq "$err" 'BLOCKED scripts/lanes/tests/plugins\.test\.mjs'; then pass "BLOCKED-with-denial is accounted for but NOT clean (rc3, names the suite)"; else fail "BLOCKED suite: rc=$rc err=$err"; fi

( cd "$FX" && printf '%s\n' 'SUITE scripts/lanes/tests/plugins.test.mjs = BLOCKED denied: bun not permitted' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a missing verdict (rc1) still outranks BLOCKED (rc3)"; else fail "missing+blocked ordering: rc=$rc"; fi

( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = MAYBE' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "an unknown verdict word is not a verdict (rc1)"; else fail "unknown verdict accepted: rc=$rc"; fi

( cd "$FX" && printf '%s\n' 'SUITE scripts/test-uninstall.sh = PASS' 'SUITE scripts/test-elsewhere.sh = PASS' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a verdict for a suite that is not impacted does not cover the one that is (rc1)"; else fail "stray verdict covered a missing suite: rc=$rc"; fi

# --- 9. --check with nothing impacted is clean, and says so -----------------
change docs/foo/other.md
out="$( cd "$FX" && printf '' | bash "$IS" --check "$range" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '0 impacted'; then pass "no impacted suites -> rc0 '0 impacted'"; else fail "empty impacted set: rc=$rc out=$out"; fi

# --- 10. a search that fails is an error, never an empty impacted set --------
# A `git` shim that fails only `grep` (fatal, rc 128); every other subcommand
# reaches the real git so the range still resolves and needles are built.
SHIM="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM"' EXIT
printf '#!/usr/bin/env bash\nfor a in "$@"; do if [ "$a" = grep ]; then echo "fatal: injected" >&2; exit 128; fi; done\nexec "%s" "$@"\n' "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
change scripts/machine-setup/uninstall-plugins.sh
out="$( cd "$FX" && PATH="$SHIM:$PATH" bash "$IS" "$range" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "a failing git grep -> rc2, empty stdout (not an empty impacted set)"; else fail "git grep failure: rc=$rc out=$out"; fi
err="$( cd "$FX" && PATH="$SHIM:$PATH" bash "$IS" "$range" 2>&1 >/dev/null )"
if grepq "$err" 'git grep failed'; then pass "the failed search is named on stderr"; else fail "git grep failure not named: $err"; fi

# --- 11. a root-level generic file has no parent to qualify it ---------------
# package.json / CLAUDE.md at the repo root: the bare name is the only needle.
change package.json
out="$(run_is "$range")"
if [ "$out" = "scripts/test-pkg.sh" ]; then pass "root-level package.json -> suite naming package.json"; else fail "root-level generic file reached nothing: $out"; fi

# --- 11a. an extensionless reference to a changed script (HIMMEL-5160) -------
# A suite that names a hook by its stem (`guard_rc block-foo-guard`) exercises it
# as surely as one naming `block-foo-guard.sh`. Only a stem holding `-` or `_`
# counts (a one-word stem is a common word), and a longer name or a dotted
# variant that merely starts with the stem is a different word.
change scripts/hooks/block-foo-guard.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-ext\.sh$'; then pass "changed hook -> suite naming it without .sh"; else fail "extensionless stem reference not listed: $out"; fi
if ! grepq "$out" 'test-stem-longer\.sh'; then pass "stem needle does not match a longer name (block-foo-guard-extra)"; else fail "stem matched a longer name: $out"; fi
if ! grepq "$out" 'test-stem-dotted\.sh'; then pass "stem needle does not match block-foo-guard.bak"; else fail "stem matched a dotted variant: $out"; fi
change scripts/lib/my_helper.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-underscore\.sh$'; then pass "underscore stem named without .sh is listed"; else fail "underscore stem not listed: $out"; fi
change scripts/hooks/gate.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-gate-full\.sh$' && ! grepq "$out" 'test-stem-word\.sh'; then pass "one-word stem (gate) is not matched extensionless"; else fail "one-word stem over-listed or control missing: $out"; fi
# HIMMEL-5167 (judge j2322a items 1, 2): the leading boundary and the escaping of
# the stem needle are each pinned by a row that goes RED when that piece is removed.
change scripts/hooks/block-foo-guard.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-ext\.sh$' && ! grepq "$out" 'test-stem-lead\.sh'; then pass "stem needle has a leading boundary: x-block-foo-guard is another word"; else fail "stem matched x-block-foo-guard (no leading boundary) or control missing: $out"; fi
change scripts/hooks/a+b-c.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-plus\.sh$'; then pass "stem with a regex metacharacter (a+b-c) matches its own literal"; else fail "escaped stem a+b-c did not select its own suite: $out"; fi
if ! grepq "$out" 'test-stem-plus-wild\.sh'; then pass "stem a+b-c is a literal, not the pattern a+b-c (aab-c unlisted)"; else fail "stem metacharacter acted as a pattern: $out"; fi
# HIMMEL-5174 (judge j2330a item 1): the closure sourcer is named by its own stem
# in a suite (`guard_rc block-clo-hook`), never with .sh, so it needs its stem needle.
change scripts/lib/clo-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-clo-stem\.sh$'; then pass "a changed lib -> its sourcing hook named by stem only in a suite"; else fail "closure sourcer's stem reference not listed: $out"; fi

# --- 11b. an extensionless basename takes the path rule (HIMMEL-4606) ---------
# `diff` is a common word: a suite that merely says `diff -u` must not be listed,
# one that names guard-corpus/diff (or the full path) must.
change scripts/eval/guard-corpus/diff
out="$(run_is "$range")"
if ! grepq "$out" 'test-diff-word\.sh'; then pass "extensionless diff: a bare common-word mention is not listed"; else fail "bare 'diff' suite over-listed: $out"; fi
if grepq "$out" '^scripts/test-guard-corpus\.sh$' && grepq "$out" '^scripts/test-diff-fullpath\.sh$'; then pass "extensionless diff: suites naming guard-corpus/diff or the full path stay listed"; else fail "path-naming suite under-listed: $out"; fi
# A distinctive extensionless name (a `-` in it) keeps the bare match: a quoted
# 'claude-fake' has no `/` before it, and dropping it was an under-list (J1939 B1).
change scripts/claude-fake
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-claude-fake\.sh$'; then pass "extensionless distinctive name: a quoted bare reference stays listed"; else fail "claude-fake suite under-listed: $out"; fi
change scripts/eval/guard-corpus/diff
out="$(run_is "$range")"
# A suite-local variable ($HERE/diff) still ends in /diff, so it stays listed.
if grepq "$out" '^scripts/test-diff-var\.sh$'; then pass "extensionless diff: a variable-built \$HERE/diff reference stays listed"; else fail "\$HERE/diff suite under-listed: $out"; fi

# --- 11c. a bare source / . / shellcheck source= of a single-word file (HIMMEL-4621) ---
# After a `cd`, the operand is the bare name with no `/` before it. Only a line
# that sources it counts: a plain `diff a b` command and prose stay unlisted.
if grepq "$out" '^scripts/test-diff-source\.sh$'; then pass "bare 'source diff' after a cd is listed"; else fail "source diff suite under-listed: $out"; fi
if grepq "$out" '^scripts/test-diff-dot\.sh$'; then pass "bare '. \"diff\"' after a cd is listed"; else fail ". diff suite under-listed: $out"; fi
if grepq "$out" '^scripts/test-diff-directive\.sh$'; then pass "'# shellcheck source=diff' is listed"; else fail "shellcheck source=diff suite under-listed: $out"; fi
if grepq "$out" '^scripts/test-diff-dashdash\.sh$'; then pass "'source -- diff' is listed (HIMMEL-4978)"; else fail "source -- diff suite under-listed: $out"; fi
if grepq "$out" '^scripts/test-diff-helper\.sh$'; then pass "a suite reaching diff through a sourcing helper is listed"; else fail "source-closure bare-name suite under-listed: $out"; fi
if ! grepq "$out" 'test-diff-plain\.sh' && ! grepq "$out" 'test-diff-prose\.sh' && ! grepq "$out" 'test-diff-word\.sh'; then pass "a plain 'diff a b' command and comment prose stay unlisted"; else fail "plain diff over-listed: $out"; fi

# --- 11d. a changed path git would C-quote (HIMMEL-4978) ---------------------
# `git diff --name-only` quotes a name holding a double quote, backslash or tab,
# so no needle matched and the selector listed nothing and exited 0.
change 'scripts/q/we"ird.sh'
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-q-dquote\.sh$'; then pass "changed path with a double quote selects its suite"; else fail "double-quote path selected nothing: $out"; fi
change 'scripts/q/back\slash.sh'
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-q-backslash\.sh$'; then pass "changed path with a backslash selects its suite"; else fail "backslash path selected nothing: $out"; fi
change $'scripts/q/ta\tb.sh'
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-q-tab\.sh$'; then pass "changed path with a tab selects its suite"; else fail "tab path selected nothing: $out"; fi

# --- 12. the answer does not depend on the cwd it is run from ----------------
# git ls-tree / git grep are cwd-scoped; from a subdirectory the suites one
# level up would silently drop out and --check would pass on a partial set.
change scripts/machine-setup/uninstall-plugins.sh
out="$( cd "$FX/scripts/machine-setup" && bash "$IS" "$range" 2>/dev/null )"
if grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "run from a subdirectory: repo-relative list still reaches test-uninstall.sh"; else fail "subdirectory run dropped suites: $out"; fi

# --- 13. a non-ASCII suite path comes back as itself, not quoted -------------
# git grep -l quotes such a path ("scripts/test-caf\303\251.sh") unless
# core.quotepath is off; the runner would then filter it out as "not a suite".
mkf scripts/uniq-widget.sh
mkf 'scripts/test-café.sh' 'bash "$d/uniq-widget.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add widget + café suite"
change scripts/uniq-widget.sh
out="$(run_is "$range" --shell)"
if [ "$out" = "scripts/test-café.sh" ]; then pass "non-ASCII suite path is emitted verbatim"; else fail "non-ASCII suite path mangled: $out"; fi

# --- 13b. a SUITE path git grep -l would C-quote (HIMMEL-4997) ----------------
# A suite file name holding a double quote, backslash or tab came back quoted
# ("scripts/test-q\"x.sh") and the runner filtered it out as "not a suite".
mkf scripts/uniq-quoter.sh
mkf 'scripts/test-qg"x.sh' 'bash "$d/uniq-quoter.sh"'
mkf 'scripts/test-qg\y.sh' 'bash "$d/uniq-quoter.sh"'
mkf $'scripts/test-qg\tz.sh' 'bash "$d/uniq-quoter.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add quoter + quoted suites"
change scripts/uniq-quoter.sh
out="$(run_is "$range" --shell)"
want=$'scripts/test-qg\tz.sh\nscripts/test-qg"x.sh\nscripts/test-qg\\y.sh'
if [ "$(printf '%s\n' "$out" | LC_ALL=C sort)" = "$(printf '%s\n' "$want" | LC_ALL=C sort)" ]; then pass "suite paths with a double quote, backslash and tab are emitted verbatim"; else fail "quoted suite paths mangled: $out"; fi

# --- 14. a step that builds the list and fails is an error, not a short list --
# A `sort` shim that fails: the shell-only filter used to end in `|| true`, so
# an empty impacted set (rc 0) was the result of a pipeline that never ran.
SHIM2="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2"' EXIT
printf '#!/usr/bin/env bash\necho "sort: injected" >&2\nexit 2\n' > "$SHIM2/sort"
chmod +x "$SHIM2/sort"
out="$( cd "$FX" && PATH="$SHIM2:$PATH" bash "$IS" "$range" --shell 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "a failing sort -> rc2, empty stdout (not an empty impacted set)"; else fail "sort failure: rc=$rc out=$out"; fi
err="$( cd "$FX" && PATH="$SHIM2:$PATH" bash "$IS" "$range" --shell 2>&1 >/dev/null )"
if grepq "$err" 'sorting the impacted list failed'; then pass "the failed step is named on stderr"; else fail "sort failure not named: $err"; fi

# --- 15. a suite path containing spaces can receive a verdict (HIMMEL-3243) --
# The verdict path is everything between "SUITE " and the FIRST " = ", so a
# spaced path is accepted; a " = " inside the reason must not move the split.
mkf scripts/uniq-gadget.sh
mkf 'scripts/test-with space.sh' 'bash "$d/uniq-gadget.sh"'
mkf 'scripts/test-a=b.sh' 'bash "$d/uniq-gadget.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add gadget + spaced suites"
change scripts/uniq-gadget.sh
out="$(run_is "$range" --shell)"
if [ "$out" = "$(printf 'scripts/test-a=b.sh\nscripts/test-with space.sh')" ]; then pass "spaced suite paths are listed verbatim"; else fail "spaced suite paths not listed: $out"; fi
SP1='SUITE scripts/test-with space.sh = PASS'
SP2='SUITE scripts/test-a=b.sh = SKIP no gadget = here'
( cd "$FX" && printf '%s\n%s\n' "$SP1" "$SP2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass "verdicts for spaced/'='-bearing suite paths -> clean (rc0)"; else fail "spaced-path verdicts refused: rc=$rc"; fi
( cd "$FX" && printf '%s\n' "$SP2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a spaced suite without its own verdict stays missing (rc1)"; else fail "missing spaced verdict passed: rc=$rc"; fi
( cd "$FX" && printf '%s\n%s\n' "$SP1" 'SUITE scripts/test-a=b.sh = SKIP' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a reasonless SKIP on a spaced-path row is still no verdict (rc1)"; else fail "reasonless SKIP accepted on spaced path: rc=$rc"; fi

# --- 16. --runner-check: direct vitest steps + runner drift (HIMMEL-3445) ---
# Fixture workflow files in a scratch dir under $FX, never the real
# .github/workflows (case (c) below reads the real one as a control).
mkdir -p "$FX/.github/workflows"
run_rc() { ( cd "$FX" && bash "$IS" --runner-check 2>&1 ); }

# (a) a direct `npx vitest run` step for an unmapped directory is invisible
# to the old grep (it only looked for node --test/bun test/npm test/
# check-hook-lib-suites.sh) and passed silently; it must now fail, naming it.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  new-suite:
    runs-on: ubuntu-latest
    steps:
      - run: npx vitest run scripts/newthing/foo.test.ts
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'newthing'; then pass "unmapped direct vitest step fails --runner-check, naming it"; else fail "unmapped vitest step: rc=$rc out=$out"; fi

# (b) a mapped suite whose invocation drifted from node --test to bun test:
# the old marker matched by path substring alone (still present after the
# swap), so drift went undetected. --runner still emits `node --test` for
# this path.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  lanes-and-trust-suites:
    runs-on: ubuntu-latest
    steps:
      - run: bun test "scripts/lanes/tests/**/*.test.mjs"
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'lanes'; then pass "runner drift (node --test -> bun test) fails --runner-check, naming the suite"; else fail "runner drift: rc=$rc out=$out"; fi

# (c) control: today's real .github/workflows/ci.yml still passes.
out="$( cd "$REPO_ROOT" && bash "$IS" --runner-check 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "control: today's real ci.yml still passes --runner-check"; else fail "real ci.yml regressed: rc=$rc out=$out"; fi

# (d) an ambiguous line — two runner families on one `run:` line — cannot be
# attributed to a single runner; fail closed and name it, never guess.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  weird:
    runs-on: ubuntu-latest
    steps:
      - run: node --test "scripts/lanes/tests/**/*.test.mjs" && bun test "scripts/lanes/tests/**/*.test.mjs"
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'ambiguous'; then pass "a line naming two runner families fails closed as ambiguous"; else fail "ambiguous line: rc=$rc out=$out"; fi

# --- 17. --run: a fresh worktree's missing npm deps install before the
# suite runs (HIMMEL-3553: worktrees are created with --no-install, so a leg
# running an impacted suite raw sees a false SKIP/FAIL it mislabels
# "pre-existing" — N441/N440/N446 in one shift). -----------------------------
mkdir -p "$FX/pkg-npm"
cat > "$FX/pkg-npm/package.json" <<'JSON'
{
  "name": "fixture-npm",
  "version": "1.0.0",
  "dependencies": { "picocolors": "1.1.1" }
}
JSON
cat > "$FX/pkg-npm/package-lock.json" <<'JSON'
{
  "name": "fixture-npm",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": { "name": "fixture-npm", "version": "1.0.0", "dependencies": { "picocolors": "1.1.1" } },
    "node_modules/picocolors": {
      "version": "1.1.1",
      "resolved": "https://registry.npmjs.org/picocolors/-/picocolors-1.1.1.tgz",
      "integrity": "sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==",
      "license": "ISC"
    }
  }
}
JSON
cat > "$FX/pkg-npm/script.mjs" <<'JS'
import pc from 'picocolors';
console.log(pc.red('ok'));
JS
cat > "$FX/pkg-npm/test-uses-dep.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
node "$dir/script.mjs"
SH
chmod +x "$FX/pkg-npm/test-uses-dep.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add npm fixture package"

# RED control: today (no --run), the suite run raw with no node_modules
# fails MODULE_NOT_FOUND — the base bug, not something --check can rescue.
if (cd "$FX" && bash pkg-npm/test-uses-dep.sh >/dev/null 2>&1); then
    fail "RED control: raw suite should fail without node_modules installed"
else
    pass "RED control: raw suite fails without node_modules (base bug reproduced)"
fi
if [ ! -d "$FX/pkg-npm/node_modules" ]; then pass "RED control: node_modules absent before --run"; else fail "node_modules unexpectedly present before --run"; fi

out="$( cd "$FX" && bash "$IS" --run pkg-npm/test-uses-dep.sh 2>&1 )"; rc=$?
out_plain="$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')"
if [ "$rc" -eq 0 ] && grepq "$out_plain" '^ok$'; then pass "--run installs missing npm deps then runs the suite (GREEN)"; else fail "--run npm install+run: rc=$rc out=$out"; fi
if [ -d "$FX/pkg-npm/node_modules/picocolors" ]; then pass "--run left node_modules installed from the lockfile"; else fail "--run did not install node_modules"; fi
if grepq "$out" 'installing deps for pkg-npm'; then pass "--run names the package dir it is installing"; else fail "--run install message missing: $out"; fi

# idempotent second run: node_modules already present -> no reinstall.
out2="$( cd "$FX" && bash "$IS" --run pkg-npm/test-uses-dep.sh 2>&1 )"; rc2=$?
if [ "$rc2" -eq 0 ] && ! grepq "$out2" 'installing deps'; then pass "--run is idempotent: no reinstall once node_modules exists"; else fail "--run second run: rc=$rc2 out=$out2"; fi

# --- 18. --run: a bun.lock package installs via bun, --ignore-scripts ------
mkdir -p "$FX/pkg-bun"
cat > "$FX/pkg-bun/package.json" <<'JSON'
{
  "name": "fixture-bun",
  "version": "1.0.0",
  "dependencies": { "picocolors": "1.1.1" }
}
JSON
cat > "$FX/pkg-bun/bun.lock" <<'LOCK'
{
  "lockfileVersion": 2,
  "configVersion": 1,
  "workspaces": {
    "": {
      "name": "fixture-bun",
      "dependencies": {
        "picocolors": "1.1.1",
      },
    },
  },
  "packages": {
    "picocolors": ["picocolors@1.1.1", "", {}, "sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA=="],
  }
}
LOCK
cat > "$FX/pkg-bun/script.mjs" <<'JS'
import pc from 'picocolors';
console.log(pc.red('ok-bun'));
JS
cat > "$FX/pkg-bun/test-uses-dep.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
bun "$dir/script.mjs"
SH
chmod +x "$FX/pkg-bun/test-uses-dep.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add bun fixture package"

out="$( cd "$FX" && bash "$IS" --run pkg-bun/test-uses-dep.sh 2>&1 )"; rc=$?
out_plain="$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')"
if [ "$rc" -eq 0 ] && grepq "$out_plain" '^ok-bun$'; then pass "--run installs a bun.lock package via bun then runs the suite"; else fail "--run bun install+run: rc=$rc out=$out"; fi
if [ -d "$FX/pkg-bun/node_modules/picocolors" ]; then pass "--run left node_modules installed from bun.lock"; else fail "--run did not install bun node_modules"; fi
if grepq "$out" 'bun install --frozen-lockfile --ignore-scripts'; then pass "--run picks the frozen, script-ignoring bun install command"; else fail "--run bun install command not named: $out"; fi

# --- 19. --run: a missing lockfile is a hard FAIL naming the package dir and
# the suite never runs — never a SKIP, never a bare FAIL (HIMMEL-3553). ------
mkdir -p "$FX/pkg-nolock"
cat > "$FX/pkg-nolock/package.json" <<'JSON'
{ "name": "fixture-nolock", "version": "1.0.0", "dependencies": { "left-pad": "1.0.0" } }
JSON
cat > "$FX/pkg-nolock/test-nolock.sh" <<'SH'
#!/usr/bin/env bash
echo should-not-run
SH
chmod +x "$FX/pkg-nolock/test-nolock.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add nolock fixture package"
out="$( cd "$FX" && bash "$IS" --run pkg-nolock/test-nolock.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" 'no lockfile' && grepq "$out" 'pkg-nolock'; then pass "--run: missing lockfile is a hard FAIL naming the package dir (rc2), never a SKIP"; else fail "--run missing-lockfile: rc=$rc out=$out"; fi
if ! grepq "$out" 'should-not-run'; then pass "--run: the suite itself never ran after a failed install"; else fail "suite ran despite a missing lockfile: $out"; fi

# --- 20. --run: a suite with no package.json ancestor runs unchanged -------
# (fixture step 9 left a root-level package.json in $FX for a naming test;
# drop it here so this suite genuinely has no package.json ancestor.)
rm -f "$FX/package.json"
mkf scripts/test-no-deps.sh 'echo unaffected'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add no-deps suite, drop root package.json"
out="$( cd "$FX" && bash "$IS" --run scripts/test-no-deps.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'unaffected'; then pass "--run: a suite with no package.json ancestor runs unchanged"; else fail "--run no-deps suite: rc=$rc out=$out"; fi

# --- 21. HIMMEL-3798 round 3: --check --from-file reads verdict lines from a
# path instead of stdin. -------------------------------------------------
change scripts/machine-setup/uninstall-plugins.sh
FF="$FX/from-file-21.txt"
printf 'SUITE scripts/test-uninstall.sh = PASS\nSUITE scripts/lanes/tests/plugins.test.mjs = SKIP no node on this host\n' > "$FF"
err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FF" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "--check --from-file with the impacted suite's verdict -> clean (rc0)"; else fail "--from-file full verdict set refused: rc=$rc err=$err"; fi

# --- 22. --from-file without --check refuses (rc2). -------------------------
( cd "$FX" && bash "$IS" "$range" --from-file "$FF" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "--from-file without --check refuses (rc2)"; else fail "--from-file sans --check: rc=$rc"; fi

# --- 23. --from-file naming a missing path refuses (rc2), fails closed. -----
err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/nope-23.txt" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && grepq "$err" 'does not exist'; then pass "--from-file missing path -> rc2, names the reason"; else fail "--from-file missing path: rc=$rc err=$err"; fi

# --- 24. --from-file naming a symlink refuses (rc2) without reading through
# it. `ln -s` silently falls back to a plain copy without admin/Developer-Mode
# privilege on Windows — skip the assertion there (same probe idiom as T4e in
# test-write-verdicts.sh). --------------------------------------------------
printf 'SUITE scripts/test-uninstall.sh = PASS\n' > "$FX/real-24.txt"
ln -s "$FX/real-24.txt" "$FX/link-24.txt" 2>/dev/null
if [ -L "$FX/link-24.txt" ]; then
    err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/link-24.txt" 2>&1 >/dev/null )"; rc=$?
    if [ "$rc" -eq 2 ] && grepq "$err" 'symlink'; then pass "--from-file symlinked path -> rc2, names the reason"; else fail "--from-file symlink: rc=$rc err=$err"; fi
else
    echo "SKIP 24: platform cannot create symlinks without elevated privilege"
fi

# --- 25. HIMMEL-3798 round 4: --from-file naming a genuinely empty regular
# file is ALLOWED (same "no candidates" semantics as empty stdin, test 9) —
# but --check's own n_impacted/n_missing reconciliation, computed independently
# from the diff rather than from this file, still catches it as a missing
# verdict (rc1) when the impacted set from `change scripts/machine-setup/
# uninstall-plugins.sh` (test 21) is non-empty: this is the downstream catch
# for a wrongly-empty --from-file when real candidates exist. -----------------
: > "$FX/empty-25.txt"
out="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/empty-25.txt" 2>&1 )"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'without a verdict'; then pass "--from-file empty path with a non-empty impacted set -> rc1, names the gap"; else fail "--from-file empty path against impacted suites: rc=$rc out=$out"; fi

# --- 26. --from-file naming a genuinely empty file against a genuinely empty
# impacted set is clean (rc0) — the case the runbook's own zero-candidate
# instruction relies on. ------------------------------------------------------
change docs/bar/other-26.md
out="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/empty-25.txt" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '0 impacted'; then pass "--from-file empty path with an empty impacted set -> rc0 '0 impacted'"; else fail "--from-file empty path against no impacted suites: rc=$rc out=$out"; fi

# --- 27. HIMMEL-3896: source closure. A suite that names only mid.sh must be
# listed when far.sh (two source hops behind mid.sh) changes. -----------------
mkf scripts/lib/far.sh
mkf scripts/lib/deep.sh '. "$here/far.sh"'
mkf scripts/lib/mid.sh 'source "$here/deep.sh"'
mkf scripts/test-top.sh 'bash "$d/lib/mid.sh"'
mkf scripts/lib/noise.sh 'echo "see far.sh and deep.sh"'
mkf scripts/test-noise.sh 'bash "$d/lib/noise.sh"'
mkf scripts/lib/cyc-a.sh '. "$here/cyc-b.sh"'
mkf scripts/lib/cyc-b.sh '. "$here/cyc-a.sh"'
mkf scripts/test-cyc.sh 'bash "$d/lib/cyc-a.sh"'
gv_a=HIMMEL_UNINSTALL_   # name split across two variables so this file never matches the callers scan itself
gv_b=REAL_HOME
mkf scripts/guard-setter.sh "${gv_a}${gv_b}=1 bash x"
mkf scripts/guard-plain.sh 'echo nothing'
mkf scripts/test-uninstall-real-home-callers.sh 'grep -r "$V" scripts'
mkf scripts/lib/sp-a.sh
mkf scripts/lib/sp-b.sh 'source sp-a.sh'
mkf scripts/lib/sp-c.sh '. sp-b.sh'
mkf scripts/test-sp.sh 'bash "$d/lib/sp-c.sh"'
mkf scripts/lib/vs-lib.sh
mkf scripts/vs-user.sh $'_VS_LIB="$d/lib/vs-lib.sh"\nfor _l in "$_VS_LIB"; do\n  . "$_l"\ndone'
mkf scripts/test-vs.sh 'bash "$d/vs-user.sh"'
mkf scripts/lib/dr-lib.sh
mkf scripts/dr-user.sh $'# shellcheck source=lib/dr-lib.sh\n. "$(pick_lib)"'
mkf scripts/test-dr.sh 'bash "$d/dr-user.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: closure fixtures"
change scripts/lib/far.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-top\.sh$'; then pass "far.sh (2 source hops behind mid.sh) -> test-top.sh"; else fail "closure miss: $out"; fi
if ! grepq "$out" 'test-noise\.sh'; then pass "a non-source mention of far.sh/deep.sh does not widen"; else fail "non-source line widened the closure: $out"; fi
change scripts/lib/cyc-b.sh
change scripts/lib/sp-a.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-sp\.sh$'; then pass "single-space 'source x' / '. x' forms are followed (2 hops)"; else fail "single-space source form missed: $out"; fi
change scripts/lib/vs-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-vs\.sh$'; then pass "variable sourcing (_LIB=...; . \"\$_l\") is followed (backfill-sessions idiom)"; else fail "variable-sourcing miss: $out"; fi
change scripts/lib/dr-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-dr\.sh$'; then pass "a '# shellcheck source=<path>' directive is followed"; else fail "shellcheck-directive miss: $out"; fi
change scripts/lib/cyc-b.sh
# gnu-ok: timeout is guarded by command -v and falls back to an unbounded run
if command -v timeout >/dev/null 2>&1; then out="$( cd "$FX" && timeout 20 bash "$IS" "$range" 2>/dev/null )"; rc=$?; else out="$(run_is "$range")"; rc=0; fi
if [ "$rc" -eq 0 ] && grepq "$out" '^scripts/test-cyc\.sh$'; then pass "source cycle terminates and still lists test-cyc.sh"; else fail "cycle rc=$rc out=$out"; fi

# --- 28. HIMMEL-3868: a file that sets the fence-lifting variable pulls in the
# path-scanning callers suite, which never names it. -------------------------
change scripts/guard-setter.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-uninstall-real-home-callers\.sh$'; then pass "fence-lifting setter -> callers scan listed"; else fail "3868 miss: $out"; fi
change scripts/guard-plain.sh
out="$(run_is "$range")"
if ! grepq "$out" 'real-home-callers'; then pass "a file without the variable does not pull the callers scan"; else fail "callers scan over-selected: $out"; fi

# --- 28b. HIMMEL-4789: a file spelling a ~/.himmel ledger path pulls in the
# ledger registry lint, which scans every script and names none of them. ------
lg_dir=.himmel   # split so this file never spells a ledger path itself
mkf scripts/observability/test-ledgers-registry.sh 'git ls-files scripts'
mkf scripts/new-jsonl-writer.sh "echo x"
mkf scripts/new-log-writer.sh "echo x"
mkf scripts/no-ledger.sh 'echo nothing'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: ledger fixtures"
printf '%s\n' "out=\"\$HOME/${lg_dir}/failure-routes.jsonl\"" >> "$FX/scripts/new-jsonl-writer.sh"
change scripts/new-jsonl-writer.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/observability/test-ledgers-registry\.sh$'; then pass "added .jsonl ledger literal -> ledger registry lint listed"; else fail "4789 jsonl miss: $out"; fi
printf '%s\n' "log=~/${lg_dir}/sub/run.log" >> "$FX/scripts/new-log-writer.sh"
change scripts/new-log-writer.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/observability/test-ledgers-registry\.sh$'; then pass "added .log ledger literal -> ledger registry lint listed"; else fail "4789 log miss: $out"; fi
change scripts/no-ledger.sh
out="$(run_is "$range")"
if ! grepq "$out" 'test-ledgers-registry'; then pass "a file without a ledger literal does not pull the registry lint"; else fail "registry lint over-selected: $out"; fi

# --- 29. selector-miss: a red suite the PR's selection skipped is recorded. --
change scripts/lib/far.sh
printf 'scripts/test-other.sh\nscripts/test-top.sh\n' > "$FX/red-29.txt"
out="$( cd "$FX" && bash "$IS" --selector-miss "$range" --red-file "$FX/red-29.txt" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^selector-miss: scripts/test-other\.sh scripts/lib/far\.sh$' && ! grepq "$out" 'test-top'; then pass "selector-miss row for the skipped red suite only (rc1)"; else fail "selector-miss rc=$rc out=$out"; fi
printf 'scripts/test-top.sh\n' > "$FX/red-29b.txt"
out="$( cd "$FX" && bash "$IS" --selector-miss "$range" --red-file "$FX/red-29b.txt" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "every red suite was selected -> no rows (rc0)"; else fail "selector-miss clean case rc=$rc out=$out"; fi
( cd "$FX" && bash "$IS" --selector-miss "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "--selector-miss without --red-file -> rc2"; else fail "selector-miss usage rc=$rc"; fi

# --- 30. HIMMEL-3963: the word "source" in a full-line COMMENT is prose, not a
# source edge. A comment naming the changed helper must not join the closure
# (bank-preflight.sh:1084 "# Same source and spelling as tick.sh's ..." pulled
# ~136 suites in for a tracker.py change); a real source line, however it is
# indented or chained, still must. ------------------------------------------
mkf scripts/lib/cm-lib.sh
mkf scripts/lib/cm-prose.sh $'# Same source and spelling as cm-lib.sh\'s field\n  # source cm-lib.sh is the real one\necho prose'
mkf scripts/test-cm-prose.sh 'bash "$d/lib/cm-prose.sh"'
mkf scripts/lib/cm-asg.sh $'_CM="$d/cm-lib.sh"\n# the source $_CM line lives elsewhere\necho asg'
mkf scripts/test-cm-asg.sh 'bash "$d/lib/cm-asg.sh"'
mkf scripts/lib/cm-real.sh $'if x; then\n    source "$here/cm-lib.sh"   # trailing comment\nfi'
mkf scripts/test-cm-real.sh 'bash "$d/lib/cm-real.sh"'
mkf scripts/lib/cm-chain.sh 'true; . cm-lib.sh'
mkf scripts/test-cm-chain.sh 'bash "$d/lib/cm-chain.sh"'
mkf scripts/lib/cm-var.sh $'_CM="$d/cm-lib.sh"\n    . "$_CM"'
mkf scripts/test-cm-var.sh 'bash "$d/lib/cm-var.sh"'
mkf scripts/lib/cm-sub.sh $'(source cm-lib.sh)\n(. "$_CM")'
mkf scripts/test-cm-sub.sh 'bash "$d/lib/cm-sub.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: comment-prose closure fixtures"
change scripts/lib/cm-lib.sh
out="$(run_is "$range")"
if ! grepq "$out" 'test-cm-prose\.sh'; then pass "a comment that says 'source ... cm-lib.sh' does not widen"; else fail "comment prose widened the closure: $out"; fi
if ! grepq "$out" 'test-cm-asg\.sh'; then pass "a comment 'source \$var' does not make an assigning file a variable sourcer"; else fail "comment var-source widened the closure: $out"; fi
if grepq "$out" '^scripts/test-cm-real\.sh$'; then pass "an indented real source line with a trailing comment is still followed"; else fail "indented source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-chain\.sh$'; then pass "a chained '; . x' source is still followed"; else fail "chained source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-var\.sh$'; then pass "an indented variable-sourcing file is still followed"; else fail "indented var-source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-sub\.sh$'; then pass "a subshell '(source x)' is still followed"; else fail "subshell source missed: $out"; fi

# --- 31. HIMMEL-4256: the PR-1734 shape. A NEW file under a tree that a suite
# walks (lint-fail-open scans scripts/lanes/) lists that suite, though no suite
# names the file; a new file outside every declared tree does not. -----------
mkf scripts/guardrails/test-lint-fail-open.sh 'bash "$d/lint-fail-open.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: scan-roots fixtures"
mkdir -p "$FX/scripts/lanes/lib" "$FX/docs/scan-31"
change scripts/lanes/lib/leg-cost-row.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/guardrails/test-lint-fail-open\.sh$'; then pass "a new file under scripts/lanes/ -> test-lint-fail-open.sh (scan root)"; else fail "scan-root miss on the PR-1734 shape: $out"; fi
change docs/scan-31/new.sh
out="$(run_is "$range")"
if ! grepq "$out" 'test-lint-fail-open'; then pass "a new file outside every scan root does not list the scanning suite"; else fail "scan root over-selected: $out"; fi

# --- 31b. HIMMEL-5039: the wired-hook resolution sweep reads every hook script,
# its libs and the two wiring files without naming any of them, so a change to
# any of those lists it. ------------------------------------------------------
mkf scripts/hooks/test-wired-hooks-integrity-resolution.sh 'echo sweep'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: wired-hook sweep fixture"
mkdir -p "$FX/.claude" "$FX/.codex"
mkdir -p "$FX/scripts/guardrails" "$FX/scripts/handover"
for f in scripts/hooks/some-guard.sh scripts/lib/some-lib.sh scripts/guardrails/lib.sh scripts/handover/queue-lock.sh .claude/settings.json .codex/hooks.json; do
  change "$f"
  out="$(run_is "$range")"
  if grepq "$out" '^scripts/hooks/test-wired-hooks-integrity-resolution\.sh$'; then pass "$f -> test-wired-hooks-integrity-resolution.sh (scan root)"; else fail "wired-hook sweep not selected for $f: $out"; fi
done

# --- 32. HIMMEL-4323: npm-licenses row (RED control) and the veto rows. -----
NPM=scripts/hooks/test-check-npm-licenses\\.sh
PCR=scripts/cr/test-pr-check-run\\.sh
LSP=scripts/lanes/test-launch-site-profiles\\.sh
mkf scripts/hooks/test-check-npm-licenses.sh 'echo npm'
mkf scripts/cr/test-pr-check-run.sh 'echo pcr'
mkf scripts/lanes/test-launch-site-profiles.sh 'echo lsp'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: veto fixtures"
mkdir -p "$FX/tools/new" "$FX/tools/node_modules/dep" "$FX/scripts/lanes/bench/fixtures/x" "$FX/scripts/handover" "$FX/scripts/lanes/dist" "$FX/scripts/a"
change tools/new/package.json
out="$(run_is "$range")"
if grepq "$out" "^${NPM}\$"; then pass "a new package.json -> test-check-npm-licenses.sh"; else fail "npm-licenses row missed: $out"; fi
change tools/node_modules/dep/package.json
out="$(run_is "$range")"
if ! grepq "$out" "^${NPM}\$"; then pass "a node_modules package.json does not select npm-licenses"; else fail "npm-licenses veto (node_modules) missed: $out"; fi
change scripts/lanes/bench/fixtures/x/package.json
out="$(run_is "$range")"
if ! grepq "$out" "^${NPM}\$"; then pass "a bench-fixtures package.json does not select npm-licenses"; else fail "npm-licenses veto (fixtures) missed: $out"; fi
change scripts/a/tool.sh
out="$(run_is "$range")"
if grepq "$out" "^${PCR}\$" && grepq "$out" "^${LSP}\$"; then pass "a scripts/a/tool.sh selects pr-check-run and launch-site-profiles"; else fail "scripts/*.sh rows lost: $out"; fi
change scripts/a/test-foo.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${LSP}\$"; then pass "scripts/a/test-foo.sh does not select launch-site-profiles"; else fail "launch-site veto (test-*) missed: $out"; fi
if grepq "$out" "^${PCR}\$"; then pass "scripts/a/test-foo.sh still selects pr-check-run (its walk reads it)"; else fail "pr-check-run over-vetoed scripts/a/test-foo.sh: $out"; fi
change scripts/cr/test-foo.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${PCR}\$"; then pass "scripts/cr/test-foo.sh does not select pr-check-run"; else fail "pr-check-run veto (scripts/cr/test-*) missed: $out"; fi
change scripts/lanes/dist/gen.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${LSP}\$"; then pass "a dist/ file does not select launch-site-profiles"; else fail "launch-site veto (dist) missed: $out"; fi
if grepq "$out" "^${PCR}\$"; then pass "a dist/ file still selects pr-check-run"; else fail "pr-check-run lost dist/ file: $out"; fi

# --- 33. HIMMEL-4488: a changed .claude/commands/*.html selects the CR
# terminology suite (RED control: the .md row alone missed it). ----------------
TERM=scripts/ci/test-check-cr-terminology\\.sh
mkf scripts/ci/test-check-cr-terminology.sh 'echo term'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: terminology fixture"
mkdir -p "$FX/.claude/commands"
change .claude/commands/x.html
out="$(run_is "$range")"
if grepq "$out" "^${TERM}\$"; then pass "a .claude/commands/x.html -> test-check-cr-terminology.sh"; else fail "commands html row missed: $out"; fi

# --- 34. HIMMEL-4453: a change to the CR guarded closure selects
# test-cr-guarded-closure.sh (#1851: leg-jira-status.sh, reached from the
# guarded scripts/lanes/leg-pr-open.sh, was added without selecting it). --------
GC=scripts/cr/test-cr-guarded-closure\\.sh
mkf scripts/cr/test-cr-guarded-closure.sh 'echo gc'
mkf scripts/cr/pr-check-context.sh 'cr_guarded="scripts/cr scripts/lib
scripts/lanes/leg-pr-open.sh"'
mkf scripts/lanes/leg-pr-open.sh 'bash "$d/../handover/console-kit/leg-jira-status.sh"'
mkf scripts/lanes/unrelated.sh 'echo unrelated'
mkf scripts/handover/console-kit/leg-jira-status.sh 'echo jira'
mkf scripts/handover/console-kit/tracker.py 'print(1)'
mkf scripts/cr/test-names-tracker.sh 'grep -q tracker.py x'
mkf .agents/skills/pr-check/SKILL.md 'runbook'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: guarded-closure fixtures"
change scripts/lanes/leg-pr-open.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "a guarded file (leg-pr-open.sh) -> test-cr-guarded-closure.sh"; else fail "guarded file missed: $out"; fi
change scripts/handover/console-kit/leg-jira-status.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "the #1851 shape: an unguarded file a guarded file names -> test-cr-guarded-closure.sh"; else fail "#1851 shape missed: $out"; fi
change .agents/skills/pr-check/SKILL.md
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "the runbook twin -> test-cr-guarded-closure.sh"; else fail "runbook seed missed: $out"; fi
change scripts/handover/console-kit/tracker.py
out="$(run_is "$range")"
if ! grepq "$out" "^${GC}\$"; then pass "tracker.py (named only by a guarded test, reached by no guarded file) does not select the closure suite"; else fail "closure row over-selected tracker.py: $out"; fi
change scripts/lanes/unrelated.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${GC}\$"; then pass "an unreferenced scripts/lanes file does not select the closure suite"; else fail "closure row over-selected scripts/lanes: $out"; fi

# --- 35. HIMMEL-4533/4534/4535: closure arms. -------------------------------
# 4534: arm 1 alone. brand-new.sh sits under the guarded scripts/lib dir, no
# guarded file names it (arm 2 cannot fire) and no scan_roots row maps
# scripts/lib/* to the closure suite (scripts/cr/* does, so it cannot be used).
mkf scripts/lib/brand-new.sh 'echo new'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: arm-1 fixture"
change scripts/lib/brand-new.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "arm 1 alone: a file inside a guarded dir that nothing names -> closure suite"; else fail "arm 1 alone missed: $out"; fi
# 4533: arm 2 is not limited to handover/lanes/lib: a guarded file naming
# scripts/telegram/status.sh makes a change to it select the closure suite.
mkf scripts/lanes/names-tg.sh 'bash "$d/../telegram/status.sh"'
mkf scripts/telegram/status.sh 'echo status'
mkf scripts/cr/pr-check-context.sh 'cr_guarded="scripts/cr scripts/lib
scripts/lanes/leg-pr-open.sh scripts/lanes/names-tg.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: telegram fixtures"
change scripts/telegram/status.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "arm 2 beyond handover/lanes/lib: scripts/telegram/status.sh -> closure suite"; else fail "telegram edge missed: $out"; fi
# 4535: a head without pr-check-context.sh must not silently skip the suite.
git -C "$FX" rm -q scripts/cr/pr-check-context.sh
git -C "$FX" commit -q -m "chore: drop pr-check-context.sh"
change scripts/lanes/unrelated.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "a head with no pr-check-context.sh still selects the closure suite"; else fail "closure suite skipped on an unreadable guarded set: $out"; fi

# --- 36. HIMMEL-5167: a temp write that fails is an error, never a short list ---
# A full /tmp (2026-10-10, PR 2301: 56 suites against 60) made a bash here-string
# fail with "cannot create temp file for here-document"; its rc was read as "no
# suites" and the selector exited 0 with a partial list. RLIMIT_FSIZE (ulimit -f,
# SIGXFSZ ignored so the write returns EFBIG) is the user-space stand-in for
# ENOSPC: the same failing write(2), no root and no real disk filled. The fixture
# tree is sized like the real one (about 200 KB of path names, over a pipe's
# capacity, so a here-string must go through a temp file on every bash).
BIG="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2" "$SHD" "$BIG"' EXIT
(
    fixture_enter_git_init_dir "$BIG" || exit 1
    git init -q
    git config user.email t@e
    git config user.name t
    mkdir -p scripts/bulk
    pad="$(printf 'p%.0s' $(seq 1 100))"
    i=0
    while [ "$i" -lt 1500 ]; do
        : > "scripts/bulk/filler-${i}-${pad}.txt"
        i=$((i + 1))
    done
    printf '# big-target\n' > scripts/big-target.sh
    printf 'bash scripts/big-target.sh\n' > scripts/test-big.sh
    printf 'echo self\n' > scripts/test-self.sh
    git add -A
    git commit -q -m "chore: big base"
    printf '# changed\n' >> scripts/big-target.sh
    printf '# changed\n' >> scripts/test-self.sh
    git add -A
    git commit -q -m "fix: change big-target and a suite"
)
big_range="$(git -C "$BIG" rev-parse HEAD~1)..$(git -C "$BIG" rev-parse HEAD)"
# Probe: does a file-size limit bite here (Git Bash on Windows may not enforce it)?
probe="$BIG/.fsize-probe"
( ulimit -f 1; trap '' XFSZ; head -c 4096 /dev/zero > "$probe" ) 2>/dev/null
if [ "$(wc -c < "$probe" 2>/dev/null | tr -d ' ')" -ge 4096 ] 2>/dev/null; then
    echo "SKIP 36: this platform does not enforce ulimit -f"
else
    out="$( cd "$BIG" && bash "$IS" "$big_range" 2>/dev/null )"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$(printf 'scripts/test-big.sh\nscripts/test-self.sh')" ]; then pass "big fixture, room to write: the suite naming big-target.sh and the changed suite are listed (control)"; else fail "big fixture control: rc=$rc out=$out"; fi
    out="$( cd "$BIG" && ulimit -f 40 && trap '' XFSZ && bash "$IS" "$big_range" 2>/dev/null )"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then pass "a temp write that fails -> non-zero rc and no list (not a short list at rc0)"; else fail "failing temp write: rc=$rc out=$out"; fi
    err="$( cd "$BIG" && ulimit -f 40 && trap '' XFSZ && bash "$IS" "$big_range" 2>&1 >/dev/null )"
    if grepq "$err" 'cannot trust the impacted list'; then pass "the failed temp write is named on stderr"; else fail "failing temp write not named: $err"; fi
fi

# --- 36a. HIMMEL-5174 (judge j2330a item 3): every checked create fails closed ---
# Row 36 pins only the first temp write. Here a mktemp shim makes the work dir
# with a DIRECTORY already sitting at one scratch file's name, so that file's
# create cannot open: each name below must end the run at rc 2 with no list. A
# create that read its failure as rc 1 ("no match") would exit 0 with a short list.
SHIM3="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2" "$SHD" "$BIG" "$SHIM3"' EXIT
printf '#!/usr/bin/env bash\nd="$(%s "$@")" || exit $?\nif [ -n "${PRECREATE_DIR:-}" ]; then mkdir "$d/$PRECREATE_DIR" || exit 1; fi\nprintf "%%s\\n" "$d"\n' "$(command -v mktemp)" > "$SHIM3/mktemp"
chmod +x "$SHIM3/mktemp"
change scripts/lib/clo-lib.sh
out="$( cd "$FX" && PRECREATE_DIR=unused PATH="$SHIM3:$PATH" bash "$IS" "$range" 2>"$SHIM3/err" )"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ] && [ ! -s "$SHIM3/err" ]; then pass "unused scratch directory: shim permits rc 0 and a non-empty list (36a control)"; else fail "36a control: rc=$rc out=$out err=$(cat "$SHIM3/err")"; fi
# For grep.out and *.raw, rc 2/no list alone pins only the fail-closed outcome:
# a later read also fails after a removed create check. The diagnostic below
# additionally pins the expected first failing step, not just that outcome.
while IFS='|' read -r name step; do
    out="$( cd "$FX" && PRECREATE_DIR="$name" PATH="$SHIM3:$PATH" bash "$IS" "$range" 2>"$SHIM3/err" )"; rc=$?
    err="$(cat "$SHIM3/err")"
    if [ "$rc" -eq 2 ] && [ -z "$out" ] && grepq "$err" -F "impacted-suites: $step failed — cannot trust the impacted list"; then pass "scratch '$name' cannot open -> rc 2, no list, named step"; else fail "scratch '$name': rc=$rc out=$out err=$err (wanted $step)"; fi
done <<'EOF'
tree|writing the tree listing
changed|writing the changed-file list
suites|creating the suite list
patterns|writing a needle
found|recording a scan-root suite
seen|seeding the source closure
front|seeding the source closure
srcpats|writing a source-edge pattern
asgpats|writing an assignment pattern
dirpats|writing a directive pattern
hit.src.raw|creating the walking the source closure hit list
hit.dir.raw|creating the reading shellcheck source directives hit list
hit.asg.raw|creating the reading variable assignments hit list
hit.src|reading walking the source closure
hit.dir|reading reading shellcheck source directives
hit.asg|reading reading variable assignments
src.out|merging source-closure hits
next|growing the source closure
varsrc.raw|creating the variable-sourcer list
varsrc|listing variable-sourcing files
content-rules|writing the content rules
grep.out|creating the search result file
EOF
out="$( cd "$FX" && PRECREATE_DIR=shell PATH="$SHIM3:$PATH" bash "$IS" "$range" --shell 2>"$SHIM3/err" )"; rc=$?
err="$(cat "$SHIM3/err")"
if [ "$rc" -eq 2 ] && [ -z "$out" ] && grepq "$err" -F 'impacted-suites: creating the shell-suite list failed'; then pass "--shell: filter file cannot open -> rc 2, no list, named step"; else fail "--shell filter file: rc=$rc out=$out err=$err"; fi
out="$( cd "$FX" && PRECREATE_DIR=impacted PATH="$SHIM3:$PATH" bash "$IS" "$range" 2>"$SHIM3/err" )"; rc=$?
err="$(cat "$SHIM3/err")"
if [ "$rc" -eq 2 ] && [ -z "$out" ] && grepq "$err" -F 'impacted-suites: sorting the impacted list failed'; then pass "impacted-list file cannot open -> rc 2, no list, named step"; else fail "impacted-list file: rc=$rc out=$out err=$err"; fi

# --- 36b. HIMMEL-5178: final stdout write must fail closed ------------------
# /dev/full rejects writes, but can be opened: the failure must reach the final
# cat, not the shell redirect. Dropping cat's || io_fail returns rc 0 instead.
if [ -c /dev/full ]; then
    ( cd "$FX" && bash "$IS" "$range" >/dev/full 2>"$SHIM3/err" ); rc=$?
    err="$(cat "$SHIM3/err")"
    if [ "$rc" -eq 2 ] && grepq "$err" -F 'impacted-suites: listing the impacted suites failed'; then pass "final stdout write fails -> rc 2, named listing step"; else fail "final stdout write: rc=$rc err=$err"; fi
else
    echo "SKIP 36b: /dev/full is unavailable on this platform"
fi

# --- HIMMEL-4781: no range argument defaults to merge-base(default)..HEAD ----
# The default branch is resolved by scripts/lib/cr-default-base.sh (origin/HEAD,
# else origin/main).
run_is_err() { ( cd "$FX" && { bash "$IS" "$@" >/dev/null; } 2>&1 ); }
# (a) no origin ref at all: refuse non-zero, name the filled fetch command.
err="$(run_is_err)"
if ( cd "$FX" && bash "$IS" >/dev/null 2>&1 ); then
    fail "no-arg run with no default ref exited 0"
else
    pass "no-arg run with no default ref exits non-zero"
fi
if grepq "$err" -F 'git fetch origin'; then pass "no default ref: error names the filled fetch command"; else fail "no default ref: no fetch command in: $err"; fi
# (b) origin/main behind HEAD: the default is merge-base..HEAD, printed to stderr.
mb_sha="$(git -C "$FX" rev-parse HEAD)"
git -C "$FX" update-ref refs/remotes/origin/main "$mb_sha"
change scripts/machine-setup/uninstall-plugins.sh
want="$(run_is "${mb_sha}..HEAD")"
got="$(run_is)"
if [ -n "$want" ] && [ "$got" = "$want" ]; then pass "no-arg run lists the same suites as merge-base..HEAD"; else fail "no-arg output differs: want [$want] got [$got]"; fi
err="$(run_is_err)"
if grepq "$err" -F "${mb_sha}..HEAD"; then pass "no-arg run prints the chosen range to stderr"; else fail "chosen range not on stderr: $err"; fi
err="$(run_is_err "${mb_sha}..HEAD")"
if [ -z "$err" ]; then pass "explicit range: stderr unchanged (empty)"; else fail "explicit range wrote to stderr: $err"; fi
# (c) origin/HEAD names another branch: it wins over origin/main.
git -C "$FX" update-ref refs/remotes/origin/trunk "$(git -C "$FX" rev-parse HEAD~3)"
git -C "$FX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
trunk_mb="$(git -C "$FX" rev-parse HEAD~3)"
err="$(run_is_err)"
if grepq "$err" -F "${trunk_mb}..HEAD"; then pass "origin/HEAD's target is the default branch"; else fail "origin/HEAD ignored: $err"; fi
git -C "$FX" symbolic-ref -d refs/remotes/origin/HEAD
# (d) default ref shares no history with HEAD: refuse with a filled command.
orphan="$(git -C "$FX" commit-tree -m orphan "$(git -C "$FX" mktree </dev/null)")"
git -C "$FX" update-ref refs/remotes/origin/main "$orphan"
err="$(run_is_err)"
if ( cd "$FX" && bash "$IS" >/dev/null 2>&1 ); then
    fail "no-arg run with no merge-base exited 0"
else
    pass "no-arg run with no merge-base exits non-zero"
fi
if grepq "$err" -F 'pass an explicit range' && ! grepq "$err" -F 'unshallow'; then pass "unrelated history: error asks for an explicit range, not --unshallow"; else fail "unrelated history: wrong remedy in: $err"; fi
# (e) the same in a shallow clone: --unshallow is the remedy.
SHD="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2" "$SHD" "$BIG" "$SHIM3"' EXIT
# HIMMEL-5178: this replacement must retain the earlier fixture cleanup.
# Source-level assertion; CI also runs the actual EXIT trap.
exit_trap="$(trap -p EXIT)"
if grepq "$exit_trap" -F '"$BIG"' && grepq "$exit_trap" -F '"$SHIM3"'; then pass "active EXIT trap retains BIG and SHIM3 cleanup"; else fail "active EXIT trap drops earlier fixtures: $exit_trap"; fi
SH="$SHD/c"
git clone -q --depth 1 "file://$FX" "$SH"
git -C "$SH" symbolic-ref -d refs/remotes/origin/HEAD
git -C "$SH" update-ref refs/remotes/origin/main "$(git -C "$SH" -c user.name=t -c user.email=t@e commit-tree -m orphan "$(git -C "$SH" mktree </dev/null)")"
err="$( ( cd "$SH" && { bash "$IS" >/dev/null; } 2>&1 ) )"
if grepq "$err" -F 'git fetch --unshallow origin'; then pass "shallow clone: error names git fetch --unshallow origin"; else fail "shallow clone: no unshallow command in: $err"; fi
git -C "$FX" update-ref -d refs/remotes/origin/main

echo
if [ "$failures" -eq 0 ]; then echo "OK: all cases passed"; exit 0; fi
echo "FAIL: $failures case(s) failed"
exit 1
