#!/usr/bin/env bash
# scripts/handover/append-cr-bugs.sh — CR->bug-tracker bridge (HIMMEL-446).
#
# Bridges /pr-check panel findings into the active item's bugs.md so the CR
# fix-loop has an open->resolved lifecycle (the F1 ledger is machine telemetry;
# reviewer-notes.md is the human trail; THIS gives findings tracked state).
#
# Inputs (files, NOT shell vars — /pr-check fences run independently, so 4.7
# re-resolves its own item dir and writes temp files rather than leaning on 4.6):
#   --bugs <path>        the active item's bugs.md (bug.sh target)
#   --findings <path>    Critical/Important findings: "<finding-id>\t<severity>\t<symptom>" per line
#   --avail <path>       panel availability: "<slug>\tok|unavailable" per line
#
# Per finding: open (new) / reopen (matched bug is resolved = regression) / skip
# (matched bug already open|fixing). Per open bug whose finding-id is ABSENT this
# run: resolve ONLY if its critic slug is `ok` in --avail (a flaky critic drop
# must not falsely resolve a still-open bug — the F-D guard). The critic slug is
# the finding-id with its trailing -<integer> stripped (gptoss-3 -> gptoss);
# critic slugs never end in -<digits> (pr-check.md registry contract).
#
# Best-effort: all errors to stderr, ALWAYS exit 0 — never block the /pr-check gate.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; BUG="$HERE/bug.sh"
TAB="$(printf '\t')"

bugs="" findings="" avail=""
while [ $# -gt 0 ]; do case "$1" in
  --bugs) bugs="$2"; shift 2;; --findings) findings="$2"; shift 2;;
  --avail) avail="$2"; shift 2;;
  *) echo "append-cr-bugs: unknown arg $1" >&2; exit 0;;
esac; done
{ [ -n "$bugs" ] && [ -f "$findings" ]; } || { echo "append-cr-bugs: need --bugs + an existing --findings file" >&2; exit 0; }

slug_of(){ printf '%s' "${1%-*}"; }   # gptoss-3 -> gptoss

# avail_ok <slug> → rc 0 if the slug is marked `ok` in the availability file.
avail_ok(){
  [ -n "$avail" ] && [ -f "$avail" ] || return 1
  awk -F'\t' -v s="$1" '$1==s && $2=="ok"{f=1} END{exit !f}' "$avail"
}

# 1) Open / reopen each current finding.
present=""
while IFS="$(printf '\t')" read -r fid sev sym || [ -n "$fid" ]; do
  [ -n "$fid" ] || continue
  present="$present $fid"
  match="$(bash "$BUG" find --bugs "$bugs" --finding-id "$fid" 2>/dev/null || true)"
  if [ -z "$match" ]; then
    bash "$BUG" add --bugs "$bugs" --symptom "${sym:-$fid ($sev)}" --finding-id "$fid" >/dev/null 2>&1 || true
  else
    bn="${match%%"$TAB"*}"; st="${match#*"$TAB"}"
    [ "$st" = "resolved" ] && { bash "$BUG" status --bugs "$bugs" --id "$bn" --to open >/dev/null 2>&1 || true; }
  fi
done < "$findings"

# 2) Resolve open bugs whose finding-id is ABSENT this run AND whose critic is available.
[ -f "$bugs" ] || exit 0
# Real finding-ids are ASCII <slug>-<int>; the placeholder bullet value is a
# non-ASCII em-dash, so this ASCII class naturally excludes it (and keeps this
# source file ASCII-only — a literal em-dash breaks shellcheck output on Windows).
{ grep -oE '^- \*\*CR finding:\*\* [A-Za-z0-9._-]+$' "$bugs" 2>/dev/null || true; } | awk '{print $NF}' | sort -u | while read -r fid; do
  [ -n "$fid" ] || continue
  case " $present " in *" $fid "*) continue;; esac        # still present -> leave
  m="$(bash "$BUG" find --bugs "$bugs" --finding-id "$fid" 2>/dev/null || true)"
  [ -n "$m" ] || continue
  bn="${m%%"$TAB"*}"; st="${m#*"$TAB"}"
  { [ "$st" = "open" ] || [ "$st" = "fixing" ]; } || continue
  if avail_ok "$(slug_of "$fid")"; then
    bash "$BUG" status --bugs "$bugs" --id "$bn" --to resolved >/dev/null 2>&1 || true
  fi                                                       # critic unavailable → leave open (F-D)
done

exit 0
