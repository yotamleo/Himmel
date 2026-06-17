# Bitbucket Cloud support via a forge-dispatch layer

- **Status:** Approved design — ready for implementation planning
- **Date:** 2026-06-16
- **Driver:** himmel has users whose repos live on Bitbucket Cloud (not GitHub).
  himmel must give them the same dev-loop a GitHub user gets.
- **Goal:** Full parity with the current GitHub integration, scoped to
  **Bitbucket Cloud** (`bitbucket.org`) only. Bitbucket Server/Data Center is
  out of scope.

---

## 1. Problem & goal

Today every forge operation in himmel assumes GitHub and shells out to `gh`
(PR open/merge, merged-PR pruning, repo context, auth, user-slug, issue
filing, review threads). A user whose `origin` is `bitbucket.org` gets nothing.

The goal is a **forge-agnostic dev-loop**: the forge is selected per-repo from
the `origin` remote URL, and every himmel verb routes to the correct backend.
A Bitbucket user runs the identical workflow — worktree → PR → CR gate →
merge → clean-garden prune — with no GitHub assumptions leaking through.

### Decisions already made (during brainstorming)

| Decision | Choice |
|---|---|
| Bitbucket flavor | **Cloud only** (`bitbucket.org`, REST API v2.0) |
| Seam location | **Forge-dispatch layer** — one interface, backend chosen per-repo by remote URL |
| Plugin shape | **Fold into `himmel-gh`** (make it forge-aware; keep the name) |
| Auth | **Atlassian API token with Bitbucket scopes**, supplied via `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN` env (auto-loaded from repo-root `.env`, Jira-CLI pattern) |
| Transport | **himmel-owned `bitbucket` CLI** wrapping a maintained TypeScript SDK, mirroring `scripts/jira/` — NOT hand-rolled REST |
| Spec scope | **All four phases in one spec**, each an independently-shippable PR |

### Verified facts (de-risking, 2026-06-16)

- The existing **Jira API token does NOT authenticate against Bitbucket**
  (`GET /2.0/user` → `401 "Token is invalid, expired, or not supported for this
  endpoint."`). Atlassian scoped API tokens are per-app; a Bitbucket-scoped
  token is required. **This is a hard prerequisite** — see §9.
