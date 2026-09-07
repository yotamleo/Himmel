#!/usr/bin/env bash
# PreToolUse hook (Bash) - deny a bare invocation of a repo shell test suite
# and name the scripts/quiet-run.sh replacement (HIMMEL-1952).
#
# WHY: scripts/quiet-run.sh already exists, is cataloged
# (docs/commands-catalog.md, /quiet-run), and CLAUDE.md's Tests section
# explains why quiet reporters are deliberate. None of that prose produced
# compliance - sessions kept running suites bare, then burned several
# tail/grep round-trips fishing the PASS/FAIL line out of a noisy background
# run. himmel already measured that an advisory PreToolUse hook
# (additionalContext) does not change behaviour. What DOES work here,
# observed twice in one session and obeyed on the first bounce, is deny +
# name the exact replacement - the same pattern as the tokensave grep guard
# and block-graphify-egress.sh. This hook follows that shape: it never
# rewrites the command (a silent rewrite would hide what actually ran), it
# only refuses and prints the copy-pasteable quiet-run form.
#
# SCOPE - deliberately narrow, because over-matching is the main way this
# hook can fail (it would become the next thing people bypass): ONLY
# scripts/**/test-*.sh and scripts/ci/run-shell-tests.sh, and ONLY when one
# is actually being EXECUTED (`bash <path>`, `sh <path>`, or `./<path>` at
# command position) - not merely mentioned as an argument to cat/grep/etc.
# `node --test`, `bun test`, and everything else are untouched; those
# already have their own quiet reporters by convention.
#
# Hook I/O contract (mirrors the other PreToolUse Bash guards): input is
# JSON on stdin.
#   exit 0 - allow
#   exit 2 - block; stderr is shown to Claude and the user
#
# Fail OPEN (exit 0) on anything this hook cannot evaluate (no jq,
# unparseable JSON, non-Bash tool). This is a workflow nudge, not a security
# fence - it must never become the reason an unrelated command can't run.
#
# Bypass: QUIET_RUN_BYPASS=1 in the shell that launched the agent (session-
# sticky; a per-call prefix does not work), mirroring
# TOKENSAVE_DISABLE_GREP_HOOK=1.
set -uo pipefail

if [ "${QUIET_RUN_BYPASS:-0}" = "1" ]; then
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# HIMMEL-2123: bash builtin `read` instead of `$(cat)` drops one more spawn.
input=""
IFS= read -r -d '' input 2>/dev/null || true

# HIMMEL-2060: one jq launch instead of three (validate-JSON + tool_name +
# command) - the largest per-call fork lever on a loaded Windows/Git-Bash box,
# where every jq launch is a full MSYS2 process spawn. Invalid JSON makes the
# combined query fail exactly like the old standalone `jq empty` did, so the
# fail-open behaviour is unchanged. tool_name and command come back on one
# jq-emitted line separated by a real newline (command is emitted RAW, not
# TSV-escaped, so a heredoc/multi-line command keeps its literal newlines for
# the tr step below); bash parameter expansion splits at the first one, no
# extra fork needed. The Windows jq.exe build writes stdout in TEXT mode, so
# every "\n" this filter emits - including the tool/command separator AND
# every line boundary inside a multi-line $cmd - comes back as "\r\n"; strip
# the stray \r off $tool explicitly. HIMMEL-2322: $cmd's copy used to be
# "harmless" only because the old cmd_norm fold treated \r and \n as
# interchangeable separators; the heredoc-body stage below does its own
# line-based `read`, which treats \r as ordinary line content, not a
# terminator - a body/delimiter line ending in a stray \r would never
# string-match its (clean) heredoc delimiter and the whole rest of the
# command would look unterminated. Strip every \r from $cmd up front so
# both stages see plain \n-delimited lines.
#
# HIMMEL-2123: two more fixes on top of the HIMMEL-2060 shape above.
#   * `<<<"$input"` feeds jq directly instead of `printf '%s' "$input" |`,
#     dropping the printf fork that pipeline paid on top of jq's own.
#   * `// ""` (empty STRING) replaces `// empty` (a zero-output jq
#     GENERATOR) on both fallbacks: in a `+`-concatenation, one operand
#     collapsing to `empty` zeroes out the WHOLE expression (cross-product-
#     of-generators semantics), not just that field — caught empirically
#     while applying this identical shape to block-read-secrets.sh, where a
#     Bash command (no file_path/path field) went silently blank.
result=$(jq -r '(.tool_name // "") + "\n" + (.tool_input.command // .tool_input.cmd // "")' <<<"$input" 2>/dev/null) || exit 0
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
cmd="${cmd//$'\r'/}"

