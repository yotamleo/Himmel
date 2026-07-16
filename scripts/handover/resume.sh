#!/usr/bin/env bash
# scripts/handover/resume.sh — read-only chain-resume for a handover item.
#
# Given an ID (#N | <PROJECT>-N | bare N), resolves the target repo + bucket
# from the registry (same resolution as resolve-active-item.sh), finds the
# item dir, and prints its latest session's Cold-Start Prompt (fallback:
# context.md / brief.md), then the open-bugs + latest-CR panel
# (resume-context.sh) and a stale nudge from tech-debt.md. `--list` prints
# active items for the No-ID picker (the calling command runs the prompt).
# Read-only — never mutates. Lets /handover-resume skip the 47KB handover
# SKILL.md load. HIMMEL-1038.
#
# Exit: 0 = printed; 2 = usage/hard error; 3 = graceful (no repo match in
#       registry / item not found).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mode="resume" id="" repo_root=""
while [ $# -gt 0 ]; do case "$1" in
  --list) mode="list"; shift;;
  --repo-root) [ $# -ge 2 ] || { echo "resume.sh: --repo-root needs a value" >&2; exit 2; }
               repo_root="$2"; shift 2;;   # test/override hook (mirrors resolve-active-item.sh)
  -h|--help) echo "usage: resume.sh <#N|PROJECT-N|N>   |   resume.sh --list" >&2; exit 0;;
  --*) echo "resume.sh: unknown flag '$1'" >&2; exit 2;;
  *) if [ -n "$id" ]; then echo "resume.sh: too many arguments (one ID only)" >&2; exit 2; fi
     id="$1"; shift;;
esac; done

if [ "$mode" = "resume" ] && [ -z "$id" ]; then
  echo "resume.sh: no ID given (use --list for the picker)" >&2; exit 2
fi

# --- handover root + repo/bucket resolution (mirrors resolve-active-item.sh) ---
# shellcheck source=/dev/null
. "$SCRIPT_DIR/../lib/handover-path.sh" || { echo "resume.sh: cannot source handover-path.sh" >&2; exit 2; }
root="$(handover_root)" || { echo "resume.sh: handover root unresolved" >&2; exit 2; }

if [ -z "$repo_root" ]; then
  gcd="$(git -C . rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { echo "resume.sh: not in a git repo" >&2; exit 3; }
  repo_root="$(dirname "$gcd")"
fi
canon(){ printf '%s' "$1" | tr '\134' '/' | sed 's:/*$::' | tr '[:upper:]' '[:lower:]'; }
rr_canon="$(canon "$repo_root")"

reg="${HANDOVER_REGISTRY:-$HOME/.claude/handover/registry.json}"
[ -f "$reg" ] || { echo "resume.sh: registry not found ($reg)" >&2; exit 3; }
# node exits 0 (match, prints user\tbucket\tjira), 1 (no matching repo ->
# graceful skip), or 2 (registry unreadable -> hard error). Same contract as
# resolve-active-item.sh.
meta="$(REG="$reg" RR="$rr_canon" node -e '
  const fs=require("fs"), e=process.env;
  let j; try{ j=JSON.parse(fs.readFileSync(e.REG,"utf8")); }catch(err){ console.error("resume.sh: registry parse error: "+err.message); process.exit(2); }
  const repos=(j&&j.repos)||{};
  for(const k of Object.keys(repos)){
    const p=String(repos[k].path||"").replace(/\\/g,"/").replace(/\/+$/,"").toLowerCase();
    if(p===e.RR){ process.stdout.write([repos[k].user||"",k,repos[k].jira_project||""].join("\t")); process.exit(0); }
  }
  process.exit(1);
')"; node_rc=$?
if [ "$node_rc" -eq 2 ]; then echo "resume.sh: registry unreadable ($reg)" >&2; exit 2; fi
if [ "$node_rc" -ne 0 ]; then echo "resume.sh: repo not registered ($repo_root)" >&2; exit 3; fi
user="${meta%%$'\t'*}"; rest="${meta#*$'\t'}"; bucket="${rest%%$'\t'*}"; jira="${rest#*$'\t'}"
[ -n "$jira" ] || jira="$bucket"
jira_uc="$(printf '%s' "$jira" | tr '[:lower:]' '[:upper:]')"

state_root="$root/$user"
base="$state_root/$bucket"
[ -d "$base" ] || base="$state_root"     # no-bucket (flat) fallback

# --- helpers ---
item_status(){ grep -m1 '^\*\*Status:\*\*' "$1" 2>/dev/null | sed 's/^\*\*Status:\*\*[[:space:]]*//'; }
is_active(){ case "$1" in not-started|in-progress|pending|planned|blocked) return 0;; *) return 1;; esac; }

