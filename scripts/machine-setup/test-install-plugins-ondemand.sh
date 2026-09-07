#!/usr/bin/env bash
# test-install-plugins-ondemand.sh — hermetic tests for the HIMMEL-2733
# two-tier profile in scripts/machine-setup/install-plugins.sh:
#
#   1. INSTALL set = enabledPlugins-true (ALWAYS) UNION onDemandPlugins keys
#      (ON-DEMAND) — both tiers get `claude plugin install`ed.
#   2. Presence-verify covers the WHOLE union — a missing on-demand plugin is
#      a real install failure (exit 1), not silently ignored.
#   3. A `false`-flagged entry ABSENT from onDemandPlugins is still never
#      installed (the plain HIMMEL-816 lean-profile case, unaffected by this
#      ticket).
#   4. After a real run, the scope's settings file ends up with EXACTLY the
#      ALWAYS tier at `true` and every onDemandPlugins key at `false` (RED
#      control #1 from the brief).
#   5. No-clobber: an on-demand spec the operator already enabled (`true` in
#      the live settings before the run) is left `true` after a re-run — the
#      override is read before installing, not from CLI-written state (RED #2).
#   6. The force-enable step (HIMMEL-2292) never force-enables an on-demand
#      spec, even when it is present in `claude plugin list` (installed) and
#      still `false` in the live settings.
#   7. A partially failed install or failed presence-list still normalizes
#      successful fresh on-demand installs to `false` before exiting; a retry
#      cannot misclassify the install side effect as a deliberate override.
#   8. The install summary names each on-demand spec with its `neededBy` text
#      plus the enable recipe, and names the onDemandConnectors entries.
#
# install-plugins.ps1 carries the SAME two-tier logic as a PowerShell twin,
# EXCEPT it has no HIMMEL-2292 force-enable step at all (a pre-existing,
# documented, bash-only gap unrelated to this ticket — see
# test-install-plugins-diagnostics.ps1's header) — case 6 has no ps1
# counterpart for that reason. Cases 1-5 and 7 should still hold there;
# sanity-check with `pwsh install-plugins.ps1` on a Windows host.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Uses git, jq, and mktemp to validate the two-tier install logic; NOT ported
# to native PowerShell. A test harness needs no .ps1 twin (project convention:
# a documented platform guard suffices for a test fixture).
set -uo pipefail

# Pin OFF regardless of the ambient environment: some stations export
# HIMMEL_RECONCILE_PLUGINS=1 for their own operator convenience, and this
# suite's whole point is asserting what a PLAIN install does on its own
# (preserve pre-install enables, disable new on-demand installs) — the opt-in subtractive
# reconcile is a DIFFERENT feature with its own test coverage, and letting it
# fire here would rewrite enabledPlugins to the full template floor
# (including never-installed@mp: false) and mask what install-plugins.sh
# itself just wrote.
unset HIMMEL_RECONCILE_PLUGINS

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/install-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }
REAL_JQ=$(command -v jq)
export REAL_JQ

FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-install-plugins-ondemand.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"; FAILED=$((FAILED + 1))
    fi
}

assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

assert_not_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — unexpectedly present: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

