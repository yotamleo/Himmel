#!/usr/bin/env bash
# Update an existing himmel checkout (HIMMEL-397).
#
# WHY this exists: himmel's marketplace is registered from a LOCAL `directory`
# source (see docs/setup/settings-template.json), so Claude Code's marketplace
# `autoUpdate` only RE-SYNCS plugins from the on-disk dir — it never fetches
# from GitHub. And the core hooks + slash commands aren't plugins at all;
# they run from $CLAUDE_PROJECT_DIR. So `git pull` of THIS checkout is the only
# thing that delivers a himmel update.
#
# HIMMEL-893: this is also the SHARED ENGINE behind `himmelctl update`
# (scripts/himmelctl/bin.js's cmdUpdate is a thin wrapper that shells out
# here) — the full dependency chain lives in ONE place so the two front ends
# never drift. The chain (see the STATUS_*/update_*/print_status_table
# functions below) covers six managed items in order — checkout pull,
# marketplace re-sync, jira CLI dist rebuild, qmd fork, hermes, luna template
# — each with its own per-item status, aborting on the first genuine failure.
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
# shellcheck source=lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/load-dotenv.sh"

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
# à-la-carte: absent/unconfigured/offline is always a clean SKIP (never fails
# the himmel update) — but once the checkout IS present + configured + the
# remote IS reachable, a genuine update failure (non-ff pull, or the editable
# pip refresh erroring) IS a real failure and propagates as such (CR fix — see
# run_hermes_step below, which surfaces it as STATUS_hermes="failed" and
# aborts the chain like any other item). HERMES_HOME (install root) /
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

    # Resolve the branch's CONFIGURED upstream (branch.<name>.remote + .merge)
    # rather than assuming a same-named branch on origin. Detached HEAD or no
    # upstream configured falls back to origin/HEAD.
    local branch remote merge_ref
    branch=$(git -C "$src" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
    remote=""; merge_ref=""
    if [ -n "$branch" ]; then
        remote=$(git -C "$src" config "branch.$branch.remote" 2>/dev/null || echo "")
        merge_ref=$(git -C "$src" config "branch.$branch.merge" 2>/dev/null || echo "")
    fi
    if [ -z "$remote" ] || [ -z "$merge_ref" ]; then
        remote="origin"
        merge_ref="HEAD"
    fi

    if [ "$mode" = "check" ]; then
        # Non-mutating remote comparison (CR fix): `git fetch` updates
        # remote-tracking refs + FETCH_HEAD in the EXTERNAL hermes checkout,
        # which violates --check's read-only contract. `git ls-remote` queries
        # the remote directly over the wire without touching any local git
        # state — no refs, no FETCH_HEAD, nothing written under $src/.git.
        local here there
        here=$(git -C "$src" rev-parse HEAD 2>/dev/null || echo "?")
        there=$(git -C "$src" ls-remote "$remote" "$merge_ref" 2>/dev/null | cut -f1)
        if [ -z "$there" ]; then
            echo "    skip: could not reach origin (offline?)."
            return 0
        fi
        if [ "$here" != "$there" ]; then
            echo "    update available — run /himmel-update (no --check) to pull + reinstall."
        else
            echo "    hermes is current."
        fi
        return 0
    fi

    # apply. Fetch FIRST, separately from the merge, so an unreachable remote
    # (offline / transient network) is a clean SKIP — "couldn't attempt" —
    # never a "failed". Only once the fetch has genuinely succeeded does a
    # non-fast-forward merge (diverged / local edits) count as a real FAILURE
    # (CR fix: this used to `git pull --ff-only` in one shot and swallow BOTH
    # cases as a non-aborting warn, hiding a genuine broken update behind
    # "skipped").
    if ! git -C "$src" fetch -q "$remote" "$merge_ref" 2>/dev/null; then
        echo "    skip: could not reach origin (offline?)."
        return 0
    fi
    if ! git -C "$src" merge --ff-only -q FETCH_HEAD 2>/dev/null; then
        echo "    FAILED: hermes git pull was not fast-forward (local edits / diverged?) — resolve in $src." >&2
        return 1
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
        # The editable pip refresh IS the second half of "update" (code pulled
        # but the install left stale) — a genuine error here is a real
        # failure, not a best-effort warn (CR fix, same rationale as the pull
        # above).
        if ! "$py" -m pip install -e "$src" --quiet; then
            echo "    FAILED: pip editable refresh failed — see docs/hermes-runbook.md (recover a broken venv pip)." >&2
            return 1
        fi
    else
        echo "    note: hermes venv python not found — code pulled, but run 'pip install -e .' in the venv if pyproject changed."
    fi
    return 0
}

