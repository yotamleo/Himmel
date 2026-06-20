#!/usr/bin/env bash
# scripts/handover/lessons-sweep.sh — proposal-only lessons sweep
# (HIMMEL-416 F2 / C6). Read-only: collects resolved/wontfix bug symptoms and
# CR-finding titles across every handover item, flags text recurring across
# >=2 items as lesson CANDIDATES, then prints a digest. Writes nothing — the
# operator promotes what's worth keeping (no auto-write to vault / CLAUDE.md).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/handover-path.sh" || { echo "lessons-sweep.sh: cannot source handover-path.sh" >&2; exit 2; }

root_override=""
while [ $# -gt 0 ]; do case "$1" in
  --root) root_override="$2"; shift 2;;
  *) echo "lessons-sweep.sh: unknown arg $1" >&2; exit 2;;
esac; done
root="${root_override:-$(handover_root)}" || { echo "lessons-sweep.sh: handover root unresolved" >&2; exit 2; }
[ -d "$root" ] || { echo "lessons-sweep.sh: handover root not found ($root)" >&2; exit 2; }

TAB="$(printf '\t')"
# norm: lowercase + whitespace-collapse — the recurrence key.
norm(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }

digest=""   # pre-formatted "- bug · …" / "- cr · …" lines
pairs=""    # "<item><TAB><key><TAB><display>" rows for recurrence detection

# Resolved/wontfix bug symptoms (via bug.sh — the single bugs.md parser).
# No 2>/dev/null on the subcalls/find: a genuine parser or permission failure must
# surface on stderr rather than read as "no lessons" (bug.sh self-guards missing files).
while IFS= read -r bf; do
  [ -n "$bf" ] || continue
  item="${bf%/bugs.md}"; label="${item#"$root"}"; label="${label#/}"
  while IFS="$TAB" read -r id st nf sym; do
    [ -n "$id" ] || continue
    case "$st" in resolved|wontfix) :;; *) continue;; esac
    : "$nf"   # nfixes unused here; symptom is the recurrence signal
    key="$(norm "$sym")"
    digest="${digest}- bug · ${label} · ${id} · ${sym}
"
    pairs="${pairs}${label}${TAB}${key}${TAB}${sym}
"
  done < <(bash "$HERE/bug.sh" list --porcelain --bugs "$bf")
done < <(find "$root" -type f -name bugs.md | LC_ALL=C sort)

# CR-finding titles: bullet "… — <title> (<verdict>) <!-- cr:… -->" under "## CR Findings".
while IFS= read -r nf2; do
  [ -n "$nf2" ] || continue
  item="${nf2%/reviewer-notes.md}"; label="${item#"$root"}"; label="${label#/}"
  while IFS= read -r title; do
    [ -n "$title" ] || continue
    key="$(norm "$title")"
    digest="${digest}- cr · ${label} · ${title}
"
    pairs="${pairs}${label}${TAB}${key}${TAB}${title}
"
  done < <(awk '
    /^## CR Findings[[:space:]]*$/ { incr=1; next }
    incr && /^## / && !/^### / { incr=0 }
    incr && /^- / {
      t=$0
      sep=" — "; ix=index(t, sep); if (ix > 0) t=substr(t, ix+length(sep))  # content after the FIRST " — "
      sub(/ \([^)]*\)[[:space:]]*<!--.*$/,"",t)    # drop " (verdict) <!-- … -->"
      print t
    }
  ' "$nf2")
done < <(find "$root" -type f -name reviewer-notes.md | LC_ALL=C sort)

# Recurring: a norm-key appearing in >=2 DISTINCT items.
recurring="$(printf '%s' "$pairs" | awk -F"$TAB" '
  NF>=3 {
    key=$2
    if (!(key SUBSEP $1 in seen)) { seen[key SUBSEP $1]=1; items[key]=items[key] (items[key]?", ":"") $1; cnt[key]++ }
    if (!(key in disp)) disp[key]=$3
  }
  END { for (k in cnt) if (cnt[k] >= 2) printf "- %s  (in: %s)\n", disp[k], items[k] }
' | LC_ALL=C sort)"

if [ -n "$recurring" ]; then
  printf '## Recurring (lesson candidates)\n%s\n\n' "$recurring"
fi
printf '## Digest\n'
if [ -z "$digest" ]; then
  printf '_No resolved bugs or CR findings yet._\n'
else
  printf '%s' "$digest"
fi
