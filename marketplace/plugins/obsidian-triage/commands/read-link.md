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
   - X url → **first** run `bash <plugin>/tools/ensure-deps.sh` (resolve `<plugin>` from the installed plugin root, matching harvest-clips.md — a repo-relative path fails in a cache-installed plugin, the very case this preflight exists for). It installs the `js-yaml` dep `fxtwitter-enrich.mjs` needs but `tools/.gitignore` keeps out of git — fast no-op when present, browser-download-free install when absent; needed only on this X-enrich path, not for a non-X url. **If it exits non-zero, STOP and report its remediation message — do NOT run the enricher** (it would just throw the `js-yaml` error). Only on success run `node <plugin>/tools/fxtwitter-enrich.mjs --vault <vault>` (browser-free, api.fxtwitter.com).
   - article → if `FIRECRAWL_API_KEY` is set and the privacy gate passes, enrich via the harvest firecrawl path; otherwise present what the clip has and note it is `thin-body` (do not fabricate).
   - Re-read the clip and present.

4. **Miss → live fetch (last resort).**
   - X url → run `bash <plugin>/tools/ensure-deps.sh` first (as in step 3, `<plugin>` = installed plugin root — only before the `fxtwitter-enrich.mjs` option, not the WebFetch fallback). **If it exits non-zero, report the remediation and skip the enricher — fall through to the WebFetch option** (which needs no `js-yaml`). Otherwise run `node <plugin>/tools/fxtwitter-enrich.mjs` against a freshly-filed clip, OR WebFetch `https://api.fxtwitter.com/<handle>/status/<id>`.
   - article → WebFetch the URL (firecrawl only if enabled+gated).
   - repo url (github/bitbucket) → dispatch `obsidian-triage:luna-ingest`.
   - NEVER Grok. Present the result; optionally offer to file it as a clip so next time is vault-first.

## Hard rules
- Grok is never called.
- The lookup (step 1) makes no network call; only steps 3–4 may.
- No vault / no clip is normal for adopters — fall straight to step 4, never error.