[ "$tool" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# Strip leading structural tokens so a suite invoked in a NESTED command
# position is still seen at command position (HIMMEL-1952 CR round 3): an
# assignment prefix (`FOO=1 bash ...`), a conditional/loop keyword (`if bash
# ...`), `time`/`env`, or `!`. Subshells, brace groups and command/backtick
# substitutions need no keyword handling - the segment splitter below breaks
# on their delimiters as well as on ';', '&' and '|'.
strip_lead() {
    local s=$1 prev="" w
    while [ "$s" != "$prev" ]; do
        prev=$s
        s=${s#"${s%%[![:space:]]*}"}
        case $s in
            "if "*|"then "*|"elif "*|"else "*|"while "*|"until "*|"do "*|"time "*|"env "*|"! "*)
                s=${s#* }
                ;;
            *)
                w=${s%%[[:space:]]*}
                case $w in
                    *=*) s=${s#"$w"} ;;
                    *) break ;;
                esac
                ;;
        esac
    done
    printf '%s' "$s"
}

# HIMMEL-2322 stage 1 - strip heredoc BODIES that are not fed to a shell,
# before the SUITE/QUIET_RUN regexes ever see them. A heredoc body is DATA,
# not a command: `cat > handover.md <<'EOF' ... EOF` never executes whatever
# suite-shaped text sits inside it, but the old whole-text regex scan (this
# file's previous "ponytail" note here) couldn't tell the difference and
# denied it anyway - refusing legitimate handover/PR-body/stuck-playbook
# prose that happens to quote a suite command (observed 2026-08-31). The one
# shape that DOES need its body kept is a heredoc actually piped/fed to a
# shell (`bash <<'EOF'`, `cat <<'EOF' | bash`) - that body genuinely
# executes.
#
# "Shell-fed" is decided from the INTRO line alone: split it the same way
# the segment loop below splits segments, but ONLY the segment that
# CONTAINS the `<<` and any segment AFTER it on that line count - an
# earlier, unrelated segment naming bash/sh/zsh
# (`bash scripts/quiet-run.sh foo -- true; cat <<'EOF' > handover.md`) must
# not turn a later, unrelated heredoc shell-fed (HIMMEL-2322 CR round 1).
# This one rule still covers both `bash <<EOF` (the `<<` segment itself
# starts with bash) and `cat <<EOF | bash` (a later segment does).
#
# The bare-word delimiter alternative also allows an OPTIONAL leading
# backslash (`<<\EOF`) - real bash treats that exactly like a quoted
# delimiter (suppresses body expansion; the closing line is still just
# "EOF", no backslash) (HIMMEL-2322 CR round 1, codex-3). The backslash is
# its OWN capturing group (BASH_REMATCH[6], empty when absent) so
# strip_heredoc_bodies can tell "escaped" from "bare and unescaped" without
# re-matching anything - see the round-3 note below for why that matters.
# HIMMEL-2322 CR round 2 (codex-2): the bare-word charset itself is widened
# to letters/digits/underscore/hyphen/dot (`<<END-MARK` is a real, if
# unusual, delimiter) - the old identifier-only class captured "END" and
# left "-MARK" attached to the terminator line, which never matched.
#
# ponytail: only the FIRST heredoc intro on a given physical line is
# detected - two heredocs on the SAME line (`cmd <<A <<B`) isn't a shape
# this repo's suites/docs/PR bodies use; extend to a loop over multiple
# intros per line if that ever shows up. Detection (scan_quotes "detect")
# is quote-aware, but delimiter EXTRACTION still just re-matches the raw
# line and takes bash's leftmost hit - so a quoted heredoc-lookalike
# EARLIER on the same line as a real heredoc operator (`echo '<<FAKE' &&
# cat <<'REAL' > x`) still mis-captures the delimiter as "FAKE" instead of
# "REAL" (HIMMEL-2322 CR round 2, codex-3 residual; not a shape this repo's
# docs/PR bodies use). That mis-capture no longer bypasses anything, though
# - see the unterminated-heredoc posture below, which is exactly what a
# never-matching mis-captured delimiter degrades into. Upgrade path: locate
# the match's offset in the blanked ("detect") copy and slice the real
# delimiter out of the original line at that same offset instead of
# re-matching the whole line from scratch.
#
# HIMMEL-2322 CR round 2 (codex-2/codex-3, BLOCKING): an unterminated
# heredoc (no matching closing-delimiter line before the command ends) used
# to drop everything from the intro onward - but that made a mis-captured
# delimiter (never matching its real terminator, hence "unterminated" from
# this parser's point of view) into a silent bypass: whatever real,
# genuinely-executing text sat after it vanished along with the fake body.
# Round 2 inverts this: an unterminated heredoc now strips NOTHING (see the
# end of strip_heredoc_bodies below) - the scan proceeds over that stretch
# exactly as it did before HIMMEL-2322. A parse this stage can't complete
# degrades to a possible false POSITIVE (denying something inert), never to
# a false NEGATIVE (allowing something that executes) - see the
# "unterminated heredoc" test below, which now asserts rc=2 for exactly
# this reason.
#
# HIMMEL-2322 CR round 3 (codex-1, BLOCKING): whether a heredoc body can be
# stripped at all depends on the delimiter form, not just on shell_fed -
# this is plain POSIX heredoc semantics, not a special case invented here.
# A QUOTED or BACKSLASH-ESCAPED delimiter (`<<'EOF'`, `<<"EOF"`, `<<\EOF`)
# makes the body literal data - nothing in it can execute, so it is always
# safe to strip regardless of shell_fed (unchanged). An UNQUOTED bare
# delimiter (`<<EOF`) leaves the body subject to parameter/command
# substitution - bash performs that substitution while BUILDING the
# heredoc, before anything reads it, so a `$(...)` or backtick inside
# genuinely executes even when the command consuming the heredoc (`cat`,
# `tee`, ...) never invokes a shell itself. strip_heredoc_bodies below
# keeps (does not strip) an unquoted-delimiter body that contains `$(` or a
# backtick - same fail-closed direction as the unterminated-heredoc rule
# above: a parse this stage can't prove inert is left for the scan, never
# silently dropped. An unquoted body with neither stays inert prose and is
# still stripped - that's what keeps the ticket's original goal (a plain
# prose suite line in a `cat <<EOF > doc.md` body) working.
HEREDOC_INTRO_RE="(^|[^<])<<(-)?[[:space:]]*('([^']*)'|\"([^\"]*)\"|(\\\\?)([A-Za-z0-9_.-]+))"

