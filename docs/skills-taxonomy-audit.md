# Skills taxonomy audit (HIMMEL-181)

Inventory + classification of every himmel-owned skill and slash command
against the 5-type taxonomy surfaced in the 2026-05-26 wiki synthesis
page `30-Resources/_synthesis/2026-05-26-concept-skills-as-primitive.md`.
Audit-only — no splits proposed for execution in this ticket; per-skill
follow-ups become separate tickets if the audit recommends them.

**Date:** 2026-05-28
**Parent:** LUNA-26 session-4 handover Phase 4d #5
**Scope:** `marketplace/plugins/*/skills/`, `marketplace/plugins/*/commands/`,
`.claude/commands/`. Vendored / external plugins out of scope.

## Taxonomy

| Type | Definition (per concept page) | Practical reading used here |
|---|---|---|
| **Formatter** | Transform input shape | One-shot input → output transformation. Args / draft / spec → file / command / refined text. Pure when output is the only side-effect. |
| **Validator** | Gate on invariants | Pass/fail decision. State mutation only as a side-effect of clearing a gate (e.g. marker files). |
| **Researcher** | Gather + synthesize | Multi-source aggregation, network calls, embedding lookups. Output may be persistent (synthesis pages) but the work is gather-and-synthesize. |
| **Refactorer** | Mutate code in place | Mutate pre-existing state (strict: code; practical: code OR git state OR vault frontmatter). See methodology note below. |
| **Reporter** | Read-only summary | Read state, emit summary. No mutation in the primary path. |
| **Multi-type** | Spans 2+ above | Flag for possible split. |

### Methodology note — strict vs practical Refactorer

The concept page defines Refactorer as "mutate code in place". Read
strictly, almost none of himmel's skills qualify — they mutate git state,
worktree state, handover state, or vault frontmatter, but not source
code. Read this strictly and ~10 units land in Formatter as the
catch-all state-shaper.

The audit below uses a **practical reading**: Refactorer covers
mutation of any pre-existing repo-or-vault state (git, worktree,
frontmatter, marker files). Formatter is reserved for one-shot
shape transformations whose output is the artifact itself (improve
draft → improved draft; args → PR body; halt-marker write where the
marker IS the spec).

The strict/practical split should be revisited if/when the synthesis
page is itself reworked — for now, the practical reading produces a
more useful classification.

## Audit table

22 units total. Type column reflects the practical reading. (Originally 24;
`open-warp` + `oz-offload` removed per HIMMEL-421, 2026-06-19.)

