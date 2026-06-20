---
name: minerva
description: Use when turning an idea into an implementation plan — runs brainstorm → spec → plan as ONE pipeline with an ADVERSARIAL CRITIC LOOP between each stage. Trigger on "build/implement/design X", "/minerva", or any feature/capability work that should pass through a spec + plan before code. Composes superpowers brainstorming + writing-plans (no fork); adds a spec-critic and a plan-critic.
---

# minerva — brainstorm → critic → spec → critic → plan (HIMMEL-428)

Orchestrate a hardened path from idea to implementation plan. You drive the
superpowers sub-skills and insert an adversarial critic between each stage, so
every artifact is red-teamed before it advances. minerva pairs the Roman
goddess of wisdom + strategic planning with himmel's critic discipline.

**You are the orchestrator.** Do not let the sub-skills auto-chain past their
stage — you decide when each critic runs and when to advance.

## Mode (gates)

Determine once, up front, whether to pause for the operator between stages:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-mode.sh"
```

- Output `interactive` → after each critic-cleaned artifact, PAUSE for the
  operator to approve or redirect before advancing.
- Output `autonomous` → do NOT pause; the critics are the gate; auto-advance
  through to the terminal.

## Stage 1 — brainstorm → spec

Invoke `superpowers:brainstorming` for the interactive design (clarifying
questions, approaches, the design, and the written spec).

**HALT it before its auto-handoff to writing-plans.** When brainstorming has
written + self-reviewed the spec and the design is approved, return HERE
instead of letting it invoke writing-plans — minerva runs the spec-critic
first.

## Stage 2 — spec critic (adversarial)

Dispatch a fresh subagent (Agent tool) against the written spec file. Loop
fix → re-critic until it returns clean, **cap 2 rounds** (then advance with
any residual findings noted).

CHARTER — paste into the subagent prompt verbatim:

> Red-team this design spec. You are adversarial: find problems, do not
> rubber-stamp. Check ONLY these dimensions and return findings as a list
> (or "SPEC CLEAN" if none):
> 1. Hidden/unstated assumptions.
> 2. Scope creep — features not justified by the stated goal (YAGNI).
> 3. Feasibility gaps — does the proposed approach actually work?
> 4. Internal contradictions between sections.
> 5. Missing or untestable success criteria.
> For each finding: the section + the problem + a concrete fix.

After the loop: if `interactive`, present the hardened spec for approve/redirect;
if `autonomous`, proceed.

## Stage 3 — plan

Invoke `superpowers:writing-plans` on the approved spec to produce the
implementation plan.

## Stage 4 — plan critic (adversarial)

Dispatch a fresh subagent (Agent tool) against the written plan file. Loop
fix → re-critic until clean, **cap 2 rounds**.

CHARTER — paste into the subagent prompt verbatim:

> Red-team this implementation plan. You are adversarial. Check ONLY these
> dimensions and return findings as a list (or "PLAN CLEAN" if none):
> 1. Unordered or missing dependencies between tasks/steps.
> 2. Untestable / unverifiable steps (no clear done-check).
> 3. Missing verification at the end of a task.
> 4. Over-decomposition (busywork) or under-decomposition (a step too big to verify).
> 5. Assumptions embedded in steps that were not present in the spec.
> For each finding: the task/step + the problem + a concrete fix.

After the loop: if `interactive`, present the hardened plan for approve/redirect;
if `autonomous`, proceed.

## Terminal

You now hold a critic-hardened, approved implementation plan. What happens next
depends on the **`execute` leg** of the initiative grammar (HIMMEL-444). Read the
active legs (transport wrapper → the shared resolver; fail-open):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/legs.sh"
```

- If mode is `autonomous` (Stage 0) **AND** the output contains `execute`: do NOT
  stop — **invoke `superpowers:subagent-driven-development`** on the hardened plan
  to implement it task-by-task. This is the execute-seam auto-handoff that makes
  the loop continuous. (You remain the parent: own synthesis across the subagents.)
- Otherwise (interactive mode, or `execute` not active): minerva STOPS here — it
  does not start implementation. Offer the hand-off:

  > Plan ready. Execute with `superpowers:subagent-driven-development`
  > (recommended) or `superpowers:executing-plans`?

Interactive mode never auto-executes (a human is present to choose).
