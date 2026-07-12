#!/usr/bin/env bash
# scripts/where-are-we/statusline-rollup.sh — detached epic-rollup refresh for the
# status line (HIMMEL-538, epic 514). NETWORK-TOUCHING; never run on the status
# line render path — the segment spawns this DETACHED + lock-gated.
#
# Resolves the ticket's parent epic (jira get --json → fields.parent.key) and
# counts Done / total children (jira list --jql passthrough — the passthrough
# OVERRIDES the default "To Do,In Progress" status filter so Done IS included).
# Writes {epic,done,total,refreshed_at} atomically to --out. A burst of renders
# triggers at most ONE refresh per key: the mkdir lock is the gate.
#
# `jira list` emits TSV (KEY \t TYPE \t STATUS-NAME \t TITLE), no --json and no
# statusCategory — so Done is matched on the literal status NAME in column 3.
# HIMMEL uses only To Do/In Progress/Done, so the literal match is exact here;
# other projects with differently-named done states would undercount (documented).
#
# CLI: statusline-rollup.sh --key KEY --out CACHE_FILE [--jira-cmd "CMD"]
# Env:  HIMMEL_WHERE_ARE_WE_ROLLUP_TTL   reaper threshold base (s, default 900)
#       HIMMEL_WHERE_ARE_WE_JIRA_TIMEOUT per-jira-call timeout (s, default 8)
# Test seam: --jira-cmd overrides the jira CLI (default the primary-checkout CLI).
set -uo pipefail

key="" out="" jira_cmd=""
while [ $# -gt 0 ]; do
    case "$1" in
        --key)      key="${2:-}"; shift 2 ;;
        --out)      out="${2:-}"; shift 2 ;;
        --jira-cmd) jira_cmd="${2:-}"; shift 2 ;;
        *)          shift ;;
    esac
done
[ -n "$key" ] || exit 2
[ -n "$out" ] || exit 2

# Reaper threshold = max(TTL, 300). Numeric-guard the env override.
ttl="${HIMMEL_WHERE_ARE_WE_ROLLUP_TTL:-900}"
case "$ttl" in ''|*[!0-9]*) ttl=900 ;; esac
reap="$ttl"
if [ "$reap" -lt 300 ]; then reap=300; fi

lock="$out.lock"
now="$(date +%s)"

# Stale-lock reaper — rmdir a lock left by a crashed refresh so a key can't wedge.
if [ -d "$lock" ]; then
    lmt="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0)"
    age=$(( now - lmt ))
    if [ "$age" -gt "$reap" ]; then
        rmdir "$lock" 2>/dev/null || true
    fi
fi

# Acquire the lock (PRIMARY gate). Held → another refresh is in flight → bail.
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

# Default jira command = the primary-checkout CLI (absolute). Mirrors build-plan's
# JIRA_CMD seam: intentional unquoted word-split of "node <path>" at call sites.
if [ -z "$jira_cmd" ]; then
    # The script lives at <root>/scripts/where-are-we/, so ../.. is the repo root
    # (no git needed — and in production this runs from the primary checkout,
    # which has the built jira dist/).
    sd="$(cd "$(dirname "$0")" && pwd)"
    root="$(cd "$sd/../.." && pwd)"
    jira_cmd="node $root/scripts/jira/dist/index.js"
fi

jira_timeout="${HIMMEL_WHERE_ARE_WE_JIRA_TIMEOUT:-8}"
case "$jira_timeout" in ''|*[!0-9]*) jira_timeout=8 ;; esac

run_jira() {
    if command -v timeout >/dev/null 2>&1; then
        # shellcheck disable=SC2086  # $jira_cmd is the intentional "node <path>" seam word-split
        timeout "$jira_timeout" $jira_cmd "$@" 2>/dev/null
    else
        # shellcheck disable=SC2086
        $jira_cmd "$@" 2>/dev/null
    fi
}

iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_cache() {
    # $1 = epic-or-empty, $2 = done, $3 = total
    local e="$1" d="$2" t="$3" tmp
    tmp="$out.$$.tmp"
    if [ -z "$e" ]; then
        printf '{"epic":null,"done":0,"total":0,"refreshed_at":"%s"}\n' "$iso" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return; }
    else
        printf '{"epic":"%s","done":%s,"total":%s,"refreshed_at":"%s"}\n' "$e" "$d" "$t" "$iso" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return; }
    fi
    mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# 1. Parent epic via `get --json`. On a TRANSIENT failure (nonzero / timeout) do
#    NOT poison the cache with an `epic:null` sentinel — leave the prior good
#    value in place and retry next render (I2). Only a SUCCESSFUL get with no
#    parent writes the null sentinel.
get_rc=0
getjson="$(run_jira get "$key" --json)" || get_rc=$?
if [ "$get_rc" -ne 0 ]; then exit 0; fi
epic="$(printf '%s' "$getjson" | jq -r '.fields.parent.key // empty' 2>/dev/null || true)"

if [ -z "$epic" ]; then
    write_cache "" 0 0
    exit 0
fi

# 2. Children via `list --jql` passthrough (includes Done), high limit so a large
#    epic doesn't undercount. Count ONLY lines whose col-1 is a real KEY-N (robust
#    to any header / blank line); Done = col-3 literal name, case-insensitive.
#    A transient list failure also leaves the prior cache rather than writing a
#    bogus total=0 (I2).
list_rc=0
rows="$(run_jira list --jql "parent = $epic" --limit 500)" || list_rc=$?
if [ "$list_rc" -ne 0 ]; then exit 0; fi
done_n=0
total_n=0
while IFS="$(printf '\t')" read -r col1 _col2 col3 _rest; do
    printf '%s' "$col1" | grep -qE '^[A-Z]+-[0-9]+$' || continue
    total_n=$(( total_n + 1 ))
    lc="$(printf '%s' "$col3" | tr '[:upper:]' '[:lower:]')"
    if [ "$lc" = "done" ]; then
        done_n=$(( done_n + 1 ))
    fi
done <<EOF
$rows
EOF

write_cache "$epic" "$done_n" "$total_n"
exit 0
