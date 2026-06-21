# Harness compatibility — running himmel under Codex (and beyond)

himmel is built end-to-end around **Claude Code's** contract: PreToolUse
guardrail hooks, a plugin/marketplace system, skills, slash commands, and
`CLAUDE.md` as the always-loaded rule file. This doc records what carries over
to **other coding harnesses** — Codex first — so an operator can decide what to
*port*, what to *guard*, and what to *accept as Claude-only*.

> **Status:** the **Codex** column is triple-validated (openai/codex source +
> context7 `/openai/codex` v0.75.0 + official docs, 2026-06-21, HIMMEL-427).
> Cursor / Copilot / Gemini columns are **not yet audited** — tracked in
> HIMMEL-472. Treat their cells as best-effort until then.
>
> This doc is the HIMMEL-427 deliverable under epic **HIMMEL-470** (multi-harness
> support). The ports it recommends are tracked as 470's children: **427**
> (guardrail hook port), **471** (AGENTS.md generation), **472**
> (Cursor / Copilot / Gemini audit), **473** (per-critic prompt adaptation).

## Frame matrix

| Surface | Claude Code | Codex | Cursor | Copilot CLI | Gemini CLI |
|---|---|---|---|---|---|
| **PreToolUse guardrail hooks** | native | ✅ Claude-compatible engine (`ClaudeHooksEngine`); same stdin/decision contract | ⚠️ hooks exist (`hooks-cursor.json`, `CURSOR_PLUGIN_ROOT`) — TBD 472 | ⚠️ `COPILOT_CLI` detected by superpowers — TBD 472 | ❓ TBD 472 |
| **pre-commit / pre-push git gates** | ✅ | ✅ harness-independent (git runs them) | ✅ | ✅ | ✅ |
| **Plugins / marketplace** | native | ✅ marketplaces + `@himmel` plugins load (`config.toml`) | ❌ no marketplace (per operator) | ❓ TBD 472 | ❌ none |
| **Skills** | native | ✅ native skill loading (superpowers confirms) | ⚠️ partial — TBD 472 | ⚠️ partial — TBD 472 | ⚠️ `activate_skill` — TBD 472 |
| **Slash commands** | `.claude/commands/` | ⚠️ Codex has its own slash-command surface — himmel's `.claude/commands/` do NOT auto-load — TBD | ❓ TBD 472 | ❓ TBD 472 | ❓ TBD 472 |
| **Instruction file** | `CLAUDE.md` (always loaded) | ⚠️ **`AGENTS.md` only — CLAUDE.md is NOT read** | `.cursor/rules` (MDC) + `AGENTS.md` | `AGENTS.md` | `GEMINI.md` |
| **Subagents** | `.claude/agents/*.md` | ⚠️ `.codex/agents/*.toml` (different format) | ❓ TBD 472 | ❓ TBD 472 | ❓ TBD 472 |

**Headline:** under Codex the **git-level gates survive** (the safety net), the
**hook engine is Claude-compatible** (so the guardrail *scripts* are reusable),
but two things silently break unless ported: the **project hook wiring**
(`.codex/hooks.json` path/env bug, below) and the **rule file** (CLAUDE.md is
invisible; AGENTS.md must carry the rules).

## Codex deep-dive

### 1. Hooks — Claude-compatible, with a Windows wiring bug

Codex implements a hook engine literally named `ClaudeHooksEngine`. The
PreToolUse contract mirrors Claude Code's:

- **stdin** (`pre-tool-use.command.input.schema.json`): `tool_name`,
  `tool_input`, `cwd`, `hook_event_name:"PreToolUse"`, `permission_mode`,
  `session_id`, `tool_use_id`, `transcript_path`.
- **output** (strict `deny_unknown_fields`): `decision:approve|block`,
  `hookSpecificOutput.permissionDecision:allow|deny|ask`,
  `permissionDecisionReason`, `updatedInput`, `additionalContext`.
- **events (10):** PreToolUse, PermissionRequest, PostToolUse, PreCompact,
  PostCompact, SessionStart, UserPromptSubmit, SubagentStart, SubagentStop, Stop.
- **config layers:** user / project / session / managed. A project
  `.codex/hooks.json` IS a recognized layer (admins can restrict to managed-only
  via `allow_managed_hooks_only` in `requirements.toml`). Each hook is
  trust-hashed in `config.toml` `[hooks.state]`.
- **env vars:** Codex injects `CLAUDE_PLUGIN_ROOT` **and** `PLUGIN_ROOT` for
  **plugin** hooks ("for OOTB compat with existing plugins"). It does **not**
  inject a project-dir var for project hooks — `cwd` arrives via stdin JSON.
- **execution:** commands run via `cmd.exe` (Windows) / `/bin/sh` (Unix).

**The bug.** himmel's (untracked) repo `.codex/hooks.json` was hand-ported from
`.claude/settings.json` and uses `bash $CLAUDE_PROJECT_DIR/scripts/hooks/…`. Two
failure modes on Windows under Codex:
1. `$CLAUDE_PROJECT_DIR` is **unset** for project hooks → the path resolves to
   `/scripts/hooks/…` (broken).
2. Bare `bash` via `cmd.exe` hits the **WSL `System32\bash.exe` stub trap** →
   can't read `C:/`, exit 127.

So himmel's PreToolUse guardrails almost certainly **do not fire** under Codex
today, despite being registered.

