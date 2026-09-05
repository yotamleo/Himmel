#!/usr/bin/env bash
# test-machine-setup-hermetic.sh — structural guard: no machine-setup suite may
# reach a REAL user settings.json write (HIMMEL-2353).
#
# WHY this exists: test-install-plugins-verify.ps1 / test-install-plugins-diagnostics.ps1
# drove install-plugins.ps1 -Scope user with no settings pin. install-plugins.ps1
# had NO -Settings seam at all, so `user` scope always resolved to the operator's
# real $HOME/.claude/settings.json — and on a verify-FAIL case, control still
# reached the HIMMEL-1032 reconcile step (gated by HIMMEL_RECONCILE_PLUGINS, which
# is `1` in the operator's live env), silently rewriting real enabledPlugins down
# to the fixture floor. The fix teaches install-plugins.sh/.ps1 the same
# CLAUDE_CONFIG_DIR idiom the sibling reconcile-enabled-plugins.{sh,ps1} and
# remove-retired-plugin.sh already use, and the two leaking suites now pin it.
#
# WHY behavioral, not textual: a static grep for "does this suite mention
# CLAUDE_CONFIG_DIR" has idiom blind spots — a sibling HIMMEL leg's own textual
# guard missed an in-process invocation this exact way. Instead, each suite
# under test is run as a CHILD with HOME, USERPROFILE and CLAUDE_CONFIG_DIR all
# pointed at a fresh sandbox holding a canary .claude/settings.json of known
# content. A properly hermetic suite pins its own temp settings and never
# touches the sandbox canary; a suite that resolves `user` scope for real
# writes the canary and is caught by a sha256 mismatch. This observes the
# WRITE, not the source text, so it can't be fooled by an idiom it doesn't
# recognize.
#
# Positive control (HIMMEL-2353, mandatory — a guard that cannot fail is
# worthless): before touching any real suite, a deliberately NON-hermetic
# fixture ("$HOME/.claude/settings.json" writer) is generated and run through
# the same canary check, which must report it FAILED. If it doesn't, the
# guard's own instrument is broken and this script aborts loudly rather than
# silently passing everything downstream.
#
# EXPANSION (HIMMEL-2353, ratified): CLAUDE_CONFIG_DIR is PRODUCTION behavior
# in install-plugins.{sh,ps1} now, not test-only scaffolding, so two more
# properties are proven directly against the installers (not their test
# suites):
#   - unset-path negative control: with CLAUDE_CONFIG_DIR UNSET, `user` scope
#     must still resolve to (a sandboxed) $HOME/.claude/settings.json exactly
#     as before this ticket — proven by observing a real write land there.
#   - twin parity: .sh and .ps1 each get their OWN named case proving they
#     honor CLAUDE_CONFIG_DIR when set — never collapsed into one, so a future
#     one-sided edit fails loudly and names which twin drifted.
#
# Scope: only the suites that can actually reach a plugin-settings write are
# driven here (kept fast — this does not run the whole directory).
#
# Usage: bash scripts/machine-setup/test-machine-setup-hermetic.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
MS_DIR="$REPO_ROOT/scripts/machine-setup"
INSTALL_SH="$MS_DIR/install-plugins.sh"
INSTALL_PS1="$MS_DIR/install-plugins.ps1"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }
SHA_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then SHA_TOOL=sha256sum
elif command -v shasum >/dev/null 2>&1; then SHA_TOOL="shasum -a 256"
fi
[ -n "$SHA_TOOL" ] || { echo "SKIP: no sha256sum/shasum on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (no sha256 tool on PATH)"; exit 0; }
sha256_of() { $SHA_TOOL "$1" 2>/dev/null | awk '{print $1}'; }

PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
pass() { printf 'PASS %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL %s -- %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { printf 'SKIP %s -- %s\n' "$1" "$2"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# mktemp WITH a template + a captured failure: bare `mktemp -d` is not portable
# to BSD/macOS, and every sandbox path below is built on $TMP, so a silent
# failure here would scatter them across the real filesystem.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-hermetic.XXXXXX")" || { echo "FAIL: mktemp -d failed - cannot build the canary sandboxes"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Windows + pwsh gate, same idiom as test-upgrade-rtk.sh (a .cmd stub is
# cmd.exe-native and cannot run for real under pwsh on Linux/macOS).
PS_BIN=""
for c in pwsh pwsh.exe powershell.exe; do
  if command -v "$c" >/dev/null 2>&1; then PS_BIN="$c"; break; fi
done
IS_WINDOWS=0
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
  msys*|cygwin*|win32*|MINGW*|MSYS*) IS_WINDOWS=1 ;;
esac
PS1_OK=0
[ -n "$PS_BIN" ] && [ "$IS_WINDOWS" -eq 1 ] && PS1_OK=1
ps1_skip_reason() {
  if [ -z "$PS_BIN" ]; then echo "no pwsh/powershell.exe on PATH"
  else echo "not Windows (OSTYPE=${OSTYPE:-unknown}); the claude.cmd stub needs cmd.exe"; fi
}

# ── canary check: run <cmd...> as a child with HOME/USERPROFILE/CLAUDE_CONFIG_DIR
# pointed at a fresh sandbox holding a known canary, cwd pinned to REPO_ROOT
# (a suite like test-install-plugins-verify.sh needs a git worktree under it);
# assert it comes back byte-identical (sha256) AND that the child actually
# completed (exit 0). A non-zero exit is gated fatal — HIMMEL-2353 measured
# all nine suites in this exact shape and all nine exit 0, so an inconclusive
# run (crashed/died before reaching its settings-write path) must never read
# as a pass: that's the vacuous-verdict failure mode this script exists to
# rule out. Kept as two distinct failure messages on purpose: "canary WRITTEN"
# means the suite leaked; "exited N" means it never got far enough to prove
# anything either way — a reader must be able to tell those apart. ──────────
check_hermetic() {
  local label="$1"; shift
  local sandbox cfg canary before after rc outfile
  sandbox="$(mktemp -d "$TMP/sbx.XXXXXX")"
  cfg="$sandbox/.claude"
  mkdir -p "$cfg"
  canary="$cfg/settings.json"
  printf '{"HIMMEL-2353-canary": true, "label": "%s"}\n' "$label" > "$canary"
  before="$(sha256_of "$canary")"
  outfile="$sandbox/child.out"

  # HIMMEL_RECONCILE_PLUGINS=1 — NOT unset: the root-caused bug (HIMMEL-2353)
  # only reaches a real write via the HIMMEL-1032 reconcile step, which is
  # gated on this var being `1` in "the operator's live env." A guard that
  # unset it would test a condition milder than the one that actually shipped
  # the leak; setting it here reproduces that operator condition on purpose.
  #
  # HIMMEL-2356: stdout+stderr are captured to $outfile, not discarded — a
  # suite that skips every case still exits 0 and never touches the canary,
  # so without reading what it printed this would report PASS having proved
  # nothing (the other half of the vacuous-verdict bug this file exists to
  # rule out). Merged (2>&1) rather than stdout-only: every skip marker
  # observed across the nine suites is on stdout (plain `echo`/`Write-Host`),
  # but merging costs nothing and removes the risk of missing one on stderr.
  (
    cd "$REPO_ROOT" || exit 99
    HOME="$sandbox" USERPROFILE="$sandbox" CLAUDE_CONFIG_DIR="$cfg" \
      HIMMEL_RECONCILE_PLUGINS=1 "$@" >"$outfile" 2>&1
  )
  rc=$?

  # Priority order is deliberate: a leaked canary or a non-zero exit is
  # reported as such regardless of anything the suite printed, so a skip
  # marker can never mask a real leak or an incomplete run. Every branch's
  # message is textually distinct: "leaked" vs "did not complete" vs "ran
  # nothing" vs "ran partially" vs a clean pass.
  if [ ! -f "$canary" ]; then
    fail "$label" "canary file gone after run (sandbox: $sandbox)"
    return
  fi
  after="$(sha256_of "$canary")"
  if [ "$before" != "$after" ]; then
    fail "$label" "canary settings.json was WRITTEN (sandbox: $sandbox)"
    return
  fi
  if [ "$rc" -ne 0 ]; then
    fail "$label" "suite exited $rc -- run inconclusive, not a pass (sandbox: $sandbox)"
    return
  fi
  # Total skip: the repo's standard "0 cases ran" marker. Matched via an
  # alternation on the dash (em dash U+2014 or a plain hyphen), not a
  # bracket-expression character class -- a [—-] class silently fails to
  # match the multibyte em dash under this host's C.UTF-8/no-LANG grep
  # locale (measured), where the same glyph in an alternation matches fine.
  if grep -qE 'SKIPPED (—|-) 0 cases ran' "$outfile" 2>/dev/null; then
    skip "$label" "suite reported SKIPPED — 0 cases ran; hermeticity unproven, not a pass (sandbox: $sandbox)"
    return
  fi
  # Partial skip: a `SKIP:`-prefixed line without the total marker means
  # some cases genuinely ran (e.g. test-install-plugins-scope.sh's Test 3
  # always runs before its dry-run assertions are conditionally skipped) —
  # not vacuous, but reduced coverage. Deliberately NOT normalised to the
  # total marker (see test-install-plugins-scope.sh's own comment) — doing
  # so would claim "0 cases ran" for a suite that ran one for real, which
  # would be a false statement. Report as PASS, but annotate the label so a
  # reduced-coverage run is never silently indistinguishable from a full one.
  if grep -q 'SKIP:' "$outfile" 2>/dev/null; then
    pass "$label (partial: some cases skipped)"
    return
  fi
  pass "$label"
}

