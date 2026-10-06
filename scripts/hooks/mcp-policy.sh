#!/usr/bin/env bash
# PreToolUse hook on mcp__.* — MCP call tracking plus a gating seam
# (HIMMEL-4676).
#
# Every MCP call is classified against scripts/guardrails/mcp-policy.json and
# audited as one JSONL line (ts, session, server, tool, class, egress, mode,
# verdict, reason) — never any tool argument.
#
# Classes: read | write | destructive (from the registry), or
#   unknown-server  the server is not in the registry
#   unlisted-tool   the server is, the tool is not
#   invalid-class   the registry gives the tool a class outside the three
#   malformed       unparseable input, a non-string tool_name, or one that is
#                   not mcp__<server>__<tool> in [A-Za-z0-9_.-] (ANSI, CR/LF)
# The verdict is what the policy WOULD do: deny for every class above except
# read/write, for a destructive tool not in the server's allow_destructive,
# for a server whose verdict is deny, and for an off-box server whose
# egress-matrix provider has a corpus:* purpose:* deny row.
#
# Mode (registry `mode`, overridable per server):
#   observe  ALWAYS exit 0. This is what ships: operator ruling 2026-10-06 —
#            this hook must never break or stall a current MCP call.
#   enforce  a deny verdict exits 2 with the registry entry to add. Tested,
#            OFF everywhere in the shipped registry.
#
# Fail direction: OPEN, deliberately, on every infrastructure error (no jq,
# missing or malformed registry, jq timeout, unwritable audit log) — it is a
# tracker until a server is switched to enforce, and a tracker that can deny
# on its own bug is the over-deny the ruling forbids. Enforce-mode denials of
# malformed input still fail closed, because they are policy, not
# infrastructure. jq runs under a 2 s internal timeout.
#
# The Atlassian MCP-to-CLI redirect stays its own hook
# (block-backend-tier.sh, matcher mcp__plugin_atlassian_atlassian__.*) and
# runs beside this one, unchanged.
#
# Test seams: MCP_POLICY_REGISTRY, MCP_POLICY_EGRESS_MATRIX,
# MCP_POLICY_AUDIT_LOG (default $HOME/.himmel/state/mcp-audit.jsonl).
set -u

input=$(cat 2>/dev/null) || input=""

# fail-open-ok: tracker — without jq there is nothing to classify (header).
command -v jq >/dev/null 2>&1 || exit 0

hook_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 0
registry="${MCP_POLICY_REGISTRY:-$hook_dir/../guardrails/mcp-policy.json}"
matrix="${MCP_POLICY_EGRESS_MATRIX:-$hook_dir/../guardrails/egress-matrix.json}"
log="${MCP_POLICY_AUDIT_LOG:-${HOME:-}/.himmel/state/mcp-audit.jsonl}"

# fail-open-ok: tracker — no registry, nothing to classify against.
[ -r "$registry" ] || exit 0
[ -r "$matrix" ] || matrix=/dev/null

tmo=""
if command -v timeout >/dev/null 2>&1; then
    tmo="timeout 2"
elif command -v gtimeout >/dev/null 2>&1; then
    tmo="gtimeout 2"
fi

