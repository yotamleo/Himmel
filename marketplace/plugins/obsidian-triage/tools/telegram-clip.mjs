#!/usr/bin/env node
/**
 * telegram-clip.mjs — LUNA-58 telegram → Clippings/ ingestion entry point.
 *
 * Maps ONE telegram message (text / bare URL / forward) to a LUNA-2
 * Web-Clipper-shaped clip note written into <vault>/Clippings/, so
 * /harvest-clips ingests it on its next pass. Idempotent: a re-run for the
 * same telegram_msg_id is a no-op (dedup by frontmatter, robust to slug drift).
 *
 * Access-gating is delegated to telegram:access (the channel only surfaces
 * allowlisted senders). This tool captures provenance and REFUSES to write
 * without a sender; it does not reimplement the allowlist.
 *
 * Usage:
 *   node telegram-clip.mjs --sender <user> --msg-id <id> --ts <iso>
 *       [--chat-id <id>] --text "<message>" [--text-file <path>] [--vault <path>] [--dry-run]
 *
 * Exit codes:
 *   0 — clip written, or skipped because the msg-id is already filed,
 *       or --dry-run printed the clip
 *   1 — bad usage / missing required arg (--msg-id, --text/--text-file)
 *   2 — env unusable (vault missing / not an Obsidian vault, no --sender,
 *       path-safety violation)
 *
 * LUNA-58.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { resolve, relative, join } from "node:path";
import { homedir } from "node:os";
import { classifyMessage, buildClip, clipFilename, deriveTitle } from "./lib/telegram-clip.mjs";
import { unquote } from "./lib/url-canonical.mjs";
import { clipUrlKeys, matchesUrl } from "./lib/clip-lookup.mjs";

const TODAY = process.env.TELEGRAM_CLIP_TODAY || new Date().toISOString().slice(0, 10);

function die(code, msg) {
  process.stderr.write(`telegram-clip: ${msg}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const a = { dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    switch (k) {
      case "-h": case "--help": a.help = true; break;
      case "--dry-run": a.dryRun = true; break;
      case "--vault": a.vault = next(); break;
      case "--sender": a.sender = next(); break;
      case "--ts": a.ts = next(); break;
      case "--msg-id": a.msgId = next(); break;
      case "--chat-id": a.chatId = next(); break;
      case "--text": a.text = next(); break;
      case "--text-file": a.textFile = next(); break;
      default: die(1, `unknown arg: ${k}`);
    }
  }
  return a;
}

const USAGE = `Usage: node telegram-clip.mjs --sender <user> --msg-id <id> [--ts <iso>] \\
    [--chat-id <id>] (--text "<message>" | --text-file <path>) [--vault <path>] [--dry-run]`;

function resolveVault(arg) {
  const candidate = arg || process.env.OBSIDIAN_VAULT_PATH || join(homedir(), "Documents", "luna");
  if (!existsSync(candidate) || !statSync(candidate).isDirectory()) {
    die(2, `vault path not found: ${candidate} (pass --vault or set OBSIDIAN_VAULT_PATH)`);
  }
  if (!existsSync(join(candidate, ".obsidian"))) {
    die(2, `not an Obsidian vault (no .obsidian/): ${candidate}`);
  }
  return resolve(candidate);
}

/** Leading `---` frontmatter block of a clip, or "" if none. Dedup matches
 * only here so a telegram_msg_id appearing in a clip BODY (e.g. a forwarded
 * message quoting another clip's frontmatter) can't false-positive. */
function frontmatterOf(content) {
  const t = String(content).replace(/\r\n/g, "\n");
  if (!t.startsWith("---\n")) return "";
  const end = t.indexOf("\n---", 4);
  return end < 0 ? "" : t.slice(4, end);
}

/** True if any clip in Clippings/ (depth ≤ 2, inbox-internals excluded) already
 * carries this telegram_msg_id in its frontmatter. A non-ENOENT read failure is
 * warned (not swallowed): the scan then biases toward writing — safe (a dup is
 * deduped downstream by canonical URL) but a recurring fault must be visible. */
