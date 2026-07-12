#!/usr/bin/env bash
# Tests for HIMMEL-660 Phase 2 follow-web.mjs — the WEB verification rung.
# Pure/stubbed (webFn injected); no live network. verifyWebClaims is async,
# so the heredoc test scripts use top-level await (node ESM). Cross-platform:
# bash on Linux/macOS/Git-Bash. Uses node (not bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
LIB="$TOOLS_DIR/lib/follow-web.mjs"

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

node --check "$LIB" 2>/dev/null && s=ok || s=fail
assert "follow-web.mjs parses" ok "$s"

# NB: fixture paths go through env vars (not embedded literally in the .mjs
# source) — MSYS/Git-Bash auto-converts POSIX paths in argv/env when invoking
# a native Windows node.exe, but NOT plain text written into a heredoc file.
lib_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"

# -- Test 1: verifyWebClaims marks course/product/role verified on a found+corroborating hit --
echo "Test 1: verifyWebClaims — web-verifiable kinds verified on corroborating hit"

cat > "$tmpdir/verify.mjs" <<EOF
import { verifyWebClaims } from "$lib_url";

// Stub webFn: returns a corroborating hit only for queries whose claim-
// specific token appears in the returned evidence (grounded, not blanket).
function webFn(query) {
  if (query.includes("maven.com")) {
    return { found: true, url: "https://maven.com/foo", title: "Foo course on Maven", snippet: "a course" };
  }
  if (query.includes("acme")) {
    return { found: true, url: "https://acme.dev", title: "Acme Labs", snippet: "founder of Acme" };
  }
  if (query.includes("smithery")) {
    return { found: true, url: "https://smithery.ai", title: "Smithery", snippet: "the MCP registry" };
  }
  return { found: false };
}

const dossier = {
  handle: "x",
  claims: [
    { text: "course at maven.com/foo", kind: "course", status: "unverified" },
    { text: "founder of acme", kind: "role", status: "unverified" },
    { text: "smithery.ai", kind: "product", status: "unverified" },
  ],
};

const out = await verifyWebClaims(dossier, { webFn });
const byKind = Object.fromEntries(out.map(c => [c.kind, c.status]));
console.log("COURSE=" + byKind.course);
console.log("ROLE=" + byKind.role);
console.log("PRODUCT=" + byKind.product);
console.log("RETURNS_NEW_ARRAY=" + (out !== dossier.claims));
EOF
out1="$(node "$tmpdir/verify.mjs" 2>&1)"
echo "$out1" | grep -q 'COURSE=verified' && r=yes || r=no; assert "verifyWebClaims: course verified on corroborating hit" yes "$r"
echo "$out1" | grep -q 'ROLE=verified' && r=yes || r=no; assert "verifyWebClaims: role ('founder of') verified on corroborating hit" yes "$r"
echo "$out1" | grep -q 'PRODUCT=verified' && r=yes || r=no; assert "verifyWebClaims: product verified on corroborating hit" yes "$r"
echo "$out1" | grep -q 'RETURNS_NEW_ARRAY=true' && r=yes || r=no; assert "verifyWebClaims: returns a new claims array" yes "$r"

# -- Test 2: stays unverified on a miss, a webFn error, and a non-corroborating hit --
echo "Test 2: verifyWebClaims — unverified on miss / error / non-corroboration"

cat > "$tmpdir/negatives.mjs" <<EOF
import { verifyWebClaims } from "$lib_url";

function missFn() { return { found: false }; }
function errorFn() { throw new Error("backend down"); }
// found:true but the evidence never echoes the claim's anchor token ("acme").
function nonCorroboratingFn() {
  return { found: true, url: "https://unrelated.example", title: "Something else", snippet: "no match" };
}

function claimSet() {
  return { claims: [{ text: "founder of acme", kind: "role", status: "unverified" }] };
}

const miss = await verifyWebClaims(claimSet(), { webFn: missFn });
console.log("MISS=" + miss[0].status);

const errored = await verifyWebClaims(claimSet(), { webFn: errorFn });
console.log("ERROR=" + errored[0].status);

const noncorr = await verifyWebClaims(claimSet(), { webFn: nonCorroboratingFn });
console.log("NONCORROBORATING=" + noncorr[0].status);
EOF
out2="$(node "$tmpdir/negatives.mjs" 2>&1)"
echo "$out2" | grep -q 'MISS=unverified' && r=yes || r=no; assert "verifyWebClaims: found:false -> unverified" yes "$r"
echo "$out2" | grep -q 'ERROR=unverified' && r=yes || r=no; assert "verifyWebClaims: webFn error -> unverified (never fabricates)" yes "$r"
echo "$out2" | grep -q 'NONCORROBORATING=unverified' && r=yes || r=no; assert "verifyWebClaims: found but non-corroborating -> unverified" yes "$r"

