#!/usr/bin/env bash
# PreToolUse Bash guard — bounce jira CLI WRITE verbs in shapes that would
# otherwise fall through to the auto-mode classifier (HIMMEL-1077).
#
# WHY: jira CLI writes are operator-sanctioned (HIMMEL-205 allow-lists them,
# auto-approve-safe-bash.sh grants them explicitly). But approval is decided on
# command SHAPE: the moment a sanctioned `create` is wrapped in `$(…)`, a
# heredoc, or chained with a segment the gateway cannot vet, the gateway stays
# silent and the call falls through to the auto-mode classifier — which judges
# the write cold and denies it as "[External System Writes] unrequested
# publishing". Incident (2026-07-16): two sanctioned creates denied inside a
# compound chain; the identical creates as literal single commands were
# auto-approved seconds later. Root cause = shape, not permission (HIMMEL-203).
#
# This hook converts that opaque, non-actionable denial into a deterministic
# bounce that names the ONE sanctioned retry shape. Naming exactly one shape is
# deliberate: a second failure mode from the same incident had paced retries
# (Write, then a Bash heredoc of the same content) read as "[Auto Mode Bypass]"
# tool-shopping. An agent that is told the single correct next command does not
# probe.
#
# CONTRACT — the guard never widens and never narrows the gateway:
#   * It bounces ONLY commands the auto-approve gateway would NOT approve. The
#     gateway is consulted as a subprocess (single source of truth — no forked
#     copy of its safety model to drift). Gateway approves → this hook is
#     silent, the command runs exactly as it does today.
#   * Literal single jira writes (bare or `cd`-prefixed) are gateway-approved,
#     so they are never touched — that is the sanctioned shape.
#   * jira READ verbs are never bounced.
#
# Fail OPEN (exit 0) on anything we cannot evaluate — missing jq, unparseable
# input, no gateway script. A guard whose job is to improve a denial message
# must never become the reason a sanctioned write cannot run.
#
# KNOWN, DELIBERATE GAP — a QUOTED CLI path (`node "/c/Users/John Smith/…/index.js"
# create …`) is blanked by quote_mask, so this guard does not detect it and stays
# silent. That is the correct behaviour, not an oversight: the gateway cannot vet
# a quoted binary either (it tokenises on spaces, so `"path` never matches the
# CLI), which means a checkout whose path contains whitespace has NO
# gateway-approvable jira shape at all — even a literal single write. Bouncing it
# with "issue ONE literal command" would be advice the agent has already followed
# and cannot act on — an unactionable loop, the exact failure this guard exists to
# remove. Staying silent leaves the pre-HIMMEL-1077 status quo (classifier judges
# it) instead of making it worse. The upstream gap is HIMMEL-1083.
#
# Same class, same reasoning — a QUOTED VERB (`… index.js "create" …`) is masked
# as data and not detected. Valid bash, but a shape nothing here writes; making
# quoted spans visible is what would let `grep 'index.js create'` false-bounce, so
# the trade is deliberate.
#
# The other deliberate misses, all for the same reason — the scanner is flat, and a
# guess it cannot justify risks ordering a write the command never made:
#   * CONDITIONAL writes (`a && …`, `a || …`, if/while/for/case bodies). The retry
#     guidance is unconditional, so it would strip the condition. Everything from the
#     first `&&`/`||` to the END of the command goes out of scope — which also drops
#     an unconditional write after a later `;` (`false && echo skip; node … create`).
#     Truncating per-STATEMENT instead would catch that, but a conditional RHS can be
#     a group whose body spans separators (`false && { echo; node … create; }`), and
#     group parens are blanked by then — so the two are indistinguishable here and the
#     narrower rule would bounce a write bash never runs. Wrong block > miss in cost,
#     so the whole tail goes.
#   * Function DEFINITIONS — a definition anywhere disables detection for the WHOLE
#     command, so `f(){ :; }; node … create …` (an unconditional write after one) and
#     `deploy() { node … create; }; deploy` (define-then-invoke, which really writes)
#     are both missed. Scoping to the body needs brace tracking, and telling a real
#     invocation from a definition needs call-graph reasoning; a flat scanner would
#     have to guess, and guessing here is what orders writes that never happened.
#     Defining a shell function in the same call as a jira write is not a shape
#     anything in this repo produces.
#   * ERREXIT / `set -e` reachability (`set -e; false; node … create`). Whether a
#     preceding command FAILS (and so aborts the chain under errexit, leaving a later
#     write unreachable) is a RUNTIME fact — none of it has run when this PreToolUse
#     hook fires — so a flat scanner cannot prove the write unreachable. The
#     codex-adversarial "fail open for every statement after `set -e`" fix is WRONG
#     here: the common `set -e; node …/jira create --desc "$(…)"` is fully reachable
#     (nothing before it fails) and SHOULD bounce, and blanket post-`set -e`
#     fail-open would neuter the guard for exactly that shape. Accepted flat-scanner
#     limitation; the real reachability fix is a shell AST (separate, larger work).
#   * Multiple heredocs on a line, unparseable delimiters, whitespace CLI paths.
# Every gap forfeits GUIDANCE only — the write keeps its pre-HIMMEL-1077 classifier
# denial, exactly as before this hook existed. None can produce a wrong block.
#
# Bypass (set in the shell that LAUNCHED Claude Code; a per-call prefix does
# NOT reach the hook process):
#   JIRA_COMPOUND_WRITE_OK=1 claude
#
# Exit codes: 0 — allow;  2 — bounce (stderr shown to Claude and the user).
# bash 3.2-compatible (no mapfile / associative arrays).
set -uo pipefail

# Write verbs on the jira CLI: everything that mutates Jira state, per the CLI's
# own command surface. Read verbs (get/list/transitions/transition*s*/projects/
# attachments/watchers/boards/sprints/worklog list/…) are deliberately absent, as
# is `download` (writes local disk, not Jira).
#
# The list is static, not introspected from the CLI: this hook fires on EVERY
# Bash call, and shelling out to `node …/index.js --list-commands` per call (the
# block-backend-tier approach, which fires only on rare MCP calls) would tax the
# hot path. Drift risk is bounded — a verb missing here only means the write
# keeps its pre-HIMMEL-1077 opaque denial, never a wrong block. Keep in sync when
# the CLI gains a mutating verb.
#
# $1 = verb, $2 = following token (for nested verbs: `worklog add` writes,
# `worklog list` reads).
is_write_verb() {
    case "$1" in
        create|comment|transition|edit|link|assign|move|watch|unwatch) return 0 ;;
        attach|project-create|sprint) return 0 ;;
        worklog) case "${2:-}" in add) return 0 ;; esac ;;
    esac
    return 1
}

