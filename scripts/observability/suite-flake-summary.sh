#!/usr/bin/env bash
# scripts/observability/suite-flake-summary.sh — HIMMEL-5131: read the suite-flake
# ledger scripts/ci/run-shell-tests.sh appends to (HIMMEL-5116) and summarise this
# repo's FLAKE rows. Used by console-kit tick.sh (flakes=) and board.mjs.
#
#   suite-flake-summary.sh [--since <epoch> | --days <n>] [--now <epoch>]
#                          [--format tick|counts|detail]
#
#   tick    none | <rows>/<suites>@<top-suite>*<k>   (? when the ledger or jq is unreadable)
#   counts  one "<n><TAB><suite>" per suite, most-flaked first (? when unreadable)
#   detail  one "<suite><TAB><case><TAB><sha><TAB><run><TAB>x<n>" per row, newest
#           first, <n> = that suite's rows in the window (the repeat count)
#
# Ledger path and repo id follow the writer: SUITE_FLAKE_LEDGER, else
# $FAIL_LOG_DIR/flake-ledger.jsonl, else $HOME/.himmel/suite-flake-ledger.jsonl;
# SUITE_FLAKE_REPO_ID, else cksum of the origin URL (never the URL), else cksum of
# the checkout path. Only the last SUITE_FLAKE_TAIL_ROWS (default 2000) lines are
# read. Rows of another repo, legacy rows with no repo id, non-flake rows and
# malformed lines are skipped. Never fails: read problems print ?.
#
# ponytail: the repo-id recipe is a copy of run-shell-tests.sh's (no shared lib
# yet); test-suite-flake-summary.sh R5 fails if the two drift. Upgrade: one lib
# both source, once the id normalisation (HIMMEL-5144) lands.
set -uo pipefail

format=tick since="" days=7 now=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format) format="${2:-tick}"; shift 2 ;;
    --since) since="${2:-}"; shift 2 ;;
    --days) days="${2:-7}"; shift 2 ;;
    --now) now="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$format" in tick|counts|detail) ;; *) format=tick ;; esac
case "$now" in ''|*[!0-9]*) now=$(date +%s 2>/dev/null || echo 0) ;; esac
case "$days" in ''|*[!0-9]*) days=7 ;; esac
case "$since" in ''|*[!0-9]*) since=$(( now - 10#$days * 86400 )) ;; esac
[ "$since" -ge 0 ] 2>/dev/null || since=0

unreadable() { [ "$format" = detail ] || echo '?'; exit 0; }

command -v jq >/dev/null 2>&1 || unreadable

ledger="${SUITE_FLAKE_LEDGER:-}"
if [ -z "$ledger" ]; then
  if [ -n "${FAIL_LOG_DIR:-}" ]; then ledger="$FAIL_LOG_DIR/flake-ledger.jsonl"
  elif [ -n "${HOME:-}" ]; then ledger="$HOME/.himmel/suite-flake-ledger.jsonl"
  else unreadable; fi
fi

repo_id="${SUITE_FLAKE_REPO_ID:-}"
if [ -z "$repo_id" ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  url=$(git -C "$here" config --get remote.origin.url 2>/dev/null)
  if [ -n "$url" ]; then
    repo_id="origin-$(printf '%s' "$url" | cksum | cut -d' ' -f1)"
  else
    repo_id="dir-$(printf '%s' "$here" | cksum | cut -d' ' -f1)"
  fi
fi
repo_id=$(printf '%s' "$repo_id" | tr -c 'A-Za-z0-9._:@-' '_')

if [ ! -e "$ledger" ]; then
  [ "$format" = tick ] && echo none
  exit 0
fi
{ [ -f "$ledger" ] && [ -r "$ledger" ]; } || unreadable

tail_rows="${SUITE_FLAKE_TAIL_ROWS:-2000}"
case "$tail_rows" in ''|*[!0-9]*) tail_rows=2000 ;; esac

rows=$(tail -n "$tail_rows" "$ledger" 2>/dev/null \
  | jq -R -c --arg repo "$repo_id" --argjson since "$since" \
      'fromjson? | select(type == "object" and .kind == "flake" and .repo == $repo
         and (.ts | type) == "number" and .ts >= $since and (.suite | type) == "string")' 2>/dev/null) || unreadable

# One jq pass over the matching rows; control characters in text print as spaces
# so a TICK line or a TSV stays one line.
clean='gsub("[[:cntrl:]]"; " ")'
case "$format" in
  tick)
    printf '%s\n' "$rows" | jq -s -r "
      if length == 0 then \"none\"
      else (group_by(.suite) | map({s: .[0].suite, n: length}) | sort_by(-.n, .s)) as \$g
        | \"\(length)/\(\$g | length)@\(\$g[0].s | $clean | gsub(\" \"; \"_\"))*\(\$g[0].n)\"
      end" 2>/dev/null || echo '?'
    ;;
  counts)
    printf '%s\n' "$rows" | jq -s -r "
      group_by(.suite) | map({s: .[0].suite, n: length}) | sort_by(-.n, .s)
      | .[] | \"\(.n)\t\(.s | $clean)\"" 2>/dev/null
    ;;
  detail)
    printf '%s\n' "$rows" | jq -s -r "
      (group_by(.suite) | map({key: .[0].suite, value: length}) | from_entries) as \$c
      | sort_by(-.ts) | .[]
      | [(.suite | $clean), ((.case // \"\") | tostring | $clean), ((.sha // \"\") | tostring | $clean), ((.run // \"\") | tostring | $clean), \"x\(\$c[.suite])\"]
      | join(\"\t\")" 2>/dev/null
    ;;
esac
exit 0
