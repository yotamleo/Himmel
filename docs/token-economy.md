# Token economy — per-boundary optimizer policy (HIMMEL-654 WS6)

> Operative reference (load-on-trigger, not a CLAUDE.md rule — HIMMEL-177
> layer selection). Single source of truth for **who owns which token
> boundary**. Sessions and evals cite this doc; changes to a boundary owner
> go through the measurement gate below. Spec provenance: the WS6 design
> (state repo, `himmel/specs/design/ws6-token-economy-policy.md`); Jira
> rollup: HIMMEL-654 (sequencing comment, 2026-07-03).

## The policy

Counter-pattern first, because it frames everything: **token burn is a
vanity metric — measure outcomes, not tokens.** Optimizers compose because
each targets a different boundary; they conflict only when two target the
same one (then pick the stronger and disable the loser).

| Boundary | Owner | Status / gate |
|---|---|---|
| Dev command output | **RTK (hooked)** — keeps the boundary | context-mode is **REJECTED for adoption while NOASSERTION-licensed** (himmel targets an MIT-licensed public path, HIMMEL-297); re-open ONLY if it ships an OSI license AND beats RTK on a measured real-session delta (HIMMEL-622-style protocol) |
| Conversational / verbose output | **Caveman plugin** (never code/precise; vendor-claimed savings vary by level) | incumbent, grandfathered (invariant 3) |
| MCP / tool output | **open — HIMMEL-622 decides** (Headroom lead candidate, Apache-2.0), with HIMMEL-632's token-optimizer-mcp as TAKE-PARTS comparator (PolyForm-NC = personal-internal ceiling, never redistributed) | adoption gate = measured token delta on a real himmel workday + outcome-per-session verdict |
| Stable prefixes (prompt cache) | **owner = the operator** (as `/morning-report` reviewer), responder path below | cheapest lever, least instrumented. **UNMONITORED until HIMMEL-668 verifies a deterministic zero-token local data source** — accepted and stated; no vacuous interim check is claimed. The circulating 76.5% read-ratio / "<40% = structural issue" figures are one-tweet heuristics from someone else's workspace, flagged non-representative by the source note itself; himmel has never measured its own read-ratio |
| Context bloat | **CLAUDE.md hygiene (HIMMEL-480)** | with the Vercel passive-beats-on-demand caveat baked into its acceptance (always-on beat on-demand 100% vs 79% for general knowledge — don't blanket-move content out of always-on) |
| Whole task (routing) | **WS2's router (HIMMEL-666)** — this doc only states the policy: trivial→cheap is the biggest lever (HIMMEL-506) | seam: WS6 = policy + measurement bar; WS2 = mechanism (router, model tables, fallback chains) |
| Downgraded bulk output (validation) | **WS4 (HIMMEL-667) — sampling rule** | every downgraded task class names its validation sampling rule: rate, judge, escalation trigger (sampled failure ⇒ batch escalates to the frontier lane). Proposed as an acceptance criterion on HIMMEL-506; cheap routing that silently degrades outcome-per-session is the named failure |

### Prompt-cache responder path (owner: operator)

Once HIMMEL-668 establishes a himmel-measured baseline: investigate when
read-ratio trends **materially below that baseline sustained over ≥3 days**
(single-day dips after idle/fresh sessions are known false positives).
Responder action = file a context-hygiene investigation ticket
(HIMMEL-480-shaped). Until then this boundary is explicitly unmonitored.

## Invariants (normative)

1. **One optimizer owns each boundary.** Two tools on one boundary = pick
   the stronger, disable the other. Concretely: any OmniRoute deployment
   (WS2 / HIMMEL-666) MUST disable its bundled RTK+Caveman — himmel already
   runs both — enforced by a structural config-lint at deploy time (a
   positive assertion over the source-read-discovered engine set; an
   omitted key FAILS), not by prose.
2. **License gate precedes measurement gate.** NOASSERTION / non-OSI /
   noncommercial licenses are REJECT-for-adoption on himmel's public MIT
   path; at most personal-internal pilot, never wired into shipped config.
   Current casualties: context-mode (NOASSERTION), token-optimizer-mcp
   (PolyForm-NC — TAKE-PARTS comparator only).
3. **Measurement gate (boundary-owner CHANGES).** Every change requires a
   measured token delta on a real himmel session AND an outcome-per-session
   verdict. Vendor percentages are never sufficient. **Incumbent
   grandfathering is explicit, not silent:** RTK and Caveman predate this
   gate and keep their boundaries, but carry a re-measure obligation via
   measure-during telemetry once HIMMEL-236's record format ships (tracked
   in the HIMMEL-654 sequencing comment).

## Decision records

- **Dev-command contest (decided 2026-07-02):** RTK keeps the boundary.
  context-mode REJECT-while-unlicensed (18.4k★ and a 98% vendor claim do
  not clear the license gate). Evidence snapshot: RTK Apache-2.0/67.9k★
  active; context-mode NOASSERTION as of 2026-07-02. Reversal protocol:
  OSI license + HIMMEL-622-style measured win over RTK.
- **MCP/tool-output contest (protocol, decision deferred by design):**
  license gate → HIMMEL-622 measured eval (Headroom Apache-2.0/55.8k★ lead
  vs rtk incumbent), HIMMEL-632 as comparator. The eval ticket owns the
  verdict; this doc records the protocol so the decision is reproducible.
- **Lane compliance (2026-07-03, WS4 re-validation):** panel/router lanes
  terminate PER-TOKEN keys only; subscription lanes (Z.ai Coding Plan —
  ToS-restricted to officially supported tools) are launcher-only (WS1's
  `claude-glm` is the compliant use; Claude Code qualifies).

## Pointers

- Eval tickets: HIMMEL-622 (MCP boundary owner), HIMMEL-632 (comparator),
  HIMMEL-480 (context bloat), HIMMEL-668 (cache data source), HIMMEL-506
  (routing policy input), HIMMEL-666 (router mechanism), HIMMEL-667
  (validation-lane sampling).
- Tooling inventory: [`docs/tooling-catalog.md`](tooling-catalog.md).
- Adoption method: [`docs/tool-adoption/rubric.md`](tool-adoption/rubric.md).
