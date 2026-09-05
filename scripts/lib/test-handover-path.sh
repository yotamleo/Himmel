#!/usr/bin/env bash
# Smoke test for scripts/lib/handover-path.sh.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/handover-path.sh"
# shellcheck source=handover-path.sh
# shellcheck disable=SC1091
. "$LIB"
# shellcheck source=fixture-tempdir.sh
# shellcheck disable=SC1091
. "$(dirname "$LIB")/fixture-tempdir.sh"

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# T1: HANDOVER_DIR unset → inline default under repo root (pure)
# PURE handover_root only resolves when the dir already exists. The
# himmel repo has handovers/ tracked (README stub), so this passes on
# main without bootstrap.
unset HANDOVER_DIR
REPO=$(git rev-parse --show-toplevel)
got=$(handover_root)
expected=$(cd "$REPO/handovers" && pwd)
assert_eq "T1 mode A resolves to repo/handovers" "$expected" "$got"
assert_eq "T1 mode A reports A" "A" "$(handover_mode)"

# T1b: pure handover_root in Mode A with MISSING dir → rc=2 (HIMMEL-150).
# Use an isolated temp git repo with no handovers/ to exercise the pure
# fail-closed path without polluting himmel state.
TMP_REPO_PURE=$(fixture_mktemp_dir) || exit 1
git -C "$TMP_REPO_PURE" init --quiet
(
    cd "$TMP_REPO_PURE" || exit 1
    unset HANDOVER_DIR
    handover_root >/dev/null 2>&1
)
assert_rc "T1b pure handover_root rc=2 when inline missing" 2 "$?"
if [ -d "$TMP_REPO_PURE/handovers" ]; then
    echo "FAIL T1b pure resolver should NOT have mkdir'd"
    FAILED=$((FAILED + 1))
else
    echo "PASS T1b pure resolver did not mkdir"
fi
rm -rf "$TMP_REPO_PURE"

# T1c: handover_root_ensure in Mode A with missing dir → creates + rc=0.
TMP_REPO_ENSURE=$(fixture_mktemp_dir) || exit 1
git -C "$TMP_REPO_ENSURE" init --quiet
got_ensure=$(
    cd "$TMP_REPO_ENSURE" || exit 1
    unset HANDOVER_DIR
    handover_root_ensure 2>/dev/null
)
expected_ensure=$(cd "$TMP_REPO_ENSURE/handovers" 2>/dev/null && pwd)
assert_eq "T1c ensure resolves to repo/handovers" "$expected_ensure" "$got_ensure"
if [ -d "$TMP_REPO_ENSURE/handovers" ]; then
    echo "PASS T1c ensure did mkdir"
else
    echo "FAIL T1c ensure should have mkdir'd"
    FAILED=$((FAILED + 1))
fi
rm -rf "$TMP_REPO_ENSURE"

# T2: HANDOVER_DIR set to existing dir → mode B
mkdir -p "$TMP/external"
HANDOVER_DIR="$TMP/external"
got=$(handover_root)
expected=$(cd "$TMP/external" && pwd)
assert_eq "T2 mode B resolves to HANDOVER_DIR" "$expected" "$got"
assert_eq "T2 mode B reports B" "B" "$(handover_mode)"

# T3: HANDOVER_DIR set to non-existent dir → fail-closed rc=2
HANDOVER_DIR="$TMP/does-not-exist"
( handover_root >/dev/null 2>&1 )
assert_rc "T3 missing HANDOVER_DIR fails closed" 2 "$?"

# T4: HANDOVER_DIR set to a file (not dir) → fail-closed rc=2
touch "$TMP/not-a-dir"
HANDOVER_DIR="$TMP/not-a-dir"
( handover_root >/dev/null 2>&1 )
assert_rc "T4 HANDOVER_DIR is a file" 2 "$?"

# T5: HANDOVER_DIR empty string → treat as unset → inline default
unset HANDOVER_DIR
export HANDOVER_DIR=""
got=$(handover_root)
expected=$(cd "$REPO/handovers" && pwd)
assert_eq "T5 empty HANDOVER_DIR falls back to inline" "$expected" "$got"

# T6: trailing slash on HANDOVER_DIR is normalised
HANDOVER_DIR="$TMP/external/"
got=$(handover_root)
expected=$(cd "$TMP/external" && pwd)
assert_eq "T6 trailing slash normalised" "$expected" "$got"

# T7: _hp_json_field / _hp_json_escape unit cases (HIMMEL-882 CR round-4
# test-2). Direct coverage of the flat-JSON parser/escaper shared by
# queue-lock.sh and arm-resume.sh (previously only exercised indirectly
# through their acquire/rewrite flows).

