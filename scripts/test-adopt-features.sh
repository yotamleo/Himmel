#!/usr/bin/env bash
# test-adopt-features.sh — the second half of the adopt.sh smoke tests, split
# from scripts/test-adopt.sh so each stays well under the runner's per-suite
# time cap. Same fixture (scripts/lib/adopt-test-fixture.sh):
# stubs `claude` on PATH, throwaway temp dirs, a fake HOME.
#
# Covers the native git-gate placement scenarios (chained, foreign and
# symlinked hooks, the worktree and shared-payload gates, the pre-commit
# fallbacks), the provenance ledger and the himmel wizard suites.

# shellcheck disable=SC2154 # the fixture, sourced below, assigns work/adopt/pchome and the rest
set -euo pipefail

# shellcheck source=lib/adopt-test-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/adopt-test-fixture.sh"


# install_native_hooks() must
# not clobber a pre-existing hand-written hook, must stay idempotent about
# its OWN generated hooks, and must refuse an absolute/shared core.hooksPath
# rather than write dispatcher hooks into it (they resolve $(git rev-parse
# --show-toplevel) at FIRE time, so a hooksPath shared by other repos would
# break commits there the instant this repo adopts).

# 1. An existing hand-written hook is preserved, not truncated.
crtarget1="$work/cr2771-foreign"; crbin1="$work/cr2771-foreign-bin"
mkdir -p "$crtarget1" "$crbin1"
HOME="$pchome" git -C "$crtarget1" init -q
mkdir -p "$crtarget1/.git/hooks"
foreign_hook_content='#!/usr/bin/env bash
echo "ADOPTER OWN HOOK -- do not clobber me"
'
printf '%s' "$foreign_hook_content" > "$crtarget1/.git/hooks/commit-msg"
chmod +x "$crtarget1/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin1:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget1" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR foreign-hook: adopt exited $rc: $out"
[ -x "$crtarget1/.git/hooks/commit-msg" ] || fail "HIMMEL-2771 CR foreign-hook: native commit-msg hook absent"
grepq "$(cat "$crtarget1/.git/hooks/commit-msg")" 'HIMMEL-2771: native invariant gate' \
  || fail "HIMMEL-2771 CR foreign-hook: native hook was not written in place of the foreign one"
