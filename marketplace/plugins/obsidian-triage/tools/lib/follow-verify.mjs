#!/usr/bin/env node
// follow-verify.mjs — HIMMEL-660 X-follow-list scorer, Task 3: claim
// extraction + gh-api resource evidence + claim verification. Pure —
// takes injected `ghFn`/`headFn` deps, no network calls of its own.
//
// Dependency contract (real impls live with the caller, e.g. Task 5's
// gather subcommand):
//   ghFn(argsArray) — calls `gh api <path>` (spawnSync under the hood)
//     and returns the already-JSON-parsed response (array or object).
//     Tests stub it directly with fixture data/errors.
//   headFn(url) — issues an HTTP HEAD request and returns the numeric
//     status code. Tests stub it directly.
//
// `verifyClaims` cross-checks self-reported claims against hard evidence
// ("grounded, not trusting"): repo claims via `ghFn` existence + owner
// match, course/url claims via `headFn` 2xx, follower claims gated on
// `accountSource.spike_result` (Task 0: "A" = a confirmed account-level
// source exists, so a mismatch is a real contradiction; "B" = no such
// source, so follower claims can only ever be `unverified`, never
// `contradicted` — we don't have hard evidence to contradict them with).

const GITHUB_URL_RE = /github\.com\/[A-Za-z0-9_.\/-]+/gi;
const REPO_WORD_RE = /\brepos?\b/gi;
const FOLLOWERS_RE = /\d[\d,.]*\s*[km]?\s*followers\b/gi;
const COURSE_HOST_RE = /(?:maven\.com|udemy\.com|gumroad\.com|deeplearning\.ai)\/\S+/gi;
// "works at X" / "founder of X" are self-descriptions we accept from both
// bio and tweets. A bare `@mention`, by contrast, is only a self-role when
// it's in the BIO — tweet bodies open with a "# Tweet by @handle" byline and
// mention other handles, so mining @mentions from tweets floods `claims`
// with always-`unverified` noise that drowns real signal (HIMMEL-660).
const ROLE_PHRASE_RE = /\bworks?\s+at\s+\S+|\bfounder\s+of\s+\S+/gi;
const MENTION_RE = /@[A-Za-z0-9_]+\b/gi;
const STARS_RE = /\d[\d,.]*\s*[km]?\s*stars\b/gi;

function pushMatches(regex, kind, text, claims) {
  for (const m of text.matchAll(regex)) {
    claims.push({ text: m[0].trim(), kind });
  }
}

/**
 * Parse self-assertions out of a bio + sample tweets into
 * `{text, kind}` claims. kind ∈ repo|followers|course|role|stars; text not
 * matching any known pattern is skipped (not tagged `other`). `@mention`
 * role claims come only from `bio`; "works at"/"founder of" from both bio
 * and tweets. The caller may append resolved t.co destinations (see
 * `follow-dossier.extractShortLinks`) to `sampleTweets` so shortened links
 * surface their real github/course/product URLs here.
 */
export function extractClaims(bio, sampleTweets = []) {
  const claims = [];
  if (bio) pushMatches(MENTION_RE, "role", bio, claims);
  for (const text of [bio, ...sampleTweets]) {
    if (!text) continue;
    pushMatches(GITHUB_URL_RE, "repo", text, claims);
    pushMatches(REPO_WORD_RE, "repo", text, claims);
    pushMatches(FOLLOWERS_RE, "followers", text, claims);
    pushMatches(COURSE_HOST_RE, "course", text, claims);
    pushMatches(STARS_RE, "stars", text, claims);
    pushMatches(ROLE_PHRASE_RE, "role", text, claims);
  }
  return claims;
}

/**
 * Resolves a github login for the account. First regexes a login out of
 * `bio`. Failing that, a SAFE handle-as-login fallback: call
 * `ghFn(["api", "users/<handle>"])` and accept `<handle>` as the login ONLY
 * when the github user's `twitter_username` cross-checks against the X
 * handle (case-insensitive) — so we never attribute a stranger's repos.
 * Backward-compatible: `resolveGithub(bio)` and `resolveGithub(bio, {ghFn})`
 * (opts as 2nd arg, no handle) both still work. {login: string|null}.
 */
