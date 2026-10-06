#!/usr/bin/env bash
# Smoke test for scripts/cr/write-verdicts.sh (HIMMEL-2131).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/write-verdicts.sh"

fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: $3 — got '$1' want '$2'"; fail=1; }; }

tmp="$(mktemp -d -t write-verdicts.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
(
  cd "$repo" || exit 1
  git init -q -b main .
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  git commit -q --allow-empty -m init
)
git_dir="$repo/.git"

# 1. Valid write lands at the derived prior-blocking path with exact contents.
( cd "$repo" && printf 'VERDICT [x-1] = disproved\nVERDICT [codex-adv-2] = agreed\n' | bash "$SCRIPT" prior-blocking --branch t1 )
rc=$?
check "$rc" "0" "T1 rc"
check "$(cat "$git_dir/cr-prior-blocking/t1")" "VERDICT [x-1] = disproved
VERDICT [codex-adv-2] = agreed" "T1 contents"

# 2. aggregate vs prior-blocking path selection.
( cd "$repo" && printf 'VERDICT [coderabbit-3] = unaddressed\n' | bash "$SCRIPT" aggregate --branch t1 )
check "$?" "0" "T2 rc"
[ -f "$git_dir/cr-aggregate-verdicts/t1" ] || { echo "FAIL: T2 aggregate file missing"; fail=1; }
check "$(cat "$git_dir/cr-aggregate-verdicts/t1")" "VERDICT [coderabbit-3] = unaddressed" "T2 aggregate contents"
check "$(cat "$git_dir/cr-prior-blocking/t1")" "VERDICT [x-1] = disproved
VERDICT [codex-adv-2] = agreed" "T2 prior-blocking untouched by aggregate write"

# 3. Branch with '/' creates parent dirs.
( cd "$repo" && printf 'VERDICT [a-1] = conflict\n' | bash "$SCRIPT" prior-blocking --branch feat/himmel-2131/sub )
check "$?" "0" "T3 rc"
check "$(cat "$git_dir/cr-prior-blocking/feat/himmel-2131/sub")" "VERDICT [a-1] = conflict" "T3 contents"

# 4. Malformed line refuses rc=2 and leaves a pre-seeded target untouched.
# The diagnostic must carry the LINE NUMBER, never the offending line's
# content (HIMMEL-2131 round 2 — content could be a secret piped in by
# mistake), so assert the sentinel line text is ABSENT from stderr.
mkdir -p "$git_dir/cr-prior-blocking"
printf 'SENTINEL — do not overwrite' >"$git_dir/cr-prior-blocking/t4"
( cd "$repo" && printf 'VERDICT [x-1] = disproved\nnot a verdict line\n' | bash "$SCRIPT" prior-blocking --branch t4 ) 2>"$tmp/err4.txt"
rc=$?
check "$rc" "2" "T4 rc"
check "$(cat "$git_dir/cr-prior-blocking/t4")" "SENTINEL — do not overwrite" "T4 target untouched"
grep -q 'malformed verdict line at line 2' "$tmp/err4.txt" || { echo "FAIL: T4 missing line-numbered diagnostic"; fail=1; }
grep -q 'not a verdict line' "$tmp/err4.txt" && { echo "FAIL: T4 diagnostic leaked the offending line's content"; fail=1; }

# 4b. Path-escape refusal: '../../evil' must never resolve out of the
# git-common-dir's cr-prior-blocking/ tree (HIMMEL-2131 review round 1).
( cd "$repo" && printf 'VERDICT [x-1] = disproved\n' | bash "$SCRIPT" prior-blocking --branch "../../evil" ) 2>"$tmp/err4b.txt"
check "$?" "2" "T4b rc"
[ ! -e "$repo/evil" ] || { echo "FAIL: T4b escaped into $repo/evil"; fail=1; }
[ ! -e "$tmp/evil" ] || { echo "FAIL: T4b escaped into $tmp/evil"; fail=1; }
grep -q "'\\.\\.' path segment" "$tmp/err4b.txt" || { echo "FAIL: T4b missing '..'-segment diagnostic"; fail=1; }