| # | Unit | Type | Notes |
|---|---|---|---|
| 1 | `marketplace/plugins/handover/skills/handover/SKILL.md` | **Multi-type** | Reporter (resume / repos list / status) + Formatter (new-epic / new-task / new-standalone — shape spec into state file) + Refactorer (update-status / end-session — mutate state). The skill is a *command set*, not a single primitive. |
| 2 | `marketplace/plugins/obsidian-triage/skills/luna-ingest/SKILL.md` | Researcher | gh-api fetch + README parse + 1-hop reference following + classification → writes one tech-ref note. Output is the synthesis. |
| 3 | `marketplace/plugins/obsidian-triage/commands/harvest-clips.md` | **Multi-type** | Researcher (dispatches sub-skills for content gathering) + Refactorer (writes `harvested_at:` frontmatter to mark per-clip state). The state-mark is bundled with the work; a pure Researcher would emit the marks separately. |
| 4 | `marketplace/plugins/obsidian-triage/commands/triage-clips.md` | **Multi-type** | Researcher (summarize / infer tags / suggest related / extract actions) + Refactorer (write `processed:true` + frontmatter + append to daily note). Same pattern as harvest-clips. |
| 5 | `marketplace/plugins/obsidian-triage/commands/synthesize-clips.md` | Researcher | Cross-clip pattern detection → writes synthesis pages. The page IS the synthesis output, not a state-mark on inputs. |
| 6 | `.claude/commands/clean.md` | Refactorer | Prune merged-PR worktrees. Repo-state mutation. |
| 7 | `.claude/commands/clean_garden.md` | **Multi-type** | Refactorer (prune) + Formatter (create worktree). Two ops in one command. The split already exists at the script level (`scripts/clean.sh` + `scripts/worktree.sh`); this command is the combined orchestrator. |
| 8 | `.claude/commands/worktree.md` | Formatter | Args → new worktree (filesystem spec materialized). |
| 9 | `.claude/commands/context-hop.md` | **Multi-type** | Reporter (snapshot of context state) + Refactorer (arms relaunch — mutates scheduler state). Internally already two-layered. |
| 10 | `.claude/commands/handover-arm-resume.md` | Formatter | Args → schtasks/at command. |
| 11 | `.claude/commands/handover-commit.md` | Refactorer | Stages + commits .md files. Git state mutation. |
| 12 | `.claude/commands/handover-flush.md` | **Multi-type** | Reporter (default mode: walks branches and reports table) + Refactorer (--cleanup mode: deletes branches). Split already gated by flag, so structural split exists. |
| 13 | `.claude/commands/handover-link.md` | Reporter | Reports mode + path. (`doctor` subcommand has a Validator side: exits non-zero on misconfiguration — minor Multi-type angle, not enough to flag.) |
| 14 | `.claude/commands/handover-pr-merge.md` | Refactorer | Squash-merges PR. |
| 15 | `.claude/commands/handover-pr-open.md` | Formatter | Args + diff → PR body spec. Output is the PR. |
| 16 | `.claude/commands/improve.md` | Formatter | Draft prompt → refined prompt + audit artifact. Pure shape transform. |
| 17 | `.claude/commands/luna-ingest.md` | Researcher | Thin wrapper — type matches the delegate (entry 2). |
| 18 | `.claude/commands/overnight-shift.md` | **Multi-type** | Researcher (Jira pull) + Formatter (plan emit) + Refactorer (subagent fan-out spawns persistent work). Three phases bundled. |
| 19 | `.claude/commands/pr-check.md` | **Multi-type** | Validator (multi-agent CR review) + Refactorer (clears pre-push marker file on clean output). Called out as the canonical example in the HIMMEL-181 brief. |
| 20 | `.claude/commands/quiet-run.md` | Reporter | Runs a command; emits one OK/ERR line + log path. The summary IS the output. |
| 21 | `.claude/commands/skill-find.md` | Researcher | Embedding-indexed lookup over installed skills. Gather-only. |
| 22 | `.claude/commands/stop.md` | Formatter | Args → halt-marker file. The marker IS the spec for the in-flight /overnight-shift to read. |

## Type distribution

| Type | Count | Units |
|---|---|---|
| Formatter | 5 | worktree, handover-arm-resume, handover-pr-open, improve, stop |
| Validator | 0 | (none pure — see pr-check Multi-type) |
| Researcher | 4 | luna-ingest (skill), luna-ingest (cmd wrapper), synthesize-clips, skill-find |
| Refactorer | 3 | clean, handover-commit, handover-pr-merge |
| Reporter | 2 | handover-link, quiet-run |
| **Multi-type** | **8** | handover skill, harvest-clips, triage-clips, clean_garden, context-hop, handover-flush, overnight-shift, pr-check |

8/22 (36%) are Multi-type. The concept page argues pure single-type
skills compose better; this audit confirms the spread is wide enough
that a follow-up sprint to split the highest-friction Multi-type units
is justified.

## Multi-type flags — split recommendations

