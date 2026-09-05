#!/usr/bin/env bash
# inject-initiative.sh — SessionStart hook for opt-in initiative mode
# (HIMMEL-425; leg grammar + profiles HIMMEL-443).
#
# Gated by an initiative env var (must be set in the shell that LAUNCHED Claude
# — bypass convention per scripts/hooks/CLAUDE.md; a per-call prefix does NOT
# reach the hook process). When active, the session is given a scoped "drive to
# ship" directive so a normal session proactively advances the work through its
# active legs at natural completion points, without the operator saying "ship
# it" each time.
#
# Leg grammar (single source of truth: scripts/lib/initiative-legs.sh). The
# value is either a master switch (1/true/on/yes/all) or a comma-separated
# subset of the 8-leg vocabulary
# `plan,execute,prcheck,pr,ticket,merge,public,handover` (`plan` is a reserved
# token with no behavior yet). Parsing is case-insensitive, whitespace-tolerant,
# deduped; unknown tokens are ignored; steps always render in canonical order.
# The directive echoes the recognized tokens (`Active steps: …`) so a typo is
# visible.
#
# Profiles (selected by HIMMEL_OVERNIGHT):
#   - interactive (default): var = HIMMEL_INITIATIVE,           `all` = prcheck,pr,ticket,handover
#   - overnight (selector):  var = HIMMEL_INITIATIVE_OVERNIGHT, `all` = execute,prcheck,pr,ticket,merge,handover
#
# Default: OFF. Exit silently when the env is unset, falsy, or resolves to no
# recognized leg — behaviour then is byte-identical to a session without the
# directive.
#
# This is ADVISORY injected context, not a permission change: it cannot widen
# what the hooks allow. The safety rails still HARD-block (check-cr-marker-on-
# pr-create gates gh pr create; the persistence classifier vetoes reactive
# --amend and settings.json self-edits; the `merge` leg is advisory — branch
# protection still applies; the exfil classifier still blocks public push).
#
# Hook contract (SessionStart):
#   - Reads the SessionStart JSON payload from stdin. Only session_id is
#     consumed (per-session-start dedup below, HIMMEL-813); no other field
#     is read.
#   - Exit 0 with stdout → stdout is injected as additional context.
#   - Non-zero exit → would surface an error; we never block, only ever exit 0.
#
# Double-fire dedup (HIMMEL-813): this script is wired at BOTH user scope
# (~/.claude/settings.json) and project scope (.claude/settings.json), so a
# single SessionStart event fires it twice within seconds, doubling the
# directive. Dedup is keyed on session_id with a ~60s FRESHNESS WINDOW, not a
# once-per-session-id-ever marker: a resume/clear later in the SAME
# session_id fires SessionStart again, and compaction may have dropped the
# directive from context by then, so that later fire must still re-inject. A
# marker younger than the window means "this is the duplicate of the two
# near-simultaneous registrations for the same session-start event" (stay
# silent); a marker older than the window means "this is a later, distinct
# session-start event" (refresh + re-inject). See the marker/mkdir block
# below for the atomicity + timestamp-freshness mechanics. Missing or
# unparseable session_id skips dedup entirely and always injects (fail-open
# — this hook must never suppress its own output on its own bugs).
#
# Wiring (in .claude/settings.json):
#   {
#     "hooks": {
#       "SessionStart": [
#         { "hooks": [ { "type": "command",
#                        "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/inject-initiative.sh"
#                      } ] }
#       ]
#     }
#   }

set -euo pipefail

# Always exit clean; never block session start.
trap 'exit 0' ERR

# Drain stdin so the hook contract doesn't break the runtime if it pipes a
# payload. Captured (not merely discarded) so session_id can be pulled out
# below for the per-session-start dedup marker (HIMMEL-813).
_ii_payload=""
if [ -t 0 ]; then
    :
else
    _ii_payload=$(cat 2>/dev/null) || true
fi

# --- Source the himmel clone's .env for the initiative vars (R1, HIMMEL-460) -
# The hook reads HIMMEL_INITIATIVE* from the process env, but a session launched
# from a shell that never exported them (and without a settings.json `env` block)
# would see no legs. Populate them from the himmel clone's .env — but ONLY for
# vars not already set (process env / settings.json env still wins; load_dotenv is
# non-clobbering). Resolve the himmel root EXPLICITLY (HIMMEL_REPO, else the git
# toplevel of THIS hook script) and never trust the CWD: a session launched inside
# a DIFFERENT git repo must not read that repo's .env. Fail-open on any miss.
_ii_root="${HIMMEL_REPO:-}"
if [ -z "$_ii_root" ]; then
    _ii_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null) || _ii_root=""
