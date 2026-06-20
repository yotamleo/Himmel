# obsidian-triage

Autonomous triage + synthesis for Obsidian Web Clipper output.

## What it does

- **`/triage-clips`** — process every unprocessed clip in `<vault>/Clippings/`. Summarize, infer tags from the existing vault tag set, suggest Related Notes via link-graph proximity, extract Action Items to today's daily note (dedup-by-backreference for idempotency under partial failure), annotate a Promotion candidate, mark `processed: true`. Idempotent. No user prompts.
- **`/synthesize-clips`** — find cross-clip patterns (concepts hit 3+ times, repeated authors, tag overpopulation, folder pressure) and write synthesis pages to `<vault>/Clippings/_synthesis/` proposing vault restructuring (new MOCs, new folders, missing person notes). Proposals only — never restructures the vault directly.
- **`/archive-clips`** (Stage 4, LUNA-55) — graduate clips that completed the full chain out of the `Clippings/` inbox. A clip is eligible when `harvested_at:` AND `processed: true` AND it is wikilinked from a `Clippings/_synthesis/` page; eligible clips move to `Clippings/_done/<YYYY-MM>/` with every path-qualified `[[Clippings/…]]` inbound link rewritten (literal, boundary-safe — won't clobber a prefix-sibling, preserves `|alias`/`#heading`) so they don't dangle. Basename-only `[[name]]` links resolve by Obsidian's unique-basename lookup and survive the move untouched. Dedups by `harvest_url_canonical:` before moving (never deletes). Also (re)generates `Clippings/_deferred.md` — the running backlog of fan-out refs, tail-skipped refs, and safety-flagged repos the pipeline logged but did not action. Keeps `Clippings/` an inbox: only active/incomplete clips stay visible.
- **`obsidian-triage:luna-ingest` skill** — chain-following triage for a github OR bitbucket.org repo URL. Fetches metadata + README, follows 1-hop references, classifies each (integrate / take-parts / inspire / skip / api_failure), writes a structured tech-ingest note under `<vault>/30-Resources/Tech/`. Issue URLs (`github.com/<owner>/<repo>/issues/<n>`, HIMMEL-239) take a flat dedicated branch — fetch issue + comments via `gh api`, same safety pre-filter, write `<owner>-<repo>-issue-<n>.md` (github PR/discussion URLs stay out of scope). **Bitbucket Cloud (HIMMEL-329):** the URL host routes the request — `bitbucket.org/<ws>/<repo>` (repo), `/pull-requests/<n>` (PR), and `/issues/<n>` (issue) URLs take the **Bitbucket branch**, dispatching to the himmel `bitbucket` CLI (`scripts/bitbucket/`) instead of `gh`. The bitbucket repo path reuses the github Phase 2/3 ref-following for the **github** refs in its README (BB→BB ref-following + BB has-no-stars/topics trust-tier degradation are documented in the skill); PR/issue paths are flat fetch→write. Invokable as `/luna-ingest <url>` at user prompt (via thin slash-command wrapper) OR `Skill { skill: "obsidian-triage:luna-ingest", args: "<url>" }` from inside another runbook (LUNA-9 skill conversion lifts the runbook out of `.claude/commands/luna-ingest.md` into a HIMMEL-128-compliant Skill-tool-dispatchable form so `/harvest-clips` can call it programmatically without violating the no-headless-claude rule). Two opt-in enrichment flags (off by default, orthogonal): `--deep` (LUNA-57) inventories reusable components from the code into a deduped `30-Resources/Components/` library; `--research` (LUNA-64) web-researches the source repo (maturity, alternatives, gotchas) via Claude's own WebSearch and adds a `## Research enrichment` section. The `/harvest-clips` dispatch passes neither.
- **`obsidian-triage:telegram-clip` skill** (LUNA-58) — pipeline **entry point**: turns a Telegram message (text / bare URL / forward) into a harvest-ready LUNA-2 clip note in `<vault>/Clippings/` (carrying no `harvested_at:`), so `/harvest-clips` ingests it on its next pass. Classifies by the first URL's host (github→`research`, x/twitter→`tweet`, youtube, reddit, other→`article`, no-URL→`note`); preserves sender/ts/message-id provenance; idempotent per message-id. Access-gating is delegated to `telegram:access` (the channel only surfaces allowlisted senders; the tool refuses to write without a sender and never reimplements the allowlist). Invokable as `/telegram-clip <text-or-url>` OR `Skill { skill: "obsidian-triage:telegram-clip", args: "<text>" }` from the interactive telegram channel session. Deterministic logic lives in `tools/telegram-clip.mjs` (pure Node, no runtime deps; the test suite uses the vendored `js-yaml`).

- **`obsidian-triage:roadmap-clips` skill** (LUNA-59) — cross-source synthesis: aggregates actionable items across daily-note action items, the clipper backlog (`Clippings/_deferred.md`), synthesis proposals, promotion candidates, and the component inventory, clusters them into sequenced themes (effort/impact + target repo), dedups candidate tickets against open Jira, and writes a `60-Maps/<date>-roadmap.md` note. **Proposals only** — never auto-files tickets or restructures the vault (same contract as `/synthesize-clips`). Read-only aggregation lives in `tools/roadmap-aggregate.mjs` (pure Node, no runtime deps); invokable as `/roadmap-clips` OR `Skill { skill: "obsidian-triage:roadmap-clips" }`.

Together: harvest → **enrich** (X body-fill via `tools/fxtwitter-enrich.mjs` — see `tools/README.md`) → tag → link → action-item → promote-suggest → mark processed → synthesize patterns → graduate to `_done/` → over time, propose structure → roadmap. `Clippings/` acts as an inbox that drains as clips complete the chain. The vault learns from accumulated clips.

The **enrich** stage runs `fxtwitter-enrich.mjs` (X) and `ig-embed-enrich.mjs` (Instagram) between harvest and triage. For X it fills a thin telegram bare-URL stub's `## The Idea` from the tweet text and de-anonymizes `author`/`title` (the `x.com/i/status/<id>` forwards), so triage tags a rich body on its first pass. The same enrich also fires **inline** at `telegram-clip` filing time (best-effort) so group links are usually born rich. Authenticated long tail (protected tweets, login-walled IG) defers to the `playwright-crawl-*` rung.

**Inbox-internal names** (never source clips; excluded from every stage's scan): `_synthesis/` (synthesize output), `_done/` (archive of graduated clips), `_deferred.md` (archive backlog log).

## Why a plugin

LUNA-2 ships the install pipeline (Web Clipper extension + JSON templates landed in luna PR #11, see `_Templates/Web-Clipper/import/`). Without triage, clips become a bookmark graveyard inside the vault — the exact failure the source article called out. This plugin owns the triage rhythm.

The LUNA-3 brief (tracked in the operator's private handover repo) documents three approach options (A manual / B interactive / C scheduled). This implements **B autonomous** — no per-clip confirmations, but on-demand rather than nightly cron.

## Architecture strategy: statusline-pattern (himmel-as-LOGIC, fork-as-vendor)

This plugin lives in himmel as **independent triage LOGIC**, not embedded in a fork of any upstream skill. Why:

- **LOGIC stays in himmel.** The `/triage-clips` and `/synthesize-clips` runbooks are pure-markdown agent instructions with no dependency on any specific upstream skill. They run against any vault that has a `Clippings/` folder and (optionally) a `_CLAUDE.md` Folder Map.
- **Companion plugins are vendored, not absorbed.** `claude-obsidian` (AgriciDaniel) is tag-pinned in himmel's `marketplace.json` (via the `yotamleo` fork). `obsidian` (kepano) and `obsidian-second-brain` (eugeniughelbur) are NOT declared in himmel's marketplace — they install from their own sources (a bare-SHA himmel pin is not installable and kepano publishes no tags, HIMMEL-435). We read their OUTPUTS (skill invocations, frontmatter conventions) — we don't fork their SOURCE.
- **Forks (when needed) are minimal.** LUNA-4 forked `AgriciDaniel/claude-obsidian` as `yotamleo/claude-obsidian` for attribution (banner-only diff from upstream) — similar to how HIMMEL-122 forks `claude-statusline` purely for CRLF/hooks/.gitattributes guardrails. Triage LOGIC does NOT migrate into the fork; the marketplace pin points at the fork SHA.

Trade-off accepted: a few Luna-flavored fallbacks in the command bodies (folder names like `30-Resources/Concepts/`, `20-Areas/`, `50-Journal/Daily/`). All such paths fall back to `<vault>/_CLAUDE.md` Folder Map for non-Luna vaults. Easy to delete the Luna-specific paragraphs if upstreaming a subset to `eugeniughelbur/obsidian-second-brain` later.

## Install

This plugin ships as part of himmel's marketplace. With the himmel marketplace registered:

```
/plugin install obsidian-triage
```

Companion plugins — read the **Install method** column carefully (different sources have different install paths):

| Plugin | Repo (pinned) | Install method | Why |
|--------|--------------|----------------|-----|
| `obsidian` (kepano) | [kepano/obsidian-skills](https://github.com/kepano/obsidian-skills) — NOT in himmel marketplace | `/plugin install obsidian@obsidian-skills` (kepano's own marketplace) | Provides `obsidian-markdown` skill that `/triage-clips` can use for OFM syntax. **Recommended, not required** — conservative-subset fallback is documented in the command body. *(Not himmel-pinned: a bare-SHA pin isn't installable and kepano publishes no tags, HIMMEL-435.)* |
| `claude-obsidian` (AgriciDaniel, vendored via yotamleo fork) | [yotamleo/claude-obsidian](https://github.com/yotamleo/claude-obsidian) (fork of [AgriciDaniel/claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian)) @ tag `v1.9.2-himmel.1` in himmel marketplace.json | `/plugin install claude-obsidian` from himmel marketplace | `wiki-query` optionally powers richer Phase 4 Related Notes traversal. Optional. *(LUNA-4 vendor fork — attribution + prompt-hook fix; LOGIC stays in himmel.)* |
| `obsidian-second-brain` (eugeniughelbur) | [eugeniughelbur/obsidian-second-brain](https://github.com/eugeniughelbur/obsidian-second-brain) | manual `git clone` to `~/.claude/plugins/` (NOT in himmel marketplace) | Daily notes, kanban, ADRs, vault operating manual. `triage-clips` writes to today's daily note via this skill's conventions. |

## Usage

```bash
# Triage everything unprocessed in Luna's Clippings/
/triage-clips

# Dry-run — report what would change, write nothing (hard contract — phases never write under --dry-run)
/triage-clips --dry-run

# Limit to 5 clips for calibration
/triage-clips --limit 5

# Explicit vault path
/triage-clips ~/Documents/luna

# Cross-clip synthesis weekly
/synthesize-clips --since 2026-05-17

# Both commands accept --dry-run
/synthesize-clips --dry-run
```

## Idempotency

`/triage-clips`:
- Adds `processed: true` + `triaged_at: <today>` to each clip's frontmatter on success. Re-runs skip those clips.
- Phase 5 (action item → daily note) uses **dedup-by-backreference** to guarantee idempotency under partial failure. If a prior run completed Phase 5 but failed before Phase 7, the next run detects the existing `(from [[Clippings/<clip>]])` backref in the daily note and skips re-appending — only writes the missing `processed: true` marker. No duplicate action items.
- To force re-triage of a single clip, delete BOTH `processed: true` AND `triaged_at:` lines manually.

`/synthesize-clips`:
- Deterministic slug derivation (see command body § "Slug derivation") — same pattern + subject → same slug across runs.
- Checks `Clippings/_synthesis/` for existing pages with the same slug within the last 14 days — skips if a proposal stands.
- Old (>14d) proposals get superseded by new ones with `supersedes:` frontmatter linking back.

## Recommended cadence

- After each clipping session OR nightly: `/triage-clips`
- Weekly: `/synthesize-clips --since YYYY-MM-DD` (pass the start-of-week ISO date — script doesn't compute it for you)
- Manual reviewing of `Clippings/_synthesis/` is a once-a-week task. Move accepted proposals to `Clippings/_synthesis/_done/` after acting on them.

## Tests

`tests/test-triage-invariants.sh` validates the scan helper, frontmatter mutation contract, and Phase 7 placement invariants on a portable bash matrix (verified on Git Bash for Windows). Fixture clips live in `tests/fixtures/clips/` — three cover real Web Clipper output shapes (`tags: []` flow-empty, `tags:` block-list with items, and edge-case unicode title).

Run: `bash marketplace/plugins/obsidian-triage/tests/test-triage-invariants.sh`

A `tests/test-synthesize-invariants.sh` covers the synthesize-side invariants (processed-filter, 14-day dedup, confidence-floor single-source rejection for Patterns 1/3/4 + the Pattern 2 domain-floor exemption (HIMMEL-242), deterministic slug derivation).

`tests/test-telegram-clip.sh` (LUNA-58) covers the telegram entry point: URL→type classification, frontmatter shape + provenance, idempotent re-run dedup, `--dry-run` no-write, no-sender refusal, and YAML-validity of the written clip. Requires `bun install` (or `npm install`) in `tools/` first (the YAML-validity check resolves the vendored `js-yaml`).

`tests/test-roadmap-aggregate.sh` (LUNA-59) covers the roadmap aggregator: per-source parsers (daily action items, `_deferred.md` sections, synthesis `## Proposed vault change`, promotion-candidate frontmatter, component inventory), CLI JSON shape + counts, `_done`-exclusion, empty-source graceful, and vault validation. Pure Node — no `bun install` needed.

## Known issues (as of audit cycle 2026-05-25)

Tracked in the operator's private handover repo (LUNA-3 next-session notes). Calibration-on-real-clips will tighten these:

- **Phase 3 tag inference is heuristic.** Conservative ≥80% confidence threshold + "prefer existing vault tags" rule, but real-world false-positive rate unknown until calibration. Tune in command body if needed.
- **Phase 4 Related Notes proximity is grep-based.** Falls back to a comment when `claude-obsidian:wiki-query` skill is unavailable OR vault has >1000 notes. Quality depends on vault link-graph density.
- **Concurrency with Obsidian's auto-save.** Documented at top of `/triage-clips` runbook. There is no cross-platform IPC to detect Obsidian holding a file open — the contract is "don't run while editing Clippings/ or today's daily note in Obsidian." The Phase 7 stale-read guard catches the race after the fact, but the work in Phases 2-6 is wasted if it fires.

## Cross-refs

- Sibling ticket (install pipeline): [LUNA-2](https://yotamleo.atlassian.net/browse/LUNA-2) — done
- This ticket: [LUNA-3](https://yotamleo.atlassian.net/browse/LUNA-3) — in-progress (audit fixes landed; calibration pending)
- Upcoming follow-up: LUNA-4 — fork `claude-obsidian` for vendor/attribution (statusline-pattern; LOGIC stays in himmel)
- Handover: tracked in the operator's private handover repo (LUNA-3)
- Templates landed in luna: `_Templates/Web-Clipper/` + `_Templates/Web-Clipper/import/`
- Reference page: luna `30-Resources/Tech/Obsidian Web Clipper Templates.md`
- Source article (the *why*): Kanika (@KanikaBK) — "fill in Related Notes before closing the clip"

## Pin update workflow

The external `claude-obsidian` plugin is pinned in himmel's `marketplace/.claude-plugin/marketplace.json`. The `ref` MUST be an **immutable tag**, never a bare commit SHA: `claude plugin install` clones the source with `git clone --branch <ref>`, and `--branch` only resolves branch/tag *names* — a 40-hex SHA (even one that is the tip of `main`) fails with `fatal: Remote branch <sha> not found`. A branch name would install but moves, breaking reproducibility. So: **tag, not SHA, not branch.** This keeps the same hygiene posture as `npm-audit-signatures` / `pip-hashes` / `lockfile-integrity` — no moving refs in production marketplace entries — while staying installable.

### Bumping a vendored fork (`claude-obsidian`)

`claude-obsidian` is pinned to the `yotamleo/claude-obsidian` vendor fork (not upstream `AgriciDaniel/claude-obsidian`), carrying a small himmel twist (the unsupported prompt-type SessionStart/PostCompact hooks removed — Claude Code's SessionStart accepts `command`/`mcp_tool` only). To pick up a new upstream release:

1. Sync the fork: merge the new upstream release tag into `yotamleo/claude-obsidian` `main`, reapplying the hook twist + attribution on any `hooks.json`/`README.md` conflict.
2. Tag the synced commit `vX.Y.Z-himmel.N` (upstream base version + himmel patch level — upstream's own `vX.Y.Z` tag lives on a different commit, so the suffix avoids ambiguity) and push the tag.
3. In **one himmel PR**: bump `marketplace.json` `ref` → the new tag, AND bump `synced_base` in [`scripts/plugin-upstreams.json`](../../../scripts/plugin-upstreams.json) → the new upstream `vX.Y.Z`.
4. PR description: one line on what changed upstream and why we're picking it up now.

### Drift detection (track the TRUE upstream)

Because the marketplace `repo` for a fork points at OUR fork, a naive pin-vs-HEAD check would only ever catch fork-vs-pin drift — never the real signal, the original upstream advancing. `scripts/plugin-upstreams.json` declares each fork's true upstream so `scripts/check-plugin-drift.sh` compares the upstream's latest **version tag** (highest semver — not the GitHub Releases API, which would silently miss a tag-only or prerelease version) against `synced_base` and reports BEHIND when upstream ships a newer version. Run `bash scripts/check-plugin-drift.sh` on demand (or on a cadence) to know when a re-sync is due. (kepano's `obsidian` is intentionally NOT in himmel's marketplace — a bare-SHA pin isn't installable and kepano publishes no tags, so it installs from its own marketplace, `obsidian@obsidian-skills`; HIMMEL-435.)

### Fork tag immutability (LUNA-4)

Tags on an operator-controlled fork are not implicitly immutable — to keep a pinned tag reachable and unmovable, branch protection on `yotamleo/claude-obsidian` enforces `allow_force_pushes: false` + `allow_deletions: false` + `enforce_admins: true`. Any future fork-side change goes through PR + a new commit + a new `-himmel.N` tag, never a force-push or a moved tag over a pinned ref.
