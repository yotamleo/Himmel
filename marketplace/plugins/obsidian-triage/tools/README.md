# obsidian-triage tools/

Batch tooling for the obsidian-triage plugin. Several flavors:

- **Pure-Python harvest** (`harvest-clip-body-batch.py`) — no fetch, marks
  clip-body harvest frontmatter. Pre-LUNA-27. Opt-in `--firecrawl-thin`
  escalation (LUNA-27 / HIMMEL-320): for thin-body **article/web** clips
  (X/github/youtube excluded — owned by cheaper paths), fetches clean
  markdown via firecrawl `/v2/scrape` and writes a `## Harvested content`
  section (`harvest_skill: firecrawl`). Credit-conscious — off by default,
  `--firecrawl-budget N` (default 20) caps scrapes/run, budget-exhausted or
  failed fetches stay retryable partials. Needs `FIRECRAWL_API_KEY` (opt.
  `FIRECRAWL_BASE_URL` for self-hosted). Re-screens fetched text for
  injection. Tests: `tests/test-firecrawl-thin.{sh,py}`.
- **fxtwitter enricher** (`fxtwitter-enrich.mjs`) — **default X path**
  (LUNA-33). Browser-free + auth-free; hits `api.fxtwitter.com`. Handles
  plain tweets, long tweets (`is_note_tweet`), X Articles (Draft.js
  blocks → markdown), and quote-tweet context. Use this for X clips.
- **Instagram embed enricher** (`ig-embed-enrich.mjs`) — **no-login Instagram
  path** (HIMMEL-280). Browser-free + auth-free; fetches the public
  `/embed/captioned/` endpoint. Handles `p`, `reel`/`reels`, and `tv` URLs.
  Extracts author + caption + poster image URL. Login-walled / removed posts
  set `enrichment_status: failed` and are left for the LUNA-27 authenticated
  rung (`playwright-crawl-ig.mjs`, not yet implemented). Use this for
  Instagram clips; escalate to LUNA-27 for failed clips.
- **twitter-cli X escalation** (`twitter-cli-enrich.mjs`) — **authenticated X
  reply/thread rung** (LUNA-27). Consumes clips fxtwitter flagged
  `needs_thread: true`; runs `twitter tweet <id> --json` (public-clis/twitter-cli,
  cookie+HTTP) with **burner** credentials to capture the author self-thread +
  first link-bearing reply that fxtwitter can't see. Burner account ONLY. See
  "twitter-cli X thread/reply escalation" below.
- **Playwright crawlers** (`playwright-*.mjs`) — authenticated batch enrich.
  LUNA-27. `playwright-crawl-youtube.mjs` is the **default YouTube path**.
  `playwright-crawl-x.mjs` is **DEPRECATED** (LUNA-35) and superseded for X
  reply/thread capture by `twitter-cli-enrich.mjs`: X/Google anti-automation
  blocks login on automation-controlled browsers, so a burner session can't be
  captured via Playwright at all.
- **Dedup sweep** (`dedup-sweep.mjs`) — LUNA-37. URL-canonical +
  content-hash dupe detection across a luna-style vault. Mutates
  frontmatter only (G-3 body-identity). See "Dedup sweep" section below.
- **Follow-list scorer** (`follow-list-score.mjs`) — HIMMEL-660. Three-stage
  evidence-first scorer for the X/Twitter follow list
  (`ai-x-follow-list.md`): a pure-code `gather` stage collects verifiable
  evidence per handle, a manual Claude judge pass scores it against a
  pinned charter, and a pure-code `assemble` stage deterministically tiers
  + writes the list. See "Follow-list scorer" section below.

Shared URL canonicalisation lives in `lib/url-canonical.mjs` — single
source of truth consumed by `dedup-sweep.mjs`. Mirrors the per-domain
rules already inlined in `harvest-clip-body-batch.py` (Phase 3) and
`playwright-crawl-x.mjs` (`canonicalXUrl`).

## fxtwitter enricher (default X path)

No auth, no browser. Just bun + a network connection.

