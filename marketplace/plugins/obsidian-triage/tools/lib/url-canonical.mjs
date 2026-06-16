/**
 * url-canonical.mjs — shared URL canonicalisation for obsidian-triage tools.
 *
 * Mirrors the per-domain rules in:
 *   - harvest-clip-body-batch.py (Phase 3 of /harvest-clips)
 *   - playwright-crawl-x.mjs (canonicalXUrl)
 *   - fxtwitter-enrich.mjs    (canonicalXUrl)
 *
 * Rules (LUNA-37, matching harvest-clips.md Phase 3 table):
 *   - x.com / twitter.com / mobile.twitter.com  → host=x.com, keep /<user>/status/<id>, drop query
 *   - youtube.com / youtu.be                    → youtube.com/watch?v=<id>
 *   - github.com                                → lowercase owner/repo, strip /tree/, /blob/, trailing /
 *   - medium.com                                → drop ?source=
 *   - generic                                   → drop utm_*, fbclid, gclid, ref=, source=, mc_cid, mc_eid
 *
 * Returns the canonical URL string, or null when the input is unparseable
 * (caller decides how to route the clip — typically `harvest_status: failed`).
 *
 * No fetch, no I/O. Pure URL string surgery.
 */

const TRACKING_PARAMS = new Set([
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_term",
  "utm_content",
  "fbclid",
  "gclid",
  "ref",
  "source",
  "mc_cid",
  "mc_eid",
]);

const X_HOSTS = new Set([
  "x.com",
  "www.x.com",
  "twitter.com",
  "www.twitter.com",
  "mobile.twitter.com",
]);

const YOUTUBE_LONG_HOSTS = new Set([
  "youtube.com",
  "www.youtube.com",
  "m.youtube.com",
]);

const YOUTUBE_SHORT_HOSTS = new Set([
  "youtu.be",
  "www.youtu.be",
]);

const GITHUB_HOSTS = new Set([
  "github.com",
  "www.github.com",
]);

/**
 * Strip surrounding quotes (single or double) from a frontmatter value.
 * Many clips have `source: "https://..."` with quoted strings; some don't.
 */
function unquote(s) {
  if (s == null) return "";
  let v = String(s).trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
    v = v.slice(1, -1);
  }
  return v;
}

/**
 * Canonicalise a URL string. Returns canonical string or null on parse error.
 */
export function canonicalize(rawUrl) {
  const input = unquote(rawUrl);
  if (!input) return null;
  let u;
  try {
    u = new URL(input);
  } catch {
    return null;
  }
  const host = (u.hostname || "").toLowerCase();
  if (!host) return null;

  // x.com / twitter.com / mobile.twitter.com → x.com
  if (X_HOSTS.has(host)) {
    const m = u.pathname.match(/^(\/[^/]+\/status\/\d+)/);
    const path = m ? m[1] : u.pathname.replace(/\/$/, "") || "/";
    return `https://x.com${path}`;
  }

  // youtu.be → youtube.com/watch?v=<id>
  if (YOUTUBE_SHORT_HOSTS.has(host)) {
    const vid = u.pathname.replace(/^\/+/, "").split("/")[0];
    return vid ? `https://youtube.com/watch?v=${vid}` : `https://youtube.com${u.pathname}`;
  }

  // youtube.com/watch?v=<id> — strip every other param.
  if (YOUTUBE_LONG_HOSTS.has(host)) {
    const vid = u.searchParams.get("v");
    if (vid) return `https://youtube.com/watch?v=${vid}`;
    // /shorts/<id> + /embed/<id> are also legit video pointers — keep them.
    return `https://youtube.com${u.pathname}`;
  }

  // github.com — lowercase owner/repo, strip /tree/<branch>, /blob/<branch>/<path>, trailing /
  if (GITHUB_HOSTS.has(host)) {
    const parts = u.pathname.split("/").filter(Boolean);
    if (parts.length >= 2) {
      const [owner, repo, ...rest] = parts;
      let kept = [owner.toLowerCase(), repo.toLowerCase()];
      if (rest.length && (rest[0] === "tree" || rest[0] === "blob")) {
        // strip /tree/<branch>[...] + /blob/<branch>/<path>
        // Per harvest-clips.md, we strip the entire ref-scoped suffix.
      } else {
        kept = kept.concat(rest);
      }
      return `https://github.com/${kept.join("/")}`.replace(/\/$/, "");
    }
    return `https://github.com${u.pathname.replace(/\/$/, "") || "/"}`;
  }

  // medium.com — drop ?source=
  if (host === "medium.com" || host.endsWith(".medium.com")) {
    const params = new URLSearchParams();
    for (const [k, v] of u.searchParams) {
      if (k !== "source") params.append(k, v);
    }
    const q = params.toString();
    return `${u.protocol}//${host}${u.pathname}${q ? "?" + q : ""}`;
  }

  // Generic — drop tracking params, keep rest of URL intact.
  const params = new URLSearchParams();
  for (const [k, v] of u.searchParams) {
    if (!TRACKING_PARAMS.has(k.toLowerCase())) params.append(k, v);
  }
  const q = params.toString();
  return `${u.protocol}//${host}${u.pathname}${q ? "?" + q : ""}`;
}

export { unquote };
