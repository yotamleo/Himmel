# ADR: `unslop` skill — AI-tell removal for human-facing prose

**Decision: PILOT-MEASURE** (2026-09-17). Not ADOPT — rubric §1 (goal
articulation) does not pass on evidence, per the operator's own framing below.
Not REJECT either — the operator chose to land it anyway, with adapted rules,
because the blast radius is one file and the cost to try is near zero.

## What

`unslop` (`cursor/plugins` pstack, MIT, (c) 2026 Lauren Tan) is a 33-rule
style-editing skill: it scans prose for AI-generated tells (hedging, filler,
inline-header lists, em dashes, abstract metaphor nouns, over-compression,
and more) and rewrites to remove them. Vendored at
`.claude/skills/unslop/SKILL.md`, pinned to commit
`e8d856f0273b42ebafe0ec3546bd645709e7c1b0`. Full provenance, deviations, and
license pointer are in the skill file's own header — this ADR covers the
decision, not the mechanics.

## Why this shape, not another

A scoped-research leg scored it against
[the tool-adoption rubric](rubric.md):

- **License and self-containment.** MIT, one file, no scripts, no sibling
  dependencies.
- **Injection scan: clean.** 33 numbered style rules, no instruction-override
  phrasing, no fake system/assistant tags, no tool-invocation requests, no
  exfiltration asks.
- **Trust tier: `community-active → validate-before-adopt`.** Layer-A prompt
  content only — no `PreToolUse` hook, no secret, no network surface,
  reversible by deleting one file. Rubric §2's sandbox-test prescription for
  this tier is a throwaway-worktree trial before a tool touches a real
  session; here the injection scan and the pilot's own 3-5-document
  measurement protocol (below) serve that role instead of a separate
  disposable trial, because the tool has no executable surface to sandbox
  beyond the prose rules themselves, and the PILOT-MEASURE status means this
  landing already IS the bounded trial, not a fait accompli.
- **Rubric §1 (goal articulation): does NOT pass on evidence.** There is no
  CR finding, no stuck loop, and no operator complaint about AI-sounding
  prose anywhere in the memory index or the CR ledger. Adopting on "looks
  useful" is the exact drift rubric §1 exists to block.

That last point is why this lands as **PILOT-MEASURE, not ADOPT**: the
problem the skill claims to fix has not been observed as friction here. The
operator's own words on the decision to proceed anyway: *"1 + slighly change
rules as some might be stractually different for us."* — land it as a pilot
with adapted rules, and let the pilot itself produce the evidence rubric §1
asks for, rather than asserting it exists today.

**A correction to the original framing, carried forward from the research
leg:** upstream ships `disable-model-invocation: true`, so the skill is
already lean-invoke in its native environment — fired deliberately via
`/unslop`, never by semantic match. The objection that a prose-shaping skill
is inherently always-on and therefore expensive does not apply to it as
written, and this vendoring keeps that key rather than dropping it (see the
two open questions below).

## Rule adaptations

The upstream rules were written for a different authoring context than
himmel's. Three adaptations, recorded in full (with rule numbers) in the
skill file's own provenance header — summarized here for the decision
record:

1. **Rules 28 and 33** (dense-sentence splitting, over-compression / write
   whole sentences) are scoped to documents written for a human reader — PR
   bodies, ADRs, handovers, tickets — never routine interactive replies. The
   operator runs a Concise output style; a blanket application of
   terseness-fighting rules would fight it directly.
2. **Rule 13 (em-dash ban) is dropped.** himmel's own docs (`docs/voice.md`,
   this repo's ADRs, `CLAUDE.md`) use em dashes as an established
   house-style device. The ban is a house-style call, not a correctness
   rule, and this repo is not adopting it. The upstream file's own
   convention ("Rule numbers are stable ids... A removed rule leaves a gap")
   is used as designed — rule 13 is simply absent, not renumbered.
3. **`disable-model-invocation: true` is kept**, not dropped — see the first
   open question below.

