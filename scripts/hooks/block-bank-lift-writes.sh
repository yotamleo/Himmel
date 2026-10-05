#!/usr/bin/env bash
# PreToolUse hook (Bash | Edit|Write|MultiEdit|NotebookEdit | apply_patch) —
# HIMMEL-4445. The bank lift (~/.himmel/state/bank-lift.json, written by
# `scripts/lib/bank-lift.sh set`, HIMMEL-4423) relaxes the 7-day bank gate
# while it is valid. Raising your own spending ceiling is an OPERATOR call, so
# an agent session may not:
#   1. write the lift file, in any write form (redirects, tee, cp/mv/install/
#      ln/rsync, dd of=, sed -i, interpreter one-liners, the file tools), under
#      any spelling of its path (~, $HOME, ${HOME}, /home/<user>, relative,
#      quote/glob/ANSI-C/brace obfuscation, symlinks), nor fill the state dir
#      as a whole with a lift-named (or unknowable) entry;
#   2. run `bank-lift.sh set`, under any launcher (bash/sh/direct/source/.,
#      env/timeout/nohup/command/exec/sudo/xargs/…) or path spelling.
# `bash <path>/bank-lift.sh show` / `clear` and reads of the lift stay
# allowed. By console ruling (rounds 6-7) any OTHER command with a word naming
# bank-lift.json or bank-lift.sh denies, over-deny accepted: rm/mv/cp of the
# lift, `git commit -m` / ticket titles / echo naming it. Remedy for text:
# `git commit -F <file>`, a jira --desc-file. Only the reader allowlist
# (cat less head tail stat ls file wc test [ jq grep rg) may name it.
#
# Remedy named in every deny: the operator runs `! bash scripts/lib/bank-lift.sh
# set ...` at their own prompt. There is deliberately NO env bypass — a bypass
# an agent can request is the very thing this fence exists to remove.
#
# Why a purpose-built tokenizer instead of block-write-into-main-checkout.sh's:
# that fence's tokenizer is welded to main_checkout_verdict (repo/worktree
# resolution, per-verb operand classes against a checkout root), not a reusable
# "is this word a write target" API. This hook needs the inverse question
# (does ANY write target name one fixed file), so it reuses the shared
# write-verb GRAMMAR instead: its suite renders lib-test-write-fence-matrix.sh's
# verb x spelling axis against the lift path.
#
# Fail-closed (security fence): missing jq, malformed / non-object JSON, or a
# tokenizer error -> deny. Any other non-0/2 exit is clamped to 2.
#
# ponytail: text-level fence — it cannot see a renamed COPY of bank-lift.sh
# run in a later call, Write-tool CONTENT that is itself a script writing the
# lift, a script FILE that writes the lift without being handed its path,
# inline interpreter code that never spells bank-lift.json / bank-lift.sh, variable
# indirection that never mentions bank-lift, or a bind mount; upgrade path is
# to move the lift out of agent-writable reach (an operator-owned file the
# gate verifies), filed when one of these is seen in a transcript.
# ponytail: the PowerShell tool is not wired, Windows is parked under
# HIMMEL-4102 — wire it when Windows legs resume.
#
# Hook I/O: JSON on stdin; exit 0 = allow, exit 2 = block (stderr shown).
# Platform guard: bash 3.2-safe (no mapfile, no associative arrays).
set -uo pipefail
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

deny() {
    {
        echo "block-bank-lift-writes: refusing — $1."
        echo
        echo "    ~/.himmel/state/bank-lift.json relaxes the 7-day bank gate (HIMMEL-4423),"
        echo "    so setting it is operator-only (HIMMEL-4445). Ask the operator to run, at"
        echo "    their own prompt:"
        echo
        echo "        ! bash scripts/lib/bank-lift.sh set ..."
        echo
        echo "    Reading the lift, \`bank-lift.sh show\` and \`bank-lift.sh clear\` stay"
        echo "    allowed. There is no env bypass: the operator's own command is the path."
    } >&2
    exit 2
}

command -v jq >/dev/null 2>&1 || deny "jq not found on PATH (fail-closed)"
input=$(cat)
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || deny "malformed or non-object JSON payload (fail-closed)"

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || deny "unreadable tool_name (fail-closed)"
case "$tool" in
    Bash|Write|Edit|MultiEdit|NotebookEdit|apply_patch) ;;
    *) exit 0 ;;
esac
CWD=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
[ -n "$CWD" ] || CWD=$PWD

LIFT_NAME=bank-lift.json
STATE_REAL="$HOME/.himmel/state"
HAS_CD=0   # set for Bash: a cd/pushd makes every relative path's dir unknown

# ---------------------------------------------------------------- paths ---

# _norm <abs-path> -> lexically normalised (., .., //), no trailing slash.
_norm() {
    local p="$1" out="" seg rest
    rest="${p#/}"
    while [ -n "$rest" ]; do
        case "$rest" in */*) seg="${rest%%/*}"; rest="${rest#*/}" ;; *) seg="$rest"; rest="" ;; esac
        case "$seg" in
            ''|.) ;;
            ..) out="${out%/*}" ;;
            *) out="$out/$seg" ;;
        esac
    done
    printf '%s' "${out:-/}"
}

# _expand <word> -> word with ~ / ~user / $HOME / ${HOME} expanded and, when
# the cwd is known, made absolute. Prints "?/<word>" for an unknown dir.
# shellcheck disable=SC2088,SC2016  # literal ~ / $HOME spellings are matched as text
_expand() {
    local w="$1"
    case "$w" in
        '~') w="$HOME" ;;
        '~/'*) w="$HOME/${w#\~/}" ;;
        '~'*) w="/home/${w#\~}" ;;
        '$HOME'|'${HOME}') w="$HOME" ;;
        '$HOME/'*) w="$HOME/${w#\$HOME/}" ;;
        '${HOME}/'*) w="$HOME/${w#\$\{HOME\}/}" ;;
    esac
    case "$w" in
        /*) ;;
        '$'*|'`'*) printf '?/%s' "$w"; return ;;
        *) if [ "$HAS_CD" = 1 ]; then printf '?/%s' "$w"; return; fi; w="$CWD/$w" ;;
    esac
    # A `..` after a symlink climbs out of the link's TARGET, not out of the
    # lexical parent: resolve the existing directory part physically.
    case "$w" in
        *..*)
            local d="${w%/*}" b="${w##*/}" pd
            case "$b" in .|..) d="$w"; b="" ;; esac
            if pd=$(CDPATH='' cd -P -- "${d:-/}" 2>/dev/null && pwd -P); then
                w="$pd${b:+/$b}"
            fi
            ;;
    esac
    _norm "$w"
}

