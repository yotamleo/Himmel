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
#   (b) WRITE-ON-MAIN — as of HIMMEL-2526, DESTINATION-based rather than
#       cwd-only: a write-shaped terminal command (redirect > / >>, tee,
#       sed -i, cp/mv/rm/touch) has its actual TARGET PATH(s) resolved and
#       refused when a target lands inside a protected checkout (on
#       main/master, or the PRIMARY checkout on a feature branch), regardless
#       of the cwd's own branch — closing the gap where a subagent wrote into
#       the primary checkout from an unrelated cwd and this class never saw
#       it. The git-commit and PowerShell-writer (Set-Content/Out-File/
#       Add-Content) arms have no extractable target, so they keep this
#       lane's ORIGINAL HIMMEL-745 cwd predicate (is_on_main on
#       tool_input.cwd, fail-open on a feature branch or an unreadable
#       branch, honouring a repo-root .single-writer marker) — a deliberate,
#       documented carve-out (codex-lane parity), not an oversight; see
#       block-write-into-main-checkout.sh's header for the split. This class
#       now lives in that shared script (sourced below), so it can be reused
#       byte-identically by the Claude Bash PreToolUse chain instead of a
#       second copy drifting.
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
{ [ -r "$SCRIPT_DIR/../guardrails/lib.sh" ] && . "$SCRIPT_DIR/../guardrails/lib.sh"; } 2>/dev/null || LIB_OK=0

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
    # HIMMEL-844: `url.<base>.insteadOf` / `.pushInsteadOf` rewrite every remote
    # URL without ending in `url`, so the key may also end in `insteadof` (both
    # spellings; cmd_lc is lowercased), and the one-shot `git -c <k>.insteadof=`.
    # config-url branch requires a VALUE token after the url key, so a read
    # (`git config --get remote.origin.url`, no trailing value) is NOT blocked
    # (CR codex-2); only a `config …url <newvalue>` rewrite matches.
    # config-subcommand flags carry the same optional-VALUE tolerance as the
    # git-level flags (`--file <path>` before the url key), else a value-taking
    # config flag breaks the anchor and lets a url rewrite slip through (CR).
    gu_shape='(git(\.exe)?([[:space:]]+-[^[:space:];&|]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+remote[[:space:]]+set-url|git(\.exe)?([[:space:]]+-[^[:space:];&|]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+config([[:space:]]+-[^[:space:];&|]+([[:space:]]+[^[:space:];&|]+)?)*([[:space:]]+(set|add|replace-all))?([[:space:]]+-[^[:space:];&|]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+[^[:space:];&|]*(url|insteadof)[[:space:]]+[^[:space:];&|]|git(\.exe)?[[:space:]]+([^;&|]*[[:space:]])?(-c|--config-env)[=[:space:]]*[^[:space:];&|]*insteadof=)'
    gh_shape='gh(\.exe)?([[:space:]]|$)'
    gh_allow='gh(\.exe)?[[:space:]]+(issue([[:space:]]|$)|pr[[:space:]]+(view|diff|checks|status|list)([[:space:]]|$)|run[[:space:]]+(view|list|watch)([[:space:]]|$))'
    net_shape='(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)(\.exe)?([[:space:]]|$)'

    if [ "$(count_cmd "$gp_shape")" -gt 0 ]; then
        deny_ext "git push is refused (external-write class)."
    fi
    # Round 7: decode every ANSI-C dollar-quote segment (bash's own escape set) BEFORE the
    # dequote/lowercase step, so hex/octal/unicode-escaped `git`, `config` and `insteadof` read
    # as the words git sees. An unterminated / undecodable segment appends `insteadof` (deny-leaning).
    ansic_decode() {
        LC_ALL=C awk '
        function hv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
        function ch(code) { return (code > 0 && code < 128) ? sprintf("%c", code) : "#" }
        # decode one ANSI-C body from index j to the next unescaped quote; sets globals ni (next
        # index), cl (closed), bd (bad escape). A NUL escape ends the string: the rest is dropped.
        function cdec(j,   seg, nul, cut, c, e, k, v, d, mx) {
            seg = ""; nul = 0; cut = 0; cl = 0; bd = 0
            while (j <= n) {
                c = substr(s, j, 1)
                if (c == q) { cl = 1; j++; break }
                if (c != "\\") { seg = seg c; j++; continue }
                e = substr(s, j + 1, 1); j += 2
                if (e == "") { bd = 1; break }
                if ((k = index("abeEfnrtv\\\047\"?", e)) > 0) {
                    seg = seg substr("\007\010\033\033\014\012\015\011\013\\\047\"?", k, 1); continue
                }
                if (e ~ /[0-7]/) {
                    v = e + 0; d = 1
                    while (d < 3 && substr(s, j, 1) ~ /[0-7]/) { v = v * 8 + substr(s, j, 1); j++; d++ }
                    v = v % 256
                    if (v == 0 && !nul) { nul = 1; cut = length(seg) }
                    seg = seg ch(v); continue
                }
                if (e == "x" || e == "u" || e == "U") {
                    mx = (e == "x") ? 2 : (e == "u") ? 4 : 8; v = 0; d = 0
                    while (d < mx && hv(substr(s, j, 1)) >= 0) { v = v * 16 + hv(substr(s, j, 1)); j++; d++ }
                    if (d == 0) bd = 1
                    if (v == 0 && !nul) { nul = 1; cut = length(seg) }
                    seg = seg ch(v); continue
                }
                if (e == "c") { if (j > n) bd = 1; else j++; seg = seg "#"; continue }
                seg = seg "\\" e
            }
            ni = j
            return nul ? substr(seg, 1, cut) : seg
        }
        { s = (NR > 1 ? s "\n" : "") $0 }
        END {
            q = "\047"; n = length(s); i = 1; out = ""; bad = 0
            while (i <= n) {
                c = substr(s, i, 1)
                if (c != "$" || substr(s, i + 1, 1) != q) { out = out c; i++; continue }
                out = out cdec(i + 2); i = ni
                if (!cl || bd) bad = 1
            }
            # over-approximation: a decoy opener inside quotes/comments can swallow a real segment above,
            # so every opener is also decoded on its own and appended (no quote-state lexer).
            for (p = 1; p < n; p++) {
                if (substr(s, p, 1) == "$" && substr(s, p + 1, 1) == q) { cand = cdec(p + 2); out = out " " cand }
            }
            printf "%s", out
            if (bad) printf " insteadof "
        }'
    }
    cmd_dq=$(printf '%s' "$cmd" | ansic_decode | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\n\r' ';;' | LC_ALL=C tr -d "'\"\\\\")
    # Blunt rule: decoded + dequoted + lowercased text containing `git` AND `insteadof`.
    # Accepted overmatch: `git log --grep insteadof`.
    gu_blunt=0
    case $cmd_dq in
        *git*) case $cmd_dq in *insteadof*) gu_blunt=1 ;; esac ;;
    esac
    if [ "$gu_blunt" -gt 0 ] ||
       [ "$(cmd_lc=$cmd_dq count_cmd "$gu_shape")" -gt 0 ]; then
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
# Write-on-main lock. As of HIMMEL-2526 this class is DESTINATION-based
# (redirect/tee/sed -i/cp/mv/rm/touch targets resolved and checked against
# main_checkout_verdict) rather than the old cwd-only "is this command
# write-shaped AND is the cwd's repo on main" test — the shared logic now
# lives in block-write-into-main-checkout.sh (sourced by every terminal-write
# lane, Bash chain included) so the two lanes cannot drift. is_temp_or_devnull
# stays HERE (not moved) so the sourced script — self-sufficient for its own
# direct-exec mode too — can reuse this exact copy via its `declare -f` guard
# instead of duplicating it when running in THIS process.
#
# CODEX-LANE PARITY (unchanged in this PR): the git-commit / PowerShell-writer
# arms have no extractable destination, so they stay on this lane's original
# HIMMEL-745 cwd predicate (is_on_main, fail-open on a feature branch or an
# unreadable branch) — block-write-into-main-checkout.sh ports that exact
# logic for the SOURCED case; see its header for the full rationale.
# shellcheck disable=SC2329,SC2317
# SC2329 ("never invoked") / SC2317 ("unreachable") — same false positive, different shellcheck versions: this function is called
# from block-write-into-main-checkout.sh once sourced below — shellcheck's
# per-file analysis cannot see that a followed (SC1091) file calls BACK into
# a function defined in the file that sourced it.
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

if [ "$LIB_OK" = 1 ]; then
    # shellcheck source=./block-write-into-main-checkout.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/block-write-into-main-checkout.sh"
fi

exit 0
