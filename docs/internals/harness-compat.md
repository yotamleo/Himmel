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
> 472 audit spawned follow-ups **487** (Cursor hooks), **488** (rejected Hermes
> CR-skill integration), **489** (soft-deferred Gemini/Copilot ports), and
> **554** (Codex where-are-we/status context). **533** now owns selective Codex
> command/skill ports, including `pr-check`.

## Frame matrix

| Surface | Claude Code | Codex | Cursor | Copilot CLI | Gemini CLI |
|---|---|---|---|---|---|
| **PreToolUse guardrail hooks** | native | ✅ Claude-compatible engine (`ClaudeHooksEngine`); same stdin schema, but blocks via JSON `permissionDecision:"deny"` **not exit 2** — himmel bridges via `.codex/run-hook.cmd`→`codex-hook-adapter.sh` (HIMMEL-427, live-verified) | ✅ `.cursor/hooks.json`; events **camelCase** (`preToolUse`, `beforeShellExecution`); **fails OPEN** unless `failClosed:true` | ✅ `.github/hooks/*.json`; camel/Pascal; **fails CLOSED**; ⚠️ headless `-p` disables repo hooks unless `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true` | ✅ `.gemini/settings.json` `hooks`; events **PascalCase** (`BeforeTool`); stdin JSON |
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
1. **The rule file is nearly free.** **Codex, Copilot CLI, and Cursor read
   `AGENTS.md`** — so HIMMEL-471's generated repo `AGENTS.md` now carries
   himmel's rules for those harnesses, with freshness enforced by the
   `agents-md-fresh` gate. Only **Gemini** needs a distinct `GEMINI.md` (same
   content, different filename — a one-line generator target).
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

### 1. Hooks — Claude-compatible; Windows wiring + block-decision fixed (HIMMEL-427)

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

**The bugs (3 — the third found only by live verification).** himmel's original
hand-ported `.codex/hooks.json` used `bash $CLAUDE_PROJECT_DIR/scripts/hooks/…`,
which fails on Windows under Codex because (1) `$CLAUDE_PROJECT_DIR` is **unset**
for project hooks → path resolves to `/scripts/hooks/…`; and (2) bare `bash` via
`cmd.exe` hits the **WSL `System32\bash.exe` stub trap** (can't read `C:/`, exit
127). A live `codex exec` run (codex-cli **0.141.0**, 2026-06-21) surfaced a
third, deeper one: (3) himmel guardrails signal a block by **exiting 2** (Claude
convention), but **Codex does not act on exit 2** — it blocks a tool call ONLY
on a JSON `{"hookSpecificOutput":{"permissionDecision":"deny",…}}` on stdout. A
guardrail that merely exits 2 is reported as a *failed (non-blocking)* hook and
**the tool call proceeds**. So even with the path bugs fixed, the guardrails
would *fire but never block*.

