#!/usr/bin/env bash
# scripts/lib/red-control-lint.sh -- advisory lint for vacuous mutation
# controls (HIMMEL-2544, item 2; contract from HIMMEL-2518).
#
# WHAT IT DETECTS
# A mutation control proves a test assertion is non-vacuous. The silent failure
# mode the contract in scripts/lib/red-control.sh names: a control written as an
# inequality/absence check ("the mutant's value differs from the correct one")
# is SATISFIED by a mutant that crashed, exited early or emitted nothing,
# because the empty string differs from everything. Such a control prints
# "RED confirmed" while proving nothing. This lint reports the shape: a
# "RED confirmed" line whose enclosing conditional tests ONLY an inequality
# (`!=`) or a bare file-existence test (`-e`/`-f`), with the mutant's exit
# status never compared anywhere in that block.
#
# WHY IT IS ADVISORY AND NEVER A GATE
# It exits 0 ALWAYS -- with hits, without hits, and on internal error. That is
# deliberate and load-bearing: a nonzero exit is all anybody needs to wire a
# heuristic text-matcher into a pre-commit hook or CI job by accident, and this
# matcher is a heuristic. It reads source and writes only two mktemp files (a
# stderr capture and the directory listing, both removed on exit). Run it on
# demand;
# read the hits; decide. Its hit list is empty on main by construction, so any
# line it prints is new -- but that is an invariant maintained at REVIEW time,
# deliberately not enforced by any suite or CI job. Its own smoke test scans the
# real tree and REPORTS; it does not fail on hits (CR round 1 [codex-3]).
#
# KNOWN LIMITS -- real gaps, stated rather than papered over:
#   * It anchors on the literal convention string "RED confirmed". A mutation
#     control that does not print that phrase is INVISIBLE to this lint. That is
#     the biggest gap and it is structural: there is no other reliable marker.
#   * It reads the nearest preceding `if`/`elif` line only, so a condition split
#     across a line continuation, or a control whose real guard is a `case` or a
#     `&&` chain on a bare command, is not classified.
#   * A test mixing any other comparison (`-eq`, `-z`, ` = `, `=~`, ...) into the
#     conditional is left alone, so the report skews to FALSE NEGATIVES. For an
#     advisory tool that is the right direction: every printed line should be
#     worth a human's minute.
#   * For a seed inside NO conditional the compliance scan falls back to a flat
#     40-line window, so a nearby `red_control_*` call can still suppress it.
#     That path only reaches controls this lint could not classify anyway.
#   * A seed in the ELSE branch of a conditional is classified against that
#     conditional's test, which the else branch actually NEGATES. The verdict
#     can therefore be wrong in either direction for that shape.
#   * It is a LINE-BASED TEXT MATCHER and cannot reliably tell executable shell
#     from text. The echo/printf rule closes the common diagnostic family -- a
#     control's own error message crediting it with a check it never made -- but
#     not the general problem: a comparison hidden in a command substitution, a
#     heredoc, an `eval`, or a message built by some other command is out of
#     reach. The detector is not sound and does not claim to be.
#   * The exit-status rules are heuristics, not proof. A `$?` comparison ON the
#     conditional line is credited, but `$?` refers to whatever ran last and
#     this lint cannot prove that was the mutant. The captured-variable shape
#     (`rc=$?` recorded, compared later, which red_control_run enforces) is the
#     only reliable one; `$?` is credited as a courtesy to hand-rolled controls.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure shell plus grep/awk -- no .ps1 twin, because the only thing it reads is
# the repo's shell test suites, which are themselves gitbash-only. This is the
# T15 marker scripts/parity/test-ws5-invariants.sh looks for.
#
# Usage: bash scripts/lib/red-control-lint.sh [PATH...]
#   PATH may be a file or a directory; directories are walked for *.sh.
#   With no PATH, the repo's scripts/ directory is scanned, resolved from this
#   script's own location (never from $PWD, so the default root does not depend
#   on where it is invoked from).
# Output: one `<file>:<line> <reason>` line per hit on stdout, nothing else.
#   Zero hits prints nothing on stdout; a one-line summary goes to stderr.
set -uo pipefail

