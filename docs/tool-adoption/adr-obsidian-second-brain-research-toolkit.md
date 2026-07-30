# ADR: obsidian-second-brain research toolkit (Grok/xAI + Perplexity)

> **DRAFT — pending operator sign-off.** Filed retroactively by the
> 2026-07-29 skill-hygiene round; the tool has been installed since
> 2026-05-16 with no ADR on record until now (rubric gap, HIMMEL-199/200).

**Proposed decision: NOT ADOPTED** (2026-07-29) — pending operator sign-off
on this ADR (see DRAFT banner above).

## What

The obsidian-second-brain plugin's research toolkit — six commands, three
external backends, matching the C17 declaration map in
`scripts/lib/dependency-readiness.sh`:

- `/x-read`, `/x-pulse`, `/youtube` — xAI Grok (Live Search), `XAI_API_KEY`
- `/research`, `/research-deep` — Perplexity Sonar, `PERPLEXITY_API_KEY`
- `/notebooklm` — Gemini File Search, `GEMINI_API_KEY`

## Why NOT ADOPTED

The 2026-07-29 skill-hygiene survey found real usage on `/x-read` (8×15d)
and a `~/.config/obsidian-second-brain/.env` credentials file present since
2026-06-12, which initially read as "keyed and working, just missing an ADR."
The operator corrected that premise directly: **there is no active Grok/xAI
or Perplexity subscription** — the credentials file is presence-without-
validity (stale or a placeholder), not evidence of a working integration.
Presence-only checking cannot distinguish "keyed and working" from "file
exists, no live subscription behind it" — this case is itself the motivating
example for the HIMMEL-1393 doctor readiness gate
(`scripts/lib/dependency-readiness.sh`). That gate detects configuration
**presence** and **documentation-state drift** only (a declared skill's key
missing/blank; a doc still calling an enabled+keyed toolkit "disabled") — it
never validates a live credential, so it could not by itself have caught
this case's presence-without-validity gap. Subscription validity stays
operator-confirmed, same as it was here.

Separately, the vault-first capture pipeline already covers the two content
types the toolkit's most-used commands (`/x-read`, `/youtube`) targeted,
**without any external API**: `/telegram-clip` and the Obsidian Web Clipper
file raw clips into `Clippings/`, `harvest-clips` marks them ready, and
`luna-ingest`/clip-body triage does the rest — `harvest-clips.md`'s own
comment (LUNA-26 pivot, 2026-05-26) documents this explicitly: *"The original
MVP's external-fetch paths (Grok via `/x-read`/`/youtube`, Perplexity via
`/research-deep`/`/research`) are deferred to LUNA-27 ... `/harvest-clips` no
longer re-fetches via external LLM skills."* `read-link` (LUNA-78) explicitly
rules "never Grok" for link reading, live-fetching via fxtwitter/WebFetch/
luna-ingest as the last resort instead. So beyond the missing subscription,
the API-dependent path was a duplicate parallel route on top of a pipeline
that already does the job without external egress or a paid key.

`/notebooklm` (Gemini File Search) is a different dependency (GEMINI_API_KEY,
not XAI/Perplexity) and is **not covered by this decision** — its key
presence was not independently confirmed during this round (blocked by the
`block-read-secrets.sh` guardrail; the operator would need to confirm via
`grep -c '^GEMINI_API_KEY=' <file>` or a `READ_SECRETS_OK=1` session).

## Disposition

- `/x-read`, `/x-pulse`, `/research`, `/research-deep`, `/youtube` — remove
  from `~/.claude/commands/` (operator action; these are user-scope files,
  not tracked by this repo — see the 2026-07-29 skill-hygiene round report
  for the exact paths).
- `/notebooklm` — untouched by this decision.
- `docs/tooling-catalog.md`'s research-toolkit line corrected to reflect this
  (2026-07-29), replacing the prior stale "disabled (needs XAI + Perplexity
  API keys — re-run install.sh to enable)" line, which was already wrong on
  its own terms (the credentials file had existed for six weeks) before this
  ADR further corrected the underlying premise (presence ≠ active subscription).

## Revisit trigger

If an XAI/Grok or Perplexity subscription is actually purchased and
confirmed live, re-open this ADR: re-run the tool-adoption rubric's
measure-during protocol using fresh usage telemetry, and reconsider
reinstalling the five commands.
