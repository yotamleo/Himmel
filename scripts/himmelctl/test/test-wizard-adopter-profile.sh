#!/usr/bin/env bash
# test-wizard-adopter-profile.sh — hermetic tests for the HIMMEL-862 v1
# adopter-user install profile: the lane SUBSET selection/probe and the
# always-on machine-hardening CHECKLIST.
#
# Conventions copied from test-wizard-questions.sh: a stub PATH built via
# scripts/lib/hermetic-path.sh, a fake HOME, node launched by absolute path,
# a fake `git` stub driving the role heuristic, and HIMMELCTL_REPO_ROOT aimed
# at throwaway fixtures. Nothing on the real machine is read or written.
#
# The whole point of this suite is that it must be GREEN on a machine where
# none of the lane CLIs are installed AND on the operator's box where all four
# are — so every case controls lane presence explicitly via the stub PATH
# rather than inheriting whatever the host happens to have.
#
# Covers:
#   A. lanes ABSENT (scrubbed PATH) -> MISSING rows + a `still manual` entry
#      carrying the per-platform install command. The installer must NOT
#      claim to have installed them.
#   B. lane PRESENT (stub on PATH)  -> reads `binary present` (NOT "ready" —
#      the probe saw an executable, not a working lane) and lands under
#      `skipped` as already-present, never as installed work. Its setup step
#      is RETAINED as a verify item, but it is never re-listed as an install.
#      (Updated for rounds 1/4/7 — this comment used to describe the original
#      `available` + `installed`-row shape.)
#   C. opt-in gating — codex/hermes are absent from a default run and appear
#      only under --with-codex/--with-hermes.
#   D. flag validation — `--lanes bogus`, `--lanes codex` (opt-in ids are not
#      a second door around the explicit flag), `--lanes ollama`/`--lanes
#      copilot` (HIMMEL-2352: dormant-in-v1 ids get DISTINCT wording naming
#      their lanes.json opt-in env, not a bare unknown-lane message — "one
#      door, not two"), `--lanes none` (accepted) and `--from-profile`
#      combined with a lane flag all exit 2 (or, for `none`, exit 0). With a
#      MISSING profile the CONFLICT is reported, never a load failure, and the
#      file is not opened at all (CR round 10 [codex-r9-1] — the ordering was
#      already correct; only the rc had been pinned, so the message class
#      could have drifted silently).
#   E. hardening is PRINTED, NEVER EXECUTED — alwaysOn=true prints the
#      checklist while a sentinel `powercfg` stub on PATH proves nothing ran.
#   F. alwaysOn=false -> the one-line pointer, and NO powercfg text at all.
#   G. contributor runs print their own contributor-dev report, never the
#      adopter lane/hardening summary owned by this module.
#   H. two identical runs produce byte-identical epilogues (idempotent, and
#      the probe never mutates state).
#   I. an unreadable lane registry degrades to UNKNOWN — never to a false
#      `available` (fail-open to honesty, not to a guess).
#   J. --dry-run NEVER uses the `installed` label (CR round 1 [codex-1]) —
#      asserted on the printed text and on the pure-data buildSummary model,
#      plus the converse: an applied run still does.
#   K. the hermes lane resolves through the CANONICAL `installed` probe
#      (CR round 1 [codex-adv-3]): HERMES_PY and venvs under HERMES_HOME read
#      PRESENT with `hermes` off PATH, and a bare `hermes` on PATH with no
#      real install reads ABSENT.
#   L. HIMMEL-2304: pluginSet=full's enable step is RETIRED — a legacy
#      profile carrying it validates and runs to rc=0 with zero `claude`
#      calls, and the summary says the option was retired, never "full
#      plugin set enabled" and never a plugin-command failure. L2: same
#      under --dry-run.
#   M. a lane DISABLED by lanes.local.json does not read ready (CR round 2
#      [codex-adv-r2-1]) — it reads DISABLED, names the config flip that fixes
#      it, and is NOT sent back to the package manager. Verified by mutation:
#      reverting probeLane to base-only makes this case fail.
#   N. a PRESENT-but-INVALID lanes.local.json fails closed (CR round 4
#      [codex-adv-r3-3]) — lanes read UNKNOWN and the diagnostic names the
#      file, matching the canonical resolver's die(2) on that same file.
#      Absent overlay stays fine (every other case runs without one).
#   O. a lane with a RICHER readiness probe reads 'ready' and emits no verify
#      item (CR round 4 [codex-adv-r3-2]) — the counterpart to caseB, which
#      pins that a binary-only probe RETAINS the lane's setup step.
#   P. an `always` overlay cannot conjure a missing binary (CR round 5
#      [codex-adv-r5-1], a round-2 regression): forced-on-but-absent reads
#      MISCONFIGURED and KEEPS its install command, while a forced-on lane
#      that really is installed still reads present — citing the physical
#      reason, never the override.
#   Q. lane guidance is platform-correct (CR round 7 [codex-adv-r6-2]) — POSIX
#      renders no .ps1/%LOCALAPPDATA%/winget/powercfg anywhere in the lane
#      rows, summary or hardening block, and win32 still keeps its own.
#
#   R. vault=default-template onto an OCCUPIED destination (CR round 8
#      [codex-adv-r7-3]) — unstamped is REFUSED before adopt.sh runs at all
#      (sentinel-checked), stamped proceeds but never claims scaffolding,
#      because adopt.sh silently skips the copy when the destination exists.
#      R3 pins that BOTH previews (--from-profile and interactive) agree with
#      the applied run and never say "would scaffold" (CR round 10
#      [glm-r9-3] — already correct, previously only the applied path tested).
#   S. the planned bucket is conditional-tense throughout (CR round 8
#      [glm-r7-2]), and the applied bucket never leaks "would".
#
#   T. a DEGENERATE merged overlay probe fails closed (CR round 9
#      [codex-adv-r8-1]) — null / {} / empty-kind / unknown-kind must not read
#      present, because evalProbe returns false for all of them and /lanes
#      excludes the lane. Asserted against resolveLanes itself, with a
#      no-overlay baseline, so the two cannot drift apart again.
#   U. overlay remediation preserves the SETUP note (CR round 9
#      [codex-adv-r8-2]) — a DISABLED codex keeps its post-install auth setup
#      and a forced-on absent codex keeps the same step, ordered AFTER the fix
#      (HIMMEL-2352: both halves now use codex — see the case's own comment).
#
#   V. ABSENT *and* overlay-disabled (CR round 11 [codex-r10-1]) — the last
#      cell of the matrix: installing the CLI alone leaves /lanes excluding
#      the lane, so install, overlay re-enable and setup are ALL listed, in
#      that order.
#   W. EVALUABLE_PROBE_KINDS has not drifted from evalProbe's switch in
#      scripts/lanes/probe.mjs (CR round 11 [glm-r10-3]) — probe.mjs exports
#      no equivalent set, so the suite parses its case labels and compares.
#   X. the occupied-vault gate is re-evaluated immediately BEFORE the spawn
#      (CR round 11 [codex-adv-r10-2]). Exercised deterministically, not by
#      racing: handover.mode=external pointed at the vault path creates the
#      directory in the real mid-window between the two checks.
#   Y. LANES_REGISTRY replaces the registry AND skips the overlay, exactly as
#      resolve.mjs does (CR round 11 [codex-adv-r10-3]), with a no-override
#      control proving the overlay otherwise applies.
#   Z. an APPLIED adopter install persists the resolver's narrow-only profile
#      allowlist plus its wizard-owned scope. `none`, codex-only opt-in,
#      hermes-only opt-in and both opt-ins constrain only that subset;
#      ollama-cloud and every other unoffered registry lane stay on their
#      real base probes. (HIMMEL-2352: the matrix used to also cover a
#      non-opt-in "default" combo — ollama+copilot selected with no flag —
#      but v1 has no non-opt-in lane left to make that combo meaningful, so
#      it is dropped rather than forced onto a lane that isn't a default.)
#   AA. LANES_REGISTRY makes applied profile persistence fail loudly before an
#      ignored lanes.local.json write; success is never reported.
#
# Cases N, O, P, Q, R, T, U, V, W, X and Y are mutation-verified: disabling the
# overlay-error branch fails N, dropping the retained setup note fails B,
# restoring the merged-probe-first ordering fails P, pinning setupNote to the
# win32 entry fails Q, removing the unstamped-destination refusal fails R,
# restoring the optimistic degenerate-probe fallback fails T, dropping the
# retained note from the disabled branch fails U, dropping the overlay re-enable
# step fails V, adding a bogus kind to the constant fails W, removing the
# pre-spawn re-check fails X, and ignoring LANES_REGISTRY fails Y.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# Same rationale as test-wizard-questions.sh: pin bin.js's bash spawns to the
# PATH-honoring `bash` so any git shell-out (e.g. the lane probe's buildCtx)
# reads the STUB git below, not the real repo.
export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# HIMMEL-1446 r3: a non-dry-run install (caseE --from-profile) reaches
# applyHimmelctlPathShim(), whose default binDir is the operator's REAL
# ~/.local/bin (win32 ignores HOME entirely). Isolate binDir for the WHOLE
# suite so no case touches the real bin dir — mirrors test-wizard-update.sh /
# test-wizard-uninstall.sh. winpath'd so win32 node resolves it cleanly.
HIMMELCTL_BIN_DIR="$(winpath "$work/isolated-bin")"
export HIMMELCTL_BIN_DIR

# build_path <stub_dir> <present_tools...> -- <absent_tools...>
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
  local _d="$1" _url="$2" _top="${3:-}"
  cat > "$_d/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ] && [ "\$3" = "origin" ]; then
  printf '%s\n' "$_url"
  exit 0
fi
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--show-toplevel" ]; then
  if [ -n "$_top" ]; then printf '%s\n' "$_top"; exit 0; fi
  exit 1
fi
exit 0
STUB
  chmod +x "$_d/git"
}

# make_fixture <dir> [--no-registry] — a throwaway HIMMELCTL_REPO_ROOT with a
# no-op adopt.sh and (unless suppressed) a COPY of the real lane registry.
# The copy matters: probeLane resolves lanes through repoRoot's
# scripts/lanes/lanes.json, so a fixture without one exercises the
# unreadable-registry path (case I) rather than the probe path.
make_fixture() {
  local _d="$1" _mode="${2:-}"
  mkdir -p "$_d/scripts/lanes" "$_d/scripts/machine-setup"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_d/scripts/adopt.sh"
  chmod +x "$_d/scripts/adopt.sh"
  # A two-command pluginSet=full table. Only the pluginSet=full cases read it,
  # but every fixture carries one so a `full` answer never dies on a missing
  # file instead of exercising the path under test.
  cat > "$_d/scripts/machine-setup/full-plugin-enable.json" <<'PLUGINS'
{ "plugins": [ { "spec": "demo-plugin@demo-market", "marketplaceAdd": "demo-org/demo-market" } ] }
PLUGINS
  if [ "$_mode" != "--no-registry" ]; then
    cp "$repo_root/scripts/lanes/lanes.json" "$_d/scripts/lanes/lanes.json"
  fi
}

# The lane CLIs this suite controls. Scrubbed from PATH by default so the
# host's real installs can never leak into an "absent" assertion.
LANE_TOOLS=(ollama copilot codex hermes)

# plant_cli <dir> <name> — put a fake <name> on PATH in a way the CANONICAL
# resolver recognises. scripts/lanes/resolve.mjs honours PATHEXT on win32, so
# an extensionless file there is (correctly) NOT executable and would make a
# "lane is present" fixture silently absent — and a "false positive" fixture
# pass for the wrong reason. Plant both forms so the stub is real on every OS.
plant_cli() {
  local _dir="$1" _name="$2"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_dir/$_name"
  chmod +x "$_dir/$_name"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      printf '@echo off\r\nexit /b 0\r\n' > "$_dir/$_name.cmd"
      ;;
  esac
}

# run_install <stub_dir> <home_dir> <fixture_dir> [extra args...] — a dry-run
# adopter install with every lane CLI scrubbed off PATH unless the caller
# planted a stub in <stub_dir> first. Echoes combined output and RETURNS the
# wizard's exit code (callers run it under `set +e` and read $? — a `rc=`
# assignment inside would die with the command substitution's subshell).
run_install() {
  local _stub="$1" _home="$2" _fixture="$3"; shift 3
  local _p
  _p=$(build_path "$_stub" bash jq python3 npm -- "${LANE_TOOLS[@]}")
  make_git_stub "$_stub" "https://github.com/someone/other-repo.git"
  PATH="$_p" HOME="$_home" USERPROFILE="$(winpath "$_home")" HIMMELCTL_CACHE_DIR="$(winpath "$_home.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_home.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$_fixture")" \
    "$node_bin" "$wizard" install --dry-run "$@" </dev/null 2>&1
}

# capture <stub> <home> <fixture> [args...] — run_install with the rc dance
# done once, in the CALLER's shell: sets `out` and `rc`.
capture() {
  set +e
  out=$(run_install "$@")
  rc=$?
  set -e
}

# Slice the lane-report + summary epilogue out of a captured run.
epilogue() { printf '%s' "$1" | sed -n '/delegation lanes/,$p'; }

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. The obvious printf-into-`grep -q` is a trap under this
# file's `set -o pipefail`: grep -q exits the instant it matches, printf then
# takes SIGPIPE writing the remainder, and pipefail reports the PIPELINE as
# failed — so a SUCCESSFUL match returns non-zero whenever the match lands
# early in a large input. That is exactly what happened to caseM (matched on
# line 2 of a 2.4 KB epilogue) and it is latent in every such assertion: the
# outcome depends on how far down the match sits. A here-string is not a
# pipeline, so the status is grep's own verdict and nothing else.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# HIMMEL-1447: the wizard resolves the codex install command per-platform
# (adopter-profile.js pickByPlatform), so the suite asserts the ACTIVE
# platform's EXACT string. The previous win32 literal failed on ubuntu CI and
# passed vacuously on POSIX; an any-platform alternation was rejected in CR —
# it would keep CI green if the wizard regressed to another platform's hint.
# (Library-level platform mapping for all three platforms is pinned by caseQ.)
#
# HIMMEL-2352 (ruling 34): codex is the vehicle for every generic
# probe/summary mechanism case below that used to use ollama/copilot — those
# two are DROPPED from V1_LANES entirely (see adopter-profile.js's own
# comment), so a case whose whole point is exercising the SHARED probeLane/
# buildSummary machinery (not anything ollama/copilot-specific) now selects
# codex via --with-codex instead of relying on a non-opt-in default that no
# longer exists.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) CODEX_INSTALL_HINT='winget install OpenAI.Codex' ;;
  *)                    CODEX_INSTALL_HINT='npm install -g @openai/codex' ;;
