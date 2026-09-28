#!/usr/bin/env bash
# PermissionDenied hook (HIMMEL-3724 §4c): appends one redacted JSON line per
# denial to ~/.himmel/state/classifier-denials.jsonl, so tick.sh can surface a
# classifier denial as an operator-visible event instead of a silent
# re-dispatch.
#
# WHY: classifier denials currently surface only when a leg happens to report
# them, and consoles were re-dispatching fresh legs on the same denial
# repeatedly. This is the capture half of §4c; detection (tick.sh `denials=`)
# and action (page + re-dispatch refusal) are separate, later steps.
#
# This is an OBSERVABILITY TAP, same contract as scripts/trust/shadow-ledger.mjs
# on the same event: it must NEVER block, delay, or `ask` on a tool call, so it
# fails open on every error path (missing jq, unparseable JSON, unwritable
# state dir) and always exits 0. A hook bug here must never park a leg.
#
# Hook input arrives on stdin as JSON (session_id, cwd, tool_name, tool_input,
# denial_reason, ...). Nothing here writes unredacted command text: input_head
# is capped to 200 chars and passed through redact() first, and input_sha
# hashes a NORMALISED copy (SHAs collapsed, whitespace squeezed) rather than
# the raw bytes.
set -uo pipefail
trap 'exit 0' EXIT

OUT="${HIMMEL_CLASSIFIER_DENIALS_LOG:-$HOME/.himmel/state/classifier-denials.jsonl}"

command -v jq >/dev/null 2>&1 || exit 0

input=""
IFS= read -r -d '' input 2>/dev/null || true
[ -n "$input" ] || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || exit 0
denial_reason=$(printf '%s' "$input" | jq -r '.denial_reason // ""' 2>/dev/null) || exit 0
tool_input_flat=$(printf '%s' "$input" | jq -r '[.tool_input // {} | .. | strings] | join(" ")' 2>/dev/null) || exit 0

[ -n "$tool" ] || exit 0

# Redacts common secret shapes before ANY of this text is written to disk.
# Not a full gitleaks port (that ruleset is upstream-maintained and huge) —
# a bounded set of the shapes most likely to appear in a denied command:
# GitHub/Slack/Telegram tokens, AWS keys, PEM key blocks, bearer auth headers,
# and a generic key/secret/token/password assignment.
redact() {
    printf '%s' "$1" | sed -E \
        -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED]/g' \
        -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
        -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
        -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
        -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
        -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[REDACTED]/g' \
        -e 's/([Bb]earer) [A-Za-z0-9._-]{20,}/\1 [REDACTED]/g' \
        -e 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])([\"'"'"']?[[:space:]]*[:=][[:space:]]*[\"'"'"']?)[A-Za-z0-9._/+=-]{12,}/\1\2[REDACTED]/g' \
        | awk '
            BEGIN { inkey = 0 }
            {
                line = $0
                if (!inkey && line ~ /-----BEGIN[A-Z ]*PRIVATE KEY-----/) {
                    if (line ~ /-----END[A-Z ]*PRIVATE KEY-----/) {
                        sub(/-----BEGIN[A-Z ]*PRIVATE KEY-----.*-----END[A-Z ]*PRIVATE KEY-----/, "[REDACTED-PEM]", line)
                        print line
                        next
                    }
                    sub(/-----BEGIN[A-Z ]*PRIVATE KEY-----.*/, "[REDACTED-PEM]", line)
                    print line
                    inkey = 1
                    next
                }
                if (inkey) {
                    if (line ~ /-----END[A-Z ]*PRIVATE KEY-----/) inkey = 0
                    next
                }
                print line
            }
        '
}

# The reason tag is the bracketed classifier category, e.g.
# "[Out-of-Place Publication]" — observed empirically across the 172 mined
# denials (design doc §4c). Redact the WHOLE denial_reason first (a
# classifier denial_reason, bracketed or not, can itself quote the offending
# command text back — a secret can land inside the brackets too), then
# extract the bracket from the redacted copy, falling back to the redacted
# text capped like input_head, then to "unknown", so an unrecognised shape
# still lands a row instead of vanishing.
denial_reason_redacted=$(redact "$denial_reason")
reason_tag=$(printf '%s' "$denial_reason_redacted" | grep -oE '\[[^]]+\]' | head -1)
if [ -z "$reason_tag" ]; then
    reason_tag="$denial_reason_redacted"
fi
if [ -z "$reason_tag" ]; then
    reason_tag="unknown"
fi
# Cap every field going into the row, not just input_head: denial_reason (and
# so a bracket match on it) is classifier/reviewer text, not bounded by us,
# and the row-fits-in-PIPE_BUF atomic-append claim below only holds if every
# field is actually short.
reason_tag=$(printf '%s' "$reason_tag" | cut -c1-200)
cwd=$(printf '%s' "$cwd" | cut -c1-400)
session_id=$(printf '%s' "$session_id" | cut -c1-200)

# Collapses git-SHA-shaped tokens and squeezes whitespace so two calls that
# differ only by a commit sha or incidental spacing hash identically — this is
# what lets tick.sh's REPEAT class notice "this exact call already ran once".
normalize() {
    printf '%s' "$1" | sed -E 's/\b[0-9a-f]{40}\b/<SHA>/g' | tr -s '[:space:]' ' '
}

normalized=$(normalize "$tool_input_flat")
redacted=$(redact "$tool_input_flat")
input_head=$(printf '%s' "$redacted" | tr '\n\r' '  ' | cut -c1-200)

input_sha=$(printf '%s' "$normalized" | sha256sum 2>/dev/null | cut -d' ' -f1)
[ -n "$input_sha" ] || exit 0

# Best-effort leg name: a worktree cwd carries its own slug
# (.claude/worktrees/<slug>); anything else falls back to the cwd's basename.
# No lookup against the session registry — this tap must stay cheap and fail
# open, never shell out to something that can hang.
case "$cwd" in
    */worktrees/*)
        session_title=$(printf '%s' "${cwd##*/worktrees/}" | cut -d/ -f1)
        ;;
    *)
        session_title=$(basename "$cwd" 2>/dev/null || printf '')
        ;;
esac

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$OUT")" 2>/dev/null || exit 0

# A single jq -c line is well under PIPE_BUF (4096 bytes): input_head,
# reason_tag, cwd and session_id are all explicitly capped above (not just
# "usually short" — denial_reason and cwd are classifier/session text, not
# bounded by us), so a plain O_APPEND >> is atomic against concurrent legs
# without needing a lock.
jq -n -c \
    --arg ts "$ts" \
    --arg session_id "$session_id" \
    --arg session_title "$session_title" \
    --arg cwd "$cwd" \
    --arg tool "$tool" \
    --arg reason_tag "$reason_tag" \
    --arg input_sha "$input_sha" \
    --arg input_head "$input_head" \
    '{ts:$ts, session_id:$session_id, session_title:$session_title, cwd:$cwd, tool:$tool, reason_tag:$reason_tag, input_sha:$input_sha, input_head:$input_head}' \
    >> "$OUT" 2>/dev/null || exit 0

exit 0
