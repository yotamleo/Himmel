# Overnight Mode — Autonomous Pipeline

> **Trigger phrase:** when a user prompt includes the phrase **"overnight mode"** alongside a `next-session-*.md` path (e.g. `load handovers/<USER_SLUG>/himmel/epics/HIMMEL-XX-…/next-session-N.md overnight mode`), execute this pipeline end-to-end without pausing for confirmation between phases.

## When to use it

Use overnight mode when a single ticket has a complete brief + plan, the work is well-scoped, and you want to ship without sitting at the keyboard. Proven on HIMMEL-97 (himmel-run runner + himmel-jira plugin, shipped in one overnight session).

Do **not** use overnight mode when:
- The brief is ambiguous or the spec is incomplete.
- The work touches multiple independent subsystems (split into separate tickets first).
- Destructive ops outside the worktree are required.

## The 11 phases (+ step 0: queue lock)

0. **Queue lock (HIMMEL-856)** — before Phase 1, run
   `bash scripts/handover/queue-lock.sh acquire <handover-path>`. rc=0
   (fresh acquire or an automatic stale takeover) proceeds straight to
   Phase 1 — **capture the `release-token: <token>` line the acquire
   prints and keep the token for Phase 11**: `release` (and `heartbeat`)
   refuse without it, so a late or wrong-session release can never rm a
   live lock. **rc=2** means the queue is owned by a LIVE session elsewhere
   right now (the exact 2026-07-10 00:51 double-fire shape) — do NOT
   proceed on this queue: load the coordination file, pick a different
   queue, or stop with a clear message to the operator. Do not set
   `QUEUE_LOCK_TAKEOVER=1` to push past a FRESH lock unless you have
   independently confirmed the other holder is gone (the operator said so,
   or the machine it names is verifiably offline) — a live double-acquire
   is the failure this step exists to prevent. Release the lock at wrap
   (Phase 11, with the captured token) or via `/stop`; an un-released lock
   is covered by the TTL (default **6 h** — sized to cover the 3-4 h
   overnight budget; `QUEUE_LOCK_TTL_SECONDS` tunes it, and wiring periodic
   `queue-lock.sh heartbeat <handover-path> <token>` refreshes into long
   sessions is the future lever for tightening it back down — TTL sizing
   is an open operator question on the HIMMEL-856 design) so a crashed
   session never strands the queue.
1. **Plan** — `superpowers:writing-plans` on the active brief; commit to `<plans-root>/YYYY-MM-DD-<slug>.md` where `<plans-root>` resolves as:
   - `$HANDOVER_DIR/plans/` when `HANDOVER_DIR` is set (Mode B — plans live with handover state in `<state-repo>/handovers/plans/`).
   - `<repo>/docs/superpowers/plans/` otherwise (Mode A default — backwards-compat;
     this path is **gitignored**, so Mode-A plans stay local and are never committed
     to the public repo, per HIMMEL-297).

   The Mode B path collocates the plan with the per-ticket session notes (`<state-root>/<repo>/{epics,standalones}/<TICKET>/next-session-N.md`), so a reviewer auditing the work can grep one root for plan + decisions + outcomes. Mode A keeps plans inside the code repo for solo-operator no-env-var setups.
