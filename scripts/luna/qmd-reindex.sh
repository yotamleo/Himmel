#!/usr/bin/env bash
# qmd-reindex.sh — deterministic qmd index refresh: `qmd update` then
# `qmd embed`, then a completeness assert (HIMMEL-568).
#
# WHY: the qmd index goes stale SILENTLY. Observed during HIMMEL-564 Phase A —
# `qmd status` reported luna lastUpdated 2026-06-22 with needsEmbedding: 0 for
# five days, so notes written 2026-06-27 were simply not searchable, and every
# qmd-backed workflow (compounding, ingest, synthesis, recall) answered off a
# stale index without signalling anything. This script is the RUNNER that fixes
# that; scripts/luna/qmd-cadence.sh is the scheduler that fires it daily.
#
# The split is deliberate and mirrors the graphify precedent (HIMMEL-825/829):
# refresh-graph-map.sh is the runner, graphmap-cadence.sh the arm layer. Keeping
# them separate is what lets HIMMEL-1275's ship transport invoke the SAME build
# step on demand ("ship after a successful local reindex") without re-entering a
# scheduler.
#
# DESIGN: this is a DETERMINISTIC SCRIPT, not a claude session. `qmd update` and
# `qmd embed` are plain CLI calls, so there is no bounded-session shape here — no
# NUL stdin, no --settings auto-approve fragment, no claude invocation at all.
# HIMMEL-128 (headless-claude billing) therefore does not apply: nothing in this
# path shells `claude`, unlike refresh-graph-map.sh whose graphify backend does.
#
# WHY A SECOND `qmd embed` (the completeness assert): `qmd embed` has a session
# cap (--timeout, default 30 minutes). A run that hits the cap exits having
# embedded only PART of the pending set, leaving vectors lagging the lex index —
# which is the EXACT silently-wrong state this ticket exists to eliminate, just
# with a fresher timestamp on it. So after embedding we call `qmd embed` again:
# when the set is genuinely complete it is a no-op that prints
# "All content hashes already have embeddings" and costs ~1s. A pass that
# reports embedding work means vectors were still pending, and we fail LOUD
# (rc=5) instead of reporting success.
#
# WHY THIS STILL READS A STRING (HIMMEL-1282, decision recorded). The ticket
# offered two routes: query the index directly (contentvectors / vectorsvec), or
# accept the coupling with a pinned-version note. Taking the second, and the
# reasoning is not "cheaper":
#   - The SQL route swaps coupling to qmd's PUBLIC CLI output for coupling to
#     its PRIVATE schema. A renamed table or a changed vec0 layout is a tighter
#     break, not a looser one, and it breaks with a SQL error or — worse — a
#     silently wrong COUNT, where a reworded CLI line at least still prints.
#   - It puts a DB-driver dependency inside a cadence whose value is being
#     dependency-light. Under node that means better-sqlite3, whose native
#     binding is the exact thing scripts/lib/qmd-bin.sh carries ~60 lines of
#     recovery machinery for (HIMMEL-928); a daily unattended job is the last
#     place that belongs.
#   - Checked first, as the ticket asked: qmd 2.6.3 offers NO machine-readable
#     mode to prefer. `--format json` is a SEARCH option; `qmd status --format
#     json` and `qmd collection list --json` are both silently IGNORED and print
#     the same prose.
# What the ticket is actually right about is the FAILURE MODE, and that is what
# changed: an unrecognized verifier used to report "embed INCOMPLETE" (rc 5) — a
# wrong diagnosis that would fire nightly after any reword and train the
# operator to disarm the cadence. It now reports rc 6, "cannot read the
# verifier", which is true and actionable. Still fail-closed either way.
# If the operator prefers the SQL route, this is the note to overrule.
#
# DAEMON SAFETY: a resident `qmd mcp` daemon (the qmd-mcp-daemon scheduled task,
# plus any MCP client holding the index) may be live while this runs. This runner
# does NOT fence (stop/start) the daemon.
#
# Be precise about the evidence for that, because "verified safe" is a bigger
# claim than what was actually measured. OBSERVED on 2026-07-25: with the daemon
# up (PID 26420 @ localhost:8181), a full `qmd update` + `qmd embed` completed
# without error, and the daemon was still serving on the SAME PID afterwards.
# That is process survival + no error — it is NOT a concurrency proof: nothing
# exercised MCP reads racing these writes, and SQLite-level read consistency
# under concurrent access was not tested. It is enough to justify not fencing by
# default; it is not enough to call the combination proven. If a fence is ever
# needed, it belongs HERE, in the runner — not in the scheduler.
#
# COLLECTION SCOPE: all configured collections. Both `qmd update` and `qmd embed`
# default to every collection and take `-c <name>` only to NARROW, so the bare
# calls below are the "everything qmd knows about" scope by construction. That is
# deliberately not a hardcoded list — a collection added later is picked up with
# no edit here. (Local carries 4 today: himmel, luna, salus, luna-curated.)
#
# CONCURRENCY: no lock. The scheduled task is registered with
# MultipleInstancesPolicy=IgnoreNew, so the cadence cannot overlap ITSELF; an
# on-demand run racing a scheduled one is left to qmd's own SQLite locking, the
# same bet graphmap-cadence makes. Cost basis for why overlap is unlikely: a full
# local refresh measured 2026-07-25 took 16s (update) + 24s (embed, 457 chunks /
# 81 docs) — a daily run has ~24h of headroom.
#
# Usage:
#   bash scripts/luna/qmd-reindex.sh [--qmd-bin PATH] [--qmd-js PATH] [--dry-run]
#
#   --qmd-bin PATH   Absolute path to the qmd EXECUTABLE. Default: resolved via
#                    scripts/lib/qmd-bin.sh's preference order (HIMMEL-1283),
#                    NOT a bare `command -v qmd`. The cadence passes this
#                    explicitly, because schtasks and cron fire with a MINIMAL
#                    PATH that does not carry the bun bin dir where qmd installs.
#   --qmd-js PATH    Optional absolute script path passed as the first argument
#                    to --qmd-bin, i.e. the invocation becomes
#                    `<qmd-bin> <qmd-js> update` instead of `<qmd-bin> update`.
#                    This is how the bun-served install is pinned: qmd's
#                    canonical invocation there is `bun <.../dist/cli/qmd.js>`,
#                    two tokens, and neither is a `qmd` executable. Requires
#                    --qmd-bin (HIMMEL-1283).
#   --dry-run        Print the two commands that would run, execute neither.
#
# Exit codes:
#   0  index refreshed and verified complete
#   1  usage / input error
#   2  qmd executable not found or not usable
#   3  `qmd update` failed
#   4  `qmd embed` failed
#   5  embed INCOMPLETE — vectors still pending after the embed pass
#   6  completeness assert could not READ its verifier (qmd reworded its
#      output) — distinct from 5 on purpose; see the sentinel note below
set -euo pipefail

