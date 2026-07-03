#!/usr/bin/env bash
# Hermetic tests for scripts/omniroute-config-lint.sh (HIMMEL-654 WS2, child
# HIMMEL-666). bash 3.2-safe. Fixtures are generated from one compliant BASE by
# applying a tiny JS patch via node (node is the lint's own runtime dependency —
# same precedent as scripts/test-claude-glm.sh). Every case writes its config to
# a mktemp sandbox; nothing outside the sandbox is touched.
# shellcheck disable=SC2015  # && || pattern is intentional for ternary-like asserts
set -u
FAILS=0
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/omniroute-config-lint.sh"
WORK="$(mktemp -d)"
OUT="$WORK/out.txt"
trap 'rm -rf "$WORK"' EXIT

# Compliant reference config: every bundled optimizer explicitly disabled, free
# lane off. The RED path (default-on engine) is exercised by OMITTING keys below.
BASE_JSON='{"autoRoutingEnabled":false,"compression":{"enabled":false,"defaultMode":"off","autoTriggerMode":"off","rtkConfig":{"enabled":false},"cavemanConfig":{"enabled":false},"cavemanOutputMode":{"enabled":false},"ultra":{"enabled":false},"contextEditing":{"enabled":false},"languageConfig":{"enabled":false},"mcpDescriptionCompressionEnabled":false,"mcpAccessibilityConfig":{"enabled":false},"engines":{},"aggressive":{"summarizerEnabled":false,"toolStrategies":{}},"stackedPipeline":[],"cache":{"semanticCacheEnabled":false,"promptCacheEnabled":false}}}'

mkcfg() { # mkcfg <outfile> <patch-js over `c`> — writes a fixture derived from BASE
  BASE="$BASE_JSON" PATCH="$2" node -e '
const c = JSON.parse(process.env.BASE);
new Function("c", process.env.PATCH)(c);
require("fs").writeFileSync(process.argv[1], JSON.stringify(c, null, 2));
' "$1"
}

t() { # t <name> <want-exit> <configfile> — run the lint, capture combined output
  local name="$1" want="$2" cfg="$3"
  bash "$LINT" "$cfg" >"$OUT" 2>&1
  local got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $name (exit $got, want $want)"; cat "$OUT"; FAILS=$((FAILS+1))
  else
    echo "ok: $name"
  fi
}

have() { # assert last captured output contains a literal substring
  grep -qF -- "$1" "$OUT" || { echo "FAIL: output missing literal: $1"; cat "$OUT"; FAILS=$((FAILS+1)); }
}

PASS_LINE="PASS: omniroute compression stack disabled (18 keys asserted)"

# --- T1: compliant config -> PASS (exit 0) ---
mkcfg "$WORK/compliant.json" ""
t "compliant config passes" 0 "$WORK/compliant.json"
have "$PASS_LINE"

# --- T2: an optimization subtree is IGNORED (SQLite VACUUM tuning) -> still PASS ---
mkcfg "$WORK/opt.json" 'c.compression.optimization={vacuumIntervalMs:1000,walEnabled:true};'
t "optimization subtree ignored, still passes" 0 "$WORK/opt.json"
have "$PASS_LINE"

# --- T3: one engine explicitly ENABLED -> FAIL naming the key ---
mkcfg "$WORK/enabled.json" 'c.compression.rtkConfig.enabled=true;'
t "explicitly enabled engine fails" 1 "$WORK/enabled.json"
have "FAIL: compression.rtkConfig.enabled expected false, got true"

# --- T4: one engine entry OMITTED entirely -> FAIL (the default-on red path) ---
mkcfg "$WORK/omitted.json" 'delete c.compression.cavemanConfig;'
t "omitted engine fails (default-on red path)" 1 "$WORK/omitted.json"
have "FAIL: compression.cavemanConfig.enabled expected false, got <absent>"

# --- T5: mcpDescriptionCompressionEnabled true (source default TRUE) -> FAIL ---
mkcfg "$WORK/mcpdesc.json" 'c.compression.mcpDescriptionCompressionEnabled=true;'
t "default-on mcpDescriptionCompression true fails" 1 "$WORK/mcpdesc.json"
have "FAIL: compression.mcpDescriptionCompressionEnabled expected false, got true"

# --- T6: free lane autoRoutingEnabled ABSENT -> FAIL (permissive default-on) ---
mkcfg "$WORK/noauto.json" 'delete c.autoRoutingEnabled;'
t "autoRoutingEnabled absent fails" 1 "$WORK/noauto.json"
have "FAIL: autoRoutingEnabled expected false, got <absent>"

# --- T7: unknown key inside compression -> FAIL (renamed/new engine sneaking in) ---
mkcfg "$WORK/unknown.json" 'c.compression.newTurboEngine={enabled:true};'
t "unknown compression key fails" 1 "$WORK/unknown.json"
have "FAIL: compression.newTurboEngine is not a recognized key"