- No `gh`-equivalent official Bitbucket CLI exists. Two viable TS SDKs:
  [`bitbucket`](https://github.com/MunifTanjim/node-bitbucket) (octokit-style,
  OpenAPI-generated, popular, intermittent maintenance) and
  [`@coderabbitai/bitbucket`](https://github.com/coderabbitai/bitbucket)
  (`openapi-typescript`-generated, actively maintained). SDK pick is the first
  step of implementation (§7), run through `docs/tool-adoption/rubric.md`.

---

## 2. Architecture — the forge seam

A single forge abstraction with two backends, selected by parsing
`git remote get-url origin`:

- `github.com/<owner>/<repo>` or `git@github.com:<owner>/<repo>.git` → **github backend** (today's `gh` calls, lifted unchanged)
- `bitbucket.org/<workspace>/<repo>` or `git@bitbucket.org:<workspace>/<repo>.git` → **bitbucket backend** (himmel `bitbucket` CLI)
- anything else → fail loud with an actionable message (no silent fallback)

**`forge_detect()` precedence (exhaustive — no ambiguity for an unattended run):**
1. If `FORGE` env var is set (`github`|`bitbucket`), use it verbatim. This is
   the **only** disambiguator for a repo with mixed remotes (e.g. a GitHub fork
   of a Bitbucket upstream) and the override used in tests.
2. Else read `git remote get-url origin`; match against the github/bitbucket
   host regexes (https + ssh forms, optional trailing `.git`, case-insensitive
   host).
3. If `origin` is missing **or** matches neither host → **exit non-zero** with
   `forge_detect: cannot determine forge — set FORGE=github|bitbucket or add a github.com/bitbucket.org origin`.
   Never infer the forge from a non-`origin` remote (silent wrong-API risk).

himmel has two languages, so the seam has two parallel (but mirror-image)
dispatch points:

### Shell layer — `scripts/lib/forge.sh`

- `forge_detect()` → echoes `github` | `bitbucket` | (exit non-zero + message)
- Verb functions, each routing to the detected backend:
  - `forge_pr_create`, `forge_pr_merge`, `forge_pr_mergeable`,
    `forge_pr_list_merged`, `forge_repo_context`, `forge_auth_status`,
    `forge_default_branch`, `forge_user_slug`, `forge_issue_create`
- Backends:
  - `scripts/lib/forge-github.sh` — today's `gh` logic **moved, not rewritten**
  - `scripts/lib/forge-bitbucket.sh` — shells out to the himmel `bitbucket` CLI
    (symmetric with how everything shells out to `gh`)

Only the verbs actually used today are abstracted. No speculative interface.

### Node/plugin layer — `plugins/himmel-gh/lib/forge/`

- `detect.mjs` — same remote-URL detection
- `github-backend.mjs` — reuses the existing `repo-context-cli.mjs`,
  `threads-list-cli.mjs`, etc.
- `bitbucket-backend.mjs` — calls the SDK / himmel `bitbucket` CLI
- Existing skills/commands keep their names + intents; routing changes
  underneath. (Plugin stays named `himmel-gh`; it becomes forge-aware.)

### The himmel `bitbucket` CLI — `scripts/bitbucket/`

Mirrors `scripts/jira/` exactly:

- TypeScript source → built `dist/index.js`, invoked **by absolute path**
- Auto-loads repo-root `.env`; reads `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN`
- Wraps the chosen TS SDK (best-practice typed client, not raw `fetch`)
- Emits JSON on stdout (the `gh --json` analogue) so shell + plugin parse it
- Subcommands map 1:1 to the verb table (§4)
- Both the shell backend and the plugin backend call this one CLI → single
  transport, dogfooded like the Jira CLI

```
                 ┌─────────────────────────┐
 shell scripts ──┤ scripts/lib/forge.sh     ├─► forge-github.sh ─► gh
 (pr-open, …)    │   forge_detect + verbs   │
                 └────────────┬─────────────┘
                              └─────────────► forge-bitbucket.sh ─┐
 plugin skills ──┤ lib/forge/ detect+route  ├─► github-backend ─► gh
 (gh-pr-*)       └──────────────────────────┘  bitbucket-backend ┤
                                                                  ▼
                                              scripts/bitbucket/dist/index.js
                                                   (TS SDK over BB REST v2)
```

---

## 3. Auth & transport

- Base: `https://api.bitbucket.org/2.0`, HTTP Basic auth =
  `BITBUCKET_EMAIL:BITBUCKET_API_TOKEN`.
- Token = **Atlassian API token created "with scopes" and the Bitbucket app
  selected.** Required scopes (cover the verb table):
  `read:repository:bitbucket`, `write:repository:bitbucket`,
  `read:pullrequest:bitbucket`, `write:pullrequest:bitbucket`,
  `read:account`, `write:issue:bitbucket`.
- `.env` additions (gitignored, never committed):
  ```
  BITBUCKET_EMAIL=<atlassian-account-email>
  BITBUCKET_API_TOKEN=<scoped-token>
  ```
- The himmel `bitbucket` CLI strips trailing CR/whitespace from these values
  (same defensive parsing the Jira CLI already does — CRLF-safe Basic auth).
- `/gh-init` (forge-aware) verifies creds + workspace access for whichever
  forge the repo uses, mirroring today's GitHub auth check.

---

## 4. Verb mapping (the parity table)

| himmel verb | GitHub (today) | Bitbucket Cloud REST v2 (via himmel CLI) |
|---|---|---|
| pr create | `gh pr create` | `POST /2.0/repositories/{ws}/{repo}/pullrequests` `{title, source.branch.name, destination.branch.name, description}` |
| pr merge (squash, delete source) | `gh pr merge --squash --delete-branch` | `POST .../pullrequests/{id}/merge` `{merge_strategy:"squash", close_source_branch:true}` |
| pr mergeable check | `gh pr view --json mergeable` | **no direct field** — see §5.1 |
| list merged PRs (clean-garden) | `gh pr list --state merged` | `GET .../pullrequests?q=state="MERGED"` (paginated) |
| repo context (owner/repo, default branch) | `gh repo view --json owner,name,defaultBranchRef` | `GET .../repositories/{ws}/{repo}` → `full_name`, `mainbranch.name` |
| auth status | `gh auth status` | `GET /2.0/user` |
| user slug | `gh api user -q .login` | `GET /2.0/user` → `nickname` (fallback `account_id`) — see §5.4 |
| issue create (CR deferred) | `gh issue create --label cr-deferred` | `POST .../issues` — see §5.2 |
| review threads list/reply/resolve | `gh api graphql` | REST PR comments + resolve endpoint — see §5.3 |

---

## 5. Known divergences (handled explicitly, not papered over)

### 5.1 No `mergeable` boolean — VERIFIED behavior (PF-2, 2026-06-16)
Bitbucket Cloud's PR object has no GitHub-style `mergeable` field, and `state`
stays `OPEN` even when the PR conflicts (confirmed against a live conflicting
PR). There is **no dry-run merge endpoint**. The verified, definitive signal:

- `POST .../pullrequests/{id}/merge` is **atomic**: `200` = merged;
  **`400` with `error.message` = "You can't merge until you resolve all merge
  conflicts."** = conflict, and **nothing was merged** (safe to treat as
  "not mergeable").

So the bitbucket backend does NOT pre-poll a mergeable field. `forge_pr_merge`
attempts the merge and maps the `400`-conflict body to the same failure the
GitHub path raises; `forge_pr_mergeable` (used by `check-pr-mergeable.sh`) is
implemented as the same attempt guarded by `SKIP_PR_MERGEABLE`. **Async note:**
the PR object has a `queued` field — merges can be queued; the backend polls PR
`state`→`MERGED` (with a timeout) after a `200`/queued response before
declaring success. `SKIP_PR_MERGEABLE=1` stays forge-agnostic.

### 5.2 Issues disabled by default — VERIFIED `404` (PF-3, 2026-06-16)
Bitbucket repos ship with the **issue tracker off**; `POST .../issues` on a
disabled repo returns **`404 "Resource not found"`** (verified — not `403`).
`file-deferred-issues` must treat `404` on the issues endpoint as
"issues disabled" and **degrade gracefully** — skip + emit a one-line warning
naming the deferred findings — rather than erroring the CR flow. (GitHub path
unchanged.) Retry policy: **do NOT retry `404`/`403`** (deterministic); **MAY
retry `5xx`/`429`** with backoff (respect `Retry-After`), cap 3 attempts.

### 5.3 No GraphQL → REST review threads
Bitbucket Cloud has no GraphQL API. The `gh-pr-comments` / `-reply` /
`-resolve` skills are reimplemented over REST:
- list: `GET .../pullrequests/{id}/comments` (inline comments carry
  `inline.path` + `inline.to/from`)
- reply: `POST .../pullrequests/{id}/comments` with `parent.id`
- resolve: `POST .../pullrequests/{id}/comments/{cid}/resolve`
The thread-cache prefix mechanism (SHA256 → 6-char prefix) is reused; only the
fetch/mutate calls differ. Bitbucket's flat comment+`parent` model is mapped
into the existing thread abstraction.

### 5.4 Identity — VERIFIED (PF-1, 2026-06-16)
Bitbucket is deprecating `username`; key on `nickname`, fall back to
`account_id`, then `uuid`. `GET /2.0/user` for our token returns **all of
`nickname`, `account_id`, `uuid` present** — the fallback chain is fully
backed. Affects handover user-slug resolution (`scripts/lib/user-slug.sh`). If
(future) none are present the resolver errors loudly — never an empty slug
(empty user-slug silently corrupts handover paths).

### 5.6 CHANGE-2770 — cross-workspace endpoints removed
Atlassian retired cross-workspace listing APIs (`GET /2.0/workspaces`,
`GET /2.0/repositories/{ws}?role=member`, user-scoped permission endpoints);
brownouts are live now, full sunset 2026-04-14. **himmel never lists
workspaces** — always derive `{workspace}/{repo}` from the `origin` remote URL
(§2) and call **workspace-scoped** endpoints (`/repositories/{ws}/{repo}/…`).
This was verified during preflight: `/workspaces` → `410`, but
`/workspaces/{ws}` and `/repositories/{ws}/{repo}` → `200`.

### 5.5 Repo-side config has no himmel equivalent — out of code scope
`.github/CODEOWNERS` and `.github/mergeable.yml` are GitHub-specific.
Bitbucket uses default reviewers + branch restrictions + merge checks
(repo *settings*, not files in the repo). himmel's own gate (CR markers +
conventional-commit checks) is forge-agnostic and already enforces the intent.
→ Documented as a one-time setup note for Bitbucket users; **no himmel code.**

