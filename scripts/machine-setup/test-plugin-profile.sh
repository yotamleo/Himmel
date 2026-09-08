#!/usr/bin/env bash
# test-plugin-profile.sh — hermetic tests for the two-tier plugin profile
# toggle engine (HIMMEL-2733), scripts/machine-setup/plugin-profile.sh.
#
# Stubs the `claude` CLI on PATH so nothing touches the operator's real
# plugin set: `claude plugin list` prints a stanza per spec named in
# $STUB_LIVE ("<spec> <enabled|disabled>", newline-separated; a spec absent
# from $STUB_LIVE is reported [absent] by the script under test), matching
# the ❯/Scope:/Status: shape plugin-profile.sh's own awk parser expects.
# `claude plugin enable|disable <spec> --scope user` appends its argv to
# $CALL_LOG instead of touching anything real, so a case can assert EXACTLY
# which writes happened (or that none did).
#
# plugin-profile.ps1 carries the SAME resolution + refusal rules as a
# PowerShell twin — not covered here (this repo has no pwsh runner); sanity
# check with `pwsh plugin-profile.ps1` on a Windows host per its own header.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Stubs the claude CLI and relies on git, jq, and temporary directories; NOT ported to native
# PowerShell. A test harness needs no .ps1 twin (project convention: a
# documented platform guard suffices for a test fixture).
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/plugin-profile.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-plugin-profile.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
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

assert_empty_file() {
  local label="$1" file="$2"
  if [ -s "$file" ]; then
    echo "FAIL $label — expected empty, got:"; sed 's/^/    /' "$file"; FAILED=$((FAILED + 1))
  else
    echo "PASS $label"
  fi
}

assert_lines_eq() {
  # Order-independent line-set comparison — a case cares WHICH calls
  # happened, not the order the on-demand map's keys iterate in.
  local label="$1" file="$2"; shift 2
  local want got
  want=$(printf '%s\n' "$@" | sort)
  got=$(sort < "$file")
  if [ "$got" = "$want" ]; then
    echo "PASS $label"
  else
    echo "FAIL $label — expected:"; printf '%s\n' "$want" | sed 's/^/    want> /'
    echo "  got:"; sed 's/^/    got>  /' "$file"
    FAILED=$((FAILED + 1))
  fi
}

# ── Stub `claude` ─────────────────────────────────────────────────────────
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  # STUB_LIST_FAIL simulates a broken `claude plugin list` (e.g. corrupted CLI).
  if [ -n "${STUB_LIST_FAIL:-}" ]; then echo "stub: list boom" >&2; exit 3; fi
  # Observed real CLI shapes: a non-empty response starts with this header and
  # complete four-line stanzas; a genuinely empty install has one exact sentence.
  case "${STUB_LIST_MODE:-normal}" in
    garbage) printf '%s\n' 'garbled success payload'; exit 0 ;;
    malformed-status)
      printf 'Installed plugins:\n\n  ❯ od-a@mkt\n    Version: 1.0.0\n    Scope: user\n    Status: ? maybe\n'
      exit 0 ;;
    malformed-stanza)
      printf 'Installed plugins:\n\n  ❯ od-a@mkt\n    Scope: user\n    Status: ✔ enabled\n'
      exit 0 ;;
    valid-empty)
      printf '%s\n' 'No plugins installed. Use `claude plugin install` to install a plugin.'
      exit 0 ;;
    project-only)
      printf 'Installed plugins:\n\n  ❯ od-a@mkt\n    Version: 1.0.0\n    Scope: project\n    Status: ✘ disabled\n'
      exit 0 ;;
  esac
  # STUB_LIVE: newline-separated "<spec> <enabled|disabled>"; a spec named
  # here is "installed at user scope"; a spec never named is "absent".
  printf 'Installed plugins:\n\n'
  printf '%s\n' "${STUB_LIVE:-}" | while IFS=' ' read -r spec state; do
    [ -z "$spec" ] && continue
    if [ "${STUB_CRLF:-0}" = 1 ]; then
      printf '❯ %s\r\n  Version: 1.0.0\r\n  Scope: user\r\n  Status: ● %s\r\n\r\n' "$spec" "$state"
    else
      printf '❯ %s\n  Version: 1.0.0\n  Scope: user\n  Status: ● %s\n\n' "$spec" "$state"
    fi
  done
  exit 0
fi
if [ "${1:-}" = "plugin" ] && { [ "${2:-}" = "enable" ] || [ "${2:-}" = "disable" ]; }; then
  echo "$*" >> "${CALL_LOG:?CALL_LOG not set for stub claude}"
  exit 0