[ -f "$crtarget1/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR foreign-hook: no backup of the adopter's original hook"
diff <(printf '%s' "$foreign_hook_content") "$crtarget1/.git/hooks/commit-msg.himmel-backup" >/dev/null \
  || fail "HIMMEL-2771 CR foreign-hook: backup content does not match the original byte-for-byte"
grepq "$out" 'backed up to commit-msg.himmel-backup' \
  || fail "HIMMEL-2771 CR foreign-hook: missing the backup progress message"
echo "ok: HIMMEL-2771 CR foreign-hook is preserved as commit-msg.himmel-backup"

# 2. Idempotent re-adopt: running adopt TWICE on a clean target must not
# back up our own generated hook on the second run.
crtarget2="$work/cr2771-idempotent"; crbin2="$work/cr2771-idempotent-bin"
mkdir -p "$crtarget2" "$crbin2"
HOME="$pchome" git -C "$crtarget2" init -q
set +e
out=$(PATH="$crbin2:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget2" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR idempotent (run 1): adopt exited $rc: $out"
[ -x "$crtarget2/.git/hooks/commit-msg" ] || fail "HIMMEL-2771 CR idempotent (run 1): native hook absent"
[ ! -e "$crtarget2/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR idempotent (run 1): unexpected backup on a clean target"
set +e
out2=$(PATH="$crbin2:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget2" 2>&1); rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "HIMMEL-2771 CR idempotent (run 2): adopt exited $rc2: $out2"
[ -x "$crtarget2/.git/hooks/commit-msg" ] || fail "HIMMEL-2771 CR idempotent (run 2): native hook absent"
[ ! -e "$crtarget2/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR idempotent (run 2): re-adopt backed up its OWN previously-placed hook"
echo "ok: HIMMEL-2771 CR idempotent re-adopt creates no spurious backup"

# 3. An absolute/shared core.hooksPath OUTSIDE the target is refused, not
# written into -- this is the control that matters: asserting only the rc
# would not catch a write that happened before the refusal.
crtarget3="$work/cr2771-hookspath"; crbin3="$work/cr2771-hookspath-bin"
croutside3="$work/cr2771-hookspath-outside"
mkdir -p "$crtarget3" "$crbin3" "$croutside3"
HOME="$pchome" git -C "$crtarget3" init -q
HOME="$pchome" git -C "$crtarget3" config core.hooksPath "$croutside3"
set +e
out=$(PATH="$crbin3:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget3" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR hookspath-outside: adopt exited 0 with a shared/outside hooksPath"
grepq "$out" 'git gate hooks — FAILED (native:' \
  || fail "HIMMEL-2771 CR hookspath-outside: missing the FAILED summary line"
grepq "$out" 'core.hooksPath' \
  || fail "HIMMEL-2771 CR hookspath-outside: FAILED line does not name core.hooksPath"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside3" \
  || fail "HIMMEL-2771 CR hookspath-outside: a hook was written into the outside hooksPath dir"
echo "ok: HIMMEL-2771 CR hookspath-outside refuses to write into a shared/absolute hooksPath"

# 4. A pre-existing <hook>.himmel-backup is REFUSED, not overwritten. Silently
# clobbering it would destroy the adopter's real original -- the exact harm
# the backup exists to prevent -- so the only assertion that matters is that
# the prior backup survives byte-for-byte, not merely that adopt exited != 0.
crtarget4="$work/cr2771-backup-exists"; crbin4="$work/cr2771-backup-exists-bin"
mkdir -p "$crtarget4" "$crbin4"
HOME="$pchome" git -C "$crtarget4" init -q
mkdir -p "$crtarget4/.git/hooks"
prior_backup_content='#!/usr/bin/env bash
echo "THE ADOPTERS REAL ORIGINAL -- never destroy me"
'
printf '%s' "$foreign_hook_content" > "$crtarget4/.git/hooks/commit-msg"
chmod +x "$crtarget4/.git/hooks/commit-msg"
printf '%s' "$prior_backup_content" > "$crtarget4/.git/hooks/commit-msg.himmel-backup"
set +e
out=$(PATH="$crbin4:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget4" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR backup-exists: adopt exited 0 over an existing backup"
grepq "$out" 'already exists' \
  || fail "HIMMEL-2771 CR backup-exists: FAILED line does not name the existing backup"
diff <(printf '%s' "$prior_backup_content") "$crtarget4/.git/hooks/commit-msg.himmel-backup" >/dev/null \
  || fail "HIMMEL-2771 CR backup-exists: the adopter's prior backup was overwritten"
echo "ok: HIMMEL-2771 CR backup-exists refuses rather than destroying the prior backup"

# 5. A RELATIVE --target still gates. install_native_hooks() compares the
# resolved hooks dir against $TARGET, and --target is taken verbatim (never
# canonicalised at parse time), so a relative one reaches that comparison
# unanchored -- this is the end-to-end control over that path.
crrelbase="$work/cr2771-relbase"; crbin5="$work/cr2771-relbase-bin"
mkdir -p "$crrelbase/reltarget" "$crbin5"
HOME="$pchome" git -C "$crrelbase/reltarget" init -q
set +e
out=$( cd "$crrelbase" && PATH="$crbin5:$work/bin:$native_free_path" HOME="$pchome" \
  bash "$adopt" --profile core --scope project --target reltarget 2>&1 ); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR relative-target: adopt exited $rc: $out"
[ -x "$crrelbase/reltarget/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR relative-target: native commit-msg hook absent"
grepq "$(cat "$crrelbase/reltarget/.git/hooks/commit-msg")" 'HIMMEL-2771: native invariant gate' \
  || fail "HIMMEL-2771 CR relative-target: hook is not the native gate"
echo "ok: HIMMEL-2771 CR relative-target still places the native gate"

# _native_hooks_canon() used LOGICAL
# cd+pwd, so a core.hooksPath pointing at a path INSIDE the target that is
# itself a symlink to a directory OUTSIDE it was accepted as "inside" and the
# adopter wrote hooks THROUGH the symlink into the outside directory -- the
# exact shared-hooks-directory escape the round-1 containment check exists to
# prevent. Asserting only the rc would not catch a write that happened before
# the refusal, so assert the outside directory stays empty.
crtarget6="$work/cr2771r2-symlink"; crbin6="$work/cr2771r2-symlink-bin"
croutside6="$work/cr2771r2-symlink-outside"
mkdir -p "$crtarget6" "$crbin6" "$croutside6"
HOME="$pchome" git -C "$crtarget6" init -q
ln -s "$croutside6" "$crtarget6/hookslink"
HOME="$pchome" git -C "$crtarget6" config core.hooksPath hookslink
set +e
out=$(PATH="$crbin6:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget6" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR2 symlink-escape: adopt exited 0 with a hooksPath symlinked outside the target"
grepq "$out" 'git gate hooks — FAILED (native:' \
  || fail "HIMMEL-2771 CR2 symlink-escape: missing the FAILED summary line"
grepq "$out" 'core.hooksPath' \
  || fail "HIMMEL-2771 CR2 symlink-escape: FAILED line does not name core.hooksPath"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside6" \
  || fail "HIMMEL-2771 CR2 symlink-escape: a hook was written through the symlink into the outside dir"
echo "ok: HIMMEL-2771 CR2 symlink-escape refuses a hooksPath symlinked outside the target"

# _native_hooks_canon()'s walk-up reattaches
# the not-yet-existing tail of a hooksPath UNCHANGED, so a tail containing ".."
# was never folded -- the containment check then compared a string that still
# held "..", which `mkdir -p` resolves past $TARGET. A hooksPath shaped like
# "new/../../<outside>" reaches this: "new" does not exist, so the walk-up
# strips the whole tail back to the target and reattaches it verbatim. As with
# the round-2 symlink-escape control above, asserting only the rc would not
# catch a write that happened before the refusal, so assert the outside
# directory stays empty.
crtarget10="$work/cr2771r3-dotdot"; crbin10="$work/cr2771r3-dotdot-bin"
croutside10="$work/cr2771r3-dotdot-outside"
mkdir -p "$crtarget10" "$crbin10" "$croutside10"
HOME="$pchome" git -C "$crtarget10" init -q
HOME="$pchome" git -C "$crtarget10" config core.hooksPath 'new/../../cr2771r3-dotdot-outside'
set +e
out=$(PATH="$crbin10:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget10" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR3 dotdot-escape: adopt exited 0 with an unfolded ../.. hooksPath escaping the target"
grepq "$out" 'git gate hooks — FAILED (native:' \
  || fail "HIMMEL-2771 CR3 dotdot-escape: missing the FAILED summary line"
grepq "$out" 'core.hooksPath' \
  || fail "HIMMEL-2771 CR3 dotdot-escape: FAILED line does not name core.hooksPath"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside10" \
  || fail "HIMMEL-2771 CR3 dotdot-escape: a hook was written through the unfolded ../.. into the outside dir"
echo "ok: HIMMEL-2771 CR3 dotdot-escape refuses a hooksPath whose unfolded ../.. tail escapes the target"

# folding "." and ".." out of the
# not-yet-existing tail (the round-3 fix above) can RE-EXPOSE a symlink the
# walk-up never looked at. A hooksPath shaped "new/../hookslink" -- "new"
# absent, "hookslink" a symlink INSIDE the target pointing OUTSIDE it --
# reaches this: the walk-up strips the whole tail back to the target without
# ever seeing "hookslink" (it does not exist as a path component until the
# ".." fold puts it directly under the target), then the fold reattaches
# "hookslink" as a plain string that nothing ever resolves, so the
# containment check compares a string that never followed the symlink. As
# with the round-2 and round-3 controls above, asserting only the rc would
# not catch a write that happened before the refusal, so assert the outside
# directory stays empty.
crtarget11="$work/cr2771r4-dotdot-symlink"; crbin11="$work/cr2771r4-dotdot-symlink-bin"
croutside11="$work/cr2771r4-dotdot-symlink-outside"
mkdir -p "$crtarget11" "$crbin11" "$croutside11"
HOME="$pchome" git -C "$crtarget11" init -q
ln -s "$croutside11" "$crtarget11/hookslink"
HOME="$pchome" git -C "$crtarget11" config core.hooksPath 'new/../hookslink'
set +e
out=$(PATH="$crbin11:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget11" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: adopt exited 0 with a folded ../<symlink> hooksPath escaping the target"
grepq "$out" 'git gate hooks — FAILED (native:' \
  || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: missing the FAILED summary line"
grepq "$out" 'core.hooksPath' \
  || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: FAILED line does not name core.hooksPath"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside11" \
  || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: a hook was written through the re-exposed symlink into the outside dir"
echo "ok: HIMMEL-2771 CR4 dotdot-symlink-escape refuses a hooksPath whose ../ fold re-exposes a symlink out of the target"

# The containment check above
# refused an ORDINARY linked worktree outright -- its default hooks dir lives
# in the PRIMARY checkout's common git dir, outside $TARGET, with
# core.hooksPath UNSET (not misconfigured -- this is Git's own default
# layout, and himmel's own workflow mandates worktrees). Prove this on a real
# linked worktree: `git worktree add` needs a real HEAD, so commit
# --allow-empty first (same user.name/user.email/-c commit.gpgsign=false
# idiom as the push-block control above). RED against the pre-fix code =
# adopt exits 1 with the core.hooksPath FAILED line, naming a setting that
# was never set.
crprimary12="$work/cr2771r5-worktree-primary"; crwt12="$work/cr2771r5-worktree-wt"
crbin12="$work/cr2771r5-worktree-bin"
mkdir -p "$crprimary12" "$crbin12"
HOME="$pchome" git -C "$crprimary12" init -q
HOME="$pchome" git -C "$crprimary12" config user.name 'Native Test'
HOME="$pchome" git -C "$crprimary12" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crprimary12" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] worktree-default primary commit'
HOME="$pchome" git -C "$crprimary12" worktree add -q "$crwt12" -b cr2771r5-worktree-branch
effective_hooks_dir12=$(HOME="$pchome" git -C "$crwt12" rev-parse --git-path hooks)
case "$effective_hooks_dir12" in
  /*) : ;;
  *) effective_hooks_dir12="$crwt12/$effective_hooks_dir12" ;;
esac
set +e
out=$(PATH="$crbin12:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crwt12" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR5 worktree-default: adopt exited $rc on an ordinary linked worktree with core.hooksPath unset: $out"
grepq "$out" 'git gate hooks — placed (native' \
  || fail "HIMMEL-2771 CR5 worktree-default: missing the native placed summary line: $out"
for hook in commit-msg pre-commit pre-push; do
  [ -x "$effective_hooks_dir12/$hook" ] \
    || fail "HIMMEL-2771 CR5 worktree-default: $hook absent/non-executable in the worktree's effective hooks dir ($effective_hooks_dir12)"
done
echo "ok: HIMMEL-2771 CR5 worktree-default: adopt gates an ordinary linked worktree with core.hooksPath unset"

# The directory-level containment
# check cannot see a per-file SYMLINK escape -- $hooks_dir itself is
# legitimately inside the target; it is this one directory ENTRY that
# escapes. Shape (a): a DANGLING symlink at $hooks_dir/commit-msg bypasses the
# `-e` backup-need test entirely (a dangling symlink is not `-e`), so the
# subsequent `cat >` follows the link and creates a file OUTSIDE $TARGET. As
# with the containment controls above, asserting only rc would not catch a
# write that happened before/during the escape, so assert the outside
# directory stays empty AND that the hooks-dir entry is now a genuine regular
# file (not still a symlink) carrying the marker.
crtarget13="$work/cr2771r5-symlink-dangling"; crbin13="$work/cr2771r5-symlink-dangling-bin"
croutside13="$work/cr2771r5-symlink-dangling-outside"
mkdir -p "$crtarget13" "$crbin13" "$croutside13"
HOME="$pchome" git -C "$crtarget13" init -q
mkdir -p "$crtarget13/.git/hooks"
ln -s "$croutside13/pwned" "$crtarget13/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin13:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget13" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: adopt exited $rc: $out"
# pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside13" \
  || fail "HIMMEL-2771 CR5 symlink-dangling: a file was created outside the target through the dangling symlink"
[ -f "$crtarget13/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: hooks-dir entry is not a regular file after adopt"
[ ! -L "$crtarget13/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: hooks-dir entry is still a symlink after adopt"
grepq "$(cat "$crtarget13/.git/hooks/commit-msg")" 'HIMMEL-2771: native invariant gate' \
  || fail "HIMMEL-2771 CR5 symlink-dangling: replacement entry is not the native gate"
echo "ok: HIMMEL-2771 CR5 symlink-dangling: a dangling hook symlink is backed up (not followed) and replaced with a real file"

# shape (b) -- a symlink at
# $hooks_dir/commit-msg pointing at an OUTSIDE file that already carries our
# marker made the marker check (`grep -qF`, which follows the link) look like
# "already ours" and skip the backup, so the subsequent `cat >` truncated a
# file OUTSIDE $TARGET. Assert the outside file survives byte-for-byte (its
# distinctive sentinel line, not just its existence) and that the hooks-dir
# entry is now a genuine regular file.
crtarget14="$work/cr2771r5-symlink-marker"; crbin14="$work/cr2771r5-symlink-marker-bin"
croutside14="$work/cr2771r5-symlink-marker-outside.sh"
mkdir -p "$crtarget14" "$crbin14"
HOME="$pchome" git -C "$crtarget14" init -q
mkdir -p "$crtarget14/.git/hooks"
sentinel14='echo "SENTINEL cr2771r5-symlink-marker: outside file must not be truncated"'
markerline14='# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.'
cat > "$croutside14" <<OUTSIDEHOOK
#!/usr/bin/env bash
$markerline14
$sentinel14
OUTSIDEHOOK
chmod +x "$croutside14"
ln -s "$croutside14" "$crtarget14/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin14:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget14" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR5 symlink-marker: adopt exited $rc: $out"
grepq "$(cat "$croutside14")" -F "$sentinel14" \
  || fail "HIMMEL-2771 CR5 symlink-marker: outside file was truncated (sentinel line missing)"
[ -f "$crtarget14/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-marker: hooks-dir entry is not a regular file after adopt"
[ ! -L "$crtarget14/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-marker: hooks-dir entry is still a symlink after adopt"
echo "ok: HIMMEL-2771 CR5 symlink-marker: a symlink to a marker-bearing outside file is backed up (not followed) and replaced with a real file"

# The earlier fix above teaches
# adopt to ACCEPT the shared Git common-directory hooks layout, but the
# payload (scripts/hooks/*.sh + guardrails/lib.sh) was copied only into
# $TARGET (the linked worktree). Git's hooks are per-REPOSITORY, not
# per-worktree, so that one hooks dir also serves the PRIMARY checkout (and
# any sibling worktree) -- neither of which received a payload. Their shared
# dispatcher resolves `$root/scripts/hooks/<script>` against ITS OWN
# toplevel (the primary, not the adopted worktree), finds nothing, and every
# commit/push there starts failing with a bash "No such file or directory"
# error -- an earlier version traded a false refusal for a real breakage of a checkout
# the adopter never named. Drive the PRIMARY's own commit-msg dispatcher
# directly rather than `git commit`: the pre-commit dispatcher fires too on
# a real commit, and check-worktree-isolation.sh legitimately refuses
# commits on the primary's default branch, which would make RED and GREEN
# indistinguishable (both would fail).
#
# The cwd trap: the dispatcher does `root=$(git rev-parse --show-toplevel)`.
# Git sets cwd to the repo toplevel when IT fires a hook, but here the hook
# is invoked by hand, so an un-pinned cwd would still be THIS himmel
# worktree -- which DOES carry scripts/hooks/check-commit-msg.sh -- and the
# control would pass against the broken code for the wrong reason. Pin cwd
# to the primary with a subshell.
crprimary15="$work/cr2771r6-worktree-primary"; crwt15="$work/cr2771r6-worktree-wt"
crbin15="$work/cr2771r6-worktree-bin"
mkdir -p "$crprimary15" "$crbin15"
HOME="$pchome" git -C "$crprimary15" init -q
HOME="$pchome" git -C "$crprimary15" config user.name 'Native Test'
HOME="$pchome" git -C "$crprimary15" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crprimary15" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] worktree-primary-gate primary commit'
HOME="$pchome" git -C "$crprimary15" worktree add -q "$crwt15" -b cr2771r6-worktree-branch
set +e
out=$(PATH="$crbin15:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crwt15" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR6 worktree-primary-gate: adopt exited $rc against the linked worktree: $out"

msgfile15="$work/cr2771r6-valid.msg"
printf 'test: HIMMEL-2771 [#2771] worktree-primary-gate valid message\n' > "$msgfile15"
set +e
pout15=$( cd "$crprimary15" && HOME="$pchome" bash .git/hooks/commit-msg "$msgfile15" 2>&1 ); prc15=$?
set -e
[ "$prc15" -eq 0 ] \
  || fail "HIMMEL-2771 CR6 worktree-primary-gate: PRIMARY's commit-msg dispatcher rejected a valid ticketed message (rc=$prc15): $pout15"
grepq "$pout15" 'No such file or directory' \
  && fail "HIMMEL-2771 CR6 worktree-primary-gate: PRIMARY's dispatcher hit the missing-script error: $pout15"

msgfile15b="$work/cr2771r6-noticket.msg"
printf 'no ticket here at all\n' > "$msgfile15b"
set +e
pout15b=$( cd "$crprimary15" && HOME="$pchome" bash .git/hooks/commit-msg "$msgfile15b" 2>&1 ); prc15b=$?
set -e
[ "$prc15b" -ne 0 ] \
  || fail "HIMMEL-2771 CR6 worktree-primary-gate: an unticketed message exited 0 in the PRIMARY -- the gate did not actually run: $pout15b"
echo "ok: HIMMEL-2771 CR6 worktree-primary-gate: the PRIMARY checkout's shared dispatcher finds its payload copy and genuinely gates"

# direct self-test of
# dir_is_empty itself, because every containment control above -- including
# the round-5 cr2771r5-symlink-dangling control, whose whole SUBJECT is a
# dangling symlink -- trusts this helper's verdict. `[ -e "$f" ]` alone
# follows a symlink to test its TARGET, so a dangling symlink is `-e` false
# and was silently skipped: if the escape those controls guard against ever
# landed as a dangling link, this helper would report the directory empty
# while the escape happened. RED against the pre-fix helper = it reports the
# dangling-symlink directory empty.
cr2771r6dirempty="$work/cr2771r6-dir-is-empty-dangling"
# Two SEPARATE directories, not one shared parent: a dangling symlink sitting
# alongside a genuinely-existing entry (e.g. the plain-empty dir itself) would
# still make the parent report non-empty via that OTHER entry, masking the
# very bug this control exists to catch. The dangling-holder directory must
# contain the dangling symlink and NOTHING else.
mkdir -p "$cr2771r6dirempty/dangling-holder" "$cr2771r6dirempty/plain-empty"
ln -s "$cr2771r6dirempty/plain-empty/nonexistent-target" "$cr2771r6dirempty/dangling-holder/dangling"
if dir_is_empty "$cr2771r6dirempty/dangling-holder"; then
  fail "HIMMEL-2771 CR6 dir-is-empty-dangling: dir_is_empty reported a directory containing only a dangling symlink as empty"
fi
dir_is_empty "$cr2771r6dirempty/plain-empty" \
  || fail "HIMMEL-2771 CR6 dir-is-empty-dangling: dir_is_empty reported a genuinely empty directory as non-empty"
echo "ok: HIMMEL-2771 CR6 dir-is-empty-dangling: dir_is_empty sees a dangling symlink as an occupied entry and a genuinely empty dir as empty"

# A pre-existing foreign hook is backed up
# to <hook>.himmel-backup but the generated dispatcher never ran it again, so
# the adopter's own gate was silently disabled. This is the control that
# matters -- it proves enforcement was preserved, not merely that a file was
# kept: a presence-only assertion on .himmel-backup would pass today while
# the check is dead.
crtarget7="$work/cr2771r2-chain-fails"; crbin7="$work/cr2771r2-chain-fails-bin"
mkdir -p "$crtarget7" "$crbin7"
HOME="$pchome" git -C "$crtarget7" init -q
mkdir -p "$crtarget7/.git/hooks"
HOME="$pchome" git -C "$crtarget7" checkout -q -b feat/native-test
cat > "$crtarget7/.git/hooks/commit-msg" <<'FOREIGNHOOK'
#!/usr/bin/env bash
echo "ADOPTER HOOK REFUSES EVERYTHING" >&2
exit 1
FOREIGNHOOK
chmod +x "$crtarget7/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin7:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget7" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR2 chain-fails: adopt exited $rc: $out"
[ -f "$crtarget7/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR2 chain-fails: backup absent"
HOME="$pchome" git -C "$crtarget7" config user.name 'Native Test'
HOME="$pchome" git -C "$crtarget7" config user.email 'native@example.invalid'
set +e
cout=$(HOME="$pchome" git -C "$crtarget7" -c commit.gpgsign=false commit --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] chained backup fails' 2>&1); crc=$?
set -e
[ "$crc" -ne 0 ] \
  || fail "HIMMEL-2771 CR2 chain-fails: an otherwise-valid ticketed commit LANDED even though the adopter's backed-up hook refuses everything"
! git -C "$crtarget7" rev-parse --verify HEAD >/dev/null 2>&1 \
  || fail "HIMMEL-2771 CR2 chain-fails: refused commit created HEAD"
echo "ok: HIMMEL-2771 CR2 chain-fails: a chained backup hook can still fail the operation"

# The flip side of chain-fails -- a chained backup
# hook that PASSES must not break the himmel gate itself (no double-negative,
# no rc-mangling that turns a real himmel-gate refusal into a pass).
crtarget8="$work/cr2771r2-chain-passes"; crbin8="$work/cr2771r2-chain-passes-bin"
mkdir -p "$crtarget8" "$crbin8"
HOME="$pchome" git -C "$crtarget8" init -q
mkdir -p "$crtarget8/.git/hooks"
HOME="$pchome" git -C "$crtarget8" checkout -q -b feat/native-test
cat > "$crtarget8/.git/hooks/commit-msg" <<FOREIGNHOOK2
#!/usr/bin/env bash
echo ran >> "$crtarget8/adopter-hook-ran"
exit 0
FOREIGNHOOK2
chmod +x "$crtarget8/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin8:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget8" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR2 chain-passes: adopt exited $rc: $out"
[ -f "$crtarget8/.git/hooks/commit-msg.himmel-backup" ] \
  || fail "HIMMEL-2771 CR2 chain-passes: backup absent"
HOME="$pchome" git -C "$crtarget8" config user.name 'Native Test'
HOME="$pchome" git -C "$crtarget8" config user.email 'native@example.invalid'
set +e
cout=$(HOME="$pchome" git -C "$crtarget8" -c commit.gpgsign=false commit --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] chained backup passes' 2>&1); crc=$?
set -e
[ "$crc" -eq 0 ] || fail "HIMMEL-2771 CR2 chain-passes: ticketed commit refused even though both gates pass: $cout"
git -C "$crtarget8" rev-parse --verify HEAD >/dev/null \
  || fail "HIMMEL-2771 CR2 chain-passes: ticketed commit did not create HEAD"
[ -f "$crtarget8/adopter-hook-ran" ] \
  || fail "HIMMEL-2771 CR2 chain-passes: adopter's backed-up hook never ran"
set +e
cout2=$(HOME="$pchome" git -C "$crtarget8" -c commit.gpgsign=false commit --allow-empty \
  -m 'no ticket here at all' 2>&1); crc2=$?
set -e
[ "$crc2" -ne 0 ] \
  || fail "HIMMEL-2771 CR2 chain-passes: unticketed commit landed -- himmel gate was masked by the passing backup hook: $cout2"
echo "ok: HIMMEL-2771 CR2 chain-passes: a passing chained backup hook does not break the himmel gate"

# git feeds pre-push its ref list on
# STDIN, and running the himmel gate (which drains stdin -- see
# check-push-target.sh's own header) before the backup left the backup
# reading an already-drained, EOF stdin. A backed-up hook whose refusal
# depends on the ref stream (the realistic shape -- check-push-target.sh
# itself decides this way) would then see zero ref lines and fall through to
# exit 0 regardless of what it should have refused. presence/rc-only checks
# on the hook file do not catch this (a probe against the pre-fix payload
# showed exactly that fallthrough); only a REAL `git push` supplies git's own
# ref-stream protocol, so this control drives one against a real remote.
crtarget9="$work/cr2771r2-push-block"; crbin9="$work/cr2771r2-push-block-bin"
crremote9="$work/cr2771r2-push-block-remote.git"
mkdir -p "$crtarget9" "$crbin9"
HOME="$pchome" git init -q --bare "$crremote9"
HOME="$pchome" git -C "$crtarget9" init -q
mkdir -p "$crtarget9/.git/hooks"
HOME="$pchome" git -C "$crtarget9" checkout -q -b feat/native-test
out=$(PATH="$crbin9:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget9" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "HIMMEL-2771 CR2 push-block: adopt exited $rc: $out"
[ -x "$crtarget9/.git/hooks/pre-push" ] \
  || fail "HIMMEL-2771 CR2 push-block: no native pre-push hook was installed"
# No pre-existing pre-push hook here for adopt to back up (that mechanic is
# already covered by chain-fails/chain-passes above) -- plant the "adopter's
# own hook" directly as .himmel-backup, the exact file the dispatcher chains
# to. It refuses a push whose DESTINATION ref is refs/heads/protected, a
# decision that requires actually reading the ref stream, so a drained stdin
# is indistinguishable from "nothing pushed" and the hook would wrongly allow
# it -- unlike a stub that always/never refuses regardless of stdin content.
cat > "$crtarget9/.git/hooks/pre-push.himmel-backup" <<'FOREIGNPUSHHOOK'
#!/usr/bin/env bash
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in
    refs/heads/protected)
      echo "ADOPTER PRE-PUSH HOOK REFUSES protected" >&2
      exit 1
      ;;
  esac
done
exit 0
FOREIGNPUSHHOOK
chmod +x "$crtarget9/.git/hooks/pre-push.himmel-backup"
HOME="$pchome" git -C "$crtarget9" config user.name 'Native Test'
HOME="$pchome" git -C "$crtarget9" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crtarget9" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2771 [#2771] push-block probe commit'
HOME="$pchome" git -C "$crtarget9" remote add origin "$crremote9"
set +e
pout=$(HOME="$pchome" git -C "$crtarget9" push origin feat/native-test:refs/heads/protected 2>&1); prc=$?
set -e
[ "$prc" -ne 0 ] \
  || fail "HIMMEL-2771 CR2 push-block: a REAL git push landed even though the chained backup hook refuses this ref (drained-stdin regression): $pout"
grepq "$pout" 'ADOPTER PRE-PUSH HOOK REFUSES protected' \
  || fail "HIMMEL-2771 CR2 push-block: push was refused but not by the adopter's chained backup hook: $pout"
! HOME="$pchome" git -C "$crremote9" rev-parse --verify refs/heads/protected >/dev/null 2>&1 \
  || fail "HIMMEL-2771 CR2 push-block: remote has refs/heads/protected even though the push was refused"
echo "ok: HIMMEL-2771 CR2 push-block: a chained pre-push backup hook blocks a real git push"

# --skip-hooks: pre-commit is never invoked.
: > "$work/pre-commit.argv"
pctarget19b2="$work/pctarget19b2"; mkdir -p "$pctarget19b2"
( cd "$pctarget19b2" && HOME="$pchome" git init -q )
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b2" --skip-hooks 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 --skip-hooks: adopt should exit 0 (got $rc): $out"
[ ! -s "$work/pre-commit.argv" ] || fail "HIMMEL-2441 --skip-hooks: pre-commit stub was invoked (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" 'git hooks: skipped (--skip-hooks)' \
  || fail "HIMMEL-2441 --skip-hooks: missing the skip message (got: $out)"
echo "ok: HIMMEL-2441 --skip-hooks opts out, pre-commit never invoked"

# non-git target: no .git in $TARGET -> skip, pre-commit never invoked.
: > "$work/pre-commit.argv"
pctarget19b3="$work/pctarget19b3"; mkdir -p "$pctarget19b3"
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b3" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 non-git target: adopt should exit 0 (got $rc): $out"
[ ! -s "$work/pre-commit.argv" ] || fail "HIMMEL-2441 non-git target: pre-commit stub was invoked (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" 'git hooks: skipping (' \
  || fail "HIMMEL-2441 non-git target: missing the non-git skip message (got: $out)"
echo "ok: HIMMEL-2441 non-git \$TARGET skips git-hooks install, pre-commit never invoked"

# --dry-run: prints the DRY line, pre-commit never invoked.
: > "$work/pre-commit.argv"
pctarget19b4="$work/pctarget19b4"; mkdir -p "$pctarget19b4"
( cd "$pctarget19b4" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b4/.pre-commit-config.yaml"  # HIMMEL-3306: the framework path is for an adopter with a config
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b4" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 --dry-run: adopt should exit 0 (got $rc): $out"
[ ! -s "$work/pre-commit.argv" ] || fail "HIMMEL-2441 --dry-run: pre-commit stub was invoked (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" "DRY: (cd $pctarget19b4 && pre-commit install --allow-missing-config" \
  || fail "HIMMEL-2441 --dry-run: missing the DRY git-hooks line (got: $out)"
echo "ok: HIMMEL-2441 --dry-run prints the git-hooks DRY line, pre-commit never invoked"

# framework hook installation failure falls back to native gates.
cat > "$pcbin/pre-commit" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$work/pre-commit.argv"
exit 1
STUB
chmod +x "$pcbin/pre-commit"
: > "$work/pre-commit.argv"
pctarget19b5="$work/pctarget19b5"; mkdir -p "$pctarget19b5"
( cd "$pctarget19b5" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b5/.pre-commit-config.yaml"  # HIMMEL-3306: the framework path is for an adopter with a config
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b5" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 install-fails: adopt must exit 0 (WARN-not-fail), got rc=$rc: $out"
grepq "$out" 'WARNING: git hook install failed' \
  || fail "HIMMEL-2441 install-fails: missing the WARNING message (got: $out)"
grepq "$out" "git gate hooks — placed (native, no pre-commit framework: lint hooks absent)" \
  || fail "HIMMEL-2771 install-fails: native fallback absent"
echo "ok: HIMMEL-2771 failing pre-commit install falls back to native gates (rc=0)"

# A real `uv tool install pre-commit`
# can succeed while its bin dir isn't on PATH yet -- prove adopt.sh resolves
# the bootstrapped binary to an absolute path instead of trusting a bare
# `pre-commit` call that would silently miss it. No real pre-commit anywhere
# on PATH (pc_free_path additionally scrubs any dir carrying one, on top of
# the suite-wide qmd/bun/npm/node/uv/pipx scrub); a stubbed `uv` on PATH
# answers `tool install pre-commit --quiet` by writing an argv-logging
# `pre-commit` into $HOME/.local/bin — the UV_TOOL_BIN_DIR default — which is
# deliberately NOT added to PATH, so `command -v pre-commit` still fails
# after the "install" and adopt.sh must fall back to the candidate bin dir.
pc_free_path=$(scrub_path "$qmd_free_path" pre-commit)
uvbin="$work/uvbin"; mkdir -p "$uvbin"
cat > "$uvbin/uv" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "tool" ] && [ "$2" = "install" ] && [ "$3" = "pre-commit" ]; then
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/pre-commit" <<'INNER'
#!/usr/bin/env bash
echo "$*" >> "$HOME/pre-commit-2483.argv"
exit 0
INNER
  chmod +x "$HOME/.local/bin/pre-commit"
  exit 0
fi
exit 1
STUB
chmod +x "$uvbin/uv"
rm -f "$pchome/pre-commit-2483.argv" "$pchome/.local/bin/pre-commit"
pctarget19b6="$work/pctarget19b6"; mkdir -p "$pctarget19b6"
( cd "$pctarget19b6" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b6/.pre-commit-config.yaml"  # HIMMEL-3306: the framework path is for an adopter with a config
set +e
out=$(PATH="$uvbin:$work/bin:$pc_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b6" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441/2483 PATH-less bootstrap: adopt should exit 0 (got $rc): $out"
[ -f "$pchome/pre-commit-2483.argv" ] \
  || fail "HIMMEL-2441/2483 PATH-less bootstrap: bootstrapped pre-commit in \$HOME/.local/bin was never invoked (got: $out)"
grepq "$(cat "$pchome/pre-commit-2483.argv")" \
  'install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push' \
  || fail "HIMMEL-2441/2483 PATH-less bootstrap: pre-commit install was not invoked with all 3 hook types (argv: $(cat "$pchome/pre-commit-2483.argv"))"
grepq "$out" 'git hooks installed (pre-commit, commit-msg, pre-push).' \
  || fail "HIMMEL-2441/2483 PATH-less bootstrap: missing the git-hooks-installed message (got: $out)"
echo "ok: HIMMEL-2441/2483 a PATH-less uv bootstrap still resolves pre-commit to an absolute path"

# Clean up the PATH-less-bootstrap fixture so it cannot affect any later
# scenario — none of this is on the ambient exported PATH.
rm -f "$pchome/pre-commit-2483.argv" "$pchome/.local/bin/pre-commit"
rmdir "$pchome/.local/bin" "$pchome/.local" 2>/dev/null || true

# --dry-run must describe the
# planned pre-commit install regardless of host state. No real pre-commit
# anywhere (reuses $uvbin/$pc_free_path from the row above) and a uv stub
# present -- in --dry-run the bootstrap's own `run uv tool install ...` never
# actually executes the stub (it just prints its DRY: line), so resolution
# afterward necessarily finds nothing real either. adopt.sh must still print
# the planned `pre-commit install` DRY: line (literal name) instead of
# WARNing and going silent -- the plan is what matters in dry-run, not
# whether the plan's binary actually exists yet.
pctarget19b7="$work/pctarget19b7"; mkdir -p "$pctarget19b7"
( cd "$pctarget19b7" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b7/.pre-commit-config.yaml"  # HIMMEL-3306: the framework path is for an adopter with a config
rm -f "$pchome/pre-commit-2483.argv" "$pchome/.local/bin/pre-commit"
set +e
out=$(PATH="$uvbin:$work/bin:$pc_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b7" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441/2483 --dry-run PATH-less: adopt should exit 0 (got $rc): $out"
[ ! -f "$pchome/pre-commit-2483.argv" ] \
  || fail "HIMMEL-2441/2483 --dry-run PATH-less: pre-commit stub was invoked during --dry-run (argv: $(cat "$pchome/pre-commit-2483.argv"))"
grepq "$out" 'DRY: uv tool install pre-commit' \
  || fail "HIMMEL-2441/2483 --dry-run PATH-less: missing the uv bootstrap DRY line (got: $out)"
grepq "$out" "DRY: (cd $pctarget19b7 && pre-commit install --allow-missing-config" \
  || fail "HIMMEL-2441/2483 --dry-run PATH-less: missing the planned pre-commit install DRY line (got: $out)"
echo "ok: HIMMEL-2441/2483 --dry-run describes the planned pre-commit install even when resolution finds nothing"

rm -f "$pchome/pre-commit-2483.argv" "$pchome/.local/bin/pre-commit"
rmdir "$pchome/.local/bin" "$pchome/.local" 2>/dev/null || true

# no installer can run in dry-run; describe both framework
# bootstrap and the native fallback without writing any hooks.
pctarget19b8="$work/pctarget19b8"; mkdir -p "$pctarget19b8"
( cd "$pctarget19b8" && HOME="$pchome" git init -q )
printf 'repos: []\n' > "$pctarget19b8/.pre-commit-config.yaml"  # HIMMEL-3306: the framework path is for an adopter with a config
set +e
out=$(PATH="$work/bin:$pc_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b8" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441/2483 --dry-run no-tool-at-all: adopt should exit 0 (got $rc): $out"
grepq "$out" "DRY: place executable native commit-msg, pre-commit, pre-push hooks" \
  || fail "HIMMEL-2771 --dry-run: missing native placement plan (got: $out)"
[ ! -e "$pctarget19b8/.git/hooks/commit-msg" ] || fail "HIMMEL-2771 --dry-run: wrote native hook"
grepq "$out" "DRY: (cd $pctarget19b8 && pre-commit install --allow-missing-config" \
  || fail "HIMMEL-2441/2483 --dry-run no-tool-at-all: missing the planned pre-commit install DRY line (got: $out)"
echo "ok: HIMMEL-2771 --dry-run prints framework and native plans without placing hooks"

# Remove the stub so it cannot affect any later scenario in this file — $pcbin
# was only ever added to PATH via a per-invocation prefix above (never
# exported), so this is belt-and-braces, not load-bearing.
rm -f "$pcbin/pre-commit"

# ── 19c. plugin failure must not leave an adopter ungated ───────
# A second claude stub shadows the suite's successful one only for these runs.
# Empty plugin-list output models a failed install, not an already-installed
# plugin (whose nonzero install status is legitimately tolerated).
failurebin="$work/plugin-failure-bin"; mkdir -p "$failurebin"
cat > "$failurebin/claude" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = plugin ] && [ "$2" = install ]; then
  echo 'PLUGIN_INSTALL_FAILURE_STUB' >&2
  exit 1
fi
exit 0
STUB
cat > "$failurebin/pre-commit" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$PWD" "\$*" >> "$work/plugin-failure-hooks.argv"
exit 0
STUB
chmod +x "$failurebin/claude" "$failurebin/pre-commit"
for hook_mode in default skip; do
  failuretarget="$work/plugin-failure-$hook_mode"
  failurehome="$work/plugin-failure-home-$hook_mode"
  mkdir -p "$failuretarget" "$failurehome"
  ( cd "$failuretarget" && HOME="$failurehome" git init -q )
  # This block is about ordering (hooks before plugins), so it takes the
  # framework path -- that needs the adopter's own config (no-config = 19d).
  [ "$hook_mode" = skip ] || : > "$failuretarget/.pre-commit-config.yaml"
  : > "$work/plugin-failure-hooks.argv"
  hook_args=()
  [ "$hook_mode" != skip ] || hook_args+=(--skip-hooks)
  set +e
  out=$(PATH="$failurebin:$work/bin:$qmd_free_path" HOME="$failurehome" bash "$adopt" \
        --profile core --scope project --target "$failuretarget" ${hook_args[@]+"${hook_args[@]}"} 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "HIMMEL-2818 $hook_mode: plugin failure must abort adopt"
  grepq "$out" 'PLUGIN_INSTALL_FAILURE_STUB' \
    || fail "HIMMEL-2818 $hook_mode: failing plugin install was not reached: $out"
  grepq "$out" 'plugin(s) not present after install:' \
    || fail "HIMMEL-2818 $hook_mode: missing fatal plugin verification diagnostic: $out"
  if [ "$hook_mode" = default ]; then
    grep -qxF "$failuretarget" "$work/plugin-failure-hooks.argv" \
      || fail "HIMMEL-2818 default: hooks were not installed in the target before plugin failure"
    grep -qxF 'install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push' \
      "$work/plugin-failure-hooks.argv" \
      || fail "HIMMEL-2818 default: hook install must include all three gate types"
    plugin_header='──── Installing plugins (--scope project) ────'
    grepq "$out" -F "$plugin_header" \
      || fail "HIMMEL-2818 default: missing plugin install section"
    before_plugins=${out%%"$plugin_header"*}
    grepq "$before_plugins" -F 'git hooks installed (pre-commit, commit-msg, pre-push).' \
      || fail "HIMMEL-2818 default: hooks must be installed BEFORE the plugin section"
  else
    [ ! -s "$work/plugin-failure-hooks.argv" ] \
      || fail "HIMMEL-2818 skip: --skip-hooks must not invoke pre-commit"
    for hook in pre-commit commit-msg pre-push; do
      [ ! -e "$failuretarget/.git/hooks/$hook" ] \
        || fail "HIMMEL-2818 skip: --skip-hooks placed $hook despite the opt-out"
    done
  fi
  echo "ok: HIMMEL-2818 $hook_mode: plugin failure stays fatal and hook placement respects the opt-out"
done

# gap 1 (mirror of cr2771r6-worktree-primary-gate, reversed): adopt
# the PRIMARY checkout itself -- its resolved hooks dir is `$TARGET/.git/hooks`,
# INSIDE $TARGET -- and only THEN add a SIBLING worktree, with no re-run of
# adopt.sh against it. Pre-fix, install_native_hooks() keyed the fallback
# payload decision on containment ("hooks dir inside $TARGET => no payload
# needed"), true here even though this is Git's ONE per-repository hooks dir
# that the sibling worktree shares. RED against the pre-fix code = the
# sibling's dispatcher (same physical script file; only $root at fire-time
# differs) finds neither $root/scripts/hooks (the branch it was created from
# carries no tree copy) nor a payload, and refuses every commit with the
# "not found ... re-run adopt.sh" message instead of genuinely gating.
crprimaryG1="$work/cr2814g1-primary"; crwtG1="$work/cr2814g1-wt"
crbinG1="$work/cr2814g1-bin"
mkdir -p "$crprimaryG1" "$crbinG1"
HOME="$pchome" git -C "$crprimaryG1" init -q
HOME="$pchome" git -C "$crprimaryG1" config user.name 'Native Test'
HOME="$pchome" git -C "$crprimaryG1" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crprimaryG1" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2814 [#2814] gap1 primary commit'
set +e
out=$(PATH="$crbinG1:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crprimaryG1" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload: adopt exited $rc against the PRIMARY checkout: $out"
[ -x "$crprimaryG1/.git/hooks/himmel-payload/scripts/hooks/check-commit-msg.sh" ] \
  || fail "HIMMEL-2814 gap1 shared-payload: no fallback payload was left beside the PRIMARY's own (shared) hooks dir"
[ -f "$crprimaryG1/.git/hooks/himmel-payload/scripts/lib/project-mode.sh" ] \
  || fail "HIMMEL-4758 shared-payload: the payload carries check-commit-msg.sh without the scripts/lib/project-mode.sh it sources"
[ -f "$crprimaryG1/.git/hooks/himmel-payload/scripts/lib/git-clean.sh" ] \
  || fail "HIMMEL-5308 shared-payload: the payload carries check-push-target.sh without the scripts/lib/git-clean.sh it sources"
HOME="$pchome" git -C "$crprimaryG1" worktree add -q "$crwtG1" -b cr2814g1-worktree-branch

# Resolve the hooks dir from the SIBLING's own view (it is the same physical
# path as the primary's, since hooks are per-repository, not per-worktree --
# but resolve it this way rather than assuming so, mirroring cr2771r5-worktree-default above).
effective_hooks_dir_g1=$(HOME="$pchome" git -C "$crwtG1" rev-parse --git-path hooks)
case "$effective_hooks_dir_g1" in
  /*) : ;;
  *) effective_hooks_dir_g1="$crwtG1/$effective_hooks_dir_g1" ;;
esac

msgfileG1="$work/cr2814g1-valid.msg"
printf 'test: HIMMEL-2814 [#2814] gap1 worktree valid message\n' > "$msgfileG1"
set +e
woutG1=$( cd "$crwtG1" && HOME="$pchome" bash "$effective_hooks_dir_g1/commit-msg" "$msgfileG1" 2>&1 ); wrcG1=$?
set -e
[ "$wrcG1" -eq 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload: SIBLING worktree's commit-msg dispatcher rejected a valid ticketed message added AFTER the primary adopt (rc=$wrcG1): $woutG1"
grepq "$woutG1" 'not found in' \
  && fail "HIMMEL-2814 gap1 shared-payload: sibling worktree hit the missing-script 'not found ... re-run adopt.sh' error: $woutG1"

msgfileG1b="$work/cr2814g1-noticket.msg"
printf 'no ticket here at all\n' > "$msgfileG1b"
set +e
woutG1b=$( cd "$crwtG1" && HOME="$pchome" bash "$effective_hooks_dir_g1/commit-msg" "$msgfileG1b" 2>&1 ); wrcG1b=$?
set -e
[ "$wrcG1b" -ne 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload: an unticketed message exited 0 in the sibling worktree -- the gate did not actually run: $woutG1b"
echo "ok: HIMMEL-2814 gap1 shared-payload: adopting the PRIMARY checkout leaves a fallback payload that gates a SIBLING worktree added afterward, with no re-run of adopt.sh"

# gap 1, push variant (contract item 3): the same sibling
# worktree's pre-push dispatcher genuinely gates a REAL `git push` (not just a
# hand-invoked commit-msg dispatcher) via its fallback payload -- proving the
# fix covers the pre-push hook too, not only commit-msg.
crremoteG1="$work/cr2814g1-remote.git"
HOME="$pchome" git init -q --bare "$crremoteG1"
HOME="$pchome" git -C "$crwtG1" config user.name 'Native Test'
HOME="$pchome" git -C "$crwtG1" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crwtG1" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2814 [#2814] gap1 worktree push probe commit'
HOME="$pchome" git -C "$crwtG1" remote add origin "$crremoteG1"

set +e
poutG1=$(HOME="$pchome" git -C "$crwtG1" push origin cr2814g1-worktree-branch:refs/heads/main 2>&1); prcG1=$?
set -e
[ "$prcG1" -ne 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload push: a direct push to main from the SIBLING worktree landed"
grepq "$poutG1" 'not found in' \
  && fail "HIMMEL-2814 gap1 shared-payload push: sibling worktree's pre-push dispatcher hit the missing-script error instead of genuinely gating: $poutG1"
grepq "$poutG1" "Direct push to 'main' is not allowed" \
  || fail "HIMMEL-2814 gap1 shared-payload push: push was refused but not by the real check-push-target.sh gate: $poutG1"
! HOME="$pchome" git -C "$crremoteG1" rev-parse --verify refs/heads/main >/dev/null 2>&1 \
  || fail "HIMMEL-2814 gap1 shared-payload push: remote has refs/heads/main even though the push was refused"

set +e
poutG1b=$(HOME="$pchome" git -C "$crwtG1" push origin cr2814g1-worktree-branch:refs/heads/fix/cr2814g1-ok 2>&1); prcG1b=$?
set -e
[ "$prcG1b" -eq 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload push: a push to a non-main ref from the SIBLING worktree was refused: $poutG1b"
# the gate sources scripts/lib/git-clean.sh; a payload without it
# prints source errors on every push and git_env_scrub never runs.
grepq "$poutG1b" 'No such file|cannot open|not found' \
  && fail "HIMMEL-5308 shared-payload push: the pre-push gate printed source errors (payload is missing a file it sources): $poutG1b"
# BRANCH_NAME_OK bypasses the branch-NAME check only, never the main refusal.
set +e
poutG1c=$(BRANCH_NAME_OK=1 HOME="$pchome" git -C "$crwtG1" push origin cr2814g1-worktree-branch:refs/heads/main 2>&1); prcG1c=$?
set -e
[ "$prcG1c" -ne 0 ] \
  || fail "HIMMEL-5308 BRANCH_NAME_OK=1 let a push to main land"
grepq "$poutG1c" "Direct push to 'main' is not allowed" \
  || fail "HIMMEL-5308 BRANCH_NAME_OK=1 push to main was refused but not by the main gate: $poutG1c"
echo "ok: HIMMEL-2814 gap1 shared-payload push: the SIBLING worktree's pre-push dispatcher (added after the primary adopt) genuinely gates a real git push via its fallback payload"

# gap 2: the generated pre-push dispatcher's `cat > "$reffile"`
# stdin-capture return status was unchecked -- a read error or a full
# $TMPDIR would leave a TRUNCATED ref list that check-push-target.sh then
# validates instead of the refs actually being pushed, letting a push that
# should have been refused pass. Force the capture to fail by wrapping
# `mktemp` so the reffile it returns is immediately made read-only: a real
# `git push` then drives the dispatcher's real stdin-piping shape (the same
# reason CR2 push-block above uses a real push rather than a hand-invocation),
# and the truncated-write `cat >` genuinely fails. RED against the pre-fix
# dispatcher = the push proceeds (validating an empty/truncated ref list)
# instead of aborting with the named capture-failure message.
crtargetG2="$work/cr2814g2-captured-fail"; crbinG2="$work/cr2814g2-bin"
crremoteG2="$work/cr2814g2-remote.git"
mkdir -p "$crtargetG2" "$crbinG2"
HOME="$pchome" git init -q --bare "$crremoteG2"
HOME="$pchome" git -C "$crtargetG2" init -q
HOME="$pchome" git -C "$crtargetG2" checkout -q -b feat/native-test
set +e
out=$(PATH="$crbinG2:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtargetG2" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2814 gap2 capture-checked: adopt exited $rc: $out"

real_mktemp_g2=$(command -v mktemp) || fail "HIMMEL-2814 gap2 capture-checked: no system mktemp on PATH to wrap"
cat > "$crbinG2/mktemp" <<MKTEMPSHIM
#!/usr/bin/env bash
f=\$("$real_mktemp_g2" "\$@") || exit 1
chmod 0444 "\$f"
printf '%s\n' "\$f"
MKTEMPSHIM
chmod +x "$crbinG2/mktemp"

# confirm chmod 0444 actually blocks writes for the current user
# before relying on it below to force the capture failure -- as root (or on a
# filesystem where mode bits don't gate writes) this is a silent no-op and the
# suite would then fail because the push simply succeeded, not because the
# gate misbehaved. Same "fixture requires an unprivileged user" convention as
# The unwritable-hooks-dir case above.
probe_g2=$("$crbinG2/mktemp")
if : > "$probe_g2" 2>/dev/null; then
  fail "HIMMEL-2814 gap2 capture-checked: fixture requires an unprivileged user (chmod 0444 did not block a write to $probe_g2)"
fi

HOME="$pchome" git -C "$crtargetG2" config user.name 'Native Test'
HOME="$pchome" git -C "$crtargetG2" config user.email 'native@example.invalid'
HOME="$pchome" git -C "$crtargetG2" -c commit.gpgsign=false commit -q --allow-empty \
  -m 'test: HIMMEL-2814 [#2814] gap2 capture-checked probe commit'
HOME="$pchome" git -C "$crtargetG2" remote add origin "$crremoteG2"
set +e
poutG2=$(PATH="$crbinG2:$PATH" HOME="$pchome" git -C "$crtargetG2" push origin feat/native-test:refs/heads/cr2814g2-ok 2>&1); prcG2=$?
set -e
[ "$prcG2" -ne 0 ] \
  || fail "HIMMEL-2814 gap2 capture-checked: push landed even though the ref-list capture into a read-only reffile should have failed: $poutG2"
grepq "$poutG2" 'failed to capture the pushed ref list' \
  || fail "HIMMEL-2814 gap2 capture-checked: push was refused but not with the named stdin-capture-failure message: $poutG2"
! HOME="$pchome" git -C "$crremoteG2" rev-parse --verify refs/heads/cr2814g2-ok >/dev/null 2>&1 \
  || fail "HIMMEL-2814 gap2 capture-checked: remote received the ref even though capture failed"
echo "ok: HIMMEL-2814 gap2 capture-checked: a failed stdin-ref-list capture aborts the pre-push dispatcher instead of validating a truncated ref list"

# ── 21. the hook block MERGES into an existing settings.json ────
# Regression control for the 2026-09-09 dogfood incident: `himmelctl install
# --scope project` inside a repo whose .claude/settings.json already carried a
# hand-curated hook block REGENERATED that block from the manifest (98+/38-):
# foreign matchers dropped, a himmel matcher collapsed to the canonical string,
# adopter timeouts reset 60 -> 15, ordering shuffled. Ownership rule this
# asserts: himmel owns ONLY the `command` string of an entry it installed
# (so a moved clone / broken backslash path is still repaired in place —
# section 9 above). The adopter owns everything else — the stanza's `matcher`,
# its POSITION in the array, the entry's `timeout`, and every foreign matcher
# or co-located foreign entry, all of which must survive byte-for-byte.
p2892="$work/proj-2892"; mkdir -p "$p2892/.claude"
cat > "$p2892/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"WebFetch|WebSearch","hooks":[{"type":"command","command":"bash \"/opt/foreign/hooks/foreign-guard.sh\"","timeout":90}]},
      {"matcher":"Edit|Write|MultiEdit|NotebookEdit|PowerShell","hooks":[
        {"type":"command","command":"bash \"/old/clone/scripts/hooks/block-edit-on-main.sh\"","timeout":60},
        {"type":"command","command":"bash \"/opt/foreign/hooks/co-located.sh\"","timeout":45}
      ]}
    ]
  }
}
JSON
cp "$p2892/.claude/settings.json" "$work/2892-seed.json"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$p2892" >/dev/null
s2892="$p2892/.claude/settings.json"

# (a) the foreign matcher stanza survives byte-for-byte, at index 0.
before_a=$(jq -Sc '.hooks.PreToolUse[0]' "$work/2892-seed.json")
after_a=$(jq -Sc '.hooks.PreToolUse[0]' "$s2892")
[ "$before_a" = "$after_a" ] \
  || fail "HIMMEL-2892 (a): the foreign PreToolUse stanza was not preserved byte-for-byte at its original index — before=$before_a after=$after_a"

# (b) the foreign entry co-located under a himmel-owned matcher survives
#     byte-for-byte, still the SECOND entry of that stanza.
before_b=$(jq -Sc '.hooks.PreToolUse[1].hooks[1]' "$work/2892-seed.json")
after_b=$(jq -Sc '.hooks.PreToolUse[1].hooks[1]' "$s2892")
[ "$before_b" = "$after_b" ] \
  || fail "HIMMEL-2892 (b): the co-located foreign hook entry was not preserved byte-for-byte in place — before=$before_b after=$after_b"

# (c) the himmel-owned entry is UPDATED IN PLACE, not regenerated: adopter's
#     matcher kept (never collapsed to the canonical string), adopter's timeout
#     kept, only the command repointed at this install's prefix.
[ "$(jq -r '.hooks.PreToolUse[1].matcher' "$s2892")" = "Edit|Write|MultiEdit|NotebookEdit|PowerShell" ] \
  || fail "HIMMEL-2892 (c): the adopter's matcher was collapsed to the canonical one (got: $(jq -r '.hooks.PreToolUse[1].matcher' "$s2892"))"
[ "$(jq -r '.hooks.PreToolUse[1].hooks[0].timeout' "$s2892")" = "60" ] \
  || fail "HIMMEL-2892 (c): the adopter's timeout was reset (got: $(jq -r '.hooks.PreToolUse[1].hooks[0].timeout' "$s2892"))"
c2892=$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$s2892")
# shellcheck disable=SC2016  # literal $CLAUDE_PROJECT_DIR (the project-scope prefix), not an expansion
# the wired command now guards a missing script (if [ -f ]; then
# bash "..."; else warn+exit 0; fi) instead of a bare bash "...".
case "$c2892" in
  'if [ -f "$CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh" ]; then bash "$CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh"; else echo "himmel: hook script missing ($CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh) -- re-run the install (himmelctl install) or unwire it (himmelctl uninstall)" >&2; exit 0; fi') : ;;
  *) fail "HIMMEL-2892 (c): the himmel-owned command was not repointed at this install's prefix (got: $c2892)" ;;
esac

# (d) exactly ONE block-edit-on-main entry (merged in place, not appended
#     alongside the existing one), and the two hooks that were genuinely ABSENT
#     and the merge gate are appended as fresh stanzas -> 2 seeded + 3 appended = 5.
[ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-edit-on-main"))] | length' "$s2892")" = "1" ] \
  || fail "HIMMEL-2892 (d): expected exactly one block-edit-on-main entry after the merge"
[ "$(jq '.hooks.PreToolUse | length' "$s2892")" = "5" ] \
  || fail "HIMMEL-2892 (d): expected 5 PreToolUse stanzas (2 seeded + the 3 genuinely-absent himmel hooks appended), got $(jq '.hooks.PreToolUse | length' "$s2892")"
echo "ok: HIMMEL-2892 the hook block merges into an existing settings.json (foreign matcher + co-located entry + adopter matcher/timeout preserved; himmel command repointed in place)"

# ── 19x. copy_portable + the user-scope gate copies record what
# they overwrite. Every copy into the adopter's tree is one `file` row in the
# install-provenance ledger; an OVERWRITE keeps the user's bytes (and mode) in a
# backup, so uninstall can put them back (a same-named user file was
# silently gone at install time). Scratch HOME + scratch ledger throughout.
prov_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
prov_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
# prov_row <ledger> <path-suffix> — the newest `file` row whose path ends in <suffix>
prov_row() { jq -c --arg s "$2" 'select(.kind=="file" and (.path|endswith($s)))' "$1" | tail -n 1; }

p4home="$work/p4-home"; mkdir -p "$p4home"
p4led="$work/p4-ledger"
p4proj="$work/p4-proj"; mkdir -p "$p4proj/scripts"
printf '#!/bin/sh\necho user-owned worktree.sh\n' > "$p4proj/scripts/worktree.sh"
chmod 0755 "$p4proj/scripts/worktree.sh"
p4seed_sha="$(prov_sha "$p4proj/scripts/worktree.sh")"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" bash "$adopt" --profile core --scope project --target "$p4proj" >/dev/null
[ -s "$p4led/provenance.jsonl" ] || fail "HIMMEL-3332 S4: copy_portable wrote no ledger"
row="$(prov_row "$p4led/provenance.jsonl" /scripts/worktree.sh)"
[ -n "$row" ] || fail "HIMMEL-3332 S4: no file row for the overwritten scripts/worktree.sh"
[ "$(jq -r '[.op,.class,.scope,.manifest_row,.pre.state,.pre.sha,.pre.mode]|join(",")' <<< "$row")" = "replace,code,project,adopter-scripts,present,$p4seed_sha,0755" ] \
  || fail "HIMMEL-3332 S4: overwritten worktree.sh row wrong: $row"
p4bk="$(jq -r '.pre.backup' <<< "$row")"
[ "$([ -f "$p4bk" ] && prov_sha "$p4bk")" = "$p4seed_sha" ] \
  || fail "HIMMEL-3332 S4: the backup is missing or is not the user's original bytes ($p4bk)"
[ "$(prov_mode "$p4bk")" = "755" ] || fail "HIMMEL-3332 S4: the backup lost the user's mode"
[ "$(jq -r '.post.sha' <<< "$row")" = "$(prov_sha "$repo_root/scripts/worktree.sh")" ] \
  || fail "HIMMEL-3332 S4: post.sha is not the himmel copy's sha"
row="$(prov_row "$p4led/provenance.jsonl" /scripts/hooks/block-edit-on-main.sh)"
[ "$(jq -r '[.op,.pre.state,.class]|join(",")' <<< "$row")" = "create,absent,code" ] \
  || fail "HIMMEL-3332 S4: a copy into a clean target must be a create row: $row"
[ "$(jq -sr '[.[]|select(.kind=="file" and .manifest_row=="adopter-scripts")]|length' "$p4led/provenance.jsonl")" = "81" ] \
  || fail "HIMMEL-3332 S4: expected 81 file rows (80 portable entries plus the trust policy seed)"
echo "ok: HIMMEL-3332 S4 copy_portable records create + replace rows; the user's bytes and mode are backed up"

# a re-run finds our own bytes already there: noop rows, and NO new backups
p4bk_count="$(find "$p4led/provenance-backups" -type f | wc -l | tr -d ' ')"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" bash "$adopt" --profile core --scope project --target "$p4proj" >/dev/null
row="$(prov_row "$p4led/provenance.jsonl" /scripts/worktree.sh)"
[ "$(jq -r '[.op,.pre.sha,(.pre.backup|tostring)]|join(",")' <<< "$row")" = "noop,$(jq -r .post.sha <<< "$row"),null" ] \
  || fail "HIMMEL-3332 S4: a re-run over our own copy must record noop with no backup: $row"
[ "$(find "$p4led/provenance-backups" -type f | wc -l | tr -d ' ')" = "$p4bk_count" ] \
  || fail "HIMMEL-3332 S4: a noop re-run must not take another backup"
echo "ok: HIMMEL-3332 S4 re-run records noop, takes no backup"

# --dry-run writes nothing to the ledger and says what it would record
p4dry="$work/p4-dry"; mkdir -p "$p4dry"
p4lines="$(wc -l < "$p4led/provenance.jsonl" | tr -d ' ')"
out=$(HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" bash "$adopt" --profile core --scope project --target "$p4dry" --dry-run 2>&1)
[ "$(wc -l < "$p4led/provenance.jsonl" | tr -d ' ')" = "$p4lines" ] || fail "HIMMEL-3332 S4: --dry-run appended to the ledger"
grepq "$out" 'DRY: record create file' || fail "HIMMEL-3332 S4: --dry-run did not say what it would record: $out"
[ ! -e "$p4dry/scripts/worktree.sh" ] || fail "HIMMEL-3332 S4: --dry-run copied a file"
echo "ok: HIMMEL-3332 S4 --dry-run records nothing"

# ── adopt never overwrites a file it cannot back up, and reports every replace.
p6home="$work/p6-home"; mkdir -p "$p6home"
p6led="$work/p6-ledger"
p6proj="$work/p6-proj"; mkdir -p "$p6proj/scripts"
printf '#!/bin/sh\necho user-owned worktree.sh\n' > "$p6proj/scripts/worktree.sh"
chmod 0755 "$p6proj/scripts/worktree.sh"
p6sha="$(prov_sha "$p6proj/scripts/worktree.sh")"
# a mktemp that fails only for the copy_recorded snapshot template
p6bin="$work/p6-bin"; mkdir -p "$p6bin"
# shellcheck disable=SC2016 # the stub's $1 and $@ must stay literal
printf '#!/bin/sh\ncase "${1:-}" in */adopt-copy.XXXXXX) exit 1;; esac\nPATH="${PATH#*:}" exec mktemp "$@"\n' > "$p6bin/mktemp"
chmod +x "$p6bin/mktemp"
set +e
out=$(PATH="$p6bin:$PATH" HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "HIMMEL-6321: adopt exited 0 although it could not back up an existing file: $out"
[ "$(prov_sha "$p6proj/scripts/worktree.sh")" = "$p6sha" ] \
  || fail "HIMMEL-6321: the user's worktree.sh was overwritten although the snapshot failed"
grepq "$out" 'not replaced.*scripts/worktree.sh' \
  || fail "HIMMEL-6321: the refused file is not listed: $out"
echo "ok: HIMMEL-6321 a failed snapshot leaves the user's file untouched, lists it, exits non-zero"

# a cp that truncates the destination and then fails (disk full, EIO): the user's file is restored from the snapshot
p6cp="$work/p6-cp-bin"; mkdir -p "$p6cp"
# shellcheck disable=SC2016 # the stub's $# and $@ must stay literal
printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in */p6-proj/scripts/worktree.sh) [ "$#" -eq 2 ] && { : > "$last"; exit 1; };; esac\nPATH="${PATH#*:}" cp "$@"\n' > "$p6cp/cp"
chmod +x "$p6cp/cp"
set +e
out=$(PATH="$p6cp:$PATH" HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" 2>&1); rc=$?
set -e
[ "$(prov_sha "$p6proj/scripts/worktree.sh")" = "$p6sha" ] \
  || fail "HIMMEL-6356: a failed copy left the user's worktree.sh truncated: $out"
[ "$rc" -ne 0 ] || fail "HIMMEL-6356: adopt exited 0 although a copy failed: $out"
grepq "$out" 'not replaced.*scripts/worktree.sh' \
  || fail "HIMMEL-6356: the file whose copy failed is not listed: $out"
echo "ok: HIMMEL-6356 a failed copy restores the user's file from the snapshot, lists it, exits non-zero"

# a normal replace names the file and its backup; the backup holds the user's original bytes
out=$(HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" 2>&1)
p6bk="$(jq -r '.pre.backup' <<< "$(prov_row "$p6led/provenance.jsonl" /scripts/worktree.sh)")"
grepq "$out" "replaced scripts/worktree.sh (backed up to $p6bk)" \
  || fail "HIMMEL-6321: a replace must print the file and its backup path ($p6bk): $out"
[ "$(prov_sha "$p6bk")" = "$p6sha" ] || fail "HIMMEL-6321: the backup is not the user's original bytes"
out=$(HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" 2>&1)
! grepq "$out" 'replaced scripts/worktree.sh' || fail "HIMMEL-6321: a noop re-run must not report a replace: $out"
echo "ok: HIMMEL-6321 a replace prints the file and its backup path; a re-run is silent"

# --dry-run says what it would replace
printf '#!/bin/sh\necho user-owned worktree.sh\n' > "$p6proj/scripts/worktree.sh"
out=$(HOME="$p6home" HIMMEL_PROVENANCE_DIR="$p6led" bash "$adopt" --profile core --scope project --target "$p6proj" --dry-run 2>&1)
grepq "$out" 'would replace scripts/worktree.sh (backed up to ' \
  || fail "HIMMEL-6321: --dry-run must say 'would replace X (backed up to ...)': $out"
[ "$(prov_sha "$p6proj/scripts/worktree.sh")" = "$p6sha" ] || fail "HIMMEL-6321: --dry-run changed the file"
echo "ok: HIMMEL-6321 --dry-run reports would-replace"

# P6: the user-scope gate copies (install_native_hooks) go through the same path
p4gate="$work/p4-gate"; mkdir -p "$p4gate/scripts/hooks"
HOME="$p4home" git -C "$p4gate" init -q
printf '#!/bin/sh\necho user-owned gate\n' > "$p4gate/scripts/hooks/check-commit-msg.sh"
p4gate_sha="$(prov_sha "$p4gate/scripts/hooks/check-commit-msg.sh")"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" PATH="$work/bin:$native_free_path" \
  bash "$adopt" --profile core --scope user --target "$p4gate" >/dev/null
row="$(prov_row "$p4led/provenance.jsonl" "$p4gate/scripts/hooks/check-commit-msg.sh")"
[ "$(jq -r '[.op,.class,.manifest_row,.pre.sha]|join(",")' <<< "$row")" = "replace,code,adopter-scripts,$p4gate_sha" ] \
  || fail "HIMMEL-3332 S4: user-scope gate copy over a user file must record a replace row: $row"
[ "$(prov_sha "$(jq -r '.pre.backup' <<< "$row")")" = "$p4gate_sha" ] \
  || fail "HIMMEL-3332 S4: the user-scope gate copy's backup is not the user's original bytes"
row="$(prov_row "$p4led/provenance.jsonl" "$p4gate/scripts/guardrails/lib.sh")"
[ "$(jq -r '[.op,.pre.state]|join(",")' <<< "$row")" = "create,absent" ] \
  || fail "HIMMEL-3332 S4: a fresh user-scope gate copy must be a create row: $row"
echo "ok: HIMMEL-3332 S4 user-scope gate copies record create + replace rows with a backup"

# class 5: the native git hooks, the adopter's displaced hook and
# the shared-dir payload are all written into the repo, so each gets a ledger
# row (the VM round trip's no-unrecorded-write check reads these); uninstall
# [5/8] still removes/restores them from the manifest, not from these rows.
p4gh="$work/p4-gh"; mkdir -p "$p4gh"
HOME="$p4home" git -C "$p4gh" init -q
mkdir -p "$p4gh/.git/hooks"
printf '#!/bin/sh\necho adopter pre-commit\n' > "$p4gh/.git/hooks/pre-commit"; chmod +x "$p4gh/.git/hooks/pre-commit"
p4gh_sha="$(prov_sha "$p4gh/.git/hooks/pre-commit")"
p4ghled="$work/p4-gh-ledger"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4ghled" PATH="$work/bin:$native_free_path" \
  bash "$adopt" --profile core --scope project --target "$p4gh" >/dev/null
for h in commit-msg pre-push; do
  row="$(prov_row "$p4ghled/provenance.jsonl" "/.git/hooks/$h")"
  [ "$(jq -r '[.op,.pre.state,.manifest_row,.scope,.class]|join(",")' <<< "$row")" = "create,absent,git-hooks,project,code" ] \
    || fail "HIMMEL-3541: a fresh native $h hook must be a create row on git-hooks: $row"
done
row="$(prov_row "$p4ghled/provenance.jsonl" "/.git/hooks/pre-commit")"
[ "$(jq -r '[.op,.pre.sha,.manifest_row]|join(",")' <<< "$row")" = "replace,$p4gh_sha,git-hooks" ] \
  || fail "HIMMEL-3541: a native hook over the adopter's own must be a replace row naming its bytes: $row"
row="$(prov_row "$p4ghled/provenance.jsonl" "/.git/hooks/pre-commit.himmel-backup")"
[ "$(jq -r '[.op,.pre.state,.post.sha,.manifest_row]|join(",")' <<< "$row")" = "create,absent,$p4gh_sha,git-hook-backups" ] \
  || fail "HIMMEL-3541: the displaced hook's backup must be a create row on git-hook-backups: $row"
row="$(jq -c 'select(.kind=="tree" and (.path|endswith("/.git/hooks/himmel-payload")))' "$p4ghled/provenance.jsonl" | tail -n 1)"
[ "$(jq -r '[.op,.pre.state,.manifest_row]|join(",")' <<< "$row")" = "create,absent,git-hooks" ] \
  || fail "HIMMEL-3541: the shared-dir hook payload must be a tree create row: $row"
echo "ok: HIMMEL-3541 native git hooks, the displaced hook and the payload are ledger rows"

# wire_handover_dir_luna skips a HANDOVER_DIR the operator already chose;
# the ledger must say the key was theirs, or uninstall removes it anyway.
p4hd="$work/p4-hd"; mkdir -p "$p4hd/.claude"
printf '%s' '{"env":{"HANDOVER_DIR":"/some/operator/chosen/handovers"}}' > "$p4hd/.claude/settings.json"
HOME="$p4home" HIMMEL_PROVENANCE_DIR="$p4led" bash "$adopt" --profile luna --target "$p4hd" >/dev/null
row="$(jq -c 'select(.kind=="json-key" and .unit=="/env/HANDOVER_DIR")' "$p4led/provenance.jsonl" | tail -n 1)"
[ "$(jq -r '[.op,.preexisted,.pre.state,.scope,.manifest_row,.class]|join(",")' <<< "$row")" = "noop,true,present,project,project-settings,code" ] \
  || fail "HIMMEL-3332 S4: a skipped HANDOVER_DIR must be recorded as noop preexisted: $row"
[ "$(jq -r '.env.HANDOVER_DIR' "$p4hd/.claude/settings.json")" = "/some/operator/chosen/handovers" ] \
  || fail "HIMMEL-3332 S4: the recorded skip must not change the operator's HANDOVER_DIR"
echo "ok: HIMMEL-3332 S4 a preserved HANDOVER_DIR is recorded as noop preexisted"

# ── 20. himmelctl wizard + machine-setup shim suites ──────────
# A plain `bash scripts/test-adopt-features.sh` run exercises the himmelctl install
# wizard + the T7/T8 bootstrap/deprecation-shim suites, so a regression in any
# of them fails THIS harness, not just the CI shell-test sweep. Each suite runs
# as a self-contained `bash <script>` subprocess (own `set -e` + trap + temp
# dir), isolating it from this script's hermetic PATH scrub. That scrub dropped
# node/npm/bun suite-wide for the adopt.sh scenarios above; the wizard suites
# shell out to bin.js and need a REAL node, so each is invoked with `saved_path`
# (the pre-scrub environment PATH captured above). The .ps1 shim suite is
# skipped — not failed — when pwsh is absent, mirroring the availability guard
# in scripts/himmelctl/test/test-wizard-bootstrap.sh.
#
# run_wizard_suite <relpath-under-scripts/> <label> — run one suite under the
# real PATH; tail its log + fail on non-zero (cleans up via this script's trap).
run_wizard_suite() {
  local _rel="$1" _label="$2" _path
  _path="$repo_root/scripts/$_rel"
  [ -f "$_path" ] || fail "wizard suite not found: $_path"
  set +e
  PATH="$saved_path" bash "$_path" >"$work/wizard-suite.log" 2>&1
  local _rc=$?
  set -e
  if [ "$_rc" -ne 0 ]; then
    tail -20 "$work/wizard-suite.log" >&2
    fail "wizard suite failed (rc=$_rc): $_label"
  fi
  echo "ok: wizard suite green: $_label"
}

run_wizard_suite himmelctl/test/test-wizard-preflight.sh       "test-wizard-preflight"
run_wizard_suite himmelctl/test/test-wizard-questions.sh       "test-wizard-questions"
run_wizard_suite himmelctl/test/test-wizard-derive.sh          "test-wizard-derive"
run_wizard_suite himmelctl/test/test-wizard-uninstall.sh       "test-wizard-uninstall"
run_wizard_suite himmelctl/test/test-wizard-uninstall-converge.sh "test-wizard-uninstall-converge"
run_wizard_suite himmelctl/test/test-wizard-noinstall-guard.sh "test-wizard-noinstall-guard"
run_wizard_suite himmelctl/test/test-wizard-bootstrap.sh       "test-wizard-bootstrap"
run_wizard_suite himmelctl/test/test-wizard-state.sh           "test-wizard-state"
run_wizard_suite himmelctl/test/test-wizard-probes.sh          "test-wizard-probes"
run_wizard_suite himmelctl/test/test-wizard-status-cmd.sh      "test-wizard-status-cmd"
run_wizard_suite himmelctl/test/test-wizard-status-golden.sh   "test-wizard-status-golden"
run_wizard_suite himmelctl/test/test-wizard-status-multitarget.sh "test-wizard-status-multitarget"
run_wizard_suite himmelctl/test/test-wizard-manifest-v2.sh     "test-wizard-manifest-v2"
run_wizard_suite himmelctl/test/test-wizard-himmel-clone-target.sh "test-wizard-himmel-clone-target"
run_wizard_suite himmelctl/test/test-wizard-statusreport.sh    "test-wizard-statusreport"
run_wizard_suite himmelctl/test/test-wizard-reconcile.sh       "test-wizard-reconcile"
run_wizard_suite himmelctl/test/test-wizard-install-engine.sh  "test-wizard-install-engine"
run_wizard_suite himmelctl/test/test-wizard-ensure.sh          "test-wizard-ensure"
run_wizard_suite himmelctl/test/test-wizard-ensure-disable.sh  "test-wizard-ensure-disable"
run_wizard_suite himmelctl/test/test-wizard-scope-switch.sh    "test-wizard-scope-switch"
run_wizard_suite himmelctl/test/test-wizard-option-validation.sh "test-wizard-option-validation"
run_wizard_suite himmelctl/test/test-wizard-config.sh          "test-wizard-config"
run_wizard_suite himmelctl/test/test-wizard-deps.sh             "test-wizard-deps"
run_wizard_suite himmelctl/test/test-wizard-deps-lint.sh        "test-wizard-deps-lint"
run_wizard_suite machine-setup/test-ubuntu-shim.sh             "test-ubuntu-shim"

echo "PASS"
