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
# scripts/lib/bank-lift.sh of this checkout, or of one of its .claude/worktrees
# while that copy is byte-identical to the primary's (HIMMEL-4458; HIMMEL-4545
# closed the edited-copy case: a worktree copy that differs no longer runs).
# HIMMEL-4545 also closed a glob source into a computed destination
# (d=<state>; cp dir/* "$d", --parents too). Still open, verified at base and
# head: a redirect or tee to an inherited env value (`> "$X"`, X set outside
# the command) is allowed, since denying every `> "$VAR"` would break the
# fleet (HIMMEL-5159); upgrade path is the operator-owned lift above.
# ponytail: accepted over-deny (HIMMEL-4545), measured on p22-hist at 845 of
# 211,645 rows (0.40 %): ~725 relative or computed copy destinations and
# sources under an unproven cwd, 110 computed extraction destinations
# (`tar -C "$B"` with B set in the command), ~14 glob / JSON-argument mention
# over-matches, 16 harness artifacts, 1 tar --wildcards. HIMMEL-4545 trims the
# copy class that is provably harmless (a plain literal name copied to a
# plain literal name, `_plain_name_copy`, which still refuses a name that
# exists under the payload's cwd as a symlink to the lift or its directory; a
# proven cwd resolves such a link too, as does the target of a literal
# absolute `cd`/`pushd`; a relative or computed `cd` keeps the copy denied).
# The remainder stays denied because
# the member names or the resolved cwd are unknowable to a text layer: an
# extraction under an unproven cwd, `ln` with a computed or relative source,
# a computed extraction destination, and a glob that can match the lift's
# name. A trim that would also let one of those through is not taken; the
# retry (a literal path, or `cd` in its own command) costs a leg one call.
# ponytail: the PowerShell tool is not wired, Windows is parked under
# HIMMEL-4102 — wire it when Windows legs resume.
# ponytail: HIMMEL-5094 extraction ceilings, none visible to a text layer
# (each needs a runtime or filesystem view; upgrade path is a sandbox that
# mounts HOME read-only for agent shells): (a) an archive MEMBER that is a
# symlink, or a git clone carrying a link, then a second extraction through it
# in a LATER command, or in the SAME command (a clone then an extract, or two
# extractions into one destination: the first leaves the link the second
# follows, and no text names it); (b) data piped into a shell (`echo '…' | bash`), whose
# text arrives on a pipe the tokenizer does not join to the reader; (c) a
# variable command word with a variable destination when the command names
# neither an archive tool nor a HOME spelling; (d) an interpreter script FILE,
# or inline code calling tarfile.extractall; (e) dpkg --root/--instdir, 7z
# @listfile and ar --plugin, whose targets sit in a file or a plugin; (f) eval
# nesting past depth 4 where no archive tool and HOME spelling remain to read.
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
CWD_UNPROVEN=0  # set for Bash: a directory-changing word anywhere makes the cwd unknown
XENV_SET=0      # set for Bash: the command names a tar/unzip option variable
EXTRACT_SEEN=0  # set when a clause extracts an archive to disk (HIMMEL-4530)
SYMLINK_SEEN=0  # set when a clause creates a symlink (ln -s, cp -s)
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
        *) if [ "$CWD_UNPROVEN" = 1 ]; then printf '?/%s' "$w"; return; fi; w="$CWD/$w" ;;
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

# HIMMEL-4972: brace expansion works on the ORIGINAL word. The tokenizer marks
# only UNQUOTED { } , with \003 \004 \005 (quoted or escaped ones stay plain
# characters), so a "}" or \} or $'\x7d' inside a group does not close it, as
# in bash. _bx expands the marked word the way bash does; a no-comma group
# (which bash leaves literal, or a {a..c} sequence) becomes `*`, a superset.
# It fails closed (BX_FAIL=1) on an unbalanced group, more than BX_MAX words,
# more than 16 groups or a word over 4096 characters.
BX_MAX=256
BXW=(); BX_FAIL=0
# _bx <marked-word> <groups-resolved>: appends the expansions to BXW.
_bx() {
    local s="$1" depth="$2" pre rest c lvl=0 i n alt="" end=-1 commas=0 suf w
    local -a alts=()
    [ "$BX_FAIL" = 1 ] && return
    case "$s" in
        *$'\003'*) ;;
        *) s="${s//$'\004'/\}}"; s="${s//$'\005'/,}"
           if [ "${#BXW[@]}" -ge "$BX_MAX" ]; then BX_FAIL=1; return; fi
           BXW[${#BXW[@]}]="$s"; return ;;
    esac
    if [ "$depth" -ge 16 ] || [ "${#s}" -gt 4096 ]; then BX_FAIL=1; return; fi
    pre="${s%%$'\003'*}"; rest="${s#*$'\003'}"; n=${#rest}; i=0
    while [ "$i" -lt "$n" ]; do
        c="${rest:i:1}"
        case "$c" in
            $'\003') lvl=$((lvl+1)); alt="$alt$c" ;;
            $'\004') if [ "$lvl" = 0 ]; then end=$i; break; fi; lvl=$((lvl-1)); alt="$alt$c" ;;
            $'\005') if [ "$lvl" = 0 ]; then alts[${#alts[@]}]="$alt"; alt=""; commas=$((commas+1)); else alt="$alt$c"; fi ;;
            *) alt="$alt$c" ;;
        esac
        i=$((i+1))
    done
    if [ "$end" -lt 0 ]; then BX_FAIL=1; return; fi
    alts[${#alts[@]}]="$alt"
    suf="${rest:end+1}"
    if [ "$commas" = 0 ]; then _bx "$pre*$suf" $((depth+1)); return; fi
    for w in "${alts[@]}"; do
        _bx "$pre$w$suf" $((depth+1))
        [ "$BX_FAIL" = 1 ] && return
    done
}

_is_dynamic() { case "$1" in *'$'*|*'`'*) return 0 ;; esac; return 1; }

# _name_matches <component-from-word> <real-name>: the word component could
# name real-name (literal, glob, brace, case-folded), or is dynamic.
_name_matches() {
    local c="$1" w
    _is_dynamic "$c" && return 0
    case "$c" in
        *$'\003'*)
            BXW=(); BX_FAIL=0; _bx "$c" 0
            [ "$BX_FAIL" = 0 ] || return 0
            for w in "${BXW[@]}"; do _name_match1 "$w" "$2" && return 0; done
            return 1 ;;
    esac
    _name_match1 "$c" "$2"
}
_name_match1() {
    # Case-folded only here: option parsing elsewhere is case-sensitive (-t/-T).
    local r=1
    shopt -s nocasematch extglob
    # shellcheck disable=SC2053  # the RHS is deliberately a pattern
    [[ "$2" == $1 ]] && r=0
    shopt -u nocasematch extglob
    return "$r"
}

