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
# shellcheck source=lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/load-dotenv.sh"
# shellcheck source=lib/handover-path.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/handover-path.sh"

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
#
# HIMMEL-2515: the Telegram bridge's Linux persistence is a systemd --user
# unit (scripts/himmelctl/lib/bridge-persistence.js installSystemdUnit()),
# not a crontab row — but the registry names it "HimmelTelegramBridge" (the
# Windows scheduled-task name; kept stable across platforms on purpose, so
# this fix does NOT rename the registry entry). The crontab-only probe below
# therefore WARNed "expected-but-absent" on every Linux station with a
# WORKING bridge — a permanent false alarm that trains the operator to
# ignore C24. Fix: for that one task name, probe
# `systemctl --user is-enabled telegram-bridge.service` first when systemctl
# is on PATH; "enabled" counts as present. The crontab probe stays the
# fallback: unconditionally for every OTHER task, and for this task too when
# systemctl is absent, or its answer is inconclusive (see
# _systemd_user_unit_state below — a bus-unreachable "Failed to connect to
# bus" is NOT evidence the unit is absent, so it must not be read as one).
#
# Test seam: HIMMEL_DOCTOR_SYSTEMCTL (shared with C30's check below)
# overrides the systemctl binary; default "systemctl" (PATH-resolved).
#
# _systemd_user_unit_state <systemctl_bin> <unit> — echoes "enabled",
# "disabled", "notfound" or "unknown". Shared by C24 (this check) and C30
# below — named check-neutral on purpose (an earlier draft called this
# _c24_systemd_enabled, which read as C24-owned to a reviewer despite C30
# calling it too, and invited deleting it if C24 is ever retired/rewritten).
# is-enabled only reads the unit's enablement symlinks (it starts and stops
# nothing), so this is as read-only as the crontab probe C24 augments.
#
# Every `systemctl --user is-enabled` answer is handled BY NAME below (per
# `man systemctl` Table 3 and empirically verified against this box's
# systemd 261) rather than falling through an undocumented wildcard — an
# earlier draft's silent `*) -> disabled` mapped "enabled-runtime" (rc 0,
# same "this unit WILL autostart" meaning as "enabled", differing only in
# whether the enablement symlink lives in /etc, permanent, or /run,
# runtime-only) to "disabled", reproducing THIS TICKET'S OWN false-absent
# bug in a narrower case (a bridge enabled with `enable --runtime` would
# read as expected-but-absent). Caught by CR round 1 (E1) before ever
# shipping.
_systemd_user_unit_state() {
    local bin="$1" unit="$2" out
    # LC_ALL=C (CR round 1 E5): the stdout enum (enabled/not-found/...) is
    # never translated, but the bus-failure diagnostic below is a strerror()
    # tail and IS locale-dependent on this box (`locale -a` lists de_DE.utf8
    # among others) -- this repo has already been bitten once by parsing an
    # unpinned localized label, so pin it here even though it costs nothing
    # for the common (non-failure) path.
    out="$(LC_ALL=C "$bin" --user is-enabled "$unit" 2>&1)"
    case "$out" in
        *"Failed to connect to"*"bus"*)
            # Transient/environment failure, not a unit-state answer at all —
            # NOT evidence the unit is absent (HIMMEL-2515). The wording is
            # systemd-version-dependent -- both forms observed for real (CR
            # round 1 E5, this station's systemd 261, forced via
            # XDG_RUNTIME_DIR=/nonexistent DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent):
            #   older systemd: "Failed to connect to bus: No such file or directory"
            #   this station:  "Failed to connect to user scope bus via local
            #                   transport: No such file or directory"
            # A literal `*"Failed to connect to bus"*` glob (the original,
            # untested-against-a-real-failure version) matches the first but
            # NOT the second -- "to bus" is never a contiguous substring in
            # the real message this box's systemd produces, so it fell
            # through to the `*)` default below and silently reproduced the
            # exact false-absent bug this ticket exists to fix. This looser
            # two-part glob matches either wording.
            printf 'unknown' ;;
        enabled|enabled-runtime)
            # Both mean systemd WILL start this unit on its own — the only
            # difference is where the enablement symlink lives.
            printf 'enabled' ;;
        not-found)
            # The unit file does not exist at all (exit 4) — genuinely
            # nothing installed, distinct from "installed but not enabled"
            # (see C30's E2 fix below, which needs this distinction to word
            # its OK message honestly).
            printf 'notfound' ;;
        disabled|static|indirect|generated|transient|alias|linked|linked-runtime|masked|masked-runtime|bad)
            # Named deliberately, not swallowed by a wildcard (E1):
            #   disabled          — has an [Install] section but isn't enabled.
            #   static            — no [Install] section; can't be enabled at all.
            #   indirect          — enables OTHER units via Also=, not itself.
            #   generated         — a generator-tool unit; "may not be enabled".
            #   transient         — created via the runtime API; "may not be enabled".
            #   alias             — a symlinked alternate name, not itself an
            #                       enablement (rc 0, but not "will autostart").
            #   linked/-runtime   — a unit file made available via a symlink,
            #                       WITHOUT the WantedBy enablement this check
            #                       cares about.
            #   masked/-runtime   — explicitly BLOCKED from ever starting.
            #   bad               — invalid unit / another error (is-enabled
            #                       normally prints an error instead of this
            #                       literal token, but the table documents it).
            # None of these mean "systemd will autostart this on its own", so
            # all count as "not enabled" for C24/C30's purposes -- but every
            # one of them still means the unit is INSTALLED (unlike
            # "not-found" above), which is why this bucket stays "disabled",
            # never folded into "notfound".
            printf 'disabled' ;;
        *)
            # A systemd is-enabled answer this helper does not recognise yet
            # (a future state, a permission-denied/other failed invocation, or
            # a translated/locale string) — genuinely UNVERIFIED, not "not
            # enabled". Default to "unknown", never "disabled" (CR round 1
            # finding 2, HIMMEL-2515): the original comment here argued the
            # conservative default was deliberate, and it was right that
            # unfamiliar output must never be read as "armed" — but wrong
            # about which bucket is the SAFE one. "disabled" asserts the unit
            # IS installed, a fact this branch never established (a bare
            # permission error proves nothing about install state either way).
            # Both callers already have a real inconclusive-answer path for
            # exactly this: C24 falls back to its crontab probe, C30 declines
            # to guess and emits INFO — folding an unrecognised/failed answer
            # into "disabled" instead skips both of those and asserts a fact
            # the probe never proved.
            printf 'unknown' ;;
    esac
}

