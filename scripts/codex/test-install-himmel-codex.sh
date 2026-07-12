#!/usr/bin/env bash
# Hermetic tests for install-himmel-codex.sh (HIMMEL-597).
# No real Codex install needed: a stub `codex` CLI simulates
# `plugin marketplace list/add` and `plugin list/add`, driven by test-controlled
# state files, and records every mutating call to a log. Asserts the installer is
# idempotent (no re-add when already installed+enabled), registers the himmel
# marketplace when absent, adds only the missing plugins, honours --dry-run, and
# is non-destructive (never removes/disables anything).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-himmel-codex.sh"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
# `-e "$2"` so a pattern beginning with '-' (e.g. "--disable") is not parsed as a grep option.
assert_log_has()  { if grep -qF -e "$2" "$1"; then pass "$3"; else fail "$3 (missing '$2' in call-log)"; fi; }
assert_log_lacks(){ if grep -qF -e "$2" "$1"; then fail "$3 (unexpected '$2' in call-log)"; else pass "$3"; fi; }
assert_count()    { local n; n="$(grep -cF -e "$2" "$1" || true)"; if [ "$n" = "$3" ]; then pass "$4"; else fail "$4 (count '$2' = $n, want $3)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub `codex` CLI --------------------------------------------------------
# State dir ($CODEX_STUB_STATE):
#   marketplaces.txt : one marketplace NAME per line (drives `marketplace list`)
#   plugins.txt      : "name@marketplace<TAB>STATUS" per line (drives `plugin list`)
#   calls.log        : every mutating invocation, appended by the stub
STUB="$TMP/codex-stub.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
S="${CODEX_STUB_STATE:?CODEX_STUB_STATE unset}"
log() { echo "$*" >> "$S/calls.log"; }
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "list" ]; then
  echo "MARKETPLACE                  ROOT"
  if [ -f "$S/marketplaces.txt" ]; then
    while IFS= read -r m; do [ -n "$m" ] && printf '%-28s %s\n' "$m" "/fake/$m"; done < "$S/marketplaces.txt"
  fi
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "add" ]; then
  log "marketplace add ${4:-}"; exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  echo "PLUGIN                                   STATUS              VERSION  PATH"
  if [ -f "$S/plugins.txt" ]; then
    while IFS="$(printf '\t')" read -r sel status; do
      [ -n "$sel" ] && printf '%-40s %-19s local     /fake/%s\n' "$sel" "$status" "$sel"
    done < "$S/plugins.txt"
  fi
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "add" ]; then
  log "plugin add ${3:-}"; exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "remove" ]; then
  log "plugin remove ${3:-}"; exit 0
fi
exit 0
STUB_EOF
chmod +x "$STUB"

mk_state() {  # $1 = state dir; seeds empty marketplaces + plugins + calls
  local s="$1"; rm -rf "$s"; mkdir -p "$s"
  : > "$s/marketplaces.txt"; : > "$s/plugins.txt"; : > "$s/calls.log"
}

run() {  # state-dir, then installer args
  local s="$1"; shift
  # CODEX_HOME -> an empty temp dir so the wired sanitize-plugin-hooks step
  # (HIMMEL-651) finds no plugin cache and no-ops, keeping the test hermetic
  # (never touches the real ~/.codex cache).
  CODEX_BIN="$STUB" CODEX_STUB_STATE="$s" CODEX_HOME="$TMP/codex-home" bash "$INSTALLER" "$@"
}

DEFAULT_SET="himmel-ops handover obsidian-triage telegram-himmel"

echo "== scenario A: fresh machine (no himmel marketplace, no plugins) =="
S="$TMP/A"; mk_state "$S"
# only foreign marketplaces/plugins present
printf 'openai-bundled\n' > "$S/marketplaces.txt"
printf 'browser@openai-bundled\tinstalled, enabled\n' > "$S/plugins.txt"
run "$S" >/dev/null
assert_log_has  "$S/calls.log" "marketplace add"           "registers himmel marketplace when absent"
assert_count    "$S/calls.log" "plugin add"              "4" "adds all 4 default plugins"
for p in $DEFAULT_SET; do assert_log_has "$S/calls.log" "plugin add $p@himmel" "adds $p"; done