# _glob_from_word <s> -> a [[ ]] pattern: {a,b} becomes *.
_glob_from_word() {
    local s="$1" out=""
    while :; do
        case "$s" in
            *'{'*'}'*) out="$out${s%%\{*}*"; s="${s#*\}}" ;;
            *) out="$out$s"; break ;;
        esac
    done
    printf '%s' "$out"
}

_is_dynamic() { case "$1" in *'$'*|*'`'*) return 0 ;; esac; return 1; }

# _name_matches <component-from-word> <real-name>: the word component could
# name real-name (literal, glob, brace, case-folded), or is dynamic.
_name_matches() {
    local c="$1"
    _is_dynamic "$c" && return 0
    c=$(_glob_from_word "$c")
    # Case-folded only here: option parsing elsewhere is case-sensitive (-t/-T).
    local r=1
    shopt -s nocasematch
    # shellcheck disable=SC2053  # the RHS is deliberately a pattern
    [[ "$2" == $c ]] && r=0
    shopt -u nocasematch
    return "$r"
}

# _dir_kind <expanded-dir> -> STATE | HIMMEL | HOME | UNKNOWN | NONE
_dir_kind() {
    local d="$1" last parent
    case "$d" in '?'|'?/'*) echo UNKNOWN; return ;; esac
    if _is_dynamic "$d"; then echo UNKNOWN; return; fi
    last="${d##*/}"; parent="${d%/*}"; parent="${parent##*/}"
    if [ -n "$last" ] && [ -n "$parent" ] && _name_matches "$parent" .himmel && _name_matches "$last" state; then
        echo STATE; return
    fi
    if [ -d "$d" ] && [ -d "$STATE_REAL" ] && [ "$d" -ef "$STATE_REAL" ]; then echo STATE; return; fi
    if [ -n "$last" ] && _name_matches "$last" .himmel; then echo HIMMEL; return; fi
    if [ -d "$d" ] && [ -d "$HOME/.himmel" ] && [ "$d" -ef "$HOME/.himmel" ]; then echo HIMMEL; return; fi
    if [ "$d" = "$HOME" ] || { [ -d "$d" ] && [ "$d" -ef "$HOME" ]; }; then echo HOME; return; fi
    case "$d" in /home/*/*|/Users/*/*|/root/*) ;; /home/*|/Users/*|/root) echo HOME; return ;; esac
    echo NONE
}

# _is_pure_glob <s>: nothing left after removing glob metacharacters.
_is_pure_glob() { local t="${1//[\*\?\[\]\{\},]/}"; [ -z "$t" ]; }

# lift_ref <word> [depth] -> LIFT | STATE | HIMMEL | HOME | NONE.
# LIFT = the word may name the lift file itself; the others name an ancestor
# directory a whole-directory write could put a lift into.
lift_ref() {
    local w="$1" depth="${2:-0}" e dir base dk tgt
    [ -n "$w" ] || { echo NONE; return; }
    e=$(_expand "$w")
    # Symlinks (also dangling ones — a link to a lift that does not exist yet).
    case "$e" in
        '?/'*) ;;
        *)
            if [ -e "$STATE_REAL/$LIFT_NAME" ] && [ -e "$e" ] && [ "$e" -ef "$STATE_REAL/$LIFT_NAME" ]; then
                echo LIFT; return
            fi
            if [ -L "$e" ] && [ "$depth" -lt 8 ]; then
                tgt=$(readlink "$e" 2>/dev/null) || tgt=""
                if [ -n "$tgt" ]; then
                    case "$tgt" in /*) ;; *) tgt="${e%/*}/$tgt" ;; esac
                    case "$(lift_ref "$tgt" $((depth+1)))" in LIFT) echo LIFT; return ;; esac
                fi
            fi
            ;;
    esac
    base="${e##*/}"; dir="${e%/*}"
    [ -n "$dir" ] || dir=/
    dk=$(_dir_kind "$dir")
    if [ -n "$base" ] && _name_matches "$base" "$LIFT_NAME"; then
        case "$dk" in
            STATE) echo LIFT; return ;;
            # Unknown dir: only a lift-NAMED word (not `$x`, not a bare `*`/`{}`).
            UNKNOWN) if ! _is_dynamic "$base" && ! _is_pure_glob "$base"; then echo LIFT; return; fi ;;
        esac
    fi
    # The word itself as a directory.
    dk=$(_dir_kind "$e")
    case "$dk" in STATE|HIMMEL|HOME) echo "$dk"; return ;; esac
    echo NONE
}

is_lift() { [ "$(lift_ref "$1")" = LIFT ]; }

# ------------------------------------------------------------ file tools ---
case "$tool" in
    Write|Edit|MultiEdit|NotebookEdit)
        p=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) \
            || deny "unreadable tool_input (fail-closed)"
        if [ -n "$p" ] && is_lift "$p"; then deny "$tool targets the bank lift ($p)"; fi
        exit 0
        ;;
    apply_patch)
        patch=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // ""' 2>/dev/null) \
            || deny "unreadable apply_patch payload (fail-closed)"
        while IFS= read -r ln; do
            ln="${ln%$'\r'}"
            case "$ln" in
                '*** Add File: '*) p="${ln#\*\*\* Add File: }" ;;
                '*** Update File: '*) p="${ln#\*\*\* Update File: }" ;;
                '*** Move to: '*) p="${ln#\*\*\* Move to: }" ;;
                *) continue ;;
            esac
            if is_lift "$p"; then deny "apply_patch targets the bank lift ($p)"; fi
        done <<EOF
$patch
EOF
        exit 0
        ;;
esac

# ------------------------------------------------------------------ Bash ---
CMD=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || deny "unreadable command (fail-closed)"
# CRLF text must not hide a target: strip CRs at the capture boundary.
CMD="${CMD//$'\r'/}"
[ -n "$CMD" ] || exit 0
# The tokenizer marks below start with the control byte \002, so no word of
# the command can spell one; the byte in the input itself is refused.
case "$CMD" in *$'\002'*) deny "the command carries a \\x02 control byte (tokenizer sentinel)" ;; esac

# Tokenizer: shell text -> one CLAUSE per output line, tokens joined by \037,
# a newline inside a token as \036. Quotes are removed (quoted metachars stay
# literal), $'..' is decoded, backslash escapes become literals, comments and
# line continuations drop. Redirects become the tokens \002W (write: > >> >|
# &> <>) and \002R (read: < <<<) before their target. $( ), backticks, ( ),
# <( ), >( ) open a nested depth whose clauses print as their own lines; the
# outer word carries a "$" so it reads as dynamic. Heredoc bodies print as a
# line "\002B\037<body>". A \002 decoded from $'..' prints a "\002X" line.
read -r -d '' TOKENIZER <<'AWK'
function hexv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function addc(c) { if (c == SB) forged = 1; tok = tok c }
function emit_tok() {
    if (tok != "" || quoted) { buf[d] = buf[d] (bn[d]++ ? US : "") tok }
    tok = ""; quoted = 0
}
function emit_mark(m) { emit_tok(); buf[d] = buf[d] (bn[d]++ ? US : "") m }
function flush(   l) {
    emit_tok()
    if (bn[d] > 0) { l = buf[d]; gsub(/\n/, NL, l); print l }
    buf[d] = ""; bn[d] = 0
}
function open_sub(t) {
    savetok[d] = tok "$"; d++; typ[d] = t; ret[d] = mode
    tok = ""; quoted = 0; buf[d] = ""; bn[d] = 0; mode = "o"
}
function close_sub(   m) {
    m = ret[d]; flush(); d--; mode = m; tok = savetok[d]; quoted = 1
}
function heredocs(   k, body, line, e, del, stripped) {
    for (k = 1; k <= nhd; k++) {
        body = ""; del = hd[k]
        while (i < n) {
            e = index(substr(s, i + 1), "\n")
            if (e == 0) { line = substr(s, i + 1); i = n } else { line = substr(s, i + 1, e - 1); i = i + e }
            stripped = line; sub(/^\t+/, "", stripped)
            if (stripped == del) break
            body = body (body == "" ? "" : "\n") line
        }
        if (!hdq[k]) subs(body)
        gsub(/\n/, NL, body); print SB "B" US body
    }
    nhd = 0
}
# An unquoted-delimiter heredoc body runs its $( ) and backtick commands:
# print each as "\002S\037<command>" (nesting counted on parens, quotes not).
function subs(b,   p, L, j, dep, x, inner, e) {
    L = length(b); p = 1
    while (p <= L) {
        x = substr(b, p, 1)
        if (x == "\\") { p += 2; continue }
        if (x == "$" && substr(b, p + 1, 1) == "(") {
            dep = 1; j = p + 2
            while (j <= L && dep > 0) {
                x = substr(b, j, 1)
                if (x == "\\") { j += 2; continue }
                if (x == "(") dep++; else if (x == ")") dep--
                j++
            }
            inner = dep > 0 ? substr(b, p + 2) : substr(b, p + 2, j - p - 3)
            gsub(/\n/, NL, inner); print SB "S" US inner
            p = j; continue
        }
        if (x == "`") {
            e = index(substr(b, p + 1), "`")
            if (e == 0) { inner = substr(b, p + 1); j = L + 1 } else { inner = substr(b, p + 1, e - 1); j = p + e + 1 }
            gsub(/\n/, NL, inner); print SB "S" US inner
            p = j; continue
        }
        p++
    }
}
{ s = (NR > 1 ? s "\n" : "") $0 }
END {
    US = "\037"; NL = "\036"; SB = "\002"; forged = 0
    n = length(s); d = 0; mode = "o"; tok = ""; quoted = 0; nhd = 0
    buf[0] = ""; bn[0] = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); c2 = substr(s, i + 1, 1)
        if (mode == "s") { if (c == "'") mode = "o"; else addc(c); continue }
        if (mode == "a") {
            if (c == "'") { mode = "o"; continue }
            if (c != "\\") { addc(c); continue }
            i++; c = substr(s, i, 1)
            if (c == "n") addc("\n"); else if (c == "t") addc("\t"); else if (c == "r") addc("\r")
            else if (c == "x") {
                v = 0; k = 0
                while (k < 2 && hexv(substr(s, i + 1, 1)) >= 0) { v = v * 16 + hexv(substr(s, i + 1, 1)); i++; k++ }
                addc(sprintf("%c", v))
            } else if (c == "u" || c == "U") {
                v = 0; k = 0
                while (k < (c == "u" ? 4 : 8) && hexv(substr(s, i + 1, 1)) >= 0) { v = v * 16 + hexv(substr(s, i + 1, 1)); i++; k++ }
                addc(v < 128 ? sprintf("%c", v) : "?")
            } else if (c ~ /[0-7]/) {
                v = c + 0; k = 1
                while (k < 3 && substr(s, i + 1, 1) ~ /[0-7]/) { v = v * 8 + substr(s, i + 1, 1); i++; k++ }
                addc(sprintf("%c", v))
            } else if (c == "c") { i++ }
            else if (c == "a" || c == "b" || c == "e" || c == "E" || c == "f" || c == "v") { }
            else addc(c)
            continue
        }
        if (mode == "q") {
            if (c == "\"") { mode = "o"; continue }
            if (c == "\\" && (c2 == "$" || c2 == "`" || c2 == "\"" || c2 == "\\")) { addc(c2); i++; continue }
            if (c == "\\" && c2 == "\n") { i++; continue }
            if (c == "$" && c2 == "(") { i++; open_sub("p"); continue }
            if (c == "`") { open_sub("b"); continue }
            addc(c); continue
        }
        # mode o
        if (c == " " || c == "\t") { emit_tok(); continue }
        if (c == "\n") { flush(); if (nhd > 0) heredocs(); continue }
        if (c == "\\") { if (c2 == "\n") { i++; continue } addc(c2); quoted = 1; i++; continue }
        if (c == "'") { mode = "s"; quoted = 1; continue }
        if (c == "\"") { mode = "q"; quoted = 1; continue }
        if (c == "$" && c2 == "'") { mode = "a"; quoted = 1; i++; continue }
        if (c == "$" && c2 == "(") { i++; open_sub("p"); continue }
        if (c == "`") { if (d > 0 && typ[d] == "b") close_sub(); else open_sub("b"); continue }
        if (c == "#" && tok == "" && !quoted) {
            while (i < n && substr(s, i + 1, 1) != "\n") i++
            continue
        }
        if (c == ")") { if (d > 0 && typ[d] == "p") close_sub(); else flush(); continue }
        if ((c == "<" || c == ">") && c2 == "(") { emit_tok(); i++; open_sub("p"); continue }
        if (c == "&" && c2 == ">") {
            emit_mark(SB "W"); i++
            if (substr(s, i + 1, 1) == ">") i++
            continue
        }
        if (c == ";" || c == "&" || c == "|" || c == "(") { flush(); continue }
        if (c == ">") {
            if (!quoted && tok ~ /^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})$/) tok = ""
            j = i + 1
            if (substr(s, j, 1) == ">") j++
            if (substr(s, j, 1) == "|") j++
            if (substr(s, j, 1) == "&") {
                j++
                if (substr(s, j, 1) ~ /[0-9-]/) {
                    while (substr(s, j, 1) ~ /[0-9-]/) j++
                    emit_tok(); i = j - 1; continue
                }
            }
            emit_mark(SB "W"); i = j - 1; continue
        }
        if (c == "<") {
            if (!quoted && tok ~ /^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})$/) tok = ""
            if (c2 == ">") { emit_mark(SB "W"); i++; continue }
            if (c2 == "&") {
                emit_tok(); i++
                while (substr(s, i + 1, 1) ~ /[0-9-]/) i++
                continue
            }
            if (c2 == "<" && substr(s, i + 2, 1) == "<") { emit_mark(SB "R"); i += 2; continue }
            if (c2 == "<") {
                emit_tok(); i++
                if (substr(s, i + 1, 1) == "-") i++
                while (substr(s, i + 1, 1) == " " || substr(s, i + 1, 1) == "\t") i++
                del = ""; dq = 0
                while (i < n) {
                    x = substr(s, i + 1, 1)
                    if (x ~ /[ \t\n;&|<>()]/) break
                    if (x != "'" && x != "\"" && x != "\\") del = del x; else dq = 1
                    i++
                }
                hd[++nhd] = del; hdq[nhd] = dq
                continue
            }
            emit_mark(SB "R"); continue
        }
        addc(c)
    }
    while (d > 0) { flush(); d-- }
    flush()
    if (forged) print SB "X"
}
AWK

# --------------------------------------------------------- clause checks ---
INTERP_RE='^(python[0-9.]*|pypy[0-9.]*|perl[0-9.]*|ruby[0-9.]*|node|nodejs|deno|bun|php[0-9.]*|lua[0-9.]*|luajit|[gmn]?awk|busybox-awk|osascript|pwsh|powershell|rscript|julia|tclsh|wish|jshell|groovy|scala|kotlin|swift)$'
SHELL_RE='^(bash|sh|zsh|dash|ksh|mksh|yash|ash|fish|rbash)$'
# Verbs that only read their operands (an xargs-appended word stays a read).
READ_RE='^(cat|jq|grep|egrep|fgrep|rg|head|tail|less|more|wc|stat|ls|file|diff|cmp|md5sum|sha1sum|sha256sum|readlink|realpath)$'
MENTION_RE='^(curl|wget|tar|bsdtar|unzip|cpio|7z|7za|7zr|ed|ex|vi|vim|nvim|view|nano|pico|emacs|emacsclient|mcedit|joe|micro|helix|hx|kak|ssh|scp|sftp|rclone|aria2c|gunzip|bunzip2|xz|unxz|zstd|unzstd|gzip|bzip2|split|csplit)$'

_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
_base() { local b="${1%/}"; printf '%s' "${b##*/}"; }

