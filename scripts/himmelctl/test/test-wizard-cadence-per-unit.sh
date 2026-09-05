#!/usr/bin/env bash
# test-wizard-cadence-per-unit.sh — hermetic tests for HIMMEL-2302 (per-
# cadence wizard selection). Covers the NEW behavior that sits on top of
# test-wizard-luna-sections.sh's existing pipeline-only cadence coverage
# (which continues to prove the legacy `luna.cadenceEnabled` fallback, byte-
# stable round-trips, and disarm-consent wiring — none of that is repeated
# here):
#
#   a. a top-level `cadences` section (no `luna` section at all — the
#      operator-capture shape, docs/setup/profiles/operator.install-
#      profile.json) arms qmd/graphmap via their OWN scripts with the
#      documented minimal argv, and does NOT spawn pipeline-cadence.sh when
#      pipeline is declined.
#   b. `cadences` is AUTHORITATIVE over the legacy `luna.cadenceEnabled`
#      boolean when both are present on the same profile: cadenceEnabled=true
#      + cadences.pipeline='off' must NOT arm pipeline.
#   c. interactive: the cadences menu offers codex-sweep ONLY when the codex
#      lane was selected; it stays absent (never asked) otherwise.
#   d/e (installer v1 spec-deviation fix): the cadences question is PER-ROW
#      gated, not whole-question vault gated — offeredCadenceRows() filters
#      each row by its own `requires` (vault vs lane:codex) independently, so
#      the question itself sits outside askQuestions()'s vaultMode!=='none'
#      gate. vault=none + the codex lane must still reach the question
#      (offering ONLY codex-sweep, the one row that does not require a
#      vault) — case c already covers the mirror case (vault!=='none'); d/e
#      prove the vault=none side stays correctly gated in BOTH directions.
#   d. vault=none + codex lane selected -> cadences IS asked, offering ONLY
#      codex-sweep; arming it records `cadences: {"codex-sweep":"armed"}`,
#      the other three registry ids stay genuinely absent from the object.
#   e. vault=none + no codex lane -> zero rows are offered (no 'vault' row
#      qualifies, no 'lane:codex' row qualifies) -> the question is NEVER
#      asked and `cadences` is absent from the answers entirely (round-8:
#      not-asked stays undefined, never a fabricated {}).
#   f. HIMMEL-2302 CR round 1 Fix 1 (documented consent asymmetry, end-to-
#      end): --from-profile with vault=none + cadences.codex-sweep='armed'
#      and codex ABSENT from lanes validates cleanly (naming codex-sweep in a
#      hand-reviewed profile IS the consent — loadProfile does not gate
#      requires:lane:codex on the lanes field, unlike requires:vault which it
#      DOES enforce, see case f's sibling exit-2 coverage in
#      test-wizard-questions.sh case6d) and actually spawns
#      codex-sweep-cadence.sh arm.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
luna_config_lib="$repo_root/scripts/himmelctl/lib/luna-config.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-cadence-per-unit.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
luna_config_lib_w="$(winpath "$luna_config_lib")"

build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _t
  for _t in "$@"; do
    if [ "$_t" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_t"); else _absent+=("$_t"); fi
  done
  for _t in "${_present[@]}"; do
    link_hermetic_tool "$_t" "$_stub"
  done
  local _scrubbed="$PATH"
  if [ "${#_absent[@]}" -gt 0 ]; then
    _scrubbed=$(scrub_path "$PATH" "${_absent[@]}")
  fi
  printf '%s:%s' "$_stub" "$_scrubbed"
}

make_git_stub() {
  local _d="$1" _url="$2"
  cat > "$_d/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ] && [ "\$3" = "origin" ]; then
  printf '%s\n' "$_url"
  exit 0
fi
exit 0
STUB
  chmod +x "$_d/git"
}

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# ═══════════════════════════════════════════════════════════════════════════
# case a: a `cadences`-only profile (no `luna` section) arms qmd + graphmap
# via their own scripts, and does NOT spawn pipeline-cadence.sh (declined).
# ═══════════════════════════════════════════════════════════════════════════

