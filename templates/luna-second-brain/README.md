# luna-brain

OSS Obsidian vault skeleton for Claude Code workflows. Ships a PARA
folder layout, daily/weekly templates, pre-commit + branch-hygiene
guardrails, and a SHA-pinned plugin marketplace so a fresh clone
becomes a working AI-first second brain in under five minutes.

luna-brain is the **skeleton**: the inert structure that turns into a
personal vault on first run. Your live vault starts as a copy of this
template and accumulates content over time. The skeleton does not ship
content — only the bones, hooks, and plugin pointers.

> **Where this lives:** this template ships inside the public
> [Himmel](https://github.com/yotamleo/Himmel) repo (the dev engine that
> provides the worktree / handover / PR-flow tooling the vault inherits).
> To create a vault, copy this folder *out* of Himmel into its own git
> repo — see Quickstart.

## Quickstart

Requires `bash`, `git`, `python3` (verified by `scripts/setup.sh` step
`[1/6]`). See `docs/setup/new-machine.md` for per-platform install notes.

This template lives inside Himmel, so the install is "copy the folder out,
make it its own repo, run setup." Your vault **must** be its own git repo:
`setup.sh` resolves `git rev-parse --show-toplevel`, so running it while the
folder is still nested inside the Himmel checkout would target Himmel, not
your vault.

```bash
git clone https://github.com/yotamleo/Himmel
cp -r Himmel/templates/luna-second-brain my-vault
cd my-vault
git init                                            # your vault is its own repo

# Linux / macOS / Git Bash
bash scripts/setup.sh

# Windows PowerShell
powershell -File scripts\setup.ps1
```

Setup is idempotent — re-run safely after pulling.

After setup, install the SHA-pinned vault plugins from inside Claude
Code (setup prints the exact commands):

```
claude plugin marketplace add <repo>/marketplace
claude plugin install claude-obsidian@luna-brain
claude plugin install obsidian@luna-brain
```

Optional: install `obsidian-second-brain` for PARA capture/daily/project
skills. Operator-driven (3rd-party install.sh):
<https://github.com/eugeniughelbur/obsidian-second-brain#install>

Open your vault folder in Obsidian to start using the vault.

> **Keep your vault out of Himmel's history.** If you created the vault
> *inside* the Himmel checkout (e.g. `Himmel/my-vault`) rather than as a
> sibling, add its path to Himmel's `.gitignore` so your personal vault
> content never lands in a Himmel commit. The cleanest layout is to keep
> the vault as its own repo in a separate directory and delete the Himmel
> clone you copied it from.

**Plugin credentials:** `obsidian-local-rest-api`'s `data.json` is
gitignored. When you enable that plugin in Obsidian the first time, it
generates a fresh `apiKey` + RSA cert/key pair on your machine —
nothing leaks into commits. Other plugin `data.json` files stay
tracked so a fresh clone inherits usable defaults (audited free of
credentials).

**Optional plugins:** six permissively-licensed plugins ship bundled
under `.obsidian/plugins/` (each with its upstream `LICENSE`). Three
the source vault also used — Templater, Excalidraw, and Thino — are
**not bundled** (incompatible licenses) and are optional; install them
yourself from the Community Plugins browser per
`.obsidian/PLUGINS-SETUP.md`.

## Features

Pointer-heavy by design — every feature has a canonical doc that owns
the detail.

| Feature                                         | Pointer                                                                                |
|-------------------------------------------------|----------------------------------------------------------------------------------------|
| **PARA folder layout + templates**              | `_CLAUDE.md` (`## Folder Map` + `## Templates`)                                        |
| **Pre-commit + commit-msg hooks**               | `.pre-commit-config.yaml` (trailing-ws, eof-fixer, yaml/json, shellcheck, gitleaks, worktree-isolation, no-push-to-main, no-force-push, conventional-commit-msg) |
| **Shared git-state predicates**                 | `scripts/guardrails/lib.sh` (`is_on_main`, `is_main_ref`, `is_dirty` + `guard_call`)   |
| **Handover-path resolver (HIMMEL-118)**         | `scripts/lib/handover-path.sh` (Mode A inline default, Mode B external via HANDOVER_DIR) |
| **USER_SLUG resolver (HIMMEL-145)**             | `scripts/lib/user-slug.sh` (env var → git config fallback)                             |
| **SHA-pinned vault plugin marketplace**         | `marketplace/.claude-plugin/marketplace.json` (claude-obsidian + obsidian-skills)      |
| **Setup scripts (sh + ps1)**                    | `scripts/setup.sh`, `scripts/setup.ps1`                                                |

## Vault layout

```
00-Inbox/        Capture queue — process weekly
10-Projects/     Active work with a clear outcome
20-Areas/        Ongoing responsibilities (Life / Work)
30-Resources/    Reference (Tech / Concepts / Books)
40-Archive/      Completed projects, inactive areas
50-Journal/      Daily + Weekly notes
60-Maps/         Maps of Content (MOCs)
_Templates/      Note templates (do not modify during normal ops)
```

See `_CLAUDE.md` for the full folder map and per-folder conventions.

## Setup details

Per-platform install notes (Linux / macOS / Windows Git Bash) live in
`docs/setup/new-machine.md`.

The two operator-tunable knobs:

| Variable      | Required? | Default                                                          |
|---------------|-----------|------------------------------------------------------------------|
| `USER_SLUG`   | no        | Slugified `git config user.name`.                                |
| `HANDOVER_DIR`| no        | `<repo>/handovers/` (Mode A). Set to point at an external repo.  |

Both have resolver fallbacks — most operators never need to set them.

## Contributing

PR-only — main is protected, force-push to main is blocked by pre-push
hook, and conventional commits are enforced.

1. Create a worktree branch (`git switch -c feat/<slug>`); never edit
   on `main`.
2. Conventional commit format: `type(scope): [TICKET-N ]message`.
   Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `style`,
   `perf`, `ci`, `build`, `revert`. Ticket prefix is optional but
   validated if present.
3. Pre-commit + pre-push hooks must pass.
4. Open a PR; squash-merge to keep main history linear.

See `docs/contributing.md` for the full contribution workflow.

## Relationship to other repos

- **Himmel** — dev engine and **host repo**: this template ships under
  `templates/luna-second-brain/` and inherits Himmel's pre-commit +
  guardrails patterns.
- **luna** — personal vault. A copy of this template that has accumulated
  content. Stays private.
- **claude-obsidian** (upstream) — knowledge-companion plugin pinned
  in `marketplace/`.
- **obsidian-skills** (upstream, Steph Ango) — Obsidian Flavored
  Markdown skill pack pinned in `marketplace/`.
- **obsidian-second-brain** (upstream, eugeniughelbur) — optional
  PARA capture plugin. Operator-installed via its native install.sh.

## License

MIT — this template ships inside the [himmel](https://github.com/yotamleo/Himmel)
repository and is covered by its root `LICENSE`. Bundled `.obsidian`
plugins retain their own upstream licenses (see each plugin's
`LICENSE`/`LICENCE` file under `.obsidian/plugins/`).
