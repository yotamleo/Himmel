#!/usr/bin/env bash
# graph-cadence.sh — the recurring refresh+publish leg for himmel's own
# graphify graph (HIMMEL-2095).
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight. This is plain
# POSIX bash, and stays that way on purpose -- graphmap-cadence.sh (the ONLY
# arm point for this leg) already owns the one place platform actually
# diverges: on Windows it wraps this script in a hidden wscript/.bat shim
# whose Exec Command is Git Bash's own bash.exe (same pattern its AST/
# semantic siblings use, see that file's emit_bat); on POSIX it's a bare
# cron entry. graph-cadence.sh itself is invoked identically either way --
# `bash graph-cadence.sh --corpus-root <path>` -- and every script it shells
# (ast-update.sh, graph-publish.sh, merge-on-green.sh) is the SAME bash
# already required on Windows via GitBash for every other cadence in this
# repo; there is no native-PowerShell leg here to twin against. A `.ps1`
# rewrite would duplicate this logic in a second language for a platform
# that already runs the bash original correctly.
#
# WHY: graphify-out/graph.json is heavily used (139/143 sessions on the day
# this was written) but nothing refreshed or published it on a schedule, so
# it silently rotted -- the shipped graph sat 36 commits behind origin/main.
# Because refreshing was lean-invoke only, the operator repeatedly regenerated
# it by hand and committed it STRAIGHT TO MAIN with a bare, ticketless subject
# (d05ef8ca "update graphify", 913073df ".", 378c21f9/310646da "graphify
# update") -- bypassing the worktree/PR workflow every OTHER change in this
# repo goes through. This script exists to remove the reason that happened:
# a deterministic, unattended runner that measures staleness, refreshes,
# publishes via a PR, and auto-merges it through the sanctioned chokepoint --
# so there is never again a reason to reach for a bare commit on main.
#
# SEQUENCE (every leg's outcome is recorded; see EXIT/LEDGER below):
#   1. git fetch origin (in the PRIMARY checkout -- safe: fetch only updates
#      remote-tracking refs, never the working tree or the checked-out
#      branch, so it cannot disturb a live agent session working there).
#   2. Read built_at_commit out of the SHIPPED graph.json (origin/main's
#      committed blob, via `git show`, not whatever happens to be on disk).
#   3. Measure staleness as `git rev-list --count <built_at_commit>..origin/
#      main` -- NOT `--merges`. himmel squash-merges every PR, so
#      `--count --merges` always returns 0 (there are no merge commits to
#      count) while the true distance is the real number (36, measured at
#      write time) -- getting this wrong makes the cadence never fire.
#   4. Below --threshold: action=skipped, ledger row, exit 0.
#   5. At/above threshold: run ast-update.sh (the free, AST-only structural
#      refresh) against a DEDICATED worktree -- never the primary checkout.
#   6. graph-publish.sh, invoked with cwd = that worktree, opens/refreshes
#      the publish PR.
#   7. merge-on-green.sh, same cwd, ARMAUTOMERGE=1, lands it. The machine-
#      generated PR class (HIMMEL-2278, see graph-publish.sh's PR body) gets
#      no CodeRabbit review -- this cadence must not wait for one; it doesn't.
#   8. One ledger row (this script's own JSONL, see LEDGER below) plus the
#      standard flow-run-ledger start/end pair every other cadence writes,
#      so cadence-audit/staleness tooling is not blind to this leg.
#
# WHY A DEDICATED WORKTREE, NOT THE PRIMARY CHECKOUT: graph-publish.sh runs
# `git checkout -B chore/graph-publish-<corpus> ...` in whatever repo it is
# invoked from, and ast-update.sh writes graphify-out/* (tracked files) into
# whatever CORPUS_ROOT it is given. Firing either against the primary
# checkout from cron would switch the branch of a repo live agent sessions
# are working in and leave its tracked graphify-out/ dirty -- exactly the
# temptation that produced the manual bare commits this ticket exists to
# stop. So every mutating leg operates inside a PERSISTENT worktree (see
# WORKTREE_DIR below), created on demand via `git worktree add` off the
# primary -- a worktree has its own HEAD/index and never touches the
# primary's checked-out branch or working tree, which is exactly the
# isolation this needs (proven by test 6 in test-graph-cadence.sh: primary
# branch + `git status --porcelain` are asserted byte-identical before/after
# a full run). NOT /tmp: a cleanup sweep reaping a live worktree registration
# out from under git's `.git/worktrees/<name>` bookkeeping leaves the primary
# checkout's `git worktree list` pointing at a hole, which then has to be
# `git worktree prune`d by hand. ~/.claude/graph-cadence/<corpus-slug> follows
# the same persistent-runner-home convention every sibling cadence in this
# repo already uses (graphmap-cadence.sh's ~/.claude/graphmap-cadence,
# ggs-cadence.sh's ~/.claude/graphify-cadence).
#
# WORKTREE DIRNAME MUST MATCH THE CORPUS SLUG: graph-publish.sh derives its
# PR branch name from `basename "$(git rev-parse --show-toplevel)")`, i.e.
# whatever directory it happens to be invoked from -- it has no
# --corpus-name flag. This script names the worktree
# ~/.claude/graph-cadence/<corpus-slug> (corpus-slug = the sanitized basename
# of CORPUS_ROOT, "himmel" today) FOR EXACTLY THIS REASON: so
# graph-publish.sh's own `basename "$repo_root")` resolves to the SAME slug
# this script predicts and passes to merge-on-green.sh as the PR selector.
# Naming the worktree anything else (e.g. a generic "himmel-worktree") would
# make graph-publish.sh open a PR against branch
# "chore/graph-publish-himmel-worktree", which merge-on-green.sh (told to
# look for "chore/graph-publish-himmel") would never find -- a silent no-op
# merge every single run. See PUBLISH_BRANCH below.
#
# CRON ENVIRONMENT (HIMMEL-2619 class): cron gives no login shell -- no PATH
# beyond a bare default, no HANDOVER_DIR, no tool dirs. Every external command
# this script needs is resolved explicitly near the top (PATH self-heal +
# `command -v` checks that fail LOUDLY, never silently), and HANDOVER_DIR
# comes from the primary checkout's .env via scripts/lib/load-dotenv.sh, the
# same source every other handover-writing script in this repo reads it from
# -- never hardcoded. Verified by test-graph-cadence.sh running the wrapper
# under `env -i`.
#
# NEVER A SILENT rc=0: every failure path sets ACTION=failed, writes both
# ledger rows with the real error text, and exits non-zero. Rc's are captured
# explicitly (this script does NOT `set -e`) so a later step can never mask
# an earlier one's failure -- mirroring scripts/graphify/ggs-cadence.sh's
# rc-preserving convention. One deliberate divergence from ggs-cadence.sh's
# "run every leg regardless, OR every rc together": THIS pipeline's three
# legs are not independent (graph-publish/merge-on-green have nothing to do
# if ast-update produced nothing new), so a failing ast-update SHORT-CIRCUITS
# the remaining legs rather than running them for no reason -- their rc's
# would carry no information ast-update's failure doesn't already give, and
# running graph-publish against a stale/failed refresh risks opening a PR
# with no real content. This is a considered adaptation, not an oversight;
# flagged in the ticket's implementation report as a decision a reviewer
# might reasonably want revisited.
#
# ACTION CLASSIFICATION (ledger `action` field; PR-B panel r2 codex-6: this
# block must stay in sync with step 8's actual rc classification -- it drifted
# once already, see that step's own comment for the full rc table):
#   skipped   -- below --threshold, OR the pipeline lock was held by a
#                concurrent run (skip-not-wait; see step 5a) -- nothing else
#                ran either way.
#   failed    -- a genuine error: fetch, the built_at_commit read, rev-list,
#                the worktree identity check, a sync (checkout/reset/clean)
#                failure, ast-update.sh, a graph-publish.sh exit outside
#                {0,5}, OR a merge-on-green.sh exit that is NOT a documented
#                time-resolving deferral (step 8: anything other than rc 14
#                or 15 -- e.g. a missing tool, an unwritable audit sink, a
#                misconfigured base/privacy binding).
#   refreshed -- ast-update.sh succeeded but graph-publish.sh found nothing
#                new to publish (exit 5) -- the local rebuild produced
#                byte-identical tracked output. Not a failure. ALSO this
#                action, permanently, post-HIMMEL-2705-step-1: origin/main no
#                longer tracks graphify-out/graph.json at all (retired from
#                the git tree), so there is nothing to compare a rebuild
#                against and nothing to publish -- the local, AST-only refresh
#                still runs every fire (see step 5's own comment), and steps
#                6-7 (publish/merge) cleanly no-op right after it succeeds.
#   published -- graph-publish.sh opened/refreshed the PR (exit 0) but
#                merge-on-green.sh did not land it this run, for a genuine,
#                TIME-RESOLVING reason ONLY (rc 14: check-ci gate not green;
#                rc 15: merge attempt failed/indeterminate, incl. a
#                --match-head-commit head-moved abort -- see step 8 and
#                merge-on-green.sh's own exit-code table). Not a failure;
#                the next scheduled run (or an operator) picks it up from
#                here. Any OTHER non-zero merge-on-green.sh rc is `failed`,
#                not `published`.
#   merged    -- the full pipeline landed: refreshed, published, merged.
#
# Usage:
#   graph-cadence.sh [--threshold N] [--corpus-root <path>]
#
# THRESHOLD DEFAULT = 15 commits behind. Justified against the measured
# numbers (HIMMEL-2095 brief): the shipped graph was 36 commits behind
# origin/main when this was written, with the operator refreshing by hand at
# irregular multi-day intervals. This cadence is armed at a 6-hour interval
# (graphmap-cadence.sh's HIMMEL-GraphPublish-Himmel task, HIMMEL-2095), i.e.
# up to 4 checks/day. A threshold of 3 (this repo's typical single-PR commit
# count) would open a publish PR on ALMOST EVERY run -- constant PR churn for
# a marginal freshness gain. 15 sits below half of today's measured 36-commit
# gap: it fires immediately at today's staleness, and in steady state bounds
# the graph's staleness to roughly "at most one busy day's worth of merged
# PRs" rather than the current unbounded, hand-triggered-only gap, while
# still going quiet on days with only a handful of merges (most of the 4
# daily checks skip). This is a starting point, not a measured optimum --
# retune with --threshold if the operator wants tighter or looser freshness.
#
# Environment (test seams — a real cadence run never sets any of these):
#   GRAPH_CADENCE_HIMMEL_ROOT     override the resolved primary checkout root.
#   GRAPH_CADENCE_WORKTREE_DIR    override the dedicated worktree path.
#   GRAPH_CADENCE_AST_UPDATE      override the ast-update.sh path.
#   GRAPH_CADENCE_GRAPH_PUBLISH   override the graph-publish.sh path.
#   GRAPH_CADENCE_MERGE_ON_GREEN  override the merge-on-green.sh path.
#   GRAPH_CADENCE_LEDGER_ROOT     override the handover-root resolution
#                                 entirely (bypasses handover_root_ensure AND
#                                 the HANDOVER_DIR-unset refusal below).
#   GRAPH_CADENCE_DOTENV_ROOT     override which dir's .env is read for
#                                 HANDOVER_DIR. Honoured ONLY alongside
#                                 GRAPH_CADENCE_HIMMEL_ROOT (never set in a
#                                 real cadence run) -- lets a hermetic test
#                                 assert the HANDOVER_DIR-unset refusal
#                                 without depending on this checkout's own
#                                 .env happening to be absent.
#   GRAPH_CADENCE_BYPASS_2654_GUARD  the ONLY way past the HIMMEL-2654 stop
#                                 sign (see right below this table). Honoured
#                                 ONLY alongside GRAPH_CADENCE_HIMMEL_ROOT, so
#                                 it is structurally unreachable outside this
#                                 script's own test fixtures. Gone entirely
#                                 once HIMMEL-2654 lands and the guard is
#                                 removed.
#
# HANDOVER_DIR is NOT a test seam -- it is the normal, required way this
# script locates <handover-root>/.graph-cadence/ledger.jsonl (via
# scripts/lib/load-dotenv.sh -> scripts/lib/handover-path.sh, same as every
# other handover-writing script in this repo). If it is unset (cron's own
# minimal environment is exactly where this bites, HIMMEL-2619 class) this
# script refuses LOUDLY rather than let handover_root_ensure silently
# `mkdir -p` himmel's own Mode A handovers/ stub and write the cadence
# ledger straight into the git repo it publishes. The refusal still lands in
# the runner's per-fire log AND a flow-run-ledger error row (both resolve
# independently of HANDOVER_DIR) -- see the block itself for the full
# rationale. Set it via /handover-setup, or docs/internals/handover-system.md.
#
# Exit codes:
#   0  skipped (below threshold), refreshed, published, or merged
#   1  usage error
#   2  environment unusable (HOME unresolvable, required tool missing,
#      HANDOVER_DIR unset or unresolvable) -- OR (as of HIMMEL-2654, see the
#      STOP SIGN right below this table) the script refuses to run AT ALL,
#      unconditionally, until that ticket lands.
#   3  a pipeline leg failed (action=failed in the ledger; see stderr)
#   4  the run itself completed (or failed) but its OWN ledger.jsonl append
#      failed (disk full, permissions, etc.) -- the run is UNRECORDED; see
#      stderr. Distinct from every other code so an append failure can never
#      be confused with a genuine pipeline failure or a usage/environment
#      problem (PR-B panel r1, codex-6: the ledger IS the report).
set -uo pipefail

