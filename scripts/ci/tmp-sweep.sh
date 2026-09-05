#!/usr/bin/env bash
# tmp-sweep.sh — sweep himmel's own leftover fixture trees out of %TEMP%.
#
# WHY (HIMMEL-1978). Git-Bash /tmp on the OVERLORD8 suite box reached ~149,600
# top-level entries; `ls /tmp | wc -l` alone took >120s and every suite that
# calls mktemp paid for it. The litter is ours: suites and probes that crashed
# or were killed by run-shell-tests.sh's watchdog never ran their cleanup, and
# a reboot does NOT clear %TEMP% on Windows.
#
# DRY-RUN BY DEFAULT. `--apply` is the only thing that deletes.
#
# WHAT IT TOUCHES. Only TOP-LEVEL entries of the temp root whose name starts
# with one of the PREFIXES below, and only entries older than --older-than
# hours (default 6 — comfortably longer than the slowest suite). Symlinks are
# never followed and never removed. Nothing outside the temp root is reachable:
# the root must itself look like a temp dir (see the guard below).
#
# THE PREFIX LIST IS DERIVED, NOT GUESSED. Every entry traces to a mktemp /
# mkdtempSync template in this repo. Re-derive it after adding a new fixture
# family with:
#
#   grep -rhoE "mkdtempSync\(join\([A-Za-z_.()]+, *[\"'][^\"']+[\"']" scripts/ \
#     | grep -oE "[\"'][^\"']+[\"']$" | tr -d "\"'" | sort -u
#   grep -rn mktemp scripts/ --include=*.sh --include=*.ps1
#
# and cross-check against what is actually accumulating:
#
#   find "$TMPDIR" -maxdepth 1 -printf '%f\n' | sed -E 's/^([A-Za-z][A-Za-z0-9]*).*/\1/' \
#     | sort | uniq -c | sort -rn | head -40
#
# Deliberately NOT listed (they are on the box in volume but are not ours):
# pip-*, dd_setup_*, scoped_dir*, vscode-*, chrome_url_fetcher_*,
# msedge_url_fetcher_*, and bare session scratch (h1077-, leg4-, panel-) that
# no script in this repo creates.
#
# Usage:
#   bash scripts/ci/tmp-sweep.sh [--apply] [--older-than <hours>] [--root <dir>]
#                                [--bytes] [--include-bare-mktemp]
#
# Exit codes:
#   0 — swept (or reported, in dry-run)
#   2 — usage error, or the temp root does not look like a temp dir
#   3 — --apply ran but left matched entries behind (deletion shortfall; the
#       count of survivors is on stderr). Dry-run never returns this.
set -uo pipefail

APPLY=0
BYTES=0
BARE_MKTEMP=0
HOURS=6
ROOT=""

# usage [rc] — rc defaults to 2 (a usage ERROR). `--help` passes 0: asking for
# help is not a failure, and a non-zero --help breaks any caller that checks.
usage() {
    cat >&2 <<'EOF'
Usage: tmp-sweep.sh [--apply] [--older-than <hours>] [--root <dir>] [--bytes]

  --apply              delete the matched entries (default: report only)
  --older-than <h>     age floor in hours, positive integer (default: 6)
  --root <dir>         temp root to sweep (default: $TMPDIR, $TEMP, or /tmp)
  --bytes              also report reclaimable size (slow: walks every match)
  --include-bare-mktemp
                       also sweep bare `tmp.XXXXXX` entries. These come from
                       coreutils mktemp's DEFAULT template, so they are not
                       exclusively ours — opt in only on a box whose temp root
                       you own.
EOF
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --bytes) BYTES=1; shift ;;
        --include-bare-mktemp) BARE_MKTEMP=1; shift ;;
        --older-than) [ $# -ge 2 ] || usage; HOURS="$2"; shift 2 ;;
        --root) [ $# -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "tmp-sweep: unknown argument: $1" >&2; usage ;;
    esac
done

case "$HOURS" in
    ''|*[!0-9]*) echo "tmp-sweep: --older-than must be a positive integer, got: $HOURS" >&2; usage ;;
esac
[ "$HOURS" -ge 1 ] || { echo "tmp-sweep: --older-than must be >= 1" >&2; usage; }

