#!/usr/bin/env bash
# qmd-staleness.sh — report whether the LOCAL qmd index is fresh and complete
# enough to be trusted, and say so LOUDLY when it is not (HIMMEL-1286).
#
# WHY: the index degrades silently, and the degradation is invisible at query
# time. During HIMMEL-564 the luna collection sat five days stale while notes
# written that week were simply not searchable. Measured 2026-07-26 the win2
# station was 23h stale, missing an entire collection, and carrying 2722
# un-embedded chunks — semantic search there was quietly degraded and NOTHING
# signalled it. scripts/luna/qmd-reindex.sh fixes a stale index and
# scripts/luna/ship-index.sh delivers one; what was missing is the cheap READ
# that tells a session its substrate cannot be trusted before it answers off it.
# This is that read.
#
# Fail loud beats fail quiet: a session that KNOWS the index is stale can treat
# misses as unproven. A session that does not know reports a confident absence.
# A qmd miss is not evidence a fact is absent — that is only true when the index
# is current, which is exactly what this script establishes.
#
# THIS SCRIPT NEVER WRITES. It runs `qmd status` and parses it. It does not
# reindex, embed, or ship — deliberately. On the receiving station a reindex is
# the WRONG reaction (win2 embeds at ~5 docs/min vs ~256 on the host, so an
# in-place rebuild there was projected at ~17 hours and killed mid-run); the
# right reaction is to say so and let the host push. The notice therefore tells
# the reader NOT to reindex rather than offering to.
#
# SHAPE: a deterministic script, like its siblings qmd-reindex.sh and
# ship-index.sh — no claude session, no NUL stdin, no settings fragment.
# HIMMEL-128 (headless-claude billing) does not apply; nothing here invokes
# claude.
#
# WHAT `Updated:` ACTUALLY MEASURES — READ THIS BEFORE TRUSTING IT.
# It is NOT "when the index was last refreshed". qmd computes it as
#   SELECT MAX(modified_at) FROM documents WHERE active = 1     (cli/qmd.ts)
# and `modified_at` is written from `statSync(filepath).mtime` (store.ts), i.e.
# the SOURCE FILE's mtime. So the field means:
#
#   "the newest document this index KNOWS ABOUT was edited <n> ago"
#
# That is a proxy for index freshness, not a measurement of it, and the two
# directions are not symmetric:
#
#   * A CORPUS THAT HAS BEEN QUIET reads as old even when the index was rebuilt
#     minutes ago. The age is real; the staleness inference is not. This is why
#     the notice below states the observation and both of its readings instead
#     of asserting "the index is stale" — on a slow-moving corpus that assertion
#     would be wrong daily, and a warning that is wrong daily is one the reader
#     learns to skip, taking the real warning with it.
#   * ONE ACTIVE COLLECTION CAN MASK ANOTHER. The MAX is global, so a busy
#     collection keeps the number recent while a second collection's new files
#     sit un-indexed. This direction is the dangerous one and this field cannot
#     see it at all; --require-collections covers only total ABSENCE, not
#     partial coverage.
#
# The honest fix is a durable timestamp written ONLY after a verified refresh
# (host) or a verified receipt (station) — HIMMEL-1307. That spans
# qmd-reindex.sh and the receiver leg, so it is not this script's to invent;
# what this script owes in the meantime is to claim no more than it can see.
# The signal is still worth having: for the RECEIVING station this was written
# for, an index that stopped arriving while the source corpus kept moving is
# exactly the case the proxy detects correctly.
#
# PARSING IS COUPLED TO HUMAN-READABLE OUTPUT, ON PURPOSE AND UNDER PROTEST:
# `qmd status` has no machine format. `--format json` is a SEARCH option; there
# is no `qmd status --format json` (verified 2026-07-27 — it prints the ordinary
# report and exits 0, so a caller cannot even detect the unsupported flag). That
# is the same coupling HIMMEL-1282 was filed for, so this script takes the same
# precaution qmd-reindex.sh took: it ANCHORS on the block's required fields and
# exits 6 when it cannot recognise them, rather than treating an unparseable
# report as healthy. A rewording upstream must surface as a loud "I can no
# longer read this", never as a silent all-clear.
#
# Two specimens this parser was written against (2026-07-27):
#
#   host — fresh, complete            win2 — stale, incomplete
#     Documents                         Documents
#       Total:    17141 files indexed     Total:    14918 files indexed
#       Vectors:  76055 embedded          Vectors:  72898 embedded
#       Updated:  2h ago                  Pending:  1193 need embedding (run 'qmd embed')
#                                         Updated:  1d ago
#
# Note the shape difference: `Pending:` is present ONLY when non-zero. Its
# absence is therefore the healthy case, NOT a parse failure — but that
# inference is only safe once the block has been positively identified, which
# is why Total/Vectors/Updated are all required before absence is read as zero.
#
# WHY 36h DEFAULT: the reindex cadence (HIMMEL-568) fires daily at 05:00 local,
# so a healthy index is at most ~24h old plus the run's own duration. 36h is one
# missed cadence fire plus headroom — it trips on a cadence that has actually
# stopped, not on the ordinary trough of a daily rhythm.
#
# WHAT 36h CAN ACTUALLY CERTIFY, given qmd's output granularity: `qmd status`
# reports ages under a day to the hour but everything above it as whole DAYS
# (formatTimeAgo floors), so once an index crosses 24h the finest available
# reading is "1d ago" = somewhere in [24h, 48h). This guard resolves a floored
# label to its WORST case (see age_hours), so nothing at or above 24h is
# certifiable under 36h — the practical effect of the default is "warn once the
# index crosses a day". That is not the headroom the paragraph above describes,
# and the honest reason is that the headroom is unusable: qmd simply does not
# report finely enough up there to tell 25h from 47h. The daily rhythm never
# reaches it (05:00 to 04:59 stays hour-granular), so the default still does not
# trip on a healthy cadence — only on one that has actually missed a fire, which
# is a touch earlier than "36h" suggests and never later. An operator who wants
# the literal one-missed-fire-plus-headroom behaviour sets --max-age-hours 47,
# the largest age a "1d ago" reading can represent.
#
# Usage:
#   bash scripts/luna/qmd-staleness.sh [--max-age-hours N] [--quiet]
#       [--require-collections a,b] [--qmd-bin <path>] [--qmd-js <path>]
#
#   --max-age-hours N  staleness budget in hours        (default: 36)
#   --quiet            suppress the all-clear line; the STALE/INCOMPLETE
#                      notice and every error still print
#   --require-collections a,b
#                      comma-separated collections that MUST be registered.
#                      Opt-in: without it, the collection set is not checked.
#   --qmd-bin <path>   absolute qmd (schedulers fire with a minimal PATH)
#   --qmd-js <path>    script arg for --qmd-bin, when qmd is bun-served
#
# Exit codes (chosen to mirror qmd-reindex.sh, whose 6 means the same thing):
#   0  index is fresh AND complete (and carries every required collection)
#   1  usage / input error
#   2  qmd executable not found or not usable — NOT a claim about the index.
#      This is the "adopter never installed qmd" case, and it is the ONLY
#      not-an-index-verdict code a caller may treat as silence.
#   3  STALE — last update is older than the budget
#   4  INCOMPLETE — chunks are still pending embedding
#   5  STALE and INCOMPLETE
#   6  could not READ `qmd status` (qmd reworded its output) — fail-closed,
#      deliberately distinct from 0 so an unreadable report is never an
#      all-clear
#   7  `qmd status` itself FAILED — qmd is installed but could not answer (a
#      corrupt or locked index, a crashed or wedged process). Split out of 2
#      deliberately: a caller that silences 2 to spare adopters without qmd
#      was silencing THIS too, so the one shape the guard exists to catch —
#      a substrate that stopped answering — produced no warning at all.
#   8  a REQUIRED collection is ABSENT (needs --require-collections). Takes
#      precedence over 3/4/5 when several conditions hold; the banner names
#      every one of them.
set -euo pipefail

