#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell — codex-lane terminal write-fence.
#
# WHY (HIMMEL-745): the codex-direct lane runs himmel's deny-guards through the
# .codex/hooks.json adapter, but block-edit-on-main.sh is wired ONLY on the
# Edit|Write|MultiEdit matcher — so the PATCH path (Edit/Write tools) is fenced
# while the TERMINAL path (a shell command that writes a file, pushes, or hits
# the network) is not. On the Claude lane the auto-mode classifier + the
# GLM-lane block-glm-external-writes.sh cover that terminal surface; codex has
# NO classifier layer (HIMMEL-748 ratified deterministic-guards-only for codex),
# so this hook is the codex-lane classifier SUBSTITUTE for the terminal write
# surface. It is the behavioural port of hermes's parity_guard.py
# (terminal_external_write_reason + the terminal branch of _edit_on_main_reason)
# into the Claude hook convention, wired ONLY in .codex/hooks.json.
#
# Two classes, both scoped to a tool_input.command (Bash/PowerShell payloads):
#
#   (a) EXTERNAL-WRITE — plain/force git push; git remote-URL rewrite
#       (remote set-url / config ...url); gh PR-mutations (create/merge/close/
#       edit/review/comment/api/…) with a read carve-out (gh issue *, gh pr
#       view/diff/checks/status/list, gh run view/list/watch); and network CLIs
#       (curl/wget/iwr/irm/Invoke-WebRequest/Invoke-RestMethod). FAIL-CLOSED:
#       denied UNLESS the named opt-in CODEX_EXTERNAL_WRITES_OK=1 is set (mirrors
#       HERMES_EXTERNAL_WRITES_OK / GLM_EXTERNAL_WRITES_OK semantics).
#
#   (b) WRITE-ON-MAIN — a write-shaped terminal command (redirect > / >>, tee,
#       Set-Content/Out-File/Add-Content, sed -i, cp/mv/rm on a path, git commit)
#       whose effective repo (tool_input.cwd if present, else process cwd) is
#       checked out on its DEFAULT branch (main/master) is refused, UNLESS the
#       repo root carries a .single-writer marker (same opt-out as
#       block-edit-on-main.sh). A feature/worker-branch cwd is ALLOWED — normal
#       worktree work is never blocked. Conservative on false positives: a
#       command that is not confidently write-shaped is ALLOWED (the charter is
#       the known write shapes, not a general sandbox).
#
# Known limitations (accidental-shape guard, like block-glm-external-writes /
# block-read-secrets): a write verb displaced from command position (env-prefix
# `FOO=1 git push`, sudo/xargs/timeout wrappers, hyphenated aliases) is missed
# (under-block); command-text scanning shares those wrapper/quoting gaps. A
# `.exe` suffix on the Windows lane (`git.exe push`, `curl.exe`) IS handled.
#
# Exit codes: 0 allow; 2 block (stderr shown to the model). Bash 3.2-safe.
set -euo pipefail

# On a security-relevant hook a TOP-LEVEL errexit abort must BLOCK (exit 2),
# never slip through as a non-blocking exit 1 (only exit 2 denies under Claude
# Code, and the codex adapter only translates exit 2 -> JSON deny). Mirrors
# block-glm-external-writes.sh's clamp. The malformed-JSON path below stays
# fail-OPEN (sibling-hook parity — Claude Code / codex emit valid JSON).
# shellcheck disable=SC2154  # rc is assigned by rc=$? inside the same trap string
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq >/dev/null 2>&1; then
    echo "block-terminal-write-fence: jq not on PATH — refusing to evaluate; install jq" >&2
    exit 2
fi

# lib.sh drives the on-main branch read (is_on_main). Class (b) is skipped if it
# cannot be sourced (fail-OPEN for the hygiene class), but class (a) — the
# security-critical external-write fence — still runs.
LIB_OK=1
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null || LIB_OK=0

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$tool" in
    Bash|PowerShell|"") ;;   # "" = tolerate a payload with no tool_name
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# Lower-case + flatten newlines TO ';' (a newline separates commands like ';';
# flattening to spaces would UNDER-block a two-line "gh pr view 1\ngh pr merge 1"
# by reading it as one command). Keeps command boundaries visible to the
# (^|[;&|(]) anchor. Mirrors block-glm-external-writes.sh.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\n\r' ';;')

