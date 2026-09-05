---
name: minerva
description: Grill / stress-test / brainstorm an idea, or design/build a feature, into a critic-hardened spec + plan. /minerva
---

# minerva — grill → brainstorm → critic → spec → critic → plan (HIMMEL-428)

Orchestrate a hardened path from idea to implementation plan. You drive the
superpowers sub-skills and insert an adversarial critic between each stage, so
every artifact is red-teamed before it advances. minerva pairs the Roman
goddess of wisdom + strategic planning with himmel's critic discipline.

**You are the orchestrator.** Do not let the sub-skills auto-chain past their
stage — you decide when each critic runs and when to advance.

**One front door (HIMMEL-2039).** grill / stress-test / interrogate / brainstorm
/ "build / design / implement X" / `/minerva` all land here. The grilling
stance is minerva's Stage 1a, not a second skill: if
`mattpocock-skills:grilling` fires, run Stage 1a below and continue the
pipeline rather than stopping at a shared understanding.

## Mode (gates)

Determine once, up front, whether to pause for the operator between stages.
`CLAUDE_PLUGIN_ROOT` is set under Claude Code but **empty in a Codex skill
shell** (HIMMEL-606), so resolve the himmel-ops scripts dir with a fallback
chain before invoking — the resolver below is reused verbatim in the Terminal
section (keep both copies byte-identical):

```bash
# >>> himmel-ops scripts resolver (CLAUDE_PLUGIN_ROOT is empty in a Codex skill shell)
S="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}"
if [ -z "${S:-}" ] || [ ! -f "$S/autonomy-mode.sh" ]; then
  R="${HIMMEL_REPO:-}"; [ -f "$R/scripts/lib/initiative-legs.sh" ] || R="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -f "$R/scripts/lib/initiative-legs.sh" ] || R="$HOME/Documents/github/himmel"
  S="$R/marketplace/plugins/himmel-ops/scripts"
  [ -f "$S/autonomy-mode.sh" ] || for d in "$HOME"/.codex/plugins/cache/himmel/himmel-ops/*/scripts; do
    [ -f "$d/autonomy-mode.sh" ] && { S="$d"; break; }
  done
fi
# <<< himmel-ops scripts resolver
bash "$S/autonomy-mode.sh" 2>/dev/null || echo interactive
```

- Output `interactive` → after each critic-cleaned artifact, PAUSE for the
  operator to approve or redirect before advancing.
- Output `autonomous` → do NOT pause; the critics are the gate; auto-advance
  through to the terminal.

## Stage 1 — grill → brainstorm → spec

### 1a. Grill (the interrogation phase, HIMMEL-2039)

Before any design is written, interrogate the idea until it survives. Map it as
a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose
prerequisites are already settled — the questions you can ask *now* without
guessing at answers you have not heard yet. Ask the WHOLE frontier in one
round, numbered, each with your recommended answer:

```
❓ **Q1** — **<question title>**: <question body, options if any>

➡️ <your recommended answer>
```

Then wait. Each round's answers reshape the tree: settled decisions push the
frontier outward and unblock the questions that depended on them. Recompute the
frontier and ask the next round. A question whose answer depends on another
question still open in THIS round belongs to a LATER round.

**Facts are your job, never the operator's.** When a frontier question needs a
fact from the environment, go get it — never ask for what you could look up.
Look it up inline when a handful of tool calls settles it; delegate only a
genuinely independent, sizeable search (CLAUDE.md subagent policy). Do not
block on it: only the questions downstream of a running exploration wait; ask
the rest of the frontier now. The *decisions* are the operator's — put each to
them and wait.

**Stop condition:** the frontier is empty — every branch visited, nothing
silently assumed. Do not advance to 1b until the operator confirms you have
reached a shared understanding.

`autonomous` mode has no operator to answer: still build the tree and still
write the frontier out, but answer each question yourself with the recommended
answer and carry the whole Q/A list into the spec as an explicit ASSUMPTIONS
section — the Stage-2 critic red-teams it (charter dimension 1, hidden
assumptions).

### 1b. Brainstorm → spec

Invoke `superpowers:brainstorming` for the design and the written spec, carrying
the Stage-1a outcome in as settled context — do not re-ask what the grill
settled.

**HALT it before its auto-handoff to writing-plans.** When brainstorming has
written + self-reviewed the spec and the design is approved, return HERE
instead of letting it invoke writing-plans — minerva runs the spec-critic
first.

## Stage 2 — spec critic (adversarial)

Dispatch a fresh subagent (Agent tool) against the written spec file. Loop
fix → re-critic until it returns clean, **cap 2 rounds** (then advance with
any residual findings noted).

