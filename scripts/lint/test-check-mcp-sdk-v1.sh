#!/usr/bin/env bash
# test-check-mcp-sdk-v1.sh — tests for scripts/lint/check-mcp-sdk-v1.sh (HIMMEL-4866).
#
# Cases (each fixture is a throwaway git repo; the gate reads `git ls-files`):
#   1. clean tree (v2 manifest + v2 import + v2 lock)            -> exit 0
#   2. direct v1 dependency in package.json                      -> exit 1
#   3. v1 import / require / dynamic import in source            -> exit 1
#   4. npm transitive v1 lock entry (package-lock.json)          -> exit 1
#   5. bun transitive v1 lock entry (bun.lock)                   -> exit 1
#   6. a mere mention (test assertion, prose, comment) is NOT a hit
#   7. vendored bundle with v2 modules: exit 0, NOTE says version unknown
#   8. vendored bundle embedding the v1 monolith                 -> exit 1
#   9. the real tree passes
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
LINT="$SELF_DIR/check-mcp-sdk-v1.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mcp-v1-gate.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# mkrepo <name>: an empty git repo at $T/<name>; echoes the path.
mkrepo() {
    mkdir -p "$T/$1" && git -C "$T/$1" init -q && printf '%s' "$T/$1"
}
# put <repo> <relpath> <content>: write and stage a file.
put() {
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add -- "$2"
}
# run <repo>: run the gate; sets OUT and RC.
run() { OUT="$(bash "$LINT" "$1" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

V2_PKG='{"name":"x","dependencies":{"@modelcontextprotocol/server":"2.3.1"}}'
V2_SRC="import { Server } from '@modelcontextprotocol/server'"

if [ ! -f "$LINT" ]; then
    echo "FAIL: $LINT does not exist yet (RED)"
    exit 1
fi

echo "== 1. clean v2 tree =="
r="$(mkrepo clean)"
put "$r" a/package.json "$V2_PKG"
put "$r" a/server.ts "$V2_SRC"
put "$r" a/package-lock.json '{"packages":{"node_modules/@modelcontextprotocol/server":{"version":"2.3.1"}}}'
put "$r" a/bun.lock '"@modelcontextprotocol/server": ["@modelcontextprotocol/server@2.3.1", "", {}, "sha512-x"],'
run "$r"
if [ "$RC" -eq 0 ]; then pass "clean v2 tree -> exit 0"; else fail "clean v2 tree -> rc=$RC: $OUT"; fi

echo "== 2. direct v1 dependency =="
r="$(mkrepo dep)"
put "$r" a/package.json '{"dependencies":{"@modelcontextprotocol/sdk":"^1.32.1"}}'
run "$r"
if [ "$RC" -eq 1 ] && has 'a/package.json:1'; then pass "v1 dependency refused"; else fail "v1 dependency -> rc=$RC: $OUT"; fi
r="$(mkrepo devdep)"
put "$r" package.json '{"devDependencies":{"@modelcontextprotocol/sdk":"1.0.0"}}'
run "$r"
if [ "$RC" -eq 1 ]; then pass "v1 devDependency refused"; else fail "v1 devDependency -> rc=$RC: $OUT"; fi

echo "== 3. v1 imports =="
r="$(mkrepo imp)"
put "$r" a.ts "import { Server } from '@modelcontextprotocol/sdk/server/index.js'"
run "$r"
if [ "$RC" -eq 1 ] && has 'a.ts:1'; then pass "ESM import refused"; else fail "ESM import -> rc=$RC: $OUT"; fi
r="$(mkrepo req)"
put "$r" a.cjs "const { Server } = require(\"@modelcontextprotocol/sdk/server\")"
run "$r"
if [ "$RC" -eq 1 ]; then pass "require refused"; else fail "require -> rc=$RC: $OUT"; fi
r="$(mkrepo dyn)"
put "$r" a.mjs "const m = await import('@modelcontextprotocol/sdk/client/index.js')"
run "$r"
if [ "$RC" -eq 1 ]; then pass "dynamic import refused"; else fail "dynamic import -> rc=$RC: $OUT"; fi

r="$(mkrepo multi)"
put "$r" a.mjs "const m = await import(
  '@modelcontextprotocol/sdk/client/index.js'
)"
run "$r"
if [ "$RC" -eq 1 ] && has 'a.mjs:2'; then pass "multiline specifier refused"; else fail "multiline import -> rc=$RC: $OUT"; fi

echo "== 4. npm transitive lock entry =="
r="$(mkrepo npmlock)"
put "$r" a/package-lock.json '{"packages":{"node_modules/foo":{"dependencies":{"@modelcontextprotocol/sdk":"^1.0.0"}},"node_modules/@modelcontextprotocol/sdk":{"version":"1.29.0"}}}'
run "$r"
if [ "$RC" -eq 1 ] && has 'a/package-lock.json'; then pass "npm lock entry refused"; else fail "npm lock -> rc=$RC: $OUT"; fi

echo "== 5. bun transitive lock entry =="
r="$(mkrepo bunlock)"
put "$r" a/bun.lock '"@modelcontextprotocol/sdk": ["@modelcontextprotocol/sdk@1.29.0", "", {}, "sha512-x"],'
run "$r"
if [ "$RC" -eq 1 ] && has 'a/bun.lock'; then pass "bun lock entry refused"; else fail "bun lock -> rc=$RC: $OUT"; fi

echo "== 6. mentions are not hits =="
r="$(mkrepo mention)"
put "$r" a.test.ts "expect(pkg.dependencies['@modelcontextprotocol/sdk']).toBeUndefined(); expect(src).not.toContain('@modelcontextprotocol/sdk')"
put "$r" notes.md "The v1 monolith @modelcontextprotocol/sdk was replaced."
put "$r" s.sh "# fails with Cannot find module '@modelcontextprotocol/sdk/...'"
run "$r"
if [ "$RC" -eq 0 ]; then pass "assertions, prose and comments pass"; else fail "mentions -> rc=$RC: $OUT"; fi

echo "== 7. vendored v2 bundle: passes, version stays UNKNOWN =="
r="$(mkrepo vend)"
put "$r" t/.obsidian/plugins/p/main.js '// node_modules/@modelcontextprotocol/server/dist/chunk-x.mjs'
run "$r"
if [ "$RC" -eq 0 ] && has 'NOTE' && has 'unknown' && has 't/.obsidian/plugins/p/main.js'; then pass "vendored bundle noted as unknown"; else fail "vendored v2 -> rc=$RC: $OUT"; fi

echo "== 8. vendored v1 bundle =="
r="$(mkrepo vendv1)"
put "$r" t/.obsidian/plugins/p/main.js '// node_modules/@modelcontextprotocol/sdk/dist/esm/server/index.js'
run "$r"
if [ "$RC" -eq 1 ] && has 't/.obsidian/plugins/p/main.js'; then pass "vendored v1 bundle refused"; else fail "vendored v1 -> rc=$RC: $OUT"; fi

echo "== 9. the real tree passes =="
run "$REPO_ROOT"
if [ "$RC" -eq 0 ]; then pass "real tree clean"; else fail "real tree -> rc=$RC: $OUT"; fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