# Blank every DATA span, so tokens that are data — `grep 'index.js create' …`, a
# comment body that happens to contain the word "create" — cannot be mistaken for
# the CLI's verb. What survives is CODE, which is where a real verb lives.
#
# Data vs code is not the same as quoted vs unquoted: a `$(…)`/backtick
# substitution inside DOUBLE quotes is code the shell runs, so a write nested
# there (`key="$(node …/index.js create …)"` — the realistic capture-the-new-key
# shape) must stay visible. Single quotes admit no substitution, so their spans
# are always data. Hence the state stack: entering a substitution pushes the
# surrounding state and resumes code scanning; its closer pops back.
# bash 3.2-safe: only ${s:i:1}, ${#s}, arithmetic, an indexed array + counter.
# Is line "$1" the heredoc's closing delimiter? Bash is strict: the line must be
# EXACTLY the delimiter — a space-indented `  EOF` does NOT close a `<<EOF` body
# (verified 2026-07-16). Only `<<-` allows leading TABS. Trailing \r is stripped
# as a line-ending artifact, not content (CRLF commands).
# Reads hd / hd_dash from the caller's scope.
hd_is_close() {
    local ln="$1"
    # Strip EVERY trailing CR: line-ending artifact, not content. (One is the
    # usual CRLF; an MSYS text-mode redirect of already-CRLF text yields \r\r\n.
    # Leaving any behind means the delimiter never matches and the body silently
    # swallows the rest of the command — including a real write.)
    while [ "${ln%$'\r'}" != "$ln" ]; do ln="${ln%$'\r'}"; done
    [ "$hd_dash" = 1 ] && ln="${ln#"${ln%%[!$'\t']*}"}"
    [ "$ln" = "$hd" ]
}