# T7a: a value ending in a backslash immediately before the field's closing
# quote (the parity boundary) -- the raw value's trailing backslash doubles
# under _hp_json_escape, so the closing quote must read as UNESCAPED (an
# EVEN trailing-backslash count) and correctly terminate the value there.
raw7a=$'abc\\'
_hp_json_escape "$raw7a"; esc7a="$_HP_ESC"
line7a="{\"key\":\"$esc7a\",\"next\":\"ok\"}"
_hp_json_field "$line7a" key
assert_eq "T7a trailing-backslash value extracts in full (escaped form)" "$esc7a" "$_HP_FIELD"
_hp_json_field "$line7a" next
assert_eq "T7a boundary correctly found -- next field still parses" "ok" "$_HP_FIELD"

# T7b: a raw value with a literal backslash immediately adjacent to a
# literal double-quote -- escaping produces an ODD trailing-backslash run
# before an ESCAPED quote (the quote is part of the value, not the
# terminator), so the scan must keep going past it instead of truncating.
raw7b='x\"y'
_hp_json_escape "$raw7b"; esc7b="$_HP_ESC"
line7b="{\"key\":\"$esc7b\"}"
_hp_json_field "$line7b" key
assert_eq "T7b backslash-adjacent-to-quote value round-trips" "$esc7b" "$_HP_FIELD"

# T7c: an empty value ("key":"") extracts as the empty string, not a miss,
# and the scan still finds the next field's boundary correctly.
line7c='{"key":"","next":"ok"}'
_hp_json_field "$line7c" key
assert_eq "T7c empty value extracts as empty string" "" "$_HP_FIELD"
_hp_json_field "$line7c" next
assert_eq "T7c boundary correctly found after an empty value" "ok" "$_HP_FIELD"

# T7d: a key entirely absent from the line -- the return-on-miss branch
# reports the miss via $_HP_FIELD="" rather than leaving a stale value from
# a prior call.
_HP_FIELD="stale-from-a-prior-call"
line7d='{"other":"value"}'
_hp_json_field "$line7d" key
assert_eq "T7d absent key resets _HP_FIELD to empty (miss branch)" "" "$_HP_FIELD"

# T7e: the inverse used by legacy arms-registry migration preserves adjacent
# backslashes and quotes exactly.
_hp_json_unescape "$esc7b"
assert_eq "T7e escaped registry value decodes to the original raw value" "$raw7b" "$_HP_UNESC"

# T8 (HIMMEL-1344): registry identity is canonical, root-relative, and
# uniformly case-folded. The scheduler canonicalizer remains platform-specific,
# while the durable registry key must compare identically across machines.
ROOT8A="$TMP/layout-a/handovers"
ROOT8B="$TMP/layout-b/handovers"
mkdir -p "$ROOT8A/HIMMEL-1344-test" "$ROOT8B/HIMMEL-1344-test"
HO8A="$ROOT8A/HIMMEL-1344-test/next-session-1.md"
HO8B="$ROOT8B/HIMMEL-1344-test/next-session-1.md"
: > "$HO8A"
: > "$HO8B"
key8a=$(_arm_registry_identity_path "$ROOT8A/HIMMEL-1344-test/../HIMMEL-1344-test/next-session-1.md" "$ROOT8A")
key8b=$(_arm_registry_identity_path "$HO8B" "$ROOT8B")
expected8="root-relative:himmel-1344-test/next-session-1.md"
assert_eq "T8a alternate spelling canonicalizes to the folded root-relative key" "$expected8" "$key8a"
assert_eq "T8b different absolute layouts share one registry key" "$key8a" "$key8b"
MIXED8="$ROOT8A/HiMmEl-1344-TeSt/NeXt-SeSsIoN-1.Md"
key8_linux=$(PLATFORM=linux _arm_registry_identity_path "$MIXED8" "$ROOT8A")
key8_windows=$(PLATFORM=windows _arm_registry_identity_path "$MIXED8" "$ROOT8A")
assert_eq "T8c mixed-case registry key is equal across simulated platforms" "$key8_linux" "$key8_windows"
assert_eq "T8d mixed-case root-relative remainder is uniformly folded" "$expected8" "$key8_linux"
# T8e/T8f (HIMMEL-1344 codex-adv round): the outside-root `absolute:` branch
# PRESERVES case. It makes no cross-machine promise (documented cross-layout
# limitation), so folding buys nothing there — while on a case-sensitive
# filesystem it would collapse two genuinely distinct files onto one registry
# key and let one handover's re-arm retire the other's pending record.
outside8=$(PLATFORM=linux _arm_registry_identity_path "$TMP/Outside.MD" "$ROOT8A")
outside8_expected=$(PLATFORM=linux _arm_identity_path "$TMP/Outside.MD")
outside8_expected=$(printf 'absolute:%s' "$outside8_expected")
assert_eq "T8e outside-root absolute fallback preserves case" "$outside8_expected" "$outside8"
outside8_lower=$(PLATFORM=linux _arm_registry_identity_path "$TMP/outside.md" "$ROOT8A")
if [ "$outside8" != "$outside8_lower" ]; then
    echo "PASS T8f case-distinct outside-root handovers keep distinct registry keys"
