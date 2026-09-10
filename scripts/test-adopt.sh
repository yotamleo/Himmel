#!/usr/bin/env bash
# test-adopt.sh — smoke tests for scripts/adopt.sh (the one-click harness
# installer). Self-contained: stubs `claude` on PATH so the plugin-install
# step doesn't hit the network, and uses throwaway temp dirs + a fake HOME so
# nothing touches the real ~/.claude.
#
# adopt.ps1 carries the same profile/scope logic for PowerShell — that twin is
# NOT covered here; keep both in lockstep when changing either.
#
# Covers:
#   1. core/project — copies the portable files, wires 3 PreToolUse hooks
#      ($CLAUDE_PROJECT_DIR prefix), idempotent on re-run.
#   2. merge — pre-existing settings.json keys + hooks are preserved.
#   3. core/user — wires ~/.claude/settings.json to the himmel abs path,
#      copies NO scripts into a repo.
#   4. luna — copies the vault scaffold to the target.
#   5. invalid --profile / --scope exit 2.

set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# dir_is_empty <dir> — true (rc 0) iff <dir> has no entries, dotfiles
# included, using only bash builtins/globs -- no `ls`. HIMMEL-2771 CR
# round-2: under the hermetic PATH built below, `ls` is NOT guaranteed
# reachable -- scrub_path() drops a PATH directory WHOLESALE to remove a
# named tool, and on a box where `ls` shares a directory with one of the
# scrubbed tools (e.g. /usr/bin holding node/npm/uv/bun), `ls` goes with it.
# A missing `ls` makes `[ -z "$(ls -A "$dir")" ]` evaluate `[ -z "" ]` --
# TRUE no matter what is actually in the directory, silently turning a
# containment assertion into one that can never fail (already hit 3x per
# scripts/lib/hermetic-path.sh: HIMMEL-2470/2520/2530). Without `nullglob`
# an unmatched glob stays literal, so an unmatched literal must still be
# filtered out -- but `[ -e "$f" ]` ALONE follows a symlink to test its
# TARGET, so a DANGLING symlink (an unmatched-glob false positive's exact
# opposite: a real directory entry whose target does not exist) is `-e`
# false and was silently skipped, reporting an occupied directory as empty
# (HIMMEL-2771 CR round-6, codex-2, confirmed -- this is what let the
# round-5 cr2771r5-symlink-dangling control's whole subject, a dangling
# symlink, slip past this assertion undetected). `[ -L "$f" ]` sees the
# LINK ITSELF regardless of what it points at (or fails to), so an
# unmatched literal is still excluded (no entry is ever a symlink) while a
# genuine dangling entry now counts. "." and ".." are excluded by
# construction (.[!.]* skips them, ..?* only matches a dotfile whose name
# is LONGER than "..").
dir_is_empty() {
  local d="$1" f
  for f in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    return 1
  done
  return 0
}

repo_root=$(git rev-parse --show-toplevel)
adopt="$repo_root/scripts/adopt.sh"
[ -f "$adopt" ] || { echo "FAIL: $adopt not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# Normalize a path the same way wire-luna-vault.sh stores it: passing a path as a
# jq arg triggers MSYS POSIX->Windows path mangling on Git-Bash (e.g.
# /tmp/x -> C:/Users/.../x) and is an identity on Linux. Normalizing the EXPECTED
# value through the same jq hop makes the LUNA_VAULT_PATH assertions below
# cross-platform without hard-coding either path form.
norm() { jq -rn --arg v "$1" '$v'; }

work=$(mktemp -d)

# HIMMEL-842 CR round-2 (F1): scripts/jira/dist + scripts/jira/node_modules are
# gitignored build artifacts that MAY already exist in this checkout (a primary
# checkout that has run adopt.sh/setup.sh before). build_jira_cli's "already
# built" skip fires the instant either is present, which would make scenarios
# 14-19 below assert on the WRONG branch. Move any existing dist/node_modules
# aside for the whole suite and restore unconditionally on exit — mirrors the
# real_jira_dist/dist_backup + trap cleanup EXIT pattern in
# scripts/test-preflight-adopter.sh.
real_jira_dist="$repo_root/scripts/jira/dist"
real_jira_node_modules="$repo_root/scripts/jira/node_modules"
dist_backup=""
node_modules_backup=""
if [ -e "$real_jira_dist" ]; then
  dist_backup="$work/dist-backup"
  mv "$real_jira_dist" "$dist_backup"
fi
if [ -e "$real_jira_node_modules" ]; then
  node_modules_backup="$work/node_modules-backup"
  mv "$real_jira_node_modules" "$node_modules_backup"
fi
# HIMMEL-839 CR round-2: the repo-.env-preserve scenario below temporarily
# writes a HANDOVER_DIR= line into THIS repo's real .env ($HIMMEL_ROOT is
# resolved by adopt.sh from its own script path — not overridable via HOME —
# so there is no fake-checkout stand-in for it). Declared here, set only at
# the point of mutation, and restored unconditionally in cleanup() — same
# backup-then-trap-restore shape as the jira dist/node_modules pair above, so
# a `fail()` (which exits immediately) mid-scenario can never strand a
# mutated .env in the real worktree.
real_env="$repo_root/.env"
env_backup=""
env_mutated=0
cleanup() {
  rm -rf "$real_jira_dist" "$real_jira_node_modules"
  if [ -n "$dist_backup" ]; then mv "$dist_backup" "$real_jira_dist"; fi
  if [ -n "$node_modules_backup" ]; then mv "$node_modules_backup" "$real_jira_node_modules"; fi
  if [ -n "$env_backup" ]; then
    mv "$env_backup" "$real_env"
  elif [ "$env_mutated" -eq 1 ]; then
    rm -f "$real_env"
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Stub claude so adopt's install-plugins step is a no-op. `plugin list` must echo
# the enabled plugin specs so install-plugins.sh's presence-verify (HIMMEL-361)
# passes offline — without it `set -e` aborts adopt at the first core install.
mkdir -p "$work/bin"
cat > "$work/bin/claude" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then
  jq -r '.enabledPlugins | keys[]' "$repo_root/docs/setup/settings-template.json"
fi
exit 0
STUB
chmod +x "$work/bin/claude"

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

# xargs: Arch co-locates node with coreutils in /usr/bin, so the toolchain
# scrub drops it (same class as the HIMMEL-874 sed fix).
for _tool in bash git jq python3 grep sed cat cp mv rm ln mkdir chmod diff wc tr head tail basename dirname mktemp sort cut xargs; do
  link_hermetic_tool "$_tool"
done

# Derive the expected suffix from an INDEPENDENT platform probe, never from
# HERMETIC_EXE_SUFFIX — the very variable link_hermetic_tool writes with.
# Reusing the writer's value makes this test tautological: if the detection in
# hermetic-path.sh regressed to an empty suffix, the writer would emit
# extensionless stubs, the expectation below would ALSO go extensionless and
# still match, and the rejection branch would be skipped by its own
# [ -n ... ] guard. The test could then never fail (HIMMEL-1686 CR).
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT*) hermetic_suffix='.exe' ;;
  *)                                hermetic_suffix='' ;;
esac
[ -f "$work/bin/bash$hermetic_suffix" ] || fail "link_hermetic_tool self-test: platform-named bash stub was not created"
# `find` with a literal -name match is REQUIRED here; do not "simplify" this to
# [ -e "$work/bin/bash" ]. On MSYS/Git-Bash, test -e resolves bash -> bash.exe,
# so the plain file test reports an extensionless stub that does not exist and
# this check fires on every healthy Windows run. find matches real directory
# entries and does not do the .exe fallback. (HIMMEL-1686 CR proposed the
# [ -e ]/[ -L ] form on portability grounds; the premise is wrong -- BSD find
# does support -maxdepth -- and the replacement breaks the suite on Windows.
# Verified live: swapping it made the green baseline fail.)
if [ -n "$hermetic_suffix" ] && [ -n "$(find "$work/bin" -maxdepth 1 -name bash -print -quit)" ]; then
  fail "link_hermetic_tool self-test: extensionless bash stub was created on Windows"
fi

# ── HIMMEL-874 unit test: link_hermetic_tool's two failure-fallback branches ──
# Force `ln -s` to fail deterministically (a stub `ln` fronting PATH — the
# function calls bare `ln`, so it resolves via PATH) and assert both
# fallbacks: the wrapper-script proxy (any non-bash tool, here jq) and the
# copy fallback (bash, finding 1 above). Uses an isolated dest dir (the
# function's optional 2nd arg) so it can't disturb the suite's real
# $work/bin; the PATH= prefix is scoped to each function call only.
ut="$work/ut-link"; mkdir -p "$ut/bin" "$ut/stub"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ut/stub/ln"; chmod +x "$ut/stub/ln"

PATH="$ut/stub:$PATH" link_hermetic_tool jq "$ut/bin"
[ -f "$ut/bin/jq$hermetic_suffix" ] || fail "link_hermetic_tool self-test: wrapper-fallback did not create jq wrapper"
[ -x "$ut/bin/jq$hermetic_suffix" ] || fail "link_hermetic_tool self-test: jq wrapper is not executable"
"$ut/bin/jq$hermetic_suffix" --version >/dev/null 2>&1 || fail "link_hermetic_tool self-test: jq wrapper does not proxy correctly"

