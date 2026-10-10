# Cloud environment: from nothing to a working `claude --cloud` session

How an adopter gets `claude --cloud` sessions on **their own fork** of himmel
starting with the harness working (HIMMEL-4429, HIMMEL-5163). The cloud lane
runs small, well-scoped tickets on an Anthropic-managed VM and opens a PR; a
local shepherd then reviews and merges it. What a session has, and why the
shepherd is mandatory, is in
[`cloud-brief-template.md`](../handover/cloud-brief-template.md). Platform
reference: [cloud environments](https://code.claude.com/docs/en/cloud-environments).

## Why this is a paste, not a command

Checked against the docs and the CLI on 2026-10-10 (HIMMEL-5163):

| Question | Answer | Source |
|---|---|---|
| Create or declare an environment from a repo file? | **No.** The dialog is the only path; the setup script is "entered in the Setup script field" of the environment settings dialog | [cloud-environments](https://code.claude.com/docs/en/cloud-environments) |
| Create one from a command or API? | **No.** `/remote-env` "only sets the default: it doesn't start a session, and it can't add or edit environments". `claude --help` has no environment subcommand | same page; `claude --help` (2.1.296) |
| Read an environment's script or variables back from the CLI? | **No.** `/remote-env` lists names and IDs only | same page |
| Detect that the dialog differs from the repo? | **No platform mechanism.** A session sees `CLAUDE_CODE_REMOTE=true` and the variables you set | same page |

The Managed Agents environments API (`POST /v1/environments`,
`ant apply environment.yaml`) is a different product: API-key billed, its own
sessions, no env-var or setup-script field, and nothing connects it to
`claude --cloud`. It does not apply here.

So himmel keeps the dialog's content in **one checked-in source** and checks the
dialog against it:

| File | Role |
|---|---|
| `scripts/cloud/environment.env` | The environment variables and the setup-script `# rev:` |
| `scripts/cloud/setup-env.sh` | The setup script itself; the dialog only clones the repo and runs it |
| `scripts/cloud/check-env.sh` | `--print` renders the dialog's fields; with no argument a session checks itself |

## Prerequisites

- A Claude subscription with Claude Code on the web (claude.ai/code), and the
  `claude` CLI on your machine.
- Your fork of himmel on GitHub, with the **Claude GitHub app** installed on it:
  at claude.ai/code connect GitHub and grant the app access to the fork, or run
  `/web-setup` in a local terminal. The platform's GitHub proxy then
  authenticates `git` and `gh` inside the VM, so no token of yours enters it.
- The fork's `origin` set on the checkout you run the commands below from.

## Create the environment

1. From your fork's checkout, print the fields (it uses your `origin` as the
   clone URL, so a fork gets its own URL):

   ```bash
   bash scripts/cloud/check-env.sh --print
   ```

2. At [claude.ai/code](https://claude.ai/code), select the cloud icon above the
   message box, then **Cloud**, then **Add cloud environment**. Paste the
   printed fields: **Name** `himmel`, **Network access** `Trusted`,
   **Environment variables** (the printed block), **Setup script** (the printed
   block).

Notes on the fields:

- Everyone who uses the environment can read the variables, so **never put a
  secret there**. The cloud has no Jira token on purpose: Jira goes through the
  claude.ai Atlassian connector, not the local jira CLI.
- Leave `GH_TOKEN` and `GITHUB_TOKEN` unset so the GitHub proxy authenticates.
- The two Bash timeouts must be set in this field: it is the only place they
  reach the Bash tool (HIMMEL-4429).
- Keep the setup script's trailing `|| true`: a non-zero setup script stops the
  session from starting, and a failed step should cost a tool, not the session.
- The setup script installs shellcheck, `at` and pre-commit, builds the Jira CLI
  dist, installs the obsidian-triage deps and the lean plugin profile
  (himmel-ops, lean-skills; a claude.ai plugin upload never loads in a cloud
  session), then graphify and qmd over the repo (HIMMEL-4726). Each build is
  bounded by `timeout` and a failure costs only that tool. Its last step stamps
  the script's hash for the self-check below.
- **Network access** `Trusted` covers GitHub, npm, PyPI and the Ubuntu
  archives, which is everything the setup and a session reach. Atlassian needs
  no entry: connector traffic goes through Anthropic, not the VM's network.
  Pick **Custom** only for a host outside that list, and tick "Also include
  default list of common package managers".

## Make it the CLI default

`claude --cloud` does not use the claude.ai selector. In a local terminal run
`/remote-env` once and pick `himmel`; it saves `remote.defaultEnvironmentId` in
your user settings. Without it the CLI falls back to the Anthropic-hosted
**Default** environment, which has no setup script.

## First session

```bash
claude --cloud "reply with the word ready, change nothing"
```

The first session runs the setup script (about five minutes); watch it at the
session URL the command prints. If it finishes inside about five minutes the
platform snapshots the filesystem and later sessions start from the snapshot.

## Verify it

In the session, run:

```bash
bash scripts/cloud/check-env.sh
```

Expect `env <NAME> ok` for each variable and `setup-script ok`, exit 0. A
mismatch is named on its own line and exits 1:

| Line | Meaning | Fix |
|---|---|---|
| `env <NAME> MISMATCH expected=... actual=...` | The dialog's variable differs from `environment.env` | Fix the dialog from `check-env.sh --print`, then start a **new** session (a resumed one keeps the values it last read) |
| `setup-script STALE` | The cached snapshot ran an older `setup-env.sh` than this clone's | Bump `# rev:` in the dialog's setup script (and in `environment.env`) to rebuild the snapshot |
| `setup-script MISSING` | No stamp: the setup never finished, or the dialog does not run `setup-env.sh` | Read `/tmp/himmel-setup-logs/` for the failed step, or re-paste the setup script |

What the check cannot see: the bootstrap text in the dialog (the clone URL and
flags) is not readable from inside the VM, so a changed URL shows only as a
missing or stale stamp. The check is also not wired into a SessionStart hook
yet: a cloud brief or the operator runs it by hand.

Then the tool probe:

```bash
echo CLAUDE_CODE_REMOTE=$CLAUDE_CODE_REMOTE BASH_DEFAULT_TIMEOUT_MS=$BASH_DEFAULT_TIMEOUT_MS
shellcheck --version | sed -n 2p
ls ~/.claude/plugins
# Inside the session's repo worktree, not /tmp/himmel-setup:
bash scripts/cloud/setup-env.sh
graphify query "cloud route classification" --graph graphify-out/graph.json
bash scripts/lib/qmd-bounded.sh collection list
bash scripts/lib/qmd-bounded.sh search "cloud environment" -c himmel
```

Expect `CLAUDE_CODE_REMOTE=true`, `BASH_DEFAULT_TIMEOUT_MS=600000`, a shellcheck
version, a plugins directory, a `Graph: ... nodes` line, exactly one collection
(`himmel`) and hits from `docs/`. Then ask the session to list its skills: the
`himmel-ops:` and `lean-skills:` skills should be there.

## What the cloud has, and what stays local

| The cloud has | How |
|---|---|
| Hooks | The repo's `.claude/settings.json`; plugin hooks through the setup script's plugin step (probed, HIMMEL-4273) |
| graphify | Pinned at `scripts/lib/graphify-bin.sh`, no backend extra, AST-only (`graphify update .`): it parses code locally and calls no model |
| qmd, repo only | The pinned fork and one collection, `himmel`, rebuilt on every setup run. BM25 only; a ticket that needs `qmd query`, vector search or another collection routes LOCAL-NATIVE |
| Jira | The claude.ai Atlassian MCP connector, enabled for the session |

| Stays local | Why |
|---|---|
| luna and any other vault | Private vault data never leaves the station (`scripts/guardrails/egress-matrix.json`) |
| Handover state | It lives in the state repo, which the cloud cannot reach; a cloud session reports through its PR |
| A Jira token | Not in the environment on purpose; use the Atlassian connector |
| Lane tickets (claudex, codex or another lane) | Cloud is Claude only; `/cloud-route` routes them LOCAL |
| The console bridge and the hook-integrity bypass | Local launching-shell state; a ticket that edits `scripts/hooks/` routes HOOK-BYPASS |

The cached graph and index live in `/tmp/himmel-setup`, a frozen clone. In the
session's own worktree run `bash scripts/cloud/setup-env.sh` to rebuild both
against that checkout. Never run a semantic `/graphify` extraction in the cloud:
it would send content to a model backend.

## How a cloud PR lands

1. `/cloud-route` classifies a ticket CLOUD-OK, writes the brief and prints the
   launch line; you run it (`claude --cloud "<brief>"`).
2. The session works in a worktree, opens the PR and posts one top-level comment
   whose first line is `CLOUD-DONE <session URL>`, then the head SHA and test
   results. A block it cannot resolve is posted as `CLOUD-BLOCKED <session URL>`.
3. A **local shepherd** takes it from there: `bash
   scripts/handover/console-kit/shepherd.sh <pr>` runs the coverage lint, the
   impacted suites, CI and the ready check; `/pr-check` and the CR gate run
   locally, and the console merges on `GO`. The cloud session never merges and
   stops pushing once the shepherd comments.
4. The ticket stays `In Progress` until the merge closes it.

## Cache and refresh

- The snapshot is rebuilt when the setup script text or the allowed network
  hosts change, and when it expires after about seven days. Plugins come from
  the frozen `/tmp/himmel-setup` clone, so a change on `main` reaches new
  sessions only after a rebuild: bump `# rev:` in `environment.env`, re-print and
  re-paste the script.
- A paused session that resumes does not re-run the setup script and keeps the
  variables it last read. Start a new session to pick up a change.
