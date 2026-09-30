#!/usr/bin/env bash
# scripts/ci/macos-breakage.sh -- HIMMEL-3902: the os:macos cadence breakage
# metric. macOS shell-unit runs on its own lower-frequency workflow
# (.github/workflows/macos-cadence.yml); this records, per run, which suites are
# red NOW that were green on the previous completed cadence run, so the
# operator can measure what the reduced macOS coverage costs and buys.
#
# bash 3.2-safe (the same script family runs on macOS); needs jq and, for the
# gh-facing modes, an authenticated gh.
#
#   suites-from-logs <dir>   suite relpaths of the *.log files in <dir> (the
#                            runner's FAIL_LOG_DIR; decodes its injective
#                            escape: _s -> /, _u -> _)
#   diff <prev.json> <cur.json>
#                            suites in cur.failed and not in prev.failed, one
#                            per line, sorted. A missing prev is a baseline.
#   record --run-id N --head-sha S --run-at ISO --shards-result R
#          --failed-dir D --out FILE [--prev-file F] [--shards-expected N]
#                            union every failed.txt under D, diff against F,
#                            write the run record JSON to FILE and print one
#                            markdown summary row (with header) on stdout. A
#                            red run whose failed list is empty, or that got
#                            fewer than N failed.txt files, is `infra_suspect`
#                            (a shard died before reporting: list incomplete).
#   prev-record --repo R --run-id N --dest FILE
#                            newest completed cadence run other than N that
#                            carries a macos-breakage-record artifact -> FILE;
#                            exit 1 when there is none (this run is a baseline).
#   report --repo R [--limit N]
#                            per-run breakages, then per ISO week totals, from
#                            the recorded artifacts of the last N runs (12).
set -uo pipefail

WORKFLOW="macos-cadence.yml"
ARTIFACT="macos-breakage-record"

die() { echo "macos-breakage: $*" >&2; exit 2; }

cmd_suites_from_logs() {
  local dir="${1:?suites-from-logs <dir>}"
  [ -d "$dir" ] || return 0
  # shellcheck disable=SC2012 # names are run-shell-tests' escaped suite paths (alnum + _), never odd bytes
  ls "$dir" 2>/dev/null | sed -n -e 's/\.log$//p' | sed -e 's/_s/\//g' -e 's/_u/_/g' | sort
}

cmd_diff() {
  local prev="${1:?diff <prev.json> <cur.json>}" cur="${2:?diff <prev.json> <cur.json>}"
  [ -f "$prev" ] || return 0
  jq -nr --slurpfile p "$prev" --slurpfile c "$cur" \
    '(($c[0].failed // []) - ($p[0].failed // [])) | unique | .[]'
}

cmd_record() {
  local run_id="" head_sha="" run_at="" shards_result="" failed_dir="" out="" prev_file="" expected=0
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --shards-expected) expected="${2:-0}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --head-sha) head_sha="${2:-}"; shift 2 ;;
      --run-at) run_at="${2:-}"; shift 2 ;;
      --shards-result) shards_result="${2:-}"; shift 2 ;;
      --failed-dir) failed_dir="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      --prev-file) prev_file="${2:-}"; shift 2 ;;
      *) die "record: unknown argument $1" ;;
    esac
  done
  # shellcheck disable=SC2015 # die is the intended else-branch; the tests cannot fail
  [ -n "$run_id" ] && [ -n "$head_sha" ] && [ -n "$run_at" ] && [ -n "$shards_result" ] && [ -n "$out" ] \
    || die "record: --run-id --head-sha --run-at --shards-result --out are required"

  local failed_json="[]" reported=0
  if [ -n "$failed_dir" ] && [ -d "$failed_dir" ]; then
    failed_json="$(find "$failed_dir" -name failed.txt -exec cat {} + 2>/dev/null \
      | sed '/^[[:space:]]*$/d' | sort -u | jq -R . | jq -s .)"
    reported="$(find "$failed_dir" -name failed.txt | wc -l | tr -d ' ')"
  fi

  local prev_id="null" prev_sha="null"
  if [ -n "$prev_file" ] && [ -f "$prev_file" ]; then
    prev_id="$(jq '.run_id' "$prev_file")"
    prev_sha="$(jq '.head_sha' "$prev_file")"
  fi

  jq -n --argjson run_id "$run_id" --arg head_sha "$head_sha" --arg run_at "$run_at" \
        --arg shards_result "$shards_result" --argjson failed "$failed_json" \
        --argjson prev_id "$prev_id" --argjson prev_sha "$prev_sha" \
        --argjson reported "$reported" --argjson expected "$expected" \
    '{run_id: $run_id, head_sha: $head_sha, run_at: $run_at, shards_result: $shards_result,
      failed: $failed, prev_run_id: $prev_id, prev_head_sha: $prev_sha,
      new_breakages: [],
      infra_suspect: ($shards_result != "success" and (($failed | length) == 0 or $reported < $expected))}' > "$out.tmp" \
    || die "record: building the record failed"

  local new_json
  if [ "$prev_id" != "null" ]; then
    new_json="$(cmd_diff "$prev_file" "$out.tmp" | jq -R . | jq -s .)"
  else
    new_json="[]"
  fi
  jq --argjson n "$new_json" '.new_breakages = $n' "$out.tmp" > "$out" || die "record: writing $out failed"
  rm -f "$out.tmp"

  jq -r '
    "| run | head | previous head | shards | red suites | new breakages |",
    "|---|---|---|---|---|---|",
    "| \(.run_id) | \(.head_sha[0:9]) | \(if .prev_head_sha then .prev_head_sha[0:9] else "baseline" end) | \(.shards_result)\(if .infra_suspect then " (infra suspect: red with no failed suite)" else "" end) | \(.failed | length) | \(if (.new_breakages | length) > 0 then (.new_breakages | join(", ")) else "none" end) |"' "$out"
}

