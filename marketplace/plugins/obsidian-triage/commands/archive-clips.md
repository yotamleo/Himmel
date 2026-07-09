---
allowed-tools: Bash, Glob, Grep, Read, Edit, Write
description: Autonomous ARCHIVE pass (Stage 4 of the clipper pipeline). Graduates clips that completed the full chain — harvested_at AND processed:true AND wikilinked from a Clippings/_synthesis/ page — out of the Clippings/ inbox into Clippings/_done/YYYY-MM/, rewriting every path-qualified [[Clippings/…]] inbound link (literal, boundary-safe) so they don't dangle; basename-only [[name]] links resolve by Obsidian and survive untouched. Dedups by canonical URL before moving. (Re)generates Clippings/_deferred.md from the harvest fan-out + tail-skip + safety records. Idempotent. No user prompts.
argument-hint: "[vault-path] [--dry-run] [--limit N]"
---

## Your task

Run an autonomous ARCHIVE pass over the vault's `Clippings/` folder. The **inbox now drains at TRIAGE** (LUNA-84 moves processed clips to `Clippings/_evidence/`); with the 3-state model, graduation to `Clippings/_done/<YYYY-MM>/` is now **optional terminal housekeeping / de-clutter — not the inbox drainer**. A default run graduates **~nothing** after Phase 1: eligible clips have already been moved to `_evidence/` (excluded from archive's scans by LUNA-83), so few top-level stragglers remain. Archive **never reads / never graduates** `Clippings/_evidence/` — the pool is owned by triage and synthesize. Also (re)generate `Clippings/_deferred.md` — the running list of work the pipeline logged but deliberately did not do.

This is **Stage 4** of the clipper pipeline (HARVEST → TRIAGE → SYNTHESIZE → **ARCHIVE**; LUNA-55). Run it AFTER `/synthesize-clips`, because the graduation gate (for any stragglers still at the top-level inbox) depends on synthesis pages existing and wikilinking their evidence clips.

**Deferred Phase-2 opt-in:** when `promoted_to:` is set on a fully-absorbed evidence clip by Phase-2 code, a future `--graduate-absorbed` flag will graduate it from `_evidence/` to `_done/`; that path is not built in Phase 1 (no clip carries `promoted_to:` yet).

Default: process every eligible clip. With `--dry-run`: report the move + link-rewrite + dedup plan and the `_deferred.md` it would write, touch nothing. With `--limit N`: stop after N graduations (calibration runs).

### Concurrency contract (read this BEFORE every run)

NOT safe while Obsidian has the vault open AND the user is editing `Clippings/`, `_synthesis/`, or today's daily note. This command MOVES files and REWRITES wikilinks across many notes — the race window spans the whole vault, not one folder. At the start of every run, print:

```
archive-clips: assumed-safe (Obsidian not editing the vault). This pass MOVES clips and REWRITES links across notes. If Obsidian is open on these files, abort now (Ctrl-C).
```

### `--dry-run` hard gate

If `--dry-run` is passed, set `DRY_RUN=1` for the entire run. **Every phase below that would invoke `Edit` or `Write` (including the file move and the `_deferred.md` write) MUST first check `DRY_RUN`.** When `DRY_RUN=1`, the agent MUST NOT call `Edit`/`Write` and MUST NOT move any file — only `Read`, `Glob`, `Grep`, read-only `Bash`.

If the agent realizes it mutated anything while `DRY_RUN=1`, abort immediately with:
```
archive-clips: DRY-RUN CONTRACT VIOLATION — write/move executed during --dry-run; report this as a bug.
```
Exit non-zero.

### Logging contract

Every per-clip outcome MUST emit exactly one line to stdout BEFORE the final summary:

