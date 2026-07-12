#!/usr/bin/env bash
# guard-implementor-dispatch.sh — PreToolUse hook (matcher "Agent"): bank-aware
# cost guard on implementor-shaped subagent dispatches (HIMMEL-920).
#
# WHY: structural enforcement of the HIMMEL-195 second-drift rule. s40 burned
# 86% of a 5-hour bank routing four CR-fix rounds to a Sonnet subagent while
# the GLM lane sat available (CLAUDE.md subagent policy: "every dispatch
# names an explicit model... raise effort before tier... route by lane").
# Prose didn't stop the drift twice, so this hook makes the expensive shape
# structurally visible/blockable at dispatch time instead of after the fact.
#
# THIS IS A COST GUARD, NOT A SECURITY GUARD — it fails OPEN everywhere
# (opposite of the block-*.sh security siblings, which fail CLOSED on a
# missing dependency). A bug in this hook must never brick a legitimate
# Agent dispatch; worst case it silently allows. The fail-open sibling
# precedent is the auto-arm watchdog family (auto-arm-on-cap.sh,
# auto-arm-on-subagent-cap.sh), not block-edit-on-main.sh.
#
# Decision order (first hit wins — see the critic-hardened plan
# 2026-07-12-himmel-920-impl-dispatch-guard.md for the full derivation):
#   1. IMPL_GUARD_DISABLE=1 / IMPL_GUARD_OK=1 (session bypass, launching-shell
#      convention, same as EDIT_ON_MAIN_OK etc.) → allow silently.
#   2. jq missing / stdin unparseable / not an Agent call → allow (fail-open).
#   3. Parse subagent_type / model / prompt from tool_input.
#   4. model == haiku → always allow (cheap lane, never worth gating).
#   5. DENY-tier eligibility is an ALLOW-LIST of known-expensive implementor
#      shapes (critic Q2 — a deny-list would false-block future reviewer
#      agent types): subagent_type in {general-purpose, claude,
#      feature-dev:code-architect} AND model in {sonnet, opus, fable, absent/
#      empty}. An absent/empty model IS DENY-eligible (HIMMEL-972 operator
#      ruling 2026-07-12: an unnamed dispatch inherits the parent loop — the
#      exact expensive shape this guard exists for; supersedes the original
#      critic call).
#   6. Impl-shaped prompt classifier (case-insensitive ERE, de-greeded per
#      critic Q1 — dropped `patch` (substring of "dispatch"), bare `commit`,
#      bare `refactor`: all high false-positive). No match → allow.
#   7. Read the 5-hour bank utilization from the claude-statusline cache
#      (IMPL_GUARD_CACHE_PATH, default /tmp/claude/statusline-usage-cache.json).
#      Missing cache, unstatable, stale (mtime older than
#      IMPL_GUARD_CACHE_MAX_AGE_SECS, default 300s), or an unusable value
#      (null / non-numeric / out of [0,100] range — the documented
#      leaked-epoch corruption, see auto-arm-on-cap.sh) → allow + a plain
#      stderr WARN. Never brick on a cold statusline.
#   8. Policy on a confirmed numeric utilization (float-safe: jq validates
#      the value and awk performs the threshold compares — never bash
#      `[ -ge ]` against a float, the HIMMEL-392 no-stderr hook death):
#        util >= IMPL_GUARD_HARD (default 80) AND DENY-tier-eligible →
#          exit 2 (block), naming util%, the dispatch shape, and the
#          cheaper-lane redirect.
#        util >= IMPL_GUARD_WARN (default 65) [either DENY-eligible but
#          under HARD, or capped to WARN by step 5] → allow, but emit the
#          hookSpecificOutput permissionDecision:"allow" JSON idiom
#          (auto-approve-safe-bash.sh:432 precedent) so the advisory
#          actually reaches the model — an exit-0 stderr line is INVISIBLE
#          to the model in PreToolUse.
#        else → allow silently.
#
# Env knobs (all optional, read from the LAUNCHING shell):
#   IMPL_GUARD_DISABLE=1           kill switch
#   IMPL_GUARD_OK=1                per-call deliberate override (session-sticky)
#   IMPL_GUARD_CACHE_PATH          cache file (default /tmp/claude/statusline-usage-cache.json)
#   IMPL_GUARD_CACHE_MAX_AGE_SECS  staleness bound in seconds (default 300)
#   IMPL_GUARD_HARD                block threshold, percent (default 80)
#   IMPL_GUARD_WARN                advisory threshold, percent (default 65)
#
# Non-goals (v1, per plan): no GLM-bank preflight, no prompt-length/token
# estimation, threshold *calibration* beyond the defaults above (HIMMEL-774).
#
# Known limitations (chosen tradeoffs, NOT bugs — adjudicated against the
# codex adversarial round that proposed the opposite):
# - WORDING-DEPENDENT CLASSIFICATION: prompts phrased without the marker set
#   ("update the hook", "create the handler") bypass the guard. Widening to
#   generic verbs (add/update/create/modify/build) was REJECTED by the plan
#   critic as high-false-positive (research/planning briefs use those verbs
#   constantly); the parent authoring the prompt is not adversarial, and the
#   incident class this guard exists for (s40 CR-fix rounds) uses the marker
#   vocabulary. Same accepted-limitation family as the wrapper-displacement
#   gaps documented in block-glm-external-writes.sh.
# - ABSENT MODEL IS DENY-ELIGIBLE (HIMMEL-972): an unnamed dispatch inherits
#   the parent loop, so it is treated as a known-expensive shape at the hard
#   threshold. Originally WARN-only (plan-critic call); superseded by the
#   2026-07-12 operator ruling on the HIMMEL-920 cross-model conflict.
#   Residual edge (adjudicated, NOT a bug): a HAIKU parent's unnamed dispatch
#   inherits cheap Haiku yet still denies — accepted because Haiku does not
#   spawn (CLAUDE.md invariant), naming `haiku` explicitly hits the early
#   always-allow, and IMPL_GUARD_OK=1 covers the exotic remainder.
#
# bash 3.2-compatible (no ${var,,}, no mapfile, no associative arrays).
set -uo pipefail

