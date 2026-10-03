/**
 * daily-report.mjs — pure rendering + carry-over logic for the day note's
 * `## Daily report` section (HIMMEL-4182).
 *
 * The report turns a day's intake into decisions: that day's triaged sources
 * grouped by evidence_kind, a short ranked list of DETERMINISTIC suggested
 * actions (no model), and a carry-over of earlier actions nobody acted on.
 *
 * An action is one checkbox line carrying a stable marker:
 *   - [ ] <text> <!-- act:<8hex> since:YYYY-MM-DD -->
 * `[x]` = done, `[-]` = dismissed. An id ticked or dismissed in ANY scanned
 * report is resolved for good; an id still unchecked is re-listed under
 * `### Carried over` with its age until someone resolves it.
 *
 * Suggestions are proposals only: nothing here edits another note. No I/O.
 */

import { parse, fmScalar, fmList, sha256, stripCR } from "./frontmatter.mjs";

export const REPORT_HEADING = "## Daily report";
export const RUBRIC_PATH = "docs/tool-adoption/rubric.md";
export const MAX_ACTIONS = 7;
const WHY_MAX = 140;
const TITLE_MAX = 80;
const CITED_MAX = 3;
const TICKET_REPOS = ["himmel", "luna", "salus"];
const ITEM_RE = /^- \[(.)\] (.*?)\s*<!-- act:([0-9a-f]{8}) since:(\d{4}-\d{2}-\d{2}) -->\s*$/;

/** `s` cut to `max` chars with an ellipsis. */
function clip(s, max) {
  return s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s;
}

/** `[[link|title]]`, the title shortened and stripped of wikilink-breaking characters. */
export function wikilink(link, title) {
  const t = clip(String(title || "").replace(/[[\]|]/g, " ").replace(/\s+/g, " ").trim(), TITLE_MAX);
  return t ? `[[${link}|${t}]]` : `[[${link}]]`;
}

/** First sentence of a clip body's first prose line, cut to WHY_MAX chars.
 *  Starts after a `## The Idea` heading when there is one; skips headings,
 *  HTML comments and bare URLs. "" when the body has no prose. */
