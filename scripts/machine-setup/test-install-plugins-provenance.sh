#!/usr/bin/env bash
# test-install-plugins-provenance.sh — hermetic tests for the HIMMEL-3332 S3
# install-provenance records written by scripts/machine-setup/install-plugins.sh:
#
#   1. Every `claude plugin install` / `marketplace add` writes one `register`
#      row, and `preexisted` is read from enabledPlugins /
#      extraKnownMarketplaces plus the plugin/marketplace dirs BEFORE the CLI
#      call — so the operator's own context7 + claude-plugins-official come
#      back `preexisted:true` and himmel's own come back `preexisted:false`.
#   2. CLAUDE_CONFIG_DIR is honoured (both the pre-state read and the recorded
#      path); project / local scope read + record the project settings file, and
#      a user-scope plugin dir does not make a project-scope plugin "pre-existing".
#   3. A re-run reads the pre-state again (the first run's own writes are now
#      `preexisted:true`), a failed marketplace add closes the session `failed`,
#      a dry run writes no ledger, a child of a session appends into that
#      session, and a ledger that cannot be written never fails the install.
#
# Every case runs under a scratch HOME (the ledger defaults to $HOME/.himmel)
# with a stub `claude` on PATH; HIMMEL_UNINSTALL_REAL_HOME is never set.
#
# install-plugins.ps1 has no provenance calls: the PowerShell dialect of the
# helpers is tracked in HIMMEL-3346.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Uses git, jq and mktemp; NOT ported to native PowerShell (a test harness
# needs no .ps1 twin — a documented platform guard suffices).
set -uo pipefail

unset HIMMEL_RECONCILE_PLUGINS HIMMEL_PROVENANCE_IID HIMMEL_PROVENANCE_DIR CLAUDE_CONFIG_DIR DRY_RUN

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/install-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-install-plugins-provenance.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# The operator's REAL ledger must come out of this suite byte-for-byte as it went
# in: every case runs under a scratch HOME, and a leak here (a case that forgot
# the scratch HOME) would append test rows to ~/.himmel/provenance.jsonl.
REAL_LEDGER="$HOME/.himmel/provenance.jsonl"
real_ledger_sha() { if [ -f "$REAL_LEDGER" ]; then sha256sum "$REAL_LEDGER" | cut -d' ' -f1; else echo absent; fi; }
REAL_LEDGER_BEFORE=$(real_ledger_sha)

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

assert_eq() {
    local label="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$label"; else fail "$label — want [$want], got [$got]"; fi
}

# Stub `claude`: marketplace add succeeds (fails for STUB_MKT_FAIL) and creates
# the marketplace dir; `plugin install <spec> --scope S` writes
# enabledPlugins[spec]=true into the scope's settings file and the plugin cache
# dir, like the real CLI; `plugin list` prints every spec on STUB_PRESENT.
export STUB_PRESENT="context7@claude-plugins-official himmel-ops@himmel"
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
scope=""; prev=""
for arg in "$@"; do
  if [ "$prev" = "--scope" ]; then scope="$arg"; fi
  prev="$arg"
done
case "$scope" in
  project) sf="$PWD/.claude/settings.json" ;;
  local)   sf="$PWD/.claude/settings.local.json" ;;
  *)       sf="$cfg/settings.json" ;;
esac
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  for s in ${STUB_PRESENT:-}; do printf '  %s\n' "$s"; done
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "add" ]; then
  case " ${STUB_MKT_FAIL:-} " in *" ${4:-} "*) echo "stub: marketplace add failed" >&2; exit 1 ;; esac
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "install" ]; then
  spec="${3:-}"
  mkdir -p "$(dirname "$sf")" "$cfg/plugins/cache/${spec##*@}/${spec%@*}"
  if [ -f "$sf" ]; then
    tmp=$(mktemp "$sf.stub.XXXXXX"); jq --arg k "$spec" '.enabledPlugins[$k] = true' "$sf" > "$tmp" && mv "$tmp" "$sf"
  else
    jq -n --arg k "$spec" '{enabledPlugins: {($k): true}}' > "$sf"
  fi
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Fixture template: one ALWAYS plugin from the operator's marketplace, one
# himmel plugin from himmel's own. Sources are github/directory shaped like the
# real template; nothing is fetched (the stub never clones).
TEMPLATE="$TMP/settings-template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "enabledPlugins": {
    "context7@claude-plugins-official": true,
    "himmel-ops@himmel": true
  },
  "extraKnownMarketplaces": {
    "claude-plugins-official": { "source": { "source": "github", "repo": "anthropics/claude-plugins-official" } },
    "himmel": { "autoUpdate": true, "source": { "source": "directory", "path": "<himmel-path>" } }
  }
}
JSON