fi
echo "stub: unhandled claude invocation: $*" >&2
exit 9
STUB
chmod +x "$STUB_DIR/claude"

CALL_LOG="$TMP/calls.log"
: > "$CALL_LOG"

run() {  # run <args...> — drives the real script with the stub claude on PATH
  PATH="$STUB_DIR:$PATH" CALL_LOG="$CALL_LOG" STUB_LIVE="${STUB_LIVE:-}" STUB_LIST_FAIL="${STUB_LIST_FAIL:-}" STUB_CRLF="${STUB_CRLF:-0}" STUB_LIST_MODE="${STUB_LIST_MODE:-normal}" \
    bash "$script" "$@" 2>&1
}

# ── Fixture: the general two-tier template (one ambiguous bare name) ───────
TMPL="$TMP/settings-template.json"
cat > "$TMPL" <<'JSON'
{
  "enabledPlugins": {
    "handover@himmel": true,
    "himmel-ops@himmel": true,
    "qmd@himmel": true,
    "always-x@mkt": true,
    "od-a@mkt": false,
    "od-b@mkt": false,
    "amb@mktA": false,
    "amb@mktB": false
  },
  "onDemandPlugins": {
    "od-a@mkt": { "neededBy": "thing A" },
    "od-b@mkt": { "neededBy": "thing B" },
    "amb@mktA": { "neededBy": "ambiguous A" },
    "amb@mktB": { "neededBy": "ambiguous B" }
  },
  "onDemandConnectors": {
    "conn-x": { "neededBy": "connector x need", "enableVia": "somewhere" }
  }
}
JSON

# ── 1: list — both tiers, live state, [disabled] vs [absent] ────────────────
: > "$CALL_LOG"
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nalways-x@mkt enabled\nod-a@mkt enabled\nod-b@mkt disabled'
out=$(run list --template "$TMPL"); rc=$?
assert_rc "list exits 0" 0 "$rc"
assert_has "list shows always-tier live state" "[enabled] always-x@mkt" "$out"
assert_has "list shows installed-disabled on-demand as [disabled]" "[disabled] od-b@mkt" "$out"
assert_has "list shows an uninstalled on-demand spec as [absent]" "[absent] amb@mktA" "$out"
assert_empty_file "list issues no writes" "$CALL_LOG"

# ── 2: list --json — valid JSON, tiers carry neededBy / live state ──────────
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nalways-x@mkt enabled\nod-a@mkt enabled\nod-b@mkt disabled'
out=$(run list --json --template "$TMPL"); rc=$?
assert_rc "list --json exits 0" 0 "$rc"
if echo "$out" | jq -e . >/dev/null 2>&1; then echo "PASS list --json emits valid JSON"; else echo "FAIL list --json emits valid JSON — got: $out"; FAILED=$((FAILED + 1)); fi
if [ "$(echo "$out" | jq -r '.onDemand[] | select(.spec=="od-a@mkt") | .neededBy')" = "thing A" ]; then
  echo "PASS list --json onDemand carries neededBy"
else
  echo "FAIL list --json onDemand carries neededBy"; FAILED=$((FAILED + 1))
fi
if [ "$(echo "$out" | jq -r '.always[] | select(.spec=="always-x@mkt") | .state')" = "enabled" ]; then
  echo "PASS list --json always carries live state"
else
  echo "FAIL list --json always carries live state"; FAILED=$((FAILED + 1))
fi
if [ "$(echo "$out" | jq -r '.connectors[] | select(.name=="conn-x") | .neededBy')" = "connector x need" ]; then
  echo "PASS list --json connectors carry neededBy"
else
  echo "FAIL list --json connectors carry neededBy"; FAILED=$((FAILED + 1))
fi

# ── Fixture: lean/full template (three on-demand specs, no ambiguity) ───────
TMPL_LF="$TMP/settings-template-leanfull.json"
cat > "$TMPL_LF" <<'JSON'
{
  "enabledPlugins": {
    "handover@himmel": true, "himmel-ops@himmel": true, "qmd@himmel": true,
    "od-a@mkt": false, "od-b@mkt": false, "od-c@mkt": false
  },
  "onDemandPlugins": {
    "od-a@mkt": { "neededBy": "a" },
    "od-b@mkt": { "neededBy": "b" },
    "od-c@mkt": { "neededBy": "c" }
  }
}
JSON