stubA="$work/stubA"; mkdir -p "$stubA"
pathA=$(build_path "$stubA" bash jq python3 npm --)
make_git_stub "$stubA" "https://github.com/someone/other-repo.git"
homeA="$work/homeA"; mkdir -p "$homeA"

fixtureRepoA="$work/fixture-repo-a"; mkdir -p "$fixtureRepoA/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoA/scripts/adopt.sh"
chmod +x "$fixtureRepoA/scripts/adopt.sh"

markerPipelineA="$work/marker-pipeline-a.txt"
markerQmdA="$work/marker-qmd-a.txt"
markerGraphmapA="$work/marker-graphmap-a.txt"
cat > "$fixtureRepoA/scripts/luna/pipeline-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_PIPELINE_A"
exit 0
STUB
cat > "$fixtureRepoA/scripts/luna/qmd-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_QMD_A"
exit 0
STUB
cat > "$fixtureRepoA/scripts/luna/graphmap-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_GRAPHMAP_A"
exit 0
STUB
chmod +x "$fixtureRepoA/scripts/luna/pipeline-cadence.sh" "$fixtureRepoA/scripts/luna/qmd-cadence.sh" "$fixtureRepoA/scripts/luna/graphmap-cadence.sh"

vaultPathA="$(winpath "$work/vaultA")"
configPathA="$(winpath "$work/config-a.json")"

profileA="$work/profileA.json"
cat > "$profileA" <<JSON
{
  "schemaVersion": 2, "profile": "operator", "devOverlay": false, "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$vaultPathA" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": true,
  "cadences": { "pipeline": "off", "qmd": "armed", "graphmap": "armed" }
}
JSON

set +e
outA=$(PATH="$pathA" HOME="$homeA" USERPROFILE="$(winpath "$homeA")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoA")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathA" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-a")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-a")" \
  MARKER_PIPELINE_A="$(winpath "$markerPipelineA")" \
  MARKER_QMD_A="$(winpath "$markerQmdA")" \
  MARKER_GRAPHMAP_A="$(winpath "$markerGraphmapA")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileA")" </dev/null 2>&1)
rcA=$?
set -e
[ "$rcA" -eq 0 ] || fail "case a: a cadences-only (no luna section) apply run should exit 0 (got rc=$rcA): $outA"

[ -f "$markerQmdA" ] || fail "case a: qmd-cadence.sh should have been spawned with 'arm' (marker missing)"
grepq "$(cat "$markerQmdA")" -F -- 'arm' || fail "case a: qmd spawn should carry the 'arm' subcommand (got: $(cat "$markerQmdA"))"

[ -f "$markerGraphmapA" ] || fail "case a: graphmap-cadence.sh should have been spawned with 'arm' (marker missing)"
graphmapArgvA=$(cat "$markerGraphmapA")
grepq "$graphmapArgvA" -F -- 'arm' || fail "case a: graphmap spawn should carry the 'arm' subcommand (got: $graphmapArgvA)"
grepq "$graphmapArgvA" -F -- '--vault' || fail "case a: graphmap arm argv missing --vault (got: $graphmapArgvA)"
grepq "$graphmapArgvA" -F -- "$vaultPathA" || fail "case a: graphmap arm argv should carry the configured vault path (got: $graphmapArgvA)"

[ -f "$markerPipelineA" ] && fail "case a: pipeline-cadence.sh must NEVER be spawned when pipeline was declined (found marker: $(cat "$markerPipelineA"))"

