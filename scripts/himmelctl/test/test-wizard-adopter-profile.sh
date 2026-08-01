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
#      a second door around the explicit flag) and `--from-profile` combined
#      with a lane flag all exit 2. With a MISSING profile the CONFLICT is
#      reported, never a load failure, and the file is not opened at all
#      (CR round 10 [codex-r9-1] — the ordering was already correct; only the
#      rc had been pinned, so the message class could have drifted silently).
#   E. hardening is PRINTED, NEVER EXECUTED — alwaysOn=true prints the
#      checklist while a sentinel `powercfg` stub on PATH proves nothing ran.
#   F. alwaysOn=false -> the one-line pointer, and NO powercfg text at all.
#   G. contributor runs print NO adopter epilogue (HIMMEL-1423 owns that).
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
#   L. a FAILED pluginSet=full step is reported as failed (CR round 1
#      [codex-adv-2]) — never as "full plugin set enabled" beside a nonzero rc.
#      L2: under --dry-run the same step is phrased as PLANNED, not past-tense
#      (CR round 2 [codex-r2-1 / glm-r2-3]).
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
#      [codex-adv-r8-2]) — a DISABLED copilot keeps its device-flow login and a
#      forced-on absent ollama keeps its model pull, ordered AFTER the fix.
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
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# Same rationale as test-wizard-questions.sh: pin bin.js's bash spawns to the
# PATH-honoring `bash` so detectRole reads the STUB git, not the real repo.
export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

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
  PATH="$_p" HOME="$_home" HIMMELCTL_INTERACTIVE=0 \
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

# ── Case A: lanes absent -> MISSING + manual entry with the install command ──
sA="$work/a"; mkdir -p "$sA"; hA="$work/a-home"; mkdir -p "$hA"
fA="$work/a-fix"; make_fixture "$fA"
capture "$sA" "$hA" "$fA"
[ "$rc" -eq 0 ] || fail "caseA: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '!! +ollama +MISSING' \
  || fail "caseA: ollama should probe MISSING on a scrubbed PATH: $ep"
grepq "$ep" -E '!! +copilot +MISSING' \
  || fail "caseA: copilot should probe MISSING on a scrubbed PATH: $ep"
grepq "$ep" 'still manual' \
  || fail "caseA: summary should carry a 'still manual' section: $ep"
grepq "$ep" 'lane ollama' \
  || fail "caseA: ollama should appear in the manual section: $ep"
# The install command must be surfaced — an adopter who is told a lane is
# missing and NOT told how to get it has been given a defect report, not a
# next step.
grepq "$ep" -iE 'winget install Ollama|ollama.com/download|brew install ollama' \
  || fail "caseA: the manual entry must carry an install command: $ep"
# And the installer must never claim it installed a lane it only probed.
grepq "$ep" '+ lane ollama' \
  && fail "caseA: an ABSENT lane must not appear under 'installed': $ep"
echo "ok: caseA absent lanes -> MISSING + manual entry carrying the install command"

# ── Case B: lane present -> available + installed, never manual ──────────────
sB="$work/b"; mkdir -p "$sB"; hB="$work/b-home"; mkdir -p "$hB"
fB="$work/b-fix"; make_fixture "$fB"
# Plant a fake `ollama` the node-side which() will resolve. build_path scrubs
# the REAL one off PATH, so this stub is the only match.
plant_cli "$sB" ollama
capture "$sB" "$hB" "$fB"
[ "$rc" -eq 0 ] || fail "caseB: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '~ +ollama +binary present' \
  || fail "caseB: a planted ollama should probe available: $ep"
# CR round 1 [codex-1]: a present lane is a FACT, not an action himmelctl
# performed — it belongs in `skipped` ("already available, nothing to
# install"), never in the installed/would-install bucket.
grepq "$ep" -- '- lane ollama — binary already present' \
  || fail "caseB: a present lane belongs under 'skipped' as already available: $ep"