PATH="$ut/stub:$PATH" link_hermetic_tool bash "$ut/bin"
[ -f "$ut/bin/bash$hermetic_suffix" ] || fail "link_hermetic_tool self-test: bash copy-fallback did not create bash"
[ -x "$ut/bin/bash$hermetic_suffix" ] || fail "link_hermetic_tool self-test: bash copy is not executable"
[ "$("$ut/bin/bash$hermetic_suffix" -c 'echo ok')" = "ok" ] || fail "link_hermetic_tool self-test: bash copy-fallback produced a non-working bash"
echo "ok: link_hermetic_tool wrapper-fallback (jq) + bash copy-fallback verified under forced ln failure"

# Hermeticity (HIMMEL-752 CR): scrub every dir carrying a real qmd, bun, npm,
# node, uv, or pipx from the suite-wide PATH. With bun absent, wire_qmd_core
# takes its documented clean-skip branch, so NO test can fire a real
# fix-qmd-stub (~/.claude mutation), a real `qmd pull` (~2.1 GB), or a real
# collection registration on a dev box that has the toolchain installed. Tests
# 10/11 re-add their own stubbed bun on top of this scrubbed base to exercise
# the qmd path.
#
# HIMMEL-842: ALSO scrub npm dirs (node + npm share a bin dir, so this drops
# real node too). With npm AND bun both absent suite-wide, build_jira_cli takes
# its "no npm or bun - skipping build" branch, so NO test fires a real
# `npm install` in scripts/jira (network + repo mutation). Tests 14/15 re-add a
# stubbed npm on top of this scrubbed base to exercise the build path; 12/13
# re-add a stubbed node (and 13 a stubbed bun) for the npm-less-node preflight.
#
# Factored out (scripts/lib/hermetic-path.sh) so the exact scrub logic can
# also run over a synthetic PATH (self-test below) without touching the
# suite's real PATH.
#
# The himmelctl wizard + shim suites appended at the bottom (HIMMEL-887 T10)
# need a REAL node — they shell out to bin.js — so they cannot run under the
# scrubbed PATH below. Capture the pre-scrub environment PATH here and pass it
# to each of those suites explicitly.
# HIMMEL-2771: pip bootstrap must stay offline while real Python still handles
# the adopter's JSON/file operations.
real_python3=$(command -v python3)
rm -f "$work/bin/python3"
cat > "$work/bin/python3" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-m" ] && [ "\$2" = "pip" ]; then
  echo 'pip unavailable in offline test fixture' >&2
  exit 1
fi
exec "$real_python3" "\$@"
STUB
chmod +x "$work/bin/python3"

# HIMMEL-2892: wire-statusline.sh drops the hud config under
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}. Every case here already fakes HOME, but a
# RUNNER that exports CLAUDE_CONFIG_DIR would win over that and take the drop to
# their real config dir — pin it at a throwaway dir for the whole suite.
export CLAUDE_CONFIG_DIR="$work/claude-config"

saved_path="$PATH"
qmd_free_path=$(scrub_path "$PATH" qmd bun npm node uv pipx)
export PATH="$work/bin:$qmd_free_path"
PATH="$work/bin" command -v bash >/dev/null 2>&1 \
  || fail "hermetic stub dir must provide bash even if every scrubbed dir is removed"
for _tool in qmd bun npm node uv pipx; do
  if command -v "$_tool" >/dev/null 2>&1; then
    fail "hermetic PATH leaked $_tool: $(command -v "$_tool")"
  fi
done

# ── HIMMEL-874 self-test: co-located essential + scrubbed tool ──────────────
# Reproduce the stock-Ubuntu regression shape synthetically: a single dir
# carrying BOTH a scrubbed tool (npm) and an essential one (sed) must be
# dropped wholesale by scrub_path, and sed must still resolve afterward — via
# the hermetic stub dir ($work/bin), not via the dropped co-located dir.
coloc="$work/coloc"; mkdir -p "$coloc"
printf '#!/usr/bin/env bash\nexit 0\n' > "$coloc/npm"; chmod +x "$coloc/npm"
printf '#!/usr/bin/env bash\nexit 0\n' > "$coloc/sed"; chmod +x "$coloc/sed"
synthetic_scrubbed=$(scrub_path "$coloc:$work/bin" qmd bun npm node uv pipx)
case ":$synthetic_scrubbed:" in
  *":$coloc:"*) fail "self-test: co-located dir with npm+sed was not scrubbed" ;;
esac
[ "$(PATH="$work/bin:$synthetic_scrubbed" command -v sed)" = "$work/bin/sed" ] \
  || fail "self-test: sed did not resolve via the hermetic stub dir after scrub"
echo "ok: self-test reproduces HIMMEL-874 (co-located npm+sed dir scrubbed, sed still resolves via stub dir)"

