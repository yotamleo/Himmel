#!/usr/bin/env bash
# test-tokensave-mcp-install.sh — regression guard for HIMMEL-2547 (the
# `himmelctl deps` half): tokensave-mcp had a probe (HIMMEL-1093's
# initMarker deepening — a registered-but-uninitialized checkout already
# read 'degraded', never a silent 'present') but NO install descriptor, so
# `ensure` had nothing to run to actually converge it. Mirrors
# test-observability-stack-manifest.sh's structure: self-contained cases
# against the REAL manifest.json/manifest-lint.mjs/probes.js/
# install-engine.js, no fixture harness invented.
#
# Cases:
#   a. manifest.json still lints clean.
#   b. the tokensave-mcp item carries install.type:tokensave (the gap this
#      ticket exists to close) with no extraneous fields.
#   c. a malformed tokensave-mcp install descriptor (an unknown extra field)
#      is REJECTED by manifest-lint — the closed-shape check.
#   d. install-engine.js's planInstall() dispatches install.type:tokensave to
#      a `tokensave init <ctx.targetPath> --no-git-hook` bash invocation,
#      guarded by a `.tokensave` existence check — targeting the SAME path
#      probes.js's initMarker check resolves against (ctx.targetPath), never
#      a hardcoded path or the user's home; `--no-git-hook` is present
#      unconditionally.
#   e. running the returned plan entry against a scratch checkout (a stub
#      `tokensave` on PATH, never the real binary — hermetic) actually
#      creates `.tokensave/` and invokes the stub exactly once; running the
#      SAME entry a second time against the now-initialized checkout is a
#      clean no-op (rc=0, stub NOT invoked again) — idempotency, since the
#      real `tokensave init` errors on an already-initialized project rather
#      than no-op'ing.
#   f. probes.js's mcp-registered probe (HIMMEL-1093 initMarker deepening)
#      distinguishes all three states for tokensave-mcp: not registered ->
#      absent; registered + binary unresolvable -> degraded naming the
#      command; registered + binary present + no `.tokensave` -> degraded
#      naming "project not initialized" — proving the status half already
#      existed and still reads correctly now that ensure has a real
#      convergence step for the last case.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
manifest_path="$repo_root/scripts/install/manifest.json"
lint="$repo_root/scripts/install/manifest-lint.mjs"
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
install_engine_lib="$repo_root/scripts/himmelctl/lib/install-engine.js"
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tokensave-install-test.XXXXXX") || fail "mktemp -d failed"
[ -n "$work" ] || fail "mktemp -d produced an empty path"
trap 'rm -rf "$work"' EXIT

# winpath <path> — MSYS/Git Bash paths confuse node's own path resolution
# when handed straight through; convert to a Windows-form path there, pass
# through unchanged elsewhere. Mirrors test-observability-stack-manifest.sh's
# own helper.
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── case a: manifest.json still lints clean ─────────────────────────────
outA=$(MANIFEST_PATH="$(winpath "$manifest_path")" "$node_bin" "$(winpath "$lint")" 2>&1) \
  || fail "case a: manifest.json should lint clean (got): $outA"
echo "ok: case a — manifest.json lints clean"

# ── case b: tokensave-mcp carries install.type:tokensave, no extra fields ──
tsItem=$(jq -c '[.items[] | select(.id == "tokensave-mcp")] | .[0] // empty' "$manifest_path")
[ -n "$tsItem" ] || fail "case b: manifest.json has no 'tokensave-mcp' item"
[ "$(echo "$tsItem" | jq -r '.install.type // empty')" = "tokensave" ] \
  || fail "case b: tokensave-mcp item must carry install.type:tokensave (HIMMEL-2547 — ensure has nothing to run without it), got: $tsItem"
[ "$(echo "$tsItem" | jq -r '.install | keys | length')" = "1" ] \
  || fail "case b: tokensave-mcp install descriptor should carry no field besides 'type', got: $tsItem"
echo "ok: case b — manifest.json's tokensave-mcp item carries install.type:tokensave"

# ── case c: a malformed install descriptor (unknown extra field) is
# REJECTED — closed-shape check ──────────────────────────────────────────
badManifest="$work/manifest-bad-install.json"
jq '(.items[] | select(.id == "tokensave-mcp") | .install) |= (. + {"bogus": true})' \
  "$manifest_path" > "$badManifest"