# _c24_cron_has_task <task> — true (rc 0) when the current user's crontab
# has a row whose comment marker is exactly "# <task>" at end of line, false
# (rc 1) otherwise (including "no crontab for this user" at all).
#
# HIMMEL-1430 / HIMMEL-2515: the shape this replaces,
# `crontab -l 2>/dev/null | grep -qE "# ${task}\$"`, is a
# `<producer> | grep -q` pipeline under this file's `set -uo pipefail`
# (line 10) — grep -q exits the instant it matches, crontab then takes
# SIGPIPE writing whatever output is left, and pipefail reports the
# PIPELINE as failed if any stage exited non-zero. So a SUCCESSFUL match
# can still read as "not found" — a false "expected-but-absent cadence
# task" WARN, exactly the bug class this ticket exists to remove
# (known-findings.json: grep-q-pipe-under-pipefail). Fix: capture the
# command's own output into a local first, then match against that with no
# pipe in the way (this repo's `known-findings.sh` prescribes the same
# capture-then-match shape). A here-string is used for the match rather than
# a second pipe; a crontab is comfortably under the ~64 KiB here-string
# size that wedges Git Bash (HIMMEL-2027), so it's safe at this size.
#
# This fixes BOTH call sites in check_c24's task loop below: the new
# systemctl-"unknown" fallback branch, and the PRE-EXISTING `else` branch a
# few lines under it — same latent bug in the same loop, and the `else`
# branch is the primary path taken for every non-bridge cadence task, so it
# needed the identical fix.
_c24_cron_has_task() {
    local task="$1" cron
    cron="$(crontab -l 2>/dev/null)"
    grep -qE "# ${task}\$" <<< "$cron"
}

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
    # them, a false alarm distinct from a genuinely absent task. That
    # reasoning is still correct -- but HIMMEL-2515 CR round 4 found it had
    # been wired as a single WHOLE-FUNCTION early return, unconditionally,
    # which was right back when crontab was the only backend this check ever
    # spoke to. Once the systemd probe for HimmelTelegramBridge below was
    # added, a crontab-only early return became wrong: on a systemd-only
    # Linux host with no cron installed at all (common on modern minimal
    # distros), it returned before the per-task loop ever ran, so the
    # systemd probe never executed and the bridge's enablement was never
    # checked at all -- precisely the visibility this ticket exists to
    # provide. Availability is now tracked PER BACKEND: a missing/failing
    # crontab only takes crontab-probed tasks off the table (each becomes
    # INDETERMINATE per-task below, reusing CR round 1's existing bucket
    # rather than inventing a second one); a systemd-probed task is
    # unaffected by crontab's availability. The whole-check bail a few lines
    # down still fires when it is genuinely the right call -- crontab
    # unreachable AND no expected task has any OTHER backend (no
    # HimmelTelegramBridge expected, or systemctl itself unavailable too) --
    # because in that case nothing here could be checked either way, and
    # skipping the whole check is more honest than a false-clean OK or a
    # false WARN on tasks crontab was never going to be able to answer for.
    local crontab_unavailable=0 crontab_err=""
    local systemctl_bin="${HIMMEL_DOCTOR_SYSTEMCTL:-systemctl}"
    if is_windows; then
        # Windows has exactly one backend (schtasks) for every cadence task,
        # so schtasks unavailable really does mean nothing here can be
        # checked -- the original whole-check bail is still correct as-is.
        if ! command -v schtasks >/dev/null 2>&1 || ! MSYS_NO_PATHCONV=1 schtasks /query >/dev/null 2>&1; then
            emit INFO C24-cadence-registry "the live scheduler (schtasks) is unreachable -- expected-cadence check skipped (not a false-clean OK)" "verify manually: schtasks /query"
            return
        fi
    else
        if ! command -v crontab >/dev/null 2>&1; then
            crontab_unavailable=1
        else
            crontab_err="$(crontab -l 2>&1 >/dev/null)"
            # Mirrors graphmap-cadence.sh's cron_read classification: "no
            # crontab for this user" is the normal empty case, not a failure.
            if ! crontab -l >/dev/null 2>/dev/null && ! printf '%s' "$crontab_err" | grep -qi 'no crontab'; then
                crontab_unavailable=1
            fi
        fi
        # here-string, not a `producer | grep -q` pipe -- see _c24_cron_has_task's
        # comment above on why that shape is unsafe under this file's pipefail.
        if [ "$crontab_unavailable" -eq 1 ] && { ! grep -qx 'HimmelTelegramBridge' <<< "$expected" || ! command -v "$systemctl_bin" >/dev/null 2>&1; }; then
            emit INFO C24-cadence-registry "the live scheduler (crontab) is unreachable -- expected-cadence check skipped (not a false-clean OK)" "verify manually: crontab -l"
            return
        fi
    fi

    local missing="" indeterminate="" indeterminate_crontab_only="" task
    while IFS= read -r task; do
        [ -n "$task" ] || continue
        if is_windows; then
            MSYS_NO_PATHCONV=1 schtasks /query /tn "$task" >/dev/null 2>&1 || missing="$missing $task"
        elif [ "$task" = "HimmelTelegramBridge" ] && command -v "$systemctl_bin" >/dev/null 2>&1; then
            case "$(_systemd_user_unit_state "$systemctl_bin" telegram-bridge.service)" in
                enabled) : ;; # present via systemd — the crontab probe never had this task's row
                unknown)
                    # Bus unreachable/unrecognized: not evidence of absence —
                    # fall back to the same crontab probe a systemctl-less
                    # host would use, UNLESS crontab is already known
                    # unavailable (CR round 4) -- then skip straight to
                    # indeterminate instead of invoking a crontab already
                    # known unable to answer. If crontab ALSO has no row,
                    # NEITHER probe established absence — this task's
                    # enablement is genuinely INDETERMINATE, not missing (CR
                    # round 1 finding 3, HIMMEL-2515: this is the ticket's
                    # own false-absent bug re-entering through the "unknown"
                    # fallback path). Track it apart from $missing so it
                    # never joins the expected-but-absent WARN, while still
                    # surfacing it below rather than dropping it silently.
                    if [ "$crontab_unavailable" -eq 1 ] || ! _c24_cron_has_task "$task"; then
                        indeterminate="$indeterminate $task"
                    fi
                    ;;
                *) missing="$missing $task" ;; # disabled OR notfound -- neither counts as armed
            esac
        elif [ "$crontab_unavailable" -eq 1 ]; then
            # CR round 4: this task's only backend is crontab and crontab is
            # unreachable — INDETERMINATE (CR round 1's existing bucket),
            # never silently dropped and never joining the
            # expected-but-absent WARN (that would blame the task for
            # something crontab, not it, made unknowable). Tracked in its own
            # $indeterminate_crontab_only bucket too (CR round 5) so the
            # diagnostic below can name crontab, not systemd, as this task's
            # cause — this branch is never reached for HimmelTelegramBridge
            # while crontab is unavailable (the whole-check bail above
            # guarantees systemctl is available whenever the bridge is
            # expected and crontab_unavailable=1), so every task landing here
            # is a genuinely crontab-only task.
            indeterminate="$indeterminate $task"
            indeterminate_crontab_only="$indeterminate_crontab_only $task"
        else
            _c24_cron_has_task "$task" || missing="$missing $task"
        fi
    done <<EOF
$expected
EOF
    if [ -n "$missing" ]; then
        emit WARN C24-cadence-registry "expected-but-absent cadence task(s):$missing — registered as owned but not found on the live scheduler" \
            "re-arm the missing cadence (its script's 'arm' subcommand), or if intentionally retired, run its 'disarm' to unregister"
    elif [ -n "$indeterminate" ]; then
        emit OK C24-cadence-registry "no expected-but-absent cadence task(s) — every task whose enablement could be determined is present on the live scheduler"
    else
        emit OK C24-cadence-registry "all $(printf '%s\n' "$expected" | grep -c .) expected cadence task(s) present on the live scheduler"
    fi
    # codex-1 (CR round 5): this used to be a single emit hardcoding ONE cause
    # (systemd bus unreachable) and ONE remedy (check systemctl) for every
    # $indeterminate task -- but since CR round 4 a task reaches this bucket
    # via two unrelated routes: HimmelTelegramBridge when the systemd probe
    # answered "unknown" (crontab consulted as a fallback, or itself
    # unavailable), or a crontab-only sibling when CRONTAB ITSELF is what's
    # unreachable ($indeterminate_crontab_only above) -- nothing to do with
    # systemd or the bridge. Telling that sibling's operator to check
    # telegram-bridge.service names a cause this check never established and
    # hands a remedy that cannot help: the same false-attribution class this
    # whole ticket exists to remove, now in the operator-facing text.
    # Attribute per task instead: the bridge (the only task ever routed
    # through the systemd probe) gets its own line, naming BOTH backends when
    # crontab was also unavailable rather than picking one; any crontab-only
    # sibling gets a separate line naming crontab and `crontab -l`.
    case " $indeterminate " in
        *' HimmelTelegramBridge '*)
            if [ "$crontab_unavailable" -eq 1 ]; then
                emit INFO C24-cadence-registry "HimmelTelegramBridge has UNDETERMINED enablement — neither backend could answer (systemd bus unreachable/unrecognized, and crontab itself is unreachable) — not scored as expected-but-absent (neither probe established absence), but not confirmed present either" \
                    "verify manually: systemctl --user is-enabled telegram-bridge.service, and crontab -l"
            else
                emit INFO C24-cadence-registry "HimmelTelegramBridge has UNDETERMINED enablement (systemd bus unreachable/unrecognized, and no crontab row either) — not scored as expected-but-absent (neither probe established absence), but not confirmed present either" \
                    "verify manually: systemctl --user is-enabled telegram-bridge.service"
            fi
            ;;
    esac
    if [ -n "$indeterminate_crontab_only" ]; then
        emit INFO C24-cadence-registry "cadence task(s) with UNDETERMINED enablement (crontab itself is unreachable, and these tasks have no other backend):$indeterminate_crontab_only — not scored as expected-but-absent (neither probe established absence), but not confirmed present either" \
            "verify manually: crontab -l"
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
# scripts/telegram/phi-egress-guard.ts) test for `.salus` before refusing a cloud/
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