# ─── codex plugin re-sync + hooks.json sanitize (HIMMEL-742 / 605) ───────────
# The codex-CLI side is provisioned by scripts/codex/install-himmel-codex.sh,
# whose phase 3 strips the top-level `description` key from external-plugin
# hooks.json (sanitize-plugin-hooks.sh). Codex BEFORE rust-v0.143.0 rejects that
# key and silently unloads those hooks; upstream fixed it in rust-v0.143.0
# (PR #30229), so on newer codex the strip is a no-op benefit — HIMMEL-1104/1114.
# Running the INSTALLER is a first-install action, so on its own the sanitize
# would happen once — while a later codex plugin re-sync/update re-adds
# `description`, silently unloading the hooks again with nothing to re-clean them.
# Hence this step: it re-runs the installer on /himmel-update, so phase 3 (and
# therefore the sanitize) runs on UPDATES TOO, not just at first install,
# alongside the Claude marketplace
# re-sync. install-himmel-codex.sh is non-destructive + idempotent (re-runs are
# no-ops) and chains sanitize as its phase 3, so it is the right re-run entry
# point. Operator-personal + à-la-carte: skips cleanly when codex is absent or
# was never provisioned, and is always best-effort (never fails the himmel
# update). CODEX_BIN (codex CLI) / CODEX_HOME (default ~/.codex) override, mirror
# install-himmel-codex.sh + sanitize-plugin-hooks.sh.
update_codex() {
    local mode="$1"   # check | apply
    echo ""
    echo "==> codex plugin re-sync + hooks.json sanitize (HIMMEL-742)"
    # codex CLI present? CODEX_BIN override mirrors install-himmel-codex.sh's
    # resolve_codex (explicit-but-unusable -> skip, no silent PATH fallback).
    if [ -n "${CODEX_BIN:-}" ]; then
        if [ ! -x "$CODEX_BIN" ]; then
            echo "    skip: CODEX_BIN set but not executable ($CODEX_BIN)."
            return 0
        fi
    elif ! command -v codex >/dev/null 2>&1; then
        echo "    skip: codex CLI not on PATH — codex side not provisioned."
        return 0
    fi
    # Provisioned? The plugin cache dir exists once install-himmel-codex.sh has
    # run at least once — its absence means the codex side was never set up.
    local cache="${CODEX_HOME:-$HOME/.codex}/plugins/cache"
    if [ ! -d "$cache" ]; then
        echo "    skip: no codex plugin cache ($cache) — run scripts/codex/install-himmel-codex.sh first."
        return 0
    fi
    local installer="$ROOT/scripts/codex/install-himmel-codex.sh"
    if [ ! -f "$installer" ]; then
        echo "    skip: install-himmel-codex.sh not found ($installer)."
        return 0
    fi
    if [ "$mode" = "check" ]; then
        echo "    codex provisioned — /himmel-update (no --check) will re-sync plugins + re-sanitize hooks.json."
        return 0
    fi
    # apply: idempotent re-provision; chains sanitize-plugin-hooks as its phase 3.
    if ! bash "$installer"; then
        echo "    warn: codex re-provision/sanitize failed (non-fatal) — run bash scripts/codex/install-himmel-codex.sh yourself." >&2
    fi
    return 0
}