echo "== scenario B: idempotent (marketplace present, all targets installed+enabled) =="
S="$TMP/B"; mk_state "$S"
printf 'openai-bundled\nhimmel\n' > "$S/marketplaces.txt"
{ for p in $DEFAULT_SET; do printf '%s@himmel\tinstalled, enabled\n' "$p"; done; } > "$S/plugins.txt"
run "$S" >/dev/null
assert_log_lacks "$S/calls.log" "marketplace add" "no re-register when himmel marketplace present"
assert_log_lacks "$S/calls.log" "plugin add"      "no re-add when all targets enabled (idempotent)"

echo "== scenario C: one target not installed (others enabled) =="
S="$TMP/C"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"
{ printf 'himmel-ops@himmel\tnot installed\n';
  printf 'handover@himmel\tinstalled, enabled\n';
  printf 'obsidian-triage@himmel\tinstalled, enabled\n';
  printf 'telegram-himmel@himmel\tinstalled, enabled\n'; } > "$S/plugins.txt"
run "$S" >/dev/null
assert_count    "$S/calls.log" "plugin add" "1" "adds exactly the one missing plugin"
assert_log_has  "$S/calls.log" "plugin add himmel-ops@himmel" "adds the not-installed himmel-ops"
assert_log_lacks "$S/calls.log" "plugin add handover@himmel"  "leaves already-enabled handover untouched"

echo "== scenario D: --dry-run reports but does not mutate =="
S="$TMP/D"; mk_state "$S"
printf 'openai-bundled\n' > "$S/marketplaces.txt"; : > "$S/plugins.txt"
out="$(run "$S" --dry-run)"
assert_log_lacks "$S/calls.log" "marketplace add" "--dry-run issues no marketplace add"
assert_log_lacks "$S/calls.log" "plugin add"      "--dry-run issues no plugin add"
if printf '%s' "$out" | grep -qiE 'would|dry'; then pass "--dry-run reports intended changes"; else fail "--dry-run gave no change report"; fi

echo "== scenario E: codex CLI missing -> exit 1, no calls =="
S="$TMP/E"; mk_state "$S"
rc=0; CODEX_BIN="$TMP/nope-not-a-codex" CODEX_STUB_STATE="$S" bash "$INSTALLER" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "1" ]; then pass "missing codex CLI exits 1"; else fail "missing codex CLI exit=$rc (want 1)"; fi
assert_log_lacks "$S/calls.log" "add" "no calls when codex CLI missing"

echo "== scenario F: non-destructive (never removes/disables) =="
S="$TMP/F"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"
printf 'himmel-ops@himmel\tnot installed\n' > "$S/plugins.txt"
run "$S" >/dev/null
assert_log_lacks "$S/calls.log" "remove"    "never calls plugin/marketplace remove"
assert_log_lacks "$S/calls.log" "--disable" "never disables a plugin"

echo "== scenario G: --plugins override =="
S="$TMP/G"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"; : > "$S/plugins.txt"
run "$S" --plugins=himmel-ops >/dev/null
assert_count   "$S/calls.log" "plugin add" "1" "--plugins restricts the set to one"
assert_log_has "$S/calls.log" "plugin add himmel-ops@himmel" "--plugins adds the named plugin"

echo "== scenario H: unknown argument -> exit 2, no calls =="
S="$TMP/H"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"
rc=0; run "$S" --bogus >/dev/null 2>&1 || rc=$?
if [ "$rc" = "2" ]; then pass "unknown arg exits 2"; else fail "unknown arg exit=$rc (want 2)"; fi
assert_log_lacks "$S/calls.log" "add" "no calls on unknown arg"

echo "== scenario I: @marketplace discrimination (same plugin name, different marketplace) =="
S="$TMP/I"; mk_state "$S"
printf 'himmel\nopenai-bundled\n' > "$S/marketplaces.txt"
# himmel-ops is installed+enabled under ANOTHER marketplace; the himmel one is absent.
printf 'himmel-ops@openai-bundled\tinstalled, enabled\n' > "$S/plugins.txt"
run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "plugin add himmel-ops@himmel" "still adds himmel-ops@himmel despite same name in another marketplace"

echo "== scenario J: marketplace name exact-match (near-miss must not satisfy) =="
S="$TMP/J"; mk_state "$S"
printf 'himmel-extra\n' > "$S/marketplaces.txt"   # 'himmel' absent; only a substring-y near-miss present
: > "$S/plugins.txt"
run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "marketplace add" "registers 'himmel' when only 'himmel-extra' present (no substring false-match)"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED" >&2; exit 1; fi
