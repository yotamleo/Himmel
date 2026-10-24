#!/usr/bin/env bash
# Unit tests for scripts/luna/qmd-embed-model.sh.
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
[ -n "$proc" ] && grep -qE -- <<<"$proc" "${!#}"
EOF
# nvidia-smi stub: prints $FAKE_VRAM MiB, or fails when it is empty.
cat >"$STUBS/fake-smi" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_VRAM:-}" ] || exit 9
echo "$FAKE_VRAM"
EOF
# uname stub: the capability rows model a Linux host, so an Apple-silicon runner
# does not short-circuit to "build" before the nvidia-smi and meminfo seams.
cat >"$STUBS/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -m) echo x86_64 ;; *) echo Linux ;; esac
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
    env -u QMD_CONFIG_DIR -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u INDEX_PATH -u QMD_EMBED_MODEL -u QMD_RERANK_MODEL -u QMD_GENERATE_MODEL \
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

# An inline-scalar models: line must be replaced, not shadowed by an appended second block.
# YAML parse uses python3 yaml when importable; otherwise the strict ^models: count stands alone.
yaml_loads() {
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then return 0; fi
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$1"
}
n=0
for inline in 'models: null' 'models: ~' 'models: {}' 'models: null # per machine'; do
    n=$((n+1))
    new_home "12-$n"
    printf 'collections:\n  luna:\n    path: /x\n%s\nother: keep\n' "$inline" >"$(CFG)"
    rc=0; run bash "$SCRIPT" set gemma >/dev/null 2>&1 || rc=$?
    cfg="$(cat "$(CFG)")"
    assert_rc "set over '$inline' succeeds" 0 "$rc"
    assert_rc "'$inline': exactly one models: key" 1 "$(grep -c '^models:' "$(CFG)")"
    tail_comment=""
    case "$inline" in *'#'*) tail_comment=" #${inline#*#}" ;; esac
    want="$(printf 'collections:\n  luna:\n    path: /x\nmodels:%s\n  embed: %s\nother: keep' "$tail_comment" "$GEMMA")"
    if [ "$cfg" = "$want" ]; then pass "'$inline': embed written in place, other lines preserved"; else fail "'$inline': embed written in place, other lines preserved" "$cfg"; fi
    rc=0; yaml_loads "$(CFG)" 2>/dev/null || rc=$?
    assert_rc "'$inline': result loads as YAML" 0 "$rc"
done

new_home 12n
printf 'collections:\n  luna:\n    path: /x\n    models: null\n' >"$(CFG)"
run bash "$SCRIPT" set gemma >/dev/null 2>&1
cfg="$(cat "$(CFG)")"
assert_contains "an indented models: null is left alone" "    models: null" "$cfg"
assert_rc "an indented models: null still gets one top-level block appended" 1 "$(grep -c '^models:' "$(CFG)")"

echo "== reembed"
# retired collection filtering must fail before creating a copy.
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --collections luna --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed rejects retired --collections" 1 "$rc"
assert_contains "retired filtering is an unknown option" "reembed: unknown arg '--collections'" "$out"
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
assert_contains "embed batches 4096 docs so a remote embedder commits per batch" "--max-docs-per-batch 4096" "$log"
if [ ! -e "$copy.partial" ]; then pass "a finished run removes the resume marker"; else fail "a finished run removes the resume marker"; fi
# A finished copy is a snapshot of an older live index: never reused.
sqlite3 "$copy" "CREATE TABLE resume_marker(x INT);"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed refuses a finished copy" 2 "$rc"
assert_contains "the refusal names the finished copy" "finished copy of an older live index" "$out"
# A copy that still carries the marker is a partial run: resume it.
: >"$copy.partial"
: >"$H/qmd.log"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed resumes a partial copy of the target model" 0 "$rc"
if [ ! -e "$copy.partial" ]; then pass "the resumed run removes the resume marker"; else fail "the resumed run removes the resume marker"; fi
assert_contains "the resume kept the copy (no new backup)" "resume_marker" "$(sqlite3 "$copy" .tables)"
log="$(cat "$H/qmd.log")"
assert_contains "the resume embeds without --force" "ARGS=embed --timeout 0 --max-docs-per-batch 4096" "$log"
assert_not_contains "the resume never forces" "embed --force" "$log"
# An interrupted first pass leaves the marker on a copy that still holds the old model: restart it forced, keep the copy.
sqlite3 "$copy" "UPDATE content_vectors SET model='$GEMMA';"
: >"$copy.partial"
: >"$H/qmd.log"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed restarts an interrupted copy that still holds the old model" 0 "$rc"
assert_contains "the restart kept the copy (no new backup)" "resume_marker" "$(sqlite3 "$copy" .tables)"
assert_contains "the restart embeds forced" "ARGS=embed --force --timeout 0 --max-docs-per-batch 4096" "$(cat "$H/qmd.log")"
# A copy still holding another model is not resumable.
sqlite3 "$copy" "UPDATE content_vectors SET model='$GEMMA';"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed refuses a copy holding another model" 2 "$rc"
assert_contains "the refusal says to remove the copy" "remove it or pick another --copy" "$out"
sqlite3 "$copy" "UPDATE content_vectors SET model='$QWEN'; DROP TABLE resume_marker;"
# A link to the live index is the live index: never resumed.
ln -s "$(IDX)" "$H/.cache/qmd/link.sqlite"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --copy "$H/.cache/qmd/link.sqlite" --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed refuses a symlink to the live index as --copy" 2 "$rc"
assert_contains "the link refusal names the live index" "same file as the live index" "$out"
rm -f "$H/.cache/qmd/link.sqlite"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --copy "$(IDX)" --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed refuses the live index as --copy" 2 "$rc"