# ─── stale cadence runner nudge (HIMMEL-588/HIMMEL-969) ──────────────────────
# Cadence runners (.bat/.sh) are GENERATED at arm time and NOT regenerated on a
# code pull — so a `git pull` that changes the runner format leaves an
# already-armed cadence firing the OLD format until a manual `arm --force`.
# This surfaces that right after the pull. Advisory; never fails the update.
# *_BAT_DIR env seams mirror each emitter's runner home; defaults resolve via
# cadence_user_home (emitter parity — USERPROFILE via cygpath before $HOME on
# Windows Git-Bash, HIMMEL-645/969 — a bare $HOME would probe the MSYS dir).
report_cadence_stale() {
    local label bat_dir rearm ver uh
    uh="$(cadence_user_home)"
    while IFS='|' read -r label bat_dir rearm; do
        [ -n "$label" ] || continue
        ver="$(cadence_runner_stamp "$bat_dir")" || continue
        [ "$ver" -lt "$CADENCE_RUNNER_FORMAT_VERSION" ] || continue
        echo ""
        echo "==> $label runners are STALE (format v$ver < v$CADENCE_RUNNER_FORMAT_VERSION)"
        echo "    Armed before a runner-format change — re-arm to pick up the new format:"
        echo "        $rearm"
    done <<EOF
pipeline-cadence|${PIPELINE_BAT_DIR:-$uh/.claude/pipeline-cadence}|bash scripts/luna/pipeline-cadence.sh arm --force
codex-sweep-cadence|${SWEEP_BAT_DIR:-$uh/.claude/codex-sweep-cadence}|bash scripts/cleanup/codex-sweep-cadence.sh arm --force
graphmap-cadence|${GRAPHMAP_BAT_DIR:-$uh/.claude/graphmap-cadence}|bash scripts/luna/graphmap-cadence.sh arm --force
EOF
    return 0
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
    # Resolve the user settings.json: explicit test override wins, else honor a
    # relocated CLAUDE_CONFIG_DIR, else the ~/.claude default. Without the
    # CLAUDE_CONFIG_DIR fallback a relocated config would be silently skipped.
    local settings="${CLAUDE_USER_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
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
# ─── lean plugin-set reconcile (HIMMEL-1032) ─────────────────────────────────
# The lean plugin profile (HIMMEL-816) was additive-only: install-plugins
# installs the template's `true` plugins but never writes the `false` ones, so
# a plugin enabled once (manual toggle, old template, himmelctl full-set) stays
# enabled forever and drifts back after every update (~10% context at session
# start). This step reconciles the user settings.json enabledPlugins DOWN to the
# template floor on every update — the plugin analog of --strict-mcp-config.
# Whitelist model: only template-`true` plugins survive; everything else is
# forced `false`. settings.local.json per-machine overrides still win (the
# harness layers them over settings.json; the reconciler never touches it).
# Best-effort: never fails the update. CLAUDE_USER_SETTINGS overridable for tests.
reconcile_plugins() {
    local mode="$1"   # check | apply
    local script="$ROOT/scripts/machine-setup/reconcile-enabled-plugins.sh"
    local settings="${CLAUDE_USER_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
    echo ""
    echo "==> lean plugin-set reconcile (HIMMEL-1032)"
    if [ ! -f "$script" ]; then
        echo "    skip: reconcile-enabled-plugins.sh not found ($script)."
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "    skip: jq not on PATH (cannot reconcile plugin set)."
        return 0
    fi
    # Adopter-safe default: WARN-only. `/himmel-update` must never silently
    # disable a plugin an adopter intentionally enabled — it reports the drift
    # and stops. Enforcement (writing the floor) is OPT-IN via
    # HIMMEL_RECONCILE_PLUGINS (1/all/true) — set once per machine so the
    # operator gets automatic drift-clearing while a fresh adopter clone does
    # not. Wanted plugins survive enforcement via settings.local.json regardless.
    local apply=0
    case "${HIMMEL_RECONCILE_PLUGINS:-}" in 1|all|true|yes) apply=1 ;; esac
    # Scalar flag (not a `dry=()` array): on bash 3.2, expanding an empty array as
    # `"${dry[@]}"` under `set -u` trips "unbound variable"; branch the call instead.
    local do_apply=0
    [ "$mode" = "apply" ] && [ "$apply" -eq 1 ] && do_apply=1
    if [ "$do_apply" -eq 1 ]; then
        bash "$script" --settings "$settings" \
            || echo "    warn: plugin-set reconcile failed (non-fatal) — run bash scripts/machine-setup/reconcile-enabled-plugins.sh yourself." >&2
    else
        bash "$script" --dry-run --settings "$settings" \
            || echo "    warn: plugin-set reconcile failed (non-fatal) — run bash scripts/machine-setup/reconcile-enabled-plugins.sh yourself." >&2
    fi
    if [ "$do_apply" -eq 0 ] && [ "$mode" = "apply" ]; then
        echo "    (warn-only: set HIMMEL_RECONCILE_PLUGINS=1 to have /himmel-update enforce the lean floor;"
        echo "     or apply once now: bash scripts/machine-setup/reconcile-enabled-plugins.sh)"
    fi
    return 0
}

# ─── the full dependency chain (HIMMEL-893) ──────────────────────────────────
# Six MANAGED items — the things this file already updates (or, for jira/qmd/
# luna below, already has a real recipe for elsewhere in this repo that this
# wires in rather than re-inventing): the checkout pull, the marketplace
# re-sync, the jira CLI dist rebuild, the qmd fork, hermes, and the luna
# template. graphify/headroom are NOT managed yet (HIMMEL-890/891 pending) —
# deliberately absent here.
#
# Per-item status is one of: updated | up-to-date | skipped | failed |
# not-attempted. ONLY "failed" (a step that ran and genuinely errored, never a
# clean skip for an absent/unconfigured optional tool) aborts the chain — the
# first failure stops the remaining items at "not-attempted", the status table
# always prints, and the script exits non-zero. bash-3.2-safe throughout: no
# arrays, no associative maps — six items means six named STATUS_*/DETAIL_*
# scalar pairs, read back by print_status_table's own fixed heredoc list
# (mirrors report_cadence_stale's read-loop style above).
STATUS_pull="not-attempted";          DETAIL_pull=""
STATUS_marketplace="not-attempted";   DETAIL_marketplace=""
STATUS_jira_cli="not-attempted";      DETAIL_jira_cli=""
STATUS_qmd_fork="not-attempted";      DETAIL_qmd_fork=""
STATUS_hermes="not-attempted";        DETAIL_hermes=""
STATUS_luna_template="not-attempted"; DETAIL_luna_template=""