# Command-position occurrence counter (start-of-command or right after ; & | ( —
# deliberately NOT space/quote, so a blocked verb quoted in a message does not
# false-block). grep -c counts LINES; cmd_lc is one line, so count PER-MATCH via
# grep -oE | wc -l. grep exits 1 on zero matches; `|| true` keeps errexit calm.
count_cmd() {
    local n
    n=$(printf '%s' "$cmd_lc" | grep -oE "(^|[;&|(])[[:space:]]*($1)" | wc -l) || true
    printf '%s' "$((n))"
}

# ------------------------------------------------------------------ class (a)
# External-write fence (port of parity_guard.terminal_external_write_reason /
# block-glm-external-writes.sh shapes). FAIL-CLOSED unless the operator opts in.
if [ "${CODEX_EXTERNAL_WRITES_OK:-0}" != "1" ]; then
    deny_ext() {
        {
            echo "⛔ block-terminal-write-fence: $1"
            echo "    The codex-direct lane has no auto-mode classifier, so external-write"
            echo "    shapes are hard-blocked (HIMMEL-745). Commit locally and deliver a"
            echo "    branch diff; the operator / trusted lane pushes and opens PRs."
            echo "    Opt-in: set CODEX_EXTERNAL_WRITES_OK=1 in the launching shell."
        } >&2
        exit 2
    }

    # `git(\.exe)?` etc: a Windows lane invokes git.exe/curl.exe/gh.exe — the
    # bare-name anchor would miss those (CR codex-1), so tolerate an optional
    # `.exe`. Flag atom is `-[^[:space:];&|]+` (spec parity: parity_guard uses
    # `-\S+`) so an attached-value long flag like `--git-dir=/x` before `push`
    # cannot break the anchor (CR under-block).
    gp_shape='git(\.exe)?([[:space:]]+-[^[:space:];&|]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+push([[:space:]]|$)'
    # config-url branch requires a VALUE token after the url key, so a read
    # (`git config --get remote.origin.url`, no trailing value) is NOT blocked
    # (CR codex-2); only a `config …url <newvalue>` rewrite matches.
    # config-subcommand flags carry the same optional-VALUE tolerance as the
    # git-level flags (`--file <path>` before the url key), else a value-taking
    # config flag breaks the anchor and lets a url rewrite slip through (CR).
    gu_shape='(git(\.exe)?([[:space:]]+-[^[:space:];&|]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+remote[[:space:]]+set-url|git(\.exe)?([[:space:]]+-[^[:space:];&|]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+config([[:space:]]+-[^[:space:];&|]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+[^[:space:];&|]*url[[:space:]]+[^[:space:];&|])'
    gh_shape='gh(\.exe)?([[:space:]]|$)'
    gh_allow='gh(\.exe)?[[:space:]]+(issue([[:space:]]|$)|pr[[:space:]]+(view|diff|checks|status|list)([[:space:]]|$)|run[[:space:]]+(view|list|watch)([[:space:]]|$))'
    net_shape='(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)(\.exe)?([[:space:]]|$)'

    if [ "$(count_cmd "$gp_shape")" -gt 0 ]; then
        deny_ext "git push is refused (external-write class)."
    fi
    if [ "$(count_cmd "$gu_shape")" -gt 0 ]; then
        deny_ext "rewriting a git remote / push URL is refused (external-write class)."
    fi
    if [ "$(count_cmd "$gh_shape")" -gt "$(count_cmd "$gh_allow")" ]; then
        deny_ext "gh is limited (external-write class): issue ops + pr/run reads only; PR mutations belong to the operator / trusted lane."
    fi
    if [ "$(count_cmd "$net_shape")" -gt 0 ]; then
        deny_ext "network CLIs are refused (external-write class); chores are repo-local."
    fi
fi

# ------------------------------------------------------------------ class (b)
# Write-on-main lock (port of the terminal branch of parity_guard's
# _edit_on_main_reason). Only fires when the command is CONFIDENTLY write-shaped
# AND the effective repo is on its default branch AND no .single-writer opt-out.

