#!/usr/bin/env bash
# scripts/handover/resume-context.sh — resume panel for one handover item:
# open bugs (avoid re-trying failed fixes) + the latest CR-findings block
# (HIMMEL-416 F2 / C5). Read-only; prints nothing for a clean item.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

item=""
while [ $# -gt 0 ]; do case "$1" in
  --item) item="$2"; shift 2;;
  *) echo "resume-context.sh: unknown arg $1" >&2; exit 2;;
esac; done
[ -n "$item" ] || { echo "resume-context.sh: --item required" >&2; exit 2; }

# Open bugs (only if any).
bugs="$item/bugs.md"
if [ -f "$bugs" ]; then
  open_out="$(bash "$HERE/bug.sh" list --bugs "$bugs" --open)" || echo "resume-context.sh: bug.sh list failed, open bugs unavailable" >&2
  if [ -n "$open_out" ]; then
    printf '### Open bugs (avoid re-trying failed fixes)\n%s\n\n' "$open_out"
  fi
fi

# Pending CR markers for this item's ticket (HIMMEL-1553): re-derive the
# machine classification EVERY resume, so an inherited "blocked/unopenable"
# claim in the handover prose always sits next to what the marker + ledger
# actually say (HIMMEL-1519 stayed falsely "blocked" for four legs because the
# claim propagated leg-to-leg unchallenged). Ticket key comes from the item
# dir name (KEY-N-slug); #N items have no key and are skipped. Best-effort:
# an audit failure never breaks the panel.
key="$(basename "$item" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)"
if [ -n "$key" ] && [ -f "$HERE/../cr/cr-pending-audit.sh" ]; then
  audit_out="$(bash "$HERE/../cr/cr-pending-audit.sh" --ticket "$key" 2>/dev/null)" || true
  if [ -n "$audit_out" ]; then
    printf '### Pending CR markers (machine-classified — trust this over inherited prose)\n%s\n\n' "$audit_out"
  fi
fi

# Latest CR-findings block: the LAST "### " header under "## CR Findings" and
# its bullets (append-cr-findings.sh appends newest blocks at EOF). awk resets
# `blk` on each "### " so only the final block survives to END.
notes="$item/reviewer-notes.md"
if [ -f "$notes" ] && grep -qE '^## CR Findings[[:space:]]*$' "$notes"; then
  cr="$(awk '
    /^## CR Findings[[:space:]]*$/ { incr=1; next }
    incr && /^## / && !/^### / { incr=0 }                # left the section
    incr && /^### / { blk=$0 ORS; next }                 # new block -> reset
    incr { blk=blk $0 ORS }
    END { printf "%s", blk }
  ' "$notes")"
  if [ -n "$cr" ]; then
    printf '### Latest CR findings\n%s\n' "$cr"
  fi
fi