# -- Test 3: never verifies a claim with no web evidence; passes through other rungs' verdicts --
echo "Test 3: verifyWebClaims — no-op cases (no webFn, non-web kinds, already-verified)"

cat > "$tmpdir/passthrough.mjs" <<EOF
import { verifyWebClaims } from "$lib_url";

// A webFn that would "verify" anything with a url — proves the rung does NOT
// touch repo/followers kinds nor downgrade/upgrade already-decided claims.
function greedyFn() { return { found: true, url: "https://any.example", title: "any", snippet: "any" }; }

const dossier = {
  claims: [
    { text: "github.com/x/bar", kind: "repo", status: "verified" },       // owned by gh rung
    { text: "120k followers", kind: "followers", status: "unverified" },  // owned by account rung
    { text: "founder of acme", kind: "role", status: "contradicted" },    // already decided -> keep
  ],
};

// No webFn at all -> pure pass-through, no mutation.
const noWeb = await verifyWebClaims(dossier, {});
console.log("NOWEB_REPO=" + noWeb.find(c => c.kind === "repo").status);
console.log("NOWEB_ROLE=" + noWeb.find(c => c.kind === "role").status);

// With a greedy webFn: repo/followers untouched, contradicted role NOT flipped.
const withWeb = await verifyWebClaims(dossier, { webFn: greedyFn });
console.log("REPO=" + withWeb.find(c => c.kind === "repo").status);
console.log("FOLLOWERS=" + withWeb.find(c => c.kind === "followers").status);
console.log("ROLE=" + withWeb.find(c => c.kind === "role").status);
EOF
out3="$(node "$tmpdir/passthrough.mjs" 2>&1)"
echo "$out3" | grep -q 'NOWEB_REPO=verified' && r=yes || r=no; assert "verifyWebClaims: no webFn -> claims pass through unchanged" yes "$r"
echo "$out3" | grep -q 'REPO=verified' && r=yes || r=no; assert "verifyWebClaims: repo kind never web-checked" yes "$r"
echo "$out3" | grep -q 'FOLLOWERS=unverified' && r=yes || r=no; assert "verifyWebClaims: followers kind never web-checked (no evidence -> stays unverified)" yes "$r"
echo "$out3" | grep -q 'ROLE=contradicted' && r=yes || r=no; assert "verifyWebClaims: already-decided claim not overridden" yes "$r"

# -- Test 4: FOLLOW_WEB_FIXTURE seam (makeWebFn) resolves a hermetic webFn ------
echo "Test 4: makeWebFn — FOLLOW_WEB_FIXTURE hermetic seam"

cat > "$tmpdir/fixture.mjs" <<EOF
import { makeWebFn, makeFirecrawlWebFn } from "$lib_url";

const fixture = JSON.stringify({
  "course at maven.com/foo": { found: true, url: "https://maven.com/foo", title: "Maven course", snippet: "" },
});
const webFn = makeWebFn({ FOLLOW_WEB_FIXTURE: fixture });
const hit = await webFn("course at maven.com/foo");
const miss = await webFn("something not in the map");
console.log("FIXTURE_HIT=" + (hit.found === true && hit.url === "https://maven.com/foo"));
console.log("FIXTURE_MISS=" + (miss.found === false));

// No fixture + no FIRECRAWL_API_KEY -> web rung OFF (null).
console.log("OFF_WHEN_NO_KEY=" + (makeWebFn({}) === null));
// makeFirecrawlWebFn returns null without an apiKey (default-off posture).
console.log("FIRECRAWL_NULL_NO_KEY=" + (makeFirecrawlWebFn({}) === null));
EOF
out4="$(node "$tmpdir/fixture.mjs" 2>&1)"
echo "$out4" | grep -q 'FIXTURE_HIT=true' && r=yes || r=no; assert "makeWebFn: FOLLOW_WEB_FIXTURE returns the mapped result" yes "$r"
echo "$out4" | grep -q 'FIXTURE_MISS=true' && r=yes || r=no; assert "makeWebFn: fixture miss -> {found:false}" yes "$r"
echo "$out4" | grep -q 'OFF_WHEN_NO_KEY=true' && r=yes || r=no; assert "makeWebFn: no fixture + no key -> null (rung off)" yes "$r"
echo "$out4" | grep -q 'FIRECRAWL_NULL_NO_KEY=true' && r=yes || r=no; assert "makeFirecrawlWebFn: null without apiKey (default off)" yes "$r"