# check_lift_name <args...> — runs on every clause BEFORE the verb rules
# (console ruling, HIMMEL-4445 round 6): a word that contains the basename
# bank-lift.json, in a clause whose command is not an allowlisted reader,
# denies. Over-deny is accepted. The command word is resolved past
# keywords, assignments and simple env/sudo/timeout/nice-style wrappers;
# anything else counts as not a reader. Redirect targets are not in args:
# a write redirect onto the lift is denied by the redirect rule.
#
# Round 7: a word naming bank-lift.sh (as a path or word, not as part of a
# longer name like test-bank-lift.sh) triggers it too; that clause may also
# be `bash <path>/bank-lift.sh show|clear ...` or `<path>/bank-lift.sh
# show|clear ...`. A wrapper (env, sudo, nice, timeout, ...) that carries ANY
# option leaves the command word unknown: an option's argument (`env -u cat`)
# must not be read as the command.
check_lift_name() {
    local a l hit=0 w c ow
    for a in "$@"; do
        l=$(_lower "$a")
        case "$l" in *bank-lift.json*) hit=1; break ;; esac
        if [[ "$l" =~ (^|[^a-z0-9_.-])bank-lift\.sh($|[^a-z0-9_.-]) ]]; then hit=1; break; fi
    done
    [ "$hit" = 1 ] || return 0
    while [ $# -gt 0 ]; do
        w="$1"
        case "$w" in
            '{'|'}'|'!'|if|then|else|elif|do|while|until|fi|done|command|time) shift; continue ;;
        esac
        if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then shift; continue; fi
        c=$(_lower "$(_base "$w")")
        case "$c" in
            env|sudo|doas|nice|xargs|timeout|stdbuf|ionice|chrt|taskset|setsid|nohup)
                shift
                case "${1-}" in -*) c=""; break ;; esac
                if [ "$c" = env ]; then
                    while [ $# -gt 0 ]; do case "$1" in *=*) shift ;; *) break ;; esac; done
                elif [ "$c" = timeout ] && [ $# -gt 0 ]; then
                    shift
                fi
                continue ;;
        esac
        break
    done
    ow="${1-}"
    shift
    case "$c" in
        bash) if _name_matches "$(_base "${1-}")" bank-lift.sh; then
                  case "${2-}" in show|clear) return 0 ;; esac
              fi ;;
        bank-lift.sh) _is_dynamic "$ow" || case "${1-}" in show|clear) return 0 ;; esac ;;
    esac
    case "$c" in
        cat|less|head|stat|ls|file|wc|test|'[') return 0 ;;
        jq) for a in "$@"; do case "$a" in -i|--in-place*) deny "jq edits in place a word naming the bank lift ($a)" ;; esac; done; return 0 ;;
        tail) for a in "$@"; do case "$a" in --follow*) deny "tail follows the bank lift" ;; --*) ;; -*[fF]*) deny "tail follows the bank lift" ;; esac; done; return 0 ;;
        grep|rg) for a in "$@"; do case "$a" in --pre|--pre=*) deny "$c --pre runs a command on the bank lift" ;; esac; done; return 0 ;;
    esac
    deny "a word names the bank lift (bank-lift.json or bank-lift.sh) in a non-reader command (${c:-unknown}); only cat/less/head/tail/stat/ls/file/wc/test/jq/grep/rg and \`bash scripts/lib/bank-lift.sh show|clear\` may name it — for a commit message or ticket text that names it, use \`git commit -F <file>\` / a --desc-file"
}

