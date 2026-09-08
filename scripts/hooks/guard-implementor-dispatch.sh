#!/usr/bin/env bash
# guard-implementor-dispatch.sh — PreToolUse hook (matcher "Agent"): compose
# lane routing (HIMMEL-1513) with the bank-aware cost guard (HIMMEL-920).
#
# The policies answer independent questions:
#   1. If an external implementation lane is registry-available, runnable,
#      READY (HIMMEL-1626), AND bank-funded, refuse an implementation-shaped
#      in-process Agent dispatch and name that lane. A lane failing any leg
#      falls through to the other lane (or the HIMMEL-920 bank guard) rather
#      than refusing toward it. Readiness is MEASURED, not asserted: a lane
#      under a readiness gate (lanes.json readiness.passesRequired) must show
#      that many trailing consecutive verify-return PASSes in the flow-runs
#      ledger (HIMMEL-1621) — so a ruled-down lane is skipped like a spent
#      bank instead of stranding the sanctioned in-process Claude-tier path.
#   2. If no lane is available but the live 5-hour bank is near exhaustion,
#      retain HIMMEL-920's HARD refusal / WARN advisory policy.
#
# Lane routing never refuses toward a lane whose required bank windows are
# unknown: missing/unreadable evidence is loud and skips that lane. A parent-bank
# HARD refusal requires fresh numeric utilization for a window the parent lane
# actually has and a provably live resets_at value.
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
#   IMPL_GUARD_WEEKLY_HARD         seven-day bank refusal threshold (default 85)
#   IMPL_GUARD_WEEKLY_WARN         seven-day bank advisory threshold (default 70)
# The four threshold overrides above are validated as positive numbers; a
# non-numeric, zero, or negative override is warned and replaced with its
# documented default rather than reaching the awk ratio math below as a
# divide-by-zero (HIMMEL-2653).
#   IMPL_GUARD_BANK_STATUS_CMD     override the funded-bank probe command (tests stub it; default `bun scripts/lanes/bank-status.ts`)
#   IMPL_GUARD_BANK_BUDGET_SECS    funded-bank probe wall-clock budget (default 4)
#   IMPL_GUARD_READINESS_CMD       override the lane-readiness probe command (tests stub it; default `node scripts/lanes/lane-readiness.mjs`)
#   IMPL_GUARD_READINESS_BUDGET_SECS  lane-readiness probe wall-clock budget (default 4)
#
# Exit codes: 0 allow; 2 refuse. Bash 3.2-compatible.
set -uo pipefail

warn() { echo "guard-implementor-dispatch: $*" >&2; }

# grepq <text> [grep-args...] — never use printf|grep -q under pipefail. grep -q
# can exit on an early match, SIGPIPE the producer, and turn a true match into a
# nondeterministic pipeline failure on large input (HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# valid_threshold <value> <default> <env-var-name> — echoes <value> if it is a
# positive number, else warns and echoes <default>. Used on every operator
# threshold override so a bad value (zero, negative, non-numeric) can never
# reach the awk ratio math as a divide-by-zero — falling back to the default
# keeps the guard active, which is the safe (fail-closed) direction.
valid_threshold() {
    local value="$1" default="$2" name="$3" ok
    ok=$(awk -v v="$value" 'BEGIN{ print (v ~ /^[0-9]+(\.[0-9]+)?$/ && v+0 > 0) ? 1 : 0 }' 2>/dev/null)
    if [ "$ok" = "1" ]; then
        printf '%s' "$value"
    else
        warn "$name=$value is not a positive number — using default $default"
        printf '%s' "$default"
    fi
}

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
read_only_declared=0
imperative_verb=0