QMD_BIN=""
QMD_JS=""
DRY_RUN=0

# --- completeness-assert sentinels (HIMMEL-1282) -----------------------------
#
# The assert reads `qmd embed` output. That is coupling to a human-readable
# string, and the decision NOT to replace it with a SQL check is deliberate —
# see the header note. What this pins down is the failure mode: keep the
# sentinels NAMED, in one place, with the version they were verified against,
# and recognise BOTH outcomes rather than treating "not complete" as
# "incomplete". A reword then reports itself instead of impersonating a stale
# index.
#
# complete : the no-op pass. Matched as a fixed ASCII substring only — the real
#            line is prefixed with a UTF-8 check mark, and this output is read
#            under the OEM codepage when the cadence fires from cmd.exe.
# did-work : the pass embedded something, i.e. work WAS pending. Regex, because
#            the counts vary.
QMD_SENTINEL_COMPLETE='All content hashes already have embeddings'
QMD_SENTINEL_DID_WORK='Embedded [0-9]+ chunks?'
QMD_SENTINEL_VERIFIED_AGAINST='qmd 2.6.3'

usage() {
    cat <<'EOF'
Usage: qmd-reindex.sh [--qmd-bin PATH] [--qmd-js PATH] [--dry-run]

Refresh the qmd index across ALL configured collections: `qmd update`
(re-index changed files) then `qmd embed` (generate missing vectors),
then assert the embed actually finished.

Flags:
  --qmd-bin <PATH>  Absolute path to the qmd executable (default: resolved via
                    scripts/lib/qmd-bin.sh's preference order). Schedulers fire
                    with a minimal PATH that lacks qmd's bin dir, so the cadence
                    always passes this explicitly.
  --qmd-js <PATH>   Optional absolute script path passed as the first argument
                    to --qmd-bin, making the invocation `<bin> <js> update`.
                    This is how a bun-served qmd is pinned (`bun .../qmd.js`).
                    Requires --qmd-bin.
  --dry-run         Print what would run; execute nothing.

Exit: 0 ok | 1 usage | 2 qmd unusable | 3 update failed | 4 embed failed
      5 embed incomplete (vectors still pending)
      6 completeness assert could not read its verifier (qmd output reworded)
EOF
}

# Invoke the resolved qmd. Two tokens when --qmd-js is in play (`bun <js> …`),
# one otherwise — each quoted separately so a space in either path (a Windows
# certainty) cannot split it (HIMMEL-1283).
run_qmd() {
    if [ -n "$QMD_JS" ]; then
        "$QMD_BIN" "$QMD_JS" "$@"
    else
        "$QMD_BIN" "$@"
    fi
}

# Human-readable form of the invocation, for logs and --dry-run.
qmd_desc() {
    if [ -n "$QMD_JS" ]; then
        printf '%s %s' "$QMD_BIN" "$QMD_JS"
    else
        printf '%s' "$QMD_BIN"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --qmd-bin)
            # Demand a real operand. Without this, a trailing `--qmd-bin` makes
            # `shift 2` fail under set -e and the script dies with no message,
            # and `--qmd-bin --dry-run` silently swallows the next FLAG as the
            # path (surfacing later as a confusing "not an executable file").
            # An EXPLICITLY EMPTY operand is rejected too: `--qmd-bin ""` would
            # otherwise leave QMD_BIN empty and fall through to PATH resolution,
            # silently ignoring the flag the caller deliberately passed.
            if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo "ERR qmd-reindex: --qmd-bin requires an absolute path operand" >&2
                usage >&2
                exit 1
            fi
            QMD_BIN="$2"; shift 2 ;;
        --qmd-bin=*)
            QMD_BIN="${1#--qmd-bin=}"
            if [ -z "$QMD_BIN" ]; then
                echo "ERR qmd-reindex: --qmd-bin requires an absolute path operand" >&2
                usage >&2
                exit 1
            fi
            shift ;;
        --qmd-js)
            # Same operand discipline as --qmd-bin above: reject a missing,
            # empty, or flag-shaped operand rather than swallowing the next arg.
            if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo "ERR qmd-reindex: --qmd-js requires an absolute path operand" >&2
                usage >&2
                exit 1
            fi
            QMD_JS="$2"; shift 2 ;;
        --qmd-js=*)
            QMD_JS="${1#--qmd-js=}"
            if [ -z "$QMD_JS" ]; then
                echo "ERR qmd-reindex: --qmd-js requires an absolute path operand" >&2
                usage >&2
                exit 1
            fi
            shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)
            echo "ERR qmd-reindex: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# --qmd-js is meaningless without an executable to pass it to: on its own it
