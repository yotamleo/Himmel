#!/usr/bin/env node
/**
 * grow-feed-log.mjs — LUNA-130 grow-tent feed/watering log append tool.
 *
 * Deterministic APPEND half of the grow-feed-log skill (the extract half is
 * the LLM runbook in skills/grow-feed-log/SKILL.md). Appends ONE feed row to
 * the `## Log` table, or ONE product subsection to `## Products`, in
 * `<vault>/20-Areas/Grow/Grow-Feeding-Log.md`. Pure Node, no network, no LLM
 * (HIMMEL-128) — invoke with the Bash tool only, never a headless claude run.
 *
 * Idempotent per `--msg-id`, SCOPED PER MODE: the dedup match is anchored
 * to the tool's own `<!-- tg:<id> <mode> ...` provenance comment, so a
 * product-mode call and a feed-mode call sharing ONE msg-id (the SKILL.md
 * Step 0 flow: file a new product, then its feed row, same message) both
 * write — and free-form note/body text merely CONTAINING a `tg:<id> <mode>`
 * -looking token (accidentally, or via a prompt-injected extraction) can't
 * false-trigger a skip, since `<!--`/`-->` are neutralized in all
 * operator/LLM-authored text before it lands in the file. A product-mode
 * re-run for an already-present `### <product>` heading is ALSO a no-op,
 * independently, even under a fresh msg-id. Product body text additionally
 * has heading-shaped line starts entity-escaped (`## x` → `&#35;# x`), so
 * no body line can terminate the `## Products` block it is inserted into
 * (HIMMEL-1798).
 *
 * Usage:
 *   node grow-feed-log.mjs --mode feed --msg-id <id> --sender <name> \
 *       --date <YYYY-MM-DD> --vessel <text> [--water <text>] \
 *       [--product <name>] [--dose <text>] [--ec <text>] \
 *       [--note-file <path>] [--ts <iso>] [--vault <path>] [--dry-run]
 *
 *   node grow-feed-log.mjs --mode product --msg-id <id> --sender <name> \
 *       --product <name> --body-file <path> [--ts <iso>] [--vault <path>] \
 *       [--dry-run]
 *
 * Exit codes:
 *   0 — appended, or skipped because already-logged / product-exists,
 *       or --dry-run printed the would-be write
 *   1 — bad usage / missing required arg or flag value (--msg-id,
 *       --mode-specific flags, a flag given with no following value, a
 *       flag-shaped token where a value belongs, an explicitly blank value
 *       — `--vault ""` must never fall through to the default vault — a
 *       flag inapplicable to the selected --mode, a malformed --msg-id
 *       (charset [A-Za-z0-9._:-]) or --date (YYYY-MM-DD), an invalid
 *       --product name, an unreadable --note-file/--body-file path)
 *   2 — env unusable (vault missing / not an Obsidian vault, target file
 *       missing, no `## Log` table / `## Products` section, no --sender,
 *       path-safety violation, read/write failure, a concurrent-write race
 *       lost after retrying, a test-only env hook set without
 *       GROW_FEED_LOG_TEST_HOOKS=1)
 *
 * Writes are atomic (temp file + rename beside the target) — a crash or I/O
 * failure mid-write never leaves the operator's hand-kept log truncated.
 *
 * LUNA-130.
 */
import { appendFileSync, existsSync, readFileSync, writeFileSync, statSync, renameSync, unlinkSync, realpathSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { homedir } from "node:os";
import { splitLines, stripCR, frontmatterBounds, hasKey } from "./lib/frontmatter.mjs";

const TODAY = process.env.GROW_FEED_LOG_TODAY || new Date().toISOString().slice(0, 10);
const TARGET_REL = "20-Areas/Grow/Grow-Feeding-Log.md";

function die(code, msg) {
  process.stderr.write(`grow-feed-log: ${msg}\n`);
  process.exit(code);
}

/** Reject a required string flag whose value is blank AFTER trimming — never
 * on raw truthiness. A bare `if (!value)` guard is truthy for a
 * whitespace-only value (`" "`), which then sanitizes down to an empty
 * idempotency key / provenance field / table cell — the same silent
 * data-loss shape as the mode-scoping and boundary-safety dedup bugs fixed
 * earlier in this file. One shared validation point for every required
 * string flag, so a future new flag can't reintroduce this by hand-rolling
 * its own `!value` guard. Returns the trimmed value on success; dies with
 * `code` + `msg` otherwise. */
function requireNonBlank(value, code, msg) {
  const trimmed = String(value ?? "").trim();
  if (trimmed === "") die(code, msg);
  return trimmed;
}

function parseArgs(argv) {
  const a = { dryRun: false, mode: "feed" };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    // A flag with no following token (e.g. a trailing `--vault` at the end
    // of argv) must be a usage error, not a silent fall-through to whatever
    // default the missing value's field happens to have — for `--vault`
    // specifically, silently defaulting means writing to the OPERATOR'S
    // REAL vault instead of the caller-intended one.
    const next = () => {
      const v = argv[++i];
      if (v === undefined) die(1, `${k} requires a value.\n${USAGE}`);
      // A following token that is itself flag-shaped means the value was
      // OMITTED, not that the value happens to start with "--": silently
      // consuming it both masks the missing value AND erases that flag's
      // meaning — `--water --dry-run` would swallow --dry-run and turn a
      // requested dry-run into a REAL vault write. No legitimate value for
      // any flag here starts with "--" (free text arrives via files).
      if (v.startsWith("--")) die(1, `${k} requires a value (got the flag-like token ${v}).\n${USAGE}`);
      return v;
    };
    switch (k) {
      case "-h": case "--help": a.help = true; break;
      case "--dry-run": a.dryRun = true; break;
      case "--vault": a.vault = next(); break;
      case "--mode": a.mode = next(); break;
      case "--msg-id": a.msgId = next(); break;
      case "--sender": a.sender = next(); break;
      case "--ts": a.ts = next(); break;
      case "--date": a.date = next(); break;
      case "--vessel": a.vessel = next(); break;
      case "--water": a.water = next(); break;
      case "--product": a.product = next(); break;
      case "--dose": a.dose = next(); break;
      case "--ec": a.ec = next(); break;
      case "--note-file": a.noteFile = next(); break;
      case "--body-file": a.bodyFile = next(); break;
      default: die(1, `unknown arg: ${k}`);
    }
  }
  return a;
}

