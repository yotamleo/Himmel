#!/usr/bin/env bash
# refresh-graph-map.sh — incremental graphify refresh + curated-MOC publish for
# one corpus (HIMMEL-825). The schedulable core behind the interval refresh that
# bounds graph drift.
#
# WHY: graphify graphs are point-in-time snapshots that drift as the corpus
# changes. A full sync is ~$2 (measured 2026-07-09); `graphify --update` is
# INCREMENTAL (only changed files re-extracted) so a frequent (e.g. daily) run
# is cheap. This wraps the fence-safe refresh so a scheduler (or an operator)
# can call it per corpus.
#
# FENCE SAFETY: extraction never runs on a live vault — we operate on a
# scratchpad COPY carrying a `.graphify-corpus` marker (same discipline as the
# harvest tools + the egress matrix). The derived graph.json + full
# GRAPH_REPORT.md land in the corpus's repo-local `graphify-out/` (the "latest
# in repo" substrate); only the curated MOC is published to the vault's
# 60-Maps/ (the tracked artifact that "moves" on update).
#
# Usage:
#   refresh-graph-map.sh --name luna --corpus-root <path> --backend deepseek \
#       --maps-dir <luna>/60-Maps --title "Graphify Luna Map" --slug graphify-luna-map \
#       [--corpus-tag luna] [--scratch <dir>] [--no-update]
#
# Exit: 0 ok; 1 usage/IO; 2 fence/graphify failure.
#
# Freshness guard: this script REBUILDS the graph. To CHECK whether an existing
# graphify-out/ is still fresh (and not orphaned from its corpus) before querying
# it, run check-graph-freshness.sh --out <graphify-out> [--max-age-days N]
# (companion script, same dir). HIMMEL-621/824/825 family.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# BACKEND default = claude-cli (HIMMEL-1049): graphify distinguishes `claude`
# (Anthropic API — requires ANTHROPIC_API_KEY, pay-as-you-go) from `claude-cli`
# (routes through the locally-installed `claude` CLI). The claude-ONLY adopter
# story needs claude-cli, not claude.
# BILLING CAVEAT (CodeRabbit): claude-cli authenticates via the operator's
# existing Pro/Max SUBSCRIPTION *only when no Anthropic API credential is in the
# environment* — a set ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN takes precedence
# in the `claude` CLI and switches the run back to pay-as-you-go. We deliberately
# do NOT strip those vars here (the operator may intend the API path); this is a
# default, not a billing guarantee.
NAME="" CORPUS_ROOT="" BACKEND="claude-cli" MAPS_DIR="" TITLE="" SLUG="" CORPUS_TAG=""
SCRATCH="" DO_UPDATE=1 CORPUS_CLASS="luna-personal"
usage() { echo "usage: refresh-graph-map.sh --name N --corpus-root P --maps-dir D --title T --slug S [--backend B] [--corpus-tag T] [--corpus-class C] [--scratch DIR] [--no-update]" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    --backend) BACKEND="${2:-}"; shift 2 ;;
    --maps-dir) MAPS_DIR="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --corpus-tag) CORPUS_TAG="${2:-}"; shift 2 ;;
    --corpus-class) CORPUS_CLASS="${2:-}"; shift 2 ;;
    --scratch) SCRATCH="${2:-}"; shift 2 ;;
    --no-update) DO_UPDATE=0; shift ;;
    *) echo "refresh-graph-map: unknown flag: $1" >&2; usage ;;
  esac
done
if [ -z "$NAME" ] || [ -z "$CORPUS_ROOT" ] || [ -z "$MAPS_DIR" ] || [ -z "$TITLE" ] || [ -z "$SLUG" ]; then usage; fi
[ -d "$CORPUS_ROOT" ] || { echo "refresh-graph-map: corpus root not found: $CORPUS_ROOT" >&2; exit 1; }

# GLM (Z.ai) alias (HIMMEL-1048). graphify has NO native `glm` backend — GLM is
# reached via graphify's `claude` backend pointed at Z.ai's Anthropic-compatible
# endpoint. The egress matrix + fence already classify `--backend glm` as the
# ratified zai-glm provider (luna-personal extraction = allow+log, HIMMEL-1096/1122),
# so make `--backend glm` a single-flag process instead of hand-setting ANTHROPIC_*
# env each run: it remaps to `--backend claude` + ANTHROPIC_BASE_URL=<z.ai> +
# ANTHROPIC_MODEL=glm-5.2 + ANTHROPIC_API_KEY=<ZAI_API_KEY, loaded from .env, never
# printed>. A live ANTHROPIC_* env still wins (only fills gaps).
case "$BACKEND" in
  glm|zai-glm)
    BACKEND="claude"
    : "${ANTHROPIC_BASE_URL:=https://api.z.ai/api/anthropic}"
    : "${ANTHROPIC_MODEL:=glm-5.2}"
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      # shellcheck source=../lib/load-dotenv.sh
      # shellcheck disable=SC1091
      if . "$(dirname "$0")/../lib/load-dotenv.sh" 2>/dev/null && load_dotenv ZAI_API_KEY 2>/dev/null && [ -n "${ZAI_API_KEY:-}" ]; then
        ANTHROPIC_API_KEY="$ZAI_API_KEY"
      else
        echo "refresh-graph-map: --backend glm needs ZAI_API_KEY (in the primary checkout's .env) or ANTHROPIC_API_KEY set." >&2
        exit 1
      fi
    fi
    export ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_API_KEY
    echo "refresh-graph-map: --backend glm -> claude backend @ $ANTHROPIC_BASE_URL (model $ANTHROPIC_MODEL)" >&2
    ;;
esac

GRAPHIFY_MAP="${GRAPHIFY_MAP_BIN:-graphify}"   # test hook: stub graphify
# graphify is only needed for the extraction path — --no-update publishes from
# an existing report and must not require it (CR: code-reviewer).