# Inline interpreter code naming the lift FILE (bank-lift.json, split or
# globbed), $BANK_LIFT_FILE, bank-lift.sh, or its sourced _bank_lift_cmd.
LIFT_CODE_RE='bank[^a-z0-9]{0,4}l[a-z?*]{0,2}ft[^a-z0-9]{0,6}json|bank[-_.]?lift[-_.]?(file|sh)|_bank_lift_cmd'
# Matches "bank…lift" spelled close together (also a l?ft glob), not "bank"
# and "left" far apart in prose.
MENTION_NEAR_RE='bank[^a-z0-9]{0,4}l[a-z?*]{0,2}ft'
CUR_BODIES=""    # heredoc bodies of the text analyse() is walking
TEXT_MENTION=0   # set per analyse() call: dequoted text names bank + lift
HAS_XARGS=0

# set_rule <script-word> <first-subcommand-or-empty> <has-sub 0|1> <stdin-fed 0|1>
set_rule() {
    local script="$1" sub="$2" hassub="$3" scrb
    scrb=$(_base "$script")
    # An existing symlink (chain) to bank-lift.sh runs it under another name.
    if [ "$hassub" = 1 ] && ! _is_dynamic "$script"; then
        local e n=0 tgt
        e=$(_expand "$script")
        while [ "$n" -lt 8 ] && [ -L "$e" ]; do
            case "$e" in '?/'*) break ;; esac
            tgt=$(readlink "$e" 2>/dev/null) || break
            case "$tgt" in /*) e="$tgt" ;; *) e="${e%/*}/$tgt" ;; esac
            n=$((n+1))
        done
        [ "$n" -gt 0 ] && scrb=$(_base "$e")
    fi
    if [ "$scrb" = "_bank_lift_cmd" ] || { ! _is_dynamic "$scrb" && _name_matches "$scrb" bank-lift.sh; }; then
        if [ "$hassub" = 1 ]; then
            if _is_dynamic "$sub" || _name_matches "$sub" set; then deny "\`bank-lift.sh set\` is operator-only"; fi
        elif [ "$HAS_XARGS" = 1 ] || [ "$4" = 1 ]; then
            deny "\`bank-lift.sh\` with its subcommand fed from a pipe/xargs/stdin"
        fi
        return 0
    fi
    # A dynamic script/command word followed by `set`, in a command that
    # names bank-lift somewhere: `s=scripts/lib/bank-lift.sh; bash "$s" set`.
    if _is_dynamic "$script" && [ "$hassub" = 1 ] && [ "$TEXT_MENTION" = 1 ]; then
        if _is_dynamic "$sub" || _name_matches "$sub" set; then deny "a dynamic command word running \`set\` beside a bank-lift mention"; fi
    fi
    return 0
}

# check_copy <verb> <args...>: cp / mv / install / rsync / ln destination and
# aliasing rules.
check_copy() {
    local verb="$1"; shift
    local tdir="" T=0 sym=0 a v kind src srcb need dest dk endopts=0
    local -a pos=()
    while [ $# -gt 0 ]; do
        a="$1"; shift
        if [ "$endopts" = 1 ]; then pos+=("$a"); continue; fi
        case "$a" in
            --) endopts=1 ;;
            --target-directory=*|--targ*=*|--ta=*|--tar=*) tdir="${a#*=}" ;;
            --t|--ta|--tar|--targ*) tdir="${1:-}"; shift ;;
            --no-target-directory) T=1 ;;
            --no-dereference) [ "$verb" = ln ] && T=1 ;;
            --symbolic*|--link) sym=1 ;;
            --suffix|--mode|--owner|--group|--backup-dir|--rsh|--filter|--exclude|--include|--temp-dir|--partial-dir|--compare-dest|--copy-dest|--link-dest|--chmod|--chown) shift ;;
            --*) ;;
            -?*)
                v="${a#-}"
                while [ -n "$v" ]; do
                    case "$v" in
                        t*) if [ "$verb" = rsync ]; then v="${v#?}"; continue; fi
                            if [ -n "${v#t}" ]; then tdir="${v#t}"; else tdir="${1:-}"; shift; fi; v="" ;;
                        T*) if [ "$verb" = rsync ]; then shift; v=""; else T=1; v="${v#?}"; fi ;;
                        s*) case "$verb" in ln|cp) sym=1 ;; esac; v="${v#?}" ;;
                        l*) case "$verb" in cp) sym=1 ;; esac; v="${v#?}" ;;
                        n*) case "$verb" in ln) T=1 ;; esac; v="${v#?}" ;;
                        S*|m*|o*|g*|e*|f*|B*|M*)
                            case "$verb:${v%"${v#?}"}" in
                                cp:S|mv:S|ln:S|install:[Smog]|rsync:[efBM])
                                    if [ -z "${v#?}" ]; then shift; fi; v="" ;;
                                *) v="${v#?}" ;;
                            esac ;;
                        *) v="${v#?}" ;;
                    esac
                done
                ;;
            *) pos+=("$a") ;;
        esac
    done
    if [ -n "$tdir" ]; then
        dest="$tdir"
    elif [ "${#pos[@]}" -ge 2 ]; then
        dest="${pos[${#pos[@]}-1]}"
        unset "pos[${#pos[@]}-1]"
    else
        return 0
    fi
    [ "$verb" = ln ] && sym=1
    # A copy/link/rename of bank-lift.sh runs `set` under another name. Only
    # a source that spells "bank": a bare `*.sh` glob keeps every name, so
    # bank-lift.sh still matches by name wherever it lands.
    for src in ${pos[@]+"${pos[@]}"}; do
        srcb=$(_base "$src")
        case "$(_lower "$srcb")" in *bank*) ;; *) continue ;; esac
        if ! _is_dynamic "$srcb" && _name_matches "$srcb" bank-lift.sh; then
            deny "$verb makes an alias of bank-lift.sh ($src)"
        fi
    done
    # Aliasing: a link TO the lift or its directory lets a later write reach
    # it without naming it.
    if [ "$sym" = 1 ]; then
        for src in ${pos[@]+"${pos[@]}"}; do
            case "$(lift_ref "$src")" in LIFT|STATE) deny "$verb links to the bank lift or its directory ($src)" ;; esac
        done
    fi
    # After a cd the dir of a relative destination is unknown: a lift-named
    # source copied into a bare directory destination (`.`, `dir/`, -t) may
    # land as the lift.
    if [ "$HAS_CD" = 1 ]; then
        case "$dest" in /*|'~'*|'$'*) ;; *)
            case "$tdir:$dest" in ?*:*|*:.|*:..|*/|*/.|*/..)
                for src in ${pos[@]+"${pos[@]}"}; do
                    srcb=$(_base "$src")
                    if ! _is_dynamic "$srcb" && ! _is_pure_glob "$srcb" && _name_matches "$srcb" "$LIFT_NAME"; then
                        deny "$verb puts a lift-named file into $dest after a cd"
                    fi
                done ;;
            esac ;;
        esac
    fi
    dk=$(lift_ref "$dest")
    case "$dk" in
        LIFT) deny "$verb writes the bank lift ($dest)" ;;
        STATE) need="$LIFT_NAME" ;;
        HIMMEL) need=state ;;
        HOME) need=.himmel ;;
        *) return 0 ;;
    esac
    # Whole-directory write into an ancestor of the lift.
    if [ "$T" = 1 ] && [ -z "$tdir" ]; then deny "$verb -T replaces/fills $dest wholesale"; fi
    # A missing state dir is CREATED from a directory source (its lift inside
    # comes along); a source that is a literal existing regular file cannot do
    # that, so only an unknowable or directory source denies here.
    if [ "$dk" = STATE ] && [ -z "$tdir" ]; then
        kind=$(_expand "$dest")
        case "$kind" in
            '?/'*) ;;
            *) if [ ! -d "$kind" ]; then
                   for src in ${pos[@]+"${pos[@]}"}; do
                       v=$(_expand "$src")
                       case "$v" in '?/'*) deny "$verb would create the state dir ($dest) from a source" ;; esac
                       if [ -d "$v" ] || [ ! -f "$v" ]; then deny "$verb would create the state dir ($dest) from a source" ; fi  # fail-open-ok: a file-TYPE test, the file is never read
                   done
               fi ;;
        esac
    fi
    for src in ${pos[@]+"${pos[@]}"}; do
        case "$src" in
            */|*/.) deny "$verb copies a directory's contents into $dest" ;;
        esac
        srcb=$(_base "$src")
        if _name_matches "$srcb" "$need"; then deny "$verb puts a \`$need\`-named (or unknowable) entry into $dest"; fi
    done
    return 0
}

