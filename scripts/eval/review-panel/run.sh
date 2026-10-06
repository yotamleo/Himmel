#!/usr/bin/env bash
# scripts/eval/review-panel/run.sh - one review-panel recall sweep (HIMMEL-4649).
# Lints the fixture set, feeds each frozen diff to critic-panel.sh on stdin from
# an empty scratch dir outside any git checkout (the critic sees the diff and
# nothing else: never the key, never this repo), then scores the outputs with
# score.py and appends one eval-runs row.
#
# usage: run.sh --out <dir> [--fixtures <dir>] [--key <file>] [--tiers <t>]
#               [--critics a,b] [--only case-01,...] [--meta-json <json>]
#               [--ledger <path> | --no-ledger]
#   --tiers    CRITIC_PANEL_TIERS for the panel (default paid: the codex row).
#   --critics  critic slugs to report even when they file nothing (default:
#              the critics.json rows in --tiers).
# Env: REVIEW_PANEL_CMD (default scripts/cr/critic-panel.sh; the test seam),
#      REVIEW_PANEL_SCRATCH (default a fresh mktemp -d).
# Exit: 0 scored; 2 usage, refused lint or bad dirs; else score.py's exit.
# Draws codex bank per fixture: the console runs it, never a test (README).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="${REVIEW_PANEL_CMD:-$HERE/../../cr/critic-panel.sh}"
fixtures="$HERE/fixtures"; key="$HERE/key/seeds.json"
out=""; tiers="paid"; critics=""; only=""; meta="{}"; ledger_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="${2:-}"; shift 2 ;;
        --fixtures) fixtures="${2:-}"; shift 2 ;;
        --key) key="${2:-}"; shift 2 ;;
        --tiers) tiers="${2:-}"; shift 2 ;;
        --critics) critics="${2:-}"; shift 2 ;;
        --only) only="${2:-}"; shift 2 ;;
        --meta-json) meta="${2:-}"; shift 2 ;;
        --ledger) ledger_args=(--ledger "${2:-}"); shift 2 ;;
        --no-ledger) ledger_args=(--no-ledger); shift ;;
        *) echo "run.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$out" ] || { echo "run.sh: --out <dir> is required" >&2; exit 2; }
if [ ! -d "$fixtures" ] || [ ! -f "$key" ]; then
    echo "run.sh: no fixtures dir or key" >&2
    exit 2
fi

if ! python3 "$HERE/score.py" lint --fixtures "$fixtures" --key "$key"; then
    echo "run.sh: fixture lint failed - no panel call made" >&2
    exit 2
fi

if [ -z "$critics" ]; then
    critics="$(python3 -c 'import json,sys
tiers=set(sys.argv[2].split(","))
print(",".join(r["slug"] for r in json.load(open(sys.argv[1]))["panel"] if r.get("tier") in tiers))' \
        "$HERE/../../cr/critics.json" "$tiers")" || critics=""
fi

mkdir -p "$out" || exit 2
out="$(cd "$out" && pwd)"
scratch="${REVIEW_PANEL_SCRATCH:-}"
if [ -z "$scratch" ]; then
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/review-panel.XXXXXX")" || exit 2
fi
mkdir -p "$scratch" || exit 2

for patch in "$fixtures"/case-*.patch; do
    [ -e "$patch" ] || continue
    cid="$(basename "$patch" .patch)"
    if [ -n "$only" ]; then
        case ",$only," in *",$cid,"*) ;; *) continue ;; esac
    fi
    dir="$scratch/$cid"
    rm -rf "$dir" && mkdir -p "$dir" || exit 2
    cp "$patch" "$dir/diff.patch" || exit 2
    echo "run.sh: $cid" >&2
    # The panel reads its tier set from CRITIC_PANEL_TIERS only when CR_PROFILE
    # is unset; the triviality gate would skip the paid tier on a small diff,
    # and known-findings would inject himmel's own dispositions into the prompt.
    (cd "$dir" && env -u CR_PROFILE CRITIC_PANEL_TIERS="$tiers" CR_TRIVIALITY_OVERRIDE=full \
        CRITIC_KNOWN_FINDINGS=0 bash "$PANEL" < diff.patch > "$out/$cid.md" 2> "$out/$cid.err")
    echo "$?" > "$out/$cid.rc"
done

python3 "$HERE/score.py" score --outputs "$out" --fixtures "$fixtures" --key "$key" \
    --critics "$critics" ${only:+--only "$only"} --meta-json "$meta" \
    --json "$out/scores.json" ${ledger_args[@]+"${ledger_args[@]}"}