# Direct action words and commit/trailer instructions are strong signals. Strip
# two kinds of non-imperative framing BEFORE the bare-verb check, so a noun or
# past-tense use of "fix" cannot alone set implementation=1 and veto every
# read-only override (HIMMEL-1617):
#   1. "how to <verb>" research framing (HIMMEL-1513).
#   2. A descriptive/past-tense "fix" — "a/the fix", "this/that/its/prior/
#      previous/earlier/existing fix", "committed a fix that", "fixed" — which
#      refers to prior work, not an imperative to act. Imperatives survive:
#      "fix the X" keeps "fix" as the head word, and action-verb+fix phrases
#      ("apply/commit/push/land/merge/ship the fix") are masked then restored
#      so the bare-verb clause below still matches them (CR round 1: the
#      apply-only mask let "commit the fix" slip through the article strip).
#      The catch-all "fixed" strip is word-boundary anchored (^|[^[:alnum:]_]
#      ... [^[:alnum:]_]|$) so it cannot eat the "fixed" inside "prefixed",
#      "affixed", or "unfixed" — an unbounded s/fixed/ /g garbles those words
#      and removes signal (HIMMEL-1624).
implementation_text=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed -E '
    s/how[[:space:]]+to[[:space:]]+(implement|fix|land)/ /g
    s/(apply|commit|push|land|merge|ship)[[:space:]]+(the[[:space:]]+|a[[:space:]]+)?fix/applyprotected/g
    s/((this|that|its|prior|previous|earlier|existing)[[:space:]]+|committed[[:space:]]+(a|the)[[:space:]]+|(a|an|the)[[:space:]]+)fix(ed)?/ /g
    s/(^|[^[:alnum:]_])fixed([^[:alnum:]_]|$)/\1 \2/g
    s/applyprotected/apply the fix/g
')
if grepq "$implementation_text" -Eq '(^|[^[:alnum:]_])(implement|fix|land)([^[:alnum:]_]|$)|apply (the |a )?(fix|change)|write (the )?(code|implementation)|make (the )?(change|changes|test(s)? pass)|address (the |all |every )?((coderabbit|cr|review(er)?) )?(comment(s)?|finding(s)?|feedback)|resolve (the |all |every )?((coderabbit|cr|review(er)?) )?(comment(s)?|finding(s)?|feedback)|git commit|commit (the |these )?changes|commit message|attestation trailer|platforms tested:|security reviewed:'; then
    implementation=1
fi

# CR rounds 2+3 (HIMMEL-1617): a standalone imperative is genuine
# implementation intent and must veto the read-only/plan override below. Two
# shapes count: a bare verb heading its own clause — text start or right after
# a sentence boundary, tolerating an adverb run ("Please fix", "Now implement";
# round 3: a single leading word defeated the bare clause-head anchor) — or a
# verb taking a determiner object ("fix the bug"), which no noun or past-tense
# survivor of the strip can form. Infinitives are stripped first so a plan or
# judgment brief describing WHAT the plan is for ("plan to fix the flaky
# suite") does not read as an order to do it. Computed on the post-strip text
# so an enumerated noun ("the fix") cannot pose as one; "apply" is in the verb
# set because every masked action-verb+fix phrase restores to "apply the fix".
# The "to" of the infinitive is left-boundary anchored (^|[^[:alnum:]_]) so the
# strip hits only the standalone word "to": without it, the "to " inside "auto
# fix" or "into fix" is eaten, destroying a genuine imperative and pushing the
# verdict toward ALLOW (HIMMEL-1624: "Auto fix the parser" must still refuse).
imperative_text=$(printf '%s' "$implementation_text" | sed -E 's/(^|[^[:alnum:]_])to[[:space:]]+(implement|fix|land|apply)/\1 /g')
if grepq "$imperative_text" -Eq '(^|[.!?;][[:space:]]*)((please|now|just|kindly|first|then)[[:space:]]+)*(implement|fix|land|apply)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])(implement|fix|land|apply)[[:space:]]+(the|a|an|this|that|it|its)([^[:alnum:]_]|$)'; then
    imperative_verb=1
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

# An explicit read-only / analysis-only / plan-only declaration outranks an
# incidental bare "fix" noun: a judgment or plan brief that merely describes
# prior work must still reach its lane (HIMMEL-1617). The declaration never
# rescues a prompt that then transitions to action or carries worktree/commit/
# trailer instructions — followed_by_action and operational_context stay vetoes
# at the allow gate below. "read-only" must be a DECLARATION — standalone
# ("Read-only.") or naming the dispatch (read-only analysis/task/...) — not an
# adjective on a noun ("fix the readonly field" is imperative implementation;
# CR round 1: the loose read[-[:space:]]*only matched "readonly" anywhere).
if grepq "$text" -Eqi 'do[[:space:]]+not[[:space:]]+edit|analysis[[:space:]]+only|read[-[:space:]]+only[[:space:]]*([.,;:!]|$)|read[-[:space:]]+only[[:space:]]+(task|review|analysis|audit|brief|mode|dispatch|pass)|plan[[:space:]]+only|return[[:space:]]+[^.!?;]*((as[[:space:]]+text)|recommendation)|produce[[:space:]]+[^.!?;]*(plan|recommendation)'; then
    read_only_declared=1
