#!/usr/bin/env bash
# himmel-doctor.sh — diagnose common himmel-harness health problems, print a
# severity-grouped report with remediation, and (on request) file ONE
# consolidated GitHub issue. Read-only except `--fix` (heals C1-guardrail wiring).
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
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/resolve-powershell.sh"
# shellcheck source=lib/cadence-format.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/cadence-format.sh"
# shellcheck source=lib/runtime-preflight.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/runtime-preflight.sh"
# shellcheck source=lib/observability-registry.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/observability-registry.sh"

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
        -h|--help) sed -n '2,/^set /p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
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

# --- C1-node: RETIRED (HIMMEL-2033) --------------------------------------------
# The response-compression plugin whose SessionStart/UserPromptSubmit node hooks
# this check classified and healed is gone, so there is nothing left to check.
# Check ids are NOT renumbered: C1-guardrail below and C2..C21 keep their ids.

# --- C1-guardrail: user-level guardrail block's baked node path -----------------
# scripts/setup-hooks.sh|.ps1 --guardrail-mode global bakes the setup-time
# ABSOLUTE node path into the 3 user-level guardrail hooks. If node moves
# (e.g. a switch from a winget MSI to nvm-windows, HIMMEL-2013) every tool
# call errors and the guardrails fail OPEN.
check_c1_guardrail() {
    [ -f "$SETTINGS" ] || return 0
    local gb="$REPO_ROOT/scripts/hooks/guardrail-block.mjs"
    [ -f "$gb" ] || return 0
    local node_bin
    node_bin="$(resolve_node 2>/dev/null)" || return 0
    local js
    js="$(CLAUDE_USER_SETTINGS="$SETTINGS" "$node_bin" "$gb" status --json 2>/dev/null)" || {
        emit WARN C1-guardrail "guardrail-block status --json failed" "run: node scripts/hooks/guardrail-block.mjs status --json"
        return 0
    }
    local mode
    mode="$(printf '%s' "$js" | jq -r '.mode')"
    if [ "$mode" != global ]; then
        emit OK C1-guardrail "no user-level guardrail block (mode=$mode)"
        return 0
    fi
    local stale
    stale="$(printf '%s' "$js" | jq -r '[.hooks[] | select(.present and (.nodeResolves|not)) | .basename] | join(", ")')"
    if [ -n "$stale" ]; then
        local stale_node
        stale_node="$(printf '%s' "$js" | jq -r '[.hooks[] | select(.present and (.nodeResolves|not)) | .nodePath] | .[0] // empty')"
        emit FAIL C1-guardrail "user-level guardrail hooks point at a missing node ($stale; nodePath=$stale_node) — every tool call errors and the guardrails fail OPEN" "himmel-doctor --fix (re-bakes via setup-hooks --guardrail-mode global)"
        return 1
    fi
    emit OK C1-guardrail "user-level guardrail block node path resolves"
    return 0
}

fix_c1_guardrail() {
    if check_c1_guardrail; then return 0; fi
    if is_windows; then
        local ps_bin
        ps_bin="$(resolve_powershell)" || { echo "  fix_c1_guardrail: no PowerShell interpreter found" >&2; return 1; }
        CLAUDE_USER_SETTINGS="$SETTINGS" "$ps_bin" -NoProfile -ExecutionPolicy Bypass -File "$REPO_ROOT/scripts/setup-hooks.ps1" -GuardrailMode global -Yes
    else
        CLAUDE_USER_SETTINGS="$SETTINGS" bash "$REPO_ROOT/scripts/setup-hooks.sh" --guardrail-mode global --yes
    fi
    echo "  re-checking C1-guardrail after --fix:"
    check_c1_guardrail
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
# Same failure class as C1-guardrail: a macOS GUI launch has a minimal PATH, so an MCP
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
            # HIMMEL-1692: /clean already refuses to prune a worktree with
            # TRACKED modifications, so "prune with /clean" is misleading
            # advice for one that is dirty — it will just skip it.
            # THREE states, not two (codex CR round 4). Tracked modifications
            # are a definite refusal. Untracked files are the AMBIGUOUS case —
            # clean-garden force-prunes its is_ignorable_stray() allowlist and
            # refuses everything else as forgotten work — but "ambiguous" is not
            # a reason to fall back to the flat "prune with /clean", which is
            # exactly wrong for the shape this ticket was filed over (a 502-line
            # untracked spec sitting in a merged worktree). Say what is actually
            # known and point at --dry-run, rather than asserting either verdict.
            # Deliberately does NOT re-enumerate the allowlist here: duplicating
            # it in the doctor is what would drift out of sync with the sweep.
            #
            # Do NOT advise "just commit it" (codex adversarial round 2). On a
            # NON-GITHUB forge, clean-garden's is_branch_mergeable_for_prune()
            # falls back to a per-branch merged-PR COUNT with no tip match, so a
            # fresh commit on this already-merged branch does not protect it:
            # the prune still fires and takes the branch with it, leaving that
            # commit reachable only through the reflog. (On github the exact
            # PR_HEAD_MATCH check does stop the prune — but the remedy must be
            # safe on both forges, not just the one this box happens to use.)
            # Moving the work OFF the merged branch is correct on every forge.
            local c7_remedy="verify, then prune with /clean (dry-runs first); do NOT reuse this branch name"
            if [ -n "$(git -C "$wt_path" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
                c7_remedy="worktree has uncommitted changes — /clean refuses to prune it; move them OFF this merged branch (git switch -c <new-branch>, or stash) then re-run /clean — do NOT just commit in place, a non-github prune ignores the moved tip and would delete the commit with the branch"
            elif [ -n "$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null)" ]; then
                # Phrasing note: write "dry-run /clean", not the double-dash
                # flag spelling. The C7 STATIC guard in test-himmel-doctor.sh
                # scans this entire function body — comments included — for
                # destructive-git substrings, and the flag spelling collides
                # with one of them even inside a quoted advisory string.
                c7_remedy="worktree has UNTRACKED files — /clean prunes it only if they are known-disposable tool strays, and refuses them as forgotten work otherwise; dry-run /clean first, and move anything worth keeping OFF this merged branch before pruning"
            fi
            emit WARN C7-shipped \
                "worktree $wt_path (branch $wt_branch) maps to a MERGED PR — shipped work lingering" \
                "$c7_remedy"
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
qmd-cadence|${QMD_CADENCE_BAT_DIR:-$uh/.claude/qmd-cadence}|bash scripts/luna/qmd-cadence.sh arm --force
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

# --- C16: delegate to `himmelctl status --json` for install/wiring TRUTH -------
# HIMMEL-755 sub-ticket F (doctor<->status dedup). Operator-locked design:
# `himmelctl status --json` OWNS install/wiring truth (the install manifest's
# desired-vs-actual diff). C1-C15 stay harness-health checks status does not
# cover (resolution robustness, shadowing, dirty vaults, drift, PATH-
# fragility, worktrees, registry gaps, egress pins, startup health) -- none
# of them reimplement a manifest presence probe, so there is nothing to
# dedup there. This section instead COMPOSES the two surfaces: run status
# ONCE and surface its red/degraded DESIRED items as doctor findings, rather
# than doctor re-deriving any install/wiring presence fact itself. Read-only;
# degrades gracefully -- no install profile (rc=2), no node, or any other
# unparsable/non-zero result is an INFO skip, never a crash or a false FAIL
# (mirrors the read-only advisory stance of C7/C9-C12).
check_c16() {
    local node_bin
    if ! node_bin="$(resolve_node 2>/dev/null)"; then
        emit INFO C16-status "no node found -- himmelctl status delegation skipped" "install Node.js to enable install/wiring-truth findings via himmel-doctor"
        return
    fi
    local bin="$REPO_ROOT/scripts/himmelctl/bin.js"
    if [ ! -f "$bin" ]; then
        emit INFO C16-status "scripts/himmelctl/bin.js not found -- delegation skipped"
        return
    fi

    local out rc
    out="$("$node_bin" "$bin" status --json 2>/dev/null)"; rc=$?
    case "$rc" in
        0) : ;;
        2) emit INFO C16-status "no himmelctl install profile found -- run 'node scripts/himmelctl/bin.js install' to enable install/wiring-truth findings here"; return ;;
        *) emit INFO C16-status "himmelctl status --json unavailable (rc=$rc) -- delegation skipped"; return ;;
    esac

    # Require the EXPECTED schema, not merely valid JSON: an object with an
    # array-valued .items. Valid JSON of the wrong shape (e.g. `{}` from a
    # future/broken status build) would otherwise pass a bare `jq -e .`, yield
    # zero items, and emit a misleading "no findings" OK — treat it as
    # unavailable and take the delegation-skipped path instead.
    if ! command -v jq >/dev/null 2>&1 \
       || ! printf '%s' "$out" | jq -e 'type == "object" and (.items | type == "array")' >/dev/null 2>&1; then
        emit INFO C16-status "himmelctl status --json output unavailable/unparsable -- delegation skipped"
        return
    fi

    local bad count
    bad="$(printf '%s' "$out" | jq -r '.items[]? | select(.desired == true and (.severity == "red" or .severity == "degraded")) | "\(.severity)/\(.id): \(.detail)"' 2>/dev/null || true)"
    count="$(printf '%s\n' "$bad" | grep -c . || true)"
    if [ "${count:-0}" -eq 0 ]; then
        emit OK C16-status "himmelctl status: no red/degraded install/wiring findings"
        return
    fi
    emit WARN C16-status "$count himmelctl install/wiring finding(s) (delegated from 'himmelctl status --json')" "node scripts/himmelctl/bin.js status   # or: ... ensure"
    printf '%s\n' "$bad" | sed 's/^/       · /'
    # Persist the per-item detail into the filed-issue body too, not only
    # stdout — otherwise `--file-issue` reports the count without the items.
    printf '%s\n' "$bad" | sed 's/^/  - /' >> "$BODY"
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
    # A parseable file whose enabledPlugins is a non-object (string/array) would
    # make the drift has($k) query error (suppressed → a false OK). Skip instead.
    case "$(jq -r '.enabledPlugins | type' "$tmpl" 2>/dev/null)" in
        object|null) ;;
        *) emit INFO C15-plugins "lean template has a non-object enabledPlugins — drift not checked"; return ;;
    esac
    case "$(jq -r '.enabledPlugins | type' "$SETTINGS" 2>/dev/null)" in
        object|null) ;;
        *) emit INFO C15-plugins "settings.json has a non-object enabledPlugins — drift not checked"; return ;;
    esac
    tmpl_ep="$(jq -c '.enabledPlugins // {}' "$tmpl")"
    live_ep="$(jq -c '.enabledPlugins // {}' "$SETTINGS")"
    local_file="$CLAUDE_DIR_R/settings.local.json"
    local_ep='{}'
    if [ -f "$local_file" ]; then
        # A malformed local file is NOT "no overrides": treating it as {} would
        # report the operator's intentionally-kept plugins as drift, while the
        # reconciler itself refuses to run in that state. Skip the check instead.
        if ! jq -e . "$local_file" >/dev/null 2>&1; then
            emit INFO C15-plugins "settings.local.json ($local_file) not valid JSON — drift not checked (its overrides can't be read)"
            return
        fi
        # `jq -e .` only proves it PARSES. A parseable file whose enabledPlugins
        # is not an object (string/array/number) makes local_ep unusable and the
        # later has($k) would error (suppressed → false OK). Skip on bad shape too.
        case "$(jq -r '.enabledPlugins | type' "$local_file" 2>/dev/null)" in
            object|null) local_ep="$(jq -c '.enabledPlugins // {}' "$local_file")" ;;
            *) emit INFO C15-plugins "settings.local.json ($local_file) has a non-object enabledPlugins — drift not checked"; return ;;
        esac
    fi
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
        "reclaim: bash \"$REPO_ROOT/scripts/machine-setup/reconcile-enabled-plugins.sh\" (or set HIMMEL_RECONCILE_PLUGINS=1 so /himmel-update enforces it). Keep any you want by adding \"<plugin>\": true to ~/.claude/settings.local.json first."
}

