# Using himmel on your own project

> This doc is for adopters — someone bringing himmel's hooks and worktree
> workflow to **their own repo**, not someone developing himmel itself.
> If you are setting up a new machine to work on himmel, see
> [`docs/setup/new-machine.md`](new-machine.md) instead.

himmel ships a portable core that works in any git repo: three Claude
PreToolUse hooks, a shared guardrails library, and worktree commands.
Everything else (Jira, luna/Obsidian, Telegram, hermes, clipper pipeline)
is operator-personal and safely skippable.

---

## Quickest path — one-shot adopt

From a himmel clone, `scripts/adopt.sh` (or `adopt.ps1` on Windows) brings the
whole harness over in **one command**. Pick a **profile** (a logical block) and
a **scope**:

```bash
# The himmel harness — portable hooks + guardrails + worktree commands +
# marketplace plugins/skills — wired into YOUR repo (project scope). Commit the
# result and anyone who clones the repo gets it:
bash scripts/adopt.sh --profile core --scope project --target /path/to/your/repo

# ...or at user scope (enabled for you in every project on this machine):
bash scripts/adopt.sh --profile core --scope user

# core + the luna second-brain vault scaffold (the vault goes to --luna-target,
# default ~/Documents/luna; core still goes to --target):
bash scripts/adopt.sh --profile all --scope project --target /path/to/your/repo
```

Windows: `pwsh scripts/adopt.ps1 -Profile core -Scope project -Target C:\path\to\repo`.

| Profile | Brings |
|---------|--------|
| `core` | portable hooks + guardrails + worktree commands + the marketplace plugins/skills + a requirements check |
| `luna` | the luna second-brain vault scaffold (`templates/luna-second-brain`) |
| `all`  | `core` + `luna` |

`--scope project` copies the scripts into your repo and wires its
`.claude/settings.json`; `--scope user` wires `~/.claude/settings.json` to
reference the himmel clone. `--dry-run` previews; re-running is idempotent.
(jira / qmd / telegram / handover stay à-la-carte — install those separately.)

**Want only PARTS?** The manual steps below install just the portable hooks +
worktree workflow; [`new-machine.md §6`](new-machine.md#scope-user-vs-project)
covers installing just the plugins at a chosen scope; the
[luna template README](../../templates/luna-second-brain/README.md) covers just
the vault.

---

## What you get out of the box

Three hooks are portable — they have no himmel-specific dependencies and
go inert cleanly when the subsystems they reference are absent:

| Hook | What it does | Inert-when |
|------|-------------|------------|
| `scripts/hooks/auto-approve-safe-bash.sh` | Grants permission for read-only Bash commands that include `$var` / pipes, bypassing Claude Code's static matcher which hangs on those. Fails open — never blocks. | Always active (has no external deps). |
| `scripts/hooks/block-edit-on-main.sh` | Blocks Edit/Write/MultiEdit/NotebookEdit when HEAD == main, forcing work into worktrees. | — |
| `scripts/hooks/block-read-secrets.sh` | Blocks Bash/Read/Grep calls that would surface `.env`, `*.pem`, `id_rsa`, and similar files to Claude as tool results. | — |

Three more hooks in `.claude/settings.json` go **inert cleanly** when their
subsystems are missing:

- `block-backend-tier.sh` — registry-driven backend-routing guard (CLI→API→MCP);
  blocks an MCP call (e.g. Atlassian Jira) when the local CLI covers the verb.
  With no Jira/backend setup, no such calls are made, so the hook never fires.
- `auto-arm-on-cap.sh` + `auto-arm-on-subagent-cap.sh` — usage-cap watchdog.
  Requires a claude-statusline usage cache at `/tmp/claude/statusline-usage-cache.json`.
  Without it the hook exits 0 silently on every check.

---

## Minimal install — no Jira, no luna, no Telegram

### 1. Prerequisites

You need: `bash` 3.2+, `git`, `jq`, `python3`. That is the full dependency
set for the three portable hooks. `gh` is needed only for the worktree prune
step that checks merged PRs; without it the prune falls back to the `[gone]`
git signal.

### 2. Copy the portable files

From the himmel repo into your project:

```
scripts/hooks/auto-approve-safe-bash.sh
scripts/hooks/block-edit-on-main.sh
scripts/hooks/block-read-secrets.sh
scripts/guardrails/lib.sh
scripts/guardrails/guard-gh.sh          # optional — only needed for /gh-pr-create + /gh-pr-merge
scripts/clean-garden.sh                 # worktree orchestrator
scripts/worktree.sh                     # thin wrapper: create-only
scripts/clean.sh                        # thin wrapper: prune-only
scripts/_new-worktree.sh                # called by clean-garden.sh
scripts/lib/py-armor.sh                 # required by block-edit-on-main
```

Keep the relative paths — `block-edit-on-main.sh` sources
`../guardrails/lib.sh` and `../lib/py-armor.sh` relative to its own
location.

### 3. Wire the hooks in `.claude/settings.json`

The hooks resolve themselves relative to `$CLAUDE_PROJECT_DIR`, the env
var Claude Code sets to the project root when a hook fires. Add a
`.claude/settings.json` to your repo with these three stanzas:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/auto-approve-safe-bash.sh"
          }
        ]
      },
      {
        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh"
          }
        ]
      },
      {
        "matcher": "Bash|PowerShell|Read|Grep",
        "hooks": [
          {
            "type": "command",
            "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/block-read-secrets.sh"
          }
        ]
      }
    ]
  }
}
```

`$CLAUDE_PROJECT_DIR` is set by Claude Code to the directory where it found
`.claude/settings.json`. It must be the repo root — run `claude` from the
root and keep `.claude/` at the top level, not a subdirectory.

### 4. Make the hook scripts executable

```bash
chmod +x scripts/hooks/auto-approve-safe-bash.sh \
         scripts/hooks/block-edit-on-main.sh \
         scripts/hooks/block-read-secrets.sh \
         scripts/guardrails/lib.sh \
         scripts/lib/py-armor.sh
