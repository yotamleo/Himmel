#!/usr/bin/env bash
# test-wizard-himmel-clone-target.sh — HIMMEL-2892: the himmel checkout is not
# a project TARGET, and the project-scope items a CONTRIBUTOR station really
# carries stop reading n/a.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + node; the surfaces under test (bin.js, lib/state.js) are JS, so
# there is no .ps1 twin to keep in step.
#
# WHY: 2026-09-09 dogfood — `himmelctl install --scope project` run inside the
# himmel checkout regenerated the repo's own tracked .claude/settings.json hook
# block from the manifest (98+/38-) and dropped a hud config inside the repo.
# That file is the SOURCE the installer generates from; the checkout is not an
# adopt target. The remedy the operator actually wanted is BOTH halves of the
# ticket: refuse project scope there, and let the user-scope record of a
# CONTRIBUTOR station probe the five scopes:["project"] items that
# scripts/setup.sh genuinely installs, instead of printing
# "n/a — not enabled for this target (profile/scope)" for things that are green.
#
# Covers:
#   a. RED control — `install --scope project` with cwd INSIDE the himmel clone
#      exits non-zero, names the checkout, and prints the remedy (setup.sh +
#      `install --scope user`). No install-profile cache is written: a refused
#      install must leave no `scope: project` record behind.
#   b. negative control (load-bearing) — an ORDINARY adopter repo that VENDORS
#      himmel's portable core (scripts/hooks/*, scripts/guardrails/lib.sh, even
#      a copy of adopt.sh) is NOT caught: `install --scope project` there
#      proceeds. A content heuristic would have failed this.
#   c. scope control — `install --scope user` from inside the himmel clone is
#      unaffected: the refusal is project-scope only, not a blanket refusal.
#   d. contributor membership — a user-scope report over an item carrying
#      contributorScopes:["user"] reads desired + PROBED on a devOverlay:true
#      (contributor) record...
#   e. ...and still reads n/a on a devOverlay:false (plain adopter) record, and
#      an item WITHOUT contributorScopes reads n/a on both. Without (e) the
#      change would be a blanket turn-everything-on.
#   a4. platform control — the remedy assertion in a/a2 follows uname, so Git
#      Bash asserts the pwsh rendering the diagnostic actually prints there
#      instead of reddening on correct behaviour (HIMMEL-2905).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath()
wizard="$repo_root/scripts/himmelctl/bin.js"
status_report_lib="$repo_root/scripts/himmelctl/lib/status-report.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$status_report_lib" ] || { echo "FAIL: $status_report_lib not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (printf-into-`grep -q` is a pipefail trap: grep exits on the first
# match, the producer takes SIGPIPE, and pipefail reports the PIPELINE failed).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-himmel-clone-target.XXXXXX") || exit 1
cleanup() { chmod -R u+w "$work" 2>/dev/null || true; command rm -rf -- "$work"; }
trap cleanup EXIT

STATUS_REPORT_LIB="$(winpath "$status_report_lib")"
export STATUS_REPORT_LIB

# make_clone_fixture <dir> — a throwaway HIMMELCTL_REPO_ROOT standing in for a
# himmel clone: the no-op adopt.sh + setup.sh the installer shells out to, and
# the lane registry probeLane resolves through.
make_clone_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/lanes" "$_d/scripts/machine-setup"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_d/scripts/adopt.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_d/scripts/setup.sh"
  chmod +x "$_d/scripts/adopt.sh" "$_d/scripts/setup.sh"
  cat > "$_d/scripts/machine-setup/full-plugin-enable.json" <<'PLUGINS'
{ "plugins": [ { "spec": "demo-plugin@demo-market", "marketplaceAdd": "demo-org/demo-market" } ] }
PLUGINS
  cp "$repo_root/scripts/lanes/lanes.json" "$_d/scripts/lanes/lanes.json"
}

# run_install <cwd> <home> <repo_root_fixture> [args...] — bin.js install
# --dry-run under a fake HOME + redirected cache/config seams. Every write
# seam is redirected (HIMMEL-2350): nothing on the real machine is touched.
run_install() {
  local _cwd="$1" _home="$2" _fixture="$3"; shift 3
  ( cd "$_cwd" && HOME="$_home" USERPROFILE="$(winpath "$_home")" \
      HIMMELCTL_CACHE_DIR="$(winpath "$_home/himmelctl-cache")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_home/himmelctl-cache/luna-config.json")" \
      HIMMELCTL_INTERACTIVE=0 HIMMELCTL_REPO_ROOT="$(winpath "$_fixture")" \
      "$node_bin" "$wizard" install --dry-run "$@" </dev/null 2>&1 )
}