# _dir_kind <expanded-dir> -> STATE | HIMMEL | HOME | UNKNOWN | NONE
_dir_kind() {
    local d="$1" last parent
    case "$d" in '?'|'?/'*) echo UNKNOWN; return ;; esac
    if _is_dynamic "$d"; then echo UNKNOWN; return; fi
    last="${d##*/}"; parent="${d%/*}"; parent="${parent##*/}"
    # HIMMEL-4750: .himmel/state is two components. A slash-less word (a JSON
    # argument, whose braces glob to `*`) has parent == last == the whole word.
    if [ -n "$last" ] && [ -n "$parent" ] && [ "$d" != "$last" ] && _name_matches "$parent" .himmel && _name_matches "$last" state; then
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
    local w best=NONE k
    case "$1" in
        *$'\003'*) ;;
        *) _lift_ref1 "$@"; return ;;
    esac
    BXW=(); BX_FAIL=0; _bx "$1" 0
    [ "$BX_FAIL" = 0 ] || { echo LIFT; return; }
    for w in "${BXW[@]}"; do
        k=$(_lift_ref1 "$w" "${2:-0}")
        case "$k" in
            LIFT) echo LIFT; return ;;
            STATE) best=STATE ;;
            HIMMEL) [ "$best" = STATE ] || best=HIMMEL ;;
            HOME) [ "$best" = NONE ] && best=HOME ;;
        esac
    done
    echo "$best"
}
_lift_ref1() {
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
case "$CMD" in *$'\002'*|*$'\003'*|*$'\004'*|*$'\005'*|*$'\036'*|*$'\037'*) deny "the command carries a tokenizer control byte (\\x02-\\x05, \\x1e, \\x1f)" ;; esac

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
# HIMMEL-4729: every caller runs this program under LC_ALL=C. It walks the
# text with substr(s, i, 1), which gawk resolves by decoding from the start in a
# UTF-8 locale (quadratic: 0.15 s per run at 45 KB); every byte it tests is
# ASCII, so a byte walk emits the same tokens.
read -r -d '' TOKENIZER <<'AWK'
function hexv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function addc(c) { if (c == SB || c == US || c == NL || c == BO || c == BC || c == CM) forged = 1; tok = tok c }
# HIMMEL-4972: unquoted { } , carry \003 \004 \005 so a later brace expansion
# sees which ones are active; a word with no active { gets them back as text.
function unmark(t) {
    if (index(t, BO) == 0 || t == BO || t == BC) { gsub(BC, "}", t); gsub(CM, ",", t); gsub(BO, "{", t) }
    return t
}
function emit_tok() {
    pe = 0; tok = unmark(tok)
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
    US = "\037"; NL = "\036"; SB = "\002"; BO = "\003"; BC = "\004"; CM = "\005"; FDRE = "^([0-9]+|" BO "[A-Za-z_][A-Za-z0-9_]*" BC ")$"; forged = 0; pe = 0
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
        if (c == "$" && c2 == "{") { addc(c); addc(c2); pe = 1; i++; continue }
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
            if (!quoted && tok ~ FDRE) tok = ""
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
            if (!quoted && tok ~ FDRE) tok = ""
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
        if (pe > 0) { if (c == "{") pe++; else if (c == "}") pe--; addc(c); continue }
        if (c == "{") { tok = tok BO; continue }
        if (c == "}") { tok = tok BC; continue }
        if (c == ",") { tok = tok CM; continue }
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

# HIMMEL-5094: archive tools (and the python modules that extract), as a word
# anywhere in a text and as a command word.
EXTRACT_WORD_RE='(^|[^A-Za-z0-9_.-])(tar|gtar|bsdtar|unzip|cpio|bsdcpio|7z|7za|7zr|7zz|pax|ar|jar|dpkg|dpkg-deb|unar|tarfile|zipfile)([^A-Za-z0-9_.-]|$)'
EXTRACT_CMD_RE='^(tar|gtar|bsdtar|unzip|cpio|bsdcpio|7z|7za|7zr|7zz|pax|ar|jar|dpkg|dpkg-deb|unar)$'
# A symlink CALL in interpreter code: symlink(…), os.symlink(…), symlink_to,
# perl/php `symlink q(…)` / `symlink "…"` — not the word inside a string.
SYMCALL_RE='(^|[^a-z0-9_"'"'"'])symlink[a-z_]*[[:space:]]*\(|(^|[^a-z0-9_"'"'"'])symlink_to|(^|[^a-z0-9_"'"'"'])symlink[[:space:]]+[q"'"'"'$]'
# Commands that only name a tool (install it, look it up, print it): not wrappers.
NOSCAN_RE='^(apt|apt-get|aptitude|apt-cache|dnf|yum|zypper|apk|brew|pacman|pip[0-9.]*|pipx|cargo|gem|which|whereis|type|man|info|help|whatis|apropos|tldr|echo|printf|git|gh)$'

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
            [ "$CWD_UNPROVEN" = 0 ] || return 1
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
        # HIMMEL-4545: a worktree's copy runs only while it is byte-identical
        # to the primary's; an edited copy is other code under the same name.
        "$LIFT_REPO"/.claude/worktrees/?*) cmp -s -- "$p" "$LIFT_REPO/scripts/lib/bank-lift.sh" && return 0 ;;
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
    out=$(printf '%s' "$text" | LC_ALL=C awk -v STRICT=1 "$TOKENIZER") || deny "command tokenizer failed (fail-closed)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            $'\002X') deny "the command decodes a tokenizer control byte (\\x02-\\x05, \\x1e, \\x1f)" ;;
            $'\002U') deny "a command naming the bank lift cannot be parsed reliably (an unclosed quote or substitution, or a heredoc delimiter whose quote does not close)" ;;
            $'\002B\037'*) continue ;;   # heredoc body: data; its $( ) arrive as S lines
            $'\002S\037'*) line="${line#$'\002S\037'}"; _c_replace "$line" $'\036' $'\n'; whole_command_gate "$REPLY" $((depth+1)); continue ;;
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
    _lift_join "$1" || return 1
    local j="$LIFT_J"
    # Unicode spaces (U+3000 ...) are not ASCII, so a UTF-8 pass drops them;
    # the ASCII ones are already gone, so it has next to no matches to pay for.
    j="${j//[[:space:]]/}"
    [[ "$j" =~ $LIFT_CODE_JOINED_RE ]]
}
# _lift_join <lowered-code>: 1 when the text has none of the quote characters
# a split name hides behind; else LIFT_J = the text with those and the ASCII
# blanks dropped. HIMMEL-4729: the bytes tested are ASCII, so the case and the
# strip run under a function-local LC_ALL=C. In a UTF-8 locale the strip
# re-decoded the whole text per match (3 s at 45 KB).
# _c_replace <text> <byte> <replacement>: REPLY = text with every <byte>
# replaced, under the same function-local LC_ALL=C (HIMMEL-4729). A UTF-8
# ${x//b/r} re-decodes the text for each match; a 640-line body has 640.
_c_replace() { local LC_ALL=C; REPLY=${1//"$2"/"$3"}; }
_lift_join() {
    local LC_ALL=C
    case "$1" in *[\"\'+\`,]*) ;; *) return 1 ;; esac
    LIFT_J="${1//[\"\'+\`,[:space:]]/}"
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

# Directory-changing words (whole command; see the CWD_UNPROVEN check at the
# bottom): cd/pushd/popd, eval, su/runuser/chroot, CDPATH, any chdir/--chdir,
# find -execdir, a `(` or backtick (subshell, $( ), <( )), a { } brace group,
# env/sudo with -C/-i, and a shell running a -c string.
DIRWORD_RE='(^|[^A-Za-z0-9_.-])(cd|pushd|popd|eval|su|runuser|chroot)([^A-Za-z0-9_.-]|$)|CDPATH|chdir|-execdir|[(`]|(^|[[:space:];&|])[{]([[:space:]]|$)|(^|[^A-Za-z0-9_.-])(env|sudo)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+-[A-Za-z]*[Ci]|(^|[^A-Za-z0-9_.-])(bash|sh|zsh|dash|ksh|mksh|ash|fish|busybox)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+-[A-Za-z]*c'
# DIRWORD_RE without its `(`/backtick and `{ }` alternatives: the words that
# can move the cwd themselves. A bare subshell, $( ) or brace group does not
# (what it runs is read as text), so _plain_name_copy reads this one after it
# has accounted for every literal absolute `cd`.
DIRMOVE_RE=${DIRWORD_RE/'|[(`]|(^|[[:space:];&|])[{]([[:space:]]|$)'/}
# tar/unzip read options from these variables. A variable can be set in many
# forms (prefix, export, env, declare/typeset/local, readonly, printf -v, read,
# a nameref, +=, a nested body), so the BARE name anywhere in the raw text or
# the dequoted tokens counts; mentions over-deny, by design. Case-sensitive:
# the `unzip` command never matches `UNZIP`. The value is not parsed. A value
# inherited from the launching environment is out of scope.
XENV_RE='(^|[^A-Za-z0-9_])(TAR_OPTIONS|UNZIP|UNZIPOPT|ZIPINFO|ZIPINFOOPT)([^A-Za-z0-9_]|$)'
# shellcheck disable=SC2016  # the rewrite names literal command shapes
UNPROVEN_FIX='a directory-changing word (cd/pushd/popd/CDPATH/eval/subshell/nested shell) makes the cwd unknown: use an absolute destination (`tar -C /abs`, `cp ... /abs`) or run it as its own command'

# _rel_unproven <word> -> 0 when the cwd is unproven and the word is not an
# absolute, ~ or $HOME path (relative, or computed: it may be relative).
# shellcheck disable=SC2016  # literal $HOME spellings are matched as text
_rel_unproven() {
    [ "$CWD_UNPROVEN" = 1 ] || return 1
    case "$1" in
        /*|'~'*|'$HOME'|'${HOME}'|'$HOME/'*|'${HOME}/'*) return 1 ;;
    esac
    return 0
}

# _lit_name <word> -> 0 when the word's last component is a plain literal
# name: not empty, `.` or `..`, no trailing slash, no expansion, glob, escape
# or brace mark, no `~` lead or `..` component, and not a name the lift or its
# ancestors answer to (bank-lift.json, state, .himmel, any component of HOME).
_lit_name() {
    local b p c
    case "$1" in ''|*/|*/.|*/..|.|..|'~'*) return 1 ;; esac
    case "/$1/" in */../*) return 1 ;; esac
    b="${1##*/}"
    # a name that is any component of HOME may be HOME or an ancestor of it
    # when the cwd is unproven (`cd /home; ln -s overlord x`)
    p="${HOME#/}"
    while [ -n "$p" ]; do
        c="${p%%/*}"
        _name_matches "$b" "$c" && return 1
        case "$p" in */*) p="${p#*/}" ;; *) p="" ;; esac
    done
    # the whole word, not just the name: `$X/plainlink` is computed whatever X
    # holds (an inherited value is invisible here)
    case "$1" in
        *[\$\`\*\?\[\\]*|*$'\003'*|*$'\004'*|*$'\005'*) return 1 ;;
    esac
    _name_matches "$b" "$LIFT_NAME" && return 1
    _name_matches "$b" state && return 1
    _name_matches "$b" .himmel && return 1
    return 0
}

# _plain_name_copy <dest> <T><parents> <srcs...> (HIMMEL-4545) -> 0 when a copy
# to a relative destination under an unproven cwd cannot put anything at the
# lift or inside its directory, whatever the cwd turns out to be. The lift is
# written only as a file NAMED bank-lift.json (the mention rule denies that
# spelling first), or as the contents of a directory landing on state, .himmel
# or HOME. So every source and the destination must be a plain literal name that
# is none of those; `-T` / `--parents` / `-R` and a trailing-slash or `.`
# source (which spill a directory's contents) never qualify. A destination that
# already exists, under the payload's cwd, as a symlink (chain) to the lift or
# to its state / .himmel / HOME directory is refused: the name is plain but
# the write is not. The same holds under each literal absolute `cd`/`pushd`
# target; a relative or computed `cd`, `eval` and the like refuse the allow.
_plain_name_copy() {
    local dest="$1" flags="$2" s
    shift 2
    [ "$flags" = 00 ] || return 1
    _lit_name "$dest" || return 1
    for s in "$@"; do _lit_name "$s" || return 1; done
    case "$CWD" in
        /*)
            case "$(lift_ref "${CWD%/}/$dest")" in
                LIFT|STATE|HIMMEL|HOME) return 1 ;;
            esac
            ;;
    esac
    # The cwd is unproven because of a directory-changing word. A literal
    # absolute `cd`/`pushd <dir>` names where the copy lands: the link is
    # looked up there too. Any other directory-changing word (a relative or
    # computed cd, eval, a subshell, ...) leaves the cwd unknown: refused.
    local rest wrest dir re
    rest=$CMD wrest=$WTOK_SP
    re='(^|[^A-Za-z0-9_.-])(cd|pushd)[[:space:]]+(--[[:space:]]+)?(/[A-Za-z0-9_./+@%,:=-]*)([[:space:];&|]|$)'
    while [[ "$rest" =~ $re ]]; do
        dir=${BASH_REMATCH[4]}
        case "$(lift_ref "${dir%/}/$dest")" in
            LIFT|STATE|HIMMEL|HOME) return 1 ;;
        esac
        rest=${rest/"${BASH_REMATCH[0]}"/ }
    done
    while [[ "$wrest" =~ $re ]]; do
        dir=${BASH_REMATCH[4]}
        case "$(lift_ref "${dir%/}/$dest")" in
            LIFT|STATE|HIMMEL|HOME) return 1 ;;
        esac
        wrest=${wrest/"${BASH_REMATCH[0]}"/ }
    done
    [ "$(printf '%s\n%s' "$rest" "$wrest" | grep -Ec "$DIRMOVE_RE")" = 0 ] || return 1
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
            _rel_unproven "$src" && deny "$verb links to a relative source ($src): $UNPROVEN_FIX"
            case "$(lift_ref "$src")" in LIFT|STATE) deny "$verb links to the bank lift or its directory ($src)" ;; esac
        done
    fi
    # With the cwd unproven a relative destination cannot be placed (the
    # --parents path and the ancestor check below build on it); an absolute
    # one is judged as with a proven cwd. HIMMEL-4545: except a plain
    # file-to-name copy, which cannot reach the lift through any cwd.
    if _rel_unproven "$dest"; then
        _plain_name_copy "$dest" "$T$parents" ${pos[@]+"${pos[@]}"} \
            || deny "$verb writes to a relative destination ($dest): $UNPROVEN_FIX"
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
            case "$(lift_ref "${dest%/}/$rel")" in
                LIFT|STATE) deny "$verb --parents/-R recreates the bank lift's path under $dest ($src)" ;;
            esac
            if _is_dynamic "$dest"; then
                case "$(lift_ref "/$rel")" in
                    LIFT|STATE) deny "$verb --parents/-R recreates the bank lift's path under $dest ($src)" ;;
                esac
            fi
        done
    fi
    # HIMMEL-4545: a computed destination (`d=<state dir>; cp dir/* "$d"`) may
    # BE the state dir, so a glob source that can match the lift's name, or
    # state / .himmel, denies as it does for a literal destination. A computed
    # source word is not a glob and stays an accepted ceiling.
    if _is_dynamic "$dest"; then
        for src in ${pos[@]+"${pos[@]}"}; do
            case "$src" in *[\*\?\[]*) ;; *) continue ;; esac
            srcb=$(_base "$src")
            for need in "$LIFT_NAME" state .himmel; do
                if _name_matches "$srcb" "$need"; then
                    deny "$verb copies a glob source ($src) into a computed destination ($dest) that may be the state dir; name the destination literally"
                fi
            done
        done
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
    # A missing ancestor of the lift (~/.himmel/state, or ~/.himmel itself) is
    # CREATED from a directory source (a lift inside comes along); a source
    # that is a literal existing regular file cannot do that, so only an
    # unknowable or directory source denies here.
    if { [ "$dk" = STATE ] || [ "$dk" = HIMMEL ]; } && [ -z "$tdir" ]; then
        kind=$(_expand "$dest")
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
        # HIMMEL-5094: too deep to inspect, so an archive tool beside a HOME
        # spelling denies.
        if [[ "$text" =~ $EXTRACT_WORD_RE ]] && _text_names_home "$text"; then
            deny "command nests too deep to inspect and names an archive tool beside HOME"
        fi
        return 0
    fi
    out=$(printf '%s' "$text" | LC_ALL=C awk "$TOKENIZER") || deny "command tokenizer failed (fail-closed)"
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
    _c_replace "$CUR_BODIES" $'\036' $'\n'
    CUR_BODIES=$REPLY
    # Pass 1: clauses.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            $'\002X') deny "the command decodes a tokenizer control byte (\\x02-\\x05, \\x1e, \\x1f)" ;;
            $'\002B\037'*) bodies="$bodies${line#$'\002B\037'}"$'\n'; continue ;;
            $'\002S\037'*) line="${line#$'\002S\037'}"; _c_replace "$line" $'\036' $'\n'; analyse "$REPLY" $((depth+1)); continue ;;
        esac
        local -a tk=() args=() rt=()
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
                    rt+=("$t")
                    case "$(_base "$t")" in *bank*) _name_matches "$(_base "$t")" bank-lift.sh && fed=2 ;; esac
                    ;;
                *) args+=("$t") ;;
            esac
            i=$((i+1))
        done
        [ "${#args[@]}" -gt 0 ] || continue
        check_lift_name "${args[@]}"
        check_clause "$depth" "$fed" "${args[@]}"
        case "$?" in
            # HIMMEL-5094: a here-string (<<<) into a shell is its script text;
            # a `< file` target analysed as text is a harmless command word.
            10) stdin_shell=1
                for t in ${rt[@]+"${rt[@]}"}; do analyse "$t" $((depth+1)); done ;;
        esac
    done <<EOF
$out
EOF
    if [ -n "$bodies" ] && [ "$stdin_shell" = 1 ]; then
        _c_replace "$bodies" $'\036' $'\n'
        analyse "$REPLY" $((depth+1))
    fi
    return 0
}

# HIMMEL-4458: archive extraction writes members under its destination, and
# a member can be .himmel/state/bank-lift.json — a name no clause spells.
# Extraction into HOME, ~/.himmel or its state dir denies; so does one with no
# destination option whose effective cwd is one of those.

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

# _extract_allow <tar|gtar|bsdtar|unzip> <args...>: an extraction may
# use ONLY options the destination parser understands, or inert ones that
# cannot change where a member lands (HIMMEL-4458 r7). Anything else denies,
# long or short, bundled letters included: an option like --one-top-level=DIR
# moves members off the judged destination. Long options match whole names
# only (an abbreviation denies). Not listed, by design: -P/--absolute-names,
# --transform/--xform, --one-top-level, -h/--dereference.
_extract_allow() {
    local c="$1" a v ch sl vl first=1 skip=0
    shift
    case "$c" in
        tar|gtar|bsdtar) sl=xfCzjJvomkp; vl=fC ;;
        unzip) sl=oqndj; vl=d ;;
    esac
    for a in "$@"; do
        if [ "$skip" -gt 0 ]; then skip=$((skip-1)); first=0; continue; fi
        case "$a" in
            --) return 0 ;;
            -) first=0; continue ;;
            --*)
                case "$c:${a%%=*}" in
                    *tar:--extract|*tar:--get|*tar:--gzip|*tar:--gunzip|*tar:--bzip2|*tar:--xz|*tar:--zstd|*tar:--verbose|*tar:--no-same-owner|*tar:--no-same-permissions|*tar:--same-permissions|*tar:--preserve-permissions|*tar:--touch|*tar:--keep-old-files|*tar:--skip-old-files) ;;
                    *tar:--file|*tar:--directory|*tar:--strip-components)
                        case "$a" in *=*) ;; *) skip=1 ;; esac ;;
                    *) deny "$c extracts with ${a%%=*}, an option the destination check does not model (it may move members off the judged destination, e.g. into HOME or ~/.himmel); use only -x/-f/-C/-z/-j/-J/-v/-o/-m/-k/-p, --strip-components, --no-same-owner/--no-same-permissions (unzip: -o/-q/-n/-j/-d)" ;;
                esac
                first=0; continue ;;
            -*) v="${a#-}" ;;
            *) case "$c" in
                   tar|gtar|bsdtar) [ "$first" = 1 ] || continue; v="$a" ;;
                   *) first=0; continue ;;
               esac ;;
        esac
        # Bundled letters; a value letter takes the rest of a dashed bundle,
        # else the next word (old-style tar: one word per value letter).
        while [ -n "$v" ]; do
            ch="${v:0:1}"; v="${v:1}"
            case "$sl" in *"$ch"*) ;; *)
                deny "$c extracts with -$ch, an option the destination check does not model (it may move members off the judged destination, e.g. into HOME or ~/.himmel); use only -x/-f/-C/-z/-j/-J/-v/-o/-m/-k/-p, --strip-components, --no-same-owner/--no-same-permissions (unzip: -o/-q/-n/-j/-d)" ;;
            esac
            case "$vl" in *"$ch"*)
                if [ "${a:0:1}" = - ]; then
                    [ -n "$v" ] || skip=1
                    v=""
                else
                    skip=$((skip+1))
                fi ;;
            esac
        done
        first=0
    done
    return 0
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
    local c="$1" x=0 q="" a k first=1 n out=0 end=0 pend=0 u cwdchk=0 v ch dash amb args alld=0
    local abs=0 lst=0 cprev="" ksym=0 e wasfirst nonopt=0 nx=0 xe=0
    local -a dests=() pos=()
    shift
    # Mode allowlist: tar/gtar/bsdtar and unzip count as EXTRACTING unless a
    # non-extract mode is PROVEN by a real option word (not an operand, not a
    # word after a non-option or `--`, not after an unknown long option); an
    # old-style bundle (`tar tvf`) is read only as argv[1].
    case "$c" in tar|gtar|bsdtar|unzip) x=1 ;; esac
    case "$c" in
        tar) args=fCTXbI; amb=HKNVgFLs ;;
        gtar) args=fCTXbIHKNVgFL; amb="" ;;
        bsdtar) args=fCTXbIs; amb="" ;;
        unzip) args=dPOI; amb="" ;;
        cpio) args=FEHIODRMC; amb="" ;;
    esac
    for a in "$@"; do
        wasfirst=$first; first=0
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
            *tar:--extract|*tar:--get) xe=1; continue ;;
            cpio:--extract|cpio:--ext|cpio:--extr*) x=1; continue ;;
            # Only a full-spelled non-extract mode word proves the mode.
            *tar:--list|*tar:--create|*tar:--append|*tar:--update|*tar:--diff|*tar:--compare)
                [ "$u" = 1 ] || [ "$nonopt" = 1 ] || nx=1; continue ;;
            cpio:--pass-through|cpio:--pass*) x=1; continue ;;
            *tar:--to-stdout|cpio:--to-stdout) [ "$u" = 1 ] || [ "$nonopt" = 1 ] || out=1; continue ;;
            *tar:--directory=*|*tar:--dir*=*) _tar_dest "${a#*=}"; continue ;;
            cpio:--directory=*|cpio:--dir*=*) dests+=("${a#*=}"); continue ;;
            *tar:--abs*) abs=1; continue ;;
            *tar:--keep-d*) ksym=1; continue ;;
            cpio:--abs*) abs=1; continue ;;
            cpio:--no-abs*) continue ;;
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
            *tar:*) [ "$wasfirst" = 1 ] || { nonopt=1; continue; }
                    v="$a"; dash=0 ;;
            cpio:*) pos+=("$a"); continue ;;
            *) nonopt=1; continue ;;
        esac
        while [ -n "$v" ]; do
            ch="${v:0:1}"; v="${v:1}"
            case "$c:$ch" in
                *tar:x) xe=1; continue ;;
                cpio:i) x=1; continue ;;
                cpio:p) x=1; continue ;;
                *tar:[tcrud]) [ "$u" = 1 ] || [ "$nonopt" = 1 ] || nx=1; continue ;;
                *tar:O) [ "$u" = 1 ] || [ "$nonopt" = 1 ] || out=1; continue ;;
                *tar:P|unzip:[:]) abs=1; continue ;;
                cpio:t) lst=1; continue ;;
                unzip:[ltvZpc]) [ "$u" = 1 ] || [ "$nonopt" = 1 ] || x=0; continue ;;
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
    # -O / --to-stdout extracts to stdout, not to disk; cpio -t lists. A tar
    # with a proven non-extract mode and no explicit -x/--extract/--get does
    # not extract.
    [ "$lst" = 1 ] && x=0
    case "$c" in tar|gtar|bsdtar) [ "$nx" = 1 ] && [ "$xe" = 0 ] && x=0 ;; esac
    [ "$x" = 1 ] && [ "$out" = 0 ] || return 0
    EXTRACT_SEEN=1
    # GNU cpio keeps absolute and ../ member names by default, and its
    # pass mode copies whatever paths stdin names: every cpio extraction
    # denies, whatever the destination (--no-absolute-filenames not modelled).
    [ "$c" = cpio ] && deny "cpio extracts members by their own (absolute or ../) names, which can land on the bank lift whatever the destination; extract with tar or unzip into an absolute destination"
    [ "$XENV_SET" = 1 ] && deny "$c extracts while the command names TAR_OPTIONS/UNZIP/UNZIPOPT/ZIPINFO/ZIPINFOOPT, which can inject options (-P, -C, -:) the hook cannot see; pass the options on the $c command line"
    [ "$abs" = 1 ] && deny "$c keeps absolute (or ../) member names, so a member can land on the bank lift whatever the destination; drop -P/--absolute-names/--absolute-paths/-:"
    # ponytail: a symlink that ALREADY exists inside an allowed destination is
    # followed by default for a member's intermediate path (GNU tar without a
    # directory member, unzip, cpio) and is not judged here; one planted by the
    # SAME command is denied (HIMMEL-4530, closed). Upgrade path: a new ticket
    # if an agent can plant the link in an earlier command.
    [ "$ksym" = 1 ] && deny "$c --keep-directory-symlink follows a directory symlink inside the destination, which can lead into HOME or ~/.himmel; drop it"
    _extract_allow "$c" "$@"
    _dest_verdict "$c" "$cwdchk" ${dests[@]+"${dests[@]}"}
}

# _dest_verdict <tool> <cwd-dependent 0|1> <dest...>: the destination half of
# an extraction verdict (HIMMEL-5094 lifted it out of check_extract). With no
# destination, or when the cwd may matter, the cwd is judged; each destination
# is then judged against HOME, ~/.himmel and its state dir.
_dest_verdict() {
    local c="$1" cwdchk="$2" a k e n
    shift 2
    n=$#
    if [ "$n" = 0 ] || [ "$cwdchk" = 1 ]; then
        [ "$CWD_UNPROVEN" = 1 ] && deny "$c extracts into the cwd: $UNPROVEN_FIX"
        case "$(lift_ref "$CWD")" in
            LIFT|STATE|HIMMEL|HOME) deny "$c extracts into the cwd ($CWD), which is HOME or ~/.himmel" ;;
        esac
        _home_anc "$CWD" && deny "$c extracts into the cwd ($CWD), an ancestor of HOME: a relative member can reach the bank lift"
        [ "$n" = 0 ] && return 0
    fi
    for a in "$@"; do
        # A computed destination ($D, $(...), `...`; $HOME spellings resolve)
        # cannot be shown to stay off HOME: fail closed, like an unresolved cd.
        case "$(_expand "$a")" in
            *'$'*|*'`'*) deny "$c extracts into a computed destination ($a), which may be HOME or ~/.himmel; name a literal path" ;;
        esac
        _rel_unproven "$a" && deny "$c extracts into a relative destination ($a): $UNPROVEN_FIX"
        k=$(lift_ref "$a")
        case "$k" in
            LIFT|STATE|HIMMEL|HOME) deny "$c extracts into $a (HOME, ~/.himmel or its state dir), where a member can be the bank lift" ;;
        esac
        e=$(_expand "$a")
        _home_anc "$e" && deny "$c extracts into $a, an ancestor of HOME: a relative member (home/<user>/.himmel/state/...) can reach the bank lift"
    done
    return 0
}

# check_extract_coarse <7z|7za|7zr|7zz|pax|ar|jar|dpkg|dpkg-deb|unar> <args...>
# (HIMMEL-5094) Extractors check_extract does not model option by option: find
# the extraction mode and the destination operand/option, then judge them with
# _dest_verdict. pax -r (no copy destination) and 7z -spf keep members' own
# absolute names, so they deny whatever the destination.
check_extract_coarse() {
    local c="$1" a v ch mode=0 skip=0 first=1 rd=0 wr=0 spec=0
    local -a dests=() ops=()
    shift
    for a in "$@"; do
        if [ "$skip" = 1 ]; then skip=0; dests+=("$a"); continue; fi
        case "$c" in
            7z|7za|7zr|7zz)
                case "$a" in
                    -spf*) deny "$c -spf keeps absolute member names, so a member can land on the bank lift whatever the destination" ;;
                    -o?*) dests+=("${a#-o}") ;;
                    -*) ;;
                    *) if [ "$first" = 1 ]; then case "$a" in x|e|X) mode=1 ;; esac; first=0; fi ;;
                esac ;;
            pax)
                case "$a" in
                    --) ;;
                    -*) v="${a#-}"
                        while [ -n "$v" ]; do
                            ch="${v:0:1}"; v="${v:1}"
                            case "$ch" in r) rd=1 ;; w) wr=1 ;; s) spec=1 ;; esac
                        done ;;
                    *) ops+=("$a") ;;
                esac ;;
            ar)
                case "$a" in
                    --output=*) dests+=("${a#*=}") ;;
                    --output) skip=1 ;;
                    --*) ;;
                    -*) case "$a" in *x*) mode=1 ;; esac ;;
                    *) if [ "$first" = 1 ]; then case "$a" in *x*) mode=1 ;; esac; first=0; fi ;;
                esac ;;
            jar)
                case "$a" in
                    -x|--extract) mode=1 ;;
                    --dir=*) dests+=("${a#*=}") ;;
                    --dir|-C) skip=1 ;;
                    --*) ;;
                    *) if [ "$first" = 1 ]; then case "$a" in *x*) mode=1 ;; esac; first=0; fi ;;
                esac ;;
            dpkg|dpkg-deb)
                case "$a" in
                    -x|--extract|--vextract) mode=1 ;;
                    -X|-R|--raw-extract) mode=1 ;;
                    -*) ;;
                    *) ops+=("$a") ;;
                esac ;;
            unar)
                mode=1
                case "$a" in
                    -o|-output-directory|--output-directory) skip=1 ;;
                    -o?*) dests+=("${a#-o}") ;;
                esac ;;
        esac
    done
    case "$c" in
        pax)
            [ "$rd" = 1 ] || return 0
            EXTRACT_SEEN=1
            [ "$spec" = 1 ] && deny "pax -s rewrites member names, which can move them into HOME or ~/.himmel"
            [ "$wr" = 1 ] || deny "pax -r keeps members' own (absolute or ../) names, which can land on the bank lift whatever the destination; extract with tar or unzip into an absolute destination"
            [ "${#ops[@]}" -gt 0 ] && dests+=("${ops[${#ops[@]}-1]}") ;;
        dpkg|dpkg-deb)
            [ "$mode" = 1 ] && [ "${#ops[@]}" -ge 2 ] || return 0
            EXTRACT_SEEN=1
            dests+=("${ops[1]}") ;;
        *)
            [ "$mode" = 1 ] || return 0
            EXTRACT_SEEN=1 ;;
    esac
    _dest_verdict "$c" 0 ${dests[@]+"${dests[@]}"}
}

# check_interp_archive <args...>: `python -m tarfile|zipfile -e <archive>
# [<dest>]` extracts like tar/unzip (HIMMEL-5094).
check_interp_archive() {
    local a mod="" st=0 pre n=0 lt=0
    for a in "$@"; do
        if [ -z "$mod" ]; then
            if [ "$st" = 1 ]; then mod="$a"; continue; fi
            case "$a" in
                --*) ;;
                # -m, -mMOD, or -m inside a short-flag cluster (-Im, -Bm, -Imtarfile)
                -*m*)
                    pre="${a#-}"; pre="${pre%%m*}"
                    # Deny-list the argument-taking letters (c code, W warn, X
                    # impl): any other letter is a bare flag, so a flag this
                    # list forgets still reaches the module (fail closed).
                    case "$pre" in
                        *[!A-Za-z]*|*[cWX]*) ;;
                        *) if [ "${a#*m}" = "" ]; then st=1; else mod="${a#*m}"; fi ;;
                    esac ;;
            esac
            continue
        fi
        case "$a" in
            -l|--list|-t|--test) lt=1 ;;
            -*) n=1 ;;
        esac
    done
    # Any module named tarfile* or zipfile* (zipfile.__main__), or a computed
    # module name beside an archive word, may be the archive CLI (fail closed).
    case "$mod" in
        tarfile*|zipfile*) ;;
        *'$'*|*'`'*) [[ "$CMD" =~ $EXTRACT_WORD_RE ]] || return 0 ;;
        *) return 0 ;;
    esac
    # Only a pure list/test passes: every other option (-e and its
    # abbreviations, a combined cluster, --filter VALUE, create) denies, with no
    # operand modelling (fail closed).
    [ "$lt" = 1 ] && [ "$n" = 0 ] && return 0
    EXTRACT_SEEN=1
    deny "python -m $mod is allowed only as a pure list or test (-l/--list/-t/--test); any other form may extract into HOME or ~/.himmel"
}

# _homeish_word <word>: the word (or its -oVALUE / --opt=VALUE value) names
# HOME, ~/.himmel, its state dir or the lift.
_homeish_word() {
    local b
    for b in "$1" "${1#-?}" "${1#*=}"; do
        case "$(lift_ref "$b")" in NONE) ;; *) return 0 ;; esac
    done
    return 1
}

# _text_names_home <text>: some word of the text is a HOME bank-lift target
# (~, $HOME, the real HOME path itself, ~/.himmel, the state dir, or a bare
# /home or /Users). A path UNDER a user directory (a worktree) is not one,
# so the fail-closed rules below never fire on a bare /home/ substring.
_text_names_home() {
    local t w
    t="${1//[^[:alnum:]_.\/~\$\{\}:+=-]/ }"
    for w in $t; do
        case "$w" in
            /home|/home/|/Users|/Users/) return 0 ;;
            *'~'*|*HOME*|*/home*|*/Users*|*/root*|*.himmel*|"$HOME"*) _homeish_word "$w" && return 0 ;;
        esac
    done
    return 1
}

ENVC_RE='(^|[^A-Za-z0-9_.-])(env|sudo)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+-[^[:space:];&|]*[CD]'
# DYN_DIR_RE: env/sudo -C/-D inside any flag cluster (-iC, -0C), read on the
# whole text independent of the wrapper parse; the other directory-changing
# words come from the literal path's verdict (CWD_UNPROVEN, HIMMEL-5094).
DYN_DIR_RE='(^|[^A-Za-z0-9_.-])(cd|pushd|popd)([^A-Za-z0-9_.-]|$)|CDPATH|chdir|(^|[^A-Za-z0-9_.-])(env|sudo)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+-[^[:space:];&|]*[CD]'

# _dyn_ctx: classify the whole command ONCE (cached in DYN_CTX): no archive
# word (none), a cwd at HOME or the bank-lift dir (cwd), any directory-changing
# word (dir), else archive (arc). Per-clause work stays constant (perf).
DYN_CTX=""
SEP=$'\037'
DYN_SAFE="$SEP"
_dyn_ctx() {
    [ -z "$DYN_CTX" ] || return 0
    DYN_CTX=none
    [[ "$CMD" =~ $EXTRACT_WORD_RE ]] || return 0
    DYN_CTX=arc
    case "$(_dir_kind "$CWD")" in HOME|HIMMEL|STATE) DYN_CTX=cwd; return 0 ;; esac
    # The literal path's cwd verdict (CWD_UNPROVEN: DIRWORD_RE over the raw text
    # and the dequoted tokens), plus env/sudo -C/-D in any flag cluster.
    local wt="${WTOK//$SEP/ }"
    if [ "$CWD_UNPROVEN" = 1 ] || [[ "$CMD" =~ $DYN_DIR_RE ]] || [[ "$wt" =~ $DYN_DIR_RE ]]; then DYN_CTX=dir; fi
    return 0
}

