# Harness compatibility — running himmel under Codex (and beyond)

himmel is built end-to-end around **Claude Code's** contract: PreToolUse
guardrail hooks, a plugin/marketplace system, skills, slash commands, and
`CLAUDE.md` as the always-loaded rule file. This doc records what carries over
to **other coding harnesses** — Codex first — so an operator can decide what to
*port*, what to *guard*, and what to *accept as Claude-only*.

> **Setting up himmel under Codex?** The operational step-by-step (prereqs,
> AGENTS.md, `config.toml`, hook trust, `.agents/skills`, and a guard-blocks
> verification) lives in [`docs/setup/codex.md`](../setup/codex.md). This doc is
> the *why*; that one is the *how*.

> **Per-lane parity?** The living lane-parity index (invariant guard set + lane x dimension table, the successor to this doc's Codex-centric frame) is in [`lane-parity.md`](lane-parity.md).

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
| **PreToolUse guardrail hooks** | native | ✅ Claude-compatible engine (`ClaudeHooksEngine`); same stdin schema, but blocks via JSON `permissionDecision:"deny"` **not exit 2** — himmel bridges via `.codex/run-hook.{sh,cmd}`→`codex-hook-adapter.sh` (HIMMEL-427/HIMMEL-2019) | ✅ `.cursor/hooks.json`; events **camelCase** (`preToolUse`, `beforeShellExecution`); **fails OPEN** unless `failClosed:true` | ✅ `.github/hooks/*.json`; camel/Pascal; **fails CLOSED**; ⚠️ headless `-p` disables repo hooks unless `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true` | ✅ `.gemini/settings.json` `hooks`; events **PascalCase** (`BeforeTool`); stdin JSON |
| **pre-commit / pre-push git gates** | ✅ | ✅ harness-independent (git runs them) | ✅ | ✅ | ✅ |
| **Plugins / marketplace** | native | ✅ marketplaces + `@himmel` plugins load (`config.toml`) | ✅ marketplace exists (`.cursor-plugin/plugin.json`) — *corrects "no marketplace"* | ✅ `marketplace.json` registries (`copilot plugin marketplace add`) | ✅ "extensions" gallery (`gemini-extension.json`) |
| **Skills** | native | ✅ native skill loading | ✅ `SKILL.md`; reads `.cursor/skills` **+ `.claude/skills` + `.codex/skills`** | ✅ `SKILL.md`; reads `.github/skills` **+ `.claude/skills`** | ✅ `SKILL.md` (gemini-native); `.gemini/skills/` |
| **Slash commands** | `.claude/commands/` | ⚠️ own slash surface; `.claude/commands/` don't auto-load | ✅ `.cursor/commands/*.md` | ⚠️ via plugins/skills/agents (`/name`); dedicated file unverified | ✅ **TOML** `.gemini/commands/` (`:` namespacing) |
| **Instruction file** | `CLAUDE.md` (always loaded) | ⚠️ **`AGENTS.md` only** | `.cursor/rules/*.mdc` + **`AGENTS.md`** | **`AGENTS.md`** (also reads `CLAUDE.md`/`GEMINI.md`) | **`GEMINI.md`** |
| **Subagents** | `.claude/agents/*.md` | ⚠️ `.codex/agents/*.toml` | ✅ `.cursor/agents/*.md` (reads **`.claude/agents`**) | ✅ `*.agent.md` (`.github/agents/`) | ✅ `.gemini/agents/*.md` |
| **Interactive questions (`AskUserQuestion`)** | native tool | ❌ no equivalent question-tool → **degrades to a conversational prose question** (HIMMEL-595) | ❌ same | ❌ same | ❌ same |

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

## Hook-chain smoke demo — run after any hook/runner change

`scripts/codex/hook-smoke-demo.sh` (HIMMEL-2000) is the end-to-end proof that
the *project* hook chain still fires clean in **both** harnesses. Run it after
any change to `.codex/hooks.json`, `.codex/run-hook.{sh,cmd}`, the adapter,
`.claude/settings.json` hook entries, `scripts/hooks/run-hook-with-bash.js`, or
any hook script — those are all ways to break a session's hooks **silently**, in
the fail-open direction where nothing in the transcript says so.

```bash
bash scripts/codex/hook-smoke-demo.sh                       # smoke main
bash scripts/codex/hook-smoke-demo.sh --from <worktree>     # smoke a branch BEFORE it merges
bash scripts/codex/hook-smoke-demo.sh --codex-only --keep   # one harness, keep the demo dir
```

It clones the checkout under test into a throwaway dir under the scratch root —
so a broken hook set can never touch the real checkout — and runs four legs:

| leg | what it proves |
|---|---|
| `codex-exec` | a real `codex exec` turn (a shell call plus a file read) exits 0, proves both tool calls, and emits no hook-failure banner in stdout/stderr or the session rollout |
| `codex-replay` | `probe-codex-hooks.ps1 -Replay` **executes** every project hook — the positive control that separates "clean" from "never fired" |
| `claude-print` | the same turn under `claude -p --model haiku` (bank-gated via `bank-preflight.sh`; skips on `SKIPPED-BANK`/`BANK-STALE`) |
| `claude-replay` | every `run-hook-with-bash.js` PreToolUse entry in `.claude/settings.json` is fed a canned benign payload and must exit **0** |

The two replay legs are deliberately asymmetric. `codex-replay` covers every
event; `claude-replay` covers PreToolUse only — that is where the guardrails
live, and it is the one event whose payload can be synthesised without side
effects (a Stop/SessionEnd replay would drive `speak-reply` and the wiki writer
against a fabricated session). The other Claude events are still exercised:
`claude-print` is a real session, so SessionStart, PostToolUse, Stop and
SessionEnd all fire there and any banner is caught by the same scan.

**Tool calls are proven, not assumed.** A turn with no tool calls fires no
PreToolUse hooks, so "no banner" would be true of a run that tested nothing.
The runner plants two per-run secrets the agent can only produce by calling
tools — the clone's short HEAD (a shell call) and a random `SMOKE-TOKEN` written
only into `DEMO-PROJECT.md` (a file read) — and requires both in the reply. The
check does not care *which* tool did the read: Codex has no `Read` tool at all
(see the Codex deep-dive below), and either route fires the PreToolUse chain,
which is what is under test.

Exit 0 = all ran legs clean, 1 = a leg failed, 2 = nothing ran, or an agent leg
ran without its replay leg (both vacuous-pass guards), or a usage error.
`scripts/codex/test-hook-smoke-demo.sh` pins the runner's own contract with
stubbed `claude`/`codex`/`pwsh` — it never spends a token.

Three non-obvious things the runner depends on, in both directions:

- **Codex hook trust is keyed to the absolute `hooks.json` path**
  (`~/.codex/config.toml` → `[hooks.state.'<abs path>:<event>:<i>:<j>']`), so a
  fresh clone at a fresh path is untrusted and its hooks would silently **not
  run** — a vacuous pass. That is why the codex leg passes
  `--dangerously-bypass-hook-trust`: the hook source is one the runner just
  cloned itself from the checkout under test.
- **The Claude leg's untrusted workspace is a feature.** Claude prints
  `Ignoring N permissions.allow entries … not been trusted` and runs with no
  allow-list, so the only thing left that can approve the `git log` call is
  `auto-approve-safe-bash` — a `DONE` reply *is* proof the PreToolUse chain
  fired. Do not "fix" the trust warning.
- **A deliberate guardrail block counts as a failure here.** The prompt is
  read-only and benign; a guardrail firing on it is itself a break.
- **`--from` smokes the COMMITTED state.** `git clone` takes the worktree's
  HEAD, so uncommitted hook edits are invisible to it — commit first, then
  smoke.
- **`--from` is a trust boundary.** Running the hook chain *is* the job, so
  every leg executes the target checkout's hook commands unsandboxed on this
  host. The disposable clone protects the real *checkout* from a broken hook
  set; it is not a sandbox. Point `--from` only at a branch you would open
  interactively. Two things the branch is deliberately *not* trusted with: the
  prompt names the runner-authored `DEMO-PROJECT.md` rather than a tracked file,
  and `AGENTS.md` / `CLAUDE.md` are stripped from the clone (both harnesses
  auto-load them, and they have nothing to do with the hook chain). The clone
  itself is `--no-hardlinks`, so nothing running in the demo can reach the real
  object store.

Side effects are held off two ways. The feature flags are documented opt-outs
only — `HIMMEL_INITIATIVE=` (empty), `HIMMEL_JIRA_NUDGE=0`,
`CLAUDE_END_SESSION_WIKI=0`, `AUTO_ARM_DISABLE=1`. On top of that the runner
blanks every ambient credential a hook could reach out with, by prefix/suffix
rule rather than a list (`TELEGRAM_*`, `JIRA_*`, `ATLASSIAN_*`, `OBSIDIAN_*`,
`*_API_KEY`, `*_API_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`) — `CLAUDE_*`/`ANTHROPIC_*`
excluded, since that family is `native-auth-pin.sh`'s job and blanking it would
break the lane the Claude leg needs. `.env` and `scripts/jira/dist/` are
untracked, so the clone itself carries no credentials and no Jira CLI either.

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
- **events (11, codex-cli 0.149):** PreToolUse, PermissionRequest, PostToolUse,
  PreCompact, PostCompact, SessionStart, **SessionEnd** (added after the
  original 10; input-only, default timeout **1s, capped 3s**), UserPromptSubmit,
  SubagentStart, SubagentStop, Stop. No Notification / PostToolUseFailure.
  Unknown event keys in a `hooks.json` are ignored, not fatal (probed
  2026-08-21). Default command-hook timeout is **600s** for every event except
  SessionEnd — a hung hook without an explicit `timeout` stalls a turn 10 min.
- **config layers:** user / project / session / managed. A project
  `.codex/hooks.json` IS a recognized layer (admins can restrict to managed-only
  via `allow_managed_hooks_only` in `requirements.toml`). Each hook is
  trust-hashed in `config.toml` `[hooks.state]`.
- **env vars:** Codex injects `CLAUDE_PLUGIN_ROOT` **and** `PLUGIN_ROOT` for
  **plugin** hooks ("for OOTB compat with existing plugins"). It does **not**
  inject a project-dir var for project hooks — `cwd` arrives via stdin JSON.
- **execution:** Codex source falls back to `cmd.exe /C` (Windows) / `$SHELL -lc`
  (Unix) when no shell is configured, but **live on Windows (0.149.0, 2026-08-21)
  every hook ran as `pwsh.exe -NoProfile -Command "<command>"`** — see the
  Windows-runner subsection below for the two traps that follow. A hook entry may
  carry `commandWindows` (alias `command_windows`) as a per-platform override.

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

**The fix (HIMMEL-427, split by HIMMEL-2019).** Tracked
`.codex/hooks.json` routes `command` through `.codex/run-hook.sh --sandbox` on
Unix and `commandWindows` through `.codex/run-hook.cmd --sandbox` on Windows.
Both derive + export `CLAUDE_PROJECT_DIR` from their own location; the Windows
wrapper finds Git Bash explicitly (skipping the System32 stub). The wrapper
delegates to `.codex/codex-hook-adapter.sh`, which runs the guardrail and,
for PreToolUse/PermissionRequest exit 2, re-emits the block as Codex's JSON
`permissionDecision:"deny"` (the guardrail's stderr → reason) and exits 0.
**Non-exit-2 outcomes are swallowed, not passed through (HIMMEL-1987):**
Codex 0.149 rejects a Claude `permissionDecision:"allow"`/`updatedInput`
envelope ("unsupported permissionDecision:allow"), so the adapter never
forwards guardrail stdout to Codex's stdout — an allow, an advisory, or empty
output is captured and re-emitted only on the adapter's OWN stderr, and
execution proceeds. The adapter always exits 0 on this path (HIMMEL-1987): the
guardrail's own non-2 exit code is deliberately NOT propagated, because Codex
renders any nonzero non-deny hook as a "failed" banner even though the tool
call still proceeds regardless — spurious noise for a guardrail that simply
exited nonzero. Only a BLOCK — a guardrail exit 2, or an explicit stdout
`permissionDecision:"deny"` — reaches Codex, as deny JSON.

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
the platform wrappers with `--sandbox`, alongside `check-update-available`. Because these hooks
deliver their `<system-reminder>` on **stdout at exit 0** (not exit 2), the
adapter now wraps such a hook's output into the SAME
`hookSpecificOutput.additionalContext` JSON channel. The wrap is **gated on the
event** (`hook_event_name ∈ {SessionStart, UserPromptSubmit}`), NOT on the exit
code: it captures the combined output and always exits 0 (exit-0 stdout AND a
defensive exit-2's stderr both funnel to additionalContext — there is no deny
path for these no-permission-gate events). Event-gating means it never touches
the PreToolUse/PostToolUse path, which (HIMMEL-1987) does NOT pass a guardrail's
stdout through either: Codex rejects a Claude `permissionDecision:"allow"`/
`updatedInput` envelope outright, so an allow from `auto-approve-safe-bash` (or
the Claude-only `rtk-hook-guard`) is swallowed — a correct no-op, since Codex's
own approval/sandbox model already governs the call; only a BLOCK reaches Codex,
as deny JSON. Raw stdout is NOT a reliable Codex context channel (the JSON
`additionalContext` field is — same reasoning as the 565 exit-2 path), so the
wrap is correct-by-construction whether or not Codex also honours raw stdout.
**Verification scope:** the fixture
(`scripts/hooks/test-codex-sessionstart-hooks.sh`) proves the adapter emits the
`additionalContext` JSON end-to-end through `run-hook.sh`; a **live Codex
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
**Blocked**; a benign command is allowed. Unit-tested both platform wrappers,
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
- **No-sandbox mode is diagnostic-only.** The Windows wrapper accepts
  `--no-sandbox <script.sh>` and surfaces the raw child exit code. Do not wire it
  into `.codex/hooks.json`; it is for trusted local debugging, not normal
  guardrail enforcement.
- Run from a git **worktree**, Codex resolves the project root to the **main
  checkout** (the worktree's `.git` is a file, not a dir) and loads *its*
  `.codex/hooks.json` — so the live hook config is the main checkout's, not the
  worktree's. Edit/trust hooks in the primary checkout.
- New project hooks are **trust-hashed on first use**; non-interactive
  `codex exec` needs `--dangerously-bypass-hook-trust` to run not-yet-trusted
  hooks (interactive Codex prompts to trust them once).

**Headless `codex exec` must fail LOUD (HIMMEL-2023 / HIMMEL-1788 instance 5).**
Without the headed TUI nobody sees a wedge, so four holes were closed at once.
(1) **Watchdog.** `scripts/codex/dispatch-codex-exec.sh` ended in an unbounded
`wait`; the codex-exec lane's `timeoutSeconds` in `scripts/lanes/lanes.json` was
registry metadata nothing enforced. The run is now timeboxed to
`CODEX_EXEC_TIMEOUT` (default **1800**, the lane's own number — the suite
asserts the two match, since the dispatcher keeps it as a literal rather than
taking a JSON-reader dependency on its hot path). On expiry the process **tree**
is killed through `scripts/lib/proc-tree.sh` — never a hand-rolled `taskkill` —
and the dispatch exits **124** (what GNU `timeout` and `run-shell-tests.sh`
already report) with a `codex-exec: TIMEOUT after Ns - killed tree` line on
stderr. Start/end rows now land in `~/.himmel/flow-runs.jsonl` exactly as the
`codex-wsl` twin writes them, `outcome` ∈ `complete|timeout|error`; and the
job-registry JSON, previously deleted by the script's own EXIT trap, is moved to
`$CODEX_JOBS_DIR/failed/` on a timeout or nonzero exit — out of the live-jobs
glob so `reap-mcp-fleet` does not re-report a dead job, but still on disk as
evidence. (2) **stdin.** `codex exec` reads stdin to EOF even with an argv
prompt, so an inherited TTY hangs the run before a token is spent; the child now
gets `</dev/null` when stdin is a terminal, while a genuinely piped brief still
crosses on `<&0` (the lane's `briefDelivery: "stdin"` depends on it).
(3) **Hook timeouts on EVERY event.** All seven `.codex/hooks.json`
PreToolUse/PostToolUse entries carry an explicit `timeout` (Codex otherwise
defaults to 600 s, so one guardrail chain could stall a turn ten minutes);
`test-codex-hook-parity.sh` now asserts this for all events, not lifecycle only
(HIMMEL-1985 had skipped the permission-gate ones). Single-script entries mirror
their `.claude/settings.json` twin (15, or 60 for `auto-arm-on-cap` /
`block-edit-on-main`); multi-script **chains** get 60, because Codex runs the
chain sequentially inside ONE command where Claude wires the same guards as N
independent entries. Adding a `timeout` field does **not** re-trust: the trust
key is `<abs path>:<event>:<i>:<j>` (see above), and neither the `command`
strings nor the entry count/order changed. (4) **Native rogue guard.**
`scripts/hooks/block-rogue-codex-exec.sh` mirrors `block-rogue-codex-wsl.sh` for
raw native `codex exec` (bypass `CODEX_EXEC_RAW_OK=1`), wired in the himmel-ops
plugin `hooks.json` beside its WSL sibling. Mirroring both into
`.codex/hooks.json` remains open as HIMMEL-1014.

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
(root-equivalent docker mounts + merged-PR commits went unguarded). Fix: mirror both into `.codex/hooks.json` via the platform wrappers, which
derives the root from its own location. **Both guards are now live-verified under
Codex (codex-cli 0.142.0, HIMMEL-650):** with the project `.codex/hooks.json`
already trusted (no `--dangerously-bypass-hook-trust`), a `codex exec` attempt of
`docker run … -v /etc:…:rw` and a `git commit` on a merged-PR branch (cwd = a
merged worktree) each surface as a Codex `PreToolUse Blocked` carrying the guard's
verbatim reason — so the docker-privesc and merged-PR-commit guards genuinely
*block* (not just fire) at Codex runtime. Adapter-level probes (a PreToolUse
payload through the platform wrapper → `permissionDecision:"deny"`, benign control
allowed) back the same conclusion at zero token cost. The non-security plugin SessionStart
hooks (`inject-where-are-we` / `inject-doc-freshness`) shared the same
root-resolution bug; **HIMMEL-596** mirrors them (plus `inject-initiative`) into
`.codex/hooks.json` SessionStart with the exit-0 `additionalContext` wrap above
(live Codex firing pending a probe).

**SessionEnd → Codex `Stop` (HIMMEL-596 follow-up, HIMMEL-599).** himmel's three
SessionEnd hooks — `refresh-where-are-we-on-end` + `jira-nudge-on-end` (himmel-ops
plugin) and `end-session-wiki` (user-scope settings-template) — are now wired into
a `.codex/hooks.json` **`Stop`** key via the platform wrappers with `--sandbox`, the same
root-resolution fix. Stop is a real Codex event (one of 10); its **input** schema
(`stop.command.input`) carries `cwd` + `transcript_path` (both consumed by the
hooks; it has no `reason` field — `last_assistant_message`/`stop_hook_active`
instead — but `end-session-wiki` reads `.reason // "other"` harmlessly). Unlike
SessionStart, the Stop **output** schema (`stop.command.output`) has **no
`additionalContext` / `hookSpecificOutput`** — only a `continue`/`decision`/
`systemMessage` gate. So the adapter does NOT wrap Stop output as
`additionalContext`; it has a dedicated **`Stop` branch** that runs the hook for
its side effects, routes any output to the adapter's stderr as advisory (never to
Codex's Stop *decision* parser, and never through the generic exit-2 path that
would emit a `hookSpecificOutput` shape Stop's strict `deny_unknown_fields` schema
rejects), and always exits 0 — a SessionEnd advisory hook must never block
teardown. `jira-nudge`'s operator-reaching surface under Codex is its Telegram
relay, not stdout. Covered by the no-token fixture
`scripts/hooks/test-codex-stop-hooks.sh` (static wiring + behavioral, incl. a
gate-ON nudge case and the exit-2-protection case). `scripts/codex/test-codex-hook-parity.sh`
also asserts Claude→Codex inventory parity for end-side members, with every
non-mirrored basename listed in a declared exemption table.

**`telegram-session-end` is wired to Codex `SessionEnd`, NOT `Stop`
(HIMMEL-2021).** It was the one unmirrored member with an operator-visible cost:
an unattended Codex session ended with no notification at all. It is the only
end-side member NOT on `Stop`, and that split is the point. Codex fires `Stop` at
the end of every assistant TURN, so a `Stop` wiring would relay a Telegram
message per turn, and the HIMMEL-2004 queue cannot collapse them: `detach_queued`
drains stdin before enqueuing, so `entryKey` has no `session_id` to key on and
falls back to a random suffix — and even a shared key only merges entries still
PENDING, never two turns drained minutes apart. The three ledger/note hooks are
idempotent refreshes, so per-turn is merely wasteful for them; an operator ping
is not.

`SessionEnd` fires once, and its 1–3 s cap — the reason the other three could not
go there (HIMMEL-599: `end-session-wiki` runs a synchronous transcript scan plus
an unbounded `curl`) — is not a constraint for this one, because it is
enqueue-and-exit: the hook writes one queue entry and returns, and the bounded
worker does the transcript scan and the relay afterwards, outside the event's
budget. Its entry carries `timeout: 3` (Codex's own cap for the event); measured
**1.6 s** end to end on this Windows box through `run-hook.sh` + the adapter
(2026-08-23) — inside the cap, but not by much, so keep that event's wiring to
enqueue-and-exit hooks only.
`codex-hook-adapter.sh`'s `Stop` branch now also handles `SessionEnd` — same
contract, and required for the same reason: that event's output schema is
input-only, so a hook there must never emit a decision envelope.

Nothing about the relay is Codex-specific — it is the same
`scripts/hooks/telegram-session-end.sh` Claude's `SessionEnd` runs, reached
through the same enqueue seam. Two members stay exempt, both by choice, both
recorded in that file's `CLAUDE_END_ONLY` table: `speak-reply.sh` (cosmetic TTS,
gated off) and `session-run-hook.ts` (the session-runs census is Claude-scoped,
and the adapter resolves `scripts/hooks/<name>.sh` only — a `bun` `.ts`
entrypoint has no adapter shape).

**Caveats (do not overclaim).** (1) `end-session-wiki.sh` self-guards out on
`msys*/cygwin*/Windows_NT` (its `.ps1` twin is the Windows-Claude path), so
under Codex on **Windows it captures nothing** —
only `refresh-where-are-we-on-end` + `jira-nudge-on-end` (no platform guard) fire
there (2/3). end-session-wiki capture works on **Linux/macOS/VM Codex**. (2) Even
where it fires, its config path (`$CLAUDE_PROJECT_DIR/.claude/end-session-wiki.json`)
may be Codex-blind (the Codex setup writes elsewhere), so it can capture to a
default/possibly-wrong vault rather than the configured one (separate gap). (3)
Side effects need a `workspace-write` sandbox (Codex suppresses hook writes under
`-s read-only`). (4) `end-session-wiki` runs synchronously (transcript scan + a
`curl` with no `-m` timeout) and can block teardown to its `timeout: 30`. (5)
**Probed 2026-08-21 (codex-cli 0.149.0, `codex exec`):** `Stop` DOES fire at the
end of the exec turn, followed by `SessionEnd` — see the event matrix below. Keep
the Stop wiring (SessionEnd's 1–3s cap cannot carry `end-session-wiki`).

#### Windows hook runner = `pwsh -Command` — the two traps (HIMMEL-1982)

**Live finding (2026-08-21, codex-cli 0.149.0, native Windows, no WSL).** A
himmel Codex session stalled ~10 min per hook (`UserPromptSubmit hook timed out
after 600s`, `SessionStart … 180s`, plus a stream of `exit code 1`). The process
tree under `codex.exe` showed every hook running as
`pwsh.exe -NoProfile -Command "<hook command>"`. Two consequences:

1. **Bare `bash` = the WSL launcher.** PATH lookup from that pwsh resolves
   `bash` to `C:\Windows\System32\bash.exe` — the *machine* PATH lists System32
   before any Git dir, and `Git\usr\bin` lives only in the *user* PATH (appended
   after). With WSL wedged on the box (`wsl -l -v` itself hung) every bare-`bash`
   hook blocked until Codex's **600s default** (180s where the plugin set one).
   Culprits were not himmel's: the global `~/.codex/hooks.json` `rtk-hook-guard`
   (fires on **every** Bash tool call) and the `security-guidance` plugin (4
   events). Codex kills the `pwsh` tree on timeout, but immediately spawns the
   next hook — the session never recovers.
2. **A command that STARTS with a quoted path is a pwsh string expression.**
   `"C:\Program Files\nodejs\node.exe" "x.js"` and superpowers'
   `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start` yield
   `ParserError` → **rc=1 in 0.4s** (the "exit code 1" spam). Fix shape: a
   leading `& ` (`& "C:\…\bash.exe" "…"`), or Codex's `commandWindows` field.

himmel's own `.codex/hooks.json` entries are immune to both — `commandWindows`
selects an unquoted relative `.cmd` that pins Git Bash internally. **A/B replay
(same stdin per event; arm A = registry Machine+User
PATH as Codex inherits it, arm B = `Git\bin` prepended):** all 18 project hooks
ok (<1.4s) on both arms; arm A → `rtk-hook-guard` + 4× security-guidance
**TIMEOUT**, the response-compression plugin's 2 hooks + superpowers **rc=1**; arm B → every bash hook ok, the
quoted-path ones still rc=1 (PATH-independent). `& "C:\Program Files\Git\bin\bash.exe" …`
→ rc 0 / 0.45s on arm A. Operator-side fix applied the same night: global
hooks.json = rtk-hook-guard via `& "…Git\bin\bash.exe"` only (the
response-compression hooks dropped — they were OFF in Claude too, and the plugin
was removed outright in HIMMEL-2033); `security-guidance` + `hookify` `enabled = false` for
Codex (hookify is OFF in Claude; security-guidance is fatal under this runner);
`codex exec` in himmel went from 180s+600s of stalls to **13s** wall.

**Tooling (this ticket):** `scripts/codex/probe-codex-hooks.ps1` enumerates the
*effective* Codex hook set (global + project + enabled plugins, with
`${CLAUDE_PLUGIN_ROOT}` substituted), statically flags `bare-bash` /
`quoted-path-start` / bash-without-timeout, and with `-Replay` re-runs each hook
exactly like Codex (pwsh `-Command`, native PATH, per-event stdin, timeout) and
prints the A/B table. `install-himmel-codex.ps1` runs the static lint as an
advisory phase so a fresh machine sees the trap before its first 600s stall.

**Empirical event / tool-name matrix (codex-cli 0.149.0, Windows, `codex exec`
`--sandbox danger-full-access`, a recorder hook on every event, prompt = shell +
read + create + edit + search):**

| Fired | Event | `tool_name` seen | stdin keys worth knowing |
|---|---|---|---|
| ✅ | SessionStart | — | `source`, `model`, `permission_mode`, `cwd`, `transcript_path` |
| ✅ | UserPromptSubmit | — | `prompt`, `turn_id` |
| ✅ | PreToolUse / PostToolUse | **`Bash`** for *every* shell-shaped call — incl. file reads (`Get-Content -Raw -LiteralPath …`) and search (`rg -l …`); **`apply_patch`** for create/edit (`tool_input.command` = the patch text) | `tool_use_id`, `tool_response` (Post) |
| ✅ | Stop | — | `last_assistant_message`, `stop_hook_active` |
| ✅ | SessionEnd | — | `reason` |
| ⚪ not exercised | PermissionRequest, PreCompact/PostCompact, SubagentStart/Stop | — | no approvals / compaction / subagents in the probe run — not evidence of absence |
| ❌ not a Codex event | Notification, PostToolUseFailure | — | silently ignored in `hooks.json` |

Consequences for himmel's `.codex/hooks.json` matchers (follow-ups, not in this
ticket): **there is no `Read`/`Edit`/`Write`/`Grep` tool under Codex**, so
`Edit|Write|MultiEdit|NotebookEdit` matchers (`block-edit-on-main`,
`block-lesson-enforcement-writes`) **never fire** — and adding `apply_patch` is
not enough, because the guards read `tool_input.file_path`, which apply_patch
does not carry (the paths sit in `*** Add/Update/Delete File:` lines; the guard
exits 0 on an empty path = fails open). `Bash`-matched guards *do* fire, but the
command text is **PowerShell** (`Get-Content`, `Remove-Item`, …), so reader/
destructive token lists tuned for bash shapes under-match. The `Bash` tool name
is itself a Codex compat alias (Claude-engine), which is why the project matchers
`Bash|PowerShell` are harmless but the `PowerShell` half never matches.

**The codex-WSL lane (`dispatch-codex-wsl.sh`) is outside both traps by
construction, but NOT live-verified this round.** Inside the distro Codex runs
hooks via `$SHELL -lc`, reads the distro's own `$HOME/.codex` (not the Windows
one via `/mnt/c` — the lane's quota probe reads `$HOME/.codex/sessions` in-distro),
and the project `.codex/hooks.json` resolves through `run-hook.sh`.
So neither the pwsh quoted-path trap nor the `& "C:\…bash.exe"` global rewrite
reaches it. Unverified because WSL itself was wedged on the box and the lane is
dormant (`CODEX_WSL_LANE_OK` opt-in, HIMMEL-1967); re-probe with `codex exec` in
the in-distro clone after `wsl --shutdown` clears the hang.

**Same benchmark on the other two harnesses (2026-08-21, no finding):** Claude Code
runs hooks through Git Bash (`bash -c`) with `CLAUDE_PROJECT_DIR`/`CLAUDE_PLUGIN_ROOT`
set, so neither trap applies — replaying all 75 effective Claude hooks (user 7,
himmel project 24, enabled plugins 26 across superpowers / security-guidance /
himmel-ops / codex / qmd) on this Windows box: 51 replayed, **every one ≤1.0s**,
the only non-zero being `block-edit-on-main` rc=2 on a synthetic primary-checkout
Edit (= the guard working); 24 skipped as side-effecting (Stop/SessionEnd/
Notification, telegram, speak-reply, end-session-wiki, CR triggers, shadow-ledger,
session-run-hook). hermes has no hook runner of this kind — its `pre_tool_call`
hook, `parity_guard.py` (timeout 10), costs ~125ms per call.

#### hermes end-side hooks (HIMMEL-2021)

hermes wires shell hooks from the `hooks:` block of a profile `config.yaml`;
`hermes_cli/plugins.py`'s `VALID_HOOKS` doubles as the allow-list, and it carries
`on_session_start` / `on_session_end` / `on_session_finalize` / `on_session_reset`.
So the end side was a **choice**, not a runtime limit: until this ticket
`install-himmel-profile.sh` produced exactly one hook (`pre_tool_call` →
`parity_guard.py`) and no installer path could produce an end hook at all.
`himmel_agent` is himmel's main-tier orchestrator, not just a one-shot critic
lane, so an interactive session there ended leaving no ledger refresh and no
operator notification.

What is wired now, and what is deliberately not:

| Claude member | hermes | why |
|---|---|---|
| `telegram-session-end.sh` | **wired** (`on_session_finalize`) | the operator-reaching relay; the same script Claude `SessionEnd` runs. `on_session_end` would relay every turn — see below |
| `refresh-where-are-we-on-end.sh` | **wired** (`on_session_finalize`) | leaves the next session's ledger current; gated on `HIMMEL_WHERE_ARE_WE` as everywhere else |
| `jira-nudge-on-end.sh` | NA by choice | its window is *a Claude session's* commits + breadcrumb; nothing under hermes writes those |
| `end-session-wiki.sh` | NA by choice | self-guards off on Windows and its config path is Claude-scoped (see the Codex caveats above) |
| `session-run-hook.ts` | NA by choice | the session-runs census is Claude-scoped |
| `speak-reply.sh` | NA by choice | cosmetic TTS, gated off by default |
| `shadow-ledger.mjs notify`, `telegram-notification.sh` | NA — runtime | hermes has no notification event in `VALID_HOOKS` |

Three details that are not guessable:

- **`on_session_finalize`, never `on_session_end`.** Finalize is the
  once-per-identity teardown (CLI exit, `/new`, `/reset`, gateway session
  eviction); `on_session_end` fires from `agent/turn_finalizer.py` and is
  **turn-scoped**, so wiring the relay there would notify on every turn.
- **One entry, not one per member.** The hook command is a single
  `run-hook-with-bash.js --chain --lifecycle <member> <member>` launch
  (HIMMEL-2002/2003). `--lifecycle` marks the chain advisory: every member runs,
  stderr is forwarded, the chain always exits 0. It also resolves Git Bash
  itself, which a bare `bash` spawned by hermes on Windows would not (the
  `System32\bash.exe` WSL-stub trap).
- **hermes' payload is not Claude's.** `agent/shell_hooks.py` sends
  `{hook_event_name, tool_name, tool_input, session_id, cwd, extra}` — a `cwd`
  (the hermes process's, per `Path.cwd()`) but **no `transcript_path`**. Both
  wired members tolerate that: `refresh-where-are-we-on-end` drains stdin and
  ignores it, and `telegram-session-end` needs only `.cwd`, degrading to a
  status with no last-assistant summary rather than failing.

Both members are enqueue-and-exit through the HIMMEL-2004 Stop queue, so the
hook returns in well under its `timeout: 20` and one bounded worker does the
work. Registration is gated by hermes' first-use consent prompt
(`~/.hermes/shell-hooks-allowlist.json`, or `--accept-hooks` /
`HERMES_ACCEPT_HOOKS` for non-TTY callers), so a fresh install needs the
operator to approve the new hook once. `scripts/hermes/test-hook-inventory.sh`
asserts the produced inventory against a declared expected set, in both the full
and the degraded (no node on PATH) install shapes — a dropped hook type fails
loudly instead of silently.

**A parity_guard DENY is not terminal upstream (HIMMEL-2025).** hermes'
`agent/tool_executor.py` feeds a `pre_tool_call` block back to the model as an
ordinary tool result (`{"error": block_message}`) — it does not end the turn
or the run. `run_agent.py`'s `max_iterations` defaults to `sys.maxsize`, so a
headless run whose every tool call is denied can retry indefinitely,
burning the bank silently with no verdict (found by the HIMMEL-1969 audit).
himmel bounds this at its own chokepoint rather than upstream: `invoke.sh`
(the single shell-out point, `scripts/hermes/invoke.sh`) wraps every one-shot
in a hard wall-clock timebox (`HERMES_INVOKE_TIMEOUT`, default 1800s, matching
the `hermes-oneshot` lane's `timeoutSeconds`) and kills the process TREE on
expiry (rc 124), mirroring `dispatch-codex-exec.sh`'s watchdog (HIMMEL-2023).
Layered on top, `parity_guard.py` counts identical (same tool + args hash)
denies in a row and, at the Nth (`PARITY_GUARD_DENY_ESCALATE_N`, default 3),
writes an abort marker under `PARITY_GUARD_STATE_DIR` (a per-run dir
`invoke.sh` creates and exports) that the watchdog polls for, killing the run
early with a distinct rc (125) and the escalation reason on stderr + the
ledger row. Both land start/end rows in `~/.himmel/flow-runs.jsonl`. This is a
himmel-side bound, not an upstream fix — a hermes session launched OUTSIDE
`invoke.sh` (interactively, or via a future direct integration) gets neither
protection; the deny-counter state has no effect without
`PARITY_GUARD_STATE_DIR` set, so it fails open to hermes' pre-existing
(unbounded) behavior in that case.

**A hermes run can hit its OWN iteration budget and still exit 0 (HIMMEL-2049).**
Separately from the deny-loop above, hermes' turn loop
(`agent/conversation_loop.py`) counts one iteration per model API call (not
per tool call — several tool calls can land inside one iteration's response)
against `agent.max_turns` (default 500 upstream; the installed `himmel_agent`
profile's `config.yaml` carries `max_turns: 150`, inherited from this
machine's hermes root `config.yaml` via `--clone-from default` at profile
creation, not a himmel-authored override). The budget is **shared across the
run**: parent + every subagent it spawns draw from the same
`agent.IterationBudget` (`agent/iteration_budget.py`), so it is per top-level
invocation of the agent loop, not per-session across separate CLI calls. When
it exhausts, `run_agent.py`'s max-iterations fallback asks the model for one
toolless summary and the CLI (`cli.py`) prints
`⚠ Iteration budget reached (N/max) — response may be incomplete` to
stdout — but still returns rc 0, because the process itself completed
normally. Knob priority (`cli.py` `_resolve_turn_limit`): CLI-level
`max_turns` arg (no invoke.sh flag exposes it) → `agent.max_turns` in the
profile `config.yaml` → legacy root-level `max_turns` (back-compat) →
`HERMES_MAX_ITERATIONS` env → default 500. himmel did **not** raise the
150 default for `himmel_agent` — no evidence yet that himmel's dispatch
shapes need more than 150 model turns, and raising it would let a genuinely
runaway task burn more budget silently before this detection fires — so
visibility came first: `scripts/hermes/invoke.sh` now tees hermes' stdout to
a capture file (reusing `--log`'s sink when given, else a scratch temp file)
and greps it for the banner after the process exits. A hit overrides rc to
**126** (a new code, distinct from the watchdog's 124/125), prints a
`TRUNCATED` advisory to stderr with the captured `(N/max)`, and logs a
`"truncated"` ledger row instead of `"complete"` — a truncated run can no
longer read as a clean pass anywhere downstream (`hermes-critic.sh` already
treats any non-zero `invoke.sh` rc as a failed route and falls back).
`scripts/hermes/test-invoke.sh` feeds a captured banner through a stub and
asserts rc 126 + the ledger outcome.

**hermes exposes no live agent cwd to that hook (HIMMEL-2008).** The payload's
`cwd` is `Path.cwd()` of the agent PROCESS (`agent/shell_hooks.py`
`_serialize_payload`) — the session launch dir, i.e. the primary checkout on
main — while the directory the agent actually works in after a `cd` lives in an
in-process registry (`tools/terminal_tool.py` `_session_cwd`, the anchor
`tools/file_tools.py` `_resolve_base_dir` resolves relative file-tool paths
against). Judging that process cwd made the edit-on-main lock refuse legitimate
worktree writes and commits. `parity_guard.py` now takes the agent cwd from an
explicit `workdir`/`cwd` tool arg → `$TERMINAL_CWD` (exported by `hermes -w`,
`/worktree new`, kanban workers) → the payload `cwd` when it is not merely the
guard's own, plus a `git -C` / `cd <dir> &&` / `pushd <dir>` parse for commits
(whichever sits NEAREST the commit verb wins); with none of those the target is
undeterminable and the branch checks are SKIPPED (fail-open) rather than
resolved against `os.getcwd()`. That command-text parse is unwrapped-only — a
`cd` inside a quoted wrapper payload (`sh -c "cd <dir> && git commit"`) or an
unquoted path with spaces is not parsed, the same best-effort limitation
`terminal_phi_egress_reason` carries, and it fails open (the agent cwd is judged
instead), as do `popd`-restored and subshell `( … )` `cd`s, which the walk
models. The PHI/egress fence is the exception that never fails open: it is
handed the same cwd-resolved target, and the raw path when the cwd is unknown.
**Residual:** `$TERMINAL_CWD` is a session-START signal, not a live one — after
a manual `cd` back into the primary checkout the guard still judges the
worktree, so an on-main write can pass. Not detectable from a hook (the live
cwd lives in hermes' in-process `_session_cwd` registry); the Claude-side
`block-edit-on-main` hook stays the enforcing layer for Claude sessions. Residual,
stated plainly: a RELATIVE write with no cwd signal at all (plain `hermes`
launched in the checkout, agent never `cd`-ed, no `-w`) is now allowed where it
used to be judged against the launch dir — launch with `hermes -w <dir>` or
use `/worktree new` so the guard sees the workspace; absolute paths are judged
exactly as before.

**Claude ↔ Codex hook alignment (2026-08-21 audit):** Claude-side hooks with no
Codex wiring and why — `shadow-ledger.mjs` ×7 + `session-run-hook.ts` ×4
(observability, Claude-only events/plumbing), `trigger-cr-on-pr-create/push`
(CR marker flow is Claude-driven), `block-jira-compound-write`,
`block-tail-pipe-on-gates`, `block-rogue-claude-schedule`,
`block-chokepoint-env-prefix`, `require-quiet-run`, `guard-memory-capture`,
`orchestrator-inline-guard` (candidates to mirror through the platform wrappers — each
needs the tool-name audit above first), `graphify`/`tokensave` hook-guards and
`speak-reply` (Claude-specific tooling), `qmd-staleness-notice` /
`graphify-freshness-advisory` (advisory; cheap to mirror), and — the two the
original audit omitted (HIMMEL-2021) — `telegram-notification.sh`, which is
**runtime-impossible** (Codex has no `Notification` event, see the matrix above),
and `telegram-session-end.sh`, which was the gap and is now **mirrored** onto
Codex `SessionEnd` (not `Stop` — see the paragraph above). Plugins: the
response-compression plugin was OFF both sides (Codex global file had stale
entries — removed) and is gone entirely as of HIMMEL-2033; hookify ON only in
Codex (now off); security-guidance ON both, Codex side now off (runner-fatal);
superpowers ON both (its Codex SessionStart is rc=1 under pwsh — upstream
`commandWindows`/`&` fix wanted, harmless); himmel-ops ON both (Codex side inert
by design, mirrored into the project file — HIMMEL-589/596).

**Hook-set prune + the exit-code contract (HIMMEL-1981, 2026-08-21).** The
follow-up symptom — 5 SessionStart timeouts (5/10/15s) and 2 UserPromptSubmit
`exit code 1` per session, on a box at 73% RAM with ~90 bash processes
(HIMMEL-1978) — resolved into three separate causes, all re-probed post-reboot:

- **The Codex set was never a superset of Claude's**, it is a subset: SessionStart
  carries 4 of Claude's 9, and PreToolUse mirrors 12 of ~26. The one genuine
  drift was `improve-on-submit` — HIMMEL-708 un-wired that no-op hook from
  `.claude/settings.json` (#899) and the Codex copy stayed, so every prompt paid
  a pwsh→cmd→bash chain for a guaranteed `exit 0`. Now removed, and
  `scripts/codex/test-codex-hook-parity.sh` gates the inventory: every guardrail
  `.codex/hooks.json` wires must also be wired for Claude or sit on a short
  declared `CODEX_ONLY` allowlist (`block-terminal-write-fence`,
  `end-session-wiki`), every referenced script must exist, and every lifecycle
  entry must carry an explicit `timeout` (Codex's default is 600s).
- **`check-update-available` is NOT Claude-only** and stays wired: post-HIMMEL-1844
  it reads local remote-tracking refs and detaches the fetch, replaying in 0.81s.
- **The timeouts were load, amplified by the wrapper chain.** Replayed on a
  healthy box (`probe-codex-hooks.ps1 -Replay`), every himmel-owned hook (project
  + plugin) runs **0.36–1.26s**; the only rc≠0 in the effective set is superpowers' quoted-path
  ParserError above. But sandbox-mode `run-hook.cmd` used to spawn a *separate*
  `bash -c "exit 0"` startup smoke test before the adapter — pwsh → cmd →
  bash(smoke) → bash(adapter) → bash(guardrail), five processes per hook, and
  under fork pressure the smoke spawn is itself what fails. It now runs the
  adapter directly and checks its code afterwards: the adapter exits 0 on every
  normal path (a block lives in its stdout JSON — HIMMEL-1987), so a nonzero code
  in sandbox mode means the adapter never ran → emit the fail-closed deny and
  `exit /b 0`. Propagating that code was strictly worse: Codex rendered
  "hook exited with code 1" *and* failed open. `--no-sandbox` still surfaces the
  raw child rc for diagnostics. A **no-permission-gate** hook (SessionStart /
  Stop) instead carries `--lifecycle`: there is nothing to deny there and the
  event's own output schema rejects a PreToolUse deny envelope, so an adapter
  failure reports honestly (stderr + rc 1) rather than emitting a payload shaped
  for the wrong event. The wrapper also EXPORTS the intent as
  `HIMMEL_CODEX_HOOK_LIFECYCLE=1`, because the adapter has preconditions the
  wrapper does not (missing guardrail file, unset project dir) and reaches them
  before stdin is read — so the inbound event is unknown there too. Only the
  adapter's `fail_precondition` consults that flag, never `emit_deny`: a real
  guardrail BLOCK on a permission-gate event must not be downgradeable by a stray
  env var — and for the same reason both wrappers CLEAR any inherited value
  before parsing flags: the wrapper is the only authority on it. The parity gate requires the flag on every SessionStart/Stop entry
  **and forbids it on every permission-gate entry** — the direction that matters,
  since a mis-flagged gate hook would fail open.
  Batch trap found doing this: `exit /b <code>` from a **doubly nested**
  `if (…)` block returns 0 under cmd.exe — same family as the bare-`exit /b`
  trap — so the branches are flat.
- **Plugin-sourced copies stay inert under Codex** (confirmed, not assumed):
  Codex substitutes `${CLAUDE_PLUGIN_ROOT}` but **not** `$CLAUDE_PROJECT_DIR`, so
  himmel-ops' `--optional "$CLAUDE_PROJECT_DIR/scripts/hooks/x.sh"` resolves to
  `/scripts/hooks/x.sh`, misses, and exits 0 silently. The `.codex/hooks.json`
  entries that look like duplicates of the plugin's SessionStart/SessionEnd are
  therefore the *only* working copies — do not "de-duplicate" them.
- Phase 4 of `install-himmel-codex.**sh**` now runs the probe advisorily on
  Windows. `/himmel-update` calls the `.sh` installer, so wiring the lint only
  into the `.ps1` twin meant it never fired on the update path.

**PreToolUse dispatcher (HIMMEL-1989, RAM program P0-2).** Codex launches a full
`pwsh → cmd.exe → Git Bash → adapter` stack **per hook entry**, so the nine
PreToolUse entries a Bash tool call matched cost nine of them (parallel
diagnostic batches peaked at 119–120 Git Bash processes). A `run-hook.cmd`
argument may now be a **chain** — `a.sh+b.sh+c.sh` — that one adapter runs in
order. Guardrail set and order are unchanged; only the number of adapter
launches drops:

| tool | before | after | chain |
|---|---|---|---|
| Bash | 9 entries / ~27 launches | 2 entries / ~11 | 8-chain + `.*` auto-arm |
| PowerShell | 7 / ~21 | 2 / ~9 | 6-chain + `.*` auto-arm |
| Read, Grep | 2 / ~6 | 2 / ~4 | 1 + `.*` auto-arm |
| Edit/Write family | 3 | 2 / ~5 | 2-chain + `.*` auto-arm |

- **The separator is `+`, never `,`.** cmd.exe treats `,` (like space, tab, `;`,
  `=`) as an argument delimiter, so `--sandbox a.sh,b.sh` arrives as `%2=a.sh`
  and the chain silently truncates to its first guardrail — every later guard
  quietly not running, with nothing downstream able to detect it. Measured on
  cmd.exe 10.0.26200 and pinned as a named canary in
  `test-codex-run-hook.ps1`; `test-codex-hook-parity.sh` refuses a comma outright.
- **First deny wins and short-circuits.** Codex ran every matched hook and then
  honoured the deny; the chain stops at the first. Safe because every himmel
  PreToolUse guardrail is a pure check — the one side-effecting hook,
  `auto-arm-on-cap`, deliberately keeps its own `.*` entry so it fires for every
  tool AND regardless of an earlier deny. That entry is the second, deliberate
  invocation in the table above.
- **A bad member denies before any member runs** — never a prefix of the chain
  with the rest skipped. Malformed chains (`++`, leading/trailing `+`, any
  character outside `[A-Za-z0-9._+-]`) fail closed.
- **Matchers had to become disjoint** for this to pay off: `Bash`, `PowerShell`,
  `Read|Grep`, the Edit/Write family and the atlassian MCP matcher now each match
  a tool at most once (`.*` exempt). The parity gate asserts that, because two
  matching blocks silently re-multiply the launches and would not stand out in a
  diff.
- `--lifecycle` semantics are untouched, and Stop stays one entry per hook.
  SessionStart is now chained too (HIMMEL-2003): ONE
  `.codex/run-hook.cmd --sandbox --lifecycle a.sh+b.sh+c.sh+d.sh` entry, 4
  launches → 1 — so its positional trust keys shift 4→1 and the operator must
  **re-trust the hook once**, exactly as after #1804 (see the trap below).
- **The Claude wiring now mirrors this** (HIMMEL-2002): `.claude/settings.json`
  carries the same disjoint matchers and the same chains, dispatched by
  `run-hook-with-bash.js --chain` — see
  [`enforcement.md`](enforcement.md#claude-pretooluse-dispatcher-himmel-2002).

**Trap:** Codex keys hook trust state positionally in `config.toml`
(`[hooks.state.'<file>:<event>:<block>:<hook>']` + `trusted_hash`). Editing
`.codex/hooks.json` shifts those indices, so entries re-prompt for trust on the
next interactive session — and an operator-set `enabled = false` follows the
*position*, not the hook it was aimed at.

**codex-cli 0.153's clamp is loud, not silent (HIMMEL-2492).** Beyond capping
SessionEnd hook timeouts to 3s, it now prints `⚠ clamping SessionEnd hook
timeout to 3s in <file>` once per over-declared entry at startup — an
over-declaration is both noise AND a hook killed mid-flight: on Windows the
launch chain alone measures 0.6-3s under load (HIMMEL-2480), the same
silent-no-run class as HIMMEL-2148. himmel-ops therefore declares `timeout: 3`
on every SessionEnd entry, and every SessionEnd hook full-body detaches
(HIMMEL-636/661) so the parent returns well inside the clamp — gate:
`scripts/hooks/test-session-end-timeout-budget.sh`. The plugin cache is
version-keyed, so a `hooks.json` change to SessionEnd needs a
`.claude-plugin/plugin.json` version bump to reach an installed codex, plus the
one-time hook re-trust the Trap above already describes.

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
`obsidian-triage@himmel`, `telegram-himmel@himmel` (enabled). A few **external**
plugins' `hooks.json` (warp, hookify, ralph-loop, security-guidance) carry a
top-level `description` key that Codex **before `rust-v0.143.0`** rejects
("unknown field description") — Codex skips just those hooks and runs normally
(per-plugin isolation, verified HIMMEL-1104). No himmel-owned plugin ships that
shape. **Fixed upstream:** codex PR #30229 added `description` to the `HooksFile`
schema, shipping in **`rust-v0.143.0`** — on that version or newer the key is
accepted and no sanitizing is needed (HIMMEL-1104; removal of the automatic
phase is HIMMEL-1114). **Sanitize** (supersedes the 2026-06-20 "accept",
operator decision 2026-06-30, HIMMEL-651): `scripts/codex/sanitize-plugin-hooks.{sh,ps1}`
strips the top-level `description` from every `hooks.json` under
`~/.codex/plugins/cache/` (idempotent; re-run after a plugin update re-adds the
field). `install-himmel-codex.{sh,ps1}` runs it automatically as its final phase.

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

Claude's `statusLine.command` is wired to the hud node renderer `marketplace/plugins/claude-hud/dist/index.js` (HIMMEL-718), with the bash bar `scripts/where-are-we/statusline.sh` retained as the rollback fallback;
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

### 9. Interactive questions (`AskUserQuestion`) — Claude-only, graceful prose degradation (HIMMEL-595)

`AskUserQuestion` is a **Claude-Code-only interactive multiple-choice tool**, not
a lifecycle hook event — so unlike the SessionStart/Stop ports (596/599) there is
**nothing to wire** in `.codex/hooks.json`; Codex's 10-event set (and
Cursor/Copilot/Gemini) has no question-tool equivalent. When a skill that says
"ask via `AskUserQuestion`" runs under Codex, the tool is simply absent and the
model **degrades to asking the same question as plain conversational prose**. What
is lost is the structured-choice UI, **not** the question/answer exchange — no
*functional* capability is lost and nothing silently does the wrong thing (the
562 audit's "functional breakage" label overstates it).

**The one real risk** is a model that, seeing "use `AskUserQuestion`", tries to
*call a tool that does not exist* and stalls/errors at a **confirm/disambiguation
gate** instead of narrating. HIMMEL-595 mitigates this on the **3 gates where
failing to ask would matter** with a one-line "if `AskUserQuestion` is unavailable,
ask the same question as plain text and act on the typed answer" guard:
`/overnight-shift` dispatch confirm (`.claude/commands/overnight-shift.md`),
handover repo-resolution (`…/handover/SKILL.md` + `…/references/routing.md`). The
handover **bucket** prompt (`…/references/buckets.md`) already shipped a
degradation-aware line (its safe default is the *opposite* pattern — auto-apply
default and skip, because it *has* a safe default; the gates above must still ask).

**Cosmetic sites are intentionally left untouched** — they self-degrade to prose
with no gate semantics: `/improve` clarifying Qs; `jira-init|create|comment`;
`gh-pr-review|resolve|reply`; `handover-setup`; handover `init`/`register`
(`references/init-register.md`, already self-documents "or text"); handover
slug/hygiene prompts. `luna-upgrade`/`luna-upgrade-all` already confirm via prose
(they never used the tool) and needed no change.

**Follow-up (HIMMEL-649, deferred by operator 2026-06-30):** the *complete* Codex
treatment — measure the actual usage gap on the cosmetic sites under real Codex
runs, and consider a harness-agnostic structured-confirm convention/helper so a
skill expresses "ask a multiple-choice question" once and it renders as
`AskUserQuestion` under Claude and a numbered prose prompt elsewhere (with
input-format validation/retry on the typed answer), instead of per-skill fallback
prose. "The content isn't lacked, just rough around the edges."

### 10. Cheap-lane branch provenance — the `codex/*` convention (HIMMEL-654 WS7)

Hermes-Codex work branches are named `codex/<slug>` (mirrors the spawn-glm
`glm/<slug>` convention). This prefix is the Codex lane's positive cheap-lane
provenance marker — `scripts/cr/lane-classify.sh` reads it to route the branch
through the WS7 D1 lane gate (see
[`docs/internals/validation-gates.md`](validation-gates.md)). Codex work
predating this convention is unmarked and rides the Claude chain unless manually
flagged into the cheap lane by the operator/validating session (recorded in the
D1 verdict PR-body snippet). Absence is never inferred as cheap-lane: an unmarked
branch is indistinguishable from ordinary Claude work (spec D1.1), so structural
cheap-lane enforcement for Codex waits on a future hermes task→branch provenance
record; until it ships, `codex/*` PRs rely on behavioral verdict discipline.

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

### CR gate in an adopter's own repo (HIMMEL-2035)
An adopter arms one repo, run from himmel's **primary checkout**, with
`bash <primary-checkout>/scripts/cr/install-cr-gate.sh --target <path>`, then
reviews by starting a session whose cwd IS that repo and running a bare
`/pr-check` there — `/pr-check` takes no argument, ever (HIMMEL-2226, operator
ruling 2026-08-31); cwd alone selects the repo under review. The installed
`pre-push` hook has himmel's gate path **baked in at install time**, so the
himmel checkout must stay reachable at
that path for the hook to fire — move or delete it and every armed repo's push
gate fails closed with a message naming the remedy (re-run the installer);
`--status` reports `stale`. GitHub-hosted repos only. Detail:
[`enforcement.md`](enforcement.md#cr-gate-outside-the-himmel-checkout-adopters--upstream-prs--himmel-2035).

## Port / guard / accept decisions

| Item | Decision | Where |
|---|---|---|
| Git gates (pre-commit/push) | **Accept** — fire on every harness | — |
| PreToolUse guardrails (Codex) | **Ported** — tracked `.codex/hooks.json` through `run-hook.{sh,cmd}` + adapter | HIMMEL-427/HIMMEL-2019 |
| Rule file (CLAUDE.md → AGENTS.md) | **Port** — covers Codex **+ Copilot + Cursor** | HIMMEL-471 |
| Rule file → `GEMINI.md` | **Port (small), SOFT-DEFER** — extra generator target | HIMMEL-489 |
| Hooks → Cursor (`.cursor/hooks.json`, fail-open) | **Port** (priority 2) | HIMMEL-487 |
| Hooks → Copilot / Gemini | **Port, SOFT-DEFER** (no free usage) | HIMMEL-489 |
| Skills / subagents (Cursor, Copilot) | **Accept** — read `.claude/*` directly | — |
| Driver commands → Codex skills | **Ported (delivered)** — thin tracked `.agents/skills/` wrappers (worktree/clean/clean-garden/shell-lint/guardrail-sim/pr-check) shelling existing `scripts/`; live-verified under codex-cli 0.142.0 | HIMMEL-533 |
| CR reviewer skill for Codex | **Ported (panel-only)** — Codex `pr-check` skill runs the shell panel + clears the CR marker on clean; native `/review` participation deferred post-HIMMEL-527 | HIMMEL-533 |
| where-are-we / status context for Codex | **Port** — use Codex-native advisory context, not Claude `statusLine.command` | HIMMEL-554 |
| Marketplace (all) | **Accept** — each has one | — |
| `AskUserQuestion` (interactive tool) | **Accept (degrades to prose) + guard the 3 gates** — Claude-only tool, no equivalent elsewhere; minimal conversational-fallback line on the confirm/disambiguation gates; complete treatment deferred | HIMMEL-595 → HIMMEL-649 |

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
(qwen) need stronger JSON-obedience scaffolding; Claude adjudicators get
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