export function resolveGithub(bio, handle, opts) {
  // 2-arg legacy shape: resolveGithub(bio, { ghFn }) — 2nd arg is opts.
  if (handle && typeof handle === "object") {
    opts = handle;
    handle = undefined;
  }
  const { ghFn } = opts || {};

  const m = /github\.com\/([A-Za-z0-9-]+)/i.exec(bio || "");
  if (m) return { login: m[1] };

  const h = handle ? String(handle).replace(/^@/, "") : "";
  if (h && ghFn) {
    let user;
    try {
      user = ghFn(["api", `users/${h}`]);
    } catch {
      return { login: null };
    }
    const tw = user && user.twitter_username;
    if (tw && String(tw).toLowerCase() === h.toLowerCase()) return { login: h };
  }
  return { login: null };
}

const FOCUS_RE = /\b(agent|harness|claude|orchestration|memory|second-brain|llm|ai)\b/i;

function isTopical(repo) {
  const haystack = [repo.name, repo.description, ...(repo.topics || [])]
    .filter(Boolean)
    .join(" ");
  return FOCUS_RE.test(haystack);
}

function emptyRepoEvidence(status) {
  return {
    repo_count: 0,
    total_stars: 0,
    recent_pushed_at: null,
    topical_hits: 0,
    sample_descriptions: [],
    status,
  };
}

/**
 * Fetches `login`'s public repos via `ghFn(["api", "users/<login>/repos?per_page=100"])`
 * and summarizes them into resource evidence.
 */
export function fetchRepos(login, { ghFn } = {}) {
  if (!login) return emptyRepoEvidence("no_login");
  if (!ghFn) return emptyRepoEvidence("fetch_error");

  let repos;
  try {
    repos = ghFn(["api", `users/${login}/repos?per_page=100`]);
  } catch {
    return emptyRepoEvidence("fetch_error");
  }
  if (!Array.isArray(repos)) return emptyRepoEvidence("fetch_error");

  const total_stars = repos.reduce((sum, r) => sum + (r.stargazers_count || 0), 0);
  const topical_hits = repos.filter(isTopical).length;
  const sample_descriptions = repos
    .map((r) => r.description)
    .filter(Boolean)
    .slice(0, 5);

  let recentPushedMs = null;
  for (const r of repos) {
    const t = r.pushed_at ? Date.parse(r.pushed_at) : NaN;
    if (!Number.isNaN(t) && (recentPushedMs === null || t > recentPushedMs)) recentPushedMs = t;
  }

  return {
    repo_count: repos.length,
    total_stars,
    recent_pushed_at: recentPushedMs === null ? null : new Date(recentPushedMs).toISOString(),
    topical_hits,
    sample_descriptions,
    status: "ok",
  };
}

// Self-reported counts round/drift ("120k" vs an exact 118,432) — only
// treat a relative delta beyond this threshold as a real contradiction.
const FOLLOWERS_CONTRADICTION_THRESHOLD = 0.15;

function parseCountNumber(text, unit) {
  const m = new RegExp(`([\\d][\\d,.]*)\\s*([km]?)\\s*${unit}\\b`, "i").exec(text || "");
  if (!m) return null;
  let n = parseFloat(m[1].replace(/,/g, ""));
  if (Number.isNaN(n)) return null;
  const suffix = m[2].toLowerCase();
  if (suffix === "k") n *= 1_000;
  if (suffix === "m") n *= 1_000_000;
  return Math.round(n);
}

function parseFollowersNumber(text) {
  return parseCountNumber(text, "followers");
}

function parseStarsNumber(text) {
  return parseCountNumber(text, "stars");
}

function verifyFollowersClaim(claim, dossier, accountSource) {
  if (!accountSource || accountSource.spike_result !== "A") return "unverified";
  const claimed = parseFollowersNumber(claim.text);
  const actual = dossier && dossier.account && dossier.account.followers;
  if (claimed == null || actual == null) return "unverified";
  const delta = Math.abs(claimed - actual) / Math.max(actual, 1);
  return delta > FOLLOWERS_CONTRADICTION_THRESHOLD ? "contradicted" : "verified";
}