# --- C17: dependency readiness -- enabled skills vs their required API keys ----
# (HIMMEL-1393). Delegates to scripts/lib/dependency-readiness.sh (mirrors how
# C10 delegates to propagation-drift.sh) so the SAME declaration map + logic
# is shared with himmel-update's dependency-readiness advisory step. Two
# drift directions, both WARN-only, never FAIL: (1) an enabled skill declares
# a required env key that is absent/blank; (2) an enabled+keyed skill whose
# toolkit a doc still calls disabled. Presence-only -- never reads/prints a
# key VALUE. See the lib's own header comment for the motivating case (a
# credentials file existing is not evidence of an active subscription).
check_c17() {
    local lib="$REPO_ROOT/scripts/lib/dependency-readiness.sh"
    if [ ! -f "$lib" ]; then
        emit INFO C17-dep-readiness "scripts/lib/dependency-readiness.sh not found -- skipped"
        return
    fi
    # shellcheck source=scripts/lib/dependency-readiness.sh
    # shellcheck disable=SC1091
    . "$lib"
    local out; out="$(dependency_readiness_scan 2>/dev/null)"
    local total; total="$(printf '%s\n' "$out" | grep -c '^READY-DRIFT ' || true)"
    if [ "${total:-0}" -eq 0 ]; then
        emit OK C17-dep-readiness "no enabled skill is missing its declared API key, and no ready toolkit is mis-marked disabled"
        return
    fi
    emit WARN C17-dep-readiness \
        "$total dependency-readiness finding(s) -- presence-only check, key values never read" \
        "key-missing: confirm the key in its .env, or disable the skill if there's no active subscription. doc-disabled: correct the doc."
    printf '%s\n' "$out" | grep '^READY-DRIFT key-missing ' | awk '{print "       · "$3" is enabled but "$4" is absent/blank"}'
    printf '%s\n' "$out" | grep '^READY-DRIFT doc-disabled ' | awk '{print "       · "$3" is enabled+keyed but a doc still marks its toolkit disabled"}'
}

# --- C18: monitored zero-usage command cluster (2026-07-29 skill-hygiene spec) --
# WARN-only, "flag but don't auto-fix" like C15. That survey found five
# project-scope commands with WEAK evidence (no supersession found anywhere,
# "never used" is the only signal) and disposed them KEEP-monitor rather than
# removed. No persistent usage-tracking mechanism exists yet (the survey's own
# open question, §4 Q5) -- so this check applies the survey's own age/cost
# thresholds (never-used AND age>60d, OR never-used AND age>30d AND cost>50
# tok) to a STATIC declared table rather than a live usage counter. A command
# dropping out of `.claude/commands/` (disabled/removed) silently drops out of
# this check too -- nothing to update there. Update/remove an entry once a
# fresh usage signal actually resolves it; don't let this table go stale.
DOCTOR_C18_MONITORED='
quiet-run|2026-05-18|17
retitle|2026-06-22|37
improve|2026-05-25|40
guardrail-sim|2026-06-21|71
cr-scores|2026-06-19|21
'

# portable YYYY-MM-DD -> epoch seconds; GNU date first (Git Bash/Linux), then
# BSD date -j (macOS). Echoes nothing (rc=1) on an unparsable/foreign date --
# callers must treat that as "skip", never crash.
_c18_epoch() {
    date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null
}

check_c18() {
    local cmds_dir="${DOCTOR_C18_COMMANDS_DIR:-$REPO_ROOT/.claude/commands}"
    # Test seam only (default unset -- production always uses the built-in
    # table above): lets the hermetic test supply landed-dates relative to
    # its own run time instead of asserting against a live-clock threshold
    # crossing on the real, fixed 2026-xx-xx dates.
    local monitored="${DOCTOR_C18_MONITORED_OVERRIDE:-$DOCTOR_C18_MONITORED}"
    local now; now="$(date +%s)"
    local name landed cost added_epoch age_days hits hit_n
    hits=""; hit_n=0
    while IFS='|' read -r name landed cost; do
        [ -n "$name" ] || continue
        [ -f "$cmds_dir/$name.md" ] || continue   # already disabled/removed -- nothing to flag
        added_epoch="$(_c18_epoch "$landed")"
        case "$added_epoch" in ''|*[!0-9]*) continue ;; esac   # unparsable date -- skip, never crash
        age_days=$(( (now - added_epoch) / 86400 ))
        if [ "$age_days" -gt 60 ] || { [ "$age_days" -gt 30 ] && [ "${cost:-0}" -gt 50 ]; }; then
            hits="${hits}${name} (${age_days}d old, ~${cost} tok)
"
            hit_n=$((hit_n + 1))
        fi
    done <<EOF
$monitored
EOF
    if [ "$hit_n" -eq 0 ]; then
        emit OK C18-skill-usage "no monitored zero-usage command has crossed its staleness threshold"
        return
    fi
    emit WARN C18-skill-usage \
        "$hit_n monitored command(s) from the 2026-07-29 skill-hygiene survey are still zero-usage past their threshold" \
        "re-confirm real usage; disable/remove if still unused, or clear the entry in check_c18 if it's now in active use"
    printf '%s' "$hits" | sed '/^$/d' | sed 's/^/       · /'
}

