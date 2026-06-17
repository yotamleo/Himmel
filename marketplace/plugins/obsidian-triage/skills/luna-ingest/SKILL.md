---
name: luna-ingest
description: Use when ingesting a github OR bitbucket.org repo / issue / PR URL into the luna Obsidian vault — repo URLs fetch metadata + README, follow 1-hop references, classify each (integrate / take-parts / inspire / skip / api_failure) and write a structured tech-ingest note under 30-Resources/Tech/; issue URLs (github.com or bitbucket.org) fetch the issue and write an issue note; bitbucket PR URLs (HIMMEL-329) write a PR note. Triggers on /luna-ingest <url> at user prompt OR programmatic Skill-tool dispatch from inside another runbook (e.g. obsidian-triage:harvest-clips repo-URL dispatch branch). Host-routed: github.com via gh, bitbucket.org via the himmel bitbucket CLI. Rejects twitter / article inputs.
---

# luna-ingest — chain-following triage (LUNA-5 Wedge B, MVP; skill conversion LUNA-9)

You are running LUNA-5 Wedge B. Take a github OR bitbucket.org URL, follow its README references one hop (github sources only — see below), classify each, and produce a structured tech-ref note in the luna vault.

**Scope:** github + bitbucket.org URLs. Twitter (`x.com/...`) and article URLs raise an explicit "not yet" error and point at LUNA-5 v2.
- **github.com:** repo URLs run Phases 1–4; issue URLs (`/issues/<n>`) take the issue branch (HIMMEL-239); PR (`/pull/<n>`) and discussion URLs remain out of scope.
- **bitbucket.org (HIMMEL-329):** repo, PR (`/pull-requests/<n>`), and issue (`/issues/<n>`) URLs take the **Bitbucket branch** below. They dispatch to the himmel bitbucket CLI (`node scripts/bitbucket/dist/index.js …`) instead of `gh`.

**Forge routing (HIMMEL-329):** the URL **host** selects the path — parallel to how the dev-loop routes on the git origin. `github.com` (or bare `<owner>/<repo>`) → the github Phases below, unchanged. `bitbucket.org` → the **Bitbucket branch**. Everything in Phases 1–4 and the issue branch is the github path; the Bitbucket branch reuses the shared Phase 1.5 safety pre-filter and Phase 3/4 heuristics but swaps the fetch transport.

**Invocation surfaces (LUNA-9):**

- **User prompt:** `/luna-ingest <github-url> [--vault <path>] [--dest <category>] [--limit <N>] [--deep] [--research] [--dry-run]` — handled by the thin wrapper at `.claude/commands/luna-ingest.md` which delegates here.
- **Programmatic Skill-tool dispatch (HIMMEL-128 compliant — no headless claude):** `Skill { skill: "obsidian-triage:luna-ingest", args: "<github-url> [<flags...>]" }` from inside another runbook (e.g. `/harvest-clips` github-URL branch).

Both surfaces feed the same argument shape into the runbook below. Wherever this document references `$ARGUMENTS`, treat it as the literal arg string supplied via either invocation path.

## Inputs

`$ARGUMENTS` is `<url> [--vault <path>] [--dest <category>] [--limit <N>] [--dry-run]`.

Parse:
- `<url>` — required. Accepted shapes:
  - `https://github.com/<owner>/<repo>` (+ `/`, `/tree/<branch>`, `/blob/<branch>/<path>`)
  - `https://github.com/<owner>/<repo>/issues/<n>` — routes to the github issue branch (HIMMEL-239)
  - bare `<owner>/<repo>` — treated as github
  - `https://bitbucket.org/<ws>/<repo>` (+ `/`, `/src/<branch>/...`) — routes to the **Bitbucket branch** (HIMMEL-329)
  - `https://bitbucket.org/<ws>/<repo>/pull-requests/<n>` — Bitbucket PR branch
  - `https://bitbucket.org/<ws>/<repo>/issues/<n>` — Bitbucket issue branch
- `--vault <path>` — luna vault root. Default: `$HOME/Documents/luna`. Refuse with rc=2 if the dir does not exist OR is not an Obsidian vault (no `.obsidian/` dir).
- `--dest <category>` — vault destination category override. Default: `30-Resources/Tech`. Validate against the vault's PARA folders (`00-Inbox`, `10-Projects/*`, `20-Areas/*`, `30-Resources/Tech`, `30-Resources/Concepts`, `30-Resources/Components`). Anything else → rc=2.
- `--limit <N>` — max 1-hop refs to follow. Default `10`. Clamp to [1, 25].
- `--dry-run` — print what would be written + verdicts, touch no files. rc=0.
- `--allow-unsafe` — opt-in flag to ingest a repo flagged by the LUNA-43 safety-keyword pre-filter (Phase 1.5). Without this flag, repos whose name/description/topics match red-flag terms exit rc=6 before fetching the README.
- `--repo <ws/repo>` is NOT a luna-ingest flag — it is the bitbucket CLI's own override, set internally by the Bitbucket branch from the parsed URL. Operators pass the bitbucket.org URL, not `--repo`.
- `--deep` — LUNA-57: after classification, run the component scan
  (`tools/component-scan.mjs`) over the source repo (always) and over each
  1-hop ref verdicted `integrate` or `take-parts`. Inventories reusable
  components (skills/commands/agents/tools/plugin manifests) into a
  `## Reusable components` section of the Tech note AND a cross-repo-deduped
  `30-Resources/Components/` library. Off by default (MVP keeps the light path).
- `--components-dir <rel>` — vault-relative Components library root.
  Default `30-Resources/Components`. Only meaningful with `--deep`.
