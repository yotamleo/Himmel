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
# shellcheck source=guardrails/lib.sh
# shellcheck disable=SC1091
. "$ROOT/scripts/guardrails/lib.sh"
# shellcheck source=lib/cadence-format.sh
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/cadence-format.sh"
# shellcheck source=lib/resolve-hermes-py.sh
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/resolve-hermes-py.sh"

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

# ─── hermes junior-tier update (HIMMEL-426) ──────────────────────────────────
# Hermes (NousResearch/hermes-agent) is an EDITABLE install from a local git
# checkout (default %LOCALAPPDATA%/hermes/hermes-agent), NOT a himmel plugin and
# NOT in this repo — so `git pull` of this checkout never updates it. This step
# pulls that checkout and refreshes the editable install. Operator-personal +
# à-la-carte: absent on most machines, so it skips cleanly and is always
# best-effort (never fails the himmel update). HERMES_HOME (install root) /
# HERMES_PY (venv python) override the defaults; HERMES_PY mirrors
# scripts/hermes/invoke.sh resolution.
update_hermes() {
    local mode="$1"   # check | apply
    # HERMES_HOME is the hermes install ROOT (the runbook + operator env set it
    # to %LOCALAPPDATA%\hermes) — config + venv + the editable git checkout, the
    # last living in the hermes-agent/ subdir. So the checkout we pull is
    # $root/hermes-agent. Default root: %LOCALAPPDATA%\hermes. We also tolerate
    # HERMES_HOME pointing straight at the checkout (… /.git) for robustness.
    local root="${HERMES_HOME:-}"
    [ -n "$root" ] || root="${LOCALAPPDATA:-$HOME/AppData/Local}/hermes"
    local src="$root/hermes-agent"
    [ -d "$src/.git" ] || { [ -d "$root/.git" ] && src="$root"; }

    echo ""
    echo "==> hermes junior-tier update"
    if [ ! -d "$src/.git" ]; then
        echo "    skip: hermes not installed as a git checkout ($src) — see docs/hermes-runbook.md."
        return 0
    fi
    if ! git -C "$src" remote get-url origin 2>/dev/null | grep -q "NousResearch/hermes-agent"; then
        echo "    skip: $src is not a NousResearch/hermes-agent checkout — leaving it alone."
        return 0
    fi

    if [ "$mode" = "check" ]; then
        if ! git -C "$src" fetch -q origin 2>/dev/null; then
            echo "    skip: could not reach origin (offline?)."
            return 0
        fi
        local here there
        here=$(git -C "$src" rev-parse @ 2>/dev/null || echo "?")
        there=$(git -C "$src" rev-parse '@{u}' 2>/dev/null || echo "")
        if [ -n "$there" ] && [ "$here" != "$there" ]; then
            echo "    update available — run /himmel-update (no --check) to pull + reinstall."
        else
            echo "    hermes is current."
        fi
        return 0
    fi

    # apply
    if ! git -C "$src" pull --ff-only; then
        echo "    warn: hermes git pull was not fast-forward (local edits / diverged?) — resolve in $src." >&2
        return 0
    fi
    # Resolve the venv python at RUNTIME (HIMMEL-613): HERMES_PY wins only when
    # it still points at an executable, else probe $src/venv — a moved/rebuilt
    # venv (or a stale HERMES_PY) re-resolves instead of breaking the refresh.
    local py
    py="$(resolve_hermes_py "$src")" || py=""
    if [ -n "$py" ] && [ -x "$py" ]; then
        # uv-created venvs ship WITHOUT pip (uv venv default), so a plain
        # `$py -m pip install` fails with "No module named pip". Bootstrap pip
        # via stdlib ensurepip first — best-effort, harmless if pip is present.
        "$py" -m pip --version >/dev/null 2>&1 \
            || "$py" -m ensurepip --upgrade >/dev/null 2>&1 \
            || echo "    warn: could not bootstrap pip in the hermes venv (ensurepip failed) — see docs/hermes-runbook.md." >&2
        echo "    refreshing editable install (deps may have changed)…"
        "$py" -m pip install -e "$src" --quiet \
            || echo "    warn: pip editable refresh failed (non-fatal) — see docs/hermes-runbook.md (recover a broken venv pip) if hermes misbehaves." >&2
    else
        echo "    note: hermes venv python not found — code pulled, but run 'pip install -e .' in the venv if pyproject changed."
    fi
    return 0
}

# ─── stale pipeline-cadence runner nudge (HIMMEL-588) ────────────────────────
# The pipeline-cadence runners (.bat/.sh) are GENERATED at arm time and NOT
# regenerated on a code pull — so a `git pull` that changes the runner format
# leaves an already-armed cadence firing the OLD format until a manual
# `arm --force`. This surfaces that right after the pull. Advisory; never fails
# the update. PIPELINE_BAT_DIR mirrors pipeline-cadence.sh's runner-home seam.
report_cadence_stale() {
    local bat_dir="${PIPELINE_BAT_DIR:-$HOME/.claude/pipeline-cadence}" ver
    ver="$(cadence_runner_stamp "$bat_dir")" || return 0
    [ "$ver" -lt "$CADENCE_RUNNER_FORMAT_VERSION" ] || return 0
    echo ""
    echo "==> pipeline-cadence runners are STALE (format v$ver < v$CADENCE_RUNNER_FORMAT_VERSION)"
    echo "    Armed before a runner-format change — re-arm to pick up the new format:"
    echo "        bash scripts/luna/pipeline-cadence.sh arm --force"
}

