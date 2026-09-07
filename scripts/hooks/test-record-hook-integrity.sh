#!/usr/bin/env bash
# Coverage for HIMMEL-2528: record-hook-integrity.sh's schema-v2 pin (anchor_ref
# / anchor / git_dir), its idempotent merge over an existing v2 record, its
# all-or-nothing fallback to the legacy v1 shape, and the per-session record
# lock (scripts/hooks/hook-integrity-lock.sh) it now holds across the
# read-merge-publish. House style follows test-hook-rewrite-integrity.sh:
# a real fixture repo, ok()/bad() counters, one summary line, `[ "$fail" -eq 0 ]`.
#
# Rows 1/2/4/5/6 exercise schema-v2 behaviour that does not exist in the pre-
# HIMMEL-2528 recorder at all (it never wrote anchor_ref/anchor/git_dir, and
# never merged) — each would fail against that recorder simply because the
# keys/merge semantics it asserts on did not exist. Rows 9-12 exercise the
# lock, which the pre-HIMMEL-2528 recorder had no notion of at all: it wrote
# straight over $dest with no regard for any `$dest.lock` directory, so row 9
# and row 11 (expecting the record to be left UNTOUCHED while a lock is held)
# would fail against it — it would clobber the record every time regardless.
# Row 7/8 (staging + atomic-publish mechanics)
# exercise code paths whose failure mode is platform-specific (row 8 does
# not actually fail against the old recorder ON LINUX, since POSIX rename()
# is not gated by the target file's own permission bits — only Windows needs
# the pre-chmod; kept anyway as a regression guard for the new step).
#
# Rows 15-21 came out of the review panel on this branch and each one fails
# against the FIRST cut of HIMMEL-2528, not just against the pre-2528 recorder:
# 15 the suite skipping on an in-repo file, 16 `rm -rf`-based reclaim letting
# two contenders both win, 17/18 `kill -0`'s EPERM being read as death (the JS
# twin reads it as ALIVE), 19/20 a swallowed owner-file write leaving an
# ownerless lock dir that wedges the record forever, 21 the recorder sourcing
# an unverified project-local guardrails/lib.sh.
#
# Rows 3 and 22 came out of the SECOND panel round, which found the same class
# still open one file over: the recorder sourced its lock lib unverified, and
# that lib lived in scripts/lib/, a directory nothing pins. The lib moved into
# scripts/hooks/ (pinned) and the recorder now compares it against the blob at
# $anchor_ref before the dot. Row 22 is the tamper direction; row 3 is the
# unresolvable-anchor direction; 22b is the tamper COMMITTED, so HEAD alone
# cannot certify it. Each asserts BOTH halves of the fix: the lib is not
# sourced (marker absent) AND the pin record is still written, lock-free and
# flagged `lock_unverified`. The second half matters as much as the first --
# the launcher fails OPEN on a missing record, so a recorder that simply exited
# on a verify failure would be a one-step off switch for the whole integrity
# system rather than a fix for it. Row 1c is the negative control on the flag.
#
# Row 24 came out of the THIRD panel round, on the fix rows 3/22/22b installed:
# the comparison itself was running the repository's own clean filter, so the
# check could be made to execute attacker-chosen code and to hash laundered
# bytes. It fails against every earlier cut of this branch.
#
# Row 3 used to assert that a no-origin repo got a legacy record with no
# further comment; it now also carries the refusal and the flag. The legacy v1
# shape is still WRITTEN when the anchor resolves but --git-common-dir
# canonicalization fails, and still READ (and replaced) when a pre-HIMMEL-2528
# record is already on disk -- row 4 covers that, now from a planted legacy
# record rather than one this recorder produced.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
RECORDER="$HOOKS_DIR/record-hook-integrity.sh"
LOCK_LIB="$REPO_ROOT/scripts/hooks/hook-integrity-lock.sh"
GUARDRAILS_LIB="$REPO_ROOT/scripts/guardrails/lib.sh"

# jq/git are genuinely EXTERNAL and genuinely optional (a machine without them
# cannot run the recorder either, so there is nothing here to prove) -- those
# stay SKIPs.
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

# The lock lib and guardrails lib are IN THIS REPO. "Missing" therefore means a
# broken checkout or a stale path in this suite -- never a legitimate
# environment gap -- and skipping on it reports GREEN while covering nothing.
# Hard-fail instead, so the ledger cannot record a vacuous pass. Row 15 below
# proves this preflight fails rather than skips.
require_in_repo() {
  [ -f "$1" ] && return 0
  printf 'FAIL: required in-repo file missing: %s\n' "$1" >&2
  printf '      This file is committed to this repo; its absence is a broken checkout or a\n' >&2
  printf '      stale path in this suite, not a reason to skip. Refusing to report green.\n' >&2
  exit 1
}
require_in_repo "$RECORDER"
require_in_repo "$LOCK_LIB"
require_in_repo "$GUARDRAILS_LIB"
# Row 15 re-executes a COPY of this suite purely to observe the preflight above;
# this marker stops that copy from running the whole suite again (and recursing).
[ -n "${HIMMEL_RECORD_TEST_PREFLIGHT_ONLY:-}" ] && exit 0

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-record-hook-integrity.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

# shellcheck source=/dev/null
. "$LOCK_LIB"

# new_fixture <name> [origin_branch] -- a project repo with real
# scripts/hooks + scripts/guardrails content (so the recorder pins something
# real), optionally with an `origin` remote whose default branch is
# origin_branch, already fetched. Omit origin_branch for a no-remote fixture.
# Prints the project dir.
#
# The origin is a BARE CLONE-BY-PUSH of the project, not the unrelated
# empty-commit repo it used to be: the recorder now verifies its lock lib
# against `<anchor_ref>:scripts/hooks/hook-integrity-lock.sh`, so an origin
# whose tree does not actually contain the project's files leaves nothing to
# verify against and every fixture would refuse. A real origin carries the
# code, so this is also the more faithful fixture.
new_fixture() {
  local name="$1" origin_branch="${2:-}" project origin
  project="$T/$name/project"
  mkdir -p "$project/scripts/hooks" "$project/scripts/guardrails"
  cp "$RECORDER" "$project/scripts/hooks/record-hook-integrity.sh"
  cp "$LOCK_LIB" "$project/scripts/hooks/hook-integrity-lock.sh"
  cp "$GUARDRAILS_LIB" "$project/scripts/guardrails/lib.sh"
  printf '#!/usr/bin/env bash\necho fake-guard\n' > "$project/scripts/hooks/fake-guard.sh"
  git init -q "$project"
  git -C "$project" -c user.email=t@t -c user.name=t add -A
  git -C "$project" -c user.email=t@t -c user.name=t commit -q -m init
  if [ -n "$origin_branch" ]; then
    origin="$T/$name/origin"
    git init -q --bare "$origin"
    # Set HEAD before the push so the bare repo's default branch is
    # origin_branch regardless of this machine's init.defaultBranch.
    git -C "$origin" symbolic-ref HEAD "refs/heads/$origin_branch"
    git -C "$project" push -q "$origin" "HEAD:refs/heads/$origin_branch"
    git -C "$project" remote add origin "$origin"
    git -C "$project" fetch -q origin
    # resolve_default_branch reads refs/remotes/origin/HEAD first. Recent git
    # sets it on fetch, older git does not; set it explicitly so the fixture
    # does not depend on which.
    git -C "$project" remote set-head origin -a >/dev/null 2>&1 || true
  fi
  printf '%s' "$project"
}

