---
name: medic
description: >
  Use inside a Salus medical vault to FILE a medical item into its structured
  place (skin photo → photo archive + capture note; lesion/symptom note; lab/PDF
  → 00-Sources) and auto-commit, OR to QUERY the vault for a health follow-up
  (grounded answer + flagged, non-diagnostic morphology read). Triggers on "file
  this photo / note / lab", "log this into the medical vault", "ask the medic",
  or any health follow-up while cwd = the medical vault. Organize & surface only —
  never diagnose (posture-A).
---

# medic — FILE + QUERY for a Salus medical vault

This vault ORGANIZES and SURFACES medical facts; the operator + clinicians
interpret. **Never diagnose.** Every inferred / morphology statement is flagged
with the `[inferred]` token (the same token `_CLAUDE.md` + `_skin-photo-archive.md`
already use). See `_CLAUDE.md` for the full posture-A floor.

Run this skill with **cwd = the medical vault** so `.claude/hooks/block-cloud-egress.sh`
is in force (no cloud/web/push egress of PHI).

---

## Verb 1 — FILE

Classify the incoming item, route it, then **auto-commit** (local only — never
push; the egress floor blocks it anyway).

### Route A — skin photo
Input: one or more local image paths + an operator caption naming the **region**
(side/flank, chest, back, neck, forearm, hand, thigh, …) and optionally a date.

1. **Date** = today (`YYYY-MM-DD`) unless the caption gives one. This is the
   *filing* date.
2. **Idempotency (do this BEFORE copying):** compute a content hash of the source
   image and compare against every file already in `_media/skin/<date>/`. If any
   existing file has identical bytes, **skip the copy AND skip the row** for that
   image (report "already filed as <name>"). This is required — the `-NN` index
   below always allocates a fresh name, so name-collision alone never dedups.
3. **Copy** to `_media/skin/<date>/<region>-<date>-NN.<ext>` where `NN` is the
   next free 2-digit index for that region+date (`01`, `02`, …). `mkdir -p` the
   dated dir first.
4. **Archive row:** append one row to `_skin-photo-archive.md` matching its
   existing table header exactly:
   `| <date> | <region> | <state> | \`<date>/<file>\` | **<thread>** \`[inferred]\` | <visual note, not a diagnosis> |`
   - `state` ∈ the file's `tag_vocab` (active / active-worst / recovery /
     good-baseline). If unknown, use `active (faint)` and tag `[inferred]`.
   - `thread` ∈ the file's `tag_vocab` (ad-eczema / hs / urticaria / folliculitis
     / acne / pih-mark / uncertain). Pick by morphology; flag `[inferred]`.
   - The visual note is a **morphology observation, not a diagnosis**.
5. **Capture note:** add (or append to) a dated capture note — a short
   `## <date> capture` block in `_skin-photo-archive.md` (or a sibling note) that
   embeds the clearest shot `![[_media/skin/<date>/<file>]]` and summarises what
   the set shows + any operator-reported lesion behavior. Keep it `[inferred]`.
6. **Commit** (see Commit rules).

### Route B — lesion / symptom / behavior note (text)
File as a **dated capture note** in the skin-archive area, `[inferred]`-flagged.
Do **NOT** do in-place structured edits of `_derm-visit-prep-*` (the interview
block) or the circle-test table — those are **deferred** (hand-run for now). If
the operator explicitly asks to update the derm-prep / circle-test, do it by hand
and confirm; otherwise capture-note it and note "fold into derm-prep if wanted".

### Route C — lab / PDF / record
File the extracted content into `00-Sources/<id>.md` (verbatim + provenance per
`_CLAUDE.md`); if it carries structured analyte values, also surface them under
`10-Labs/` keyed by the English analyte code. Cite the source.

### Route D — unknown
Ask the operator what it is (desktop). If unattended, file to a dated inbox
capture note and flag for triage — never guess a clinical route.

### Commit rules (all routes)
- **Selective staging is MANDATORY.** `git status --short` first, then
  `git add -- <only the exact paths you created/changed>`. **NEVER `git add -A`**
  — this vault has multiple concurrent writers (desktop + Telegram); a broad add
  would commit another session's half-done work.
- One commit per FILE action; conventional message, e.g.
  `skin(photo-archive): file <date> <region> capture`.
- **Never push, never add a remote** (the egress floor blocks it; the repo is
  local-only by design).
- Report back: what was filed, where, the commit hash.

---

## Verb 2 — QUERY

Answer a health follow-up **grounded in the vault**.

1. Retrieve: `Grep`/`Read` across the vault; use `qmd` (the vault's own collection)
   and the localhost `obsidian-vault` MCP **when available** (both are allowlisted
   by the egress floor) — but they are optional; file reads are the substrate.
   Good entry points: `STATUS.md` / `_STATUS.md`, `_skin-photo-archive.md`,
   `_derm-visit-prep-*`, `30-Entities/condition-*`, `10-Labs/panel-*`.
2. Answer **grounded** — cite the vault file path(s) the answer rests on.
3. Any morphology read or hypothesis is tagged `[inferred]` and framed
   **for the clinician**. State what would confirm/refute it.
4. **Never assert a diagnosis.** Distinguish "the chart records X" (fact, cite it)
   from "this looks like X" (`[inferred]`, for the clinician). When the data is
   ambiguous, say so and name the discriminating test.
5. Close a morphology answer with a brief "organize & surface, not a diagnosis —
   for your dermatologist/clinician" note.

---

## Guardrails (do not violate)
- No diagnosis, ever — flag every inference `[inferred]`.
- cwd = the medical vault so the egress floor loads; no cloud/web/non-Anthropic egress.
- Selective staging; never `git add -A`; never push.
- Idempotent photo filing (content-hash dedup).
- Deferred (not this skill yet): in-place derm-prep / circle-test table mutation.
