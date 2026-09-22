#!/usr/bin/env bash
# WS5 Task 5 invariants test (HIMMEL-654). Assertion-only: greps the
# integrated WS5 branch diff (git diff <base>...HEAD) for the four locks that
# make lane parity durable without growing always-on surface or root-doctrine
# bloat.
#
#   T12 no-bloat     -- root CLAUDE.md does not grow on net (add-del <=1);
#                       pure churn (net 0) or shrinkage passes. (Changed
#                       2026-09-06 from a symmetric per-side cap to a
#                       net-growth cap, HIMMEL-2581 -- the per-side form
#                       failed ordinary rewordings, e.g. PR #2101/HIMMEL-2413's
#                       add=2 del=2, and even pure deletions, neither of which
#                       is the rule-block bloat this check exists to catch.)
#   T13 no-always-on -- no new SessionStart/PreToolUse hook registration in
#                       .claude/settings.json or any */hooks.json, and no
#                       unbounded-loop / background-service / JS-timer marker
#                       in the SHIPPED source the diff adds (test fixtures are
#                       excluded: a harness loop is not runtime surface; a
#                       VENDORED.md tree is excluded too, HIMMEL-3093: it is
#                       upstream content this repo mirrors, not himmel's own
#                       surface -- see the corpus loop below). The daemon
#                       marker skips prose -- *.md and comment lines --
#                       and adds service-creation shapes (HIMMEL-3233;
#                       rules at T13(b) below). A read-only process lookup
#                       (pgrep / `pkill -0` / `ps ... | grep`) naming a
#                       daemon does not count, and a trailing same-line
#                       `# t13b-ok: <reason>` exempts that one line from
#                       T13(b) only (HIMMEL-3432; rules at T13(b) below).
#   T14 locks        -- no per-token-lane wiring in shipped source; the
#                       gemini/copilot/cursor index rows stay deferred.
#                       (The former T14(a) claude-codex-launcher prohibition
#                       was retired 2026-07-13, HIMMEL-979.)
#   T15 x-platform   -- every NEW scripts/**/*.sh ships a .ps1 twin OR carries
#                       a documented platform-guard marker in its header.
#
# Public propagation-snapshot guard (HIMMEL-2642): T12/T13/T15 assume
# $BASE...HEAD is a normal feature-branch diff -- what one PR authored. A
# public re-baseline (propagate-public.sh's `snapshot`/`reship` modes) breaks
# that assumption: it re-projects the ENTIRE private tree onto the public
# repo's main in one commit, so hundreds of scripts the private repo has
# carried for months read as brand-new relative to PUBLIC's own git history.
# T14 is untouched by this (T14(c) reads a doc directly, not diff-scoped) and
# keeps running -- and keeps failing -- on every diff, snapshot or not; only
# T12/T13/T15 are SKIPPED (never silently, always with a named reason), so a
# snapshot that genuinely breaks T14 still fails the suite. Two EARLIER
# revisions of this guard inferred "is this a snapshot" from added-file volume
# and, later, volume PLUS scripts/lib/public-clone-paths.sh's absence -- both
# were heuristics, and a critic panel found a hole in each. The guard now
# checks one thing: whether propagate-public.sh itself wrote
# `.himmel-public-projection` into this tree (see the check right after BASE
# resolves, below, and propagate-public.sh's snapshot_core/reship for the
# write side). No inference, no threshold.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + grep over the branch diff; NOT ported to native PowerShell. A
# test harness needs no .ps1 twin (project convention: a documented platform
# guard suffices for a test fixture).
#
# Usage:
#   bash scripts/parity/test-ws5-invariants.sh [--base <ref>]
#     --base <ref>   diff base (defaults to origin/main); HEAD is the tip.
#
# Exit codes: 0 = PASS, 1 = FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASE="origin/main"

while [ $# -gt 0 ]; do
    case "$1" in
        --base)
            if [ $# -lt 2 ]; then
                echo "FAIL: --base requires a ref argument" >&2
                exit 1
            fi
            BASE="$2"
            shift 2
            ;;
        *)
            echo "FAIL: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

