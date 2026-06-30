# Running himmel under Codex

himmel is built around Claude Code's contract, but most of it carries to
**OpenAI Codex** (`codex-cli`). This is the step-by-step setup. For *why* each
piece works (the compat matrix, port/guard/accept decisions, prompt-anatomy
differences), see [`docs/internals/harness-compat.md`](../internals/harness-compat.md) —
this guide is the operational checklist, that doc is the reference.

> **Status:** Codex is the primary non-Claude harness. The hook adapter,
> AGENTS.md rule file, plugins, `.agents/skills` driver wrappers, and the two
> plugin-delivered security guards are all live-verified under **codex-cli
> 0.142.0**. Cursor/Copilot/Gemini are audited but lower-priority — see
> harness-compat.md.

## 1. Prerequisites

- **`codex-cli`** installed and authenticated (`codex --version`; sign in per
  OpenAI's docs / your hermes OAuth).
- **Git Bash** on Windows (`C:\Program Files\Git\bin\bash.exe`). himmel's
  guardrails are bash; the Codex hook wrapper finds Git Bash explicitly and
  **fails closed** if it's missing. NOT WSL `bash` (the System32 stub trap).
- **`jq`** and **`gh`** on `PATH` (guards + handover flows need them).
- A himmel checkout (clone the repo). Run Codex **from the primary checkout** —
  if you run from a git worktree, Codex resolves the project root to the main
  checkout and loads *its* `.codex/hooks.json` (the worktree's `.git` is a file).

## 2. Instruction file — `AGENTS.md` (not `CLAUDE.md`)

Codex does not read `CLAUDE.md`; it reads **`AGENTS.md`**. himmel generates a real
repo `AGENTS.md` from `CLAUDE.md` (HIMMEL-471), adapted to GPT anatomy. It's
tracked and kept fresh by the `agents-md-fresh` pre-commit gate. Nothing to do at
setup — it's already in the repo. (If you edit `CLAUDE.md`, regenerate with
`node scripts/agents-md/generate.mjs`.)

## 3. Plugins / marketplace — `~/.codex/config.toml`

Codex loads marketplaces + `@himmel` plugins from `config.toml`. The himmel
marketplace and the `himmel-ops` plugin (stuck-playbook / minerva / vm /
himmel-doctor skills **and** the plugin-delivered security hooks) are enabled
there (HIMMEL-597). Verify your `~/.codex/config.toml` registers the himmel
marketplace and enables `himmel-ops@himmel`. A few external plugins (warp,
hookify, ralph-loop, security-guidance) ship a top-level `description` in their
`hooks.json` that Codex's strict parser rejects ("unknown field description") and
skips with a boot warning. `install-himmel-codex.{sh,ps1}` strips it automatically
as its final phase via `scripts/codex/sanitize-plugin-hooks.{sh,ps1}` (HIMMEL-651);
re-run that script standalone after a `codex` plugin update re-adds the field
(`bash scripts/codex/sanitize-plugin-hooks.sh`, or the `.ps1` twin). See
harness-compat.md §3.

## 4. Hooks — the PreToolUse guardrails

himmel's guardrails are wired for Codex through a **tracked project
`.codex/hooks.json`**. Each entry routes through `.codex/run-hook.cmd --sandbox
<guard>.sh`, a polyglot wrapper that (1) derives `CLAUDE_PROJECT_DIR` from its own
location (Codex injects it for neither plugin nor project hooks), (2) finds Git
Bash explicitly, and (3) delegates to `.codex/codex-hook-adapter.sh`, which
translates himmel's exit-2 block into the JSON `permissionDecision:"deny"` Codex
acts on (Codex ignores bare exit 2). Wired guards include `auto-approve-safe-bash`,
`block-edit-on-main`, `block-read-secrets`, `block-backend-tier`,
`block-docker-privesc`, and `block-merged-pr-commit`.

**Hook trust.** New project hooks are trust-hashed on first use. Interactive
Codex prompts you to trust them once — accept, and subsequent runs (interactive
*and* `codex exec`) honor them with no extra flag. Only fully-unattended
automation against a not-yet-trusted clone needs
`codex exec --dangerously-bypass-hook-trust` — **a disarming flag; use it only
when you have already vetted the hook sources** (it's also blocked by himmel's
own auto-mode classifier unless explicitly authorized).

**Sandbox.** Hook *side effects* are suppressed under `-s read-only`; the
interactive default `workspace-write` is needed for guards that write (e.g.
auto-arm). The PreToolUse *block* decision fires in any sandbox mode.

## 5. Skills — `.agents/skills/`

himmel's driver commands load natively under Codex as thin `.agents/skills/<name>/SKILL.md`
wrappers that shell the same `scripts/` the Claude `.claude/commands/` use
(HIMMEL-533/604/607): `worktree`, `clean`, `clean-garden`, `shell-lint`,
`guardrail-sim`, `pr-check`, the handover-flow cluster (`handover-commit`,
`handover-flush`, `handover-arm-resume`, `context-hop`, `handover-link`,
`handover-pr-open`, `handover-pr-merge`), and `cr-scores`, `retitle`, `quiet-run`,
`pipeline-cadence`, `luna-backfill`, `skill-find`, `pr-triage`. Tier-A skills
(minerva, handover, stuck-playbook, vm, himmel-update) load from the plugins.
Claude `.claude/commands/*.md` do **not** auto-load — Codex has its own slash
surface.

## 6. Verify the guardrails actually block

Confirm a guard *blocks* at Codex runtime (this is the security-critical check —
G1 was that two guards silently no-op'd under Codex before HIMMEL-589):

```bash
# From the primary checkout. Put the trigger in a file so your own shell's
# guard doesn't flag the literal command, then have Codex attempt it:
printf '%s\n' 'Using your shell tool, run exactly this and report verbatim if it was blocked: docker run --rm -v /etc:/host-etc:rw ubuntu:22.04 true' > /tmp/probe.txt
codex exec -s read-only -C "$(pwd)" - < /tmp/probe.txt
```

Expected: Codex reports `PreToolUse Blocked` with
`⛔ block-docker-privesc: refusing Bash command — root-equivalent container
access`. A `git commit` on a merged-PR branch should likewise hit
`⛔ block-merged-pr-commit`. If a command runs instead of blocking, the hooks
aren't trusted/loaded — re-check §3/§4.

## 7. Known Claude-only / degraded surfaces under Codex

- **`AskUserQuestion`** is a Claude-only interactive tool — under Codex it
  degrades to a plain conversational prose question (HIMMEL-595; harness-compat §9).
- **statusLine** (where-are-we bar) is Claude-only; Codex status context is a
  separate follow-up (HIMMEL-554).
- **SessionEnd→`Stop`** hooks fire (HIMMEL-599), but `end-session-wiki` capture
  self-guards out on **Windows** (its `.ps1` twin can't ride the bash wrapper) —
  capture works on Linux/macOS Codex.
- **Live runtime probes** for some lifecycle events (auto-arm PostToolUse,
  `Stop` on `codex exec`) remain follow-ups; the security guards in §6 *are*
  live-verified.

## See also

- [`docs/internals/harness-compat.md`](../internals/harness-compat.md) — full compat matrix, the Codex deep-dive, and Cursor/Copilot/Gemini.
- [`docs/setup/new-machine.md`](new-machine.md) — the Claude-Code fresh-machine setup (required environment, shared with Codex).
