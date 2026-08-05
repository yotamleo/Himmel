#!/usr/bin/env bash
# guard-implementor-dispatch.sh — PreToolUse hook (matcher "Agent"): compose
# lane routing (HIMMEL-1513) with the bank-aware cost guard (HIMMEL-920).
#
# The policies answer independent questions:
#   1. If an external implementation lane is available, refuse an
#      implementation-shaped in-process Agent dispatch and name that lane.
#   2. If no lane is available but the live 5-hour bank is near exhaustion,
#      retain HIMMEL-920's HARD refusal / WARN advisory policy.
#
# Both policies fail open when their own evidence is unavailable. Lane routing
# never blocks without a positively resolved lane. A bank HARD refusal requires
# a fresh numeric utilization and a provably live five_hour resets_at window.
# Missing/unparseable resets_at downgrades HARD to the visible WARN advisory.
#
# Haiku always allows: it is already the cheap bulk-mechanical tier. Known
# read-only helpers and external-lane wrappers also allow. Plan remains exempt
# from lane routing, but retains HIMMEL-920's bank eligibility.
#
# Escape hatches (set in the shell that LAUNCHED Claude Code; session-sticky):
#   IMPL_GUARD_OK=1       deliberate one-session carve-out
#   IMPL_GUARD_DISABLE=1  emergency kill switch
# Every use is warned and appended to IMPL_GUARD_LOG (default
# ~/.claude/lane-routing-guard/overrides.jsonl), best-effort.
#
# Test seams:
#   LANES_REGISTRY                 consumed by scripts/lanes/resolve.mjs
#   IMPL_GUARD_LOG                 override audit-log path
#   IMPL_GUARD_CACHE_PATH          statusline usage cache
#   IMPL_GUARD_CACHE_MAX_AGE_SECS  cache staleness bound (default 300)
#   IMPL_GUARD_HARD                bank refusal threshold (default 80)
#   IMPL_GUARD_WARN                bank advisory threshold (default 65)
#
# Exit codes: 0 allow; 2 refuse. Bash 3.2-compatible.
set -uo pipefail

warn() { echo "guard-implementor-dispatch: $*" >&2; }

# grepq <text> [grep-args...] — never use printf|grep -q under pipefail. grep -q
# can exit on an early match, SIGPIPE the producer, and turn a true match into a
# nondeterministic pipeline failure on large input (HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

input=$(cat 2>/dev/null || true)

log_override() {
    local override="$1" log now session subagent model log_dir
    log="${IMPL_GUARD_LOG:-${HOME:-}/.claude/lane-routing-guard/overrides.jsonl}"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
    session=""
    subagent=""
    model=""
    log_dir=$(dirname "$log" 2>/dev/null || true)
    if [ -n "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
    if command -v jq >/dev/null 2>&1; then
        session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
        subagent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)
        model=$(printf '%s' "$input" | jq -r '.tool_input.model // empty' 2>/dev/null || true)
        jq -nc --arg ts "$now" --arg o "$override" --arg s "$session" --arg a "$subagent" --arg m "$model" \
            '{ts:$ts,override:$o,session:$s,subagent_type:$a,model:$m}' >> "$log" 2>/dev/null || true
    else
        printf '{"ts":"%s","override":"%s","session":"","subagent_type":"","model":""}\n' \
            "$now" "$override" >> "$log" 2>/dev/null || true
    fi
    warn "$override=1 — allowing by explicit session override; audit log: $log"
}

if [ "${IMPL_GUARD_OK:-0}" = "1" ]; then
    log_override IMPL_GUARD_OK
    exit 0
fi
if [ "${IMPL_GUARD_DISABLE:-0}" = "1" ]; then
    log_override IMPL_GUARD_DISABLE
    exit 0
fi

command -v jq >/dev/null 2>&1 || { warn "jq not on PATH — allowing (fail-open)"; exit 0; }
[ -n "$input" ] || exit 0

if ! tool=$(printf '%s' "$input" | jq -r '.tool_name | select(type == "string") // empty' 2>/dev/null); then
    warn "cannot parse hook input — allowing (fail-open)"
    exit 0
