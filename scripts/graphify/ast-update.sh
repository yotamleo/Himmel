#!/usr/bin/env bash
# ast-update.sh — HIMMEL-1948 CR r1b: serialize the hourly free structural
# (AST) graphify refresh against refresh-graph-map.sh's per-out-dir promote
# lock (HIMMEL-910).
#
# WHY: the hourly structural cadence leg used to fire bare `graphify update
# <corpus> --force` directly, writing straight into <corpus>/graphify-out --
# the SAME directory the weekly semantic leg writes through
# refresh-graph-map.sh, which guards that directory with an exclusive
# mkdir-based promote lock. The AST leg bypassed that lock entirely, and the
# schedules overlap by construction (luna semantic fires Sunday 13:00, luna
# AST fires :05 past every hour, landing inside a still-running semantic
# refresh at 13:05 Sunday) -- distinct scheduler tasks are not otherwise
# serialized, so last-writer-wins could discard the freshly-built semantic
# layer. This wrapper takes the SAME lock, protocol-compatibly, before
# touching graphify-out.
#
# PROTOCOL: mirrors refresh-graph-map.sh's _promote_lock_acquire/_release
# EXACTLY (same $OUT_DIR/.promote.lock SHAPE, same mkdir-is-the-atomic-arbiter,
# same owner token file, same "acquired" epoch stamp) so the two sides
# interoperate. Read refresh-graph-map.sh's _promote_lock_acquire header
# before touching this file -- duplication of that protocol here (rather than
# a shared lib) is an accepted, documented cost (see commit body); refresh-
# graph-map.sh itself is NOT modified.
#
# OUT_DIR resolution honours GRAPHIFY_OUT (graphify/paths.py: GRAPHIFY_OUT =
# os.environ.get("GRAPHIFY_OUT", "graphify-out"), read by graphify itself at
# import time) exactly the way `graphify update <corpus-root>` resolves its
# OWN output dir (watch.py: out = watch_path / GRAPHIFY_OUT) -- a relative
# name joins under corpus-root, an absolute path is used as-is (Python's `/`
# join semantics on an absolute rhs discard the lhs entirely; mirrored below
# with a bash case). A lock taken on a hardcoded <corpus-root>/graphify-out
# when GRAPHIFY_OUT points elsewhere would guard a directory nobody is
# writing to -- false serialization, worse than none because it LOOKS
# correct. The divergence this header used to warn about is CLOSED as of
# HIMMEL-1960: refresh-graph-map.sh now resolves the same GRAPHIFY_OUT for
# its OUT_DIR, promote lock and corpus exclusion. One asymmetry remains by
# design -- it accepts only the RELATIVE form and refuses an ABSOLUTE
# GRAPHIFY_OUT outright, because it extracts into a scratch copy and
# promotes, and an absolute out dir would bypass both. So under an absolute
# override the semantic leg does not run at all rather than writing a
# directory this one is not locking; see that script's OUT_DIR block.
#
# POLICY DIFFERENCE from refresh-graph-map.sh's acquire: SKIP-not-wait. The
# semantic side does a bounded spin (default 120s) because a stuck reader is
# worth waiting out; the hourly structural leg is cheap (seconds) and fires
# again in 60 minutes, so waiting buys nothing and risks stacking hourly runs
# behind a long semantic extraction. Up to three mkdir attempts, retried only
# while the lock dir is ABSENT (HIMMEL-1960 -- a retry there distinguishes "the
# holder released in the window" from a real path failure; a lock that is
# actually present is never waited on): held -> skip
# LOUDLY (distinct exit 4, never exit 0 -- a skip that reads as success is
# the exact failure mode HIMMEL-1948 exists to eliminate); free -> acquire,
# stamp, run, release on ANY exit (owner-tokened, so a takeover by the
# semantic side while we're gone is never clobbered by our own release).
#
# --force is DELIBERATE and stays (do not "fix" this, HIMMEL-1938): `graphify
# update` silently refuses to overwrite graph.json when the rebuild has fewer
# nodes unless --force is given -- that silent refusal caused a month of
# unnoticed graph staleness. Dropping --force here would reintroduce it on an
# unattended hourly cadence, where nobody is watching even less.
#
# Usage: ast-update.sh <corpus-root>
#
# Exit: 0 ok (graphify update ran and succeeded); 1 usage error; 2 lock
#   housekeeping failure (owner token could not be written); 3 FAILED -- a
#   genuine filesystem error acquiring or stamping the lock (CORPUS_ROOT does
#   not exist or is not a directory, OUT_DIR could not be created, the lock
#   mkdir failed AND a probe directory could not be created in OUT_DIR either
#   -- permissions, a bad GRAPHIFY_OUT path, a read-only mount, etc; a lock
#   that merely came and went during acquire is contention and reports 4 -- or the
#   mandatory "acquired" stamp could not be written, in which case the lock
#   is released before exiting); 4 SKIPPED --
#   promote lock held by a concurrent (semantic) refresh, nothing run this
#   time (skip-not-wait; retried automatically on this corpus's next scheduled
#   structural run -- hourly for himmel, DAILY for luna since HIMMEL-1960, so
#   this wrapper must not promise an hour); 5 FAILED --
#   `graphify update` itself ran and exited non-zero (its real exit code is
#   logged to stderr, NEVER reused as this script's own exit status). Exit 3
#   is deliberately DISTINCT from exit 4: a real filesystem failure must
#   never be reported as the benign "lock held, retry next run" skip -- that
#   is the exact false-benign failure class HIMMEL-1948 exists to eliminate
#   (see graph-refresh.sh's own OK-on-bank-skip history). Exit 5 exists for
#   the SAME reason on the other side of the call: `graphify update` can
#   itself exit 4 (or any other code) for reasons of its own, and propagating
#   that unchanged used to let a genuine graphify failure masquerade as this
#   script's benign lock-skip -- so ANY non-zero graphify exit is remapped to
#   the fixed sentinel 5 here, never propagated as-is. Exit 4 mirrors
#   graph-refresh.sh's HIMMEL-1948 exit-4-means-skipped convention.
set -euo pipefail

