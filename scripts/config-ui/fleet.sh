#!/usr/bin/env bash
# fleet.sh — read-only session census for the AG-UI fleet page (HIMMEL-4712).
# Composes the existing owners and parses nothing itself, like legs.sh: the live
# claude processes from claude-sessions.sh's claude_sessions() (the census
# tick.sh's procs= and board.mjs read), the handover root from
# `load_dotenv HANDOVER_DIR` + `handover_root` (anchored as legs.sh does), each
# session's leg doc (<root>/**/<session name>.md) and its status from
# leg_tail_status. Prints one JSON object:
#   {"census": "ok"|"degraded"|"unavailable", "sessions": [{"pid": "<pid>",
#    "name": "<-n value>", "model": "<--model value>", "doc": "<path>"|"",
#    "status": "<marker>"|"", "autocompact": "<--autocompact value>"|""}],
#    "cloudRoutes": ["<bucket>/cloud-route.jsonl", ...]}
# cloudRoutes (HIMMEL-4791) = every console bucket's cloud-route.jsonl under the
# handover root, the routing log fleet-cloud.ts reads the cloud sessions from.
# census: degraded = some live pid's argv was unreadable (claude_sessions rc 3),
# unavailable = the scan itself failed. No handover root is not an error: the
# sessions are still listed, with no doc.
# Bash 3.2-compatible; needs jq.
self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
common=$(git -C "$self" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && anchor=$(cd "$common/.." && pwd) || anchor=$(cd "$self/../.." && pwd)

# shellcheck source=../lib/load-dotenv.sh
. "$self/../lib/load-dotenv.sh"
# shellcheck source=../lib/handover-path.sh
. "$self/../lib/handover-path.sh"
# shellcheck source=../lib/leg-tail-status.sh
. "$self/../lib/leg-tail-status.sh"
# shellcheck source=../lanes/lib/claude-sessions.sh
. "$self/../lanes/lib/claude-sessions.sh"

load_dotenv --root "$anchor" HANDOVER_DIR
root=$(cd "$anchor" && handover_root 2>/dev/null) || root=""

out=$(claude_sessions)
rc=$?
census=ok
if [ "$rc" -eq 3 ] && [ -n "$out" ]; then census=degraded
elif [ "$rc" -ne 0 ]; then census=unavailable; out=""
fi

rows=""
# Read on a non-whitespace separator: tab is IFS whitespace, so an empty name
# column (a session started without -n) would collapse and shift model into it.
sep=$(printf '\037')
out=$(printf '%s\n' "$out" | tr '\t' '\037')
while IFS="$sep" read -r pid name model autocompact _; do
    case "$pid" in ''|'#'*) continue ;; esac
    # Helpers share the claude executable but are not sessions. Inspect argv boundaries,
    # not prompt substrings; a helper flag used as a prompt value is not a flag.
    helper=0 expect=""
    cmdline="${CLAUDE_SESSIONS_PROC:-/proc}/$pid/cmdline"
    if [ -r "$cmdline" ]; then
        while IFS= read -r -d '' arg; do
            if [ -n "$expect" ]; then expect=""; continue; fi
            case "$arg" in
                --) break ;;
                --chrome-native-host|--claude-in-chrome-mcp|--mcp-server) helper=1 ;;
                -n|--model|--autocompact|--append-system-prompt|--append-system-prompt-file|--system-prompt|--system-prompt-file) expect=skip ;;
            esac
        done < "$cmdline"
    fi
    [ "$helper" -eq 1 ] && continue
    doc="" status=""
    # Only a plain session name is searched for (find -name would read glob characters as a pattern).
    case "$name" in ''|*[!A-Za-z0-9._+-]*) plain="" ;; *) plain=1 ;; esac
    if [ -n "$root" ] && [ -n "$plain" ]; then
        doc=$(find "$root" -maxdepth 4 -type f -name "$name.md" 2>/dev/null | head -1) # gnu-ok: BSD find also supports -maxdepth
        [ -n "$doc" ] && status=$(leg_tail_status "$doc")
    fi
    started=""
    elapsed=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$elapsed" in ''|*[!0-9]*) ;; *) started=$(( $(date +%s) - elapsed )) ;; esac
    rows="$rows$pid	$name	$model	$doc	$status	$autocompact	$started
"
done <<EOF
$out
EOF
routes=""
[ -n "$root" ] && routes=$(find "$root" -maxdepth 4 -type f -name cloud-route.jsonl 2>/dev/null) # gnu-ok: BSD find also supports -maxdepth
manifests="" consoles="" locks=""
if [ -n "$root" ]; then
    manifests=$(find "$root" -maxdepth 4 -type f -name '*.fleet.json' 2>/dev/null) # gnu-ok: BSD find supports -maxdepth
    consoles=$(find "$root" -maxdepth 4 -type f -name '*-console.md' 2>/dev/null) # gnu-ok: BSD find supports -maxdepth
    locks=$(find "$root/.locks/queue" -maxdepth 2 -type f -name owner.json 2>/dev/null) # gnu-ok: BSD find supports -maxdepth
fi
jq -n --arg census "$census" --arg rows "$rows" --arg routes "$routes" --arg manifests "$manifests" --arg consoles "$consoles" --arg locks "$locks" '{census: $census, sessions: [$rows | split("\n")[] | select(length > 0) | split("\t") | {pid: .[0], name: .[1], model: .[2], doc: .[3], status: (.[4] // ""), autocompact: (.[5] // ""), startedAt: (if (.[6] // "") == "" then null else (.[6] | tonumber) * 1000 end)}], cloudRoutes: [$routes | split("\n")[] | select(length > 0)], manifests: [$manifests | split("\n")[] | select(length > 0)], consoleDocs: [$consoles | split("\n")[] | select(length > 0)], lockFiles: [$locks | split("\n")[] | select(length > 0)]}'
