#!/usr/bin/env bash
# Tests for scripts/lib/ensure-workspace-trust.sh (HIMMEL-386).
# The helper is invoked as a subprocess (it shells out to node), so each
# case runs `bash "$HELPER" <dir>` against a throwaway $WORKSPACE_TRUST_CONFIG.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/ensure-workspace-trust.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

command -v node >/dev/null 2>&1 || { echo "SKIP all — node not on PATH"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Mirror the helper's key-normalization so assertions compare apples to apples.
norm_key() {
    local d abs
    d="$1"
    abs=$(cd "$d" && pwd)
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$abs"; else printf '%s' "$abs"; fi
}

# Read projects[<key>].hasTrustDialogAccepted back out of a config file.
read_flag() {
    F="$1" K="$2" node -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.env.F,"utf8"));
const v=j.projects && j.projects[process.env.K] && j.projects[process.env.K].hasTrustDialogAccepted;
process.stdout.write(String(v));
'
}

WORKDIR="$TMP/work"; mkdir -p "$WORKDIR"
KEY=$(norm_key "$WORKDIR")

# T1: config file missing → created, key trusted, rc 0.
CFG="$TMP/missing.json"
WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR"; rc=$?
assert_eq "T1 missing-config rc" "0" "$rc"
assert_eq "T1 missing-config sets flag" "true" "$(read_flag "$CFG" "$KEY")"

# T2: existing config with OTHER projects → key added, others preserved.
CFG="$TMP/other.json"
printf '%s\n' '{"numStartups":7,"projects":{"C:/other/repo":{"hasTrustDialogAccepted":true,"foo":1}}}' > "$CFG"
WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR"; rc=$?
assert_eq "T2 preserve-others rc" "0" "$rc"
assert_eq "T2 new key set" "true" "$(read_flag "$CFG" "$KEY")"
assert_eq "T2 sibling project kept" "true" "$(read_flag "$CFG" "C:/other/repo")"
assert_eq "T2 top-level key kept" "7" "$(F="$CFG" node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.env.F,"utf8")).numStartups))')"

# T3: already-true → no-op, rc 0, content byte-identical.
CFG="$TMP/already.json"
WT_K="$KEY" node -e 'const fs=require("fs");fs.writeFileSync(process.env.F,JSON.stringify({projects:{[process.env.WT_K]:{hasTrustDialogAccepted:true}}},null,2))' F="$CFG" >/dev/null 2>&1 || \
  F="$CFG" WT_K="$KEY" node -e 'const fs=require("fs");fs.writeFileSync(process.env.F,JSON.stringify({projects:{[process.env.WT_K]:{hasTrustDialogAccepted:true}}},null,2))'
before=$(cat "$CFG")
WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR"; rc=$?
after=$(cat "$CFG")
assert_eq "T3 already-true rc" "0" "$rc"
assert_eq "T3 already-true no rewrite" "$before" "$after"

# T4: project entry exists but flag absent → flag set, sibling field preserved.
CFG="$TMP/partial.json"
F="$CFG" WT_K="$KEY" node -e 'const fs=require("fs");fs.writeFileSync(process.env.F,JSON.stringify({projects:{[process.env.WT_K]:{exampleFilesGenerated:true}}}))'
WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR"; rc=$?
assert_eq "T4 partial rc" "0" "$rc"
assert_eq "T4 flag set" "true" "$(read_flag "$CFG" "$KEY")"
assert_eq "T4 sibling field kept" "true" "$(F="$CFG" K="$KEY" node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.env.F,"utf8")).projects[process.env.K].exampleFilesGenerated))')"

# T5: config is invalid JSON → rc 3, file NOT overwritten (clobber guard).
CFG="$TMP/broken.json"
printf '%s' '{ this is not json' > "$CFG"
before=$(cat "$CFG")
WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR" 2>/dev/null; rc=$?
after=$(cat "$CFG")
assert_eq "T5 invalid-json rc" "3" "$rc"
assert_eq "T5 invalid-json not overwritten" "$before" "$after"

# T6: dir does not exist → rc 2.
WORKSPACE_TRUST_CONFIG="$TMP/x.json" bash "$HELPER" "$TMP/nope" 2>/dev/null; rc=$?
assert_eq "T6 missing-dir rc" "2" "$rc"

# T7: no argument → rc 2.
WORKSPACE_TRUST_CONFIG="$TMP/x.json" bash "$HELPER" 2>/dev/null; rc=$?
assert_eq "T7 no-arg rc" "2" "$rc"

echo
if [ "$FAILED" -eq 0 ]; then echo "All ensure-workspace-trust tests passed."; else echo "$FAILED test(s) failed."; exit 1; fi
