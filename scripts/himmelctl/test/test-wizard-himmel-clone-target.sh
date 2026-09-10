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
# The refusal names projectTargetDir() -- node's own path.resolve(cwd), which
# under Git Bash on Windows is a NATIVE Windows path (C:\Users\...\a-clone)
# while $cloneA is the POSIX form. Comparing the full paths would fail on the
# platform this suite explicitly supports (CR round 1, [codex-2]), and no
# single normalisation matches both node's backslashes and cygpath -m's forward
# slashes. Assert on the two separator-free segments instead: they are
# byte-identical in either path form, and the mktemp suffix makes the pair
# specific to THIS run's fixture rather than any generic message.
work_leaf=$(basename "$work")
grepq "$outA" -F "$work_leaf" \
  || fail "case a: the refusal must NAME the checkout it refused (expected the fixture root $work_leaf in the path): $outA"
grepq "$outA" -F 'a-clone' \
  || fail "case a: the refusal must NAME the checkout it refused (expected the a-clone leaf in the path): $outA"
grepq "$outA" -F 'scripts/setup.sh' \
  || fail "case a: the remedy must name scripts/setup.sh (the contributor primitive): $outA"
grepq "$outA" -F 'install --scope user' \
  || fail "case a: the remedy must name 'install --scope user': $outA"
[ ! -f "$homeA/himmelctl-cache/install-profile.json" ] \
  || fail "case a: a REFUSED install must not write an install-profile cache (a 'scope: project' record would survive it)"
echo "ok: case a — --scope project inside the himmel clone is refused with the remedy, and writes no cache"

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
