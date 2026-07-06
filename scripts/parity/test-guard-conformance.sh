#!/usr/bin/env bash
# Conformance test for the deny-guard x lane sub-table in
# docs/internals/lane-parity.md (WS5 Task 2, HIMMEL-654).
#
# Parses the markdown table inside the stable anchor
#   <!-- BEGIN guard-lane-conformance --> ... <!-- END guard-lane-conformance -->
# and asserts:
#   (i)  the anchor is present (FAIL LOUDLY if absent -- Task 3 and Task 6 both
#        rewrite this file, so a reformat must not silently void the parser);
#   (ii) every lane x deny-guard cell carries a valid Task-0 token:
#          tested:<path>  -> the path resolves via [ -f <path> ] from the
#                            repo root;
#          GAP            -> accepted literal;
#          pending:TaskN  -> accepted literal (N a run of digits).
#        Anything else, or an empty cell, FAILS.
#   (iii) no lane column that is "tested-green" (EVERY one of its cells is a
#        tested cell -- across the six deny-guards AND the write-authority
#        dimension row) contains any GAP or pending: cell. A consistency guard
#        against parser-classification drift. The write-authority row counts
#        toward tested-green because write-authority is the load-bearing parity
#        dimension (Task 0): a lane is fully guard-tested only once its
#        write-fence is also tested, so a column with a pending/GAP write-fence
#        cell is honestly NOT tested-green.
#
# Platform guard: Git Bash on Windows (gitbash) only. The parser relies on
# GNU sed/grep POSIX-E regex + [ -f ] over a POSIX path tree; it is NOT ported
# to native PowerShell. A test harness needs no .ps1 twin (project convention:
# a documented platform guard suffices for a test fixture).
#
# Usage:
#   bash scripts/parity/test-guard-conformance.sh [--doc <path>]
#     --doc <path>   parse a different doc (defaults to
#                    docs/internals/lane-parity.md at the repo root). Used by
#                    the negative test: a tmp copy with the anchor removed must
#                    make this script exit non-zero.
#
# Exit codes: 0 = PASS, 1 = FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOC="${REPO}/docs/internals/lane-parity.md"

while [ $# -gt 0 ]; do
    case "$1" in
        --doc)
            if [ $# -lt 2 ]; then
                echo "FAIL: --doc requires a path argument" >&2
                exit 1
            fi
            DOC="$2"
            shift 2
            ;;
        *)
            echo "FAIL: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ ! -f "$DOC" ]; then
    echo "FAIL: doc not found: $DOC" >&2
    exit 1
fi

FAIL=0
CELLS=0
TABLE="$(mktemp)"
trap 'rm -f "$TABLE"' EXIT

# --- (i) anchor presence -----------------------------------------------------
if ! grep -q '<!-- BEGIN guard-lane-conformance -->' "$DOC"; then
    echo "FAIL: anchor missing: <!-- BEGIN guard-lane-conformance --> in $DOC" >&2
    exit 1
fi
if ! grep -q '<!-- END guard-lane-conformance -->' "$DOC"; then
    echo "FAIL: anchor missing: <!-- END guard-lane-conformance --> in $DOC" >&2
    exit 1
fi

# Extract the region BETWEEN the markers (markers excluded), keep table rows.
awk '
    /<!-- BEGIN guard-lane-conformance -->/ { f = 1; next }
    /<!-- END guard-lane-conformance -->/   { f = 0 }
    f { print }
' "$DOC" | grep -E '^[[:space:]]*\|' > "$TABLE"

if [ ! -s "$TABLE" ]; then
    echo "FAIL: anchor present but contains no markdown table rows in $DOC" >&2
    exit 1
fi

# --- helpers -----------------------------------------------------------------
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Split a markdown table row into trimmed fields. Sets the global FIELDS array
# (FIELDS[0] = row label, FIELDS[1..N] = lane cells).
row_to_fields() {
    local line="$1" core raw f
    core="$(printf '%s' "$line" | sed 's/^[[:space:]]*|//; s/|[[:space:]]*$//')"
    IFS='|' read -ra raw <<< "$core"
    FIELDS=()
    for f in "${raw[@]}"; do
        FIELDS+=("$(trim "$f")")
    done
}

