#!/usr/bin/env bash
# scripts/guardrails/lint-fail-open.sh — HIMMEL-1776
#
# Lints the SHAPE behind "unknown treated as benign". The five instances on
# the ticket were one missing convention implemented wrong five times: a
# guard that cannot classify its input (unreadable file, unresolvable host,
# missing bank reading) silently landed on the permissive branch. This lint
# exists so instance six cannot ship quietly.
#
# THE CONVENTION IT ENFORCES: every guard classifies its input
#   allow / deny / unknown — and unknown NEVER silently takes the allow path.
# Fail toward deny, toward an explicit unknown branch, or toward a default
# that is itself enforced — never toward "looks fine".
#
# Detectors (chosen for an acceptable false-positive rate; the suite proves
# each one red against a reconstruction of the ORIGINAL pre-fix code it was
# built for, so the lint is not decoration):
#
#   unreadable-config   [ -f "$x" ] gating a later READ of "$x" with no
#                       [ -r "$x" ] anywhere in the file and no failure
#                       handling (no `||`-guard) on the read line.
#                       Instance-1 shape: the phi-roots denylist existed but
#                       was unreadable, the read loop yielded nothing, and
#                       "no entries" read as "no PHI roots" -> allow.
#
#   sentinel-not-denied a fallback classification literal (*-custom /
#                       *-rerouted / *-unknown / *-unmeasured), or any value
#                       assigned to a *PROVIDER*/*BACKEND*/*CLASS*/*TIER*/*
#                       MODEL* variable inside a `*)` case arm — arm member-
#                       ship tracked from the `*)` opener through the closing
#                       `;;`, so the conventional MULTILINE arm counts, and
#                       the literal parsed double- OR single-quoted (round 2,
#                       codex-adv-2) — with no comparison against that
#                       literal elsewhere in the file (the hard-deny wiring).
#                       Instance-2 shape: an unresolvable endpoint fell
#                       through to "anthropic-custom", which a wildcard
#                       egress-matrix cell happily matched -> allow.
#
#   quota-zero          a bank/quota/cost reading coalesced to zero
#                       (`?? 0` / `|| 0`) in the lane preflight surfaces.
#                       Instance-3/4 shape: an unreadable reading resolved at
#                       zero spent -> authorized. `?? null` (preserve the
#                       unknown, refuse downstream) is the prescribed shape
#                       and is NOT flagged.
#
#   pct-unguarded       a *pct* reading compared against a threshold (`>=`)
#                       inside a lanes .mjs function with no
#                       Number.isFinite/null guard on it in that function.
#                       Instance-3 shape: `null >= 80` is false, so an
#                       unmeasured bank passed the refuse gate.
#
# Deliberate exceptions are marked INLINE, with the reason recorded where the
# next reader needs it (house style of `# headless-claude-ok:`):
#
#   # fail-open-ok: <reason>        (shell — on the flagged line)
#   // fail-open-ok: <reason>       (JS/TS)
#
# Known gaps, stated plainly: the PowerShell twins (.ps1) get no coverage
# (no bash-shaped parsing here); snake_case *_percent readings are not
# matched (the lane grammar names things *pct*/usedPct); .ts files get
# quota-zero only (the function-block scanner relies on the lanes .mjs
# formatting); scripts/telegram/spawn-claudex.ts is owned by a parallel
# worker this leg and is not scanned; the .sh AND .mjs/.ts surfaces under
# scripts/guardrails, scripts/hooks, and scripts/lanes are all recursive
# (excluding scripts/lanes/bench/, a self-contained benchmark harness whose
# fixtures/lib are test data, not guard surfaces — closed panel rounds
# codex-4 and codex-1/round-5); the
# sentinel-not-denied and pct-unguarded detectors confirm a hard-deny/guard
# COMPARISON exists (and, for pct-unguarded, that it textually precedes the
# risky use at no deeper a brace nesting), but not that the branch actually
# DENIES -- a comparison that only logs, or a same-depth sibling if/else,
# can still satisfy the lint (panel round 4, codex-1 / round 2, codex-3).
# True control-flow/dominance analysis needs a real parser; a keyword-list
# attempt at "does this branch deny" was tried and reverted -- it does not
# generalize across this repo's several deny-wrapper idioms (deny(),
# refuse(), plain exit/return) without a steady stream of new false
# positives on files the fix was never run against; the quota-zero and
# pct-unguarded `?? null` / `Number.isFinite(id)` guard checks confirm that
# expression occurs SOMEWHERE in the function, not that its result is what
# actually reaches the flagged comparison -- `const x = id ?? null;` earlier
# in the function does not prove a later `id >= N` (the ORIGINAL, uncoalesced
# identifier) is guarded (panel round 7, codex-2). Same real-parser ceiling
# as the deny-verification gap above; not fixed for the same reason. The
# pct-unguarded block scanner also only recognizes column-0 `function NAME(`
# declarations -- arrow functions and class methods on the .mjs surfaces are
# not scanned at all (panel round 7, codex-3, suggestion).
#
# Usage:
#   scripts/guardrails/lint-fail-open.sh            # lint the guard surfaces
#   scripts/guardrails/lint-fail-open.sh PATH...    # lint explicit files
#                                                   # (language by extension;
#                                                   # a trailing .fxt is
#                                                   # stripped first, so a
#                                                   # committed fixture like
#                                                   # instance1.sh.fxt scans
#                                                   # as shell)
#
# Exit: 0 clean · 1 findings · 2 misconfiguration (unknown extension, missing
#       file, or a default-surface scan that found nothing to scan — a scan
#       that never looked is not green, the same false-green class
#       run-shell-tests.sh closes at HIMMEL-1128).
#
# bash 3.2-safe (no mapfile, no associative arrays); Git Bash on Windows OK.
# The whole tree is scanned with three awk invocations total — on Windows a
# fork costs a quarter-second, so per-file subprocesses are not affordable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    # CodeRabbit: the old '2,72p' stopped mid-header, before the Usage and
    # Exit-code sections a --help reader actually needs. '2,105p' covers the
    # whole header comment block (through the line before `set -uo pipefail`).
    sed -n '2,105p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

