# Cloud brief template

The brief a console hands to `claude --cloud` for a small, well-scoped ticket
(HIMMEL-4206). A cloud session sees the repo clone plus the claude.ai MCP
connectors that are enabled for that session (see "claude.ai connectors in the
cloud" below), plus whatever plugins the environment's setup script installs (see below). It has no handover
state and no console inbox. A plugin uploaded on claude.ai (Customize, Plugins)
does NOT load in a cloud session: it only syncs as `<name>@synced`, and it also
syncs into every local terminal session, so do not use that route. The brief is
its working world, so it is self-contained. For a local leg, use
[`leg-brief-template.md`](leg-brief-template.md) instead.

`/cloud-route` (`scripts/lanes/cloud-route.mjs`) generates this brief for a
CLOUD-OK ticket and prints the launch line.

## What a cloud session has

| Has | Does not have |
|---|---|
| The clone's `CLAUDE.md`, `.claude/{skills,agents,commands,rules}`, `.mcp.json` (single-repo session only) | Plugins not in the environment's profile; claude.ai-uploaded plugins (sync as `@synced` only) |
| The repo's `.claude/settings.json` hooks and permissions | Your local `~/.claude` state; `settings.local.json` |
| Plugins the environment setup script installs (`--with-plugins` / `--plugins <list>`) and their hooks | Plugin hooks of plugins outside the profile (see [`cloud-hooks-proposal.md`](../internals/cloud-hooks-proposal.md)) |
| Skills enabled on claude.ai; claude.ai MCP connectors only when enabled for the session (Atlassian for Jira: read, comment, file follow-ups, transition) | The local jira CLI, luna, the console inbox; context7 by default (see below) |
| The environment setup script's installs (graphify, AST-only; qmd over the repo only, BM25); `CLAUDE_CODE_REMOTE=true` | Handover state; qmd over any vault; qmd vector search |

So the local shepherd stays mandatory: it runs `/pr-check`, the CR gate and the
merge. The cloud session ships a PR and stops.

The mechanical half of the shepherd is scripted (HIMMEL-4942):
`bash scripts/handover/console-kit/shepherd.sh <pr>` makes a detached worktree of
the PR head, runs the coverage lint, the impacted shell suites, `check-ci.sh` and
`ready-check.sh`, and prints one `SHEPHERD <pr> <head> READY-CANDIDATE|NEEDS-LEG
<reasons>` block (exit 0 / 1; 2 = usage or infra). It skips `CLOUD-ACK` steering
only when `CLOUD-DONE` is already posted, and it is read-only toward the PR. It
cannot run `/pr-check` (a model-session runbook): with no `ok` CR-ledger row for
the head it reports `panel: NOT-RUN` and the PR still needs a `/pr-check` round.
A clean candidate needs no shepherd leg; the console reads the diff, GOs and merges.

## claude.ai connectors in the cloud (probed 2026-10-08, HIMMEL-4971)

Probed from a cloud session launched with the generated brief: `ToolSearch`
found no `context7` or Atlassian tools, and `SearchMcpRegistry` reported both
Context7 and Atlassian MCP as `installState: connected` but
`enabledInChat: false`. A connector connected on the claude.ai account is not
thereby enabled in a cloud session, so the brief must not assume it:

- **context7: absent.** The brief's context7 line is conditional (use it if
  listed, else WebFetch the library's docs).
- **Atlassian: absent in the same probe.** The brief's Jira steps (claim,
  comment, file follow-ups) could not run; enable the connector for the session
  before launch, or the session reports the Jira steps as not done in its PR.

## Plugin hooks in the cloud (probed 2026-10-04, HIMMEL-4273)

Probed from a cloud session started in a `--with-plugins` environment:
`CLAUDE_CODE_REMOTE=true`, `HOME=/root`, `CLAUDE_PROJECT_DIR=/home/user/Himmel`,
`HIMMEL_REPO` unset. Plugins install at user scope (`/root/.claude/plugins`,
himmel-ops 0.4.22, lean-skills 0.2.2).

- **SessionStart plugin hooks fire.** `record-hook-integrity` and
  `record-primary-baseline` wrote
  `~/.claude/himmel/{hook-integrity,primary-baseline}/<session-id>.*`.