- `--max-components <N>` — per-repo component cap (tail-skip beyond). Default 60.
- `--research` — LUNA-64: after classification, web-research the SOURCE repo
  (maturity/adoption, notable alternatives, known limitations, community
  sentiment, recency) using Claude's own WebSearch/WebFetch tools and inject a
  `## Research enrichment` section into the Tech note. Off by default.
  **Orthogonal to `--deep`** — they enrich different axes (`--deep` = reusable
  components inventoried from the code; `--research` = external context about
  the repo) and may be combined (`--deep --research` runs both). This is the
  lightweight inline path: NO external Python (`research_deep.py`), NO
  Perplexity/Grok keys, NO vault-wide propagation — those belong to the full
  `/research-deep` command, deferred to a later LUNA-64 follow-up. Source repo
  only in MVP (1-hop refs are not researched). The harvest-clips github
  dispatch MUST NOT pass `--research` (cost + scope safety).

Reject `x.com/`, `twitter.com/`, or any host that is neither `github.com` nor `bitbucket.org` with:

```
ERR luna-ingest: only github.com and bitbucket.org URLs supported. Twitter + article inputs ship in LUNA-5 v2.
```

## Issue branch — github issue URLs (HIMMEL-239)

When `<github-url>` matches `^https?://(www\.)?github\.com/<owner>/<repo>/issues/(\d+)$` (query/fragment stripped first), run THIS branch instead of Phases 1–3.6 and the Phase 4 repo synthesis. The repo phases assume a README + 1-hop ref pool; an issue has neither, so this branch is deliberately flat: fetch → safety-filter → write. `--deep`, `--research`, and `--limit` are repo-only flags — if passed alongside an issue URL, ignore them with one stderr line: `WARN luna-ingest: --deep/--research/--limit are repo-only; ignored for issue URLs.`

**I-1 — Fetch.** Extract `<owner>/<repo>` + `<n>`. Validate `<owner>/<repo>` with the same Phase 1 regex (leading-char rule included). Then:

```bash
gh api "repos/${owner_repo}/issues/${n}" --jq '{title, state, body, user: .user.login, labels: [.labels[].name], comments, created_at, closed_at, html_url}'
```

- 404 → rc=5, nothing written (issue deleted or repo private/renamed).
- Other `gh api` failure → rc=2 with stderr inlined.
- Also fetch repo metadata (`gh api "repos/${owner_repo}"` — same Phase 1 jq) for the trust-tier inputs. If THIS call fails but the issue call succeeded, continue with `trust_tier: community-thin`, `trust_tier_reason: repo metadata unavailable → conservative default`.

