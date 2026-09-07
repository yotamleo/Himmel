#!/usr/bin/env bash
# test-ast-update.sh — HIMMEL-1948 CR r1b: hermetic tests for ast-update.sh,
# the wrapper that serializes the hourly free structural (AST) refresh
# against refresh-graph-map.sh's per-out-dir promote lock (HIMMEL-910).
# Stubs `graphify` on PATH -- never a real extraction.
# Run: bash scripts/graphify/test-ast-update.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/ast-update.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT

# make_stub <bindir> [sleep_seconds] -- a graphify stub that records every
# invocation (args + PID) to $CALL_LOG and optionally sleeps before
# succeeding, so a test can grab a deterministic window while the lock is
# held.
make_stub() {
  local dir="$1" sleep_s="${2:-0}"
  mkdir -p "$dir"
  cat > "$dir/graphify" <<STUB
#!/usr/bin/env bash
echo "\$\$ \$*" >> "$WS/call.log"
sleep $sleep_s
exit 0
STUB
  chmod +x "$dir/graphify"
}

# --- T1: lock held -> SKIP, loudly, non-zero, graphify never invoked -------
echo "T1: lock held -> skip (loud, non-zero, no graphify invocation)"
CORPUS1="$WS/c1"; mkdir -p "$CORPUS1"
OUT1="$CORPUS1/graphify-out"
mkdir -p "$OUT1/.promote.lock"
printf 'holder-token\n' > "$OUT1/.promote.lock/owner"
date -u +%s > "$OUT1/.promote.lock/acquired"

BIN1="$WS/bin1"; make_stub "$BIN1"
: > "$WS/call.log"
out1=$( PATH="$BIN1:$PATH" bash "$SCRIPT" "$CORPUS1" 2>&1 ); rc1=$?

[ "$rc1" -eq 4 ] && pass "T1 exits 4 (documented skip code), never 0" \
  || fail "T1 should exit 4 (got $rc1): $out1"
echo "$out1" | grep -q "SKIPPED" && pass "T1 stderr is a loud SKIPPED, not silent" \
  || fail "T1 stderr should say SKIPPED: $out1"
[ -s "$WS/call.log" ] && fail "T1 graphify was invoked despite the held lock (bypass!)" \
  || pass "T1 graphify was never invoked"
[ -f "$OUT1/.promote.lock/owner" ] && [ "$(cat "$OUT1/.promote.lock/owner")" = "holder-token" ] \
  && pass "T1 the held lock's owner token is untouched" \
  || fail "T1 the held lock's owner token was disturbed"

# --- T2: lock free -> runs graphify, then releases the lock ----------------
echo "T2: lock free -> runs, then releases"
CORPUS2="$WS/c2"; mkdir -p "$CORPUS2"
OUT2="$CORPUS2/graphify-out"

BIN2="$WS/bin2"; make_stub "$BIN2"
: > "$WS/call.log"
out2=$( PATH="$BIN2:$PATH" bash "$SCRIPT" "$CORPUS2" 2>&1 ); rc2=$?

[ "$rc2" -eq 0 ] && pass "T2 exits 0 on a free lock" || fail "T2 should exit 0 (got $rc2): $out2"
grep -qF -- "update $CORPUS2 --force" "$WS/call.log" 2>/dev/null \
  && pass "T2 graphify was invoked as: update <corpus-root> --force (kept, HIMMEL-1938)" \
  || fail "T2 graphify was not invoked with the expected args: $(cat "$WS/call.log" 2>/dev/null)"
[ -d "$OUT2/.promote.lock" ] && fail "T2 the lock directory was left behind after success" \
  || pass "T2 the lock directory is gone after a successful run"

# --- T3: while held, the stamp is a numeric epoch; and a takeover mid-run --
# is respected -- the wrapper never deletes a lock it no longer owns. -------
echo "T3: acquired stamp is numeric while held; owner-tokened release respects a takeover"
CORPUS3="$WS/c3"; mkdir -p "$CORPUS3"
OUT3="$CORPUS3/graphify-out"