# Extraction/labeling concurrency knob (HIMMEL-1097 mitigation). --max-concurrency
# caps only how many requests are IN FLIGHT at once — it is not true rate-limiting
# (no pacing/backoff between sequential requests), so it reduces request pressure
# but cannot beat a hard per-key quota. The default 6 overshoots a rate-limited
# backend badly — `--backend glm` (Z.ai) 429s (rate_limit_error code 1302) on most
# chunks at 6. Lowering it (e.g. GRAPHIFY_MAX_CONCURRENCY=1) eases the pressure and
# is worth trying, but is NOT guaranteed to complete: an exhausted/hard request
# quota 429s even serialized (observed 2026-07-21 — chunk 1 failed at concurrency 1
# with ~33s spacing). Applies to BOTH the --update extraction and the cluster-only
# labeling pass (both make backend LLM calls against the same limit). Must be a
# positive integer; anything else (including an explicitly-empty value) fails loud.
# Band-aid — the durable fix (seed graphify's semantic cache so the regen is a
# small incremental, not a full 255-chunk extraction) is HIMMEL-1097.
# `-6` (unset-only default), NOT `:-6`: an explicitly-empty value stays empty and
# is caught by the validation below, rather than silently defaulting to 6.
# The default stays 6 (not glm-lowered): this script's DEFAULT backend is
# claude-cli (line 45), which is unaffected — lowering the default would 6x-slow
# every non-glm regen for no gain. glm callers pass the knob explicitly, and a
# lower value would not rescue glm anyway when the request quota is exhausted
# (it 429s even serialized, as above). Wiring a throttled default into the glm
# cadence is a separate concern, out of scope for this knob.
GRAPHIFY_MAX_CONCURRENCY="${GRAPHIFY_MAX_CONCURRENCY-6}"
# Validate ONLY on the extraction path (DO_UPDATE=1): the knob feeds the
# --update + cluster-only graphify calls, which a --no-update publish-only run
# never makes — so an invalid value is irrelevant there and must not fail an
# unrelated republish (CR: codex-1).
if [ "$DO_UPDATE" -eq 1 ]; then
  case "$GRAPHIFY_MAX_CONCURRENCY" in
    ''|*[!0-9]*) echo "refresh-graph-map: GRAPHIFY_MAX_CONCURRENCY must be a positive integer (got '$GRAPHIFY_MAX_CONCURRENCY')" >&2; exit 1 ;;
  esac
  [ "$GRAPHIFY_MAX_CONCURRENCY" -ge 1 ] || { echo "refresh-graph-map: GRAPHIFY_MAX_CONCURRENCY must be >= 1 (got '$GRAPHIFY_MAX_CONCURRENCY')" >&2; exit 1; }
fi

# Off-peak advisory (DeepSeek peak-valley UTC 1-4 + 6-10 = 2x). Advisory only —
# a scheduler should aim off-peak; we never hard-refuse (an operator may run ad hoc).
if [ "$BACKEND" = "deepseek" ]; then
  H=$(date -u +%H)
  case "$H" in 01|02|03|06|07|08|09) echo "refresh-graph-map: WARN inside DeepSeek peak window (2x); off-peak resumes 10:00 UTC. Advisory." >&2 ;; esac
fi

OUT_DIR="$CORPUS_ROOT/graphify-out"
REPORT="$OUT_DIR/GRAPH_REPORT.md"

# HIMMEL-910: exclusive per-out-dir promote lock. Two overlapping refreshes
# of the SAME out dir (a scheduler firing twice, an operator re-running
# while a prior run is still in flight, ...) had no inter-process
# serialization around the F2 transactional promote block below -- B
# overwriting a .tmp before A renames it (or B's cp landing between A's
# invalidate and A's own cp) could stamp A's graph with B's corpus snapshot,
# or leave the out dir with an artifact triple from two different runs.
# mkdir is atomic (no check-then-create TOCTOU, works on NTFS/Git-Bash
# without relying on O_EXCL) -- same primitive as
# scripts/handover/queue-lock.sh's queue lock (see its header for the full
# mkdir-atomicity rationale). Deliberately smaller here: this is a
# lean-invoke operator/scheduler tool, not the multi-writer armed-session
# coordination queue-lock.sh guards, so no session tokens, heartbeat, or
# arms-registry integration -- just a bounded-wait acquire with stale-by-age
# takeover (a loud stderr trail either way), released on ANY exit (success
# or failure) by the same EXIT trap that cleans up SCRATCH below.
# Residual (accepted, CR r1): a stale-but-ALIVE holder (machine-sleep
# mid-promote) that was taken over can still be INSIDE the promote block
# when it wakes and interleave with the successor -- inherent to fail-open
# stale takeover; the 600s stale floor vs a promote block measured in
# seconds gives the margin. Its RELEASE, however, is owner-tokened (below)
# so it never deletes the successor's lock.
PROMOTE_LOCK="$OUT_DIR/.promote.lock"
PROMOTE_LOCK_TIMEOUT_SECONDS="${GRAPHIFY_PROMOTE_LOCK_TIMEOUT_SECONDS:-120}"
PROMOTE_LOCK_STALE_SECONDS="${GRAPHIFY_PROMOTE_LOCK_STALE_SECONDS:-600}"
PROMOTE_LOCK_HELD=0
PROMOTE_LOCK_TOKEN=""

# _promote_lock_release -- owner-tokened (CR r1 [codex-1]): a former holder
# that was taken over while paused (stale takeover) must NOT, on wake,
# rm -rf the SUCCESSOR's lock -- so release compares the lock's owner file
# against OUR token and only removes on a match; on mismatch it WARNs
# loudly and walks away.
_promote_lock_release() {
  local cur=""
  if [ "$PROMOTE_LOCK_HELD" -eq 1 ]; then
    PROMOTE_LOCK_HELD=0
    [ -d "$PROMOTE_LOCK" ] || return 0
    cur=$(cat "$PROMOTE_LOCK/owner" 2>/dev/null) || cur=""
    if [ "$cur" != "$PROMOTE_LOCK_TOKEN" ]; then
      echo "refresh-graph-map: WARN promote lock $PROMOTE_LOCK was taken over by another refresh while we held it (owner token mismatch) -- not releasing the successor's lock" >&2
      return 0
    fi
    rm -rf "$PROMOTE_LOCK" 2>/dev/null || true
  fi
}

# _promote_lock_takeover <reason> -- SINGLE-WINNER takeover (CR r1
# [codex-adv-1]): atomically SIDELINE the dead lock via a dir rename --
# exactly one contender's mv succeeds; the loser's mv fails and it just
# loops back to the mkdir spin. rm-then-continue was a race: two contenders
# judging the same stale stamp could have the second's rm -rf destroy the
# first's freshly-won lock. NOTE queue-lock.sh's header documents mv-to-
# graveyard as unreliable under concurrent rename on MSYS (spurious rc-0);
# here that is harmless -- mv only picks who prints the trail and reaps the
# sideline, while mkdir stays the sole acquire arbiter, so a spurious
# double-win degrades to a duplicate WARN, never a double-acquire.
_promote_lock_takeover() {
  local sideline="$PROMOTE_LOCK.stale.$$.$RANDOM"
  if mv "$PROMOTE_LOCK" "$sideline" 2>/dev/null; then
    echo "refresh-graph-map: WARN promote lock $PROMOTE_LOCK $1 -- taking over" >&2
    rm -rf "$sideline" 2>/dev/null || true
    return 0
  fi
  return 1
}