# overlay_remedy_ok <output> <posix_literal> <win_regex> — does <output> name the
# contributor primitive the diagnostic renders on THIS platform?
#
# HIMMEL-2905: bin.js prints displayCommand(deriveOverlayCommand()), which is
# `bash <clone>/scripts/setup.sh` on POSIX but
# `<pwsh> -ExecutionPolicy Bypass -File <clone>\scripts\setup.ps1` on win32 —
# CodeRabbit round 1 on #605, because `bash …setup.ps1` is unrunnable there.
# Asserting the POSIX rendering unconditionally therefore REJECTS correct
# behaviour under Git Bash and reddens this suite (and its parent
# scripts/test-adopt.sh) on a platform CI does not run. The Windows arm matches
# the invariant part of the line rather than a full literal: resolvePowershell()
# picks the interpreter at runtime, so the leading argv element is not
# predictable. Returns an rc instead of calling fail(), so case a4 below can
# exercise BOTH arms.
overlay_remedy_ok() {
  local _out="$1" _posix="$2" _win="$3"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) grepq "$_out" -E -- "$_win" ;;
    *)                    grepq "$_out" -F -- "$_posix" ;;
  esac
}

# ── case a: RED control — project scope inside the himmel clone is refused ──
cloneA="$work/a-clone"; make_clone_fixture "$cloneA"
homeA="$work/a-home"; mkdir -p "$homeA"
set +e
outA=$(run_install "$cloneA" "$homeA" "$cloneA" --scope project); rcA=$?
set -e
[ "$rcA" -ne 0 ] \
  || fail "case a: --scope project inside the himmel clone should exit non-zero (got rc=$rcA): $outA"
grepq "$outA" 'not valid inside the himmel checkout' \
  || fail "case a: the refusal must say project scope is not valid inside the himmel checkout: $outA"
# EVERY fixture path compared against bin.js output goes through winpath first
# (CR round 4, [codex-1] — and rounds 1/2/3 were all this same class). bin.js
# prints paths via displayPath(): node's own path.resolve(), forward-slashed,
# which under Git Bash on Windows is `C:/Users/...` while the raw shell
# variable is the POSIX `/tmp/...`. winpath() is the suite-wide `cygpath -m`
# bridge that produces exactly that forward-slashed native form, and is the
# identity on Linux — so ONE normalisation makes every assertion below a plain
# full-path comparison on both platforms. Do not hand-roll a per-assertion
# workaround instead; that is what kept regressing.
cloneA_w=$(winpath "$cloneA")
grepq "$outA" -F "$cloneA_w" \
  || fail "case a: the refusal must NAME the checkout it refused ($cloneA_w): $outA"
# The contributor primitive is NOT hardcoded in bin.js — it is rendered from
# deriveOverlayCommand(), the same derivation that would actually spawn it, so
# the line carries `bash <clone>/scripts/setup.sh` on POSIX and pwsh +
# -ExecutionPolicy Bypass -File setup.ps1 on Windows (CodeRabbit round 1).
# Assert whichever this platform actually renders — see overlay_remedy_ok()
# (HIMMEL-2905). Case a3 below is the platform-independent control.
overlay_remedy_ok "$outA" "bash $cloneA_w/scripts/setup.sh" '-ExecutionPolicy Bypass -File .*setup[.]ps1' \
  || fail "case a: the remedy must name the checkout's own scripts/setup.sh (the contributor primitive) in this platform's rendering: $outA"
# The node command must be ABSOLUTE (CR round 3): the refusal fires from
# whatever subdirectory the operator ran it in — which is where they paste it
# back — and a relative `node scripts/himmelctl/bin.js` only resolves from the
# checkout root.
grepq "$outA" -F "node $cloneA_w/scripts/himmelctl/bin.js install --scope user" \
  || fail "case a: the remedy's node command must be ABSOLUTE, rooted at the checkout, so it resolves from any subdirectory: $outA"
[ ! -f "$homeA/himmelctl-cache/install-profile.json" ] \
  || fail "case a: a REFUSED install must not write an install-profile cache (a 'scope: project' record would survive it)"
echo "ok: case a — --scope project inside the himmel clone is refused with the remedy, and writes no cache"