# _dyn_cmd_check <command-word> <args...>: a command word held in a variable
# or substitution cannot be read (HIMMEL-5094). It denies when an argument
# names HOME/~/.himmel, or when the command also names an archive tool and
# there is a cwd at HOME or the bank-lift dir, ANY directory-changing word, or
# ANY computed argument. Fail closed, no operand parsing: the literal-tool
# path's verdict, applied to a command word it cannot read.
_dyn_cmd_check() {
    local w="$1" a dynarg=0
    shift
    # Cheap pre-check (no subshell): a literal command word has no $ or backtick.
    case "$w" in *'$'*|*'`'*) ;; *) return 0 ;; esac
    case "$(_expand "$w")" in *'$'*|*'`'*) ;; *) return 0 ;; esac
    for a in "$@"; do
        # A word already judged not HOME-ish is not judged again (the cwd is
        # fixed for the command), so a long chain pays once per distinct word.
        if [[ "$DYN_SAFE" != *"$SEP$a$SEP"* ]]; then
            _homeish_word "$a" && deny "a command word held in a variable or substitution ($w) is handed HOME or ~/.himmel ($a), so it may be an extractor; name the command literally"
            DYN_SAFE="$DYN_SAFE$a$SEP"
        fi
        _is_dynamic "$a" && dynarg=1
    done
    _dyn_ctx
    case "$DYN_CTX" in
        cwd) deny "a command word held in a variable or substitution ($w) runs beside an archive tool in HOME or the bank-lift dir, so it may extract there; name the command literally" ;;
        dir) deny "a command word held in a variable or substitution ($w) runs beside an archive tool and a directory-changing word (cd, pushd, popd, CDPATH, env -C, sudo -D), so the cwd is unknown and it may extract into HOME; name the command and destination literally" ;;
        arc) if [ "$dynarg" = 1 ]; then
                deny "a command word held in a variable or substitution ($w) is handed a computed argument beside an archive tool, so it may extract into HOME; name the command and destination literally"
            fi ;;
    esac
    return 0
}