# 4c. Drive-absolute branch refused (rc + diagnostic only — the refusal fires
# before any target path is built, so there is nothing on disk to assert
# against, and asserting a fixed path like /c/tmp/x not existing would depend
# on the test-runner's own filesystem state, codex-2 HIMMEL-2131 round 4).
( cd "$repo" && printf 'VERDICT [x-1] = disproved\n' | bash "$SCRIPT" prior-blocking --branch "C:/tmp/x" ) 2>"$tmp/err4c.txt"
check "$?" "2" "T4c rc"
grep -q 'drive-absolute' "$tmp/err4c.txt" || { echo "FAIL: T4c missing drive-absolute diagnostic"; fail=1; }

# 4d. `--branch` with no following value refuses rc=2 (codex-3) instead of a
# `set -u` unbound-variable crash.
( cd "$repo" && printf 'VERDICT [x-1] = disproved\n' | bash "$SCRIPT" prior-blocking --branch ) 2>"$tmp/err4d.txt"
check "$?" "2" "T4d rc"

# 4e. Symlink-through defense: a pre-planted symlink at the target must not
# be written through (codex-2, HIMMEL-2131 round 2) — the file it points to
# stays untouched. `ln -s` silently falls back to a plain copy without
# admin/Developer-Mode privilege on Windows (same probe idiom as
# scripts/ci/test-tmp-sweep.sh) — skip the assertion there rather than fail
# on an environment that cannot exercise it.
mkdir -p "$git_dir/cr-prior-blocking"
printf 'SENTINEL — do not overwrite via symlink' >"$tmp/symlink-victim.txt"
ln -s "$tmp/symlink-victim.txt" "$git_dir/cr-prior-blocking/t4e" 2>/dev/null
if [ -L "$git_dir/cr-prior-blocking/t4e" ]; then
  ( cd "$repo" && printf 'VERDICT [x-1] = disproved\n' | bash "$SCRIPT" prior-blocking --branch t4e ) 2>"$tmp/err4e.txt"
  check "$?" "2" "T4e rc"
  check "$(cat "$tmp/symlink-victim.txt")" "SENTINEL — do not overwrite via symlink" "T4e symlink target untouched"
  grep -q 'symlink' "$tmp/err4e.txt" || { echo "FAIL: T4e missing symlink diagnostic"; fail=1; }

  # 4f. Ancestor-component symlink (codex-3, HIMMEL-2131 round 4): the
  # planted symlink sits at cr-prior-blocking/walktest (a walked path
  # component, not the final target) — writing branch "walktest/x" must still
  # refuse. A distinct component name (not "feat", which T3 already created
  # as a real dir) avoids colliding with an earlier test's directory.
  mkdir -p "$tmp/walktest-victim-dir"
  ln -s "$tmp/walktest-victim-dir" "$git_dir/cr-prior-blocking/walktest"
  ( cd "$repo" && printf 'VERDICT [x-1] = disproved\n' | bash "$SCRIPT" prior-blocking --branch walktest/x ) 2>"$tmp/err4f.txt"
  check "$?" "2" "T4f rc"
  [ ! -e "$tmp/walktest-victim-dir/x" ] || { echo "FAIL: T4f wrote through the ancestor-component symlink"; fail=1; }
  grep -q 'symlink' "$tmp/err4f.txt" || { echo "FAIL: T4f missing symlink diagnostic"; fail=1; }
else
  rm -f "$git_dir/cr-prior-blocking/t4e"
  echo "SKIP T4e/T4f: platform cannot create symlinks without elevated privilege"
fi

# 5. Empty stdin writes an empty file, rc=0.
( cd "$repo" && printf '' | bash "$SCRIPT" prior-blocking --branch t5 )
check "$?" "0" "T5 rc"
[ -f "$git_dir/cr-prior-blocking/t5" ] || { echo "FAIL: T5 file missing"; fail=1; }
check "$(wc -c <"$git_dir/cr-prior-blocking/t5" | tr -d ' ')" "0" "T5 empty file"

# 6. Outside a repo refuses rc=3.
nonrepo="$tmp/nonrepo"; mkdir -p "$nonrepo"
( cd "$nonrepo" && printf 'VERDICT [x-1] = agreed\n' | bash "$SCRIPT" prior-blocking --branch t6 ) >/dev/null 2>"$tmp/err6.txt"
check "$?" "3" "T6 rc"
grep -q 'not a git repository' "$tmp/err6.txt" || { echo "FAIL: T6 missing not-a-repo diagnostic"; fail=1; }

