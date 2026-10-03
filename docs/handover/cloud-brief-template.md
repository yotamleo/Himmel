# Cloud brief template

The brief a console hands to `claude --cloud` for a small, well-scoped ticket
(HIMMEL-4206). A cloud session sees the repo clone and nothing else: no Jira, no
handover state, no plugins, no `~/.claude`, no console inbox. The brief is its
whole world, so it is self-contained. For a local leg, use
[`leg-brief-template.md`](leg-brief-template.md) instead.

## What a cloud session has

| Has | Does not have |
|---|---|
| The clone's `CLAUDE.md`, `.claude/{skills,agents,commands,rules}`, `.mcp.json` (single-repo session only) | Plugins and marketplaces (himmel-ops, lean-skills, qmd, handover) |
| The repo's `.claude/settings.json` hooks and permissions | Anything under `~/.claude`; `settings.local.json` |
| Skills enabled on claude.ai | Jira, qmd, graphify, luna, the console inbox |
| The environment setup script's installs; `CLAUDE_CODE_REMOTE=true` | Plugin-provided hooks (see [`cloud-hooks-proposal.md`](../internals/cloud-hooks-proposal.md)) |

So the local shepherd stays mandatory: it runs `/pr-check`, the CR gate and the
merge. The cloud session ships a PR and stops.

## One-time operator setup

1. **Environment setup script.** At claude.ai, open the cloud environment's
   settings and paste into "Setup script":

   ```bash
   #!/bin/bash
   rm -rf /tmp/himmel-setup \
     && git clone --depth 1 https://github.com/yotamleo/Himmel /tmp/himmel-setup \
     && bash /tmp/himmel-setup/scripts/cloud/setup-env.sh
   ```

   It installs shellcheck, `at`, pre-commit, builds the Jira CLI dist (no
   secret), installs the obsidian-triage tool deps and sets
   `BASH_DEFAULT_TIMEOUT_MS`/`BASH_MAX_TIMEOUT_MS` to 600000. It is idempotent
   and bounded to fit the platform's roughly 5-minute setup cache. Also set both
   timeout variables in the environment's own "Environment variables" field: that
   field is the documented route, the script's profile.d write is a fallback.
   Network access: "Trusted" is enough for apt, pip and npm.
2. **Skills.** `bash scripts/cloud/package-skills.sh` writes one zip per skill
   under `${TMPDIR:-/tmp}/himmel-cloud-skills`. Upload each at claude.ai
   (Settings, Skills). The list is `test-driven-development`,
   `systematic-debugging` and `verification-before-completion`: skill-only,
   self-contained, and what a small fix/test/PR brief reaches for. `test-audit`
   and `unslop` already ship under the repo `.claude/skills` and load from the
   clone, so they are not bundled. Verify once: start a cloud session and ask it
   to list its skills.
3. **Plugin experiment (optional, undocumented).** `setup-env.sh --with-plugins`
   tries `claude plugin marketplace add` plus `claude plugin install` into the
   VM's `~/.claude`. Run it on one session; if the session does not list the
   plugin skills, the answer is "no" and the flag stays off.

## Brief sections (reproduce in order)

1. **Opening.** `You are working in a cloud clone of the GitHub repo
   yotamleo/Himmel. This is a small, well-scoped task. Work only from this brief:
   you cannot reach Jira or any local state.`
2. **`## Ticket HIMMEL-<n> (verbatim from Jira)`** — key, type, status, title,
   then the description unedited, then `Fix versions:`.
3. **`## The change`** — what to do, "verified against main on <date>", with line
   numbers marked approximate ("find the code by its text"). Name the files.
4. **`## How to do it`** — numbered:
   1. Read `CLAUDE.md` and the named files in full before editing.
   2. Create branch `<type>/himmel-<n>-<slug>` from `main` BEFORE any edit (the
      repo's edit-on-main guard denies edits on `main`).
   3. Edit ONLY the named files; keep the diff minimal and in the surrounding style.
   4. Write the new or changed test FIRST and show it RED without the fix, then
      green. Run `shellcheck` on every `.sh` file touched.
   5. Make exactly ONE commit, never amend. Then, before pushing, run the
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

   6. Push, open a PR to `main` titled as the commit. The body carries a summary,
      the files changed, the test/shellcheck/impacted-suite results, the line
      `cloud-pilot: HIMMEL-<n> (<console id>)`, the `completes-ticket:` line and
      the `## Ticket coverage` section below.
   7. Turn on `/autofix-pr` for the PR, so the session fixes its own CI reds and
      review comments before the shepherd picks it up.
   8. Do NOT merge, do NOT request reviewers, do NOT touch any other file.
5. **Closing.** `When done, print the PR URL, the branch, the commit SHA, and a
   3-line summary.`

## PR body contract

```markdown
completes-ticket: yes|no

## Ticket coverage
- <ask 1 of the ticket> — done
- <ask 2> — deferred → HIMMEL-<n>
```

- **One line per ask** of each cited ticket, each `done` or `deferred → HIMMEL-<n>`
  (HIMMEL-4207: the console's ready-check fails a missing section, a deferred key
  that does not exist and one already Done). The cloud session cannot reach Jira,
  so the console files a follow-up ticket for every ask the brief scopes out
  BEFORE writing the brief and names each key in `## The change`; the session
  writes it as `deferred → HIMMEL-<n>`. An ask is never silently dropped: no
  key to name means the ask belongs in the brief, not outside it. An ask the
  session finds mid-task and cannot finish is reported in its closing summary
  and the shepherd files the key before GO.
- `completes-ticket: yes` only when every ask is `done`; any `deferred` line
  means `no` (or a `yes` whose every deferral names an open follow-up key, which
  the shepherd confirms before passing `--jira-transition`).
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