# Stub `claude`: marketplace add → ok; `plugin list` prints whatever
# $STUB_PRESENT names (space-separated); `plugin enable` records to
# $ENABLE_LOG (never a real toggle) so case 6 can assert it was never called
# with an on-demand spec. `plugin install <spec> --scope <scope>` writes
# enabledPlugins["<spec>"] = true into $STUB_SETTINGS_FILE — this is the
# faithful bit (HIMMEL-2733 finding 1/6): the REAL CLI does exactly this as a
# side effect of a genuinely FRESH install (verified in an empty
# CLAUDE_CONFIG_DIR — marketplace add + install, then `enabledPlugins`
# already carries the spec as `true`). A stub that skipped this could never
# reproduce the fresh-install bug the absent-only on-demand check shipped
# with, so the "fresh install -> on-demand false" assertions below would pass
# for the wrong reason (a vacuous test). $STUB_ALREADY_INSTALLED
# (space-separated) names specs that were ALREADY installed before this run —
# install is a no-op for those (no settings write), matching the CLI's
# idempotent re-run behaviour that HIMMEL-2292's force-enable step exists to
# repair in the first place (if a re-install always reset enabledPlugins to
# true, that drift could never happen).
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  if [ -n "${STUB_LIST_FAIL:-}" ]; then
    echo "stub: list boom" >&2
    exit 3
  fi
  for s in ${STUB_PRESENT:-}; do printf '  %s\n' "$s"; done
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "enable" ]; then
  echo "$*" >> "${ENABLE_LOG:-/dev/null}"
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "install" ]; then
  spec="${3:-}"
  case " ${STUB_INSTALL_FAIL:-} " in
    *" $spec "*) echo "stub: install failed for $spec" >&2; exit 1 ;;
  esac
  case " ${STUB_ALREADY_INSTALLED:-} " in
    *" $spec "*) exit 0 ;;
  esac
  settings_file="${STUB_SETTINGS_FILE:-}"
  if [ -z "$settings_file" ]; then
    scope=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--scope" ]; then scope="$arg"; break; fi
      prev="$arg"
    done
    case "$scope" in
      user) settings_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" ;;
      project) settings_file="$PWD/.claude/settings.json" ;;
      local) settings_file="$PWD/.claude/settings.local.json" ;;
    esac
  fi
  if [ -n "$settings_file" ] && [ -n "$spec" ]; then
    if [ -f "$settings_file" ]; then
      tmp="$(mktemp "$settings_file.stub.XXXXXX")" || exit 0
      if jq --arg k "$spec" '.enabledPlugins[$k] = true' "$settings_file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$settings_file"
      else
        rm -f "$tmp"
      fi
    else
      jq -n --arg k "$spec" '{enabledPlugins: {($k): true}}' > "$settings_file" 2>/dev/null
    fi
  fi
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Native jq on Windows emits CRLF for raw line output. On Linux, this wrapper
# reproduces that boundary for the installer's raw/compact non-override set;
# every other invocation delegates byte-for-byte to the real jq.
cat > "$STUB_DIR/jq" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_JQ_CRLF_RAW:-0}" = 1 ] && { [ "${1:-}" = "-rn" ] || [ "${1:-}" = "-cn" ]; }; then
  "$REAL_JQ" "$@" | sed 's/$/\r/'
  exit "${PIPESTATUS[0]}"
fi
exec "$REAL_JQ" "$@"
STUB
chmod +x "$STUB_DIR/jq"

# Two-tier template: two ALWAYS plugins, two ON-DEMAND plugins (both `false`
# in enabledPlugins AND listed in onDemandPlugins), one plain `false` plugin
# NOT in onDemandPlugins (must stay uninstalled — case 3), and the
# documentation-only onDemandConnectors tier (case 7).
TEMPLATE="$TMP/settings-template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "enabledPlugins": {
    "always-a@mp": true,
    "always-b@mp": true,
    "ondemand-a@mp": false,
    "ondemand-b@mp": false,
    "never-installed@mp": false
  },
  "extraKnownMarketplaces": {},
  "onDemandPlugins": {
    "ondemand-a@mp": { "neededBy": "thing A" },
    "ondemand-b@mp": { "neededBy": "thing B" }
  },
  "onDemandConnectors": {
    "claude-in-chrome": { "neededBy": "browser automation", "enableVia": "Chrome extension" }
  }
}
JSON

# Run through the installer's real scope resolver. The CLI stub independently
# resolves the same scope from its argv and writes the actual scope target; no
# STUB_SETTINGS_FILE or installer --settings seam participates in these cases.
run_resolved_scope() {
  local work="$1" scope="$2" present="$3" install_fail="${4:-}" list_fail="${5:-}" already="${6:-}"
  ( cd "$work" && env -u STUB_SETTINGS_FILE \
      PATH="$STUB_DIR:$PATH" STUB_PRESENT="$present" STUB_INSTALL_FAIL="$install_fail" \
      STUB_LIST_FAIL="$list_fail" STUB_ALREADY_INSTALLED="$already" \
      bash "$script" --scope "$scope" --template "$TEMPLATE" 2>&1 )
}

ALL_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp"