# fresh_env <name> — a scratch HOME + cwd for one case; sets HOME, CASE, LEDGER.
fresh_env() {
    CASE="$TMP/$1"
    rm -rf "$CASE"; mkdir -p "$CASE/home" "$CASE/cwd"
    export HOME="$CASE/home"
    unset CLAUDE_CONFIG_DIR HIMMEL_PROVENANCE_IID
    LEDGER="$HOME/.himmel/provenance.jsonl"
    cd "$CASE/cwd" || exit 1
}

# seed_operator_state <cfg-dir> — the operator's own context7 + marketplace.
seed_operator_state() {
    mkdir -p "$1/plugins/cache/claude-plugins-official/context7" "$1/plugins/marketplaces/claude-plugins-official"
    cat > "$1/settings.json" <<'JSON'
{ "enabledPlugins": { "context7@claude-plugins-official": true },
  "extraKnownMarketplaces": { "claude-plugins-official": { "source": { "source": "github", "repo": "anthropics/claude-plugins-official" } } } }
JSON
}

run_install() {
    PATH="$STUB_DIR:$PATH" bash "$script" --template "$TEMPLATE" --himmel-path "$repo_root" "$@" 2>&1
}

# row <kind> <unit> — the (single) ledger row of that kind+unit, as compact JSON.
row() {
    jq -c --arg k "$1" --arg u "$2" 'select(.op == "register" and .kind == $k and .unit == $u)' "$LEDGER" 2>/dev/null
}
field() { jq -r "$2" <<< "$1" 2>/dev/null; }
count_rows() { jq -c --arg k "$1" --arg u "$2" 'select(.op == "register" and .kind == $k and .unit == $u)' "$LEDGER" 2>/dev/null | wc -l | tr -d ' '; }

# ── Case 1: user scope, operator already has context7 + its marketplace ──────
fresh_env user
seed_operator_state "$HOME/.claude"
out=$(run_install --scope user); rc=$?
assert_eq "1 install rc" 0 "$rc"
[ -f "$LEDGER" ] || { fail "1 ledger written"; echo "$out" >&2; }
r=$(row plugin context7@claude-plugins-official)
assert_eq "1 context7 rows" 1 "$(count_rows plugin context7@claude-plugins-official)"
assert_eq "1 context7 preexisted" true "$(field "$r" .preexisted)"
assert_eq "1 context7 scope" user "$(field "$r" .scope)"
assert_eq "1 context7 cli_scope" user "$(field "$r" .cli_scope)"
assert_eq "1 context7 marketplace" claude-plugins-official "$(field "$r" .marketplace)"
assert_eq "1 context7 manifest_row" plugins "$(field "$r" .manifest_row)"
assert_eq "1 context7 path" "$HOME/.claude/settings.json" "$(field "$r" .path)"
r=$(row plugin himmel-ops@himmel)
assert_eq "1 himmel-ops rows" 1 "$(count_rows plugin himmel-ops@himmel)"
assert_eq "1 himmel-ops preexisted" false "$(field "$r" .preexisted)"
r=$(row marketplace claude-plugins-official)
assert_eq "1 operator marketplace rows" 1 "$(count_rows marketplace claude-plugins-official)"
assert_eq "1 operator marketplace preexisted" true "$(field "$r" .preexisted)"
assert_eq "1 operator marketplace manifest_row" marketplaces "$(field "$r" .manifest_row)"
r=$(row marketplace himmel)
assert_eq "1 himmel marketplace preexisted" false "$(field "$r" .preexisted)"
assert_eq "1 one session, begun and ended ok" "install-begin,install-end:ok" \
    "$(jq -r 'select(.op == "install-begin" or .op == "install-end") | .op + (if .status then ":" + .status else "" end)' "$LEDGER" | paste -sd, -)"
assert_eq "1 every row shares one iid" 1 "$(jq -r .iid "$LEDGER" | sort -u | wc -l | tr -d ' ')"

