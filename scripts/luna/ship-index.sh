#!/usr/bin/env bash
# ship-index.sh — build the qmd search index LOCALLY and ship the artifact to a
# receiving machine (HIMMEL-1275).
#
# WHY: the receiver cannot BUILD its own substrate. Measured 2026-07-25, win2
# embeds at ~5 docs/min vs ~256 docs/min locally (50x), so an in-place reindex
# there was projected at ~17 HOURS and was killed mid-run. Any design that has
# the receiver run `qmd embed` over the corpus is wrong. It RECEIVES, never
# builds. Today the index and the graphify graph only reach it when a human
# remembers to copy a file; this is that transport.
#
# SHAPE: a deterministic script, like scripts/luna/qmd-reindex.sh and
# scripts/graphify/refresh-graph-map.sh — no claude session, no NUL stdin, no
# settings fragment. HIMMEL-128 does not apply.
#
# THREE PARTS, each in the place it belongs:
#   1. build     — scripts/luna/qmd-reindex.sh (HIMMEL-568). Reused, not
#                  reimplemented: the ticket says ship AFTER a successful local
#                  reindex, not on a blind clock. --no-reindex skips it.
#   2. prepare   — scripts/luna/prepare-ship-index.mjs. Consistent copy via
#                  SQLite's backup API, collection reconcile, vec0 orphan GC,
#                  VACUUM, self-check. Node because Python's stdlib sqlite3
#                  cannot load vec0 on these boxes.
#   3. receive   — scripts/luna/ship-index-remote.ps1, copied over and run
#                  THERE: daemon fence, swap, WMI-parented restart, verify,
#                  .preship reap.
#
# COLLECTION RECONCILE POLICY: ship-only-what-the-RECEIVER-configures. The
# receiver's own `qmd collection list` is the authority, so the ship can never
# create an orphan collection there. It also never silently drops one the
# receiver expects: prepare-ship-index.mjs REFUSES if the receiver asks for a
# collection the source lacks. The local index is never modified.
#
# WHY NOT INLINE THE REMOTE LOGIC: the quoting that survives Git-Bash -> ssh ->
# cmd.exe -> powershell is `ssh host 'powershell -NoProfile -Command "..."'`,
# and a nested `\"` inside that breaks cmd parsing. So anything with real logic
# goes over as a FILE and is invoked, rather than being escaped into a one-liner.
#
# GRAPH: ~/.graphify/global-graph.json rides the same transport (last hand-ported
# 2026-07-13). This moves the machine-to-machine leg ONLY — HIMMEL-1129 owns
# publishing the tracked graph, and nothing here reimplements that.
#
# Usage:
#   bash scripts/luna/ship-index.sh [--host <ssh-host>] [--no-reindex]
#       [--collections a,b] [--no-graph] [--keep-staging] [--dry-run]
#
#   --host <h>          ssh host to ship to            (default: win2)
#   --no-reindex        skip the local qmd-reindex step (ship what exists)
#   --collections a,b   override the receiver's set    (default: ask the receiver)
#   --no-graph          do not ship the graphify graph
#   --keep-staging      keep the local staging copy for inspection
#   --dry-run           print the plan; build nothing, copy nothing, change nothing
#
# Exit codes:
#   0  shipped + verified
#   1  usage / input error
#   2  local prerequisite unusable (ssh/scp/node/reindex/prepare script missing)
#   3  local reindex failed  — nothing shipped
#   4  prepare/staging failed — nothing shipped
#   5  upload failed          — receiver untouched
#   6  receiver-side failure  (see its SHIP-REMOTE output; it reports whether the
#                              index was swapped before failing)
#   7  graph leg failed       (index shipped OK — reported separately, non-fatal
#                              to the index result but a non-zero overall exit)
set -euo pipefail

HOST="win2"
DO_REINDEX=1
DO_GRAPH=1
KEEP_STAGING=0
DRY_RUN=0
COLLECTIONS=""

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REINDEX_SCRIPT="$HERE/qmd-reindex.sh"
PREPARE_SCRIPT="$HERE/prepare-ship-index.mjs"
REMOTE_SCRIPT="$HERE/ship-index-remote.ps1"