# ─── guardrail-mode block drift check (HIMMEL-709) ───────────────────────────
# The himmel-owned user-level guardrail block (guardrail-skip-in-himmel.js) is a
# himmel-managed artifact; the wrapper body auto-updates via this pull, but the
# baked node/bash/wrapper paths in ~/.claude/settings.json do NOT. If the block
# is in global mode but its baked node path no longer resolves (e.g. a
# version-manager node upgrade), the guardrails silently stop firing outside
# himmel. This surfaces that. ADVISORY — never mutates settings, never fails the
# update. CLAUDE_USER_SETTINGS overridable for tests.
report_guardrail_block() {
    local block="$ROOT/scripts/hooks/guardrail-block.mjs" status
    echo ""
    echo "==> guardrail-mode block"
    if ! command -v node >/dev/null 2>&1; then echo "    skip: node not on PATH."; return 0; fi
    if [ ! -f "$block" ]; then echo "    skip: guardrail-block.mjs not found."; return 0; fi
    status=$(node "$block" status 2>/dev/null || echo "unknown")
    echo "    $status"
    case "$status" in
        *guardrail-mode=global*node-resolves=no*)
            echo "    ⚠ global mode but the baked node path no longer resolves — re-sync:"
            echo "        bash scripts/setup-hooks.sh --guardrail-mode global --yes" ;;
    esac
    return 0
}


# ─── statusLine hud migration (HIMMEL-718) ──────────────────────────────────
# Existing installs wired to the bash bar need one best-effort re-wire after the
# repo update. Fresh installs already get the hud renderer from setup/adopt.
rewire_statusline() {
    local settings="${CLAUDE_USER_SETTINGS:-$HOME/.claude/settings.json}"
    local match_re='marketplace/plugins/claude-hud/dist/index[.]js|scripts/(statusline/bin/statusline|where-are-we/statusline)[.]sh'
    local cur lib="$ROOT/scripts/lib/wire-statusline.sh"

    echo ""
    echo "==> statusLine re-wire (hud migration, HIMMEL-718)"
    if ! command -v jq >/dev/null 2>&1; then
        echo "    skip: jq not on PATH (cannot inspect statusLine)."
        return 0
    fi
    if [ ! -f "$settings" ]; then
        echo "    skip: settings file not found ($settings)."
        return 0
    fi
    if ! jq -e . "$settings" >/dev/null 2>&1; then
        echo "    skip: settings file is not valid JSON ($settings)."
        return 0
    fi

    cur=$(jq -r '.statusLine.command? // ""' "$settings" 2>/dev/null || printf '')
    # A user who never wired or deliberately unwired must not be re-wired by an
    # update; only an EXISTING himmel wiring migrates.
    if ! printf '%s' "$cur" | grep -Eq "$match_re"; then
        echo "    skip: statusLine not himmel-wired — leaving it alone."
        return 0
    fi
    if [ ! -f "$lib" ]; then
        echo "    skip: wire-statusline.sh not found ($lib)."
        return 0
    fi
    # The hud renderer is `node …/dist/index.js` — migrating a WORKING bash bar
    # on a node-less machine would trade it for a silently broken statusLine.
    # Skip (keeping the bash bar, the stated fallback) instead.
    if ! command -v node >/dev/null 2>&1; then
        echo "    skip: node not on PATH — leaving the bash statusLine bar in place."
        return 0
    fi

    # shellcheck source=lib/wire-statusline.sh
    # shellcheck disable=SC1090,SC1091
    if ! . "$lib"; then
        echo "    warn: could not load wire-statusline.sh (non-fatal)." >&2
        return 0
    fi
    if ! wire_statusline "$settings" "$ROOT"; then
        echo "    warn: statusLine re-wire failed (non-fatal) — run bash scripts/lib/wire-statusline.sh manually if needed." >&2
    fi
    return 0
}
# Test seam: source with HIMMEL_UPDATE_LIB=1 to load the functions above without
# running any update mode (lets test-himmel-update-hermes.sh call update_hermes
# directly with HERMES_HOME fixtures — no network, no repo mutation).
[ "${HIMMEL_UPDATE_LIB:-}" = "1" ] && return 0

# ─── --plugins-check mode ────────────────────────────────────────────────────
# Just the plugin install-state report; no git, no network. Exit 0 always.
if [ "${1:-}" = "--plugins-check" ]; then
    report_plugin_gap
    warn_doc_guard_off "$ROOT"
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
    update_hermes check
    report_cadence_stale
    report_guardrail_block
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

# 3. Update the hermes junior tier (separate editable git checkout outside this
#    repo — see update_hermes). Best-effort; skips cleanly when hermes is absent.
update_hermes apply

# 4. Re-wire existing himmel statusLine installs to the hud renderer. Fresh
#    installs already get hud via setup/adopt; update previously had the rollout
#    gap for users still wired to the bash bar. Advisory; never fails the update.
rewire_statusline

# 5. Report any himmel-marketplace plugins not installed from @himmel — the
#    marketplace re-sync above can't surface these (it only touches plugins that
#    are already installed). Advisory; never fails the update.
report_plugin_gap

# 6. Nudge if an armed pipeline-cadence is firing pre-change (stale) runners
#    that this pull's code won't regenerate on its own (HIMMEL-588). Advisory.
report_cadence_stale

# 7. Check the himmel-owned guardrail-mode block for baked-path drift (HIMMEL-709).
#    Advisory; never mutates ~/.claude/settings.json.
report_guardrail_block

cat <<'EOF'

==> himmel updated.
    - Hooks are live immediately (PreToolUse/etc. re-read from disk per call).
    - Plugins / slash commands / skills load at session start — RESTART any
      running Claude session to pick them up.
    - hermes (if installed) was pulled + reinstalled; restart its gateway to
      pick up changes (docs/hermes-runbook.md).
EOF
