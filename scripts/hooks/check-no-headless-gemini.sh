#!/usr/bin/env bash
# Pre-commit gate (pre-commit framework, not Claude PreToolUse).
#
# Refuses commits that introduce `gemini -p` / `gemini --prompt` / `gemini
# --bg` (headless gemini-cli) invocations into executable code paths. The
# same billing/quota risk that motivated the no-headless-claude gate
# (HIMMEL-128) applies to gemini-cli: headless one-shot runs eat quota
# silently. Interactive `gemini "$prompt"` invocations (no `-p`, no
# `--prompt`, no `--bg`) are the preferred form.
#
# Catches the case where a contributor (human or agent) adds a `gemini -p`
# call without realising the billing/quota implication. Allows intentional
# headless use via an opt-in marker on the same line OR the line
# immediately preceding the call:
#
#     # headless-gemini-ok: <reason>
#     gemini --prompt "$prompt"
#
# Exit codes:
#   0 — clean (no headless calls in non-exempt staged files)
#   1 — headless call(s) found without opt-in marker
set -uo pipefail

# Pattern: `gemini` followed by whitespace and `-p` (word-bounded) or
# `--prompt` or `--bg`. `\b` is GNU-only; use `($|[^A-Za-z0-9_-])` for
# portable right-anchoring so `gemini --prompts` doesn't match.
#
# Left side: require `gemini` to be at the start of a word (not part
# of an identifier like `mygemini`). Match command-position patterns
# only: `\bgemini\b` followed by space-then-flag.
PATTERN='(^|[^A-Za-z0-9_-])gemini[[:space:]]+(-p|--prompt|--bg)($|[^A-Za-z0-9_-])'

# Self-test: a known-positive sample must match. Catches accidental
# regex de-anchoring or syntax break before the gate quietly approves
# every commit.
if ! printf 'gemini -p "test"\n' | grep -E "$PATTERN" >/dev/null 2>&1; then
    echo "check-no-headless-gemini: PATTERN failed self-test — refusing" >&2
    exit 1
fi

# Files exempt from the check. Repo-relative path match (not basename)
# so an attacker can't drop an evil file at any path with an exempt
# basename. Exemptions cover:
#   - this hook + its smoke test (talk about the pattern)
#   - docs/ + handovers/ + CLAUDE.md (documentation/anti-recommendations)
#   - .agents/ (vendored caveman skills — upstream code, can't modify)
#   - .claude/commands/*.md (slash-command docs, often anti-recommend)
is_exempt() {
    case "$1" in
        scripts/hooks/check-no-headless-gemini.sh) return 0 ;;
        scripts/hooks/test-check-no-headless-gemini.sh) return 0 ;;
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
# match line (`# headless-gemini-ok: <reason>`). Both forms allow a
# contributor to intentionally introduce a headless call when they've
# accepted the billing/quota implications.
has_optin_marker() {
    local file="$1" line_no="$2"
    # Same-line marker (comment on the call line itself)
    if sed -n "${line_no}p" "$file" 2>/dev/null | grep -q 'headless-gemini-ok'; then
        return 0
    fi
    # Preceding-line marker (within 1 line above the call)
    if [ "$line_no" -gt 1 ]; then
        if sed -n "$((line_no - 1))p" "$file" 2>/dev/null | grep -q 'headless-gemini-ok'; then
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
        echo "check-no-headless-gemini: headless 'gemini -p' / '--prompt' / '--bg' call(s) without opt-in marker:"
        for v in "${violations[@]}"; do
            echo "    $v"
        done
        echo ""
        echo "Headless gemini-cli invocations eat quota silently. Interactive"
        echo "  gemini \"\$prompt\""
        echo "is the preferred form — prefer that when launching from"
        echo "cron/at/schtasks or any script."
        echo ""
        echo "If this call is intentional (billing/quota accepted, or you"
        echo "need stdout for the response), add an opt-in marker on the same"
        echo "line or the line immediately above:"
        echo "    # headless-gemini-ok: <one-line reason>"
        echo "    gemini --prompt \"\$prompt\""
        echo ""
        echo "Refs: HIMMEL-157 (mirrors HIMMEL-128 no-headless-claude)."
    } >&2
    exit 1
fi