# _promote_lock_acquire -- bounded mkdir spin (default 120s, 1s poll) with
# single-winner stale takeover (default 600s, loud on stderr). The lock dir
# carries an "owner" token (release compares against it, above) and an
# "acquired" epoch-seconds file written by the winner right after mkdir,
# read back by a contender to judge staleness -- no filesystem-mtime probe
# needed (portable across NTFS/ext4 without a stat-flag dance). A lock
# whose stamp is missing/unparseable for ~5 consecutive polls (grace window
# covering a healthy winner's mkdir->stamp gap) is treated as a holder that
# crashed before stamping and reclaimed the same way (CR r1) -- otherwise
# such a lock would brick the out dir forever. Returns 1 (never held) once
# the wait budget is exhausted -- the caller exits non-zero rather than
# silently clobbering.
_promote_lock_acquire() {
  local waited=0 missing_polls=0 held_at now age token
  while :; do
    if mkdir "$PROMOTE_LOCK" 2>/dev/null; then
      token="$$-$RANDOM"
      if ! printf '%s\n' "$token" > "$PROMOTE_LOCK/owner" 2>/dev/null; then
        rm -rf "$PROMOTE_LOCK" 2>/dev/null || true
        echo "refresh-graph-map: promote lock acquired but its owner token could not be written ($PROMOTE_LOCK/owner) -- released again, nothing acquired" >&2
        return 1
      fi
      date -u +%s > "$PROMOTE_LOCK/acquired" 2>/dev/null || true
      PROMOTE_LOCK_TOKEN="$token"
      PROMOTE_LOCK_HELD=1
      return 0
    fi
    held_at=$(cat "$PROMOTE_LOCK/acquired" 2>/dev/null) || held_at=""
    case "$held_at" in ''|*[!0-9]*) held_at="" ;; esac
    if [ -n "$held_at" ]; then
      missing_polls=0
      now=$(date -u +%s)
      age=$(( now - held_at ))
      if [ "$age" -ge "$PROMOTE_LOCK_STALE_SECONDS" ]; then
        if _promote_lock_takeover "is stale (age ${age}s >= ${PROMOTE_LOCK_STALE_SECONDS}s)"; then
          continue
        fi
        # lost the takeover to another contender -- fall through and wait.
      fi
    else
      missing_polls=$((missing_polls + 1))
      if [ "$missing_polls" -ge 5 ]; then
        missing_polls=0
        if _promote_lock_takeover "has no readable acquired stamp after a ~5s grace window (holder crashed between mkdir and stamp?)"; then
          continue
        fi
      fi
    fi
    if [ "$waited" -ge "$PROMOTE_LOCK_TIMEOUT_SECONDS" ]; then
      echo "refresh-graph-map: promote lock $PROMOTE_LOCK held by another refresh-graph-map run after ${PROMOTE_LOCK_TIMEOUT_SECONDS}s -- giving up (another refresh is in progress against this out dir)" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

