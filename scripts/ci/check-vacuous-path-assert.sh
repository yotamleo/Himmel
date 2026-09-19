#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# Pre-commit gate: flag an emptiness assertion whose shell-test-suite line
# follows an AMBIENT hermetic-PATH scrub in the same file, hence vacuous by
# construction — the class HIMMEL-2812 found (himmel-dev only).
#
# Why line-oriented, not scope-aware: this codebase's SAFE, normal idiom is
# the per-command prefix (`PATH=... bash "$SCRIPT"` / `env PATH=... cmd`),
# which scopes the override to one subprocess and never touches the calling
# shell's own PATH. The unsafe shape is a bare `PATH=` / `export PATH=`
# assignment — the whole statement, no command word trailing it — which
# persists into every line the calling shell runs afterward, INCLUDING an
# emptiness assertion (`[ -z "$(cmd ...)" ]`) that the author believes still
# sees the real PATH. A precise detector would need to model shell scope and
# restoration (a later `PATH=$OLD_PATH`, a subshell, a function boundary);
# this one deliberately does not — it flags the co-occurrence and leaves the
# call on whether it is real to the reader, via a same-line
# `# vacuous-path-ok: <reason>` marker (HIMMEL-2957).
#
# A THIRD safe idiom the whole-tree run surfaced: an ambient assignment
# whose value verbatim retains `$PATH`/`${PATH}` as a component
# (`export PATH="$stub:$PATH"`) can only ADD entries, never remove one --
# no later assertion's tool lookup can be made vacuous by a pure prepend,
# so it is excluded from pattern A below. A `$(...)` command substitution
# (e.g. `scrub_path "$PATH" tool`) does NOT get this pass: it may take
# $PATH as an input and still reduce it. The reference must also sit at a
# complete path-component boundary (value start/end, or a colon) on both
# sides — `PATH="/nonexistent$PATH"` and `PATH="${PATH}/suffix"` instead
# MERGE a bogus segment onto the first/last real entry with no colon
# between them, silently dropping it, so neither counts as preserving
# (CR round 3, codex-2). This boundary rule also resolves the round-2
# codex-1 gap where a single-quoted `PATH='$PATH'` literal was misread as
# preserving: the `'` immediately before the reference is not a boundary.
#
# Known limitations (deferred, HIMMEL-2957 — both rare and either
# under-flagging in a way a reviewer would still catch, or an explicit
# ticket-design tradeoff, not a detector defect to fix here):
#   - A single-quoted value that STILL has a colon on both sides of a
#     literal `$PATH` (`PATH='/stub:$PATH:/other'`) passes the boundary
#     check and is read as preserving, even though single quotes suppress
#     expansion entirely and the assignment does not preserve anything
#     (CR round 4, codex-2).
#   - The multi-operand `export` scan (HIMMEL-3015) tokenizes double-quoted
#     values but not single-quoted ones, so a single-quoted operand holding
#     a space (`export PATH=/stub OTHER='a b'`) ends the scan unterminated
#     and the line is NOT flagged — an under-flag, rare, and the same
#     failure direction as the pre-fix behaviour.
#   - Pattern B matches both `-z` and `-n`; a `-n` (non-emptiness)
#     assertion after a real PATH break fails loudly rather than passing
#     vacuously, so flagging it is noise, not a missed vacuous pass — kept
#     symmetric with `-z` per the ticket's own design (CR round 4, codex-3).
#
# Usage:
#   check-vacuous-path-assert.sh              # tree-walk: every git-tracked
#                                              # scripts/**/test-*.sh
#   check-vacuous-path-assert.sh <file>...     # check only these files
#                                              # (pre-commit passes staged ones)
#
# Exit: 0 clean · 1 findings (printed, one per line) · 2 cannot evaluate
#       (fail-closed).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# himmel-dev only: an adopter who vendored the repo never agreed to this
# check and maintains their own test suites. Mirrors check-claude-md-budget.
# shellcheck source=scripts/guardrails/lib.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/guardrails/lib.sh"
rc=0
# shellcheck disable=SC2119  # deliberately called with no args to use its DIR default (.)
is_himmel_dev_repo || rc=$?
if [ "$rc" -eq 1 ]; then exit 0; fi
if [ "$rc" -eq 2 ]; then echo "→ vacuous-path-assert: cannot resolve repo root — fail-closed" >&2; exit 2; fi

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    # Tree walk: every git-tracked scripts/**/test-*.sh, mirroring
    # run-shell-tests.sh's own `find -H ... -name 'test-*.sh'` discovery, then
    # filtered to tracked paths so a scratch/untracked fixture is never scanned.
    tmp_list="$(mktemp "${TMPDIR:-/tmp}/vacuous-path-assert-list.XXXXXX")" || {
        echo "→ vacuous-path-assert: mktemp failed — fail-closed" >&2; exit 2
    }
    trap 'rm -f "$tmp_list"' EXIT
    if ! find -H "$REPO_ROOT/scripts" -name 'test-*.sh' -print > "$tmp_list" 2>/dev/null; then
        echo "→ vacuous-path-assert: tree walk failed — fail-closed" >&2; exit 2
    fi
    files=()
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if git -C "$REPO_ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
            files+=("$f")
        fi
    done < "$tmp_list"