# ── Local scope normalization: fresh, true override, false, failure/retry ────
LOCAL_FRESH="$TMP/local-fresh"
mkdir -p "$LOCAL_FRESH/.claude"
out=$(run_resolved_scope "$LOCAL_FRESH" local "$ALL_PRESENT"); rc=$?
assert_rc "local resolver: fresh install exits 0" 0 "$rc"
LOCAL_FRESH_SETTINGS="$LOCAL_FRESH/.claude/settings.local.json"
WANT4='{"always-a@mp":true,"always-b@mp":true,"ondemand-a@mp":false,"ondemand-b@mp":false}'
if [ "$(jq -Sc '.enabledPlugins' "$LOCAL_FRESH_SETTINGS")" = "$WANT4" ]; then
  echo "PASS local resolver: fresh CLI writes are normalized to the two-tier state"
else
  echo "FAIL local resolver: fresh on-demand CLI writes stayed enabled"; FAILED=$((FAILED + 1))
fi
assert_has "local summary uses the actual local scope" "claude plugin enable <spec> --scope local" "$out"
assert_not_has "local summary omits the user-only /profile command" "/profile" "$out"

LOCAL_TRUE="$TMP/local-true"
mkdir -p "$LOCAL_TRUE/.claude"
printf '%s\n' '{"enabledPlugins":{"ondemand-a@mp":true}}' > "$LOCAL_TRUE/.claude/settings.local.json"
out=$(run_resolved_scope "$LOCAL_TRUE" local "$ALL_PRESENT"); rc=$?
assert_rc "local resolver: pre-existing true override exits 0" 0 "$rc"
if [ "$(jq -Sc '.enabledPlugins' "$LOCAL_TRUE/.claude/settings.local.json")" = '{"always-a@mp":true,"always-b@mp":true,"ondemand-a@mp":true,"ondemand-b@mp":false}' ]; then
  echo "PASS local resolver: real pre-install true override survives normalization"
else
  echo "FAIL local resolver: pre-install true override or absent on-demand state was clobbered"; FAILED=$((FAILED + 1))
fi

LOCAL_FALSE="$TMP/local-false"
mkdir -p "$LOCAL_FALSE/.claude"
printf '%s\n' '{"enabledPlugins":{"ondemand-a@mp":false}}' > "$LOCAL_FALSE/.claude/settings.local.json"
out=$(run_resolved_scope "$LOCAL_FALSE" local "$ALL_PRESENT"); rc=$?
assert_rc "local resolver: pre-existing false state exits 0" 0 "$rc"
if [ "$(jq -Sc '.enabledPlugins' "$LOCAL_FALSE/.claude/settings.local.json")" = "$WANT4" ]; then
  echo "PASS local resolver: CLI true side effect cannot override pre-existing false"
else
  echo "FAIL local resolver: pre-existing false was promoted by the CLI side effect"; FAILED=$((FAILED + 1))
fi

LOCAL_RETRY="$TMP/local-retry"
mkdir -p "$LOCAL_RETRY/.claude"
printf '%s\n' '{}' > "$LOCAL_RETRY/.claude/settings.local.json"
out=$(run_resolved_scope "$LOCAL_RETRY" local "$ALL_PRESENT" "" 1); rc=$?
assert_rc "local resolver: list failure exits 1" 1 "$rc"
if [ "$(jq -r '.enabledPlugins["ondemand-a@mp"]' "$LOCAL_RETRY/.claude/settings.local.json")" = false ] \
   && [ "$(jq -r '.enabledPlugins["ondemand-b@mp"]' "$LOCAL_RETRY/.claude/settings.local.json")" = false ]; then
  echo "PASS local resolver: failed run normalizes CLI writes before exit"
else
  echo "FAIL local resolver: failed run left CLI-written on-demand values true"; FAILED=$((FAILED + 1))
fi
out=$(run_resolved_scope "$LOCAL_RETRY" local "$ALL_PRESENT" "" "" "$ALL_PRESENT"); rc=$?
assert_rc "local resolver: retry succeeds" 0 "$rc"
if [ "$(jq -Sc '.enabledPlugins' "$LOCAL_RETRY/.claude/settings.local.json")" = "$WANT4" ]; then
  echo "PASS local resolver: retry does not mistake prior CLI writes for overrides"