# 1. checkout pull. The real `git pull --ff-only` (apply only — --check mode
#    has its own read-only fetch+rev-list reporting above and sets STATUS_pull
#    itself). Distinguishes up-to-date (HEAD unchanged) from updated so the
#    status table is honest, not just "ran without error".
update_pull() {
    local before after autostash=""
    before=$(git rev-parse HEAD 2>/dev/null || echo "")
    # HIMMEL_UPDATE_AUTOSTASH=1 opts into stash->pull->restore around the pull so a
    # dirty tree (e.g. local skill-dev diffs to skills-lock.json/.gitignore) can be
    # updated through instead of the HIMMEL-893 pre-check refusing (HIMMEL-1197).
    [ "${HIMMEL_UPDATE_AUTOSTASH:-}" = "1" ] && autostash="--autostash"
    # shellcheck disable=SC2086  # $autostash is a fixed literal or empty; intentional split
    if ! git pull --ff-only $autostash; then
        STATUS_pull="failed"
        if [ -n "$autostash" ]; then
            DETAIL_pull="pull failed with autostash active — any local changes are preserved in 'git stash list'; see the git output above, resolve manually, then re-run"
        else
            DETAIL_pull="pull was not a fast-forward (branch '$branch' diverged from upstream, or local edits block it) — resolve manually, then re-run"
        fi
        return 1
    fi
    # `git pull --ff-only --autostash` returns 0 even when the autostash REAPPLY
    # conflicts: the fast-forward applied, but git left conflict markers in the
    # tree and kept the stash (verified: git 2.55). Detect that here and report
    # failed — otherwise the chain would proceed on a conflicted tree reported as
    # "updated" (HIMMEL-1197).
    if [ -n "$autostash" ] && [ -n "$(git ls-files --unmerged 2>/dev/null)" ]; then
        STATUS_pull="failed"
        DETAIL_pull="pull applied but autostash reapply conflicted — your local changes are preserved in 'git stash list' and left as conflict markers; resolve them (or 'git checkout -- .' then 'git stash pop' later), then re-run"
        return 1
    fi
    after=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ "$before" = "$after" ]; then
        STATUS_pull="up-to-date"; DETAIL_pull="already at ${after:-?}"
    else
        STATUS_pull="updated"; DETAIL_pull="${before:-?} -> ${after:-?}"
    fi
    return 0
}

# Last non-empty line of $1, leading whitespace stripped — used to pull a
# one-line DETAIL_* summary out of a captured multi-line step output (the
# steps below echo indented "    ..." lines; the table's own indentation
# would otherwise double up).
_last_line_trimmed() {
    local line
    line=$(printf '%s' "$1" | tail -1)
    printf '%s' "${line#"${line%%[![:space:]]*}"}"
}

# 2. marketplace re-sync. claude CLI absent is a clean skip (many machines);
#    present-but-failing is a real failure. HIMMEL_UPDATE_CLAUDE_BIN overrides
#    the binary (tests — a stub that logs/fails without touching the real
#    ~/.claude marketplace state; mirrors update_codex's CODEX_BIN seam).
update_marketplace() {
    local mode="$1"   # check | apply
    local claude_bin="${HIMMEL_UPDATE_CLAUDE_BIN:-claude}"
    if ! command -v "$claude_bin" >/dev/null 2>&1; then
        STATUS_marketplace="skipped"; DETAIL_marketplace="claude CLI not on PATH"
        return 0
    fi
    if [ "$mode" = "check" ]; then
        STATUS_marketplace="skipped"; DETAIL_marketplace="check mode — re-sync deferred to apply"
        return 0
    fi
    if "$claude_bin" plugin marketplace update himmel; then
        STATUS_marketplace="updated"; DETAIL_marketplace="re-synced from local dir"
        return 0
    fi
    STATUS_marketplace="failed"
    DETAIL_marketplace="$claude_bin plugin marketplace update himmel failed — run it yourself"
    return 1
}

