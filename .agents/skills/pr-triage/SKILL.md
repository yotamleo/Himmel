---
name: pr-triage
description: Lightweight 4-step PR triage gate (steipete) — decide if a PR is even worth a deep multi-agent CR before running pr-check. Use when the user asks to triage a PR or runs /pr-triage.
---

# pr-triage

A lightweight first-pass gate (~10s of reasoning) run BEFORE the heavy `pr-check`.
The question is "is this PR even worth a deep review?" — not "is it correct?".
There is no script: this is a reasoning procedure. Given a PR number/URL (default
the current branch's PR):

0. **Pull the PR:** `gh pr view <PR> --json title,body,files,additions,deletions`
   and `gh pr diff <PR>`. Read the diff + linked ticket.
1. **Is the issue clear?** If the *problem* is fuzzy, stop — push back for a
   problem statement (no review fixes an unclear goal).
2. **Is this the best fix?** Is it the simplest approach that solves the stated
   problem? A "yes, but" here is the highest-leverage redirect.
3. **Tradeoffs / usually rewrite.** Name the tradeoffs; often rewrite the PR
   rather than nitpick the diff.

**Verdict** (one line): `PROCEED` (issue clear + fix sound → run `pr-check`) /
`REDIRECT` (approach wrong or issue unclear → comment, skip CR) / `REWRITE` (fix
the direction first, then re-triage). See `.claude/commands/pr-triage.md`.
