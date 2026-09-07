#!/usr/bin/env bash
# Pre-commit gate: the root CLAUDE.md stays under its always-on byte budget
# (HIMMEL-2038).
#
# Why a gate and not a rule: CLAUDE.md is the only preload block paid on all
# three harnesses (Claude Code loads it directly; Codex and Hermes load the
# AGENTS.md generated from it), so every byte is charged on every session of
# every lane. The surface re-accretes — each new rule looks cheap on its own and
# the file grew 19 KB before anyone measured it. A number that is enforced does
# not get re-argued; an aspirational one does. Budget is deliberately generous:
# it refuses growth, it does not force a rewrite.
#
# The `## graphify` section is UPSTREAM-OWNED (operator ruling 2026-08-23):
# `graphify install --platform claude` writes it and rewrites it verbatim on
# every install/upgrade (graphifyy install.py: claude_install ->
# _replace_or_append_section — replace the section in place when a line is
# exactly `## graphify`, else append at EOF). himmel does not edit that text,
# so the budget counts ONLY the bytes OUTSIDE it: the section is excluded with
# the installer's own boundary rule (heading = a line that strips to exactly
# `## graphify`; section runs to the next column-zero `## ` heading, or EOF).
# Two sanity assertions remain: exactly one graphify section (zero means the
# installer anchor was deleted and the next install will append it back at a
# place of ITS choosing; more than one means a pre-#1688 duplicate the
# installer's replace-last semantics will never clean up), and the remainder
# under budget.
#
# Usage:
#   check-claude-md-budget.sh            # gate mode: checks the STAGED CLAUDE.md
#   check-claude-md-budget.sh <file>     # check a file directly (ad hoc / tests)
#
# Env: CLAUDE_MD_MAX_BYTES overrides the limit (used by the test suite).
# Exit: 0 pass / not applicable · 1 over budget or graphify-section count != 1 ·
# 2 cannot evaluate (fail-closed).
set -euo pipefail

MAX_BYTES="${CLAUDE_MD_MAX_BYTES:-12288}"   # 12 KiB, himmel content only

case "$MAX_BYTES" in
    ''|*[!0-9]*) echo "→ claude-md-budget: CLAUDE_MD_MAX_BYTES must be an integer, got '$MAX_BYTES'" >&2; exit 2 ;;
esac

# ── Resolve the content to check into a temp file ────────────────────────────
tmp="$(mktemp "${TMPDIR:-/tmp}/claude-md-budget.XXXXXX")" || { echo "→ claude-md-budget: mktemp failed — fail-closed" >&2; exit 2; }
trap 'rm -f "$tmp"' EXIT

if [ "$#" -gt 0 ]; then
    # Direct-file mode: no git, no himmel-dev gating.
    file="$1"
    [ -f "$file" ] || { echo "→ claude-md-budget: no such file: $file" >&2; exit 2; }
    cp "$file" "$tmp"
    label="$file"
else
    # ── Gate mode ────────────────────────────────────────────────────────────
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

    # himmel-dev only: an adopter who vendored the repo maintains their own
    # CLAUDE.md and never agreed to this budget. Use the shared resolver, not a
    # bare `[ -f .himmel-dev ]` — the marker is gitignored and lives in the
    # PRIMARY checkout, so a naive test silently no-ops in every worktree (i.e.
    # in exactly the place feature work happens). Mirrors check-debrand-coverage.
    # shellcheck source=scripts/guardrails/lib.sh
    # shellcheck disable=SC1091
    . "$REPO_ROOT/scripts/guardrails/lib.sh"
    rc=0
    # shellcheck disable=SC2119  # deliberately called with no args to use its DIR default (.)
    is_himmel_dev_repo || rc=$?
    # `if`, not `[ … ] && exit 0` — under errexit a false test makes the
    # compound return 1 and kills the script with a bogus failure.
    if [ "$rc" -eq 1 ]; then exit 0; fi

    # Only relevant when the repo-root CLAUDE.md is staged. A git failure is NOT
    # "nothing staged" — swallowing it would turn an unreadable index into a
    # silent pass, the opposite of fail-closed.
    if ! staged="$(git diff --cached --name-only 2>/dev/null)"; then
        echo "→ claude-md-budget: cannot inspect staged paths — fail-closed" >&2; exit 2
    fi
    # here-string, not a pipe: `| grep -q` under pipefail can SIGPIPE the
    # producer and invert the guard (HIMMEL-1430); the staged list is tiny.
    grep -qx 'CLAUDE.md' <<< "$staged" || exit 0

    # The STAGED blob, byte-exact — no `$(…)` capture (it strips trailing
    # newlines and would miscount).
    if ! git show :CLAUDE.md > "$tmp" 2>/dev/null; then
        echo "→ claude-md-budget: cannot read staged CLAUDE.md — fail-closed" >&2; exit 2
    fi
    label="CLAUDE.md (staged)"
fi

fail=0

# ── Sanity: exactly one graphify section ─────────────────────────────────────
# Same heading match as the installer's `line.strip() == "## graphify"`.
n_sections="$(LC_ALL=C awk '/^[[:space:]]*## graphify[[:space:]]*$/ { n++ } END { print n + 0 }' "$tmp")"
if [ "$n_sections" -gt 1 ]; then
    echo "→ claude-md-budget: $label carries $n_sections '## graphify' headings — the installer replaces only the LAST one, so duplicates never self-heal. Remove the extra section(s), keeping the last (installer-written) copy." >&2
    fail=1
elif [ "$n_sections" -eq 0 ]; then
    echo "→ claude-md-budget: $label has no '## graphify' section. It is graphify's installer anchor (upstream-owned); restore it with: graphify install --platform claude" >&2
    echo "→ claude-md-budget: then re-price the hooks: bash scripts/lib/graphify-bin.sh price-hooks" >&2
    fail=1
fi

# ── Budget: count ONLY himmel's own bytes (graphify section excluded) ────────
# The exclusion is positional, not content-verified — deliberately: verifying
# "installer-owned" text would mean pinning upstream's wording, the exact fight
# the upstream-owned ruling ended. Smuggling himmel rules into the section to
# dodge the budget buys nothing durable: the next `graphify install` REPLACES
# the whole section and deletes them, and any CLAUDE.md diff is review-gated.
# awk's `print` re-adds the record newline, so a file whose LAST counted line
# lacks a final newline is counted one byte high — conservative (fails closed
# at the exact boundary, never a false pass), and moot for committed files:
# end-of-file-fixer normalizes them.
counted="$(LC_ALL=C awk '
    /^[[:space:]]*## graphify[[:space:]]*$/ { skip = 1; next }
    skip && /^## /                          { skip = 0 }
    !skip                                   { print }
' "$tmp" | wc -c)"
counted=${counted//[!0-9]/}
total="$(wc -c < "$tmp")"
total=${total//[!0-9]/}

if [ "$counted" -gt "$MAX_BYTES" ]; then
    echo "→ claude-md-budget: $label is ${counted} B of himmel content (file total ${total} B; the upstream '## graphify' section is excluded), over the ${MAX_BYTES} B always-on budget (+$((counted - MAX_BYTES)))." >&2
    echo "  CLAUDE.md is paid on every session of every harness. Demote the new rule instead of growing the file:" >&2
    echo "  structurally enforced → name the hook/gate and point at its doc; reference detail → docs/internals/;" >&2
    echo "  operational recovery → docs/internals/stuck-playbook.md. Doctrine: docs/internals/context-architecture.md." >&2
    fail=1
fi

exit "$fail"
