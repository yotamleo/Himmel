#!/usr/bin/env bash
# test-adopter-profile-lane-allowlist-cache-fallback.sh — HIMMEL-3059 S3:
# when the install prefix's scripts/lanes/ is NOT writable (a packaged,
# root-owned tree), persistProfileLaneAllowlist must not throw — it falls
# back to $HIMMELCTL_CACHE_DIR/lanes.local.json instead of the in-tree file.
# A WRITABLE repoRoot keeps today's behaviour byte-for-byte (in-tree, scope
# 'clone'). readLaneRegistries() must find the cache-dir overlay too.
# Hermetic: throwaway fixture trees only, no real HOME or repo touched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/adopter-profile.js"
fails=0
check() {
    if [ "$2" = "$3" ]; then echo "ok - $1"; else
        echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails + 1)); fi
}

tmp="$(mktemp -d -t adopter-lane-cache-fallback.XXXXXX)" || exit 1
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

# ── Case 1: read-only scripts/lanes/ → falls back to the cache dir ──────────
RO_ROOT="$tmp/ro-repo"
mkdir -p "$RO_ROOT/scripts/lanes"
CACHE1="$tmp/cache1"
echo '{"lanes":[]}' > "$RO_ROOT/scripts/lanes/lanes.json"
chmod 555 "$RO_ROOT/scripts/lanes"

out=$(HIMMELCTL_CACHE_DIR="$CACHE1" node -e '
  const lib = require(process.argv[1]);
  (async () => {
    try {
      const r = await lib.persistProfileLaneAllowlist(["codex"], process.argv[2]);
      console.log(JSON.stringify(r));
    } catch (e) {
      console.log("THREW:" + (e && e.message ? e.message : e));
    }
  })();
' "$LIB" "$RO_ROOT" 2>&1)
chmod 755 "$RO_ROOT/scripts/lanes"

case "$out" in
    THREW:*) check "Case1: does not throw on a read-only install tree" "$out" "<no throw>" ;;
    *) echo "ok - Case1: does not throw on a read-only install tree" ;;
esac
case "$out" in *'"scope":"user"'*) echo "ok - Case1: scope is 'user'" ;; *) echo "FAIL - Case1: scope is 'user' — got: $out"; fails=$((fails + 1));; esac
if [ -f "$CACHE1/lanes.local.json" ]; then echo "ok - Case1: wrote to the cache dir"; else echo "FAIL - Case1: cache-dir file missing"; fails=$((fails + 1)); fi
[ -f "$RO_ROOT/scripts/lanes/lanes.local.json" ] && { echo "FAIL - Case1: must NOT write into the read-only tree"; fails=$((fails + 1)); } || echo "ok - Case1: in-tree file was not created"
case "$(cat "$CACHE1/lanes.local.json" 2>/dev/null)" in *codex-exec*) echo "ok - Case1: cache overlay carries the allowlisted id" ;; *) echo "FAIL - Case1: cache overlay missing the allowlisted id"; fails=$((fails + 1));; esac

# readLaneRegistries() must find the same overlay at the cache location.
read_out=$(HIMMELCTL_CACHE_DIR="$CACHE1" node -e '
  const lib = require(process.argv[1]);
  const regs = lib.readLaneRegistries(process.argv[2]);
  console.log(JSON.stringify(regs && regs.local));
' "$LIB" "$RO_ROOT" 2>&1)
case "$read_out" in *'codex-exec'*) echo "ok - Case1: readLaneRegistries finds the cache-dir overlay" ;; *) echo "FAIL - Case1: readLaneRegistries missed the cache-dir overlay — got: $read_out"; fails=$((fails + 1));; esac

# ── Case 2: a WRITABLE repoRoot keeps today's behaviour, byte-for-byte ──────
RW_ROOT="$tmp/rw-repo"
mkdir -p "$RW_ROOT/scripts/lanes"
CACHE2="$tmp/cache2"

out2=$(HIMMELCTL_CACHE_DIR="$CACHE2" node -e '
  const lib = require(process.argv[1]);
  (async () => {
    const r = await lib.persistProfileLaneAllowlist(["codex"], process.argv[2]);
    console.log(JSON.stringify(r));
  })();
' "$LIB" "$RW_ROOT" 2>&1)

case "$out2" in *'"scope":"clone"'*) echo "ok - Case2: scope is 'clone' on a writable clone" ;; *) echo "FAIL - Case2: scope is 'clone' — got: $out2"; fails=$((fails + 1));; esac
if [ -f "$RW_ROOT/scripts/lanes/lanes.local.json" ]; then echo "ok - Case2: writable clone still writes in-tree"; else echo "FAIL - Case2: in-tree file missing on a writable clone"; fails=$((fails + 1)); fi
[ -f "$CACHE2/lanes.local.json" ] && { echo "FAIL - Case2: must NOT write to the cache dir when in-tree is writable"; fails=$((fails + 1)); } || echo "ok - Case2: cache dir untouched on a writable clone"

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