# _wrapped_extract <depth> <fed> <command-word> <args...>: an UNKNOWN command
# (strace, fakeroot, unshare, nsenter, …) may wrap an extractor. Every later
# word that is an archive tool, with at least one argument after it, is judged
# as if it were the command (HIMMEL-5094). Over-matches by design: it can only
# add a deny, and only when the tool would itself deny.
_wrapped_extract() {
    local depth="$1" fed="$2" j k n nx cf crc wrc=0
    shift 2
    local -a ws=("$@")
    n=${#ws[@]}; j=1
    while [ "$j" -lt "$n" ]; do
        nx=$((j+1))
        _lb "${ws[j]}"
        if [[ "$R" =~ $SHELL_RE ]]; then
            # A shell run under an unmodelled wrapper: its -c text is
            # analysed as if the wrapper were not there; with no -c it reads
            # its script from stdin or a file, so the clause is judged whole
            # and a stdin shell (rc 10) is reported to the caller.
            cf=0; k=$nx
            while [ "$k" -lt "$n" ]; do
                case "${ws[k]}" in
                    --) break ;;
                    -c*|-[a-zA-Z]*c*|--command) cf=1; break ;;
                esac
                k=$((k+1))
            done
            check_clause "$depth" "$fed" "${ws[@]:j}"; crc=$?
            [ "$cf" = 0 ] && [ "$crc" = 10 ] && wrc=10
        elif [ "$nx" -lt "$n" ]; then
            if [ "$R" = eval ]; then
                check_clause "$depth" "$fed" "${ws[@]:j}"
            elif [[ "$R" =~ $EXTRACT_CMD_RE ]]; then
                check_clause "$depth" "$fed" "${ws[@]:j}"
            elif [[ "$R" =~ $INTERP_RE ]]; then
                k=$nx
                while [ "$k" -lt "$n" ]; do
                    case "${ws[k]}" in *tarfile*|*zipfile*) check_clause "$depth" "$fed" "${ws[@]:j}"; break ;; esac
                    k=$((k+1))
                done
            fi
        fi
        j=$((j+1))
    done
    return "$wrc"
}

