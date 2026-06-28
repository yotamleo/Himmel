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

# --- C6: PATH-fragile bare-interpreter MCP servers ------------------------------
# Same failure class as C1 node: a macOS GUI launch has a minimal PATH, so an MCP
# server wired as a bare interpreter name (uvx/bun/deno/python/pwsh) silently fails
# to start and all its tools vanish. Scans user settings + the himmel plugins.
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

# --- C8: stale pipeline-cadence runners (armed before a format change) ----------
# The pipeline-cadence runners (.bat/.sh) are GENERATED at arm time and NOT
# regenerated on a code change (HIMMEL-588), so a cadence armed before a
# runner-format change (e.g. the HIMMEL-575 --settings auto-approve injection)
# keeps firing the old format with no nudge. Read-only: compare the version
# stamped into the runners against the current CADENCE_RUNNER_FORMAT_VERSION and
# point a stale one at `arm --force`. No --fix — a re-arm touches the OS
# scheduler, so this stays advisory (mirrors C7).
check_c8() {
    # Default must match pipeline-cadence.sh's runner home EXACTLY — that is
    # $HOME/.claude/pipeline-cadence (it keys off $HOME, NOT $CLAUDE_DIR), so use
    # $HOME here too rather than $CLAUDE_DIR_R, which would diverge when an
    # operator relocates .claude via CLAUDE_DIR. PIPELINE_BAT_DIR overrides both.
    local bat_dir="${PIPELINE_BAT_DIR:-${HOME:-}/.claude/pipeline-cadence}" ver
    if ! ver="$(cadence_runner_stamp "$bat_dir")"; then
        emit OK C8-cadence "no armed pipeline-cadence runners (skipped)"
        return
    fi
    if [ "$ver" -lt "$CADENCE_RUNNER_FORMAT_VERSION" ]; then
        emit WARN C8-cadence \
            "pipeline-cadence runners are stale (format v$ver < v$CADENCE_RUNNER_FORMAT_VERSION) — armed before a runner-format change, still firing the old format" \
            "re-arm: bash scripts/luna/pipeline-cadence.sh arm --force"
    else
        emit OK C8-cadence "pipeline-cadence runners current (format v$ver)"
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
echo
printf 'Summary: %s%d FAIL%s  %s%d WARN%s  %s%d INFO%s\n' "$C_RED" "$n_fail" "$C_0" "$C_YEL" "$n_warn" "$C_0" "$C_DIM" "$n_info" "$C_0"

if [ "$DO_FILE" = 1 ] && [ $((n_fail+n_warn+n_info)) -gt 0 ]; then
    echo; echo "Filing a consolidated GitHub issue:"; file_issue
elif [ $((n_fail+n_warn)) -gt 0 ] && [ -t 1 ]; then
    echo; printf 'File a consolidated GitHub issue? [y/N] '; read -r ans
    case "$ans" in y|Y|yes) file_issue ;; *) echo "  (skipped — re-run with --file-issue to file)";; esac
fi

[ "$n_fail" -eq 0 ]
