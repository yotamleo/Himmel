# AGENTS.md — himmel rules for any coding agent (Codex / GPT / Cursor / Copilot / …)

<!-- GENERATED FILE — DO NOT EDIT BY HAND. -->
<!-- Source of truth: CLAUDE.md. Regenerate: node scripts/agents-md/generate.mjs --write -->
<!-- A pre-commit guard (check-agents-md-fresh) blocks commits where this file is stale. -->

> **GENERATED FILE — do not edit by hand.** This file is generated from
> `CLAUDE.md`, himmel's source-of-truth rule file. Edit `CLAUDE.md`, then
> regenerate with `node scripts/agents-md/generate.mjs --write`. A pre-commit
> drift guard blocks any commit where this file is stale.

## Precedence — read this first

When two instructions conflict, apply this order (highest wins):

1. **The user's explicit instructions** in the current session.
2. **The most specific rule** for the file or area you are touching — a
   subdirectory's own rules win over this document.
3. **The rules in this document** (generated from `CLAUDE.md`).
4. **Your platform defaults.**

Phrases in the rules below such as "use judgement", "deviate only for a concrete
reason", or "treat as defaults" are **defaults, not contradictions** — the ladder
above resolves every apparent conflict. Do not spend reasoning reconciling them:
follow the default unless rule (1) or (2) overrides it.

## Reading note for non-Claude harnesses

These rules are generated from a Claude Code rule file. Where they reference
Claude-Code-specific mechanisms — skill / subagent / shell invocation,
"PreToolUse" guardrails, `.claude/settings.json`, named hooks, or slash commands
— they describe himmel's **reference implementation**. Apply the described
*behavior* using your own harness's equivalent mechanism. The git-level gates
(pre-commit / pre-push) run under any harness and are the safety net that always
fires.

---

# himmel — Project Rules

## WHY