# A pre-existing marker path (here a link to the live index) is never truncated.
rm -f "$copy" "$copy.partial"
ln -s "$(IDX)" "$copy.partial"
live_sum="$(cksum <"$(IDX)")"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed refuses a marker path that already exists" 2 "$rc"
assert_contains "the marker refusal names the path" "already exists or cannot be created" "$out"
assert_rc "the live index was not touched by the marker write" 0 "$([ "$live_sum" = "$(cksum <"$(IDX)")" ] && echo 0 || echo 1)"
rm -f "$copy.partial"
rc=0; out=$(run bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
assert_rc "reembed rebuilds the copy once the marker path is clear" 0 "$rc"

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
assert_contains "swap tells the operator not to start qmd by hand" "do not start qmd by hand until the swap finishes" "$out"
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
if [ ! -e "$H/.cache/qmd/embed-swap.lock" ]; then pass "the swap lock is released after the commit"; else fail "the swap lock is released after the commit"; fi

echo "== swap lock (HIMMEL-4314)"
# A relaunched daemon mid-swap served the old model's query embeddings against
# the new vectors. The swap holds <cache>/qmd/embed-swap.lock from its liveness
# check to its commit or rollback; a daemon start path must see it.
new_home 12
make_index "$(IDX)" 768 "$GEMMA"
printf 'models:\n  embed: %s\n' "$GEMMA" >"$(CFG)"
make_index "$H/.cache/qmd/index.reembed-qwen.sqlite" 1024 "$QWEN"
LOCK="$H/.cache/qmd/embed-swap.lock"
# the hook stands in for the relauncher: it runs between the rename and the
# config flip and records whether the lock is held and by which pid.
rc=0; out=$(run env QMD_EMBED_SWAP_MID_HOOK="cat '$LOCK/pid' >'$H/mid-pid'; cat '$LOCK/role' >'$H/mid-role'; ls -d '$LOCK' >'$H/mid-lock'" \
    bash "$SCRIPT" swap --copy "$H/.cache/qmd/index.reembed-qwen.sqlite" 2>&1) || rc=$?
assert_rc "swap with a mid-swap hook succeeds" 0 "$rc"
if [ -s "$H/mid-lock" ]; then pass "the lock is held mid-swap"; else fail "the lock is held mid-swap"; fi
if [ -s "$H/mid-pid" ]; then pass "the lock records its holder pid"; else fail "the lock records its holder pid"; fi
if [ "$(cat "$H/mid-role" 2>/dev/null)" = swap ]; then pass "the lock records the swap role"; else fail "the lock records the swap role"; fi
if [ ! -e "$LOCK" ]; then pass "the lock is released after a committed swap"; else fail "the lock is released after a committed swap"; fi

# a failed swap still releases the lock (rollback path: the post-swap check fails)
new_home 13
make_index "$(IDX)" 768 "$GEMMA"
make_index "$H/.cache/qmd/index.reembed-qwen.sqlite" 1024 "$QWEN"
LOCK="$H/.cache/qmd/embed-swap.lock"
rc=0; out=$(run env FAKE_DAEMON=1 bash "$SCRIPT" swap --copy "$H/.cache/qmd/index.reembed-qwen.sqlite" 2>&1) || rc=$?
assert_rc "swap refused for a running daemon" 2 "$rc"
if [ ! -e "$LOCK" ]; then pass "a refused swap releases the lock"; else fail "a refused swap releases the lock"; fi

# a second swap while the first is live is refused; the first's lock survives
mkdir -p "$LOCK"
sleep 30 &
HOLDER=$!
echo "$HOLDER" >"$LOCK/pid"
rc=0; out=$(run bash "$SCRIPT" swap --copy "$H/.cache/qmd/index.reembed-qwen.sqlite" 2>&1) || rc=$?
assert_rc "swap refuses while another swap holds the lock" 2 "$rc"
assert_contains "the refusal names the holder" "$HOLDER" "$out"
if [ -d "$LOCK" ]; then pass "a live holder's lock is left alone"; else fail "a live holder's lock is left alone"; fi

# a dead holder's lock is stale: the swap clears it and proceeds
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
# another contender is mid-reclaim (its guard is fresh): do not clear under it,
# or both could win the lock
mkdir "$LOCK.reclaim"
rc=0; out=$(run bash "$SCRIPT" swap --copy "$H/.cache/qmd/index.reembed-qwen.sqlite" 2>&1) || rc=$?
assert_rc "swap yields to a reclaim already in flight" 2 "$rc"
if [ -d "$LOCK" ]; then pass "the stale lock is left to the reclaimer"; else fail "the stale lock is left to the reclaimer"; fi
rmdir "$LOCK.reclaim"
rc=0; out=$(run bash "$SCRIPT" swap --copy "$H/.cache/qmd/index.reembed-qwen.sqlite" 2>&1) || rc=$?
assert_rc "swap recovers a stale lock" 0 "$rc"
if [ ! -e "$LOCK.reclaim" ]; then pass "the reclaim guard is released"; else fail "the reclaim guard is released"; fi
if [ ! -e "$LOCK" ]; then pass "the recovered lock is released again"; else fail "the recovered lock is released again"; fi

echo "== jina gate on config writes"
new_home 6
printf 'collections:\n  luna:\n    path: /x\n  salus:\n    path: /s\nmodels:\n  embed: %s\n  rerank: openai:jina-reranker-v2-base-multilingual\n  openai_base_url: https://api.jina.ai/v1\n' "$GEMMA" >"$(CFG)"
before=$(cat "$(CFG)")
rc=0; out=$(run env FAKE_VRAM=24564 bash "$SCRIPT" set qwen --force 2>&1) || rc=$?
assert_rc "set refuses a Jina index that holds salus" 2 "$rc"
if [ "$(cat "$(CFG)")" = "$before" ]; then pass "the refused write leaves the config untouched"; else fail "the refused write leaves the config untouched"; fi
if ls "$H"/.config/qmd/index.yml.tmp.* >/dev/null 2>&1; then fail "no temp file is left behind"; else pass "no temp file is left behind"; fi

new_home 7
printf 'collections:\n  luna:\n    path: /x\nmodels:\n  embed: %s\n  rerank: openai:jina-reranker-v2-base-multilingual\n  openai_base_url: https://api.jina.ai/v1\n' "$GEMMA" >"$(CFG)"
rc=0; out=$(run env FAKE_VRAM=24564 bash "$SCRIPT" set qwen --force 2>&1) || rc=$?
assert_rc "set writes a Jina index with no salus collection" 0 "$rc"
assert_contains "the new model is written" "embed: $QWEN" "$(cat "$(CFG)")"

# the index database counts: an active salus document refuses a remote model
# even when the config lists no salus; swap refuses BEFORE the rename
new_home 8
make_index "$(IDX)" 768 "$GEMMA"
make_index "$H/.cache/qmd/index.reembed-qwen.sqlite" 1024 "$QWEN"
sqlite3 "$H/.cache/qmd/index.reembed-qwen.sqlite" "CREATE TABLE documents(collection TEXT, active INTEGER); INSERT INTO documents VALUES('himmel',1),('salus',1);"
printf 'collections:\n  himmel:\n    path: /x\nmodels:\n  embed: %s\n  rerank: openai:jina-reranker-v2-base-multilingual\n  openai_base_url: https://api.jina.ai/v1\n' "$GEMMA" >"$(CFG)"
before=$(cat "$(CFG)")
rc=0; out=$(run bash "$SCRIPT" swap --copy "$H/.cache/qmd/index.reembed-qwen.sqlite" 2>&1) || rc=$?
assert_rc "swap refuses a copy holding active salus documents under a remote model" 2 "$rc"
if [ -f "$H/.cache/qmd/index.reembed-qwen.sqlite" ]; then pass "the refused swap leaves the copy in place"; else fail "the refused swap leaves the copy in place"; fi
assert_contains "the live index still holds gemma" "$GEMMA" "$(sqlite3 "$(IDX)" 'select distinct model from content_vectors')"
if [ "$(cat "$(CFG)")" = "$before" ]; then pass "the refused swap leaves the config untouched"; else fail "the refused swap leaves the config untouched"; fi

# staging the live config for the gate must not fail silently: a failed copy
# would let the gate judge an incomplete config
new_home 14
make_index "$(IDX)" 768 "$GEMMA"
make_index "$H/.cache/qmd/index.reembed-qwen.sqlite" 1024 "$QWEN"
printf 'models:\n  embed: %s\n  rerank: openai:jina-reranker-v2-base-multilingual\n  openai_base_url: https://api.jina.ai/v1\n' "$GEMMA" >"$(CFG)"
REAL_CP="$(command -v cp)"
mkdir -p "$TMP_ROOT/cpfail"
printf '#!/bin/sh\ncase "$*" in *qmd-swap-gate*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_CP" >"$TMP_ROOT/cpfail/cp"
chmod +x "$TMP_ROOT/cpfail/cp"
rc=0; out=$(run env PATH="$TMP_ROOT/cpfail:$STUBS:$PATH" bash "$SCRIPT" swap --copy "$H/.cache/qmd/index.reembed-qwen.sqlite" 2>&1) || rc=$?
assert_rc "swap aborts when the config cannot be staged for the gate" 5 "$rc"
assert_contains "the abort names the staging failure" "could not stage the config" "$out"
assert_contains "the live index still holds gemma after the abort" "$GEMMA" "$(sqlite3 "$(IDX)" 'select distinct model from content_vectors')"

# swap_lock_stale is duplicated in the qmd plugin's ensure-qmd-daemon.sh (a
# plugin copy cannot source this repo); both copies must classify a lock dir alike.
PLUGIN_DAEMON="${QMD_DAEMON_SCRIPT:-$SCRIPT_DIR/../../marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh}"
stale_verdicts() { # <script>: stale/live verdict per lock-dir shape
    bash -c '
        eval "$(sed -n "$2" "$1")"
        d=$(mktemp -d) || exit 1; trap "rm -rf \"\$d\"" EXIT
        mkdir "$d/dead" "$d/live" "$d/nopid-fresh" "$d/nopid-old" "$d/junk"
        echo 2147483646 >"$d/dead/pid"; echo "$$" >"$d/live/pid"; echo abc >"$d/junk/pid"
        touch -t 200001010000 "$d/nopid-old" "$d/junk"
        for n in dead live nopid-fresh nopid-old junk; do
            if swap_lock_stale "$d/$n"; then echo "$n stale"; else echo "$n live"; fi
        done' _ "$1" '/^swap_lock_stale() {/,/^}/p'
}
want=$'dead stale\nlive live\nnopid-fresh live\nnopid-old stale\njunk stale'
for copy in "$SCRIPT" "$PLUGIN_DAEMON"; do
    got="$(stale_verdicts "$copy")"
    if [ "$got" = "$want" ]; then pass "swap_lock_stale in $(basename "$copy") classifies lock dirs"
    else fail "swap_lock_stale in $(basename "$copy") classifies lock dirs" "got: $got"; fi
done

echo "== remote model (HIMMEL-5756)"
REMOTE='openai:qwen/qwen3-embedding-8b'
new_home 40
printf 'collections:\n  notes:\n    path: %s\nmodels:\n  openai_base_url: http://127.0.0.1:9\n' "$H" >"$(CFG)"
rc=0; out=$(run bash "$SCRIPT" set remote 2>&1) || rc=$?
assert_rc "set remote writes the OpenRouter qwen3 embed model" 0 "$rc"
assert_contains "the config names the remote model" "embed: $REMOTE" "$(cat "$(CFG)")"
new_home 41
rc=0; out=$(run env QMD_REMOTE_EMBED_MODEL='hf:evil/x.gguf' bash "$SCRIPT" set remote 2>&1) || rc=$?
assert_rc "QMD_REMOTE_EMBED_MODEL must be an openai: URI" 1 "$rc"
new_home 42
printf 'collections:\n  salus:\n    path: /x\nmodels:\n  openai_base_url: https://openrouter.ai/api/v1\n' >"$(CFG)"
rc=0; out=$(run bash "$SCRIPT" set remote 2>&1) || rc=$?
assert_rc "set remote on a config holding salus is refused by the egress gate" 2 "$rc"

echo "== env-named remote model runs the gate (HIMMEL-5711)"
# A recording node shim stands in for the gate: it logs its argv and exits $FAKE_GATE_RC.
GSTUBS="$TMP_ROOT/gstubs"
mkdir -p "$GSTUBS"
cat >"$GSTUBS/node" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GATE_LOG"
exit "${FAKE_GATE_RC:-0}"
EOF
chmod +x "$GSTUBS/node"
LOCAL_CFG="$(printf 'collections:\n  luna:\n    path: /x\nmodels:\n  embed: %s\n  rerank: r\n' "$GEMMA")"
grun() { run env PATH="$GSTUBS:$STUBS:$PATH" FAKE_GATE_LOG="$H/gate.log" "$@"; }

new_home 50
printf '%s\n' "$LOCAL_CFG" >"$(CFG)"; before="$(cksum <"$(CFG)")"
rc=0; out=$(grun env QMD_RERANK_MODEL=openai:x FAKE_GATE_RC=1 FAKE_VRAM=24564 bash "$SCRIPT" set qwen 2>&1) || rc=$?
assert_rc "env remote model + gate refusal aborts the write" 2 "$rc"
assert_rc "the gate ran for a local-only config" 1 "$({ wc -l <"$H/gate.log" 2>/dev/null || echo 0; } | tr -d ' ')"
assert_rc "the live config is byte-identical after the refusal" 0 "$([ "$before" = "$(cksum <"$(CFG)")" ] && echo 0 || echo 1)"
for v in QMD_EMBED_MODEL QMD_GENERATE_MODEL; do
    new_home "50$v"
    printf '%s\n' "$LOCAL_CFG" >"$(CFG)"
    rc=0; out=$(grun env "$v=openai:x" FAKE_GATE_RC=1 FAKE_VRAM=24564 bash "$SCRIPT" set qwen 2>&1) || rc=$?
    assert_rc "$v naming openai: also runs the gate" 2 "$rc"
done

new_home 51
printf '%s\n' "$LOCAL_CFG" >"$(CFG)"
rc=0; out=$(grun env FAKE_GATE_RC=1 FAKE_VRAM=24564 bash "$SCRIPT" set qwen 2>&1) || rc=$?
assert_rc "local config + clean environment skips the gate" 0 "$rc"
if [ ! -s "$H/gate.log" ]; then pass "the gate shim was never called"; else fail "the gate shim was never called"; fi

new_home 52
make_index "$(IDX)" 768 "$GEMMA"
printf '%s\n' "$LOCAL_CFG" >"$(CFG)"
# A failing cp shim, not chmod: file modes do not stop root from reading the config.
printf '#!/usr/bin/env bash\nexit 1\n' >"$GSTUBS/cp"
chmod +x "$GSTUBS/cp"
rc=0; out=$(grun bash "$SCRIPT" reembed --model qwen --qmd-bin "$STUBS/qmd" 2>&1) || rc=$?
rm -f "$GSTUBS/cp"
assert_rc "reembed aborts when the config copy fails" 2 "$rc"
assert_contains "the abort names the config copy" "could not copy the qmd config" "$out"
assert_rc "the live config is untouched by the failed copy" 0 "$([ "$(cat "$(CFG)")" = "$LOCAL_CFG" ] && echo 0 || echo 1)"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -eq 0 ]