# Validate one lane cell. Sets globals CELL_HAS_TESTED / CELL_HAS_GAP /
# CELL_HAS_PENDING (each "1" or empty). Bumps FAIL and returns 1 on any
# validation failure. Arg 1 = cell text, arg 2 = diagnostic label.
validate_cell() {
    local cell="$1" label="$2" stripped compact path residual
    CELL_HAS_TESTED=""
    CELL_HAS_GAP=""
    CELL_HAS_PENDING=""
    stripped="$(printf '%s' "$cell" | tr -d '`')"
    compact="$(printf '%s' "$stripped" | tr -d '[:space:]')"
    if [ -z "$compact" ]; then
        echo "FAIL ${label}: empty cell" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi
    # tested:<path> -> each must resolve from the repo root.
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ ! -f "${REPO}/${path}" ]; then
            echo "FAIL ${label}: tested path does not resolve: ${path}" >&2
            FAIL=$((FAIL + 1))
            return 1
        fi
        CELL_HAS_TESTED=1
    done < <(printf '%s' "$stripped" | grep -oE 'tested:[A-Za-z0-9_./-]+' | sed 's/^tested://')
    if printf '%s' "$stripped" | grep -qE '(^|[[:space:]])GAP([[:space:]]|$)'; then
        CELL_HAS_GAP=1
    fi
    if printf '%s' "$stripped" | grep -qE 'pending:Task[0-9]+'; then
        CELL_HAS_PENDING=1
    fi
    residual="$(printf '%s' "$stripped" \
        | sed -E 's/tested:[A-Za-z0-9_./-]+//g; s/pending:Task[0-9]+//g; s/GAP//g' \
        | tr -d '[:space:]')"
    if [ -n "$residual" ]; then
        echo "FAIL ${label}: cell has unknown content: <${residual}>" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi
    return 0
}

# --- (ii)+(iii) parse rows, validate cells, track per-column state -----------
# Indexed arrays (bash 3.2-safe): LANES = column header names; COL_ALL_TESTED
# starts at 1 per column and is cleared if any cell is not a clean-tested cell;
# COL_HAS_GP is set if any cell carries GAP/pending.
LANES=()
COL_ALL_TESTED=()
COL_HAS_GP=()
header_done=0
expected_fields=0
lanecount=0

while IFS= read -r line; do
    # Skip the header separator row (only |, -, :, whitespace).
    if printf '%s' "$line" | grep -qE '^[[:space:]|:-]+$'; then
        continue
    fi
    row_to_fields "$line"
    if [ "$header_done" = 0 ]; then
        expected_fields=${#FIELDS[@]}
        lanecount=$((expected_fields - 1))
        if [ "$lanecount" -lt 1 ]; then
            echo "FAIL: header has no lane columns" >&2
            exit 1
        fi
        LANES=()
        COL_ALL_TESTED=()
        COL_HAS_GP=()
        ci=1
        while [ "$ci" -le "$lanecount" ]; do
            LANES+=("${FIELDS[$ci]}")
            COL_ALL_TESTED+=(1)
            COL_HAS_GP+=(0)
            ci=$((ci + 1))
        done
        header_done=1
        continue
    fi
    # data row
    if [ "${#FIELDS[@]}" -ne "$expected_fields" ]; then
        echo "FAIL: row has ${#FIELDS[@]} column(s), expected ${expected_fields}: ${line}" >&2
        FAIL=$((FAIL + 1))
        continue
    fi
    row_label="${FIELDS[0]}"
    ci=1
    while [ "$ci" -le "$lanecount" ]; do
        cell="${FIELDS[$ci]}"
        lane="${LANES[ci - 1]}"
        CELLS=$((CELLS + 1))
        if validate_cell "$cell" "[${row_label}] x [${lane}]"; then
            if [ "$CELL_HAS_TESTED" = 1 ] && [ "$CELL_HAS_GAP" != 1 ] && [ "$CELL_HAS_PENDING" != 1 ]; then
                : # clean-tested cell -> column stays all_tested
            else
                COL_ALL_TESTED[ci - 1]=0
            fi
            if [ "$CELL_HAS_GAP" = 1 ] || [ "$CELL_HAS_PENDING" = 1 ]; then
                COL_HAS_GP[ci - 1]=1
            fi
        fi
        ci=$((ci + 1))
    done
done < "$TABLE"

if [ "$header_done" = 0 ]; then
    echo "FAIL: no header row found in anchored table" >&2
    FAIL=$((FAIL + 1))
fi

# --- (iii) tested-green column consistency -----------------------------------
green=0
idx=0
while [ "$idx" -lt "${#LANES[@]}" ]; do
    lane="${LANES[$idx]}"
    if [ "${COL_ALL_TESTED[$idx]:-0}" = 1 ]; then
        green=$((green + 1))
        if [ "${COL_HAS_GP[$idx]:-0}" = 1 ]; then
            echo "FAIL: lane '${lane}' is tested-green but contains a GAP/pending cell" >&2
            FAIL=$((FAIL + 1))
        else
            echo "PASS lane '${lane}': tested-green (all cells tested, no GAP/pending)"
        fi
    else
        echo "ok lane '${lane}': not tested-green (has GAP/pending cell) -- allowed"
    fi
    idx=$((idx + 1))
done

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: ${FAIL} conformance failure(s)" >&2
    exit 1
fi
echo "PASS: guard-lane-conformance sub-table parsed (${CELLS} cells, ${green}/${#LANES[@]} lane column(s) tested-green)."
exit 0