grepq "$ep" 'nothing to install' \
  || fail "caseB: a present lane should say nothing to install (idempotent): $ep"
grepq "$ep" '+ lane ollama' \
  && fail "caseB: a present lane must NOT be claimed as installed work: $ep"
# CR round 4 [codex-adv-r3-2]: the probe sees a BINARY, not a working lane.
# ollama still needs its model pulled, so that step must survive into `still
# manual` as a verify item — dropping it told the adopter a lane they cannot
# yet use was ready. It must NOT be re-listed as an install, though.
grepq "$ep" 'cannot confirm setup' \
  || fail "caseB: a present lane's unverified setup must stay visible: $ep"
grepq "$ep" 'ollama pull' \
  || fail "caseB: the retained setup step should name the model pull: $ep"
grepq "$ep" 'winget install Ollama.Ollama' \
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
sC2="$work/c2"; mkdir -p "$sC2"; hC2="$work/c2-home"; mkdir -p "$hC2"
capture "$sC2" "$hC2" "$fC" --with-codex
[ "$rc" -eq 0 ] || fail "caseC: --with-codex should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '(!!|ok) +codex' \
  || fail "caseC: --with-codex should SELECT codex (probed, not 'not selected'): $ep"
grepq "$ep" 'opt in with --with-hermes' \
  || fail "caseC: --with-codex must not also select hermes: $ep"
echo "ok: caseC opt-in lanes appear only under their own flag"

# ── Case D: flag validation ─────────────────────────────────────────────────
expect_rc2() {
  local _label="$1"; shift
  set +e
  local _o
  _o=$(HIMMELCTL_INTERACTIVE=0 "$node_bin" "$wizard" install "$@" </dev/null 2>&1)
  local _rc=$?
  set -e
  [ "$_rc" -eq 2 ] || fail "caseD/$_label: expected rc=2, got $_rc: $_o"
}
expect_rc2 bogus-lane --lanes bogus
expect_rc2 optin-via-lanes --lanes codex
expect_rc2 empty-lanes --lanes ,
expect_rc2 profile-conflict --from-profile "$work/nope.json" --with-codex
expect_rc2 profile-conflict-lanes --from-profile "$work/nope.json" --lanes ollama
# CR round 10 [codex-r9-1] investigated this ordering: with a MISSING profile
# the run must report the flag-CONFLICT (a parse-time contract), never the
# profile-LOAD failure. It already does — the combination is rejected in
# parseArgs, before cmdInstall ever opens the file — but only the rc was
# pinned, so the message class could have drifted without a test noticing.
# Both are asserted now, including the absence of any load-failure text.
set +e
conflict_out=$(HIMMELCTL_INTERACTIVE=0 "$node_bin" "$wizard" install \
  --from-profile "$work/definitely-not-here.json" --lanes ollama </dev/null 2>&1)
conflict_rc=$?
set -e
[ "$conflict_rc" -eq 2 ] \
  || fail "caseD: missing profile + --lanes should exit 2 (got $conflict_rc): $conflict_out"
grepq "$conflict_out" 'cannot be combined with --from-profile' \
  || fail "caseD: should report the flag CONFLICT, not a load error: $conflict_out"
grepq "$conflict_out" -iE 'ENOENT|no such file|not valid JSON|invalid profile' \
  && fail "caseD: the profile must not even be OPENED when the flags conflict: $conflict_out"
echo "ok: caseD bad/opt-in/empty --lanes and --from-profile conflicts all exit 2 with the conflict message"

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
  "alwaysOn": true
}
JSON
pE=$(build_path "$sE" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sE" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pE" HOME="$hE" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fE")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profE")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseE: profile install should succeed (got rc=$rc): $out"
grepq "$out" 'CHECKLIST ONLY' \
  || fail "caseE: alwaysOn=true must print the checklist banner: $out"
grepq "$out" 'powercfg /hibernate off' \
  || fail "caseE: the checklist must carry the real Phase-6 commands: $out"
