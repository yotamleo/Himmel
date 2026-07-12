#!/usr/bin/env bash
# Tests for HIMMEL-660 follow-verify.mjs — claim extraction + gh-api
# resource evidence + claim verification. Pure/stubbed (ghFn/headFn
# injected); no live network. Cross-platform: bash on Linux/macOS/Git-Bash.
# Uses node (not bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
LIB="$TOOLS_DIR/lib/follow-verify.mjs"

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
assert "follow-verify.mjs parses" ok "$s"

# NB: fixture paths go through env vars (not embedded literally in the
# .mjs source) — MSYS/Git-Bash auto-converts POSIX paths in argv/env when
# invoking a native Windows node.exe, but NOT plain text written into a
# heredoc-generated file.
lib_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"

# -- Test 1: extractClaims ----------------------------------------------------
echo "Test 1: extractClaims"

cat > "$tmpdir/extract.mjs" <<EOF
import { extractClaims } from "$lib_url";
const bio = "building agent tools, github.com/x, 120k followers, course at maven.com/foo";
const sampleTweets = ["shipped repo bar today"];
const claims = extractClaims(bio, sampleTweets);
const kinds = new Set(claims.map(c => c.kind));
console.log("HAS_REPO=" + kinds.has("repo"));
console.log("HAS_FOLLOWERS=" + kinds.has("followers"));
console.log("HAS_COURSE=" + kinds.has("course"));
console.log("ALL_HAVE_TEXT=" + claims.every(c => typeof c.text === "string" && c.text.length > 0));
const followersClaim = claims.find(c => c.kind === "followers");
console.log("FOLLOWERS_TEXT=" + (followersClaim ? followersClaim.text : "MISSING"));
EOF
out1="$(node "$tmpdir/extract.mjs" 2>&1)"
echo "$out1" | grep -q 'HAS_REPO=true' && r=yes || r=no; assert "extractClaims: repo kind present" yes "$r"
echo "$out1" | grep -q 'HAS_FOLLOWERS=true' && r=yes || r=no; assert "extractClaims: followers kind present" yes "$r"
echo "$out1" | grep -q 'HAS_COURSE=true' && r=yes || r=no; assert "extractClaims: course kind present" yes "$r"
echo "$out1" | grep -q 'ALL_HAVE_TEXT=true' && r=yes || r=no; assert "extractClaims: every claim carries raw text" yes "$r"
echo "$out1" | grep -qi 'FOLLOWERS_TEXT=120k followers' && r=yes || r=no; assert "extractClaims: followers claim text captures '120k followers'" yes "$r"

# -- Test 2: resolveGithub + fetchRepos (stubbed ghFn) -----------------------
echo "Test 2: resolveGithub + fetchRepos"

cat > "$tmpdir/repos.mjs" <<EOF
import { resolveGithub, fetchRepos } from "$lib_url";
const bio = "building agent tools, github.com/x, active";

const fixtureRepos = [
  { name: "foo", stargazers_count: 5, pushed_at: "2026-01-01T00:00:00Z", description: "a foo tool", topics: [] },
  { name: "bar", stargazers_count: 0, pushed_at: "2026-02-01T00:00:00Z", description: null, topics: [] },
  { name: "baz-agent", stargazers_count: 20, pushed_at: "2026-03-01T00:00:00Z", description: "an ai agent harness", topics: ["ai-agents"] },
];

function ghFn(args) {
  if (args[0] === "api" && args[1] === "users/x/repos?per_page=100") return fixtureRepos;
  throw new Error("unexpected ghFn call: " + JSON.stringify(args));
}

const resolved = resolveGithub(bio, { ghFn });
console.log("LOGIN=" + resolved.login);

const repos = fetchRepos(resolved.login, { ghFn });
console.log("REPO_COUNT=" + repos.repo_count);
console.log("TOTAL_STARS=" + repos.total_stars);
console.log("TOPICAL_HITS_GE1=" + (repos.topical_hits >= 1));
console.log("SAMPLE_DESC_LEN_GE1=" + (repos.sample_descriptions.length >= 1));
console.log("STATUS=" + repos.status);