# ── Control instrument: invoke check_hermetic() ITSELF against a
# deliberately-broken fixture and assert IT reported a FAILURE. Asserting on
# the environment (canary hash, exit code) instead of on check_hermetic's own
# verdict would prove the fixture behaves as expected without proving the
# function acts on it — deleting a gate inside check_hermetic could still
# leave a control like that green. This calls the real function, so removing
# either gate inside it turns the matching control red. The FAIL line
# check_hermetic prints is expected output for a control; say so first so a
# reader doesn't mistake it for a real failure, and restore FAIL_COUNT after
# so the deliberately-induced failure doesn't pollute the real tally. ───────
assert_check_hermetic_catches() { # <control-name> <fixture-cmd...>
  local name="$1"; shift
  echo "(the FAIL line below is expected -- it's the \"$name\" control's deliberately-broken fixture, not a real suite failure)"
  local before="$FAIL_COUNT"
  check_hermetic "$name control fixture (expected FAIL)" "$@"
  if [ "$FAIL_COUNT" -gt "$before" ]; then
    FAIL_COUNT="$before"
    pass "$name: deliberately-broken fixture correctly reported as a FAILURE by check_hermetic"
  else
    echo "FATAL: $name control did NOT trip — check_hermetic no longer gates on this; refusing to trust any PASS below." >&2
    FAIL_COUNT=$((before + 1))
    printf 'PASS: %s SKIP: %s FAIL: %s\n' "$PASS_COUNT" "$SKIP_COUNT" "$FAIL_COUNT"
    exit 1
  fi
}

# ── Positive control (MANDATORY, run first): a deliberately non-hermetic
# fixture (writes the canary path directly) must be caught by check_hermetic's
# canary-changed gate. ────────────────────────────────────────────────────
echo "──── positive control: a deliberately non-hermetic fixture must be CAUGHT ────"
BAD_FIXTURE="$TMP/non-hermetic-fixture.sh"
cat > "$BAD_FIXTURE" <<'FIXTURE'
#!/usr/bin/env bash
# Deliberately BAD: resolves `user` scope the way install-plugins.{sh,ps1}
# used to, straight off $HOME, ignoring CLAUDE_CONFIG_DIR entirely.
mkdir -p "$HOME/.claude"
printf '{"tampered": true}\n' > "$HOME/.claude/settings.json"
FIXTURE
chmod +x "$BAD_FIXTURE"
assert_check_hermetic_catches "positive control (canary write)" bash "$BAD_FIXTURE"