# 3. jira CLI dist rebuild. scripts/jira/dist is a GITIGNORED build artifact —
#    adopt.sh's build_jira_cli builds it once at fresh-clone time and SKIPS if
#    already built (an install-time step only). A `git pull` here can change
#    scripts/jira/*.ts without ever rebuilding dist/, so the jira CLI silently
#    runs stale code after an update. This is the update-time counterpart:
#    always rebuilds (never skip-if-exists), reusing adopt.sh's own npm/bun
#    recipe rather than inventing a new one. No npm/bun on PATH, or no
#    scripts/jira here at all, is a clean skip; a present package manager that
#    fails the build is a real failure.
update_jira_cli() {
    local mode="$1"   # check | apply
    local jira_dir="$ROOT/scripts/jira"

    if [ ! -f "$jira_dir/package.json" ]; then
        STATUS_jira_cli="skipped"; DETAIL_jira_cli="scripts/jira not found"
        return 0
    fi
    local pm=""
    if command -v npm >/dev/null 2>&1; then
        pm=npm
    elif command -v bun >/dev/null 2>&1; then
        pm=bun
    fi
    if [ -z "$pm" ]; then
        STATUS_jira_cli="skipped"; DETAIL_jira_cli="no npm or bun on PATH"
        return 0
    fi
    if [ "$mode" = "check" ]; then
        STATUS_jira_cli="skipped"; DETAIL_jira_cli="check mode — rebuild deferred to apply"
        return 0
    fi
    if [ "$pm" = "npm" ]; then
        if ( cd "$jira_dir" && npm install --silent && npm run build --silent ); then
            STATUS_jira_cli="updated"; DETAIL_jira_cli="rebuilt via npm"
            return 0
        fi
    else
        if ( cd "$jira_dir" && bun install && bun run build ); then
            STATUS_jira_cli="updated"; DETAIL_jira_cli="rebuilt via bun"
            return 0
        fi
    fi
    STATUS_jira_cli="failed"
    DETAIL_jira_cli="build failed — (cd scripts/jira && $pm install && $pm run build)"
    return 1
}

# 4. qmd fork update. qmd ships from the himmel FORK, pinned by commit SHA
#    (scripts/lib/qmd-bin.sh, HIMMEL-877/911) — `git pull` of THIS checkout
#    never touches that separate clone. qmd_install() (sourced from
#    qmd-bin.sh) IS the real, existing update mechanism: idempotent, skips
#    cleanly when already fork-served at the pin, else clones/fetches +
#    rebuilds + re-links. No qmd-bin.sh, or no git/bun on PATH (never adopted
#    qmd), is a clean skip; a present git+bun that fails install/build is a
#    real failure.
update_qmd_fork() {
    local mode="$1"   # check | apply
    local lib="$ROOT/scripts/lib/qmd-bin.sh"

    if [ ! -f "$lib" ]; then
        STATUS_qmd_fork="skipped"; DETAIL_qmd_fork="qmd-bin.sh not found"
        return 0
    fi
    if ! command -v git >/dev/null 2>&1 || ! command -v bun >/dev/null 2>&1; then
        STATUS_qmd_fork="skipped"; DETAIL_qmd_fork="git or bun not on PATH"
        return 0
    fi
    # shellcheck source=lib/qmd-bin.sh
    # shellcheck disable=SC1090,SC1091
    # A PRESENT-but-unsourceable qmd-bin.sh is a genuine breakage of a
    # himmel-shipped managed helper — distinct from the "not found" / "no
    # git or bun" precondition-gap skips just above, which are legit
    # environment gaps, not bugs. Fail the chain in apply mode instead of
    # reporting a misleading "skipped".
    if ! . "$lib"; then
        STATUS_qmd_fork="failed"; DETAIL_qmd_fork="could not source qmd-bin.sh"
        return 1
    fi
    if qmd_fork_served; then
        STATUS_qmd_fork="up-to-date"; DETAIL_qmd_fork="$(qmd_cmd --version 2>/dev/null)"
        return 0
    fi
    if [ "$mode" = "check" ]; then
        STATUS_qmd_fork="skipped"; DETAIL_qmd_fork="update available — run without --check to install"
        return 0
    fi
    if qmd_install; then
        STATUS_qmd_fork="updated"; DETAIL_qmd_fork="$(qmd_cmd --version 2>/dev/null)"
        return 0
    fi
    STATUS_qmd_fork="failed"
    DETAIL_qmd_fork="qmd_install failed — see: bash scripts/lib/qmd-bin.sh install"
    return 1
}

# 5. hermes junior-tier update. Reuses update_hermes() (defined above) and
#    classifies its outcome into STATUS_hermes/DETAIL_hermes for the shared
#    status table. CR fix: update_hermes now returns NON-ZERO for a genuine
#    failure (checkout present + configured but the pull/pip refresh actually
#    errored) while staying 0 for every "couldn't attempt" skip (absent,
#    foreign checkout, offline). This step propagates that distinction —
#    STATUS_hermes="failed" + return 1 on a real failure (so the chain's
#    `if ! run_hermes_step apply; then chain_rc=1` aborts it like every other
#    item), STATUS_hermes="skipped" on a clean skip, STATUS_hermes="updated"
#    otherwise.
run_hermes_step() {
    local mode="$1"   # check | apply
    local out rc
    if out=$(update_hermes "$mode" 2>&1); then rc=0; else rc=$?; fi
    printf '%s\n' "$out"
    DETAIL_hermes="$(_last_line_trimmed "$out")"
    if [ "$mode" = "check" ]; then
        STATUS_hermes="skipped"   # check mode never mutates, by update_hermes's own contract
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        STATUS_hermes="failed"
        return 1
    fi
    case "$out" in
        *"skip:"*) STATUS_hermes="skipped" ;;
        *)         STATUS_hermes="updated" ;;
    esac
    return 0
}