# -- Test 5: chainWebFns — order, short-circuit, fall-through, error-swallow --
echo "Test 5: chainWebFns — free-first fallback composition"

cat > "$tmpdir/chain.mjs" <<EOF
import { chainWebFns } from "$lib_url";

const calls = [];
const mk = (name, result) => (q) => { calls.push(name); return result; };
const thrower = (name) => (q) => { calls.push(name); throw new Error("boom"); };

// order + short-circuit: first found wins; later backends NOT called.
calls.length = 0;
let fn = chainWebFns([mk("a", { found: false }), mk("b", { found: true, url: "u" }), mk("c", { found: true, url: "z" })]);
let r = await fn("q");
console.log("SHORTCIRCUIT_URL=" + r.url);
console.log("ORDER=" + calls.join(","));

// all miss -> {found:false}, every backend tried in order.
calls.length = 0;
fn = chainWebFns([mk("a", { found: false }), mk("b", { found: false })]);
r = await fn("q");
console.log("ALLMISS=" + (r.found === false));
console.log("ALLMISS_ORDER=" + calls.join(","));

// a throwing backend is swallowed (treated as a miss); chain continues.
calls.length = 0;
fn = chainWebFns([thrower("a"), mk("b", { found: true, url: "ok" })]);
r = await fn("q");
console.log("SWALLOW_URL=" + r.url);
console.log("SWALLOW_ORDER=" + calls.join(","));

// nulls in the array are skipped (filter(Boolean) semantics).
fn = chainWebFns([null, mk("b", { found: true, url: "nn" }), null]);
r = await fn("q");
console.log("SKIPNULL_URL=" + r.url);

// async backends are awaited.
fn = chainWebFns([async () => ({ found: false }), async () => ({ found: true, url: "async" })]);
r = await fn("q");
console.log("ASYNC_URL=" + r.url);
EOF
out5="$(node "$tmpdir/chain.mjs" 2>&1)"
echo "$out5" | grep -q 'SHORTCIRCUIT_URL=u' && r=yes || r=no; assert "chainWebFns: returns first found result" yes "$r"
echo "$out5" | grep -q 'ORDER=a,b$' && r=yes || r=no; assert "chainWebFns: short-circuits — later backends not called" yes "$r"
echo "$out5" | grep -q 'ALLMISS=true' && r=yes || r=no; assert "chainWebFns: all-miss -> {found:false}" yes "$r"
echo "$out5" | grep -q 'ALLMISS_ORDER=a,b$' && r=yes || r=no; assert "chainWebFns: tries every backend in order on a miss" yes "$r"
echo "$out5" | grep -q 'SWALLOW_URL=ok' && r=yes || r=no; assert "chainWebFns: swallows a throwing backend, continues to next" yes "$r"
echo "$out5" | grep -q 'SWALLOW_ORDER=a,b$' && r=yes || r=no; assert "chainWebFns: thrower counted then next backend tried" yes "$r"
echo "$out5" | grep -q 'SKIPNULL_URL=nn' && r=yes || r=no; assert "chainWebFns: skips null backends" yes "$r"
echo "$out5" | grep -q 'ASYNC_URL=async' && r=yes || r=no; assert "chainWebFns: awaits async backends" yes "$r"

# -- Test 6: makeWebFn — free-first chain assembly + gating -----------------
echo "Test 6: makeWebFn — chain assembly, gating, fixture precedence"

cat > "$tmpdir/chainfn.mjs" <<EOF
import { makeWebFn } from "$lib_url";

// nothing enabled -> null (rung dark, verifyWebClaims no-ops).
console.log("NULL_EMPTY=" + (makeWebFn({}) === null));

// fixture precedence beats every backend flag (hermetic seam wins).
const fx = JSON.stringify({ "q": { found: true, url: "fixture" } });
const w = makeWebFn({ FOLLOW_WEB_FIXTURE: fx, FOLLOW_WEB_QMD: "1", FOLLOW_WEB_CLI: "agy", FOLLOW_WEB_HERMES: "1", FIRECRAWL_API_KEY: "x" });
const hit = await w("q");
console.log("FIXTURE_WINS=" + (hit.url === "fixture"));