# would be silently ignored while the caller believes they pinned the bun-served
# install. Reject it explicitly (HIMMEL-1283).
if [ -n "$QMD_JS" ] && [ -z "$QMD_BIN" ]; then
    echo "ERR qmd-reindex: --qmd-js requires --qmd-bin (the invocation is '<qmd-bin> <qmd-js> …')" >&2
    usage >&2
    exit 1
fi

# Resolve qmd. An explicit --qmd-bin wins; otherwise fall back to the SHARED
# resolver's preference order, NOT a bare `command -v qmd` (HIMMEL-1283). The
# bare lookup finds the broken Claude-plugin stub that shadows the bun shim on
# Git Bash $PATH inside a Claude Code session — the exact context an operator
# runs this from by hand — and that stub dies with "Module not found …
# dist/cli/qmd.js". qmd_pinned_invocation prefers the bun-served install the
# same way qmd_cmd does, and returns absolute tokens.
if [ -z "$QMD_BIN" ]; then
    # shellcheck source=../lib/qmd-bin.sh
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/qmd-bin.sh"
    _resolved=""
    if ! _resolved=$(qmd_pinned_invocation 2>/dev/null); then
        {
            echo "ERR qmd-reindex: no usable qmd found and --qmd-bin was not given."
            echo "    Install qmd, or pass the absolute path: --qmd-bin /path/to/qmd"
        } >&2
        exit 2
    fi
    QMD_BIN=$(printf '%s\n' "$_resolved" | sed -n '1p')
    QMD_JS=$(printf '%s\n' "$_resolved" | sed -n '2p')
    unset _resolved