else
  echo "FAIL local resolver: retry promoted prior CLI writes"; FAILED=$((FAILED + 1))
fi

LOCAL_MALFORMED="$TMP/local-malformed"
mkdir -p "$LOCAL_MALFORMED/.claude"
printf '%s\n' '{ bad json' > "$LOCAL_MALFORMED/.claude/settings.local.json"
out=$(run_resolved_scope "$LOCAL_MALFORMED" local "$ALL_PRESENT"); rc=$?
assert_rc "local resolver: malformed JSON is refused" 1 "$rc"
assert_has "local resolver: malformed refusal is explicit" "not valid JSON — refusing to register on-demand plugins" "$out"
if [ "$(tr -d '\n' < "$LOCAL_MALFORMED/.claude/settings.local.json")" = '{ bad json' ]; then
  echo "PASS local resolver: malformed settings remain untouched"
else
  echo "FAIL local resolver: malformed settings were modified"; FAILED=$((FAILED + 1))
fi

# Project summary also uses its actual scope and never advertises /profile.
PROJECT_SUMMARY="$TMP/project-summary"
mkdir -p "$PROJECT_SUMMARY/.claude"
out=$(run_resolved_scope "$PROJECT_SUMMARY" project "$ALL_PRESENT"); rc=$?
assert_rc "project resolver: summary run exits 0" 0 "$rc"
assert_has "project summary uses the actual project scope" "claude plugin enable <spec> --scope project" "$out"
assert_not_has "project summary omits the user-only /profile command" "/profile" "$out"

# ── 1 + 3: install set = ALWAYS UNION on-demand; plain-false stays excluded ──
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_SETTINGS_FILE="$TMP/settings-not-created.json" \
      bash "$script" --template "$TEMPLATE" --settings "$TMP/settings-not-created.json" 2>&1); rc=$?
assert_rc "both tiers install, all present -> exit 0" 0 "$rc"
assert_has "installs always-a" "install: always-a@mp" "$out"
assert_has "installs ondemand-a" "install: ondemand-a@mp" "$out"
assert_has "installs ondemand-b" "install: ondemand-b@mp" "$out"
assert_not_has "never installs the plain-false, non-on-demand entry" "install: never-installed@mp" "$out"
assert_has "verify summary counts BOTH tiers (4)" "All 4 enabled plugins present" "$out"
if [ "$(jq -Sc '.enabledPlugins' "$TMP/settings-not-created.json")" = '{"always-a@mp":true,"always-b@mp":true,"ondemand-a@mp":false,"ondemand-b@mp":false}' ]; then
    echo "PASS missing settings file: fresh installs end with exactly the two tiers"
else
    echo "FAIL missing settings file: fresh install tier state is wrong"; FAILED=$((FAILED + 1))
fi

# ── 2: presence-verify covers the whole union — a missing ON-DEMAND plugin
#      fails the install, exactly like a missing always-plugin would ─────────
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp" \
      STUB_SETTINGS_FILE="$TMP/settings-not-created2.json" \
      bash "$script" --template "$TEMPLATE" --settings "$TMP/settings-not-created2.json" 2>&1); rc=$?
assert_rc "missing on-demand plugin fails the install" 1 "$rc"
assert_has "names the missing on-demand plugin" "ondemand-b@mp" "$out"

# ── 4: RED control #1 — after a real run, settings ends up with EXACTLY the
#      ALWAYS tier at true and every onDemandPlugins key at false ───────────
SETTINGS4="$TMP/settings4.json"
echo '{}' > "$SETTINGS4"
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_SETTINGS_FILE="$SETTINGS4" \
      bash "$script" --template "$TEMPLATE" --settings "$SETTINGS4" 2>&1); rc=$?
assert_rc "real run against a fresh settings file exits 0" 0 "$rc"
GOT4=$(jq -Sc '.enabledPlugins' "$SETTINGS4")
WANT4='{"always-a@mp":true,"always-b@mp":true,"ondemand-a@mp":false,"ondemand-b@mp":false}'
if [ "$GOT4" = "$WANT4" ]; then
    echo "PASS RED#1: effective enabledPlugins is EXACTLY the always tier (true) + on-demand tier (false)"
else
    echo "FAIL RED#1: enabledPlugins mismatch — want $WANT4, got $GOT4"; FAILED=$((FAILED + 1))