Explicitly out of scope for this leg, per the ticket: no folding of any of
this into `CLAUDE.md`, a hook, or an always-on skill (himmel's escalation
rule needs a recorded second drift instance, and there isn't a first yet),
and no touching the `ponytail:` convention (HIMMEL-3117, a parallel leg's
territory).

## The two open questions, resolved

**1. Does Claude Code's SKILL.md frontmatter parser silently ignore
`disable-model-invocation: true`, or does it error?**

Neither. Verified against Claude Code's own docs
(`code.claude.com/docs/en/skills`, checked 2026-09-17): `disable-model-
invocation` is a first-class, documented, functioning CLI frontmatter key.
Setting it `true` hides the skill from autonomous model invocation while
leaving explicit `/unslop` invocation intact — exactly the lean-invoke shape
this pilot needs. It is not silently ignored (it does something) and it does
not error (Claude Code parses it as designed). The only place it does error
is claude.ai's stricter distribution/upload validator, which enforces the
narrower six-field Agent Skills spec and rejects any Claude Code-only key
(`disable-model-invocation` included) with a hard error — irrelevant here,
since this is a local project skill under `.claude/skills/`, never uploaded
to claude.ai. No himmel skill used this key before now; that reflects
absence of need, not unsupported syntax. **Decision: keep it.**

**2. Where does the vendored skill belong — a repo-tracked directory or the
operator's `~/.claude/skills/`?**

Repo-tracked, at `.claude/skills/unslop/SKILL.md`. Claude Code's own
discovery rules define `.claude/skills/<name>/SKILL.md` at a repository root
as the standard **project-scoped** skill location — loaded for every session
in this repository, distinct from the **personal** `~/.claude/skills/`
(every project on the machine) and from a **plugin** skill (namespaced,
distributed via the marketplace). himmel had no precedent for a repo-root
project skill before this — every existing himmel skill lives inside a
`marketplace/plugins/*` plugin instead, because those are built for
cross-repo distribution. `unslop` is neither: it's scoped to himmel's own
writing, not meant for the marketplace, and the pilot needs it active for
every session in this repo specifically. `.claude/skills/` is the
structurally correct fit, not a workaround. **Decision: repo-tracked, in
this diff.** (`~/.claude/skills/` was considered and rejected for this
reason — it would also mean the pilot runs invisibly, outside any diff a
reviewer could see.)

## Pilot + close condition

Per the ticket: apply `/unslop` to the next 3-5 PR descriptions / ADRs /
handover writeups that would otherwise ship as drafted. Baseline is the
pre-edit draft; treatment is the post-`unslop` edit plus one operator verdict
(better / worse / no difference). Close on **outcome**, never on rule-count
applied — the KPI is operator reword-passes per document, explicitly not
"percent of AI tells removed" (the vanity-metric shape the skill's own
self-audit step would itself produce, and the exact trap rubric §1 names).

If the pilot shows no signal, or the compression rules fight the operator's
preferred voice more than they help, close as **REJECT** with the numbers
attached.

## Honest limits

- Some fraction of the 33 patterns is likely already suppressed by the model
  and by ambient instructions (this repo's own CLAUDE.md, the Concise output
  style). The pilot must compare against **current** output, not a worse
  baseline, or it will credit the skill for work already done.
- "Sounds less like AI" has no automated check. The operator-verdict proxy is
  the best available instrument; if it produces no informal signal even
  after 3-5 documents, that is itself evidence for REJECT.
- Upstream can change the file; the pinned SHA in the skill's provenance
  header is what re-sync diffs against, not the branch tip.
- This ADR is not a measured justification for a real, observed friction —
  it's a pilot resting on an operator call to try something cheap and
  reversible. Do not cite it later as evidence the AI-prose problem was
  established; it wasn't, and that's the honest reading of rubric §1.

## Revisit trigger

At pilot close (3-5 documents processed): re-open this ADR, attach the
operator verdicts, and resolve to ADOPT (registry status `in-use`) or REJECT
(registry status `rejected`) per the close condition above.