esac
# Negative asserts reject EVERY platform's hint — a foreign-platform leak
# (winget on Linux) must fail too (CR round 2 [codex-adv-r2-1]).
CODEX_ANY_HINT_RE='winget install OpenAI[.]Codex|npm install -g @openai/codex'

# ── Case A: lanes absent -> MISSING + manual entry with the install command ──
# HIMMEL-2352: codex is opt-in in v1 (no non-opt-in lane exists any more), so
# --with-codex selects it the same way a real adopter's --with-codex or
# interactive 'codex' answer would.
sA="$work/a"; mkdir -p "$sA"; hA="$work/a-home"; mkdir -p "$hA"
fA="$work/a-fix"; make_fixture "$fA"
capture "$sA" "$hA" "$fA" --with-codex
[ "$rc" -eq 0 ] || fail "caseA: dry-run should succeed (got rc=$rc): $out"
grepq "$out" '"lanesMeaningful": true' \
  || fail "caseA: newly-built profiles must mark lane selections as meaningful: $out"
ep=$(epilogue "$out")
grepq "$ep" -E '!! +codex +MISSING' \
  || fail "caseA: codex should probe MISSING on a scrubbed PATH: $ep"
grepq "$ep" 'still manual' \
  || fail "caseA: summary should carry a 'still manual' section: $ep"
grepq "$ep" 'lane codex' \
  || fail "caseA: codex should appear in the manual section: $ep"
# The install command must be surfaced — an adopter who is told a lane is
# missing and NOT told how to get it has been given a defect report, not a
# next step.
grepq "$ep" -iE 'winget install OpenAI.Codex|npm install -g @openai/codex' \
  || fail "caseA: the manual entry must carry an install command: $ep"
# And the installer must never claim it installed a lane it only probed.
grepq "$ep" '+ lane codex' \
  && fail "caseA: an ABSENT lane must not appear under 'installed': $ep"
echo "ok: caseA absent lanes -> MISSING + manual entry carrying the install command"

# ── Case B: lane present -> available + installed, never manual ──────────────
sB="$work/b"; mkdir -p "$sB"; hB="$work/b-home"; mkdir -p "$hB"
fB="$work/b-fix"; make_fixture "$fB"
# Plant a fake `codex` the node-side which() will resolve. build_path scrubs
# the REAL one off PATH, so this stub is the only match. The fixture carries
# no scripts/install/manifest.json, so codex's richer readiness probe
# (manifestItem: 'codex-cli') degrades to 'unverified' exactly like a lane
# with no manifestItem at all (laneSetupState's ENOENT catch) — caseO below
# is the counterpart that DOES provide a manifest and pins the 'ready' branch.
plant_cli "$sB" codex
capture "$sB" "$hB" "$fB" --with-codex
[ "$rc" -eq 0 ] || fail "caseB: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '~ +codex +binary present' \
  || fail "caseB: a planted codex should probe available: $ep"
# CR round 1 [codex-1]: a present lane is a FACT, not an action himmelctl
# performed — it belongs in `skipped` ("already available, nothing to
# install"), never in the installed/would-install bucket.
grepq "$ep" -- '- lane codex — binary already present' \
  || fail "caseB: a present lane belongs under 'skipped' as already available: $ep"
grepq "$ep" 'nothing to install' \
  || fail "caseB: a present lane should say nothing to install (idempotent): $ep"
grepq "$ep" '+ lane codex' \
  && fail "caseB: a present lane must NOT be claimed as installed work: $ep"
# CR round 4 [codex-adv-r3-2]: the probe sees a BINARY, not a working lane.
# codex still needs auth (its note says so), so that step must survive into
# `still manual` as a verify item — dropping it told the adopter a lane they
# cannot yet use was ready. It must NOT be re-listed as an install, though.
grepq "$ep" 'cannot confirm setup' \
  || fail "caseB: a present lane's unverified setup must stay visible: $ep"
grepq "$ep" 'auth lives in ~/.codex/auth.json' \
  || fail "caseB: the retained setup step should name the auth step: $ep"
grepq "$ep" -E "$CODEX_ANY_HINT_RE" \
  && fail "caseB: a present lane must not be sent back to the package manager: $ep"
echo "ok: caseB present lane -> binary present + setup step retained, never re-installed"

# ── Case C: opt-in gating ────────────────────────────────────────────────────
sC="$work/c"; mkdir -p "$sC"; hC="$work/c-home"; mkdir -p "$hC"
fC="$work/c-fix"; make_fixture "$fC"
capture "$sC" "$hC" "$fC"
ep=$(epilogue "$out")
grepq "$ep" 'opt in with --with-codex' \
  || fail "caseC: a default run should show codex as opt-in: $ep"
grepq "$ep" 'opt in with --with-hermes' \
  || fail "caseC: a default run should show hermes as opt-in: $ep"
# HIMMEL-2303: no codex/hermes opt-in -> the summary discloses the resulting
# Claude-only CR floor.
grepq "$ep" 'cross-model CR floor — NOT satisfied' \
  || fail "caseC: a default run (no codex/hermes opt-in) should disclose the Claude-only CR floor: $ep"
grepq "$ep" 'cross-model CR floor — satisfied' \
  && fail "caseC: a default run must NOT claim the cross-model floor is satisfied: $ep"
sC2="$work/c2"; mkdir -p "$sC2"; hC2="$work/c2-home"; mkdir -p "$hC2"
capture "$sC2" "$hC2" "$fC" --with-codex
[ "$rc" -eq 0 ] || fail "caseC: --with-codex should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '(!!|ok) +codex' \
  || fail "caseC: --with-codex should SELECT codex (probed, not 'not selected'): $ep"
grepq "$ep" 'opt in with --with-hermes' \
  || fail "caseC: --with-codex must not also select hermes: $ep"
# CR round 1 [codex-2]: opting in is not the same as the lane actually being
# usable. This fixture never plants a codex binary (LANE_TOOLS is scrubbed
# off PATH by run_install), so codex reads ABSENT even though it was opted
# into — the floor must say NOT satisfied yet, never a bare "satisfied" off
# the opt-in alone.
grepq "$ep" 'cross-model CR floor — NOT satisfied yet: codex opted in but not available' \
  || fail "caseC: --with-codex with codex ABSENT should disclose 'not satisfied yet', not a bare satisfied claim: $ep"
grepq "$ep" 'cross-model CR floor — satisfied' \
  && fail "caseC: --with-codex with codex ABSENT must not claim the floor satisfied: $ep"

# The genuinely-satisfied case: codex opted in AND actually present.
sC3="$work/c3"; mkdir -p "$sC3"; hC3="$work/c3-home"; mkdir -p "$hC3"
plant_cli "$sC3" codex
capture "$sC3" "$hC3" "$fC" --with-codex
[ "$rc" -eq 0 ] || fail "caseC: --with-codex + a present codex binary should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
# HIMMEL-2303: codex opted in AND present -> the summary reflects the
# RESULTING satisfied CR floor.
grepq "$ep" 'cross-model CR floor — satisfied (codex opted in and present)' \
  || fail "caseC: --with-codex + a present codex binary should disclose the satisfied cross-model CR floor: $ep"
grepq "$ep" 'cross-model CR floor — NOT satisfied' \
  && fail "caseC: --with-codex + a present codex binary must not claim the Claude-only floor still applies: $ep"