# HIMMEL-2322 CR round 2 (codex-1): `source`/`.` genuinely execute a
# heredoc body too (`source /dev/stdin <<EOF`, `. /dev/stdin <<EOF`) and
# were missing from the shell-fed verb set, so their bodies read as inert
# prose. `strip_lead`'s own `env ` handling already covers `env bash` and
# needs no change here (pinned by its own regression test).
SHELL_FED_RE='^(bash|sh|zsh|source|\.)([[:space:]]|$)'

line_invokes_shell() {
    local ln=$1 seg found=0
    while IFS= read -r seg || [ -n "$seg" ]; do
        if [ "$found" = "0" ]; then
            case $seg in
                *'<<'*) found=1 ;;
                *) continue ;;
            esac
        fi
        seg=$(strip_lead "$seg")
        [[ $seg =~ $SHELL_FED_RE ]] && return 0
    done < <(printf '%s' "$ln" | tr ';&|(){}`' '\n')
    return 1
}

strip_tabs() {
    local s=$1
    while [ "${s#$'\t'}" != "$s" ]; do
        s=${s#$'\t'}
    done
    printf '%s' "$s"
}

# Shared quote-span walker (HIMMEL-2322 CR round 1, codex-1) - used by both
# stage 1's heredoc-intro detector below and stage 2's prose-unwrapper
# further down. Walks $2 char by char, and for every single- or
# double-quoted span asks $1 ("stage2" or "detect") what to do with it:
#
#   stage2  - unwrap the span (drop its quote marks) and replace embedded
#             separator characters in its content with spaces; a
#             double-quoted span containing `$(` or a backtick is copied
#             through untouched instead (see stage 2's own comment below).
#   detect  - blank the span's ENTIRE interior to same-length spaces while
#             KEEPING the quote marks (both quote kinds, unconditionally -
#             detection doesn't care about $(/backtick, a heredoc operator
#             can't hide inside command substitution either). This is what
#             lets HEREDOC_INTRO_RE stop seeing a `<<` that was only ever
#             quoted TEXT (`echo '<<EOF'`), while a GENUINELY quoted
#             delimiter (`cat <<'EOF' > x`) still matches structurally -
#             same quote marks, same length, blank content - so detection
#             gating still says "yes, a real heredoc operator is here" even
#             though the delimiter text itself reads as blank in this copy.
scan_quotes() {
    local mode=$1 s=$2
    local out="" i=0 n=${#s} c j closed cj span blank
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        case $c in
            "'")
                j=$((i + 1)); closed=0
                while [ "$j" -lt "$n" ]; do
                    [ "${s:$j:1}" = "'" ] && { closed=1; break; }
                    j=$((j + 1))
                done
                if [ "$closed" = "1" ]; then
                    span="${s:$((i + 1)):$((j - i - 1))}"
                    if [ "$mode" = "detect" ]; then
                        blank=$(printf '%*s' "${#span}" '')
                        out="${out}'${blank}'"
                    else
                        out="${out}$(neutralize_chars "$span")"
                    fi
                    i=$((j + 1))
                else
                    out="${out}${s:$i}"
                    i=$n
                fi
                ;;
            '"')
                j=$((i + 1)); closed=0
                while [ "$j" -lt "$n" ]; do
                    cj=${s:$j:1}
                    if [ "$cj" = "\\" ]; then
                        j=$((j + 2))
                        continue
                    fi
                    [ "$cj" = '"' ] && { closed=1; break; }
                    j=$((j + 1))
                done
                if [ "$closed" = "1" ]; then
                    span="${s:$((i + 1)):$((j - i - 1))}"
                    if [ "$mode" = "detect" ]; then
                        blank=$(printf '%*s' "${#span}" '')
                        out="${out}\"${blank}\""
                    else
                        # shellcheck disable=SC2016  # literal-substring case pattern, not meant to expand
                        case $span in
                            *'$('*|*'`'*)
                                out="${out}\"${span}\""
                                ;;
                            *)
                                out="${out}$(neutralize_chars "$span")"
                                ;;
                        esac
                    fi
                    i=$((j + 1))
                else
                    out="${out}${s:$i}"
                    i=$n
                fi
                ;;
            *)
                out="${out}${c}"
                i=$((i + 1))
                ;;
        esac
    done
    printf '%s' "$out"
}