outC=$(MANIFEST_PATH="$(winpath "$badManifest")" "$node_bin" "$(winpath "$lint")" 2>&1) && \
  fail "case c: manifest-lint should have REJECTED a tokensave-mcp install descriptor with an unknown 'bogus' field, but it exited 0: $outC"
outC_match=$(printf '%s' "$outC" | grep -E "unexpected field" || true)
[ -n "$outC_match" ] \
  || fail "case c: manifest-lint's rejection should name the unexpected field, got: $outC"
echo "ok: case c — a malformed tokensave-mcp install descriptor (extra field) is rejected"

# ── case d: install-engine.js's dispatch for install.type:tokensave ───────
outD=$("$node_bin" -e "
const ie = require(process.argv[1]);
const item = { id: 'tokensave-mcp', deps: [], install: { type: 'tokensave' } };
const ctx = { repoRoot: '/repo', scope: 'project', profile: 'all', targetPath: process.argv[2], platform: 'linux', env: process.env };
console.log(JSON.stringify(ie.planInstall([item], ctx)[0]));
" "$(winpath "$install_engine_lib")" "$work/some-checkout")

[ "$(echo "$outD" | jq -r '.cmd')" = "bash" ] \
  || fail "case d: tokensave install entry must dispatch via bash, got: $outD"
argsJoined=$(echo "$outD" | jq -r '.args | join(" ")')
echo "$argsJoined" | grep -qF "tokensave init" \
  || fail "case d: tokensave install entry must run 'tokensave init', got args: $argsJoined"
echo "$argsJoined" | grep -qF -- "--no-git-hook" \
  || fail "case d: tokensave install entry must ALWAYS pass --no-git-hook (HIMMEL-2281 hooksPath race), got args: $argsJoined"
echo "$argsJoined" | grep -qF "$work/some-checkout" \
  || fail "case d: tokensave install entry must target ctx.targetPath (the SAME checkout the initMarker probe resolves against), got args: $argsJoined"
echo "$outD" | jq -e '.args | index("/root") == null and index("/home") == null' >/dev/null \
  || fail "case d: tokensave install entry must never hardcode a home/root path, got: $outD"
echo "ok: case d — install-engine.js dispatches install.type:tokensave to 'tokensave init <ctx.targetPath> --no-git-hook' via bash"

# ── case e: the returned entry, actually spawned against a scratch
# checkout with a STUB tokensave (hermetic — never the real binary), creates
# .tokensave/ once and is a clean idempotent no-op on a second run ────────
checkoutA="$work/checkout-a"
mkdir -p "$checkoutA"
stubDir="$work/stub-bin"
mkdir -p "$stubDir"
callLog="$work/tokensave-calls.log"
: > "$callLog"
cat > "$stubDir/tokensave" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$callLog"
target="\$2"
mkdir -p "\$target/.tokensave"
exit 0
STUB
chmod +x "$stubDir/tokensave"

runEntry() {
  "$node_bin" -e "
const { spawnSync } = require('child_process');
const ie = require(process.argv[1]);
const item = { id: 'tokensave-mcp', deps: [], install: { type: 'tokensave' } };
const ctx = { repoRoot: '/repo', scope: 'project', profile: 'all', targetPath: process.argv[2], platform: 'linux', env: process.env };
const entry = ie.planInstall([item], ctx)[0];
const r = spawnSync(entry.cmd, entry.args, { env: process.env, encoding: 'utf8' });
process.stdout.write(String(r.status));
" "$(winpath "$install_engine_lib")" "$checkoutA"
}

rc1=$(PATH="$stubDir:$PATH" runEntry)
[ "$rc1" = "0" ] || fail "case e: first run against an uninitialized checkout must exit 0, got rc=$rc1"
[ -d "$checkoutA/.tokensave" ] || fail "case e: first run must create .tokensave/ under the target checkout"
calls1=$(wc -l < "$callLog" | tr -d ' ')
[ "$calls1" = "1" ] || fail "case e: first run must invoke tokensave exactly once, got $calls1 calls: $(cat "$callLog")"

rc2=$(PATH="$stubDir:$PATH" runEntry)
[ "$rc2" = "0" ] || fail "case e: second run against an ALREADY-initialized checkout must still exit 0 (idempotent no-op), got rc=$rc2"
calls2=$(wc -l < "$callLog" | tr -d ' ')
[ "$calls2" = "1" ] \
  || fail "case e: second run must NOT invoke tokensave again (the .tokensave guard should short-circuit) — real 'tokensave init' errors on an already-initialized checkout; calls=$calls2: $(cat "$callLog")"
echo "ok: case e — the tokensave install entry initializes a fresh checkout once, then no-ops cleanly (never re-invoking) on an already-indexed one"

# ── case f: probes.js's mcp-registered probe distinguishes all three states
# for tokensave-mcp (HIMMEL-1093 already built this; confirming it still
# holds now that ensure has a real convergence step for the degraded case) ─
checkoutF="$work/checkout-f"
mkdir -p "$checkoutF/.claude"
mcpConfig="$checkoutF/.mcp.json"

item_probe='{"probe":{"type":"mcp-registered","server":"tokensave","bin":"tokensave","initMarker":".tokensave"}}'

# f1: not registered at all -> absent
cat > "$mcpConfig" <<'JSON'
{"mcpServers":{}}
JSON
outF1=$("$node_bin" -e "
const { runProbe } = require(process.argv[1]);
const item = JSON.parse(process.argv[2]);
const ctx = { repoRoot: process.argv[3], targetPath: process.argv[3], scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
" "$(winpath "$probes_lib")" "$item_probe" "$(winpath "$checkoutF")")
[ "$(echo "$outF1" | jq -r '.actual')" = "absent" ] \
  || fail "case f1: an unregistered tokensave-mcp must probe 'absent', got: $outF1"
echo "ok: case f1 — not registered reads absent"

# f2: registered, but the command is unresolvable -> degraded, naming the command
cat > "$mcpConfig" <<'JSON'
{"mcpServers":{"tokensave":{"command":"tokensave-definitely-not-on-path-xyz","args":["serve"]}}}
JSON
outF2=$("$node_bin" -e "
const { runProbe } = require(process.argv[1]);
const item = JSON.parse(process.argv[2]);
const ctx = { repoRoot: process.argv[3], targetPath: process.argv[3], scope: 'project', env: { PATH: '' } };
console.log(JSON.stringify(runProbe(item, ctx)));
" "$(winpath "$probes_lib")" "$item_probe" "$(winpath "$checkoutF")")
[ "$(echo "$outF2" | jq -r '.actual')" = "degraded" ] \
  || fail "case f2: registered-but-unresolvable-binary must probe 'degraded', got: $outF2"
detailF2=$(echo "$outF2" | jq -r '.detail')
echo "$detailF2" | grep -qE "tokensave-definitely-not-on-path-xyz" \
  || fail "case f2: the degraded detail must name the unresolvable command, got: $detailF2"
echo "ok: case f2 — registered with an unresolvable binary reads degraded, naming the command (distinguishable from f1/f3)"

# f3: registered, command resolvable, but no .tokensave/ -> degraded, naming
# "project not initialized"
stubDir2="$work/stub-bin-2"
mkdir -p "$stubDir2"
cat > "$stubDir2/tokensave" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stubDir2/tokensave"
cat > "$mcpConfig" <<JSON
{"mcpServers":{"tokensave":{"command":"$stubDir2/tokensave","args":["serve"]}}}
JSON
outF3=$("$node_bin" -e "
const { runProbe } = require(process.argv[1]);
const item = JSON.parse(process.argv[2]);
const ctx = { repoRoot: process.argv[3], targetPath: process.argv[3], scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
" "$(winpath "$probes_lib")" "$item_probe" "$(winpath "$checkoutF")")
[ "$(echo "$outF3" | jq -r '.actual')" = "degraded" ] \
  || fail "case f3: registered + resolvable binary + no .tokensave/ must probe 'degraded' (HIMMEL-1093), got: $outF3"
detailF3=$(echo "$outF3" | jq -r '.detail')
echo "$detailF3" | grep -qE "not initialized" \
  || fail "case f3: the degraded detail must name the project as not initialized, got: $detailF3"
echo "$detailF3" | grep -qE '\.tokensave' \
  || fail "case f3: the degraded detail must name the .tokensave marker, got: $detailF3"
# Distinguishability: f2's and f3's details must differ (never the same
# generic 'degraded' text for two different root causes).
[ "$detailF2" != "$detailF3" ] \
  || fail "case f3: an unresolvable-binary degraded and an uninitialized-project degraded must read with DIFFERENT detail text, both were: $detailF2"
echo "ok: case f3 — registered + binary present + no .tokensave/ reads degraded naming 'project not initialized', distinguishable from f2's unresolvable-binary degraded and f1's absent"

echo "PASS"