# CR round 2 [codex-1]: BOTH lanes opted in, but only the SECOND (hermes) is
# present — V1_LANES orders codex before hermes, so checking only the first
# opted-in lane would report "not satisfied" even though hermes could review.
# hermes' probe needs a real venv under HERMES_HOME (never a bare PATH hit —
# see caseK above), so this builds that fixture directly rather than through
# the shared capture() helper, which has no HERMES_HOME seam.
sC4="$work/c4"; mkdir -p "$sC4"; hC4="$work/c4-home"; mkdir -p "$hC4"
vC4="$work/c4-venv"; mkdir -p "$vC4/venv/bin" "$vC4/venv/Scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$vC4/venv/bin/python"; chmod +x "$vC4/venv/bin/python"
printf 'stub\n' > "$vC4/venv/Scripts/python.exe"
pC4=$(build_path "$sC4" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sC4" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pC4" HOME="$hC4" USERPROFILE="$(winpath "$hC4")" HIMMELCTL_CACHE_DIR="$(winpath "$hC4.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hC4.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HERMES_HOME="$(winpath "$vC4")" \
      HIMMELCTL_REPO_ROOT="$(winpath "$fC")" \
      "$node_bin" "$wizard" install --dry-run --with-codex --with-hermes </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseC: --with-codex --with-hermes + only hermes present should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" 'cross-model CR floor — satisfied (hermes opted in and present)' \
  || fail "caseC: with codex ABSENT and hermes PRESENT (both opted in), the floor must be satisfied via hermes, not report unsatisfied because codex (checked first) is absent: $ep"
grepq "$ep" 'cross-model CR floor — NOT satisfied' \
  && fail "caseC: must not report unsatisfied when hermes (the second opted-in lane) is present: $ep"
echo "ok: caseC opt-in lanes appear only under their own flag; CR-floor disclosure reflects the RESULTING selection (opted-in-but-absent vs opted-in-and-present vs a later opted-in lane satisfying it)"

# ── Case D: flag validation ─────────────────────────────────────────────────
expect_rc2() {
  local _label="$1"; shift
  set +e
  local _o
  _o=$(HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/caseD-expect-rc2.himmelctl-cache")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/caseD-expect-rc2.himmelctl-cache/luna-config.json")" \
    "$node_bin" "$wizard" install "$@" </dev/null 2>&1)
  local _rc=$?
  set -e
  [ "$_rc" -eq 2 ] || fail "caseD/$_label: expected rc=2, got $_rc: $_o"
}
expect_rc2 bogus-lane --lanes bogus
expect_rc2 optin-via-lanes --lanes codex
expect_rc2 empty-lanes --lanes ,
expect_rc2 profile-conflict --from-profile "$work/nope.json" --with-codex
expect_rc2 profile-conflict-lanes --from-profile "$work/nope.json" --lanes none

# HIMMEL-2352 (ruling 34): --lanes accepts ONLY 'none' in v1 — ollama/copilot
# are refused the SAME way codex/hermes are (one door, not two), but with
# DISTINCT wording naming the scripts/lanes/lanes.json opt-in env instead of a
# --with-<id> flag that does not exist for them. 'none' itself must still work.
for _dormant_pair in 'ollama:OLLAMA_LOCAL_LANE_OK' 'copilot:COPILOT_CLI_LANE_OK'; do
  _dl="${_dormant_pair%%:*}"; _de="${_dormant_pair##*:}"
  expect_rc2 "dormant-$_dl" --lanes "$_dl"
  set +e
  dormant_out=$(HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/caseD-dormant-$_dl.himmelctl-cache")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/caseD-dormant-$_dl.himmelctl-cache/luna-config.json")" \
    "$node_bin" "$wizard" install --lanes "$_dl" </dev/null 2>&1)
  set -e
  grepq "$dormant_out" "dormant in v1" \
    || fail "caseD: --lanes $_dl should be refused with dormant wording, not a bare unknown-lane message: $dormant_out"
  grepq "$dormant_out" "$_de=1" \
    || fail "caseD: --lanes $_dl's refusal should name its lanes.json opt-in env ($_de): $dormant_out"
done
sDnone="$work/d-none"; mkdir -p "$sDnone"; hDnone="$work/d-none-home"; mkdir -p "$hDnone"
fDnone="$work/d-none-fix"; make_fixture "$fDnone"
capture "$sDnone" "$hDnone" "$fDnone" --lanes none
[ "$rc" -eq 0 ] || fail "caseD: --lanes none should be accepted (got rc=$rc): $out"

# CR round 10 [codex-r9-1] investigated this ordering: with a MISSING profile
# the run must report the flag-CONFLICT (a parse-time contract), never the
# profile-LOAD failure. It already does — the combination is rejected in
# parseArgs, before cmdInstall ever opens the file — but only the rc was
# pinned, so the message class could have drifted without a test noticing.
# Both are asserted now, including the absence of any load-failure text.
# 'none' is the only value --lanes accepts in v1 (see the dormant-refusal
# block above), so it is the value used here to exercise the CONFLICT check
# itself without also tripping the lane-validity refusal.
set +e
conflict_out=$(HIMMELCTL_INTERACTIVE=0 \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/caseD-conflict.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/caseD-conflict.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" install \
  --from-profile "$work/definitely-not-here.json" --lanes none </dev/null 2>&1)
conflict_rc=$?
set -e
[ "$conflict_rc" -eq 2 ] \
  || fail "caseD: missing profile + --lanes should exit 2 (got $conflict_rc): $conflict_out"
grepq "$conflict_out" 'cannot be combined with --from-profile' \
  || fail "caseD: should report the flag CONFLICT, not a load error: $conflict_out"
grepq "$conflict_out" -iE 'ENOENT|no such file|not valid JSON|invalid profile' \
  && fail "caseD: the profile must not even be OPENED when the flags conflict: $conflict_out"
echo "ok: caseD bad/opt-in/empty --lanes and --from-profile conflicts all exit 2 with the conflict message"

# ── Case D2: legacy empty lane placeholder requires reconfirmation ──────────
sD2="$work/d2"; mkdir -p "$sD2"; hD2="$work/d2-home"; mkdir -p "$hD2"
fD2="$work/d2-fix"; make_fixture "$fD2"
profD2="$work/d2-legacy-profile.json"
cat > "$profD2" <<'JSON'
{
  "role": "adopter",
  "tier": "standard",
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "alwaysOn": false
}
JSON
pD2=$(build_path "$sD2" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sD2" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pD2" HOME="$hD2" USERPROFILE="$(winpath "$hD2")" HIMMELCTL_CACHE_DIR="$(winpath "$hD2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hD2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fD2")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profD2")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "caseD2: legacy lanes:[] profile must exit 2 (got rc=$rc): $out"
grepq "$out" 'legacy profile has lanes:\[\]' \
  || fail "caseD2: refusal must identify the legacy empty placeholder: $out"
grepq "$out" 'reconfirm lane selection' \
  || fail "caseD2: refusal must tell the operator how to recover: $out"
echo "ok: caseD2 legacy lanes:[] profile fails loud and requires lane-selection reconfirmation"

# ── case D3 (HIMMEL-2352 backward compatibility): a profile naming a lane
# this ticket made DORMANT must still LOAD. ollama and copilot were the
# DEFAULT selection before 2352, so every adopter who ran the wizard has them
# in ~/.claude/himmel/install-profile.json, and the shipped operator profile
# carried them too — erroring would brick all of those caches on the next
# --from-profile run. They are dropped from the effective selection with a
# note naming the registry opt-in env instead. The NEGATIVE half matters just
# as much: an id that was never a lane must still fail loud, so the carve-out
# is keyed to the known dormant set and not to "anything unrecognised".
sD3="$work/d3"; mkdir -p "$sD3"; hD3="$work/d3-home"; mkdir -p "$hD3"
fD3="$work/d3-fix"; make_fixture "$fD3"
pD3=$(build_path "$sD3" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sD3" "https://github.com/someone/other-repo.git"

run_d3() {
  PATH="$pD3" HOME="$hD3" USERPROFILE="$(winpath "$hD3")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$hD3.himmelctl-cache")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hD3.himmelctl-cache/luna-config.json")" \
    HIMMELCTL_INTERACTIVE=0 HIMMELCTL_REPO_ROOT="$(winpath "$fD3")" \
    "$node_bin" "$wizard" install --from-profile "$(winpath "$1")" --dry-run </dev/null 2>&1
}

# D3a — the pre-2352 default selection, verbatim.
profD3="$work/d3-dormant-profile.json"
cat > "$profD3" <<'JSON'
{
  "schemaVersion": 2,
  "profile": "starter",
  "scope": "project",
  "vault": { "mode": "none" },
  "handover": { "mode": "inline" },
  "pluginSet": "lean",
  "lanes": ["codex", "copilot", "hermes", "ollama"],
  "lanesMeaningful": true,
  "alwaysOn": false,
  "devOverlay": false
}
JSON
set +e
out=$(run_d3 "$profD3"); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case D3a: a profile naming the pre-2352 default lanes must still LOAD (got rc=$rc): $out"
grepq "$out" -F "profile names lane 'ollama', which is dormant in v1" \
  || fail "case D3a: the drop of a dormant lane must be announced, not silent: $out"
grepq "$out" -F 'OLLAMA_LOCAL_LANE_OK=1' \
  || fail "case D3a: the note must name the registry opt-in env, not imply a --with-ollama flag: $out"
grepq "$out" -F "profile names lane 'copilot', which is dormant in v1" \
  || fail "case D3a: copilot must be announced too, not just the first dormant lane: $out"
grepq "$out" -F 'COPILOT_CLI_LANE_OK=1' \
  || fail "case D3a: copilot's note must name its own opt-in env: $out"
grepq "$out" -E 'derived: .*adopt\.sh' \
  || fail "case D3a: the core install must still be derived — dropping a dormant lane is not a refusal: $out"

# D3b — NEGATIVE control: an id that was never a lane still fails loud.
profD3b="$work/d3-bogus-profile.json"
cat > "$profD3b" <<'JSON'
{
  "schemaVersion": 2,
  "profile": "starter",
  "scope": "project",
  "vault": { "mode": "none" },
  "handover": { "mode": "inline" },
  "pluginSet": "lean",
  "lanes": ["codex", "not-a-real-lane"],
  "lanesMeaningful": true,
  "alwaysOn": false,
  "devOverlay": false
}
JSON
set +e
outB=$(run_d3 "$profD3b"); rcB=$?
set -e
[ "$rcB" -ne 0 ] || fail "case D3b: an unknown lane id must STILL fail loud, not be swallowed by the dormant carve-out (got rc=0): $outB"
grepq "$outB" -F 'contains unknown lane "not-a-real-lane"' \
  || fail "case D3b: the refusal must name the offending id: $outB"
grepq "$outB" -F "dormant in v1" \
  && fail "case D3b: an unknown id must not be described as dormant: $outB"
echo "ok: case D3 — a pre-2352 profile naming ollama/copilot still loads (dropped with a note naming its opt-in env); a genuinely unknown lane still fails loud"

# ── Case E: hardening PRINTED, never EXECUTED ───────────────────────────────
# A sentinel `powercfg` stub: if the installer ever shelled out to it, the
# sentinel file would exist. This is the assertion the whole rescope turns on.
sE="$work/e"; mkdir -p "$sE"; hE="$work/e-home"; mkdir -p "$hE"
fE="$work/e-fix"; make_fixture "$fE"
sentinel="$work/POWERCFG-WAS-EXECUTED"
cat > "$sE/powercfg" <<STUB
#!/usr/bin/env bash
printf 'executed\n' > "$sentinel"
exit 0
STUB
chmod +x "$sE/powercfg"
profE="$work/e-profile.json"
cat > "$profE" <<'JSON'
{
  "role": "adopter",
  "tier": "standard",
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": true
}
JSON
pE=$(build_path "$sE" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sE" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pE" HOME="$hE" USERPROFILE="$(winpath "$hE")" HIMMELCTL_CACHE_DIR="$(winpath "$hE.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hE.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fE")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profE")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseE: profile install should succeed (got rc=$rc): $out"
grepq "$out" 'CHECKLIST ONLY' \
  || fail "caseE: alwaysOn=true must print the checklist banner: $out"
[ -f "$sentinel" ] \
  && fail "caseE: HARDENING WAS EXECUTED — powercfg stub ran (sentinel $sentinel exists)"
# HIMMEL-1444: the hardening checklist is platform-branched
# (hardeningChecklistLines filters HARDENING_CHECKLIST by platform; every step
# is win32-only so far). caseE drives the REAL wizard on the HOST, so it must
# assert the host-appropriate content: the real Phase-6 commands on win32, and
# the honest "no steps published for <platform>" note on any other host (the
# emission is already platform-correct; caseQ separately pins the cross-
# platform emission via forced-platform library renders). caseE's own job is
# the integration invariant -- alwaysOn=true PRINTS the checklist and
# EXECUTES none of it -- which holds on every platform.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    grepq "$out" 'powercfg /hibernate off' \
      || fail "caseE: the checklist must carry the real Phase-6 commands: $out"
    # CR round 11 [codex-adv-r10-1]: sshd reads its config at START, so
    # `Start-Service` against an already-running daemon is a no-op and the OLD
    # (possibly password-auth) config stays live — which would make the whole
    # policy-before-enable ordering cosmetic. The checklist must restart a
    # running service, and the access policy must precede the enable step.
    grepq "$out" 'Restart-Service sshd' \
      || fail "caseE: the checklist must RESTART an already-running sshd: $out"
    grepq "$out" "Get-Service sshd).Status -eq 'Running'" \
      || fail "caseE: the checklist should branch on the current service state: $out"
    policy_line=$(printf '%s' "$out" | grep -n 'SSH access policy' | head -1 | cut -d: -f1)
    enable_line=$(printf '%s' "$out" | grep -n 'Enable sshd' | head -1 | cut -d: -f1)
    [ "$policy_line" -lt "$enable_line" ] \
      || fail "caseE: the access policy must be printed BEFORE the enable step: $out"
    grepq "$out" 'PreferredAuthentications=password' \
      || fail "caseE: the off-box password-refusal verification must survive: $out"
    ;;
  *)
    # Non-win32 host: the checklist honestly reports no platform-specific
    # hardening steps yet. Assert that note is present and that NO Windows-only
    # command leaked into a POSIX host's checklist.
    grepq "$out" 'no hardening steps are published for platform' \
      || fail "caseE: a non-win32 host should get the honest 'no steps for platform' note: $out"
    grepq "$out" 'powercfg' \
      && fail "caseE: a non-win32 host's checklist must not carry Windows-only powercfg commands: $out"
    ;;
esac
echo "ok: caseE alwaysOn=true prints the checklist and executes NONE of it (platform-correct content)"

# ── Case F: alwaysOn=false -> pointer only, no powercfg text ────────────────
sF="$work/f"; mkdir -p "$sF"; hF="$work/f-home"; mkdir -p "$hF"
fF="$work/f-fix"; make_fixture "$fF"
capture "$sF" "$hF" "$fF"
grepq "$out" 'always-on hardening: skipped' \
  || fail "caseF: alwaysOn=false should print the one-line pointer: $out"
grepq "$out" 'powercfg' \
  && fail "caseF: alwaysOn=false must not dump the checklist: $out"
echo "ok: caseF alwaysOn=false -> pointer line only, no checklist"

# ── Case G (HIMMEL-2308): --contribute gets its own report AND the ──────────
# universal epilogue, never one instead of the other. The old role fork used
# to print the contributor-dev report EXCLUSIVELY (no adopter lane/summary
# section) — devOverlay is an orthogonal layer now, so BOTH sections print.
sG="$work/g"; mkdir -p "$sG"; hG="$work/g-home"; mkdir -p "$hG"
fG="$work/g-fix"; make_fixture "$fG"
mkdir -p "$fG/scripts/install"
cp "$repo_root/scripts/install/manifest.json" "$fG/scripts/install/manifest.json"
cp "$repo_root/scripts/install/deps.json" "$fG/scripts/install/deps.json"
# The dev overlay's own primitive — contributeCheckoutOk() reads this (the
# platform-appropriate one), and deriveOverlayCommand() derives it as the
# overlay's additional command.
printf '#!/usr/bin/env bash\nexit 0\n' > "$fG/scripts/setup.sh"
chmod +x "$fG/scripts/setup.sh"
printf 'exit 0\n' > "$fG/scripts/setup.ps1"
pG=$(build_path "$sG" bash jq python3 npm -- "${LANE_TOOLS[@]}")
set +e
out=$(PATH="$pG" HOME="$hG" USERPROFILE="$(winpath "$hG")" HIMMELCTL_CACHE_DIR="$(winpath "$hG.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hG.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fG")" \
      "$node_bin" "$wizard" install --dry-run --contribute 2>&1 <<INPUT
starter
project
none
inline
lean
none
no
INPUT
); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseG: --contribute dry-run should succeed (got rc=$rc): $out"
grepq "$out" '"devOverlay": true' \
  || fail "caseG: --contribute should record devOverlay=true (got: $out)"
grepq "$out" 'contributor dev profile' \
  || fail "caseG: --contribute should print its own dev-overlay report (got: $out)"
grepq "$out" 'delegation lanes' \
  || fail "caseG: --contribute must ALSO print the universal adopter lane report, not instead-of it (got: $out)"
grepq "$out" 'install summary' \
  || fail "caseG: --contribute must ALSO print the universal install summary (got: $out)"
echo "ok: caseG --contribute -> the dev-overlay report AND the universal epilogue both print"

# ── Case H: two identical runs -> byte-identical epilogue ───────────────────
sH="$work/h"; mkdir -p "$sH"; hH="$work/h-home"; mkdir -p "$hH"
fH="$work/h-fix"; make_fixture "$fH"
capture "$sH" "$hH" "$fH"; out1="$out"
ep1=$(epilogue "$out1")
sH2="$work/h2"; mkdir -p "$sH2"; hH2="$work/h2-home"; mkdir -p "$hH2"
capture "$sH2" "$hH2" "$fH"; out2="$out"
ep2=$(epilogue "$out2")
[ "$ep1" = "$ep2" ] || fail "caseH: repeated runs should be byte-identical
first:  <$ep1>
second: <$ep2>"
echo "ok: caseH repeated runs produce a byte-identical epilogue (idempotent)"

# ── Case I: unreadable lane registry -> UNKNOWN, never a false 'available' ──
sI="$work/i"; mkdir -p "$sI"; hI="$work/i-home"; mkdir -p "$hI"
fI="$work/i-fix"; make_fixture "$fI" --no-registry
capture "$sI" "$hI" "$fI" --with-codex
[ "$rc" -eq 0 ] || fail "caseI: a missing registry must not crash the run (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '\?\? +codex +UNKNOWN' \
  || fail "caseI: a missing lane registry should degrade to UNKNOWN: $ep"
grepq "$ep" -E '(ok|~) +codex' \
  && fail "caseI: a missing registry must NEVER report a lane as available: $ep"
echo "ok: caseI unreadable lane registry -> UNKNOWN, never a false available"

# ── Case J: --dry-run must NEVER use the `installed` label ──────────────────
# CR round 1 [codex-1]. The regression this pins: the summary used to print
# `installed:` under --dry-run, claiming work that had not happened. Asserted
# twice over — on the printed text AND on the pure-data model, so the bucket
# cannot silently go back to being one list with a cosmetic heading.
sJ="$work/j"; mkdir -p "$sJ"; hJ="$work/j-home"; mkdir -p "$hJ"
fJ="$work/j-fix"; make_fixture "$fJ"
capture "$sJ" "$hJ" "$fJ"
[ "$rc" -eq 0 ] || fail "caseJ: dry-run should succeed (got rc=$rc): $out"
grepq "$out" -E '^installed:$' \
  && fail "caseJ: --dry-run must NOT print the 'installed:' heading: $out"
grepq "$out" 'would install' \
  || fail "caseJ: --dry-run should print a 'would install' heading: $out"
grepq "$out" 'NOTHING below was executed' \
  || fail "caseJ: --dry-run heading should say nothing was executed: $out"

# The same claim on the model itself (pure data, no text scraping).
# Single-quoted on purpose: this is JS handed to node verbatim, so the shell
# must not touch it. The lib path arrives as argv[1], not by interpolation.
# shellcheck disable=SC2016
"$node_bin" -e '
const a = require(process.argv[1]);
const ans = { role:"adopter", scope:"project", vault:{mode:"default-template",path:"/v"},
              handover:{mode:"external",path:"/h"}, pluginSet:"full", lanes:[], alwaysOn:false };
const dry = a.buildSummary(ans, [], { derived:"x", dryRun:true });
const app = a.buildSummary(ans, [], { derived:"x", dryRun:false });
if (dry.installed.length !== 0) { console.error("dry-run populated `installed`"); process.exit(1); }
if (dry.planned.length === 0)   { console.error("dry-run left `planned` empty"); process.exit(1); }
if (app.planned.length !== 0)   { console.error("applied run populated `planned`"); process.exit(1); }
if (app.installed.length === 0) { console.error("applied run left `installed` empty"); process.exit(1); }
if (dry.planned.length !== app.installed.length) { console.error("bucket contents diverge"); process.exit(1); }
' "$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")" \
  || fail "caseJ: buildSummary model is not dry-run honest"

# And the applied path DOES use the installed label (the fix must not have
# simply removed it everywhere).
sJ2="$work/j2"; mkdir -p "$sJ2"; hJ2="$work/j2-home"; mkdir -p "$hJ2"
fJ2="$work/j2-fix"; make_fixture "$fJ2"
profJ="$work/j-profile.json"
cat > "$profJ" <<'JSON'
{
  "role": "adopter",
  "tier": "standard",
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
pJ=$(build_path "$sJ2" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sJ2" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pJ" HOME="$hJ2" USERPROFILE="$(winpath "$hJ2")" HIMMELCTL_CACHE_DIR="$(winpath "$hJ2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hJ2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fJ2")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profJ")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseJ: applied run should succeed (got rc=$rc): $out"
grepq "$out" -E '^installed:$' \
  || fail "caseJ: an APPLIED run should print the 'installed:' heading: $out"
grepq "$out" 'would install' \
  && fail "caseJ: an APPLIED run must not print a 'would install' heading: $out"
echo "ok: caseJ --dry-run never claims 'installed'; the applied run still does"

# ── Case K: hermes uses the CANONICAL `installed` probe, not a PATH lookup ──
# CR round 1 [codex-adv-3]. The registry's `installed` kind is resolved by
# scripts/lanes/resolve.mjs (HERMES_PY, then venvs under HERMES_HOME /
# LOCALAPPDATA) — NOT by looking for `hermes` on PATH. Both directions of the
# old duplicate's error are pinned here: a real install must not read missing,
# and an unrelated `hermes` executable must not read present.
kfix="$work/k-fix"; make_fixture "$kfix"
# hermes_probe <label> <stub_dir> <HERMES_HOME> <HERMES_PY> -> echoes the row
hermes_probe() {
  local _label="$1" _stub="$2" _home="$3" _py="$4"
  local _p _h="$work/$_label-home"
  mkdir -p "$_h"
  _p=$(build_path "$_stub" bash jq python3 npm -- "${LANE_TOOLS[@]}")
  make_git_stub "$_stub" "https://github.com/someone/other-repo.git"
  set +e
  PATH="$_p" HOME="$_h" USERPROFILE="$(winpath "$_h")" HIMMELCTL_CACHE_DIR="$(winpath "$_h.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_h.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
    HERMES_HOME="$_home" HERMES_PY="$_py" \
    HIMMELCTL_REPO_ROOT="$(winpath "$kfix")" \
    "$node_bin" "$wizard" install --dry-run --lanes none --with-hermes </dev/null 2>&1
  set -e
}

# K1 — the FALSE-POSITIVE guard: a `hermes` executable sits on PATH but there
# is no hermes installation. The lane must read MISSING.
sK1="$work/k1"; mkdir -p "$sK1"; emptyK="$work/k-empty"; mkdir -p "$emptyK"
plant_cli "$sK1" hermes
out=$(hermes_probe k1 "$sK1" "$(winpath "$emptyK")" "")
grepq "$out" -E '!! +hermes +MISSING' \
  || fail "caseK1: an unrelated hermes on PATH must NOT read as installed: $(epilogue "$out")"

# K2 — a standard venv under HERMES_HOME, with `hermes` scrubbed off PATH.
# Both layouts resolve.mjs accepts are planted so this holds on win32+posix.
sK2="$work/k2"; mkdir -p "$sK2"
vK="$work/k-venv"; mkdir -p "$vK/venv/bin" "$vK/venv/Scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$vK/venv/bin/python"; chmod +x "$vK/venv/bin/python"
printf 'stub\n' > "$vK/venv/Scripts/python.exe"
out=$(hermes_probe k2 "$sK2" "$(winpath "$vK")" "")
grepq "$out" -E '~ +hermes +binary present' \
  || fail "caseK2: a venv under HERMES_HOME must read as installed: $(epilogue "$out")"

# K3 — an explicit HERMES_PY wins even with an empty HERMES_HOME.
sK3="$work/k3"; mkdir -p "$sK3"
out=$(hermes_probe k3 "$sK3" "$(winpath "$emptyK")" "$(winpath "$vK/venv/bin/python")")
grepq "$out" -E '~ +hermes +binary present' \
  || fail "caseK3: an explicit HERMES_PY must read as installed: $(epilogue "$out")"
echo "ok: caseK hermes honors HERMES_PY + venv layouts and rejects a bare PATH hit"

# ── Case L (HIMMEL-2304): a legacy pluginSet=full profile must never be ─────
# reported as an enabled/failed plugin step — that step is GONE. Before this
# ticket, `claude` absent from PATH made every `claude plugin ...` command
# fail and the summary reported that failure (CR round 1 [codex-adv-2]); now
# `claude` is never invoked at all, so the run succeeds and the summary says
# the option was retired, never "enabled" and never "FAILED".
sL="$work/l"; mkdir -p "$sL"; hL="$work/l-home"; mkdir -p "$hL"
fL="$work/l-fix"; make_fixture "$fL"
profL="$work/l-profile.json"
cat > "$profL" <<'JSON'
{
  "role": "adopter",
  "tier": "standard",
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "full",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
pL=$(build_path "$sL" bash jq python3 npm -- "${LANE_TOOLS[@]}" claude)
make_git_stub "$sL" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pL" HOME="$hL" USERPROFILE="$(winpath "$hL")" HIMMELCTL_CACHE_DIR="$(winpath "$hL.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hL.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fL")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profL")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "caseL: a legacy pluginSet=full profile has no plugin step left to fail — should exit 0 (got rc=$rc): $out"
grepq "$out" 'full plugin set enabled' \
  && fail "caseL: must NOT claim the full plugin set was enabled — the step no longer runs: $out"
grepq "$out" 'plugin command(s) FAILED' \
  && fail "caseL: must NOT report a plugin-command failure — no plugin command was ever invoked: $out"
grepq "$out" 'retired (HIMMEL-2304)' \
  || fail "caseL: the summary should say pluginSet=full was retired: $out"
echo "ok: caseL a legacy pluginSet=full profile -> retired, never reported as enabled or failed"

# L2 — the same pluginSet=full profile under --dry-run must ALSO never claim
# "full plugin set enabled" or preview a plugin-enable DRY line — there is
# nothing left to plan.
sL2="$work/l2"; mkdir -p "$sL2"; hL2="$work/l2-home"; mkdir -p "$hL2"
pL2=$(build_path "$sL2" bash jq python3 npm -- "${LANE_TOOLS[@]}" claude)
make_git_stub "$sL2" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pL2" HOME="$hL2" USERPROFILE="$(winpath "$hL2")" HIMMELCTL_CACHE_DIR="$(winpath "$hL2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hL2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fL")" \
      "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profL")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseL2: dry-run should succeed (got rc=$rc): $out"
grepq "$out" 'full plugin set enabled' \
  && fail "caseL2: --dry-run must not claim the retired enable step ran: $out"
grepq "$out" 'would be enabled' \
  && fail "caseL2: --dry-run must not preview a retired enable step as planned work: $out"
grepq "$out" 'retired (HIMMEL-2304)' \
  || fail "caseL2: --dry-run should also say pluginSet=full was retired: $out"
echo "ok: caseL2 --dry-run also reports pluginSet=full as retired, never planned or done"

# ── Case M: a lane DISABLED by lanes.local.json must not read ready ─────────
# CR round 2 [codex-adv-r2-1]. The probe used to read base lanes.json alone,
# so a locally-disabled lane still reported "available" while /lanes excluded
# it. The installer's epilogue must agree with the runtime surface. The lane
# is ALSO physically installed here, so this pins the second half too: the
# next step is a config flip, not a reinstall.
sM="$work/m"; mkdir -p "$sM"; hM="$work/m-home"; mkdir -p "$hM"
fM="$work/m-fix"; make_fixture "$fM"
cat > "$fM/scripts/lanes/lanes.local.json" <<'OVERLAY'
{ "lanes": [ { "id": "codex-exec", "probe": { "kind": "never" } } ] }
OVERLAY
plant_cli "$sM" codex
capture "$sM" "$hM" "$fM" --with-codex
[ "$rc" -eq 0 ] || fail "caseM: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '~ +codex +binary present' \
  && fail "caseM: an overlay-DISABLED lane must NOT read as available: $ep"
grepq "$ep" -E '\-\- +codex +DISABLED' \
  || fail "caseM: an overlay-disabled lane should read DISABLED: $ep"
grepq "$ep" 'config set lanes.codex-exec on' \
  || fail "caseM: the fix for a disabled lane is a config flip, and must be named: $ep"
# It is installed — so it must NOT be reported as something to go install.
grepq "$ep" -E "$CODEX_ANY_HINT_RE" \
  && fail "caseM: a DISABLED-but-installed lane must not be sent back to the package manager: $ep"
# Sanity: the same fixture WITHOUT the overlay reads available, proving the
# difference comes from the overlay and not from the stub being broken.
fM2="$work/m2-fix"; make_fixture "$fM2"
sM2="$work/m2"; mkdir -p "$sM2"; hM2="$work/m2-home"; mkdir -p "$hM2"
plant_cli "$sM2" codex
capture "$sM2" "$hM2" "$fM2" --with-codex
grepq "$(epilogue "$out")" -E '~ +codex +binary present' \
  || fail "caseM: without the overlay the same stub must read available: $(epilogue "$out")"
echo "ok: caseM overlay-disabled lane reads DISABLED, not ready, and not reinstallable"

# ── Case N: a PRESENT-but-INVALID overlay must fail closed ─────────────────
# CR round 4 [codex-adv-r3-3]. An ABSENT lanes.local.json is normal (use the
# base registry); a present-but-corrupt one is not. The canonical resolver
# die(2)s on exactly that file, so if `/lanes` cannot resolve at all, the
# installer must not go on certifying lanes off the base registry — it must
# say UNKNOWN and name the file that needs fixing.
for _shape in truncated wrongshape; do
  sN="$work/n-$_shape"; mkdir -p "$sN"; hN="$work/n-$_shape-home"; mkdir -p "$hN"
  fN="$work/n-$_shape-fix"; make_fixture "$fN"
  case "$_shape" in
    truncated)  printf '{"lanes":[{"id":"codex-exec",\n' > "$fN/scripts/lanes/lanes.local.json" ;;
    wrongshape) printf '{"lanes":{}}\n'                    > "$fN/scripts/lanes/lanes.local.json" ;;
  esac
  # Plant the binary too: without the fail-closed the lane would read present,
  # so this proves the overlay error wins over a real probe hit.
  plant_cli "$sN" codex
  capture "$sN" "$hN" "$fN" --with-codex
  [ "$rc" -eq 0 ] || fail "caseN/$_shape: a corrupt overlay must not crash the run (got rc=$rc): $out"
  ep=$(epilogue "$out")
  grepq "$ep" -E '\?\? +codex +UNKNOWN' \
    || fail "caseN/$_shape: a corrupt overlay should make lanes read UNKNOWN: $ep"
  grepq "$ep" 'lanes.local.json' \
    || fail "caseN/$_shape: the diagnostic must NAME the offending file: $ep"
  grepq "$ep" -E '(ok|~) +codex' \
    && fail "caseN/$_shape: a corrupt overlay must not still report the lane usable: $ep"
done
echo "ok: caseN corrupt lanes.local.json -> UNKNOWN, file named, fails closed like the resolver"

# ── Case O: a lane with a RICHER readiness probe can read genuinely ready ───
# CR round 4 [codex-adv-r3-2], the other half of caseB: codex carries a
# manifest probe (cmd:codex_provisioned) that checks provisioning, not just
# the binary. When it reports ready, no verify item is emitted — otherwise
# "setup unverified" would be noise rather than information. Driven off a
# fixture manifest so the assertion does not depend on this machine's codex.
sO="$work/o"; mkdir -p "$sO"; hO="$work/o-home"; mkdir -p "$hO"
fO="$work/o-fix"; make_fixture "$fO"
mkdir -p "$fO/scripts/install"
# A `dep`-probe manifest item stands in for the real provisioning probe: it is
# satisfied by the planted binary, so this case pins the READY branch (no
# verify item) without needing a provisioned codex on the test machine.
cat > "$fO/scripts/install/manifest.json" <<'MANIFEST'
{ "schemaVersion": 2, "harness": {}, "items": [
  { "id": "codex-cli", "kind": "dep", "scopes": ["user"], "profiles": ["core","all"],
    "deps": [], "probe": { "type": "dep", "cmd": "codex" } } ] }
MANIFEST
plant_cli "$sO" codex
capture "$sO" "$hO" "$fO" --lanes none --with-codex
[ "$rc" -eq 0 ] || fail "caseO: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E 'ok +codex +ready' \
  || fail "caseO: a lane whose richer probe passes should read ready: $ep"
grepq "$ep" 'cannot confirm setup' \
  && fail "caseO: a verified-ready lane must not also claim unverified setup: $ep"
echo "ok: caseO richer readiness probe -> 'ready', no redundant verify item"

# ── Case P: an `always` overlay must not conjure a missing binary ──────────
# CR round 5 [codex-adv-r5-1] — a REGRESSION the round-2 overlay merge
# introduced, and the exact probe.kind=always trap this module was built to
# avoid, re-entering through the overlay. `himmelctl config set lanes.<id> on`
# writes probe.kind=always; evaluating that first and returning on any truthy
# result made a machine with NO binary report "binary present" and silently
# drop its install command. An override expresses intent; it cannot conjure an
# executable. The full 2x2 (physical x enabled) is pinned here.
pM_fix() { make_fixture "$1"; printf '%s\n' "$2" > "$1/scripts/lanes/lanes.local.json"; }
# HIMMEL-2352: codex is the vehicle (see the CODEX_INSTALL_HINT comment above)
# — ollama-local is dormant-in-v1, so its registry row can no longer be
# reached through the wizard's own opt-in path at all; codex exercises the
# identical mergeLocalOverlay/probeLane machinery this case is pinning.
ALWAYS_OVERLAY='{ "lanes": [ { "id": "codex-exec", "probe": { "kind": "always" } } ] }'

# P1 — forced ON, nothing installed: must NOT read present, and must KEEP the
# install command. This is the reproduction from the review.
sP1="$work/p1"; mkdir -p "$sP1"; hP1="$work/p1-home"; mkdir -p "$hP1"
fP1="$work/p1-fix"; pM_fix "$fP1" "$ALWAYS_OVERLAY"
capture "$sP1" "$hP1" "$fP1" --with-codex
[ "$rc" -eq 0 ] || fail "caseP1: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '(ok|~) +codex' \
  && fail "caseP1: an always-overlay must NOT make an uninstalled lane read present: $ep"
grepq "$ep" -E 'XX +codex +MISCONFIGURED' \
  || fail "caseP1: forced-on-but-absent should read MISCONFIGURED: $ep"
grepq "$ep" -F "$CODEX_INSTALL_HINT" \
  || fail "caseP1: the install command must survive a bogus override: $ep"

# P2 — forced ON with the binary actually there: still present, and the detail
# must name the REAL reason, not the override ("registry probe kind=always").
sP2="$work/p2"; mkdir -p "$sP2"; hP2="$work/p2-home"; mkdir -p "$hP2"
fP2="$work/p2-fix"; pM_fix "$fP2" "$ALWAYS_OVERLAY"
plant_cli "$sP2" codex
capture "$sP2" "$hP2" "$fP2" --with-codex
ep=$(epilogue "$out")
grepq "$ep" -E '~ +codex +binary present' \
  || fail "caseP2: an always-overlay over a real binary should still read present: $ep"
grepq "$ep" 'codex found on PATH' \
  || fail "caseP2: the detail must cite physical presence, not the override: $ep"
grepq "$ep" 'kind=always' \
  && fail "caseP2: the override must never be the stated reason a lane is present: $ep"
echo "ok: caseP always-overlay cannot fake a binary; real presence still reported honestly"

# ── Case Q: guidance must be platform-correct, not just install commands ───
# CR round 7 [codex-adv-r6-2]. The install hints were platform-aware while the
# SETUP notes were bare strings, so a Linux adopter got a working install
# command followed by "run this .ps1" and a Windows-only runbook — able to
# install the binary, unable to finish. Renders the whole guidance surface
# (lane rows + summary + hardening) under forced linux/darwin and asserts no
# Windows leakage, then the converse for win32 so the fix cannot have simply
# deleted the PowerShell guidance. Driven through the library so no production
# platform-override seam has to exist just for a test.
fQ="$work/q-fix"; make_fixture "$fQ"
# shellcheck disable=SC2016
"$node_bin" -e '
const a = require(process.argv[1]);
const repoRoot = process.argv[2];
const ans = { role:"adopter", scope:"project", vault:{mode:"none",path:""},
              handover:{mode:"inline",path:""}, pluginSet:"lean",
              lanes:a.ALL_LANE_IDS, alwaysOn:true };
const render = (plat) => {
  const rows = a.probeSelection(a.ALL_LANE_IDS, { repoRoot, platform: plat, env: {} });
  return [].concat(
    rows.map((r) => [r.id, r.state, r.detail, r.hint, r.note].join(" | ")),
    a.summaryLines(a.buildSummary(ans, rows, { derived: "x", dryRun: true })),
    a.hardeningChecklistLines(plat)
  ).join("\n");
};
const WINDOWS_ONLY = [/\.ps1/, /%LOCALAPPDATA%/, /venv.Scripts/, /powershell/i, /winget/, /powercfg/];
for (const plat of ["linux", "darwin"]) {
  const text = render(plat);
  for (const re of WINDOWS_ONLY) {
    if (re.test(text)) { console.error(plat + " leaks Windows-only guidance " + re + "\n" + text); process.exit(1); }
  }
  for (const want of [/install-himmel-codex\.sh/, /install-himmel-profile\.sh/, /hermes-runbook\.md/]) {
    if (!want.test(text)) { console.error(plat + " is missing POSIX guidance " + want + "\n" + text); process.exit(1); }
  }
}
const win = render("win32");
// HIMMEL-2126: a printed note cannot run resolvePowershell() itself, so the
// codex/hermes win32 notes must say BOTH the pwsh preference AND that
// powershell.exe still works for that one step (verified: both .ps1 targets
// carry a UTF-8 BOM and no PS7-only syntax, so 5.1 genuinely tolerates them) —
// a stock clean-Windows box (no pwsh yet) must not be handed a dead command.
for (const want of [/install-himmel-codex\.ps1/, /install-himmel-profile\.ps1/, /winget install/, /powercfg/,
                     /pwsh\/PowerShell 7 preferred/, /powershell\.exe also works for this step/]) {
  if (!want.test(win)) { console.error("win32 lost its own guidance " + want + "\n" + win); process.exit(1); }
}
' "$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")" "$(winpath "$fQ")" \
  || fail "caseQ: lane guidance is not platform-correct"
echo "ok: caseQ POSIX platforms get POSIX guidance; win32 keeps its PowerShell guidance (pwsh preferred, powershell.exe fallback stated, HIMMEL-2126)"

# ── Case R: vault=default-template onto an OCCUPIED destination ────────────
# CR round 8 [codex-adv-r7-3]. adopt.sh's do_luna() skips the template copy
# whenever the destination EXISTS and continues with rc 0, so pointing
# default-template at an occupied unrelated directory quietly promoted that
# directory to "your vault" while the summary claimed it had been scaffolded.
# Unstamped -> refuse before any shell-out; stamped -> proceed but never claim
# scaffolding happened.
rVault_profile() {
  printf '{\n  "role": "adopter",\n  "tier": "standard",\n  "scope": "project",\n  "vault": { "mode": "default-template", "path": "%s" },\n  "handover": { "mode": "inline", "path": "" },\n  "pluginSet": "lean",\n  "lanes": [],\n  "lanesMeaningful": true,\n  "alwaysOn": false\n}\n' "$1"
}
sR="$work/r"; mkdir -p "$sR"; hR="$work/r-home"; mkdir -p "$hR"
fR="$work/r-fix"; make_fixture "$fR"
pR=$(build_path "$sR" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sR" "https://github.com/someone/other-repo.git"
# A sentinel adopt.sh: if the refusal leaks through to the shell-out, this
# fires and the assertion below catches it.
adopt_ran="$work/R-ADOPT-RAN"
cat > "$fR/scripts/adopt.sh" <<STUB
#!/usr/bin/env bash
printf 'ran\n' > "$adopt_ran"
exit 0
STUB
chmod +x "$fR/scripts/adopt.sh"

# R1 — occupied and UNSTAMPED: refuse, nonzero, and adopt.sh must NOT run.
occR="$work/r-occupied"; mkdir -p "$occR"; printf 'unrelated\n' > "$occR/README.md"
profR="$work/r-profile.json"; rVault_profile "$(winpath "$occR")" > "$profR"
set +e
out=$(PATH="$pR" HOME="$hR" USERPROFILE="$(winpath "$hR")" HIMMELCTL_CACHE_DIR="$(winpath "$hR.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hR.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fR")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profR")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseR1: an occupied UNSTAMPED vault destination must exit nonzero: $out"
grepq "$out" 'refusing to adopt' \
  || fail "caseR1: the refusal should say so plainly: $out"
grepq "$out" 'no luna-second-brain stamp' \
  || fail "caseR1: the refusal should name the missing stamp: $out"
[ -f "$adopt_ran" ] \
  && fail "caseR1: adopt.sh must NOT run when the destination is refused: $out"
grepq "$out" 'scaffolded' \
  && fail "caseR1: a refused run must never claim scaffolding: $out"

# R2 — occupied but STAMPED: proceed, and report reuse rather than scaffolding.
printf '{ "template": "luna-second-brain" }\n' > "$occR/.vault-template.json"
set +e
out=$(PATH="$pR" HOME="$hR" USERPROFILE="$(winpath "$hR")" HIMMELCTL_CACHE_DIR="$(winpath "$hR.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hR.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fR")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profR")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseR2: a STAMPED existing vault should succeed (got rc=$rc): $out"
[ -f "$adopt_ran" ] || fail "caseR2: adopt.sh should have run for a stamped vault: $out"
grepq "$out" 'scaffolded' \
  && fail "caseR2: nothing was copied, so nothing may claim it was scaffolded: $out"
grepq "$out" 'no scaffolding ran' \
  || fail "caseR2: the summary should say the existing vault was reused: $out"
# R3 — the PREVIEW must agree with the applied run. CR round 10 [glm-r9-3]
# asked whether a dry-run could still claim "would scaffold" for a stamped
# destination adopt.sh would actually reuse; it cannot (the occupied-vault
# evaluation sits ahead of every epilogue call on the default-template path),
# but only the applied path was pinned. Both previews are asserted here.
rm -f "$adopt_ran"
for _mode in flag interactive; do
  set +e
  if [ "$_mode" = flag ]; then
    out=$(PATH="$pR" HOME="$hR" USERPROFILE="$(winpath "$hR")" HIMMELCTL_CACHE_DIR="$(winpath "$hR.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hR.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
          HIMMELCTL_REPO_ROOT="$(winpath "$fR")" \
          "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profR")" \
          </dev/null 2>&1)
  else
    out=$(printf 'starter\nproject\ndefault-template\n%s\ninline\nlean\nnone\nno\n' "$(winpath "$occR")" \
      | PATH="$pR" HOME="$hR" USERPROFILE="$(winpath "$hR")" HIMMELCTL_INTERACTIVE=1 \
        HIMMELCTL_CACHE_DIR="$(winpath "$work/r3-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/r3-cache")-luna-config.json" \
        HIMMELCTL_REPO_ROOT="$(winpath "$fR")" \
        "$node_bin" "$wizard" install --dry-run 2>&1)
  fi
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "caseR3/$_mode: dry-run should succeed (got rc=$rc): $out"
  grepq "$out" 'would scaffold' \
    && fail "caseR3/$_mode: a preview must not claim a scaffold adopt.sh would skip: $out"
  grepq "$out" 'no scaffolding ran' \
    || fail "caseR3/$_mode: the preview should say the stamped vault is reused: $out"
  [ -f "$adopt_ran" ] \
    && fail "caseR3/$_mode: --dry-run must not run adopt.sh at all: $out"
done
echo "ok: caseR occupied vault destination -> unstamped refused, stamped reused (applied AND both previews)"

# ── Case S: the planned bucket is conditional-tense throughout ──────────────
# CR round 8 [glm-r7-2]: the plugin row said "would be enabled" while the
# vault/handover rows stayed past-tense, so one preview mixed both and half of
# it read like completed work.
# shellcheck disable=SC2016
"$node_bin" -e '
const a = require(process.argv[1]);
const ans = { role:"adopter", scope:"project", vault:{mode:"default-template",path:"/v"},
              handover:{mode:"external",path:"/h"}, pluginSet:"full", lanes:[], alwaysOn:false };
const planned = a.buildSummary(ans, [], { derived:"X", dryRun:true }).planned.join("\n");
for (const past of [/ scaffolded /, / upgraded in place/, /-> \/h \(HANDOVER_DIR\)/, / via X/]) {
  if (past.test(planned)) { console.error("dry-run planned bucket uses past tense " + past + "\n" + planned); process.exit(1); }
}
// HIMMEL-2304: pluginSet=full used to contribute a 4th conditional-tense row
// ("full plugin set (would be enabled)") — that branch is retired now (it
// lands in `skipped`, not `planned`, regardless of dryRun), so only the top
// summary line + vault + handover stay conditional here: 3, not 4.
const n = planned.split("\n").filter((l) => /would/.test(l)).length;
if (n !== 3) { console.error("expected all 3 planned rows conditional, got " + n + "\n" + planned); process.exit(1); }
const done = a.buildSummary(ans, [], { derived:"X", dryRun:false, pluginFailures:[], pluginTotal:2 }).installed.join("\n");
if (/would/.test(done)) { console.error("applied bucket leaked conditional tense\n" + done); process.exit(1); }
' "$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")" \
  || fail "caseS: summary tense is not consistent with the bucket"
echo "ok: caseS planned bucket is conditional throughout; applied bucket is not"

# ── Case T: a degenerate overlay probe must fail closed, like the resolver ──
# CR round 9 [codex-adv-r8-1]. evalProbe returns FALSE for a null/non-object/
# empty-kind/unknown-kind probe, so such an overlay entry EXCLUDES the lane
# from /lanes. This used to fall back to the base probe (or to enabled=true)
# and report the lane present with nothing to do. Each shape is asserted
# against resolveLanes itself, so the two can never drift apart again.
for _probe in 'null' '{}' '{"kind":""}' '{"kind":"future-thing"}'; do
  sT="$work/t-$(printf '%s' "$_probe" | tr -cd '[:lower:]')"; mkdir -p "$sT"
  hT="$sT-home"; mkdir -p "$hT"
  fT="$sT-fix"; make_fixture "$fT"
  # HIMMEL-2352: codex is the vehicle (see the CODEX_INSTALL_HINT comment
  # above) — this loop drives the wizard's own epilogue, and ollama-local is
  # dormant-in-v1 there, so codex-exec exercises the identical overlay path.
  printf '{ "lanes": [ { "id": "codex-exec", "probe": %s } ] }\n' "$_probe" \
    > "$fT/scripts/lanes/lanes.local.json"
  # Plant the binary: physical presence is real, so only the overlay handling
  # can be what keeps the lane from reading present.
  plant_cli "$sT" codex
  capture "$sT" "$hT" "$fT" --with-codex
  [ "$rc" -eq 0 ] || fail "caseT[$_probe]: run should succeed (got rc=$rc): $out"
  ep=$(epilogue "$out")
  grepq "$ep" -E '(ok|~) +codex' \
    && fail "caseT[$_probe]: a degenerate overlay probe must NOT read present: $ep"
  grepq "$ep" 'lanes.local.json' \
    || fail "caseT[$_probe]: the reason should name the overlay: $ep"
done

# ...and the consistency claim itself, checked against the real resolver.
# shellcheck disable=SC2016
"$node_bin" -e '
(async () => {
  const { pathToFileURL } = require("url");
  const m = await import(pathToFileURL(process.argv[1]).href);
  const base = { lanes: [ { id: "ollama-local", probe: { kind: "path", cli: "ollama" } } ] };
  const ctx = { env: {}, pathHas: () => true, installed: {} };  // pretend the binary IS there
  // Sanity: with no overlay the lane DOES resolve, so an exclusion below can
  // only come from the degenerate overlay probe.
  if (!m.resolveLanes(base, ctx).map((l) => l.id).includes("ollama-local")) {
    console.error("baseline: lane should resolve with no overlay"); process.exit(1);
  }
  for (const probe of [null, undefined, {}, { kind: "" }, { kind: "future-thing" }]) {
    const merged = m.mergeLocalOverlay(base, { lanes: [ { id: "ollama-local", probe } ] });
    if (m.resolveLanes(merged, ctx).map((l) => l.id).includes("ollama-local")) {
      console.error("resolver INCLUDED a degenerate-probe lane: " + JSON.stringify(probe));
      process.exit(1);
    }
  }
})().catch((e) => { console.error(e && e.message ? e.message : e); process.exit(1); });
' "$(winpath "$repo_root/scripts/lanes/resolve.mjs")" \
  || fail "caseT: resolveLanes no longer excludes degenerate-probe lanes — the premise moved"
echo "ok: caseT degenerate overlay probes fail closed, consistent with resolveLanes"

# ── Case U: overlay remediation must not drop the setup note ────────────────
# CR round 9 [codex-adv-r8-2]. Round 7 guaranteed a lane's platform-specific
# setup step survives into `still manual`; the disabled/misconfigured branches
# were dropping it, so a disabled lane showed only the re-enable command and a
# forced-on absent lane only install+override repair.
# HIMMEL-2352: codex is the vehicle for BOTH halves (see the
# CODEX_INSTALL_HINT comment above) — hermes's probe is kind=installed, which
# the shared capture()/run_install() helper has no seam for (see caseK's own
# comment: it needs HERMES_HOME/HERMES_PY threaded through a dedicated
# function), so it cannot be forced ABSENT hermetically through capture() the
# way U2 needs. codex's path-probe is fully controlled by the scrubbed PATH
# capture() already builds, so it stays the reliable vehicle for both halves.
# U1 — DISABLED codex keeps its post-install auth-setup step, AFTER the
# re-enable.
sU1="$work/u1"; mkdir -p "$sU1"; hU1="$work/u1-home"; mkdir -p "$hU1"
fU1="$work/u1-fix"; make_fixture "$fU1"
printf '{ "lanes": [ { "id": "codex-exec", "probe": { "kind": "never" } } ] }\n' \
  > "$fU1/scripts/lanes/lanes.local.json"
plant_cli "$sU1" codex
capture "$sU1" "$hU1" "$fU1" --with-codex
ep=$(epilogue "$out")
grepq "$ep" 'config set lanes.codex-exec on' \
  || fail "caseU1: the re-enable command must still be present: $ep"
grepq "$ep" 'install-himmel-codex.sh' \
  || fail "caseU1: a DISABLED lane must keep its setup step: $ep"
# Ordering: remediation before the setup step it unblocks.
remediation_line=$(printf '%s' "$ep" | grep -n 'config set lanes.codex-exec on' | head -1 | cut -d: -f1)
setup_line=$(printf '%s' "$ep" | grep -n 'install-himmel-codex.sh' | tail -1 | cut -d: -f1)
[ "$remediation_line" -lt "$setup_line" ] \
  || fail "caseU1: remediation should come BEFORE the setup step: $ep"

# U2 — forced-on-but-ABSENT codex keeps its auth-setup step.
sU2="$work/u2"; mkdir -p "$sU2"; hU2="$work/u2-home"; mkdir -p "$hU2"
fU2="$work/u2-fix"; make_fixture "$fU2"
printf '{ "lanes": [ { "id": "codex-exec", "probe": { "kind": "always" } } ] }\n' \
  > "$fU2/scripts/lanes/lanes.local.json"
capture "$sU2" "$hU2" "$fU2" --with-codex
ep=$(epilogue "$out")
grepq "$ep" -E 'XX +codex +MISCONFIGURED' \
  || fail "caseU2: forced-on-but-absent should read MISCONFIGURED: $ep"
grepq "$ep" -F "$CODEX_INSTALL_HINT" \
  || fail "caseU2: the install command must survive: $ep"
grepq "$ep" 'install-himmel-codex.sh' \
  || fail "caseU2: a MISCONFIGURED lane must keep its setup step: $ep"
echo "ok: caseU overlay remediation preserves the setup note, ordered after the fix"

# ── Case V: ABSENT *and* overlay-disabled — the last cell of the matrix ────
# CR round 11 [codex-r10-1]. Installing the CLI does NOT make the lane usable
# while lanes.local.json still turns it off: /lanes keeps excluding it, so an
# adopter who followed the one instruction we gave got nothing. Both steps
# must be listed, install first, then the re-enable, then the setup step.
# HIMMEL-2352: codex is the vehicle (see the CODEX_INSTALL_HINT comment
# above); the previous absent+disabled cell is the same probeLane branch
# whichever v1 lane exercises it.
sV="$work/v"; mkdir -p "$sV"; hV="$work/v-home"; mkdir -p "$hV"
fV="$work/v-fix"; make_fixture "$fV"
printf '{ "lanes": [ { "id": "codex-exec", "probe": { "kind": "never" } } ] }\n' \
  > "$fV/scripts/lanes/lanes.local.json"
# NOTE: no plant_cli here — the lane is absent AND disabled, the whole point.
capture "$sV" "$hV" "$fV" --with-codex
[ "$rc" -eq 0 ] || fail "caseV: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -F "$CODEX_INSTALL_HINT" \
  || fail "caseV: the install command must be listed: $ep"
grepq "$ep" 'config set lanes.codex-exec on' \
  || fail "caseV: the overlay re-enable must ALSO be listed: $ep"
grepq "$ep" 'install-himmel-codex.sh' \
  || fail "caseV: the setup step must survive here too: $ep"
grepq "$ep" 'DISABLED by scripts/lanes/lanes.local.json' \
  || fail "caseV: the row should say the overlay also blocks it: $ep"
# Ordering: install, then re-enable, then setup.
i_install=$(printf '%s' "$ep" | grep -nF "$CODEX_INSTALL_HINT" | head -1 | cut -d: -f1)
i_enable=$(printf '%s' "$ep" | grep -n 'config set lanes.codex-exec on' | head -1 | cut -d: -f1)
i_setup=$(printf '%s' "$ep" | grep -n 'install-himmel-codex.sh' | head -1 | cut -d: -f1)
{ [ "$i_install" -lt "$i_enable" ] && [ "$i_enable" -lt "$i_setup" ]; } \
  || fail "caseV: steps must read install -> re-enable -> setup (got $i_install/$i_enable/$i_setup): $ep"
echo "ok: caseV absent+disabled lists install, overlay re-enable, and setup in order"

# ── Case W: EVALUABLE_PROBE_KINDS must not drift from probe.mjs ────────────
# CR round 11 [glm-r10-3]. The constant hand-tracks evalProbe's switch and
# probe.mjs exports no equivalent set, so a kind added there would silently
# start reporting UNKNOWN here. Compare the two directly.
# shellcheck disable=SC2016
"$node_bin" -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
// evalProbe is one switch over string literals; `default:` is the fail-closed
// arm and carries no label, so the case labels ARE the decidable set.
const fromSource = [...src.matchAll(/case\s+"([a-z]+)":|case\s+.([a-z]+).:/g)]
  .map((m) => m[1] || m[2]).filter(Boolean).sort();
const declared = [...require(process.argv[1]).EVALUABLE_PROBE_KINDS].sort();
if (fromSource.length === 0) {
  console.error("drift test found no case labels in probe.mjs — the parse assumption moved");
  process.exit(1);
}
if (fromSource.join(",") !== declared.join(",")) {
  console.error("EVALUABLE_PROBE_KINDS has drifted from probe.mjs\n  probe.mjs: " +
    fromSource.join(",") + "\n  declared : " + declared.join(","));
  process.exit(1);
}
' "$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")" \
  "$(winpath "$repo_root/scripts/lanes/probe.mjs")" \
  || fail "caseW: EVALUABLE_PROBE_KINDS no longer matches probe.mjs"
echo "ok: caseW EVALUABLE_PROBE_KINDS matches evalProbe's decidable kinds"

# ── Case X: the vault gate is re-checked immediately BEFORE the spawn ──────
# CR round 11 [codex-adv-r10-2]. The first gate runs before the plan print,
# the confirm and the handover write, so the destination can appear in the
# meantime. Exercised deterministically rather than by racing: point
# handover.mode=external at the SAME path as the vault, so applyHandoverStep
# mkdir's it in the real mid-window — between the two checks — exactly the
# class of change the re-check exists to catch.
sX="$work/x"; mkdir -p "$sX"; hX="$work/x-home"; mkdir -p "$hX"
fX="$work/x-fix"; make_fixture "$fX"
adopt_ran_x="$work/X-ADOPT-RAN"
cat > "$fX/scripts/adopt.sh" <<STUB
#!/usr/bin/env bash
printf 'ran\n' > "$adopt_ran_x"
exit 0
STUB
chmod +x "$fX/scripts/adopt.sh"
# set-handover-dir.sh must exist for applyHandoverStep to succeed.
mkdir -p "$fX/scripts/handover"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fX/scripts/handover/set-handover-dir.sh"
chmod +x "$fX/scripts/handover/set-handover-dir.sh"
raceX="$work/x-vault-appears"          # deliberately does NOT exist yet
profX="$work/x-profile.json"
printf '{\n  "role": "adopter",\n  "tier": "standard",\n  "scope": "project",\n  "vault": { "mode": "default-template", "path": "%s" },\n  "handover": { "mode": "external", "path": "%s" },\n  "pluginSet": "lean",\n  "lanes": [],\n  "lanesMeaningful": true,\n  "alwaysOn": false\n}\n' \
  "$(winpath "$raceX")" "$(winpath "$raceX")" > "$profX"
pX=$(build_path "$sX" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sX" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pX" HOME="$hX" USERPROFILE="$(winpath "$hX")" HIMMELCTL_CACHE_DIR="$(winpath "$hX.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hX.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fX")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profX")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] \
  || fail "caseX: a destination that appeared mid-window must abort (got rc=$rc): $out"
grepq "$out" 'since the preflight check' \
  || fail "caseX: the abort should say the destination changed after the first check: $out"
[ -f "$adopt_ran_x" ] \
  && fail "caseX: adopt.sh must NOT run once the re-check refuses: $out"
grepq "$out" 'scaffolded' \
  && fail "caseX: a refused run must never claim scaffolding: $out"
echo "ok: caseX the occupied-vault gate is re-evaluated immediately before the spawn"

# ── Case Y: LANES_REGISTRY replaces the registry AND skips the overlay ──────
# CR round 11 [codex-adv-r10-3]. resolve.mjs treats LANES_REGISTRY as a
# wholesale replacement and does NOT layer lanes.local.json on top of it, so
# reading checkout-default + overlay under the override made this report a
# different lane set than /lanes resolved.
# HIMMEL-2352: codex is the vehicle (see the CODEX_INSTALL_HINT comment
# above) — this case drives the wizard's own epilogue.
sY="$work/y"; mkdir -p "$sY"; hY="$work/y-home"; mkdir -p "$hY"
fY="$work/y-fix"; make_fixture "$fY"
# An overlay that would DISABLE codex if it were consulted.
printf '{ "lanes": [ { "id": "codex-exec", "probe": { "kind": "never" } } ] }\n' \
  > "$fY/scripts/lanes/lanes.local.json"
altY="$work/y-registry.json"
printf '{ "lanes": [ { "id": "codex-exec", "probe": { "kind": "path", "cli": "codex" } } ] }\n' > "$altY"
plant_cli "$sY" codex
pY=$(build_path "$sY" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sY" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pY" HOME="$hY" USERPROFILE="$(winpath "$hY")" HIMMELCTL_CACHE_DIR="$(winpath "$hY.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hY.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      LANES_REGISTRY="$(winpath "$altY")" \
      HIMMELCTL_REPO_ROOT="$(winpath "$fY")" \
      "$node_bin" "$wizard" install --dry-run --with-codex </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseY: dry-run under LANES_REGISTRY should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '~ +codex +binary present' \
  || fail "caseY: under LANES_REGISTRY the overlay must be IGNORED: $ep"
grepq "$ep" 'DISABLED' \
  && fail "caseY: the skipped overlay must not still disable the lane: $ep"
# Control: the SAME fixture WITHOUT the override does honour the overlay.
set +e
out=$(PATH="$pY" HOME="$hY" USERPROFILE="$(winpath "$hY")" HIMMELCTL_CACHE_DIR="$(winpath "$hY.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hY.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fY")" \
      "$node_bin" "$wizard" install --dry-run --with-codex </dev/null 2>&1)
set -e
grepq "$(epilogue "$out")" 'DISABLED' \
  || fail "caseY: without the override the overlay must still apply: $(epilogue "$out")"
echo "ok: caseY LANES_REGISTRY replaces the registry and skips the overlay, like the resolver"

# ── Case Z: applied selections constrain only the wizard-owned lane subset ──
# Every optional probe the fixture can satisfy is made true below. That makes
# suppression observable while also proving registry lanes outside the persisted
# wizard scope remain on their base probes.
# HIMMEL-2352: PROFILE_LANE_REGISTRY_IDS (the wizard-owned scope the real
# code persists) is now V1_LANES.map(registryId) = just codex-exec and
# hermes-oneshot — ollama-local/copilot-cli dropped out of V1_LANES entirely,
# so they are no longer part of the persisted scope either.
profile_scope='codex-exec,hermes-oneshot'
for _combo in none codex hermes both; do
  sZ="$work/z-$_combo"; mkdir -p "$sZ"; hZ="$work/z-$_combo-home"; mkdir -p "$hZ"
  fZ="$work/z-$_combo-fix"; make_fixture "$fZ"
  profZ="$work/z-$_combo-profile.json"
  case "$_combo" in
    none)    _profile_lanes='[]'; _expected='' ;;
    codex)   _profile_lanes='["codex"]'; _expected='codex-exec' ;;
    hermes)  _profile_lanes='["hermes"]'; _expected='hermes-oneshot' ;;
    both)    _profile_lanes='["codex","hermes"]'; _expected='codex-exec,hermes-oneshot' ;;
  esac
  printf '{\n  "role": "adopter",\n  "tier": "standard",\n  "scope": "project",\n  "vault": { "mode": "none", "path": "" },\n  "handover": { "mode": "inline", "path": "" },\n  "pluginSet": "lean",\n  "lanes": %s,\n  "lanesMeaningful": true,\n  "alwaysOn": false\n}\n' \
    "$_profile_lanes" > "$profZ"
  pZ=$(build_path "$sZ" bash jq python3 npm -- "${LANE_TOOLS[@]}")
  make_git_stub "$sZ" "https://github.com/someone/other-repo.git"
  set +e
  out=$(PATH="$pZ" HOME="$hZ" USERPROFILE="$(winpath "$hZ")" HIMMELCTL_CACHE_DIR="$(winpath "$hZ.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hZ.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
        HIMMELCTL_REPO_ROOT="$(winpath "$fZ")" \
        "$node_bin" "$wizard" install --from-profile "$(winpath "$profZ")" \
        </dev/null 2>&1); rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "caseZ/$_combo: applied install should succeed (got rc=$rc): $out"
  [ -f "$fZ/scripts/lanes/lanes.local.json" ] \
    || fail "caseZ/$_combo: applied install did not write lanes.local.json"
  # shellcheck disable=SC2016
  "$node_bin" -e '
  (async () => {
    const fs = require("fs");
    const path = require("path");
    const { pathToFileURL } = require("url");
    const root = process.argv[1];
    const expected = process.argv[2] ? process.argv[2].split(",") : [];
    const m = await import(pathToFileURL(process.argv[3]).href);
    const scope = process.argv[4].split(",");
    const base = JSON.parse(fs.readFileSync(path.join(root, "scripts", "lanes", "lanes.json"), "utf8"));
    const local = JSON.parse(fs.readFileSync(path.join(root, "scripts", "lanes", "lanes.local.json"), "utf8"));
    if (JSON.stringify(local.profileAllowlist) !== JSON.stringify(expected)) {
      throw new Error("persisted allowlist mismatch: " + JSON.stringify(local.profileAllowlist) + " != " + JSON.stringify(expected));
    }
    if (JSON.stringify(local.profileAllowlistScope) !== JSON.stringify(scope)) {
      throw new Error("persisted allowlist scope mismatch: " + JSON.stringify(local.profileAllowlistScope) + " != " + JSON.stringify(scope));
    }
    const merged = m.mergeLocalOverlay(base, local);
    const ctx = {
      env: { ZAI_API_KEY: "k", CLIPROXY_API_KEY: "k", OPENROUTER_API_KEY: "k", CR_PROFILE: "paid" },
      pathHas: () => true,
      installed: { hermes: true },
    };
    const optionalIds = (registry) => m.resolveLanes(registry, ctx)
      .filter((lane) => lane.class !== "claude-tier").map((lane) => lane.id).sort();
    const baseAvailable = optionalIds(base);
    const effective = optionalIds(merged);
    const effectiveInScope = effective.filter((id) => scope.includes(id));
    const want = [...expected].sort();
    if (JSON.stringify(effectiveInScope) !== JSON.stringify(want)) {
      throw new Error("effective wizard-owned inventory mismatch: " + JSON.stringify(effectiveInScope) + " != " + JSON.stringify(want));
    }
    const outsideScope = baseAvailable.filter((id) => !scope.includes(id));
    const missingOutside = outsideScope.filter((id) => !effective.includes(id));
    if (missingOutside.length > 0) {
      throw new Error("out-of-scope registry lanes were suppressed: " + JSON.stringify(missingOutside));
    }
    const suppressed = m.resolveLaneInventory(merged, ctx)
      .filter((row) => row.suppressedByProfile).map((row) => row.lane.id);
    if (suppressed.some((id) => !scope.includes(id))) {
      throw new Error("out-of-scope lane reported suppressed-by-profile: " + JSON.stringify(suppressed));
    }
    if (suppressed.some((id) => expected.includes(id))) {
      throw new Error("allowlisted lane reported suppressed: " + JSON.stringify(suppressed));
    }
  })().catch((e) => { console.error(e && e.message ? e.message : e); process.exit(1); });
  ' "$(winpath "$fZ")" "$_expected" "$(winpath "$repo_root/scripts/lanes/resolve.mjs")" "$profile_scope" \
    || fail "caseZ/$_combo: persisted profile did not produce the expected resolver inventory"
