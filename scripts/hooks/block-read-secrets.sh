#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell/Read/Grep.
#
# Blocks tool calls that would read or print the contents of secret files
# (.env, .envrc, *.pem, *.key, id_rsa, id_ed25519, credentials.json,
# secrets.y[a]ml, *.p12, *.pfx). Pattern after block-edit-on-main.sh.
#
# Memory: feedback_secrets_handling.md — "never cat .env or secret files;
# ask user to echo specific values via `!` prefix; narrow grep if file
# must be read." Plugs the friction case where an overly-broad grep on
# .env leaked a Jira API token mid-session.
#
# Detection model:
#   * Read tool   → block when file_path matches a secret pattern
#   * Grep tool   → block when path matches a secret pattern
#   * Bash/PS tool → split the command into clauses at shell separators
#                    (; | & ( ) ` newlines); for each clause the first token
#                    that isn't an env-assignment / wrapper (sudo,doas,env,
#                    xargs) / shell keyword is the COMMAND. Block when that
#                    command is a reader (cat/grep/head/jq/sed/awk/…) AND a
#                    secret-file arg follows, OR on a `< secretfile` redirect.
#                    In-place sed/awk (`-i`) is carved out per-clause. This
#                    command-position model (HIMMEL-436) replaced a global
#                    reader-OR-secret scan that false-positived on inline
#                    interpreter bodies (`node -e "…obj.key…file…"`).
#
# Reader command list intentionally narrow: cat/grep/head/jq/sed/awk/etc.
# In-place forms of sed and awk (`sed -i …`, `awk -i inplace …`) are
# carved out below since they rewrite in place without piping content
# to stdout. Interactive editors (`vim`, `nano`, `vi`, `nvim`, `emacs`)
# and the read-only `view` are NOT in the reader list at all — they
# never surface content to Claude as a tool result.
# Write-only ops (echo >, tee, mv, cp, docker -v) are also not blocked.
#
# Known limitations (consciously accepted — gate targets accidental leaks,
# not a determined attacker):
#   * `bash -c 'cat .env'` — the quoted body is one shell token; we never
#     see `cat` and `.env` as separate tokens after metachar splitting.
#   * `git show HEAD:.env`, `git cat-file -p HEAD:.env` — git not in
#     reader list (would false-positive on most git commands).
#   * Cross-command exfil: `cp .env /tmp/x; cat /tmp/x` — cp is write-only,
#     and the second command targets a non-secret path.
#   * Variable indirection: `F=.env; cat $F` — no `.env` token after `cat`.
#   * Inline interpreter bodies (`node -e`, `python -c`): command-position
#     fixes the COMMON false positive (coincidental `obj.key` property access
#     and reader-named identifiers like `file`/`type`). A body that literally
#     contains `<separator><reader-name><secretfile>` adjacent (e.g.
#     `node -e "x; cat .env"`) still fragments to a `cat .env` clause and
#     blocks — same class as `bash -c 'cat .env'`.
#   * A reader whose own filter/arg equals a secret name: `jq .env file.json`
#     (filter literally `.env`) blocks — jq is the command, `.env` its arg;
#     command-position can't tell a jq filter path from a filename.
#   * Wrappers are carved out only in their bare form, where the command is
#     the wrapper's immediate next token: {sudo,doas,env,xargs,time,nice,
#     command,nohup}. A wrapper with leading ARGS before the command
#     (`timeout 5 cat .env`, `nice -n5 cat .env`, `sudo -u u cat .env`) makes
#     that arg the command token → the read is allowed through. Likewise
#     wrappers outside the set (`strace`, `flatpak-spawn`). Determined-attacker
#     territory; the gate targets the common accidental shapes.
#   * `cat <<< .env` here-string normalises to `cat < < < .env` and trips the
#     `<`-redirect path though it reads no file.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow (default)
#   2 — block; stderr is shown to Claude and the user
#
# Bypass: set READ_SECRETS_OK=1 in the shell that launched Claude Code
# (Claude cannot inject env vars into hooks). Session-sticky; restart to
# re-enable. Or comment the hook in .claude/settings.json.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "block-read-secrets: jq not on PATH — refusing to evaluate; install jq or comment the hook in .claude/settings.json" >&2
    exit 2
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

is_secret_path() {
    # Match against basename (path-prefix agnostic). Globs only; no regex.
    local p="${1#\"}"; p="${p#\'}"
    p="${p%\"}"; p="${p%\'}"
    local base="${p##*/}"
    case "$base" in
        # Non-secret env TEMPLATES — committed placeholder files whose whole
        # purpose is to be shareable (the himmel one is verified scrubbed,
        # HIMMEL-286). Reading these is safe; carve them out BEFORE the .env.*
        # secret arm (first-match-wins) so the bridge/operator can `cat .env.example`
        # without the guard mis-firing. Real value files (.env, .env.local,
        # .env.production, …) are NOT listed here and stay blocked.
        .env.example|.env.sample|.env.template|.env.dist) return 1 ;;
        .env|.env.*|.envrc|id_rsa|id_ed25519|credentials.json|secrets.yaml|secrets.yml)
            return 0 ;;
        *.pem|*.key|*.p12|*.pfx)
            return 0 ;;
    esac
    return 1
}

is_reader_cmd() {
    # ONLY commands that exfiltrate file contents to stdout (i.e. would
    # leak the secret into Claude's tool result). Interactive editors
    # (vim, nano, vi, nvim, emacs, view) and write-only ops (echo >,
    # tee, mv, cp) are NOT readers — they don't surface content to
    # Claude. sed/awk ARE readers by default (they print to stdout);
    # the in-place forms are carved out by is_inplace_cmd below.
    case "$1" in
        cat|bat|tac|head|tail|less|more|most)  return 0 ;;
        grep|egrep|fgrep|rg|ripgrep|ag)        return 0 ;;
        sed|awk|gawk|mawk|nawk)                return 0 ;;
        jq|yq)                                 return 0 ;;
        xxd|od|hexdump|strings|base64|file)    return 0 ;;
        # PowerShell readers (Bash matcher may still see these via pwsh -c).
        Get-Content|gc|Select-String|sls|type) return 0 ;;
    esac
    return 1
}

