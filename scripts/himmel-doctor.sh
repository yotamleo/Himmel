#!/usr/bin/env bash
# himmel-doctor.sh — diagnose common himmel-harness health problems, print a
# severity-grouped report with remediation, and (on request) file ONE
# consolidated GitHub issue. Read-only except `--fix` (heals C1 node wiring).
#
#   bash himmel-doctor.sh [--fix] [--file-issue] [--repo owner/name] [--no-color]
#
# Exit 0 unless a FAIL finding is present (then 1) — so `--fix` re-checks are
# scriptable. WARN/INFO never fail the exit. See the /himmel-doctor command md.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/scripts/himmel-doctor.sh" ] || REPO_ROOT="${HIMMEL_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/resolve-node.sh"
# shellcheck source=lib/cadence-format.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/cadence-format.sh"

CLAUDE_DIR_R="${CLAUDE_DIR:-${HOME:-}/.claude}"
SETTINGS="$CLAUDE_DIR_R/settings.json"
REGISTRY="$CLAUDE_DIR_R/handover/registry.json"

# --- args ---
DO_FIX=0; DO_FILE=0; REPO_FLAG=""; USE_COLOR=1
[ -t 1 ] || USE_COLOR=0
while [ $# -gt 0 ]; do
    case "$1" in
        --fix) DO_FIX=1 ;;
        --file-issue) DO_FILE=1 ;;
        --repo) shift; REPO_FLAG="${1:-}" ;;
        --no-color) USE_COLOR=0 ;;
        -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "himmel-doctor: unknown arg '$1'" >&2; exit 2 ;;
    esac
    shift
done

if [ "$USE_COLOR" = 1 ]; then C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'
else C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_0=""; fi

n_fail=0; n_warn=0; n_info=0
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
printf '## himmel-doctor findings (%s)\n\n' "$(uname -s 2>/dev/null || echo ?)" >> "$BODY"

# emit <SEV> <id> <msg> <remedy>
emit() {
    local sev="$1" id="$2" msg="$3" remedy="${4:-}" col=""
    case "$sev" in
        FAIL) col="$C_RED"; n_fail=$((n_fail+1)) ;;
        WARN) col="$C_YEL"; n_warn=$((n_warn+1)) ;;
        INFO) col="$C_DIM"; n_info=$((n_info+1)) ;;
        OK)   col="$C_GRN" ;;
    esac
    printf '%s%-4s%s %s: %s\n' "$col" "$sev" "$C_0" "$id" "$msg"
    [ -n "$remedy" ] && printf '       %s→ %s%s\n' "$C_DIM" "$remedy" "$C_0"
    if [ "$sev" != OK ]; then printf -- '- **%s** %s: %s\n  - → %s\n' "$sev" "$id" "$msg" "$remedy" >> "$BODY"; fi
}

is_windows() { case "$(uname -s 2>/dev/null || echo x)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }

# --- C1: node / caveman SessionStart wiring -------------------------------------
classify_caveman_cmd() {
    # echoes: ok-wrapper | ok-bin | fail-dangling | fail-missing | warn-bare
    local cmd="$1" bin bin_unix
    case "$cmd" in
        *run-node.sh*) echo ok-wrapper; return ;;
        *'<node-path>'*) echo fail-dangling; return ;;
    esac
    bin="$(printf '%s' "$cmd" | sed -E 's/^"([^"]*)".*/\1/; t; s/^([^ ]+).*/\1/')"
    bin_unix="$(printf '%s' "$bin" | sed 's#\\#/#g')"
    if [ "$bin" = node ] || [ "$bin" = node.exe ]; then
        if command -v node >/dev/null 2>&1; then echo ok-bin; else echo warn-bare; fi
        return
    fi
    if [ -x "$bin_unix" ]; then echo ok-bin; else echo fail-missing; fi
}

check_c1() {
    if [ ! -f "$SETTINGS" ]; then
        emit INFO C1-node "no ~/.claude/settings.json — node hook wiring not checked" "run himmel setup if this is a himmel machine"
        return
    fi
    local cmds worst="ok" has_wrapper=0 line cl
    cmds="$(jq -r '[.hooks.SessionStart[]?.hooks[]?, .hooks.UserPromptSubmit[]?.hooks[]?] | .[]? | .command? // empty | select(test("caveman-(activate|mode-tracker)\\.js"))' "$SETTINGS" 2>/dev/null || true)"
    if [ -z "$cmds" ]; then
        if resolve_node >/dev/null 2>&1; then emit OK C1-node "node resolvable; no caveman node hooks wired"; else emit WARN C1-node "no node found on this machine" "install Node.js"; fi
        return
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        cl="$(classify_caveman_cmd "$line")"
        case "$cl" in
            ok-wrapper) has_wrapper=1 ;;
            fail-dangling|fail-missing) worst="fail" ;;
            warn-bare) [ "$worst" = fail ] || worst="warn" ;;
        esac
    done <<EOF
