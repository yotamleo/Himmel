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

repo_root=$(git rev-parse --show-toplevel)
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

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe misresolves MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

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
echo "$outA" | jq -er '.args[3]' | grep -qF 'ensure-tools.sh' \
  || fail "case a: the ensure-tools.sh path should be a positional arg (got: $outA)"
echo "ok: case a — manager:ensure-tools (non-bun) dispatches via ensure_tools \$2, positional args"

# ── case b: manager:"ensure-tools" for bun (install vs upgrade) ────────────
outB1=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'bun', cmd: 'bun', install: { macos: { manager: 'ensure-tools' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'darwin' };
console.log(JSON.stringify(buildDepEntry(dep, ctx)));
")
echo "$outB1" | jq -er '.args[1]' | grep -qF 'ensure_tools bun' \
  || fail "case b (install): expected 'ensure_tools bun' (got: $outB1)"
outB2=$("$node_bin" -e "
const { buildDepEntry } = require(process.env.DEPS_ENGINE_LIB);
const dep = { id: 'bun', cmd: 'bun', install: { macos: { manager: 'ensure-tools' } } };
const ctx = { repoRoot: '/fake/repo', platform: 'darwin' };
console.log(JSON.stringify(buildDepEntry(dep, ctx, { upgrade: true })));
")
echo "$outB2" | jq -er '.args[1]' | grep -qF '_ensure_install_bun' \
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
echo "$outC2" | jq -er '.args[1]' | grep -qF 'brew upgrade' \
  || fail "case c (upgrade): expected 'brew upgrade' in the line (got: $outC2)"
# CodeRabbit: assert the COMPLETE documented upgrade shape — brew upgrade
# with its `|| brew install "$1"` fallback (and the literal "$1" placeholder),
# not just the 'brew upgrade' verb. (The "$1" is the literal positional-arg
# placeholder text, matched with grep -F — single-quoted so the shell never
# expands it.)
# shellcheck disable=SC2016
echo "$outC2" | jq -er '.args[1]' | grep -qF 'brew upgrade "$1" 2>/dev/null || brew install "$1"' \
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
echo "$outD1" | jq -er '.args[1]' | grep -qF 'winget install --id "$1"' \
  || fail "case d (install): expected 'winget install --id \"\$1\"' (got: $outD1)"
# CodeRabbit: winget's required -e --silent flags must be present on install
# (exact-case match + non-interactive) — `--` so grep doesn't read the
# leading -e as one of its own flags.
echo "$outD1" | jq -er '.args[1]' | grep -qF -- '-e --silent' \
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
echo "$outD2" | jq -er '.args[1]' | grep -qF 'winget upgrade --id "$1"' \
  || fail "case d (upgrade): expected 'winget upgrade --id \"\$1\"' (got: $outD2)"
# CodeRabbit: the same -e --silent flags are required on upgrade too.
echo "$outD2" | jq -er '.args[1]' | grep -qF -- '-e --silent' \
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
outJ=$("$node_bin" "$wizard" --help)
echo "$outJ" | grep -q 'deps status' || fail "case j: --help should list 'deps status' (got: $outJ)"
echo "$outJ" | grep -q 'deps ensure' || fail "case j: --help should list 'deps ensure' (got: $outJ)"
echo "$outJ" | grep -q 'deps upgrade' || fail "case j: --help should list 'deps upgrade' (got: $outJ)"
echo "ok: case j — --help lists deps status|ensure|upgrade"

# ── case k: deps with no verb / an unknown verb -> exit 2 ─────────────────
set +e
errK1=$("$node_bin" "$wizard" deps 2>&1); rcK1=$?
set -e
[ "$rcK1" -eq 2 ] || fail "case k: 'deps' with no verb should exit 2 (got rc=$rcK1): $errK1"
echo "$errK1" | grep -qF 'status|ensure|upgrade' || fail "case k: error should name the verb requirement (got: $errK1)"
set +e
errK2=$("$node_bin" "$wizard" deps bogus 2>&1); rcK2=$?
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
    "$node_bin" "$wizard" deps "$@"
}

# ── case l: status — green/red rows + summary ───────────────────────────────
set +e
outL=$(runDeps status </dev/null 2>&1); rcL=$?
set -e
[ "$rcL" -eq 0 ] || fail "case l: deps status should exit 0 (got rc=$rcL): $outL"
echo "$outL" | grep -qE 'green +greentool +present \(3\.2\.1\)' \
  || fail "case l: greentool should read green with its version (got: $outL)"
echo "$outL" | grep -qE "red +redtool +'redtool-does-not-exist' not found on PATH" \
  || fail "case l: redtool should read red naming the missing cmd (got: $outL)"
echo "$outL" | grep -qE '^red +qmd' \
  || fail "case l: qmd should also read red (marker not yet created — got: $outL)"
echo "$outL" | grep -qF '2 red, 0 degraded, 1 green' \
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
echo "$outN" | grep -qF 'DRY:' || fail "case n: expected DRY: lines (got: $outN)"
# Assert the SPECIFIC planned actions, not just "some DRY line" — one line
# per missing dep (redtool, qmd), each naming its script recipe + args.
echo "$outN" | grep -qF 'fake-install.sh' || fail "case n: expected redtool's install script path in the DRY plan (got: $outN)"
echo "$outN" | grep -qE 'fake-install\.sh[^[:space:]]* redtool' || fail "case n: expected redtool's script arg in the DRY plan (got: $outN)"
echo "$outN" | grep -qF 'fake-qmd-bin.sh' || fail "case n: expected qmd's install script path in the DRY plan (got: $outN)"
echo "$outN" | grep -qE 'fake-qmd-bin\.sh[^[:space:]]* install' || fail "case n: expected qmd's 'install' arg in the DRY plan (got: $outN)"
[ -f "$installLog" ] && fail "case n: --dry-run must NOT execute the install script (got: $(cat "$installLog")))"
echo "ok: case n — ensure --dry-run prints DRY lines naming every planned dep + recipe, executes nothing"

# ── case o: ensure, non-interactive, no --yes -> exit 2 ────────────────────
rm -f "$installLog"
set +e
errO=$(runDeps ensure </dev/null 2>&1); rcO=$?
set -e
[ "$rcO" -eq 2 ] || fail "case o: non-interactive ensure without --yes should exit 2 (got rc=$rcO): $errO"
echo "$errO" | grep -qF 'requires --yes' || fail "case o: error should name the --yes requirement (got: $errO)"
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
echo "$outP" | grep -qF 'redtool: installed but still not found on PATH' \
  || fail "case p: redtool should be reported failed with the re-probe reason (got: $outP)"
echo "$outP" | grep -qF '1 installed, 1 failed' \
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
outQ=$(HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" PATH="$depsPathQ" "$node_bin" "$wizard" deps ensure --yes </dev/null 2>&1); rcQ=$?
set -e
[ "$rcQ" -eq 0 ] || fail "case q: ensure with nothing missing should exit 0 (got rc=$rcQ): $outQ"
echo "$outQ" | grep -qF 'nothing to converge' || fail "case q: expected the nothing-to-converge message (got: $outQ)"
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
echo "$outR" | grep -qF 'skipping qmd model pull' \
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
echo "$outS" | grep -qF 'skipping qmd model pull' \
  && fail "case s: --with-models must NOT print the skip message (got: $outS)"
echo "ok: case s — upgrade --yes --with-models also runs the qmd model pull, no prompt shown"

# ── case t: upgrade --dry-run — DRY lines only, nothing executed ──────────
rm -f "$installLog" "$modelsLog"
set +e
outT=$(runDeps upgrade --dry-run </dev/null 2>&1); rcT=$?
set -e
[ "$rcT" -eq 0 ] || fail "case t: upgrade --dry-run should exit 0 for these runnable recipes (got rc=$rcT): $outT"
echo "$outT" | grep -qF 'DRY:' || fail "case t: expected DRY: lines (got: $outT)"
# Assert the SPECIFIC planned actions — present set is [greentool, qmd]
# (redtool stays absent on depsPath), plus the qmd model-pull prompt DRY
# line (no --with-models passed).
echo "$outT" | grep -qF 'fake-install.sh' || fail "case t: expected greentool's upgrade script path in the DRY plan (got: $outT)"
echo "$outT" | grep -qE 'fake-install\.sh[^[:space:]]* greentool' || fail "case t: expected greentool's script arg in the DRY plan (got: $outT)"
echo "$outT" | grep -qF 'fake-qmd-bin.sh' || fail "case t: expected qmd's upgrade script path in the DRY plan (got: $outT)"
echo "$outT" | grep -qE 'fake-qmd-bin\.sh[^[:space:]]* install' || fail "case t: expected qmd's 'install' arg in the DRY plan (got: $outT)"
echo "$outT" | grep -qF 'prompt to pull qmd embedding/rerank models' || fail "case t: expected the qmd model-pull DRY prompt line (got: $outT)"
[ -f "$installLog" ] && fail "case t: --dry-run must NOT execute the upgrade script"
[ -f "$modelsLog" ] && fail "case t: --dry-run must NOT execute the model pull"
echo "ok: case t — upgrade --dry-run prints DRY lines naming every planned dep + recipe + the model-pull prompt, executes nothing"

echo "PASS"