fi
if [ -n "$_ii_root" ] && [ -f "$_ii_root/.env" ]; then
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/load-dotenv.sh"
    load_dotenv --root "$_ii_root" HIMMEL_INITIATIVE HIMMEL_OVERNIGHT HIMMEL_INITIATIVE_OVERNIGHT || true
fi

# --- Resolve the active legs via the shared resolver (HIMMEL-443) -----------
# The leg grammar lives in ONE place: scripts/lib/initiative-legs.sh. We pass
# the relevant env vars as named arguments (the resolver never reads ambient
# env) and get back the normalized, canonical-ordered, deduped active leg set.
# Profile is selected by HIMMEL_OVERNIGHT: truthy → read HIMMEL_INITIATIVE_OVERNIGHT
# (overnight `all` = 6 legs), else HIMMEL_INITIATIVE (interactive `all` = legacy 4).
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../lib/initiative-legs.sh"

active=$(resolve_legs "${HIMMEL_INITIATIVE:-}" "${HIMMEL_INITIATIVE_OVERNIGHT:-}" "${HIMMEL_OVERNIGHT:-}")
# Off when nothing resolved (unset / falsy / all-unknown subset).
[ -n "$active" ] || exit 0

# --- Per-session-start dedup (HIMMEL-813) -----------------------------------
# Only reached once we know we're about to inject (the OFF path above already
# exited silently, so there is nothing to dedup there). Extraction mirrors
# the jq-first / grep -oP-fallback convention used elsewhere in this dir
# (scripts/hooks/block-cheap-lane-pr-without-verdict.sh's extract_command).
_ii_extract_session_id() {
    local input="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.session_id // empty' <<<"$input" 2>/dev/null
        return
    fi
    echo "$input" | grep -oP '"session_id"\s*:\s*"(\\.|[^"\\])*"' \
        | head -1 \
        | sed -E 's/^"session_id"\s*:\s*"(.*)"$/\1/' \
        | sed 's/\\"/"/g'
}

_ii_sid=$(_ii_extract_session_id "$_ii_payload" || true)
# Sanitize to a safe path component (session_id is normally a UUID; belt for
# any stray path-hostile characters reaching the marker directory name).
_ii_sid_safe=$(printf '%s' "$_ii_sid" | tr -c 'A-Za-z0-9._-' '-')

if [ -n "$_ii_sid_safe" ]; then
    _ii_window=60
    _ii_now=$(date +%s)
    _ii_marker_dir="${TMPDIR:-/tmp}/himmel-inject-initiative-${_ii_sid_safe}"
    _ii_ts_file="$_ii_marker_dir/ts"

    if mkdir "$_ii_marker_dir" 2>/dev/null; then
        # Won the mkdir race: first of the (likely two) near-simultaneous
        # firings for this session-start event. Stamp and proceed to inject.
        printf '%s\n' "$_ii_now" >"$_ii_ts_file" 2>/dev/null || true
    else
        # Lost the mkdir race (or this is a later, distinct fire): read the
        # existing timestamp numerically — never stat -c/-f (GNU/BSD differ).
        _ii_ts=$(head -1 "$_ii_ts_file" 2>/dev/null || true)
        case "$_ii_ts" in
            ''|*[!0-9]*)
                # Timestamp missing or unparseable. Two different causes:
                # (1) this read raced the winner's write - resolves in <1s;
                # (2) an orphaned/corrupted marker (winner killed pre-write,
                #     temp-cleaner swept the file but not the dir). Case (2)
                #     must NOT go silent - it would suppress the directive
                #     for this session_id forever. Retry once, then fail OPEN.
                sleep 1
                _ii_ts=$(head -1 "$_ii_ts_file" 2>/dev/null || true)
                ;;
        esac
        case "$_ii_ts" in
            ''|*[!0-9]*)
                # Still unreadable after the retry: orphaned/corrupted marker.
                # Fail OPEN - refresh the stamp and fall through to inject.
                # Worst case is one extra inject, which this dedup exists to
                # reduce, never to buy permanent silence on our own bugs.
                printf '%s\n' "$_ii_now" >"$_ii_ts_file" 2>/dev/null || true
                ;;
            *)
                _ii_age=$(( _ii_now - _ii_ts ))
                if [ "$_ii_age" -ge 0 ] && [ "$_ii_age" -lt "$_ii_window" ]; then
                    exit 0  # duplicate fire of the same session-start event — silent
                fi
                # Stale marker: a later, distinct session-start event
                # (resume/clear) for the same session_id. Refresh the stamp
                # and fall through to re-inject — compaction may have dropped
                # the directive since.
                printf '%s\n' "$_ii_now" >"$_ii_ts_file" 2>/dev/null || true
                ;;
        esac
    fi