done
echo "ok: caseZ applied profiles constrain only the wizard-owned subset; all other registry lanes stay on base probes"

# ── Case AA: LANES_REGISTRY makes overlay persistence fail loudly ───────────
sAA="$work/aa"; mkdir -p "$sAA"; hAA="$work/aa-home"; mkdir -p "$hAA"
fAA="$work/aa-fix"; make_fixture "$fAA"
mutationAA="$work/aa-core-install-ran"
cat > "$fAA/scripts/adopt.sh" <<STUB
#!/usr/bin/env bash
printf 'ran\n' > "$mutationAA"
exit 0
STUB
chmod +x "$fAA/scripts/adopt.sh"
profAA="$work/aa-profile.json"
cat > "$profAA" <<'JSON'
{
  "role": "adopter",
  "tier": "standard",
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": ["codex"],
  "alwaysOn": false
}
JSON
pAA=$(build_path "$sAA" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sAA" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pAA" HOME="$hAA" USERPROFILE="$(winpath "$hAA")" HIMMELCTL_CACHE_DIR="$(winpath "$hAA.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hAA.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      LANES_REGISTRY="$(winpath "$fAA/scripts/lanes/lanes.json")" \
      HIMMELCTL_REPO_ROOT="$(winpath "$fAA")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profAA")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] \
  || fail "caseAA: applied install under LANES_REGISTRY must fail instead of reporting ignored persistence: $out"