fi

# Demand a real, absolute, executable file — the same discipline graphmap-cadence
# applies to the `claude` it pins. `command -v` also resolves shell FUNCTIONS and
# ALIASES (to their own name) and relative PATH entries (to a relative path);
# either would be meaningless once a scheduled runner has cd'd elsewhere under a
# different PATH. Windows note: `command -v qmd` yields an extensionless path
# that MSYS resolves to qmd.exe, and -f/-x accept it.
case "$QMD_BIN" in
    /*|[A-Za-z]:[/\\]*) : ;;
    *)
        echo "ERR qmd-reindex: qmd resolved to a non-absolute path ('$QMD_BIN') — a shell function/alias or relative PATH entry cannot be used from a scheduled runner." >&2
        exit 2
        ;;
esac
if [ ! -f "$QMD_BIN" ] || [ ! -x "$QMD_BIN" ]; then
    echo "ERR qmd-reindex: qmd path '$QMD_BIN' is not an executable file." >&2
    exit 2
fi
# The script arg gets the same absolute + real-file discipline. It is NOT
# required to be executable — it is a .js handed to an interpreter, not run
# directly (HIMMEL-1283).
if [ -n "$QMD_JS" ]; then
    case "$QMD_JS" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *)
            echo "ERR qmd-reindex: --qmd-js is not an absolute path ('$QMD_JS') — it cannot be resolved from a scheduled runner that has cd'd elsewhere." >&2
            exit 2
            ;;
    esac
    if [ ! -f "$QMD_JS" ]; then
        echo "ERR qmd-reindex: --qmd-js path '$QMD_JS' is not a file." >&2
        exit 2
    fi
fi

stamp() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?'; }

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY qmd-reindex: would run: $(qmd_desc) update"
    echo "DRY qmd-reindex: would run: $(qmd_desc) embed"
    echo "DRY qmd-reindex: would re-run: $(qmd_desc) embed   (completeness assert)"
    echo "qmd-reindex: dry-run complete (no changes made)"
    exit 0
fi

echo "qmd-reindex: start $(stamp) (qmd: $(qmd_desc))"

# --- 1. re-index changed files across every configured collection -----------
echo "qmd-reindex: [1/3] qmd update"
if ! run_qmd update; then
    echo "ERR qmd-reindex: 'qmd update' failed — index NOT refreshed." >&2
    exit 3
fi

# --- 2. embed whatever the update left without vectors ----------------------
echo "qmd-reindex: [2/3] qmd embed"
if ! run_qmd embed; then
    echo "ERR qmd-reindex: 'qmd embed' failed — lex index is fresh but vectors are NOT." >&2
    exit 4
fi

# --- 3. completeness assert (see the header for why this is not optional) ---
# A no-op embed prints "All content hashes already have embeddings". Match the
# ASCII substring only: the real line is prefixed with a UTF-8 check mark, and
# this output is read under the OEM codepage when the cadence fires from cmd.exe.
echo "qmd-reindex: [3/3] verifying embed completeness"
VERIFY_OUT=""
VERIFY_RC=0
VERIFY_OUT=$(run_qmd embed 2>&1) || VERIFY_RC=$?
if [ "$VERIFY_RC" -ne 0 ]; then
    echo "ERR qmd-reindex: completeness re-check ('qmd embed') failed (rc=$VERIFY_RC):" >&2
    printf '%s\n' "$VERIFY_OUT" >&2
    exit 4
fi
# Match with a HERE-STRING, not `printf … | grep -q` (HIMMEL-1115, same class
# already fixed in check-security-reviewed.sh). Under `set -o pipefail`, grep -q
# exits early on a match, printf takes SIGPIPE (141), and pipefail surfaces 141
# as the pipeline status — so a SUCCESSFUL match reads as a failure once the
# output is large enough to not fit the pipe buffer. Here that inversion would
# report "embed INCOMPLETE" (rc=5) on a fully COMPLETE embed: a loud false alarm
# in the exact check that exists to prevent silent wrongness.
if grep -qF -- "$QMD_SENTINEL_COMPLETE" <<<"$VERIFY_OUT"; then
    :   # complete — fall through to the success line below
elif grep -qE -- "$QMD_SENTINEL_DID_WORK" <<<"$VERIFY_OUT"; then
    # POSITIVE evidence of incompleteness: the verify pass found work left to
    # do, so vectors really are lagging the lex index.
    {
        echo "ERR qmd-reindex: embed INCOMPLETE — content hashes still need vectors after the embed pass."
        echo "    Vectors are lagging the lex index, which is the silently-stale state this"
        echo "    runner exists to prevent. Most likely cause: 'qmd embed' hit its session"
        echo "    cap (--timeout, default 30 min). Re-run this script, or embed by hand:"
        echo "        $(qmd_desc) embed --timeout 0"
        echo "    Verifier output was:"
        printf '%s\n' "$VERIFY_OUT" | sed 's/^/        /'
    } >&2
    exit 5
else
    # NEITHER sentinel matched. Do not guess (HIMMEL-1282). Before this, an
    # unrecognized verifier read as "INCOMPLETE" (rc 5) — so the day qmd rewords
    # its output, a fully COMPLETE index reports a loud daily failure with a
    # diagnosis that is simply WRONG, and the operator's rational response to a
    # cadence that cries wolf every night is to disarm it, re-opening the very
    # staleness hole HIMMEL-568 closed. Report what actually happened instead:
    # the assert can no longer read its verifier. Still FAIL-CLOSED (nonzero,
    # nothing is called complete) — the fix is to make the wrong answer
    # distinguishable from the right one, not to start trusting it.
    {
        echo "ERR qmd-reindex: completeness assert UNRECOGNIZED verifier output — cannot tell complete from incomplete."
        echo "    This is NOT 'the index is stale' — it is 'this script can no longer read qmd'."
        echo "    Neither known sentinel matched:"
        echo "        complete : $QMD_SENTINEL_COMPLETE"
        echo "        did-work : $QMD_SENTINEL_DID_WORK   (regex)"
        echo "    Most likely cause: a qmd release reworded 'qmd embed' output. Verify by hand"
        echo "    (${QMD_SENTINEL_VERIFIED_AGAINST} is the version these were checked against):"
        echo "        $(qmd_desc) embed"
        echo "    then update the sentinels at the top of this script."
        echo "    Verifier output was:"
        printf '%s\n' "$VERIFY_OUT" | sed 's/^/        /'
    } >&2
    exit 6
fi

echo "qmd-reindex: OK $(stamp) — index refreshed, all content hashes embedded"
