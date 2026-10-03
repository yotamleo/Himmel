#!/usr/bin/env bash
# Unit tests for scripts/luna/qmd-embed-model.sh (HIMMEL-4232).
#
# Hermetic: a scratch HOME, a FAKE qmd, stubbed nvidia-smi and pgrep, and tiny
# synthetic sqlite fixtures that carry only what the script reads
# (content_vectors.model and the vectors_vec CREATE text). Needs sqlite3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/qmd-embed-model.sh"

PASS=0
FAIL=0
TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() { if [ -n "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT" 2>/dev/null || true; fi; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1" "missing: $2"; fi
}
assert_not_contains() {
    if grep -qF -- "$2" <<<"$3"; then fail "$1" "unexpected: $2"; else pass "$1"; fi
}
assert_rc() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected rc=$2, got rc=$3"; fi; }

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "SKIP: sqlite3 not on PATH"
    exit 0
fi

GEMMA='hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf'
QWEN='hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf'

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-qmd-embed-model.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"

# pgrep stub: matches its pattern against $FAKE_PROC (FAKE_DAEMON=1 is a
# running `qmd mcp`).
cat >"$STUBS/pgrep" <<'EOF'
#!/usr/bin/env bash
proc="${FAKE_PROC:-}"
if [ "${FAKE_DAEMON:-0}" = 1 ]; then proc="node /x/qmd.js mcp"; fi
[ -n "$proc" ] && printf '%s\n' "$proc" | grep -qE -- "${!#}"
EOF
# nvidia-smi stub: prints $FAKE_VRAM MiB, or fails when it is empty.
cat >"$STUBS/fake-smi" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_VRAM:-}" ] || exit 9
echo "$FAKE_VRAM"
EOF
# Fake qmd: `embed --force` rewrites every vector's model to the one the config
# names, and records what it saw; a plain `embed` prints the all-clear.
cat >"$STUBS/qmd" <<'EOF'
#!/usr/bin/env bash
printf 'INDEX_PATH=%s QMD_CONFIG_DIR=%s ARGS=%s\n' "$INDEX_PATH" "$QMD_CONFIG_DIR" "$*" >>"$FAKE_QMD_LOG"
if [ "$1" = embed ] && [ "${2:-}" = --force ]; then
    m="$(sed -n 's/^  embed: //p' "$QMD_CONFIG_DIR/index.yml")"
    sqlite3 "$INDEX_PATH" "UPDATE content_vectors SET model='$m';"
    echo "Embedded 3 chunks"
    exit 0
fi
echo "✓ All content hashes already have embeddings."
EOF
chmod +x "$STUBS"/*

# make_index <path> <dims> <model>...
make_index() {
    local p="$1" dims="$2"; shift 2
    mkdir -p "$(dirname "$p")"
    local sql="CREATE TABLE content_vectors(hash TEXT, seq INT, model TEXT);
CREATE TABLE vectors_vec(hash_seq TEXT, embedding BLOB /* float[$dims] distance_metric=cosine */);"
    local i=0 m
    for m in "$@"; do i=$((i+1)); sql="$sql INSERT INTO content_vectors VALUES('h$i',0,'$m');"; done
    sqlite3 "$p" "$sql"
}

# Each case gets a fresh HOME. Run the script with the stubs first on PATH.
new_home() {
    H="$TMP_ROOT/home$1"
    mkdir -p "$H/.config/qmd" "$H/.cache/qmd"
    printf 'MemTotal:       16000000 kB\n' >"$H/meminfo"
}
run() {
    env -u QMD_CONFIG_DIR -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u INDEX_PATH -u QMD_EMBED_MODEL \
        HOME="$H" PATH="$STUBS:$PATH" QMD_EMBED_NVIDIA_SMI="$STUBS/fake-smi" \
        QMD_EMBED_MEMINFO="$H/meminfo" FAKE_QMD_LOG="$H/qmd.log" "$@"
}
CFG() { printf '%s/.config/qmd/index.yml' "$H"; }
IDX() { printf '%s/.cache/qmd/index.sqlite' "$H"; }