function alreadyFiled(clippingsDir, msgId) {
  const id = escapeRe(String(msgId));
  // Balanced quoting only: `"<id>"` or bare `<id>`, never an unbalanced `"<id>`.
  const want = new RegExp(`^telegram_msg_id:\\s*(?:"${id}"|${id})\\s*$`, "m");
  const skip = new Set(["_synthesis", "_done"]);
  const scan = (dir, depth) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch (e) {
      if (e.code !== "ENOENT") {
        process.stderr.write(`telegram-clip: WARN dedup scan could not read ${dir}: ${e.code || e.message} — a duplicate may be written\n`);
      }
      return null;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (depth >= 2 || skip.has(e.name)) continue;
        const hit = scan(join(dir, e.name), depth + 1);
        if (hit) return hit;
      } else if (e.isFile() && e.name.endsWith(".md") && e.name !== "_deferred.md") {
        const p = join(dir, e.name);
        let content;
        try {
          content = readFileSync(p, "utf8");
        } catch (err) {
          if (err.code !== "ENOENT") {
            process.stderr.write(`telegram-clip: WARN could not read ${p} during dedup: ${err.code || err.message}\n`);
          }
          continue;
        }
        if (want.test(frontmatterOf(content))) return p;
      }
    }
    return null;
  };
  return scan(clippingsDir, 1);
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Single-line frontmatter value (surrounding quotes stripped), or null. */
function fmValue(fm, key) {
  const m = fm.match(new RegExp(`^${key}:\\s*(.+?)\\s*$`, "m"));
  return m ? unquote(m[1]) : null;
}

/**
 * The matched clip path if a clip in scope already owns this source URL, else
 * null. Complements alreadyFiled (msg-id): that catches the same MESSAGE
 * re-forwarded; this catches two DIFFERENT messages sharing a URL.
 *
 * Match key — X URLs → numeric status id (so an `x.com/i/status/<id>` telegram
 * forward matches an `x.com/<user>/status/<id>` browser clip of the same tweet);
 * non-X URLs → canonical URL. A `source` with neither (e.g. a note's null
 * source, or an unparseable URL) → no URL-dedup (returns null).
 *
 * Scope — Clippings/ inbox (depth ≤2, _synthesis/_done/_deferred.md excluded:
 * the alreadyFiled scope) AND Clippings/_done/ (recursive: a graduated clip
 * still owns its URL). Matches against each clip's source: / harvest_url_canonical:.
 * Kept separate from alreadyFiled (single responsibility) — a second O(N) scan,
 * fine for the serial low-volume bridge; no premature combined pass (YAGNI).
 */