- Graduated: `✓ <clip-filename.md> — graduated → Clippings/_done/<YYYY-MM>/, {L} inbound links rewritten`
- Skip (not eligible): `⊘ <clip-filename.md> — skipped (not-eligible): <missing — harvested_at | processed | in-synthesis>`
- Skip (dedup): `⊘ <clip-filename.md> — skipped (dedup): canonical URL matches <[[…done clip]] | sibling in batch>; left in inbox for operator`
- Skip (collision): `⊘ <clip-filename.md> — skipped (collision): <dest path> already exists and differs; left in inbox`
- Failed: `✗ <clip-filename.md> — failed (<phase>): <reason>; reverted`

The final summary is two lines:
1. `archive-clips: N graduated, D deduped, S skipped, F failed. (See ✓ / ⊘ / ✗ lines above.)` — `N`/`D`/`S`/`F` MUST equal the count of `✓` / `⊘`(dedup) / `⊘`(other) / `✗` per-clip glyph lines respectively. If they disagree, abort with a clear error.
2. `archive-clips: _deferred.md written with <X> fan-out, <Y> tail-skipped, <Z> safety entries.` — `X`/`Y`/`Z` are the entry counts written into `_deferred.md` in Phase 5 (sourced from external records, NOT from per-clip glyph lines), so this line is NOT cross-checked against the glyphs.

Exit codes:
- 0: all eligible clips graduated or correctly skipped; `_deferred.md` written
- 1: usage / input error (bad vault path, conflicting flags)
- 2: env unusable (vault not found, lock contention)
- 3: refused under headless (HIMMEL-128)
- 4: partial — ≥1 clip failed mid-move and was reverted; re-run to retry
- 5: catastrophic — aborted mid-run; state file written for next run

### Date substitution rule

Wherever `YYYY-MM-DD` or `TODAY` appears, substitute `$(date +%Y-%m-%d)`. Capture once: `TODAY=$(date +%Y-%m-%d)`. The per-clip destination month `<YYYY-MM>` is derived from EACH CLIP's `date_clipped` (NOT today) — see Phase 4.

### G-6 — Pre-flight headless refusal (run FIRST)

```bash
if [ "${CLAUDECODE_HEADLESS:-0}" = "1" ] || [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "cli-print" ]; then
    echo "ERR archive-clips: refusing to run under headless claude (HIMMEL-128 / Max-X5 billing split)." >&2
    exit 3
fi
```

### G-2 — Lockfile

Acquire sentinel lock `<vault>/.archive.lock` (atomic-mkdir, portable across Git Bash — `flock` is not available there):
```bash
lockdir="<vault>/.archive.lock"
if ! mkdir "$lockdir" 2>/dev/null; then
    echo "archive-clips: another archive run is active (or stale lock at $lockdir); wait or remove it." >&2
    exit 2
fi
trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT INT TERM
```
Also coordinate with the harvest stage: if `<vault>/.harvest.lock` exists (a harvest run is active), abort with exit 2 — do not interleave a move pass with a write pass. (Triage has no lockfile to check; the operator is responsible for not running `/triage-clips` and `/archive-clips` concurrently — the concurrency banner above states this.)

### Resolve vault path (cross-platform)

Same logic as `/triage-clips`:
1. If `$1` is a directory, use it. 2. Else `$OBSIDIAN_VAULT_PATH`. 3. Else `~/Documents/luna`. 4. Else exit 1 with `archive-clips: vault path not found; pass as $1 or set OBSIDIAN_VAULT_PATH`.

All `find`/`grep`/`mv` use forward-slash paths; quote every path containing spaces. Verify `<vault>/Clippings/` exists; else exit 0 with `archive-clips: no Clippings/ — nothing to archive`.

### Inbox-folder convention (shared with all pipeline stages)