MAX_AGE_HOURS=36
QUIET=0
QMD_BIN=""
QMD_JS=""
REQUIRE_COLLECTIONS=""

# Anchored on the END of the comment header (the `set -euo` line, then dropped)
# rather than on the last exit code's number: the old `/^#   6 /` form ended the
# range at the code's FIRST line, so any code documented in more than one line
# printed truncated mid-sentence, and every new code needed the anchor bumped by
# hand — a doc that silently stops documenting.
usage() {
    sed -n '/^# Usage:/,/^set -euo /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --max-age-hours)
            [ $# -ge 2 ] || { echo "ERR qmd-staleness: --max-age-hours needs a value." >&2; exit 1; }
            MAX_AGE_HOURS="$2"; shift 2 ;;
        # An EXPLICITLY EMPTY operand is rejected on all three flags, not just a
        # missing one. `--qmd-bin ""` would otherwise fall through to PATH
        # resolution — a caller that passed the flag to PIN qmd ends up
        # unpinned, silently (the qmd-reindex.sh / ship-index.sh lesson); and
        # `--require-collections ""` would skip the very check it was asked to
        # perform. A flag that was passed must never be a no-op.
        --qmd-bin)
            [ $# -ge 2 ] || { echo "ERR qmd-staleness: --qmd-bin needs a value." >&2; exit 1; }
            [ -n "$2" ] || { echo "ERR qmd-staleness: --qmd-bin needs a non-empty path." >&2; exit 1; }
            QMD_BIN="$2"; shift 2 ;;
        --qmd-js)
            [ $# -ge 2 ] || { echo "ERR qmd-staleness: --qmd-js needs a value." >&2; exit 1; }
            [ -n "$2" ] || { echo "ERR qmd-staleness: --qmd-js needs a non-empty path." >&2; exit 1; }
            QMD_JS="$2"; shift 2 ;;
        --require-collections)
            [ $# -ge 2 ] || { echo "ERR qmd-staleness: --require-collections needs a value." >&2; exit 1; }
            [ -n "$2" ] || { echo "ERR qmd-staleness: --require-collections needs a non-empty list." >&2; exit 1; }
            REQUIRE_COLLECTIONS="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERR qmd-staleness: unknown argument '$1'." >&2; usage >&2; exit 1 ;;
    esac
done

# A non-numeric or negative budget is a usage error, not a silently-defaulted
# one: a caller that passed --max-age-hours meant to set a budget, and quietly
# substituting 36 would enforce a threshold they did not choose.
case "$MAX_AGE_HOURS" in
    ''|*[!0-9]*)
        echo "ERR qmd-staleness: --max-age-hours must be a non-negative integer (got '$MAX_AGE_HOURS')." >&2
        exit 1 ;;
esac

# Same discipline for the required-collection set, and for the same reason: a
# list this parser cannot read is a list it cannot ENFORCE, and quietly dropping
# an unreadable entry would leave the operator believing a collection is being
# checked when it is not. An empty entry (a stray or trailing comma) is exactly
# that shape, so it is a usage error rather than a silent skip.
if [ -n "$REQUIRE_COLLECTIONS" ]; then
    case "$REQUIRE_COLLECTIONS" in
        ,*|*,|*,,*|*[!A-Za-z0-9._,-]*)
            {
                echo "ERR qmd-staleness: --require-collections must be a comma-separated list of"
                echo "    collection names ([A-Za-z0-9._-]), with no empty entries (got '$REQUIRE_COLLECTIONS')."
            } >&2
            exit 1 ;;
    esac