# ── 3: lean — exactly two disable calls, zero enables ────────────────────────
: > "$CALL_LOG"
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nod-a@mkt enabled\nod-b@mkt enabled\nod-c@mkt disabled'
out=$(run lean --template "$TMPL_LF"); rc=$?
assert_rc "lean exits 0" 0 "$rc"
assert_lines_eq "lean issues exactly the two needed disable calls" "$CALL_LOG" \
  "plugin disable od-a@mkt --scope user" "plugin disable od-b@mkt --scope user"
assert_not_has "lean issues zero enable calls" "enable" "$(cat "$CALL_LOG")"

# ── 4: lean when already lean — no-op, empty call log, rc 0 ─────────────────
: > "$CALL_LOG"
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nod-a@mkt disabled\nod-b@mkt disabled\nod-c@mkt disabled'
out=$(run lean --template "$TMPL_LF"); rc=$?
assert_rc "lean no-op exits 0" 0 "$rc"
assert_empty_file "lean no-op issues no writes" "$CALL_LOG"
assert_has "lean no-op reports nothing to change" "already lean" "$out"
assert_has "lean no-op limits its claim to user scope" "user scope" "$out"
assert_has "lean no-op warns that higher-precedence settings may override" "project/local settings may override effective state" "$out"

# ── 5: full — enables exactly the disabled on-demand specs, skips absent ────
: > "$CALL_LOG"
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nod-a@mkt disabled\nod-c@mkt enabled'
out=$(run full --template "$TMPL_LF"); rc=$?
assert_rc "full exits 0" 0 "$rc"
assert_lines_eq "full enables exactly the one disabled+installed spec" "$CALL_LOG" \
  "plugin enable od-a@mkt --scope user"
assert_has "full says it only targets installed on-demand plugins" "installed on-demand plugins" "$out"
assert_has "full skips the absent spec" "skip: od-b@mkt" "$out"

# ── Fixture: a floor plugin misplaced in onDemandPlugins by a --template
#      override (HIMMEL-2733 finding 7 — the bulk loop must refuse it too) ───
TMPL_FLOOR_OD="$TMP/settings-template-floor-ondemand.json"
cat > "$TMPL_FLOOR_OD" <<'JSON'
{
  "enabledPlugins": {
    "handover@himmel": false, "himmel-ops@himmel": true, "qmd@himmel": true,
    "od-a@mkt": false
  },
  "onDemandPlugins": {
    "handover@himmel": { "neededBy": "floor-in-ondemand misconfiguration test" },
    "od-a@mkt": { "neededBy": "a" }
  }
}
JSON

# ── 5b: lean's bulk loop refuses to disable a floor plugin even when a
#      template override lists it in onDemandPlugins — the floor refusal
#      lives in the shared writer now, not only the single-spec `disable`
#      path, so `lean`/`full` cannot bypass it (HIMMEL-2733 finding 7) ──────
: > "$CALL_LOG"
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nod-a@mkt enabled'
out=$(run lean --template "$TMPL_FLOOR_OD"); rc=$?
assert_rc "lean over a floor-in-ondemand template exits 1 (write refused)" 1 "$rc"
assert_not_has "lean NEVER disables a floor plugin via onDemandPlugins" "plugin disable handover@himmel" "$(cat "$CALL_LOG")"
assert_has "lean still disables the legitimate od-a@mkt" "plugin disable od-a@mkt --scope user" "$(cat "$CALL_LOG")"
assert_has "lean prints the floor refusal" "floor" "$out"

# ── 6: enable <bare-name> resolution ─────────────────────────────────────────
: > "$CALL_LOG"
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nod-a@mkt disabled'
out=$(run enable od-a --template "$TMPL"); rc=$?
assert_rc "enable bare unambiguous name exits 0" 0 "$rc"
assert_lines_eq "enable bare name resolves to full spec" "$CALL_LOG" "plugin enable od-a@mkt --scope user"
assert_has "toggle success says only user scope changed" "user scope changed: enable od-a@mkt" "$out"
assert_has "toggle success warns that higher-precedence settings may override" "project/local settings may override effective state" "$out"
assert_has "on-demand advice calls the user sibling reconciliation input" "reconciliation input" "$out"
assert_has "on-demand advice says reconcile copies the override into settings.json" "copies it into settings.json" "$out"
assert_not_has "on-demand advice never calls the user sibling a runtime layer" "layers over settings.json" "$out"

: > "$CALL_LOG"
out=$(run enable amb --template "$TMPL"); rc=$?
assert_rc "enable ambiguous bare name exits 2" 2 "$rc"
assert_has "ambiguous error names candidate amb@mktA" "amb@mktA" "$out"
assert_has "ambiguous error names candidate amb@mktB" "amb@mktB" "$out"
assert_empty_file "ambiguous bare name writes nothing" "$CALL_LOG"

