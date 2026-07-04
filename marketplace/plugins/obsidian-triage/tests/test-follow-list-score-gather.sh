#!/usr/bin/env bash
# Tests for HIMMEL-660 follow-list-score.mjs — CLI entry + gather subcommand.
# Wires Tasks 1-4 together end-to-end. Hermetic: no live network/gh/python —
# every real dependency (gh, fxtwitter fetch, HIMMEL-256 screener) is
# bypassed via the FOLLOW_GH_FIXTURE / FOLLOW_ACCOUNT_FIXTURE /
# FOLLOW_SCAN_FIXTURE env-fixture seams. Cross-platform: bash on
# Linux/macOS/Git-Bash. Uses node (not bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
CLI="$TOOLS_DIR/follow-list-score.mjs"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

node --check "$CLI" 2>/dev/null && s=ok || s=fail
assert "follow-list-score.mjs parses" ok "$s"

# -- Test 1: bad usage -> exit 1 ---------------------------------------------
echo "Test 1: bad usage"

node "$CLI" >/dev/null 2>&1
r=$?
assert "no args -> exit 1" 1 "$r"

node "$CLI" gather >/dev/null 2>&1
r=$?
assert "gather without --vault -> exit 1" 1 "$r"

node "$CLI" bogus-subcommand --vault "$tmpdir" >/dev/null 2>&1
r=$?
assert "unknown subcommand -> exit 1" 1 "$r"

# -- shared fixture vault: list file + one clip for handle x ----------------
vault="$tmpdir/vault"
mkdir -p "$vault/.obsidian"
mkdir -p "$vault/Clippings"
mkdir -p "$vault/30-Resources"

cat > "$vault/30-Resources/ai-x-follow-list.md" <<'EOF'
## Tier 1 — core

