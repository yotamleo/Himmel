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
#
# ADVISORY (HIMMEL-1867), never blocking: a staged file carrying the opt-in
# marker that never references the native-auth pin gets a stderr WARNING — a
# marked headless site that inherits an ambient ANTHROPIC_BASE_URL is silently
# proxied off native auth (operator ruling 2026-08-17). Advisory because a
# blocking check would gate every pre-existing marked site, including
# graphify's vendored headless calls, which are out of scope for epic
# HIMMEL-1859.
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
#   - .agents/ (harness-neutral skill wrappers — docs, same as .claude/commands)
#   - .claude/commands/*.md (slash-command docs, often anti-recommend)
#   - root CHANGELOG.md (generated from immutable commit subjects by
#     scripts/gen-changelog.sh — it records that a headless call was once
#     discussed/shipped, it can never introduce one, and the opt-in marker
#     can't survive regeneration, HIMMEL-2250)
is_exempt() {
    case "$1" in
        scripts/hooks/check-no-headless-claude.sh) return 0 ;;
        scripts/hooks/test-check-no-headless-claude.sh) return 0 ;;
        CLAUDE.md) return 0 ;;
        AGENTS.md) return 0 ;;
        CHANGELOG.md) return 0 ;;
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
    # bash 3.2-safe (macOS): no mapfile.
    while IFS= read -r _line; do files+=("$_line"); done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
fi
[ "${#files[@]}" -eq 0 ] && exit 0

violations=()
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    if [ ! -r "$f" ]; then
        violations+=("$f:unreadable")
        continue
    fi
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

# ADVISORY (HIMMEL-1867): warn when a staged file carrying the opt-in marker
# never references the native-auth pin (bash lib or PowerShell twin). Warn
# only — the exit code is decided solely by the violations above, so this can
# never gate a pre-existing marked site (graphify's vendored headless calls
# are out of scope for epic HIMMEL-1859).
native_auth_pin_advisory() {
    local f blob
    for f in "${files[@]}"; do
        is_exempt "$f" && continue
        if blob=$(git show ":$f" 2>/dev/null); then
            grep -q 'headless-claude-ok' <<<"$blob" || continue
            # Any reference counts — sourcing the bash lib, dot-sourcing the .ps1
            # twin, or naming either in a comment that says why the site is safe.
            grep -q 'native-auth-pin' <<<"$blob" && continue
        else
            # Direct self-test inputs are real files outside the index.
            [ -f "$f" ] || continue
            grep -q 'headless-claude-ok' -- "$f" 2>/dev/null || continue
            grep -q 'native-auth-pin' -- "$f" 2>/dev/null && continue
        fi
        echo "check-no-headless-claude: ADVISORY - $f carries a '# headless-claude-ok:' marker but never references native-auth-pin; a marked headless site that inherits an ambient ANTHROPIC_BASE_URL is silently proxied off native auth (operator ruling 2026-08-17). Source scripts/lib/native-auth-pin.sh and call native_auth_pin_env before the launch (PowerShell sites: scripts/lib/native-auth-pin.ps1). Advisory only, not blocking." >&2
    done
    return 0
}
native_auth_pin_advisory

if [ "${#violations[@]}" -gt 0 ]; then
    {
        echo "check-no-headless-claude: headless 'claude -p' / '--print' / '--bg' call(s) without opt-in marker:"
        for v in "${violations[@]}"; do
            echo "    $v"
        done
        echo ""
        echo "Headless Claude Code is permitted. Subscription-authenticated"
        echo "'claude -p' draws the SAME 5-hour/weekly bank as interactive use"
        echo "(HIMMEL-1748, measured 2026-08-11/12), so shape is not the cost"
        echo "question."
        echo ""
        echo "For scheduled or unattended use, route through"
        echo "scripts/lib/bank-preflight.sh before spending; parse the outcome"
        echo "with '--output-format json' instead of sniffing prose; and declare"
        echo "an explicit '--permission-mode' (never 'bypassPermissions')."
        echo ""
        echo "This gate verifies marker PRESENCE ONLY. It does not parse the"
        echo "reason; any string passes. The preflight, JSON-output, and"
        echo "permission-mode items above are review-enforced conventions, not"
        echo "structural guarantees."
        echo ""
        echo "The marker remains required to force a pause and documented"
        echo "decision at every new '-p' introduction. Add it with a one-line"
        echo "reason on the same line or the line immediately above:"
        echo "    # headless-claude-ok: <one-line reason>"
        echo "    claude --print \"\$prompt\""
        echo ""
        echo "Refs: HIMMEL-1748; scripts/lib/bank-preflight.sh;"
        echo "docs/internals/enforcement.md#claude-invocation-billing-himmel-128;"
        echo "https://code.claude.com/docs/en/headless.md."
    } >&2
    exit 1
fi