quote_mask() {
    local s="$1" n i c nx st out top pv hd hd_set ln j hd_q hd_dash ad dq
    local -a stk
    local sp=0
    # hd_set, not `-n "$hd"`, marks "a heredoc is pending": `<<''` is a legal EMPTY
    # delimiter, and testing the delimiter's emptiness would read that as no-heredoc
    # and scan its inert body as code.
    n=${#s}; i=0; st=0; out=""; pv=""; hd=""; hd_set=0; hd_q=0; hd_dash=0; ad=0
    while [ "$i" -lt "$n" ]; do
        c="${s:$i:1}"
        nx="${s:$((i + 1)):1}"
        pv=""; [ "$i" -gt 0 ] && pv="${s:$((i - 1)):1}"
        if [ "$st" = 1 ]; then                     # single quotes — always data
            [ "$c" = "'" ] && st=0
            out="$out "; i=$((i + 1)); continue
        fi
        if [ "$st" = 6 ]; then
            # Inside `${…}` — parameter expansion text is DATA. (A `$(…)` nested in a
            # default value does run, but bash requires it to be written `${x:-$(cmd)}`
            # and that shape is beyond this flat scanner: masking it is a MISS, never
            # a wrong block, which is the safe side.)
            case "$c" in
                '{') ad=$((ad + 1)) ;;
                '}') ad=$((ad - 1)); [ "$ad" -le 0 ] && st=0 ;;
            esac
            out="$out "; i=$((i + 1)); continue
        fi
        if [ "$st" = 5 ]; then
            # Inside ARITHMETIC — `$((…))` or the `((…))` command. Bash EVALUATES
            # arithmetic here; it executes nothing, so the text is data. Without this
            # the `$(`+`(` pair read as a substitution around a subshell and
            # `x=$((node …/index.js create))` bounced with guidance to perform a write
            # the command never ran.
            # A SUBSTITUTION among the operands still runs, though — `$(( $(node …
            # create) + 1 ))` really writes — so it stays visible, same rule as
            # everywhere else. (Nested `$((…))` needs no case: its parens just count.)
            if [ "$c" = '$' ] && [ "$nx" = '(' ] && [ "${s:$((i + 2)):1}" != '(' ]; then
                stk[sp]="5p"; sp=$((sp + 1)); st=0
                out="$out"$'\n'" "; i=$((i + 2)); continue
            fi
            if [ "$c" = '`' ]; then
                stk[sp]="5b"; sp=$((sp + 1)); st=0
                out="$out"$'\n'; i=$((i + 1)); continue
            fi
            case "$c" in
                '(') ad=$((ad + 1)) ;;
                ')') ad=$((ad - 1))
                     if [ "$ad" -le 0 ]; then
                         # Return to whatever state opened this arithmetic span:
                         # inside "…" it must stay quoted data, not code.
                         st=0
                         if [ "$sp" -gt 0 ]; then
                             top="${stk[$((sp - 1))]}"
                             case "$top" in
                                 *a) sp=$((sp - 1)); st="${top%a}" ;;
                             esac
                         fi
                     fi ;;
                '$') : ;;   # a bare `$…` operand (e.g. $x) is just data
            esac
            out="$out "; i=$((i + 1)); continue
        fi
        if [ "$st" = 4 ]; then
            # Inside an ARRAY assignment `args=( … )`. Bash CONSTRUCTS an array
            # here — it executes nothing — so the words are data. Without this,
            # `args=(node …/index.js create …)` looked like a node command (the
            # `args=` prefix reads as a leading assignment) and got bounced with
            # guidance to file a ticket the command never attempted.
            # A substitution among the elements IS still executed, so it stays
            # visible — same rule as everywhere else: data is masked, code is not.
            if [ "$c" = '$' ] && [ "$nx" = '(' ] && [ "${s:$((i + 2)):1}" = '(' ]; then
                stk[sp]="4a"; sp=$((sp + 1)); ad=2; st=5   # arithmetic → data
                out="$out   "; i=$((i + 3)); continue
            fi
            if [ "$c" = '$' ] && [ "$nx" = '(' ]; then
                stk[sp]="4p"; sp=$((sp + 1)); st=0
                out="$out"$'\n'" "; i=$((i + 2)); continue
            fi
            if [ "$c" = '`' ]; then
                stk[sp]="4b"; sp=$((sp + 1)); st=0
                out="$out"$'\n'; i=$((i + 1)); continue
            fi
            case "$c" in
                '(') ad=$((ad + 1)) ;;
                ')') ad=$((ad - 1)); [ "$ad" -le 0 ] && st=0 ;;
            esac
            out="$out "; i=$((i + 1)); continue
        fi
        if [ "$st" = 3 ]; then
            # Body of an UNQUOTED heredoc (`<<EOF`): bash expands substitutions
            # inside it, so it is expandable text — like a double-quoted string,
            # except literal quotes do not change state and it ends at the
            # delimiter LINE (a quoted `<<'EOF'` body never gets here: it is inert
            # data, blanked wholesale below).
            if [ "$c" = "\\" ]; then out="$out  "; i=$((i + 2)); continue; fi
            if [ "$c" = '$' ] && [ "$nx" = '(' ] && [ "${s:$((i + 2)):1}" = '(' ]; then
                stk[sp]="3a"; sp=$((sp + 1)); ad=2; st=5   # arithmetic → data
                out="$out   "; i=$((i + 3)); continue
            fi
            if [ "$c" = '$' ] && [ "$nx" = '(' ]; then
                stk[sp]="3p"; sp=$((sp + 1)); st=0
                out="$out"$'\n'" "; i=$((i + 2)); continue
            fi
            if [ "$c" = '`' ]; then
                stk[sp]="3b"; sp=$((sp + 1)); st=0
                out="$out"$'\n'; i=$((i + 1)); continue
            fi
            if [ "$c" = $'\n' ]; then
                # Peek the next line: the delimiter ends the body.
                j=$((i + 1)); ln=""
                while [ "$j" -lt "$n" ] && [ "${s:$j:1}" != $'\n' ]; do
                    ln="$ln${s:$j:1}"; j=$((j + 1))
                done
                if hd_is_close "$ln"; then
                    # Keep this line break as a REAL newline: it separates the
                    # heredoc from whatever command follows, and downstream
                    # tokenisation needs that boundary to see the next command in
                    # COMMAND POSITION. Blank the delimiter line itself.
                    out="$out"$'\n'; i=$((i + 1))
                    while [ "$i" -lt "$j" ]; do out="$out "; i=$((i + 1)); done
                    st=0; hd=""; hd_set=0; continue
                fi
                out="$out "; i=$((i + 1)); continue
            fi
            out="$out "; i=$((i + 1)); continue
        fi
        if [ "$st" = 2 ]; then                     # double quotes — data, but
            if [ "$c" = "\\" ]; then out="$out  "; i=$((i + 2)); continue; fi
            if [ "$c" = '$' ] && [ "$nx" = '(' ] && [ "${s:$((i + 2)):1}" = '(' ]; then
                stk[sp]="2a"; sp=$((sp + 1)); ad=2; st=5   # "$((…))" → arithmetic, data
                out="$out   "; i=$((i + 3)); continue
            fi
            if [ "$c" = '$' ] && [ "$nx" = '(' ]; then     # …$( → code
                stk[sp]="2p"; sp=$((sp + 1)); st=0
                out="$out"$'\n'" "; i=$((i + 2)); continue
            fi
            if [ "$c" = '`' ]; then                        # …` → code
                stk[sp]="2b"; sp=$((sp + 1)); st=0
                out="$out"$'\n'; i=$((i + 1)); continue
            fi
            [ "$c" = '"' ] && st=0
            out="$out "; i=$((i + 1)); continue
        fi
        # --- st=0: code ---
        if [ "$c" = "\\" ]; then out="$out  "; i=$((i + 2)); continue; fi
        case "$c" in
            "'") st=1; out="$out "; i=$((i + 1)); continue ;;
            '"') st=2; out="$out "; i=$((i + 1)); continue ;;
        esac
        # A `#` starting a word begins a comment — data to end of line.
        if [ "$c" = '#' ] && [ "$pv" != "$c" ]; then
            case "$pv" in
                ''|' '|$'\t'|$'\n'|';'|'&'|'|'|'('|')')
                    while [ "$i" -lt "$n" ] && [ "${s:$i:1}" != $'\n' ]; do
                        out="$out "; i=$((i + 1))
                    done
                    continue ;;
            esac
        fi
        # `<<[-]DELIM` opens a heredoc. Whether its BODY is inert data depends on
        # the DELIMITER: `<<'EOF'` (quoted) is literal text — a doc block that
        # merely MENTIONS the CLI must never read as an invocation — while `<<EOF`
        # (unquoted) still expands `$(…)`/backticks, so a write nested there really
        # runs and must stay visible. Record the delimiter and which kind it is.
        # `<<<` is a here-string (one word, no body) — not a heredoc.
        if [ "$c" = '<' ] && [ "$nx" = '<' ] && [ "${s:$((i + 2)):1}" != '<' ]; then
            # `cmd <<A <<B` queues TWO bodies, in order. This scanner tracks ONE
            # delimiter, so a second heredoc on the same line would silently reuse
            # the wrong metadata — which could end a body early and scan inert text
            # as code, i.e. a wrong block. Refuse to guess: unparseable → fail open
            # (the write keeps its pre-HIMMEL-1077 denial, nothing gets worse). A
            # real delimiter queue is not worth it for a shape nothing here writes.
            [ "$hd_set" = 1 ] && return 1
            i=$((i + 2)); out="$out  "; hd_q=0; hd_dash=0; hd_set=1
            [ "${s:$i:1}" = '-' ] && { hd_dash=1; out="$out "; i=$((i + 1)); }
            # Bash allows spaces OR tabs between << and the delimiter.
            while [ "$i" -lt "$n" ]; do
                case "${s:$i:1}" in
                    ' '|$'\t') out="$out "; i=$((i + 1)) ;;
                    *) break ;;
                esac
            done
            # Read the delimiter WORD. Quoting it any way — <<'EOF', <<"EOF", <<\EOF
            # — makes the body inert, and the quotes/escapes are not part of the
            # delimiter TEXT. Recording a SHORT delimiter is a wrong-block bug: a body
            # line matching the truncated prefix would close the body early and expose
            # inert text to command scanning. So separators end the word only OUTSIDE
            # quotes (`<<'END MARK'` is the single delimiter `END MARK`), and an
            # escaped character is consumed into it (`<<END\;X` is `END;X`).
            # `<<$'EOF'` / `<<$"EOF"` are ANSI-C / locale quoting forms this scanner
            # does not decode: it would record a wrong delimiter, the body would never
            # close, and the rest of the command would be masked as body. Fail open.
            case "${s:$i:1}" in '$') return 1 ;; esac
            hd=""; dq=""
            while [ "$i" -lt "$n" ]; do
                c="${s:$i:1}"
                if [ -n "$dq" ]; then                  # inside the delimiter's quotes
                    if [ "$c" = "$dq" ]; then dq=""; else hd="$hd$c"; fi
                    out="$out "; i=$((i + 1)); continue
                fi
                case "$c" in
                    # \r ends it too: a CRLF command would otherwise capture the
                    # delimiter as "EOF<CR>", never match the body's closing line, and
                    # blank the REST OF THE COMMAND as body — silently swallowing the
                    # real write that follows it.
                    $'\n'|$'\r'|' '|$'\t'|';'|'&'|'|'|'>') break ;;
                    "\\")
                        # Escapes the NEXT character into the delimiter. A trailing
                        # lone backslash has nothing to escape: unparseable, fail open.
                        hd_q=1
                        i=$((i + 1)); out="$out "
                        [ "$i" -lt "$n" ] || return 1
                        hd="$hd${s:$i:1}" ;;
                    "'"|'"') hd_q=1; dq="$c" ;;
                    *) hd="$hd$c" ;;
                esac
                out="$out "; i=$((i + 1))
            done
            [ -n "$dq" ] && return 1        # unterminated quote in the delimiter
            continue
        fi
        # End of the line that opened a heredoc → the body starts. An UNQUOTED
        # delimiter means the body still expands substitutions: hand it to st=3
        # rather than blanking it wholesale.
        if [ "$c" = $'\n' ] && [ "$hd_set" = 1 ] && [ "$hd_q" != 1 ]; then
            out="$out"$'\n'; i=$((i + 1)); st=3; continue
        fi
        # Quoted delimiter → inert body: blank through the delimiter line, then
        # resume normal scanning after it.
        if [ "$c" = $'\n' ] && [ "$hd_set" = 1 ]; then
            # Line breaks around the body stay REAL newlines: they separate the
            # heredoc from the command that follows, and downstream tokenisation
            # needs those boundaries to see it in COMMAND POSITION. Only the body
            # CONTENT is blanked.
            out="$out"$'\n'; i=$((i + 1))
            while [ "$i" -lt "$n" ]; do
                ln=""
                while [ "$i" -lt "$n" ] && [ "${s:$i:1}" != $'\n' ]; do
                    ln="$ln${s:$i:1}"; out="$out "; i=$((i + 1))
                done
                [ "$i" -lt "$n" ] && { out="$out"$'\n'; i=$((i + 1)); }
                hd_is_close "$ln" && break
            done
            hd=""; hd_set=0; continue
        fi
        # `${…}` is a PARAMETER expansion: its text is data, not commands. Without
        # this, a `;` inside one (`echo ${x:-a; node …/index.js create --title y}`)
        # split off a bogus statement that read as a real write and got bounced.
        if [ "$c" = '$' ] && [ "$nx" = '{' ]; then
            ad=1; st=6; out="$out  "; i=$((i + 2)); continue
        fi
        # Arithmetic first: `$((` is arithmetic EXPANSION, not `$(` around a subshell,
        # and a bare `((` is the arithmetic COMMAND. Both evaluate, neither executes.
        if [ "$c" = '$' ] && [ "$nx" = '(' ] && [ "${s:$((i + 2)):1}" = '(' ]; then
            ad=2; st=5; out="$out   "; i=$((i + 3)); continue
        fi
        if [ "$c" = '(' ] && [ "$nx" = '(' ]; then
            ad=2; st=5; out="$out  "; i=$((i + 2)); continue
        fi
        if [ "$c" = '$' ] && [ "$nx" = '(' ]; then
            # `FOO=$(…)` is an assignment VALUE: a command may still follow it
            # (`FOO=$(date) node … create`), so that frame must not plant the
            # command-position sentinel on the tail. An ARGUMENT substitution
            # (`echo "$(…)" node …`) must — see the pop.
            if [ "$pv" = '=' ]; then stk[sp]="0P"; else stk[sp]="0p"; fi
            sp=$((sp + 1)); out="$out"$'\n'" "; i=$((i + 2)); continue
        fi
        # `name=(` opens an ARRAY assignment: its words are DATA, not a command.
        if [ "$c" = '(' ] && [ "$pv" = '=' ]; then
            ad=1; st=4; out="$out "; i=$((i + 1)); continue
        fi
        # `<(…)` / `>(…)` are PROCESS substitutions: the command inside really runs,
        # exactly like `$(…)`. Give them the same frame so the body is scanned as the
        # command it is (`read k < <(node …/index.js create …)` really writes).
        if { [ "$c" = '<' ] || [ "$c" = '>' ]; } && [ "$nx" = '(' ]; then
            stk[sp]="0p"; sp=$((sp + 1))
            out="$out"$'\n'" "; i=$((i + 2)); continue
        fi
        # `name()` / `name ( )` at CODE level opens a function DEFINITION (it defines,
        # it never executes). Detect it structurally here rather than by searching the
        # raw command for "()": that substring also occurs inside quoted DATA, so a
        # perfectly ordinary `--title 'Fix parse()'` disabled the whole guard.
        if [ "$c" = '(' ]; then
            j=$((i + 1))
            while [ "$j" -lt "$n" ]; do            # bash allows any blank in `f ( )`
                case "${s:$j:1}" in
                    ' '|$'\t') j=$((j + 1)) ;;
                    *) break ;;
                esac
            done
            [ "${s:$j:1}" = ')' ] && FN_DEF=1
        fi
        # A plain `(` is subshell GROUPING, not a substitution — but it still
        # consumes a `)`. Give it its own frame, or `$( (…) )` pops the
        # substitution at the inner paren and masks the rest of it.
        if [ "$c" = '(' ]; then
            stk[sp]="0g"; sp=$((sp + 1)); out="$out "; i=$((i + 1)); continue
        fi
        if [ "$c" = ')' ] && [ "$sp" -gt 0 ]; then
            top="${stk[$((sp - 1))]}"
            case "$top" in
                *g) sp=$((sp - 1)); out="$out "; i=$((i + 1)); continue ;;
                # Argument substitution: the sentinel holds command position so the
                # outer command's remaining ARGS are not read as a command.
                *p) sp=$((sp - 1)); st="${top%p}"; out="$out"$'\n'"_ "; i=$((i + 1)); continue ;;
                # Assignment-value substitution: a real command may follow it.
                *P) sp=$((sp - 1)); st="${top%P}"; out="$out"$'\n'; i=$((i + 1)); continue ;;
            esac
        fi
        if [ "$c" = '`' ]; then
            if [ "$sp" -gt 0 ]; then
                top="${stk[$((sp - 1))]}"
                case "$top" in
                    *b) sp=$((sp - 1)); st="${top%b}"; out="$out"$'\n'"_ "; i=$((i + 1)); continue ;;
                esac
            fi
            stk[sp]="0b"; sp=$((sp + 1)); out="$out"$'\n'; i=$((i + 1)); continue
        fi
        out="$out$c"; i=$((i + 1))
    done
    # Unbalanced quotes / unclosed substitution → unparseable, fail open.
    [ "$st" = 0 ] && [ "$sp" -eq 0 ] || return 1
    MASKED="$out"
    return 0
}