- **[@x](https://x.com/x)** (1) — builds agent tooling
EOF

cat > "$vault/Clippings/clip-x-1.md" <<'EOF'
---
title: "clip 1"
author:
  - "@x"
source: "https://x.com/x/status/1"
date_clipped: 2026-06-01
type: tweet
tags: []
---
## The Idea
built repo github.com/x/bar today, definitely not a placeholder.
EOF

# -- Test 2: assemble/judge-prep stubs (not yet implemented, exit 0) --------
echo "Test 2: assemble/judge-prep stubs"

node "$CLI" assemble --vault "$vault" >/dev/null 2>&1
r=$?
assert "assemble -> exit 0 (stub)" 0 "$r"

node "$CLI" judge-prep --vault "$vault" >/dev/null 2>&1
r=$?
assert "judge-prep -> exit 0 (stub)" 0 "$r"

# -- Test 3: dry-run prints the roster, writes NO dossier -------------------
echo "Test 3: gather --dry-run"

# Even though the dry-run code path doesn't reach the network, fixture the
# seams anyway so a wiring regression can never fall through to live
# network/gh/python instead of failing loudly.
echo '{}' > "$tmpdir/gh-empty.json"
echo '{}' > "$tmpdir/account-empty.json"
echo 'false' > "$tmpdir/scan-clean.json"

out3="$(FOLLOW_GH_FIXTURE="$tmpdir/gh-empty.json" \
        FOLLOW_ACCOUNT_FIXTURE="$tmpdir/account-empty.json" \
        FOLLOW_SCAN_FIXTURE="$tmpdir/scan-clean.json" \
        node "$CLI" gather --vault "$vault" --dry-run 2>&1)"
r3=$?
assert "gather --dry-run exits 0" 0 "$r3"
echo "$out3" | grep -qi ' x ' && rr=yes || rr=no
assert "dry-run prints roster handle 'x'" yes "$rr"
[ -d "$vault/30-Resources/.follow-scores" ] && dd=exists || dd=absent
assert "dry-run writes NO dossier dir" absent "$dd"

# -- Test 4: real gather (stubbed network) writes a dossier per handle,     --
# -- and end-to-end extraction+verification produces >=1 verified claim.    --
echo "Test 4: gather (real write, stubbed network)"

cat > "$tmpdir/gh-fixture.json" <<'EOF'
{
  "api users/x/repos?per_page=100": [],
  "api repos/x/bar": { "full_name": "x/bar", "owner": { "login": "x" } }
}
EOF

cat > "$tmpdir/account-fixture.json" <<'EOF'
{
  "https://api.fxtwitter.com/x": {
    "code": 200,
    "user": {
      "followers": 5000,
      "following": 10,
      "description": "building agent tools, github.com/x, 120k followers",
      "joined": "2020-01-01T00:00:00.000Z"
    }
  }
}
EOF

echo 'false' > "$tmpdir/scan-clean2.json"

FOLLOW_GH_FIXTURE="$tmpdir/gh-fixture.json" \
FOLLOW_ACCOUNT_FIXTURE="$tmpdir/account-fixture.json" \
FOLLOW_SCAN_FIXTURE="$tmpdir/scan-clean2.json" \
node "$CLI" gather --vault "$vault" >/dev/null 2>&1
r4=$?
assert "gather (real) exits 0" 0 "$r4"

dossier="$vault/30-Resources/.follow-scores/x.json"
[ -f "$dossier" ] && de=exists || de=absent
assert "gather writes a dossier for handle x" exists "$de"

lib_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$TOOLS_DIR/lib/follow-dossier.mjs")"
cat > "$tmpdir/check.mjs" <<EOF
import { readDossier } from "$lib_url";
const d = readDossier(process.env.FLS_VAULT, "x");
console.log("HAS_DOSSIER=" + (d !== null));
console.log("CLAIMS_NONEMPTY=" + (Array.isArray(d && d.claims) && d.claims.length > 0));
console.log("HAS_VERIFIED=" + (Array.isArray(d && d.claims) && d.claims.some(c => c.status === "verified")));
console.log("HAS_FOLLOWERS_CLAIM=" + (Array.isArray(d && d.claims) && d.claims.some(c => c.kind === "followers")));
console.log("FOLLOWERS=" + (d && d.account && d.account.followers));
console.log("SCREEN_STATUS=" + (d && d.screen_status));
EOF
out5="$(FLS_VAULT="$vault" node "$tmpdir/check.mjs" 2>&1)"
echo "$out5" | grep -q 'HAS_DOSSIER=true' && r=yes || r=no; assert "dossier round-trips via readDossier" yes "$r"
echo "$out5" | grep -q 'CLAIMS_NONEMPTY=true' && r=yes || r=no; assert "dossier.claims is non-empty" yes "$r"
echo "$out5" | grep -q 'HAS_VERIFIED=true' && r=yes || r=no; assert "dossier.claims has >=1 verified entry (extraction+gh-verify ran end-to-end)" yes "$r"
echo "$out5" | grep -q 'HAS_FOLLOWERS_CLAIM=true' && r=yes || r=no; assert "dossier.claims has a followers claim (bio-only; extractClaims ran AFTER fetchAccount populated bio)" yes "$r"
echo "$out5" | grep -q 'FOLLOWERS=5000' && r=yes || r=no; assert "dossier.account.followers populated from fetchAccount (fxtwitter fixture)" yes "$r"
echo "$out5" | grep -q 'SCREEN_STATUS=ok' && r=yes || r=no; assert "dossier.screen_status==ok (screenDossier ran via FOLLOW_SCAN_FIXTURE)" yes "$r"

# -- Test 5: re-run without --refetch skips the now-fresh dossier -----------
echo "Test 5: skip-if-fresh (no --refetch)"

out6="$(FOLLOW_GH_FIXTURE="$tmpdir/gh-fixture.json" \
        FOLLOW_ACCOUNT_FIXTURE="$tmpdir/account-fixture.json" \
        FOLLOW_SCAN_FIXTURE="$tmpdir/scan-clean2.json" \
        node "$CLI" gather --vault "$vault" 2>&1)"
echo "$out6" | grep -qi 'skip' && r=yes || r=no
assert "re-run without --refetch reports a skip for the fresh handle" yes "$r"

# -- Test 6: Gap B (HIMMEL-703) — an injection-suspect dossier SKIPS the     --
# -- LLM-backed web rung. A web fixture that WOULD verify a role claim is    --
# -- honored on a clean scan, but ignored once the injection screen fires.   --
echo "Test 6: injection-suspect skips the web rung (HIMMEL-703 Gap B)"

vault2="$tmpdir/vault2"
mkdir -p "$vault2/.obsidian" "$vault2/Clippings" "$vault2/30-Resources"
cat > "$vault2/30-Resources/ai-x-follow-list.md" <<'EOF'
## Tier 1 — core

- **[@y](https://x.com/y)** (0) — founder
EOF

cat > "$tmpdir/gh-empty2.json" <<'EOF'
{}
EOF

cat > "$tmpdir/account-y.json" <<'EOF'
{
  "https://api.fxtwitter.com/y": {
    "code": 200,
    "user": {
      "followers": 100,
      "following": 5,
      "description": "founder of AcmeCorp",
      "joined": "2021-01-01T00:00:00.000Z"
    }
  }
}
EOF

# Web backend that corroborates the "founder of AcmeCorp" role claim. The
# query is built as `X/Twitter account @<handle>: <claim text>` by follow-web.
cat > "$tmpdir/web-y.json" <<'EOF'
{
  "X/Twitter account @y: founder of AcmeCorp": {
    "found": true,
    "url": "https://example.com/acmecorp",
    "title": "AcmeCorp",
    "snippet": "AcmeCorp raised a seed round"
  }
}
EOF

lib_url2="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$TOOLS_DIR/lib/follow-dossier.mjs")"
cat > "$tmpdir/check-y.mjs" <<EOF
import { readDossier } from "$lib_url2";
const d = readDossier(process.env.FLS_VAULT, "y");
const role = (d && d.claims || []).find((c) => c.kind === "role");
console.log("INJECTION_SUSPECT=" + (d && d.injection_suspect));
console.log("SCREEN_STATUS=" + (d && d.screen_status));
console.log("ROLE_STATUS=" + (role && role.status));
EOF

# 6a: clean scan -> web rung runs -> role claim verified.
echo 'false' > "$tmpdir/scan-clean-y.json"
FOLLOW_GH_FIXTURE="$tmpdir/gh-empty2.json" \
FOLLOW_ACCOUNT_FIXTURE="$tmpdir/account-y.json" \
FOLLOW_WEB_FIXTURE="$tmpdir/web-y.json" \
FOLLOW_SCAN_FIXTURE="$tmpdir/scan-clean-y.json" \
node "$CLI" gather --vault "$vault2" --refetch >/dev/null 2>&1
r6a=$?
assert "6a clean: gather exits 0" 0 "$r6a"
out_clean="$(FLS_VAULT="$vault2" node "$tmpdir/check-y.mjs" 2>&1)"
echo "$out_clean" | grep -q 'INJECTION_SUSPECT=false' && r=yes || r=no; assert "6a clean: injection_suspect==false" yes "$r"
echo "$out_clean" | grep -q 'ROLE_STATUS=verified' && r=yes || r=no; assert "6a clean: web rung ran -> role claim verified" yes "$r"

# 6b: injection hit -> injection_suspect -> web rung SKIPPED -> role stays unverified.
echo 'true' > "$tmpdir/scan-hit-y.json"
FOLLOW_GH_FIXTURE="$tmpdir/gh-empty2.json" \
FOLLOW_ACCOUNT_FIXTURE="$tmpdir/account-y.json" \
FOLLOW_WEB_FIXTURE="$tmpdir/web-y.json" \
FOLLOW_SCAN_FIXTURE="$tmpdir/scan-hit-y.json" \
node "$CLI" gather --vault "$vault2" --refetch >/dev/null 2>&1
r6b=$?
assert "6b hit: gather exits 0" 0 "$r6b"
out_hit="$(FLS_VAULT="$vault2" node "$tmpdir/check-y.mjs" 2>&1)"
echo "$out_hit" | grep -q 'INJECTION_SUSPECT=true' && r=yes || r=no; assert "6b hit: injection_suspect==true" yes "$r"
echo "$out_hit" | grep -q 'ROLE_STATUS=unverified' && r=yes || r=no; assert "6b hit: web rung skipped -> role claim stays unverified (Gap B)" yes "$r"

# 6c: fail-closed -- scanner CANNOT run (screen_error) must ALSO skip the web
# rung, since the gate keys on injection_suspect (set true in both the hit and
# the error path). Proves the fail-closed property end-to-end, not just in the
# follow-screen unit test.
printf '%s' '"error"' > "$tmpdir/scan-error-y.json"
FOLLOW_GH_FIXTURE="$tmpdir/gh-empty2.json" \
FOLLOW_ACCOUNT_FIXTURE="$tmpdir/account-y.json" \
FOLLOW_WEB_FIXTURE="$tmpdir/web-y.json" \
FOLLOW_SCAN_FIXTURE="$tmpdir/scan-error-y.json" \
node "$CLI" gather --vault "$vault2" --refetch >/dev/null 2>&1
r6c=$?
assert "6c error: gather exits 0" 0 "$r6c"
out_err="$(FLS_VAULT="$vault2" node "$tmpdir/check-y.mjs" 2>&1)"
echo "$out_err" | grep -q 'INJECTION_SUSPECT=true' && r=yes || r=no; assert "6c error: injection_suspect==true (fail-closed)" yes "$r"
echo "$out_err" | grep -q 'SCREEN_STATUS=screen_error' && r=yes || r=no; assert "6c error: screen_status==screen_error" yes "$r"
echo "$out_err" | grep -q 'ROLE_STATUS=unverified' && r=yes || r=no; assert "6c error: web rung skipped on scanner failure (fail-closed Gap B)" yes "$r"

# -- Results summary -----------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