# ── case a3: the remedy's contributor command is DERIVED, not hardcoded ────
# Platform-independent control for the CodeRabbit round-1 finding: the Windows
# branch cannot be exercised here (no pwsh, and process.platform is not
# stubbable from a shell suite), so assert the SOURCE property that makes the
# Windows rendering correct — the refusal renders deriveOverlayCommand() (which
# already carries the pwsh/-File form on win32) rather than prefixing a literal
# `bash ` to contributeOverlayFilename(), which yields the unrunnable
# `bash …/setup.ps1` there. Same static-assertion shape as
# test-wizard-noinstall-guard.sh.
wizard_src=$(cat "$wizard")
grepq "$wizard_src" -F 'const setupCmd = displayCommand(deriveOverlayCommand());' \
  || fail "case a3: the refusal's contributor command must be rendered from deriveOverlayCommand(), so the Windows branch gets pwsh -File instead of an unrunnable 'bash <setup.ps1>'"
grepq "$wizard_src" -E 'bash \$\{(setupCmd|.*contributeOverlayFilename)' \
  && fail "case a3: the refusal must not prefix a literal 'bash ' to the contributor primitive — that is the Windows bug (setup.ps1 is not a bash script)"
echo "ok: case a3 — the contributor command in the refusal is derived per-platform, never a hardcoded 'bash <script>'"

# ── case b: negative control — a VENDORING adopter repo still installs ──────
# This is the load-bearing half: the detector keys off the clone THIS
# himmelctl runs from, not off file content, so an adopter who copied himmel's
# portable core (or even adopt.sh) into their own repo must not be caught.
cloneB="$work/b-clone"; make_clone_fixture "$cloneB"
adopterB="$work/b-adopter"
mkdir -p "$adopterB/scripts/hooks" "$adopterB/scripts/guardrails"
printf '#!/usr/bin/env bash\nexit 0\n' > "$adopterB/scripts/hooks/block-edit-on-main.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$adopterB/scripts/guardrails/lib.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$adopterB/scripts/adopt.sh"
printf '# my-repo — Project Rules\n' > "$adopterB/CLAUDE.md"
homeB="$work/b-home"; mkdir -p "$homeB"
set +e
outB=$(run_install "$adopterB" "$homeB" "$cloneB" --scope project); rcB=$?
set -e
[ "$rcB" -eq 0 ] \
  || fail "case b: --scope project in an ordinary (himmel-vendoring) adopter repo should still install (got rc=$rcB): $outB"
grepq "$outB" 'not valid inside the himmel checkout' \
  && fail "case b: the refusal must NOT fire on an adopter repo that merely vendors himmel's portable core: $outB"
echo "ok: case b — a himmel-VENDORING adopter repo is not caught by the refusal (the detector is identity, not content)"

# ── case a2: a checkout path containing a SPACE stays pasteable ────────────
# CR round 3 [codex-1]: the remedy is `bash <path>` / `node <path>`, so an
# unquoted path with a space produces a line that runs the wrong thing. Both
# are shell-quoted; this is the control that proves it, and it is why the
# fixture directory is deliberately named with a space in it.
cloneA2="$work/a2 clone with space"; make_clone_fixture "$cloneA2"
homeA2="$work/a2-home"; mkdir -p "$homeA2"
set +e
outA2=$(run_install "$cloneA2" "$homeA2" "$cloneA2" --scope project); rcA2=$?
set -e
[ "$rcA2" -ne 0 ] \
  || fail "case a2: --scope project inside a himmel clone whose path contains a space should still be refused (got rc=$rcA2): $outA2"
cloneA2_w=$(winpath "$cloneA2")
overlay_remedy_ok "$outA2" "bash '$cloneA2_w/scripts/setup.sh'" "-ExecutionPolicy Bypass -File '[^']*a2 clone with space[^']*setup[.]ps1'" \
  || fail "case a2: a setup path containing a space must be SHELL-QUOTED in the remedy, or the printed command runs the wrong thing: $outA2"
grepq "$outA2" -F "node '$cloneA2_w/scripts/himmelctl/bin.js'" \
  || fail "case a2: the bin.js path containing a space must be SHELL-QUOTED in the remedy too: $outA2"
echo "ok: case a2 — a checkout path with a space is refused and both remedy commands stay shell-quoted"