SED_E_RE='(^|[[:space:];{}!/0-9$])e([[:space:]]|$)'
# check_sed_scripts <sed-args...>: a sed SCRIPT writes with w/W (also the
# s///w flag) and runs commands with e (also s///e). The script is each -e /
# --expression value, else the first operand; -f files are not read.
check_sed_scripts() {
    local -a scripts=() ops=()
    local a nx="" have=0 rest ch line p cand low
    for a in "$@"; do
        case "$nx" in
            e) scripts+=("$a"); nx=""; continue ;;
            skip) nx=""; continue ;;
        esac
        case "$a" in
            --expression=*) scripts+=("${a#*=}"); have=1 ;;
            --expression) nx=e; have=1 ;;
            --file=*) have=1 ;;
            --file) nx=skip; have=1 ;;
            --line-length) nx=skip ;;
            --*|-) ;;
            -*)
                rest="${a#-}"
                while [ -n "$rest" ]; do
                    ch="${rest:0:1}"; rest="${rest:1}"
                    case "$ch" in
                        e) have=1; if [ -n "$rest" ]; then scripts+=("$rest"); else nx=e; fi; break ;;
                        f) have=1; [ -n "$rest" ] || nx=skip; break ;;
                        l) [ -n "$rest" ] || nx=skip; break ;;
                        i) break ;;
                    esac
                done ;;
            *) ops+=("$a") ;;
        esac
    done
    [ "$have" = 1 ] || [ "${#ops[@]}" -eq 0 ] || scripts+=("${ops[0]}")
    for a in ${scripts[@]+"${scripts[@]}"}; do
        low=$(_lower "$a")
        if [[ "$low" =~ $LIFT_CODE_RE ]] && [[ "$a" =~ $SED_E_RE ]]; then
            deny "a sed e command names the bank lift"
        fi
        while IFS= read -r line; do
            p="$line"
            while [ -n "$p" ]; do
                case "$p" in *[wW]*) ;; *) break ;; esac
                p="${p#*[wW]}"
                cand="${p#"${p%%[![:space:]]*}"}"
                [ -n "$cand" ] || continue
                is_lift "$cand" && deny "a sed w/W command writes the bank lift ($cand)"
            done
        done <<EOF