fi
[ "$tool" = "Agent" ] || exit 0

subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type | select(type == "string") // empty' 2>/dev/null || true)
model=$(printf '%s' "$input" | jq -r '.tool_input.model | select(type == "string") // empty' 2>/dev/null || true)
text=$(printf '%s' "$input" | jq -r '[.tool_input.description, .tool_input.prompt] | map(select(type == "string")) | join("\n")' 2>/dev/null || true)
[ -n "$text" ] || exit 0

model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
# Haiku is always cheap — never worth gating regardless of shape, lane, or
# bank. The Agent tool's model param accepts both the bare alias ("haiku")
# and a full model identifier ("claude-haiku-4-5-20251001"); match either.
case "$model_lc" in
    *haiku*) exit 0 ;;
esac

# Known read-only helpers and external-lane wrappers are not in-process
# implementation workers. Plan is lane-exempt, but HIMMEL-920 still applies if
# a Plan prompt is genuinely implementation-shaped.
lane_exempt=0
case "$subagent_type" in
    Explore|gemini-subagent|statusline-setup|pr-review-toolkit-himmel:code-reviewer|himmel-ops:claudex-subagent|himmel-ops:glm-subagent|codex:codex-rescue)
        exit 0
        ;;
    Plan)
        lane_exempt=1
        ;;
esac

implementation=0
operational_context=0
research=0
followed_by_action=0

# Direct action words and commit/trailer instructions are strong signals. Strip
# "how to <verb>" research framing before checking bare action verbs.
implementation_text=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed -E 's/how[[:space:]]+to[[:space:]]+(implement|fix|land)/ /g')
if grepq "$implementation_text" -Eq '(^|[^[:alnum:]_])(implement|fix|land)([^[:alnum:]_]|$)|apply (the |a )?(fix|change)|write (the )?(code|implementation)|make (the )?(change|changes|test(s)? pass)|address (the |all |every )?((coderabbit|cr|review(er)?) )?(comment(s)?|finding(s)?|feedback)|resolve (the |all |every )?((coderabbit|cr|review(er)?) )?(comment(s)?|finding(s)?|feedback)|git commit|commit (the |these )?changes|commit message|attestation trailer|platforms tested:|security reviewed:'; then
    implementation=1
fi

# A ticket ID alone is context, not implementation intent. Research wins only
# without a direct action signal, action transition, or worktree/commit instructions.
if grepq "$text" -Eqi '(^|[^[:alnum:]_])(research|explore|investigate|analy[sz]e|review|audit|plan|design|locate|trace|explain|read-only)([^[:alnum:]_]|$)'; then
    research=1
fi
if grepq "$text" -Eqi '(^|[^[:alnum:]_])(then|and)([[:space:][:punct:]]+)(implement|fix|land|apply|write|edit|modify|commit)([^[:alnum:]_]|$)'; then
    followed_by_action=1
fi
if grepq "$text" -Eqi '(\.claude[/\\]worktrees[/\\]|--worktree([=[:space:]]|$)|platforms tested:|security reviewed:|attestation trailer|git commit|commit (the |these )?changes)'; then
    operational_context=1
fi

[ "$implementation" = "1" ] || [ "$operational_context" = "1" ] || exit 0
if [ "$research" = "1" ] && [ "$implementation" = "0" ] && [ "$followed_by_action" = "0" ] && [ "$operational_context" = "0" ]; then
    exit 0
fi

hook_dir=$(cd "$(dirname "$0")" && pwd)
repo_root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$repo_root" ] || repo_root=$(cd "$hook_dir/../.." && pwd)