# advance_origin <project> -- one more commit on the fixture's origin remote,
# fetched into <project>. Prints the new commit sha.
#
# commit-tree over the CURRENT tip's tree, rather than `commit --allow-empty`:
# the origin is bare now (no index to commit from), and the new tip has to keep
# carrying scripts/hooks/hook-integrity-lock.sh or the recorder's verify step
# would refuse on the very re-fire this exercises.
advance_origin() {
  local project="$1" origin="$1/../origin" branch tip new
  branch="$(git -C "$origin" symbolic-ref --short HEAD)"
  tip="$(git -C "$origin" rev-parse HEAD)"
  new="$(git -C "$origin" -c user.email=t@t -c user.name=t \
    commit-tree "$tip^{tree}" -p "$tip" -m advance)"
  git -C "$origin" update-ref "refs/heads/$branch" "$new"
  git -C "$project" fetch -q origin
  printf '%s' "$new"
}

canonical_git_dir() {
  local project="$1" raw
  raw="$(git -C "$project" rev-parse --git-common-dir)"
  (cd "$project" && cd "$raw" && pwd)
}

run_recorder() {
  local project="$1" out_dir="$2" session_id="$3"
  printf '{"session_id":%s}' "$(printf '%s' "$session_id" | jq -Rs '.')" \
    | CLAUDE_PROJECT_DIR="$project" HIMMEL_HOOK_INTEGRITY_DIR="$out_dir" bash "$RECORDER"
}

# run_fixture_recorder <project> <out_dir> <session_id> -- same, but executes
# the fixture's OWN copy of the recorder. Any row about the lock lib must use
# this one: the recorder resolves the lib relative to $0, so running the repo's
# recorder sources the REPO's pristine lib and a tamper planted in the fixture
# is never read (which is how the first cut of rows 22/22b passed vacuously).
run_fixture_recorder() {
  local project="$1" out_dir="$2" session_id="$3"
  printf '{"session_id":%s}' "$(printf '%s' "$session_id" | jq -Rs '.')" \
    | CLAUDE_PROJECT_DIR="$project" HIMMEL_HOOK_INTEGRITY_DIR="$out_dir" \
      bash "$project/scripts/hooks/record-hook-integrity.sh"
}

