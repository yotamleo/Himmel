#!/usr/bin/env bash
# Suite for scripts/ci/tmp-sweep.sh (HIMMEL-1978).
#
# Pins OUR contract only — the age guard, the prefix allow-list, dry-run vs
# apply, symlink safety, and the temp-path guard. It does not re-prove find(1).
#
# The fixture root sits UNDER the real temp dir so its own path satisfies the
# "looks like a temp dir" guard; the one case that must NOT satisfy that guard
# builds its fixture outside it.
#
# Usage: bash scripts/ci/test-tmp-sweep.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

SWEEP="$(cd "$(dirname "$0")" && pwd)/tmp-sweep.sh"

failures=0
skips=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }
skip() { printf '  SKIP  %s\n' "$1"; skips=$((skips+1)); }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# make_fixture <root> — sets HAS_LINK=1 when a real symlink could be created.
#   himmel-old-a / capguard-old-b  listed prefix, aged 10h  -> sweepable
#   himmel-new-c                   listed prefix, brand new -> protected by age
#   notours-old-d                  unlisted prefix, aged    -> protected by list
#   himmel-link-e                  symlink, aged            -> never touched
#
# The link points at notours-old-d, not at the young dir: where `touch -h` is
# unsupported the age stamp follows the link to its target, and aging an
# already-aged unlisted entry changes nothing. Aging himmel-new-c that way
# would have silently destroyed the age-guard case.
make_fixture() {
    local root="$1" stamp e
    HAS_LINK=0
    mkdir -p "$root/himmel-old-a" "$root/capguard-old-b" "$root/himmel-new-c" "$root/notours-old-d"
    echo payload > "$root/himmel-old-a/file"
    echo payload > "$root/notours-old-d/file"
    if ln -s "$root/notours-old-d" "$root/himmel-link-e" 2>/dev/null && [ -L "$root/himmel-link-e" ]; then
        HAS_LINK=1
    else
        rm -rf "$root/himmel-link-e"
    fi
    # 10 hours ago. -d is GNU touch; BSD touch wants -v.
    stamp=$(date -d '10 hours ago' '+%Y%m%d%H%M' 2>/dev/null) \
      || stamp=$(date -v-10H '+%Y%m%d%H%M' 2>/dev/null)
    for e in himmel-old-a capguard-old-b notours-old-d himmel-link-e; do
        [ -e "$root/$e" ] || [ -L "$root/$e" ] || continue
        touch -h -t "$stamp" "$root/$e" 2>/dev/null || touch -t "$stamp" "$root/$e" 2>/dev/null
    done
}

TMPROOT="${TMPDIR:-/tmp}"

echo "test-tmp-sweep.sh"