BIN3="$WS/bin3"; make_stub "$BIN3" 2
: > "$WS/call.log"
PATH="$BIN3:$PATH" bash "$SCRIPT" "$CORPUS3" > "$WS/t3.out" 2> "$WS/t3.err" &
PID3=$!

i=0
while [ ! -d "$OUT3/.promote.lock" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ -d "$OUT3/.promote.lock" ]; then
  pass "T3 the wrapper acquired the lock"
else
  fail "T3 setup: the wrapper never acquired the lock in time"
fi

stamp=$(cat "$OUT3/.promote.lock/acquired" 2>/dev/null || echo "")
case "$stamp" in
  ''|*[!0-9]*) fail "T3 'acquired' stamp is missing or non-numeric while held: '$stamp'" ;;
  *)           pass "T3 'acquired' stamp is a numeric epoch while held" ;;
esac

# Simulate a takeover: another refresh reclaimed this same lock while we're
# still "inside" the promote (mirrors refresh-graph-map.sh's stale-takeover
# window). The owner file now names a DIFFERENT token.
printf 'someone-elses-token\n' > "$OUT3/.promote.lock/owner"

wait "$PID3"; rc3=$?
[ "$rc3" -eq 0 ] && pass "T3 the wrapper still exits 0 (graphify itself succeeded)" \
  || fail "T3 should exit 0 (got $rc3): $(cat "$WS/t3.err")"
grep -q "taken over" "$WS/t3.err" && pass "T3 the takeover is called out loudly on stderr" \
  || fail "T3 stderr should WARN about the takeover: $(cat "$WS/t3.err")"
[ -d "$OUT3/.promote.lock" ] && [ "$(cat "$OUT3/.promote.lock/owner" 2>/dev/null)" = "someone-elses-token" ] \
  && pass "T3 the successor's lock was NOT deleted (owner-tokened release)" \
  || fail "T3 the wrapper deleted a lock it no longer owned"

# --- T5: GRAPHIFY_OUT override -- the lock follows the SAME out dir graphify
# itself will write to (relative name joins under corpus-root; absolute path
# is used as-is), not a hardcoded <corpus-root>/graphify-out. -----------------
echo "T5: GRAPHIFY_OUT override -- lock follows the resolved out dir"

# 5a: relative name -> joined under corpus-root.
CORPUS5A="$WS/c5a"; mkdir -p "$CORPUS5A"
OUT5A="$CORPUS5A/graphify-out-feature"
BIN5A="$WS/bin5a"; make_stub "$BIN5A"
out5a=$( PATH="$BIN5A:$PATH" GRAPHIFY_OUT="graphify-out-feature" bash "$SCRIPT" "$CORPUS5A" 2>&1 ); rc5a=$?
[ "$rc5a" -eq 0 ] && pass "T5a exits 0 with a relative GRAPHIFY_OUT override" \
  || fail "T5a should exit 0 (got $rc5a): $out5a"
[ -d "$OUT5A" ] && pass "T5a the relative override dir was used, joined under corpus-root" \
  || fail "T5a expected $OUT5A to exist"
[ -d "$CORPUS5A/graphify-out" ] && fail "T5a wrote the DEFAULT graphify-out despite the override (ignored the env var)" \
  || pass "T5a did not touch the default graphify-out dir"

# 5b: relative name, lock held -> skip, and the DEFAULT dir's (unrelated,
# never-contended) lock must be left completely alone -- proves the lock
# tracks the override, not a hardcoded path.
CORPUS5B="$WS/c5b"; mkdir -p "$CORPUS5B/graphify-out-feature/.promote.lock"
printf 'holder\n' > "$CORPUS5B/graphify-out-feature/.promote.lock/owner"
date -u +%s > "$CORPUS5B/graphify-out-feature/.promote.lock/acquired"
BIN5B="$WS/bin5b"; make_stub "$BIN5B"
: > "$WS/call.log"
out5b=$( PATH="$BIN5B:$PATH" GRAPHIFY_OUT="graphify-out-feature" bash "$SCRIPT" "$CORPUS5B" 2>&1 ); rc5b=$?
[ "$rc5b" -eq 4 ] && pass "T5b skips when the OVERRIDDEN dir's lock is held" \
  || fail "T5b should exit 4 (got $rc5b): $out5b"
