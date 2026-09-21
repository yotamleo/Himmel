#!/usr/bin/env bash
# Platform guard (gitbash-only): bash + node + jq.
# test-luna-config-migration.sh -- HIMMEL-3349: `himmelctl install` must not fail
# on a ~/.himmel/config.json that carries an unknown key, and must migrate a
# pre-schema config (a required v1 field missing) instead of refusing it.
#
# Every run is a scratch HOME with the config, ledger, cache, bin dir and repo
# root all redirected into it -- the operator's real ~/.himmel is never touched.
#
# RED at the base (093371c8): validateConfig() treats any extra key as an error
# and every missing field as an error, so applyLunaSectionsStep sets rc=1.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_hermetic-home.sh
. "$here/_hermetic-home.sh"
repo="$(cd "$here/../../.." && pwd)"
wizard="$repo/scripts/himmelctl/bin.js"
lunacfg="$(winpath "$repo/scripts/himmelctl/lib/luna-config.js")"
fails=0
passes=0
check() { # name got want
    if [ "$2" = "$3" ]; then passes=$((passes + 1)); echo "ok - $1"
    else fails=$((fails + 1)); echo "FAIL - $1: [$2] != [$3]"; fi
}

node_bin="$(command -v node || true)"
if [ -z "$node_bin" ]; then echo "SKIP - node not installed"; exit 0; fi
command -v jq >/dev/null 2>&1 || { echo "SKIP - jq not installed"; exit 0; }