---

## 6. Integration-point inventory (what must route through the seam)

From the GitHub-surface map. Each becomes forge-dispatched:

| Area | Files (illustrative) | Phase |
|---|---|---|
| Handover PR open/merge | `scripts/handover/pr-open.sh`, `pr-merge.sh`, `flush.sh`, `generate-morning-briefing.sh` | 1 |
| Worktree prune (merged-PR detection) | `scripts/clean-garden.sh` | 1 |
| Worktree create (default branch, auth) | `scripts/_new-worktree.sh` | 1 |
| Pre-push / PR hooks | `scripts/hooks/check-pr-mergeable.sh`, `check-platforms-tested.sh`, `check-cr-marker-on-pr-create.sh` | 1 |
| Default-branch + behind-origin | `scripts/guardrails/lib.sh`, `scripts/cr/hermes-critic.sh` | 1 |
| User-slug resolution | `scripts/lib/user-slug.sh` | 1 |
| Auth / init | `plugins/himmel-gh/lib/init-flow.mjs`, `gh-init` skill | 1 |
| Interactive PR skills/commands | `plugins/himmel-gh/` (gh-pr-create/view/list/checks/merge) | 1 |
| CR deferred-issues | `scripts/cr/file-deferred-issues.sh` | 2 |
| Review threads | `plugins/himmel-gh/` (gh-pr-comments/reply/resolve), `lib/threads-*.mjs`, `graphql/*.gql` | 3 |
| luna-ingest (vault) | `marketplace/plugins/obsidian-triage/skills/luna-ingest/SKILL.md` | 4 |