# _symlink_mode <cmd> <args...>: flag a clause that creates a symlink (ln -s /
# --symbolic, cp -s / --symbolic-link, combined short flags too) so a
# same-command extraction can be denied (HIMMEL-4530). An operand starting
# with a dash and holding an s over-matches by design: it only adds a deny.
# Every word is scanned, `--` included: GNU accepts unique long-option prefixes
# (--sym, --sy) and a `--` can be the value of -S/--suffix/-t, so stopping at
# one would hide a later -s.
_symlink_mode() {
    local c="$1" a
    shift
    case "$c" in ln|cp) ;; *) return 0 ;; esac
    for a in "$@"; do
        case "$a" in
            --sy*) SYMLINK_SEEN=1 ;;
            --*) ;;
            -*s*) SYMLINK_SEEN=1 ;;
        esac
    done
}

# check_clause <depth> <fed> <args...> — returns 10 when the clause is a shell
# reading its script from stdin (heredoc bodies then get analysed), 11 for an
# interpreter (already decided here).
check_clause() {
    local depth="$1" fed="$2"; shift 2
    local w cmd a v rc=0 wrapped_rc=0
    # Command-position walk: keywords, assignments, wrappers.
    while [ $# -gt 0 ]; do
        w="$1"
        case "$w" in
            '{'|'}'|'!'|if|then|else|elif|do|while|until|fi|done|coproc|builtin|nohup|setsid|unbuffer|caffeinate)
                shift; continue ;;
            # HIMMEL-5094: `function NAME [()] {` — skip the keyword and name.
            function) shift; [ $# -gt 0 ] && shift; [ "${1:-}" = '()' ] && shift; continue ;;
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
    _dyn_cmd_check "$w" "$@"

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
        check_interp_archive "$@"
        if [ "$inline" = 1 ]; then
            code=$(_lower "$* $CUR_BODIES")
            code="${code//\\/}"
            # HIMMEL-5094: an interpreter one-liner that creates a link counts
            # as a symlink creation beside any extraction in the command.
            # A symlink CALL counts (a quoted word does not); `ln -s` / mklink
            # text counts only beside a HOME word (j2243a).
            if [[ "$code" =~ $SYMCALL_RE ]]; then
                SYMLINK_SEEN=1
            elif [[ "$code" =~ (^|[^a-z0-9_])ln[^a-z0-9_]+(-[a-z-]*s|--sym)|mklink ]] && _text_names_home "$CMD"; then
                SYMLINK_SEEN=1
            fi
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
            _symlink_mode "${cmd#g}" "$@"
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
                bsdcpio) check_extract cpio "$@" ;;
                7z|7za|7zr|7zz|pax|ar|jar|dpkg|dpkg-deb|unar) check_extract_coarse "$cmd" "$@" ;;
                *) if ! [[ "$cmd" =~ $READ_RE ]] && ! [[ "$cmd" =~ $NOSCAN_RE ]]; then
                       _wrapped_extract "$depth" "$fed" "$w" "$@" || wrapped_rc=$?
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
    return "$wrapped_rc"
}

