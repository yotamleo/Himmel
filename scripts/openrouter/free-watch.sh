#!/usr/bin/env bash
# free-watch.sh - OpenRouter free-tier watcher (HIMMEL-846).
#
# Operator policy (2026-07-09, twice-confirmed): the $20 top-up is NEVER spent;
# it only unlocks the 1000 free-req/day tier. Panels/fallbacks pin ':free'
# model ids EXCLUSIVELY. The risk this watcher covers is free-model CHURN
# (delisting, provider/uptime changes), not the daily cap.
#
# Lean-invoke (no hook, no daemon): run it on demand. It
#   1. fetches the public catalog (GET /api/v1/models, no auth) and keeps the
#      ':free' subset,
#   2. parses the OpenRouter pins out of the CR registry (overlay
#      critics.local.json wins over shipped critics.json),
#   3. snapshots the ':free' subset to the state dir and diffs vs the previous
#      run (new / delisted free models),
#   4. checks every pin - non-free policy violation, delisted pin, deranked
#      endpoints (any status < 0; all-deranked vs partial), uptime drop,
#   5. prints SUGGEST lines for better code-capable ':free' candidates.
# It never edits any registry file - suggestions only. Suggested ids are
# structurally ':free'-only (non-free ids are filtered before any suggestion).
#
# Usage: free-watch.sh [--catalog-file f] [--endpoints-dir d] [--state-dir d]
#                      [--registry f] [--no-probe]
#   --catalog-file f   read the catalog JSON from f instead of the network
#   --endpoints-dir d  read per-model endpoint JSON fixtures from d instead of
#                      the network (filename: model id with / and : -> _)
#   --state-dir d      snapshot dir (default $HOME/.himmel)
#   --registry f       registry to read pins from (default: overlay > shipped)
#   --no-probe         skip only the per-pin endpoints probe (policy +
#                      delisted-pin checks and the catalog diff still run)
# Env: OPENROUTER_UPTIME_MIN  uptime-drop threshold percent (default 90)
# Exit: 0 = ran (flags/suggestions are advisory); 1 = fetch/parse/dep error.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
API_BASE="https://openrouter.ai/api/v1"
UPTIME_MIN="${OPENROUTER_UPTIME_MIN:-90}"
# Validate once at startup: a bad value would otherwise crash jq --argjson
# mid-loop, silently skipping the remaining pin health checks (false-healthy).
# Must be a valid JSON number for --argjson: digits with at most one INNER dot
# (".5", "5.", "." are invalid JSON and would still crash jq).
case "$UPTIME_MIN" in
  ''|*[!0-9.]*|*.*.*|.*|*.) echo "free-watch: OPENROUTER_UPTIME_MIN must be numeric, got '$UPTIME_MIN'" >&2; exit 1 ;;
esac

CATALOG_FILE="" ENDPOINTS_DIR="" STATE_DIR="${HOME}/.himmel" REGISTRY="" NO_PROBE=0
while [ $# -gt 0 ]; do
  case "$1" in
    # Value-taking flags check $# first: with set -u a bare "$2" on a missing
    # value would crash unbound instead of printing the friendly error.
    --catalog-file|--endpoints-dir|--state-dir|--registry)
      [ $# -ge 2 ] || { echo "free-watch: $1 requires a value" >&2; exit 1; }
      case "$1" in
        --catalog-file)  CATALOG_FILE="$2" ;;
        --endpoints-dir) ENDPOINTS_DIR="$2" ;;
        --state-dir)     STATE_DIR="$2" ;;
        --registry)      REGISTRY="$2" ;;
      esac
      shift 2 ;;
    --no-probe) NO_PROBE=1; shift ;;
    *) echo "free-watch: unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "free-watch: jq is required" >&2; exit 1; }

# Registry resolution mirrors critic-panel.sh (HIMMEL-727) in full:
# --registry flag > CRITICS_JSON env > overlay critics.local.json > shipped.
# Without the env tier the watcher could report health for a different
# registry than the one the panel actually runs.
if [ -z "$REGISTRY" ]; then
  if [ -n "${CRITICS_JSON:-}" ]; then
    REGISTRY="$CRITICS_JSON"
  elif [ -f "$REPO_ROOT/scripts/cr/critics.local.json" ]; then
    REGISTRY="$REPO_ROOT/scripts/cr/critics.local.json"
  else
    REGISTRY="$REPO_ROOT/scripts/cr/critics.json"
  fi