LOCAL_INDEX="${QMD_INDEX_PATH:-$HOME/.cache/qmd/index.sqlite}"
LOCAL_GRAPH="${GRAPHIFY_GRAPH_PATH:-$HOME/.graphify/global-graph.json}"
# Remote paths are DERIVED from the receiver's own profile at run time, never
# hardcoded. An absolute C:/Users/<name>/... default would (a) tie the script to
# one operator's account, so it simply would not work for anyone else, and (b)
# bake a personal home path into a file that propagates to the public repo.
# Each is overridable for a non-standard layout.
REMOTE_HOME=""                              # resolved in preflight (see below)
REMOTE_INDEX="${SHIP_REMOTE_INDEX:-}"
REMOTE_GRAPH="${SHIP_REMOTE_GRAPH:-}"
REMOTE_TMP="${SHIP_REMOTE_TMP:-}"

usage() {
    cat <<'EOF'
Usage: ship-index.sh [--host <ssh-host>] [--no-reindex] [--collections a,b]
                     [--no-graph] [--keep-staging] [--dry-run]

Build the qmd index LOCALLY and ship the artifact to a receiving machine that
is too slow to build its own (win2 embeds ~50x slower; an in-place reindex
there was measured at ~17 hours).

The receiver's own `qmd collection list` decides what is shipped, so the ship
can never create an orphan collection there; and it refuses outright if the
receiver expects a collection the source does not have.

Exit: 0 ok | 1 usage | 2 prereq | 3 reindex | 4 prepare | 5 upload
      6 receiver | 7 graph leg
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "ERR ship-index: --host requires a value" >&2; exit 1
            fi
            HOST="$2"; shift 2 ;;
        --host=*)        HOST="${1#--host=}"; shift ;;
        --collections)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "ERR ship-index: --collections requires a value" >&2; exit 1
            fi
            COLLECTIONS="$2"; shift 2 ;;
        --collections=*) COLLECTIONS="${1#--collections=}"; shift ;;
        --no-reindex)    DO_REINDEX=0; shift ;;
        --no-graph)      DO_GRAPH=0; shift ;;
        --keep-staging)  KEEP_STAGING=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "ERR ship-index: unknown arg: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done
[ -n "$HOST" ] || { echo "ERR ship-index: --host resolved to empty" >&2; exit 1; }

say() { printf 'ship-index: %s\n' "$*"; }
die() { local c="$1"; shift; printf 'ERR ship-index: %s\n' "$*" >&2; exit "$c"; }

# --- staging + cleanup -------------------------------------------------------
# The staging copy is reaped on EVERY exit path, success or failure. Stale
# pre-ship copies (365MB + 221MB) once sat on the receiver for days; the local
# side must not repeat that.
STAGING=""
# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$STAGING" ] && [ -f "$STAGING" ] && [ "$KEEP_STAGING" -eq 0 ]; then
        rm -f "$STAGING" 2>/dev/null || true
    elif [ -n "$STAGING" ] && [ -f "$STAGING" ]; then
        printf 'ship-index: staging kept at %s (--keep-staging)\n' "$STAGING"
    fi
}
trap cleanup EXIT

# --- preflight ---------------------------------------------------------------
for tool in ssh scp node; do
    command -v "$tool" >/dev/null 2>&1 || die 2 "'$tool' not on PATH (required)"
done
[ -f "$PREPARE_SCRIPT" ] || die 2 "prepare-ship-index.mjs not found at $PREPARE_SCRIPT"
[ -f "$REMOTE_SCRIPT" ]  || die 2 "ship-index-remote.ps1 not found at $REMOTE_SCRIPT"
[ "$DO_REINDEX" -eq 0 ] || [ -f "$REINDEX_SCRIPT" ] || die 2 "qmd-reindex.sh not found at $REINDEX_SCRIPT"
# The index-EXISTS check deliberately does NOT run here. On a first-ever run the
# reindex step is what CREATES the index, so demanding it up front would fail
# preflight on exactly the case the reindex exists to handle. With --no-reindex
# there is nothing that could create it, so the check applies immediately.
if [ "$DO_REINDEX" -eq 0 ] && [ ! -f "$LOCAL_INDEX" ]; then
    die 2 "local qmd index not found at $LOCAL_INDEX and --no-reindex was given (set QMD_INDEX_PATH, or drop --no-reindex to build it)"
