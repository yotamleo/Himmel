#!/usr/bin/env bash
# scripts/handover/append-cr-findings.sh — append one CR-panel finding into a
# handover item's reviewer-notes.md, deduped per (head,id) (HIMMEL-416 F2 / C2).
set -uo pipefail

notes="" head="" date="" pr="" id="" severity="" file="" line="" title="" verdict=""
while [ $# -gt 0 ]; do case "$1" in
  --notes) notes="$2"; shift 2;; --head) head="$2"; shift 2;;
  --date) date="$2"; shift 2;; --pr) pr="$2"; shift 2;;
  --id) id="$2"; shift 2;; --severity) severity="$2"; shift 2;;
  --file) file="$2"; shift 2;; --line) line="$2"; shift 2;;
  --title) title="$2"; shift 2;; --verdict) verdict="$2"; shift 2;;
  *) echo "append-cr-findings.sh: unknown arg $1" >&2; exit 2;;
esac; done
if [ -z "$notes" ] || [ -z "$head" ] || [ -z "$id" ]; then
  echo "append-cr-findings.sh: --notes, --head, --id required" >&2; exit 2
fi
# Seed a minimal reviewer-notes.md if the item dir exists but the file does
# not (older handover items predate the scaffolding). Refuse if the parent
# dir is absent so a bad path never creates a stray file.
if [ ! -f "$notes" ]; then
  ndir="$(dirname "$notes")"
  [ -d "$ndir" ] || { echo "append-cr-findings.sh: item dir not found ($ndir)" >&2; exit 2; }
  cat > "$notes" <<'EOF'
---
template_version: 2
---
# Reviewer Notes

## Automated Review

<!-- Claude appends /review output here with date -->

## Human Feedback

<!-- Claude captures user's chat feedback here -->
EOF
fi

marker="cr:${head}:${id}"
grep -qF "<!-- ${marker} -->" "$notes" 2>/dev/null && exit 0   # already recorded (anchored, so id prefixes don't collide)

case "$severity" in
  crit) emoji="🔴"; label="Critical";;
  imp)  emoji="🟠"; label="Important";;
  *)    emoji="🔵"; label="Suggestion";;
esac
bullet="- ${emoji} ${label} [${id}] ${file}:${line} — ${title} (${verdict}) <!-- ${marker} -->"
hdr="### ${date} — HEAD ${head}"
[ -n "$pr" ] && hdr="${hdr} (PR ${pr})"

grep -qxF "## CR Findings" "$notes" 2>/dev/null || printf '\n## CR Findings\n' >> "$notes"

if grep -qxF "$hdr" "$notes" 2>/dev/null; then
  # Insert the bullet immediately after the existing header line. Use a temp
  # file next to $notes (same filesystem -> atomic mv) created via mktemp so a
  # crash never leaves a predictable stray in the committed state dir; trap
  # cleans it up. A failed awk/mv must surface, not silently drop the finding.
  tmpf="$(mktemp "${notes}.cr.XXXXXX")" || { echo "append-cr-findings.sh: cannot create temp next to $notes" >&2; exit 2; }
  trap 'rm -f "$tmpf"' EXIT
  if ! { awk -v hdr="$hdr" -v b="$bullet" '{print} $0==hdr && !d {print b; d=1}' "$notes" > "$tmpf" && mv "$tmpf" "$notes"; }; then
    echo "append-cr-findings.sh: failed to write $notes" >&2; exit 2
  fi
else
  printf '\n%s\n%s\n' "$hdr" "$bullet" >> "$notes" || { echo "append-cr-findings.sh: failed to append $notes" >&2; exit 2; }
fi