himmel is a harness for running Claude Code as a managed, orchestrated
agent: hooks + guardrails + slash commands + a Jira CLI + a handover
system that lets work survive across sessions. Most of what lives here
exists to make Claude's behavior *structurally* safe and repeatable
rather than relying on it to remember prose. Positioning — the
[Tier 3-4 maturity stance](README.md#who-is-this-for--tier-3-4-on-the-maturity-ladder)
and the [Camp 2 memory architecture](README.md#memory-architecture--camp-2-a-context-substrate-not-a-backend)
— lives in `README.md`.

This file is **state, not a prompt**: repo memory of why/map/rules/
workflows, kept short on purpose. Reference detail lives in
`docs/internals/` (linked below) so it loads only when needed. Every
line here is paid for in every session — if a rule isn't session-time
relevant, it belongs in a doc, not here.

## MAP

- `scripts/` — shell tooling (worktrees, guardrails, handover, jira, hooks).
- `scripts/jira/dist/index.js` — the Jira CLI (prefer over Atlassian MCP).
- `.claude/settings.json` — hooks (UserPromptSubmit, PreToolUse) + permissions.
- `.pre-commit-config.yaml` — pre-commit/commit-msg/pre-push gates (source of truth).
- `marketplace/plugins/` — vendored + forked plugins (handover, pr-review-toolkit-himmel, …).
- `docs/internals/` — extracted reference (enforcement, handover-system, jira-plugin, stuck-playbook).
- `docs/setup/`, `docs/luna/`, `docs/security-review.md` — setup, luna guides, security.
- Subdir `CLAUDE.md` (scripts/jira, scripts/handover, scripts/hooks,
  marketplace/plugins) — subtree-local dev conventions, loaded only when
  working there. This file stays cross-project invariants.

## RULES

### Working principles (general defaults)
These ship in the repo so a project-scope clone gets them even without the
operator's user-scope `~/.claude/CLAUDE.md`. Use judgement on trivial tasks.
1. **Think before coding** — state assumptions; if multiple readings exist,
   ask, don't pick silently; if a simpler approach exists, say so.
2. **Simplicity first** — minimum code that solves the problem; nothing
   speculative (no unrequested features, abstractions, or config).
3. **Surgical changes** — touch only what the task requires; match existing
   style; don't refactor what isn't broken; remove only the orphans your own
   change created.
4. **Goal-driven execution** — turn the task into a verifiable success
   criterion, then loop until it passes.

### Git workflow
- All feature work in git worktrees. Never commit directly to main.
- All changes via PR. No direct pushes to main. PRs need ≥1 approval before merge.
- Conventional commits: `type(scope): [HIMMEL-N ]message` where type ∈
  `feat|fix|chore|docs|refactor|test`. Ticket ID optional, validated if present.
- Pre-push gates need attestation trailers (`Platforms tested: <os>` on
  shell/script diffs; `Security reviewed: <token>` on non-docs code) in the
  **FIRST commit** after genuinely testing + reviewing. Recovery when a gate
  fails (never reactive `git commit --amend` — HARD-blocked in auto-mode):
  `himmel-ops:stuck-playbook` skill /
  [`docs/internals/stuck-playbook.md`](docs/internals/stuck-playbook.md).

### Jira — prefer plugin over MCP
Always invoke by ABSOLUTE path from the primary checkout —
`node <repo-root>/scripts/jira/dist/index.js <op>` — never relative from a
worktree (`dist/` is an untracked build artifact; worktrees lack it →
MODULE_NOT_FOUND, silent create failures). Never the global `jira` shim
(unrelated, often-broken npm package). `JIRA_PROJECT_KEY` is required.
`transition` takes a status NAME; multi-line bodies via `--comment-file`/`--desc-file`.
Routing is enforced by `block-backend-tier.sh` (registry: `scripts/backends.json`,
default chain `cli → api → mcp`; hard-blocks MCP if CLI has the verb; advisory
to prefer raw REST before MCP for ops the CLI lacks). The auto-approve hook
grants the CLI reads AND writes (HIMMEL-205).
Op↔MCP mapping + registry detail: [`docs/internals/jira-plugin.md`](docs/internals/jira-plugin.md);
denial recovery: `himmel-ops:stuck-playbook` skill.

### Claude invocation billing (HIMMEL-128)
Headless invocations (`claude -p`/`--print`/`--bg`/Agent SDK; same for
gemini-cli, HIMMEL-157) bill to a separate bucket (announced **2026-06-15**;
**currently PAUSED** by Anthropic as of 2026-06-21 — preference kept because
the split is volatile and may re-activate). Scripts here prefer interactive
`claude "$prompt"`. The
`no-headless-claude`/`no-headless-gemini` pre-commit gates block new
headless calls unless marked `# headless-claude-ok: <reason>` /
`# headless-gemini-ok: <reason>` on the call line or the line above.
Detail + exempt paths: [`docs/internals/enforcement.md`](docs/internals/enforcement.md#claude-invocation-billing-himmel-128).

### Bash command shape (HIMMEL-203)
Native permission matcher bails + PROMPTS on `$var`/`$(…)`/backticks/compound
operators (it never reads the allow-list; hangs in headless/auto). Prefer
**literal single commands** so the allow-list matches. Full symptom→action +
what `auto-approve-safe-bash` does/doesn't cover: `himmel-ops:stuck-playbook`
skill / [`docs/internals/stuck-playbook.md`](docs/internals/stuck-playbook.md).

### Subagent policy (HIMMEL-166)
Frame-shaping rule (per HIMMEL-177 — changes how the whole task is decomposed, so it lives in this file, not lean-invoke). Tier subagents by job (source: @PawelHuryn clip, via synthesis Clippings/_synthesis/2026-05-26-concept-claude-code-architecture-layers.md): Haiku = bulk mechanical work; Sonnet = scoped research/synthesis; Opus = planning, tradeoffs, judgement. Don't escalate tiers without a concrete reason. Spawn-depth limit is 2; Haiku does NOT spawn further subagents. The parent owns the final output + synthesis across everything it spawned. Single-writer rule (@waldenyan, `Clippings/synthesis/2026-05-26-concept-multi-agent-single-writer.md): many readers, ONE writer — never fan parallel writes at one shared artifact. /overnight-shift` parallel fanout is a valid exception: each subagent writes its OWN branch (per-ticket isolation = independent products, not concurrent writes to shared state); parent/operator does the merge + synthesis. Structural PreToolUse enforcement is deferred — the harness doesn't expose current-session spawn-depth or model, so depth-limit-2 and Haiku-no-spawn can't be checked. Revisit per HIMMEL-195 if drift appears.

### Operator conventions (calibrated through repeated sessions)
These shape WHERE new rules/capabilities live. Treat as defaults; deviate
only for a concrete reason.

**Layer selection — lean-invoke vs default (HIMMEL-177).** When adding a
rule/capability, pick the cheapest layer. **Default to lean-invoke**
(operator runs a slash command on demand) UNLESS a trigger applies:
- Safety-critical → `default-hook` (PreToolUse / pre-commit / pre-push). The
  cost of forgetting to invoke manually beats the cost of always running.
  E.g. `block-edit-on-main`, `block-read-secrets`, `no-headless-claude`, `gitleaks`.
- Frame-shaping (changes how Claude reads the *whole* task) → `default-rule`
  (this file). E.g. "PRs require approval", conventional commits, "prefer plugin over MCP".
- High frequency × low marginal cost → `default-rule + installed skill`.
  E.g. `/handover`, `/clean`, `/worktree`.
- Eval-shaped ("read X, decide, write ADR", no ship-code) → `defer`: file a
  timeboxed ticket, close Won't Do on expiry. Do NOT install as always-on.

Default-everything is the failure mode — more always-on rules without a
trigger above creates drift: the file grows, both operator and Claude stop
reading it, rules lose authority. Lean-invoke keeps the cost on the
operator's side, which is the right side: the operator knows when a rule
applies; Claude does not.

**Enforcement strength — structural > instructional (HIMMEL-195).** Track
the **drift count** per instructional rule. First drift is signal; on the
**second** drift escalate to structural (PreToolUse hook, pre-commit/
pre-push gate, classifier, dispatcher guard) — don't wait for the third, by
then the rule has lost authority and Claude is rationalising bypasses.
Prose does not enforce. `default-rule` is a fine first layer, but its next
layer after drift is structural, not "stronger prose." (Worked escalation
examples — MCP-jira, headless-billing, edit-on-main, secrets-reads — and the
per-layer example set: [`docs/internals/enforcement.md`](docs/internals/enforcement.md#operator-conventions--worked-examples).)

### Luna-area docs convention (HIMMEL-138, locked 2026-05-25)
Three tiers for luna-touching artifacts:
1. **Reference docs operators consume** (guides, runbooks, architecture) →
   the relevant repo's `docs/` (himmel luna docs → `himmel/docs/luna/`;
   luna → `luna/docs/`; luna_brain → `luna_brain/docs/`, OSS-quality from
   day 1; plugin specs stay in `plugins/<plugin>/README.md`).
2. **Personal-state work artifacts** (handovers, work/decision logs,
   journal-style decision records, next-session-resume) →
   `<state-repo>/handovers/<USER_SLUG>/<repo-bucket>/` (cross-cutting → `…/cross/`).
3. **Vault content** (clips, notes, daily entries) → unchanged, stays in luna.

Author new luna-touching reference docs in `docs/luna/`; author
journal-style decision records under the appropriate <state-repo> bucket.

**Internal specs/plans → state repo, not himmel `docs/` (HIMMEL-409).** Design
docs, implementation plans, and decision records are work artifacts → the
state bucket `<state-repo>/handovers/<USER_SLUG>/<repo-bucket>/specs/<type>/`
(subfolders `design/`, `plan/`, …; extensible). They never live in himmel
`docs/` (reference + OSS-public only). Cross-repo source of truth = the
**handover skill** (loaded in any repo, unlike this project-scoped file);
existing `docs/specs/` files migrate per-ticket.

**Luna recent context (HIMMEL-254):** read `~/Documents/luna/hot.md` (if present)
first for recent vault context (~500-word Tier-2 hot cache) before crawling luna
`index.md`.

## WORKFLOWS

### Worktree commands (one orchestrator, `scripts/clean-garden.sh`)
- **`/worktree <branch>`** — create only. Branch must be `type/slug`
  (`feat|fix|chore|docs|refactor|test`).
- **`/clean`** — prune merged-PR worktrees only.
- **`/clean_garden <branch>`** — prune AND create in one shot.

Pick by intent: fresh feature = `/worktree`, prune cycle = `/clean`,
both = `/clean_garden`. (Superseded, don't use: `/new-worktree`, `/clean_gone`.)
`/worktree` (via `scripts/_new-worktree.sh`) refuses to create a worktree for
a branch whose PR is already MERGED (bypass: `REUSE_MERGED_BRANCH_OK=1`).
`/himmel-doctor` C7 flags lingering worktrees on merged-PR branches as a
read-only diagnostic (points to `/clean`; no `--fix`; HIMMEL-512).

### Handover
All personal handover state is centralized in your handover state repo
(configured via `/handover-setup` / `$HANDOVER_DIR`; himmel `handovers/`
is a stub). The v2 handover skill +
`~/.claude/handover/registry.json` are the live source of truth —
inspect/change via `/handover repos|register|init`, never by editing
docs. Branched auto-commit + PR-open + flush flows + the single-root
resolver (`scripts/lib/handover-path.sh`, `HANDOVER_DIR` bridge) are
documented in
[`docs/internals/handover-system.md`](docs/internals/handover-system.md).
Scripts MUST source `handover-path.sh` + call `handover_root`, never
hardcode `./handovers/`.

### Overnight mode
Autonomous end-to-end execution of a well-scoped ticket: see
[`docs/handover/overnight-mode.md`](docs/handover/overnight-mode.md).

## ENFORCEMENT (runs automatically)

himmel enforces structurally, not by prose: **9 PreToolUse hooks**
(`auto-approve-safe-bash`, `block-edit-on-main`, `block-read-secrets`,
`block-rogue-claude-schedule` — blocks raw scheduler-arms of claude that bypass
arm-resume.sh (System32-cwd trap, HIMMEL-647),
`block-backend-tier` — registry-driven MCP guard, replaces `block-mcp-when-plugin-exists`,
`auto-arm-on-cap`, `check-cr-marker-on-pr-create`, and `block-docker-privesc` —
root-equivalent docker/podman mount+privilege guard, HIMMEL-441, shipped via the
himmel-ops plugin `hooks.json` so it's live only after `/himmel-update` + a fresh
session; likewise `block-merged-pr-commit` — hygiene guard that blocks committing
onto a merged-PR branch, HIMMEL-512, same plugin delivery), **1 PostToolUse hook**
(`auto-arm-on-subagent-cap` — detects cap in Agent tool results, HIMMEL-276),
**pre-commit/commit-msg/pre-push gates** (source of truth
`.pre-commit-config.yaml`; pre-push incl. `check-platforms-tested`;
pre-commit+pre-push `doc-guard` — himmel-dev-only, blocks ADDING a
command/skill without updating `docs/commands-catalog.md`, gated by
`.himmel-dev` marker; pre-commit `agents-md-fresh` — himmel-dev-only, blocks a
stale `AGENTS.md` (regenerate from this file via
`scripts/agents-md/generate.mjs`, HIMMEL-471)), a
`UserPromptSubmit` hook (`improve-on-submit.sh`,
default OFF), a `SessionStart` hook (`inject-initiative.sh` — opt-in
`HIMMEL_INITIATIVE` drive-to-ship directive over the shared leg grammar
(`scripts/lib/initiative-legs.sh`, HIMMEL-443): `1`/`all` or a comma-subset of
`plan,execute,prcheck,pr,ticket,merge,public,handover`; `HIMMEL_OVERNIGHT`
selects the overnight profile reading `HIMMEL_INITIATIVE_OVERNIGHT`; default OFF,
advisory only; HIMMEL-425), and shared **guardrail predicates** (`scripts/guardrails/lib.sh`).
Hook bypass = session env var set in the LAUNCHING shell (e.g.
`EDIT_ON_MAIN_OK=1 claude`); a per-call prefix does NOT work. Per-repo opt-out:
a local gitignored `.single-writer` at a repo root allows on-main edits there
(single-writer repos — personal vaults, state repos — that commit straight to
main by design); clones without the marker stay protected. Remote auto-actions
(Telegram `/arm`, HIMMEL-424): the trusted bridge parses + invokes directly (agent
out of the trust path); operator-identity (DM or allowlisted group), typed-only,
forwarded-refused; default OFF behind `TELEGRAM_AUTO_ACTIONS` (per-op flag, grammar
mirrors `HIMMEL_INITIATIVE`). Per-hook
behaviour, the full gate list, the guardrail matrix, and the `/arm` surface:
[`docs/internals/enforcement.md`](docs/internals/enforcement.md). Required
environment (HIMMEL-123):
[`docs/setup/new-machine.md`](docs/setup/new-machine.md#1-required-environment-himmel-123).

## REFERENCE INDEX

- [`docs/internals/enforcement.md`](docs/internals/enforcement.md) — pre-commit + all hooks + guardrails + billing detail.
- [`docs/internals/handover-system.md`](docs/internals/handover-system.md) — full handover system + user-slug resolution.
- [`docs/internals/jira-plugin.md`](docs/internals/jira-plugin.md) — Jira plugin↔MCP op mapping.
- [`docs/operator-conventions.md`](docs/operator-conventions.md) — durable operator working-habits (jira CLI invocation, CR/merge habits, clips-are-pointers) consolidated from per-user auto-memory (HIMMEL-179 sharp #5).
- [`docs/internals/stuck-playbook.md`](docs/internals/stuck-playbook.md) — guardrail-recovery escape-hatches (surfaced load-on-trigger by the `himmel-ops:stuck-playbook` skill on a denial/friction symptom).
- [`docs/tool-adoption/rubric.md`](docs/tool-adoption/rubric.md) — the decision method every community-tool eval runs through (goal/KPI, trust-posture tiers, ADOPT/PILOT/REJECT, measurement protocol).
- [`docs/tooling-catalog.md`](docs/tooling-catalog.md) — all tools/scripts/plugins in active use.
- [`docs/commands-catalog.md`](docs/commands-catalog.md) — project-local slash commands (`.claude/commands/`).
- [`docs/setup/new-machine.md`](docs/setup/new-machine.md) — fresh-machine setup.
- [`docs/internals/harness-compat.md`](docs/internals/harness-compat.md) — running himmel under Codex / other harnesses (compat matrix + port/guard/accept decisions, HIMMEL-470).
- [`docs/internals/environment-gotchas.md`](docs/internals/environment-gotchas.md) — Windows / Git-Bash / Bash-tool / content-filter environment traps (generic, adopter-facing).