These names under `Clippings/` are NEVER source clips and MUST be excluded from any clip scan:
- `_synthesis/` — `/synthesize-clips` output (proposal pages).
- `_done/` — this command's archive destination (already-graduated clips).
- `_deferred.md` — this command's deferred-work log.
- `_evidence/` — the reviewed-evidence pool (LUNA-83): `Clippings/_evidence/` and its `_rejected/` subfolder hold clips that have been manually reviewed and promoted; excluded from inbox/eligibility scans. Archive **never reads / never graduates** `Clippings/_evidence/` (belt-and-suspenders: the pool is owned by triage/synthesize). (`/synthesize-clips` intentionally keeps visibility into `_evidence/`.)

The canonical clip scan (used by harvest/triage/archive) is:
```bash
find "<vault>/Clippings" -maxdepth 3 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
  -not -path '*/_evidence/*' -print0
```
(`maxdepth 3` so `_done/<YYYY-MM>/<clip>.md` is reachable when this command itself needs to read the archive for dedup — but the ELIGIBILITY scan in Phase 2 stays at the inbox top level and applies the same exclusions.)

### Phase 1 — Build the synthesis-link index (run ONCE)

Parse every `Clippings/_synthesis/*.md` for wikilinks pointing at clips. A clip is "in a synthesis" if a synthesis page links it.

```bash
# Collect referenced clip identifiers (relative path under Clippings/, no .md).
grep -rhoE '\[\[Clippings/[^]|#]+' "<vault>/Clippings/_synthesis/" 2>/dev/null \
  | sed -E 's/^\[\[Clippings\///' \
  | sort -u > /tmp/archive-synth-refs.txt
```
Each line is a clip identifier RELATIVE to `Clippings/` without extension (e.g. `@karpathy – 2026-05-25T031232+0200` or `2026-05/foo`). Also tolerate basename-only links `[[<name>]]` by indexing each clip's basename as a fallback eligibility key — a synthesis page that links a clip by bare basename still counts as evidence. Note the asymmetry with Phase 4: basename-only links are used for *eligibility* but are NOT rewritten on move, because Obsidian resolves `[[<basename>]]` by the clip's unique timestamped basename regardless of folder, so they keep resolving after the clip lands in `_done/`. Only the path-qualified `[[Clippings/…]]` form breaks on a move and must be rewritten. (This relies on clip basenames being unique — they are, since the Web Clipper templates stamp a timestamp into every filename.) If `_synthesis/` is absent or empty: no clip is eligible → skip straight to Phase 5 (`_deferred.md`) and report `0 graduated`.

### Phase 2 — Scan eligible clips

Enumerate inbox clips (top of `Clippings/`, with the standard exclusions). A clip is **eligible** when ALL hold:
1. Frontmatter has `^harvested_at:[[:space:]]*\S` (Stage 1 done).
2. Frontmatter has `^processed:[[:space:]]*true[[:space:]]*$` (Stage 2 done).
3. Its identifier (relative-path-no-ext) OR its basename is present in `/tmp/archive-synth-refs.txt` (Stage 3 evidence).

Skip + log `⊘ … (not-eligible): <which condition failed>` for any clip missing one. Sort eligible clips by `date_clipped` ascending. Apply `--limit N`.

If zero eligible: still run Phase 5, report `archive-clips: 0 graduated …`.

### Phase 3 — Dedup (before any move)

