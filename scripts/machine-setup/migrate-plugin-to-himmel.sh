#!/usr/bin/env bash
# migrate-plugin-to-himmel.sh — switch a plugin's install source from an
# external marketplace to himmel's SHA-pinned @himmel entry (HIMMEL-434).
#
# WHY: himmel vendors some upstream plugins into its own marketplace pinned to a
# reviewed commit SHA (supply-chain policy). If the same plugin is ALSO installed
# from its external marketplace with autoUpdate:true, that auto-updating copy
# shadows the pin — defeating the whole point. This re-points the install at
# @himmel and removes the now-orphaned external marketplace.
#
# WHAT MOVES (config preservation): `claude plugin install <name>@himmel`
# re-creates the enabledPlugins entry under the @himmel key (enabled), so the
# plugin stays enabled across the switch. Plugin-specific state (vault paths,
# .env, etc.) lives outside the marketplace registration and is never touched.
# Only the now-unused external marketplace registration is removed.
#
# RUN THIS OPERATOR-PRESENT, IN A FRESH SESSION. It mutates settings.json via
# `claude plugin` (enabledPlugins + extraKnownMarketplaces); doing it inside the
# session that's also editing plugins risks cache staleness, and agent-side
# settings.json mutation is a self-mod HARD-veto (HIMMEL-429) — so this is an
# operator step, not an autonomous one.
#
# Usage:
#   migrate-plugin-to-himmel.sh [--apply] [--target <name>] <name@market> ...
#     (no flag)        dry-run: print the exact commands, change nothing (default)
#     --apply          actually run the uninstall/install/marketplace-remove
#     --target <name>  destination marketplace name (default: himmel)
#
# Example (migrating claude-obsidian off BOTH stale sources — the fork
# marketplace and the luna vault's bundled luna-brain marketplace — onto @himmel):
#   migrate-plugin-to-himmel.sh --apply \
#     claude-obsidian@claude-obsidian-marketplace claude-obsidian@luna-brain \
#     obsidian@obsidian-skills
set -euo pipefail

TARGET="himmel"
APPLY=0
SPECS=()
INSTALLED_JSON="${HIMMEL_INSTALLED_PLUGINS_JSON:-$HOME/.claude/plugins/installed_plugins.json}"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  APPLY=1; shift ;;
        --target) TARGET="${2:?--target needs a value}"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
        *)  SPECS+=("$1"); shift ;;
    esac
done

[ "${#SPECS[@]}" -gt 0 ] || { echo "ERROR: no <name@market> specs given (see --help)" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI required on PATH" >&2; exit 1; }

run() {
    if [ "$APPLY" -eq 1 ]; then
        echo "RUN: $*"
        "$@"
    else
        echo "DRY: $*"
    fi
}

# ── Migrate each plugin ──────────────────────────────────────────────────────
SOURCES=()
for spec in "${SPECS[@]}"; do
    case "$spec" in
        *@*) ;;
        *) echo "ERROR: spec must be name@market: '$spec'" >&2; exit 2 ;;
    esac
    name="${spec%@*}"
    src="${spec#*@}"
    if [ "$src" = "$TARGET" ]; then
        echo "skip: $spec is already @$TARGET"
        continue
    fi
    echo "──── migrate $name: @$src → @$TARGET ────"
    # uninstall may exit non-zero if it wasn't installed from that source — don't
    # abort the run; the install below is what matters.
    run claude plugin uninstall "$name@$src" || echo "  (uninstall non-zero — not installed from @$src? continuing)"
    run claude plugin install "$name@$TARGET"
    SOURCES+=("$src")
done

# ── Remove now-orphaned external marketplaces ────────────────────────────────
# Only remove a source marketplace if NO installed plugin still resolves through
# it (apply-mode, recomputed live). In dry-run we print the intended removal
# with the caveat, since nothing has actually been uninstalled yet.
if [ "${#SOURCES[@]}" -gt 0 ]; then
    echo "──── orphaned-marketplace cleanup ────"
    # de-dup SOURCES
    UNIQ=$(printf '%s\n' "${SOURCES[@]}" | sort -u)
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        if [ "$APPLY" -eq 1 ] && command -v jq >/dev/null 2>&1 && [ -f "$INSTALLED_JSON" ]; then
            # Count installed specs whose marketplace == $src, by exact suffix
            # match (not grep -c "@$src$" — a marketplace name with a regex
            # metachar like '.' would over/under-match and wrongly keep/remove).
            # tr -d '\r': jq emits CRLF on Windows.
            specs_now=$(jq -r '.plugins | keys[]' "$INSTALLED_JSON" 2>/dev/null | tr -d '\r' || true)
            remaining=0
            while IFS= read -r s; do
                [ -z "$s" ] && continue
                [ "${s##*@}" = "$src" ] && remaining=$((remaining + 1))
            done <<EOF2
$specs_now
EOF2
            if [ "$remaining" -gt 0 ]; then
                echo "  keep: marketplace '$src' still serves $remaining installed plugin(s)."
                continue
            fi
        fi
        run claude plugin marketplace remove "$src" || echo "  (marketplace remove non-zero — already gone? continuing)"
    done <<EOF
$UNIQ
EOF
fi

echo ""
if [ "$APPLY" -eq 1 ]; then
    echo "==> migration applied. RESTART the session to load the @$TARGET copies."
else
    echo "==> dry-run only. Re-run with --apply to execute (operator-present)."
fi