# The only two files this tool writes: a capture of find's / awk's stderr, and
# the directory listing itself. Both exist so a FAILED step can be REPORTED
# rather than silently read as clean. Pinned ONCE here, before the trap that
# consumes them, and never repointed (HIMMEL-2503). If the stderr capture cannot
# be created the scan still runs -- the exit-status checks below are what detect
# a failure; the capture only supplies the detail.
ERRF="$(mktemp "${TMPDIR:-/tmp}/red-control-lint.XXXXXX" 2>/dev/null)" || ERRF=""
FINDF="$(mktemp "${TMPDIR:-/tmp}/red-control-lint-list.XXXXXX" 2>/dev/null)" || FINDF=""

# Report-only, enforced structurally: whatever happens below -- a hit, a `set -u`
# violation, a missing awk -- the process exits 0. See "WHY IT IS ADVISORY".
trap 'rm -f ${ERRF:+"$ERRF"} ${FINDF:+"$FINDF"}; exit 0' EXIT

usage() {
    cat <<'USAGE'
Usage: bash scripts/lib/red-control-lint.sh [PATH...]

Advisory lint (HIMMEL-2544): reports mutation controls whose only assertion is
an inequality or a bare file-existence test, with the mutant's exit status never
compared -- the vacuous shape scripts/lib/red-control.sh exists to replace.

  PATH   a file or directory to scan (directories are walked for *.sh).
         Defaults to the repo's scripts/ directory.

Prints one "<file>:<line> <reason>" line per hit on stdout. Report-only: the
exit status is ALWAYS 0, so this can never be wired up as a gate.
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

roots=()
if [ "$#" -gt 0 ]; then
    for r in "$@"; do roots+=("$r"); done
else
    roots=("$DEFAULT_ROOT")
fi

# How far above a "RED confirmed" line the enclosing conditional may sit, and
# the same window used to spot the contract helper's own machinery.
WINDOW=40

# The detector. One awk pass per candidate file; the file is buffered so the
# walk can go both up (to the conditional) and down (to the matching `fi`).
AWK_PROG=$(cat <<'AWK'
# nif/nfi -- crude `if`/`fi` counting, enough to find the end of the block that
# a given `if` opens. `elif` is deliberately not counted as an opener.
function nif(s,   n, t) {
    n = 0; t = s
    while (match(t, /(^|[ \t;&|(])if[ \t]/)) { n++; t = substr(t, RSTART + RLENGTH) }
    return n
}
function nfi(s,   n, t) {
    n = 0; t = s
    while (match(t, /(^|[ \t;&|])fi([ \t;&|)]|$)/)) { n++; t = substr(t, RSTART + RLENGTH) }
    return n
}
BEGIN {
    # CMP -- what counts as a comparison anywhere on a line. Used by the `$?`
    # rule, where the operand is unambiguous because `$?` IS the status.
    CMP = "(-eq|-ne|-gt|-lt|-ge|-le|==|!=|[^!<>=]=[ \t])"
    # RCCMP -- an rc-ish VARIABLE actually standing next to a comparison
    # operator, on either side: `[ "$rc" -eq 0 ]`, `[ $rc != 0 ]`,
    # `[ "$_rc" = 14 ]`, `[ 0 -ne "$rc" ]`. CR round 4 [codex-1]: the old rule
    # asked only that an rc-ish variable AND some comparison token appear on the
    # same line, which a DIAGNOSTIC MESSAGE satisfies --
    # `echo "R4 RED confirmed: got != want (rc=$rc)"` bought a full exemption
    # from its own error text. Adjacency is what makes it a comparison OF the
    # status rather than a comparison near a mention of it.
    RCVAR = "[$][{]?([A-Za-z_][A-Za-z0-9_]*_)?[Rr][Cc][}]?"
    OP    = "(-eq|-ne|-gt|-lt|-ge|-le|==|!=|=)"
    RCCMP = RCVAR "[\"']?[ \t]+" OP "[ \t]" "|" OP "[ \t]+[\"']?" RCVAR
}
# ev_text -- the part of a line that is allowed to establish exit-status
# evidence: every command segment EXCEPT the ones whose command word is `echo`
# or `printf`. CR round 5 [codex-1]: rounds 1 and 4 each patched one SPELLING of
# the same defect -- a control's own human-readable message satisfying an
# exit-status rule (`(rc=$rc)`, then `$rc != 0` inside quotes). Chasing prose
# with regexes is an arms race, so the class is closed instead: a diagnostic IS
# an echo/printf, while a real check is `[ ... ]`, `test ...` or `--expect-rc`,
# none of which start with echo/printf.
#
# Segments split on ; && || | & at the TOP level -- separators inside quotes do
# not split, so a message containing them stays one segment. Quoted spans are
# deliberately NOT stripped: `[ "$rc" -eq 0 ]` quotes the variable it compares,
# and removing quoted text would turn every genuine control into a false
# positive. `[ -n "$x" ] && echo "... $rc != 0"` therefore keeps only the `[`
# test (no rc adjacency -> not evidence), while `[ "$rc" -eq 0 ] && echo ok`
# keeps the test that IS the evidence.
function keep_seg(t,   u) {
    u = t
    sub(/^[ \t]*/, "", u)
    sub(/^([{(][ \t]*)+/, "", u)
    sub(/^(then|else|do)[ \t]+/, "", u)
    if (u ~ /^(echo|printf)([ \t]|$)/) return " "
    return t
}
function ev_text(s,   out, seg, i, ch, q, n) {
    out = ""; seg = ""; q = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        if (q != "") { seg = seg ch; if (ch == q) q = ""; continue }
        if (ch == "\"" || ch == "'") { q = ch; seg = seg ch; continue }
        if (ch == ";") { out = out keep_seg(seg) " "; seg = ""; continue }
        if (ch == "&" || ch == "|") {
            out = out keep_seg(seg) " "; seg = ""
            if (substr(s, i + 1, 1) == ch) i++
            continue
        }
        seg = seg ch
    }
    return out keep_seg(seg)
}
{ L[NR] = $0 }
END {
    for (i = 1; i <= NR; i++) {
        # (1) seed: a non-comment line carrying the convention string.
        if (L[i] !~ /RED confirmed/) continue
        t = L[i]; sub(/^[ \t]+/, "", t)
        if (substr(t, 1, 1) == "#") continue

        lo = i - WINDOW; if (lo < 1) lo = 1

        # (2) the seed's own control: the nearest ENCLOSING conditional -- the
        # one still OPEN where the seed sits, not merely the nearest preceding
        # `if` LINE. CR round 2 [codex-1]: without nesting an inner conditional
        # that had already CLOSED above the seed was taken as the guard, and the
        # real vacuous one was never examined at all. Walking upward, every `fi`
        # raises a pending-close count and every `if` either settles one (so it
        # opened an inner block that is already shut -- skip it) or, at zero,
        # IS the enclosing conditional. On the seed's OWN line only the text
        # BEFORE the marker can have opened or closed the block the marker sits
        # in, so that line is counted on its prefix -- which is what keeps a
        # one-line `if ...; then echo "... RED confirmed"; fi` matched while
        # `if ...; fi; echo "... RED confirmed"` is correctly not.
        # Computed BEFORE the compliance shortcut, because it is what scopes
        # that shortcut to this control rather than to a flat window.
        c = 0
        pending = 0
        for (j = i; j >= lo; j--) {
            if (L[j] ~ /^[ \t]*#/) continue
            s2 = (j == i) ? substr(L[j], 1, index(L[j], "RED confirmed")) : L[j]
            pending += nfi(s2)
            opens = nif(s2)
            if (opens > 0) {
                if (opens <= pending) {
                    pending -= opens
                } else if (L[j] ~ /^[ \t]*if[ \t]/) {
                    c = j; break
                } else {
                    pending = 0
                }
            }
            if (pending == 0 && L[j] ~ /^[ \t]*elif[ \t]/) { c = j; break }
        }

        # (3) compliance shortcut: the seed belongs to a control that goes
        # through the contract helper -- either it IS an argument of a
        # red_control_assert invocation, or the block around it drives one.
        # Derived from what a compliant control looks like (the invocation name
        # always precedes its arguments), not from a filename allowlist.
        #
        # Scoped to the seed's OWN control -- from its conditional down to the
        # seed -- and comment lines do not count. CR round 1 [codex-1] measured
        # the flat-window version letting a SEPARATE, already-completed
        # compliant control 40 lines above suppress a genuinely vacuous one
        # after it, and a bare comment naming either helper doing the same. The
        # flat window survives only as the fallback for a seed inside no
        # conditional at all -- the scripts/lib/test-red-control.sh shape, where
        # the seed is an argument to an assertion helper rather than the body
        # of an `if`.
        from = (c > 0) ? c : lo
        skip = 0
        for (j = from; j <= i; j++) {
            if (L[j] ~ /^[ \t]*#/) continue
            if (L[j] ~ /red_control_(run|assert)/) { skip = 1; break }
        }
        if (skip) continue

        # (4) the smell: what that conditional tests.
        if (c == 0) continue
        expr = L[c]
        sub(/^[ \t]*(if|elif)[ \t]+/, "", expr)
        sub(/;[ \t]*then.*$/, "", expr)
        sub(/[ \t]+then[ \t]*$/, "", expr)

        ineq = (expr ~ /!=/)
        fex  = (expr ~ /[[][[]?[ \t]+(![ \t]*)?-[ef][ \t]/)
        if (!ineq && !fex) continue

        # Any OTHER comparison in the same test means the control is doing more
        # than "it differs" -- leave it alone rather than guess.
        other = 0
        if (expr ~ /(^|[^[:alnum:]_-])-(eq|ne|lt|gt|le|ge|z|n|d|s|x|r|w)([^[:alnum:]_-]|$)/) other = 1
        if (expr ~ /[^!<>=]=[ \t]/) other = 1
        if (expr ~ /=~/) other = 1
        if (expr ~ /==/) other = 1
        if (other) continue

        # ... and no exit-status comparison anywhere in the block it opens.
        depth = (L[c] ~ /^[ \t]*elif[ \t]/) ? 1 : 0
        endl = NR
        for (j = c; j <= NR; j++) {
            if (L[j] ~ /^[ \t]*#/) continue
            depth += nif(L[j]) - nfi(L[j])
            if (depth <= 0) { endl = j; break }
        }
        rc = 0
        for (j = c; j <= endl; j++) {
            s = L[j]
            if (s ~ /^[ \t]*#/) continue
            # All three rules below read the line with its DIAGNOSTIC segments
            # removed (see ev_text): a message never establishes evidence, in
            # any spelling.
            s = ev_text(s)
            # A bare `$?` counts ONLY on the conditional line itself (j == c),
            # and only with a real comparison operator on it. Three rounds of
            # narrowing built this one line:
            #   round 1 [codex-2] -- a diagnostic `echo "... (status $?)"` with
            #     no comparison silenced the whole control;
            #   round 2 [codex-2] -- `[ "$?" ]` is a nonempty-STRING test, true
            #     for every exit status, so it compares nothing;
            #   round 3 [codex-2] -- and INSIDE the then-branch, `$?` is the
            #     CONDITIONAL's status, which is 0 precisely because the branch
            #     was taken. It can never be the mutant's, so a `$?` comparison
            #     there is evidence of nothing at all.
            # Only at j == c does `$?` still refer to whatever ran before the
            # `if`. See the KNOWN LIMITS header: even there it is a heuristic.
            if (j == c && s ~ /[$][?]/ && s ~ CMP) { rc = 1; break }
            if (s ~ /--expect-rc/) { rc = 1; break }
            # The robust shape, and the only one that survives all four rounds
            # of narrowing: a captured status compared later. Adjacency is
            # required -- see RCCMP above.
            if (s ~ RCCMP) { rc = 1; break }
        }
        if (rc) continue

        # (5) one reason per hit, naming WHICH half is missing.
        if (ineq) what = "an inequality"; else what = "a bare file-existence test"
        printf "%s:%d mutation control asserts only %s and never compares the mutant's exit status -- a crashed or silent mutant satisfies it (HIMMEL-2518; use scripts/lib/red-control.sh)\n", F, i, what
    }
}
AWK
)

scanned=0
hits=0
failed=0

files=()
for r in "${roots[@]}"; do
    if [ -f "$r" ]; then
        files+=("$r")
    elif [ -d "$r" ]; then
        # CR round 3 [codex-1]: this is round 2's awk hole ONE LAYER UP. The
        # listing used to be read through `$(find ... | sort)` inside a heredoc,
        # which discards find's exit status entirely -- so a find that cannot
        # traverse a subtree (permissions, a vanished directory, a broken mount)
        # printed what it reached, exited nonzero, and the run reported a clean
        # scan over a PARTIAL file list. Same incomplete-scan class, same fix:
        # keep find OUT of a pipeline so its own status survives, write the
        # listing to the pinned scratch file, and count a failure into the same
        # tally the summary reports. Sorting happens afterwards, in place, so it
        # can never stand between find and its exit status.
        if [ -z "$FINDF" ]; then
            failed=$((failed + 1))
            printf 'red-control-lint: FAILED to enumerate %s (no writable scratch file for the listing)\n' "$r" >&2
            continue
        fi
        find "$r" -type f -name '*.sh' > "$FINDF" 2>"${ERRF:-/dev/null}"
        frc=$?
        if [ "$frc" -ne 0 ]; then
            failed=$((failed + 1))
            detail=""
            [ -n "${ERRF:-}" ] && [ -s "$ERRF" ] && detail=" - $(tr '\n' ' ' < "$ERRF")"
            printf 'red-control-lint: FAILED to enumerate %s (find exited %s)%s - the file list is PARTIAL\n' \
                "$r" "$frc" "$detail" >&2
        fi
        LC_ALL=C sort -o "$FINDF" "$FINDF" 2>/dev/null
        while IFS= read -r f; do
            [ -n "$f" ] && files+=("$f")
        done < "$FINDF"
    else
        # CR round 5 [codex-2]: same incomplete-scan family as the awk, find and
        # enumeration holes. A mistyped or vanished root used to print a notice
        # and still reach the CLEAN-scan summary -- "0 suspect controls" for a
        # root that was never looked at.
        failed=$((failed + 1))
        printf 'red-control-lint: FAILED to scan %s (not a file or directory)\n' "$r" >&2
    fi
done

for f in ${files[@]+"${files[@]}"}; do
    scanned=$((scanned + 1))
    # The contract helper itself is compliant by construction: it is the code
    # that PRINTS the convention string. Only this one path is special-cased --
    # every other file earns its pass from the detector above.
    case "$f" in
        */lib/red-control.sh) continue ;;
    esac
    # grep exits 1 for "no match" (fine) but >=1 above that for a real error --
    # an unreadable file, a missing grep. Only the first is a clean skip.
    grep -q 'RED confirmed' "$f" 2>/dev/null
    grc=$?
    if [ "$grc" -gt 1 ]; then
        failed=$((failed + 1))
        printf 'red-control-lint: FAILED to scan %s (grep exited %s)\n' "$f" "$grc" >&2
        continue
    fi
    [ "$grc" -eq 0 ] || continue
    # CR round 2 [codex-3]: awk's exit status and stderr used to be discarded,
    # so a broken, missing or failing awk produced empty output for every file
    # and the run printed a summary byte-identical to a genuinely clean scan --
    # a vacuous green inside the vacuous-green detector, which is precisely the
    # shape HIMMEL-2518 exists to refuse. Both are now captured, and a run with
    # any failed scan can no longer report a bare "0 suspect controls".
    if [ -n "$ERRF" ]; then
        out=$(awk -v F="$f" -v WINDOW="$WINDOW" "$AWK_PROG" "$f" 2>"$ERRF")
        arc=$?
    else
        out=$(awk -v F="$f" -v WINDOW="$WINDOW" "$AWK_PROG" "$f" 2>/dev/null)
        arc=$?
    fi
    if [ "$arc" -ne 0 ]; then
        failed=$((failed + 1))
        detail=""
        [ -n "$ERRF" ] && [ -s "$ERRF" ] && detail=" - $(tr '\n' ' ' < "$ERRF")"
        printf 'red-control-lint: FAILED to scan %s (awk exited %s)%s\n' "$f" "$arc" "$detail" >&2
        continue
    fi
    [ -n "$out" ] || continue
    printf '%s\n' "$out"
    hits=$((hits + $(printf '%s\n' "$out" | wc -l)))
done

# A run with any failed scan must never be able to print the clean-scan line:
# "0 suspect controls" would then mean "found nothing" and "looked at nothing"
# indistinguishably (CR round 2 [codex-3]). The exit status stays 0 either way --
# the fix is to stop the summary lying, not to start gating.
if [ "$failed" -gt 0 ]; then
    printf 'red-control-lint: %s suspect control(s) in %s files scanned (%s file(s) FAILED to scan - the result is incomplete; advisory, exit status is always 0)\n' \
        "$hits" "$scanned" "$failed" >&2
elif [ "$hits" -eq 0 ]; then
    printf 'red-control-lint: 0 suspect controls in %s files scanned\n' "$scanned" >&2
else
    printf 'red-control-lint: %s suspect control(s) in %s files scanned (advisory; exit status is always 0)\n' \
        "$hits" "$scanned" >&2
fi

exit 0