Build a canonical-URL index of clips ALREADY archived:
```bash
grep -rhoE '^harvest_url_canonical:[[:space:]]*\S.*' "<vault>/Clippings/_done/" 2>/dev/null \
  | sed -E 's/^harvest_url_canonical:[[:space:]]*//; s/^"//; s/"$//' | sort -u > /tmp/archive-done-urls.txt
```
(The `s/^"//; s/"$//` strips surrounding quotes so a quoted `harvest_url_canonical: "https://…"` in one clip still string-matches an unquoted value in another — normalize both the index AND each eligible clip's value the same way before comparing.)

For each eligible clip, read its `harvest_url_canonical:` (normalized as above). Then:
> **Title fallback is opt-out, not default.** If `harvest_url_canonical:` is absent, do NOT silently fall back to `title:` — two genuinely different clips can share a generic title (e.g. a repo/page both titled "GitHub") and would be wrongly deduped (declined graduation, stuck in inbox). Instead, when the canonical URL is missing, treat the clip as **not a dedup candidate** (graduate it normally) and note it in `_deferred.md` § Duplicates as "unverifiable-dedup: no canonical URL". Dedup acts ONLY on an exact canonical-URL match.
- **Already archived:** canonical URL ∈ `/tmp/archive-done-urls.txt` → it is a duplicate of an already-graduated clip. Do NOT move (avoid two copies). Log `⊘ … (dedup): canonical URL matches [[Clippings/_done/<…>]]; left in inbox for operator`. Record it in `_deferred.md` § Duplicates.
- **Sibling dup in this batch:** two eligible clips share a canonical URL → keep the one with the EARLIER `date_clipped` as canonical (graduate it normally), and dedup-skip the rest with `⊘ … (dedup): canonical URL matches sibling <[[name]]> in batch; left in inbox`.

Dedup NEVER deletes a clip. It only declines to move duplicates, surfacing them for operator review.

### Phase 4 — Graduate (move + link-rewrite, atomic per clip)

For each non-deduped eligible clip, in order. The sequence is atomic — on ANY failure, restore the clip to its inbox path and undo partial link edits, then log `✗ … failed (<phase>): …; reverted`.

1. **Compute destination.** `<YYYY-MM>` = first 7 chars of the clip's `date_clipped` (fallback: `harvested_at`; final fallback: `$TODAY`'s month). Dest = `<vault>/Clippings/_done/<YYYY-MM>/<basename>`. `mkdir -p` the month dir.
2. **Collision check.** If dest exists: compare content. Identical → treat as already-graduated (skip, log dedup). Differs → `⊘ … (collision): <dest> exists and differs; left in inbox`, skip.
3. **Enumerate inbound link forms (BEFORE moving).** The old identifier `<OLD>` is the clip's current path relative to `Clippings/` without `.md` (e.g. `@karpathy – 2026-05-25T031232+0200` or `2026-05/@foo – …`). **Clip identifiers routinely contain regex metacharacters (`+`, `(`, `.`, `?`, spaces) — so ALL matching in steps 3, 5, 6 is LITERAL (fixed-string), NEVER regex.** A regex engine reads the `+` in `…031232+0200` as a quantifier and silently fails to match (or matches the wrong span). There are exactly three inbound forms, distinguished by the boundary character right after `<OLD>`:
   - `[[Clippings/<OLD>]]`  — plain link (this also covers the daily-note backref `(from [[Clippings/<OLD>]])`)
   - `[[Clippings/<OLD>|`   — aliased link (alias text + `]]` tail follow)
   - `[[Clippings/<OLD>#`   — heading link (`#heading` + `]]` tail follow)
   Find the notes containing ANY of the three with **fixed-string** grep (`-F`, never `-E`):
   ```bash
   grep -rlF -e "[[Clippings/<OLD>]]" -e "[[Clippings/<OLD>|" -e "[[Clippings/<OLD>#" "<vault>" --include='*.md' 2>/dev/null
   ```
   Listing the three explicit boundary forms is what stops a `<OLD>=foo` move from touching `[[Clippings/foobar]]` — `foobar` matches none of them. Count total occurrences as `{L}`.
   **Basename-only links** `[[<OLD-basename>]]` (WITHOUT the `Clippings/` prefix) are deliberately NOT in this set and are NOT rewritten — Obsidian resolves them by the clip's (unique, timestamped) basename, so they keep resolving after the move. See the basename note in Phase 1.
   **The clip's OWN body is among the step-3 hits (LUNA-60).** `/triage-clips` Phase 6 appends a `## Promotion candidate` section to every clip it marks `processed: true` (it skips clips of unknown `type:` — those never get the section, but they also never reach this command since they lack `processed: true`). That section's bi-temporal-anchor bullet contains a literal backticked wikilink — `` `derived_from: [[Clippings/<OLD>]]` `` — as example text for a future promoted note (it is NOT a frontmatter field on the clip). The step-3 fixed-string grep matches that `[[Clippings/<OLD>]]` inside the clip's own body, so the clip returns as one of its own inbound hits. This self-ref must be rewritten too — but at the clip's NEW location after the move, NOT its old inbox path (which no longer exists). See step 5.