**Fix paths** (HIMMEL-427 follow-on):
- **Preferred — plugin delivery.** Ship the guardrails through the `himmel-ops`
  plugin (it already ships a `hooks.json`). Codex injects `CLAUDE_PLUGIN_ROOT`
  for plugin hooks, so `${CLAUDE_PLUGIN_ROOT}/…` resolves. Add a
  `hooks-codex.json` variant if the Claude/Codex shapes ever diverge (superpowers
  ships one).
- **Or — harden the project file.** Mirror superpowers' `run-hook.cmd` polyglot
  (finds Git Bash explicitly; avoids the WSL stub) and derive the project dir
  from stdin `cwd` instead of `$CLAUDE_PROJECT_DIR`.

### 2. Instruction file — CLAUDE.md is invisible; AGENTS.md must carry the rules

**Codex does not read `CLAUDE.md`.** It reads `AGENTS.md`, checking
`AGENTS.override.md` then `AGENTS.md` from the global `~/.codex` scope down to
the project root, concatenating root→local (local wins), capped at
`project_doc_max_bytes` (32 KiB).

himmel's repo `AGENTS.md` is a thin "read CLAUDE.md first" pointer — a **dead end
under Codex**, because Codex won't follow it to CLAUDE.md. Result: himmel's
*entire* rule system (git workflow, prefer-plugin-over-MCP, conventional commits,
subagent policy, …) is **absent** under Codex.

**Fix:** generate a real `AGENTS.md` from `CLAUDE.md`, adapted to GPT anatomy
(see §Prompt anatomy) — tracked in **HIMMEL-471**.

### 3. Plugins / marketplace — works

`config.toml` registers the himmel marketplace + `handover@himmel`,
`obsidian-triage@himmel`, `telegram-himmel@himmel` (enabled). The only known
issue is benign: 4 **external** plugins' `hooks.json` carry a top-level
`description` key that Codex's strict parser rejects ("unknown field
description") — Codex skips just those hooks and runs normally. No himmel-owned
plugin ships that shape. **Accept** (operator decision 2026-06-20).

### 4. Skills / slash commands

Skills load natively under Codex. himmel's project-local **slash commands**
(`.claude/commands/*.md`) do **not** auto-load — Codex has its own
slash-command surface. **Accept / port selectively** (TBD per command).

### 5. Subagents

Codex uses `.codex/agents/*.toml` (`name`, `description`,
`developer_instructions`); Claude uses `.claude/agents/*.md` with frontmatter.
himmel subagents don't auto-carry. The operator has hand-authored
`.codex/agents/gemini-subagent.toml`. **Port selectively** if Codex-side
subagents are needed.

### 6. config.toml

Codex's config surface (`~/.codex/config.toml`) ≠ `.claude/settings.json`:
`notify`, `[marketplaces.*]`, `[plugins."x@y"]`, `[hooks.state]` (trust hashes),
`[mcp_servers.*]`, `[projects.*]` trust levels, `[windows] sandbox`. Permissions
and hook wiring live here, not in `.claude/`.

## Port / guard / accept decisions

| Item | Decision | Where |
|---|---|---|
| Git gates (pre-commit/push) | **Accept** — already fire | — |
| PreToolUse guardrails | **Port** — via himmel-ops plugin (CLAUDE_PLUGIN_ROOT) or hardened project file | HIMMEL-427 |
| Rule file (CLAUDE.md → AGENTS.md) | **Port** — generate GPT-adapted AGENTS.md | HIMMEL-471 |
| Plugins/marketplace | **Accept** — loads; ext-plugin `description` warnings benign | — |
| Slash commands | **Guard/port selectively** | TBD |
| Subagents (.toml) | **Port selectively** | TBD |
| Cursor / Copilot / Gemini frame | **Audit** | HIMMEL-472 |

## Prompt anatomy — why rules must be *adapted*, not copied

Mirroring `CLAUDE.md` verbatim into `AGENTS.md` would misfire. Validated
differences (GPT-5 prompting guide + the `everything-codex` migration):

- **Contradictions are expensive for GPT-5** ("surgical precision" wastes
  reasoning tokens reconciling conflicts). CLAUDE.md hedges ("use judgement",
  "deviate only for a concrete reason") read as conflicts → **resolve precedence
  explicitly**.
- **Clarity > volume.** Caps/`IMPORTANT` matter less than for Claude; structured
  sections win. XML spec tags help both.
- **Steerability is param-level** for GPT (`reasoning_effort`, `verbosity`,
  persistence prompting) — not prose.
- **Migration rule:** "remove Claude-Code-specific references; convert tool
  constraints to behavioral text." References to `.claude/settings.json`, "the
  Skill tool", or "PreToolUse hook" must be reworded as behavior.

The same per-model adaptation applies to the CR critic panel (HIMMEL-473):
GPT/codex critics get contradiction-resolution + spec tags; open models
(qwen/kimi) need stronger JSON-obedience scaffolding; Claude adjudicators get
XML/`IMPORTANT`.

## Sources

- openai/codex hook source + generated schemas: `codex-rs/hooks/` (input/output
  schemas, `engine/discovery.rs` env vars, `engine/command_runner.rs`).
- context7 `/openai/codex` (v0.75.0): event list, `deny_unknown_fields`, TOML
  `[hooks.state]` model.
- [Codex AGENTS.md discovery](https://developers.openai.com/codex/guides/agents-md)
- [GPT-5 prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide)
- context7 `/luohaothu/everything-codex` (everything-claude-code → Codex migration).