cd "$REPO" || { echo "FAIL: cannot cd to repo root $REPO" >&2; exit 1; }

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    # CI checkouts (shallow / single-ref) may lack origin/main -- fall back to
    # a local main; with NO resolvable base there is no diff to scope the
    # invariants over, so SKIP (exit 0), matching the harness skip convention.
    # An EXPLICIT --base that does not resolve still FAILS (caller error).
    if [ "$BASE" = "origin/main" ] && git rev-parse --verify --quiet main >/dev/null; then
        echo "note: origin/main does not resolve; falling back to local main"
        BASE=main
    elif [ "$BASE" = "origin/main" ]; then
        echo "SKIP: no resolvable diff base (origin/main and main both absent -- shallow CI checkout?); nothing to scope"
        exit 0
    else
        echo "FAIL: diff base ref does not resolve: $BASE" >&2
        exit 1
    fi
fi

# ----------------------------------------------------------------------------
# Public propagation-snapshot guard (HIMMEL-2642) -- EXPLICIT MARKER, not an
# inferred signal.
#
# History: this guard went through three designs. (1) a threshold on added
# scripts/**/*.sh volume -- a critic showed the cited evidence was a
# per-COMMIT maximum, which does not bound a per-PR-RANGE diff. (2) volume
# PLUS scripts/lib/public-clone-paths.sh's absence -- a second critic showed
# that signal distinguishes "public repo" from "private repo", not
# "propagation snapshot" from "feature PR": an ordinary public-repo PR adding
# >100 scripts would ALSO have lost T12/T13/T15 under it. Two rounds, two
# holes in two different inferred signals -- that pattern is itself the
# finding: inference is the wrong shape for this check, not a tuning problem.
#
# So there is no inference left. propagate-public.sh's `snapshot` and
# `reship` paths (the only two that produce or extend a propagation PR) write
# `.himmel-public-projection` directly into the tree they build, through the
# SAME staging/scan/verify pipeline as everything else they write (see their
# own comments). Its presence is the ONLY question this guard asks. No
# volume threshold, no second file's absence, no re-derivable statistic --
# a fact the propagator itself asserts by writing it.
#
# Ride-back guard (HIMMEL-2642 follow-up): the marker must never appear on a
# PRIVATE tree (a stray copy would falsely skip T12/T13/T15 there too).
# scripts/propagate-public.sh is ITSELF private-only, by its own header, and
# scripts/lib/propagation-drift.sh already relies on exactly that fact as
# "a sufficient private signal" (its Guard 1) -- reused here rather than
# inventing a second mechanism: if the marker and propagate-public.sh are
# EVER both present, something rode the marker back into a private tree, and
# that is an unconditional FAIL, checked before anything below can act on
# the marker's presence.
# PRESENCE is not enough, and design (4) is why (a fourth critic, and the last
# hole): the marker is COMMITTED into the public tree, so every branch cut from
# public main after a propagation INHERITS it. Presence therefore identifies
# projection ANCESTRY -- "this tree descends from a snapshot" -- not "this diff
# IS a snapshot", so an ordinary public-repo feature PR would inherit the
# exemption and skip T12/T13/T15 indefinitely.
#
# What distinguishes the two is the DIFF, and the marker already carries it:
# snapshot and reship REWRITE the marker on every run (a fresh private base SHA
# and timestamp), so it is always added-or-modified in a propagation diff and
# never touched in a branch that merely inherited it. So ask the diff, not the
# filesystem. This needs no new mechanism and no second signal -- it reads the
# same fact the propagator already asserts, scoped to the range under review.
#
# Captured into a variable rather than piped into `grep -q`: this file runs
# under `set -o pipefail` (line 54), where grep -q exits at its first match and
# the producer's SIGPIPE flips the pipeline's status (HIMMEL-1430).
PUBLIC_PROJECTION_MARKER=".himmel-public-projection"
PRIVATE_ONLY_SIGNAL="scripts/propagate-public.sh"
FAIL=0
marker_in_diff="$(git diff --name-only "$BASE...HEAD" -- "$PUBLIC_PROJECTION_MARKER" 2>/dev/null)"
if [ -f "$PUBLIC_PROJECTION_MARKER" ] && [ -f "$PRIVATE_ONLY_SIGNAL" ]; then
    echo "FAIL: $PUBLIC_PROJECTION_MARKER is present alongside $PRIVATE_ONLY_SIGNAL -- a public-only propagation marker rode back into a private tree (HIMMEL-2642). This checkout is treated as private: T12/T13/T15 still run below." >&2
    FAIL=$((FAIL + 1))
    PROPAGATION_SNAPSHOT=0