# --- C19: observability stack drift + endpoint readiness (read-only advisory) ---
# HIMMEL-1676: the alerting assets existed in-repo while the installed stack had
# no rule groups. Compare the installed copies and query the two local endpoints;
# every branch is WARN/INFO-only and no --fix path mutates the stack.
check_c19() {
    if [ "${DOCTOR_OBSERVABILITY_SKIP:-0}" = 1 ]; then
        emit OK C19-observability "observability drift checks skipped by test seam"
        return
    fi

    local install_dir="${DOCTOR_OBSERVABILITY_INSTALL_DIR:-${LOCALAPPDATA:-${HOME:-}/AppData/Local}/himmel/observability}"
    local source_dir="$REPO_ROOT/scripts/observability"
    local drift=""
    # compared=1 only on the branch that actually ran cmp/diff (glm-2 CR
    # finding, HIMMEL-1676): cmp/diff-unavailable already emits its own INFO
    # here, so it must not ALSO fall through to the "match the repo copies" OK
    # below — that would claim a verification that never happened.
    local compared=0
    if [ ! -d "$install_dir" ]; then
        drift=" stack-not-installed"
    elif ! command -v cmp >/dev/null 2>&1 || ! command -v diff >/dev/null 2>&1; then
        emit INFO C19-observability "cmp/diff unavailable — installed observability assets not compared" "install cmp + diff, then re-run"
    else
        compared=1
        cmp -s "$source_dir/prometheus.yml" "$install_dir/prometheus.yml" 2>/dev/null || drift="$drift prometheus.yml"
        cmp -s "$source_dir/alerts.rules.yml" "$install_dir/alerts.rules.yml" 2>/dev/null || drift="$drift alerts.rules.yml"
        diff -qr "$source_dir/provisioning" "$install_dir/grafana-provisioning" >/dev/null 2>&1 || drift="$drift provisioning/"
    fi
    if [ -n "$drift" ]; then
        emit WARN C19-observability "observability stack stale — re-run install-stack.ps1 (drift:$drift)" "powershell -ExecutionPolicy Bypass -File scripts/observability/install-stack.ps1"
    elif [ "$compared" -eq 1 ]; then
        emit OK C19-observability "installed observability assets match the repo copies"
    fi

    local missing=""
    [ -n "${GRAFANA_TELEGRAM_BOT_TOKEN:-}" ] || missing="$missing GRAFANA_TELEGRAM_BOT_TOKEN"
    [ -n "${GRAFANA_TELEGRAM_CHAT_ID:-}" ] || missing="$missing GRAFANA_TELEGRAM_CHAT_ID"
    if [ -n "$missing" ]; then
        emit WARN C19-observability "Grafana Telegram delivery variable(s) unset:$missing" "set the user-scoped variables, then re-run install-stack.ps1"
    else
        emit OK C19-observability "Grafana Telegram delivery variables are set"
    fi

    local curl_bin="${DOCTOR_CURL_BIN:-curl}"
    if [ ! -x "$curl_bin" ] && ! command -v "$curl_bin" >/dev/null 2>&1; then
        emit INFO C19-observability "curl unavailable — Prometheus rules and flow exporter not probed" "install curl, then re-run"
        return
    fi

    local rules_url="${DOCTOR_PROMETHEUS_RULES_URL:-http://127.0.0.1:9090/api/v1/rules}"
    local exporter_url="${DOCTOR_FLOW_EXPORTER_URL:-http://127.0.0.1:9877/metrics}"
    local rules_json rules_rc groups
    rules_json="$("$curl_bin" -fsS --max-time 2 "$rules_url" 2>/dev/null)"; rules_rc=$?
    if [ "$rules_rc" -ne 0 ]; then
        emit INFO C19-observability "Prometheus rules endpoint unavailable — rule groups not checked" "start Prometheus, then re-run"
    elif ! command -v jq >/dev/null 2>&1; then
        emit INFO C19-observability "jq unavailable — Prometheus rule-group response not parsed" "install jq, then re-run"
    elif ! groups="$(printf '%s' "$rules_json" | jq -er 'select(.status == "success") | .data.groups | length' 2>/dev/null)"; then
        emit INFO C19-observability "Prometheus rules endpoint returned an unexpected response — rule groups not checked" "inspect $rules_url"
    elif [ "$groups" -eq 0 ]; then
        emit WARN C19-observability "Prometheus has zero rule groups — no alert rule has evaluated" "re-run install-stack.ps1, restart Prometheus, then inspect $rules_url"
    else
        emit OK C19-observability "Prometheus reports $groups rule group(s)"
    fi

    if "$curl_bin" -fsS --max-time 2 "$exporter_url" >/dev/null 2>&1; then
        emit OK C19-observability "flow exporter answers on $exporter_url"
    else
        emit WARN C19-observability "flow exporter on $exporter_url is not answering" "start himmel-observability-flow-exporter, then re-run"
    fi

    # Grafana liveness (codex-adv CR finding, HIMMEL-1676): the checks above
    # (Prometheus rule-group count, Telegram vars set) can all read OK while
    # the component that actually evaluates + delivers alerts is down —
    # README.md's Alert rules section is explicit that "No Alertmanager is
    # installed in this stack" and Grafana's provisioning/alerting/rules.yaml
    # "is what actually evaluates and delivers to Telegram" (RATIFIED F3).
    # This is a liveness probe only (Grafana up/down), not a verification of
    # its provisioned alert-rule/contact-point state — narrower than the full
    # readiness check codex recommended, but it closes the "Do not ship" case
    # the finding raised: Grafana's task stopped, everything else reports OK.
    local grafana_url="${DOCTOR_GRAFANA_HEALTH_URL:-http://127.0.0.1:3000/api/health}"
    if "$curl_bin" -fsS --max-time 2 "$grafana_url" >/dev/null 2>&1; then
        emit OK C19-observability "Grafana answers on $grafana_url (the actual alert evaluator/delivery path)"
    else
        emit WARN C19-observability "Grafana on $grafana_url is not answering — no alert can evaluate or deliver even if Prometheus/exporter are healthy" "start the Grafana service, then re-run"
    fi
}

# --- C20: running node major vs .nvmrc (HIMMEL-1986 / HIMMEL-2010) --------------
# FAILS on drift. It shipped advisory (HIMMEL-1986) because the drift was TRUE
# on the box it landed on — on OVERLORD8 (2026-08-20/21) .nvmrc pinned 24 while
# every hook, the Jira CLI, run-hook-with-bash.js and the lanes suites ran on
# v26.7.0, and a default-fail check would have been an outage, not a gate. That
# machine is now aligned (HIMMEL-2010), so the ladder's second rung applies: a
# rediscovered-every-session drift becomes structural, not a louder warning.
# The doctor still never edits .nvmrc and never switches a runtime — WHICH major
# to converge on stays the operator's call, the FAIL only refuses to let the two
# disagree silently.
#
# Two exits, both still visible as a WARN:
#   $CI / $GITHUB_ACTIONS  — a runner installs the pin itself; its node is not
#                            this operator's machine to fix.
#   NODE_MAJOR_DRIFT_OK=1  — the documented bypass (deliberately exercising an
#                            unpinned major), same *_OK=1 shape as the hooks.
#
# PATH's node, not resolve_node's fallback chain: the question is what the next
# hook/CLI invocation will ACTUALLY run, and that is `command -v node`.
# Test seam: DOCTOR_NVMRC overrides the pin file.
check_c20() {
    local nvmrc pin node_bin cur cur_major sev=FAIL why=""
    nvmrc="${DOCTOR_NVMRC:-$REPO_ROOT/.nvmrc}"
    if [ ! -f "$nvmrc" ]; then emit OK C20-node "no .nvmrc in this checkout (skipped)"; return; fi
    # The pin is parsed by the shared runtime policy (HIMMEL-1991), not a second
    # copy here: `24`, `v24`, `24.1.0` -> 24; `lts/iron` -> empty (nothing to
    # compare, which is a skip and never a drift).
    pin="$(RUNTIME_PREFLIGHT_NVMRC="$nvmrc" runtime_preflight_pin)"
    if [ -z "$pin" ]; then
        emit INFO C20-node "$nvmrc does not pin a numeric major — nothing to compare" "pin a major (e.g. 24) if this checkout should hold one"
        return
    fi
    node_bin="$(command -v node 2>/dev/null || true)"
    if [ -z "$node_bin" ]; then
        emit INFO C20-node "no node on PATH — cannot compare against the .nvmrc pin ($pin)"
        return
    fi
    cur="$("$node_bin" --version 2>/dev/null | tr -d '\r')"
    # Same anchored parser as the pin above (HIMMEL-1991): a prefix-only read
    # would report `v24-corrupt` as ALIGNED with a pin of 24 instead of saying
    # it could not read the version at all.
    cur_major="$(_runtime_preflight_major "$cur")"
    if [ -z "$cur_major" ]; then
        emit INFO C20-node "node --version returned '$cur' — cannot read a major to compare against the pin ($pin)"
        return
    fi
    if [ "$cur_major" = "$pin" ]; then
        emit OK C20-node "node $cur matches the .nvmrc pin ($pin)"
        return
    fi
    if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then sev=WARN; why=" [CI — advisory here]"; fi
    if [ "${NODE_MAJOR_DRIFT_OK:-0}" = 1 ]; then sev=WARN; why=" [NODE_MAJOR_DRIFT_OK=1]"; fi
    emit "$sev" C20-node "node major drift: running $cur, .nvmrc pins $pin — hooks, the Jira CLI, run-hook-with-bash.js and the lanes suites all run on the UNPINNED major here, while CI and adopters run $pin$why" \
        "align this box (nvm-windows/volta: install + use $pin), or bump .nvmrc to $cur_major once run-shell-tests.sh and the lanes suite are green on it — the pin bump is an operator decision, the doctor never makes it (HIMMEL-1986); NODE_MAJOR_DRIFT_OK=1 downgrades this to a warning (HIMMEL-2010)"
}