grepq "$out" 'LANES_REGISTRY is set' \
  || fail "caseAA: failure must name the active registry override: $out"
grepq "$out" 'ignores lanes.local.json' \
  || fail "caseAA: failure must explain why persistence cannot bind: $out"
grepq "$out" 'lane profile: allowlisted' \
  && fail "caseAA: ignored persistence must never print a success line: $out"
grepq "$out" 'lane profile preflight failed' \
  || fail "caseAA: LANES_REGISTRY must fail in the pre-install validation phase: $out"
[ -f "$mutationAA" ] \
  && fail "caseAA: LANES_REGISTRY preflight must abort before adopt.sh mutates anything"
[ -f "$fAA/scripts/lanes/lanes.local.json" ] \
  && fail "caseAA: refusal should happen before writing an overlay the resolver ignores"
echo "ok: caseAA LANES_REGISTRY aborts in preflight before the core installer or overlay write"

# ── Case AB: unwritable overlay dir aborts T5b before any mutation ───────────
sAB="$work/ab"; mkdir -p "$sAB"; hAB="$work/ab-home"; mkdir -p "$hAB"
fAB="$work/ab-fix"; make_fixture "$fAB"
vaultAB="$work/ab-vault"; mkdir -p "$vaultAB"
printf '{ "template": "luna-second-brain" }\n' > "$vaultAB/.vault-template.json"
handoverAB="$work/ab-handover"
profAB="$work/ab-profile.json"
printf '{\n  "role": "adopter",\n  "tier": "standard",\n  "scope": "user",\n  "vault": { "mode": "existing", "path": "%s" },\n  "handover": { "mode": "external", "path": "%s" },\n  "pluginSet": "lean",\n  "lanes": [],\n  "lanesMeaningful": true,\n  "alwaysOn": false\n}\n' \
  "$(winpath "$vaultAB")" "$(winpath "$handoverAB")" > "$profAB"