# ── Second, distinct control: a child that exits non-zero BEFORE writing
# anything must be caught too. A crash-before-reaching-the-write-path leaves
# the canary untouched, so the canary-changed gate alone would misreport it
# PASS — the vacuous-verdict failure mode CodeRabbit flagged. This proves the
# completion-status gate independently of the canary-write gate above. ──────
echo "──── second control: an early-exiting fixture (no write, non-zero exit) must be CAUGHT ────"
EARLY_EXIT_FIXTURE="$TMP/early-exit-fixture.sh"
cat > "$EARLY_EXIT_FIXTURE" <<'FIXTURE'
#!/usr/bin/env bash
# Deliberately BAD: dies before doing anything -- never touches the canary,
# so only an exit-status check (not the canary check) can catch this.
exit 7
FIXTURE
chmod +x "$EARLY_EXIT_FIXTURE"
assert_check_hermetic_catches "second control (early exit, rc!=0)" bash "$EARLY_EXIT_FIXTURE"

# ── Sibling control instrument (HIMMEL-2356): same shape as
# assert_check_hermetic_catches, but asserts on SKIP_COUNT instead of
# FAIL_COUNT — a total-skip classification doesn't call fail(), so the
# FAIL-based assertion can't observe it. Invokes check_hermetic() itself,
# never a re-implementation of its classification logic. ───────────────────
assert_check_hermetic_skips() { # <control-name> <fixture-cmd...>
  local name="$1"; shift
  echo "(the SKIP line below is expected -- it's the \"$name\" control's total-skip fixture, not a real suite skip)"
  local before="$SKIP_COUNT"
  check_hermetic "$name control fixture (expected SKIP)" "$@"
  if [ "$SKIP_COUNT" -gt "$before" ]; then
    SKIP_COUNT="$before"
    pass "$name: total-skip fixture correctly classified as SKIP (not a vacuous PASS) by check_hermetic"
  else
    echo "FATAL: $name control did NOT trip -- check_hermetic no longer classifies a total-skip marker as SKIP; refusing to trust any PASS below." >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'PASS: %s SKIP: %s FAIL: %s\n' "$PASS_COUNT" "$SKIP_COUNT" "$FAIL_COUNT"
    exit 1
  fi
}

# ── Third control: a fixture that prints the standard total-skip marker and
# exits 0, touching nothing. Before HIMMEL-2356 this read as a bare PASS
# having proved zero hermeticity; it must now be classified SKIP. ──────────
echo "──── third control: a total-skip fixture (0 cases ran, exit 0) must be classified SKIP, not PASS ────"
SKIP_MARKER_FIXTURE="$TMP/skip-marker-fixture.sh"
cat > "$SKIP_MARKER_FIXTURE" <<'FIXTURE'
#!/usr/bin/env bash
# Deliberately vacuous: reports the repo's standard total-skip marker and
# exits 0 without touching anything -- exactly the shape that used to read
# as a hermetic PASS while proving nothing.
echo "SKIP: nothing on PATH"
echo "$(basename "$0"): SKIPPED — 0 cases ran (fixture)"
exit 0
FIXTURE
chmod +x "$SKIP_MARKER_FIXTURE"
assert_check_hermetic_skips "third control (total skip marker)" bash "$SKIP_MARKER_FIXTURE"

