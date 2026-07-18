# X Follow-List Judge Charter (HIMMEL-660)

Version: 1

Pinned scoring charter for the X-follow-list judge pass (Task 6, the
pluggable LLM seam). A judge (a Claude subagent pass today; any future
replacement — e.g. a v2 hybrid judge — changes only the judge consumer,
never `gather`/`assemble`) reads one `_judge-queue.jsonl` line at a time —
`{handle, charter_ref, trimmed_dossier}` — and scores the account against
this charter, writing `<handle>.judgment.json`. `charter_ref` pins this
file's path + its sha256 so a scoring run is reproducible against the
exact charter text it used.

## Scoring dimensions (0-5 each)

Score each dimension from 0 (no evidence / poor) to 5 (strong,
well-evidenced). Base every score on `trimmed_dossier` only — never on
outside knowledge of the handle.

- **factual_reliability** — how much of what the account claims (bio,
  sample tweets, resolved GitHub repos) holds up against the verified
  claims already in the dossier. Contradicted claims pull this down hard.
- **resources** — the concrete, reusable artifacts the account produces or
  points to (repos, tools, writeups, threads with real technical content),
  not follower count and not vibes.
- **reach** — audience size/engagement judged as *evidence of signal*, not
  a goal in itself. A small account with strong resources can outscore a
  huge account with none.
- **focus_fit** — overlap with Yotam's focus axes (below). An account
  wholly outside these axes scores low here even if it's otherwise
  excellent on every other dimension.
- **substance** — the depth/rigor of the account's own content: does it
  teach, build, or demonstrate — versus repost/hot-take volume.

## Grounding rule

Weight `verified` claims far above `unverified` claims — an unverified
claim is an assertion pending evidence, not evidence itself. A
`contradicted` claim is a **reliability penalty**, not a neutral
non-signal: it must pull `factual_reliability` down, not merely fail to
help it. When a claim (or the dossier as a whole) is unvalidatable — no
way to check it from the evidence in `trimmed_dossier` — cap that claim's
contribution to every dimension it would otherwise have supported, and
lower `confidence` accordingly. An unvalidatable claim never carries the
same weight as a verified one.

## Crypto-neutrality

Score crypto-tagged content on exactly the same axes as anything else —
**crypto is scored neither up nor down as a topic.** A crypto-tagged
account with strong resources/reliability/substance scores exactly as it
would if the same content were about any other topic; a crypto-tagged
account with weak resources/reliability/substance scores exactly as low
as it would on any other topic. `focus_fit` is judged solely against the
focus axes below, independent of whether the content happens to be
crypto-tagged — crypto is not itself one of Yotam's focus axes, and it is
not a penalty axis either.

## Yotam's focus axes (for focus_fit)

- agent harnesses
- agentic OS / Jarvis
- Claude Code
- AI engineering
- orchestration
- memory / context engineering
- second-brain

## Output schema

Emit exactly this JSON shape per handle — no extra top-level keys, and
**no `tier`** (tier is derived in code from these subscores — Task 7 — the
judge never assigns it):

```json
{
  "handle": "string",
  "scores": {
    "factual_reliability": 0,
    "resources": 0,
    "reach": 0,
    "focus_fit": 0,
    "substance": 0
  },
  "confidence": "high|med|low",
  "rationale": "string",
  "grounding_notes": "string"
}
```
