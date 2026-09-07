#!/usr/bin/env bash
# dependency-readiness.sh — read-only WARN-only readiness gate for skills that
# depend on an external API key (HIMMEL-1393).
#
# Sourced by /himmel-doctor C17 (scripts/himmel-doctor.sh) and by
# himmel-update's dependency-readiness advisory step (scripts/himmel-update.sh).
# Exposes:
#   dependency_readiness_scan  — declaration-map-driven presence check, both
#                                 drift directions, emits READY-DRIFT lines.
#
# Motivating case (2026-07-29 skill-hygiene audit, HIMMEL-1393): a
# `~/.config/obsidian-second-brain/.env` credentials file had existed for six
# weeks while `docs/tooling-catalog.md` still called the research toolkit
# "disabled" — a stale doc misinforming an entire investigation into whether
# `/x-read` was safe to keep. That investigation then found the credentials
# file itself was presence-without-validity: no active XAI/Perplexity
# subscription behind it. So **presence-only checking is the floor here, not
# a guarantee the key actually works** — a cheap opt-in validity probe (hit a
# free/cheap endpoint) is deliberately deferred to a follow-up ticket, not
# built into this default path. No network calls happen in this file.
#
# Declaration map is a pipe-delimited table (Bash 3.2-safe — no associative
# arrays): <skill-command-name>|<required-env-key>|<catalog-grep-term>.
# Extend this table when a new external-API-backed skill/command lands.
#
# SOURCEABLE-only: no `set -e`, no side effects at source time.

DEPENDENCY_READINESS_MAP='
x-read|XAI_API_KEY|XAI
x-pulse|XAI_API_KEY|XAI
youtube|XAI_API_KEY|XAI
research|PERPLEXITY_API_KEY|Perplexity
research-deep|PERPLEXITY_API_KEY|Perplexity
notebooklm|GEMINI_API_KEY|Gemini
'

# dependency_readiness_scan — env seams (all overridable, for tests and for
# the himmel-update advisory step which runs outside CLAUDE_DIR/REPO_ROOT's
# himmel-doctor.sh defaults):
#   DEP_READY_COMMANDS_DIR  default: ${CLAUDE_DIR:-$HOME/.claude}/commands
#   DEP_READY_ENV_FILE      default: $HOME/.config/obsidian-second-brain/.env
#   DEP_READY_CATALOG       default: ${REPO_ROOT:-.}/docs/tooling-catalog.md
# Prints one line per finding, nothing when clean:
#   READY-DRIFT key-missing <skill> <key>   — skill enabled, key absent/blank
#   READY-DRIFT doc-disabled <skill> <key>  — skill enabled+keyed, but a doc
#                                              still calls its toolkit disabled
# Never exits non-zero and never prints a key VALUE — presence checks only.
dependency_readiness_scan() {
    local cmds_dir env_file catalog
    cmds_dir="${DEP_READY_COMMANDS_DIR:-${CLAUDE_DIR:-$HOME/.claude}/commands}"
    env_file="${DEP_READY_ENV_FILE:-$HOME/.config/obsidian-second-brain/.env}"
    catalog="${DEP_READY_CATALOG:-${REPO_ROOT:-.}/docs/tooling-catalog.md}"

    local skill key term cmd_file keyed
    while IFS='|' read -r skill key term; do
        [ -n "$skill" ] || continue
        cmd_file="$cmds_dir/$skill.md"
        [ -f "$cmd_file" ] || continue   # not enabled here — nothing to check

        # Present means non-blank after stripping a single layer of optional
        # quotes: KEY="" and KEY="   " (quoted-empty / quoted-whitespace)
        # must count as missing, same as bare KEY=.
        keyed=0
        if [ -f "$env_file" ] && grep -qE "^${key}=.+" "$env_file" 2>/dev/null \
            && ! grep -qE "^${key}=[\"']?[[:space:]]*[\"']?\$" "$env_file" 2>/dev/null; then
            keyed=1
        fi

        if [ "$keyed" -eq 0 ]; then
            echo "READY-DRIFT key-missing $skill $key"
            continue
        fi

        # Direction 2: enabled + keyed, but a doc still claims the toolkit is
        # disabled — the "ready-but-disabled" drift this ticket exists to
        # catch (docs/tooling-catalog.md's stale line, 2026-06-12..2026-07-29).
        # Requires "disabled" + "toolkit" + the key term all on the SAME line
        # (the real bug's exact shape: "**Research toolkit:** disabled (needs
        # XAI...)"). A looser same-line "disabled"+term-only match false-
        # positived on this doc's unrelated CR-critic-panel prose, which
        # happens to mention both "gemini" and "disabled" in one paragraph.
        if [ -f "$catalog" ] && grep -i "disabled" "$catalog" 2>/dev/null | grep -i "toolkit" | grep -qi "$term"; then
            echo "READY-DRIFT doc-disabled $skill $key"
        fi
    done <<EOF
$DEPENDENCY_READINESS_MAP
EOF
    return 0
}