# --- T8: engines map with one enabled:true entry -> FAIL naming the entry ---
mkcfg "$WORK/engine-on.json" 'c.compression.engines={evil:{enabled:true}};'
t "engines entry enabled fails" 1 "$WORK/engine-on.json"
have 'FAIL: compression.engines["evil"].enabled expected false, got true'

# --- T8b: engines map with a properly disabled entry -> PASS (non-empty allowed) ---
mkcfg "$WORK/engine-off.json" 'c.compression.engines={legacy:{enabled:false}};'
t "engines disabled entry passes" 0 "$WORK/engine-off.json"
have "$PASS_LINE"

# --- T9: stackedPipeline non-empty -> FAIL ---
mkcfg "$WORK/stack.json" 'c.compression.stackedPipeline=[{name:"x"}];'
t "non-empty stackedPipeline fails" 1 "$WORK/stack.json"
have "FAIL: compression.stackedPipeline expected an empty array, got 1 entry"

# --- T9b: stackedPipeline with TWO entries -> FAIL using the PLURAL "entries"
# branch (the length>1 arm of the entry/ies ternary; T9 only covers the 1-entry
# "entry" arm). CR F1: this branch was untested on both twins. ---
mkcfg "$WORK/stack2.json" 'c.compression.stackedPipeline=[{name:"x"},{name:"y"}];'
t "two-entry stackedPipeline fails (plural)" 1 "$WORK/stack2.json"
have "FAIL: compression.stackedPipeline expected an empty array, got 2 entries"

# --- T10: wrong string value on defaultMode -> FAIL ---
mkcfg "$WORK/mode.json" 'c.compression.defaultMode="aggressive";'
t "wrong defaultMode fails" 1 "$WORK/mode.json"
have "FAIL: compression.defaultMode expected off, got aggressive"

# --- T11: aggressive.toolStrategies object entry enabled -> FAIL ---
mkcfg "$WORK/ts.json" 'c.compression.aggressive.toolStrategies={bigTool:{enabled:true}};'
t "toolStrategies object entry enabled fails" 1 "$WORK/ts.json"
have "FAIL: compression.aggressive.toolStrategies.bigTool.enabled expected false, got true"

# --- T11b: aggressive.toolStrategies BARE BOOLEAN true entry -> FAIL (the bare-
# boolean branch: a strategy expressed as `true` rather than `{enabled:...}`) ---
mkcfg "$WORK/tsbool.json" 'c.compression.aggressive.toolStrategies={bigTool:true};'
t "toolStrategies bare-boolean true entry fails" 1 "$WORK/tsbool.json"
have "FAIL: compression.aggressive.toolStrategies.bigTool expected false, got true"

# --- T12: compression object missing entirely -> FAIL ---
mkcfg "$WORK/nocomp.json" 'delete c.compression;'
t "missing compression object fails" 1 "$WORK/nocomp.json"
have "FAIL: compression object is missing"

# --- T13: ALL failures reported, not just the first ---
mkcfg "$WORK/multi.json" 'c.compression.ultra.enabled=true; delete c.autoRoutingEnabled;'
t "reports all failures" 1 "$WORK/multi.json"
have "FAIL: compression.ultra.enabled expected false, got true"
have "FAIL: autoRoutingEnabled expected false, got <absent>"

# --- T13b..T13f: defensive structural FAIL branches (CR F2). Each exercises a
# guard the happy path never hits, so a future fail-open simplification is caught.
# These mirror the .ps1 twin case-for-case (keep both twins' matrices in sync). ---
# engines MISSING -> the structural guard fires (not the per-entry loop)
mkcfg "$WORK/noeng.json" 'delete c.compression.engines;'
t "engines missing fails" 1 "$WORK/noeng.json"
have "FAIL: compression.engines missing (expected an object with every entry disabled)"

# engines present but NOT an object -> the guard before the per-entry loop
mkcfg "$WORK/engnonobj.json" 'c.compression.engines=true;'
t "engines non-object fails" 1 "$WORK/engnonobj.json"
have "FAIL: compression.engines expected an object, got true"

# aggressive.toolStrategies MISSING -> the summarizer assert still passes; only
# the toolStrategies structural guard fires
mkcfg "$WORK/nots.json" 'delete c.compression.aggressive.toolStrategies;'
t "toolStrategies missing fails" 1 "$WORK/nots.json"
have "FAIL: compression.aggressive.toolStrategies missing (expected an object with every entry disabled)"