CORPUS_ROOT="${1:-}"
if [ -z "$CORPUS_ROOT" ]; then
  echo "usage: ast-update.sh <corpus-root>" >&2
  exit 1
fi

# CR (HIMMEL-1948): a typoed/nonexistent CORPUS_ROOT used to be silently
# accepted here -- `mkdir -p "$OUT_DIR"` below happily creates the whole path
# tree, so `graphify update` then runs (successfully, exit 0) against a
# directory containing nothing, forever, while the real corpus's graph goes
# stale unalerted. That is the exact false-benign "silently not-done" class
# exit 3/4/5 exist to eliminate. Fail LOUDLY before creating anything: the
# corpus root must already exist (OUT_DIR underneath it need not -- that's
# what mkdir -p is for).
if [ ! -d "$CORPUS_ROOT" ]; then
  echo "ast-update: FAILED -- CORPUS_ROOT=$CORPUS_ROOT does not exist (or is not a directory) -- this is a real filesystem failure, NOT a lock-held skip; exiting 3, not 4" >&2
  exit 3
fi

# Resolve the SAME out dir graphify itself will write to (see GRAPHIFY_OUT
# note above): a relative GRAPHIFY_OUT joins under corpus-root (default:
# "graphify-out" -> "$CORPUS_ROOT/graphify-out"); an absolute path (POSIX
# "/..." or a Windows drive letter "C:/..."/"C:\...") is used as-is.
# `${VAR-default}`, NOT `${VAR:-default}` (CR r5): upstream's
# `os.environ.get("GRAPHIFY_OUT", "graphify-out")` defaults only on ABSENT and
# preserves an exported empty string, which pathlib joins away so graphify
# writes the corpus root itself. `:-` would substitute "graphify-out" and lock a
# directory nobody is writing. Preserving the empty value makes OUT_DIR
# "$CORPUS_ROOT/", i.e. the corpus root -- the same place graphify picks.
_graphify_out_name="${GRAPHIFY_OUT-graphify-out}"
# An EMPTY GRAPHIFY_OUT is refused here too (CR r9). Upstream would resolve it
# to the corpus root itself -- pathlib joins an empty segment away -- so
# honouring it means running graphify against a corpus whose "out dir" IS the
# corpus, scattering graph.json/manifest.json/cache into the source tree and
# taking the promote lock at <corpus>/.promote.lock. An earlier revision kept
# it on the grounds that matching upstream is what keeps the two legs on one
# directory. That reasoning was wrong: what the two legs must agree on is the
# directory they operate on, and BOTH refusing is agreement. The semantic side
# already refuses an empty value via its name check, so refusing here keeps
# them consistent AND stops the write. An empty value is a misconfiguration,
# not a mode.
if [ -z "$_graphify_out_name" ]; then
  echo "ast-update: FAILED -- GRAPHIFY_OUT is set but EMPTY, which would resolve the out dir to the corpus root itself and write graph artifacts into the source tree. Unset it, or set a directory name. Exiting 3, not 4" >&2
  exit 3
