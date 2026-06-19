# himmel-ops

Harness-meta operational skills for himmel — the load-on-trigger guardrail
recovery layer.

## What it does

himmel enforces its workflow structurally (PreToolUse hooks, pre-commit /
pre-push gates, an auto-mode classifier). When you hit one of those guardrails,
the recovery rule has to be available **without** living in the always-on root
`CLAUDE.md` — every line there is paid for in every session (HIMMEL-211). This
plugin holds that operational knowledge as a skill that loads only on the
friction symptom, at zero always-on token cost.

## Skills

### `stuck-playbook`

Triggers on the **denial / friction symptom**, not on a slash command — e.g.
an auto-mode Bash or Jira write was denied, a command fell through to the
classifier, a permission prompt hung then aborted, or a pre-push gate failed on
a missing attestation trailer. It points at the full symptom→action playbook in
the repo (`docs/internals/stuck-playbook.md`) and surfaces the matching
recovery section.

Symptom index:

- **Bash command hangs on a permission prompt then aborts** — the native
  matcher bails on `$var` / `$(…)` / backticks / compound operators. Prefer
  literal single commands. (HIMMEL-203)
- **A Jira write fell through to the classifier and was denied** — a command
  *shape* problem, not a permission problem. Prefer the literal
  `node …/jira …` invocation; multi-line bodies via `--comment-file` /
  `--desc-file`. (HIMMEL-205 / 209)
- **A pre-push gate failed on a missing attestation trailer** — put the trailer
  (`Platforms tested:` / `Security reviewed:`) in the **first** commit; never a
  reactive `git commit --amend` (HARD-blocked in auto-mode). If already pushed,
  add it to the PR body.

**The one rule that overrides every workaround:** never reshape a command to
dodge a guardrail. The guardrails are structural on purpose (HIMMEL-195:
structural > instructional). If a write is still denied after applying the
matching section, that denial is *correct* — defer to the operator, and prefer
a structural fix (a new `auto-approve-safe-bash` case, a CLI flag) over a
cleverer command.

## Install

Ships as part of himmel's marketplace. With the marketplace registered:

```
/plugin install himmel-ops
```

No always-on cost — the skill loads only when a guardrail symptom appears.

## Why a plugin

Operational escape-hatches are exactly the kind of rule that should **not** be
always-on prose: they are needed rarely, and putting them in `CLAUDE.md` both
bloats every session and invites Claude to rationalise bypasses. Packaging them
as a load-on-trigger skill keeps the root rules lean while making recovery
guidance available the moment it is relevant (memory:
`feedback_no_operational_rules_in_claudemd`).

## Reference

- Full playbook: [`docs/internals/stuck-playbook.md`](../../../docs/internals/stuck-playbook.md)
- Enforcement detail (hooks + gates + classifier): [`docs/internals/enforcement.md`](../../../docs/internals/enforcement.md)

## minerva — brainstorm → critic → spec → critic → plan (`/minerva`)

`/minerva` (skill `himmel-ops:minerva`) runs the recurring idea→plan workflow as
one pipeline with an adversarial critic between each stage, so every artifact is
red-teamed before it advances:

1. **Brainstorm → spec** — drives `superpowers:brainstorming`, halted before its
   auto-handoff to writing-plans.
2. **Spec critic** — a fresh adversarial subagent red-teams the spec (hidden
   assumptions, scope creep, feasibility, contradictions, missing success
   criteria); loop fix→re-critic, cap 2 rounds.
3. **Plan** — drives `superpowers:writing-plans` on the approved spec.
4. **Plan critic** — adversarial subagent red-teams the plan (unordered deps,
   untestable steps, missing verification, over/under-decomposition); cap 2 rounds.
5. **Terminal** — a critic-hardened plan; offers hand-off to
   `superpowers:subagent-driven-development` / `executing-plans`. minerva does
   not implement.

**Gates are mode-driven.** `scripts/autonomy-mode.sh` reports `autonomous` when
`HIMMEL_INITIATIVE` or `HIMMEL_INITIATIVE_OVERNIGHT` is set (initiative mode,
HIMMEL-425) — then the critics are the only gate and the pipeline auto-advances.
Otherwise it reports `interactive` and minerva pauses for the operator after each
critic-cleaned artifact.

**Distribution:** ships in this plugin (skill + command + helper), so it installs
system-wide and works in any repo, with no `superpowers` fork. A deferred
companion (HIMMEL-429) adds a Skill-tool hook so the critic also fires when
brainstorming/writing-plans is triggered without `/minerva`.