out=$(run enable nope-at-all --template "$TMPL"); rc=$?
assert_rc "enable unknown bare name exits 2" 2 "$rc"
assert_empty_file "unknown bare name writes nothing" "$CALL_LOG"

# ── 7: disable of each floor spec refuses, writes nothing ──────────────────
for floor_spec in handover@himmel himmel-ops@himmel qmd@himmel; do
  : > "$CALL_LOG"
  STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled'
  out=$(run disable "$floor_spec" --template "$TMPL"); rc=$?
  assert_rc "disable floor spec $floor_spec exits 2" 2 "$rc"
  assert_has "disable floor spec $floor_spec names the floor refusal" "floor" "$out"
  assert_empty_file "disable floor spec $floor_spec writes nothing" "$CALL_LOG"
done

# ── 8: enable of an absent spec — exit 1, install-it-first recipe ──────────
: > "$CALL_LOG"
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled'
out=$(run enable od-a@mkt --template "$TMPL"); rc=$?
assert_rc "enable of an absent spec exits 1" 1 "$rc"
assert_has "absent-spec error names the install recipe" "install-plugins.sh" "$out"
assert_empty_file "enable of an absent spec writes nothing" "$CALL_LOG"

# ── 9: claude plugin list fails — exit 1, claims no state ───────────────────
: > "$CALL_LOG"
STUB_LIVE=""
STUB_LIST_FAIL=1
out=$(run list --template "$TMPL"); rc=$?
STUB_LIST_FAIL=
assert_rc "list-failure fails closed" 1 "$rc"
assert_not_has "list-failure does not print any [enabled] state" "[enabled]" "$out"
assert_not_has "list-failure does not print any [disabled] state" "[disabled]" "$out"
assert_empty_file "list-failure writes nothing" "$CALL_LOG"

# Exit 0 is not enough: only the two observed CLI response shapes are trusted.
# Garbage and incomplete/unknown stanzas must fail closed before lean/full can
# mistake an empty parse for an already-converged user map.
for bad_mode in garbage malformed-status malformed-stanza; do
  : > "$CALL_LOG"
  STUB_LIST_MODE="$bad_mode"
  STUB_LIVE=""
  out=$(run lean --template "$TMPL_LF"); rc=$?
  assert_rc "$bad_mode exit-0 list response fails closed" 1 "$rc"
  assert_has "$bad_mode names the unrecognized list response" "unrecognized response" "$out"
  assert_not_has "$bad_mode never claims already lean" "already lean" "$out"
  assert_empty_file "$bad_mode causes no plugin writes" "$CALL_LOG"
done
STUB_LIST_MODE=normal

# The real CLI's exact no-installed-plugins sentence is a supported empty map.
: > "$CALL_LOG"
STUB_LIST_MODE=valid-empty
out=$(run list --template "$TMPL_LF"); rc=$?
assert_rc "valid empty plugin-list response exits 0" 0 "$rc"
assert_has "valid empty response reports template plugins absent" "[absent] od-a@mkt" "$out"
assert_empty_file "valid empty response causes no writes" "$CALL_LOG"

# A valid response containing only a non-user stanza is also supported: this
# tool writes user scope, so project/local installs remain absent in its map.
: > "$CALL_LOG"
STUB_LIST_MODE=project-only
out=$(run full --template "$TMPL_LF"); rc=$?
assert_rc "valid project-only plugin-list response exits 0" 0 "$rc"
assert_has "project-only response remains absent at user scope" "skip: od-a@mkt (not installed at user scope" "$out"
assert_has "project-only full explicitly reports no installed user-scope targets" "no on-demand plugins installed at user scope" "$out"
assert_not_has "project-only full never claims the user profile is already full" "already full" "$out"
assert_has "project-only full preserves the scope-override caveat" "project/local" "$out"
assert_empty_file "project-only response causes no user-scope writes" "$CALL_LOG"
STUB_LIST_MODE=normal

# Help and both operator references must define `full` as installed-only, and
# the PowerShell twin must carry the same wording. Static PS coverage is used
# because this host has no pwsh runtime.
out=$(run --help); rc=$?
assert_rc "help exits 0" 0 "$rc"
assert_has "bash help defines full as installed-only at user scope" "Enable every installed on-demand plugin at user scope" "$out"
PS_PROFILE="$repo_root/scripts/machine-setup/plugin-profile.ps1"
if grep -Fq 'Enable every installed on-demand plugin at user scope.' "$PS_PROFILE"; then
  echo "PASS PowerShell help defines full as installed-only at user scope"
