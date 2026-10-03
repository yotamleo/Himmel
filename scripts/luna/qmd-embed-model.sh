#!/usr/bin/env bash
# qmd-embed-model.sh — choose qmd's embedding model per machine, and keep the
# index consistent with it (HIMMEL-4232).
#
# WHY: Qwen3-Embedding-0.6B beats the default embeddinggemma-300M on our golden
# set (scoped hybrid MRR .886 to .930, HIMMEL-4184), but not every machine can
# build an index with it. So it is an OPTION, chosen per machine; gemma stays
# the default.
#
# THE TRAP THIS GUARDS: qmd records the model PER VECTOR (content_vectors.model)
# and the vector dimension PER INDEX (vectors_vec float[N]), but its query path
# never checks which model made a vector. gemma is 768d and Qwen 1024d, so that
# pair at least errors; a same-dimension model swap returns garbage silently.
# `check` compares the configured model with every model in the index and fails
# on ANY difference, whatever the dimensions.
#
# Subcommands:
#   capability                 classify this host: build | query | none
#   set gemma|qwen [--force]   write models.embed into the qmd config
#   check [--index P]          configured model vs the index's vectors
#   reembed --model gemma|qwen [--copy F] [--collections a,b] [--qmd-bin P [--qmd-js P]]
#                              build a re-embedded COPY of the index (never the live one)
#   swap --copy F              swap a re-embedded copy in atomically and flip the config
#
# CAPABILITY CLASSES (Qwen only; gemma is allowed everywhere):
#   build  an NVIDIA GPU with at least 4 GiB of VRAM, or Apple Silicon. Can embed
#          a whole corpus (about 2 h for ours on an RTX 4090).
#   query  no such GPU, at least 4 GiB of RAM. Can embed one short query per
#          search on CPU, so it can SEARCH a Qwen index it receives from
#          ship-index.sh, but should not build one.
#   none   less than 4 GiB of RAM. `set qwen` refuses without --force.
#
# Exit codes:
#   0 ok | 1 usage | 2 refused (capability, guard, daemon running)
#   3 MISMATCH: the index holds vectors from a model other than the configured one
#   4 cannot verify (sqlite3 missing, unreadable index)
#   5 a step failed (copy, embed, swap)
#
# Config and index paths follow qmd's own resolution: QMD_CONFIG_DIR, else
# $XDG_CONFIG_HOME/qmd, else ~/.config/qmd (index.yml); INDEX_PATH, else
# $XDG_CACHE_HOME/qmd, else ~/.cache/qmd (index.sqlite). The model resolves as
# qmd does: models.embed in index.yml, else QMD_EMBED_MODEL, else gemma.
set -euo pipefail

GEMMA_URI='hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf'
QWEN_URI='hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf'
MIN_VRAM_MIB=4096
MIN_RAM_KIB=4194304

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf 'qmd-embed-model: %s\n' "$*"; }
warn() { printf 'WARN qmd-embed-model: %s\n' "$*" >&2; }
die()  { local c="$1"; shift; printf 'ERR qmd-embed-model: %s\n' "$*" >&2; exit "$c"; }

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

config_dir() {
    if [ -n "${QMD_CONFIG_DIR:-}" ]; then printf '%s\n' "$QMD_CONFIG_DIR"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then printf '%s\n' "$XDG_CONFIG_HOME/qmd"
    else printf '%s\n' "$HOME/.config/qmd"; fi
}
config_file() { printf '%s/index.yml\n' "$(config_dir)"; }
index_file() {
    if [ -n "${INDEX_PATH:-}" ]; then printf '%s\n' "$INDEX_PATH"
    elif [ -n "${XDG_CACHE_HOME:-}" ]; then printf '%s\n' "$XDG_CACHE_HOME/qmd/index.sqlite"
    else printf '%s\n' "$HOME/.cache/qmd/index.sqlite"; fi
}

model_uri() {
    case "$1" in
        gemma) printf '%s\n' "$GEMMA_URI" ;;
        qwen)  printf '%s\n' "$QWEN_URI" ;;
        *) die 1 "unknown model '$1' (expected gemma or qwen)" ;;
    esac
}