# Case A: dry-run reports the right matches and deletes nothing.
echo "== Case A: dry-run =="
root_a=$(mktemp -d "$TMPROOT/himmel-sweeptest.XXXXXX")
make_fixture "$root_a"
out=$(bash "$SWEEP" --root "$root_a" --older-than 6 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "dry-run rc=0"; else fail "dry-run rc=$rc"; fi
if grepq "$out" -E 'matched \(ours, older than 6h\): 2'; then
    pass "dry-run matched exactly the 2 old listed entries"
else
    fail "dry-run match count wrong: $out"
fi
if grepq "$out" -F 'nothing deleted'; then pass "dry-run says nothing deleted"; else fail "dry-run missing the nothing-deleted line"; fi
missing=''
for e in himmel-old-a capguard-old-b himmel-new-c notours-old-d; do
    [ -e "$root_a/$e" ] || missing="$missing $e"
done
if [ -z "$missing" ]; then pass "dry-run left every fixture entry in place"; else fail "dry-run removed:$missing"; fi
rm -rf "$root_a"

# Case B: --apply removes only old + listed; young, unlisted and symlink survive.
echo "== Case B: apply =="
root_b=$(mktemp -d "$TMPROOT/himmel-sweeptest.XXXXXX")
make_fixture "$root_b"
expect_after=$(( 2 + HAS_LINK ))   # himmel-new-c + notours-old-d [+ the link]
out=$(bash "$SWEEP" --root "$root_b" --older-than 6 --apply 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "apply rc=0"; else fail "apply rc=$rc"; fi
if [ ! -e "$root_b/himmel-old-a" ] && [ ! -e "$root_b/capguard-old-b" ]; then
    pass "apply removed both old listed entries"
else
    fail "apply left an old listed entry behind"
fi
if [ -e "$root_b/himmel-new-c" ]; then pass "apply kept the young listed entry"; else fail "apply deleted a young entry"; fi
if [ -e "$root_b/notours-old-d" ]; then pass "apply kept the unlisted prefix"; else fail "apply deleted an unlisted prefix"; fi
if [ "$HAS_LINK" -eq 1 ]; then
    if [ -L "$root_b/himmel-link-e" ]; then pass "apply left the aged symlink untouched"; else fail "apply removed the symlink"; fi
else
    skip "symlink case — this host cannot create symlinks"
fi
if grepq "$out" -E "entries after: $expect_after \(removed 2\)"; then
    pass "apply reported before/after counts"
else
    fail "apply before/after line wrong (expected after=$expect_after): $out"
fi
rm -rf "$root_b"

# Case C: a root outside the machine's temp roots is refused, rc=2, nothing
# listed and nothing deleted.
#
# The fixtures live under $HOME (they must be OUTSIDE any temp root — that is
# the whole point) and are removed with rmdir, never rm -rf: a $HOME path plus
# a recursive delete would destroy whatever the user happened to keep there.
#
# HIMMEL-2258: they are `mktemp -d` roots, like every other fixture in this
# suite, NOT fixed paths guarded by "skip if it already exists". That guard
# was a self-skipping shield: one interrupted run leaks the fixed directory
# and every host that ever hit that leak silently drops these six assertions
# from then on, while the suite still reports green. A unique root per run
# cannot collide, so the case ALWAYS executes and needs no skip branch.
echo "== Case C: non-temp root refused =="
root_c=$(mktemp -d "$HOME/.himmel-sweep-guard-fixture.XXXXXX") || root_c=""
# Engage-control: prove the scenario was actually staged. Without this, a
# fixture that failed to materialise would leave the assertions below passing
# or failing for a reason that has nothing to do with the guard under test —
# so a staging failure is a hard `fail`, not a report followed by running the
# case anyway on a bogus (possibly empty) root.
if [ -n "$root_c" ] && [ -d "$root_c" ]; then
    pass "guard case staged its fixture outside every temp root ($root_c)"
    # --older-than is absurd on purpose throughout this case: if the guard ever
    # regresses, the case must still be unable to delete anything.
    mkdir -p "$root_c/himmel-old-a"
    out=$(bash "$SWEEP" --root "$root_c" --older-than 999999 --apply 2>&1); rc=$?
    if [ "$rc" -eq 2 ]; then pass "root outside every temp root rc=2"; else fail "non-temp root rc=$rc (expected 2)"; fi
    if grepq "$out" -F "not under this machine's temp root"; then pass "refusal names the reason"; else fail "refusal message wrong: $out"; fi
    if [ -e "$root_c/himmel-old-a" ]; then pass "refusal deleted nothing"; else fail "refusal deleted the fixture"; fi
    rmdir "$root_c/himmel-old-a" "$root_c"
else
    fail "guard case could not stage its fixture at $root_c"
fi

# A root whose TEXT says "tmp" only because it traverses through a
# temp-looking directory must still be refused — the guard reads the
# resolved path, and $HOME is not a temp root (panel r1 codex-1, r2 codex-1).
# The mktemp suffix keeps the "tmp" component in the path text.
trav=$(mktemp -d "$HOME/.himmel-tmp-guard-fixture.XXXXXX") || trav=""
if [ -n "$trav" ] && [ -d "$trav" ]; then
    pass "traversal case staged its temp-named fixture ($trav)"
    out=$(bash "$SWEEP" --root "$trav/.." --older-than 999999 --apply 2>&1); rc=$?
    if [ "$rc" -eq 2 ]; then pass "traversal through a temp-named dir rc=2"; else fail "traversal root rc=$rc (expected 2)"; fi
    if grepq "$out" -F "not under this machine's temp root"; then pass "traversal refusal names the reason"; else fail "traversal refusal wrong: $out"; fi
    rmdir "$trav"
else
    fail "traversal case could not stage its fixture at $trav"
fi

# Case D: usage errors, and --help which is NOT one.
echo "== Case D: usage =="
bash "$SWEEP" --older-than 0 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "--older-than 0 rc=2"; else fail "--older-than 0 rc=$rc"; fi
bash "$SWEEP" --older-than abc >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "--older-than abc rc=2"; else fail "--older-than abc rc=$rc"; fi
bash "$SWEEP" --nope >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "unknown flag rc=2"; else fail "unknown flag rc=$rc"; fi
bash "$SWEEP" --help >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "--help rc=0"; else fail "--help rc=$rc (help is not a usage error)"; fi

# Case E: bare `tmp.XXXXXX` is coreutils mktemp's default template, so it is
# NOT ours by default — only --include-bare-mktemp opts into it (panel r3).
echo "== Case E: bare mktemp prefix is opt-in =="
root_e=$(mktemp -d "$TMPROOT/himmel-sweeptest.XXXXXX")
make_fixture "$root_e"
mkdir -p "$root_e/tmp.OTHERAP"
stamp_e=$(date -d '10 hours ago' '+%Y%m%d%H%M' 2>/dev/null) || stamp_e=$(date -v-10H '+%Y%m%d%H%M' 2>/dev/null)
touch -t "$stamp_e" "$root_e/tmp.OTHERAP"
out=$(bash "$SWEEP" --root "$root_e" --older-than 6 --apply 2>&1)
if [ -e "$root_e/tmp.OTHERAP" ]; then pass "default sweep left the bare tmp. entry alone"; else fail "default sweep deleted a bare tmp. entry"; fi
out=$(bash "$SWEEP" --root "$root_e" --older-than 6 --apply --include-bare-mktemp 2>&1)
if [ ! -e "$root_e/tmp.OTHERAP" ]; then pass "--include-bare-mktemp opts the bare tmp. entry in"; else fail "--include-bare-mktemp did not sweep the bare tmp. entry: $out"; fi
rm -rf "$root_e"

# Case F: --apply exits 3 when a matched entry survives the delete (HIMMEL-1995).
# The exit status has to come from the filesystem: the delete discards rm's
# errors on purpose, so only a re-match proves the sweep did what it printed.
# A real deletion failure is not reproducible by a same-user test: `rm -rf`
# makes a directory it owns writable before descending, so mode bits do not
# block it, and neither Git-Bash nor POSIX refuses to unlink a file the test
# still holds open (all five mechanisms were probed on the OVERLORD8 box; none
# blocked). So the failure is injected instead of provoked: `find -exec rm`
# resolves `rm` through PATH, and a stub that no-ops on the fixture root (and
# delegates every other path to the real binary, so the sweep still cleans up
# its own $WORK) leaves the matched entries in place. What is under test is
# ours — the post-apply re-match and the exit code — not the OS's refusal.
echo "== Case F: deletion shortfall exits 3 =="
root_f=$(mktemp -d "$TMPROOT/himmel-sweeptest.XXXXXX")
make_fixture "$root_f"
out=$(bash "$SWEEP" --root "$root_f" --older-than 6 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "dry-run never reports a shortfall (rc=0)"; else fail "dry-run rc=$rc"; fi

REAL_RM=$(command -v rm)
stub_f=$(mktemp -d "$TMPROOT/himmel-sweeptest-stub.XXXXXX")
cat > "$stub_f/rm" <<EOF
#!/usr/bin/env bash
case " \$* " in *"$root_f"*) exit 0 ;; esac
exec "$REAL_RM" "\$@"
EOF
chmod +x "$stub_f/rm"
out=$(PATH="$stub_f:$PATH" bash "$SWEEP" --root "$root_f" --older-than 6 --apply 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then pass "shortfall rc=3"; else fail "shortfall rc=$rc (expected 3): $out"; fi
if grepq "$out" -F '2 of 2 matched entries survived'; then
    pass "shortfall line carries requested-vs-survived counts"
else
    fail "shortfall count wrong: $out"
fi
if grepq "$out" -E 'entries after: '; then pass "the report is still printed"; else fail "shortfall suppressed the report: $out"; fi
rm -rf "$root_f" "$stub_f"

# Case G: the prefix list is templates, not family stems (HIMMEL-1995).
#   bench-run-batch-abort-runs-  a real mkdtempSync template     -> matched
#   telegram-bus-                the renamed telegram bus template -> matched
#   bench-marks-                 shares the OLD `bench-` stem     -> not ours
#   lc-                          the deleted underivable stem     -> not ours
echo "== Case G: narrowed prefixes =="
root_g=$(mktemp -d "$TMPROOT/himmel-sweeptest.XXXXXX")
mkdir -p "$root_g/bench-run-batch-abort-runs-AAAAAA" "$root_g/telegram-bus-AAAAAA" \
         "$root_g/bench-marks-AAAAAA" "$root_g/lc-AAAAAA"
stamp_g=$(date -d '10 hours ago' '+%Y%m%d%H%M' 2>/dev/null) || stamp_g=$(date -v-10H '+%Y%m%d%H%M' 2>/dev/null)
for e in bench-run-batch-abort-runs-AAAAAA telegram-bus-AAAAAA bench-marks-AAAAAA lc-AAAAAA; do
    touch -t "$stamp_g" "$root_g/$e"
done
out=$(bash "$SWEEP" --root "$root_g" --older-than 6 --apply 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "narrowed-prefix apply rc=0"; else fail "narrowed-prefix apply rc=$rc: $out"; fi
if [ ! -e "$root_g/bench-run-batch-abort-runs-AAAAAA" ]; then
    pass "a folded template prefix (bench-run-batch-) still matches"
else
    fail "bench-run-batch- no longer matches its own template"
fi
if [ ! -e "$root_g/telegram-bus-AAAAAA" ]; then
    pass "the renamed telegram-bus- template matches"
else
    fail "telegram-bus- did not match"
fi
if [ -e "$root_g/bench-marks-AAAAAA" ]; then
    pass "the bare bench- family stem no longer sweeps a foreign bench-* dir"
else
    fail "bench-marks- was swept — the family stem is still in the list"
fi
if [ -e "$root_g/lc-AAAAAA" ]; then
    pass "the underivable lc- stem is gone from the list"
else
    fail "lc- was swept — the stem is still in the list"
fi
rm -rf "$root_g"

echo
if [ "$failures" -eq 0 ]; then
    if [ "$skips" -gt 0 ]; then
        echo "test-tmp-sweep.sh: ALL PASS ($skips skipped)"
    else
        echo "test-tmp-sweep.sh: ALL PASS"
    fi
    exit 0
fi
echo "test-tmp-sweep.sh: $failures FAILED"
exit 1