const nullLogin = resolveGithub("no github mention here", { ghFn });
console.log("NULL_LOGIN=" + nullLogin.login);
EOF
out2="$(node "$tmpdir/repos.mjs" 2>&1)"
echo "$out2" | grep -q 'LOGIN=x' && r=yes || r=no; assert "resolveGithub: login extracted from bio" yes "$r"
echo "$out2" | grep -q 'REPO_COUNT=3' && r=yes || r=no; assert "fetchRepos: repo_count==3" yes "$r"
echo "$out2" | grep -q 'TOTAL_STARS=25' && r=yes || r=no; assert "fetchRepos: total_stars==25" yes "$r"
echo "$out2" | grep -q 'TOPICAL_HITS_GE1=true' && r=yes || r=no; assert "fetchRepos: topical_hits>=1" yes "$r"
echo "$out2" | grep -q 'SAMPLE_DESC_LEN_GE1=true' && r=yes || r=no; assert "fetchRepos: sample_descriptions.length>=1" yes "$r"
echo "$out2" | grep -q 'STATUS=ok' && r=yes || r=no; assert "fetchRepos: status==ok" yes "$r"
echo "$out2" | grep -q 'NULL_LOGIN=null' && r=yes || r=no; assert "resolveGithub: login null when no github.com mention" yes "$r"

# -- Test 3: verifyClaims ------------------------------------------------------
echo "Test 3: verifyClaims"

cat > "$tmpdir/verify.mjs" <<EOF
import { verifyClaims } from "$lib_url";

function makeDossier(followersText, actualFollowers) {
  return {
    handle: "x",
    repos: { login: "x" },
    account: { followers: actualFollowers },
    claims: [
      { text: "github.com/x/bar", kind: "repo" },
      { text: followersText, kind: "followers" },
    ],
  };
}

function ghFn(args) {
  if (args[0] === "api" && args[1] === "repos/x/bar") {
    return { full_name: "x/bar", owner: { login: "x" } };
  }
  throw new Error("unexpected ghFn call: " + JSON.stringify(args));
}
function headFn() { return 200; }

// Branch: spike_result "A" + mismatch -> followers claim contradicted.
// Fetched count lives on dossier.account.followers (Task 5's fetchAccount);
// accountSource never carries a follower count (Task 0 interface contract).
const dossierMismatch = makeDossier("120k followers", 5000);
const resultMismatch = verifyClaims(dossierMismatch, {
  ghFn, headFn,
  accountSource: { spike_result: "A" },
});
const repoClaimA = resultMismatch.find(c => c.kind === "repo");
const followersClaimA = resultMismatch.find(c => c.kind === "followers");
console.log("A_REPO_STATUS=" + repoClaimA.status);
console.log("A_MISMATCH_FOLLOWERS_STATUS=" + followersClaimA.status);

// Branch: spike_result "A" + close match -> verified (never contradicted on a match).
const dossierMatch = makeDossier("5000 followers", 5000);
const resultMatch = verifyClaims(dossierMatch, {
  ghFn, headFn,
  accountSource: { spike_result: "A" },
});
console.log("A_MATCH_FOLLOWERS_STATUS=" + resultMatch.find(c => c.kind === "followers").status);

// Branch: spike_result "B" -> followers claim stays unverified, never contradicted.
const dossierB = makeDossier("120k followers", 5000);
const resultB = verifyClaims(dossierB, {
  ghFn, headFn,
  accountSource: { spike_result: "B" },
});
console.log("B_FOLLOWERS_STATUS=" + resultB.find(c => c.kind === "followers").status);
EOF
out3="$(node "$tmpdir/verify.mjs" 2>&1)"
echo "$out3" | grep -q 'A_REPO_STATUS=verified' && r=yes || r=no; assert "verifyClaims: repo claim verified via ghFn owner match" yes "$r"
echo "$out3" | grep -q 'A_MISMATCH_FOLLOWERS_STATUS=contradicted' && r=yes || r=no; assert "verifyClaims: spike_result A + mismatch -> contradicted" yes "$r"
echo "$out3" | grep -q 'A_MATCH_FOLLOWERS_STATUS=verified' && r=yes || r=no; assert "verifyClaims: spike_result A + close match -> verified" yes "$r"
echo "$out3" | grep -q 'B_FOLLOWERS_STATUS=unverified' && r=yes || r=no; assert "verifyClaims: spike_result B -> unverified (never contradicted)" yes "$r"

