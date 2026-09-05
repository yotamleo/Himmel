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
| Conversational / verbose output | **unowned** — the incumbent response-compression plugin was removed 2026-08-22 (HIMMEL-2033) | it had been `off` since 2026-06-12 and its vendored skill family tripped Hermes's skill scanner on every start (HIMMEL-2032). The boundary is now deliberately empty: any replacement enters through invariant 2 (license) then invariant 3 (measured delta) — there is nothing left to grandfather here |
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

### Downgrade-safety (WS4)

Cheap-lane bulk work (the HIMMEL-506 downgraded task classes — clip-filling,
mechanical sweeps) is validated by **SAMPLING, not 100% review**: reviewing
every output of a cheap batch erases the savings that justified the downgrade.
The downgrade-safety loop is: cheap lane executes → a sampled subset is
validated → a sampled failure **escalates the whole batch to the frontier
lane**. So every downgraded task class MUST name its sampling rule — the
**rate**, the **judge**, and the **escalation trigger** — or it is not
eligible for the cheap lane (proposed as a HIMMEL-506 acceptance criterion).
Split of ownership: **WS4 owns the validation MECHANICS** (the critic panel,
diversity, the correctness ledger — HIMMEL-414); **WS7 owns gate PLACEMENT**
(where the sampling gate sits in a workflow, PASS/FAIL, human checkpoints).
WS4 ships the pattern + the criterion, not a sampling harness — there is no
live bulk lane to sample until WS1 ships and HIMMEL-506 defines the classes.

## Invariants (normative)