[ -n "$ROOT" ] || ROOT="${TMPDIR:-${TEMP:-/tmp}}"
ROOT="${ROOT%/}"
[ -d "$ROOT" ] || { echo "tmp-sweep: not a directory: $ROOT" >&2; exit 2; }

# Resolve to a PHYSICAL path FIRST, then check WHERE it is. Checking the
# argument as given let `/tmp/../home/user` satisfy the guard (it contains
# "tmp") while pointing anywhere on the disk. `pwd -P` also resolves symlinked
# components, so a symlink under /var/tmp pointing at / cannot smuggle a root
# through.
ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P) \
    || { echo "tmp-sweep: cannot resolve root: $ROOT" >&2; exit 2; }
ROOT="${ROOT%/}"

# The root must BE, or live under, a real temp root of this machine. A plain
# "does the path contain tmp/temp" test was the first version and it is not a
# guard at all: `$HOME/templates` passes it, and macOS's own TMPDIR
# (/var/folders/.../T) fails it. Anchoring on the resolved temp roots is both
# stricter and more portable. The whole script is one `rm -rf` behind a glob,
# so this is checked before any listing happens.
_root_ok=0
for _cand in "${TMPDIR:-}" "${TEMP:-}" "${TMP:-}" /tmp /var/tmp; do
    [ -n "$_cand" ] || continue
    _c=$(cd "$_cand" 2>/dev/null && pwd -P) || continue
    _c="${_c%/}"
    # A candidate of "/" strips to the empty string, and the "$_c"/* pattern
    # below would then read as /* and accept every absolute path on the disk.
    # A temp root of / is not a configuration worth supporting; drop it.
    [ -n "$_c" ] || continue
    case "$ROOT" in "$_c"|"$_c"/*) _root_ok=1; break ;; esac
done
if [ "$_root_ok" -ne 1 ]; then
    echo "tmp-sweep: refusing to sweep \"$ROOT\" — not under this machine's temp root (\$TMPDIR/\$TEMP/\$TMP, /tmp, /var/tmp)" >&2
    exit 2
fi

# Every entry is a LITERAL name prefix; the script appends the `*`. Keep them
# sorted, one per line, and ALWAYS end an entry with its separator (`-` or
# `.`): a bare family like `cx` or `himmel` would also match a third-party
# `cxfoo`, and this allow-list is the only thing standing between `--apply`
# and someone else's temp files.
#
# Each entry is a COMPLETE template prefix — the whole fixed part of a real
# `mktemp` / `mkdtempSync` call in this repo, up to its `XXXXXX`. Family stems
# are not good enough: `codex-` is also what the Codex CLI itself writes, and
# `qmd-` / `graphify-` / `telegram-` belong to tools that ship their own temp
# files. Where several templates share a longer fixed part (`lane-bank-*`,
# `luna-vitals-*`) the shared part is itself a template, so it folds; where it
# is not (`qmd-staleness-notice.` vs `qmd-staleness.`) both are listed.
#
# One entry deliberately ends WITHOUT a separator, because its writer does not
# use one: `graphify-refresh-lock` is followed by a bare lock index.
#
# HIMMEL-1995 finished the narrowing the r5 pass left half-done. The remaining
# family stems (`bench-`, `critic-`, `critics-`, `fleet-`, `graphmap-`,
# `lanes-`, `pp-`) are gone, replaced by the templates their writers actually
# use. Where one writer family has many near-identical templates
# (`bench-run-batch-abort-*`, `bench-run-batch-retry-*`, …) the shared fixed
# part is listed once, the same fold `lane-bank-` already uses. Three entries
# were DELETED rather than narrowed:
#   `lc-`      — no mktemp/mkdtempSync in this repo produces it. Not ours.
#   `ast-` / `bus-` — those WERE the complete templates (scripts/telegram
#     armed-session-track/bus tests), i.e. two-to-three letters no other program
#     is obliged to avoid. Narrowing them means renaming at the writer, which is
#     what happened: they now write `telegram-ast-` / `telegram-bus-`.
# `graphmap-` collapses to `graphmap-cadence.` alone: the `graphmap-{ast-,}
# {himmel,luna}.{bat,vbs}.` templates are written to ~/.claude/graphmap-cadence
# with a leading dot, never into the temp root.
PREFIXES='
att-
bench-aggregate-cli-
bench-bank-breach-
bench-bank-snapshot-cli-
bench-dispatch-luna-
bench-materialize-
bench-report-cli-
bench-run-batch-
bench-run-manifest-
bench-verify-common-
bridgecfg-
capguard-
cfp-
codex-bank-cache-cli-
codex-bank-probe-ok-
codex-bank-probe-to-
codex-sweep-cadence.
cr-available-test.
cr-floor-
cr-floored-repo-
cr-no-floor-
cr-panel-avail.
critic-err.
critic-pack.
critic-panel-
critic-panel.
critic-test.
critics-merged.
cx-
cxc-
cxshared-
fleet-barehome-
fleet-codex-
fleet-degrade-
fleet-doc-
fleet-esc-
fleet-events-
fleet-glm-
fleet-hermes-
fleet-home-
fleet-ledger-
fleet-page-
gblock-
glm-
glmgit-
glmmain-
glmmain2-
glmshared-
graphify-bin.
graphify-bin-sete.
graphify-refresh-lock
graphify-seed-config.
graphmap-cadence.
gskip-
himmel-
himmelctl-
jira-attach-
jira-nudge-payload.
lane-bank-
lane-output-
lanes-bin-
lanes-ctx-
lanes-dormant-
lanes-empty-
lanes-hermes-
lanes-malformed-
lanes-profile-
lanes-repo-
lanes-shim-
luna-brain-sweep-
luna-ingest-
luna-sync-alert-
luna-upgrade-vm-out.
luna-vitals-
new-worktree-
pipeline-cadence.
poller-
pp-altcfg-
pp-cli-bare-cwd-
pp-cli-bare-home-
pp-cli-cwd-
pp-cli-home-
pp-cwd-
pp-cwd2-
pp-home-
pp-home2-
pp-home3-
pp-home4-
pp-reg-
pp-root-
pull-cadence-
qmd-cadence-test.
qmd-cadence.
qmd-ship.
qmd-staleness.
qmd-staleness-notice.
qmd-staleness-test.
quiet-run-
spawn-bad-
spawn-claudex-test-trust-
spawn-glm-test-trust-
spawn-proj-
telegram-ast-
telegram-bus-
telegram-notification-payload.
telegram-session-end-payload.
tg-dl-
tv-test-
waw-
'

# OPT-IN, and separate from the list above on purpose. `tmp.` is coreutils
# `mktemp`'s DEFAULT template, so it is the one prefix here that any program on
# the box can produce — 15,588 of the 125,839 entries the first sweep matched.
# HIMMEL-1978 asks for it, but a top-level mtime older than the floor does not
# prove a tree is unused (a long-running program can hold a stale-looking dir
# open), and the rest of the list carries no such doubt. So the default sweep
# stays strictly-ours and this is an explicit operator choice.
if [ "$BARE_MKTEMP" -eq 1 ]; then
    PREFIXES="$PREFIXES
tmp."
fi

MINS=$(( HOURS * 60 ))

# One pass, not one per prefix: a 149k-entry directory scan is the expensive
# part, and 40 of them would cost more than everything the sweep saves.
# `! -type l` keeps symlinks out of the match set entirely (find without -L
# does not follow them either, so neither the link nor its target is reached).
find_args=""
set --
for p in $PREFIXES; do
    if [ -z "$find_args" ]; then
        set -- -name "$p*"
        find_args=x
    else
        set -- "$@" -o -name "$p*"
    fi
done

WORK=$(mktemp -d) || { echo "tmp-sweep: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
LIST="$WORK/matches"

# `wc -l` pads its count on some platforms; every consumer below is an integer
# comparison, so strip before assigning rather than at each use.
count_lines() { wc -l < "$1" | tr -d '[:space:]'; }

find "$ROOT" -maxdepth 1 -mindepth 1 -print > "$WORK/all" 2>/dev/null
before=$(count_lines "$WORK/all")
find "$ROOT" -maxdepth 1 -mindepth 1 ! -type l -mmin +"$MINS" \
    \( "$@" \) -print > "$LIST" 2>/dev/null
matched=$(count_lines "$LIST")

echo "tmp-sweep: root=$ROOT older-than=${HOURS}h mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run)"
echo "tmp-sweep: top-level entries before: $before"
echo "tmp-sweep: matched (ours, older than ${HOURS}h): $matched"

if [ "$matched" -gt 0 ]; then
    echo "tmp-sweep: per-prefix counts"
    # Bucket the match list against the same literal prefixes, in ONE awk pass.
    printf '%s\n' "$PREFIXES" | sed '/^[[:space:]]*$/d' > "$WORK/prefixes"
    awk '
      NR == FNR { pfx[++n] = $0; next }
      {
        name = $0
        sub(".*/", "", name)
        for (i = 1; i <= n; i++)
          if (substr(name, 1, length(pfx[i])) == pfx[i]) { c[pfx[i]]++; next }
        c["(other)"]++
      }
      END { for (k in c) printf "  %8d  %s\n", c[k], k }
    ' "$WORK/prefixes" "$LIST" | sort -rn

    # OPT-IN, because du has to recursively stat every matched tree: measured
    # 17m09s against 125,839 matches on the box this ticket came from, versus
    # 20s for the counts above. A sweep you won't wait for doesn't get
    # run, and the entry COUNT is what the suite-box symptom tracks anyway
    # (mktemp cost scales with directory entries, not with bytes).
    # -k for portability: GNU du's -b / --block-size are not on BSD/macOS du.
    # No `xargs -r` here: this branch is already inside `matched -gt 0`, and -r
    # is a GNU extension that BSD/macOS xargs rejects outright. This path DOES
    # rebuild paths from the newline-delimited list, unlike the delete path —
    # harmless, because the worst a filename containing a newline can do here
    # is make `du` stat the wrong path and skew a report-only number.
    if [ "$BYTES" -eq 1 ]; then
        kb=$(tr '\n' '\0' < "$LIST" | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')
        echo "tmp-sweep: reclaimable: ${kb} KB"
    else
        echo "tmp-sweep: reclaimable bytes not computed (--bytes; slow, walks every matched tree)"
    fi
fi

if [ "$APPLY" -ne 1 ]; then
    echo "tmp-sweep: dry-run — nothing deleted (re-run with --apply)"
    exit 0
fi

# Delete from a SECOND find with -exec, not by re-reading $LIST. The list is
# newline-delimited, and a filename containing a newline would split into two
# paths on the way back out — one of which need not be under $ROOT at all.
# Handing find the same predicate keeps every path find's own, so no filename
# is ever parsed. (It costs one extra directory scan; the residual is that an
# entry can cross the age boundary between the two scans, which only ever adds
# an entry that was already older than the floor a moment ago.)
if [ "$matched" -gt 0 ]; then
    find "$ROOT" -maxdepth 1 -mindepth 1 ! -type l -mmin +"$MINS" \
        \( "$@" \) -exec rm -rf {} + 2>/dev/null
fi
find "$ROOT" -maxdepth 1 -mindepth 1 -print > "$WORK/all" 2>/dev/null
after=$(count_lines "$WORK/all")
echo "tmp-sweep: top-level entries after: $after (removed $(( before - after )))"

# The delete above sends rm's errors to /dev/null (a locked or unreadable entry
# is normal on a shared box and must not abort the sweep), so the exit status
# has to come from the FILESYSTEM, not from rm. Re-run the same predicate: what
# still matches is what --apply failed to remove.
#
# Counting survivors, not `before - after`: on a live box other programs create
# and delete temp entries between the two listings, so the delta is not a
# deletion count.
#
# And the survivors are intersected with $LIST — the entries this run actually
# matched — rather than taken from the re-scan alone (panel r1 codex-3). A
# re-scan is not a subset of the first one: an entry sitting just under the age
# floor crosses it during the sweep, and `mv` into the temp root carries an old
# mtime with it. Either would report a shortfall this run did not cause, and
# could even count more survivors than were ever requested.
if [ "$matched" -gt 0 ]; then
    find "$ROOT" -maxdepth 1 -mindepth 1 ! -type l -mmin +"$MINS" \
        \( "$@" \) -print > "$WORK/left" 2>/dev/null
    grep -Fxf "$LIST" "$WORK/left" > "$WORK/survivors" 2>/dev/null
    leftover=$(count_lines "$WORK/survivors")
    if [ "$leftover" -gt 0 ]; then
        echo "tmp-sweep: shortfall — $leftover of $matched matched entries survived --apply (in use, or not ours to delete)" >&2
        exit 3
    fi
fi
exit 0