fi

# Resolve qmd through the SHARED resolver, never a bare `command -v qmd`
# (HIMMEL-1283): on Git Bash inside a Claude Code session the bare lookup finds
# the broken plugin-cache stub that shadows the bun shim, and every call then
# dies with `Module not found ".../dist/cli/qmd.js"`.
# shellcheck source=../lib/qmd-bin.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/qmd-bin.sh"

# --qmd-js is the SCRIPT ARG for --qmd-bin, meaningless without it — and worse
# than meaningless if allowed through: the resolution below OVERWRITES QMD_JS
# with whatever the resolver returns (or blanks it), so a caller who passed
# --qmd-js alone would have it silently discarded and the guard would run a
# different qmd than the one they named. Same "a flag that was passed must never
# be a no-op" rule the empty-operand checks enforce, and the same usage error
# qmd-reindex.sh raises for this combination.
if [ -n "$QMD_JS" ] && [ -z "$QMD_BIN" ]; then
    echo "ERR qmd-staleness: --qmd-js requires --qmd-bin (the invocation is '<qmd-bin> <qmd-js> …')" >&2
    exit 1
fi

if [ -z "$QMD_BIN" ]; then
    _resolved=""
    if ! _resolved=$(qmd_pinned_invocation 2>/dev/null); then
        {
            echo "ERR qmd-staleness: no usable qmd found and --qmd-bin was not given."
            echo "    Install qmd, or pass the absolute path: --qmd-bin /path/to/qmd"
        } >&2
        exit 2
    fi
    QMD_BIN=$(printf '%s\n' "$_resolved" | sed -n '1p')
    QMD_JS=$(printf '%s\n' "$_resolved" | sed -n '2p')
    unset _resolved
