#!/usr/bin/env bash
# Smoke test for scripts/check-plugin-drift.sh (HIMMEL-322).
# Structural checks (no network needed) + one end-to-end run (uses network iff
# gh is available; the script itself fail-opens when it isn't).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/check-plugin-drift.sh"
MJSON="$ROOT/marketplace/.claude-plugin/marketplace.json"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# 2. The marketplace.json parser yields the SHA-pinned remotes (>=1; expect
#    claude-obsidian + obsidian). Mirrors the script's own parser.
pins="$(python3 - "$MJSON" <<'PY' | tr -d '\r'
import json, sys
m = json.load(open(sys.argv[1]))
for p in m.get("plugins", []):
    s = p.get("source")
    if isinstance(s, dict) and s.get("source") == "github" and s.get("ref"):
        print(p["name"])
PY
)"
if echo "$pins" | grep -qx "claude-obsidian"; then ok "parser finds claude-obsidian pin"; else bad "parser missing claude-obsidian"; fi
if echo "$pins" | grep -qx "obsidian"; then ok "parser finds obsidian (kepano) pin"; else bad "parser missing obsidian"; fi

# 3. Every fork UPSTREAM_PIN carries the generic fields the checker reads.
for pin in "$ROOT"/marketplace/plugins/*/UPSTREAM_PIN; do
  [ -f "$pin" ] || continue
  plug="$(basename "$(dirname "$pin")")"
  for field in upstream_repo upstream_path upstream_sha256; do
    if grep -q "^${field}=" "$pin"; then ok "$plug UPSTREAM_PIN has $field"; else bad "$plug UPSTREAM_PIN missing $field"; fi
  done
done

# 4. End-to-end: the script runs to completion with a sane exit code —
#    0 (all current / fail-open), 2 (drift), or 3 (incomplete). Anything else
#    (1, 127, crash) fails.
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
case "$rc" in
  0|2|3) ok "end-to-end run exits $rc (expected 0, 2, or 3)" ;;
  *)     bad "end-to-end run exited $rc; output: $out" ;;
esac
# When gh ran (not the fail-open path), both section headers must appear.
if ! printf '%s' "$out" | grep -q "fail-open"; then
  if printf '%s' "$out" | grep -q "SHA-pinned remotes"; then ok "output has SHA-pinned section"; else bad "no SHA-pinned section"; fi
  if printf '%s' "$out" | grep -q "vendored forks"; then ok "output has vendored-forks section"; else bad "no vendored-forks section"; fi
else
  ok "gh unavailable — fail-open path taken (sections skipped, expected)"
fi

# 5. Fail-open path, deterministically (hide gh from PATH). The script's headline
#    safety property: gh absent -> exit 0 + skip, so CI / fresh clones never break.
fo_out="$(PATH=/usr/bin:/bin bash "$SCRIPT" 2>&1)"; fo_rc=$?
if [ "$fo_rc" -eq 0 ] && printf '%s' "$fo_out" | grep -q "fail-open"; then
  ok "fail-open: gh absent -> exit 0 + skip message"
else
  bad "fail-open broken: rc=$fo_rc out=$fo_out"
fi

# Note (deliberately NOT covered by this smoke layer): the exit-2 DRIFT verdict
# and the exit-3 INCOMPLETE path require an actually-drifted / unreachable
# upstream (non-deterministic) or an injectable-gh fixture harness — out of scope
# for a network-tool smoke test. The CRLF-strip is exercised implicitly on this
# Windows checkout (python3 emits CRLF; check #2 + the real run both depend on it).

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
