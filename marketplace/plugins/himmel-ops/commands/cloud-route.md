---
description: Classify tickets for the cloud lane, write the cloud brief, print the operator launch line. Never launches.
argument-hint: HIMMEL-<n> [HIMMEL-<n> ...]
---

Routing a ticket to `claude --cloud` was console hand work: read the ticket,
judge it, write the brief from `docs/handover/cloud-brief-template.md`, hand the
operator a command. This does the mechanical part. It **only prints** the launch
line: `claude --cloud` needs a TTY in the operator's terminal and spends credit,
so the operator runs it.

## Workflow

1. Collect the keys from `$ARGUMENTS`. Optionally write a held-files list (one
   path per line: files of live legs, or anything else one-writer-per-file) and
   a spec JSON `{"HIMMEL-n": {"files": [...], "change": "...", "branchType": "fix", "completes": "yes"}}`
   for any ticket whose touched files or "The change" text the console knows
   better than the ticket's prose.
2. Dry run first (reads Jira and open PRs, writes nothing):

   ```bash
   node scripts/lanes/cloud-route.mjs --classify-only HIMMEL-<n> HIMMEL-<m>
   ```

   One line per ticket: key, class, one-line reason.
3. Route for real into the console bucket (briefs plus `cloud-route.jsonl`):

   ```bash
   node scripts/lanes/cloud-route.mjs --bucket <bucket-dir> --console <console id> [--held <file>] [--spec <json>] HIMMEL-<n> ...
   ```

   Each CLOUD-OK ticket gets `cloud-brief-HIMMEL-<n>.md` and ONE printed line,
   `konsole --separate -e claude --cloud "$(cat <brief>)" --permission-mode auto`.
   Every ticket, whatever its class, gets one record in `cloud-route.jsonl`
   (ticket, class, reason, brief path, time) so the console can shepherd each
   resulting PR.
4. Before handing a launch line over, file a follow-up ticket for every ask the
   brief scopes out and add `"change"` naming each key (template, "PR body
   contract"). Hand the operator the lines; the shepherd polls the PRs.

## Classes (first match wins)

| Class | When |
|---|---|
| BLOCKED | ticket not To Do; a touched file is held by an open PR (`gh pr diff --name-only`) or the console list; or `gh` failed, so freedom is unproven |
| HOOK-BYPASS | touches `scripts/hooks/`: hooks do not run in the cloud and edits need the integrity bypass |
| LOCAL-NATIVE | touches a trust path (`scripts/ci/ci-trust-paths.txt`, read as data); needs luna, a vault or handover state at run time (private data never leaves the station); more than 3 asks; or names no file. AST-only graphify and BM25 `qmd search` over the repo do not route local: the cloud setup installs both. `qmd query`, vector search and `qmd embed`/`pull` still do (the cloud has no qmd models), and so does a semantic graphify run (`/graphify`, `--backend`) |
| CLOUD-OK | none of the above |

Files come from the ticket text (repo paths) unless the spec supplies them.