# ── Case 2: re-run — the first run's own writes now read as pre-existing ────
out=$(run_install --scope user); rc=$?
assert_eq "2 re-run rc" 0 "$rc"
assert_eq "2 re-run himmel-ops rows" 2 "$(count_rows plugin himmel-ops@himmel)"
assert_eq "2 re-run himmel-ops preexisted (last row)" true "$(field "$(row plugin himmel-ops@himmel | tail -n 1)" .preexisted)"

# ── Case 3: CLAUDE_CONFIG_DIR is honoured for the read AND the recorded path ─
fresh_env cfgdir
export CLAUDE_CONFIG_DIR="$CASE/cfg"
seed_operator_state "$CLAUDE_CONFIG_DIR"
out=$(run_install --scope user); rc=$?
assert_eq "3 install rc" 0 "$rc"
r=$(row plugin context7@claude-plugins-official)
assert_eq "3 context7 preexisted via CLAUDE_CONFIG_DIR" true "$(field "$r" .preexisted)"
assert_eq "3 context7 path under CLAUDE_CONFIG_DIR" "$CASE/cfg/settings.json" "$(field "$r" .path)"
assert_eq "3 himmel-ops preexisted" false "$(field "$(row plugin himmel-ops@himmel)" .preexisted)"
assert_eq "3 nothing written under HOME/.claude" "" "$(ls "$HOME/.claude" 2>/dev/null)"
unset CLAUDE_CONFIG_DIR

# ── Case 4: project scope reads + records the project settings file ─────────
fresh_env project
seed_operator_state "$HOME/.claude"   # a USER-scope context7 must not count for the project
out=$(run_install --scope project); rc=$?
assert_eq "4 install rc" 0 "$rc"
r=$(row plugin context7@claude-plugins-official)
assert_eq "4 project context7 preexisted (user-scope copy does not count)" false "$(field "$r" .preexisted)"
assert_eq "4 project context7 scope" project "$(field "$r" .scope)"
assert_eq "4 project context7 cli_scope" project "$(field "$r" .cli_scope)"
assert_eq "4 project context7 path" "$CASE/cwd/.claude/settings.json" "$(field "$r" .path)"
assert_eq "4 marketplace known at user level still reads preexisted" true \
    "$(field "$(row marketplace claude-plugins-official)" .preexisted)"

# ── Case 5: project scope, operator already declared context7 there ─────────
fresh_env project-preseeded
mkdir -p .claude
echo '{ "enabledPlugins": { "context7@claude-plugins-official": true } }' > .claude/settings.json
out=$(run_install --scope project); rc=$?
assert_eq "5 install rc" 0 "$rc"
assert_eq "5 project context7 preexisted" true "$(field "$(row plugin context7@claude-plugins-official)" .preexisted)"

# ── Case 6: local scope records scope=project, cli_scope=local ──────────────
fresh_env local
out=$(run_install --scope local); rc=$?
assert_eq "6 install rc" 0 "$rc"
r=$(row plugin himmel-ops@himmel)
assert_eq "6 local scope recorded as project" project "$(field "$r" .scope)"
assert_eq "6 local cli_scope" local "$(field "$r" .cli_scope)"
assert_eq "6 local path" "$CASE/cwd/.claude/settings.local.json" "$(field "$r" .path)"

# ── Case 7: an unparseable settings file reads as pre-existing (unknown = keep)
fresh_env corrupt
mkdir -p "$HOME/.claude"
echo '{ not json' > "$HOME/.claude/settings.json"
out=$(run_install --scope user); rc=$?
assert_eq "7 corrupt settings: context7 reads preexisted (unknown = keep)" true \
    "$(field "$(row plugin context7@claude-plugins-official)" .preexisted)"

# ── Case 8: a failed marketplace add closes the session failed, no rows ─────
fresh_env mktfail
out=$(STUB_MKT_FAIL="anthropics/claude-plugins-official" run_install --scope user); rc=$?
assert_eq "8 install rc" 1 "$rc"
assert_eq "8 no plugin rows" 0 "$(count_rows plugin himmel-ops@himmel)"
assert_eq "8 no row for the failed marketplace" 0 "$(count_rows marketplace claude-plugins-official)"
assert_eq "8 session ended failed" failed "$(jq -r 'select(.op == "install-end") | .status' "$LEDGER" 2>/dev/null)"

