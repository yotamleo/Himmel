#!/usr/bin/env bash
# PreToolUse Bash guard — DENY piping an exit-code-critical himmel gate command
# into `tail`/`head` (HIMMEL-1696).
#
# WHY: `cmd | tail` makes `$?` the status of TAIL, not of `cmd`. Agents here trim
# output for context constantly and then read the exit code — silently getting 0
# from a command that failed. The highest-consequence instance: a gate
# orchestrator ran `clear-cr-marker.sh … | tail` and read `CLEAR_RC=0` when the
# true exit was 16, so it believed the CR gate had CLEARED when it had not. The
# CR marker is the control that HARD-BLOCKS `gh pr create` until a clean review,
# so that misread defeats the review gate itself.
#
# This is structural because prose already failed at EVERY level it was applied
# (house doctrine: on the second drift, escalate to a hook, not to stronger
# prose). It sat in the dispatch handover's TRAPS section for multiple legs; on
# leg 11 the judge did it twice AND the gate orchestrator produced the CLEAR_RC
# incident; on leg 12 the judge put it in the orchestrator's brief in bold as the
# FIRST listed trap, with that incident quoted — and the orchestrator then ran
# `bash scripts/ci/run-shell-tests.sh scripts/handover 2>&1 | tail -80` anyway.
#
# CONTRACT:
#   * DENY (exit 2, reason on stderr) when a logical command line contains a
#     pipeline whose FIRST stage INVOKES a registered gate command and whose LAST
#     stage is `tail`/`head`. Intermediate stages are irrelevant — `gate |
#     grep x | tail` denies too — and `2>&1` is a redirection, not a stage. A
#     command substitution or group is its own pipeline, so `RC=$(gate | tail)`
#     and `( gate | tail )` are caught like the bare form.
#   * "INVOKES" means COMMAND POSITION, not "mentions": the first stage is
#     tokenised, then leading `VAR=value` assignments, leading redirections
#     (`2>/dev/null`, `2> /dev/null`), grouping/negation prefixes
#     (`(`, `{`, `!`), compound-command keywords (`if`, `elif`, `while`, `until`,
#     `then`, `do`, `else`) and a bounded launcher set (`bash`, `sh`, `zsh`,
#     `env`, `command`, `exec`, `nohup`, `time`, `sudo`, `nice`, `timeout`,
#     `xargs`, with or without a directory prefix) are stepped over, and the
#     next token must END with a
#     registered path. So `grep -n x scripts/check-ci.sh | tail` is a
#     READ of the gate script and passes, while `bash scripts/check-ci.sh | tail`
#     is an invocation and denies. A launcher's own OPTIONS (`bash -x <gate>`,
#     `bash -- <gate>`) are stepped over too, but only once a launcher has been
#     seen — a leading `-something` on its own is not that shape. Each launcher
#     carries its OWN small table of the options that take an OPERAND
#     (HIMMEL-1979): `-p` is sudo's prompt but time's bare portability flag, and
#     `-S` is env's split-string but sudo's bare stdin flag, so one flat
#     launcher-agnostic list mis-parsed both directions. `timeout` additionally
#     steps over its positional DURATION. Tables, not a general option parser —
#     an unlisted `--opt=value` carries its own operand and needs no entry.
#     BOTH ends of the pipeline use this same walk, so `| env tail`,
#     `| command head` and `| FOO=1 tail` are recognised as tail/head too.
#   * Registered paths (the ticket's small, high-value allow-list), matched
#     forward-slash only and anchored at a `/` boundary, so `bash …`,
#     `./scripts/…`, `"$ROOT/scripts/…"` and an absolute path all count while a
#     lookalike suffix does not:
#       scripts/cr/clear-cr-marker.sh, scripts/ci/run-shell-tests.sh,
#       scripts/check-ci.sh, scripts/handover/merge-on-green.sh,
#       scripts/handover/pr-merge.sh, and scripts/<dir>/test-*.sh.
#     A backslash-separated Windows path is a documented miss — nothing here
#     writes one, and a miss forfeits guidance only.
#   * Everything else is untouched: `git log | tail`, a bare `tail -f file`, and
#     the CORRECT shape `gate > out 2>&1; tail out` (no pipe) all pass.
#   * Fail OPEN (exit 0) on anything unevaluable — missing jq, empty or
#     unparseable stdin, a non-Bash tool, a command containing an UNQUOTED
#     heredoc (`<<`), whose body text a scanner this flat cannot tell from syntax
#     and which in this repo very often documents this exact shape, or a command
#     over the 16KB cost bound (see below). Per
#     scripts/hooks/CLAUDE.md a workflow
#     nudge fails open: a hook that cannot parse its input must not deny
#     unrelated commands, and an over-matching nudge becomes the next thing
#     everyone bypasses. The gap costs GUIDANCE only — the pre-hook status quo.
#   * NEVER allows: exit 2 is the only decision it emits, so it can neither widen
#     nor narrow any other hook's grant.
#   * `pipefail` is deliberately NOT an exemption (panel r2, codex-4). A hook
#     cannot know the invoking shell's option state — a Bash tool call inherits
#     whatever the harness's shell has, and `set -o pipefail` earlier in the same
#     string only covers that string — so exempting on the presence of the words
#     would hand the incident class a new one-line workaround. And pipefail fixes
#     only HALF the defect: `| tail -80` still throws away the head of the output
#     that several incidents needed to diagnose, which is exactly why the ticket
#     prescribes redirect-to-file over `${PIPESTATUS[0]}`. The deny message says
#     "unless the shell has pipefail set" rather than claiming otherwise.
#
# BYPASS: a same-line `# tail-pipe-ok: <reason>` marker on the offending logical
# line — for the genuine case where the exit code really does not matter. It
# mirrors the existing `# headless-claude-ok:` convention and is deliberately NOT
# an env prefix (the shape scripts/hooks/CLAUDE.md documents for PreToolUse
# bypasses): a `VAR=1 bash scripts/…` prefix on a sanctioned chokepoint is itself
# denied by block-chokepoint-env-prefix.sh, and a per-call env prefix cannot
# reach a hook process anyway (HIMMEL-203). The marker is honoured only where it
# is real shell text — one carried inside a quoted argument is data, not an
# opt-out. Presence is what is verified, not the reason's content, same as the
# headless-claude gate.
#
# SCANNER CEILING (deliberate, bounded — ADJUDICATED in HIMMEL-1979): this is a
# flat character walk, not a shell parser. It tracks quotes (with double-quote
# backslash escapes, whose escaped character is emitted as DATA so no later walk
# can read it as syntax), comments, escapes, one level of command substitution,
# per-launcher operand tables, and the statement/pipeline operators — enough for
# the shapes agents actually write. Anything it cannot resolve withdraws rather
# than guesses.
#
# The residual list, complete and deliberate. HIMMEL-1979 decided the hook grows
# only by SMALL bounded pieces and names the rest as its ceiling: 13 panel rounds
# of lexer-completeness chasing on HIMMEL-1696 established that a complete POSIX
# lexer is not the scope of an advisory-shaped deny hook. Every gap here forfeits
# GUIDANCE only — the pre-hook status quo — and can never widen any grant.
#   * NAMED CEILING: a gate invoked from INSIDE a `-c` payload —
#     `bash -c 'scripts/check-ci.sh' | tail` — is not seen, because the payload
#     is a quoted string this scanner reads as data. Catching it means re-running
#     the scanner over that payload as a NESTED PROGRAM, which is the HIMMEL-912
#     tokenizer class rather than another table, and it is not a shape written
#     here (agents write `bash <gate> | tail`). Do not implement `-c` payload
#     recursion without re-deciding this.
#   * an UNQUOTED heredoc (`<<`), whose body text a scanner this flat cannot tell
#     from syntax and which in this repo very often documents this exact shape.
#   * a command over the 16KB cost bound (see below).
#   * a backslash-separated Windows path to a gate — nothing here writes one.
# A real tokenizer stays the upgrade path if a genuine command ever trips on it.
# bash 3.2-compatible.
set -fuo pipefail   # -f: the token walk word-splits, and must not glob `*.sh`