# --- C21: hermes himmel_agent profile default vs lanes.json record (advisory) ---
# HIMMEL-2024: hermes-critic.sh and hermes-oneshot both defer to whichever
# model the himmel_agent hermes profile currently defaults to (deliberately
# NOT pinned in this repo — that is the point of HIMMEL-2017/#1811), so a
# silent hermes-side profile-default swap changes their behaviour with
# nothing here to notice it. Advisory only (WARN, never FAIL): this never
# edits the hermes profile or lanes.json, and never invokes the hermes CLI —
# a plain offline read of the active profile's config.yaml. The expected
# model is READ from lanes.json (`profileDefaultModel` on the hermes rows),
# never hardcoded here, so a future profile move only needs a lanes.json edit.
# Test seams: DOCTOR_HERMES_HOME overrides the resolved hermes install root;
# DOCTOR_LANES_JSON overrides the lanes.json path read for profileDefaultModel.
check_c21() {
    local lanes_json expected oneshot_model critics_model hermes_home active_profile cfg cur_model
    lanes_json="${DOCTOR_LANES_JSON:-$REPO_ROOT/scripts/lanes/lanes.json}"
    if ! command -v jq >/dev/null 2>&1; then
        emit INFO C21-hermes-profile "jq not on PATH — hermes profile-default drift not checked"
        return
    fi
    if [ ! -f "$lanes_json" ] || ! jq -e . "$lanes_json" >/dev/null 2>&1; then
        emit INFO C21-hermes-profile "lanes.json not found/parseable — hermes profile-default drift not checked"
        return
    fi
    # Both hermes-oneshot and hermes-critics are expected to carry
    # profileDefaultModel. Read each SEPARATELY (not merged via `// empty` +
    # sort -u) so a row that silently DROPPED the field is distinguishable
    # from the two rows genuinely agreeing — merging first would let one
    # undeclared row hide behind the other's value and still read as OK.
    oneshot_model="$(jq -r '.lanes[] | select(.id=="hermes-oneshot") | .profileDefaultModel // empty' "$lanes_json" 2>/dev/null)"
    critics_model="$(jq -r '.lanes[] | select(.id=="hermes-critics") | .profileDefaultModel // empty' "$lanes_json" 2>/dev/null)"
    if [ -z "$oneshot_model" ] && [ -z "$critics_model" ]; then
        emit INFO C21-hermes-profile "lanes.json hermes-oneshot/hermes-critics rows have no profileDefaultModel recorded — nothing to compare"
        return
    fi
    if [ -z "$oneshot_model" ] || [ -z "$critics_model" ]; then
        emit WARN C21-hermes-profile "only one of lanes.json's hermes-oneshot/hermes-critics rows declares profileDefaultModel (hermes-oneshot='${oneshot_model:-<none>}' hermes-critics='${critics_model:-<none>}') — the undeclared row's model isn't checked" \
            "add profileDefaultModel to the row that's missing it in scripts/lanes/lanes.json"
        return
    fi
    if [ "$oneshot_model" != "$critics_model" ]; then
        emit WARN C21-hermes-profile "lanes.json's hermes-oneshot and hermes-critics rows disagree on profileDefaultModel ('$oneshot_model' vs '$critics_model')" \
            "reconcile the two rows in scripts/lanes/lanes.json before this check can compare against the live hermes install"
        return
    fi
    expected="$oneshot_model"
    # Resolution order: DOCTOR_HERMES_HOME (test-only override) > HERMES_HOME
    # (explicit override) > $LOCALAPPDATA/hermes (Windows, when set) >
    # $HOME/.hermes (Linux/macOS default — upstream hermes' own default
    # config home).
    if [ -n "${DOCTOR_HERMES_HOME:-}" ]; then hermes_home="$DOCTOR_HERMES_HOME"
    elif [ -n "${HERMES_HOME:-}" ]; then hermes_home="$HERMES_HOME"
    elif [ -n "${LOCALAPPDATA:-}" ]; then hermes_home="$LOCALAPPDATA/hermes"
    else hermes_home="$HOME/.hermes"
    fi
    if [ ! -d "$hermes_home" ]; then
        emit INFO C21-hermes-profile "no hermes install found ($hermes_home) — hermes profile-default drift not checked"
        return
    fi
    active_profile="$(tr -d '\r\n' < "$hermes_home/active_profile" 2>/dev/null)"
    [ -n "$active_profile" ] || active_profile="himmel_agent"
    cfg="$hermes_home/profiles/$active_profile/config.yaml"
    if [ ! -f "$cfg" ]; then
        emit INFO C21-hermes-profile "no config.yaml for the active hermes profile ($active_profile) — drift not checked"
        return
    fi
    # Strip a trailing \r (CRLF config), a trailing "# comment", and
    # surrounding quotes — a hermes-side re-dump of this YAML is free to
    # quote/comment the scalar and this is advisory-only: a false WARN from
    # a cosmetic re-dump is exactly the noise this check must not add.
    cur_model="$(awk "
        /^model:/ { f=1; next }
        f && /^[^ ]/ { f=0 }
        f && /^[[:space:]]*default:/ {
            sub(/^[[:space:]]*default:[[:space:]]*/, \"\")
            sub(/\r\$/, \"\")
            sub(/[[:space:]]+#.*\$/, \"\")
            gsub(/^[\"']|[\"']\$/, \"\")
            print; exit
        }
    " "$cfg")"
    if [ -z "$cur_model" ]; then
        emit INFO C21-hermes-profile "could not read model.default from $cfg — drift not checked"
        return
    fi
    if [ "$cur_model" = "$expected" ]; then
        emit OK C21-hermes-profile "hermes '$active_profile' profile default ($cur_model) matches lanes.json"
        return
    fi
    emit WARN C21-hermes-profile "hermes '$active_profile' profile default is now '$cur_model' — lanes.json still records '$expected' for hermes-oneshot/hermes-critics" \
        "if the swap is real and lasting: update profileDefaultModel on the hermes-oneshot/hermes-critics rows in scripts/lanes/lanes.json and re-profile (docs/internals/lane-calibration.md, ox-alpha section); if temporary, no action needed"
}

# --- C22: hook chain budget skips/denies (read-only advisory, HIMMEL-2060) ------
# run-hook-with-bash.js --chain durably logs every member the shared chain
# budget starved to .claude/logs/hook-chain-skips.jsonl (one JSON row per
# skip/deny). Counts per member so a member starved often enough to matter is
# visible without grepping session transcripts. No log = nothing has been
# starved yet — OK, not a finding.
check_c22() {
    local log="$REPO_ROOT/.claude/logs/hook-chain-skips.jsonl"
    [ -f "$log" ] || { emit OK C22-chain-skips "no hook-chain-skips.jsonl — no starved chain member recorded"; return; }
    command -v jq >/dev/null 2>&1 || { emit INFO C22-chain-skips "hook-chain-skips.jsonl present but jq missing — counts not checked"; return; }
    local summary jq_rc=0
    # Grouped by reason too (HIMMEL-2060 CR round 5, codex-2): an ENOBUFS row
    # is an output-buffer overflow (a chatty hook), not budget starvation —
    # folding both into one "starved" label made the remedy text below
    # misleading for a box that is only seeing chatty-hook overflows.
    summary="$(jq -rs 'group_by(.action + "/" + .member + "/" + (.reason // "?")) | map({action: .[0].action, member: .[0].member, reason: (.[0].reason // "?"), n: length}) | sort_by(-.n) | .[] | "\(.n)x \(.action) \(.member) (\(.reason))"' "$log" 2>/dev/null)" || jq_rc=$?
    # A malformed/partially-written row makes the WHOLE `jq -s` slurp fail
    # (HIMMEL-2060 CR round 1, codex-2) — distinguish that from a genuinely
    # empty log rather than reporting both as the same clean OK.
    if [ "$jq_rc" -ne 0 ]; then
        emit INFO C22-chain-skips "hook-chain-skips.jsonl present but could not be parsed (a malformed row?) — counts not checked"
        return
    fi
    if [ -z "$summary" ]; then
        emit OK C22-chain-skips "hook-chain-skips.jsonl present but empty"
        return
    fi
    emit WARN C22-chain-skips "chain member event(s) recorded: $(printf '%s' "$summary" | tr '\n' ';' | sed 's/;/; /g')" \
        "reason=ETIMEDOUT is budget starvation (see HIMMEL-2060 / DEFAULT_CHAIN_BUDGET_MS in scripts/hooks/run-hook-with-bash.js); reason=ENOBUFS is an output-buffer overflow (a chatty hook), not a budget problem; a 'deny' action means a must-run security guard hit either one and the chain failed closed"
}

# --- C23: unlanded local work (read-only advisory, HIMMEL-2070) -----------------
# scripts/unlanded-work.sh finds local branches ahead of origin/main that
# never became a PR — the gap /clean's patch-id rail can't see (a squash
# rewrites the patch-id) and never looked for in the first place (it only
# prunes a branch whose PR already MERGED). Delegates entirely to that
# script's --tsv classification; never re-derives it here. WARN only when
# there is AGED live work worth a nudge; INFO for everything else that isn't
# a clean bill of health; never FAIL — this is a nudge, not a break.
check_c23() {
    local script="$REPO_ROOT/scripts/unlanded-work.sh"
    [ -f "$script" ] || { emit OK C23-unlanded "scripts/unlanded-work.sh not found (skipped)"; return; }
    # Test seam (mirrors DOCTOR_WORKTREE_ROOT on C7): scan a different repo dir
    # instead of this checkout, so the suite can hermetically fixture branches.
    local scan_dir="${DOCTOR_UNLANDED_DIR:-$REPO_ROOT}"
    # Capture stderr separately (codex-3, HIMMEL-2070 CR round 1): unlanded-work.sh
    # always exits 0 by contract even when it could not scan at all (e.g. an
    # unresolvable --base) — it writes the diagnostic to stderr instead. A
    # discarded stderr made an operational failure and a genuinely clean repo
    # both print "no unlanded work", so an unresolvable base on some other
    # operator's machine would read as OK here. When the TSV is empty AND the
    # scan printed a diagnostic, surface it as INFO rather than a false-clean OK.
    local stderr_tmp; stderr_tmp="$(mktemp)"
    local tsv sub_rc
    tsv="$(cd "$scan_dir" 2>/dev/null && bash "$script" --tsv 2>"$stderr_tmp")"; sub_rc=$?
    local scan_stderr; scan_stderr="$(cat "$stderr_tmp" 2>/dev/null)"; rm -f "$stderr_tmp"
    # A `cd` failure (codex-3, HIMMEL-2070 CR round 7) short-circuits the `&&`
    # before the script ever runs, so nothing lands in stderr_tmp — the
    # non-zero $sub_rc is the ONLY signal that distinguishes "cd into
    # scan_dir failed" from "the scan genuinely found nothing", so it must be
    # checked alongside scan_stderr, not instead of it.
    if [ -z "$tsv" ] && { [ -n "$scan_stderr" ] || [ "$sub_rc" -ne 0 ]; }; then
        emit INFO C23-unlanded "unlanded-work scan produced no data: $(printf '%s' "${scan_stderr:-cd into $scan_dir failed (rc=$sub_rc)}" | head -1)" "bash scripts/unlanded-work.sh   # investigate directly"
        return
    fi
    local n_unlanded n_aged n_landed n_stale
    n_unlanded="$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="UNLANDED-LIVE"' | grep -c . || true)"
    n_aged="$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="UNLANDED-LIVE" && $5=="1"' | grep -c . || true)"
    n_landed="$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="LANDED-ELSEWHERE"' | grep -c . || true)"
    n_stale="$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="STALE"' | grep -c . || true)"
    if [ "${n_aged:-0}" -gt 0 ]; then
        emit WARN C23-unlanded \
            "$n_aged aged unlanded local branch(es) (of $n_unlanded unlanded, ${n_landed:-0} landed-elsewhere, ${n_stale:-0} stale) — work committed but never opened as a PR, sitting past the age threshold" \
            "bash scripts/unlanded-work.sh   # review, then open PRs or drop"
        return
    fi
    if [ "${n_unlanded:-0}" -gt 0 ] || [ "${n_landed:-0}" -gt 0 ] || [ "${n_stale:-0}" -gt 0 ]; then
        emit INFO C23-unlanded \
            "$n_unlanded unlanded (none aged), ${n_landed:-0} landed-elsewhere, ${n_stale:-0} stale local branch(es) — nothing urgent" \
            "bash scripts/unlanded-work.sh   # full report"
        return
    fi
    emit OK C23-unlanded "no unlanded work"
}

# --- C24: expected-but-absent cadence tasks (read-only advisory, HIMMEL-1680) ---
# The cadence scripts (codex-sweep-cadence.sh, graphmap-cadence.sh, ...)
# self-register every task they arm into observability_registry_path()'s
# .expected_tasks[] (and unregister it on disarm). An operator-armed cadence
# that silently stops existing — deleted, never armed, wiped by the OS
# scheduler — is otherwise indistinguishable from one that is working and just
# hasn't fired yet. This is that detector. Read-only: only queries the live
# scheduler, never mutates the registry or any task. WARN-only (never FAIL),
# mirroring the read-only advisory stance of C7-C9: a missing cadence is a
# nudge to re-arm, not a guardrail break.
check_c24() {
    local registry; registry="$(observability_registry_path)"
    if [ ! -f "$registry" ]; then
        emit OK C24-cadence-registry "no cadence observability registry yet (nothing expected)"
        return
    fi
    if ! command -v jq >/dev/null 2>&1; then
        emit INFO C24-cadence-registry "jq not on PATH — expected-cadence check skipped"
        return
    fi
    local expected
    if ! expected="$(jq -r '.expected_tasks[]? // empty' "$registry" 2>/dev/null)"; then
        emit INFO C24-cadence-registry "registry ($registry) could not be parsed — expected-cadence check skipped" "inspect/repair $registry (invalid JSON?)"
        return
    fi
    if [ -z "$expected" ]; then
        emit OK C24-cadence-registry "registry present but no cadence tasks expected"
        return
    fi
    # codex-1 (CR round 3): probe the scheduler ITSELF once before looping --
    # without this, an access-denied/transient schtasks or crontab error
    # reads identically to "every expected task is gone" and WARNs on all of
    # them, a false alarm distinct from a genuinely absent task.
    local sched_unavailable=0 crontab_err=""
    if is_windows; then
        if ! command -v schtasks >/dev/null 2>&1 || ! MSYS_NO_PATHCONV=1 schtasks /query >/dev/null 2>&1; then
            sched_unavailable=1
        fi
    else
        if ! command -v crontab >/dev/null 2>&1; then
            sched_unavailable=1
        else
            crontab_err="$(crontab -l 2>&1 >/dev/null)"
            # Mirrors graphmap-cadence.sh's cron_read classification: "no
            # crontab for this user" is the normal empty case, not a failure.
            if ! crontab -l >/dev/null 2>/dev/null && ! printf '%s' "$crontab_err" | grep -qi 'no crontab'; then
                sched_unavailable=1
            fi
        fi
    fi
    if [ "$sched_unavailable" -eq 1 ]; then
        emit INFO C24-cadence-registry "the live scheduler ($(is_windows && echo schtasks || echo crontab)) is unreachable -- expected-cadence check skipped (not a false-clean OK)" "verify manually: $(is_windows && echo 'schtasks /query' || echo 'crontab -l')"
        return
    fi

    local missing="" task
    while IFS= read -r task; do
        [ -n "$task" ] || continue
        if is_windows; then
            MSYS_NO_PATHCONV=1 schtasks /query /tn "$task" >/dev/null 2>&1 || missing="$missing $task"
        else
            crontab -l 2>/dev/null | grep -qE "# ${task}\$" || missing="$missing $task"
        fi
    done <<EOF
$expected
EOF
    if [ -n "$missing" ]; then
        emit WARN C24-cadence-registry "expected-but-absent cadence task(s):$missing — registered as owned but not found on the live scheduler" \
            "re-arm the missing cadence (its script's 'arm' subcommand), or if intentionally retired, run its 'disarm' to unregister"
    else
        emit OK C24-cadence-registry "all $(printf '%s\n' "$expected" | grep -c .) expected cadence task(s) present on the live scheduler"
    fi
}

# --- C25: orphaned scratchpad watcher processes (HIMMEL-1820) -------------------
# On 2026-08-16 a watch-branches.sh poll loop written into a Claude session's
# scratchpad was found still running ~10 hours after its session had died --
# orphaned, spinning off children, and helping make the box unresponsive.
# Scratchpad watcher loops have no TTL, never check whether the session they
# serve still exists, and nothing swept for them (scripts/lib/watch-loop.sh is
# how loops bound themselves going forward; this check sweeps for the ones
# already running). Reports processes whose COMMAND LINE (or, on Linux via
# /proc, CWD) references a Claude per-session area -- .claude*/projects/
# session dirs or the himmel handover bridge session dirs, either separator
# style -- AND whose parent process is dead, NAMING the dead parent.
# Windows-first: Windows has no reparenting, so an orphan's ParentProcessId
# still names the DEAD pid (modulo pid reuse). POSIX degrade via ps: a dead
# parent has usually been reparented to init, so ppid 1 is flagged as such
# there. REPORT and OFFER the kill only -- this check never terminates
# anything itself. Never a FAIL: like C7-C19 it is advisory, so scripted
# doctor runs stay usable while an operator decides.
#
# Test seams: DOCTOR_ORPHAN_SCAN_SKIP=1 skips (hermeticity for unrelated
# cases); DOCTOR_ORPHAN_SCAN_SHIM=<exe> replaces the platform producer with
# a fixture emitter of pid|ppid|cmdline lines.
check_c25() {
    if [ "${DOCTOR_ORPHAN_SCAN_SKIP:-0}" = 1 ]; then
        emit OK C25-orphans "orphaned scratchpad watcher scan skipped by test seam"
        return
    fi
    # A scratchpad reference: a per-session Claude path, either separator
    # style (Windows cmdlines are backslashed, MSYS ones forward-slashed),
    # any CLAUDE_DIR suffix (e.g. the glm lane's ~/.claude-glm).
    local c25_pattern='\.claude([A-Za-z0-9_-]*)[/\\](projects[/\\]|handover[/\\]bridge[/\\])'
    local c25_windows=0
    is_windows && c25_windows=1
    local scan="" rc=0
    if [ -n "${DOCTOR_ORPHAN_SCAN_SHIM:-}" ]; then
        scan="$("$DOCTOR_ORPHAN_SCAN_SHIM" 2>/dev/null)" || rc=$?
    elif [ "$c25_windows" -eq 1 ]; then
        local c25_ps=""
        c25_ps="$(resolve_powershell)" || c25_ps=""
        if [ -z "$c25_ps" ]; then
            emit WARN C25-orphans "cannot evaluate orphaned scratchpad watchers on this platform (no PowerShell for the Win32_Process scan) -- this is NOT a clean bill of health" "install PowerShell, then re-run"
            return
        fi
        # Dumb dump only -- every decision (pattern match, parent liveness,
        # naming) lives in THIS script where it is testable. Newlines in a
        # CommandLine are flattened so one process stays one line.
        #
        # The single quotes are LOAD-BEARING: the payload is PowerShell, and
        # its $_ / $c must reach powershell unexpanded. Double-quoting it would
        # let bash eat them first -- MSYS mangles a bare $_ into the literal
        # "unsetenv", which is a real failure mode seen on this box.
        # shellcheck disable=SC2016
        scan="$("$c25_ps" -NoProfile -NonInteractive -Command 'Get-CimInstance Win32_Process | ForEach-Object { $c = $_.CommandLine; if ($null -eq $c) { $c = "" }; $c = $c -replace "\r"," " -replace "\n"," "; "{0}|{1}|{2}" -f $_.ProcessId, $_.ParentProcessId, $c }' 2>/dev/null)" || rc=$?
    else
        # POSIX: normalise pid/ppid/command into the same pid|ppid|cmdline
        # shape (the command column is last, so a | inside it survives the
        # field split below).
        scan="$(ps -e -o pid=,ppid=,command= 2>/dev/null | sed -E 's/^ *([0-9]+) +([0-9]+) /\1|\2|/')" || rc=$?
    fi
    if [ "$rc" -ne 0 ] || [ -z "$scan" ]; then
        # An empty table is a failed scan, not an empty machine -- never a
        # false clean.
        emit WARN C25-orphans "cannot evaluate orphaned scratchpad watchers (process scan unavailable, rc=$rc) -- this is NOT a clean bill of health" "inspect the platform scan command, then re-run"
        return
    fi
    # Linux cwd add-on: /proc exposes each process's working directory, so a
    # watcher whose cmdline no longer names the scratchpad but which still
    # RUNS from one is caught too. (Windows CIM and macOS expose no cheap
    # per-process cwd; the cmdline scan is the whole story there.) Skipped
    # under the shim so fixtures stay host-independent.
    if [ -z "${DOCTOR_ORPHAN_SCAN_SHIM:-}" ] && [ -r /proc/self/cwd ]; then
        local c25_dir c25_p c25_link c25_pp
        for c25_dir in /proc/[0-9]*; do
            [ -d "$c25_dir" ] || continue
            c25_p="${c25_dir#/proc/}"
            c25_link="$(readlink "$c25_dir/cwd" 2>/dev/null)" || continue
            [ -n "$c25_link" ] || continue
            printf '%s\n' "$c25_link" | grep -Eiq "$c25_pattern" || continue
            c25_pp="$(printf '%s\n' "$scan" | awk -F'|' -v p="$c25_p" '$1==p {print $2; exit}')"
            case "$c25_pp" in ''|*[!0-9]*) continue ;; esac
            scan="$c25_p|$c25_pp|(cwd) $c25_link
$scan"
        done
    fi
    local live_pids="" cands=""
    live_pids="$(printf '%s\n' "$scan" | awk -F'|' '{print $1}')"
    cands="$(printf '%s\n' "$scan" | grep -Ei "$c25_pattern" || true)"
    # Candidate rows are ARBITRARY process command lines, so the loop reads
    # them from a temp file, not an unquoted heredoc -- a cmdline containing
    # $(...) or backticks must never be expanded by this script.
    local c25_tmp="" line pid pppid cmd parent_note rows="" n=0 seen=""
    c25_tmp="$(mktemp)"
    printf '%s\n' "$cands" > "$c25_tmp"
    while IFS='|' read -r pid pppid cmd; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        case "$pppid" in ''|*[!0-9]*) continue ;; esac
        printf '%s\n' "$seen" | grep -qx "$pid" && continue
        seen="$pid
$seen"
        parent_note=""
        if printf '%s\n' "$live_pids" | grep -qx "$pppid"; then
            # Parent alive. On POSIX an orphan is usually REPARENTED to init,
            # which hides the dead parent -- flag that shape there (never on
            # Windows, where no reparenting exists and ppid 1 means init
            # itself spawned it).
            if [ "$pppid" = 1 ] && [ "$c25_windows" -eq 0 ]; then
                parent_note="reparented to init (pid 1) -- original parent exited"
            else
                continue
            fi
        else
            parent_note="parent pid $pppid is dead"
        fi
        n=$((n+1))
        if [ "$n" -le 8 ]; then
            rows="$rows$(printf '       · pid %s (%s): %.120s\n' "$pid" "$parent_note" "$cmd")"
        fi
    done < "$c25_tmp"
    rm -f "$c25_tmp"
    if [ "$n" -eq 0 ]; then
        emit OK C25-orphans "no orphaned Claude-scratchpad watcher processes"
        return
    fi
    emit WARN C25-orphans \
        "$n orphaned Claude-scratchpad watcher process(es) -- parent dead, still running (HIMMEL-1820 class)" \
        "inspect each line, then terminate the ones that are not yours: taskkill /PID <pid> /T /F (Windows) or kill <pid> (POSIX) -- this check never terminates anything itself"
    printf '%s' "$rows"
    if [ "$n" -gt 8 ]; then
        printf '       · ...and %d more\n' "$((n-8))"
    fi
}

# --- C26: salus profile marker present but PHI guard marker absent (advisory, HIMMEL-2173) ---
# The salus medical-vault profile installer/upgrade drops `.salus-profile`
# (template machinery) at the vault root; the PHI launcher guards (claude-glm/
# claude-codex/claude-routed + their .ps1 twins + the hermes parity guard, and
# scripts/telegram/glm-guard.ts) test for `.salus` before refusing a cloud/
# codex launch there (now `.salus-profile` too, as a defense — HIMMEL-2173
# part 2). A vault that carries the profile marker but no `.salus` looks
# PHI-protected to the operator (it opted into the medical profile) yet had no
# armed guard before part 2 shipped. Kept as a standing detectability layer
# even after the guards were widened — it still catches future marker drift
# (a hand-rolled vault, a guard that regresses to a single-marker test, or a
# guard this ticket missed). Scans SALUS_VAULT_PATH if set, else the
# documented ~/Documents/salus convention (docs/setup/new-machine.md #4d),
# guarded by existence — doctor has no general vault-discovery mechanism to
# delegate to (mirrors C3's LUNA_VAULT_PATH pattern). NON-fatal (WARN, never
# FAIL), matching the read-only advisory stance of C3/C7-C12.
check_c26() {
    local v=""
    for c in "${SALUS_VAULT_PATH:-}" "${HOME:-}/Documents/salus"; do
        [ -n "$c" ] && [ -d "$c" ] && { v="$c"; break; }
    done
    [ -n "$v" ] || { emit OK C26-salus-marker "no salus vault found (skipped)"; return; }
    if [ ! -f "$v/.salus-profile" ]; then
        emit OK C26-salus-marker "salus vault ($v) has no .salus-profile (not a salus-profile deployment — skipped)"
        return
    fi
    if [ -f "$v/.salus" ]; then
        emit OK C26-salus-marker "salus vault ($v) carries both .salus-profile and .salus — PHI guards are armed"
        return
    fi
    emit WARN C26-salus-marker \
        "salus vault ($v) carries .salus-profile but NOT .salus — armed-but-inert against any guard that still tests only .salus" \
        "touch '$v/.salus' (or re-run the salus profile installer/upgrade — HIMMEL-2173 part 1 ships it automatically going forward)"
}

# --- C27: PHI/egress guard signal readability (HIMMEL-1776 ask 5) ---------------
# graphify-fence.sh (interactive) honors $CLAUDE_GLM_CONFIG_DIR (default
# ~/.config/claude-glm) for its phi-roots/egress-denylist lookup.
# refresh-graph-map.sh's scheduled salus guard deliberately does NOT: it
# hard-codes ~/.config/claude-glm regardless of the override (CR codex-adv
# r4 — a caller-controllable env var must not steer a fail-closed check).
# BOTH fail CLOSED (deny every corpus) when a listed file exists but is not
# a readable regular file — the shared _guard_file_readable predicate,
# scripts/guardrails/phi-egress-lib.sh (HIMMEL-1776 ask 3). Denying is the
# safe outcome, but an operator who never sees that deny message still has
# an armed guard whose SALUS-classification signal is silently broken (the
# HIMMEL-1773 inert-guard shape). This check surfaces the same readability
# signal read-only, before it ever blocks a real extraction. Checking only
# $CLAUDE_GLM_CONFIG_DIR would falsely certify config the scheduled guard
# never reads when the override is set and differs — check the scheduled
# guard's hard-coded location too whenever it diverges. Neither directory
# declared here is a normal skip, same stance as C3/C26.
check_c27() {
    local cfgdir="${CLAUDE_GLM_CONFIG_DIR:-${HOME:-}/.config/claude-glm}"
    local sched_cfgdir="${HOME:-}/.config/claude-glm"
    local lib="$REPO_ROOT/scripts/guardrails/phi-egress-lib.sh"
    local -a dirs=("$cfgdir")
    [ "$sched_cfgdir" != "$cfgdir" ] && dirs+=("$sched_cfgdir")
    local d any_dir=0
    for d in "${dirs[@]}"; do
        [ -d "$d" ] && any_dir=1
    done
    if [ "$any_dir" -eq 0 ]; then
        emit OK C27-guard-signals "no ${dirs[*]} (no phi-roots/egress-denylist declared here — skipped)"
        return
    fi
    if [ ! -f "$lib" ]; then
        emit WARN C27-guard-signals "$lib not found — cannot verify phi-roots/egress-denylist readability" "restore scripts/guardrails/phi-egress-lib.sh"
        return
    fi
    # shellcheck source=guardrails/phi-egress-lib.sh
    # shellcheck disable=SC1091
    . "$lib"
    local name path bad=""
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for name in phi-roots egress-denylist; do
            path="$d/$name"
            [ -e "$path" ] || continue
            _guard_file_readable "$path" || bad="$bad $path"
        done
    done
    if [ -n "$bad" ]; then
        emit WARN C27-guard-signals \
            "PHI guard signal exists but is not a readable regular file:$bad — the guard fails closed on this (denies every corpus), but is inert as a SALUS-classification signal until fixed" \
            "make the listed path(s) a readable regular file (e.g. chmod +r, or replace a directory/special file with a plain text file)"
        return
    fi
    emit OK C27-guard-signals "phi-roots/egress-denylist under ${dirs[*]} (where present) are readable regular files"
}

# --- C28: guardrail-block-global armed-but-inert (HIMMEL-2176) ------------------
# HIMMEL-2176 gave guardrail-block-global (this operator's GLOBAL guardrail
# hooks, distinct from a per-project guardrail-scope item) a REAL install
# path — `himmelctl ensure` can now wire it, via install-engine.js's
# 'guardrail-block-global' wire target — but its round-3 ruling forbids ever
# doing so without an explicit, RECORDED consent (himmelctl's own state.json
# target.items['guardrail-block-global'].overrides.consent). C1-guardrail
# above already covers "wired and healthy" (OK) vs "wired but degraded"
# (FAIL, a baked node path that rotted) and deliberately reads mode=project
# as OK (never-wired is a legitimate, longstanding choice — see its own
# header). This check adds the THIRD distinction C1-guardrail does not make:
# among the never-wired case, "declined on purpose" (consent recorded 'no' —
# still OK, the operator already decided) is not the same as "never even
# asked" (no recorded consent at all) — the latter IS the honest gap this
# ticket exists to close, and stays silent nowhere else in this script.
# Read-only; no --fix (the whole point of the ask-first gate is that this
# is never auto-wired without the operator's own explicit answer).
#
# HIMMEL-2176 panel finding: this used to also early-return OK when
# $SETTINGS itself was absent. That conflated "nothing to check" ($gb
# absent — this checkout has no guardrail-block.mjs, genuinely nothing to
# probe) with "guardrails available but never wired at all" (no user-level
# settings.json), which is exactly the never-asked gap this check exists
# to report — a fresh machine with $gb present and no settings.json has
# never recorded consent either way. Only $gb absence short-circuits now;
# a missing $SETTINGS falls through into guardrail-block.mjs status --json,
# which reads a missing settings path as `{}` (readSettings) and reports
# mode=project cleanly (verified empirically — no throw, rc=0) — so the
# existing mode/consent logic below already does the right thing without
# any special-casing here.
check_c28_guardrail_consent() {
    local gb="$REPO_ROOT/scripts/hooks/guardrail-block.mjs"
    if [ ! -f "$gb" ]; then
        emit OK C28-guardrail-consent "no guardrail-block.mjs in this checkout — nothing to check"
        return
    fi
    local node_bin
    node_bin="$(resolve_node 2>/dev/null)" || { emit OK C28-guardrail-consent "no node resolvable — C1-guardrail already reports this"; return; }
    local js
    js="$(CLAUDE_USER_SETTINGS="$SETTINGS" "$node_bin" "$gb" status --json 2>/dev/null)" || {
        emit OK C28-guardrail-consent "guardrail-block status --json failed — C1-guardrail already reports this"
        return
    }
    local mode
    mode="$(printf '%s' "$js" | jq -r '.mode')"
    if [ "$mode" = global ]; then
        emit OK C28-guardrail-consent "guardrail-block-global is wired (C1-guardrail covers its health)"
        return
    fi
    # mode=project (never wired). Consult himmelctl's OWN recorded consent —
    # the exact same override status-report.js's n/a-unless-'yes' logic reads
    # — to tell "declined on purpose" apart from "never even asked".
    local state_file="${HIMMELCTL_CACHE_DIR:-${HOME:-}/.claude/himmel}/state.json"
    local consent=""
    [ -f "$state_file" ] && consent="$(jq -r '.targets.user.items["guardrail-block-global"].overrides.consent // empty' "$state_file" 2>/dev/null)"
    case "$consent" in
        no)
            emit OK C28-guardrail-consent "guardrail-block-global not wired — recorded decline (run 'himmelctl ensure' interactively to reconsider)"
            ;;
        yes)
            emit WARN C28-guardrail-consent \
                "guardrail-block-global consent is recorded 'yes' but it is still NOT wired — a prior 'himmelctl ensure' may have failed partway" \
                "run: himmelctl ensure --items guardrail-block-global"
            ;;
        *)
            emit WARN C28-guardrail-consent \
                "guardrail-block-global is available in this checkout but never wired into your global settings, and never asked about — nothing enforces it" \
                "run: himmelctl ensure  (or directly: node scripts/hooks/guardrail-block.mjs install --node <ABS_NODE> --bash <ABS_BASH>)"
            ;;
    esac
}