[ -f "$sentinel" ] \
  && fail "caseE: HARDENING WAS EXECUTED — powercfg stub ran (sentinel $sentinel exists)"
# CR round 11 [codex-adv-r10-1]: sshd reads its config at START, so
# `Start-Service` against an already-running daemon is a no-op and the OLD
# (possibly password-auth) config stays live — which would make the whole
# policy-before-enable ordering cosmetic. The checklist must restart a running
# service, and the access policy must precede the enable step.
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
echo "ok: caseE alwaysOn=true prints the checklist (policy before enable, restart-aware) and executes NONE of it"

# ── Case F: alwaysOn=false -> pointer only, no powercfg text ────────────────
sF="$work/f"; mkdir -p "$sF"; hF="$work/f-home"; mkdir -p "$hF"
fF="$work/f-fix"; make_fixture "$fF"
capture "$sF" "$hF" "$fF"
grepq "$out" 'always-on hardening: skipped' \
  || fail "caseF: alwaysOn=false should print the one-line pointer: $out"
grepq "$out" 'powercfg' \
  && fail "caseF: alwaysOn=false must not dump the checklist: $out"
echo "ok: caseF alwaysOn=false -> pointer line only, no checklist"

# ── Case G: contributor prints no adopter epilogue ──────────────────────────
sG="$work/g"; mkdir -p "$sG"; hG="$work/g-home"; mkdir -p "$hG"
fG="$work/g-fix"; make_fixture "$fG"
topG="$work/g-top"; mkdir -p "$topG"; touch "$topG/.himmel-dev"
pG=$(build_path "$sG" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sG" "https://github.com/user/himmel.git" "$(winpath "$topG")"
set +e
out=$(PATH="$pG" HOME="$hG" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fG")" \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseG: contributor dry-run should succeed (got rc=$rc): $out"
grepq "$out" '"role": "contributor"' \
  || fail "caseG: fixture should resolve to contributor: $out"
grepq "$out" 'delegation lanes' \
  && fail "caseG: contributor must print NO lane report: $out"
grepq "$out" 'install summary' \
  && fail "caseG: contributor must print NO adopter summary: $out"
echo "ok: caseG contributor -> no adopter epilogue (HIMMEL-1423 owns that)"

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
capture "$sI" "$hI" "$fI"
[ "$rc" -eq 0 ] || fail "caseI: a missing registry must not crash the run (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '\?\? +ollama +UNKNOWN' \
  || fail "caseI: a missing lane registry should degrade to UNKNOWN: $ep"
grepq "$ep" -E '(ok|~) +ollama' \
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
  "alwaysOn": false
}
JSON
pJ=$(build_path "$sJ2" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sJ2" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pJ" HOME="$hJ2" HIMMELCTL_INTERACTIVE=0 \
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
  PATH="$_p" HOME="$_h" HIMMELCTL_INTERACTIVE=0 \
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

# ── Case L: a FAILED plugin step must not be reported as success ────────────
# CR round 1 [codex-adv-2]. With `claude` absent from the stub PATH every
# `claude plugin ...` command fails, so pluginSet=full completes with a
# nonzero rc — the summary must say so rather than print "full plugin set
# enabled" alongside that failure.
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
  "alwaysOn": false
}
JSON
pL=$(build_path "$sL" bash jq python3 npm -- "${LANE_TOOLS[@]}" claude)
make_git_stub "$sL" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pL" HOME="$hL" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fL")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$profL")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] \
  || fail "caseL: a wholly-failed plugin step should exit nonzero (got rc=$rc): $out"
grepq "$out" 'full plugin set enabled' \
  && fail "caseL: must NOT claim the full plugin set was enabled after failures: $out"
grepq "$out" 'plugin command(s) FAILED' \
  || fail "caseL: the summary should report the failed plugin commands: $out"
# Single-quoted on purpose: the backticks are literal text in the summary's
# retry hint, not a command substitution.
# shellcheck disable=SC2016
grepq "$out" 're-run `himmelctl install` to retry' \
  || fail "caseL: the failure entry should carry the retry instruction: $out"