# HIMMEL-2123: read stdin with the bash builtin (not `$(cat)`) to drop one
# external-process spawn per call, and pull tool_name + command in ONE jq
# call (not two) so a non-matching call pays a single jq fork instead of
# two `printf | jq` pipelines (four forks). `<<<"$input"` feeds jq directly,
# skipping the `printf` fork each pipeline used to pay. Windows jq.exe
# writes CRLF, so the embedded "\n" separator between the two fields can
# arrive as "\r\n" — strip the stray CR off $tool the same way
# require-quiet-run.sh (HIMMEL-2060) already does for the identical shape.
input=""
IFS= read -r -d '' input 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0
[ -n "$input" ] || exit 0

# `// ""` (empty STRING), not `// empty` (a zero-output jq GENERATOR): in a
# `+`-concatenation, one operand collapsing to `empty` zeroes out the WHOLE
# expression's output (cross-product-of-generators semantics), not just
# that field — caught empirically writing this fix (HIMMEL-2123) in
# block-read-secrets.sh, where it went silently blank for every non-Read
# tool call.
result=$(jq -r '(.tool_name // "") + "\n" + (.tool_input.command // "")' <<<"$input" 2>/dev/null) || exit 0
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
[ "$tool" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# CRLF hosts: a stray CR sits between the last real character of a line and its
# newline, so `gate \<CR><LF> | tail` would read as an escaped CR followed by a
# line break — the continuation lost, the pipeline split in two, the guard
# silently blind. Drop CRs before anything treats the text as syntax.
cmd=${cmd//$'\r'/}

# Registered gate paths, anchored: the token must END with one, at a `/` boundary.
GATE_RE='(^|/)scripts/(cr/clear-cr-marker\.sh|ci/run-shell-tests\.sh|check-ci\.sh|handover/merge-on-green\.sh|handover/pr-merge\.sh|[A-Za-z0-9._-]+/test-[A-Za-z0-9._-]*\.sh)$'
NL=$'\n'
TAB=$'\t'
MARK='#tail-pipe-ok:'      # the opt-out, reduced to one operator-free token
HEREDOC_MARK='HEREDOCSEEN' # an UNQUOTED `<<`; the guard withdraws on it
offender=""

# Cost bound. The normaliser below is a character walk, and bash string slicing
# turns it superlinear on large inputs — measured on Git Bash: ~0.55s at 8KB but
# ~4.9s at 32KB, on top of ~0.7s of process start. A PreToolUse hook runs on
# EVERY Bash call, so withdraw above the bound rather than tax the session; a
# command that size is not the incident shape this guard exists for.
[ "${#cmd}" -gt 16000 ] && exit 0

# ONE quote-aware pass over the WHOLE command (not per physical line, so a quote
# or a pipeline that spans newlines is tracked correctly — panel r3, codex-2/3):
#   * operators carried INSIDE quotes (`|`, `;`, `&`, newline) become spaces —
#     they are data, not syntax — while the quoted TEXT is kept, because the gate
#     path in `bash "$ROOT/scripts/check-ci.sh"` lives inside quotes and blanking
#     whole quoted spans would hide the very invocation this hook exists to catch
#     (panel r1, codex-1);
#   * an unquoted word-initial `#` drops the rest of that line, so a pipeline
#     that only appears in a COMMENT cannot produce a denial for something bash
#     never runs (panel r2, codex-3) — EXCEPT that a comment carrying the opt-out
#     collapses to the bare `#tail-pipe-ok:` token, which is how the bypass
#     survives comment stripping while a quoted lookalike does not.
normalise() {
    local s=$1
    local n=${#s} i=0 j d c ch qq p=$NL q='' out='' extra='' ctext
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        # A command substitution runs a pipeline of its OWN, and
        # `RC=$(gate | tail)` swallows the status exactly like the bare form
        # (panel r4, codex-2). Lift its body out to be scanned as a separate
        # line, and leave a placeholder WORD behind so the outer pipeline keeps
        # its shape — splitting the line at the `$(` instead would tear
        # `gate $(…) | tail` apart and lose it.
        # Checked BEFORE the in-quote branch because substitution happens inside
        # DOUBLE quotes too, and `RC="$(gate | tail)"` — the idiomatic, careful
        # spelling — is precisely the shape that must not slip through
        # (panel r5, codex-1). Single quotes really are inert, hence `!= "'"`.
        if [ "$q" != "'" ]; then
            j=-1
            if [ "$c" = '`' ]; then
                j=$((i + 1))
                while [ "$j" -lt "$n" ]; do
                    case ${s:$j:1} in
                        \\) j=$((j + 1)) ;;
                        '`') break ;;
                    esac
                    j=$((j + 1))
                done
                extra="$extra$NL$(normalise "${s:$((i + 1)):$((j - i - 1))}")"
            elif [ "$c" = '$' ] && [ "${s:$((i + 1)):1}" = '(' ]; then
                # `$((…))` is ARITHMETIC, not a command: its body must not be
                # scanned as shell (an `x << 2` shift there used to read as a
                # heredoc and switch the guard off — panel r8, codex-2).
                j=$((i + 2)); d=1; qq=''
                while [ "$j" -lt "$n" ]; do
                    ch=${s:$j:1}
                    if [ -n "$qq" ]; then
                        [ "$ch" = "$qq" ] && qq=''
                    else
                        # Quote- and escape-aware, so a literal `)` inside the
                        # body cannot end the scan early (panel r8, codex-1).
                        case $ch in
                            "'" | '"') qq=$ch ;;
                            \\) j=$((j + 1)) ;;
                            '(') d=$((d + 1)) ;;
                            ')') d=$((d - 1)); [ "$d" -eq 0 ] && break ;;
                        esac
                    fi
                    j=$((j + 1))
                done
                if [ "${s:$((i + 2)):1}" = '(' ]; then
                    # Arithmetic itself is inert, but bash still RUNS a command
                    # substitution nested inside it (panel r11, codex-1), so the
                    # body is still scanned — with `<`/`>` blanked first, since
                    # there they are shift/compare operators, never redirections
                    # or a heredoc.
                    ctext=${s:$((i + 2)):$((j - i - 1))}
                    ctext=${ctext//</ }
                    ctext=${ctext//>/ }
                    extra="$extra$NL$(normalise "$ctext")"
                    out=${out}ARITH
                    p=' '; i=$((j + 1)); continue
                fi
                extra="$extra$NL$(normalise "${s:$((i + 2)):$((j - i - 2))}")"
            fi
            if [ "$j" -ge 0 ]; then
                out=${out}SUBST
                p=' '; i=$((j + 1)); continue
            fi
        fi
        if [ -n "$q" ]; then
            # Inside DOUBLE quotes a backslash escapes the next character, so
            # `"a \" | tail"` is one quoted argument and the `"` does not close
            # the span (panel r6, codex-3). Single quotes have no escapes.
            if [ "$q" = '"' ] && [ "$c" = "\\" ]; then
                c=${s:$((i + 1)):1}
                # An escaped character is DATA. Emitting an escaped QUOTE as a
                # RAW quote left every later quote-state walk unbalanced, and an
                # unbalanced walk never resolves a command at all -- so
                # `FOO="a \" b" bash <gate> | tail` silently passed the guard
                # (HIMMEL-1979, codex-1 r13). `_` is a word character that can be
                # neither a quote, a separator, nor part of a gate path.
                case $c in
                    '|' | ';' | '&' | "$NL") c=' ' ;;
                    '"' | "'") c='_' ;;
                esac
                out=$out$c; p=$c; i=$((i + 2)); continue
            fi
            if [ "$c" = "$q" ]; then
                q=''
            else
                case $c in '|' | ';' | '&' | "$NL") c=' ' ;; esac
            fi
            out=$out$c; p=$c; i=$((i + 1)); continue
        fi
        case $c in
            "'" | '"') q=$c ;;
            '&')
                # A standalone `&` backgrounds the command before it and STARTS a
                # new statement, so `true & gate | tail` is two statements and
                # the gate is the second one's first stage (panel r6, codex-1).
                # `2>&1`, `>&2`, `|&` and `&&` are not separators — hence the
                # look-behind and the look-ahead.
                case $p in
                    '>' | '|' | '&') ;;
                    *) case ${s:$((i + 1)):1} in
                           '&' | '>') ;;   # `&&`, and bash's `&>`/`&>>` (panel r7, codex-3)
                           *) c=$NL ;;
                       esac ;;
                esac
                ;;
            '<')
                # `<<` OUTSIDE quotes introduces a heredoc, whose body a scanner
                # this flat cannot tell from syntax. Mark it so the caller can
                # withdraw. Detecting it HERE rather than as a raw substring is
                # what stops `--title '<<'` — quoted data — from switching the
                # whole guard off (panel r7, codex-2).
                # `<<<` is a HERE-STRING: its operand is a word, not a body, so
                # it stays scannable and must not switch the guard off
                # (panel r8, codex-2).
                if [ "${s:$((i + 1)):1}" = '<' ]; then
                    if [ "${s:$((i + 2)):1}" = '<' ]; then
                        out=$out'<<<'          # here-string: consume all three
                        p=' '; i=$((i + 3)); continue
                    fi
                    out=${out}${HEREDOC_MARK}
                    p=' '; i=$((i + 2)); continue
                fi
                ;;
            \\)
                # Outside single quotes a backslash escapes the next character.
                # `\<newline>` is a line continuation — splice it out here, which
                # is also why the fold below only has to handle a trailing `|`.
                # An escaped operator is DATA, so it must not read as syntax
                # (panel r4, codex-3): `--pattern \| tail` is one command.
                if [ "${s:$((i + 1)):1}" = "$NL" ]; then i=$((i + 2)); continue; fi
                case ${s:$((i + 1)):1} in
                    '|' | ';' | '&' | '#') out="$out " ;;
                    # An escaped SPACE/TAB does not separate words, so emitting
                    # the whitespace itself split `FOO=a\ b bash <gate>` and hid
                    # the gate behind the fragment (panel r11, codex-2). `_`
                    # keeps the word joined and can be neither a path nor a
                    # command name we look for. An escaped QUOTE is data for
                    # the same reason, and emitting it raw unbalanced the same
                    # later walks (HIMMEL-1979).
                    ' ' | "$TAB" | '"' | "'") out="${out}_" ;;
                    *) out=$out${s:$((i + 1)):1} ;;
                esac
                # `p` records the previous character for the word-initial test
                # below. An escaped character — an escaped SPACE above all —
                # keeps bash INSIDE the current word, so a `#` after it does not
                # start a comment; recording a space here let
                # `x\ # tail-pipe-ok: …` fake the opt-out (panel r9, codex-1).
                # 'x' stands for "word character, not a separator".
                p='x'; i=$((i + 2)); continue
                ;;
            '#')
                case $p in
                    ' ' | "$TAB" | "$NL" | '(' | '{' | ';' | '|' | '&')
                        j=$i
                        while [ "$j" -lt "$n" ] && [ "${s:$j:1}" != "$NL" ]; do j=$((j + 1)); done
                        # The marker must OPEN the comment, as documented. A
                        # mere mention — `# no tail-pipe-ok: marker supplied` —
                        # is prose, not an opt-out (panel r11, codex-4).
                        ctext=${s:$((i + 1)):$((j - i - 1))}
                        while :; do
                            case $ctext in
                                ' '* | "$TAB"*) ctext=${ctext#?} ;;
                                *) break ;;
                            esac
                        done
                        case $ctext in 'tail-pipe-ok:'*) out=$out$MARK ;; esac
                        i=$j; p=$NL
                        continue
                        ;;
                esac
                ;;
        esac
        out=$out$c
        p=$c
        i=$((i + 1))
    done
    printf '%s' "$out$extra"
}