# Downloads the record of one run into <dir>/record.json; rc 0 iff it exists.
fetch_record() {
  local repo="$1" id="$2" dir="$3"
  mkdir -p "$dir"
  gh run download "$id" -R "$repo" -n "$ARTIFACT" -D "$dir" >/dev/null 2>&1 && [ -f "$dir/record.json" ]
}

list_run_ids() {
  local repo="$1" limit="$2"
  gh run list --workflow "$WORKFLOW" -R "$repo" --status completed --limit "$limit" \
    --json databaseId,headSha --jq '.[].databaseId'
}

cmd_prev_record() {
  local repo="" run_id="" dest=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --dest) dest="${2:-}"; shift 2 ;;
      *) die "prev-record: unknown argument $1" ;;
    esac
  done
  # shellcheck disable=SC2015 # die is the intended else-branch; the tests cannot fail
  [ -n "$repo" ] && [ -n "$run_id" ] && [ -n "$dest" ] || die "prev-record: --repo --run-id --dest are required"
  local tmp id ids
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/macos-breakage.XXXXXX")" || die "mktemp failed"
  ids="$(list_run_ids "$repo" 30)" || { rm -rf "$tmp"; die "prev-record: gh run list failed"; }
  for id in $ids; do
    # only runs before this one: a rerun of an older run must not pick a newer predecessor
    [ "$id" -ge "$run_id" ] && continue
    # skip an incomplete predecessor: suites missing from its report would read as green
    if fetch_record "$repo" "$id" "$tmp/$id" && jq -e '.infra_suspect | not' "$tmp/$id/record.json" >/dev/null 2>&1; then
      cp "$tmp/$id/record.json" "$dest"
      rm -rf "$tmp"
      return 0
    fi
  done
  rm -rf "$tmp"
  return 1
}

cmd_report() {
  local repo="" limit=12
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --limit) limit="${2:-}"; shift 2 ;;
      *) die "report: unknown argument $1" ;;
    esac
  done
  [ -n "$repo" ] || die "report: --repo is required"
  local tmp id ids files=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/macos-breakage.XXXXXX")" || die "mktemp failed"
  ids="$(list_run_ids "$repo" "$limit")" || { rm -rf "$tmp"; die "report: gh run list failed"; }
  for id in $ids; do
    if fetch_record "$repo" "$id" "$tmp/$id"; then files="$files $tmp/$id/record.json"; fi
  done
  if [ -z "$files" ]; then
    echo "no os:macos cadence run in the last $limit has a $ARTIFACT artifact yet"
    rm -rf "$tmp"
    return 0
  fi
  # shellcheck disable=SC2086 # $files is a space-joined list of mktemp paths (no spaces)
  jq -rs '
    sort_by(.run_at) as $runs
    | ($runs[] | [ (.run_at | .[0:10]), (.run_id | tostring), (.head_sha[0:9]),
                   (if .prev_head_sha then .prev_head_sha[0:9] else "baseline" end),
                   "red=\(.failed | length)", "new=\(.new_breakages | length)",
                   (if (.new_breakages | length) > 0 then (.new_breakages | join(",")) else "-" end) ]
      | join("\t")),
      "",
      ( $runs | group_by(.run_at | fromdateiso8601 | strftime("%G-W%V"))
        | .[] | "\(.[0].run_at | fromdateiso8601 | strftime("%G-W%V"))\truns=\(length)\tnew_breakages=\(map(.new_breakages | length) | add)" )
  ' $files
  rm -rf "$tmp"
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  suites-from-logs) cmd_suites_from_logs "$@" ;;
  diff) cmd_diff "$@" ;;
  record) cmd_record "$@" ;;
  prev-record) cmd_prev_record "$@" ;;
  report) cmd_report "$@" ;;
  *) die "usage: macos-breakage.sh suites-from-logs|diff|record|prev-record|report ..." ;;
esac
