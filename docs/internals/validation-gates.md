# Validation / quality gates — placement doctrine (HIMMEL-654 WS7)

WS7 owns WHERE validation gates sit on himmel's workflows: gate placement,
rubric chains, PASS/FAIL semantics, the report contract, human-checkpoint
doctrine, lane trust tiers, and the unquarantine gate for cheap-lane
(GLM/Codex) outputs. Every mechanic it invokes is an ALREADY-SHIPPED instrument
(the HIMMEL-414 CR stack + spawn-glm PR #843); WS7 places them, it does not
respec them. It unquarantines the GLM/Codex capacity WS1 already shipped.

Spec: `<state-repo>/handovers/<user>/himmel/specs/design/ws7-validation-gates.md`.
Where this doc and the spec disagree, the spec wins.

## 0. Two meanings of "gate" (read first)

- **WS7 gate = per-artifact correctness/merge gate:** "is this specific output
  correct enough to advance/merge?"
- **WS6 gate = per-tool adoption gate:** "is this boundary-owner change worth
  keeping?" (measured token delta + outcome-per-session verdict).

They compose: a new WS7 gate *mechanism* is itself a tool and must pass WS6's
measurement bar (license gate first, then measured delta) before adoption.
Nothing here redefines WS6's bar.

## 1. The lane gate (D1 — unquarantine gate for GLM/Codex)

**Placement:** between a cheap-lane worker branch and PR creation — a
**validating-session review** run by a Claude-family session on the worker's
branch diff. This is the same seam the spawn-glm worker prompt already names
("a validating session reviews your branch and owns all external writes").

**Provenance precondition — positive markers, not inferred absence.** A branch
is cheap-lane IFF it carries a POSITIVE marker, classified by
`scripts/cr/lane-classify.sh`:

- `glm/*` → `cheap-glm` (spawn-glm PR #843 names `glm/<slug>`; the session meta
  under `<BRIDGE_ROOT>/glm-sessions/` corroborates);
- `codex/*` → `cheap-codex` (the hermes-Codex convention, adopted in
  [`harness-compat.md`](harness-compat.md) §10);
- everything else → `claude`.

Absence is NEVER cheap-lane: an unmarked branch is indistinguishable from
ordinary Claude work, so it takes the Claude chain (an "unmarked ⇒ cheap" rule
is not mechanically actionable and would make the Claude chain unreachable). A
known-Codex branch not yet named `codex/*` is manually flagged cheap by the
operator/validating session (recorded in the D1 verdict PR-body snippet); Codex
work predating the convention does not ride this gate mechanically.

**Stated deviation:** `lane-classify.sh` is branch-string-only by design (pure,
no I/O). The spec's session-meta corroboration happens at the verdict/hook layer
— `scripts/cr/d1-verdict.sh` and the §9 hook read the meta directly — which
fails SAFE: a `glm/*` branch with no session meta has no verdict ⇒ no advance.

**Chain:** the standard `/pr-check` full lane (panel + reviewer matrix + VERDICT
adjudication + marker clear) PLUS the D2 lane rubric (R1-R4) reviewed by the
validating session.

**Verdict owner (⚑ Fork A DEFAULT):** the Claude-family validating session
applying the lane rubric owns the merge-trust verdict. Panel findings stay
ADVISORY blocking-candidates (WS4 Fork-1: junior models advise, Claude
adjudicates; the gate stays Claude-only). The operator retains the physical
merge action (unchanged).

**PASS/FAIL semantics:** fail-closed on the verdict-presence axis. No
validating-session verdict ⇒ not PR-eligible. A worker self-report ("done") is
never a PASS input (WS3 workers-never-self-report invariant).

**Verdict persistence:** the validating session writes a one-line verdict record
— `d1_verdict: pass|fail (R1-R4)` — via `scripts/cr/d1-verdict.sh`, into the
spawn-glm session meta AND the PR body. D5's gated-merge count reads that record
+ git history (NOT the CR ledger, which carries critic findings, not lane
verdicts).

**Enforcement honesty:** the CR-marker hook
(`scripts/hooks/check-cr-before-push.sh` +
`scripts/hooks/check-cr-marker-on-pr-create.sh`) structurally enforces the
panel/CR half. The R1-R4 lane-rubric verdict is BEHAVIORALLY enforced v1
(validating-session discipline); its structural enforcement is the deferred
lane-marker hook (§9), escalated on drift per HIMMEL-195.

## 2. Rubric chains per artifact class (D2)

A gate chain = ordered rubric set + failure posture + report contract. Every
mechanic invoked is a shipped instrument.

| Artifact class | Chain (shipped instruments only) | Posture (panel avail. / verdict presence) | Human checkpoint |
|---|---|---|---|
| Code diff (Claude lane) | pre-push deterministic gates → `/pr-check` full lane → operator merge | panel fail-open; verdict/marker fail-closed | merge (operator) |
| Code diff (GLM/Codex lane) | D1 lane gate = full lane + lane rubric, validating session adjudicates | panel fail-open; verdict/marker fail-closed (verdict-presence axis — §3) | merge (operator) |
| Docs-only diff | docs-audit lane (never-zero-CR) | verdict/marker fail-closed | merge (operator) |
| Spec/plan artifacts (minerva) | Stage-2/4 adversarial critics (same-family today — known blind spot; the cross-model lane arrives with WS4 D1 artifact-critic, a FUTURE instrument, non-blocking) | critics advisory; orchestrator gates advance (fail-closed on a missing critic round) | operator ratifies ⚑ forks |
| Handover state | exempt (HIMMEL-142) — no gate | exempt — no gate | none |

**Lane rubric (the D1 extension, applied to cheap-lane diffs on top of the full
lane):**

- **R1 scope adherence:** the diff touches only what the task named (worker
  prompt contract).
- **R2 attestation honesty:** trailers/claims in commits are backed by
  observable evidence (tests actually run in the transcript, etc.).
- **R3 convention conformance:** conventional commits, worktree discipline, no
  external writes from the worker (tripwire + transcript check).
- **R4 self-report cross-check:** the worker's outbox/context summary matches
  the actual diff (catches "confidently wrong done").

**Behavioral-degradation checks** are part of the lane rubric — the failure
surface WS1 names (attestation honesty, scope adherence, convention drift) that
structural guards do not catch.

**Gate-report contract (all chains):** a FAIL names the exact failing item —
`file:line`, rubric ID, and for agentic/test gates the exact tool-call/fixture
that triggered the miss. This preserves the `[<slug>-N]` bullet contract and the
`(N found)` heading/count contracts untouched.

**Validity-regime line (scale discipline):** every chain declares what regime
its evidence covers (e.g. "reviewed at diff scale; no production-scale claim").
Small-set green ≠ production green (benchmark-saturation lesson).

## 3. Degradation posture (D3 — ⚑ Fork B)

**Posture axes, stated once:** panel availability is fail-open; verdict presence
is fail-closed. "Fail-closed" anywhere in this doc refers to the verdict/marker
axis (no verdict ⇒ no advance), never to panel availability.

**⚑ Fork B DEFAULT:** **critic-panel UNAVAILABILITY** ⇒ degrade fail-open to
Claude-only adjudication, for ALL chains including the D1 lane gate.
"Unavailable" is the runbook's own umbrella for BOTH shapes: the panel runs and
every critic errors/times out (`panel_rc=1`), OR the panel cannot be run at all
(e.g. the diff could not be produced — `pr-check.md:99`). `CR_PROFILE=none` is
the explicit opt-out and also lands Claude-only; an empty diff simply skips the
panel.

The clarification this needs (HIMMEL-1101): a **registry fallback is NOT
unavailability** — the panel RAN, on the paid anchor. Of the four shapes below,
only 3 and 4 reach Claude-only; 1 and 2 BILL:

1. **Registry missing / invalid / empty** (`critic-panel.sh` node parse exits 7)
   ⇒ **paid** codex anchor-only. The stderr line says so verbatim:
   `registry <path> missing/invalid/empty — anchor-only (codex)`.
2. **Registry present and valid, but no row matches the tier filter** (exit 8)
   ⇒ **paid** codex anchor-only, via the same fallback. This is the shipped
   default today: `critics.json` holds exactly one row (`codex`/`gpt-5.5`, tier
   `paid`) and no free anchor, so an unset `CR_PROFILE` (tier filter `free`)
   matches nothing and lands here.
   The free lane was REMOVED DELIBERATELY (operator, HIMMEL-1101): the free
   critics made more trouble than they were worth — HIMMEL-667 dropped
   gptoss+kimi on a 12%/13% agreed-rate (noise), and the surviving qwen3coder
   anchor kept erroring rc=1 (HIMMEL-953). This is a decision, not drift; the
   panel is paid-by-default on purpose and only the docs had lagged.
3. **The selected panel runs but every critic errors/times out** (panel rc=1)
   ⇒ Claude-only fail-open, exactly as this fork has always specified.
   Unchanged, and still fires. Observed live 2026-07-17: the sole registered
   critic (paid codex) returned rc=1 for a whole run once its weekly bank was
   exhausted — with no free row registered, that is 0/1 panel critics.
   **This does NOT by itself block the CR gate.** `clear-cr-marker.sh` counts
   ANY ledger `avail … status=ok` as a responder (`:176`), and the CodeRabbit
   CLI pass (`/pr-check` step 3.2) records its own — so the gate can still
   certify on CodeRabbit while every panel critic is down, and did. What a
   single-critic roster costs is the panel's own cross-model redundancy, not
   the gate's ability to certify. Accepted knowingly (HIMMEL-1101).
4. **The panel cannot be run at all** — e.g. the diff could not be produced
   (`pr-check.md:99`, "critic panel unavailable — claude-only review (git diff
   failed …)") ⇒ Claude-only fail-open. `CR_PROFILE=none` is the explicit
   operator opt-out onto the same path; an empty diff skips the panel outright.

Operator-relevant consequence: cases 1 and 2 both SPEND the OpenAI bank on the
paid anchor (paid usage is user-enabled by design). Do not read "the panel was
unavailable" as "nothing was billed" — only 3 and 4 reach zero panel members.

So the fork's rationale below holds for cases 3-4; cases 1-2 reach a paid critic
rather than zero panel members.
Rationale: for GLM/Codex-origin artifacts the adjudicator is already a DIFFERENT
family than the implementer — the WS3 "evaluator = different family, never
self-grading" invariant holds even with zero panel members. The known residual
blind spot is Claude-reviewing-Claude (same-family) on Claude-lane diffs — that
is today's shipped posture, targeted by WS4 D1(b), not worsened by this default.

Alternative rejected by default: hard-block on anchor death (turns a free
third-party outage into a repo-wide merge freeze — disproportionate).
`CR_PROFILE=paid` (codex) remains the operator escalation. Per-token lanes stay
blocked (locked) — no GLM critic in any panel until the operator enables
per-token billing.

## 4. Human checkpoints (D4 — first-class, bounded)

- **Merge is operator-only.** The D1 verdict feeds it, never replaces it.
  `--admin`/gate-bypass remain HARD-vetoed.
- **`/code-review ultra`** stays the operator-triggered top escalation, recorded
  as a one-action operator step.
- **Batching bound:** the review surface batches into the consolidated morning
  report; fan-out ceiling ≈6-8 tickets/shift (rubber-stamp threshold) — a WS7
  checkpoint property, owned operationally by the overnight-mode doc.
- **Checkpoint placement rule:** a human checkpoint is REQUIRED where a verdict
  is (a) irreversible outward (merge, publish, external write) or (b) a
  trust-tier promotion (§5). Everything else is agent-adjudicated.

## 5. Trust-tier promotion (D5 — ⚑ Fork C)

Unquarantine is not binary-forever; it is a per-lane trust ledger.

- **Tier 0 (today, executable):** every cheap-lane output passes the D1 gate.
- **Tier 1 (earned — ⚑ Fork C DEFAULT N=10):** after ≥N gated merges with zero
  post-merge reverts/regressions attributable to the lane (counted from the
  verdict records + git history), the operator MAY relax the lane rubric to
  sampled application. **The sampling mechanism is a FUTURE instrument** (WS4 D3
  ships policy text + an acceptance criterion only — no sampling harness exists
  today). Tier 1 is a reserved slot, not executable now.
- **Demotion:** any lane-attributed regression that reaches main returns the
  lane to Tier 0 (full gating) until N accrues again.
- Promotion/demotion are **operator actions** (§4 checkpoint rule b); this doc
  only defines the ledger evidence that justifies them.

## 6. Trace→regression loop (D6 — WS10 seam, placement only)

Every D1/D2 gate FAIL emits a machine-findable record stored with the run
artifacts. **Emission points:**

- lane fails → the spawn-glm session dir (shipped);
- blocking CR fails on a cheap-lane branch → `scripts/cr/emit-gate-fail.sh`
  writes them to the SAME `<session-dir>/gate-report.jsonl` as lane fails.

This is the ONE added emission WS7 places: today `file-deferred-issues.sh`
captures ONLY deferred low-severity findings; blocking Critical/High/Important
CR fails are NOT persisted (they block the marker and get fixed in place), so
the corpus was missing the failures that matter. WS10's self-improvement loop
consumes these ("failed traces become the next test cases"); WS7 places the
emission points, WS10 owns the loop. No new storage system (YAGNI) — session
dirs + issues are the corpus v1, with the one added write above.

## 7. CI promotion path (D7 — ⚑ Fork D)

Shell-unit CI (`workflow_dispatch`-only, HIMMEL-494) is advisory evidence a
validating session MAY cite, never a PASS substitute, until promoted.

**⚑ Fork D DEFAULT (unmeasured constants — ratify or retune before promotion):**
20 consecutive manual runs green on main AND per-run wall time < 10 min AND zero
flaky-test quarantines open. The promotion decision itself is a WS6-bar adoption
call. (Public-repo CI is already per-push; this fork governs the private repo's
workflow.)

## 8. Data-egress-safe gate lane (D8)

Sensitive (Salus/PHI/secret-touching) artifacts NEVER route through cloud
critics — the panel is cloud (NIM/hermes), so their chains are
Claude-session-local review only, today.

**Signal honesty:** the mechanically-testable guard covers PATH/REPO signals
only (diffs in Salus-profile vaults, or matching sensitive-path
patterns); PHI/secret CONTENT in an otherwise-ordinary diff is
operator/adjudicator judgment, not a mechanical gate — content scanning is
runtime DLP, explicitly out of scope (WS1 non-goal inherited). This is a
**placement rule**, not a gate: no sensitive-path diff on a cloud critic lane.

DeepEval (local-execution, Apache-2.0 — license to be verified at adoption per
WS6's license gate) is the named candidate engine for a future local assertion
gate; adopting it is a WS6-gated tool decision, not a WS7 build item.

## 9. Deferred structural enforcement

The lane-marker hook
(`scripts/hooks/block-cheap-lane-pr-without-verdict.sh`) is BUILT but NOT wired:
HIMMEL-195 escalates instructional→structural on the SECOND observed drift. v1 =
behavioral (validating-session discipline).

**Scope: `cheap-glm` ONLY** — only glm has a session substrate (spawn-glm meta
under `glm-sessions/`) to look a verdict up in. `cheap-codex` structural
enforcement WAITS on the FUTURE hermes task→branch record (spec D1.1/SC2), so
`codex/*` PRs pass this hook and rely on the behavioral verdict discipline until
that record ships.

**Wiring (OPERATOR-executed, only after a second observed drift — a cheap-lane
PR opened with no `d1_verdict` record):** a guarded `Bash|PowerShell` entry in
`marketplace/plugins/himmel-ops/hooks/hooks.json` (live after `/himmel-update` +
a fresh session), never `.claude/settings.json` (an agent-executed
settings.json edit is a classifier-vetoed self-modification). Until then this
stays "built, not wired." See §1 enforcement-honesty.

## Forks awaiting ratification

Each fork ships at its DEFAULT; ratification flips exactly the one knob below —
no rewrite.

- **⚑ Fork A (§1 — verdict owner):** DEFAULT = Claude-family validating session
  owns the merge-trust verdict (operator owns the merge action). Flip changes
  §1's owner sentence + the `d1-verdict.sh`/hook headers — the record format is
  unchanged.
- **⚑ Fork B (§3 — anchor-death posture):** DEFAULT = fail-open to Claude-only
  adjudication. Flip changes §3's default clause only (to hard-block).
- **⚑ Fork C (§5 — Tier-1 threshold):** DEFAULT = N=10 gated merges (Tier-1
  itself is future/non-executable). Flip changes §5's N only; no code (the
  sampling harness is a WS4 future instrument).
- **⚑ Fork D (§7 — CI-promotion constants):** DEFAULT = 20 green / <10 min / 0
  open flaky quarantines. Flip changes §7's constants only.

## Carry-forwards

- **→ WS8 (Mission Control):** gate verdicts + trust-tier state are first-class
  C&C surfaces (what's quarantined, what's pending verdict).
- **→ WS10 (Jarvis):** the §6 emission points are the self-improvement loop's
  input corpus.
- **→ WS4:** when the artifact-critic (D1) ships, minerva Stage-2/4 chains gain
  a cross-model lane — the placement slot is reserved in §2 (spec/plan row).
- **→ WS5 (parity):** the D1 lane-gate rubric applies to any future Codex-driven
  himmel work regardless of harness (AGENTS.md surface).