fi

[ "$implementation" = "1" ] || [ "$operational_context" = "1" ] || exit 0
if [ "$research" = "1" ] && [ "$implementation" = "0" ] && [ "$followed_by_action" = "0" ] && [ "$operational_context" = "0" ]; then
    exit 0
fi

# HIMMEL-1617: a declared read-only / analysis-only / plan-only brief is
# categorically not implementation, even when an incidental "fix" noun tripped
# implementation. A standalone imperative (imperative_verb), an action
# transition (then/and <verb>), or worktree/commit/trailer context still vetoes
# — those reveal genuine implementation intent (CR round 2: the declaration
# alone rescued "Read-only. ... Fix the bug in X").
if [ "$read_only_declared" = "1" ] && [ "$imperative_verb" = "0" ] && [ "$followed_by_action" = "0" ] && [ "$operational_context" = "0" ]; then
    exit 0
fi

hook_dir=$(cd "$(dirname "$0")" && pwd)
repo_root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$repo_root" ] || repo_root=$(cd "$hook_dir/../.." && pwd)

# --- HIMMEL-1513: refuse only when a concrete external lane is
# registry-available AND actually runnable AND bank-funded. The registry marks
# a lane available by API-key presence alone — it never checks that bun is
# installed, that the lane's dispatcher script exists on disk, or that the
# lane's bank still has quota. Refusing toward an available-but-unrunnable or
# available-but-unfunded lane would strand the caller on a command that cannot
# answer, which is the one path this guard's fail-open invariant forbids.
# Verify runnability AND funding before refusing; a preferred lane that fails
# either falls through to the other lane (preference order claudex-before-glm
# stays intact) rather than straight to a refusal. If neither lane qualifies,
# no refusal is emitted and control falls through to the HIMMEL-920 bank guard.
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

