# Tool-adoption rubric — the decision method (HIMMEL-200)

> The method every himmel community-tool eval runs through (token
> optimizers, memory layers, PreToolUse hooks, MCP servers, skills).
> Part of the HIMMEL-199 framework: this rubric decides; the registry
> (`registry.md`, HIMMEL-201) records the decision so it
> isn't re-litigated.

## Why

Community tooling lands fast and markets hard. Without a method, evals
drift into "looks cool, installed" — and the cost shows up later as
guardrail surface we don't understand, benchmark numbers we never
reproduced, and a CLAUDE.md/hook stack nobody can reason about. This
rubric forces every eval to name its goal, pick a trust posture
proportional to blast radius, and end in a recorded decision (ADR).

**Open tool-eval tickets route through this file** before any
install/measure: HIMMEL-167 (skill-factory), HIMMEL-170 (token-savior),
HIMMEL-182 (tdd-guard), HIMMEL-183 (context-mode), LUNA-44 (engram).
Each should cite this rubric's decision states + measurement protocol in
its ADR.

## 1. Goal articulation

Before touching the tool, write three lines. If you can't, the eval
isn't ready.

- **Problem** — the concrete friction in a real himmel session this is
  meant to remove. Not "X is a category we lack" — a moment that hurt.
- **Desired outcome** — what a session looks like *after* adoption.
  Observable, not aspirational.
- **KPI — outcome-per-session.** Did the workday go better: fewer stuck
  loops, fewer manual interventions, a ticket shipped that otherwise
  wouldn't have, less operator babysitting.

**Vanity-metric trap (call it out loud): %-token-reduction is NOT the
KPI.** A tool can cut tokens 40% and make sessions worse — by hiding
context the agent needed, adding a guardrail-dodging shape, or trading a
cheap turn for an expensive retry. Token count is an input cost, not an
outcome. If the only number a tool's marketing offers is %-tokens-saved,
treat that as a reason to read the impl, not a reason to adopt (see
tier 3 below). Measure the session, not the byte count.

## 2. Trust-posture tiers

Pick the posture by blast radius, not by how polished the README is.
Higher tier = more verification before the tool runs anywhere real.

- **`docs-claim-trusted`** *(rare)* — take the vendor's docs at face
  value, no impl read. Only when: established vendor + low blast radius
  (read-only, no hook/secret/network surface) + trivially reversible.
  Most tools do NOT qualify; default to a higher tier.
- **`community-active → validate-before-adopt`** — active community
  project, plausible but unverified. **Sandbox-test in a throwaway
  worktree** (`/worktree`) before it touches a real session: run it
  against representative work, watch what it actually does, then discard
  the worktree. Adopt only on validated behavior, never on the pitch.
- **`source-read-mandatory`** — read the implementation before it runs
  anywhere. Required, no exceptions, for anything that:
  - touches the **PreToolUse hook stack** (it can see/alter every tool
    call — a malicious or buggy hook is a full compromise),
  - touches **secrets** (reads env/credential paths, network egress),
  - claims **benchmark numbers we cannot independently reproduce** — if
    we can't reproduce the claim, we read the code that makes it or we
    don't believe it.

**Injection scan (every tier, before install):** scan the tool's
SKILL.md / commands / hooks for prompt-injection patterns
(instruction-override phrases, fake system/assistant tags,
reader-agent tool-invocation requests, allowlist/approval
manipulation, prompt-exfiltration requests) — ~36% of public skills
carry prompt-injection vectors
(@affaan, 2026-05-26; HIMMEL-256). The `/harvest-clips` Phase 4.5
pattern list (`marketplace/plugins/obsidian-triage/tools/harvest-clip-body-batch.py`
`INJECTION_PATTERNS`) is the reusable starting point.

When in doubt between two tiers, take the higher one. The cost of an
over-careful eval is a few minutes; the cost of a trusted-but-hostile
hook is the whole session's trust boundary.

## 3. Decision states

Every eval ends in exactly one of these, **each recorded as an ADR**
(decision + why + date) so a future session doesn't re-open a settled
question. Log the ADR in the registry (`registry.md`, HIMMEL-201).

- **ADOPT** — install it, wire it into the default path. Requires a
  passed measurement (§4) or a tier-1 trivially-reversible call. The ADR
  names the goal it served and the measured outcome.
- **PILOT-MEASURE** — promising but unproven. Run the measurement
  protocol on a real workday, time-boxed, behind an opt-in flag. The
  pilot is not adoption; it ends in ADOPT or REJECT with the captured
  numbers attached.
- **REJECT** — not adopting. **Record it anyway** with the reason
  (failed measurement / blast radius too high / goal not real / impl
  read failed). Rejected tools are the most valuable registry entries:
  they stop the same tool being re-evaluated from scratch next quarter.

## 4. Measurement protocol

Adopt on evidence from a **real himmel workday**, not a synthetic demo.

1. **Pick a representative task** — a real ticket or recurring chore,
   not a benchmark crafted to flatter the tool.
2. **Capture baseline (before)** — run the workday without the tool.
   Record outcome-per-session signals: did the ticket ship, how many
   stuck loops / permission hangs / manual operator interventions, did
   the agent need a re-launch. Tokens may be noted as context, never as
   the verdict.
3. **Capture treatment (after)** — same shape of task with the tool
   active. Record the same signals.
4. **Compare on outcome, not bytes.** The tool wins only if the *session*
   went better — work shipped with less friction. A token drop with
   equal-or-worse outcomes is a REJECT, not a win.

The before/after baseline above applies to **net-new installs**. For
items **already in use** — our own skills/tools running every session,
with no "without" baseline to capture — the accepted protocol is
**measure-during**: 0-token-cost live telemetry captured as a side-effect
while real work runs, analysed later (HIMMEL-236 — record format + emit
lib: [`telemetry.md`](telemetry.md)). The verdict is
still outcome-per-session, just earned retroactively from real workdays
instead of an A/B.

**Avoiding the vanity-metric trap in practice:** if your before/after
table has only a token column, the measurement is incomplete — go back
and fill the outcome signals from step 2. A single number that always
moves in the "good" direction (tokens down) and never captures regressions
(work that didn't ship, loops that got worse) is exactly the metric to
distrust. The honest signals are the messy ones.
