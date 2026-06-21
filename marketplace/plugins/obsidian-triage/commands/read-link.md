---
allowed-tools: Bash, Glob, Grep, Read, WebFetch, Skill
description: Vault-first link reader — read an already-harvested luna clip for a URL before any live fetch; live fetch (fxtwitter / WebFetch / luna-ingest) is the last resort, never Grok.
argument-hint: "<url>"
---

# /read-link <url>

Read a link vault-first. NEVER call Grok / x.ai / x_search.

## Steps

1. **Vault lookup (no network).** Run, from the himmel repo root:
   `node marketplace/plugins/obsidian-triage/tools/clip-lookup-cli.mjs "<url>"`
   Parse the single JSON line: `null`, or `{path,status,enriched}`.
   - If the command errors or prints `null` (no vault / no clip), treat as a MISS → go to step 4.

2. **Enriched hit → read it (STOP, no network).** If `enriched` is `true`:
   Read the clip at `path` (the lookup already returns an absolute path — do not
   prefix it with the vault root) and present TL;DR / key claims / sentiment from
   the clip body. Do not fetch anything.

3. **Thin hit → enrich, then read.** If a hit exists but `enriched` is `false`:
   - X url → run `node marketplace/plugins/obsidian-triage/tools/fxtwitter-enrich.mjs --vault <vault>` (browser-free, api.fxtwitter.com).
   - article → if `FIRECRAWL_API_KEY` is set and the privacy gate passes, enrich via the harvest firecrawl path; otherwise present what the clip has and note it is `thin-body` (do not fabricate).
   - Re-read the clip and present.

4. **Miss → live fetch (last resort).**
   - X url → `node …/tools/fxtwitter-enrich.mjs` against a freshly-filed clip, OR WebFetch `https://api.fxtwitter.com/<handle>/status/<id>`.
   - article → WebFetch the URL (firecrawl only if enabled+gated).
   - repo url (github/bitbucket) → dispatch `obsidian-triage:luna-ingest`.
   - NEVER Grok. Present the result; optionally offer to file it as a clip so next time is vault-first.

## Hard rules
- Grok is never called.
- The lookup (step 1) makes no network call; only steps 3–4 may.
- No vault / no clip is normal for adopters — fall straight to step 4, never error.