fi
case "$_graphify_out_name" in
  /*|[A-Za-z]:[/\\]*) OUT_DIR="$_graphify_out_name" ;;
  *)
    # A RELATIVE override must be a single directory NAME, matching what
    # refresh-graph-map.sh accepts (CR r12). Without this the legs disagreed
    # again: `GRAPHIFY_OUT=foo/bar` was refused by the semantic leg's name
    # check while this one kept updating, so semantic refreshes would fail
    # forever with the structural leg looking healthy. `../out` was worse than
    # a disagreement -- it resolves OUTSIDE the corpus root, so the lock and
    # the write would land somewhere the operator never named. The absolute
    # form stays supported: this leg runs graphify in place and can honour it.
    if ! printf '%s' "$_graphify_out_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
      echo "ast-update: FAILED -- a relative GRAPHIFY_OUT must be a single directory name matching [A-Za-z0-9][A-Za-z0-9._-]* (got '$_graphify_out_name'); refresh-graph-map.sh applies the same rule, and a multi-segment or dot-dot value would put the two cadence legs on different directories. Exiting 3, not 4" >&2
      exit 3
    fi
    OUT_DIR="$CORPUS_ROOT/$_graphify_out_name" ;;
esac
# Refuse to write into somebody's SOURCE directory (CR r10). The semantic leg
# gained this guard first; without the mirror, GRAPHIFY_OUT=docs made the two
# legs DISAGREE -- the semantic side refusing while this one happily ran
# `graphify update` and scattered graph.json/manifest.json into <corpus>/docs.
# The whole point of resolving GRAPHIFY_OUT identically is that both legs act on
# one directory, so they have to refuse the same ones too.
#
# Same shape as refresh-graph-map.sh's: only an override is checked (the
# conventional <corpus>/graphify-out is the out dir by definition), and the dir
# may be absent, empty, or carry graphify's own namespaced control files -- a
# `graphify update` writes `.graphify_root` (watch.py) on every path that
# produces a graph, so a real out dir always has one. Unmatched globs expand
# literally and fail `-e`.
# A SYMLINK at an overridden out dir escapes the corpus, exactly as on the
# semantic leg (CR r14) -- `-d` follows the link, so the write would land
# wherever it points. `-L` sees the link itself.
if [ "$OUT_DIR" != "$CORPUS_ROOT/graphify-out" ] && [ -L "$OUT_DIR" ]; then
  echo "ast-update: FAILED -- GRAPHIFY_OUT is overridden to '$GRAPHIFY_OUT' and $OUT_DIR is a SYMLINK, which would place the graph write outside the directory named. Point it at a real directory. Exiting 3, not 4" >&2
  exit 3
fi
if [ "$OUT_DIR" != "$CORPUS_ROOT/graphify-out" ] && [ -d "$OUT_DIR" ]; then
  _out_is_graphify=0
  # `.graphify_*` with the UNDERSCORE, not `.graphify*` (CR r11). Every out-dir
  # control file graphify writes is underscored -- .graphify_root,
  # .graphify_build.json, .graphify_semantic_marker, .graphify_analysis.json,
  # .graphify_labels.json, .graphify_promoted_version -- while the CORPUS-side
  # file this repo puts at a source root, `.graphify-corpus-ignore`
  # (HIMMEL-1903), is hyphenated. The looser glob accepted that as proof of
  # ownership, so a source tree carrying one could be adopted and have its
  # cache and manifest destroyed: the guard defeated by a file this very repo
  # tells operators to create.
  for _marker in "$OUT_DIR"/.graphify_* "$OUT_DIR"/.promote* \
                 "$OUT_DIR"/.cache.previous.*; do
    if [ -e "$_marker" ]; then _out_is_graphify=1; break; fi
  done
  # Fail closed when the directory cannot be listed (CR r14) -- an unreadable
  # dir must not read as empty, i.e. as safe to write into.
  if ! _out_listing=$(ls -A "$OUT_DIR" 2>/dev/null); then
    echo "ast-update: FAILED -- $OUT_DIR exists but could not be listed (permissions?), so its contents cannot be checked before writing graph artifacts into it. Exiting 3, not 4" >&2
    exit 3
  fi
  if [ "$_out_is_graphify" -eq 0 ] && [ -n "$_out_listing" ]; then
    echo "ast-update: FAILED -- GRAPHIFY_OUT is overridden to '$GRAPHIFY_OUT' and $OUT_DIR is a non-empty directory carrying none of graphify's control files, so it is source content, not a graph output. Refusing to write graph artifacts into it. Exiting 3, not 4" >&2
    exit 3
  fi
fi

PROMOTE_LOCK="$OUT_DIR/.promote.lock"
PROMOTE_LOCK_HELD=0
PROMOTE_LOCK_TOKEN=""

# _promote_lock_release -- owner-tokened, identical rationale to refresh-
# graph-map.sh's _promote_lock_release: never rm -rf a lock we don't
# currently own (e.g. taken over by the semantic side's own crashed-holder
# reclaim while we were paused/killed).
# shellcheck disable=SC2329,SC2317  # invoked indirectly via `trap ... EXIT` below; shellcheck's reachability check misses it (whole function + its body) once an early exit precedes the script's end
_promote_lock_release() {
  local cur=""
  if [ "$PROMOTE_LOCK_HELD" -eq 1 ]; then
    PROMOTE_LOCK_HELD=0
    [ -d "$PROMOTE_LOCK" ] || return 0
    cur=$(cat "$PROMOTE_LOCK/owner" 2>/dev/null) || cur=""
    if [ "$cur" != "$PROMOTE_LOCK_TOKEN" ]; then
      echo "ast-update: WARN promote lock $PROMOTE_LOCK was taken over by another refresh while we held it (owner token mismatch) -- not releasing the successor's lock" >&2
      return 0
    fi
    rm -rf "$PROMOTE_LOCK" 2>/dev/null || true
  fi
}
trap '_promote_lock_release' EXIT

# CR r2 (HIMMEL-1948): a swallowed `mkdir -p` failure here used to fall
# through into the lock mkdir below, whose failure (parent missing) was then
# misread as "lock held" -> exit 4 forever, hiding a real, permanent,
# operator-actionable path/permission failure behind the benign-skip code.
# Check it explicitly and fail LOUDLY with a DISTINCT code (see header).
if ! _out_err=$(mkdir -p "$OUT_DIR" 2>&1 1>/dev/null); then
  echo "ast-update: FAILED to create OUT_DIR=$OUT_DIR (resolved from GRAPHIFY_OUT=${GRAPHIFY_OUT:-<default: graphify-out>}) -- $_out_err -- this is a real filesystem failure, NOT a lock-held skip; exiting 3, not 4" >&2
  exit 3
fi

# SKIP-not-wait (see header): a single mkdir attempt, retried ONCE on
# failure before classifying. mkdir is the same atomic acquire arbiter
# refresh-graph-map.sh uses. Same masking risk as above: mkdir failing does
# NOT always mean "the lock dir already exists" -- it can also mean
# permissions/read-only/etc on $OUT_DIR itself. Distinguish by checking
# whether the lock dir actually exists after the failure.
#
# TOCTOU (HIMMEL-1948 CR, residual closed in HIMMEL-1960): mkdir can fail
# because the lock is genuinely held, and the holder can then RELEASE it
# before the -d test runs -- the -d test then sees no lock dir and this
# misreads a benign contention event as exit 3 (real filesystem failure),
# inverting the header's documented contract on an hourly cadence.
#
# The fix is to make `-d false` mean RETRY rather than "filesystem failure".
# The two outcomes are distinguishable by what the NEXT mkdir does: if the
# holder really did release, the retry acquires; if the path is genuinely
# broken (permissions, read-only mount, vanished parent), every attempt
# fails with the dir still absent. So loop while `-d` is false, and classify
# only on the two states that are self-consistent:
#   mkdir failed AND -d true  -> genuinely held      -> exit 4 (benign skip)
#   mkdir failed AND -d false, 3x in a row -> real fs failure -> exit 3
# Each extra iteration would need a fresh holder to acquire AND release
# inside the window, so three attempts closes the race in practice without
# turning skip-not-wait into a wait. On success we hold the lock ourselves
# and fall through to the normal path below (owner token, mandatory
# "acquired" stamp -- neither is skipped).
_lock_acquired=0
for _lock_try in 1 2 3; do
  if _lock_err=$(mkdir "$PROMOTE_LOCK" 2>&1 1>/dev/null); then
    _lock_acquired=1
    break
  fi
  # Genuinely held -- no retry can help, and waiting is not this script's
  # contract. Stop and let the classification below report the skip.
  if [ -d "$PROMOTE_LOCK" ]; then break; fi
done
if [ "$_lock_acquired" -eq 0 ]; then
  # SYMLINK FIRST (CR r4). Both sides of this protocol acquire by `mkdir`, so
  # the lock path is always a REAL directory when it is ours -- a symlink there
  # is foreign and permanent, and it defeats both classifiers below in opposite
  # ways: one pointing AT a directory satisfies `-d` and reads as "held by a
  # semantic refresh", while a DANGLING one fails `-e` (which follows the link)
  # and then passes the sibling writability probe as "contention". Either way an
  # hourly leg would skip forever under the benign code. `-L` is the only test
  # that sees the link itself.
  if [ -L "$PROMOTE_LOCK" ]; then
    echo "ast-update: FAILED -- $PROMOTE_LOCK is a SYMLINK, but this lock is only ever acquired as a real directory (mkdir), so it can never be acquired here; this is a permanent conflict, NOT a lock-held skip. Remove it. Exiting 3, not 4" >&2
    exit 3
  fi
  if [ -d "$PROMOTE_LOCK" ]; then
    echo "ast-update: structural refresh SKIPPED -- promote lock $PROMOTE_LOCK held by a semantic refresh (skip-not-wait; retried on this corpus's next scheduled structural run)" >&2
    exit 4
  fi
  # The lock dir is absent yet mkdir kept failing. Retrying only NARROWS that
  # race (CR r2) -- `-d` is simply the wrong oracle, because it asks about the
  # lock (which another process owns and can change under us) when the question
  # is about the FILESYSTEM (which nobody else is mutating). Ask the real
  # question directly: can OUT_DIR accept a directory at all? A success means
  # the path is healthy, so every failed acquire above was contention, and
  # reporting a filesystem failure would be a false alarm on an hourly cadence.
  # Only a probe that ALSO fails justifies exit 3. This closes the TOCTOU rather
  # than shrinking it: exit 3 no longer depends on winning any race.
  # A non-directory sitting on the lock path (a stray regular file, a symlink)
  # makes mkdir fail EEXIST forever while `-d` stays false and OUT_DIR remains
  # perfectly writable -- so the probe below would call it contention and this
  # leg would skip every hour, permanently, reporting the benign code (CR r3
  # codex-2). That is the exact false-benign class exit 3 exists for, and it is
  # name-specific, so no probe of a SIBLING path can see it. Check the lock path
  # itself first.
  # Re-test `! -d` rather than trusting the earlier check (CR r11): another
  # process can create the legitimate lock DIRECTORY in the window between
  # them, and reporting that as a permanent non-directory conflict would turn
  # ordinary contention into a loud failure. If it became a directory, fall
  # through to the probe, which classifies it as contention (exit 4).
  if [ -e "$PROMOTE_LOCK" ] && [ ! -d "$PROMOTE_LOCK" ]; then
    echo "ast-update: FAILED -- $PROMOTE_LOCK exists but is NOT a directory, so the lock can never be acquired; this is a permanent filesystem conflict, NOT a lock-held skip. Remove it. Exiting 3, not 4" >&2
    exit 3
  fi
  # $$-$RANDOM, not $$ alone (CR r7): a probe dir left behind by a failed
  # cleanup would collide on PID reuse, and mkdir failing on that stale
  # directory would report a filesystem failure on a perfectly healthy path --
  # the same false verdict this probe exists to prevent, inverted. Same idiom
  # as the owner token below.
  _lock_probe="$PROMOTE_LOCK.probe.$$-$RANDOM"
  if mkdir "$_lock_probe" 2>/dev/null; then
    rmdir "$_lock_probe" 2>/dev/null || true
    echo "ast-update: structural refresh SKIPPED -- promote lock $PROMOTE_LOCK was contended and released repeatedly during acquire (the out dir is writable, so this is contention, not a filesystem failure); retried on this corpus's next scheduled structural run" >&2
    exit 4
  fi
  echo "ast-update: FAILED to acquire promote lock $PROMOTE_LOCK -- $_lock_err -- the out dir rejects directory creation, so this is a real filesystem failure, NOT a lock-held skip; exiting 3, not 4" >&2
  exit 3
fi

PROMOTE_LOCK_TOKEN="$$-$RANDOM"
if ! printf '%s\n' "$PROMOTE_LOCK_TOKEN" > "$PROMOTE_LOCK/owner" 2>/dev/null; then
  rm -rf "$PROMOTE_LOCK" 2>/dev/null || true
  echo "ast-update: promote lock acquired but its owner token could not be written ($PROMOTE_LOCK/owner) -- released again, nothing run" >&2
  exit 2
fi
# Mandatory (not optional): without this stamp, refresh-graph-map.sh's
# crashed-holder grace window (~5 polls with no readable "acquired" stamp)
# treats our lock as a crashed holder and takes it over mid-write. A failed
# write must not leave a stampless lock behind -- release it and fail loudly.
if ! _stamp_err=$( { date -u +%s > "$PROMOTE_LOCK/acquired"; } 2>&1 1>/dev/null ); then
  rm -rf "$PROMOTE_LOCK" 2>/dev/null || true
  echo "ast-update: FAILED to write acquired stamp ($PROMOTE_LOCK/acquired) -- $_stamp_err -- this is a real filesystem failure, NOT a lock-held skip; exiting 3, not 4" >&2
  exit 3
fi
PROMOTE_LOCK_HELD=1

# Capture graphify's own exit status instead of propagating it unchanged
# (set -e would otherwise make this script's own exit code just BE whatever
# `graphify update` exits with) -- graphify can itself exit 4 for reasons of
# its own, which would then misread as this script's reserved benign
# lock-skip. Remap any non-zero graphify exit to the fixed sentinel 5 (see
# header); the real code is logged, never reused as our own exit status.
set +e
graphify update "$CORPUS_ROOT" --force
_graphify_rc=$?
set -e
if [ "$_graphify_rc" -eq 0 ]; then
  exit 0
fi
echo "ast-update: FAILED -- graphify update exited $_graphify_rc -- reporting as exit 5, not $_graphify_rc, so a real graphify failure can never masquerade as this script's reserved exit 3 (fs failure) or exit 4 (benign lock-skip)" >&2
exit 5