if [ "$DO_UPDATE" -eq 1 ]; then
  command -v "$GRAPHIFY_MAP" >/dev/null 2>&1 || { echo "refresh-graph-map: '$GRAPHIFY_MAP' not on PATH (needed for --update; use --no-update to publish from an existing report)" >&2; exit 2; }
  # F3 (HIMMEL-907): python3 writes the freshness manifest (see stamp step
  # below). Preflight it next to the graphify check so a python3-less box fails
  # BEFORE the scratch copy / paid extraction — never after promoting a new graph.
  command -v python3 >/dev/null 2>&1 || { echo "refresh-graph-map: python3 not found (needed to write manifest.json for freshness verification)" >&2; exit 2; }
  # Fence-safe incremental refresh on a scratchpad COPY (never the live corpus).
  # Always work inside a uniquely-named, launcher-OWNED subdir (PID-suffixed) so
  # we never rm -rf an operator-supplied --scratch that may point at an existing
  # directory holding unrelated data (codex-adv [codex-1]). --scratch names only
  # the PARENT under which the owned workdir is created.
  SCRATCH_PARENT="${SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$SCRATCH_PARENT" || { echo "refresh-graph-map: cannot create scratch parent: $SCRATCH_PARENT" >&2; exit 1; }
  SCRATCH="$SCRATCH_PARENT/graphify-refresh-$NAME-$$"
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  # Clean the owned subdir on ANY exit — a graphify/cluster-only failure (exit 2)
  # otherwise leaks it (CR suggestion). Scoped to the PID-owned dir only.
  trap 'rm -rf "$SCRATCH" 2>/dev/null || true; _promote_lock_release' EXIT
  # pull-before-regenerate (HIMMEL-1050): refresh the corpus from its remote
  # before copying to scratch, so the graph reflects the latest pushed state, not
  # a stale local checkout. Best-effort + advisory: a miss regenerates from the
  # current checkout (a stale-but-present corpus still yields a useful incremental
  # graph). --ff-only stays non-destructive (never a merge commit or a left-behind
  # conflict). Guarded so `set -e` never trips on the miss path.
  #
  # GUARDED (codex-adv-1 on HIMMEL-1049) — pull ONLY when the corpus is BOTH:
  #   (a) the git TOPLEVEL (empty --show-prefix), never a nested corpus whose
  #       pull would mutate an unrelated PARENT repo (a subdir passes
  #       is-inside-work-tree but a pull there updates the whole parent tree); and
  #   (b) a CLEAN tree (empty status --porcelain), never pulling over uncommitted
  #       work the operator/another session is mid-edit on.
  # --show-prefix keeps this Windows-safe (no C:/ vs /c/ path-form comparison).
  #
  # NOT under the promote lock — deliberate (codex-adv-3 + CodeRabbit asked for a
  # lock here; it was tried and REVERTED, and here is why). The promote lock's
  # takeover is AGE-based (PROMOTE_LOCK_STALE_SECONDS): holding it across the
  # pull+copy+extraction — extraction can outlast the stale floor — would let a
  # second refresh judge a STILL-ALIVE holder stale and take over, breaking the
  # very promote exclusivity HIMMEL-910 built (and a heartbeat, or splitting into
  # two holds, each conflicts with that same stale-takeover contract). The lock
  # therefore stays SHORT and promote-only, exactly as designed.
  # The residual it leaves is small and self-healing: only TWO CONCURRENT refreshes
  # of the SAME corpus could interleave a pull against the other's copy, yielding a
  # mixed-revision SCRATCH -> a slightly-off graph, corrected on the next refresh;
  # the promote itself stays serialized, and the scratch manifest always attests
  # exactly what that copy saw (never a lie). What IS hardened below instead — the
  # real teeth of codex-adv-3 — is the pull itself: toplevel-only (never mutate a
  # nested corpus's PARENT repo), clean-tree-only (never pull over uncommitted
  # work), and bounded + non-interactive (never hang).
  # CLEAN-TREE PROBE (CodeRabbit): `git status` must SUCCEED *and* be EMPTY. A
  # FAILED status (permissions, corrupt index, ...) writes nothing to STDOUT, so a
  # bare `[ -z "$(...)" ]` would misread the failure as "clean" and pull over an
  # unknown state. Capture rc via the assignment-in-condition form (set -e exempt).
  # EVERY probe must SUCCEED before its output is tested for emptiness — a failed
  # probe writes nothing to stdout, so a bare `[ -z "$(...)" ]` would read the
  # FAILURE as "empty prefix" (= toplevel) or "empty status" (= clean) and pull
  # over an unknown state (CodeRabbit). Assignment-in-condition captures rc and is
  # set -e exempt.
  # The probe FLAGS matter as much as its rc (public CodeRabbit, HIMMEL-1070):
  # `git status --porcelain` honors the repo/global `status.showUntrackedFiles`
  # setting, so on a machine with `status.showUntrackedFiles=no` a tree full of
  # untracked work reports CLEAN and we pull over it. Submodules are equally
  # suppressible via `status.submoduleSummary`/`diff.ignoreSubmodules`. Force
  # both to the strict setting on the command line, where no config can weaken
  # them: --untracked-files=normal makes untracked files visible again, and
  # --ignore-submodules=none makes dirty submodules count as dirty.
  _corpus_clean() { # -> 0 only if `git status` SUCCEEDS *and* reports nothing
    local out
    out="$(git -C "$CORPUS_ROOT" status --porcelain \
             --untracked-files=normal --ignore-submodules=none 2>/dev/null)" || return 1
    [ -z "$out" ]
  }
  corpus_pullable=0
  if git -C "$CORPUS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if prefix_out="$(git -C "$CORPUS_ROOT" rev-parse --show-prefix 2>/dev/null)" \
       && [ -z "$prefix_out" ]; then
      _corpus_clean && corpus_pullable=1
    fi
  fi
  if [ "$corpus_pullable" = 1 ]; then
    # NEVER RUN THE PULL UNBOUNDED (CodeRabbit-major). This is a best-effort
    # freshness pull, so the safe degradation is to SKIP it — never to risk a hang:
    #   * GRAPHIFY_PULL_TIMEOUT_SECONDS must be a POSITIVE integer; non-numeric or
    #     <=0 DISABLES the pull (an explicit opt-out, not an unbounded run).
    #   * a HARD wall-clock cap requires coreutils `timeout` — absent on stock
    #     macOS, where Homebrew's coreutils installs it as `gtimeout` (CodeRabbit),
    #     so BOTH names are probed. With neither we SKIP rather than pull unbounded
    #     (git's own transport limits bound a STALLED transfer but are not a
    #     wall-clock cap).
    # Belt-and-braces on the bounded path: git's transport limits also abort a
    # stalled transfer early, and GIT_TERMINAL_PROMPT=0 + ssh BatchMode make a
    # credential prompt FAIL FAST instead of hanging. Any miss simply regenerates
    # from the current checkout.
    pull_t="${GRAPHIFY_PULL_TIMEOUT_SECONDS:-60}"
    case "$pull_t" in ''|*[!0-9]*) pull_t=0 ;; esac   # non-numeric -> disabled
    # coreutils timeout: GNU installs `timeout`; Homebrew on macOS installs the
    # g-prefixed `gtimeout` (CodeRabbit) — probe both. Being ON PATH is not
    # enough: the fetch below needs GNU's `-k` (kill-after), which some builds
    # (e.g. older busybox) lack, so FUNCTIONALLY probe `-k` on a trivial command
    # and only accept a binary that actually supports it (CodeRabbit). Without a
    # usable one we SKIP rather than pull unbounded — and say so honestly instead
    # of degrading into a misleading "could not fast-forward" warning.
    timeout_bin=""
    for _t in timeout gtimeout; do
      if command -v "$_t" >/dev/null 2>&1 && "$_t" -k 1 1 true >/dev/null 2>&1; then
        timeout_bin="$_t"; break
      fi
    done
    pull_ok=0
    if [ "$pull_t" -le 0 ]; then
      echo "refresh-graph-map: pull-before-regenerate disabled (GRAPHIFY_PULL_TIMEOUT_SECONDS not a positive integer); regenerating from the current checkout" >&2
    elif [ -z "$timeout_bin" ]; then
      echo "refresh-graph-map: pull-before-regenerate SKIPPED — no 'timeout'/'gtimeout' supporting GNU -k is available to bound the fetch (macOS: brew install coreutils provides gtimeout); refusing to fetch unbounded, regenerating from the current checkout" >&2
    else
      # FETCH (bounded, killable) then MERGE (local, fast, NOT killed) — never a
      # timeout-killed `pull` (CodeRabbit). A `pull` both fetches AND mutates the
      # worktree, so SIGKILLing it mid-flight can strand a half-updated checkout
      # (interrupted merge/checkout, a left-behind index.lock) that we would then
      # silently regenerate from. Splitting them means the only thing the timeout
      # can kill is the NETWORK op, which never touches the worktree (a killed
      # fetch just leaves the object store short of some objects). The worktree
      # mutation is then a purely local `merge --ff-only` against the freshly
      # fetched upstream: fast, offline, and safe to leave unbounded.
      #   -k 5: SIGKILL 5s after SIGTERM so a wedged transport cannot outlive the bound.
      if GIT_TERMINAL_PROMPT=0 "$timeout_bin" -k 5 "$pull_t" \
           git -C "$CORPUS_ROOT" \
             -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$pull_t" \
             -c "core.sshCommand=ssh -o ConnectTimeout=$pull_t -o BatchMode=yes" \
             fetch --quiet >/dev/null 2>&1; then
        # @{u} = the current branch's upstream (empty/absent -> merge fails -> WARN).
        # core.hooksPath=/dev/null: a fast-forward still fires the repo's
        # post-merge hook, which is arbitrary user code and CAN BLOCK — that would
        # hang this unattended refresh (CodeRabbit). We do NOT bound the merge with
        # a kill instead: SIGKILLing a mutating merge is exactly the strand risk we
        # removed by splitting fetch from merge. Disabling hooks keeps it both
        # unhangable and unkilled. Scoped to THIS internal, automated
        # fast-forward only (it is not a user-authored commit/push), and it also
        # stops a post-merge graph-refresh hook (HIMMEL-1050) recursing into us.
        # RE-PROBE (public CodeRabbit, HIMMEL-1070): the clean-tree probe above
        # ran BEFORE the fetch, and the fetch is a bounded NETWORK op that can
        # take the better part of a minute. In that window the operator (or a
        # parallel session) can start editing the corpus — this refresh is
        # unattended and fires on a schedule, so that overlap is routine, not
        # exotic. Merging on the stale verdict would fast-forward the worktree
        # out from under live work. The fetch itself never touches the worktree,
        # so re-checking here costs one local `git status` and makes the
        # clean-tree guarantee hold at the moment it is actually load-bearing.
        if _corpus_clean; then
          git -C "$CORPUS_ROOT" -c core.hooksPath=/dev/null merge --ff-only '@{u}' >/dev/null 2>&1 && pull_ok=1
        fi
      fi
      if [ "$pull_ok" = 1 ]; then
        echo "refresh-graph-map: fast-forwarded $CORPUS_ROOT to its upstream before regenerating" >&2
      else
        echo "refresh-graph-map: WARN could not fast-forward $CORPUS_ROOT (no upstream, offline, fetch timed out, diverged, or the tree went dirty during the fetch); regenerating from the current checkout" >&2
      fi
    fi
  else
    echo "refresh-graph-map: pull-before-regenerate skipped for $CORPUS_ROOT (not a clean git toplevel); regenerating from the current checkout" >&2
  fi
  # Copy only markdown (matches the extraction corpus); carry the fence marker.
  # No 2>/dev/null on find — a scan failure (permission/IO) is aborted by
  # set -euo pipefail, and find's own stderr is the ONLY diagnostic for it (CR).
  #
  # STREAMED, not per-file (HIMMEL-1103). This was a `while read` loop running
  # dirname + mkdir -p + cp PER FILE — three process spawns each. Windows process
  # creation is expensive, so staging the luna vault (15,235 md files) measured
  # ~1.8 files/sec => ~130 MINUTES of copying before extraction even started; the
  # daily HIMMEL-829 cadence firing at 13:00 was still copying at ~15:10. tar
  # streams the same file set in ONE pass (3 processes, not ~45k) and preserves
  # the relative layout, so the scratch mirrors the corpus exactly as before.
  # --null -T - consumes find's -print0 list verbatim, so the predicate and the
  # graphify-out exclusion are byte-identical to the loop's — no re-globbing, and
  # filenames with spaces/newlines stay safe. GNU tar and macOS's bsdtar both
  # accept `--null -T -`.
  # pipefail keeps the failure contract: a find/tar failure at ANY stage fails the
  # pipeline and trips the || below, so a partial corpus can never be silently
  # extracted into a confidently-wrong graph.
  # NOTE tar preserves source mtimes where cp stamped copy-time. The manifest
  # below carries mtimes as free-form provenance only (the guard reads its KEYS,
  # never these values), so nothing depends on the old behaviour — and the
  # preserved mtime is the more honest provenance of what the graph actually saw.
  # -type f is LOAD-BEARING for the tar form (CodeRabbit): `-name '*.md'` also
  # matches DIRECTORIES, and tar -T RECURSES into a directory entry — so a dir
  # named `foo.md` would drag its entire non-md subtree into the corpus and thus
  # into the graph. The old per-file `cp` could not do that (it just failed on a
  # directory), so this predicate is what keeps the streamed form equivalent.
  # Both corpora are 100% regular files today (luna 15,239 / himmel 9,114, zero
  # dirs or symlinks named *.md), so this is a no-op on current data and a guard
  # against a silently-wrong corpus later.
  ( cd "$CORPUS_ROOT" && find . -type f -name '*.md' -not -path './graphify-out/*' -print0 \
      | tar --null -T - -cf - ) | ( cd "$SCRATCH" && tar -xf - ) \
    || { echo "refresh-graph-map: corpus scan/copy failed (see find/tar output above)" >&2; exit 1; }
  printf '%s\n' "$CORPUS_CLASS" > "$SCRATCH/.graphify-corpus"
  # CLEAR THE CLAUDE REROUTE SELECTORS before dispatching (HIMMEL-1070,
  # codex-adv-1). graphify-fence.sh hard-denies these, but the fence is a
  # PreToolUse hook — it only sees graphify invocations an AGENT types. THIS
  # script is fired directly by cron/schtasks (graphmap-cadence.sh), so the
  # fence never runs on the scheduled path: an inherited CLAUDE_CODE_USE_BEDROCK
  # would send corpus content to AWS with nothing to stop it, and the hard-deny
  # we document would be true only for the interactive path. Clearing them here
  # makes the property hold where the extraction actually happens. This is
  # exactly what himmel's own scripts/claude-codex does with the same variables,
  # for the same "would silently reroute the session away" reason.
  # Clearing (not refusing) keeps a Bedrock/Vertex-configured operator's cadence
  # working on the intended provider, and fails LOUDLY if their CLI genuinely
  # cannot auth without the reroute — never silently to another cloud. Harmless
  # for non-claude backends, which do not read these at all.
  unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  unset CLAUDE_CODE_USE_GATEWAY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_ANTHROPIC_AWS
  # RESIDUAL, tracked as HIMMEL-1084 (codex-adv round 2): ANTHROPIC_BASE_URL and
  # the Anthropic credentials still pass through, so a scheduled run launched
  # from a routed environment can still reach a gateway with no matrix eval and
  # no ledger line. NOT blanket-cleared here on purpose — that would break two
  # SUPPORTED configs: `--backend claude` is the API path and NEEDS
  # ANTHROPIC_API_KEY, and zai-glm is a ratified matrix provider whose
  # luna-clippings cell the matrix explicitly allows. Clearing them would
  # override an allowed configuration rather than enforce the policy. The real
  # fix is an in-script preflight running the SAME matrix eval the fence runs —
  # a design surface, hence its own ticket.
  echo "refresh-graph-map: incremental update on scratchpad copy ($SCRATCH) backend=$BACKEND" >&2
  # HIMMEL-128 billing note (NOT a gate marker — see below). Under the default
  # BACKEND (claude-cli) graphify shells the claude CLI headlessly from inside
  # these two dispatches, so this unattended refresh does bill on the separate
  # headless bucket. That is approved for the graphmap cadence: it is a
  # scheduled, no-session extraction whose entire point is running without an
  # interactive harness, and the alternative (a paid API backend) is precisely
  # what the claude-cli backend exists to avoid.
  # Deliberately NOT a `headless-claude-ok:` marker (HIMMEL-1070, public CR
  # thread): the no-headless-claude gate matches `claude` + `-p|--print|--bg` in
  # THIS repo's shell, and these lines invoke `graphify`. The gate never fires
  # here, so a marker would suppress nothing and would imply an enforcement that
  # does not exist. (It also matches PROSE - an earlier cut of this very comment
  # tripped the gate by containing the literal flag, so the marker would only
  # have been suppressing itself.) The real control for what those nested calls
  # can reach is the reroute-selector clearing above + the egress fence.
  "$GRAPHIFY_MAP" "$SCRATCH" --update --backend "$BACKEND" --max-concurrency "$GRAPHIFY_MAX_CONCURRENCY" --api-timeout 300 >&2 || { echo "refresh-graph-map: graphify --update failed" >&2; exit 2; }
  "$GRAPHIFY_MAP" cluster-only "$SCRATCH" --backend "$BACKEND" --max-concurrency "$GRAPHIFY_MAX_CONCURRENCY" >&2 || { echo "refresh-graph-map: cluster-only failed" >&2; exit 2; }
  # HIMMEL-907: stamp freshness artifacts so the companion guard
  # check-graph-freshness.sh can VERIFY this graph (not "fresh by age" only).
  # Source-of-truth for shape is the guard's parser: manifest.json = flat
  # non-empty JSON object of corpus-relative path -> {mtime} (the parser uses
  # the KEYS to prove the corpus still exists; values are free-form, so we carry
  # the file mtime as honest provenance — stored as an INT epoch for compact,
  # human-greppable provenance — and invent nothing else); .graphify_root =
  # first non-blank line is the corpus root. graphify itself emits no manifest,
  # so we synthesize one from the same corpus predicate the extraction copy used
  # (find -name '*.md' -not -path './graphify-out/*'). A zero-md corpus stamps
  # `{}`, which the guard rejects with rc=2 — fail-loud by design, no
  # special-casing. Only written on a SUCCESSFUL refresh — this branch is reached
  # solely after graphify --update + cluster-only both succeeded; a failed run
  # exits above before reaching here, so we never stamp a failed run as fresh.
  #
  # F1: walk the SCRATCH copy (the exact corpus the graph saw), NOT the live
  # corpus — a file added/removed mid-extraction would otherwise make
  # manifest.json attest a corpus state the graph never saw. The scratch's own
  # graphify-out is pruned so GRAPH_REPORT.md doesn't leak into the keys. Keys
  # stay corpus-relative (scratch mirrors the corpus's relative md layout).
  #
  # F2: transactional promote so any interruption (disk full, kill, python3
  # gone mid-run, ...) leaves a stamp-LESS out dir the guard fails closed on —
  # never a NEW graph beside OLD stamps. Order: build the new manifest into a
  # tmp name -> invalidate the old stamps -> promote the derived graph ->
  # atomically install the new stamps (same-dir mv + marker write).
  mkdir -p "$OUT_DIR"
  # (CORPUS_ROOT_ABS removed with HIMMEL-1116 — the .graphify_root marker is now
  # relative, and that assignment was its only consumer.)
  OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"
  SCRATCH_ABS="$(cd "$SCRATCH" && pwd)"
  # HIMMEL-910: acquire the exclusive per-out-dir lock (see its definition
  # above) around the WHOLE promote block that follows -- steps 1-4 below
  # must run as one atomic unit relative to any OTHER refresh-graph-map
  # promoting into this same out dir. Acquired HERE (not earlier, around the
  # pull/extraction -- see the pull note above for why a long hold breaks the
  # age-based stale takeover) so the hold stays SHORT. exit 2 matches the
  # graphify/cluster-only failure exit code above (a refuse-to-clobber is a
  # fence/tooling failure, not a usage error).
  _promote_lock_acquire || exit 2
  # Test-only hook (HIMMEL-910): hold the lock for N seconds before doing any
  # promote work, so a concurrency test can create a deterministic overlap
  # window. No-op unless set.
  if [ -n "${GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS:-}" ]; then
    sleep "$GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS"
  fi
  # HIMMEL-1134 CR follow-up round 5: sanitize + guard-scan now run on the
  # SCRATCH artifacts (staging), BEFORE anything in $OUT_DIR is touched.
  # Previously this block invalidated the old manifest.json/.graphify_root
  # stamps and cp'd the new graph.json/GRAPH_REPORT.md into the TRACKED
  # $OUT_DIR first, then sanitized + guard-scanned those PROMOTED copies --
  # so a REJECTED (leaking) refresh had already (a) invalidated the prior
  # stamps and (b) written leaked bytes into graphify-out/ before the
  # guard's `exit 2` ever ran. The reject still failed closed on PUBLISH
  # (nothing shipped to the vault's 60-Maps), but the tracked out dir was
  # left holding leaked bytes a later `git add -A` could commit, and the
  # corpus's prior-good stamps were gone. Scanning the scratch copies gives
  # IDENTICAL coverage (byte-for-byte what would be promoted) while
  # guaranteeing $OUT_DIR's prior clean artifacts + stamps are completely
  # untouched on rejection.
  SCRATCH_REPORT="$SCRATCH/graphify-out/GRAPH_REPORT.md"
  SCRATCH_GRAPH="$SCRATCH/graphify-out/graph.json"
  # HIMMEL-1134 CR follow-up (CodeRabbit App, PR #1274): assert BOTH staging
  # artifacts exist BEFORE the sanitize/guard even start. Without this, a
  # missing graph.json (or report) would fall through every check below --
  # `head ... 2>/dev/null || true` silently swallows the read failure, the
  # `case` has no default so an empty/garbage header just skips the
  # sanitize, and the scan loop's (now-removed) `[ -f ] || continue` would
  # skip a missing artifact rather than refuse -- letting a malformed
  # staging area reach $OUT_DIR mutation before some LATER cp happened to
  # fail, defeating the round-5 preservation guarantee this whole reorder
  # exists for.
  for required_artifact in "$SCRATCH_REPORT" "$SCRATCH_GRAPH"; do
    if [ ! -f "$required_artifact" ]; then
      echo "refresh-graph-map: missing required scratch artifact ${required_artifact##*/}" >&2
      exit 2
    fi
  done
  # HIMMEL-1134: sanitize the scratch report's HEADER, before promotion.
  # graphify titles GRAPH_REPORT.md by the EXTRACTION path -- here that's
  # $SCRATCH, a PID-suffixed scratchpad dir = the operator's home dir +
  # username -- and that header would otherwise land in a TRACKED,
  # public-mirrored artifact (graphify-out/ went tracked in HIMMEL-1123).
  # Rewrite line 1 to carry the corpus NAME instead, preserving a trailing
  # " (YYYY-MM-DD)" stamp if present. Matched on the generic
  # `# Graph Report - <anything>` SHAPE, not the specific scratch string
  # (MSYS vs Windows give different separator forms). awk, not
  # sed/parameter-expansion: $NAME lands as an awk -v value (no
  # regex-replacement escaping of & or \ to worry about).
  if ! report_line1="$(head -n 1 "$SCRATCH_REPORT" 2>/dev/null)"; then
    echo "refresh-graph-map: failed to read report header" >&2
    exit 2
  fi
  case "$report_line1" in
    '# Graph Report - '*)
      report_date="$(printf '%s\n' "$report_line1" | grep -oE '\([0-9]{4}-[0-9]{2}-[0-9]{2}\)$' || true)"
      if [ -n "$report_date" ]; then
        report_header="# Graph Report - $NAME  $report_date"
      else
        report_header="# Graph Report - $NAME"
      fi
      # HIMMEL-1134 CR follow-up round 4: explicit success/failure branches,
      # not `awk ... && mv` -- under `set -euo pipefail` a command on the
      # LEFT of `&&` is EXEMPT from set -e, so an awk failure there would
      # short-circuit the `&&` (skipping the mv) and fall through SILENTLY.
      # Fail loudly on either awk or mv failing, and clean up the tmp file
      # on both paths (belt-and-braces -- it now lives inside $SCRATCH, so
      # the EXIT trap's `rm -rf "$SCRATCH"` would also catch it).
      if awk -v h="$report_header" 'NR==1 { print h; next } { print }' "$SCRATCH_REPORT" > "$SCRATCH_REPORT.tmp"; then
        if ! mv "$SCRATCH_REPORT.tmp" "$SCRATCH_REPORT"; then
          echo "refresh-graph-map: failed to install sanitized report header" >&2
          rm -f "$SCRATCH_REPORT.tmp"
          exit 2
        fi
      else
        echo "refresh-graph-map: failed to sanitize report header (awk)" >&2
        rm -f "$SCRATCH_REPORT.tmp"
        exit 2
      fi
      ;;
    *)
      # HIMMEL-1134 CR follow-up (CodeRabbit App, PR #1274): the `case`
      # previously had no default -- an unexpected header format (not
      # starting with the fixed `# Graph Report - ` prefix graphify always
      # emits) silently SKIPPED the sanitize and fell through to the guard
      # with whatever line 1 already was. Fail loudly instead: a header
      # this script doesn't recognize is itself a signal something is
      # wrong upstream (empty/corrupted report, a different tool's output,
      # ...), not a shape to quietly pass through.
      echo "refresh-graph-map: failed to sanitize report header (unexpected format)" >&2
      exit 2
      ;;
  esac
  # HIMMEL-1134: host-path GUARD, failing LOUDLY, BEFORE any $OUT_DIR
  # mutation (CR follow-up round 5). The sanitize above only touches line 1
  # -- a leak elsewhere in the report (or in graph.json) would otherwise
  # ship silently until a reviewer happened to catch it by eye. Scan both
  # SCRATCH artifacts about to be promoted for a host-path SHAPE (case
  # insensitive): a Users dir (POSIX or Windows-drive form, either slash
  # direction), a bare \Users\, a /home/<user>/ dir, or an AppData PATH
  # SEGMENT -- PLUS explicit JSON-escaped double-backslash alternatives
  # (graph.json is JSON, so a Windows path in it is serialized with each
  # backslash doubled, e.g. C:\\Users\\name). The single-backslash
  # drive-letter alternative above ([A-Za-z]:\Users\, anchored right after
  # the colon) does NOT match that doubled form; the bare \Users\
  # alternative already happens to catch most doubled-backslash cases too (a
  # run of 2 backslashes contains 1 as a substring), but the explicit
  # doubled-backslash alternatives make that coverage textual instead of
  # incidental, so it survives if the bare alternative is ever narrowed or
  # removed. AppData is bounded by path delimiters -- (^|[/\])AppData([/\]|$)
  # -- rather than a bare substring: an UNBOUNDED "AppData" would false-
  # positive-refuse a clean refresh over a legit node name or prose mentioning
  # it (e.g. "MyAppDataStore", "AppData sync"), which have no delimiter
  # immediately before/after the word (CR-caught, HIMMEL-1134 follow-up). A
  # hit refuses the promote -- same exit-2 convention as the
  # graphify/cluster-only and lock-acquire failures above (a leak
  # fence-tripping is a tooling failure, not a usage error).
  leak_pattern='(/Users/|[A-Za-z]:\\Users\\|[A-Za-z]:/Users/|\\Users\\|[A-Za-z]:\\\\Users\\\\|\\\\Users\\\\|/home/[^/]+/|(^|[/\\])AppData([/\\]|$))'
  # The upfront existence check above already guarantees both artifacts are
  # present, so no `[ -f ] || continue` skip is needed here (CR follow-up,
  # CodeRabbit App PR #1274 -- that skip is now dead code the existence
  # check made redundant, and a redundant skip is one more place a real gap
  # could silently hide).
  for leak_artifact in "$SCRATCH_REPORT" "$SCRATCH_GRAPH"; do
    # basenamed (CR follow-up round 5): the FULL path (now under $SCRATCH,
    # previously $OUT_DIR/graph.json) can itself carry the corpus/home path
    # -- error messages below print only the filename, never the full path.
    leak_artifact_name="${leak_artifact##*/}"
    # -m1: grep stops after its OWN first match (rc 0 hit / rc 1 miss) -- no
    # pipe to `head`, so no SIGPIPE. Under `set -o pipefail` (line 30), a
    # `grep | head -n 1` pipeline where grep gets SIGPIPE'd by head closing
    # early reports a NON-ZERO pipeline rc even on a real match, which made
    # `&&` short-circuit past the `exit 2` below -- the guard failed OPEN on
    # exactly the leaks with a second match past the closed pipe (CR-caught,
    # HIMMEL-1134 follow-up).
    #
    # grep has THREE exit statuses, not two (CR-caught, HIMMEL-1134 follow-up
    # round 3): 0 = match, 1 = no match, >1 = SCAN ERROR (unreadable
    # artifact, bad regex, out of memory, ...). `leak_line=$(...) && [ -n ]`
    # treated rc>1 the same as rc 1 (no match) -- a scan the guard couldn't
    # even perform was silently read as "clean", so a real leak in an
    # artifact grep failed to read would still ship. Capture the rc
    # explicitly (`|| grep_rc=$?` stays set -e safe) and fail CLOSED on
    # rc>1, distinct from the rc-0 leak-found path.
    #
    # -a (--binary-files=text, CR follow-up, CodeRabbit App PR #1274): a NUL
    # byte anywhere in the artifact flips GNU grep into "Binary file
    # matches" mode, which drops the line-number extraction this guard's
    # error message depends on and makes a real leak's detectability
    # unpredictable on adversarial/binary content. Force text mode instead
    # -- both artifacts are supposed to be text (a report is markdown, the
    # graph is JSON), so treating a NUL as just another byte is correct
    # here, not a workaround.
    leak_line=""
    grep_rc=0
    leak_line="$(grep -a -m1 -inE "$leak_pattern" "$leak_artifact")" || grep_rc=$?
    if [ "$grep_rc" -eq 0 ]; then
      # HIMMEL-1134 CR follow-up: do NOT echo $leak_line -- it's the matched
      # grep line, i.e. it CONTAINS the leaked host path. Printing it here
      # would have the guard leak the very secret it's refusing to promote,
      # straight into stderr (and from there into CI logs / captured
      # output). Report only the file NAME + the line NUMBER (grep's own
      # "N:..." prefix, stripped at the first colon).
      leak_line_number="${leak_line%%:*}"
      echo "refresh-graph-map: REFUSING to promote -- host path detected in $leak_artifact_name at line $leak_line_number" >&2
      exit 2
    elif [ "$grep_rc" -gt 1 ]; then
      echo "refresh-graph-map: REFUSING to promote -- leak SCAN FAILED for $leak_artifact_name (grep rc=$grep_rc)" >&2
      exit 2
    fi
    # grep_rc -eq 1: no leak found in this artifact, continue.
  done
  # ONLY past this point (guard passed clean) does anything in $OUT_DIR
  # change -- everything above ran against $SCRATCH only.
  # 1. build the new manifest from the scratch corpus into a tmp name (atomic
  #    content write is fine — it's a tmp name, not the stamp itself).
  python3 - "$SCRATCH_ABS" "$OUT_DIR_ABS" <<'PYEOF'