# -- Test 4: extractClaims role/mention discipline + byline + stars ----------
echo "Test 4: extractClaims role-mention discipline"

cat > "$tmpdir/roles.mjs" <<EOF
import { extractClaims } from "$lib_url";
const bio = "founder of Foo, @alice building agent tooling";
const tweets = [
  "# Tweet by @bob",
  "shipped with @carol today, founder of Bar",
  "Foo now has 96k stars",
];
const claims = extractClaims(bio, tweets);
const roleTexts = claims.filter(c => c.kind === "role").map(c => c.text);
console.log("BIO_MENTION_ROLE=" + roleTexts.includes("@alice"));
console.log("TWEET_MENTION_BOB_ROLE=" + roleTexts.some(t => /@bob/i.test(t)));
console.log("TWEET_MENTION_CAROL_ROLE=" + roleTexts.some(t => /@carol/i.test(t)));
console.log("FOUNDER_BIO_ROLE=" + roleTexts.some(t => /founder of Foo/i.test(t)));
console.log("FOUNDER_TWEET_ROLE=" + roleTexts.some(t => /founder of Bar/i.test(t)));
console.log("NO_BYLINE_CLAIM=" + !claims.some(c => /@bob/i.test(c.text)));
const starClaim = claims.find(c => c.kind === "stars");
console.log("STARS_TEXT=" + (starClaim ? starClaim.text : "MISSING"));
EOF
out4="$(node "$tmpdir/roles.mjs" 2>&1)"
echo "$out4" | grep -q 'BIO_MENTION_ROLE=true' && r=yes || r=no; assert "extractClaims: @mention in bio yields a role claim" yes "$r"
echo "$out4" | grep -q 'TWEET_MENTION_BOB_ROLE=false' && r=yes || r=no; assert "extractClaims: @mention in tweet byline yields NO role claim" yes "$r"
echo "$out4" | grep -q 'TWEET_MENTION_CAROL_ROLE=false' && r=yes || r=no; assert "extractClaims: @mention in tweet body yields NO role claim" yes "$r"
echo "$out4" | grep -q 'FOUNDER_BIO_ROLE=true' && r=yes || r=no; assert "extractClaims: 'founder of' role kept from bio" yes "$r"
echo "$out4" | grep -q 'FOUNDER_TWEET_ROLE=true' && r=yes || r=no; assert "extractClaims: 'founder of' role kept from tweet" yes "$r"
echo "$out4" | grep -q 'NO_BYLINE_CLAIM=true' && r=yes || r=no; assert "extractClaims: '# Tweet by @handle' byline never produces a claim" yes "$r"
echo "$out4" | grep -qi 'STARS_TEXT=96k stars' && r=yes || r=no; assert "extractClaims: stars claim text captures '96k stars'" yes "$r"

# -- Test 5: resolveGithub handle-as-login fallback (guarded) -----------------
echo "Test 5: resolveGithub handle-as-login fallback"