$a
EOF
    done
    return 0
}

# analyse <command-text> <depth>
analyse() {
    local text="$1" depth="$2" out line
    if [ "$depth" -gt 4 ]; then
        [ "$TEXT_MENTION" = 1 ] && deny "command nests too deep to inspect and names bank-lift"
        return 0
    fi
    out=$(printf '%s' "$text" | awk "$TOKENIZER") || deny "command tokenizer failed (fail-closed)"
    local low
    low=$(_lower "$out")
    low="${low//\\/}"
    case "$low" in *bank*lift*|*lift*bank*) TEXT_MENTION=1 ;; esac
    [[ "$low" =~ $MENTION_NEAR_RE ]] && TEXT_MENTION=1
    case "$low" in *xargs*) HAS_XARGS=1 ;; esac
    local stdin_shell=0 bodies=""
    local CUR_BODIES=""
    while IFS= read -r line; do
        case "$line" in $'\002B\037'*) CUR_BODIES="$CUR_BODIES${line#$'\002B\037'}"$'\n' ;; esac
    done <<EOF
$out
EOF
    CUR_BODIES="${CUR_BODIES//$'\036'/$'\n'}"
    # Pass 1: clauses.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            $'\002X') deny "the command decodes a \\x02 control byte (tokenizer sentinel)" ;;
            $'\002B\037'*) bodies="$bodies${line#$'\002B\037'}"$'\n'; continue ;;
            $'\002S\037'*) line="${line#$'\002S\037'}"; analyse "${line//$'\036'/$'\n'}" $((depth+1)); continue ;;
        esac
        local -a tk=() args=()
        IFS=$'\037' read -r -a tk <<<"$line"
        local i=0 t nt=${#tk[@]} fed=0
        # Redirect targets; build args without them.
        while [ "$i" -lt "$nt" ]; do
            t="${tk[$i]//$'\036'/$'\n'}"
            case "$t" in
                $'\002W')
                    i=$((i+1)); t="${tk[$i]:-}"
                    if [ -n "$t" ] && is_lift "$t"; then deny "a redirect writes the bank lift ($t)"; fi
                    ;;
                $'\002R')
                    i=$((i+1)); fed=1
                    t="${tk[$i]:-}"
                    case "$(_base "$t")" in *bank*) _name_matches "$(_base "$t")" bank-lift.sh && fed=2 ;; esac
                    ;;
                *) args+=("$t") ;;
            esac
            i=$((i+1))
        done
        [ "${#args[@]}" -gt 0 ] || continue
        check_lift_name "${args[@]}"
        check_clause "$depth" "$fed" "${args[@]}"
        case "$?" in 10) stdin_shell=1 ;; esac
    done <<EOF
$out
EOF
    if [ -n "$bodies" ] && [ "$stdin_shell" = 1 ]; then
        analyse "${bodies//$'\036'/$'\n'}" $((depth+1))
    fi
    return 0
}

