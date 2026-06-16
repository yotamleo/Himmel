---
allowed-tools: Bash, Glob, Grep, Read, Write
description: Cross-clip synthesis pass. Reads processed clips in Clippings/, finds recurring themes (concepts hit 3+ times across unrelated clips, repeated authors, emerging entity clusters), then writes synthesis pages to Clippings/_synthesis/ and proposes vault restructuring (new MOCs, new folders, missing concept pages). Autonomous — no user prompts. Designed to run weekly or after a batch of clips lands.
argument-hint: "[vault-path] [--dry-run] [--since YYYY-MM-DD]"
---

## Your task

Walk the vault's processed clips, find cross-clip patterns, write synthesis pages and folder/MOC proposals. This is the LUNA-3 "gradually understand all information and suggest new layouts" track — the vault thinks for itself based on accumulated clipper input.

### `--dry-run` hard gate

If `--dry-run` is passed, set `DRY_RUN=1`. **Every step below that would invoke `Edit` or `Write` MUST first check `DRY_RUN`.** When `DRY_RUN=1`, the agent MUST NOT call `Edit` or `Write` — only `Read`, `Glob`, `Grep`, read-only `Bash`. If the agent realizes it wrote during dry-run: abort with `synthesize-clips: DRY-RUN CONTRACT VIOLATION` and exit non-zero.

### Logging contract

Every per-pattern outcome MUST emit one line to stdout before the final summary:
- Written: `✓ Clippings/_synthesis/<filename> — <K> evidence clips, proposes <pattern-type> at <target>`
- Skipped (dedup): `⊘ <pattern-slug> — skipped (dedup): existing synthesis page <existing-filename> within 14d window`
- Skipped (confidence floor): `⊘ <pattern-slug> — skipped (confidence-floor): <reason — e.g. only 2 evidence clips, single-source-domain>`
- Skipped (substance floor): `⊘ <pattern-slug> — skipped (substance-floor): <reason — e.g. evidence clips share only 1 theme, recurring-themes extraction empty>`
- Input parse failure: `⊘ <clip-path> — excluded from synthesis (input): <reason>`

Final summary: `synthesize-clips: <N> written, <M> skipped-dedup, <K1> skipped-confidence-floor, <K2> skipped-substance-floor, <J> inputs-excluded. (See ✓ / ⊘ lines above.)`

### Date substitution rule

Wherever `YYYY-MM-DD` appears in instructions below (including YAML examples and filename patterns), substitute the actual output of `date +%Y-%m-%d`. **Do NOT write the literal string `YYYY-MM-DD` into any file.** Capture once at start: `TODAY=$(date +%Y-%m-%d)`.

### Resolve vault path

Same as `/triage-clips`. Look at `$1`, then `$OBSIDIAN_VAULT_PATH`, then `~/Documents/luna` (canonical Luna vault path). Verify `<vault>/Clippings/` exists; exit 0 with `synthesize-clips: no Clippings/ — nothing to synthesize` if not.

### Input validation (run for every candidate clip)

Only consider clips with `processed: true` in frontmatter. Reason: unprocessed clips lack inferred tags and Related Notes, so synthesis would over-fit on raw author wording. Run `/triage-clips` first if needed.

**Inbox-internal exclusions (LUNA-53 + LUNA-55).** When enumerating clips, exclude the three names under `Clippings/` that are NEVER source clips: `_synthesis/` (this command's own output — naturally filtered since proposal pages lack `processed: true`, but exclude by path too so a stray marker can't pull them in), `_done/` (`/archive-clips` archive — those clips already fed synthesis once; re-walking them every run is wasted work and would double-count evidence), and `_deferred.md`. Use:
```bash
find "<vault>/Clippings" -maxdepth 3 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' -print0
```

For each processed clip:
1. Attempt to parse frontmatter as YAML.
2. If parse fails: emit `⊘ <clip-path> — excluded from synthesis (input): frontmatter parse error: <reason>`, exclude from all pattern lenses.
3. If clip lacks `## Promotion candidate` section (required for Pattern 4 input): include in Patterns 1-3 but note exclusion from Pattern 4 in the per-pattern log.

If `--since YYYY-MM-DD` passed, restrict to clips with `triaged_at >= YYYY-MM-DD`. Default: all processed clips.

Final summary MUST report `J = number of input-excluded clips`.

### Slug derivation (deterministic)

Filename pattern is `TODAY-<slug>.md` where `<slug>` is derived as follows. Same pattern + same subject → same slug (for the 14-day dedup window).

