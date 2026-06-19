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

# --- HIMMEL-418: atomic-write hardening + launch-race jitter ---

# T8: a successful write leaves NO temp file behind (renamed away, not orphaned).
CFG="$TMP/notmp.json"
WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR" >/dev/null; rc=$?
leftover=$(find "$TMP" -maxdepth 1 -name 'notmp.json.tmp-trust-*' | wc -l | tr -d ' ')
assert_eq "T8 success rc" "0" "$rc"
assert_eq "T8 no temp file orphaned" "0" "$leftover"

# T9: jitter seam is named in the helper and disabled cleanly with =0 (functional).
grep -q 'TRUST_WRITE_JITTER_MS' "$HELPER"; assert_eq "T9 jitter env seam present" "0" "$?"
CFG="$TMP/jit0.json"
TRUST_WRITE_JITTER_MS=0 WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR"; rc=$?
assert_eq "T9 jitter=0 rc" "0" "$rc"
assert_eq "T9 jitter=0 sets flag" "true" "$(read_flag "$CFG" "$KEY")"

# T10: jitter is bounded in MILLISECONDS, not seconds (catch a units bug). A
# 900ms cap must complete well under 5s even with node startup; a `sleep 900`
# (seconds) units bug would blow past it.
CFG="$TMP/jitbound.json"
start=$(date +%s%3N)
TRUST_WRITE_JITTER_MS=900 WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR" >/dev/null; rc=$?
end=$(date +%s%3N)
elapsed=$(( end - start ))
assert_eq "T10 jitter-bound rc" "0" "$rc"
if [ "$elapsed" -lt 5000 ]; then echo "PASS T10 jitter bounded in ms (${elapsed}ms)"; else echo "FAIL T10 jitter bounded in ms — took ${elapsed}ms (units bug?)"; FAILED=$((FAILED + 1)); fi

# T11: write failure (config parent dir missing) → fail-open: clean warning on
# stderr, non-fatal non-zero rc, NO orphaned temp file. Read returns ENOENT
# (treated as fresh {}), then the temp write under the missing parent fails.
CFG="$TMP/ghost/sub.json"   # $TMP/ghost does not exist
err=$(TRUST_WRITE_JITTER_MS=0 WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$WORKDIR" 2>&1 >/dev/null); rc=$?
assert_eq "T11 write-failure rc (documented exit 4)" "4" "$rc"
case "$err" in
  *ensure-workspace-trust:*) echo "PASS T11 write-failure warns on stderr" ;;
  *) echo "FAIL T11 write-failure warns on stderr — got '$err'"; FAILED=$((FAILED + 1)) ;;
esac
leftover=$(find "$TMP" -name 'sub.json.tmp-trust-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T11 no temp file orphaned on failure" "0" "$leftover"

# T12 (best-effort): two coincident calls against the same config never corrupt
# it. Atomic rename guarantees the file is ALWAYS valid JSON; both-entries is a
# probabilistic property (jitter reduces lost-update) and is NOT asserted here.
CFG="$TMP/race.json"; printf '%s\n' '{"projects":{}}' > "$CFG"
DIRA="$TMP/ra"; DIRB="$TMP/rb"; mkdir -p "$DIRA" "$DIRB"
WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$DIRA" >/dev/null 2>&1 &
WORKSPACE_TRUST_CONFIG="$CFG" bash "$HELPER" "$DIRB" >/dev/null 2>&1 &
wait
valid=$(F="$CFG" node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.env.F,"utf8"));process.stdout.write(j&&typeof j.projects==="object"?"ok":"bad")}catch(e){process.stdout.write("bad")}')
assert_eq "T12 concurrent writes never corrupt the file" "ok" "$valid"

echo
if [ "$FAILED" -eq 0 ]; then echo "All ensure-workspace-trust tests passed."; else echo "$FAILED test(s) failed."; exit 1; fi