# --- C29: claude child-session launchers running without persistence (advisory, HIMMEL-2545) ---
# claude exports CLAUDE_CODE_CHILD_SESSION=1 and CLAUDE_PID into every process
# it spawns. A claude session launched from inside another claude session's
# Bash tool therefore inherits a "throwaway child" marker: claude saves NO
# transcript for it, scripts/context-fill.sh reads it blind (rc=4), and
# /handover-resume-armed has nothing to read. The fix (headed-arm.sh,
# arm-resume.sh) launches through
# `env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 ...`.
# This check sweeps for a NAMED session (a `-n HIMMEL-...` claude process)
# that inherited the marker anyway — a launcher that forgot the clears.
#
# THE TRAP (verified this session): reading $CLAUDE_CODE_CHILD_SESSION from
# THIS SCRIPT's own environment tells us nothing — claude sets it in every
# subprocess, doctor included, so a self-env check would WARN on every
# healthy run. The honest source is each candidate PROCESS's own /proc
# environ, read directly — never our own env.
#
# A SECOND trap (HIMMEL-2545 panel finding, from a live false positive):
# headed-arm.sh's konsole launcher process ALSO has a cmdline that names
# `claude ... -n HIMMEL-...` (that is the command it was told to run) and
# ALSO inherited CLAUDE_CODE_CHILD_SESSION=1 from whatever armed it — but
# konsole is not claude, and the claude process it actually spawns is a
# SEPARATE pid that (when correctly launched) carries only
# CLAUDE_CODE_FORCE_SESSION_PERSISTENCE. Without a comm==claude gate, every
# headed launch double-counts (launcher + claude) and a healthy session gets
# reported broken via its own launcher's stale marker. Same comm guard as
# context-fill.sh's own launched_as_child_session().
#
# procfs-only (Linux). Where /proc is absent (macOS, Git Bash) this is a
# clean skip, never a false WARN — same procfs-or-silence contract as
# context-fill.sh's own launched_as_child_session().
#
# r11-codex-3 (accuracy, not a false-WARN risk - the WARN itself is already
# gated below on comm==claude PLUS the environ check, both exact; this can
# only ever affect the DISPLAYED name for a pid already correctly flagged):
# the name used to come from grep -Eo against the FLATTENED cmdline
# (`-n HIMMEL-[^ ]*`), the same weakness round 9 fixed in headed-arm.sh's
# own dedup match - a flattened string cannot tell an actual `-n` OPTION
# from the same text sitting inside a PROMPT argument. A session whose
# prompt happens to contain "-n HIMMEL-decoy" ahead of its genuine
# "-n HIMMEL-real" option would have this check print the WRONG name for a
# correctly-flagged pid - a mislabeled diagnostic (sends an operator to the
# wrong window), not a false alarm. Fixed the same way headed-arm.sh reads
# argv: walk /proc/<pid>/cmdline's real NUL-separated elements positionally
# and take the value immediately following a literal "-n" element, rather
# than matching a pattern against space-joined text. Two checks in this PR
# disagreeing about how to read a command line is the same inconsistency
# round 6's codex-4 fixed for the persistence-variable contract - C29 and
# headed-arm.sh now read argv the same way.
_c29_argv_n_value() { # _c29_argv_n_value <cmdline-file> - echoes the value
                       # immediately following the FIRST element that
                       # equals "-n" exactly, walking the real NUL-separated
                       # argv (positional and exact, never a substring or
                       # regex match against flattened text). Empty output
                       # if there is no such pair or the file is unreadable.
    local f="$1" prev="" cur
    [ -r "$f" ] || return 0
    while IFS= read -r -d '' cur; do
        if [ "$prev" = "-n" ]; then
            printf '%s' "$cur"
            return 0
        fi
        prev="$cur"
    done < "$f"
}