- Pattern 1 (concept cluster): `concept-<concept-name>` where `<concept-name>` is the cluster's primary token, lowercased, non-alphanumerics → hyphens, multiple hyphens collapsed. E.g. concept "Attention Residue" → `concept-attention-residue`.
- Pattern 2 (author convergence): `author-<author-name>` same normalization. E.g. "Jane Smith" → `author-jane-smith`.
- Pattern 3 (tag overpopulation): `tag-<tag>-moc`. E.g. tag `focus` → `tag-focus-moc`.
- Pattern 4 (folder pressure): `folder-<folder-path>` with `/` → `-`, lowercased. E.g. `30-Resources/Concepts/` → `folder-30-resources-concepts`.

### Pattern detection — apply all 4 lenses

Each lens looks at the same eligible clip set, independent of the others. Order doesn't matter. (Do NOT issue 4 parallel tool calls — these are conceptual lenses applied serially within the agent's single context.)

**Pattern 1 — Concept clusters.** Find concepts appearing in 3+ unrelated clips (different `source` domains AND different `author:` fields). Judge concept recurrence by whatever signals the clips offer — tags, titles, headings, body prose; the 3+/unrelated floor is the contract, the detection method is yours. Exclude: concepts that already have a dedicated page at `<vault>/30-Resources/Concepts/<Concept>.md` (or `_CLAUDE.md` Folder Map equivalent).

**Pattern 2 — Author / voice convergence.** Find authors appearing in 2+ clips. For each, check if a person note exists at `<vault>/20-Areas/<Author>.md` (or Folder Map equivalent). If no person note: synthesis signal — the author has thought-weight in the vault but no anchor.

**Pattern 3 — Tag overpopulation.** Find tags on 5+ clips with no MOC at `<vault>/60-Maps/<Tag>-MOC.md` (or equivalent). When a tag accumulates this weight, it deserves an index page.