# ---------------------------------------------------------------------------
# Row 1: v2 record written -- anchor_ref/anchor/git_dir present and correct.
# ---------------------------------------------------------------------------
P1="$(new_fixture row1 main)"
OUT1="$T/row1/out"
run_recorder "$P1" "$OUT1" "sess-1"
REC1="$OUT1/sess-1.json"
if [ -f "$REC1" ] \
  && [ "$(jq -r '.anchor_ref' "$REC1")" = "refs/remotes/origin/main" ] \
  && [ "$(jq -r '.anchor' "$REC1")" = "$(git -C "$P1" rev-parse refs/remotes/origin/main)" ] \
  && [ "$(jq -r '.git_dir' "$REC1")" = "$(canonical_git_dir "$P1")" ]; then
  case "$(jq -r '.git_dir' "$REC1")" in
    /*) ok "row1: v2 record has correct anchor_ref/anchor/git_dir" ;;
    *) bad "row1: git_dir is not absolute: $(jq -r '.git_dir' "$REC1")" ;;
  esac
else
  bad "row1: record missing or wrong: $(cat "$REC1" 2>/dev/null || echo '<no file>')"
fi

# ---------------------------------------------------------------------------
# Row 1b: pins are derived correctly from `ls-tree HEAD` -- path key -> the
# RIGHT blob sha, for a file in BOTH scanned directories (scripts/hooks AND
# scripts/guardrails). This is the only place in the suite that checks a
# pin's VALUE against `git rev-parse HEAD:<path>` rather than just the shape
# around it; carried over from the pre-HIMMEL-2528 smoke test's
# "hooks/hook-a.sh pinned to its git blob sha" / "guardrails/guard-b.sh
# pinned to its git blob sha" assertions. Reuses row1's fixture/record: it
# already has a real file in both directories.
# ---------------------------------------------------------------------------
expected_hooks_pin="$(git -C "$P1" rev-parse HEAD:scripts/hooks/fake-guard.sh)"
expected_guardrails_pin="$(git -C "$P1" rev-parse HEAD:scripts/guardrails/lib.sh)"
got_hooks_pin="$(jq -r '.pins["scripts/hooks/fake-guard.sh"] // empty' "$REC1")"
got_guardrails_pin="$(jq -r '.pins["scripts/guardrails/lib.sh"] // empty' "$REC1")"
if [ "$got_hooks_pin" = "$expected_hooks_pin" ]; then
  ok "row1b: scripts/hooks/fake-guard.sh pinned to its git blob sha"
else
  bad "row1b: scripts/hooks/fake-guard.sh pin mismatch: got $got_hooks_pin expected $expected_hooks_pin"
fi
if [ "$got_guardrails_pin" = "$expected_guardrails_pin" ]; then
  ok "row1b: scripts/guardrails/lib.sh pinned to its git blob sha"
else
  bad "row1b: scripts/guardrails/lib.sh pin mismatch: got $got_guardrails_pin expected $expected_guardrails_pin"
fi

# ---------------------------------------------------------------------------
# Row 1c: the NEGATIVE control for lock_unverified. Rows 3/22/22b assert the
# flag is TRUE on a lock-free write; without this row a recorder that stamped
# it unconditionally would satisfy all three and the flag would carry no
# information. A healthy record must not carry the key at all.
# ---------------------------------------------------------------------------
if [ "$(jq -r 'has("lock_unverified")' "$REC1")" = "false" ]; then
  ok "row1c: a healthy record carries no lock_unverified key"
else
  bad "row1c: healthy record is flagged lock-free: $(jq -c '{lock_unverified}' "$REC1")"
fi

# ---------------------------------------------------------------------------
# Row 2: master-default fixture stores refs/remotes/origin/master.
# ---------------------------------------------------------------------------
P2="$(new_fixture row2 master)"
OUT2="$T/row2/out"
run_recorder "$P2" "$OUT2" "sess-2"
REC2="$OUT2/sess-2.json"
if [ "$(jq -r '.anchor_ref' "$REC2" 2>/dev/null)" = "refs/remotes/origin/master" ]; then
  ok "row2: master-default fixture pins refs/remotes/origin/master"
else
  bad "row2: expected refs/remotes/origin/master, got $(jq -r '.anchor_ref // "<none>"' "$REC2" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# Row 3 (round-2 panel, the unresolvable-anchor direction): no origin remote ->
# no anchor -> NOTHING to verify the lock lib against -> the recorder refuses to
# SOURCE it, but STILL WRITES THE RECORD, lock-free and flagged.
#
# Both halves are load-bearing and the second one is the subtler. The launcher
# fails OPEN on a missing record (hook-integrity.js: `const pins =
# recordPins(record); if (!pins) return { ok: true }`), so a recorder that
# exited here would turn every lib-verify failure into a session-wide OFF
# SWITCH for hook integrity -- reachable by an attacker with no code execution
# at all, and reachable BY ACCIDENT on any branch where the lib is not yet
# committed at the anchor. Asserting only "no marker" would have called that
# behaviour a fix.
#
# The fixture's lock lib is TAMPERED AND COMMITTED here, so HEAD's blob matches
# what is on disk. That is the self-certification an attacker gets for free
# (pins_fresh is built from `ls-tree HEAD`, and a local worker can move HEAD):
# the row therefore also pins that HEAD is not accepted as a stand-in trust
# anchor when the real one is missing. The marker file is the observable for
# the refusal -- a sourced lib would create it.
# ---------------------------------------------------------------------------
P3="$(new_fixture row3)"
OUT3="$T/row3/out"
MARKER3="$T/row3/TAMPER-EXECUTED"
cat >> "$P3/scripts/hooks/hook-integrity-lock.sh" <<EOF
: > "$MARKER3"
EOF
git -C "$P3" -c user.email=t@t -c user.name=t add -A
git -C "$P3" -c user.email=t@t -c user.name=t commit -q -m tamper
run_fixture_recorder "$P3" "$OUT3" "sess-3"
rc3=$?
REC3="$OUT3/sess-3.json"
if [ "$rc3" -eq 0 ] && [ ! -e "$MARKER3" ] && [ -f "$REC3" ] \
  && [ "$(jq -r '.pins["scripts/hooks/fake-guard.sh"] // empty' "$REC3")" \
     = "$(git -C "$P3" rev-parse HEAD:scripts/hooks/fake-guard.sh)" ] \
  && [ "$(jq -r '.lock_unverified // false' "$REC3")" = "true" ]; then
  ok "row3: no anchor -> lib refused (HEAD is no substitute) yet pins STILL recorded, flagged lock-free"
else
  bad "row3: rc=$rc3 (want 0) marker=$([ -e "$MARKER3" ] && echo 'EXECUTED' || echo absent) record=$(cat "$REC3" 2>/dev/null || echo '<NO FILE — integrity system disabled>')"
fi

# ---------------------------------------------------------------------------
# Row 4: re-fire over an existing LEGACY record -> REPLACED with v2, stale pins
# dropped rather than merged.
#
# The legacy record is PLANTED by hand rather than produced by a first
# no-origin run: since row 3's fail-closed anchor check the recorder no longer
# emits one that way, and the input this path has to handle is a record written
# by the PRE-HIMMEL-2528 recorder anyway. Planting it tests the same branch
# against the exact shape it will actually meet in the field.
# ---------------------------------------------------------------------------
P4="$(new_fixture row4 main)"
OUT4="$T/row4/out"
mkdir -p "$OUT4"
REC4="$OUT4/sess-4.json"
printf '{"session_id":"sess-4","recorded_at":"2020-01-01T00:00:00Z","pins":{"scripts/hooks/fake-guard.sh":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","scripts/hooks/gone.sh":"0000000000000000000000000000000000000000"}}' > "$REC4"
run_recorder "$P4" "$OUT4" "sess-4"
if [ "$(jq -r 'has("anchor_ref")' "$REC4" 2>/dev/null)" = "true" ] \
  && [ "$(jq -r '.anchor' "$REC4")" = "$(git -C "$P4" rev-parse refs/remotes/origin/main)" ] \
  && [ "$(jq -r '.pins["scripts/hooks/fake-guard.sh"]' "$REC4")" = "$(git -C "$P4" rev-parse HEAD:scripts/hooks/fake-guard.sh)" ] \
  && [ "$(jq -r '.pins | has("scripts/hooks/gone.sh")' "$REC4")" = "false" ]; then
  ok "row4: a legacy record is replaced wholesale with v2, stale pins dropped"
else
  bad "row4: expected v2 replace, got $(cat "$REC4" 2>/dev/null || echo '<no file>')"
fi

# ---------------------------------------------------------------------------
# Row 5: re-fire over an existing v2 record with a hand-advanced pin AND an
# anchor at a DESCENDANT commit -> pin preserved verbatim, anchor NOT lowered.
# ---------------------------------------------------------------------------
P5="$(new_fixture row5 main)"
OUT5="$T/row5/out"
run_recorder "$P5" "$OUT5" "sess-5"
REC5="$OUT5/sess-5.json"
base_anchor="$(jq -r '.anchor' "$REC5")"
# A commit descending from base_anchor, simulating the JS launcher having
# already advanced the pin past what this run would freshly resolve (origin
# is deliberately left at base_anchor, not fetched further).
advanced_anchor="$(git -C "$P5" commit-tree "$(git -C "$P5" rev-parse "$base_anchor^{tree}")" -p "$base_anchor" -m advanced)"
chmod 600 "$REC5"
jq --arg a "$advanced_anchor" '.anchor=$a | .pins["scripts/hooks/fake-guard.sh"]="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$REC5" > "$REC5.tmp"
mv "$REC5.tmp" "$REC5"
chmod 400 "$REC5"
run_recorder "$P5" "$OUT5" "sess-5"
if [ "$(jq -r '.anchor' "$REC5")" = "$advanced_anchor" ] \
  && [ "$(jq -r '.pins["scripts/hooks/fake-guard.sh"]' "$REC5")" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]; then
  ok "row5: hand-advanced pin preserved, descendant anchor not lowered"
else
  bad "row5: anchor=$(jq -r '.anchor' "$REC5"), pin=$(jq -r '.pins["scripts/hooks/fake-guard.sh"]' "$REC5") (want anchor=$advanced_anchor, pin=deadbeef...)"
fi

# ---------------------------------------------------------------------------
# Row 6: re-fire when origin moved FORWARD -> anchor advances.
# ---------------------------------------------------------------------------
P6="$(new_fixture row6 main)"
OUT6="$T/row6/out"
run_recorder "$P6" "$OUT6" "sess-6"
REC6="$OUT6/sess-6.json"
first_anchor="$(jq -r '.anchor' "$REC6")"
new_anchor="$(advance_origin "$P6")"
run_recorder "$P6" "$OUT6" "sess-6"
if [ "$(jq -r '.anchor' "$REC6")" = "$new_anchor" ] && [ "$new_anchor" != "$first_anchor" ]; then
  ok "row6: anchor advances when origin moves forward"
else
  bad "row6: expected anchor=$new_anchor, got $(jq -r '.anchor' "$REC6") (first was $first_anchor)"
fi

# ---------------------------------------------------------------------------
# Row 7: staging lands beside the destination, not under $TMPDIR; published
# record is mode 400.
# ---------------------------------------------------------------------------
P7="$(new_fixture row7 main)"
OUT7="$T/row7/out"
ISOLATED_TMPDIR="$T/row7/tmphome"
mkdir -p "$ISOLATED_TMPDIR"
printf '{"session_id":"sess-7"}' | CLAUDE_PROJECT_DIR="$P7" HIMMEL_HOOK_INTEGRITY_DIR="$OUT7" TMPDIR="$ISOLATED_TMPDIR" bash "$RECORDER"
REC7="$OUT7/sess-7.json"
# Glob + loop instead of `find -maxdepth 1`: a single-directory name check
# needs no find at all. nullglob is NOT set (repo convention), so an
# unmatched pattern expands to its own literal text -- `-e` on that literal
# is false and the iteration is skipped, same net effect as nullglob without
# relying on a shopt these scripts don't set.
stray_tmpdir=0
for f in "$ISOLATED_TMPDIR"/hook-integrity.*; do
  [ -e "$f" ] || continue
  stray_tmpdir=$((stray_tmpdir + 1))
done
stray_outdir=0
for f in "$OUT7"/.hook-integrity.*; do
  [ -e "$f" ] || continue
  stray_outdir=$((stray_outdir + 1))
done
if [ -f "$REC7" ] && [ "$stray_tmpdir" -eq 0 ] && [ "$stray_outdir" -eq 0 ]; then
  if command -v stat >/dev/null 2>&1; then
    mode="$(stat -c %a "$REC7" 2>/dev/null || stat -f %Lp "$REC7" 2>/dev/null)"
    if [ "$mode" = "400" ]; then
      ok "row7: staged beside dest (no TMPDIR/out_dir temp survives), mode 400"
    else
      bad "row7: published record mode is '$mode', expected 400"
    fi
  else
    ok "row7: staged beside dest (no TMPDIR/out_dir temp survives) [stat unavailable, mode not checked]"
  fi
else
  bad "row7: record=$( [ -f "$REC7" ] && echo present || echo missing) strayTMPDIR=$stray_tmpdir strayOUT=$stray_outdir"
fi

# ---------------------------------------------------------------------------
# Row 8: publication is atomic over a pre-existing 0400 record (chmod-before-
# rename proof).
# ---------------------------------------------------------------------------
P8="$(new_fixture row8 main)"
OUT8="$T/row8/out"
mkdir -p "$OUT8"
REC8="$OUT8/sess-8.json"
printf '{"placeholder":true}\n' > "$REC8"
chmod 400 "$REC8"
run_recorder "$P8" "$OUT8" "sess-8"
if [ -f "$REC8" ] && [ "$(jq -r 'has("placeholder")' "$REC8" 2>/dev/null)" = "false" ] \
  && [ -n "$(jq -r '.session_id // empty' "$REC8" 2>/dev/null)" ]; then
  ok "row8: publish replaces a pre-existing 0400 record"
else
  bad "row8: record unchanged or missing: $(cat "$REC8" 2>/dev/null || echo '<no file>')"
fi

# ---------------------------------------------------------------------------
# Row 9: lock held by a LIVE process (this test script itself) -> recorder
# exits 0 and does NOT modify the record.
# ---------------------------------------------------------------------------
P9="$(new_fixture row9 main)"
OUT9="$T/row9/out"
mkdir -p "$OUT9"
REC9="$OUT9/sess-9.json"
printf '{"placeholder":"row9"}\n' > "$REC9"
LOCK9="$REC9.lock"
mkdir "$LOCK9"
{
  printf 'pid=%s\n' "$$"
  printf 'pid_namespace=%s\n' "$(hil_pid_namespace)"
  printf 'start_time=\n'
} > "$LOCK9/owner"
before9="$(cat "$REC9")"
HIL_LOCK_WAIT_MS=50 HIL_LOCK_POLL_MS=10 run_recorder "$P9" "$OUT9" "sess-9"
rc9=$?
after9="$(cat "$REC9")"
if [ "$rc9" -eq 0 ] && [ "$after9" = "$before9" ] && [ -d "$LOCK9" ]; then
  ok "row9: lock held by a live (this-test) process -> record untouched, recorder still exits 0"
else
  bad "row9: rc=$rc9 before='$before9' after='$after9' lockdir=$([ -d "$LOCK9" ] && echo present || echo gone)"
fi
rm -rf "$LOCK9"

# ---------------------------------------------------------------------------
# Row 10: lock held by a dead pid in OUR namespace -> reclaimed, record
# written.
# ---------------------------------------------------------------------------
P10="$(new_fixture row10 main)"
OUT10="$T/row10/out"
mkdir -p "$OUT10"
REC10="$OUT10/sess-10.json"
( : ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
LOCK10="$REC10.lock"
mkdir "$LOCK10"
{
  printf 'pid=%s\n' "$dead_pid"
  printf 'pid_namespace=%s\n' "$(hil_pid_namespace)"
  printf 'start_time=\n'
} > "$LOCK10/owner"
run_recorder "$P10" "$OUT10" "sess-10"
rc10=$?
if [ "$rc10" -eq 0 ] && [ -f "$REC10" ] && jq -e . "$REC10" >/dev/null 2>&1; then
  ok "row10: lock held by a dead pid in our namespace -> reclaimed, record written"
else
  bad "row10: rc=$rc10 record=$(cat "$REC10" 2>/dev/null || echo '<no file>')"
fi

# ---------------------------------------------------------------------------
# Row 11: lock held by a FOREIGN namespace -> NOT reclaimed, recorder exits 0,
# record untouched.
# ---------------------------------------------------------------------------
P11="$(new_fixture row11 main)"
OUT11="$T/row11/out"
mkdir -p "$OUT11"
REC11="$OUT11/sess-11.json"
printf '{"placeholder":"row11"}\n' > "$REC11"
LOCK11="$REC11.lock"
mkdir "$LOCK11"
{
  printf 'pid=%s\n' "999999"
  printf 'pid_namespace=win32\n'
  printf 'start_time=\n'
} > "$LOCK11/owner"
before11="$(cat "$REC11")"
HIL_LOCK_WAIT_MS=50 HIL_LOCK_POLL_MS=10 run_recorder "$P11" "$OUT11" "sess-11"
rc11=$?
after11="$(cat "$REC11")"
if [ "$rc11" -eq 0 ] && [ "$after11" = "$before11" ] && [ -d "$LOCK11" ]; then
  ok "row11: lock held by a foreign namespace (win32) -> not reclaimed, record untouched"
else
  bad "row11: rc=$rc11 before='$before11' after='$after11' lockdir=$([ -d "$LOCK11" ] && echo present || echo gone)"
fi
rm -rf "$LOCK11"

# ---------------------------------------------------------------------------
# Row 12: hil_lock_release by a non-owner does not remove the lock.
# ---------------------------------------------------------------------------
REC12="$T/sess-12.json"
LOCK12="$REC12.lock"
mkdir "$LOCK12"
{
  printf 'pid=%s\n' "999998"
  printf 'pid_namespace=%s\n' "$(hil_pid_namespace)"
  printf 'start_time=\n'
} > "$LOCK12/owner"
hil_lock_release "$REC12"
if [ -d "$LOCK12" ]; then
  ok "row12: hil_lock_release by a non-owner leaves the lock in place"
else
  bad "row12: lock was removed by a non-owning release"
fi
rm -rf "$LOCK12"

# ---------------------------------------------------------------------------
# Row 13: no session_id in the payload -> writes nothing, still exits 0
# (regression coverage carried over from the pre-HIMMEL-2528 smoke test).
# ---------------------------------------------------------------------------
P13="$(new_fixture row13 main)"
OUT13="$T/row13/out"
printf '{"source":"startup"}' | CLAUDE_PROJECT_DIR="$P13" HIMMEL_HOOK_INTEGRITY_DIR="$OUT13" bash "$RECORDER"
rc13=$?
if [ "$rc13" -eq 0 ] && [ ! -d "$OUT13" ]; then
  ok "row13: missing session_id writes nothing and still exits 0"
else
  bad "row13: rc=$rc13 out_dir_created=$( [ -d "$OUT13" ] && echo yes || echo no )"
fi

# ---------------------------------------------------------------------------
# Row 14: CLAUDE_PROJECT_DIR is not a git repo -> writes nothing, exits 0
# (same carry-over as row 13).
# ---------------------------------------------------------------------------
NONGIT="$T/row14/nongit"
mkdir -p "$NONGIT/scripts/hooks"
printf 'echo x\n' > "$NONGIT/scripts/hooks/x.sh"
OUT14="$T/row14/out"
printf '{"session_id":"sess-14"}' | CLAUDE_PROJECT_DIR="$NONGIT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT14" bash "$RECORDER"
rc14=$?
if [ "$rc14" -eq 0 ] && [ ! -f "$OUT14/sess-14.json" ]; then
  ok "row14: non-git project dir writes nothing and still exits 0"
else
  bad "row14: rc=$rc14 pin_present=$( [ -f "$OUT14/sess-14.json" ] && echo yes || echo no )"
fi

# ---------------------------------------------------------------------------
# Row 15: the in-repo dependency preflight FAILS, it does not SKIP. A suite
# that skips on a file committed to its own repo reports green while covering
# nothing, so this row runs a COPY of this suite in a tree that is missing the
# lock lib and asserts a non-zero exit + a real message -- plus a positive
# control against the intact repo, so the row cannot pass just because the
# re-exec is broken for some unrelated reason.
# ---------------------------------------------------------------------------
DEP15="$T/row15/scripts"
mkdir -p "$DEP15/hooks" "$DEP15/guardrails"
cp "$HOOKS_DIR/test-record-hook-integrity.sh" "$DEP15/hooks/test-record-hook-integrity.sh"
cp "$RECORDER" "$DEP15/hooks/record-hook-integrity.sh"
cp "$GUARDRAILS_LIB" "$DEP15/guardrails/lib.sh"
# hooks/hook-integrity-lock.sh is deliberately NOT copied -- that is the
# broken checkout the preflight has to fail on rather than skip over.
HIMMEL_RECORD_TEST_PREFLIGHT_ONLY=1 bash "$DEP15/hooks/test-record-hook-integrity.sh" \
  > "$T/row15.out" 2> "$T/row15.err"
rc15=$?
HIMMEL_RECORD_TEST_PREFLIGHT_ONLY=1 bash "$HOOKS_DIR/test-record-hook-integrity.sh" \
  > "$T/row15.ctl.out" 2>&1
rc15ctl=$?
if [ "$rc15" -ne 0 ] && [ "$rc15ctl" -eq 0 ] \
  && grep -q 'required in-repo file missing' "$T/row15.err" \
  && ! grep -q 'SKIP' "$T/row15.out"; then
  ok "row15: a missing in-repo dependency FAILS the suite (control: intact repo exits 0)"
else
  bad "row15: rc=$rc15 (want non-zero) control_rc=$rc15ctl (want 0) stdout='$(cat "$T/row15.out")' stderr='$(cat "$T/row15.err")'"
fi

# ---------------------------------------------------------------------------
# Row 16 (codex-1): dead-lock reclamation is single-winner. Two contenders can
# read the SAME dead owner and both decide to reclaim. The old `rm -rf "$lock"`
# ending SUCCEEDED for both (rm -rf is idempotent on an already-gone path), so
# the loser went on to remove whatever lock existed by then -- possibly the
# winner's -- and two processes ended up holding it. The steal is a rename now,
# which exactly one contender can win.
#
# The stale read is simulated deterministically rather than raced: both calls
# run with hil_read_owner stubbed to the dead owner they each latched before
# the other acted, which is precisely the window the race opens.
# ---------------------------------------------------------------------------
REC16="$T/sess-16.json"
LOCK16="$REC16.lock"
mkdir "$LOCK16"
( : ) &
dead16=$!
wait "$dead16" 2>/dev/null
{
  printf 'pid=%s\n' "$dead16"
  printf 'pid_namespace=%s\n' "$(hil_pid_namespace)"
  printf 'start_time=\n'
} > "$LOCK16/owner"
stale_reclaim16() {
  (
    # Deliberate stub, invoked indirectly by hil_lock_reclaim, whose reads of
    # the HIL_OWNER_* globals are what make it a stale-read simulation. The
    # body is unreachable to the analyzer for that same reason. SC2317 and
    # SC2329 are the SAME finding under two linter generations (0.10.x emits
    # 2317, 0.11.x renamed it to 2329). The repo's pre-commit gate pins 0.10.0
    # while a dev box may carry 0.11, so BOTH codes have to be listed -- with
    # only one, the file lints clean by hand and still fails the gate.
    # (No line of this comment may begin with the linter's own name: a leading
    # `shellcheck` word is parsed as a directive and errors out. Same rule the
    # lock lib's header states.)
    # shellcheck disable=SC2317,SC2329,SC2034
    hil_read_owner() {
      HIL_OWNER_PID="$dead16"
      HIL_OWNER_NS="$(hil_pid_namespace)"
      HIL_OWNER_START=""
      return 0
    }
    hil_lock_reclaim "$REC16"
  )
}
stale_reclaim16
rc16a=$?
stale_reclaim16
rc16b=$?
grave16=0
for f in "$LOCK16".dead.*; do
  [ -e "$f" ] || continue
  grave16=$((grave16 + 1))
done
if [ "$rc16a" -eq 0 ] && [ "$rc16b" -ne 0 ] && [ ! -e "$LOCK16" ] && [ "$grave16" -eq 0 ]; then
  ok "row16: two contenders on one dead owner -> exactly one reclaims, no graveyard left behind"
else
  bad "row16: rcA=$rc16a (want 0) rcB=$rc16b (want non-zero) lock=$([ -e "$LOCK16" ] && echo present || echo gone) graveyards=$grave16"
fi
rm -rf "$LOCK16" "$LOCK16".dead.*

# ---------------------------------------------------------------------------
# Row 17 (codex-5): the kill-error classifier. `kill -0` fails with EPERM
# against a LIVE process owned by another OS user; reading that as death steals
# a live foreign-user lock. hook-integrity.js treats EPERM as alive and only
# ESRCH as dead, and the two implementations must agree. The C-locale strings
# below are what bash actually prints.
# ---------------------------------------------------------------------------
c17_dead="$(hil_classify_kill_error 'bash: line 1: kill: (12345) - No such process')"
c17_eperm="$(hil_classify_kill_error 'bash: line 1: kill: (1) - Operation not permitted')"
c17_other="$(hil_classify_kill_error 'kill: (1) - an errno string this classifier has never seen')"
if [ "$c17_dead" = "dead" ] && [ "$c17_eperm" = "alive" ] && [ "$c17_other" = "alive" ]; then
  ok "row17: ESRCH->dead, EPERM->alive, unrecognised->alive (fail-closed default)"
else
  bad "row17: ESRCH='$c17_dead' (want dead) EPERM='$c17_eperm' (want alive) other='$c17_other' (want alive)"
fi

# ---------------------------------------------------------------------------
# Row 18 (codex-5, end to end): a lock owned by a LIVE pid this user may not
# signal must NOT be reclaimed. pid 1 is the probe -- live and root-owned, so
# `kill -0 1` returns EPERM for any non-root user. Under the old code that
# EPERM fell straight through to the reclaim and stole the lock.
# Not assertable when the suite itself runs as root (no foreign-user pid to
# probe); that is an environment property, not a missing dependency, so it is
# reported as a plain note and row 17 carries the unit-level proof.
# ---------------------------------------------------------------------------
if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && ! kill -0 1 2>/dev/null; then
  if [ "$(hil_pid_liveness 1)" = "alive" ]; then
    REC18="$T/sess-18.json"
    LOCK18="$REC18.lock"
    mkdir "$LOCK18"
    {
      printf 'pid=1\n'
      printf 'pid_namespace=%s\n' "$(hil_pid_namespace)"
      printf 'start_time=\n'
    } > "$LOCK18/owner"
    hil_lock_reclaim "$REC18"
    rc18=$?
    if [ "$rc18" -ne 0 ] && [ -d "$LOCK18" ]; then
      ok "row18: EPERM (live foreign-user pid 1) -> reclaim refused, lock left in place"
    else
      bad "row18: rc=$rc18 (want non-zero) lock=$([ -d "$LOCK18" ] && echo present || echo STOLEN)"
    fi
    rm -rf "$LOCK18"
  else
    bad "row18: hil_pid_liveness reported pid 1 (live, root-owned) as dead"
  fi
else
  printf '  note row18: no foreign-user pid available (running as root?); row17 covers the rule\n'
fi

# ---------------------------------------------------------------------------
# Row 19 (codex-8): _hil_write_owner REPORTS a failed owner write instead of
# swallowing it. Probe an unwritable lock dir; skipped with a note when the
# suite runs somewhere chmod cannot make a directory unwritable to it (root).
# ---------------------------------------------------------------------------
LOCK19="$T/row19.lock"
mkdir "$LOCK19"
chmod 500 "$LOCK19"
# 2>/dev/null first, output redirect second -- see _hil_write_owner's note on
# why the intuitive order lets the "Permission denied" line escape.
if : 2>/dev/null > "$LOCK19/probe"; then
  rm -f "$LOCK19/probe"
  printf '  note row19: dir stayed writable after chmod 500 (root?); write-failure path not probed\n'
else
  _hil_write_owner "$LOCK19" 4242 "$(hil_pid_namespace)" ""
  rc19=$?
  if [ "$rc19" -ne 0 ] && [ ! -e "$LOCK19/owner" ]; then
    ok "row19: _hil_write_owner reports failure on an unwritable lock dir"
  else
    bad "row19: rc=$rc19 (want non-zero) owner=$([ -e "$LOCK19/owner" ] && echo present || echo absent)"
  fi
fi
chmod 700 "$LOCK19"
rm -rf "$LOCK19"

# ---------------------------------------------------------------------------
# Row 19b (codex-8): a redirect that SUCCEEDS but leaves nothing behind is also
# a failure. The rc of the write alone does not cover it -- a filesystem that
# is full can accept the open and drop the bytes -- and hil_read_owner rejects
# an empty owner file as malformed, which is the same permanent-refusal wedge.
# /dev/null is the deterministic stand-in: writes to it succeed, its size stays
# 0, so only the non-empty check can catch it. Linux/macOS both have it; the
# row is skipped with a note where it is absent.
# ---------------------------------------------------------------------------
if [ -c /dev/null ]; then
  LOCK19B="$T/row19b.lock"
  mkdir "$LOCK19B"
  ln -s /dev/null "$LOCK19B/owner"
  _hil_write_owner "$LOCK19B" 4243 "$(hil_pid_namespace)" ""
  rc19b=$?
  if [ "$rc19b" -ne 0 ]; then
    ok "row19b: an owner write that succeeds but stores nothing is reported as failure"
  else
    bad "row19b: rc=$rc19b (want non-zero) for a zero-length owner file"
  fi
  rm -rf "$LOCK19B"
else
  printf '  note row19b: no /dev/null character device; empty-write path not probed\n'
fi

# ---------------------------------------------------------------------------
# Row 20 (codex-8): mkdir wins but the owner write fails -> hil_lock_acquire
# must remove the half-built lock and return non-zero. An OWNERLESS lock dir is
# refused by hil_lock_reclaim forever (owner missing => not ours to interpret),
# so leaving one wedges every future session on that record permanently. The
# failure is injected by overriding _hil_write_owner inside a subshell, which
# is the only way to reach this path without an actually-full filesystem.
# ---------------------------------------------------------------------------
REC20="$T/sess-20.json"
LOCK20="$REC20.lock"
(
  # Deliberate stub, invoked indirectly by hil_lock_acquire. Both codes for
  # the same finding across shellcheck generations -- see row 16's note.
  # shellcheck disable=SC2317,SC2329
  _hil_write_owner() { return 1; }
  hil_lock_acquire "$REC20"
) 2>/dev/null
rc20=$?
if [ "$rc20" -ne 0 ] && [ ! -e "$LOCK20" ]; then
  ok "row20: a failed owner write leaves no ownerless lock dir and fails the acquire"
else
  bad "row20: rc=$rc20 (want non-zero) lock=$([ -e "$LOCK20" ] && echo 'OWNERLESS DIR SURVIVED' || echo gone)"
fi
rm -rf "$LOCK20"

# ---------------------------------------------------------------------------
# Row 21 (codex-4): the recorder does NOT source the project-local
# scripts/guardrails/lib.sh. The recorder is what ESTABLISHES the integrity
# pins, so executing unverified project-local shell inside it hands a tampered
# checkout the recorder itself, before any check exists that could object.
# default_branch() is inlined instead; this row plants a lib.sh that would
# leave a marker if executed, and asserts both that the marker never appears
# and that the record is still a correct v2 one (i.e. the inlined resolver
# really is doing the work).
# ---------------------------------------------------------------------------
P21="$(new_fixture row21 main)"
OUT21="$T/row21/out"
MARKER21="$T/row21/TAMPER-EXECUTED"
cat > "$P21/scripts/guardrails/lib.sh" <<EOF
#!/usr/bin/env bash
# Tampered project-local lib. Sourcing this is the whole finding.
: > "$MARKER21"
default_branch() { printf 'main'; }
EOF
run_recorder "$P21" "$OUT21" "sess-21"
REC21="$OUT21/sess-21.json"
if [ ! -e "$MARKER21" ] \
  && [ -f "$REC21" ] \
  && [ "$(jq -r '.anchor_ref' "$REC21" 2>/dev/null)" = "refs/remotes/origin/main" ]; then
  ok "row21: a tampered project-local guardrails/lib.sh is never executed by the recorder"
else
  bad "row21: marker=$([ -e "$MARKER21" ] && echo 'EXECUTED' || echo absent) record=$(cat "$REC21" 2>/dev/null || echo '<no file>')"
fi

# ---------------------------------------------------------------------------
# Row 22 (round-2 panel, codex-2): the recorder does not source a TAMPERED lock
# lib. Round 1 closed this class one file over by inlining default_branch()
# (row 21) while the same commit opened it again on the lock lib, which was
# sourced unverified from scripts/lib/ -- a directory nothing pins. The lib
# moved into the pinned scripts/hooks/ AND the recorder now compares it against
# the blob at $anchor_ref before the dot; being pinned alone would not have
# been enough, since verifyProjectHookIntegrity only ever checks the ONE script
# being launched and a library is never launched.
#
# Same shape as row 21: plant a lib that leaves a marker if executed, assert
# the marker never appears. But the refusal to SOURCE must not become a refusal
# to RECORD -- see row 3 -- so this also asserts the pins landed, correct and
# complete, with the lock-free marker on them. Row 1 is the control for the
# healthy shape (record written, no lock_unverified key).
# ---------------------------------------------------------------------------
P22="$(new_fixture row22 main)"
OUT22="$T/row22/out"
MARKER22="$T/row22/TAMPER-EXECUTED"
cat >> "$P22/scripts/hooks/hook-integrity-lock.sh" <<EOF
: > "$MARKER22"
EOF
run_fixture_recorder "$P22" "$OUT22" "sess-22"
rc22=$?
REC22="$OUT22/sess-22.json"
if [ "$rc22" -eq 0 ] && [ ! -e "$MARKER22" ] && [ -f "$REC22" ] \
  && [ "$(jq -r '.anchor_ref' "$REC22" 2>/dev/null)" = "refs/remotes/origin/main" ] \
  && [ "$(jq -r '.pins["scripts/hooks/fake-guard.sh"] // empty' "$REC22")" \
     = "$(git -C "$P22" rev-parse HEAD:scripts/hooks/fake-guard.sh)" ] \
  && [ "$(jq -r '.lock_unverified // false' "$REC22")" = "true" ]; then
  ok "row22: a tampered lock lib is never sourced, yet the pins are still recorded lock-free"
else
  bad "row22: rc=$rc22 (want 0) marker=$([ -e "$MARKER22" ] && echo 'EXECUTED' || echo absent) record=$(cat "$REC22" 2>/dev/null || echo '<NO FILE — integrity system disabled>')"
fi

# ---------------------------------------------------------------------------
# Row 22b: the same tamper, but COMMITTED, so HEAD's blob matches the bytes on
# disk. HEAD is the source of pins_fresh and a local worker can move it, which
# is precisely why the verify step anchors on refs/remotes/origin/<default>
# instead. Without that choice this row passes while row 22 fails, and the
# whole check would be self-certifying.
# ---------------------------------------------------------------------------
P22B="$(new_fixture row22b main)"
OUT22B="$T/row22b/out"
MARKER22B="$T/row22b/TAMPER-EXECUTED"
cat >> "$P22B/scripts/hooks/hook-integrity-lock.sh" <<EOF
: > "$MARKER22B"
EOF
git -C "$P22B" -c user.email=t@t -c user.name=t add -A
git -C "$P22B" -c user.email=t@t -c user.name=t commit -q -m tamper
run_fixture_recorder "$P22B" "$OUT22B" "sess-22b"
rc22b=$?
REC22B="$OUT22B/sess-22b.json"
if [ "$rc22b" -eq 0 ] && [ ! -e "$MARKER22B" ] && [ -f "$REC22B" ] \
  && [ "$(jq -r '.lock_unverified // false' "$REC22B")" = "true" ] \
  && [ "$(git -C "$P22B" rev-parse HEAD:scripts/hooks/hook-integrity-lock.sh)" \
     = "$(git -C "$P22B" hash-object -- "$P22B/scripts/hooks/hook-integrity-lock.sh")" ]; then
  ok "row22b: a tamper committed to HEAD still fails the anchor check, and still records"
else
  bad "row22b: rc=$rc22b (want 0) marker=$([ -e "$MARKER22B" ] && echo 'EXECUTED' || echo absent) record=$(cat "$REC22B" 2>/dev/null || echo '<NO FILE — integrity system disabled>')"
fi

# ---------------------------------------------------------------------------
# Row 23 (round-2 panel, codex-1 option (a)): the RECREATED-LOCK timing. Row 16
# covers the window while the path is still empty -- the loser's rename fails
# ENOENT and it refuses. This row covers the window AFTER the winner has
# re-taken the lock under its own live pid: the loser's rename now SUCCEEDS,
# against a LIVE lock it never inspected. Renaming alone cannot tell the two
# apart, because a rename cannot be conditioned on which directory is at the
# path. The post-move identity re-read can, and must put the lock back.
#
# No inode check is involved and none is needed: a holder only ever writes its
# OWN pid into the owner file, and this code path was reached by proving the
# RECORDED pid is dead, so a recreated lock necessarily names a different
# owner. The mirror of this lives in reclaimIfDead in hook-integrity.js; the
# two implementations must agree.
#
# The stale read is stubbed, as in row 16, because the race window cannot be
# hit deterministically otherwise -- but the stub manufactures only the
# PRECONDITION (this contender latched the dead owner before the winner acted).
# What is under test is real code: whether hil_lock_reclaim notices that the
# directory it renamed aside is not the one it judged. The stub is first-call
# only; the second read -- the one that decides the outcome -- runs the real
# hil_read_owner against the real filesystem. A stub that answered BOTH calls
# would report the dead owner twice and pass no matter what the code did.
# ---------------------------------------------------------------------------
REC23="$T/sess-23.json"
LOCK23="$REC23.lock"
# The dead owner this contender latched, exactly as row 16 builds one.
( : ) &
dead23=$!
wait "$dead23" 2>/dev/null
# The WINNER's lock: same path, live owner (this test process), already
# re-taken by the time our loser gets to its rename.
mkdir "$LOCK23"
{
  printf 'pid=%s\n' "$$"
  printf 'pid_namespace=%s\n' "$(hil_pid_namespace)"
  printf 'start_time=%s\n' "$(hil_start_time "$$")"
} > "$LOCK23/owner"
winner_owner23="$(cat "$LOCK23/owner")"
(
  eval "$(declare -f hil_read_owner | sed '1s/^hil_read_owner/hil_read_owner_real/')"
  hil_read_owner_calls=0
  # Deliberate stub, invoked indirectly by hil_lock_reclaim; both linter codes
  # for the same finding across generations, plus SC2034 because the HIL_OWNER_*
  # globals it sets are read by the CALLER, not here -- see row 16's note.
  # shellcheck disable=SC2317,SC2329,SC2034
  hil_read_owner() {
    hil_read_owner_calls=$((hil_read_owner_calls + 1))
    if [ "$hil_read_owner_calls" -eq 1 ]; then
      HIL_OWNER_PID="$dead23"
      HIL_OWNER_NS="$(hil_pid_namespace)"
      HIL_OWNER_START=""
      return 0
    fi
    hil_read_owner_real "$@"
  }
  hil_lock_reclaim "$REC23"
)
rc23=$?
grave23=0
for f in "$LOCK23".dead.*; do
  [ -e "$f" ] || continue
  grave23=$((grave23 + 1))
done
# The owner CONTENT, not just the directory's existence: a restore that put
# back an empty or half-built directory would satisfy `-d` and still have
# destroyed the winner's claim.
if [ "$rc23" -ne 0 ] && [ -d "$LOCK23" ] \
  && [ "$(cat "$LOCK23/owner" 2>/dev/null)" = "$winner_owner23" ] \
  && [ "$grave23" -eq 0 ]; then
  ok "row23: a rename that lands on a RECREATED lock is put back and refused, owner intact"
else
  bad "row23: rc=$rc23 (want non-zero) lock=$([ -d "$LOCK23" ] && echo present || echo 'DELETED A LIVE LOCK') owner_match=$([ "$(cat "$LOCK23/owner" 2>/dev/null)" = "$winner_owner23" ] && echo yes || echo NO) graveyards=$grave23"
fi
rm -rf "$LOCK23" "$LOCK23".dead.*

# ---------------------------------------------------------------------------
# Row 24 (round-3 panel, codex-1): verifying the lock lib must not run the
# repository's own clean filter. The check used to hash the on-disk lib with
# `hash-object --path scripts/hooks/hook-integrity-lock.sh`, which makes git
# apply whatever `filter.<name>.clean` command a .gitattributes entry selects
# for that path -- and BOTH the attributes file and the filter command live
# inside the repository an attacker who can tamper with the lib already
# controls. That hands over both halves at once:
#   (a) arbitrary code execution inside the recorder, from the filter command
#       itself, before any verdict is even computed; and
#   (b) a hash of the FILTERED bytes, which the filter can make equal the
#       trusted anchor blob while the tampered bytes stay on disk and are
#       sourced a few lines later.
# `--no-filters` hashes the raw bytes actually about to be sourced.
#
# The fixture is the real mechanism, never a stub that synthesises the verdict:
# a genuine .gitattributes plus a genuine filter.pwn.clean whose script both
# strips the injected line (so the filtered form hashes to the pristine
# committed blob) and touches a marker (so the row can prove the filter command
# never ran at all). Three observables, and the pre-fix code fails all three:
# the filter did not execute, the laundered tamper was not sourced, and the
# record was still written -- lock-free and flagged, per row 3's rule that
# refusing to SOURCE must not become refusing to RECORD.
# ---------------------------------------------------------------------------
P24="$(new_fixture row24 main)"
OUT24="$T/row24/out"
SRC_MARKER24="$T/row24/TAMPER-SOURCED"
FILTER_MARKER24="$T/row24/CLEAN-FILTER-RAN"
# The injected line carries a sentinel the clean filter strips, so
# filter(tampered) is byte-identical to the pristine committed lib.
cat >> "$P24/scripts/hooks/hook-integrity-lock.sh" <<EOF
: > "$SRC_MARKER24" # HIL_R3W1_FILTER_SENTINEL
EOF
cat > "$P24/pwn-clean-filter.sh" <<EOF
#!/bin/sh
: > "$FILTER_MARKER24"
grep -v HIL_R3W1_FILTER_SENTINEL
EOF
chmod +x "$P24/pwn-clean-filter.sh"
printf 'scripts/hooks/hook-integrity-lock.sh filter=pwn\n' > "$P24/.gitattributes"
git -C "$P24" config filter.pwn.clean "$P24/pwn-clean-filter.sh"
# Precondition: the filter really does launder the tamper back to the anchor
# blob while the raw bytes differ from it. If that stops holding the row proves
# nothing, so it is asserted rather than assumed. Computing `laundered24` runs
# the filter, hence the marker reset before the recorder is invoked.
laundered24="$(git -C "$P24" hash-object --path scripts/hooks/hook-integrity-lock.sh \
  -- "$P24/scripts/hooks/hook-integrity-lock.sh" 2>/dev/null)"
raw24="$(git -C "$P24" hash-object --no-filters \
  -- "$P24/scripts/hooks/hook-integrity-lock.sh" 2>/dev/null)"
anchor_blob24="$(git -C "$P24" rev-parse --verify --quiet \
  refs/remotes/origin/main:scripts/hooks/hook-integrity-lock.sh 2>/dev/null)"
rm -f "$FILTER_MARKER24"
run_fixture_recorder "$P24" "$OUT24" "sess-24"
rc24=$?
REC24="$OUT24/sess-24.json"
if [ -z "$anchor_blob24" ] || [ "$laundered24" != "$anchor_blob24" ] || [ "$raw24" = "$anchor_blob24" ]; then
  bad "row24: fixture precondition broken -- laundered=$laundered24 raw=$raw24 anchor=$anchor_blob24"
elif [ "$rc24" -eq 0 ] && [ ! -e "$FILTER_MARKER24" ] && [ ! -e "$SRC_MARKER24" ] \
  && [ -f "$REC24" ] \
  && [ "$(jq -r '.pins["scripts/hooks/fake-guard.sh"] // empty' "$REC24")" \
     = "$(git -C "$P24" rev-parse HEAD:scripts/hooks/fake-guard.sh)" ] \
  && [ "$(jq -r '.lock_unverified // false' "$REC24")" = "true" ]; then
  ok "row24: verification runs no clean filter -- filter unexecuted, laundered tamper refused, pins still recorded"
else
  bad "row24: rc=$rc24 (want 0) filter=$([ -e "$FILTER_MARKER24" ] && echo 'EXECUTED' || echo absent) sourced=$([ -e "$SRC_MARKER24" ] && echo 'EXECUTED' || echo absent) record=$(cat "$REC24" 2>/dev/null || echo '<NO FILE — integrity system disabled>')"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