# ── case a4: platform control for a/a2 — the assertion arm follows uname ──
# The bug HIMMEL-2905 closes is a FALSE red on a platform CI does not run (the
# shell suites are ubuntu-only), so it cannot be reproduced by running this
# suite here. Exercise overlay_remedy_ok() itself instead, against synthetic
# renderings under a STUBBED uname — BOTH arms stubbed, never the host's own
# (CR round 1, [codex-1]): asserting the POSIX arm against the real `uname`
# would itself fail under Git Bash, where the Windows arm is selected — the
# very platform this case exists to protect. The LAST check is the RED control:
# before the fix the POSIX literal was asserted unconditionally, so a POSIX
# rendering under a Git-Bash uname PASSED, which is precisely the false red a
# contributor hits. Each stub lives inside its own subshell; nothing below this
# case runs with a doctored PATH.
a4_posix_line="derived: bash /x/scripts/setup.sh"
a4_pwsh_line="derived: /usr/bin/pwsh -ExecutionPolicy Bypass -File /x/scripts/setup.ps1"
a4_posix_lit="bash /x/scripts/setup.sh"
a4_win_re='-ExecutionPolicy Bypass -File .*setup[.]ps1'
a4_posix_stub="$work/a4-uname-posix"; mkdir -p "$a4_posix_stub"
printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' > "$a4_posix_stub/uname"
a4_win_stub="$work/a4-uname-mingw"; mkdir -p "$a4_win_stub"
printf '#!/usr/bin/env bash\nprintf "MINGW64_NT-10.0-22631\\n"\n' > "$a4_win_stub/uname"
chmod +x "$a4_posix_stub/uname" "$a4_win_stub/uname"
# shellcheck disable=SC2030,SC2031  # deliberately subshell-LOCAL: the uname stub must not leak past this case
( PATH="$a4_posix_stub:$PATH"; hash -r 2>/dev/null || true
  overlay_remedy_ok "$a4_posix_line" "$a4_posix_lit" "$a4_win_re" ) \
  || fail "case a4: under a POSIX uname the bash rendering must satisfy the remedy assertion"
# shellcheck disable=SC2030,SC2031  # deliberately subshell-LOCAL: the uname stub must not leak past this case
( PATH="$a4_posix_stub:$PATH"; hash -r 2>/dev/null || true
  overlay_remedy_ok "$a4_pwsh_line" "$a4_posix_lit" "$a4_win_re" ) \
  && fail "case a4: under a POSIX uname the pwsh rendering must NOT satisfy it — the two arms must be distinguishable"
# shellcheck disable=SC2030,SC2031  # deliberately subshell-LOCAL: the uname stub must not leak past this case
( PATH="$a4_win_stub:$PATH"; hash -r 2>/dev/null || true
  overlay_remedy_ok "$a4_pwsh_line" "$a4_posix_lit" "$a4_win_re" ) \
  || fail "case a4: under a Git-Bash uname the pwsh rendering must satisfy the remedy assertion"
# shellcheck disable=SC2030,SC2031  # deliberately subshell-LOCAL: the uname stub must not leak past this case
( PATH="$a4_win_stub:$PATH"; hash -r 2>/dev/null || true
  overlay_remedy_ok "$a4_posix_line" "$a4_posix_lit" "$a4_win_re" ) \
  && fail "case a4: under a Git-Bash uname the POSIX rendering must FAIL — asserting it unconditionally is the false red HIMMEL-2905 fixes"
echo "ok: case a4 — the remedy assertion selects its arm from uname (Git Bash asserts the pwsh rendering, POSIX the bash one)"

# ── case c: scope control — user scope inside the clone is unaffected ───────
cloneC="$work/c-clone"; make_clone_fixture "$cloneC"
homeC="$work/c-home"; mkdir -p "$homeC"
set +e
outC=$(run_install "$cloneC" "$homeC" "$cloneC" --scope user); rcC=$?
set -e
[ "$rcC" -eq 0 ] \
  || fail "case c: --scope user inside the himmel clone should still install (got rc=$rcC): $outC"
grepq "$outC" 'not valid inside the himmel checkout' \
  && fail "case c: the refusal is project-scope only; it must not fire on --scope user: $outC"
echo "ok: case c — the refusal is project-scope only (--scope user inside the clone still installs)"