# Does the command RUN the jira CLI with a write verb?
#
# The CLI must be the script `node` executes — not merely a path that appears
# somewhere in the command. Same model as the gateway's own node handling: find a
# `node` token, skip its flags, and the first non-flag token after it is the
# script. Without this, any command that happens to carry the CLI path plus a
# write verb as bare arguments would be falsely bounced with jira guidance.
#
# The verb is then the first non-flag token AFTER the script (commander shape:
# `jira [options] <verb>`). That relies on the CLI having no value-taking GLOBAL
# option: today only -V/-h precede the verb, so the first non-flag token IS the
# verb. (`--project X create` is not a valid shape — commander rejects it with
# "unknown option", verified 2026-07-16 — so there is no pre-verb option value to
# mistake for the verb.) Were a value-taking global option ever added, its value
# could be read as the verb and the write would forfeit its guidance — fail open,
# never a wrong block.
# Does ONE simple command run the jira CLI with a write verb? `node` must be the
# command this segment EXECUTES — not a word that merely appears in it. `echo node
# …/index.js create` runs echo, and bouncing it with jira guidance would be a wrong
# block. Leading VAR=val assignments are skipped (the incident shape was
# `JIRA_PROJECT_KEY=… node …`); a `$(…)` blanked by quote_mask leaves its assignment
# prefix (`key=`) behind, which the same skip absorbs.
segment_has_write() {
    local -a a
    local IFS=$' \t\n' seg="$1"
    # Redirects belong to the simple command, but bind tighter than tokens: `x>out`
    # is `x` + `>out`, and a target may be glued (`>node`). Give the operators their
    # own tokens so both the command position and the verb survive; they are then
    # skipped WITH their target below.
    seg="${seg//>/ > }"; seg="${seg//</ < }"
    set -f                     # tokenise only: never let a `*` in the command glob
    # shellcheck disable=SC2206 # intentional word split for tokenisation
    a=($seg)
    set +f
    local n=${#a[@]} i=0 j scr
    # Walk to the command this segment actually EXECUTES, skipping what can legally
    # precede it: VAR=val assignments; redirects (`>out node …` really runs node,
    # while `printf x >node …` runs printf and its redirect TARGET must never be
    # mistaken for the command); reserved words that introduce a command
    # (`if node …`, `{ node …; }`, `! node …`); and transparent wrappers
    # (`command node …`, `env K=V node …`, `time node …`) — all of which really do
    # run node.
    local nm strict=0
    while [ "$i" -lt "$n" ]; do
        case "${a[$i]}" in
            # Unconditional wrappers/groupings only. Reserved words that make the
            # write CONDITIONAL (if/then/while/…) are deliberately NOT skipped: the
            # bounce tells the agent to reissue the command standalone, which would
            # drop the condition and perform a write the original might never have
            # performed. Those shapes stay undetected (status quo) instead.
            #
            # `command`/`nohup`/`exec` take a COMMAND NAME, not env assignments:
            # `command FOO=1 node …` looks for a program literally named "FOO=1"
            # ("command not found" — verified) and never runs node, so an assignment
            # after them ends the walk. `env`/`time`/`{`/`!` do accept assignments.
            command|nohup|exec)
                strict=1; i=$((i + 1)) ;;
            '{'|'!'|env|time)
                i=$((i + 1)) ;;
            '<'|'>')
                i=$((i + 1))
                case "${a[$i]:-}" in '<'|'>') ;; *) i=$((i + 1)) ;; esac ;;
            [0-9]*)
                # A leading pure-integer token that binds to a following redirect
                # is a file-descriptor designator: `2>out node …/index.js create`
                # really runs node, so skip the fd digit and let the `>`/`<` + its
                # target be consumed as the redirect above — otherwise the `2` reads
                # as the command and a real interpolated write slips past unbounced
                # (codex panel). A digit token NOT followed by a redirect, or a token
                # with any non-digit, stays the command (break — status quo).
                case "${a[$i]}" in *[!0-9]*) break ;; esac
                case "${a[$((i + 1))]:-}" in '<'|'>') i=$((i + 1)) ;; *) break ;; esac ;;
            *=*)
                # Only a VALID name= is an assignment, and only where the shell
                # would treat it as one. `foo-bar=1 node …` does not assign — bash
                # looks for a COMMAND named `foo-bar=1` and node never runs — and
                # neither does an assignment after command/nohup/exec. Skipping
                # either would bounce a command that never writes.
                [ "$strict" = 1 ] && break
                nm="${a[$i]%%=*}"
                case "$nm" in
                    ''|[0-9]*|*[!A-Za-z0-9_]*) break ;;
                    *) i=$((i + 1)) ;;
                esac ;;
            *) break ;;
        esac
    done
    [ "$i" -lt "$n" ] || return 1
    case "${a[$i]}" in
        node|node.exe|*/node|*/node.exe) ;;
        *) return 1 ;;                     # this segment does not execute node
    esac
    # First non-flag token after `node` is the script it runs — but an inline-code
    # flag means node runs THAT, and any later path is just an argv entry (same
    # rejection the gateway applies).
    j=$((i + 1)); scr=""
    while [ "$j" -lt "$n" ]; do
        case "${a[$j]}" in
            # Modes where node does NOT run the script: inline code, or a check/info
            # mode that exits before execution. `node --check <cli> create …` performs
            # no write, so bouncing it would recommend a literal invocation that DOES.
            # The `=`-glued inline-code forms (`--eval=<code>`, `--print=<code>`) run
            # the attached code and leave the CLI path as a mere argv entry, exactly
            # like their space-separated spellings (codex-1) — treat them the same.
            -e|--eval|--eval=*|-p|--print|--print=*|-) return 1 ;;
            # `--run <script>` executes a package.json script and passes any
            # following path as an ARG to it — node never runs that file, so the
            # CLI path after it is not a Jira invocation (codex-adv). Both spellings.
            --run|--run=*) return 1 ;;
            -c|--check|-v|--version|-h|--help|--v8-options) return 1 ;;
            # Options that consume the NEXT word: without this, `node -r hook.js
            # …/index.js create` reads `hook.js` as the script and the real write is
            # missed. (`--opt=value` needs no skip.)
            -r|--require|--import|--loader|--experimental-loader|-C|--conditions|--title)
                j=$((j + 2)) ;;
            --) j=$((j + 1))                    # end of options: next word is the script
                [ "$j" -lt "$n" ] && scr="${a[$j]}"
                break ;;
            -*) j=$((j + 1)) ;;
            *)  scr="${a[$j]}"; break ;;
        esac
    done
    # EXACTLY the gateway's patterns. A loose `*jira/dist/index.js` also matches an
    # unrelated CLI like /tmp/myjira/dist/index.js — which the gateway declines
    # (wrong path), so this hook would bounce that command and instruct the agent to
    # rerun its verb against himmel's REAL Jira CLI: an unrelated `create` turned
    # into a filed ticket by our own guidance.
    case "$scr" in
        scripts/jira/dist/index.js|*/scripts/jira/dist/index.js) ;;
        *) return 1 ;;
    esac
    # Remember which CLI was actually invoked: the retry must name THAT one. These
    # patterns (the gateway's) also match another checkout's CLI, which may front a
    # different Jira — echoing our primary checkout's path back would redirect the
    # write to the wrong instance.
    DETECTED_SCRIPT="$scr"
    j=$((j + 1))
    while [ "$j" -lt "$n" ]; do
        case "${a[$j]}" in
            # A pre-verb option makes the invocation UNCERTAIN: the CLI takes its
            # options AFTER the verb, so an option here is either unknown (the CLI
            # errors and writes NOTHING) or value-consuming (it would swallow the
            # verb token). Skipping it as valueless and reading the next token as
            # the verb risks bouncing a command that never writes — the retry then
            # files a ticket the original could not (coderabbit [critical]). Fail
            # open. Redirect markers below still resolve (a redirect does not stop
            # the verb from running).
            -*) return 1 ;;
            '<'|'>')                       # a redirect may sit before the verb
                j=$((j + 1))
                case "${a[$j]:-}" in '<'|'>') ;; *) j=$((j + 1)) ;; esac ;;
            *)  if is_write_verb "${a[$j]}" "${a[$((j + 1))]:-}"; then
                    # Remember the verb: the retry guidance must name the verb the
                    # agent STARTED with, never a different mutation.
                    DETECTED_VERB="${a[$j]}"
                    [ "$DETECTED_VERB" = "worklog" ] && DETECTED_VERB="worklog add"
                    return 0
                fi
                return 1 ;;
        esac
    done
    return 1
}