// Returns { status, stars? } — on a verified repo, `stars` carries that
// repo's stargazers_count so a "N stars" claim can later tie to it.
function verifyRepoClaim(claim, login, ghFn) {
  const m = /github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)/i.exec(claim.text);
  if (!m || !ghFn) return { status: "unverified" };
  const [, owner, repo] = m;
  let data;
  try {
    data = ghFn(["api", `repos/${owner}/${repo}`]);
  } catch {
    return { status: "unverified" };
  }
  if (!data) return { status: "unverified" };
  const ownerLogin = data.owner && data.owner.login;
  // Ownership can only be established when the account has a resolved github
  // login to match against. With no login (bio carries no github URL and the
  // handle-fallback didn't cross-check), a repo the account merely *mentions*
  // in a tweet is not its own evidence — stay unverified rather than crediting
  // someone else's repo as verified (false-verified evidence otherwise).
  if (!login || !ownerLogin) return { status: "unverified" };
  if (ownerLogin.toLowerCase() !== String(login).toLowerCase()) {
    return { status: "contradicted" };
  }
  return { status: "verified", stars: data.stargazers_count };
}

// A "N stars" claim is only verifiable once tied to a verified repo. We tie
// it to the closest-matching verified repo star count (`verifiedRepoClaims`
// carry `.stars`); within the relative threshold -> verified, beyond it ->
// contradicted. No verified repo to tie to -> unverified (no hard evidence).
function verifyStarsClaim(claim, verifiedRepoClaims) {
  const claimed = parseStarsNumber(claim.text);
  if (claimed == null) return "unverified";
  const counts = verifiedRepoClaims
    .map((c) => c.stars)
    .filter((n) => typeof n === "number");
  if (!counts.length) return "unverified";
  let best = Infinity;
  for (const actual of counts) {
    const delta = Math.abs(claimed - actual) / Math.max(actual, 1);
    if (delta < best) best = delta;
  }
  return best > FOLLOWERS_CONTRADICTION_THRESHOLD ? "contradicted" : "verified";
}

function verifyUrlClaim(claim, headFn) {
  const m = /(?:https?:\/\/\S+|(?:maven|udemy|gumroad)\.com\/\S+|deeplearning\.ai\/\S+)/i.exec(claim.text);
  if (!m || !headFn) return "unverified";
  const url = /^https?:\/\//i.test(m[0]) ? m[0] : `https://${m[0]}`;
  let status;
  try {
    status = headFn(url);
  } catch {
    return "unverified";
  }
  if (typeof status !== "number") return "unverified";
  if (status >= 200 && status < 300) return "verified";
  // Only a genuine gone-status (404/410) is evidence the URL is dead. A
  // 403/405/429/5xx is bot-blocking / method-not-allowed / rate-limit /
  // transient server error on a URL that may well be live — not evidence the
  // claim is false. Leave it unverified so the web rung can still corroborate.
  if (status === 404 || status === 410) return "contradicted";
  return "unverified";
}

/**
 * Cross-checks `dossier.claims` against evidence: repo claims via `ghFn`
 * existence + owner match against `dossier.repos.login`, course claims
 * via `headFn` 2xx, follower claims gated on `accountSource.spike_result`.
 * Returns a new claims array (each claim + `status`); role claims (and
 * any claim we have no evidence source for) stay `unverified`.
 */
export function verifyClaims(dossier, { ghFn, headFn, accountSource } = {}) {
  const claims = (dossier && dossier.claims) || [];
  const login = dossier && dossier.repos && dossier.repos.login;

  // First pass: everything but `stars`. Repo claims capture their verified
  // star count so `stars` claims can tie to them in the second pass.
  const result = claims.map((claim) => {
    if (claim.kind === "repo") {
      const { status, stars } = verifyRepoClaim(claim, login, ghFn);
      const out = { ...claim, status };
      if (status === "verified" && typeof stars === "number") out.stars = stars;
      return out;
    } else if (claim.kind === "followers") {
      return { ...claim, status: verifyFollowersClaim(claim, dossier, accountSource) };
    } else if (claim.kind === "course") {
      return { ...claim, status: verifyUrlClaim(claim, headFn) };
    } else if (claim.kind === "stars") {
      return { ...claim }; // status filled in second pass
    }
    return { ...claim, status: "unverified" };
  });

  // Second pass: tie `stars` claims to the verified repo claims' counts.
  const verifiedRepoClaims = result.filter((c) => c.kind === "repo" && c.status === "verified");
  for (const c of result) {
    if (c.kind === "stars") c.status = verifyStarsClaim(c, verifiedRepoClaims);
  }
  return result;
}