[ -s "$WS/call.log" ] && fail "T5b graphify was invoked despite the overridden dir's held lock" \
  || pass "T5b graphify was never invoked (T5b)"

# 5c: absolute path -> used as-is, NOT joined under corpus-root.
CORPUS5C="$WS/c5c"; mkdir -p "$CORPUS5C"
SHARED_OUT="$WS/shared-graphify-out"
BIN5C="$WS/bin5c"; make_stub "$BIN5C"
out5c=$( PATH="$BIN5C:$PATH" GRAPHIFY_OUT="$SHARED_OUT" bash "$SCRIPT" "$CORPUS5C" 2>&1 ); rc5c=$?
[ "$rc5c" -eq 0 ] && pass "T5c exits 0 with an absolute GRAPHIFY_OUT override" \
  || fail "T5c should exit 0 (got $rc5c): $out5c"
[ -d "$SHARED_OUT" ] && pass "T5c the absolute override dir was used as-is (not joined under corpus-root)" \
  || fail "T5c expected $SHARED_OUT to exist"
[ -d "$CORPUS5C/graphify-out" ] && fail "T5c wrote the DEFAULT graphify-out despite the absolute override" \
  || pass "T5c did not touch the default graphify-out dir under corpus-root"
[ -d "$CORPUS5C$SHARED_OUT" ] && fail "T5c joined the absolute override under corpus-root instead of using it as-is" \
  || pass "T5c did not mistakenly join the absolute path under corpus-root"

# --- T4: usage error ---------------------------------------------------------
echo "T4: no corpus-root argument -> usage error"
out4=$( bash "$SCRIPT" 2>&1 ); rc4=$?
[ "$rc4" -eq 1 ] && pass "T4 missing corpus-root exits 1" || fail "T4 should exit 1 (got $rc4): $out4"

# --- T6: uncreatable OUT_DIR (a real fs failure) -> distinct FAILURE, NEVER
# exit 4 (HIMMEL-1948 CR r2) -- a swallowed `mkdir -p` used to fall through
# into the lock mkdir, whose failure (parent missing) was misread as "lock
# held" and reported hourly, forever, as a benign skip. GRAPHIFY_OUT points
# under a path component that exists as a FILE: mkdir -p under it fails
# portably (Windows Git Bash included) without needing permission tricks.
echo "T6: uncreatable OUT_DIR -> distinct FAILURE, never exit 4"
CORPUS6="$WS/c6"; mkdir -p "$CORPUS6"
BLOCKER="$WS/blocker-file"
: > "$BLOCKER"
BAD_OUT="$BLOCKER/graphify-out"

BIN6="$WS/bin6"; make_stub "$BIN6"
: > "$WS/call.log"
out6=$( PATH="$BIN6:$PATH" GRAPHIFY_OUT="$BAD_OUT" bash "$SCRIPT" "$CORPUS6" 2>&1 ); rc6=$?

[ "$rc6" -ne 4 ] && pass "T6 does NOT exit 4 for a real filesystem failure (got $rc6)" \
  || fail "T6 must not report a real fs failure as the benign lock-skip (exit 4): $out6"
[ "$rc6" -ne 0 ] && pass "T6 exits non-zero" || fail "T6 should not exit 0: $out6"
echo "$out6" | grep -qF "$BAD_OUT" && pass "T6 message names the resolved OUT_DIR" \
  || fail "T6 message should name the resolved OUT_DIR ($BAD_OUT): $out6"
echo "$out6" | grep -qF "GRAPHIFY_OUT" && pass "T6 message names the GRAPHIFY_OUT override" \
  || fail "T6 message should mention GRAPHIFY_OUT: $out6"
[ -s "$WS/call.log" ] && fail "T6 graphify was invoked despite the uncreatable OUT_DIR (bypass!)" \
  || pass "T6 graphify was never invoked"