# Run a command under a hard wall-clock budget; echo its combined stdout/stderr
# and return 124 on overrun, else the command's own exit. Portable bash 3.2: a
# background job under `set -m` polled on the $SECONDS builtin, then
# process-group-killed on overrun. GNU coreutils `timeout` is intentionally NOT
# used — Windows ships a SLEEP named timeout.exe and stock macOS lacks
# coreutils, so `command -v timeout` is a trap (see qmd-staleness-notice.sh for
# the full lesson). $SECONDS keeps the bound working under the narrowed PATH
# this hook sometimes runs under, and the process-group kill reaps the helper's
# children so a wedged reader leaves nothing behind.
_run_bounded() {
    local budget_secs="$1" cmd="$2"
    local cap pid start rc
    cap=$(mktemp "${TMPDIR:-/tmp}/himmel-bank-status.XXXXXX" 2>/dev/null) || cap=""
    set -m
    bash -c "$cmd" >"${cap:-/dev/null}" 2>&1 &
    pid=$!
    set +m
    start=$SECONDS
    while [ $((SECONDS - start)) -lt "$budget_secs" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
    done
    rc=0
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rc=124
    else
        wait "$pid" 2>/dev/null || rc=$?
    fi
    [ -n "$cap" ] && cat "$cap" 2>/dev/null
    [ -n "$cap" ] && rm -f "$cap"
    return "$rc"
}

# lane_funded <lane-id> — return 0 iff the lane's declared active access path is
# positively FUNDED. Missing helpers, timeouts, non-zero exits, garbage, missing
# lane lines, and explicit `unknown` verdicts all fail LOUD and skip the lane.
# This never refuses toward the caller directly: it falls through to another
# lane or the parent-bank guard, but never routes toward unmeasured capacity.
lane_funded() {
    local id="$1" cmd budget out rc state lid lstate _detail
    budget="${IMPL_GUARD_BANK_BUDGET_SECS:-4}"
    if [ -n "${IMPL_GUARD_BANK_STATUS_CMD:-}" ]; then
        cmd="$IMPL_GUARD_BANK_STATUS_CMD"
    else
        if ! command -v bun >/dev/null 2>&1; then
            warn "lane '$id' bank-status probe needs bun, which is not on PATH — bank UNKNOWN; skipping it"
            return 1
        fi
        if [ ! -f "$repo_root/scripts/lanes/bank-status.ts" ]; then
            warn "lane '$id' bank-status probe is missing ($repo_root/scripts/lanes/bank-status.ts) — bank UNKNOWN; skipping it"
            return 1
        fi
        cmd="bun \"$repo_root/scripts/lanes/bank-status.ts\""
    fi
    rc=0
    out=$(_run_bounded "$budget" "$cmd") || rc=$?
    # rc FIRST, before the output is even parsed. A probe that timed out or
    # crashed can still have written a partial `<lane> spent` line, and the
    # `spent` arm below is the ONE arm that refuses a lane — so parsing first
    # let a half-dead probe skip a lane on evidence it never finished
    # producing. Non-zero rc means "no verdict", so the lane is skipped,
    # whatever bytes landed on stdout.
    if [ "$rc" -ne 0 ]; then
        warn "lane '$id' bank-status probe did not finish cleanly (rc=$rc) — bank UNKNOWN; skipping it"
        return 1
    fi
    # Parse `<lane-id> <state>` for this lane. A here-string (no pipeline) keeps
    # this pipefail-safe (HIMMEL-1430); the third variable absorbs status detail.
    state=""
    while IFS=' ' read -r lid lstate _detail; do
        [ -n "$lid" ] || continue
        if [ "$lid" = "$id" ]; then
            state="$lstate"
            break
        fi
    done <<< "$out"
    case "$state" in
        spent)
            warn "lane '$id' is runnable but its bank is spent — skipping it, not refusing toward it"
            return 1
            ;;
        funded)
            return 0
            ;;
        unknown)
            warn "lane '$id' bank is UNKNOWN — skipping it; inspect /lanes for the missing required window"
            return 1
            ;;
        *)
            if [ -z "$state" ]; then
                warn "lane '$id' bank-status probe returned no '$id' line — bank UNKNOWN; skipping it"
            else
                warn "lane '$id' bank-status probe returned an unrecognised state ('$state') — bank UNKNOWN; skipping it"
            fi
            return 1
            ;;
    esac
}