# True (rc 0) iff at least one redirect / tee target is a REAL file (not
# /dev/null and not a temp path). $TMP-redirects and > /dev/null are NOT writes
# worth fencing (per the charter's precision list).
is_temp_or_devnull() {
    # The '$tmp'* / '%temp%'* branches keep the $ / % literal on purpose (they
    # match an unexpanded env-var temp ref in the payload text), so SC2016 is
    # expected — a directive can only sit in front of the whole `case`.
    # shellcheck disable=SC2016
    case "$1" in
        /dev/null|/dev/null/*) return 0 ;;
        /tmp|/tmp/*|*/tmp/*|*/temp/*) return 0 ;;
        *appdata/local/temp*) return 0 ;;
        '$tmp'*|'$temp'*|'%temp%'*|'%tmp%'*) return 0 ;;
        *) return 1 ;;
    esac
}

redirect_real_target() {
    local c="$1" chunk tok
    # Redirect targets: >>? then the following token. `2>&1` / `>&2` yield no
    # target token (the char after > is & / a digit-then-&, excluded), so they
    # are not treated as file writes.
    while IFS= read -r chunk; do
        [ -z "$chunk" ] && continue
        tok=$(printf '%s' "$chunk" | sed -E 's/^>>?[[:space:]]*//')
        [ -z "$tok" ] && continue
        is_temp_or_devnull "$tok" || return 0
    done < <(printf '%s' "$c" | grep -oE '>>?[[:space:]]*[^[:space:];&|<>()]+' || true)
    # tee targets: `tee [-a] <file>` (also matches `| tee file`).
    while IFS= read -r chunk; do
        [ -z "$chunk" ] && continue
        tok=$(printf '%s' "$chunk" | sed -E 's/^tee[[:space:]]+(-a[[:space:]]+)?//')
        [ -z "$tok" ] && continue
        is_temp_or_devnull "$tok" || return 0
    done < <(printf '%s' "$c" | grep -oE 'tee[[:space:]]+(-a[[:space:]]+)?[^[:space:];&|<>()]+' || true)
    return 1
}

write_shaped() {
    local c="$1"
    # git commit at command position (flag-tolerant; `commit` as the verb so
    # commit-graph / commit-tree do not match). `git(\.exe)?` catches the
    # Windows-lane git.exe form (CR parity with class (a)).
    printf '%s' "$c" | grep -qE '(^|[;&|(])[[:space:]]*git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit([[:space:]]|$)' && return 0
    # sed -i (in-place edit).
    printf '%s' "$c" | grep -qE '(^|[;&|(])[[:space:]]*sed[[:space:]]+[^;&|]*-i' && return 0
    # PowerShell file writers at command position (not matched inside quoted /
    # logged text like `echo set-content …` — CR false-positive fix).
    printf '%s' "$c" | grep -qE '(^|[;&|(])[[:space:]]*(set-content|out-file|add-content)([[:space:]]|$)' && return 0
    # cp / mv / rm targeting a path (at command position).
    printf '%s' "$c" | grep -qE '(^|[;&|(])[[:space:]]*(cp|mv|rm)[[:space:]]+[^[:space:]]' && return 0
    # redirect / tee to a real (non-devnull, non-temp) file.
    redirect_real_target "$c" && return 0
    return 1
}

if [ "$LIB_OK" = 1 ] && command -v git >/dev/null 2>&1 && write_shaped "$cmd_lc"; then
    # Effective repo dir: tool payload cwd, else the hook process cwd.
    cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
    [ -z "$cwd" ] && cwd="$PWD"

    branch_rc=0
    is_on_main "$cwd" || branch_rc=$?
    # rc 0 = on default branch -> candidate for the lock; rc 1 (feature branch /
    # detached) or rc 2 (branch unreadable) -> ALLOW (fail-open on the hygiene
    # class so normal worktree work is never blocked).
    if [ "$branch_rc" -eq 0 ]; then
        repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
        # .single-writer opt-out (mirrors block-edit-on-main.sh): a repo that
        # commits straight to main by design (personal vaults / state repos).
        if [ -z "$repo_root" ] || [ ! -f "$repo_root/.single-writer" ]; then
            {
                echo "⛔ block-terminal-write-fence: refusing a write-shaped terminal command —"
                echo "    the effective repo is checked out on its default branch (main/master)."
                echo "    (command: $cmd)"
                echo "    (cwd: $cwd)"
                echo ""
                echo "    Feature work belongs in a worktree per CLAUDE.md, not on the primary"
                echo "    main checkout (write-on-main class, HIMMEL-745). To proceed:"
                echo "      - run the command from a type/slug worktree, or"
                echo "      - touch \"$repo_root/.single-writer\" if this repo commits to main by design."
            } >&2
            exit 2
        fi
    fi
fi

exit 0