# --- HIMMEL-2654 STOP SIGN -- structural, not prose ---------------------------
# The gate row at a7e10179 found the pipeline lock (step 5a below) is not
# actually safe under concurrency: stale-lock takeover is not single-winner
# (two contenders can both pass it), and lock age alone can evict a STILL-
# RUNNING pipeline (no heartbeat, no overall timeout) -- either way, two
# concurrent `reset --hard` + `clean -fdx` runs against one worktree. Filed as
# HIMMEL-2654; not fixed here under the cost throttle. A doc note and a ticket
# do not stop the next operator registering the scheduled entry, so this
# refuses to run at all until 2654 lands -- before ANYTHING destructive: no
# worktree resolution, no lock acquisition, no fetch, nothing below this line
# runs by default. The ONLY way past it is GRAPH_CADENCE_BYPASS_2654_GUARD,
# double-gated on GRAPH_CADENCE_HIMMEL_ROOT (same pattern as the existing
# GRAPH_CADENCE_DOTENV_ROOT seam below) so a real cadence run -- cron or a
# manual invocation, neither of which ever sets GRAPH_CADENCE_HIMMEL_ROOT --
# can never satisfy it; only test-graph-cadence.sh's own fixtures can, which
# is how the other ~100 pipeline-logic tests still exercise the code this
# guard sits in front of. REMOVAL TRIGGER (HIMMEL-2654 step 3): once the lock
# is fixed and has its own RED controls proving it, delete this block (the
# echo/exit AND the bypass conditional), the matching note in
# docs/internals/graph-cadence.md, and test-graph-cadence.sh's refusal test
# (plus the now-unneeded bypass exports it added to every other test) --
# that deletion is what makes 2654's closure observable.
if [ -z "${GRAPH_CADENCE_HIMMEL_ROOT:-}" ] || [ -z "${GRAPH_CADENCE_BYPASS_2654_GUARD:-}" ]; then
    echo "ERR graph-cadence: refusing to run -- HIMMEL-2654 (unresolved): the pipeline lock below is not safe under concurrency (stale-lock takeover is not single-winner; lock age alone can evict a still-running pipeline) and two concurrent runs can both reset --hard + clean -fdx the same worktree. This script will not run destructively until HIMMEL-2654 lands. Wait for HIMMEL-2654, or read it for the exact race." >&2
    exit 2