# ── 5. invalid args (run first — validated before any tool preflight) ────────
set +e
out=$(bash "$adopt" --profile bogus --scope project 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --profile should exit 2 (got $rc)"
grepq "$out" "invalid --profile" || fail "missing invalid-profile diagnostic"
set +e
out=$(bash "$adopt" --profile core --scope bogus 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --scope should exit 2 (got $rc)"
echo "ok: invalid --profile / --scope rejected (exit 2)"

# ── 1. core/project ──────────────────────────────────────────────────────────
# Fake HOME on every non-user-scope run too (belt-and-braces with the PATH
# scrub): nothing in the suite may read or write the real ~/.claude.
base_home="$work/home-base"; mkdir -p "$base_home"
proj="$work/proj"; mkdir -p "$proj"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$proj" >/dev/null
for f in scripts/hooks/block-edit-on-main.sh scripts/guardrails/lib.sh scripts/worktree.sh; do
  [ -f "$proj/$f" ] || fail "core/project did not copy $f"
done
s="$proj/.claude/settings.json"
[ -f "$s" ] || fail "core/project did not write $s"
[ "$(jq '.hooks.PreToolUse | length' "$s")" = "3" ] || fail "expected 3 PreToolUse hooks"
jq -e '.hooks.PreToolUse[].hooks[].command | select(contains("$CLAUDE_PROJECT_DIR"))' "$s" >/dev/null \
  || fail "project-scope hooks must use \$CLAUDE_PROJECT_DIR"
echo "ok: core/project copies portable files + wires 3 \$CLAUDE_PROJECT_DIR hooks"

# idempotency
cp "$s" "$work/before.json"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$proj" >/dev/null
diff -q "$work/before.json" "$s" >/dev/null || fail "core/project not idempotent"
echo "ok: core/project idempotent on re-run"

# ── 1b. HIMMEL-2435: self-copy guard ─────────────────────────────────────────
# A brand-new adopter clones himmel and runs the installer FROM INSIDE that
# clone (TARGET == HIMMEL_ROOT). do_core() mutates its TARGET, so this can't
# be reproduced by pointing --target at the live checkout ($repo_root) --
# that would mutate this worktree's real .claude/settings.json etc. Instead
# build a standalone, disposable clone (a full copy of this worktree's
# CURRENT tracked-file content, not the committed HEAD blob -- so it carries
# whatever adopt.sh is on disk right now: the original for this red-first
# run, the guarded version once the fix lands) and run its OWN adopt.sh
# against itself.
fakeClone="$work/fake-himmel-clone"; mkdir -p "$fakeClone"
( cd "$repo_root" && git ls-files -z ) | xargs -0 cp --parents -t "$fakeClone"
[ -f "$fakeClone/scripts/adopt.sh" ] || fail "HIMMEL-2435 fixture: scripts/adopt.sh did not land in the fake clone"

# case A (the important one, red-first): the documented flow -- cd into the
# clone and run `adopt.sh --scope project`, TARGET defaulting to $PWD (the
# clone itself). Before the fix this dies on the self-copy `cp` error on the
# very first portable file.
homeA2435="$work/home-2435a"; mkdir -p "$homeA2435"
set +e
outA2435=$( cd "$fakeClone" && HOME="$homeA2435" bash scripts/adopt.sh --scope project 2>&1 ); rcA2435=$?
set -e
[ "$rcA2435" -eq 0 ] || fail "HIMMEL-2435 case A: the documented adopter flow (adopt.sh --scope project run from inside the clone) should exit 0 (got rc=$rcA2435): $outA2435"
grepq "$outA2435" -i "already in place" \
  || fail "HIMMEL-2435 case A: expected a skip note, not silence or the self-copy cp abort (got: $outA2435)"
grepq "$outA2435" "are the same file" \
  && fail "HIMMEL-2435 case A: must NOT hit the self-copy cp error (got: $outA2435)"
echo "ok: HIMMEL-2435 case A the documented adopter flow (adopt.sh --scope project from inside the clone) completes rc=0 with a skip note, not the self-copy cp abort"

# case B: the by-hand route -- `adopt.sh --scope project --target <the
# clone>`, invoked from elsewhere. Same single guard (inside copy_portable())
# must cover this call shape too, not just the documented one above.
homeB2435="$work/home-2435b"; mkdir -p "$homeB2435"
set +e
outB2435=$(HOME="$homeB2435" bash "$fakeClone/scripts/adopt.sh" --scope project --target "$fakeClone" 2>&1); rcB2435=$?
set -e
[ "$rcB2435" -eq 0 ] || fail "HIMMEL-2435 case B: --target <the clone> (by-hand route) should exit 0 (got rc=$rcB2435): $outB2435"
grepq "$outB2435" -i "already in place" \
  || fail "HIMMEL-2435 case B: expected the skip note on the by-hand --target route too (got: $outB2435)"
echo "ok: HIMMEL-2435 case B the by-hand route (adopt.sh --scope project --target <clone>) hits the same guard"

# negative control (load-bearing): a genuinely DIFFERENT target must still
# get its portable core copied -- a guard that skipped unconditionally (or
# compared paths by content instead of identity) would also pass A and B.
diffTarget2435="$work/diff-target-2435"; mkdir -p "$diffTarget2435"
homeC2435="$work/home-2435c"; mkdir -p "$homeC2435"
set +e
outC2435=$(HOME="$homeC2435" bash "$fakeClone/scripts/adopt.sh" --scope project --target "$diffTarget2435" 2>&1); rcC2435=$?
set -e
[ "$rcC2435" -eq 0 ] || fail "HIMMEL-2435 negative control: a genuinely different --target should still succeed (got rc=$rcC2435): $outC2435"
[ -f "$diffTarget2435/scripts/worktree.sh" ] \
  || fail "HIMMEL-2435 negative control: the guard must not over-skip -- a genuinely different target should still get its portable core copied (missing $diffTarget2435/scripts/worktree.sh)"
grepq "$outC2435" -i "already in place" \
  && fail "HIMMEL-2435 negative control: a genuinely different target should NOT print the self-copy skip note (got: $outC2435)"
echo "ok: HIMMEL-2435 negative control a genuinely different --target still gets its portable core copied (the guard does not over-skip)"

# ── 2. merge preserves existing settings ─────────────────────────────────────
proj2="$work/proj2"; mkdir -p "$proj2/.claude"
printf '%s' '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /pre/existing.sh"}]}]}}' > "$proj2/.claude/settings.json"
HOME="$base_home" bash "$adopt" --profile core --scope project --target "$proj2" >/dev/null
[ "$(jq -r '.permissions.allow[0]' "$proj2/.claude/settings.json")" = "Bash(ls)" ] || fail "merge dropped existing permissions"
[ "$(jq '.hooks.PreToolUse | length' "$proj2/.claude/settings.json")" = "4" ] || fail "merge expected 4 PreToolUse hooks (1 existing + 3)"
echo "ok: merge preserves existing keys + hooks"

# ── 3. core/user (fake HOME) ─────────────────────────────────────────────────
home="$work/home"; mkdir -p "$home"
HOME="$home" bash "$adopt" --profile core --scope user --target "$work/ignored" >/dev/null
us="$home/.claude/settings.json"
[ -f "$us" ] || fail "core/user did not write ~/.claude/settings.json"
[ "$(jq '.hooks.PreToolUse | length' "$us")" = "3" ] || fail "core/user expected 3 PreToolUse hooks"
us_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$us")
# shellcheck disable=SC2016  # literal $CLAUDE_PROJECT_DIR globs below, not expansions
case "$us_cmd" in
  *'$CLAUDE_PROJECT_DIR'*) fail "user-scope must not use \$CLAUDE_PROJECT_DIR ($us_cmd)" ;;
  */scripts/hooks/*) : ;;  # absolute himmel path
  *) fail "user-scope hook command unexpected: $us_cmd" ;;
esac
[ ! -d "$work/ignored/scripts" ] || fail "core/user must NOT copy scripts into a repo"
echo "ok: core/user wires ~/.claude to himmel abs path, copies no scripts"

# ── 4. luna scaffold ─────────────────────────────────────────────────────────
vault="$work/vault"
HOME="$base_home" bash "$adopt" --profile luna --target "$vault" >/dev/null
[ -f "$vault/README.md" ] || fail "luna profile did not scaffold the vault (README.md missing)"
# F1 (HIMMEL-458): project scope wires LUNA_VAULT_PATH into $TARGET/.claude.
lv=$(jq -r '.env.LUNA_VAULT_PATH' "$vault/.claude/settings.json" 2>/dev/null)
[ "$lv" = "$(norm "$vault")" ] || fail "luna/project did not persist LUNA_VAULT_PATH ([$lv] != [$(norm "$vault")])"
echo "ok: luna scaffolds the vault + persists LUNA_VAULT_PATH (project scope)"

# HIMMEL-839: luna profile also seeds HANDOVER_DIR at <vault>/handovers so a
# fresh adopter's handover state doesn't silently default to the inline
# <repo-root>/handovers stub.
hd=$(jq -r '.env.HANDOVER_DIR' "$vault/.claude/settings.json" 2>/dev/null)
[ "$hd" = "$(norm "$vault/handovers")" ] || fail "luna/project did not persist HANDOVER_DIR ([$hd] != [$(norm "$vault/handovers")])"
[ -d "$vault/handovers" ] || fail "luna/project did not create <vault>/handovers"
echo "ok: luna scaffolds the vault + persists HANDOVER_DIR (project scope)"

# ── 4b. HIMMEL-839 CR round-2: PRESERVE an existing settings.json HANDOVER_DIR ──
# A routine re-adopt must reproduce state, never silently reset an
# operator-selected root (own settings.json env.HANDOVER_DIR from a prior
# /handover-setup or adopt run).
preserve_vault="$work/preserve-vault"
preserve_target="$work/preserve-target"; mkdir -p "$preserve_target/.claude"
printf '%s' '{"env":{"HANDOVER_DIR":"/some/operator/chosen/handovers"}}' > "$preserve_target/.claude/settings.json"
out=$(HOME="$base_home" bash "$adopt" --profile luna --target "$preserve_target" --luna-target "$preserve_vault" 2>&1)
hd=$(jq -r '.env.HANDOVER_DIR' "$preserve_target/.claude/settings.json" 2>/dev/null)
[ "$hd" = "/some/operator/chosen/handovers" ] || fail "HIMMEL-839 preserve: existing settings.json HANDOVER_DIR was overwritten ([$hd])"
grepq "$out" 'leaving it' || fail "HIMMEL-839 preserve: missing the leaving-it message (got: $out)"
echo "ok: HIMMEL-839 preserves an existing settings.json env.HANDOVER_DIR (re-adopt reproduces, not resets)"

# ── 4c. HIMMEL-839 CR round-2: PRESERVE an existing repo .env HANDOVER_DIR ──
# The other place HANDOVER_DIR can already live: the primary checkout's own
# .env (set-handover-dir.sh / Mode B — what /handover-setup actually writes).
# settings.json env takes PROCESS-ENV precedence over .env, so writing it here
# would silently shadow that choice even with the .env file itself untouched.
if [ -f "$real_env" ]; then
  env_backup="$work/env-backup"
  mv "$real_env" "$env_backup"
fi
printf 'HANDOVER_DIR=/some/dotenv/handovers\n' > "$real_env"
env_mutated=1
preserve_vault2="$work/preserve-vault2"
preserve_target2="$work/preserve-target2"; mkdir -p "$preserve_target2"
out=$(HOME="$base_home" bash "$adopt" --profile luna --target "$preserve_target2" --luna-target "$preserve_vault2" 2>&1)
if [ -n "$env_backup" ]; then mv "$env_backup" "$real_env"; env_backup=""; else rm -f "$real_env"; fi
env_mutated=0
hd=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$preserve_target2/.claude/settings.json" 2>/dev/null)
[ "$hd" = "ABSENT" ] || fail "HIMMEL-839 preserve: .env-configured HANDOVER_DIR was shadowed by a settings.json write ([$hd])"
grepq "$out" 'via /handover-setup' || fail "HIMMEL-839 preserve: missing the .env-preserve message (got: $out)"
echo "ok: HIMMEL-839 preserves an existing repo .env HANDOVER_DIR (does not shadow it via settings.json)"

# ── 4d. HIMMEL-839 CR round-2: canonicalize a relative --luna-target ────────
# A relative --luna-target must not persist a CWD-dependent relative path.
relhome="$work/relhome"; mkdir -p "$relhome"
relbase="$work/relbase"; mkdir -p "$relbase"
( cd "$relbase" && HOME="$relhome" bash "$adopt" --profile luna --luna-target "rel-vault" >/dev/null )
relsettings="$relbase/.claude/settings.json"
hd=$(jq -r '.env.HANDOVER_DIR' "$relsettings" 2>/dev/null)
expected_rel="$(norm "$relbase/rel-vault/handovers")"
[ "$hd" = "$expected_rel" ] || fail "HIMMEL-839 canonicalize: relative --luna-target persisted a wrong/non-canonical HANDOVER_DIR ([$hd] != [$expected_rel])"
case "$hd" in /*|[A-Za-z]:/*) : ;; *) fail "HIMMEL-839 canonicalize: HANDOVER_DIR is not absolute: $hd" ;; esac
echo "ok: HIMMEL-839 canonicalizes a relative --luna-target to an absolute HANDOVER_DIR"

# ── 6. all — core→--target, vault→--luna-target (no leak) ────────────────────
allrepo="$work/allrepo"; allvault="$work/allvault"; mkdir -p "$allrepo"
HOME="$base_home" bash "$adopt" --profile all --scope project --target "$allrepo" --luna-target "$allvault" >/dev/null
[ -f "$allrepo/scripts/worktree.sh" ] || fail "all: core did not land in --target"
[ -f "$allvault/README.md" ] || fail "all: vault did not land in --luna-target"
[ ! -f "$allrepo/README.md" ] || fail "all: vault scaffold leaked into the core --target"
# F1 (HIMMEL-458): project scope wires LUNA_VAULT_PATH=$allvault into $allrepo/.claude.
lv=$(jq -r '.env.LUNA_VAULT_PATH' "$allrepo/.claude/settings.json" 2>/dev/null)
[ "$lv" = "$(norm "$allvault")" ] || fail "all/project did not persist LUNA_VAULT_PATH ([$lv] != [$(norm "$allvault")])"
# HIMMEL-839: same for HANDOVER_DIR=$allvault/handovers — this is the exact
# --profile all repro shape from the ticket (VM adopter needed HANDOVER_DIR
# set manually; adopt.sh should seed it).
hd=$(jq -r '.env.HANDOVER_DIR' "$allrepo/.claude/settings.json" 2>/dev/null)
[ "$hd" = "$(norm "$allvault/handovers")" ] || fail "all/project did not persist HANDOVER_DIR ([$hd] != [$(norm "$allvault/handovers")])"
echo "ok: all routes core→--target, vault→--luna-target (no leak) + persists LUNA_VAULT_PATH + HANDOVER_DIR"

# ── 7. core/user idempotency (re-run into populated ~/.claude keeps 3) ────────
HOME="$home" bash "$adopt" --profile core --scope user --target "$work/ignored" >/dev/null
[ "$(jq '.hooks.PreToolUse | length' "$us")" = "3" ] || fail "core/user not idempotent on re-run"
echo "ok: core/user idempotent on re-run"

# ── 8. F1 (HIMMEL-458): user-scope persists LUNA_VAULT_PATH to ~/.claude ──────
# 8a. F1-SC1(a): all/user --luna-target -> env.LUNA_VAULT_PATH in ~/.claude.
fh="$work/f1a-home"; mkdir -p "$fh"; fv="$work/f1a-vault"
HOME="$fh" bash "$adopt" --profile all --scope user --target "$work/ign-a" --luna-target "$fv" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh/.claude/settings.json")
[ "$got" = "$(norm "$fv")" ] || fail "F1-SC1(a) all/user: LUNA_VAULT_PATH=[$got] != [$(norm "$fv")]"
echo "ok: F1-SC1(a) all/user --luna-target persists LUNA_VAULT_PATH"
# HIMMEL-839: this is the literal ticket repro shape (`adopt.sh --profile all
# --scope user --luna-target ...`) — HANDOVER_DIR must land in ~/.claude too.
got=$(jq -r '.env.HANDOVER_DIR' "$fh/.claude/settings.json")
[ "$got" = "$(norm "$fv/handovers")" ] || fail "HIMMEL-839 all/user: HANDOVER_DIR=[$got] != [$(norm "$fv/handovers")]"
echo "ok: HIMMEL-839 all/user --luna-target persists HANDOVER_DIR"

# 8b. F1-SC1(b): luna/user --target -> env.LUNA_VAULT_PATH in ~/.claude.
fh2="$work/f1b-home"; mkdir -p "$fh2"; fv2="$work/f1b-vault"
HOME="$fh2" bash "$adopt" --profile luna --scope user --target "$fv2" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh2/.claude/settings.json")
[ "$got" = "$(norm "$fv2")" ] || fail "F1-SC1(b) luna/user --target: LUNA_VAULT_PATH=[$got] != [$(norm "$fv2")]"
echo "ok: F1-SC1(b) luna/user --target persists LUNA_VAULT_PATH"

# 8c. arg fix: --profile luna honors --luna-target when --target is left default.
fh3="$work/f1c-home"; mkdir -p "$fh3"; fv3="$work/f1c-vault"
HOME="$fh3" bash "$adopt" --profile luna --scope user --luna-target "$fv3" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh3/.claude/settings.json")
[ "$got" = "$(norm "$fv3")" ] || fail "luna --luna-target honored: LUNA_VAULT_PATH=[$got] != [$(norm "$fv3")]"
[ -f "$fv3/README.md" ] || fail "luna --luna-target did not scaffold to --luna-target"
echo "ok: --profile luna honors --luna-target (no longer a silent no-op)"

# 8d. unconditional wiring: a re-run over an EXISTING scaffold (copy skipped)
#     must STILL write the env key — fixes a previously-unwired install.
fh4="$work/f1d-home"; mkdir -p "$fh4"; fv4="$work/f1d-vault"; mkdir -p "$fv4"
HOME="$fh4" bash "$adopt" --profile luna --scope user --luna-target "$fv4" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh4/.claude/settings.json")
[ "$got" = "$(norm "$fv4")" ] || fail "dest-preexists: LUNA_VAULT_PATH not written ([$got] != [$(norm "$fv4")])"
echo "ok: re-run over existing scaffold still wires LUNA_VAULT_PATH (unconditional)"

# ── 9. hook paths forward-slashed + quoted; re-wire REPLACES a
#       pre-existing broken backslash entry (basename dedup), keeps non-himmel ──
h9="$work/h9"; mkdir -p "$h9/.claude"
# seed a BROKEN backslash auto-approve entry (the adopt.ps1 bug) + a non-himmel hook
printf '%s' '{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash C:\\Users\\me\\Himmel/scripts/hooks/auto-approve-safe-bash.sh"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"C:/x/scripts/hooks/rtk-hook-guard.sh\""}]}
]}}' > "$h9/.claude/settings.json"
HOME="$h9" bash "$adopt" --profile core --scope user --target "$work/ign9" >/dev/null
s9="$h9/.claude/settings.json"
aa=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))' "$s9")
[ -n "$aa" ] || fail "hookpath: auto-approve hook missing after re-wire"
[ "$(printf '%s\n' "$aa" | wc -l)" = "1" ] || fail "hookpath: expected exactly ONE auto-approve entry (got: $aa)"
# shellcheck disable=SC1003  # '\' is a literal-backslash glob pattern, not a quote escape
case "$aa" in *'\'*) fail "hookpath: auto-approve command still contains a backslash: $aa" ;; esac
case "$aa" in 'bash "'*'/scripts/hooks/auto-approve-safe-bash.sh"') : ;; *) fail "hookpath: auto-approve not forward-slash+quoted: $aa" ;; esac
jq -e '.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))' "$s9" >/dev/null || fail "hookpath: rtk-hook-guard not preserved"
echo "ok: hooks forward-slash+quoted; broken entry replaced; rtk kept"

# 9b. hook-object granularity: a non-himmel hook co-located in the SAME hooks[]
#     array as a himmel hook must SURVIVE re-wire (not dropped with the stanza).
h9b="$work/h9b"; mkdir -p "$h9b/.claude"
printf '%s' '{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[
    {"type":"command","command":"bash C:\\old\\Himmel/scripts/hooks/auto-approve-safe-bash.sh"},
    {"type":"command","command":"bash \"C:/x/scripts/hooks/rtk-hook-guard.sh\""}
  ]}
]}}' > "$h9b/.claude/settings.json"
HOME="$h9b" bash "$adopt" --profile core --scope user --target "$work/ign9b" >/dev/null
s9b="$h9b/.claude/settings.json"
jq -e '.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))' "$s9b" >/dev/null \
  || fail "hookpath(nested): co-located rtk-hook-guard dropped with the himmel stanza"
[ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length' "$s9b")" = "1" ] \
  || fail "hookpath(nested): expected exactly one auto-approve after re-wire"
echo "ok: co-located non-himmel hook survives re-wire (hook-object granularity)"

# ── 10. HIMMEL-752 qmd wiring: --dry-run emits the qmd step DRY lines ───────
# Force has_qmd=false deterministically: fake HOME (no ~/.bun/.../qmd.js) on the
# suite-wide qmd/bun-scrubbed PATH (computed at the top), so wire_qmd_core
# reaches its install/register steps even on a dev box that has a real qmd
# installed. bun is stubbed (exit 0) so require_tools leaves BUN_AVAILABLE at
# its default (1). --dry-run is side-effect-free (the wire helpers honor the
# dry flag).
qbin="$work/qbin"; mkdir -p "$qbin"
cat > "$qbin/bun" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$qbin/bun"
qhome="$work/qhome"; mkdir -p "$qhome"
# --with-graphify rides this dry-run (HIMMEL-891 CR-5b): opted-in + --dry-run
# must emit the graphify DRY line (and nothing real — dry-run never installs).
set +e
out=$(PATH="$qbin:$work/bin:$qmd_free_path" HOME="$qhome" bash "$adopt" \
      --profile all --scope user --target "$work/ign-q" --luna-target "$work/qvault" --with-graphify --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "dry-run adopt exited rc=$rc (expected 0)"
grepq "$out" 'DRY:.*fix-qmd-stub'    || fail "dry-run missing fix-qmd-stub DRY line"
grepq "$out" 'DRY: qmd_install'      || fail "dry-run missing qmd_install DRY line"
grepq "$out" 'DRY: qmd pull'         || fail "dry-run missing qmd pull DRY line"
grepq "$out" 'DRY: qmd_register_collection .* himmel$' || fail "dry-run missing himmel register DRY line"
grepq "$out" 'DRY: qmd_register_collection .* luna$'   || fail "dry-run missing luna register DRY line"
# HIMMEL-839: dry-run must also report the HANDOVER_DIR seed step (no mkdir,
# no settings.json write — mirrors the mkdir-then-wire pair as DRY lines).
grepq "$out" 'DRY: mkdir -p .*/qvault/handovers$' || fail "dry-run missing HANDOVER_DIR mkdir DRY line"
grepq "$out" 'DRY: wire env.HANDOVER_DIR' || fail "dry-run missing HANDOVER_DIR wire DRY line"
grepq "$out" 'Wiring graphify (opt-in' || fail "dry-run --with-graphify missing the graphify wiring banner"
grepq "$out" 'DRY: graphify_install'   || fail "dry-run --with-graphify missing graphify_install DRY line"
# HIMMEL-1047: --with-graphify also registers the MCP server at the adopt scope
# (here --scope user), so the dry-run must emit the mcp-add DRY line.
grepq "$out" 'DRY: claude mcp add -s user graphify' || fail "dry-run --with-graphify missing the graphify MCP registration DRY line"
# HIMMEL-842 gap 3: build_jira_cli runs after install_plugins; with npm scrubbed
# suite-wide and bun stubbed present, it picks bun and emits its DRY build line.
grepq "$out" 'DRY:.*(cd scripts/jira && bun install && bun run build)' || fail "dry-run missing build_jira_cli DRY line"
echo "ok: dry-run emits all qmd step DRY lines (core G1/G3/G4 + luna G5) + build_jira_cli + graphify opt-in DRY"

# ── 11. HIMMEL-877 qmd WARN-not-fail: a failing qmd install never aborts adopt
# bun present (stubbed) + a `git` stub that fails on `clone` + has_qmd=false
# (scrubbed PATH, fake HOME) -> qmd_install is invoked, the fork clone fails,
# and wire_qmd_core WARNs, but adopt still exits 0 (qmd is best-effort). The
# git stub keeps this hermetic — no real network clone of the fork repo. Fake
# HOME keeps settings writes isolated.
fbin="$work/fbin"; mkdir -p "$fbin"
cat > "$fbin/bun" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$fbin/bun"
cat > "$fbin/git" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "clone" ] && exit 1
exit 0
STUB
chmod +x "$fbin/git"
# Argv-logging uv stub (HIMMEL-891 CR-5a): this run passes NO --with-graphify,
# so graphify must stay completely un-wired — the stub's log proves no
# `uv tool install` ever fires on a default core adopt (the HIMMEL-621
# open-verdict contract: opt-in only, never default).
cat > "$fbin/uv" <<STUB
#!/usr/bin/env bash
echo "UV \$*" >> "$work/uv-calls-11"
exit 0
STUB
chmod +x "$fbin/uv"
: > "$work/uv-calls-11"
fhome="$work/fhome"; mkdir -p "$fhome"
set +e
out=$(PATH="$fbin:$work/bin:$qmd_free_path" HOME="$fhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-f" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "adopt must exit 0 when qmd install fails (WARN-not-fail), got rc=$rc"
grepq "$out" 'Installing qmd fork' || fail "qmd_install not invoked (call order)"
grepq "$out" -E 'WARNING.*qmd install failed' || fail "missing qmd install WARNING (WARN-not-fail)"
echo "ok: qmd install failure WARNs and adopt continues (WARN-not-fail, rc=0)"
# HIMMEL-891 CR-5a: graphify default-OFF, behaviorally asserted on the run above.
if grepq "$out" 'Wiring graphify'; then
  fail "default core adopt (no --with-graphify) ran the graphify wiring (opt-in regression)"
fi
if grep -q 'tool install' "$work/uv-calls-11"; then
  fail "default core adopt (no --with-graphify) invoked uv tool install (opt-in regression)"
fi
echo "ok: graphify stays un-wired on a default core adopt (opt-in only, zero uv installs)"

# ── 11b. HIMMEL-877 CR codex-adv-1: an existing UPSTREAM install MIGRATES ────
# A real @tobilu/qmd directory at the bun-global path + a working stubbed bun
# make has_qmd TRUE -- the exact population the fork change repairs. The
# install gate is qmd_fork_served (not presence), so adopt must still run
# qmd_install: back the upstream dir up and link the fork over the global
# path -- never skip and report success on the EPERM-prone upstream install.
# Stubs keep it hermetic: git clone fabricates the fork clone locally, bun
# fabricates the build output; no network, fake HOME.
mbin="$work/mbin"; mkdir -p "$mbin"
cat > "$mbin/bun" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  install) exit 0 ;;
  run) [ "$2" = "build" ] && { mkdir -p dist/cli; : > dist/cli/qmd.js; }; exit 0 ;;
  *) echo "qmd 2.6.10"; exit 0 ;;