**The fix (HIMMEL-427, shipped + live-verified).** Tracked `.codex/hooks.json`
routes every hook through a polyglot wrapper `.codex/run-hook.cmd --sandbox` (cmd.exe branch on
Windows / bash on Unix) that derives + exports `CLAUDE_PROJECT_DIR` from its own
location and finds Git Bash explicitly (skipping the System32 stub). Before
invoking the adapter, the wrapper smoke-tests Git Bash startup and fails closed
with Codex deny JSON if Git Bash is present but unusable in the hook sandbox. The
wrapper delegates to `.codex/codex-hook-adapter.sh`, which runs the guardrail and,
for PreToolUse/PermissionRequest exit 2, re-emits the block as Codex's JSON
`permissionDecision:"deny"` (the guardrail's stderr → reason) and exits 0.
Non-exit-2 outcomes pass through.

**Lifecycle exit-2 contract (HIMMEL-565).** Exit 2 on a **non-permission**
lifecycle event (PostToolUse, SessionStart, UserPromptSubmit) does NOT translate
to a permission deny — those events have no permission gate, and their
`*.command.output` schema (per the openai/codex *generated* schemas) carries
`hookSpecificOutput.additionalContext` (which Codex appends to the model's
context), not a `permissionDecision`. **Verification scope:** the schema shape is
confirmed against those generated schemas and the fixture proves the *adapter*
emits it; a live Codex runtime probe of the auto-arm path (does Codex honour
additionalContext on PostToolUse end-to-end) is still pending. The adapter's
`emit_context` re-emits such an exit 2 as `additionalContext` with the inbound
`hookEventName` (unrecognised events normalise to PostToolUse so the
`hookEventName` const stays valid), exit 0. This is what
`auto-arm-on-subagent-cap.sh` (the lone PostToolUse guardrail) needs: it arms a resume + writes a snapshot during
execution, then exits 2 only to feed its "write a handover now" message to the
model — previously the adapter mistranslated that to a **bogus PreToolUse deny**
(wrong event, and a permission gate for a tool that already ran).

**Advisory SessionStart/UserPromptSubmit wiring (HIMMEL-596).** Three advisory
SessionStart hooks (`inject-initiative`, `inject-where-are-we`,
`inject-doc-freshness`) are wired into `.codex/hooks.json` SessionStart via
`run-hook.cmd --sandbox`, alongside `check-update-available`. Because these hooks
deliver their `<system-reminder>` on **stdout at exit 0** (not exit 2), the
adapter now wraps such a hook's output into the SAME
`hookSpecificOutput.additionalContext` JSON channel. The wrap is **gated on the
event** (`hook_event_name ∈ {SessionStart, UserPromptSubmit}`), NOT on the exit
code: it captures the combined output and always exits 0 (exit-0 stdout AND a
defensive exit-2's stderr both funnel to additionalContext — there is no deny
path for these no-permission-gate events). Event-gating means it never touches
the PreToolUse stdout-decision passthrough (auto-approve's JSON `allow` must pass
verbatim). Raw stdout is NOT a reliable Codex context channel (the JSON
`additionalContext` field is — same reasoning as the 565 exit-2 path), so the
wrap is correct-by-construction whether or not Codex also honours raw stdout.
**Verification scope:** the fixture
(`scripts/hooks/test-codex-sessionstart-hooks.sh`) proves the adapter emits the
`additionalContext` JSON end-to-end through `run-hook.cmd`; a **live Codex
SessionStart probe** (does Codex inject that additionalContext into the model at
session start?) remains pending — the same open follow-up as the 565 PostToolUse
probe, and it also retroactively covers the pre-existing `check-update-available`
wiring. Two operational notes: (a) adding hooks changes the trusted set, so the
next Codex session re-trust-hashes `.codex/hooks.json` (non-interactive
`codex exec` needs `--dangerously-bypass-hook-trust` until trusted); (b)
`inject-where-are-we`'s detached background ledger refresh likely won't survive
Codex's hook sandbox, so under Codex the synchronous render still fires but the
ledger may not refresh (known limitation; the render is the load-bearing half).

The guardrails stay single-sourced — they keep working verbatim under Claude
Code, which never invokes the adapter (only `.codex/hooks.json` does). Verified
live against codex-cli 0.141.0: a secret read (`block-read-secrets`) is
**Blocked**; a benign command is allowed. Unit-tested both polyglot branches,
exit-2→deny translation, **exit-2→additionalContext for PostToolUse/SessionStart
(HIMMEL-565)**, explicit sandbox/no-sandbox mode parsing, and Windows
Git-Bash-startup fail-closed handling
(`scripts/hooks/test-codex-run-hook.{sh,ps1}`). Live Codex lifecycle probes of
the auto-arm path remain a follow-up; the no-token fixture is the gate that has
now passed.

**Setup options / live-verification caveats (codex-cli 0.141.0, Windows):**
- **Sandboxed project hooks are the supported setup.** The tracked
  `.codex/hooks.json` passes `--sandbox` to each wrapper invocation. Under
  `-s read-only` hook side effects are suppressed; a writable sandbox (the
  interactive default `workspace-write`) is needed for them to act. The adapter
  writes **no temp files** for this reason.
- **No-sandbox mode is diagnostic-only.** `.codex/run-hook.cmd --no-sandbox
  <script.sh>` skips the Windows Git Bash startup preflight and surfaces the raw
  child exit code. Do not wire it into `.codex/hooks.json`; it is for trusted
  local debugging, not normal guardrail enforcement.
- Run from a git **worktree**, Codex resolves the project root to the **main
  checkout** (the worktree's `.git` is a file, not a dir) and loads *its*
  `.codex/hooks.json` — so the live hook config is the main checkout's, not the
  worktree's. Edit/trust hooks in the primary checkout.
- New project hooks are **trust-hashed on first use**; non-interactive
  `codex exec` needs `--dangerously-bypass-hook-trust` to run not-yet-trusted
  hooks (interactive Codex prompts to trust them once).

**Alternative considered — plugin delivery.** Shipping via the `himmel-ops`
plugin (Codex injects `CLAUDE_PLUGIN_ROOT` for plugin hooks) would fix the *path*
bugs but **not** the exit-2-vs-JSON one — the adapter translation is required
regardless of delivery mechanism. Project-file delivery + adapter was chosen as
the smaller change.

The converse bit himmel later (HIMMEL-589): two SECURITY guards that *do* ship
via the `himmel-ops` plugin `hooks.json` — `block-docker-privesc.sh` (HIMMEL-441)
and `block-merged-pr-commit.sh` (HIMMEL-512) — resolve their script via
`$CLAUDE_PROJECT_DIR`, which Codex injects for **neither** plugin nor project
hooks (plugin hooks get `CLAUDE_PLUGIN_ROOT` instead — see §1), so under Codex
the wrapper's `[ -f "$h" ]` was false and the guards silently no-op'd
(root-equivalent docker mounts + merged-PR commits went unguarded). Fix: mirror both into `.codex/hooks.json` via `run-hook.cmd`, which
derives the root from its own location. The non-security plugin SessionStart
hooks (`inject-where-are-we` / `inject-doc-freshness`) shared the same
root-resolution bug; **HIMMEL-596** mirrors them (plus `inject-initiative`) into
`.codex/hooks.json` SessionStart with the exit-0 `additionalContext` wrap above
(live Codex firing pending a probe). The SessionEnd half
(`refresh-where-are-we-on-end`) is still pending — leg HIMMEL-599 (SessionEnd →
Codex `Stop`).

### 2. Instruction file — CLAUDE.md is invisible; AGENTS.md must carry the rules

**Codex does not read `CLAUDE.md`.** It reads `AGENTS.md`, checking
`AGENTS.override.md` then `AGENTS.md` from the global `~/.codex` scope down to
the project root, concatenating root→local (local wins), capped at
`project_doc_max_bytes` (32 KiB).

HIMMEL-471 has landed: himmel now generates a real repo `AGENTS.md` from
`CLAUDE.md`, adapted to GPT anatomy (see §Prompt anatomy). `CLAUDE.md` remains
the source of truth; `AGENTS.md` is the Codex/Copilot/Cursor-facing generated
artifact with a generated-file banner, explicit precedence ladder, and
non-Claude-harness reading note. Freshness is enforced by the pre-commit
`agents-md-fresh` gate, and the direct check is:

```bash
node scripts/agents-md/generate.mjs --check
```

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

**Codex skill-discovery root = project-local `.agents/skills/<name>/SKILL.md`**
(HIMMEL-533, live-verified codex-cli 0.142.0: a project-local probe skill
loaded + ran from the worktree). The `.gitignore` ignores only
`.agents/skills/source-command-*/` (the external-installer mirror that trips
`clean-garden`); hand-authored `.agents/skills/<name>/` is tracked.

**HIMMEL-533 delivered** the high-value "driver" commands as thin **tracked**
`.agents/skills/` wrappers that shell the same harness-neutral `scripts/` the
Claude commands use (no logic duplication; Claude `.claude/commands/*.md`
untouched): `worktree`, `clean`, `clean-garden`, `shell-lint`, `guardrail-sim`,
and `pr-check`. `pr-check` is the **panel-only** subset — it runs the pure-shell
critic panel (`scripts/cr/critic-panel.sh`) and clears the CR marker only when
the panel reports 0 Critical + 0 Important (retains on findings, panel
unavailable, or a `docs-audit` lane). It does **not** dispatch the Claude
`pr-review-toolkit` reviewer agents. Codex native `/review` participation is a
post-HIMMEL-527 follow-up (shared `cr-context.sh` assembler).

Tier-A skills split by **delivery mechanism**: the enabled himmel plugins
(`handover@himmel`, `obsidian-triage@himmel`, `telegram-himmel@himmel`) carry
their own skills/commands. The **himmel-ops** skills (minerva, stuck-playbook,
vm, himmel-doctor, himmel-update) require `himmel-ops@himmel` enabled in
user-global `~/.codex/config.toml` — provisioned **reproducibly** by
`scripts/codex/install-himmel-codex.{sh,ps1}` (HIMMEL-597; the codex-CLI half of
the install split, twin of the hermes `scripts/hermes/install-himmel-profile.*`).
The installer drives the `codex` CLI (`codex plugin marketplace add` /
`codex plugin add`), idempotent + non-destructive. Independent of plugin-skill
loading, the **verified** Codex skill-discovery path is project-local
`.agents/skills/<name>/SKILL.md` (HIMMEL-533); guaranteed wrappers for the
minerva/stuck-playbook/vm cluster are tracked in HIMMEL-604/607.

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

### 7. Status context — statusLine is Claude-only (HIMMEL-554)

Claude's `statusLine.command` is wired through `scripts/where-are-we/statusline.sh`;
Codex has no equivalent visual statusline surface. The Codex port should inject
the same advisory context through a Codex-native context path (likely
SessionStart/UserPromptSubmit additional context), not by porting the rendered
bar. Reuse the existing status ledgers as the source of truth:
`.where-are-we/ledger.jsonl` via `scripts/where-are-we/{dock,provision}.mjs`,
and the CR score/usage ledger (`cr-critic-scores.jsonl`, `CR_USAGE_LOG=1`,
`scripts/cr/cr-scores.sh`) for review status. The context path must stay
offline/fail-open and must not widen guardrail permissions.

### 8. Flow-audit follow-ups (HIMMEL-470 record)

After the Codex hook-wrapper port landed, the completed HIMMEL-470 audit left
follow-up work rather than another broad implementation pass. The internal matrix classifies each high-value
flow as works under Codex, needs a Codex adapter, Claude-only by
design, a separate feature request, or unknown pending evidence.
Public/reference docs should point to the owner tickets rather than duplicate
that working matrix.

- **PR flow:** design a Codex `pr-check` skill under **HIMMEL-533**. It should
  reuse the shell critic panel, define how explicit external-diff approval is
  captured, decide whether Codex native `/review` participates, and clear the CR
  marker only after adjudication.
- **Status context:** keep Codex where-are-we/status work under **HIMMEL-554**.
  Reuse ledgers; do not emulate Claude's visual statusline.
- **Hook confidence:** file an owner ticket for no-token fixture coverage of
  individual guardrails and lifecycle events before any live Codex probe. The
  first lifecycle case — PostToolUse auto-arm's exit-2 contract — is **resolved
  (HIMMEL-565)**: exit 2 on non-permission events now emits `additionalContext`,
  not a bogus PreToolUse deny (see §1). Live auto-arm lifecycle probe still
  pending.
- **Install/update confidence:** file an owner ticket for disposable VM or
  temp-config checks covering setup, update, hook trust, and uninstall before
  live harness probes.

Do not start command ports or Codex status-context wiring from the audit chunk
itself. A live Codex probe should run only after the matrix row names the exact
question it answers and the no-token preconditions that must pass first.

## Cursor / Copilot / Gemini deep-dive (HIMMEL-472)

Audited 2026-06-21 (official docs + superpowers' shipped `hooks-cursor.json`,
`.cursor-plugin/`, `.codex-plugin/`, `gemini-extension.json`). Per-harness
port/guard/accept:

### Cursor (priority: second after Codex)
- **Rule file — ACCEPT (covered by HIMMEL-471).** Cursor reads
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
- **Rule file — ACCEPT.** Reads `AGENTS.md` (HIMMEL-471 covers it);
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
(`/pr-check`'s `pr-review-toolkit:*` Agent dispatches) does not auto-carry. The 472
audit identified brooks-lint as a possible analog, but HIMMEL-488 later rejected
the deeper Hermes review-skill integration as redundant and unsafe for himmel's
guardrails. **Current decision:** HIMMEL-533 owns a thin Codex `pr-check` skill
over the existing shell panel, with the Codex native `/review` role decided after
HIMMEL-527 supplies the shared context assembler.

## Port / guard / accept decisions

| Item | Decision | Where |
|---|---|---|
| Git gates (pre-commit/push) | **Accept** — fire on every harness | — |
| PreToolUse guardrails (Codex) | **Ported** — tracked `.codex/hooks.json` through `run-hook.cmd` + adapter | HIMMEL-427 |
| Rule file (CLAUDE.md → AGENTS.md) | **Port** — covers Codex **+ Copilot + Cursor** | HIMMEL-471 |
| Rule file → `GEMINI.md` | **Port (small), SOFT-DEFER** — extra generator target | HIMMEL-489 |
| Hooks → Cursor (`.cursor/hooks.json`, fail-open) | **Port** (priority 2) | HIMMEL-487 |
| Hooks → Copilot / Gemini | **Port, SOFT-DEFER** (no free usage) | HIMMEL-489 |
| Skills / subagents (Cursor, Copilot) | **Accept** — read `.claude/*` directly | — |
| Driver commands → Codex skills | **Ported (delivered)** — thin tracked `.agents/skills/` wrappers (worktree/clean/clean-garden/shell-lint/guardrail-sim/pr-check) shelling existing `scripts/`; live-verified under codex-cli 0.142.0 | HIMMEL-533 |
| CR reviewer skill for Codex | **Ported (panel-only)** — Codex `pr-check` skill runs the shell panel + clears the CR marker on clean; native `/review` participation deferred post-HIMMEL-527 | HIMMEL-533 |
| where-are-we / status context for Codex | **Port** — use Codex-native advisory context, not Claude `statusLine.command` | HIMMEL-554 |
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
XML/`IMPORTANT`. When reviewing prompt behavior, use the status ledgers too:
`CR_USAGE_LOG=1` records estimated prompt/response usage, and
`scripts/cr/cr-scores.sh` summarizes availability, agreement, drop advice, and
usage without coupling the prompt contract to one harness.

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
