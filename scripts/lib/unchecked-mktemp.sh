#!/usr/bin/env bash
# scripts/lib/unchecked-mktemp.sh -- shared predicate for the unchecked-mktemp
# gate (HIMMEL-2709), used by scripts/hooks/check-unchecked-mktemp.sh and its
# suite so the gate and its tests cannot drift.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# One awk process, no bash-4 constructs (no mapfile, no associative arrays);
# no .ps1 twin, because the only consumers are a shell pre-commit hook and a
# shell suite, both gitbash-only already.
#
# WHY. `T=$(mktemp -d)` with no guard is the single most-repeated defect class
# the CR ledger recorded in the 14 days to 2026-09-07: 10 separate `agreed`
# findings, every one the same shape -- a capture with NO guard at all. When
# mktemp fails the variable is EMPTY, and every path built from it collapses
# to a filesystem-root path -- reviewers named `/repo/.env`, `/bash`, `/bin`
# and `/main` as the concrete targets a failed allocation would then create,
# truncate or delete.
#
# NOT a macOS-portability rule. Whether bare `mktemp -d` (no template) fails
# on macOS was disputed between two CodeRabbit learnings; R1 settled it from
# Apple's shell_cmds source: it fails only on shell_cmds <= 175 (OS X 10.10
# and older) and works from shell_cmds-187 (2015) on
# (<state-repo>/specs/decision/2026-09-22-mktemp-macos-verdict.md). This gate
# does not depend on that: mktemp can fail on any platform (full disk,
# missing or unwritable TMPDIR, read-only mount), and the unchecked capture
# is the defect wherever it runs.
#
# soak: 2026-09-22 (landing) · 0 commits-in-scope · 0 FPs -- himmel-only
# (repo: local), NOT in .pre-commit-hooks.yaml; export only after >= 14 days
# on main, >= 20 merged commits touching *.sh, zero false positives.
#
# unchecked_mktemp_scan <path>
#   Prints one `<lineno>\t<trimmed source line>` record per OFFENDING mktemp
#   assignment in <path>, and returns 0 whether or not it found any -- it is a
#   scan, not a verdict, so callers own their own PASS/FAIL wording. A nonzero
#   return means the scan itself could not run.
#
# THE CONTRACT (deliberately simplified -- see below for why): a capture is
# OFFENDING when it has NO guard signal AT ALL. Any ONE of these counts as a
# guard, with no judgement about whether it is a GOOD guard:
#   (a) the assignment line carries a `||` ANYWHERE on it, full stop -- no
#       check on what the right-hand side says or does.
#   (b) the assignment line carries the escape `# mktemp-unchecked-ok: <reason>`.
#   (c) a test construct referencing the variable -- `[ ... ]`, `[[ ... ]]`, or
#       `test ...` (this also covers the variable being an if/while/until
#       condition, since that condition is itself one of these constructs) --
#       either in the REMAINDER of the assignment line (everything after the
#       mktemp command substitution closes, e.g. `T=$(mktemp -d); [ -n "$T" ]`)
#       or in one of the next 3 non-blank lines.
#   (d) `${VAR:?...}` -- the COLON form ONLY -- in that same same-line-remainder-
#       or-next-3-lines window. `${VAR?...}` (no colon) does NOT count: it
#       aborts only when VAR is UNSET, but a failed mktemp leaves VAR
#       set-but-EMPTY, so it never fires on the failure this gate exists to
#       catch.
#
# EXCEPT: a declaration-prefixed capture (`local`/`export`/`declare`/
# `typeset`/`readonly`) never accepts a same-line `||` as a guard, because the
# declaration builtin's own exit status (always 0) is what `||` sees, never
# mktemp's. This exception is scoped to rule (a) ONLY: a same-line VALUE
# guard -- rule (c)'s test construct or rule (d)'s `${VAR:?...}` -- inspects
# the variable's actual value, not the builtin's exit status, so it guards a
# declaration-prefixed line correctly regardless of the declaration in front
# of it (round-4 fix). An earlier version of this predicate rejected `local
# T=$(mktemp -d); : "${T:?x}"` for the same reason it rejects `local
# T=$(mktemp -d) || exit 1`, which conflated the two -- `${VAR:?...}` never
# consults an exit status at all, so the declaration builtin masking mktemp's
# is irrelevant to it. Rules (b)-(d) already applied normally from the NEXT
# 3 lines onward for every assignment; this fix makes the SAME-line window
# consistent with that for (c)/(d), while rule (a) keeps its exception. The
# remedy for a same-line `||` on a declaration-prefixed line stays: split the
# declaration from the assignment: `local VAR; VAR=$(mktemp -d) || exit 1`.
#
# Lines inside a heredoc BODY are skipped entirely -- never scanned as a
# candidate assignment, never counted toward the guard window of a real
# assignment above or below them -- but ONLY when BOTH of these hold
# (round-4 fix, closing a fail-open hole in the prior version):
#   (a) the delimiter is QUOTED -- `<<'WORD'`/`<<"WORD"`, or the `<<-'WORD'`/
#       `<<-"WORD"` dash forms. An UNQUOTED `<<WORD` heredoc performs
#       expansion and command substitution, so `T=$(mktemp -d)` written
#       inside one genuinely EXECUTES and must still be scanned like any
#       other line.
#   (b) a matching terminator line actually exists LATER in the file. If none
#       is found, the opener is ordinary code and nothing is skipped.
# The prior version skipped on the opener alone, regardless of quoting or
# whether a terminator ever appeared, so ordinary logging such as
# `echo "<<EOF"` could hide every later unchecked capture until (or unless) a
# line happened to read exactly `EOF` -- a SILENT MISS in a gate documented
# fail-closed. (a)+(b) together shrink that hole to "a quoted-delimiter
# opener embedded in a string AND a matching lone terminator later in the
# same file", which is a shape that does not occur outside a deliberate
# heredoc fixture.
#
# MEASUREMENT: across every tracked *.sh in this repo, a heredoc-embedded
# mktemp capture is rare -- essentially only this gate's own suite (which
# builds heredoc fixtures on purpose) and scripts/lint/test-shell-lint.sh.
# That is what makes (a)+(b) a narrow, cheap rule rather than a parser: the
# real shape worth protecting is "literal fixture text in a quoted heredoc",
# not general heredoc bodies, and general shell quote-state tracking is
# deliberately out of scope -- two review rounds were already lost to
# unbounded lexing (see above); this stays bounded.
#
# A shell fixture written inline as a heredoc (a fixture in this repo's own
# test suites, say) is text a consuming script writes to disk, not a
# statement this file ever executes -- flagging it is a false positive with
# no real escape, since `# mktemp-unchecked-ok:` written inside a quoted
# heredoc body would corrupt the fixture's content. An opener token appearing
# after a `#` on the same line is ignored (it is commentary, not a real
# heredoc).
#
# WHY THIS IS SIMPLER THAN IT USED TO BE. An earlier version of this predicate
# tried to classify guard QUALITY: an allowlist of "terminating verbs"
# (exit/return/fail/die/continue/break, plus scanning into a same-line
# `{ ...; }` block) for rule (a), and a "consequential test" requirement
# (chained with `||`/`&&`, or the condition of an if/while/until) for rule
# (c). Two review rounds later, every tightening had bought one hole and sold
# another -- including a false POSITIVE the tightening itself introduced: the
# house multiline form
#     scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")" || {
#         echo "FAIL..." >&2
#         exit 1
#     }
# was REJECTED, because only the assignment line was searched for a
# terminating verb and that line's RHS is just `{` -- this gate flagged its
# own sibling files. All 10 measured CR-ledger recurrences were the BARE
# shape -- a capture with no guard whatsoever; none were "wrote a guard that
# doesn't really guard". So classifying guard quality is not where this
# gate's value is, and it is where every review round kept going. Rule (a)
# alone (any `||`, no matter what it does) makes the multiline case above
# pass for free, with no multiline block-parsing needed at all.
#
# ACCEPTED, DOCUMENTED false negatives under this contract (deliberate --
# do not "fix" these by re-adding quality checks; that is the loop above):
#   * `T=$(mktemp -d) || echo failed`   -- a `||` that does not terminate.
#   * `[ -n "$T" ] || echo failed`      -- a following test that does not
#     terminate.
#
# `if ! G=$(mktemp -d); then` is not an assignment statement by this pattern
# and is never flagged -- it is already guarded by its own condition.
#
# NOT a guard, deliberately: `T=$(mktemp -d); trap 'rm -rf "$T"' EXIT`. That is
# the hazard, not the cure -- an empty $T makes the trap itself the destructive
# operation.
#
# Sourced, never executed. Sets no shell options of its own.