# --- C30: telegram-bridge liveness (read-only advisory, HIMMEL-2515) ------------
# C24 only answers "is the systemd unit ARMED" (is-enabled reads WantedBy
# symlinks; it says nothing about whether the process is actually running).
# Type=simple + Restart=on-failure means a crash-looping bridge reports
# "enabled" indefinitely with no other signal from C24's probe. This check
# reads the live unit's MainPID and confirms that pid is still alive (kill
# -0) rather than trusting ActiveState/is-enabled alone — added alongside the
# C24 fix above (scope extension recorded on HIMMEL-2515) because C24
# answering "armed" invites exactly this "but is it actually up" follow-up.
# Read-only, like C24: only ever queries systemctl show/is-enabled, never
# start/stop/restart/reload/kill — this station's bridge is a LIVE
# production unit. WARN-only (never FAIL). The state that matters most:
# NEVER warn when no bridge persistence was ever installed here — most
# adopters have none, and a doctor that nags every station that never armed
# one is the exact "operators learn to ignore this check" failure C24's own
# false alarm already demonstrated.
#
# Test seam: HIMMEL_DOCTOR_SYSTEMCTL (shared with C24's probe above) — the
# systemctl binary to invoke; default "systemctl" (PATH-resolved).
check_c30() {
    local systemctl_bin="${HIMMEL_DOCTOR_SYSTEMCTL:-systemctl}" unit="telegram-bridge.service"
    if ! command -v "$systemctl_bin" >/dev/null 2>&1; then
        # Scoped to SYSTEMD persistence specifically (CR round 3, finding 3):
        # this check only ever speaks to the systemd unit, so it must not
        # imply a whole-host verdict. C24 explicitly supports a Windows
        # `HimmelTelegramBridge` SCHEDULED TASK as an alternative persistence
        # mechanism this check knows nothing about -- "no bridge persistence
        # possible here" was false on exactly that platform.
        emit OK C30-bridge-liveness "no systemctl on this host — no systemd-unit bridge persistence to check here (a scheduled-task equivalent, if any, is C24's concern, not this check's)"
        return
    fi
    # Gate on is-enabled FIRST (shared with C24's probe): reading MainPID for
    # a unit that was never armed would come back 0/empty too —
    # indistinguishable from "armed but crashed" unless this is checked
    # first. Most adopters have no bridge at all; this is what keeps this
    # check from warning at every one of them (the exact
    # false-alarm-trains-operators-to-ignore-it failure C24 already
    # demonstrated — see the banner above).
    #
    # "notfound" and "disabled" get DISTINCT OK messages (E2, CR round 1):
    # both are correctly OK (nothing armed, nothing to WARN about), but they
    # are not the same fact -- "notfound" means the unit file does not exist
    # at all, "disabled" means it IS installed and someone (deliberately or
    # not) left it unarmed. Collapsing them into one "no unit installed"
    # message is false in the second case, and an operator who installed the
    # bridge and then intentionally disabled it, reading "not installed",
    # concludes the check is broken -- the same trust-erosion this ticket
    # exists to fix, arriving via the message instead of the verdict.
    case "$(_systemd_user_unit_state "$systemctl_bin" "$unit")" in
        enabled) : ;;
        unknown)
            emit INFO C30-bridge-liveness "systemd user bus unreachable — bridge-liveness check skipped (not evidence the unit is absent, HIMMEL-2515)" "verify manually: $systemctl_bin --user is-enabled $unit"
            return
            ;;
        notfound)
            emit OK C30-bridge-liveness "no $unit installed on this host — no bridge persistence to check"
            return
            ;;
        *)
            emit OK C30-bridge-liveness "$unit is installed but not enabled — no bridge persistence armed, nothing to check" \
                "systemctl --user enable $unit   # if this was meant to run — an OPERATOR decision, this check never enables it"
            return
            ;;
    esac
    # CR round 2: the MainPID `show` query's exit status was never checked --
    # a query that FAILS (bus dropped mid-run, unit torn down between the
    # is-enabled gate above and this query, a resource limit, ...) prints
    # nothing to stdout, and the sanitiser two lines down used to read that
    # empty output exactly like a genuine "MainPID=0" answer, asserting
    # "armed but not running" from a query that established nothing --
    # this ticket's own bug class, reachable even though is-enabled and
    # show are two SEPARATE invocations and the bus-unreachable case above
    # only gates on the first of them. Capture the exit status and treat a
    # FAILED query as undetermined, never as a live "0".
    local mainpid mainpid_rc nrestarts nrestarts_rc
    mainpid="$("$systemctl_bin" --user show "$unit" -p MainPID --value 2>/dev/null)"
    mainpid_rc=$?
    if [ "$mainpid_rc" -ne 0 ]; then
        emit INFO C30-bridge-liveness "$unit is enabled but its MainPID query failed (systemctl exit $mainpid_rc) — bridge-liveness undetermined, not evidence it is down" \
            "verify manually: $systemctl_bin --user show $unit -p MainPID --value"
        return
    fi
    # Sanitisation stays for the SUCCESS path only: a query that returned rc 0
    # but printed something non-numeric (or nothing) still isn't a pid --
    # and CR round 3 finding 2: that is a DIFFERENT answer from a literal
    # numeric "0", not the same one. A literal "0" (or a numeric pid that is
    # no longer alive) genuinely establishes the bridge is not running --
    # that is what the WARN below is for. An empty/non-numeric value from a
    # query that itself SUCCEEDED establishes nothing either way (the query
    # answered with something that isn't a pid at all) -- treating it as "0"
    # asserted "armed but not running" from evidence that never said so, the
    # same bug class the mainpid_rc check above already fixed for a FAILED
    # query; this closes the same hole for a successful-but-unreadable one.
    case "$mainpid" in
        ''|*[!0-9]*)
            emit INFO C30-bridge-liveness "$unit is enabled but its MainPID query returned an unreadable value ('$mainpid') — bridge-liveness undetermined, not evidence it is down" \
                "verify manually: $systemctl_bin --user show $unit -p MainPID --value"
            return
            ;;
    esac
    if [ "$mainpid" -eq 0 ] || ! kill -0 "$mainpid" 2>/dev/null; then
        emit WARN C30-bridge-liveness "$unit MainPID=$mainpid — armed but not running" \
            "systemctl --user status $unit   # inspect; restarting it is an OPERATOR decision, this check never restarts it"
        return
    fi
    # NRestarts is decoration on the OK line below, not evidence of anything
    # -- so a FAILED query here degrades the count to "unknown" rather than
    # blocking the liveness verdict the MainPID query already established
    # (deliberate: unlike MainPID, there is no WARN this could wrongly
    # trigger, so there is nothing to protect by returning early).
    nrestarts="$("$systemctl_bin" --user show "$unit" -p NRestarts --value 2>/dev/null)"
    nrestarts_rc=$?
    # Item 4 (mine, CR round 3): the two ways this can come up empty are NOT
    # the same fact -- a FAILED query (rc != 0) genuinely means "NRestarts
    # query failed", but a SUCCESSFUL query that printed something
    # non-numeric named that same failure on no evidence of it. Track which
    # happened so the OK line below never claims a cause the query didn't
    # establish.
    local nrestarts_unreadable=0
    if [ "$nrestarts_rc" -ne 0 ]; then
        nrestarts=""
    else
        case "$nrestarts" in ''|*[!0-9]*) nrestarts=""; nrestarts_unreadable=1 ;; esac
    fi
    if [ -n "$nrestarts" ]; then
        emit OK C30-bridge-liveness "$unit is running (pid $mainpid, $nrestarts restart(s) so far)"
    elif [ "$nrestarts_unreadable" -eq 1 ]; then
        emit OK C30-bridge-liveness "$unit is running (pid $mainpid, no usable restart count — NRestarts query returned a non-numeric value)"
    else
        emit OK C30-bridge-liveness "$unit is running (pid $mainpid, restart count unknown — NRestarts query failed)"
    fi
}

