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
#   IMPL_GUARD_ROUND_BUDGET_SECS   round-guard probe wall-clock budget (default 4)
#
# HIMMEL-1568: this hook is also the Agent-dispatch chokepoint for the
# HIMMEL-1553 reviewed-round guard (scripts/telegram/round-guard.ts) — the
# same predicate spawn-glm.ts/spawn-claudex.ts already apply, now covering the
# in-process Agent-tool dispatch path those two scripts never see. Unlike
# every other probe above, a payload cwd that IS given but whose round-guard
# probe cannot be evaluated (bun missing, script missing, probe crash/timeout)
# fails CLOSED, not open — see the HIMMEL-1568 comment at its call site.
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

# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
. "$hook_dir/../lib/git-clean.sh" 2>/dev/null || true

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
    local budget_secs="$1" cmd="$2" poll_secs="${3:-1}"
    local cap pid start rc
    cap=$(mktemp "${TMPDIR:-/tmp}/himmel-bank-status.XXXXXX" 2>/dev/null) || cap=""
    set -m
    bash -c "$cmd" >"${cap:-/dev/null}" 2>&1 &
    pid=$!
    set +m
    start=$SECONDS
    # HIMMEL-3676 (J1322A, Minor 3): $SECONDS has whole-second granularity, so
    # a strict "-lt" let the loop exit as soon as the second counter ticked
    # OVER the budget rather than honouring it in full (measured: a
    # 2-second budget killed a probe at ~1.1s). "-le" widens the floor to
    # budget..budget+1s, restoring "at least budget seconds" instead of
    # "somewhere between budget-1 and budget".
    while [ $((SECONDS - start)) -le "$budget_secs" ] && kill -0 "$pid" 2>/dev/null; do
        sleep "$poll_secs"
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

# _round_check_one <branch-args-suffix> <label> — run round-guard.ts's CLI
# once under the wall-clock budget for one branch and disposition its result
# exactly like the single-branch call this replaces (HIMMEL-3676, J1322A
# Critical): refuse the whole hook (exit 2) on anything but a clean
# sentinel-bearing rc=0. <branch-args-suffix> is empty for the payload cwd's
# own branch (round-guard.ts self-detects it from --cwd when --branch is
# omitted) or " --branch <name>" for one distinct worktree branch the
# dispatch text names. Reads round_cwd/round_task_path/round_task_file from
# the caller's scope, same as every other round-guard helper in this file.
_round_check_one() {
    local branch_args="$1" label="$2" cmd out rc
    cmd="bun $(printf '%q' "$repo_root/scripts/telegram/round-guard.ts") check --cwd $(printf '%q' "$round_cwd") --task-file $(printf '%q' "$round_task_file")$branch_args"
    rc=0
    out=$(_run_bounded "${IMPL_GUARD_ROUND_BUDGET_SECS:-4}" "$cmd" 0.05) || rc=$?
    case "$rc" in
        0)
            # HIMMEL-3681: a version-skewed/stale round-guard.ts build could
            # exit 0 having never actually evaluated the predicate; the
            # sentinel is the only signal this hook has that it did.
            # HIMMEL-3676 (J1322A, Minor 4): anchored to the WHOLE line, not a
            # bare substring — "round-guard-cli: v1" used to also match a
            # hypothetical future "round-guard-cli: v10" build.
            case $'\n'"$out"$'\n' in
                *$'\n'"round-guard-cli: v1"$'\n'*) ;;
                *)
                    printf 'guard-implementor-dispatch: REFUSED (round guard, HIMMEL-3681): the reviewed-round probe exited 0 without its version sentinel ("round-guard-cli: v1") for %s — a version-skewed or stale round-guard.ts cannot be trusted to have evaluated the predicate for this implementor dispatch. Output: %s\n' "$label" "$out" >&2
                    rm -f "$round_task_path" 2>/dev/null
                    exit 2
                    ;;
            esac
            [ -n "$out" ] && warn "$out"
            ;;
        2)
            printf '%s\n' "$out" >&2
            rm -f "$round_task_path" 2>/dev/null
            exit 2
            ;;
        *)
            printf 'guard-implementor-dispatch: REFUSED (round guard, HIMMEL-1568): the reviewed-round predicate did not finish cleanly (rc=%s) for %s — failing CLOSED. Output: %s\n' "$rc" "$label" "$out" >&2
            rm -f "$round_task_path" 2>/dev/null
            exit 2
            ;;
    esac
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