echo "ok: caseL failed plugin step -> reported as failed, never as 'enabled'"

# L2 — CR round 2 [codex-r2-1 / glm-r2-3]: the same pluginSet=full profile
# under --dry-run must describe the enable step as PLANNED, never in the past
# tense. `pluginFailures` is null there (the step never ran), which used to be
# coerced to "no failures" and printed as "full plugin set enabled".
sL2="$work/l2"; mkdir -p "$sL2"; hL2="$work/l2-home"; mkdir -p "$hL2"
pL2=$(build_path "$sL2" bash jq python3 npm -- "${LANE_TOOLS[@]}" claude)
make_git_stub "$sL2" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pL2" HOME="$hL2" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fL")" \
      "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profL")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseL2: dry-run should succeed (got rc=$rc): $out"
grepq "$out" 'full plugin set enabled' \
  && fail "caseL2: --dry-run must not use the past tense for the enable step: $out"
grepq "$out" 'would be enabled' \
  || fail "caseL2: --dry-run should describe the enable step as planned: $out"
echo "ok: caseL2 --dry-run phrases the plugin enable step as planned, not done"

# ── Case M: a lane DISABLED by lanes.local.json must not read ready ─────────
# CR round 2 [codex-adv-r2-1]. The probe used to read base lanes.json alone,
# so a locally-disabled lane still reported "available" while /lanes excluded
# it. The installer's epilogue must agree with the runtime surface. The lane
# is ALSO physically installed here, so this pins the second half too: the
# next step is a config flip, not a reinstall.
sM="$work/m"; mkdir -p "$sM"; hM="$work/m-home"; mkdir -p "$hM"
fM="$work/m-fix"; make_fixture "$fM"
cat > "$fM/scripts/lanes/lanes.local.json" <<'OVERLAY'
{ "lanes": [ { "id": "ollama-local", "probe": { "kind": "never" } } ] }
OVERLAY
plant_cli "$sM" ollama
capture "$sM" "$hM" "$fM"
[ "$rc" -eq 0 ] || fail "caseM: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '~ +ollama +binary present' \
  && fail "caseM: an overlay-DISABLED lane must NOT read as available: $ep"
grepq "$ep" -E '\-\- +ollama +DISABLED' \
  || fail "caseM: an overlay-disabled lane should read DISABLED: $ep"
grepq "$ep" 'config set lanes.ollama-local on' \
  || fail "caseM: the fix for a disabled lane is a config flip, and must be named: $ep"
# It is installed — so it must NOT be reported as something to go install.
grepq "$ep" 'winget install Ollama.Ollama' \
  && fail "caseM: a DISABLED-but-installed lane must not be sent back to winget: $ep"
# Sanity: the same fixture WITHOUT the overlay reads available, proving the
# difference comes from the overlay and not from the stub being broken.
fM2="$work/m2-fix"; make_fixture "$fM2"
sM2="$work/m2"; mkdir -p "$sM2"; hM2="$work/m2-home"; mkdir -p "$hM2"
plant_cli "$sM2" ollama
capture "$sM2" "$hM2" "$fM2"
grepq "$(epilogue "$out")" -E '~ +ollama +binary present' \
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
    truncated)  printf '{"lanes":[{"id":"ollama-local",\n' > "$fN/scripts/lanes/lanes.local.json" ;;
    wrongshape) printf '{"lanes":{}}\n'                    > "$fN/scripts/lanes/lanes.local.json" ;;
  esac
  # Plant the binary too: without the fail-closed the lane would read present,
  # so this proves the overlay error wins over a real probe hit.
  plant_cli "$sN" ollama
  capture "$sN" "$hN" "$fN"
  [ "$rc" -eq 0 ] || fail "caseN/$_shape: a corrupt overlay must not crash the run (got rc=$rc): $out"
  ep=$(epilogue "$out")
  grepq "$ep" -E '\?\? +ollama +UNKNOWN' \
    || fail "caseN/$_shape: a corrupt overlay should make lanes read UNKNOWN: $ep"
  grepq "$ep" 'lanes.local.json' \
    || fail "caseN/$_shape: the diagnostic must NAME the offending file: $ep"
  grepq "$ep" -E '(ok|~) +ollama' \
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
ALWAYS_OVERLAY='{ "lanes": [ { "id": "ollama-local", "probe": { "kind": "always" } } ] }'

