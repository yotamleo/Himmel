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
# Judge J1874: that check runs on the WHOLE command first — once the text
# names either file anywhere, every clause at every depth ($( ), backticks,
# pipelines, heredoc substitutions) must be such a reader and no redirect may
# write past /dev/null, so a reader cannot hand the path to a writer.
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
# ponytail: text-level fence — it cannot see Write-tool CONTENT that is itself
# a script writing the lift, a script FILE that writes the lift without being
# handed its path, inline interpreter code that never spells the name (even
# split into "bank"+"-lift" pieces, HIMMEL-4458), variable indirection that
# never mentions bank-lift, or a bind mount. Those are bounded at RUNTIME, not
# here: bank-preflight honours only an account-bound lift capped by the
# seven_day resets_at and fails closed on anything else (HIMMEL-4423, judge
# J1855b), so a forged lift buys at most the rest of one window; upgrade path
# is an operator-owned lift the gate verifies, filed when one is seen in a
# transcript.
# ponytail: bank-lift.sh show|clear is trusted as the repo's
# scripts/lib/bank-lift.sh of this checkout or one of its .claude/worktrees
# (HIMMEL-4458), so an edited or planted copy inside a worktree passes; a
# pure-glob source under a computed destination (cp --parents * "$d") is not
# judged as the lift; upgrade path is the operator-owned lift above.
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
CD_HOME=0  # set for Bash: a cd/pushd/popd that may land in HOME, ~/.himmel or its state dir
CD_SEEN=0  # set for Bash once a cd/pushd/popd clause has been walked
CD_UNK=0   # set for Bash: a cd/pushd/popd whose target cannot be resolved
CD_DIR=""  # set for Bash: the last resolved cd/pushd target ("" when unresolved)
CWD_UNPROVEN=0  # set for Bash: a cd/eval leaves the cwd not provably known
# HIMMEL-4458: the repo whose scripts/lib/bank-lift.sh may run show|clear —
# this hook's own checkout (scripts/hooks/..), the primary when that is a
# .claude/worktrees/* worktree. Its worktrees qualify too.
case "$0" in */*) LIFT_REPO="${0%/*}" ;; *) LIFT_REPO=. ;; esac
LIFT_REPO=$(CDPATH='' cd -P -- "$LIFT_REPO/../.." 2>/dev/null && pwd -P) || LIFT_REPO=""
LIFT_REPO="${LIFT_REPO%%/.claude/worktrees/*}"

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
    case "$c" in *"{"*) c=$(_glob_from_word "$c") ;; esac
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
# With -v STRICT=1 (the whole-command layer only) a parse it cannot trust —
# an unclosed quote or substitution, a heredoc delimiter whose quote does
# not close on its line — also prints a "\002U" line. A quoted delimiter is
# read as one word, spaces included (HIMMEL-4458).
read -r -d '' TOKENIZER <<'AWK'
function hexv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function addc(c) { if (c == SB) forged = 1; tok = tok c }
function emit_tok() {
    if (!quoted && tok == "{") gd[d]++
    if (!quoted && tok == "}" && gd[d] > 0) gd[d]--
    if (tok != "" || quoted) { buf[d] = buf[d] (bn[d]++ ? US : "") tok }
    tok = ""; quoted = 0
}
function emit_mark(m) { emit_tok(); buf[d] = buf[d] (bn[d]++ ? US : "") m }
function flush(   l) {
    emit_tok()
    # A clause inside ( ) or { } is marked P (non-strict pass only).
    if (!STRICT && bn[d] > 0 && gd[d] + pd[d] > 0) buf[d] = buf[d] US SB "P"
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
        if (c == ")") { if (d > 0 && typ[d] == "p") close_sub(); else { flush(); if (pd[d] > 0) pd[d]-- }; continue }
        if ((c == "<" || c == ">") && c2 == "(") { emit_tok(); i++; open_sub("p"); continue }
        if (c == "&" && c2 == ">") {
            emit_mark(SB "W"); i++
            if (substr(s, i + 1, 1) == ">") i++
            continue
        }
        # && ends a clause whose cd (if any) runs the next only on success.
        if (c == "&" && c2 == "&" && !STRICT) { emit_mark(SB "A"); flush(); i++; continue }
        if (c == "(") { flush(); pd[d]++; continue }
        # A clause ended by | or & (also the first half of ||) is marked O.
        if ((c == "&" || c == "|") && !STRICT) { emit_tok(); if (bn[d] > 0) emit_mark(SB "O"); flush(); continue }
        if (c == ";" || c == "&" || c == "|") { flush(); continue }
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
                del = ""; dq = 0; inq = ""
                # HIMMEL-4458: the delimiter is one shell word — quoted parts
                # keep spaces and the other quote char, `\` escapes as bash's.
                while (i < n) {
                    x = substr(s, i + 1, 1)
                    if (x == "\n") break
                    if (inq == "'") { if (x == "'") inq = ""; else del = del x; i++; continue }
                    if (inq == "\"") {
                        if (x == "\"") { inq = ""; i++; continue }
                        if (x == "\\" && substr(s, i + 2, 1) ~ /[$`"\\]/) { del = del substr(s, i + 2, 1); i += 2; continue }
                        del = del x; i++; continue
                    }
                    if (x ~ /[ \t;&|<>()]/) break
                    if (x == "'" || x == "\"") { inq = x; dq = 1; i++; continue }
                    if (x == "\\") { dq = 1; if (substr(s, i + 2, 1) != "\n") del = del substr(s, i + 2, 1); i += 2; continue }
                    del = del x; i++
                }
                if (inq != "") hdbad = 1
                hd[++nhd] = del; hdq[nhd] = dq
                continue
            }
            emit_mark(SB "R"); continue
        }
        addc(c)
    }
    if (STRICT && (hdbad || mode != "o" || d > 0)) print SB "U"
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
# _lb <word>: R = the lowercased basename, forking only for an uppercase
# letter (HIMMEL-4458: per-clause forks made a long command's check slow).
_lb() { R="${1%/}"; R="${R##*/}"; case "$R" in *[A-Z]*) R=$(_lower "$R") ;; esac; }

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
#
# HIMMEL-4458 (latency): the words are joined by a space and lowered ONCE —
# neither pattern holds a space, so a match still lies inside one word — and
# a clause with no "bank" at all returns before any fork.
check_lift_name() {
    local IFS=' ' l j
    j="$*"; IFS=$' \t\n'
    case "$j" in *[bB][aA][nN][kK]*) ;; *) return 0 ;; esac
    l=$(_lower "$j")
    case "$l" in
        *bank-lift.json*) ;;
        *) [[ "$l" =~ (^|[^a-z0-9_.-])bank-lift\.sh($|[^a-z0-9_.-]) ]] || return 0 ;;
    esac
    reader_clause 0 "$@" && return 0
    deny "a word names the bank lift (bank-lift.json or bank-lift.sh) in a non-reader command (${READER_CMD:-unknown}); only cat/less/head/tail/stat/ls/file/wc/test/jq/grep/rg and \`bash scripts/lib/bank-lift.sh show|clear\` may name it — for a commit message or ticket text that names it, use \`git commit -F <file>\` / a --desc-file"
}

