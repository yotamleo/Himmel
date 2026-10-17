#!/usr/bin/env bash
# scripts/ci/fork-drift-issue.sh — maintain ONE consolidated upstream-drift
# tracking issue from the nightly fork-drift workflow.
#
# The drift guard (scripts/check-plugin-drift.sh) reports via an EXIT CODE:
#   0 = every tracked upstream CURRENT
#   2 = DRIFT (at least one fork/pin is behind upstream)
#   3 = INCOMPLETE (a check could not complete — expected in CI, where the
#       probe/checkout registry entries have no local install)
# This script turns that code into issue state, refreshing a single issue in
# place (keyed by the `fork-drift` label) rather than opening a new one per run:
#   rc 2 -> open the issue if absent, else refresh its body + add a "still
#           drifting" comment.
#   rc 0 -> if an issue is open, comment "cleared" and close it.
#   rc 3 (or anything else) -> leave existing issue state untouched (an
#           incomplete run must never open OR close — it proved nothing).
#
# Usage:  fork-drift-issue.sh <guard-exit-code> <report-file>
# Env:
#   GH_TOKEN / GITHUB_TOKEN  gh auth (issues:write) — supplied by the workflow.
#   DRIFT_ISSUE_LABEL        marker label (default: fork-drift).
#   DRIFT_ISSUE_TITLE        issue title (default below) — stable across runs.
#   DRY_RUN=1                print the gh commands instead of running them
#                            (used by the test harness; no network, no auth).
set -uo pipefail

RC="${1:-}"
REPORT="${2:-}"
LABEL="${DRIFT_ISSUE_LABEL:-fork-drift}"
TITLE="${DRIFT_ISSUE_TITLE:-Upstream fork drift detected (nightly fork-drift)}"

if [ -z "$RC" ] || [ -z "$REPORT" ]; then
  echo "usage: fork-drift-issue.sh <guard-exit-code> <report-file>" >&2
  exit 2
fi
if [ ! -f "$REPORT" ]; then
  echo "fork-drift-issue: report file not found: $REPORT" >&2
  exit 2
fi

# DRY_RUN prints the command instead of executing — lets the test harness
# assert behaviour with no gh, no auth, no network.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  "$@"
}

# UTC stamp — plain `date` (this runs in CI / a shell, not a Workflow script).
now() { date -u +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "unknown-time"; }

# Newest open issue carrying the marker label. Prints the number (empty when
# there is none) on a SUCCESSFUL lookup; returns nonzero when the lookup itself
# fails (network/auth) so callers can distinguish "no issue" from "don't know" —
# a swallowed failure would let the rc=2 branch open a DUPLICATE when an issue
# already exists but the query transiently failed (breaks the one-issue contract).
find_open_issue() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    # Test hook: simulate a failed gh lookup (returns nonzero, no output).
    [ "${DRY_RUN_LOOKUP_FAIL:-0}" = "1" ] && return 1
    printf '%s' "${DRY_RUN_OPEN_ISSUE:-}"
    return 0
  fi
  local out rc
  out="$(gh issue list --label "$LABEL" --state open --limit 1 \
    --json number --jq '.[0].number // empty' 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out"
}