has_jira_write() {
    local t stmt sub seg kw ekw nm val rest exec_cmd et
    local -a ets
    # Split on real command SEPARATORS only, with or without cosmetic spaces:
    # `echo ok;node …`, `true&&node …`, `echo x|node …` all RUN node, and splitting
    # on whitespace alone would yield `ok;node` and miss the write. Safe by
    # construction: everything surviving quote_mask is structure (data is already
    # blanked), so this cannot resurrect masked data.
    # Redirects (`<` `>`) are deliberately NOT separators — they belong to the
    # simple command. Breaking on them moved a redirect TARGET into command
    # position, so `printf x >node …/index.js create` (which runs printf, writing a
    # file named `node`) got bounced with authoritative guidance to file a ticket
    # the command never attempted. segment_has_write parses them in-segment.
    # Only PROVABLY UNCONDITIONAL writes are in scope. `a || node … create` runs the
    # write only if `a` FAILED; `test -f body && node … create` only if the test
    # PASSED. This is a PreToolUse hook — neither side has run when it fires — and
    # the bounce says "reissue as ONE literal command", which strips the condition:
    # it would file a ticket precisely when the original wanted none (`||`) or when
    # its prerequisite was never met (`&&`). Everything after `&&`/`||` is therefore
    # out of scope: mark the operators, then keep only each statement's text before
    # them. Undetected = the pre-HIMMEL-1077 status quo; wrong guidance = a real
    # unwanted mutation. The incident's own shape (`;`-chained, `$(…)`-interpolated)
    # is unconditional and stays fully in scope.
    t="${1//&&/$'\001'}"
    t="${t//||/$'\001'}"
    # Everything from the FIRST conditional operator onward is out of scope, whole
    # stop. A conditional RHS can be a GROUP whose body spans separators
    # (`false && { echo skipped; node … create; }` never runs the write), and group
    # extent is unknowable here — quote_mask blanks group parens, and `{ … }` nesting
    # needs a real parser. Truncating is the one rule that cannot guess wrong: what
    # precedes the operator runs unconditionally and stays fully in scope (so
    # `node … create … || { echo failed; }` still bounces), and what follows keeps its
    # pre-HIMMEL-1077 denial. The incident's own `;`-only shape has no marker at all.
    t="${t%%$'\001'*}"
    # `&>` / `&>>` / `>&` are REDIRECTS, not separators. Splitting on their `&` moved
    # the redirect target into command position, so `printf &>/tmp/log node …/index.js
    # create …` — which runs printf and passes the rest as ARGUMENTS — was bounced with
    # guidance to perform a real create. Normalise them to plain redirects first; the
    # `&` that survives is the bare background separator.
    t="${t//&>>/>>}"
    t="${t//&>/>}"
    t="${t//>&/>}"
    # `>|` (clobber) and `<&` (fd-dup) are ALSO redirects — their `|`/`&` are not a
    # pipe or a separator. Normalise to plain redirects too, else `printf x >|/tmp/f
    # node …/index.js create` would split at the `|` and read the tail as a real
    # create (coderabbit). Same class as the &>/>& normalisation above.
    t="${t//>|/>}"
    t="${t//<&/<}"
    # Split into STATEMENTS first (`;`, newline, bare `&`), truncate each at its
    # conditional marker, and only then split what remains into simple commands
    # (`|`, grouping). Splitting everything at once let `false && printf x | node …
    # create` escape: the pipe started a fresh segment that no longer carried the
    # marker, so a conditional write read as unconditional.
    t="${t//[;&]/$'\n'}"
    while IFS= read -r stmt; do
        [ -n "$stmt" ] || continue
        # Bail out on structure this flat scanner cannot reason about:
        #   * `function name { … }` DEFINES, it does not execute — and its body lands
        #     in later segments, so the raw `()` check misses this spelling.
        #   * Any conditional compound (`if`/`while`/`for`/`case`/…). Segments are
        #     flat, so a multi-line body line reads as an unconditional command and
        #     loses its condition — and the bounce would tell the agent to run the
        #     write standalone, mutating Jira when the condition would have been false.
        # Both fail open for the WHOLE command: a lost bounce costs guidance, a wrong
        # one costs a real ticket. Checked on the MASKED text, so these words inside a
        # quoted title (`--title "fix function foo"`) stay data and a real write there
        # still bounces.
        # Strip leading TRANSPARENT group tokens first: `{ case x in …` and
        # `{ function f { … }` open a compound whose keyword is not the statement's
        # first token, and missing that made the scanner walk into the body and bounce
        # a branch that may never run.
        kw="${stmt#"${stmt%%[![:space:]]*}"}"
        while : ; do
            case "$kw" in
                '{'|'{'[[:space:]]*|'!'|'!'[[:space:]]*)
                    kw="${kw#?}"; kw="${kw#"${kw%%[![:space:]]*}"}" ;;
                *) break ;;
            esac
        done
        # An unconditional TERMINATOR ends the shell, so every statement AFTER it is
        # UNREACHABLE — a write there never runs, and bouncing it (telling the agent
        # to reissue standalone) would order a Jira write the command never performs,
        # the same hazard the conditional bails below guard against. A CONDITIONAL
        # terminator (`foo || exit`) was already truncated to `foo` upstream, so only
        # a genuinely unconditional one reaches here. Stop scanning; a real write
        # BEFORE the terminator already returned 0 in its own turn.
        #
        # Terminators (HIMMEL-1182 extends the bare-`exit` break): a bare `exit`; a
        # wrapped `command exit` / `builtin exit`; an assignment-prefixed `FOO=1
        # exit`; and `exec <cmd>` (which REPLACES the shell). A backgrounded
        # `exit &` / `exec cmd &` does NOT terminate the PARENT, but the bare `&`
        # already split this statement off upstream, so it does not reach here as the
        # same statement.
        #
        # CRITICAL: `exec` WITH a command replaces the shell (terminates); `exec
        # >file` / `exec 2>&1` — exec with ONLY redirections — just reassigns file
        # descriptors and execution CONTINUES, so a later write may still run.
        # Treating redirect-only exec as a terminator would mask a REACHABLE write —
        # the one place a wrong block could sneak in here. So `exec` is resolved by
        # scanning its remaining tokens: a non-redirect word means a command is
        # present. Strip leading wrappers and VAR=val assignments first so the word
        # sits in command position.
        ekw="$kw"
        while : ; do
            ekw="${ekw#"${ekw%%[![:space:]]*}"}"   # strip leading whitespace
            case "$ekw" in
                command[[:space:]]*|builtin[[:space:]]*)
                    ekw="${ekw#*[[:space:]]}"
                    continue ;;
            esac
            # Strip ONE leading VAR=val assignment prefix (`FOO=1 exit`, chained
            # `A=1 B=2 exit`, `FOO=1 exec <cmd>`). A masked `VAR=$(…)` value already
            # split this statement on the substitution's newline, so only a literal
            # or quoted value is inline here; a quoted value was blanked to spaces,
            # which the value-word strip below consumes harmlessly. Valid name =
            # [A-Za-z_][A-Za-z0-9_]* (same rule as segment_has_write); `foo-bar=1`
            # is not an assignment (bash reads it as a command name), so it is left.
            nm="${ekw%%=*}"
            case "$nm" in
                [A-Za-z_]*)
                    case "$nm" in *[!A-Za-z0-9_]*) nm="" ;; esac ;;
                *) nm="" ;;
            esac
            if [ -n "$nm" ] && [ "${ekw:${#nm}:1}" = '=' ]; then
                ekw="${ekw:$(( ${#nm} + 1 ))}"      # drop NAME=
                val="${ekw%%[[:space:]]*}"          # the value word (empty if quoted)
                ekw="${ekw#"$val"}"
                continue
            fi
            break
        done
        case "$ekw" in
            exit|exit[[:space:]]*|exit'>'*|exit'<'*) break ;;
            exec|exec[[:space:]]*|exec'>'*|exec'<'*)
                # `exec <cmd>` replaces the shell → terminator; `exec >file` /
                # `exec 2>&1` (redirections only) does NOT — execution continues.
                rest="${ekw#exec}"
                rest="${rest#"${rest%%[![:space:]]*}"}"
                exec_cmd=0
                if [ -n "$rest" ]; then
                    set -f
                    # shellcheck disable=SC2206 # intentional word split for tokenisation
                    ets=($rest)
                    set +f
                    expect_target=0
                    for et in "${ets[@]}"; do
                        if [ "$expect_target" = 1 ]; then
                            expect_target=0   # this token is a redirect TARGET
                            continue          # (space-separated: `exec > /tmp/f`)
                        fi
                        case "$et" in
                            [0-9]*'>'*|[0-9]*'<'*|'>'*|'<'*)     # a redirect token
                                # A token that is JUST the operator (ends in > or <,
                                # e.g. `>`, `>>`, `2>`) takes the NEXT whitespace-
                                # separated token as its target — consume it, or the
                                # target reads as a command and a pure-redirect exec
                                # is wrongly treated as terminating. A glued target
                                # (`>/tmp/f`, `2>1`) needs no lookahead.
                                case "$et" in
                                    *'>'|*'<') expect_target=1 ;;
                                esac
                                ;;
                            *) exec_cmd=1; break ;;              # a command word
                        esac
                    done
                fi
                [ "$exec_cmd" = 1 ] && break
                ;;
        esac
        case "$kw" in
            function|function[[:space:]]*|\
            if|if[[:space:]]*|elif|elif[[:space:]]*|else|else[[:space:]]*|\
            then|then[[:space:]]*|fi|fi[[:space:]]*|\
            while|while[[:space:]]*|until|until[[:space:]]*|\
            for|for[[:space:]]*|select|select[[:space:]]*|\
            do|do[[:space:]]*|done|done[[:space:]]*|\
            case|case[[:space:]]*|'esac'|'esac'[[:space:]]*)
                return 1 ;;
        esac
        # Now the simple commands within this (unconditional) statement.
        sub="${stmt//[|()]/$'\n'}"
        while IFS= read -r seg; do
            [ -n "$seg" ] || continue
            segment_has_write "$seg" && return 0
        done <<SUBEOF
