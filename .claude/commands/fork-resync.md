---
description: Re-sync a carried FORK onto a newer upstream base — rebase the fork's additive delta and audit that it is still additive. An OPERATOR-run invocation may continue on to push the fork and move the pin; the nightly fork-resync cadence (HIMMEL-1323) runs unattended and STOPS after the audit, reporting the result — it never pushes and never moves the pin.
argument-hint: [name] [--dry-run] [--no-public]
---

The third repair path. `/drift-fix` handles the two easy classes — a version pin
in the repo (`mode: base`) and an installed binary (`mode: probe`). This one
handles the class that has no cheap fix: a **fork**.

himmel does not consume upstream `tobi/qmd` directly. It carries `yotamleo/qmd`,
SHA-pinned by `_qmd_fork_ref()` in `scripts/lib/qmd-bin.sh`. The registry's
`synced_base` records the highest upstream STABLE tag that fork actually sits on.

**The trap this command exists to prevent:** when upstream tags past
`synced_base`, the entry reads BEHIND, and the one-line "fix" — bump
`synced_base` — is a lie. It marks the fork as carrying an upstream base it never
rebased onto, and the guard goes quiet while the fork drifts further. That is why
qmd deliberately has **no `version_pin`** and why `apply-drift-bump.sh` returns
SKIP for it rather than being taught to handle it.

The real fix is a rebase, and a rebase can conflict. That needs judgment, which
is why this is a runbook and not a shell script.

**Rules that hold throughout.**

1. **Never bump `synced_base` without a completed rebase.** If you cannot finish
   the re-sync, leave the entry BEHIND. A truthful BEHIND is the product here.
2. **Never push to the fork remote unless the audit is clean.**
   `resync-fork.sh --push` enforces this, so do not work around it.
3. **STOP at the public PR.** The public squash-merge is operator-authorized.

`--dry-run` = report the rebase result, change nothing, push nothing.
`--no-public` = stop after the private merge.

---

## 1. Ground the run

Work from the PRIMARY checkout. `git fetch origin`, confirm a clean tree and
`main` at `origin/main`. A dirty tree aborts the run — never stash or reset
someone else's work.

## 2. Find the drifting forks

```bash
bash scripts/check-plugin-drift.sh
```

Take every `BEHIND` entry that declares a **`fork`** block in
`scripts/upstreams.json`. If a `name` argument was given, restrict to it.

Nothing BEHIND with a `fork` block → report "no fork drift" and stop. This is
the expected outcome most nights; upstream tags rarely.

Any registry entry that declares a `fork` block is in scope — since
HIMMEL-1435 that includes the pinned-remote fork `claude-obsidian` (its
marketplace pin is an installable fork TAG, so publishing is a tag re-cut, but
the nightly rebase-audit runs here like any other fork). Still **not** in
scope, each needing its own judgment call — say so rather than touching them:
- vendored forks with an `UPSTREAM_PIN` (`telegram-himmel`,
  `pr-review-toolkit-himmel`) — a re-vendor plus a file-level delta audit.

## 3. Rebase and audit

```bash
bash scripts/upstreams/resync-fork.sh <name>
```

Scratch clones only; it never touches the live install and never writes to a
remote without `--push`.

| rc | meaning | do |
|----|---------|-----|
| 0 | rebase CLEAN and the delta is still strictly additive | continue to step 4 |
| 1 | already on the target base | nothing to do; if the guard still says BEHIND, the registry disagrees with reality — report that, don't "fix" it by editing `synced_base` |
| 2 | usage / registry / missing git or network | abort and report |
| 3 | SKIP — no `fork` block | not in scope for this command |
| 4 | rebase CONFLICTED, the delta is NOT additive, OR a pin-literal failure (`PIN_FILE_MISSING`/`PIN_NOT_FOUND`/`PIN_AMBIGUOUS`) | **stop and escalate** — see below; expected-non-additive entries are the exception |

**Expected-non-additive entries (HIMMEL-1435).** An entry whose `fork.note`
declares the delta non-additive BY DESIGN (`claude-obsidian`: it modifies
upstream files — removed hooks, locking patches) reports rc 4 NON-ADDITIVE on
every healthy audit. For such an entry that outcome IS the report — record the
drift + rebase-feasibility result and **continue with the remaining forks**; do
not escalate it and do not let it terminate an unattended sweep. A CONFLICTED
rebase or a pin-literal failure on the SAME entry is still a real stop-and-
escalate — only the declared non-additive shape is expected.

**On rc 4, do not resolve the conflict yourself in an unattended run.** For a
CONFLICTED/non-additive rebase, report: the conflicting paths (or the upstream
files the delta modifies/deletes), the fork's commit list, and the upstream
target. A conflicted fork re-sync is a design decision about which side wins —
that is the operator's call, and getting it wrong silently corrupts a
dependency every machine installs. Leave the entry BEHIND and file a ticket
describing the conflict.