```bash
cd marketplace/plugins/obsidian-triage/tools
bun install   # one-time
bun fxtwitter-enrich.mjs --vault ~/Documents/luna --limit 5 --dry-run
# Inspect output. When happy, drop --dry-run:
bun fxtwitter-enrich.mjs --vault ~/Documents/luna
```

### Eligibility (relaxed for pre-triage body-fill — LUNA-58)

An X clip is enriched when it has no `enriched_at:` AND is **either**
`processed: true` **or** has a *thin body* (no real tweet text — the
telegram bare-URL stub case). The original `processed:`-only gate ran enrich
as a post-triage stage; the relaxed gate lets enrich run **between harvest and
triage** so a thin telegram stub is body-filled BEFORE its first triage pass
(tags land on a rich body, no re-triage needed). See the pipeline ordering in
the plugin README.

### What gets touched

For each eligible X clip, the script:

1. Canonicalises the source URL (`twitter.com → x.com`, drops `mobile./www.`).
   The anonymized `x.com/i/status/<id>` form (telegram forwards) resolves on
   fxtwitter just like a `/<user>/status/<id>` URL.
2. Fetches `https://api.fxtwitter.com/<user>/status/<id>` (1s rate-limit).
3. Adds frontmatter:
   ```yaml
   enriched_at: 2026-05-27
   enrichment_source: fxtwitter
   enrichment_status: ok | partial | failed
   tweet_stats: { replies: N, retweets: N, quotes: N, likes: N, views: N }
   tweet_is_note: true|false
   tweet_is_article: true|false
   tweet_has_quote: true|false
   author: ["@<screen_name>"]   # only when the clip had no author (i/status de-anon)
   title: <text excerpt>        # only when the clip title was a telegram bare-URL placeholder
   last_error: <only on partial/failure>
   ```
4. For **X Articles** (Draft.js content): converts blocks → markdown and
   appends as `## Crawled content` body section.
5. For **quote tweets**: appends `## Crawled content` with the quoted
   tweet text + author + url.
6. **Thin plain/note tweets (telegram stubs):** inserts a `## The Idea`
   section built from `tweet.text` (before `## Source`) + de-anonymizes
   `author`/`title`. A non-thin plain tweet (body already has the harvested raw
   text) stays **frontmatter-only**, as before.
7. **Backfill re-triage reset:** when a body-fill happens on a clip that was
   ALREADY `processed: true` (the legacy backlog), the enrich clears
   `processed:`/`triaged_at:` and strips the triage-authored `## Promotion
   candidate` section so the next `/triage-clips` re-tags the now-rich clip
   cleanly. Fires only on the thin→filled transition, at most once per clip.
