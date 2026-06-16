# Stuck playbook — operational escape-hatches (HIMMEL-211)

Load-on-trigger reference for the moments Claude gets *stuck* on himmel's own
guardrails: an auto-mode write was denied, a Bash command fell through to the
classifier, a permission prompt hung, or a pre-push gate failed. These are
**operational/recovery** rules — they used to live in the root `CLAUDE.md` but
were migrated here (HIMMEL-211) because they are not session-time frame-shaping:
they only matter at the moment of the symptom, and paying for them on every
session is the bloat the [4 CLAUDE.md rules](#why-this-is-a-playbook-not-a-rule)
warn against. The `himmel-ops:stuck-playbook` skill surfaces this file when the
stuck condition is detected; it carries zero always-on token cost otherwise.

**First principle (HIMMEL-195): prefer a structural fix over a workaround.** If a
shape keeps getting blocked, the fix is usually a hook/CLI change (a new
`auto-approve-safe-bash` case, a CLI flag), not a cleverer command that dodges
the classifier. The cases below are the residual judgment calls after the
structural fixes are exhausted. **Never reshape a command to dodge a guardrail —
if a write is denied after following this playbook, defer to the operator.**

---

## Symptom: a Bash command hangs on a permission prompt, then aborts (HIMMEL-203)

Claude Code's native permission matcher **bails out and PROMPTS** on any command
containing variable expansion (`$t`), command substitution `$(…)`, backticks, or
compound operators — it never reads the allow-list. In headless/auto that hangs
then aborts.

The `auto-approve-safe-bash` PreToolUse hook auto-grants read-only/inspection
commands plus the allow-listed Jira CLI (incl. such loops/pipes with `$var` that
defeat the native matcher) as the structural fix. It deliberately does **not**
cover other writes, interpreters (`sed`/`awk`/bare `node`/…), or `git`/`gh`
write subcommands.

**What to do:** for anything the hook doesn't grant, prefer **literal single
commands** (no `$var` / `$(…)` / loops) so the allow-list can match. If a write
genuinely needs them and prompts, **that prompt is correct** — defer to the
operator, don't reshape to dodge it.

---

## Symptom: a Jira write fell through to the classifier and was DENIED (HIMMEL-205 / 203)

In auto-mode the `auto-approve-safe-bash` hook grants the Jira CLI wholesale —
reads AND writes (`transition`/`comment`/`edit`) — so ticket writes run
unattended (operator-trusted; HIMMEL-205). The catch is command **SHAPE**, not
the write itself: the hook auto-approves only when every segment of a compound
command resolves to a recognised-safe binary.

- `cd … && node …/jira …` **works** (`cd`/`pushd`/`popd` are in the safe-set).
- A command-substitution (`$(…)`) or an unrecognised leading binary makes the
  **whole** command fall through to the auto-mode classifier, which **DENIES**
  external-system writes.

**What to do:** prefer a literal `node …/jira …` (bare or `cd`-prefixed). If a
Jira write still falls through and is denied, that is a **command-shape problem**
— defer to the operator, do **not** reshape to dodge the classifier. See
[`overnight-mode.md`](../handover/overnight-mode.md) § Auto-mode classifier &
attestation. Multi-line bodies: use `--comment-file <path>` / `--desc-file
<path>` so the shell command stays single-line (HIMMEL-209).

---

## Symptom: a pre-push gate failed on a missing attestation trailer

Pre-push gates need attestation trailers (`Platforms tested: <os>` on
shell/script diffs; `Security reviewed: <token>` on non-docs code).

**The rule is to put them in the FIRST commit** after genuinely testing +
reviewing — never a reactive `git commit --amend` after a push fails. In
auto-mode the amend is flagged as gate-circumvention and **HARD-blocked
(uncleable)**.

**What to do if the branch is already pushed without the trailer:** add the
trailer to the **PR body** instead of amending. See
[`overnight-mode.md`](../handover/overnight-mode.md) § Auto-mode classifier &
attestation.

---

## Symptom: a PR merge was blocked (`--admin` / approval gate) (HIMMEL-224)

Overnight Phase 9 used to merge with `gh pr merge --squash --admin`. `--admin`
exists to **bypass branch protection** — but this repo has none (the protection
API returns 403 on a free private repo; PR `reviewDecision` is empty). So
`--admin` bypasses nothing useful, yet the auto-mode classifier reads it as
"bypassing the approval gate = destructive op outside the worktree" and
**HARD-vetoes** it. That stalled the HIMMEL-221 run outright and forced an
explicit in-session authorization on HIMMEL-222.

**What to do:**

1. **Merge plain.** `gh pr merge <N> --squash` (no `--admin`). With no branch
   protection this just works — verified on PR #225. The `scripts/handover/
   pr-merge.sh` helper already does plain-first.
2. **`--admin` is a fallback for REAL branch protection only.** If (and only if)
   the plain merge fails because the repo actually has protection, set
   `GH_ADMIN_MERGE_OK=1` in the **launching** shell (`GH_ADMIN_MERGE_OK=1 claude`
   — a per-call prefix does not reach the hook) and re-run; `pr-merge.sh` then
   retries with `--admin`.
3. **If still blocked, defer to the operator** as a one-action handover ("merge
   PR #N"). Do **NOT** retry the merge via a different command path — the
   classifier flags that as evasion and hardens the block (HIMMEL-195 first
   principle: structural fix over workaround — here the structural fix is
   *not emitting `--admin`*, already shipped in `pr-merge.sh` + overnight-mode
   Phase 9).

The model-based classifier is an Anthropic layer; it cannot be made to read a
repo authorization file. The durable fix is to never emit an unnecessary
`--admin` so the veto never fires.

---

## Why this is a playbook, not a `CLAUDE.md` rule

Root `CLAUDE.md` is **state, not a prompt** — frame-shaping invariants only, paid
for on every session. Operational/troubleshooting rules (the above) are
prunable, per-user, and only relevant at the moment of the symptom, so they live
load-on-trigger here instead (decision locked: memory
`feedback_no_operational_rules_in_claudemd`; layer-selection HIMMEL-177;
structural>instructional HIMMEL-195). The 9-author convergence behind "short
CLAUDE.md beats long" is synthesized in the luna vault at
`Clippings/synthesis/2026-05-26-concept-claude-md-patterns.md`.