# HIMMEL-2322 stage 2 - unwrap quoted spans that don't need to stay quoted
# for what this hook does (it never executes anything, so real $IFS-
# splitting rules don't matter here - only whether a SUITE/QUIET_RUN path
# sits at command position). A quoted command word
# (`bash "scripts/ci/run-shell-tests.sh"`) has to read as `bash
# scripts/ci/run-shell-tests.sh` for the INTERP_RE/DIRECT_RE regexes below
# to see it; a quoted separator (`echo "foo; bash ...suite"`) must NOT
# create a new segment, so the `;` inside becomes a space - replaced, not
# deleted, so "foo" and "bash" don't glue into one word - rather than
# staying a real separator for the tr-based splitter downstream.
#
# Single-quoted spans are always unwrapped this way. Double-quoted spans are
# too, UNLESS they contain a literal `$(` or a backtick: that's genuine
# command substitution, which DOES execute, so neutralizing its parens
# would hide a real invocation - those spans (quotes included) are copied
# through untouched instead. An unterminated quote is copied through
# untouched from that point on (fail open, same posture as an unterminated
# heredoc above).
neutralize_chars() {
    local s=$1
    local out="" i=0 n=${#s} c
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        case $c in
            ';'|'&'|'|'|'('|')'|'{'|'}'|'`'|$'\n') out="${out} " ;;
            *) out="${out}${c}" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