# models.embed from a qmd config file (empty when unset). A two-level YAML read:
# the `embed:` key directly under a top-level `models:` block.
yml_embed() {
    [ -f "$1" ] || return 0
    awk '
        /^[^[:space:]#]/ { inmodels = ($0 ~ /^models:[[:space:]]*$/) ; next }
        inmodels && /^[[:space:]]+embed:/ {
            v = $0; sub(/^[[:space:]]+embed:[[:space:]]*/, "", v)
            sub(/[[:space:]]+#.*$/, "", v); gsub(/^["\047]|["\047]$/, "", v)
            print v; exit
        }' "$1"
}

configured_model() {
    local m
    m="$(yml_embed "$(config_file)")"
    if [ -n "$m" ]; then printf '%s\n' "$m"
    elif [ -n "${QMD_EMBED_MODEL:-}" ]; then printf '%s\n' "$QMD_EMBED_MODEL"
    else printf '%s\n' "$GEMMA_URI"; fi
}

# Rewrite models.embed in a config file atomically, keeping every other line.
write_yml_embed() {
    local file="$1" uri="$2" tmp
    mkdir -p "$(dirname "$file")"
    tmp="$file.tmp.$$"
    if [ -f "$file" ]; then
        awk -v uri="$uri" '
            function emit() { print "  embed: " uri; done = 1 }
            /^[^[:space:]#]/ {
                if (inmodels && !done) emit()
                inmodels = ($0 ~ /^models:[[:space:]]*$/)
                print; next
            }
            inmodels && /^[[:space:]]+embed:/ { if (!done) emit(); next }
            { print }
            END {
                if (inmodels && !done) emit()
                else if (!done) { print "models:"; emit() }
            }' "$file" >"$tmp"
    else
        printf 'models:\n  embed: %s\n' "$uri" >"$tmp"
    fi
    mv -f "$tmp" "$file"
}

# --- capability --------------------------------------------------------------
CAP_REASON="" CAP_CLASS=""
# Sets CAP_CLASS (build|query|none) and CAP_REASON. Not run in $(...): the
# reason would be lost in the subshell.
capability() {
    local vram="" mem_kib="" os arch
    os="$(uname -s 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"
    if [ "$os" = Darwin ] && [ "$arch" = arm64 ]; then
        CAP_REASON="Apple Silicon (Metal)"; CAP_CLASS=build; return 0
    fi
    local smi="${QMD_EMBED_NVIDIA_SMI:-nvidia-smi}"
    if command -v "$smi" >/dev/null 2>&1; then
        vram="$("$smi" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | tr -d ' \r' | sort -n | tail -1 || true)"
        case "$vram" in ''|*[!0-9]*) vram="" ;; esac
    fi
    if [ -n "$vram" ] && [ "$vram" -ge "$MIN_VRAM_MIB" ]; then
        CAP_REASON="NVIDIA GPU, ${vram} MiB VRAM"; CAP_CLASS=build; return 0
    fi
    if [ "$os" = Darwin ]; then
        mem_kib=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
    else
        mem_kib="$(awk '/^MemTotal:/ {print $2; exit}' "${QMD_EMBED_MEMINFO:-/proc/meminfo}" 2>/dev/null || true)"
    fi
    case "$mem_kib" in ''|*[!0-9]*) mem_kib=0 ;; esac
    local gpu_note="no usable GPU"
    if [ -n "$vram" ]; then gpu_note="GPU has only ${vram} MiB VRAM"; fi
    if [ "$mem_kib" -ge "$MIN_RAM_KIB" ]; then
        CAP_REASON="$gpu_note, $((mem_kib / 1024)) MiB RAM: CPU query embedding only"; CAP_CLASS=query
    else
        CAP_REASON="$gpu_note, $((mem_kib / 1024)) MiB RAM (below 4 GiB)"; CAP_CLASS=none
    fi
}