# Variables a reader (or the loader / the shell's command lookup) obeys: an
# assignment to one turns a reader into a command runner (LESSOPEN='|cp …',
# RIPGREP_CONFIG_PATH with --pre, LD_PRELOAD, PATH).
_reader_env_unsafe() {
    local n="${1%%=*}"
    case "${n%+}" in LESS*|RIPGREP_*|GREP_*|LD_*|DYLD_*|PATH|BASH_ENV|ENV) return 0 ;; esac
    return 1
}

# _sys_word <word> -> 0 when a command word is bare (no `/`, found on PATH)
# or exactly /usr/bin/<name> or /bin/<name>; any other path is not trusted.
_sys_word() {
    [[ "$1" != */* || "$1" =~ ^/(usr/)?bin/[^/]+$ ]]
}

# _repo_lift_script <word> -> 0 when the word is THE repo's bank-lift.sh
# (HIMMEL-4458; a basename match let a planted /tmp/x/bank-lift.sh run as
# `show`): scripts/lib/bank-lift.sh or ./scripts/lib/bank-lift.sh from a cwd
# that is LIFT_REPO or one of its .claude/worktrees/* (no cd in the command),
# or an absolute / ~ / $HOME path whose checkout dir resolves, physically, to
# one of those; the script itself must be a regular file (no symlink) whose
# dir resolves physically to that checkout's scripts/lib.
# shellcheck disable=SC2088,SC2016  # literal ~ / $HOME spellings are matched as text
_repo_lift_script() {
    local w="$1" p d
    [ -n "$LIFT_REPO" ] || return 1
    case "$w" in
        scripts/lib/bank-lift.sh|./scripts/lib/bank-lift.sh)
            [ "$HAS_CD" = 0 ] || return 1
            p="$CWD/$w" ;;
        /*) p="$w" ;;
        '~/'*|'$HOME/'*|'${HOME}/'*) p=$(_expand "$w") ;;
        *) return 1 ;;
    esac
    _is_dynamic "$p" && return 1
    case "$p" in */scripts/lib/bank-lift.sh) ;; *) return 1 ;; esac
    d=$(CDPATH='' cd -P -- "${p%/scripts/lib/bank-lift.sh}" 2>/dev/null && pwd -P) || return 1
    # The script itself, every component: a symlinked scripts/lib or
    # bank-lift.sh can point out of the checkout (panel r3).
    [ -f "$p" ] && [ ! -L "$p" ] || return 1
    [ "$(CDPATH='' cd -P -- "${p%/bank-lift.sh}" 2>/dev/null && pwd -P)" = "$d/scripts/lib" ] || return 1
    [ "$d" = "$LIFT_REPO" ] && return 0
    case "$d" in
        "$LIFT_REPO"/.claude/worktrees/*/*) return 1 ;;
        "$LIFT_REPO"/.claude/worktrees/?*) return 0 ;;
    esac
    return 1
}

# reader_clause <strict 0|1> <args...> -> 0 when the clause's command is an
# allowlisted reader or `bash <repo>/scripts/lib/bank-lift.sh show|clear`
# (also direct; the script word must pass _repo_lift_script), 1 otherwise;
# READER_CMD names the resolved command word. A reader carrying
# a write/exec option denies here. The command word is resolved past
# keywords, assignments and option-less env/sudo/timeout-style wrappers.
# strict=1 (the whole-command layer): xargs is not a wrapper, an assignment
# to a _reader_env_unsafe variable is not a reader, and a clause with no
# command word left passes.
READER_CMD=""
reader_clause() {
    local strict="$1"; shift
    local a w c="" ow
    while [ $# -gt 0 ]; do
        w="$1"
        case "$w" in
            '{'|'}'|'!'|if|then|else|elif|do|while|until|fi|done|command|time) shift; continue ;;
        esac
        if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then
            if [ "$strict" = 1 ] && _reader_env_unsafe "$w"; then READER_CMD="$w"; return 1; fi
            shift; continue
        fi
        _lb "$w"; c=$R
        # codex-1: a path-qualified reader, wrapper or bash (`/tmp/cat`,
        # `./env`) is whatever was planted there, not the system tool.
        if [ "$c" != bank-lift.sh ] && ! _sys_word "$w"; then READER_CMD="$w"; return 1; fi
        case "$c" in
            env|sudo|doas|nice|xargs|timeout|stdbuf|ionice|chrt|taskset|setsid|nohup)
                if [ "$strict" = 1 ] && [ "$c" = xargs ]; then READER_CMD="xargs"; return 1; fi
                shift
                case "${1-}" in -*) c=""; break ;; esac
                if [ "$c" = env ]; then
                    while [ $# -gt 0 ]; do
                        case "$1" in
                            *=*) if [ "$strict" = 1 ] && _reader_env_unsafe "$1"; then READER_CMD="$1"; return 1; fi
                                 shift ;;
                            *) break ;;
                        esac
                    done
                elif [ "$c" = timeout ] && [ $# -gt 0 ]; then
                    shift
                fi
                continue ;;
        esac
        break
    done
    READER_CMD="$c"
    if [ "$strict" = 1 ] && [ $# -eq 0 ]; then return 0; fi
    ow="${1-}"
    shift
    case "$c" in
        bash) if _repo_lift_script "${1-}"; then
                  case "${2-}" in show|clear) return 0 ;; esac
              fi ;;
        bank-lift.sh) if _repo_lift_script "$ow"; then
                          case "${1-}" in show|clear) return 0 ;; esac
                      fi ;;
    esac
    case "$c" in
        cat|head|stat|ls|file|wc|test|'[') return 0 ;;
        less) for a in "$@"; do
                  case "$a" in
                      --[lL][oO][gG]*) deny "less --log-file writes a file beside a bank-lift mention ($a)" ;;
                      --*) ;;
                      -*[oO]*|+*) deny "less $a writes a log file or runs a command beside a bank-lift mention" ;;
                  esac
              done; return 0 ;;
        jq) for a in "$@"; do case "$a" in -i|--in-place*) deny "jq edits in place a word naming the bank lift ($a)" ;; esac; done; return 0 ;;
        tail) for a in "$@"; do case "$a" in --follow*) deny "tail follows the bank lift" ;; --*) ;; -*[fF]*) deny "tail follows the bank lift" ;; esac; done; return 0 ;;
        grep|rg) for a in "$@"; do case "$a" in --pre|--pre=*) deny "$c --pre runs a command on the bank lift" ;; esac; done; return 0 ;;
    esac
    return 1
}

# --------------------------------------------------- whole-command layer ---
# Judge J1874 (console ruling): a per-clause name rule misses a reader that
# HANDS the lift path to a writer — `cp x $(jq -rn '"…/bank-lift.json"')`,
# `echo > "$(ls <lift>)"`, `ls <lift> | xargs cp x`. So, as the FIRST layer:
# when the command text names bank-lift.json / bank-lift.sh anywhere ($( ),
# backticks, heredoc bodies, pipelines; not a longer name such as
# test-bank-lift.sh), every clause at every depth must pass reader_clause
# strictly, and no redirect may write anything but /dev/null (fd dups are
# fine). Anything else, or a parse the tokenizer flags as untrustworthy,
# denies. The per-clause layers below still run on what passes.
# ponytail: a lift name obfuscated INSIDE a substitution (glob, brace, a
# split across words) does not trigger this layer, so a reader can still
# hand such a path to a writer; upgrade path is the operator-owned lift
# named in the header ponytail, filed when seen in a transcript.
# HIMMEL-4458: the bank-lift.sh script word (direct, or bash's operand) is
# trusted only as the repo's own scripts/lib/bank-lift.sh (_repo_lift_script),
# so a planted `/tmp/x/bank-lift.sh show` denies.
names_lift() {
    local l
    l=$(_lower "$1"); l="${l//\\/}"
    case "$l" in *bank-lift.json*) return 0 ;; esac
    [[ "$l" =~ (^|[^a-z0-9_.-])bank-lift\.sh($|[^a-z0-9_.-]) ]]
}

# whole_command_gate <command-text> <depth>
whole_command_gate() {
    local text="$1" depth="$2" out line t i nt
    [ "$depth" -le 4 ] || deny "a command naming the bank lift nests too deep to inspect"
    out=$(printf '%s' "$text" | awk -v STRICT=1 "$TOKENIZER") || deny "command tokenizer failed (fail-closed)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            $'\002X') deny "the command decodes a \\x02 control byte (tokenizer sentinel)" ;;
            $'\002U') deny "a command naming the bank lift cannot be parsed reliably (an unclosed quote or substitution, or a heredoc delimiter whose quote does not close)" ;;
            $'\002B\037'*) continue ;;   # heredoc body: data; its $( ) arrive as S lines
            $'\002S\037'*) line="${line#$'\002S\037'}"; whole_command_gate "${line//$'\036'/$'\n'}" $((depth+1)); continue ;;
        esac
        local -a tk=() args=()
        IFS=$'\037' read -r -a tk <<<"$line"
        nt=${#tk[@]}; i=0
        while [ "$i" -lt "$nt" ]; do
            t="${tk[$i]//$'\036'/$'\n'}"
            case "$t" in
                $'\002W')
                    i=$((i+1))
                    [ "${tk[$i]:-}" = /dev/null ] \
                        || deny "the command names the bank lift and redirects output to ${tk[$i]:-?}; in such a command only /dev/null may be a redirect target" ;;
                $'\002R') i=$((i+1)) ;;
                *) args+=("$t") ;;
            esac
            i=$((i+1))
        done
        [ "${#args[@]}" -gt 0 ] || continue
        reader_clause 1 "${args[@]}" \
            || deny "the command names the bank lift (bank-lift.json or bank-lift.sh), so every command in it — pipeline stages, \$( ) and backtick bodies, heredoc substitutions — must be a reader (cat/less/head/tail/stat/ls/file/wc/test/jq/grep/rg) or \`bash scripts/lib/bank-lift.sh show|clear\`; this one is not (${READER_CMD:-unknown}) — for a commit message or ticket text that names it, use \`git commit -F <file>\` / a --desc-file"
    done <<EOF
$out
EOF
    return 0
}

# Inline interpreter code naming the lift FILE (bank-lift.json, split or
# globbed), $BANK_LIFT_FILE, bank-lift.sh, or its sourced _bank_lift_cmd.
LIFT_CODE_RE='bank[^a-z0-9]{0,4}l[a-z?*]{0,2}ft[^a-z0-9]{0,6}json|bank[-_.]?lift[-_.]?(file|sh)|_bank_lift_cmd'
# HIMMEL-4458: a name split into string pieces ("bank"+"-"+"lift"+".json",
# 'ba' 'nk-lift.sh') matches once quotes, + , backticks and blanks are
# dropped. bank-lift.sh needs a separator before sh there, so joined prose
# ("bank-lift show") does not read as the script.
LIFT_CODE_JOINED_RE='bank[^a-z0-9]{0,4}l[a-z?*]{0,2}ft[^a-z0-9]{0,6}json|bank[-_.]?lift[-_.](file|sh)'
# _code_names_lift <lowered-code>: 0 when inline code names the lift.
_code_names_lift() {
    [[ "$1" =~ $LIFT_CODE_RE ]] && return 0
    case "$1" in *[\"\'+\`,]*) ;; *) return 1 ;; esac
    local j="${1//[\"\'+\`,[:space:]]/}"
    [[ "$j" =~ $LIFT_CODE_JOINED_RE ]]
}
# Matches "bank…lift" spelled close together (also a l?ft glob), not "bank"
# and "left" far apart in prose.
MENTION_NEAR_RE='bank[^a-z0-9]{0,4}l[a-z?*]{0,2}ft'
CUR_BODIES=""    # heredoc bodies of the text analyse() is walking
TEXT_MENTION=0   # set per analyse() call: dequoted text names bank + lift
HAS_XARGS=0

# set_rule <script-word> <first-subcommand-or-empty> <has-sub 0|1> <stdin-fed 0|1>
set_rule() {
    local script="$1" sub="$2" hassub="$3" scrb
    scrb="${script%/}"; scrb="${scrb##*/}"
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
    local tdir="" T=0 sym=0 a v kind src srcb need dest dk endopts=0 parents=0 rel
    local -a pos=()
    while [ $# -gt 0 ]; do
        a="$1"; shift
        if [ "$endopts" = 1 ]; then pos+=("$a"); continue; fi
        case "$a" in
            --) endopts=1 ;;
            --target-directory=*|--targ*=*|--ta=*|--tar=*) tdir="${a#*=}" ;;
            --t|--ta|--tar|--targ*) tdir="${1:-}"; shift ;;
            --no-target-directory) T=1 ;;
            --parents) [ "$verb" = cp ] && parents=1 ;;
            --relative) [ "$verb" = rsync ] && parents=1 ;;
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
                        R*) case "$verb" in rsync) parents=1 ;; esac; v="${v#?}" ;;
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
            case "$(lift_ref "$src")$(_cd_ref "$src")" in *LIFT*|*STATE*) deny "$verb links to the bank lift or its directory ($src)" ;; esac
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
    # HIMMEL-4458: cp --parents / rsync -R (--relative) recreate the SOURCE's
    # path under the destination, so a glob-spelled source
    # (.himmel/state/bank-l?ft.json) lands as the lift. Judge the path the
    # copy creates (dest + source path; rsync's /./ marks where it starts);
    # under a dynamic destination, the source path alone.
    if [ "$parents" = 1 ]; then
        for src in ${pos[@]+"${pos[@]}"}; do
            rel="$src"
            case "$verb:$rel" in rsync:*/./*) rel="${rel#*/./}" ;; esac
            rel="${rel#/}"
            case "$(lift_ref "${dest%/}/$rel")$(_cd_ref "${dest%/}/$rel")" in
                *LIFT*|*STATE*) deny "$verb --parents/-R recreates the bank lift's path under $dest ($src)" ;;
            esac
            if _is_dynamic "$dest"; then
                case "$(lift_ref "/$rel")" in
                    LIFT|STATE) deny "$verb --parents/-R recreates the bank lift's path under $dest ($src)" ;;
                esac
            fi
        done
    fi
    dk=$(lift_ref "$dest")
    # A relative destination after a resolved cd is the cd target's.
    [ "$dk" = NONE ] && dk=$(_cd_ref "$dest")
    case "$dk" in
        LIFT) deny "$verb writes the bank lift ($dest)" ;;
        STATE) need="$LIFT_NAME" ;;
        HIMMEL) need=state ;;
        HOME) need=.himmel ;;
        *) return 0 ;;
    esac
    # Whole-directory write into an ancestor of the lift.
    if [ "$T" = 1 ] && [ -z "$tdir" ]; then deny "$verb -T replaces/fills $dest wholesale"; fi
    # A missing ancestor of the lift (~/.himmel/state, or ~/.himmel itself) is
    # CREATED from a directory source (a lift inside comes along); a source
    # that is a literal existing regular file cannot do that, so only an
    # unknowable or directory source denies here.
    if { [ "$dk" = STATE ] || [ "$dk" = HIMMEL ]; } && [ -z "$tdir" ]; then
        kind=$(_expand "$dest")
        case "$kind" in '?/'*) [ -n "$CD_DIR" ] && kind=$(CWD="$CD_DIR" HAS_CD=0 _expand "$dest") ;; esac
        case "$kind" in
            '?/'*) ;;
            *) if [ ! -d "$kind" ]; then
                   for src in ${pos[@]+"${pos[@]}"}; do
                       v=$(_expand "$src")
                       case "$v" in '?/'*) deny "$verb would create a lift ancestor dir ($dest) from a source" ;; esac
                       if [ -d "$v" ] || [ ! -f "$v" ]; then deny "$verb would create a lift ancestor dir ($dest) from a source" ; fi  # fail-open-ok: a file-TYPE test, the file is never read
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
        if _code_names_lift "$low" && [[ "$a" =~ $SED_E_RE ]]; then
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
    local stdin_shell=0 bodies="" CL_AND=0 CL_PAR=0 CL_O=0 CL_PREV_O=0
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
        CL_PREV_O=$CL_O; CL_AND=0; CL_PAR=0; CL_O=0
        # Redirect targets; build args without them.
        while [ "$i" -lt "$nt" ]; do
            t="${tk[$i]//$'\036'/$'\n'}"
            case "$t" in
                $'\002W')
                    i=$((i+1)); t="${tk[$i]:-}"
                    if [ -n "$t" ] && is_lift "$t"; then deny "a redirect writes the bank lift ($t)"; fi
                    ;;
                $'\002A') CL_AND=1 ;;
                $'\002P') CL_PAR=1 ;;
                $'\002O') CL_O=1 ;;
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