fi

# "qmd is not on this station" and "qmd is here but broken" must not share an
# exit code — the caller's reaction to them is opposite (silence vs alarm), and
# with both on rc 2 the hook's deliberate silence for adopters without qmd also
# silenced a corrupt index, a locked sqlite file, and a wedged process. So the
# NOT-USABLE cases are established HERE, before any invocation: an absent or
# non-executable path is rc 2, and everything past this point is a real qmd that
# failed to answer (rc 7). Same discipline as qmd-reindex.sh, which rejects a
# non-executable --qmd-bin for the same reason.
if [ ! -f "$QMD_BIN" ] || [ ! -x "$QMD_BIN" ]; then
    {
        echo "ERR qmd-staleness: qmd path '$QMD_BIN' is not an executable file."
        echo "    Install qmd, or pass the absolute path: --qmd-bin /path/to/qmd"
    } >&2
    exit 2
fi
if [ -n "$QMD_JS" ] && [ ! -f "$QMD_JS" ]; then
    echo "ERR qmd-staleness: --qmd-js path '$QMD_JS' is not a file." >&2
    exit 2
fi

run_qmd() {
    if [ -n "$QMD_JS" ]; then
        "$QMD_BIN" "$QMD_JS" "$@"
    else
        "$QMD_BIN" "$@"
    fi
}

STATUS_OUT=""
QMD_RC=0
STATUS_OUT=$(run_qmd status 2>/dev/null) || QMD_RC=$?
if [ "$QMD_RC" -ne 0 ]; then
    {
        echo "ERR qmd-staleness: '$(qmd_bin_desc) status' failed (exit $QMD_RC) — cannot assess the index."
        echo "    qmd IS installed here, so this is not an absent-tool case: the index may be"
        echo "    corrupt or locked, or a qmd process may be wedged."
        echo "    Treat the index as UNVERIFIED until this is resolved (HIMMEL-1286)."
    } >&2
    exit 7
fi