fi
[ -f "$REGISTRY" ] || { echo "free-watch: registry not found: $REGISTRY" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---- 1. catalog ------------------------------------------------------------
CATALOG="$TMP_DIR/catalog.json"
if [ -n "$CATALOG_FILE" ]; then
  cp "$CATALOG_FILE" "$CATALOG" \
    || { echo "free-watch: catalog file not readable: $CATALOG_FILE" >&2; exit 1; }
else
  curl -sf --max-time 30 "$API_BASE/models" -o "$CATALOG" \
    || { echo "free-watch: catalog fetch failed" >&2; exit 1; }
fi
# ':free'-only subset, sorted by id. This filter is the free-only policy guard:
# nothing outside it is ever diffed or suggested (a non-':free' registry pin is
# separately FLAGGED as a policy violation below, not filtered silently).
FREE="$TMP_DIR/free.json"
jq '[.data[] | select(.id | endswith(":free"))
     | {id, name, context_length}] | sort_by(.id)' "$CATALOG" > "$FREE" \
  || { echo "free-watch: catalog JSON unreadable" >&2; exit 1; }
# NB: Windows jq emits CRLF; every text-producing jq below strips \r.
FREE_COUNT="$(jq 'length' "$FREE" | tr -d '\r')"
echo "free-watch: catalog has $FREE_COUNT ':free' models"