Comments (skip when the issue's `comments` count is 0):

```bash
gh api "repos/${owner_repo}/issues/${n}/comments" --paginate --jq '.[] | {user: .user.login, created_at, body}'
```

Cap at the **30 most-reacted-or-earliest** comments (take the first 30 returned; the API returns oldest-first). If more existed, record `tail-skipped: <N-30> comments` in § Audit log.

**I-2 — Safety pre-filter.** Run the Phase 1.5 algorithm unchanged over: issue `title`, joined `labels[]`, and the first 8 KB of the issue `body`. Same rc=6 / `--allow-unsafe` semantics.

**I-3 — Write.** Destination: `<vault>/<dest-category>/<owner>-<repo>-issue-<n>.md` (Phase 4 slugify on `<owner>-<repo>`; same path-safety invariant; rc=3 if the file exists). Compute `trust_tier` from the REPO owner via the Phase 4 rules (the issue author does not affect the tier). Structure:

```markdown
---
type: tech-ingest
source: <issue html_url>
source_type: github-issue
ingested_at: <UTC ISO-8601>
last_revalidated: <UTC ISO-8601>
ingest_command: /luna-ingest
issue_state: <open|closed>
issue_author: <user.login>
issue_labels:
  - <label>
comment_count: <N>
tags:                # HIMMEL-247: REQUIRED — Phase 4 "Tags derivation", issue variant
  - github
  - github-issue
  - <tag>
trust_tier: <tier>
trust_tier_reason: <text>
safety_flag: <term-or-blank>
---

# <repo-name> issue #<n> — <issue title>

## Source

[<owner>/<repo>#<n>](<html_url>) — <state>, opened <created_at> by @<user.login><", closed <closed_at>" when closed>

## Summary

<3-5 bullet TL;DR: what the issue reports, root cause if identified, resolution state>

## Issue body

<the issue body as markdown, verbatim — trim only trailing template boilerplate>

## Key comments

<for each kept comment with substance (skip "+1"/"same here" noise): `> **@<user>** · <created_at>` followed by the comment body or its load-bearing excerpt. If none: `_(no substantive comments)_`>

## Audit log

- Comments fetched: <K> of <N> (tail-skipped: <T>)
- API calls: <2-or-3>
- Trust tier: <tier> (<reason>)
- Safety flag: <term-or-none>
```

Exit codes are the standard set (0 written, 2 env, 3 exists, 5 source fetch failed, 6 safety-blocked). The harvest-clips github dispatch needs no change: issue clips it dispatches here now land an issue note, and its rc=3 dedup contract holds (back-reference the existing `<owner>-<repo>-issue-<n>` note).

## Bitbucket branch — bitbucket.org URLs (HIMMEL-329)

When the URL host is `bitbucket.org`, run THIS branch instead of the github
Phases 1–4 / issue branch. It dispatches to the himmel **bitbucket CLI** —
`node <himmel-root>/scripts/bitbucket/dist/index.js <verb> --repo <ws>/<repo>`
— the `gh` analogue for Bitbucket Cloud. `<himmel-root>` is the himmel primary
checkout; the CLI's `dist/` is gitignored, so it must be built once
(`cd scripts/bitbucket && npm i && npm run build`). Auth comes from the repo-root
env file (`BITBUCKET_EMAIL` / `BITBUCKET_API_TOKEN`); a missing build or missing
creds surfaces as a CLI error → rc=2 (env unusable).

**B-0 — Parse + route.** Strip protocol/query/fragment, then:
- `bitbucket.org/<ws>/<repo>/pull-requests/<n>` → **B-PR** sub-branch.
- `bitbucket.org/<ws>/<repo>/issues/<n>` → **B-issue** sub-branch.
- otherwise (`/<ws>/<repo>`, optionally `/src/<branch>/…`) → **B-repo** sub-branch.

Extract `<ws>/<repo>` by stripping any `/src/…`, `/pull-requests/…`, `/issues/…`
suffix and a trailing `/`. Validate `<ws>/<repo>` with the **same** Phase 1
regex (`^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$`, leading-char
rule rejecting `.`/`..`); else rc=1. The CLI receives it verbatim via `--repo`.

### B-repo — repository ingest

**B-repo-1 Fetch.** `bitbucket repo get --repo <ws>/<repo>` → JSON `{name,
full_name, description, language, default_branch, url, updated_on, is_private,
readme}`. CLI rc≠0 (network / auth / repo 404) → **rc=5**, nothing written
(same contract as github Phase 1 source-fetch failure). `readme: null` (no
`README.md` on the default branch) → record `README: missing`.

**B-repo-1.5 Safety pre-filter.** Run the **Phase 1.5** algorithm unchanged over
`name`, `description`, and the first 8 KB of `readme`. Bitbucket has **no
`topics[]`** — skip that field. Same rc=6 / `--allow-unsafe` semantics and the
same `safety_flag` propagation.

**B-repo-2 Reference extraction + classification.** Write `readme` to a temp file
and run the **existing Phase 2 + Phase 3 unchanged** — they extract `github.com`
refs and classify them via `gh api`. github refs in a Bitbucket README are the
common, supported case. **bitbucket.org refs are NOT followed in MVP**
(BB→BB ref-following is a v2 follow-up): extract them separately
(`grep -oE 'https://bitbucket\.org/[^ )]+'`) and list them under § Open questions
as `bitbucket.org refs not followed (HIMMEL-329 MVP — v2 follow-up)`. `--limit`
applies to the github refs as usual.

**B-repo-3 Trust tier (bitbucket variant).** Bitbucket Cloud exposes **no
`stargazers_count`**. Apply the Phase 4 "Trust-tier auto-classification" rules
with these deltas:
- rule 0 (safety short-circuit), rule 1 (`anthropic-official`), rule 2
  (`known-author`, owner = `<ws>` lowercased) — **unchanged**.
- rule 3 (`community-active`) — **cannot fire** (no star signal) → skip it.
- rule 4 (`community-thin`) — default for any non-allowlisted owner.

`trust_tier_reason` for the rule-4 case: `bitbucket: no star signal,
updated_on=<YYYY-MM-DD> → community-thin`.

**B-repo-4 Synthesis.** Write the **same Phase 4 note shape** under
`<vault>/<dest>/<ws>-<repo>.md` (same slugify + path-safety invariant + rc=3 on
existing), with these frontmatter deltas:
- `source_type: bitbucket` (not `github`).
- **Omit `stars:` and `topics:`** — no Bitbucket equivalent; do NOT emit a fake
  `0` / empty list.
- `language:` from `repo get`; `license: unknown` (`repo get` returns no SPDX).
- `tags:` — first tag is `bitbucket` (parallel to github's first-tag `github`);
  since there are no `topics[]`, infer 2–4 domain tags from name + description +
  README per the Tags-derivation **rule 3** fallback (prefer the vault's existing
  tag vocabulary). Minimum 2 tags.
- The `## Referenced repos (1-hop)` section lists the **github** refs only;
  the `## Open questions` section carries the unfollowed-bitbucket-refs note.

`--deep` source-scan is **skipped on a Bitbucket source** (the LUNA-57
`component-scan.mjs` is `gh`-API-only and cannot scan a Bitbucket repo) — emit a
one-line stderr warn and continue; integrate/take-parts **github** refs are still
scanned. `--research` (LUNA-64) is forge-agnostic (WebSearch) and runs normally.

### B-PR — pull-request ingest

`bitbucket.org/<ws>/<repo>/pull-requests/<n>`. Flat fetch → write (like the
github issue branch — a PR has no README + ref pool).

**B-PR-1 Fetch.** `bitbucket pr get <n> --repo <ws>/<repo>` → `{id, title, state,
description, author, source_branch, destination_branch, url, created_on,
updated_on}`. CLI rc≠0 → rc=5, nothing written. Also fetch `bitbucket repo get
--repo <ws>/<repo>` for the trust-tier owner input; if THAT fails but the PR
fetch succeeded, continue with `trust_tier: community-thin`,
`trust_tier_reason: repo metadata unavailable → conservative default`.

**B-PR-2 Safety pre-filter.** Phase 1.5 algorithm over PR `title` +
`description` (first 8 KB). Same rc=6 / `--allow-unsafe` semantics.

**B-PR-3 Write.** `<vault>/<dest>/<ws>-<repo>-pr-<n>.md` (slugify `<ws>-<repo>`;
rc=3 if it exists). Compute `trust_tier` from the repo owner via B-repo-3.
Frontmatter mirrors the github issue note with `source_type: bitbucket-pr`,
`pr_state`, `pr_author`, `source_branch`, `destination_branch`; `tags:`
`bitbucket`, `bitbucket-pr`, then up to 3 inferred domain tags. Body:

```markdown
# <repo> PR #<n> — <title>

## Source
[<ws>/<repo> PR #<n>](<url>) — <state>, opened <created_on> by @<author>; <source_branch> → <destination_branch>

## Summary
<3-5 bullet TL;DR of what the PR changes, derived from title + description>

## Description
<the PR description verbatim as markdown; `_(no description)_` if empty>

## Audit log
- API calls: <1-or-2>
- Trust tier: <tier> (<reason>)
- Safety flag: <term-or-none>
```

### B-issue — issue ingest

`bitbucket.org/<ws>/<repo>/issues/<n>`.

**B-issue-1 Fetch.** `bitbucket issue get <n> --repo <ws>/<repo>` → `{id, title,
state, kind, content, reporter, url, created_on, updated_on}`. The CLI exits **3**
when the issue tracker is disabled OR the issue is gone (404) → map to **rc=5**,
nothing written (parallel to the github issue branch's 404 → rc=5). Other CLI
rc≠0 → rc=2. Also fetch `repo get` for the trust-tier owner (same degrade as
B-PR-1 on failure).

**B-issue-2 Safety pre-filter.** Phase 1.5 over issue `title` + `content`
(first 8 KB). Same rc=6 / `--allow-unsafe` semantics.

**B-issue-3 Write.** `<vault>/<dest>/<ws>-<repo>-issue-<n>.md` (rc=3 if exists).
Frontmatter mirrors the github issue note with `source_type: bitbucket-issue`,
`issue_state`, `issue_kind`, `issue_reporter`; `tags:` `bitbucket`,
`bitbucket-issue`, then up to 3 inferred domain tags. Body mirrors the github
issue note's `# … issue #<n>`, `## Source`, `## Summary`, `## Issue body`,
`## Audit log` (drop `## Key comments` — the MVP bitbucket issue read fetches no
comment thread; note that under § Audit log as `Comments: not fetched (MVP)`).

The harvest-clips dispatch contract is unchanged: a bitbucket.org clip dispatched
here now lands the matching note, and the rc=3 dedup invariant holds (back-ref
the existing `<ws>-<repo>[-pr|-issue]-<n>` note).

## Phase 1 — Source fetch (github URL)

Normalize to `<owner>/<repo>`:

```bash
# strip protocol, trim trailing /, strip /tree/* and /blob/* suffix
owner_repo=$(printf '%s' "$URL" | sed -E 's|^https?://github\.com/||; s|/(tree|blob)/.*$||; s|/$||')
```

Validate it matches `^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$` — the leading char rejects `.` or `..` as owner or repo (which would otherwise survive the looser `[A-Za-z0-9_.-]+` form and let `gh api "repos/../foo"` flow through). Else rc=1.

Fetch:

```bash
gh api "repos/${owner_repo}" --jq '{name, full_name, description, html_url, language, stargazers_count, topics, default_branch, pushed_at, license: .license.spdx_id}' > /tmp/luna-ingest-meta.$$.json
```

If `gh api` fails (rc≠0): exit 2 with the stderr inlined.

Read README via:

```bash
# Strip the API's embedded newlines BEFORE base64-decoding. macOS
# base64 errors on newline-padded input without -i; GNU silently
# accepts it. Trim makes the decode portable across both.
gh api "repos/${owner_repo}/readme" --jq '.content' \
  | tr -d '\n' \
  | base64 -d > /tmp/luna-ingest-readme.$$.md
```

If the README endpoint returns 404 (some repos have none): proceed with an empty README; record `README: missing` in the synthesis.

## Phase 1.5 — Safety pre-filter (LUNA-43)

Before continuing to Phase 2, scan the metadata captured in Phase 1 (`name`, `description`, `topics[]`) plus the decoded README for red-flag keywords.

**Matching algorithm (single canonical form — pin this exactly, no variants):**

1. **Normalize the searched field first.** For each of `name`, `description`, joined `topics[]`, and the first 8 KB of decoded README (interpret 8 KB as 8192 *bytes* of the UTF-8-encoded slice — truncate at a byte boundary, do not split a multibyte rune), lowercase the text and replace any run of one-or-more `[-_\s]+` characters with a single hyphen (`-`). This canonicalises `red_team`, `red team`, `red--team`, and `Red-Team` all to `red-team`.
2. **Apply each rule below as a case-insensitive substring search** against the normalized text. Whichever rule's substring (or AND-pair) appears first → set `safety_flag: <matched-term>` (use the first-listed canonical form from the rule). Word-boundary regex (`\b`) is NOT used — substring after normalization is the only form.
3. **AND-pair rules require both substrings to appear within 80 normalized characters** of each other in the same field (e.g. `red-team .{0,80} agent` or `agent .{0,80} red-team`).

**Single-term rules (substring matches alone trigger):**

- `abliteration` (also catches `abliterated`, `abliterationist`)
- `censorship-removal`
- `uncensored-model`
- `autonomous-hacking`
- `auto-hack`
- `exploit-kit`
- `malware-as-a-service`
- `maas-toolkit`

**AND-pair rules (BOTH substrings must appear in the same field within 80 chars):**

- `red-team` AND (`agent` OR `framework`) — avoids false-positives on legit security-research repos that mention red-team work
- `jailbreak` AND (`model` OR `llm` OR `bypass-safety`) — avoids false-positives on iOS jailbreak tooling

Match rule: if ANY of the rules above (or operator-curated additions, see below) trigger against `name` OR `description` OR `topics[]` OR the first 8 KB of decoded README → set `safety_flag: <matched-term>` (use the first-listed canonical form of the matched rule, e.g. `red-team+agent` for the AND-pair) and one of:

- Without `--allow-unsafe`: exit rc=6 with message `ERR luna-ingest: safety pre-filter matched <term> in <field>. Pass --allow-unsafe to ingest with safety_flag annotation, or skip this repo.` — no synthesis written.
- With `--allow-unsafe`: continue to Phase 2 but propagate `safety_flag` into the synthesis frontmatter so downstream readers (and `/synthesize-clips`) know to treat the page as `unknown-risk` regardless of license / star count.

**Operator customisation:** the keyword list above is the LUNA-43 default. Operators can extend it by setting `LUNA_INGEST_SAFETY_KEYWORDS=<comma-separated terms>` in their shell — additions ONLY (no removal of defaults). Removed defaults require an explicit SKILL.md edit + PR review, by design.

Log line: `[safety] matched=<term> field=<name|description|topics|readme> action=<refused|annotated>` to stderr regardless of action.

## Phase 2 — Reference extraction

Parse the README for github URLs that point at OTHER repos:

```bash
grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?' /tmp/luna-ingest-readme.$$.md \
  | sed -E 's|^https://github\.com/||; s|\.git$||; s|/$||' \
  | sort -u \
  | grep -v "^${owner_repo}$" \
  > /tmp/luna-ingest-refs.$$.txt || true
```

The `(\.git)?` suffix on the regex plus the `s|\.git$||` substitution dedupes `<owner>/<repo>` with `<owner>/<repo>.git` (a common README link form).

Strip refs whose path has more than one `/` (sub-paths inside the same repo — keep the bare owner/repo only), AND reject any segment that is purely `.` or `..` (would survive the looser ref regex and lead to `gh api repos/../something` calls that pollute the audit log):

```bash
awk -F/ 'NF==2 && $1 !~ /^\.+$/ && $2 !~ /^\.+$/' /tmp/luna-ingest-refs.$$.txt > /tmp/luna-ingest-refs.clean.$$.txt
```

Apply the `--limit` cap. If more refs exist than limit, log "tail-skipped: N refs" in the synthesis under § Open questions.

**LUNA-7 size telemetry:** measure the decoded README size with `wc -c < /tmp/luna-ingest-readme.$$.md` and record it in the synthesis § Audit log. If the size exceeds **512 KB**, emit a single stderr warning before Phase 3 starts:

```
WARN luna-ingest: README is <N> KB (>512 KB threshold). --limit caps API-call count, NOT text size; large monorepo/awesome-list READMEs may produce a noisy ref pool.
```

Continue regardless — the warning is informational. `--limit` already bounds the per-ref API-call cost; the size warning just flags "expect noisy classification" for the operator.

## Phase 3 — Per-ref classification

For each ref `<o>/<r>` in the cleaned ref list:

1. Fetch lightweight metadata: `gh api "repos/${ref}" --jq '{description, language, stargazers_count, pushed_at, topics, license: .license.spdx_id}'`. On failure, distinguish the failure class (LUNA-6):
   - **404 / "Not Found"** → verdict `skip`, `verdict_reason: ref_not_found`. Continue scanning the rest.
   - **403 / 429 / "rate limit" / "API rate limit exceeded"** → verdict `api_failure`, `verdict_reason: rate_limited`. Continue scanning; the run will exit rc=4 at the end so the operator knows to retry, but partial progress is preserved.
   - Other network/auth errors → verdict `api_failure`, `verdict_reason: <stderr-short>`. Continue; exit rc=4 at end.

   `api_failure` is NOT one of `integrate/take-parts/inspire/skip` — it's a SEPARATE verdict that exists only to keep partial runs honest. Refs with `verdict: api_failure` go under § Unclassified (transient) in the synthesis, never § Skip (which implies a deliberate heuristic decision).
2. Assign a verdict per these heuristics (apply in order; first match wins):
   - `integrate` — the ref appears in a parent README section titled "Dependencies", "Requires", "Built on", "Uses" OR the topics overlap explicitly with a "package" or "library" tag AND the ref has an SPDX license that's MIT / Apache-2.0 / BSD-3-Clause (permissive).
   - `take-parts` — the ref appears under "Related", "Inspired by", "See also", "Forked from" sections AND the ref has ≥10 stars AND its language matches one of the parent's top 2 languages.
   - `inspire` — the ref appears under "Reading", "Articles", "Background", "Prior art" OR the ref's language differs from the parent's primary language but its topics overlap.
   - `skip` — everything else, OR the ref's `pushed_at` is more than 24 months old (stale), OR license is restrictive (AGPL, BSL) and the parent suggests integration.
3. Capture a 1-3 sentence rationale citing which README section / topic / license / staleness drove the verdict.
4. Record confidence `0.0–1.0`: high (≥0.8) when section heading is unambiguous; medium (0.6–0.8) when section is implied by surrounding prose; low (<0.6) when no section context exists (verdict is best-guess from topics/license alone).
5. Refs with confidence <0.6 are listed in the synthesis under § Weak refs (appendix) instead of the main § Referenced repos section.

## Phase 3.5 — Deep component scan (LUNA-57, `--deep` only)

Skip this entire phase unless `--deep` was passed.

Run the component scanner once per repo, gh-API only (no clone). The source
repo is ALWAYS scanned; a 1-hop ref is scanned ONLY when its Phase-3 verdict
is `integrate` or `take-parts` (the repos actually worth lifting from — refs
verdicted `inspire`/`skip`/`api_failure` are not scanned). Propagate the
source's `trust_tier` + `safety_flag` into the scan so every Components/ note
inherits the parent's risk annotation. Compute the source `trust_tier` inline
here using the Phase-4 "Trust-tier auto-classification" rules — all their
inputs (`owner`, `stargazers_count`, `pushed_at`, plus the `safety_flag` set
in Phase 1.5) are already available at this point, so there is no need to wait
for the Phase-4 Write step.

For the SOURCE repo (writes the deduped library + returns JSON for the
Tech-note section):
```bash
bun "$TOOLS/component-scan.mjs" --repo "$owner_repo" --vault "$VAULT" \
  --components-dir "$COMPONENTS_DIR" --trust-tier "$trust_tier" \
  --safety-flag "$safety_flag" --max-components "$MAX_COMPONENTS" --emit json \
  [--dry-run]
```
Capture the JSON — its `components[]` array feeds the Phase-4
`## Reusable components` section.

For each ref `<o>/<r>` with verdict ∈ {integrate, take-parts} (library
dedup only; the Tech-note section summarises ref scans by count + link):
```bash
bun "$TOOLS/component-scan.mjs" --repo "<o>/<r>" --vault "$VAULT" \
  --components-dir "$COMPONENTS_DIR" --trust-tier "$ref_trust_tier" \
  --safety-flag "$safety_flag" --max-components "$MAX_COMPONENTS" --emit json \
  [--dry-run]
```
`$ref_trust_tier` is computed per-ref from that ref's OWN Phase-3 metadata
(description / language / stars / pushed_at / license / topics already
fetched in Phase 3) via the same Phase-4 "Trust-tier auto-classification"
rules; `$safety_flag` here is the SOURCE's Phase-1.5 flag — refs are not run
through the Phase-1.5 pre-filter, so they conservatively inherit the parent
source's flag.

When the skill was invoked with `--dry-run`, pass `--dry-run` to
component-scan too (it then prints the JSON inventory + would-write notes
without touching the vault, rc=0).

`$TOOLS` = `<plugin-root>/tools`. The tool is HIMMEL-128 compliant (no
headless claude — it shells `gh`, not `claude`). A non-zero exit (rc=4)
means ≥1 component file failed to fetch; record the count under § Open
questions and continue — partial inventories are honest, not fatal.

## Phase 3.6 — Research enrichment (LUNA-64, `--research` only)

Skip this entire phase unless `--research` was passed. Orthogonal to
Phase 3.5 — if both `--deep` and `--research` were passed, both phases run
(Phase 3.5 first, then this one).

This is the **lightweight inline** research path: you (Claude) run the web
research yourself via the WebSearch / WebFetch tools. Do NOT shell out to the
obsidian-second-brain `research_deep.py` script, and do NOT call Perplexity /
Grok — those (plus vault-wide `/obsidian-save` propagation) are the full
`/research-deep` command, deferred to a later LUNA-64 follow-up. Scope here:
**the SOURCE repo only** (1-hop refs are not researched in MVP — keeps the
tool-call budget bounded).

1. **Dry-run short-circuit.** If `--dry-run` was passed, skip the web queries
   entirely (avoids spending tool calls on a no-write run); print
   `DRY luna-ingest: would run research enrichment for <owner_repo>` to stderr
   and continue to Phase 4 (the `## Research enrichment` section is then
   rendered as `_(dry-run — research not executed)_`; do NOT set
   `research_enriched` — this is a degraded branch).
2. **Run 3–5 WebSearch queries** about the source repo. Seed them from the
   repo name + description + primary topics, covering these axes (drop any axis
   the repo metadata makes irrelevant):
   - maturity / adoption (is it actively used in production? release cadence?)
   - notable alternatives / what people compare it to
   - known limitations, gotchas, or common complaints
   - community sentiment + recency (how recent is the discourse?)
   Use WebFetch to pull a specific source when a search result needs
   confirmation. Keep total fetches modest (≤5) — this is enrichment, not a
   full research report.
3. **Synthesize** the findings into 4–8 bullets for the `## Research
   enrichment` section (rendered in Phase 4). Every external claim carries a
   recency marker (the source's date, or "as of <month YYYY>") and a source
   URL inline — consistent with the luna vault's AI-first sourcing rule.
4. **Graceful degradation.** If WebSearch/WebFetch is unavailable or returns
   nothing usable, do NOT fail the ingest: render the section as `_(research
   enrichment requested but web search returned no usable results)_`, add a
   one-line note under § Open questions, and continue. Do NOT set
   `research_enriched` (the note is not enriched). A partial note is better
   than no note — same rule as the component-scan partial path. No new exit
   code: `--research` failure never changes rc.

## Phase 4 — Synthesis

Compute a destination path under `<vault>/<dest-category>/<repo-slug>.md` where:
- `<repo-slug>` = lowercase, hyphens, max 60 chars. e.g. `kepano/obsidian-skills` → `kepano-obsidian-skills`. Slugify: replace any non-`[a-z0-9-]` with `-`, collapse repeats, strip leading/trailing `-`.
- If `<dest-category>` was passed via `--dest`, use it verbatim. Else default `30-Resources/Tech`.

**Path safety invariant:** before any Write, canonicalise the resolved destination via `realpath -m` and verify it starts with the canonicalised vault root. Refuse with rc=2 if a `..` traversal or symlink escape would land outside the vault. This guards against malformed `--dest` or weirdly-named refs.

If the target file already exists: refuse with rc=3 unless `--force` was passed (NOT supported in MVP — rc=3 with a hint to delete + retry).

### Trust-tier auto-classification (LUNA-43)

Compute the synthesis's `trust_tier` field from the source repo's `owner` (extracted as `owner = owner_repo.split('/')[0]`, then lowercased) before the Write step. All allowlist + literal comparisons in this section are **case-insensitive** — both sides lowercased before equality.

**Apply rules in this order, top-to-bottom, first match wins — do NOT reorder. Every rule short-circuits all later rules; rules 3 and 4 are NOT mutually exclusive on their own (both could match a given repo), but the "first match wins" semantic resolves the ambiguity in favour of rule 3 when both fire.**

0. **Safety short-circuit — `unknown-risk`.** If `safety_flag` (populated by Phase 1.5) is non-blank → `trust_tier = unknown-risk`, skip rules 1-4. This MUST execute before the owner-based rules so the audit-log `Trust tier: unknown-risk (reason: safety_flag=<term>)` is consistent regardless of who owns the repo.
1. **`anthropic-official`** — lowercased `owner` ∈ {`anthropics`, `anthropic`}.
2. **`known-author`** — lowercased `owner` ∈ the curated allowlist below. Default allowlist (all entries already lowercase):
   - Individual authors: `kepano`, `mattpocock`, `karpathy`, `obra`, `wshobson`, `everyinc`, `nizos`, `letta-ai`
   - Orgs: `microsoft`, `vercel`, `vercel-labs`, `github`, `browser-use`, `hkuds`, `smtg-ai`, `nousresearch`, `zilliztech`, `topoteretes`, `mksglu`
   - Operator extension: `LUNA_INGEST_TRUSTED_AUTHORS=<comma-separated owners>` adds to the allowlist (additions are lowercased before comparison; no removals).
3. **`community-active`** — none of the above matched AND `stargazers_count ≥ 100` AND `pushed_at` within the last 180 days.
4. **`community-thin`** — none of the above matched (default fallback for any non-allowlisted owner that did not satisfy rule 3).

(`stargazers_count` is the field name returned by `gh api repos/<owner_repo>` in Phase 1 — do NOT alias it to `stars` in the rule logic; the frontmatter `stars:` field is the rendered value, the gh-api source name stays canonical in code paths.)

Populate `trust_tier_reason` with a 1-line justification matching the tier:
- rule 0 → `safety_flag=<term> → unknown-risk`
- rule 1 → `owner=<owner-as-fetched> → anthropic-official`
- rule 2 → `owner=<owner-as-fetched> in known-author allowlist`
- rule 3 → `stargazers_count=<N>, pushed_at=<YYYY-MM-DD> → community-active`
- rule 4 → `stargazers_count=<N>, pushed_at=<YYYY-MM-DD> → community-thin`

Operators retro-tagging older Tech pages should rely on the Phase 4 § Audit log row `Trust tier: <tier> (<reason>)` rather than re-deriving manually.

### Tags derivation (HIMMEL-247)

`tags:` is REQUIRED in every emitted note's frontmatter — the vault's Tech
notes are tag-queried (Dataview / triage tooling), and an untagged note is
invisible to those queries. The original Phase 4 / I-3 templates never
emitted it — every pre-fix tech-ingest note shipped untagged (all 29
`type: tech-ingest` notes as of 2026-06-11; HIMMEL-247 backfilled them).
The "~90 earlier Tech notes that carry tags" in the ticket are
clipper-pipeline `type: tech-resource` notes — a different emitter, not
luna-ingest output. Never omit it.

Rules (repo notes):

1. First tag is always `github` — matches the existing `30-Resources/Tech/`
   scheme (the dominant tag in that folder).
2. Then the repo's `topics[]` from the Phase 1 metadata, each normalized the
   Phase 1.5 way (lowercase, runs of `[-_\s]+` → a single `-`), deduped,
   capped at **5** topic tags. When more than 5 topics exist, pick the most
   content-salient ones (what the repo IS, not its stack minutiae), preferring
   topics that already appear in the vault's tag vocabulary — NOT blind
   API/alphabetical order.
3. If the repo has no topics (or fewer than 2 survive normalization), infer
   2–4 domain tags from the name + description + README — prefer the vault's
   existing tag vocabulary (e.g. `claude-code`, `ai-agents`, `mcp`,
   `obsidian`, `cli`, `automation`, `memory`, `skills`) over minting a new
   term; check existing Tech-note tags before coining one.
4. Minimum 2 tags total — never a bare `tags:` with no entries, never
   `github` alone.

Issue notes (I-3) use the variant: `github`, `github-issue`, then up to 3
topic tags derived the same way (repo `topics[]` when the I-1 repo-metadata
fetch succeeded; else inferred from the issue labels + title).

Write the file. Structure:

```markdown
---
type: tech-ingest
source: <URL>
source_type: github
ingested_at: <UTC ISO-8601>
last_revalidated: <UTC ISO-8601>   # LUNA-43: initially same as ingested_at. Reserved for periodic revalidation tooling — currently unused by any sweep script. Future tooling can compute staleness from this field without confusing it with ingested_at (which never moves after first write).
ingest_command: /luna-ingest
verdict_summary:
  integrate: <count>
  take-parts: <count>
  inspire: <count>
  skip: <count>
  api_failure: <count>   # LUNA-6: refs we couldn't classify due to rate-limit / network / auth. NON-ZERO means partial run.
license: <SPDX or unknown>
stars: <N>
language: <primary>
topics:
  - <topic>
tags:                       # HIMMEL-247: REQUIRED — never omit. Derivation rules in "Tags derivation" above.
  - github
  - <tag>
trust_tier: <tier>          # LUNA-43: anthropic-official | known-author | community-active | community-thin | unknown-risk
trust_tier_reason: <text>   # LUNA-43: 1-line justification (e.g. "owner=anthropics → anthropic-official"; "owner=kepano in allowlist → known-author"; "stargazers_count=12, pushed_at=2025-04-01 → community-thin"). Field name is `owner=` (the lowercased value extracted in trust-tier rule logic), matching the trust-tier rule wording — NOT `owner_org=`.
safety_flag: <term-or-blank> # LUNA-43: blank if Phase 1.5 found no red-flag terms; matched term otherwise. NON-BLANK forces trust_tier=unknown-risk via rule 0 short-circuit in trust-tier classification.
research_enriched: <true-or-omit>  # LUNA-64: set true ONLY when --research ran (Phase 3.6) AND produced real findings. Omit the field entirely when --research was not passed OR enrichment degraded (dry-run short-circuit / web-failure placeholder) — a degraded note must not advertise itself as enriched to downstream readers (/synthesize-clips, revalidation tooling).
---

# <repo-name>

## Source

[<full_name>](<URL>) — <description from gh api>

- **Language:** <language> | **Stars:** <N> | **License:** <SPDX>
- **Last push:** <pushed_at>
- **Topics:** <topics joined by ", ">

## Summary

<3-5 bullet TL;DR derived from README + repo metadata>

## Referenced repos (1-hop)

<for each ref with confidence ≥0.6, sorted by verdict severity integrate > take-parts > inspire > skip>

### <ref-full-name> — <verdict>

- URL: https://github.com/<ref>
- Language: <lang> | Stars: <N> | License: <SPDX>
- **Rationale:** <1-3 sentences>
<if verdict == take-parts>
- **What to lift:** <file/path/area to inspect first>
</if>

## Research enrichment

<Only present when --research was passed (Phase 3.6). 4–8 bullets synthesizing
the WebSearch findings about the SOURCE repo — maturity/adoption, notable
alternatives, known limitations, community sentiment. Each external claim ends
with a recency marker + source URL inline, e.g.:
`- Actively maintained; v2.3 released as of Mar 2026 ([release notes](https://…)).`
On dry-run, render `_(dry-run — research not executed)_`. On web failure,
render `_(research enrichment requested but web search returned no usable
results)_`. If --research was NOT passed, omit this section entirely.>

## Reusable components

<Only present when --deep was passed. Compose from the source-repo scan
JSON. For each component in `components[]`, one bullet:
`- **<name>** (<type>) — <description>. _Reuse:_ <1-2 line how-to-rephrase
for himmel/luna — YOUR judgment from the description + type>.`
Then, for each integrate/take-parts ref that was scanned, one summary line:
`- _Ref <o>/<r>: N components inventoried → see [[30-Resources/Components/]]._`
If --deep was NOT passed, omit this section entirely.>

## Weak refs (low-confidence, appendix)

<for each ref with confidence <0.6 — same structure, condensed>

## Unclassified (transient — re-run to retry)

<for each ref with `verdict: api_failure` — list URL + verdict_reason. LUNA-6: surfaces rate-limited / network-failed refs distinctly from § Skip so operator knows what to retry. Empty section reads `_(none — all refs classified)_`.>

## Action items

<extracted from README headings like "TODO", "Roadmap", "Known issues" — convert each to `- [ ] <item>`. If none found: `_(none — repo README has no TODO/Roadmap section)_`>

## Open questions

<gaps the chain-follow could not resolve. Always include: "Verify integrate-verdict refs by reading their root README before taking a dep on any of them.">

## Audit log

- Refs scanned: <N>
- Refs above confidence floor (0.6): <K>
- Refs marked api_failure (LUNA-6): <F> (if >0: rc=4; re-run to retry classification)
- Tail-skipped: <T> (set if more refs existed than --limit)
- API calls: <N+1>
- README size: <bytes> (LUNA-7: warn if >512 KB; --limit caps API-call count, not text size)
- Trust tier: <tier> (<reason>)   (LUNA-43)
- Safety flag: <term-or-none>   (LUNA-43: non-blank value reached rc=6 unless --allow-unsafe; document the term in this row regardless)
```

## Phase 5 — Daily-note backref (deferred to v2)

MVP does NOT touch the daily note. v2 picks up the obsidian-triage Phase 5 dedup-by-backreference contract.

## Phase 6 — Promotion candidate (deferred to v2)

MVP does NOT write `00-Inbox/promote-<slug>.md`. v2 adds this when any verdict ∈ {integrate, take-parts}.

## Dry-run mode

When `--dry-run` is passed:
- Print "DRY luna-ingest: would write <full-path>"
- Print the synthesized markdown body to stdout, prefixed with 4 spaces
- Print per-ref verdict summary table
- With `--research`: skip the Phase 3.6 web queries (print `DRY luna-ingest:
  would run research enrichment for <owner_repo>`); the `## Research
  enrichment` section renders `_(dry-run — research not executed)_`.
- rc=0, touch no files in the vault

## Exit codes

- 0: synthesized + written (or dry-run completed) — all refs classified
- 1: usage / input error (bad URL, missing required arg)
- 2: env unusable (vault not found, gh api / bitbucket CLI unreachable or unbuilt for source repo, dest category invalid)
- 3: target file exists (no overwrite in MVP)
- 4: **partial run** — synthesis written but ≥1 ref was marked `api_failure` (rate-limit / network / auth). Re-run later to retry the failed refs; the dedup-by-existing-file invariant means the existing synthesis stays unless `--force`. (LUNA-6)
- 4 (extended): also returned when `--deep` component scan reported ≥1
  component-fetch failure (partial inventory). Synthesis is still written.
- 5: source fetch failed — `gh api` (github Phase 1) or the `bitbucket` CLI (HIMMEL-329 Bitbucket branch) failed for the SOURCE repo / PR / issue (network / rate limit / 404 / issues-disabled) — nothing written, retry the whole call
- 6: **safety-blocked** — Phase 1.5 matched a red-flag keyword in name/description/topics/README (github) or name/description/README (bitbucket — no topics), and `--allow-unsafe` was NOT passed. Nothing written. Re-run with `--allow-unsafe` to ingest with `safety_flag` annotation (which exits rc=0, NOT rc=6, on success — `--allow-unsafe` plus a match is a known-risk acknowledged ingest, not an error). (LUNA-43)

`--research` (LUNA-64) never changes the exit code: a web-search failure
degrades gracefully (annotated section + § Open questions note) and the
synthesis is still written at the rc the rest of the run would have produced.

## Out of scope (v2 follow-ups)

- Twitter URL input via `/x-read`
- Article URL input via `/defuddle` + `/research`
- github PR (`/pull/<n>`) + discussion URL ingestion (github issue URLs landed in HIMMEL-239; bitbucket repo/PR/issue landed in HIMMEL-329)
- bitbucket-source → bitbucket-ref 1-hop following (HIMMEL-329 MVP follows only github refs from a bitbucket README)
- bitbucket PR comment-thread + issue comment ingestion (the MVP bitbucket PR/issue notes carry no comment thread)
- `--deep` component scan of a bitbucket SOURCE repo (component-scan is `gh`-API-only)
- Dynamic destination routing based on verdict mix
- Daily-note backref (Phase 5)
- Promotion candidate (Phase 6)
- Refs-of-refs (hop ≥2)
- Batch input (`@file-of-urls.txt`)
- Reverse-chain lookup

Each is a separate ticket under LUNA-5 (file as sub-tasks before starting v2).