else
    echo "FAIL T8f outside-root Foo.md and foo.md collapsed to one key '$outside8'"
    FAILED=$((FAILED + 1))
fi

# T9 (HIMMEL-2073): _arm_identity_path memoizes per (path, $PLATFORM) pair in
# $_ARM_CACHE_DIR (every call site is `x=$(_arm_identity_path ...)`, a command
# substitution that forks a subshell an in-memory cache cannot survive).
# Assert the cache dir/file actually gets created + populated (proves the
# mechanism is live, not just that recomputation happens to agree with
# itself), that a repeated call with the SAME path but a DIFFERENT $PLATFORM
# still returns the platform-correct answer (the exact regression T8c/T8d
# above already caught once: a naive path-only cache key served a stale
# cross-platform value), and — T9e, CR round 2 codex-5 — that a second call
# with the identical (path, PLATFORM) genuinely SKIPS recomputation rather
# than merely landing on the same answer by coincidence: a counting `realpath`
# stub on PATH proves it is invoked exactly once across two lookups.
# Clear cache CONTENTS only — $_ARM_CACHE_DIR itself is created ONCE at
# source time (top-level library code, not re-run per subshell), so unsetting
# or removing the directory here would leave every subsequent subshell with
# no cache dir to write into (caught in review: a first draft of this test
# did exactly that and made T9a fail against a WORKING library).
rm -f "${_ARM_CACHE_DIR:?}/identity" "${_ARM_CACHE_DIR:?}/cygpath-avail" 2>/dev/null || true
T9PATH="$TMP/layout-a/handovers/HIMMEL-1344-test/next-session-1.md"
first9=$(PLATFORM=linux _arm_identity_path "$T9PATH")
if [ -n "${_ARM_CACHE_DIR:-}" ] && [ -s "$_ARM_CACHE_DIR/identity" ]; then
    echo "PASS T9a identity-path cache dir/file is created and populated on first call"
else
    echo "FAIL T9a identity-path cache dir/file missing/empty after a call"
    FAILED=$((FAILED + 1))
fi
second9=$(PLATFORM=linux _arm_identity_path "$T9PATH")
assert_eq "T9b a cache HIT (same path, same PLATFORM) returns the identical value" "$first9" "$second9"
windows9=$(PLATFORM=windows _arm_identity_path "$T9PATH")
linux9_again=$(PLATFORM=linux _arm_identity_path "$T9PATH")
assert_eq "T9c a different PLATFORM for the SAME path is not served the other platform's cached value" "$first9" "$linux9_again"
if [ "$windows9" != "$first9" ]; then
    echo "PASS T9d windows (case-folded) and linux (case-preserved) cache independently for the same path"
else
    echo "FAIL T9d windows PLATFORM override returned the linux-cached (case-preserved) value"
    FAILED=$((FAILED + 1))
fi

# T9e: a counting realpath stub proves the SECOND identical lookup is an
# actual cache HIT (skips recomputation), not just an equal answer.
rm -f "${_ARM_CACHE_DIR:?}/identity" "${_ARM_CACHE_DIR:?}/cygpath-avail" 2>/dev/null || true
T9E_BIN="$TMP/t9e-bin"; mkdir -p "$T9E_BIN"
T9E_COUNT="$TMP/t9e-realpath-calls"
: > "$T9E_COUNT"
T9E_REAL_REALPATH=$(command -v realpath)
cat > "$T9E_BIN/realpath" <<EOF
#!/usr/bin/env bash
echo x >> "$T9E_COUNT"
exec "$T9E_REAL_REALPATH" "\$@"
EOF
chmod +x "$T9E_BIN/realpath"
_t9e_old_path="$PATH"
PATH="$T9E_BIN:$PATH"
PLATFORM=linux _arm_identity_path "$T9PATH" >/dev/null
PLATFORM=linux _arm_identity_path "$T9PATH" >/dev/null
PATH="$_t9e_old_path"
t9e_calls=$(wc -l < "$T9E_COUNT" | tr -d ' ')
assert_eq "T9e the SECOND identical lookup skips realpath entirely (cache hit, not a coincidental recompute)" "1" "$t9e_calls"

