#!/usr/bin/env bash
# hook-parse-check.sh — the two shell-quoting checks that matter for a LIVE hook
# file (HIMMEL-2230). It lives in its own file because it has two consumers and
# one implementation is the point:
#
#   * scripts/lint/shell-lint.sh              — folds these findings into its report.
#   * scripts/hooks/check-hook-file-parse.sh  — the PostToolUse guard that runs
#     the instant a scripts/hooks/*.sh is written.
#
# WHY IT EXISTS: the motivating incident put a prose apostrophe inside a
# single-quoted awk program. The apostrophe ended the shell string, the hook
# stopped parsing, and — because a hook file is LIVE the moment it is saved —
# it denied EVERY command fleet-wide. It never reached a commit, so no
# commit-time gate was ever in the path. shellcheck reports the class precisely
# (SC1011) but is OPTIONAL and absent on plenty of hosts; bash is not.
#
# Checks:
#   [parse]        `bash -n` fails — the file does not parse. bash -n parses
#                  without executing, so it is safe to run on any file.
#   [quote-break]  an apostrophe TERMINATED a single-quoted awk/sed/perl program
#                  body: the closing quote is immediately followed by a word
#                  character, AND the word it is glued onto is the tail of a
#                  common English contraction (t/s/re/ll/d/ve/m — "can't",
#                  "it's", "we're", "I'll", "I'd", "I've", "I'm") — the
#                  signature of prose rather than an intended end-of-program
#                  (HIMMEL-2362, private #2018: a bare next-word-char test
#                  alone also fires on an apostrophe-quoted sed program
#                  concatenated onto a following bareword operand, which is
#                  ordinary shell concatenation — the program is complete and
#                  the operand is just the next word glued onto the same
#                  shell word, so THAT shape is NOT flagged; two earlier
#                  discriminators here — "a `#` comment had opened on this
#                  line" and "more than one word remains on the rest of the
#                  line" — were each found independently unreliable across
#                  two CR rounds and replaced by the contraction test; see
#                  the discriminator's own comment below for the specific
#                  false-positive/false-negative shapes that ruled them out).
#                  Inside a single-quoted shell string ANY apostrophe closes it
#                  (there is no escape), so once the word-char signature is
#                  present the only remaining question is whether the
#                  terminator was intended — the contraction test above
#                  answers that. It holds even when the stray quote happens to
#                  re-balance the file so it still parses and [parse] stays
#                  silent: that shape is the one bash -n genuinely cannot see.
#                  After a program's closing quote is resolved, the scan
#                  continues over the REST of the physical line rather than
#                  stopping (HIMMEL-2362, private #2017: a truncated program
#                  past an earlier, complete awk/sed/perl invocation on the
#                  same line used to go unscanned entirely).
#
# Usage:  bash scripts/lint/hook-parse-check.sh FILE [FILE...]
# Output: one "  [tag] ..." line per finding (shell-lint report format).
# Exit:   0 = clean, 1 = findings, 2 = usage error.
# bash 3.2-safe; shellcheck-clean; needs nothing beyond bash + awk.

set -uo pipefail

