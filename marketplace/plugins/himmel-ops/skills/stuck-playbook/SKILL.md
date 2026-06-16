---
name: stuck-playbook
description: Use when stuck on one of himmel's own guardrails — an auto-mode Bash/Jira write was DENIED, a command fell through to the auto-mode classifier, a permission prompt hung then aborted, or a pre-push gate failed on a missing attestation trailer (`Platforms tested:` / `Security reviewed:`). Surfaces the operational escape-hatches that deliberately do NOT live in the always-on root CLAUDE.md (HIMMEL-211). Triggers on the denial/friction symptom, not on a slash command. Load-on-trigger, zero always-on token cost.
---

# stuck-playbook — guardrail-recovery escape-hatches (HIMMEL-211)

You hit a himmel guardrail and need the recovery rule. The full symptom→action
playbook lives in the repo at **`docs/internals/stuck-playbook.md`** — read it
now and apply the section matching your symptom.

```
Read docs/internals/stuck-playbook.md
```

(In a worktree, the repo root is the worktree dir; the path is the same.)

## The one rule that overrides every workaround

**Never reshape a command to dodge a guardrail.** The guardrails are structural
on purpose (HIMMEL-195: structural > instructional). If a write is still denied
after applying the matching playbook section, that denial is *correct* — **defer
to the operator**. Prefer a structural fix (a new `auto-approve-safe-bash` case,
a CLI flag) over a cleverer command.

## Symptom index (detail in the playbook doc)

- **Bash command hangs on a permission prompt then aborts** → the native matcher
  bails on `$var` / `$(…)` / backticks / compound operators. Prefer literal
  single commands. (HIMMEL-203)
- **Jira write fell through to the classifier and was DENIED** → command-SHAPE
  problem, not a write-permission problem. Prefer literal `node …/jira …` (bare
  or `cd`-prefixed); multi-line bodies via `--comment-file` / `--desc-file`.
  (HIMMEL-205 / 209)
- **Pre-push gate failed on a missing attestation trailer** → put the trailer in
  the FIRST commit; never reactive `--amend` (HARD-blocked in auto-mode). If
  already pushed, add it to the PR body.

Why these are a load-on-trigger playbook and not CLAUDE.md rules:
`docs/internals/stuck-playbook.md` § Why this is a playbook, and memory
`feedback_no_operational_rules_in_claudemd`.