```

### 5. Verify

Start a Claude Code session from your repo root. The hooks fire immediately:

- Open any file: Claude should NOT prompt for Edit permission on main —
  instead `block-edit-on-main` blocks it with a message.
- Create a branch and a worktree (next section) — edits on the worktree
  branch proceed normally.
- Try `cat .env` (if you have one): `block-read-secrets` should block it.

---

## Worktree workflow

himmel's worktree commands keep work off `main` and make pruning safe.

### Commands

All three delegate to `scripts/clean-garden.sh`:

```bash
# Create only — branch must be type/slug (feat|fix|chore|docs|refactor|test)
bash scripts/worktree.sh feat/my-feature

# Prune only — removes worktrees whose PR is merged (or git marks [gone])
bash scripts/clean.sh

# Prune + create in one shot
bash scripts/clean-garden.sh feat/my-feature
```

Worktrees are created under `.claude/worktrees/<type>+<slug>/` next to the
`.claude/` directory (not inside it).

### Slash commands (optional)

If you expose himmel's `.claude/commands/` directory to Claude Code, the
same operations are available as `/worktree`, `/clean`, `/clean_garden`.
Copy or symlink `.claude/commands/worktree.md`, `clean.md`, and
`clean_garden.md` from the himmel repo.

### `block-edit-on-main` and worktrees

The hook blocks edits when HEAD == main. Once you create a worktree and
Claude Code opens it, HEAD is the feature branch and edits proceed normally.
Bypass for a deliberate exception: set `EDIT_ON_MAIN_OK=1` in the shell that
launches Claude Code (`EDIT_ON_MAIN_OK=1 claude`). The bypass lasts for that
session only.

---

## Operator-personal subsystems — safely skip all of these

These subsystems are not part of the portable core. Skipping them has no
effect on the three portable hooks or the worktree workflow.

| Subsystem | What it is | Skip signal |
|-----------|-----------|-------------|
| **Jira** (`scripts/jira/`) | Local Jira CLI + `block-backend-tier.sh` hook. | `setup.sh --with-jira` activates the Jira path; without the flag setup completes cleanly and the hook never fires. |
| **luna / Obsidian** (`scripts/luna/`, `docs/luna/`) | Vault management, clip pipeline, `obsidian-second-brain` plugin. | Entirely absent from the portable core. |
| **Telegram** (`scripts/telegram/`) | Bot poller + bridge for sending/receiving Claude messages via Telegram. | Absent unless you configure a bot token. |
| **hermes** (`scripts/hermes/`) | Free-model junior-tier routing (flash, OpenRouter). | Absent unless you configure API keys. |
| **Clipper pipeline** (`marketplace/plugins/obsidian-triage/`) | Harvest → triage → synthesize → archive workflow for Obsidian web clips. | Depends on luna vault. Skip with luna. |
| **Handover system** (`scripts/handover/`) | Cross-session state persistence + auto-resume. | Functional with just `./handovers/` dir; external `HANDOVER_DIR` is optional. The cap-watchdog hooks reference it but fail-open if unresolvable. |
| **overnight mode** (`scripts/overnight/`) | Unattended multi-ticket dispatch. | Depends on handover + Jira. |

---

## Adding Jira later

When you are ready to add Jira:

1. Create `.env` (copy `.env.example` if present) and fill in:
   ```
   JIRA_PROJECT_KEY=YOUR_KEY
   JIRA_BASE_URL=https://your.atlassian.net
   JIRA_API_TOKEN=...
   JIRA_EMAIL=...
   ```
2. Run `bash scripts/setup.sh --with-jira` — this builds the Jira CLI and
   validates your credentials.
3. Add the `block-backend-tier.sh` stanza to `.claude/settings.json`
   (see [`docs/internals/enforcement.md`](../internals/enforcement.md) for the
   exact matcher + command).

---

## Pre-commit hooks (optional but recommended)

himmel's pre-commit gates work independently of Claude Code. The most
useful one for a generic repo:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: <the himmel remote URL you cloned from>
    rev: <pin-a-commit-sha>   # pin; himmel has no semver tags yet
    hooks:
      - id: worktree-isolation   # blocks commits directly on main
```