# --- list mode (No-ID picker feed: ID<TAB>slug<TAB>status<TAB>type per line) ---
if [ "$mode" = "list" ]; then
  printed=0
  emit(){ # $1=dir $2=primary-file $3=type
    local d="$1" f="$2" t="$3" bn st id2 slug
    [ -d "$d" ] || return 0
    [ -f "$d/$f" ] || return 0
    st="$(item_status "$d/$f")"
    is_active "$st" || return 0
    bn="$(basename "$d")"
    id2="$(printf '%s' "$bn" | sed -n "s/^\(#\{0,1\}${jira_uc}-[0-9]\{1,\}\|#[0-9]\{1,\}\).*/\1/p")"
    [ -n "$id2" ] || id2="$bn"
    slug="${bn#"$id2"-}"
    printf '%s\t%s\t%s\t%s\n' "$id2" "$slug" "$st" "$t"
    printed=$((printed+1))
  }
  for d in "$base"/epics/*/;         do emit "$d" master-plan.md epic; done
  for d in "$base"/standalones/*/;   do emit "$d" brief.md standalone; done
  for d in "$base"/epics/*/tasks/*/; do emit "$d" brief.md task; done
  [ "$printed" -gt 0 ] || echo "resume.sh: no active items in $bucket" >&2
  exit 0
fi

# --- resume mode: normalize ID -> scan forms ---
raw="${id#\#}"                            # strip a leading #
if printf '%s' "$raw" | grep -qiE '^[A-Za-z][A-Za-z0-9-]*-[0-9]+$'; then
  # PROJECT-K form (incl. multi-part keys like LUNA-BRAIN-5) -> key namespace only
  # (charset-bounded: alnum + hyphen only — no shell metacharacters reach the globs)
  key="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"
  forms=("$key")
elif printf '%s' "$raw" | grep -qE '^[0-9]+$'; then
  # bare numeric -> both <JIRA>-N and #N namespaces (routing.md v2 rule)
  forms=("${jira_uc}-${raw}" "#${raw}")
else
  echo "resume.sh: invalid ID '$id' (want #N, ${jira_uc}-N, or a bare number)" >&2
  exit 2
fi

# --- scan for the item dir (standalone, epic, epic-task; first match wins) ---
item_dir="" item_file=""
for form in "${forms[@]}"; do
  for pair in "standalones|brief.md" "epics|master-plan.md"; do
    sub="${pair%%|*}"; pf="${pair#*|}"
    for d in "$base/$sub/$form-"*/; do
      [ -d "$d" ] || continue
      item_dir="${d%/}"; item_file="$pf"; break 3
    done
  done
  for d in "$base"/epics/*/tasks/"$form-"*/; do
    [ -d "$d" ] || continue
    item_dir="${d%/}"; item_file="brief.md"; break 2
  done
done

if [ -z "$item_dir" ]; then
  echo "resume.sh: no item with ID '$id' found in bucket '$bucket'" >&2
  exit 3
fi

# --- latest next-session-*.md -> Cold-Start Prompt block (trimmed) ---
# Highest N by numeric compare (portable — no ls / no `sort -V`).
latest="" latest_n=-1
for f in "$item_dir"/next-session-*.md; do
  [ -f "$f" ] || continue
  n="${f##*/next-session-}"; n="${n%.md}"
  case "$n" in ''|*[!0-9]*) continue;; esac
  [ "$n" -gt "$latest_n" ] && { latest_n="$n"; latest="$f"; }
done
printf 'Cold-start prompt for %s (repo: %s):\n\n' "$id" "$bucket"
if [ -n "$latest" ]; then
  block="$(awk '
    /^## Cold-Start Prompt[[:space:]]*$/ { inb=1; next }
    inb && /^## / { inb=0 }
    inb { L[++n]=$0 }
    END {
      for(i=1;i<=n;i++) if(L[i] ~ /[^[:space:]]/){ if(!f)f=i; l=i }
      for(i=f;i<=l;i++) print L[i]
    }
  ' "$latest")"
  if [ -n "$block" ]; then
    printf '%s\n' "$block"
  else
    printf '(latest session %s has no Cold-Start Prompt block — showing %s)\n\n' "$(basename "$latest")" "$item_file"
    cat "$item_dir/$item_file"
  fi
else
  printf '(no session file yet for %s — showing %s)\n\n' "$id" "$item_file"
  cat "$item_dir/$item_file"
fi

# --- open bugs + latest CR findings panel (prints nothing when clean) ---
panel="$(bash "$SCRIPT_DIR/resume-context.sh" --item "$item_dir" 2>/dev/null)"
[ -n "$panel" ] && printf '\n%s\n' "$panel"

# --- stale nudge (top-3 lingering/zombie bullets from tech-debt.md) ---
td="$state_root/tech-debt.md"
if [ -f "$td" ]; then
  nudge="$(awk '
    /^## (Lingering|Zombie)/ { sec=1; next }
    /^## / && sec && $0 !~ /^## (Lingering|Zombie)/ { sec=0 }
    sec && /^- / && $0 !~ /\(none\)/ { print }
  ' "$td" | head -n3)"
  if [ -n "$nudge" ]; then
    printf '\nStale items worth a glance before continuing:\n%s\n\nFull triage: /handover hygiene\n' "$nudge"
  fi
fi