# P1 — forced ON, nothing installed: must NOT read present, and must KEEP the
# install command. This is the reproduction from the review.
sP1="$work/p1"; mkdir -p "$sP1"; hP1="$work/p1-home"; mkdir -p "$hP1"
fP1="$work/p1-fix"; pM_fix "$fP1" "$ALWAYS_OVERLAY"
capture "$sP1" "$hP1" "$fP1"
[ "$rc" -eq 0 ] || fail "caseP1: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '(ok|~) +ollama' \
  && fail "caseP1: an always-overlay must NOT make an uninstalled lane read present: $ep"
grepq "$ep" -E 'XX +ollama +MISCONFIGURED' \
  || fail "caseP1: forced-on-but-absent should read MISCONFIGURED: $ep"
grepq "$ep" 'winget install Ollama.Ollama' \
  || fail "caseP1: the install command must survive a bogus override: $ep"

# P2 — forced ON with the binary actually there: still present, and the detail
# must name the REAL reason, not the override ("registry probe kind=always").
sP2="$work/p2"; mkdir -p "$sP2"; hP2="$work/p2-home"; mkdir -p "$hP2"
fP2="$work/p2-fix"; pM_fix "$fP2" "$ALWAYS_OVERLAY"
plant_cli "$sP2" ollama
capture "$sP2" "$hP2" "$fP2"
ep=$(epilogue "$out")
grepq "$ep" -E '~ +ollama +binary present' \
  || fail "caseP2: an always-overlay over a real binary should still read present: $ep"
grepq "$ep" 'ollama found on PATH' \
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
for (const want of [/install-himmel-codex\.ps1/, /install-himmel-profile\.ps1/, /winget install/, /powercfg/]) {
  if (!want.test(win)) { console.error("win32 lost its own guidance " + want + "\n" + win); process.exit(1); }
}
' "$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")" "$(winpath "$fQ")" \
  || fail "caseQ: lane guidance is not platform-correct"
echo "ok: caseQ POSIX platforms get POSIX guidance; win32 keeps its PowerShell guidance"