denyAB="$work/deny-lane-overlay-write.js"
cat > "$denyAB" <<'JS'
const fs = require('fs');
const path = require('path');
const realAccessSync = fs.accessSync;
fs.accessSync = function (p, mode) {
  if (path.resolve(String(p)) === path.resolve(process.env.DENY_LANE_OVERLAY_DIR)) {
    const err = new Error('simulated permission denied');
    err.code = 'EACCES';
    throw err;
  }
  return realAccessSync.call(fs, p, mode);
};
require('module').syncBuiltinESMExports();
JS
pAB=$(build_path "$sAB" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sAB" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pAB" HOME="$hAB" USERPROFILE="$(winpath "$hAB")" HIMMELCTL_CACHE_DIR="$(winpath "$hAB.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hAB.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fAB")" \
      DENY_LANE_OVERLAY_DIR="$(winpath "$fAB/scripts/lanes")" \
      NODE_OPTIONS="--require=$(winpath "$denyAB")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profAB")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseAB: unwritable lane overlay dir must fail before T5b mutation: $out"
grepq "$out" 'overlay target is not writable' \
  || fail "caseAB: failure must name the unwritable overlay target: $out"
grepq "$out" 'EACCES' \
  || fail "caseAB: failure must surface the permission code: $out"
grepq "$out" 'lane profile preflight failed' \
  || fail "caseAB: unwritable target must fail in the pre-install validation phase: $out"
