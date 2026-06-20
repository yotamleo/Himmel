#!/usr/bin/env bash
# Update an existing himmel checkout (HIMMEL-397).
#
# WHY this exists: himmel's marketplace is registered from a LOCAL `directory`
# source (see docs/setup/settings-template.json), so Claude Code's marketplace
# `autoUpdate` only RE-SYNCS plugins from the on-disk dir — it never fetches
# from GitHub. And the core hooks + slash commands aren't plugins at all;
# they run from $CLAUDE_PROJECT_DIR. So `git pull` of THIS checkout is the only
# thing that delivers a himmel update. This wraps the two steps that follow it:
# pull, then refresh the marketplace from the freshly-pulled local dir.
#
# Full model: docs/setup/updating.md.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# ─── plugin install-state gap report (HIMMEL-434) ────────────────────────────
# Advisory: `marketplace update` only re-syncs plugins that are ALREADY
# installed — it never tells you a himmel-marketplace plugin is missing, or is
# being served from a NON-@himmel marketplace whose `autoUpdate` silently
# shadows the himmel SHA pin. This reports both gaps so the operator can install
# / migrate. Best-effort: never fails the update. Both input paths are
# env-overridable (HIMMEL_MARKETPLACE_JSON / HIMMEL_INSTALLED_PLUGINS_JSON) so
# the logic is testable against fixtures.
report_plugin_gap() {
    local market_json="${HIMMEL_MARKETPLACE_JSON:-$ROOT/marketplace/.claude-plugin/marketplace.json}"
    local installed_json="${HIMMEL_INSTALLED_PLUGINS_JSON:-$HOME/.claude/plugins/installed_plugins.json}"

    echo ""
    echo "==> himmel-marketplace plugin install-state"

    if ! command -v jq >/dev/null 2>&1; then
        echo "    skip: jq not on PATH (cannot compute plugin gap)."
        return 0
    fi
    if [ ! -f "$market_json" ]; then
        echo "    skip: marketplace manifest not found ($market_json)."
        return 0
    fi
    if [ ! -f "$installed_json" ]; then
        echo "    skip: installed-plugins state not found ($installed_json)."
        return 0
    fi

    # tr -d '\r': jq emits CRLF on Windows; a trailing \r corrupts the key match.
    # mp_name comes from the manifest `.name`; this assumes the marketplace is
    # registered under that same name (true for himmel — registration name ==
    # manifest name). A divergent registration name would misreport all as missing.
    local mp_name declared installed_specs
    mp_name=$(jq -r '.name // "himmel"' "$market_json" 2>/dev/null | tr -d '\r' || true)
    [ -z "$mp_name" ] && mp_name="himmel"
    declared=$(jq -r '.plugins[].name' "$market_json" 2>/dev/null | tr -d '\r' || true)
    installed_specs=$(jq -r '.plugins | keys[]' "$installed_json" 2>/dev/null | tr -d '\r' || true)

    if [ -z "$declared" ]; then
        echo "    skip: no plugins declared in $market_json."
        return 0
    fi

    local total=0 ok=0 missing="" shadowed="" name other
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        total=$((total + 1))
        # ANY install of this plugin from a marketplace OTHER than @himmel is a
        # shadow — report it even when an @himmel copy is ALSO installed, because
        # the external copy's autoUpdate still defeats the pin. The trailing '@'
        # anchors the name so 'obsidian' can't match 'obsidian-triage@…' (plugin
        # names are [a-z0-9-], no regex metachars); -v -Fx drops the @himmel copy.
        other=$(printf '%s\n' "$installed_specs" | grep "^$name@" | grep -v -Fx "$name@$mp_name" | head -1 || true)
        if [ -n "$other" ]; then
            shadowed="$shadowed  $name  (currently: $other)
"
        elif printf '%s\n' "$installed_specs" | grep -Fxq "$name@$mp_name"; then
            ok=$((ok + 1))
        else
            missing="$missing  claude plugin install $name@$mp_name
"
        fi
    done <<EOF
$declared
EOF

    if [ -z "$missing" ] && [ -z "$shadowed" ]; then
        echo "    all $total @$mp_name plugins installed from @$mp_name."
        return 0
    fi

    echo "    $ok/$total @$mp_name plugins installed from @$mp_name."
    if [ -n "$missing" ]; then
        echo ""
        echo "    Not installed — install from @$mp_name:"
        printf '%s' "$missing"
    fi
    if [ -n "$shadowed" ]; then
        echo ""
        echo "    Served from another marketplace (its autoUpdate can shadow the @$mp_name pin):"
        printf '%s' "$shadowed"
        echo "    → migrate each to the pinned @$mp_name source (operator-present):"
        echo "        bash scripts/machine-setup/migrate-plugin-to-himmel.sh --apply <name@market> ..."
    fi
    return 0
}