CHARTER — the single source is **`panel-charter.md`** in this skill dir; paste
its contents into the subagent prompt verbatim. Do NOT inline a second copy here
— the file is the one source, shared with the panel lane below (two prose-synced
copies is the instructional-not-structural drift HIMMEL-195 warns against).

**⚑ fork-1 ADVISORY cross-model panel lane (HIMMEL-414 WS4).** After the Claude
critic round, run the free-cloud critic panel over the SAME spec as an advisory
second opinion — it catches the same-family popularity trap (Claude reviewing
Claude). The Claude critic stays the GATE; the panel only feeds its next round.
Resolve paths from the himmel checkout (minerva runs inside it):

```bash
REPO="$(git rev-parse --show-toplevel)"; CR="$REPO/scripts/cr"
CHARTER="$REPO/marketplace/plugins/himmel-ops/skills/minerva/panel-charter.md"
# 1. Enumerate the advisory critic rows (free-preferred; if the registry has NO
#    free rows, fall back to the PAID rows rather than an empty panel — an empty
#    advisory panel silently degrades minerva to claude-only, HIMMEL-1221 G3).
#    Reads the UNIVERSAL critics.json (adopter-neutral), NOT the operator overlay.
bash "$CR/advisory-rows.sh" "$CR/critics.json"
# 2. Per row, critique the spec artifact (dead row exits non-zero → FAIL OPEN, note + continue):
#    bash "$CR/artifact-critic.sh" --artifact <spec-file> --charter "$CHARTER" --model <model> --slug <slug>
```

Then the Claude critic ADJUDICATES each panel finding, one line per finding:
`VERDICT [<slug>-N] = agreed|disproved|conflict|unaddressed`. Agreed findings
join the fix list for the next round. Append EVERY verdict + one availability
record per row to the correctness ledger, segmented as spec-artifact records:

```bash
bash "$CR/ledger-append.sh" finding --head <spec-id> --model <slug> --id <slug>-N --verdict <verdict> --artifact spec
bash "$CR/ledger-append.sh" avail   --head <spec-id> --model <slug> --status ok|unavailable         --artifact spec
```

`cr-scores.sh --artifact spec` then reports panel accuracy on spec artifacts,
separate from CR-diff records. Panel failure of ANY row = fail-open (note +
continue); the Claude critic remains the gate.

After the loop: if `interactive`, present the hardened spec for approve/redirect;
if `autonomous`, proceed.

## Stage 3 — plan

Invoke `superpowers:writing-plans` on the approved spec to produce the
implementation plan.

## Stage 4 — plan critic (adversarial)

Dispatch a fresh subagent (Agent tool) against the written plan file. Loop
fix → re-critic until clean, **cap 2 rounds**.

CHARTER — the single source is **`plan-charter.md`** in this skill dir; paste its
contents into the subagent prompt verbatim (no inline second copy — same
HIMMEL-195 rule as Stage 2).

**⚑ fork-1 ADVISORY panel lane** — mirror Stage 2's lane on the PLAN artifact:
same `advisory-rows.sh` enumeration (free-preferred, paid-fallback; HIMMEL-1221
G3) + fail-open + Claude-adjudicates-and-gates, but with
`--artifact <plan-file> --charter "$REPO/marketplace/plugins/himmel-ops/skills/minerva/plan-charter.md"`
and the ledger records segmented as `--artifact plan`
(`cr-scores.sh --artifact plan` reports them). The Claude plan-critic remains the
gate; the panel is advisory.

After the loop: if `interactive`, present the hardened plan for approve/redirect;
if `autonomous`, proceed.

## Terminal

You now hold a critic-hardened, approved implementation plan. What happens next
depends on the **`execute` leg** of the initiative grammar (HIMMEL-444). Read the
active legs (transport wrapper → the shared resolver; fail-open). Re-resolve the
scripts dir (this runs in a separate shell from the Mode section — same resolver,
byte-identical):

```bash
# >>> himmel-ops scripts resolver (CLAUDE_PLUGIN_ROOT is empty in a Codex skill shell)
S="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}"
if [ -z "${S:-}" ] || [ ! -f "$S/autonomy-mode.sh" ]; then
  R="${HIMMEL_REPO:-}"; [ -f "$R/scripts/lib/initiative-legs.sh" ] || R="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -f "$R/scripts/lib/initiative-legs.sh" ] || R="$HOME/Documents/github/himmel"
  S="$R/marketplace/plugins/himmel-ops/scripts"
  [ -f "$S/autonomy-mode.sh" ] || for d in "$HOME"/.codex/plugins/cache/himmel/himmel-ops/*/scripts; do
    [ -f "$d/autonomy-mode.sh" ] && { S="$d"; break; }
  done
fi
# <<< himmel-ops scripts resolver
bash "$S/legs.sh" 2>/dev/null || true
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