fi

# --- receiver's collection set ----------------------------------------------
# The RECEIVER is the authority on what it carries (ship-only-what-it-configures).
# An explicit --collections overrides, for the case where the receiver's qmd is
# down and the operator knows the intended set.
# Ask the RECEIVER where its own profile is, and derive the paths from that.
# Forward slashes throughout: they are what PowerShell, scp targets and the
# receiver script all accept, and they avoid a second layer of backslash
# escaping through ssh.
resolve_remote_paths() {
    if [ -n "$REMOTE_INDEX" ] && [ -n "$REMOTE_GRAPH" ] && [ -n "$REMOTE_TMP" ]; then
        return 0   # fully overridden by the caller; nothing to resolve
    fi
    # `|| true`: under `set -o pipefail` a failing ssh makes the whole pipeline
    # fail, and `set -e` would abort the script right here with rc=1 — before the
    # explicit, explanatory die below could run. Swallow the status and let the
    # emptiness check produce the real diagnosis and exit code.
    REMOTE_HOME="$(ssh "$HOST" 'powershell -NoProfile -Command "$env:USERPROFILE"' 2>/dev/null \
        | tr -d '\r' | head -1 | sed 's|\\|/|g' || true)"
    if [ -z "$REMOTE_HOME" ]; then
        die 2 "could not resolve the remote user profile on '$HOST' (ssh or powershell unavailable there). Set SHIP_REMOTE_INDEX / SHIP_REMOTE_GRAPH / SHIP_REMOTE_TMP to override."
    fi
    REMOTE_INDEX="${REMOTE_INDEX:-$REMOTE_HOME/.cache/qmd/index.sqlite}"
    REMOTE_GRAPH="${REMOTE_GRAPH:-$REMOTE_HOME/.graphify/global-graph.json}"
    REMOTE_TMP="${REMOTE_TMP:-$REMOTE_HOME/AppData/Local/Temp}"
}

# The receiver's collection set, parsed from `qmd collection list`.
#
# Match the COLLECTION ROWS, not every line (HIMMEL-1284). The previous version
# took the first token of every line and kept anything that looked like an
# identifier — which swallowed the command's own header. `qmd collection list`
# opens with `Collections (2):`, whose first token `Collections` has no colon,
# so it passed the identifier filter cleanly and became a phantom collection.
# Every default (no --collections) ship then died in prepare-ship-index with
# "receiver expects collection(s) the SOURCE does not have: Collections" — the
# guard doing its job on a name the parser invented. That made the documented
# default invocation 100% broken for every receiver.
#
# The rows are recognisable by their `<name> (qmd://<name>/)` shape, which the
# header never has. Anchor on that instead:
#
#   Collections (2):            <- header, no (qmd:// -> skipped
#                               <- blank
#   himmel (qmd://himmel/)      <- row -> himmel
#     Pattern:  **/*.md         <- indented detail, no (qmd:// -> skipped
#
# No machine-readable mode to prefer here: checked against qmd 2.6.3 —
# `qmd collection list --json` is silently IGNORED (it prints the same prose),
# and `--format json` is a SEARCH option, not a collection-list one. So this
# stays a parser, just one anchored on the stable part of the format.
remote_collections() {
    ssh "$HOST" 'qmd collection list' 2>/dev/null \
        | sed 's/\r$//' \
        | sed -n 's/^\([A-Za-z0-9._-]\{1,\}\) (qmd:\/\/.*/\1/p' \
        | sort -u \
        | paste -sd, - || true
}