See [`docs/internals/enforcement.md`](../internals/enforcement.md) for the
full pre-commit hook inventory and the `pr-lane-isolation` alternative for
repos that allow some direct-to-main commits.

---

## Doc-freshness advisory (opt-in, HIMMEL-587)

himmel's doc-freshness feature notices when a `feat`/`fix` commit touches a
mapped source file without also touching its required doc, and surfaces an
advisory nudge — never a hard block.

**How to opt in for your project:**

1. **Drop your own `scripts/hooks/doc-guard-map.tsv`** pointing at YOUR docs:

   ```
   # strength	trigger	path-regex	required-doc
   advise	modify	^src/api/	docs/api-reference.md
   advise	modify	^src/cli/commands/	docs/commands.md
   ```

   **Important:** columns must be separated by literal tab characters — the
   loader reads `IFS=$'	'`; space-separated rows are silently skipped.

   The path-regex matches against files changed in the commit range (relative
   to the repo root). The required-doc path is also repo-relative.

   If you want the **blocking** gate too, add `block / add` rows — but note
   the block gate is himmel-dev-only (gated by `.himmel-dev`), so it fires
   only when you place a `.himmel-dev` marker at your repo root.

2. **Enable the advisory legs** by setting `HIMMEL_DOC_FRESHNESS` in your
   himmel `.env` (uncomment the line added by HIMMEL-587):

   ```bash
   HIMMEL_DOC_FRESHNESS=all     # advise + session + morning
   # or a subset:
   # HIMMEL_DOC_FRESHNESS=session,advise
   ```

   The `session` and `morning` legs read this from `.env` via
   `scripts/lib/load-dotenv.sh`; the `advise` leg reads it at `/pr-check`
   time. A value exported in the launching shell overrides `.env`.

**Key properties for adopters:**
- **Project-relative.** The detector resolves the map and doc paths from YOUR
  repo root, so it checks your docs against your code — never himmel's.
- **Advisory-only.** `df_detect` always exits 0; the SessionStart hook traps
  all errors and exits 0. Nothing blocks.
- **No surprise hard-block.** The blocking `doc-guard` gate (`check-doc-guard.sh`)
  is himmel-dev-only — gated by `.himmel-dev`. A fresh clone of himmel (or any
  other repo) has no marker and the block gate is inert. Adopters only ever see
  the advisory surface.
- **Inert when map absent.** If `scripts/hooks/doc-guard-map.tsv` does not exist,
  the detector exits 0 silently. If the map exists but carries no live `advise` rows
  (target doc missing from disk), it exits 0 and emits a single stderr note.

---

## Reference

- First full loop, hook by hook (worktree → PR → merge → handover): [`docs/daily-loop.md`](../daily-loop.md)
- Hook contracts + bypass model: [`docs/internals/enforcement.md`](../internals/enforcement.md)
- Worktree commands detail: [`CLAUDE.md`](../../CLAUDE.md) (`## WORKFLOWS`)
- Full new-machine setup (himmel dev): [`docs/setup/new-machine.md`](new-machine.md)