# --- HIMMEL-1513: refuse when a concrete external lane is available AND
# actually runnable. The registry marks a lane available by API-key presence
# alone — it never checks that bun is installed or that the lane's dispatcher
# script exists on disk. Refusing toward a registry-available-but-unrunnable
# lane would strand the caller on a command that cannot execute, which is the
# one path this guard's fail-open invariant forbids. Verify runnability before
# refusing; an unrunnable preferred lane falls through to the other lane
# (preference order claudex-before-glm stays intact) rather than straight to
# a refusal.
lane_runnable() {
    local id="$1" script="$2"
    if ! command -v bun >/dev/null 2>&1; then
        warn "lane '$id' is registry-available but bun is not on PATH — skipping it, not refusing toward it"
        return 1
    fi
    if [ ! -f "$script" ]; then
        warn "lane '$id' is registry-available but its dispatcher is missing ($script) — skipping it, not refusing toward it"
        return 1
    fi
    return 0
}

lane=""
reg_claudex=0
reg_glm=0
if [ "$lane_exempt" != "1" ]; then
    resolver="$repo_root/scripts/lanes/resolve.mjs"
    if ! command -v node >/dev/null 2>&1; then
        warn "node not on PATH — cannot resolve implementation lanes; continuing to bank guard"
    elif [ ! -f "$resolver" ]; then
        warn "lane resolver missing ($resolver) — continuing to bank guard"
    elif ! lanes=$(node "$resolver" --json 2>/dev/null); then
        warn "lane resolver failed — continuing to bank guard"
    elif ! printf '%s' "$lanes" | jq -e 'type == "array"' >/dev/null 2>&1; then
        warn "lane resolver returned invalid JSON — continuing to bank guard"
    else
        reg_claudex=$(printf '%s' "$lanes" | jq -r 'if any(.[]; .id == "claudex") then "1" else "0" end' 2>/dev/null || echo 0)
        reg_glm=$(printf '%s' "$lanes" | jq -r 'if any(.[]; .id == "glm") then "1" else "0" end' 2>/dev/null || echo 0)
        if [ "$reg_claudex" = "1" ] && lane_runnable claudex "$repo_root/scripts/telegram/spawn-claudex.ts"; then
            lane="claudex"
        elif [ "$reg_glm" = "1" ] && lane_runnable glm "$repo_root/scripts/telegram/spawn-glm.ts"; then
            lane="glm"
        fi
    fi
fi

case "$lane" in
    claudex)
        replacement="bun scripts/telegram/spawn-claudex.ts '<prompt>' --name <slug> --timeout-mins <n> --effort high"
        ;;
    glm)
        replacement="bun scripts/telegram/spawn-glm.ts '<prompt>' --name <slug> --timeout-mins <n>"
        ;;
    *)
        replacement=""
        ;;
esac

if [ -n "$replacement" ]; then
    printf 'guard-implementor-dispatch: refusing implementation-shaped Agent dispatch while %s is available; use: %s (override: relaunch with IMPL_GUARD_OK=1)\n' "$lane" "$replacement" >&2
    exit 2
fi

# --- HIMMEL-920: independently protect a nearly exhausted parent bank. ---
subagent_in_set=0
case "$subagent_type" in
    general-purpose|claude|Plan) subagent_in_set=1 ;;
esac
model_in_set=0
case "$model_lc" in
    sonnet|opus|fable|'') model_in_set=1 ;;
esac
eligible_deny=0
[ "$subagent_in_set" = "1" ] && [ "$model_in_set" = "1" ] && eligible_deny=1

shape="${subagent_type:-<no-subagent_type>}/${model:-<no-model>}"
CACHE_PATH="${IMPL_GUARD_CACHE_PATH:-/tmp/claude/statusline-usage-cache.json}"
MAX_AGE="${IMPL_GUARD_CACHE_MAX_AGE_SECS:-300}"
HARD="${IMPL_GUARD_HARD:-80}"
WARN_T="${IMPL_GUARD_WARN:-65}"

_py_lib="$hook_dir/../lib/py-armor.sh"
[ -f "$_py_lib" ] || _py_lib="${CLAUDE_PROJECT_DIR:-}/scripts/lib/py-armor.sh"
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
if ! . "$_py_lib" 2>/dev/null; then
    warn "cannot source py-armor.sh (tried $hook_dir/../lib and \$CLAUDE_PROJECT_DIR/scripts/lib) — cannot verify bank utilization for $shape; allowing"
    exit 0
fi