elif [ -f "$PUBLIC_PROJECTION_MARKER" ] && [ -n "$marker_in_diff" ]; then
    PROPAGATION_SNAPSHOT=1
    SNAPSHOT_REASON="$PUBLIC_PROJECTION_MARKER written by this diff -- propagate-public.sh rewrites it on every snapshot/reship, so this range IS a projection (HIMMEL-2642), not a feature branch that merely inherited the marker; T12/T13/T15 assume the diff is PR-authored content, so skipping. T14 still runs (see file header)."
else
    PROPAGATION_SNAPSHOT=0
fi
SHIPPED="$(mktemp "${TMPDIR:-/tmp}/ws5-shipped.XXXXXX")" || { echo "test-ws5-invariants.sh: mktemp failed" >&2; exit 2; }
trap 'rm -f "$SHIPPED"' EXIT

# Corpus of ADDED lines from SHIPPED source (every changed file whose basename
# does NOT start with "test-"). Test fixtures are excluded because they
# legitimately describe the very concepts they assert; the always-on and
# per-token-lane invariants are about production runtime + docs, not harness
# comments. (This also keeps the test from flagging its own assertion text.)
#
# ONE full-tree diff, not a per-file `-- "$f"` loop (HIMMEL-3090): restricting
# the diff to a single new-side pathspec drops git's rename pairing, so an
# unchanged file moved to a new path (100%-similarity rename) reads as its
# ENTIRE content being freshly added -- a vendored dependency's own
# setInterval/daemon usage then false-positives T13(b) for a file nobody
# authored in this diff. A full-tree diff resolves renames correctly (a
# content-identical rename contributes zero +/- lines); the awk filter below
# tracks the current file from each hunk's "+++ b/<path>" header instead, so
# basename exclusion still applies per file.
#
# Vendored trees (HIMMEL-3093) get the same treatment, folded into the SAME
# full-tree pass rather than a second per-file loop (which would reintroduce
# the HIMMEL-3090 rename-blindness this file just fixed): a directory
# carrying its own VENDORED.md declares its content copied verbatim from an
# upstream project himmel did not author (see marketplace/plugins/*/VENDORED.md)
# -- T13 audits surface HIMMEL SHIPPED BY WRITING IT, not prose or scripts an
# upstream project wrote that this repo mirrors byte-for-byte. The vendored
# file SET is computed once (walking UP from each changed file's own
# directory, not a hardcoded path list, so any VENDORED.md tree is covered at
# any nesting depth) and fed into the awk filter as a lookup table; the diff
# itself still runs once, full-tree. Never silent: every skip is named on
# stderr.
#
# The SAME pass also collects the REMOVED lines of the non-skipped files into
# $REMOVED (HIMMEL-3147). T13(b) uses them to tell moved code from new code: a
# refactor that hoists a setInterval poll out of one file into a shared helper
# reads, per line, as an add in the new home -- but the identical line is
# removed from the old one in the same diff. Still one full-tree diff, no
# per-file loop (HIMMEL-3090). `--- ` headers are dropped, so a removed line
# whose own text starts with `-- ` is missed: that only ever makes a
# cancellation LESS likely, i.e. the gate stays strict.
VENDORED_LIST="$(mktemp "${TMPDIR:-/tmp}/ws5-vendored-list.XXXXXX")" || { echo "test-ws5-invariants.sh: mktemp failed" >&2; exit 2; }
REMOVED="$(mktemp "${TMPDIR:-/tmp}/ws5-removed.XXXXXX")" || { echo "test-ws5-invariants.sh: mktemp failed" >&2; exit 2; }
# One line per $SHIPPED line, in lockstep: "md" when the added line came from a
# *.md file, "code" otherwise. T13(b)'s daemon class reads it (HIMMEL-3233);
# $SHIPPED itself stays bare lines so T14(b)'s grep cannot match a path.
SHIPPED_KIND="$(mktemp "${TMPDIR:-/tmp}/ws5-shipped-kind.XXXXXX")" || { echo "test-ws5-invariants.sh: mktemp failed" >&2; exit 2; }
trap 'rm -f "$SHIPPED" "$VENDORED_LIST" "$REMOVED" "$SHIPPED_KIND"' EXIT
while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    case "$base" in test-* | *.tsv | *.test.ts | *.test.js | *.test.mjs | *.test.cjs) continue ;;
    esac
    d="$REPO/$(dirname "$f")"
    vendored_root=""
    while :; do
        if [ -f "$d/VENDORED.md" ]; then
            vendored_root="$d/VENDORED.md"
            break
        fi
        [ "$d" = "$REPO" ] && break
        d="$(dirname "$d")"
    done
    # HIMMEL-3064 (CR round 1, PR #777) -- the marker is a directory boundary,
    # but a VENDORED.md also declares its tree's OWN himmel-authored exceptions
    # as `local=<path>` lines relative to itself (lean-skills' context7-mcp).
    # Those are shipped by writing them, so the marker must not exempt them
    # from a "what did himmel ship" audit. Same rule as skill-cost.mjs's
    # vendoredRoot(), so both gates agree on the vendored path set.
    if [ -n "$vendored_root" ]; then
        vendored_dir="${vendored_root%/VENDORED.md}"
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            case "$REPO/$f" in
            "$vendored_dir/$rel" | "$vendored_dir/$rel"/*) vendored_root="" ;;
            esac
        done < <(sed -n 's/^local=\([^[:space:]]*\).*/\1/p' "$vendored_root")
    fi
    if [ -n "$vendored_root" ]; then
        echo "test-ws5-invariants: skipping $f: vendored per $vendored_root" >&2
        echo "$f" >> "$VENDORED_LIST"
    fi