neutralize_quoted_separators() {
    scan_quotes "stage2" "$1"
}

# HIMMEL-2322 CR round 1 (codex-1) - detection-only counterpart used by
# strip_heredoc_bodies below to decide whether a `<<` is a real heredoc
# operator or just quoted TEXT. See scan_quotes' own comment for what
# "detect" mode does.
blank_quoted_spans() {
    scan_quotes "detect" "$1"
}

strip_heredoc_bodies() {
    local text=$1
    local out="" line detect_line delim="" dash="" shell_fed="" delim_literal="" body="" in_heredoc=0 term keep

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$in_heredoc" = "1" ]; then
            term=$line
            # HIMMEL-2322 CR round 2: $dash holds BASH_REMATCH[2], which is
            # the literal "-" character when `<<-` was used (or "" when
            # not) - never the string "1". Comparing against "1" here meant
            # strip_tabs never ran, so a real `<<-...EOF` heredoc's
            # tab-indented terminator never matched $delim and the heredoc
            # always looked unterminated. Round 1's fail-OPEN-on-
            # unterminated posture happened to mask this (dropping the body
            # either way, terminated or not); round 2's fail-CLOSED posture
            # exposed it as a false positive on every `<<-` heredoc.
            [ "$dash" = "-" ] && term=$(strip_tabs "$term")
            if [ "$term" = "$delim" ]; then
                in_heredoc=0
                # HIMMEL-2322 CR round 3: keep (don't strip) the body when
                # shell_fed, OR when the delimiter was bare/unquoted AND
                # the body itself contains `$(` or a backtick - see the
                # round-3 note above HEREDOC_INTRO_RE for why an unquoted
                # delimiter's body can execute on its own even when nothing
                # shell-fed it.
                keep=0
                if [ "$shell_fed" = "1" ]; then
                    keep=1
                elif [ "$delim_literal" = "0" ]; then
                    # shellcheck disable=SC2016  # literal-substring case pattern, not meant to expand
                    case $body in
                        *'$('*|*'`'*) keep=1 ;;
                    esac
                fi
                [ "$keep" = "1" ] && out="${out}${body}"
                out="${out}${line}"$'\n'
                body=""
            else
                body="${body}${line}"$'\n'
            fi
            continue
        fi

        out="${out}${line}"$'\n'
        detect_line=$(blank_quoted_spans "$line")
        # Gate on BOTH: detect_line confirms a `<<` exists OUTSIDE any
        # quoted span (a real operator, not text like `echo '<<EOF'`); the
        # second match, against the real $line, is what actually populates
        # BASH_REMATCH with the genuine (unblanked) delimiter text.
        if [[ $detect_line =~ $HEREDOC_INTRO_RE ]] && [[ $line =~ $HEREDOC_INTRO_RE ]]; then
            dash="${BASH_REMATCH[2]}"
            if [ -n "${BASH_REMATCH[4]}" ]; then
                delim="${BASH_REMATCH[4]}"
                delim_literal=1
            elif [ -n "${BASH_REMATCH[5]}" ]; then
                delim="${BASH_REMATCH[5]}"
                delim_literal=1
            else
                delim="${BASH_REMATCH[7]}"
                if [ -n "${BASH_REMATCH[6]}" ]; then delim_literal=1; else delim_literal=0; fi
            fi
            if line_invokes_shell "$line"; then shell_fed=1; else shell_fed=0; fi
            in_heredoc=1
            body=""
        fi
    done <<<"$text"

    # HIMMEL-2322 CR round 2: never terminated - put the buffered body back
    # verbatim instead of dropping it (see the round-2 note above
    # HEREDOC_INTRO_RE for why). $body is empty and this is a no-op for the
    # ordinary case where the loop never entered a heredoc at all.
    [ "$in_heredoc" = "1" ] && out="${out}${body}"

    printf '%s' "$out"
}