[ -e "$handoverAB" ] \
  && fail "caseAB: T5b preflight must abort before applyHandoverStep creates the external handover dir"
[ -f "$fAB/.env" ] \
  && fail "caseAB: T5b preflight must abort before applyHandoverStep writes HANDOVER_DIR"
echo "ok: caseAB unwritable overlay dir aborts T5b before handover, wire or upgrade mutation"

# ── Case AC (HIMMEL-2305): resolveActiveFeatures() — the ONE selection ->
# feature mapping shared by the secrets walk (bin.js's runSecretsWalk) and
# status-report.js's n/a downgrades. Pure unit test against the function
# directly, mirroring caseJ's buildSummary-model style above.
#   - a genuinely missing `answers` (not just an empty object) fails OPEN:
#     null, never a fabricated empty Set — callers must keep full-nag/
#     full-walk behavior rather than silently scoping everything out.
#   - vault/cadence/bridge+whisper/lane:codex/lane:hermes each flip on only
#     when the recorded answer says so; an absent section (never asked)
#     reads OFF, same round-8 "not asked ≠ answered off, but still OFF for
#     scoping" rule every other luna/secretsWalk/bridge section follows.
#   - legacy `luna.cadenceEnabled` (pre-HIMMEL-2302, no top-level `cadences`)
#     still flips 'cadence' on via resolveCadenceDispositions' own fallback.
#   - 'core' is always on for any real answers object.
# shellcheck disable=SC2016
"$node_bin" -e '
const a = require(process.argv[1]);
const fail = (m) => { console.error(m); process.exit(1); };

if (a.resolveActiveFeatures(undefined) !== null) fail("undefined answers should fail open (null), not a Set");
if (a.resolveActiveFeatures(null) !== null) fail("null answers should fail open (null), not a Set");

const bare = { scope: "project", vault: { mode: "none", path: "" }, lanes: [] };
const bareFeatures = a.resolveActiveFeatures(bare);
if (!(bareFeatures instanceof Set)) fail("a real (even minimal) answers object must return a Set, not null");
if (!bareFeatures.has("core")) fail("core must always be on");
if (bareFeatures.has("vault")) fail("vault=none must not turn on the vault feature");
if (bareFeatures.has("cadence")) fail("no cadences section (never asked) must not turn on the cadence feature");
if (bareFeatures.has("bridge") || bareFeatures.has("whisper")) fail("no bridge section (never asked) must not turn on bridge/whisper");
if (bareFeatures.has("lane:codex") || bareFeatures.has("lane:hermes")) fail("empty lanes must not turn on either lane feature");

const vaultOn = a.resolveActiveFeatures(Object.assign({}, bare, { vault: { mode: "default-template", path: "/v" } }));
if (!vaultOn.has("vault")) fail("vault.mode!=none must turn on the vault feature");

const cadenceOn = a.resolveActiveFeatures(Object.assign({}, bare, { cadences: { pipeline: "armed" } }));
if (!cadenceOn.has("cadence")) fail("any armed cadence must turn on the cadence feature");
const cadenceOff = a.resolveActiveFeatures(Object.assign({}, bare, { cadences: { pipeline: "off" } }));
if (cadenceOff.has("cadence")) fail("an explicitly-off cadence disposition must not turn on the cadence feature");
const cadenceLegacy = a.resolveActiveFeatures(Object.assign({}, bare, { luna: { cadenceEnabled: true } }));
if (!cadenceLegacy.has("cadence")) fail("legacy luna.cadenceEnabled=true must still turn on the cadence feature");

const bridgeOn = a.resolveActiveFeatures(Object.assign({}, bare, { bridge: { enabled: true } }));
if (!bridgeOn.has("bridge")) fail("bridge.enabled=true must turn on the bridge feature");
if (!bridgeOn.has("whisper")) fail("bridge.enabled=true must ALSO turn on the whisper feature");
const bridgeOff = a.resolveActiveFeatures(Object.assign({}, bare, { bridge: { enabled: false } }));
if (bridgeOff.has("bridge") || bridgeOff.has("whisper")) fail("bridge.enabled=false must not turn on bridge/whisper");

const codexOn = a.resolveActiveFeatures(Object.assign({}, bare, { lanes: ["codex"] }));
if (!codexOn.has("lane:codex")) fail("lanes containing codex must turn on lane:codex");
if (codexOn.has("lane:hermes")) fail("selecting codex must not also turn on lane:hermes");
const hermesOn = a.resolveActiveFeatures(Object.assign({}, bare, { lanes: ["hermes"] }));
if (!hermesOn.has("lane:hermes")) fail("lanes containing hermes must turn on lane:hermes");
' "$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")" \
  || fail "caseAC: resolveActiveFeatures() selection->feature mapping is wrong"
echo "ok: caseAC resolveActiveFeatures() fails open on a missing answers object and maps vault/cadence/bridge+whisper/lanes correctly otherwise"

# ── Case AD (HIMMEL-2536): the git gate hooks are reported from DISK ────────
# The measured 2457 failure: on a stock guest with neither uv nor pipx,
# adopt.sh warns and SKIPS placing the hooks, a garbage commit message then
# lands rc=0, and the install summary's `still manual` section prints
# `(nothing)` in the very same run. Two halves are pinned here.
#
# AD1 — the renderer: buildSummary must carry a still-manual row when, and
# only when, the probe says hooks are genuinely missing. A --dry-run (null,
# nothing ran) and a non-repo target (applicable:false, adopt.sh skips it by
# design) must both stay silent — a preview that claims a probe it never
# performed is the same class of lie this section exists to refuse.
# shellcheck disable=SC2016
"$node_bin" -e '
const a = require(process.argv[1]);
const fail = (m) => { console.error(m); process.exit(1); };
const ans = { role:"adopter", scope:"project", vault:{mode:"none",path:""},
              handover:{mode:"inline",path:""}, pluginSet:"lean", lanes:[], alwaysOn:false };
const manualText = (s) => s.manual.map((m) => [m.what, m.how, m.note].join(" ")).join("\n");

const missing = a.buildSummary(ans, [], { derived:"x", dryRun:false,
  gitHooks: { applicable:true, verified:true, placed:false, missing:["pre-commit","commit-msg","pre-push"] } });
const mt = manualText(missing);
if (!/git gate hooks/.test(mt)) fail("missing hooks produced no still-manual row");
if (!/commit-msg/.test(mt)) fail("the row must NAME the hooks that are missing");
if (!/NOT gated/.test(mt)) fail("the row must state the consequence, not just the fact");
if (!/re-run/.test(mt)) fail("the row must carry a remedy, not just a defect report");

const placed = a.buildSummary(ans, [], { derived:"x", dryRun:false,
  gitHooks: { applicable:true, verified:true, placed:true, missing:[] } });
if (/git gate hooks/.test(manualText(placed))) fail("hooks that ARE placed must produce no still-manual row");