# --- HIMMEL-1568: the reviewed-round guard (HIMMEL-1553) runs at THIS
# chokepoint too, not only in scripts/telegram/spawn-glm.ts / spawn-claudex.ts.
# Those two lanes are dispatched by an operator/console over a separate
# subprocess; a real implementor round is just as often an in-process Agent
# tool call, which reaches neither script (HIMMEL-1568). Control has already
# reached here past every read-only/research/Haiku/lane-exempt-Explore
# classification gate above without exiting, so this dispatch is exactly the
# same "implementation-shaped, not read-only, not research" scope those two
# scripts gate on — applied to the SAME countReviewedRounds()/checkRoundGuard()
# in scripts/telegram/round-guard.ts via a small CLI entry point there (never a
# shell reimplementation): one implementation of "what counts as a reviewed
# round" backs all three dispatch paths.
#
# The dispatch's own worktree is the payload's cwd (.tool_input.cwd // .cwd,
# the same fallback convention used elsewhere in this repo's hooks) — an
# Agent-tool dispatch runs IN the caller's existing branch, unlike
# spawn-glm/spawn-claudex's anonymous own-mode dispatches, which mint a fresh
# branch and so key off --name instead. A payload with no cwd at all cannot be
# attributed to any branch — that is a shape issue, not an infra failure, and
# is skipped here exactly like round-guard.ts's own documented fail-open cases
# (no ticket key, no ledger): allow, without even trying to run bun.
#
# Once a cwd IS given, this stops being "not enough identity to ask the
# question" and becomes a real implementor dispatch this guard must answer for
# — so from here the direction flips (deliberately the opposite of every other
# probe in this hook): bun missing, round-guard.ts missing, or the CLI not
# finishing cleanly all mean the predicate could not be EVALUATED, and for a
# genuine implementor dispatch that fails CLOSED with a clear, self-serviceable
# message (IMPL_GUARD_DISABLE=1 is the only escape hatch — there is no
# round-guard-specific bypass; the sanctioned unblock is the same INVARIANT:
# section spawn-glm/spawn-claudex already honour).
round_cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
if [ -n "$round_cwd" ]; then
    # HIMMEL-3676: the dispatch text (not the payload cwd) is the ground truth
    # for WHICH branch this implementor round belongs to whenever it names a
    # worktree — a dispatching session's own cwd is routinely the primary
    # checkout (on main, or another branch entirely) while the actual work
    # happens in a linked worktree it names by path. Naming one and failing to
    # resolve its branch (missing dir, not a git repo, detached HEAD) must
    # refuse rather than silently fall back to the payload cwd's own (0-round)
    # branch — that fallback is exactly the wrong-attribution bug this fixes.
    # HIMMEL-3676 (J1322A, Critical): a named worktree branch must be ADDED to
    # the cwd's own branch, never REPLACE it — evaluating only the first
    # named worktree let a dispatch made FROM an already-exhausted worktree
    # become ALLOWED the moment its text named any other same-repo worktree
    # first, because that worktree's (unrelated, usually 0-round) branch
    # silently took over the WHOLE predicate, cwd branch included. So this
    # collects every DISTINCT worktree branch the text names (not just the
    # first) into round_extra_branches and, further down, the predicate runs
    # once for the cwd's own branch and once per named branch, refusing if
    # ANY of them refuses — over-counting is the safe direction for a
    # refusal-only guard.
    #
    # HIMMEL-3676 (codex-2, CR round 2): the trailing worktree-name class
    # excluded "." (e.g. "fix.himmel-9016"), which rejected the match
    # entirely instead of recognizing it -- a false-positive refusal, not a
    # bypass, since every downstream check (absolute path, own .git,
    # matching git-common-dir) still gates the resolved branch either way.
    # A dot is allowed INSIDE the name but the match may not END on one --
    # dispatch prose routinely ends the sentence naming the path with a
    # literal "." right after it, and a trailing-dot class would swallow
    # that punctuation into the path, making a real worktree unresolvable.
    round_task_file=$(mktemp "${TMPDIR:-/tmp}/himmel-round-guard.XXXXXX" 2>/dev/null) || round_task_file=""
    round_task_path="$round_task_file"
    if [ -n "$round_task_file" ]; then
        printf '%s' "$text" > "$round_task_file" 2>/dev/null || round_task_file=""
    fi
    if [ -z "$round_task_file" ] || ! command -v bun >/dev/null 2>&1 || [ ! -f "$repo_root/scripts/telegram/round-guard.ts" ]; then
        printf 'guard-implementor-dispatch: REFUSED (round guard, HIMMEL-1568): the reviewed-round predicate could not be evaluated for this implementor dispatch (bun missing, scripts/telegram/round-guard.ts missing, or a temp file could not be created; dispatch cwd: %s) — fix the environment and re-dispatch, or IMPL_GUARD_DISABLE=1 to bypass every check in this hook.\n' "$round_cwd" >&2
        [ -n "$round_task_path" ] && rm -f "$round_task_path" 2>/dev/null
        exit 2
    fi
    # HIMMEL-3676 (J1322B NO-GO, Critical): check the cwd's OWN branch FIRST,
    # before the named-worktree loop below. A PreToolUse hook that times out
    # fails OPEN (docs/internals/enforcement.md), and the loop below is O(n)
    # in the number of DISTINCT .claude/worktrees/ path spellings the dispatch
    # text contains -- a pathological prompt with thousands of spellings ran
    # the loop past the 15s hook timeout (measured ~17s), turning a dispatch
    # main REFUSES (cwd is an exhausted worktree) into an ALLOW purely by
    # timing the hook out before it ever reached this check. Running the cwd
    # check first means a dispatch main refuses is refused at the SAME speed
    # as on main, no matter what the rest of the text contains.
    _round_check_one "" "the dispatch cwd's own branch"
    round_wt_paths=$(printf '%s' "$text" | grep -oE '[A-Za-z0-9_./+-]*\.claude/worktrees/([A-Za-z0-9_+-]+\.)*[A-Za-z0-9_+-]+' | sort -u || true)
    round_extra_branches=""
    if [ -n "$round_wt_paths" ]; then
        # HIMMEL-3676 (J1322B NO-GO, Critical): bound the loop itself, so the
        # NEW named-worktree check cannot be timed out either. A dispatch
        # naming more than IMPL_GUARD_MAX_WT_PATHS distinct worktree-path
        # spellings refuses outright rather than resolving them all --
        # over-refusing here is the safe direction for a refusal-only guard,
        # and no honest brief spells the same worktree path hundreds of times.
        round_wt_path_count=$(printf '%s\n' "$round_wt_paths" | grep -c . || true)
        round_max_wt_paths="${IMPL_GUARD_MAX_WT_PATHS:-200}"
        if [ "$round_wt_path_count" -gt "$round_max_wt_paths" ]; then
            printf 'guard-implementor-dispatch: REFUSED (round guard, HIMMEL-3676): the dispatch text names %s distinct .claude/worktrees/ paths, over the %s-path bound -- refusing rather than resolving them all (a pathological prompt must not be able to time this guard out into an allow). Raise the bound with IMPL_GUARD_MAX_WT_PATHS, or IMPL_GUARD_DISABLE=1 to bypass every check in this hook.\n' "$round_wt_path_count" "$round_max_wt_paths" >&2
            rm -f "$round_task_path" 2>/dev/null
            exit 2
        fi
        # HIMMEL-3676 (J1322C, Critical): the per-path `git -C "$round_wt_path"
        # rev-parse ...` calls this loop used to run had NO time bound of
        # their own — the path-count bound above caps how MANY paths are
        # resolved, not how LONG resolving one takes. A named path whose
        # `.git/HEAD` (or a gitfile's target gitdir's `HEAD`) is a FIFO blocks
        # `git rev-parse` on open() until Claude Code's own 15s PreToolUse
        # kill, which fails OPEN (docs/internals/enforcement.md) — skipping
        # the lane-routing and bank-guard refusals below. Never `git -C` INTO
        # a path the dispatch text supplies. Resolve every named path against
        # ONE bounded `git -C "$round_cwd" worktree list --porcelain` read on
        # the TRUSTED cwd instead (this also subsumes the old git-common-dir
        # equality check: only same-repo worktrees are ever listed), matching
        # by canonical path (`cd -P`/`pwd -P`, which never opens a file), and
        # run the whole block under a deadline so an unmatched, detached-HEAD
        # or unreadable path — or the deadline itself — REFUSES instead of
        # hanging.
        round_wt_paths_file=$(mktemp "${TMPDIR:-/tmp}/himmel-round-guard.XXXXXX" 2>/dev/null) || round_wt_paths_file=""
        if [ -z "$round_wt_paths_file" ]; then
            printf 'guard-implementor-dispatch: REFUSED (round guard, HIMMEL-3676): could not create a temp file to resolve the named worktree paths — failing CLOSED. IMPL_GUARD_DISABLE=1 to bypass every check in this hook.\n' >&2
            rm -f "$round_task_path" 2>/dev/null
            exit 2
        fi
        printf '%s\n' "$round_wt_paths" > "$round_wt_paths_file"
        round_resolver="$repo_root/scripts/hooks/lib/resolve-worktree-branches.sh"
        round_resolve_budget="${IMPL_GUARD_WT_RESOLVE_BUDGET_SECS:-5}"
        round_resolve_cmd="bash $(printf '%q' "$round_resolver") $(printf '%q' "$round_cwd") $(printf '%q' "$round_wt_paths_file")"
        round_resolve_out=$(_run_bounded "$round_resolve_budget" "$round_resolve_cmd" 0.05); round_resolve_rc=$?
        rm -f "$round_wt_paths_file" 2>/dev/null
        if [ "$round_resolve_rc" -ne 0 ]; then
            printf 'guard-implementor-dispatch: REFUSED (round guard, HIMMEL-3676): resolving the named worktree paths did not finish cleanly (rc=%s, budget %ss) — failing CLOSED rather than risk a hang skipping the checks below.\n' "$round_resolve_rc" "$round_resolve_budget" >&2
            rm -f "$round_task_path" 2>/dev/null
            exit 2
        fi
        while IFS= read -r round_resolve_line; do
            [ -n "$round_resolve_line" ] || continue
            case "$round_resolve_line" in
                "BRANCH "*)
                    round_wt_branch=${round_resolve_line#BRANCH }
                    case " $round_extra_branches " in
                        *" $round_wt_branch "*) ;;
                        *) round_extra_branches="$round_extra_branches $round_wt_branch" ;;
                    esac
                    ;;
                "UNRESOLVED "*)
                    printf 'guard-implementor-dispatch: REFUSED (round guard, HIMMEL-3676): the dispatch names worktree %s but its branch could not be resolved (missing directory, not a git repo, not this repository, or detached HEAD) — the reviewed-round predicate cannot be safely attributed. Fix the worktree reference and re-dispatch, or IMPL_GUARD_DISABLE=1 to bypass every check in this hook.\n' "${round_resolve_line#UNRESOLVED }" >&2
                    rm -f "$round_task_path" 2>/dev/null
                    exit 2
                    ;;
            esac
        done <<< "$round_resolve_out"
    fi
    if [ -n "$round_extra_branches" ]; then
        for round_extra_branch in $round_extra_branches; do
            _round_check_one " --branch $(printf '%q' "$round_extra_branch")" "worktree branch $round_extra_branch"
        done
    fi
    rm -f "$round_task_path" 2>/dev/null
fi

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