1. **One optimizer owns each boundary.** Two tools on one boundary = pick
   the stronger, disable the other. Concretely: any OmniRoute deployment
   (WS2 / HIMMEL-666) MUST disable its whole bundled compression stack —
   himmel owns the dev-output boundary with RTK, and no other optimizer may
   claim a boundary without clearing invariant 3 — enforced by a structural
   config-lint at deploy time (a
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
   grandfathering is explicit, not silent:** RTK predates this
   gate and keeps its boundary, but carries a re-measure obligation via
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

## Measured preload deltas

Session-start preload is a boundary like any other, so a change to it owes
invariant 3 a measured delta. Numbers land here; the method is restated with
them so a later re-measure is reproducible.

### `inject-initiative.sh` → pointer form (HIMMEL-2036, measured 2026-08-23)

**Method.** Byte-sum of the hook's own stdout — the exact string the SessionStart
chain injects — per leg set, on this machine, both harnesses (Claude Code
`.claude/settings.json` and Codex `.codex/hooks.json` run the same script):

```bash
printf '{}' | HIMMEL_INITIATIVE=all bash scripts/hooks/inject-initiative.sh | wc -c
```

Before-figures come from the pre-change script (`git show <base>:scripts/hooks/inject-initiative.sh`)
run the same way, with `HIMMEL_REPO` pointed at an empty dir so no local `.env`
perturbs the leg set. This is the same listing-sum method as the
2026-08-22 context-preload audit, narrowed to the one block that changed.

| Leg set | Before (B) | After (B) | Delta |
|---|---:|---:|---:|
| `prcheck,pr` | 1,707 | 350 | −1,357 (−80%) |
| `all` (interactive: 4 legs) | 1,803 | 366 | −1,437 (−80%) |
| `all` (overnight: 6 legs) | 2,477 | 376 | −2,101 (−85%) |
| all 8 legs (widest) | 3,155 | 378 | −2,777 (−88%) |

After-figures are for a **canonical install** — a primary checkout, whose
absolute runbook path is 74 B on the reference machine — computed as
`fixed content + 74`, where *fixed content* is the emitted bytes minus the
emitted path. That path is the only variable term. It is absolute because the
hook is wired at user scope and reads the himmel clone's `.env`, so a session
started in another repo can be initiative-active and a repo-relative path would
not resolve there; a worktree under `.claude/worktrees/<branch-slug>/` then pays
~62 B more for byte-identical pointer content, which is a property of where the
checkout lives, not of the pointer. The budget assertion therefore bounds the
fixed content at `400 − 74 = 326 B` — so a canonical install always fits the
400 B acceptance criterion — and reports the raw total alongside, so an
unusually long path stays visible without failing the budget.

Paid on **both** harnesses, on every session start the gate is on, whether or not
a completion point is ever reached — so the operator's overnight profile saves
~2.2 KB × 2 per session. The step bodies moved to
[`scripts/hooks/initiative-runbook.md`](../scripts/hooks/initiative-runbook.md);
the enforcement sentence and the no-merge guard stayed inline because a rail is
not a lookup.

**The saving is in the read TRIGGER, not just the move.** A pointer that said
"read the runbook first" would defer the 3.1 KB to the first turn rather than
remove it. The pointer instead names the two moments the bodies are actually
needed — a natural completion point, and a handover resume (when the
tasklist-seed section applies) — so an ordinary session never opens the file at
all.

**What could NOT be deferred is the directive itself.** "At a completion point,
run them unasked" is what makes a session recognise a completion point; behind
the read trigger it would never fire, and the whole feature would vanish with no
error — the failure mode the audit named as this change's real risk. One inline
line carries it; only the step BODIES are deferred. The budget assertion in
`scripts/hooks/test-inject-initiative.sh` (test 27) holds the line, and test 28
fails if a runbook body creeps back inline.

**Not re-measured here:** the plugin/skill listing blocks. Disabling
`ui-ux-pro-max` + `scroll-world` (audit O1, ~6 KB) is a user-scope operator
action already applied outside this repo, and `security-guidance` is an adopter-
default change (see
[`docs/setup/new-machine.md`](setup/new-machine.md#security-guidance--recommended-off-operator-decision-pending-himmel-2036))
with the operator-box decision still pending — neither changes this machine's
current listing sum.

### Skill/command descriptions → a 120-char cap (HIMMEL-2037, measured 2026-08-23)

Audit O4. Every `description:` byte in a skill or command frontmatter is paid on
every session start, and Claude Code's own cap is 1,536 chars — so nothing
truncates and nothing self-limits. himmel's own entries averaged 219 B each.
Capping `description` at **120 chars** and rewriting the 78 over-cap
frontmatters (meaning-preserving, routing/trigger phrase kept — that phrase is
what the description is *for*) gives:

| Bucket | Entries | Before (chars) | After (chars) | Delta |
|---|---:|---:|---:|---:|
| `.claude/commands/` | 44 | 9,617 | 5,162 | −46% |
| `marketplace/plugins/*/commands/` | 20 | 7,472 | 2,485 | −67% |
| `marketplace/plugins/*/skills/` | 15 | 7,809 | 1,910 | −76% |
| `.agents/skills/` (Codex lane) | 19 | 3,782 | 2,235 | −41% |
| **TOTAL** | **98** | **28,680** | **11,792** | **−59%** |

The three Claude-listing buckets alone go **24,898 → 9,557 chars (24.3 KB →
9.3 KB, −61.6%)**, against the ticket's ≥40% / ≤15 KB acceptance. The Codex lane
pays its own `.agents/skills/` listing, so the 98-entry total is the honest
cross-harness figure. Both are measured with the HIMMEL-1461 harness
(`scripts/lanes/skill-cost.mjs`), same arithmetic as the audit — its
`project-commands` before-figure reproduces the audit's 9,617 B to the byte.

`--max-desc <n> <paths…>` on that same script is the gate, wired twice: the
`skill-description-cap` pre-commit hook over the staged frontmatter paths, and a
`doc-invariants` CI step over the whole tracked set (`git ls-files`), because the
pre-commit hook is blind to anything that arrived through a bypass. It names the
offending file and its length and exits 1.

**No cap on `when_to_use`, and none needed** — himmel uses the field in zero
entries; the audit's warning about it came from measuring other harnesses.
`argument-hint` is likewise untouched: it is a completion affordance, not a
routing signal, and it was not the offender.

**The risk is routing, not bytes.** A description that stops being *selected*
costs far more than it saved, and there is no automated routing check to prove
otherwise — `/skill-find` and the golden-profile fixtures cover the index and
plugin resolution, not selection quality. The mitigation is in the rewrite rule:
the trigger phrase survives; what was cut is restatement of the body (mechanism,
ticket IDs, wrapper plumbing, sub-flag enumerations) that a reader only needs
*after* the skill is already selected.

### `CLAUDE.md` lean-invoke (HIMMEL-2038, measured 2026-08-23)

Audit O5. The root `CLAUDE.md` is the one preload block every harness pays —
Claude Code loads it directly, Codex and Hermes load the `AGENTS.md` generated
from it — and it had grown to 19,018 B. Every rule was re-sorted by layer
(hook/gate → one line naming the enforcer; reference detail → `docs/internals/`;
recovery → the stuck-playbook; general engineering defaults → a user-scope
block installed once by `adopt.sh`/`adopt.ps1`/`himmel-update`), and a
pre-commit byte gate (`scripts/ci/check-claude-md-budget.sh`, ≤ 12,288 B) keeps
it from re-accreting.

**Method.** Tracked bytes straight from the object store (`git show <rev>:<path> | wc -c`)
for the rule files; the skill/command listing rows reuse the HIMMEL-2037 figures
above (name + description chars, `scripts/lanes/skill-cost.mjs` arithmetic) so
the two audits add without double counting. Tokens are estimated at 4 B/token,
the same divisor `skill-cost.mjs` prints. "Before" is `main@6215f5e8`, the last
commit before HIMMEL-2037 landed; "after" is this branch.

| Harness | Always-loaded set (himmel's share) | Before (B) | After (B) | Delta | ≈ tokens |
|---|---|---:|---:|---:|---|
| Claude Code | `CLAUDE.md` (file total) | 19,018 | 12,310 | −6,708 (−35.3%) | ~4,750 → ~3,080 |
| Claude Code | + skill/command listing (2037) | 24,898 | 9,557 | −15,341 (−61.6%) | ~6,220 → ~2,390 |
| **Claude Code total** | | **43,916** | **21,867** | **−22,049 (−50.2%)** | **~10,980 → ~5,470** |
| Codex | `AGENTS.md` (generated, total) | 20,851 | 14,143 | −6,708 (−32.2%) | ~5,210 → ~3,540 |
| Codex | + `.agents/skills/` listing (2037) | 3,782 | 2,235 | −1,547 (−40.9%) | ~950 → ~560 |
| **Codex total** | | **24,633** | **16,378** | **−8,255 (−33.5%)** | **~6,160 → ~4,090** |
| Hermes | `AGENTS.md` (generated, total) | 20,851 | 14,143 | −6,708 (−32.2%) | ~5,210 → ~3,540 |

Of the 12,310 B file, **11,537 B is himmel content** (what the budget gate
holds ≤ 12,288 B) and **773 B is the upstream-owned `## graphify` section**,
excluded from the budget (see below). The HIMMEL-2038 share alone is the
`CLAUDE.md`/`AGENTS.md` rows: **−6,708 B on every session of every harness.**
On the operator's own machine the working principles were paid *twice* before
(user-scope `~/.claude/CLAUDE.md` and the project file both state them); now
once.

**What could NOT be demoted is the directive itself.** Each rule that is
structurally enforced kept its one-line directive and gained the enforcer's
name (`block-edit-on-main`, `check-push-target`, `orchestrator-inline-guard`, …);
only the rationale and recovery detail moved. The session-critical paragraph
(hook bypass = launching-shell env, `.single-writer`), the RETASK rule, the
Jira absolute-path invocation, the qmd `--collections` trap and the egress
clause stayed inline verbatim — a directive behind a lookup is a dead directive.

**The `## graphify` section stays — verbatim upstream text (operator ruling
2026-08-23).** `graphify install --platform claude` writes a stock `## graphify`
section into the project `CLAUDE.md` on every run (`graphifyy`
`install.py: claude_install` → `_replace_or_append_section`: replace the
section in place if a line is exactly `## graphify`, else append at EOF), and
it is the same command that upgrades the hook-guard hooks and the user skill,
so it recurs. After such a run, re-apply himmel's hook pricing with
`bash scripts/lib/graphify-bin.sh price-hooks` (HIMMEL-2480) — the installer
restores the stock four-tool, no-timeout entries. The section is therefore **upstream-owned**: himmel keeps exactly
what the installer writes, unmodified — a reinstall or upgrade is then a no-op
(or a clean upstream text bump), never a conflict. himmel's own rules live
entirely OUTSIDE the section; the one caveat (upstream text recommends
`graphify path`, which Retrieval routing forbids) is a single line in the RULES
above the section: where they conflict, RULES win. The budget gate
(`scripts/ci/check-claude-md-budget.sh`) counts ONLY himmel's bytes — it
excludes the section using the installer's own boundary rule — and asserts
exactly one section (zero = anchor deleted, hint to reinstall; duplicates never
self-heal because the installer replaces only the last). Proven against the
real installer: `scripts/ci/test-check-claude-md-budget.sh` Case H runs
graphifyy's `claude_install` over the committed file — byte-identical result,
one section, gate green.

**Behavioural half — not yet run.** Fewer bytes is only half the claim; the
other half is that a fresh session still refuses to commit on main, still routes
Jira through the CLI, still reaches for `graphify query` on a structure
question. The with/without recipe (arms, probes, metrics, acceptance) is in
[`docs/internals/token-economy-bench.md`](internals/token-economy-bench.md); it
needs a quiet bank window, so it runs post-merge and its numbers land here.

## Pointers

- Eval tickets: HIMMEL-622 (MCP boundary owner), HIMMEL-632 (comparator),
  HIMMEL-480 (context bloat), HIMMEL-668 (cache data source), HIMMEL-506
  (routing policy input), HIMMEL-666 (router mechanism), HIMMEL-667
  (validation-lane sampling).
- Tooling inventory: [`docs/tooling-catalog.md`](tooling-catalog.md).
- Adoption method: [`docs/tool-adoption/rubric.md`](tool-adoption/rubric.md).