# --- C31: codex still wires the dropped tokensave server (HIMMEL-2581) -----
# tokensave was evaluated (a GPT-6 audit, a Claude Fable audit, and a
# measured 3-op benchmark, all three independently) and DROPPED — it lost to
# plain Grep+Read on all three measured symbol-level ops (HIMMEL-2581). The
# finding this check reports is now the OPPOSITE of what it used to report:
# a codex config that still declares an ENABLED [mcp_servers.tokensave]
# table is itself the problem, because codex will keep trying to spawn a
# server the harness no longer recommends. The doctor never edits operator
# machine state — it only WARNs and names the remedy (remove the block from
# the codex config by hand).
#
# Test seam: CODEX_HOME (codex's OWN env var, not a test-only invention;
# matches scripts/codex/startup-health.sh's convention) selects the config
# file.
check_c31() {
    local codex_home="${CODEX_HOME:-${HOME:-}/.codex}"
    local cfg="$codex_home/config.toml"

    if [ ! -f "$cfg" ]; then
        # Distinct wording from "does not wire tokensave" below (CR-round
        # precedent, C30): "no codex config at all" and "a config that wires
        # something else" are different facts, and collapsing them into one
        # message is itself a finding.
        emit OK C31-tokensave-dropped "no codex config at $cfg — nothing to check"
        return
    fi
    if [ ! -r "$cfg" ]; then
        # A failed read establishes NOTHING about what the config wires.
        # Calling that "not wired" would assert an OK from evidence that
        # never said so — the same finding class as C30's MainPID-query
        # rows. Never OK, never WARN: only INFO (undetermined).
        local cfg_q; cfg_q=$(printf '%q' "$cfg")
        emit INFO C31-tokensave-dropped "$cfg exists but is not readable — tokensave wiring undetermined" \
            "chmod +r $cfg_q   # or re-run this check as the file's owner"
        return
    fi
    # Anchored to the exact parent-table header, never a bare substring
    # match: a real wired config carries 80+ per-tool
    # [mcp_servers.tokensave.tools.<name>] sub-tables, which declare no
    # `command` (codex spawns nothing from them) — a substring match on
    # '[mcp_servers.tokensave' would misread those as wiring. Requiring
    # `\]` immediately (mod whitespace) after the SECOND segment is what
    # keeps those sub-tables excluded: `.tools.foo]` puts a literal `.`
    # where the pattern instead demands whitespace-then-`]`, so the match
    # fails and the sub-table row stays "not wired". The leading
    # ^[[:space:]]* anchor is what excludes a commented-out
    # `# [mcp_servers.tokensave]` header too.
    #
    # Past this point TOML's own header grammar has three independent
    # dimensions, and this pattern covers each one FULLY rather than
    # accreting one more bolted-on alternative per CR round (three rounds
    # each added a single case; this rewrite closes the shape instead):
    #   - whitespace: TOML permits it after the opening `[`, on both
    #     sides of the dotted-key `.` separator, and before the closing
    #     `]` — every `[[:space:]]*` below is one of those four spots.
    #   - key spelling: EACH dotted segment (`mcp_servers` and
    #     `tokensave` independently, not just the second) may be a bare
    #     key, a basic string (`"key"`), or a literal string (`'key'`) —
    #     hence the three-way alternation applied twice, once per
    #     segment.
    #   - trailing comment: `[[:space:]]*(#.*)?$` tolerates an inline
    #     TOML comment after the closing bracket (e.g.
    #     `[mcp_servers.tokensave] # local server`) — TOML permits that,
    #     and without it a commented-header config reads as unwired,
    #     which is a false OK that suppresses the WARN below.
    #
    # Deliberate boundary: this is a regex, not a TOML parser, so escape
    # sequences INSIDE a quoted key are not decoded — a header spelled
    # with an escape (e.g. a key containing `t`) would still read as
    # unwired here. No tool in the wild writes that, and correctly
    # decoding it needs a real TOML parser, not one more alternation. A
    # future round that turns up such a spelling should record it as a
    # documented scope line here, not bolt on another case.
    local hdr_re
    hdr_re='^[[:space:]]*\[[[:space:]]*(mcp_servers|"mcp_servers"|'"'"'mcp_servers'"'"')[[:space:]]*\.[[:space:]]*(tokensave|"tokensave"|'"'"'tokensave'"'"')[[:space:]]*\][[:space:]]*(#.*)?$'
    if ! grep -qE "$hdr_re" "$cfg"; then
        emit OK C31-tokensave-dropped "codex config at $cfg does not wire tokensave — nothing to remove"
        return
    fi
    # `enabled = false` on an MCP server table is a REAL codex key, IN USE on
    # this station's own ~/.codex/config.toml (mcp_servers.telegram carries
    # `enabled = false`) — not a hypothetical branch. A disabled tokensave
    # table means codex will never start it, so the dropped-server problem
    # this check exists to catch cannot occur: warning here would be exactly
    # the "nag when nothing is armed" failure C30's banner exists to avoid.
    # Read ONLY the parent
    # table's own body — from its header line up to (not including) the
    # next TOML table header — because the real config carries 80+
    # [mcp_servers.tokensave.tools.*] sub-tables right after the parent, and
    # an `enabled` line inside one of those is NOT part of the parent's body
    # (see the negative-control test row for this exact trap).
    #
    # Like hdr_re above, the `enabled` key itself accepts all three TOML key
    # spellings — bare, "enabled", and 'enabled' — since `"enabled" = false`
    # and `'enabled' = false` are the same key as the bare form and a config
    # using either spelling is genuinely disabled. The same documented
    # boundary as hdr_re applies here too: this is a regex, not a TOML
    # parser, so escape sequences inside a quoted key are not decoded. Only
    # the KEY spelling is widened, never the value — `enabled = "false"` is
    # the TOML string "false", not the boolean, so it must still fall
    # through to the WARN below (see the value-not-key control).
    local hdr_line
    hdr_line=$(grep -nE "$hdr_re" "$cfg" | head -n1 | cut -d: -f1)
    # awk reads the parent table's own body and answers the question
    # itself — via its own exit status — so there is no pipeline for
    # `pipefail` to invert (a `printf | grep -q` producer/consumer pair can
    # SIGPIPE on an early match, turning a SUCCESSFUL match into a failed
    # pipeline, HIMMEL-1430) and no here-string to materialise the body
    # into a shell variable, which would hit Git Bash's ~64 KiB here-string
    # limit on a large config (HIMMEL-2027).
    if awk -v start="$hdr_line" '
        NR == start { in_body = 1; next }
        in_body && /^[[:space:]]*\[/ { exit }
        in_body && /^[[:space:]]*(enabled|"enabled"|'"'"'enabled'"'"')[[:space:]]*=[[:space:]]*false[[:space:]]*(#.*)?$/ { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$cfg"; then
        emit OK C31-tokensave-dropped "codex config at $cfg declares [mcp_servers.tokensave] but enabled = false — the table is disabled, nothing to remove"
        return
    fi
    local cfg_q; cfg_q=$(printf '%q' "$cfg")
    emit WARN C31-tokensave-dropped "codex config at $cfg wires an enabled [mcp_servers.tokensave] — tokensave was evaluated and dropped (it lost to plain Grep+Read on every measured op, HIMMEL-2581); codex will keep trying to spawn a server the harness no longer recommends" \
        "remove the [mcp_servers.tokensave] table (and its [mcp_servers.tokensave.tools.*] sub-tables) from $cfg_q by hand — the doctor does not edit codex config"
}

# --- C35: VM after-report runner reachable (HIMMEL-2623) -------------------
# Advisory only — scripts/vm/after-report.sh has its own loud fallback to the
# host invocation when the VM runner is unavailable, so nothing here is ever
# a FAIL; this row just tells the operator WHY that fallback would fire
# before they hit it mid-run.
#
# NUMBERED C35, NOT C32 (2026-09-06 allocation): main independently landed
# its own check_c32()/C32-main-ref-guard (#2195). A later leg hit the
# collision this avoids first-hand — himmel-doctor.sh merges TEXTUALLY CLEAN
# with two check_c32() definitions and one call site, bash silently keeps
# the LATER definition, and the doctor still reports a clean row while one
# guard never runs again. Nothing in the merge, the diff, or a normal test
# run says a word about it. That night's allocation: C32 main-ref-guard
# (main), C33 graph-stale, C34 cost-guards (other legs, unmerged at the
# time), C35 vm-ar (this one) — never reuse C32-C34 for this check.
check_c35() {
    local vbm="${VBOXMANAGE_PATH:-/usr/bin/VBoxManage}"
    if ! command -v "$vbm" >/dev/null 2>&1 && [ ! -x "$vbm" ]; then
        emit INFO C35-vm-ar "VBoxManage not found at '$vbm' — scripts/vm/after-report.sh will refuse and name the host after-report invocation instead" \
            "install VirtualBox, or set VBOXMANAGE_PATH to its VBoxManage binary"
        return
    fi
    local venv_py="${HIMMEL_VM_PYTHON:-$HOME/.himmel/vm-venv/bin/python}"
    if [ ! -x "$venv_py" ]; then
        emit WARN C35-vm-ar "VBoxManage is present but the VM venv python ($venv_py) is missing — scripts/vm/after-report.sh needs it to drive scripts/lib/vbox.py's clone/restore/boot lifecycle" \
            "python3 -m venv ~/.himmel/vm-venv   # or set HIMMEL_VM_PYTHON at an existing python3"
        return
    fi
    # CodeRabbit (PR #2206): 'list vms' had no timeout — a wedged VBoxSVC
    # blocked this call indefinitely, and with it every remaining doctor
    # check and the whole summary. The doctor is an interactive
    # diagnostic; hanging is the one thing it must not do. Same optional-
    # timeout convention as critic-panel.sh and the VM scripts: wrap when
    # 'timeout' is present, degrade to an uncapped call (with that gap
    # named) when it is not.
    local timeout_bin
    timeout_bin="$(command -v timeout 2>/dev/null)" || timeout_bin=""
    local list_vms_rc=0
    if [ -n "$timeout_bin" ]; then
        "$timeout_bin" 10 "$vbm" list vms >/dev/null 2>&1 || list_vms_rc=$?
    else
        "$vbm" list vms >/dev/null 2>&1 || list_vms_rc=$?
    fi
    if [ "$list_vms_rc" -ne 0 ]; then
        if [ -n "$timeout_bin" ] && [ "$list_vms_rc" -eq 124 ]; then
            emit WARN C35-vm-ar "VBoxManage ($vbm) 'list vms' timed out after 10s — VBoxSVC is likely wedged; after-report runs will fail over to the host lock" \
                "restart the VirtualBox service (VBoxSVC) or reboot, then check the VirtualBox install / vboxdrv kernel module"
        elif [ -z "$timeout_bin" ]; then
            emit WARN C35-vm-ar "VBoxManage ($vbm) did not answer 'list vms' (no 'timeout' binary present to cap this call, so a wedged VBoxSVC could have hung here indefinitely instead) — after-report runs will fail over to the host lock" \
                "check the VirtualBox install / vboxdrv kernel module; install coreutils' timeout for hang protection on this check"
        else
            emit WARN C35-vm-ar "VBoxManage ($vbm) did not answer 'list vms' — after-report runs will fail over to the host lock" \
                "check the VirtualBox install / vboxdrv kernel module"
        fi
        return
    fi
    # CR finding codex-10: VBoxManage/venv being PRESENT is not the same
    # fact as after-report.sh being willing to USE them right now — with
    # VBOXMANAGE_PATH unset (the normal state in an interactive shell) it
    # refuses outright unless HIMMEL_VM_AR_LIVE=1 is set for that one
    # invocation (HIMMEL-2623 incident hardening). Saying plain "reachable"
    # here would read as "ready to go" in exactly the configuration the
    # runner itself explicitly does not trust.
    if [ -z "${VBOXMANAGE_PATH:-}" ] && [ "${HIMMEL_VM_AR_LIVE:-0}" != "1" ]; then
        # CodeRabbit (PR #2206): this row's own text says "will still
        # refuse" — `emit OK` excludes a row from $BODY and every counter,
        # so that refusal was invisible in the summary and in
        # --file-issue reports. INFO is the honest severity for it.
        emit INFO C35-vm-ar "VBoxManage + venv python present, but scripts/vm/after-report.sh will still refuse an unset VBOXMANAGE_PATH without HIMMEL_VM_AR_LIVE=1 set for that invocation (by design, HIMMEL-2623 opt-in guard) — set it for a real run"
        return
    fi
    emit OK C35-vm-ar "VM after-report runner reachable (VBoxManage + venv python present, opt-in guard satisfied for this environment)"
}

# --- C32: main-branch reference-transaction guard installed (HIMMEL-2095) -------
# scripts/hooks/check-main-ref-transaction.sh refuses a `git commit
# --no-verify` (then `push --no-verify`) landing directly on refs/heads/main
# — the exact bypass class d05ef8ca/913073df/378c21f9/310646da used, since
# --no-verify skips pre-commit/commit-msg/pre-push but NOT
# reference-transaction. That script being TRACKED is not the same as the
# protection being ACTIVE: `.git/hooks/` is untracked, so shipping the
# script ships nothing until scripts/hooks/install-main-ref-transaction.sh
# has actually written the shim into the git common dir. WARN, never FAIL —
# same rationale as C8/C9: this is a safety net whose absence must not flip
# the scripted exit code (no --fix here either, for the same reason C7/C9
# stay advisory-only: re-arming a git hook is a real repo mutation, not
# something a read-only doctor pass should do unasked).
#
# GIT VERSION: this check's hooks-directory resolution (`git rev-parse
# --path-format=absolute --git-path hooks`, in check_c32 below) needs git
# >= 2.31 -- but this repo's declared minimum is git 2.30
# (docs/setup/new-machine.md, scripts/install/deps.json). CodeRabbit (PR
# #2195) caught this exposure; a first fix pass assumed an unsupported
# `--path-format` makes `rev-parse` FAIL, so it was safe to branch on the
# resolved value being empty -- THAT ASSUMPTION WAS WRONG and was reported
# as fact without being tested. Proven directly instead: `git rev-parse
# --totally-unknown-option --git-path hooks` echoes the unrecognised
# option back as an ordinary output line, THEN the (relative, since the
# format request was never honoured) resolved path -- and still exits 0.
# `rev-parse` does not reject options it does not recognise; it echoes
# them. So on git < 2.31, `rev-parse --path-format=absolute --git-path
# hooks` returns rc=0 with a garbled, non-absolute value -- NOT empty, NOT
# an error -- and a bare `[ -z "$hooks_dir" ]` check would have let that
# value through as if it were a real hooks directory, exactly the "false
# OK on a supported configuration" pattern this whole guard exists to
# close, in the code meant to close it. Fixed below by validating the
# VALUE (single-line, starts with `/` or a drive letter) rather than
# trusting the exit status -- an invalid value is normalized to empty and
# falls into the SAME repo-check branch a genuinely failed/empty
# resolution does, so a station on git 2.30 reports WARN "UNVERIFIED"
# either way, never a false OK. Validating the value, not the git version,
# because a version check is only as good as our own reading of which
# versions echo which options -- this proved that reading wrong once
# already.
#
# Test seams: HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR overrides the resolved hooks
# directory this check probes (default: `git -C "$REPO_ROOT" rev-parse
# --path-format=absolute --git-path hooks` -- git's own answer, see
# check_c32's own comment); HIMMEL_DOCTOR_MAIN_REF_TARGET, when SET (even to
# an empty string -- presence, not non-emptiness, `${VAR+set}`), overrides
# the target value this check reads instead of querying `git -C "$REPO_ROOT"
# config --local --get himmel-main-ref.target`. Both required because THIS
# station's real checkout may or may not have the hook installed, or a
# target configured, depending on when this ran relative to setup.sh -- and
# because check_c32 always reads $REPO_ROOT's OWN git config (never a fake
# sandbox's), the target-VALUE seam is the only way to observe the
# missing/mismatched-target WARN rows without mutating the real checkout's
# git config from a test (the exact hermeticity class this ticket's own
# test suites were hardened against — scripts/himmelctl/test/
# test-suite-hermeticity.sh names the invariant). The hooks_dir RESOLUTION
# itself (core.hooksPath unset/relative/absolute, any invoking cwd, any
# worktree) is git's own logic via that one call, not re-derived here, so
# it needs no separate test seam of its own -- it is exercised end-to-end
# by install-main-ref-transaction.sh's sandboxed test suite (real toplevels
# and worktrees are cheap to fabricate there; this suite's REPO_ROOT is
# fixed to the real checkout).
check_c32() {
    local marker="# himmel-main-ref-transaction-v1"

    # Where THIS checkout's git actually looks for a hook -- git's OWN
    # resolution (`--path-format=absolute --git-path hooks`), the exact
    # call install-main-ref-transaction.sh uses (see that installer's
    # header, round 3): already correct for core.hooksPath unset, relative,
    # or absolute, and already correct regardless of invoking cwd. A
    # hand-rolled re-derivation of "common dir + /hooks" here would be a
    # FOURTH copy of arithmetic that has already been wrong twice on this
    # ticket -- ask git instead of re-deriving its answer.
    #
    # Note on scope: a RELATIVE core.hooksPath resolves PER WORKTREE (git's
    # own semantics -- confirmed empirically, see the installer's header).
    # This check reports on THIS checkout alone, same as every other row in
    # this doctor pass; it does not enumerate sibling worktrees. The
    # installer, unlike this check, DOES cover every linked worktree that
    # EXISTS AT INSTALL TIME when core.hooksPath is relative -- see its own
    # header for why C32 does not need to, and for the residual gap
    # (a worktree created afterwards needs the installer re-run).
    local hooks_dir="${HIMMEL_DOCTOR_MAIN_REF_HOOKS_DIR:-}"
    if [ -z "$hooks_dir" ]; then
        local hooks_dir_raw
        hooks_dir_raw=$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || hooks_dir_raw=""
        # Validate the VALUE, not just the exit status -- see the GIT
        # VERSION note above: git < 2.31 echoes an unrecognised
        # --path-format=absolute back as output and still exits 0, so a
        # non-empty, rc=0 result is not proof the format was honoured. An
        # invalid value normalizes to empty here, so it falls into the SAME
        # repo-check branch immediately below that an actually-empty
        # resolution does -- one decision point, not two.
        case "$hooks_dir_raw" in
            /*|[A-Za-z]:[/\\]*) hooks_dir="$hooks_dir_raw" ;;
            *) hooks_dir="" ;;
        esac
    fi

    if [ -z "$hooks_dir" ]; then
        # empty hooks_dir is NOT automatically "nothing to check" -- confirm
        # with a call that needs no particular git version (`rev-parse
        # --git-dir`, supported since git's earliest releases) whether we
        # are actually inside a repo before deciding which verdict applies.
        if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
            emit WARN C32-main-ref-guard "inside a git repo, but could not resolve an absolute hooks directory (git rev-parse --path-format=absolute --git-path hooks did not return a usable absolute path -- this needs git >= 2.31; this station's git may be older) -- treating as UNVERIFIED, not protecting" \
                "upgrade git to >= 2.31 and re-run himmel-doctor; if the git version is already >= 2.31, run: git -C $REPO_ROOT rev-parse --path-format=absolute --git-path hooks   # and report what it prints"
        else
            emit OK C32-main-ref-guard "not inside a git repo — nothing to check"
        fi
        return
    fi
    local hook_path="$hooks_dir/reference-transaction"
    if [ -f "$hook_path" ] && grep -Fq "$marker" "$hook_path"; then
        # Git silently ignores a non-executable hook on Unix -- a hook that
        # lost its +x bit (a chmod, a checkout on a filesystem that drops
        # the mode, a copy) provides nothing while reading as "installed".
        if [ ! -x "$hook_path" ]; then
            emit WARN C32-main-ref-guard "reference-transaction guard installed at $hook_path but is NOT EXECUTABLE — git silently ignores a non-executable hook on Unix, so this is currently NOT protecting main" \
                "chmod +x $hook_path   # or re-run: bash $REPO_ROOT/scripts/hooks/install-main-ref-transaction.sh"
            return
        fi
        # The shim itself deliberately FAILS OPEN when its configured
        # target stops resolving (install-main-ref-transaction.sh's own
        # header explains why: refusing on a broken shim would fail EVERY
        # ref update in the repo, not just main). That means "installed"
        # alone is not "protecting" -- surface the silently-absent case as
        # a WARN instead of an OK, or this check itself becomes blind to
        # exactly the failure mode it exists to catch.
        #
        # The target is read the EXACT same way the shim itself reads it at
        # hook-run time: `git config --local --get himmel-main-ref.target`.
        # NEVER read, parse, or evaluate anything out of the hook FILE's
        # content beyond the plain marker-presence grep above -- two prior
        # rounds tried embedding the target INSIDE this file (an `eval`-ed
        # shell assignment, then a literal comment line) and each broke a
        # different way (arbitrary code execution via a hostile marker'd
        # file; a newline byte in the path injecting a shell line). git
        # config is the representation with no escaping question left --
        # see the installer's own header for the full reasoning and the
        # empirical proof (a value containing `$`, backticks, `"`, and a
        # literal embedded newline round-trips byte-exact).
        local target_path
        if [ "${HIMMEL_DOCTOR_MAIN_REF_TARGET+set}" = "set" ]; then
            target_path="$HIMMEL_DOCTOR_MAIN_REF_TARGET"
        else
            target_path=$(git -C "$REPO_ROOT" config --local --get himmel-main-ref.target 2>/dev/null) || target_path=""
        fi
        # A missing/unconfigured target must WARN, not silently fall
        # through to OK -- an empty target_path here previously skipped the
        # unreadable-target check entirely and reported a broken shim as
        # protecting (fixed: require a successfully configured, non-empty,
        # READABLE target before ever reporting OK).
        if [ -z "$target_path" ]; then
            emit WARN C32-main-ref-guard "reference-transaction guard installed at $hook_path but no target is configured (git config himmel-main-ref.target is unset) — treating as UNVERIFIED, not protecting" \
                "bash $REPO_ROOT/scripts/hooks/install-main-ref-transaction.sh   # re-run to configure the target"
            return
        fi
        # `-f`, not just `-r` (round 9, mirrors the shim's own fix -- see
        # install-main-ref-transaction.sh's header): `[ -r DIR ]` is TRUE
        # for a readable directory, so this check would otherwise certify
        # a target shape the shim itself would brick on (bash fails to
        # `exec` a directory, so the shim would fail-CLOSED instead of the
        # documented fail-open -- every ref update refused). No realistic
        # route makes the installer-set target a directory, but reporting
        # OK for a shape that would brick the repo is worse than the
        # negligible probability costs to guard against.
        if [ ! -f "$target_path" ] || [ ! -r "$target_path" ]; then
            emit WARN C32-main-ref-guard "reference-transaction guard installed at $hook_path but its configured target check script is missing/unreadable/not-a-regular-file ($target_path) — the shim fails OPEN (silently NOT protecting main) rather than bricking every ref update" \
                "bash $REPO_ROOT/scripts/hooks/install-main-ref-transaction.sh   # re-run from a checkout that still has scripts/hooks/check-main-ref-transaction.sh"
            return
        fi
        emit OK C32-main-ref-guard "main-branch reference-transaction guard installed ($hook_path)"
        return
    fi
    if [ -f "$hook_path" ]; then
        emit WARN C32-main-ref-guard "a reference-transaction hook exists at $hook_path but is NOT Himmel's main-branch reference-transaction guard — a --no-verify commit/push to main would not be refused, and the installer will not overwrite it" \
            "merge scripts/hooks/check-main-ref-transaction.sh into $hook_path manually, or remove the foreign hook and re-run: bash $REPO_ROOT/scripts/hooks/install-main-ref-transaction.sh"
        return
    fi
    emit WARN C32-main-ref-guard "main-branch reference-transaction guard NOT installed at $hook_path — a --no-verify commit/push directly to main would not be refused" \
        "bash $REPO_ROOT/scripts/hooks/install-main-ref-transaction.sh"
}

# --- C33: graphify graph staleness (HIMMEL-2095) --------------------------------
# scripts/graphify/graph-cadence.sh (arm-time task HIMMEL-GraphPublish-Himmel,
# scripts/luna/graphmap-cadence.sh, 6-hour interval) appends one JSONL row to
# <handover-root>/.graph-cadence/ledger.jsonl per fire. This check reads only
# the LAST row -- it reports current staleness, not history. Read-only,
# advisory, no --fix (mirrors C7/C8/C9/C10's own "never sudo/mutate, WARN
# never FAILs" rationale: an unpublished graph degrades graphify query
# quality, it never breaks the harness itself).
#
# NEVER FAIL, always OK/WARN/INFO -- same rationale as C9's own comment: a
# stale graph is real drift, but flipping himmel-doctor's scripted exit code
# over it would make an advisory row block scripted callers (--fix loops,
# CI-adjacent wrappers) that only care about hard guardrail breakage.
#
# THRESHOLD = 3x the armed cadence interval (18h at the 6h default) before
# WARNing on age alone -- one MISSED fire is not staleness (the next one is
# due within the interval), three in a row is. `action:"failed"` on the last
# row WARNs immediately regardless of age -- a failing cadence needs
# attention now, not after it has ALSO gone quiet for 18h.
DOCTOR_C33_CADENCE_INTERVAL_S=$((6 * 3600))

# portable ISO8601 UTC ("...Z") -> epoch seconds; GNU date first (Git Bash/
# Linux), then BSD date -j (macOS) -- same fallback shape as check_c18's
# _c18_epoch. Echoes nothing (rc=1) on an unparsable timestamp; callers treat
# that as "can't determine age", never crash.
_c33_epoch() {
    date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null  # gnu-ok: GNU date -d is paired with the BSD date -j fallback on this same line
}

# human-readable age from a second count: Nd / Nh / Nm, coarsest unit that
# is >=1, never a bare second count (which would read as spuriously precise
# for a check that only samples once).
_c33_age_human() {
    local s="$1"
    if [ "$s" -ge 86400 ]; then printf '%dd' $((s / 86400));
    elif [ "$s" -ge 3600 ]; then printf '%dh' $((s / 3600));
    else printf '%dm' $((s / 60)); fi
}

check_c33_graph_stale() {
    local root ledger
    # PURE resolver (never handover_root_ensure) -- himmel-doctor is
    # read-only and must not create the handover dir as a side effect of a
    # diagnostic pass.
    load_dotenv --root "$REPO_ROOT" HANDOVER_DIR >/dev/null 2>&1 || true
    if ! root="$(handover_root 2>/dev/null)" || [ -z "$root" ]; then
        emit OK C33-graph-stale "graph-cadence: no handover root resolvable — cadence has not run here"
        return
    fi
    ledger="$root/.graph-cadence/ledger.jsonl"
    if [ ! -f "$ledger" ]; then
        emit OK C33-graph-stale "graph-cadence: ledger absent ($ledger) — cadence not yet armed or has not fired"
        return
    fi
    # PR-B panel r3, codex-1 (the same class as codex-8 and r2's codex-4, a
    # third level down): `tail`'s failure was discarded by 2>/dev/null, so an
    # UNREADABLE ledger produced an empty $last_line and fell into the branch
    # below that reports OK "has not completed a run yet" -- this row calling
    # a ledger it could not read HEALTHY. `[ -f ]` does not test readability,
    # so a chmod 000 ledger (or any I/O error) reaches here: probed at the
    # site -- -f passes, tail exits 1, output empty. Separate the two states
    # by tail's own exit status, exactly as the jq gate below separates
    # "cannot read" from "read and empty": unreadable is WARN (undetermined),
    # genuinely empty is still OK.
    local last_line tail_rc=0
    last_line="$(tail -n 1 "$ledger" 2>/dev/null)" || tail_rc=$?
    if [ "$tail_rc" -ne 0 ]; then
        emit WARN C33-graph-stale "graph-cadence: ledger exists at $ledger but could not be READ (tail exited $tail_rc -- permissions or I/O), so staleness cannot be determined (this is NOT the same as healthy)" "check the ledger's permissions and ownership: ls -l $ledger"
        return
    fi
    if [ -z "$last_line" ]; then
        emit OK C33-graph-stale "graph-cadence: ledger present but empty — cadence has not completed a run yet"
        return
    fi
    # PR-B panel r1, codex-8: "cannot tell" must never render as "healthy".
    # A missing jq is reported directly here (WARN, not a silent fall-through
    # to a "?"-filled OK line below) -- same rationale as check_c24's own
    # jq-availability gate, but WARN rather than INFO: unlike C24 (a scan
    # that can legitimately have nothing to check), this row's whole job is a
    # staleness verdict, and "undetermined" is never a safe default for one.
    if ! command -v jq >/dev/null 2>&1; then
        emit WARN C33-graph-stale "graph-cadence: jq not on PATH -- cannot read the ledger's last row, so staleness cannot be determined (this is NOT the same as healthy)" "install jq"
        return
    fi
    local behind action ts age_s age_human remedy
    behind="$(printf '%s' "$last_line" | jq -r '.merges_behind // "?"' 2>/dev/null)"
    action="$(printf '%s' "$last_line" | jq -r '.action // "?"' 2>/dev/null)"
    ts="$(printf '%s' "$last_line" | jq -r '.ts // empty' 2>/dev/null)"
    age_human="unknown"
    # PR-B panel r2, codex-4 (codex-8's own class, one level down): a
    # RECOGNIZED action with a missing or unparseable timestamp used to still
    # earn OK, because the failed-parse branch simply never ran and
    # `stale_on_age` was left at its 0 default -- "the age check didn't fire"
    # silently read as "the age check passed". Track age determination
    # EXPLICITLY instead of inferring it from stale_on_age's default.
    local now_epoch ts_epoch stale_on_age=0 age_undetermined=1
    now_epoch="$(date -u +%s)"
    if [ -n "$ts" ] && ts_epoch="$(_c33_epoch "$ts")" && [ -n "$ts_epoch" ]; then
        age_undetermined=0
        age_s=$((now_epoch - ts_epoch))
        [ "$age_s" -ge 0 ] || age_s=0
        age_human="$(_c33_age_human "$age_s")"
        [ "$age_s" -gt $((3 * DOCTOR_C33_CADENCE_INTERVAL_S)) ] && stale_on_age=1
    fi
    remedy="bash scripts/graphify/graph-cadence.sh   # or check scripts/luna/graphmap-cadence.sh status for the armed task"
    if [ "$action" = "failed" ]; then
        emit WARN C33-graph-stale "graph stale: $behind commits behind main / last cadence run $age_human ago FAILED" "$remedy"
        return
    fi
    if [ "$stale_on_age" -eq 1 ]; then
        emit WARN C33-graph-stale "graph stale: $behind commits behind main / last cadence run $age_human ago (no run in over 3x the armed interval)" "$remedy"
        return
    fi
    # codex-8 (cont.): an unreadable/malformed ledger row (jq failed to parse
    # the last line, or a genuinely unrecognized `action` value) leaves
    # `action` as "?" or empty -- that must WARN too, not fall through to OK
    # just because it also isn't literally "failed". Only the pipeline's own
    # KNOWN-GOOD action values earn an OK verdict.
    case "$action" in
        skipped|refreshed|published|merged)
            # codex-4 (cont.): ...and even a known-good action only earns OK
            # when its age was actually established. "Cannot tell how old
            # this is" must never render as "recent enough to be healthy".
            if [ "$age_undetermined" -eq 1 ]; then
                emit WARN C33-graph-stale "graph-cadence: last ledger row (action=$action) has a missing or unparseable timestamp -- its age cannot be established, so staleness cannot be ruled out (this is NOT the same as healthy)" "inspect $ledger directly"
            else
                emit OK C33-graph-stale "graph stale: $behind commits behind main / last cadence run $age_human ago (action=$action)"
            fi
            ;;
        *)
            emit WARN C33-graph-stale "graph-cadence: last ledger row's action is unrecognized or undetermined ('$action') -- the row may be malformed/unparseable; staleness cannot be established from it (this is NOT the same as healthy)" "inspect $ledger directly"
            ;;
    esac
}

# _c34_subagent_guard_registered <hooks.json> - true only when
# guard-subagent-model.sh is registered under a PreToolUse entry whose
# matcher includes "Agent" as a whole alternative (not a substring match of
# e.g. "AgentFoo"). A bare grep for the filename anywhere in the file passes
# just as confidently for a mention under a different event, a different
# matcher, or a disabled/commented block - which is not proof the guard is
# actually wired on Agent dispatch (CR round 3, HIMMEL-2653). Requires jq and
# a parseable file; both absent count as "not verified", never as registered.
_c34_subagent_guard_registered() {
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg pat 'guard-subagent-model\.sh' '
        (.hooks.PreToolUse // [])
        | any(
            (.matcher // "") as $m
            | ($m | split("|") | any(. == "Agent"))
            and ((.hooks // []) | any(.command // "" | test($pat)))
          )
    ' "$1" >/dev/null 2>&1
}

# --- C34-cost-guards: HIMMEL-2653 cost guards actually in force ------------------
# HIMMEL-2653 found the fleet burning 73% of its weekly bank in ~1.5 days
# while the live dispatch gate watched only the five-hour window, plus
# subagents at 50.06% of raw spend (general-purpose alone 49.85%) with no
# structural nudge toward naming a model. This reports whether the three
# guards that answer those findings are actually wired in THIS checkout, not
# just present as unreferenced files. Reads only tracked repo files (no
# operator machine state), so there is no HOME/CLAUDE_DIR seam here — REPO_ROOT
# is the only variable.
check_c34() {
    local hooks_json="$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/hooks.json"
    local subagent_guard="$REPO_ROOT/scripts/hooks/guard-subagent-model.sh"
    local impl_guard="$REPO_ROOT/scripts/hooks/guard-implementor-dispatch.sh"
    local ctx_fill="$REPO_ROOT/scripts/context-fill.sh"

    if [ -r "$subagent_guard" ] && [ -f "$hooks_json" ] && _c34_subagent_guard_registered "$hooks_json"; then
        emit OK C34-cost-guards "guard-subagent-model.sh exists and is registered under PreToolUse/Agent in hooks.json"
    else
        local missing=""
        [ -r "$subagent_guard" ] || missing="${missing}scripts/hooks/guard-subagent-model.sh missing or unreadable; "
        if [ ! -f "$hooks_json" ]; then
            missing="${missing}hooks.json not found at $hooks_json; "
        elif ! command -v jq >/dev/null 2>&1; then
            missing="${missing}jq not on PATH — cannot verify its PreToolUse/Agent registration in hooks.json; "
        elif ! jq -e . "$hooks_json" >/dev/null 2>&1; then
            missing="${missing}hooks.json does not parse as JSON; "
        elif ! _c34_subagent_guard_registered "$hooks_json"; then
            missing="${missing}not registered under a PreToolUse entry whose matcher includes Agent in marketplace/plugins/himmel-ops/hooks/hooks.json; "
        fi
        emit WARN C34-cost-guards "guard-subagent-model.sh is not fully wired (${missing%; })" \
            "see scripts/hooks/guard-subagent-model.sh and its Agent-matcher entry in marketplace/plugins/himmel-ops/hooks/hooks.json"
    fi

    if [ -r "$impl_guard" ] && grep -q 'seven_day' "$impl_guard" 2>/dev/null; then
        emit OK C34-cost-guards "guard-implementor-dispatch.sh is weekly (seven_day)-bank-aware"
    else
        emit WARN C34-cost-guards "guard-implementor-dispatch.sh does not mention seven_day — the dispatch gate is five-hour-blind" \
            "see HIMMEL-2653: the guard must read both the five_hour and seven_day bank windows"
    fi

    if [ -r "$ctx_fill" ] && grep -q -- '--warn-at' "$ctx_fill" 2>/dev/null; then
        emit OK C34-cost-guards "context-fill.sh supports --warn-at (handover-fill nudge)"
    else
        emit INFO C34-cost-guards "context-fill.sh does not support --warn-at yet — legs get no handover-fill nudge" \
            "see HIMMEL-2653: context-fill.sh --warn-at N (default 50)"
    fi
}

# --- C36: stray .git at the system temp dir root (HIMMEL-2739) -----------------
# Incident 2026-09-07 09:4x: a subagent's fixture work ran `git init` relative
# to an inherited (unset/broken) cwd and it landed at /tmp, leaving an EMPTY
# /tmp/.git behind. From then on block-edit-on-main walked UP from every
# edited path under /tmp, found that .git, treated /tmp itself as a repo
# root, and failed closed on every Write/Edit under /tmp station-wide with
# "cannot determine branch for '/tmp' - refusing to evaluate" — invisible to
# this doctor until now. Platform guard: POSIX ${TMPDIR:-/tmp} and Windows
# $TEMP/$TMP are both checked directly (is_windows() branch below) rather
# than needing a .ps1 twin.
#
# WARN only, never FAIL: this is an environmental accident, not a repo
# misconfiguration, and the doctor's exit code must not flip on it. Never
# --fix here either — an EMPTY .git is safe to rmdir but a NON-EMPTY one must
# never be touched by an unattended pass; the remedy is printed, not run.
check_c36_stray_tmp_git() {
    local tmp_git="" tmp_git_q=""
    if is_windows; then
        local base="${TEMP:-${TMP:-}}"
        if [ -z "$base" ]; then
            emit INFO C36-stray-tmp-git "neither TEMP nor TMP is set — cannot resolve the system temp dir to check for a stray .git"
            return
        fi
        tmp_git="$base/.git"
    else
        tmp_git="${TMPDIR:-/tmp}/.git"
    fi
    tmp_git_q="$(printf '%q' "$tmp_git")"

    if [ ! -e "$tmp_git" ]; then
        emit OK C36-stray-tmp-git "no stray .git at the system temp dir root ($tmp_git)"
        return
    fi
    if [ ! -d "$tmp_git" ]; then
        emit WARN C36-stray-tmp-git "$tmp_git exists but is not a directory — investigate by hand before removing anything" \
            "ls -la $tmp_git_q"
        return
    fi
    if [ -z "$(ls -A "$tmp_git" 2>/dev/null)" ]; then
        emit WARN C36-stray-tmp-git "stray EMPTY .git directory at $tmp_git — block-edit-on-main walks up from every edited path under the system temp dir, finds it, and fails closed station-wide with \"cannot determine branch for '$(dirname "$tmp_git")' - refusing to evaluate\" (HIMMEL-2739)" \
            "rmdir $tmp_git_q"
    else
        emit WARN C36-stray-tmp-git "stray NON-EMPTY .git directory at $tmp_git — same station-wide block-edit-on-main failure as an empty one, but its contents were left in place, NOT deleted (HIMMEL-2739)" \
            "inspect $tmp_git_q by hand before removing anything"
    fi
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
check_c30
check_c31
check_c32
check_c33_graph_stale
check_c34
check_c35
check_c36_stray_tmp_git
echo
printf 'Summary: %s%d FAIL%s  %s%d WARN%s  %s%d INFO%s\n' "$C_RED" "$n_fail" "$C_0" "$C_YEL" "$n_warn" "$C_0" "$C_DIM" "$n_info" "$C_0"

if [ "$DO_FILE" = 1 ] && [ $((n_fail+n_warn+n_info)) -gt 0 ]; then
    echo; echo "Filing a consolidated GitHub issue:"; file_issue
elif [ $((n_fail+n_warn)) -gt 0 ] && [ -t 1 ]; then
    echo; printf 'File a consolidated GitHub issue? [y/N] '; read -r ans
    case "$ans" in y|Y|yes) file_issue ;; *) echo "  (skipped — re-run with --file-issue to file)";; esac
fi

[ "$n_fail" -eq 0 ]