# ── case c2: a SIBLING worktree of the clone is caught too ─────────────────
# CR round 1 [codex-3]: himmel keeps its own worktrees under .claude/worktrees/,
# so the path tests cover them — but `git worktree add ../sibling` puts one
# OUTSIDE repoRoot() while its .claude/settings.json is the very same tracked
# file. The git-common-dir test is what closes that; this case is its control.
if command -v git >/dev/null 2>&1; then
  cloneC2="$work/c2-clone"; make_clone_fixture "$cloneC2"
  git -C "$cloneC2" init -q
  git -C "$cloneC2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  sibC2="$work/c2-sibling-worktree"
  git -C "$cloneC2" worktree add -q -b c2-branch "$sibC2" >/dev/null 2>&1
  homeC2="$work/c2-home"; mkdir -p "$homeC2"
  set +e
  outC2=$(run_install "$sibC2" "$homeC2" "$cloneC2" --scope project); rcC2=$?
  set -e
  [ "$rcC2" -ne 0 ] \
    || fail "case c2: --scope project in a SIBLING worktree of the clone should be refused — its .claude/settings.json is the same tracked file (got rc=$rcC2): $outC2"
  grepq "$outC2" 'not valid inside the himmel checkout' \
    || fail "case c2: the sibling worktree should hit the himmel-checkout refusal: $outC2"
  echo "ok: case c2 — a sibling worktree (outside repoRoot) is caught via the shared git common dir"
else
  echo "ok: case c2 skipped (git not on PATH)"
fi

# ── cases d/e: contributor membership ──────────────────────────────────────
# Two items, identical but for contributorScopes, both scopes:["project"]:
# only the one carrying contributorScopes:["user"] may be enabled by a
# devOverlay (contributor) record — and only on a contributor record.
manifestD="$work/manifestD.json"
cat > "$manifestD" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "contributor-item",
      "kind": "dep",
      "scopes": ["project"],
      "contributorScopes": ["user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "built.txt" }
    },
    {
      "id": "plain-project-item",
      "kind": "dep",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "built.txt" }
    }
  ]
}
JSON
MANIFEST_D_PATH="$(winpath "$manifestD")"
export MANIFEST_D_PATH

# The repoRoot the file-exists probe resolves against under user scope
# (probes.js: base = ctx.repoRoot when scope === 'user').
fixtureRepoD="$work/d-repo"; mkdir -p "$fixtureRepoD"
printf 'built\n' > "$fixtureRepoD/built.txt"
homeD="$work/d-home"; mkdir -p "$homeD"
cacheD="$work/d-cache"; mkdir -p "$cacheD"

# run_report <devOverlay:true|false> — a user-scope statusReport with no
# persisted state.json, so membership comes from the recorded answers alone.
run_report() {
  DEV_OVERLAY="$1" HOME="$homeD" USERPROFILE="$(winpath "$homeD")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheD")-luna-config.json" \
    HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoD")" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_D_PATH, 'utf8'));
const answers = {
  profile: 'starter', scope: 'user',
  devOverlay: process.env.DEV_OVERLAY === 'true',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
console.log(JSON.stringify(statusReport({ manifest, scope: 'user', targetPath: process.cwd(), answers })));
"
}

outD=$(run_report true)
echo "$outD" | jq -e '.items[] | select(.id=="contributor-item") | .desired == true and .severity == "green"' >/dev/null \
  || fail "case d: on a contributor (devOverlay:true) user-scope record, a contributorScopes:[\"user\"] item must be desired and PROBED (got: $outD)"
echo "ok: case d — contributorScopes widens membership on a contributor's user-scope record (the item probes instead of reading n/a)"

echo "$outD" | jq -e '.items[] | select(.id=="plain-project-item") | .desired == false and .severity == "n/a"' >/dev/null \
  || fail "case e: an item WITHOUT contributorScopes must stay n/a even on a contributor record — the widening is per-item, not blanket (got: $outD)"
outE=$(run_report false)
echo "$outE" | jq -e '.items[] | select(.id=="contributor-item") | .desired == false and .severity == "n/a"' >/dev/null \
  || fail "case e: on a PLAIN adopter (devOverlay:false) user-scope record, the contributorScopes item must still read n/a (got: $outE)"
echo "$outE" | jq -e '.items[] | select(.id=="plain-project-item") | .desired == false and .severity == "n/a"' >/dev/null \
  || fail "case e: a plain adopter's user-scope status must be unchanged for an ordinary project-scope item (got: $outE)"
echo "ok: case e — negative controls: no contributorScopes, or no devOverlay, still reads n/a (a plain adopter's status output is unchanged)"

echo "PASS"