# 6. luna template upgrade. Vault-side counterpart to this harness update
#    (HIMMEL-389) — the vault at LUNA_VAULT_PATH is scaffolded once from
#    templates/luna-second-brain and never re-reads it; upgrade.sh is the
#    real, existing content-preserving refresh path (never touches
#    journal/notes/clips; a _CLAUDE.md conflict is fail-closed — original kept,
#    conflicted merge written to a sidecar, version stamp NOT advanced). No
#    LUNA_VAULT_PATH (or no vault/upgrade.sh there) is a clean skip — operator-
#    personal + à-la-carte, same class as hermes. --yes (non-interactive)
#    matches this file's other auto-apply steps (hermes, codex, qmd fork);
#    safe because upgrade.sh's own contract never destroys user content.
update_luna_template() {
    local mode="$1"   # check | apply
    # Load LUNA_VAULT_PATH from the primary checkout's .env when it is not
    # already in the process env (a live shell env var still wins — load_dotenv
    # only fills the gap). Without this, `himmelctl update` run from a shell that
    # never exported LUNA_VAULT_PATH silently skipped the luna-template upgrade
    # even though it was configured in .env (operator report 2026-07-21).
    load_dotenv LUNA_VAULT_PATH 2>/dev/null || true
    local vault="${LUNA_VAULT_PATH:-}"
    local template="$ROOT/templates/luna-second-brain"
    local upgrade="$template/scripts/upgrade.sh"

    if [ -z "$vault" ]; then
        STATUS_luna_template="skipped"; DETAIL_luna_template="LUNA_VAULT_PATH not set"
        return 0
    fi
    if [ ! -d "$vault" ]; then
        STATUS_luna_template="skipped"; DETAIL_luna_template="vault dir not found ($vault)"
        return 0
    fi
    if [ ! -f "$upgrade" ]; then
        STATUS_luna_template="skipped"; DETAIL_luna_template="upgrade.sh not found ($upgrade)"
        return 0
    fi

    local flag="--check"
    [ "$mode" = "apply" ] && flag="--yes"
    local out rc
    # Guard the command substitution (CR codex-1): the --check dispatch calls
    # this function UNGUARDED (bare `update_luna_template check`, not the
    # `if ! update_luna_template apply` chain form that already suspends set -e),
    # so a non-zero upgrade.sh — e.g. `--check` signalling "upgrade available" —
    # would otherwise trigger errexit HERE and kill the whole script before the
    # check-mode status table prints. The `if …; then rc=0; else rc=$?; fi`
    # form captures the real rc while staying set -e-safe in every call context.
    if out=$(bash "$upgrade" --template-dir "$template" --vault-dir "$vault" "$flag" 2>&1); then rc=0; else rc=$?; fi
    printf '%s\n' "$out"
    if [ "$mode" = "check" ]; then
        STATUS_luna_template="skipped"; DETAIL_luna_template="$(_last_line_trimmed "$out")"
        return 0
    fi
    if [ "$rc" -eq 0 ]; then
        if printf '%s' "$out" | grep -qi "already current"; then
            STATUS_luna_template="up-to-date"
        else
            STATUS_luna_template="updated"
        fi
        DETAIL_luna_template="$(_last_line_trimmed "$out")"
        return 0
    fi
    STATUS_luna_template="failed"
    DETAIL_luna_template="upgrade.sh exited $rc — see docs/luna, resolve any _CLAUDE.md.template-merge conflict"
    return 1
}

# Prints the six-item status table in FIXED chain order (a heredoc read-loop,
# not a bash array — bash-3.2-safe, mirrors report_cadence_stale's style).
print_status_table() {
    echo ""
    echo "==> update chain status"
    local id status detail
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        case "$id" in
            pull)          status="$STATUS_pull";          detail="$DETAIL_pull" ;;
            marketplace)   status="$STATUS_marketplace";   detail="$DETAIL_marketplace" ;;
            jira_cli)      status="$STATUS_jira_cli";      detail="$DETAIL_jira_cli" ;;
            qmd_fork)      status="$STATUS_qmd_fork";      detail="$DETAIL_qmd_fork" ;;
            hermes)        status="$STATUS_hermes";        detail="$DETAIL_hermes" ;;
            luna_template) status="$STATUS_luna_template"; detail="$DETAIL_luna_template" ;;
        esac
        printf '    %-14s %-14s %s\n' "$id" "$status" "$detail"
    done <<EOF
