#!/usr/bin/env bash
# shellcheck disable=SC2034
# scripts/handover/bug.sh — per-item bug tracker over one bugs.md
# (HIMMEL-416 F2 / C3). Subcommands: add | fix | status | list | find.
# Bug ids are per-item sequential (BUG-1, BUG-2, …), stable within the item.
# `--finding-id` (HIMMEL-446) tags a bug with the CR finding-id that raised it,
# so the CR->bug bridge can dedup/reopen/resolve by that id (`find` queries it).
set -uo pipefail

sub="${1:-}"; [ $# -gt 0 ] && shift
bugs="" symptom="" id="" outcome="" note="" to="" only_open="" porcelain="" finding_id=""
while [ $# -gt 0 ]; do case "$1" in
  --bugs) bugs="$2"; shift 2;; --symptom) symptom="$2"; shift 2;;
  --id) id="$2"; shift 2;; --outcome) outcome="$2"; shift 2;;
  --note) note="$2"; shift 2;; --to) to="$2"; shift 2;;
  --finding-id) finding_id="$2"; shift 2;;
  --open) only_open=1; shift;; --porcelain) porcelain=1; shift;;
  *) echo "bug.sh: unknown arg $1" >&2; exit 2;;
esac; done
[ -n "$bugs" ] || { echo "bug.sh: --bugs required" >&2; exit 2; }

seed_if_missing(){
  [ -f "$bugs" ] && return 0
  local d; d="$(dirname "$bugs")"
  [ -d "$d" ] || { echo "bug.sh: item dir not found ($d)" >&2; exit 2; }
  printf '%s\n' '---' 'template_version: 2' '---' '# Bug Log' '' > "$bugs" || { echo "bug.sh: failed to seed $bugs" >&2; exit 2; }
}

next_id(){
  local n
  n="$(grep -oE '^### BUG-[0-9]+ ' "$bugs" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -n1)"
  [ -n "$n" ] && echo $((n+1)) || echo 1
}