- **PreToolUse plugin hooks fire and block.** A probe `true || docker run
  --privileged ...` was refused by `block-docker-privesc` ("This hook comes from
  the himmel-ops@himmel plugin"). The runner path is
  `/tmp/himmel-setup/marketplace/plugins/himmel-ops/hooks/...`.
- **Paths behave.** The hook scripts resolve via
  `$CLAUDE_PROJECT_DIR/scripts/hooks/` in the session clone.
- **Repo hooks fire too, and the cloud clone counts as a PRIMARY checkout.**
  `block-edit-on-main` denies Edit/Write and `block-write-into-main-checkout`
  denies `git checkout` there, even on a feature branch. A cloud session must
  `git worktree add -b <type/slug> .claude/worktrees/<name> origin/main` and work
  inside it. This settles the open question in
  [`cloud-hooks-proposal.md`](../internals/cloud-hooks-proposal.md).
  `require-quiet-run` also refuses a bare suite run: wrap it as
  `bash scripts/quiet-run.sh suite -- <cmd>`.
- **Consequence.** In a plugin-profile environment the three guard-value plugin
  hooks (`block-docker-privesc`, `block-merged-pr-commit`,
  `block-unresolved-cr-merge`) are live, so option (b) of
  `cloud-hooks-proposal.md` is needed only for plugin-free environments.

## One-time operator setup

The recommended environment, field by field (name, network, environment
variables, setup script, CLI default via `/remote-env`, cache refresh), is
[`docs/setup/cloud-environment.md`](../setup/cloud-environment.md). The steps
below are the background and the plugin-free variant.

1. **Environment setup script.** At claude.ai, open the cloud environment's
   settings and paste into "Setup script":

   ```bash
   #!/bin/bash
   rm -rf /tmp/himmel-setup \
     && git clone --depth 1 https://github.com/yotamleo/Himmel /tmp/himmel-setup \
     && bash /tmp/himmel-setup/scripts/cloud/setup-env.sh || true
   ```

   Keep the trailing `|| true`: a non-zero setup script stops the session from
   starting, and a failed clone or step should cost a tool, not the session.
   It installs shellcheck, `at`, pre-commit, builds the Jira CLI dist (no
   secret) and installs the obsidian-triage tool deps. It is idempotent and
   bounded to fit the platform's roughly 5-minute setup cache. Set
   `BASH_DEFAULT_TIMEOUT_MS=600000` and `BASH_MAX_TIMEOUT_MS=600000` in the
   environment's own "Environment variables" field: a cloud probe showed that
   field is the only route that reaches the Bash tool (HIMMEL-4429).
   Network access: "Trusted" is enough for apt, pip and npm.
2. **Skills.** `bash scripts/cloud/package-skills.sh` writes one zip per skill
   under `${TMPDIR:-/tmp}/himmel-cloud-skills`. Upload each at claude.ai
   (Settings, Skills). The list is `test-driven-development`,
   `systematic-debugging` and `verification-before-completion`: skill-only,
   self-contained, and what a small fix/test/PR brief reaches for. `test-audit`
   and `unslop` already ship under the repo `.claude/skills` and load from the
   clone, so they are not bundled. Verify once: start a cloud session and ask it
   to list its skills.
3. **Plugin profile (dedicated environment).** Create a SEPARATE cloud
   environment for plugin sessions; the plain one stays plugin-free. Paste the
   setup script with the flag:

   ```bash
   #!/bin/bash
   rm -rf /tmp/himmel-setup \
     && git clone --depth 1 https://github.com/yotamleo/Himmel /tmp/himmel-setup \
     && bash /tmp/himmel-setup/scripts/cloud/setup-env.sh --with-plugins || true
   ```

   `--with-plugins` installs the lean set (himmel-ops, lean-skills). To control
   exactly which load, use `--plugins himmel-ops,lean-skills,<more>` instead.
   - The step is non-fatal: a failed install warns and the session still starts
     (a non-zero setup script would block the session).
   - Cache refresh: plugins install from `/tmp/himmel-setup`, a clone frozen into
     the environment cache. They refresh only when the setup script text changes
     or the cache expires (about 7 days). To force a refresh, edit the script
     (for example bump a `# rev:` comment line). Plugin hook runners resolve
     `${CLAUDE_PLUGIN_ROOT}` to that frozen clone while the hook scripts come
     from the session clone (`$CLAUDE_PROJECT_DIR/scripts/hooks/`), so a stale
     cache can pair an old runner with new scripts.
   - Verified 2026-10-04 (HIMMEL-4273): 10 `himmel-ops:` and 13 `lean-skills:`
     skills listed.

## Brief sections (reproduce in order)

1. **Opening.** `You are working in a cloud clone of the GitHub repo
   yotamleo/Himmel. This is a small, well-scoped task. Work only from this brief
   and the repo. You have no local state. Jira is reachable through the Atlassian
   MCP connector (the local jira CLI is absent in the cloud): read the ticket,
   comment, file follow-ups with the fixVersion this brief names, and cite the
   ticket key in your commits and the PR. If the context7 MCP tools are listed
   in this session, use them for current library docs; otherwise WebFetch the
   library's own docs.`
2. **`## Ticket HIMMEL-<n> (verbatim from Jira)`** — key, type, status, title,
   then the description unedited, then `Fix versions:`.
3. **`## The change`** — what to do, "verified against main on <date>", with line
   numbers marked approximate ("find the code by its text"). Name the files.
4. **`## How to do it`** — numbered:
   1. Read `CLAUDE.md` and the named files in full before editing.
   2. Claim the ticket: through the Atlassian MCP, transition it to
      `In Progress` (see "What replaces the handover and the lock" below).
   3. Create the branch as a worktree BEFORE any edit:
      `git worktree add -b <type>/himmel-<n>-<slug> .claude/worktrees/<name> origin/main`,
      and work there (the repo's edit-on-main guard denies edits in the cloud's
      primary clone, even on a feature branch).
      If repo retrieval is needed, run `bash scripts/cloud/setup-env.sh` inside
      this worktree first. Query `graphify query "<question>" --graph graphify-out/graph.json`,
      not the unclassified cached `/tmp` graph. Search with
      `bash scripts/lib/qmd-bounded.sh search "<terms>" -c himmel`, never bare
      qmd search or a vault collection. The wrapper finds the installed bun-global
      tool even without a qmd shim on PATH.
   4. Edit ONLY the named files; keep the diff minimal and in the surrounding style.
   5. Write the new or changed test FIRST and show it RED without the fix, then
      green. Run `shellcheck` on every `.sh` file touched.
   6. Make exactly ONE commit, never amend. Then, before pushing, run the
      impacted suites (the selector reads the COMMITTED range, so it sees
      nothing before the commit): `bash scripts/cr/impacted-suites.sh origin/main..HEAD --shell`
      lists every suite that references a changed file, and
      `bash scripts/ci/run-shell-tests.sh --impacted origin/main..HEAD` runs
      them. Do not run only the one test the ticket names. Report rc and the
      PASS/FAIL tail of each. A red suite is fixed in a NEW commit, never an
      amend.

          <type>: [HIMMEL-<n>] <subject>

          <2-4 line body>

          Platforms tested: linux
          Security reviewed: manual — <what you checked>

   7. Push, open a PR to `main` titled as the commit. The body carries a summary,
      the files changed, the test/shellcheck/impacted-suite results, the line
      `cloud-pilot: HIMMEL-<n> (<console id>)`, the `completes-ticket:` line and
      the `## Ticket coverage` section below.
   8. Turn on `/autofix-pr` for the PR, so the session fixes its own CI reds and
      review comments before the shepherd picks it up.
   9. Do NOT merge, do NOT request reviewers, do NOT touch any other file.
   10. Report: one top-level PR comment whose first line is
       `CLOUD-DONE <session URL>`, then the head SHA and test results; then a
       comment on the ticket (Atlassian MCP) with the PR URL. Leave the ticket
       `In Progress`. Once a local shepherd comments on the PR, stop pushing.
5. **Closing.** `When done, print the PR URL, the branch, the commit SHA, and a
   3-line summary.`

## What replaces the handover and the lock

A local leg is held together by its handover doc (status bullets the console's
tick reads), a queue lock on that doc, and SendMessage to the console. A cloud
session has none of the three: no luna, no `queue-lock.sh` state, and no inbox
(SendMessage cannot reach a local session from the cloud). It works on four
substitutes, all of them on GitHub or Jira, which it reaches:

| Local leg | Cloud session |
|---|---|
| One handover doc per leg | One ticket = one branch = one PR. The PR body (summary, results, `## Ticket coverage`) is the record |
| Queue lock on the doc | The ticket's Jira status: `In Progress` + an open `cloud-pilot:` PR means taken. The console dispatches no second session on it |
| `LIVE` / `READY` / `WRAPPED` bullets | One `CLOUD-DONE <session URL>` top-level PR comment when the PR is up; the console polls the PR with `gh` (no callback exists) |
| `BLOCKED` / `FINDING` to the console | A `CLOUD-BLOCKED <session URL>` PR comment (or, before a PR exists, a ticket comment) stating the question, then end the session; the console answers with `claude -p "<msg>" --cloud <session>` |
| Jira close at merge | Unchanged: the local shepherd merges and closes; the session never transitions past `In Progress` |

The `CLOUD-<MARKER>` first-line shape matches the `CLOUD-ACK` reply proven on
2026-10-04 and the reader HIMMEL-4277 builds into the tick.

## PR body contract

```markdown
completes-ticket: yes|no

## Ticket coverage
- <ask 1 of the ticket> — done
- <ask 2> — deferred → HIMMEL-<n>
```

- **One line per ask** of each cited ticket, each `done` or `deferred → HIMMEL-<n>`
  (HIMMEL-4207: the console's ready-check fails a missing section, a deferred key
  that does not exist and one already Done). The console files a follow-up
  ticket for every ask the brief scopes out BEFORE writing the brief and names
  each key in `## The change`; the session writes it as `deferred → HIMMEL-<n>`.
  An ask is never silently dropped: no key to name means the ask belongs in the
  brief, not outside it. An ask the session finds mid-task and cannot finish is
  filed by the session itself through the Atlassian MCP connector (with the
  fixVersion the brief names) and written as `deferred → HIMMEL-<n>`; the
  shepherd confirms the key before GO.
- `completes-ticket: yes` only when every ask is either `done` or `deferred →`
  an open follow-up key the shepherd confirms before passing
  `--jira-transition`; otherwise `no`.
- The PR title and the commit carry the ticket ID (`check-commit-msg`, CI range gate).

## Launching

```bash
claude --cloud "$(cat cloud-brief-HIMMEL-<n>.md)" --permission-mode auto
```

Steering a running session is headless (`claude -p "<msg>" --cloud <id>`) and
draws the same bank as interactive use (see CLAUDE.md, "Claude invocation
billing"). There is no completion callback: the shepherd polls the PR with `gh`.
A cloud session reports back to the console only when the console is connected
to Remote Control; do not rely on it, and brief the session to end on the PR URL.