fi

# ── 5: RED control #2 — no-clobber: pre-seed one on-demand spec as `true`
#      (operator already enabled it); a re-run must NOT flip it back off ────
SETTINGS5="$TMP/settings5.json"
cat > "$SETTINGS5" <<'JSON'
{ "enabledPlugins": { "ondemand-a@mp": true } }
JSON
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_SETTINGS_FILE="$SETTINGS5" \
      bash "$script" --template "$TEMPLATE" --settings "$SETTINGS5" 2>&1); rc=$?
assert_rc "no-clobber run exits 0" 0 "$rc"
GOT_A=$(jq -r '.enabledPlugins["ondemand-a@mp"]' "$SETTINGS5")
GOT_B=$(jq -r '.enabledPlugins["ondemand-b@mp"]' "$SETTINGS5")
if [ "$GOT_A" = "true" ]; then
    echo "PASS RED#2: operator's pre-existing ondemand-a@mp=true survives the re-run unchanged"
else
    echo "FAIL RED#2: ondemand-a@mp was clobbered — expected true, got $GOT_A"; FAILED=$((FAILED + 1))
fi
if [ "$GOT_B" = "false" ]; then
    echo "PASS RED#2: the ABSENT ondemand-b@mp is still written as false"
else
    echo "FAIL RED#2: ondemand-b@mp expected false, got $GOT_B"; FAILED=$((FAILED + 1))
fi

# Native-Windows jq emits CRLF from `-r`; the trailing CR must never become
# part of an enabledPlugins key when the non-override line set is converted
# back to JSON. Keep the pre-install true override while asserting the exact
# final key set, so both halves of the boundary are covered.
SETTINGS5_CRLF="$TMP/settings5-crlf.json"
cat > "$SETTINGS5_CRLF" <<'JSON'
{ "enabledPlugins": { "ondemand-a@mp": true } }
JSON
out=$(PATH="$STUB_DIR:$PATH" STUB_JQ_CRLF_RAW=1 \
      STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_SETTINGS_FILE="$SETTINGS5_CRLF" \
      bash "$script" --template "$TEMPLATE" --settings "$SETTINGS5_CRLF" 2>&1); rc=$?
assert_rc "native-jq CRLF non-override run exits 0" 0 "$rc"
GOT5_CRLF=$("$REAL_JQ" -Sc '.enabledPlugins' "$SETTINGS5_CRLF")
WANT5_CRLF='{"always-a@mp":true,"always-b@mp":true,"ondemand-a@mp":true,"ondemand-b@mp":false}'
if [ "$GOT5_CRLF" = "$WANT5_CRLF" ]; then
    echo "PASS native-jq CRLF preserves exact plugin keys and the pre-install true override"
else
    echo "FAIL native-jq CRLF key boundary — want $WANT5_CRLF, got $GOT5_CRLF"; FAILED=$((FAILED + 1))
fi

# ── 6: force-enable (HIMMEL-2292) never touches an on-demand spec — installed
#      + present in `claude plugin list`, still `false` in live settings ────
# STUB_ALREADY_INSTALLED = all four: this fixture is exactly HIMMEL-2292's own
# drift scenario (already installed, drifted to `false`), so the install loop
# below must be a no-op for every spec here — a stub that instead wrote `true`
# on every install call would make this drift state unreachable in the first
# place, and force-enable would never fire in this test.
SETTINGS6="$TMP/settings6.json"
cat > "$SETTINGS6" <<'JSON'
{ "enabledPlugins": { "always-a@mp": false, "always-b@mp": false, "ondemand-a@mp": false, "ondemand-b@mp": false } }
JSON
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_SETTINGS_FILE="$SETTINGS6" \
      STUB_ALREADY_INSTALLED="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      bash "$script" --template "$TEMPLATE" --settings "$SETTINGS6" 2>&1); rc=$?
