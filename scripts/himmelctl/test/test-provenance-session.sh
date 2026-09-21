#!/usr/bin/env bash
# Platform guard (gitbash-only): bash + node + jq.
# test-provenance-session.sh -- HIMMEL-3332 S5: `himmelctl install` opens a
# provenance session (install-begin ... install-end) and its writers record
# their own units into it.
#
# RED at the S5 base: bin.js never calls provBegin/provEnd/provRecord, so no
# ledger exists. Every install-path run here uses a scratch HOME with the
# ledger, cache, config, bin dir and repo root all redirected into it -- the
# operator's real ~/.himmel is never touched.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_hermetic-home.sh
. "$here/_hermetic-home.sh"
repo="$(cd "$here/../../.." && pwd)"
wizard="$repo/scripts/himmelctl/bin.js"
fails=0
passes=0
check() { # name got want
    if [ "$2" = "$3" ]; then passes=$((passes + 1)); echo "ok - $1"
    else fails=$((fails + 1)); echo "FAIL - $1: [$2] != [$3]"; fi
}

node_bin="$(command -v node || true)"
if [ -z "$node_bin" ]; then echo "SKIP - node not installed"; exit 0; fi
command -v jq >/dev/null 2>&1 || { echo "SKIP - jq not installed"; exit 0; }

work_raw=$(mktemp -d "${TMPDIR:-/tmp}/prov-session.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap '[ -n "${work_raw:-}" ] && [ -d "$work_raw" ] && rm -rf "$work_raw"' EXIT
# shellcheck source=../../lib/canon-path.sh
. "$repo/scripts/lib/canon-path.sh"
work=$(canon_path_native "$work_raw") || { echo "FAIL: canon $work_raw" >&2; exit 1; }

# make_clone <dir> <adopt-exit> -- a throwaway HIMMELCTL_REPO_ROOT whose adopt.sh
# just exits with <adopt-exit>
make_clone() {
    local d="$1" arc="$2"
    mkdir -p "$d/scripts/lanes" "$d/scripts/machine-setup"
    printf '#!/usr/bin/env bash\nexit %s\n' "$arc" > "$d/scripts/adopt.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/setup.sh"
    chmod +x "$d/scripts/adopt.sh" "$d/scripts/setup.sh"
    printf '{ "plugins": [] }\n' > "$d/scripts/machine-setup/full-plugin-enable.json"
    cp "$repo/scripts/lanes/lanes.json" "$d/scripts/lanes/lanes.json"
}

# run_install <clone> <home> [args...] -- bin.js install under a scratch HOME
run_install() {
    local clone="$1" home="$2"; shift 2
    ( cd "$clone" && env -u HIMMEL_PROVENANCE_IID -u DRY_RUN -u HIMMEL_PROVENANCE_DIR \
        HOME="$home" USERPROFILE="$(winpath "$home")" \
        HIMMELCTL_CACHE_DIR="$(winpath "$home/himmelctl-cache")" \
        HIMMEL_LUNA_CONFIG_PATH="$(winpath "$home/himmelctl-cache/luna-config.json")" \
        HIMMELCTL_BIN_DIR="$(winpath "$home/bin")" \
        HIMMELCTL_INTERACTIVE=0 HIMMELCTL_REPO_ROOT="$(winpath "$clone")" \
        "$node_bin" "$wizard" install "$@" </dev/null 2>&1 )
}

# ── A: a clean install writes begin ... end ok ─────────────────────────────
cloneA="$work/a-clone"; make_clone "$cloneA" 0
# the real trust helper, so the workspace-trust step runs (make_clone omits it)
mkdir -p "$cloneA/scripts/lib"; cp "$repo/scripts/lib/ensure-workspace-trust.sh" "$cloneA/scripts/lib/"
homeA="$work/a-home"; mkdir -p "$homeA"
outA=$(run_install "$cloneA" "$homeA" --scope user); rcA=$?
check "A install rc" "$rcA" "0"
ledA="$homeA/.himmel/provenance.jsonl"
[ -f "$ledA" ] || echo "note: no ledger at $ledA; install output: $outA"
check "A ledger exists" "$([ -f "$ledA" ] && echo yes || echo no)" "yes"
check "A first row is install-begin" "$(jq -rs '.[0].op // "none"' "$ledA" 2>/dev/null)" "install-begin"
homeA_real="$(cd "$homeA" && pwd -P)"
check "A begin.home is the scratch HOME" "$(jq -rs '.[0].home // "none"' "$ledA" 2>/dev/null)" "$(winpath "$homeA_real")"
check "A begin.writer" "$(jq -rs '.[0].writer // "none"' "$ledA" 2>/dev/null)" "himmelctl"
check "A last row is install-end ok" "$(jq -rs '.[-1] | (.op // "none") + " " + (.status // "none")' "$ledA" 2>/dev/null)" "install-end ok"
check "A exactly one session" "$(jq -rs '[.[] | select(.op=="install-begin")] | length' "$ledA" 2>/dev/null)" "1"
check "A one iid throughout" "$(jq -rs '[.[].iid] | unique | length' "$ledA" 2>/dev/null)" "1"
check "A cache file row (class code, manifest_row himmelctl-cache)" \
    "$(jq -rs '[.[] | select(.kind=="file" and .manifest_row=="himmelctl-cache" and .class=="code")] | length' "$ledA" 2>/dev/null)" "1"
check "A launcher shim row (class code)" \
    "$(jq -rs '[.[] | select(.kind=="shim" and .op=="create" and .class=="code")] | length >= 1' "$ledA" 2>/dev/null)" "true"
check "A workspace-trust json-key row (keep, preexisted=false)" \
    "$(jq -rs '[.[] | select(.kind=="json-key" and .manifest_row=="workspace-trust" and .class=="keep" and .op=="create" and .preexisted==false)] | length' "$ledA" 2>/dev/null)" "1"
check "A lanes.local.json row is scope clone, class keep" \
    "$(jq -rs '[.[] | select(.kind=="file" and (.path|endswith("lanes.local.json")) and .class=="keep" and .scope=="clone")] | length >= 1' "$ledA" 2>/dev/null)" "true"
check "A ledger mode 0600" "$(stat -c %a "$ledA" 2>/dev/null || stat -f %Lp "$ledA" 2>/dev/null)" "600"

# ── B: a failing adopt.sh ends the session failed at step adopt ────────────
cloneB="$work/b-clone"; make_clone "$cloneB" 1
homeB="$work/b-home"; mkdir -p "$homeB"
outB=$(run_install "$cloneB" "$homeB" --scope user); rcB=$?
check "B install rc is non-zero" "$([ "$rcB" -ne 0 ] && echo yes || echo no)" "yes"
ledB="$homeB/.himmel/provenance.jsonl"
check "B first row is install-begin" "$(jq -rs '.[0].op // "none"' "$ledB" 2>/dev/null)" "install-begin"
check "B last row is install-end failed adopt" \
    "$(jq -rs '.[-1] | (.op // "none") + " " + (.status // "none") + " " + (.failed_step // "none")' "$ledB" 2>/dev/null)" \
    "install-end failed adopt"
[ "$rcB" -eq 0 ] && echo "note: install output: $outB"

# ── C: control -- --dry-run writes no ledger and prints DRY: lines ─────────
cloneC="$work/c-clone"; make_clone "$cloneC" 0
homeC="$work/c-home"; mkdir -p "$homeC"
outC=$(run_install "$cloneC" "$homeC" --scope user --dry-run); rcC=$?
check "C dry-run rc" "$rcC" "0"
check "C dry-run wrote no ledger" "$([ -e "$homeC/.himmel/provenance.jsonl" ] && echo yes || echo no)" "no"
check "C dry-run wrote no ledger dir" "$([ -e "$homeC/.himmel" ] && echo yes || echo no)" "no"
check "C dry-run prints a DRY: shim record line" "$(printf '%s\n' "$outC" | grep -c '^DRY: record create shim ')" "1"

# ── D: luna-config save() records one json-key row per top-level section it
# created or changed (an unchanged section records nothing) ─────────────────
provD="$work/d-prov"; cfgD="$work/d-cfg/config.json"
lunacfg="$(winpath "$repo/scripts/himmelctl/lib/luna-config.js")"
run_save() { # <edit-luna-vaultPath: 0|1>
    HIMMEL_PROVENANCE_DIR="$(winpath "$provD")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgD")" \
        "$node_bin" -e "const l=require(process.argv[1]);const d=l.defaultConfig();if(process.argv[2]==='1')d.luna.vaultPath='/tmp/other-vault';l.save(d);" "$lunacfg" "$1" 2>&1
}
outD1=$(run_save 0); rcD1=$?
check "D first save rc" "$rcD1" "0"
[ "$rcD1" -eq 0 ] || echo "note: save output: $outD1"
ledD="$provD/provenance.jsonl"
check "D first save: a create row per section (version, luna, bridge)" \
    "$(jq -rs '[.[] | select(.kind=="json-key" and .op=="create" and .class=="state" and .file_created==true) | .unit] | sort | join(",")' "$ledD" 2>/dev/null)" \
    "/bridge,/luna,/version"
