#!/usr/bin/env bash
# test-wizard-contributor-profile.sh — hermetic coverage for HIMMEL-1423's
# contributor-dev install profile. The profile keeps setup.sh/setup.ps1 as the
# idempotent mutation primitive and reports actual post-run state through the
# shared manifest/probe/dependency engines plus the canonical lane resolver.
#
# Covers:
#   A. dry-run reports missing three-stage git hooks, Jira dist, shell-test
#      tools, Codex/Hermes and handover guidance without running setup.sh.
#   B. applied setup is invoked once; hook/Jira artifacts created by the stub
#      are re-probed as present rather than optimistically claimed.
#   C. repeated dry-runs produce byte-identical contributor reports.
#   D. Codex/Hermes guidance is platform-correct and hardening remains a
#      printed pointer, never an executed machine-hardening step.
#   E. a manifest-less checkout still installs rc=0 + WARN (HIMMEL-1466
#      defect 1 — a reporting failure must never abort a succeeded install).
#   F. applied install is hermetic: PATH launchers land only in the fixture
#      HIMMELCTL_BIN_DIR, never the real user bin (HIMMEL-1466 defect 2).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
contributor_lib="$repo_root/scripts/himmelctl/lib/contributor-profile.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
node_bin=$(command -v node)

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

# The directory himmelctlBinDir() resolves to when HIMMELCTL_BIN_DIR is UNSET —
# the defect-2 leak target. On win32 that is USERPROFILE (os.homedir() ignores
# the HOME override run_contributor passes); on POSIX HOME is honored so the
# override already redirects writes there. Used to assert an applied install
# leaves no new/overwritten launcher in the real user bin (HIMMEL-1466).
real_user_bin() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) [ -n "${USERPROFILE:-}" ] && printf '%s/.local/bin' "$USERPROFILE" || printf '' ;;
    *) printf '%s/.local/bin' "$HOME" ;;
  esac
}

