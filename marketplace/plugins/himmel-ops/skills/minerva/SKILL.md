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
# 1. Enumerate the free critic rows:
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1])).panel.filter(r=>r.tier==="free").forEach(r=>console.log(r.slug+"\t"+r.model))' "$CR/critics.json"
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
same free-row enumeration + fail-open + Claude-adjudicates-and-gates, but with
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