A `PIN_FILE_MISSING`/`PIN_NOT_FOUND`/`PIN_AMBIGUOUS` rc 4 is a DIFFERENT failure
mode — the registry's `fork.pin_file`/`fork.pin_template` is stale, not a
rebase judgment call. Report the pin mismatch instead (entry name, the
missing/ambiguous path or template) — the conflicting-paths/commit-list report
above does not apply.

## 4. Publish the rebased fork — OPERATOR-GATED, never unattended

```bash
bash scripts/upstreams/resync-fork.sh <name> --push
```

**A scheduled run must NOT execute this.** It moves a branch on a remote the
operator owns — the one genuinely irreversible-ish step in this runbook — and
"the rebase audited clean" is not the same as "a human agreed to publish it".
The nightly cadence has no approval to mutate a remote, exactly as it has no
approval to merge the public PR.

So the two modes differ here, and only here:

- **Unattended (the cadence):** STOP at the end of step 3. Report the audited
  result — upstream target, fork commits rebased, delta confirmed additive, and
  the rebased SHA `resync-fork.sh` computed in its scratch clone — then exit.
  Nothing is pushed, no pin moves, the entry stays BEHIND, and the guard keeps
  saying so. That is a complete, successful run: the expensive, judgment-heavy
  part (does the rebase even apply cleanly?) is done and reported, and all that
  remains is a human saying yes. Surface the exact command they need:
  `bash scripts/upstreams/resync-fork.sh <name> --push`
- **Operator-run (by hand):** invoking this step IS the approval. Continue to
  step 5.

`--push` still refuses a conflicted or non-additive rebase on its own — that
guard is structural and independent of this one. Record the new fork SHA it
prints; it is the pin.

## 5. Prove the fork still works

A clean rebase is not evidence the result runs. Before moving the pin, exercise
the thing himmel actually depends on. For qmd that is the resolver plus its
suite:

```bash
bash scripts/lib/test-qmd-bin.sh
```

If the fork's own test suite is reachable in the scratch clone, run it too. A
failure here means the rebase was clean but wrong — **stop**, do not move the
pin, and report.

## 6. Move the pin — both halves

Two edits that must move together, same discipline as `/drift-fix`:
- the SHA in `pin_file` (`_qmd_fork_ref()` in `scripts/lib/qmd-bin.sh`) → the new
  rebased SHA from step 4;
- `synced_base` in `scripts/upstreams.json` → the upstream tag just rebased onto.

Do this in a worktree (`bash scripts/clean-garden.sh --no-prune chore/fork-resync-<name>-<YYYYMMDD>`),
never in the primary checkout.

Then re-run `bash scripts/check-plugin-drift.sh` from the worktree — the entry
must now read **CURRENT**. If it does not, the pin and the push disagree; abort.

## 7. Ticket, review, land

Same as `/drift-fix` steps 6–11:
- File or reuse a Jira ticket (`node <repo-root>/scripts/jira/dist/index.js`,
  absolute path, `--desc-file` for the body).
- Commit with attestation trailers in the FIRST commit — `Platforms tested:` and
  `Security reviewed:` — earned by actually running step 5.
- `/pr-check` until CR is clean, open the private PR, watch CI green.
- Merge via `scripts/handover/merge-on-green.sh` (armed) or
  `scripts/handover/pr-merge.sh`. **The ≥1-approval rule applies to this cadence
  exactly as it does to a human PR** — green CI is necessary, never sufficient.
  Never `--admin`, never a branch-protection override. A merge refused for want
  of an approval is the rule working: leave the PR open, report `awaiting
  approval`, and stop. That is a successful run — the re-sync is captured in a
  reviewable PR, which matters more here than anywhere else in himmel, because a
  fork rebase rewrites a dependency every machine installs.
- `bash scripts/propagate-public.sh ship …`, then `/cr-public`, then **STOP** and
  hand the operator the `/mergepub <pr> <sha12>` line.

The commit body must state plainly: which upstream tag, the fork commits
rebased, that the delta was audited additive, and that the fork was pushed. A
reader six months from now needs to know the fork was genuinely re-based, not
just re-labelled.

---

## Report

Every run, including no-ops:

```text
fork-resync <date>
  forks BEHIND:  <name> (<synced_base> -> <upstream tag>)   (or: none)
  rebase:        CLEAN / CONFLICTED (<paths>) / NON-ADDITIVE (<paths>)
  pushed:        <new fork sha>                             (or: no — <why>)
  tests:         <suite> <pass/fail>
  pin moved:     <file> <old sha> -> <new sha>, synced_base <old> -> <new>
  private:       <merged PR url>                            (or: <where it stopped>)
  public:        <PR url> — awaiting /mergepub <pr> <sha12>
```

"No fork drift" is the healthy result. Never manufacture a re-sync to show
activity, and never move a pin you did not earn.
