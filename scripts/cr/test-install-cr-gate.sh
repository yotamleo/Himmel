#!/usr/bin/env bash
# Tests for scripts/cr/install-cr-gate.sh (HIMMEL-2035 T2).
# SC2015: `cond && pass || fail` is this suite family's house assertion
# shape (test-cr-pending-audit.sh, test-clear-cr-marker.sh) — pass() cannot
# fail, so the A&&B||C caveat does not apply here.
# SC2012: retained for any remaining ls-based listing in this suite.
#
# shellcheck disable=SC2015,SC2012
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-cr-gate.sh"
REPO_ROOT="$SCRIPT_DIR/../.."
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

PASS=0
FAIL=0
SKIP=0
TMP_ROOT=""
cleanup() {
    [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT" 2>/dev/null || true
    # T15 (HIMMEL-2226) registers a throwaway linked worktree of REPO_ROOT
    # under TMP_ROOT; if the suite exits before its explicit `worktree
    # remove` runs, prune the now-dangling administrative entry rather than
    # leaving it behind in the real repo.
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
# skip <label> -- a case that could not run in this environment. Must NEVER
# be reported via pass(): a skip credited as a pass hides the fact that
# nothing was asserted (HIMMEL-2258 audit; HIMMEL-2226 fix).
skip() { SKIP=$((SKIP + 1)); echo "  SKIP: $1" >&2; }

is_mingw() {
    case "$(uname -s 2>/dev/null || echo)" in
        *MINGW*|*MSYS*|*CYGWIN*|*NT*) return 0 ;; *) return 1 ;;
    esac
}

TMP_ROOT=$(fixture_mktemp_dir) || exit 1
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

# HERMETIC GIT CONFIG (HIMMEL-2035 CR round 1). Without this the fixtures
# inherit the OPERATOR's global git config — which on a himmel box sets
# core.hooksPath, so every `git commit`/`git push` below ran the machine's
# global pre-commit/commit-msg/pre-push hooks. That made the suite both
# non-hermetic (its result depended on whose machine it ran on) and glacial.
# It also masked the very finding this round fixes: the effective hooks dir
# differs from <git-common-dir>/hooks exactly when a global core.hooksPath is
# set. Pin an EMPTY global config and no system config; the cases that need a
# global hooksPath set one explicitly (T20).
GIT_CONFIG_GLOBAL="$TMP_ROOT/empty-gitconfig"
: > "$GIT_CONFIG_GLOBAL"
GIT_CONFIG_SYSTEM="$TMP_ROOT/empty-gitsystem"
: > "$GIT_CONFIG_SYSTEM"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

# mk_foreign_repo DIR — bare "origin.git" + a clone "work" on main, plus a
# feat/x branch with one commit ahead. Hermetic: repo-local identity only.
mk_foreign_repo() {
    d="$1"; mkdir -p "$d/origin.git" "$d/work"
    git init --bare -q "$d/origin.git"
    git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$d/origin.git" "$d/work"
    git -C "$d/work" config user.name  "himmel-test"
    git -C "$d/work" config user.email "himmel-test@example.invalid"
    ( cd "$d/work" && git commit -q --allow-empty -m init && git push -q origin HEAD:refs/heads/main \
        && git remote set-head origin -a >/dev/null 2>&1 \
        && git checkout -qb feat/x && git commit -q --allow-empty -m change )
    git -C "$d/work" symbolic-ref refs/remotes/origin/HEAD >/dev/null \
        || { echo "fixture: origin/HEAD not established in $d/work" >&2; return 1; }
}

# baked_path_of <hook-file> — the gate path the hook will actually resolve.
# The hook writes `gate=<printf %q token>`, so parse it with one level of
# shell parsing, exactly as the hook does at push time. A `sed` stripping a
# `gate="..."` shape silently returns the WHOLE LINE once %q emits an
# unquoted or backslash-escaped token (HIMMEL-2035 CR round 2).
baked_path_of() {
    sed -n 's/^# himmel-cr-gate-path: //p' "$1" 2>/dev/null | head -n1
}