# --- parse the Documents block ---------------------------------------------
# Anchored on `^<space>Field:` so the per-collection "(updated 1d ago)" suffixes
# further down the report — lowercase, inline, parenthesised — cannot be
# mistaken for the top-level Updated: line.
# SCOPED TO THE Documents BLOCK, not the whole report. A report-wide search
# reads any same-named field from an unrelated section: if a future qmd grows
# e.g. a `Models` block with its own `Updated:` while the Documents block loses
# one, an unscoped lookup silently returns THAT value and reports a verdict
# instead of failing closed on rc 6 — the one outcome this parser must never
# produce. The block ends at the next unindented (top-level) heading.
# HERE-STRING, not `printf … | awk`. This awk calls `exit` on the first match,
# which closes its stdin early and SIGPIPEs the producer; under the
# `set -o pipefail` in force here that surfaces as pipeline status 141, and
# because the caller writes `TOTAL_RAW=$(field 'Total')`, `set -e` would then
# ABORT the guard outright — a parser that dies rather than reports. The report
# is ~1KB so it fits the pipe buffer and this never fires today, but it is the
# same latent HIMMEL-1115 trap age_hours() was just rewritten to avoid, and a
# standard the codebase applies to itself unevenly is one that stops being
# applied. A here-string has no pipeline to fail.
field() {
    awk -v key="$1" '
        /^[^[:space:]]/ { inblk = ($0 ~ /^Documents([[:space:]]|$)/) ? 1 : 0; next }
        inblk && $0 ~ ("^[[:space:]]+" key ":") {
            sub("^[[:space:]]*" key ":[[:space:]]*", "")
            print; exit
        }' <<<"$STATUS_OUT"
}

TOTAL_RAW=$(field 'Total')
VECTORS_RAW=$(field 'Vectors')
UPDATED_RAW=$(field 'Updated')
PENDING_RAW=$(field 'Pending')

# Fail CLOSED. Total/Vectors/Updated are the block's required fields; if any is
# missing the report is not the one this parser understands, and the honest
# answer is "I cannot read this", not "looks fine".
if [ -z "$TOTAL_RAW" ] || [ -z "$VECTORS_RAW" ] || [ -z "$UPDATED_RAW" ]; then
    {
        echo "ERR qmd-staleness: could not read the Documents block of 'qmd status'."
        echo "    Expected Total:/Vectors:/Updated: lines; qmd may have reworded its output."
        echo "    Treat the index as UNVERIFIED until this parser is updated (HIMMEL-1286)."
    } >&2
    exit 6
fi