# --- index inspection --------------------------------------------------------
need_sqlite() { command -v sqlite3 >/dev/null 2>&1 || die 4 "sqlite3 not on PATH; cannot read the index to verify its embed model"; }
index_models() {
    sqlite3 -readonly "$1" "SELECT DISTINCT model FROM content_vectors ORDER BY model;" 2>/dev/null
}
index_dims() {
    sqlite3 -readonly "$1" "SELECT sql FROM sqlite_master WHERE name='vectors_vec';" 2>/dev/null \
        | sed -n 's/.*float\[\([0-9]*\)\].*/\1/p'
}

# Compare a configured model with an index. rc 0 match/empty, 3 mismatch, 4 cannot read.
compare_index() {
    local idx="$1" want="$2" models rc=0 m bad=""
    if [ ! -f "$idx" ]; then say "no index at $idx yet; nothing to compare"; return 0; fi
    need_sqlite
    models="$(index_models "$idx")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'ERR qmd-embed-model: could not read content_vectors from %s\n' "$idx" >&2
        return 4
    fi
    if [ -z "$models" ]; then say "index has no vectors yet; nothing to compare"; return 0; fi
    while IFS= read -r m; do
        if [ -n "$m" ] && [ "$m" != "$want" ]; then bad="$bad $m"; fi
    done <<<"$models"
    if [ -n "$bad" ]; then
        {
            echo "ERR qmd-embed-model: MODEL MISMATCH — the index was embedded with a model other than the configured one."
            echo "    configured : $want"
            # shellcheck disable=SC2086  # word-split the newline list on purpose
            echo "    index has  :$(printf ' %s' $models)"
            echo "    vector dims: $(index_dims "$idx")"
            echo "    Vector search on this index returns errors or garbage until they match."
            echo "    Fix: build a matching copy and swap it in (bash $HERE/qmd-embed-model.sh reembed, then swap),"
            echo "    or set the config back to the index's model (qmd-embed-model.sh set <model>)."
        } >&2
        return 3
    fi
    say "ok: index vectors match the configured model ($want)"
    return 0
}

daemon_running() {
    pgrep -f 'qmd(\.js)? mcp' >/dev/null 2>&1
}

# --- subcommands -------------------------------------------------------------
cmd_capability() {
    capability
    say "$CAP_CLASS ($CAP_REASON)"
}

cmd_set() {
    local name="" force=0 uri idx rc=0 m
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1; shift ;;
            gemma|qwen) name="$1"; shift ;;
            *) die 1 "set: unknown arg '$1'" ;;
        esac
    done
    [ -n "$name" ] || die 1 "set needs a model: gemma or qwen"
    uri="$(model_uri "$name")"
    if [ "$name" = qwen ]; then
        capability
        case "$CAP_CLASS" in
            build) say "capability: build ($CAP_REASON)" ;;
            query) warn "capability: query only ($CAP_REASON). This host can SEARCH a Qwen index but should not BUILD one: CPU embedding of a whole corpus is slow (see docs/internals/qmd-embed-model.md for the measured cost). Receive the index with ship-index.sh instead." ;;
            *)
                if [ "$force" -eq 1 ]; then warn "capability: none ($CAP_REASON); --force given, writing anyway"
                else die 2 "capability: none ($CAP_REASON). Qwen needs at least 4 GiB of RAM even to embed queries. Pass --force to override."; fi ;;
        esac
    fi
    idx="$(index_file)"
    if [ -f "$idx" ] && command -v sqlite3 >/dev/null 2>&1; then
        m="$(index_models "$idx" || true)"
        if [ -n "$m" ] && [ "$(printf '%s\n' "$m" | grep -vxF -- "$uri" | head -1)" != "" ]; then
            if [ "$force" -eq 1 ]; then
                warn "the index at $idx holds vectors from another model; it now MISMATCHES until a matching index is swapped in or shipped here"
            else
                # shellcheck disable=SC2086  # word-split the newline list on purpose
                die 2 "the index at $idx holds vectors from another model ($(printf '%s ' $m)). Switching the config alone breaks vector search. On a host that builds its index: reembed then swap (swap flips the config). On a receiver about to get a $name index from ship-index.sh: re-run with --force."
            fi
        fi
    fi
    write_yml_embed "$(config_file)" "$uri" || rc=$?
    [ "$rc" -eq 0 ] || die 5 "could not write $(config_file)"
    say "models.embed = $uri in $(config_file)"
}