const USAGE = `Usage:
  node grow-feed-log.mjs --mode feed --msg-id <id> --sender <name> \\
      --date <YYYY-MM-DD> --vessel <text> [--water <text>] [--product <name>] \\
      [--dose <text>] [--ec <text>] [--note-file <path>] [--ts <iso>] \\
      [--vault <path>] [--dry-run]
  node grow-feed-log.mjs --mode product --msg-id <id> --sender <name> \\
      --product <name> --body-file <path> [--ts <iso>] [--vault <path>] [--dry-run]`;

function resolveVault(arg) {
  // An explicitly-passed --vault must never FALL THROUGH to the default
  // resolution: deciding "was it given?" on RAW truthiness made
  // `--vault ""` (or a whitespace-only value) indistinguishable from an
  // absent --vault — which targets the operator's REAL vault by design.
  // That is the same incident shape the parseArgs trailing-flag guard
  // closed, reachable through a different door: validate the given value
  // AFTER trimming, like every required flag.
  if (arg !== undefined) arg = requireNonBlank(arg, 1, `--vault requires a non-blank value.\n${USAGE}`);
  const candidate = arg || process.env.OBSIDIAN_VAULT_PATH || join(homedir(), "Documents", "luna");
  if (!existsSync(candidate) || !statSync(candidate).isDirectory()) {
    die(2, `vault path not found: ${candidate} (pass --vault or set OBSIDIAN_VAULT_PATH)`);
  }
  if (!existsSync(join(candidate, ".obsidian"))) {
    die(2, `not an Obsidian vault (no .obsidian/): ${candidate}`);
  }
  return resolve(candidate);
}

/** Positive containment proof: true iff `base` is `full` itself or an
 * ancestor of it, established by walking `full`'s parent chain (dirname)
 * until it either REACHES `base` — membership proven — or tops out at a
 * filesystem root — membership disproven. Both arguments must already be
 * absolute paths (resolve()/realpathSync output; the callers below
 * guarantee it).
 *
 * The shape is deliberate. The previous predicate INFERRED containment from
 * the shape of relative(base, full) — "doesn't start with '..', and
 * resolve()s back" — and was bypassed twice: a junctioned directory passed
 * the pure string comparison (CR round 2), and on Windows a cross-drive
 * `full` makes relative() return an ABSOLUTE path (it cannot express a
 * cross-drive traversal), which neither starts with ".." nor changes under
 * resolve(), so both guards passed (CR round 4). A parent-chain walk proves
 * the membership relation directly instead of interpreting an escape-shaped
 * string, so there is no third relative() shape left to misread: a
 * cross-drive `full` walks up to `D:\` and terminates without ever
 * equalling a `C:\...` base. Equality is case-folded on win32 (NTFS is
 * case-insensitive; realpathSync output is canonical-case but resolve()
 * output keeps caller casing). Exported for the unit cases in
 * tests/test-grow-feed-log.sh (Test 22). */
export function isContainedIn(base, full) {
  const fold = (p) => (process.platform === "win32" ? p.toLowerCase() : p);
  const want = fold(base);
  let cur = full;
  for (;;) {
    if (fold(cur) === want) return true;
    const parent = dirname(cur);
    if (parent === cur) return false; // hit a filesystem root without meeting base
    cur = parent;
  }
}