case "$sub" in
  add)
    [ -n "$symptom" ] || { echo "bug.sh add: --symptom required" >&2; exit 2; }
    seed_if_missing
    n="$(next_id)"
    {
      printf '\n### BUG-%s — %s <!-- status: open -->\n' "$n" "$symptom"
      printf -- '- **Symptom:** %s\n' "$symptom"
      printf -- '- **Fixes tried:**\n'
      printf -- '- **Resolution:** —\n'
      printf -- '- **CR link:** —\n'
      printf -- '- **CR finding:** %s\n' "${finding_id:-—}"
    } >> "$bugs" || { echo "bug.sh add: write failed" >&2; exit 2; }
    echo "BUG-$n"
    ;;
  fix)
    [ -n "$id" ] || { echo "bug.sh fix: --id required" >&2; exit 2; }
    case "$outcome" in FAILED|WORKED) :;; *) echo "bug.sh fix: --outcome must be FAILED|WORKED" >&2; exit 2;; esac
    [ -f "$bugs" ] || { echo "bug.sh fix: $bugs not found" >&2; exit 3; }
    n="${id#BUG-}"
    grep -qE "^### BUG-${n} — " "$bugs" || { echo "bug.sh fix: $id not found" >&2; exit 3; }
    tmpf="$(mktemp "${bugs}.bug.XXXXXX")" || { echo "bug.sh fix: cannot create temp" >&2; exit 2; }
    trap 'rm -f "$tmpf"' EXIT
    # Insert the outcome bullet right after the target bug's "Fixes tried:" line.
    # `inbug` is on only between the target heading and the next "### " heading.
    if ! (awk -v n="$n" -v line="  - ${note} → ${outcome}" '
      /^### BUG-/ { inbug = ($0 ~ ("^### BUG-" n " — ")) }
      { print }
      inbug && /^- \*\*Fixes tried:\*\*/ { print line }
    ' "$bugs" > "$tmpf" && mv "$tmpf" "$bugs"); then
      echo "bug.sh fix: write failed" >&2; exit 2
    fi
    trap - EXIT
    ;;
  status)
    [ -n "$id" ] || { echo "bug.sh status: --id required" >&2; exit 2; }
    case "$to" in open|fixing|resolved|wontfix) :;; *) echo "bug.sh status: --to must be open|fixing|resolved|wontfix" >&2; exit 2;; esac
    [ -f "$bugs" ] || { echo "bug.sh status: $bugs not found" >&2; exit 3; }
    n="${id#BUG-}"
    grep -qE "^### BUG-${n} — " "$bugs" || { echo "bug.sh status: $id not found" >&2; exit 3; }
    tmpf="$(mktemp "${bugs}.bug.XXXXXX")" || { echo "bug.sh status: cannot create temp" >&2; exit 2; }
    trap 'rm -f "$tmpf"' EXIT
    if ! (awk -v n="$n" -v to="$to" '
      $0 ~ ("^### BUG-" n " — ") { sub(/<!-- status: [a-z]+ -->/, "<!-- status: " to " -->") }
      { print }
    ' "$bugs" > "$tmpf" && mv "$tmpf" "$bugs"); then
      echo "bug.sh status: write failed" >&2; exit 2
    fi
    trap - EXIT
    ;;
  list)
    [ -f "$bugs" ] || exit 0
    awk -v only_open="$only_open" -v porc="$porcelain" '
      function flush(   show, i, s) {
        if (cur_n == "") return
        show = (only_open=="") || (cur_st=="open") || (cur_st=="fixing")
        if (show) {
          if (porc != "") {
            s=cur_sym; gsub(/\t/, " ", s)   # tabs would break the porcelain field contract
            printf "BUG-%s\t%s\t%s\t%s\n", cur_n, cur_st, cur_nf, s
          }
          else {
            printf "BUG-%s [%s] %s\n", cur_n, cur_st, cur_sym
            for (i = 0; i < nf; i++) print fixbuf[i]
          }
        }
        cur_n=""; cur_nf=0; nf=0; infixes=0
      }
      /^### BUG-[0-9]+ — / {
        flush()
        cur_nf=0
        line=$0
        cur_n=line;  sub(/^### BUG-/,"",cur_n);   sub(/ — .*/,"",cur_n)
        cur_st="open"   # default for a legacy/hand-edited heading missing the status comment
        if (line ~ /<!-- status: [a-z]+ -->/) { cur_st=line; sub(/.*<!-- status: /,"",cur_st); sub(/ -->.*/,"",cur_st) }
        cur_sym=line; sub(/^### BUG-[0-9]+ — /,"",cur_sym); sub(/ <!-- status:.*/,"",cur_sym)
        next
      }
      /^- \*\*Fixes tried:\*\*/ { infixes=1; next }
      /^### / { infixes=0 }
      infixes && /^  - / {
        cur_nf++
        f=$0; sub(/^  - /,"  ",f); fixbuf[nf++]=f
      }
      END { flush() }
    ' "$bugs"
    ;;
  find)
    # Query by CR finding-id → echo "BUG-N<TAB>status" for the FIRST bug whose
    # `**CR finding:**` bullet matches (finding-ids are unique per bugs.md by the
    # bridge's contract). Empty output if none. The em-dash placeholder is never
    # matchable (bridge always passes a real id). status comes from the bug's
    # heading comment, same source `list` uses.
    [ -n "$finding_id" ] || { echo "bug.sh find: --finding-id required" >&2; exit 2; }
    [ "$finding_id" = "—" ] && exit 0
    [ -f "$bugs" ] || exit 0
    awk -v want="$finding_id" '
      /^### BUG-[0-9]+ — / {
        id=$0; sub(/^### BUG-/,"",id); sub(/ — .*/,"",id)
        st="open"
        if ($0 ~ /<!-- status: [a-z]+ -->/) { st=$0; sub(/.*<!-- status: /,"",st); sub(/ -->.*/,"",st) }
      }
      $0 ~ ("^- \\*\\*CR finding:\\*\\* " want "$") { printf "BUG-%s\t%s\n", id, st; exit }
    ' "$bugs"
    ;;
  *) echo "bug.sh: unknown subcommand '$sub'" >&2; exit 2;;
esac
