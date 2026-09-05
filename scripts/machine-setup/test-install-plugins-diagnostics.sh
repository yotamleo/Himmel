#!/usr/bin/env bash
# test-install-plugins-diagnostics.sh — install-plugins.sh surfaces a real step
# failure LOUDLY (with the CLI's own output) and exits non-zero via the
# presence-verify, while a benign "already installed" re-run stays exit 0
# (idempotent). Stubs `claude` on PATH so nothing touches the real plugin state.
# (HIMMEL-438 — C2.)
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/install-plugins.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Minimal template: one marketplace (autoUpdate:false so the script never patches
# a real settings.json) and one enabled plugin.
cat > "$TMP/template.json" <<'JSON'
{
  "extraKnownMarketplaces": {
    "mp": { "source": { "source": "github", "repo": "x/y" }, "autoUpdate": false }
  },
  "enabledPlugins": { "foo@mp": true }
}
JSON

# Stub `claude`: marketplace add → ok; plugin install → behavior from env;
# plugin list → whatever $STUB_PRESENT names (space-separated).
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "plugin" ] && [ "$2" = "marketplace" ] && [ "$3" = "add" ]; then exit 0; fi
if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then
  if [ -n "${STUB_INSTALL_FAIL:-}" ]; then echo "error: failed to clone marketplace: network unreachable" >&2; exit 1; fi
  if [ -n "${STUB_INSTALL_BENIGN:-}" ]; then echo "Plugin already installed"; exit 1; fi
  exit 0
fi
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  for s in ${STUB_PRESENT:-}; do printf '  %s\n' "$s"; done
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"

fail() { echo "FAIL: $1"; exit 1; }

# plant_attack_link <path-to-plant> <target-file> — simulates an attacker with
# write access to the settings dir pre-planting something at a PREDICTABLE
# temp path before the script runs (HIMMEL-2324). Prefers a real symlink (it
# proves both attack vectors: content written through it, AND `mv` replacing
# the destination with the symlink itself) but falls back to a hardlink (still
# proves the write-through vector) when a symlink can't be created — this
# Windows sandbox has no Developer Mode/admin, so `ln -s` here silently copies
# instead of linking (`[ -L ]` catches that) and `New-Item -ItemType
# SymbolicLink` refuses with "Administrator privilege required".
# file_id <path> — portable inode identity (GNU `stat -c`, falling back to
# BSD/macOS `stat -f`; CodeRabbit round 4 named two sibling sites — this is
# the third copy of the same helper, same partial-fix trap as CR round 3).
# The GNU-only form is only reached on the hardlink fallback (real symlinks
# already return earlier on macOS/Linux), but the caller HARD-FAILS when it
# can't verify a link, so a BSD host reaching this path would abort loudly
# rather than lose coverage silently — still worth making portable. Empty
# output (both variants fail) preserves the existing empty-result-still-
# aborts fallback.
file_id() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null || true
}
plant_attack_link() {
  local link="$1" target="$2" li ti
  rm -f "$link"
  if ln -s "$target" "$link" 2>/dev/null && [ -L "$link" ]; then return 0; fi
  rm -f "$link"
  if command -v cygpath >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 cmd.exe /c mklink /H "$(cygpath -w "$link")" "$(cygpath -w "$target")" >/dev/null 2>&1 || true
    li="$(file_id "$link")"; ti="$(file_id "$target")"
    if [ -n "$li" ] && [ "$li" = "$ti" ]; then return 0; fi
    rm -f "$link"
  fi
  ln "$target" "$link" 2>/dev/null || true
  li="$(file_id "$link")"; ti="$(file_id "$target")"
  if [ -n "$li" ] && [ "$li" = "$ti" ]; then return 0; fi
  # CR round 2 (codex-1): a security test that cannot tell "attack blocked"
  # from "attack never attempted" is worse than no test. Hard-fail here — the
  # chokepoint every caller routes through — instead of returning quietly: if
  # none of the three methods actually planted a link (verified as a real
  # symlink, or the same inode as the target for a hardlink), no caller can
  # proceed unplanted, regardless of whether it checks this function's status.
  echo "FATAL: plant_attack_link: could not plant an attack link at '$link' -- cannot exercise the HIMMEL-2324 case in this environment" >&2
  exit 1
}

# HIMMEL-2292: pins install-plugins.sh's force-enable step (and the
# pre-existing autoUpdate patch) to a path never created here — without it
# --scope user defaults both to the real $HOME/.claude/settings.json.
SETTINGS="$TMP/settings-not-created.json"

# ── Case 1: real install failure → loud diagnostics + non-zero (verify misses foo)
set +e
out1=$(PATH="$STUB_DIR:$PATH" STUB_INSTALL_FAIL=1 STUB_PRESENT="" \
       bash "$SUT" --scope user --template "$TMP/template.json" --settings "$SETTINGS" 2>&1)
rc1=$?
set -e
[ "$rc1" -ne 0 ] || fail "real failure should exit non-zero (got $rc1)"
grepq "$out1" "step FAILED"            || fail "missing loud 'step FAILED' marker"
grepq "$out1" "network unreachable"    || fail "captured CLI error text not surfaced"

# ── Case 2: benign already-installed + present in list → quiet + exit 0
set +e
out2=$(PATH="$STUB_DIR:$PATH" STUB_INSTALL_BENIGN=1 STUB_PRESENT="foo@mp" \
       bash "$SUT" --scope user --template "$TMP/template.json" --settings "$SETTINGS" 2>&1)
rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "benign already-installed re-run should exit 0 (got $rc2): $out2"
grepq "$out2" "already present"        || fail "benign path should print quiet 'already present'"
grepq "$out2" "step FAILED"            && fail "benign path must NOT print 'step FAILED'"

# ── Case 3: HIMMEL-2324 — link pre-planted at the OLD predictable force-enable
#            temp path ("$SETTINGS.enable.tmp") is not written through; the
#            drifted plugin is still force-enabled via mktemp (HIMMEL-2292).
SETTINGS3="$TMP/settings3.json"
cat > "$SETTINGS3" <<'JSON'
{ "enabledPlugins": { "foo@mp": false } }
JSON
CANARY3="$TMP/canary3.txt"
printf 'CANARY-UNCHANGED\n' > "$CANARY3"
plant_attack_link "$SETTINGS3.enable.tmp" "$CANARY3"
set +e
out3=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="foo@mp" \
       bash "$SUT" --scope user --template "$TMP/template.json" --settings "$SETTINGS3" 2>&1)
rc3=$?
set -e
[ "$rc3" -eq 0 ] || fail "HIMMEL-2324 force-enable run should exit 0 (got $rc3): $out3"
[ "$(cat "$CANARY3")" = "CANARY-UNCHANGED" ] || fail "HIMMEL-2324: write landed through the predictable force-enable temp path onto the canary file"
[ -f "$SETTINGS3" ] || fail "HIMMEL-2324: settings3.json missing after force-enable"
[ ! -L "$SETTINGS3" ] || fail "HIMMEL-2324: settings3.json ended up as a symlink"
[ "$(jq -r '.enabledPlugins["foo@mp"]' "$SETTINGS3")" = "true" ] || fail "HIMMEL-2324: drifted plugin was not force-enabled"
echo "ok: HIMMEL-2324 — pre-planted link at the predictable force-enable temp path is not written through"

echo "PASS"