$sub
SUBEOF
    done <<EOF
$t
EOF
    return 1
}

# --- Fail open on anything we cannot evaluate ---
# Drain stdin BEFORE any early exit: bailing out first would SIGPIPE the caller
# that is still writing the hook input.
input=$(cat 2>/dev/null || true)
[ "${JIRA_COMPOUND_WRITE_OK:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ -n "$input" ] || exit 0
# Use jq's output only when jq SUCCEEDS: a partial parse (malformed input, trailing
# garbage) must not reach the block path on half-read values.
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$tool" = "Bash" ] || exit 0   # PowerShell keeps its own native rules
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

FN_DEF=0
quote_mask "$cmd" || exit 0
# A function DEFINITION executes nothing: `deploy() { node …/index.js create …; }`
# merely defines deploy, so bouncing it would order a write the command never
# performed. quote_mask flags the `name()` pair only where it is real shell structure
# — a `()` inside quoted DATA (`--title 'Fix parse()'`) is not a definition and must
# not disarm the guard.
[ "$FN_DEF" = 1 ] && exit 0
has_jira_write "$MASKED" || exit 0

# --- Would the auto-approve gateway sanction this exact command? ---
# Consulting it (rather than re-implementing "is this shape safe") keeps ONE
# safety model: whatever the gateway approves runs untouched by this guard.
hook_dir=$(cd "$(dirname "$0")" && pwd)
gateway="$hook_dir/auto-approve-safe-bash.sh"
[ -f "$gateway" ] || exit 0                        # no gateway → nothing to add
gw_rc=0
verdict=$(printf '%s' "$input" | bash "$gateway" 2>/dev/null) || gw_rc=$?
case "$verdict" in
    *'"permissionDecision":"allow"'*) exit 0 ;;    # already sanctioned → silent