pull
marketplace
jira_cli
qmd_fork
hermes
luna_template
EOF
}

# Test seam: source with HIMMEL_UPDATE_LIB=1 to load the functions above without
# running any update mode (lets test-himmel-update-hermes.sh call update_hermes
# directly with HERMES_HOME fixtures — no network, no repo mutation).
[ "${HIMMEL_UPDATE_LIB:-}" = "1" ] && return 0

# Let the repo-root .env supply update opt-ins (HIMMEL_UPDATE_AUTOSTASH), same
# as the Jira CLI reads .env (HIMMEL-1205) — a live shell env var still wins (load_dotenv only
# fills UNSET keys). Without this, the var had to be exported in the launching
# shell; putting it in .env silently did nothing.
load_dotenv HIMMEL_UPDATE_AUTOSTASH

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
        STATUS_pull="up-to-date"; DETAIL_pull="up to date"
    elif [ "$behind" != "?" ]; then
        echo "status:   $behind commit(s) behind — run /himmel-update (or bash scripts/himmel-update.sh) to pull."
        STATUS_pull="skipped"; DETAIL_pull="$behind commit(s) behind — run without --check to pull"
    else
        STATUS_pull="skipped"; DETAIL_pull="unknown (git rev-list failed)"
    fi
    report_plugin_gap
    reconcile_plugins check
    # `|| true` on each: check mode is READ-ONLY reporting and must never
    # abort under set -e. STATUS_* is already set as a side effect before
    # any of these return, so `|| true` just prevents a non-zero return
    # (e.g. update_qmd_fork's can't-source "failed" case above) from
    # errexiting the script before print_status_table runs — the apply
    # chain below is where a failure is allowed to abort (via chain_rc).
    update_marketplace check || true
    update_jira_cli check || true
    update_qmd_fork check || true
    run_hermes_step check || true
    update_codex check || true
    update_luna_template check || true
    report_cadence_stale
    report_guardrail_block
    print_status_table
    exit 0
fi

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

# ─── dirty-tree pre-check (HIMMEL-893) ───────────────────────────────────────
# A `git pull` into a dirty tree is exactly the failure this guards against —
# refuse up front rather than let `git pull --ff-only` fail confusingly (or,
# worse, silently mix local edits into the pulled tree). is_dirty() is
# guardrails/lib.sh's own predicate (already sourced above) — the same one the
# edit-on-main guard uses, so "dirty" means the same thing everywhere in himmel.
if is_dirty "$ROOT"; then
    if [ "${HIMMEL_UPDATE_AUTOSTASH:-}" = "1" ]; then
        # Opt-in (HIMMEL-1197): autostash local changes around the pull instead of
        # refusing — update_pull adds --autostash and reports failed (stash kept)
        # if the reapply conflicts. Set per-invocation to avoid weakening HIMMEL-893.
        echo "" >&2
        echo "update: dirty tree — HIMMEL_UPDATE_AUTOSTASH=1, autostashing local changes around the pull." >&2
    else
        echo "" >&2
        echo "update: checkout has uncommitted changes — refusing to pull into a dirty tree." >&2
        echo "        commit or stash your changes, then re-run." >&2
        echo "        (or set HIMMEL_UPDATE_AUTOSTASH=1 to autostash them around the pull)." >&2
        exit 1
    fi
fi

# ─── the full dependency chain (HIMMEL-893) ──────────────────────────────────
# Six managed items, in order, tracked via chain_rc rather than exiting
# immediately on failure. The CHAIN still aborts on the first genuine failure
# (never a clean skip) — each later item is guarded by `[ "$chain_rc" -eq 0 ]`
# so once chain_rc flips to 1 it is never attempted, staying "not-attempted"
# (and its own "==> [N/6] ..." header never prints). But the five pre-existing
# advisory steps below (update_codex's security-relevant hooks re-sanitize
# among them) predate this ticket and ALWAYS ran regardless of the git-pull
# outcome — a chain failure must not skip them, so they now run
# UNCONDITIONALLY after the chain, win or lose. The status table prints
# exactly ONCE, after the advisory steps, and the script exits non-zero only
# then — never mid-chain (set -e must not kill the script before the report
# prints).
chain_rc=0

echo "==> [1/6] git pull --ff-only (branch: $branch)"
if ! update_pull; then
    chain_rc=1
fi