# --------------------------------------------------------------------------
# Detectors 1 + 2 (shell). One awk over every shell file; per-file state is
# flushed on file switch (FNR==1) and once more in END.
# Invoked indirectly (by name, through scan_family) — shellcheck cannot see
# the call site.
# shellcheck disable=SC2317,SC2329
shell_scan() {
    awk '
        function flush_d1(    k, i, fl, rep, tmp) {
            for (k in fline) {
                fl = fline[k]
                if (lines[fl] ~ /fail-open-ok:[[:space:]]*[^[:space:]]/) continue
                rep = 0
                for (i = 1; i <= nlines; i++) {
                    if (index(lines[i], k) == 0) continue
                    if (lines[i] ~ /fail-open-ok:[[:space:]]*[^[:space:]]/) continue
                    # codex-1 (round 2): a `-r` test for k anywhere in the
                    # file used to suppress EVERY read of k, even one that
                    # comes textually before the -r test (or on an unrelated
                    # branch). Require the -r test to appear at or before
                    # THIS read line -- order-sensitive, not merely present.
                    if ((k in rline) && rline[k] <= i) continue
                    # A bare `|| true` / `|| :` no-op silences the failure
                    # instead of handling it (codex-1 round 1) -- strip those
                    # before deciding the line has real `||` failure
                    # handling. A `||` that survives the strip (e.g.
                    # `|| exit 1`, `|| return 1`) still counts as handled.
                    tmp = lines[i]
                    gsub(/\|\|[[:space:]]*(true|:)[[:space:]]*(;|&&|$)/, "", tmp)
                    if (tmp ~ /\|\|/) continue
                    if (!isread(lines[i], k)) continue
                    printf "%s:%d: fail-open(unreadable-config): %s is existence-checked (-f) and then read with no -r test and no failure handling; an existing-but-unreadable file silently reads as empty, which the guard treats as the permissive case. Pair the -f with an -r test (deny on unreadable), handle the read failure, or mark the line `# fail-open-ok: <reason>`\n", FILE, fl, k
                    rep = 1
                    break
                }
            }
        }
        function flush_d2(    i, j, L, lit, varname, seg, sentinel, fallback_arm, classvar, ok, p, before, after, rest) {
            # Case-arm state (round 2, codex-adv-2): an assignment belongs to
            # the `*)` fallback arm when a `*)` opener precedes it (or shares
            # its line) and no `;;` / `esac` has closed the arm since. The
            # conventional MULTILINE form puts the assignment on its own line
            # under the `*)`; round 1 inspected only the assignment line and
            # missed it. Line-based like the rest of this lint: a case nested
            # inside a fallback arm closes the arm early — accepted; no guard
            # surface nests case-in-fallback-arm.
            inarm = 0
            for (i = 1; i <= nlines; i++) {
                if (!inarm && lines[i] ~ /(^|[;[:space:]])\*[[:space:]]*\)/) inarm = 1
                arm[i] = inarm
                if (inarm && (lines[i] ~ /;;/ || lines[i] ~ /(^|[;[:space:]])esac([[:space:]]|$)/)) inarm = 0
            }
            for (i = 1; i <= nlines; i++) {
                L = lines[i]
                if (L ~ /fail-open-ok:[[:space:]]*[^[:space:]]/) continue
                lit = ""; varname = ""
                if (match(L, /[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[A-Za-z0-9_.-]+)/)) {
                    seg = substr(L, RSTART, RLENGTH)
                    varname = seg; sub(/[[:space:]]*=.*/, "", varname)
                    lit = seg; sub(/^[^=]*=[[:space:]]*/, "", lit)
                    gsub(/["'\'']/, "", lit)
                } else if (match(L, /(echo[[:space:]]+|:-)("[^"]*"|[A-Za-z0-9_.-]+)/)) {
                    seg = substr(L, RSTART, RLENGTH)
                    lit = seg; sub(/^(echo[[:space:]]+|:-)/, "", lit)
                    gsub(/"/, "", lit)
                } else {
                    continue
                }
                if (lit == "") continue
                sentinel = (lit ~ /-(custom|rerouted|unknown|unmeasured)$/)
                fallback_arm = arm[i]
                # codex-2 (suggestion, round 4): match case-insensitively --
                # a lowercase provider/backend/class/tier/model var in a
                # fallback arm was silently skipped.
                classvar = (tolower(varname) ~ /(provider|backend|class|tier|model)/)
                if (!sentinel && !(fallback_arm && classvar)) continue
                # codex-1 (round 7): only a comparison AFTER the sentinel is
                # produced can be the deny that protects it -- every real
                # fixture (and the failure shape itself: produce, THEN
                # check) follows this order. A matching comparison earlier
                # in the file is unrelated to this production point.
                ok = 0
                for (j = i + 1; j <= nlines; j++) {
                    rest = lines[j]
                    p = index(rest, lit)
                    while (p > 0 && !ok) {
                        after = substr(rest, p + length(lit))
                        before = substr(rest, 1, p - 1)
                        sub(/[[:space:]]+$/, "", before)
                        if (before ~ /["'\'']$/) { before = substr(before, 1, length(before) - 1); sub(/[[:space:]]+$/, "", before) }
                        if (after ~ /^\)/) ok = 1
                        # codex-2 (panel round): a bare `=` before the literal
                        # matches a plain assignment (x=lit) as readily as a
                        # test comparison (x = "lit"), so require a `[` on
                        # the same line -- a real POSIX/bash test bracket a
                        # reassignment of the same literal elsewhere never has.
                        # codex-2 (round 2): a [ test comparing a DIFFERENT
                        # variable to the same literal string must not count
                        # either -- require the producing variable name to
                        # appear as a distinct token on the comparison line
                        # too (word-boundary via a non-identifier char or
                        # end of line -- awk ERE has no \b), when a
                        # producing variable was captured at all (the
                        # echo/:- literal branch above leaves varname empty
                        # and skips this check).
                        else if (length(before) > 0 && substr(before, length(before), 1) == "=" && \
                                (length(before) == 1 || substr(before, length(before) - 1, 1) !~ /[A-Za-z0-9_=!<>]/) && \
                                lines[j] ~ /\[/ && \
                                (varname == "" || lines[j] ~ (varname "([^A-Za-z0-9_]|$)"))) ok = 1
                        rest = substr(rest, p + length(lit))
                        p = index(rest, lit)
                    }
                    if (ok) break
                }
                if (!ok) {
                    printf "%s:%d: fail-open(sentinel-not-denied): fallback classification value %s is produced here but never compared against anywhere in this file; an input the guard could not classify silently takes a value a wildcard policy cell can match. Add the hard-deny comparison before the policy lookup, or mark the line `# fail-open-ok: <reason>`\n", FILE, i, lit
                }
            }
        }
        function isread(L, k,    p, rest) {
            # input redirection of exactly this operand (`< "$k"` / `<"$k"`), not a
            # here-string (`<<<`): the char before the `<` must not be another `<`.
            p = index(L, "< " k)
            if (p == 0) p = index(L, "<" k)
            if (p > 1 && substr(L, p - 1, 1) == "<") p = 0
            if (p > 0) return 1
            if (index(L, k) == 0) return 0
            if (L ~ /(^|[;[[:space:]&|])(cat|source|jq|awk|sed|node|python3|python|wc|head|tail|sort|md5sum|shasum)([[:space:]]|")/) return 1
            if (L ~ /(^|[;&|])[.][[:space:]]+/) return 1
            # grep reads a FILE only when the operand is its LAST argument AND the
            # line shows a separate pattern: either a ` -- ` separator before it,
            # or an earlier quoted LITERAL argument (no $). `grep -qxF "$doc"`
            # passes the operand as the PATTERN and reads stdin — not a file read.
            p = index(L, k)
            rest = substr(L, p + length(k))
            if (L ~ /(^|[;[[:space:]&|])grep([[:space:]]|$)/ && rest ~ /^[[:space:]]*(2>[^[:space:]]*)?([[:space:]]*(&&|;).*)?$/) {
                pre = substr(L, 1, p - 1)
                if (index(pre, " -- ") > 0) return 1
                if (pre ~ /"[^"$][^"]*"/) return 1
            }
            return 0
        }
        FNR == 1 {
            if (NR > 1) { flush_d1(); flush_d2() }
            delete fline; delete rline; delete lines
            nlines = 0
            FILE = FILENAME
        }
        {
            nlines++
            lines[nlines] = $0
            s = $0
            while (match(s, /\[\[?[[:space:]]*!?[[:space:]]*-f[[:space:]]+[^]]*\]\]?/)) {
                t = substr(s, RSTART, RLENGTH)
                sub(/\[\[?[[:space:]]*!?[[:space:]]*-f[[:space:]]+/, "", t)
                sub(/[[:space:]]*\]\]?$/, "", t)
                if (t != "" && !(t in fline)) fline[t] = nlines
                s = substr(s, RSTART + RLENGTH)
            }
            s = $0
            while (match(s, /\[\[?[[:space:]]*!?[[:space:]]*-r[[:space:]]+[^]]*\]\]?/)) {
                t = substr(s, RSTART, RLENGTH)
                sub(/\[\[?[[:space:]]*!?[[:space:]]*-r[[:space:]]+/, "", t)
                sub(/[[:space:]]*\]\]?$/, "", t)
                if (t != "" && !(t in rline)) rline[t] = nlines
                s = substr(s, RSTART + RLENGTH)
            }
        }
        END { flush_d1(); flush_d2() }
    ' "$@"
}

# --------------------------------------------------------------------------
# Detector 3a (JS/TS): money-named reading coalesced to zero.
# Invoked indirectly (by name, through scan_family) — shellcheck cannot see
# the call site.
# shellcheck disable=SC2317,SC2329
js_scan_coalesce() {
    awk '
        {
            if ($0 ~ /fail-open-ok:[[:space:]]*[^[:space:]]/) next
            if (match($0, /[A-Za-z0-9_$.]+[[:space:]]*(\?\?|\|\|)[[:space:]]*(0n|0\.0|0)([^0-9A-Za-z_.]|$)/)) {
                seg = substr($0, RSTART, RLENGTH)
                id = seg; sub(/[[:space:]]*(\?\?|\|\|).*$/, "", id)
                leaf = id; sub(/^.*\./, "", leaf)
                if (tolower(leaf) ~ /(bank|spent|used|cost|usage|quota|remain|limit|balance|budget)/) {
                    printf "%s:%d: fail-open(quota-zero): reading %s is coalesced to zero; an unreadable/unmeasured bank resolves as nothing-spent, which reads as authorized. Preserve the unknown (`?? null`) and refuse on it, or mark the line `// fail-open-ok: <reason>`\n", FILENAME, FNR, id
                }
            }
        }
    ' "$@"
}

# --------------------------------------------------------------------------
# Detector 3b (lanes .mjs only): *pct* threshold compare with no unknown
# branch in the same function block. Blocks run from a column-0
# `function NAME(` line to the next column-0 `}` — the formatting the lanes
# bench family uses. Top-level code is never scanned.
# Invoked indirectly (by name, through scan_family) — shellcheck cannot see
# the call site.
# shellcheck disable=SC2317,SC2329
mjs_scan_pct() {
    awk '
        function flush(    i, L, seg, id) {
            if (!inblk) return
            for (i = 1; i <= n; i++) {
                L = blk[i]
                if (L ~ /fail-open-ok:[[:space:]]*[^[:space:]]/) continue
                if (match(L, /[A-Za-z0-9_$.]+[[:space:]]*>=/)) {
                    seg = substr(L, RSTART, RLENGTH)
                    id = seg; sub(/[[:space:]]*>=.*$/, "", id)
                    if (tolower(id) !~ /pct/) continue
                    if (!guarded(id, i)) {
                        printf "%s:%d: fail-open(pct-unguarded): reading %s is compared against a threshold with no Number.isFinite/null guard in this function; a null reading coerces (null >= N is false) and an unmeasured bank silently passes the refuse gate. Branch on the unknown first, or mark the line `// fail-open-ok: <reason>`\n", FILE, bline[i], id
                    }
                }
            }
        }
        # codex-3 (panel round): scan only lines UP TO AND INCLUDING the
        # comparison (not the whole block) -- a guard appearing textually
        # AFTER the risky comparison cannot have protected it. Still
        # order-blind across if/else branches (no true control-flow
        # tracking), but this closes the flagrant "guard placed later in the
        # same function" evasion.
        # codex-3 (round 2): a guard nested inside a MORE deeply-braced,
        # unrelated conditional (a sibling branch) must not protect a
        # comparison at a shallower depth -- bdepth[] is the brace-nesting
        # depth each line EXECUTES at (counted before that own line brace
        # is applied), so requiring bdepth[i] <= bdepth[upto] rules out a
        # guard buried in a deeper, narrower branch than the comparison it
        # is being credited for. Still not true dominance (a same-depth
        # sibling if/else still passes), but closes the "nested-deeper
        # unrelated branch" shape without a real parser.
        function guarded(id, upto,    i, L) {
            for (i = 1; i <= upto; i++) {
                if (bdepth[i] > bdepth[upto]) continue
                L = blk[i]
                if (index(L, "Number.isFinite(" id ")")) return 1
                if (index(L, "isFinite(" id ")")) return 1
                if (L ~ id "[[:space:]]*(===|==|!=|!==)[[:space:]]*null") return 1
                if (L ~ "null[[:space:]]*(===|==)[[:space:]]*" id) return 1
                if (L ~ id "[[:space:]]*\\?\\?[[:space:]]*null") return 1
            }
            return 0
        }
        function bracedelta(L,    t, o, c) {
            t = L; o = gsub(/\{/, "", t)
            t = L; c = gsub(/\}/, "", t)
            return o - c
        }
        FNR == 1 { flush(); inblk = 0; n = 0; curdepth = 0; FILE = FILENAME }
        /^(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z0-9_$]+/ { flush(); inblk = 1; n = 0; curdepth = 0; next }
        # codex-2 (round 6): /^}/ alone also matched `} else if (...) {`,
        # ending the block scan mid-function and hiding every later branch
        # from pct-unguarded. Require the line to be JUST a closing brace
        # (optional trailing ; or whitespace), matching how every function
        # in this codebase actually closes.
        inblk && /^}[[:space:]]*;?[[:space:]]*$/ { flush(); inblk = 0; next }
        inblk { n++; blk[n] = $0; bline[n] = FNR; bdepth[n] = curdepth; curdepth += bracedelta($0); next }
        END { flush() }
    ' "$@"
}

# --------------------------------------------------------------------------
# Surface collection. Default: the known guard surfaces (see header). With
# explicit paths: exactly those, language sniffed from the extension (a
# trailing .fxt is stripped first so committed fixtures scan by real ext).
# --------------------------------------------------------------------------
# CodeRabbit (Major): find_err (below) used to be created, then rm -f'd on
# the happy path while `2>"$find_err"` on a LATER find call recreated the
# same path -- losing mktemp's atomic exclusive-create guarantee for that
# window and leaking the file on some early-exit branches. Own it with the
# same EXIT trap `tmp` (scan_family's scratch file, set later) already
# uses -- one cleanup function, declared before either is ever created.
find_err=""
tmp=""
# Invoked from the EXIT trap, which shellcheck cannot see as a call site.
# shellcheck disable=SC2317,SC2329
cleanup() {
    [ -n "$find_err" ] && rm -f "$find_err"
    [ -n "$tmp" ] && rm -f "$tmp"
}
trap cleanup EXIT

root=""
paths=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)
            [ "$#" -ge 2 ] || { echo "lint-fail-open.sh: --root requires a value" >&2; exit 2; }
            root="$2"; shift 2
            ;;
        -h|--help) usage
            ;;
        -*) echo "lint-fail-open.sh: unknown flag: $1" >&2; exit 2
            ;;
        *) paths+=("$1"); shift
            ;;
    esac
done

shell_files=()
js_files=()      # quota-zero detector
mjs_files=()     # pct-unguarded detector (quota-zero applies too)

lang_of() {
    local base="${1##*/}"
    case "$base" in
        *.fxt) base="${base%.fxt}" ;;
    esac
    case "$base" in
        *.sh|*.bash) printf 'sh' ;;
        *.mjs) printf 'mjs' ;;
        *.js|*.ts|*.cjs) printf 'js' ;;
        claude-codex|claude-glm|claude-routed) printf 'sh' ;;
        *) return 1 ;;
    esac
}