cmd_check() {
    local idx=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --index) [ $# -ge 2 ] || die 1 "--index needs a path"; idx="$2"; shift 2 ;;
            *) die 1 "check: unknown arg '$1'" ;;
        esac
    done
    [ -n "$idx" ] || idx="$(index_file)"
    local rc=0
    compare_index "$idx" "$(configured_model)" || rc=$?
    return "$rc"
}

QMD_BIN="" QMD_JS="" SCRATCH=""
run_qmd() {
    if [ -n "$QMD_JS" ]; then "$QMD_BIN" "$QMD_JS" "$@"; else "$QMD_BIN" "$@"; fi
}
resolve_qmd() {
    if [ -z "$QMD_BIN" ]; then
        # shellcheck source=../lib/qmd-bin.sh
        . "$HERE/../lib/qmd-bin.sh"
        local r=""
        r="$(qmd_pinned_invocation 2>/dev/null)" || die 2 "no usable qmd found; pass --qmd-bin"
        QMD_BIN="$(printf '%s\n' "$r" | sed -n 1p)"
        QMD_JS="$(printf '%s\n' "$r" | sed -n 2p)"
    fi
    [ -x "$QMD_BIN" ] || die 2 "qmd '$QMD_BIN' is not executable"
}

cmd_reembed() {
    local name="" copy="" cols="" live uri rc=0 out
    while [ $# -gt 0 ]; do
        case "$1" in
            --model) [ $# -ge 2 ] || die 1 "--model needs gemma or qwen"; name="$2"; shift 2 ;;
            --copy) [ $# -ge 2 ] || die 1 "--copy needs a path"; copy="$2"; shift 2 ;;
            --collections) [ $# -ge 2 ] || die 1 "--collections needs a list"; cols="$2"; shift 2 ;;
            --qmd-bin) [ $# -ge 2 ] || die 1 "--qmd-bin needs a path"; QMD_BIN="$2"; shift 2 ;;
            --qmd-js) [ $# -ge 2 ] || die 1 "--qmd-js needs a path"; QMD_JS="$2"; shift 2 ;;
            *) die 1 "reembed: unknown arg '$1'" ;;
        esac
    done
    [ -n "$name" ] || die 1 "reembed needs --model gemma|qwen"
    uri="$(model_uri "$name")"
    live="$(index_file)"
    [ -f "$live" ] || die 5 "no live index at $live to copy"
    [ -n "$copy" ] || copy="$(dirname "$live")/index.reembed-$name.sqlite"
    case "$copy" in /*) : ;; *) die 1 "--copy must be an absolute path" ;; esac
    [ "$copy" != "$live" ] || die 2 "--copy is the live index; reembed never writes the live index"
    [ ! -e "$copy" ] || die 2 "$copy already exists; remove it or pick another --copy"
    need_sqlite
    resolve_qmd

    say "[1/4] consistent copy of $live to $copy"
    if [ -n "$cols" ]; then
        node "$HERE/prepare-ship-index.mjs" --src "$live" --out "$copy" --collections "$cols" >/dev/null \
            || die 5 "prepare-ship-index could not build the copy"
    else
        sqlite3 -readonly "$live" ".backup '$copy'" || { rm -f "$copy"; die 5 "sqlite3 .backup failed"; }
    fi

    # qmd reads models.embed from the config BEFORE QMD_EMBED_MODEL, so the
    # override needs its own config dir: a copy of the real one with only
    # models.embed changed. The live config is never touched.
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/qmd-reembed.XXXXXX")"
    trap 'rm -rf "$SCRATCH"' EXIT
    local scratch="$SCRATCH"
    [ -f "$(config_file)" ] && cp "$(config_file)" "$scratch/index.yml"
    write_yml_embed "$scratch/index.yml" "$uri"

    say "[2/4] qmd embed --force on the copy with $uri (long: about 2 h for our corpus on a 4090)"
    INDEX_PATH="$copy" QMD_CONFIG_DIR="$scratch" run_qmd embed --force --timeout 0 || rc=$?
    [ "$rc" -eq 0 ] || die 5 "qmd embed failed on the copy (rc=$rc); the live index is untouched. Remove $copy and retry."

    say "[3/4] completeness: a second embed pass must find nothing to do"
    out="$(INDEX_PATH="$copy" QMD_CONFIG_DIR="$scratch" run_qmd embed 2>&1)" || die 5 "completeness pass failed"
    grep -qF 'All content hashes already have embeddings' <<<"$out" \
        || die 5 "the copy is not fully embedded; second pass said: $(printf '%s' "$out" | tail -3)"

    say "[4/4] model check on the copy"
    rc=0
    compare_index "$copy" "$uri" || rc=$?
    [ "$rc" -eq 0 ] || die 5 "the copy failed its model check"
    say "built $copy with $name. To switch this host: bash $HERE/qmd-embed-model.sh swap --copy $copy"
}

cmd_swap() {
    local copy="" live models uri cfg ts backup n
    while [ $# -gt 0 ]; do
        case "$1" in
            --copy) [ $# -ge 2 ] || die 1 "--copy needs a path"; copy="$2"; shift 2 ;;
            *) die 1 "swap: unknown arg '$1'" ;;
        esac
    done
    [ -n "$copy" ] || die 1 "swap needs --copy <re-embedded index>"
    [ -f "$copy" ] || die 1 "no copy at $copy"
    live="$(index_file)"
    [ "$copy" != "$live" ] || die 1 "--copy is the live index"
    # rename(2) is atomic only within one filesystem; one directory guarantees it.
    [ "$(cd "$(dirname "$copy")" && pwd -P)" = "$(cd "$(dirname "$live")" && pwd -P)" ] \
        || die 2 "the copy must sit in the live index's directory ($(dirname "$live")) so the swap is one atomic rename"
    need_sqlite
    models="$(index_models "$copy")" || die 4 "cannot read $copy"
    n="$(printf '%s\n' "$models" | grep -c . || true)"
    [ "$n" -eq 1 ] || die 2 "the copy must hold vectors from exactly one model (found $n)"
    uri="$models"
    if daemon_running; then
        die 2 "a qmd mcp daemon is running; it holds the live index open. Stop it first (qmd mcp stop, and any MCP client), then re-run swap"
    fi
    for s in "$live-wal" "$copy-wal"; do
        [ ! -s "$s" ] || die 2 "$s is not empty: a process still has that database open, or it was not closed cleanly. Run 'qmd status' once to checkpoint it, then retry"
    done

    ts="$(date +%Y%m%d-%H%M%S)"
    backup="$live.pre-swap-$ts"
    cfg="$(config_file)"
    if [ -f "$live" ]; then
        ln "$live" "$backup" 2>/dev/null || cp -p "$live" "$backup" || die 5 "could not keep a backup of the live index"
    fi
    if [ -f "$cfg" ]; then cp -p "$cfg" "$cfg.pre-swap-$ts"; fi
    mv -f "$copy" "$live" || die 5 "the rename failed; the live index is unchanged (backup at $backup)"
    rm -f "$copy-wal" "$copy-shm" "$live-shm"
    write_yml_embed "$cfg" "$uri"
    local rc=0
    compare_index "$live" "$uri" || rc=$?
    if [ "$rc" -ne 0 ]; then
        die 5 "post-swap check failed. Roll back: mv -f '$backup' '$live' && cp -p '$cfg.pre-swap-$ts' '$cfg'"
    fi
    say "swapped: $live now holds $uri; config updated. Backups: $backup, $cfg.pre-swap-$ts"
    say "restart the qmd daemon/MCP clients; delete the backup once searches look right"
}

[ $# -ge 1 ] || { usage >&2; exit 1; }
sub="$1"; shift
case "$sub" in
    capability) cmd_capability "$@" ;;
    set)        cmd_set "$@" ;;
    check)      cmd_check "$@" ;;
    reembed)    cmd_reembed "$@" ;;
    swap)       cmd_swap "$@" ;;
    -h|--help)  usage ;;
    *) usage >&2; exit 1 ;;
esac