fi

# Which var the operator set (named in the pointer, so the profile is visible).
if _il_truthy "${HIMMEL_OVERNIGHT:-}"; then
    _var="HIMMEL_INITIATIVE_OVERNIGHT"
else
    _var="HIMMEL_INITIATIVE"
fi

# Membership test against the active leg set.
has_leg() { case " $active " in *" $1 "*) return 0;; *) return 1;; esac; }

# CSV of recognized tokens for the in-session echo (typo visibility).
_steps_csv=$(printf '%s' "$active" | tr ' ' ',')

# --- Assemble the directive (POINTER form, HIMMEL-2036) ---------------------
# The 3,150-byte runbook used to be injected in full on every session start, on
# both harnesses, whether or not a completion point was ever reached. It now
# lives in scripts/hooks/initiative-runbook.md and this hook emits a ~370-byte
# POINTER — the same treatment inject-where-are-we.sh gives its global digest.
#
# What stays INLINE is the safety-relevant part, and only that: the no-merge
# guard (dropped only when the `merge` leg is explicitly active) and the
# enforcement sentence. Losing the step list to a file costs a read; losing
# "this does not relax any rail" costs a rail. The `Active steps:` echo stays so
# a typo'd token is still visible without opening the runbook.
#
# The runbook path is ABSOLUTE — like inject-where-are-we.sh's latest.md
# pointer. This hook is wired at user scope too, and it reads the himmel clone's
# .env for the gate vars, so a session started in a DIFFERENT repo can be
# initiative-active; a repo-relative path would not resolve there, and a broken
# pointer loses every step body including the merge/public safeguards.
#
# It is resolved from THIS SCRIPT'S OWN directory, not from $_ii_root: the
# runbook is installed as the script's sibling, so the script dir is always
# right, whereas $_ii_root is empty whenever HIMMEL_REPO is unset AND the git
# toplevel lookup fails (a copy installed outside a git checkout, or no git on
# PATH) — which would have emitted a dangling `./scripts/hooks/...`. Same byte
# cost either way (the script's own dir IS <root>/scripts/hooks); this buys
# correctness, not bytes. If even `pwd` fails, fall back to the git root and
# then to the literal relative path: a best-effort pointer beats none, and every
# other line of the directive still renders.
#
# Those bytes are why the enforcement line below states the rail without
# re-listing which rails — the list is in the runbook, and the sentence is what
# has to survive the trip inline.
#
# The read trigger is CONDITIONAL, and that is the whole saving. "Read it first"
# would make every session load the runbook at session start — deferring the
# 3.1 KB rather than removing it. Naming the two moments it is actually needed
# (a completion point; a handover resume, which is when the tasklist-seed
# section applies) means an ordinary session never opens the file at all.
#
# But the DIRECTIVE itself cannot live behind that trigger. "Take initiative at
# a completion point" is what makes a session recognise a completion point at
# all; if it only existed in the runbook, nothing would ever prompt the read and
# the whole feature would vanish silently — the exact no-error regression the
# audit warned this change could cause. So the one-line directive is inline and
# only the step BODIES are deferred.
_ii_rb_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _ii_rb_dir=""
if [ -n "$_ii_rb_dir" ]; then
    _ii_runbook="$_ii_rb_dir/initiative-runbook.md"
elif [ -n "$_ii_root" ]; then
    _ii_runbook="$_ii_root/scripts/hooks/initiative-runbook.md"
else
    _ii_runbook="scripts/hooks/initiative-runbook.md"
fi
printf '<system-reminder>\n%s is active. Active steps: %s\n' "$_var" "$_steps_csv"
printf 'At a completion point (work finished AND verified), run them unasked.\n'
printf 'Step bodies (read then; or now if handover-resumed): %s\n' "$_ii_runbook"
has_leg merge || printf 'Do NOT merge.\n'
printf 'This directive does NOT relax any safety rail.\n'
printf '</system-reminder>\n'

exit 0
