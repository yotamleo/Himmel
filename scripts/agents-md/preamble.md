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

## Scope and standing permissions (HIMMEL-2585)

These three notes are hand-written here rather than generated from `CLAUDE.md`:
they are addressed to non-Claude harnesses reading this file, and `CLAUDE.md`
is not the place to describe how another harness should scope its reading.

**Read what the task needs, not the repo.** The rules below are the standing
rule set for this repository, not a pre-flight checklist. A typo fix does not
earn a full repo map, and no rule here asks you to read a stack of docs before
every edit. Each rule names the hook, gate, or doc that carries its detail —
open that doc when the rule is actually in play, and otherwise proceed.

**The local test suites are safe to run unattended.** `bash
scripts/ci/run-shell-tests.sh` reaches nothing remote and nothing in
production: every suite that would need a VM, the agent stack, or the network
is in its SKIP_LIST and never runs, and what it writes outside the repo is its
own bookkeeping (a resume cursor under `$HOME/.himmel/`) plus scratch under
`TMPDIR`. Run the suites appropriate to
your change, fix failures your change caused, and re-run the affected ones,
without stopping for approval at each step. Stopping for approval still applies
to everything with a blast radius outside the worktree: git pushes, PR and Jira
writes, and anything a hook or gate denies.

**Calibrate testing to the change.** Run the checks the change warrants, and
once they pass, broaden or repeat only when new changes justify it. Do not add
tests that merely restate the implementation for a reversible, low-impact
edit; the preference for the minimum code that solves the problem governs
test code too.

---
