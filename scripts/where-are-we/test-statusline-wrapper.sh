#!/usr/bin/env bash
# Test for scripts/where-are-we/statusline.sh (HIMMEL-538 composition wrapper).
# Hermetic: stub base + stub segment via env seams — never runs the live vendored
# base (which reads live rate-limits) or a real node spawn.
# Exit: 0 = all pass, 1 = at least one failed.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$DIR/statusline.sh"
[ -x "$SUT" ] || chmod +x "$SUT" 2>/dev/null || true

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub base: emits two lines, NO trailing newline (mirrors the real vendored
# script). On EMPTY stdin it emits a distinct marker (mirrors the real base's
# empty-input branch) so we can prove the wrapper invokes it even with no input.
BASE="$TMP/base.sh"
cat > "$BASE" <<'STUB'
#!/usr/bin/env bash
in="$(cat 2>/dev/null || true)"
if [ -z "$in" ]; then printf 'EMPTY_SEEN'; else printf 'BASE_L1\nBASE_L2'; fi
STUB
chmod +x "$BASE"

# Stub segment: emits a fixed line.
SEG_OK="$TMP/seg-ok.sh"
printf '%s\n' '#!/usr/bin/env bash' "cat >/dev/null 2>&1 || true" "printf 'WAW_LINE'" > "$SEG_OK"; chmod +x "$SEG_OK"
# Stub segment that fails.
SEG_FAIL="$TMP/seg-fail.sh"
printf '%s\n' '#!/usr/bin/env bash' "exit 3" > "$SEG_FAIL"; chmod +x "$SEG_FAIL"
# Stub segment that emits nothing.
SEG_EMPTY="$TMP/seg-empty.sh"
printf '%s\n' '#!/usr/bin/env bash' "exit 0" > "$SEG_EMPTY"; chmod +x "$SEG_EMPTY"
# Stub base that emits a TRAILING NEWLINE (future-upstream check).
BASE_NL="$TMP/base-nl.sh"
printf '%s\n' '#!/usr/bin/env bash' "cat >/dev/null 2>&1 || true" "printf 'BASE_NL\n'" > "$BASE_NL"; chmod +x "$BASE_NL"

INPUT='{"cwd":"/tmp","model":{"display_name":"x"}}'

# --- Case 1: explicit opt-out → wrapper output == base, ZERO bytes added -----
# (HIMMEL-556: default is now ON, so suppression requires an explicit falsy value.)
want="$(printf '%s' "$INPUT" | bash "$BASE")"
for off in 0 false off no FALSE Off " no "; do
    got="$(HIMMEL_WHERE_ARE_WE="$off" HIMMEL_STATUSLINE_BASE="$BASE" HIMMEL_STATUSLINE_SEGMENT="$SEG_OK" \
           bash "$SUT" <<<"$INPUT" 2>/dev/null)"
    if [ "$got" = "$want" ]; then
        pass "opt-out '$off' -> wrapper adds zero bytes (== base)"
    else
        fail "opt-out '$off' -> got '$got' want '$want'"
    fi
done

# --- Case 1b: default ON (unset/empty) → segment renders --------------------
for on in "" "  "; do
    got="$(HIMMEL_WHERE_ARE_WE="$on" HIMMEL_STATUSLINE_BASE="$BASE" HIMMEL_STATUSLINE_SEGMENT="$SEG_OK" \
           bash "$SUT" <<<"$INPUT" 2>/dev/null)"
    if [ "$got" = "$(printf 'BASE_L1\nBASE_L2\nWAW_LINE')" ]; then
        pass "default ON (HIMMEL_WHERE_ARE_WE='$on') -> segment renders"
    else
        fail "default ON ('$on') -> got '$got'"
    fi
done

# --- Case 2: gate ON + segment line → base + \n + line ----------------------
got="$(HIMMEL_WHERE_ARE_WE=1 HIMMEL_STATUSLINE_BASE="$BASE" HIMMEL_STATUSLINE_SEGMENT="$SEG_OK" \
       bash "$SUT" <<<"$INPUT" 2>/dev/null)"
if [ "$got" = "$(printf 'BASE_L1\nBASE_L2\nWAW_LINE')" ]; then
    pass "gate ON -> base + newline + segment line"
else
    fail "gate ON -> got '$got'"
fi

# --- Case 3: gate ON + segment FAILS → base only (fail-open) ----------------
got="$(HIMMEL_WHERE_ARE_WE=1 HIMMEL_STATUSLINE_BASE="$BASE" HIMMEL_STATUSLINE_SEGMENT="$SEG_FAIL" \
       bash "$SUT" <<<"$INPUT" 2>/dev/null)"
if [ "$got" = "$(printf 'BASE_L1\nBASE_L2')" ]; then
    pass "segment fails -> base only"
else
    fail "segment fails -> got '$got'"
fi

# --- Case 4: gate ON + segment empty → base only (no stray newline) ---------
got="$(HIMMEL_WHERE_ARE_WE=1 HIMMEL_STATUSLINE_BASE="$BASE" HIMMEL_STATUSLINE_SEGMENT="$SEG_EMPTY" \
       bash "$SUT" <<<"$INPUT" 2>/dev/null)"
if [ "$got" = "$(printf 'BASE_L1\nBASE_L2')" ]; then
    pass "segment empty -> base only, no trailing newline"
else
    fail "segment empty -> got '$got'"
fi

# --- Case 5: empty stdin → base's empty-input branch still runs -------------
got="$(HIMMEL_WHERE_ARE_WE=1 HIMMEL_STATUSLINE_BASE="$BASE" HIMMEL_STATUSLINE_SEGMENT="$SEG_EMPTY" \
       bash "$SUT" </dev/null 2>/dev/null)"
if [ "$got" = "EMPTY_SEEN" ]; then
    pass "empty stdin -> base empty-input branch runs"
else
    fail "empty stdin -> got '$got'"
fi

# --- Case 6: base emits trailing newline → single separator (normalization) -
got="$(HIMMEL_WHERE_ARE_WE=1 HIMMEL_STATUSLINE_BASE="$BASE_NL" HIMMEL_STATUSLINE_SEGMENT="$SEG_OK" \
       bash "$SUT" <<<"$INPUT" 2>/dev/null)"
if [ "$got" = "$(printf 'BASE_NL\nWAW_LINE')" ]; then
    pass "base trailing newline -> exactly one separator"
else
    fail "base trailing newline -> got '$got'"
fi

# --- Case 7: hanging segment bounded by SEG_TIMEOUT → base only (I7) --------
SEG_HANG="$TMP/seg-hang.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 30' > "$SEG_HANG"; chmod +x "$SEG_HANG"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    start="$(date +%s)"
    got="$(HIMMEL_WHERE_ARE_WE=1 HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=1 \
           HIMMEL_STATUSLINE_BASE="$BASE" HIMMEL_STATUSLINE_SEGMENT="$SEG_HANG" \
           bash "$SUT" <<<"$INPUT" 2>/dev/null)"
    elapsed="$(( $(date +%s) - start ))"
    if [ "$got" = "$(printf 'BASE_L1\nBASE_L2')" ] && [ "$elapsed" -lt 10 ]; then
        pass "hanging segment -> base only, bounded (${elapsed}s)"
    else
        fail "hanging segment -> elapsed=${elapsed}s got='$got'"
    fi
else
    pass "hanging segment bound -> SKIPPED (no timeout/gtimeout on this host)"
fi

# --- Case 8: hanging BASE bounded by BASE_TIMEOUT -> cut off, segment still ---
# renders, wrapper does NOT hang forever (HIMMEL-717: the base was previously
# unbounded, orphaning the wrapper on a hung network read). Correctness assertion
# (LATE_BASE never appears) is load-independent; the timing bound is generous so
# the test is not flaky on a loaded MSYS host.
BASE_HANG="$TMP/base-hang.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 60; printf LATE_BASE' > "$BASE_HANG"; chmod +x "$BASE_HANG"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    start="$(date +%s)"
    got="$(HIMMEL_WHERE_ARE_WE=1 HIMMEL_STATUSLINE_BASE_TIMEOUT=2 \
           HIMMEL_STATUSLINE_BASE="$BASE_HANG" HIMMEL_STATUSLINE_SEGMENT="$SEG_OK" \
           bash "$SUT" <<<"$INPUT" 2>/dev/null)"
    elapsed="$(( $(date +%s) - start ))"
    # Base killed before it prints LATE_BASE -> empty base, only the segment line
    # survives (leading separator, since base contributed nothing).
    case "$got" in
        *LATE_BASE*) fail "hanging base -> base NOT cut off (got '$got')" ;;
        *WAW_LINE)   if [ "$elapsed" -lt 40 ]; then
                         pass "hanging base -> cut off, segment renders, bounded (${elapsed}s)"
                     else
                         fail "hanging base -> unbounded (${elapsed}s)"
                     fi ;;
        *)           fail "hanging base -> unexpected got='$got' (${elapsed}s)" ;;
    esac
else
    pass "hanging base bound -> SKIPPED (no timeout/gtimeout on this host)"
fi

echo "---"
echo "wrapper: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
