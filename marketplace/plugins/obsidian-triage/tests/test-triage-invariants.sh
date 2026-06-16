#!/usr/bin/env bash
# Invariant tests for /triage-clips.
#
# Scope: validates the bash-checkable invariants the command must hold,
# without invoking the LLM agent itself. The agent's behavior is tested
# during calibration on real clips — these are the structural guards
# that should hold for any future agent implementation:
#
#   1. Scan helper correctly partitions files by `processed: true` line.
#   2. Frontmatter mutation contract: appending `processed: true` after
#      existing keys + block-list values lands at zero-indent (NOT
#      inside any list).
#   3. Dedup-by-backreference helper: detects whether a clip's Phase-5
#      backref is already present in a daily-note simulation.
#   4. Multi-line `tags:` block-list fixture is recognized by the scan.
#
# Portable bash. Verified on Git Bash for Windows (the `grep -L` and
# `grep -q` exit-code quirks are worked around explicitly below).

# NOTE: do NOT use `set -e`. `grep -L` returns nonzero on Git Bash
# (Windows) even when files print. We use explicit assert() instead.
# `set -o pipefail` IS safe — it catches LHS pipeline failures that
# `set -e` alone would also catch, without the grep-exit-code issue.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures/clips"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Pre-flight: fixtures dir exists and is non-empty.
if [ ! -d "$FIXTURES" ]; then
    echo "PRE-FLIGHT FAIL: fixtures dir missing: $FIXTURES"
    exit 1
fi
if [ -z "$(ls -A "$FIXTURES"/*.md 2>/dev/null)" ]; then
    echo "PRE-FLIGHT FAIL: no *.md fixtures in $FIXTURES"
    exit 1
fi

# Count files that LACK a given pattern. Portable wrapper around grep -L
# whose exit code differs across grep builds (Git Bash returns 1 even
# when files are listed, GNU returns 0). Distinguishes:
#   rc=0  match found        → file HAS pattern, don't count
#   rc=1  no match           → file LACKS pattern, count it
#   rc=2  file error / other → bail out with a clear error
count_files_without_pattern() {
    local pattern="$1"
    shift
    local n=0
    local rc
    for f in "$@"; do
        if [ ! -r "$f" ]; then
            echo "  ERROR  count_files_without_pattern: unreadable file: $f" >&2
            return 2
        fi
        grep -q "$pattern" "$f"
        rc=$?
        case "$rc" in
            0) ;;            # match — file has pattern
            1) n=$((n+1)) ;; # no match — file lacks pattern
            *)
                echo "  ERROR  grep rc=$rc on: $f" >&2
                return 2
                ;;
        esac
    done
    echo "$n"
}