if [ "$chain_rc" -eq 0 ]; then
    echo ""
    echo "==> [2/6] claude plugin marketplace update himmel"
    if ! update_marketplace apply; then
        chain_rc=1
    fi
fi

if [ "$chain_rc" -eq 0 ]; then
    echo ""
    echo "==> [3/6] jira CLI dist rebuild (scripts/jira/dist)"
    if ! update_jira_cli apply; then
        chain_rc=1
    fi
fi

if [ "$chain_rc" -eq 0 ]; then
    echo ""
    echo "==> [4/6] qmd fork update"
    if ! update_qmd_fork apply; then
        chain_rc=1
    fi
fi

if [ "$chain_rc" -eq 0 ]; then
    echo ""
    echo "==> [5/6] hermes junior-tier update"
    # Guarded like every other item: run_hermes_step returns non-zero on a
    # GENUINE hermes failure (a real pull/pip-refresh error), aborting the
    # chain here exactly like every other item — never on an absent/foreign/
    # offline skip (see its own comment above). A compound command's
    # condition also suspends set -e for everything executed while it's
    # tested, so this structurally protects against the
    # `out=$(update_hermes ...)` command substitution silently killing the
    # script before the status table prints.
    if ! run_hermes_step apply; then
        chain_rc=1
    fi
fi

if [ "$chain_rc" -eq 0 ]; then
    echo ""
    echo "==> [6/6] luna template upgrade (LUNA_VAULT_PATH)"
    if ! update_luna_template apply; then
        chain_rc=1
    fi
fi

# ─── graphify pin sync (HIMMEL-1048) ─────────────────────────────────────────
# Best-effort advisory: roll an EXISTING graphify install forward to the pinned
# version so `himmelctl update` propagates a graphify pin bump to other machines.
# The de-fork (HIMMEL-1048 / issue #469) made graphify a version-pinned upstream
# PyPI install, so a pin bump only reaches a machine if something reinstalls at
# the new pin — `git pull` alone updates graphify-bin.sh but not the installed
# tool. Sources the ONE resolver impl; a missing/foreign install is handled
# inside graphify_update (fresh install / never clobber). Never aborts the script.
sync_graphify() {
    local lib="$ROOT/scripts/lib/graphify-bin.sh"
    echo "==> graphify pin sync (HIMMEL-1048)"
    if [ ! -f "$lib" ]; then
        echo "    skip: graphify-bin.sh not found ($lib)."
        return 0
    fi
    if ! command -v uv >/dev/null 2>&1; then
        echo "    skip: uv not on PATH — graphify is uv-managed."
        return 0
    fi
    # shellcheck source=lib/graphify-bin.sh
    # shellcheck disable=SC1090,SC1091
    if ! . "$lib" 2>/dev/null; then
        echo "    warn: could not load graphify-bin.sh (non-fatal)." >&2
        return 0
    fi
    graphify_update || echo "    warn: graphify pin sync failed (non-fatal)." >&2
    return 0
}

# ─── existing advisory steps (best-effort; ALWAYS run, chain outcome or not)─
# None of these are managed CHAIN items (headroom is HIMMEL-890 pending; graphify
# is now covered by the best-effort sync_graphify step above, HIMMEL-1048) — they
# stay best-effort and never abort the script. They run here UNCONDITIONALLY, even
# after a mid-chain failure (chain_rc=1) — restoring their pre-HIMMEL-893 behavior
# of always running regardless of the pull/marketplace/jira/qmd/luna outcome,
# including the security-relevant update_codex hooks.json re-sanitize.
update_codex apply
rewire_statusline
sync_graphify
report_plugin_gap
reconcile_plugins apply
report_cadence_stale
report_guardrail_block

print_status_table

[ "$chain_rc" -eq 0 ] || exit 1

cat <<'EOF'

==> himmel updated.
    - Hooks are live immediately (PreToolUse/etc. re-read from disk per call).
    - Plugins / slash commands / skills load at session start — RESTART any
      running Claude session to pick them up.
    - hermes (if installed) was pulled + reinstalled; restart its gateway to
      pick up changes (docs/hermes-runbook.md).
EOF
# CR fix: only claim Luna files were refreshed when the step actually RAN
# (updated/up-to-date) — by the time we reach here chain_rc is 0, so
# STATUS_luna_template is one of updated/up-to-date/skipped (a failure would
# have exit 1'd above); skipped (vault/upgrade.sh missing, or LUNA_VAULT_PATH
# unset) prints nothing, matching the other steps' silence-on-skip.
case "$STATUS_luna_template" in
    updated)
        echo "    - the luna template step refreshed template-owned vault files —"
        echo "      journal/notes/clips are never touched."
        ;;
    up-to-date)
        echo "    - the luna template step ran — vault was already current with the"
        echo "      template (journal/notes/clips are never touched)."
        ;;
esac