# lane_ready <lane-id> — return 0 iff the lane is READY (HIMMEL-1626). A lane
# under a readiness gate (lanes.json readiness.passesRequired) is ready only
# when the verify-return flow-runs ledger (HIMMEL-1621) shows that many
# trailing consecutive PASS rows for the lane's branches — readiness is
# measured, not asserted. FAIL-OPEN at the probe level, mirroring
# lane_funded(): missing node/helper, a timeout, a non-zero exit, garbage
# output, or a missing lane line ALL resolve to READY with one warning
# (pre-1626 behaviour). ONLY a clean `down` verdict skips the lane — toward
# the other lane or the HIMMEL-920 fall-through, never a refusal toward the
# caller ("skipping it, not refusing toward it"). The probe honours
# LANES_REGISTRY, so gated fixtures and the live registry read the same way.
lane_ready() {
    local id="$1" cmd budget out rc state lid lstate
    budget="${IMPL_GUARD_READINESS_BUDGET_SECS:-4}"
    if [ -n "${IMPL_GUARD_READINESS_CMD:-}" ]; then
        cmd="$IMPL_GUARD_READINESS_CMD"
    else
        if ! command -v node >/dev/null 2>&1; then
            warn "lane '$id' readiness probe needs node, which is not on PATH — treating it as ready (fail-open)"
            return 0
        fi
        if [ ! -f "$repo_root/scripts/lanes/lane-readiness.mjs" ]; then
            warn "lane '$id' readiness probe is missing ($repo_root/scripts/lanes/lane-readiness.mjs) — treating it as ready (fail-open)"
            return 0
        fi
        cmd="node \"$repo_root/scripts/lanes/lane-readiness.mjs\""
    fi
    rc=0
    out=$(_run_bounded "$budget" "$cmd") || rc=$?
    # rc FIRST, before the output is parsed — the same ordering lesson as
    # lane_funded(): `down` is the one arm that skips a lane, and a crashed or
    # timed-out probe can still have written a partial `<lane> down` line.
    # Non-zero rc means "no verdict", which fail-opens to READY.
    if [ "$rc" -ne 0 ]; then
        warn "lane '$id' readiness probe did not finish cleanly (rc=$rc) — treating it as ready (fail-open)"
        return 0
    fi
    state=""
    while IFS=' ' read -r lid lstate; do
        [ -n "$lid" ] || continue
        if [ "$lid" = "$id" ]; then
            state="$lstate"
            break
        fi
    done <<< "$out"
    case "$state" in
        down)
            warn "lane '$id' is runnable but its readiness gate is unmet (verify-return ledger) — skipping it, not refusing toward it"
            return 1
            ;;
        ready)
            return 0
            ;;
        *)
            if [ -z "$state" ]; then
                warn "lane '$id' readiness probe returned no '$id' line — treating it as ready (fail-open)"
            else
                warn "lane '$id' readiness probe returned an unrecognised state ('$state') — treating it as ready (fail-open)"
            fi
            return 0
            ;;
    esac
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
        # Readiness before funding: a down-listed lane is skipped before its
        # bank probe is paid for (both probes share the fail-open contract, so
        # the order cannot change a verdict — only the wall-clock).
        if [ "$reg_claudex" = "1" ] && lane_runnable claudex "$repo_root/scripts/telegram/spawn-claudex.ts" && lane_ready claudex && lane_funded claudex; then
            lane="claudex"
        elif [ "$reg_glm" = "1" ] && lane_runnable glm "$repo_root/scripts/telegram/spawn-glm.ts" && lane_ready glm && lane_funded glm; then
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
HARD=$(valid_threshold "$HARD" 80 IMPL_GUARD_HARD)
WARN_T="${IMPL_GUARD_WARN:-65}"
WARN_T=$(valid_threshold "$WARN_T" 65 IMPL_GUARD_WARN)
# HIMMEL-2653: the fleet burned 73% of its weekly (seven_day) bank in ~1.5
# days while this guard watched only five_hour, which sat at a quiet 45% the
# whole time — the live dispatch gate was silent all day at the exact moment
# the binding window was the slow-refilling one. The seven-day thresholds are
# deliberately HIGHER than the five-hour ones: the five-hour window refills in
# hours, so its 80/65 pair is tuned to be noisy early; the weekly window takes
# a week to refill, so tripping it at the same sensitivity would nag on every
# normal week of use. 85/70 fires only when the slower budget is genuinely the
# one binding.
WEEKLY_HARD="${IMPL_GUARD_WEEKLY_HARD:-85}"
WEEKLY_HARD=$(valid_threshold "$WEEKLY_HARD" 85 IMPL_GUARD_WEEKLY_HARD)
WEEKLY_WARN="${IMPL_GUARD_WEEKLY_WARN:-70}"
WEEKLY_WARN=$(valid_threshold "$WEEKLY_WARN" 70 IMPL_GUARD_WEEKLY_WARN)

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