/** Refuse (exit 2) unless `full` is PROVEN inside `base` (isContainedIn).
 * Shared by both the lexical containment check (resolve()d path strings,
 * cheap, runs even when `full` doesn't exist yet) and the real-path
 * re-check below (realpathSync output, resolves through symlinks/junctions,
 * needs both paths to exist). `label` is folded into the error message to
 * distinguish which check failed. */
function assertContained(base, full, label) {
  if (!isContainedIn(base, full)) {
    die(2, `path-safety: refusing to write outside the vault${label ? ` (${label})` : ""}: ${full}`);
  }
}

/** Break any literal `<!--` / `-->` sequence so operator/LLM-authored text
 * can never forge a well-formed HTML comment — in particular our own
 * `tg:<id> <mode>` provenance marker, which the idempotency dedup below
 * anchors to that exact comment form. Entity-escapes rather than stripping,
 * so the text stays legible. */
function neutralizeComments(s) {
  return String(s).replace(/<!--/g, "&lt;!--").replace(/-->/g, "--&gt;");
}

/** Break any heading-shaped line start — a line-initial `#` followed by up
 * to five more `#`s and then whitespace or end-of-line (the ATX heading
 * grammar Obsidian itself renders) — by entity-escaping that FIRST `#` to
 * `&#35;`: the same escape-not-strip posture as neutralizeComments above, so
 * the text stays legible. Applied to product BODY text only, at the same
 * single chokepoint: findProductsBlock/productHeadingExists below decide
 * section membership and product identity from `^## …` / `^### …` line
 * shapes, so a body line reading as a heading could otherwise PREMATURELY
 * TERMINATE the `## Products` block it is inserted into (HIMMEL-1798) —
 * content inside the section ending the section, the third door into the
 * same room as the `relative()` containment and `\b` dedup-boundary bugs,
 * both of which were replaced with proven relations for exactly this
 * reason: membership must not be inferred from an escape-shaped proxy over
 * caller-controlled bytes. After this escape, every line the tool inserts
 * into the section provably starts with a non-`#` byte, so no caller text
 * can form a section terminator or forge a `### <name>` product heading.
 * Table cells never need this: sanitizeCell collapses newlines, and a cell
 * sits mid-line inside a `| … |` row, never at a line start. Idempotent by
 * construction — the escaped line starts with `&`, which no rule here
 * matches again. A `#`-run NOT followed by whitespace (`#5 bolt`,
 * `####### seven` — 7+ is not an ATX heading) is not a heading anywhere and
 * is left byte-identical. Exported for the unit cases in
 * tests/test-grow-feed-log.sh (Test 33). */
export function neutralizeHeadings(s) {
  return String(s).replace(/^#(?=#{0,5}(?:\s|$))/gm, "&#35;");
}

/** Escape `|`, collapse any run of CR/LF into a single space, neutralize
 * comment delimiters, trim. A table cell that skips this is a bug —
 * free-form operator/note text must never be able to break the `## Log`
 * table shape or forge a provenance comment. */
function sanitizeCell(s) {
  if (s == null) return "";
  return neutralizeComments(String(s).replace(/[\r\n]+/g, " ")).replace(/\|/g, "\\|").trim();
}

function crlfOf(lines) {
  return lines.length && lines[0].endsWith("\r") ? "\r" : "";
}

/** Temp-file path for an atomic write of `target`, in the SAME directory
 * (so the final rename is same-filesystem, hence atomic). The suffix is
 * overridable via GROW_FEED_LOG_TMP_SUFFIX for deterministic failure-mode
 * testing; defaults to pid+timestamp so concurrent invocations don't collide. */
function tmpPathFor(target) {
  const suffix = process.env.GROW_FEED_LOG_TMP_SUFFIX || `${process.pid}.${Date.now()}`;
  // The temp path inherits `target`'s PROVEN containment only while the
  // suffix stays inside target's own basename — a suffix smuggling a path
  // separator (or an NTFS alternate-data-stream ':') would relocate the
  // write to a path nothing ever checked. Reject rather than sanitize: a
  // value that needs rewriting is a bug at the caller, test hook or not.
  if (/[\\/:]/.test(suffix)) {
    die(2, `path-safety: GROW_FEED_LOG_TMP_SUFFIX must not contain path separators or ':' (got: ${suffix})`);
  }
  return `${target}.tmp.${suffix}`;
}

/** Atomic replace guarded by the exact snapshot used to derive `content`.
 * The temp file keeps crash safety: `target` is untouched until the final
 * same-filesystem rename. Immediately before that rename, re-read `target`
 * and refuse with code ESTALE if it no longer byte-matches `expectedContent`.
 * The caller then re-reads and rebuilds its additive insert from the current
 * file, so an Obsidian autosave can never be silently overwritten by a stale
 * snapshot. */
function writeAtomic(target, content, expectedContent) {
  const tmp = tmpPathFor(target);
  try {
    writeFileSync(tmp, content, "utf8");

    // Deterministic test hook: append an external edit after this invocation's
    // snapshot/build but before the stale check. The payload comes from a
    // scratch fixture file; real invocations leave the env var unset.
    const concurrentAppendFile = process.env.GROW_FEED_LOG_BEFORE_RENAME_APPEND_FILE;
    if (concurrentAppendFile) {
      appendFileSync(target, readFileSync(concurrentAppendFile, "utf8"), "utf8");
      delete process.env.GROW_FEED_LOG_BEFORE_RENAME_APPEND_FILE;
    }

    if (readFileSync(target, "utf8") !== expectedContent) {
      const e = new Error("target changed since it was read");
      e.code = "ESTALE";
      throw e;
    }
    renameSync(tmp, target);
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* best-effort; original error wins */ }
    throw e;
  }
}