# T9f (CR round 2, codex-3 Suggestion): the SAME relative path string means a
# DIFFERENT file after a `cd` — the cache key must include $PWD, or a stale
# cross-directory answer gets served back.
rm -f "${_ARM_CACHE_DIR:?}/identity" "${_ARM_CACHE_DIR:?}/cygpath-avail" 2>/dev/null || true
T9F_DIR_A="$TMP/t9f-a"; T9F_DIR_B="$TMP/t9f-b"
mkdir -p "$T9F_DIR_A" "$T9F_DIR_B"
t9f_from_a=$(cd "$T9F_DIR_A" && PLATFORM=linux _arm_identity_path "rel.md")
t9f_from_b=$(cd "$T9F_DIR_B" && PLATFORM=linux _arm_identity_path "rel.md")
if [ "$t9f_from_a" != "$t9f_from_b" ]; then
    echo "PASS T9f the same relative path resolves independently per \$PWD (not cross-directory cached)"
else
    echo "FAIL T9f a relative path lookup after cd returned the OTHER directory's cached identity ($t9f_from_a)"
    FAILED=$((FAILED + 1))
fi

# CR round 5, codex-1 CRITICAL added an `[ -O "$_stale" ]` ownership guard as
# the PRIMARY defense ahead of the content-shape checks T9g/T9h below (a
# foreign-owned directory can never pass it, closing the class no
# content-shape heuristic alone can). Not exercised by its own test here:
# proving the negative (a directory NOT owned by this process survives)
# needs a second real OS user/UID, which this hermetic single-user suite has
# no way to simulate. T9g/T9h below still hold — they cover the OTHER half
# (a directory this process DOES own but that isn't actually one of ours).
#
# T9g (CR round 3, codex-1 Important): the GC sweep must never delete a
# same-named `arm-resume-cache.*` directory it did not create itself — only
# a candidate whose ENTIRE contents are exactly our own known filenames is
# eligible. TMPDIR is redirected to this test's own sandbox so the sweep
# never touches the real system temp dir.
T9G_TMPDIR="$TMP/t9g-tmpdir"; mkdir -p "$T9G_TMPDIR"
T9G_FOREIGN="$T9G_TMPDIR/arm-resume-cache.foreign"
mkdir -p "$T9G_FOREIGN"
printf 'not ours\n' > "$T9G_FOREIGN/unrelated-file.txt"
# Backdate it past the 1-day sweep threshold so age alone can't be why it survives.
touch -d '2 days ago' "$T9G_FOREIGN" 2>/dev/null || touch -t 202001010000 "$T9G_FOREIGN" 2>/dev/null || true
T9G_OURS="$T9G_TMPDIR/arm-resume-cache.ours"
mkdir -p "$T9G_OURS"
: > "$T9G_OURS/identity"
touch -d '2 days ago' "$T9G_OURS" 2>/dev/null || touch -t 202001010000 "$T9G_OURS" 2>/dev/null || true
TMPDIR="$T9G_TMPDIR" _arm_cache_dir_gc
if [ -d "$T9G_FOREIGN" ]; then
    echo "PASS T9g the GC sweep left a foreign same-named directory (unrecognized contents) alone"
else
    echo "FAIL T9g the GC sweep deleted a foreign same-named directory it did not create"
    FAILED=$((FAILED + 1))
fi
if [ ! -d "$T9G_OURS" ]; then
    echo "PASS T9g the GC sweep DID remove its own stale (>1 day) cache dir"
else
    echo "FAIL T9g the GC sweep left its own stale cache dir behind"
    FAILED=$((FAILED + 1))
fi

# T9h (CR round 4, codex-1 Important): a foreign entry that merely SHARES a
# name (`identity`) with our known file but is itself a DIRECTORY (holding
# arbitrary nested data) must NOT pass the shape check on name alone.
T9H_TRAP="$T9G_TMPDIR/arm-resume-cache.trap"
mkdir -p "$T9H_TRAP/identity"
printf 'nested foreign data\n' > "$T9H_TRAP/identity/payload.txt"
touch -d '2 days ago' "$T9H_TRAP" 2>/dev/null || touch -t 202001010000 "$T9H_TRAP" 2>/dev/null || true
TMPDIR="$T9G_TMPDIR" _arm_cache_dir_gc
if [ -d "$T9H_TRAP" ]; then
    echo "PASS T9h a directory named 'identity' (not a file) disqualifies the candidate, even though the name matches"
else
    echo "FAIL T9h the GC sweep deleted a directory holding foreign nested data because its name matched 'identity'"
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
