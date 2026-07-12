#!/usr/bin/env bash
# CLI mode tests for tools/lib/evidence-kind.mjs (D2, LUNA-84).
# TDD: written BEFORE the CLI mode is added — Tests 1-4 are RED until
# the `if (process.argv[1] ...)` block lands in evidence-kind.mjs.
# Test 5 (import guard) should also be RED until then.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/tools/lib/evidence-kind.mjs"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

echo "Test 1: CLI research+github+framework,rag → [\"concepts\",\"tools\"]"
out=$(node "$LIB" --type research --url "https://github.com/a/b" --tags "framework,rag" 2>/dev/null)
assert 'CLI: research+github+framework,rag → ["concepts","tools"]' '["concepts","tools"]' "$out"

echo "Test 2: CLI exits 0"
node "$LIB" --type article > /dev/null 2>&1
rc=$?
assert "CLI exit 0" "0" "$rc"

echo "Test 3: CLI tweet type → [\"authors\"]"
out=$(node "$LIB" --type tweet 2>/dev/null)
assert 'CLI: tweet → ["authors"]' '["authors"]' "$out"

echo "Test 4: CLI no args → [\"misc\"]"
out=$(node "$LIB" 2>/dev/null)
assert 'CLI: no args → ["misc"]' '["misc"]' "$out"

echo "Test 5: CLI tags-only (github url, tools tag) → [\"tools\"]"
out=$(node "$LIB" --url "https://github.com/owner/repo" 2>/dev/null)
assert 'CLI: github url → ["tools"]' '["tools"]' "$out"

echo "Test 6: import guard — importing module produces no stdout"
# When imported (not run as entry point), the CLI block must NOT execute.
# Use node --input-type=module reading from stdin (argv[1] = '-', not the lib path).
out=$(cd "$PLUGIN_DIR" && node --input-type=module - <<'EOJS' 2>/dev/null
import { inferEvidenceKind } from './tools/lib/evidence-kind.mjs';
// if CLI side-effected, output would appear above this point
EOJS
)
assert "import guard: no stdout when module is imported (not run directly)" "" "$out"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
