#!/usr/bin/env bash
# test-wizard-deps.sh — hermetic tests for `himmelctl deps status|ensure|
# upgrade` (HIMMEL-759, sub-ticket C of epic HIMMEL-755): the version-aware
# toolchain manager over scripts/install/deps.json, kept SEPARATE from the
# manifest's presence-only kind:"dep" items (see deps.json's own header /
# scripts/himmelctl/lib/deps-engine.js for the locked design rationale).
#
# Mirrors sibling test-wizard-*.sh conventions: node launched by absolute
# path, winpath for node.exe's MSYS-path blindness, a stub PATH via
# scripts/lib/hermetic-path.sh for the e2e cases, HIMMELCTL_REPO_ROOT pointed
# at a throwaway fixture. NEVER exercises a real package manager (apt/dnf/
# brew/winget/pip) or the real ensure-tools.sh/qmd-bin.sh, and NEVER hits the
# network — every plan-shape assertion runs the ENGINE directly (node -e +
# require, mirrors test-wizard-install-engine.sh's own pattern for exactly
# this reason: buildDepEntry accepts a ctx.platform override, so the win32/
# macos/linux branches are all exercised deterministically regardless of
# this suite's own host OS), and every e2e execution case (`deps ensure`/
# `deps upgrade` actually running something) uses manager:"script" against a
# throwaway stub script that only appends to a log file — never a real
# installer.
#
# Covers (lib-level plan-shape, cases a-i):
#   a. buildDepEntry manager:"ensure-tools" (non-bun, e.g. git) -> `. "$1" &&
#      ensure_tools "$2"` with the ensure-tools.sh path + cmd name as
#      positional args (never interpolated).
#   b. buildDepEntry manager:"ensure-tools" for bun: install ->
#      `ensure_tools bun`; upgrade:true -> `_ensure_install_bun` (re-running
#      the official installer in place, since ensure_tools() itself SKIPS an
#      already-present tool and can't upgrade one).
#   c. buildDepEntry manager:"brew": install -> `brew install "$1"`;
#      upgrade -> `brew upgrade "$1" ... || brew install "$1"`.
#   d. buildDepEntry manager:"winget": install -> `winget install --id "$1"
#      -e --silent ...`; upgrade -> the same with `upgrade`.
#   e. buildDepEntry manager:"pip": install has no `--upgrade`; upgrade adds
#      it.
#   f. buildDepEntry manager:"script": the SAME entry (script path + args)
#      for both install and upgrade — idempotent/converging by construction.
#   g. buildDepEntry manager:"hint": {unrunnable: detail}, never a spawnable
#      entry.
#   h. buildDepEntry with no recipe declared for the current OS ->
#      {unrunnable: "..."} naming the OS.
#   i. versionGte: below/equal/above a floor, and a "vNN.N.N"-shaped actual
#      (node's own `--version` output) still parses correctly.
#
# Covers (e2e, cases j-t):
#   j. `--help` / bare `--help` list `deps status|ensure|upgrade`.
#   k. `deps` with no verb, or an unknown verb -> exit 2, naming the
#      status|ensure|upgrade requirement.
#   l. `deps status`: a present dep (stubbed on PATH) reads green with its
#      version; a missing dep reads red; exit 0 either way; the summary line
#      matches the counts.
#   m. `deps status --json`: valid JSON, byte-identical across two runs.
#   n. `deps ensure --dry-run`: prints a DRY line per missing dep, executes
#      nothing (the stub install script's log file is absent afterward).
#   o. `deps ensure` non-interactive, no --yes -> exit 2, requires --yes;
#      the stub install script never runs.
#   p. `deps ensure --yes`: both missing deps' manager:"script" installs run
#      (log file written); the post-install re-probe (CR fix) KEEP the one
#      that converged (qmd — creates its presence marker) and FAIL-CLOSE the
#      one that didn't land (redtool — still off PATH) -> exit 1,
#      "1 installed, 1 failed", redtool reported "installed but still not
#      found on PATH".
#   q. `deps ensure` when nothing is missing -> "nothing to converge",
#      exit 0, no install script invoked.
#   r. `deps upgrade --yes` (dep present, manager:"script"): the upgrade
#      recipe runs (log file written); the qmd model pull is SKIPPED
#      (non-interactive, no --with-models) with the "skipping" message.
#   s. `deps upgrade --yes --with-models`: the qmd model-pull entry ALSO
#      runs (its own log file written) — no prompt shown.
#   t. `deps upgrade --dry-run` (no --with-models): prints the upgrade DRY
#      line(s) plus a DRY line for the (skipped) model-pull prompt; nothing
#      executed.

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
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
deps_engine_lib="$repo_root/scripts/himmelctl/lib/deps-engine.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$deps_engine_lib" ] || { echo "FAIL: $deps_engine_lib not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

DEPS_ENGINE_LIB="$(winpath "$deps_engine_lib")"
export DEPS_ENGINE_LIB

# write_version_stub <dir> <name> <version> — a fake "<name> --version"
# binary printing a fixed version, as a plain bash shebang script. Safe on
# every platform (including Windows) because deps-engine.js's probeVersion
# always shells out via `bash -c` (never a raw spawnSync(dep.cmd, ...)) —
# bash's own PATH search + exec resolves an extensionless shebang script
# regardless of platform, matching every other tool-stub convention this
# codebase's test suites already use (see hermetic-path.sh's own header).
write_version_stub() {
  local _dir="$1" _name="$2" _ver="$3"
  cat > "$_dir/$_name" <<SH
#!/usr/bin/env bash
[ "\$1" = "--version" ] && echo "$_name version $_ver"
exit 0
SH
  chmod +x "$_dir/$_name"
}

# ═══════════════════════ lib-level plan-shape cases ════════════════════════

# ── case a: manager:"ensure-tools" (non-bun) ────────────────────────────────
outA=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'git', cmd: 'git', install: { linux: { manager: 'ensure-tools' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'linux' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
echo "$outA" | jq -e '.cmd == "bash" and .args[0] == "-c" and (.args[1] | contains("ensure_tools \"$2\""))' >/dev/null \
  || fail "case a: expected an ensure_tools \$2 dispatch (got: $outA)"
echo "$outA" | jq -e '.args[-1] == "git"' >/dev/null \
  || fail "case a: cmd name should be the LAST positional arg (got: $outA)"
grepq "$(echo "$outA" | jq -er '.args[3]')" -F 'ensure-tools.sh' \
  || fail "case a: the ensure-tools.sh path should be a positional arg (got: $outA)"
echo "ok: case a — manager:ensure-tools (non-bun) dispatches via ensure_tools \$2, positional args"

# ── case b: manager:"ensure-tools" for bun (install vs upgrade) ────────────
outB1=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'bun', cmd: 'bun', install: { macos: { manager: 'ensure-tools' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'darwin' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
grepq "$(echo "$outB1" | jq -er '.args[1]')" -F 'ensure_tools bun' \
  || fail "case b (install): expected 'ensure_tools bun' (got: $outB1)"
outB2=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'bun', cmd: 'bun', install: { macos: { manager: 'ensure-tools' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'darwin' };
console.log(JSON.stringify(buildDepEntry(dep, ctx, { upgrade: true })));
")
grepq "$(echo "$outB2" | jq -er '.args[1]')" -F '_ensure_install_bun' \
  || fail "case b (upgrade): expected '_ensure_install_bun' (got: $outB2)"
echo "ok: case b — bun ensure-tools: install -> ensure_tools bun, upgrade -> _ensure_install_bun"

# ── case c: manager:"brew" (install vs upgrade) ─────────────────────────────
outC1=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'node', cmd: 'node', install: { macos: { manager: 'brew', pkg: 'node' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'darwin' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
echo "$outC1" | jq -e '.args == ["-c","brew install \"$1\"","himmel-dep","node"]' >/dev/null \
  || fail "case c (install): unexpected args shape (got: $outC1)"
outC2=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'node', cmd: 'node', install: { macos: { manager: 'brew', pkg: 'node' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'darwin' };
console.log(JSON.stringify(buildDepEntry(dep, ctx, { upgrade: true })));
")
grepq "$(echo "$outC2" | jq -er '.args[1]')" -F 'brew upgrade' \
  || fail "case c (upgrade): expected 'brew upgrade' in the line (got: $outC2)"
# CodeRabbit: assert the COMPLETE documented upgrade shape — brew upgrade
# with its `|| brew install "$1"` fallback (and the literal "$1" placeholder),
# not just the 'brew upgrade' verb. (The "$1" is the literal positional-arg
# placeholder text, matched with grep -F — single-quoted so the shell never
# expands it.)
# shellcheck disable=SC2016
grepq "$(echo "$outC2" | jq -er '.args[1]')" -F 'brew upgrade "$1" 2>/dev/null || brew install "$1"' \
  || fail "case c (upgrade): expected the full 'brew upgrade ... || brew install' fallback line (got: $outC2)"
echo "ok: case c — manager:brew: install -> brew install, upgrade -> brew upgrade (fallback to install)"

# ── case d: manager:"winget" (install vs upgrade) ───────────────────────────
outD1=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'jq', cmd: 'jq', install: { win32: { manager: 'winget', id: 'jqlang.jq' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'win32' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
# shellcheck disable=SC2016
# Single-quoted on purpose — grep -F matches the LITERAL "$1" positional-arg
# placeholder text buildDepEntry emits, not an expanded shell variable.
grepq "$(echo "$outD1" | jq -er '.args[1]')" -F 'winget install --id "$1"' \
  || fail "case d (install): expected 'winget install --id \"\$1\"' (got: $outD1)"
# CodeRabbit: winget's required -e --silent flags must be present on install
# (exact-case match + non-interactive) — `--` so grep doesn't read the
# leading -e as one of its own flags.
grepq "$(echo "$outD1" | jq -er '.args[1]')" -F -- '-e --silent' \
  || fail "case d (install): winget line must carry '-e --silent' (got: $outD1)"
echo "$outD1" | jq -e '.args[-1] == "jqlang.jq"' >/dev/null \
  || fail "case d (install): the winget id should be the last positional arg (got: $outD1)"
outD2=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'jq', cmd: 'jq', install: { win32: { manager: 'winget', id: 'jqlang.jq' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'win32' };
console.log(JSON.stringify(buildDepEntry(dep, ctx, { upgrade: true })));
")
# shellcheck disable=SC2016
# Same as above — the literal "$1" placeholder text, not an expansion.
grepq "$(echo "$outD2" | jq -er '.args[1]')" -F 'winget upgrade --id "$1"' \
  || fail "case d (upgrade): expected 'winget upgrade --id \"\$1\"' (got: $outD2)"
# CodeRabbit: the same -e --silent flags are required on upgrade too.
grepq "$(echo "$outD2" | jq -er '.args[1]')" -F -- '-e --silent' \
  || fail "case d (upgrade): winget line must carry '-e --silent' (got: $outD2)"
echo "ok: case d — manager:winget: install -> winget install, upgrade -> winget upgrade"

# ── case e: manager:"pip" (install vs upgrade) ──────────────────────────────
outE1=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'uv', cmd: 'uv', install: { linux: { manager: 'pip', pkg: 'uv' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'linux' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
echo "$outE1" | jq -e '.args == ["-c","python3 -m pip install --user \"$1\"","himmel-dep","uv"]' >/dev/null \
  || fail "case e (install): unexpected args shape (got: $outE1)"
outE2=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'uv', cmd: 'uv', install: { linux: { manager: 'pip', pkg: 'uv' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'linux' };
console.log(JSON.stringify(buildDepEntry(dep, ctx, { upgrade: true })));
")
echo "$outE2" | jq -e '.args == ["-c","python3 -m pip install --user --upgrade \"$1\"","himmel-dep","uv"]' >/dev/null \
  || fail "case e (upgrade): expected --upgrade added (got: $outE2)"
echo "ok: case e — manager:pip: install has no --upgrade, upgrade adds it"

# ── case f: manager:"script" — same entry for install and upgrade ──────────
outF1=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'qmd', cmd: 'qmd', install: { linux: { manager: 'script', script: 'scripts/lib/qmd-bin.sh', args: ['install'] } } };
const ctx = { repoRoot: '/fake/repo', platform: 'linux' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
outF2=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'qmd', cmd: 'qmd', install: { linux: { manager: 'script', script: 'scripts/lib/qmd-bin.sh', args: ['install'] } } };
const ctx = { repoRoot: '/fake/repo', platform: 'linux' };
console.log(JSON.stringify(buildDepEntry(dep, ctx, { upgrade: true })));
")
[ "$outF1" = "$outF2" ] || fail "case f: manager:script should emit the SAME entry for install and upgrade (got install=$outF1 upgrade=$outF2)"
echo "$outF1" | jq -e '.cmd == "bash" and (.args[0] | contains("qmd-bin.sh")) and .args[1] == "install"' >/dev/null \
  || fail "case f: unexpected script entry shape (got: $outF1)"
echo "ok: case f — manager:script emits the same converging entry for both install and upgrade"

# ── case g: manager:"hint" -> unrunnable, never spawnable ──────────────────
outG=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'bun', cmd: 'bun', install: { win32: { manager: 'hint', detail: 'install manually: https://bun.sh' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'win32' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
echo "$outG" | jq -e '.unrunnable == "install manually: https://bun.sh" and (has("cmd") | not)' >/dev/null \
  || fail "case g: expected an unrunnable entry with no cmd (got: $outG)"
echo "ok: case g — manager:hint returns an unrunnable entry, never a spawnable one"

# ── case h: no recipe declared for the current OS -> unrunnable ────────────
outH=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'onlylinux', cmd: 'onlylinux', install: { linux: { manager: 'ensure-tools' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'win32' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
echo "$outH" | jq -e '.unrunnable | contains("win32")' >/dev/null \
  || fail "case h: expected the unrunnable reason to name the missing OS (got: $outH)"
echo "ok: case h — no recipe declared for the current OS yields an unrunnable entry naming it"

# ── case i: versionGte ──────────────────────────────────────────────────────
outI=$("$node_bin" -e "
const { versionGte } = require(process.env.DEPS_ENGINE_LIB);
console.log(JSON.stringify({
  below: versionGte('1.2.3', '1.3.0'),
  equal: versionGte('1.3.0', '1.3.0'),
  above: versionGte('2.0.0', '1.3.0'),
  vPrefix: versionGte('v24.3.0', '20.0.0'),
}));
")
echo "$outI" | jq -e '.below == false and .equal == true and .above == true and .vPrefix == true' >/dev/null \
  || fail "case i: unexpected versionGte results (got: $outI)"
echo "ok: case i — versionGte: below/equal/above a floor, and a v-prefixed actual, all correct"

# ═══════════════════════════════ e2e cases ══════════════════════════════════

# ── case j: --help / deps with no args list the deps verbs ────────────────
outJ=$(HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-help.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-help.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" --help)
grepq "$outJ" 'deps status' || fail "case j: --help should list 'deps status' (got: $outJ)"
grepq "$outJ" 'deps ensure' || fail "case j: --help should list 'deps ensure' (got: $outJ)"
grepq "$outJ" 'deps upgrade' || fail "case j: --help should list 'deps upgrade' (got: $outJ)"
echo "ok: case j — --help lists deps status|ensure|upgrade"

# ── case k: deps with no verb / an unknown verb -> exit 2 ─────────────────
set +e
errK1=$(HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-caseK.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-caseK.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" deps 2>&1); rcK1=$?
set -e
[ "$rcK1" -eq 2 ] || fail "case k: 'deps' with no verb should exit 2 (got rc=$rcK1): $errK1"
grepq "$errK1" -F 'status|ensure|upgrade' || fail "case k: error should name the verb requirement (got: $errK1)"
set +e
errK2=$(HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-caseK.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-caseK.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" deps bogus 2>&1); rcK2=$?
set -e
[ "$rcK2" -eq 2 ] || fail "case k: 'deps bogus' should exit 2 (got rc=$rcK2): $errK2"
echo "ok: case k — 'deps' with no verb or an unknown verb exits 2"

# ── shared fixture repo: a green dep (stubbed on PATH), a red dep (missing,
# manager:"script" pointing at a log-writing stub), and qmd (manager:
# "script" pointing at a SEPARATE log-writing stub — models pull target) ───
fixtureRepo="$work/repo"
mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/lib"
installLog="$work/install-calls.log"
modelsLog="$work/models-calls.log"
qmdResolver="$fixtureRepo/scripts/lib/fake-qmd-bin.sh"
# qmd's simulated presence is a MARKER FILE (not hardcoded), so the same
# fixture can prove both "qmd absent" (cases l/m/n/o/p, before the marker
# exists) and "qmd present" (cases q/r/s/t, after case q creates it) without
# needing a second resolver stub — has_qmd checks the marker, never PATH.
qmdPresentMarker="$work/qmd-present-marker"

# The "green" dep is a real stub binary on the hermetic PATH (built below);
# its --version output is fixed so status's detail is assertable. "red" and
# "qmd" are NOT on PATH — "red" is genuinely absent (which() fails); qmd's
# presence is controlled by qmdPresentMarker via the resolver's has_qmd, so
# it starts absent and its install/upgrade/model-pull commands still
# exercise real spawns against this stub either way.
cat > "$qmdResolver" <<STUB
#!/usr/bin/env bash
has_qmd() { [ -f "$(winpath "$qmdPresentMarker")" ]; }
qmd_cmd() {
  if [ "\$1" = "--version" ]; then echo "qmd 9.9.9 (stub)"; return 0; fi
  if [ "\$1" = "pull" ]; then printf 'pull\n' >> "$(winpath "$modelsLog")"; return 0; fi
  return 1
}
if [ "\${BASH_SOURCE[0]:-}" = "\${0:-}" ]; then
  case "\${1:-}" in
    # CR-fix companion: a CONVERGING qmd install creates the presence marker,
    # so cmdDepsEnsure's post-install re-probe (depStatus) reads qmd green and
    # KEEPS it in the installed count — the genuine-install path case p asserts
    # alongside redtool's non-converging fail-closed path.
    install) printf 'install\n' >> "$(winpath "$installLog")"; printf 'present\n' > "$(winpath "$qmdPresentMarker")" ;;
    *) exit 2 ;;
  esac
fi
STUB
chmod +x "$qmdResolver"

cat > "$fixtureRepo/scripts/install/deps.json" <<JSON
{
  "schemaVersion": 1,
  "deps": [
    {
      "id": "greentool",
      "cmd": "greentool",
      "versionProbe": { "args": ["--version"] },
      "minVersion": null,
      "bootstrap": false,
      "install": {
        "linux": { "manager": "script", "script": "scripts/lib/fake-install.sh", "args": ["greentool"] },
        "macos": { "manager": "script", "script": "scripts/lib/fake-install.sh", "args": ["greentool"] },
        "win32": { "manager": "script", "script": "scripts/lib/fake-install.sh", "args": ["greentool"] }
      }
    },
    {
      "id": "redtool",
      "cmd": "redtool-does-not-exist",
      "versionProbe": { "args": ["--version"] },
      "minVersion": null,
      "bootstrap": false,
      "install": {
        "linux": { "manager": "script", "script": "scripts/lib/fake-install.sh", "args": ["redtool"] },
        "macos": { "manager": "script", "script": "scripts/lib/fake-install.sh", "args": ["redtool"] },
        "win32": { "manager": "script", "script": "scripts/lib/fake-install.sh", "args": ["redtool"] }
      }
    },
    {
      "id": "qmd",
      "cmd": "qmd",
      "resolver": "scripts/lib/fake-qmd-bin.sh",
      "versionProbe": { "args": ["--version"] },
      "minVersion": null,
      "bootstrap": false,
      "install": {
        "linux": { "manager": "script", "script": "scripts/lib/fake-qmd-bin.sh", "args": ["install"] },
        "macos": { "manager": "script", "script": "scripts/lib/fake-qmd-bin.sh", "args": ["install"] },
        "win32": { "manager": "script", "script": "scripts/lib/fake-qmd-bin.sh", "args": ["install"] }
      }
    }
  ]
}
JSON

cat > "$fixtureRepo/scripts/lib/fake-install.sh" <<STUB
#!/usr/bin/env bash
printf 'install %s\n' "\$*" >> "$(winpath "$installLog")"
exit 0
STUB
chmod +x "$fixtureRepo/scripts/lib/fake-install.sh"

# ── hermetic PATH: greentool present with a fixed version, redtool absent ──
stub="$work/bin"; mkdir -p "$stub"
write_version_stub "$stub" greentool 3.2.1
link_hermetic_tool bash "$stub"
depsPath="$stub:$(scrub_path "$PATH" redtool-does-not-exist)"

runDeps() {
  # HIMMELCTL_INTERACTIVE is forced to 0 (never inherited from the test
  # host's own env) — hermeticity: a test host with an interactive TTY (or
  # a stray HIMMELCTL_INTERACTIVE=1 in the caller's shell) must not be able
  # to change these cases' non-interactive assertions mid-suite.
  HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_INTERACTIVE=0 PATH="$depsPath" \
    HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-runDeps.himmelctl-cache")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-runDeps.himmelctl-cache/luna-config.json")" \
    "$node_bin" "$wizard" deps "$@"
}

# ── case l: status — green/red rows + summary ───────────────────────────────
set +e
outL=$(runDeps status </dev/null 2>&1); rcL=$?
set -e
[ "$rcL" -eq 0 ] || fail "case l: deps status should exit 0 (got rc=$rcL): $outL"
grepq "$outL" -E 'green +greentool +present \(3\.2\.1\)' \
  || fail "case l: greentool should read green with its version (got: $outL)"
grepq "$outL" -E "red +redtool +'redtool-does-not-exist' not found on PATH" \
  || fail "case l: redtool should read red naming the missing cmd (got: $outL)"
grepq "$outL" -E '^red +qmd' \
  || fail "case l: qmd should also read red (marker not yet created — got: $outL)"
grepq "$outL" -F '2 red, 0 degraded, 1 green' \
  || fail "case l: summary should be '2 red, 0 degraded, 1 green' (redtool + qmd both absent — got: $outL)"
echo "ok: case l — deps status: green/red rows with correct detail, summary matches"

# ── case m: status --json determinism ───────────────────────────────────────
outM1=$(runDeps status --json </dev/null)
outM2=$(runDeps status --json </dev/null)
[ "$outM1" = "$outM2" ] || fail "case m: two consecutive --json runs should be byte-identical"
echo "$outM1" | jq -e . >/dev/null || fail "case m: --json output should be valid JSON"
echo "$outM1" | jq -e '.deps | length == 3' >/dev/null || fail "case m: expected 3 deps in --json output (got: $outM1)"
echo "ok: case m — deps status --json: valid, deterministic JSON"

# ── case n: ensure --dry-run — DRY lines only, nothing executed ───────────
rm -f "$installLog"
set +e
outN=$(runDeps ensure --dry-run </dev/null 2>&1); rcN=$?
set -e
[ "$rcN" -eq 0 ] || fail "case n: ensure --dry-run should exit 0 (both missing recipes are runnable — got rc=$rcN): $outN"
grepq "$outN" -F 'DRY:' || fail "case n: expected DRY: lines (got: $outN)"
# Assert the SPECIFIC planned actions, not just "some DRY line" — one line
# per missing dep (redtool, qmd), each naming its script recipe + args.
grepq "$outN" -F 'fake-install.sh' || fail "case n: expected redtool's install script path in the DRY plan (got: $outN)"
grepq "$outN" -E 'fake-install\.sh[^[:space:]]* redtool' || fail "case n: expected redtool's script arg in the DRY plan (got: $outN)"
grepq "$outN" -F 'fake-qmd-bin.sh' || fail "case n: expected qmd's install script path in the DRY plan (got: $outN)"
grepq "$outN" -E 'fake-qmd-bin\.sh[^[:space:]]* install' || fail "case n: expected qmd's 'install' arg in the DRY plan (got: $outN)"
[ -f "$installLog" ] && fail "case n: --dry-run must NOT execute the install script (got: $(cat "$installLog")))"
echo "ok: case n — ensure --dry-run prints DRY lines naming every planned dep + recipe, executes nothing"

# ── case o: ensure, non-interactive, no --yes -> exit 2 ────────────────────
rm -f "$installLog"
set +e
errO=$(runDeps ensure </dev/null 2>&1); rcO=$?
set -e
[ "$rcO" -eq 2 ] || fail "case o: non-interactive ensure without --yes should exit 2 (got rc=$rcO): $errO"
grepq "$errO" -F 'requires --yes' || fail "case o: error should name the --yes requirement (got: $errO)"
[ -f "$installLog" ] && fail "case o: a refused ensure must NOT execute the install script"
echo "ok: case o — ensure non-interactive without --yes exits 2, nothing executed"

# ── case p: ensure --yes — recipes run; re-probe fail-closes the one that
# didn't land, keeps the one that did. CR fix (CodeRabbit MAJOR): an install
# that exits 0 but leaves the tool off PATH must now be re-probed and reported
# FAILED, not silently counted as installed. redtool's stub writes its log
# line but never puts 'redtool-does-not-exist' on PATH -> re-probe red ->
# 'installed but still not found on PATH', exit 1. qmd's stub CONVERGES
# (creates the presence marker) -> re-probe green -> stays installed. So the
# summary reads '1 installed, 1 failed' and exit is 1 — exercising BOTH the
# genuine-install (kept) and non-converging (fail-closed) paths in one case. ─
rm -f "$installLog" "$qmdPresentMarker"
set +e
outP=$(runDeps ensure --yes </dev/null 2>&1); rcP=$?
set -e
[ "$rcP" -eq 1 ] || fail "case p: ensure --yes should exit 1 when an install didn't land (got rc=$rcP): $outP"
[ -f "$installLog" ] || fail "case p: expected the install script to have run (no log file)"
grep -qF 'redtool' "$installLog" || fail "case p: install log should reference redtool (got: $(cat "$installLog"))"
# qmd's OWN distinct install entry — fake-qmd-bin.sh writes a bare 'install'
# line, separate from redtool's 'install redtool'. Whole-line match (-x) so
# 'install redtool' doesn't satisfy it.
grep -qxF 'install' "$installLog" || fail "case p: install log should contain qmd's distinct 'install' entry (got: $(cat "$installLog"))"
# qmd's install CONVERGED -> the presence marker now exists (re-probe reads it).
[ -f "$qmdPresentMarker" ] || fail "case p: qmd's converging install should have created the presence marker"
# redtool's install did NOT land -> the re-probe fail-closed reason is printed.
grepq "$outP" -F 'redtool: installed but still not found on PATH' \
  || fail "case p: redtool should be reported failed with the re-probe reason (got: $outP)"
grepq "$outP" -F '1 installed, 1 failed' \
  || fail "case p: expected '1 installed, 1 failed' (qmd converged, redtool didn't — got: $outP)"
echo "ok: case p — ensure --yes re-probes: qmd kept (converged), redtool fail-closed (didn't land)"

# ── case q: ensure when nothing is missing -> nothing to converge ──────────
# Creates qmdPresentMarker (qmd now reads present, for THIS and every
# subsequent case — the upgrade cases r/s/t rely on qmd being present so
# their upgrade recipe + model-pull gating actually exercise something) and
# builds a PATH where redtool is ALSO present, so every declared dep reads
# green and ensure has nothing left to converge.
stubQ="$work/bin-all-present"; mkdir -p "$stubQ"
write_version_stub "$stubQ" greentool 3.2.1
write_version_stub "$stubQ" redtool-does-not-exist 1.0.0
link_hermetic_tool bash "$stubQ"
echo present > "$qmdPresentMarker"
rm -f "$installLog"
# PREPEND stubQ to the real PATH (never stub-only) — link_hermetic_tool's
# `ln -s` fallback can silently produce a same-effect COPY of bash rather
# than a real symlink (observed on this host: no admin/dev-mode symlink
# privilege), and a copied bash.exe needs its sibling DLLs (msys-2.0.dll
# etc.) discoverable via Windows' PATH-based DLL search — which only works
# when bash's REAL original directory stays somewhere on PATH. Mirrors
# every sibling suite's own build_path() (stub + scrubbed real PATH, never
# stub-only) for exactly this reason.
depsPathQ="$stubQ:$PATH"
set +e
outQ=$(HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" PATH="$depsPathQ" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-caseQ.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-caseQ.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" deps ensure --yes </dev/null 2>&1); rcQ=$?
set -e
[ "$rcQ" -eq 0 ] || fail "case q: ensure with nothing missing should exit 0 (got rc=$rcQ): $outQ"
grepq "$outQ" -F 'nothing to converge' || fail "case q: expected the nothing-to-converge message (got: $outQ)"
[ -f "$installLog" ] && fail "case q: nothing should have been installed (got: $(cat "$installLog"))"
echo "ok: case q — ensure with every declared dep present prints 'nothing to converge', exit 0, no install run"

# ── case r: upgrade --yes — recipe runs, qmd model pull skipped (no prompt,
# not --with-models) ────────────────────────────────────────────────────────
rm -f "$installLog" "$modelsLog"
set +e
outR=$(runDeps upgrade --yes </dev/null 2>&1); rcR=$?
set -e
[ "$rcR" -eq 0 ] || fail "case r: upgrade --yes should exit 0 (got rc=$rcR): $outR"
# redtool stays absent on depsPath (not present-side), so the present set is
# exactly [greentool, qmd] — both manager:script, so upgrading them appends
# to installLog (qmd's marker was set present by case q, above).
[ -f "$installLog" ] || fail "case r: expected greentool/qmd's upgrade scripts to have run (no log file)"
grep -qF 'greentool' "$installLog" || fail "case r: install log should reference greentool (got: $(cat "$installLog"))"
# CodeRabbit: qmd's distinct upgrade entry (bare 'install' line) too, not
# only greentool's 'install greentool'.
grep -qxF 'install' "$installLog" || fail "case r: install log should contain qmd's distinct 'install' entry (got: $(cat "$installLog"))"
grepq "$outR" -F 'skipping qmd model pull' \
  || fail "case r: expected the qmd model-pull skip message (non-interactive, no --with-models) (got: $outR)"
[ -f "$modelsLog" ] && fail "case r: the model pull must NOT have run without --with-models (got: $(cat "$modelsLog"))"
echo "ok: case r — upgrade --yes runs present deps' recipes, skips the qmd model pull without --with-models"

# ── case s: upgrade --yes --with-models — the model pull ALSO runs ────────
rm -f "$installLog" "$modelsLog"
set +e
outS=$(runDeps upgrade --yes --with-models </dev/null 2>&1); rcS=$?
set -e
[ "$rcS" -eq 0 ] || fail "case s: upgrade --yes --with-models should exit 0 (got rc=$rcS): $outS"
[ -f "$modelsLog" ] || fail "case s: expected the qmd model-pull stub to have run (no log file)"
grep -qF 'pull' "$modelsLog" || fail "case s: models log should record the pull (got: $(cat "$modelsLog"))"
# CodeRabbit: --with-models runs EACH present dep's upgrade recipe (-> installLog)
# as well as the model pull (-> modelsLog) — assert qmd's distinct upgrade entry
# in installLog too, not only the pull line in modelsLog.
[ -f "$installLog" ] || fail "case s: expected greentool/qmd's upgrade scripts to have run (no install log file)"
grep -qxF 'install' "$installLog" || fail "case s: install log should contain qmd's distinct 'install' entry (got: $(cat "$installLog"))"
grepq "$outS" -F 'skipping qmd model pull' \
  && fail "case s: --with-models must NOT print the skip message (got: $outS)"
echo "ok: case s — upgrade --yes --with-models also runs the qmd model pull, no prompt shown"

# ── case t: upgrade --dry-run — DRY lines only, nothing executed ──────────
rm -f "$installLog" "$modelsLog"
set +e
outT=$(runDeps upgrade --dry-run </dev/null 2>&1); rcT=$?
set -e
[ "$rcT" -eq 0 ] || fail "case t: upgrade --dry-run should exit 0 for these runnable recipes (got rc=$rcT): $outT"
grepq "$outT" -F 'DRY:' || fail "case t: expected DRY: lines (got: $outT)"
# Assert the SPECIFIC planned actions — present set is [greentool, qmd]
# (redtool stays absent on depsPath), plus the qmd model-pull prompt DRY
# line (no --with-models passed).
grepq "$outT" -F 'fake-install.sh' || fail "case t: expected greentool's upgrade script path in the DRY plan (got: $outT)"
grepq "$outT" -E 'fake-install\.sh[^[:space:]]* greentool' || fail "case t: expected greentool's script arg in the DRY plan (got: $outT)"
grepq "$outT" -F 'fake-qmd-bin.sh' || fail "case t: expected qmd's upgrade script path in the DRY plan (got: $outT)"
grepq "$outT" -E 'fake-qmd-bin\.sh[^[:space:]]* install' || fail "case t: expected qmd's 'install' arg in the DRY plan (got: $outT)"
grepq "$outT" -F 'prompt to pull qmd embedding/rerank models' || fail "case t: expected the qmd model-pull DRY prompt line (got: $outT)"
[ -f "$installLog" ] && fail "case t: --dry-run must NOT execute the upgrade script"
[ -f "$modelsLog" ] && fail "case t: --dry-run must NOT execute the model pull"
echo "ok: case t — upgrade --dry-run prints DRY lines naming every planned dep + recipe + the model-pull prompt, executes nothing"

# ═══════════════ HIMMEL-2438: `deps ensure` on stock Ubuntu ════════════════
#
# himmelctl deps ensure --yes installed 0/4 declared deps on a stock Ubuntu
# box (HIMMEL-2438): apt-get ran unprivileged with no explanation, gitleaks
# had no apt recipe at all, bun's freshly-installed binary was invisible to
# the same run's later deps (qmd) and to the post-install re-probe, and a
# converged-but-off-PATH install was double-counted as both "installed" and
# "failed". Cases u-aa below cover the five fixes.

# ── case u: deps.json's declared order keeps bun before qmd — the plan order
# `missing.map(...)` in cmdDepsEnsure derives from is order-preserving by
# construction (deps.map(...).filter(...)), so this is a property of the
# DECLARATION, not something cmdDepsEnsure computes itself. Asserted against
# the REAL deps.json (not a synthetic fixture) since the invariant is about
# that file's own declared order. ───────────────────────────────────────────
outU=$(HIMMELCTL_REAL_REPO_ROOT="$repo_root" "$node_bin" -e "
const { loadDeps } = require(process.env.DEPS_ENGINE_LIB);
const deps = loadDeps(process.env.HIMMELCTL_REAL_REPO_ROOT);
console.log(JSON.stringify(deps.filter((d) => d.id === 'bun' || d.id === 'qmd').map((d) => d.id)));
")
echo "$outU" | jq -e '. == ["bun","qmd"]' >/dev/null \
  || fail "case u: expected deps.json's declared order to place bun before qmd (preserved by the order-preserving filter/map construction ensure's plan uses) (got: $outU)"
echo "ok: case u — deps.json declares bun before qmd; the order-preserving plan construction keeps it that way"

# ── case bb: deps.json — gitleaks installs via the package manager on linux
# (HIMMEL-2438 defect 2: it used to be manager:"hint" with no apt recipe at
# all, despite shellcheck already using the same apt-get path), keeping its
# macos brew / win32 winget recipes untouched. ─────────────────────────────
gitleaksLinuxManager=$(jq -r '.deps[] | select(.id=="gitleaks") | .install.linux.manager' "$repo_root/scripts/install/deps.json")
[ "$gitleaksLinuxManager" = "ensure-tools" ] \
  || fail "case bb: gitleaks's linux install manager should be 'ensure-tools' (got: $gitleaksLinuxManager)"
gitleaksMacManager=$(jq -r '.deps[] | select(.id=="gitleaks") | .install.macos.manager' "$repo_root/scripts/install/deps.json")
[ "$gitleaksMacManager" = "brew" ] \
  || fail "case bb: gitleaks's macos install manager should stay 'brew' (got: $gitleaksMacManager)"
gitleaksWinManager=$(jq -r '.deps[] | select(.id=="gitleaks") | .install.win32.manager' "$repo_root/scripts/install/deps.json")
[ "$gitleaksWinManager" = "winget" ] \
  || fail "case bb: gitleaks's win32 install manager should stay 'winget' (got: $gitleaksWinManager)"
echo "ok: case bb — deps.json: gitleaks installs via ensure-tools on linux, brew on macos, winget on win32 (unchanged)"

# ═════════════ ensure-tools.sh cases (sourced in a fresh subshell) ═════════
#
# Every case below sources scripts/setup/ensure-tools.sh in a NEW bash
# process under a stub-prepended PATH — real sudo/apt-get/curl on THIS
# station are never reached because the stub dir is prepended ahead of the
# real PATH, so `command -v` always resolves the stub first. Coreutils
# (mktemp/grep/tail/rm/chmod/cat) are left to resolve from the real PATH —
# only the specific privileged/network primitives are stubbed.
ensureToolsScript="$repo_root/scripts/setup/ensure-tools.sh"

# run_ensure_tools <PATH> <HOME> <tool...> — sources ensure-tools.sh in a
# fresh bash -c and calls ensure_tools "$@" with the given tools; combined
# stdout+stderr.
run_ensure_tools() {
  local _path="$1" _home="$2"; shift 2
  PATH="$_path" HOME="$_home" bash -c '. "$1"; shift; ensure_tools "$@"' _ "$ensureToolsScript" "$@" 2>&1
}

# mk_ensure_tools_path <target-tool> <dest-dir> — links bash/mktemp/grep/
# tail/rm into <dest-dir> (created here) from the CURRENT real PATH, then
# echoes "<dest-dir>:<PATH with every dir carrying <target-tool> dropped>".
# Needed because THIS station has git/jq/python3/shellcheck/gitleaks all
# genuinely installed (same merged /usr/bin as every coreutil) — a bare
# stub-dir PREPEND (test-setup-preflight.sh's simpler convention) would let
# `command -v "$t"` still resolve the REAL tool further down PATH, so
# ensure_tools' own "already present" guard would skip the install path
# before ever reaching sudo/apt-get — proving nothing. Dropping the whole
# dir that carries <target-tool> takes the coreutils sourced from that same
# dir down with it, hence relinking the specific ones ensure_tools' own
# privileged path needs.
mk_ensure_tools_path() {
  local _target="$1" _dir="$2" _tool
  mkdir -p "$_dir"
  for _tool in bash mktemp grep tail rm; do
    link_hermetic_tool "$_tool" "$_dir"
  done
  printf '%s' "$_dir:$(scrub_path "$PATH" "$_target")"
}

# ── case v: privilege probe — non-root, sudo present but NOT passwordless
# (`sudo -n true` fails, e.g. a password is required) -> the adopter is told
# the EXACT privileged command to run themselves, and apt-get is NEVER
# invoked (HIMMEL-2438 defect 1: apt-get used to run unprivileged and fail
# with a mystery "install manually" message that never named the real
# cause). ────────────────────────────────────────────────────────────────
vdir="$work/case-v-bin"
vhpath=$(mk_ensure_tools_path shellcheck "$vdir")
vlog="$work/case-v-priv.log"
printf '#!/bin/sh\necho 1000\n' > "$vdir/id"; chmod +x "$vdir/id"
# sudo exists but refuses the non-interactive probe. ANY invocation is
# logged; a call OTHER than the "-n true" probe proves the probe was
# skipped and a privileged call was attempted anyway — fail loud.
cat > "$vdir/sudo" <<SUDO
#!/usr/bin/env bash
echo "sudo \$*" >> "$(winpath "$vlog")"
if [ "\$1" = "-n" ] && [ "\$2" = "true" ] && [ "\$#" -eq 2 ]; then exit 1; fi
exit 1
SUDO
chmod +x "$vdir/sudo"
cat > "$vdir/apt-get" <<AG
#!/usr/bin/env bash
echo "apt-get \$*" >> "$(winpath "$vlog")"
exit 0
AG
chmod +x "$vdir/apt-get"
rm -f "$vlog"
outV=$(run_ensure_tools "$vhpath" "$work/case-v-home" shellcheck)
grep -qF 'apt-get' "$vlog" 2>/dev/null && fail "case v: apt-get must NEVER be invoked once the non-interactive sudo probe refuses (got: $(cat "$vlog"))"
grepq "$(cat "$vlog" 2>/dev/null)" -F 'sudo -n true' || fail "case v: expected the non-interactive probe 'sudo -n true' to have run (got: $(cat "$vlog" 2>/dev/null))"
grepq "$outV" -F 'sudo apt-get install -y shellcheck' \
  || fail "case v: expected the exact privileged command named in the message (got: $outV)"
echo "ok: case v — no passwordless sudo: names the exact privileged command, never calls apt-get"

# ── case w: privilege probe succeeds (`sudo -n true` works) -> the actual
# apt-get calls are routed through `sudo -n` (never bare sudo, which could
# hang the run on a password prompt). ──────────────────────────────────────
wdir="$work/case-w-bin"
whpath=$(mk_ensure_tools_path shellcheck "$wdir")
wsudoLog="$work/case-w-sudo.log"
printf '#!/bin/sh\necho 1000\n' > "$wdir/id"; chmod +x "$wdir/id"
cat > "$wdir/sudo" <<SUDO
#!/usr/bin/env bash
echo "sudo \$*" >> "$(winpath "$wsudoLog")"
if [ "\$1" = "-n" ]; then shift; fi
if [ "\$1" = "true" ] && [ "\$#" -eq 1 ]; then exit 0; fi
exec "\$@"
SUDO
chmod +x "$wdir/sudo"
waptLog="$work/case-w-aptget.log"
cat > "$wdir/apt-get" <<AG
#!/usr/bin/env bash
echo "apt-get \$*" >> "$(winpath "$waptLog")"
exit 0
AG
chmod +x "$wdir/apt-get"
rm -f "$wsudoLog" "$waptLog"
outW=$(run_ensure_tools "$whpath" "$work/case-w-home" shellcheck)
grepq "$(cat "$wsudoLog" 2>/dev/null)" -F 'sudo -n true' || fail "case w: expected the passwordless probe to have run (got: $(cat "$wsudoLog" 2>/dev/null))"
grepq "$(cat "$wsudoLog" 2>/dev/null)" -F 'sudo -n apt-get install -y shellcheck' \
  || fail "case w: expected the real install call to be routed through 'sudo -n' (got: $(cat "$wsudoLog" 2>/dev/null))"
[ -f "$waptLog" ] || fail "case w: expected apt-get to have actually run (no log file)"
grepq "$outW" -F "installing 'shellcheck' via apt-get" || fail "case w: expected the installing message (got: $outW)"
echo "ok: case w — passwordless sudo: the real install call is routed through 'sudo -n'"

# ── case x: apt-get install FAILS (package genuinely missing on this distro)
# -> the failure message surfaces apt-get's own last non-empty stderr line
# instead of swallowing it, and — for a tool with no fallback hint — still
# ends with the honest "install manually" (HIMMEL-2438 defect 1: stderr used
# to be redirected straight to /dev/null, so the adopter never learned WHY
# the install failed). ─────────────────────────────────────────────────────
xdir="$work/case-x-bin"
xhpath=$(mk_ensure_tools_path shellcheck "$xdir")
printf '#!/bin/sh\necho 1000\n' > "$xdir/id"; chmod +x "$xdir/id"
cat > "$xdir/sudo" <<'SUDO'
#!/usr/bin/env bash
if [ "$1" = "-n" ]; then shift; fi
if [ "$1" = "true" ] && [ "$#" -eq 1 ]; then exit 0; fi
exec "$@"
SUDO
chmod +x "$xdir/sudo"
cat > "$xdir/apt-get" <<'AG'
#!/usr/bin/env bash
if [ "$1" = "update" ]; then exit 0; fi
echo "Reading package lists..." >&2
echo "" >&2
echo "E: Unable to locate package shellcheck" >&2
exit 100
AG
chmod +x "$xdir/apt-get"
outX=$(run_ensure_tools "$xhpath" "$work/case-x-home" shellcheck)
grepq "$outX" -F "'apt-get install shellcheck' failed" || fail "case x: expected the failure message to name the failed command (got: $outX)"
grepq "$outX" -F 'E: Unable to locate package shellcheck' \
  || fail "case x: expected apt-get's own last non-empty stderr line surfaced (got: $outX)"
grepq "$outX" -F "install 'shellcheck' manually" || fail "case x: shellcheck has no fallback hint -- expected the generic manual-install fallback (got: $outX)"
echo "ok: case x — apt-get install failure surfaces its own stderr tail instead of swallowing it"

# ── case y: gitleaks — installable via the SAME apt-get path shellcheck
# uses (HIMMEL-2438 defect 2), and its failure message (older distro, no
# package) carries the old 'hint' manager's tarball guidance as a per-tool
# fallback, not a bare "install manually". ─────────────────────────────────
ydir="$work/case-y-bin"
yhpath=$(mk_ensure_tools_path gitleaks "$ydir")
printf '#!/bin/sh\necho 1000\n' > "$ydir/id"; chmod +x "$ydir/id"
cat > "$ydir/sudo" <<'SUDO'
#!/usr/bin/env bash
if [ "$1" = "-n" ]; then shift; fi
if [ "$1" = "true" ] && [ "$#" -eq 1 ]; then exit 0; fi
exec "$@"
SUDO
chmod +x "$ydir/sudo"
yaptLog="$work/case-y-aptget.log"
cat > "$ydir/apt-get" <<AG
#!/usr/bin/env bash
echo "apt-get \$*" >> "$(winpath "$yaptLog")"
if [ "\$1" = "update" ]; then exit 0; fi
echo "E: Unable to locate package gitleaks" >&2
exit 100
AG
chmod +x "$ydir/apt-get"
rm -f "$yaptLog"
outY=$(run_ensure_tools "$yhpath" "$work/case-y-home" gitleaks)
grepq "$(cat "$yaptLog" 2>/dev/null)" -F 'apt-get install -y gitleaks' \
  || fail "case y: expected gitleaks to be routed through the SAME apt-get install path as shellcheck (got: $(cat "$yaptLog" 2>/dev/null))"
grepq "$outY" -F "'apt-get install gitleaks' failed" || fail "case y: expected the failure message to name gitleaks (got: $outY)"
grepq "$outY" -F 'E: Unable to locate package gitleaks' || fail "case y: expected apt-get's stderr tail surfaced (got: $outY)"
grepq "$outY" -F 'install gitleaks from its official release tarball, then re-run' \
  || fail "case y: expected the old hint-manager's tarball guidance as gitleaks's fallback hint (got: $outY)"
echo "ok: case y — gitleaks: apt-get install attempted, failure carries the tarball fallback hint"

# ── case z: bun already installed at ~/.bun/bin -> idempotent, no re-run of
# the official installer (HIMMEL-2438: a re-run used to append a SECOND
# identical PATH block to ~/.bashrc every time). curl must never be invoked.
zdir="$work/case-z-bin"; mkdir -p "$zdir"
zcurlLog="$work/case-z-curl.log"
cat > "$zdir/curl" <<CURL
#!/usr/bin/env bash
echo "curl \$*" >> "$(winpath "$zcurlLog")"
exit 1
CURL
chmod +x "$zdir/curl"
zhome="$work/case-z-home"; mkdir -p "$zhome/.bun/bin"
printf '#!/usr/bin/env bash\necho stub-bun\n' > "$zhome/.bun/bin/bun"; chmod +x "$zhome/.bun/bin/bun"
rm -f "$zcurlLog"
outZ=$(PATH="$zdir:$PATH" HOME="$zhome" bash -c '. "$1"; _ensure_install_bun' _ "$ensureToolsScript" 2>&1)
[ -f "$zcurlLog" ] && fail "case z: bun already installed -- the official installer (curl) must NOT be re-run (got: $(cat "$zcurlLog"))"
grepq "$outZ" -F 'bun is already installed at ~/.bun/bin' \
  || fail "case z: expected the already-installed notice (got: $outZ)"
# shellcheck disable=SC2016
grepq "$outZ" -F 'export PATH="$HOME/.bun/bin:$PATH"' \
  || fail "case z: expected the shell-rc hint with the export line (got: $outZ)"
echo "ok: case z — bun already installed: idempotent, no reinstall, PATH hint printed"

# ── case aa: cmdDepsEnsure re-resolves PATH for THIS run (HIMMEL-2438 defect
# 3) and the honest counter (defect 5 in bin.js's own report): a dep whose
# install recipe lands its binary in $HOME/.bun/bin (mirrors bun's own
# official installer) is invisible to the caller's PATH, but the
# post-install re-probe must resolve it via the augmented PATH instead of
# reporting the CR-fixed "installed but still not found on PATH" false
# failure — and must say so explicitly (present via the augmented PATH, not
# the caller's own), not just silently count it a win. A SEPARATE, isolated
# fixture repo (not the shared one cases l-t use) so this doesn't perturb
# their counts. ─────────────────────────────────────────────────────────────
fixtureRepoAA="$work/repo-aa"
mkdir -p "$fixtureRepoAA/scripts/install" "$fixtureRepoAA/scripts/lib"
installLogAA="$work/install-calls-aa.log"
homeAA="$work/case-aa-home"; mkdir -p "$homeAA"
cat > "$fixtureRepoAA/scripts/install/deps.json" <<JSON
{
  "schemaVersion": 1,
  "deps": [
    {
      "id": "hometool",
      "cmd": "hometool-not-on-path",
      "versionProbe": { "args": ["--version"] },
      "minVersion": null,
      "bootstrap": false,
      "install": {
        "linux": { "manager": "script", "script": "scripts/lib/fake-hometool-install.sh", "args": [] },
        "macos": { "manager": "script", "script": "scripts/lib/fake-hometool-install.sh", "args": [] },
        "win32": { "manager": "script", "script": "scripts/lib/fake-hometool-install.sh", "args": [] }
      }
    }
  ]
}
JSON
cat > "$fixtureRepoAA/scripts/lib/fake-hometool-install.sh" <<STUB
#!/usr/bin/env bash
printf 'install\n' >> "$(winpath "$installLogAA")"
mkdir -p "\$HOME/.bun/bin"
printf '#!/usr/bin/env bash\necho stub-hometool\n' > "\$HOME/.bun/bin/hometool-not-on-path"
chmod +x "\$HOME/.bun/bin/hometool-not-on-path"
STUB
chmod +x "$fixtureRepoAA/scripts/lib/fake-hometool-install.sh"

stubAA="$work/bin-aa"; mkdir -p "$stubAA"
link_hermetic_tool bash "$stubAA"
depsPathAA="$stubAA:$(scrub_path "$PATH" hometool-not-on-path)"

set +e
outAA=$(HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoAA")" HIMMELCTL_INTERACTIVE=0 PATH="$depsPathAA" HOME="$(winpath "$homeAA")" USERPROFILE="$(winpath "$homeAA")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-caseAA.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-caseAA.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" deps ensure --yes </dev/null 2>&1); rcAA=$?
set -e
[ "$rcAA" -eq 0 ] || fail "case aa: ensure --yes should exit 0 once the augmented-PATH re-probe finds hometool (got rc=$rcAA): $outAA"
[ -f "$installLogAA" ] || fail "case aa: expected hometool's install script to have run (no log file)"
grepq "$outAA" -F 'himmelctl: PATH for this run also includes' \
  || fail "case aa: expected the augmented-PATH announcement line (got: $outAA)"
grepq "$outAA" -F '.bun/bin' || fail "case aa: the announcement should name ~/.bun/bin (got: $outAA)"
grepq "$outAA" -F '1 installed, 0 failed' \
  || fail "case aa: hometool should be counted installed, not a false PATH failure (got: $outAA)"
grepq "$outAA" -F 'hometool: installed to' || fail "case aa: expected the honest not-on-caller's-PATH message (got: $outAA)"
grepq "$outAA" -F 'not on your PATH; add' || fail "case aa: expected the shell-rc hint (got: $outAA)"
echo "ok: case aa — cmdDepsEnsure re-resolves PATH mid-run; a dep landing in ~/.bun/bin is verified + honestly reported, not falsely failed"

# ── case cc: a dep a PRIOR run already installed into $HOME/.bun/bin (CR
# round 1, codex-1) — present via the augmented PATH from the START of the
# run, never on the caller's own PATH — must NOT appear in the `--dry-run`
# plan or the "about to install" list; `ensure --yes` (it's the only
# declared dep) reports "nothing to converge" and NEVER invokes the install
# script. Distinct from case aa: there, the binary doesn't exist until the
# install script CREATES it during THIS run; here, it already exists BEFORE
# the run starts, so it must never be re-planned at all. A SEPARATE isolated
# fixture (own repo/home/log), same convention as case aa. ────────────────
fixtureRepoCC="$work/repo-cc"
mkdir -p "$fixtureRepoCC/scripts/install" "$fixtureRepoCC/scripts/lib"
installLogCC="$work/install-calls-cc.log"
homeCC="$work/case-cc-home"; mkdir -p "$homeCC/.bun/bin"
printf '#!/usr/bin/env bash\necho stub-hometool\n' > "$homeCC/.bun/bin/hometool-not-on-path"
chmod +x "$homeCC/.bun/bin/hometool-not-on-path"
cat > "$fixtureRepoCC/scripts/install/deps.json" <<JSON
{
  "schemaVersion": 1,
  "deps": [
    {
      "id": "hometool",
      "cmd": "hometool-not-on-path",
      "versionProbe": { "args": ["--version"] },
      "minVersion": null,
      "bootstrap": false,
      "install": {
        "linux": { "manager": "script", "script": "scripts/lib/fake-hometool-install.sh", "args": [] },
        "macos": { "manager": "script", "script": "scripts/lib/fake-hometool-install.sh", "args": [] },
        "win32": { "manager": "script", "script": "scripts/lib/fake-hometool-install.sh", "args": [] }
      }
    }
  ]
}
JSON
cat > "$fixtureRepoCC/scripts/lib/fake-hometool-install.sh" <<STUB
#!/usr/bin/env bash
printf 'install\n' >> "$(winpath "$installLogCC")"
STUB
chmod +x "$fixtureRepoCC/scripts/lib/fake-hometool-install.sh"

stubCC="$work/bin-cc"; mkdir -p "$stubCC"
link_hermetic_tool bash "$stubCC"
depsPathCC="$stubCC:$(scrub_path "$PATH" hometool-not-on-path)"

rm -f "$installLogCC"
set +e
outCCdry=$(HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoCC")" HIMMELCTL_INTERACTIVE=0 PATH="$depsPathCC" HOME="$(winpath "$homeCC")" USERPROFILE="$(winpath "$homeCC")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-caseCC-dry.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-caseCC-dry.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" deps ensure --dry-run </dev/null 2>&1); rcCCdry=$?
set -e
[ "$rcCCdry" -eq 0 ] || fail "case cc (dry-run): should exit 0 -- hometool is already present via the augmented PATH, nothing to plan (got rc=$rcCCdry): $outCCdry"
grepq "$outCCdry" -F 'nothing to converge' || fail "case cc (dry-run): expected 'nothing to converge' -- a PRIOR run's install must not be re-planned (got: $outCCdry)"
grepq "$outCCdry" -F 'DRY:' && fail "case cc (dry-run): a dep already present via the augmented PATH must NOT appear in the DRY plan (got: $outCCdry)"
grepq "$outCCdry" -F 'hometool' && fail "case cc (dry-run): hometool must not be named at all -- it never needed converging (got: $outCCdry)"

set +e
outCC=$(HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoCC")" HIMMELCTL_INTERACTIVE=0 PATH="$depsPathCC" HOME="$(winpath "$homeCC")" USERPROFILE="$(winpath "$homeCC")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-caseCC.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-caseCC.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" deps ensure --yes </dev/null 2>&1); rcCC=$?
set -e
[ "$rcCC" -eq 0 ] || fail "case cc: ensure --yes should exit 0 (got rc=$rcCC): $outCC"
grepq "$outCC" -F 'nothing to converge' || fail "case cc: expected 'nothing to converge' (got: $outCC)"
grepq "$outCC" -F 'about to install' && fail "case cc: must NEVER print 'about to install' for a dep already present via the augmented PATH (got: $outCC)"
[ -f "$installLogCC" ] && fail "case cc: the install script must NEVER run -- hometool was already present via the augmented PATH from the START of the run (got: $(cat "$installLogCC"))"
echo "ok: case cc — a dep a PRIOR run already installed into ~/.bun/bin reads present from the START of the run (never replanned, never re-installed)"

# ── case dd: augmentPathForRun (the extracted pure PATH-augmentation
# helper) — an EMPTY originalPath must not leave a trailing path.delimiter
# or an empty PATH segment (CR round 1, codex-2: the old
# `dirsToAdd.join(delim) + delim + originalPath` formula did exactly that
# whenever originalPath was ""; a trailing/empty segment means an implicit-
# cwd PATH lookup). Unit-tested directly via require() — bin.js's own CLI
# auto-run is guarded behind `require.main === module`, so requiring it here
# never triggers main() — because the trailing-delimiter shape is NOT
# observable from a live e2e invocation: the "PATH for this run also
# includes" announcement only lists dirsToAdd by NAME, never the joined PATH
# string itself, so a PATH="" e2e run cannot prove this one way or the
# other. ─────────────────────────────────────────────────────────────────
# The expectations are DERIVED from node's own path.delimiter / path.join
# rather than hard-coded as ":"-joined POSIX strings: under Windows node
# the delimiter is ";" and path.join emits backslashes, so literal
# expectations would fail there for a reason that has nothing to do with
# the behaviour under test (this suite runs under Git Bash on Windows too
# -- see winpath above).
outDD=$(BIN_JS_LIB="$(winpath "$wizard")" "$node_bin" -e "
const path = require('path');
const { augmentPathForRun } = require(process.env.BIN_JS_LIB);
const pre = path.join('/usr', 'bin');
const empty = augmentPathForRun('/home/x', '');
const nonEmpty = augmentPathForRun('/home/x', pre);
const dirs = [path.join('/home/x', '.bun', 'bin'), path.join('/home/x', '.local', 'bin')];
console.log(JSON.stringify({ empty, nonEmpty, sep: path.delimiter, dirs, pre }));
")
echo "$outDD" | jq -e '. as $o | $o.empty.path == ($o.dirs | join($o.sep))' >/dev/null \
  || fail "case dd: an empty originalPath should produce exactly the added dirs joined by path.delimiter, with no trailing delimiter (got: $outDD)"
echo "$outDD" | jq -e '. as $o | ($o.empty.path | endswith($o.sep)) | not' >/dev/null \
  || fail "case dd: the augmented PATH must not end with a trailing delimiter (got: $outDD)"
echo "$outDD" | jq -e '. as $o | ($o.empty.path | split($o.sep) | all(. != ""))' >/dev/null \
  || fail "case dd: the augmented PATH must not contain an empty (implicit-cwd) segment (got: $outDD)"
echo "$outDD" | jq -e '. as $o | $o.nonEmpty.path == (($o.dirs | join($o.sep)) + $o.sep + $o.pre)' >/dev/null \
  || fail "case dd: a non-empty originalPath should be appended after the added dirs, unchanged (got: $outDD)"
echo "ok: case dd — augmentPathForRun: an empty originalPath never leaves a trailing delimiter or an empty PATH segment"

# ══════ HIMMEL-2438 wet-run findings (ubuntu_new clean-tools guest) ═════
#
# The shellcheck and gitleaks deps now install via `sudo -n apt-get` (proven above), but
# bun's official installer failed on stock Ubuntu 24.04 with "error: unzip is
# required to install bun" (curl+tar ship by default, unzip does not) —
# ensure-tools printed only a bare "installer failed" with no cause, qmd then
# failed downstream on "bun not found", and the counter still printed "bun:
# installed but still not found on PATH" for a recipe that actually FAILED
# (ensure_tools() always exits 0 by contract, so that wording was never
# actually confirmed). Cases ee/ff/hh/gg below cover the three additions.

# ── case ee: bun's installer prerequisite (unzip) is auto-installed via the
# SAME apt-get path shellcheck/gitleaks already use, BEFORE curl (bun's own
# installer) ever runs. ─────────────────────────────────────────────────────
eedir="$work/case-ee-bin"
eehpath=$(mk_ensure_tools_path unzip "$eedir")
printf '#!/bin/sh\necho 1000\n' > "$eedir/id"; chmod +x "$eedir/id"
cat > "$eedir/sudo" <<'SUDO'
#!/usr/bin/env bash
if [ "$1" = "-n" ]; then shift; fi
if [ "$1" = "true" ] && [ "$#" -eq 1 ]; then exit 0; fi
exec "$@"
SUDO
chmod +x "$eedir/sudo"
eeaptLog="$work/case-ee-aptget.log"
# The stub apt-get "installs" unzip by dropping a stub binary into THIS SAME
# dir (first on PATH), so a subsequent `command -v unzip` resolves it.
cat > "$eedir/apt-get" <<AG
#!/usr/bin/env bash
echo "apt-get \$*" >> "$(winpath "$eeaptLog")"
if [ "\$1" = "install" ] && [ "\$3" = "unzip" ]; then
  printf '#!/usr/bin/env bash\necho stub-unzip\n' > "$eedir/unzip"
  chmod +x "$eedir/unzip"
fi
exit 0
AG
chmod +x "$eedir/apt-get"
eecurlLog="$work/case-ee-curl.log"
cat > "$eedir/curl" <<CURL
#!/usr/bin/env bash
echo "curl \$*" >> "$(winpath "$eecurlLog")"
exit 1
CURL
chmod +x "$eedir/curl"
eehome="$work/case-ee-home"; mkdir -p "$eehome"
rm -f "$eeaptLog" "$eecurlLog"
outEE=$(PATH="$eehpath" HOME="$eehome" bash -c '. "$1"; _ensure_install_bun' _ "$ensureToolsScript" 2>&1 || true)
grepq "$(cat "$eeaptLog" 2>/dev/null)" -F 'apt-get install -y unzip' \
  || fail "case ee: expected apt-get to be asked to install unzip BEFORE the bun installer runs (got: $(cat "$eeaptLog" 2>/dev/null))"
[ -f "$eecurlLog" ] || fail "case ee: expected the bun installer (curl) to have been attempted AFTER unzip was installed (no log file)"
grepq "$outEE" -F "installing 'unzip' via apt-get (required by bun's installer)" \
  || fail "case ee: expected ensure-tools to ANNOUNCE the unzip pre-install it performed (got: $outEE)"
echo "ok: case ee — bun's installer prerequisite (unzip) is auto-installed via the same apt-get path before curl ever runs"

# ── case ff: bun's installer needs unzip, but no passwordless sudo is
# available -> the adopter is told the EXACT privileged command (same
# wording pattern as the shellcheck/gitleaks privilege probe), and curl
# (bun's own installer) is NEVER invoked. ──────────────────────────────────
ffdir="$work/case-ff-bin"
ffhpath=$(mk_ensure_tools_path unzip "$ffdir")
printf '#!/bin/sh\necho 1000\n' > "$ffdir/id"; chmod +x "$ffdir/id"
cat > "$ffdir/sudo" <<'SUDO'
#!/usr/bin/env bash
exit 1
SUDO
chmod +x "$ffdir/sudo"
cat > "$ffdir/apt-get" <<'AG'
#!/usr/bin/env bash
exit 0
AG
chmod +x "$ffdir/apt-get"
ffcurlLog="$work/case-ff-curl.log"
cat > "$ffdir/curl" <<CURL
#!/usr/bin/env bash
echo "curl \$*" >> "$(winpath "$ffcurlLog")"
exit 1
CURL
chmod +x "$ffdir/curl"
ffhome="$work/case-ff-home"; mkdir -p "$ffhome"
rm -f "$ffcurlLog"
outFF=$(PATH="$ffhpath" HOME="$ffhome" bash -c '. "$1"; _ensure_install_bun' _ "$ensureToolsScript" 2>&1 || true)
[ -f "$ffcurlLog" ] && fail "case ff: bun's own installer (curl) must NEVER run when its unzip prerequisite can't be satisfied (got: $(cat "$ffcurlLog"))"
grepq "$outFF" -F 'sudo apt-get install -y unzip' \
  || fail "case ff: expected the exact privileged command for unzip named in the message (got: $outFF)"
echo "ok: case ff — bun's unzip prerequisite: no passwordless sudo -- names the exact command, never runs the installer"

# ── case hh: bun's official installer BODY fails (network OK, install
# script errors) -- the failure message now surfaces the installer's own
# last non-empty stderr line (wet-run fix (B), same shape as the apt/dnf
# stderr surfacing above), not just the generic manual-install hint. This
# case isolates the installer-BODY path, so the unzip prerequisite has to
# be a no-op -- and it is made one HERMETICALLY, by SHADOWING unzip with a
# stub ahead of the real PATH, rather than by relying on this station
# happening to have unzip installed. On a host without it,
# _ensure_bun_prereq_unzip would otherwise go down the real sudo/apt-get
# path and install a package on the test machine. (Shadowing, not
# mk_ensure_tools_path's scrub: this case needs unzip PRESENT, and the
# scrub would drop the whole /usr/bin that also carries the coreutils the
# installer-body path itself uses.) The fail-loud sudo/apt-get stubs are
# there for the same reason -- they PROVE the prerequisite short-circuited
# instead of assuming it, and they shadow the real ones either way.
hhdir="$work/case-hh-bin"; mkdir -p "$hhdir"
printf '#!/bin/sh\nexit 0\n' > "$hhdir/unzip"; chmod +x "$hhdir/unzip"
hhprivLog="$work/case-hh-priv.log"
cat > "$hhdir/sudo" <<SUDO
#!/usr/bin/env bash
echo "sudo \$*" >> "$(winpath "$hhprivLog")"
exit 1
SUDO
chmod +x "$hhdir/sudo"
cat > "$hhdir/apt-get" <<AG
#!/usr/bin/env bash
echo "apt-get \$*" >> "$(winpath "$hhprivLog")"
exit 1
AG
chmod +x "$hhdir/apt-get"
cat > "$hhdir/curl" <<'CURL'
#!/usr/bin/env bash
cat <<'INSTALLER'
echo "some setup output"
echo "fatal: unsupported platform xyz" >&2
exit 1
INSTALLER
CURL
chmod +x "$hhdir/curl"
hhhome="$work/case-hh-home"; mkdir -p "$hhhome"
rm -f "$hhprivLog"
outHH=$(PATH="$hhdir:$PATH" HOME="$hhhome" bash -c '. "$1"; _ensure_install_bun' _ "$ensureToolsScript" 2>&1 || true)
[ -f "$hhprivLog" ] && fail "case hh: unzip is already present, so NO privileged command may run -- the prerequisite check must short-circuit (got: $(cat "$hhprivLog"))"
[ -x "$hhhome/.bun/bin/bun" ] && fail "case hh: the installer body failed -- bun must not be present (got a bun binary anyway)"
grepq "$outHH" -F 'fatal: unsupported platform xyz' \
  || fail "case hh: expected the installer's own last non-empty stderr line surfaced (got: $outHH)"
grepq "$outHH" -F 'install bun manually' || fail "case hh: expected the existing manual-install fallback to remain (got: $outHH)"
echo "ok: case hh — bun installer BODY failure surfaces its own stderr tail, keeps the manual-install fallback"

# ── case gg: bin.js honest counter — an ensure-tools-manager recipe ALWAYS
# exits 0 (ensure_tools() is documented to "always return 0; the caller
# re-checks `command -v`"), so its OWN exit code can never prove "claimed
# success" the way a script/brew/pip/winget recipe's exit code does (case p,
# above, already proves the OLD wording stays correct for a script-manager
# dep). For manager:"ensure-tools", the honest wording instead points at
# ensure-tools.sh's own diagnostic lines. A throwaway fixture repo ships its
# OWN scripts/setup/ensure-tools.sh (a no-op stub `ensure_tools() { return
# 0; }`, mirroring the real contract exactly) so buildDepEntry's manager:
# "ensure-tools" case dispatches through it just like production. ─────────
fixtureRepoGG="$work/repo-gg"
mkdir -p "$fixtureRepoGG/scripts/install" "$fixtureRepoGG/scripts/setup"
cat > "$fixtureRepoGG/scripts/install/deps.json" <<JSON
{
  "schemaVersion": 1,
  "deps": [
    {
      "id": "ghosttool",
      "cmd": "ghosttool-never-lands",
      "versionProbe": { "args": ["--version"] },
      "minVersion": null,
      "bootstrap": false,
      "install": {
        "linux": { "manager": "ensure-tools" },
        "macos": { "manager": "ensure-tools" },
        "win32": { "manager": "ensure-tools" }
      }
    }
  ]
}
JSON
cat > "$fixtureRepoGG/scripts/setup/ensure-tools.sh" <<'STUB'
#!/usr/bin/env bash
# No-op stub mirroring the real ensure_tools() contract exactly: it ALWAYS
# returns 0, regardless of whether the tool actually landed (the real
# function's own documented behaviour).
ensure_tools() { return 0; }
STUB
chmod +x "$fixtureRepoGG/scripts/setup/ensure-tools.sh"

stubGG="$work/bin-gg"; mkdir -p "$stubGG"
link_hermetic_tool bash "$stubGG"
depsPathGG="$stubGG:$(scrub_path "$PATH" ghosttool-never-lands)"

set +e
outGG=$(HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoGG")" HIMMELCTL_INTERACTIVE=0 PATH="$depsPathGG" \
  HIMMELCTL_CACHE_DIR="$(winpath "$work/deps-caseGG.himmelctl-cache")" \
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/deps-caseGG.himmelctl-cache/luna-config.json")" \
  "$node_bin" "$wizard" deps ensure --yes </dev/null 2>&1); rcGG=$?
set -e
[ "$rcGG" -eq 1 ] || fail "case gg: ensure --yes should exit 1 -- the no-op recipe never lands ghosttool (got rc=$rcGG): $outGG"
grepq "$outGG" -F 'ghosttool: not present after its install recipe ran — see the ensure-tools lines above' \
  || fail "case gg: expected the new ensure-tools-manager wording, not the old PATH-specific one (got: $outGG)"
grepq "$outGG" -F 'ghosttool: installed but still not found on PATH' \
  && fail "case gg: the old PATH-specific wording must NOT be used for an ensure-tools-manager recipe -- its own exit code can never prove 'claimed success' (got: $outGG)"
echo "ok: case gg — an ensure-tools-manager recipe's ambiguous exit-0 gets the new 'not present after its install recipe ran' wording, not the PATH-specific one"

echo "PASS"
