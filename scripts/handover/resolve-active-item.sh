#!/usr/bin/env bash
# scripts/handover/resolve-active-item.sh — resolve the current branch's Jira
# ticket to its handover work-item directory (HIMMEL-416 F2 / C1).
#
# Exit: 0 = item dir printed to stdout; 3 = graceful skip (not in a git repo,
# no repo match in registry, no ticket in branch, or no matching item dir);
# 2 = hard error (handover root unresolvable, or registry unreadable/corrupt).
set -uo pipefail

cwd="." branch="" repo_root=""
while [ $# -gt 0 ]; do case "$1" in
  --branch) branch="$2"; shift 2;;
  --cwd) cwd="$2"; shift 2;;
  --repo-root) repo_root="$2"; shift 2;;
  *) echo "resolve-active-item.sh: unknown arg $1" >&2; exit 2;;
esac; done

# 1. Handover root (Mode B respects $HANDOVER_DIR).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/../lib/handover-path.sh" || { echo "resolve-active-item.sh: cannot source handover-path.sh" >&2; exit 2; }
root="$(handover_root)" || { echo "resolve-active-item.sh: handover root unresolved" >&2; exit 2; }

# 2. Repo root (parent of --git-common-dir), canonicalized for registry match.
if [ -z "$repo_root" ]; then
  gcd="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { echo "resolve-active-item.sh: not in a git repo" >&2; exit 3; }
  repo_root="$(dirname "$gcd")"
fi
canon(){ printf '%s' "$1" | tr '\134' '/' | sed 's:/*$::' | tr '[:upper:]' '[:lower:]'; }
rr_canon="$(canon "$repo_root")"

# 3. Registry lookup -> user, bucket(key), jira_project (case-insensitive path match).
reg="${HANDOVER_REGISTRY:-$HOME/.claude/handover/registry.json}"
[ -f "$reg" ] || { echo "resolve-active-item.sh: registry not found ($reg)" >&2; exit 3; }
# node exits 0 (match, prints meta), 1 (no matching repo -> graceful skip),
# or 2 (registry unreadable/corrupt -> hard error so a damaged registry is
# not silently misdiagnosed as "repo not registered"). node stderr is left
# visible so a parse error / missing node is surfaced.
meta="$(REG="$reg" RR="$rr_canon" node -e '
  const fs=require("fs"), e=process.env;
  let j; try{ j=JSON.parse(fs.readFileSync(e.REG,"utf8")); }catch(err){ console.error("resolve-active-item.sh: registry parse error: "+err.message); process.exit(2); }
  const repos=(j&&j.repos)||{};
  for(const k of Object.keys(repos)){
    const p=String(repos[k].path||"").replace(/\\/g,"/").replace(/\/+$/,"").toLowerCase();
    if(p===e.RR){ process.stdout.write([repos[k].user||"",k,repos[k].jira_project||""].join("\t")); process.exit(0); }
  }
  process.exit(1);
')"; node_rc=$?
if [ "$node_rc" -eq 2 ]; then echo "resolve-active-item.sh: registry unreadable ($reg)" >&2; exit 2; fi
if [ "$node_rc" -ne 0 ]; then echo "resolve-active-item.sh: repo not registered ($repo_root)" >&2; exit 3; fi
user="${meta%%$'\t'*}"; rest="${meta#*$'\t'}"; bucket="${rest%%$'\t'*}"; jira="${rest#*$'\t'}"
[ -n "$jira" ] || jira="$bucket"

# 4. Branch -> ticket (<JIRA>-<N>, case-insensitive). Skip if none.
[ -n "$branch" ] || branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
jira_lc="$(printf '%s' "$jira" | tr '[:upper:]' '[:lower:]')"
num="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | sed -n "s/.*${jira_lc}-\([0-9][0-9]*\).*/\1/p" | head -n1)"
[ -n "$num" ] || { echo "resolve-active-item.sh: no $jira ticket in branch '$branch'" >&2; exit 3; }
ticket="$(printf '%s' "$jira" | tr '[:lower:]' '[:upper:]')-$num"

# 5. Scan for the item dir (standalone, epic, then epic task; first match wins).
base="$root/$user/$bucket"
[ -d "$base" ] || base="$root/$user"   # no-bucket fallback
for pat in \
  "$base/standalones/$ticket-"* \
  "$base/epics/$ticket-"* \
  "$base"/epics/*/tasks/"$ticket-"* ; do
  for d in $pat; do
    [ -d "$d" ] || continue
    ( cd "$d" && pwd ); exit 0
  done
done
echo "resolve-active-item.sh: no handover item for $ticket" >&2
exit 3