export function alreadyFiledByUrl(clippingsDir, source) {
  const keys = clipUrlKeys(source);
  if (!keys.statusId && !keys.canon) return null; // no usable URL key (e.g. a note)

  const matches = (val) => matchesUrl(val, keys);
  const fileMatches = (p) => {
    let content;
    try {
      content = readFileSync(p, "utf8");
    } catch (err) {
      if (err.code !== "ENOENT") {
        process.stderr.write(`telegram-clip: WARN could not read ${p} during url-dedup: ${err.code || err.message}\n`);
      }
      return false;
    }
    const fm = frontmatterOf(content);
    return matches(fmValue(fm, "source")) || matches(fmValue(fm, "harvest_url_canonical"));
  };
  // shouldEnter(name, depth) → recurse into this subdir? Lets one walker serve
  // both the depth-capped inbox and the unbounded _done pass.
  const scan = (dir, depth, shouldEnter) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch (e) {
      if (e.code !== "ENOENT") {
        process.stderr.write(`telegram-clip: WARN url-dedup scan could not read ${dir}: ${e.code || e.message} — a duplicate may be written\n`);
      }
      return null;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (!shouldEnter(e.name, depth)) continue;
        const hit = scan(join(dir, e.name), depth + 1, shouldEnter);
        if (hit) return hit;
      } else if (e.isFile() && e.name.endsWith(".md") && e.name !== "_deferred.md") {
        const p = join(dir, e.name);
        if (fileMatches(p)) return p;
      }
    }
    return null;
  };

  // Inbox: depth ≤2, _synthesis + _done excluded (mirrors the alreadyFiled scope).
  const inboxHit = scan(clippingsDir, 1, (name, depth) => depth < 2 && name !== "_synthesis" && name !== "_done");
  if (inboxHit) return inboxHit;
  // _done: recursive — graduated clips live at _done/YYYY-MM/<file>.md.
  return scan(join(clippingsDir, "_done"), 1, (name) => name !== "_synthesis");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { process.stdout.write(USAGE + "\n"); process.exit(0); }

  if (!args.msgId) die(1, `--msg-id required.\n${USAGE}`);
  let text = args.text;
  if (args.textFile != null) {
    try {
      text = readFileSync(args.textFile, "utf8");
    } catch (e) {
      die(e.code === "ENOENT" ? 1 : 2, `--text-file unreadable: ${args.textFile} (${e.code || e.message})`);
    }
  }
  if (text == null || text === "") die(1, `--text or --text-file required (the message body).\n${USAGE}`);

  // Access-gating: delegated to telegram:access; refuse without provenance.
  if (!args.sender) die(2, "refusing to write without --sender (access-gating delegated to telegram:access).");

  const vault = resolveVault(args.vault);
  const clippings = join(vault, "Clippings");

  const { type, source } = classifyMessage({ text });
  const title = deriveTitle({ text, type, source });
  const clip = buildClip({
    sender: args.sender, ts: args.ts || "", msgId: args.msgId, chatId: args.chatId || "",
    text, type, source, today: TODAY,
  });
  const fname = clipFilename({ msgId: args.msgId, title });
  const dest = resolve(clippings, fname);

  // Vault-containment: dest must live inside Clippings/.
  const rel = relative(clippings, dest);
  if (rel.startsWith("..") || resolve(clippings, rel) !== dest) {
    die(2, `path-safety: refusing to write outside Clippings/: ${dest}`);
  }

  if (args.dryRun) {
    process.stdout.write(clip);
    process.stdout.write(`\n--- (dry-run) would write: Clippings/${fname} ---\n`);
    process.exit(0);
  }

  const prior = existsSync(clippings) ? alreadyFiled(clippings, args.msgId) : null;
  if (prior) {
    process.stdout.write(`⊘ telegram-clip: skipped (already-filed): telegram_msg_id=${args.msgId} → ${relative(vault, prior)}\n`);
    process.exit(0);
  }

  // URL/tweet dedup: a DIFFERENT message sharing this URL (or the same tweet via
  // a different X path form) is skipped here, after the msg-id check, before the
  // write. A note (no source) skips this entirely.
  const priorUrl = source && existsSync(clippings) ? alreadyFiledByUrl(clippings, source) : null;
  if (priorUrl) {
    process.stdout.write(`⊘ telegram-clip: skipped (dup-url): ${source} matches ${relative(vault, priorUrl)}\n`);
    process.exit(0);
  }

  try {
    if (!existsSync(clippings)) mkdirSync(clippings, { recursive: true });
    // Exclusive-create (`wx`) closes the dedup→write race: if a concurrent run
    // for the same msg-id (same deterministic dest) wrote first, both can pass
    // alreadyFiled() above, but only one create wins — the loser sees EEXIST and
    // skips instead of clobbering. Serial channel processing rarely triggers it;
    // this makes the no-duplicate guarantee structural rather than timing-based.
    writeFileSync(dest, clip, { encoding: "utf8", flag: "wx" });
  } catch (e) {
    if (e.code === "EEXIST") {
      process.stdout.write(`⊘ telegram-clip: skipped (already-filed, concurrent write): ${relative(vault, dest)}\n`);
      process.exit(0);
    }
    die(2, `failed to write Clippings/${fname}: ${e.code || e.message}`);
  }
  process.stdout.write(`✓ telegram-clip: wrote Clippings/${fname} (type=${type}, source=${source || "none"})\n`);

  // Best-effort inline enrichment (LUNA-58 + fxtwitter body-fill): for an X
  // (tweet) clip, fill `## The Idea` from the tweet text so the clip is born
  // rich instead of a thin stub. NEVER blocks filing — any failure (network,
  // fxt error) is swallowed; the harvest/enrich pipeline stage retries later.
  if (type === "tweet") {
    try {
      const { processClip } = await import("./fxtwitter-enrich.mjs");
      // skipRateLimit: single serial inline call — the 1s politeness sleep
      // only matters for the batch loop. processClip reports its common
      // failures by RETURNING {glyph:"x"|"~"} (it does NOT throw), so surface
      // those in-band so the clip-kept-as-stub case is visible.
      const res = await processClip(dest, vault, false, { skipRateLimit: true });
      if (res && (res.glyph === "x" || res.glyph === "~")) {
        process.stderr.write(`telegram-clip: WARN inline enrich incomplete (clip kept as stub): ${res.message}\n`);
      }
    } catch (e) {
      process.stderr.write(`telegram-clip: WARN inline enrich skipped (clip kept as stub): ${e.message}\n`);
    }
  }
  process.exit(0);
}

// Run as a CLI only — importers (e.g. the clip-lookup equivalence test) reuse
// the exported alreadyFiledByUrl without triggering main().
// import.meta.main is bun-only; fall back to argv[1] basename match for node.
const _argv1 = (process.argv[1] || "").replace(/\\/g, "/");
const _isMain = import.meta.main === true || _argv1.endsWith("telegram-clip.mjs");

if (_isMain) {
  main().catch((e) => {
    process.stderr.write(`telegram-clip: fatal: ${e && e.message ? e.message : e}\n`);
    process.exit(2);
  });
}