# aggressive.toolStrategies entry that is a STRING (not bool, not object) -> the
# `else` disabled-expected branch (T11/T11b cover only the object + bare-bool arms)
mkcfg "$WORK/tsstr.json" 'c.compression.aggressive.toolStrategies={weird:"somestring"};'
t "toolStrategies string entry fails" 1 "$WORK/tsstr.json"
have "FAIL: compression.aggressive.toolStrategies.weird expected disabled, got somestring"

# stackedPipeline MISSING -> the absent-key structural arm (T9/T9b cover
# present-but-non-empty)
mkcfg "$WORK/nosp.json" 'delete c.compression.stackedPipeline;'
t "stackedPipeline missing fails" 1 "$WORK/nosp.json"
have "FAIL: compression.stackedPipeline missing (expected an empty array)"

# --- T14: missing/unreadable file -> exit 2 ---
t "missing file exits 2" 2 "$WORK/does-not-exist.json"

# --- T15: unparseable JSON -> exit 2 ---
printf '{ this is not json' > "$WORK/bad.json"
t "unparseable JSON exits 2" 2 "$WORK/bad.json"

# --- T16: non-object JSON root -> exit 2 ---
printf '["a","b"]' > "$WORK/array.json"
t "array root exits 2" 2 "$WORK/array.json"

# --- T17: usage (no args) -> exit 2 ---
bash "$LINT" >"$OUT" 2>&1; got=$?
[ "$got" -eq 2 ] && echo "ok: no-args usage exits 2" || { echo "FAIL: no-args usage (exit $got, want 2)"; cat "$OUT"; FAILS=$((FAILS+1)); }

# --- T18: usage (two args) -> exit 2 ---
bash "$LINT" a b >"$OUT" 2>&1; got=$?
[ "$got" -eq 2 ] && echo "ok: two-args usage exits 2" || { echo "FAIL: two-args usage (exit $got, want 2)"; cat "$OUT"; FAILS=$((FAILS+1)); }

# --- T19: FAIL diagnostics route to STDERR (not stdout); PASS stays on stdout.
# CR F5: locks the routing contract so a future regression that re-merges FAIL to
# stdout is caught. (The cases above capture 2>&1, so they pass either way.) ---
mkcfg "$WORK/rfail.json" 'c.compression.ultra.enabled=true;'
ROUT_OUT="$WORK/rout-stdout.txt"; ROUT_ERR="$WORK/rout-stderr.txt"
bash "$LINT" "$WORK/rfail.json" >"$ROUT_OUT" 2>"$ROUT_ERR"; grc=$?
if [ "$grc" -ne 1 ]; then echo "FAIL: routing case wrong exit ($grc, want 1)"; FAILS=$((FAILS+1)); else echo "ok: routing case exit 1"; fi
{ grep -qF "FAIL: compression.ultra.enabled expected false, got true" "$ROUT_ERR" && echo "ok: FAIL line on stderr"; } || { echo "FAIL: FAIL line not on stderr"; FAILS=$((FAILS+1)); }
if grep -qF "FAIL:" "$ROUT_OUT"; then echo "FAIL: FAIL line leaked to stdout"; FAILS=$((FAILS+1)); else echo "ok: no FAIL line on stdout"; fi
# PASS on stdout, nothing on stderr
bash "$LINT" "$WORK/compliant.json" >"$ROUT_OUT" 2>"$ROUT_ERR"; prc=$?
if [ "$prc" -ne 0 ]; then echo "FAIL: compliant routing case wrong exit ($prc, want 0)"; FAILS=$((FAILS+1)); else echo "ok: compliant routing exit 0"; fi
{ grep -qF "$PASS_LINE" "$ROUT_OUT" && echo "ok: PASS on stdout"; } || { echo "FAIL: PASS not on stdout"; FAILS=$((FAILS+1)); }
if [ -s "$ROUT_ERR" ]; then echo "FAIL: PASS case wrote to stderr"; cat "$ROUT_ERR"; FAILS=$((FAILS+1)); else echo "ok: PASS case stderr empty"; fi

# --- T20: node runtime ABSENT from PATH -> exit 4 with a clear stderr message
# (CR F3 red-path). JSON parsing is delegated to node, so a missing node must fail
# closed on the node-missing=4 contract (matching the claude-routed twins), not a
# generic "node: command not found" (127). Uses the proven empty-PATH pattern from
# scripts/hooks/test-block-glm-external-writes.sh run_case_no_jq: absolute bash +
# an empty PATH dir so `command -v node` fails. (Isolating a coreutils-only PATH is
# itself PATH-fragile on Windows/msys — cat needs its colocated DLLs — but the exit-4
# preflight fires before the LINT_JS heredoc's cat output matters, so the benign
# "cat: command not found" noise is ignored; we assert only the node-missing line.) ---
BASH_ABS="$(command -v bash)"
NONODE_PATH="$WORK/nonode-path"; mkdir -p "$NONODE_PATH"
NODE_ERR="$WORK/nonode-stderr.txt"
PATH="$NONODE_PATH" "$BASH_ABS" "$LINT" "$WORK/compliant.json" >"$OUT" 2>"$NODE_ERR"; nrc=$?
if [ "$nrc" -ne 4 ]; then echo "FAIL: node-missing case wrong exit ($nrc, want 4)"; cat "$NODE_ERR"; FAILS=$((FAILS+1)); else echo "ok: node-missing exits 4"; fi
{ grep -qF "omniroute-config-lint: node is required" "$NODE_ERR" && echo "ok: node-missing message on stderr"; } || { echo "FAIL: node-missing message not on stderr"; cat "$NODE_ERR"; FAILS=$((FAILS+1)); }