assert() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# Set up: copy fixtures to a temp Clippings/ folder so we don't
# mutate the committed fixtures.
mkdir -p "$TMP/Clippings"
cp "$FIXTURES"/*.md "$TMP/Clippings/"

# Count via find (shellcheck SC2012: prefer find over ls for non-alphanumeric filenames)
fixture_count=$(find "$TMP/Clippings" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')

echo "Test 1: fresh fixtures (no processed marker) are all selected"
count=$(count_files_without_pattern "^processed: true$" "$TMP/Clippings/"*.md)
assert "all fixtures unprocessed (expected $fixture_count)" "$fixture_count" "$count"

echo "Test 2: mark one flow-style-tags fixture as processed (Phase 7 simulation)"
target="$TMP/Clippings/Sample tweet by jane.md"
[ -r "$target" ] || { echo "PRE-FLIGHT FAIL: target fixture missing: $target"; exit 1; }
# Insert `processed: true` + `triaged_at:` into frontmatter before the closing ---
# This mirrors the documented Phase 7 placement contract.
python3 - "$target" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
parts = text.split('---\n', 2)
if len(parts) < 3:
    sys.exit("frontmatter parse error in fixture")
fm = parts[1]
body = parts[2]
fm = fm.rstrip() + "\nprocessed: true\ntriaged_at: 2026-05-25\n"
p.write_text(f"---\n{fm}---\n{body}", encoding='utf-8')
PY
py_rc=$?
if [ "$py_rc" -ne 0 ]; then
    echo "  FAIL  Phase 7 simulation Python heredoc crashed (rc=$py_rc) — fixture may be partially written"
    fail=$((fail+1))
    echo "Skipping remaining Phase-7 simulation tests (1 abort)."
    echo ""
    echo "Results: $pass passed, $fail failed"
    exit 1
fi

# Verify file is still readable + non-empty before grepping.
if [ ! -r "$target" ] || [ ! -s "$target" ]; then
    echo "  FAIL  fixture file missing or empty after mutation: $target"
    fail=$((fail+1))
    echo "Results: $pass passed, $fail failed"
    exit 1
fi

count=$(count_files_without_pattern "^processed: true$" "$TMP/Clippings/"*.md)
expected_remaining=$((fixture_count - 1))
assert "$expected_remaining fixtures remain unprocessed after marking 1" "$expected_remaining" "$count"

echo "Test 3: frontmatter structure intact after mutation"
head -1 "$target" | grep -q "^---$" && fm_open=ok || fm_open=missing
assert "frontmatter open delimiter intact" "ok" "$fm_open"

# Body sections present (fixture-agnostic — count any `## ` heading).
heading_count=$(grep -c "^## " "$target" 2>/dev/null || true)
[ -z "$heading_count" ] && heading_count=0
[ "$heading_count" -ge 1 ] && body_intact=ok || body_intact=missing
assert "at least one body heading present after mutation" "ok" "$body_intact"

# processed: true present exactly once.
processed_count=$(grep -c "^processed: true$" "$target" 2>/dev/null || true)
[ -z "$processed_count" ] && processed_count=0
assert "processed:true appears exactly once" "1" "$processed_count"

# Phase 7 placement contract: processed:true MUST be at zero indent
# (not inside a list).
python3 - "$target" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
parts = text.split('---\n', 2)
if len(parts) < 3:
    sys.exit("frontmatter unparseable after mutation")
fm = parts[1]
lines = fm.splitlines()
found = False
for line in lines:
    if line.startswith("processed: true"):
        found = True
        break
    if line.startswith("  - processed"):
        sys.exit("PLACEMENT BUG: processed:true landed inside a list item")
if not found:
    sys.exit("processed: true not found at zero indent in frontmatter")
PY
py_rc=$?
if [ "$py_rc" -eq 0 ]; then
    echo "  PASS  processed:true at zero indent (NOT inside any list)"
    pass=$((pass+1))
else
    echo "  FAIL  Phase 7 placement contract violated (Python check rc=$py_rc)"
    fail=$((fail+1))
fi

echo "Test 4: scan re-decision after marking — idempotency hook"
if grep -q "^processed: true$" "$target"; then
    skip_decision=skip
else
    skip_decision=process
fi
assert "scan decides to skip already-marked clip" "skip" "$skip_decision"

echo "Test 5: block-style tags fixture is unprocessed and detectable"
block_target="$TMP/Clippings/Sample reddit with block tags.md"
if [ -r "$block_target" ]; then
    if grep -q "^processed: true$" "$block_target"; then
        block_decision=already_processed
    else
        block_decision=unprocessed
    fi
    assert "block-style-tags fixture starts unprocessed" "unprocessed" "$block_decision"

    # Confirm fixture has the expected block-style tags structure
    # (covers the audit gap: Phase 3 must handle this shape correctly).
    has_block_tags=no
    if grep -q "^tags:$" "$block_target" && grep -q "^  - learning$" "$block_target"; then
        has_block_tags=yes
    fi
    assert "block-style-tags fixture has the expected YAML shape" "yes" "$has_block_tags"
else
    echo "  WARN  block-style fixture missing — skipping Test 5"
fi

echo "Test 6: bare-tags fixture (YAML null) — Branch 3 vs Branch 4 disambiguation (LUNA-8)"
# Real-world shape from LUNA-2 Web Clipper templates: bare `tags:` with
# no value — YAML null. Phase 3 must handle this as Branch 4 (null) and
# distinguish it from Branch 3 (block-list, where `tags:` is followed by
# `  - item` lines). Both share the same first-line regex
# `^tags:[[:space:]]*$` and can only be told apart by look-ahead at the
# next non-blank line. Present in 100% of the 245-clip corpus.
bare_target="$TMP/Clippings/bare-tags.md"
if [ -r "$bare_target" ]; then
    if grep -q "^processed: true$" "$bare_target"; then
        bare_decision=already_processed
    else
        bare_decision=unprocessed
    fi
    assert "bare-tags fixture starts unprocessed" "unprocessed" "$bare_decision"

    # First-line regex: matches both Branch 3 and Branch 4 (this is by design;
    # disambiguation lives in the next-line look-ahead below).
    has_bare_tags=no
    if grep -qE "^tags:[[:space:]]*$" "$bare_target" \
       && ! grep -qE "^tags:[[:space:]]*\[\]" "$bare_target"; then
        has_bare_tags=yes
    fi
    assert "bare-tags fixture matches the first-line null-tags regex" "yes" "$has_bare_tags"

    # Branch 3 vs Branch 4 disambiguation: line AFTER `tags:` is the signal.
    # Use awk to grab the line immediately following the `tags:` match.
    bare_next="$(awk '/^tags:[[:space:]]*$/ {getline; print; exit}' "$bare_target")"
    if printf '%s' "$bare_next" | grep -qE "^  - "; then
        bare_branch=branch3_block
    else
        bare_branch=branch4_null
    fi
    assert "bare-tags fixture routes to Branch 4 (null) via next-line look-ahead" "branch4_null" "$bare_branch"

    # Block-style fixture: SAME first-line regex matches, but next line IS
    # `  - learning`, so it must route to Branch 3 instead.
    block_lookahead="$TMP/Clippings/Sample reddit with block tags.md"
    if [ -r "$block_lookahead" ]; then
        block_next="$(awk '/^tags:[[:space:]]*$/ {getline; print; exit}' "$block_lookahead")"
        if printf '%s' "$block_next" | grep -qE "^  - "; then
            block_branch=branch3_block
        else
            block_branch=branch4_null
        fi
        assert "block-style fixture routes to Branch 3 (block-list) via next-line look-ahead" "branch3_block" "$block_branch"
    fi

    # Negative-check: flow-empty fixture (`tags: []`) must NOT match the
    # first-line null-tags regex — Branch 1 owns it.
    flow_target="$TMP/Clippings/Sample tweet by jane.md"
    if [ -r "$flow_target" ]; then
        flow_misroute=no
        if grep -qE "^tags:[[:space:]]*$" "$flow_target" \
           && ! grep -qE "^tags:[[:space:]]*\[\]" "$flow_target"; then
            flow_misroute=yes
        fi
        assert "flow-empty fixture does NOT match bare-tags first-line regex (no misroute)" "no" "$flow_misroute"
    fi
else
    echo "  FAIL  bare-tags fixture missing — LUNA-8 fix not exercised"
    fail=$((fail+1))
fi

echo "Test 7: dedup-by-backreference helper (Phase 5 idempotency simulation)"
# Simulate a daily note that already contains a backref to the tweet
# clip — Phase 5 must skip re-appending.
daily="$TMP/daily-2026-05-25.md"
{
    echo "---"
    echo "date: 2026-05-25"
    echo "type: daily"
    echo "---"
    echo ""
    echo "# 2026-05-25"
    echo ""
    echo "## Actions from clips"
    echo "- [ ] Find the original paper Jane references (from [[Clippings/Sample tweet by jane]])"
} > "$daily"

# Phase 5 dedup check: grep for the exact backref pattern.
backref="(from [[Clippings/Sample tweet by jane]])"
if grep -qF "$backref" "$daily"; then
    dedup_decision=skip
else
    dedup_decision=append
fi
assert "dedup-by-backreference detects existing backref → skip append" "skip" "$dedup_decision"

# Inverse: a different clip's backref → not in daily → should append.
backref_other="(from [[Clippings/Sample reddit with block tags]])"
if grep -qF "$backref_other" "$daily"; then
    dedup_decision_other=skip
else
    dedup_decision_other=append
fi
assert "dedup correctly distinguishes different-clip backrefs → append" "append" "$dedup_decision_other"

echo ""
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