// each backend flag independently activates the rung (returns a composed webFn).
console.log("QMD_ENABLES=" + (typeof makeWebFn({ FOLLOW_WEB_QMD: "1" }) === "function"));
console.log("CLI_ENABLES=" + (typeof makeWebFn({ FOLLOW_WEB_CLI: "agy" }) === "function"));
console.log("HERMES_ENABLES=" + (typeof makeWebFn({ FOLLOW_WEB_HERMES: "1" }) === "function"));
console.log("FIRECRAWL_ENABLES=" + (typeof makeWebFn({ FIRECRAWL_API_KEY: "key" }) === "function"));
EOF
out6="$(node "$tmpdir/chainfn.mjs" 2>&1)"
echo "$out6" | grep -q 'NULL_EMPTY=true' && r=yes || r=no; assert "makeWebFn: no backend enabled -> null" yes "$r"
echo "$out6" | grep -q 'FIXTURE_WINS=true' && r=yes || r=no; assert "makeWebFn: FOLLOW_WEB_FIXTURE precedence beats backend flags" yes "$r"
echo "$out6" | grep -q 'QMD_ENABLES=true' && r=yes || r=no; assert "makeWebFn: FOLLOW_WEB_QMD activates the rung" yes "$r"
echo "$out6" | grep -q 'CLI_ENABLES=true' && r=yes || r=no; assert "makeWebFn: FOLLOW_WEB_CLI activates the rung" yes "$r"
echo "$out6" | grep -q 'HERMES_ENABLES=true' && r=yes || r=no; assert "makeWebFn: FOLLOW_WEB_HERMES activates the rung" yes "$r"
echo "$out6" | grep -q 'FIRECRAWL_ENABLES=true' && r=yes || r=no; assert "makeWebFn: FIRECRAWL_API_KEY activates the rung" yes "$r"

# -- Test 7: makeCliWebFn — null-gate, JSON parse, garbage, budget cap ------
echo "Test 7: makeCliWebFn — external prompt-in/JSON-out adapter"

# A stub CLI that echoes a strict JSON object (the shape the adapter expects).
# The adapter passes the prompt as the LAST arg; the stub ignores args & prints.
cat > "$tmpdir/good-cli.sh" <<'STUB'
#!/usr/bin/env bash
echo '{"found":true,"url":"https://acme.dev","title":"Acme","snippet":"founder of acme"}'
STUB
chmod +x "$tmpdir/good-cli.sh"

# A stub CLI that echoes garbage (no JSON object) -> {found:false}.
cat > "$tmpdir/garbage-cli.sh" <<'STUB'
#!/usr/bin/env bash
echo 'not json at all'
STUB
chmod +x "$tmpdir/garbage-cli.sh"

cat > "$tmpdir/cli.mjs" <<EOF
import { makeCliWebFn } from "$lib_url";

// null when FOLLOW_WEB_CLI unset (default OFF).
console.log("NULL_UNSET=" + (makeCliWebFn({}) === null));

// set + good stub -> {found:true,...}. Run the stub via bash (portable on
// Git-Bash where the shebang path isn't directly exec'able).
const good = makeCliWebFn({ FOLLOW_WEB_CLI: "bash", FOLLOW_WEB_CLI_ARGS: "$tmpdir/good-cli.sh" });
const g = good("founder of acme");
console.log("GOOD_FOUND=" + (g.found === true && g.url === "https://acme.dev"));

// garbage stub -> {found:false}.
const bad = makeCliWebFn({ FOLLOW_WEB_CLI: "bash", FOLLOW_WEB_CLI_ARGS: "$tmpdir/garbage-cli.sh" });
console.log("GARBAGE=" + (bad("x").found === false));

// budget cap: after FOLLOW_WEB_CLI_BUDGET calls, returns {found:false} w/o spawning.
const capped = makeCliWebFn({ FOLLOW_WEB_CLI: "bash", FOLLOW_WEB_CLI_ARGS: "$tmpdir/good-cli.sh", FOLLOW_WEB_CLI_BUDGET: "1" });
console.log("CAP_FIRST=" + (capped("a").found === true));
console.log("CAP_SECOND=" + (capped("b").found === false));
EOF
out7="$(node "$tmpdir/cli.mjs" 2>&1)"
echo "$out7" | grep -q 'NULL_UNSET=true' && r=yes || r=no; assert "makeCliWebFn: null when FOLLOW_WEB_CLI unset" yes "$r"
echo "$out7" | grep -q 'GOOD_FOUND=true' && r=yes || r=no; assert "makeCliWebFn: JSON-echoing stub -> {found:true,...}" yes "$r"
echo "$out7" | grep -q 'GARBAGE=true' && r=yes || r=no; assert "makeCliWebFn: garbage stub -> {found:false}" yes "$r"
echo "$out7" | grep -q 'CAP_FIRST=true' && r=yes || r=no; assert "makeCliWebFn: budget allows the first call" yes "$r"
echo "$out7" | grep -q 'CAP_SECOND=true' && r=yes || r=no; assert "makeCliWebFn: budget cap -> {found:false} past the limit" yes "$r"