# --- T7: the mandatory "acquired" stamp write itself fails (a real fs error,
# e.g. a bad mount, a stray directory left by something else) -> the lock is
# RELEASED (no stampless lock left for refresh-graph-map.sh's crashed-holder
# grace window to take over mid-write) and the script FAILS LOUDLY with exit
# 3 (not 4, not 0). Made to fail portably (Windows Git Bash included, no
# permission tricks) by shadowing `mkdir` on PATH: our stub intercepts the
# SAME `mkdir "$PROMOTE_LOCK"` call ast-update.sh itself makes to acquire the
# lock and, right after it really succeeds, pre-creates "acquired" as a
# directory INSIDE it -- deterministic, no timing race against the script.
echo "T7: acquired-stamp write fails -> FAILED (exit 3), lock released, no bypass"
CORPUS7="$WS/c7"; mkdir -p "$CORPUS7"
OUT7="$CORPUS7/graphify-out"

BIN7="$WS/bin7"
make_stub "$BIN7"
REAL_MKDIR="$(command -v mkdir)"
cat > "$BIN7/mkdir" <<STUB
#!/usr/bin/env bash
if [ "\$#" -eq 1 ]; then
  case "\$1" in
    */.promote.lock)
      "$REAL_MKDIR" "\$1" || exit \$?
      "$REAL_MKDIR" "\$1/acquired"
      exit 0
      ;;
  esac
fi
exec "$REAL_MKDIR" "\$@"
STUB
chmod +x "$BIN7/mkdir"
: > "$WS/call.log"
out7=$( PATH="$BIN7:$PATH" bash "$SCRIPT" "$CORPUS7" 2>&1 ); rc7=$?

[ "$rc7" -eq 3 ] && pass "T7 exits 3 (filesystem failure), not 4, not 0" \
  || fail "T7 should exit 3 (got $rc7): $out7"
echo "$out7" | grep -qF "$OUT7/.promote.lock/acquired" && pass "T7 message names the acquired-stamp path" \
  || fail "T7 message should name $OUT7/.promote.lock/acquired: $out7"
echo "$out7" | grep -q "filesystem failure" && pass "T7 message says this is a real filesystem failure" \
  || fail "T7 message should say filesystem failure: $out7"
[ -d "$OUT7/.promote.lock" ] && fail "T7 left a stampless lock directory behind (crashed-holder takeover risk)" \
  || pass "T7 the lock directory was released, nothing left behind"
[ -s "$WS/call.log" ] && fail "T7 graphify was invoked despite the stamp-write failure (bypass!)" \
  || pass "T7 graphify was never invoked"

# --- T8: graphify itself exits 4 -> the wrapper must NEVER surface its own
# reserved exit 4 (benign lock-skip) for a REAL graphify failure (HIMMEL-1948
# exit-code collision finding) -- stub graphify to exit 4, assert the wrapper
# does not exit 4 and its message does not read as a benign skip.
echo "T8: graphify itself exits 4 -> not reported as this script's benign skip (exit 4)"
CORPUS8="$WS/c8"; mkdir -p "$CORPUS8"
OUT8="$CORPUS8/graphify-out"

BIN8="$WS/bin8"; mkdir -p "$BIN8"
cat > "$BIN8/graphify" <<STUB
#!/usr/bin/env bash
echo "\$\$ \$*" >> "$WS/call.log"
exit 4
STUB
chmod +x "$BIN8/graphify"
: > "$WS/call.log"
out8=$( PATH="$BIN8:$PATH" bash "$SCRIPT" "$CORPUS8" 2>&1 ); rc8=$?

[ "$rc8" -ne 4 ] && pass "T8 does NOT exit 4 when graphify itself exits 4 (got $rc8)" \
  || fail "T8 a real graphify failure must not masquerade as this script's reserved exit 4: $out8"
[ "$rc8" -ne 0 ] && pass "T8 exits non-zero" || fail "T8 should not exit 0: $out8"
echo "$out8" | grep -q "SKIPPED" && fail "T8 message must not read as a benign skip: $out8" \
  || pass "T8 message does not read as a benign skip"
echo "$out8" | grep -qF "graphify update exited 4" && pass "T8 message names graphify's real exit code (4)" \
  || fail "T8 message should name graphify's real exit code: $out8"
