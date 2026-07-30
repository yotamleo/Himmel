---
description: Resolve upstream fork-drift end-to-end — run the drift guard, mechanically bump every auto-bumpable pin, land it on PRIVATE main, then open a PUBLIC PR and STOP for the operator to merge. The payload of the nightly drift-fix cadence (HIMMEL-1323).
argument-hint: [--dry-run] [--no-public]
---

The repair half of the fork-drift loop. The nightly `fork-drift` GitHub Action
(HIMMEL-1046) only DETECTS drift and refreshes one tracking issue; closing that
loop was always a hand-driven ticket, and those stall — HIMMEL-1260 ("bump
graphify 0.9.22 -> 0.9.23") sat in To Do while the pin advanced past it twice in
unrelated PRs. This runbook is what actually closes it.

Normally fired unattended by `scripts/upstreams/drift-fix-cadence.sh` (daily,
05:00 local). Safe to run by hand — the steps are identical.

**Two rules that hold for every step below.**

1. **Never hand-edit a pin.** `scripts/upstreams/apply-drift-bump.sh` owns the
   edit. It moves the in-repo pin literal and `synced_base` together, refuses a
   downgrade, and restores both files byte-identical if anything is off. Editing
   either spot yourself defeats all of that.
2. **STOP at the public PR.** The public squash-merge is operator-authorized
   (Telegram `/mergepub <pr> <sha12>` or the GitHub UI). Never merge it.

`--dry-run` = run steps 1–4 and report; change nothing.
`--no-public` = stop after the private merge (step 9); skip 10–11.

---

## 1. Ground the run

Work from the PRIMARY checkout (`git rev-parse --git-common-dir`'s parent), not
a worktree. Then:

```bash
git fetch origin
git status --porcelain
```

A dirty tree means someone is mid-work. **Abort** with that fact reported —
never stash, reset, or commit someone else's changes. Confirm `main` is at
`origin/main`; if not, report and abort.

## 2. Read the drift

```bash
bash scripts/check-plugin-drift.sh
```

Exit codes: `0` all current, `2` drift, `3` incomplete. Anything other than 2
means there is nothing to repair — say so and stop (an exit 3 proves nothing, so
never treat it as "clean").

From the output, collect every `BEHIND` line whose name is a **`tag_release` /
`mode: base`** entry in `scripts/upstreams.json`. Those are the only ones that
carry an in-repo pin this runbook can move. A `BEHIND` line reads:

```text
  graphify: BEHIND   (Graphify-Labs/graphify latest tag v0.9.28; installed 0.9.25 — upgrade)  [A]
```

→ name `graphify`, target version `v0.9.28`.

Also collect every `BEHIND` line whose name is a **`tag_release` / `mode: probe`**
entry (rtk, twitter-cli). Those have no repo pin at all — their drift is an
out-of-date binary on THIS machine, repaired in step A below. This is the half a
CI job could never do, and the reason the cadence runs locally.

**Ignore** everything else, and say which you ignored and why:
- `mode: checkout` entries (hermes-agent) and `mkt:*` marketplaces — a checkout
  to pull or a marketplace to re-sync, neither of which is a version bump.
- `commit_head` / vendored forks — a re-sync + delta audit, not a version bump.

## 2A. Upgrade the installed vendor CLIs

Do this BEFORE the branch work — it produces no repo diff, so it must not
influence whether a PR gets opened. Per probe entry collected above:

```bash
bash scripts/upstreams/apply-tool-upgrade.sh <name> <target-version> --unattended
```

**Always pass the target version** from the guard's BEHIND line. Without it the
script cannot tell "already the newest release" from "the upgrade silently did
nothing" — both look like an rc-0 command and an unchanged version — so it
reports rc 1 with the claim marked unverified instead of guessing. With the
target it knows, and not reaching it is a hard rc 4.

**Always pass `--unattended`.** It is the policy gate: it refuses any entry not
marked `upgrade.unattended: true` in the registry. Dropping the flag would
silently overrule an operator decision, in either direction.

Read the flag from the registry — do not assume which entries are gated. As of
2026-07-28 BOTH probe entries are `unattended: true`: `twitter-cli` (Tier A, no
caveat) and `rtk`, which the operator explicitly approved that day, overriding
its Tier B default. rtk's entry note records why the reservation existed (BEHIND
is normally its intended steady state; HIMMEL-270 is unfixed upstream) and what
makes unattended acceptable anyway (`upgrade-rtk.sh` backs up, smoke-tests, and
rolls back; `rtk-hook-guard.sh` is fail-OPEN so a broken rtk stops rewriting
Bash rather than blocking it). Flipping that field back to `false` is the
supported way to return rtk to operator-triggered — expect an rc 3 SKIP then.

| rc | meaning | do |
|----|---------|-----|
| 0 | upgraded — prints `UPGRADE <name> <old> -> <new>` | continue |
| 1 | already current | continue |
| 2 | usage / registry / **tool not installed** | report, continue with the others — this script upgrades, it never bootstraps |
| 3 | SKIP — no `upgrade` block, or operator-triggered only | report it in the run summary with the version gap so the operator can decide; do NOT re-run without `--unattended` |
| 4 | ran but the version did NOT advance | **report loudly** — the toolchain is now suspect; name the tool and the version it is stuck on |

An rc 3 is not a failure — it means the entry is gated to the operator. Surface
it as a line they can act on:
`<tool> <old> -> <new> available; operator-triggered: bash scripts/upstreams/apply-tool-upgrade.sh <tool>`

No entry is gated today (both probe entries are `unattended: true`), so rc 3
should not appear from the cadence — if it does, someone gated an entry
deliberately and the run summary is how they learn it fired.

Never edit `scripts/upstreams.json` to flip an entry's `unattended` flag to get
past an rc 3. That flag is an operator decision, not an obstacle.

## 3. Branch first

If step 2 collected no `mode: base` entries, stop here and report — including
whatever step 2A did. **Do not create a branch or a PR to prove the cadence
fired**, and note that a probe upgrade is NOT a reason to open one: it changed a
binary on this machine, not a file in the repo. A no-op night is a successful
run.

Otherwise cut the worktree BEFORE touching a pin, so the edits are never made in
the primary checkout (`git status` there must stay clean — the on-main-write
guard blocks it, and step 1 already promised not to disturb anyone's work):

```bash
bash scripts/clean-garden.sh --no-prune chore/drift-bump-<name>-<YYYYMMDD>
```

**Every remaining step runs from that worktree**, including the bumper and the
re-verify — `apply-drift-bump.sh` resolves its target files relative to its own
location, so invoking the worktree's copy edits the worktree's files.

## 4. Bump

Per collected entry, one call:

```bash
bash scripts/upstreams/apply-drift-bump.sh <name> <target-version>
```

Handle the exit code — do not paper over any of them:

| rc | meaning | do |
|----|---------|-----|
| 0 | bumped (prints `BUMP <name> <old> -> <new>`) | continue |
| 1 | already at that version | skip it; note the guard/registry disagreement |
| 2 | usage / registry / **downgrade refused** | **abort the whole run** and report — a refused downgrade means the guard reported a version older than the pin, which is an upstream or registry problem, not something to work around |
| 3 | SKIP — no `version_pin`, not auto-bumpable | report it, continue with the others; qmd is the standing example (its pin is a fork SHA, so bumping `synced_base` alone would mark the fork as rebased when it isn't) |
| 4 | bump failed, both files restored | **abort** and report — the registry's `version_pin.template` no longer matches the file |

If every entry came back rc 1 or rc 3, nothing changed: report why, remove the
worktree (`bash scripts/clean-garden.sh --prune-only` or `git worktree remove`),
and stop. **Do not open an empty PR.** With `--dry-run`, add `--dry-run` to each
call and stop after this step.

## 5. Verify the bump against upstream

Re-run `bash scripts/check-plugin-drift.sh` from the worktree. **Every bumped
entry must now read `CURRENT`.** If one still reads `BEHIND`, the target version
was misread — abort and report; do not "try the next version".

## 6. Ticket

Every private PR carries a Jira ticket. Search first:

```bash
node <repo-root>/scripts/jira/dist/index.js list --jql "project = HIMMEL AND summary ~ 'graphify' AND statusCategory != Done" --limit 10
```

Reuse an open ticket for this exact bump if one exists; otherwise file one
(absolute path from the primary checkout, `--desc-file` for the body — a
heredoc/`$( )` shape gets refused by `block-jira-compound-write.sh`):

```bash
node <repo-root>/scripts/jira/dist/index.js create --type Task --title "Bump <name> pin <old> -> <new> (fork-drift)" --desc-file <path>
```

The body should name: the drift guard line, the two files moved, the tracking
issue number, and that this was applied by the nightly cadence.

## 7. Commit

Commit in the worktree. The message needs the attestation trailers in the
**FIRST** commit (a later `--amend` is HARD-blocked in auto-mode):

```text
chore(HIMMEL-<N>): bump <name> pin <old> -> <new> (fork-drift #<issue>)

<one paragraph: which upstream release, what the guard said, that
apply-drift-bump.sh applied both halves mechanically>

Platforms tested: windows
Security reviewed: <token>
```

Both trailers are earned, not decorative — before writing them, actually run:

```bash
bash scripts/upstreams/test-apply-drift-bump.sh
bash scripts/lib/test-graphify-bin.sh      # or the bumped entry's own suite
```

If a suite fails, fix it or abort. Never write a trailer for a run you did not do.

## 8. Review gate

Run `/pr-check` and loop — fix every finding, re-run — until CR is clean. The
CR-marker hook HARD-blocks `gh pr create` until it is. Then open the private PR
referencing the ticket.

## 9. Land on private main

**The repo rule is ≥1 approval before merge, and this cadence does not get an
exemption for being automated.** An unattended runbook that says "watch CI, then
merge" quietly converts a review requirement into a formality — the one place a
policy bypass is least likely to be noticed, because nobody is watching. So:
green CI is necessary, never sufficient.

Watch CI to green, then hand the merge to the tooling that respects branch
protection — never merge past it:

- Armed auto-merge (`ARMAUTOMERGE=1`, private repo): `bash scripts/handover/merge-on-green.sh`
- Otherwise: `scripts/handover/pr-merge.sh` (plain-first)

**Never `--admin`, never a force-merge, never a branch-protection override.** If
the merge is refused for want of an approval, that is the rule working: leave
the PR open, report it as `awaiting approval` in the run summary, and stop. A
blocked merge is a successful run — the drift is captured in a reviewable PR,
which was the point. Do not retry with a stronger flag, and do not "helpfully"
self-approve.

Then `git pull` on main. Stop here if `--no-public`.

## 10. Propagate to public

The drift guard's tracking issue lives on the PUBLIC repo, and it is the public
pin the nightly Action reads — so a private-only bump leaves the issue open
forever. Ship it with the helper (never a raw push to the public remote; its
fail-closed leak scan and byte-verify are the safety gate):

```bash
bash scripts/propagate-public.sh ship <branch> <base>..<head> --commit-file <f> --title <t> --body-file <f>
```

## 11. Babysit, then STOP

Run `/cr-public` to drive the public PR to CR-clean + CI-green. When it exits 0,
report the FULL payload to the operator and **stop**:

- PR URL, short head SHA
- `check-ci` verdict + diff-identity verdict
- the ready-to-send `/mergepub <pr> <sha12>` line
- the GitHub-UI fallback link

Do not merge the public PR. Once the operator does, the next nightly `fork-drift`
run sees the pin current and **auto-closes the tracking issue** — that is the
loop closing.

---

## Report

End every run — including the no-op ones — with:

```text
drift-fix <date>
  guard:    <exit code> — <n> BEHIND (<n> pinned, <n> installed-tool)
  upgraded: <tool> <old> -> <new>      (or: none)
  awaiting: <tool> <old> -> <new> — operator-triggered: bash scripts/upstreams/apply-tool-upgrade.sh <tool>
  bumped:   <name> <old> -> <new>      (or: none)
  skipped:  <name> (<why>) ...
  ticket:   HIMMEL-<N>                 (or: none — nothing bumped)
  private:  <merged PR url>            (or: <where it stopped>)
  public:   <PR url> — awaiting /mergepub <pr> <sha12>
```

A no-op night is a successful run. Say "no drift" and exit 0 — do not invent
work, and do not open a PR to prove the cadence fired.