# --- age -> hours -----------------------------------------------------------
# Accepts the relative forms qmd emits: "just now", "45m ago", "2h ago",
# "1d ago", "3w ago". Anything else is a parse failure, not a zero.
age_hours() {
    local raw="$1" num unit
    # EXACT match, not a substring. `*"just now"*` accepted any string that
    # merely CONTAINED the phrase, so a reworded field like "unexpected just now
    # garbage" was converted to 0 hours and reported a confident all-clear —
    # measured. That is the one outcome this parser exists to prevent, and it
    # was the single branch that skipped the strict `<n><unit> ago` validation
    # every other form must pass. Format drift now fails closed here too.
    case "$raw" in
        'just now') echo 0; return 0 ;;
    esac
    # Validate the WHOLE string before converting anything. The old form picked
    # the first number found ANYWHERE and the first alpha run after it, so
    # unexpected surrounding text could still yield a confident number. Demand
    # the exact `<n><unit> ago` shape and reject everything else, so anything
    # this parser was not written against fails closed (rc 6) instead of being
    # partially understood.
    # Native bash regex, NOT `printf … | grep -Eq`. Under the `set -o pipefail`
    # in force here, a matching grep -q exits early, the producer takes SIGPIPE,
    # and the PIPELINE reports 141 — so a successful match can read as a
    # failure, which in this function means a perfectly readable age is rejected
    # and the guard exits 6. Today's inputs are short enough to fit the pipe
    # buffer, so it is latent rather than live; it is still the exact
    # HIMMEL-1115 trap the sibling suites carry warnings about, sitting in the
    # one function whose job is to not misread the age. The pattern goes in a
    # variable because bash 3.2 (macOS) treats a QUOTED =~ operand as a literal.
    local age_re='^[0-9]+[[:space:]]*[a-zA-Z]+[[:space:]]+ago$'
    [[ $raw =~ $age_re ]] || return 1
    num=$(expr "$raw" : '[^0-9]*\([0-9][0-9]*\)' 2>/dev/null || true)
    # Capture the WHOLE alphabetic run, not one letter. A single-letter capture
    # read "1mo ago" as unit `m` = MINUTES -> 1/60 -> 0 hours -> "fresh", so a
    # months-old index passed as healthy AND skipped the fail-closed rc 6 path,
    # because `m` is a recognised unit. That is the worst outcome this guard can
    # produce: silence on exactly the staleness it exists to catch.
    unit=$(expr "$raw" : '[^0-9]*[0-9][0-9]*[[:space:]]*\([a-zA-Z][a-zA-Z]*\)' 2>/dev/null || true)
    [ -n "$num" ] && [ -n "$unit" ] || return 1
    # Force base 10 BEFORE any arithmetic. `$(( 09 * 24 ))` is an octal literal
    # to bash and dies with "value too great for base", which took the
    # multiplying units (d/w/mo/y) down on any zero-padded age: measured, `09d
    # ago` printed a raw bash error to stderr and then reported "could not parse
    # the index age" — a misdiagnosis, since the age parsed fine and it was the
    # ARITHMETIC that failed. It failed closed (rc 6), so nothing was ever
    # certified fresh on this path, but a guard whose diagnostics point at the
    # wrong thing costs whoever reads them. Same octal class already seen in
    # this repo on critic-panel.sh. `h` never hit it because that branch echoes
    # the digits instead of multiplying them.
    num=$((10#$num))
    # Exact matches only. An unrecognised unit returns 1 -> rc 6 ("I cannot read
    # this") rather than being coerced into the nearest branch — an unknown unit
    # is not evidence of freshness.
    #
    # UNITS COARSER THAN AN HOUR RESOLVE TO THEIR UPPER BOUND, NOT THEIR FLOOR.
    # qmd's formatter FLOORS (src/cli/qmd.ts formatTimeAgo:
    # `days = Math.floor(hours / 24)`), so "1d ago" denotes the whole interval
    # [24h, 48h) — an index aged 47h59m prints exactly the same string as one
    # aged 24h01m. Reading that as 24 made the default 36h budget behave like a
    # ~48h one: a two-day-old index reported FRESH, silently, which is the
    # precise failure class this guard exists to catch. So a floored label is
    # certified only when its WORST case fits the budget. `Nd` -> N*24+23 is
    # that worst case (the largest whole-hour age the label can represent).
    #
    # Hours are deliberately NOT widened. qmd floors there too, so "36h" really
    # means [36h, 37h) — but the budget is itself expressed in whole hours, so
    # that slop is the comparison's own granularity rather than a lost order of
    # magnitude, and widening it would make `--max-age-hours 36` trip on an
    # index reported at exactly 36h. Seconds and minutes floor to 0 hours and
    # cannot mask anything a whole-hour budget could catch.
    case "$unit" in
        s|S|sec|secs|second|seconds)            echo 0 ;;
        m|M|min|mins|minute|minutes)            echo $(( num / 60 )) ;;
        h|H|hr|hrs|hour|hours)                  echo "$num" ;;
        d|D|day|days)                           echo $(( num * 24 + 23 )) ;;
        w|W|wk|wks|week|weeks)                  echo $(( num * 168 + 167 )) ;;
        mo|MO|Mo|month|months)                  echo $(( num * 720 + 719 )) ;;
        y|Y|yr|yrs|year|years)                  echo $(( num * 8760 + 8759 )) ;;
        *) return 1 ;;
    esac
}

AGE_HOURS=""
if ! AGE_HOURS=$(age_hours "$UPDATED_RAW"); then
    {
        echo "ERR qmd-staleness: could not parse the index age from 'Updated: $UPDATED_RAW'."
        echo "    Treat the index as UNVERIFIED until this parser is updated (HIMMEL-1286)."
    } >&2
    exit 6
fi

