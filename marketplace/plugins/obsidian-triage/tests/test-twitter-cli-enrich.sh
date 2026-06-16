#!/usr/bin/env bash
#
# test-twitter-cli-enrich.sh — CLI-level behaviours for twitter-cli-enrich.mjs:
#   (a) --dry-run selects ONLY needs_thread + not-already-crawled X clips
#   (b) the burner-token guard refuses to run without TWITTER_AUTH_TOKEN/CT0
#
# Both paths short-circuit before any `twitter` call, so no fake binary / live X
# is needed. The full fetch→map→fold→G-3 path is covered by the JS-level
# dependency-injection test in test-twitter-cli-enrich.mjs (cross-platform).
#
# Run: bash tests/test-twitter-cli-enrich.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/../tools/twitter-cli-enrich.mjs"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
vault="$tmpdir/vault"
mkdir -p "$vault/Clippings"

cat > "$vault/Clippings/flagged.md" <<'EOF'
---
harvest_skill: clip-body
source: https://x.com/israfill/status/2065868713895829991
needs_thread: true
---
## The Idea
agents that browse for you down repo in comment

## Source
https://x.com/israfill/status/2065868713895829991
EOF

cat > "$vault/Clippings/plain.md" <<'EOF'
---
harvest_skill: clip-body
source: https://x.com/foo/status/123
---
## The Idea
just a tweet
EOF

cat > "$vault/Clippings/done.md" <<'EOF'
---
harvest_skill: clip-body
source: https://x.com/bar/status/456
needs_thread: true
crawled_at: 2026-06-01T00:00:00.000Z
---
## The Idea
already crawled
EOF

# (a) selection — dry-run returns before any fetch / token guard.
# A selected clip prints an "OK ... would enrich" line; skipped clips print a
# "SKIP ... skipped" line. Assert against the selection (would-enrich) lines.
out="$(node "$tool" --vault "$vault" --dry-run 2>&1 || true)"
selected="$(echo "$out" | grep "would enrich" || true)"
echo "$selected" | grep -q "flagged.md" || { echo "FAIL: flagged not selected"; echo "$out"; exit 1; }
echo "$selected" | grep -q "plain.md" && { echo "FAIL: plain (no needs_thread) selected"; exit 1; }
echo "$selected" | grep -q "done.md" && { echo "FAIL: already-crawled selected"; exit 1; }

# (b) token guard — no TWITTER_AUTH_TOKEN/CT0 → exit 2 + clear message, no mutation
before="$(cat "$vault/Clippings/flagged.md")"
guard="$(env -u TWITTER_AUTH_TOKEN -u TWITTER_CT0 node "$tool" --vault "$vault" 2>&1 || true)"
echo "$guard" | grep -qi "TWITTER_AUTH_TOKEN" || { echo "FAIL: no token-guard message"; echo "$guard"; exit 1; }
after="$(cat "$vault/Clippings/flagged.md")"
[ "$before" = "$after" ] || { echo "FAIL: token guard mutated a clip"; exit 1; }

echo "test-twitter-cli-enrich.sh: PASS"