echo "== check"
new_home 1
make_index "$(IDX)" 768 "$GEMMA" "$GEMMA"
rc=0; out=$(run bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "default config + gemma index matches" 0 "$rc"

printf 'collections:\n  luna:\n    path: /x\nmodels:\n  embed: %s\n  rerank: r\n' "$QWEN" >"$(CFG)"
rc=0; out=$(run bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "qwen config on a gemma index is a MISMATCH" 3 "$rc"
assert_contains "mismatch names the configured model" "configured : $QWEN" "$out"
assert_contains "mismatch reports the dims" "vector dims: 768" "$out"

new_home 2
make_index "$(IDX)" 768 "hf:someone/other-768-GGUF/other.gguf"
rc=0; out=$(run bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "same-dimension different model still fails" 3 "$rc"

new_home 3
make_index "$(IDX)" 768 "$GEMMA" "$QWEN"
printf 'models:\n  embed: %s\n' "$GEMMA" >"$(CFG)"
rc=0; out=$(run bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "a mixed-model index fails" 3 "$rc"

new_home 4
rc=0; out=$(run bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "no index yet is not a mismatch" 0 "$rc"

new_home 5
make_index "$(IDX)" 1024 "$QWEN"
rc=0; out=$(run env QMD_EMBED_MODEL="$QWEN" bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "QMD_EMBED_MODEL is honoured when the config sets none" 0 "$rc"
rc=0; out=$(run bash "$SCRIPT" check --index "$(IDX)" 2>&1) || rc=$?
assert_rc "without the env the default (gemma) mismatches a qwen index" 3 "$rc"

new_home 5b
printf 'not a database' >"$(IDX)"
rc=0; out=$(run env FAKE_VRAM=24564 bash "$SCRIPT" set qwen 2>&1) || rc=$?
assert_rc "set refuses when the index's model cannot be read" 4 "$rc"
assert_not_contains "the config is not written" "$QWEN" "$(cat "$(CFG)" 2>/dev/null)"
rc=0; out=$(run env FAKE_VRAM=24564 bash "$SCRIPT" set qwen --force 2>&1) || rc=$?
assert_rc "set --force writes past an unreadable index" 0 "$rc"

echo "== capability"
new_home 6
rc=0; out=$(run env FAKE_VRAM=24564 bash "$SCRIPT" capability 2>&1) || rc=$?
assert_contains "24 GiB GPU is build-capable" "build (NVIDIA GPU, 24564 MiB VRAM)" "$out"
out=$(run env FAKE_VRAM=2048 bash "$SCRIPT" capability 2>&1)
assert_contains "small GPU + 16 GB RAM is query-capable" "query (GPU has only 2048 MiB VRAM" "$out"
out=$(run bash "$SCRIPT" capability 2>&1)
assert_contains "no GPU + 16 GB RAM is query-capable" "query (no usable GPU" "$out"
printf 'MemTotal:        2000000 kB\n' >"$H/meminfo"
out=$(run bash "$SCRIPT" capability 2>&1)
assert_contains "no GPU + 2 GB RAM is none" "none (no usable GPU" "$out"

echo "== set"
rc=0; out=$(run bash "$SCRIPT" set qwen 2>&1) || rc=$?
assert_rc "set qwen refuses on a none host" 2 "$rc"
if [ ! -f "$(CFG)" ]; then pass "refused set wrote no config"; else fail "refused set wrote no config"; fi
rc=0; out=$(run bash "$SCRIPT" set qwen --force 2>&1) || rc=$?
assert_rc "set qwen --force writes on a none host" 0 "$rc"
assert_contains "--force wrote the qwen uri" "embed: $QWEN" "$(cat "$(CFG)")"

new_home 7
printf 'collections:\n  luna:\n    path: /x\n    pattern: "**/*.md"\nmodels:\n  embed: %s\n  generate: g\n  rerank: r\n' "$GEMMA" >"$(CFG)"
rc=0; out=$(run env FAKE_VRAM=24564 bash "$SCRIPT" set qwen 2>&1) || rc=$?
assert_rc "set qwen on a build host with no index" 0 "$rc"
cfg="$(cat "$(CFG)")"
assert_contains "set rewrote models.embed" "  embed: $QWEN" "$cfg"
assert_not_contains "set dropped the old embed line" "$GEMMA" "$cfg"
assert_contains "set kept models.generate" "  generate: g" "$cfg"
assert_contains "set kept collections" '    pattern: "**/*.md"' "$cfg"

new_home 8
rc=0; out=$(run bash "$SCRIPT" set qwen 2>&1) || rc=$?
assert_rc "set qwen on a query host proceeds" 0 "$rc"
assert_contains "query host gets a WARN" "WARN qmd-embed-model: capability: query only" "$out"

new_home 9
make_index "$(IDX)" 768 "$GEMMA"
rc=0; out=$(run env FAKE_VRAM=24564 bash "$SCRIPT" set qwen 2>&1) || rc=$?
assert_rc "set qwen refuses while the index holds gemma" 2 "$rc"
assert_contains "the refusal points at reembed then swap" "reembed then swap" "$out"
rc=0; out=$(run env FAKE_VRAM=24564 bash "$SCRIPT" set qwen --force 2>&1) || rc=$?
assert_rc "set qwen --force on a gemma index proceeds (receiver path)" 0 "$rc"
assert_contains "--force on a mismatching index WARNs" "now MISMATCHES" "$out"

new_home 10
printf 'collections:\n  luna:\n    path: /x\n' >"$(CFG)"
run bash "$SCRIPT" set gemma >/dev/null 2>&1
cfg="$(cat "$(CFG)")"
assert_contains "set appends a models block when absent" "models:
  embed: $GEMMA" "$cfg"

new_home 10b
make_index "$(IDX)" 1024 "$QWEN"
printf 'models: # per machine\n  embed: %s\n' "$QWEN" >"$(CFG)"
rc=0; out=$(run bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "a commented models: line is still read" 0 "$rc"
run bash "$SCRIPT" set gemma --force >/dev/null 2>&1
cfg="$(cat "$(CFG)")"
assert_contains "set rewrites embed under a commented models: line" "embed: $GEMMA" "$cfg"
assert_rc "set leaves one models block" 1 "$(grep -c '^models:' "$(CFG)")"

echo "== reembed"
new_home 11
make_index "$(IDX)" 768 "$GEMMA" "$GEMMA"
printf 'models:\n  embed: %s\n' "$GEMMA" >"$(CFG)"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed builds a copy" 0 "$rc"
copy="$H/.cache/qmd/index.reembed-qwen.sqlite"
assert_contains "the copy holds qwen vectors" "$QWEN" "$(sqlite3 "$copy" 'select distinct model from content_vectors')"
assert_contains "the live index still holds gemma" "$GEMMA" "$(sqlite3 "$(IDX)" 'select distinct model from content_vectors')"
assert_not_contains "the live index has no qwen vectors" "$QWEN" "$(sqlite3 "$(IDX)" 'select distinct model from content_vectors')"
assert_contains "the live config is untouched" "embed: $GEMMA" "$(cat "$(CFG)")"
log="$(cat "$H/qmd.log")"
assert_contains "qmd embedded the COPY" "INDEX_PATH=$copy " "$log"
assert_not_contains "qmd never used the live config dir" "QMD_CONFIG_DIR=$H/.config/qmd " "$log"
assert_contains "embed ran forced with no session cap" "ARGS=embed --force --timeout 0" "$log"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed refuses to overwrite an existing copy" 2 "$rc"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --copy "$(IDX)" --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed refuses the live index as --copy" 2 "$rc"

echo "== swap"
rc=0; out=$(run env FAKE_DAEMON=1 bash "$SCRIPT" swap --copy "$copy" 2>&1) || rc=$?
assert_rc "swap refuses while a qmd mcp daemon runs" 2 "$rc"
rc=0; out=$(run env FAKE_PROC="node /x/qmd.js embed" bash "$SCRIPT" swap --copy "$copy" 2>&1) || rc=$?
assert_rc "swap refuses while a qmd embed writes the index" 2 "$rc"
rc=0; out=$(run env FAKE_PROC="qmd update" bash "$SCRIPT" swap --copy "$copy" 2>&1) || rc=$?
assert_rc "swap refuses while a qmd update writes the index" 2 "$rc"
mkdir -p "$H/elsewhere"; cp "$copy" "$H/elsewhere/c.sqlite"
rc=0; out=$(run bash "$SCRIPT" swap --copy "$H/elsewhere/c.sqlite" 2>&1) || rc=$?
assert_rc "swap refuses a copy outside the live index's directory" 2 "$rc"
rc=0; out=$(run bash "$SCRIPT" swap --copy "$copy" 2>&1) || rc=$?
assert_rc "swap succeeds" 0 "$rc"
assert_contains "the live index now holds qwen" "$QWEN" "$(sqlite3 "$(IDX)" 'select distinct model from content_vectors')"
assert_contains "swap flipped the config" "embed: $QWEN" "$(cat "$(CFG)")"
if [ ! -e "$copy" ]; then pass "the copy was renamed into place"; else fail "the copy was renamed into place"; fi
bk="$(find "$H/.cache/qmd" -name 'index.sqlite.pre-swap-*' | head -1)"
if [ -n "$bk" ]; then
    assert_contains "the backup keeps the gemma index" "$GEMMA" "$(sqlite3 "$bk" 'select distinct model from content_vectors')"
else
    fail "swap kept a backup of the old index"
fi
rc=0; out=$(run bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "check passes after the swap" 0 "$rc"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -eq 0 ]