fi

fail=0
for f in "${files[@]}"; do
    [ -f "$f" ] || { echo "→ vacuous-path-assert: no such file: $f" >&2; exit 2; }
    out="$(LC_ALL=C awk '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

        # Parse the value of one NAME=value assignment starting at rest.
        # Sets tv_val (the value), tv_rem (what follows it) and tv_pres (1
        # when a verbatim PATH reference means the value can only ADD
        # entries).
        function take_value(rest) {
            tv_val = ""; tv_rem = ""; tv_pres = 0
            if (match(rest, /^"\$\(.*\)"/)) {
                # A quoted command substitution, e.g.
                # PATH="$(scrub_path "$PATH" tool)" -- the greedy .*
                # reaches the LAST )" on the line, so an inner quoted
                # $PATH argument does not truncate the match early
                # (CR round 1, codex-1: the plain quoted-string branch
                # below stops at that inner quote and silently misses
                # this ambient scrub).
                tv_val = substr(rest, RSTART, RLENGTH)
                tv_rem = substr(rest, RSTART + RLENGTH)
                tv_pres = 0
            } else if (match(rest, /^"[^"]*"/)) {
                tv_val = substr(rest, RSTART, RLENGTH)
                tv_rem = substr(rest, RSTART + RLENGTH)
                # A $PATH/${PATH} reference only preserves the ORIGINAL
                # entries when it sits at a complete path-component
                # boundary (start/end of the value, or a colon) on both
                # sides -- `"/nonexistent$PATH"` and `"${PATH}/suffix"`
                # instead MERGE a bogus segment onto the first/last real
                # entry with no colon between them, silently dropping it
                # (CR round 3, codex-2). This boundary requirement also
                # resolves the round-2 codex-1 single-quote-literal gap:
                # a single-quoted PATH assignment has a quote character
                # immediately before the reference, which is not a
                # boundary char either.
                tv_pres = (tv_val ~ /(^|[:"])\$\{?PATH\}?([:"]|$)/)
            } else if (match(rest, /^\$\(.*\)/)) {
                tv_val = substr(rest, RSTART, RLENGTH)
                tv_rem = substr(rest, RSTART + RLENGTH)
                # A command substitution (e.g. scrub_path) may REDUCE
                # PATH even when it takes $PATH as an input argument --
                # never treat this branch as preserving.
                tv_pres = 0
            } else if (match(rest, /^[^ \t;]+/)) {
                # An unquoted word ends at an unquoted `;` -- the command
                # separator is not part of the value, so `PATH=/stub; cmd`
                # leaves `; cmd` as the remainder (HIMMEL-3015).
                tv_val = substr(rest, RSTART, RLENGTH)
                tv_rem = substr(rest, RSTART + RLENGTH)
                tv_pres = (tv_val ~ /(^|[:"])\$\{?PATH\}?([:"]|$)/)
            }
        }

        # 1 when an `export` line assigns a non-preserving PATH among its
        # operands and the statement ends cleanly (end of line, comment, `;`,
        # `&&`, `||`); 0 otherwise. Each operand is NAME or NAME=value, so
        # `export PATH=/stub OTHER=1` and `export OTHER=1 PATH=/stub` both
        # count, while PATH_X is a different name (HIMMEL-3015).
        function export_scrubs(s,   name, hit) {
            sub(/^[ \t]*export[ \t]+/, "", s)
            hit = 0
            while (match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) {
                name = substr(s, RSTART, RLENGTH)
                s = substr(s, RSTART + RLENGTH)
                if (substr(s, 1, 1) == "=") {
                    take_value(substr(s, 2))
                    if (name == "PATH" && !tv_pres) { hit = 1 }
                    s = tv_rem
                }
                s = trim(s)
                if (s == "" || s ~ /^#/ || s ~ /^;/ || s ~ /^(&&|\|\|)/) { return hit }
            }
            return 0
        }
        {
            line = $0

            # ── Heredoc bodies are DATA, not code the enclosing shell runs
            # ambiently -- a fixture inside a quoted heredoc can legitimately
            # contain the exact vacuous shape under test without being a live
            # assertion (HIMMEL-2957 self-scan false positive: this
            # detectors own test suite embeds such fixtures as heredoc
            # bodies). Skip pattern A/B entirely while inside one.
            if (in_heredoc) {
                term_check = line
                if (heredoc_dash) { sub(/^\t+/, "", term_check) }
                if (term_check == heredoc_term) { in_heredoc = 0 }
                next
            }

            # ── Detect an ambient PATH mutation (pattern A) ──────────────────
            isA = 0
            if (line ~ /^[ \t]*\(.*PATH=.*\)[ \t]*(#.*)?$/) {
                # A one-line ( … ) subshell scopes the whole thing to itself.
                isA = 0
            } else if (line ~ /^[ \t]*env[ \t]/) {
                isA = 0
            } else if (line ~ /^[ \t]*export[ \t]/) {
                # Every operand of the export is scanned, so a trailing
                # `OTHER=1` (or PATH in a later position) cannot hide the
                # scrub behind a leading operand (HIMMEL-3015).
                isA = export_scrubs(line)
            } else if (match(line, /^[ \t]*PATH=/)) {
                take_value(substr(line, RSTART + RLENGTH))
                remainder = trim(tv_rem)
                if (remainder == "" || remainder ~ /^#/ || remainder ~ /^;/ || remainder ~ /^(&&|\|\|)/) {
                    # A verbatim $PATH / ${PATH} reference retained in the
                    # assigned value means this assignment can only ADD
                    # entries, never remove one -- no later assertions tool
                    # lookup can be made vacuous by it (HIMMEL-2957 tree-run
                    # false positives: export PATH="$stub:$PATH" idioms).
                    if (!tv_pres) { isA = 1 }
                }
            }
            if (isA) { lastA = NR }

            # ── Detect an emptiness assertion (pattern B) ────────────────────
            if (lastA > 0 && line ~ /\[\[?[ \t]+-[zn][ \t]+"?\$\(/) {
                if (line !~ /#[ \t]*vacuous-path-ok:/) {
                    printf "%s:%d: vacuous-path-assert: emptiness assertion after ambient PATH scrub at line %d\n", FILENAME, NR, lastA
                    found = 1
                }
            }

            # ── Enter a heredoc: everything up to the matching terminator is
            # DATA for the enclosing shell, not statements it runs. A
            # commented mention (`# see: cat <<EOF`, or a trailing
            # `echo ready # example: cat <<EOF`) is not a live redirect --
            # without stripping the comment first, either shape would
            # falsely open heredoc state and silently skip every real line
            # after it, including the assertion this detector exists to
            # catch (CR round 2 codex-2: whole-line; CR round 3 codex-1:
            # trailing). A here-string (`cat <<<EOF`) is a single self-
            # contained expression, never a multi-line redirect -- its
            # third `<` would otherwise let the `<<` half of the pattern
            # match starting one character in, wrongly opening heredoc-skip
            # state with no real terminator to ever close it (CR round 4,
            # codex-1). Strip any `<<<` run before the heredoc-open check so
            # only a genuine `<<`/`<<-` survives.
            hd_line = line
            sub(/(^[ \t]*|[ \t])#.*$/, "", hd_line)
            gsub(/<<</, "", hd_line)
            if (match(hd_line, /<<-?[ \t]*["'"'"'][A-Za-z_][A-Za-z0-9_]*["'"'"'][ \t]*$/) || match(hd_line, /<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) {
                seg = substr(hd_line, RSTART, RLENGTH)
                heredoc_dash = (seg ~ /^<<-/)
                term = seg
                sub(/^<<-?[ \t]*/, "", term)
                gsub(/["'"'"']/, "", term)
                sub(/[ \t]+$/, "", term)
                heredoc_term = term
                in_heredoc = 1
            }
        }
        END { exit (found ? 1 : 0) }
    ' "$f")"
    awk_rc=$?
    if [ "$awk_rc" -eq 1 ]; then
        printf '%s\n' "$out"
        fail=1
    elif [ "$awk_rc" -ne 0 ]; then
        echo "→ vacuous-path-assert: cannot scan $f — fail-closed" >&2
        exit 2
    fi
done

exit "$fail"