done < <(git diff "$BASE...HEAD" --name-only)

git diff "$BASE...HEAD" | awk -v vendored_file="$VENDORED_LIST" -v removed_file="$REMOVED" -v kind_file="$SHIPPED_KIND" '
    BEGIN {
        while ((getline line < vendored_file) > 0) vendored[line] = 1
        close(vendored_file)
    }
    /^\+\+\+ / {
        f = $0
        sub(/^\+\+\+ [ab]\//, "", f)
        n = split(f, parts, "/")
        base = parts[n]
        # data ledgers (HIMMEL-2894 suite-durations.tsv) list suite basenames,
        # which legitimately contain the marker words; T13 is about runtime
        # surface, and a TSV has none. *.test.(ts|js|mjs|cjs) (HIMMEL-3151)
        # gets the same test-fixture exemption as the shell "test-*"
        # convention: a JS/TS test legitimately asserts on the very marker
        # words T13(b) scans for (e.g. a setInterval-timing test).
        skip = (base ~ /^test-/) || (base ~ /\.tsv$/) \
            || (base ~ /\.test\.(ts|js|mjs|cjs)$/) || (f in vendored)
        kind = (tolower(base) ~ /\.md$/) ? "md" : "code"
        next
    }
    skip { next }
    /^\+/ { print; print kind > kind_file }
    /^-/ && !/^--- / { print > removed_file }
' > "$SHIPPED"

# ----------------------------------------------------------------------------
# T12 -- no-bloat (AC6): root CLAUDE.md does not grow on net (add-del <=1).
# Changed 2026-09-06 from a symmetric per-side cap (add<=1 AND del<=1) to a
# net-growth cap, HIMMEL-2581: the per-side form failed ordinary rewordings
# (PR #2101/HIMMEL-2413, add=2 del=2 -- the same shape the HIMMEL-2581 doc
# sweep hit) and even a pure multi-line deletion, neither of which is the
# rule-block bloat this check exists to catch. Verdict computed by
# t12_verdict() in t12-no-bloat-lib.sh, shared with its control
# (test-t12-no-bloat-lib.sh) so the threshold itself is exercised directly
# against synthetic add/del pairs, not just inferred from this suite passing.
#
# Sourced INSIDE the not-a-projection branch below, not unconditionally
# (HIMMEL-2642 follow-up): a propagation-snapshot tree's `.himmel-public-
# projection` marker can legitimately be present while the marker's own
# private base SHA predates a later private-only addition of THIS file --
# ordinary two-step propagation lag (observed live: the open yotamleo/Himmel
# PR #567 was based on private 69a2751b; t12-no-bloat-lib.sh landed in
# private commit 25e937e0, confirmed NOT an ancestor of 69a2751b via
# `git merge-base --is-ancestor`, i.e. added to private AFTER that PR's base
# -- not a propagation bug, just not reshipped yet). snapshot_verify's own
# claim (1) already guarantees this file's presence/byte-content on any
# public tree whose marker base SHA postdates its creation -- a per-file
# manifest entry here would duplicate that generic completeness proof for
# one name. Sourcing it only where it is actually used means a tree in that
# lag window (marker present, dependency not yet reshipped) never needs it
# at all, since T12 is skipped in exactly that branch.
if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
    echo "SKIP T12 no-bloat: $SNAPSHOT_REASON"
else
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/t12-no-bloat-lib.sh"
    claude_ns="$(git diff "$BASE...HEAD" --numstat -- CLAUDE.md | head -n 1)"
    claude_add=0
    claude_del=0
    if [ -n "$claude_ns" ]; then
        claude_add="$(printf '%s' "$claude_ns" | awk '{print $1}')"
        claude_del="$(printf '%s' "$claude_ns" | awk '{print $2}')"
        case "$claude_add" in '' | *[!0-9]*) claude_add=0 ;; esac
        case "$claude_del" in '' | *[!0-9]*) claude_del=0 ;; esac
    fi
    if ! t12_verdict "$claude_add" "$claude_del"; then
        FAIL=$((FAIL + 1))
    fi