import json, os, sys
root, out = sys.argv[1], sys.argv[2]
scratch_out = os.path.join(root, "graphify-out")
manifest = {}
for dirpath, dirs, files in os.walk(root):
    # prune the derived out dir graphify wrote into the scratch so it doesn't
    # leak GRAPH_REPORT.md into the manifest keys.
    dirs[:] = [d for d in dirs if os.path.join(dirpath, d) != scratch_out]
    for fn in files:
        if not fn.endswith(".md"):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, root).replace(os.sep, "/")
        try:
            mtime = int(os.path.getmtime(full))
        except OSError:
            mtime = 0
        manifest[rel] = {"mtime": mtime}
with open(os.path.join(out, ".manifest.tmp"), "w") as fh:
    json.dump(manifest, fh, sort_keys=True)
    fh.write("\n")
PYEOF
  # 2. INVALIDATE the old stamps so a half-promoted out dir is never mistaken
  #    for fresh (no manifest marker <-> guard fails closed).
  rm -f "$OUT_DIR/manifest.json" "$OUT_DIR/.graphify_root"
  # 3. promote the (already sanitized + guard-scanned) derived artifacts into
  #    the corpus's repo-local out.
  cp "$SCRATCH_GRAPH" "$OUT_DIR/graph.json"
  cp "$SCRATCH_REPORT" "$REPORT"
  # 4. STAMP: same-dir rename = atomic install of the manifest, then (re)write
  #    the marker. The guard joins the corpus-relative manifest keys against the
  #    resolved corpus root.
  #
  #    .graphify_root is RELATIVE (".") — not CORPUS_ROOT_ABS (HIMMEL-1116).
  #    OUT_DIR is always <corpus>/graphify-out, so the guard's relative branch
  #    (`CORPUS_RESOLVED="$OUT/../$MARKER_ROOT"`) resolves "$OUT/../." == the
  #    corpus root on EVERY machine. An absolute marker only works on the host
  #    that wrote it: the derived graph is now a tracked, SHARED artifact
  #    (HIMMEL-1123 — stations that cannot afford extraction pull it instead of
  #    building it), so a marker carrying THIS host's path would make the guard
  #    resolve a non-existent corpus on win2, fail closed "corpus orphaned", and
  #    tell that station to rebuild the very graph we shipped it to avoid
  #    rebuilding. The guard already supported relative markers; nothing there
  #    changes.
  mv "$OUT_DIR/.manifest.tmp" "$OUT_DIR/manifest.json"
  printf '%s\n' "." > "$OUT_DIR/.graphify_root"
  # CR r2 [codex-adv-r2]: do NOT release here -- the publish step below
  # READS $REPORT from the shared out dir, and a second refresh's promote
  # overwrites it with a non-atomic cp; releasing before that read let a
  # truncated/mixed report be published despite the serialized promote.
  # The lock is held THROUGH publish and released after it (the EXIT trap
  # stays the failure-path backstop).
  rm -rf "$SCRATCH"   # eager clean on success; the EXIT trap is the failure-path backstop
  # Test-only hook (CR r2): hold between promote and publish, so the
  # promote-vs-publish overlap test can create a deterministic window.
  # No-op unless set.
  if [ -n "${GRAPHIFY_PUBLISH_TEST_HOLD_SECONDS:-}" ]; then
    sleep "$GRAPHIFY_PUBLISH_TEST_HOLD_SECONDS"
  fi