# 7. --branch override wins over the current branch.
git -C "$repo" checkout -q -b t7-current
( cd "$repo" && printf 'VERDICT [b-1] = agreed\n' | bash "$SCRIPT" prior-blocking --branch t7-explicit )
check "$?" "0" "T7 rc"
[ -f "$git_dir/cr-prior-blocking/t7-explicit" ] || { echo "FAIL: T7 explicit-branch file missing"; fail=1; }
[ ! -e "$git_dir/cr-prior-blocking/t7-current" ] || { echo "FAIL: T7 wrote to the current branch instead of --branch"; fail=1; }

# 8. HIMMEL-2375: `deferred` with no ticket is REJECTED — untracked and
# indistinguishable from a free pass around conservation — whole-write
# refused (rc=2), pre-seeded target untouched, same as any other malformed
# line (T4).
mkdir -p "$git_dir/cr-prior-blocking"
printf 'SENTINEL — do not overwrite' >"$git_dir/cr-prior-blocking/t8"
( cd "$repo" && printf 'VERDICT [x-1] = deferred\n' | bash "$SCRIPT" prior-blocking --branch t8 ) 2>"$tmp/err8.txt"
check "$?" "2" "T8 rc (bare deferred rejected)"
check "$(cat "$git_dir/cr-prior-blocking/t8")" "SENTINEL — do not overwrite" "T8 target untouched"

# 9. HIMMEL-2375: `deferred -> <TICKET>` is accepted and round-trips
# byte-identical.
( cd "$repo" && printf 'VERDICT [x-1] = deferred -> HIMMEL-2375\n' | bash "$SCRIPT" prior-blocking --branch t9 )
check "$?" "0" "T9 rc (deferred with ticket accepted)"
check "$(cat "$git_dir/cr-prior-blocking/t9")" "VERDICT [x-1] = deferred -> HIMMEL-2375" "T9 contents"

# 10. HIMMEL-2375: a malformed ticket after 'deferred ->' still refuses —
# mirrors ledger-append.sh's valid_ticket() shape exactly.
( cd "$repo" && printf 'VERDICT [x-1] = deferred -> not-a-ticket\n' | bash "$SCRIPT" prior-blocking --branch t10 ) 2>"$tmp/err10.txt"
check "$?" "2" "T10 rc (malformed ticket rejected)"

# 11. HIMMEL-3798 round 3: --from-file reads verdict content from a path
# instead of stdin, round-tripping byte-identical.
printf 'VERDICT [x-1] = disproved\nVERDICT [codex-adv-2] = agreed\n' >"$tmp/ff11.txt"
( cd "$repo" && bash "$SCRIPT" prior-blocking --branch t11 --from-file "$tmp/ff11.txt" )
check "$?" "0" "T11 rc"
check "$(cat "$git_dir/cr-prior-blocking/t11")" "VERDICT [x-1] = disproved
VERDICT [codex-adv-2] = agreed" "T11 contents"

# 12. --from-file naming a missing path refuses rc=2, fails closed.
( cd "$repo" && bash "$SCRIPT" prior-blocking --branch t12 --from-file "$tmp/does-not-exist.txt" ) 2>"$tmp/err12.txt"
check "$?" "2" "T12 rc (missing --from-file path)"
[ ! -e "$git_dir/cr-prior-blocking/t12" ] || { echo "FAIL: T12 wrote a target for a missing --from-file path"; fail=1; }
grep -q 'does not exist' "$tmp/err12.txt" || { echo "FAIL: T12 missing not-exist diagnostic"; fail=1; }

# 13. --from-file naming a symlink refuses rc=2 without reading through it
# (same symlink-through concern as T4e, applied to the read side).
printf 'VERDICT [x-1] = agreed\n' >"$tmp/ff13-real.txt"
ln -s "$tmp/ff13-real.txt" "$tmp/ff13-link.txt" 2>/dev/null
if [ -L "$tmp/ff13-link.txt" ]; then
  ( cd "$repo" && bash "$SCRIPT" prior-blocking --branch t13 --from-file "$tmp/ff13-link.txt" ) 2>"$tmp/err13.txt"
  check "$?" "2" "T13 rc (symlinked --from-file path)"
  [ ! -e "$git_dir/cr-prior-blocking/t13" ] || { echo "FAIL: T13 wrote a target reading through a symlinked --from-file path"; fail=1; }
  grep -q 'symlink' "$tmp/err13.txt" || { echo "FAIL: T13 missing symlink diagnostic"; fail=1; }