unchecked_mktemp_scan() {
    local path="$1"
    [ -f "$path" ] || return 1
    awk '
    BEGIN {
        sq = sprintf("%c", 39)  # a literal single-quote char, built this way
                                 # so none of this program text has to embed
                                 # one (the whole script is single-quoted by
                                 # its caller).
    }
    {
        line[NR] = $0
    }
    # heredoc_word(s) -- if s opens a heredoc (and the opener is not itself
    # inside a "#" comment), return its terminator word and set HEREDOC_DASH
    # and HEREDOC_QUOTED (1 iff the delimiter was quoted -- a single- or double-quoted WORD
    # -- rather than bare); otherwise return "".
    function heredoc_word(s,    p, rest, c, word, hashpos) {
        p = index(s, "<<")
        if (p == 0) return ""
        if (substr(s, p + 2, 1) == "<") return ""   # here-string "<<<", skip
        hashpos = index(s, "#")
        if (hashpos > 0 && hashpos < p) return ""   # opener is commentary
        rest = substr(s, p + 2)
        HEREDOC_DASH = 0
        if (substr(rest, 1, 1) == "-") { HEREDOC_DASH = 1; rest = substr(rest, 2) }
        while (substr(rest, 1, 1) == " " || substr(rest, 1, 1) == "\t")
            rest = substr(rest, 2)
        HEREDOC_QUOTED = 0
        if (substr(rest, 1, 1) == sq || substr(rest, 1, 1) == "\"") {
            HEREDOC_QUOTED = 1
            rest = substr(rest, 2)
        }
        word = ""
        while (1) {
            c = substr(rest, 1, 1)
            if (c ~ /^[A-Za-z0-9_]$/) { word = word c; rest = substr(rest, 2) }
            else break
        }
        return word
    }
    # remainder_after_capture(s) -- the text of s AFTER the closing paren of
    # its first `$(...)`, tracking nested parens so a template like
    # `$(mktemp -d "$(pwd)/x")` still resolves to the true outer close.
    # Returns "" if unbalanced (never seen in practice; fails safe to "no
    # remainder to scan" rather than guessing).
    function remainder_after_capture(s,    p, depth, i, n, c) {
        p = index(s, "$(")
        if (p == 0) return ""
        depth = 1
        i = p + 2
        n = length(s)
        while (i <= n && depth > 0) {
            c = substr(s, i, 1)
            if (c == "(") depth++
            else if (c == ")") depth--
            i++
        }
        if (depth != 0) return ""
        return substr(s, i)
    }
    END {
        # Pass 1: mark every line inside a heredoc body (skip[i]=1) so the
        # scan below never treats fixture content as executable code. Two
        # conditions gate the skip, both required (round-4 fix, closing a
        # fail-open hole): the delimiter must be QUOTED (an unquoted heredoc
        # expands and executes, so a capture inside one is real code), and a
        # matching terminator must actually exist LATER in the file -- an
        # opener with no terminator (e.g. a quoted-delimiter opener echoed inside a log string)
        # is ordinary code, not a heredoc, and nothing is skipped for it.
        for (i = 1; i <= NR; i++) skip[i] = 0
        i = 1
        while (i <= NR) {
            w = heredoc_word(line[i])
            if (w != "" && HEREDOC_QUOTED) {
                term_dash = HEREDOC_DASH
                term_idx = 0
                for (j = i + 1; j <= NR; j++) {
                    chk = line[j]
                    if (term_dash) sub(/^\t+/, "", chk)
                    if (chk == w) { term_idx = j; break }
                }
                if (term_idx > 0) {
                    for (k = i + 1; k <= term_idx; k++) skip[k] = 1
                    i = term_idx + 1
                    continue
                }
            }
            i++
        }

        for (i = 1; i <= NR; i++) {
            if (skip[i]) continue
            s = line[i]
            # An assignment capturing mktemp through command substitution.
            if (s !~ /^[ \t]*(local[ \t]+|export[ \t]+|typeset[ \t]+|readonly[ \t]+|declare[ \t]+(-[a-zA-Z]+[ \t]+)?)?[A-Za-z_][A-Za-z0-9_]*="?\$\([ \t]*mktemp/)
                continue

            # A declaration builtin (local/export/declare/typeset/readonly)
            # masks the command substitution exit status with its own -- a
            # same-line `||` never sees a mktemp failure on these lines, so
            # rule (a) never applies to them. (Rules (c)/(d) are NOT gated by
            # this -- see below -- because they read the actual value of the variable,
            # not the exit status of the builtin.)
            is_decl = (s ~ /^[ \t]*(local|export|typeset|declare|readonly)([ \t]+-[a-zA-Z]+)?[ \t]+/)

            # Rule (a): a `||` ANYWHERE on the line guards it, full stop --
            # no judgement about what the right-hand side does.
            if (!is_decl && s ~ /\|\|/) continue

            # Rule (b): the escape comment.
            if (index(s, "mktemp-unchecked-ok:") > 0) continue

            # Recover the variable name: the token immediately before the `=`
            # that opens the command substitution.
            head = s
            sub(/="?\$\([ \t]*mktemp.*$/, "", head)
            var = head
            sub(/^.*[^A-Za-z0-9_]/, "", var)
            if (var == "") continue

            guarded = 0

            # Rules (c)/(d) on the REMAINDER of the assignment line itself
            # (e.g. `T=$(mktemp -d); : "${T:?x}"`) -- these are VALUE guards
            # (a test of the actual value of the variable, or `${VAR:?...}`), which
            # read the variable correctly regardless of a declaration
            # builtin masked exit status, so -- unlike rule (a) -- this
            # window applies to every assignment, declaration-prefixed or not
            # (round-4 fix).
            rem = remainder_after_capture(s)
            if (rem != "") {
                if (rem ~ ("(\\[\\[?|test)[ \t].*\\$\\{?" var "[^A-Za-z0-9_]")) guarded = 1
                if (!guarded && rem ~ ("\\$\\{" var ":\\?")) guarded = 1
            }

            # Rules (c) and (d): within the next 3 non-blank, non-heredoc-body
            # lines -- this applies to every assignment, declaration-prefixed
            # or not.
            if (!guarded) {
                seen = 0
                for (j = i + 1; j <= NR && seen < 3; j++) {
                    if (skip[j]) continue
                    t = line[j]
                    if (t ~ /^[ \t]*$/) continue
                    seen++
                    # (c) a test construct referencing the variable.
                    if (t ~ ("(\\[\\[?|test)[ \t].*\\$\\{?" var "[^A-Za-z0-9_]")) { guarded = 1; break }
                    # (d) `${VAR:?...}` -- colon form only (not `${VAR?...}`).
                    if (t ~ ("\\$\\{" var ":\\?")) { guarded = 1; break }
                }
            }
            if (guarded) continue

            trimmed = s
            sub(/^[ \t]+/, "", trimmed)
            printf "%d\t%s\n", i, trimmed
        }
    }
    ' "$path"
}
