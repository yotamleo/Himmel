/**
 * telegram-clip.mjs — LUNA-58 pure message→clip mapping for the telegram
 * ingestion entry point. No I/O, no network. Mirrors the slug + frontmatter
 * conventions used across obsidian-triage tools.
 *
 * A telegram message (text / bare URL / forward) is mapped to a LUNA-2
 * Web-Clipper-shaped clip note so /harvest-clips can ingest it on its next
 * pass. Provenance (sender, ts, msg-id) is preserved in frontmatter.
 */

/** Recognised clip types this entry point can emit. */
export const CLIP_TYPES = Object.freeze([
  "research", "tweet", "youtube", "reddit", "article", "note",
]);

/**
 * First http(s) URL in a message, trailing punctuation stripped, or null.
 * (Telegram messages often wrap a link in prose: "look at https://x — neat!")
 *
 * Parens are allowed INSIDE the match so wiki-style links survive
 * (en.wikipedia.org/wiki/Foo_(bar)); a trailing `)` is only stripped when it is
 * unbalanced (more `)` than `(`), i.e. it closes a wrapping "(https://x)" rather
 * than belonging to the URL. Stripping loops because closing punctuation can sit
 * on either side of the paren ("(https://x).").
 */
export function firstUrl(text) {
  const m = String(text || "").match(/https?:\/\/[^\s<>]+/i);
  if (!m) return null;
  let url = m[0];
  for (;;) {
    const trimmed = url.replace(/[.,;:!?\]'"]+$/, "");
    if (trimmed !== url) { url = trimmed; continue; }
    const opens = (url.match(/\(/g) || []).length;
    const closes = (url.match(/\)/g) || []).length;
    if (url.endsWith(")") && closes > opens) { url = url.slice(0, -1); continue; }
    break;
  }
  return url;
}

/**
 * Map a message to a clip {type, source} by the host of its first URL.
 * No URL (or an unparseable one) → a plain `note`. github → `research` so the
 * /harvest-clips github-ingest path (research/article + github.com) dispatches
 * obsidian-triage:luna-ingest.
 */
export function classifyMessage({ text }) {
  const url = firstUrl(text);
  if (!url) return { type: "note", source: null };
  let host;
  try {
    host = new URL(url).hostname.replace(/^www\./i, "").toLowerCase();
  } catch {
    return { type: "note", source: null };
  }
  if (host === "github.com") return { type: "research", source: url };
  if (host === "x.com" || host === "twitter.com" || host === "mobile.twitter.com") {
    return { type: "tweet", source: url };
  }
  if (host === "youtube.com" || host === "m.youtube.com" || host === "youtu.be") {
    return { type: "youtube", source: url };
  }
  if (host === "reddit.com" || host.endsWith(".reddit.com")) {
    return { type: "reddit", source: url };
  }
  return { type: "article", source: url };
}

/**
 * Numeric tweet status id for an X URL (x.com / twitter.com, with www./mobile.
 * prefixes stripped), or null for a non-X URL, a non-status X URL, or an
 * unparseable input.
 *
 * This is the dedup-at-ingest match key for X: x.com/i/status/<id> (a telegram
 * forward) and x.com/<user>/status/<id> (a browser Web-Clipper clip) of the SAME
 * tweet both yield <id>. A canonical-URL comparison would miss this pairing —
 * url-canonical's canonicalize() keeps the /<user>/ path, so the two forms
 * produce different canonical strings.
 */
export function tweetStatusId(url) {
  let u;
  try {
    u = new URL(String(url == null ? "" : url).trim());
  } catch {
    return null;
  }
  const host = (u.hostname || "").toLowerCase().replace(/^(?:www|mobile)\./, "");
  if (host !== "x.com" && host !== "twitter.com") return null;
  const m = u.pathname.match(/\/status\/(\d+)/);
  return m ? m[1] : null;
}

/** Lowercase kebab slug, alnum-only, capped at 60 chars. */
export function slugify(s) {
  const out = String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60)
    .replace(/-+$/g, "");
  return out || "untitled";
}

/**
 * Deterministic clip filename: telegram-<sanitized-msgId>-<title-slug>.md.
 * The msg-id prefix makes a prior write discoverable even if the title slug
 * shifts (defence-in-depth alongside the frontmatter telegram_msg_id dedup).
 */
export function clipFilename({ msgId, title }) {
  const id = String(msgId || "").replace(/[^A-Za-z0-9_-]/g, "") || "0";
  return `telegram-${id}-${slugify(title)}.md`;
}

/**
 * Title for the clip: first non-empty line of the message (URLs stripped),
 * capped at 80 chars. If the message is only a URL, derive from host + path.
 */
export function deriveTitle({ text, type, source }) {
  const firstLine = String(text || "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .find(Boolean) || "";
  const stripped = firstLine.replace(/https?:\/\/\S+/gi, "").replace(/\s{2,}/g, " ").trim();
  if (stripped) {
    return stripped.length > 80 ? stripped.slice(0, 80).trim() : stripped;
  }
  if (source) {
    try {
      const u = new URL(source);
      const host = u.hostname.replace(/^www\./i, "");
      const path = u.pathname.replace(/\/+$/, "");
      return `${type} from ${host}${path}`.slice(0, 80);
    } catch {
      /* fall through */
    }
  }
  return `Telegram ${type}`;
}

/** Double-quoted, escaped YAML scalar (newlines/tabs flattened to spaces). */
function yamlQuote(s) {
  return '"' + String(s == null ? "" : s)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/[\n\t]+/g, " ") + '"';
}

/**
 * Build a LUNA-2 Web-Clipper-shaped clip note (markdown string) from a telegram
 * message. The clip carries NO `harvested_at:` so /harvest-clips treats it as
 * unharvested and ingests it. The original message text is preserved verbatim
 * in the body. Provenance keys: clipped_via / telegram_sender / telegram_ts /
 * telegram_msg_id / telegram_chat_id.
 *
 * The clip carries NO `processed:`/`lifecycle:` marker and lands top-level in
 * Clippings/, so by the 3-state derivation (design §12.A: state = folder +
 * existing markers, no `lifecycle:` enum) it IS inbox-state — there is no marker
 * to set (LUNA-91). `telegram_chat_id` is optional provenance the LUNA-91
 * promotion digest needs to target a reply; it is omitted when not supplied
 * (backward-compatible with clips filed before LUNA-91).
 */
export function buildClip({ sender, ts, msgId, chatId, text, type, source, today }) {
  if (!CLIP_TYPES.includes(type)) {
    throw new Error(`buildClip: unknown clip type "${type}"`);
  }
  const title = deriveTitle({ text, type, source });
  const fm = [
    "---",
    `title: ${yamlQuote(title)}`,
    ...(source ? [`source: ${source}`] : []),
    `date_clipped: ${today}`,
    `type: ${type}`,
    "tags: []",
    "status: unread",
    "clipped_via: telegram",
    `telegram_sender: ${yamlQuote(sender)}`,
    `telegram_ts: ${yamlQuote(ts)}`,
    `telegram_msg_id: ${yamlQuote(String(msgId))}`,
    ...(chatId ? [`telegram_chat_id: ${yamlQuote(String(chatId))}`] : []),
    "---",
  ];
  const bodyText = String(text || "").trim();
  const parts = [fm.join("\n"), "", `# ${title}`, ""];
  if (bodyText) parts.push(bodyText, "");
  if (source) parts.push("## Source", `[${source}](${source})`, "");
  return parts.join("\n");
}