# ── Scoped suite scan (behavioral, per HIMMEL-2353) ──────────────────────────
echo "──── scoped suite scan ────"
SH_SUITES=(
  test-install-plugins-verify.sh
  test-install-plugins-diagnostics.sh
  test-install-plugins-autoupdate.sh
  test-install-plugins-scope.sh
  test-reconcile-enabled-plugins.sh
  test-remove-retired-plugin.sh
)
PS1_SUITES=(
  test-install-plugins-verify.ps1
  test-install-plugins-diagnostics.ps1
  test-install-plugins-autoupdate.ps1
)

for s in "${SH_SUITES[@]}"; do
  suite="$MS_DIR/$s"
  if [ ! -f "$suite" ]; then
    fail "$s: hermetic" "suite not found: $suite"
    continue
  fi
  check_hermetic "$s: hermetic (real settings.json untouched)" bash "$suite"
done

for s in "${PS1_SUITES[@]}"; do
  suite="$MS_DIR/$s"
  if [ "$PS1_OK" -ne 1 ]; then
    skip "$s: hermetic" "$(ps1_skip_reason)"
    continue
  fi
  if [ ! -f "$suite" ]; then
    fail "$s: hermetic" "suite not found: $suite"
    continue
  fi
  check_hermetic "$s: hermetic (real settings.json untouched)" "$PS_BIN" -NoProfile -File "$suite"
done

# ── EXPANSION: unset-path negative control + explicit twin parity ───────────
# Both cases below drive the REAL installer directly (not a wrapping test
# suite) through its HIMMEL-365 autoUpdate patch — the one write path cheap
# enough to trigger with an empty enabledPlugins template (no install/verify
# machinery needed) — and observe WHERE the write actually lands.
echo "──── CLAUDE_CONFIG_DIR: unset-path default + explicit twin parity (HIMMEL-2353 EXPANSION) ────"

TWIN_TEMPLATE="$TMP/twin-template.json"
cat > "$TWIN_TEMPLATE" <<'JSON'
{
  "enabledPlugins": {},
  "extraKnownMarketplaces": {
    "mp": { "source": { "source": "directory", "path": "/nonexistent" }, "autoUpdate": true }
  }
}
JSON

seed_settings() { # <path>
  mkdir -p "$(dirname "$1")"
  printf '{ "extraKnownMarketplaces": { "mp": { "autoUpdate": false } } }\n' > "$1"
}
autoupdate_true() { # <path> -> "true" | "false" | "absent" | "MISSING"
  # NOT `// "absent"` — jq's `//` treats a literal `false` as empty too, so a
  # seeded autoUpdate:false would misreport as "absent" (same trap
  # reconcile-enabled-plugins.sh's own val() helper documents/avoids).
  [ -f "$1" ] || { echo "MISSING"; return; }
  jq -r 'if (.extraKnownMarketplaces.mp | has("autoUpdate")) then (.extraKnownMarketplaces.mp.autoUpdate | tostring) else "absent" end' "$1" 2>/dev/null
}

make_sh_claude_stub() { # <bindir>
  mkdir -p "$1"
  cat > "$1/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$1/claude"
}
make_ps1_claude_stub() { # <bindir>
  mkdir -p "$1"
  printf '@echo off\nexit /b 0\n' > "$1/claude.cmd"
}

# ── HIMMEL-2356: the four parity cases below used to assert only on WHERE
# the installer patched -- a run that patched the right file and then exited
# non-zero read as a clean pass. parity_verdict() is the shared gate: it
# fails on a file-patch mismatch (existing behavior, message unchanged) OR on
# a non-zero installer exit (new; a textually distinct message so the two
# failure modes are never confused), and only passes when both hold. ───────
parity_verdict() { # <label> <patched-ok:0|1> <rc> <mismatch-detail>
  local label="$1" patched_ok="$2" rc="$3" mismatch_detail="$4"
  if [ "$patched_ok" -ne 1 ]; then
    fail "$label" "$mismatch_detail"
    return
  fi
  if [ "$rc" -ne 0 ]; then
    fail "$label" "installer patched the expected file(s) but exited $rc -- not a clean pass"
    return
  fi
  pass "$label"
}