fi

# CR r2 [codex-adv-r2]: the --no-update path publishes by READING the same
# shared $REPORT a concurrent full refresh WRITES (non-atomic cp) -- take
# the same lock so reader-vs-writer is serialized in both directions (the
# update path arrives here already holding it). Same timeout/exit-2
# semantics as the writer side. mkdir -p: the lock dir lives inside
# $OUT_DIR, and a publish-only run against a never-refreshed corpus must
# still reach the "no report" exit-1 below instead of spinning on an
# uncreatable lock.
if [ "$DO_UPDATE" -eq 0 ]; then
  mkdir -p "$OUT_DIR"
  trap '_promote_lock_release' EXIT
  _promote_lock_acquire || exit 2
fi

[ -f "$REPORT" ] || { echo "refresh-graph-map: no GRAPH_REPORT.md at $REPORT (run without --no-update, or generate one first)" >&2; exit 1; }

# Publish the curated MOC into the vault's 60-Maps (the tracked artifact).
OUT_NOTE="$MAPS_DIR/$SLUG.md"
node "$REPO_ROOT/scripts/graphify/publish-graph-map.mjs" \
  --report "$REPORT" --out "$OUT_NOTE" --title "$TITLE" --slug "$SLUG" \
  ${CORPUS_TAG:+--corpus "$CORPUS_TAG"} --source-graph "graphify-out/graph.json"

_promote_lock_release   # eager release after the report is fully consumed; EXIT trap = backstop
echo "refresh-graph-map: published $OUT_NOTE" >&2
