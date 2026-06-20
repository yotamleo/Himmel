#!/usr/bin/env bash
# scripts/handover/bugs-dashboard.sh — cross-item aggregate bug dashboard
# (HIMMEL-416 F2 / C4). Read-only: walks every item's bugs.md under the
# handover root and renders a markdown table + totals. Reuses bug.sh as the
# single bugs.md parser (list --porcelain). Rows sorted by item path (groups
# epics/ before standalones/); per-item bugs stay in id order.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/handover-path.sh" || { echo "bugs-dashboard.sh: cannot source handover-path.sh" >&2; exit 2; }

only_open="" root_override=""
while [ $# -gt 0 ]; do case "$1" in
  --open) only_open=1; shift;;
  --all) only_open=""; shift;;
  --root) root_override="$2"; shift 2;;
  *) echo "bugs-dashboard.sh: unknown arg $1" >&2; exit 2;;
esac; done

root="${root_override:-$(handover_root)}" || { echo "bugs-dashboard.sh: handover root unresolved" >&2; exit 2; }
[ -d "$root" ] || { echo "bugs-dashboard.sh: handover root not found ($root)" >&2; exit 2; }

total=0 open=0 rows=""
while IFS= read -r bf; do
  [ -n "$bf" ] || continue
  item="$(dirname "$bf")"; label="${item#"$root"}"; label="${label#/}"
  # No 2>/dev/null on the bug.sh subcall or find below: bug.sh already self-guards
  # a missing file (exit 0, no output), so the only thing a redirect would hide is a
  # genuine parser/permission failure — which must surface, not read as "no bugs".
  while IFS="$(printf '\t')" read -r id st nf sym; do
    [ -n "$id" ] || continue
    total=$((total+1))
    case "$st" in open|fixing) open=$((open+1));; esac
    sym="${sym//|/\\|}"
    rows="${rows}| ${label} | ${id} | ${st} | ${sym} | ${nf} |
"
  done < <(bash "$HERE/bug.sh" list --porcelain ${only_open:+--open} --bugs "$bf")
done < <(find "$root" -type f -name bugs.md | LC_ALL=C sort)

if [ "$total" -eq 0 ]; then
  printf '_No %sbugs tracked._\n' "${only_open:+open }"
  exit 0
fi
printf '| Item | Bug | Status | Symptom | Fixes |\n'
printf '|------|-----|--------|---------|-------|\n'
printf '%s' "$rows"
printf '\n**Totals:** %d bug(s), %d open/fixing.\n' "$total" "$open"