# ── Control instrument for the new gate: a fixture "installer" that patches
# its target file correctly and THEN exits non-zero -- exactly the shape
# task (b) exists to catch. Invokes parity_verdict() itself (the real
# function the four cases below call), not a re-implementation. ───────────
echo "──── fourth control: an installer that patches correctly but exits non-zero must go RED ────"
PARITY_RC_FIXTURE_TARGET="$TMP/parity-rc-fixture-settings.json"
printf '{ "extraKnownMarketplaces": { "mp": { "autoUpdate": false } } }\n' > "$PARITY_RC_FIXTURE_TARGET"
PARITY_RC_FIXTURE_INSTALLER="$TMP/parity-rc-fixture-installer.sh"
cat > "$PARITY_RC_FIXTURE_INSTALLER" <<FIXTURE
#!/usr/bin/env bash
printf '{ "extraKnownMarketplaces": { "mp": { "autoUpdate": true } } }\n' > "$PARITY_RC_FIXTURE_TARGET"
exit 9
FIXTURE
chmod +x "$PARITY_RC_FIXTURE_INSTALLER"
bash "$PARITY_RC_FIXTURE_INSTALLER" >/dev/null 2>&1
fixture_rc=$?
fixture_patched_ok=0
[ "$(autoupdate_true "$PARITY_RC_FIXTURE_TARGET")" = "true" ] && fixture_patched_ok=1
echo "(the FAIL line below is expected -- it's the \"installer non-zero exit\" control's deliberately-broken fixture, not a real parity failure)"
before_fail_count="$FAIL_COUNT"
parity_verdict "fourth control fixture (expected FAIL)" "$fixture_patched_ok" "$fixture_rc" "control fixture did not patch as expected"
if [ "$FAIL_COUNT" -gt "$before_fail_count" ]; then
  FAIL_COUNT="$before_fail_count"
  pass "fourth control: patched-but-nonzero-exit fixture correctly reported as a FAILURE by parity_verdict"
else
  echo "FATAL: fourth control did NOT trip -- parity_verdict no longer gates on installer exit status; refusing to trust any PASS below." >&2
  FAIL_COUNT=$((before_fail_count + 1))
  printf 'PASS: %s SKIP: %s FAIL: %s\n' "$PASS_COUNT" "$SKIP_COUNT" "$FAIL_COUNT"
  exit 1
fi

# -- .sh: unset CLAUDE_CONFIG_DIR -> default must still be $HOME/.claude ------
sbx="$(mktemp -d "$TMP/sh-unset.XXXXXX")"
bindir="$sbx/bin"; make_sh_claude_stub "$bindir"
default_settings="$sbx/.claude/settings.json"
seed_settings "$default_settings"
env -u CLAUDE_CONFIG_DIR -u HIMMEL_RECONCILE_PLUGINS \
  HOME="$sbx" USERPROFILE="$sbx" PATH="$bindir:$PATH" \
  bash "$INSTALL_SH" --template "$TWIN_TEMPLATE" --scope user >/dev/null 2>&1
rc=$?
patched_ok=0
[ "$(autoupdate_true "$default_settings")" = "true" ] && patched_ok=1
parity_verdict "sh: CLAUDE_CONFIG_DIR unset -- default still resolves to \$HOME/.claude/settings.json" \
  "$patched_ok" "$rc" \
  "expected the sandboxed \$HOME/.claude/settings.json to be patched; it was not (sandbox: $sbx)"

# -- .sh: CLAUDE_CONFIG_DIR set -> that path wins, $HOME/.claude untouched ----
sbx="$(mktemp -d "$TMP/sh-set.XXXXXX")"
bindir="$sbx/bin"; make_sh_claude_stub "$bindir"
home_settings="$sbx/home/.claude/settings.json"
cfg_dir="$sbx/cfgdir"
cfg_settings="$cfg_dir/settings.json"
seed_settings "$home_settings"
seed_settings "$cfg_settings"
env -u HIMMEL_RECONCILE_PLUGINS \
  HOME="$sbx/home" USERPROFILE="$sbx/home" CLAUDE_CONFIG_DIR="$cfg_dir" PATH="$bindir:$PATH" \
  bash "$INSTALL_SH" --template "$TWIN_TEMPLATE" --scope user >/dev/null 2>&1