[ $# -gt 0 ] || { printf 'hook-parse-check: usage: hook-parse-check.sh FILE [FILE...]\n' >&2; exit 2; }

FINDINGS=0

for f in "$@"; do
    [ -f "$f" ] || continue

    # Mirrors shell-lint.sh's _is_shell_file EXACTLY (same two tests, same
    # order) so the two cannot drift apart — HIMMEL-2230 panel round 2,
    # codex-1: both current callers already gate on file type before ever
    # reaching this script (shell-lint.sh via _is_shell_file, the write-time
    # guard via its own scripts/hooks/*.sh scope check), but this is a
    # standalone tool with two consumers already; the guard belongs HERE so
    # a future THIRD caller cannot hand it a .ps1/.py/whatever and get a
    # bogus `bash -n` [parse] finding back. A skipped file prints nothing and
    # never touches FINDINGS.
    case "$f" in
        *.sh) ;;
        *) case "$(head -n1 "$f" 2>/dev/null)" in
               '#!'*sh*) ;;
               *) continue ;;
           esac ;;
    esac

    if ! parse_err="$(bash -n "$f" 2>&1)"; then
        printf '  [parse] %s: %s — the file does not parse; a hook that does not parse DENIES EVERY COMMAND. Commonest cause: a prose apostrophe inside a single-quoted awk/sed/perl program\n' \
            "$f" "$(printf '%s' "$parse_err" | head -n 3 | tr '\n' ' ')"
        FINDINGS=$((FINDINGS + 1))
    fi

    # The apostrophe is built with sprintf(37+2) rather than written literally,
    # so this scanner never flags its own source.
    #
    # A PROCEDURAL WALK, not a wider regex (HIMMEL-2230 panel round 1,
    # codex-2/codex-3): the old opener only traversed `-flag` tokens between
    # the command and the program, so a plain assignment or operand in
    # between (`awk -v n=1 'BEGIN ...`) broke the chain and the whole line
    # was skipped — a false NEGATIVE on an entirely ordinary invocation, and
    # the false-negative direction is the one that matters here. Widening the
    # flag group into a greedy `([[:space:]]+[^[:space:]]+)*` looks tempting
    # but is worse, not better: awk's match() is leftmost-LONGEST, so that
    # group would swallow the quoted program token itself. So: find the
    # command, then walk forward token by token — a token with NO apostrophe
    # (a flag, an assignment, an operand) is traversed; a token that STARTS
    # with the apostrophe is the program opener; anything else (an
    # apostrophe stuck mid-token, e.g. a quoted flag value) is a shape this
    # walk does not model, and it stops rather than guessing.
    qb="$(awk '
        BEGIN { q = sprintf("%c", 39); inprog = 0 }
        {
            line = $0

            # HIMMEL-2362 (private #2017): the old rule handled AT MOST one
            # awk/sed/perl invocation per physical line — it found the
            # program opener, then on the closing quote set inprog = 0 and
            # fell off the end of the rule, so anything AFTER that close on
            # the same line was never scanned. A `sed ...; awk ...` line hid
            # a truncated second program behind a complete first one. This is
            # now a loop: after each closing quote is resolved, `line` is
            # reset to the remainder of the physical line and the scan for
            # another invocation continues, rather than the rule ending.
            # `length(line) > 0` keeps the loop going while there is text
            # left to scan; `|| inprog == 1` also enters it when a program
            # opened but never closed on THIS line (the multi-line-program
            # carry-over from a previous record) — that pass finds no closer
            # either and falls through to the explicit `break` below, which
            # is what leaves inprog == 1 for the next record to continue.
            while (length(line) > 0 || inprog == 1) {
                if (inprog == 0) {
                    # A shell comment is inert — but ONLY skip it here, before
                    # we are inside a program. The motivating incident put its
                    # stray apostrophe inside an awk COMMENT *inside* the
                    # program body, where inprog is already 1; that path must
                    # still be scanned. This also now applies mid-line: a `#`
                    # comment trailing a real invocation (`awk ... # note`)
                    # correctly ends the scan for the rest of the line too.
                    trimmed = line
                    sub(/^[[:space:]]*/, "", trimmed)
                    if (substr(trimmed, 1, 1) == "#") break

                    if (!match(line, /(^|[^[:alnum:]_-])(awk|sed|perl)([[:space:]]|$)/)) break
                    rest = substr(line, RSTART + RLENGTH)

                    # HIMMEL-2230 panel round 2, codex-2: a backslash line
                    # continuation between the command and its program (the
                    # command name ends a line, the quoted program opens on
                    # the NEXT one) is an entirely ordinary shape, and the
                    # walk used to give up the instant it ran off the end of
                    # the PHYSICAL line without finding the opener. A lone
                    # trailing backslash (nothing else left to traverse) pulls
                    # in the next physical line via getline and keeps walking
                    # there instead -- NR/dollar-zero advance with it, so a
                    # finding still names the right line. Any other reason for
                    # running out of tokens (the command was the last thing on
                    # the line, no continuation) still gives up exactly as
                    # before.
                    found = 0
                    while (1) {
                        if (!match(rest, /^[[:space:]]*[^[:space:]]+/)) break
                        tok = substr(rest, RSTART, RLENGTH)
                        stripped = tok
                        sub(/^[[:space:]]*/, "", stripped)
                        if (substr(stripped, 1, 1) == q) {
                            inprog = 1
                            line = substr(rest, RSTART + (length(tok) - length(stripped)) + 1)
                            found = 1
                            break
                        }
                        if (index(stripped, q) > 0) break
                        remainder = substr(rest, RSTART + RLENGTH)
                        if (stripped == "\\" && remainder ~ /^[[:space:]]*$/) {
                            if (getline > 0) { rest = $0; continue }
                            break
                        }
                        rest = remainder
                    }
                    if (!found) break
                }
                pos = index(line, q)
                if (pos == 0) break  # no closer on this line; inprog stays 1, next record continues it
                nxt = substr(line, pos + 1, 1)
                if (nxt ~ /[A-Za-z0-9_]/) {
                    # HIMMEL-2362 (private #2018, replaced again against CR
                    # round 3 codex-1/codex-2/codex-3 on this same PR): a
                    # word character right after the close is necessary but
                    # not sufficient — that shape is ALSO what ordinary
                    # shell concatenation looks like (program complete, a
                    # bareword operand glued onto the same shell word), and
                    # neither "did a `#` comment open earlier on this line"
                    # nor "does more than one word remain on the rest of the
                    # line" turned out to be a reliable enough signal for
                    # that (both tried and replaced here — see below).
                    #
                    # What actually and ONLY distinguishes prose is that in
                    # English, a mid-word apostrophe is (with vanishingly
                    # rare exceptions this heuristic does not chase) a
                    # CONTRACTION — so the fragment glued onto the close is
                    # the tail of one: cannot-apostrophe-t -> t,
                    # it-apostrophe-s / user-apostrophe-s -> s,
                    # we-apostrophe-re -> re, I-apostrophe-ll -> ll,
                    # I-apostrophe-d -> d, I-apostrophe-ve -> ve,
                    # I-apostrophe-m -> m. Test that DIRECTLY: extract the whole word
                    # immediately after the close (the maximal run of word
                    # characters — a bareword operand like `file` is a much
                    # longer, unrelated word and does not match) and flag
                    # only when it is EXACTLY one of those suffixes.
                    #
                    # This replaces two earlier discriminators, both found
                    # to be independently unreliable by the panel:
                    #   - "a `#` had opened on this line before the close":
                    #     both false-negative (codex-2 round 2: a comment
                    #     with NO space before `#`, e.g. a program body of
                    #     `}# can not` with no gap before the truncating
                    #     apostrophe, was not recognized as a comment at all)
                    #     and false-positive (codex-3 round 2: a `#` that is
                    #     part of the program body syntax itself, e.g. a sed
                    #     pattern using `#` mid-regex, is not a comment
                    #     marker either — text
                    #     alone cannot tell a real awk/sed/perl comment from
                    #     a `#` used as ordinary program content, e.g. a sed
                    #     delimiter, without actually parsing that language).
                    #   - "more than one word remains after peeling off the
                    #     first bareword operand": false-positive on ANY
                    #     valid multi-operand invocation (codex-1 round 1:
                    #     redirection/chaining after one concatenated
                    #     operand; codex-1 round 2: a second, space-separated
                    #     file operand concatenated onto a closed sed
                    #     program) — ordinary shell puts no upper bound on
                    #     how many further bareword arguments can legally
                    #     follow.
                    # The contraction-suffix test depends on neither a `#`
                    # nor a word count, so none of those four shapes trip it
                    # (verified: 19i/19m/19n stay silent, 19o still fires).
                    frag = substr(line, pos + 1)
                    sub(/[^A-Za-z0-9_].*$/, "", frag)
                    if (tolower(frag) ~ /^(t|s|re|ll|d|ve|m)$/) { print NR ": " $0 }
                }
                inprog = 0
                line = substr(line, pos + 1)
            }
        }
    ' "$f")"
    if [ -n "$qb" ]; then
        while IFS=: read -r _ln _rest; do
            [ -n "$_ln" ] || continue
            printf '  [quote-break] %s line %s:%s — an apostrophe ended the single-quoted awk/sed/perl program here; the program is truncated. Reword, or double-quote the program\n' \
                "$f" "$_ln" "$_rest"
        done <<EOF
$qb
EOF
        FINDINGS=$((FINDINGS + 1))
    fi
done

[ "$FINDINGS" -eq 0 ] || exit 1
exit 0