# Test seam: HIMMEL_DOCTOR_PROC overrides the proc root (default /proc) so
# the suite can point this at a stubbed tree.
check_c29() {
    local proc_root="${HIMMEL_DOCTOR_PROC:-/proc}"
    if [ ! -d "$proc_root" ]; then
        emit OK C29-child-session "no procfs on this platform — child-session launcher scan skipped"
        return
    fi
    local c29_dir c29_pid c29_comm c29_cmdline c29_environ c29_name rows="" n=0
    for c29_dir in "$proc_root"/[0-9]*; do
        [ -d "$c29_dir" ] || continue
        c29_pid="${c29_dir##*/}"
        # The process must actually BE claude, not merely a launcher whose
        # cmdline happens to quote a claude invocation (e.g. konsole's own
        # `-e env ... claude ... -n HIMMEL-...` argv, which also inherits the
        # CLAUDE_CODE_CHILD_SESSION marker from whatever armed it). Same comm
        # guard as context-fill.sh's own launched_as_child_session() — see
        # HIMMEL-2545 panel finding: without it, every headed-arm.sh launch
        # double-counts (the konsole launcher AND the claude it spawns), and
        # a correctly-launched session (claude carries ONLY
        # CLAUDE_CODE_FORCE_SESSION_PERSISTENCE) gets falsely reported broken
        # via its own launcher's stale marker.
        [ -r "$c29_dir/comm" ] || continue
        c29_comm="$(cat "$c29_dir/comm" 2>/dev/null)" || continue
        [ "$c29_comm" = "claude" ] || continue
        [ -r "$c29_dir/cmdline" ] || continue
        c29_cmdline="$(tr '\0' ' ' < "$c29_dir/cmdline" 2>/dev/null)" || continue
        [ -n "$c29_cmdline" ] || continue
        grep -Eq 'claude ' <<< "$c29_cmdline" || continue
        grep -Eq -- '-n HIMMEL-' <<< "$c29_cmdline" || continue
        [ -r "$c29_dir/environ" ] || continue
        c29_environ="$(tr '\0' '\n' < "$c29_dir/environ" 2>/dev/null)" || continue
        grep -q '^CLAUDE_CODE_CHILD_SESSION=1$' <<< "$c29_environ" || continue
        # r3-codex-4: an EMPTY value is absent, not present - matches
        # context-fill.sh's launched_as_child_session() contract exactly
        # (same asymmetry: any NON-EMPTY value still counts as
        # persistence-on, never require exactly "=1"). Two checks in this
        # PR disagreeing about the same variable would be worse than either
        # rule alone.
        grep -q '^CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=.' <<< "$c29_environ" && continue
        c29_name="$(_c29_argv_n_value "$c29_dir/cmdline")"
        n=$((n+1))
        # A plain $(...) here would swallow the trailing newline (each
        # appended row then runs into the next on one line) -- keep the
        # newline OUTSIDE the substitution.
        rows="$rows$(printf '       · pid %s (%s)' "$c29_pid" "$c29_name")
"
    done
    if [ "$n" -eq 0 ]; then
        emit OK C29-child-session "no claude child-session launchers missing persistence"
        return
    fi
    emit WARN C29-child-session \
        "$n running claude session(s) launched as a child session; transcript not saved (HIMMEL-2545)" \
        "relaunch through: env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude ..."
    printf '%s' "$rows"
}