Ranked by **how much friction the bundling causes** (not by how cleanly
they'd split):

### High-friction split candidates (worth a follow-up ticket)

1. **`pr-check`** (Validator + Refactorer) — The marker-clear side-effect
   couples "what did the reviewers say" with "are we allowed to push".
   A split would be `/pr-review` (Validator-only, prints findings) +
   `/pr-clear-marker` (Refactorer-only, idempotent). Operator already
   sometimes wants the report without the side-effect.

2. **`handover` skill** (Reporter + Formatter + Refactorer command set) —
   The skill bundles ~12 subcommands across all 3 types. Composability
   would improve if it were 3 sibling skills:
   `handover-report` (resume / repos list / status read),
   `handover-create` (new-epic / new-task / new-standalone — Formatter),
   `handover-mutate` (update-status / end-session — Refactorer).
   Risk: the routing logic (CWD match / alias / prompt) is shared and
   would need to live in a fourth shared lib. Higher-risk split.

3. **`overnight-shift`** (Researcher + Formatter + Refactorer) — The
   plan-emit step (Formatter) is currently inlined with the Jira pull
   (Researcher) and the fan-out (Refactorer). A split would be
   `/overnight-plan` (Researcher + Formatter — emit plan only) +
   `/overnight-exec <plan-file>` (Refactorer — execute pre-approved plan).
   This matches the existing "operator must confirm" pause and would
   make the confirmation a hard file-handoff rather than an in-process
   prompt — friendlier to overnight cron resume.

### Lower-friction — split exists or work is small

4. **`harvest-clips`** + **`triage-clips`** — Researcher work bundled
   with per-clip state-mark Refactorer. Splits would emit
   `<clip-path>\t<harvest|triage payload>` records to stdout and a
   separate `/mark-processed <records>` would do the writes. Less
   urgent: the bundling matches the per-clip atomic unit operators
   reason about. Defer until a dry-run / preview workflow specifically
   needs it.

5. **`clean_garden`** — Refactorer + Formatter combined. Split already
   structurally exists (`/clean` + `/worktree`). The combined command
   is for operator convenience. Not a candidate.

6. **`handover-flush`** — Reporter + Refactorer split already gated by
   `--cleanup` flag. Not a candidate.

7. **`context-hop`** — Reporter + Refactorer; the two layers are
   internally distinct already. The combined command is the right UX.
   Not a candidate.

## Recommended follow-ups (file as separate tickets if accepted)

| Priority | Ticket scope | Estimated cost |
|---|---|---|
| 1 (highest) | Split `pr-check` into `/pr-review` + `/pr-clear-marker` | ~1hr (script edit + 2 smoke tests + doc) |
| 2 | Split `overnight-shift` into `/overnight-plan` + `/overnight-exec <plan-file>` | ~2hr (state-handoff file format + plan-resume invariants) |
| 3 | Split `handover` skill into 3 sibling skills (report / create / mutate) | ~4hr (shared routing lib + 3 SKILL.md rewrites + registry semantics) |
| 4 | Add a `Validator` primitive skill — currently 0 pure Validators in himmel; the gate is bundled into pre-commit hooks and `pr-check` | ~2hr (define what Validator-as-skill means in the .claude/commands layer; first candidate = `/check-pre-push` reporting status only) |
| 5 (lowest) | Split `harvest-clips` / `triage-clips` Researcher work from state-mark Refactorer | ~3hr each (preview format design + dry-run alignment) |

## Audit method (so future re-audits stay consistent)

1. Glob `marketplace/plugins/*/skills/*/SKILL.md`, `marketplace/plugins/*/commands/*.md`, `.claude/commands/*.md`.
2. Read each file's frontmatter `description:` + first ~60 lines.
3. Classify against the 5-type taxonomy:
   - One type if the skill's *primary path* fits one definition cleanly.
   - Multi-type if 2+ types fire in the primary path (not just incidental side-effects).
4. For Multi-type, note WHICH types co-occur and whether the bundling
   causes friction (operator wants one without the other).
5. Rank Multi-type splits by friction, not by cleanliness of the split.

Strict-reading caveat: if the synthesis page's "Refactorer = mutate code
in place" is meant strictly, re-do the audit with that lens — most
Refactorer entries here would migrate to Formatter, and the distribution
becomes much more lopsided (Formatter dominates). The practical reading
produces a more useful classification but should be confirmed with the
concept-page author.

## Refs

- `30-Resources/_synthesis/2026-05-26-concept-skills-as-primitive.md` (luna vault — the 5-type taxonomy origin)
- Parent: LUNA-26 session-4 handover Phase 4d #5
- Related: HIMMEL-178 (reviewer prompt verify-before-report — affects pr-review-toolkit agents, which would ideally fall into Validator)
- Related: HIMMEL-164 (slim CLAUDE.md against converging rules — overlap with this audit if any rules surface from the split recommendations)
