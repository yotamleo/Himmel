#!/usr/bin/env bash
# followup-report.sh -- per-version follow-up report (HIMMEL-4034). Read-only.
#
# Usage: followup-report.sh --version <fixVersion> [--store <usage dir>]
#                           [--project KEY] [--cap-pct N]
#
# Prints, for one fixVersion (see docs/release/follow-up-triage.md):
#   - follow-ups created/done per class (labels fu-escape, fu-hardening, fu-polish)
#   - follow-ups with no class label yet (unclassified-followups)
#   - slipped escapes (label fu-slipped): claim B's countable signal
#   - hardening share of the version's load against the cap
#   - claim A: mean CR rounds and token sums over the version's tickets, from
#     the usage records (scripts/usage/usage-read.sh, read only)
#
# Jira is read through FOLLOWUP_JIRA_CMD (default: the primary checkout's jira
# CLI); the usage store through usage-read.sh. Exit 0 report printed, 1 usage,
# 2 the Jira read failed (never an empty report).
#
# Platform guard (gitbash-only): bash 3.2-safe + jq + awk; no .ps1 twin needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=""; STORE=""; PROJECT="${JIRA_PROJECT_KEY:-HIMMEL}"; CAP=20
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --store)   STORE="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --cap-pct) CAP="${2:-}"; shift 2 ;;
    *) echo "followup-report: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$VERSION" ] || { echo "followup-report: --version is required" >&2; exit 1; }
case "$CAP" in ''|*[!0-9]*) echo "followup-report: --cap-pct must be an integer" >&2; exit 1 ;; esac
CAP=$((10#$CAP))  # a leading zero (08, 09) must not read as octal
case "$VERSION$PROJECT" in *'"'*|*\\*) echo "followup-report: refusing a quote or backslash in --version/--project" >&2; exit 1 ;; esac

if [ -n "${FOLLOWUP_JIRA_CMD:-}" ]; then
  jira_list() { "$FOLLOWUP_JIRA_CMD" list "$@"; }
else
  # dist/ is an untracked build artifact: resolve the primary checkout, not this tree.
  PRIMARY="$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")"
  jira_list() { node "$PRIMARY/scripts/jira/dist/index.js" list "$@"; }
fi

rows="$(jira_list --jql "project = $PROJECT AND fixVersion = \"$VERSION\"" --labels --limit 1000)" || {
  echo "followup-report: the Jira read failed" >&2; exit 2; }

# key \t type \t status \t summary \t labels
counts="$(printf '%s\n' "$rows" | awk -F'\t' '
  NF >= 4 {
    n = split($5, l, ","); cls = ""; slipped = 0
    for (i = 1; i <= n; i++) {
      if (l[i] == "fu-escape") cls = "escape"
      else if (l[i] == "fu-hardening") cls = "hardening"
      else if (l[i] == "fu-polish") cls = "polish"
      if (l[i] == "fu-slipped") slipped = 1
    }
    done = ($3 == "Done")
    if (cls != "") { created[cls]++; if (done) closed[cls]++ ; if (cls == "escape" && slipped) sl++ }
    else {
      if (tolower($4) ~ /follow-up|followup|deferred|residual/) unc++
      else load++
    }
  }
  END {
    printf "escape %d %d\nhardening %d %d\npolish %d %d\n", created["escape"], closed["escape"], created["hardening"], closed["hardening"], created["polish"], closed["polish"]
    printf "unclassified-followups %d\nslipped-escapes %d\nload %d\n", unc, sl, load
  }')"

echo "followup-report version=$VERSION"
echo "class created done"
printf '%s\n' "$counts" | grep -E '^(escape|hardening|polish) '
printf '%s\n' "$counts" | grep -E '^(unclassified-followups|slipped-escapes) '

hard="$(printf '%s\n' "$counts" | awk '$1=="hardening"{print $2}')"
load="$(printf '%s\n' "$counts" | awk '$1=="load"{print $2}')"
pct=0
if [ "$load" -gt 0 ]; then pct=$(( hard * 100 / load )); elif [ "$hard" -gt 0 ]; then pct=100; fi
# Cross-multiplied, so a truncated percentage never hides a share just over the cap.
status=ok
if [ $(( hard * 100 )) -gt $(( CAP * load )) ]; then status=OVER; fi
n_rows="$(printf '%s\n' "$rows" | awk -F'\t' 'NF >= 4' | wc -l | tr -d ' ')"
[ "$n_rows" -lt 1000 ] || echo "followup-report: WARNING the Jira read hit its 1000-row limit; counts may be incomplete" >&2
echo "hardening-share ${pct}% cap ${CAP}% ${status} (hardening ${hard} of load ${load})"

# Claim A: join the usage records to this version's tickets (read only).
keys="$(printf '%s\n' "$rows" | awk -F'\t' 'NF >= 4 {print $1}')"
usage_args=(); [ -z "$STORE" ] || usage_args=(--store "$STORE")
if ! recs="$(bash "$HERE/../usage/usage-read.sh" ${usage_args[@]+"${usage_args[@]}"} 2>/dev/null)"; then
  echo "claim-A unavailable (no usage store; run scripts/usage/usage-compute.sh)"
  exit 0
fi
printf '%s\n' "$recs" | jq -rs --arg keys "$keys" '
  ($keys | split("\n")) as $k
  | [.[] | select(.ticket as $t | $k | index($t))] as $r
  | def s(f): [$r[] | f] | add // 0;
    "claim-A usage-tickets \($r | length) mean-rounds \(if ($r|length) > 0 then (s(.cr.rounds // 0) / ($r|length)) else 0 end)",
    "claim-A tokens input \(s([.totals[]?.input // 0] | add)) output \(s([.totals[]?.output // 0] | add)) cache_create \(s([.totals[]?.cache_create // 0] | add)) cache_read \(s([.totals[]?.cache_read // 0] | add))"'