warn() { echo "guard-implementor-dispatch: $*" >&2; }

[ "${IMPL_GUARD_DISABLE:-0}" = "1" ] && exit 0
[ "${IMPL_GUARD_OK:-0}" = "1" ] && exit 0

hook_dir=$(cd "$(dirname "$0")" && pwd)

# --- Fail open on anything we cannot evaluate (cost guard, not a security boundary) ---
command -v jq >/dev/null 2>&1 || { warn "jq not on PATH — allowing (fail-open)"; exit 0; }

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ "$tool" = "Agent" ] || exit 0   # matcher already scopes to Agent; defensive for direct invocation

subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)
model=$(printf '%s' "$input" | jq -r '.tool_input.model // empty' 2>/dev/null || true)
prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // empty' 2>/dev/null || true)

model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')

# Haiku is always cheap — never worth gating regardless of shape/prompt/bank.
[ "$model_lc" = "haiku" ] && exit 0

# --- DENY-tier eligibility: ALLOW-LIST of known-expensive implementor shapes ---
# (critic Q2: a deny-list would false-block future reviewer agent types).
subagent_in_set=0
case "$subagent_type" in
    general-purpose|claude|feature-dev:code-architect) subagent_in_set=1 ;;
esac
model_in_set=0
case "$model_lc" in
    sonnet|opus|fable|'') model_in_set=1 ;;
esac
eligible_deny=0
[ "$subagent_in_set" = "1" ] && [ "$model_in_set" = "1" ] && eligible_deny=1

# --- Impl-shaped prompt classifier (case-insensitive ERE, de-greeded) ---
printf '%s' "$prompt" | grep -Eqi 'implement|apply the fix|write the code|make it pass|fix (the |all )?(bug|finding|test)s?|(address|resolve|remediate) (the |all |every )?((coderabbit|cr|review(er)?) )?(comments?|findings?|feedback)' \
    || exit 0

shape="${subagent_type:-<no-subagent_type>}/${model:-<no-model>}"

# --- Read the 5-hour bank utilization ---
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
        # Empty OR non-integer: garbage here would error the age arithmetic
        # under set -u — same fail-open answer as an unavailable timestamp.
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

# Numeric handling (float-safe, clamp to [0,100]): jq owns the whole compare
# so bash never runs `[ -ge ]` against a float (kills the hook under set -e —
# HIMMEL-392). null / non-numeric / out-of-range (e.g. the documented
# leaked-epoch corruption, auto-arm-on-cap.sh) → UNKNOWN, never coerced to 0.
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

# Per-window freshness (codex-adv): the cache producer preserves the previous
# five_hour object when a seven_day-only payload arrives, rewriting the file
# (fresh mtime) around a STALE five_hour value — so file mtime alone does not
# establish five-hour freshness. The window's own resets_at bounds the worst
# case: a utilization whose reset time has PASSED describes an expired window
# (the bank has reset since) → UNKNOWN, never a spurious DENY. A stale-low
# value inside a still-live window can only under-warn — the fail-open
# direction this cost guard already accepts.
# resets_at appears as an epoch string in the live cache; tolerate ISO forms
# too (fractional seconds normalized away — fromdateiso8601 rejects .000Z).
# A HARD deny must be backed by a provably-LIVE window: missing/unparseable
# resets_at means the value cannot be tied to the current 5h window, so deny
# authority downgrades to the WARN advisory instead of falsely blocking
# (codex-adv r3).
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
    # HARD-worthy but the window cannot be proven live — advisory only.
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
    exit 0
fi

exit 0