/** Locate the contiguous `| ... |` table immediately under `## Log`. Returns
 * `{tableEnd}` (exclusive index of the first line after the table — blank
 * line or next heading) or null if the heading or a table under it is
 * missing. */
function findLogTable(lines) {
  let headingIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^##\s+Log\s*$/.test(stripCR(lines[i]))) { headingIdx = i; break; }
  }
  if (headingIdx === -1) return null;
  let i = headingIdx + 1;
  while (i < lines.length && stripCR(lines[i]).trim() === "") i++;
  if (i >= lines.length || !stripCR(lines[i]).trim().startsWith("|")) return null;
  while (i < lines.length && stripCR(lines[i]).trim().startsWith("|")) i++;
  return { tableEnd: i };
}

/** Locate the `## Products` block. Returns `{headingIdx, blockEnd}`
 * (blockEnd = exclusive index of the next H2 heading — e.g. `## Notes` —
 * or EOF) or null if `## Products` is absent. */
function findProductsBlock(lines) {
  let headingIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^##\s+Products\s*$/.test(stripCR(lines[i]))) { headingIdx = i; break; }
  }
  if (headingIdx === -1) return null;
  let i = headingIdx + 1;
  while (i < lines.length && !/^##\s+\S/.test(stripCR(lines[i]))) i++;
  return { headingIdx, blockEnd: i };
}