fi

# ----------------------------------------------------------------------------
# T13 -- no new always-on surface (AC7).
# (a) no new SessionStart/PreToolUse registration in the hook-reg files;
# (b) no unbounded-loop / background-service / JS-timer marker in shipped src.
# ----------------------------------------------------------------------------
if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
    echo "SKIP T13 no-always-on: $SNAPSHOT_REASON"
else
    # (a) hook-registration files only: .claude/settings.json + any */hooks.json.
    t13a_hit=0
    while IFS= read -r hf; do
        [ -n "$hf" ] || continue
        if git diff "$BASE...HEAD" -- "$hf" | grep '^+' | grep -v '^+++' \
            | grep -E '(SessionStart|PreToolUse)' >/dev/null; then
            t13a_hit=1
            echo "FAIL T13(a): new SessionStart/PreToolUse registration in $hf" >&2
        fi
    done < <(git diff "$BASE...HEAD" --name-only \
        | grep -E '(^|/)hooks\.json$|^\.claude/settings\.json$' || true)

    # (b) shipped-source loop / service / timer markers.
    # A marker line counts only if no identical line (compared after trimming
    # leading/trailing whitespace) is REMOVED elsewhere in the same diff: code
    # moved between files is not new always-on surface (HIMMEL-3147; same class
    # as HIMMEL-3090 renames / HIMMEL-3151 test fixtures). One removal cancels
    # ONE addition, so a moved line plus a duplicate still fails, and a marker
    # added while a DIFFERENT line is removed is never neutral.
    #
    # `while true` / `setInterval` match every shipped line, as they always
    # have. The daemon class (HIMMEL-3233) used to be the bare word `daemon`
    # on every line, so prose naming an EXISTING daemon failed (PR #932: a
    # README remedy, a shell comment). It now skips prose only, and is never
    # weaker on code:
    #   - *.md is prose: the daemon class does not apply there;
    #   - a full-line comment (#, //, /*, *, <!--) is prose: skipped. A
    #     leading run of `/* ... */` / `<!-- ... -->` closed on the line is
    #     stripped first, so the code after it is still checked;
    #   - on every other line the bare word `daemon` still counts, quoted or
    #     not. Known limit: a message string naming a daemon (a doctor
    #     `emit "the qmd daemon is wedged"`) still trips the gate -- telling a
    #     message from an argv/`bash -c` string is not a regex's job (three
    #     review rounds each found a new shape that hid a real daemon).
    #     Workaround: name the daemon in a comment line, or say "service";
    #   - service-creation shapes count too, which the bare word never
    #     caught: `nohup ... &` backgrounded (a lone `&`, not `&&` or a
    #     `2>&1` redirect), `systemctl ... enable`, `launchctl
    #     load|bootstrap`. Bare nohup/setsid/disown are NOT shapes: measured
    #     on main 2026-09-19 they hit 31 lines, mostly hook command-position
    #     case lists (`command|exec|nohup)`) and bounded detach helpers
    #     (scripts/lib/detach.sh); `nohup ... &` hits 7 lines in 4 files,
    #     each a real detached process;
    #   - the exact command `systemctl [--user] daemon-reload` is carved out
    #     (HIMMEL-3414, rule at the gsub below); it reloads unit files and
    #     starts nothing. Known gap, unchanged: `systemctl start` is no shape.
    # ponytail: a heredoc body or multi-line string holding `#` at line start
    # reads as a comment, and a C-preprocessor `#define` line likewise
    # (himmel ships no C).
    t13b_hit=0
    t13b_count="$(awk -v removed_file="$REMOVED" -v kind_file="$SHIPPED_KIND" '
        function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t\r]+$/, "", x); return x }
        BEGIN {
            while ((getline line < removed_file) > 0) removed[trim(substr(line, 2))]++
            close(removed_file)
        }
        {
            if ((getline kind < kind_file) <= 0) kind = "code"
            t = trim(substr($0, 2))
            lt = tolower(t)
            hit = (lt ~ /while[ \t]+true|setinterval/)
            code = lt
            while (code ~ /^\/\*.*\*\/|^<!--.*-->/) {
                if (substr(code, 1, 2) == "/*") code = trim(substr(code, index(code, "*/") + 2))
                else code = trim(substr(code, index(code, "-->") + 3))
            }
            # HIMMEL-3414: `systemctl [--user] daemon-reload` reloads systemd unit
            # files and starts nothing; it is the only place the word `daemon`
            # is a verb argument rather than a process. Strip that EXACT token
            # (twice: a match eats its trailing `;`, so adjacent tokens need a
            # second pass) and let the rest of the line meet the same rules, so
            # `... && nohup ... &` or `... --daemon` beside it still fails.
            # It must END the command (end of line, `;` `&` `|` `)` `>` `#`,
            # or an fd redirect): `daemon-reload --now x`, `daemon-reloader`,
            # `daemon-reexec` and any other verb keep the bare word `daemon`.
            gsub(/(^|[^a-z0-9_-])systemctl[ \t]+(--user[ \t]+)?daemon-reload[ \t]*($|[;&|)>#]|[0-9]>)/, " ", code)
            gsub(/(^|[^a-z0-9_-])systemctl[ \t]+(--user[ \t]+)?daemon-reload[ \t]*($|[;&|)>#]|[0-9]>)/, " ", code)
            code = trim(code)
            # HIMMEL-3432: a READ-ONLY process lookup naming a daemon is not
            # a daemon start -- it reads /proc, nothing else (found on PR
            # #1087: headed-arm-leg.sh (headless mode) reads the environ of
            # Claude Code own transient `claude daemon run`, which the CLI
            # background-run flag spawns and himmel never starts or keeps). The carve-out
            # keys on the LINE COMMAND being one of three lookup shapes
            # (pgrep, `pkill -0`, `ps ... | grep`) with NO chaining on that
            # line (no `;`, `&&`, `||`, backgrounding `&`, or an extra `|`)
            # -- never on stripping the word "daemon" itself, so `pgrep ... ||
            # claude daemon run &` still hits (the `||`/`&` disqualify it as a
            # lookup) and bare `pkill` (no `-0`) still hits (it terminates,
            # it does not merely test). It suppresses ONLY the bare-word
            # "daemon" match below; a lookup line that also matches a
            # service-start shape (nohup &, systemctl enable, launchctl load)
            # still hits on that shape. A command or process substitution in
            # the lookup argument (`pgrep -f "$(claude daemon run)"`, the
            # backtick form, or `pgrep -f <(claude daemon run)` / `>(...)`)
            # executes that argument BEFORE pgrep even runs, so it is not
            # read-only either -- `subst` disqualifies all three shapes.
            # `pkill
            # -0` additionally requires `-0` be the ONLY signal-like flag on the
            # line: `pkill -0 -9 -f ...` still matches the leading `-0` but a
            # later flag can override which signal is actually sent, so a
            # second `-<digit>` or `-s`/`--signal` flag disqualifies it too.
            subst = code ~ /\$\(|`|<\(|>\(/
            is_lookup = 0
            if (code ~ /^pgrep([ \t]|$)/) {
                if (code !~ /[;&|]/ && !subst) is_lookup = 1
            } else if (code ~ /^pkill[ \t]+-0([ \t]|$)/) {
                pkrest = code
                sub(/^pkill[ \t]+-0[ \t]*/, "", pkrest)
                if (code !~ /[;&|]/ && !subst &&
                    pkrest !~ /(^|[ \t])-([0-9]|-?signal([ \t=]|$)|s([ \t]|$))/) is_lookup = 1
            } else if (code ~ /^ps[ \t]/) {
                if (code ~ /^ps[^|;&]*\|[ \t]*grep([ \t]|$)[^;&|]*$/ && !subst) is_lookup = 1
            }
            daemon_hit = (code ~ /daemon/) && !is_lookup
            service_hit = code ~ /(^|[^a-z0-9_-])nohup[ \t].*(^|[^&<>])&([ \t]*($|[);"\047])|[ \t]+[^&> \t])|systemctl[^|;&]*[ \t]enable([ \t]|$)|launchctl[ \t]+(load|bootstrap)([ \t]|$)/
            if (!hit && kind == "code" && code != "" && code !~ /^(#|\/\/|\/\*|\*([ \t]|$)|<!--)/ &&
                (daemon_hit || service_hit))
                hit = 1
            # HIMMEL-3432: a trailing `# t13b-ok: <reason>` on THIS shipped
            # line exempts it from T13(b) only -- not T13(a), not T12/T14/T15
            # (this check lives entirely inside the T13(b) per-line loop). An
            # empty reason (`# t13b-ok:` or `# t13b-ok: ` with nothing after)
            # does not exempt, and the marker never reaches a DIFFERENT line
            # (t/lt hold only this LINE own text, so a marker on the line above
            # cannot cancel a hit here).
            # ponytail: the match is text-only, not quote-aware -- a marker
            # spelled inside a quoted argument (e.g. --label "# t13b-ok: x")
            # exempts the line the same as a real trailing comment would. This
            # gate is a line-based awk scan with no shell tokenizer anywhere in
            # it (see the systemctl-daemon-reload carve-out above for the same
            # limit), so telling a real comment from a quoted string would need
            # one; out of scope for this narrow carve-out.
            if (t ~ /#[ \t]*t13b-ok:[ \t]*[^ \t]/) hit = 0
            if (hit) {
                if (removed[t] > 0) removed[t]--
                else hits++
            }
        }
        END { print hits + 0 }
    ' "$SHIPPED")" || t13b_count=1
    if [ "$t13b_count" != "0" ]; then
        t13b_hit=1
        echo "FAIL T13(b): unbounded-loop / background-service / JS-timer marker in shipped source." >&2
    fi

    if [ "$t13a_hit" -eq 0 ] && [ "$t13b_hit" -eq 0 ]; then
        echo "PASS T13 no-always-on: no new hook registration; no loop/service/timer in shipped source."
    else
        FAIL=$((FAIL + 1))
    fi
fi

# ----------------------------------------------------------------------------
# T14 -- locks (AC8).
# (a) RETIRED 2026-07-13 (operator decision, HIMMEL-979): the D9 no-claude-codex
#     lock was superseded -- the claude-codex lane (scripts/claude-codex{,.ps1})
#     ships with native guard posture (Claude Code IS the harness, same column
#     as claude-glm). See docs/internals/lane-parity.md "claude-codex lock".
# (b) no per-token-lane wiring in shipped source;
# (c) gemini/copilot/cursor index rows stay deferred.
# ----------------------------------------------------------------------------
t14b_hit=0
if grep -Ei 'token-lane' "$SHIPPED" >/dev/null; then
    t14b_hit=1
    echo "FAIL T14(b): per-token-lane wiring in shipped source." >&2
fi

t14c_hit=0
PARITY_DOC="docs/internals/lane-parity.md"
if [ ! -f "$PARITY_DOC" ]; then
    t14c_hit=1
    echo "FAIL T14(c): lane-parity index doc missing ($PARITY_DOC)." >&2
else
    # Every gemini/copilot/cursor TABLE row must carry the 'deferred' token.
    bad_rows="$(grep -Ei '^\|.*gemini|^\|.*copilot|^\|.*cursor' "$PARITY_DOC" \
        | grep -Eiv 'deferred' || true)"
    if [ -n "$bad_rows" ]; then
        t14c_hit=1
        echo "FAIL T14(c): gemini/copilot/cursor row(s) not deferred:" >&2
        printf '%s\n' "$bad_rows" >&2
    fi
    if ! grep -Eiq '^\|.*(gemini|copilot|cursor).*deferred' "$PARITY_DOC"; then
        t14c_hit=1
        echo "FAIL T14(c): no deferred gemini/copilot/cursor row in $PARITY_DOC." >&2
    fi
fi

if [ "$t14b_hit" -eq 0 ] && [ "$t14c_hit" -eq 0 ]; then
    echo "PASS T14 locks: no per-token-lane wiring; gemini/copilot/cursor deferred. (T14(a) claude-codex lock retired, HIMMEL-979.)"
else
    FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------------
# T15 -- cross-platform (AC9): every NEW scripts/**/*.sh ships a .ps1 twin OR
# a documented platform-guard marker in its header. Predicate shared with
# scripts/hooks/check-new-shell-platform-guard.sh via
# scripts/lib/platform-guard.sh (HIMMEL-2682) so the two cannot drift.
# ----------------------------------------------------------------------------
if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
    echo "SKIP T15 x-platform: $SNAPSHOT_REASON"
else
    # shellcheck source=scripts/lib/platform-guard.sh
    # shellcheck disable=SC1091
    . "$REPO/scripts/lib/platform-guard.sh"
    t15_fail=0
    t15_n=0
    while IFS= read -r sh_path; do
        [ -n "$sh_path" ] || continue
        t15_n=$((t15_n + 1))
        if platform_guard_ok "$sh_path"; then
            twin="${sh_path%.sh}.ps1"
            if [ -f "$twin" ]; then
                echo "ok T15: $sh_path -> .ps1 twin present ($twin)."
            else
                echo "ok T15: $sh_path -> documented platform-guard marker."
            fi
            continue
        fi
        echo "WARN T15: $sh_path has neither a .ps1 twin nor a platform-guard marker (advisory only, HIMMEL-3125 -- Windows is alpha)." >&2
        t15_fail=1
    done < <(git diff "$BASE...HEAD" --diff-filter=A --name-only -- 'scripts/' \
        | grep -E '\.sh$' || true)

    if [ "$t15_n" -eq 0 ]; then
        echo "PASS T15 x-platform: no new scripts/**/*.sh in the diff (vacuous)."
    elif [ "$t15_fail" -eq 0 ]; then
        echo "PASS T15 x-platform: all ${t15_n} new scripts/**/*.sh have a twin or guard."
    else
        echo "PASS T15 x-platform (advisory, HIMMEL-3125): ${t15_n} new scripts/**/*.sh, some without a twin or guard -- no longer CI-gated now that Windows is alpha; see docs/internals/harness-compat.md."
    fi
fi

# ----------------------------------------------------------------------------
# Verdict
# ----------------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
    if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
        echo "FAIL: WS5 invariants test failed ($FAIL section(s)) -- T12/T13/T15 skipped (propagation snapshot), T14 ran and failed." >&2
    else
        echo "FAIL: WS5 invariants test failed ($FAIL section(s))." >&2
    fi
    exit 1
fi
if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
    echo "PASS: WS5 invariants test (T14 locks ran; T12 no-bloat, T13 no-always-on, T15 x-platform SKIPPED -- propagation snapshot, HIMMEL-2642)."
else
    echo "PASS: WS5 invariants test (T12 no-bloat, T13 no-always-on, T14 locks, T15 x-platform)."
fi
exit 0