fi

# --- PATH self-heal (HIMMEL-2619 class) -------------------------------------
# Cron fires with, at most, a bare default PATH -- sometimes none at all
# (this script's own `env -i` test proves the no-PATH-at-all case). Every
# coreutil this script's own body uses directly (dirname, date, mkdir, cat,
# basename, grep, sed) plus git itself must resolve; if the inherited PATH is
# missing any of them, fall back to the standard POSIX locations rather than
# fail with a bare "command not found" deep inside the run. Mirrors
# scripts/lib/flow-run-ledger.sh's own self-heal idiom.
command -v dirname >/dev/null 2>&1 && command -v date >/dev/null 2>&1 \
    && command -v git >/dev/null 2>&1 && command -v mkdir >/dev/null 2>&1 \
    && command -v grep >/dev/null 2>&1 \
    || PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
export PATH

usage() {
    cat <<'EOF'
usage: graph-cadence.sh [--threshold N] [--corpus-root <path>]

Refresh + publish himmel's graphify graph on a cadence: measures how many
commits origin/main is ahead of the shipped graph.json's built_at_commit,
and -- at/above --threshold -- runs ast-update.sh, graph-publish.sh, and
merge-on-green.sh (ARMAUTOMERGE=1) against a DEDICATED worktree, never the
primary checkout. See this script's header for the full design.

Optional:
  --threshold N       Commits-behind floor to trigger a refresh+publish.
                       Default: 15 (see header for the measured trade-off).
  --corpus-root <path> MUST equal the resolved primary checkout (default:
                       that same value, so the flag is normally unnecessary).
                       NOT a real multi-corpus switch: fetch, staleness
                       measurement, and the dedicated worktree's source all
                       still target the primary checkout regardless of this
                       value -- a different --corpus-root is REFUSED outright
                       (rc=1) rather than silently publishing the wrong
                       corpus. himmel is the only corpus wired for v1; a real
                       second corpus needs this flag made genuinely end-to-end
                       first (see docs).
EOF
}

THRESHOLD=15
CORPUS_ROOT_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --threshold)
            [ $# -ge 2 ] || { echo "ERR graph-cadence: --threshold requires a value" >&2; exit 1; }
            THRESHOLD="$2"; shift 2 ;;
        --threshold=*) THRESHOLD="${1#--threshold=}"; shift ;;
        --corpus-root)
            [ $# -ge 2 ] || { echo "ERR graph-cadence: --corpus-root requires a value" >&2; exit 1; }
            CORPUS_ROOT_OVERRIDE="$2"; shift 2 ;;
        --corpus-root=*) CORPUS_ROOT_OVERRIDE="${1#--corpus-root=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERR graph-cadence: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done
case "$THRESHOLD" in
    ''|*[!0-9]*) echo "ERR graph-cadence: --threshold must be a non-negative integer, got: $THRESHOLD" >&2; exit 1 ;;
esac