if [ ! -f "$CACHE_PATH" ]; then
    warn "usage cache not found ($CACHE_PATH) — cannot verify bank utilization for $shape; allowing"
    exit 0
fi

cache_mtime=$(py_armor_mtime "$CACHE_PATH")
case "$cache_mtime" in
    ''|*[!0-9]*)
        warn "cannot stat usage cache ($CACHE_PATH) — cannot verify bank utilization for $shape; allowing"
        exit 0
        ;;
esac
now=$(date +%s)
age=$(( now - cache_mtime ))
if [ "$age" -gt "$MAX_AGE" ]; then
    warn "usage cache stale (age ${age}s > ${MAX_AGE}s) — cannot verify bank utilization for $shape; allowing"
    exit 0
fi

# jq validates the value; awk owns every float-safe threshold comparison.
util=$(jq -r '
    (.five_hour.utilization) as $u
    | if ($u == null) then "UNKNOWN"
      elif ($u | type) != "number" then "UNKNOWN"
      elif ($u < 0 or $u > 100) then "UNKNOWN"
      else ($u | tostring)
      end
' "$CACHE_PATH" 2>/dev/null)
[ -n "$util" ] || util="UNKNOWN"

if [ "$util" = "UNKNOWN" ]; then
    warn "usage cache utilization unusable (null / non-numeric / out-of-range) — cannot verify bank utilization for $shape; allowing"
    exit 0
fi

# A fresh file can still contain an expired preserved five_hour object. HARD
# authority therefore requires a future resets_at. Missing/unparseable values
# downgrade to WARN; a past reset proves the utilization is expired and allows.
resets_at=$(jq -r '
    (.five_hour.resets_at // empty) as $r
    | ($r | tostring) as $s
    | if ($s | test("^[0-9]+$")) then $s
      elif ($s | test("T")) then (try ($s | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 | tostring) catch "")
      else "" end
' "$CACHE_PATH" 2>/dev/null)
resets_live=0
if [ -n "$resets_at" ]; then
    now_epoch=$(date +%s)
    if [ "$now_epoch" -ge "$resets_at" ] 2>/dev/null; then
        warn "usage cache five_hour window expired (resets_at $resets_at <= now $now_epoch) — bank has reset since this value; allowing"
        exit 0
    fi
    resets_live=1
fi

is_hard=$(awk -v v="$util" -v t="$HARD" 'BEGIN{print (v>=t)?1:0}')
is_warn=$(awk -v v="$util" -v t="$WARN_T" 'BEGIN{print (v>=t)?1:0}')
util_disp=$(awk -v v="$util" 'BEGIN{printf "%.0f", v}')

if [ "$is_hard" = "1" ] && [ "$eligible_deny" = "1" ] && [ "$resets_live" != "1" ]; then
    is_warn=1
fi
if [ "$is_hard" = "1" ] && [ "$eligible_deny" = "1" ] && [ "$resets_live" = "1" ]; then
    cat >&2 <<EOF
guard-implementor-dispatch: 5-hour bank at ${util_disp}% (>= HARD ${HARD}%) —
refusing this implementor-shaped Agent dispatch ($shape, impl-shaped prompt
detected).

At this utilization, route implementation / CR-fix work through a cheaper
lane instead of burning the scarce Sonnet/Opus/Fable weekly quota:

    himmel-ops:glm-subagent   — shared-branch mode (CR-fix rounds)
    codex:codex-rescue        — Codex lane
    /lanes                    — live lane inventory for this machine

Deliberate override: relaunch with IMPL_GUARD_OK=1 in the launching shell.
EOF
    exit 2
fi

if [ "$is_warn" = "1" ]; then
    reason=$(printf '%s' "guard-implementor-dispatch: 5-hour bank at ${util_disp}% (>= WARN ${WARN_T}%) — this $shape implementor dispatch is costly; consider himmel-ops:glm-subagent / codex:codex-rescue / /lanes instead. (IMPL_GUARD_OK=1 to silence)" | jq -Rs . 2>/dev/null) \
        || reason='"guard-implementor-dispatch: costly implementor dispatch — consider a cheaper lane"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$reason"
fi

exit 0
