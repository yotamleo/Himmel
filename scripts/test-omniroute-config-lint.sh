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

echo; [ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS failure(s)"; exit 1; }