is_inplace_token() {
    # True for tokens that indicate sed/awk are operating in-place
    # (rewriting the file without piping content to stdout). Covers:
    #   sed -i        (GNU)
    #   sed -i ''     (BSD — '' is its own token, shell strips quotes
    #                  so we just match the bare `-i`)
    #   sed -i.bak    (BSD — backup-suffix glued to the flag)
    #   sed --in-place
    #   awk -i inplace (gawk extension; `inplace` is its own token)
    #   awk --in-place
    case "$1" in
        -i|--in-place|inplace) return 0 ;;
        -i.*)                  return 0 ;;
    esac
    return 1
}

bypass_hint() {
    cat >&2 <<'EOF'

To bypass intentionally, set READ_SECRETS_OK=1 in the shell that launched
Claude Code (env vars can't be injected per-call). Example:
    READ_SECRETS_OK=1 claude
Session-sticky. Restart Claude without it to re-enable the guard.

Prefer: ask the user to echo the specific value via the `!` prefix in the
prompt, or narrow the read to one key (e.g. `grep '^FOO=' .env | cut -d= -f2-`
under bypass).
EOF
}

case "$tool" in
    Read)
        fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
        [ -z "$fp" ] && exit 0
        if is_secret_path "$fp"; then
            [ "${READ_SECRETS_OK:-0}" = "1" ] && exit 0
            echo "⛔ block-read-secrets: refusing Read of secret file: $fp" >&2
            bypass_hint
            exit 2
        fi
        ;;

    Grep)
        gpath=$(printf '%s' "$input" | jq -r '.tool_input.path // empty' 2>/dev/null || true)
        [ -z "$gpath" ] && exit 0
        if is_secret_path "$gpath"; then
            [ "${READ_SECRETS_OK:-0}" = "1" ] && exit 0
            echo "⛔ block-read-secrets: refusing Grep on secret path: $gpath" >&2
            bypass_hint
            exit 2
        fi
        ;;

    Bash|PowerShell)
        cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
        [ -z "$cmd" ] && exit 0

        # Split the command into CLAUSES at shell separators so a reader and a
        # secret in UNRELATED parts of the command don't cross-trip (the old
        # global-OR did — it blocked any reader-named token anywhere plus any
        # secret-glob token anywhere, which false-positived on inline
        # interpreter bodies like `node -e "…cfg.key…file…"`). Separators
        # ; | & ( ) ` and newlines each become a clause boundary — a literal
        # newline via a POSIX backslash-newline sed replacement (works on BSD
        # and GNU sed; do NOT use GNU-only `\n` in the replacement). `<`/`>`
        # are spaced into their own tokens so a `< secretfile` redirect stays
        # detectable. Shell quoting is intentionally NOT parsed (see header).
        normalized=$(printf '%s' "$cmd" | sed -e 's/[;|&()`]/\
/g' -e 's/</ < /g' -e 's/>/ > /g')

        block=0
        # Iterate clause-by-clause. bash 3.2-safe: a while-read heredoc, NOT
        # mapfile (bash 4) and NOT a for-loop over unquoted $normalized (which
        # would re-split on spaces and destroy clause boundaries).
        while IFS= read -r clause; do
            if [ -z "$clause" ]; then continue; fi
            cmdtok=""
            reader=0
            secret_after=0
            inplace=0
            prev=""
            # shellcheck disable=SC2086 # intentional word split for tokenisation
            for tok in $clause; do
                # Redirect-from-secret: authoritative for `<`-redirects and
                # independent of command position (e.g. `done <.env`).
                if [ "$prev" = "<" ] && is_secret_path "$tok"; then
                    block=1
                fi
                if [ -z "$cmdtok" ]; then
                    # Still hunting the command token: skip leading redirect
                    # tokens, env-assignments (VAR=val), common reader-wrapping
                    # commands, and shell keywords.
                    case "$tok" in
                        "<"|">")                            prev="$tok"; continue ;;
                        [A-Za-z_]*=*)                       prev="$tok"; continue ;;
                        sudo|doas|env|xargs|time|nice|command|nohup)
                                                            prev="$tok"; continue ;;
                        if|while|until|then|else|elif|"!")  prev="$tok"; continue ;;
                    esac
                    cmdtok="$tok"
                    if is_reader_cmd "$cmdtok"; then reader=1; fi
                    prev="$tok"
                    continue
                fi
                # Past the command token: scan its arguments.
                if is_inplace_token "$tok"; then inplace=1; fi
                if is_secret_path "$tok";   then secret_after=1; fi
                prev="$tok"
            done
            # A clause leaks only when its COMMAND is a reader and a secret
            # follows as an arg. In-place sed/awk rewrites (carved per-clause,
            # so a global `-i` can't mask a separate read clause) don't leak.
            if [ "$reader" = "1" ] && [ "$secret_after" = "1" ] && [ "$inplace" = "0" ]; then
                block=1
            fi
        done <<EOF
$normalized
EOF

        if [ "$block" = "1" ]; then
            [ "${READ_SECRETS_OK:-0}" = "1" ] && exit 0
            echo "⛔ block-read-secrets: refusing $tool command that reads a secret file:" >&2
            echo "    $cmd" >&2
            bypass_hint
            exit 2
        fi
        ;;

    *)
        exit 0
        ;;
esac

exit 0