4. **Move the file** (`mv` via Bash, NEVER delete+recreate): `mv "<vault>/Clippings/<OLD>.md" "<dest>.md"`.
5. **Rewrite inbound links — LITERAL replacement only.** New identifier `<NEW>` = `_done/<YYYY-MM>/<basename>`. In each note from step 3, replace these three EXACT literal strings. Use the `Edit` tool with literal old/new strings, or a fixed-string replace such as bash `${content//"<literal-old>"/"<literal-new>"}`. **Do NOT use `sed`/`sed -E` or any regex tool — clip names break it (see step 3).**
   - `[[Clippings/<OLD>]]`  →  `[[Clippings/<NEW>]]`
   - `[[Clippings/<OLD>|`   →  `[[Clippings/<NEW>|`
   - `[[Clippings/<OLD>#`   →  `[[Clippings/<NEW>#`
   Each replacement preserves whatever `|alias` / `#heading` / `]]` tail followed the boundary, and never touches a prefix-sibling clip.
   **Self-ref remap (LUNA-60).** The clip's OWN file is one of the step-3 notes (its Promotion-candidate bullet's backticked `[[Clippings/<OLD>]]`; see step 3), but step 4 just moved it from `<vault>/Clippings/<OLD>.md` to `<dest>.md`. Apply the SAME three literal replacements to the moved clip at its **new** path `<dest>.md` — the backticked `[[Clippings/<OLD>]]` becomes `[[Clippings/<NEW>]]`, a valid self-link into `_done/`. Do NOT try to edit the clip at its old inbox path (gone). This is why the whole-vault verify in step 6 must see zero `[[Clippings/<OLD>]]` survivors: leaving the moved clip's own body un-remapped is a guaranteed false-positive revert.
6. **Verify (LITERAL, boundary-complete).** Re-scan with the SAME three fixed-string forms:
   ```bash
   grep -rlF -e "[[Clippings/<OLD>]]" -e "[[Clippings/<OLD>|" -e "[[Clippings/<OLD>#" "<vault>" --include='*.md' 2>/dev/null
   ```
   MUST return zero matches. Because step 6 uses the identical three forms as step 5, it cannot report clean while an alias/heading occurrence survives. If any remain, REVERT (move the file back + undo the link edits) and log `✗ … failed (link-rewrite): <N> stale links remained; reverted`.
7. **Record** in the state file (Phase 6).

The moved clip's body is unchanged except its path AND the self-ref remap in step 5 (its backticked `[[Clippings/<OLD>]]` → `[[Clippings/<NEW>]]` rewrite, LUNA-60). Do NOT add any OTHER markers inside it — graduation is recorded by location + the state file.

### Phase 5 — (Re)generate `Clippings/_deferred.md`