if [ "$DRY_RUN" -eq 1 ]; then
    say "DRY RUN — nothing will be built, copied, or changed"
    say "  host              : $HOST"
    say "  local index       : $LOCAL_INDEX"
    # Report the EXPLICIT override when one is set, rather than always claiming
    # the value will be derived — a dry-run that misreports its own plan is
    # worse than no dry-run. (And no backslash before the apostrophe: inside
    # double quotes `\'` is not an escape, it prints a literal backslash.)
    if [ -n "$REMOTE_INDEX" ]; then
        say "  remote index      : $REMOTE_INDEX (SHIP_REMOTE_INDEX override)"
    else
        say "  remote index      : (derived from the receiver's USERPROFILE at run time)"
    fi
    say "  reindex first     : $([ "$DO_REINDEX" -eq 1 ] && echo yes || echo no)"
    say "  ship graph        : $([ "$DO_GRAPH" -eq 1 ] && echo yes || echo no)"
    if [ -n "$COLLECTIONS" ]; then
        say "  collections       : $COLLECTIONS (explicit override)"
    else
        say "  collections       : (would query the receiver's 'qmd collection list')"
    fi
    say "  would run         : $REINDEX_SCRIPT"
    say "  would run         : node $PREPARE_SCRIPT --src $LOCAL_INDEX --out <staging> --collections <set>"
    say "  would upload      : <staging> -> $HOST:$REMOTE_TMP/qmd-index.incoming.sqlite"
    say "  would upload      : $REMOTE_SCRIPT -> $HOST:$REMOTE_TMP/ship-index-remote.ps1"
    say "  would run THERE   : ship-index-remote.ps1 (daemon fence -> swap -> WMI restart -> verify -> reap)"
    say "dry-run complete (no changes made)"
    exit 0
fi

# --- 1. build local ----------------------------------------------------------
if [ "$DO_REINDEX" -eq 1 ]; then
    say "[1/5] local reindex (qmd-reindex.sh)"
    bash "$REINDEX_SCRIPT" || die 3 "local reindex failed — NOTHING shipped (the receiver keeps its current index)"
else
    say "[1/5] local reindex SKIPPED (--no-reindex) — shipping the index as it stands"
fi
# Now the index must exist, whether it was just built or was already there.
[ -f "$LOCAL_INDEX" ] || die 3 "local qmd index still not present at $LOCAL_INDEX after the build step — NOTHING shipped"

# --- 2. resolve the receiver's collection set --------------------------------
say "[2/5] resolving the receiver's paths + collection set"
resolve_remote_paths
say "      receiver index: $REMOTE_INDEX"
if [ -z "$COLLECTIONS" ]; then
    COLLECTIONS="$(remote_collections)"
    [ -n "$COLLECTIONS" ] || die 2 \
        "could not read '$HOST' collections (ssh or qmd unavailable there). Pass --collections explicitly if you know the intended set."
    say "      receiver configures: $COLLECTIONS"
else
    say "      using explicit override: $COLLECTIONS"
fi

# --- 3. prepare the artifact -------------------------------------------------
say "[3/5] preparing the shippable artifact (reconcile + vec0 GC + VACUUM)"
STAGING="$(mktemp -t qmd-ship.XXXXXX)"
rm -f "$STAGING"
STAGING="$STAGING.sqlite"

PREP_JSON=""
PREP_JSON="$(node "$PREPARE_SCRIPT" --src "$LOCAL_INDEX" --out "$STAGING" --collections "$COLLECTIONS" --json)" \
    || die 4 "prepare-ship-index failed — NOTHING shipped"

SHIP_DOCS="$(printf '%s' "$PREP_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).after.documents))}catch{process.stdout.write("-1")}})')"
SHIP_VECS="$(printf '%s' "$PREP_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).after.vectors))}catch{process.stdout.write("-1")}})')"

# A parse failure must NOT sail through as a usable count. The receiver treats a
# NEGATIVE expectation as "skip this check", so an unparsed "-1" would silently
# DISABLE the post-swap doc/vector verification — turning the one guard against
# shipping a wrong index into a no-op, quietly. Demand plain non-negative
# integers and fail the prepare stage instead.
case "$SHIP_DOCS" in ''|*[!0-9]*) die 4 "prepare-ship-index returned an unusable document count ('$SHIP_DOCS') — refusing to ship with the post-swap verification disabled" ;; esac
case "$SHIP_VECS" in ''|*[!0-9]*) die 4 "prepare-ship-index returned an unusable vector count ('$SHIP_VECS') — refusing to ship with the post-swap verification disabled" ;; esac
say "      staged: ${SHIP_DOCS} documents / ${SHIP_VECS} vectors"