else
  echo "FAIL PowerShell help still overclaims full scope"; FAILED=$((FAILED + 1))
fi
if grep -Fq 'reconciliation input' "$PS_PROFILE" \
   && grep -Fq 'copies it into settings.json' "$PS_PROFILE" \
   && ! grep -Fq 'layers over settings.json' "$PS_PROFILE"; then
  echo "PASS PowerShell on-demand advice describes reconciliation, not runtime layering"
else
  echo "FAIL PowerShell on-demand advice still misdescribes the user sibling as runtime layering"; FAILED=$((FAILED + 1))
fi
for doc in "$repo_root/docs/configuration.md" "$repo_root/docs/setup/new-machine.md"; do
  doc_text=$(tr '\n' ' ' < "$doc")
  case "$doc_text" in
    *"installed on-demand plugins at user scope"*)
      echo "PASS $(basename "$doc") documents full's installed-only user scope" ;;
    *)
      echo "FAIL $(basename "$doc") does not document full's installed-only user scope"; FAILED=$((FAILED + 1)) ;;
  esac
done

# ── 10: --dry-run prints the command, call log stays empty ──────────────────
: > "$CALL_LOG"
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nod-a@mkt enabled\nod-b@mkt enabled\nod-c@mkt disabled'
out=$(run lean --dry-run --template "$TMPL_LF"); rc=$?
assert_rc "--dry-run exits 0" 0 "$rc"
assert_has "--dry-run prints the DRY command" "DRY: claude plugin disable od-a@mkt --scope user" "$out"
assert_empty_file "--dry-run issues no real writes" "$CALL_LOG"

# ── CRLF list output must not turn installed plugins into absent no-ops ────
STUB_CRLF=1
STUB_LIVE=$'handover@himmel enabled\nhimmel-ops@himmel enabled\nqmd@himmel enabled\nod-a@mkt enabled\nod-b@mkt disabled'
out=$(run list --template "$TMPL_LF"); rc=$?
assert_rc "CRLF list exits 0" 0 "$rc"
assert_has "CRLF preserves enabled state" "[enabled] od-a@mkt" "$out"
assert_has "CRLF preserves disabled state" "[disabled] od-b@mkt" "$out"
: > "$CALL_LOG"
out=$(run lean --template "$TMPL_LF"); rc=$?
assert_rc "CRLF lean exits 0" 0 "$rc"
assert_lines_eq "CRLF lean disables installed enabled plugin" "$CALL_LOG" "plugin disable od-a@mkt --scope user"
: > "$CALL_LOG"
out=$(run full --template "$TMPL_LF"); rc=$?
assert_rc "CRLF full exits 0" 0 "$rc"
assert_lines_eq "CRLF full enables installed disabled plugin" "$CALL_LOG" "plugin enable od-b@mkt --scope user"
STUB_CRLF=0

# ── Empty tiers must not abort text listing before the remaining sections ──
TMPL_EMPTY="$TMP/settings-template-empty.json"
for empty_tier in always onDemand both; do
  case "$empty_tier" in
    always) printf '%s\n' '{"enabledPlugins":{},"onDemandPlugins":{"od-a@mkt":{"neededBy":"a"}}}' > "$TMPL_EMPTY" ;;
    onDemand) printf '%s\n' '{"enabledPlugins":{"qmd@himmel":true},"onDemandPlugins":{}}' > "$TMPL_EMPTY" ;;
    both) printf '%s\n' '{"enabledPlugins":{},"onDemandPlugins":{}}' > "$TMPL_EMPTY" ;;
  esac
  out=$(run list --template "$TMPL_EMPTY"); rc=$?
  assert_rc "list with empty $empty_tier tier exits 0" 0 "$rc"
  assert_has "list with empty $empty_tier tier reaches final recipe" "back to lean:" "$out"
done

# ── 11: usage errors exit 2 ──────────────────────────────────────────────────
out=$(run --bogus-flag --template "$TMPL"); rc=$?
assert_rc "unknown flag exits 2" 2 "$rc"

out=$(run list lean --template "$TMPL"); rc=$?
assert_rc "two verbs exits 2" 2 "$rc"

out=$(run lean --json --template "$TMPL"); rc=$?
assert_rc "--json with a non-list verb exits 2" 2 "$rc"

out=$(run enable --template "$TMPL"); rc=$?
assert_rc "enable with no spec exits 2" 2 "$rc"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASS"; exit 0
else
  echo "$FAILED FAILURE(S)"; exit 1
fi