rc=$?
patched_ok=0
if [ "$(autoupdate_true "$cfg_settings")" = "true" ] && [ "$(autoupdate_true "$home_settings")" = "false" ]; then patched_ok=1; fi
parity_verdict "sh: honors CLAUDE_CONFIG_DIR when set (writes there, not \$HOME/.claude)" \
  "$patched_ok" "$rc" \
  "cfgdir autoUpdate=$(autoupdate_true "$cfg_settings"), home autoUpdate=$(autoupdate_true "$home_settings") (sandbox: $sbx)"

# -- .ps1 twins: same two cases, skipped cleanly off-Windows/no-pwsh ---------
if [ "$PS1_OK" -ne 1 ]; then
  skip "ps1: CLAUDE_CONFIG_DIR unset -- default still resolves to \$HOME/.claude/settings.json" "$(ps1_skip_reason)"
  skip "ps1: honors CLAUDE_CONFIG_DIR when set (writes there, not \$HOME/.claude)" "$(ps1_skip_reason)"
else
  sbx="$(mktemp -d "$TMP/ps1-unset.XXXXXX")"
  bindir="$sbx/bin"; make_ps1_claude_stub "$bindir"
  default_settings="$sbx/.claude/settings.json"
  seed_settings "$default_settings"
  env -u CLAUDE_CONFIG_DIR -u HIMMEL_RECONCILE_PLUGINS \
    HOME="$sbx" USERPROFILE="$sbx" PATH="$bindir:$PATH" \
    "$PS_BIN" -NoProfile -File "$INSTALL_PS1" -Template "$TWIN_TEMPLATE" -Scope user >/dev/null 2>&1
  rc=$?
  patched_ok=0
  [ "$(autoupdate_true "$default_settings")" = "true" ] && patched_ok=1
  parity_verdict "ps1: CLAUDE_CONFIG_DIR unset -- default still resolves to \$HOME/.claude/settings.json" \
    "$patched_ok" "$rc" \
    "expected the sandboxed \$HOME/.claude/settings.json to be patched; it was not (sandbox: $sbx)"

  sbx="$(mktemp -d "$TMP/ps1-set.XXXXXX")"
  bindir="$sbx/bin"; make_ps1_claude_stub "$bindir"
  home_settings="$sbx/home/.claude/settings.json"
  cfg_dir="$sbx/cfgdir"
  cfg_settings="$cfg_dir/settings.json"
  seed_settings "$home_settings"
  seed_settings "$cfg_settings"
  env -u HIMMEL_RECONCILE_PLUGINS \
    HOME="$sbx/home" USERPROFILE="$sbx/home" CLAUDE_CONFIG_DIR="$cfg_dir" PATH="$bindir:$PATH" \
    "$PS_BIN" -NoProfile -File "$INSTALL_PS1" -Template "$TWIN_TEMPLATE" -Scope user >/dev/null 2>&1
  rc=$?
  patched_ok=0
  if [ "$(autoupdate_true "$cfg_settings")" = "true" ] && [ "$(autoupdate_true "$home_settings")" = "false" ]; then patched_ok=1; fi
  parity_verdict "ps1: honors CLAUDE_CONFIG_DIR when set (writes there, not \$HOME/.claude)" \
    "$patched_ok" "$rc" \
    "cfgdir autoUpdate=$(autoupdate_true "$cfg_settings"), home autoUpdate=$(autoupdate_true "$home_settings") (sandbox: $sbx)"
fi

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAIL_COUNT FAILURE(S)"
fi
printf 'PASS: %s SKIP: %s FAIL: %s\n' "$PASS_COUNT" "$SKIP_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
