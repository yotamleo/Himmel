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
#   * `bash -c 'cat .env'` IS now caught (HIMMEL-440): when the clause command
#     resolves to a shell interpreter (bash/sh/zsh/dash/ksh/ash), the matcher
#     recurses into the `-c '<body>'` and re-runs the reader+secret check on the
#     body's first statement (the body is real shell, so this is FP-free —
#     unlike node -e / python -c non-shell bodies). Remaining `-c` gaps:
#     variable bodies `bash -c "$CMD"` (variable indirection, below), process
#     substitution `bash <(echo 'cat .env')`, and exotic flag interleavings
#     where `-c` follows a non-flag operand. (Multi-statement bodies like
#     `bash -c 'echo hi; cat .env'` already block via the later clause.) A
#     secret passed as a POSITIONAL into the body (`bash -c 'cat "$1"' _ .env`)
#     reaches the reader via `$1` — the same accepted variable-indirection gap
#     below, not a literal arg. Scanning stops at the body's closing quote, so a
#     trailing positional after a NON-secret body read is not over-blocked.
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
#   * NTFS alternate data streams: `.env:stream` is not matched (low risk —
#     POSIX toolchains don't address ADS via the colon syntax).
#   * 8.3 short names: `ENV~1` is not matched (short-name generation is off
#     by default on modern NTFS volumes).
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow (default)
#   2 — block; stderr is shown to Claude and the user
#
# Bypass: set READ_SECRETS_OK=1 in the shell that launched Claude Code
# (Claude cannot inject env vars into hooks). Session-sticky; restart to
# re-enable. Or comment the hook in .claude/settings.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "block-read-secrets: cannot source guardrails/lib.sh — refusing to evaluate" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-read-secrets: jq not on PATH — refusing to evaluate; install jq or comment the hook in .claude/settings.json" >&2
    exit 2
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

# is_secret_path: this hook's name for the shared is_secret_basename predicate
# (scripts/guardrails/lib.sh, HIMMEL-879 — pattern list + case-fold rationale
# live there; also shared with block-edit-on-main.sh). Kept as a thin wrapper
# so the many call sites below don't need to change name.
is_secret_path() {
    is_secret_basename "$@"
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

is_interp_cmd() {
    # Shell interpreters whose `-c '<body>'` body IS shell — so re-running the
    # matcher on the body is correct and FP-free (HIMMEL-440). Deliberately
    # EXCLUDES node/python/etc.: their `-e`/`-c` bodies are NOT shell, and
    # scanning them is exactly what caused the HIMMEL-436 false positives.
    case "$1" in
        bash|sh|zsh|dash|ksh|ash) return 0 ;;
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
            # HIMMEL-440 recursion state (interpreter `-c` body re-resolution):
            interp=0          # cmdtok resolved to a shell interpreter
            found_c=0         # a -c / -*c flag has been seen
            rec_cmd=""        # the recursed command (body's first token)
            rec_reader=0
            rec_secret=0
            rec_inplace=0
            bodyq=""          # the -c body's outer quote char (' or "), if any
            bodyclosed=0      # past the body's closing quote → tokens are $0/$1…
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
                    if is_interp_cmd "$cmdtok"; then interp=1; fi
                    prev="$tok"
                    continue
                fi
                # Past the command token: scan its arguments.
                if is_inplace_token "$tok"; then inplace=1; fi
                if is_secret_path "$tok";   then secret_after=1; fi

                # HIMMEL-440: when the command is a shell interpreter, recurse
                # into its `-c '<body>'`. The body is real shell, so re-running
                # the reader+secret check on it is correct (and FP-free, unlike
                # node -e / python -c non-shell bodies). Only the FIRST
                # statement of the body needs this — any `;`/`|`/`&`-separated
                # later statements are already their own clauses.
                if [ "$interp" = "1" ]; then
                    if [ -z "$rec_cmd" ]; then
                        if [ "$found_c" = "0" ]; then
                            # Hunt for -c: skip interpreter flags; a -c or a
                            # combined trailing-c bundle (-lc, -ic, -xc) arms
                            # the next operand as the recursed command. A
                            # non-flag operand BEFORE any -c (`bash run.sh`)
                            # means this isn't a -c invocation → abort recursion.
                            case "$tok" in
                                --*)    : ;;
                                -c|-*c) found_c=1 ;;
                                -*)     : ;;
                                *)      interp=0 ;;
                            esac
                        else
                            # -c seen; the first non-flag operand is the body's
                            # command. Note the body's outer quote char so we can
                            # stop scanning at its close (everything after is
                            # $0/$1… positionals the body does not read). Strip
                            # ONE leading quote glued on by the quote-naive
                            # tokeniser (`'cat` → `cat`); bash-3.2-safe.
                            case "$tok" in
                                -*) : ;;
                                *)
                                    case "$tok" in
                                        \'*) bodyq="'" ;;
                                        \"*) bodyq='"' ;;
                                    esac
                                    rtok="${tok#\'}"; rtok="${rtok#\"}"
                                    rec_cmd="$rtok"
                                    if is_reader_cmd "$rec_cmd"; then rec_reader=1; fi
                                    # Unquoted single-word body (`bash -c cat .env`)
                                    # has no args of its own — the rest are
                                    # positionals. Mark the body already closed.
                                    [ -z "$bodyq" ] && bodyclosed=1
                                    ;;
                            esac
                        fi
                    elif [ "$bodyclosed" = "0" ]; then
                        # Inside the body: scan ITS args. is_secret_path already
                        # strips one trailing quote (`.env'` → `.env`).
                        if is_inplace_token "$tok"; then rec_inplace=1; fi
                        if is_secret_path "$tok";   then rec_secret=1; fi
                        # A token bearing the body's closing quote ends the body;
                        # subsequent tokens are positionals (`bash -c 'cat x' .env`
                        # — the `.env` is $0, never read). Quote-naive: matches the
                        # outer quote only (escaped/nested quotes are accepted gaps).
                        case "$tok" in
                            *\') [ "$bodyq" = "'" ] && bodyclosed=1 ;;
                            *\") [ "$bodyq" = '"' ] && bodyclosed=1 ;;
                        esac
                    fi
                fi
                prev="$tok"
            done
            # A clause leaks only when its COMMAND is a reader and a secret
            # follows as an arg. In-place sed/awk rewrites (carved per-clause,
            # so a global `-i` can't mask a separate read clause) don't leak.
            if [ "$reader" = "1" ] && [ "$secret_after" = "1" ] && [ "$inplace" = "0" ]; then
                block=1
            fi
            # HIMMEL-440: the recursed interpreter `-c` body leaked a secret.
            if [ "$rec_reader" = "1" ] && [ "$rec_secret" = "1" ] && [ "$rec_inplace" = "0" ]; then
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
