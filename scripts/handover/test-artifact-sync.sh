#!/usr/bin/env bash
# Tests for scripts/handover/artifact-sync.sh (HIMMEL-2201).
#
# Hermetic: pins HANDOVER_DIR to a temp root, never touches real handover
# state or a live artifact URL — the registry and local files are all
# temp-dir fixtures.
#
# Covers:
#   slice  1. strips line 1, clean input passes through.
#          2. leftover _FRAMEPREAMBLE/frame-runtime/<base href → exit 3, no write.
#         10. out-path under a not-yet-existing directory still succeeds.
#   record 3. writes a registry row with sha256 matching the local file.
#          4. re-recording the same URL replaces (not duplicates) its row.
#          5. record refuses a local file that still carries frame-runtime markup.
#         11. --title with no following value fails fast (exit 2), never loops.
#         13. record refuses a case/whitespace variant (<BASE  HREF=) too.
#   check  6. fresh registry → all rows OK, exit 0.
#          7. local file edited after record (drift) → FAIL, exit 3.
#          8. local file deleted after record → FAIL, exit 3.
#          9. no registry yet → exit 0 (nothing published through the helper).
#         12. a malformed (unparseable) registry row is a FAIL, never silently skipped.
#         14. --registry with no following value fails fast (exit 2), never loops.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/artifact-sync.sh"

PASS=0; FAIL=0; TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() { if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT" 2>/dev/null || true; fi; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/artifact-sync-test.XXXXXX")
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi
HROOT="$TMP_ROOT/handover"; mkdir -p "$HROOT"
export HANDOVER_DIR="$HROOT"

REGISTRY="$HROOT/.artifacts/registry.jsonl"

echo "=== slice ==="

raw1="$TMP_ROOT/raw-clean.html"
printf '<!-- host frame preamble line -->\n<html><body>hello</body></html>\n' > "$raw1"
out1="$TMP_ROOT/local-clean.html"
if bash "$SCRIPT" slice "$raw1" "$out1" >/dev/null 2>"$TMP_ROOT/slice1.err"; then
    if [ "$(cat "$out1")" = '<html><body>hello</body></html>' ]; then
        pass "slice: drops line 1, writes clean body"
    else
        fail "slice: drops line 1, writes clean body" "got: $(cat "$out1")"
    fi
else
    fail "slice: drops line 1, writes clean body" "$(cat "$TMP_ROOT/slice1.err")"
fi

raw2="$TMP_ROOT/raw-dirty.html"
printf '<!-- preamble -->\n<html><head>_FRAMEPREAMBLE</head><body>x</body></html>\n' > "$raw2"
out2="$TMP_ROOT/local-dirty.html"
rc=0
bash "$SCRIPT" slice "$raw2" "$out2" >/dev/null 2>"$TMP_ROOT/slice2.err" || rc=$?
if [ "$rc" -eq 3 ] && [ ! -f "$out2" ]; then
    pass "slice: refuses leftover _FRAMEPREAMBLE, exit 3, no write"
else
    fail "slice: refuses leftover _FRAMEPREAMBLE, exit 3, no write" "rc=$rc out2 exists=$([ -f "$out2" ] && echo yes || echo no)"
fi

out10="$TMP_ROOT/nested/does-not-exist-yet/local.html"
if bash "$SCRIPT" slice "$raw1" "$out10" >/dev/null 2>"$TMP_ROOT/slice3.err"; then
    pass "slice: succeeds when the out-path's directory doesn't exist yet"
else
    fail "slice: succeeds when the out-path's directory doesn't exist yet" "$(cat "$TMP_ROOT/slice3.err")"
fi

echo "=== record ==="

local1="$TMP_ROOT/board-v1.html"
printf '<html><body>board v1</body></html>\n' > "$local1"
if bash "$SCRIPT" record "https://claude.ai/artifact/aaa" "$local1" --title "Chain Board" >"$TMP_ROOT/rec1.out" 2>"$TMP_ROOT/rec1.err"; then
    expected_hash=$(sha256sum "$local1" | cut -d' ' -f1)
    if grep -qF "\"sha256\":\"$expected_hash\"" "$REGISTRY" && grep -qF '"url":"https://claude.ai/artifact/aaa"' "$REGISTRY"; then
        pass "record: writes a row with matching sha256"
    else
        fail "record: writes a row with matching sha256" "$(cat "$REGISTRY" 2>/dev/null)"
    fi
else
    fail "record: writes a row with matching sha256" "$(cat "$TMP_ROOT/rec1.err")"
fi

local1b="$TMP_ROOT/board-v2.html"
printf '<html><body>board v2 (leg 04g)</body></html>\n' > "$local1b"
bash "$SCRIPT" record "https://claude.ai/artifact/aaa" "$local1b" --title "Chain Board" >/dev/null 2>"$TMP_ROOT/rec2.err"
rows=$(grep -cF '"url":"https://claude.ai/artifact/aaa"' "$REGISTRY" 2>/dev/null || echo 0)
if [ "$rows" -eq 1 ] && grep -qF "board-v2.html" "$REGISTRY"; then
    pass "record: re-recording the same URL replaces its row"
else
    fail "record: re-recording the same URL replaces its row" "rows=$rows $(cat "$REGISTRY" 2>/dev/null)"
fi