[ -s "$WS/call.log" ] && pass "T8 graphify was actually invoked" \
  || fail "T8 setup: graphify stub was never invoked"
[ -d "$OUT8/.promote.lock" ] && fail "T8 the lock directory was left behind after a graphify failure" \
  || pass "T8 the lock directory is released even after a graphify failure"

# --- T9: TOCTOU on the lock mkdir (HIMMEL-1948 CR) -- the first mkdir fails
# because another holder has the lock, but that holder releases it before
# classification would run; the retry must observe the lock is now free and
# acquire it, NOT report exit 3 (real filesystem failure). Shadow `mkdir` on
# PATH (same technique as T7): on the FIRST call for .promote.lock, pre-
# create the lock dir (simulating a concurrent holder), let the real mkdir
# attempt fail against it, then remove the dir (simulating that holder's
# release) before returning the failure -- exactly the window the fix closes.
# The second call (the wrapper's retry) hits an unshadowed path below and
# succeeds for real.
echo "T9: lock held then released before classification -> retry acquires, NOT exit 3"
CORPUS9="$WS/c9"; mkdir -p "$CORPUS9"
OUT9="$CORPUS9/graphify-out"

BIN9="$WS/bin9"
make_stub "$BIN9"
REAL_MKDIR9="$(command -v mkdir)"
cat > "$BIN9/mkdir" <<STUB
#!/usr/bin/env bash
if [ "\$#" -eq 1 ]; then
  case "\$1" in
    */.promote.lock)
      if [ ! -f "$WS/t9-first-attempt-done" ]; then
        touch "$WS/t9-first-attempt-done"
        "$REAL_MKDIR9" "\$1"
        "$REAL_MKDIR9" "\$1"
        rc=\$?
        rm -rf "\$1"
        exit "\$rc"
      fi
      ;;
  esac
fi
exec "$REAL_MKDIR9" "\$@"
STUB
chmod +x "$BIN9/mkdir"
: > "$WS/call.log"
out9=$( PATH="$BIN9:$PATH" bash "$SCRIPT" "$CORPUS9" 2>&1 ); rc9=$?

[ "$rc9" -ne 3 ] && pass "T9 does NOT exit 3 for a lock released between mkdir failure and classification (got $rc9)" \
  || fail "T9 must not report a benign TOCTOU race as a real filesystem failure (exit 3): $out9"
[ "$rc9" -eq 0 ] && pass "T9 the retry acquired the lock and ran graphify to completion (exit 0)" \
  || fail "T9 should exit 0 once the retry acquires the freed lock (got $rc9): $out9"
grep -qF -- "update $CORPUS9 --force" "$WS/call.log" 2>/dev/null \
  && pass "T9 graphify was invoked after the retry acquired the lock" \
  || fail "T9 graphify was not invoked: $(cat "$WS/call.log" 2>/dev/null)"
[ -d "$OUT9/.promote.lock" ] && fail "T9 the lock directory was left behind after a successful retry+run" \
  || pass "T9 the lock directory is gone after a successful retry+run"

# --- T10: nonexistent CORPUS_ROOT -> FAILED (exit 3), loud, no bypass, no
# stray directory created (HIMMEL-1948 cadence-inversion finding) -- a typoed
# or missing corpus root used to be silently accepted (mkdir -p happily
# creates the whole OUT_DIR tree under it), so graphify ran hourly against an
# empty directory while the real corpus's graph went stale unalerted. Must
# fail LOUDLY before creating anything, never fall through to graphify.
echo "T10: nonexistent CORPUS_ROOT -> FAILED (exit 3), no graphify invocation, nothing created"
CORPUS10="$WS/does-not-exist-c10"

BIN10="$WS/bin10"; make_stub "$BIN10"
: > "$WS/call.log"
out10=$( PATH="$BIN10:$PATH" bash "$SCRIPT" "$CORPUS10" 2>&1 ); rc10=$?

[ "$rc10" -eq 3 ] && pass "T10 exits 3 (filesystem failure) for a nonexistent corpus root" \
  || fail "T10 should exit 3 (got $rc10): $out10"