cat > "$tmpdir/resolve-fallback.mjs" <<EOF
import { resolveGithub } from "$lib_url";
function ghFnMatch(args) {
  if (args[0] === "api" && args[1] === "users/x") return { login: "x", twitter_username: "x" };
  throw new Error("unexpected ghFn call: " + JSON.stringify(args));
}
function ghFnMismatch(args) {
  if (args[0] === "api" && args[1] === "users/x") return { login: "x", twitter_username: "someoneelse" };
  throw new Error("unexpected ghFn call: " + JSON.stringify(args));
}
// bio names no github -> fallback tries handle-as-login, accepts on twitter_username match (@ stripped)
console.log("ACCEPT_LOGIN=" + resolveGithub("no github here", "@x", { ghFn: ghFnMatch }).login);
// ...and REJECTS when twitter_username points elsewhere
console.log("REJECT_LOGIN=" + resolveGithub("no github here", "x", { ghFn: ghFnMismatch }).login);
// bio WITH a github mention -> regex wins, fallback never consulted
console.log("DIRECT_LOGIN=" + resolveGithub("see github.com/realone", "x", { ghFn: ghFnMismatch }).login);
// backward-compat: 2nd arg is the opts object (no handle)
console.log("COMPAT_LOGIN=" + resolveGithub("github.com/x", { ghFn: ghFnMatch }).login);
console.log("COMPAT_NULL=" + resolveGithub("no github mention here", { ghFn: ghFnMatch }).login);
EOF
out5b="$(node "$tmpdir/resolve-fallback.mjs" 2>&1)"
echo "$out5b" | grep -q 'ACCEPT_LOGIN=x' && r=yes || r=no; assert "resolveGithub: handle-login fallback ACCEPTS on twitter_username match" yes "$r"
echo "$out5b" | grep -q 'REJECT_LOGIN=null' && r=yes || r=no; assert "resolveGithub: handle-login fallback REJECTS on twitter_username mismatch" yes "$r"
echo "$out5b" | grep -q 'DIRECT_LOGIN=realone' && r=yes || r=no; assert "resolveGithub: bio github mention wins over fallback" yes "$r"
echo "$out5b" | grep -q 'COMPAT_LOGIN=x' && r=yes || r=no; assert "resolveGithub: backward-compat 2-arg opts still extracts from bio" yes "$r"
echo "$out5b" | grep -q 'COMPAT_NULL=null' && r=yes || r=no; assert "resolveGithub: backward-compat 2-arg opts still returns null when no mention" yes "$r"

# -- Test 6: verifyClaims — resolved-URL repo + star capture/contradiction ----
echo "Test 6: verifyClaims stars + resolved-URL repo"

cat > "$tmpdir/verify-stars.mjs" <<EOF
import { extractClaims, verifyClaims } from "$lib_url";
function ghFn(args) {
  if (args[0] === "api" && args[1] === "repos/x/bar") {
    return { full_name: "x/bar", owner: { login: "x" }, stargazers_count: 96000 };
  }
  throw new Error("unexpected ghFn call: " + JSON.stringify(args));
}
const headFn = () => 200;
const accountSource = { spike_result: "B" };

// A resolved t.co -> github URL fed as extra claim-source text -> verifiable repo claim,
// and the verified repo's stargazers_count is captured onto the claim.
const claims = extractClaims("building things", ["https://github.com/x/bar", "Foo hit 96k stars"]);
const dossier = { handle: "x", repos: { login: "x" }, account: { followers: null }, claims };
const verified = verifyClaims(dossier, { ghFn, headFn, accountSource });
const repoClaim = verified.find(c => c.kind === "repo");
console.log("REPO_STATUS=" + repoClaim.status);
console.log("REPO_STARS=" + repoClaim.stars);
console.log("STAR_MATCH_STATUS=" + verified.find(c => c.kind === "stars").status);

// Star claim far from the verified repo's actual count -> contradicted.
const claims2 = extractClaims("building things", ["https://github.com/x/bar", "we have 500 stars"]);
const dossier2 = { handle: "x", repos: { login: "x" }, account: { followers: null }, claims: claims2 };
const verified2 = verifyClaims(dossier2, { ghFn, headFn, accountSource });
console.log("STAR_CONTRADICT_STATUS=" + verified2.find(c => c.kind === "stars").status);

