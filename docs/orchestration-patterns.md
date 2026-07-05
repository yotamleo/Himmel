# Orchestration patterns (HIMMEL-654 WS3)

Coordination doctrine for himmel fan-outs, verify loops, and overnight shifts,
so every future dispatch stops re-deriving it. **The binding physical
constraint: the operator's attention is the serial resource — "you are the
GIL"** (`60-Maps/agent-orchestration-MOC.md`, addyosmani). Orchestration design
optimizes the human serial fraction (batched review surfaces, verifier lanes,
closed-loop specialists), not raw agent count.

This doc names slot **classes**, never concrete models — model binding is WS2's
router (the WS2↔WS3 seam: *routing = model selection; orchestration = task
decomposition*). Each claim below carries its evidence pointer inline (a luna
clip path or a shipped himmel code path); the resolved evidence table is at the
foot of the doc.

## 1. Default shape: map-reduce-and-manage

The default — and only production-coherent — fan-out shape is
**map-reduce-and-manage**: the orchestrator decomposes, workers contribute
**intelligence, not actions**, and **writes stay single-threaded through the
orchestrator**. Unstructured swarms are a distraction, not a scaling strategy.
_Evidence:_ Cognition / walden_yan
(`Clippings/_done/2026-05/@walden_yan – 2026-05-25T030401+0200.md`).
_Shipped:_ `/overnight-shift` (`.claude/commands/overnight-shift.md`) is himmel's
live implementation — one worktree-isolated subagent per ticket, a self-heal
pass (`scripts/overnight/self-heal.sh`), then a single-threaded synthesis +
morning report (`scripts/overnight/morning-report.sh`); per-ticket branches are
independent products, the parent owns merge + synthesis (single-writer).

## 2. The four shapes + use-when / breaks-when

Catalog style after sairahul1's 13-pattern catalog
(`Clippings/_evidence/@sairahul1 – 2026-06-23T001852+0200.md`), each shape with
its failure edge:

| Shape | Use when | Breaks when |
|---|---|---|
| **fan-out-synthesize** | independent subtasks, one artifact to assemble (per-ticket overnight dispatch) | routing is ambiguous — the coordinator can't cleanly partition the work |
| **adversarial-verify** | findings must survive independent refutation (CR rounds) | the verifier shares context with the producer (rubber-stamps) |
| **loop-until-done** | unknown-size discovery; converge on a target/quiet count | no orchestrator-owned stop-condition — the loop never terminates |
| **peer-negotiation** (deliberation ONLY, never writes) | exploring competing hypotheses, design debate | any peer is allowed to write — it degrades into an unstructured swarm |

Hierarchical decomposition breaks when subgoals are **not** independent; the
coordinator shape breaks on ambiguous routing (sairahul1). map-reduce-and-manage
(§1) is the safe default the other three specialize.

## 3. Slot classes (blast-radius routing — INPUT CONTRACT to WS2)

Route by **blast radius**, expressed as classes — model binding is WS2's:

- **planner / loose-spec implementer = top tier.** Gap-filling a loose spec is
  reasoning work, not typing; it earns the top tier.
- **tight-spec implementer = mid tier, parallel-safe.** Exact-spec execution
  fans out cheaply.
- **reviewer-judge = a DIFFERENT model family than the implementer**, never
  self-grading — a weak/self verifier is the most expensive bug.
- **navigator-search = cheapest.** Locating code is the lowest-blast-radius slot.

_Evidence:_ blast-radius routing — Av1dlive orchestration.md
(`Clippings/_evidence/@Av1dlive – 2026-06-17T235945+0200.md`); evaluator =
different family, "cost = iterations not tokens" — Cherny
(`Clippings/_done/2026-05/How Boris Cherny Uses Claude Code.md`). Optimize for
mergeable output, not per-call price. **Classes only** — WS2's router owns which
concrete model/lane fills a slot given class + compliance + cost state.

## 4. Context rule (resolving the sharing contradiction)

The evidence contradiction — "share as much context as possible" vs. the
clean-context verifier — resolves by role:

- **Share context among co-builders of ONE artifact** (Cognition principle 1).
- **Isolate verifiers, critics, and independent parallel work** — the reviewer
  and the coder share ZERO context, so the review is not anchored by the
  author's framing (the clean-context verifier, same source).

_Evidence:_ Cognition / walden_yan
(`Clippings/_done/2026-05/@walden_yan – 2026-05-25T030401+0200.md`).

## 5. Invariants (hold in every shape)

- **A verifier lane in every shape** — the single highest-leverage role
  (0xMorlex,
  `Clippings/_evidence/telegram-tg-group_-1003985279697-1782407069-tweet-from-x-com-i-status-2070079645148451263.md`).
- **The orchestrator owns stop-conditions; workers never self-report done**
  (0xMorlex, same clip). himmel enforces this structurally: `/overnight-shift`
  reads `scripts/overnight/stop-marker.sh`, not a worker's claim of completion.
- **The coordinator passes prior agent outputs into each subsequent agent's
  prompt** — a concrete, testable coordinator obligation (eng-khairallah1,
  `Clippings/_done/2026-05/@eng_khairallah1 – 2026-05-25T023712+0200.md`).