assert_rc "force-enable run exits 0" 0 "$rc"
assert_has "force-enables the drifted always-a" "enable: always-a@mp" "$out"
assert_has "force-enables the drifted always-b" "enable: always-b@mp" "$out"
assert_not_has "force-enable NEVER names ondemand-a" "enable: ondemand-a@mp" "$out"
assert_not_has "force-enable NEVER names ondemand-b" "enable: ondemand-b@mp" "$out"
if [ "$(jq -r '.enabledPlugins["always-a@mp"]' "$SETTINGS6")" = "true" ] \
   && [ "$(jq -r '.enabledPlugins["always-b@mp"]' "$SETTINGS6")" = "true" ] \
   && [ "$(jq -r '.enabledPlugins["ondemand-a@mp"]' "$SETTINGS6")" = "false" ] \
   && [ "$(jq -r '.enabledPlugins["ondemand-b@mp"]' "$SETTINGS6")" = "false" ]; then
    echo "PASS: final settings — always tier force-enabled true, on-demand tier stays false"
else
    echo "FAIL: final settings6.json wrong: $(cat "$SETTINGS6")"; FAILED=$((FAILED + 1))
fi

# ── 7a: a partial install failure must normalize successful fresh on-demand
#      installs before presence verification exits. The retry must not snapshot
#      the install side effect as a deliberate pre-existing true override. ───
SETTINGS7_PARTIAL="$TMP/settings7-partial.json"
printf '%s\n' '{}' > "$SETTINGS7_PARTIAL"
out=$(PATH="$STUB_DIR:$PATH" \
      STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp" \
      STUB_INSTALL_FAIL="ondemand-b@mp" \
      STUB_SETTINGS_FILE="$SETTINGS7_PARTIAL" \
      bash "$script" --template "$TEMPLATE" --settings "$SETTINGS7_PARTIAL" 2>&1); rc=$?
assert_rc "partial install still fails presence verification" 1 "$rc"
assert_has "partial install names the missing on-demand plugin" "ondemand-b@mp" "$out"
assert_not_has "partial install never claims Done" "──── Done ────" "$out"
if [ "$(jq -r '.enabledPlugins["ondemand-a@mp"]' "$SETTINGS7_PARTIAL")" = "false" ]; then
    echo "PASS partial failure normalizes the successful fresh on-demand install before exit"
else
    echo "FAIL partial failure left successful ondemand-a@mp enabled"; FAILED=$((FAILED + 1))
fi
out=$(PATH="$STUB_DIR:$PATH" \
      STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_ALREADY_INSTALLED="always-a@mp always-b@mp ondemand-a@mp" \
      STUB_SETTINGS_FILE="$SETTINGS7_PARTIAL" \
      bash "$script" --template "$TEMPLATE" --settings "$SETTINGS7_PARTIAL" 2>&1); rc=$?
assert_rc "partial-install retry succeeds" 0 "$rc"
if [ "$(jq -r '.enabledPlugins["ondemand-a@mp"]' "$SETTINGS7_PARTIAL")" = "false" ] \
   && [ "$(jq -r '.enabledPlugins["ondemand-b@mp"]' "$SETTINGS7_PARTIAL")" = "false" ]; then
    echo "PASS partial-install retry keeps both nonoverride on-demand plugins disabled"
else
    echo "FAIL partial-install retry promoted an install side effect to an override"; FAILED=$((FAILED + 1))
fi

# ── 7b: a failed `plugin list` has the same ordering requirement. Every
#      install succeeded and wrote true, but verification still fails closed;
#      normalization must happen first so the retry cannot preserve those
#      installer-written values as overrides. ───────────────────────────────
SETTINGS7_LIST="$TMP/settings7-list.json"
printf '%s\n' '{}' > "$SETTINGS7_LIST"
out=$(PATH="$STUB_DIR:$PATH" STUB_LIST_FAIL=1 \
      STUB_SETTINGS_FILE="$SETTINGS7_LIST" \
      bash "$script" --template "$TEMPLATE" --settings "$SETTINGS7_LIST" 2>&1); rc=$?
assert_rc "plugin-list failure still exits 1" 1 "$rc"
assert_has "plugin-list failure surfaces its diagnostic" "stub: list boom" "$out"
assert_not_has "plugin-list failure never claims Done" "──── Done ────" "$out"
if [ "$(jq -r '.enabledPlugins["ondemand-a@mp"]' "$SETTINGS7_LIST")" = "false" ] \
   && [ "$(jq -r '.enabledPlugins["ondemand-b@mp"]' "$SETTINGS7_LIST")" = "false" ]; then
    echo "PASS list failure normalizes successful fresh on-demand installs before exit"
else
    echo "FAIL list failure left fresh on-demand installs enabled"; FAILED=$((FAILED + 1))
fi
out=$(PATH="$STUB_DIR:$PATH" \
      STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_ALREADY_INSTALLED="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_SETTINGS_FILE="$SETTINGS7_LIST" \
      bash "$script" --template "$TEMPLATE" --settings "$SETTINGS7_LIST" 2>&1); rc=$?
assert_rc "plugin-list-failure retry succeeds" 0 "$rc"
if [ "$(jq -Sc '.enabledPlugins' "$SETTINGS7_LIST")" = "$WANT4" ]; then
    echo "PASS plugin-list-failure retry preserves the lean two-tier state"
else
    echo "FAIL plugin-list-failure retry promoted installer-written true values"; FAILED=$((FAILED + 1))
fi

# The PowerShell twin must normalize before its list invocation too. This is a
# static ordering assertion here because this host has no pwsh runtime.
PS_SCRIPT="$repo_root/scripts/machine-setup/install-plugins.ps1"
PS_NORMALIZE_LINE=$(grep -n '^# ── Register on-demand plugins as disabled' "$PS_SCRIPT" | cut -d: -f1)
PS_LIST_LINE=$(grep -n "^\\\$listLines = & claude plugin list" "$PS_SCRIPT" | cut -d: -f1)
if [ -n "$PS_NORMALIZE_LINE" ] && [ -n "$PS_LIST_LINE" ] && [ "$PS_NORMALIZE_LINE" -lt "$PS_LIST_LINE" ]; then
    echo "PASS PowerShell twin normalizes on-demand plugins before presence listing"
else
    echo "FAIL PowerShell twin still verifies before on-demand normalization"; FAILED=$((FAILED + 1))
fi
# Literal PowerShell variable in source assertion.
# shellcheck disable=SC2016
PS_NORMALIZE_CONDITION=$(grep '^if (\$onDemandKeys.Count -gt 0' "$PS_SCRIPT" || true)
if [ -n "$PS_NORMALIZE_CONDITION" ] && ! grep -Fq "settingsFileBasenameLc -ne 'settings.local.json'" <<< "$PS_NORMALIZE_CONDITION"; then
    echo "PASS PowerShell twin allows on-demand normalization for its resolved local target"
else
    echo "FAIL PowerShell twin still excludes settings.local.json from on-demand normalization"; FAILED=$((FAILED + 1))
fi
# Literal PowerShell variable in source assertion.
# shellcheck disable=SC2016
if grep -Fq "if (\$Scope -ceq 'user')" "$PS_SCRIPT" \
   && grep -Fq 'claude plugin enable <spec> --scope $Scope' "$PS_SCRIPT"; then
    echo "PASS PowerShell twin branches the activation recipe by actual scope"
else
    echo "FAIL PowerShell twin does not branch the activation recipe by actual scope"; FAILED=$((FAILED + 1))
fi

# ── 8: install summary names on-demand specs + neededBy + enable recipe, and
#      the onDemandConnectors tier ───────────────────────────────────────────
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="always-a@mp always-b@mp ondemand-a@mp ondemand-b@mp" \
      STUB_SETTINGS_FILE="$TMP/settings8.json" \
      bash "$script" --template "$TEMPLATE" --settings "$TMP/settings8.json" 2>&1); rc=$?
assert_rc "summary run exits 0" 0 "$rc"
assert_has "summary names ondemand-a with its neededBy" "ondemand-a@mp — thing A" "$out"
assert_has "summary names ondemand-b with its neededBy" "ondemand-b@mp — thing B" "$out"
assert_has "summary prints the enable recipe" "/profile enable <spec>" "$out"
assert_has "summary prints the CLI fallback recipe" "claude plugin enable <spec> --scope user" "$out"
assert_has "summary names the onDemandConnectors tier" "claude-in-chrome" "$out"
assert_has "summary says connectors aren't installed by himmel" "Not installed by himmel" "$out"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"; exit 0
else
    echo "$FAILED FAILURE(S)"; exit 1
fi