**Pattern 4 — Folder pressure.** Count clips by promotion-candidate target folder (parse the `## Promotion candidate` section's `Suggested target:` line in each clip). If a single folder accumulates 5+ promotion candidates AND that folder doesn't exist yet, propose creating it. Clips missing the Promotion candidate section are reported in the input-exclusion log AND excluded from Pattern 4 (they remain in Patterns 1-3).

### Confidence floor — apply to ALL patterns BEFORE writing (domain sub-rule exempts Pattern 2, HIMMEL-242)

Skip any pattern where:
- Evidence is <3 clips (concepts), <2 clips (authors), <5 clips (tags / folders)
- Evidence clips all share `source:` domain — single-source patterns are noise, not signal (this filter applies to Patterns 1, 3 AND 4 — NOT Pattern 2 (HIMMEL-242): for author convergence the author IS the source and authors are inherently single-platform (an X author's clips always share x.com), so the shared-domain test would skip every tweet author — exactly the thought-weight signal Pattern 2 exists to surface. Pattern 2's noise guards are the 24-hour window below plus its substance gate (≥3 distinct recurring themes))
- Evidence clips all landed within a 24-hour window — could be a single news event, not a recurring theme

If skipped: emit a `⊘` line, do not write.

### Substantive-content gate — apply AFTER confidence floor, BEFORE write

The confidence floor counts clips. The substantive-content gate counts **extractable insight**. Templates that pass the count floor but cannot be filled with concrete content produce boilerplate (`Recurring themes: TODO`, author anchors with empty body, tag MOCs with no per-tag prose). Boilerplate is dead weight at scale — the operator surfaced this in the 2026-05-27 wiki consolidation review (LUNA-43: 8 of 20 synthesis pages were template-only).

Per-pattern minimum extractable substance:

- **Pattern 1 — Concept clusters:** ≥2 distinct quoted insights pulled verbatim from evidence clips (different clips, not 2 quotes from one clip) AND ≥1 sentence of cross-clip synthesis (what the concept means given the union of evidence, not just paraphrase of one source).
- **Pattern 2 — Author convergence:** ≥3 distinct recurring themes extracted from the author's evidence clips (e.g. "argues for X", "consistently cites Y", "frames Z as opposed to W"). "Recurring themes" MUST be filled at generation time — not left as a TODO marker.
- **Pattern 3 — Tag overpopulation:** ≥3 distinct sub-themes within the tag's evidence (e.g. tag `focus` clips clustering as "deep-work scheduling", "context-switching costs", "interruption recovery") OR ≥5 distinct entity links into the broader vault. A flat list of clip links with no thematic grouping does NOT pass — that's a Dataview query, not synthesis.
- **Pattern 4 — Folder pressure:** ≥2 distinct sub-categories within the proposed folder (justifying the folder vs flat list).

If the agent cannot extract the minimum substance after reading the evidence clips: emit `⊘ <pattern-slug> — skipped (substance-floor): <reason — e.g. evidence clips share only 1 theme, recurring-themes extraction empty>` and do not write. Surface as `<K2> skipped-substance-floor` in the final summary line (kept SEPARATE from `<K1> skipped-confidence-floor` so operators can see at a glance whether boilerplate prevention or evidence-thinness is the bottleneck — do not collapse the two counters).

### Idempotency — 14-day dedup window

Before writing each synthesis page:
1. Look in `<vault>/Clippings/_synthesis/` for existing pages with the same `<slug>` (using the deterministic derivation above), regardless of the leading date.
2. If found AND the existing page's date is within the last 14 days: SKIP — emit `⊘` dedup log line, do not write.
3. If found AND the existing page is >14 days old AND new evidence has accumulated (more clips than the old page's evidence list): write a new page with `supersedes: [[Clippings/_synthesis/<old-filename>]]` in frontmatter.
4. If not found: write the new page.

### Output — synthesis page format

For each pattern that passes the floor + dedup, write a synthesis page to `<vault>/Clippings/_synthesis/TODAY-<slug>.md`:

```markdown
---
date: TODAY
type: synthesis
tags:
  - synthesis
  - <pattern-type-tag>
ai-first: true
source: "/synthesize-clips run TODAY"
confidence: medium
---

## For future Claude

{2-3 sentences: what pattern was detected, why it matters, what action is proposed.}

## Evidence (N clips, M unique URLs)

- [[Clippings/<clip-1>]] — {1-line why this clip evidences the pattern}
- [[Clippings/<clip-2>]] — ...
- [[Clippings/<clip-3>]] — ...

> **Counting invariant** (LUNA-43): the `N` in the header MUST equal the number of bullet entries listed below it. Pre-write workflow (not post-write — the `Write` tool emits the whole file in one shot, so the verify step has to come BEFORE the Write call, not after):
>
> 1. Finalise the bullet list of evidence clips in memory first. Do NOT touch the header.
> 2. Set `N = len(finalised_bullet_list)`.
> 3. Set `M = count of distinct canonical-URL values across the finalised bullet list`. The canonical-URL field is the clip frontmatter's LUNA-37-canonicalised URL when present (`canonical_url:`); fall back to the raw `source:` value when not present.
> 4. Only THEN compose the header `Evidence (<N> clips, <M> unique URLs)` from those computed values and emit the whole synthesis page in one Write call.
>
> Never write a count then truncate the list. Never write a list then guess the count. Pages that report `N=16` while listing 8 clips are LUNA-43 bug-fixture cases and must not ship — the bug pattern is "count first, list later" which the steps above forbid by construction.

## Proposed vault change

{Concrete proposal: new file at path X, new folder Y, new MOC, new person note. Include the exact file path and what content should land in it. Do NOT create the proposed file — that's a user decision.}

## Why this is autonomous-safe

This page is a *suggestion*, not a structural change. The vault is unchanged by writing it. The user reads `Clippings/_synthesis/` periodically and decides which proposals to act on. If acted on, the user can move the proposal to `Clippings/_synthesis/_done/` to keep the active list clean.

## Counter-evidence considered

{Honest section: what would make this pattern a false positive? Note any vault evidence that argues against the proposal.}
```

(Substitute `TODAY` everywhere per the Date substitution rule above. Do NOT write the literal `TODAY` token.)

### Tracking

Append to `<vault>/log.md`:
```
## [TODAY] synthesize-clips | <N> synthesis pages written from <K> processed clips
```

### Update hot.md (HIMMEL-254)

After Tracking, rewrite `<vault>/hot.md` (the Tier-2 hot cache — see the vault `_CLAUDE.md` "Active Context" section): **overwrite the whole file** (never append; log.md is the history) with refreshed Last Updated / Key Recent Facts / Recent Changes / Active Threads reflecting this run. Keep it under ~500 words; keep frontmatter `type: meta`, `ai-first: true`, and set `updated: TODAY`. Skip when `DRY_RUN=1` or `hot.md` does not exist.

### Notes for the agent

- The proposals are advisory. The agent never restructures the vault directly via this command — only writes proposal pages to `Clippings/_synthesis/`.
- The whole pipeline (`/triage-clips` then `/synthesize-clips`) is designed to run end-to-end with no user prompts. Recommended cadence: `/triage-clips` after each clipping session (or nightly); `/synthesize-clips` weekly.
- **Skill invocations**: when this runbook references companion skills (`claude-obsidian:wiki-fold` for rollup, `obsidian-second-brain:obsidian-emerge` for pattern emergence on non-clip vault content), invoke them via the `Skill` tool with the literal name as the `skill` argument. Do NOT write `[[skill-name]]` wikilink syntax into any file or treat it as a skill reference — that's vault-link syntax. These skills cover overlapping ground for non-clip vault content and are worth knowing about as cross-references for the user.