# The program a pipeline stage actually RUNS: first token that is neither a
# leading `VAR=value` assignment, a grouping/negation prefix, nor a known
# launcher or compound-command keyword. Empty when there is none.
invoked_program() {
    local tok stripped base skip_next=0 pending='' dq sq launcher='' pos_skip=0
    for tok in $1; do
        if [ -n "$pending" ]; then pending="$pending $tok"; else pending=$tok; fi
        # A quoted span containing spaces arrives as SEVERAL whitespace-split
        # words (`FOO="a b"` -> `FOO="a`, `b"`), and treating the tail half as a
        # command hid the gate behind it (panel r7, codex-1). Keep joining until
        # the quotes balance, then evaluate the whole word. Balance is decided by
        # a STATE walk, not by counting each quote character independently: an
        # apostrophe inside double quotes (`FOO="it's fine"`) is data, and
        # counting it left the word permanently "open", swallowing the rest of
        # the stage and hiding the gate (panel r12, codex-1).
        dq=''; sq=0
        while [ "$sq" -lt "${#pending}" ]; do
            case ${pending:$sq:1} in
                "'" | '"')
                    if [ -z "$dq" ]; then dq=${pending:$sq:1}
                    elif [ "$dq" = "${pending:$sq:1}" ]; then dq=''
                    fi
                    ;;
            esac
            sq=$((sq + 1))
        done
        [ -n "$dq" ] && continue
        stripped=${pending//\"/}
        stripped=${stripped//\'/}
        pending=''
        # A LEADING redirection is not the command (panel r4, codex-1). A bare
        # operator token (`2>`) also swallows the target word that follows it.
        if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
        case $stripped in
            *'>'* | *'<'*)
                case $stripped in *'>' | *'<') skip_next=1 ;; esac
                continue
                ;;
        esac
        # `(`/`{`/`!` glue onto the command they introduce (panel r3, codex-1),
        # and a compact subshell closes onto the LAST word — `(gate|tail)` leaves
        # `tail)` (panel r6, codex-2). Strip both ends.
        while :; do
            case $stripped in
                '('* | '{'* | '!'*) stripped=${stripped#?} ;;
                *')' | *'}') stripped=${stripped%?} ;;
                *) break ;;
            esac
        done
        [ -n "$stripped" ] || continue
        case $stripped in
            [A-Za-z_]*=*) continue ;;                       # env assignment
        esac
        base=${stripped##*/}
        case $base in
            bash | sh | zsh | env | command | exec | nohup | time | sudo | \
            nice | timeout | xargs)
                launcher=$base
                # `timeout` is the one launcher with a POSITIONAL operand — its
                # DURATION — between its options and the program it runs, so
                # `timeout 300 bash <gate> | tail` must step over `300` without
                # mistaking it for the command (HIMMEL-1979).
                [ "$base" = timeout ] && pos_skip=1
                continue ;;
            if | elif | while | until | then | do | else) continue ;;
        esac
        # A launcher's OWN options come between it and the program it runs, so
        # `bash -x <gate>` and `bash -- <gate>` must not stop the walk at the
        # flag (panel r10, codex-1). Only skipped AFTER a launcher: a leading
        # `-something` with no launcher in front of it is not this shape.
        if [ -n "$launcher" ]; then
            # PER-LAUNCHER operand tables (HIMMEL-1979, codex-2 r13). ONE flat
            # launcher-agnostic list got it wrong in both directions, because the
            # same letter means different things per launcher: `-p` is sudo's
            # prompt (an operand) but time's bare portability flag, so
            # `time -p <gate> | tail` stepped over the GATE as if it were -p's
            # operand; and `sudo --user root bash <gate> | tail` had no entry at
            # all, so `root` was returned as the invoked program. Deliberately a
            # small table per launcher, NOT a general option parser: a long
            # option spelled `--opt=value` already carries its operand and falls
            # through to the generic `-*` arm below.
            case $launcher in
                bash | sh | zsh)
                    case $stripped in
                        -c | -o | -O | --rcfile | --init-file) skip_next=1; continue ;;
                    esac ;;
                sudo)
                    # Bare flags here (`-E`, `-n`, `-S`, `-i`) take NO operand —
                    # skipping a word after them would step over the gate. Every
                    # operand-taking option the retired flat list covered stays
                    # covered (panel r1, codex-1): dropping `-D`/`-R`/`-T`/`-U`
                    # would have REGRESSED shapes the hook already caught.
                    case $stripped in
                        -u | --user | -g | --group | -C | --close-from | \
                        -h | --host | -p | --prompt | -D | --chdir | \
                        -R | --chroot | -T | --command-timeout | \
                        -U | --other-user) skip_next=1; continue ;;
                    esac ;;
                env)
                    # `env`'s VAR=val assignments are already stepped over by the
                    # assignment arm above; `-S` DOES take an operand here, which
                    # is exactly what a launcher-agnostic table could not express.
                    case $stripped in
                        -u | --unset | -C | --chdir | -S | --split-string | \
                        -a | --argv0) skip_next=1; continue ;;
                    esac ;;
                nice)
                    case $stripped in -n | --adjustment) skip_next=1; continue ;; esac ;;
                timeout)
                    case $stripped in
                        -s | --signal | -k | --kill-after) skip_next=1; continue ;;
                    esac ;;
                xargs)
                    case $stripped in
                        -I | -n | -P | -L | -d | -a | -s | -E | \
                        --replace | --max-args | --max-procs | --max-lines | \
                        --delimiter | --arg-file | --max-chars | --eof) skip_next=1; continue ;;
                    esac ;;
                exec)
                    case $stripped in -a) skip_next=1; continue ;; esac ;;
                time)
                    # `-p` is the bare portability flag — the whole reason a flat
                    # table failed here — but GNU time's `-f`/`-o` DO take an
                    # operand, and the retired flat list already covered `-o`
                    # (panel r1, codex-2).
                    case $stripped in
                        -f | --format | -o | --output) skip_next=1; continue ;;
                    esac ;;
                # `nohup` and `command` have no operand-taking options:
                # `command -v` is a bare flag.
            esac
            case $stripped in -*) continue ;; esac
            if [ "$pos_skip" -gt 0 ]; then pos_skip=$((pos_skip - 1)); continue; fi
        fi
        printf '%s' "$stripped"
        return 0
    done
}