- **Guardrails:** per-agent token-budget auto-pause ~85 %; kill-and-reassign
  after 3 stuck iterations; any run >1 h gets a separate judge (Av1dlive,
  `Clippings/_evidence/@Av1dlive – 2026-06-17T235945+0200.md`).
- **Claim-and-record shared state:** claim before start, record when done
  (0xMorlex) — the same doctrine the HIMMEL-536 ADR's claim-file fallback rides.

_Shipped verifier lanes:_ the heavy-CR panel (`scripts/cr/critic-panel.sh`) and
`/pr-check` steps 4.6 (handover CR-findings capture, HIMMEL-416 F2/C2) and 4.7
(CR→bug-tracker lifecycle, HIMMEL-446) are himmel's standing verifier topology.

## 6. Durability

Checkpoint each step; persist each decision; resume from the last successful
step (else a restart duplicates subagents). _Evidence:_ Inngest 3-layer durable
orchestration
(`Clippings/_evidence/telegram-1781861527-tweet-from-x-com-i-status-2067677007140278630.md`)
is the external articulation. _Shipped:_ himmel already implements this as the
**where-are-we ledger** (HIMMEL-514, injected by
`scripts/hooks/inject-where-are-we.sh`) plus next-session handover snapshots and
the armed-resume chain (`scripts/handover/arm-resume.sh` +
`scripts/lib/scheduler-backend.sh`).

## 7. Concurrency

The **machine-aware concurrency budget** (ADR
`docs/adr/2026-07-05-machine-aware-concurrency-budget.md`, HIMMEL-536) gates the
himmel-OWNED dispatch points (`/overnight-shift`, subagent fan-out scripts,
arm-resume scheduling). The GA Workflow tool's 16-concurrent / 1000-total caps
are Anthropic-enforced internals — a **fixed ceiling the machine budget lives
UNDER**, never a consumer of it.

## 8. Agent Teams (decision record)

**PARKED until GA.** Agent Teams remains experimental/flag-gated
(`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`), token cost scales linearly per active
teammate, and on Windows it is in-process only. **Opt-in trigger:** the operator
names a debugging-competing-hypotheses case AND accepts the experimental flag;
the pilot mechanics (single session, ≤3 teammates, explicit token cap)
instantiate only then. **No WS3 machinery depends on Teams** — everything rides
subagents + saved workflows until GA.

---

## Evidence-pointer table

Each doctrine claim → its pointer → resolved (clip/path exists as of 2026-07-05).

| # | Claim | Pointer | Resolved? |
|---|---|---|---|
| §intro | operator attention = serial resource ("you are the GIL") | `60-Maps/agent-orchestration-MOC.md` (addyosmani) | ✔ path exists |
| §1 | map-reduce-and-manage default; writes single-threaded; agents contribute intelligence | luna `Clippings/_done/2026-05/@walden_yan – 2026-05-25T030401+0200.md` | ✔ clip exists |
| §1 | shipped fan-out-and-synthesize | `.claude/commands/overnight-shift.md`; `scripts/overnight/self-heal.sh`; `scripts/overnight/morning-report.sh` | ✔ paths exist |
| §2 | four shapes + use-when/breaks-when | luna `Clippings/_evidence/@sairahul1 – 2026-06-23T001852+0200.md` | ✔ clip exists |
| §3 | blast-radius slot classes | luna `Clippings/_evidence/@Av1dlive – 2026-06-17T235945+0200.md` | ✔ clip exists |
| §3 | reviewer = different family; cost = iterations | luna `Clippings/_done/2026-05/How Boris Cherny Uses Claude Code.md` | ✔ clip exists |
| §4 | share-among-co-builders / isolate-verifiers | luna `Clippings/_done/2026-05/@walden_yan – 2026-05-25T030401+0200.md` | ✔ clip exists |
| §5 | verifier every lane; orchestrator owns stop; claim-and-record | luna `Clippings/_evidence/telegram-tg-group_-1003985279697-1782407069-tweet-from-x-com-i-status-2070079645148451263.md` (0xMorlex) | ✔ clip exists |
| §5 | coordinator passes prior outputs | luna `Clippings/_done/2026-05/@eng_khairallah1 – 2026-05-25T023712+0200.md` | ✔ clip exists |
| §5 | token-pause ~85%, kill-after-3, >1h judge | luna `Clippings/_evidence/@Av1dlive – 2026-06-17T235945+0200.md` | ✔ clip exists |
| §5 | shipped verifier topology | `scripts/cr/critic-panel.sh`; `.claude/commands/pr-check.md` (4.6/4.7) | ✔ paths exist |
| §6 | durability = checkpoint/resume | luna `Clippings/_evidence/telegram-1781861527-tweet-from-x-com-i-status-2067677007140278630.md` (Inngest) | ✔ clip exists |
| §6 | shipped durability | `scripts/hooks/inject-where-are-we.sh`; `scripts/handover/arm-resume.sh`; `scripts/lib/scheduler-backend.sh` | ✔ paths exist |
| §7 | machine-aware budget; Workflow caps = ceiling | `docs/adr/2026-07-05-machine-aware-concurrency-budget.md` (HIMMEL-536) | ✔ path exists (this PR) |