add_path() {
    local p="$1" lang
    [ -f "$p" ] || { echo "lint-fail-open.sh: not a file: $p" >&2; exit 2; }
    if ! lang=$(lang_of "$p"); then
        echo "lint-fail-open.sh: cannot determine language of $p" >&2
        exit 2
    fi
    case "$lang" in
        sh)  shell_files+=("$p") ;;
        mjs) mjs_files+=("$p"); js_files+=("$p") ;;
        js)  js_files+=("$p") ;;
    esac
}

if [ "${#paths[@]}" -gt 0 ]; then
    for p in "${paths[@]}"; do
        add_path "$p"
    done
    # Default the root to the INVOKING cwd so absolute-under-cwd paths are
    # handed to the detectors as RELATIVE paths. Git Bash + a native awk can
    # mangle absolute POSIX paths in argv (`/c/...` arriving as `c/...`);
    # relative paths sidestep the conversion entirely, and the cwd is where
    # they resolve from anyway.
    [ -n "$root" ] || root="$PWD"
else
    [ -n "$root" ] || root="$DEFAULT_ROOT"
    [ -d "$root" ] || { echo "lint-fail-open.sh: root is not a directory: $root" >&2; exit 2; }
    # codex-4 (panel round): RECURSIVE — a top-level-only glob (*.sh) let a
    # guard added in a nested subdirectory (e.g. scripts/hooks/sub/new.sh)
    # escape the standing scan even though the pre-commit files: scope
    # (scripts/(guardrails|hooks|lanes)/, no depth limit) already triggers
    # the gate on it. `find`, not mapfile (bash 3.2-safe / Git Bash).
    # codex-4 (panel round 2): `find`'s own errors (e.g. a permission-denied
    # subdirectory it cannot traverse) must not be silently discarded -- a
    # partial traversal that still exits the loop clean would report green
    # on an incomplete scan. Capture to a file, check find's real exit code.
    find_err=$(mktemp -t lint-fail-open-find.XXXXXX) || { echo "lint-fail-open.sh: mktemp failed" >&2; exit 2; }
    for d in scripts/guardrails scripts/hooks; do
        find_out=$(find "$root/$d" -type f -name '*.sh' 2>"$find_err") || { echo "lint-fail-open.sh: find failed under $root/$d: $(cat "$find_err")" >&2; exit 2; }
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            case "${f##*/}" in test-*) continue ;; esac
            shell_files+=("$f")
        done < <(printf '%s\n' "$find_out" | sort)
    done
    for f in "$root/scripts/graphify/refresh-graph-map.sh" \
             "$root/scripts/claude-codex" "$root/scripts/claude-glm" "$root/scripts/claude-routed"; do
        [ -f "$f" ] || { echo "lint-fail-open.sh: expected guard-surface file missing: $f" >&2; exit 2; }
        shell_files+=("$f")
    done
    # scripts/lanes/bench is a self-contained benchmark harness -- its
    # fixtures/ and lib/ hold synthetic sample scripts and bench-internal
    # helpers, not guard surfaces (same exclusion .pre-commit-config.yaml
    # already applies to trailing-whitespace/shellcheck for this subtree).
    # Recurse scripts/lanes EXCLUDING bench/; bench keeps its original
    # top-level-only *.sh scan via the explicit glob two loops below.
    find_out=$(find "$root/scripts/lanes" -type f -name '*.sh' -not -path '*/bench/*' 2>"$find_err") || { echo "lint-fail-open.sh: find failed under $root/scripts/lanes: $(cat "$find_err")" >&2; exit 2; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "${f##*/}" in test-*) continue ;; esac
        shell_files+=("$f")
    done < <(printf '%s\n' "$find_out" | sort)
    for f in "$root/scripts/lanes/bench"/*.sh; do
        [ -f "$f" ] || continue
        case "${f##*/}" in test-*) continue ;; esac
        shell_files+=("$f")
    done
    # codex-1 (panel round 5): the .mjs/.ts surface under scripts/lanes was
    # top-level-only while the pre-commit files: scope already triggers on
    # the whole tree -- same recursion fix as the .sh surface above, same
    # bench/ exclusion (fixtures/lib are bench-harness test data, not guard
    # surfaces). scripts/lanes/*.ts (bank-status.ts, codex-bank-probe.ts)
    # were not scanned AT ALL before this -- js_files gets the quota-zero
    # detector (works on .ts too, per the header note); mjs_files ALSO gets
    # pct-unguarded, which needs the lanes .mjs function-block formatting
    # this detector relies on -- .ts stays quota-zero only, as documented.
    find_out=$(find "$root/scripts/lanes" -type f \( -name '*.mjs' -o -name '*.ts' \) -not -path '*/bench/*' 2>"$find_err") || { echo "lint-fail-open.sh: find failed under $root/scripts/lanes (mjs/ts): $(cat "$find_err")" >&2; exit 2; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "${f##*/}" in test-*) continue ;; esac
        case "$f" in
            *.mjs) mjs_files+=("$f"); js_files+=("$f") ;;
            *.ts) js_files+=("$f") ;;
        esac
    done < <(printf '%s\n' "$find_out" | sort)
    for f in "$root/scripts/lanes/bench"/*.mjs; do
        [ -f "$f" ] || continue
        case "${f##*/}" in test-*) continue ;; esac
        mjs_files+=("$f"); js_files+=("$f")
    done
    f="$root/scripts/telegram/spawn-glm.ts"
    [ -f "$f" ] || { echo "lint-fail-open.sh: expected guard-surface file missing: $f" >&2; exit 2; }
    js_files+=("$f")