esac
# The gateway exits 0 on every fall-through path, so a non-zero status means it
# BROKE — we cannot tell "declined" from "crashed". Fail open: if the gateway is
# broken, nothing is approvable, and bouncing would tell an agent to retry the
# literal shape it has already used — an unactionable loop.
[ "$gw_rc" -eq 0 ] || exit 0

# --- Bounce: the command would fall through to the classifier ---
# The retry shape must name the PRIMARY checkout's ABSOLUTE CLI path: `dist/` is
# an untracked build artifact, so a relative path run from a linked worktree dies
# with MODULE_NOT_FOUND — and a bounce whose "do exactly this" command fails is
# exactly what provokes the retry-across-shapes this guard exists to stop.
# git-common-dir resolves to the PRIMARY .git from any worktree; its parent is
# the primary checkout. JIRA_CLI is a test seam (same convention as
# block-backend-tier.sh). Fall back to the generic shape if we cannot resolve a
# CLI that actually exists.
jira_cli="${JIRA_CLI:-}"
# An ABSOLUTE invoked path is already runnable and unambiguous — name it back, so a
# write aimed at another checkout's CLI is never redirected to this one's Jira. Only
# a RELATIVE path needs resolving (that is the MODULE_NOT_FOUND-from-a-worktree case).
if [ -z "$jira_cli" ]; then
    case "${DETECTED_SCRIPT:-}" in
        /*|[A-Za-z]:[/\\]*) jira_cli="$DETECTED_SCRIPT" ;;
        # Only the CANONICAL relative form resolves to this checkout's CLI. Any other
        # relative path (`bogus/scripts/jira/dist/index.js`, a stale sibling checkout)
        # would die MODULE_NOT_FOUND and write NOTHING — substituting the real primary
        # CLI would turn a typo into a filed ticket. Fail open instead.
        scripts/jira/dist/index.js|./scripts/jira/dist/index.js)
            # A relative CLI path resolves against the CWD. A `cd` earlier in the
            # command can move that CWD off THIS checkout, so the canonical-relative
            # form no longer reliably names this Jira — resolving it to the primary
            # CLI could redirect a write meant for another location here, or turn a
            # would-fail command into a real ticket. When a `cd` command-token is
            # present, fail open (coderabbit) rather than name a possibly-wrong CLI.
            printf '%s' "$MASKED" | grep -Eq '(^|[[:space:]();&|{}])cd([[:space:]]|$)' && exit 0 ;;
        *) exit 0 ;;
    esac
fi
if [ -z "$jira_cli" ]; then
    primary_root=$(cd "$hook_dir" 2>/dev/null &&
                   cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)/.." 2>/dev/null &&
                   pwd) || primary_root=""
    if [ -n "$primary_root" ] && [ -f "$primary_root/scripts/jira/dist/index.js" ]; then
        jira_cli="$primary_root/scripts/jira/dist/index.js"
    fi
fi
# A jira_cli that is not a conservative, shell-safe path has NO sanctioned shape,
# so emitting it in the "do exactly this" guidance is wrong or dangerous:
#   * whitespace tokenises the path — unquoted it breaks, quoted it is not
#     gateway-approvable (the quoted-CLI-path gap; upstream fix HIMMEL-1083);
#   * shell-active metacharacters from a crafted DETECTED_SCRIPT token
#     (`$(…)`, backticks, `;`, `|`, `&`, redirects, globs) would turn the
#     guidance into an instruction to run INJECTED shell (coderabbit);
#   * a backslash-only Windows path (`C:\…`) mangles its separators in bash and
#     has no clean runnable shape either.
# Fail open for anything outside [alnum / : . _ -]. Checked BEFORE the placeholder
# fallback so our own fixed <primary-checkout> placeholder (its angle brackets are
# ours, safe by construction) is never caught; an EMPTY value passes through to it.
case "$jira_cli" in *[!A-Za-z0-9/:._-]*) exit 0 ;; esac
[ -z "$jira_cli" ] && jira_cli="<primary-checkout>/scripts/jira/dist/index.js"

# The example must show the verb the agent ACTUALLY used. Printing a `create`
# example for a blocked `assign`/`edit`/`move` invites the retry to file a ticket
# instead of performing the original mutation — a wrong external write caused by
# the guard's own guidance.
verb_label="${DETECTED_VERB:-create}"
# Show only what the SHAPE requires (the body moves to a file). Everything else
# stays "same arguments as before": spelling out `--type Task` here would tell an
# agent retrying a `--type Bug` create to file the wrong issue type — the same way
# a `create` example told a blocked `assign` to file a ticket.
case "$verb_label" in
    create)         verb_args=' …same arguments as before… (inline body? pass it as --desc-file <path>)' ;;
    comment)        verb_args=' <TICKET> …same arguments as before… (inline body? pass it as --comment-file <path>)' ;;
    transition)     verb_args=' <TICKET> "<Status Name>"' ;;
    # project-create takes no positional ticket (--key/--name) — a <TICKET> here
    # would contradict the CLI and bounce the retry straight back.
    project-create) verb_args=' …same arguments as before…' ;;
    *)              verb_args=' <TICKET> …same arguments as before…' ;;
esac
# shellcheck disable=SC2016 # single-quoted `$(…)`/`$1` in the message are literal text, not expansions
{
    printf 'block-jira-compound-write: refusing this jira WRITE command SHAPE (not the write itself).\n\n'
    printf 'Jira CLI writes are sanctioned (HIMMEL-205). This command is refused because\n'
    printf 'its shape — command substitution `$(…)`, a heredoc, or a chained segment the\n'
    printf 'auto-approve gateway cannot vet — makes the permission matcher bail out\n'
    printf '(HIMMEL-203), so the write falls through to the auto-mode classifier and is\n'
    printf 'denied cold as "[External System Writes]". Rerunning it as-is will fail again.\n\n'
    printf 'Do exactly this — ONE sanctioned retry shape, no other:\n\n'
    printf '  1. If the command carries a body, write it to a file with the Write tool\n'
    printf '     (not a heredoc, not `cat >`).\n'
    printf '  2. Reissue the SAME verb (`%s`) with the SAME arguments as ONE literal\n' "$verb_label"
    printf '     command, body passed by file:\n\n'
    printf '    node %s %s%s\n\n' "$jira_cli" "$verb_label" "$verb_args"
    printf '  Keep the verb you started with — do NOT substitute a different mutation,\n'
    printf '  and keep everything else you already had: every argument (--project and\n'
    printf '  other targeting options included) and any VAR=value prefix such as\n'
    printf '  JIRA_PROJECT_KEY=…. Only an INLINE BODY moves, from text to a file.\n'
    printf '  Filing/updating N tickets = N literal commands, not a chain.\n\n'
    printf 'That shape auto-approves. Do NOT retry other shapes — a retry sequence across\n'
    printf 'shapes reads to the classifier as tool-shopping and gets denied as an auto-mode\n'
    printf 'bypass. If the literal shape is genuinely impossible, say so and ask.\n\n'
    printf 'Bypass for a real carve-out: JIRA_COMPOUND_WRITE_OK=1 claude (launching shell;\n'
    printf 'a per-call prefix does not work).\n'
} >&2
exit 2