8. **Injection re-screen (HIMMEL-256):** a body-filled clip's new (untrusted)
   `## The Idea` text is re-screened via `harvest-clip-body-batch.py
   --scan-only`; on a hit the clip gets `harvest_flag: injection-suspect`
   (fail-closed → `screen-error` if the screener can't run). Flag-only.

**Media-only tweets** (no caption text, just photo/video) → `enrichment_status:
partial`, `last_error: media_only`, marker written (no retry — text-less by
nature; the video rung owns them). A *transient* fetch failure writes no marker
and retries next run.

G-3 invariant + YAML parse-validate + revert-on-failure all match the
playwright crawler contract. Re-runs skip clips with `enriched_at:`.

Also runs **inline** at telegram-clip filing time: `telegram-clip.mjs` calls
the enricher (best-effort, swallowed on failure) after writing a tweet clip, so
group links are usually born rich without waiting for the pipeline pass.

### Draft.js → markdown coverage

Block types: `unstyled`, `header-one..six`, `unordered-list-item`,
`ordered-list-item` (with auto-counter), `blockquote`, `code-block`,
`atomic`. Unknown types fall back to plain text.

Inline styles: `BOLD` (`**`), `ITALIC` (`*`), `CODE` (`` ` ``). Other
styles (`UNDERLINE`, `STRIKETHROUGH`) pass through as plain text.

Entities: `LINK` → `[text](url)`. Other entity types pass through as text.

### Known limitations

- **No replies/comments** — fxtwitter doesn't expose them (it returns a reply
  *count* only). When you need the self-thread or the first reply, fxtwitter
  sets `needs_thread: true`; the `twitter-cli-enrich.mjs` rung escalates those.
- **No video/STT/keyframes** — same as playwright path.
- **Rate-limit is 1s per call** — fxtwitter is forgiving but be polite.
  145 clips ≈ 2-3 minutes wall-clock.

### Backfilling `needs_thread` on already-enriched clips (`--reflag`)

`needs_thread` is written during enrichment, and the normal pass is idempotent
on `enriched_at` — so X clips enriched *before* the signal feature existed never
get evaluated. `--reflag` backfills exactly those:

```bash
node fxtwitter-enrich.mjs --vault ~/Documents/luna --reflag --dry-run   # inspect selection
node fxtwitter-enrich.mjs --vault ~/Documents/luna --reflag             # backfill
```

It selects already-enriched X clips lacking `needs_thread`, re-fetches the
tweet, runs the pure `detectThreadSignal`, and writes **only** `needs_thread:
true` when it fires — no body change, no other markers touched (body stays
byte-identical under the no-section G-3 guard). Idempotent: a clip already
flagged is skipped. Run this once after upgrading, then the `twitter-cli-enrich`
escalation picks up the newly-flagged clips.

### When fxtwitter is NOT the right tool

- You need reply threads with conversation context, or the payload the author
  parked in their own first reply ("repo in comment"). fxtwitter flags these
  `needs_thread: true`; run `twitter-cli-enrich.mjs` (below) to capture them.
- You hit a tweet that 404s on fxtwitter but renders in a logged-in
  browser (rare; usually a sus-flagged or age-gated tweet).

## twitter-cli X thread/reply escalation

`twitter-cli-enrich.mjs` is the signal-gated escalation rung for the
reply/thread content fxtwitter can't reach. For each clip fxtwitter marked
`needs_thread: true` (and not already `crawled_at:`), it runs
`twitter tweet <id> --json -n <N>` (the `public-clis/twitter-cli` tool,
`uv tool install twitter-cli`) and folds a `## Crawled content` section
(`### Main tweet` / `### Thread (N segments)` / `### Top reply` / `### Quoted
tweet`) into the body. It maps the CLI's `data[]` — `data[0]` focal,
contiguous same-author entries = self-thread, then the first other-author entry
**preferring one that carries a url** (the parked-repo case) = top reply — and
folds each segment's expanded `urls[]` into the text so a
parked repo link survives. Body-fold honours the same G-3 invariant + YAML
parse-validate as the other enrichers; idempotent via `crawled_at:`. A failed
fetch is a **soft fail** (`crawl_status: failed`) that leaves the fxtwitter
enrichment intact.

### Burner account ONLY — auth via env

twitter-cli reads `TWITTER_AUTH_TOKEN` + `TWITTER_CT0` from the environment.
This rung **refuses to run** unless both are set, because without them
twitter-cli falls back to extracting cookies from a local browser — the wrong
(main) account, and broken on Windows anyway (Chrome App-Bound-Encryption
v127+). Use a **dedicated burner X account** (never the main). The operator
sources the gitignored `.env` (burner tokens) into the shell first; this tool
only reads `process.env` and never the `.env` file.

```bash
# operator sources burner tokens first (NOT committed; .env is gitignored):
set -a; . ./.env; set +a
cd marketplace/plugins/obsidian-triage/tools
node twitter-cli-enrich.mjs --vault ~/Documents/luna --limit 5 --dry-run
# inspect selection, then run for real:
node twitter-cli-enrich.mjs --vault ~/Documents/luna
```

Flags: `--vault <path>` (required), `--limit N` (cap processed clips),
`--replies N` (max replies to fetch, default 20), `--dry-run` (list selection,
no fetch — skips the token guard).

### Burner-token refresh

The burner `auth_token` / `ct0` cookies are long-lived but eventually expire or
rotate. The symptom is `crawl_status: failed` with `last_error: not_authenticated`
(or similar). To refresh: open your burner Chrome profile,
DevTools → Application → Cookies → `x.com`, copy the current `auth_token` and
`ct0` values into `.env`. App-Bound-Encryption means this is a manual copy, not
auto-extraction. Then re-run; failed clips re-attempt because the soft-fail path
leaves `crawled_at:` unset.

## Instagram embed enricher (no-login path)

No auth, no browser. Just bun + a network connection.

```bash
cd marketplace/plugins/obsidian-triage/tools
bun install   # one-time
bun ig-embed-enrich.mjs --vault ~/Documents/luna --limit 5 --dry-run
# Inspect output. When happy, drop --dry-run:
bun ig-embed-enrich.mjs --vault ~/Documents/luna
```

### What gets touched

For each Instagram clip with no `enriched_at:`, the script:

1. Matches `source:` against `instagram.com/(p|reel|reels|tv)/<shortcode>`;
   normalises `reels` → `reel` in the embed URL.
2. Fetches `https://www.instagram.com/<kind>/<shortcode>/embed/captioned/`
   with a plain `Mozilla/5.0` User-Agent (800ms rate-limit).
3. Parses author (`CaptionUsername`), caption (`Caption` div), and
   optional poster image URL (`EmbeddedMediaImage`).
4. Adds frontmatter:
   ```yaml
   enriched_at: 2026-06-12
   enrichment_source: ig-embed
   enrichment_status: ok | failed
   ig_author: <username>           # only on success
   last_error: <code>              # only on failure
   ```
5. Inserts a `## Crawled content` body section (before `## Source`,
   else before `## Comments`, else appended) containing the author,
   caption text, and poster image URL (if found).

### Failure cases

| `last_error` value  | Meaning                                          |
|---------------------|--------------------------------------------------|
| `embed_no_caption`  | Login-walled, removed, or private post           |
| `http_<N>`          | HTTP error (e.g. `http_404`, `http_429`)         |
| `fetch_error`       | Network/timeout error                            |

Failed clips have **no** `enriched_at:` marker, so they are re-attempted on
the next run. Once available, the LUNA-27 authenticated rung
(`playwright-crawl-ig.mjs`) handles login-walled posts.

G-3 invariant + YAML parse-validate + revert-on-failure all match the
fxtwitter enricher contract. Re-runs skip clips with `enriched_at:`.

### Known limitations

- **No-login only.** Private accounts, login-walled posts, and removed
  posts return `enrichment_status: failed`. Run the LUNA-27 Playwright
  rung (not yet shipped) for those clips.
- **Caption parsing is regex-based.** Instagram's embed HTML is not versioned;
  if the `Caption` / `CaptionUsername` class names change, the extractor
  will start returning `embed_no_caption` on all posts. Check those class
  names if the enricher starts mass-failing.
- **Rate-limit is 800ms per call.** Be polite. 100 clips ≈ 1.5 min wall-clock.
- **Poster URL is a CDN URL with short expiry.** It works as a link at
  write-time but may 403 days later (CDN token expires). The clip body
  records it as a plain link, not an embedded image, intentionally.

## Setup (one-time)

```bash
cd marketplace/plugins/obsidian-triage/tools
bun install
```

Pinned to `playwright@1.58.0`. Bun runtime preferred; `node` (>=20) also works.

`node_modules/` is gitignored ("source files only ship in git"), so a
git-derived copy of this directory (notably the Claude plugin cache
install) never has it done automatically — `ensure-deps.sh` is the
preflight runbooks call instead of assuming this one-time step already
happened (HIMMEL-1135): fast no-op if deps are present, installs them
(without playwright's browser binaries) if not, non-zero + a remediation
message if it can't.

## Auth (per-service, ~quarterly refresh)

X and YouTube both need an interactive login to capture cookies. Run once
per service:

```bash
bun playwright-auth-save.mjs x
# Browser opens. Log in normally. Script auto-detects success + saves state.
bun playwright-auth-save.mjs youtube
```

Storage state lands at `~/.luna/playwright-state/<service>.json`
(gitignored at the home-dir level — never under the repo).

**X cookies expire** every few months. When the crawler starts mass-failing
the tweet-detection selector, re-run `playwright-auth-save.mjs x`. Cron the
refresh quarterly if you want zero-touch.

### Login-detection selectors

| Service  | Primary                                                 | Fallback                  |
|----------|---------------------------------------------------------|---------------------------|
| X        | `[data-testid="SideNav_AccountSwitcher_Button"]`        | `[data-testid="primaryColumn"]` |
| YouTube  | `ytd-topbar-menu-button-renderer #avatar-btn`           | `#avatar-btn`             |

Both vendors change DOM regularly — verify if `auth-save` times out post-login.

## Crawl (calibrate, then batch)

Dry-run first (no writes; prints what would be crawled):

```bash
bun playwright-crawl-x.mjs --vault ~/Documents/luna --limit 5 --dry-run
bun playwright-crawl-youtube.mjs --vault ~/Documents/luna --limit 5 --dry-run
```

When the output looks right, drop `--dry-run`:

```bash
bun playwright-crawl-x.mjs --vault ~/Documents/luna --limit 10
bun playwright-crawl-youtube.mjs --vault ~/Documents/luna
```

### What gets touched

For each matching clip (filter: `harvest_skill: clip-body` + matching source
host + no `crawled_at:`), the crawler appends ONE new `## Crawled content`
section to the body BEFORE `## Source` (or `## Comments`), and adds four
frontmatter markers:

```yaml
crawled_at: <ISO timestamp>
crawl_skill: playwright-x | playwright-youtube
crawl_status: ok | partial | failed
last_error: <short>   # only on partial/failed
```

Body changes are constrained by the G-3 single-section-add invariant —
every existing section (`## The Idea`, `## Why I Saved This`, etc.) is
byte-identical post-crawl. Frontmatter parse-validates as YAML via
`js-yaml`; the crawler reverts to the pre-write baseline on any failure.

Re-runs are idempotent. Clips with `crawled_at:` already set are skipped.

### Rate limiting

Per-clip 3-5s jittered sleep BEFORE each network call. Single browser
context; sequential. No retry on tweet-not-rendered / transcript-unavailable
— marked partial/failed + move on. (Operator can re-run on failed clips
selectively by manually clearing the `crawled_at:` marker.)

### Selector references (subject to vendor DOM churn)

| Target                  | Selector |
|-------------------------|----------|
| Tweet container         | `[data-testid="tweet"]` |
| Tweet body text         | `[data-testid="tweetText"]` |
| Quote-tweet target      | `div[role="link"] [data-testid="tweetText"]` (nested in focal tweet) |
| YouTube title           | `h1.ytd-watch-metadata` |
| YouTube channel         | `ytd-channel-name #text a` |
| YouTube duration        | `.ytp-time-duration` |
| YouTube transcript btn  | `button[aria-label*="transcript" i]` (else: more-actions menu → "Show transcript") |
| Transcript segment      | `ytd-transcript-segment-renderer` |
| Comment threads         | `ytd-comment-thread-renderer` |

If the crawler starts failing on a previously-working clip type, these are
the first knobs to check.

## Known limitations

- **YouTube transcript unavailable** on some videos (no auto-CC, age-gated,
  paid content, music-only). Marked `crawl_status: partial`,
  `last_error: transcript_unavailable`. Metadata + comments still captured.
- **No video download, no STT, no keyframe extraction.** Transcript-only MVP.
  Operator is evaluating better-than-Playwright video-analysis paths
  separately.
- **Tweet thread depth = 5.** Top-5 replies in DOM order. Deeper threads
  truncated. Not configurable in this MVP.
- **Headless-with-headful-fallback for crawl** (LUNA-33 Tier-2). Auth-save is
  headed (must be); crawls default to headless. X gates the React app on
  headless, so on a headless-gate selector-miss (`tweet_not_rendered` / thin
  `main_text_empty`) `playwright-crawl-x.mjs` auto-retries that clip's scrape in
  a headful (real-window) browser — launched lazily, reused, recorded as
  `crawl_skill: playwright-x-headful`. Pass `--headful` to force a real window
  from the start. (`crawl-youtube` stays headless-only — YouTube does not gate.)
- **No proxy / sleep-jitter randomization beyond 3-5s.** Aggressive bursts
  may trip rate limits. Run overnight, not synchronously.

## Future work

- **v2: Obscura swap.** Playwright is the MVP; the operator is evaluating
  Obscura (or similar) as a tighter, harder-to-detect replacement. The
  scripts here are the architectural reference for what the swap must
  preserve (G-3, idempotency, YAML parse-validate, storage-state pattern).
- **Video analysis path.** No STT / keyframe yet — operator researching
  alternatives. When that ships, a sister `playwright-video-*.mjs` (or
  whatever framework wins) will land in this dir.

## Dedup sweep (LUNA-37)

URL-canonical + content-hash dedup detection. Mutates frontmatter only;
body is byte-identical post-write (G-3 invariant + revert-on-failure).

```bash
cd marketplace/plugins/obsidian-triage/tools
bun install   # picks up js-yaml + playwright (one-time)
bun dedup-sweep.mjs --vault ~/Documents/luna --dry-run
# Inspect the cluster report it would write. When happy:
bun dedup-sweep.mjs --vault ~/Documents/luna
```

CLI:

```
bun dedup-sweep.mjs --vault <path> [--phase url|content|all] [--dry-run] [--report-only]
```

### What gets touched

For each cluster of ≥2 clips sharing a canonical URL OR content hash:

- **canonical** clip (oldest by `date_clipped:`, tie-break lex path):
  ```yaml
  re_clipped_by:
    - "[[Clippings/dupe-1]]"
    - "[[Clippings/dupe-2]]"
  ```
- **each dupe** (URL):
  ```yaml
  harvest_dedup_target: "[[Clippings/<canonical>]]"
  harvest_status: dedup
  dedup_detected_at: 2026-05-27
  ```
- **each dupe** (content-hash):
  ```yaml
  content_dedup_target: "[[Clippings/<canonical>]]"
  harvest_status: content_dedup
  dedup_detected_at: 2026-05-27
  ```

### Preserve-on-existing

If a dupe already has `harvest_status: dedup` (or `content_dedup`) with
a `harvest_dedup_target:` set, the sweep **preserves** it — the operator
may have pointed it at a `30-Resources/Tech/` synthesis note (a wave-2
pattern) which is higher-fidelity than clip→clip. The canonical's
`re_clipped_by:` is still backfilled — the reverse-index records the
relationship either way.

### Detection methods

- **URL-canonical**: groups by `canonicalize(harvest_url_canonical || source)`
  using `lib/url-canonical.mjs`. Per-domain rules match the existing
  harvest tooling (x.com / youtube / github / medium / generic).
- **Content-hash**: only over `processed: true` clips NOT already in a
  URL-cluster. Normalises (lowercase, strip whitespace + image-only
  lines + empty wikilinks + scaffold H2 headers + template-italic
  placeholders) then SHA256. Clips whose normalised body is shorter
  than `DEDUP_MIN_CONTENT_BYTES` (default 200) are skipped — too short
  to differentiate, would produce spurious clusters of empty
  scaffold-only clips.

### Cluster report

`<vault>/60-Maps/dedup-clusters-<DATE>.md` lists every cluster with
canonical wikilink + dupe wikilinks + counts summary. Generated when
`--phase all` (default) or `--report-only`. Operator review surface.

## Component scan (LUNA-57)

Deep repo component inventory for `luna-ingest --deep`. gh-API only (no clone)
— bounded read surface. Scans skills / commands / agents / tools / plugin
manifests out of a repo and writes a cross-repo-deduped `30-Resources/Components/`
library plus feeds the Tech-note `## Reusable components` section.

```bash
cd marketplace/plugins/obsidian-triage/tools
bun install
bun component-scan.mjs --repo owner/repo --vault ~/Documents/luna --dry-run --emit json
# Inspect the JSON inventory. When happy, drop --dry-run to write the library:
bun component-scan.mjs --repo owner/repo --vault ~/Documents/luna
```

CLI: `--repo <owner/repo>` (required) `[--vault <path>] [--components-dir <rel>]
[--trust-tier <t>] [--safety-flag <term>] [--max-components <N>] [--emit json|none] [--dry-run]`.

On existing notes it appends to the `seen_in:` frontmatter block AND the
`## Seen in` body list (every other section byte-identical); js-yaml-validates
and reverts on failure; dedups cross-repo via the `seen_in:` block; and enforces
a resolve()-based vault-containment check (rejects `..` traversal in
--components-dir; does not resolve symlinks). Idempotent.

## Follow-list scorer (HIMMEL-660)

Evidence-first scoring pipeline for the X/Twitter follow list
(`<vault>/30-Resources/ai-x-follow-list.md`). Three stages — two pure-code,
one a manual Claude judge pass in between — so the only non-deterministic
step in the whole pipeline is bounded to scoring, never to
evidence-gathering or tiering math.

### Stage 1 — `gather` (pure code)

For each roster handle (resolved from the current `ai-x-follow-list.md`
plus X clips in the vault, `lib/follow-roster.mjs`), fetches/derives
evidence and writes one dossier JSON to
`<vault>/30-Resources/.follow-scores/<handle>.json`: corpus evidence from
vault clips, an account fetch (see "Account-level fetch" below), extracted
+ verified claims (bio/tweet assertions checked against GitHub repos,
course URLs, etc.), and an injection screen (see "Injection screen"
below). A handle with an existing (fresh) dossier on disk is skipped
unless `--refetch`.

```bash
cd marketplace/plugins/obsidian-triage/tools
bun install   # one-time
bun follow-list-score.mjs gather --vault ~/Documents/luna --dry-run
# Inspect the roster it would gather. When happy, drop --dry-run:
bun follow-list-score.mjs gather --vault ~/Documents/luna
# Force a re-fetch of handles that already have a dossier:
bun follow-list-score.mjs gather --vault ~/Documents/luna --refetch
```

### Stage 2 — judge pass (manual, NEVER headless)

```bash
bun follow-list-score.mjs judge-prep --vault ~/Documents/luna
```

`judge-prep` trims every dossier via `trimForJudge` (redacts
injection-suspect accounts, caps sample tweets to 5) and writes the queue
to `<vault>/30-Resources/.follow-scores/_judge-queue.jsonl` — one
`{handle, charter_ref, trimmed_dossier}` line per handle. `charter_ref`
pins the judge charter's path + sha256 so a scoring run is reproducible
against the exact charter text it used.

A judge — an **interactive Claude session, or a dispatched subagent, never
a headless invocation** (no `-p`/`--print`/`--bg` flag — himmel's
invocation-billing rule, `no-headless-claude` pre-commit gate) — reads
`follow-judge-charter.md`
(five 0-5 dimensions: `factual_reliability`, `resources`, `reach`,
`focus_fit`, `substance`; the crypto-neutrality rule that scores
crypto-tagged content on exactly the same axes as anything else; the
grounding rule that weights `verified` claims over `unverified`/
`contradicted` ones) against each queued dossier, and writes
`<vault>/30-Resources/.follow-scores/<handle>.judgment.json` per handle in
the exact output schema the charter specifies (`handle`, `scores`,
`confidence`, `rationale`, `grounding_notes` — no `tier`; tier is derived
deterministically in Stage 3, never assigned by the judge).

### Stage 3 — `assemble` (pure code)

```bash
bun follow-list-score.mjs assemble --vault ~/Documents/luna
```

Reads every `<handle>.judgment.json`, computes `composite` (weighted blend
of the five dimensions) → `adjusted` (scaled by confidence: high=1.0,
med=0.85, low=0.70) → `tier` (1/2/3/`exclude` via fixed thresholds —
`lib/follow-score.mjs` is the single source of truth for this math),
applies `follow-overrides.json` (below), and writes:

- `<vault>/30-Resources/ai-x-follow-list.md` — regenerates ONLY the
  `## Tier N` / `## Excluded` sections; frontmatter and any footer (e.g.
  an operator "why this list exists" blockquote) stay byte-identical.
- `<vault>/30-Resources/ai-x-follow-scores.md` — a full scorecard:
  subscores, confidence, composite/adjusted, verified-vs-other evidence
  counts, and a `low_sample: true` flag when the dossier's
  `roster.clip_count` is 0.

### Account-level fetch (`follow-account-source.json`)

`follow-account-source.json` encodes the Task 0 spike decision
(`spike_result: "A"`) — the account-level fetch source is the fxtwitter
user endpoint (`https://api.fxtwitter.com/<handle>`, fields
`followers`/`description`/`joined`), read at runtime by `gather`. If
`spike_result` were ever `"B"` (no confirmed account-level source),
`fetchAccount` degrades to a corpus-only shape (`followers`/`following`/
`bio`/`created_at` all `null`) and the `reach` judge dimension would have
to be scored from corpus evidence (tweet cadence, sample-tweet content)
alone rather than actual follower counts. This is a **spike-gated**
caveat: reach-scoring quality tracks whichever account source is
currently wired, not a fixed guarantee.

### Overrides (`follow-overrides.json`)

```json
{
  "whitelist": ["cyrilxbt"],
  "exclude": []
}
```

Applied in `assemble` after tiering: `exclude` force-removes a handle
regardless of computed score; `whitelist` guarantees presence — if the
computed tier is `exclude`, the handle is placed at Tier 3 (lowest
visible tier, never promoted higher) with an override note recorded in
both output files. Edit this file directly; there is no CLI flag for it.

### Injection screen (HIMMEL-256)

`gather` screens every untrusted text field a dossier carries
(`account.bio`, `repos.sample_descriptions[]`,
`corpus.sample_tweets[].text`) via the same
`harvest-clip-body-batch.py --scan-only` screener the fxtwitter enricher
uses, setting `dossier.injection_suspect`. **Fail-closed**: if the
scanner can't run at all, the dossier is flagged suspect rather than
trusted (`screen_status: screen_error`). `judge-prep`'s `trimForJudge`
never lets an injection-suspect account's raw bio/repo descriptions reach
the judge prompt — they're replaced with `[withheld: injection-suspect]`
— regardless of what the judge charter says; the redaction happens before
the charter is ever consulted.

### Hermetic test fixtures

`gather`'s external dependencies (`gh`, the fxtwitter account fetch, the
injection screener) are swappable via env vars for hermetic testing —
mirrors `fxtwitter-enrich.mjs`'s `FXT_FIXTURE` pattern: `FOLLOW_GH_FIXTURE`,
`FOLLOW_ACCOUNT_FIXTURE`, `FOLLOW_SCAN_FIXTURE` (each a file path or
inline JSON, keyed by call args / fetch URL). Unset in normal operator
use — real `gh`/fetch/screener run.

## Tests

Smoke tests live one level up:

```bash
bash ../tests/test-playwright-crawl.sh
bash ../tests/test-dedup-sweep.sh   # LUNA-37
bash ../tests/test-component-scan.sh   # LUNA-57
for t in ../tests/test-follow-*.sh; do bash "$t" || exit 1; done   # HIMMEL-660
bash ../tests/test-ensure-deps.sh   # HIMMEL-1135
```

Verifies: scripts pass `node --check`, package.json declares the right
deps, storage-state path is consistent, crawler scripts exit rc=2 with a
clear message when storage state is missing.

The dedup-sweep tests build a 4-clip fixture vault and verify the URL +
content cluster detection, idempotency, --dry-run / --report-only modes,
and the G-3 body-identity invariant.

`test-component-scan.sh` verifies the lib (classifyPath / extractComponent /
componentKey / selectComponentPaths), the `Components/` upsert (create,
cross-repo seen_in dedup, idempotent re-runs, cross-repo risk escalation, and
revert-on-malformed-frontmatter), and the realpath-under-vault path-safety
invariant.

The `test-follow-*.sh` suite (HIMMEL-660) covers the follow-list scorer
end-to-end: `test-follow-roster.sh` (handle normalization + roster
resolution), `test-follow-dossier.sh` (dossier schema + corpus evidence
build), `test-follow-verify.sh` (claim extraction + gh-api resource
verification), `test-follow-screen.sh` (injection screen + judge-view
redaction), `test-follow-list-score-gather.sh` (the `gather` CLI, hermetic
via `FOLLOW_GH_FIXTURE`/`FOLLOW_ACCOUNT_FIXTURE`/`FOLLOW_SCAN_FIXTURE`),
`test-follow-judge-prep.sh` (the `judge-prep` queue + charter pinning),
`test-follow-score.sh` (composite/adjusted/tier math + overrides +
render determinism), and `test-follow-list-score-assemble.sh` (the
`assemble` CLI end-to-end).