# -- Test 8: makeHermesWebFn — null-gate + enabled returns a function --------
echo "Test 8: makeHermesWebFn — null-gate (no real hermes invoked)"

cat > "$tmpdir/hermes.mjs" <<EOF
import { makeHermesWebFn } from "$lib_url";

// null when FOLLOW_WEB_HERMES unset (default OFF — never fans hermes calls).
console.log("NULL_UNSET=" + (makeHermesWebFn({}) === null));
// enabled -> a function (we do NOT invoke it — no real hermes in tests).
console.log("ENABLED_FN=" + (typeof makeHermesWebFn({ FOLLOW_WEB_HERMES: "1" }) === "function"));
EOF
out8="$(node "$tmpdir/hermes.mjs" 2>&1)"
echo "$out8" | grep -q 'NULL_UNSET=true' && r=yes || r=no; assert "makeHermesWebFn: null when FOLLOW_WEB_HERMES unset" yes "$r"
echo "$out8" | grep -q 'ENABLED_FN=true' && r=yes || r=no; assert "makeHermesWebFn: enabled -> returns a webFn function" yes "$r"

# -- Test 9: corroboration grounding (claim-token anchor, handle in query) ----
echo "Test 9: corroboration grounding"

cat > "$tmpdir/corrob.mjs" <<EOF
import { verifyWebClaims } from "$lib_url";

// The query must carry the handle so the backend verifies THIS account.
let seenQuery = "";
function captureFn(q) { seenQuery = q; return { found: true, url: "https://x.io", title: "", snippet: "google chrome eng lead" }; }
const camel = { handle: "addyosmani", claims: [{ text: "@GoogleChrome", kind: "role", status: "unverified" }] };
const c1 = await verifyWebClaims(camel, { webFn: captureFn });
console.log("QUERY_HAS_HANDLE=" + seenQuery.includes("addyosmani"));
// camelCase claim "@GoogleChrome" tokenises to google/chrome, matched by the
// space-separated "google chrome" in the result -> verified.
console.log("CAMEL_VERIFIED=" + c1.find(c => c.kind === "role").status);

// Handle appears in the result but the CLAIM substance does not -> NOT verified
// (no circular self-page corroboration).
function handleOnlyFn() { return { found: true, url: "https://x.com/addyosmani", title: "addyosmani", snippet: "profile" }; }
const c2 = await verifyWebClaims(camel, { webFn: handleOnlyFn });
console.log("HANDLE_ONLY=" + c2.find(c => c.kind === "role").status);

// found:true but empty URL -> unverified (no page).
function noUrlFn() { return { found: true, url: "", title: "google chrome", snippet: "" }; }
const c3 = await verifyWebClaims(camel, { webFn: noUrlFn });
console.log("NO_URL=" + c3.find(c => c.kind === "role").status);

// Claim with no salient token to anchor on -> unverified (fail-safe), even on found:true+url.
const noTok = { handle: "acct", claims: [{ text: "at IBM", kind: "role", status: "unverified" }] };
const c4 = await verifyWebClaims(noTok, { webFn: () => ({ found: true, url: "https://ibm.com", title: "", snippet: "" }) });
console.log("NO_ANCHOR=" + c4.find(c => c.kind === "role").status);
EOF
out9="$(node "$tmpdir/corrob.mjs" 2>&1)"
echo "$out9" | grep -q 'QUERY_HAS_HANDLE=true' && r=yes || r=no; assert "verifyWebClaims: query carries the handle for account-scoped search" yes "$r"
echo "$out9" | grep -q 'CAMEL_VERIFIED=verified' && r=yes || r=no; assert "corroborates: camelCase claim token matches space-separated result -> verified" yes "$r"
echo "$out9" | grep -q 'HANDLE_ONLY=unverified' && r=yes || r=no; assert "corroborates: handle in result but not the claim substance -> unverified (no circular)" yes "$r"
echo "$out9" | grep -q 'NO_URL=unverified' && r=yes || r=no; assert "corroborates: found:true with empty url -> unverified" yes "$r"
echo "$out9" | grep -q 'NO_ANCHOR=unverified' && r=yes || r=no; assert "corroborates: no salient claim token -> unverified (fail-safe)" yes "$r"

# -- Results summary -----------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