# Output: line 1 the audit JSON, line 2 "<apply> <max_bytes>" where apply is
# deny only when the verdict is deny AND the mode is enforce, then the
# refusal text.
# shellcheck disable=SC2016  # jq program, not shell expansion
out=$(printf '%s' "$input" | $tmo jq -Rsr --arg host "${HOSTNAME:-}" --slurpfile reg "$registry" --slurpfile mx "$matrix" '
    . as $raw
    | ($reg[0] // {}) as $r
    | (($r.servers // {}) | if type == "object" then . else {} end) as $servers
    | (try ($raw | fromjson) catch null) as $in
    | ($in | if type == "object" then . else {} end) as $o
    | ($o.session_id | if type == "string" then gsub("[^A-Za-z0-9._-]"; "")[:64] else "" end) as $sess
    | ($o.tool_name) as $tn
    | (if ($tn | type) == "string" and ($tn | test("\\Amcp__[A-Za-z0-9_.-]+\\z"))
       then ($tn[5:]) as $rest
          | ($rest | index("__")) as $i
          | if $i == null or $i == 0 or ($rest[$i+2:] == "") then null
            else {server: $rest[:$i], tool: $rest[$i+2:]} end
       else null end) as $p
    | (if $p == null then null else $servers[$p.server] end) as $s
    | ($s | if type == "object" then . else null end) as $s
    | (if $s != null and ($s.mode | type) == "string" then $s.mode
       else ($r.mode // "observe") end) as $mode
    | (if $p == null then "malformed"
       elif $s == null then "unknown-server"
       else ((($s.tools // {}) | if type == "object" then . else {} end)[$p.tool]) as $c
          | if $c == null then "unlisted-tool"
            elif ($c == "read" or $c == "write" or $c == "destructive") then $c
            else "invalid-class" end
       end) as $class
    | ($s.egress // null) as $egress
    | ($s.provider // null) as $prov
    | ([($mx[0].rules // [])[]
        | select(.corpus == "*" and .provider == $prov and .purpose == "*"
                 and (.verdict == "deny" or .verdict == "pending-operator"))]
       | length > 0) as $egress_denied
    | (if $class == "malformed" then "malformed tool_name or hook input"
       elif $class == "unknown-server" then "add servers[\"\($p.server)\"] to scripts/guardrails/mcp-policy.json"
       elif $class == "unlisted-tool" then "add servers[\"\($p.server)\"].tools[\"\($p.tool)\"] to scripts/guardrails/mcp-policy.json"
       elif $class == "invalid-class" then "servers[\"\($p.server)\"].tools[\"\($p.tool)\"] must be read, write or destructive"
       elif $s.verdict == "deny" then "servers[\"\($p.server)\"].verdict is deny"
       elif $egress == "off-box" and $egress_denied then "egress-matrix.json denies provider \($prov) for every corpus"
       elif $class == "destructive" and ((($s.allow_destructive // []) | index([$p.tool])) == null)
         then "destructive: list \"\($p.tool)\" in servers[\"\($p.server)\"].allow_destructive to allow it"
       else "" end) as $reason
    | (if $reason == "" then "allow" else "deny" end) as $verdict
    | ({v: 1, ts: (now | todate), host: $host, source: "mcp-policy", kind: "mcp-call", session: $sess, server: $p.server, tool: $p.tool,
        class: $class, egress: $egress, mode: $mode, verdict: $verdict, reason: $reason} | tojson),
      ((if $verdict == "deny" and $mode == "enforce" then "deny" else "allow" end)
       + " " + (($r.audit.max_bytes // 1048576) | tostring)),
      (if $verdict == "deny" and $mode == "enforce" then
         "mcp-policy: refusing MCP call \"\(if $p == null then "<malformed>" else "mcp__\($p.server)__\($p.tool)" end)\" (class \($class), mode enforce).\n\n"
         + "Why: \($reason).\n\n"
         + "The registry is scripts/guardrails/mcp-policy.json (HIMMEL-4676). Add the entry in a PR,\n"
         + "or set this server back to \"mode\": \"observe\" there."
       else empty end)
' 2>/dev/null) || exit 0  # fail-open-ok: tracker — jq error or timeout (header)

{ IFS= read -r audit; IFS=' ' read -r apply max_bytes; msg=$(cat); } <<<"$out"

case "$max_bytes" in ''|*[!0-9]*) max_bytes=1048576 ;; esac
if [ -n "$audit" ] && mkdir -p "$(dirname "$log")" 2>/dev/null; then
    if [ -f "$log" ]; then  # fail-open-ok: size read only drives rotation; the verdict never reads the log
        size=$(wc -c <"$log" 2>/dev/null | tr -d ' ')
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        [ "$size" -ge "$max_bytes" ] && mv -f "$log" "$log.1" 2>/dev/null
    fi
    printf '%s\n' "$audit" >>"$log" 2>/dev/null
fi

if [ "${apply:-allow}" = "deny" ]; then
    printf '%s\n' "$msg" >&2
    exit 2
fi
exit 0