# ─── --plugins-check mode ────────────────────────────────────────────────────
# Just the plugin install-state report; no git, no network. Exit 0 always.
if [ "${1:-}" = "--plugins-check" ]; then
    report_plugin_gap
    exit 0
fi

# ─── --check / --dry-run mode ────────────────────────────────────────────────
# Reports behind/ahead counts + plugin gap; pulls nothing. Exit 0 always.
if [ "${1:-}" = "--check" ] || [ "${1:-}" = "--dry-run" ]; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    git fetch --quiet origin 2>/dev/null || {
        echo "update --check: could not reach origin (offline or no remote configured)."
        report_plugin_gap
        exit 0
    }
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || {
        echo "update --check: no upstream configured for branch '$branch'."
        report_plugin_gap
        exit 0
    }
    behind=$(git rev-list --count "HEAD..$upstream" 2>/dev/null || echo "?")
    ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo "?")
    echo "branch:   $branch"
    echo "upstream: $upstream"
    echo "behind:   $behind"
    echo "ahead:    $ahead"
    if [ "$behind" = "0" ]; then
        echo "status:   up to date — nothing to pull."
    elif [ "$behind" != "?" ]; then
        echo "status:   $behind commit(s) behind — run /himmel-update (or bash scripts/himmel-update.sh) to pull."
    fi
    report_plugin_gap
    exit 0
fi

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

# 1. Pull. --ff-only so a diverged/feature branch fails loudly instead of
#    opening a merge — the operator decides how to reconcile in that case.
echo "==> git pull --ff-only (branch: $branch)"
if ! git pull --ff-only; then
    echo "" >&2
    echo "update: pull was not a fast-forward (branch '$branch' has diverged from upstream, or local edits block the update)." >&2
    echo "        Resolve manually: stash/commit local work, or 'git checkout main' first," >&2
    echo "        then re-run. himmel updates land on the default branch." >&2
    exit 1
fi

# 2. Re-sync the himmel marketplace from the (now-updated) local dir so a
#    running install picks up plugin changes. Best-effort: skip cleanly if the
#    claude CLI is absent. `marketplace update` is non-interactive.
if command -v claude >/dev/null 2>&1; then
    echo "==> claude plugin marketplace update himmel"
    claude plugin marketplace update himmel || \
        echo "update: marketplace re-sync failed (non-fatal) — run 'claude plugin marketplace update himmel' yourself." >&2
else
    echo "update: claude CLI not on PATH — skipping marketplace re-sync." >&2
fi

# 3. Report any himmel-marketplace plugins not installed from @himmel — the
#    marketplace re-sync above can't surface these (it only touches plugins that
#    are already installed). Advisory; never fails the update.
report_plugin_gap

cat <<'EOF'

==> himmel updated.
    - Hooks are live immediately (PreToolUse/etc. re-read from disk per call).
    - Plugins / slash commands / skills load at session start — RESTART any
      running Claude session to pick them up.
EOF
