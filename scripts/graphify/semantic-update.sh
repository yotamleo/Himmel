#!/usr/bin/env bash
# semantic-update.sh — HIMMEL-4185: incremental semantic layer for one corpus.
#
# WHY: the armed graphmap cadence rebuilds only the AST graph (hourly/daily
# `graphify update`); semantic extraction of markdown never runs on a schedule.
# refresh-graph-map.sh can run it, but it copies the whole corpus, re-runs
# clustering + LLM community labeling and has no change gate or spend cap.
# This step re-extracts ONLY the markdown files whose content changed since the
# last semantic pass and merges the result into the live graph.json.
#
# Flow: fence --eval (salus / any DENY refuses before anything is copied) ->
# content-hash plan against <out>/semantic-manifest.json -> no change = no-op
# (no bank, no copy) -> promote lock, re-planned under it (the HIMMEL-910 protocol ast-update.sh and
# refresh-graph-map.sh share) -> bank-preflight -> scratch copy of the changed
# files only (+ `.graphify-corpus` marker + seeded semantic cache) ->
# `graphify extract --no-cluster` -> semantic-merge.py merge -> harden-graph.py.
# Clustering is left to the next AST pass, which reclusters and keeps semantic
# nodes. Each run appends one line to <out>/semantic-runs.jsonl (nodes/edges
# added and removed, backlog, runtime, tokens, cost equivalent).
#
# BILLING: --backend claude-cli makes graphify shell `claude -p` once per chunk,
# which draws the SAME subscription 5h/weekly bank as interactive use
# (HIMMEL-128); hence the bank-preflight gate and the --max-files cap. Changed
# files above the cap stay unstamped and roll to the next run (reported as
# `backlog`).
#
# Usage:
#   semantic-update.sh --name N --corpus-root R --corpus-class C
#       [--backend claude-cli] [--max-files 150] [--seed-manifest] [--dry-run]
#
# --seed-manifest stamps the current hashes as the baseline without extracting:
# run it once on a corpus whose graph already carries a semantic pass, or the
# first run treats every file as changed.
#
# Exit: 0 ok / no-op; 1 usage or IO; 2 fence deny, graphify or merge failure;
# 3 bank at/over threshold (nothing touched); 4 promote lock held.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

NAME="" CORPUS_ROOT="" CORPUS_CLASS="" BACKEND="claude-cli" MAX_FILES=150 SEED=0 DRY=0
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    --corpus-class) CORPUS_CLASS="${2:-}"; shift 2 ;;
    --backend) BACKEND="${2:-}"; shift 2 ;;
    --max-files) MAX_FILES="${2:-}"; shift 2 ;;
    --seed-manifest) SEED=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "semantic-update: unknown argument '$1'" >&2; usage ;;
  esac