// CR round 1 [codex-2]: a probe that could not run is its own row, and it must
// not be silently folded into either of the two states above.
const unverified = a.buildSummary(ans, [], { derived:"x", dryRun:false,
  gitHooks: { applicable:true, verified:false, reason:"git rev-parse --git-path hooks failed" } });
const ut = manualText(unverified);
if (!/could NOT be verified/.test(ut)) fail("an unverifiable hooks probe produced no still-manual row");
if (!/possibly ungated/.test(ut)) fail("the unverifiable row must not read as reassurance");
if (/NOT placed/.test(ut)) fail("an unverifiable probe must not be reported as a known-missing gate");

const nonRepo = a.buildSummary(ans, [], { derived:"x", dryRun:false,
  gitHooks: { applicable:false } });
if (/git gate hooks/.test(manualText(nonRepo))) fail("a non-git target must produce no still-manual row");

const dry = a.buildSummary(ans, [], { derived:"x", dryRun:true, gitHooks: null });
if (/git gate hooks/.test(manualText(dry))) fail("--dry-run must not claim a hooks probe it never ran");
' "$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")" \
  || fail "caseAD1: buildSummary does not report the git gate hooks honestly"

# AD2 — the probe itself, against REAL git repos. The interesting arm is the
# linked worktree: its `.git` is a FILE, so the obvious `<target>/.git/hooks`
# check finds nothing and would read EVERY worktree install as ungated, while
# git actually runs the hooks in the SHARED common dir. `git rev-parse
# --git-path hooks` is what pre-commit itself resolves, so it is what the
# probe uses.
adBin="$work/ad-bin"; mkdir -p "$adBin"
adRepo="$work/ad-repo"; mkdir -p "$adRepo"
(
  cd "$adRepo" || exit 1
  git init -q . >/dev/null 2>&1
  git config user.email ad@example.invalid
  git config user.name  "Case AD"
  : > seed.txt
  git add seed.txt >/dev/null 2>&1
  git commit -qm "seed" >/dev/null 2>&1
) || fail "caseAD2: could not build the fixture repo"

probe_hooks() {
  # $1 = cwd to probe. Prints `applicable placed missing` as one line.
  # shellcheck disable=SC2016
  ( cd "$1" && "$node_bin" -e '
const s = require(process.argv[1]).gitGateHooksState();
console.log([s.applicable, s.placed === undefined ? "-" : s.placed, (s.missing || []).join(",") || "-"].join(" "));
' "$(winpath "$repo_root/scripts/himmelctl/bin.js")" )
}

adNonRepo=$(probe_hooks "$adBin") || fail "caseAD2: probe failed on a non-repo dir"
[ "$adNonRepo" = "false - -" ] \
  || fail "caseAD2: a non-git dir must probe applicable=false, got [$adNonRepo]"

adBare=$(probe_hooks "$adRepo") || fail "caseAD2: probe failed on the fixture repo"
case "$adBare" in
  "true false "*commit-msg*) : ;;
  *) fail "caseAD2: a repo with no gate hooks must probe placed=false naming commit-msg, got [$adBare]" ;;
esac

# `git init` does not always leave a .git/hooks directory behind -- with the
# hermetic HOME this suite runs under, the sample-hook template dir is not
# applied, so the bare-repo arm above is measuring a hooks dir that does not
# exist at all. Create it the way git itself resolves it.
adHooks=$( cd "$adRepo" && git rev-parse --git-path hooks )
case "$adHooks" in /*) : ;; *) adHooks="$adRepo/$adHooks" ;; esac
mkdir -p "$adHooks"
for h in pre-commit commit-msg pre-push; do
  printf '#!/bin/sh\nexit 0\n' > "$adHooks/$h"
  chmod +x "$adHooks/$h"
done
adFull=$(probe_hooks "$adRepo") || fail "caseAD2: probe failed after placing hooks"
[ "$adFull" = "true true -" ] \
  || fail "caseAD2: all three hooks present must probe placed=true, got [$adFull]"

# CR round 1 [codex-1]: "the path exists" is not "git will run it". A
# non-executable file and a DIRECTORY at the hook path both satisfy an
# existence check while git runs nothing -- certifying an ungated repo as
# gated is the exact false-clean this ticket is about. Windows is exempt:
# git-for-windows runs hooks through sh and ignores the mode, so the bit is
# not part of "would git run this" there.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  (caseAD2: executable-bit arm skipped -- git-for-windows ignores the hook mode)" ;;
  *)
    chmod -x "$adHooks/commit-msg"
    adNoExec=$(probe_hooks "$adRepo") || fail "caseAD2: probe failed on a non-executable hook"
    case "$adNoExec" in
      "true false "*commit-msg*) : ;;
      *) fail "caseAD2: a NON-EXECUTABLE commit-msg must read as missing, got [$adNoExec]" ;;
    esac
    chmod +x "$adHooks/commit-msg" ;;
esac

rm -f "$adHooks/pre-push"
mkdir -p "$adHooks/pre-push"
adDir=$(probe_hooks "$adRepo") || fail "caseAD2: probe failed on a directory-shaped hook"
case "$adDir" in
  "true false "*pre-push*) : ;;
  *) fail "caseAD2: a DIRECTORY at the hook path must read as missing, got [$adDir]" ;;
esac
rmdir "$adHooks/pre-push"
printf '#!/bin/sh\nexit 0\n' > "$adHooks/pre-push"
chmod +x "$adHooks/pre-push"

# The worktree arm, and the reason the probe uses `git rev-parse --git-path
# hooks` at all. A linked worktree's `.git` is a FILE, so the obvious
# `<target>/.git/hooks` check finds nothing there and would report EVERY
# worktree install as ungated. Git does not work that way: hooks live in the
# common dir and are SHARED by every worktree, so the hooks placed on the main
# checkout above are exactly the ones git will run here. Measured, not assumed
# -- this arm fails if the probe ever goes back to a literal .git/hooks join.
#
# CR round 1 [codex-3]: this arm does NOT silently skip when `git worktree add`
# fails. It is the ONLY arm that exercises the path resolution the fix exists
# for, so a skip here is a suite that passes while proving nothing -- and git
# worktree is available wherever this suite runs at all, since the fixture repo
# above already needed init/add/commit from the same binary.
adWt="$work/ad-wt"
( cd "$adRepo" && git worktree add -q -b case-ad-wt "$adWt" >/dev/null 2>&1 ) \
  || fail "caseAD2: git worktree add failed -- the linked-worktree arm is the whole point of the path resolution under test and must not be skipped"
[ -f "$adWt/.git" ] \
  || fail "caseAD2: fixture assumption broken -- a linked worktree's .git should be a FILE"
[ -e "$adWt/.git/hooks" ] \
  && fail "caseAD2: fixture assumption broken -- <worktree>/.git/hooks should not exist"
adWtOut=$(probe_hooks "$adWt") || fail "caseAD2: probe failed inside the worktree"
[ "$adWtOut" = "true true -" ] \
  || fail "caseAD2: a worktree must read the SHARED common-dir hooks as placed, got [$adWtOut]"
echo "ok: caseAD git gate hooks are reported from disk — missing/placed/non-repo/dry-run all distinct, worktree hooks dir resolved"

# ── caseAS (HIMMEL-2537): the dev overlay's USER_SLUG step is advisory now.
# Until this ticket, setup.sh exited 1 on an unresolved slug and runPlan
# returned on that rc BEFORE the epilogue -- so no summary was printed and none
# could be wrong. Making the install complete is what creates the obligation to
# say what was left undone, which is the same argument caseAD pins for the git
# gate hooks.
#
# AS1 -- the renderer.
# shellcheck disable=SC2016
"$node_bin" -e '
const a = require(process.argv[1]);
const fail = (m) => { console.error(m); process.exit(1); };
const ans = { role:"adopter", scope:"project", vault:{mode:"none",path:""},
              handover:{mode:"inline",path:""}, pluginSet:"lean", lanes:[], alwaysOn:false };
const manualText = (s) => s.manual.map((m) => [m.what, m.how, m.note].join(" ")).join("\n");

const unresolved = a.buildSummary(ans, [], { derived:"x", dryRun:false,
  userSlug: { applicable:true, verified:true, resolved:false } });
const ut = manualText(unresolved);
if (!/USER_SLUG/.test(ut)) fail("an unresolved slug produced no still-manual row");
if (!/handover bucket paths/.test(ut)) fail("the row must state the consequence, not just the fact");
if (!/gh auth login/.test(ut)) fail("the row must carry the remedies, not just a defect report");

const resolved = a.buildSummary(ans, [], { derived:"x", dryRun:false,
  userSlug: { applicable:true, verified:true, resolved:true } });
if (/USER_SLUG/.test(manualText(resolved))) fail("a slug that DID resolve must produce no still-manual row");

// A probe that could not run is its own row -- the caseAD/codex-2 lesson: an
// unverifiable state must not be folded into either known state.
const unverified = a.buildSummary(ans, [], { derived:"x", dryRun:false,
  userSlug: { applicable:true, verified:false, reason:"check-user-slug.sh exited rc=127" } });
const vt = manualText(unverified);
if (!/could NOT be verified/.test(vt)) fail("an unverifiable slug probe produced no still-manual row");
if (/did NOT resolve/.test(vt)) fail("an unverifiable probe must not be reported as a known-unresolved slug");
// codex round 4 [codex-1]: the prescribed command must match what
// userSlugState() actually ran (with --dotenv-root), or an operator whose
// USER_SLUG lives only in .env is told to run a command that misreports them.
if (!/check-user-slug\.sh --dotenv-root/.test(vt)) fail("the unverified row prescribed command must carry --dotenv-root");

const nonApplicable = a.buildSummary(ans, [], { derived:"x", dryRun:false,
  userSlug: { applicable:false } });
if (/USER_SLUG/.test(manualText(nonApplicable))) fail("win32 (setup.ps1 has no such step) must produce no still-manual row");

const dry = a.buildSummary(ans, [], { derived:"x", dryRun:true, userSlug: null });
if (/USER_SLUG/.test(manualText(dry))) fail("--dry-run must not claim a slug probe it never ran");
' "$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")" \
  || fail "caseAS1: buildSummary does not report the USER_SLUG step honestly"

# AS2 -- the probe. HIMMELCTL_REPO_ROOT points bin.js at STUB fixtures, so all
# four arms are deterministic instead of depending on whether the tester's own
# machine happens to have a git identity or an authenticated gh.
probe_slug() {
  # $1 = HIMMELCTL_REPO_ROOT to probe. Prints `applicable verified resolved`.
  # shellcheck disable=SC2016
  HIMMELCTL_REPO_ROOT="$1" "$node_bin" -e '
const s = require(process.argv[1]).userSlugState();
console.log([s.applicable, s.verified === undefined ? "-" : s.verified,
             s.resolved === undefined ? "-" : s.resolved].join(" "));
' "$(winpath "$repo_root/scripts/himmelctl/bin.js")"
}
as_stub() {
  # $1 = fixture root, $2 = the rc the stub check-user-slug.sh exits with.
  mkdir -p "$1/scripts/setup"
  printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$1/scripts/setup/check-user-slug.sh"
  chmod +x "$1/scripts/setup/check-user-slug.sh"
}
# as_stub_argv -- a stub that RECORDS its own argv instead of just exiting, so
# the assertion binds to the probe's BEHAVIOUR (what it actually passed the
# script) rather than grepping bin.js's source for the flag (CR round 2
# [codex-1]: the fix is that userSlugState() now passes --dotenv-root
# repoRoot() on the same spawnSync call the other arms above already probe).
as_stub_argv() {
  # $1 = fixture root, $2 = the rc to exit with.
  mkdir -p "$1/scripts/setup"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf '\''%%s\n'\'' "$@" > %q/argv-capture\n' "$1"
    printf 'exit %s\n' "$2"
  } > "$1/scripts/setup/check-user-slug.sh"
  chmod +x "$1/scripts/setup/check-user-slug.sh"
}
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  (caseAS2: probe arms skipped -- the dev overlay on win32 is setup.ps1, which has no USER_SLUG step)" ;;
  *)
    asOk="$work/as-ok";   as_stub "$asOk" 0
    asAdv="$work/as-adv"; as_stub "$asAdv" 3
    asBad="$work/as-bad"; as_stub "$asBad" 7
    asGone="$work/as-gone"; mkdir -p "$asGone/scripts/setup"

    asOkOut=$(probe_slug "$asOk") || fail "caseAS2: probe failed on the rc=0 stub"
    [ "$asOkOut" = "true true true" ] \
      || fail "caseAS2: rc=0 must read as resolved, got [$asOkOut]"
    asAdvOut=$(probe_slug "$asAdv") || fail "caseAS2: probe failed on the rc=3 stub"
    [ "$asAdvOut" = "true true false" ] \
      || fail "caseAS2: rc=3 (advised) must read as verified-but-unresolved, got [$asAdvOut]"
    # An unexpected rc is the probe breaking, NOT a slug that failed to resolve.
    # Collapsing the two would put a confident "did NOT resolve" row in front of
    # an operator whose slug may be perfectly fine.
    asBadOut=$(probe_slug "$asBad") || fail "caseAS2: probe failed on the rc=7 stub"
    [ "$asBadOut" = "true false -" ] \
      || fail "caseAS2: an unexpected rc must read as unverified, got [$asBadOut]"
    asGoneOut=$(probe_slug "$asGone") || fail "caseAS2: probe failed on the missing-script fixture"
    [ "$asGoneOut" = "true false -" ] \
      || fail "caseAS2: an absent check-user-slug.sh must read as unverified, got [$asGoneOut]"

    # The probe must pass --dotenv-root repoRoot() on the same spawnSync call
    # (CR round 2 [codex-1]) -- without it a slug filled into the fixture's
    # own .env is invisible to this replay, disagreeing with setup.sh's footer.
    asArgv="$work/as-argv"; as_stub_argv "$asArgv" 0
    argvProbeOut=$(probe_slug "$asArgv") || fail "caseAS2: probe failed on the argv-capture stub"
    [ "$argvProbeOut" = "true true true" ] \
      || fail "caseAS2: argv-capture stub did not read as resolved, got [$argvProbeOut]"
    capturedArgv=$(cat "$asArgv/argv-capture" 2>/dev/null || echo "")
    printf '%s' "$capturedArgv" | grep -q -F -- "--dotenv-root" \
      || fail "caseAS2: the probe did not pass --dotenv-root, argv was [$capturedArgv]"
    ;;
esac
echo "ok: caseAS the USER_SLUG step is reported from a replay of its own check — resolved/unresolved/unverified/dry-run all distinct"

echo "PASS: test-wizard-adopter-profile.sh (35 cases)"