work_raw=$(mktemp -d "${TMPDIR:-/tmp}/luna-cfg-mig.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap '[ -n "${work_raw:-}" ] && [ -d "$work_raw" ] && rm -rf "$work_raw"' EXIT
# shellcheck source=../../lib/canon-path.sh
. "$repo/scripts/lib/canon-path.sh"
work=$(canon_path_native "$work_raw") || { echo "FAIL: canon $work_raw" >&2; exit 1; }

# sha256sum when present, else macOS's shasum -a 256; with neither, fail loudly
# rather than compare two empty hashes (a vacuous byte-preservation check).
if command -v sha256sum >/dev/null 2>&1; then
  _sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  _sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "FAIL: sha256sum or shasum required" >&2
  exit 1
fi
sha() { if [ -e "$1" ]; then _sha256 "$1"; else echo absent; fi; }

# a throwaway HIMMELCTL_REPO_ROOT whose adopt.sh just exits 0
clone="$work/clone"
mkdir -p "$clone/scripts/lanes" "$clone/scripts/machine-setup" "$clone/scripts/lib"
printf '#!/usr/bin/env bash\nexit 0\n' > "$clone/scripts/adopt.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$clone/scripts/setup.sh"
chmod +x "$clone/scripts/adopt.sh" "$clone/scripts/setup.sh"
printf '{ "plugins": [] }\n' > "$clone/scripts/machine-setup/full-plugin-enable.json"
cp "$repo/scripts/lanes/lanes.json" "$clone/scripts/lanes/lanes.json"
cp "$repo/scripts/lib/ensure-workspace-trust.sh" "$clone/scripts/lib/"

# new_home <name> -- a scratch HOME; prints its path. The config lives at the
# real default location <home>/.himmel/config.json.
new_home() { local h="$work/$1"; mkdir -p "$h/.himmel"; echo "$h"; }

# run_install <home> [args...] -- bin.js install under a scratch HOME, ledger pinned
run_install() {
    local home="$1"; shift
    ( cd "$clone" && env -u HIMMEL_PROVENANCE_IID -u DRY_RUN \
        HOME="$home" USERPROFILE="$(winpath "$home")" \
        HIMMEL_PROVENANCE_DIR="$(winpath "$home/prov")" \
        HIMMELCTL_CACHE_DIR="$(winpath "$home/himmelctl-cache")" \
        HIMMEL_LUNA_CONFIG_PATH="$(winpath "$home/.himmel/config.json")" \
        HIMMELCTL_BIN_DIR="$(winpath "$home/bin")" \
        HIMMELCTL_INTERACTIVE=0 HIMMELCTL_REPO_ROOT="$(winpath "$clone")" \
        "$node_bin" "$wizard" install --scope user "$@" </dev/null 2>&1 )
}

# validates <file> -- zero validateConfig errors on the parsed file
validates() {
    "$node_bin" -e "
const l=require(process.argv[1]);
const e=l.validateConfig(JSON.parse(require('fs').readFileSync(process.argv[2],'utf8')));
console.log(e.length===0?'valid':'invalid: '+e.join('; '));" "$lunacfg" "$(winpath "$1")"
}

nbak() { find "$1/.himmel" -maxdepth 1 -name 'config.json.bak-*' 2>/dev/null | wc -l | tr -d ' '; }  # gnu-ok: BSD find supports -maxdepth
nlines() { printf '%s\n' "$1" | grep -c "$2"; }

# ── fixtures (user values are deliberately non-default) ─────────────────────
FULL='{"version":1,"luna":{"vaultPath":"/u/vault","cadence":{"enabled":true,"schedules":{"fetchHealth":{"time":"05:15"},"harvest":{"time":"06:00"},"synthesize":{"time":"07:00"},"health":{"time":"08:00","day":"MON"}},"models":{"harvest":"opus","synthesize":"opus","health":"sonnet"}},"phi":{"declared":true}},"bridge":{"enabled":true,"envPath":"/u/env","whisper":{"cli":"/u/whisper","model":"ggml-base.bin"}}}'
mk() { printf '%s\n' "$2" > "$1/.himmel/config.json"; }

# ── (e) a valid current file: untouched, no backup, no migration, no warning ─
hE=$(new_home e); mk "$hE" "$FULL"
before=$(sha "$hE/.himmel/config.json")
outE=$(run_install "$hE"); rcE=$?
check "e valid file: rc" "$rcE" "0"
check "e valid file: byte-identical" "$(sha "$hE/.himmel/config.json")" "$before"
check "e valid file: no backup" "$(nbak "$hE")" "0"
check "e valid file: no migrated line" "$(nlines "$outE" 'migrated ~/.himmel/config.json')" "0"
check "e valid file: no unknown-key warning" "$(nlines "$outE" 'WARN.*does not manage')" "0"
[ "$rcE" -eq 0 ] || echo "note: $outE"

# ── (a) unknown keys: install rc 0, keys preserved, ONE warning ────────────
UNK=$(printf '%s' "$FULL" | jq -c '. + {userKey:"keep-me"} | .luna.note = {"a":[1,2]} | .bridge.whisper.extra = 7')
hA=$(new_home a); mk "$hA" "$UNK"
before=$(sha "$hA/.himmel/config.json")
outA=$(run_install "$hA"); rcA=$?
check "a unknown keys: rc" "$rcA" "0"
check "a unknown keys: file byte-identical (nothing else changed)" "$(sha "$hA/.himmel/config.json")" "$before"
check "a unknown keys: exactly one warning" "$(nlines "$outA" 'WARN.*does not manage')" "1"
check "a unknown keys: the warning names every unknown path" \
    "$(printf '%s\n' "$outA" | grep 'does not manage' | grep 'userKey' | grep 'luna\.note' | grep -c 'bridge\.whisper\.extra')" "1"
check "a unknown keys: no backup, nothing migrated" "$(nbak "$hA")" "0"
[ "$rcA" -eq 0 ] || echo "note: $outA"

# unknown keys + a missing field: the rewrite keeps every unknown value
UNK2=$(printf '%s' "$UNK" | jq -c 'del(.bridge.whisper.model)')
hA2=$(new_home a2); mk "$hA2" "$UNK2"
outA2=$(run_install "$hA2"); rcA2=$?
check "a2 unknown+missing: rc" "$rcA2" "0"
check "a2 unknown+missing: userKey survives" "$(jq -r '.userKey' "$hA2/.himmel/config.json")" "keep-me"
check "a2 unknown+missing: nested unknowns survive" "$(jq -c '[.luna.note, .bridge.whisper.extra]' "$hA2/.himmel/config.json")" '[{"a":[1,2]},7]'
check "a2 unknown+missing: valid afterwards" "$(validates "$hA2/.himmel/config.json")" "valid"
check "a2 unknown+missing: still one warning" "$(nlines "$outA2" 'WARN.*does not manage')" "1"

# ── (b) each pre-schema shape -> valid v1, user values kept, a line per field ─
# migrate_case <name> <fixture-json> <expected-lines> <jq-user-values> <expected-values>
migrate_case() {
    local name="$1" fixture="$2" want="$3" jqx="$4" wantv="$5"
    local h; h=$(new_home "b-$name"); mk "$h" "$fixture"
    local orig="$work/b-$name.orig"; cp "$h/.himmel/config.json" "$orig"
    local out rc
    out=$(run_install "$h"); rc=$?
    check "b/$name: rc" "$rc" "0"
    [ "$rc" -eq 0 ] || echo "note: $out"
    check "b/$name: valid v1 afterwards" "$(validates "$h/.himmel/config.json")" "valid"
    check "b/$name: every user value kept" "$(jq -c "$jqx" "$h/.himmel/config.json")" "$wantv"
    check "b/$name: one line per filled field" "$(nlines "$out" 'migrated ~/.himmel/config.json')" "$want"
    check "b/$name: exactly one backup" "$(nbak "$h")" "1"
    local bak; bak=$(find "$h/.himmel" -maxdepth 1 -name 'config.json.bak-*' | head -1)  # gnu-ok: BSD find supports -maxdepth
    check "b/$name: the backup is byte-exact" "$(sha "$bak")" "$(sha "$orig")"
    check "b/$name: the ledger records the config rewrite with a backup" \
        "$(jq -rs '[.[] | select(.kind=="json-key" and .op=="replace" and (.path|endswith("config.json")))] | length >= 1' "$h/prov/provenance.jsonl" 2>/dev/null)" "true"
    check "b/$name: the ledger backup of the pre-image exists" \
        "$(find "$h/prov/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ' | awk '{print ($1>=1)?"yes":"no"}')" "yes"
    # (c) second run: a no-op, no second backup
    local sha1 ledn; sha1=$(sha "$h/.himmel/config.json"); ledn=$(jq -rs 'length' "$h/prov/provenance.jsonl" 2>/dev/null)
    local out2 rc2
    out2=$(run_install "$h"); rc2=$?
    check "c/$name: second run rc" "$rc2" "0"
    check "c/$name: second run leaves the file byte-identical" "$(sha "$h/.himmel/config.json")" "$sha1"
    check "c/$name: second run takes no second backup" "$(nbak "$h")" "1"
    check "c/$name: second run migrates nothing" "$(nlines "$out2" 'migrated ~/.himmel/config.json')" "0"
    check "c/$name: second run records no config row" \
        "$(jq -rs '[.[] | select(.kind=="json-key" and (.path|endswith("config.json")))] | length' "$h/prov/provenance.jsonl" 2>/dev/null)" \
        "$(jq -rs --argjson n "$ledn" '[.[0:$n][] | select(.kind=="json-key" and (.path|endswith("config.json")))] | length' "$h/prov/provenance.jsonl" 2>/dev/null)"
}

USERV='[.luna.vaultPath,.luna.cadence.enabled,.luna.cadence.models.harvest,.luna.phi.declared,.bridge.enabled,.bridge.envPath,.bridge.whisper.cli]'
USERV_WANT='["/u/vault",true,"opus",true,true,"/u/env",null]'

# missing leaf fields at three levels, incl. `version`
migrate_case leaves "$(printf '%s' "$FULL" | jq -c 'del(.version, .luna.cadence.models.synthesize, .luna.cadence.models.health, .bridge.whisper.model) | .bridge.whisper.cli = null')" 4 "$USERV" "$USERV_WANT"
# a whole section missing
migrate_case section "$(printf '%s' "$FULL" | jq -c 'del(.bridge.whisper)')" 2 '[.luna.vaultPath,.bridge.envPath,.bridge.whisper.cli,.bridge.whisper.model]' '["/u/vault","/u/env",null,"ggml-small.bin"]'
# only luna.vaultPath: every other field is filled from the defaults
migrate_case sparse '{"version":1,"luna":{"vaultPath":"/u/vault"}}' 14 '[.luna.vaultPath,.luna.cadence.enabled,.bridge.enabled]' '["/u/vault",false,false]'
# a schedule with `day` but no `time`: only `time` is filled, `day` stays
migrate_case sched "$(printf '%s' "$FULL" | jq -c 'del(.luna.cadence.schedules.health.time) | .bridge.whisper.cli = null')" 1 '[.luna.cadence.schedules.health.day, .luna.cadence.schedules.health.time, .luna.cadence.schedules.harvest.time]' '["MON","04:00","06:00"]'

# ── (d) invalid JSON: refused, the file untouched, a hand-fix command ──────
hD=$(new_home d); printf '{ "luna": not json' > "$hD/.himmel/config.json"
before=$(sha "$hD/.himmel/config.json")
outD=$(run_install "$hD"); rcD=$?
check "d invalid JSON: install still refuses (rc non-zero)" "$([ "$rcD" -ne 0 ] && echo yes || echo no)" "yes"
check "d invalid JSON: file untouched" "$(sha "$hD/.himmel/config.json")" "$before"
check "d invalid JSON: no backup or temp file written" "$(find "$hD/.himmel" -maxdepth 1 -name 'config.json.*' | wc -l | tr -d ' ')" "0"  # gnu-ok: BSD find supports -maxdepth
check "d invalid JSON: names the file" "$([ "$(printf '%s\n' "$outD" | grep -c "$hD/.himmel/config.json")" -ge 1 ] && echo yes || echo no)" "yes"
check "d invalid JSON: a hand-fix command with the backup path" \
    "$(printf '%s\n' "$outD" | grep -c "hand-fix: cp .*config.json.hand-fix.bak")" "1"

# ── (f) a wrong-typed user value is still refused and never rewritten ───────
hF=$(new_home f); mk "$hF" "$(printf '%s' "$FULL" | jq -c '.luna.cadence.enabled = "yes"')"
before=$(sha "$hF/.himmel/config.json")
outF=$(run_install "$hF"); rcF=$?
check "f wrong type: rc non-zero" "$([ "$rcF" -ne 0 ] && echo yes || echo no)" "yes"
check "f wrong type: the refusal names the file" "$(printf '%s\n' "$outF" | grep -c 'could not read ~/.himmel/config.json')" "1"
check "f wrong type: file untouched" "$(sha "$hF/.himmel/config.json")" "$before"
check "f wrong type: no backup" "$(nbak "$hF")" "0"

# ── unit level: unknownKeys / inspect on a config that is not on disk ───────
outU=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/absent/config.json")" "$node_bin" -e "
const l=require(process.argv[1]);
const i=l.inspect();
console.log(JSON.stringify({existed:i.existed,filled:i.filled.length,unknown:i.unknown.length}));" "$lunacfg" 2>&1)
check "u absent file: inspect() reports nothing to migrate" "$outU" '{"existed":false,"filled":0,"unknown":0}'

echo "passes=$passes fails=$fails"
[ "$fails" -eq 0 ]