// Star claim with no verifiable repo to tie to -> stays unverified.
const claims3 = extractClaims("building things", ["we have 500 stars"]);
const dossier3 = { handle: "x", repos: { login: null }, account: { followers: null }, claims: claims3 };
const verified3 = verifyClaims(dossier3, { ghFn, headFn, accountSource });
console.log("STAR_UNTIED_STATUS=" + verified3.find(c => c.kind === "stars").status);
EOF
out6="$(node "$tmpdir/verify-stars.mjs" 2>&1)"
echo "$out6" | grep -q 'REPO_STATUS=verified' && r=yes || r=no; assert "verifyClaims: resolved github URL produces a verified repo claim" yes "$r"
echo "$out6" | grep -q 'REPO_STARS=96000' && r=yes || r=no; assert "verifyClaims: verified repo captures stargazers_count onto claim.stars" yes "$r"
echo "$out6" | grep -q 'STAR_MATCH_STATUS=verified' && r=yes || r=no; assert "verifyClaims: star claim tied to a verified repo (close match) -> verified" yes "$r"
echo "$out6" | grep -q 'STAR_CONTRADICT_STATUS=contradicted' && r=yes || r=no; assert "verifyClaims: star claim far from verified repo count -> contradicted" yes "$r"
echo "$out6" | grep -q 'STAR_UNTIED_STATUS=unverified' && r=yes || r=no; assert "verifyClaims: star claim with no verifiable repo -> unverified" yes "$r"

# -- Test 7: repo ownership + course HEAD status grounding --------------------
echo "Test 7: repo null-login + course HEAD status"

cat > "$tmpdir/verify-grounding.mjs" <<EOF
import { verifyClaims } from "$lib_url";

// A repo the account merely mentions, but the account has NO resolved github
// login (repos.login null) -> ownership can't be established -> unverified,
// NOT verified (must not credit someone else's repo as the account's own).
function ghExists(args) {
  if (args[0] === "api" && args[1] === "repos/vercel/next.js") {
    return { owner: { login: "vercel" }, stargazers_count: 100000 };
  }
  throw new Error("unexpected ghFn call: " + JSON.stringify(args));
}
const noLogin = {
  handle: "someone", repos: { login: null }, account: { followers: null },
  claims: [{ text: "github.com/vercel/next.js", kind: "repo" }],
};
console.log("NULL_LOGIN_REPO=" + verifyClaims(noLogin, { ghFn: ghExists }).find(c => c.kind === "repo").status);

// Course HEAD status: 200 -> verified, 404 -> contradicted, 403/429/500 ->
// unverified (ambiguous, not evidence the URL is dead).
function dossierCourse() {
  return { handle: "x", repos: { login: null }, account: { followers: null },
    claims: [{ text: "course at maven.com/foo", kind: "course" }] };
}
const codes = { ok: 200, gone: 404, blocked: 403, limited: 429, err: 500 };
for (const [name, code] of Object.entries(codes)) {
  const st = verifyClaims(dossierCourse(), { headFn: () => code }).find(c => c.kind === "course").status;
  console.log("COURSE_" + name.toUpperCase() + "=" + st);
}
EOF
out7="$(node "$tmpdir/verify-grounding.mjs" 2>&1)"
echo "$out7" | grep -q 'NULL_LOGIN_REPO=unverified' && r=yes || r=no; assert "verifyClaims: repo claim with null account login -> unverified (no false ownership)" yes "$r"
echo "$out7" | grep -q 'COURSE_OK=verified' && r=yes || r=no; assert "verifyClaims: course HEAD 2xx -> verified" yes "$r"
echo "$out7" | grep -q 'COURSE_GONE=contradicted' && r=yes || r=no; assert "verifyClaims: course HEAD 404 -> contradicted" yes "$r"
echo "$out7" | grep -q 'COURSE_BLOCKED=unverified' && r=yes || r=no; assert "verifyClaims: course HEAD 403 -> unverified (not false-contradicted)" yes "$r"
echo "$out7" | grep -q 'COURSE_LIMITED=unverified' && r=yes || r=no; assert "verifyClaims: course HEAD 429 -> unverified" yes "$r"
echo "$out7" | grep -q 'COURSE_ERR=unverified' && r=yes || r=no; assert "verifyClaims: course HEAD 500 -> unverified" yes "$r"

# -- Results summary -----------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