2. **Worktree** — `/clean_garden feat/himmel-<N>-<slug>`.
3. **Impl** — `superpowers:subagent-driven-development`. Sequential per task: implementer subagent → spec-compliance reviewer → code-quality reviewer → fix-on-finding → next task. **Verifier cadence (HIMMEL-281, Fable-5 scaffolding):** every 3 completed tasks, dispatch one fresh-context verifier subagent that re-checks the accumulated branch diff against the Phase-1 plan. Fresh-context verification beats self-critique, and the per-task reviewers see one task at a time — this is the layer that catches cross-task drift before Phase 4. **Stop-check (HIMMEL-137):** before EACH subagent dispatch in this loop, run `bash scripts/overnight/stop-marker.sh check` (silent; rc=0 = stop marker present, rc=1 = clear). When rc=0, finish the in-flight subagent if one is running, then halt the loop gracefully (write a `next-session-N.md` snapshot at the partial-completion point, file followup tickets for remaining tasks, and exit Phase 3). Operator-triggered via `/stop` (soft) or `/stop --hard` (also `TaskStop`s in-flight). `/stop --reset` clears the marker.
4. **Final review** — one holistic `code-reviewer` subagent across the full diff vs main. Any solo/holistic review pass uses the `pr-review-toolkit(-himmel)` `code-reviewer` — NEVER `caveman:cavecrew-reviewer` as the sole reviewer (solo cavecrew produced 2 false Criticals of 4 findings on the HIMMEL-292–296 fix batch, while the 4-reviewer toolkit round on #453 was clean — HIMMEL-299). **Never zero CR (HIMMEL-299, 2026-06-13):** a docs-only diff still gets ONE **docs-audit** `code-reviewer` subagent scoped to the docs charter — repo-claim accuracy (hooks/gates/flags/paths/commands vs actual code), dead links, stale file/flag/ticket refs, example correctness, internal consistency; NOT prose nitpicks (`CLAUDE.md` → `/claude-md-audit`). Review is never skipped outright.
5. **Heavy CR** — dispatch 6 reviewers IN PARALLEL: 5 from `pr-review-toolkit` (`code-reviewer`, `pr-test-analyzer`, `comment-analyzer`, `silent-failure-hunter`, `type-design-analyzer`) + `caveman:cavecrew-reviewer`. `cavecrew-reviewer` is the heavy-CR sixth opinion ONLY — never a solo/holistic reviewer (HIMMEL-299: 2 false Criticals when run solo). Aggregate Critical/Important/Minor findings by file. For docs-only or test-free PRs, skip reviewers that don't apply (e.g. `pr-test-analyzer`, `type-design-analyzer`, `silent-failure-hunter` are no-ops on a pure-markdown PR) and dispatch only the relevant subset. **`/code-review ultra` sits ABOVE this tier (HIMMEL-299 eval — ADOPT):** it is the MOST expensive lane — more than this 6-reviewer heavy CR — so it is the top/last-resort escalation for the biggest/riskiest PRs, run AFTER heavy CR, never as a cheaper first reach. It is operator-triggered + billed; the agent cannot launch it — record an `ultra` pass as a one-action operator step.
6. **Fix batch** — dispatch fix subagent(s) for ALL Critical + Important findings. Run tests after each batch.
7. **Re-CR** — re-dispatch the same 6 reviewers. Loop fix → re-CR until 0 Critical remain.
8. **PR open + push** — `gh pr create --body-file <path>`. Write the body to a file first to avoid shell-interpretation surprises (heredocs, `$()` substitutions, multi-line content with quotes). **Attestation trailers go in the FIRST commit, never a reactive amend** — see "Auto-mode classifier & attestation" below. Before the first `git commit` of any shippable change, after you have genuinely run tests + the heavy CR, write the gate trailers directly into that commit body:
   ```
   Platforms tested: <linux|windows|gitbash|…>   # only when the diff touches shell/scripts
   Security reviewed: <pr-review-toolkit|manual|claude-code-security-review>   # only for non-docs code
   ```
   Then the push passes the `platforms-tested` / HIMMEL-176 gates first-try with no amend. **Do NOT commit first, hit the gate, then `git commit --amend` to add the trailer** — the auto-mode classifier flags that reactive amend as security-gate circumvention and HARD-blocks it (uncleable, even with operator approval).
9. **Merge** — `gh pr merge --squash` once CR is clean. **Default to a PLAIN squash merge — do NOT add `--admin`** (HIMMEL-224). `--admin` exists to bypass *branch protection*; this repo has none (the protection API returns 403 on a free private repo, and `reviewDecision` is empty), so `--admin` bypasses nothing useful yet it trips the auto-mode classifier's "bypassing the approval gate = destructive op outside the worktree" HARD-veto (see § Block-only criteria) — which is exactly what stalled the HIMMEL-221 run. Only reach for `--admin` if the repo *actually* has branch protection that blocks the plain merge, and then only with `GH_ADMIN_MERGE_OK=1` set in the launching shell (the `scripts/handover/pr-merge.sh` helper encodes this plain-first/admin-fallback logic). **If the merge is blocked for any reason, load the `himmel-ops:stuck-playbook` skill** (§ "a PR merge was blocked"), then — rather than guessing or routing around the block — record the merge as a one-action operator step in the Phase 11 handover. Retrying a blocked merge via a different command path is flagged as evasion and hardens the block.
10. **Jira** — invoke the CLI as `node scripts/jira/dist/index.js transition <KEY> "<state>"` (NOT the global `jira` shim — it points at an unrelated, often-broken `jira-cli` package). This runs autonomously **provided the specific standing allow-rule `Bash(node scripts/jira/dist/index.js:*)` is present** — a generic `Bash(node *)` is NOT enough to authorize an external write (see § Auto-mode classifier). If the rule is missing, a transition is classifier-blocked; do NOT retry via a different path (evasion) — record it as an operator action in Phase 11 and have the operator add the rule once (it then works for all future runs).
11. **Handover** — write `next-session-<N+1>.md` (or whichever increment) in the right dir, file followup tickets for non-blocking findings, record any classifier-blocked Jira transitions as explicit operator actions, update `status.md` + `roadmap.md`, commit + push (trailers in the first commit per Phase 8). **Release the step-0 queue lock** (`bash scripts/handover/queue-lock.sh release <handover-path> <release-token>` — the token captured from the step-0 acquire output; if it was lost, `QUEUE_LOCK_FORCE_RELEASE=1 bash scripts/handover/queue-lock.sh release <handover-path>` force-releases loudly and logs the override) as part of this phase — the TTL is a safety net for a crashed session, not a substitute for releasing on a clean wrap.

## Fable-5 launch preamble (HIMMEL-281)

Any prompt that launches an overnight/armed run (the next-session
`Overnight Mode Trigger` block — also reached by `arm-resume.sh`
relaunches, whose prompt loads a next-session file carrying this block —
and manual "overnight mode" invocations) carries these two standing
instructions, verbatim from the [official Fable-5 prompting guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5):

**Caveman has no model-tier exemption (HIMMEL-699):** if the caveman plugin
is ever toggled on (it defaults `off`), its hooks apply uniformly — an
`arm-resume.sh` relaunch has no `CAVEMAN_DEFAULT_MODE` override, so a
Fable-5 overnight session would get compressed like any other model. See
[`docs/token-economy.md`](../token-economy.md) before enabling caveman
globally or repo-locally.

> When you have enough information to act, act. Do not re-derive facts
> already established in the conversation, re-litigate a decision the
> user has already made, or narrate options you will not pursue in
> user-facing messages. If you are weighing a choice, give a
> recommendation, not an exhaustive survey. This does not apply to
> thinking blocks.

> You have ample context remaining. Do not stop, summarize, or suggest a
> new session on account of context limits. Continue the work.

The first counters overplanning on long autonomous turns; the second
counters context-budget anxiety (Fable 5 occasionally wraps up early when
it believes context is short). The guide's grounded-progress-claims and
early-stopping snippets are NOT duplicated here — the attestation
discipline (§ Auto-mode classifier) and the block-only criteria already
cover them.

**Safety-classifier reroute is not a failure.** ~5% of Fable sessions trip
a (trigger-happy) safety classifier and route to Opus 4.8 **with a
notification** (community-measured, @PawelHuryn). This is a different
layer from the auto-mode classifier below: nothing was blocked, the floor
is Opus 4.8, and the run should simply continue — do not halt, retry, or
escalate to the operator over a reroute notice.

## Artifacts to keep in sync

The pipeline ships code, but some repo artifacts mirror that code and must be
updated in the **same PR** or they silently rot. **Owner: the executing agent,
as the first action of Phase 8** (before `gh pr create`) — diff the change set
against this list and commit any sync edit onto the branch. The Phase-5 heavy
CR (`comment-analyzer` / `cavecrew-reviewer`) is the backstop, not the primary
catch.

- **`docs/commands-catalog.md`** — if the diff adds, renames, or removes a
  command under `.claude/commands/`, update the matching row (verbatim from the
  command's `description:` frontmatter; the doc carries a regen snippet).
- **`CLAUDE.md` quality** — if the diff changes any `CLAUDE.md` (root or
  subtree), run `/claude-md-audit` before `gh pr create` (HIMMEL-218). It runs
  the `claude-md-improver` rubric audit against the changed file(s) in the
  worktree and surfaces findings to fix in-branch; lean-invoke, not a hook
  (an LLM audit per commit is too heavy), and audit-only (no auto-edits).

This list grows as new mirrored artifacts appear; add a row when you create one.

## Morning review — one report, then drill into PRs (HIMMEL-258)

A `/overnight-shift` run ends by writing a **consolidated morning report**:
one artifact, `overnight-report-YYYY-MM-DD.md`, generated by
`scripts/overnight/morning-report.sh` and placed under the handover root
(resolved via `scripts/lib/handover-path.sh` / `handover_root_ensure`,
which creates the Mode A inline dir on demand; a broken `HANDOVER_DIR`
fails closed with exit 2 instead of falling back to a hardcoded
`./handovers/`). One row per dispatched ticket — ticket, branch,
PR link, status (`done` / `blocked` / `partial`), one-line outcome — with
anything needing a human decision grouped in a "Decisions needed" block at
the top and those tickets sorted first in the table.

The morning-review flow is therefore **read one report, then drill into
PRs** — not per-ticket discovery across N branches/PRs/reports. Rationale
(Amdahl's Law applied to multi-agent work): human review is the serial
fraction that caps fanout speedup, so the mandatory human checkpoint is
batched into a single entry point. Work the decisions block first, then
review PRs in report order (`/pr-check`). Merging stays human — only the
review *surface* is batched.

**Standing operator actions (HIMMEL-450).** The report is *regenerated* every
run, so a one-off note elsewhere won't resurface. Durable manual actions —
especially **single-session-only** ones (e.g. a history rewrite) — go in
`<handover-root>/operator-actions.md`; `morning-report.sh` appends them verbatim
as a `## Standing operator actions` section to *every* report until you delete
them. Use plain bullets (not headings — they'd compete with the report's H2s);
absent or blank ⇒ no section. The run-end command relies on the default path
(`<dirname report>/operator-actions.md`) — no `--actions` flag needed. With no
overnight run, just read the file directly; it's plain markdown.

## Budget (informational)

- **Subagent dispatches:** ~50-60 per overnight run. Per phase 3, impl is ~3 subagents per task (implementer + 2 reviewers); a 16-task plan = ~48 just for impl. Add ~6-12 for phase 5 heavy CR over 1-2 rounds, plus fix-batch dispatches (5-10).
- **Wall time:** ~3-4 hours.
- **Inference cost:** ~$10-20 on Sonnet. Bump to Opus for the planning / final-review phases if extra rigor is wanted; Sonnet is enough for impl + per-task reviews.
- **Effort tiering (Fable-5, HIMMEL-281):** on Fable 5, `low` effort ≈ `xhigh` on prior models — this strengthens the raise-effort-before-tier rule of the Subagent delegation & escalation policy (HIMMEL-166/688, root `CLAUDE.md`). For mechanical subagent work, raise effort before raising the model tier; reach for Opus-class only with a concrete reason. Default effort `high`; `max` is a re-verification tax (2-3× time for the same answer, community-measured) — reserve it for capability-critical single calls, not pipeline phases.

These are estimates from HIMMEL-97. The operator decides when to stop — no auto-pause guardrails.

## Block-only criteria

Block for human input ONLY when:
- An ambiguous design decision is not covered by the spec.
- Ticket creation needs a human judgment call on Jira project or priority.
- A destructive op outside the worktree is required (e.g. force-push to main, drop a remote branch the operator owns).
- A plain Phase-9 `--squash` merge is blocked by *real* branch protection (not the no-op case HIMMEL-224 removed) and `--admin` would be needed but is not authorized (`GH_ADMIN_MERGE_OK` unset) — bypassing a genuine approval gate is exactly the kind of "destructive op outside the worktree" overnight mode should NOT do unattended. Defer the merge to the operator.

Everything else proceeds without confirmation.

## Telegram relaunch — always PLAIN, never `--channels` (HIMMEL-225)

When an overnight/armed session is scheduled to relaunch (via the
`handover-arm-resume` skill / `scripts/handover/arm-resume.sh`), the relaunch
is **PLAIN — no `--channels`**. The always-on bun Telegram bridge
(HIMMEL-207/208) owns the single `getUpdates` slot and reaches Telegram
independent of any session, so a `--channels` relaunch is actively harmful: it
becomes a 2nd `getUpdates` consumer (409 Conflict) and its
`--dangerously-load-development-channels` prompt **hangs the unattended
launch**. `arm-resume.sh` enforces this — it refuses `--channels` (rc=5) while
the bridge is live. Keep the bun bridge up; relaunch plain. Full rationale:
[`docs/internals/telegram-bridge.md`](../internals/telegram-bridge.md).

## Auto-mode classifier & attestation (Opus 4.8+)

Opus 4.8 runs a model-based **auto-mode classifier** on every tool call in autonomous/auto-accept sessions. It is a SEPARATE layer from the `.claude/settings.json` permission allow-list. Crucially, **a generic catch-all allow-rule does NOT authorize a semantically-risky action — only a SPECIFIC, tool-named rule does**. Observed: a Jira write invoked as `node scripts/jira/dist/index.js …` matched only the generic `Bash(node *)` and was **blocked**, whereas the same write invoked as `jira …` matched the specific `Bash(jira *)` and **ran**. The classifier sorts actions into two tiers:

- **HARD vetoes — uncleable by any setting OR by operator approval** (this is the prompt-injection defense that makes unattended overnight runs safe):
  - **Security-gate circumvention** — e.g. `git commit --amend` to add a `Security reviewed:` / `Platforms tested:` trailer *after* a push gate already failed. The reactive amend reads as "fabricate an attestation to bypass the gate."
  - **Self-modification** — editing `.claude/settings.json` (or via the update-config skill) to widen your own allow-rules. An agent cannot escalate its own permissions.
- **Authorization-gated — cleared by a SPECIFIC, tool-named standing allow-rule** (operator-authored once):
  - **External-system writes** — Jira transitions, posting comments, etc. A broad `Bash(node *)` does NOT authorize these; a specific rule naming the exact CLI does. For himmel Jira, the rule is `Bash(node scripts/jira/dist/index.js:*)` — with it present, transitions run autonomously (no defer). Retrying a *blocked* write via a different command path is flagged as **evasion** and hardens the block, so the fix is the standing rule, not retrying.

What this means for an autonomous run, and how to stay unblocked:

1. **Attestation: write trailers into the FIRST commit** (Phase 8), never a reactive amend. This avoids the gate-circumvention veto entirely — the push passes the deterministic git hook first-try and there is no amend for the classifier to flag. This is the single most important rule for shipping autonomously.
2. **Never `git commit --amend` to satisfy a just-failed push gate.** If you somehow committed without a required trailer, the recovery is to author a clean replacement commit message *before* the first push of that branch — not an amend after a failed push. If the branch is already pushed, the trailer must go in the PR body (the gates accept PR-body attestation) — let the operator add it; do not amend.
3. **Self-modification is operator-only by design.** The agent cannot add allow-rules to its own settings, nor edit `CLAUDE.md` / `.claude/settings.json`, even in a worktree PR branch — the *commit* of such a change is classified as self-modification and HARD-blocked when the change is **agent-inferred**. The unblock is **explicit user specification**: when the operator states the exact allow-rule string (or exact rule text) verbatim, the intent bar is met and the agent may commit it. Pure operational docs (this file) are NOT governing config and commit freely.
4. **External writes (Jira): ensure the specific standing allow-rule exists, then run them.** With `Bash(node scripts/jira/dist/index.js:*)` in settings, transitions run autonomously — 100%, no defer. If the rule is absent (and you cannot add it — that's operator self-mod), do NOT probe alternative invocations (flagged as evasion); record the transition as an operator action in the handover and ask the operator to add the rule once.

These are environment behaviors, not himmel policy — documented here so every operator's overnight run understands why an agent stalls and what the unblocked path is.

## Failure modes to watch (operator layer, HIMMEL-175)

Overnight mode fans out N parallel sub-agents (Phase 3) and the operator
becomes their coordinator. [@nyk_builderz](https://x.com/nyk_builderz) named
four operator-layer failure modes that nobody screenshots — "ignore the
operator layer and your team collapses into a single blurry agent within a
month." How each shows up here, what mitigates it today, and what the operator
should check **after** a shift:

1. **Voice blur** — sub-agents converge on the same style after enough shared
   context; the N PRs read cookie-cutter and reviewers stop noticing.
   - *Mitigation:* **NONE.** Candidate: seed each ticket's implementer with a
     per-ticket persona (different altitude/emphasis) so approaches diverge.
   - *Post-shift check:* skim the N PRs side by side — do they vary in approach
     and commit cadence, or is every one structurally identical? Identical = blur.

2. **Memory pollution** — personal/unrelated context bleeds into a shared layer.
   - *Mitigation:* **PARTIAL.** Per-branch worktree isolation + per-ticket
     `handover/<TICKET>` branches keep one ticket's state out of another's; the
     nested subdir `CLAUDE.md` tree (HIMMEL-173) scopes context to the subtree.
     The shared root `CLAUDE.md` is the one shared layer to guard.
   - *Post-shift check:* did any PR commit unrelated-ticket context, scratch
     notes, or personal state into a tracked file?

3. **Handoff drift** — context lost between agent A and agent B.
   - *Mitigation:* **ADDRESSED.** `next-session-N.md` snapshots carry decisions
     forward; `/handover-flush` (HIMMEL-143) consolidates across `handover/*`
     branches; the Phase-3 implementer → spec-compliance reviewer →
     code-quality reviewer → fix loop hands forward a reviewed diff, not raw
     intent.
   - *Post-shift check:* read the resume snapshot cold — can you reconstruct
     *why* each decision was made, or only *what* shipped? Only-what = drift.

4. **Coordination overhead** — the coordinator (here, the operator reviewing N
   PRs) becomes the bottleneck past some size.
   - *Mitigation:* **PARTIAL — batch the entry point + enforce a ceiling.**
     The consolidated morning report (HIMMEL-258, § Morning review) collapses
     N-PR discovery into one decisions-first artifact, but review depth is
     still serial: keep an overnight fan-out to **≈6–8 tickets**. Beyond
     that, manual N-PR review degrades to rubber-stamping (defeating the CR
     gate); split into multiple shifts instead.
   - *Post-shift check:* if a shift dispatched >8 tickets, assume review fatigue
     — spot-check rather than pretend-to-deep-review all of them.

## Lessons learned (HIMMEL-97)

Non-obvious gotchas that surfaced during the proof-of-concept run; carry forward to future overnights:

- **Lock target must be a FILE not a directory.** Pass a real file path to `lockfile.lock()` — e.g. `<tDir>/.lock`, touched into existence first (see the `// B2:` comment block in `scripts/himmel-run/src/run.ts`). `proper-lockfile` v4 then creates the lock artifact at `<target>.lock` (so `<tDir>/.lock.lock` here) as a sibling **directory**, not a file — verified by the `mkdirSync(lockPath)` line in the `'recovers from stale lockfile'` test at `scripts/himmel-run/tests/lock.test.ts`. To clean a stale lock: `rm -rf <target>.lock` (or `rmdir <target>.lock` since the dir is empty in v4). POSIX `rm` without `-r` refuses directories — that is the failure mode if you treat the artifact as a file.
- **`lastIndexOf('--')` not `indexOf('--')`** in arg parsers — the user can write `--` inside earlier flag values.
- **Init flow must collect ALL required env vars upfront.** HIMMEL-97 D1 missed `JIRA_BASE_URL` and had to re-init. Enumerate from the runner config.
- **Skill markdown body should be a single command line.** ALL retry/fallback/recovery logic lives in the runner — skills cannot enforce branching deterministically.
- **Log/cache paths need Windows variants** in skill markdown (`%LOCALAPPDATA%` vs `$XDG_CACHE_HOME`).
- **`gh api graphql` uses `-F query=@file.gql`** (capital F) — verified during HIMMEL-97 CR.
- **Heavy CR catches 30+ Critical/Important issues** on a fresh runner. Budget ~2 rounds of fix-then-review minimum.

## Reference run

- Epic: HIMMEL-46 (jira-plugin-wrap)
- Task: HIMMEL-97 (runner + plugin)
- PR: #97 (squash `8c482b5`), merged 2026-05-23
- 36 commits on feat branch, 113 tests at merge, 2 CR rounds, ~30 distinct Critical/Important fixes
- HIMTEST Jira project created mid-flow as a **permanent** sandbox — do not delete; `scripts/himmel-run/tests/integration.test.ts` hard-codes `--project HIMTEST` and asserts issue keys match `/^HIMTEST-\d+$/`
- Followups filed as HIMMEL-100/101/102