Overwrite `<vault>/Clippings/_deferred.md` (single living page; it is excluded from all clip scans). Sources:
- **Fan-out refs (LUNA-14):** union the lines of `<vault>/.harvest-run-fanout-candidates-*.txt` (sort -u; strip malformed entries).
- **Tail-skipped refs:** grep `30-Resources/Tech/*.md` for `Tail-skipped: [1-9]` audit-log rows; list `<repo-slug> — <N> refs beyond --limit`.
- **Safety-flagged:** clips/Tech notes with non-blank `safety_flag:` and their resolution (refused vs operator-allowed).
- **Duplicates:** the dedup-skips recorded in Phase 3.
- **Enricher gaps (HIMMEL-799):** thin clips whose host has no dedicated enricher, flagged `harvest_enricher_gap: <host>` by `/harvest-clips` Phase 4. Roll them up by host (count desc) so the set of enrichers still to build is visible. Exact rendering (matches the harvest tool's `harvest_enricher_gap:` writes; omit the section entirely when zero):
  ```bash
  grep -rhoE '^harvest_enricher_gap:[[:space:]]*\S.*' "<vault>/Clippings" 2>/dev/null \
    | sed -E 's/^harvest_enricher_gap:[[:space:]]*//; s/^"//; s/"$//' \
    | sort | uniq -c | sort -rn \
    | awk 'NF{if(!seen){print "## Enricher gaps"; seen=1} print "- " $2 " — " $1 " clips"}'
  ```

Structure:
```markdown
---
type: pipeline-deferred
generated_at: <TODAY>
generated_by: /archive-clips
---

# Deferred — clipper pipeline backlog

> Auto-generated by `/archive-clips`. Each entry is work the pipeline logged but did not do. Excluded from all clip scans.

## Fan-out refs (LUNA-14 — discovered in READMEs, not crawled)
- [ ] https://github.com/<owner>/<repo>

## Tail-skipped refs (luna-ingest --limit cap)
- [ ] <repo-slug> — <N> refs beyond --limit; re-run `/luna-ingest <url> --limit <higher>`

## Safety-flagged repos
- <repo> — safety_flag=<term>; <refused | operator-allowed YYYY-MM-DD>

## Duplicates (declined graduation — operator review)
- [[Clippings/<dup>]] — canonical URL matches [[Clippings/_done/<…>]]

## Enricher gaps
- <host> — <N> clips
```
Empty sections read `_(none)_`, EXCEPT `## Enricher gaps`, which is omitted entirely when no clip carries `harvest_enricher_gap:` (per the awk guard above). Do NOT invent entries — only what the records contain.

### Phase 6 — State file + tracking

Append one JSON line per graduated/deduped/failed clip to `<vault>/.archive-run-state-$TODAY.jsonl`:
```json
{"clip_path": "Clippings/foo.md", "action": "graduated|dedup|skip|failed", "dest": "Clippings/_done/2026-05/foo.md", "links_rewritten": 7, "ended_at": "<UTC ISO>", "reason": ""}
```
Lock the append (atomic-mkdir, same as G-2). Then append to `<vault>/log.md` (if present):
```
## [$TODAY] archive-clips | N graduated → _done/, D deduped, S skipped, F failed. _deferred.md regenerated.
```

### Update hot.md (HIMMEL-254)

After Phase 6, rewrite `<vault>/hot.md` (the Tier-2 hot cache — see the vault `_CLAUDE.md` "Active Context" section): **overwrite the whole file** (never append; log.md is the history) with refreshed Last Updated / Key Recent Facts / Recent Changes / Active Threads reflecting this run. Keep it under ~500 words; keep frontmatter `type: meta`, `ai-first: true`, and set `updated: $TODAY`. Skip when `DRY_RUN=1` or `hot.md` does not exist.

### Notes for the agent

- This command is autonomous — do NOT ask for confirmation between phases.
- The ONLY destructive op is `mv` (relocate); never `rm` a clip. Reverting a failed graduation means moving the file back + undoing link edits.
- Link-rewrite is the risk surface — always re-verify zero stale `[[Clippings/<OLD>]]` links remain before declaring a clip graduated; revert otherwise.
<!-- headless-claude-ok: documenting the HIMMEL-128 ban; this is a prohibition note, not an invocation -->
- No `claude -p` / `--print` / `--bg` / Anthropic API (HIMMEL-128). This command makes no external calls.
- `_done/` and `_deferred.md` are inbox-scan exclusions in EVERY pipeline stage (harvest/triage/synthesize/archive) — see the Inbox-folder convention above.