outCfgA=$("$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathA';
const lc = require('$luna_config_lib_w');
console.log(JSON.stringify(lc.load()));
")
echo "$outCfgA" | jq -e '.luna.cadence.enabled == false' >/dev/null \
  || fail "case a: luna.cadence.enabled should mirror the declined pipeline row (false), even with no luna section supplied (got: $outCfgA)"

set +e
installedBlockA=$(grep -A5 '^installed:$' <<< "$outA")
set -e
grepq "$installedBlockA" -F -- 'qmd reindex cadence armed' \
  || fail "case a: the summary should report qmd reindex cadence armed under installed: (got: $outA)"
grepq "$installedBlockA" -F -- 'graphify graph refresh cadence armed' \
  || fail "case a: the summary should report graphify graph refresh cadence armed under installed: (got: $outA)"
echo "ok: case a — a cadences-only profile (no luna section) arms qmd + graphmap via their own scripts with the documented minimal argv, and never spawns pipeline-cadence.sh when pipeline is declined"

# ═══════════════════════════════════════════════════════════════════════════
# case b: `cadences` is AUTHORITATIVE over the legacy luna.cadenceEnabled
# boolean when both are present — cadenceEnabled=true + cadences.pipeline=
# 'off' must NOT arm pipeline.
# ═══════════════════════════════════════════════════════════════════════════

stubB="$work/stubB"; mkdir -p "$stubB"
pathB=$(build_path "$stubB" bash jq python3 npm --)
make_git_stub "$stubB" "https://github.com/someone/other-repo.git"
homeB="$work/homeB"; mkdir -p "$homeB"

fixtureRepoB="$work/fixture-repo-b"; mkdir -p "$fixtureRepoB/scripts/luna"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoB/scripts/adopt.sh"
chmod +x "$fixtureRepoB/scripts/adopt.sh"
markerPipelineB="$work/marker-pipeline-b.txt"
cat > "$fixtureRepoB/scripts/luna/pipeline-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_PIPELINE_B"
exit 0
STUB
chmod +x "$fixtureRepoB/scripts/luna/pipeline-cadence.sh"

vaultPathB="$(winpath "$work/vaultB")"
configPathB="$(winpath "$work/config-b.json")"

profileB="$work/profileB.json"
cat > "$profileB" <<JSON
{
  "role": "adopter", "tier": "standard", "scope": "user",
  "vault": { "mode": "default-template", "path": "$vaultPathB" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "luna": { "cadenceEnabled": true, "phiDeclared": false },
  "secretsWalk": "skip",
  "bridge": { "enabled": false, "envPath": "~/.claude/channels/telegram/.env", "whisperCli": "", "whisperModel": "ggml-small.bin", "installPersistence": false },
  "cadences": { "pipeline": "off" }
}
JSON

set +e
outB=$(PATH="$pathB" HOME="$homeB" USERPROFILE="$(winpath "$homeB")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoB")" \
  HIMMEL_LUNA_CONFIG_PATH="$configPathB" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-b")" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-b")" \
  MARKER_PIPELINE_B="$(winpath "$markerPipelineB")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileB")" </dev/null 2>&1)
