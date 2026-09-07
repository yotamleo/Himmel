---
name: stuck-playbook
description: Use when stuck on a himmel guardrail — a DENIED Bash/Jira write, a permission prompt, or a failed attestation gate.
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

- **Bash command stopped by a permission prompt** (interactively it waits;
  headless/auto it DENIES at rc=0 and continues — a silent no-op) → the native
  matcher bails on `$var` / `$(…)` / backticks / compound operators. Prefer
  literal single commands. (HIMMEL-203 / HIMMEL-1969)
- **Jira write fell through to the classifier and was DENIED** → command-SHAPE
  problem, not a write-permission problem. Prefer literal `node …/jira …` (bare
  or `cd`-prefixed); multi-line bodies via `--comment-file` / `--desc-file`.
  (HIMMEL-205 / 209)
- **Pre-push gate failed on a missing attestation trailer** → put the trailer in
  the FIRST commit; never reactive `--amend` (HARD-blocked in auto-mode). If
  already pushed, add it to the PR body.
- **`/worktree` refused the branch ("PR already MERGED")** → deliberate reuse
  bypasses with `REUSE_MERGED_BRANCH_OK=1` set in the LAUNCHING shell; prefer a
  fresh `type/slug` branch. Lingering merged-PR worktrees are flagged read-only
  by `/himmel-doctor` C7 → run `/clean`.

Why these are a load-on-trigger playbook and not CLAUDE.md rules:
`docs/internals/stuck-playbook.md` § Why this is a playbook, and memory
`feedback_no_operational_rules_in_claudemd`.