local_dirty="$TMP_ROOT/board-dirty.html"
printf '<html><base href="https://claude.ai/x/"><body>x</body></html>\n' > "$local_dirty"
rc=0
bash "$SCRIPT" record "https://claude.ai/artifact/bbb" "$local_dirty" >/dev/null 2>"$TMP_ROOT/rec3.err" || rc=$?
if [ "$rc" -eq 3 ] && ! grep -qF '"url":"https://claude.ai/artifact/bbb"' "$REGISTRY" 2>/dev/null; then
    pass "record: refuses a local file still carrying frame-runtime markup"
else
    fail "record: refuses a local file still carrying frame-runtime markup" "rc=$rc"
fi

rc=0
if command -v timeout >/dev/null 2>&1; then
    # A generous budget: this guards against a genuine infinite loop, not
    # normal runtime -- git-bash/MSYS process-spawn overhead alone can eat
    # several seconds here, so a tight timeout produces a false failure.
    timeout 30 bash "$SCRIPT" record "https://claude.ai/artifact/ccc" "$local1" --title >/dev/null 2>"$TMP_ROOT/rec4.err" || rc=$?
else
    bash "$SCRIPT" record "https://claude.ai/artifact/ccc" "$local1" --title >/dev/null 2>"$TMP_ROOT/rec4.err" || rc=$?
fi
if [ "$rc" -eq 2 ]; then
    pass "record: --title with no value fails fast (exit 2), never loops"
else
    fail "record: --title with no value fails fast (exit 2), never loops" "rc=$rc (124 = timed out / looped) $(cat "$TMP_ROOT/rec4.err")"
fi

local_dirty_variant="$TMP_ROOT/board-dirty-variant.html"
printf '<html><BASE  HREF="https://claude.ai/x/"><body>x</body></html>\n' > "$local_dirty_variant"
rc=0
bash "$SCRIPT" record "https://claude.ai/artifact/vvv" "$local_dirty_variant" >/dev/null 2>"$TMP_ROOT/rec5.err" || rc=$?
if [ "$rc" -eq 3 ] && ! grep -qF '"url":"https://claude.ai/artifact/vvv"' "$REGISTRY" 2>/dev/null; then
    pass "record: refuses a case/whitespace variant of the base-href guard"
else
    fail "record: refuses a case/whitespace variant of the base-href guard" "rc=$rc"
fi

echo "=== check ==="

# Fresh registry (aaa @ v2 only, bbb never recorded) — should be all-clean.
rc=0
bash "$SCRIPT" check >"$TMP_ROOT/check1.out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -qF "OK https://claude.ai/artifact/aaa" "$TMP_ROOT/check1.out"; then
    pass "check: fresh registry passes, exit 0"
else
    fail "check: fresh registry passes, exit 0" "rc=$rc $(cat "$TMP_ROOT/check1.out")"
fi

# Drift: edit the recorded local file after the fact.
printf '<html><body>SOMEONE EDITED THIS WITHOUT REPUBLISHING</body></html>\n' > "$local1b"
rc=0
bash "$SCRIPT" check >"$TMP_ROOT/check2.out" 2>&1 || rc=$?
if [ "$rc" -eq 3 ] && grep -qF "FAIL https://claude.ai/artifact/aaa" "$TMP_ROOT/check2.out" && grep -qF "drifted" "$TMP_ROOT/check2.out"; then
    pass "check: local drift after record → FAIL, exit 3"
else
    fail "check: local drift after record → FAIL, exit 3" "rc=$rc $(cat "$TMP_ROOT/check2.out")"
fi

# Missing: delete the recorded local file.
rm -f "$local1b"
rc=0
bash "$SCRIPT" check >"$TMP_ROOT/check3.out" 2>&1 || rc=$?
if [ "$rc" -eq 3 ] && grep -qF "missing" "$TMP_ROOT/check3.out"; then
    pass "check: local file deleted after record → FAIL, exit 3"
else
    fail "check: local file deleted after record → FAIL, exit 3" "rc=$rc $(cat "$TMP_ROOT/check3.out")"
fi

# No registry at all yet (separate empty HANDOVER_DIR).
HROOT2="$TMP_ROOT/handover-empty"; mkdir -p "$HROOT2"
rc=0
HANDOVER_DIR="$HROOT2" bash "$SCRIPT" check >"$TMP_ROOT/check4.out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "check: no registry yet → exit 0"
else
    fail "check: no registry yet → exit 0" "rc=$rc $(cat "$TMP_ROOT/check4.out")"
fi

# Malformed row: no matching "url":"..." field at all.
printf '{"local":"%s","sha256":"deadbeef"}\n' "$local1" > "$REGISTRY"
rc=0
bash "$SCRIPT" check >"$TMP_ROOT/check5.out" 2>&1 || rc=$?
if [ "$rc" -eq 3 ] && grep -qF "FAIL <unparseable row>" "$TMP_ROOT/check5.out"; then
    pass "check: a malformed registry row is a FAIL, never silently skipped"
else
    fail "check: a malformed registry row is a FAIL, never silently skipped" "rc=$rc $(cat "$TMP_ROOT/check5.out")"
fi

rc=0
if command -v timeout >/dev/null 2>&1; then
    timeout 30 bash "$SCRIPT" check --registry >/dev/null 2>"$TMP_ROOT/check6.err" || rc=$?
else
    bash "$SCRIPT" check --registry >/dev/null 2>"$TMP_ROOT/check6.err" || rc=$?
fi
if [ "$rc" -eq 2 ]; then
    pass "check: --registry with no value fails fast (exit 2), never loops"
else
    fail "check: --registry with no value fails fast (exit 2), never loops" "rc=$rc (124 = timed out / looped) $(cat "$TMP_ROOT/check6.err")"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