# ── Case R: vault=default-template onto an OCCUPIED destination ────────────
# CR round 8 [codex-adv-r7-3]. adopt.sh's do_luna() skips the template copy
# whenever the destination EXISTS and continues with rc 0, so pointing
# default-template at an occupied unrelated directory quietly promoted that
# directory to "your vault" while the summary claimed it had been scaffolded.
# Unstamped -> refuse before any shell-out; stamped -> proceed but never claim
# scaffolding happened.
rVault_profile() {
  printf '{\n  "role": "adopter",\n  "tier": "standard",\n  "scope": "project",\n  "vault": { "mode": "default-template", "path": "%s" },\n  "handover": { "mode": "inline", "path": "" },\n  "pluginSet": "lean",\n  "lanes": [],\n  "alwaysOn": false\n}\n' "$1"
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
out=$(PATH="$pR" HOME="$hR" HIMMELCTL_INTERACTIVE=0 \
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
out=$(PATH="$pR" HOME="$hR" HIMMELCTL_INTERACTIVE=0 \
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
    out=$(PATH="$pR" HOME="$hR" HIMMELCTL_INTERACTIVE=0 \
          HIMMELCTL_REPO_ROOT="$(winpath "$fR")" \
          "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$profR")" \
          </dev/null 2>&1)
  else
    out=$(printf 'adopter\nproject\ndefault-template\n%s\ninline\nlean\nnone\nno\n' "$(winpath "$occR")" \
      | PATH="$pR" HOME="$hR" HIMMELCTL_INTERACTIVE=1 \
        HIMMELCTL_CACHE_DIR="$(winpath "$work/r3-cache")" \
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
const n = planned.split("\n").filter((l) => /would/.test(l)).length;
if (n !== 4) { console.error("expected all 4 planned rows conditional, got " + n + "\n" + planned); process.exit(1); }
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
  printf '{ "lanes": [ { "id": "ollama-local", "probe": %s } ] }\n' "$_probe" \
    > "$fT/scripts/lanes/lanes.local.json"
  # Plant the binary: physical presence is real, so only the overlay handling
  # can be what keeps the lane from reading present.
  plant_cli "$sT" ollama
  capture "$sT" "$hT" "$fT"
  [ "$rc" -eq 0 ] || fail "caseT[$_probe]: run should succeed (got rc=$rc): $out"
  ep=$(epilogue "$out")
  grepq "$ep" -E '(ok|~) +ollama' \
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
# were dropping it, so a disabled copilot showed only the re-enable command
# and a forced-on absent ollama only install+override repair.
# U1 — DISABLED copilot keeps its device-flow login step, AFTER the re-enable.
sU1="$work/u1"; mkdir -p "$sU1"; hU1="$work/u1-home"; mkdir -p "$hU1"
fU1="$work/u1-fix"; make_fixture "$fU1"
printf '{ "lanes": [ { "id": "copilot-cli", "probe": { "kind": "never" } } ] }\n' \
  > "$fU1/scripts/lanes/lanes.local.json"
plant_cli "$sU1" copilot
capture "$sU1" "$hU1" "$fU1"
ep=$(epilogue "$out")
grepq "$ep" 'config set lanes.copilot-cli on' \
  || fail "caseU1: the re-enable command must still be present: $ep"
grepq "$ep" 'device-flow login' \
  || fail "caseU1: a DISABLED lane must keep its setup step: $ep"
# Ordering: remediation before the setup step it unblocks.
remediation_line=$(printf '%s' "$ep" | grep -n 'config set lanes.copilot-cli on' | head -1 | cut -d: -f1)
setup_line=$(printf '%s' "$ep" | grep -n 'device-flow login' | tail -1 | cut -d: -f1)
[ "$remediation_line" -lt "$setup_line" ] \
  || fail "caseU1: remediation should come BEFORE the setup step: $ep"

# U2 — forced-on-but-ABSENT ollama keeps its model-pull step.
sU2="$work/u2"; mkdir -p "$sU2"; hU2="$work/u2-home"; mkdir -p "$hU2"
fU2="$work/u2-fix"; make_fixture "$fU2"
printf '{ "lanes": [ { "id": "ollama-local", "probe": { "kind": "always" } } ] }\n' \
  > "$fU2/scripts/lanes/lanes.local.json"
capture "$sU2" "$hU2" "$fU2"
ep=$(epilogue "$out")
grepq "$ep" -E 'XX +ollama +MISCONFIGURED' \
  || fail "caseU2: forced-on-but-absent should read MISCONFIGURED: $ep"
grepq "$ep" 'winget install Ollama.Ollama' \
  || fail "caseU2: the install command must survive: $ep"
grepq "$ep" 'ollama pull' \
  || fail "caseU2: a MISCONFIGURED lane must keep its setup step: $ep"
echo "ok: caseU overlay remediation preserves the setup note, ordered after the fix"

# ── Case V: ABSENT *and* overlay-disabled — the last cell of the matrix ────
# CR round 11 [codex-r10-1]. Installing the CLI does NOT make the lane usable
# while lanes.local.json still turns it off: /lanes keeps excluding it, so an
# adopter who followed the one instruction we gave got nothing. Both steps
# must be listed, install first, then the re-enable, then the setup step.
sV="$work/v"; mkdir -p "$sV"; hV="$work/v-home"; mkdir -p "$hV"
fV="$work/v-fix"; make_fixture "$fV"
printf '{ "lanes": [ { "id": "ollama-local", "probe": { "kind": "never" } } ] }\n' \
  > "$fV/scripts/lanes/lanes.local.json"
# NOTE: no plant_cli here — the lane is absent AND disabled, the whole point.
capture "$sV" "$hV" "$fV"
[ "$rc" -eq 0 ] || fail "caseV: dry-run should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" 'winget install Ollama.Ollama' \
  || fail "caseV: the install command must be listed: $ep"
grepq "$ep" 'config set lanes.ollama-local on' \
  || fail "caseV: the overlay re-enable must ALSO be listed: $ep"
grepq "$ep" 'ollama pull' \
  || fail "caseV: the setup step must survive here too: $ep"
grepq "$ep" 'DISABLED by scripts/lanes/lanes.local.json' \
  || fail "caseV: the row should say the overlay also blocks it: $ep"
# Ordering: install, then re-enable, then setup.
i_install=$(printf '%s' "$ep" | grep -n 'winget install Ollama.Ollama' | head -1 | cut -d: -f1)
i_enable=$(printf '%s' "$ep" | grep -n 'config set lanes.ollama-local on' | head -1 | cut -d: -f1)
i_setup=$(printf '%s' "$ep" | grep -n 'ollama pull' | head -1 | cut -d: -f1)
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
printf '{\n  "role": "adopter",\n  "tier": "standard",\n  "scope": "project",\n  "vault": { "mode": "default-template", "path": "%s" },\n  "handover": { "mode": "external", "path": "%s" },\n  "pluginSet": "lean",\n  "lanes": [],\n  "alwaysOn": false\n}\n' \
  "$(winpath "$raceX")" "$(winpath "$raceX")" > "$profX"
pX=$(build_path "$sX" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sX" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pX" HOME="$hX" HIMMELCTL_INTERACTIVE=0 \
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
sY="$work/y"; mkdir -p "$sY"; hY="$work/y-home"; mkdir -p "$hY"
fY="$work/y-fix"; make_fixture "$fY"
# An overlay that would DISABLE ollama if it were consulted.
printf '{ "lanes": [ { "id": "ollama-local", "probe": { "kind": "never" } } ] }\n' \
  > "$fY/scripts/lanes/lanes.local.json"
altY="$work/y-registry.json"
printf '{ "lanes": [ { "id": "ollama-local", "probe": { "kind": "path", "cli": "ollama" } } ] }\n' > "$altY"
plant_cli "$sY" ollama
pY=$(build_path "$sY" bash jq python3 npm -- "${LANE_TOOLS[@]}")
make_git_stub "$sY" "https://github.com/someone/other-repo.git"
set +e
out=$(PATH="$pY" HOME="$hY" HIMMELCTL_INTERACTIVE=0 \
      LANES_REGISTRY="$(winpath "$altY")" \
      HIMMELCTL_REPO_ROOT="$(winpath "$fY")" \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseY: dry-run under LANES_REGISTRY should succeed (got rc=$rc): $out"
ep=$(epilogue "$out")
grepq "$ep" -E '~ +ollama +binary present' \
  || fail "caseY: under LANES_REGISTRY the overlay must be IGNORED: $ep"
grepq "$ep" 'DISABLED' \
  && fail "caseY: the skipped overlay must not still disable the lane: $ep"
# Control: the SAME fixture WITHOUT the override does honour the overlay.
set +e
out=$(PATH="$pY" HOME="$hY" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fY")" \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1)
set -e
grepq "$(epilogue "$out")" 'DISABLED' \
  || fail "caseY: without the override the overlay must still apply: $(epilogue "$out")"
echo "ok: caseY LANES_REGISTRY replaces the registry and skips the overlay, like the resolver"

echo "PASS: test-wizard-adopter-profile.sh (27 cases)"
