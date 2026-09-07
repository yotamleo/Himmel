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
- **Every Write/Edit under `/tmp` refused: "cannot determine branch for
  '/tmp'"** → a stray `.git` in an ANCESTOR of the edited path (not the file
  itself) makes `block-edit-on-main` treat that ancestor as a repo root.
  `/himmel-doctor` C36-stray-tmp-git catches it; `rmdir` it if empty, stop and
  name it (never delete contents) if not. (HIMMEL-2739)
- **An ad-hoc Bash line containing the literal word "enable" is refused in a
  worktree-pinned session** → the harness's own worktree-isolation guard, not
  a himmel script; independent of `git` involvement. Do not reshape the
  command to dodge it (the rule above still applies) — rephrase to avoid the
  word where possible, or defer to the operator. (HIMMEL-2739)
- **A late fix after plain `pre-commit run` is gated against stale content**
  → it stashes every unstaged file repo-wide and lints the STAGED index;
  `--all-files` does NOT stash. `git add` the fix again before re-running.
  (HIMMEL-2739)

Why these are a load-on-trigger playbook and not CLAUDE.md rules:
`docs/internals/stuck-playbook.md` § Why this is a playbook, and memory
`feedback_no_operational_rules_in_claudemd`.