done
if [ -z "$NAME" ] || [ -z "$CORPUS_ROOT" ] || [ -z "$CORPUS_CLASS" ]; then usage; fi
case "$NAME" in *[!A-Za-z0-9._-]*) echo "semantic-update: --name must match [A-Za-z0-9._-]+" >&2; exit 1 ;; esac
case "$MAX_FILES" in ''|*[!0-9]*) MAX_FILES=0 ;; *) MAX_FILES=$((10#$MAX_FILES)) ;; esac
[ "$MAX_FILES" -gt 0 ] || { echo "semantic-update: --max-files must be a positive integer" >&2; exit 1; }
[ -d "$CORPUS_ROOT" ] || { echo "semantic-update: --corpus-root '$CORPUS_ROOT' is not a directory" >&2; exit 1; }
CORPUS_ROOT="$(cd "$CORPUS_ROOT" && pwd -P)"
# ponytail: only the default out dir, a GRAPHIFY_OUT override is refused; add it if a corpus ever needs one.
if [ -n "${GRAPHIFY_OUT:-}" ] && [ "$GRAPHIFY_OUT" != "graphify-out" ]; then
  echo "semantic-update: GRAPHIFY_OUT overrides are not supported (got '$GRAPHIFY_OUT')" >&2; exit 1
fi
OUT_DIR="$CORPUS_ROOT/graphify-out"
MERGE=(python3 "$HERE/semantic-merge.py")

# Egress first, before any copy or bank call (HIMMEL-1084 direct-eval contract:
# the same verdict, provider map and ledger an agent-typed graphify gets; the
# asserted class can only be tightened by the path classifier, so a .salus
# root denies whatever is asserted). Reroute selectors are cleared first, as
# refresh-graph-map.sh does, so the anthropic verdict is the provider reached.
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
unset CLAUDE_CODE_USE_GATEWAY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_ANTHROPIC_AWS
if [ "$SEED" -eq 0 ]; then
  bash "$REPO_ROOT/scripts/guardrails/graphify-fence.sh" --eval "$CORPUS_CLASS" "$BACKEND" "$CORPUS_ROOT" semantic-update \
    || { echo "semantic-update: egress fence refused corpus '$NAME' -- nothing copied" >&2; exit 2; }
fi

[ -f "$OUT_DIR/graph.json" ] || { echo "semantic-update: no $OUT_DIR/graph.json -- run the AST pass (ast-update.sh) first" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/graphify-semantic-$NAME-XXXXXX")"
PROMOTE_LOCK="$OUT_DIR/.promote.lock" PROMOTE_LOCK_HELD=0 PROMOTE_LOCK_TOKEN="$$-$RANDOM"
cleanup() {
  if [ "$PROMOTE_LOCK_HELD" -eq 1 ] && [ "$(cat "$PROMOTE_LOCK/owner" 2>/dev/null)" = "$PROMOTE_LOCK_TOKEN" ]; then
    rm -rf "$PROMOTE_LOCK"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Promote lock, same protocol as ast-update.sh (mkdir arbiter, owner token,
# acquired stamp). Bounded wait, then skip: the next run retries.
acquire_promote_lock() {
  local waited=0
  until mkdir "$PROMOTE_LOCK" 2>/dev/null; do
    if [ "$waited" -ge "${GRAPHIFY_SEMANTIC_LOCK_WAIT:-120}" ]; then
      echo "semantic-update: SKIPPED -- promote lock $PROMOTE_LOCK held by another graph refresh" >&2
      exit 4
    fi
    sleep 5; waited=$((waited + 5))
  done
  PROMOTE_LOCK_HELD=1
  printf '%s\n' "$PROMOTE_LOCK_TOKEN" > "$PROMOTE_LOCK/owner"
  date -u +%s > "$PROMOTE_LOCK/acquired"
}

if [ "$SEED" -eq 1 ]; then
  [ "$DRY" -eq 0 ] || { echo "semantic-update: --dry-run, not stamping the manifest"; exit 0; }
  acquire_promote_lock
  "${MERGE[@]}" seed --root "$CORPUS_ROOT" --out "$OUT_DIR"
  exit 0
fi

PLAN="$WORK/plan.json"
plan_or_noop() {
  "${MERGE[@]}" plan --root "$CORPUS_ROOT" --out "$OUT_DIR" --max-files "$MAX_FILES" --plan "$PLAN"
  read -r N_BATCH N_DELETED < <(python3 -c 'import json,sys;p=json.load(open(sys.argv[1]));print(len(p["batch"]),len(p["deleted"]))' "$PLAN")
  if [ "$N_BATCH" -eq 0 ] && [ "$N_DELETED" -eq 0 ]; then
    echo "semantic-update: corpus '$NAME' unchanged since the last semantic pass -- no-op"
    exit 0
  fi
}
plan_or_noop
[ "$DRY" -eq 0 ] || { echo "semantic-update: --dry-run, stopping before the bank and the copy"; exit 0; }
acquire_promote_lock
# Re-plan under the lock: another run may have promoted (or the corpus moved)
# while we waited, and the pre-lock plan would re-extract a stale batch.
plan_or_noop

TOKENS_IN=0 TOKENS_OUT=0 START="$(date +%s)"
SCRATCH="$WORK/corpus"
if [ "$N_BATCH" -gt 0 ]; then
  case "$BACKEND" in
    claude|claude-cli)
      # Fail-open by bank-preflight's own contract; bounded and loud like
      # refresh-graph-map.sh, so a hung or silent preflight is visible.
      _bound=()
      if command -v timeout >/dev/null 2>&1; then _bound=(timeout -k 10 120); fi
      verdict="$(CADENCE_BANK_LEG="graphmap-semantic-$NAME" ${_bound[@]+"${_bound[@]}"} bash "$REPO_ROOT/scripts/lib/bank-preflight.sh" || true)"
      if [ -z "$verdict" ]; then
        echo "semantic-update: WARN bank-preflight gave no verdict (timed out or failed) -- proceeding UNGUARDED" >&2
      fi
      if [ "$verdict" = "SKIPPED-BANK" ]; then
        echo "semantic-update: bank at/over threshold -- extraction SKIPPED for '$NAME', nothing touched" >&2
        exit 3
      fi ;;
  esac
  if [ "$BACKEND" = "claude-cli" ]; then
    # Same pins as refresh-graph-map.sh (HIMMEL-1748/1902): sonnet, low effort,
    # raised timeout, and a hook-free config dir.
    export GRAPHIFY_CLAUDE_CLI_MODEL="${GRAPHIFY_CLAUDE_CLI_MODEL-sonnet}"
    export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL-low}"
    export GRAPHIFY_API_TIMEOUT="${GRAPHIFY_API_TIMEOUT-900}"
    export GRAPHIFY_CLAUDE_CONFIG_DIR="${GRAPHIFY_CLAUDE_CONFIG_DIR:-$HOME/.claude-graphify}"
    bash "$HERE/seed-claude-config.sh" \
      || { echo "semantic-update: failed to seed the hook-free Claude config dir; refusing claude-cli extraction" >&2; exit 2; }
    export CLAUDE_CONFIG_DIR="$GRAPHIFY_CLAUDE_CONFIG_DIR"
  fi
  mkdir -p "$SCRATCH/graphify-out/cache"
  python3 - "$PLAN" "$CORPUS_ROOT" "$SCRATCH" <<'PY'
import json, os, shutil, sys
plan, src, dst = sys.argv[1:4]
for rel in json.load(open(plan))["batch"]:
    os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
    shutil.copy2(os.path.join(src, rel), os.path.join(dst, rel))
PY
  [ ! -f "$CORPUS_ROOT/.graphifyignore" ] || cp "$CORPUS_ROOT/.graphifyignore" "$SCRATCH/"
  [ ! -d "$OUT_DIR/cache/semantic" ] || cp -R "$OUT_DIR/cache/semantic" "$SCRATCH/graphify-out/cache/semantic"
  printf '%s\n' "$CORPUS_CLASS" > "$SCRATCH/.graphify-corpus"
  set +e
  graphify extract "$SCRATCH" --backend "$BACKEND" --no-cluster > "$WORK/extract.log" 2>&1
  rc=$?
  set -e
  cat "$WORK/extract.log" >&2
  [ "$rc" -eq 0 ] || { echo "semantic-update: graphify extract exited $rc -- graph and manifest untouched" >&2; exit 2; }
  read -r TOKENS_IN TOKENS_OUT < <(sed -n 's/.*tokens: \([0-9,]*\) in \/ \([0-9,]*\) out.*/\1 \2/p' "$WORK/extract.log" | tr -d , | tail -1; echo)
  : "${TOKENS_IN:=0}" "${TOKENS_OUT:=0}"
fi

"${MERGE[@]}" merge --name "$NAME" --out "$OUT_DIR" --scratch "$SCRATCH" --plan "$PLAN" \
  --runtime-s "$(( $(date +%s) - START ))" --tokens-in "$TOKENS_IN" --tokens-out "$TOKENS_OUT" \
  || { echo "semantic-update: merge failed -- the batch stays unstamped and re-extracts next run" >&2; exit 2; }
if [ -d "$SCRATCH/graphify-out/cache/semantic" ]; then
  mkdir -p "$OUT_DIR/cache/semantic"
  cp -R "$SCRATCH/graphify-out/cache/semantic/." "$OUT_DIR/cache/semantic/"
fi
python3 "$HERE/harden-graph.py" --out "$OUT_DIR" >&2 \
  || echo "semantic-update: WARN harden-graph.py failed; the merged graph stands, the next refresh re-hardens it" >&2