esac
STUB
chmod +x "$mbin/bun"
# The stub answers the pin check with the pin adopt.sh will actually check:
# the ambient QMD_FORK_REF override when one is set (the same precedence
# _qmd_fork_ref uses, and the shape HIMMEL-2452's own positive control ran),
# otherwise the compiled-in default read out of qmd-bin.sh. A hardcoded copy
# drifts on the next pin bump and silently fails this case before it reaches
# the migration branch it asserts on (HIMMEL-2452).
QMD_STUB_HEAD_SHA="${QMD_FORK_REF:-$(sed -n 's/.*QMD_FORK_REF:-\([0-9a-f]\{40\}\).*/\1/p' \
  "$repo_root/scripts/lib/qmd-bin.sh" | head -1)}"
[ -n "$QMD_STUB_HEAD_SHA" ] \
  || fail "could not read QMD_FORK_REF out of scripts/lib/qmd-bin.sh"
export QMD_STUB_HEAD_SHA
cat > "$mbin/git" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-C" ]; then shift 2; fi
case "$1" in
  # HIMMEL-911 replaced `git clone` with init+fetch-by-sha+checkout, so the
  # stub must materialize the dir on `init` (clone kept for back-compat) and
  # answer the belt-and-braces `rev-parse HEAD` with the pinned fork SHA --
  # otherwise install refuses before the migration ("moving aside") branch
  # this case exercises ever runs (HIMMEL-934).
  clone|init) target="${!#}"; mkdir -p "$target/.git"; exit 0 ;;
  # Only the exact `rev-parse HEAD` query the pin check performs gets the
  # SHA; other rev-parse forms keep the silent-success default (coderabbit
  # finding, HIMMEL-934 CR round).
  rev-parse) [ "${2:-}" = "HEAD" ] && echo "${QMD_STUB_HEAD_SHA:-}"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$mbin/git"