# ── Case 9: dry run writes no ledger and names what it would record ─────────
fresh_env dry
out=$(run_install --dry-run --scope user); rc=$?
assert_eq "9 dry-run rc" 0 "$rc"
if [ ! -e "$HOME/.himmel" ]; then pass "9 dry-run wrote no ledger dir"; else fail "9 dry-run wrote $HOME/.himmel"; fi
case "$out" in *"DRY: record register plugin "*) pass "9 dry-run names the plugin record" ;; *) fail "9 dry-run missing 'DRY: record register plugin'" ;; esac

# ── Case 10: a child of a session appends into it and opens none of its own ─
fresh_env child
out=$(HIMMEL_PROVENANCE_IID=20260921T000000Z-abc123 run_install --scope user); rc=$?
assert_eq "10 install rc" 0 "$rc"
assert_eq "10 rows carry the parent's iid" 20260921T000000Z-abc123 "$(jq -r .iid "$LEDGER" | sort -u)"
assert_eq "10 no begin/end rows from the child" 0 "$(jq -c 'select(.op == "install-begin" or .op == "install-end")' "$LEDGER" | wc -l | tr -d ' ')"

# ── Case 11: an unwritable ledger warns but never fails the install ─────────
fresh_env noledger
mkdir -p "$HOME/.himmel"; : > "$HOME/.himmel/provenance.jsonl"; chmod 0400 "$HOME/.himmel/provenance.jsonl"
out=$(run_install --scope user); rc=$?
if [ "$(id -u)" = 0 ]; then
    echo "SKIP 11 (root ignores file modes)"
else
    assert_eq "11 unwritable ledger: install still rc 0" 0 "$rc"
    case "$out" in *"provenance"*) pass "11 unwritable ledger is reported" ;; *) fail "11 no provenance warning in output" ;; esac
fi
chmod 0600 "$HOME/.himmel/provenance.jsonl" 2>/dev/null

# ── Case 12: --settings redirects only the autoUpdate patch, not what the CLI writes ─
# The stub CLI (like the real one) writes the scope's default settings, so the
# pre-existence read and the recorded path must follow the scope's file, not the override.
fresh_env override
mkdir -p "$HOME/.claude"
echo '{ "enabledPlugins": { "context7@claude-plugins-official": true } }' > "$HOME/.claude/settings.json"
out=$(run_install --scope user --settings "$CASE/elsewhere.json"); rc=$?
assert_eq "12 install rc" 0 "$rc"
r=$(row plugin context7@claude-plugins-official)
assert_eq "12 --settings override: context7 still reads preexisted" true "$(field "$r" .preexisted)"
assert_eq "12 --settings override: path is the scope's settings file" "$HOME/.claude/settings.json" "$(field "$r" .path)"

# ── Case 13: an unparseable CLI registry reads as pre-existing (unknown = keep) ─
fresh_env badregistry
mkdir -p "$HOME/.claude/plugins"
echo '{ not json' > "$HOME/.claude/plugins/installed_plugins.json"
echo '{ not json' > "$HOME/.claude/plugins/known_marketplaces.json"
out=$(run_install --scope user); rc=$?
assert_eq "13 install rc" 0 "$rc"
assert_eq "13 corrupt installed_plugins.json: plugin reads preexisted" true \
    "$(field "$(row plugin context7@claude-plugins-official)" .preexisted)"
assert_eq "13 corrupt known_marketplaces.json: marketplace reads preexisted" true \
    "$(field "$(row marketplace claude-plugins-official)" .preexisted)"

# ── Case 14: a parseable registry without the entry reads as NOT pre-existing (control) ─
fresh_env goodregistry
mkdir -p "$HOME/.claude/plugins"
echo '{ "plugins": {} }' > "$HOME/.claude/plugins/installed_plugins.json"
echo '{}' > "$HOME/.claude/plugins/known_marketplaces.json"
out=$(run_install --scope user); rc=$?
assert_eq "14 install rc" 0 "$rc"
assert_eq "14 valid registry without the plugin: preexisted false" false \
    "$(field "$(row plugin context7@claude-plugins-official)" .preexisted)"
assert_eq "14 valid registry without the marketplace: preexisted false" false \
    "$(field "$(row marketplace claude-plugins-official)" .preexisted)"

if [ "$(real_ledger_sha)" = "$REAL_LEDGER_BEFORE" ]; then
    pass "15 the real ~/.himmel ledger is untouched by this suite"
else
    fail "15 the real ~/.himmel ledger changed during this suite (a case leaked out of its scratch HOME)"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"; exit 0
else
    echo "$FAILED FAILURE(S)"; exit 1
fi