# Parse the guard's report into the pieces the issue body is built from
# Writes behind.tsv (name|kind|current|target|action), vendored.txt,
# other.txt (every remaining row, CURRENT included) and behind-names.txt
# (sorted — the delta key). Reads only the guard's row shapes; the guard's
# output and exit codes are unchanged.
parse_report() {
  local wd="$1" line sec="" name rest detail cur tgt kind action files
  local re_arrow='([^ ]+) -> ([^ )]+)'
  local re_tag='latest tag ([^;]+); (fork synced to|installed) ([^ ]+)'
  local re_latest='latest ([^ )]+)'
  local re_fork='fork-behind upstream=([^ ]+) behind=([0-9]+) ahead=([0-9]+) action=(.+)\)$'
  : > "$wd/behind.tsv"; : > "$wd/vendored.txt"; : > "$wd/other.txt"
  while IFS= read -r line; do
    case "$line" in
      "== pinned remotes"*) sec=remote; continue ;;
      "== vendored forks"*) sec=vendored; continue ;;
      "== carried upstreams"*) sec=carried; continue ;;
      "== pinned tools"*) sec=pins; continue ;;
      "=="*) sec=""; continue ;;
      "  "*) ;;
      *) continue ;;
    esac
    rest="${line#  }"
    if [[ "$rest" == *": VENDORED"* ]]; then
      printf -- '- %s\n' "$rest" >> "$wd/vendored.txt"
    elif [[ "$rest" == *": BEHIND"* ]]; then
      detail="${rest#*: BEHIND}"
      if [[ "$detail" =~ $re_fork ]]; then
        name="${rest%%: *}"
        tgt="${BASH_REMATCH[1]}"
        cur="behind=${BASH_REMATCH[2]} ahead=${BASH_REMATCH[3]}"
        action="${BASH_REMATCH[4]}"
        printf '%s|fork-behind|%s|%s|%s\n' "$name" "$cur" "$tgt" "$action" >> "$wd/behind.tsv"
        continue
      fi
      cur="?"; tgt="?"
      if [[ "$detail" =~ $re_arrow ]]; then
        cur="${BASH_REMATCH[1]}"; tgt="${BASH_REMATCH[2]}"
      elif [[ "$detail" =~ $re_tag ]]; then
        tgt="${BASH_REMATCH[1]}"; cur="${BASH_REMATCH[3]}"
      elif [[ "$detail" =~ $re_latest ]]; then
        tgt="${BASH_REMATCH[1]}"
      fi
      if [ "$sec" = pins ]; then
        name="${rest%% *}"
        rest="${rest#"$name" }"
        cur="${rest%% *}"
        files="${rest#*\(}"; files="${files%%)*}"
        case "$name" in
          gh:*) case "$files" in *.pre-commit-config.yaml*) kind="pre-commit rev" ;; *) kind="action" ;; esac ;;
          pypi:*) kind="pypi package" ;;
          *) kind="npm package" ;;
        esac
        action="bump $files to $tgt plus synced_base in scripts/upstreams.json"
      else
        name="${rest%%: *}"
        case "$sec" in
          remote) case "$detail" in
                    *"re-sync fork"*) kind="skill fork"; action="/fork-resync $name" ;;
                    *) kind="upstream pin"; action="bump the marketplace.json sha pin to $tgt" ;;
                  esac ;;
          vendored) kind="vendored fork"; action="/fork-resync $name" ;;
          *) kind="carried tool"
             case "$detail" in
               *"re-sync fork"*) action="/fork-resync $name" ;;
               *) action="station tool: VM-first upgrade" ;;
             esac ;;
        esac
      fi
      printf '%s|%s|%s|%s|%s\n' "$name" "$kind" "$cur" "$tgt" "$action" >> "$wd/behind.tsv"
    else
      printf '%s\n' "$line" >> "$wd/other.txt"
    fi
  done < "$REPORT"
  cut -d'|' -f1 "$wd/behind.tsv" | LC_ALL=C sort > "$wd/behind-names.txt"
}

build_body() {
  local body_file="$1" wd="$2" n m names
  n="$(wc -l < "$wd/behind.tsv" | tr -d ' ')"
  m="$(wc -l < "$wd/other.txt" | tr -d ' ')"
  names="$(paste -sd, "$wd/behind-names.txt")"
  {
    echo "### Needs update ($n)"
    echo ""
    if [ "$n" -gt 0 ]; then
      echo "| Name | Kind | Current pin | Target | Action |"
      echo "|---|---|---|---|---|"
      while IFS='|' read -r a b c d e; do
        echo "| $a | $b | $c | $d | $e |"
      done < "$wd/behind.tsv"
    else
      echo "Nothing is BEHIND upstream in this run."
    fi
    echo ""
    if [ -s "$wd/vendored.txt" ]; then
      echo "### Vendored (upstream-owned pins) — no action unless upstream advances"
      echo ""
      cat "$wd/vendored.txt"
      echo ""
    fi
    echo "<details>"
    echo "<summary>Current and other rows ($m)</summary>"
    echo ""
    echo '```'
    cat "$wd/other.txt"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
    echo "_Maintained in place by the nightly \`fork-drift\` workflow (HIMMEL-1046); auto-closed when drift clears. Last drift detected: $(now)._"
    echo ""
    echo "To resolve: run the action in each row, then this issue closes on the next nightly run."
    echo ""
    echo "<!-- fork-drift-behind: $names -->"
  } > "$body_file"
}

# Previous run's BEHIND names, read from the marker in the open issue's body.
old_body() {
  if [ "${DRY_RUN:-0}" = "1" ]; then printf '%s' "${DRY_RUN_OLD_BODY:-}"; return 0; fi
  gh issue view "$1" --json body --jq .body 2>/dev/null
}