cmd_stage1=$(strip_heredoc_bodies "$cmd")
cmd_stage2=$(neutralize_quoted_separators "$cmd_stage1")

# Fold newlines to ';' so a heredoc/multi-line command still has a command-
# position separator right before a later suite invocation (mirrors
# block-destructive-commands.sh's cmd_lc normalization). HIMMEL-2123: no
# `$`-anchored patterns downstream depend on cmd_norm's exact end-of-string
# (SUITE/QUIET_RUN below all anchor with `^` only), so `<<<` is safe here
# and drops the printf fork too.
cmd_norm=$(tr '\n\r' ';;' <<<"$cmd_stage2")

SUITE='(scripts/([[:alnum:]_/-]*/)?test-[[:alnum:]_.-]+\.sh|scripts/ci/run-shell-tests\.sh)'
QUIET_RUN='scripts/quiet-run\.sh'

# Decide per segment (split on ';' '&' '|' and on subshell/brace-group/
# command-substitution delimiters), not per whole command (HIMMEL-1952
# CR round 2): a compound command can wrap ONE suite call in quiet-run.sh and
# run another bare in a separate segment - a whole-command "any quiet-run
# invocation anywhere -> allow" check misses that. Each segment is anchored at
# its own start (same discipline the old CMDPOS anchor gave the whole
# command), so a mere MENTION still doesn't count as an invocation.
QUIET_RUN_INTERP_RE="^[[:space:]]*(bash|sh)[[:space:]]+(\./)?${QUIET_RUN}"
QUIET_RUN_DIRECT_RE="^[[:space:]]*\./${QUIET_RUN}"
INTERP_RE="^[[:space:]]*(bash|sh)[[:space:]]+(\./)?${SUITE}"
DIRECT_RE="^[[:space:]]*\./${SUITE}"

suite_path=""
while IFS= read -r seg || [ -n "$seg" ]; do
    seg=$(strip_lead "$seg")
    [ -n "$seg" ] || continue
    if [[ $seg =~ $QUIET_RUN_INTERP_RE ]] || [[ $seg =~ $QUIET_RUN_DIRECT_RE ]]; then
        continue
    fi
    if [[ $seg =~ $INTERP_RE ]]; then
        suite_path="${BASH_REMATCH[3]}"
        break
    elif [[ $seg =~ $DIRECT_RE ]]; then
        suite_path="${BASH_REMATCH[1]}"
        break
    fi
done < <(printf '%s' "$cmd_norm" | tr ';&|(){}`' '\n')

[ -n "$suite_path" ] || exit 0

base=$(basename "$suite_path" .sh)
label="${base#test-}-suite"

{
    printf 'require-quiet-run: bare repo test-suite run refused.\n\n'
    printf 'scripts/quiet-run.sh already exists for this (docs/commands-catalog.md,\n'
    printf '/quiet-run) - it runs the noisy suite, suppresses output, and prints ONE\n'
    printf 'OK/ERR line with the log path, instead of a hand-rolled background run\n'
    printf 'chased with tail/grep for the PASS/FAIL line. Run it wrapped:\n\n'
    printf '  bash scripts/quiet-run.sh %s -- bash %s\n\n' "$label" "$suite_path"
    printf 'Bypass (streaming output genuinely needed): QUIET_RUN_BYPASS=1 <launching\n'
    printf 'shell>; a per-call prefix does not work.\n'
} >&2
exit 2