command -v git >/dev/null 2>&1 || { echo "ERR graph-cadence: 'git' not on PATH" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT: the checkout this script ITSELF physically lives in -- always
# used to resolve its own siblings (scripts/lib/*.sh, scripts/handover/
# merge-on-green.sh). Deliberately distinct from HIMMEL_ROOT below, which is
# the CORPUS being measured/fetched and is test-overridable
# (GRAPH_CADENCE_HIMMEL_ROOT) to point at a fixture repo -- a script's own
# sibling libraries must resolve from where the script lives, never from a
# corpus a test has pointed elsewhere. In a real cadence run the two are the
# same path (this script only ever ships inside the primary checkout it also
# measures), so this split is invisible outside the test suite.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Resolve the PRIMARY checkout root, mirroring ggs-cadence.sh's
# resolve_himmel_root (HIMMEL-892 codex-adv-1 rationale): via
# --git-common-dir, not this script's own SCRIPT_DIR, so arming/firing from a
# feature worktree copy of this file still targets the real primary.
resolve_himmel_root() {
    local common_dir
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common_dir" ] || return 1
    case "$common_dir" in
        /*) : ;;
        *) common_dir="$SCRIPT_DIR/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
}
if [ -n "${GRAPH_CADENCE_HIMMEL_ROOT:-}" ]; then
    HIMMEL_ROOT="$GRAPH_CADENCE_HIMMEL_ROOT"
elif HIMMEL_ROOT="$(resolve_himmel_root)" && [ -n "$HIMMEL_ROOT" ]; then
    :
else
    echo "ERR graph-cadence: could not resolve the primary checkout via git (git unavailable, not inside a repo, or rev-parse failed)" >&2
    exit 2
fi
[ -d "$HIMMEL_ROOT/.git" ] || [ -f "$HIMMEL_ROOT/.git" ] || {
    echo "ERR graph-cadence: resolved HIMMEL_ROOT '$HIMMEL_ROOT' is not a git checkout" >&2
    exit 2
}

CORPUS_ROOT="${CORPUS_ROOT_OVERRIDE:-$HIMMEL_ROOT}"
[ -d "$CORPUS_ROOT" ] || { echo "ERR graph-cadence: --corpus-root '$CORPUS_ROOT' is not a directory" >&2; exit 2; }
# --corpus-root is NOT yet honoured end-to-end (PR-B panel r1, codex-3): it
# changes CORPUS_SLUG and this existence check, but the fetch, the shipped-
# graph read, the staleness measurement, and the worktree's SOURCE all still
# target $HIMMEL_ROOT below, unconditionally -- passing a different corpus
# would silently publish HIMMEL while claiming to operate on something else.
# himmel is the only corpus wired for v1 (see this script's header + docs/
# internals/graph-cadence.md); rather than ship a flag that LOOKS like it
# works and quietly does something else, refuse outright here until a real
# per-corpus fetch/staleness/worktree-source path is verified end-to-end
# (tracked as future work, not this ticket -- see the header's Usage note).
_corpus_root_canon="$(cd "$CORPUS_ROOT" && pwd)"
_himmel_root_canon="$(cd "$HIMMEL_ROOT" && pwd)"
if [ "$_corpus_root_canon" != "$_himmel_root_canon" ]; then
    echo "ERR graph-cadence: --corpus-root '$CORPUS_ROOT' is not the resolved primary checkout ('$HIMMEL_ROOT') -- himmel is the only corpus this script is wired for in v1. Fetch, staleness measurement, and the dedicated worktree's source all still target the primary checkout regardless of --corpus-root, so a different value would silently publish HIMMEL's graph while claiming to operate on something else. Omit --corpus-root, or pass the primary checkout's own path." >&2
    exit 1
fi

AST_UPDATE="${GRAPH_CADENCE_AST_UPDATE:-$SCRIPT_DIR/ast-update.sh}"
GRAPH_PUBLISH="${GRAPH_CADENCE_GRAPH_PUBLISH:-$SCRIPT_DIR/graph-publish.sh}"
MERGE_ON_GREEN="${GRAPH_CADENCE_MERGE_ON_GREEN:-$REPO_ROOT/scripts/handover/merge-on-green.sh}"
for _f in "$AST_UPDATE" "$GRAPH_PUBLISH" "$MERGE_ON_GREEN"; do
    [ -f "$_f" ] || { echo "ERR graph-cadence: required script missing: $_f" >&2; exit 2; }
done

# --- HOME resolution ---------------------------------------------------------
# Real cron sets HOME from the crontab owner's passwd entry, so this is a
# no-op there. `env -i` (this script's own hermetic-environment test) wipes
# it too -- fall back to a passwd lookup (works with no login shell, no
# HOME); if THAT also fails, refuse loudly rather than silently defaulting
# the PERSISTENT worktree location to /tmp (see header: a cleanup sweep would
# reap it).
if [ -z "${HOME:-}" ]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
fi
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    echo "ERR graph-cadence: HOME is unset/unresolvable and no passwd fallback was found -- refusing to guess a persistent worktree location (never /tmp; see header). Set HOME in the environment this fires under." >&2
    exit 2
fi
export HOME

# --- corpus slug + dedicated worktree ---------------------------------------
# See header: the worktree's BASENAME must equal this slug so graph-
# publish.sh's own `basename "$(git rev-parse --show-toplevel)")` derives the
# SAME branch name this script predicts (PUBLISH_BRANCH) and hands to
# merge-on-green.sh as its PR selector. Identical sanitization to graph-
# publish.sh's own corpus_slug (documented duplication, small + stable).
# Computed BEFORE HANDOVER_DIR resolution below (deliberately -- neither
# depends on it) so a HANDOVER_DIR failure can still be logged to LOG_FILE
# and to the flow-run ledger (see the loud-refusal block).
_corpus_basename="$(basename "$CORPUS_ROOT")"
CORPUS_SLUG="$(printf '%s' "$_corpus_basename" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
[ -n "$CORPUS_SLUG" ] || CORPUS_SLUG="repo"
WORKTREE_DIR="${GRAPH_CADENCE_WORKTREE_DIR:-$HOME/.claude/graph-cadence/$CORPUS_SLUG}"
PUBLISH_BRANCH="chore/graph-publish-${CORPUS_SLUG}"
LOG_FILE="$WORKTREE_DIR.log"
FLOW_NAME="graph-publish-${CORPUS_SLUG}"

# --- flow-run-ledger.sh (~/.himmel/flow-runs.jsonl by default) --------------
# Sourced early, deliberately BEFORE HANDOVER_DIR resolution: its default
# path is HOME-based, not HANDOVER_DIR-based, so it is the one ledger this
# script can ALWAYS write to -- including the loud-refusal path below, where
# there is by definition no resolved handover root to write this script's
# OWN ledger.jsonl into.
# shellcheck source=../lib/flow-run-ledger.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/flow-run-ledger.sh"
START_TS=$(date -u +%s)
RUN_ID=$(_fr_emit_append_start "$FLOW_NAME" "" "" "" "" "graph-cadence" "$LOG_FILE" "$$")

# --- HANDOVER_DIR from the primary's .env (never hardcoded) -----------------
# Sourced/resolved from REPO_ROOT (this script's own checkout), not
# HIMMEL_ROOT (the corpus under measurement, test-overridable) -- see the
# REPO_ROOT comment above.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/load-dotenv.sh"
# GRAPH_CADENCE_DOTENV_ROOT (test seam, PR-B panel r1 codex-5): load_dotenv's
# `--root` bypasses CWD-based resolution entirely and reads exactly the given
# dir's .env -- no fallback walk to a primary checkout -- so this script's own
# REPO_ROOT (always the checkout it physically ships in, never test-
# overridable) is what gets read in EVERY invocation, real or test. A test
# fixture happening to run from a checkout with no .env is safe only by
# ACCIDENT of that checkout's disk state, not by anything the test itself
# asserts -- exactly the hermeticity gap PR-A's three CR rounds on this same
# class landed on (explicit `env -i` allowlist, never an incidental absence).
# Gated on GRAPH_CADENCE_HIMMEL_ROOT (an EXISTING test-only seam a real
# cadence run never sets) so this can never be reached in production: a real
# fire always resolves HIMMEL_ROOT itself and never redirects the dotenv read
# to an arbitrary directory.
DOTENV_ROOT_FOR_LOAD="$REPO_ROOT"
if [ -n "${GRAPH_CADENCE_HIMMEL_ROOT:-}" ] && [ -n "${GRAPH_CADENCE_DOTENV_ROOT:-}" ]; then
    DOTENV_ROOT_FOR_LOAD="$GRAPH_CADENCE_DOTENV_ROOT"
fi
load_dotenv --root "$DOTENV_ROOT_FOR_LOAD" HANDOVER_DIR
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/handover-path.sh"

# HIMMEL-2619 class, closed: cron gives no login shell, so HANDOVER_DIR --
# unset (never exported anywhere, and this checkout's .env doesn't carry it
# either) -- is EXACTLY the variable that goes missing there. himmel's own
# handovers/ is a Mode A stub by design (real state lives in the operator's
# external state repo); handover_root_ensure's Mode A branch would silently
# `mkdir -p` that stub and hand back a "valid" root the instant HANDOVER_DIR
# is unset -- writing this cadence's ledger straight into the git repo the
# cadence itself publishes, invisibly, until someone `git add -A`s it by
# accident. (This is not hypothetical: it happened once during this ticket's
# own implementation, caught and reverted before commit.) So: refuse LOUDLY
# here, before ever calling handover_root_ensure, rather than let that
# "succeed". `handover_root()`'s OWN rc=2 already covers the OTHER bad case
# (HANDOVER_DIR set but pointing nowhere real) via the else-branch below --
# this block covers only the UNSET case, which is silently accepted
# upstream.
#
# GRAPH_CADENCE_LEDGER_ROOT (the test seam) is a deliberate escape hatch and
# bypasses this requirement entirely: it names the ledger root directly and
# never touches handover_root_ensure/Mode A, so there is no fallback risk to
# guard against when it is set. A real cadence run never sets it.
if [ -z "${GRAPH_CADENCE_LEDGER_ROOT:-}" ] && [ -z "${HANDOVER_DIR:-}" ]; then
    _msg="HANDOVER_DIR is unset (not in the environment, not in $REPO_ROOT/.env) -- refusing to fall back to himmel's own handovers/ stub (Mode A), which would write this cadence's ledger straight into the git repo it publishes. Set HANDOVER_DIR (see /handover-setup, or docs/internals/handover-system.md) in whatever environment this fires under -- cron included."
    echo "ERR graph-cadence: $_msg" >&2
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '[%s] ERR graph-cadence: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_msg" >> "$LOG_FILE" 2>/dev/null || true
    _fr_emit_append_end "$FLOW_NAME" "$RUN_ID" "" 2 error "" "$_msg"
    exit 2
fi
if [ -n "${GRAPH_CADENCE_LEDGER_ROOT:-}" ]; then
    LEDGER_ROOT="$GRAPH_CADENCE_LEDGER_ROOT"
elif LEDGER_ROOT="$(cd "$REPO_ROOT" && handover_root_ensure)" && [ -n "$LEDGER_ROOT" ]; then
    :
else
    _msg="HANDOVER_DIR='$HANDOVER_DIR' is set but does not resolve to a usable handover root -- cannot write the ledger row"
    echo "ERR graph-cadence: $_msg" >&2
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '[%s] ERR graph-cadence: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_msg" >> "$LOG_FILE" 2>/dev/null || true
    _fr_emit_append_end "$FLOW_NAME" "$RUN_ID" "" 2 error "" "$_msg"
    exit 2
fi
LEDGER_DIR="$LEDGER_ROOT/.graph-cadence"
mkdir -p "$LEDGER_DIR" || { echo "ERR graph-cadence: could not create $LEDGER_DIR" >&2; exit 2; }
LEDGER_FILE="$LEDGER_DIR/ledger.jsonl"

ACTION="failed"
ERROR=""
PR_REF=""
GRAPH_HEAD=""
MERGES_BEHIND=""
FINAL_RC=0

# _write_ledger — one JSONL line to LEDGER_FILE (this script's own ledger)
# PLUS the standard flow-run-ledger end row every sibling cadence writes.
# Reuses flow-run-ledger.sh's own JSON-escaping helpers (_fr_json_str /
# _fr_json_null_str / _fr_json_int) rather than a fifth hand-rolled escaper.
_write_ledger() {
    local head_sha end_ts dur outcome
    head_sha=$(git -C "$HIMMEL_ROOT" rev-parse --verify --quiet origin/main 2>/dev/null || echo "")
    end_ts=$(date -u +%s)
    dur=$(( end_ts - START_TS ))
    local line
    line=$(printf '{"ts":%s,"head":%s,"graph_head":%s,"merges_behind":%s,"action":%s,"pr":%s,"duration_s":%s,"error":%s}' \
        "$(_fr_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
        "$(_fr_json_null_str "$head_sha")" \
        "$(_fr_json_null_str "$GRAPH_HEAD")" \
        "$(_fr_json_int "${MERGES_BEHIND:-}")" \
        "$(_fr_json_str "$ACTION")" \
        "$(_fr_json_null_str "$PR_REF")" \
        "$(_fr_json_int "$dur")" \
        "$(_fr_json_null_str "$ERROR")")
    local _ledger_append_rc=0
    printf '%s\n' "$line" >> "$LEDGER_FILE" || _ledger_append_rc=$?

    case "$ACTION" in
        failed)             outcome=error ;;
        skipped)             outcome=complete ;;
        refreshed|published|merged) outcome=complete ;;
        *)                   outcome=error ;;
    esac
    # PR-B panel r1, codex-6: a failed append to LEDGER_FILE must never be
    # silently absorbed by a SUCCESSFUL flow-run-ledger write -- they are two
    # separate files, and the flow-run row succeeding says nothing about
    # whether THIS script's own ledger.jsonl (the one operators/himmel-
    # doctor's C33 check actually read) recorded anything at all. Force the
    # flow-run row's own outcome to error too when the append failed, so the
    # two rows for this run never disagree about whether it was recorded.
    [ "$_ledger_append_rc" -eq 0 ] || outcome=error
    _fr_emit_append_end "$FLOW_NAME" "$RUN_ID" "" "$FINAL_RC" "$outcome" "" "${ERROR:-$ACTION}"

    # The ledger IS the report (see this script's header): a run that could
    # not record its own outcome did not report, regardless of what the
    # pipeline itself did. `_write_ledger` therefore never returns control to
    # its caller on an append failure -- every call site's own `exit`
    # immediately after `_write_ledger` would otherwise still fire with
    # whatever rc the PIPELINE computed, silently masking an unrecorded run
    # as a clean skip/success. exit 4 is a NEW, distinct code (see header)
    # so this failure mode is never confused with a genuine pipeline failure
    # (exit 3) or a usage/environment problem (exit 1/2).
    if [ "$_ledger_append_rc" -ne 0 ]; then
        echo "ERR graph-cadence: could not append to ledger $LEDGER_FILE (rc=$_ledger_append_rc) -- this run's outcome (action=$ACTION) is UNRECORDED. Treating this as a hard failure regardless of the pipeline's own result." >&2
        exit 4
    fi
}

_fail() {
    ACTION="failed"
    ERROR="$1"
    FINAL_RC=3
    echo "ERR graph-cadence: $1" >&2
    _write_ledger
    exit 3
}

# --- 1. fetch (safe: refs only, never the working tree) ---------------------
if ! git -C "$HIMMEL_ROOT" fetch origin >/dev/null 2>&1; then
    _fail "git fetch origin failed"
fi

# --- 2. built_at_commit from the SHIPPED graph.json --------------------------
# `cat-file -e origin/main:<path>` returns non-zero both when origin/main
# resolves but the path is absent AND when origin/main itself does not
# resolve (a genuine git/ref error `git fetch origin` alone doesn't rule
# out -- CodeRabbit, PR #2272). Only the first case is the permanent
# HIMMEL-2705 steady state; the second must still route through _fail so a
# real ref/object-read failure is never misreported as a clean skip.
if ! git -C "$HIMMEL_ROOT" rev-parse --verify -q origin/main >/dev/null; then
    _fail "origin/main does not resolve after git fetch origin"
fi
# graphify-out/ was REMOVED from the git tree entirely and gitignored outright
# (HIMMEL-2705 step 1) -- this repo's derived graph no longer publishes at
# all, so origin/main never has graphify-out/graph.json to read. That is the
# permanent steady state now, not a transient gap. PUBLISH_POSSIBLE gates
# ONLY the origin-comparison staleness measurement (steps 3-4) and the
# retired publish/merge legs (steps 6-7, renumbered below) -- it must NEVER
# skip step 5, the local AST-only refresh, which has nothing to do with
# whether origin has anything to compare against or publish to. An earlier
# revision of this fix (this same PR, CR round 2) collapsed all of that into
# one early `exit 0`, making step 5 -- the free, no-LLM-cost rebuild
# .gitignore's own comment promises ("the daily HIMMEL-829 cadence keeps
# rebuilding them locally") -- permanently unreachable. It is not gated on
# staleness at all now: with no shipped graph left to measure distance
# against, "stale" has no origin-side meaning any more, so the local refresh
# just runs every fire, throttled only by this cadence's own external
# schedule (6h, HIMMEL-2095) -- exactly what the .gitignore promise says.
PUBLISH_POSSIBLE=1
GRAPH_JSON_OBJECT_UNREADABLE=0
if ! git -C "$HIMMEL_ROOT" cat-file -e "origin/main:graphify-out/graph.json" 2>/dev/null; then
    PUBLISH_POSSIBLE=0
    # cat-file -e alone cannot tell "path absent" (the HIMMEL-2705 retired
    # steady state, handled by the plain message below) apart from "path IS
    # tracked but its object could not be read" (corrupt/partial clone,
    # missing objects -- PR #2272 round-3). ls-tree only reads the TREE
    # object, so it still lists the path even when the blob itself is
    # unreadable -- distinguish the two and say so loudly; PUBLISH_POSSIBLE
    # stays 0 either way (fail closed).
    if [ -n "$(git -C "$HIMMEL_ROOT" ls-tree origin/main -- graphify-out/graph.json 2>/dev/null)" ]; then
        GRAPH_JSON_OBJECT_UNREADABLE=1
        echo "graph-cadence: WARN graphify-out/graph.json is listed in origin/main's tree but its object could not be read (corrupt or partial clone?) -- treating as unpublishable this run, NOT the permanent HIMMEL-2705 retired-path skip" >&2
    fi
fi

if [ "$PUBLISH_POSSIBLE" -eq 1 ]; then
    _shipped_graph=$(git -C "$HIMMEL_ROOT" show origin/main:graphify-out/graph.json 2>/dev/null) \
        || _fail "could not read origin/main:graphify-out/graph.json despite cat-file -e succeeding"
    GRAPH_HEAD=$(printf '%s' "$_shipped_graph" \
        | grep -o '"built_at_commit"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed -E 's/.*"built_at_commit"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
    [ -n "$GRAPH_HEAD" ] || _fail "graphify-out/graph.json has no (or an empty) built_at_commit field"

    # --- 3. staleness: commit distance, NOT --merges (see header) -----------
    MERGES_BEHIND=$(git -C "$HIMMEL_ROOT" rev-list --count "${GRAPH_HEAD}..origin/main" 2>&1) \
        || _fail "git rev-list --count ${GRAPH_HEAD}..origin/main failed: $MERGES_BEHIND"
    case "$MERGES_BEHIND" in
        ''|*[!0-9]*) _fail "git rev-list produced a non-numeric count: $MERGES_BEHIND" ;;
    esac

    # --- 4. below threshold: skip (nothing to refresh-and-publish this run) --
    if [ "$MERGES_BEHIND" -lt "$THRESHOLD" ]; then
        ACTION="skipped"
        FINAL_RC=0
        echo "graph-cadence: $MERGES_BEHIND commit(s) behind origin/main, below threshold $THRESHOLD -- skipping"
        _write_ledger
        exit 0
    fi
    echo "graph-cadence: $MERGES_BEHIND commit(s) behind origin/main (threshold $THRESHOLD) -- refreshing"
elif [ "$GRAPH_JSON_OBJECT_UNREADABLE" -eq 1 ]; then
    : # already reported by the loud WARN above; nothing more to say here
else
    echo "graph-cadence: origin/main does not track graphify-out/graph.json (HIMMEL-2705 step 1: retired from the git tree) -- publish/merge will no-op this run, but the local AST-only refresh (step 5) still runs"
fi

# --- 5. dedicated worktree: create on demand, always resync to origin/main --
mkdir -p "$(dirname "$WORKTREE_DIR")" || _fail "could not create $(dirname "$WORKTREE_DIR")"

# --- 5a. pipeline lock (PR-B panel r1 codex-1, hardened r2 codex-1): serializes
# the WHOLE refresh/publish/merge pipeline below, not just ast-update.sh's own
# promote step. ast-update.sh's HIMMEL-910 promote lock is SKIP-not-wait and
# scoped to ITS OWN write into graphify-out/ -- it does not, and was never
# meant to, cover graph-publish.sh's checkout/commit/push or merge-on-green.sh's
# merge, both of which also mutate $WORKTREE_DIR. Without a run-wide lock, an
# overlapping scheduled fire and a manual invocation can reset/clean the
# worktree out from under each other mid-refresh or mid-publish.
# SKIP-not-wait, mirroring ast-update.sh's own convention: a losing run
# reports action=skipped (not a failure) and the next scheduled fire retries.
# OWNER TOKEN + STALE-AGE RECOVERY (r2 codex-1): round 1's lock had neither --
# a reboot or SIGKILL between mkdir and the matching rm leaves it behind
# PERMANENTLY, and every above-threshold run afterward reports a successful
# skip while refreshing and publishing nothing -- silently doing nothing
# forever, reporting success each time, exactly this branch's subject class.
# The owner-token + acquired-epoch-stamp + single-winner-takeover shape below
# is NOT a new convention: it mirrors refresh-graph-map.sh's OWN
# `_promote_lock_acquire`/`_promote_lock_release` (HIMMEL-1960) byte-for-byte
# in spirit -- a proven pattern in this exact codebase, reused rather than
# reinvented. Residual TOCTOU (a lock that mkdir'd but crashed before its
# stamp was written) is the SAME documented HIMMEL-2618-class race that
# script's own header carries and this ticket does not fix -- this script's
# single-attempt skip-not-wait shape treats a missing/unreadable stamp as
# "held" (never a takeover candidate), narrower exposure than a wait-and-poll
# acquire but the same accepted residual, not a new one.
PIPELINE_LOCK="${WORKTREE_DIR}.lock"
PIPELINE_LOCK_HELD=0
PIPELINE_LOCK_TOKEN=""
# Comfortably above any genuine run's ceiling (fetch + ast-update + graph-
# publish + merge-on-green.sh's own up-to-540s check-ci watch), comfortably
# below the 6h armed interval -- a crashed holder is reclaimed well before
# more than one scheduled fire is lost to it.
PIPELINE_LOCK_STALE_SECONDS=1800
# shellcheck disable=SC2317  # invoked only via `trap ... EXIT` below
_pipeline_lock_release() {
    local cur=""
    if [ "$PIPELINE_LOCK_HELD" -eq 1 ]; then
        PIPELINE_LOCK_HELD=0
        [ -d "$PIPELINE_LOCK" ] || return 0
        cur=$(cat "$PIPELINE_LOCK/owner" 2>/dev/null) || cur=""
        if [ "$cur" != "$PIPELINE_LOCK_TOKEN" ]; then
            # Taken over by another run while we still (thought we) held it
            # -- never remove a successor's lock (mirrors refresh-graph-
            # map.sh's _promote_lock_release owner-token compare exactly).
            echo "graph-cadence: WARN pipeline lock $PIPELINE_LOCK was taken over by another run while we held it (owner token mismatch) -- not releasing the successor's lock" >&2
            return 0
        fi
        rm -rf "$PIPELINE_LOCK" 2>/dev/null || true
    fi
}
trap _pipeline_lock_release EXIT
# _pipeline_lock_try_acquire -- rc 0: lock dir now exists and is ours to
# stamp (either mkdir won outright, or we won a stale takeover). rc 1: held
# by another run, genuinely contended (skip, benign).
_pipeline_lock_try_acquire() {
    if mkdir "$PIPELINE_LOCK" 2>/dev/null; then
        return 0
    fi
    local held_at now age sideline
    held_at=$(cat "$PIPELINE_LOCK/acquired" 2>/dev/null) || held_at=""
    case "$held_at" in ''|*[!0-9]*) held_at="" ;; esac
    [ -n "$held_at" ] || return 1
    now=$(date -u +%s)
    age=$(( now - held_at ))
    [ "$age" -ge "$PIPELINE_LOCK_STALE_SECONDS" ] || return 1
    # Single-winner atomic takeover: exactly one contender's mv succeeds.
    sideline="$PIPELINE_LOCK.stale.$$.$RANDOM"
    mv "$PIPELINE_LOCK" "$sideline" 2>/dev/null || return 1
    echo "graph-cadence: WARN pipeline lock $PIPELINE_LOCK is stale (age ${age}s >= ${PIPELINE_LOCK_STALE_SECONDS}s, presumably a crashed prior run) -- taking over" >&2
    rm -rf "$sideline" 2>/dev/null || true
    mkdir "$PIPELINE_LOCK" 2>/dev/null || return 1
    return 0
}
if ! _pipeline_lock_try_acquire; then
    ACTION="skipped"
    ERROR="pipeline lock $PIPELINE_LOCK held by a concurrent graph-cadence run -- skip-not-wait, retried on the next scheduled fire"
    FINAL_RC=0
    echo "graph-cadence: $ERROR"
    _write_ledger
    exit 0
fi
PIPELINE_LOCK_TOKEN="$$-$RANDOM"
if ! printf '%s\n' "$PIPELINE_LOCK_TOKEN" > "$PIPELINE_LOCK/owner" 2>/dev/null; then
    rm -rf "$PIPELINE_LOCK" 2>/dev/null || true
    _fail "pipeline lock acquired but its owner token could not be written ($PIPELINE_LOCK/owner) -- released again"
fi
date -u +%s > "$PIPELINE_LOCK/acquired" 2>/dev/null || true
PIPELINE_LOCK_HELD=1

_just_created_worktree=0
if [ ! -f "$WORKTREE_DIR/.git" ] && [ ! -d "$WORKTREE_DIR/.git" ]; then
    git -C "$HIMMEL_ROOT" worktree prune >/dev/null 2>&1 || true
    # The branch can already exist (a prior run's `git worktree add -b`
    # succeeded, then the WORKTREE DIRECTORY was later removed by hand
    # without `git worktree remove` -- the branch ref survives that) --
    # `-b` on an existing branch name is refused, so only pass it when the
    # branch is genuinely absent.
    if git -C "$HIMMEL_ROOT" show-ref --verify --quiet refs/heads/graph-cadence-work; then
        _wt_add_args=(graph-cadence-work)
    else
        _wt_add_args=(-b graph-cadence-work origin/main)
    fi
    if ! git -C "$HIMMEL_ROOT" worktree add "$WORKTREE_DIR" "${_wt_add_args[@]}" >/dev/null 2>&1; then
        # A stray non-worktree directory at the target path is the other
        # realistic cause here -- surface it rather than silently retrying.
        _fail "git worktree add $WORKTREE_DIR failed (stray directory at that path?)"
    fi
    _just_created_worktree=1
fi

# --- 5b. identity check (PR-B panel r1 codex-2, hardened r2 codex-2 -- the
# SINGLE MOST DANGEROUS item across either panel): round 1 compared
# --git-common-dir and called that "ownership". It is not. --git-common-dir
# only proves "this directory is A worktree of THIS repository" -- the
# PRIMARY CHECKOUT ITSELF, and every OTHER active worktree of this repo
# (any feature branch under .claude/worktrees/), share that EXACT same
# --git-common-dir and would pass that check too. If WORKTREE_DIR ever
# resolved to one of those (a misconfigured GRAPH_CADENCE_WORKTREE_DIR, a
# corpus-slug collision, an operator override) the checkout/reset/clean
# below would DESTROY that checkout's live uncommitted work -- unattended,
# on a schedule. "Same repo" is not "ours"; only something WE OURSELVES
# wrote can prove that.
#
# Two checks now, in order:
#   (a) WORKTREE_DIR must never canonicalize to HIMMEL_ROOT itself -- the
#       single most catastrophic case (destroying the PRIMARY checkout),
#       rejected EXPLICITLY (never left to the marker check below to also
#       happen to catch it). `pwd -P` (physical, symlinks resolved) so a
#       symlinked WORKTREE_DIR can't disguise itself either.
#   (b) OWNERSHIP MARKER: this script -- and ONLY this script -- writes
#       ${WORKTREE_DIR}.owner, stamped with HIMMEL_ROOT's own canonical
#       --git-common-dir (so a marker copied in from a DIFFERENT graph-
#       cadence deployment can't be replayed here either). A SIBLING path,
#       deliberately OUTSIDE $WORKTREE_DIR -- same convention as
#       ${WORKTREE_DIR}.lock/.log -- not a dotfile INSIDE the worktree: an
#       in-worktree marker is untracked, which trips graph-publish.sh's own
#       "working tree must be clean outside the two graph paths" refusal
#       (caught by this ticket's own test suite: a same-round regression,
#       fixed before it shipped) AND would be wiped by `clean -fdx` below,
#       needing yet another re-stamp-after-clean dance to survive. Outside
#       the worktree, git never sees it and clean never touches it -- written
#       once per run, after the sync below succeeds. A worktree that already
#       existed before this run (not just-created by step 5 above) MUST
#       already carry a matching marker, checked BEFORE any destructive git
#       command runs against it. The primary checkout and every sibling
#       worktree of this repo -- created by `git worktree`/`git clone`,
#       never by this script -- can never carry this marker, so they are
#       refused regardless of how their --git-common-dir resolves.
_himmel_common="$(git -C "$HIMMEL_ROOT" rev-parse --git-common-dir 2>/dev/null)" \
    || _fail "could not resolve HIMMEL_ROOT's own --git-common-dir"
case "$_himmel_common" in /*) ;; *) _himmel_common="$HIMMEL_ROOT/$_himmel_common" ;; esac
_himmel_common="$(cd "$_himmel_common" 2>/dev/null && pwd)" || _fail "could not canonicalize HIMMEL_ROOT's --git-common-dir"

_himmel_root_physical="$(cd "$HIMMEL_ROOT" && pwd -P)"
_worktree_dir_physical="$(cd "$WORKTREE_DIR" 2>/dev/null && pwd -P)" || _fail "could not canonicalize $WORKTREE_DIR"
if [ "$_worktree_dir_physical" = "$_himmel_root_physical" ]; then
    _fail "GRAPH_CADENCE_WORKTREE_DIR ($WORKTREE_DIR) resolves to the PRIMARY checkout itself ($HIMMEL_ROOT) -- refusing to checkout/reset/clean it. This would destroy the primary checkout live agent sessions use."
fi

OWNER_MARKER="${WORKTREE_DIR}.owner"
if [ "$_just_created_worktree" -eq 0 ]; then
    if [ ! -f "$OWNER_MARKER" ] || ! grep -qF "owner=$_himmel_common" "$OWNER_MARKER" 2>/dev/null; then
        _fail "$WORKTREE_DIR exists but carries no graph-cadence ownership marker (or one for a different checkout) at $OWNER_MARKER -- refusing to checkout/reset/clean it. This directory was NOT created by this script for this checkout; it may be the primary checkout, another worktree, or a foreign clone -- 'same repo' is not 'ours'. Remove it by hand if safe to discard, or point GRAPH_CADENCE_WORKTREE_DIR at an unused path."
    fi
fi
# (A just-created worktree has no marker YET -- trusted without one because
# `git worktree add` just handed it to us in this same process; the marker
# is written fresh below, after the sync succeeds, for the NEXT run to check.)

if ! git -C "$WORKTREE_DIR" checkout -B graph-cadence-work origin/main >/dev/null 2>&1; then
    _fail "could not sync dedicated worktree $WORKTREE_DIR to origin/main"
fi
# --- 5c. hard-fail on a sync failure (PR-B panel r2, codex-3): round 1
# swallowed a `reset --hard`/`clean -fdx` failure with `|| true` -- ast-
# update.sh and graph-publish.sh would then run against a tree that is NOT
# provably the clean origin/main snapshot they are told they're getting.
# Publishing from a dirty/stale tree is exactly how a wrong graph gets
# shipped as authoritative, so either step failing now aborts the pipeline.
if ! git -C "$WORKTREE_DIR" reset --hard origin/main >/dev/null 2>&1; then
    _fail "could not reset dedicated worktree $WORKTREE_DIR to origin/main (git reset --hard failed) -- refusing to refresh/publish from a tree that is not provably the clean origin/main snapshot"
fi
if ! git -C "$WORKTREE_DIR" clean -fdx >/dev/null 2>&1; then
    _fail "could not clean dedicated worktree $WORKTREE_DIR (git clean -fdx failed) -- refusing to refresh/publish from a tree that may carry leftover untracked files from a prior run"
fi
# (Re-)stamp the ownership marker AFTER the sync succeeds, so the NEXT run's
# identity check above finds it (it lives OUTSIDE the worktree -- see the
# comment above OWNER_MARKER -- so unlike an in-worktree marker it is never
# at risk from `clean -fdx`; written here anyway, once per successful run,
# to keep "ownership proven" tied to "sync actually succeeded"). A failure
# here is a hard failure, not a silent skip of the marker -- an unmarked
# worktree on the next run reads as foreign and refuses, defeating the whole
# point of a dedicated persistent worktree.
printf 'graph-cadence.sh HIMMEL-2095 owner=%s\n' "$_himmel_common" > "$OWNER_MARKER" \
    || _fail "could not write ownership marker $OWNER_MARKER after sync -- refusing to proceed on an unmarked worktree"

# --- 6. ast-update.sh (structural refresh, promote-lock-safe) ---------------
_ast_out=$("$AST_UPDATE" "$WORKTREE_DIR" 2>&1)
_ast_rc=$?
printf '%s\n' "$_ast_out"
if [ "$_ast_rc" -ne 0 ]; then
    # Short-circuit here — see header's ACTION CLASSIFICATION note on why
    # this pipeline does not run the remaining legs on a failed refresh.
    _fail "ast-update.sh exited $_ast_rc: $(printf '%s' "$_ast_out" | tail -n 3 | tr '\n' ' ')"
fi
ACTION="refreshed"

# --- 6a. retired publish/merge legs: clean no-op, not a skip ----------------
# PUBLISH_POSSIBLE=0 (see step 2/PUBLISH_POSSIBLE above) means origin/main
# does not track graphify-out/graph.json at all -- the permanent HIMMEL-2705
# step 1 steady state. The local refresh above still ran (that IS the point
# of decoupling it from this check); there is simply nothing left to open a
# PR against or merge. This is a clean no-op of steps 7-8, not an error and
# not ACTION="skipped" -- real work happened this run.
if [ "$PUBLISH_POSSIBLE" -eq 0 ]; then
    FINAL_RC=0
    echo "graph-cadence: local refresh complete; origin/main does not track graphify-out/graph.json, so publish/merge have nothing to do -- no-op"
    _write_ledger
    exit 0
fi

# --- 7. graph-publish.sh (open/refresh the PR) -------------------------------
_pub_out=$(cd "$WORKTREE_DIR" && "$GRAPH_PUBLISH" 2>&1)
_pub_rc=$?
printf '%s\n' "$_pub_out"
if [ "$_pub_rc" -eq 5 ]; then
    # Nothing new to publish (the rebuild was byte-identical to what's
    # already shipped) -- not a failure.
    FINAL_RC=0
    _write_ledger
    exit 0
elif [ "$_pub_rc" -ne 0 ]; then
    _fail "graph-publish.sh exited $_pub_rc: $(printf '%s' "$_pub_out" | tail -n 3 | tr '\n' ' ')"
fi
ACTION="published"
PR_REF=$(printf '%s' "$_pub_out" | grep -oE 'https://[^ ]+/pull/[0-9]+|PR #[0-9]+' | head -1)

# --- 8. merge-on-green.sh (ARMAUTOMERGE=1, sanctioned auto-merge chokepoint) -
# Explicit selector: the branch name this script predicted above (see header
# "WORKTREE DIRNAME MUST MATCH THE CORPUS SLUG") -- never the default
# "current branch" selector, which would resolve to this worktree's OWN
# graph-cadence-work branch (no PR there) after graph-publish.sh's own
# restore_branch put it back.
_merge_out=$(cd "$WORKTREE_DIR" && ARMAUTOMERGE=1 "$MERGE_ON_GREEN" "$PUBLISH_BRANCH" 2>&1)
_merge_rc=$?
printf '%s\n' "$_merge_out"
if [ "$_merge_rc" -eq 0 ]; then
    ACTION="merged"
    FINAL_RC=0
else
    # PR-B panel r1, codex-7: NOT every non-zero merge-on-green.sh exit is a
    # benign "not yet mergeable" state -- treating all of them alike used to
    # mean a permanently broken merge leg (gh missing, an unwritable audit
    # sink, a misconfigured base/privacy binding) reported "published" forever,
    # exactly as healthy-looking as a PR merely waiting on CI. Classify
    # against merge-on-green.sh's own documented exit-code table (its header):
    #   14 (check-ci gate not green) and 15 (merge attempt failed/indeterminate,
    #     incl. a --match-head-commit head-moved abort -- explicitly documented
    #     there as "not REFUSED") are genuine, TIME-RESOLVING deferrals: the
    #     PR is up, nothing is broken, the next scheduled run retries.
    #   Everything else -- 10 (not opted in; should be impossible, we set
    #     ARMAUTOMERGE=1 ourselves, so seeing it means something stripped our
    #     env), 11 (required tool missing), 12 (repo/base misconfigured --
    #     will not resolve with time), 13 (can't even resolve the PR/head),
    #     16 (audit sink unwritable), or any code merge-on-green.sh does not
    #     document -- is a real execution/environment failure, not a deferral.
    case "$_merge_rc" in
        14|15)
            ACTION="published"
            ERROR="merge-on-green.sh exited $_merge_rc (not merged this run -- expected deferral, see merge-on-green.sh's exit-code table): $(printf '%s' "$_merge_out" | tail -n 3 | tr '\n' ' ')"
            FINAL_RC=0
            _write_ledger
            exit 0
            ;;
        *)
            _fail "merge-on-green.sh exited $_merge_rc (execution/environment failure, not an expected deferral -- see merge-on-green.sh's exit-code table): $(printf '%s' "$_merge_out" | tail -n 3 | tr '\n' ' ')"
            ;;
    esac
fi

_write_ledger
exit "$FINAL_RC"