function escapeRegex(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** True iff a `### <product>` heading already exists — scoped to the
 * `## Products` block only (a `###` elsewhere in the file, e.g. inside a
 * product's own body prose, must never false-positive this check). */
function productHeadingExists(lines, product) {
  const block = findProductsBlock(lines);
  if (!block) return false;
  const re = new RegExp(`^###\\s+${escapeRegex(product)}\\s*$`);
  for (let i = block.headingIdx + 1; i < block.blockEnd; i++) {
    if (re.test(stripCR(lines[i]))) return true;
  }
  return false;
}

/** Normalize + validate a `--product` name for use as BOTH the `### <name>`
 * heading text and the feed row's `[[#<name>]]` wikilink anchor — the same
 * normalized string feeds all three call sites (heading, wikilink,
 * productHeadingExists) so they can never disagree. Rejects rather than
 * silently mangles: a name that would corrupt the `## Log` table cell (`|`),
 * span multiple lines, read as a deeper heading (`#` prefix), forge an HTML
 * comment (`<!--`/`-->` — the same forgery surface the provenance dedup
 * below guards against), or be empty after trimming, is a usage error, not
 * something to auto-fix. Returns `{name}` or `{error}`. */
function normalizeProductName(raw) {
  const name = String(raw ?? "").trim();
  if (name === "") return { error: "must not be empty" };
  if (/[\r\n]/.test(name)) return { error: "must be a single line (no newlines)" };
  if (name.startsWith("#")) return { error: "must not start with '#' (would corrupt the heading level)" };
  if (name.includes("|")) return { error: "must not contain '|' (breaks the ## Log table cell and the wikilink anchor)" };
  if (name.includes("[[") || name.includes("]]")) return { error: "must not contain '[[' or ']]' (breaks the [[#<name>]] wikilink anchor out of its ## Products heading; single brackets are fine)" };
  if (name.includes("<!--") || name.includes("-->")) return { error: "must not contain '<!--' or '-->' (would forge a provenance comment)" };
  return { name };
}

/** Bump the frontmatter `updated:` scalar to TODAY, in place, preserving
 * every other byte. No-op if the file has no frontmatter or no `updated:`
 * key (never invents one — the target file already carries it, but this
 * keeps the tool honest if that ever changes). */
function bumpUpdated(content) {
  const lines = splitLines(content);
  const b = frontmatterBounds(lines);
  if (!b || !hasKey(lines, b.close, "updated")) return content;
  for (let i = 1; i < b.close; i++) {
    if (stripCR(lines[i]).startsWith("updated:")) {
      const crlf = lines[i].endsWith("\r") ? "\r" : "";
      lines[i] = `updated: ${TODAY}${crlf}`;
      break;
    }
  }
  return lines.join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  // Successful/skip status lines end main() with a plain `return` (letting
  // the event loop drain stdout) instead of process.exit(0), which can
  // truncate an async pipe write on Windows and break the runbook's
  // verbatim-status contract. die() keeps process.exit: a truncated error
  // message is survivable, the exit CODE itself never truncates.
  if (args.help) { process.stdout.write(USAGE + "\n"); return; }

  // Test-only env hooks are honored ONLY under an explicit
  // GROW_FEED_LOG_TEST_HOOKS=1 gate. This tool runs from a Telegram-
  // dispatched session: a stray hook variable inherited from a test shell
  // could otherwise append foreign content to a REAL vault write
  // (BEFORE_RENAME_APPEND_FILE), clobber it (SIMULATE_LOST_WRITE), or skew
  // it (TODAY, TMP_SUFFIX). Refuse loudly rather than silently ignoring —
  // silently reinterpreting live instrumentation is exactly the failure
  // shape this file exists to refuse.
  if (process.env.GROW_FEED_LOG_TEST_HOOKS !== "1") {
    const stray = ["GROW_FEED_LOG_TODAY", "GROW_FEED_LOG_TMP_SUFFIX", "GROW_FEED_LOG_SIMULATE_LOST_WRITE", "GROW_FEED_LOG_BEFORE_RENAME_APPEND_FILE"]
      .filter((k) => process.env[k] !== undefined);
    if (stray.length) {
      die(2, `test-only env hooks set without GROW_FEED_LOG_TEST_HOOKS=1: ${stray.join(", ")} — refusing a real write with test instrumentation active.`);
    }
  }

  args.msgId = requireNonBlank(args.msgId, 1, `--msg-id required.\n${USAGE}`);
  // The msg-id is the DEDUP KEY: it is compared against the id field of
  // provenance markers already on file, and that field is delimited by
  // whitespace. A key that could itself contain the delimiter (or any
  // character sanitizeCell would rewrite) makes the field boundary
  // ambiguous — CR round 5: `--msg-id "1 feed"` wrote `tg:1 feed feed`,
  // which a later legitimate `--msg-id 1 --mode feed` matched as its own
  // marker and silently skipped, data loss reported as ⊘ success. The
  // `\s+`/`\b` in the dedup regex were escape-shaped proxies for a field
  // boundary the id itself could contain — the same invariant breach as
  // the round-4 relative() bug. Charset-restrict rather than sanitize: an
  // id that would need rewriting is rejected, so the id on file, the id
  // compared, and the id displayed are all the SAME string, and the
  // space-delimited marker field is unambiguous BY CONSTRUCTION.
  if (!/^[A-Za-z0-9._:-]+$/.test(args.msgId)) {
    die(1, `--msg-id may only contain [A-Za-z0-9._:-] (it is the idempotency key embedded in a whitespace-delimited provenance field; whitespace or markup characters would make that field ambiguous).\n${USAGE}`);
  }
  if (args.mode !== "feed" && args.mode !== "product") die(1, `--mode must be 'feed' or 'product'.\n${USAGE}`);

  // Reject flags that don't apply to the selected mode instead of silently
  // dropping them — a --body-file passed in feed mode is STAGED CONTENT the
  // caller expected to land; ignoring it loses data behind a ✓ (same
  // reject-don't-guess posture as every other guard here). --product is
  // valid in both modes.
  const FEED_ONLY = { "--date": args.date, "--vessel": args.vessel, "--water": args.water, "--dose": args.dose, "--ec": args.ec, "--note-file": args.noteFile };
  const PRODUCT_ONLY = { "--body-file": args.bodyFile };
  const wrongMode = Object.entries(args.mode === "feed" ? PRODUCT_ONLY : FEED_ONLY)
    .filter(([, v]) => v !== undefined).map(([f]) => f);
  if (wrongMode.length) die(1, `not applicable to --mode ${args.mode}: ${wrongMode.join(", ")}.\n${USAGE}`);

  if (args.mode === "feed") {
    args.date = requireNonBlank(args.date, 1, `--date required for --mode feed.\n${USAGE}`);
    // USAGE and SKILL.md advertise YYYY-MM-DD; the value lands in the log
    // table's Date column, so a free-form date corrupts the log's sort/scan
    // semantics silently. Validate the shape, not the calendar.
    if (!/^\d{4}-\d{2}-\d{2}$/.test(args.date)) {
      die(1, `--date must be YYYY-MM-DD (got: ${args.date}).\n${USAGE}`);
    }
    args.vessel = requireNonBlank(args.vessel, 1, `--vessel required for --mode feed.\n${USAGE}`);
  } else {
    args.product = requireNonBlank(args.product, 1, `--product required for --mode product.\n${USAGE}`);
    args.bodyFile = requireNonBlank(args.bodyFile, 1, `--body-file required for --mode product.\n${USAGE}`);
  }

  // --product is used verbatim as BOTH the `### <name>` heading and the
  // `[[#<name>]]` wikilink anchor (feed mode) — normalize+validate ONCE so
  // the two can never disagree. Optional in feed mode, required in product
  // mode (already enforced above). Presence is decided on `!== undefined`,
  // not raw truthiness: an explicitly-passed `--product ""` must be
  // REJECTED (by normalizeProductName's empty check), never silently
  // treated as "no product given".
  let productName;
  if (args.product !== undefined) {
    const norm = normalizeProductName(args.product);
    if (norm.error) die(1, `--product ${norm.error}.\n${USAGE}`);
    productName = norm.name;
  }

  // Access-gating: delegated to telegram:access; refuse without provenance
  // (same posture as telegram-clip.mjs — this is an env-unusable refusal,
  // not a usage error, so it is exit 2 like every other required-flag check
  // here is exit 1).
  args.sender = requireNonBlank(args.sender, 2, "refusing to write without --sender (access-gating delegated to telegram:access).");

  let noteText = "";
  // Same non-fall-through rule as --vault/--product: `--note-file ""` is a
  // usage error, not a silent "no note".
  if (args.mode === "feed" && args.noteFile !== undefined) {
    args.noteFile = requireNonBlank(args.noteFile, 1, `--note-file requires a non-blank value.\n${USAGE}`);
    try {
      noteText = readFileSync(args.noteFile, "utf8");
    } catch (e) {
      die(e.code === "ENOENT" ? 1 : 2, `--note-file unreadable: ${args.noteFile} (${e.code || e.message})`);
    }
  }
  let bodyText = "";
  if (args.mode === "product") {
    try {
      bodyText = readFileSync(args.bodyFile, "utf8");
    } catch (e) {
      die(e.code === "ENOENT" ? 1 : 2, `--body-file unreadable: ${args.bodyFile} (${e.code || e.message})`);
    }
  }

  const vault = resolveVault(args.vault);
  const target = resolve(vault, TARGET_REL);

  // Vault-containment (lexical): target must live inside the vault
  // (defensive — the path is a fixed relative join, but mirrors
  // telegram-clip's discipline). Runs before the existence check below
  // because it's a pure string comparison — no I/O needed yet.
  assertContained(vault, target);
  if (!existsSync(target)) {
    die(2, `target file not found: ${TARGET_REL} (expected at ${target})`);
  }

  // Vault-containment (real path): the lexical check above compares path
  // STRINGS, so a symlink or NTFS junction anywhere under the vault (e.g.
  // `20-Areas` or `20-Areas/Grow` itself pointing outside the vault) would
  // pass it while the actual write lands somewhere else on disk entirely —
  // exactly the boundary this tool advertises refusing to cross.
  // realpathSync resolves through symlinks/junctions to the true filesystem
  // location; both paths are known to exist at this point (the target-exists
  // check above), so re-check containment on the REAL paths too.
  let realVault, realTarget;
  try {
    realVault = realpathSync(vault);
    realTarget = realpathSync(target);
  } catch (e) {
    die(2, `path-safety: could not resolve real path: ${e.code || e.message}`);
  }
  assertContained(realVault, realTarget, "symlink/junction escape");

  // From here on, every filesystem effect (read, temp write, rename,
  // verification re-read) goes through realTarget — the exact value the
  // containment proof above was established ON — never the pre-resolution
  // `target` string. Effecting through `target` would re-resolve any
  // junction at write time, so the proof and the effect could diverge if
  // a junction were swapped in between; using the proven real path removes
  // that re-resolution. (The narrower same-instant TOCTOU that remains is
  // the cross-process-lock territory deliberately deferred as HIMMEL-1770.)
  // The safety line below keeps the vault-shaped `target` spelling — that
  // is the operator-meaningful location, and the proof just established
  // both name the same contained place.

  // Safety line (HIMMEL-130 review hardening — a manual-testing incident
  // showed an unannounced write landing on the operator's REAL vault after a
  // missing --vault value silently fell through to the default resolution;
  // parseArgs now rejects that specific case, but ANY invocation that omits
  // --vault still targets the live vault by design, and an unannounced write
  // is what made that invisible until git caught it). Printed to stderr,
  // unconditionally, before every remaining branch — real write, --dry-run,
  // and a skip (already-logged / product-exists) alike — so the resolved
  // target is always visible before the outcome, not just on success.
  process.stderr.write(`grow-feed-log: target vault=${vault} file=${target}\n`);

  // Provenance carries the mode so dedup below is mode-scoped: the SKILL.md
  // Step 0 flow deliberately reuses ONE --msg-id across a product-mode call
  // then a feed-mode call for the same message, and the second call must
  // NOT see the first's provenance comment as "already logged".
  // args.msgId is charset-validated above ([A-Za-z0-9._:-]) — sanitizeCell
  // would be the identity on it, so it is embedded, compared, and displayed
  // as the SAME raw string.
  const prov = `<!-- tg:${args.msgId} ${args.mode} from:${sanitizeCell(args.sender)} at:${sanitizeCell(args.ts || "")} -->`;
  const msgKeyDisplay = `tg:${args.msgId}`;
  // Boundary-safe AND anchored to the tool's own comment form: a bare
  // `tg:<id> <mode>` token test would (a) let a short id (e.g. "7")
  // false-positive against a longer one already on file ("tg:777"), and
  // (b) match the same token if it merely APPEARED in free-form note/body
  // text — accidentally, or via a prompt-injected extraction deliberately
  // planting one to suppress a future legitimate write. Anchoring to the
  // literal `<!-- tg:<id> <mode>` comment-opener prefix rules out (b)
  // together with sanitizeCell/neutralizeComments below, which break any
  // `<!--`/`-->` a caller's free text could otherwise use to forge this
  // exact form.
  //
  // Field-equality proof (this regex is a comparison, not a heuristic):
  // every marker this tool writes has the shape `<!-- tg:<S> <mode> ...`
  // where S is charset-validated and therefore contains NO whitespace. So
  // after `tg:`, `${escapeRegex(id)}\s` matches iff the STORED field S
  // equals the queried id in full — a shorter query id fails because the
  // next stored char is non-whitespace, a longer one fails outright. The
  // mode is enum-validated (feed|product) and terminated by `(?=\s)` — a
  // true delimiter lookahead, not a `\b` word-boundary heuristic. Both
  // this dedup check and the post-write verification below reuse it, so
  // the same proven comparison gates the skip and confirms the landing.
  const msgKeyRe = new RegExp(`<!--\\s+tg:${escapeRegex(args.msgId)}\\s+${args.mode}(?=\\s)`);

  // Concurrent-write safety covers both race orderings without pretending
  // Obsidian will participate in a lock protocol. Before rename, writeAtomic
  // rejects a stale snapshot; this loop then re-reads and rebuilds the whole
  // additive insert from the current file. After rename, verification catches
  // a writer that lands later and retries from that newer state. Either the
  // exact entry lands on top of all observed content, or the CLI fails loudly
  // without knowingly replacing a newer snapshot.
  const MAX_ATTEMPTS = 2;
  // Test-only hook: for the next N writes, clobber the file back to its
  // pre-write snapshot immediately after writeAtomic (see below) — simulates
  // a concurrent writer's rename winning the race, so the retry and eventual
  // loud-failure paths are exercisable deterministically without real
  // inter-process concurrency. Unset (0) in every real invocation.
  let simulatedLossRemaining = Number(process.env.GROW_FEED_LOG_SIMULATE_LOST_WRITE || 0);

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    let content;
    try {
      content = readFileSync(realTarget, "utf8");
    } catch (e) {
      die(2, `failed to read ${TARGET_REL}: ${e.code || e.message}`);
    }

    if (msgKeyRe.test(content)) {
      process.stdout.write(`⊘ grow-feed-log: skipped (already-logged): ${msgKeyDisplay}\n`);
      return;
    }

    const lines = splitLines(content);

    if (args.mode === "product" && productHeadingExists(lines, productName)) {
      process.stdout.write(`⊘ grow-feed-log: skipped (product-exists): ### ${productName}\n`);
      return;
    }
    if (args.mode === "feed" && productName && !productHeadingExists(lines, productName)) {
      die(2, `product not found in ## Products: ### ${productName} (run --mode product first)`);
    }

    const crlf = crlfOf(lines);
    let insertLines; // lines to splice in (each carries a trailing \r when the file is CRLF)
    let anchorIdx;    // exclusive index to insert before
    let kind;

    if (args.mode === "feed") {
      const table = findLogTable(lines);
      if (!table) die(2, `no ## Log table found in ${TARGET_REL}`);

      let nutrients = sanitizeCell(args.dose || "");
      if (productName) {
        // productName is already validated pipe/newline/comment-free
        // (normalizeProductName above) — used raw so the anchor text is
        // byte-identical to the `### <name>` heading it targets.
        const link = `[[#${productName}]]`;
        nutrients = nutrients ? `${nutrients} ${link}` : link;
      }

      const noteParts = [];
      // Decide on the SANITIZED value, not raw truthiness — a
      // whitespace-only --ec would otherwise pass `if (args.ec)` and leave
      // a dangling "EC " prefix in the notes cell (the same
      // validate-after-normalize class as the required-flag guards above).
      const ecSan = sanitizeCell(args.ec || "");
      if (ecSan) noteParts.push(`EC ${ecSan}`);
      if (noteText.trim()) noteParts.push(sanitizeCell(noteText));
      const notePrefix = noteParts.join(" — ");
      const ecNotes = notePrefix ? `${notePrefix} ${prov}` : prov;

      const row = `| ${sanitizeCell(args.date)} | ${sanitizeCell(args.vessel)} | ${sanitizeCell(args.water || "")} | ${nutrients} | ${ecNotes} |`;
      insertLines = [row + crlf];
      anchorIdx = table.tableEnd;
      kind = "feed row";
    } else {
      const block = findProductsBlock(lines);
      if (!block) die(2, `no ## Products section found in ${TARGET_REL}`);

      const prevBlank = block.blockEnd > 0 && stripCR(lines[block.blockEnd - 1]).trim() === "";
      // Neutralize comment delimiters in the body too (not just table cells)
      // — a body-file is free-form markdown prose, so it isn't run through
      // sanitizeCell (that would collapse its newlines), but it must still
      // be unable to forge a `<!-- tg:... -->`-shaped provenance comment.
      // Heading-shaped line starts are neutralized for the same reason the
      // section itself is load-bearing: this body is inserted INTO
      // `## Products`, whose extent and product headings are decided by
      // `^## …` / `^### …` line shapes — a raw heading line here would
      // terminate the block it lands in (HIMMEL-1798).
      const bodyLines = neutralizeHeadings(neutralizeComments(bodyText).replace(/\r\n/g, "\n")).split("\n");
      while (bodyLines.length && bodyLines[bodyLines.length - 1].trim() === "") bodyLines.pop();

      const section = [];
      if (!prevBlank) section.push("");
      section.push(`### ${productName}`);
      section.push("");
      section.push(prov);
      section.push(...bodyLines);
      section.push("");

      insertLines = section.map((l) => l + crlf);
      anchorIdx = block.blockEnd;
      kind = "product section";
    }

    if (args.dryRun) {
      process.stdout.write(insertLines.map(stripCR).join("\n") + "\n");
      process.stdout.write(`--- (dry-run) would append ${kind} to ${TARGET_REL} ---\n`);
      return;
    }

    const newLines = lines.slice(0, anchorIdx).concat(insertLines, lines.slice(anchorIdx));
    const newContent = bumpUpdated(newLines.join("\n"));

    try {
      writeAtomic(realTarget, newContent, content);
    } catch (e) {
      if (e.code === "ESTALE" && attempt < MAX_ATTEMPTS) continue;
      if (e.code === "ESTALE") {
        die(2, `lost a concurrent-write race: ${TARGET_REL} changed before the atomic replace after ${MAX_ATTEMPTS} attempts — no stale snapshot was written; re-run to retry.`);
      }
      die(2, `failed to write ${TARGET_REL}: ${e.code || e.message}`);
    }

    // Test-only hook (continued): actually clobber the just-written file
    // back to the PRE-write snapshot, so the verification read below
    // genuinely — not just nominally — fails to find our entry. Faking only
    // the boolean result would leave our real row on disk, and a retry's
    // fresh read would then correctly (and unhelpfully, for testing) treat
    // it as already-logged instead of exercising the lost-write path; this
    // clobber reproduces what a losing race actually looks like on disk.
    if (simulatedLossRemaining > 0) {
      simulatedLossRemaining--;
      try { writeFileSync(realTarget, content, "utf8"); } catch { /* best-effort simulation */ }
    }

    // Verify: re-read from disk (not the in-memory newContent) and confirm
    // OUR provenance marker is actually there. A concurrent writer that
    // renamed AFTER us would make this observe content without our entry
    // even though writeAtomic itself reported no error.
    let verifyContent;
    try {
      verifyContent = readFileSync(realTarget, "utf8");
    } catch (e) {
      die(2, `failed to verify write to ${TARGET_REL}: ${e.code || e.message}`);
    }
    const landed = msgKeyRe.test(verifyContent);

    if (landed) {
      // The displayed key IS the raw args.msgId: the charset validation
      // above already rules out control characters / newlines that could
      // inject misleading text into this status line, so display, marker,
      // and comparison all carry the identical string.
      process.stdout.write(`✓ grow-feed-log: appended ${kind} to ${TARGET_REL} (tg:${args.msgId})\n`);
      return;
    }

    if (attempt === MAX_ATTEMPTS) {
      die(2, `lost a concurrent-write race: could not verify the ${kind} landed in ${TARGET_REL} after ${MAX_ATTEMPTS} attempts (another process is likely writing this file concurrently) — re-run to retry.`);
    }
    // else: loop again — re-read the latest state and retry the whole
    // dedup/build/write sequence once.
  }
}

// Run as a CLI only — a future importer could reuse the pure helpers above
// without triggering main().
const _argv1 = (process.argv[1] || "").replace(/\\/g, "/");
const _isMain = import.meta.main === true || _argv1.endsWith("grow-feed-log.mjs");

if (_isMain) {
  main().catch((e) => {
    process.stderr.write(`grow-feed-log: fatal: ${e && e.message ? e.message : e}\n`);
    process.exit(2);
  });
}