scan_line() {
    local line=$1 stmts pipeline prog last
    # The opt-out survived normalisation only if it was a real shell comment.
    case "$line" in *"$MARK"*) return 0 ;; esac

    # Statement separators -> newlines, so each remaining line is ONE pipeline.
    # `&&`/`||` are replaced before the `|` split; a lone `&` is left alone on
    # purpose — splitting on it would tear `2>&1` in half.
    stmts=${line//&&/$NL}
    stmts=${stmts//||/$NL}
    stmts=${stmts//;/$NL}

    while IFS= read -r pipeline; do
        case "$pipeline" in *'|'*) ;; *) continue ;; esac
        prog=$(invoked_program "${pipeline%%|*}")
        [ -n "$prog" ] || continue
        printf '%s' "$prog" | grep -Eq "$GATE_RE" || continue
        # Last stage, same command-position walk — so `| env tail`, `| command
        # head` and `| FOO=1 tail` are recognised too (panel r2, codex-1). The
        # leading `&` is the tail of a `|&` operator, not a word.
        last=${pipeline##*|}
        last=${last#&}
        case $(invoked_program "$last") in
            tail | head | */tail | */head) ;;
            *) continue ;;
        esac
        offender=$pipeline
        return 0
    done <<EOF
$stmts
EOF
}