# --- 4. upload ---------------------------------------------------------------
say "[4/5] uploading to $HOST"
# PER-INVOCATION remote paths. Fixed names would have two concurrent ships
# overwriting each other's upload mid-flight — and the loser would swap in a
# file that is half the other run's index. $$ plus the epoch is enough to
# separate runs; the receiver script removes its own staged file when it swaps.
RUN_TAG="$$-$(date +%s 2>/dev/null || echo 0)"
REMOTE_STAGED="$REMOTE_TMP/qmd-index.incoming.$RUN_TAG.sqlite"
REMOTE_PS1="$REMOTE_TMP/ship-index-remote.$RUN_TAG.ps1"
scp -q "$STAGING" "$HOST:$REMOTE_STAGED" || die 5 "upload of the index failed — receiver untouched"
if ! scp -q "$REMOTE_SCRIPT" "$HOST:$REMOTE_PS1"; then
    # The INDEX upload already succeeded, so a ~400MB staged file is sitting on
    # the receiver with nothing left to consume it. Reap it rather than leaving
    # the exact stale-copy litter this transport is meant to stop producing.
    # shellcheck disable=SC2029  # client-side expansion is intended (path resolved here)
    ssh "$HOST" "cmd /c del /q \"${REMOTE_STAGED//\//\\}\"" >/dev/null 2>&1 || true
    die 5 "upload of the receiver script failed — receiver untouched (staged index reaped)"
fi

# --- 5. receive (fence -> swap -> restart -> verify -> reap) -----------------
say "[5/5] running the receiver-side swap on $HOST"
# Single-quoted OUTER, double-quoted INNER — the one quoting shape that survives
# Git-Bash -> ssh -> cmd.exe -> powershell. No nested \" anywhere.
remote_rc=0
# shellcheck disable=SC2029  # client-side expansion is INTENDED: the paths and
# counts are resolved HERE and baked into the command the receiver runs.
ssh "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File \"$REMOTE_PS1\" -Staged \"$REMOTE_STAGED\" -Target \"$REMOTE_INDEX\" -ExpectDocs $SHIP_DOCS -ExpectVectors $SHIP_VECS" || remote_rc=$?
if [ "$remote_rc" -ne 0 ]; then
    # Best-effort: do not leave this run's per-invocation artifacts behind on the
    # receiver. A failed swap already left its own state; the uploads are ours.
    # shellcheck disable=SC2029  # client-side expansion is intended (paths resolved here)
    ssh "$HOST" "cmd /c del /q \"${REMOTE_STAGED//\//\\}\" \"${REMOTE_PS1//\//\\}\"" >/dev/null 2>&1 || true
    die 6 "receiver-side ship failed (rc=$remote_rc). Its SHIP-REMOTE output above states whether the index was swapped before the failure."
fi
# On success the receiver consumed the staged index (it was MOVED into place);
# only our copy of the script needs reaping.
# shellcheck disable=SC2029  # client-side expansion is intended (path resolved here)
ssh "$HOST" "cmd /c del /q \"${REMOTE_PS1//\//\\}\"" >/dev/null 2>&1 || true

say "index shipped + verified on $HOST (${SHIP_DOCS} docs / ${SHIP_VECS} vectors)"

# --- graph leg ---------------------------------------------------------------
# Transport only. HIMMEL-1129 owns publishing the tracked graph; this never
# generates or publishes one, it moves whatever already exists.
graph_rc=0
if [ "$DO_GRAPH" -eq 1 ]; then
    if [ -f "$LOCAL_GRAPH" ]; then
        say "shipping the graphify graph ($(wc -c < "$LOCAL_GRAPH" | tr -d ' ') bytes)"
        ssh "$HOST" 'powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path $env:USERPROFILE\.graphify | Out-Null"' >/dev/null 2>&1 || true
        if scp -q "$LOCAL_GRAPH" "$HOST:$REMOTE_GRAPH"; then
            say "graph shipped"
        else
            echo "WARN ship-index: graph upload failed (the INDEX shipped fine)" >&2
            graph_rc=7
        fi
    else
        say "no local graph at $LOCAL_GRAPH — graph leg skipped"
    fi
fi

exit "$graph_rc"