rcB=$?
set -e
[ "$rcB" -eq 0 ] || fail "case b: run should exit 0 (got rc=$rcB): $outB"
[ -f "$markerPipelineB" ] && fail "case b: cadences.pipeline='off' must override luna.cadenceEnabled=true -- pipeline-cadence.sh must NOT be spawned (found marker: $(cat "$markerPipelineB")))"
outCfgB=$("$node_bin" -e "
process.env.HIMMEL_LUNA_CONFIG_PATH = '$configPathB';
const lc = require('$luna_config_lib_w');
console.log(JSON.stringify(lc.load()));
")
echo "$outCfgB" | jq -e '.luna.cadence.enabled == false' >/dev/null \
  || fail "case b: luna.cadence.enabled should reflect the AUTHORITATIVE cadences.pipeline='off', not the legacy cadenceEnabled=true (got: $outCfgB)"
echo "ok: case b — a top-level cadences section is authoritative over the legacy luna.cadenceEnabled boolean"

# ═══════════════════════════════════════════════════════════════════════════
# case c (interactive): the cadences menu offers codex-sweep ONLY when the
# codex lane was selected; it stays absent (never asked) otherwise.
# ═══════════════════════════════════════════════════════════════════════════

stubC="$work/stubC"; mkdir -p "$stubC"
pathC=$(build_path "$stubC" bash jq python3 npm --)
homeC="$work/homeC"; mkdir -p "$homeC"

set +e
outNoCodex=$(PATH="$pathC" HOME="$homeC" USERPROFILE="$(winpath "$homeC")" HIMMELCTL_CACHE_DIR="$(winpath "$homeC.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$homeC.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
luna
project
default-template

inline
lean

no
INPUT
); rcNoCodex=$?
set -e
[ "$rcNoCodex" -eq 0 ] || fail "case c(no codex): should succeed (got rc=$rcNoCodex): $outNoCodex"
grepq "$outNoCodex" -F -- 'codex-sweep' \
  && fail "case c(no codex): codex-sweep must NOT appear in the cadences menu when codex was not selected (got: $outNoCodex)"

set +e
outCodex=$(PATH="$pathC" HOME="$homeC" USERPROFILE="$(winpath "$homeC")" HIMMELCTL_CACHE_DIR="$(winpath "$homeC.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$homeC.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
luna
project
default-template

inline
lean
codex
no
INPUT
); rcCodex=$?
set -e
[ "$rcCodex" -eq 0 ] || fail "case c(codex): should succeed (got rc=$rcCodex): $outCodex"
grepq "$outCodex" -F -- 'codex-sweep' \
  || fail "case c(codex): codex-sweep SHOULD appear in the cadences menu once codex is selected (got: $outCodex)"
echo "ok: case c — codex-sweep is offered in the cadences menu only when the codex lane was selected, absent (never asked) otherwise"

# ═══════════════════════════════════════════════════════════════════════════
# case d (interactive, installer v1 spec-deviation fix): vault=none + the
# codex lane selected -> the cadences question is STILL asked (per-row
# gating, not whole-question vault gating), offering ONLY codex-sweep (the
# one registry row that does not require a vault); arming it records
# `cadences: {"codex-sweep":"armed"}` with pipeline/qmd/graphmap genuinely
# absent from the object.
# ═══════════════════════════════════════════════════════════════════════════

stubD="$work/stubD"; mkdir -p "$stubD"
pathD=$(build_path "$stubD" bash jq python3 npm --)
homeD="$work/homeD"; mkdir -p "$homeD"

set +e
outD=$(PATH="$pathD" HOME="$homeD" USERPROFILE="$(winpath "$homeD")" HIMMELCTL_CACHE_DIR="$(winpath "$homeD.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$homeD.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
starter
project
none
inline
lean
codex
no
1
INPUT
); rcD=$?
set -e
[ "$rcD" -eq 0 ] || fail "case d: vault=none + codex lane run should succeed (got rc=$rcD): $outD"
grepq "$outD" -F -- '? cadences — recurring scheduled jobs to arm now [codex-sweep|none] (default: none)' \
  || fail "case d: vault=none + codex should still ask cadences, offering ONLY codex-sweep (got: $outD)"
grepq "$outD" -F -- '"codex-sweep": "armed"' \
  || fail "case d: selecting codex-sweep should record it armed (got: $outD)"
grepq "$outD" -F -- '"pipeline":' \
  && fail "case d: pipeline must stay genuinely absent from cadences (requires vault, not offered) (got: $outD)"
grepq "$outD" -F -- '"qmd":' \
  && fail "case d: qmd must stay genuinely absent from cadences (requires vault, not offered) (got: $outD)"
grepq "$outD" -F -- '"graphmap":' \
  && fail "case d: graphmap must stay genuinely absent from cadences (requires vault, not offered) (got: $outD)"
echo "ok: case d — vault=none + codex lane still asks cadences, offering ONLY codex-sweep; arming it records cadences:{codex-sweep:armed} with the vault-requiring rows genuinely absent"

# ═══════════════════════════════════════════════════════════════════════════
# case e (interactive, installer v1 spec-deviation fix): vault=none + NO
# codex lane -> zero cadence-registry rows qualify (every row requires either
# a vault or the codex lane) -> the cadences question is NEVER asked and
# `cadences` is genuinely absent from the answers (round-8: not-asked stays
# undefined, never a fabricated {}).
# ═══════════════════════════════════════════════════════════════════════════

stubE="$work/stubE"; mkdir -p "$stubE"
pathE=$(build_path "$stubE" bash jq python3 npm --)
homeE="$work/homeE"; mkdir -p "$homeE"

set +e
outE=$(PATH="$pathE" HOME="$homeE" USERPROFILE="$(winpath "$homeE")" HIMMELCTL_CACHE_DIR="$(winpath "$homeE.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$homeE.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
  "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
starter
project
none
inline
lean

no
INPUT
); rcE=$?
set -e
[ "$rcE" -eq 0 ] || fail "case e: vault=none without codex run should succeed (got rc=$rcE): $outE"
grepq "$outE" -F -- '? cadences —' \
  && fail "case e: vault=none with no codex lane must NEVER ask cadences (zero rows offered) (got: $outE)"
grepq "$outE" -F -- '"cadences"' \
  && fail "case e: cadences must be genuinely absent from the answers, not a fabricated {} (got: $outE)"
echo "ok: case e — vault=none without the codex lane never asks cadences (zero offered rows); cadences stays absent from the answers"

# ═══════════════════════════════════════════════════════════════════════════
# case f (HIMMEL-2302 CR round 1 Fix 1, documented consent asymmetry): a
# --from-profile with vault=none + cadences.codex-sweep='armed' and codex
# ABSENT from lanes must VALIDATE (not exit 2 — that's for requires:'vault'
# rows only) and actually arm codex-sweep via its own script.
# ═══════════════════════════════════════════════════════════════════════════

stubF="$work/stubF"; mkdir -p "$stubF"
pathF=$(build_path "$stubF" bash jq python3 npm --)
make_git_stub "$stubF" "https://github.com/someone/other-repo.git"
homeF="$work/homeF"; mkdir -p "$homeF"

fixtureRepoF="$work/fixture-repo-f"; mkdir -p "$fixtureRepoF/scripts/cleanup"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixtureRepoF/scripts/adopt.sh"
chmod +x "$fixtureRepoF/scripts/adopt.sh"
markerCodexF="$work/marker-codex-f.txt"
cat > "$fixtureRepoF/scripts/cleanup/codex-sweep-cadence.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$MARKER_CODEX_F"
exit 0
STUB
chmod +x "$fixtureRepoF/scripts/cleanup/codex-sweep-cadence.sh"

profileF="$work/profileF.json"
cat > "$profileF" <<JSON
{
  "schemaVersion": 2, "profile": "custom", "devOverlay": false, "tier": "standard", "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true, "alwaysOn": false,
  "cadences": { "codex-sweep": "armed" }
}
JSON

set +e
outF=$(PATH="$pathF" HOME="$homeF" USERPROFILE="$(winpath "$homeF")" HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoF")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/cache-f")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/cache-f")-luna-config.json" \
  HIMMELCTL_BIN_DIR="$(winpath "$work/bin-f")" \
  MARKER_CODEX_F="$(winpath "$markerCodexF")" \
  "$node_bin" "$wizard" install --from-profile "$(winpath "$profileF")" </dev/null 2>&1)
rcF=$?
set -e
[ "$rcF" -eq 0 ] || fail "case f: vault=none + cadences.codex-sweep=armed with no codex lane should validate and apply cleanly (got rc=$rcF): $outF"
[ -f "$markerCodexF" ] || fail "case f: codex-sweep-cadence.sh should have been spawned with 'arm' despite codex being absent from lanes (marker missing)"
grepq "$(cat "$markerCodexF")" -F -- 'arm' || fail "case f: codex-sweep spawn should carry the 'arm' subcommand (got: $(cat "$markerCodexF"))"
echo "ok: case f — a hand-authored profile naming codex-sweep armed validates and arms it even with codex absent from lanes (the documented requires:lane:codex consent asymmetry)"

echo "PASS"