outD2=$(run_save 1); rcD2=$?
check "D second save rc" "$rcD2" "0"
[ "$rcD2" -eq 0 ] || echo "note: save output: $outD2"
check "D second save: only the changed section (luna) is a replace row" \
    "$(jq -rs '[.[] | select(.kind=="json-key" and .op=="replace") | .unit] | join(",")' "$ledD" 2>/dev/null)" "/luna"
check "D second save: the replace row is not a file_created row" \
    "$(jq -rs '[.[] | select(.kind=="json-key" and .op=="replace")][0].file_created' "$ledD" 2>/dev/null)" "false"
check "D second save: a ledger backup of the prior section exists" \
    "$(find "$provD/provenance-backups" -type f 2>/dev/null | wc -l | tr -d ' ')" "1"

# an existing config that is not valid JSON has an unknown pre-state: it is
# replaced but no section row is recorded (that would claim ownership of it)
rowsD3_before="$(jq -rs 'length' "$ledD" 2>/dev/null)"
printf 'not json\n' > "$cfgD"
outD3=$(run_save 0); rcD3=$?
check "D corrupt-config save rc" "$rcD3" "0"
[ "$rcD3" -eq 0 ] || echo "note: save output: $outD3"
check "D corrupt-config save records no rows" "$(jq -rs 'length' "$ledD" 2>/dev/null)" "$rowsD3_before"

echo "passes=$passes fails=$fails"
[ "$fails" -eq 0 ]