# HIMMEL-2653: the two bank windows (five_hour, seven_day) are read and
# validated IDENTICALLY and INDEPENDENTLY — an unusable/expired five_hour must
# never suppress a usable seven_day verdict, and vice versa (the live gate's
# whole failure mode was one window's silence masking the other's signal).
# jq validates each value; awk owns every float-safe threshold/ratio
# comparison. Only when BOTH windows end up unusable does the hook fail open.
#
# Per-window "why it doesn't count" reasons are BUILT here but only ever
# WARNED when they actually explain the final verdict (the both-unusable
# fail-open below): a five_hour-only cache (the pre-2653 shape) or a healthy
# low-utilization seven_day that never trips must stay exactly as silent as
# the single-window guard always was — printing "7-day window does not
# contribute" on every ordinary call would be new noise on every existing
# cache, not a fix.
#
# five_hour ---------------------------------------------------------------
FIVE_USABLE=0
FIVE_RESETS_LIVE=0
FIVE_IS_HARD=0
FIVE_IS_WARN=0
FIVE_DISP=""
FIVE_REASON=""
five_util=$(jq -r '
    (.five_hour.utilization) as $u
    | if ($u == null) then "UNKNOWN"
      elif ($u | type) != "number" then "UNKNOWN"
      elif ($u < 0 or $u > 100) then "UNKNOWN"
      else ($u | tostring)
      end
' "$CACHE_PATH" 2>/dev/null)
[ -n "$five_util" ] || five_util="UNKNOWN"

if [ "$five_util" = "UNKNOWN" ]; then
    FIVE_REASON="5-hour bank utilization unusable (null / non-numeric / out-of-range) for $shape — 5-hour window does not contribute"
else
    five_resets_at=$(jq -r '
        (.five_hour.resets_at // empty) as $r
        | ($r | tostring) as $s
        | if ($s | test("^[0-9]+$")) then $s
          elif ($s | test("T")) then (try ($s | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 | tostring) catch "")
          else "" end
    ' "$CACHE_PATH" 2>/dev/null)
    five_expired=0
    if [ -n "$five_resets_at" ]; then
        now_epoch=$(date +%s)
        if [ "$now_epoch" -ge "$five_resets_at" ] 2>/dev/null; then
            FIVE_REASON="usage cache five_hour window expired (resets_at $five_resets_at <= now $now_epoch) — bank has reset since this value; 5-hour window does not contribute"
            five_expired=1
        else
            FIVE_RESETS_LIVE=1
        fi
    fi
    if [ "$five_expired" != "1" ]; then
        FIVE_USABLE=1
        FIVE_IS_HARD=$(awk -v v="$five_util" -v t="$HARD" 'BEGIN{print (v>=t)?1:0}')
        FIVE_IS_WARN=$(awk -v v="$five_util" -v t="$WARN_T" 'BEGIN{print (v>=t)?1:0}')
        FIVE_DISP=$(awk -v v="$five_util" 'BEGIN{printf "%.0f", v}')
        # CR round 3 (HIMMEL-2653): explicit HARD->WARN downgrade, restored from
        # the pre-2653 single-window guard verbatim (same eligible_deny / live-
        # reset conditions). An eligible-but-not-live-reset HARD reading cannot
        # actually refuse, so it must still surface as a WARN. Relying on
        # FIVE_IS_WARN alone is NOT equivalent whenever WARN_T > HARD (an
        # operator config the four thresholds are never validated against each
        # other for) -- a util between HARD and WARN_T would then trip HARD but
        # not WARN, and without this downgrade the guard would silently allow.
        if [ "$FIVE_IS_HARD" = "1" ] && [ "$eligible_deny" = "1" ] && [ "$FIVE_RESETS_LIVE" != "1" ]; then
            FIVE_IS_WARN=1
        fi
    fi
fi

# seven_day -----------------------------------------------------------------
SEVEN_USABLE=0
SEVEN_RESETS_LIVE=0
SEVEN_IS_HARD=0
SEVEN_IS_WARN=0
SEVEN_DISP=""
SEVEN_REASON=""
seven_util=$(jq -r '
    (.seven_day.utilization) as $u
    | if ($u == null) then "UNKNOWN"
      elif ($u | type) != "number" then "UNKNOWN"
      elif ($u < 0 or $u > 100) then "UNKNOWN"
      else ($u | tostring)
      end
' "$CACHE_PATH" 2>/dev/null)
[ -n "$seven_util" ] || seven_util="UNKNOWN"

if [ "$seven_util" = "UNKNOWN" ]; then
    SEVEN_REASON="7-day bank utilization unusable (null / non-numeric / out-of-range, or absent) for $shape — 7-day window does not contribute"
else
    seven_resets_at=$(jq -r '
        (.seven_day.resets_at // empty) as $r
        | ($r | tostring) as $s
        | if ($s | test("^[0-9]+$")) then $s
          elif ($s | test("T")) then (try ($s | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 | tostring) catch "")
          else "" end
    ' "$CACHE_PATH" 2>/dev/null)
    seven_expired=0
    if [ -n "$seven_resets_at" ]; then
        now_epoch=$(date +%s)
        if [ "$now_epoch" -ge "$seven_resets_at" ] 2>/dev/null; then
            SEVEN_REASON="usage cache seven_day window expired (resets_at $seven_resets_at <= now $now_epoch) — bank has reset since this value; 7-day window does not contribute"
            seven_expired=1
        else
            SEVEN_RESETS_LIVE=1
        fi
    fi
    if [ "$seven_expired" != "1" ]; then
        SEVEN_USABLE=1
        SEVEN_IS_HARD=$(awk -v v="$seven_util" -v t="$WEEKLY_HARD" 'BEGIN{print (v>=t)?1:0}')
        SEVEN_IS_WARN=$(awk -v v="$seven_util" -v t="$WEEKLY_WARN" 'BEGIN{print (v>=t)?1:0}')
        SEVEN_DISP=$(awk -v v="$seven_util" 'BEGIN{printf "%.0f", v}')
        # CR round 3 (HIMMEL-2653): same explicit HARD->WARN downgrade as the
        # five_hour window above, applied to seven_day.
        if [ "$SEVEN_IS_HARD" = "1" ] && [ "$eligible_deny" = "1" ] && [ "$SEVEN_RESETS_LIVE" != "1" ]; then
            SEVEN_IS_WARN=1
        fi
    fi
fi

if [ "$FIVE_USABLE" != "1" ] && [ "$SEVEN_USABLE" != "1" ]; then
    [ -n "$FIVE_REASON" ] && warn "$FIVE_REASON"
    [ -n "$SEVEN_REASON" ] && warn "$SEVEN_REASON"
    warn "neither the 5-hour nor the 7-day bank window is usable — cannot verify bank utilization for $shape; allowing"
    exit 0
fi

# Fire on the binding window. HARD requires eligible_deny AND a live
# resets_at; a HARD reading without a live reset still counts toward WARN via
# the explicit HARD->WARN downgrade above (not merely *_IS_WARN's own
# threshold check, which is NOT equivalent whenever WARN_T > HARD) — the same
# downgrade the five-hour-only guard always had. When more than one window
# trips a tier, report the one
# proportionally further past its OWN threshold (a ratio, since the two
# windows use different thresholds) so a barely-over-WARN five-hour reading
# never outshouts a well-past-WARN weekly one, or vice versa.
hard_window=""
if [ "$eligible_deny" = "1" ]; then
    if [ "$FIVE_IS_HARD" = "1" ] && [ "$FIVE_RESETS_LIVE" = "1" ]; then
        hard_window="five_hour"
    fi
    if [ "$SEVEN_IS_HARD" = "1" ] && [ "$SEVEN_RESETS_LIVE" = "1" ]; then
        if [ -z "$hard_window" ]; then
            hard_window="seven_day"
        else
            hard_window=$(awk -v fu="$five_util" -v fh="$HARD" -v su="$seven_util" -v sh="$WEEKLY_HARD" \
                'BEGIN{ print ((su/sh) > (fu/fh)) ? "seven_day" : "five_hour" }')
        fi
    fi
fi

if [ -n "$hard_window" ]; then
    if [ "$hard_window" = "seven_day" ]; then
        win_label="7-day"; win_disp="$SEVEN_DISP"; win_thresh="$WEEKLY_HARD"
    else
        win_label="5-hour"; win_disp="$FIVE_DISP"; win_thresh="$HARD"
    fi
    cat >&2 <<EOF
guard-implementor-dispatch: ${win_label} bank at ${win_disp}% (>= HARD ${win_thresh}%) —
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

warn_window=""
if [ "$FIVE_IS_WARN" = "1" ]; then
    warn_window="five_hour"
fi
if [ "$SEVEN_IS_WARN" = "1" ]; then
    if [ -z "$warn_window" ]; then
        warn_window="seven_day"
    else
        warn_window=$(awk -v fu="$five_util" -v fw="$WARN_T" -v su="$seven_util" -v sw="$WEEKLY_WARN" \
            'BEGIN{ print ((su/sw) > (fu/fw)) ? "seven_day" : "five_hour" }')
    fi
fi

if [ -n "$warn_window" ]; then
    if [ "$warn_window" = "seven_day" ]; then
        win_label="7-day"; win_disp="$SEVEN_DISP"; win_thresh="$WEEKLY_WARN"
    else
        win_label="5-hour"; win_disp="$FIVE_DISP"; win_thresh="$WARN_T"
    fi
    reason=$(printf '%s' "guard-implementor-dispatch: ${win_label} bank at ${win_disp}% (>= WARN ${win_thresh}%) — this $shape implementor dispatch is costly; consider himmel-ops:glm-subagent / codex:codex-rescue / /lanes instead. (IMPL_GUARD_OK=1 to silence)" | jq -Rs . 2>/dev/null) \
        || reason='"guard-implementor-dispatch: costly implementor dispatch — consider a cheaper lane"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$reason"
fi

exit 0