# HIMMEL-4458: archive extraction writes members under its destination, and
# a member can be .himmel/state/bank-lift.json — a name no clause spells.
# Extraction into HOME, ~/.himmel or its state dir denies; so does one with no
# destination option whose effective cwd is one of those.
# _note_cd <cd|pushd|popd> <args...>: a bare cd, or a target resolving to
# HOME, ~/.himmel or its state dir, sets CD_HOME. `-`, popd, a stack index, a
# computed target ($d; $HOME spellings do resolve), or a relative target after
# an earlier cd set CD_UNK. Both stick for the rest of the command. CD_DIR is
# the last resolved target ("" when unresolved), which a relative operand of a
# later clause is also judged against (_cd_ref).
# shellcheck disable=SC2016  # literal $HOME spellings are matched as text
_note_cd() {
    local c="$1" t k=UNK
    shift
    while [ $# -gt 0 ]; do
        case "$1" in --) shift; break ;; -[LPe@]|-n) shift ;; *) break ;; esac
    done
    t="${1-}"
    CD_DIR=""
    if [ "$c" = popd ]; then :
    elif [ -z "$t" ]; then k=HOME; [ "$c" = cd ] && CD_DIR="$HOME"
    else
        case "$t" in
            -|[+-][0-9]*) ;;
            /*|'~'*|'$HOME'|'${HOME}'|'$HOME/'*|'${HOME}/'*) k=$(lift_ref "$t"); CD_DIR=$(_expand "$t") ;;
            *'$'*|*'`'*) ;;
            *) if [ "$CD_SEEN" = 0 ]; then k=$(HAS_CD=0 lift_ref "$t"); CD_DIR=$(HAS_CD=0 _expand "$t"); fi ;;
        esac
    fi
    case "$CD_DIR" in '?'*) CD_DIR="" ;; esac
    CD_SEEN=1
    case "$k" in LIFT|STATE|HIMMEL|HOME) CD_HOME=1 ;; UNK) CD_UNK=1 ;; esac
}

# _cd_ref <word> -> lift_ref of a relative word resolved against the last
# resolved cd target (`cd ~/projects && tar -C ..` is HOME), else NONE.
_cd_ref() {
    case "$1" in ''|/*|'~'*|'$'*) echo NONE; return ;; esac
    if [ "$CD_SEEN" = 1 ] && [ -n "$CD_DIR" ]; then
        CWD="$CD_DIR" HAS_CD=0 lift_ref "$1"
    else
        echo NONE
    fi
}

# _tar_dest <dir>: record a tar -C/--directory destination. tar applies each
# -C relative to the one before it, so a relative dir is judged as the composed
# path (`-C ~/projects -C ..` is HOME); a chain through a computed dir fails
# closed. Uses check_extract's dests/cprev.
# shellcheck disable=SC2016  # literal $HOME spellings are matched as text
_tar_dest() {
    local d="$1"
    case "$d" in
        /*|'~'*|'$HOME'|'${HOME}'|'$HOME/'*|'${HOME}/'*) ;;
        *) if [ -n "$cprev" ]; then
               case "$cprev" in
                   /*|'~'*|'$HOME'|'${HOME}'|'$HOME/'*|'${HOME}/'*) ;;
                   *'$'*|*'`'*) deny "$c resolves -C $d against a computed -C ($cprev), which may be HOME or ~/.himmel; name an absolute destination" ;;
               esac
               d="$cprev/$d"
           fi ;;
    esac
    cprev="$d"
    dests+=("$d")
}

# _home_anc <expanded-path> -> 0 when the path is a strict ancestor of HOME
# (whole components: /home is one of /home/u, /ho is not), lexically or
# physically, either side.
_home_anc() {
    local e="$1" p h hr
    case "$e" in /*) ;; *) return 1 ;; esac
    hr=$(CDPATH='' cd -P -- "$HOME" 2>/dev/null && pwd -P) || hr=""
    p=""
    [ -d "$e" ] && p=$(CDPATH='' cd -P -- "$e" 2>/dev/null && pwd -P)
    for e in "$e" "$p"; do
        [ -n "$e" ] || continue
        [ "$e" = / ] && return 0
        for h in "$HOME" "$hr"; do
            [ -n "$h" ] || continue
            case "$h" in "$e"/*) return 0 ;; esac
        done
    done
    return 1
}

# check_extract <tar|gtar|bsdtar|unzip|cpio> <args...>
# An option's operand is consumed, never read as a flag (`tar -xf -O` names
# the archive -O; it is not --to-stdout). Letters whose arity differs between
# GNU tar and bsdtar are not consumed, but the word after them is never
# trusted as a stdout flag, and a destination option there also keeps the cwd
# check (it may be an operand).
# A relative tar -C/--directory resolves against the -C before it (_tar_dest);
# kept absolute (or ../) member names (-P, --absolute-names/-paths, unzip -:,
# cpio copy-in without --no-absolute-filenames) deny whatever the destination.
check_extract() {
    local c="$1" x=0 q="" a k first=1 n out=0 end=0 pend=0 u cwdchk=0 pass=0 v ch dash amb args alld=0
    local abs=0 noabs=0 lst=0 cprev="" ksym=0 e
    local -a dests=() pos=()
    shift
    [ "$c" = unzip ] && x=1
    case "$c" in
        tar) args=fCTXbI; amb=HKNVgFLs ;;
        gtar) args=fCTXbIHKNVgFL; amb="" ;;
        bsdtar) args=fCTXbIs; amb="" ;;
        unzip) args=dPOI; amb="" ;;
        cpio) args=FEHIODRMC; amb="" ;;
    esac
    for a in "$@"; do
        [ "$alld" = 1 ] && dests+=("$a")
        # The operand of the option before it: never a flag.
        if [ -n "$q" ]; then
            ch="${q:0:1}"; q="${q:1}"
            case "$c:$ch" in *tar:C) _tar_dest "$a"; continue ;; cpio:D|unzip:d) dests+=("$a"); continue ;; esac
            # A destination option as another option's operand: the readings
            # diverge from here, so judge the cwd and every later word.
            case "$c:$a" in
                *tar:--dir*=*|cpio:--dir*=*) cwdchk=1; alld=1; dests+=("${a#*=}") ;;
                *tar:-C?*|cpio:-D?*|unzip:-d?*) cwdchk=1; alld=1; dests+=("${a#-?}") ;;
                *tar:-C|*tar:--dir*|cpio:-D|cpio:--dir*|unzip:-d) cwdchk=1; alld=1 ;;
            esac
            continue
        fi
        u=$pend; pend=0
        if [ "$end" = 1 ]; then pos+=("$a"); continue; fi
        case "$a" in -[CDd]*|--dir*) [ "$u" = 1 ] && cwdchk=1 ;; esac
        dash=1
        case "$c:$a" in
            *:--) end=1; continue ;;
            *tar:--extract|*tar:--ext|*tar:--extr*|*tar:--get|cpio:--extract|cpio:--ext|cpio:--extr*) x=1; continue ;;
            cpio:--pass-through|cpio:--pass*) x=1; pass=1; continue ;;
            *tar:--to-stdout|cpio:--to-stdout) [ "$u" = 1 ] || out=1; continue ;;
            *tar:--directory=*|*tar:--dir*=*) _tar_dest "${a#*=}"; continue ;;
            cpio:--directory=*|cpio:--dir*=*) dests+=("${a#*=}"); continue ;;
            *tar:--abs*) abs=1; continue ;;
            *tar:--keep-d*) ksym=1; continue ;;
            cpio:--abs*) abs=1; continue ;;
            cpio:--no-abs*) noabs=1; continue ;;
            cpio:--list) lst=1; continue ;;
            *tar:--dir*) q=C; continue ;;
            cpio:--dir*) q=D; continue ;;
            *:--*=*) continue ;;
            *tar:--file|*tar:--fil|*tar:--files*|*tar:--exclude|*tar:--exclude-from|*tar:--exclude-tag*|*tar:--exclude-ignore*|*tar:--blocking-factor|*tar:--format|*tar:--starting-file|*tar:--newer*|*tar:--after-date|*tar:--label|*tar:--listed-incremental|*tar:--info-script|*tar:--new-volume-script|*tar:--tape-length|*tar:--use-compress-program|*tar:--transform|*tar:--xform|*tar:--owner*|*tar:--group*|*tar:--mode|*tar:--mtime|*tar:--suffix|*tar:--to-command|*tar:--rsh-command|*tar:--rmt-command|*tar:--volno-file|*tar:--record-size|*tar:--strip-components|*tar:--warning|*tar:--hole-detection|*tar:--sort|*tar:--quoting-style|*tar:--index-file|*tar:--pax-option|*tar:--level|*tar:--add-file|*tar:--checkpoint-action|*tar:--quote-chars|*tar:--no-quote-chars|*tar:--options|*tar:--include|*tar:--uid|*tar:--gid|*tar:--uname|*tar:--gname)
                q=a; continue ;;
            cpio:--file|cpio:--pattern-file|cpio:--format|cpio:--owner|cpio:--message|cpio:--io-size|cpio:--rsh-command|cpio:--block-size)
                q=a; continue ;;
            # Common long flags that take no operand.
            *:--no-*|*:--verbose|*:--gzip|*:--gunzip|*:--bzip2|*:--xz|*:--lzma|*:--lzip|*:--lzop|*:--zstd|*:--auto-compress|*:--overwrite*|*:--keep-old-files|*:--skip-old-files|*:--keep-newer-files|*:--unlink-first|*:--recursive-unlink|*:--same-owner|*:--same-permissions|*:--preserve-permissions|*:--numeric-owner|*:--wildcards|*:--anchored|*:--ignore-case|*:--totals|*:--touch|*:--sparse|*:--dereference|*:--ignore-zeros|*:--null|*:--exclude-vcs*|*:--exclude-caches*|*:--exclude-backups|*:--show-transformed-names|*:--delay-directory-restore|*:--make-directories|*:--preserve-modification-time|*:--unconditional|*:--list|*:--create|*:--quiet|*:--selinux|*:--acls|*:--xattrs) continue ;;
            # An unknown long option may take the next word.
            *:--*) pend=1; continue ;;
            *:-?*) v="${a#-}" ;;
            *tar:*) [ "$first" = 1 ] || { first=0; continue; }
                    v="$a"; dash=0 ;;
            cpio:*) pos+=("$a"); first=0; continue ;;
            *) first=0; continue ;;
        esac
        first=0
        while [ -n "$v" ]; do
            ch="${v:0:1}"; v="${v:1}"
            case "$c:$ch" in
                *tar:x|cpio:i) x=1; continue ;;
                cpio:p) x=1; pass=1; continue ;;
                *tar:O) [ "$u" = 1 ] || out=1; continue ;;
                *tar:P|unzip:[:]) abs=1; continue ;;
                cpio:t) lst=1; continue ;;
                unzip:[ltvZpcz]) [ "$u" = 1 ] || x=0; continue ;;
            esac
            case "$args" in
                *"$ch"*)
                    if [ "$dash" = 1 ] && [ -n "$v" ]; then
                        case "$c:$ch" in *tar:C) _tar_dest "$v" ;; cpio:D|unzip:d) dests+=("$v") ;; esac
                        v=""
                    else
                        q="$q$ch"
                        [ "$dash" = 1 ] && v=""
                    fi
                    continue ;;
            esac
            case "$amb" in *"$ch"*) u=1; pend=1 ;; esac
        done
    done
    # -O / --to-stdout extracts to stdout, not to disk; cpio -t lists.
    [ "$lst" = 1 ] && x=0
    [ "$x" = 1 ] && [ "$out" = 0 ] || return 0
    # GNU cpio keeps absolute member names by default (copy-in only).
    [ "$c" = cpio ] && [ "$pass" = 0 ] && [ "$noabs" = 0 ] && abs=1
    [ "$abs" = 1 ] && deny "$c keeps absolute (or ../) member names, so a member can land on the bank lift whatever the destination; drop -P/--absolute-names/--absolute-paths/-: (cpio: add --no-absolute-filenames)"
    # ponytail: a symlink ALREADY inside an allowed destination is followed by
    # default for a member's intermediate path (GNU tar without a directory
    # member, unzip, cpio) and is not judged here; revisit (new ticket) if a
    # destination-internal symlink becomes plantable by an agent before the
    # extraction, e.g. the destination is created in the same command.
    [ "$ksym" = 1 ] && deny "$c --keep-directory-symlink follows a directory symlink inside the destination, which can lead into HOME or ~/.himmel; drop it"
    # Structural fail-closed: with the cwd unproven, no destination (even an
    # absolute one) is judged; split the cd and the extraction into separate
    # commands, or join them only by && at top level.
    [ "$CWD_UNPROVEN" = 1 ] && deny "$c extracts in a command whose cwd is not provably known (a cd not joined only by && at top level, a cd in a subshell, brace group or nested shell body, or an eval), so it may extract into HOME or ~/.himmel; run the extraction as its own command"
    # cpio -p copies into its directory operand.
    [ "$pass" = 1 ] && dests+=(${pos[@]+"${pos[@]}"})
    n=${#dests[@]}
    if [ "$n" = 0 ] || [ "$cwdchk" = 1 ]; then
        [ "$CD_HOME" = 1 ] && deny "$c extracts into the cwd after a cd into HOME or ~/.himmel"
        [ "$CD_UNK" = 1 ] && deny "$c extracts into the cwd after a cd whose target cannot be resolved, or that may have failed (only \`cd X && ...\` moves the cwd), so the cwd may be HOME or ~/.himmel; name the destination with -C/-d"
        if [ "$CD_SEEN" = 0 ]; then
            case "$(lift_ref "$CWD")" in
                LIFT|STATE|HIMMEL|HOME) deny "$c extracts into the cwd ($CWD), which is HOME or ~/.himmel" ;;
            esac
            _home_anc "$CWD" && deny "$c extracts into the cwd ($CWD), an ancestor of HOME: a relative member can reach the bank lift"
        elif [ -n "$CD_DIR" ]; then
            _home_anc "$CD_DIR" && deny "$c extracts into the cwd after a cd to $CD_DIR, an ancestor of HOME: a relative member can reach the bank lift"
        fi
        [ "$n" = 0 ] && return 0
    fi
    for a in "${dests[@]}"; do
        # A computed destination ($D, $(...), `...`; $HOME spellings resolve)
        # cannot be shown to stay off HOME: fail closed, like an unresolved cd.
        case "$(_expand "$a")" in
            *'$'*|*'`'*) deny "$c extracts into a computed destination ($a), which may be HOME or ~/.himmel; name a literal path" ;;
        esac
        case "$a" in
            /*|'~'*|'$'*) ;;
            *) [ "$CD_HOME" = 1 ] && deny "$c extracts into a relative dir ($a) after a cd into HOME or ~/.himmel"
               # After an unresolved cd, `.`, a `..` or a .himmel-named first
               # part may be HOME's.
               if [ "$CD_UNK" = 1 ]; then
                   k="${a#./}"; k="${k%%/*}"
                   case "/$a/" in */../*) k=. ;; esac
                   if [ -z "$k" ] || [ "$k" = . ] || _name_matches "$k" .himmel; then
                       deny "$c extracts into $a after a cd whose target cannot be resolved (it may be HOME or ~/.himmel)"
                   fi
               fi ;;
        esac
        if [ "$CD_SEEN" = 0 ]; then k=$(HAS_CD=0 lift_ref "$a"); else k=$(lift_ref "$a"); fi
        [ "$k" = NONE ] && k=$(_cd_ref "$a")
        case "$k" in
            LIFT|STATE|HIMMEL|HOME) deny "$c extracts into $a (HOME, ~/.himmel or its state dir), where a member can be the bank lift" ;;
        esac
        if [ "$CD_SEEN" = 0 ]; then e=$(HAS_CD=0 _expand "$a"); else e=$(_expand "$a"); fi
        case "$e" in '?/'*) [ -n "$CD_DIR" ] && e=$(CWD="$CD_DIR" HAS_CD=0 _expand "$a") ;; esac
        _home_anc "$e" && deny "$c extracts into $a, an ancestor of HOME: a relative member (home/<user>/.himmel/state/...) can reach the bank lift"
    done
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
        _lb "$w"; cmd=$R
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
                CWD_UNPROVEN=1
                if _is_dynamic "$*" && [ "$TEXT_MENTION" = 1 ]; then
                    deny "eval runs computed text beside a bank-lift mention"
                fi
                analyse "$*" $((depth+1)); return 0 ;;
        esac
        break
    done
    [ $# -gt 0 ] || return 0
    w="$1"; shift
    _lb "$w"; cmd=$R

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
            case "${1:-}" in sh|ash|bash) shift; bbsh=1 ;; *) w="${1:-}"; [ $# -gt 0 ] && shift; _lb "$w"; cmd=$R ;; esac
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
            set_rule "$w" "${1:-}" $(( $# > 0 ? 1 : 0 )) "$(( fed != 0 ))"
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
            if _code_names_lift "$code"; then
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
            case "$cmd" in
                tar|gtar|bsdtar|unzip|cpio) check_extract "$cmd" "$@" ;;
                # The cwd is provably the cd target only for a top-level cd
                # joined to the next clause by && and not reached through | ||
                # or &; else (failed or skipped cd, a subshell, a nested body)
                # it is unproven and every extraction denies.
                cd|pushd|popd) _note_cd "$cmd" "$@"
                    if [ "$CL_AND" = 0 ] || [ "$CL_PAR" = 1 ] || [ "$CL_PREV_O" = 1 ] || [ "$depth" -gt 0 ]; then
                        CWD_UNPROVEN=1
                    fi ;;
            esac
            if [[ "$cmd" =~ $MENTION_RE ]]; then
                for a in "$@"; do
                    case "$a" in -*=*) a="${a#*=}" ;; esac
                    case "$(lift_ref "$a")" in LIFT|STATE) deny "$cmd is handed a bank-lift path ($a)" ;; esac
                done
            fi
            set_rule "$w" "${1:-}" $(( $# > 0 ? 1 : 0 )) "$(( fed != 0 ))" ;;
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
# Layer 1: the whole-command mention rule (J1874). The trigger reads both the
# raw text and the dequoted tokens (quote splits, $'..', heredoc bodies).
WTOK=$(printf '%s' "$CMD" | awk -v STRICT=1 "$TOKENIZER") || deny "command tokenizer failed (fail-closed)"
if names_lift "$CMD" || names_lift "$WTOK"; then whole_command_gate "$CMD" 0; fi
analyse "$CMD" 0
exit 0