$cmds
EOF
    # A wrapper-form command resolves node at runtime — but if NO node exists
    # anywhere, the wrapper silently no-ops (fail-open). C1 is the only surface
    # for that, so flag it (R4/P5).
    if [ "$worst" = ok ] && [ "$has_wrapper" = 1 ] && ! resolve_node >/dev/null 2>&1; then
        emit FAIL C1-node "no node found anywhere — the caveman runtime wrapper will silently skip every session" "install Node.js (or fix PATH/nvm); then re-run"
        return
    fi
    case "$worst" in
        fail)
            if is_windows; then
                emit FAIL C1-node "caveman SessionStart hook points at a missing node — session-start error every launch" "re-run himmel setup / win11.ps1 to re-resolve the node path"
            else
                emit FAIL C1-node "caveman SessionStart hook points at a dangling/missing node (the 'node: command not found' error)" "himmel-doctor --fix"
            fi ;;
        warn) emit WARN C1-node "caveman hook uses a bare 'node' (works only if node is on the GUI launch PATH)" "himmel-doctor --fix" ;;
        *)    emit OK C1-node "caveman node hooks resolve to a working node" ;;
    esac
}

fix_c1() {
    if is_windows; then
        printf '%sWindows: node path is stable — nothing to wire (win11.ps1 owns Windows).%s\n' "$C_DIM" "$C_0"
        return 0
    fi
    [ -f "$SETTINGS" ] || { echo "no settings.json to fix"; return 0; }
    bash "$REPO_ROOT/scripts/lib/wire-caveman-node.sh" "$SETTINGS" "$REPO_ROOT" "$CLAUDE_DIR_R"
    echo "  re-checking C1 after --fix:"
    check_c1
}

# --- C2: claude-obsidian shadow (prompt-type-hook risk) -------------------------
check_c2() {
    local shadow=""
    for d in "$CLAUDE_DIR_R"/plugins/cache/claude-obsidian-marketplace \
             "$CLAUDE_DIR_R"/plugins/marketplaces/claude-obsidian-marketplace \
             "$CLAUDE_DIR_R"/plugins/repos/*/claude-obsidian-marketplace; do
        [ -e "$d" ] && { shadow="$d"; break; }
    done
    if [ -n "$shadow" ]; then
        emit WARN C2-obsidian "claude-obsidian served from a non-@himmel marketplace — autoUpdate can shadow the himmel pin (prompt-type-hook error risk)" "scripts/machine-setup/migrate-plugin-to-himmel.sh --apply claude-obsidian@claude-obsidian-marketplace, then restart"
    else
        emit OK C2-obsidian "no shadowing claude-obsidian marketplace detected"
    fi
}

# --- C3: dirty single-writer luna vault (won't autosync) ------------------------
check_c3() {
    local v=""
    for c in "${LUNA_VAULT_PATH:-}" "${HOME:-}/Documents/luna" "${HOME:-}/luna"; do
        [ -n "$c" ] && [ -d "$c/.git" ] && { v="$c"; break; }
    done
    [ -n "$v" ] || { emit OK C3-luna "no local luna vault found (skipped)"; return; }
    if [ ! -f "$v/.single-writer" ]; then emit OK C3-luna "luna vault present, not single-writer (skipped)"; return; fi
    if [ -n "$(git -C "$v" status --porcelain 2>/dev/null)" ]; then
        emit WARN C3-luna "luna vault ($v) has uncommitted changes — single-writer vaults are NOT auto-committed (e.g. after /luna-upgrade)" "commit it: git -C '$v' add -A && git -C '$v' commit -m 'chore: vault update'"
    else
        emit OK C3-luna "luna vault clean"
    fi
}

# --- C4: bitbucket remote where gh-based flows fail -----------------------------
check_c4() {
    local url; url="$(git remote get-url origin 2>/dev/null || true)"
    case "$url" in
        *bitbucket.org*)
            emit INFO C4-forge "this repo's origin is Bitbucket — /commit-push-pr hardcodes 'gh pr create' and will not open a PR here" "use the handover forge seam (scripts/handover/pr-open.sh → scripts/bitbucket/ CLI)" ;;
        *) : ;;
    esac
}

# --- C5: cwd repo not registered for handover-resume ----------------------------
check_c5() {
    local top; top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || return
    [ -f "$REGISTRY" ] || { emit INFO C5-handover "no handover registry yet" "/handover-setup to enable handover-resume"; return; }
    # Case-insensitive (Windows registry stores lowercased paths) + accept a
    # registered path that is a PARENT of $top (so a worktree under the main
    # checkout still counts as registered).
    local match; match="$(jq -r --arg p "$top" '
        ($p | ascii_downcase) as $pl
        | [.. | .path? // empty] | map(ascii_downcase)
        | map(. as $rp | select($rp == $pl or ($pl | startswith($rp + "/")))) | length' "$REGISTRY" 2>/dev/null || echo 0)"
    if [ "${match:-0}" = 0 ]; then
        emit INFO C5-handover "this repo is not in the handover registry — /handover handover-resume won't find handovers written here" "/handover register"
    fi
}

# --- C6: PATH-fragile bare-interpreter MCP servers + hooks ----------------------
# Same failure class as C1 node: a macOS GUI launch has a minimal PATH, so an MCP
# server wired as a bare interpreter name (uvx/bun/deno/python/pwsh) silently fails
# to start and all its tools vanish. Scans user settings + the himmel plugins.
#
# C6-hooks (HIMMEL-611) extends the scan to HOOK commands. A hook wired to lead
# with a bare interpreter that is NOT installed on THIS host (the canonical case:
# a `pwsh -NoProfile -File …` SessionEnd twin copied literally onto a host without
# PowerShell) prints `pwsh: command not found` every session. Unlike the MCP scan
# (which flags any bare interpreter, since the GUI PATH differs), the hook scan
# gates on the interpreter being genuinely absent here — that is the actual
# per-session error. The shipped template routes the pwsh twin through
# scripts/lib/run-pwsh.sh (leading token `bash`), so a current wiring never trips.
check_c6() {
    local fragile="" name c
    _scan_mcp() { # $1 = json file with .mcpServers
        [ -f "$1" ] || return
        while IFS="$(printf '\t')" read -r name c; do
            [ -n "$c" ] || continue
            case "$c" in */*) continue ;; esac
            case "$c" in uvx|uv|bun|node|deno|python|python3|pwsh) fragile="$fragile ${name}(${c})" ;; esac
        done <<EOF
