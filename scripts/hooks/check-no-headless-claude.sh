#!/usr/bin/env bash
# Pre-commit gate (pre-commit framework, not Claude PreToolUse).
#
# Refuses commits that introduce `claude -p` / `claude --print` / Agent
# SDK invocations into executable code paths. From 2026-06-15 onward
# Anthropic splits headless mode (`claude -p`, Agent SDK, `--bg`) onto
# a separate monthly Agent SDK credit bucket on Max subscriptions;
# interactive `claude "$prompt"` invocations (no `-p`, no `--print`,
# no `--bg`) stay on the regular Max quota.
#
# arm-resume.sh + similar cron-spawned `claude "..."` shells are fine —
# they're interactive. New `claude -p` introductions in scripts will
# start eating a separate credit bucket silently from 06-15 onward
# unless they're an explicit Agent SDK billing decision.
#
# Catches the case where a contributor (human or agent) adds a
# `claude -p` call without realising the billing split. Allows
# intentional Agent SDK use via an opt-in marker on the same line
# OR the line immediately preceding the call:
#
#     # headless-claude-ok: <reason>
#     claude --print "$prompt"
#
# Exit codes:
#   0 — clean (no headless calls in non-exempt staged files)
#   1 — headless call(s) found without opt-in marker
set -uo pipefail

# Pattern: `claude` followed by whitespace and `-p` (word-bounded) or
# `--print` or `--bg`. `\b` is GNU-only; use `($|[^A-Za-z0-9_-])` for
# portable right-anchoring so `claude --printer` doesn't match.
#
# Left side: require `claude` to be at the start of a word (not part
# of an identifier like `myclaude`). Match command-position patterns
# only: `\bclaude\b` followed by space-then-flag.
PATTERN='(^|[^A-Za-z0-9_-])claude[[:space:]]+(-p|--print|--bg)($|[^A-Za-z0-9_-])'

# Self-test: a known-positive sample must match. Catches accidental
# regex de-anchoring or syntax break before the gate quietly approves
# every commit.
if ! printf 'claude -p "test"\n' | grep -E "$PATTERN" >/dev/null 2>&1; then
    echo "check-no-headless-claude: PATTERN failed self-test — refusing" >&2
    exit 1
fi

# Files exempt from the check. Repo-relative path match (not basename)
# so an attacker can't drop an evil file at any path with an exempt
# basename. Exemptions cover:
#   - this hook + its smoke test (talk about the pattern)
#   - docs/ + handovers/ + CLAUDE.md + AGENTS.md (documentation/anti-recommendations;
#     AGENTS.md is generated from CLAUDE.md, HIMMEL-471)
#   - .agents/ (vendored caveman skills — upstream code, can't modify)
#   - .claude/commands/*.md (slash-command docs, often anti-recommend)
is_exempt() {
    case "$1" in
        scripts/hooks/check-no-headless-claude.sh) return 0 ;;
        scripts/hooks/test-check-no-headless-claude.sh) return 0 ;;
        CLAUDE.md) return 0 ;;
        AGENTS.md) return 0 ;;
        docs/*) return 0 ;;
        handovers/*) return 0 ;;
        .agents/*) return 0 ;;
        .claude/commands/*.md) return 0 ;;
        *) return 1 ;;
    esac
}

# Opt-in marker on the same line OR the line immediately preceding the
# match line (`# headless-claude-ok: <reason>`). Both forms allow a
# contributor to intentionally introduce a headless call when they've
# accepted the post-2026-06-15 Agent SDK billing implications.
has_optin_marker() {
    local file="$1" line_no="$2"
    # Same-line marker (comment on the call line itself)
    if sed -n "${line_no}p" "$file" 2>/dev/null | grep -q 'headless-claude-ok'; then
        return 0
    fi
    # Preceding-line marker (within 1 line above the call)
    if [ "$line_no" -gt 1 ]; then
        if sed -n "$((line_no - 1))p" "$file" 2>/dev/null | grep -q 'headless-claude-ok'; then
            return 0
        fi
    fi
    return 1
}

# pre-commit framework passes staged filenames as argv (pass_filenames
# true). Fall back to a staged-diff name list if argv is empty so the
# hook also works when invoked standalone.
files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
    mapfile -t files < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
fi
[ "${#files[@]}" -eq 0 ] && exit 0

violations=()
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    is_exempt "$f" && continue

    # grep -n prints lineno:line; iterate matches to check opt-in marker
    # per-match so a single intentional call doesn't waive others.
    while IFS=: read -r line_no _; do
        [ -z "$line_no" ] && continue
        if ! has_optin_marker "$f" "$line_no"; then
            violations+=("$f:$line_no")
        fi
    done < <(grep -En "$PATTERN" -- "$f" 2>/dev/null)
done

if [ "${#violations[@]}" -gt 0 ]; then
    {
        echo "check-no-headless-claude: headless 'claude -p' / '--print' / '--bg' call(s) without opt-in marker:"
        for v in "${violations[@]}"; do
            echo "    $v"
        done
        echo ""
        echo "From 2026-06-15 onward, headless Claude Code invocations bill on a"
        echo "separate Agent SDK credit bucket (Max subscriptions). Interactive"
        echo "  claude \"\$prompt\""
        echo "still bills on the regular Max quota — prefer that when launching"
        echo "from cron/at/schtasks (arm-resume pattern) or any script."
        echo ""
        echo "If this call is intentional (Agent SDK billing accepted, or you"
        echo "need stdout for the response), add an opt-in marker on the same"
        echo "line or the line immediately above:"
        echo "    # headless-claude-ok: <one-line reason>"
        echo "    claude --print \"\$prompt\""
        echo ""
        echo "Refs: HIMMEL-128. Cite https://code.claude.com/docs/en/headless.md"
        echo "and https://code.claude.com/docs/en/authentication.md."
    } >&2
    exit 1
fi