echo "$out10" | grep -qF "$CORPUS10" && pass "T10 message names the missing CORPUS_ROOT path" \
  || fail "T10 message should name $CORPUS10: $out10"
[ -s "$WS/call.log" ] && fail "T10 graphify was invoked despite the missing corpus root (bypass!)" \
  || pass "T10 graphify was never invoked"
[ -e "$CORPUS10" ] && fail "T10 a stray path was created at the bogus corpus root" \
  || pass "T10 no stray directory was created at the bogus corpus root"

# --- T11 (HIMMEL-1960 CR r3): a NON-DIRECTORY on the lock path is a permanent
# filesystem conflict, not contention. mkdir fails EEXIST forever, `-d` stays
# false, and OUT_DIR itself remains perfectly writable -- so the writability
# probe that classifies the retry-exhausted case would call this "contention"
# and skip every hour, permanently, under the BENIGN exit code. That is exactly
# the false-benign class exit 3 exists for, and being name-specific it is
# invisible to any probe of a sibling path. ---
echo "T11: a regular file on the lock path -> FAILED (exit 3), never the benign skip"
CORPUS11="$WS/c11"; mkdir -p "$CORPUS11/graphify-out"
: > "$CORPUS11/graphify-out/.promote.lock"          # a FILE where the lock dir belongs

BIN11="$WS/bin11"; make_stub "$BIN11"
: > "$WS/call.log"
out11=$( PATH="$BIN11:$PATH" bash "$SCRIPT" "$CORPUS11" 2>&1 ); rc11=$?

[ "$rc11" -eq 3 ] && pass "T11 exits 3 for a non-directory occupying the lock path" \
  || fail "T11 should exit 3, not $rc11 (4 would mean an hourly permanent silent skip): $out11"
echo "$out11" | grep -qF "NOT a directory" && pass "T11 message names the conflict" \
  || fail "T11 message should say the lock path is not a directory: $out11"
[ -s "$WS/call.log" ] && fail "T11 graphify ran despite an unacquirable lock (bypass!)" \
  || pass "T11 graphify was never invoked"
[ -f "$CORPUS11/graphify-out/.promote.lock" ] && pass "T11 left the conflicting file alone (operator removes it)" \
  || fail "T11 must not delete the conflicting path itself"

# --- T12 (HIMMEL-1960 CR r4): a SYMLINK on the lock path. Both variants defeat
# a classifier that does not look at the link itself: one pointing at a real
# directory satisfies `-d` and reads as "held by a semantic refresh", while a
# DANGLING one fails `-e` (which follows the link) and then passes the sibling
# writability probe as "contention". Both would skip forever under the benign
# exit 4 on an hourly leg. Skipped, loudly, where symlinks cannot be created --
# unprivileged Windows without Developer Mode -- mirroring T35's probe/skip
# pattern in test-refresh-graph-map.sh rather than failing for the wrong reason. ---
echo "T12: a symlink on the lock path -> FAILED (exit 3), never the benign skip"
SYMPROBE="$WS/symprobe"; mkdir -p "$SYMPROBE/target"
if ln -s "$SYMPROBE/target" "$SYMPROBE/link" 2>/dev/null && [ -L "$SYMPROBE/link" ]; then
  BIN12="$WS/bin12"; make_stub "$BIN12"
  for variant in dir dangling; do
    CORPUS12="$WS/c12-$variant"; mkdir -p "$CORPUS12/graphify-out"
    if [ "$variant" = "dir" ]; then
      mkdir -p "$CORPUS12/real-lock-target"
      ln -s "$CORPUS12/real-lock-target" "$CORPUS12/graphify-out/.promote.lock"
    else
      ln -s "$CORPUS12/nothing-here-at-all" "$CORPUS12/graphify-out/.promote.lock"
    fi
    : > "$WS/call.log"
    out12=$( PATH="$BIN12:$PATH" bash "$SCRIPT" "$CORPUS12" 2>&1 ); rc12=$?
    [ "$rc12" -eq 3 ] && pass "T12/$variant exits 3 for a symlink on the lock path" \
      || fail "T12/$variant should exit 3, not $rc12 (4 = permanent silent hourly skip): $out12"
    echo "$out12" | grep -qF "SYMLINK" && pass "T12/$variant message names the symlink" \
      || fail "T12/$variant message should name the symlink: $out12"
    [ -s "$WS/call.log" ] && fail "T12/$variant graphify ran despite an unacquirable lock (bypass!)" \
      || pass "T12/$variant graphify was never invoked"
    [ -L "$CORPUS12/graphify-out/.promote.lock" ] && pass "T12/$variant left the symlink alone" \
      || fail "T12/$variant must not delete the conflicting symlink itself"
  done