else
  echo "SKIP T13: platform cannot create symlinks without elevated privilege"
fi

# 14. --from-file naming an unreadable path refuses rc=2, fails closed.
# Skip under a caller running as root (e.g. some CI containers), where mode
# bits do not block reads.
printf 'VERDICT [x-1] = agreed\n' >"$tmp/ff14.txt"
chmod 000 "$tmp/ff14.txt"
if [ "$(id -u)" != "0" ]; then
  ( cd "$repo" && bash "$SCRIPT" prior-blocking --branch t14 --from-file "$tmp/ff14.txt" ) 2>"$tmp/err14.txt"
  check "$?" "2" "T14 rc (unreadable --from-file path)"
  [ ! -e "$git_dir/cr-prior-blocking/t14" ] || { echo "FAIL: T14 wrote a target for an unreadable --from-file path"; fail=1; }
  grep -q 'not readable' "$tmp/err14.txt" || { echo "FAIL: T14 missing not-readable diagnostic"; fail=1; }
else
  echo "SKIP T14: running as root, mode bits do not block reads"
fi
chmod 644 "$tmp/ff14.txt"

# 15. HIMMEL-3798 round 4: --from-file naming a genuinely empty regular file
# is ALLOWED, same "no candidates" semantics as empty STDIN (T5) — it is the
# only sanctioned shape /pr-check can use for that case post-round-3-cut.
: >"$tmp/ff15.txt"
( cd "$repo" && bash "$SCRIPT" prior-blocking --branch t15 --from-file "$tmp/ff15.txt" ) 2>"$tmp/err15.txt"
check "$?" "0" "T15 rc (empty --from-file path)"
check "$(wc -c <"$git_dir/cr-prior-blocking/t15" | tr -d ' ')" "0" "T15 empty target file"

# 16. HIMMEL-4566: sweep mode APPENDS class-sweep records to
# cr-class-sweeps/<branch> (never truncates — a later round must not erase an
# earlier round's record), in both accepted shapes.
( cd "$repo" && printf 'SWEEP [codex-1@abc1234] class=unquoted path :: sites=a.sh:1, b.sh:4\n' | bash "$SCRIPT" sweep --branch feat/t16 )
check "$?" "0" "T16 rc (multi-site sweep)"
printf 'SWEEP [glm-2@abcdef0123] class=stale doc line :: single-site search=git grep -n stale docs/\n' >"$tmp/ff16.txt"
( cd "$repo" && bash "$SCRIPT" sweep --branch feat/t16 --from-file "$tmp/ff16.txt" )
check "$?" "0" "T16 rc (single-site sweep)"
check "$(cat "$git_dir/cr-class-sweeps/feat/t16")" "SWEEP [codex-1@abc1234] class=unquoted path :: sites=a.sh:1, b.sh:4
SWEEP [glm-2@abcdef0123] class=stale doc line :: single-site search=git grep -n stale docs/" "T16 appended contents"

# 17. A record that names one site with no backing search, no class, no head,
# or a VERDICT line refuses the whole write (rc=2) and leaves the file as it was.
for bad in 'SWEEP [codex-1@abc1234] class=x :: sites=a.sh:1' \
           'SWEEP [codex-1@abc1234] class= :: sites=a.sh:1, b.sh:2' \
           'SWEEP [codex-1] class=x :: sites=a.sh:1, b.sh:2' \
           'SWEEP [codex-1@abc1234] class=x :: single-site search=' \
           'VERDICT [codex-1] = agreed'; do
  ( cd "$repo" && printf 'SWEEP [ok-1@abc1234] class=x :: sites=a, b\n%s\n' "$bad" | bash "$SCRIPT" sweep --branch feat/t16 ) 2>/dev/null
  check "$?" "2" "T17 rc for '$bad'"
done
check "$(wc -l <"$git_dir/cr-class-sweeps/feat/t16" | tr -d ' ')" "2" "T17 sweep file untouched"

# 18. The verdict modes still refuse a SWEEP line.
( cd "$repo" && printf 'SWEEP [codex-1@abc1234] class=x :: sites=a, b\n' | bash "$SCRIPT" aggregate --branch t18 ) 2>/dev/null
check "$?" "2" "T18 rc (SWEEP line in aggregate mode)"

[ "$fail" -eq 0 ] && echo "PASS test-write-verdicts" || exit 1