echo "T1: install into a clean fixture"
d="$TMP_ROOT/f1"; mk_foreign_repo "$d" || exit 1
hook="$d/work/.git/hooks/pre-push"
out=$(bash "$INSTALLER" --target "$d/work" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -x "$hook" ] && grep -Fq '# himmel-cr-gate-v1' "$hook" \
    && pass || fail "T1 rc=$rc out=$out"

echo "T2: install again -> already-current, byte-identical"
before=$(md5sum "$hook" 2>/dev/null || cksum "$hook")
out=$(bash "$INSTALLER" --target "$d/work" 2>&1); rc=$?
after=$(md5sum "$hook" 2>/dev/null || cksum "$hook")
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Fq "already-current" && [ "$before" = "$after" ] \
    && pass || fail "T2 rc=$rc out=$out"

echo "T3: --status after install -> installed"
out=$(bash "$INSTALLER" --target "$d/work" --status 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Fq "installed" && pass || fail "T3 rc=$rc out=$out"

echo "T4: --remove -> hook gone; --status -> absent"
out=$(bash "$INSTALLER" --target "$d/work" --remove 2>&1); rc=$?
out2=$(bash "$INSTALLER" --target "$d/work" --status 2>&1); rc2=$?
[ "$rc" -eq 0 ] && [ ! -e "$hook" ] && [ "$rc2" -eq 0 ] && printf '%s' "$out2" | grep -Fq "absent" \
    && pass || fail "T4 rc=$rc out=$out rc2=$rc2 out2=$out2"

echo "T5: --remove again -> nothing to remove"
out=$(bash "$INSTALLER" --target "$d/work" --remove 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Fq "nothing to remove" && pass || fail "T5 rc=$rc out=$out"

echo "T6: --remove on a hand-written foreign pre-push -> exit 2, untouched"
printf '#!/bin/sh\necho foreign\n' > "$hook"; chmod +x "$hook"
before=$(cat "$hook")
out=$(bash "$INSTALLER" --target "$d/work" --remove 2>&1); rc=$?
after=$(cat "$hook")
[ "$rc" -eq 2 ] && [ "$before" = "$after" ] && pass || fail "T6 rc=$rc out=$out"

echo "T7: install over a hand-written foreign pre-push -> exit 2, untouched"
out=$(bash "$INSTALLER" --target "$d/work" 2>&1); rc=$?
after=$(cat "$hook")
[ "$rc" -eq 2 ] && [ "$before" = "$after" ] && pass || fail "T7 rc=$rc out=$out"

echo "T8: same with --force -> exit 0, replaced by himmel hook"
out=$(bash "$INSTALLER" --target "$d/work" --force 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -Fq '# himmel-cr-gate-v1' "$hook" && pass || fail "T8 rc=$rc out=$out"

echo "T9: --target = a non-work-tree dir -> exit 2, nothing created"
notrepo="$TMP_ROOT/notrepo"; mkdir -p "$notrepo"
out=$(bash "$INSTALLER" --target "$notrepo" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$notrepo/.git" ] && pass || fail "T9 rc=$rc out=$out"

echo "T10: --target = the himmel checkout -> exit 2, himmel hooks dir unchanged"
himmel_hooks_dir=$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)/hooks
out=$(bash "$INSTALLER" --target "$REPO_ROOT" 2>&1); rc=$?
# Assert the PRECISE property, not a whole-directory hash. himmel's hooks dir
# is live shared state — a concurrent session in this checkout can rewrite a
# hook mid-run, so a listing comparison flakes red for reasons unrelated to
# the code under test. What must never happen is OUR gate appearing there.
leaked=$(grep -lF '# himmel-cr-gate-v1' "$himmel_hooks_dir"/* 2>/dev/null || true)
[ "$rc" -eq 2 ] && [ -z "$leaked" ] && pass || fail "T10 rc=$rc leaked='$leaked' out=$out"

echo "T11: --target with core.hooksPath=.githooks -> lands at <target>/.githooks/pre-push"
d2="$TMP_ROOT/f2"; mk_foreign_repo "$d2" || exit 1
git -C "$d2/work" config --local core.hooksPath .githooks
out=$(bash "$INSTALLER" --target "$d2/work" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$d2/work/.githooks/pre-push" ] && [ ! -f "$d2/work/.git/hooks/pre-push" ] \
    && pass || fail "T11 rc=$rc out=$out"

echo "T12: --status on a fixture-local hook whose baked path is sed-edited to a nonexistent file -> stale"
d3="$TMP_ROOT/f3"; mk_foreign_repo "$d3" || exit 1
hook3="$d3/work/.git/hooks/pre-push"
bash "$INSTALLER" --target "$d3/work" >/dev/null 2>&1
sed -i -e 's|^gate=.*|gate=/no/such/gate.sh|' \
       -e 's|^# himmel-cr-gate-path: .*|# himmel-cr-gate-path: /no/such/gate.sh|' "$hook3"
out=$(bash "$INSTALLER" --target "$d3/work" --status 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq "stale" && pass || fail "T12 rc=$rc out=$out"

echo "T13: running that edited fixture hook directly -> exit 2 + named remedy on stderr"
out=$(bash "$hook3" </dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -Fq "install-cr-gate.sh" && pass || fail "T13 rc=$rc out=$out"

if is_mingw; then
    echo "T14 (MINGW only): baked path matches ^[A-Za-z]:/"
    d4="$TMP_ROOT/f4"; mk_foreign_repo "$d4" || exit 1
    bash "$INSTALLER" --target "$d4/work" >/dev/null 2>&1
    baked=$(baked_path_of "$d4/work/.git/hooks/pre-push")
    case "$baked" in
        [A-Za-z]:/*) pass ;;
        *) fail "T14 baked=$baked" ;;
    esac
else
    echo "T14 (MINGW only): SKIP (not running under MINGW/MSYS/CYGWIN)"
fi

echo "T15: installer invoked from a THROWAWAY LINKED WORKTREE -> baked path names the PRIMARY checkout"
# HIMMEL-2226 (HIMMEL-2258 audit): the old version of this test only
# discriminated worktree-vs-primary when the SUITE ITSELF happened to be
# invoked from a linked worktree — the ordinary invocation state, but not a
# guarantee. When the suite ran FROM the primary checkout, "this suite's own
# root" and "expected primary" were the SAME directory, so that half was
# SKIPPED (HIMMEL-2232) while the test still reported a plain pass — the
# discrimination asserted nothing in that shape of run. Fix: stand up a
# genuine throwaway linked worktree of REPO_ROOT (itself either primary or a
# worktree — irrelevant, `git worktree list` always resolves the SAME
# primary) and run the installer FROM there, so the worktree-vs-primary
# discrimination runs unconditionally regardless of where this suite itself
# was invoked from.
expected_primary=$(git -C "$REPO_ROOT" worktree list --porcelain | sed -n 's/^worktree //p;1q')
if command -v cygpath >/dev/null 2>&1; then
    expected_primary=$(cygpath -m "$expected_primary")
fi
w15="$TMP_ROOT/f15-worktree"
if git -C "$REPO_ROOT" worktree add --detach -q "$w15" >/dev/null 2>&1; then
    w15_native="$w15"
    if command -v cygpath >/dev/null 2>&1; then
        w15_native=$(cygpath -m "$w15")
    fi
    installer15="$w15/scripts/cr/install-cr-gate.sh"
    d5="$TMP_ROOT/f5"; mk_foreign_repo "$d5" || exit 1
    bash "$installer15" --target "$d5/work" >/dev/null 2>&1
    baked=$(baked_path_of "$d5/work/.git/hooks/pre-push")
    case "$baked" in
        "$w15_native"/*) fail "T15 baked path names the throwaway worktree, not primary: $baked" ;;
        *)
            if [ -n "$baked" ] && [ -f "$baked" ]; then
                case "$baked" in "$expected_primary"/*) pass ;; *) fail "T15 baked=$baked expected under $expected_primary" ;; esac
            else
                fail "T15 baked path missing/empty: $baked"
            fi
            ;;
    esac
    git -C "$REPO_ROOT" worktree remove --force "$w15" >/dev/null 2>&1 || rm -rf "$w15" 2>/dev/null || true
else
    skip "T15 — could not create a throwaway git worktree of REPO_ROOT in this environment; worktree-vs-primary discrimination unavailable"
fi

echo "T16: invoked with cwd = the target repo (the realistic deployment shape)"
d6="$TMP_ROOT/f6"; mk_foreign_repo "$d6" || exit 1
out=$(cd "$d6/work" && bash "$INSTALLER" --target . 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$d6/work/.git/hooks/pre-push" ] && grep -Fq '# himmel-cr-gate-v1' "$d6/work/.git/hooks/pre-push" \
    && pass || fail "T16 rc=$rc out=$out"

echo "T17: target whose origin is non-github -> exit 0, install succeeds, warning on stderr"
d7="$TMP_ROOT/f7"; mk_foreign_repo "$d7" || exit 1
git -C "$d7/work" remote set-url origin https://bitbucket.org/o/n
out=$(bash "$INSTALLER" --target "$d7/work" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Fq "not github.com" && pass || fail "T17 rc=$rc out=$out"

echo "T20: repo-local core.hooksPath='~/hooks' is TILDE-EXPANDED by git, not treated as repo-relative [codex-2]"
# The old hand-rolled resolver classified `~/hooks` as "relative" and produced
# "<toplevel>/~/hooks" — a literal '~' directory git never reads.
# [codex-4], CR round 2: this case previously configured an ALREADY-EXPANDED
# absolute path, so it never exercised tilde expansion at all — it asserted
# nothing the regression could break. Configure a literal `~/hooks` and point
# HOME at a temp dir so the expansion is observable and hermetic.
d9="$TMP_ROOT/f9"; mk_foreign_repo "$d9" || exit 1
fake_home="$TMP_ROOT/fakehome"; mkdir -p "$fake_home"
# shellcheck disable=SC2088  # the LITERAL tilde is the point: git expands it, we must not
git -C "$d9/work" config --local core.hooksPath '~/hooks'
out=$(HOME="$fake_home" bash "$INSTALLER" --target "$d9/work" 2>&1); rc=$?
# The literal '~' directory is the old bug's signature; it must never appear.
# $HOME/hooks is OUTSIDE the repo, so per [codex-1] the gate installs
# per-repo and warns rather than writing into a home-shared dir.
[ "$rc" -eq 0 ] \
    && [ ! -e "$d9/work/~" ] \
    && [ ! -e "$d9/work/.githooks" ] \
    && [ -f "$d9/work/.git/hooks/pre-push" ] \
    && printf '%s' "$out" | grep -Fq "$fake_home/hooks" \
    && pass || fail "T20 rc=$rc out=$out"

echo "T21: a GLOBAL-scope core.hooksPath installs PER-REPO and warns [codex-1]"
# git would run hooks from the shared global dir, so an "installed" report
# must be accompanied by the warning — and must NOT write into the shared dir
# (that would arm every repo on the machine).
d10="$TMP_ROOT/f10"; mk_foreign_repo "$d10" || exit 1
shared_hooks="$TMP_ROOT/shared-hooks"; mkdir -p "$shared_hooks"
g10="$TMP_ROOT/gitconfig-global-hookspath"
printf '[core]\n\thooksPath = %s\n' "$shared_hooks" > "$g10"
out=$(GIT_CONFIG_GLOBAL="$g10" bash "$INSTALLER" --target "$d10/work" 2>&1); rc=$?
# No chain present -> must say INERT and name both owner-run remedies.
[ "$rc" -eq 0 ] \
    && [ -f "$d10/work/.git/hooks/pre-push" ] \
    && [ ! -e "$shared_hooks/pre-push" ] \
    && printf '%s' "$out" | grep -Fq "INSTALLED BUT INERT" \
    && printf '%s' "$out" | grep -Fq "core.hooksPath '$d10/work/.git/hooks'" \
    && printf '%s' "$out" | grep -Fq "rev-parse --path-format=absolute --git-common-dir" \
    && pass || fail "T21 rc=$rc out=$out"

echo "T21b: a GLOBAL hooks dir that CHAINS to the repo hook reports 'should fire', not inert"
# tokensave's shim shape. The warn must distinguish this from the inert case,
# or an operator on a chained box learns to ignore a warning that is wrong.
d12="$TMP_ROOT/f12"; mk_foreign_repo "$d12" || exit 1
chain_hooks="$TMP_ROOT/chain-hooks"; mkdir -p "$chain_hooks"
cat > "$chain_hooks/pre-push" <<'CHAIN'
#!/bin/sh
repo_hook="$(git rev-parse --git-dir 2>/dev/null)/hooks/pre-push"
if [ -x "$repo_hook" ] && [ "$repo_hook" != "$0" ]; then
	"$repo_hook" "$@"
fi
CHAIN
chmod +x "$chain_hooks/pre-push"
g12="$TMP_ROOT/gitconfig-global-chain"
printf '[core]\n\thooksPath = %s\n' "$chain_hooks" > "$g12"
out=$(GIT_CONFIG_GLOBAL="$g12" bash "$INSTALLER" --target "$d12/work" 2>&1); rc=$?
[ "$rc" -eq 0 ] \
    && printf '%s' "$out" | grep -Fq "appears to CHAIN" \
    && ! printf '%s' "$out" | grep -Fq "INSTALLED BUT INERT" \
    && pass || fail "T21b rc=$rc out=$out"

# NAMED for what it actually verifies (round 3 [codex-2]): the earlier title
# claimed failed-write preservation, which this does NOT cover — a regression
# to a direct truncating write would still pass. Interrupting a write is not
# portably injectable (chmod on a directory is a no-op under MSYS, and the temp
# name carries the INSTALLER's $$, so it cannot be pre-created from here). What
# IS checkable is that the rewrite lands complete and leaves no staging residue.
# ponytail: consequence-level check; a true mid-write interrupt needs a fault-
# injection seam in the installer, which is not worth adding for this.
echo "T22: a rewrite lands COMPLETE and leaves no staging residue (not failed-write coverage)"
# [codex-5], CR round 2: this case previously set `core.gate-bump`, which does
# NOT change the generated content — so the installer short-circuited on
# `already-current` and the write path under test never ran. The assertion
# passed vacuously. Force a genuine content difference by editing the baked
# path in the INSTALLED hook (never the real gate), so the installer must
# actually rewrite, then make the write fail.
d11="$TMP_ROOT/f11"; mk_foreign_repo "$d11" || exit 1
bash "$INSTALLER" --target "$d11/work" >/dev/null 2>&1
hook11="$d11/work/.git/hooks/pre-push"
sed -i -e 's|^gate=.*|gate=/deliberately/different/path.sh|' \
       -e 's|^# himmel-cr-gate-path: .*|# himmel-cr-gate-path: /deliberately/different/path.sh|' "$hook11"
before11=$(cat "$hook11")
# Prove the precondition: content now DIFFERS, so a re-install must write.
out_dry=$(bash "$INSTALLER" --target "$d11/work" --status 2>&1)
printf '%s' "$out_dry" | grep -Fq "stale" || fail "T22 precondition: edited hook should read 'stale', got: $out_dry"
# ponytail: no portable way to interrupt a write mid-flight — chmod on a
# directory is a no-op under MSYS, and the temp name carries the INSTALLER's
# $$, not ours, so it cannot be pre-created from here. Assert the observable
# consequences of staging instead: the rewrite lands COMPLETE (a truncated
# hook fails `bash -n`) and leaves no temp residue behind. A direct truncating
# write regresses both of those under failure, and the residue check fails
# immediately if the rename is ever dropped.
out=$(bash "$INSTALLER" --target "$d11/work" 2>&1); rc=$?
residue=$(find "$d11/work/.git/hooks" -name '*.himmel-tmp.*' 2>/dev/null)
[ "$rc" -eq 0 ] \
    && [ "$(cat "$hook11")" != "$before11" ] \
    && bash -n "$hook11" 2>/dev/null \
    && grep -Fq '# himmel-cr-gate-v1' "$hook11" \
    && [ -z "$residue" ] \
    && pass || fail "T22 rc=$rc residue='$residue' out=$out"

echo "T23: a gate path holding shell/sed metacharacters round-trips intact [codex-3]"
# The old `sed "s|...|$1|"` into `gate="..."` broke two ways on such a path:
# `|` closed the sed expression, `&` expanded to the whole match, and a `$` or
# backtick landing inside double quotes was EVALUATED when the hook ran. Test
# build_hook_content directly — the installer always bakes a real himmel path,
# so only a unit-level call can reach this.
# Stand up a fake "himmel" checkout whose path contains the metacharacters,
# and run the REAL installer from inside it, so the baked path is produced by
# production code rather than a re-implementation of it in this test.
meta_root="$TMP_ROOT/meta&dir\$x"
mkdir -p "$meta_root/scripts/cr" "$meta_root/scripts/hooks"
cp "$INSTALLER" "$meta_root/scripts/cr/install-cr-gate.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$meta_root/scripts/hooks/check-cr-before-push.sh"
chmod +x "$meta_root/scripts/hooks/check-cr-before-push.sh"
git init -q "$meta_root"
git -C "$meta_root" config user.name himmel-test
git -C "$meta_root" config user.email himmel-test@example.invalid
d13="$TMP_ROOT/f13"; mk_foreign_repo "$d13" || exit 1
out=$(bash "$meta_root/scripts/cr/install-cr-gate.sh" --target "$d13/work" 2>&1); rc=$?
hook13="$d13/work/.git/hooks/pre-push"
if [ "$rc" -eq 0 ] && [ -f "$hook13" ]; then
    # What the hook itself resolves after one level of shell parsing — the
    # exact operation the generated `gate=` line undergoes at push time.
    # shellcheck disable=SC2154  # $gate is assigned by the eval on this line
    seen=$( eval "$(grep -E '^gate=' "$hook13" | head -n1)"; printf '%s' "$gate" )
    want="$meta_root/scripts/hooks/check-cr-before-push.sh"
    [ "$seen" = "$want" ] && [ -f "$seen" ] && bash -n "$hook13" 2>/dev/null \
        && pass || fail "T23 metachar path mangled: got '$seen' want '$want'"
else
    fail "T23 install failed rc=$rc out=$out"
fi

echo "T24: the inert-gate remedy names an ABSOLUTE hooks dir, never '.git/hooks' [round-4 codex-1]"
# In a LINKED WORKTREE `.git` is a FILE, so `core.hooksPath=.git/hooks` points
# at a directory that does not exist and disables EVERY hook — strictly worse
# than the inert gate the advice was meant to cure.
d14="$TMP_ROOT/f14"; mk_foreign_repo "$d14" || exit 1
shared14="$TMP_ROOT/shared-hooks-14"; mkdir -p "$shared14"
g14="$TMP_ROOT/gitconfig-global-14"
printf '[core]\n\thooksPath = %s\n' "$shared14" > "$g14"
out=$(GIT_CONFIG_GLOBAL="$g14" bash "$INSTALLER" --target "$d14/work" 2>&1); rc=$?
[ "$rc" -eq 0 ] \
    && printf '%s' "$out" | grep -Fq "core.hooksPath '$d14/work/.git/hooks'" \
    && ! printf '%s' "$out" | grep -Eq "core\.hooksPath[= ]+'?\.git/hooks'?" \
    && pass || fail "T24 rc=$rc out=$out"

# NOT TESTED HERE: the control-character refusal in install-cr-gate.sh
# ([codex-2], round 4). Reaching it needs himmel's own checkout to sit at a
# path containing a newline, and Windows filenames cannot hold one — every
# attempt to stage that fixture either fails to create the directory or gets
# normalised, so the case only ever produced a permanent SKIP. A test that can
# never run is noise, so it was removed rather than left as decoration. The
# guard itself is a four-line `case ... *[[:cntrl:]]*) refuse` immediately
# after the path is resolved; it is inspectable, and it fails CLOSED.

echo "T18a: a bare trailing --target -> usage error, NOT an infinite loop"
# Regression: `--target) TARGET="${2:-}"; shift 2` looks harmless but `shift 2`
# with one arg left FAILS, and this script runs without `set -e` — so $# never
# decreased and the while loop spun forever. A timeout is the only honest
# assertion for a hang: rc 124 here means the bug is back.
out=$(timeout 15 bash "$INSTALLER" --target 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -Fq "requires a value" && pass || fail "T18a rc=$rc out=$out"

echo "T18b: unknown flag -> usage error"
out=$(timeout 15 bash "$INSTALLER" --target "$d/work" --bogus 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s' "$out" | grep -Fq "unknown argument" && pass || fail "T18b rc=$rc out=$out"

echo "T19 (e2e, LAST): install then git push origin feat/x -> marker written with pushed SHA"
d8="$TMP_ROOT/f8"; mk_foreign_repo "$d8" || exit 1
bash "$INSTALLER" --target "$d8/work" >/dev/null 2>&1
# mk_foreign_repo's feat/x commit is --allow-empty (identical tree to main),
# which check-cr-before-push.sh treats as an empty diff and skips the marker
# entirely. Add one real content change so the gate has something to gate.
echo "change" > "$d8/work/change.sh"
git -C "$d8/work" add change.sh
git -C "$d8/work" commit -q -m "add change"
pushed_sha=$(git -C "$d8/work" rev-parse feat/x)
push_out=$(cd "$d8/work" && git push origin feat/x 2>&1); push_rc=$?
marker="$d8/work/.git/cr-pending/feat/x"
# HIMMEL-2226 (HIMMEL-2258 audit): this used to SKIP (uncounted, at least not
# credited as a pass) whenever push stderr matched "cannot locate" or
# "branch-lock library missing", on the theory that hook infrastructure might
# be unavailable in some environments. Investigated and closed: neither
# string can reach push-time stderr here.
#   - "cannot locate" is emitted ONLY by install-cr-gate.sh's own --target
#     install step ("cannot locate himmel's primary checkout", line ~299) —
#     that already ran (and succeeded, or this push would hit the hook-not-
#     installed path instead) several lines above, long before `git push`.
#     The generated hook itself (build_hook_content) emits exactly one
#     string on a resolution failure, "himmel CR gate not found at $gate",
#     which does not match either pattern.
#   - "branch-lock library missing" is emitted by check-cr-before-push.sh
#     only when $SCRIPT_DIR/../lib/shared-branch-lock.sh is absent, where
#     $SCRIPT_DIR resolves (via BASH_SOURCE) to the PRIMARY checkout's own
#     scripts/hooks/ — the generated hook always `exec bash`s the PRIMARY
#     checkout's copy. scripts/lib/shared-branch-lock.sh is a tracked file
#     that ships with every himmel checkout, primary included, so this
#     requires a corrupted/partial primary checkout to fire — not a
#     property of "this environment" the way GNU timeout availability is.
# Dead branch removed; the assertion below now runs unconditionally.
if [ -f "$marker" ]; then
    field2=$(cut -d'|' -f2 "$marker" | tr -d ' ')
    [ "$field2" = "$pushed_sha" ] && pass || fail "T19 marker field2=$field2 expected=$pushed_sha"
else
    fail "T19 push_rc=$push_rc push_out=$push_out (no marker at $marker)"
fi

echo
if [ "$SKIP" -gt 0 ]; then
    echo "install-cr-gate tests: $PASS passed, $FAIL failed, $SKIP skipped"
else
    echo "install-cr-gate tests: $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