# --- pending ----------------------------------------------------------------
# ABSENCE means zero — but only now, after the block above was positively
# identified. A `Pending:` line that IS present and yet carries no leading
# integer is a rewording, and gets the same fail-closed treatment as the rest.
PENDING=0
if [ -n "$PENDING_RAW" ]; then
    PENDING=$(expr "$PENDING_RAW" : '[[:space:]]*\([0-9][0-9]*\)' 2>/dev/null || true)
    if [ -z "$PENDING" ]; then
        {
            echo "ERR qmd-staleness: could not parse the pending count from 'Pending: $PENDING_RAW'."
            echo "    Treat the index as UNVERIFIED until this parser is updated (HIMMEL-1286)."
        } >&2
        exit 6
    fi
fi

# --- required collections ---------------------------------------------------
# OPT-IN, because the required set is a per-station policy this script cannot
# infer: the host carries himmel+luna+salus, win2 deliberately carries no salus
# at all, and an adopter carries whatever they registered. Absent the flag,
# nothing here runs.
#
# WHY IT EXISTS: freshness and completeness are properties of the documents that
# ARE indexed, so a station missing an ENTIRE collection scores perfectly on
# both — which is precisely the shape measured on win2 (index fresh, `salus`
# absent outright). Without this check the guard returned rc 0 for the incident
# its own header cites, i.e. it promised more than it delivered.
#
# The rows are anchored on the `<name> (qmd://<name>/)` shape inside the
# Collections block, the same block-scoped discipline field() uses. A required
# set that cannot be checked FAILS CLOSED on rc 6: "I could not see the
# collection list" is not "the collection is there".
# Here-string for the same reason as field() above. This awk has no early
# `exit` so it cannot SIGPIPE today, but the two readers of $STATUS_OUT should
# not differ in a way a later edit has to rediscover — adding an `exit` here
# would silently reintroduce the abort.
collections() {
    awk '
        /^[^[:space:]]/ { inblk = ($0 ~ /^Collections([[:space:]]|$)/) ? 1 : 0; next }
        inblk && $0 ~ /^[[:space:]]+[A-Za-z0-9._-]+[[:space:]]+\(qmd:\/\// {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+\(qmd:.*$/, "", line)
            print line
        }' <<<"$STATUS_OUT"
}

MISSING_COLLECTIONS=""
if [ -n "$REQUIRE_COLLECTIONS" ]; then
    FOUND_COLLECTIONS=$(collections)
    if [ -z "$FOUND_COLLECTIONS" ]; then
        {
            echo "ERR qmd-staleness: --require-collections was given but no Collections block"
            echo "    could be read from 'qmd status'; qmd may have reworded its output."
            echo "    Treat the index as UNVERIFIED until this parser is updated (HIMMEL-1286)."
        } >&2
        exit 6
    fi
    while IFS= read -r _want; do
        [ -n "$_want" ] || continue
        # Here-string, not `printf | grep -q`: under pipefail an early-exiting
        # grep -q SIGPIPEs the producer and the whole pipeline reads as a MISS,
        # which here would invent an absent collection (HIMMEL-1115).
        if ! grep -qxF -- "$_want" <<<"$FOUND_COLLECTIONS"; then
            MISSING_COLLECTIONS="${MISSING_COLLECTIONS:+$MISSING_COLLECTIONS, }$_want"
        fi
    done <<EOF
$(printf '%s' "$REQUIRE_COLLECTIONS" | tr ',' '\n')
EOF
    unset _want
fi

# --- verdict ----------------------------------------------------------------
# Explicit `if` rather than `[ … ] && VAR=1` throughout the verdict section: under
# `set -e` a bare AND-list whose test fails is the classic errexit leak, and the
# failure mode here would be the worst possible one — the guard exiting 1 instead
# of printing its warning.
STALE=0
if [ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]; then STALE=1; fi
INCOMPLETE=0
if [ "$PENDING" -gt 0 ]; then INCOMPLETE=1; fi
MISSING=0
if [ -n "$MISSING_COLLECTIONS" ]; then MISSING=1; fi