fi

total=$(( ${#shell_files[@]} + ${#js_files[@]} ))
[ "$total" -gt 0 ] || {
    echo "lint-fail-open.sh: nothing to scan (no guard-surface files resolved) — refusing to report green" >&2
    exit 2
}

# Report paths are repo-root-relative and forward-slashed: readable from any
# cwd, and stable across Git Bash / drive-letter forms. The scans run from
# $root so the relative paths resolve.
rel() {
    case "$1" in
        "$root"/*) printf '%s' "${1#"$root"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}
report_shell=()
report_js=()
report_mjs=()
# CodeRabbit (Major, verified): bash 3.2 (macOS default) raises "unbound
# variable" under set -u expanding an EMPTY array with "${arr[@]}" (fixed in
# 4.4). An explicit-path run that names only e.g. one .mjs file leaves
# shell_files empty, so the plain form is a real crash on this repo's stated
# bash-3.2-safe target. ${arr[@]+"${arr[@]}"} is the portable empty-safe idiom.
for f in ${shell_files[@]+"${shell_files[@]}"}; do report_shell+=("$(rel "$f")"); done
for f in ${js_files[@]+"${js_files[@]}"}; do report_js+=("$(rel "$f")"); done
for f in ${mjs_files[@]+"${mjs_files[@]}"}; do report_mjs+=("$(rel "$f")"); done

if [ -n "$root" ]; then
    cd "$root" || { echo "lint-fail-open.sh: cannot enter root: $root" >&2; exit 2; }
fi

n=0
# tmp/cleanup/trap are declared once, near the top of the script (before
# find_err's first use) -- not re-declared here.

# Count via `wc -l <` with a fail-closed fallback: an unreadable results file
# inflates the count (never deflates it), so a lost detector file can only
# make the lint RED, never green — and the pattern carries no -f-gated read
# for the lint to flag in itself.
scan_family() {
    local label="$1"; shift
    tmp=$(mktemp) || exit 2
    if ! "$@" > "$tmp"; then
        echo "lint-fail-open.sh: $label failed" >&2
        exit 2
    fi
    cat "$tmp"
    n=$(( n + $(wc -l < "$tmp" 2>/dev/null || echo 999999) ))
    rm -f "$tmp"
    tmp=""
}

if [ "${#report_shell[@]}" -gt 0 ]; then
    scan_family "shell detector" shell_scan "${report_shell[@]}"
fi
if [ "${#report_js[@]}" -gt 0 ]; then
    scan_family "js detector" js_scan_coalesce "${report_js[@]}"
fi
if [ "${#report_mjs[@]}" -gt 0 ]; then
    scan_family "mjs detector" mjs_scan_pct "${report_mjs[@]}"
fi

echo "lint-fail-open: $n finding(s) across $total file(s)"
[ "$n" -eq 0 ] || exit 1
exit 0
