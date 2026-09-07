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

# pre-commit install fails (stub exits 1): WARN-not-fail, adopt still rc=0.
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
echo "ok: HIMMEL-2441 a failing pre-commit install WARNs, adopt continues (rc=0)"

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

# HIMMEL-2441/2483 [round-4 panel, codex-1]: the "neither uv nor pipx"
# branch WARNed and returned unconditionally, so --dry-run output still
# depended on host tooling in this one last case. No pre-commit, uv, or pipx
# anywhere on PATH ($pc_free_path is already uv/pipx/pre-commit-free -- it's
# $qmd_free_path, itself scrubbed of uv/pipx, further scrubbed of
# pre-commit; $work/bin only carries the hermetic bash/jq/claude stubs).
# adopt.sh must still print the WARNING (useful info, kept) AND fall through
# to the planned `pre-commit install` DRY: line, rc=0.
pctarget19b8="$work/pctarget19b8"; mkdir -p "$pctarget19b8"
( cd "$pctarget19b8" && HOME="$pchome" git init -q )
set +e
out=$(PATH="$work/bin:$pc_free_path" HOME="$pchome" bash "$adopt" \
      --profile core --scope project --target "$pctarget19b8" --dry-run 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "HIMMEL-2441/2483 --dry-run no-tool-at-all: adopt should exit 0 (got $rc): $out"
grepq "$out" "WARNING: git hooks: 'pre-commit' not found and neither uv nor pipx is available" \
  || fail "HIMMEL-2441/2483 --dry-run no-tool-at-all: missing the no-uv/pipx WARNING (got: $out)"
grepq "$out" "DRY: (cd $pctarget19b8 && pre-commit install --allow-missing-config" \
  || fail "HIMMEL-2441/2483 --dry-run no-tool-at-all: missing the planned pre-commit install DRY line (got: $out)"
echo "ok: HIMMEL-2441/2483 --dry-run with no pre-commit/uv/pipx at all still WARNs AND prints the plan"

# Remove the stub so it cannot affect any later scenario in this file — $pcbin
# was only ever added to PATH via a per-invocation prefix above (never
# exported), so this is belt-and-braces, not load-bearing.
rm -f "$pcbin/pre-commit"

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