# Fold shell line continuations into ONE logical line, so a pipeline written as
# `gate |` / newline / `tail` is still seen as one pipeline (panel r1, codex-2).
# Runs on the NORMALISED text, so a trailing comment no longer hides the `|` that
# continues the pipeline (panel r3, codex-2). The opt-out is therefore per
# LOGICAL line, which is what "the offending line" means to whoever wrote it.
normalised=$(normalise "$cmd")

# A heredoc makes BODY TEXT indistinguishable from syntax to a scanner this flat
# — and the body of a heredoc in this repo is very often documentation OF this
# very shape (panel r3, codex-3). Withdraw rather than risk denying a command
# whose only `| tail` is data. Same posture as the other fail-open branches.
case $normalised in *"$HEREDOC_MARK"*) exit 0 ;; esac

logical=""
while IFS= read -r raw; do
    rstripped=${raw%"${raw##*[![:space:]]}"}
    case "$rstripped" in
        *'|' | *'|&') logical="$logical$rstripped "; continue ;;
    esac
    scan_line "$logical$raw"
    logical=""
    [ -n "$offender" ] && break
done <<EOF
$normalised
EOF
[ -z "$offender" ] && [ -n "$logical" ] && scan_line "$logical"

[ -n "$offender" ] || exit 0

# printf, not echo: echo joins its arguments with a space, which would leave a
# stray space at the head of every continuation line in this multi-line message.
printf '%s\n' \
  "block-tail-pipe-on-gates: DENIED — this pipes an exit-code-critical himmel gate command into tail/head. Unless the invoking shell has \`pipefail\` set (a Bash tool call cannot assume it does), \$? becomes tail's status (0) and the gate's real exit code is LOST. That misread is what made a gate orchestrator record CLEAR_RC=0 when clear-cr-marker.sh had exited 16 (HIMMEL-1696). Even under pipefail the \`| tail\` throws away the head of the output several incidents needed to diagnose." \
  "Offending pipeline:" \
  "    $(printf '%s' "$offender" | sed 's/^[[:space:]]*//')" \
  "Use the redirect shape instead — it keeps the exit code AND the full output you would otherwise throw away:" \
  "    <cmd> > <file> 2>&1; echo \"RC=\$?\"; tail -80 <file>" \
  "(\${PIPESTATUS[0]} recovers the exit code too, but discards the head of the output that several incidents needed to diagnose.)" \
  "If the exit code genuinely does not matter here, add a same-line marker: \`# tail-pipe-ok: <reason>\`." >&2
exit 2