CR-marker write path (`check-cr-before-push.sh`) is already forge-agnostic —
no change needed.

---

## 7. Phasing (one spec, four standalone PRs)

Each phase is an independent, mergeable PR. If an overnight run stops early,
every completed phase is coherent on its own. Phase 1 is the parity floor.

**Phase 0 (gate, part of Phase 1's PR): SDK selection.**
Evaluate `bitbucket` vs `@coderabbitai/bitbucket` via
`docs/tool-adoption/rubric.md` (maintenance, typing, Cloud coverage, license).
Pick one; record the decision in the PR. Default lean: `@coderabbitai/bitbucket`
for freshness + active maintenance, `bitbucket` if octokit-style ergonomics win.

**Phase 1 — Forge seam + dev-loop core.**
- `scripts/lib/forge.sh` (+ `forge-github.sh` lift-and-shift, `forge-bitbucket.sh`)
- `scripts/bitbucket/` CLI (SDK-backed): `pr create|merge|list`, `repo view`,
  `auth status`, `user`, JSON output
- `plugins/himmel-gh/lib/forge/` detect + backends; skills route
- Refactor Phase-1 integration points (§6) to call forge verbs
- `/gh-init` forge-aware
- **Exit:** a Bitbucket user can worktree → open PR → merge → clean-garden
  prune; the **full existing GitHub test suite stays green** (regression guard).

**Phase 2 — CR deferred-issues.**
- `forge_issue_create` + bitbucket CLI `issue create`
- `file-deferred-issues.sh` routes through the seam; issues-disabled fallback (§5.2)

**Phase 3 — PR review threads over REST.**
- bitbucket CLI `pr comments|reply|resolve`; reuse thread-cache
- `gh-pr-comments/reply/resolve` skills route; map flat-comment model (§5.3)

**Phase 4 — luna-ingest of Bitbucket.**
- bitbucket CLI `repo get` / `pr get` / `issue get` for ingestion
- `luna-ingest` SKILL recognizes `bitbucket.org` URLs, classifies + writes
  tech notes (parity with the GitHub ingest path)

For overnight dispatch, each phase maps to its own Jira ticket (HIMMEL-N) so
`/overnight-shift` can fan them out / sequence them.

---

## 8. Testing strategy

TDD throughout (global rule). The existing tests already use a `GH_CMD` env
override as a seam — generalize to a **forge-backend fake** so both backends
are testable without network:

- Unit-test `forge_detect()` against every remote URL shape (https/ssh,
  github/bitbucket, trailing `.git`, unknown → error).
- Each verb: a github-path test (existing suite, must stay green = the
  lift-and-shift regression guard) and a bitbucket-path test against a fake
  CLI/SDK returning recorded JSON fixtures.
- `bitbucket` CLI: unit tests mirroring `scripts/jira` (env parsing incl.
  CRLF strip, auth header shape, JSON output, error mapping) — no live network
  in CI.
- One **live smoke test** (manual / gated on creds present) against the real
  Bitbucket workspace once the token exists: create branch → PR → merge → list
  merged → prune. Documented, not in CI.

**Fake-backend contract (so both languages test offline, no network in CI):**
- **Shell:** a `BITBUCKET_CMD` env override (exact parallel to the existing
  `GH_CMD` seam) points `forge-bitbucket.sh` at a stub script that echoes
  fixture JSON instead of invoking the real CLI. `forge.sh` tests set
  `FORGE=bitbucket` + `BITBUCKET_CMD=<stub>`.
- **Plugin/CLI:** the himmel `bitbucket` CLI's own unit tests inject a fake
  SDK/transport; plugin-layer tests mock the **CLI** (not the SDK) so they
  exercise the same boundary shell tests do.
- **Fixtures:** recorded real responses live in
  `scripts/bitbucket/tests/fixtures/<verb>.json` (e.g. `pr-list-merged.json`,
  `user.json`, `repo.json`, `issues-disabled.json`). They are **captured
  during preflight (§9)** from the live API so fixtures match reality.
- **GitHub-coverage characterization (do FIRST in Phase 1):** before lifting
  any `gh` logic behind the seam, run the existing suite and record which
  GitHub verbs have test coverage. Any verb lacking a test gets a
  characterization test written **before** it is moved — otherwise the
  "test-suite-as-regression-guard" claim is hollow for that verb.

---

## 9. Preflight (MANDATORY before any implementation) & risks

> **STATUS: PF-0…PF-4 COMPLETED 2026-06-16** against workspace `example-ws`
> (throwaway repo created + torn down). Results are folded into §5.1/§5.2/§5.4/
> §5.6 above. The overnight run does NOT need to re-run preflight — but MUST
> re-confirm PF-0 (auth 200) as a cheap gate before coding, and halt if it fails.

The internal review surfaced two "blockers" that are not spec-writing problems
but **verify-against-the-real-API-first** problems. They are gated on the live
token and MUST be completed (and their outputs pasted into the Phase-1 PR)
**before** the corresponding code is written. An unattended run that skips
these is the single likeliest way to ship wrong, hard-to-reverse behavior.

- **PF-0 — Auth works.** `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN` (scoped
  Bitbucket token, §3) in `.env`; `GET /2.0/user` and
  `GET /2.0/workspaces?role=member` both return `200`. **Hard gate — without
  this every call 401s.** (Token created at id.atlassian.com → Security → API
  tokens → "Create API token with scopes" → Bitbucket. It can be a *second*
  token on the same Atlassian email as Jira — the Jira token is per-app and
  carries no Bitbucket scopes, verified 401.)
- **PF-1 — Identity shape (resolves review Blocker #1).** Record the exact
  `GET /2.0/user` JSON for this token: which of `nickname` / `account_id` /
  `uuid` is present. Drives §5.4. Capture to `tests/fixtures/user.json`.
- **PF-2 — Mergeability signal (resolves review Blocker #2).** On a throwaway
  branch in the test workspace, open a PR and inspect the PR object + available
  endpoints to determine the **concrete** un-mergeable/conflict signal (PR
  field, merge-checks endpoint, or the error shape of a dry-run/real merge).
  Then open a deliberately-conflicting PR and record that signal. Drives §5.1.
  Capture fixtures. Until PF-2 is settled, the BB merge path is NOT coded.
- **PF-3 — Issues-disabled status (resolves §5.2).** `POST .../issues` on a
  repo with the tracker off; record the exact status (`403` vs `404`) + body.
- **PF-4 — Scope sufficiency.** Exercise one call per verb family (repo read,
  PR create, PR merge, issue create, comment) to confirm the chosen scopes
  cover them; tighten §3 if any 403s on scope.

These are quick (minutes) and the operator can run them, or the run executes
them as its first step once the token is present. **No Phase-1 code lands
before PF-0–PF-2.**

### Risks

- **Primary risk: GitHub regression.** Phase 1 moves working `gh` logic behind
  the seam. Mitigation: lift-and-shift (move, don't rewrite) + the existing
  test suite as the green-bar gate + the GitHub-coverage characterization pass
  (§8) so untested verbs get a test *before* they move.
- **Scope risk:** four phases in one overnight is ambitious. Mitigation:
  standalone-PR-per-phase; partial completion still ships value.
- **SDK risk:** chosen SDK may lag the REST spec. Mitigation: thin wrapper —
  our CLI owns the verb surface, so swapping SDKs later touches one layer.
- **Bitbucket pagination + rate limits** differ from GitHub; the CLI handles
  `next`-link pagination centrally.

---

## 10. Out of scope

- Bitbucket Server / Data Center (self-hosted).
- Migrating himmel's own repo off GitHub.
- Replicating GitHub repo-side config (CODEOWNERS / mergeable.yml) as himmel
  code — documented as BB repo-settings setup instead (§5.5).
- OAuth / app-password auth flows (App Passwords are deprecated; scoped API
  token only).

---

## 11. Autonomous execution protocol (overnight)

The run executes phases **sequentially** (each builds on the seam from Phase 1),
each on **its own branch off `main`** = its own PR. himmel's overnight rule
applies: the deliverable is **PR-ready, not merged** — opening/merging order is
the morning operator loop, never the unattended run.

**Per-phase exit gate (ALL must hold before the phase PR is opened):**
1. New + existing unit tests green (incl. the GitHub regression suite, §8).
2. The phase's offline fake-backend tests pass (§8 contract).
3. For Phase 1: the live smoke test (§8) passes against the test workspace.
4. `/pr-check` (multi-agent CR) run on the branch and clean; CR marker cleared.
5. Attestation trailers present in the first commit (`Platforms tested:` on
   shell/script diffs; `Security reviewed:` on non-docs code) per repo rules.

**Failure semantics — halt, don't cascade.** If a phase fails its gate, the run
**stops** (does not start the next phase), writes a handover note (what passed,
the exact failing check, the PF/fixture outputs gathered so far), and leaves the
branch intact for morning. Later phases depend on Phase 1's seam, so proceeding
past a red Phase 1 would compound breakage.

**Resume.** Each phase = one Jira ticket (HIMMEL-N) under a parent epic. Resume
= re-dispatch the failed ticket; completed phases stay as their own
open/merged PRs and are not re-run (the seam from a merged Phase 1 is a normal
dependency for Phase 2+). Phase 0 (SDK pick) is recorded in Phase 1's PR
description and is a blocking prerequisite to writing Phase 1 code.

**Preflight first.** The very first action of the run is §9 PF-0…PF-4. If PF-0
(auth) fails, the run halts immediately with a one-line "token missing/invalid"
handover — nothing else is attempted.
