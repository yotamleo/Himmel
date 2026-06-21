# Harness compatibility — running himmel under Codex (and beyond)

himmel is built end-to-end around **Claude Code's** contract: PreToolUse
guardrail hooks, a plugin/marketplace system, skills, slash commands, and
`CLAUDE.md` as the always-loaded rule file. This doc records what carries over
to **other coding harnesses** — Codex first — so an operator can decide what to
*port*, what to *guard*, and what to *accept as Claude-only*.

> **Status:** the **Codex** column is triple-validated (openai/codex source +
> context7 `/openai/codex` v0.75.0 + official docs, 2026-06-21, HIMMEL-427). The
> **Cursor / Copilot / Gemini** columns were audited 2026-06-21 (HIMMEL-472,
> official docs + superpowers' shipped cross-harness manifests); a few cells with
> no authoritative source are marked *unverified* inline.
>
> This doc is the HIMMEL-427 deliverable under epic **HIMMEL-470** (multi-harness
> support). The ports it recommends are tracked as 470's children: **427**
> (guardrail hook port), **471** (AGENTS.md generation), **472**
> (Cursor / Copilot / Gemini audit), **473** (per-critic prompt adaptation). The
> 472 audit spawned follow-ups **487** (Cursor hooks), **488** (Codex CR review
> skill), **489** (soft-deferred Gemini/Copilot ports).

## Frame matrix

| Surface | Claude Code | Codex | Cursor | Copilot CLI | Gemini CLI |
|---|---|---|---|---|---|
| **PreToolUse guardrail hooks** | native | ✅ Claude-compatible engine (`ClaudeHooksEngine`); same stdin/decision contract | ✅ `.cursor/hooks.json`; events **camelCase** (`preToolUse`, `beforeShellExecution`); **fails OPEN** unless `failClosed:true` | ✅ `.github/hooks/*.json`; camel/Pascal; **fails CLOSED**; ⚠️ headless `-p` disables repo hooks unless `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true` | ✅ `.gemini/settings.json` `hooks`; events **PascalCase** (`BeforeTool`); stdin JSON |
| **pre-commit / pre-push git gates** | ✅ | ✅ harness-independent (git runs them) | ✅ | ✅ | ✅ |
| **Plugins / marketplace** | native | ✅ marketplaces + `@himmel` plugins load (`config.toml`) | ✅ marketplace exists (`.cursor-plugin/plugin.json`) — *corrects "no marketplace"* | ✅ `marketplace.json` registries (`copilot plugin marketplace add`) | ✅ "extensions" gallery (`gemini-extension.json`) |
| **Skills** | native | ✅ native skill loading | ✅ `SKILL.md`; reads `.cursor/skills` **+ `.claude/skills` + `.codex/skills`** | ✅ `SKILL.md`; reads `.github/skills` **+ `.claude/skills`** | ✅ `SKILL.md` (gemini-native); `.gemini/skills/` |
| **Slash commands** | `.claude/commands/` | ⚠️ own slash surface; `.claude/commands/` don't auto-load | ✅ `.cursor/commands/*.md` | ⚠️ via plugins/skills/agents (`/name`); dedicated file unverified | ✅ **TOML** `.gemini/commands/` (`:` namespacing) |
| **Instruction file** | `CLAUDE.md` (always loaded) | ⚠️ **`AGENTS.md` only** | `.cursor/rules/*.mdc` + **`AGENTS.md`** | **`AGENTS.md`** (also reads `CLAUDE.md`/`GEMINI.md`) | **`GEMINI.md`** |
| **Subagents** | `.claude/agents/*.md` | ⚠️ `.codex/agents/*.toml` | ✅ `.cursor/agents/*.md` (reads **`.claude/agents`**) | ✅ `*.agent.md` (`.github/agents/`) | ✅ `.gemini/agents/*.md` |

> **Status (HIMMEL-472, 2026-06-21):** Cursor / Copilot / Gemini columns are now
> audited (web + official docs). Several earlier hints were **stale** and are
> corrected above: Cursor **does** have a marketplace; all three have blocking
> hooks, `SKILL.md` skills, subagents, and custom commands; `CURSOR_PLUGIN_ROOT`
> and `COPILOT_CLI` env vars are **unverified / non-existent** in current docs.

**Headline.** Two facts dominate the port decisions:
1. **The rule file is nearly free.** **Copilot CLI and Cursor both read
   `AGENTS.md`** — so the generated `AGENTS.md` from **HIMMEL-471 covers them once
   it lands** (471 is in flight; today's repo `AGENTS.md` is still the thin
   pointer — see §2). Only **Gemini** needs a distinct `GEMINI.md` (same content,
   different filename — a one-line generator target).
2. **Skills + subagents are near drop-in; hooks are not.** Cursor and Copilot
   read `.claude/skills` and `.claude/agents` directly, so himmel's skills +
   subagents largely carry. But each harness's **hook schema differs** —
   event-name casing (camel vs Pascal), fail posture (Cursor fails OPEN, Copilot
   fails CLOSED), and payload transport (Cursor env vars incl. a `CLAUDE_PROJECT_DIR`
   alias; Copilot + Gemini stdin JSON). himmel's guardrail *scripts* are reusable
   but the *wiring* is per-harness. As under Codex, the **git gates survive on
   every harness** — the safety net.

**Prioritization (operator, 2026-06-21).** **Codex is primary** (operator has
Codex-primary users; free OAuth usage via hermes). **Cursor** is a reasonable
second (rule file already covered by AGENTS.md; skills/agents near drop-in).
**Gemini + Copilot are soft-deferred** — no free usage tier, so the cost of
porting + running guardrails there is not yet justified; file the subtasks but
leave them low-priority until there's demand.

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

## Cursor / Copilot / Gemini deep-dive (HIMMEL-472)

Audited 2026-06-21 (official docs + superpowers' shipped `hooks-cursor.json`,
`.cursor-plugin/`, `.codex-plugin/`, `gemini-extension.json`). Per-harness
port/guard/accept:

### Cursor (priority: second after Codex)
- **Rule file — ACCEPT (covered once HIMMEL-471 lands).** Cursor reads
  `AGENTS.md`, so HIMMEL-471's generated file works as-is. Optional upside: a
  `.cursor/rules/*.mdc` variant for glob-scoped rules (defer).
- **Skills / subagents — ACCEPT.** Cursor reads `.claude/skills` and
  `.claude/agents` directly → near drop-in.
- **Hooks — PORT.** `.cursor/hooks.json`, **camelCase** events
  (`preToolUse`/`beforeShellExecution`), and **fails OPEN** by default — himmel's
  fail-closed posture needs explicit `failClosed:true`. Reuse the guardrail
  scripts; new wiring file. Cursor injects `CURSOR_PROJECT_DIR` (+ a
  `CLAUDE_PROJECT_DIR` alias) so the project-dir resolution is easier than Codex's.
- **Marketplace — ACCEPT** (exists, contrary to the earlier "no marketplace" note).

### Copilot CLI (SOFT-DEFER — no free usage)
- **Rule file — ACCEPT.** Reads `AGENTS.md` (HIMMEL-471 covers it once shipped);
  also reads `CLAUDE.md`/`GEMINI.md`.
- **Skills — ACCEPT** (reads `.claude/skills`). **Subagents** `*.agent.md` — port selectively.
- **Hooks — PORT, with a gotcha.** `.github/hooks/*.json`, fails CLOSED, BUT
  **headless `-p` disables repo hooks** unless `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true`
  — himmel's auto-mode guardrails would silently not fire. Note `COPILOT_CLI` env
  var (superpowers reference) does **not** exist in current docs.

### Gemini CLI (SOFT-DEFER — no free usage)
- **Rule file — PORT (small).** Needs `GEMINI.md` (distinct filename); same body
  as AGENTS.md → a one-line extra target on the HIMMEL-471 generator. Soft-deferred.
- **Skills / subagents** — gemini-native `SKILL.md` (`.gemini/skills/`) +
  `.gemini/agents/*.md` — port selectively.
- **Hooks — PORT.** `.gemini/settings.json` `hooks`, **PascalCase** events
  (`BeforeTool`), stdin-JSON payload (no env vars). New wiring.

### CR reviewer under non-Claude harnesses (answers "pr-review-toolkit for codex?")
The **cross-model critic panel** (`scripts/cr/critic-panel.sh` + hermes) is pure
shell → already runs under any harness. Only the **Claude-subagent** layer
(`/pr-check`'s `.claude/agents/code-reviewer.md`) doesn't auto-carry. No 1:1
codex mirror of pr-review-toolkit exists; the closest trusted analog is
**`hyhmrright/brooks-lint`** (921★, MIT — an AI code-review *codex skill*),
catalogued in **`ComposioHQ/awesome-codex-skills`** (~14k★ live 2026-06-21,
active; the vault clip `luna/30-Resources/Tech/composiohq-awesome-codex-skills.md`
recorded 13.5k earlier and already flags it
"take-parts, directly relevant to pr-review-toolkit"). Codex skills are
`SKILL.md`-based (same shape himmel uses), installable into `$CODEX_HOME/skills/`.
**Decision:** author a himmel codex review `SKILL.md` OR adopt/adapt brooks-lint
via the [tool-adoption rubric](../tool-adoption/rubric.md) — tracked as a 472
follow-up subtask (priority: with Codex).

## Port / guard / accept decisions

| Item | Decision | Where |
|---|---|---|
| Git gates (pre-commit/push) | **Accept** — fire on every harness | — |
| PreToolUse guardrails (Codex) | **Port** — via himmel-ops plugin (CLAUDE_PLUGIN_ROOT) or hardened project file | HIMMEL-427 |
| Rule file (CLAUDE.md → AGENTS.md) | **Port** — covers Codex **+ Copilot + Cursor** | HIMMEL-471 |
| Rule file → `GEMINI.md` | **Port (small), SOFT-DEFER** — extra generator target | HIMMEL-489 |
| Hooks → Cursor (`.cursor/hooks.json`, fail-open) | **Port** (priority 2) | HIMMEL-487 |
| Hooks → Copilot / Gemini | **Port, SOFT-DEFER** (no free usage) | HIMMEL-489 |
| Skills / subagents (Cursor, Copilot) | **Accept** — read `.claude/*` directly | — |
| CR reviewer skill for Codex | **Port/adopt** — codex `SKILL.md` or brooks-lint | HIMMEL-488 |
| Marketplace (all) | **Accept** — each has one | — |

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
- **HIMMEL-472 (Cursor/Copilot/Gemini, 2026-06-21):** cursor.com/docs (hooks,
  rules, plugins, skills, subagents, slash-commands) · docs.github.com/copilot
  (hooks-configuration/reference, custom-instructions, CLI plugins + marketplace,
  skills, custom agents) · geminicli.com/docs (hooks, GEMINI.md, extensions,
  skills, subagents, custom-commands) · superpowers v6.0.3 shipped
  `hooks-cursor.json` / `hooks-codex.json` / `.cursor-plugin` / `gemini-extension.json`.
- **CR-under-Codex:** `ComposioHQ/awesome-codex-skills` (~14k★ live 2026-06-21) +
  `hyhmrright/brooks-lint` (921★, MIT) — vault clip
  `luna/30-Resources/Tech/composiohq-awesome-codex-skills.md`.