# One-line per-run comment: count plus what changed since the last run.
delta_comment() {
  local num="$1" wd="$2" n added cleared d prev
  n="$(wc -l < "$wd/behind.tsv" | tr -d ' ')"
  if ! prev="$(old_body "$num")"; then
    printf 'Still drifting: %s items (change since last run unavailable)' "$n"
    return 0
  fi
  printf '%s\n' "$prev" | sed -n 's/.*<!-- fork-drift-behind: \(.*\) -->.*/\1/p' | head -1 | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort > "$wd/old-names.txt"
  added="$(LC_ALL=C comm -13 "$wd/old-names.txt" "$wd/behind-names.txt" | paste -sd, - | sed 's/,/, /g')"
  cleared="$(LC_ALL=C comm -23 "$wd/old-names.txt" "$wd/behind-names.txt" | paste -sd, - | sed 's/,/, /g')"
  if [ -z "$added" ] && [ -z "$cleared" ]; then d="no change"
  elif [ -n "$added" ] && [ -n "$cleared" ]; then d="+$added; -$cleared"
  elif [ -n "$added" ]; then d="+$added"
  else d="-$cleared"; fi
  printf 'Still drifting: %s items (%s since last run)' "$n" "$d"
}

case "$RC" in
  2)
    # A failed lookup (not "no issue") must NOT fall through to `gh issue create`
    # — that would open a duplicate when an issue already exists. Bail loudly; the
    # workflow step goes red so the transient failure is visible, and the next
    # nightly retries.
    if ! num="$(find_open_issue)"; then
      echo "fork-drift: could not query existing issues (gh lookup failed) — not creating/refreshing to avoid a duplicate. Retrying next run." >&2
      exit 1
    fi
    # Propagate EVERY mutation failure (mut=1) so a failed create/edit turns the
    # workflow step RED — a silent green run that failed to open the drift issue
    # would hide real drift. Cleanup runs before the exit either way.
    mut=0
    # Ensure the marker label exists (idempotent). --force updates an existing
    # label rather than erroring, so a re-run never fails here.
    run gh label create "$LABEL" --color B60205 \
        --description "Nightly upstream fork-drift tracking (HIMMEL-1046)" --force || mut=1
    body_file="$(mktemp)" || exit 1; wd="$(mktemp -d)" || exit 1
    parse_report "$wd"
    build_body "$body_file" "$wd"
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "DRY-BODY-BEGIN"; cat "$body_file"; echo "DRY-BODY-END"
    fi
    if [ -n "$num" ]; then
      echo "fork-drift: refreshing existing issue #$num"
      # Read the previous body (its marker) before the edit overwrites it.
      comment="$(delta_comment "$num" "$wd")"
      run gh issue edit "$num" --body-file "$body_file" || mut=1
      run gh issue comment "$num" --body "$comment" || mut=1
    else
      echo "fork-drift: opening new consolidated drift issue"
      run gh issue create --title "$TITLE" --label "$LABEL" --body-file "$body_file" || mut=1
    fi
    rm -rf "$body_file" "$wd"
    if [ "$mut" -ne 0 ]; then
      echo "fork-drift: an issue mutation failed (see above) — failing so the drift is not silently green." >&2
      exit 1
    fi
    ;;
  0)
    # A failed lookup here means we can't verify/close a possibly-open drift
    # issue — propagate it (red) for consistency with the rc=2 path rather than
    # exiting green on an unverified reconciliation. The next run retries.
    if ! num="$(find_open_issue)"; then
      echo "fork-drift: all current, but could not query existing issues (gh lookup failed) — failing so the unresolved reconciliation is visible. Retries next run." >&2
      exit 1
    fi
    if [ -n "$num" ]; then
      echo "fork-drift: drift cleared — closing issue #$num"
      mut=0
      run gh issue comment "$num" --body "Drift cleared as of $(now) — all tracked upstreams current. Closing." || mut=1
      run gh issue close "$num" || mut=1
      if [ "$mut" -ne 0 ]; then
        echo "fork-drift: failed to close the drift issue (see above) — it will retry next run." >&2
        exit 1
      fi
    else
      echo "fork-drift: all current, no open drift issue — nothing to do."
    fi
    ;;
  3)
    # INCOMPLETE — a documented, benign steady state in CI (the probe/checkout
    # registry entries have no local install). Proved nothing about drift, so
    # leave issue state as-is and exit 0.
    echo "fork-drift: guard exit 3 (incomplete — expected in CI) — leaving issue state unchanged."
    ;;
  *)
    # Any OTHER code (1 usage error, 127 not-found, a crash) is NOT the guard's
    # documented 0/2/3 contract — the guard is broken. Fail (red) rather than
    # exit green, so a broken nightly is visible instead of silently passing.
    echo "fork-drift: guard exited $RC (unexpected — not the documented 0/2/3; crash/usage error?) — failing so a broken guard is not silently green." >&2
    exit 1
    ;;
esac
