/**
 * cookie-jar.mjs - minimal Netscape (cookies.txt) parser + Cookie header
 * builder. Pure string logic; no I/O, no network. node `fetch` carries no
 * cookie jar, so reddit-enrich.mjs uses this to attach exported burner-account
 * cookies to its requests (HIMMEL-769). The parser never logs or returns the
 * cookie VALUES anywhere except inside the header string the caller sends.
 */

/**
 * Parse Netscape cookies.txt text into cookie records.
 * Format (TAB-separated, 7 fields):
 *   domain  includeSubdomains  path  secure  expiry  name  value
 * Lines beginning with '#' are comments, EXCEPT the '#HttpOnly_' prefix that
 * Cookie-Editor / curl emit for HttpOnly cookies - those are real cookies.
 * Blank / short (< 7 field) lines are skipped.
 *
 * @param {string} text
 * @returns {Array<{domain:string, includeSubdomains:boolean, path:string,
 *   secure:boolean, expires:number, name:string, value:string}>}
 */
export function parseNetscapeCookies(text) {
  const out = [];
  for (const raw of String(text || "").split(/\r?\n/)) {
    if (!raw) continue;
    let line = raw;
    if (line.startsWith("#HttpOnly_")) line = line.slice("#HttpOnly_".length);
    else if (line.startsWith("#")) continue;
    const f = line.split("\t");
    if (f.length < 7) continue;
    const [domain, includeSub, path, secure, expiry, name, ...rest] = f;
    if (!name) continue;
    out.push({
      domain: String(domain || "").toLowerCase(),
      includeSubdomains: String(includeSub || "").toUpperCase() === "TRUE",
      path: path || "/",
      secure: String(secure || "").toUpperCase() === "TRUE",
      expires: Number.parseInt(expiry, 10) || 0,
      name,
      value: rest.join("\t"),
    });
  }
  return out;
}

/**
 * Whether a cookie's domain applies to host. A leading-dot cookie domain
 * ('.reddit.com') matches the bare domain and any subdomain; a bare cookie
 * domain matches exactly or a subdomain. Host compared lowercase.
 */
function domainMatches(cookie, host) {
  const cd = cookie.domain.replace(/^\./, "");
  if (!cd) return false;
  return host === cd || host.endsWith("." + cd);
}

/**
 * Build a 'name=value; name2=value2' Cookie header value for host at nowEpoch.
 * - Keeps only cookies whose domain matches host.
 * - Drops expired cookies (expires !== 0 && expires < nowEpoch); expires === 0
 *   is a session cookie and is kept.
 * - Dedups by name (first wins), preserves file order.
 * Returns '' when no live cookie applies (caller treats as auth_expired).
 *
 * @param {ReturnType<typeof parseNetscapeCookies>} jar
 * @param {string} host
 * @param {number} nowEpoch  seconds since epoch
 * @returns {string}
 */
export function cookieHeaderFor(jar, host, nowEpoch) {
  const h = String(host || "").toLowerCase();
  const now = Number.isFinite(nowEpoch) ? nowEpoch : Math.floor(Date.now() / 1000);
  const seen = new Set();
  const parts = [];
  for (const c of jar || []) {
    if (!domainMatches(c, h)) continue;
    if (c.expires !== 0 && c.expires < now) continue;
    if (seen.has(c.name)) continue;
    seen.add(c.name);
    parts.push(`${c.name}=${c.value}`);
  }
  return parts.join("; ");
}