export function whyOf(content) {
  const { lines, bounds } = parse(content);
  let body = (bounds ? lines.slice(bounds.close + 1) : lines).map(stripCR);
  const idea = body.findIndex((l) => /^##\s+The Idea\s*$/.test(l));
  if (idea !== -1) body = body.slice(idea + 1);
  for (const raw of body) {
    const l = raw.trim();
    if (!l || l.startsWith("#") || l.startsWith("<!--") || /^https?:\/\/\S+$/.test(l)) continue;
    const m = l.match(/^(.*?[.!?])(\s|$)/);
    const s = m ? m[1] : l;
    return clip(s, WHY_MAX);
  }
  return "";
}

/** 754 → "12:34"; 3725 → "1:02:05". */
export function formatDuration(totalSeconds) {
  const s = Math.max(0, Math.round(Number(totalSeconds) || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}

/**
 * Build a source record from a clip's content. `link` is the vault-relative
 * path without `.md`. Video fields come from HIMMEL-4107's media keys and are
 * present only when `media_video_duration_s` is.
 */
export function sourceFromClip(link, content) {
  const { lines, bounds } = parse(content);
  const close = bounds ? bounds.close : 0;
  const get = (k) => (bounds ? fmScalar(lines, close, k) : "");
  const kinds = bounds ? fmList(lines, close, "evidence_kind") : [];
  const statsLikes = get("tweet_stats").match(/likes:\s*(\d+)/);
  const dur = get("media_video_duration_s");
  return {
    link,
    // fmScalar strips the quotes of a double-quoted value but not its escapes.
    title: get("title").replace(/\\(["\\])/g, "$1") || link.split("/").pop(),
    kind: kinds[0] || "unsorted",
    kinds,
    tags: bounds ? fmList(lines, close, "tags") : [],
    source: get("source"),
    harvestStatus: get("harvest_status"),
    likes: statsLikes ? Number(statsLikes[1]) : 0,
    why: whyOf(content),
    // ponytail: no digest link yet, add it when HIMMEL-4108 item 4 writes the digest key.
    video: dur
      ? {
          duration: Number(dur),
          coverage: get("media_transcript_coverage"),
          source: get("media_transcript_source"),
        }
      : null,
  };
}

/** Keyed on what the action does and the day it was suggested, not on which
 *  clips it cites: a clip joining a fold later that day keeps its id, so a
 *  tick already made on it survives the re-run. */
export function actionId(verb, target, date) {
  return sha256(`${verb}|${target}|${date}`).slice(0, 8);
}

/**
 * Deterministic suggestions. Each source gets one action, first rule wins:
 * failed harvest → archive; tag/source names a repo → file a ticket; github
 * source or `tools` kind → evaluate the tool; a tag shared with a MOC → fold
 * into it (clips sharing a MOC merge into one action); else archive.
 * `mocs` = [{ link, tags:[...] }]. Ids in `seen` are dropped before the
 * MAX_ACTIONS cap; ids in `pinned` (already resolved on today's report) rank
 * first, so a later, better suggestion cannot push a tick off the note.
 * Then: archive last, more cited clips, engagement, text.
 * Returns [{ id, text, links }].
 */
export function suggestActions(sources, mocs, { date = "", seen = new Set(), pinned = new Set() } = {}) {
  const byKey = new Map();
  const add = (verb, target, src, render, weight) => {
    const key = `${verb}|${target}`;
    if (!byKey.has(key)) byKey.set(key, { verb, target, srcs: [], render, weight });
    byKey.get(key).srcs.push(src);
  };
  const sortedMocs = [...mocs].sort((a, b) => a.link.localeCompare(b.link));
  for (const s of sources) {
    const hay = `${s.tags.join(" ")} ${s.source}`.toLowerCase();
    const repo = TICKET_REPOS.find((r) => new RegExp(`\\b${r}\\b`).test(hay));
    const moc = sortedMocs.find((m) => m.tags.some((t) => s.tags.includes(t)));
    if (/^(failed|error)$/.test(s.harvestStatus)) {
      add("archive", s.link, s, (ls) => `Archive ${ls} (harvest failed)`, 1);
    } else if (repo) {
      add("ticket", `${repo}:${s.link}`, s, (ls) => `File a ticket in ${repo} for ${ls}`, 0);
    } else if (/^https?:\/\/(www\.)?github\.com\//.test(s.source) || s.kinds.includes("tools")) {
      add("evaluate", s.link, s, (ls) => `Evaluate tool ${ls} — rubric: \`${RUBRIC_PATH}\``, 0);
    } else if (moc) {
      add("fold", moc.link, s, (ls) => `Fold ${ls} into [[${moc.link}]]`, 0);
    } else {
      add("archive", s.link, s, (ls) => `Archive ${ls} (no fold target)`, 1);
    }
  }
  const actions = [...byKey.values()].map((a) => {
    const srcs = [...a.srcs].sort((x, y) => x.link.localeCompare(y.link));
    const links = srcs.map((x) => x.link);
    const shown = srcs.slice(0, CITED_MAX).map((x) => wikilink(x.link, x.title)).join(", ");
    const more = srcs.length > CITED_MAX ? ` and ${srcs.length - CITED_MAX} more` : "";
    return {
      id: actionId(a.verb, a.target, date),
      text: a.render(shown + more),
      links,
      weight: a.weight,
      likes: srcs.reduce((n, x) => n + x.likes, 0),
    };
  }).filter((a) => !seen.has(a.id));
  actions.sort((a, b) =>
    pinned.has(b.id) - pinned.has(a.id) || a.weight - b.weight || b.links.length - a.links.length || b.likes - a.likes || a.text.localeCompare(b.text));
  return actions.slice(0, MAX_ACTIONS).map(({ id, text, links }) => ({ id, text, links }));
}

/** The lines of the `heading` section (heading excluded), or [] if absent. */
export function sectionLines(content, heading) {
  const lines = content.split(/\r?\n/);
  const start = lines.indexOf(heading);
  if (start === -1) return [];
  const out = [];
  for (let i = start + 1; i < lines.length && !/^## /.test(lines[i]); i++) out.push(lines[i]);
  return out;
}

/** Action items in a report section: [{ mark, text, id, since }]. The `(Nd)`
 *  age prefix of a carried line is stripped so the text stays stable. */
export function parseItems(lines) {
  const items = [];
  for (const l of lines) {
    const m = l.match(ITEM_RE);
    if (m) items.push({ mark: m[1], text: m[2].replace(/^\(\d+d\) /, ""), id: m[3], since: m[4] });
  }
  return items;
}

export const isResolved = (mark) => mark === "x" || mark === "X" || mark === "-";

/**
 * Carry-over from prior reports, given oldest → newest as arrays of item
 * lists. Returns { carried:[{id,text,since}], seen:Set<id> } — `seen` is every
 * id met (open or resolved), so today never re-suggests one.
 */
export function carryOver(priorItemLists) {
  const open = new Map();
  const resolved = new Set();
  for (const items of priorItemLists) {
    for (const it of items) {
      if (isResolved(it.mark)) resolved.add(it.id);
      else if (!open.has(it.id)) open.set(it.id, { id: it.id, text: it.text, since: it.since });
    }
  }
  const carried = [...open.values()]
    .filter((it) => !resolved.has(it.id))
    .sort((a, b) => a.since.localeCompare(b.since) || a.id.localeCompare(b.id));
  return { carried, seen: new Set([...open.keys(), ...resolved]) };
}

/** Whole days from `since` to `date` (both YYYY-MM-DD). */
export function ageDays(since, date) {
  return Math.round((Date.parse(`${date}T00:00:00Z`) - Date.parse(`${since}T00:00:00Z`)) / 86400000);
}

/**
 * Render the section. `marks` maps id → the mark already in today's section,
 * so a tick made on today's report survives a re-run.
 */
export function renderReportSection({ date, sources, actions, carried, marks }, eol = "\n") {
  const mark = (id) => (marks && marks.get(id)) || " ";
  const item = (id, text, since) => `- [${mark(id)}] ${text} <!-- act:${id} since:${since} -->`;
  const out = [REPORT_HEADING, ""];
  if (!sources.length) {
    out.push(`- No intake on ${date}.`, "");
  } else {
    out.push(`### Sources (${sources.length})`, "");
    const groups = new Map();
    for (const s of [...sources].sort((a, b) => a.link.localeCompare(b.link))) {
      if (!groups.has(s.kind)) groups.set(s.kind, []);
      groups.get(s.kind).push(s);
    }
    for (const kind of [...groups.keys()].sort()) {
      out.push(`**${kind}**`);
      for (const s of groups.get(kind)) {
        out.push(`- ${wikilink(s.link, s.title)}${s.why ? ` — ${s.why}` : ""}`);
        if (s.video) {
          const cov = s.video.coverage !== "" ? ` · transcript ${s.video.coverage}%` : "";
          const src = s.video.source ? ` (${s.video.source})` : "";
          out.push(`  - video ${formatDuration(s.video.duration)}${cov}${src}`);
        }
      }
      out.push("");
    }
  }
  if (actions.length) {
    out.push("### Suggested actions", "");
    for (const a of actions) out.push(item(a.id, a.text, date));
    out.push("");
  }
  if (carried.length) {
    out.push("### Carried over", "");
    for (const c of carried) out.push(item(c.id, `(${ageDays(c.since, date)}d) ${c.text}`, c.since));
    out.push("");
  }
  while (out[out.length - 1] === "") out.pop();
  return out.join(eol);
}