else
  pass "T12 SKIPPED (this environment cannot create symlinks -- unprivileged Windows without Developer Mode; the classifier is still guarded on POSIX CI)"
fi

# --- T13 (HIMMEL-1960 CR r10): the structural leg must refuse the same source
# directories the semantic leg does. Before this, GRAPHIFY_OUT=docs made the two
# legs disagree -- refresh-graph-map.sh refused while this one wrote graph
# artifacts straight into <corpus>/docs. ---
echo "T13: an overridden GRAPHIFY_OUT pointing at source content -> FAILED (exit 3)"
CORPUS13="$WS/c13"; mkdir -p "$CORPUS13/docs"
printf 'real source content\n' > "$CORPUS13/docs/handbook.md"
BIN13="$WS/bin13"; make_stub "$BIN13"
: > "$WS/call.log"
out13=$( PATH="$BIN13:$PATH" GRAPHIFY_OUT="docs" bash "$SCRIPT" "$CORPUS13" 2>&1 ); rc13=$?
[ "$rc13" -eq 3 ] && pass "T13 exits 3 for an override pointing at a source dir" \
  || fail "T13 should exit 3, not $rc13 (4 would read as a benign skip): $out13"
[ -s "$WS/call.log" ] && fail "T13 graphify ran against a source directory (bypass!)" \
  || pass "T13 graphify was never invoked"
[ -f "$CORPUS13/docs/handbook.md" ] && pass "T13 the refused directory's contents are untouched" \
  || fail "T13 must not modify the directory it refuses"

# --- T14 (HIMMEL-1960 CR r12): a RELATIVE GRAPHIFY_OUT must be a single
# directory name, exactly as refresh-graph-map.sh requires. `foo/bar` was
# accepted here and refused there, so the two cadence legs would sit on
# different directories with the semantic one failing forever; `../out`
# resolves outside the corpus root altogether. ---
echo "T14: a multi-segment / dot-dot relative GRAPHIFY_OUT -> FAILED (exit 3)"
BIN14="$WS/bin14"; make_stub "$BIN14"
for bad in "foo/bar" "../out"; do
  CORPUS14="$WS/c14-$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '_')"; mkdir -p "$CORPUS14"
  : > "$WS/call.log"
  out14=$( PATH="$BIN14:$PATH" GRAPHIFY_OUT="$bad" bash "$SCRIPT" "$CORPUS14" 2>&1 ); rc14=$?
  [ "$rc14" -eq 3 ] && pass "T14 '$bad' is refused with exit 3" \
    || fail "T14 '$bad' should exit 3, not $rc14: $out14"
  [ -s "$WS/call.log" ] && fail "T14 '$bad' invoked graphify anyway (bypass!)" \
    || pass "T14 '$bad' never invoked graphify"
done
# The single-name form still works -- the rule must not swallow the legitimate case.
CORPUS14OK="$WS/c14-ok"; mkdir -p "$CORPUS14OK"
out14=$( PATH="$BIN14:$PATH" GRAPHIFY_OUT="graphify-out-feature" bash "$SCRIPT" "$CORPUS14OK" 2>&1 ); rc14=$?
[ "$rc14" -eq 0 ] && [ -d "$CORPUS14OK/graphify-out-feature" ] \
  && pass "T14 a single-name relative override still works" \
  || fail "T14 the single-name form must still be accepted (rc=$rc14): $out14"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