# Snapshot the himmelctl* launchers in the real user bin by NAME + content hash,
# so both a NEW stray launcher and an in-place overwrite of an existing marked
# one (writeMarkedLauncher replaces marked files) are caught. 'none' if the dir
# is absent/unresolvable (then the before/after compare is a stable no-op).
snapshot_real_bin() {
  local _dir _f _out=''
  _dir="$(real_user_bin)"
  [ -n "$_dir" ] || { printf 'none'; return; }
  [ -d "$_dir" ] || { printf 'none'; return; }
  for _f in "$_dir"/himmelctl "$_dir"/himmelctl.js "$_dir"/himmelctl.cmd "$_dir"/himmelctl.ps1; do
    [ -e "$_f" ] || continue
    _out="${_out}$(printf '%s=' "${_f##*/}"; cksum < "$_f" 2>/dev/null);"
  done
  printf '%s' "$_out"
}

# Coreutils this suite and its targets shell out to, which must survive the
# scrub (HIMMEL-1469). scrub_path drops a PATH dir WHOLESALE when it carries any
# scrubbed tool, and this suite's scrub list includes shellcheck / pre-commit /
# gh — all of which live in /usr/bin on stock Ubuntu, so the scrub takes
# /usr/bin (and every coreutil in it) with them. Windows hid this: node and the
# scrubbed CLIs live in their own directories there, so Git-Bash's /usr/bin
# survives and every local run stayed green while Linux CI failed with
# `uname: command not found` / `dirname: command not found` / `mkdir: command
# not found`. hermetic-path.sh's header already states the contract this
# restores: link whatever the target needs BEFORE calling scrub_path.
# Entries that do not resolve to a real binary are skipped rather than fatal:
# the list spans platforms, and `command -v` reports a SHELL BUILTIN for names
# like printf (bare "printf", not a path) — linking that would plant a dangling
# symlink that any non-bash execve of printf would then trip over.
HERMETIC_COREUTILS=(uname dirname basename mkdir chmod cat cp rm ls sed grep
                    mktemp env sort head tail tr wc find date printf sha256sum)

# True when <stub>/<tool> was already planted, so linking is a no-op.
# caseC runs the SAME stub dir through build_path twice, and re-linking is not
# harmless on Linux: link_hermetic_tool's `ln -s` fails when the entry exists,
# and its wrapper fallback then writes THROUGH the existing symlink into the
# real binary (`/usr/bin/uname: Permission denied`). Windows never hit this —
# `ln -s` fails there, so the first pass leaves a plain wrapper file that the
# second pass simply truncates. The same latent hazard exists in the shared
# link_hermetic_tool for any suite that re-links one stub dir (HIMMEL-1469).
already_linked() { [ -e "$1/$2" ] || [ -L "$1/$2" ]; }

build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _t
  for _t in "$@"; do
    if [ "$_t" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_t"); else _absent+=("$_t"); fi
  done
  local _src
  for _t in "${HERMETIC_COREUTILS[@]}"; do
    already_linked "$_stub" "$_t" && continue
    _src=$(command -v "$_t" 2>/dev/null) || continue
    case "$_src" in /*) link_hermetic_tool "$_t" "$_stub" ;; esac
  done
  for _t in "${_present[@]}"; do
    already_linked "$_stub" "$_t" && continue
    link_hermetic_tool "$_t" "$_stub"
  done
  local _scrubbed="$PATH"
  if [ "${#_absent[@]}" -gt 0 ]; then
    _scrubbed=$(scrub_path "$PATH" "${_absent[@]}")
  fi
  printf '%s:%s' "$_stub" "$_scrubbed"
}

make_git_stub() {
  local _d="$1" _top="$2"
  cat > "$_d/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ] && [ "\$3" = "origin" ]; then
  printf '%s\n' 'https://github.com/yotamleo/himmel.git'
  exit 0
fi
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--show-toplevel" ]; then
  printf '%s\n' '$(winpath "$_top")'
  exit 0
fi
exit 0
STUB
  chmod +x "$_d/git"
}

make_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/install" "$_d/scripts/lanes" "$_d/scripts/guardrails"
  cp "$repo_root/scripts/install/manifest.json" "$_d/scripts/install/manifest.json"
  cp "$repo_root/scripts/install/deps.json" "$_d/scripts/install/deps.json"
  cp "$repo_root/scripts/lanes/lanes.json" "$_d/scripts/lanes/lanes.json"
  cp "$repo_root/scripts/lanes/probe.mjs" "$_d/scripts/lanes/probe.mjs"
  cp "$repo_root/scripts/lanes/resolve.mjs" "$_d/scripts/lanes/resolve.mjs"
  cp "$repo_root/scripts/guardrails/lib.sh" "$_d/scripts/guardrails/lib.sh"
  cat > "$_d/scripts/setup.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$_d/scripts/setup.sh"
  cat > "$_d/scripts/setup.ps1" <<'STUB'
& bash (Join-Path $PSScriptRoot 'setup.sh')
exit $LASTEXITCODE
STUB
}

profile_file() {
  local _out="$1"
  cat > "$_out" <<'JSON'
{
  "role": "contributor",
  "tier": "standard",
  "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
}

run_contributor() {
  local _stub="$1" _home="$2" _fixture="$3" _profile="$4"; shift 4
  local _p
  _p=$(build_path "$_stub" bash jq python3 npm -- node bun codex hermes shellcheck gitleaks pre-commit gh)
  make_git_stub "$_stub" "$_fixture"
  # HIMMELCTL_BIN_DIR must be pinned under the fixture home (HIMMEL-1466
  # defect 2): himmelctlBinDir() on win32 falls back to os.homedir() = USERPROFILE,
  # which IGNORES the HOME override below — so without this seam every applied
  # case would write its PATH launchers into the REAL ~/.local/bin (stray
  # launchers on the operator's machine, and a never-clobber refusal -> rc=1 if
  # an unmarked stray already lives there). Mirrors test-himmelctl-path-shim.sh
  # caseF, which writes to a fixture-local bin via the same env var.
  PATH="$_p" HOME="$_home" LOCALAPPDATA="$(winpath "$_home/local")" \
    HERMES_HOME="$(winpath "$_home/local/hermes")" HERMES_PY="$(winpath "$_home/local/hermes/python")" \
    HIMMELCTL_INTERACTIVE=0 HIMMELCTL_REPO_ROOT="$(winpath "$_fixture")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$_home/cache")" \
    HIMMELCTL_BIN_DIR="$(winpath "$_home/.local/bin")" \
    "$node_bin" "$wizard" install --from-profile "$(winpath "$_profile")" "$@" </dev/null 2>&1
}

contributor_report() { printf '%s' "$1" | sed -n '/contributor dev profile/,$p'; }

# Captured BEFORE any install runs: the himmelctl* launchers in the real user
# bin (defect-2 leak target). Compared again after the applied cases to assert
# the suite wrote nothing outside its fixture dirs.
real_bin_before="$(snapshot_real_bin)"

# ── Case A: dry-run is truthful and pure ──────────────────────────────────
sA="$work/a-stub"; mkdir -p "$sA"
hA="$work/a-home"; mkdir -p "$hA"
fA="$work/a-fixture"; make_fixture "$fA"; touch "$fA/.himmel-dev"
pA="$work/a-profile.json"; profile_file "$pA"
sentinelA="$work/A-SETUP-RAN"
cat > "$fA/scripts/setup.sh" <<STUB
#!/usr/bin/env bash
printf 'ran\n' > '$(winpath "$sentinelA")'
exit 0
STUB
chmod +x "$fA/scripts/setup.sh"
set +e
out=$(run_contributor "$sA" "$hA" "$fA" "$pA" --dry-run); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseA: contributor dry-run should succeed (got rc=$rc): $out"
[ ! -e "$sentinelA" ] || fail "caseA: --dry-run executed setup.sh"
grepq "$out" '"lanesMeaningful": true' \
  || fail "caseA: explicit empty contributor lane list must be meaningful: $out"
report=$(contributor_report "$out")
grepq "$report" 'pre-commit gates' || fail "caseA: missing pre-commit gate row: $report"
grepq "$report" 'pre-commit, commit-msg, pre-push' \
  || fail "caseA: hook report must name all three configured hook types: $report"
grepq "$report" 'Jira CLI dist' || fail "caseA: missing Jira dist row: $report"
grepq "$report" 'shellcheck' || fail "caseA: shell-test report must include shellcheck: $report"
grepq "$report" 'gitleaks' || fail "caseA: shell-test report must include gitleaks: $report"
grepq "$report" 'gh' || fail "caseA: shell-test report must include gh: $report"
grepq "$report" -E '!! +codex' || fail "caseA: Codex must be a first-class probed item: $report"
grepq "$report" -E '!! +hermes' || fail "caseA: Hermes must be a first-class probed item: $report"
grepq "$report" '/handover-setup' || fail "caseA: unwired handover must print interactive completion guidance: $report"
grepq "$report" 'always-on hardening: skipped' \
  || fail "caseA: hardening must remain a printed pointer: $report"
grepq "$report" 'would run the idempotent contributor setup primitive' \
  || fail "caseA: dry-run must describe setup as planned, not completed: $report"
[ ! -e "$fA/scripts/lanes/lanes.local.json" ] \
  || fail "caseA: contributor dry-run must not persist an adopter lane allowlist"
echo "ok: caseA dry-run reports contributor state/guidance and mutates nothing"

# ── Case B: applied setup is followed by actual-state re-probes ────────────
sB="$work/b-stub"; mkdir -p "$sB"
hB="$work/b-home"; mkdir -p "$hB"
fB="$work/b-fixture"; make_fixture "$fB"; touch "$fB/.himmel-dev"
pB="$work/b-profile.json"; profile_file "$pB"
sentinelB="$work/B-SETUP-RAN"
cat > "$fB/scripts/setup.sh" <<STUB
#!/usr/bin/env bash
set -e
root="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "\$root/.git/hooks" "\$root/scripts/jira/dist"
for hook in pre-commit commit-msg pre-push; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "\$root/.git/hooks/\$hook"
  chmod +x "\$root/.git/hooks/\$hook"
done
printf 'built\n' > "\$root/scripts/jira/dist/index.js"
printf 'ran\n' > '$(winpath "$sentinelB")'
STUB
chmod +x "$fB/scripts/setup.sh"
cat > "$fB/scripts/setup.ps1" <<STUB
\$root = Split-Path -Parent \$PSScriptRoot
\$hooks = Join-Path \$root '.git/hooks'
\$jira = Join-Path \$root 'scripts/jira/dist'
New-Item -ItemType Directory -Force -Path \$hooks, \$jira | Out-Null
foreach (\$hook in @('pre-commit', 'commit-msg', 'pre-push')) {
  Set-Content -Path (Join-Path \$hooks \$hook) -Value @('#!/usr/bin/env bash', 'exit 0')
}
Set-Content -Path (Join-Path \$jira 'index.js') -Value 'built'
Set-Content -Path '$(winpath "$sentinelB")' -Value 'ran'
STUB
set +e
out=$(run_contributor "$sB" "$hB" "$fB" "$pB"); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseB: applied contributor install should succeed (got rc=$rc): $out"
[ -f "$sentinelB" ] || fail "caseB: setup.sh/setup.ps1 was not invoked"
report=$(contributor_report "$out")
grepq "$report" -E 'ok +pre-commit gates +ready' \
  || fail "caseB: post-install probe must attest the three installed gates: $report"
grepq "$report" -E 'ok +Jira CLI dist +ready' \
  || fail "caseB: post-install probe must attest the built Jira artifact: $report"
grepq "$report" 'setup primitive completed; post-install probes above are authoritative' \
  || fail "caseB: applied summary should defer to probes rather than claiming blanket success: $report"
[ ! -e "$fB/scripts/lanes/lanes.local.json" ] \
  || fail "caseB: applied contributor install must not persist an adopter lane allowlist"
echo "ok: caseB applied setup runs once and post-probes verify hooks/Jira honestly"

# ── Case C: repeated dry-run reports are byte-identical ────────────────────
sC="$work/c-stub"; mkdir -p "$sC"
hC="$work/c-home"; mkdir -p "$hC"
fC="$work/c-fixture"; make_fixture "$fC"; touch "$fC/.himmel-dev"
pC="$work/c-profile.json"; profile_file "$pC"
out1=$(run_contributor "$sC" "$hC" "$fC" "$pC" --dry-run)
out2=$(run_contributor "$sC" "$hC" "$fC" "$pC" --dry-run)
r1=$(contributor_report "$out1")
r2=$(contributor_report "$out2")
[ "$r1" = "$r2" ] || fail "caseC: repeated contributor reports differ\nfirst: <$r1>\nsecond: <$r2>"
echo "ok: caseC repeated contributor dry-runs are byte-identical"

# ── Case D: lane guidance is platform-correct; hardening is print-only ─────
[ -f "$contributor_lib" ] || fail "caseD: contributor-profile.js not found"
pD=$(build_path "$sA" bash jq python3 npm -- node bun codex hermes shellcheck gitleaks pre-commit gh)
# shellcheck disable=SC2016
"$node_bin" -e '
(async () => {
  const c = require(process.argv[1]);
  const root = process.argv[2];
  const env = Object.assign({}, process.env, { HOME: process.argv[3], LOCALAPPDATA: process.argv[3] + "/local", HERMES_HOME: process.argv[3] + "/local/hermes", HERMES_PY: process.argv[3] + "/local/hermes/python", PATH: process.argv[4] });
  const render = async (platform) => c.reportLines(await c.buildReport({ repoRoot: root, env, platform }), { dryRun: true, derived: "setup" }).join("\n");
  const posix = await render("linux");
  for (const re of [/\.ps1/, /winget/, /%LOCALAPPDATA%/, /powercfg/]) {
    if (re.test(posix)) throw new Error("linux contributor guidance leaks Windows text " + re + "\n" + posix);
  }
  for (const want of [/install-himmel-codex\.sh/, /install-himmel-profile\.sh/, /\/handover-setup/]) {
    if (!want.test(posix)) throw new Error("linux contributor guidance misses " + want + "\n" + posix);
  }
  const win = await render("win32");
  for (const want of [/install-himmel-codex\.ps1/, /install-himmel-profile\.ps1/, /winget install/]) {
    if (!want.test(win)) throw new Error("win32 contributor guidance misses " + want + "\n" + win);
  }
  if (/CHECKLIST ONLY|powercfg/.test(win)) throw new Error("contributor profile must not execute or dump machine hardening\n" + win);
})().catch((e) => { console.error(e && e.message ? e.message : e); process.exit(1); });
' "$(winpath "$contributor_lib")" "$(winpath "$fA")" "$(winpath "$hA")" "$pD" \
  || fail "caseD: contributor guidance is not platform-correct"
echo "ok: caseD contributor lane guidance is platform-correct; hardening stays a pointer"

# ── Case E: a manifest-less checkout still installs rc=0 + WARN (HIMMEL-1466
# defect 1). printContributorProfile runs AFTER the core install succeeds, so a
# missing scripts/install/manifest.json must never abort it (the #1530
# regression: loadManifest()'s throw escaped and turned a green install into
# exit 1). Assert the install exits 0 and the skipped profile is WARNed.
sE="$work/e-stub"; mkdir -p "$sE"
hE="$work/e-home"; mkdir -p "$hE"
fE="$work/e-fixture"; make_fixture "$fE"; touch "$fE/.himmel-dev"
rm -f "$fE/scripts/install/manifest.json"
pE="$work/e-profile.json"; profile_file "$pE"
set +e
out=$(run_contributor "$sE" "$hE" "$fE" "$pE"); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseE: a manifest-less contributor install must still exit 0 (got rc=$rc): $out"
grepq "$out" 'WARN: contributor dev profile unavailable' \
  || fail "caseE: manifest-less install must WARN the profile report was skipped: $out"
grepq "$out" 'manifest.json' \
  || fail "caseE: WARN must name the unreadable manifest.json: $out"
echo "ok: caseE manifest-less checkout installs rc=0 and WARNs the skipped profile"

# ── Case F: applied install is hermetic — launchers land ONLY in HIMMELCTL_BIN_DIR
# (HIMMEL-1466 defect 2). On win32 himmelctlBinDir() falls back to os.homedir()
# (USERPROFILE) and ignores the HOME override, so without the HIMMELCTL_BIN_DIR
# export run_contributor now sets, every applied install leaked PATH launchers
# into the REAL ~/.local/bin. Assert the launchers land in the fixture bin and
# nothing touches the real user bin (checked across the whole suite).
sF="$work/f-stub"; mkdir -p "$sF"
hF="$work/f-home"; mkdir -p "$hF"
fF="$work/f-fixture"; make_fixture "$fF"; touch "$fF/.himmel-dev"
pF="$work/f-profile.json"; profile_file "$pF"
set +e
out=$(run_contributor "$sF" "$hF" "$fF" "$pF"); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF: applied contributor install should succeed (got rc=$rc): $out"
fixtureBin="$hF/.local/bin"
[ -f "$fixtureBin/himmelctl.js" ] \
  || fail "caseF: himmelctl.js must be written into the fixture HIMMELCTL_BIN_DIR ($fixtureBin), not the real user bin: $out"
grepq "$(cat "$fixtureBin/himmelctl.js")" 'generated by himmelctl (HIMMEL-1446)' \
  || fail "caseF: fixture launcher must carry the ownership marker"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) [ -f "$fixtureBin/himmelctl.cmd" ] || fail "caseF: win32 must write himmelctl.cmd into the fixture bin: $out" ;;
  *) [ -x "$fixtureBin/himmelctl" ] || fail "caseF: posix must write the executable himmelctl wrapper into the fixture bin: $out" ;;
esac
real_bin_after="$(snapshot_real_bin)"
[ "$real_bin_after" = "$real_bin_before" ] \
  || fail "caseF: applied install leaked/overwrote launchers in the real user bin (before=<$real_bin_before> after=<$real_bin_after>)"
echo "ok: caseF applied install writes launchers only into the fixture HIMMELCTL_BIN_DIR (no real-home leak)"

echo "PASS: test-wizard-contributor-profile.sh (6 cases)"