# --- run ------------------------------------------------------------------------
echo "himmel-doctor — $(uname -s 2>/dev/null || echo ?) — checkout: $REPO_ROOT"
echo
if [ "$DO_FIX" = 1 ]; then fix_c1_guardrail; else check_c1_guardrail; fi
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
check_c16
check_c17
check_c18
check_c19
check_c20
check_c21
check_c22
check_c23
check_c24
check_c25
check_c26
check_c27
check_c28_guardrail_consent
check_c29
echo
printf 'Summary: %s%d FAIL%s  %s%d WARN%s  %s%d INFO%s\n' "$C_RED" "$n_fail" "$C_0" "$C_YEL" "$n_warn" "$C_0" "$C_DIM" "$n_info" "$C_0"

if [ "$DO_FILE" = 1 ] && [ $((n_fail+n_warn+n_info)) -gt 0 ]; then
    echo; echo "Filing a consolidated GitHub issue:"; file_issue
elif [ $((n_fail+n_warn)) -gt 0 ] && [ -t 1 ]; then
    echo; printf 'File a consolidated GitHub issue? [y/N] '; read -r ans
    case "$ans" in y|Y|yes) file_issue ;; *) echo "  (skipped — re-run with --file-issue to file)";; esac
fi

[ "$n_fail" -eq 0 ]