$(jq -r '(.mcpServers // {}) | to_entries[] | "\(.key)\t\(.value.command)"' "$1" 2>/dev/null)
EOF
    }
    _scan_mcp "$SETTINGS"
    local glob="${DOCTOR_MCP_PLUGINS_GLOB:-$REPO_ROOT/marketplace/plugins/*/.mcp.json}"
    for mcp in $glob; do _scan_mcp "$mcp"; done
    if [ -n "$fragile" ]; then
        emit WARN C6-mcp "MCP server(s) wired as a bare interpreter a PATH-less GUI launch often lacks:$fragile — the server + its tools silently fail to start on macOS app launch" "expose the interpreter's bin dir on the launch PATH, or wire an absolute command"
    else
        emit OK C6-mcp "no PATH-fragile bare-interpreter MCP servers"
    fi

    # C6-hooks: bare-interpreter hook commands whose interpreter is MISSING here.
    local hook_bad="" cmd lead
    if [ -f "$SETTINGS" ]; then
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            lead="${cmd%% *}"          # leading token = the interpreter
            case "$lead" in */*) continue ;; esac
            case "$lead" in
                uvx|uv|bun|node|deno|python|python3|pwsh)
                    command -v "$lead" >/dev/null 2>&1 || hook_bad="$hook_bad ${lead}"
                    ;;
            esac
        done <<EOF
$(jq -r '(.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | .command // empty' "$SETTINGS" 2>/dev/null)
EOF
    fi
    if [ -n "$hook_bad" ]; then
        emit WARN C6-hooks "hook(s) wired to a bare interpreter not installed on this host:$hook_bad — every session prints '<interp>: command not found'" "install the interpreter, or route the hook through a guarded wrapper (e.g. scripts/lib/run-pwsh.sh) / re-run himmel setup"
    else
        emit OK C6-hooks "no hooks wired to a missing bare interpreter"
    fi
}

# --- C7: lingering merged-PR worktrees (READ-ONLY detective check) --------------
# Scans non-primary, non-locked, non-detached worktrees and flags any whose
# branch has a merged PR.  Never issues a destructive git verb; only emits
# findings and points to /clean.
check_c7() {
    local wt_root="${DOCTOR_WORKTREE_ROOT:-$REPO_ROOT}"
    # shellcheck source=scripts/lib/branch-shipped.sh
    # shellcheck disable=SC1091
    . "$REPO_ROOT/scripts/lib/branch-shipped.sh"

    local warned=0 info_emitted=0
    local wt_path="" wt_branch="" is_locked=0 is_detached=0

    _c7_eval_record() {
        [ -n "$wt_path" ] || return 0
        local canonical_root canonical_path
        canonical_root="$(cd "$wt_root" 2>/dev/null && pwd)" || canonical_root="$wt_root"
        canonical_path="$(cd "$wt_path" 2>/dev/null && pwd)" || canonical_path="$wt_path"
        if [ "$canonical_path" = "$canonical_root" ]; then
            return 0
        fi
        if [ "$is_locked" = 1 ]; then
            return 0
        fi
        if [ "$is_detached" = 1 ] || [ -z "$wt_branch" ]; then
            return 0
        fi
        branch_has_merged_pr "$wt_branch" "$wt_root"
        local brc=$?
        if [ "$brc" -eq 0 ]; then
            emit WARN C7-shipped \
                "worktree $wt_path (branch $wt_branch) maps to a MERGED PR — shipped work lingering" \
                "verify, then prune with /clean (dry-runs first); do NOT reuse this branch name"
            warned=$((warned+1))
        elif [ "$brc" -eq 2 ]; then
            if [ "$info_emitted" -eq 0 ]; then
                emit INFO C7-shipped \
                    "merged-PR worktree scan skipped (forge unreachable)" \
                    "ensure gh is authenticated and retry; or manually prune stale worktrees"
                info_emitted=1
            fi
        fi
    }

    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                _c7_eval_record
                wt_path="${line#worktree }"
                wt_branch=""; is_locked=0; is_detached=0
                ;;
            branch\ refs/heads/*)
                wt_branch="${line#branch refs/heads/}"
                ;;
            locked*)
                is_locked=1
                ;;
            detached)
                is_detached=1
                ;;
        esac
    done <<EOF
$(git -C "$wt_root" worktree list --porcelain 2>/dev/null)
EOF
    _c7_eval_record

    if [ "$warned" -eq 0 ] && [ "$info_emitted" -eq 0 ]; then
        emit OK C7-shipped "no lingering merged-PR worktrees"
    fi
}

# --- C8: stale cadence runners (armed before a format change) -----------------
# The cadence runners (.bat/.sh) are GENERATED at arm time and NOT regenerated
# on a code change (HIMMEL-588/HIMMEL-969), so a cadence armed before a
# runner-format change keeps firing the old format with no nudge. Read-only:
# compare the version stamped into the runners against the current
# CADENCE_RUNNER_FORMAT_VERSION and point stale ones at `arm --force`. No --fix
# — a re-arm touches the OS scheduler, so this stays advisory (mirrors C7).
check_c8() {
    # Defaults must match each emitter's runner home EXACTLY — the emitters
    # key off resolve_user_home (USERPROFILE via cygpath before $HOME on
    # Windows Git-Bash, HIMMEL-645), NOT $CLAUDE_DIR, so probe via the lib's
    # cadence_user_home rather than $HOME or $CLAUDE_DIR_R.
    # PIPELINE_BAT_DIR/SWEEP_BAT_DIR/GRAPHMAP_BAT_DIR override those homes.
    local label bat_dir rearm ver saw_any=0 uh
    uh="$(cadence_user_home)"
    while IFS='|' read -r label bat_dir rearm; do
        [ -n "$label" ] || continue
        if ! ver="$(cadence_runner_stamp "$bat_dir")"; then
            continue
        fi
        saw_any=1
        if [ "$ver" -lt "$CADENCE_RUNNER_FORMAT_VERSION" ]; then
            emit WARN C8-cadence \
                "$label runners are stale (format v$ver < v$CADENCE_RUNNER_FORMAT_VERSION) — armed before a runner-format change, still firing the old format" \
                "re-arm: $rearm"
        else
            emit OK C8-cadence "$label runners current (format v$ver)"
        fi
    done <<EOF
pipeline-cadence|${PIPELINE_BAT_DIR:-$uh/.claude/pipeline-cadence}|bash scripts/luna/pipeline-cadence.sh arm --force
codex-sweep-cadence|${SWEEP_BAT_DIR:-$uh/.claude/codex-sweep-cadence}|bash scripts/cleanup/codex-sweep-cadence.sh arm --force
graphmap-cadence|${GRAPHMAP_BAT_DIR:-$uh/.claude/graphmap-cadence}|bash scripts/luna/graphmap-cadence.sh arm --force
EOF
    if [ "$saw_any" -eq 0 ]; then
        emit OK C8-cadence "no armed cadence runners (skipped)"
    fi
}

# --- C9: auto-arm scheduler backend (read-only; enable needs sudo) -------------
# arm-resume.sh schedules the usage-cap auto-resume via an OS scheduler backend
# (windows=schtasks, linux=at+atd else crontab, macos=crontab). If that backend
# is absent/disabled the armed resume silently never fires. Detect + remediate
# only — NEVER sudo (enable lives in the installers). WARN never FAILs: auto-arm
# is a safety net, its absence must not flip the scripted exit code (mirrors
# C7/C8). HIMMEL-594.
check_c9() {
    # shellcheck source=scripts/lib/scheduler-backend.sh
    # shellcheck disable=SC1091
    . "$REPO_ROOT/scripts/lib/scheduler-backend.sh"
    local os status remedy; os="$(scheduler_backend_os)"; status="$(scheduler_backend_status)"
    remedy="$(scheduler_backend_remediation)"
    case "$status" in
        ok)       emit OK   C9-scheduler "auto-arm scheduler backend present ($os)" ;;
        ok-cron)  emit WARN C9-scheduler "auto-arm: only crontab available ($os) — weaker one-shot (fires at next HH:MM, misses if asleep)" "$remedy" ;;
        disabled) emit WARN C9-scheduler "auto-arm: 'at' present but atd not running — armed resumes silently won't fire" "$remedy" ;;
        *)        emit WARN C9-scheduler "auto-arm: no scheduler backend — can't schedule a resume" "$remedy" ;;
    esac
}

# --- C10: private→public propagation drift (read-only advisory) -----------------
# Sources the drift detector (Component A) and surfaces MISSING/DRIFT/REVERSE-LEAK
# between the private mirror and the public clone. Private-only tooling: on a
# public/adopter clone propagate-public.sh + propagation-drift.sh are absent →
# skipped, OK. NON-fatal (WARN never FAILs), no --fix — like C7. The detector's
# own cwd/clone/fetch guards make a non-private or clone-less run skip cleanly.
check_c10() {
    local drift_lib="$REPO_ROOT/scripts/lib/propagation-drift.sh"
    if [ ! -f "$REPO_ROOT/scripts/propagate-public.sh" ] || [ ! -f "$drift_lib" ]; then
        emit OK C10-propagation "skipped (no private mirror tooling)"
        return
    fi
    # shellcheck source=scripts/lib/public-clone-paths.sh
    # shellcheck disable=SC1091
    . "$REPO_ROOT/scripts/lib/public-clone-paths.sh"
    # shellcheck source=scripts/lib/propagation-drift.sh
    # shellcheck disable=SC1091
    . "$drift_lib"
    local out; out="$(propagation_drift 2>/dev/null)"
    case "$out" in
        *"propagation-drift: skipped"*)
            emit OK C10-propagation "$(printf '%s\n' "$out" | sed -n 's/^propagation-drift: //p' | head -1)"
            return ;;
    esac
    local total; total="$(printf '%s\n' "$out" | grep -c '^DRIFT-BUCKET ' || true)"
    # A WARN line (fetch failed → stale/local refs, or unreadable/empty origin/main)
    # means the comparison did NOT run against fresh trees — a "0 buckets" result
    # there is NOT a clean bill of health, so surface it as WARN, never OK.
    local warned; warned="$(printf '%s\n' "$out" | grep -c '^propagation-drift: WARN' || true)"
    if [ "${total:-0}" -eq 0 ] && [ "${warned:-0}" -gt 0 ]; then
        emit WARN C10-propagation \
            "drift comparison ran against stale/unreadable refs — cannot assert clean" \
            "re-run with network access (fetch origin/main on both private + public clone)"
        printf '%s\n' "$out" | grep '^propagation-drift: WARN' | sed 's/^propagation-drift: /       /'
        return
    fi
    if [ "${total:-0}" -eq 0 ]; then
        emit OK C10-propagation "no private→public propagation drift"
        return
    fi
    emit WARN C10-propagation \
        "$total private→public propagation-drift finding(s) — public mirror behind/diverged" \
        "review + propagate: scripts/propagate-public.sh prep/new (genericize MISSING-needs-review by hand)"
    # Surface any fetch/unreadable WARN too — if drift was found AGAINST stale refs
    # the counts may be inaccurate, and the operator must know the compare wasn't fresh.
    printf '%s\n' "$out" | grep '^propagation-drift: WARN' | sed 's/^propagation-drift: /       /'
    # One-screen breakdown: per-bucket counts + up to 5 example paths.
    printf '%s\n' "$out" | sed -n '/propagation-drift summary/,$p' | grep -v 'summary (private' | sed 's/^/       /'
    printf '       examples:\n'
    printf '%s\n' "$out" | grep '^DRIFT-BUCKET ' | head -5 | sed 's/^DRIFT-BUCKET /       · /'
}

# --- C11: glm-launcher config-seed drift (read-only advisory) -------------------
# The glm-LAUNCHER lane seeds ~/.claude-glm from ~/.claude once, then re-seeds
# only on --reseed/missing .seeded, so a reused config dir lags the source.
# Runs scripts/claude-glm-seed-check.sh --check (read-only; NEVER mutates) when
# ~/.claude-glm exists and points to --reseed on drift. The glm-SPAWN lane has
# no seeded dir, so the check is skipped there (no ~/.claude-glm -> OK skip).
# NON-fatal (never FAIL): a stale launcher config is a nudge, not a breakage,
# matching the read-only stance of C7/C8/C9/C10. No --fix here. HIMMEL-654 WS5.
check_c11() {
    # The launcher hardcodes ~/.claude-glm (NOT CLAUDE_DIR-derived), so this does
    # too -- diverging when an operator relocates .claude via CLAUDE_DIR would
    # check the wrong dir.
    local glm_cfg="${HOME}/.claude-glm"
    if [ ! -d "$glm_cfg" ]; then
        emit OK C11-glm-seed "skipped (no ~/.claude-glm -- glm-launcher lane not in use)"
        return
    fi
    local out rc
    out="$(bash "$REPO_ROOT/scripts/claude-glm-seed-check.sh" --check 2>&1)"
    rc=$?
    case "$rc" in
        0) emit OK C11-glm-seed "glm-launcher seeded set in sync (~/.claude-glm matches ~/.claude)" ;;
        1)
            emit WARN C11-glm-seed \
                "glm-launcher config-seed drift -- ~/.claude-glm lags ~/.claude (reused config dir)" \
                "claude-glm --reseed"
            # Surface the per-file drift list (up to 8), like C10's example breakdown.
            printf '%s\n' "$out" | grep '^  · ' | sed 's/^  /       /' | head -8
            ;;
        2)
            emit INFO C11-glm-seed \
                "glm-launcher config dir present but unseeded (no .seeded sentinel)" \
                "run 'claude-glm' to seed on first launch"
            ;;
        *)
            emit WARN C11-glm-seed "claude-glm-seed-check exited rc=$rc (unexpected)" "inspect scripts/claude-glm-seed-check.sh"
            ;;
    esac
}

# --- C12: codex startup health (read-only advisory, HIMMEL-747) -----------------
# Surfaces a DEGRADED codex CLI startup (skills silently truncated / lifecycle
# hooks silently ignored / oversized _where-are-we injection) so a codex
# delegation lane that LOOKS healthy but starts degraded becomes visible. Runs
# scripts/codex/startup-health.sh, which reads only the most-recent codex session
# logs under CODEX_HOME. Skips cleanly when codex is absent (detector rc=2).
# NON-fatal (WARN at most, never FAIL): a broken detector must never fail doctor.
check_c12() {
    local detector="$REPO_ROOT/scripts/codex/startup-health.sh"
    if [ ! -f "$detector" ]; then
        emit OK C12-codex "codex startup-health detector not present (skipped)"
        return
    fi
    local out rc
    out="$(bash "$detector" 2>/dev/null)"; rc=$?
    case "$rc" in
        0) emit OK C12-codex "codex startup healthy (no skill-truncation / hook-failure / oversized where-are-we in the last session)" ;;
        2) emit OK C12-codex "no codex logs under CODEX_HOME (codex lane not in use here — skipped)" ;;
        1)
            local n; n="$(printf '%s\n' "$out" | grep -c '^WARN ')"
            emit WARN C12-codex \
                "codex started DEGRADED -- $n startup finding(s) in the most recent session (a routed codex lane looks healthy but is not)" \
                "restart codex after fixing (skills: scripts/codex/sanitize-plugin-hooks.sh; hooks: check .codex/hooks.json shape). Detail: scripts/codex/startup-health.sh"
            printf '%s\n' "$out" | sed 's/^WARN /       · /'
            ;;
        *) emit WARN C12-codex "codex startup-health detector exited rc=$rc (unexpected)" "inspect scripts/codex/startup-health.sh" ;;
    esac
}

# --- C13: himmel-ops plugin hooks resolve in this checkout ----------------------
# The plugin-delivered hooks.json deliberately guards project-local hooks with
# `[ -f "$h" ] && exec ...` so external/adopter repos fail open.  That also makes
# a missing/moved himmel hook script silent in a himmel checkout.  Doctor surfaces
# that drift without changing hook runtime semantics.
check_c13() {
    local hooks_files=() hooks_json f
    if [ -n "${DOCTOR_HIMMEL_OPS_HOOKS_JSON:-}" ]; then
        hooks_files=("$DOCTOR_HIMMEL_OPS_HOOKS_JSON")
    else
        for f in "$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/hooks.json" \
                 "$CLAUDE_DIR_R"/plugins/cache/himmel/himmel-ops/*/hooks/hooks.json \
                 "$CLAUDE_DIR_R"/plugins/repos/*/himmel-ops/hooks/hooks.json; do
            [ -f "$f" ] && hooks_files+=("$f")
        done
    fi
    if [ "${#hooks_files[@]}" -eq 0 ]; then
        emit INFO C13-plugin-hooks "himmel-ops hooks.json not found (skipped)" "run /himmel-update or verify the himmel-ops plugin install"
        return
    fi
    local missing="" cmd rel target
    for hooks_json in "${hooks_files[@]}"; do
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            rel="$(printf '%s\n' "$cmd" | sed -n 's#.*CLAUDE_PROJECT_DIR/\([^"]*\)".*#\1#p')"
            [ -n "$rel" ] || continue
            target="$REPO_ROOT/$rel"
            [ -f "$target" ] || missing="$missing $rel"
        done <<EOF_CMDS
$(jq -r '(.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | .command // empty | select(contains("CLAUDE_PROJECT_DIR/"))' "$hooks_json" 2>/dev/null)
EOF_CMDS
    done
    if [ -n "$missing" ]; then
        emit WARN C13-plugin-hooks "himmel-ops hooks.json references missing checkout hook(s):$missing - guarded [ -f ] wrappers will silently no-op" "run /himmel-update or restore the missing script(s), then re-run"
    else
        emit OK C13-plugin-hooks "himmel-ops plugin hooks resolve in this checkout"
    fi
}

# --- C14: ollama zero-egress defense-in-depth pin (OLLAMA_NO_CLOUD) -------------
# ADVISORY only. The PRIMARY zero-egress guarantee for the ollama-local lane is
# structural and holds regardless of this var: bare model names never reach
# cloud, cloud is opt-in only via the -cloud suffix. OLLAMA_NO_CLOUD=1 is an
# additional belt-and-suspenders pin applied at machine-setup (see
# docs/setup/new-machine.md) — never a hard fail, and skipped where ollama
# isn't installed.
check_c14() {
    if ! command -v ollama >/dev/null 2>&1; then
        emit OK C14-ollama-no-cloud "ollama CLI not on PATH (ollama-local lane not in use here — skipped)"
        return
    fi
    if [ -n "${OLLAMA_NO_CLOUD:-}" ]; then
        emit OK C14-ollama-no-cloud "OLLAMA_NO_CLOUD=$OLLAMA_NO_CLOUD (zero-egress defense-in-depth pin is set)"
    else
        emit WARN C14-ollama-no-cloud \
            "zero-egress defense-in-depth pin unset -- the primary guarantee (bare model names, cloud opt-in only via -cloud suffix) still holds, but the belt-and-suspenders OLLAMA_NO_CLOUD pin is off" \
            "set per docs/setup/new-machine.md #1 Required environment (setx on Windows, launchctl/shell-profile on macOS, systemd drop-in/shell-profile on Linux)"
    fi
}

# --- issue filing ---------------------------------------------------------------
resolve_issue_repo() {
    [ -n "$REPO_FLAG" ] && { printf '%s\n' "$REPO_FLAG"; return 0; }
    [ -n "${HIMMEL_DOCTOR_ISSUE_REPO:-}" ] && { printf '%s\n' "$HIMMEL_DOCTOR_ISSUE_REPO"; return 0; }
    local url; url="$(git remote get-url origin 2>/dev/null || true)"
    case "$url" in
        *github.com[:/]*) printf '%s\n' "$url" | sed -E 's#.*github\.com[:/]([^/]+/[^/]+)#\1#; s#\.git$##'; return 0 ;;
    esac
    return 1
}

file_issue() {
    local title repo existing
    title="[himmel-doctor] $((n_fail+n_warn+n_info)) finding(s) on $(uname -s 2>/dev/null || echo ?)"
    if ! command -v gh >/dev/null 2>&1; then
        echo "  gh not found — report saved at: $BODY"
        echo "  manual: gh issue create --repo <owner/name> --title '$title' --body-file '$BODY'"
        cp "$BODY" "$CLAUDE_DIR_R/himmel-doctor-report.md" 2>/dev/null && echo "  (also copied to $CLAUDE_DIR_R/himmel-doctor-report.md)"
        return 0
    fi
    if ! repo="$(resolve_issue_repo)"; then
        echo "  cannot resolve a public repo — pass --repo owner/name or set HIMMEL_DOCTOR_ISSUE_REPO"
        return 0
    fi
    existing="$(gh issue list --repo "$repo" --state open --search 'in:title himmel-doctor' --json title,url 2>/dev/null | jq -r '.[] | select(.title|startswith("[himmel-doctor]")) | .url' | head -1 || true)"
    if [ -n "$existing" ]; then
        echo "  an open himmel-doctor issue already exists: $existing (skipping create — comment there instead)"
        return 0
    fi
    if ! gh issue create --repo "$repo" --title "$title" --body-file "$BODY"; then
        # Don't lose the report when filing fails (auth/network) — the EXIT trap rm's $BODY.
        cp "$BODY" "$CLAUDE_DIR_R/himmel-doctor-report.md" 2>/dev/null \
            && echo "  issue filing failed — report saved at $CLAUDE_DIR_R/himmel-doctor-report.md" >&2
        return 0
    fi
}

# --- C15: enabled-plugin drift beyond the lean floor (HIMMEL-1032) ----------------
# Read-only WARN: surfaces plugins enabled beyond the lean template floor (the
# ad-hoc /plugin drift that costs context at session start). Never mutates — it
# tells the operator what /himmel-update's reconcile WOULD disable so a plugin
# they intentionally want isn't lost: keep it by adding it to settings.local.json.
# The lean floor = template-`true` plugins; settings.local.json `true` entries
# also count as intentionally-kept (never reported as drift).
check_c15() {
    local tmpl="$REPO_ROOT/docs/setup/settings-template.json"
    if [ ! -f "$SETTINGS" ]; then
        emit INFO C15-plugins "no ~/.claude/settings.json — plugin-set drift not checked"
        return
    fi
    if ! command -v jq >/dev/null 2>&1; then
        emit INFO C15-plugins "jq not on PATH — plugin-set drift not checked"
        return
    fi
    if [ ! -f "$tmpl" ] || ! jq -e . "$tmpl" >/dev/null 2>&1; then
        emit INFO C15-plugins "lean template not found/parseable ($tmpl) — drift not checked"
        return
    fi
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
        emit INFO C15-plugins "settings.json ($SETTINGS) not valid JSON, drift not checked"
        return
    fi
    local tmpl_ep live_ep local_ep local_file drift count
    tmpl_ep="$(jq -c '.enabledPlugins // {}' "$tmpl")"
    live_ep="$(jq -c '.enabledPlugins // {}' "$SETTINGS")"
    local_file="$CLAUDE_DIR_R/settings.local.json"
    local_ep='{}'
    [ -f "$local_file" ] && jq -e . "$local_file" >/dev/null 2>&1 && local_ep="$(jq -c '.enabledPlugins // {}' "$local_file")"
    # drift = live-enabled specs that are NOT template-true AND absent from
    # settings.local.json. ANY local entry (true OR false) is an explicit
    # operator override, so it is never drift — a local `false` means the
    # operator already disabled it on purpose.
    drift="$(jq -rn --argjson t "$tmpl_ep" --argjson l "$live_ep" --argjson lo "$local_ep" '
        [ $l | to_entries[] | select(.value != false)
          | .key as $k | select( (($t[$k]) != true) and (($lo | has($k)) | not) ) | $k ] | .[]' 2>/dev/null || true)"
    count="$(printf '%s\n' "$drift" | grep -c . || true)"
    if [ "${count:-0}" -eq 0 ]; then
        emit OK C15-plugins "enabled plugins are at the lean floor — no drift"
        return
    fi
    local list; list="$(printf '%s' "$drift" | paste -sd, - 2>/dev/null | sed 's/,/, /g')"
    [ -n "$list" ] || list="$(printf '%s' "$drift" | tr '\n' ' ')"
    emit WARN C15-plugins "$count plugin(s) enabled beyond the lean floor (context cost at session start): $list" \
        "reclaim: bash scripts/machine-setup/reconcile-enabled-plugins.sh (or set HIMMEL_RECONCILE_PLUGINS=1 so /himmel-update enforces it). Keep any you want by adding \"<plugin>\": true to ~/.claude/settings.local.json first."
}

# --- run ------------------------------------------------------------------------
echo "himmel-doctor — $(uname -s 2>/dev/null || echo ?) — checkout: $REPO_ROOT"
echo
if [ "$DO_FIX" = 1 ]; then fix_c1; else check_c1; fi
check_c2
check_c3
check_c4
check_c5
check_c6
check_c7
check_c8
check_c9
check_c10
check_c11
check_c12
check_c13
check_c14
check_c15
echo
printf 'Summary: %s%d FAIL%s  %s%d WARN%s  %s%d INFO%s\n' "$C_RED" "$n_fail" "$C_0" "$C_YEL" "$n_warn" "$C_0" "$C_DIM" "$n_info" "$C_0"

if [ "$DO_FILE" = 1 ] && [ $((n_fail+n_warn+n_info)) -gt 0 ]; then
    echo; echo "Filing a consolidated GitHub issue:"; file_issue
elif [ $((n_fail+n_warn)) -gt 0 ] && [ -t 1 ]; then
    echo; printf 'File a consolidated GitHub issue? [y/N] '; read -r ans
    case "$ans" in y|Y|yes) file_issue ;; *) echo "  (skipped — re-run with --file-issue to file)";; esac
fi

[ "$n_fail" -eq 0 ]