# Layer 1: the whole-command mention rule (J1874). The trigger reads both the
# raw text and the dequoted tokens (quote splits, $'..', heredoc bodies).
WTOK=$(printf '%s' "$CMD" | LC_ALL=C awk -v STRICT=1 "$TOKENIZER") || deny "command tokenizer failed (fail-closed)"
# HIMMEL-4458: the cwd is never modelled through shell control flow. It is the
# hook's own cwd unless a directory-changing word appears ANYWHERE in the raw
# text or the dequoted tokens; then it is unknown for the whole command, and a
# relative destination of an extraction or copy denies (_rel_unproven). Erring
# toward unproven is the design. grep -c reads all input: a -q early exit would
# SIGPIPE printf on a big command and, under pipefail, read a hit as none.
_c_replace "$WTOK" $'\037' ' '
WTOK_SP=$REPLY
cwd_hits=$(printf '%s\n%s' "$CMD" "$WTOK_SP" | grep -Ec "$DIRWORD_RE")
case "$cwd_hits" in ''|0) ;; *) CWD_UNPROVEN=1 ;; esac
xenv_hits=$(printf '%s\n%s' "$CMD" "$WTOK_SP" | grep -Ec "$XENV_RE")
case "$xenv_hits" in ''|0) ;; *) XENV_SET=1 ;; esac
if names_lift "$CMD" || names_lift "$WTOK"; then whole_command_gate "$CMD" 0; fi
# HIMMEL-5094: env/sudo -C/-D in any flag cluster (-iC, -0C), read on the whole
# text independent of the wrapper parse, beside an archive word and a computed
# word: the parse may mistake the directory for the command, so the computed
# word is never read as the extractor. Fail closed.
if [[ "$CMD" =~ $ENVC_RE ]] || [[ "$WTOK_SP" =~ $ENVC_RE ]]; then
    if [[ "$CMD" =~ $EXTRACT_WORD_RE ]] && [[ "$CMD" == *['$`']* ]]; then
        deny "env/sudo with a -C/-D directory option beside an archive tool and a computed word: the cwd is unknown and the computed word may be the extractor; name the command and destination literally"
    fi
fi
analyse "$CMD" 0
# HIMMEL-4530: an extraction and a symlink creation in one command, in any
# order, can send members through the planted link into HOME.
if [ "$EXTRACT_SEEN" = 1 ] && [ "$SYMLINK_SEEN" = 1 ]; then
    deny "the command extracts an archive and creates a symlink (ln -s / cp -s), so members can follow the link into HOME or ~/.himmel; create the link in a separate command, away from the extraction destination"
fi
exit 0