# --- T21 (CR F6, #836): a DUPLICATE JSON key makes the config ambiguous. Both
# engines (node JSON.parse, PS ConvertFrom-Json) silently keep the LAST value, so a
# duplicate-key config could lint differently per platform if an engine ever kept
# FIRST. The lint now rejects duplicate keys explicitly (pre-parse scan) on BOTH
# twins, so the outcome is deterministic and cross-platform identical. This case
# injects a duplicate autoRoutingEnabled whose LAST value is `false` (compliant) —
# WITHOUT detection the lint would PASS (exit 0), so the exit-1 + dup message here
# PROVES detection fired, not coincidental keep-last catching a non-compliant last
# value. The .ps1 twin asserts the IDENTICAL outcome + message (parity). ---
DUP_JSON="$WORK/dupkey.json"
BASE="$BASE_JSON" node -e 'const fs=require("fs"); const d=process.env.BASE.replace("{\"autoRoutingEnabled\":false,", "{\"autoRoutingEnabled\":true,\"autoRoutingEnabled\":false,"); fs.writeFileSync(process.argv[1], d);' "$DUP_JSON"
t "duplicate-key config rejected (exit 1, both twins)" 1 "$DUP_JSON"
have 'FAIL: duplicate JSON key "autoRoutingEnabled"'

# --- T22 (CR F6, #836 — CR round 2): NESTED duplicate key. The engine keys this
# lint exists to catch live in nested objects (rtkConfig.enabled etc.), and the
# scanner's per-object stack is what distinguishes a real nested dup from the
# many legitimate same-name "enabled" keys across DIFFERENT objects (which T1's
# compliant PASS already guards). A dup INSIDE one nested object must flag —
# this catches any future "flatten/scan-root-only" regression that T21's
# top-level case would miss. LAST value compliant (false) for the same
# detection-proof reasoning as T21. The .ps1 twin asserts the IDENTICAL
# outcome + message (parity). ---
NESTED_DUP_JSON="$WORK/nesteddupkey.json"
BASE="$BASE_JSON" node -e 'const fs=require("fs"); const d=process.env.BASE.replace("\"rtkConfig\":{\"enabled\":false}", "\"rtkConfig\":{\"enabled\":true,\"enabled\":false}"); if (d===process.env.BASE) { console.error("T22 fixture injection did not match BASE"); process.exit(1); } fs.writeFileSync(process.argv[1], d);' "$NESTED_DUP_JSON"
t "nested duplicate-key config rejected (exit 1, both twins)" 1 "$NESTED_DUP_JSON"
have 'FAIL: duplicate JSON key "enabled"'

# --- T23 (CR F6, #836 — CR round 2): CASE-VARIANT sibling keys — a DOCUMENTED
# ENGINE DIVERGENCE, deliberately pinned per twin (not parity). JSON keys are
# case-sensitive: node's JSON.parse accepts {"enabled":…,"Enabled":…} as two
# distinct keys → the scan (case-sensitive) sees no dup → this twin PASSes exit 0.
# PowerShell's ConvertFrom-Json REJECTS keys differing only in case ("keys with
# different casing") BEFORE the scan runs → the .ps1 twin exits 2 (invalid JSON,
# fail-closed — the safe direction). The exact-dup parity guarantee (T21/T22) is
# scoped to exact-case duplicates; this case pins each twin's actual behavior so
# neither drifts silently. ---
CASE_JSON="$WORK/casevariantkey.json"
BASE="$BASE_JSON" node -e 'const fs=require("fs"); const d=process.env.BASE.replace("\"rtkConfig\":{\"enabled\":false}", "\"rtkConfig\":{\"enabled\":false,\"Enabled\":false}"); if (d===process.env.BASE) { console.error("T23 fixture injection did not match BASE"); process.exit(1); } fs.writeFileSync(process.argv[1], d);' "$CASE_JSON"
t "case-variant sibling keys accepted by node, no dup flag (exit 0; .ps1 twin exits 2 — documented divergence)" 0 "$CASE_JSON"

echo; [ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS failure(s)"; exit 1; }