if [ "$STALE" -eq 0 ] && [ "$INCOMPLETE" -eq 0 ] && [ "$MISSING" -eq 0 ]; then
    # "newest doc edited ${UPDATED_RAW}" rather than "index fresh (${UPDATED_RAW})":
    # the all-clear must not assert more than the banner does. Within budget is
    # the strongest honest statement this field supports.
    [ "$QUIET" -eq 1 ] || echo "OK qmd-staleness: newest indexed doc edited ${UPDATED_RAW} (within ${MAX_AGE_HOURS}h), complete (${TOTAL_RAW}, ${VECTORS_RAW})."
    exit 0
fi

# The notice goes to STDERR and is banner-framed on purpose: its whole reason to
# exist is being impossible to scroll past in a session transcript.
{
    echo "=============================================================================="
    if [ "$STALE" -eq 1 ] && [ "$INCOMPLETE" -eq 1 ]; then
        echo "  qmd index may be STALE (${UPDATED_RAW}) and IS INCOMPLETE (${PENDING} chunks pending)"
    elif [ "$STALE" -eq 1 ]; then
        echo "  qmd index may be STALE — budget ${MAX_AGE_HOURS}h"
    elif [ "$INCOMPLETE" -eq 1 ]; then
        echo "  qmd index is INCOMPLETE — ${PENDING} chunks still need embedding"
    fi
    # Named on its OWN line, never folded into the stale/incomplete sentence: a
    # missing collection is a different failure with a different fix (register
    # and ship it), and it is the one condition a fresh, complete index still
    # hides.
    if [ "$MISSING" -eq 1 ]; then
        echo "  qmd is MISSING required collection(s): ${MISSING_COLLECTIONS}"
    fi
    echo
    if [ "$MISSING" -eq 1 ]; then
        echo "  Those collections are NOT SEARCHABLE here at all — a miss against them"
        echo "  is meaningless, not an absence. Register them (qmd collection add) on"
        echo "  this station, then have the host ship an index that covers them."
    fi
    if [ "$STALE" -eq 1 ]; then
        # State the OBSERVATION and both of its readings. `Updated:` is
        # MAX(source-file mtime) over indexed documents, so this number cannot
        # tell "the index stopped updating" from "nobody edited anything" — and
        # a banner that asserts the first every time the second is true is a
        # banner the reader stops seeing (HIMMEL-1307 tracks the durable
        # refresh/receipt stamp that would settle it).
        echo "  The newest document this index knows about was edited ${UPDATED_RAW}."
        echo "  That means EITHER the index stopped being refreshed, OR the corpus"
        echo "  has simply been quiet. qmd cannot distinguish the two: the figure is"
        echo "  MAX(source-file mtime) over indexed docs, not a refresh timestamp."
        echo
        echo "  Until you know which, treat qmd MISSES AS UNPROVEN: a miss is only"
        echo "  evidence of absence when the index is current, and that is unproven."
    fi
    if [ "$INCOMPLETE" -eq 1 ]; then
        echo "  Semantic (vec) search is DEGRADED for the pending chunks; lexical"
        echo "  (lex) search over them still works."
    fi
    echo
    echo "  Do NOT reindex on a receiving station — it embeds ~50x slower than the"
    echo "  host. The host publishes: scripts/luna/qmd-reindex.sh then"
    echo "  scripts/luna/ship-index.sh (HIMMEL-1286)."
    echo "=============================================================================="
} >&2

# A missing collection outranks stale/incomplete: those degrade an index that
# still covers the corpus, this one means part of the corpus is not there at
# all. The banner above already named every condition, so nothing is lost by
# the single-value exit code reporting the most severe.
if [ "$MISSING" -eq 1 ]; then exit 8; fi
if [ "$STALE" -eq 1 ] && [ "$INCOMPLETE" -eq 1 ]; then exit 5; fi
if [ "$STALE" -eq 1 ]; then exit 3; fi
exit 4