# ---- 2. pinned models from the registry -------------------------------------
# Parsed BEFORE the snapshot is replaced so a malformed registry aborts the run
# without losing the previous snapshot (the churn diff survives a retry).
# Mirrors critic-panel.sh fallback semantics: "fallback_models" array OR legacy
# "fallback_model" string, on EVERY row - a non-OpenRouter primary can carry an
# OpenRouter fallback (the HIMMEL-729 quota-exhaustion path). OpenRouter ids
# are the author/slug form; on non-openrouter rows only those count.
jq -r '.panel[] as $r
       | [$r.model, ($r.fallback_models[]?), ($r.fallback_model // empty)]
       | if $r.provider == "openrouter" then . else map(select(contains("/"))) end
       | .[]' "$REGISTRY" \
  | tr -d '\r' | sort -u > "$TMP_DIR/pins" \
  || { echo "free-watch: registry unreadable: $REGISTRY" >&2; exit 1; }

# ---- 3. snapshot diff --------------------------------------------------------
mkdir -p "$STATE_DIR"
SNAP="$STATE_DIR/openrouter-free-catalog.json"
# A corrupt previous snapshot (killed prior run, manual edit) degrades to a
# first run instead of aborting - it would otherwise wedge EVERY later run
# until a human deletes the state file.
if [ -f "$SNAP" ] && ! jq -e 'type == "array"' "$SNAP" >/dev/null 2>&1; then
  echo "free-watch: previous snapshot unreadable ($SNAP) - treating as first run" >&2
  rm -f "$SNAP"
fi
if [ -f "$SNAP" ]; then
  jq -r '.[].id' "$SNAP" | tr -d '\r' > "$TMP_DIR/old.ids"
  jq -r '.[].id' "$FREE" | tr -d '\r' > "$TMP_DIR/new.ids"
  # LC_ALL=C: comm must collate the way jq's sort_by(.id) sorted (codepoint).
  LC_ALL=C comm -13 "$TMP_DIR/old.ids" "$TMP_DIR/new.ids" > "$TMP_DIR/added"
  LC_ALL=C comm -23 "$TMP_DIR/old.ids" "$TMP_DIR/new.ids" > "$TMP_DIR/removed"
  while IFS= read -r id; do
    [ -n "$id" ] && echo "FLAG new-free-model: $id"
  done < "$TMP_DIR/added"
  while IFS= read -r id; do
    [ -n "$id" ] && echo "FLAG delisted-free-model: $id"
  done < "$TMP_DIR/removed"
else
  echo "free-watch: first run - snapshot created, no diff"
fi
# Atomic replace: an interrupted copy must not corrupt the previous snapshot.
# The explicit guard matters: a failing non-final command in an && list is
# exempt from set -e, so an unguarded cp failure would report success ("done")
# while the snapshot silently never updates.
if ! cp "$FREE" "$SNAP.tmp" || ! mv -f "$SNAP.tmp" "$SNAP"; then
  echo "free-watch: snapshot write failed ($SNAP)" >&2; exit 1
fi

# ---- 4. pinned-model checks --------------------------------------------------
probe_endpoints() { # $1 = model id; prints endpoints JSON to stdout, or fails
  if [ -n "$ENDPOINTS_DIR" ]; then
    local fixture
    fixture="$ENDPOINTS_DIR/$(echo "$1" | tr '/:' '__').json"
    [ -f "$fixture" ] && cat "$fixture"
  else
    curl -sf --max-time 30 "$API_BASE/models/$1/endpoints"
  fi
}

while IFS= read -r pin; do
  [ -n "$pin" ] || continue
  case "$pin" in
    *:free) : ;;
    *) echo "FLAG non-free-pin: $pin (violates free-only policy - replace with a :free id)"; continue ;;
  esac
  if ! jq -e --arg id "$pin" 'any(.[]; .id == $id)' "$FREE" >/dev/null; then
    echo "FLAG delisted-pin: $pin (pinned in $(basename "$REGISTRY") but absent from the ':free' catalog)"
    continue
  fi
  [ "$NO_PROBE" -eq 1 ] && continue
  EP="$TMP_DIR/ep.json"
  if ! probe_endpoints "$pin" > "$EP" || ! jq -e '.data.endpoints' "$EP" >/dev/null 2>&1; then
    echo "FLAG probe-failed: $pin (endpoints API unreachable or unreadable)"
    continue
  fi
  # status < 0 means OpenRouter deranked/disabled the endpoint; uptime_last_30m
  # is null for some free providers (observed live 2026-07-10) - null is OK.
  if ! jq -e '.data.endpoints | length > 0' "$EP" >/dev/null; then
    echo "FLAG no-endpoints: $pin (zero live endpoints)"
    continue
  fi
  neg="$(jq -r '[.data.endpoints[] | select((.status // 0) < 0)] | length' "$EP" | tr -d '\r')"
  tot="$(jq -r '.data.endpoints | length' "$EP" | tr -d '\r')"
  if [ "$neg" -gt 0 ]; then
    if [ "$neg" -eq "$tot" ]; then
      echo "FLAG deranked-pin: $pin (all $tot endpoint(s) status < 0)"
    else
      # Partial derank = lost provider redundancy; surface before it worsens.
      echo "FLAG deranked-pin-partial: $pin ($neg of $tot endpoint(s) status < 0)"
    fi
  fi
  low="$(jq -r --argjson min "$UPTIME_MIN" \
    '[.data.endpoints[] | select(.uptime_last_30m != null and .uptime_last_30m < $min)] | length' "$EP" | tr -d '\r')"
  if [ "$low" -gt 0 ]; then
    echo "FLAG uptime-drop: $pin ($low endpoint(s) under ${UPTIME_MIN}% uptime_last_30m)"
  fi
done < "$TMP_DIR/pins"

# ---- 5. better-candidate suggestions ----------------------------------------
# Code-capable heuristic: id or name mentions code/coder. A candidate beats the
# pins when its context_length exceeds every pinned model's. Suggestions only -
# the operator edits critics.local.json (qwenor row) manually.
PINS_JSON="$(jq -R -s 'split("\n") | map(select(length > 0))' "$TMP_DIR/pins" | tr -d '\r')"
MAX_PIN_CTX="$(jq -r --argjson pins "$PINS_JSON" \
  '[.[] | select(.id as $i | $pins | index($i)) | .context_length] | max // 0' "$FREE" | tr -d '\r')"
jq -r --argjson maxctx "$MAX_PIN_CTX" '
  .[] | select((.id + " " + (.name // "")) | test("(^|[-/_ ])cod(e|er)([-/_ :]|$)"; "i"))
      | select(.context_length > $maxctx)
      | "SUGGEST qwenor-candidate: \(.id) (ctx \(.context_length) beats pinned max \($maxctx)) - consider critics.local.json"
' "$FREE" | tr -d '\r'

echo "free-watch: done (snapshot: $SNAP)"
