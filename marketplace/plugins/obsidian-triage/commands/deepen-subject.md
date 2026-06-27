---
allowed-tools: Bash, Read, Edit, Skill
description: github source fan-out on promotion (LUNA-89). Fills the `## References` scaffold of a `deepen_pending: true` Tech subject by re-running luna-ingest at a higher `--limit` to crawl the repo's one-hop references (classify integrate / take-parts / inspire / skip). The corresponding `Clippings/_deferred.md` tail-skipped row is already CLAIMED by synthesize-stubs at promotion time; this command does the actual crawl and flips `deepen_pending: false`.
argument-hint: "<subject-path> [--limit N] [vault-path]"
---

## Your task

When `/synthesize-stubs` promotes a github evidence clip to a Tech subject it
writes a `deepen_pending: true` marker, a `## References` scaffold, and **claims**
the matching `Clippings/_deferred.md` tail-skipped row (`- [x] … — promoted →
[[subject]]`). What it does NOT do is the network crawl — that is this command,
kept separate because it makes external `gh`/network calls.

### Why split from synthesize-stubs

`synthesize-stubs.mjs` is a deterministic, offline, hermetically-tested engine.
The one-hop reference crawl is inherently network-bound (luna-ingest hits the
GitHub API). Keeping the crawl here preserves that engine's offline guarantee
and lets the deepen pass be re-run / rate-limited independently.

### Steps

1. **Resolve the subject + repo.** Read `<subject-path>` (a `30-Resources/Tech/`
   note). Confirm `deepen_pending: true`. Take its `source:` (canonical github
   URL). If the marker is absent or already `false`, exit 0 — nothing to deepen.
2. **Crawl one hop at a higher limit.** Invoke the `obsidian-triage:luna-ingest`
   skill on the repo URL with a raised `--limit` (default +N over the original
   cap; `--max-components` likewise) so the refs previously tail-skipped now get
   classified. luna-ingest returns the per-ref verdicts (integrate / take-parts /
   inspire / skip).
3. **Fill `## References`.** Replace the `<!-- deepen: pending … -->` placeholder
   with the classified one-hop refs (one bullet per ref + its verdict). Then set
   `deepen_pending: false` in the subject's frontmatter.
4. **The `_deferred.md` row is already claimed** (by synthesize-stubs at
   promotion). If the crawl surfaced *new* tail-skips beyond the raised limit,
   luna-ingest records them; `/archive-clips` will regenerate `_deferred.md`
   with the residual.

### Reversibility

The deferred-row claim is recorded in the synthesize-stubs generation-ledger
(`deferred-claim`) and is reversible via `synthesize-stubs.mjs --revert`. This
command's edits (filling `## References`, flipping `deepen_pending`) are ordinary
content edits to a subject the operator owns — not auto-reverted.

### Headless refusal (HIMMEL-128)

<!-- headless-claude-ok: prohibition note, not an invocation -->
Drive luna-ingest interactively; never wrap it in a headless `claude -p` call.