mhome="$work/mhome"
mkdir -p "$mhome/.bun/install/global/node_modules/@tobilu/qmd/dist/cli"
: > "$mhome/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"  # upstream: has_qmd=TRUE
set +e
out=$(PATH="$mbin:$work/bin:$qmd_free_path" HOME="$mhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-m" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "migration adopt exited rc=$rc (expected 0)"
grepq "$out" 'Installing qmd fork' \
  || fail "upstream-present install did not trigger the fork install (presence-gate regression)"
grepq "$out" 'moving aside' || fail "upstream dir was not moved aside"
[ -d "$mhome/.bun/install/global/node_modules/@tobilu/qmd.pre-fork-backup" ] \
  || fail "upstream backup dir missing after migration"
[ -e "$mhome/.himmel/qmd-fork/dist/cli/qmd.js" ] || fail "fork clone was not built"
[ -e "$mhome/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js" ] \
  || fail "global path does not serve the fork after migration"
echo "ok: existing upstream install migrates to the fork (backup + link, not skipped)"

# ── 12. HIMMEL-842 gap 2: node-without-npm + no JS package manager -> HARD fail ──
# Stub node on PATH but provide NO npm; bun is already absent suite-wide, so the
# node-without-npm check finds no JS package manager and adopt must exit non-zero
# with the bun.sh + NodeSource install hints. npm dirs are scrubbed from the
# suite-wide bun/qmd-scrubbed PATH (node + npm usually share a bin dir, so dropping
# the npm dir also drops real node — the stub node re-adds node deterministically).
nbin="$work/nbin"; mkdir -p "$nbin"
cat > "$nbin/node" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$nbin/node"
npm_free_path=""
_save_ifs="$IFS"; IFS=':'
for _d in $qmd_free_path; do
  [ -x "$_d/npm" ] && continue
  npm_free_path="${npm_free_path:+$npm_free_path:}$_d"
done
IFS="$_save_ifs"
ntarget="$work/ntarget"; nhome="$work/nhome"; mkdir -p "$ntarget" "$nhome"
set +e
out=$(PATH="$nbin:$work/bin:$npm_free_path" HOME="$nhome" bash "$adopt" \
      --profile core --scope project --target "$ntarget" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "node-without-npm + no bun should exit non-zero (got $rc)"
grepq "$out" 'npm' || fail "node-without-npm msg missing 'npm'"
grepq "$out" 'bun.sh' || fail "node-without-npm msg missing bun.sh hint"
grepq "$out" -i 'nodesource' || fail "node-without-npm msg missing nodesource hint"
echo "ok: node-without-npm + no JS package manager -> hard fail (rc=$rc) + install hints"

# ── 13. HIMMEL-842 gap 2: node-without-npm WITH bun -> soft warn, adopt proceeds ─
# bun covers every himmel JS build, so node-without-npm is only a SOFT warn when
# bun is present (no hard fail). --dry-run keeps the run side-effect-free.
nbin2="$work/nbin2"; mkdir -p "$nbin2"
printf '#!/usr/bin/env bash\nexit 0\n' > "$nbin2/node"; chmod +x "$nbin2/node"
printf '#!/usr/bin/env bash\nexit 0\n' > "$nbin2/bun";  chmod +x "$nbin2/bun"
ntarget2="$work/ntarget2"; nhome2="$work/nhome2"; mkdir -p "$ntarget2" "$nhome2"
set +e
out=$(PATH="$nbin2:$work/bin:$npm_free_path" HOME="$nhome2" bash "$adopt" \
      --profile core --scope project --target "$ntarget2" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "node-without-npm + bun should proceed (got $rc)"
grepq "$out" 'npm' || fail "node-without-npm+bun missing soft warn"
if grepq "$out" 'no JS package manager'; then
  fail "node-without-npm+bun must NOT hard-fail (saw hard-fail message)"
fi
echo "ok: node-without-npm + bun present -> soft warn, adopt proceeds (rc=0)"

# ── 14. HIMMEL-842 gap 3: build_jira_cli success path (stub npm exit 0) ───────
# npm scrubbed suite-wide; re-add a stub npm (exit 0) so build_jira_cli picks npm,
# the (cd scripts/jira && npm install && npm run build) subshell "succeeds", and
# adopt reports the build + continues. dist/index.js is not actually created by
# the stub — the assertion is on the reported outcome, not the artifact.
bjbin="$work/bjbin"; mkdir -p "$bjbin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$bjbin/npm"; chmod +x "$bjbin/npm"
bjhome="$work/bjhome"; mkdir -p "$bjhome"
set +e
out=$(PATH="$bjbin:$work/bin:$qmd_free_path" HOME="$bjhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bj" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build_jira_cli success path: adopt should exit 0 (got $rc)"
grepq "$out" 'Building jira CLI' || fail "build_jira_cli: missing 'Building jira CLI' header"
grepq "$out" 'jira CLI built'    || fail "build_jira_cli: missing success message"
if grepq "$out" 'jira CLI build failed'; then
  fail "build_jira_cli: success path must not print a build-failed warning"
fi
echo "ok: build_jira_cli success path (stub npm) reports built, adopt exits 0"

# ── 15. HIMMEL-842 gap 3: build_jira_cli WARN-not-fail (stub npm exit 1) ──────
# A failing build must WARN with the manual command and return 0 — matches
# wire_qmd_core's contract; a broken jira build never aborts adopt.
bfbin="$work/bfbin"; mkdir -p "$bfbin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$bfbin/npm"; chmod +x "$bfbin/npm"
bfhome="$work/bfhome"; mkdir -p "$bfhome"
set +e
out=$(PATH="$bfbin:$work/bin:$qmd_free_path" HOME="$bfhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bf" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build_jira_cli WARN-not-fail: adopt must exit 0 on a build failure (got $rc)"
grepq "$out" -E 'WARNING.*jira CLI build failed' || fail "build_jira_cli: missing build-failed WARNING"
grepq "$out" 'npm install && npm run build'     || fail "build_jira_cli: missing manual command in WARNING"
echo "ok: build_jira_cli failure WARNs with manual command, adopt continues (rc=0)"

# ── 16. HIMMEL-842 gap 3: build_jira_cli skip when no JS package manager ──────
# npm AND bun both absent (the scrubbed suite base) -> build_jira_cli skips with
# the manual command and never attempts a build. A real run, not --dry-run, so
# the skip branch (not the DRY branch) is exercised.
skhome="$work/skhome"; mkdir -p "$skhome"
set +e
out=$(PATH="$work/bin:$qmd_free_path" HOME="$skhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-sk" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build_jira_cli skip path: adopt should exit 0 (got $rc)"
grepq "$out" 'jira CLI: skipping build (no npm or bun' || fail "build_jira_cli: missing no-pm skip note"
if grepq "$out" 'Building jira CLI'; then
  fail "build_jira_cli: no-pm path must NOT attempt a build (saw build header)"
fi
echo "ok: build_jira_cli skips (no npm/bun) with manual command, no build attempted"

# ── 17. HIMMEL-842 gap 3: build_jira_cli idempotent when dist AND node_modules
# already built (F3: the skip now requires BOTH halves present) ─────────────
# The suite-wide move-aside at the top guarantees scripts/jira/dist and
# scripts/jira/node_modules are both absent entering this scenario; create
# both so build_jira_cli's "already built" branch fires. Removed right after
# (dist/ and node_modules/ are gitignored, so this never pollutes git); the
# suite-wide trap restores the real ones unconditionally regardless.
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
mkdir -p "$real_jira_node_modules"
bjhome2="$work/bjhome2"; mkdir -p "$bjhome2"
set +e
out=$(PATH="$bjbin:$work/bin:$qmd_free_path" HOME="$bjhome2" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bj2" 2>&1); rc=$?
set -e
rm -rf "$real_jira_dist" "$real_jira_node_modules"
[ "$rc" -eq 0 ] || fail "build_jira_cli idempotent path: adopt should exit 0 (got $rc)"
grepq "$out" 'jira CLI dist already built' || fail "build_jira_cli: missing 'already built' skip"
if grepq "$out" 'Building jira CLI'; then
  fail "build_jira_cli: already-built path must NOT attempt a build"
fi
echo "ok: build_jira_cli idempotent when dist/index.js + node_modules already present (skips build)"

# ── 18. HIMMEL-842 gap 3 (F3): dist present but node_modules ABSENT -> build
# must NOT skip ────────────────────────────────────────────────────────────
# A stale dist/ without node_modules/ previously passed as "already built"
# then failed at runtime — F3's fix requires BOTH halves present to skip.
mkdir -p "$real_jira_dist"; : > "$real_jira_dist/index.js"
# node_modules stays absent (suite-wide baseline).
bjhome3="$work/bjhome3"; mkdir -p "$bjhome3"
set +e
out=$(PATH="$bjbin:$work/bin:$qmd_free_path" HOME="$bjhome3" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bj3" 2>&1); rc=$?
set -e
rm -rf "$real_jira_dist"
[ "$rc" -eq 0 ] || fail "dist-present/node_modules-absent: adopt should exit 0 (got $rc)"
grepq "$out" 'Building jira CLI' || fail "dist-present/node_modules-absent: build_jira_cli should NOT skip (missing build header)"
if grepq "$out" 'jira CLI dist already built'; then
  fail "dist-present/node_modules-absent: must NOT take the already-built skip branch"
fi
echo "ok: build_jira_cli builds when dist present but node_modules absent (F3 invariant)"

# ── 19. HIMMEL-842 gap 3 (F5): build_jira_cli bun branch, REAL invocation ────
# npm absent (suite-wide scrub), bun stubbed; assert the bun install/build
# lines actually ran (success path is enough per F5) — the bun branch was
# previously only exercised via --dry-run (scenario 10).
bubin="$work/bubin"; mkdir -p "$bubin"
cat > "$bubin/bun" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  install) echo "BUN_INSTALL_STUB_RAN" ;;
  run) [ "$2" = "build" ] && echo "BUN_BUILD_STUB_RAN" ;;
esac
exit 0
STUB
chmod +x "$bubin/bun"
buhome="$work/buhome"; mkdir -p "$buhome"
set +e
out=$(PATH="$bubin:$work/bin:$qmd_free_path" HOME="$buhome" bash "$adopt" \
      --profile core --scope user --target "$work/ign-bu" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "build_jira_cli bun real-invocation: adopt should exit 0 (got $rc)"
grepq "$out" 'BUN_INSTALL_STUB_RAN' || fail "build_jira_cli bun real-invocation: bun install did not run"
grepq "$out" 'BUN_BUILD_STUB_RAN'   || fail "build_jira_cli bun real-invocation: bun run build did not run"
grepq "$out" 'jira CLI built' || fail "build_jira_cli bun real-invocation: missing success message"
echo "ok: build_jira_cli bun branch real-invocation runs install + build (F5)"

# ── 19b. HIMMEL-2441: install_precommit_hooks places the git gate hooks ──────
# A stub `pre-commit` in a dedicated $pcbin dir (put FIRST on PATH, ahead of
# any real pre-commit the dev box might have installed via pipx/uv outside
# the qmd/bun/npm/node/uv/pipx scrub list) logs its argv to a file and exits
# 0 or 1 on demand — this proves adopt.sh actually shells out to `pre-commit
# install ...` against $TARGET, not just that it prints a message. Scoped to
# this block only (PATH= prefix per invocation, never exported) so the stub
# can never leak into an earlier scenario or run against a real repo — every
# $TARGET below is a disposable temp dir this block git-inits itself.
pcbin="$work/pcbin"; mkdir -p "$pcbin"
pchome="$work/pchome"; mkdir -p "$pchome"

# default: no --skip-hooks -> pre-commit install runs against $TARGET with
# all 3 hook types, adopt reports success, rc=0.
cat > "$pcbin/pre-commit" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$work/pre-commit.argv"
exit 0
STUB
chmod +x "$pcbin/pre-commit"
: > "$work/pre-commit.argv"
pctarget19b1="$work/pctarget19b1"; mkdir -p "$pctarget19b1"
( cd "$pctarget19b1" && HOME="$pchome" git init -q )
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b1" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 default: adopt should exit 0 (got $rc): $out"
grepq "$(cat "$work/pre-commit.argv")" \
  'install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push' \
  || fail "HIMMEL-2441 default: pre-commit install was not invoked with all 3 hook types (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" 'git hooks installed (pre-commit, commit-msg, pre-push).' \
  || fail "HIMMEL-2441 default: missing the git-hooks-installed message (got: $out)"
echo "ok: HIMMEL-2441 default adopt wires pre-commit/commit-msg/pre-push hooks into \$TARGET"

# HIMMEL-2771: collect all five controls so the first missing fallback does
# not hide the behavioural failure. Each subshell retains the fail idiom.
native_failures=0
native_free_path=$(scrub_path "$qmd_free_path" pre-commit uv pipx)
for native_case in missing framework pep668 unwritable behaviour; do
  set +e
  (
    set -e
    ntarget="$work/native-$native_case"
    nbin="$work/native-bin-$native_case"
    mkdir -p "$ntarget" "$nbin"
    HOME="$pchome" git -C "$ntarget" init -q
    HOME="$pchome" git -C "$ntarget" checkout -q -b feat/native-test
    npath="$nbin:$work/bin:$native_free_path"
    if [ "$native_case" = framework ]; then
      npath="$pcbin:$npath"
      : > "$work/pre-commit.argv"
    fi
    if [ "$native_case" = pep668 ]; then
      cat > "$nbin/python3" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-m" ] && [ "\$2" = "pip" ]; then
  echo 'error: externally-managed-environment' >&2
  exit 1
fi
exec "$real_python3" "\$@"
STUB
      chmod +x "$nbin/python3"
    fi
    if [ "$native_case" = unwritable ]; then
      chmod a-w "$ntarget/.git/hooks"
      [ ! -w "$ntarget/.git/hooks" ] || fail "HIMMEL-2771 unwritable: fixture requires an unprivileged user"
    fi
    set +e
    nout=$(PATH="$npath" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$ntarget" 2>&1); nrc=$?
    set -e
    case "$native_case" in
      missing|pep668)
        [ "$nrc" -eq 0 ] || fail "HIMMEL-2771 $native_case: adopt exited $nrc"
        if [ "$native_case" = pep668 ]; then
          grepq "$nout" 'externally-managed-environment' \
            || fail "HIMMEL-2771 pep668: refusal was not reported by name"
        fi
        for hook in commit-msg pre-commit pre-push; do
          [ -x "$ntarget/.git/hooks/$hook" ] \
            || fail "HIMMEL-2771 $native_case: executable $hook hook absent"
        done
        grepq "$nout" 'git gate hooks — placed (native, no pre-commit framework: lint hooks absent)' \
          || fail "HIMMEL-2771 $native_case: native summary absent"
        ;;
      framework)
        [ "$nrc" -eq 0 ] || fail "HIMMEL-2771 framework: adopt exited $nrc"
        grepq "$(cat "$work/pre-commit.argv")" 'install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push' \
          || fail "HIMMEL-2771 framework: install not called"
        ! grepq "$nout" 'placed (native' || fail "HIMMEL-2771 framework: native fallback taken"
        ;;
      unwritable)
        chmod u+w "$ntarget/.git/hooks"
        [ "$nrc" -ne 0 ] || fail "HIMMEL-2771 unwritable: adopt exited 0 with no gates"
        grepq "$nout" 'git gate hooks — FAILED (native:' \
          || fail "HIMMEL-2771 unwritable: failure summary absent"
        # HIMMEL-2814: $ntarget is the PRIMARY checkout with core.hooksPath
        # unset, so the fallback payload copy (now always attempted for
        # Git's own shared per-repository hooks dir, per the gap-1 fix) is
        # the FIRST write into the unwritable hooks dir and fails before the
        # dispatcher-writing loop below it ever runs -- the failure reason
        # moved from "cannot write .../commit-msg" to the payload mkdir/cp.
        grepq "$nout" "cannot copy scripts/hooks/check-commit-msg.sh into $ntarget/.git/hooks/himmel-payload" \
          || fail "HIMMEL-2771 unwritable: failure reason absent"
        ;;
      behaviour)
        [ "$nrc" -eq 0 ] || fail "HIMMEL-2771 behaviour: adopt exited $nrc"
        HOME="$pchome" git -C "$ntarget" config user.name 'Native Test'
        HOME="$pchome" git -C "$ntarget" config user.email 'native@example.invalid'
        set +e
        nout=$(HOME="$pchome" git -C "$ntarget" -c commit.gpgsign=false commit --allow-empty -m 'no ticket here at all' 2>&1); nrc=$?
        set -e
        [ "$nrc" -ne 0 ] || fail "HIMMEL-2771 behaviour: unticketed commit landed"
        ! git -C "$ntarget" rev-parse --verify HEAD >/dev/null 2>&1 \
          || fail "HIMMEL-2771 behaviour: rejected commit created HEAD"
        # Also isolate the ticket check from the conventional-format check.
        if HOME="$pchome" git -C "$ntarget" -c commit.gpgsign=false commit --allow-empty -m 'test: missing ticket' >/dev/null 2>&1; then
          fail "HIMMEL-2771 behaviour: conventional unticketed commit landed"
        fi
        HOME="$pchome" git -C "$ntarget" -c commit.gpgsign=false commit --allow-empty -m 'test: HIMMEL-2771 [#2771] native gates' >/dev/null 2>&1 \
          || fail "HIMMEL-2771 behaviour: ticketed commit refused"
        git -C "$ntarget" rev-parse --verify HEAD >/dev/null \
          || fail "HIMMEL-2771 behaviour: ticketed commit did not create HEAD"
        ;;
    esac
    echo "ok: HIMMEL-2771 $native_case"
  )
  native_rc=$?
  set -e
  if [ "$native_rc" -ne 0 ]; then native_failures=$((native_failures + 1)); fi
done
[ "$native_failures" -eq 0 ] || fail "HIMMEL-2771 controls: $native_failures failed, $((5 - native_failures)) passed"

# HIMMEL-2771: exercise the remaining bootstrap exits and Git's configured
# hooks directory. User scope must also carry its own native gate payloads.
for fallback_case in uv-fails pipx-fails unresolved user-hooks-path skip; do
  ntarget="$work/fallback-$fallback_case"; nbin="$work/fallback-bin-$fallback_case"
  mkdir -p "$ntarget" "$nbin"
  HOME="$pchome" git -C "$ntarget" init -q
  nscope=project; hook_dir="$ntarget/.git/hooks"; extra_flag=""
  case "$fallback_case" in
    uv-fails|pipx-fails|unresolved)
      installer="${fallback_case%-fails}"; installer_rc=1
      if [ "$fallback_case" = unresolved ]; then installer=uv; installer_rc=0; fi
      printf '#!/usr/bin/env bash\nexit %s\n' "$installer_rc" > "$nbin/$installer"
      chmod +x "$nbin/$installer"
      ;;
    user-hooks-path)
      nscope=user; hook_dir="$ntarget/native hooks"
      HOME="$pchome" git -C "$ntarget" config core.hooksPath 'native hooks'
      ;;
    skip) extra_flag=--skip-hooks ;;
  esac
  out=$(PATH="$nbin:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
    --profile core --scope "$nscope" --target "$ntarget" ${extra_flag:+"$extra_flag"} 2>&1) \
    || fail "HIMMEL-2771 $fallback_case: adoption failed: $out"
  if [ "$fallback_case" = skip ]; then
    [ ! -e "$hook_dir/commit-msg" ] || fail "HIMMEL-2771 skip: native hook placed"
  else
    for hook in commit-msg pre-commit pre-push; do
      [ -x "$hook_dir/$hook" ] || fail "HIMMEL-2771 $fallback_case: $hook absent"
    done
    printf 'test: HIMMEL-2771 [#2771] native gates\n' > "$ntarget/message"
    ( cd "$ntarget" && HOME="$pchome" bash "$hook_dir/commit-msg" "$ntarget/message" ) \
      || fail "HIMMEL-2771 $fallback_case: native message gate failed"
  fi
  echo "ok: HIMMEL-2771 $fallback_case"
done

# HIMMEL-2771 CR round-1 (Important, confirmed): install_native_hooks() must
# not clobber a pre-existing hand-written hook, must stay idempotent about
# its OWN generated hooks, and must refuse an absolute/shared core.hooksPath
# rather than write dispatcher hooks into it (they resolve $(git rev-parse
# --show-toplevel) at FIRE time, so a hooksPath shared by other repos would
# break commits there the instant this repo adopts).

# 1. An existing hand-written hook is preserved, not truncated.
crtarget1="$work/cr2771-foreign"; crbin1="$work/cr2771-foreign-bin"
mkdir -p "$crtarget1" "$crbin1"
HOME="$pchome" git -C "$crtarget1" init -q
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
# HIMMEL-2771: pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
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

# HIMMEL-2771 CR round-2 (confirmed): _native_hooks_canon() used LOGICAL
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
# HIMMEL-2771: pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside6" \
  || fail "HIMMEL-2771 CR2 symlink-escape: a hook was written through the symlink into the outside dir"
echo "ok: HIMMEL-2771 CR2 symlink-escape refuses a hooksPath symlinked outside the target"

# HIMMEL-2771 CR round-3 (confirmed): _native_hooks_canon()'s walk-up reattaches
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
# HIMMEL-2771: pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside10" \
  || fail "HIMMEL-2771 CR3 dotdot-escape: a hook was written through the unfolded ../.. into the outside dir"
echo "ok: HIMMEL-2771 CR3 dotdot-escape refuses a hooksPath whose unfolded ../.. tail escapes the target"

# HIMMEL-2771 CR round-4 (confirmed): folding "." and ".." out of the
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
# HIMMEL-2771: pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside11" \
  || fail "HIMMEL-2771 CR4 dotdot-symlink-escape: a hook was written through the re-exposed symlink into the outside dir"
echo "ok: HIMMEL-2771 CR4 dotdot-symlink-escape refuses a hooksPath whose ../ fold re-exposes a symlink out of the target"

# HIMMEL-2771 CR round-5 (codex-1, confirmed): the containment check above
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

# HIMMEL-2771 CR round-5 (codex-2, confirmed): the directory-level containment
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
ln -s "$croutside13/pwned" "$crtarget13/.git/hooks/commit-msg"
set +e
out=$(PATH="$crbin13:$work/bin:$native_free_path" HOME="$pchome" bash "$adopt" \
  --profile core --scope project --target "$crtarget13" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: adopt exited $rc: $out"
# HIMMEL-2771: pure-shell -- `ls` is not guaranteed reachable under the hermetic PATH here (see dir_is_empty above).
dir_is_empty "$croutside13" \
  || fail "HIMMEL-2771 CR5 symlink-dangling: a file was created outside the target through the dangling symlink"
[ -f "$crtarget13/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: hooks-dir entry is not a regular file after adopt"
[ ! -L "$crtarget13/.git/hooks/commit-msg" ] \
  || fail "HIMMEL-2771 CR5 symlink-dangling: hooks-dir entry is still a symlink after adopt"
grepq "$(cat "$crtarget13/.git/hooks/commit-msg")" 'HIMMEL-2771: native invariant gate' \
  || fail "HIMMEL-2771 CR5 symlink-dangling: replacement entry is not the native gate"
echo "ok: HIMMEL-2771 CR5 symlink-dangling: a dangling hook symlink is backed up (not followed) and replaced with a real file"

# HIMMEL-2771 CR round-5 (codex-2, confirmed): shape (b) -- a symlink at
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
sentinel14='echo "SENTINEL cr2771r5-symlink-marker: outside file must not be truncated"'
cat > "$croutside14" <<OUTSIDEHOOK
#!/usr/bin/env bash
# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.
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

# HIMMEL-2771 CR round-6 (codex-1, confirmed): round-5's fix above teaches
# adopt to ACCEPT the shared Git common-directory hooks layout, but the
# payload (scripts/hooks/*.sh + guardrails/lib.sh) was copied only into
# $TARGET (the linked worktree). Git's hooks are per-REPOSITORY, not
# per-worktree, so that one hooks dir also serves the PRIMARY checkout (and
# any sibling worktree) -- neither of which received a payload. Their shared
# dispatcher resolves `$root/scripts/hooks/<script>` against ITS OWN
# toplevel (the primary, not the adopted worktree), finds nothing, and every
# commit/push there starts failing with a bash "No such file or directory"
# error -- round 5 traded a false refusal for a real breakage of a checkout
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

# HIMMEL-2771 CR round-6 (codex-2, confirmed): direct self-test of
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

# HIMMEL-2771 CR round-2 (confirmed): a pre-existing foreign hook is backed up
# to <hook>.himmel-backup but the generated dispatcher never ran it again, so
# the adopter's own gate was silently disabled. This is the control that
# matters -- it proves enforcement was preserved, not merely that a file was
# kept: a presence-only assertion on .himmel-backup would pass today while
# the check is dead.
crtarget7="$work/cr2771r2-chain-fails"; crbin7="$work/cr2771r2-chain-fails-bin"
mkdir -p "$crtarget7" "$crbin7"
HOME="$pchome" git -C "$crtarget7" init -q
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

# HIMMEL-2771 CR round-2: the flip side of chain-fails -- a chained backup
# hook that PASSES must not break the himmel gate itself (no double-negative,
# no rc-mangling that turns a real himmel-gate refusal into a pass).
crtarget8="$work/cr2771r2-chain-passes"; crbin8="$work/cr2771r2-chain-passes-bin"
mkdir -p "$crtarget8" "$crbin8"
HOME="$pchome" git -C "$crtarget8" init -q
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

# HIMMEL-2771 CR round-2 (confirmed): git feeds pre-push its ref list on
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
set +e
out=$(PATH="$pcbin:$work/bin:$qmd_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b4" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441 --dry-run: adopt should exit 0 (got $rc): $out"
[ ! -s "$work/pre-commit.argv" ] || fail "HIMMEL-2441 --dry-run: pre-commit stub was invoked (argv: $(cat "$work/pre-commit.argv"))"
grepq "$out" "DRY: (cd $pctarget19b4 && pre-commit install --allow-missing-config" \
  || fail "HIMMEL-2441 --dry-run: missing the DRY git-hooks line (got: $out)"
echo "ok: HIMMEL-2441 --dry-run prints the git-hooks DRY line, pre-commit never invoked"

# HIMMEL-2771: framework hook installation failure falls back to native gates.
cat > "$pcbin/pre-commit" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$work/pre-commit.argv"
exit 1
STUB
chmod +x "$pcbin/pre-commit"
: > "$work/pre-commit.argv"
pctarget19b5="$work/pctarget19b5"; mkdir -p "$pctarget19b5"
( cd "$pctarget19b5" && HOME="$pchome" git init -q )
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

# HIMMEL-2441/2483 [codex-1, CR round 2]: a real `uv tool install pre-commit`
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

# HIMMEL-2441/2483 [round-3 panel, Important #1]: --dry-run must describe the
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

# HIMMEL-2771: no installer can run in dry-run; describe both framework
# bootstrap and the native fallback without writing any hooks.
pctarget19b8="$work/pctarget19b8"; mkdir -p "$pctarget19b8"
( cd "$pctarget19b8" && HOME="$pchome" git init -q )
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

# ── 19c. HIMMEL-2818: plugin failure must not leave an adopter ungated ───────
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
  : > "$work/plugin-failure-hooks.argv"
  hook_args=()
  [ "$hook_mode" != skip ] || hook_args+=(--skip-hooks)
  set +e
  out=$(PATH="$failurebin:$work/bin:$qmd_free_path" HOME="$failurehome" bash "$adopt" \
        --profile core --scope project --target "$failuretarget" "${hook_args[@]}" 2>&1); rc=$?
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

# HIMMEL-2814 gap 1 (mirror of cr2771r6-worktree-primary-gate, reversed): adopt
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

# HIMMEL-2814 gap 1, push variant (contract item 3): the same sibling
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
poutG1b=$(HOME="$pchome" git -C "$crwtG1" push origin cr2814g1-worktree-branch:refs/heads/cr2814g1-ok 2>&1); prcG1b=$?
set -e
[ "$prcG1b" -eq 0 ] \
  || fail "HIMMEL-2814 gap1 shared-payload push: a push to a non-main ref from the SIBLING worktree was refused: $poutG1b"
echo "ok: HIMMEL-2814 gap1 shared-payload push: the SIBLING worktree's pre-push dispatcher (added after the primary adopt) genuinely gates a real git push via its fallback payload"

# HIMMEL-2814 gap 2: the generated pre-push dispatcher's `cat > "$reffile"`
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

# HIMMEL-2814: confirm chmod 0444 actually blocks writes for the current user
# before relying on it below to force the capture failure -- as root (or on a
# filesystem where mode bits don't gate writes) this is a silent no-op and the
# suite would then fail because the push simply succeeded, not because the
# gate misbehaved. Same "fixture requires an unprivileged user" convention as
# the HIMMEL-2771 unwritable-hooks-dir case above.
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

# ── 21. HIMMEL-2892: the hook block MERGES into an existing settings.json ────
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
case "$c2892" in
  'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh"') : ;;
  *) fail "HIMMEL-2892 (c): the himmel-owned command was not repointed at this install's prefix (got: $c2892)" ;;
esac

# (d) exactly ONE block-edit-on-main entry (merged in place, not appended
#     alongside the existing one), and the two hooks that were genuinely ABSENT
#     are appended as fresh stanzas -> 2 seeded + 2 appended = 4.
[ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-edit-on-main"))] | length' "$s2892")" = "1" ] \
  || fail "HIMMEL-2892 (d): expected exactly one block-edit-on-main entry after the merge"
[ "$(jq '.hooks.PreToolUse | length' "$s2892")" = "4" ] \
  || fail "HIMMEL-2892 (d): expected 4 PreToolUse stanzas (2 seeded + the 2 genuinely-absent himmel hooks appended), got $(jq '.hooks.PreToolUse | length' "$s2892")"
echo "ok: HIMMEL-2892 the hook block merges into an existing settings.json (foreign matcher + co-located entry + adopter matcher/timeout preserved; himmel command repointed in place)"

# ── 20. HIMMEL-887 T10: himmelctl wizard + machine-setup shim suites ──────────
# A plain `bash scripts/test-adopt.sh` run also exercises the himmelctl install
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

# The win11 shim suite is a .ps1 (static source-parse of win11.ps1, HIMMEL-887
# T8) — needs pwsh. Skip (not fail) when pwsh is absent, same guard as the
# bootstrap.ps1 cases in test-wizard-bootstrap.sh.
_win11_shim="$repo_root/scripts/machine-setup/test-win11-shim.ps1"
[ -f "$_win11_shim" ] || fail "wizard suite not found: $_win11_shim"
if command -v pwsh >/dev/null 2>&1; then
  set +e
  PATH="$saved_path" pwsh -NoProfile -File "$_win11_shim" >"$work/wizard-suite.log" 2>&1
  _win11_rc=$?
  set -e
  if [ "$_win11_rc" -ne 0 ]; then
    tail -20 "$work/wizard-suite.log" >&2
    fail "wizard suite failed (rc=$_win11_rc): test-win11-shim.ps1"
  fi
  echo "ok: wizard suite green: test-win11-shim.ps1"
else
  echo "ok: wizard suite skipped (pwsh not found): test-win11-shim.ps1"
fi

echo "PASS"