# check_clause <depth> <fed> <args...> — returns 10 when the clause is a shell
# reading its script from stdin (heredoc bodies then get analysed), 11 for an
# interpreter (already decided here).
check_clause() {
    local depth="$1" fed="$2"; shift 2
    local w cmd a v rc=0
    # Command-position walk: keywords, assignments, wrappers.
    while [ $# -gt 0 ]; do
        w="$1"
        case "$w" in
            '{'|'}'|'!'|if|then|else|elif|do|while|until|fi|done|coproc|builtin|nohup|setsid|unbuffer|caffeinate)
                shift; continue ;;
        esac
        if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then
            # NAME=value assignment: a value naming the lift with no command
            # is a parameter, not a write — but test it for the set path below.
            shift; continue
        fi
        cmd=$(_lower "$(_base "$w")")
        case "$cmd" in
            env)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -S|--split-string) analyse "${2:-}" $((depth+1)); shift 2 || shift ;;
                        -S*) analyse "${1#-S}" $((depth+1)); shift ;;
                        --split-string=*) analyse "${1#*=}" $((depth+1)); shift ;;
                        -u|-C|--unset|--chdir) shift 2 || shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *=*) shift ;;
                        *) break ;;
                    esac
                done
                continue ;;
            sudo|doas|run0)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -u|-g|-C|-D|-h|-p|-r|-t|-U|-T|--user|--group|--chdir|--host|--prompt|--role|--type|--other-user|--command-timeout) shift 2 || shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *) break ;;
                    esac
                done
                continue ;;
            timeout)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -s|-k|--signal|--kill-after) shift 2 || shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *) shift; break ;;   # the duration
                    esac
                done
                continue ;;
            nice|ionice|stdbuf|chrt|taskset|command|exec|flock|watch|script|su|xargs|parallel|time)
                shift
                case "$cmd" in
                    command)
                        case "${1:-}" in -v|-V) return 0 ;; esac
                        while [ $# -gt 0 ]; do case "$1" in -p|--) shift ;; *) break ;; esac; done ;;
                    exec)
                        while [ $# -gt 0 ]; do case "$1" in -a) shift 2 || shift ;; -c|-l|-cl|-lc|--) shift ;; *) break ;; esac; done ;;
                    nice|ionice)
                        while [ $# -gt 0 ]; do
                            case "$1" in -n|-c|-p|-t|--adjustment|--class|--classdata) shift 2 || shift ;; --) shift; break ;; -*) shift ;; *) break ;; esac
                        done ;;
                    stdbuf)
                        while [ $# -gt 0 ]; do
                            case "$1" in -i|-o|-e) shift 2 || shift ;; --) shift; break ;; -*) shift ;; *) break ;; esac
                        done ;;
                    chrt|taskset)
                        while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) shift; break ;; esac; done ;;
                    flock)
                        while [ $# -gt 0 ]; do
                            case "$1" in -w|-E|--timeout|--conflict-exit-code) shift 2 || shift ;; -c|--command) analyse "${2:-}" $((depth+1)); return 0 ;; -*) shift ;; *) shift; break ;; esac
                        done
                        case "${1:-}" in -c|--command) analyse "${2:-}" $((depth+1)); return 0 ;; esac ;;
                    watch)
                        while [ $# -gt 0 ]; do case "$1" in -n|-d|--interval) shift 2 || shift ;; -*) shift ;; *) break ;; esac; done
                        analyse "$*" $((depth+1)); return 0 ;;
                    script|su)
                        while [ $# -gt 0 ]; do
                            case "$1" in -c|--command) analyse "${2:-}" $((depth+1)); return 0 ;; -s|-T|--shell|--timing) shift 2 || shift ;; *) shift ;; esac
                        done
                        return 0 ;;
                    xargs|parallel)
                        HAS_XARGS=1
                        while [ $# -gt 0 ]; do
                            case "$1" in
                                -I|-E|-L|-n|-P|-s|-d|-a|--arg-file|--delimiter|--max-args|--max-procs|--max-lines|--max-chars|--replace|--eof) shift 2 || shift ;;
                                --) shift; break ;;
                                -*) shift ;;
                                *) break ;;
                            esac
                        done ;;
                    time)
                        while [ $# -gt 0 ]; do case "$1" in -f|-o|--format|--output) shift 2 || shift ;; -*) shift ;; *) break ;; esac; done ;;
                esac
                continue ;;
            eval)
                shift
                if _is_dynamic "$*" && [ "$TEXT_MENTION" = 1 ]; then
                    deny "eval runs computed text beside a bank-lift mention"
                fi
                analyse "$*" $((depth+1)); return 0 ;;
        esac
        break
    done
    [ $# -gt 0 ] || return 0
    w="$1"; shift
    cmd=$(_lower "$(_base "$w")")

    # xargs anywhere in the command: any word naming the lift or the state
    # dir is a write the hook cannot follow — unless the verb only reads its
    # operands, so appended words stay read operands too.
    if [ "$HAS_XARGS" = 1 ] && ! [[ "$cmd" =~ $READ_RE ]]; then
        for a in "$w" "$@"; do
            case "$(lift_ref "$a")" in LIFT|STATE) deny "xargs feeds a command a bank-lift path ($a)" ;; esac
        done
    fi

    # Generic output-file options (-o / -O / --output[=] / --output-document).
    local prev=""
    for a in "$@"; do
        case "$prev" in
            -o|-O|--output|--output-document|--out-file|--outfile)
                is_lift "$a" && deny "$cmd $prev writes the bank lift ($a)" ;;
        esac
        case "$a" in
            --output=*|--output-document=*|--out-file=*|--outfile=*)
                is_lift "${a#*=}" && deny "$cmd writes the bank lift (${a#*=})" ;;
        esac
        prev="$a"
    done

    # Shells.
    if [[ "$cmd" =~ $SHELL_RE ]] || [ "$cmd" = busybox ]; then
        local bbsh=0   # busybox's own sh applet (cmd stays "busybox")
        if [ "$cmd" = busybox ]; then
            case "${1:-}" in sh|ash|bash) shift; bbsh=1 ;; *) w="${1:-}"; [ $# -gt 0 ] && shift; cmd=$(_lower "$(_base "$w")") ;; esac
        fi
        if [[ "$cmd" =~ $SHELL_RE ]] || [ "$bbsh" = 1 ]; then
            local cflag=0 sflag=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    --) shift; break ;;
                    -o|+o|-O|+O|--rcfile|--init-file) shift 2 || shift ;;
                    --*) shift ;;
                    [-+]*)
                        case "$1" in *c*) cflag=1 ;; esac
                        case "$1" in *s*) sflag=1 ;; esac
                        shift ;;
                    *) break ;;
                esac
            done
            if [ "$cflag" = 1 ]; then
                # A computed body (sh -c "$(printf …)") cannot be read here.
                if _is_dynamic "${1:-}" && [ "$TEXT_MENTION" = 1 ]; then
                    deny "a shell runs a computed -c body beside a bank-lift mention"
                fi
                analyse "${1:-}" $((depth+1)); return 0
            fi
            if [ "$sflag" = 1 ] || [ $# -eq 0 ] || [ "${1:-}" = - ] || [ "${1:-}" = /dev/stdin ]; then
                [ "$sflag" = 1 ] || { [ $# -gt 0 ] && shift; }
                if [ "$fed" = 2 ] && [ $# -gt 0 ]; then set_rule bank-lift.sh "$1" 1 1; fi
                if [ $# -gt 0 ] && [ "$TEXT_MENTION" = 1 ] && _name_matches "$1" set; then
                    deny "a shell reading its script from stdin runs \`set\` beside a bank-lift mention"
                fi
                return 10
            fi
            w="$1"; shift
            set_rule "$w" "${1:-}" $(( $# > 0 ? 1 : 0 )) "$( [ "$fed" = 0 ] && echo 0 || echo 1 )"
            return 0
        fi
    fi
    case "$cmd" in
        source|.)
            [ $# -gt 0 ] || return 0
            w="$1"; shift
            set_rule "$w" "${1:-}" $(( $# > 0 ? 1 : 0 )) 0
            return 0 ;;
    esac

    # Interpreters: their code is text the hook cannot parse. Any argument that
    # IS the lift (or its dir) denies. INLINE code (-c/-e/…, an awk program, or
    # a script read from stdin/heredoc) also denies when it names the lift FILE
    # or bank-lift.sh. A script FILE's other arguments are data — a ticket title
    # that merely mentions bank-lift is not code.
    if [[ "$cmd" =~ $INTERP_RE ]]; then
        local inline=0 code="" seen=0 iscode=0
        case "$cmd" in *awk) inline=1 ;; esac
        for a in "$@"; do
            # The code word itself (after -c/-e, or awk's program) is not a path.
            if [ "$iscode" = 0 ] && ! { [ "$seen" = 0 ] && [[ "$cmd" == *awk ]] && [[ "$a" != -* ]]; }; then
                case "$(lift_ref "$a")" in LIFT|STATE) deny "an interpreter ($cmd) is handed the bank lift path ($a)" ;; esac
            fi
            iscode=0
            case "$a" in
                -c|-e|-E|-p|-r|--eval|--print|--command|-command|-Command|-[a-zA-Z]e|-[a-zA-Z]c) inline=1; iscode=1 ;;
                -f|--file) [ "$seen" = 0 ] && inline=0 ;;
                -) [ "$seen" = 0 ] && inline=1 ;;
                -*) ;;
                *) [ "$seen" = 0 ] && case "$cmd" in *awk) ;; *) case "$a" in /dev/stdin|/proc/self/fd/0) inline=1 ;; esac ;; esac
                   seen=1 ;;
            esac
        done
        [ "$seen" = 0 ] && inline=1
        if [ "$inline" = 1 ]; then
            code=$(_lower "$* $CUR_BODIES")
            code="${code//\\/}"
            if [[ "$code" =~ $LIFT_CODE_RE ]]; then
                deny "an interpreter ($cmd) runs inline code naming the bank lift"
            fi
        fi
        return 11
    fi

    case "$cmd" in
        tee|sponge|touch|truncate|patch|ex|ed)
            for a in "$@"; do
                case "$a" in -*) continue ;; esac
                is_lift "$a" && deny "$cmd writes the bank lift ($a)"
            done ;;
        sed|gsed)
            local inplace=0
            for a in "$@"; do
                case "$a" in --in-place*) inplace=1 ;; --*) ;; -*i*) inplace=1 ;; esac
            done
            if [ "$inplace" = 1 ]; then
                for a in "$@"; do
                    case "$a" in -*) continue ;; esac
                    is_lift "$a" && deny "sed -i edits the bank lift ($a)"
                done
            fi
            check_sed_scripts "$@" ;;
        dd)
            for a in "$@"; do
                case "$a" in of=*) is_lift "${a#of=}" && deny "dd of= writes the bank lift (${a#of=})" ;; esac
            done ;;
        cp|mv|install|ln|rsync|gcp|gmv|gln|ginstall)
            check_copy "${cmd#g}" "$@" ;;
        find|gfind)
            local acts=0
            for a in "$@"; do case "$a" in -exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) acts=1 ;; esac; done
            if [ "$acts" = 1 ]; then
                for a in "$@"; do
                    case "$(lift_ref "$a")" in LIFT|STATE) deny "find runs actions over a bank-lift path ($a)" ;; esac
                done
                # -exec/-execdir/-ok/-okdir launch a command: check it as a clause.
                local -a fx=()
                local inx=0
                for a in "$@"; do
                    if [ "$inx" = 1 ]; then
                        case "$a" in
                            ';'|'+') [ "${#fx[@]}" -gt 0 ] && check_clause "$depth" 0 "${fx[@]}"; fx=(); inx=0 ;;
                            *) fx+=("$a") ;;
                        esac
                        continue
                    fi
                    case "$a" in -exec|-execdir|-ok|-okdir) inx=1 ;; esac
                done
                [ "${#fx[@]}" -gt 0 ] && check_clause "$depth" 0 "${fx[@]}"
            fi ;;
        *)
            if [[ "$cmd" =~ $MENTION_RE ]]; then
                for a in "$@"; do
                    case "$a" in -*=*) a="${a#*=}" ;; esac
                    case "$(lift_ref "$a")" in LIFT|STATE) deny "$cmd is handed a bank-lift path ($a)" ;; esac
                done
            fi
            set_rule "$w" "${1:-}" $(( $# > 0 ? 1 : 0 )) "$( [ "$fed" = 0 ] && echo 0 || echo 1 )" ;;
    esac
    return 0
}

# A cd anywhere in the command makes relative paths' directory unknown.
case "$CMD" in *cd*|*pushd*|*popd*)
    # grep -c reads all input: a -q early exit would SIGPIPE printf on a big
    # command and, under pipefail, read a found cd as none.
    cd_hits=$(printf '%s' "$CMD" | grep -Ec '(^|[^A-Za-z0-9_.-])(cd|pushd|popd)([^A-Za-z0-9_.-]|$)')
    case "$cd_hits" in ''|0) ;; *) HAS_CD=1 ;; esac ;;
esac
analyse "$CMD" 0
exit 0
